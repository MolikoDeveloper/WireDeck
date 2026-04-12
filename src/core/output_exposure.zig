const std = @import("std");
const enable_output_exposure_info_logs = false;
const enable_virtual_mic_debug_logs = false;
const StateStore = @import("../app/state_store.zig").StateStore;
const audio_engine_mod = @import("audio/engine.zig");
const bus_buffer_mod = @import("audio/bus_consumer_buffer.zig");
const buses_mod = @import("audio/buses.zig");
const destinations_mod = @import("audio/destinations.zig");
const bus_playback_mod = @import("pulse/bus_playback.zig");
const pipewire_context_mod = @import("pipewire/context.zig");
const pw_c = @import("pipewire/c.zig").c;
const virtual_mic_source_mod = @import("pipewire/virtual_mic_source.zig");
const pulse = @import("pulse.zig");

const default_http_port: u16 = 8787;
const output_sink_prefix = "wiredeck_output_";
const remap_source_prefix = "wiredeck_busmic_";
const mic_description_prefix = "WireDeck ";
const output_description_prefix = "WireDeck Output ";
const virtual_mic_create_warn_threshold_ns: i128 = 50 * std.time.ns_per_ms;

pub const BusTargetSummary = struct {
    count: usize = 0,
    single_sink: ?pulse.PulseSink = null,

    pub fn usesDirectSink(self: BusTargetSummary, bus: buses_mod.Bus) bool {
        _ = self;
        _ = bus;
        return false;
    }

    pub fn needsVirtualBus(self: BusTargetSummary, bus: buses_mod.Bus) bool {
        _ = bus;
        return self.count > 0;
    }
};

