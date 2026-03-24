const std = @import("std");
const StateStore = @import("state_store.zig").StateStore;
const AudioCore = @import("../core/audio/routing.zig").AudioCore;
const channels_mod = @import("../core/audio/channels.zig");
const sources_mod = @import("../core/audio/sources.zig");
const destinations_mod = @import("../core/audio/destinations.zig");
const pw = @import("../core/pipewire.zig");
const pulse = @import("../core/pulse.zig");
const binder = @import("../core/binder.zig");
const icon = @import("../core/icon_resolver.zig");
const output_exposure_mod = @import("../core/output_exposure.zig");
const OutputExposureManager = output_exposure_mod.OutputExposureManager;
const ChannelFxFilterManager = @import("../core/pipewire/channel_fx_filters.zig").ChannelFxFilterManager;
const virtual_inputs = @import("../core/pipewire/virtual_inputs.zig");
const VirtualInputManager = virtual_inputs.VirtualInputManager;
const plugin_host = @import("../plugins/host.zig");
const Lv2Support = @import("../plugins/lv2.zig").Lv2Support;
const FxRuntime = @import("../plugins/fx_runtime.zig").FxRuntime;

pub const App = struct {
    const inventory_refresh_interval_ns = 1500 * std.time.ns_per_ms;
    const routing_poll_interval_ns = 20 * std.time.ns_per_ms;
    const pulse_startup_retry_attempts = 6;
    const pulse_startup_retry_delay_ns = 150 * std.time.ns_per_ms;
    const worker_allocator = std.heap.c_allocator;

    const InventoryRefresh = struct {
        sources: []sources_mod.Source,
        destinations: []destinations_mod.Destination,
        meter_specs: []pulse.MeterSpec,

        fn deinit(self: *InventoryRefresh, allocator: std.mem.Allocator) void {
            for (self.sources) |source| {
                allocator.free(source.id);
                allocator.free(source.label);
                allocator.free(source.subtitle);
                allocator.free(source.process_binary);
                allocator.free(source.icon_name);
                allocator.free(source.icon_path);
            }
            allocator.free(self.sources);

            for (self.destinations) |destination| {
                allocator.free(destination.id);
                allocator.free(destination.label);
                allocator.free(destination.subtitle);
                allocator.free(destination.pulse_sink_name);
            }
            allocator.free(self.destinations);

            for (self.meter_specs) |spec| {
                allocator.free(spec.source_id);
                if (spec.channel_id) |channel_id| allocator.free(channel_id);
                allocator.free(spec.pulse_source_name);
            }
            allocator.free(self.meter_specs);
        }
    };

    const RoutingSnapshot = struct {
        state_store: StateStore,

        fn deinit(self: *RoutingSnapshot) void {
            self.state_store.deinit();
        }
    };

    const RoutedSinkInput = struct {
        channel_id: []u8,
        sink_input_index: u32,
        original_sink_index: u32,
    };

    const RoutedSourceOutput = struct {
        source_output_index: u32,
        original_source_index: u32,
    };

    const RoutedCombineModule = struct {
        channel_id: []u8,
        module_index: u32,
        sink_name: []u8,
        sink_key: []u8,
    };

    const RoutedLoopbackModule = struct {
        channel_id: []u8,
        module_index: u32,
        source_name: []u8,
        sink_name: []u8,
    };

    const RoutedFxOutputLoopbackModule = struct {
        channel_id: []u8,
        module_index: u32,
        source_name: []u8,
        sink_name: []u8,
    };

    const ChannelTargetSink = struct {
        sink_index: u32,
        sink_name: []const u8,
    };

    allocator: std.mem.Allocator,
    state_store: *StateStore,
    pipewire_live: pw.PipeWireLiveProfiler,
    pulse_peak: pulse.PeakMonitor,
    last_live_generation: u64,
    last_inventory_refresh_ns: i128,
    refresh_thread: ?std.Thread,
    refresh_mutex: std.Thread.Mutex,
    pending_refresh: ?*InventoryRefresh,
    refresh_stop: std.atomic.Value(bool),
    refresh_running: std.atomic.Value(bool),
    routing_thread: ?std.Thread,
    routing_mutex: std.Thread.Mutex,
    pending_routing: ?*RoutingSnapshot,
    routing_stop: std.atomic.Value(bool),
    routing_retry_requested: std.atomic.Value(bool),
    route_dirty: bool,
    routed_sink_inputs: std.ArrayList(RoutedSinkInput),
    routed_source_outputs: std.ArrayList(RoutedSourceOutput),
    blocked_source_outputs: std.ArrayList(u32),
    routed_combine_modules: std.ArrayList(RoutedCombineModule),
    routed_loopback_modules: std.ArrayList(RoutedLoopbackModule),
    routed_fx_output_loopbacks: std.ArrayList(RoutedFxOutputLoopbackModule),
    output_exposure: OutputExposureManager,
    fx_virtual_inputs: VirtualInputManager,
    fx_processed_inputs: VirtualInputManager,
    fx_filters: ChannelFxFilterManager,
    lv2_support: Lv2Support,
    fx_runtime: FxRuntime,

    pub fn init(allocator: std.mem.Allocator, state_store: *StateStore) App {
        return .{
            .allocator = allocator,
            .state_store = state_store,
            .pipewire_live = pw.PipeWireLiveProfiler.init(allocator),
            .pulse_peak = pulse.PeakMonitor.init(allocator),
            .last_live_generation = 0,
            .last_inventory_refresh_ns = 0,
            .refresh_thread = null,
            .refresh_mutex = .{},
            .pending_refresh = null,
            .refresh_stop = std.atomic.Value(bool).init(false),
            .refresh_running = std.atomic.Value(bool).init(false),
            .routing_thread = null,
            .routing_mutex = .{},
            .pending_routing = null,
            .routing_stop = std.atomic.Value(bool).init(false),
            .routing_retry_requested = std.atomic.Value(bool).init(false),
            .route_dirty = false,
            .routed_sink_inputs = .empty,
            .routed_source_outputs = .empty,
            .blocked_source_outputs = .empty,
            .routed_combine_modules = .empty,
            .routed_loopback_modules = .empty,
            .routed_fx_output_loopbacks = .empty,
            .output_exposure = OutputExposureManager.init(allocator),
            .fx_virtual_inputs = VirtualInputManager.init(allocator),
            .fx_processed_inputs = VirtualInputManager.initFxStage(allocator),
            .fx_filters = ChannelFxFilterManager.init(allocator),
            .lv2_support = Lv2Support.init(allocator),
            .fx_runtime = FxRuntime.init(allocator),
        };
    }

    pub fn deinit(self: *App) void {
        self.stopRoutingWorker();
        self.clearPendingRouting();
        self.stopRefreshWorker();
        self.clearPendingRefresh();
        self.restoreOutputRouting() catch {};
        for (self.routed_sink_inputs.items) |item| {
            self.allocator.free(item.channel_id);
        }
        self.routed_sink_inputs.deinit(self.allocator);
        self.routed_source_outputs.deinit(self.allocator);
        self.blocked_source_outputs.deinit(self.allocator);
        for (self.routed_combine_modules.items) |module| {
            self.allocator.free(module.channel_id);
            self.allocator.free(module.sink_name);
            self.allocator.free(module.sink_key);
        }
        self.routed_combine_modules.deinit(self.allocator);
        for (self.routed_loopback_modules.items) |module| {
            self.allocator.free(module.channel_id);
            self.allocator.free(module.source_name);
            self.allocator.free(module.sink_name);
        }
        self.routed_loopback_modules.deinit(self.allocator);
        for (self.routed_fx_output_loopbacks.items) |module| {
            self.allocator.free(module.channel_id);
            self.allocator.free(module.source_name);
            self.allocator.free(module.sink_name);
        }
        self.routed_fx_output_loopbacks.deinit(self.allocator);
        self.fx_filters.deinit();
        self.fx_processed_inputs.deinit();
        self.fx_virtual_inputs.deinit();
        self.output_exposure.deinit();
        self.fx_runtime.deinit();
        self.pulse_peak.deinit();
        self.pipewire_live.deinit();
    }

    pub fn prepareBootstrapState(self: *App) !void {
        try self.seedDefaultRouting();
        try self.seedPluginCatalog();
        self.pipewire_live.connect() catch |err| {
            std.log.warn("pipewire live profiler unavailable: {s}", .{@errorName(err)});
        };
        connectPeakMonitorWithRetry(&self.pulse_peak) catch |err| {
            std.log.warn("pulse peak monitor unavailable: {s}", .{@errorName(err)});
        };
        self.refreshAudioInventory() catch |err| {
            std.log.warn("audio inventory refresh failed during bootstrap: {s}", .{@errorName(err)});
        };
        self.last_inventory_refresh_ns = std.time.nanoTimestamp();
    }

    pub fn startBackgroundServices(self: *App) void {
        self.startRefreshWorker() catch |err| {
            std.log.warn("audio inventory worker unavailable: {s}", .{@errorName(err)});
        };
        self.output_exposure.start() catch |err| {
            std.log.warn("output exposure server unavailable: {s}", .{@errorName(err)});
        };
        self.startRoutingWorker() catch |err| {
            std.log.warn("routing worker unavailable: {s}", .{@errorName(err)});
        };
    }

    pub fn bootstrap(self: *App) !void {
        try self.prepareBootstrapState();
        self.startBackgroundServices();
    }

    pub fn reconcileCurrentRoutingNow(self: *App) !void {
        try self.reconcileOutputRouting(self.state_store);
    }

    pub fn cleanupStartupBindings(self: *App) !void {
        const pulsectx = try initPulseContextWithRetry(self.allocator);
        defer pulsectx.deinit();

        const modules = try pulsectx.listModules(self.allocator);
        defer pulse.freeModules(self.allocator, modules);

        var unloaded_any = false;
        for (modules) |module| {
            const name = module.name orelse continue;
            const argument = module.argument orelse "";
            if (isWiredeckManagedModule(name, argument)) {
                std.log.info("startup cleanup unloading module {d}: {s} {s}", .{
                    module.index,
                    name,
                    argument,
                });
                pulsectx.unloadModule(module.index) catch {};
                unloaded_any = true;
            }
        }
        if (!unloaded_any) {
            std.log.info("startup cleanup found no stale WireDeck modules", .{});
        }
    }

    pub fn normalizeConfiguredBindingsToDefault(self: *App) !void {
        const pulsectx = try initPulseContextWithRetry(self.allocator);
        defer pulsectx.deinit();

        const default_sink_name = try pulsectx.defaultSinkName(self.allocator) orelse return;
        defer self.allocator.free(default_sink_name);
        std.log.info("startup normalization default sink: {s}", .{default_sink_name});

        const pulse_snapshot = try pulsectx.snapshot(self.allocator);
        defer pulse.freeSnapshot(self.allocator, pulse_snapshot);
        const default_sink_index = findPulseSinkIndexByName(pulse_snapshot, default_sink_name) orelse return;

        const pipewire = try pw.PipewireContext.init(self.allocator);
        defer pipewire.deinit();
        try pipewire.scan();

        const owners = try binder.bind(self.allocator, &pipewire.registry_state, pulse_snapshot);
        defer binder.freeBoundOwners(self.allocator, owners);

        var moved_any = false;
        for (self.state_store.channels.items) |channel| {
            const bound_source_id = channel.bound_source_id orelse continue;
            const source = findStateSource(self.state_store.sources.items, bound_source_id) orelse continue;
            if (source.kind != .app) continue;

            for (owners) |owner| {
                if (!try ownerMatchesGroupedSourceId(self.allocator, owner, bound_source_id)) continue;
                for (owner.pulse_sink_input_indexes) |sink_input_index| {
                    const sink_input = findPulseSinkInput(pulse_snapshot.sink_inputs, sink_input_index) orelse continue;
                    const current_sink_index = sink_input.sink_index orelse continue;
                    if (current_sink_index == default_sink_index) continue;
                    std.log.info("startup normalization moving app stream {d} for channel {s} back to default sink {s}", .{
                        sink_input_index,
                        channel.id,
                        default_sink_name,
                    });
                    pulsectx.moveSinkInputToSink(sink_input_index, default_sink_index) catch {};
                    moved_any = true;
                }
            }
        }
        if (!moved_any) {
            std.log.info("startup normalization found no app streams to reset", .{});
        }
    }

    pub fn pumpLiveAudio(self: *App) !void {
        self.fx_runtime.sync(
            self.state_store.plugin_descriptors.items,
            self.state_store.channel_plugins.items,
            self.state_store.channel_plugin_params.items,
        ) catch |err| {
            std.log.warn("fx runtime sync failed: {s}", .{@errorName(err)});
        };

        if (self.pipewire_live.canPump()) {
            var pump_count: usize = 0;
            while (pump_count < 3) : (pump_count += 1) {
                self.pipewire_live.pump(if (pump_count == 2) 8 else 0) catch break;
            }
            self.last_live_generation = self.pipewire_live.discovery_generation;
        }
        self.pulse_peak.pump(8) catch {};

        var discovery = try self.pipewire_live.snapshotDiscovery(self.allocator);
        defer discovery.deinit(self.allocator);

        for (self.state_store.sources.items) |*source| {
            source.level_left = 0.0;
            source.level_right = 0.0;
            source.level = 0.0;
        }
        for (self.state_store.channels.items) |*channel| {
            channel.level_left = 0.0;
            channel.level_right = 0.0;
            channel.level = 0.0;
        }
        for (self.state_store.destinations.items) |*destination| {
            destination.level_left = 0.0;
            destination.level_right = 0.0;
            destination.level = 0.0;
        }

        for (discovery.channels.items) |discovered_source| {
            if (try findMappedStateSourceIndex(self.allocator, self.state_store.sources.items, discovered_source)) |index| {
                self.state_store.sources.items[index].level_left = discovered_source.level_left;
                self.state_store.sources.items[index].level_right = discovered_source.level_right;
                self.state_store.sources.items[index].level = discovered_source.level;
                self.state_store.sources.items[index].muted = discovered_source.muted;
            }
        }
        self.pulse_peak.applyToSources(self.state_store.sources.items);
        for (discovery.destinations.items) |discovered_destination| {
            if (findMappedStateDestinationIndex(self.state_store.destinations.items, discovered_destination)) |index| {
                self.state_store.destinations.items[index].level_left = discovered_destination.level_left;
                self.state_store.destinations.items[index].level_right = discovered_destination.level_right;
                self.state_store.destinations.items[index].level = discovered_destination.level;
            }
        }

        for (self.state_store.channels.items) |*channel| {
            const bound_source_id = channel.bound_source_id orelse continue;
            const source = findStateSource(self.state_store.sources.items, bound_source_id) orelse continue;
            channel.level_left = source.level_left;
            channel.level_right = source.level_right;
            channel.level = source.level;
        }
        self.pulse_peak.applyToChannels(self.state_store.channels.items);
    }

    pub fn refreshAudioInventory(self: *App) !void {
        const refresh = try self.buildInventoryRefresh(worker_allocator);
        defer {
            var owned = refresh;
            owned.deinit(worker_allocator);
        }
        try self.applyInventoryRefresh(refresh);
        self.last_inventory_refresh_ns = std.time.nanoTimestamp();
    }

    pub fn maybeRefreshAudioInventory(self: *App) void {
        self.applyPendingRefresh() catch |err| {
            std.log.warn("audio inventory apply failed: {s}", .{@errorName(err)});
        };
    }

    pub fn markRoutingDirty(self: *App) void {
        self.route_dirty = true;
    }

    pub fn reconcileOutputRoutingIfNeeded(self: *App) void {
        if (self.routing_retry_requested.swap(false, .acq_rel)) {
            self.route_dirty = true;
        }
        if (!self.route_dirty) return;
        const snapshot = self.buildRoutingSnapshot(worker_allocator) catch |err| {
            std.log.warn("routing snapshot build failed: {s}", .{@errorName(err)});
            return;
        };
        self.enqueueRoutingSnapshot(snapshot);
        self.route_dirty = false;
    }

    fn seedDefaultRouting(self: *App) !void {
        if (self.state_store.buses.items.len == 0) {
            for (AudioCore.defaultBuses()) |bus| {
                try self.state_store.addBus(bus);
            }
        }
    }

    fn seedPluginCatalog(self: *App) !void {
        self.state_store.clearPluginDescriptors();
        for (plugin_host.PluginHost.descriptors()) |descriptor| {
            try self.state_store.addPluginDescriptor(descriptor);
        }

        const lv2_descriptors = self.lv2_support.discoverDescriptors() catch |err| {
            std.log.warn("lv2 descriptor discovery failed: {s}", .{@errorName(err)});
            return;
        };
        defer {
            for (lv2_descriptors) |descriptor| {
                self.state_store.allocator.free(descriptor.id);
                self.state_store.allocator.free(descriptor.label);
                self.state_store.allocator.free(descriptor.category);
                self.state_store.allocator.free(descriptor.bundle_name);
                for (descriptor.control_ports) |control_port| {
                    self.state_store.allocator.free(control_port.symbol);
                    self.state_store.allocator.free(control_port.label);
                }
                self.state_store.allocator.free(descriptor.control_ports);
                self.state_store.allocator.free(descriptor.primary_ui_uri);
            }
            self.state_store.allocator.free(lv2_descriptors);
        }

        for (lv2_descriptors) |descriptor| {
            try self.state_store.addPluginDescriptor(descriptor);
        }

        _ = try self.state_store.ensurePluginParamsMatchDescriptors();
    }

    fn startRefreshWorker(self: *App) !void {
        if (self.refresh_thread != null) return;
        self.refresh_stop.store(false, .release);
        self.refresh_thread = try std.Thread.spawn(.{}, refreshWorkerMain, .{self});
    }

    fn startRoutingWorker(self: *App) !void {
        if (self.routing_thread != null) return;
        self.routing_stop.store(false, .release);
        self.routing_thread = try std.Thread.spawn(.{}, routingWorkerMain, .{self});
    }

    fn stopRefreshWorker(self: *App) void {
        self.refresh_stop.store(true, .release);
        if (self.refresh_thread) |thread| {
            thread.join();
            self.refresh_thread = null;
        }
    }

    fn stopRoutingWorker(self: *App) void {
        self.routing_stop.store(true, .release);
        if (self.routing_thread) |thread| {
            thread.join();
            self.routing_thread = null;
        }
    }

    fn clearPendingRefresh(self: *App) void {
        self.refresh_mutex.lock();
        defer self.refresh_mutex.unlock();
        if (self.pending_refresh) |pending| {
            var value = pending.*;
            value.deinit(worker_allocator);
            worker_allocator.destroy(pending);
            self.pending_refresh = null;
        }
    }

    fn clearPendingRouting(self: *App) void {
        self.routing_mutex.lock();
        defer self.routing_mutex.unlock();
        if (self.pending_routing) |pending| {
            var value = pending.*;
            value.deinit();
            worker_allocator.destroy(pending);
            self.pending_routing = null;
        }
    }

    fn enqueueRoutingSnapshot(self: *App, snapshot: RoutingSnapshot) void {
        const snapshot_ptr = worker_allocator.create(RoutingSnapshot) catch {
            var owned = snapshot;
            owned.deinit();
            return;
        };
        snapshot_ptr.* = snapshot;

        self.routing_mutex.lock();
        defer self.routing_mutex.unlock();
        if (self.pending_routing) |pending| {
            var old = pending.*;
            old.deinit();
            worker_allocator.destroy(pending);
        }
        self.pending_routing = snapshot_ptr;
    }

    fn applyPendingRefresh(self: *App) !void {
        self.refresh_mutex.lock();
        const pending = self.pending_refresh;
        self.pending_refresh = null;
        self.refresh_mutex.unlock();

        if (pending) |refresh_ptr| {
            defer {
                var refresh = refresh_ptr.*;
                refresh.deinit(worker_allocator);
                worker_allocator.destroy(refresh_ptr);
            }
            if (inventoryRefreshMatchesState(self.state_store, refresh_ptr.*)) {
                const meter_specs_changed = self.pulse_peak.wouldChange(refresh_ptr.*.meter_specs);
                self.pulse_peak.sync(refresh_ptr.*.meter_specs) catch |err| {
                    std.log.warn("pulse peak meter resync failed: {s}", .{@errorName(err)});
                };
                if (meter_specs_changed and hasConfiguredOutputRoutes(self.state_store)) {
                    self.route_dirty = true;
                }
                self.last_inventory_refresh_ns = std.time.nanoTimestamp();
                return;
            }
            try self.applyInventoryRefresh(refresh_ptr.*);
            self.last_inventory_refresh_ns = std.time.nanoTimestamp();
        }
    }

    fn buildRoutingSnapshot(self: *App, allocator: std.mem.Allocator) !RoutingSnapshot {
        var snapshot_store = StateStore.init(allocator);
        errdefer snapshot_store.deinit();

        try snapshot_store.setActiveProfile(self.state_store.active_profile);
        snapshot_store.channel_feed = self.state_store.channel_feed;
        snapshot_store.destination_feed = self.state_store.destination_feed;

        for (self.state_store.channels.items) |channel| {
            try snapshot_store.addChannel(channel);
        }
        for (self.state_store.buses.items) |bus| {
            try snapshot_store.addBus(bus);
        }
        for (self.state_store.sources.items) |source| {
            try snapshot_store.addSource(source);
        }
        for (self.state_store.channel_sources.items) |channel_source| {
            try snapshot_store.addChannelSource(channel_source);
        }
        for (self.state_store.destinations.items) |destination| {
            try snapshot_store.addDestination(destination);
        }
        for (self.state_store.bus_destinations.items) |bus_destination| {
            try snapshot_store.addBusDestination(bus_destination);
        }
        for (self.state_store.sends.items) |send| {
            try snapshot_store.addSend(send);
        }
        for (self.state_store.channel_plugins.items) |channel_plugin| {
            try snapshot_store.addChannelPlugin(channel_plugin);
        }
        for (self.state_store.channel_plugin_params.items) |param| {
            try snapshot_store.addChannelPluginParam(param);
        }

        return .{ .state_store = snapshot_store };
    }

    fn reconcileOutputRouting(self: *App, state_store: *const StateStore) !void {
        var fx_channels = std.ArrayList(channels_mod.Channel).empty;
        defer fx_channels.deinit(self.allocator);
        try collectActiveFxChannels(self.allocator, state_store, &fx_channels);
        try self.fx_virtual_inputs.sync(fx_channels.items);
        try self.fx_processed_inputs.sync(fx_channels.items);
        try self.fx_filters.sync(
            &self.fx_runtime,
            state_store.channels.items,
            state_store.sources.items,
            state_store.channel_sources.items,
            fx_channels.items,
        );

        const pulsectx = try initPulseContextWithRetry(self.allocator);
        defer pulsectx.deinit();

        try self.syncSelectedBluetoothProfiles(state_store, pulsectx);

        const pulse_snapshot = try pulsectx.snapshot(self.allocator);
        defer pulse.freeSnapshot(self.allocator, pulse_snapshot);

        try self.output_exposure.sync(state_store, pulse_snapshot, pulsectx);

        const refreshed_pulse_snapshot = try pulsectx.snapshot(self.allocator);
        defer pulse.freeSnapshot(self.allocator, refreshed_pulse_snapshot);

        const pipewire = try pw.PipewireContext.init(self.allocator);
        defer pipewire.deinit();
        try pipewire.scan();

        const owners = try binder.bind(self.allocator, &pipewire.registry_state, refreshed_pulse_snapshot);
        defer binder.freeBoundOwners(self.allocator, owners);

        var desired = std.ArrayList(DesiredSinkMove).empty;
        defer desired.deinit(self.allocator);
        try self.collectDesiredSinkMoves(state_store, &desired, owners, refreshed_pulse_snapshot, pulsectx, fx_channels.items);

        for (desired.items) |move| {
            const sink_input = findPulseSinkInput(refreshed_pulse_snapshot.sink_inputs, move.sink_input_index) orelse continue;
            const original_sink_index = sink_input.sink_index orelse continue;
            const keep_routed = try self.moveSinkInputWithRecheck(pulsectx, move.sink_input_index, move.target_sink_index);
            if (!keep_routed) continue;
            if (!hasRecordedOriginal(self.routed_sink_inputs.items, move.sink_input_index)) {
                try self.routed_sink_inputs.append(self.allocator, .{
                    .channel_id = try self.allocator.dupe(u8, move.channel_id),
                    .sink_input_index = move.sink_input_index,
                    .original_sink_index = original_sink_index,
                });
            }
        }

        try self.reconcileVirtualMicCaptureRouting(state_store, owners, refreshed_pulse_snapshot, pulsectx);

        var index: usize = 0;
        while (index < self.routed_sink_inputs.items.len) {
            const routed = self.routed_sink_inputs.items[index];
            if (containsDesiredMove(desired.items, routed.sink_input_index)) {
                index += 1;
                continue;
            }
            if (findPulseSinkInput(refreshed_pulse_snapshot.sink_inputs, routed.sink_input_index) == null) {
                self.allocator.free(routed.channel_id);
                _ = self.routed_sink_inputs.orderedRemove(index);
                continue;
            }
            const channel_still_has_target = (try self.resolveTargetSinkForChannel(state_store, routed.channel_id, refreshed_pulse_snapshot, pulsectx)) != null;
            if (channel_still_has_target) {
                index += 1;
                continue;
            }
            pulsectx.moveSinkInputToSink(routed.sink_input_index, routed.original_sink_index) catch {};
            self.allocator.free(routed.channel_id);
            _ = self.routed_sink_inputs.orderedRemove(index);
        }

        try self.reconcilePhysicalSourceLoopbacks(state_store, refreshed_pulse_snapshot, pulsectx, fx_channels.items);
        try self.reconcileFxOutputLoopbacks(state_store, refreshed_pulse_snapshot, pulsectx, fx_channels.items);
    }

    fn syncSelectedBluetoothProfiles(self: *App, state_store: *const StateStore, pulsectx: *pulse.PulseContext) !void {
        var desired_profiles = std.AutoHashMap(u32, []const u8).init(self.allocator);
        defer desired_profiles.deinit();

        for (state_store.bus_destinations.items) |bus_destination| {
            if (!bus_destination.enabled) continue;
            const destination = findStateDestination(state_store.destinations.items, bus_destination.destination_id) orelse continue;
            const card_index = destination.pulse_card_index orelse continue;
            if (destination.pulse_card_profile.len == 0) continue;
            _ = try desired_profiles.getOrPutValue(card_index, destination.pulse_card_profile);
        }

        if (desired_profiles.count() == 0) return;

        const cards = try pulsectx.listCards(self.allocator);
        defer pulse.freeCards(self.allocator, cards);

        var iter = desired_profiles.iterator();
        while (iter.next()) |entry| {
            const card = findPulseCard(cards, entry.key_ptr.*) orelse continue;
            const desired_profile = entry.value_ptr.*;
            if (card.active_profile != null and std.mem.eql(u8, card.active_profile.?, desired_profile)) continue;
            pulsectx.setCardProfileByIndex(card.index, desired_profile) catch |err| {
                std.log.warn("failed to switch bluetooth card {d} to profile {s}: {s}", .{
                    card.index,
                    desired_profile,
                    @errorName(err),
                });
            };
        }
    }

    fn restoreOutputRouting(self: *App) !void {
        const pulsectx = try initPulseContextWithRetry(self.allocator);
        defer pulsectx.deinit();

        for (self.routed_sink_inputs.items) |routed| {
            pulsectx.moveSinkInputToSink(routed.sink_input_index, routed.original_sink_index) catch {};
            self.allocator.free(routed.channel_id);
        }
        self.routed_sink_inputs.clearRetainingCapacity();

        for (self.routed_source_outputs.items) |routed| {
            pulsectx.moveSourceOutputToSource(routed.source_output_index, routed.original_source_index) catch {};
        }
        self.routed_source_outputs.clearRetainingCapacity();

        for (self.routed_combine_modules.items) |module| {
            pulsectx.unloadModule(module.module_index) catch {};
            self.allocator.free(module.channel_id);
            self.allocator.free(module.sink_name);
            self.allocator.free(module.sink_key);
        }
        self.routed_combine_modules.clearRetainingCapacity();

        for (self.routed_loopback_modules.items) |module| {
            pulsectx.unloadModule(module.module_index) catch {};
            self.allocator.free(module.channel_id);
            self.allocator.free(module.source_name);
            self.allocator.free(module.sink_name);
        }
        self.routed_loopback_modules.clearRetainingCapacity();

        for (self.routed_fx_output_loopbacks.items) |module| {
            pulsectx.unloadModule(module.module_index) catch {};
            self.allocator.free(module.channel_id);
            self.allocator.free(module.source_name);
            self.allocator.free(module.sink_name);
        }
        self.routed_fx_output_loopbacks.clearRetainingCapacity();

        self.output_exposure.resetAudioState() catch {};
    }

    fn moveSinkInputWithRecheck(
        self: *App,
        pulsectx: *pulse.PulseContext,
        sink_input_index: u32,
        target_sink_index: u32,
    ) !bool {
        pulsectx.moveSinkInputToSink(sink_input_index, target_sink_index) catch |err| switch (err) {
            error.PulseMoveSinkInputFailed, error.PulseOperationTimedOut => {
                const latest_snapshot = pulsectx.snapshot(self.allocator) catch return err;
                defer pulse.freeSnapshot(self.allocator, latest_snapshot);

                const latest_input = findPulseSinkInput(latest_snapshot.sink_inputs, sink_input_index) orelse return false;
                const current_sink_index = latest_input.sink_index orelse return false;
                if (current_sink_index == target_sink_index) return true;
                return err;
            },
            else => return err,
        };
        return true;
    }

    fn moveSourceOutputWithRecheck(
        self: *App,
        pulsectx: *pulse.PulseContext,
        source_output_index: u32,
        target_source_index: u32,
    ) !bool {
        pulsectx.moveSourceOutputToSource(source_output_index, target_source_index) catch |err| switch (err) {
            error.PulseMoveSourceOutputFailed, error.PulseOperationTimedOut => {
                const latest_snapshot = pulsectx.snapshot(self.allocator) catch return err;
                defer pulse.freeSnapshot(self.allocator, latest_snapshot);

                const latest_output = findPulseSourceOutput(latest_snapshot.source_outputs, source_output_index) orelse return false;
                const current_source_index = latest_output.source_index orelse return false;
                if (current_source_index == target_source_index) return true;
                return err;
            },
            else => return err,
        };
        return true;
    }

    fn reconcileVirtualMicCaptureRouting(
        self: *App,
        state_store: *const StateStore,
        owners: []const binder.BoundOwner,
        pulse_snapshot: pulse.PulseSnapshot,
        pulsectx: *pulse.PulseContext,
    ) !void {
        _ = state_store;
        _ = owners;

        const restore_index: usize = 0;
        while (restore_index < self.routed_source_outputs.items.len) {
            const routed = self.routed_source_outputs.items[restore_index];
            if (findPulseSourceOutput(pulse_snapshot.source_outputs, routed.source_output_index) == null) {
                _ = self.routed_source_outputs.orderedRemove(restore_index);
                continue;
            }
            pulsectx.moveSourceOutputToSource(routed.source_output_index, routed.original_source_index) catch {};
            _ = self.routed_source_outputs.orderedRemove(restore_index);
        }
        self.blocked_source_outputs.clearRetainingCapacity();
    }

    fn collectDesiredSinkMoves(
        self: *App,
        state_store: *const StateStore,
        out: *std.ArrayList(DesiredSinkMove),
        owners: []const binder.BoundOwner,
        pulse_snapshot: pulse.PulseSnapshot,
        pulsectx: *pulse.PulseContext,
        fx_channels: []const channels_mod.Channel,
    ) !void {
        for (state_store.channels.items) |channel| {
            const bound_source_id = channel.bound_source_id orelse continue;
            const source = findStateSource(state_store.sources.items, bound_source_id) orelse continue;
            if (source.kind != .app) continue;
            const target_sink = try resolveCaptureSinkForChannel(self, state_store, channel.id, pulse_snapshot, pulsectx, containsChannel(fx_channels, channel.id)) orelse continue;
            for (owners) |owner| {
                if (!try ownerMatchesGroupedSourceId(self.allocator, owner, bound_source_id)) continue;
                for (owner.pulse_sink_input_indexes) |sink_input_index| {
                    const sink_input = findPulseSinkInput(pulse_snapshot.sink_inputs, sink_input_index) orelse continue;
                    const current_sink_index = sink_input.sink_index orelse continue;
                    if (current_sink_index == target_sink.sink_index) continue;
                    if (!containsDesiredMove(out.items, sink_input_index)) {
                        try out.append(self.allocator, .{
                            .channel_id = channel.id,
                            .sink_input_index = sink_input_index,
                            .target_sink_index = target_sink.sink_index,
                        });
                    }
                }
            }
        }
    }

    fn resolveTargetSinkForChannel(
        self: *App,
        state_store: *const StateStore,
        channel_id: []const u8,
        pulse_snapshot: pulse.PulseSnapshot,
        pulsectx: *pulse.PulseContext,
    ) !?ChannelTargetSink {
        var sinks = std.ArrayList(ChannelTargetSink).empty;
        defer sinks.deinit(self.allocator);

        for (state_store.sends.items) |send| {
            if (!send.enabled) continue;
            if (!std.mem.eql(u8, send.channel_id, channel_id)) continue;
            try self.appendDestinationsForBus(state_store, &sinks, send.bus_id, pulse_snapshot);
        }
        if (sinks.items.len == 0) return null;
        if (sinks.items.len == 1) return sinks.items[0];
        return self.ensureCombinedSinkForChannel(channel_id, sinks.items, pulse_snapshot, pulsectx) catch |err| blk: {
            std.log.warn("combine sink fallback for {s}: {s}", .{ channel_id, @errorName(err) });
            break :blk sinks.items[0];
        };
    }

    fn appendDestinationsForBus(self: *const App, state_store: *const StateStore, out: *std.ArrayList(ChannelTargetSink), bus_id: []const u8, pulse_snapshot: pulse.PulseSnapshot) !void {
        _ = state_store;
        const sink_name = try output_exposure_mod.allocOutputSinkName(self.allocator, bus_id);
        defer self.allocator.free(sink_name);
        const sink = findPulseSinkByName(pulse_snapshot, sink_name) orelse return;
        const resolved_name = sink.name orelse return;
        if (!containsChannelTargetSink(out.items, sink.index)) {
            try out.append(self.allocator, .{
                .sink_index = sink.index,
                .sink_name = resolved_name,
            });
        }
    }

    fn ensureCombinedSinkForChannel(
        self: *App,
        channel_id: []const u8,
        sinks: []const ChannelTargetSink,
        pulse_snapshot: pulse.PulseSnapshot,
        pulsectx: *pulse.PulseContext,
    ) !?ChannelTargetSink {
        const sink_key = try buildSinkKey(self.allocator, sinks);
        defer self.allocator.free(sink_key);

        if (findCombineModuleIndex(self.routed_combine_modules.items, channel_id)) |index| {
            const existing = self.routed_combine_modules.items[index];
            if (std.mem.eql(u8, existing.sink_key, sink_key)) {
                const sink_index = findPulseSinkIndexByName(pulse_snapshot, existing.sink_name) orelse return null;
                return .{
                    .sink_index = sink_index,
                    .sink_name = existing.sink_name,
                };
            }
            pulsectx.unloadModule(existing.module_index) catch {};
            self.allocator.free(existing.channel_id);
            self.allocator.free(existing.sink_name);
            self.allocator.free(existing.sink_key);
            _ = self.routed_combine_modules.orderedRemove(index);
        }

        const sink_name = try std.fmt.allocPrint(self.allocator, "wiredeck-combine-{s}", .{sanitizeId(channel_id)});
        errdefer self.allocator.free(sink_name);

        var slaves = std.ArrayList(u8).empty;
        defer slaves.deinit(self.allocator);
        for (sinks, 0..) |sink, index| {
            if (index > 0) try slaves.append(self.allocator, ',');
            try slaves.appendSlice(self.allocator, sink.sink_name);
        }
        const slaves_owned = try slaves.toOwnedSlice(self.allocator);
        defer self.allocator.free(slaves_owned);

        const args = try std.fmt.allocPrint(self.allocator, "sink_name={s} slaves={s}", .{ sink_name, slaves_owned });
        defer self.allocator.free(args);

        const module_index = try pulsectx.loadModule("module-combine-sink", args);

        const refreshed = try pulsectx.snapshot(self.allocator);
        defer pulse.freeSnapshot(self.allocator, refreshed);
        const sink_index = findPulseSinkIndexByName(refreshed, sink_name) orelse return null;

        try self.routed_combine_modules.append(self.allocator, .{
            .channel_id = try self.allocator.dupe(u8, channel_id),
            .module_index = module_index,
            .sink_name = sink_name,
            .sink_key = try self.allocator.dupe(u8, sink_key),
        });
        return .{
            .sink_index = sink_index,
            .sink_name = sink_name,
        };
    }

    fn reconcilePhysicalSourceLoopbacks(
        self: *App,
        state_store: *const StateStore,
        pulse_snapshot: pulse.PulseSnapshot,
        pulsectx: *pulse.PulseContext,
        fx_channels: []const channels_mod.Channel,
    ) !void {
        for (state_store.channels.items) |channel| {
            const bound_source_id = channel.bound_source_id orelse continue;
            const source = findStateSource(state_store.sources.items, bound_source_id) orelse continue;
            if (source.kind == .app) continue;

            const target_sink = try resolveCaptureSinkForChannel(self, state_store, channel.id, pulse_snapshot, pulsectx, containsChannel(fx_channels, channel.id));
            const pulse_source_name = if (target_sink != null)
                matchPulseSourceNameForStateSource(pulse_snapshot, source)
            else
                null;

            try self.syncLoopbackModule(channel.id, pulse_source_name, if (target_sink) |target| target.sink_name else null, pulsectx);
        }

        var index: usize = 0;
        while (index < self.routed_loopback_modules.items.len) {
            const module = self.routed_loopback_modules.items[index];
            if (findStateChannel(state_store, module.channel_id) != null) {
                index += 1;
                continue;
            }
            pulsectx.unloadModule(module.module_index) catch {};
            self.allocator.free(module.channel_id);
            self.allocator.free(module.source_name);
            self.allocator.free(module.sink_name);
            _ = self.routed_loopback_modules.orderedRemove(index);
        }
    }

    fn syncLoopbackModule(
        self: *App,
        channel_id: []const u8,
        pulse_source_name: ?[]const u8,
        sink_name: ?[]const u8,
        pulsectx: *pulse.PulseContext,
    ) !void {
        if (findLoopbackModuleIndex(self.routed_loopback_modules.items, channel_id)) |index| {
            const existing = self.routed_loopback_modules.items[index];
            if (pulse_source_name != null and sink_name != null and
                std.mem.eql(u8, existing.source_name, pulse_source_name.?) and
                std.mem.eql(u8, existing.sink_name, sink_name.?))
            {
                return;
            }

            pulsectx.unloadModule(existing.module_index) catch {};
            self.allocator.free(existing.channel_id);
            self.allocator.free(existing.source_name);
            self.allocator.free(existing.sink_name);
            _ = self.routed_loopback_modules.orderedRemove(index);
        }

        if (pulse_source_name == null or sink_name == null) return;

        const args = try std.fmt.allocPrint(
            self.allocator,
            "source={s} sink={s} source_dont_move=true sink_dont_move=true",
            .{ pulse_source_name.?, sink_name.? },
        );
        defer self.allocator.free(args);

        const module_index = try pulsectx.loadModule("module-loopback", args);
        try self.routed_loopback_modules.append(self.allocator, .{
            .channel_id = try self.allocator.dupe(u8, channel_id),
            .module_index = module_index,
            .source_name = try self.allocator.dupe(u8, pulse_source_name.?),
            .sink_name = try self.allocator.dupe(u8, sink_name.?),
        });
    }

    fn reconcileFxOutputLoopbacks(
        self: *App,
        state_store: *const StateStore,
        pulse_snapshot: pulse.PulseSnapshot,
        pulsectx: *pulse.PulseContext,
        fx_channels: []const channels_mod.Channel,
    ) !void {
        for (fx_channels) |channel| {
            const target_sink = try self.resolveTargetSinkForChannel(state_store, channel.id, pulse_snapshot, pulsectx);
            const processed_source_name = if (target_sink != null)
                try allocFxMonitorSourceName(self.allocator, channel.id)
            else
                null;
            defer if (processed_source_name) |value| self.allocator.free(value);

            try self.syncFxOutputLoopbackModule(
                channel.id,
                processed_source_name,
                if (target_sink) |target| target.sink_name else null,
                pulsectx,
            );
        }

        var index: usize = 0;
        while (index < self.routed_fx_output_loopbacks.items.len) {
            const module = self.routed_fx_output_loopbacks.items[index];
            if (containsChannel(fx_channels, module.channel_id)) {
                index += 1;
                continue;
            }
            pulsectx.unloadModule(module.module_index) catch {};
            self.allocator.free(module.channel_id);
            self.allocator.free(module.source_name);
            self.allocator.free(module.sink_name);
            _ = self.routed_fx_output_loopbacks.orderedRemove(index);
        }
    }

    fn syncFxOutputLoopbackModule(
        self: *App,
        channel_id: []const u8,
        pulse_source_name: ?[]const u8,
        sink_name: ?[]const u8,
        pulsectx: *pulse.PulseContext,
    ) !void {
        if (findFxOutputLoopbackModuleIndex(self.routed_fx_output_loopbacks.items, channel_id)) |index| {
            const existing = self.routed_fx_output_loopbacks.items[index];
            if (pulse_source_name != null and sink_name != null and
                std.mem.eql(u8, existing.source_name, pulse_source_name.?) and
                std.mem.eql(u8, existing.sink_name, sink_name.?))
            {
                return;
            }

            pulsectx.unloadModule(existing.module_index) catch {};
            self.allocator.free(existing.channel_id);
            self.allocator.free(existing.source_name);
            self.allocator.free(existing.sink_name);
            _ = self.routed_fx_output_loopbacks.orderedRemove(index);
        }

        if (pulse_source_name == null or sink_name == null) return;

        const args = try std.fmt.allocPrint(
            self.allocator,
            "source={s} sink={s} source_dont_move=true sink_dont_move=true",
            .{ pulse_source_name.?, sink_name.? },
        );
        defer self.allocator.free(args);

        const module_index = try pulsectx.loadModule("module-loopback", args);
        try self.routed_fx_output_loopbacks.append(self.allocator, .{
            .channel_id = try self.allocator.dupe(u8, channel_id),
            .module_index = module_index,
            .source_name = try self.allocator.dupe(u8, pulse_source_name.?),
            .sink_name = try self.allocator.dupe(u8, sink_name.?),
        });
    }

    fn buildInventoryRefresh(self: *App, allocator: std.mem.Allocator) !InventoryRefresh {
        const pipewire = try pw.PipewireContext.init(allocator);
        defer pipewire.deinit();
        try pipewire.scan();

        const pulsectx = try initPulseContextWithRetry(allocator);
        defer pulsectx.deinit();

        const snapshot = try pulsectx.snapshot(allocator);
        defer pulse.freeSnapshot(allocator, snapshot);
        const cards = try pulsectx.listCards(allocator);
        defer pulse.freeCards(allocator, cards);

        const owners = try binder.bind(allocator, &pipewire.registry_state, snapshot);
        defer binder.freeBoundOwners(allocator, owners);

        var sources = std.ArrayList(sources_mod.Source).empty;
        defer sources.deinit(allocator);
        try appendRegistryHardwareSourcesToList(allocator, &sources, &pipewire.registry_state);
        try appendGroupedAppSourcesToList(allocator, &sources, owners);

        var destinations = std.ArrayList(destinations_mod.Destination).empty;
        defer destinations.deinit(allocator);
        try appendDestinationsToList(allocator, &destinations, &pipewire.registry_state, snapshot, cards);

        var meter_specs = std.ArrayList(pulse.MeterSpec).empty;
        defer meter_specs.deinit(allocator);
        for (sources.items) |source| {
            if (source.kind == .app) {
                try appendAppPulseSpecs(allocator, &meter_specs, snapshot, owners, source.id);
            } else {
                try appendPhysicalPulseSpecs(allocator, &meter_specs, snapshot, source);
            }
        }
        for (self.state_store.channels.items) |channel| {
            try appendPostFxPulseSpecs(allocator, &meter_specs, channel);
        }

        return .{
            .sources = try sources.toOwnedSlice(allocator),
            .destinations = try destinations.toOwnedSlice(allocator),
            .meter_specs = try meter_specs.toOwnedSlice(allocator),
        };
    }

    fn applyInventoryRefresh(self: *App, refresh: InventoryRefresh) !void {
        var preserved_bus_destinations = std.ArrayList(PreservedBusDestination).empty;
        defer freePreservedBusDestinations(self.allocator, &preserved_bus_destinations);
        try collectPreservedBusDestinations(self.allocator, &preserved_bus_destinations, self.state_store);
        const restored_preserved = try self.allocator.alloc(bool, preserved_bus_destinations.items.len);
        defer self.allocator.free(restored_preserved);
        @memset(restored_preserved, false);

        self.state_store.clearSources();
        self.state_store.clearChannelSources();
        self.state_store.channel_feed = .pulse_pipewire;

        for (refresh.sources) |source| {
            try self.state_store.addSource(source);
        }
        try self.rebuildChannelSources();

        self.state_store.clearDestinations();
        self.state_store.clearBusDestinations();
        for (refresh.destinations) |destination| {
            try self.state_store.addDestination(destination);
        }
        self.state_store.destination_feed = if (self.state_store.destinations.items.len > 0) .pipewire else .unavailable;
        for (self.state_store.buses.items) |bus| {
            for (self.state_store.destinations.items) |destination| {
                const preserved_index = findPreservedBusDestinationIndex(preserved_bus_destinations.items, bus.id, destination);
                if (preserved_index) |index| restored_preserved[index] = true;
                try self.state_store.addBusDestination(.{
                    .bus_id = bus.id,
                    .destination_id = destination.id,
                    .destination_sink_name = destination.pulse_sink_name,
                    .destination_label = destination.label,
                    .destination_subtitle = destination.subtitle,
                    .destination_kind = destination.kind,
                    .enabled = if (preserved_index) |index| preserved_bus_destinations.items[index].enabled else false,
                });
            }
        }
        for (preserved_bus_destinations.items, 0..) |item, index| {
            if (restored_preserved[index]) continue;
            if (findStateBus(self.state_store, item.bus_id) == null) continue;
            try self.state_store.addBusDestination(.{
                .bus_id = item.bus_id,
                .destination_id = item.destination_id,
                .destination_sink_name = item.destination_sink_name,
                .destination_label = item.destination_label,
                .destination_subtitle = item.destination_subtitle,
                .destination_kind = item.destination_kind,
                .enabled = item.enabled,
            });
        }

        self.pulse_peak.sync(refresh.meter_specs) catch |err| {
            std.log.warn("pulse peak meter sync failed: {s}", .{@errorName(err)});
        };
        self.route_dirty = self.routed_sink_inputs.items.len > 0 or
            self.routed_combine_modules.items.len > 0 or
            self.routed_loopback_modules.items.len > 0 or
            self.routed_fx_output_loopbacks.items.len > 0;
    }

    fn syncSourcesFromOwners(self: *App, registry: *const pw.RegistryState, owners: []const binder.BoundOwner) !void {
        self.state_store.clearSources();
        self.state_store.clearChannelSources();
        self.state_store.channel_feed = .pulse_pipewire;

        try self.appendRegistryHardwareSources(registry);
        try self.appendGroupedAppSources(owners);
        try self.rebuildChannelSources();
    }

    fn syncDestinationsFromRegistry(self: *App, registry: *const pw.RegistryState) !void {
        self.state_store.clearDestinations();
        self.state_store.clearBusDestinations();

        for (registry.objects.items) |obj| {
            if (obj.kind != .node) continue;

            const media_class = obj.props.media_class orelse continue;
            if (!isDestinationMediaClass(media_class)) continue;

            const destination_id = try std.fmt.allocPrint(self.allocator, "pw-destination-{d}", .{obj.id});
            defer self.allocator.free(destination_id);

            try self.state_store.addDestination(.{
                .id = destination_id,
                .label = obj.props.node_description orelse obj.props.node_name orelse obj.props.app_name orelse "PipeWire Destination",
                .subtitle = media_class,
                .kind = destinationKindForRegistryNode(obj),
            });
        }

        self.state_store.destination_feed = if (self.state_store.destinations.items.len > 0) .pipewire else .unavailable;

        for (self.state_store.buses.items) |bus| {
            for (self.state_store.destinations.items) |destination| {
                try self.state_store.addBusDestination(.{
                    .bus_id = bus.id,
                    .destination_id = destination.id,
                    .enabled = false,
                });
            }
        }
    }

    fn appendRegistryHardwareSources(self: *App, registry: *const pw.RegistryState) !void {
        for (registry.objects.items) |obj| {
            if (obj.kind != .node) continue;

            const media_class = obj.props.media_class orelse continue;
            if (!isSourceMediaClass(media_class)) continue;

            const source_id = try std.fmt.allocPrint(self.allocator, "pw-source-{d}", .{obj.id});
            defer self.allocator.free(source_id);

            try self.state_store.addSource(.{
                .id = source_id,
                .label = obj.props.node_description orelse obj.props.node_name orelse obj.props.app_name orelse "PipeWire Source",
                .subtitle = obj.props.media_name orelse media_class,
                .kind = sourceKindForRegistryNode(obj),
                .process_binary = obj.props.app_process_binary orelse "",
                .icon_name = sourceIconForRegistryNode(obj),
                .icon_path = "",
                .level_left = 0.0,
                .level_right = 0.0,
            });
        }
    }

    fn appendGroupedAppSources(self: *App, owners: []const binder.BoundOwner) !void {
        var grouped: std.ArrayList(GroupedAppSource) = .empty;
        defer {
            for (grouped.items) |*item| item.deinit(self.allocator);
            grouped.deinit(self.allocator);
        }

        for (owners) |owner| {
            const resolved = try icon.resolve(self.allocator, .{
                .process_binary = owner.process_binary,
                .app_name = owner.flatpak_app_id orelse owner.app_name,
            });
            defer icon.freeResolveResult(self.allocator, resolved);

            const key = try buildGroupedAppSourceId(self.allocator, owner, resolved);
            defer self.allocator.free(key);

            if (findGroupedAppSource(grouped.items, key)) |index| {
                try grouped.items[index].merge(self.allocator, owner, resolved);
                continue;
            }

            try grouped.append(self.allocator, try GroupedAppSource.init(self.allocator, owner, resolved, key));
        }

        for (grouped.items) |item| {
            try self.state_store.addSource(.{
                .id = item.id,
                .label = item.label,
                .subtitle = item.subtitle,
                .kind = .app,
                .process_binary = item.process_binary,
                .icon_name = item.icon_name,
                .icon_path = item.icon_path,
                .level_left = item.level_left,
                .level_right = item.level_right,
                .level = item.level,
                .muted = item.muted,
            });
        }
    }

    fn rebuildChannelSources(self: *App) !void {
        for (self.state_store.channels.items) |channel| {
            for (self.state_store.sources.items) |source| {
                try self.state_store.addChannelSource(.{
                    .channel_id = channel.id,
                    .source_id = source.id,
                    .enabled = if (channel.bound_source_id) |bound_id|
                        std.mem.eql(u8, bound_id, source.id)
                    else
                        false,
                });
            }
        }
    }

    fn syncPulsePeakMeters(self: *App, snapshot: pulse.PulseSnapshot, owners: []const binder.BoundOwner) !void {
        var specs: std.ArrayList(pulse.MeterSpec) = .empty;
        defer {
            for (specs.items) |spec| {
                self.allocator.free(spec.source_id);
                if (spec.channel_id) |channel_id| self.allocator.free(channel_id);
                self.allocator.free(spec.pulse_source_name);
            }
            specs.deinit(self.allocator);
        }

        for (self.state_store.sources.items) |source| {
            if (source.kind == .app) {
                try appendAppPulseSpecs(self.allocator, &specs, snapshot, owners, source.id);
            } else {
                try appendPhysicalPulseSpecs(self.allocator, &specs, snapshot, source);
            }
        }
        for (self.state_store.channels.items) |channel| {
            try appendPostFxPulseSpecs(self.allocator, &specs, channel);
        }

        self.pulse_peak.sync(specs.items) catch |err| {
            std.log.warn("pulse peak meter sync failed: {s}", .{@errorName(err)});
        };
    }
};

