const builtin = @import("builtin");
const std = @import("std");
const audio_engine_mod = @import("../audio/engine.zig");
const channels_mod = @import("../audio/channels.zig");
const fx_runtime_mod = @import("../../plugins/fx_runtime.zig");

const c = @cImport({
    @cInclude("pipewire/pipewire.h");
    @cInclude("pipewire/filter.h");
    @cInclude("pipewire/proxy.h");
    @cInclude("pipewire/stream.h");
    @cInclude("pipewire/thread-loop.h");
    @cInclude("pipewire/properties.h");
    @cInclude("pipewire/keys.h");
    @cInclude("spa/param/audio/dsp-utils.h");
    @cInclude("spa/pod/builder.h");
    @cInclude("spa_helpers.h");
});

const input_prefix = "wiredeck_input_";
const thread_name = "wiredeck-fx";
const max_block_frames: u32 = 4096;
const dsp_format = "32 bit float mono audio";
const node_interface_type = "PipeWire:Interface:Node";
const port_interface_type = "PipeWire:Interface:Port";
const filter_node_latency = "128/48000";
const process_diag_log_interval_ns: i128 = 5 * std.time.ns_per_s;
const callback_jitter_warn_threshold_ns: i128 = 8 * std.time.ns_per_ms;
const route_ready_grace_ns: i128 = 2500 * std.time.ns_per_ms;
const enable_fx_routing_info_logs = false;
const enable_fx_shutdown_summary_logs = false;
const enable_rt_process_diagnostics = false;
const enable_rt_signal_logging = false;
const ansi_red = "\x1b[31m";
const ansi_reset = "\x1b[0m";
const ChannelProcessStatus = fx_runtime_mod.FxRuntime.ChannelProcessStatus;

pub const InputPortKind = enum(u8) {
    monitor,
    capture,
    output,
};