pub const OutputExposureManager = struct {
    const config_revision: u32 = 1;

    const WebRoute = struct {
        bus_id: []u8,
        label: []u8,
        path: []u8,
        monitor_source_name: []u8,

        fn deinit(self: *WebRoute, allocator: std.mem.Allocator) void {
            allocator.free(self.bus_id);
            allocator.free(self.label);
            allocator.free(self.path);
            allocator.free(self.monitor_source_name);
        }
    };

    const DesiredWebRoute = struct {
        bus_id: []const u8,
        label: []const u8,
        path: []u8,
        monitor_source_name: []u8,

        fn deinit(self: *DesiredWebRoute, allocator: std.mem.Allocator) void {
            allocator.free(self.path);
            allocator.free(self.monitor_source_name);
        }
    };

    const ManagedVirtualMic = struct {
        bus_id: []u8,
        bus_label: []u8,
        source_name: []u8,
        source: *virtual_mic_source_mod.VirtualMicSource,

        fn deinit(self: *ManagedVirtualMic, allocator: std.mem.Allocator) void {
            allocator.free(self.bus_id);
            allocator.free(self.bus_label);
            allocator.free(self.source_name);
        }
    };

    const ManagedOutputBus = struct {
        bus_id: []u8,
        bus_label: []u8,
        source_name: []u8,
        source: *virtual_mic_source_mod.VirtualMicSource,

        fn deinit(self: *ManagedOutputBus, allocator: std.mem.Allocator) void {
            allocator.free(self.bus_id);
            allocator.free(self.bus_label);
            allocator.free(self.source_name);
        }
    };

    const DesiredOutputBus = struct {
        bus_id: []const u8,
        bus_label: []const u8,
    };

    const ManagedBusDestinationLoopback = struct {
        bus_id: []u8,
        target_sink_name: []u8,
        consumer_id: []u8,
        stream: *bus_playback_mod.BusPlayback,

        fn deinit(self: *ManagedBusDestinationLoopback, allocator: std.mem.Allocator) void {
            allocator.free(self.bus_id);
            allocator.free(self.target_sink_name);
            allocator.free(self.consumer_id);
        }
    };

    const DesiredBusDestinationLoopback = struct {
        bus_id: []const u8,
        target_sink_name: []u8,

        fn deinit(self: *DesiredBusDestinationLoopback, allocator: std.mem.Allocator) void {
            allocator.free(self.target_sink_name);
        }
    };

    const DesiredVirtualMic = struct {
        bus_id: []const u8,
        bus_label: []const u8,
    };

    allocator: std.mem.Allocator,
    port: u16,
    stop_requested: std.atomic.Value(bool),
    server_thread: ?std.Thread,
    routes_mutex: std.Thread.Mutex,
    routes: std.ArrayList(WebRoute),
    output_buses: std.ArrayList(ManagedOutputBus),
    bus_destination_loopbacks: std.ArrayList(ManagedBusDestinationLoopback),
    virtual_mics: std.ArrayList(ManagedVirtualMic),
    engine: ?*audio_engine_mod.AudioEngine,
    default_virtual_mic_source_name: ?[]u8,
    did_initial_recovery_cleanup: bool,
    last_plan_signature: u64,

    pub fn init(allocator: std.mem.Allocator) OutputExposureManager {
        return .{
            .allocator = allocator,
            .port = default_http_port,
            .stop_requested = std.atomic.Value(bool).init(false),
            .server_thread = null,
            .routes_mutex = .{},
            .routes = .empty,
            .output_buses = .empty,
            .bus_destination_loopbacks = .empty,
            .virtual_mics = .empty,
            .engine = null,
            .default_virtual_mic_source_name = null,
            .did_initial_recovery_cleanup = false,
            .last_plan_signature = 0,
        };
    }

    pub fn deinit(self: *OutputExposureManager) void {
        self.stopServer();
        self.clearRoutes();
        self.unloadAllBusDestinationLoopbacks() catch {};
        self.unloadAllOutputBuses() catch {};
        self.unloadAllVirtualMics() catch {};
        for (self.bus_destination_loopbacks.items) |*loopback| loopback.deinit(self.allocator);
        self.bus_destination_loopbacks.deinit(self.allocator);
        for (self.output_buses.items) |*bus| bus.deinit(self.allocator);
        self.output_buses.deinit(self.allocator);
        for (self.virtual_mics.items) |*mic| mic.deinit(self.allocator);
        self.virtual_mics.deinit(self.allocator);
        self.routes.deinit(self.allocator);
        if (self.default_virtual_mic_source_name) |value| self.allocator.free(value);
    }

    pub fn attachEngine(self: *OutputExposureManager, engine: *audio_engine_mod.AudioEngine) void {
        self.engine = engine;
    }

    pub fn start(self: *OutputExposureManager) !void {
        _ = self;
    }

    pub fn stopServer(self: *OutputExposureManager) void {
        _ = self;
    }

    pub fn resetAudioState(self: *OutputExposureManager) !void {
        self.clearRoutes();
        try self.unloadAllVirtualMics();
        try self.unloadAllBusDestinationLoopbacks();
        try self.unloadAllOutputBuses();

        for (self.virtual_mics.items) |*mic| mic.deinit(self.allocator);
        self.virtual_mics.clearRetainingCapacity();
        for (self.bus_destination_loopbacks.items) |*item| item.deinit(self.allocator);
        self.bus_destination_loopbacks.clearRetainingCapacity();
        for (self.output_buses.items) |*bus| bus.deinit(self.allocator);
        self.output_buses.clearRetainingCapacity();
    }

    pub fn sync(
        self: *OutputExposureManager,
        state_store: *const StateStore,
        pulse_snapshot: pulse.PulseSnapshot,
        pulsectx: *pulse.PulseContext,
    ) !void {
        if (!self.did_initial_recovery_cleanup) {
            try self.recoverFromStaleModules(pulsectx);
            self.did_initial_recovery_cleanup = true;
        }

        var desired_bus_destination_loopbacks = std.ArrayList(DesiredBusDestinationLoopback).empty;
        defer {
            for (desired_bus_destination_loopbacks.items) |*item| item.deinit(self.allocator);
            desired_bus_destination_loopbacks.deinit(self.allocator);
        }

        var desired_mics = std.ArrayList(DesiredVirtualMic).empty;
        defer {
            desired_mics.deinit(self.allocator);
        }

        try collectDesiredOutputs(
            self.allocator,
            state_store,
            pulse_snapshot,
            &desired_bus_destination_loopbacks,
            &desired_mics,
        );
        if (enable_virtual_mic_debug_logs) {
            std.log.info("virtual mic sync begin: desired={d} existing={d}", .{
                desired_mics.items.len,
                self.virtual_mics.items.len,
            });
            for (desired_mics.items) |item| {
                std.log.info("virtual mic desired: bus={s} label={s}", .{ item.bus_id, item.bus_label });
            }
        }
        const plan_signature = computeExposurePlanSignature(state_store, pulse_snapshot);
        if (plan_signature != self.last_plan_signature) {
            self.last_plan_signature = plan_signature;
            logExposurePlan(state_store, pulse_snapshot);
        }
        try self.syncOutputBuses(&.{}, pulsectx);
        try self.syncBusDestinationLoopbacks(desired_bus_destination_loopbacks.items);
        self.clearRoutes();
        try self.syncVirtualMics(desired_mics.items, pulsectx);
        self.syncDefaultVirtualMicSource() catch |err| {
            std.log.warn("virtual mic default source sync failed: {s}", .{@errorName(err)});
        };
    }

    fn recoverFromStaleModules(self: *OutputExposureManager, pulsectx: *pulse.PulseContext) !void {
        const modules = try pulsectx.listModules(self.allocator);
        defer pulse.freeModules(self.allocator, modules);

        for (modules) |module| {
            const name = module.name orelse continue;
            const argument = module.argument orelse "";
            if (!isOutputExposureManagedModule(name, argument)) continue;
            pulsectx.unloadModule(module.index) catch {};
        }

        try destroyStaleVirtualMicNodes(self.allocator);

        for (self.virtual_mics.items) |*mic| mic.deinit(self.allocator);
        self.virtual_mics.clearRetainingCapacity();
        for (self.bus_destination_loopbacks.items) |*item| item.deinit(self.allocator);
        self.bus_destination_loopbacks.clearRetainingCapacity();
        for (self.output_buses.items) |*bus| bus.deinit(self.allocator);
        self.output_buses.clearRetainingCapacity();
        self.clearRoutes();
    }

    fn destroyStaleVirtualMicNodes(allocator: std.mem.Allocator) !void {
        const pipewire = try pipewire_context_mod.PipewireContext.init(allocator);
        defer pipewire.deinit();
        try pipewire.scan();

        for (pipewire.registry_state.objects.items) |obj| {
            if (obj.kind != .node) continue;
            const media_class = obj.props.media_class orelse continue;
            if (!std.mem.eql(u8, media_class, "Audio/Source/Virtual") and
                !std.mem.eql(u8, media_class, "Audio/Source"))
            {
                continue;
            }
            const node_name = obj.props.node_name orelse "";
            const node_description = obj.props.node_description orelse "";
            const media_name = obj.props.media_name orelse "";
            if (!std.mem.startsWith(u8, node_name, "WireDeck_") and
                !std.mem.startsWith(u8, node_description, mic_description_prefix) and
                !std.mem.startsWith(u8, media_name, mic_description_prefix))
            {
                continue;
            }
            _ = pw_c.pw_registry_destroy(pipewire.registry, obj.id);
        }

        // Flush any pending removals before continuing startup.
        try pipewire.scan();
    }

    fn clearRoutes(self: *OutputExposureManager) void {
        self.routes_mutex.lock();
        defer self.routes_mutex.unlock();
        for (self.routes.items) |*route| route.deinit(self.allocator);
        self.routes.clearRetainingCapacity();
    }

    fn replaceRoutes(self: *OutputExposureManager, desired: []const DesiredWebRoute) !void {
        self.routes_mutex.lock();
        defer self.routes_mutex.unlock();

        for (self.routes.items) |*route| route.deinit(self.allocator);
        self.routes.clearRetainingCapacity();

        for (desired) |route| {
            try self.routes.append(self.allocator, .{
                .bus_id = try self.allocator.dupe(u8, route.bus_id),
                .label = try self.allocator.dupe(u8, route.label),
                .path = try self.allocator.dupe(u8, route.path),
                .monitor_source_name = try self.allocator.dupe(u8, route.monitor_source_name),
            });
        }
    }

    fn syncVirtualMics(self: *OutputExposureManager, desired: []const DesiredVirtualMic, pulsectx: *pulse.PulseContext) !void {
        var index: usize = 0;
        while (index < self.virtual_mics.items.len) {
            const existing = self.virtual_mics.items[index];
            const desired_item = findDesiredMic(desired, existing.bus_id);
            if (desired_item == null or !std.mem.eql(u8, existing.bus_label, desired_item.?.bus_label)) {
                if (enable_virtual_mic_debug_logs) {
                    std.log.info("virtual mic remove: bus={s} current_label={s} reason={s}", .{
                        existing.bus_id,
                        existing.bus_label,
                        if (desired_item == null) "no_longer_desired" else "label_changed",
                    });
                }
                try unloadVirtualMic(self, existing, pulsectx);
                var removed = self.virtual_mics.orderedRemove(index);
                removed.deinit(self.allocator);
                continue;
            }
            if (enable_virtual_mic_debug_logs) {
                std.log.info("virtual mic keep: bus={s} label={s} source={s}", .{
                    existing.bus_id,
                    existing.bus_label,
                    existing.source_name,
                });
            }
            index += 1;
        }

        for (desired) |item| {
            if (findManagedMic(self.virtual_mics.items, item.bus_id) != null) continue;
            if (enable_virtual_mic_debug_logs) {
                std.log.info("virtual mic add: bus={s} label={s}", .{ item.bus_id, item.bus_label });
            }
            const managed = try loadVirtualMic(self, item, pulsectx);
            try self.virtual_mics.append(self.allocator, managed);
        }
    }

    fn syncOutputBuses(self: *OutputExposureManager, desired: []const DesiredOutputBus, pulsectx: *pulse.PulseContext) !void {
        var index: usize = 0;
        while (index < self.output_buses.items.len) {
            const existing = self.output_buses.items[index];
            const desired_item = findDesiredOutputBus(desired, existing.bus_id);
            if (desired_item == null or !std.mem.eql(u8, existing.bus_label, desired_item.?.bus_label)) {
                try unloadOutputBus(self, existing, pulsectx);
                var removed = self.output_buses.orderedRemove(index);
                removed.deinit(self.allocator);
                continue;
            }
            index += 1;
        }

        for (desired) |item| {
            if (findManagedOutputBus(self.output_buses.items, item.bus_id) != null) continue;
            const managed = try loadOutputBus(self, item, pulsectx);
            try self.output_buses.append(self.allocator, managed);
        }
    }

    fn syncBusDestinationLoopbacks(
        self: *OutputExposureManager,
        desired: []const DesiredBusDestinationLoopback,
    ) !void {
        var index: usize = 0;
        while (index < self.bus_destination_loopbacks.items.len) {
            const existing = self.bus_destination_loopbacks.items[index];
            if (!containsDesiredBusLoopback(desired, existing.bus_id, existing.target_sink_name)) {
                existing.stream.deinit();
                var removed = self.bus_destination_loopbacks.orderedRemove(index);
                removed.deinit(self.allocator);
                continue;
            }
            index += 1;
        }

        for (desired) |item| {
            if (findManagedBusLoopback(self.bus_destination_loopbacks.items, item.bus_id, item.target_sink_name) != null) continue;
            const managed = try loadBusDestinationLoopback(self, item);
            try self.bus_destination_loopbacks.append(self.allocator, managed);
        }
    }

    fn unloadAllVirtualMics(self: *OutputExposureManager) !void {
        const pulsectx = try pulse.PulseContext.init(self.allocator);
        defer pulsectx.deinit();
        for (self.virtual_mics.items) |mic| {
            unloadVirtualMic(self, mic, pulsectx) catch {};
        }
    }

    fn syncDefaultVirtualMicSource(self: *OutputExposureManager) !void {
        const preferred_source_name = if (self.virtual_mics.items.len > 0) self.virtual_mics.items[0].source_name else null;
        if (enable_virtual_mic_debug_logs) {
            std.log.info("virtual mic default sync: preferred={s} existing={s} active_count={d}", .{
                preferred_source_name orelse "<none>",
                self.default_virtual_mic_source_name orelse "<none>",
                self.virtual_mics.items.len,
            });
        }
        if (preferred_source_name == null) {
            if (self.default_virtual_mic_source_name) |value| {
                self.allocator.free(value);
                self.default_virtual_mic_source_name = null;
            }
            return;
        }

        if (self.default_virtual_mic_source_name) |value| {
            if (std.mem.eql(u8, value, preferred_source_name.?)) return;
            self.allocator.free(value);
            self.default_virtual_mic_source_name = null;
        }
        // Do not auto-assign virtual microphones as the default system source.
    }

    fn unloadAllOutputBuses(self: *OutputExposureManager) !void {
        const pulsectx = try pulse.PulseContext.init(self.allocator);
        defer pulsectx.deinit();
        for (self.output_buses.items) |bus| {
            unloadOutputBus(self, bus, pulsectx) catch {};
        }
    }

    fn unloadAllBusDestinationLoopbacks(self: *OutputExposureManager) !void {
        for (self.bus_destination_loopbacks.items) |item| {
            item.stream.deinit();
        }
    }
};