fn refreshWorkerMain(app: *App) void {
    while (!app.refresh_stop.load(.acquire)) {
        std.Thread.sleep(App.inventory_refresh_interval_ns);
        if (app.refresh_stop.load(.acquire)) break;
        if (app.refresh_running.swap(true, .acq_rel)) continue;
        defer _ = app.refresh_running.swap(false, .acq_rel);

        const refresh_ptr = App.worker_allocator.create(App.InventoryRefresh) catch continue;
        refresh_ptr.* = app.buildInventoryRefresh(App.worker_allocator) catch |err| {
            App.worker_allocator.destroy(refresh_ptr);
            std.log.warn("audio inventory worker refresh failed: {s}", .{@errorName(err)});
            continue;
        };

        app.refresh_mutex.lock();
        defer app.refresh_mutex.unlock();
        if (app.pending_refresh) |pending| {
            var old = pending.*;
            old.deinit(App.worker_allocator);
            App.worker_allocator.destroy(pending);
        }
        app.pending_refresh = refresh_ptr;
    }
}

fn routingWorkerMain(app: *App) void {
    while (!app.routing_stop.load(.acquire)) {
        std.Thread.sleep(App.routing_poll_interval_ns);
        if (app.routing_stop.load(.acquire)) break;

        app.routing_mutex.lock();
        const pending = app.pending_routing;
        app.pending_routing = null;
        app.routing_mutex.unlock();

        const snapshot_ptr = pending orelse continue;
        defer {
            var snapshot = snapshot_ptr.*;
            snapshot.deinit();
            App.worker_allocator.destroy(snapshot_ptr);
        }

        app.reconcileOutputRouting(&snapshot_ptr.state_store) catch |err| {
            if (err != error.CaptureSinkPending) {
                std.log.warn("routing worker reconcile failed: {s}", .{@errorName(err)});
            }
            app.routing_retry_requested.store(true, .release);
        };
    }
}