pub const ChannelFxFilterManager = struct {
    const RegistryNode = struct {
        global_id: u32,
        name: []u8,
    };

    const RegistryPort = struct {
        global_id: u32,
        node_id: u32,
        name: []u8,
    };

    const LinkProxy = struct {
        proxy: ?*c.struct_pw_proxy = null,
        listener: c.struct_spa_hook = std.mem.zeroes(c.struct_spa_hook),
        bound: bool = false,
        failed: bool = false,
        role: []const u8 = "",
        channel_id: []const u8 = "",
    };

    const ManagedFilter = struct {
        const OutputTarget = struct {
            name_z: [:0]u8,
            left_link: LinkProxy = .{},
            right_link: LinkProxy = .{},

            fn deinit(self: *OutputTarget, allocator: std.mem.Allocator) void {
                destroyLinkProxy(&self.left_link);
                destroyLinkProxy(&self.right_link);
                allocator.free(self.name_z);
            }
        };

        manager: *ChannelFxFilterManager,
        engine: *audio_engine_mod.AudioEngine,
        runtime: *fx_runtime_mod.FxRuntime,
        requires_external_capture: bool,
        input_port_kind: InputPortKind,
        thread_loop: *c.struct_pw_thread_loop,
        filter: ?*c.struct_pw_filter = null,
        listener: c.struct_spa_hook = std.mem.zeroes(c.struct_spa_hook),
        drain_filter: ?*c.struct_pw_filter = null,
        drain_filter_listener: c.struct_spa_hook = std.mem.zeroes(c.struct_spa_hook),
        registry: ?*c.struct_pw_registry = null,
        registry_listener: c.struct_spa_hook = std.mem.zeroes(c.struct_spa_hook),
        drain_name_z: ?[:0]u8 = null,
        drain_in_left: ?*anyopaque = null,
        drain_in_right: ?*anyopaque = null,
        drain_left_link: LinkProxy = .{},
        drain_right_link: LinkProxy = .{},
        channel_id: []u8,
        name_z: [:0]u8,
        input_target_z: ?[:0]u8 = null,
        input_target_node_id: ?u32 = null,
        output_targets: std.ArrayList(OutputTarget),
        registry_nodes: std.ArrayList(RegistryNode),
        registry_ports: std.ArrayList(RegistryPort),
        ports_linked: bool = false,
        link_in_left: LinkProxy = .{},
        link_in_right: LinkProxy = .{},
        in_left: ?*anyopaque = null,
        in_right: ?*anyopaque = null,
        out_left: ?*anyopaque = null,
        out_right: ?*anyopaque = null,
        last_process_frames: u32 = 0,
        last_process_sample_rate_hz: u32 = 0,
        last_process_cycle_token: u64 = 0,
        last_process_started_ns: i128 = 0,
        last_process_log_ns: i128 = 0,
        last_input_signal_present: bool = false,
        last_ready_ns: i128 = 0,
        process_callback_count: u64 = 0,
        nonzero_process_count: u64 = 0,
        last_output_frames: u32 = 0,
        last_output_left: [max_block_frames]f32 = [_]f32{0.0} ** max_block_frames,
        last_output_right: [max_block_frames]f32 = [_]f32{0.0} ** max_block_frames,

        fn deinit(self: *ManagedFilter, allocator: std.mem.Allocator) void {
            cleanupManagedFilter(self, allocator, true);
        }
    };

    fn cleanupManagedFilter(filter: *ManagedFilter, allocator: std.mem.Allocator, destroy_self: bool) void {
        if (enable_fx_shutdown_summary_logs) {
            std.log.info("routing fx filter summary: channel={s} callbacks={d} nonzero_callbacks={d}", .{
                filter.channel_id,
                filter.process_callback_count,
                filter.nonzero_process_count,
            });
        }
        c.pw_thread_loop_lock(filter.thread_loop);
        destroyLinkProxy(&filter.link_in_left);
        destroyLinkProxy(&filter.link_in_right);
        destroyLinkProxy(&filter.drain_left_link);
        destroyLinkProxy(&filter.drain_right_link);
        for (filter.output_targets.items) |*output_target| output_target.deinit(allocator);
        c.spa_hook_remove(&filter.registry_listener);
        c.spa_hook_remove(&filter.listener);
        c.spa_hook_remove(&filter.drain_filter_listener);
        if (filter.registry) |registry| {
            c.pw_proxy_destroy(@ptrCast(registry));
            filter.registry = null;
        }
        if (filter.drain_filter) |pw_filter| {
            _ = c.pw_filter_disconnect(pw_filter);
            c.pw_filter_destroy(pw_filter);
            filter.drain_filter = null;
        }
        if (filter.filter) |pw_filter| {
            _ = c.pw_filter_disconnect(pw_filter);
            c.pw_filter_destroy(pw_filter);
            filter.filter = null;
        }
        c.pw_thread_loop_unlock(filter.thread_loop);
        c.pw_thread_loop_stop(filter.thread_loop);
        c.pw_thread_loop_destroy(filter.thread_loop);
        for (filter.registry_nodes.items) |node| allocator.free(node.name);
        filter.registry_nodes.deinit(allocator);
        for (filter.registry_ports.items) |port| allocator.free(port.name);
        filter.registry_ports.deinit(allocator);
        allocator.free(filter.channel_id);
        allocator.free(filter.name_z);
        if (filter.drain_name_z) |value| allocator.free(value);
        if (filter.input_target_z) |value| allocator.free(value);
        filter.output_targets.deinit(allocator);
        if (destroy_self) allocator.destroy(filter);
    }

    allocator: std.mem.Allocator,
    filters: std.ArrayList(*ManagedFilter),
    last_signature: u64 = 0,
    host_available: bool = true,
    pipewire_initialized: bool = false,

    pub fn init(allocator: std.mem.Allocator) ChannelFxFilterManager {
        return .{
            .allocator = allocator,
            .filters = .empty,
        };
    }

    pub fn deinit(self: *ChannelFxFilterManager) void {
        for (self.filters.items) |filter| filter.deinit(self.allocator);
        self.filters.deinit(self.allocator);
        if (self.pipewire_initialized) c.pw_deinit();
    }

    pub fn isHostAvailable(self: ChannelFxFilterManager) bool {
        return self.host_available;
    }

    pub fn reset(self: *ChannelFxFilterManager) void {
        for (self.filters.items) |filter| filter.deinit(self.allocator);
        self.filters.clearRetainingCapacity();
        self.last_signature = 0;
        self.host_available = true;
    }

    pub fn routeReady(self: *ChannelFxFilterManager, channel_id: []const u8) bool {
        const filter = findFilter(self.filters.items, channel_id) orelse return false;
        const thread_loop = filter.thread_loop;
        c.pw_thread_loop_lock(thread_loop);
        const ready = filter.ports_linked and filterLinksHealthy(filter);
        if (ready) filter.last_ready_ns = std.time.nanoTimestamp();
        const grace_ready = !ready and
            filter.last_ready_ns != 0 and
            std.time.nanoTimestamp() - filter.last_ready_ns <= route_ready_grace_ns;
        c.pw_thread_loop_unlock(thread_loop);
        if (ready) return true;
        if (grace_ready) return true;

        const relinked = self.tryConnectFilterPorts(filter) catch false;
        c.pw_thread_loop_lock(thread_loop);
        defer c.pw_thread_loop_unlock(thread_loop);
        filter.ports_linked = relinked;
        if (relinked and filterLinksHealthy(filter)) {
            filter.last_ready_ns = std.time.nanoTimestamp();
            if (enable_fx_routing_info_logs) std.log.info("routing fx links recovered on demand: channel={s}", .{filter.channel_id});
            return true;
        }
        if (filter.last_ready_ns != 0 and std.time.nanoTimestamp() - filter.last_ready_ns <= route_ready_grace_ns) {
            return true;
        }
        return false;
    }

    pub fn sync(
        self: *ChannelFxFilterManager,
        engine: *audio_engine_mod.AudioEngine,
        runtime: *fx_runtime_mod.FxRuntime,
        channels: []const channels_mod.Channel,
        route_specs: []const RouteSpec,
    ) !void {
        if (builtin.is_test or !self.host_available) return;
        if (!self.pipewire_initialized) {
            c.pw_init(null, null);
            self.pipewire_initialized = true;
        }

        const signature = computeSignature(channels, route_specs);
        if (signature == self.last_signature) {
            try self.ensurePortLinks();
            return;
        }

        var index = self.filters.items.len;
        while (index > 0) {
            index -= 1;
            const filter = self.filters.items[index];
            const desired_spec = findSpec(route_specs, filter.channel_id);
            if (desired_spec == null) {
                std.log.info(
                    "routing fx filter recreate: channel={s} old_input={s}:{s} old_node_id={any}",
                    .{
                        filter.channel_id,
                        @tagName(filter.input_port_kind),
                        if (filter.input_target_z) |value| value else "(none)",
                        filter.input_target_node_id,
                    },
                );
                const removed = self.filters.orderedRemove(index);
                removed.deinit(self.allocator);
                continue;
            }
            if (sameRouteSpec(filter, desired_spec.?)) continue;
            if (canRetargetFilterInputNode(filter, desired_spec.?)) {
                retargetFilterInputNode(filter, desired_spec.?);
                continue;
            }
            std.log.info(
                "routing fx filter recreate: channel={s} old_input={s}:{s} old_node_id={any}",
                .{
                    filter.channel_id,
                    @tagName(filter.input_port_kind),
                    if (filter.input_target_z) |value| value else "(none)",
                    filter.input_target_node_id,
                },
            );
            const removed = self.filters.orderedRemove(index);
            removed.deinit(self.allocator);
        }

        for (route_specs) |spec| {
            if (findFilter(self.filters.items, spec.channel_id) != null) continue;
            const filter = self.createFilter(engine, runtime, spec) catch |err| {
                self.host_available = false;
                return err;
            };
            try self.filters.append(self.allocator, filter);
        }

        try self.ensurePortLinks();
        logRouteSpecs(route_specs);
        self.last_signature = signature;
    }

    fn createFilter(
        self: *ChannelFxFilterManager,
        engine: *audio_engine_mod.AudioEngine,
        runtime: *fx_runtime_mod.FxRuntime,
        spec: RouteSpec,
    ) !*ManagedFilter {
        const managed = try self.allocator.create(ManagedFilter);
        errdefer self.allocator.destroy(managed);

        const filter_name = try std.fmt.allocPrint(self.allocator, "WireDeck FX {s}", .{spec.channel_id});
        defer self.allocator.free(filter_name);
        const filter_name_z = try self.allocator.dupeZ(u8, filter_name);
        errdefer self.allocator.free(filter_name_z);

        const input_target_z = if (spec.input_target_name) |input_target_name|
            try self.allocator.dupeZ(u8, input_target_name)
        else if (spec.requires_external_capture) blk: {
            const raw_input_sink = try allocInputSinkName(self.allocator, spec.channel_id);
            defer self.allocator.free(raw_input_sink);
            break :blk try self.allocator.dupeZ(u8, raw_input_sink);
        } else null;
        errdefer if (input_target_z) |value| self.allocator.free(value);

        var output_targets = std.ArrayList(ManagedFilter.OutputTarget).empty;
        errdefer {
            for (output_targets.items) |*output_target| output_target.deinit(self.allocator);
            output_targets.deinit(self.allocator);
        }
        for (spec.output_target_names) |output_target_name| {
            try output_targets.append(self.allocator, .{
                .name_z = try self.allocator.dupeZ(u8, output_target_name),
            });
        }

        const thread_loop = try createThreadLoop();
        errdefer {
            c.pw_thread_loop_stop(thread_loop);
            c.pw_thread_loop_destroy(thread_loop);
        }

        managed.* = .{
            .manager = self,
            .engine = engine,
            .runtime = runtime,
            .requires_external_capture = spec.requires_external_capture,
            .input_port_kind = spec.input_port_kind,
            .thread_loop = thread_loop,
            .channel_id = try self.allocator.dupe(u8, spec.channel_id),
            .name_z = filter_name_z,
            .input_target_z = input_target_z,
            .input_target_node_id = spec.input_target_node_id,
            .output_targets = output_targets,
            .registry_nodes = .empty,
            .registry_ports = .empty,
        };
        errdefer cleanupManagedFilter(managed, self.allocator, true);

        c.pw_thread_loop_lock(thread_loop);
        defer c.pw_thread_loop_unlock(thread_loop);

        const props = try makeFilterProperties(filter_name_z);
        errdefer c.pw_properties_free(props);
        const events = c.struct_pw_filter_events{
            .version = c.PW_VERSION_FILTER_EVENTS,
            .destroy = null,
            .state_changed = onStateChanged,
            .io_changed = null,
            .param_changed = null,
            .add_buffer = null,
            .remove_buffer = null,
            .process = onProcess,
            .drained = null,
            .command = null,
        };
        const filter = c.pw_filter_new_simple(
            c.pw_thread_loop_get_loop(thread_loop),
            managed.name_z.ptr,
            props,
            &events,
            managed,
        ) orelse return error.PipeWireFilterCreateFailed;
        managed.filter = filter;
        c.pw_filter_add_listener(filter, &managed.listener, &events, managed);

        managed.in_left = addPort(filter, c.PW_DIRECTION_INPUT, if (managed.input_target_z) |value| value.ptr else null, "in-L");
        managed.in_right = addPort(filter, c.PW_DIRECTION_INPUT, if (managed.input_target_z) |value| value.ptr else null, "in-R");
        managed.out_left = addPort(filter, c.PW_DIRECTION_OUTPUT, null, "out-L");
        managed.out_right = addPort(filter, c.PW_DIRECTION_OUTPUT, null, "out-R");
        if (managed.in_left == null or managed.in_right == null or managed.out_left == null or managed.out_right == null) {
            return error.PipeWireFilterPortCreateFailed;
        }

        if (c.pw_filter_connect(filter, c.PW_FILTER_FLAG_RT_PROCESS, null, 0) < 0) return error.PipeWireFilterConnectFailed;
        const core = c.pw_filter_get_core(filter) orelse return error.PipeWireCoreUnavailable;
        const registry = c.pw_core_get_registry(core, c.PW_VERSION_REGISTRY, 0) orelse return error.PipeWireRegistryUnavailable;
        managed.registry = registry;
        _ = c.pw_registry_add_listener(registry, &managed.registry_listener, &registry_events, managed);
        _ = c.pw_filter_set_active(filter, true);
        if (spec.output_target_names.len == 0) {
            try createInternalDrainStream(managed);
        }
        if (enable_fx_routing_info_logs) {
            std.log.info(
                "routing fx filter created: channel={s} input={s}:{s} node_id={any} outputs={d}",
                .{
                    managed.channel_id,
                    @tagName(spec.input_port_kind),
                    spec.input_target_name orelse "(none)",
                    spec.input_target_node_id,
                    spec.output_target_names.len,
                },
            );
        }
        return managed;
    }

    fn ensurePortLinks(self: *ChannelFxFilterManager) !void {
        for (self.filters.items) |filter| {
            if (filter.ports_linked) continue;
            const linked = try self.tryConnectFilterPorts(filter);
            if (linked and !filter.ports_linked) {
                if (enable_fx_routing_info_logs) std.log.info("routing fx links ready: channel={s}", .{filter.channel_id});
            }
            filter.ports_linked = linked;
        }
    }

    fn refreshLinkProxy(link: *ChannelFxFilterManager.LinkProxy) void {
        if (link.proxy != null and !link.bound) {
            destroyLinkProxy(link);
        }
    }

    fn tryConnectFilterPorts(self: *ChannelFxFilterManager, filter: *ManagedFilter) !bool {
        _ = self;
        c.pw_thread_loop_lock(filter.thread_loop);
        defer c.pw_thread_loop_unlock(filter.thread_loop);

        const filter_node_id = findNodeId(filter.registry_nodes.items, filter.name_z) orelse return false;

        const filter_in_left = findPortId(filter.registry_ports.items, filter_node_id, "in-L") orelse return false;
        const filter_in_right = findPortId(filter.registry_ports.items, filter_node_id, "in-R") orelse return false;
        const filter_out_left = findPortId(filter.registry_ports.items, filter_node_id, "out-L") orelse return false;
        const filter_out_right = findPortId(filter.registry_ports.items, filter_node_id, "out-R") orelse return false;

        if (filter.input_target_z) |input_target_z| {
            const input_node_id = if (filter.input_target_node_id) |node_id|
                node_id
            else
                findNodeId(filter.registry_nodes.items, input_target_z) orelse return false;
            const input_left_name = switch (filter.input_port_kind) {
                .monitor => "monitor_FL",
                .capture => "capture_FL",
                .output => "output_FL",
            };
            const input_right_name = switch (filter.input_port_kind) {
                .monitor => "monitor_FR",
                .capture => "capture_FR",
                .output => "output_FR",
            };
            const input_left = findPortId(filter.registry_ports.items, input_node_id, input_left_name) orelse return false;
            const input_right = findPortId(filter.registry_ports.items, input_node_id, input_right_name) orelse return false;

            refreshLinkProxy(&filter.link_in_left);
            refreshLinkProxy(&filter.link_in_right);
            if (filter.link_in_left.proxy == null and !filter.link_in_left.failed) {
                filter.link_in_left.role = "input-left";
                filter.link_in_left.channel_id = filter.channel_id;
                createLinkProxy(filter, &filter.link_in_left, input_node_id, input_left, filter_node_id, filter_in_left) catch {
                    filter.link_in_left.failed = true;
                };
            }
            if (filter.link_in_right.proxy == null and !filter.link_in_right.failed) {
                filter.link_in_right.role = "input-right";
                filter.link_in_right.channel_id = filter.channel_id;
                createLinkProxy(filter, &filter.link_in_right, input_node_id, input_right, filter_node_id, filter_in_right) catch {
                    filter.link_in_right.failed = true;
                };
            }
        } else {
            filter.link_in_left.bound = true;
            filter.link_in_right.bound = true;
            filter.link_in_left.failed = false;
            filter.link_in_right.failed = false;
        }

        for (filter.output_targets.items) |*output_target| {
            const output_node_id = findNodeId(filter.registry_nodes.items, output_target.name_z) orelse return false;
            const output_left = findPortId(filter.registry_ports.items, output_node_id, "playback_FL") orelse return false;
            const output_right = findPortId(filter.registry_ports.items, output_node_id, "playback_FR") orelse return false;

            refreshLinkProxy(&output_target.left_link);
            refreshLinkProxy(&output_target.right_link);
            if (output_target.left_link.proxy == null and !output_target.left_link.failed) {
                output_target.left_link.role = "output-left";
                output_target.left_link.channel_id = filter.channel_id;
                createLinkProxy(filter, &output_target.left_link, filter_node_id, filter_out_left, output_node_id, output_left) catch {
                    output_target.left_link.failed = true;
                };
            }
            if (output_target.right_link.proxy == null and !output_target.right_link.failed) {
                output_target.right_link.role = "output-right";
                output_target.right_link.channel_id = filter.channel_id;
                createLinkProxy(filter, &output_target.right_link, filter_node_id, filter_out_right, output_node_id, output_right) catch {
                    output_target.right_link.failed = true;
                };
            }
        }

        var outputs_ready = true;
        if (filter.output_targets.items.len == 0) {
            const drain_left_name_z = filter.drain_name_z orelse return false;
            const drain_left_node_id = findNodeId(filter.registry_nodes.items, drain_left_name_z) orelse return false;
            const drain_left = findPortId(filter.registry_ports.items, drain_left_node_id, "in-L") orelse return false;
            const drain_right = findPortId(filter.registry_ports.items, drain_left_node_id, "in-R") orelse return false;

            refreshLinkProxy(&filter.drain_left_link);
            refreshLinkProxy(&filter.drain_right_link);
            if (filter.drain_left_link.proxy == null and !filter.drain_left_link.failed) {
                filter.drain_left_link.role = "drain-left";
                filter.drain_left_link.channel_id = filter.channel_id;
                createLinkProxy(filter, &filter.drain_left_link, filter_node_id, filter_out_left, drain_left_node_id, drain_left) catch {
                    filter.drain_left_link.failed = true;
                };
            }
            if (filter.drain_right_link.proxy == null and !filter.drain_right_link.failed) {
                filter.drain_right_link.role = "drain-right";
                filter.drain_right_link.channel_id = filter.channel_id;
                createLinkProxy(filter, &filter.drain_right_link, filter_node_id, filter_out_right, drain_left_node_id, drain_right) catch {
                    filter.drain_right_link.failed = true;
                };
            }
            outputs_ready = filter.drain_left_link.bound and filter.drain_right_link.bound;
        } else {
            for (filter.output_targets.items) |output_target| {
                outputs_ready = outputs_ready and output_target.left_link.bound and output_target.right_link.bound;
            }
        }

        return filter.link_in_left.bound and
            filter.link_in_right.bound and
            outputs_ready;
    }
};