pub fn allocOutputSinkName(allocator: std.mem.Allocator, bus_id: []const u8) ![]u8 {
    return allocSafeName(allocator, output_sink_prefix, bus_id);
}

pub fn allocVirtualMicSourceName(allocator: std.mem.Allocator, bus_id: []const u8) ![]u8 {
    return allocSafeName(allocator, remap_source_prefix, bus_id);
}

pub fn allocVirtualMicNodeName(allocator: std.mem.Allocator, bus_label: []const u8, bus_id: []const u8) ![]u8 {
    const label = if (bus_label.len > 0) bus_label else bus_id;
    return allocSafeNamePreserveCase(allocator, "WireDeck_", label);
}

pub fn allocVirtualMicDisplayName(allocator: std.mem.Allocator, bus_label: []const u8, bus_id: []const u8) ![]u8 {
    const label = if (bus_label.len > 0) bus_label else bus_id;
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ mic_description_prefix, label });
}

pub fn cleanupDefaultAudioSource(allocator: std.mem.Allocator) !void {
    const output = try runHostCommandCapture(allocator, &.{ "pw-metadata", "-n", "default" });
    defer allocator.free(output);

    const configured = try parseDefaultAudioSourceNameForKey(allocator, output, "default.configured.audio.source");
    defer if (configured) |value| allocator.free(value);
    const effective = try parseDefaultAudioSourceNameForKey(allocator, output, "default.audio.source");
    defer if (effective) |value| allocator.free(value);

    const current = configured orelse effective orelse return;

    const pulsectx = try pulse.PulseContext.init(allocator);
    defer pulsectx.deinit();

    const snapshot = try pulsectx.snapshot(allocator);
    defer pulse.freeSnapshot(allocator, snapshot);

    const current_is_managed = isManagedVirtualMicSourceName(snapshot, current) or
        std.mem.startsWith(u8, current, remap_source_prefix) or
        std.mem.startsWith(u8, current, "WireDeck_") or
        std.mem.startsWith(u8, current, mic_description_prefix);
    if (!current_is_managed) return;

    if (effective) |source_name| {
        const effective_is_managed = isManagedVirtualMicSourceName(snapshot, source_name) or
            std.mem.startsWith(u8, source_name, remap_source_prefix) or
            std.mem.startsWith(u8, source_name, "WireDeck_") or
            std.mem.startsWith(u8, source_name, mic_description_prefix);
        if (!effective_is_managed) {
            try setPipeWireDefaultAudioSource(allocator, source_name);
            return;
        }
    }

    for (snapshot.sources) |source| {
        const source_name = source.name orelse continue;
        if (source.monitor_of_sink != null) continue;
        if (isManagedVirtualMicSource(snapshot, source)) continue;
        try setPipeWireDefaultAudioSource(allocator, source_name);
        return;
    }
}

pub fn cleanupManagedVirtualMicState(allocator: std.mem.Allocator) !void {
    cleanupDefaultAudioSource(allocator) catch |err| switch (err) {
        error.HostCommandFailed => {},
        else => return err,
    };
    try deleteManagedDefaultAudioSourceMetadata(allocator);
    try cleanupStaleVirtualMicNodes(allocator);
}

fn serverMain(manager: *OutputExposureManager) void {
    const address = std.net.Address.parseIp4("0.0.0.0", manager.port) catch return;
    var server = std.net.Address.listen(address, .{ .reuse_address = true }) catch |err| {
        std.log.warn("output exposure server unavailable on port {d}: {s}", .{ manager.port, @errorName(err) });
        return;
    };
    defer server.deinit();

    while (!manager.stop_requested.load(.monotonic)) {
        const connection = server.accept() catch |err| {
            if (manager.stop_requested.load(.monotonic)) break;
            std.log.warn("output exposure accept failed: {s}", .{@errorName(err)});
            continue;
        };
        const thread = std.Thread.spawn(.{}, handleConnectionThread, .{ manager, connection }) catch {
            connection.stream.close();
            continue;
        };
        thread.detach();
    }
}

pub fn cleanupStaleVirtualMicNodes(allocator: std.mem.Allocator) !void {
    const pipewire = try pipewire_context_mod.PipewireContext.init(allocator);
    defer pipewire.deinit();
    try pipewire.scan();

    for (pipewire.registry_state.objects.items) |obj| {
        if (obj.kind != .node) continue;
        const media_class = obj.props.media_class orelse continue;
        if (!std.mem.eql(u8, media_class, "Audio/Source/Virtual") and
            !std.mem.eql(u8, media_class, "Audio/Source"))
        {
            continue;
        }
        const node_name = obj.props.node_name orelse "";
        const node_description = obj.props.node_description orelse "";
        const media_name = obj.props.media_name orelse "";
        if (!std.mem.startsWith(u8, node_name, "WireDeck_") and
            !std.mem.startsWith(u8, node_description, mic_description_prefix) and
            !std.mem.startsWith(u8, media_name, mic_description_prefix))
        {
            continue;
        }
        _ = pw_c.pw_registry_destroy(pipewire.registry, obj.id);
    }

    try pipewire.scan();
}

fn handleConnectionThread(manager: *OutputExposureManager, connection: std.net.Server.Connection) void {
    defer connection.stream.close();

    var request_buffer: [2048]u8 = undefined;
    const read_len = connection.stream.read(&request_buffer) catch return;
    if (read_len == 0) return;

    const request = request_buffer[0..read_len];
    const line_end = std.mem.indexOf(u8, request, "\r\n") orelse std.mem.indexOfScalar(u8, request, '\n') orelse return;
    const request_line = request[0..line_end];
    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method = parts.next() orelse return;
    const target = parts.next() orelse return;
    if (!std.mem.eql(u8, method, "GET")) {
        writeSimpleResponse(connection.stream, "405 Method Not Allowed", "Only GET is supported.\n") catch {};
        return;
    }

    const path = normalizeRequestPath(target);
    if (std.mem.eql(u8, path, "/")) {
        writeRouteIndexResponse(manager, connection.stream) catch {};
        return;
    }
    if (std.mem.eql(u8, path, "/api/routes")) {
        writeRoutesJsonResponse(manager, connection.stream) catch {};
        return;
    }
    if (lookupRoute(manager, path)) |route| {
        defer freeResolvedRoute(std.heap.page_allocator, &route);
        writeRouteHtmlResponse(manager, connection.stream, route, false) catch {};
        return;
    }

    if (lookupRouteNoUi(manager, path)) |route| {
        defer freeResolvedRoute(std.heap.page_allocator, &route);
        writeRouteHtmlResponse(manager, connection.stream, route, true) catch {};
        return;
    }

    if (lookupRoutePcmStream(manager, path)) |route| {
        defer freeResolvedRoute(std.heap.page_allocator, &route);
        streamPcmToClient(manager, connection.stream, route) catch |err| {
            std.log.warn("web output stream failed for {s}: {s}", .{ path, @errorName(err) });
        };
        return;
    }

    writeSimpleResponse(connection.stream, "404 Not Found", "Output route not found.\n") catch {};
}

