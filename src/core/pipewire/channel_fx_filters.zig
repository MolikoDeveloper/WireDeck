const builtin = @import("builtin");
const std = @import("std");
const channel_sources_mod = @import("../audio/channel_sources.zig");
const channels_mod = @import("../audio/channels.zig");
const sources_mod = @import("../audio/sources.zig");
const fx_runtime_mod = @import("../../plugins/fx_runtime.zig");

const c = @cImport({
    @cInclude("pipewire/pipewire.h");
    @cInclude("pipewire/filter.h");
    @cInclude("pipewire/proxy.h");
    @cInclude("pipewire/thread-loop.h");
    @cInclude("pipewire/properties.h");
    @cInclude("pipewire/keys.h");
    @cInclude("spa/param/audio/dsp-utils.h");
    @cInclude("spa/pod/builder.h");
});

const input_prefix = "wiredeck_input_";
const fx_prefix = "wiredeck_fx_";
const thread_name = "wiredeck-fx";
const max_block_frames: u32 = 4096;
const dsp_format = "32 bit float mono audio";
const node_interface_type = "PipeWire:Interface:Node";
const port_interface_type = "PipeWire:Interface:Port";

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
        manager: *ChannelFxFilterManager,
        runtime: *fx_runtime_mod.FxRuntime,
        thread_loop: *c.struct_pw_thread_loop,
        filter: *c.struct_pw_filter,
        listener: c.struct_spa_hook = std.mem.zeroes(c.struct_spa_hook),
        registry: ?*c.struct_pw_registry = null,
        registry_listener: c.struct_spa_hook = std.mem.zeroes(c.struct_spa_hook),
        channel_id: []u8,
        name_z: [:0]u8,
        raw_monitor_z: [:0]u8,
        processed_sink_z: [:0]u8,
        registry_nodes: std.ArrayList(RegistryNode),
        registry_ports: std.ArrayList(RegistryPort),
        ports_linked: bool = false,
        link_in_left: LinkProxy = .{},
        link_in_right: LinkProxy = .{},
        link_out_left: LinkProxy = .{},
        link_out_right: LinkProxy = .{},
        in_left: ?*anyopaque = null,
        in_right: ?*anyopaque = null,
        out_left: ?*anyopaque = null,
        out_right: ?*anyopaque = null,

        fn deinit(self: *ManagedFilter, allocator: std.mem.Allocator) void {
            c.pw_thread_loop_lock(self.thread_loop);
            destroyLinkProxy(&self.link_in_left);
            destroyLinkProxy(&self.link_in_right);
            destroyLinkProxy(&self.link_out_left);
            destroyLinkProxy(&self.link_out_right);
            if (self.registry) |registry| c.pw_proxy_destroy(@ptrCast(registry));
            _ = c.pw_filter_disconnect(self.filter);
            c.pw_filter_destroy(self.filter);
            c.pw_thread_loop_unlock(self.thread_loop);
            c.pw_thread_loop_stop(self.thread_loop);
            c.pw_thread_loop_destroy(self.thread_loop);
            for (self.registry_nodes.items) |node| allocator.free(node.name);
            self.registry_nodes.deinit(allocator);
            for (self.registry_ports.items) |port| allocator.free(port.name);
            self.registry_ports.deinit(allocator);
            allocator.free(self.channel_id);
            allocator.free(self.name_z);
            allocator.free(self.raw_monitor_z);
            allocator.free(self.processed_sink_z);
            allocator.destroy(self);
        }
    };

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

    pub fn sync(
        self: *ChannelFxFilterManager,
        runtime: *fx_runtime_mod.FxRuntime,
        channels: []const channels_mod.Channel,
        sources: []const sources_mod.Source,
        channel_sources: []const channel_sources_mod.ChannelSource,
        fx_channels: []const channels_mod.Channel,
    ) !void {
        if (builtin.is_test or !self.host_available) return;
        if (!self.pipewire_initialized) {
            c.pw_init(null, null);
            self.pipewire_initialized = true;
        }

        const signature = computeSignature(channels, sources, channel_sources, fx_channels);
        if (signature == self.last_signature) {
            try self.ensurePortLinks();
            return;
        }

        var desired = std.ArrayList(RouteSpec).empty;
        defer desired.deinit(self.allocator);
        try buildDesired(self.allocator, &desired, channels, sources, channel_sources, fx_channels);

        var index = self.filters.items.len;
        while (index > 0) {
            index -= 1;
            const filter = self.filters.items[index];
            if (!containsSpec(desired.items, filter.channel_id)) {
                const removed = self.filters.orderedRemove(index);
                removed.deinit(self.allocator);
            }
        }

        for (desired.items) |spec| {
            if (findFilter(self.filters.items, spec.channel_id) != null) continue;
            const filter = self.createFilter(runtime, spec) catch |err| {
                self.host_available = false;
                return err;
            };
            try self.filters.append(self.allocator, filter);
        }

        try self.ensurePortLinks();
        self.last_signature = signature;
    }

    fn createFilter(self: *ChannelFxFilterManager, runtime: *fx_runtime_mod.FxRuntime, spec: RouteSpec) !*ManagedFilter {
        const managed = try self.allocator.create(ManagedFilter);
        errdefer self.allocator.destroy(managed);

        const filter_name = try std.fmt.allocPrint(self.allocator, "WireDeck FX {s}", .{spec.channel_id});
        defer self.allocator.free(filter_name);
        const filter_name_z = try self.allocator.dupeZ(u8, filter_name);
        errdefer self.allocator.free(filter_name_z);
        const raw_input_sink = try allocInputSinkName(self.allocator, spec.channel_id);
        defer self.allocator.free(raw_input_sink);
        const raw_input_sink_z = try self.allocator.dupeZ(u8, raw_input_sink);
        errdefer self.allocator.free(raw_input_sink_z);
        const processed_sink = try allocProcessedSinkName(self.allocator, spec.channel_id);
        defer self.allocator.free(processed_sink);
        const processed_sink_z = try self.allocator.dupeZ(u8, processed_sink);
        errdefer self.allocator.free(processed_sink_z);

        const thread_loop = c.pw_thread_loop_new(thread_name, null) orelse return error.PipeWireThreadLoopFailed;
        errdefer c.pw_thread_loop_destroy(thread_loop);
        if (c.pw_thread_loop_start(thread_loop) < 0) return error.PipeWireThreadLoopFailed;
        errdefer {
            c.pw_thread_loop_stop(thread_loop);
            c.pw_thread_loop_destroy(thread_loop);
        }

        managed.* = .{
            .manager = self,
            .runtime = runtime,
            .thread_loop = thread_loop,
            .filter = undefined,
            .channel_id = try self.allocator.dupe(u8, spec.channel_id),
            .name_z = filter_name_z,
            .raw_monitor_z = raw_input_sink_z,
            .processed_sink_z = processed_sink_z,
            .registry_nodes = .empty,
            .registry_ports = .empty,
        };
        errdefer self.allocator.free(managed.channel_id);

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

        managed.in_left = addPort(filter, c.PW_DIRECTION_INPUT, managed.raw_monitor_z.ptr, "in-L");
        managed.in_right = addPort(filter, c.PW_DIRECTION_INPUT, managed.raw_monitor_z.ptr, "in-R");
        managed.out_left = addPort(filter, c.PW_DIRECTION_OUTPUT, managed.processed_sink_z.ptr, "out-L");
        managed.out_right = addPort(filter, c.PW_DIRECTION_OUTPUT, managed.processed_sink_z.ptr, "out-R");

        if (c.pw_filter_connect(filter, c.PW_FILTER_FLAG_RT_PROCESS, null, 0) < 0) return error.PipeWireFilterConnectFailed;
        const core = c.pw_filter_get_core(filter) orelse return error.PipeWireCoreUnavailable;
        const registry = c.pw_core_get_registry(core, c.PW_VERSION_REGISTRY, 0) orelse return error.PipeWireRegistryUnavailable;
        managed.registry = registry;
        _ = c.pw_registry_add_listener(registry, &managed.registry_listener, &registry_events, managed);
        _ = c.pw_filter_set_active(filter, true);
        return managed;
    }

    fn ensurePortLinks(self: *ChannelFxFilterManager) !void {
        for (self.filters.items) |filter| {
            if (filter.ports_linked) continue;
            filter.ports_linked = try self.tryConnectFilterPorts(filter);
        }
    }

    fn tryConnectFilterPorts(self: *ChannelFxFilterManager, filter: *ManagedFilter) !bool {
        _ = self;
        c.pw_thread_loop_lock(filter.thread_loop);
        defer c.pw_thread_loop_unlock(filter.thread_loop);

        const raw_node_id = findNodeId(filter.registry_nodes.items, filter.raw_monitor_z) orelse return false;
        const filter_node_id = findNodeId(filter.registry_nodes.items, filter.name_z) orelse return false;
        const processed_node_id = findNodeId(filter.registry_nodes.items, filter.processed_sink_z) orelse return false;

        const input_left = findPortId(filter.registry_ports.items, raw_node_id, "monitor_FL") orelse return false;
        const input_right = findPortId(filter.registry_ports.items, raw_node_id, "monitor_FR") orelse return false;
        const filter_in_left = findPortId(filter.registry_ports.items, filter_node_id, "in-L") orelse return false;
        const filter_in_right = findPortId(filter.registry_ports.items, filter_node_id, "in-R") orelse return false;
        const filter_out_left = findPortId(filter.registry_ports.items, filter_node_id, "out-L") orelse return false;
        const filter_out_right = findPortId(filter.registry_ports.items, filter_node_id, "out-R") orelse return false;
        const processed_left = findPortId(filter.registry_ports.items, processed_node_id, "playback_FL") orelse return false;
        const processed_right = findPortId(filter.registry_ports.items, processed_node_id, "playback_FR") orelse return false;

        if (filter.link_in_left.proxy == null and !filter.link_in_left.failed) {
            filter.link_in_left.role = "input-left";
            filter.link_in_left.channel_id = filter.channel_id;
            createLinkProxy(filter, &filter.link_in_left, raw_node_id, input_left, filter_node_id, filter_in_left) catch {
                filter.link_in_left.failed = true;
            };
        }
        if (filter.link_in_right.proxy == null and !filter.link_in_right.failed) {
            filter.link_in_right.role = "input-right";
            filter.link_in_right.channel_id = filter.channel_id;
            createLinkProxy(filter, &filter.link_in_right, raw_node_id, input_right, filter_node_id, filter_in_right) catch {
                filter.link_in_right.failed = true;
            };
        }
        if (filter.link_out_left.proxy == null and !filter.link_out_left.failed) {
            filter.link_out_left.role = "output-left";
            filter.link_out_left.channel_id = filter.channel_id;
            createLinkProxy(filter, &filter.link_out_left, filter_node_id, filter_out_left, processed_node_id, processed_left) catch {
                filter.link_out_left.failed = true;
            };
        }
        if (filter.link_out_right.proxy == null and !filter.link_out_right.failed) {
            filter.link_out_right.role = "output-right";
            filter.link_out_right.channel_id = filter.channel_id;
            createLinkProxy(filter, &filter.link_out_right, filter_node_id, filter_out_right, processed_node_id, processed_right) catch {
                filter.link_out_right.failed = true;
            };
        }

        return filter.link_in_left.bound and
            filter.link_in_right.bound and
            filter.link_out_left.bound and
            filter.link_out_right.bound;
    }
};