fn createThreadLoop() !*c.struct_pw_thread_loop {
    const thread_loop = c.pw_thread_loop_new(thread_name, null) orelse return error.PipeWireThreadLoopFailed;
    errdefer c.pw_thread_loop_destroy(thread_loop);
    if (c.pw_thread_loop_start(thread_loop) < 0) return error.PipeWireThreadLoopFailed;
    return thread_loop;
}

pub const RouteSpec = struct {
    channel_id: []const u8,
    requires_external_capture: bool,
    input_target_name: ?[]const u8 = null,
    input_target_node_id: ?u32 = null,
    input_port_kind: InputPortKind = .monitor,
    output_target_names: []const []const u8 = &.{},
};

fn computeSignature(
    channels: []const channels_mod.Channel,
    route_specs: []const RouteSpec,
) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (channels) |channel| {
        hasher.update(channel.id);
        hasher.update(std.mem.asBytes(&[_]u8{
            @intFromFloat(@round(channel.volume * 100.0)),
            @intFromBool(channel.muted),
        }));
    }
    for (route_specs) |spec| {
        hasher.update(spec.channel_id);
        hasher.update(&[_]u8{@intFromBool(spec.requires_external_capture)});
        hasher.update(&[_]u8{@intFromEnum(spec.input_port_kind)});
        hasher.update(std.mem.asBytes(&spec.input_target_node_id));
        if (spec.input_target_name) |input_target_name| hasher.update(input_target_name);
        hasher.update(&[_]u8{0xff});
        for (spec.output_target_names) |output_target_name| {
            hasher.update(output_target_name);
            hasher.update(&[_]u8{0});
        }
        hasher.update(&[_]u8{1});
    }
    return hasher.final();
}