fn writeSimpleResponse(stream: std.net.Stream, status: []const u8, body: []const u8) !void {
    const header = try std.fmt.allocPrint(std.heap.page_allocator, "HTTP/1.1 {s}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, body.len });
    defer std.heap.page_allocator.free(header);
    try stream.writeAll(header);
    try stream.writeAll(body);
}

fn writeRouteIndexResponse(manager: *OutputExposureManager, stream: std.net.Stream) !void {
    var body = std.ArrayList(u8).empty;
    defer body.deinit(manager.allocator);

    try body.writer(manager.allocator).print("WireDeck output exposure server\n\n", .{});
    try body.writer(manager.allocator).print("HTTP port: {d}\n", .{manager.port});
    try body.writer(manager.allocator).print("Machine-readable routes: /api/routes\n\n", .{});

    manager.routes_mutex.lock();
    defer manager.routes_mutex.unlock();

    if (manager.routes.items.len == 0) {
        try body.writer(manager.allocator).writeAll("No outputs are currently exposed.\n");
    } else {
        try body.writer(manager.allocator).writeAll("Active routes:\n");
        for (manager.routes.items) |route| {
            try body.writer(manager.allocator).print("- {s} -> {s}\n", .{ route.label, route.path });
            try body.writer(manager.allocator).print("  stream: {s}/stream.pcm\n", .{route.path});
        }
    }

    const body_slice = try body.toOwnedSlice(manager.allocator);
    defer manager.allocator.free(body_slice);
    const header = try std.fmt.allocPrint(manager.allocator, "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body_slice.len});
    defer manager.allocator.free(header);
    try stream.writeAll(header);
    try stream.writeAll(body_slice);
}

fn writeRoutesJsonResponse(manager: *OutputExposureManager, stream: std.net.Stream) !void {
    var body = std.ArrayList(u8).empty;
    defer body.deinit(manager.allocator);
    try body.writer(manager.allocator).print("{{\"port\":{d},\"routes\":[", .{manager.port});

    manager.routes_mutex.lock();
    defer manager.routes_mutex.unlock();

    for (manager.routes.items, 0..) |route, index| {
        if (index > 0) try body.append(manager.allocator, ',');
        try body.writer(manager.allocator).writeAll("{\"label\":");
        try appendJsonString(manager.allocator, &body, route.label);
        try body.writer(manager.allocator).writeAll(",\"path\":");
        try appendJsonString(manager.allocator, &body, route.path);
        try body.writer(manager.allocator).writeAll(",\"stream_path\":");
        const stream_path = try std.fmt.allocPrint(manager.allocator, "{s}/stream.pcm", .{route.path});
        defer manager.allocator.free(stream_path);
        try appendJsonString(manager.allocator, &body, stream_path);
        try body.writer(manager.allocator).writeAll("}");
    }
    try body.writer(manager.allocator).writeAll("]}");

    const body_slice = try body.toOwnedSlice(manager.allocator);
    defer manager.allocator.free(body_slice);
    const header = try std.fmt.allocPrint(manager.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", .{body_slice.len});
    defer manager.allocator.free(header);
    try stream.writeAll(header);
    try stream.writeAll(body_slice);
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    try out.append(allocator, '"');
    for (value) |char| {
        switch (char) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, char),
        }
    }
    try out.append(allocator, '"');
}

const ResolvedRoute = struct {
    bus_id: []u8,
    label: []u8,
    path: []u8,
    monitor_source_name: []u8,
};

fn freeResolvedRoute(allocator: std.mem.Allocator, route: *const ResolvedRoute) void {
    allocator.free(route.bus_id);
    allocator.free(route.label);
    allocator.free(route.path);
    allocator.free(route.monitor_source_name);
}

fn lookupRoute(manager: *OutputExposureManager, request_path: []const u8) ?ResolvedRoute {
    manager.routes_mutex.lock();
    defer manager.routes_mutex.unlock();
    for (manager.routes.items) |route| {
        if (!std.mem.eql(u8, route.path, request_path)) continue;
        return .{
            .bus_id = std.heap.page_allocator.dupe(u8, route.bus_id) catch return null,
            .label = std.heap.page_allocator.dupe(u8, route.label) catch return null,
            .path = std.heap.page_allocator.dupe(u8, route.path) catch return null,
            .monitor_source_name = std.heap.page_allocator.dupe(u8, route.monitor_source_name) catch return null,
        };
    }
    return null;
}

fn lookupRouteNoUi(manager: *OutputExposureManager, request_path: []const u8) ?ResolvedRoute {
    manager.routes_mutex.lock();
    defer manager.routes_mutex.unlock();
    for (manager.routes.items) |route| {
        const expected = std.fmt.allocPrint(std.heap.page_allocator, "{s}/noUI", .{route.path}) catch return null;
        defer std.heap.page_allocator.free(expected);
        if (!std.mem.eql(u8, expected, request_path)) continue;
        return .{
            .bus_id = std.heap.page_allocator.dupe(u8, route.bus_id) catch return null,
            .label = std.heap.page_allocator.dupe(u8, route.label) catch return null,
            .path = std.heap.page_allocator.dupe(u8, route.path) catch return null,
            .monitor_source_name = std.heap.page_allocator.dupe(u8, route.monitor_source_name) catch return null,
        };
    }
    return null;
}

fn lookupRoutePcmStream(manager: *OutputExposureManager, request_path: []const u8) ?ResolvedRoute {
    manager.routes_mutex.lock();
    defer manager.routes_mutex.unlock();
    for (manager.routes.items) |route| {
        const expected = std.fmt.allocPrint(std.heap.page_allocator, "{s}/stream.pcm", .{route.path}) catch return null;
        defer std.heap.page_allocator.free(expected);
        if (!std.mem.eql(u8, expected, request_path)) continue;
        return .{
            .bus_id = std.heap.page_allocator.dupe(u8, route.bus_id) catch return null,
            .label = std.heap.page_allocator.dupe(u8, route.label) catch return null,
            .path = std.heap.page_allocator.dupe(u8, route.path) catch return null,
            .monitor_source_name = std.heap.page_allocator.dupe(u8, route.monitor_source_name) catch return null,
        };
    }
    return null;
}

fn normalizeRequestPath(target: []const u8) []const u8 {
    const without_query = if (std.mem.indexOfScalar(u8, target, '?')) |index| target[0..index] else target;
    if (without_query.len == 0) return "/";
    return without_query;
}

fn writeRouteHtmlResponse(manager: *OutputExposureManager, stream: std.net.Stream, route: ResolvedRoute, no_ui: bool) !void {
    const stream_path = try std.fmt.allocPrint(manager.allocator, "{s}/stream.pcm", .{route.path});
    defer manager.allocator.free(stream_path);
    const no_ui_path = try std.fmt.allocPrint(manager.allocator, "{s}/noUI", .{route.path});
    defer manager.allocator.free(no_ui_path);

    var body = std.ArrayList(u8).empty;
    defer body.deinit(manager.allocator);
    try body.writer(manager.allocator).writeAll(
        "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" ++
            "<title>",
    );
    try appendHtmlEscaped(manager.allocator, &body, route.label);
    if (no_ui) {
        try body.writer(manager.allocator).writeAll(
            "</title><style>html,body{margin:0;background:#000}body{overflow:hidden}</style></head><body><script>",
        );
    } else {
        try body.writer(manager.allocator).writeAll(
            "</title><style>body{font-family:sans-serif;max-width:720px;margin:40px auto;padding:0 16px;background:#0f1115;color:#f3f4f6}" ++
                ".card{background:#171a21;border:1px solid #2b3140;border-radius:16px;padding:20px}" ++
                "button{margin-top:16px;background:#1f8f5f;color:#fff;border:0;border-radius:10px;padding:12px 16px;font:inherit;cursor:pointer}" ++
                "button[disabled]{opacity:.55;cursor:default}code{background:#0b0d12;padding:2px 6px;border-radius:6px;color:#9bd1ff}.status{margin-top:12px;color:#b9c0cd}</style></head><body><div class=\"card\"><h1>",
        );
        try appendHtmlEscaped(manager.allocator, &body, route.label);
        try body.writer(manager.allocator).writeAll("</h1><p>Live output stream</p><p>Stream endpoint: <code>");
        try appendHtmlEscaped(manager.allocator, &body, stream_path);
        try body.writer(manager.allocator).writeAll("</code></p><p>Autoplay page: <code>");
        try appendHtmlEscaped(manager.allocator, &body, no_ui_path);
        try body.writer(manager.allocator).writeAll("</code></p><button id=\"start\">Start low-latency stream</button><div class=\"status\" id=\"status\">Idle</div><script>");
    }
    try body.writer(manager.allocator).writeAll(
        "const streamUrl = ",
    );
    try appendJsonString(manager.allocator, &body, stream_path);
    try body.writer(manager.allocator).print(";const noUi={s};", .{if (no_ui) "true" else "false"});
    try body.writer(manager.allocator).writeAll(
        "" ++
            "const startBtn=document.getElementById('start');" ++
            "const statusEl=document.getElementById('status');" ++
            "let audioCtx=null;" ++
            "let nextTime=0;" ++
            "let started=false;" ++
            "let reconnectTimer=0;" ++
            "let reconnectDelay=1000;" ++
            "function setStatus(t){if(statusEl)statusEl.textContent=t;}" ++
            "function scheduleReconnect(){" ++
            "if(reconnectTimer)return;" ++
            "setStatus('Disconnected, retrying...');" ++
            "reconnectTimer=window.setTimeout(()=>{reconnectTimer=0;connect().catch(handleDisconnect);},reconnectDelay);" ++
            "reconnectDelay=Math.min(reconnectDelay*3/2,5000);" ++
            "}" ++
            "function handleDisconnect(err){" ++
            "console.warn(err);" ++
            "started=false;" ++
            "if(startBtn)startBtn.disabled=false;" ++
            "scheduleReconnect();" ++
            "}" ++
            "async function ensureAudio(){" ++
            "if(!audioCtx)audioCtx=new(window.AudioContext||window.webkitAudioContext)({sampleRate:48000});" ++
            "if(audioCtx.state!=='running')await audioCtx.resume();" ++
            "}" ++
            "async function connect(){" ++
            "if(started)return;" ++
            "started=true;" ++
            "if(startBtn)startBtn.disabled=true;" ++
            "await ensureAudio();" ++
            "nextTime=audioCtx.currentTime+0.06;" ++
            "setStatus('Connecting...');" ++
            "const response=await fetch(streamUrl,{cache:'no-store'});" ++
            "if(!response.ok||!response.body)throw new Error('stream unavailable');" ++
            "reconnectDelay=1000;" ++
            "setStatus('Streaming');" ++
            "const reader=response.body.getReader();" ++
            "let pending=new Uint8Array(0);" ++
            "const framesPerChunk=960;" ++
            "const bytesPerFrame=4;" ++
            "const chunkBytes=framesPerChunk*bytesPerFrame;" ++
            "const lead=0.06;" ++
            "const maxLead=0.18;" ++
            "const maxPendingBytes=chunkBytes*6;" ++
            "let dropping=false;" ++
            "for(;;){" ++
            "const result=await reader.read();" ++
            "if(result.done)break;" ++
            "const value=result.value;" ++
            "if(!value||!value.length)continue;" ++
            "const merged=new Uint8Array(pending.length+value.length);" ++
            "merged.set(pending,0);" ++
            "merged.set(value,pending.length);" ++
            "pending=merged.length>maxPendingBytes?merged.slice(merged.length-maxPendingBytes):merged;" ++
            "while(pending.length>=chunkBytes){" ++
            "const chunk=pending.slice(0,chunkBytes);" ++
            "pending=pending.slice(chunkBytes);" ++
            "const frameCount=chunk.length/bytesPerFrame;" ++
            "const now=audioCtx.currentTime;" ++
            "if(nextTime>now+maxLead){dropping=true;setStatus('Streaming (dropping stale audio)');continue;}" ++
            "if(dropping&&nextTime<=now+lead){dropping=false;setStatus('Streaming');}" ++
            "const audioBuffer=audioCtx.createBuffer(2,frameCount,48000);" ++
            "const left=audioBuffer.getChannelData(0);" ++
            "const right=audioBuffer.getChannelData(1);" ++
            "const view=new DataView(chunk.buffer,chunk.byteOffset,chunk.byteLength);" ++
            "for(let i=0;i<frameCount;i++){left[i]=view.getInt16(i*4,true)/32768;right[i]=view.getInt16(i*4+2,true)/32768;}" ++
            "const source=audioCtx.createBufferSource();" ++
            "source.buffer=audioBuffer;" ++
            "source.connect(audioCtx.destination);" ++
            "if(nextTime<now+lead)nextTime=now+lead;" ++
            "source.onended=()=>source.disconnect();" ++
            "source.start(nextTime);" ++
            "nextTime+=audioBuffer.duration;" ++
            "}" ++
            "}" ++
            "throw new Error('stream ended');" ++
            "}" ++
            "if(startBtn)startBtn.addEventListener('click',()=>{connect().catch(handleDisconnect);});" ++
            "window.addEventListener('online',()=>{if(!started)connect().catch(handleDisconnect);});" ++
            "document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible'&&started&&audioCtx&&audioCtx.state!=='running')audioCtx.resume().catch(()=>{});});" ++
            "if(noUi){connect().catch(handleDisconnect);}",
    );
    if (no_ui) {
        try body.writer(manager.allocator).writeAll("</script></body></html>");
    } else {
        try body.writer(manager.allocator).writeAll("</script></div></body></html>");
    }

    const body_slice = try body.toOwnedSlice(manager.allocator);
    defer manager.allocator.free(body_slice);
    const header = try std.fmt.allocPrint(manager.allocator, "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", .{body_slice.len});
    defer manager.allocator.free(header);
    try stream.writeAll(header);
    try stream.writeAll(body_slice);
}

fn appendHtmlEscaped(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    for (value) |char| {
        switch (char) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&#39;"),
            else => try out.append(allocator, char),
        }
    }
}

