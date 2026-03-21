const builtin = @import("builtin");
const std = @import("std");
const StateStore = @import("../app/state_store.zig").StateStore;
const buses_mod = @import("audio/buses.zig");
const destinations_mod = @import("audio/destinations.zig");
const pulse = @import("pulse.zig");

const default_http_port: u16 = 8787;
const output_sink_prefix = "wiredeck_output_";
const null_sink_prefix = "wiredeck_busmic_sink_";
const remap_source_prefix = "wiredeck_busmic_";
const mic_description_prefix = "WireDeck Mic ";
const output_description_prefix = "WireDeck Output ";

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
        target_monitor_source_name: []u8,
        sink_name: []u8,
        source_name: []u8,
        sink_module_id: u32,
        remap_source_module_id: u32,
        loopback_module_id: u32,

        fn deinit(self: *ManagedVirtualMic, allocator: std.mem.Allocator) void {
            allocator.free(self.bus_id);
            allocator.free(self.target_monitor_source_name);
            allocator.free(self.sink_name);
            allocator.free(self.source_name);
        }
    };

    const ManagedOutputBus = struct {
        bus_id: []u8,
        sink_name: []u8,
        module_id: u32,

        fn deinit(self: *ManagedOutputBus, allocator: std.mem.Allocator) void {
            allocator.free(self.bus_id);
            allocator.free(self.sink_name);
        }
    };

    const DesiredOutputBus = struct {
        bus_id: []const u8,
        bus_label: []const u8,
    };

    const ManagedBusDestinationLoopback = struct {
        bus_id: []u8,
        sink_name: []u8,
        target_sink_name: []u8,
        module_id: u32,

        fn deinit(self: *ManagedBusDestinationLoopback, allocator: std.mem.Allocator) void {
            allocator.free(self.bus_id);
            allocator.free(self.sink_name);
            allocator.free(self.target_sink_name);
        }
    };

    const DesiredBusDestinationLoopback = struct {
        bus_id: []const u8,
        sink_name: []u8,
        target_sink_name: []u8,

        fn deinit(self: *DesiredBusDestinationLoopback, allocator: std.mem.Allocator) void {
            allocator.free(self.sink_name);
            allocator.free(self.target_sink_name);
        }
    };

    const DesiredVirtualMic = struct {
        bus_id: []const u8,
        bus_label: []const u8,
        target_monitor_source_name: []u8,

        fn deinit(self: *DesiredVirtualMic, allocator: std.mem.Allocator) void {
            allocator.free(self.target_monitor_source_name);
        }
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
    did_initial_recovery_cleanup: bool,

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
            .did_initial_recovery_cleanup = false,
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
    }

    pub fn start(self: *OutputExposureManager) !void {
        if (builtin.is_test or self.server_thread != null) return;
        self.stop_requested.store(false, .monotonic);
        self.server_thread = try std.Thread.spawn(.{}, serverMain, .{self});
    }

    pub fn stopServer(self: *OutputExposureManager) void {
        self.stop_requested.store(true, .monotonic);
        wakeServer(self.port);
        if (self.server_thread) |thread| {
            thread.join();
            self.server_thread = null;
        }
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

        var desired_output_buses = std.ArrayList(DesiredOutputBus).empty;
        defer desired_output_buses.deinit(self.allocator);

        var desired_bus_destination_loopbacks = std.ArrayList(DesiredBusDestinationLoopback).empty;
        defer {
            for (desired_bus_destination_loopbacks.items) |*item| item.deinit(self.allocator);
            desired_bus_destination_loopbacks.deinit(self.allocator);
        }

        var desired_routes = std.ArrayList(DesiredWebRoute).empty;
        defer {
            for (desired_routes.items) |*route| route.deinit(self.allocator);
            desired_routes.deinit(self.allocator);
        }

        var desired_mics = std.ArrayList(DesiredVirtualMic).empty;
        defer {
            for (desired_mics.items) |*mic| mic.deinit(self.allocator);
            desired_mics.deinit(self.allocator);
        }

        try collectDesiredOutputs(
            self.allocator,
            state_store,
            pulse_snapshot,
            &desired_output_buses,
            &desired_bus_destination_loopbacks,
            &desired_routes,
            &desired_mics,
        );
        try self.syncOutputBuses(desired_output_buses.items, pulsectx);
        try self.syncBusDestinationLoopbacks(desired_bus_destination_loopbacks.items, pulsectx);
        try self.replaceRoutes(desired_routes.items);
        try self.syncVirtualMics(desired_mics.items, pulsectx);
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

        for (self.virtual_mics.items) |*mic| mic.deinit(self.allocator);
        self.virtual_mics.clearRetainingCapacity();
        for (self.bus_destination_loopbacks.items) |*item| item.deinit(self.allocator);
        self.bus_destination_loopbacks.clearRetainingCapacity();
        for (self.output_buses.items) |*bus| bus.deinit(self.allocator);
        self.output_buses.clearRetainingCapacity();
        self.clearRoutes();
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
            if (desired_item == null or !std.mem.eql(u8, existing.target_monitor_source_name, desired_item.?.target_monitor_source_name)) {
                try unloadVirtualMic(self, existing, pulsectx);
                var removed = self.virtual_mics.orderedRemove(index);
                removed.deinit(self.allocator);
                continue;
            }
            index += 1;
        }

        for (desired) |item| {
            if (findManagedMic(self.virtual_mics.items, item.bus_id) != null) continue;
            const managed = try loadVirtualMic(self, item, pulsectx);
            try self.virtual_mics.append(self.allocator, managed);
        }
    }

    fn syncOutputBuses(self: *OutputExposureManager, desired: []const DesiredOutputBus, pulsectx: *pulse.PulseContext) !void {
        var index: usize = 0;
        while (index < self.output_buses.items.len) {
            const existing = self.output_buses.items[index];
            if (findDesiredOutputBus(desired, existing.bus_id) == null) {
                pulsectx.unloadModule(existing.module_id) catch {};
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

    fn syncBusDestinationLoopbacks(self: *OutputExposureManager, desired: []const DesiredBusDestinationLoopback, pulsectx: *pulse.PulseContext) !void {
        var index: usize = 0;
        while (index < self.bus_destination_loopbacks.items.len) {
            const existing = self.bus_destination_loopbacks.items[index];
            if (!containsDesiredBusLoopback(desired, existing.bus_id, existing.target_sink_name)) {
                pulsectx.unloadModule(existing.module_id) catch {};
                var removed = self.bus_destination_loopbacks.orderedRemove(index);
                removed.deinit(self.allocator);
                continue;
            }
            index += 1;
        }

        for (desired) |item| {
            if (findManagedBusLoopback(self.bus_destination_loopbacks.items, item.bus_id, item.target_sink_name) != null) continue;
            const managed = try loadBusDestinationLoopback(self, item, pulsectx);
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

    fn unloadAllOutputBuses(self: *OutputExposureManager) !void {
        const pulsectx = try pulse.PulseContext.init(self.allocator);
        defer pulsectx.deinit();
        for (self.output_buses.items) |bus| {
            pulsectx.unloadModule(bus.module_id) catch {};
        }
    }

    fn unloadAllBusDestinationLoopbacks(self: *OutputExposureManager) !void {
        const pulsectx = try pulse.PulseContext.init(self.allocator);
        defer pulsectx.deinit();
        for (self.bus_destination_loopbacks.items) |item| {
            pulsectx.unloadModule(item.module_id) catch {};
        }
    }
};

pub fn allocOutputSinkName(allocator: std.mem.Allocator, bus_id: []const u8) ![]u8 {
    return allocSafeName(allocator, output_sink_prefix, bus_id);
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

fn collectDesiredOutputs(
    allocator: std.mem.Allocator,
    state_store: *const StateStore,
    pulse_snapshot: pulse.PulseSnapshot,
    desired_output_buses: *std.ArrayList(OutputExposureManager.DesiredOutputBus),
    desired_bus_destination_loopbacks: *std.ArrayList(OutputExposureManager.DesiredBusDestinationLoopback),
    desired_routes: *std.ArrayList(OutputExposureManager.DesiredWebRoute),
    desired_mics: *std.ArrayList(OutputExposureManager.DesiredVirtualMic),
) !void {
    var used_paths = std.StringHashMap(void).init(allocator);
    defer used_paths.deinit();

    for (state_store.buses.items) |bus| {
        if (bus.hidden or bus.role == .input_stage) continue;
        try desired_output_buses.append(allocator, .{
            .bus_id = bus.id,
            .bus_label = bus.label,
        });

        const sink_name = try allocSafeName(allocator, output_sink_prefix, bus.id);
        defer allocator.free(sink_name);
        const monitor_source_name = try std.fmt.allocPrint(allocator, "{s}.monitor", .{sink_name});
        errdefer allocator.free(monitor_source_name);

        for (state_store.bus_destinations.items) |bus_destination| {
            if (!bus_destination.enabled) continue;
            if (!std.mem.eql(u8, bus_destination.bus_id, bus.id)) continue;
            const destination = findDestination(state_store.destinations.items, bus_destination.destination_id) orelse continue;
            const sink = resolvePulseSinkForDestination(pulse_snapshot, destination) orelse continue;
            const target_sink_name = sink.name orelse continue;
            try desired_bus_destination_loopbacks.append(allocator, .{
                .bus_id = bus.id,
                .sink_name = try allocator.dupe(u8, sink_name),
                .target_sink_name = try allocator.dupe(u8, target_sink_name),
            });
        }

        if (bus.expose_on_web) {
            const route_path = try uniqueRoutePath(allocator, &used_paths, bus.label, bus.id);
            errdefer allocator.free(route_path);
            try desired_routes.append(allocator, .{
                .bus_id = bus.id,
                .label = bus.label,
                .path = route_path,
                .monitor_source_name = try allocator.dupe(u8, monitor_source_name),
            });
        }

        if (bus.expose_as_microphone) {
            try desired_mics.append(allocator, .{
                .bus_id = bus.id,
                .bus_label = bus.label,
                .target_monitor_source_name = try allocator.dupe(u8, monitor_source_name),
            });
        }

        allocator.free(monitor_source_name);
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
    const sink_name = try allocSafeName(manager.allocator, output_sink_prefix, desired.bus_id);
    errdefer manager.allocator.free(sink_name);

    const escaped_label = try escapePactlValue(manager.allocator, desired.bus_label);
    defer manager.allocator.free(escaped_label);
    const description = try std.fmt.allocPrint(manager.allocator, "{s}{s}", .{ output_description_prefix, escaped_label });
    defer manager.allocator.free(description);

    const sink_props = try std.fmt.allocPrint(
        manager.allocator,
        "\"device.description='{s}' node.description='{s}' node.virtual=true node.hidden=true device.class=filter media.class=Audio/Sink\"",
        .{ description, description },
    );
    defer manager.allocator.free(sink_props);
    const sink_args = try std.fmt.allocPrint(manager.allocator, "sink_name={s} sink_properties={s}", .{ sink_name, sink_props });
    defer manager.allocator.free(sink_args);
    const module_id = try pulsectx.loadModule("module-null-sink", sink_args);

    return .{
        .bus_id = try manager.allocator.dupe(u8, desired.bus_id),
        .sink_name = sink_name,
        .module_id = module_id,
    };
}

fn loadBusDestinationLoopback(
    manager: *OutputExposureManager,
    desired: OutputExposureManager.DesiredBusDestinationLoopback,
    pulsectx: *pulse.PulseContext,
) !OutputExposureManager.ManagedBusDestinationLoopback {
    const source_name = try std.fmt.allocPrint(manager.allocator, "{s}.monitor", .{desired.sink_name});
    defer manager.allocator.free(source_name);
    const loopback_args = try std.fmt.allocPrint(
        manager.allocator,
        "source={s} sink={s} source_dont_move=true sink_dont_move=true",
        .{ source_name, desired.target_sink_name },
    );
    defer manager.allocator.free(loopback_args);
    const module_id = try pulsectx.loadModule("module-loopback", loopback_args);

    return .{
        .bus_id = try manager.allocator.dupe(u8, desired.bus_id),
        .sink_name = try manager.allocator.dupe(u8, desired.sink_name),
        .target_sink_name = try manager.allocator.dupe(u8, desired.target_sink_name),
        .module_id = module_id,
    };
}

fn loadVirtualMic(
    manager: *OutputExposureManager,
    desired: OutputExposureManager.DesiredVirtualMic,
    pulsectx: *pulse.PulseContext,
) !OutputExposureManager.ManagedVirtualMic {
    const sink_name = try allocSafeName(manager.allocator, null_sink_prefix, desired.bus_id);
    errdefer manager.allocator.free(sink_name);
    const source_name = try allocSafeName(manager.allocator, remap_source_prefix, desired.bus_id);
    errdefer manager.allocator.free(source_name);

    const escaped_label = try escapePactlValue(manager.allocator, desired.bus_label);
    defer manager.allocator.free(escaped_label);
    const description = try std.fmt.allocPrint(manager.allocator, "{s}{s}", .{ mic_description_prefix, escaped_label });
    defer manager.allocator.free(description);

    const sink_props = try std.fmt.allocPrint(
        manager.allocator,
        "\"device.description='{s}' node.description='{s}' node.virtual=true node.hidden=true device.class=filter media.class=Audio/Sink\"",
        .{ description, description },
    );
    defer manager.allocator.free(sink_props);
    const sink_args = try std.fmt.allocPrint(manager.allocator, "sink_name={s} sink_properties={s}", .{ sink_name, sink_props });
    defer manager.allocator.free(sink_args);
    const sink_module_id = try pulsectx.loadModule("module-null-sink", sink_args);
    errdefer pulsectx.unloadModule(sink_module_id) catch {};

    const source_props = try std.fmt.allocPrint(
        manager.allocator,
        "\"device.description='{s}' node.description='{s}' device.class=filter media.class=Audio/Source\"",
        .{ description, description },
    );
    defer manager.allocator.free(source_props);
    const remap_args = try std.fmt.allocPrint(
        manager.allocator,
        "source_name={s} master={s}.monitor source_properties={s}",
        .{ source_name, sink_name, source_props },
    );
    defer manager.allocator.free(remap_args);
    const remap_source_module_id = try pulsectx.loadModule("module-remap-source", remap_args);
    errdefer pulsectx.unloadModule(remap_source_module_id) catch {};

    const loopback_args = try std.fmt.allocPrint(
        manager.allocator,
        "source={s} sink={s} source_dont_move=true sink_dont_move=true",
        .{ desired.target_monitor_source_name, sink_name },
    );
    defer manager.allocator.free(loopback_args);
    const loopback_module_id = try pulsectx.loadModule("module-loopback", loopback_args);
    errdefer pulsectx.unloadModule(loopback_module_id) catch {};

    return .{
        .bus_id = try manager.allocator.dupe(u8, desired.bus_id),
        .target_monitor_source_name = try manager.allocator.dupe(u8, desired.target_monitor_source_name),
        .sink_name = sink_name,
        .source_name = source_name,
        .sink_module_id = sink_module_id,
        .remap_source_module_id = remap_source_module_id,
        .loopback_module_id = loopback_module_id,
    };
}

fn unloadVirtualMic(
    manager: *OutputExposureManager,
    mic: OutputExposureManager.ManagedVirtualMic,
    pulsectx: *pulse.PulseContext,
) !void {
    _ = manager;
    pulsectx.unloadModule(mic.loopback_module_id) catch {};
    pulsectx.unloadModule(mic.remap_source_module_id) catch {};
    pulsectx.unloadModule(mic.sink_module_id) catch {};
}

fn allocSafeName(allocator: std.mem.Allocator, prefix: []const u8, id: []const u8) ![]u8 {
    var name = try allocator.alloc(u8, prefix.len + id.len);
    @memcpy(name[0..prefix.len], prefix);
    for (id, prefix.len..) |char, index| {
        name[index] = if (std.ascii.isAlphanumeric(char)) std.ascii.toLower(char) else '_';
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

fn wakeServer(port: u16) void {
    const address = std.net.Address.parseIp4("127.0.0.1", port) catch return;
    const stream = std.net.tcpConnectToAddress(address) catch return;
    stream.close();
}