fn findSpec(specs: []const RouteSpec, channel_id: []const u8) ?RouteSpec {
    for (specs) |spec| {
        if (std.mem.eql(u8, spec.channel_id, channel_id)) return spec;
    }
    return null;
}

fn sameRouteSpec(filter: *const ChannelFxFilterManager.ManagedFilter, spec: RouteSpec) bool {
    if (filter.requires_external_capture != spec.requires_external_capture) return false;
    if (filter.input_port_kind != spec.input_port_kind) return false;
    if (filter.input_target_node_id != spec.input_target_node_id) return false;
    if (!sameRouteSpecIgnoringInputNodeId(filter, spec)) return false;
    return true;
}

fn canRetargetFilterInputNode(filter: *const ChannelFxFilterManager.ManagedFilter, spec: RouteSpec) bool {
    if (!sameRouteSpecIgnoringInputNodeId(filter, spec)) return false;
    return filter.input_target_node_id != spec.input_target_node_id;
}

fn sameRouteSpecIgnoringInputNodeId(filter: *const ChannelFxFilterManager.ManagedFilter, spec: RouteSpec) bool {
    if (filter.requires_external_capture != spec.requires_external_capture) return false;
    if (filter.input_port_kind != spec.input_port_kind) return false;
    if (spec.input_target_name) |input_target_name| {
        const filter_input_target = filter.input_target_z orelse return false;
        if (!std.mem.eql(u8, filter_input_target, input_target_name)) return false;
    } else if (filter.input_target_z != null) {
        return false;
    }
    if (filter.output_targets.items.len != spec.output_target_names.len) return false;
    for (filter.output_targets.items, spec.output_target_names) |output_target, output_target_name| {
        if (!std.mem.eql(u8, output_target.name_z, output_target_name)) return false;
    }
    return true;
}

fn retargetFilterInputNode(filter: *ChannelFxFilterManager.ManagedFilter, spec: RouteSpec) void {
    const old_node_id = filter.input_target_node_id;
    filter.input_target_node_id = spec.input_target_node_id;
    filter.ports_linked = false;

    c.pw_thread_loop_lock(filter.thread_loop);
    defer c.pw_thread_loop_unlock(filter.thread_loop);
    destroyLinkProxy(&filter.link_in_left);
    destroyLinkProxy(&filter.link_in_right);

    if (enable_fx_routing_info_logs) {
        std.log.info(
            "routing fx filter retarget: channel={s} input={s}:{s} old_node_id={any} new_node_id={any}",
            .{
                filter.channel_id,
                @tagName(filter.input_port_kind),
                if (filter.input_target_z) |value| value else "(none)",
                old_node_id,
                spec.input_target_node_id,
            },
        );
    }
}