fn isRouteStillExposed(manager: *OutputExposureManager, bus_id: []const u8) bool {
    manager.routes_mutex.lock();
    defer manager.routes_mutex.unlock();
    for (manager.routes.items) |route| {
        if (std.mem.eql(u8, route.bus_id, bus_id)) return true;
    }
    return false;
}

fn streamPcmToClient(manager: *OutputExposureManager, stream: std.net.Stream, route: ResolvedRoute) !void {
    if (manager.engine) |engine| {
        try streamBusPcmFromEngine(manager, engine, stream, route);
        return;
    }
    try streamPcmFromMonitorSource(manager, stream, route);
}

fn streamPcmFromMonitorSource(manager: *OutputExposureManager, stream: std.net.Stream, route: ResolvedRoute) !void {
    const allocator = std.heap.page_allocator;
    const source_arg = try std.fmt.allocPrint(allocator, "--device={s}", .{route.monitor_source_name});
    defer allocator.free(source_arg);

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    if (std.process.hasEnvVarConstant("FLATPAK_ID")) {
        try argv.appendSlice(allocator, &.{ "flatpak-spawn", "--host", "parec", source_arg, "--raw", "--rate=48000", "--channels=2", "--format=s16le", "--latency-msec=10" });
    } else {
        try argv.appendSlice(allocator, &.{ "parec", source_arg, "--raw", "--rate=48000", "--channels=2", "--format=s16le", "--latency-msec=10" });
    }

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    defer {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }

    try stream.writeAll(
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: application/octet-stream\r\n" ++
            "X-WireDeck-Format: pcm_s16le\r\n" ++
            "X-WireDeck-Rate: 48000\r\n" ++
            "X-WireDeck-Channels: 2\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "Cache-Control: no-store\r\n" ++
            "Connection: close\r\n\r\n",
    );

    const stdout = child.stdout.?;
    var buffer: [8192]u8 = undefined;
    var chunk_header_buffer: [32]u8 = undefined;
    while (true) {
        if (!isRouteStillExposed(manager, route.bus_id)) break;
        const read_len = stdout.read(&buffer) catch break;
        if (read_len == 0) break;
        const chunk_header = std.fmt.bufPrint(&chunk_header_buffer, "{x}\r\n", .{read_len}) catch break;
        stream.writeAll(chunk_header) catch break;
        stream.writeAll(buffer[0..read_len]) catch break;
        stream.writeAll("\r\n") catch break;
    }
    stream.writeAll("0\r\n\r\n") catch {};
}

