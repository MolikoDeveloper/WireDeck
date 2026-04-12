const std = @import("std");
const sources_mod = @import("../audio/sources.zig");
const destinations_mod = @import("../audio/destinations.zig");
const RegistrySnapshot = @import("registry.zig").RegistrySnapshot;

const c = @cImport({
    @cInclude("pipewire/pipewire.h");
    @cInclude("pipewire/extensions/profiler.h");
    @cInclude("pipewire/impl-module.h");
    @cInclude("pipewire/properties.h");
    @cInclude("pipewire/keys.h");
    @cInclude("spa/param/profiler.h");
    @cInclude("spa_helpers.h");
    @cInclude("spa/pod/iter.h");
    @cInclude("spa/pod/parser.h");
    @cInclude("spa/pod/pod.h");
    @cInclude("spa/utils/dict.h");
});

pub const ProfilerSample = struct {
    received_at_ns: u64,
    profiler_global_id: u32,
    pod_size: u32,
    pod_type: u32,
};

pub const Discovery = struct {
    registry_snapshot: RegistrySnapshot,
    channels: std.ArrayList(sources_mod.Source),
    destinations: std.ArrayList(destinations_mod.Destination),

    pub fn deinit(self: *Discovery, allocator: std.mem.Allocator) void {
        deinitDiscoveredChannels(allocator, &self.channels);
        deinitDiscoveredDestinations(allocator, &self.destinations);
    }
};

pub const ProfilerRingBuffer = struct {
    pub const capacity = 256;

    items: [capacity]ProfilerSample = undefined,
    next_index: usize = 0,
    len: usize = 0,

    pub fn push(self: *ProfilerRingBuffer, sample: ProfilerSample) void {
        self.items[self.next_index] = sample;
        self.next_index = (self.next_index + 1) % capacity;
        if (self.len < capacity) self.len += 1;
    }

    pub fn snapshot(self: *const ProfilerRingBuffer, allocator: std.mem.Allocator) ![]ProfilerSample {
        var out = try allocator.alloc(ProfilerSample, self.len);
        var index: usize = 0;
        while (index < self.len) : (index += 1) out[index] = self.at(index);
        return out;
    }

    pub fn at(self: *const ProfilerRingBuffer, index: usize) ProfilerSample {
        std.debug.assert(index < self.len);
        const start = if (self.len == capacity) self.next_index else 0;
        return self.items[(start + index) % capacity];
    }
};