fn logRouteSpecs(route_specs: []const RouteSpec) void {
    if (!enable_fx_routing_info_logs) return;
    std.log.info("routing fx sync: channels={d}", .{route_specs.len});
    for (route_specs) |spec| {
        var buffer: [512]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buffer);
        const writer = stream.writer();

        for (spec.output_target_names, 0..) |target_name, index| {
            if (index > 0) writer.writeAll(",") catch break;
            writer.writeAll(target_name) catch break;
        }

        const targets = if (stream.pos == 0) "(none)" else stream.getWritten();
        const input_target = spec.input_target_name orelse "(none)";
        std.log.info(
            "routing fx channel={s} capture={s} input={s}:{s} targets={d} [{s}]",
            .{
                spec.channel_id,
                if (spec.requires_external_capture) "external" else "internal",
                @tagName(spec.input_port_kind),
                input_target,
                spec.output_target_names.len,
                targets,
            },
        );
    }
}

fn findFilter(filters: []const *ChannelFxFilterManager.ManagedFilter, channel_id: []const u8) ?*ChannelFxFilterManager.ManagedFilter {
    for (filters) |filter| {
        if (std.mem.eql(u8, filter.channel_id, channel_id)) return filter;
    }
    return null;
}

fn findNodeId(nodes: []const ChannelFxFilterManager.RegistryNode, node_name: []const u8) ?u32 {
    for (nodes) |node| {
        if (std.mem.eql(u8, node.name, node_name)) return node.global_id;
    }
    return null;
}

fn findPortId(ports: []const ChannelFxFilterManager.RegistryPort, node_id: u32, port_name: []const u8) ?u32 {
    for (ports) |port| {
        if (port.node_id != node_id) continue;
        if (std.mem.eql(u8, port.name, port_name)) return port.global_id;
    }
    return null;
}

fn findFirstPortIdByNames(
    ports: []const ChannelFxFilterManager.RegistryPort,
    node_id: u32,
    port_names: []const []const u8,
) ?u32 {
    for (port_names) |port_name| {
        if (findPortId(ports, node_id, port_name)) |port_id| return port_id;
    }
    return null;
}

fn findChannel(channels: []const channels_mod.Channel, channel_id: []const u8) ?channels_mod.Channel {
    for (channels) |channel| {
        if (std.mem.eql(u8, channel.id, channel_id)) return channel;
    }
    return null;
}

fn allocInputSinkName(allocator: std.mem.Allocator, channel_id: []const u8) ![]u8 {
    var sink_name = try allocator.alloc(u8, input_prefix.len + channel_id.len);
    @memcpy(sink_name[0..input_prefix.len], input_prefix);
    for (channel_id, input_prefix.len..) |char, index| {
        sink_name[index] = if (std.ascii.isAlphanumeric(char)) std.ascii.toLower(char) else '_';
    }
    return sink_name;
}

fn makeFilterProperties(name_z: [:0]const u8) !*c.struct_pw_properties {
    const props = c.pw_properties_new(null);
    if (props == null) return error.OutOfMemory;
    _ = c.pw_properties_set(props, c.PW_KEY_NODE_NAME, name_z.ptr);
    _ = c.pw_properties_set(props, c.PW_KEY_NODE_DESCRIPTION, name_z.ptr);
    _ = c.pw_properties_set(props, c.PW_KEY_MEDIA_NAME, name_z.ptr);
    _ = c.pw_properties_set(props, "node.hidden", "true");
    _ = c.pw_properties_set(props, "node.autoconnect", "false");
    _ = c.pw_properties_set(props, c.PW_KEY_NODE_PASSIVE, "true");
    _ = c.pw_properties_set(props, "node.want-driver", "false");
    _ = c.pw_properties_set(props, "node.dont-reconnect", "true");
    _ = c.pw_properties_set(props, "node.latency", filter_node_latency);
    _ = c.pw_properties_set(props, c.PW_KEY_MEDIA_CLASS, "Audio/Filter");
    return props;
}

const drain_filter_events = c.struct_pw_filter_events{
    .version = c.PW_VERSION_FILTER_EVENTS,
    .destroy = null,
    .state_changed = onDrainFilterStateChanged,
    .io_changed = null,
    .param_changed = null,
    .add_buffer = null,
    .remove_buffer = null,
    .process = onDrainFilterProcess,
    .drained = null,
    .command = null,
};

fn createInternalDrainStream(filter: *ChannelFxFilterManager.ManagedFilter) !void {
    const drain_name = try std.fmt.allocPrint(filter.manager.allocator, "wiredeck_fx_drain_{s}", .{filter.channel_id});
    defer filter.manager.allocator.free(drain_name);
    const drain_name_z = try filter.manager.allocator.dupeZ(u8, drain_name);

    const props = try makeFilterProperties(drain_name_z);
    errdefer c.pw_properties_free(props);
    const drain_filter = c.pw_filter_new_simple(
        c.pw_thread_loop_get_loop(filter.thread_loop),
        drain_name_z.ptr,
        props,
        &drain_filter_events,
        filter,
    ) orelse return error.PipeWireFilterCreateFailed;
    errdefer c.pw_filter_destroy(drain_filter);

    filter.drain_name_z = drain_name_z;
    filter.drain_filter = drain_filter;
    errdefer {
        filter.manager.allocator.free(drain_name_z);
        filter.drain_name_z = null;
        filter.drain_filter = null;
    }

    c.pw_filter_add_listener(drain_filter, &filter.drain_filter_listener, &drain_filter_events, filter);
    filter.drain_in_left = addPort(drain_filter, c.PW_DIRECTION_INPUT, null, "in-L");
    filter.drain_in_right = addPort(drain_filter, c.PW_DIRECTION_INPUT, null, "in-R");
    if (filter.drain_in_left == null or filter.drain_in_right == null) {
        return error.PipeWireFilterPortCreateFailed;
    }
    if (c.pw_filter_connect(drain_filter, c.PW_FILTER_FLAG_RT_PROCESS, null, 0) < 0) {
        return error.PipeWireFilterConnectFailed;
    }
    if (c.pw_filter_set_active(drain_filter, true) < 0) {
        return error.PipeWireFilterConnectFailed;
    }
}

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