fn streamBusPcmFromEngine(
    manager: *OutputExposureManager,
    engine: *audio_engine_mod.AudioEngine,
    stream: std.net.Stream,
    route: ResolvedRoute,
) !void {
    const consumer_id = try std.fmt.allocPrint(manager.allocator, "web:{s}:{d}", .{ route.path, std.time.nanoTimestamp() });
    defer manager.allocator.free(consumer_id);
    defer engine.releaseBusTapConsumer(route.bus_id, consumer_id);
    var pcm_buffer = bus_buffer_mod.BusConsumerBuffer.init(manager.allocator);
    defer pcm_buffer.deinit();

    const sample_rate_hz = if (engine.busLevels(route.bus_id)) |bus_metrics|
        if (bus_metrics.generation != 0) @as(u32, 48_000) else @as(u32, 48_000)
    else
        48_000;
    _ = sample_rate_hz;

    try stream.writeAll(
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: application/octet-stream\r\n" ++
            "X-WireDeck-Format: pcm_s16le\r\n" ++
            "X-WireDeck-Rate: 48000\r\n" ++
            "X-WireDeck-Channels: 2\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "Cache-Control: no-store\r\n" ++
            "Connection: close\r\n\r\n",
    );

    var frame_buffer: [1920]i16 = undefined;
    var scratch_buffer: [bus_buffer_mod.render_quantum_frames * bus_buffer_mod.stereo_channels]i16 = undefined;
    var byte_buffer: [3840]u8 = undefined;
    var chunk_header_buffer: [32]u8 = undefined;
    const chunk_frames = frame_buffer.len / bus_buffer_mod.stereo_channels;

    while (isRouteStillExposed(manager, route.bus_id)) {
        _ = pcm_buffer.fillFromEngine(
            engine,
            route.bus_id,
            consumer_id,
            chunk_frames,
            scratch_buffer[0..],
        ) catch {};
        if (pcm_buffer.availableFrames() < chunk_frames) {
            std.Thread.sleep(bus_buffer_mod.render_quantum_ns);
            continue;
        }

        const read_frames = pcm_buffer.drainFrames(frame_buffer[0..], chunk_frames);
        if (read_frames == 0) continue;

        const sample_count = read_frames * bus_buffer_mod.stereo_channels;
        for (frame_buffer[0..sample_count], 0..) |sample, index| {
            std.mem.writeInt(i16, byte_buffer[index * 2 ..][0..2], sample, .little);
        }
        const byte_len = sample_count * @sizeOf(i16);
        const chunk_header = std.fmt.bufPrint(&chunk_header_buffer, "{x}\r\n", .{byte_len}) catch break;
        stream.writeAll(chunk_header) catch break;
        stream.writeAll(byte_buffer[0..byte_len]) catch break;
        stream.writeAll("\r\n") catch break;
    }
    stream.writeAll("0\r\n\r\n") catch {};
}

fn collectDesiredOutputs(
    allocator: std.mem.Allocator,
    state_store: *const StateStore,
    pulse_snapshot: pulse.PulseSnapshot,
    desired_bus_destination_loopbacks: *std.ArrayList(OutputExposureManager.DesiredBusDestinationLoopback),
    desired_mics: *std.ArrayList(OutputExposureManager.DesiredVirtualMic),
) !void {
    for (state_store.buses.items) |bus| {
        if (bus.hidden or bus.role == .input_stage) continue;
        const target_summary = summarizeBusTargets(state_store, pulse_snapshot, bus);

        if (target_summary.needsVirtualBus(bus)) {
            for (state_store.bus_destinations.items) |bus_destination| {
                if (!bus_destination.enabled) continue;
                if (!std.mem.eql(u8, bus_destination.bus_id, bus.id)) continue;

                const destination = findDestination(state_store.destinations.items, bus_destination.destination_id) orelse continue;
                const sink = resolvePulseSinkForDestination(pulse_snapshot, destination) orelse continue;
                const sink_name = sink.name orelse continue;
                try desired_bus_destination_loopbacks.append(allocator, .{
                    .bus_id = bus.id,
                    .target_sink_name = try allocator.dupe(u8, sink_name),
                });
            }
        }

        if (bus.expose_as_microphone) {
            if (enable_virtual_mic_debug_logs) {
                std.log.info("virtual mic desired-from-bus: bus={s} label={s} hidden={any} role={s}", .{
                    bus.id,
                    bus.label,
                    bus.hidden,
                    @tagName(bus.role),
                });
            }
            try desired_mics.append(allocator, .{
                .bus_id = bus.id,
                .bus_label = bus.label,
            });
        } else if (enable_virtual_mic_debug_logs) {
            std.log.info("virtual mic skipped-bus: bus={s} label={s} expose_as_microphone=false", .{
                bus.id,
                bus.label,
            });
        }
    }
}

pub fn summarizeBusTargets(
    state_store: *const StateStore,
    pulse_snapshot: pulse.PulseSnapshot,
    bus: buses_mod.Bus,
) BusTargetSummary {
    var summary = BusTargetSummary{};

    for (state_store.bus_destinations.items) |bus_destination| {
        if (!bus_destination.enabled) continue;
        if (!std.mem.eql(u8, bus_destination.bus_id, bus.id)) continue;

        const destination = findDestination(state_store.destinations.items, bus_destination.destination_id) orelse continue;
        const sink = resolvePulseSinkForDestination(pulse_snapshot, destination) orelse continue;

        if (summary.single_sink) |existing| {
            if (existing.index == sink.index) continue;
        }

        summary.count += 1;
        summary.single_sink = sink;
        if (summary.count > 1) {
            summary.single_sink = null;
            break;
        }
    }

    return summary;
}

fn computeExposurePlanSignature(state_store: *const StateStore, pulse_snapshot: pulse.PulseSnapshot) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (state_store.buses.items) |bus| {
        const summary = summarizeBusTargets(state_store, pulse_snapshot, bus);
        hasher.update(bus.id);
        hasher.update(std.mem.asBytes(&bus.share_on_network));
        hasher.update(std.mem.asBytes(&bus.expose_as_microphone));
        hasher.update(std.mem.asBytes(&summary.count));
        if (summary.single_sink) |sink| hasher.update(std.mem.asBytes(&sink.index));
    }
    return hasher.final();
}

fn logExposurePlan(state_store: *const StateStore, pulse_snapshot: pulse.PulseSnapshot) void {
    for (state_store.buses.items) |bus| {
        const summary = summarizeBusTargets(state_store, pulse_snapshot, bus);
        if (summary.needsVirtualBus(bus) or bus.share_on_network or bus.expose_as_microphone) {
            if (enable_output_exposure_info_logs) {
                std.log.info(
                    "routing bus {s}: internal route targets={d} network={any} mic={any}",
                    .{ bus.id, summary.count, bus.share_on_network, bus.expose_as_microphone },
                );
            }
            continue;
        }

        if (enable_output_exposure_info_logs) std.log.info("routing bus {s}: no resolved sink targets", .{bus.id});
    }
}

fn isOutputExposureManagedModule(name: []const u8, argument: []const u8) bool {
    if (std.mem.eql(u8, name, "module-null-sink")) {
        return containsIgnoreCase(argument, "sink_name=wiredeck_output_") or
            containsIgnoreCase(argument, "sink_name=wiredeck_busmic_sink_");
    }
    if (std.mem.eql(u8, name, "module-remap-source")) {
        return containsIgnoreCase(argument, "source_name=wiredeck_busmic_");
    }
    if (std.mem.eql(u8, name, "module-loopback")) {
        return (containsIgnoreCase(argument, "source=wiredeck_output_") or
            containsIgnoreCase(argument, "source=wiredeck_busmic_") or
            containsIgnoreCase(argument, "sink=wiredeck_output_") or
            containsIgnoreCase(argument, "sink=wiredeck_busmic_sink_")) and
            containsIgnoreCase(argument, "source_dont_move=true") and
            containsIgnoreCase(argument, "sink_dont_move=true");
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

fn uniqueRoutePath(
    allocator: std.mem.Allocator,
    used_paths: *std.StringHashMap(void),
    label: []const u8,
    bus_id: []const u8,
) ![]u8 {
    const base_slug = try sanitizeRouteSegment(allocator, if (label.len > 0) label else bus_id);
    defer allocator.free(base_slug);

    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const slug = if (attempt == 0)
            try allocator.dupe(u8, base_slug)
        else
            try std.fmt.allocPrint(allocator, "{s}-{d}", .{ base_slug, attempt + 1 });
        errdefer allocator.free(slug);

        const path = try std.fmt.allocPrint(allocator, "/{s}", .{slug});
        allocator.free(slug);
        errdefer allocator.free(path);

        const entry = try used_paths.getOrPut(path);
        if (!entry.found_existing) {
            entry.key_ptr.* = path;
            return path;
        }
        allocator.free(path);
    }
}

fn sanitizeRouteSegment(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    var previous_dash = false;
    for (value) |char| {
        if (std.ascii.isAlphanumeric(char)) {
            try out.append(allocator, std.ascii.toLower(char));
            previous_dash = false;
        } else if (!previous_dash) {
            try out.append(allocator, '-');
            previous_dash = true;
        }
    }

    const raw = try out.toOwnedSlice(allocator);
    errdefer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, "-");
    if (trimmed.len == 0) {
        allocator.free(raw);
        return allocator.dupe(u8, "output");
    }
    if (trimmed.ptr == raw.ptr and trimmed.len == raw.len) return raw;
    const compact = try allocator.dupe(u8, trimmed);
    allocator.free(raw);
    return compact;
}