const RouteSpec = struct {
    channel_id: []const u8,
};

fn buildDesired(
    allocator: std.mem.Allocator,
    desired: *std.ArrayList(RouteSpec),
    channels: []const channels_mod.Channel,
    sources: []const sources_mod.Source,
    channel_sources: []const channel_sources_mod.ChannelSource,
    fx_channels: []const channels_mod.Channel,
) !void {
    for (fx_channels) |channel| {
        _ = findChannel(channels, channel.id) orelse continue;
        if (!channelHasReadySource(channel.id, sources, channel_sources)) continue;
        try desired.append(allocator, .{ .channel_id = channel.id });
    }
}

fn computeSignature(
    channels: []const channels_mod.Channel,
    sources: []const sources_mod.Source,
    channel_sources: []const channel_sources_mod.ChannelSource,
    fx_channels: []const channels_mod.Channel,
) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (channels) |channel| {
        hasher.update(channel.id);
        hasher.update(std.mem.asBytes(&[_]u8{
            @intFromFloat(@round(channel.volume * 100.0)),
            @intFromBool(channel.muted),
        }));
    }
    for (sources) |source| hasher.update(source.id);
    for (channel_sources) |channel_source| {
        hasher.update(channel_source.channel_id);
        hasher.update(channel_source.source_id);
        hasher.update(&[_]u8{@intFromBool(channel_source.enabled)});
    }
    for (fx_channels) |channel| hasher.update(channel.id);
    return hasher.final();
}