fn createLinkProxy(
    filter: *ChannelFxFilterManager.ManagedFilter,
    link: *ChannelFxFilterManager.LinkProxy,
    output_node_id: u32,
    output_port_id: u32,
    input_node_id: u32,
    input_port_id: u32,
) !void {
    const pw_filter = filter.filter orelse return error.PipeWireFilterCreateFailed;
    const core = c.pw_filter_get_core(pw_filter) orelse return error.PipeWireCoreUnavailable;
    const props = c.pw_properties_new(null) orelse return error.OutOfMemory;
    errdefer c.pw_properties_free(props);
    _ = c.pw_properties_setf(props, c.PW_KEY_LINK_OUTPUT_NODE, "%u", output_node_id);
    _ = c.pw_properties_setf(props, c.PW_KEY_LINK_OUTPUT_PORT, "%u", output_port_id);
    _ = c.pw_properties_setf(props, c.PW_KEY_LINK_INPUT_NODE, "%u", input_node_id);
    _ = c.pw_properties_setf(props, c.PW_KEY_LINK_INPUT_PORT, "%u", input_port_id);
    _ = c.pw_properties_set(props, c.PW_KEY_OBJECT_LINGER, "false");

    const proxy = c.pw_core_create_object(
        core,
        "link-factory",
        c.PW_TYPE_INTERFACE_Link,
        c.PW_VERSION_LINK,
        &props.*.dict,
        0,
    ) orelse return error.PipeWireLinkCreateFailed;
    link.proxy = @ptrCast(proxy);
    link.bound = false;
    link.failed = false;
    c.pw_proxy_add_listener(link.proxy.?, &link.listener, &proxy_events, link);
}

fn destroyLinkProxy(link: *ChannelFxFilterManager.LinkProxy) void {
    c.spa_hook_remove(&link.listener);
    if (link.proxy) |value| c.pw_proxy_destroy(value);
    link.proxy = null;
    link.bound = false;
    link.failed = false;
}

fn onLinkProxyDestroy(data: ?*anyopaque) callconv(.c) void {
    _ = data;
}

fn onLinkProxyBound(data: ?*anyopaque, _: u32) callconv(.c) void {
    if (data == null) return;
    const link: *ChannelFxFilterManager.LinkProxy = @ptrCast(@alignCast(data));
    link.bound = true;
    link.failed = false;
    if (enable_fx_routing_info_logs) std.log.info("routing fx link bound: channel={s} role={s}", .{ link.channel_id, link.role });
}

fn onLinkProxyRemoved(data: ?*anyopaque) callconv(.c) void {
    if (data == null) return;
    const link: *ChannelFxFilterManager.LinkProxy = @ptrCast(@alignCast(data));
    link.bound = false;
    if (enable_fx_routing_info_logs) std.log.info("routing fx link removed: channel={s} role={s}", .{ link.channel_id, link.role });
}

fn onDrainFilterStateChanged(
    data: ?*anyopaque,
    _: c.enum_pw_filter_state,
    state: c.enum_pw_filter_state,
    error_message: ?[*:0]const u8,
) callconv(.c) void {
    const filter: *ChannelFxFilterManager.ManagedFilter = @ptrCast(@alignCast(data orelse return));
    if (state == c.PW_FILTER_STATE_ERROR) {
        std.log.warn("routing fx drain error: channel={s} message={s}", .{
            filter.channel_id,
            if (error_message) |msg| std.mem.span(msg) else "unknown",
        });
    }
}

fn onDrainFilterProcess(data: ?*anyopaque, position: ?*c.struct_spa_io_position) callconv(.c) void {
    const filter: *ChannelFxFilterManager.ManagedFilter = @ptrCast(@alignCast(data orelse return));
    const frames: u32 = blk: {
        const pos = position orelse break :blk max_block_frames;
        const duration = @as(usize, @intCast(pos.clock.duration));
        if (duration == 0 or duration > max_block_frames) break :blk max_block_frames;
        break :blk @intCast(duration);
    };
    _ = c.pw_filter_get_dsp_buffer(filter.drain_in_left, frames);
    _ = c.pw_filter_get_dsp_buffer(filter.drain_in_right, frames);
}

fn onLinkProxyError(data: ?*anyopaque, seq: c_int, res: c_int, message: [*c]const u8) callconv(.c) void {
    if (data == null) return;
    const link: *ChannelFxFilterManager.LinkProxy = @ptrCast(@alignCast(data));
    link.failed = true;
    link.bound = false;
    std.log.warn("routing fx link error: channel={s} role={s} seq={d} res={d} message={s}", .{
        link.channel_id,
        link.role,
        seq,
        res,
        std.mem.span(message),
    });
}

fn onRegistryGlobal(
    data: ?*anyopaque,
    id: u32,
    _: u32,
    type_name: [*c]const u8,
    _: u32,
    props: ?*const c.struct_spa_dict,
) callconv(.c) void {
    if (data == null or type_name == null or props == null) return;
    const filter: *ChannelFxFilterManager.ManagedFilter = @ptrCast(@alignCast(data));
    const type_slice = std.mem.span(type_name);
    if (std.mem.eql(u8, type_slice, node_interface_type)) {
        const node_name_ptr = c.spa_dict_lookup(props, c.PW_KEY_NODE_NAME) orelse return;
        const node_name = std.mem.span(node_name_ptr);
        appendOrUpdateRegistryNode(filter, id, node_name) catch {};
        return;
    }
    if (std.mem.eql(u8, type_slice, port_interface_type)) {
        const node_id_ptr = c.spa_dict_lookup(props, c.PW_KEY_NODE_ID) orelse return;
        const port_name_ptr = c.spa_dict_lookup(props, c.PW_KEY_PORT_NAME) orelse return;
        const node_id = std.fmt.parseInt(u32, std.mem.span(node_id_ptr), 10) catch return;
        const port_name = std.mem.span(port_name_ptr);
        appendOrUpdateRegistryPort(filter, id, node_id, port_name) catch {};
    }
}

fn onRegistryGlobalRemove(data: ?*anyopaque, id: u32) callconv(.c) void {
    if (data == null) return;
    const filter: *ChannelFxFilterManager.ManagedFilter = @ptrCast(@alignCast(data));
    removeRegistryNode(filter, id);
    removeRegistryPort(filter, id);
    if (filter.ports_linked and !filterLinksHealthy(filter)) {
        filter.ports_linked = false;
        if (enable_fx_routing_info_logs) std.log.info("routing fx links lost: channel={s} removed_global_id={d}", .{ filter.channel_id, id });
    }
}

fn filterLinksHealthy(filter: *const ChannelFxFilterManager.ManagedFilter) bool {
    if (!filter.link_in_left.bound or !filter.link_in_right.bound) return false;
    if (filter.output_targets.items.len == 0) {
        return filter.drain_filter != null and
            filter.drain_left_link.bound and
            filter.drain_right_link.bound;
    }
    for (filter.output_targets.items) |output_target| {
        if (!output_target.left_link.bound or !output_target.right_link.bound) return false;
    }
    return true;
}

fn appendOrUpdateRegistryNode(filter: *ChannelFxFilterManager.ManagedFilter, id: u32, name: []const u8) !void {
    for (filter.registry_nodes.items) |*entry| {
        if (entry.global_id != id) continue;
        if (std.mem.eql(u8, entry.name, name)) return;
        filter.manager.allocator.free(entry.name);
        entry.name = try filter.manager.allocator.dupe(u8, name);
        return;
    }
    try filter.registry_nodes.append(filter.manager.allocator, .{
        .global_id = id,
        .name = try filter.manager.allocator.dupe(u8, name),
    });
}