pub const PipeWireLiveProfiler = struct {
    const EntryKind = enum {
        none,
        source,
        sink,
        stream,
    };

    const RegistryEntry = struct {
        global_id: u32,
        kind: EntryKind = .none,
        client_id: ?u32 = null,
        meter_target: ?[]u8 = null,
        source: ?sources_mod.Source = null,
        destination: ?destinations_mod.Destination = null,

        fn deinit(self: *RegistryEntry, allocator: std.mem.Allocator) void {
            if (self.meter_target) |value| allocator.free(value);
            if (self.source) |*source| freeSource(allocator, source);
            if (self.destination) |*destination| freeDestination(allocator, destination);
            self.* = .{ .global_id = self.global_id };
        }
    };

    const ClientInfo = struct {
        id: u32,
        process_binary: []u8,
        application_name: []u8,
        portal_app_id: []u8,

        fn deinit(self: *ClientInfo, allocator: std.mem.Allocator) void {
            allocator.free(self.process_binary);
            allocator.free(self.application_name);
            allocator.free(self.portal_app_id);
        }
    };

    const MeterStream = struct {
        source_global_id: u32,
        target_object: []u8,
        stream: *c.struct_pw_stream,
        listener: c.struct_spa_hook = std.mem.zeroes(c.struct_spa_hook),
        channels: u32 = 2,
        left_peak_milli: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        right_peak_milli: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn deinit(self: *MeterStream, allocator: std.mem.Allocator, destroy_stream: bool) void {
            if (destroy_stream) c.pw_stream_destroy(self.stream);
            allocator.free(self.target_object);
            allocator.destroy(self);
        }
    };

    allocator: std.mem.Allocator,
    main_loop: ?*c.struct_pw_main_loop = null,
    context: ?*c.struct_pw_context = null,
    core: ?*c.struct_pw_core = null,
    registry: ?*c.struct_pw_registry = null,
    profiler: ?*c.struct_pw_profiler = null,
    profiler_proxy: ?*c.struct_pw_proxy = null,
    profiler_module: ?*c.struct_pw_impl_module = null,
    core_listener: c.struct_spa_hook = std.mem.zeroes(c.struct_spa_hook),
    registry_listener: c.struct_spa_hook = std.mem.zeroes(c.struct_spa_hook),
    profiler_listener: c.struct_spa_hook = std.mem.zeroes(c.struct_spa_hook),
    pipewire_initialized: bool = false,
    connected: bool = false,
    profiler_global_id: ?u32 = null,
    profile_event_count: u64 = 0,
    discovery_generation: u64 = 0,
    registry_snapshot: RegistrySnapshot = .{},
    last_error_code: i32 = 0,
    last_error_message: [160]u8 = [_]u8{0} ** 160,
    samples: ProfilerRingBuffer = .{},
    entries: std.ArrayList(RegistryEntry),
    clients: std.ArrayList(ClientInfo),
    meters: std.ArrayList(*MeterStream),

    pub fn init(allocator: std.mem.Allocator) PipeWireLiveProfiler {
        return .{
            .allocator = allocator,
            .entries = std.ArrayList(RegistryEntry).empty,
            .clients = std.ArrayList(ClientInfo).empty,
            .meters = std.ArrayList(*MeterStream).empty,
        };
    }

    pub fn connect(self: *PipeWireLiveProfiler) !void {
        if (self.connected) return;

        c.pw_init(null, null);
        self.pipewire_initialized = true;

        self.main_loop = c.pw_main_loop_new(null) orelse return error.PipeWireMainLoopInitFailed;
        errdefer self.destroyMainLoop();

        const loop = c.pw_main_loop_get_loop(self.main_loop.?);
        self.context = c.pw_context_new(loop, null, 0) orelse return error.PipeWireContextInitFailed;
        errdefer self.destroyContext();

        self.core = c.pw_context_connect(self.context.?, null, 0) orelse return error.PipeWireCoreConnectFailed;
        errdefer self.disconnectCore();

        _ = c.pw_core_add_listener(self.core.?, &self.core_listener, &core_events, self);

        self.registry = c.pw_core_get_registry(self.core.?, c.PW_VERSION_REGISTRY, 0) orelse return error.PipeWireRegistryUnavailable;
        errdefer self.destroyRegistry();

        _ = c.pw_registry_add_listener(self.registry.?, &self.registry_listener, &registry_events, self);

        // Ensure the profiler module is configured to emit samples at a reasonable interval.
        // The default config in pipewire.conf can disable sampling (interval 0), so we set
        // a small interval here to ensure we receive profiler events.
        // If we fail to enable profiler sampling we continue anyway.
        self.ensureProfilerSampling(20) catch {};

        _ = c.pw_core_sync(self.core.?, c.PW_ID_CORE, 0);
        self.connected = true;
    }

    pub fn pump(self: *PipeWireLiveProfiler, timeout_ms: i32) !void {
        const main_loop = self.main_loop orelse return error.PipeWireNotConnected;
        const loop = c.pw_main_loop_get_loop(main_loop);
        const result = c.pw_loop_iterate(loop, timeout_ms);
        if (result < 0) return error.PipeWireLoopFailed;
    }

    pub fn hasProfiler(self: PipeWireLiveProfiler) bool {
        return self.profiler != null;
    }

    pub fn canPump(self: PipeWireLiveProfiler) bool {
        return self.main_loop != null;
    }

    pub fn describe(self: PipeWireLiveProfiler) []const u8 {
        return if (self.connected) "connected" else "disconnected";
    }

    pub fn snapshotDiscovery(self: *const PipeWireLiveProfiler, allocator: std.mem.Allocator) !Discovery {
        var channels = std.ArrayList(sources_mod.Source).empty;
        errdefer deinitDiscoveredChannels(allocator, &channels);
        var destinations = std.ArrayList(destinations_mod.Destination).empty;
        errdefer deinitDiscoveredDestinations(allocator, &destinations);

        for (self.entries.items) |entry| {
            if (entry.source) |source| {
                var cloned = try cloneSource(allocator, source);
                self.applyMeterLevels(entry.global_id, &cloned);
                try channels.append(allocator, cloned);
            }
            if (entry.destination) |destination| {
                var cloned = try cloneDestination(allocator, destination);
                self.applyDestinationMeterLevels(entry.global_id, &cloned);
                try destinations.append(allocator, cloned);
            }
        }

        dedupeAndSortChannels(allocator, &channels);
        dedupeAndSortDestinations(allocator, &destinations);

        return .{
            .registry_snapshot = self.registry_snapshot,
            .channels = channels,
            .destinations = destinations,
        };
    }

    pub fn injectDiscoveryForTest(
        self: *PipeWireLiveProfiler,
        sources: []const sources_mod.Source,
        destinations: []const destinations_mod.Destination,
        snapshot: RegistrySnapshot,
    ) !void {
        self.clearEntries();

        for (sources, 0..) |source, index| {
            try self.entries.append(self.allocator, .{
                .global_id = @intCast(10_000 + index),
                .kind = if (source.kind == .app) .stream else .source,
                .source = try cloneSource(self.allocator, source),
            });
        }
        for (destinations, 0..) |destination, index| {
            try self.entries.append(self.allocator, .{
                .global_id = @intCast(20_000 + index),
                .kind = .sink,
                .destination = try cloneDestination(self.allocator, destination),
            });
        }

        self.registry_snapshot = snapshot;
        self.discovery_generation += 1;
        self.connected = true;
    }

    pub fn snapshotSamples(self: *const PipeWireLiveProfiler) ![]ProfilerSample {
        return self.samples.snapshot(self.allocator);
    }

    pub fn deinit(self: *PipeWireLiveProfiler) void {
        self.clearEntries();
        self.entries.deinit(self.allocator);
        self.clearClients();
        self.clients.deinit(self.allocator);
        self.clearMeters(false);
        self.meters.deinit(self.allocator);
        self.destroyProfilerProxy();
        self.destroyProfilerModule();
        self.destroyRegistry();
        self.disconnectCore();
        self.destroyContext();
        self.destroyMainLoop();
        if (self.pipewire_initialized) {
            c.pw_deinit();
            self.pipewire_initialized = false;
        }
        self.connected = false;
    }

    fn bindProfiler(self: *PipeWireLiveProfiler, global_id: u32, version: u32) void {
        // If the profiler global changes (i.e., new module loaded) we want to re-bind.
        if (self.profiler_global_id == global_id and self.profiler_proxy != null) return;
        self.destroyProfilerProxy();

        const bind_version: u32 = @min(version, @as(u32, c.PW_VERSION_PROFILER));
        const bound = c.pw_registry_bind(self.registry.?, global_id, c.PW_TYPE_INTERFACE_Profiler, bind_version, 0) orelse return;
        self.profiler = @ptrCast(bound);
        self.profiler_proxy = @ptrCast(bound);
        self.profiler_global_id = global_id;
        _ = c.pw_profiler_add_listener(self.profiler.?, &self.profiler_listener, &profiler_events, self);
    }

    fn noteError(self: *PipeWireLiveProfiler, code: i32, message: [*c]const u8) void {
        self.last_error_code = code;
        @memset(&self.last_error_message, 0);
        const text = std.mem.span(message);
        const len = @min(text.len, self.last_error_message.len - 1);
        @memcpy(self.last_error_message[0..len], text[0..len]);
        if (code < 0) {
            self.connected = false;
            self.profiler = null;
            self.profiler_proxy = null;
            self.profiler_global_id = null;
            self.clearEntries();
            self.clearClients();
            self.clearMeters(true);
            self.discovery_generation += 1;
        }
    }

    fn disconnectCore(self: *PipeWireLiveProfiler) void {
        if (self.core) |core| {
            _ = c.pw_core_disconnect(core);
            self.core = null;
        }
    }

    fn ensureProfilerSampling(self: *PipeWireLiveProfiler, interval_ms: u32) !void {
        if (self.profiler_module != null) return;
        // The profiler module can be loaded by the server, but it may be configured
        // with a zero interval (disabled). Ensure at least one module instance is
        // loaded with a nonzero interval so profiler events are emitted.
        // PipeWire module argument strings are simple key=value lists.

        const args = try std.fmt.allocPrint(self.allocator, "profile.interval.ms={d}", .{interval_ms});
        defer self.allocator.free(args);

        const args_z = try self.allocator.alloc(u8, args.len + 1);
        defer self.allocator.free(args_z);
        std.mem.copyForwards(u8, args_z[0..args.len], args);
        args_z[args.len] = 0;

        // If the profiler module is already loaded, loading it again may simply
        // return the existing module instance. If that instance was configured with
        // a 0ms interval (disabled), destroy it and retry so we get a working one.
        var module: ?*c.struct_pw_impl_module = null;
        var attempt: u8 = 0;
        while (attempt < 2) {
            module = c.pw_context_load_module(self.context.?, c.PW_EXTENSION_MODULE_PROFILER, args_z.ptr, null);
            if (module == null) break;

            const info = c.pw_impl_module_get_info(module);
            if (info != null and info.*.args != null) {
                if (parseProfilerModuleInterval(info.*.args)) |existing_interval| {
                    if (existing_interval > 0) break;
                }
            }

            // If the loaded module is not configured with a usable interval, destroy
            // it and retry so we can get one configured correctly.
            c.pw_impl_module_destroy(module);
            module = null;
            attempt += 1;
        }

        if (module != null) {
            self.profiler_module = module;
        }
    }

    fn parseProfilerModuleInterval(args: [*c]const u8) ?u32 {
        // args is a null-terminated C string.
        var len: usize = 0;
        while (args[len] != 0) : (len += 1) {}
        const slice = args[0..len];
        const key = "profile.interval.ms";
        const key_pos = std.mem.indexOf(u8, slice, key) orelse return null;
        var i: usize = key_pos + key.len;
        while (i < slice.len and (slice[i] == ' ' or slice[i] == '\t')) : (i += 1) {}
        if (i >= slice.len or slice[i] != '=') return null;
        i += 1;
        while (i < slice.len and (slice[i] == ' ' or slice[i] == '\t')) : (i += 1) {}
        const start = i;
        while (i < slice.len and (slice[i] >= '0' and slice[i] <= '9')) : (i += 1) {}
        if (i == start) return null;
        const digits = slice[start..i];
        return std.fmt.parseInt(u32, digits, 10) catch null;
    }

    fn destroyRegistry(self: *PipeWireLiveProfiler) void {
        if (self.registry) |registry| {
            c.pw_proxy_destroy(@ptrCast(registry));
            self.registry = null;
        }
    }

    fn destroyProfilerProxy(self: *PipeWireLiveProfiler) void {
        if (self.profiler_proxy) |proxy| {
            c.pw_proxy_destroy(proxy);
            self.profiler_proxy = null;
            self.profiler = null;
            self.profiler_global_id = null;
        }
    }

    fn destroyProfilerModule(self: *PipeWireLiveProfiler) void {
        if (self.profiler_module) |module| {
            c.pw_impl_module_destroy(module);
            self.profiler_module = null;
        }
    }

    fn destroyContext(self: *PipeWireLiveProfiler) void {
        if (self.context) |context| {
            c.pw_context_destroy(context);
            self.context = null;
        }
    }

    fn destroyMainLoop(self: *PipeWireLiveProfiler) void {
        if (self.main_loop) |main_loop| {
            c.pw_main_loop_destroy(main_loop);
            self.main_loop = null;
        }
    }

    fn handleRegistryGlobal(
        self: *PipeWireLiveProfiler,
        id: u32,
        type_name: [*c]const u8,
        version: u32,
        props: ?*const c.struct_spa_dict,
    ) void {
        const interface_name = std.mem.span(type_name);
        if (std.mem.eql(u8, interface_name, std.mem.sliceTo(c.PW_TYPE_INTERFACE_Profiler, 0))) {
            self.bindProfiler(id, version);
            return;
        }
        if (std.mem.eql(u8, interface_name, "PipeWire:Interface:Client")) {
            self.upsertClientInfo(id, props orelse return) catch return;
            return;
        }
        if (!std.mem.eql(u8, interface_name, "PipeWire:Interface:Node")) return;
        self.upsertNodeEntry(id, props orelse return) catch return;
    }

    fn upsertNodeEntry(self: *PipeWireLiveProfiler, global_id: u32, props: *const c.struct_spa_dict) !void {
        const media_class = lookupProp(props, "media.class");
        const entry_kind = classifyProps(props, media_class);
        if (entry_kind == .none) return;
        const client_id = lookupClientId(props);

        var new_entry = RegistryEntry{
            .global_id = global_id,
            .kind = entry_kind,
            .client_id = client_id,
            .meter_target = try allocMeterTarget(self.allocator, props, global_id),
        };

        switch (new_entry.kind) {
            .sink => new_entry.destination = try buildDestinationFromProps(self.allocator, props, global_id),
            .source, .stream => new_entry.source = try buildSourceFromProps(
                self.allocator,
                props,
                media_class orelse defaultMediaClassForKind(entry_kind),
                global_id,
                if (client_id) |resolved_id| self.lookupClientInfo(resolved_id) else null,
            ),
            .none => {},
        }

        if (self.findEntryIndex(global_id)) |index| {
            self.entries.items[index].deinit(self.allocator);
            self.entries.items[index] = new_entry;
        } else {
            try self.entries.append(self.allocator, new_entry);
        }

        try self.syncMeterForEntry(global_id);
        self.recomputeRegistrySnapshot();
        self.discovery_generation += 1;
    }

    fn handleRegistryGlobalRemove(self: *PipeWireLiveProfiler, id: u32) void {
        if (self.profiler_global_id != null and self.profiler_global_id.? == id) self.destroyProfilerProxy();
        if (self.findEntryIndex(id)) |index| {
            self.entries.items[index].deinit(self.allocator);
            _ = self.entries.orderedRemove(index);
            self.removeMeter(id);
            self.recomputeRegistrySnapshot();
            self.discovery_generation += 1;
        }
        if (self.findClientIndex(id)) |index| {
            self.clients.items[index].deinit(self.allocator);
            _ = self.clients.orderedRemove(index);
            self.refreshStreamEntriesForClient(id);
            self.discovery_generation += 1;
        }
    }

    fn handleProfile(self: *PipeWireLiveProfiler, pod: *const c.struct_spa_pod) void {
        self.profile_event_count += 1;

        self.samples.push(.{
            .received_at_ns = nowNs(),
            .profiler_global_id = self.profiler_global_id orelse 0,
            .pod_size = pod.size,
            .pod_type = pod.type,
        });
    }

    fn entryExists(self: *PipeWireLiveProfiler, node_id: u32) bool {
        for (self.entries.items) |entry| {
            if (entry.global_id == node_id) return true;
        }
        return false;
    }

    fn findEntryIndex(self: *const PipeWireLiveProfiler, global_id: u32) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (entry.global_id == global_id) return index;
        }
        return null;
    }

    fn clearEntries(self: *PipeWireLiveProfiler) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.clearRetainingCapacity();
        self.registry_snapshot = .{};
    }

    fn clearMeters(self: *PipeWireLiveProfiler, destroy_streams: bool) void {
        for (self.meters.items) |meter| meter.deinit(self.allocator, destroy_streams);
        self.meters.clearRetainingCapacity();
    }

    fn clearClients(self: *PipeWireLiveProfiler) void {
        for (self.clients.items) |*client| client.deinit(self.allocator);
        self.clients.clearRetainingCapacity();
    }

    fn recomputeRegistrySnapshot(self: *PipeWireLiveProfiler) void {
        var snapshot = RegistrySnapshot{};
        for (self.entries.items) |entry| {
            switch (entry.kind) {
                .source => snapshot.sources += 1,
                .sink => snapshot.sinks += 1,
                .stream => snapshot.streams += 1,
                .none => {},
            }
        }
        self.registry_snapshot = snapshot;
    }

    fn upsertClientInfo(self: *PipeWireLiveProfiler, client_id: u32, props: *const c.struct_spa_dict) !void {
        const new_client = ClientInfo{
            .id = client_id,
            .process_binary = try self.allocator.dupe(u8, lookupProp(props, "application.process.binary") orelse ""),
            .application_name = try self.allocator.dupe(u8, lookupProp(props, "application.name") orelse ""),
            .portal_app_id = try self.allocator.dupe(u8, lookupProp(props, "pipewire.access.portal.app_id") orelse ""),
        };

        if (self.findClientIndex(client_id)) |index| {
            self.clients.items[index].deinit(self.allocator);
            self.clients.items[index] = new_client;
        } else {
            try self.clients.append(self.allocator, new_client);
        }

        self.refreshStreamEntriesForClient(client_id);
        self.discovery_generation += 1;
    }

    fn findClientIndex(self: *const PipeWireLiveProfiler, client_id: u32) ?usize {
        for (self.clients.items, 0..) |client, index| {
            if (client.id == client_id) return index;
        }
        return null;
    }

    fn lookupClientInfo(self: *const PipeWireLiveProfiler, client_id: u32) ?ClientInfo {
        const index = self.findClientIndex(client_id) orelse return null;
        return self.clients.items[index];
    }

    fn refreshStreamEntriesForClient(self: *PipeWireLiveProfiler, client_id: u32) void {
        const client_info = self.lookupClientInfo(client_id);
        for (self.entries.items) |*entry| {
            if (entry.kind != .stream or entry.client_id != client_id) continue;
            if (entry.source) |*source| {
                const resolved_binary = chooseProcessBinaryFromClient(client_info) orelse source.process_binary;
                updateOwnedString(self.allocator, &source.process_binary, resolved_binary) catch continue;
                updateOwnedString(self.allocator, &source.label, normalizeProcessLabel(resolved_binary, client_info)) catch continue;
                updateOwnedString(self.allocator, &source.subtitle, chooseRefreshedSourceSubtitle(source, client_info)) catch continue;
                updateOwnedString(self.allocator, &source.icon_name, chooseSourceIconNameFromBinary(resolved_binary)) catch continue;
                source.kind = .app;
            }
        }
    }

    fn syncMeterForEntry(self: *PipeWireLiveProfiler, global_id: u32) !void {
        const entry_index = self.findEntryIndex(global_id) orelse {
            self.removeMeter(global_id);
            return;
        };
        const entry = self.entries.items[entry_index];
        const meter_target = blk: {
            if (entry.meter_target) |target| break :blk target;
            if (entry.source) |source| break :blk source.id;
            if (entry.destination) |destination| break :blk destination.id;
            self.removeMeter(global_id);
            return;
        };
        if (meter_target.len == 0) {
            self.removeMeter(global_id);
            return;
        }

        if (self.findMeterIndex(global_id)) |meter_index| {
            const meter = self.meters.items[meter_index];
            if (std.mem.eql(u8, meter.target_object, meter_target)) return;
            const removed = self.meters.orderedRemove(meter_index);
            removed.deinit(self.allocator, true);
        }

        const meter = try self.createMeter(global_id, meter_target);
        try self.meters.append(self.allocator, meter);
    }

    fn createMeter(self: *PipeWireLiveProfiler, global_id: u32, target_object: []const u8) !*MeterStream {
        const meter = try self.allocator.create(MeterStream);
        errdefer self.allocator.destroy(meter);

        const target_owned = try self.allocator.dupe(u8, target_object);
        errdefer self.allocator.free(target_owned);
        const target_z = try self.allocator.dupeZ(u8, target_object);
        defer self.allocator.free(target_z);
        const meter_node_name = try std.fmt.allocPrint(self.allocator, "wiredeck_meter_{d}", .{global_id});
        defer self.allocator.free(meter_node_name);
        const meter_node_name_z = try self.allocator.dupeZ(u8, meter_node_name);
        defer self.allocator.free(meter_node_name_z);
        const stream_name = try std.fmt.allocPrint(self.allocator, "WireDeck Meter {s}", .{target_object});
        defer self.allocator.free(stream_name);
        const stream_name_z = try self.allocator.dupeZ(u8, stream_name);
        defer self.allocator.free(stream_name_z);

        const props = c.pw_properties_new(null) orelse return error.OutOfMemory;
        _ = c.pw_properties_set(props, c.PW_KEY_MEDIA_TYPE, "Audio");
        _ = c.pw_properties_set(props, c.PW_KEY_MEDIA_CATEGORY, "Capture");
        _ = c.pw_properties_set(props, c.PW_KEY_MEDIA_ROLE, "DSP");
        _ = c.pw_properties_set(props, c.PW_KEY_NODE_NAME, meter_node_name_z.ptr);
        _ = c.pw_properties_set(props, c.PW_KEY_NODE_DESCRIPTION, stream_name_z.ptr);
        _ = c.pw_properties_set(props, c.PW_KEY_TARGET_OBJECT, target_z.ptr);

        const stream = c.pw_stream_new_simple(
            c.pw_main_loop_get_loop(self.main_loop.?),
            stream_name_z.ptr,
            props,
            &meter_stream_events,
            meter,
        ) orelse return error.PipeWireMeterCreateFailed;
        errdefer c.pw_stream_destroy(stream);

        meter.* = .{
            .source_global_id = global_id,
            .target_object = target_owned,
            .stream = stream,
        };

        var params: [1]*const c.struct_spa_pod = undefined;
        var buffer: [1024]u8 = undefined;
        var builder: c.struct_spa_pod_builder = undefined;
        c.spa_pod_builder_init(&builder, &buffer, buffer.len);
        params[0] = c.wiredeck_spa_build_f32_capture_format(&builder);

        const rc = c.pw_stream_connect(
            stream,
            c.PW_DIRECTION_INPUT,
            c.PW_ID_ANY,
            c.PW_STREAM_FLAG_AUTOCONNECT | c.PW_STREAM_FLAG_MAP_BUFFERS | c.PW_STREAM_FLAG_RT_PROCESS,
            @ptrCast(&params),
            params.len,
        );
        if (rc < 0) return error.PipeWireMeterConnectFailed;

        return meter;
    }

    fn removeMeter(self: *PipeWireLiveProfiler, global_id: u32) void {
        if (self.findMeterIndex(global_id)) |index| {
            const removed = self.meters.orderedRemove(index);
            removed.deinit(self.allocator, true);
        }
    }

    fn findMeterIndex(self: *const PipeWireLiveProfiler, global_id: u32) ?usize {
        for (self.meters.items, 0..) |meter, index| {
            if (meter.source_global_id == global_id) return index;
        }
        return null;
    }

    fn applyMeterLevels(self: *const PipeWireLiveProfiler, global_id: u32, source: *sources_mod.Source) void {
        const index = self.findMeterIndex(global_id) orelse {
            source.level_left = 0.0;
            source.level_right = 0.0;
            source.level = 0.0;
            return;
        };
        const meter = self.meters.items[index];
        const left = @as(f32, @floatFromInt(meter.left_peak_milli.load(.monotonic))) / 1000.0;
        const right = @as(f32, @floatFromInt(meter.right_peak_milli.load(.monotonic))) / 1000.0;
        source.level_left = left;
        source.level_right = right;
        source.level = @max(left, right);
    }

    fn applyDestinationMeterLevels(self: *const PipeWireLiveProfiler, global_id: u32, destination: *destinations_mod.Destination) void {
        const index = self.findMeterIndex(global_id) orelse {
            destination.level_left = 0.0;
            destination.level_right = 0.0;
            destination.level = 0.0;
            return;
        };
        const meter = self.meters.items[index];
        const left = @as(f32, @floatFromInt(meter.left_peak_milli.load(.monotonic))) / 1000.0;
        const right = @as(f32, @floatFromInt(meter.right_peak_milli.load(.monotonic))) / 1000.0;
        destination.level_left = left;
        destination.level_right = right;
        destination.level = @max(left, right);
    }
};