fn channelHasReadySource(channel_id: []const u8, sources: []const sources_mod.Source, channel_sources: []const channel_sources_mod.ChannelSource) bool {
    for (channel_sources) |channel_source| {
        if (!channel_source.enabled) continue;
        if (!std.mem.eql(u8, channel_source.channel_id, channel_id)) continue;
        if (findSource(sources, channel_source.source_id) != null) return true;
    }
    return false;
}

fn findSource(sources: []const sources_mod.Source, source_id: []const u8) ?sources_mod.Source {
    for (sources) |source| {
        if (std.mem.eql(u8, source.id, source_id)) return source;
    }
    return null;
}

fn containsSpec(specs: []const RouteSpec, channel_id: []const u8) bool {
    for (specs) |spec| {
        if (std.mem.eql(u8, spec.channel_id, channel_id)) return true;
    }
    return false;
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

fn allocProcessedSinkName(allocator: std.mem.Allocator, channel_id: []const u8) ![]u8 {
    var sink_name = try allocator.alloc(u8, fx_prefix.len + channel_id.len);
    @memcpy(sink_name[0..fx_prefix.len], fx_prefix);
    for (channel_id, fx_prefix.len..) |char, index| {
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
    _ = c.pw_properties_set(props, "node.want-driver", "true");
    _ = c.pw_properties_set(props, c.PW_KEY_MEDIA_CLASS, "Audio/Filter");
    return props;
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
    const core = c.pw_filter_get_core(filter.filter) orelse return error.PipeWireCoreUnavailable;
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
}

fn onLinkProxyRemoved(data: ?*anyopaque) callconv(.c) void {
    _ = data;
}

fn onLinkProxyError(data: ?*anyopaque, _: c_int, _: c_int, _: [*c]const u8) callconv(.c) void {
    if (data == null) return;
    const link: *ChannelFxFilterManager.LinkProxy = @ptrCast(@alignCast(data));
    link.failed = true;
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
    if (filter.ports_linked and (!filter.link_in_left.bound or !filter.link_in_right.bound or !filter.link_out_left.bound or !filter.link_out_right.bound)) {
        filter.ports_linked = false;
    }
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

fn addPort(filter: *c.struct_pw_filter, direction: c.enum_spa_direction, target_object: [*:0]const u8, label: []const u8) ?*anyopaque {
    const props = c.pw_properties_new(null) orelse return null;
    const label_z = std.heap.page_allocator.dupeZ(u8, label) catch {
        c.pw_properties_free(props);
        return null;
    };
    defer std.heap.page_allocator.free(label_z);
    _ = c.pw_properties_set(props, c.PW_KEY_PORT_NAME, label_z.ptr);
    _ = c.pw_properties_set(props, c.PW_KEY_TARGET_OBJECT, target_object);
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
    if (position) |pos| {
        const rate_num = pos.clock.rate.num;
        const rate_denom = pos.clock.rate.denom;
        if (rate_num != 0 and rate_denom != 0) {
            runtime.setSampleRate(@intCast(rate_denom / rate_num));
        }
    }
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

    _ = runtime.processChannel(filter.channel_id, left, right);
    for (0..frames) |index| {
        out_l[index] = left[index];
        out_r[index] = right[index];
    }
}