fn appendOrUpdateRegistryPort(filter: *ChannelFxFilterManager.ManagedFilter, id: u32, node_id: u32, name: []const u8) !void {
    for (filter.registry_ports.items) |*entry| {
        if (entry.global_id != id) continue;
        if (entry.node_id == node_id and std.mem.eql(u8, entry.name, name)) return;
        filter.manager.allocator.free(entry.name);
        entry.node_id = node_id;
        entry.name = try filter.manager.allocator.dupe(u8, name);
        return;
    }
    try filter.registry_ports.append(filter.manager.allocator, .{
        .global_id = id,
        .node_id = node_id,
        .name = try filter.manager.allocator.dupe(u8, name),
    });
}

fn removeRegistryNode(filter: *ChannelFxFilterManager.ManagedFilter, id: u32) void {
    var index: usize = 0;
    while (index < filter.registry_nodes.items.len) {
        if (filter.registry_nodes.items[index].global_id != id) {
            index += 1;
            continue;
        }
        const removed = filter.registry_nodes.orderedRemove(index);
        filter.manager.allocator.free(removed.name);
        break;
    }
}

fn removeRegistryPort(filter: *ChannelFxFilterManager.ManagedFilter, id: u32) void {
    var index: usize = 0;
    while (index < filter.registry_ports.items.len) {
        if (filter.registry_ports.items[index].global_id != id) {
            index += 1;
            continue;
        }
        const removed = filter.registry_ports.orderedRemove(index);
        filter.manager.allocator.free(removed.name);
        break;
    }
}

fn addPort(filter: *c.struct_pw_filter, direction: c.enum_spa_direction, target_object: ?[*:0]const u8, label: []const u8) ?*anyopaque {
    const props = c.pw_properties_new(null) orelse return null;
    const label_z = std.heap.page_allocator.dupeZ(u8, label) catch {
        c.pw_properties_free(props);
        return null;
    };
    defer std.heap.page_allocator.free(label_z);
    _ = c.pw_properties_set(props, c.PW_KEY_PORT_NAME, label_z.ptr);
    if (target_object) |value| _ = c.pw_properties_set(props, c.PW_KEY_TARGET_OBJECT, value);
    _ = c.pw_properties_set(props, c.PW_KEY_NODE_PASSIVE, "true");
    _ = c.pw_properties_set(props, c.PW_KEY_FORMAT_DSP, dsp_format);
    return c.pw_filter_add_port(filter, direction, c.PW_FILTER_PORT_FLAG_MAP_BUFFERS, 0, props, null, 0);
}

fn onStateChanged(data: ?*anyopaque, _: c.enum_pw_filter_state, state: c.enum_pw_filter_state, _: ?[*:0]const u8) callconv(.c) void {
    if (data == null) return;
    const filter: *ChannelFxFilterManager.ManagedFilter = @ptrCast(@alignCast(data));
    if (state != c.PW_FILTER_STATE_ERROR) return;
    filter.manager.host_available = false;
}