const core_events = c.struct_pw_core_events{
    .version = c.PW_VERSION_CORE_EVENTS,
    .info = null,
    .done = null,
    .ping = null,
    .@"error" = onCoreError,
    .remove_id = null,
    .bound_id = null,
    .add_mem = null,
    .remove_mem = null,
    .bound_props = null,
};

const registry_events = c.struct_pw_registry_events{
    .version = c.PW_VERSION_REGISTRY_EVENTS,
    .global = onRegistryGlobal,
    .global_remove = onRegistryGlobalRemove,
};

const profiler_events = c.struct_pw_profiler_events{
    .version = c.PW_VERSION_PROFILER_EVENTS,
    .profile = onProfilerProfile,
};

const meter_stream_events = c.struct_pw_stream_events{
    .version = c.PW_VERSION_STREAM_EVENTS,
    .destroy = null,
    .state_changed = onMeterStreamStateChanged,
    .control_info = null,
    .io_changed = null,
    .param_changed = onMeterStreamParamChanged,
    .add_buffer = null,
    .remove_buffer = null,
    .process = onMeterStreamProcess,
    .drained = null,
    .command = null,
    .trigger_done = null,
};

fn onCoreError(data: ?*anyopaque, id: u32, seq: c_int, res: c_int, message: [*c]const u8) callconv(.c) void {
    _ = id;
    _ = seq;
    const self: *PipeWireLiveProfiler = @ptrCast(@alignCast(data orelse return));
    self.noteError(res, message);
}

