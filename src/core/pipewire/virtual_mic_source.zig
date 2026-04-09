const std = @import("std");
const enable_virtual_mic_info_logs = false;
const audio_engine_mod = @import("../audio/engine.zig");
const bus_buffer_mod = @import("../audio/bus_consumer_buffer.zig");

const c = @cImport({
    @cInclude("pipewire/pipewire.h");
    @cInclude("pipewire/properties.h");
    @cInclude("pipewire/keys.h");
    @cInclude("spa_helpers.h");
});

pub const VirtualMicSource = struct {
    allocator: std.mem.Allocator,
    engine: *audio_engine_mod.AudioEngine,
    bus_id: []u8,
    source_name: []u8,
    description: []u8,
    main_loop: ?*c.struct_pw_main_loop = null,
    stream: ?*c.struct_pw_stream = null,
    listener: c.struct_spa_hook = std.mem.zeroes(c.struct_spa_hook),
    thread: ?std.Thread = null,
    trigger_thread: ?std.Thread = null,
    pipewire_initialized: bool = false,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    process_callback_count: u64 = 0,
    nonzero_callback_count: u64 = 0,
    pcm_buffer: bus_buffer_mod.BusConsumerBuffer,

    pub fn init(
        allocator: std.mem.Allocator,
        engine: *audio_engine_mod.AudioEngine,
        bus_id: []const u8,
        source_name: []const u8,
        description: []const u8,
    ) !*VirtualMicSource {
        const self = try allocator.create(VirtualMicSource);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .engine = engine,
            .bus_id = try allocator.dupe(u8, bus_id),
            .source_name = try allocator.dupe(u8, source_name),
            .description = try allocator.dupe(u8, description),
            .pcm_buffer = bus_buffer_mod.BusConsumerBuffer.init(allocator),
        };
        errdefer {
            self.pcm_buffer.deinit();
            allocator.free(self.description);
            allocator.free(self.source_name);
            allocator.free(self.bus_id);
        }

        c.pw_init(null, null);
        self.pipewire_initialized = true;
        errdefer {
            c.pw_deinit();
            self.pipewire_initialized = false;
        }

        self.main_loop = c.pw_main_loop_new(null) orelse return error.PipeWireMainLoopInitFailed;
        errdefer {
            c.pw_main_loop_destroy(self.main_loop);
            self.main_loop = null;
        }

        const stream_name_z = try allocator.dupeZ(u8, description);
        defer allocator.free(stream_name_z);
        const source_name_z = try allocator.dupeZ(u8, source_name);
        defer allocator.free(source_name_z);
        const description_z = try allocator.dupeZ(u8, description);
        defer allocator.free(description_z);

        const props = c.pw_properties_new(null) orelse return error.OutOfMemory;
        _ = c.pw_properties_set(props, c.PW_KEY_MEDIA_TYPE, "Audio");
        _ = c.pw_properties_set(props, c.PW_KEY_MEDIA_CATEGORY, "Capture");
        _ = c.pw_properties_set(props, c.PW_KEY_MEDIA_ROLE, "Communication");
        _ = c.pw_properties_set(props, c.PW_KEY_MEDIA_CLASS, "Audio/Source");
        _ = c.pw_properties_set(props, c.PW_KEY_MEDIA_NAME, description_z.ptr);
        _ = c.pw_properties_set(props, c.PW_KEY_NODE_NAME, source_name_z.ptr);
        _ = c.pw_properties_set(props, c.PW_KEY_NODE_DESCRIPTION, description_z.ptr);
        _ = c.pw_properties_set(props, c.PW_KEY_AUDIO_FORMAT, "S16LE");
        _ = c.pw_properties_set(props, c.PW_KEY_AUDIO_RATE, "48000");
        _ = c.pw_properties_set(props, c.PW_KEY_AUDIO_CHANNELS, "2");
        _ = c.pw_properties_set(props, "audio.position", "FL,FR");
        _ = c.pw_properties_set(props, "node.virtual", "true");
        _ = c.pw_properties_set(props, "node.pause-on-idle", "false");
        _ = c.pw_properties_set(props, "node.always-process", "true");

        self.stream = c.pw_stream_new_simple(
            c.pw_main_loop_get_loop(self.main_loop.?),
            stream_name_z.ptr,
            props,
            &stream_events,
            self,
        ) orelse return error.PipeWireVirtualMicStreamCreateFailed;
        errdefer {
            c.pw_stream_destroy(self.stream);
            self.stream = null;
        }

        var params: [1]*const c.struct_spa_pod = undefined;
        var buffer: [1024]u8 = undefined;
        var builder: c.struct_spa_pod_builder = undefined;
        c.spa_pod_builder_init(&builder, &buffer, buffer.len);
        params[0] = c.wiredeck_spa_build_s16_stereo_format(&builder);

        const rc = c.pw_stream_connect(
            self.stream,
            c.PW_DIRECTION_OUTPUT,
            c.PW_ID_ANY,
            c.PW_STREAM_FLAG_AUTOCONNECT | c.PW_STREAM_FLAG_MAP_BUFFERS | c.PW_STREAM_FLAG_RT_PROCESS | c.PW_STREAM_FLAG_TRIGGER,
            @ptrCast(&params),
            params.len,
        );
        if (rc < 0) return error.PipeWireVirtualMicConnectFailed;
        if (c.pw_stream_set_active(self.stream, true) < 0) {
            return error.PipeWireVirtualMicConnectFailed;
        }

        self.thread = try std.Thread.spawn(.{}, loopMain, .{self});
        self.trigger_thread = try std.Thread.spawn(.{}, triggerMain, .{self});
        return self;
    }

    pub fn deinit(self: *VirtualMicSource) void {
        self.stop_requested.store(true, .monotonic);
        if (enable_virtual_mic_info_logs) {
            std.log.info("virtual mic source summary for {s}: callbacks={d} nonzero_callbacks={d}", .{
                self.source_name,
                self.process_callback_count,
                self.nonzero_callback_count,
            });
        }
        if (self.main_loop) |main_loop| {
            _ = c.pw_main_loop_quit(main_loop);
        }
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        if (self.trigger_thread) |thread| {
            thread.join();
            self.trigger_thread = null;
        }
        if (self.stream) |stream| {
            c.pw_stream_destroy(stream);
            self.stream = null;
        }
        if (self.main_loop) |main_loop| {
            c.pw_main_loop_destroy(main_loop);
            self.main_loop = null;
        }
        if (self.pipewire_initialized) {
            c.pw_deinit();
            self.pipewire_initialized = false;
        }
        self.engine.releaseBusTapConsumer(self.bus_id, self.source_name);
        self.pcm_buffer.deinit();
        self.allocator.free(self.description);
        self.allocator.free(self.source_name);
        self.allocator.free(self.bus_id);
        self.allocator.destroy(self);
    }

    pub fn sourceName(self: *const VirtualMicSource) []const u8 {
        return self.source_name;
    }

    fn loopMain(self: *VirtualMicSource) void {
        const rc = c.pw_main_loop_run(self.main_loop.?);
        if (!self.stop_requested.load(.monotonic) and rc < 0) {
            std.log.warn("virtual mic source loop failed for {s}: rc={d}", .{ self.bus_id, rc });
        }
    }

    fn triggerMain(self: *VirtualMicSource) void {
        while (!self.stop_requested.load(.monotonic)) {
            if (self.stream) |stream| {
                _ = c.pw_stream_trigger_process(stream);
            }
            std.Thread.sleep(bus_buffer_mod.render_quantum_ns);
        }
    }

    fn process(self: *VirtualMicSource) void {
        self.process_callback_count += 1;
        const stream = self.stream orelse return;
        const pw_buffer = c.pw_stream_dequeue_buffer(stream) orelse return;
        defer _ = c.pw_stream_queue_buffer(stream, pw_buffer);

        const spa_buffer = pw_buffer.*.buffer orelse return;
        if (spa_buffer.*.n_datas == 0) return;
        const spa_data = &spa_buffer.*.datas[0];
        if (spa_data.data == null or spa_data.chunk == null) return;

        const bytes_per_frame = 2 * @sizeOf(i16);
        const frame_capacity = spa_data.maxsize / bytes_per_frame;
        if (frame_capacity == 0) return;

        const samples = @as([*]i16, @ptrCast(@alignCast(spa_data.data)))[0 .. frame_capacity * 2];
        var scratch_buffer: [bus_buffer_mod.render_quantum_frames * bus_buffer_mod.stereo_channels]i16 = undefined;
        _ = self.pcm_buffer.fillFromEngine(
            self.engine,
            self.bus_id,
            self.source_name,
            frame_capacity,
            scratch_buffer[0..],
        ) catch {};

        const written_frames = self.pcm_buffer.drainFrames(samples, frame_capacity);
        const written_samples = written_frames * 2;
        for (samples[0..written_samples]) |sample| {
            if (sample != 0) {
                self.nonzero_callback_count += 1;
                break;
            }
        }
        if (written_samples < samples.len) {
            @memset(samples[written_samples..], 0);
        }

        spa_data.chunk.*.offset = 0;
        spa_data.chunk.*.stride = bytes_per_frame;
        spa_data.chunk.*.size = @intCast(written_frames * bytes_per_frame);
    }
};

