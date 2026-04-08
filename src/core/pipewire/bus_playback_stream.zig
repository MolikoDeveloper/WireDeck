const std = @import("std");
const audio_engine_mod = @import("../audio/engine.zig");

const c = @cImport({
    @cInclude("pipewire/pipewire.h");
    @cInclude("pipewire/properties.h");
    @cInclude("pipewire/keys.h");
    @cInclude("spa_helpers.h");
});

pub const BusPlaybackStream = struct {
    allocator: std.mem.Allocator,
    engine: *audio_engine_mod.AudioEngine,
    bus_id: []u8,
    consumer_id: []u8,
    target_sink_name: []u8,
    description: []u8,
    main_loop: ?*c.struct_pw_main_loop = null,
    stream: ?*c.struct_pw_stream = null,
    listener: c.struct_spa_hook = std.mem.zeroes(c.struct_spa_hook),
    thread: ?std.Thread = null,
    trigger_thread: ?std.Thread = null,
    pipewire_initialized: bool = false,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    last_signal_log_ns: i128 = 0,
    last_silence_log_ns: i128 = 0,
    process_callback_count: u64 = 0,
    nonzero_callback_count: u64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        engine: *audio_engine_mod.AudioEngine,
        bus_id: []const u8,
        consumer_id: []const u8,
        target_sink_name: []const u8,
        description: []const u8,
    ) !*BusPlaybackStream {
        const self = try allocator.create(BusPlaybackStream);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .engine = engine,
            .bus_id = try allocator.dupe(u8, bus_id),
            .consumer_id = try allocator.dupe(u8, consumer_id),
            .target_sink_name = try allocator.dupe(u8, target_sink_name),
            .description = try allocator.dupe(u8, description),
        };
        errdefer {
            allocator.free(self.description);
            allocator.free(self.target_sink_name);
            allocator.free(self.consumer_id);
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

        const description_z = try allocator.dupeZ(u8, description);
        defer allocator.free(description_z);
        const consumer_id_z = try allocator.dupeZ(u8, consumer_id);
        defer allocator.free(consumer_id_z);
        const target_sink_name_z = try allocator.dupeZ(u8, target_sink_name);
        defer allocator.free(target_sink_name_z);

        const props = c.pw_properties_new(null) orelse return error.OutOfMemory;
        _ = c.pw_properties_set(props, c.PW_KEY_MEDIA_TYPE, "Audio");
        _ = c.pw_properties_set(props, c.PW_KEY_MEDIA_CATEGORY, "Playback");
        _ = c.pw_properties_set(props, c.PW_KEY_MEDIA_ROLE, "Production");
        _ = c.pw_properties_set(props, c.PW_KEY_MEDIA_CLASS, "Stream/Output/Audio");
        _ = c.pw_properties_set(props, c.PW_KEY_MEDIA_NAME, description_z.ptr);
        _ = c.pw_properties_set(props, c.PW_KEY_NODE_NAME, consumer_id_z.ptr);
        _ = c.pw_properties_set(props, c.PW_KEY_NODE_DESCRIPTION, description_z.ptr);
        _ = c.pw_properties_set(props, c.PW_KEY_TARGET_OBJECT, target_sink_name_z.ptr);
        _ = c.pw_properties_set(props, "node.hidden", "true");
        _ = c.pw_properties_set(props, "node.dont-reconnect", "true");
        _ = c.pw_properties_set(props, "node.pause-on-idle", "false");
        _ = c.pw_properties_set(props, "node.always-process", "true");
        _ = c.pw_properties_set(props, c.PW_KEY_AUDIO_FORMAT, "S16LE");
        _ = c.pw_properties_set(props, c.PW_KEY_AUDIO_RATE, "48000");
        _ = c.pw_properties_set(props, c.PW_KEY_AUDIO_CHANNELS, "2");
        _ = c.pw_properties_set(props, "audio.position", "FL,FR");

        self.stream = c.pw_stream_new_simple(
            c.pw_main_loop_get_loop(self.main_loop.?),
            description_z.ptr,
            props,
            &stream_events,
            self,
        ) orelse return error.PipeWirePlaybackStreamCreateFailed;
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
        if (rc < 0) return error.PipeWirePlaybackStreamConnectFailed;
        if (c.pw_stream_set_active(self.stream, true) < 0) {
            return error.PipeWirePlaybackStreamConnectFailed;
        }

        self.thread = try std.Thread.spawn(.{}, loopMain, .{self});
        self.trigger_thread = try std.Thread.spawn(.{}, triggerMain, .{self});
        return self;
    }

    pub fn deinit(self: *BusPlaybackStream) void {
        self.stop_requested.store(true, .monotonic);
        std.log.info("bus playback stream summary for {s}: callbacks={d} nonzero_callbacks={d}", .{
            self.consumer_id,
            self.process_callback_count,
            self.nonzero_callback_count,
        });
        if (self.main_loop) |main_loop| _ = c.pw_main_loop_quit(main_loop);
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
        self.engine.releaseBusTapConsumer(self.bus_id, self.consumer_id);
        self.allocator.free(self.description);
        self.allocator.free(self.target_sink_name);
        self.allocator.free(self.consumer_id);
        self.allocator.free(self.bus_id);
        self.allocator.destroy(self);
    }

    fn loopMain(self: *BusPlaybackStream) void {
        const rc = c.pw_main_loop_run(self.main_loop.?);
        if (!self.stop_requested.load(.monotonic) and rc < 0) {
            std.log.warn("bus playback stream loop failed for {s} -> {s}: rc={d}", .{
                self.bus_id,
                self.target_sink_name,
                rc,
            });
        }
    }

    fn triggerMain(self: *BusPlaybackStream) void {
        while (!self.stop_requested.load(.monotonic)) {
            if (self.stream) |stream| {
                _ = c.pw_stream_trigger_process(stream);
            }
            std.Thread.sleep(5 * std.time.ns_per_ms);
        }
    }

    fn process(self: *BusPlaybackStream) void {
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
        const read = self.engine.readBusPcmS16ForConsumer(self.bus_id, self.consumer_id, samples);
        const written_frames = if (read.frames > 0) @min(read.frames, frame_capacity) else 0;
        const written_samples = written_frames * 2;
        var peak: f32 = 0.0;
        for (samples[0..written_samples]) |sample| {
            const normalized = @abs(@as(f32, @floatFromInt(sample)) / 32768.0);
            peak = @max(peak, normalized);
        }
        if (written_samples < samples.len) @memset(samples[written_samples..], 0);

        spa_data.chunk.*.offset = 0;
        spa_data.chunk.*.stride = bytes_per_frame;
        spa_data.chunk.*.size = @intCast(frame_capacity * bytes_per_frame);

        const now_ns = std.time.nanoTimestamp();
        if (peak > 0.01) {
            self.nonzero_callback_count += 1;
            if (self.last_signal_log_ns == 0 or now_ns - self.last_signal_log_ns >= std.time.ns_per_s) {
                self.last_signal_log_ns = now_ns;
                std.log.info("bus playback audio active for {s}: bus={s} sink={s} peak={d:.3} frames={d}", .{
                    self.consumer_id,
                    self.bus_id,
                    self.target_sink_name,
                    peak,
                    written_frames,
                });
            }
        } else if (self.last_silence_log_ns == 0 or now_ns - self.last_silence_log_ns >= 2 * std.time.ns_per_s) {
            self.last_silence_log_ns = now_ns;
            std.log.info("bus playback audio silent for {s}: bus={s} sink={s} frames={d}", .{
                self.consumer_id,
                self.bus_id,
                self.target_sink_name,
                written_frames,
            });
        }
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
    const self: *BusPlaybackStream = @ptrCast(@alignCast(data orelse return));
    if (state == c.PW_STREAM_STATE_STREAMING or state == c.PW_STREAM_STATE_PAUSED) {
        std.log.info("bus playback stream state for {s}: {s}", .{
            self.consumer_id,
            if (state == c.PW_STREAM_STATE_STREAMING) "streaming" else "paused",
        });
    }
    if (state != c.PW_STREAM_STATE_ERROR) return;
    std.log.warn("bus playback stream error for {s} -> {s}: {s}", .{
        self.bus_id,
        self.target_sink_name,
        if (error_message) |msg| std.mem.span(msg) else "unknown",
    });
}

fn onStreamProcess(data: ?*anyopaque) callconv(.c) void {
    const self: *BusPlaybackStream = @ptrCast(@alignCast(data orelse return));
    self.process();
}