fn onRegistryGlobal(
    data: ?*anyopaque,
    id: u32,
    permissions: u32,
    type_name: [*c]const u8,
    version: u32,
    props: ?*const c.struct_spa_dict,
) callconv(.c) void {
    _ = permissions;
    const self: *PipeWireLiveProfiler = @ptrCast(@alignCast(data orelse return));
    self.handleRegistryGlobal(id, type_name, version, props);
}

fn onRegistryGlobalRemove(data: ?*anyopaque, id: u32) callconv(.c) void {
    const self: *PipeWireLiveProfiler = @ptrCast(@alignCast(data orelse return));
    self.handleRegistryGlobalRemove(id);
}

fn onProfilerProfile(data: ?*anyopaque, pod: ?*const c.struct_spa_pod) callconv(.c) void {
    const self: *PipeWireLiveProfiler = @ptrCast(@alignCast(data orelse return));
    self.handleProfile(pod orelse return);
}

fn onMeterStreamStateChanged(
    data: ?*anyopaque,
    _: c.enum_pw_stream_state,
    state: c.enum_pw_stream_state,
    error_message: ?[*:0]const u8,
) callconv(.c) void {
    const meter: *PipeWireLiveProfiler.MeterStream = @ptrCast(@alignCast(data orelse return));
    meter.active.store(state == c.PW_STREAM_STATE_STREAMING or state == c.PW_STREAM_STATE_PAUSED, .monotonic);
    if (state == c.PW_STREAM_STATE_ERROR) {
        std.log.warn("meter stream error for {s}: {s}", .{
            meter.target_object,
            if (error_message) |msg| std.mem.span(msg) else "unknown",
        });
    }
}