fn resolvePulseSinkForDestination(snapshot: pulse.PulseSnapshot, destination: destinations_mod.Destination) ?pulse.PulseSink {
    if (destination.pulse_card_index) |card_index| {
        return findPulseSinkForCardProfile(snapshot, card_index, destination.pulse_card_profile);
    }

    const sink_name = if (destination.pulse_sink_name.len != 0) destination.pulse_sink_name else return null;
    return findPulseSinkByName(snapshot, sink_name);
}

fn findPulseSinkForCardProfile(snapshot: pulse.PulseSnapshot, card_index: u32, profile: []const u8) ?pulse.PulseSink {
    for (snapshot.sinks) |sink| {
        if (sink.card_index != null and sink.card_index.? == card_index and
            sink.bluez5_profile != null and std.mem.eql(u8, sink.bluez5_profile.?, profile))
        {
            return sink;
        }
    }
    return null;
}

fn findPulseSinkByName(snapshot: pulse.PulseSnapshot, sink_name: []const u8) ?pulse.PulseSink {
    for (snapshot.sinks) |sink| {
        const current_name = sink.name orelse continue;
        if (std.mem.eql(u8, current_name, sink_name)) return sink;
    }
    return null;
}

fn findDestination(items: []const destinations_mod.Destination, id: []const u8) ?destinations_mod.Destination {
    for (items) |destination| {
        if (std.mem.eql(u8, destination.id, id)) return destination;
    }
    return null;
}

fn findDesiredMic(items: []const OutputExposureManager.DesiredVirtualMic, bus_id: []const u8) ?OutputExposureManager.DesiredVirtualMic {
    for (items) |item| {
        if (std.mem.eql(u8, item.bus_id, bus_id)) return item;
    }
    return null;
}

fn findDesiredOutputBus(items: []const OutputExposureManager.DesiredOutputBus, bus_id: []const u8) ?OutputExposureManager.DesiredOutputBus {
    for (items) |item| {
        if (std.mem.eql(u8, item.bus_id, bus_id)) return item;
    }
    return null;
}

fn findManagedMic(items: []const OutputExposureManager.ManagedVirtualMic, bus_id: []const u8) ?usize {
    for (items, 0..) |item, index| {
        if (std.mem.eql(u8, item.bus_id, bus_id)) return index;
    }
    return null;
}

fn findManagedOutputBus(items: []const OutputExposureManager.ManagedOutputBus, bus_id: []const u8) ?usize {
    for (items, 0..) |item, index| {
        if (std.mem.eql(u8, item.bus_id, bus_id)) return index;
    }
    return null;
}

fn containsDesiredBusLoopback(items: []const OutputExposureManager.DesiredBusDestinationLoopback, bus_id: []const u8, target_sink_name: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item.bus_id, bus_id) and std.mem.eql(u8, item.target_sink_name, target_sink_name)) return true;
    }
    return false;
}

fn findManagedBusLoopback(items: []const OutputExposureManager.ManagedBusDestinationLoopback, bus_id: []const u8, target_sink_name: []const u8) ?usize {
    for (items, 0..) |item, index| {
        if (std.mem.eql(u8, item.bus_id, bus_id) and std.mem.eql(u8, item.target_sink_name, target_sink_name)) return index;
    }
    return null;
}

fn loadOutputBus(
    manager: *OutputExposureManager,
    desired: OutputExposureManager.DesiredOutputBus,
    pulsectx: *pulse.PulseContext,
) !OutputExposureManager.ManagedOutputBus {
    _ = pulsectx;
    const engine = manager.engine orelse return error.AudioEngineUnavailable;
    const source_name = try allocSafeName(manager.allocator, output_sink_prefix, desired.bus_id);
    errdefer manager.allocator.free(source_name);

    const escaped_label = try escapePactlValue(manager.allocator, desired.bus_label);
    defer manager.allocator.free(escaped_label);
    const description = try std.fmt.allocPrint(manager.allocator, "{s}{s}", .{ output_description_prefix, escaped_label });
    defer manager.allocator.free(description);

    const source = try virtual_mic_source_mod.VirtualMicSource.init(
        manager.allocator,
        engine,
        desired.bus_id,
        source_name,
        source_name,
        description,
    );
    std.log.info("output exposure: created bus source {s} for bus {s}", .{
        source_name,
        desired.bus_id,
    });

    return .{
        .bus_id = try manager.allocator.dupe(u8, desired.bus_id),
        .bus_label = try manager.allocator.dupe(u8, desired.bus_label),
        .source_name = source_name,
        .source = source,
    };
}

fn loadBusDestinationLoopback(
    manager: *OutputExposureManager,
    desired: OutputExposureManager.DesiredBusDestinationLoopback,
) !OutputExposureManager.ManagedBusDestinationLoopback {
    const engine = manager.engine orelse return error.AudioEngineUnavailable;
    const consumer_id = try std.fmt.allocPrint(
        manager.allocator,
        "wiredeck_busplay_{s}_{d}",
        .{ desired.bus_id, std.hash.Wyhash.hash(0, desired.target_sink_name) },
    );
    errdefer manager.allocator.free(consumer_id);
    const description = try std.fmt.allocPrint(
        manager.allocator,
        "WireDeck Bus {s} -> {s}",
        .{ desired.bus_id, desired.target_sink_name },
    );
    defer manager.allocator.free(description);
    const stream = try bus_playback_mod.BusPlayback.init(
        manager.allocator,
        engine,
        desired.bus_id,
        consumer_id,
        desired.target_sink_name,
        description,
    );
    if (enable_output_exposure_info_logs) {
        std.log.info("output exposure: created bus playback {s} for bus {s} -> {s}", .{
            consumer_id,
            desired.bus_id,
            desired.target_sink_name,
        });
    }

    return .{
        .bus_id = try manager.allocator.dupe(u8, desired.bus_id),
        .target_sink_name = try manager.allocator.dupe(u8, desired.target_sink_name),
        .consumer_id = consumer_id,
        .stream = stream,
    };
}

fn loadVirtualMic(
    manager: *OutputExposureManager,
    desired: OutputExposureManager.DesiredVirtualMic,
    pulsectx: *pulse.PulseContext,
) !OutputExposureManager.ManagedVirtualMic {
    _ = pulsectx;
    const started_ns = std.time.nanoTimestamp();
    const engine = manager.engine orelse return error.AudioEngineUnavailable;
    const consumer_id = try allocSafeName(manager.allocator, remap_source_prefix, desired.bus_id);
    errdefer manager.allocator.free(consumer_id);
    const source_name = try allocVirtualMicNodeName(manager.allocator, desired.bus_label, desired.bus_id);
    errdefer manager.allocator.free(source_name);
    const description = try allocVirtualMicDisplayName(manager.allocator, desired.bus_label, desired.bus_id);
    defer manager.allocator.free(description);

    const source = try virtual_mic_source_mod.VirtualMicSource.init(
        manager.allocator,
        engine,
        desired.bus_id,
        consumer_id,
        source_name,
        description,
    );
    manager.allocator.free(consumer_id);
    const duration_ns = std.time.nanoTimestamp() - started_ns;
    if (duration_ns >= virtual_mic_create_warn_threshold_ns) {
        std.log.warn("virtual mic create slow: bus={s} source={s} duration_ns={d}", .{
            desired.bus_id,
            source_name,
            duration_ns,
        });
    }

    return .{
        .bus_id = try manager.allocator.dupe(u8, desired.bus_id),
        .bus_label = try manager.allocator.dupe(u8, desired.bus_label),
        .source_name = source_name,
        .source = source,
    };
}