const stream_events = c.struct_pw_stream_events{
    .version = c.PW_VERSION_STREAM_EVENTS,
    .destroy = null,
    .state_changed = onStreamStateChanged,
    .control_info = null,
    .io_changed = null,
    .param_changed = null,
    .add_buffer = null,
    .remove_buffer = null,
    .process = onStreamProcess,
    .drained = null,
    .command = null,
    .trigger_done = null,
};

fn onStreamStateChanged(
    data: ?*anyopaque,
    _: c.enum_pw_stream_state,
    state: c.enum_pw_stream_state,
    error_message: ?[*:0]const u8,
) callconv(.c) void {
    const self: *VirtualMicSource = @ptrCast(@alignCast(data orelse return));
    self.active.store(state == c.PW_STREAM_STATE_STREAMING or state == c.PW_STREAM_STATE_PAUSED, .monotonic);
    if (state == c.PW_STREAM_STATE_STREAMING or state == c.PW_STREAM_STATE_PAUSED) {
        if (enable_virtual_mic_info_logs) {
            std.log.info("virtual mic source state for {s}: {s}", .{
                self.source_name,
                if (state == c.PW_STREAM_STATE_STREAMING) "streaming" else "paused",
            });
        }
    }
    if (state == c.PW_STREAM_STATE_ERROR) {
        std.log.warn("virtual mic source error for {s}: {s}", .{
            self.bus_id,
            if (error_message) |msg| std.mem.span(msg) else "unknown",
        });
    }
}

fn onStreamProcess(data: ?*anyopaque) callconv(.c) void {
    const self: *VirtualMicSource = @ptrCast(@alignCast(data orelse return));
    self.process();
}