fn onMeterStreamProcess(data: ?*anyopaque) callconv(.c) void {
    const meter: *PipeWireLiveProfiler.MeterStream = @ptrCast(@alignCast(data orelse return));
    const pw_buffer = c.pw_stream_dequeue_buffer(meter.stream) orelse return;
    defer _ = c.pw_stream_queue_buffer(meter.stream, pw_buffer);

    const spa_buffer = pw_buffer.*.buffer orelse return;
    if (spa_buffer.*.n_datas == 0) return;
    const spa_data = &spa_buffer.*.datas[0];
    if (spa_data.data == null or spa_data.chunk == null) return;

    const channel_count = if (meter.channels == 0) @as(u32, 1) else meter.channels;
    const total_samples = spa_data.chunk.*.size / @sizeOf(f32);
    if (total_samples == 0) return;

    const samples = @as([*]const f32, @ptrCast(@alignCast(spa_data.data)))[0..total_samples];
    var left_peak: f32 = 0.0;
    var right_peak: f32 = 0.0;

    if (channel_count == 1) {
        for (samples) |sample| {
            const amplitude = @abs(sample);
            if (amplitude > left_peak) left_peak = amplitude;
        }
        right_peak = left_peak;
    } else {
        var index: usize = 0;
        while (index < samples.len) : (index += channel_count) {
            const left_sample = @abs(samples[index]);
            const right_sample = @abs(samples[@min(index + 1, samples.len - 1)]);
            if (left_sample > left_peak) left_peak = left_sample;
            if (right_sample > right_peak) right_peak = right_sample;
        }
    }

    meter.left_peak_milli.store(levelToMilli(left_peak), .monotonic);
    meter.right_peak_milli.store(levelToMilli(right_peak), .monotonic);
}

fn onMeterStreamParamChanged(data: ?*anyopaque, id: u32, param: ?*const c.struct_spa_pod) callconv(.c) void {
    const meter: *PipeWireLiveProfiler.MeterStream = @ptrCast(@alignCast(data orelse return));
    if (id != c.SPA_PARAM_Format) return;
    const channels = c.wiredeck_spa_parse_audio_channels(param);
    if (channels > 0) {
        meter.channels = channels;
    }
}

fn nowNs() u64 {
    return @intCast(std.time.nanoTimestamp());
}

fn classifyMediaClass(media_class: []const u8) PipeWireLiveProfiler.EntryKind {
    if (std.mem.startsWith(u8, media_class, "Audio/Sink")) return .sink;
    if (std.mem.startsWith(u8, media_class, "Audio/Source")) return .source;
    if (std.mem.eql(u8, media_class, "Stream/Output/Audio")) return .stream;
    return .none;
}

fn classifyProps(props: *const c.struct_spa_dict, media_class: ?[]const u8) PipeWireLiveProfiler.EntryKind {
    if (isManagedWireDeckNode(props)) return .none;

    if (media_class) |class_name| {
        const kind = classifyMediaClass(class_name);
        if (kind != .none) return kind;
    }

    if (lookupProp(props, "application.process.binary") != null or lookupProp(props, "application.name") != null) {
        return .stream;
    }

    const node_name = lookupProp(props, "node.name") orelse lookupProp(props, "object.path") orelse "";
    const description = lookupProp(props, "node.description") orelse lookupProp(props, "device.description") orelse "";

    if (containsIgnoreCase(node_name, "sink") or containsIgnoreCase(node_name, "output")) return .sink;
    if (containsIgnoreCase(node_name, "source") or containsIgnoreCase(node_name, "input")) return .source;
    if (containsIgnoreCase(description, "microphone") or containsIgnoreCase(description, "mic")) return .source;
    if (containsIgnoreCase(description, "camera") and !containsIgnoreCase(description, "video")) return .source;
    if (containsIgnoreCase(node_name, "camera") and containsIgnoreCase(node_name, "input")) return .source;

    return .none;
}

fn defaultMediaClassForKind(kind: PipeWireLiveProfiler.EntryKind) []const u8 {
    return switch (kind) {
        .source => "Audio/Source",
        .sink => "Audio/Sink",
        .stream => "Stream/Output/Audio",
        .none => "",
    };
}

fn isManagedWireDeckNode(props: *const c.struct_spa_dict) bool {
    if (lookupProp(props, "node.name")) |name| {
        if (std.mem.startsWith(u8, name, "wiredeck_input_")) return true;
        if (std.mem.startsWith(u8, name, "wiredeck_output_")) return true;
        if (std.mem.startsWith(u8, name, "wiredeck_busmic_")) return true;
        if (std.mem.startsWith(u8, name, "wiredeck_fx_")) return true;
        if (std.mem.startsWith(u8, name, "wiredeck_parking_sink")) return true;
        if (std.mem.startsWith(u8, name, "wiredeck_meter_")) return true;
    }
    if (lookupProp(props, "object.path")) |path| {
        if (std.mem.startsWith(u8, path, "wiredeck_input_")) return true;
        if (std.mem.startsWith(u8, path, "wiredeck_output_")) return true;
        if (std.mem.startsWith(u8, path, "wiredeck_busmic_")) return true;
        if (std.mem.startsWith(u8, path, "wiredeck_fx_")) return true;
        if (std.mem.startsWith(u8, path, "wiredeck_parking_sink")) return true;
        if (std.mem.startsWith(u8, path, "wiredeck_meter_")) return true;
    }
    if (lookupProp(props, "node.description")) |description| {
        if (containsIgnoreCase(description, "wiredeck ")) return true;
    }
    if (lookupProp(props, "device.description")) |description| {
        if (containsIgnoreCase(description, "wiredeck ")) return true;
    }
    return false;
}

fn buildSourceFromProps(
    allocator: std.mem.Allocator,
    props: *const c.struct_spa_dict,
    media_class: []const u8,
    global_id: u32,
    client_info: ?PipeWireLiveProfiler.ClientInfo,
) !sources_mod.Source {
    const owned_id = try allocChosenId(allocator, props, global_id);
    errdefer allocator.free(owned_id);

    const source_kind = inferSourceKind(media_class);
    const raw_label = chooseSourceLabel(props, client_info, source_kind, owned_id);
    const raw_subtitle = chooseSourceSubtitle(props, client_info, media_class, source_kind);
    const raw_process_binary = chooseProcessBinary(props, client_info);
    const raw_icon_name = chooseSourceIconName(props, client_info, source_kind, raw_process_binary);

    return .{
        .id = owned_id,
        .label = try allocator.dupe(u8, raw_label),
        .subtitle = try allocator.dupe(u8, raw_subtitle),
        .kind = source_kind,
        .process_binary = try allocator.dupe(u8, raw_process_binary),
        .icon_name = try allocator.dupe(u8, raw_icon_name),
        .icon_path = try allocator.dupe(u8, ""),
        .level_left = chooseSourceLevel(props),
        .level_right = chooseSourceLevel(props),
        .level = chooseSourceLevel(props),
        .muted = chooseSourceMuted(props),
    };
}

fn buildDestinationFromProps(
    allocator: std.mem.Allocator,
    props: *const c.struct_spa_dict,
    global_id: u32,
) !destinations_mod.Destination {
    const media_class = lookupProp(props, "media.class") orelse "Audio/Sink";
    const owned_id = try allocChosenId(allocator, props, global_id);
    errdefer allocator.free(owned_id);
    const raw_label = chooseLabel(props, owned_id);
    const raw_subtitle = chooseSubtitle(props, media_class);

    return .{
        .id = owned_id,
        .label = try allocator.dupe(u8, raw_label),
        .subtitle = try allocator.dupe(u8, raw_subtitle),
        .kind = inferKind(props),
        .level_left = 0.0,
        .level_right = 0.0,
        .level = 0.0,
    };
}

fn cloneSource(allocator: std.mem.Allocator, source: sources_mod.Source) !sources_mod.Source {
    return .{
        .id = try allocator.dupe(u8, source.id),
        .label = try allocator.dupe(u8, source.label),
        .subtitle = try allocator.dupe(u8, source.subtitle),
        .kind = source.kind,
        .process_binary = try allocator.dupe(u8, source.process_binary),
        .icon_name = try allocator.dupe(u8, source.icon_name),
        .icon_path = try allocator.dupe(u8, source.icon_path),
        .level_left = source.level_left,
        .level_right = source.level_right,
        .level = source.level,
        .muted = source.muted,
    };
}

fn cloneDestination(allocator: std.mem.Allocator, destination: destinations_mod.Destination) !destinations_mod.Destination {
    return .{
        .id = try allocator.dupe(u8, destination.id),
        .label = try allocator.dupe(u8, destination.label),
        .subtitle = try allocator.dupe(u8, destination.subtitle),
        .kind = destination.kind,
        .level_left = destination.level_left,
        .level_right = destination.level_right,
        .level = destination.level,
    };
}