fn initPulseContextWithRetry(allocator: std.mem.Allocator) !*pulse.PulseContext {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        return pulse.PulseContext.init(allocator) catch |err| {
            if (err != error.PulseContextNotReady or attempt + 1 >= App.pulse_startup_retry_attempts) {
                return err;
            }
            std.Thread.sleep(App.pulse_startup_retry_delay_ns);
            continue;
        };
    }
}

fn connectPeakMonitorWithRetry(monitor: *pulse.PeakMonitor) !void {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        return monitor.connect() catch |err| {
            if (err != error.PulseContextNotReady or attempt + 1 >= App.pulse_startup_retry_attempts) {
                return err;
            }
            std.Thread.sleep(App.pulse_startup_retry_delay_ns);
            continue;
        };
    }
}

fn findStateSource(sources: []const sources_mod.Source, source_id: []const u8) ?sources_mod.Source {
    for (sources) |source| {
        if (std.mem.eql(u8, source.id, source_id)) return source;
    }
    return null;
}

fn resolvePulseTargetForDestination(snapshot: pulse.PulseSnapshot, destination: destinations_mod.Destination) ?App.ChannelTargetSink {
    if (destination.pulse_card_index) |card_index| {
        const sink = findPulseSinkForCardProfile(snapshot, card_index, destination.pulse_card_profile) orelse return null;
        const sink_name = sink.name orelse return null;
        return .{
            .sink_index = sink.index,
            .sink_name = sink_name,
        };
    }

    const sink_index = destination.pulse_sink_index orelse return null;
    if (destination.pulse_sink_name.len == 0) return null;
    return .{
        .sink_index = sink_index,
        .sink_name = destination.pulse_sink_name,
    };
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

fn appendRegistryHardwareSourcesToList(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(sources_mod.Source),
    registry: *const pw.RegistryState,
) !void {
    for (registry.objects.items) |obj| {
        if (obj.kind != .node) continue;

        const media_class = obj.props.media_class orelse continue;
        if (!isSourceMediaClass(media_class)) continue;
        if (isWiredeckManagedRegistryObject(obj)) continue;

        const source_id = try std.fmt.allocPrint(allocator, "pw-source-{d}", .{obj.id});
        errdefer allocator.free(source_id);
        const label = try allocator.dupe(u8, obj.props.node_description orelse obj.props.node_name orelse obj.props.app_name orelse "PipeWire Source");
        errdefer allocator.free(label);
        const subtitle = try allocator.dupe(u8, obj.props.media_name orelse media_class);
        errdefer allocator.free(subtitle);
        const process_binary = try allocator.dupe(u8, obj.props.app_process_binary orelse "");
        errdefer allocator.free(process_binary);
        const icon_name = try allocator.dupe(u8, sourceIconForRegistryNode(obj));
        errdefer allocator.free(icon_name);
        const icon_path = try allocator.dupe(u8, "");
        errdefer allocator.free(icon_path);

        try out.append(allocator, .{
            .id = source_id,
            .label = label,
            .subtitle = subtitle,
            .kind = sourceKindForRegistryNode(obj),
            .process_binary = process_binary,
            .icon_name = icon_name,
            .icon_path = icon_path,
            .level_left = 0.0,
            .level_right = 0.0,
        });
    }
}

fn appendGroupedAppSourcesToList(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(sources_mod.Source),
    owners: []const binder.BoundOwner,
) !void {
    var grouped: std.ArrayList(GroupedAppSource) = .empty;
    defer {
        for (grouped.items) |*item| item.deinit(allocator);
        grouped.deinit(allocator);
    }

    for (owners) |owner| {
        if (shouldSkipGroupedAppOwner(owner)) continue;

        const resolved = try icon.resolve(allocator, .{
            .process_binary = owner.process_binary,
            .app_name = owner.flatpak_app_id orelse owner.app_name,
        });
        defer icon.freeResolveResult(allocator, resolved);

        const key = try buildGroupedAppSourceId(allocator, owner, resolved);
        defer allocator.free(key);

        if (findGroupedAppSource(grouped.items, key)) |index| {
            try grouped.items[index].merge(allocator, owner, resolved);
            continue;
        }

        try grouped.append(allocator, try GroupedAppSource.init(allocator, owner, resolved, key));
    }

    for (grouped.items) |item| {
        try out.append(allocator, .{
            .id = try allocator.dupe(u8, item.id),
            .label = try allocator.dupe(u8, item.label),
            .subtitle = try allocator.dupe(u8, item.subtitle),
            .kind = .app,
            .process_binary = try allocator.dupe(u8, item.process_binary),
            .icon_name = try allocator.dupe(u8, item.icon_name),
            .icon_path = try allocator.dupe(u8, item.icon_path),
            .level_left = item.level_left,
            .level_right = item.level_right,
            .level = item.level,
            .muted = item.muted,
        });
    }
}

fn appendDestinationsToList(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(destinations_mod.Destination),
    registry: *const pw.RegistryState,
    pulse_snapshot: pulse.PulseSnapshot,
    pulse_cards: []const pulse.PulseCard,
) !void {
    var appended_bluetooth_cards = std.AutoHashMap(u32, void).init(allocator);
    defer appended_bluetooth_cards.deinit();

    for (registry.objects.items) |obj| {
        if (obj.kind != .node) continue;

        const media_class = obj.props.media_class orelse continue;
        if (!isDestinationMediaClass(media_class)) continue;
        if (isWiredeckManagedRegistryObject(obj)) continue;

        const base_label = obj.props.node_description orelse obj.props.node_name orelse obj.props.app_name orelse "PipeWire Destination";
        const base_subtitle = try destinationSubtitle(allocator, obj);
        defer allocator.free(base_subtitle);
        const matched_sink = matchPulseSinkForDestination(pulse_snapshot, base_label, base_subtitle);
        if (matched_sink) |sink| {
            if (sink.card_index) |card_index| {
                if (findPulseCard(pulse_cards, card_index)) |card| {
                    if (isBluetoothCard(card)) {
                        if (try appendBluetoothCardDestinations(allocator, out, card, matched_sink)) {
                            try appended_bluetooth_cards.put(card_index, {});
                        }
                        continue;
                    }
                }
            }
        }

        const destination_id = try std.fmt.allocPrint(allocator, "pw-destination-{d}", .{obj.id});
        errdefer allocator.free(destination_id);
        const label = try destinationLabel(allocator, base_label, matched_sink);
        errdefer allocator.free(label);
        const subtitle = try destinationSubtitleWithPulse(allocator, obj, matched_sink);
        errdefer allocator.free(subtitle);
        const pulse_sink_name = if (matched_sink) |sink| (sink.name orelse "") else "";
        if (isWiredeckManagedSinkName(pulse_sink_name)) {
            continue;
        }

        try out.append(allocator, .{
            .id = destination_id,
            .label = label,
            .subtitle = subtitle,
            .kind = destinationKindForRegistryNode(obj),
            .pulse_sink_index = if (matched_sink) |sink| sink.index else null,
            .pulse_sink_name = try allocator.dupe(u8, pulse_sink_name),
            .pulse_card_index = null,
            .pulse_card_profile = try allocator.dupe(u8, ""),
        });
    }
}

const PreservedBusDestination = struct {
    bus_id: []const u8,
    destination_id: []const u8,
    destination_sink_name: []const u8,
    destination_label: []const u8,
    destination_subtitle: []const u8,
    destination_kind: ?destinations_mod.DestinationKind,
    enabled: bool,
};

fn collectPreservedBusDestinations(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(PreservedBusDestination),
    state_store: *const StateStore,
) !void {
    for (state_store.bus_destinations.items) |bus_destination| {
        const destination = findStateDestination(state_store.destinations.items, bus_destination.destination_id);
        const destination_sink_name = if (destination) |item| item.pulse_sink_name else bus_destination.destination_sink_name;
        const destination_label = if (destination) |item| item.label else bus_destination.destination_label;
        const destination_subtitle = if (destination) |item| item.subtitle else bus_destination.destination_subtitle;
        const destination_kind = if (destination) |item| item.kind else bus_destination.destination_kind;
        if (isWiredeckManagedSinkName(destination_sink_name)) continue;
        try out.append(allocator, .{
            .bus_id = try allocator.dupe(u8, bus_destination.bus_id),
            .destination_id = try allocator.dupe(u8, bus_destination.destination_id),
            .destination_sink_name = try allocator.dupe(u8, destination_sink_name),
            .destination_label = try allocator.dupe(u8, destination_label),
            .destination_subtitle = try allocator.dupe(u8, destination_subtitle),
            .destination_kind = destination_kind,
            .enabled = bus_destination.enabled,
        });
    }
}

fn freePreservedBusDestinations(allocator: std.mem.Allocator, items: *std.ArrayList(PreservedBusDestination)) void {
    for (items.items) |item| {
        allocator.free(item.bus_id);
        allocator.free(item.destination_id);
        allocator.free(item.destination_sink_name);
        allocator.free(item.destination_label);
        allocator.free(item.destination_subtitle);
    }
    items.deinit(allocator);
}

fn findPreservedBusDestinationIndex(
    preserved: []const PreservedBusDestination,
    bus_id: []const u8,
    destination: destinations_mod.Destination,
) ?usize {
    for (preserved, 0..) |item, index| {
        if (!std.mem.eql(u8, item.bus_id, bus_id)) continue;
        if (std.mem.eql(u8, item.destination_id, destination.id)) return index;
        if (item.destination_sink_name.len != 0 and destination.pulse_sink_name.len != 0 and sameText(item.destination_sink_name, destination.pulse_sink_name)) return index;
        if (sameText(item.destination_label, destination.label) and sameText(item.destination_subtitle, destination.subtitle)) return index;
    }
    return null;
}

fn inventoryRefreshMatchesState(state_store: *const StateStore, refresh: App.InventoryRefresh) bool {
    if (state_store.sources.items.len != refresh.sources.len) return false;
    if (state_store.destinations.items.len != refresh.destinations.len) return false;

    for (state_store.sources.items, refresh.sources) |current, next| {
        if (!std.mem.eql(u8, current.id, next.id)) return false;
        if (!std.mem.eql(u8, current.label, next.label)) return false;
        if (!std.mem.eql(u8, current.subtitle, next.subtitle)) return false;
        if (current.kind != next.kind) return false;
        if (!std.mem.eql(u8, current.process_binary, next.process_binary)) return false;
        if (!std.mem.eql(u8, current.icon_name, next.icon_name)) return false;
        if (!std.mem.eql(u8, current.icon_path, next.icon_path)) return false;
    }

    for (state_store.destinations.items, refresh.destinations) |current, next| {
        if (!std.mem.eql(u8, current.id, next.id)) return false;
        if (!std.mem.eql(u8, current.label, next.label)) return false;
        if (!std.mem.eql(u8, current.subtitle, next.subtitle)) return false;
        if (current.kind != next.kind) return false;
        if (current.pulse_sink_index != next.pulse_sink_index) return false;
    }

    return true;
}

fn findStateDestination(items: []const destinations_mod.Destination, id: []const u8) ?destinations_mod.Destination {
    for (items) |item| {
        if (std.mem.eql(u8, item.id, id)) return item;
    }
    return null;
}

fn findStateBus(state_store: *const StateStore, id: []const u8) ?usize {
    for (state_store.buses.items, 0..) |bus, index| {
        if (std.mem.eql(u8, bus.id, id)) return index;
    }
    return null;
}

fn findMappedStateDestinationIndex(
    items: []const destinations_mod.Destination,
    discovered_destination: destinations_mod.Destination,
) ?usize {
    for (items, 0..) |item, index| {
        if (std.mem.eql(u8, item.id, discovered_destination.id)) return index;
    }
    for (items, 0..) |item, index| {
        if (item.pulse_sink_name.len == 0) continue;
        if (sameText(item.pulse_sink_name, discovered_destination.id)) return index;
        if (sameText(item.pulse_sink_name, discovered_destination.label)) return index;
        if (sameText(item.pulse_sink_name, discovered_destination.subtitle)) return index;
    }
    for (items, 0..) |item, index| {
        if (!sameText(item.label, discovered_destination.label)) continue;
        if (!sameText(item.subtitle, discovered_destination.subtitle)) continue;
        return index;
    }
    for (items, 0..) |item, index| {
        if (sameText(item.label, discovered_destination.label)) return index;
    }
    return null;
}

fn findStateChannel(state_store: *const StateStore, id: []const u8) ?channels_mod.Channel {
    for (state_store.channels.items) |channel| {
        if (std.mem.eql(u8, channel.id, id)) return channel;
    }
    return null;
}

fn matchPulseSinkIndexForDestination(snapshot: pulse.PulseSnapshot, label: []const u8, subtitle: []const u8) ?u32 {
    return if (matchPulseSinkForDestination(snapshot, label, subtitle)) |sink| sink.index else null;
}

fn matchPulseSinkNameForDestination(snapshot: pulse.PulseSnapshot, label: []const u8, subtitle: []const u8) ?[]const u8 {
    return if (matchPulseSinkForDestination(snapshot, label, subtitle)) |sink| (sink.name orelse "") else null;
}

fn matchPulseSinkForDestination(snapshot: pulse.PulseSnapshot, label: []const u8, subtitle: []const u8) ?pulse.PulseSink {
    for (snapshot.sinks) |sink| {
        const sink_name = sink.name orelse "";
        const sink_description = sink.description orelse "";
        if (sameText(label, sink_description) or sameText(label, sink_name) or sameText(subtitle, sink_description) or sameText(subtitle, sink_name)) {
            return sink;
        }
    }
    return null;
}

fn appendPhysicalPulseSpecs(
    allocator: std.mem.Allocator,
    specs: *std.ArrayList(pulse.MeterSpec),
    snapshot: pulse.PulseSnapshot,
    source: sources_mod.Source,
) !void {
    if (source.kind == .app) return;
    const pulse_source = matchPulseSourceForStateSource(snapshot, source) orelse return;
    const source_name = pulse_source.name orelse return;
    try specs.append(allocator, .{
        .source_id = try allocator.dupe(u8, source.id),
        .channel_id = null,
        .pulse_source_name = try allocator.dupe(u8, source_name),
        .sink_input_index = null,
        .channels = pulse_source.channels,
    });
}

fn appendAppPulseSpecs(
    allocator: std.mem.Allocator,
    specs: *std.ArrayList(pulse.MeterSpec),
    snapshot: pulse.PulseSnapshot,
    owners: []const binder.BoundOwner,
    grouped_source_id: []const u8,
) !void {
    for (owners) |owner| {
        if (shouldSkipGroupedAppOwner(owner)) continue;

        const resolved = try icon.resolve(allocator, .{
            .process_binary = owner.process_binary,
            .app_name = owner.flatpak_app_id orelse owner.app_name,
        });
        defer icon.freeResolveResult(allocator, resolved);

        const owner_group_id = try buildGroupedAppSourceId(allocator, owner, resolved);
        defer allocator.free(owner_group_id);
        if (!std.mem.eql(u8, owner_group_id, grouped_source_id)) continue;

        for (owner.pulse_sink_input_indexes) |sink_input_index| {
            const sink_input = findPulseSinkInput(snapshot.sink_inputs, sink_input_index) orelse continue;
            const sink_index = sink_input.sink_index orelse continue;
            const sink = findPulseSink(snapshot.sinks, sink_index) orelse continue;
            const monitor_name = sink.monitor_source_name orelse continue;
            try specs.append(allocator, .{
                .source_id = try allocator.dupe(u8, grouped_source_id),
                .channel_id = null,
                .pulse_source_name = try allocator.dupe(u8, monitor_name),
                .sink_input_index = sink_input_index,
                .channels = sink_input.channels,
            });
        }
    }
}

fn appendPostFxPulseSpecs(
    allocator: std.mem.Allocator,
    specs: *std.ArrayList(pulse.MeterSpec),
    channel: channels_mod.Channel,
) !void {
    if (channel.meter_stage != .post_fx) return;

    const monitor_name = try allocFxMonitorSourceName(allocator, channel.id);
    defer allocator.free(monitor_name);

    try specs.append(allocator, .{
        .source_id = try allocator.dupe(u8, channel.bound_source_id orelse channel.id),
        .channel_id = try allocator.dupe(u8, channel.id),
        .pulse_source_name = try allocator.dupe(u8, monitor_name),
        .sink_input_index = null,
        .channels = 2,
    });
}

fn findPulseSinkInput(items: []const pulse.PulseSinkInput, index: u32) ?pulse.PulseSinkInput {
    for (items) |item| {
        if (item.index == index) return item;
    }
    return null;
}

fn findPulseSourceOutput(items: []const pulse.PulseSourceOutput, index: u32) ?pulse.PulseSourceOutput {
    for (items) |item| {
        if (item.index == index) return item;
    }
    return null;
}

fn findPulseSink(items: []const pulse.PulseSink, index: u32) ?pulse.PulseSink {
    for (items) |item| {
        if (item.index == index) return item;
    }
    return null;
}

fn findPulseSourceIndexByName(snapshot: pulse.PulseSnapshot, source_name: []const u8) ?u32 {
    for (snapshot.sources) |source| {
        const current_name = source.name orelse continue;
        if (std.mem.eql(u8, current_name, source_name)) return source.index;
    }
    return null;
}

fn matchPulseSourceForStateSource(snapshot: pulse.PulseSnapshot, source: sources_mod.Source) ?pulse.PulseSource {
    if (source.kind == .app) return null;

    for (snapshot.sources) |pulse_source| {
        if (pulse_source.monitor_of_sink != null) continue;
        const source_name = pulse_source.name orelse continue;
        const description = pulse_source.description orelse "";
        if (!sameText(source.label, description) and
            !sameText(source.label, source_name) and
            !sameText(source.subtitle, description) and
            !sameText(source.subtitle, source_name))
        {
            continue;
        }
        return pulse_source;
    }
    return null;
}

fn matchPulseSourceNameForStateSource(snapshot: pulse.PulseSnapshot, source: sources_mod.Source) ?[]const u8 {
    const pulse_source = matchPulseSourceForStateSource(snapshot, source) orelse return null;
    return pulse_source.name;
}

fn findPulseSinkIndexByName(snapshot: pulse.PulseSnapshot, sink_name: []const u8) ?u32 {
    for (snapshot.sinks) |sink| {
        const current_name = sink.name orelse continue;
        if (std.mem.eql(u8, current_name, sink_name)) return sink.index;
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

fn resolvePreferredVirtualMicSourceIndex(
    allocator: std.mem.Allocator,
    state_store: *const StateStore,
    snapshot: pulse.PulseSnapshot,
) !?u32 {
    for (state_store.buses.items) |bus| {
        if (!bus.expose_as_microphone) continue;
        const source_name = try output_exposure_mod.allocVirtualMicSourceName(allocator, bus.id);
        defer allocator.free(source_name);
        return findPulseSourceIndexByName(snapshot, source_name);
    }
    return null;
}

fn hasRecordedSourceOutputOriginal(items: []const App.RoutedSourceOutput, source_output_index: u32) bool {
    for (items) |item| {
        if (item.source_output_index == source_output_index) return true;
    }
    return false;
}

fn containsBlockedSourceOutput(items: []const u32, source_output_index: u32) bool {
    for (items) |item| {
        if (item == source_output_index) return true;
    }
    return false;
}

fn removeBlockedSourceOutput(items: *std.ArrayList(u32), source_output_index: u32) void {
    for (items.items, 0..) |item, index| {
        if (item != source_output_index) continue;
        _ = items.orderedRemove(index);
        return;
    }
}

fn allocFxMonitorSourceName(allocator: std.mem.Allocator, channel_id: []const u8) ![]u8 {
    const sink_name = try virtual_inputs.allocSinkName(allocator, "wiredeck_fx_", channel_id);
    defer allocator.free(sink_name);
    return std.fmt.allocPrint(allocator, "{s}.monitor", .{sink_name});
}

fn resolveCaptureSinkForChannel(
    self: *App,
    state_store: *const StateStore,
    channel_id: []const u8,
    pulse_snapshot: pulse.PulseSnapshot,
    pulsectx: *pulse.PulseContext,
    uses_fx: bool,
) !?App.ChannelTargetSink {
    if (!uses_fx) return try self.resolveTargetSinkForChannel(state_store, channel_id, pulse_snapshot, pulsectx);

    const target_sink = try self.resolveTargetSinkForChannel(state_store, channel_id, pulse_snapshot, pulsectx);
    if (target_sink == null) return null;

    const sink_name = try virtual_inputs.allocSinkName(self.allocator, "wiredeck_input_", channel_id);
    defer self.allocator.free(sink_name);

    const sink = findPulseSinkByName(pulse_snapshot, sink_name) orelse return error.CaptureSinkPending;
    return .{
        .sink_index = sink.index,
        .sink_name = sink.name.?,
    };
}

fn collectActiveFxChannels(
    allocator: std.mem.Allocator,
    state_store: *const StateStore,
    channels: *std.ArrayList(channels_mod.Channel),
) !void {
    for (state_store.channels.items) |channel| {
        if (!channelHasLv2Plugin(state_store, channel.id)) continue;
        try channels.append(allocator, channel);
    }
}

fn channelHasLv2Plugin(state_store: *const StateStore, channel_id: []const u8) bool {
    for (state_store.channel_plugins.items) |channel_plugin| {
        if (channel_plugin.backend != .lv2) continue;
        if (std.mem.eql(u8, channel_plugin.channel_id, channel_id)) return true;
    }
    return false;
}

fn shouldSkipGroupedAppOwner(owner: binder.BoundOwner) bool {
    if (owner.process_binary) |binary| {
        if (containsIgnoreCase(binary, "wiredeck")) return true;
    }
    if (owner.app_name) |app_name| {
        if (containsIgnoreCase(app_name, "wiredeck")) return true;
    }
    if (owner.flatpak_app_id) |flatpak_app_id| {
        if (containsIgnoreCase(flatpak_app_id, "wiredeck")) return true;
    }
    return false;
}

fn isWiredeckManagedModule(name: []const u8, argument: []const u8) bool {
    if (std.mem.eql(u8, name, "module-null-sink")) {
        return containsIgnoreCase(argument, "sink_name=wiredeck_input_") or
            containsIgnoreCase(argument, "sink_name=wiredeck_fx_") or
            containsIgnoreCase(argument, "sink_name=wiredeck_output_") or
            containsIgnoreCase(argument, "sink_name=wiredeck_busmic_sink_");
    }
    if (std.mem.eql(u8, name, "module-remap-source")) {
        return containsIgnoreCase(argument, "source_name=wiredeck_busmic_");
    }
    if (std.mem.eql(u8, name, "module-combine-sink")) {
        return containsIgnoreCase(argument, "wiredeck-combine-");
    }
    if (std.mem.eql(u8, name, "module-loopback")) {
        return std.mem.eql(u8, argument, "--help") or
            (containsIgnoreCase(argument, "source_dont_move=true") and containsIgnoreCase(argument, "sink_dont_move=true"));
    }
    return false;
}

const GroupedAppSource = struct {
    id: []const u8,
    label: []const u8,
    subtitle: []const u8,
    process_binary: []const u8,
    icon_name: []const u8,
    icon_path: []const u8,
    level: f32 = 0.0,
    level_left: f32 = 0.0,
    level_right: f32 = 0.0,
    muted: bool = false,
    owner_count: usize = 1,

    fn init(
        allocator: std.mem.Allocator,
        owner: binder.BoundOwner,
        resolved: icon.ResolveResult,
        key: []const u8,
    ) !GroupedAppSource {
        const label = normalizedOwnerLabel(owner);
        const subtitle = normalizedOwnerSubtitle(owner);
        return .{
            .id = try allocator.dupe(u8, key),
            .label = try allocator.dupe(u8, label),
            .subtitle = try allocator.dupe(u8, subtitle),
            .process_binary = try allocator.dupe(u8, owner.process_binary orelse ""),
            .icon_name = try allocator.dupe(u8, resolved.icon_name orelse "audio-source"),
            .icon_path = try allocator.dupe(u8, resolved.icon_path orelse ""),
        };
    }

    fn merge(
        self: *GroupedAppSource,
        allocator: std.mem.Allocator,
        owner: binder.BoundOwner,
        resolved: icon.ResolveResult,
    ) !void {
        self.owner_count += 1;
        if (self.process_binary.len == 0) {
            if (owner.process_binary) |binary| {
                allocator.free(self.process_binary);
                self.process_binary = try allocator.dupe(u8, binary);
            }
        }
        if (self.icon_name.len == 0 and resolved.icon_name != null) {
            allocator.free(self.icon_name);
            self.icon_name = try allocator.dupe(u8, resolved.icon_name.?);
        }
        if (self.icon_path.len == 0 and resolved.icon_path != null) {
            allocator.free(self.icon_path);
            self.icon_path = try allocator.dupe(u8, resolved.icon_path.?);
        }
    }

    fn deinit(self: *GroupedAppSource, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.label);
        allocator.free(self.subtitle);
        allocator.free(self.process_binary);
        allocator.free(self.icon_name);
        allocator.free(self.icon_path);
    }
};

const DesiredSinkMove = struct {
    channel_id: []const u8,
    sink_input_index: u32,
    target_sink_index: u32,
};

fn buildSourceId(allocator: std.mem.Allocator, owner: binder.BoundOwner) ![]u8 {
    if (owner.real_pid) |pid| {
        if (owner.process_binary) |binary| {
            return std.fmt.allocPrint(allocator, "app-{d}-{s}", .{ pid, binary });
        }
        return std.fmt.allocPrint(allocator, "app-{d}", .{pid});
    }
    if (owner.pw_client_id) |client_id| {
        return std.fmt.allocPrint(allocator, "pw-client-{d}", .{client_id});
    }
    if (owner.pulse_client_index) |client_index| {
        return std.fmt.allocPrint(allocator, "pulse-client-{d}", .{client_index});
    }
    return allocator.dupe(u8, "app-unknown");
}

fn buildGroupedAppSourceId(
    allocator: std.mem.Allocator,
    owner: binder.BoundOwner,
    resolved: icon.ResolveResult,
) ![]u8 {
    if (resolved.desktop_file_id) |desktop_file_id| {
        return std.fmt.allocPrint(allocator, "appgrp-{s}", .{sanitizeId(desktop_file_id)});
    }
    if (owner.flatpak_app_id) |flatpak_app_id| {
        return std.fmt.allocPrint(allocator, "appgrp-{s}", .{sanitizeId(flatpak_app_id)});
    }
    if (resolved.icon_name) |icon_name| {
        return std.fmt.allocPrint(allocator, "appgrp-{s}", .{sanitizeId(icon_name)});
    }
    if (owner.process_binary) |binary| {
        return std.fmt.allocPrint(allocator, "appgrp-{s}", .{sanitizeId(binary)});
    }
    if (owner.app_name) |app_name| {
        return std.fmt.allocPrint(allocator, "appgrp-{s}", .{sanitizeId(app_name)});
    }
    return allocator.dupe(u8, "appgrp-unknown");
}

fn ownerMatchesGroupedSourceId(
    allocator: std.mem.Allocator,
    owner: binder.BoundOwner,
    grouped_source_id: []const u8,
) !bool {
    if (shouldSkipGroupedAppOwner(owner)) return false;

    const resolved = try icon.resolve(allocator, .{
        .process_binary = owner.process_binary,
        .app_name = owner.flatpak_app_id orelse owner.app_name,
    });
    defer icon.freeResolveResult(allocator, resolved);

    const owner_group_id = try buildGroupedAppSourceId(allocator, owner, resolved);
    defer allocator.free(owner_group_id);
    return std.mem.eql(u8, owner_group_id, grouped_source_id);
}

fn containsDesiredMove(items: []const DesiredSinkMove, sink_input_index: u32) bool {
    for (items) |item| {
        if (item.sink_input_index == sink_input_index) return true;
    }
    return false;
}

fn hasRecordedOriginal(items: []const App.RoutedSinkInput, sink_input_index: u32) bool {
    for (items) |item| {
        if (item.sink_input_index == sink_input_index) return true;
    }
    return false;
}

fn containsChannelTargetSink(items: []const App.ChannelTargetSink, sink_index: u32) bool {
    for (items) |item| {
        if (item.sink_index == sink_index) return true;
    }
    return false;
}

fn containsChannel(channels: []const channels_mod.Channel, channel_id: []const u8) bool {
    for (channels) |channel| {
        if (std.mem.eql(u8, channel.id, channel_id)) return true;
    }
    return false;
}

fn buildSinkKey(allocator: std.mem.Allocator, sinks: []const App.ChannelTargetSink) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    for (sinks, 0..) |sink, index| {
        if (index > 0) try buffer.append(allocator, ',');
        try buffer.appendSlice(allocator, sink.sink_name);
    }
    return try buffer.toOwnedSlice(allocator);
}

fn findCombineModuleIndex(items: []const App.RoutedCombineModule, channel_id: []const u8) ?usize {
    for (items, 0..) |item, index| {
        if (std.mem.eql(u8, item.channel_id, channel_id)) return index;
    }
    return null;
}

fn findLoopbackModuleIndex(items: []const App.RoutedLoopbackModule, channel_id: []const u8) ?usize {
    for (items, 0..) |item, index| {
        if (std.mem.eql(u8, item.channel_id, channel_id)) return index;
    }
    return null;
}

fn findFxOutputLoopbackModuleIndex(items: []const App.RoutedFxOutputLoopbackModule, channel_id: []const u8) ?usize {
    for (items, 0..) |item, index| {
        if (std.mem.eql(u8, item.channel_id, channel_id)) return index;
    }
    return null;
}

fn buildGroupedSourceIdForDiscovered(allocator: std.mem.Allocator, source: sources_mod.Source) ![]u8 {
    if (source.kind != .app) return allocator.dupe(u8, source.id);
    if (source.icon_name.len > 0 and !std.mem.eql(u8, source.icon_name, "application-x-executable")) {
        return std.fmt.allocPrint(allocator, "appgrp-{s}", .{sanitizeId(source.icon_name)});
    }
    if (source.process_binary.len > 0) {
        return std.fmt.allocPrint(allocator, "appgrp-{s}", .{sanitizeId(source.process_binary)});
    }
    if (source.label.len > 0) {
        return std.fmt.allocPrint(allocator, "appgrp-{s}", .{sanitizeId(source.label)});
    }
    return allocator.dupe(u8, "appgrp-unknown");
}

fn findGroupedAppSource(items: []const GroupedAppSource, id: []const u8) ?usize {
    for (items, 0..) |item, index| {
        if (std.mem.eql(u8, item.id, id)) return index;
    }
    return null;
}

fn findSourceIndex(items: []const sources_mod.Source, id: []const u8) ?usize {
    for (items, 0..) |item, index| {
        if (std.mem.eql(u8, item.id, id)) return index;
    }
    return null;
}

fn findMappedStateSourceIndex(
    allocator: std.mem.Allocator,
    items: []const sources_mod.Source,
    discovered_source: sources_mod.Source,
) !?usize {
    if (findSourceIndex(items, discovered_source.id)) |index| return index;

    const grouped_id = try buildGroupedSourceIdForDiscovered(allocator, discovered_source);
    defer allocator.free(grouped_id);
    if (findSourceIndex(items, grouped_id)) |index| return index;

    for (items, 0..) |item, index| {
        if (item.kind != discovered_source.kind) continue;

        if (item.kind == .app) {
            if (sameText(item.icon_name, discovered_source.icon_name) and item.icon_name.len > 0) return index;
            if (sameText(item.process_binary, discovered_source.process_binary) and item.process_binary.len > 0) return index;
            if (sameText(item.label, discovered_source.label) and item.label.len > 0) return index;
            if (looksLikeDiscordVoiceEngine(discovered_source) and looksLikeDiscordSource(item)) return index;

            if (item.label.len > 0 and discovered_source.label.len > 0 and
                (containsIgnoreCase(item.label, discovered_source.label) or containsIgnoreCase(discovered_source.label, item.label)))
            {
                return index;
            }
            if (item.process_binary.len > 0 and discovered_source.process_binary.len > 0 and
                (containsIgnoreCase(item.process_binary, discovered_source.process_binary) or containsIgnoreCase(discovered_source.process_binary, item.process_binary)))
            {
                return index;
            }
        } else {
            if (sameText(item.label, discovered_source.label) and item.label.len > 0) return index;
            if (sameText(item.subtitle, discovered_source.subtitle) and item.subtitle.len > 0) return index;
        }
    }

    return null;
}

fn normalizedOwnerLabel(owner: binder.BoundOwner) []const u8 {
    const candidate = owner.app_name orelse owner.process_binary orelse "Unknown App";
    if (containsIgnoreCase(candidate, "discord")) return "Discord";
    if (containsIgnoreCase(candidate, "firefox")) return "Firefox";
    if (containsIgnoreCase(candidate, "chromium")) return "Chromium";
    if (containsIgnoreCase(candidate, "chrome")) return "Google Chrome";
    if (containsIgnoreCase(candidate, "webrtc") and owner.process_binary != null and containsIgnoreCase(owner.process_binary.?, "discord")) return "Discord";
    return candidate;
}

fn normalizedOwnerSubtitle(owner: binder.BoundOwner) []const u8 {
    if (owner.process_binary) |binary| return binary;
    if (owner.flatpak_app_id) |flatpak_app_id| return flatpak_app_id;
    return confidenceLabel(owner.confidence);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

fn sameText(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    return std.ascii.eqlIgnoreCase(a, b);
}

fn hasConfiguredOutputRoutes(state_store: *const StateStore) bool {
    for (state_store.sends.items) |send| {
        if (!send.enabled) continue;
        for (state_store.bus_destinations.items) |bus_destination| {
            if (!bus_destination.enabled) continue;
            if (std.mem.eql(u8, send.bus_id, bus_destination.bus_id)) return true;
        }
    }
    return false;
}

fn looksLikeDiscordVoiceEngine(source: sources_mod.Source) bool {
    return source.kind == .app and
        (containsIgnoreCase(source.label, "webrtc voiceengine") or containsIgnoreCase(source.subtitle, "webrtc"));
}

fn looksLikeDiscordSource(source: sources_mod.Source) bool {
    if (source.kind != .app) return false;
    return containsIgnoreCase(source.label, "discord") or
        containsIgnoreCase(source.subtitle, "discord") or
        containsIgnoreCase(source.process_binary, "discord") or
        containsIgnoreCase(source.id, "discord");
}

fn looksLikeDiscordCaptureOwner(owner: binder.BoundOwner) bool {
    return containsIgnoreCase(owner.app_name orelse "", "discord") or
        containsIgnoreCase(owner.process_binary orelse "", "discord") or
        containsIgnoreCase(owner.app_name orelse "", "webrtc") or
        containsIgnoreCase(owner.process_binary orelse "", "webrtc") or
        containsIgnoreCase(owner.app_name orelse "", "voiceengine") or
        containsIgnoreCase(owner.process_binary orelse "", "voiceengine");
}

fn shouldSkipVirtualMicCaptureOwner(owner: binder.BoundOwner) bool {
    if (owner.pulse_source_output_indexes.len == 0) return true;
    return containsIgnoreCase(owner.app_name orelse "", "wiredeck") or
        containsIgnoreCase(owner.process_binary orelse "", "wiredeck");
}

fn sanitizeId(value: []const u8) []const u8 {
    return value;
}

fn isWiredeckManagedSinkName(sink_name: []const u8) bool {
    return std.mem.startsWith(u8, sink_name, "wiredeck-combine-") or
        std.mem.startsWith(u8, sink_name, "wiredeck_output_") or
        std.mem.startsWith(u8, sink_name, "wiredeck_input_") or
        std.mem.startsWith(u8, sink_name, "wiredeck_fx_") or
        std.mem.startsWith(u8, sink_name, "wiredeck_busmic_sink_");
}

fn isWiredeckManagedRegistryObject(obj: pw.types.GlobalObject) bool {
    if (obj.props.node_name) |node_name| {
        if (isWiredeckManagedNodeName(node_name)) return true;
    }
    if (obj.props.node_description) |node_description| {
        if (containsIgnoreCase(node_description, "wiredeck input ") or
            containsIgnoreCase(node_description, "wiredeck fx ") or
            containsIgnoreCase(node_description, "wiredeck level ") or
            containsIgnoreCase(node_description, "wiredeck output "))
        {
            return true;
        }
    }
    return false;
}

fn isWiredeckManagedNodeName(node_name: []const u8) bool {
    return std.mem.startsWith(u8, node_name, "wiredeck_input_") or
        std.mem.startsWith(u8, node_name, "wiredeck_fx_") or
        std.mem.startsWith(u8, node_name, "wiredeck_output_") or
        std.mem.startsWith(u8, node_name, "wiredeck_meter_") or
        std.mem.startsWith(u8, node_name, "WireDeck FX ");
}

fn confidenceLabel(confidence: binder.BoundOwner.Confidence) []const u8 {
    return switch (confidence) {
        .low => "Low confidence",
        .medium => "Medium confidence",
        .high => "High confidence",
    };
}

fn isDestinationMediaClass(media_class: []const u8) bool {
    return std.mem.eql(u8, media_class, "Audio/Sink") or
        std.mem.eql(u8, media_class, "Audio/Duplex");
}

fn destinationSubtitle(allocator: std.mem.Allocator, obj: pw.types.GlobalObject) ![]u8 {
    const media_class = obj.props.media_class orelse "Audio/Sink";
    if (obj.props.device_api == null or !std.mem.eql(u8, obj.props.device_api.?, "bluez5")) {
        return allocator.dupe(u8, media_class);
    }

    const profile = obj.props.bluez5_profile orelse "";
    const codec = obj.props.bluez5_codec orelse "";
    const mode = if (std.mem.startsWith(u8, profile, "a2dp-sink"))
        "Bluetooth Headphones"
    else if (std.mem.startsWith(u8, profile, "headset-head-unit"))
        "Bluetooth Headset"
    else
        "Bluetooth Audio";

    if (codec.len > 0) {
        const codec_upper = try allocator.dupe(u8, codec);
        defer allocator.free(codec_upper);
        for (codec_upper) |*char| char.* = std.ascii.toUpper(char.*);
        return std.fmt.allocPrint(allocator, "{s} ({s})", .{ mode, codec_upper });
    }

    return allocator.dupe(u8, mode);
}

fn appendBluetoothCardDestinations(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(destinations_mod.Destination),
    card: pulse.PulseCard,
    active_sink: ?pulse.PulseSink,
) !bool {
    const base_label = card.description orelse card.name orelse "Bluetooth Device";
    const headphones_profile = bestBluetoothProfile(card.profiles, .headphones);
    const headset_profile = bestBluetoothProfile(card.profiles, .headset);

    if (headphones_profile) |profile| {
        try appendBluetoothProfileDestination(allocator, out, card, active_sink, base_label, profile);
    }
    if (headset_profile) |profile| {
        try appendBluetoothProfileDestination(allocator, out, card, active_sink, base_label, profile);
    }

    return headphones_profile != null or headset_profile != null;
}

fn isBluetoothCard(card: pulse.PulseCard) bool {
    return card.device_api != null and std.mem.eql(u8, card.device_api.?, "bluez5");
}

fn isBluetoothOutputProfile(profile_name: []const u8) bool {
    return std.mem.startsWith(u8, profile_name, "a2dp-sink") or
        std.mem.startsWith(u8, profile_name, "headset-head-unit");
}

const BluetoothProfileFamily = enum {
    headphones,
    headset,
};

fn bestBluetoothProfile(profiles: []const pulse.PulseCardProfile, family: BluetoothProfileFamily) ?pulse.PulseCardProfile {
    var best: ?pulse.PulseCardProfile = null;
    for (profiles) |profile| {
        if (!profile.available or profile.n_sinks == 0) continue;
        const matches = switch (family) {
            .headphones => std.mem.startsWith(u8, profile.name, "a2dp-sink"),
            .headset => std.mem.startsWith(u8, profile.name, "headset-head-unit"),
        };
        if (!matches) continue;
        if (best == null or profile.priority > best.?.priority) best = profile;
    }
    return best;
}

fn appendBluetoothProfileDestination(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(destinations_mod.Destination),
    card: pulse.PulseCard,
    active_sink: ?pulse.PulseSink,
    base_label: []const u8,
    profile: pulse.PulseCardProfile,
) !void {
    const port_label = bluetoothPortLabel(profile.name);
    const label = if (port_label.len > 0)
        try std.fmt.allocPrint(allocator, "{s} - {s}", .{ base_label, port_label })
    else
        try allocator.dupe(u8, base_label);
    errdefer allocator.free(label);

    const subtitle = try bluetoothDestinationModeLabel(
        allocator,
        profile.name,
        if (isProfileActive(card, profile.name) and active_sink != null) active_sink.?.bluez5_codec else null,
    );
    errdefer allocator.free(subtitle);

    const destination_id = try std.fmt.allocPrint(allocator, "pulse-card-{d}-{s}", .{ card.index, sanitizeId(profile.name) });
    errdefer allocator.free(destination_id);

    try out.append(allocator, .{
        .id = destination_id,
        .label = label,
        .subtitle = subtitle,
        .kind = .physical,
        .pulse_sink_index = if (isProfileActive(card, profile.name) and active_sink != null) active_sink.?.index else null,
        .pulse_sink_name = try allocator.dupe(u8, if (isProfileActive(card, profile.name) and active_sink != null) (active_sink.?.name orelse "") else ""),
        .pulse_card_index = card.index,
        .pulse_card_profile = try allocator.dupe(u8, profile.name),
    });
}

fn isProfileActive(card: pulse.PulseCard, profile_name: []const u8) bool {
    return card.active_profile != null and std.mem.eql(u8, card.active_profile.?, profile_name);
}

fn findPulseCard(cards: []const pulse.PulseCard, index: u32) ?pulse.PulseCard {
    for (cards) |card| {
        if (card.index == index) return card;
    }
    return null;
}

fn destinationSubtitleWithPulse(
    allocator: std.mem.Allocator,
    obj: pw.types.GlobalObject,
    sink: ?pulse.PulseSink,
) ![]u8 {
    if (sink) |value| {
        if (value.bluez5_profile != null) {
            return bluetoothDestinationModeLabel(allocator, value.bluez5_profile.?, value.bluez5_codec);
        }
    }
    return destinationSubtitle(allocator, obj);
}

fn destinationLabel(
    allocator: std.mem.Allocator,
    base_label: []const u8,
    sink: ?pulse.PulseSink,
) ![]u8 {
    if (sink) |value| {
        if (value.bluez5_profile != null) {
            const port_label = value.active_port_description orelse bluetoothPortLabel(value.bluez5_profile.?);
            if (port_label.len > 0) {
                return std.fmt.allocPrint(allocator, "{s} - {s}", .{ base_label, port_label });
            }
        }
    }
    return allocator.dupe(u8, base_label);
}

fn bluetoothDestinationModeLabel(
    allocator: std.mem.Allocator,
    profile: []const u8,
    codec: ?[]const u8,
) ![]u8 {
    const mode = if (std.mem.startsWith(u8, profile, "a2dp-sink"))
        "Bluetooth Headphones"
    else if (std.mem.startsWith(u8, profile, "headset-head-unit"))
        "Bluetooth Headset"
    else
        "Bluetooth Audio";

    if (codec) |codec_value| {
        if (codec_value.len > 0) {
            const codec_upper = try allocator.dupe(u8, codec_value);
            defer allocator.free(codec_upper);
            for (codec_upper) |*char| char.* = std.ascii.toUpper(char.*);
            return std.fmt.allocPrint(allocator, "{s} ({s})", .{ mode, codec_upper });
        }
    }
    return allocator.dupe(u8, mode);
}

fn bluetoothPortLabel(profile: []const u8) []const u8 {
    if (std.mem.startsWith(u8, profile, "a2dp-sink")) return "Headphones";
    if (std.mem.startsWith(u8, profile, "headset-head-unit")) return "Headset";
    return "";
}

fn destinationKindForRegistryNode(obj: pw.types.GlobalObject) destinations_mod.DestinationKind {
    if (obj.props.node_name) |node_name| {
        if (std.mem.indexOf(u8, node_name, "monitor") != null or std.mem.indexOf(u8, node_name, "null") != null) {
            return .virtual;
        }
    }
    if (obj.props.node_description) |description| {
        if (std.mem.indexOf(u8, description, "Monitor") != null or std.mem.indexOf(u8, description, "Virtual") != null) {
            return .virtual;
        }
    }
    return .physical;
}

fn isSourceMediaClass(media_class: []const u8) bool {
    return std.mem.eql(u8, media_class, "Audio/Source") or
        std.mem.eql(u8, media_class, "Audio/Duplex");
}

fn sourceKindForRegistryNode(obj: pw.types.GlobalObject) sources_mod.SourceKind {
    if (obj.props.node_name) |node_name| {
        if (std.mem.indexOf(u8, node_name, "monitor") != null or std.mem.indexOf(u8, node_name, "null") != null) {
            return .virtual;
        }
    }
    if (obj.props.node_description) |description| {
        if (std.mem.indexOf(u8, description, "Monitor") != null or std.mem.indexOf(u8, description, "Virtual") != null) {
            return .virtual;
        }
    }
    return .physical;
}

fn sourceIconForRegistryNode(obj: pw.types.GlobalObject) []const u8 {
    if (obj.props.app_icon_name) |icon_name| return icon_name;
    return switch (sourceKindForRegistryNode(obj)) {
        .physical => "audio-input-microphone",
        .virtual => "audio-card",
        .app => "audio-source",
    };
}