fn unloadVirtualMic(
    manager: *OutputExposureManager,
    mic: OutputExposureManager.ManagedVirtualMic,
    pulsectx: *pulse.PulseContext,
) !void {
    _ = manager;
    _ = pulsectx;
    mic.source.deinit();
}

fn isManagedVirtualMicSourceName(snapshot: pulse.PulseSnapshot, source_name: []const u8) bool {
    for (snapshot.sources) |source| {
        const current_name = source.name orelse continue;
        if (!std.mem.eql(u8, current_name, source_name)) continue;
        return isManagedVirtualMicSource(snapshot, source);
    }
    return false;
}

fn isManagedVirtualMicSource(snapshot: pulse.PulseSnapshot, source: pulse.PulseSource) bool {
    const current_name = source.name orelse "";
    const description = source.description orelse "";
    if (std.mem.startsWith(u8, current_name, remap_source_prefix)) return true;
    if (std.mem.startsWith(u8, current_name, "WireDeck_")) return true;
    if (std.mem.startsWith(u8, description, mic_description_prefix)) return true;

    if (source.monitor_of_sink) |sink_index| {
        for (snapshot.sinks) |sink| {
            if (sink.index != sink_index) continue;
            const sink_description = sink.description orelse "";
            if (std.mem.startsWith(u8, sink_description, mic_description_prefix)) return true;
            const sink_name = sink.name orelse "";
            if (std.mem.startsWith(u8, sink_name, remap_source_prefix)) return true;
            if (std.mem.startsWith(u8, sink_name, "WireDeck_")) return true;
        }
    }
    return false;
}

fn unloadOutputBus(
    manager: *OutputExposureManager,
    bus: OutputExposureManager.ManagedOutputBus,
    pulsectx: *pulse.PulseContext,
) !void {
    _ = manager;
    _ = pulsectx;
    bus.source.deinit();
}

fn allocSafeName(allocator: std.mem.Allocator, prefix: []const u8, id: []const u8) ![]u8 {
    var name = try allocator.alloc(u8, prefix.len + id.len);
    @memcpy(name[0..prefix.len], prefix);
    for (id, prefix.len..) |char, index| {
        name[index] = if (std.ascii.isAlphanumeric(char)) std.ascii.toLower(char) else '_';
    }
    return name;
}

fn allocSafeNamePreserveCase(allocator: std.mem.Allocator, prefix: []const u8, id: []const u8) ![]u8 {
    var name = try allocator.alloc(u8, prefix.len + id.len);
    @memcpy(name[0..prefix.len], prefix);
    for (id, prefix.len..) |char, index| {
        name[index] = if (std.ascii.isAlphanumeric(char)) char else '_';
    }
    return name;
}

fn escapePactlValue(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    for (value) |char| {
        if (char == '"' or char == '\\') try out.append(allocator, '\\');
        try out.append(allocator, char);
    }
    return out.toOwnedSlice(allocator);
}

fn setPipeWireDefaultAudioSource(allocator: std.mem.Allocator, source_name: []const u8) !void {
    const configured_value = try std.fmt.allocPrint(allocator, "{{ \"name\": \"{s}\" }}", .{source_name});
    defer allocator.free(configured_value);
    const effective_value = try std.fmt.allocPrint(allocator, "{{\"name\":\"{s}\"}}", .{source_name});
    defer allocator.free(effective_value);

    try runHostCommand(allocator, &.{ "pw-metadata", "-n", "default", "0", "default.configured.audio.source", configured_value });
    try runHostCommand(allocator, &.{ "pw-metadata", "-n", "default", "0", "default.audio.source", effective_value });
}

fn deleteManagedDefaultAudioSourceMetadata(allocator: std.mem.Allocator) !void {
    const output = try runHostCommandCapture(allocator, &.{ "pw-metadata", "-n", "default" });
    defer allocator.free(output);

    if (try parseDefaultAudioSourceNameForKey(allocator, output, "default.configured.audio.source")) |value| {
        defer allocator.free(value);
        if (isManagedVirtualMicIdentifier(value)) {
            runHostCommand(allocator, &.{ "pw-metadata", "-n", "default", "-d", "0", "default.configured.audio.source" }) catch |err| switch (err) {
                error.HostCommandFailed => {},
                else => return err,
            };
        }
    }

    if (try parseDefaultAudioSourceNameForKey(allocator, output, "default.audio.source")) |value| {
        defer allocator.free(value);
        if (isManagedVirtualMicIdentifier(value)) {
            runHostCommand(allocator, &.{ "pw-metadata", "-n", "default", "-d", "0", "default.audio.source" }) catch |err| switch (err) {
                error.HostCommandFailed => {},
                else => return err,
            };
        }
    }
}

fn isManagedVirtualMicIdentifier(value: []const u8) bool {
    return std.mem.startsWith(u8, value, remap_source_prefix) or
        std.mem.startsWith(u8, value, "WireDeck_") or
        std.mem.startsWith(u8, value, mic_description_prefix);
}

fn currentDefaultAudioSourceName(allocator: std.mem.Allocator) !?[]u8 {
    const output = try runHostCommandCapture(allocator, &.{ "pw-metadata", "-n", "default" });
    defer allocator.free(output);

    if (try parseDefaultAudioSourceNameForKey(allocator, output, "default.configured.audio.source")) |value| {
        return value;
    }
    return parseDefaultAudioSourceNameForKey(allocator, output, "default.audio.source");
}

fn parseDefaultAudioSourceNameForKey(allocator: std.mem.Allocator, output: []const u8, key: []const u8) !?[]u8 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const key_pattern = try std.fmt.allocPrint(allocator, "key:'{s}'", .{key});
        defer allocator.free(key_pattern);
        if (std.mem.indexOf(u8, line, key_pattern) == null) continue;
        const marker = "value:'";
        const start = std.mem.indexOf(u8, line, marker) orelse continue;
        const value_start = start + marker.len;
        const value_end = std.mem.lastIndexOfScalar(u8, line, '\'') orelse continue;
        if (value_end <= value_start) continue;
        const json = line[value_start..value_end];
        const name_key_start = std.mem.indexOf(u8, json, "\"name\"") orelse continue;
        const colon_index = std.mem.indexOfScalarPos(u8, json, name_key_start + "\"name\"".len, ':') orelse continue;
        const source_start = std.mem.indexOfScalarPos(u8, json, colon_index + 1, '"') orelse continue;
        const source_end_rel = std.mem.indexOfScalarPos(u8, json, source_start + 1, '"') orelse continue;
        if (source_end_rel <= source_start + 1) continue;
        const actual_start = source_start + 1;
        const value = try allocator.dupe(u8, json[actual_start..source_end_rel]);
        return value;
    }
    return null;
}

fn runHostCommand(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const output = try runHostCommandCapture(allocator, argv);
    allocator.free(output);
}

fn runHostCommandCapture(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const use_flatpak_host = std.process.hasEnvVarConstant("FLATPAK_ID");
    const command_argv = if (use_flatpak_host) blk: {
        const host_argv = try allocator.alloc([]const u8, argv.len + 2);
        host_argv[0] = "flatpak-spawn";
        host_argv[1] = "--host";
        @memcpy(host_argv[2..], argv);
        break :blk host_argv;
    } else argv;
    defer if (use_flatpak_host) allocator.free(command_argv);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = command_argv,
        .max_output_bytes = 64 * 1024,
    });
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) {
            allocator.free(result.stdout);
            return error.HostCommandFailed;
        },
        else => {
            allocator.free(result.stdout);
            return error.HostCommandFailed;
        },
    }
    return result.stdout;
}

fn wakeServer(port: u16) void {
    const address = std.net.Address.parseIp4("127.0.0.1", port) catch return;
    const stream = std.net.tcpConnectToAddress(address) catch return;
    stream.close();
}