fn freeSource(allocator: std.mem.Allocator, source: *sources_mod.Source) void {
    allocator.free(source.id);
    allocator.free(source.label);
    allocator.free(source.subtitle);
    allocator.free(source.process_binary);
    allocator.free(source.icon_name);
    allocator.free(source.icon_path);
}

fn freeDestination(allocator: std.mem.Allocator, destination: *destinations_mod.Destination) void {
    allocator.free(destination.id);
    allocator.free(destination.label);
    allocator.free(destination.subtitle);
}

fn deinitDiscoveredChannels(allocator: std.mem.Allocator, channels: *std.ArrayList(sources_mod.Source)) void {
    for (channels.items) |*channel| freeSource(allocator, channel);
    channels.deinit(allocator);
}

fn deinitDiscoveredDestinations(allocator: std.mem.Allocator, destinations: *std.ArrayList(destinations_mod.Destination)) void {
    for (destinations.items) |*destination| freeDestination(allocator, destination);
    destinations.deinit(allocator);
}

fn dedupeAndSortDestinations(allocator: std.mem.Allocator, destinations: *std.ArrayList(destinations_mod.Destination)) void {
    var index: usize = 0;
    while (index < destinations.items.len) : (index += 1) {
        var compare_index = index + 1;
        while (compare_index < destinations.items.len) {
            if (std.mem.eql(u8, destinations.items[index].id, destinations.items[compare_index].id)) {
                freeDestination(allocator, &destinations.items[compare_index]);
                _ = destinations.orderedRemove(compare_index);
            } else {
                compare_index += 1;
            }
        }
    }

    std.mem.sort(destinations_mod.Destination, destinations.items, {}, struct {
        fn lessThan(_: void, a: destinations_mod.Destination, b: destinations_mod.Destination) bool {
            if (!std.mem.eql(u8, a.subtitle, b.subtitle)) return std.ascii.lessThanIgnoreCase(a.subtitle, b.subtitle);
            return std.ascii.lessThanIgnoreCase(a.label, b.label);
        }
    }.lessThan);
}

fn dedupeAndSortChannels(allocator: std.mem.Allocator, channels: *std.ArrayList(sources_mod.Source)) void {
    var index: usize = 0;
    while (index < channels.items.len) : (index += 1) {
        var compare_index = index + 1;
        while (compare_index < channels.items.len) {
            if (std.mem.eql(u8, channels.items[index].id, channels.items[compare_index].id)) {
                freeSource(allocator, &channels.items[compare_index]);
                _ = channels.orderedRemove(compare_index);
            } else {
                compare_index += 1;
            }
        }
    }

    std.mem.sort(sources_mod.Source, channels.items, {}, struct {
        fn lessThan(_: void, a: sources_mod.Source, b: sources_mod.Source) bool {
            if (!std.mem.eql(u8, a.subtitle, b.subtitle)) return std.ascii.lessThanIgnoreCase(a.subtitle, b.subtitle);
            return std.ascii.lessThanIgnoreCase(a.label, b.label);
        }
    }.lessThan);
}

fn lookupProp(props: *const c.struct_spa_dict, key: [:0]const u8) ?[]const u8 {
    const value = c.spa_dict_lookup(props, key.ptr) orelse return null;
    return std.mem.span(value);
}

fn allocChosenId(allocator: std.mem.Allocator, props: *const c.struct_spa_dict, fallback_global_id: u32) ![]u8 {
    if (lookupProp(props, "node.name")) |name| return allocator.dupe(u8, name);
    if (lookupProp(props, "object.path")) |path| return allocator.dupe(u8, path);
    return std.fmt.allocPrint(allocator, "pw-node-{d}", .{fallback_global_id});
}

fn allocMeterTarget(allocator: std.mem.Allocator, props: *const c.struct_spa_dict, fallback_global_id: u32) ![]u8 {
    if (lookupProp(props, "object.serial")) |serial| return allocator.dupe(u8, serial);
    return allocChosenId(allocator, props, fallback_global_id);
}

fn chooseLabel(props: *const c.struct_spa_dict, fallback: []const u8) []const u8 {
    if (lookupProp(props, "node.description")) |label| return label;
    if (lookupProp(props, "node.nick")) |label| return label;
    if (lookupProp(props, "device.description")) |label| return label;
    return fallback;
}

fn chooseSubtitle(props: *const c.struct_spa_dict, media_class: []const u8) []const u8 {
    if (lookupProp(props, "device.description")) |label| return label;
    if (lookupProp(props, "device.api")) |api| return api;
    if (lookupProp(props, "node.name")) |name| return name;
    return media_class;
}

fn chooseSourceSubtitle(
    props: *const c.struct_spa_dict,
    client_info: ?PipeWireLiveProfiler.ClientInfo,
    media_class: []const u8,
    source_kind: sources_mod.SourceKind,
) []const u8 {
    if (source_kind == .app) {
        if (lookupProp(props, "application.name")) |name| return normalizeProcessSubtitle(name, props);
        if (lookupProp(props, "node.description")) |name| return normalizeProcessSubtitle(name, props);
        if (chooseApplicationNameFromClient(client_info)) |name| return normalizeProcessSubtitle(name, props);
        if (lookupProp(props, "application.process.binary")) |name| return normalizeProcessSubtitle(name, props);
        if (chooseProcessBinaryFromClient(client_info)) |name| return normalizeProcessSubtitle(name, props);
    }
    if (lookupProp(props, "device.description")) |name| return name;
    if (lookupProp(props, "device.api")) |api| return api;
    if (lookupProp(props, "node.name")) |name| return name;
    return media_class;
}

fn chooseSourceLabel(
    props: *const c.struct_spa_dict,
    client_info: ?PipeWireLiveProfiler.ClientInfo,
    source_kind: sources_mod.SourceKind,
    fallback: []const u8,
) []const u8 {
    if (source_kind == .app) {
        if (chooseProcessBinaryFromClient(client_info)) |binary| return normalizeProcessLabel(binary, client_info);
        if (lookupProp(props, "application.process.binary")) |binary| return normalizeProcessLabel(binary, props);
        if (chooseApplicationNameFromClient(client_info)) |name| return normalizeProcessLabel(name, client_info);
        if (lookupProp(props, "application.name")) |name| return normalizeProcessLabel(name, props);
    }
    if (lookupProp(props, "node.description")) |label| return label;
    if (lookupProp(props, "device.description")) |label| return label;
    return fallback;
}

fn normalizeProcessLabel(candidate: []const u8, props: anytype) []const u8 {
    if (asciiEqlIgnoreCase(candidate, "discord") or containsIgnoreCase(candidate, "discord")) return "Discord";
    if (asciiEqlIgnoreCase(candidate, "firefox")) return "Firefox";
    if (asciiEqlIgnoreCase(candidate, "steam")) return "Steam";
    if (asciiEqlIgnoreCase(candidate, "obs")) return "OBS";
    if (asciiEqlIgnoreCase(candidate, "obs-studio")) return "OBS Studio";
    if (asciiEqlIgnoreCase(candidate, "chromium")) return "Chromium";
    if (asciiEqlIgnoreCase(candidate, "google-chrome")) return "Google Chrome";

    if (getProcessBinaryFromPropsLike(props)) |binary| {
        if (asciiEqlIgnoreCase(binary, "discord") and containsIgnoreCase(candidate, "webrtc")) return "Discord";
    }
    return candidate;
}

