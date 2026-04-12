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
    const startup_buffer_blocks: usize = 2;
    const underrun_warn_log_interval_ns: i128 = 1000 * std.time.ns_per_ms;
    const max_process_frames: usize = 2048;
    const dsp_format = "32 bit float mono audio";
    const filter_node_latency = "128/48000";

    const LinkProxy = struct {
        proxy: ?*c.struct_pw_proxy = null,
        listener: c.struct_spa_hook = std.mem.zeroes(c.struct_spa_hook),
        bound: bool = false,
    };

    allocator: std.mem.Allocator,
    engine: *audio_engine_mod.AudioEngine,
    bus_id: []u8,
    consumer_id: []u8,
    source_name: []u8,
    description: []u8,
    main_loop: ?*c.struct_pw_main_loop = null,
    context: ?*c.struct_pw_context = null,
    core: ?*c.struct_pw_core = null,
    source_proxy: ?*c.struct_pw_proxy = null,
    filter: ?*c.struct_pw_filter = null,
    registry: ?*c.struct_pw_registry = null,
    listener: c.struct_spa_hook = std.mem.zeroes(c.struct_spa_hook),
    registry_listener: c.struct_spa_hook = std.mem.zeroes(c.struct_spa_hook),
    out_left: ?*anyopaque = null,
    out_right: ?*anyopaque = null,
    source_node_id: u32 = 0,
    feeder_node_id: u32 = 0,
    source_input_left_port_id: u32 = 0,
    source_input_right_port_id: u32 = 0,
    feeder_output_left_port_id: u32 = 0,
    feeder_output_right_port_id: u32 = 0,
    left_link: LinkProxy = .{},
    right_link: LinkProxy = .{},
    thread: ?std.Thread = null,
    feeder_thread: ?std.Thread = null,
    pipewire_initialized: bool = false,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    buffering: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    requested_quantum_frames: std.atomic.Value(u32) = std.atomic.Value(u32).init(bus_buffer_mod.render_quantum_frames),
    buffer_mutex: std.Thread.Mutex = .{},
    process_callback_count: u64 = 0,
    nonzero_callback_count: u64 = 0,
    underrun_count: u64 = 0,
    last_underrun_log_ns: i128 = 0,
    pcm_buffer: bus_buffer_mod.BusConsumerBuffer,

    pub fn init(
        allocator: std.mem.Allocator,
        engine: *audio_engine_mod.AudioEngine,
        bus_id: []const u8,
        consumer_id: []const u8,
        source_name: []const u8,
        description: []const u8,
    ) !*VirtualMicSource {
        const self = try allocator.create(VirtualMicSource);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .engine = engine,
            .bus_id = try allocator.dupe(u8, bus_id),
            .consumer_id = try allocator.dupe(u8, consumer_id),
            .source_name = try allocator.dupe(u8, source_name),
            .description = try allocator.dupe(u8, description),
            .pcm_buffer = bus_buffer_mod.BusConsumerBuffer.init(allocator),
        };
        errdefer {
            self.pcm_buffer.deinit();
            allocator.free(self.description);
            allocator.free(self.source_name);
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

        const loop = c.pw_main_loop_get_loop(self.main_loop.?);
        self.context = c.pw_context_new(loop, null, 0) orelse return error.PipeWireContextInitFailed;
        errdefer {
            c.pw_context_destroy(self.context);
            self.context = null;
        }

        self.core = c.pw_context_connect(self.context, null, 0) orelse return error.PipeWireCoreConnectFailed;
        errdefer {
            _ = c.pw_core_disconnect(self.core);
            self.core = null;
        }

        const consumer_id_z = try allocator.dupeZ(u8, consumer_id);
        defer allocator.free(consumer_id_z);
        const source_name_z = try allocator.dupeZ(u8, source_name);
        defer allocator.free(source_name_z);
        const description_z = try allocator.dupeZ(u8, description);
        defer allocator.free(description_z);
        const feeder_description = try std.fmt.allocPrint(allocator, "WireDeck Virtual Mic Feeder {s}", .{bus_id});
        defer allocator.free(feeder_description);
        const feeder_description_z = try allocator.dupeZ(u8, feeder_description);
        defer allocator.free(feeder_description_z);

        const source_props = c.pw_properties_new(null) orelse return error.OutOfMemory;
        errdefer c.pw_properties_free(source_props);
        _ = c.pw_properties_set(source_props, "factory.name", "support.null-audio-sink");
        _ = c.pw_properties_set(source_props, c.PW_KEY_MEDIA_TYPE, "Audio");
        _ = c.pw_properties_set(source_props, c.PW_KEY_MEDIA_CATEGORY, "Capture");
        _ = c.pw_properties_set(source_props, c.PW_KEY_MEDIA_ROLE, "Communication");
        _ = c.pw_properties_set(source_props, c.PW_KEY_MEDIA_CLASS, "Audio/Source/Virtual");
        _ = c.pw_properties_set(source_props, c.PW_KEY_MEDIA_NAME, description_z.ptr);
        _ = c.pw_properties_set(source_props, c.PW_KEY_NODE_NAME, source_name_z.ptr);
        _ = c.pw_properties_set(source_props, c.PW_KEY_NODE_DESCRIPTION, description_z.ptr);
        _ = c.pw_properties_set(source_props, "node.nick", description_z.ptr);
        _ = c.pw_properties_set(source_props, "device.description", description_z.ptr);
        _ = c.pw_properties_set(source_props, "audio.position", "FL,FR");
        _ = c.pw_properties_set(source_props, "monitor.passthrough", "true");
        _ = c.pw_properties_set(source_props, "node.virtual", "true");
        _ = c.pw_properties_set(source_props, "node.pause-on-idle", "false");
        _ = c.pw_properties_set(source_props, "node.suspend-on-idle", "false");
        _ = c.pw_properties_set(source_props, "node.latency", filter_node_latency);
        _ = c.pw_properties_set(source_props, c.PW_KEY_PRIORITY_SESSION, "1000");

        self.source_proxy = @ptrCast(c.pw_core_create_object(
            self.core,
            "adapter",
            c.PW_TYPE_INTERFACE_Node,
            c.PW_VERSION_NODE,
            &source_props.*.dict,
            0,
        ) orelse return error.PipeWireVirtualMicSourceCreateFailed);

        const props = c.pw_properties_new(null) orelse return error.OutOfMemory;
        errdefer c.pw_properties_free(props);
        _ = c.pw_properties_set(props, c.PW_KEY_MEDIA_TYPE, "Audio");
        _ = c.pw_properties_set(props, c.PW_KEY_MEDIA_CATEGORY, "Playback");
        _ = c.pw_properties_set(props, c.PW_KEY_MEDIA_ROLE, "DSP");
        _ = c.pw_properties_set(props, c.PW_KEY_MEDIA_CLASS, "Audio/Filter");
        _ = c.pw_properties_set(props, c.PW_KEY_MEDIA_NAME, feeder_description_z.ptr);
        _ = c.pw_properties_set(props, c.PW_KEY_NODE_NAME, consumer_id_z.ptr);
        _ = c.pw_properties_set(props, c.PW_KEY_NODE_DESCRIPTION, feeder_description_z.ptr);
        _ = c.pw_properties_set(props, "node.hidden", "true");
        _ = c.pw_properties_set(props, "node.dont-reconnect", "true");
        _ = c.pw_properties_set(props, "node.dont-fallback", "true");
        _ = c.pw_properties_set(props, "node.pause-on-idle", "false");
        _ = c.pw_properties_set(props, "node.always-process", "true");
        _ = c.pw_properties_set(props, "node.latency", filter_node_latency);
        _ = c.pw_properties_set(props, c.PW_KEY_NODE_PASSIVE, "true");

        const events = c.struct_pw_filter_events{
            .version = c.PW_VERSION_FILTER_EVENTS,
            .destroy = null,
            .state_changed = onFilterStateChanged,
            .io_changed = null,
            .param_changed = null,
            .add_buffer = null,
            .remove_buffer = null,
            .process = onFilterProcess,
            .drained = null,
            .command = null,
        };

        self.filter = c.pw_filter_new_simple(
            c.pw_main_loop_get_loop(self.main_loop.?),
            consumer_id_z.ptr,
            props,
            &events,
            self,
        ) orelse return error.PipeWireVirtualMicStreamCreateFailed;
        errdefer {
            c.pw_filter_destroy(self.filter);
            self.filter = null;
        }

        c.pw_filter_add_listener(self.filter, &self.listener, &events, self);
        self.out_left = addFilterPort(self.filter.?, c.PW_DIRECTION_OUTPUT, source_name_z.ptr, "out-FL", "FL");
        self.out_right = addFilterPort(self.filter.?, c.PW_DIRECTION_OUTPUT, source_name_z.ptr, "out-FR", "FR");
        if (self.out_left == null or self.out_right == null) return error.PipeWireVirtualMicConnectFailed;

        const rc = c.pw_filter_connect(
            self.filter,
            c.PW_FILTER_FLAG_RT_PROCESS,
            null,
            0,
        );
        if (rc < 0) return error.PipeWireVirtualMicConnectFailed;
        if (c.pw_filter_set_active(self.filter, true) < 0) {
            return error.PipeWireVirtualMicConnectFailed;
        }

        self.registry = c.pw_core_get_registry(self.core.?, c.PW_VERSION_REGISTRY, 0) orelse return error.PipeWireRegistryUnavailable;
        _ = c.pw_registry_add_listener(self.registry, &self.registry_listener, &registry_events, self);

        self.thread = try std.Thread.spawn(.{}, loopMain, .{self});
        self.feeder_thread = try std.Thread.spawn(.{}, feederMain, .{self});
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
        if (self.feeder_thread) |thread| {
            thread.join();
            self.feeder_thread = null;
        }
        destroyLinkProxy(&self.left_link);
        destroyLinkProxy(&self.right_link);
        c.spa_hook_remove(&self.registry_listener);
        c.spa_hook_remove(&self.listener);
        if (self.filter) |filter| {
            _ = c.pw_filter_disconnect(filter);
            c.pw_filter_destroy(filter);
            self.filter = null;
        }
        if (self.registry) |registry| {
            c.pw_proxy_destroy(@ptrCast(registry));
            self.registry = null;
        }
        if (self.source_proxy) |proxy| {
            c.pw_proxy_destroy(proxy);
            self.source_proxy = null;
        }
        if (self.core) |core| {
            _ = c.pw_core_disconnect(core);
            self.core = null;
        }
        if (self.context) |context| {
            c.pw_context_destroy(context);
            self.context = null;
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
        self.pcm_buffer.deinit();
        self.allocator.free(self.description);
        self.allocator.free(self.source_name);
        self.allocator.free(self.consumer_id);
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

    fn feederMain(self: *VirtualMicSource) void {
        var scratch_buffer: [bus_buffer_mod.render_quantum_frames * bus_buffer_mod.stereo_channels]i16 = undefined;
        var next_tick_ns = std.time.nanoTimestamp();
        while (!self.stop_requested.load(.acquire)) {
            const quantum_frames = self.currentQuantumFrames();
            const target_buffer_frames = targetBufferFramesForQuantum(quantum_frames);
            self.buffer_mutex.lock();
            _ = self.pcm_buffer.fillFromEngine(
                self.engine,
                self.bus_id,
                self.consumer_id,
                target_buffer_frames,
                scratch_buffer[0..],
            ) catch {};
            const buffered_frames = self.pcm_buffer.availableFrames();
            self.buffer_mutex.unlock();

            const step_ns: u64 = if (buffered_frames < target_buffer_frames / 2)
                @max(@as(u64, 1), bus_buffer_mod.render_quantum_ns / 2)
            else
                bus_buffer_mod.render_quantum_ns;
            next_tick_ns +%= step_ns;
            const now_ns = std.time.nanoTimestamp();
            if (next_tick_ns > now_ns) {
                std.Thread.sleep(@intCast(next_tick_ns - now_ns));
            } else {
                next_tick_ns = now_ns;
            }
        }
    }

    fn process(self: *VirtualMicSource) void {
        self.process_callback_count += 1;
        const frames = self.currentQuantumFrames();
        const target_buffer_frames = targetBufferFramesForQuantum(frames);
        var interleaved: [max_process_frames * 2]i16 = undefined;
        const left_buf = c.pw_filter_get_dsp_buffer(self.out_left, @intCast(frames)) orelse return;
        const right_buf = c.pw_filter_get_dsp_buffer(self.out_right, @intCast(frames)) orelse return;
        const left = @as([*]f32, @ptrCast(@alignCast(left_buf)))[0..frames];
        const right = @as([*]f32, @ptrCast(@alignCast(right_buf)))[0..frames];
        @memset(left, 0);
        @memset(right, 0);

        self.buffer_mutex.lock();
        const buffered_frames = self.pcm_buffer.availableFrames();
        const was_buffering = self.buffering.load(.acquire);
        var buffering = was_buffering;
        if (buffering and buffered_frames >= target_buffer_frames) {
            buffering = false;
            self.buffering.store(false, .release);
        }

        var written_frames: usize = 0;
        if (!buffering) {
            written_frames = self.pcm_buffer.drainFrames(interleaved[0 .. frames * 2], frames);
            if (written_frames < frames) {
                self.buffering.store(true, .release);
            }
        }
        self.buffer_mutex.unlock();

        if (!buffering and written_frames < frames) {
            self.underrunCountAndMaybeWarn(frames, written_frames, buffered_frames);
        }
        for (0..written_frames) |frame_index| {
            const left_sample = interleaved[frame_index * 2];
            const right_sample = interleaved[frame_index * 2 + 1];
            left[frame_index] = @as(f32, @floatFromInt(left_sample)) / 32768.0;
            right[frame_index] = @as(f32, @floatFromInt(right_sample)) / 32768.0;
            if (left_sample != 0 or right_sample != 0) {
                self.nonzero_callback_count += 1;
            }
        }
    }

    fn underrunCountAndMaybeWarn(self: *VirtualMicSource, requested_frames: usize, drained_frames: usize, buffered_frames: usize) void {
        self.underrun_count += 1;
        const now_ns = std.time.nanoTimestamp();
        if (self.last_underrun_log_ns != 0 and now_ns - self.last_underrun_log_ns < underrun_warn_log_interval_ns) return;
        self.last_underrun_log_ns = now_ns;
        std.log.warn(
            "virtual mic underrun: bus={s} source={s} requested_frames={d} drained_frames={d} buffered_frames={d} underruns={d}",
            .{
                self.bus_id,
                self.source_name,
                requested_frames,
                drained_frames,
                buffered_frames,
                self.underrun_count,
            },
        );
    }

    fn currentQuantumFrames(self: *VirtualMicSource) usize {
        return clampProcessFrames(self.requested_quantum_frames.load(.acquire));
    }
};

const filter_events = c.struct_pw_filter_events{
    .version = c.PW_VERSION_FILTER_EVENTS,
    .destroy = null,
    .state_changed = onFilterStateChanged,
    .control_info = null,
    .io_changed = null,
    .param_changed = null,
    .add_buffer = null,
    .remove_buffer = null,
    .process = onFilterProcess,
    .drained = null,
    .command = null,
};

const proxy_events = c.struct_pw_proxy_events{
    .version = c.PW_VERSION_PROXY_EVENTS,
    .destroy = onLinkProxyDestroy,
    .bound = onLinkProxyBound,
    .removed = onLinkProxyRemoved,
    .done = null,
    .@"error" = onLinkProxyError,
    .bound_props = null,
};

const registry_events = c.struct_pw_registry_events{
    .version = c.PW_VERSION_REGISTRY_EVENTS,
    .global = onRegistryGlobal,
    .global_remove = onRegistryGlobalRemove,
};

fn onFilterStateChanged(
    data: ?*anyopaque,
    _: c.enum_pw_filter_state,
    state: c.enum_pw_filter_state,
    error_message: ?[*:0]const u8,
) callconv(.c) void {
    const self: *VirtualMicSource = @ptrCast(@alignCast(data orelse return));
    self.active.store(state == c.PW_FILTER_STATE_STREAMING or state == c.PW_FILTER_STATE_PAUSED, .monotonic);
    if (state == c.PW_FILTER_STATE_STREAMING or state == c.PW_FILTER_STATE_PAUSED) {
        if (enable_virtual_mic_info_logs) {
            std.log.info("virtual mic source state for {s}: {s}", .{
                self.source_name,
                if (state == c.PW_FILTER_STATE_STREAMING) "streaming" else "paused",
            });
        }
    }
    if (state == c.PW_FILTER_STATE_ERROR) {
        std.log.warn("virtual mic source error for {s}: {s}", .{
            self.bus_id,
            if (error_message) |msg| std.mem.span(msg) else "unknown",
        });
    }
}

fn onFilterProcess(data: ?*anyopaque, position: ?*c.struct_spa_io_position) callconv(.c) void {
    const self: *VirtualMicSource = @ptrCast(@alignCast(data orelse return));
    const frames = processFrameCount(position);
    self.requested_quantum_frames.store(@intCast(frames), .release);
    self.process();
}

fn processFrameCount(position: ?*c.struct_spa_io_position) usize {
    const pos = position orelse return bus_buffer_mod.render_quantum_frames;
    return clampProcessFrames(pos.clock.duration);
}

fn clampProcessFrames(raw_frames: anytype) usize {
    const frames: usize = @intCast(raw_frames);
    return std.math.clamp(frames, @as(usize, 1), VirtualMicSource.max_process_frames);
}

fn targetBufferFramesForQuantum(quantum_frames: usize) usize {
    return std.math.clamp(
        quantum_frames * VirtualMicSource.startup_buffer_blocks,
        quantum_frames,
        VirtualMicSource.max_process_frames * VirtualMicSource.startup_buffer_blocks,
    );
}

fn onRegistryGlobal(
    data: ?*anyopaque,
    id: u32,
    _: u32,
    type_name: [*c]const u8,
    _: u32,
    props: ?*const c.struct_spa_dict,
) callconv(.c) void {
    const self: *VirtualMicSource = @ptrCast(@alignCast(data orelse return));
    if (props == null) return;
    const type_slice = std.mem.span(type_name);
    if (std.mem.eql(u8, type_slice, "PipeWire:Interface:Node")) {
        const node_name_ptr = c.spa_dict_lookup(props, c.PW_KEY_NODE_NAME) orelse return;
        const node_name = std.mem.span(node_name_ptr);
        if (std.mem.eql(u8, node_name, self.source_name)) {
            self.source_node_id = id;
        } else if (std.mem.eql(u8, node_name, self.consumer_id)) {
            self.feeder_node_id = id;
        }
        tryEnsureLinks(self);
        return;
    }
    if (!std.mem.eql(u8, type_slice, "PipeWire:Interface:Port")) return;
    const node_id_ptr = c.spa_dict_lookup(props, c.PW_KEY_NODE_ID) orelse return;
    const node_id = std.fmt.parseInt(u32, std.mem.span(node_id_ptr), 10) catch return;
    const direction_ptr = c.spa_dict_lookup(props, c.PW_KEY_PORT_DIRECTION) orelse return;
    const direction = std.mem.span(direction_ptr);
    const channel_ptr = c.spa_dict_lookup(props, "audio.channel") orelse return;
    const channel = std.mem.span(channel_ptr);
    if (node_id == self.source_node_id and std.mem.eql(u8, direction, "in")) {
        if (std.mem.eql(u8, channel, "FL")) self.source_input_left_port_id = id;
        if (std.mem.eql(u8, channel, "FR")) self.source_input_right_port_id = id;
    } else if (node_id == self.feeder_node_id and std.mem.eql(u8, direction, "out")) {
        if (std.mem.eql(u8, channel, "FL")) self.feeder_output_left_port_id = id;
        if (std.mem.eql(u8, channel, "FR")) self.feeder_output_right_port_id = id;
    }
    tryEnsureLinks(self);
}

fn onRegistryGlobalRemove(data: ?*anyopaque, id: u32) callconv(.c) void {
    const self: *VirtualMicSource = @ptrCast(@alignCast(data orelse return));
    if (id == self.source_node_id) self.source_node_id = 0;
    if (id == self.feeder_node_id) self.feeder_node_id = 0;
    if (id == self.source_input_left_port_id) self.source_input_left_port_id = 0;
    if (id == self.source_input_right_port_id) self.source_input_right_port_id = 0;
    if (id == self.feeder_output_left_port_id) self.feeder_output_left_port_id = 0;
    if (id == self.feeder_output_right_port_id) self.feeder_output_right_port_id = 0;
}

fn onLinkProxyDestroy(data: ?*anyopaque) callconv(.c) void {
    _ = data;
}

fn onLinkProxyBound(data: ?*anyopaque, _: u32) callconv(.c) void {
    const link: *VirtualMicSource.LinkProxy = @ptrCast(@alignCast(data orelse return));
    link.bound = true;
}

fn onLinkProxyRemoved(data: ?*anyopaque) callconv(.c) void {
    const link: *VirtualMicSource.LinkProxy = @ptrCast(@alignCast(data orelse return));
    link.bound = false;
}

fn onLinkProxyError(data: ?*anyopaque, _: c_int, _: c_int, message: [*c]const u8) callconv(.c) void {
    const link: *VirtualMicSource.LinkProxy = @ptrCast(@alignCast(data orelse return));
    link.bound = false;
    std.log.warn("virtual mic link error: bus={s} source={s} message={s}", .{
        "unknown",
        "unknown",
        std.mem.span(message),
    });
}

fn addFilterPort(filter: *c.struct_pw_filter, direction: c.enum_spa_direction, target_object: [*:0]const u8, label: []const u8, channel: []const u8) ?*anyopaque {
    const props = c.pw_properties_new(null) orelse return null;
    const label_z = std.heap.page_allocator.dupeZ(u8, label) catch {
        c.pw_properties_free(props);
        return null;
    };
    defer std.heap.page_allocator.free(label_z);
    const channel_z = std.heap.page_allocator.dupeZ(u8, channel) catch {
        c.pw_properties_free(props);
        return null;
    };
    defer std.heap.page_allocator.free(channel_z);
    _ = c.pw_properties_set(props, c.PW_KEY_PORT_NAME, label_z.ptr);
    _ = c.pw_properties_set(props, c.PW_KEY_TARGET_OBJECT, target_object);
    _ = c.pw_properties_set(props, c.PW_KEY_NODE_PASSIVE, "true");
    _ = c.pw_properties_set(props, c.PW_KEY_FORMAT_DSP, VirtualMicSource.dsp_format);
    _ = c.pw_properties_set(props, "audio.channel", channel_z.ptr);
    return c.pw_filter_add_port(filter, direction, c.PW_FILTER_PORT_FLAG_MAP_BUFFERS, 0, props, null, 0);
}

fn destroyLinkProxy(link: *VirtualMicSource.LinkProxy) void {
    c.spa_hook_remove(&link.listener);
    if (link.proxy) |value| c.pw_proxy_destroy(value);
    link.proxy = null;
    link.bound = false;
}

fn createLinkProxy(self: *VirtualMicSource, link: *VirtualMicSource.LinkProxy, output_node_id: u32, output_port_id: u32, input_node_id: u32, input_port_id: u32) !void {
    const props = c.pw_properties_new(null) orelse return error.OutOfMemory;
    errdefer c.pw_properties_free(props);
    _ = c.pw_properties_setf(props, c.PW_KEY_LINK_OUTPUT_NODE, "%u", output_node_id);
    _ = c.pw_properties_setf(props, c.PW_KEY_LINK_OUTPUT_PORT, "%u", output_port_id);
    _ = c.pw_properties_setf(props, c.PW_KEY_LINK_INPUT_NODE, "%u", input_node_id);
    _ = c.pw_properties_setf(props, c.PW_KEY_LINK_INPUT_PORT, "%u", input_port_id);
    _ = c.pw_properties_set(props, c.PW_KEY_OBJECT_LINGER, "false");
    const proxy = c.pw_core_create_object(
        self.core,
        "link-factory",
        c.PW_TYPE_INTERFACE_Link,
        c.PW_VERSION_LINK,
        &props.*.dict,
        0,
    ) orelse return error.PipeWireLinkCreateFailed;
    link.proxy = @ptrCast(proxy);
    link.bound = false;
    c.pw_proxy_add_listener(link.proxy.?, &link.listener, &proxy_events, link);
}

fn tryEnsureLinks(self: *VirtualMicSource) void {
    if (self.source_node_id == 0 or self.feeder_node_id == 0) return;
    if (self.source_input_left_port_id == 0 or self.source_input_right_port_id == 0) return;
    if (self.feeder_output_left_port_id == 0 or self.feeder_output_right_port_id == 0) return;
    if (self.left_link.proxy == null) {
        createLinkProxy(self, &self.left_link, self.feeder_node_id, self.feeder_output_left_port_id, self.source_node_id, self.source_input_left_port_id) catch {};
    }
    if (self.right_link.proxy == null) {
        createLinkProxy(self, &self.right_link, self.feeder_node_id, self.feeder_output_right_port_id, self.source_node_id, self.source_input_right_port_id) catch {};
    }
}