fn onProcess(data: ?*anyopaque, position: ?*c.struct_spa_io_position) callconv(.c) void {
    if (data == null) return;
    const filter: *ChannelFxFilterManager.ManagedFilter = @ptrCast(@alignCast(data));
    const runtime = filter.runtime;
    filter.process_callback_count += 1;
    const process_started_ns = if (enable_rt_process_diagnostics) std.time.nanoTimestamp() else 0;
    const position_missing = position == null;
    const invalid_duration = blk: {
        const pos = position orelse break :blk false;
        const duration = @as(usize, @intCast(pos.clock.duration));
        break :blk duration == 0 or duration > max_block_frames;
    };
    const frames: u32 = blk: {
        const pos = position orelse break :blk max_block_frames;
        const duration = @as(usize, @intCast(pos.clock.duration));
        if (duration == 0 or duration > max_block_frames) break :blk max_block_frames;
        break :blk @intCast(duration);
    };
    const in_left = c.pw_filter_get_dsp_buffer(filter.in_left, frames) orelse return;
    const in_right = c.pw_filter_get_dsp_buffer(filter.in_right, frames) orelse return;
    const out_left = c.pw_filter_get_dsp_buffer(filter.out_left, frames) orelse return;
    const out_right = c.pw_filter_get_dsp_buffer(filter.out_right, frames) orelse return;

    const left = @as([*]f32, @ptrCast(@alignCast(in_left)))[0..frames];
    const right = @as([*]f32, @ptrCast(@alignCast(in_right)))[0..frames];
    const out_l = @as([*]f32, @ptrCast(@alignCast(out_left)))[0..frames];
    const out_r = @as([*]f32, @ptrCast(@alignCast(out_right)))[0..frames];

    const sample_rate_hz: u32 = blk: {
        const pos = position orelse break :blk 0;
        const rate_num = pos.clock.rate.num;
        const rate_denom = pos.clock.rate.denom;
        if (rate_num == 0 or rate_denom == 0) break :blk 0;
        break :blk @intCast(rate_denom / rate_num);
    };
    const cycle_token: u64 = blk: {
        const pos = position orelse break :blk 0;
        break :blk @intCast(pos.clock.position);
    };

    if (enable_rt_process_diagnostics) {
        if (position_missing) {
            logProcessDiagnostic(filter, "missing PipeWire position; using fallback quantum", .{});
        } else if (invalid_duration) {
            logProcessDiagnostic(filter, "invalid quantum from PipeWire: duration={d}; using fallback={d}", .{
                position.?.clock.duration,
                max_block_frames,
            });
        }
        if (sample_rate_hz == 0) {
            logProcessDiagnostic(filter, "invalid sample rate in process callback; rate.num={d} rate.denom={d}", .{
                if (position) |pos| pos.clock.rate.num else 0,
                if (position) |pos| pos.clock.rate.denom else 0,
            });
        }
        if (filter.last_process_frames != 0 and frames != filter.last_process_frames) {
            logProcessDiagnostic(filter, "quantum changed: prev={d} now={d} cycle={d}", .{
                filter.last_process_frames,
                frames,
                cycle_token,
            });
        }
        if (filter.last_process_sample_rate_hz != 0 and sample_rate_hz != 0 and sample_rate_hz != filter.last_process_sample_rate_hz) {
            logProcessDiagnostic(filter, "sample rate changed: prev={d} now={d} cycle={d}", .{
                filter.last_process_sample_rate_hz,
                sample_rate_hz,
                cycle_token,
            });
        }
        const cycle_drift_frames: ?u64 = blk: {
            if (filter.last_process_cycle_token == 0 or cycle_token == 0 or filter.last_process_frames == 0) break :blk null;
            const expected_next_cycle = filter.last_process_cycle_token + filter.last_process_frames;
            if (cycle_token >= expected_next_cycle) break :blk cycle_token - expected_next_cycle;
            break :blk expected_next_cycle - cycle_token;
        };

        if (filter.last_process_started_ns != 0 and filter.last_process_frames != 0 and sample_rate_hz != 0) {
            const expected_interval_ns = framesToNanoseconds(filter.last_process_frames, sample_rate_hz);
            const actual_interval_ns = process_started_ns - filter.last_process_started_ns;
            const interval_delta_ns = absoluteDelta(actual_interval_ns, expected_interval_ns);
            if (interval_delta_ns > callback_jitter_warn_threshold_ns and
                (cycle_drift_frames == null or cycle_drift_frames.? != 0))
            {
                logProcessDiagnostic(filter, "callback interval jitter: prev_frames={d} expected_ns={d} actual_ns={d} delta_ns={d}", .{
                    filter.last_process_frames,
                    expected_interval_ns,
                    actual_interval_ns,
                    interval_delta_ns,
                });
            }
        }
        if (cycle_drift_frames) |drift| {
            if (drift != 0) {
                const expected_next_cycle = filter.last_process_cycle_token + filter.last_process_frames;
                logProcessDiagnostic(filter, "cycle drift: prev_cycle={d} expected={d} actual={d} drift={d} frames={d}", .{
                    filter.last_process_cycle_token,
                    expected_next_cycle,
                    cycle_token,
                    drift,
                    frames,
                });
            }
        }
    }

    if (enable_rt_signal_logging) {
        var input_peak_abs: f32 = 0.0;
        for (0..frames) |index| {
            input_peak_abs = @max(input_peak_abs, @abs(left[index]));
            input_peak_abs = @max(input_peak_abs, @abs(right[index]));
        }
        if (input_peak_abs > 0.00001) filter.nonzero_process_count += 1;
        const input_signal_present = input_peak_abs > 0.00001;
        if (input_signal_present != filter.last_input_signal_present) {
            std.log.info(
                "routing fx signal: channel={s} input={s}:{s} state={s} peak={d:.6} frames={d} cycle={d}",
                .{
                    filter.channel_id,
                    @tagName(filter.input_port_kind),
                    if (filter.input_target_z) |value| value else "(none)",
                    if (input_signal_present) "present" else "silent",
                    input_peak_abs,
                    frames,
                    cycle_token,
                },
            );
            filter.last_input_signal_present = input_signal_present;
        }
    }
    if (!enable_rt_signal_logging) {
        for (0..frames) |index| {
            if (@abs(left[index]) > 0.00001 or @abs(right[index]) > 0.00001) {
                filter.nonzero_process_count += 1;
                break;
            }
        }
    }

    const populate_started_ns = if (enable_rt_process_diagnostics) std.time.nanoTimestamp() else 0;
    _ = filter.engine.populateChannelInput(filter.channel_id, left, right, sample_rate_hz);
    const populate_duration_ns = if (enable_rt_process_diagnostics) std.time.nanoTimestamp() - populate_started_ns else 0;

    const sample_rate_change = sample_rate_hz != 0 and sample_rate_hz != filter.last_process_sample_rate_hz;
    const set_sample_rate_started_ns = if (enable_rt_process_diagnostics) std.time.nanoTimestamp() else 0;
    if (sample_rate_change) {
        runtime.setSampleRate(sample_rate_hz);
    }
    const set_sample_rate_duration_ns = if (enable_rt_process_diagnostics) std.time.nanoTimestamp() - set_sample_rate_started_ns else 0;

    const fx_started_ns = if (enable_rt_process_diagnostics) std.time.nanoTimestamp() else 0;
    const process_status = filter.engine.processChannelStatus(runtime, filter.channel_id, left, right, sample_rate_hz, cycle_token);
    const fx_duration_ns = if (enable_rt_process_diagnostics) std.time.nanoTimestamp() - fx_started_ns else 0;

    const copy_started_ns = if (enable_rt_process_diagnostics) std.time.nanoTimestamp() else 0;
    writeProcessOutput(filter, process_status, left, right, out_l, out_r);
    const copy_duration_ns = if (enable_rt_process_diagnostics) std.time.nanoTimestamp() - copy_started_ns else 0;

    const process_duration_ns = if (enable_rt_process_diagnostics) std.time.nanoTimestamp() - process_started_ns else 0;
    if (enable_rt_process_diagnostics and sample_rate_hz != 0) {
        const budget_ns = framesToNanoseconds(frames, sample_rate_hz);
        if (process_duration_ns > budget_ns) {
            logProcessDiagnostic(filter, "process over budget: frames={d} budget_ns={d} actual_ns={d} populate_ns={d} set_rate_ns={d} set_rate_changed={any} fx_ns={d} copy_ns={d}", .{
                frames,
                budget_ns,
                process_duration_ns,
                populate_duration_ns,
                set_sample_rate_duration_ns,
                sample_rate_change,
                fx_duration_ns,
                copy_duration_ns,
            });
        }
    }

    filter.last_process_frames = frames;
    filter.last_process_sample_rate_hz = sample_rate_hz;
    filter.last_process_cycle_token = cycle_token;
    filter.last_process_started_ns = process_started_ns;
}

fn writeProcessOutput(
    filter: *ChannelFxFilterManager.ManagedFilter,
    process_status: ChannelProcessStatus,
    left: []const f32,
    right: []const f32,
    out_left: []f32,
    out_right: []f32,
) void {
    switch (process_status) {
        .processed, .bypass_no_chain => {
            for (0..left.len) |index| {
                out_left[index] = left[index];
                out_right[index] = right[index];
                filter.last_output_left[index] = left[index];
                filter.last_output_right[index] = right[index];
            }
            filter.last_output_frames = @intCast(left.len);
        },
        .bypass_busy, .bypass_failed => {
            if (filter.last_output_frames == left.len) {
                for (0..left.len) |index| {
                    out_left[index] = filter.last_output_left[index];
                    out_right[index] = filter.last_output_right[index];
                }
                return;
            }
            for (0..left.len) |index| {
                out_left[index] = left[index];
                out_right[index] = right[index];
            }
        },
    }
}

fn logProcessDiagnostic(
    filter: *ChannelFxFilterManager.ManagedFilter,
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (!enable_rt_process_diagnostics) return;
    const now_ns = std.time.nanoTimestamp();
    if (filter.last_process_log_ns != 0 and now_ns - filter.last_process_log_ns < process_diag_log_interval_ns) return;
    filter.last_process_log_ns = now_ns;
    std.log.warn(ansi_red ++ "fx process diag channel={s}: " ++ fmt ++ ansi_reset, .{filter.channel_id} ++ args);
}

fn framesToNanoseconds(frames: u32, sample_rate_hz: u32) i128 {
    if (frames == 0 or sample_rate_hz == 0) return 0;
    return @divTrunc(@as(i128, frames) * std.time.ns_per_s, @as(i128, sample_rate_hz));
}

fn absoluteDelta(actual: i128, expected: i128) i128 {
    return if (actual >= expected) actual - expected else expected - actual;
}