fn normalizeProcessSubtitle(candidate: []const u8, props: *const c.struct_spa_dict) []const u8 {
    if (containsIgnoreCase(candidate, "webrtc")) return "webrtc";
    if (asciiEqlIgnoreCase(candidate, "discord") or containsIgnoreCase(candidate, "discord")) return "discord";
    if (asciiEqlIgnoreCase(candidate, "firefox")) return "firefox";
    if (asciiEqlIgnoreCase(candidate, "steam")) return "steam";
    if (asciiEqlIgnoreCase(candidate, "obs") or asciiEqlIgnoreCase(candidate, "obs-studio")) return "obs";
    if (asciiEqlIgnoreCase(candidate, "chromium")) return "chromium";
    if (asciiEqlIgnoreCase(candidate, "google-chrome")) return "google-chrome";

    if (lookupProp(props, "application.process.binary")) |binary| {
        if (asciiEqlIgnoreCase(binary, "discord") and containsIgnoreCase(candidate, "webrtc")) return "webrtc";
        if (asciiEqlIgnoreCase(binary, "discord")) return "discord";
    }
    return candidate;
}

fn normalizeProcessSubtitleWithBinary(candidate: []const u8, process_binary: []const u8) []const u8 {
    if (containsIgnoreCase(candidate, "webrtc")) return "webrtc";
    if (asciiEqlIgnoreCase(candidate, "discord") or containsIgnoreCase(candidate, "discord")) return "discord";
    if (asciiEqlIgnoreCase(candidate, "firefox")) return "firefox";
    if (asciiEqlIgnoreCase(candidate, "steam")) return "steam";
    if (asciiEqlIgnoreCase(candidate, "obs") or asciiEqlIgnoreCase(candidate, "obs-studio")) return "obs";
    if (asciiEqlIgnoreCase(candidate, "chromium")) return "chromium";
    if (asciiEqlIgnoreCase(candidate, "google-chrome")) return "google-chrome";

    if (asciiEqlIgnoreCase(process_binary, "discord") and containsIgnoreCase(candidate, "webrtc")) return "webrtc";
    if (asciiEqlIgnoreCase(process_binary, "discord")) return "discord";
    return candidate;
}

fn chooseProcessBinary(props: *const c.struct_spa_dict, client_info: ?PipeWireLiveProfiler.ClientInfo) []const u8 {
    if (chooseProcessBinaryFromClient(client_info)) |binary| return binary;
    return lookupProp(props, "application.process.binary") orelse "";
}

fn chooseRefreshedSourceSubtitle(source: *const sources_mod.Source, client_info: ?PipeWireLiveProfiler.ClientInfo) []const u8 {
    if (chooseApplicationNameFromClient(client_info)) |name| {
        return normalizeProcessSubtitleWithBinary(name, chooseProcessBinaryFromClient(client_info) orelse source.process_binary);
    }
    if (chooseProcessBinaryFromClient(client_info)) |binary| return normalizeProcessSubtitleWithBinary(binary, binary);
    return source.subtitle;
}

fn chooseSourceIconName(
    props: *const c.struct_spa_dict,
    client_info: ?PipeWireLiveProfiler.ClientInfo,
    source_kind: sources_mod.SourceKind,
    process_binary: []const u8,
) []const u8 {
    if (lookupProp(props, "application.icon-name")) |icon| return icon;
    if (lookupProp(props, "application.icon_name")) |icon| return icon;
    if (chooseProcessBinaryFromClient(client_info)) |binary| return chooseSourceIconNameFromBinary(binary);
    if (lookupProp(props, "application.process.binary")) |binary| return chooseSourceIconNameFromBinary(binary);
    if (source_kind == .physical) return "audio-input-microphone";
    if (process_binary.len > 0) return process_binary;
    return "application-x-executable";
}

fn chooseSourceIconNameFromBinary(binary: []const u8) []const u8 {
    if (asciiEqlIgnoreCase(binary, "discord")) return "discord";
    if (asciiEqlIgnoreCase(binary, "firefox") or asciiEqlIgnoreCase(binary, "firefox-bin")) return "firefox";
    if (asciiEqlIgnoreCase(binary, "steam")) return "steam";
    if (asciiEqlIgnoreCase(binary, "obs") or asciiEqlIgnoreCase(binary, "obs-studio")) return "com.obsproject.Studio";
    if (asciiEqlIgnoreCase(binary, "google-chrome")) return "google-chrome";
    if (asciiEqlIgnoreCase(binary, "chromium")) return "chromium";
    return binary;
}

fn chooseProcessBinaryFromClient(client_info: ?PipeWireLiveProfiler.ClientInfo) ?[]const u8 {
    const info = client_info orelse return null;
    if (info.process_binary.len > 0) return info.process_binary;
    if (info.portal_app_id.len > 0) {
        if (std.mem.lastIndexOfScalar(u8, info.portal_app_id, '.')) |index| {
            return info.portal_app_id[index + 1 ..];
        }
        return info.portal_app_id;
    }
    return null;
}

fn chooseApplicationNameFromClient(client_info: ?PipeWireLiveProfiler.ClientInfo) ?[]const u8 {
    const info = client_info orelse return null;
    return if (info.application_name.len > 0) info.application_name else null;
}

fn getProcessBinaryFromPropsLike(props: anytype) ?[]const u8 {
    const T = @TypeOf(props);
    if (T == *const c.struct_spa_dict) return lookupProp(props, "application.process.binary");
    if (T == PipeWireLiveProfiler.ClientInfo) return if (props.process_binary.len > 0) props.process_binary else null;
    if (T == ?PipeWireLiveProfiler.ClientInfo) return chooseProcessBinaryFromClient(props);
    return null;
}

fn lookupClientId(props: *const c.struct_spa_dict) ?u32 {
    const raw = lookupProp(props, "client.id") orelse return null;
    return std.fmt.parseInt(u32, raw, 10) catch null;
}

fn updateOwnedString(allocator: std.mem.Allocator, field: *[]const u8, value: []const u8) !void {
    if (std.mem.eql(u8, field.*, value)) return;
    const replacement = try allocator.dupe(u8, value);
    allocator.free(field.*);
    field.* = replacement;
}

fn chooseSourceLevel(props: *const c.struct_spa_dict) f32 {
    if (lookupProp(props, "volume")) |text| return std.fmt.parseFloat(f32, text) catch 0.0;
    return 0.0;
}

fn chooseSourceMuted(props: *const c.struct_spa_dict) bool {
    if (lookupProp(props, "mute")) |value| return parseBool(value);
    if (lookupProp(props, "softMute")) |value| return parseBool(value);
    return false;
}

fn inferSourceKind(media_class: []const u8) sources_mod.SourceKind {
    if (std.mem.startsWith(u8, media_class, "Stream/") and std.mem.endsWith(u8, media_class, "/Audio")) return .app;
    return .physical;
}

const ProfilerBlockMetric = struct {
    node_id: u32,
    activity: f32,
};

fn parseProfilerBlock(pod: *const c.struct_spa_pod) ?ProfilerBlockMetric {
    if (pod.type != c.SPA_TYPE_Struct) return null;

    const struct_start = @intFromPtr(pod) + @sizeOf(c.struct_spa_pod_struct);
    const struct_end = @intFromPtr(pod) + @sizeOf(c.struct_spa_pod) + pod.size;

    var cursor = struct_start;
    const node_id_pod = nextStructPod(&cursor, struct_end) orelse return null;
    _ = nextStructPod(&cursor, struct_end) orelse return null;
    const prev_signal_pod = nextStructPod(&cursor, struct_end) orelse return null;
    const signal_pod = nextStructPod(&cursor, struct_end) orelse return null;
    const awake_pod = nextStructPod(&cursor, struct_end) orelse return null;
    const finish_pod = nextStructPod(&cursor, struct_end) orelse return null;

    const raw_node_id = readPodInt(node_id_pod) orelse return null;
    const prev_signal = readPodLong(prev_signal_pod) orelse return null;
    const signal = readPodLong(signal_pod) orelse return null;
    const awake = readPodLong(awake_pod) orelse return null;
    const finish = readPodLong(finish_pod) orelse return null;

    if (raw_node_id < 0) return null;

    return .{
        .node_id = @intCast(raw_node_id),
        .activity = computeProfilerActivity(prev_signal, signal, awake, finish),
    };
}

fn podPropFirst(body: *const c.struct_spa_pod_object_body) *const c.struct_spa_pod_prop {
    return @ptrFromInt(@intFromPtr(body) + @sizeOf(c.struct_spa_pod_object_body));
}

fn podPropNext(prop: *const c.struct_spa_pod_prop) *const c.struct_spa_pod_prop {
    const size = @sizeOf(c.struct_spa_pod_prop) + prop.*.value.size;
    const padded_size = std.mem.alignForward(usize, size, 8);
    return @ptrFromInt(@intFromPtr(prop) + padded_size);
}

fn podPropIsInside(
    body: *const c.struct_spa_pod_object_body,
    body_size: u32,
    prop: *const c.struct_spa_pod_prop,
) bool {
    const start = @intFromPtr(body);
    const end = start + body_size;
    const prop_start = @intFromPtr(prop);
    if (prop_start < start + @sizeOf(c.struct_spa_pod_object_body)) return false;
    if (prop_start + @sizeOf(c.struct_spa_pod_prop) > end) return false;
    const prop_total_size = @sizeOf(c.struct_spa_pod_prop) + prop.*.value.size;
    return prop_start + prop_total_size <= end;
}

fn levelToMilli(value: f32) u32 {
    const clamped = std.math.clamp(value, 0.0, 1.0);
    return @intFromFloat(clamped * 1000.0);
}

fn nextStructPod(cursor: *usize, end: usize) ?*const c.struct_spa_pod {
    if (cursor.* + @sizeOf(c.struct_spa_pod) > end) return null;
    const pod: *const c.struct_spa_pod = @ptrFromInt(cursor.*);
    const padded_size = std.mem.alignForward(usize, @sizeOf(c.struct_spa_pod) + pod.size, 8);
    if (cursor.* + padded_size > end) return null;
    cursor.* += padded_size;
    return pod;
}

fn readPodInt(pod: *const c.struct_spa_pod) ?i32 {
    if (pod.type != c.SPA_TYPE_Int) return null;
    const value: *const c.struct_spa_pod_int = @ptrCast(@alignCast(pod));
    return value.value;
}

fn readPodLong(pod: *const c.struct_spa_pod) ?i64 {
    if (pod.type != c.SPA_TYPE_Long) return null;
    const value: *const c.struct_spa_pod_long = @ptrCast(@alignCast(pod));
    return value.value;
}

fn computeProfilerActivity(prev_signal: i64, signal: i64, awake: i64, finish: i64) f32 {
    const signal_start = @max(prev_signal, signal);
    const wake_or_signal = @max(signal_start, awake);
    const active_ns = if (finish > wake_or_signal) finish - wake_or_signal else 0;
    const cycle_ns = if (finish > prev_signal) finish - prev_signal else 0;

    const active_component = @as(f32, @floatFromInt(active_ns)) / 350_000.0;
    const cycle_component = @as(f32, @floatFromInt(cycle_ns)) / 2_000_000.0;
    return std.math.clamp(@max(active_component, cycle_component * 0.35), 0.0, 1.0);
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn inferKind(props: *const c.struct_spa_dict) destinations_mod.DestinationKind {
    if (lookupProp(props, "node.virtual")) |value| {
        if (parseBool(value)) return .virtual;
    }
    if (lookupProp(props, "node.name")) |name| {
        if (std.mem.indexOf(u8, name, "monitor") != null or std.mem.indexOf(u8, name, "null") != null) return .virtual;
    }
    if (lookupProp(props, "device.api") != null or lookupProp(props, "api.alsa.path") != null or lookupProp(props, "api.bluez5.path") != null) {
        return .device;
    }
    return .physical;
}

fn parseBool(text: []const u8) bool {
    return std.ascii.eqlIgnoreCase(text, "true") or std.ascii.eqlIgnoreCase(text, "yes") or std.mem.eql(u8, text, "1");
}

test "profiler ring buffer keeps newest samples" {
    var buffer = ProfilerRingBuffer{};
    var index: usize = 0;
    while (index < ProfilerRingBuffer.capacity + 3) : (index += 1) {
        buffer.push(.{
            .received_at_ns = index,
            .profiler_global_id = 7,
            .pod_size = @intCast(index),
            .pod_type = 42,
        });
    }

    try std.testing.expectEqual(@as(usize, ProfilerRingBuffer.capacity), buffer.len);
    try std.testing.expectEqual(@as(u64, 3), buffer.at(0).received_at_ns);
    try std.testing.expectEqual(@as(u64, ProfilerRingBuffer.capacity + 2), buffer.at(buffer.len - 1).received_at_ns);
}

test "live profiler snapshot discovery clones and sorts registry data" {
    var profiler = PipeWireLiveProfiler.init(std.testing.allocator);
    defer profiler.deinit();

    const sources = [_]sources_mod.Source{
        .{ .id = "discord", .label = "Discord", .subtitle = "discord", .kind = .app },
        .{ .id = "alsa_input.usb", .label = "USB Mic", .subtitle = "USB Audio", .kind = .physical },
    };
    const destinations = [_]destinations_mod.Destination{
        .{ .id = "sink-b", .label = "Zulu Sink", .subtitle = "alsa", .kind = .device },
        .{ .id = "sink-a", .label = "Alpha Sink", .subtitle = "alsa", .kind = .device },
    };

    try profiler.injectDiscoveryForTest(&sources, &destinations, .{ .sources = 1, .sinks = 2, .streams = 1 });

    var discovery = try profiler.snapshotDiscovery(std.testing.allocator);
    defer discovery.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), discovery.channels.items.len);
    try std.testing.expectEqualStrings("Discord", discovery.channels.items[0].label);
    try std.testing.expectEqualStrings("Alpha Sink", discovery.destinations.items[0].label);
    try std.testing.expectEqual(@as(usize, 1), discovery.registry_snapshot.sources);
    try std.testing.expectEqual(@as(usize, 1), discovery.registry_snapshot.streams);
}

test "build source from stream input prefers client process name and webrtc subtitle" {
    const items = [_]c.struct_spa_dict_item{
        .{ .key = "media.class", .value = "Stream/Input/Audio" },
        .{ .key = "node.name", .value = "WEBRTC VoiceEngine" },
        .{ .key = "application.name", .value = "WEBRTC VoiceEngine" },
    };
    const props = c.struct_spa_dict{
        .flags = 0,
        .n_items = items.len,
        .items = &items,
    };
    const client = PipeWireLiveProfiler.ClientInfo{
        .id = 115,
        .process_binary = try std.testing.allocator.dupe(u8, "Discord"),
        .application_name = try std.testing.allocator.dupe(u8, "WEBRTC VoiceEngine"),
        .portal_app_id = try std.testing.allocator.dupe(u8, "com.discordapp.Discord"),
    };
    defer {
        std.testing.allocator.free(client.process_binary);
        std.testing.allocator.free(client.application_name);
        std.testing.allocator.free(client.portal_app_id);
    }

    var source = try buildSourceFromProps(std.testing.allocator, &props, "Stream/Input/Audio", 129, client);
    defer freeSource(std.testing.allocator, &source);

    try std.testing.expectEqual(sources_mod.SourceKind.app, source.kind);
    try std.testing.expectEqualStrings("Discord", source.label);
    try std.testing.expectEqualStrings("webrtc", source.subtitle);
    try std.testing.expectEqualStrings("Discord", source.process_binary);
}

test "note error marks profiler disconnected and clears discovery" {
    var profiler = PipeWireLiveProfiler.init(std.testing.allocator);
    defer profiler.deinit();

    try profiler.entries.append(std.testing.allocator, .{
        .global_id = 1,
        .kind = .source,
        .source = try cloneSource(std.testing.allocator, .{ .id = "discord", .label = "Discord", .subtitle = "discord", .kind = .app }),
    });
    profiler.connected = true;
    profiler.profiler_global_id = 42;
    profiler.discovery_generation = 7;

    profiler.noteError(-32, "disconnected");

    try std.testing.expect(!profiler.connected);
    try std.testing.expectEqual(@as(?u32, null), profiler.profiler_global_id);
    try std.testing.expectEqual(@as(usize, 0), profiler.entries.items.len);
    try std.testing.expectEqual(@as(u64, 8), profiler.discovery_generation);
}
