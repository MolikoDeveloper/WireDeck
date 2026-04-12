const std = @import("std");
const StateStore = @import("state_store.zig").StateStore;
const AudioCore = @import("../core/audio/routing.zig").AudioCore;
const AudioEngine = @import("../core/audio/engine.zig").AudioEngine;
const NetworkAudioService = @import("../core/audio/network_ingress.zig").NetworkAudioService;
const ObsOutputService = @import("../core/audio/obs_output_service.zig").ObsOutputService;
const channels_mod = @import("../core/audio/channels.zig");
const sources_mod = @import("../core/audio/sources.zig");
const destinations_mod = @import("../core/audio/destinations.zig");
const pw = @import("../core/pipewire.zig");
const live_profiler_mod = @import("../core/pipewire/live_profiler.zig");
const pulse = @import("../core/pulse.zig");
const binder = @import("../core/binder.zig");
const icon = @import("../core/icon_resolver.zig");
const output_exposure_mod = @import("../core/output_exposure.zig");
const OutputExposureManager = output_exposure_mod.OutputExposureManager;
const channel_fx_filters_mod = @import("../core/pipewire/channel_fx_filters.zig");
const ChannelFxFilterManager = channel_fx_filters_mod.ChannelFxFilterManager;
const FxRouteSpec = channel_fx_filters_mod.RouteSpec;
const FxInputPortKind = channel_fx_filters_mod.InputPortKind;
const virtual_inputs = @import("../core/pipewire/virtual_inputs.zig");
const VirtualInputManager = virtual_inputs.VirtualInputManager;
const plugin_host = @import("../plugins/host.zig");
const plugin_chain = @import("../plugins/chain.zig");
const Lv2Support = @import("../plugins/lv2.zig").Lv2Support;
const FxRuntime = @import("../plugins/fx_runtime.zig").FxRuntime;

const parking_sink_name = "wiredeck_parking_sink";
const parking_sink_label = "WireDeck Parking";
const enable_routing_info_logs = false;
const enable_shutdown_info_logs = false;
const enable_shutdown_stage_logs = false;
const live_audio_worker_warn_threshold_ns: i128 = 12 * std.time.ns_per_ms;
const live_audio_warn_log_interval_ns: i128 = 1000 * std.time.ns_per_ms;

pub const App = struct {
    const inventory_refresh_interval_ns = 1500 * std.time.ns_per_ms;
    const routing_poll_interval_ns = 20 * std.time.ns_per_ms;
    const live_audio_poll_interval_ns = 50 * std.time.ns_per_ms;
    const app_resume_grace_ns = 2500 * std.time.ns_per_ms;
    const pulse_startup_retry_attempts = 6;
    const pulse_startup_retry_delay_ns = 150 * std.time.ns_per_ms;
    const worker_allocator = std.heap.c_allocator;

    const InventoryRefresh = struct {
        sources: []sources_mod.Source,
        destinations: []destinations_mod.Destination,
        meter_specs: []pulse.MeterSpec,
        parking_sink_volume: f32 = 1.0,
        parking_sink_muted: bool = false,

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
        original_muted: bool,
        original_channels: u8,
        original_volume: f32,
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

    const RecentAppFxBinding = struct {
        channel_id: []u8,
        source_id: []u8,
        target_name: []u8,
        target_node_id: ?u32,
        port_kind: FxInputPortKind,
        last_live_ns: i128,
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
    last_live_audio_worker_warn_ns: i128,
    live_audio_thread: ?std.Thread,
    live_audio_mutex: std.Thread.Mutex,
    pending_live_discovery: ?*live_profiler_mod.Discovery,
    live_audio_stop: std.atomic.Value(bool),
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
    blocked_sink_inputs: std.ArrayList(u32),
    blocked_source_outputs: std.ArrayList(u32),
    routed_combine_modules: std.ArrayList(RoutedCombineModule),
    routed_loopback_modules: std.ArrayList(RoutedLoopbackModule),
    routed_fx_output_loopbacks: std.ArrayList(RoutedFxOutputLoopbackModule),
    recent_app_fx_bindings: std.ArrayList(RecentAppFxBinding),
    audio_engine: AudioEngine,
    network_audio: NetworkAudioService,
    obs_output_service: ObsOutputService,
    output_exposure: OutputExposureManager,
    fx_virtual_inputs: VirtualInputManager,
    fx_processed_inputs: VirtualInputManager,
    fx_filters: ChannelFxFilterManager,
    lv2_support: Lv2Support,
    fx_runtime: FxRuntime,
    last_fx_runtime_signature: u64,
    parking_sink_module_index: ?u32,
    parking_sink_name_owned: ?[]u8,
    original_default_sink_name: ?[]u8,

    pub fn init(allocator: std.mem.Allocator, state_store: *StateStore) App {
        return .{
            .allocator = allocator,
            .state_store = state_store,
            .pipewire_live = pw.PipeWireLiveProfiler.init(allocator),
            .pulse_peak = pulse.PeakMonitor.init(allocator),
            .last_live_generation = 0,
            .last_live_audio_worker_warn_ns = 0,
            .live_audio_thread = null,
            .live_audio_mutex = .{},
            .pending_live_discovery = null,
            .live_audio_stop = std.atomic.Value(bool).init(false),
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
            .blocked_sink_inputs = .empty,
            .blocked_source_outputs = .empty,
            .routed_combine_modules = .empty,
            .routed_loopback_modules = .empty,
            .routed_fx_output_loopbacks = .empty,
            .recent_app_fx_bindings = .empty,
            .audio_engine = AudioEngine.init(allocator),
            .network_audio = NetworkAudioService.init(allocator),
            .obs_output_service = ObsOutputService.init(allocator),
            .output_exposure = OutputExposureManager.init(allocator),
            .fx_virtual_inputs = VirtualInputManager.init(allocator),
            .fx_processed_inputs = VirtualInputManager.initFxStage(allocator),
            .fx_filters = ChannelFxFilterManager.init(allocator),
            .lv2_support = Lv2Support.init(allocator),
            .fx_runtime = FxRuntime.init(allocator),
            .last_fx_runtime_signature = 0,
            .parking_sink_module_index = null,
            .parking_sink_name_owned = null,
            .original_default_sink_name = null,
        };
    }

    pub fn deinit(self: *App) void {
        if (enable_shutdown_info_logs) std.log.info("shutdown: stop routing worker", .{});
        self.stopRoutingWorker();
        if (enable_shutdown_info_logs) std.log.info("shutdown: clear pending routing", .{});
        self.clearPendingRouting();
        if (enable_shutdown_info_logs) std.log.info("shutdown: stop live audio worker", .{});
        self.stopLiveAudioWorker();
        if (enable_shutdown_info_logs) std.log.info("shutdown: clear pending live audio", .{});
        self.clearPendingLiveDiscovery();
        if (enable_shutdown_info_logs) std.log.info("shutdown: stop refresh worker", .{});
        self.stopRefreshWorker();
        if (enable_shutdown_info_logs) std.log.info("shutdown: clear pending refresh", .{});
        self.clearPendingRefresh();
        if (enable_shutdown_info_logs) std.log.info("shutdown: deinit fx filters", .{});
        self.fx_filters.deinit();
        if (enable_shutdown_info_logs) std.log.info("shutdown: deinit output exposure", .{});
        self.output_exposure.deinit();
        if (enable_shutdown_info_logs) std.log.info("shutdown: deinit obs output service", .{});
        self.obs_output_service.deinit();
        if (enable_shutdown_info_logs) std.log.info("shutdown: deinit fx processed inputs", .{});
        self.fx_processed_inputs.deinit();
        if (enable_shutdown_info_logs) std.log.info("shutdown: deinit fx virtual inputs", .{});
        self.fx_virtual_inputs.deinit();
        if (enable_shutdown_info_logs) std.log.info("shutdown: restore output routing", .{});
        self.restoreOutputRouting() catch {};
        output_exposure_mod.cleanupManagedVirtualMicState(self.allocator) catch |err| {
            std.log.warn("shutdown virtual mic cleanup failed: {s}", .{@errorName(err)});
        };
        for (self.routed_sink_inputs.items) |item| {
            self.allocator.free(item.channel_id);
        }
        self.routed_sink_inputs.deinit(self.allocator);
        self.routed_source_outputs.deinit(self.allocator);
        self.blocked_sink_inputs.deinit(self.allocator);
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
        for (self.recent_app_fx_bindings.items) |binding| {
            self.allocator.free(binding.channel_id);
            self.allocator.free(binding.source_id);
            self.allocator.free(binding.target_name);
        }
        self.recent_app_fx_bindings.deinit(self.allocator);
        if (enable_shutdown_stage_logs) std.log.info("shutdown stage: deinit audio engine", .{});
        self.audio_engine.deinit();
        if (enable_shutdown_stage_logs) std.log.info("shutdown stage: deinit network audio", .{});
        self.network_audio.deinit();
        if (enable_shutdown_stage_logs) std.log.info("shutdown stage: deinit fx runtime", .{});
        self.fx_runtime.deinit();
        if (enable_shutdown_stage_logs) std.log.info("shutdown stage: deinit pulse peak", .{});
        self.pulse_peak.deinit();
        if (enable_shutdown_stage_logs) std.log.info("shutdown stage: deinit pipewire live profiler", .{});
        self.pipewire_live.deinit();
        if (self.parking_sink_name_owned) |value| self.allocator.free(value);
        if (self.original_default_sink_name) |value| self.allocator.free(value);
        if (enable_shutdown_stage_logs) std.log.info("shutdown stage: app deinit complete", .{});
    }

    pub fn prepareBootstrapState(self: *App) !void {
        try self.seedDefaultRouting();
        try self.seedPluginCatalog();
        self.audio_engine.start() catch |err| {
            std.log.warn("audio engine render worker unavailable: {s}", .{@errorName(err)});
        };
        self.network_audio.attachEngine(&self.audio_engine);
        self.obs_output_service.attachEngine(&self.audio_engine);
        self.output_exposure.attachEngine(&self.audio_engine);
        self.network_audio.configure(self.state_store.network_audio);
        try self.obs_output_service.syncOutputs(self.state_store);
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
        self.startLiveAudioWorker() catch |err| {
            std.log.warn("live audio worker unavailable: {s}", .{@errorName(err)});
        };
        self.startRefreshWorker() catch |err| {
            std.log.warn("audio inventory worker unavailable: {s}", .{@errorName(err)});
        };
        self.networkAudioBootstrap() catch |err| {
            std.log.warn("network audio bootstrap unavailable: {s}", .{@errorName(err)});
        };
        self.output_exposure.start() catch |err| {
            std.log.warn("output exposure server unavailable: {s}", .{@errorName(err)});
        };
        self.obs_output_service.start() catch |err| {
            std.log.warn("obs output service unavailable: {s}", .{@errorName(err)});
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

    fn networkAudioBootstrap(self: *App) !void {
        self.network_audio.configure(self.state_store.network_audio);

        try self.network_audio.registerPlannedSession(.{
            .channel_id = "mic",
            .client_name = "macos-template",
            .stream_name = "Mac Desktop",
            .platform = .macos,
        });
        try self.network_audio.registerPlannedSession(.{
            .channel_id = "game",
            .client_name = "windows-template",
            .stream_name = "Windows Desktop",
            .platform = .windows,
        });
        try self.network_audio.registerPlannedSession(.{
            .channel_id = "chat",
            .client_name = "linux-template",
            .stream_name = "Linux Desktop",
            .platform = .linux,
        });

        self.network_audio.start();
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

        const pulse_snapshot = try pulsectx.snapshot(self.allocator);
        defer pulse.freeSnapshot(self.allocator, pulse_snapshot);
        const current_default_sink_name = try pulsectx.defaultSinkName(self.allocator);
        defer if (current_default_sink_name) |value| self.allocator.free(value);
        if (current_default_sink_name) |value| {
            if (isWiredeckManagedSinkName(value) or findPulseSinkIndexByName(pulse_snapshot, value) == null) {
                if (findFirstNonManagedSinkName(self.allocator, pulse_snapshot)) |fallback_sink_name| {
                    defer self.allocator.free(fallback_sink_name);
                    pulsectx.setDefaultSinkName(fallback_sink_name) catch {};
                    std.log.info("startup cleanup restored default sink to {s}", .{fallback_sink_name});
                }
            }
        }
    }

    pub fn normalizeConfiguredBindingsToDefault(self: *App) !void {
        const pulsectx = try initPulseContextWithRetry(self.allocator);
        defer pulsectx.deinit();

        try self.ensureParkingSinkAvailable(pulsectx);
        const previous_default_sink_name = try pulsectx.defaultSinkName(self.allocator) orelse return;
        defer self.allocator.free(previous_default_sink_name);
        if (!std.mem.eql(u8, previous_default_sink_name, parking_sink_name)) {
            try pulsectx.setDefaultSinkName(parking_sink_name);
            std.log.info("startup normalization parking default sink: {s}", .{parking_sink_name});
        }
        const active_default_sink_name = try pulsectx.defaultSinkName(self.allocator) orelse return;
        defer self.allocator.free(active_default_sink_name);
        std.log.info("startup normalization default sink: {s}", .{active_default_sink_name});
        std.log.info("startup normalization keeps parking as the default sink before routing so app playback is captured without duplicate output", .{});
    }

    pub fn pumpLiveAudio(self: *App) !void {
        const fx_runtime_signature = computeFxRuntimeSignature(
            self.state_store.plugin_descriptors.items,
            self.state_store.channel_plugins.items,
            self.state_store.channel_plugin_params.items,
        );
        if (fx_runtime_signature != self.last_fx_runtime_signature) {
            self.fx_runtime.sync(
                self.state_store.plugin_descriptors.items,
                self.state_store.channel_plugins.items,
                self.state_store.channel_plugin_params.items,
            ) catch |err| {
                std.log.warn("fx runtime sync failed: {s}", .{@errorName(err)});
            };
            self.last_fx_runtime_signature = fx_runtime_signature;
        }

        self.live_audio_mutex.lock();
        const pending_discovery = self.pending_live_discovery;
        self.pending_live_discovery = null;
        self.live_audio_mutex.unlock();

        if (pending_discovery) |discovery_ptr| {
            defer {
                var discovery = discovery_ptr.*;
                discovery.deinit(worker_allocator);
                worker_allocator.destroy(discovery_ptr);
            }

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

            for (discovery_ptr.channels.items) |discovered_source| {
                if (try findMappedStateSourceIndex(self.allocator, self.state_store.sources.items, discovered_source)) |index| {
                    self.state_store.sources.items[index].level_left = discovered_source.level_left;
                    self.state_store.sources.items[index].level_right = discovered_source.level_right;
                    self.state_store.sources.items[index].level = discovered_source.level;
                    self.state_store.sources.items[index].muted = discovered_source.muted;
                }
            }
            for (discovery_ptr.destinations.items) |discovered_destination| {
                if (findMappedStateDestinationIndex(self.state_store.destinations.items, discovered_destination)) |index| {
                    self.state_store.destinations.items[index].level_left = discovered_destination.level_left;
                    self.state_store.destinations.items[index].level_right = discovered_destination.level_right;
                    self.state_store.destinations.items[index].level = discovered_destination.level;
                }
            }
        }

        self.network_audio.applyToSources(self.state_store.sources.items);
        self.pulse_peak.applyToSources(self.state_store.sources.items);
        for (self.state_store.channels.items) |*channel| {
            const bound_source_id = channel.bound_source_id orelse continue;
            const source = findStateSource(self.state_store.sources.items, bound_source_id) orelse continue;
            channel.level_left = source.level_left;
            channel.level_right = source.level_right;
            channel.level = source.level;
        }
        self.pulse_peak.applyToChannels(self.state_store.channels.items);
        for (self.state_store.channels.items) |*channel| {
            switch (channel.meter_stage) {
                .input => {},
                .post_fx, .post_fader => {
                    const levels = self.audio_engine.channelLevels(channel.id, channel.meter_stage) orelse continue;
                    channel.level_left = levels.left;
                    channel.level_right = levels.right;
                    channel.level = levels.level;
                },
            }
        }
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

    fn startLiveAudioWorker(self: *App) !void {
        if (self.live_audio_thread != null) return;
        self.live_audio_stop.store(false, .release);
        self.live_audio_thread = try std.Thread.spawn(.{}, liveAudioWorkerMain, .{self});
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

    fn stopLiveAudioWorker(self: *App) void {
        self.live_audio_stop.store(true, .release);
        if (self.live_audio_thread) |thread| {
            thread.join();
            self.live_audio_thread = null;
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

    fn clearPendingLiveDiscovery(self: *App) void {
        self.live_audio_mutex.lock();
        defer self.live_audio_mutex.unlock();
        if (self.pending_live_discovery) |pending| {
            var discovery = pending.*;
            discovery.deinit(worker_allocator);
            worker_allocator.destroy(pending);
            self.pending_live_discovery = null;
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

    fn pruneRecentAppFxBindings(self: *App, now_ns: i128) void {
        var index: usize = 0;
        while (index < self.recent_app_fx_bindings.items.len) {
            const binding = self.recent_app_fx_bindings.items[index];
            if (now_ns - binding.last_live_ns <= app_resume_grace_ns) {
                index += 1;
                continue;
            }
            self.allocator.free(binding.channel_id);
            self.allocator.free(binding.source_id);
            self.allocator.free(binding.target_name);
            _ = self.recent_app_fx_bindings.orderedRemove(index);
        }
    }

    fn findRecentAppFxBindingIndex(self: *const App, channel_id: []const u8) ?usize {
        for (self.recent_app_fx_bindings.items, 0..) |binding, index| {
            if (std.mem.eql(u8, binding.channel_id, channel_id)) return index;
        }
        return null;
    }

    fn rememberRecentAppFxBinding(self: *App, channel_id: []const u8, source_id: []const u8, binding: FxInputBinding) !void {
        const target_name = binding.target_name orelse return;
        const now_ns = std.time.nanoTimestamp();
        self.pruneRecentAppFxBindings(now_ns);

        if (self.findRecentAppFxBindingIndex(channel_id)) |index| {
            var existing = &self.recent_app_fx_bindings.items[index];
            if (!std.mem.eql(u8, existing.source_id, source_id)) {
                self.allocator.free(existing.source_id);
                existing.source_id = try self.allocator.dupe(u8, source_id);
            }
            self.allocator.free(existing.target_name);
            existing.target_name = try self.allocator.dupe(u8, target_name);
            existing.target_node_id = binding.target_node_id;
            existing.port_kind = binding.port_kind;
            existing.last_live_ns = now_ns;
            return;
        }

        try self.recent_app_fx_bindings.append(self.allocator, .{
            .channel_id = try self.allocator.dupe(u8, channel_id),
            .source_id = try self.allocator.dupe(u8, source_id),
            .target_name = try self.allocator.dupe(u8, target_name),
            .target_node_id = binding.target_node_id,
            .port_kind = binding.port_kind,
            .last_live_ns = now_ns,
        });
    }

    fn recentAppFxBinding(self: *App, channel_id: []const u8, source_id: []const u8) ?RecentAppFxBinding {
        const index = self.findRecentAppFxBindingIndex(channel_id) orelse return null;
        const now_ns = std.time.nanoTimestamp();
        const binding = self.recent_app_fx_bindings.items[index];
        if (now_ns - binding.last_live_ns > app_resume_grace_ns or !std.mem.eql(u8, binding.source_id, source_id)) {
            self.allocator.free(binding.channel_id);
            self.allocator.free(binding.source_id);
            self.allocator.free(binding.target_name);
            _ = self.recent_app_fx_bindings.orderedRemove(index);
            return null;
        }
        return self.recent_app_fx_bindings.items[index];
    }

    fn hasRecentAppFxBindingForChannel(self: *App, state_store: *const StateStore, channel_id: []const u8) bool {
        const channel = findStateChannel(state_store, channel_id) orelse return false;
        const source_id = channel.bound_source_id orelse return false;
        const source = findStateSource(state_store.sources.items, source_id) orelse return false;
        if (source.kind != .app) return false;
        return self.recentAppFxBinding(channel_id, source.id) != null;
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
        snapshot_store.network_audio = self.state_store.network_audio;
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
        self.pruneRecentAppFxBindings(std.time.nanoTimestamp());
        self.network_audio.configure(state_store.network_audio);
        try self.audio_engine.syncGraph(
            state_store.channels.items,
            state_store.buses.items,
            state_store.sends.items,
        );
        try self.obs_output_service.syncOutputs(state_store);

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

        var fx_channels = std.ArrayList(channels_mod.Channel).empty;
        defer fx_channels.deinit(self.allocator);
        try collectActiveFxChannels(self.allocator, self, state_store, refreshed_pulse_snapshot, &fx_channels);

        var fx_route_specs = std.ArrayList(FxRouteSpec).empty;
        defer deinitFxRouteSpecs(self.allocator, &fx_route_specs);
        try self.buildFxRouteSpecs(&fx_route_specs, state_store, refreshed_pulse_snapshot, &pipewire.registry_state, owners, fx_channels.items);

        var fx_capture_channels = std.ArrayList(channels_mod.Channel).empty;
        defer fx_capture_channels.deinit(self.allocator);
        try collectVirtualCaptureFxChannels(self.allocator, state_store, owners, fx_channels.items, fx_route_specs.items, &fx_capture_channels);

        try self.fx_virtual_inputs.sync(fx_capture_channels.items);
        try self.fx_processed_inputs.sync(&.{});
        try self.fx_filters.sync(
            &self.audio_engine,
            &self.fx_runtime,
            state_store.channels.items,
            fx_route_specs.items,
        );

        const routing_pulse_snapshot = try pulsectx.snapshot(self.allocator);
        defer pulse.freeSnapshot(self.allocator, routing_pulse_snapshot);

        var desired = std.ArrayList(DesiredSinkMove).empty;
        defer desired.deinit(self.allocator);
        try self.collectDesiredSinkMoves(state_store, &desired, &pipewire.registry_state, owners, routing_pulse_snapshot, pulsectx, fx_channels.items, fx_route_specs.items);

        for (desired.items) |move| {
            const sink_input = findPulseSinkInput(routing_pulse_snapshot.sink_inputs, move.sink_input_index) orelse continue;
            const original_sink_index = sink_input.sink_index orelse continue;
            if (!hasRecordedOriginal(self.routed_sink_inputs.items, move.sink_input_index)) {
                try self.routed_sink_inputs.append(self.allocator, .{
                    .channel_id = try self.allocator.dupe(u8, move.channel_id),
                    .sink_input_index = move.sink_input_index,
                    .original_sink_index = original_sink_index,
                    .original_muted = sink_input.muted,
                    .original_channels = sink_input.channels,
                    .original_volume = sink_input.volume,
                });
            }

            if (move.target_sink_index) |target_sink_index| {
                const keep_routed = self.moveSinkInputWithRecheck(pulsectx, move.sink_input_index, target_sink_index) catch |err| switch (err) {
                    error.PulseMoveSinkInputFailed, error.PulseOperationTimedOut => {
                        if (!move.block_on_failure) return err;

                        if (!containsBlockedSinkInput(self.blocked_sink_inputs.items, move.sink_input_index)) {
                            try self.blocked_sink_inputs.append(self.allocator, move.sink_input_index);
                            std.log.warn("routing app stream {d}: legacy capture move blocked for channel={s}; keeping original sink", .{
                                move.sink_input_index,
                                move.channel_id,
                            });
                        }

                        if (findRecordedRoutedSinkInput(self.routed_sink_inputs.items, move.sink_input_index)) |recorded| {
                            pulsectx.moveSinkInputToSink(move.sink_input_index, recorded.original_sink_index) catch {};
                            pulsectx.setSinkInputMuteByIndex(move.sink_input_index, recorded.original_muted) catch {};
                            pulsectx.setSinkInputVolumeByIndex(move.sink_input_index, recorded.original_channels, recorded.original_volume) catch {};
                        } else {
                            pulsectx.setSinkInputMuteByIndex(move.sink_input_index, false) catch {};
                            pulsectx.setSinkInputVolumeByIndex(move.sink_input_index, sink_input.channels, 1.0) catch {};
                        }
                        continue;
                    },
                    else => return err,
                };
                if (!keep_routed) continue;
                removeBlockedSinkInput(&self.blocked_sink_inputs, move.sink_input_index);
                std.log.info("routing app stream {d}: channel={s} target_sink_index={d}", .{
                    move.sink_input_index,
                    move.channel_id,
                    target_sink_index,
                });
            }

            if (sink_input.muted != move.muted) {
                pulsectx.setSinkInputMuteByIndex(move.sink_input_index, move.muted) catch |err| switch (err) {
                    error.PulseSetSinkInputMuteFailed, error.PulseOperationTimedOut => continue,
                    else => return err,
                };
                std.log.info("routing app stream {d}: channel={s} muted={any}", .{
                    move.sink_input_index,
                    move.channel_id,
                    move.muted,
                });
            }

            if (move.volume) |target_volume| {
                if (!approxEqVolume(sink_input.volume, target_volume)) {
                    pulsectx.setSinkInputVolumeByIndex(move.sink_input_index, sink_input.channels, target_volume) catch |err| switch (err) {
                        error.PulseSetSinkInputVolumeFailed, error.PulseOperationTimedOut => continue,
                        else => return err,
                    };
                    std.log.info("routing app stream {d}: channel={s} volume={d:.3}", .{
                        move.sink_input_index,
                        move.channel_id,
                        target_volume,
                    });
                }
            }
        }

        try self.reconcileVirtualMicCaptureRouting(state_store, owners, routing_pulse_snapshot, pulsectx);

        var index: usize = 0;
        while (index < self.routed_sink_inputs.items.len) {
            const routed = self.routed_sink_inputs.items[index];
            if (containsDesiredMove(desired.items, routed.sink_input_index)) {
                index += 1;
                continue;
            }
            const sink_input = findPulseSinkInput(routing_pulse_snapshot.sink_inputs, routed.sink_input_index) orelse {
                removeBlockedSinkInput(&self.blocked_sink_inputs, routed.sink_input_index);
                self.allocator.free(routed.channel_id);
                _ = self.routed_sink_inputs.orderedRemove(index);
                continue;
            };
            const uses_fx = containsChannel(fx_channels.items, routed.channel_id);
            const channel_still_has_target = shouldHoldNetworkCaptureRoute(
                self,
                state_store,
                routed.channel_id,
                routing_pulse_snapshot,
                pulsectx,
                sink_input,
                uses_fx,
            ) or self.hasRecentAppFxBindingForChannel(state_store, routed.channel_id) or
                (try self.resolveTargetSinkForChannel(state_store, routed.channel_id, routing_pulse_snapshot, pulsectx)) != null;
            if (channel_still_has_target) {
                index += 1;
                continue;
            }
            pulsectx.moveSinkInputToSink(routed.sink_input_index, routed.original_sink_index) catch {};
            pulsectx.setSinkInputMuteByIndex(routed.sink_input_index, routed.original_muted) catch {};
            pulsectx.setSinkInputVolumeByIndex(routed.sink_input_index, routed.original_channels, routed.original_volume) catch {};
            std.log.info("routing app stream {d}: restored original sink={d} muted={any}", .{
                routed.sink_input_index,
                routed.original_sink_index,
                routed.original_muted,
            });
            self.allocator.free(routed.channel_id);
            _ = self.routed_sink_inputs.orderedRemove(index);
        }

        try self.reconcilePhysicalSourceLoopbacks(state_store, routing_pulse_snapshot, pulsectx, fx_channels.items);
        try self.reconcileFxOutputLoopbacks(state_store, routing_pulse_snapshot, pulsectx, &.{});
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
        std.log.info("shutdown restore: init pulse context", .{});
        const pulsectx = try initPulseContextWithRetry(self.allocator);
        defer pulsectx.deinit();
        std.log.info("shutdown restore: pulse context ready", .{});

        std.log.info("shutdown restore: restore sink inputs={d}", .{self.routed_sink_inputs.items.len});
        for (self.routed_sink_inputs.items) |routed| {
            pulsectx.moveSinkInputToSink(routed.sink_input_index, routed.original_sink_index) catch {};
            pulsectx.setSinkInputMuteByIndex(routed.sink_input_index, routed.original_muted) catch {};
            pulsectx.setSinkInputVolumeByIndex(routed.sink_input_index, routed.original_channels, routed.original_volume) catch {};
            self.allocator.free(routed.channel_id);
        }
        self.routed_sink_inputs.clearRetainingCapacity();
        self.blocked_sink_inputs.clearRetainingCapacity();

        std.log.info("shutdown restore: restore source outputs={d}", .{self.routed_source_outputs.items.len});
        for (self.routed_source_outputs.items) |routed| {
            pulsectx.moveSourceOutputToSource(routed.source_output_index, routed.original_source_index) catch {};
        }
        self.routed_source_outputs.clearRetainingCapacity();

        std.log.info("shutdown restore: unload combine modules={d}", .{self.routed_combine_modules.items.len});
        for (self.routed_combine_modules.items) |module| {
            pulsectx.unloadModule(module.module_index) catch {};
            self.allocator.free(module.channel_id);
            self.allocator.free(module.sink_name);
            self.allocator.free(module.sink_key);
        }
        self.routed_combine_modules.clearRetainingCapacity();

        std.log.info("shutdown restore: unload loopback modules={d}", .{self.routed_loopback_modules.items.len});
        for (self.routed_loopback_modules.items) |module| {
            pulsectx.unloadModule(module.module_index) catch {};
            self.allocator.free(module.channel_id);
            self.allocator.free(module.source_name);
            self.allocator.free(module.sink_name);
        }
        self.routed_loopback_modules.clearRetainingCapacity();

        std.log.info("shutdown restore: unload fx output loopbacks={d}", .{self.routed_fx_output_loopbacks.items.len});
        for (self.routed_fx_output_loopbacks.items) |module| {
            pulsectx.unloadModule(module.module_index) catch {};
            self.allocator.free(module.channel_id);
            self.allocator.free(module.source_name);
            self.allocator.free(module.sink_name);
        }
        self.routed_fx_output_loopbacks.clearRetainingCapacity();
        if (self.original_default_sink_name) |value| {
            pulsectx.setDefaultSinkName(value) catch {};
            std.log.info("shutdown restore: restored default sink={s}", .{value});
            self.allocator.free(value);
            self.original_default_sink_name = null;
        }
        if (self.parking_sink_module_index) |module_index| {
            pulsectx.unloadModule(module_index) catch {};
            self.parking_sink_module_index = null;
        }
        if (self.parking_sink_name_owned) |value| {
            self.allocator.free(value);
            self.parking_sink_name_owned = null;
        }
        std.log.info("shutdown restore: complete", .{});
    }

    fn ensureParkingSinkAvailable(self: *App, pulsectx: *pulse.PulseContext) !void {
        const pulse_snapshot = try pulsectx.snapshot(self.allocator);
        defer pulse.freeSnapshot(self.allocator, pulse_snapshot);

        if (self.original_default_sink_name == null) {
            const current_default_sink_name = try pulsectx.defaultSinkName(self.allocator);
            defer if (current_default_sink_name) |value| self.allocator.free(value);
            var fallback_default_sink_name: ?[]u8 = null;
            defer if (fallback_default_sink_name) |value| self.allocator.free(value);
            const preferred_default = blk: {
                if (current_default_sink_name) |value| {
                    if (!isWiredeckManagedSinkName(value) and findPulseSinkIndexByName(pulse_snapshot, value) != null) {
                        break :blk value;
                    }
                }
                fallback_default_sink_name = findFirstNonManagedSinkName(self.allocator, pulse_snapshot) orelse return;
                break :blk fallback_default_sink_name.?;
            };
            self.original_default_sink_name = try self.allocator.dupe(u8, preferred_default);
        }

        if (self.parking_sink_module_index == null) {
            const sink_properties = try std.fmt.allocPrint(
                self.allocator,
                "\"device.description='{s}' node.description='{s}' wiredeck.parking=true node.virtual=true node.hidden=true device.class=abstract media.class=Audio/Sink node.pause-on-idle=false node.always-process=true node.latency=128/48000\"",
                .{ parking_sink_label, parking_sink_label },
            );
            defer self.allocator.free(sink_properties);
            const args = try std.fmt.allocPrint(
                self.allocator,
                "sink_name={s} sink_properties={s} rate=48000",
                .{ parking_sink_name, sink_properties },
            );
            defer self.allocator.free(args);

            self.parking_sink_module_index = try pulsectx.loadModule("module-null-sink", args);
            self.parking_sink_name_owned = try self.allocator.dupe(u8, parking_sink_name);
        }
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
        registry: *const pw.RegistryState,
        owners: []const binder.BoundOwner,
        pulse_snapshot: pulse.PulseSnapshot,
        pulsectx: *pulse.PulseContext,
        fx_channels: []const channels_mod.Channel,
        fx_route_specs: []const FxRouteSpec,
    ) !void {
        _ = registry;
        const parking_sink_gain = currentParkingSinkGain(pulse_snapshot);
        for (state_store.channels.items) |channel| {
            const bound_source_id = channel.bound_source_id orelse continue;
            const source = findStateSource(state_store.sources.items, bound_source_id) orelse continue;
            if (source.kind != .app) continue;
            const uses_fx = containsChannel(fx_channels, channel.id);
            const fx_route_ready = !uses_fx or self.fx_filters.routeReady(channel.id);
            const direct_app_capture = routeSpecUsesDirectAppCapture(fx_route_specs, channel.id);
            for (owners) |owner| {
                if (!try ownerMatchesAppSource(self.allocator, owner, source)) continue;
                for (owner.pulse_sink_input_indexes) |sink_input_index| {
                    const sink_input = findPulseSinkInput(pulse_snapshot.sink_inputs, sink_input_index) orelse continue;
                    const preserved_volume = if (findRecordedRoutedSinkInput(self.routed_sink_inputs.items, sink_input_index)) |recorded|
                        recorded.original_volume
                    else
                        sink_input.volume;
                    if (!containsDesiredMove(out.items, sink_input_index)) {
                        if (!fx_route_ready) {
                            if (shouldHoldNetworkCaptureRoute(self, state_store, channel.id, pulse_snapshot, pulsectx, sink_input, uses_fx)) {
                                removeBlockedSinkInput(&self.blocked_sink_inputs, sink_input_index);
                                if (source.kind == .app and enable_routing_info_logs) {
                                    std.log.info(
                                        "routing app decision: channel={s} sink_input={d} mode=route_not_ready_hold current_sink={d} muted={any} volume={d:.3}",
                                        .{
                                            channel.id,
                                            sink_input_index,
                                            sink_input.sink_index orelse 0,
                                            sink_input.muted,
                                            sink_input.volume,
                                        },
                                    );
                                }
                                continue;
                            }
                            if (source.kind == .app and enable_routing_info_logs) {
                                std.log.info(
                                    "routing app decision: channel={s} sink_input={d} mode=route_not_ready direct_capture={any} current_sink={d} muted={any} volume={d:.3}",
                                    .{
                                        channel.id,
                                        sink_input_index,
                                        direct_app_capture,
                                        sink_input.sink_index orelse 0,
                                        sink_input.muted,
                                        sink_input.volume,
                                    },
                                );
                            }
                            removeBlockedSinkInput(&self.blocked_sink_inputs, sink_input_index);
                            if (findRecordedRoutedSinkInput(self.routed_sink_inputs.items, sink_input_index)) |recorded| {
                                const adjusted = applyParkingSinkGain(recorded.original_volume, recorded.original_muted, parking_sink_gain);
                                const current_sink_index = sink_input.sink_index orelse recorded.original_sink_index;
                                if (current_sink_index != recorded.original_sink_index or
                                    sink_input.muted != adjusted.muted or
                                    !approxEqVolume(sink_input.volume, adjusted.volume))
                                {
                                    try out.append(self.allocator, .{
                                        .channel_id = channel.id,
                                        .sink_input_index = sink_input_index,
                                        .target_sink_index = recorded.original_sink_index,
                                        .muted = adjusted.muted,
                                        .volume = adjusted.volume,
                                        .block_on_failure = false,
                                    });
                                }
                            } else {
                                const adjusted = applyParkingSinkGain(preserved_volume, false, parking_sink_gain);
                                if (sink_input.muted == adjusted.muted and approxEqVolume(sink_input.volume, adjusted.volume)) {
                                    continue;
                                }
                                try out.append(self.allocator, .{
                                    .channel_id = channel.id,
                                    .sink_input_index = sink_input_index,
                                    .target_sink_index = null,
                                    .muted = adjusted.muted,
                                    .volume = adjusted.volume,
                                    .block_on_failure = false,
                                });
                            }
                            continue;
                        }

                        if (direct_app_capture) {
                            removeBlockedSinkInput(&self.blocked_sink_inputs, sink_input_index);
                            var parking_target_sink_index = findPulseSinkIndexByName(pulse_snapshot, parking_sink_name);
                            if (parking_target_sink_index == null) {
                                self.ensureParkingSinkAvailable(pulsectx) catch |err| {
                                    std.log.warn("routing app direct capture parking ensure failed: channel={s} sink_input={d} err={s}", .{
                                        channel.id,
                                        sink_input_index,
                                        @errorName(err),
                                    });
                                };
                                const latest_snapshot = try pulsectx.snapshot(self.allocator);
                                defer pulse.freeSnapshot(self.allocator, latest_snapshot);
                                parking_target_sink_index = findPulseSinkIndexByName(latest_snapshot, parking_sink_name);
                            }
                            if (enable_routing_info_logs) {
                                std.log.info(
                                    "routing app decision: channel={s} sink_input={d} mode=direct_capture_ready parking_sink={d} current_sink={d} muted={any} volume={d:.3}",
                                    .{
                                        channel.id,
                                        sink_input_index,
                                        parking_target_sink_index orelse 0,
                                        sink_input.sink_index orelse 0,
                                        sink_input.muted,
                                        sink_input.volume,
                                    },
                                );
                            }
                            const current_sink_index = sink_input.sink_index orelse 0;
                            const keep_on_parking = blk: {
                                const parking_sink_index = parking_target_sink_index orelse break :blk false;
                                if (current_sink_index == parking_sink_index) break :blk true;
                                if (findRecordedRoutedSinkInput(self.routed_sink_inputs.items, sink_input_index)) |recorded| {
                                    break :blk recorded.original_sink_index == parking_sink_index;
                                }
                                break :blk false;
                            };
                            if (findRecordedRoutedSinkInput(self.routed_sink_inputs.items, sink_input_index)) |recorded| {
                                const adjusted = applyParkingSinkGain(recorded.original_volume, recorded.original_muted, parking_sink_gain);
                                const active_sink_index = sink_input.sink_index orelse recorded.original_sink_index;
                                const desired_sink_index: ?u32 = if (keep_on_parking)
                                    (parking_target_sink_index orelse recorded.original_sink_index)
                                else
                                    null;
                                const desired_volume = if (keep_on_parking)
                                    adjusted.volume
                                else
                                    0.0;
                                const needs_sink_move = if (desired_sink_index) |sink_index|
                                    active_sink_index != sink_index
                                else
                                    false;
                                if (needs_sink_move or
                                    sink_input.muted != adjusted.muted or
                                    !approxEqVolume(sink_input.volume, desired_volume))
                                {
                                    try out.append(self.allocator, .{
                                        .channel_id = channel.id,
                                        .sink_input_index = sink_input_index,
                                        .target_sink_index = desired_sink_index,
                                        .muted = adjusted.muted,
                                        .volume = desired_volume,
                                        .block_on_failure = false,
                                    });
                                }
                            } else {
                                const adjusted = applyParkingSinkGain(preserved_volume, false, parking_sink_gain);
                                const desired_sink_index: ?u32 = if (keep_on_parking) parking_target_sink_index else null;
                                const desired_volume = if (keep_on_parking) adjusted.volume else 0.0;
                                if ((desired_sink_index != null and current_sink_index != desired_sink_index.?) or
                                    sink_input.muted != adjusted.muted or
                                    !approxEqVolume(sink_input.volume, desired_volume))
                                {
                                    try out.append(self.allocator, .{
                                        .channel_id = channel.id,
                                        .sink_input_index = sink_input_index,
                                        .target_sink_index = desired_sink_index,
                                        .muted = adjusted.muted,
                                        .volume = desired_volume,
                                        .block_on_failure = false,
                                    });
                                }
                            }
                            continue;
                        }

                        const target_sink = try resolveCaptureSinkForChannel(self, state_store, channel.id, pulse_snapshot, pulsectx, uses_fx);
                        if (target_sink) |target| {
                            const needs_legacy_capture_move = isVirtualCaptureSinkName(target.sink_name);
                            if (source.kind == .app) {
                                std.log.info(
                                    "routing app decision: channel={s} sink_input={d} mode=resolved_target sink={d} sink_name={s} legacy_capture={any}",
                                    .{
                                        channel.id,
                                        sink_input_index,
                                        target.sink_index,
                                        target.sink_name,
                                        needs_legacy_capture_move,
                                    },
                                );
                            }
                            if (!needs_legacy_capture_move) {
                                removeBlockedSinkInput(&self.blocked_sink_inputs, sink_input_index);
                            } else if (containsBlockedSinkInput(self.blocked_sink_inputs.items, sink_input_index)) {
                                if (findRecordedRoutedSinkInput(self.routed_sink_inputs.items, sink_input_index)) |recorded| {
                                    const adjusted = applyParkingSinkGain(recorded.original_volume, recorded.original_muted, parking_sink_gain);
                                    const current_sink_index = sink_input.sink_index orelse recorded.original_sink_index;
                                    if (current_sink_index != recorded.original_sink_index or
                                        sink_input.muted != adjusted.muted or
                                        !approxEqVolume(sink_input.volume, adjusted.volume))
                                    {
                                        try out.append(self.allocator, .{
                                            .channel_id = channel.id,
                                            .sink_input_index = sink_input_index,
                                            .target_sink_index = recorded.original_sink_index,
                                            .muted = adjusted.muted,
                                            .volume = adjusted.volume,
                                            .block_on_failure = false,
                                        });
                                    }
                                } else {
                                    const adjusted = applyParkingSinkGain(preserved_volume, false, parking_sink_gain);
                                    if (sink_input.muted == adjusted.muted and approxEqVolume(sink_input.volume, adjusted.volume)) {
                                        continue;
                                    }
                                    try out.append(self.allocator, .{
                                        .channel_id = channel.id,
                                        .sink_input_index = sink_input_index,
                                        .target_sink_index = null,
                                        .muted = adjusted.muted,
                                        .volume = adjusted.volume,
                                        .block_on_failure = false,
                                    });
                                }
                                continue;
                            }
                            const current_sink_index = sink_input.sink_index orelse continue;
                            const adjusted = applyParkingSinkGain(preserved_volume, false, parking_sink_gain);
                            const target_volume = adjusted.volume;
                            if (current_sink_index == target.sink_index and sink_input.muted == adjusted.muted and approxEqVolume(sink_input.volume, target_volume)) continue;
                            try out.append(self.allocator, .{
                                .channel_id = channel.id,
                                .sink_input_index = sink_input_index,
                                .target_sink_index = target.sink_index,
                                .muted = adjusted.muted,
                                .volume = target_volume,
                                .block_on_failure = needs_legacy_capture_move,
                            });
                        } else if (findRecordedRoutedSinkInput(self.routed_sink_inputs.items, sink_input_index)) |recorded| {
                            const adjusted = applyParkingSinkGain(recorded.original_volume, recorded.original_muted, parking_sink_gain);
                            const current_sink_index = sink_input.sink_index orelse recorded.original_sink_index;
                            removeBlockedSinkInput(&self.blocked_sink_inputs, sink_input_index);
                            if (current_sink_index == recorded.original_sink_index and
                                sink_input.muted == adjusted.muted and
                                approxEqVolume(sink_input.volume, adjusted.volume))
                            {
                                continue;
                            }
                            try out.append(self.allocator, .{
                                .channel_id = channel.id,
                                .sink_input_index = sink_input_index,
                                .target_sink_index = recorded.original_sink_index,
                                .muted = adjusted.muted,
                                .volume = adjusted.volume,
                                .block_on_failure = false,
                            });
                        } else {
                            removeBlockedSinkInput(&self.blocked_sink_inputs, sink_input_index);
                            continue;
                        }
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
        _ = pulsectx;
        const channel = findStateChannel(state_store, channel_id) orelse return null;
        if (channel.muted) return null;

        var sinks = std.ArrayList(ChannelTargetSink).empty;
        defer sinks.deinit(self.allocator);
        try self.collectResolvedSinksForChannel(state_store, channel_id, pulse_snapshot, &sinks);
        if (sinks.items.len == 0) return null;
        return sinks.items[0];
    }

    fn collectResolvedSinksForChannel(
        self: *const App,
        state_store: *const StateStore,
        channel_id: []const u8,
        pulse_snapshot: pulse.PulseSnapshot,
        out: *std.ArrayList(ChannelTargetSink),
    ) !void {
        const channel = findStateChannel(state_store, channel_id) orelse return;
        if (channel.muted) return;

        for (state_store.sends.items) |send| {
            if (!send.enabled) continue;
            if (!std.mem.eql(u8, send.channel_id, channel_id)) continue;
            try self.appendDestinationsForBus(state_store, out, send.bus_id, pulse_snapshot);
        }
    }

    fn appendDestinationsForBus(self: *const App, state_store: *const StateStore, out: *std.ArrayList(ChannelTargetSink), bus_id: []const u8, pulse_snapshot: pulse.PulseSnapshot) !void {
        const bus_index = findStateBus(state_store, bus_id) orelse return;
        const bus = state_store.buses.items[bus_index];
        for (state_store.bus_destinations.items) |bus_destination| {
            if (!bus_destination.enabled) continue;
            if (!std.mem.eql(u8, bus_destination.bus_id, bus.id)) continue;

            const destination = findStateDestination(state_store.destinations.items, bus_destination.destination_id) orelse continue;
            const target = resolvePulseTargetForDestination(pulse_snapshot, destination) orelse continue;
            if (containsChannelTargetSink(out.items, target.sink_index)) continue;
            try out.append(self.allocator, target);
        }
    }

    fn channelHasNetworkVisibleRoute(state_store: *const StateStore, channel_id: []const u8) bool {
        for (state_store.sends.items) |send| {
            if (!send.enabled) continue;
            if (!std.mem.eql(u8, send.channel_id, channel_id)) continue;
            const bus_index = findStateBus(state_store, send.bus_id) orelse continue;
            const bus = state_store.buses.items[bus_index];
            if (bus.share_on_network or bus.expose_as_microphone) return true;
        }
        return false;
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

    fn cleanupCombineModules(self: *App, pulsectx: *pulse.PulseContext) !void {
        const modules = try pulsectx.listModules(self.allocator);
        defer pulse.freeModules(self.allocator, modules);

        for (modules) |module| {
            const name = module.name orelse continue;
            const argument = module.argument orelse "";
            if (!std.mem.eql(u8, name, "module-combine-sink")) continue;
            if (!containsIgnoreCase(argument, "wiredeck-combine-")) continue;
            pulsectx.unloadModule(module.index) catch {};
            std.log.info("routing cleanup: unloaded stale combine module {d}", .{module.index});
        }
    }

    fn reconcilePhysicalSourceLoopbacks(
        self: *App,
        state_store: *const StateStore,
        pulse_snapshot: pulse.PulseSnapshot,
        pulsectx: *pulse.PulseContext,
        fx_channels: []const channels_mod.Channel,
    ) !void {
        _ = state_store;
        _ = pulse_snapshot;
        _ = fx_channels;

        const index: usize = 0;
        while (index < self.routed_loopback_modules.items.len) {
            const module = self.routed_loopback_modules.items[index];
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
            std.log.info("routing loopback {s}: replacing {s} -> {s}", .{
                channel_id,
                existing.source_name,
                existing.sink_name,
            });
            self.allocator.free(existing.channel_id);
            self.allocator.free(existing.source_name);
            self.allocator.free(existing.sink_name);
            _ = self.routed_loopback_modules.orderedRemove(index);
        }

        if (pulse_source_name == null or sink_name == null) return;

        const args = try std.fmt.allocPrint(
            self.allocator,
            "source={s} sink={s} source_dont_move=true sink_dont_move=true latency_msec=10 adjust_time=0",
            .{ pulse_source_name.?, sink_name.? },
        );
        defer self.allocator.free(args);

        const module_index = try pulsectx.loadModule("module-loopback", args);
        std.log.info("routing loopback {s}: source={s} sink={s} module={d}", .{
            channel_id,
            pulse_source_name.?,
            sink_name.?,
            module_index,
        });
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
        _ = state_store;
        _ = pulse_snapshot;
        _ = fx_channels;

        const index: usize = 0;
        while (index < self.routed_fx_output_loopbacks.items.len) {
            const module = self.routed_fx_output_loopbacks.items[index];
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
            std.log.info("routing fx loopback {s}: replacing {s} -> {s}", .{
                channel_id,
                existing.source_name,
                existing.sink_name,
            });
            self.allocator.free(existing.channel_id);
            self.allocator.free(existing.source_name);
            self.allocator.free(existing.sink_name);
            _ = self.routed_fx_output_loopbacks.orderedRemove(index);
        }

        if (pulse_source_name == null or sink_name == null) return;

        const args = try std.fmt.allocPrint(
            self.allocator,
            "source={s} sink={s} source_dont_move=true sink_dont_move=true latency_msec=10 adjust_time=0",
            .{ pulse_source_name.?, sink_name.? },
        );
        defer self.allocator.free(args);

        const module_index = try pulsectx.loadModule("module-loopback", args);
        std.log.info("routing fx loopback {s}: source={s} sink={s} module={d}", .{
            channel_id,
            pulse_source_name.?,
            sink_name.?,
            module_index,
        });
        try self.routed_fx_output_loopbacks.append(self.allocator, .{
            .channel_id = try self.allocator.dupe(u8, channel_id),
            .module_index = module_index,
            .source_name = try self.allocator.dupe(u8, pulse_source_name.?),
            .sink_name = try self.allocator.dupe(u8, sink_name.?),
        });
    }

    fn buildFxRouteSpecs(
        self: *App,
        out: *std.ArrayList(FxRouteSpec),
        state_store: *const StateStore,
        pulse_snapshot: pulse.PulseSnapshot,
        registry: *const pw.RegistryState,
        owners: []const binder.BoundOwner,
        fx_channels: []const channels_mod.Channel,
    ) !void {
        for (fx_channels) |channel| {
            const input_binding = try resolveFxInputBinding(self, state_store, pulse_snapshot, registry, owners, channel);
            if (!channelShouldCreateFxRoute(self.allocator, state_store, owners, channel, input_binding)) {
                if (input_binding.target_name) |target_name| self.allocator.free(target_name);
                continue;
            }

            try out.append(self.allocator, .{
                .channel_id = channel.id,
                .requires_external_capture = channelRequiresExternalCapture(state_store, channel),
                .input_target_name = input_binding.target_name,
                .input_target_node_id = input_binding.target_node_id,
                .input_port_kind = input_binding.port_kind,
                .output_target_names = &.{},
            });
        }
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
        try self.network_audio.appendSnapshotSources(allocator, &sources);

        var destinations = std.ArrayList(destinations_mod.Destination).empty;
        defer destinations.deinit(allocator);
        try appendDestinationsToList(allocator, &destinations, &pipewire.registry_state, snapshot, cards);

        var meter_specs = std.ArrayList(pulse.MeterSpec).empty;
        defer meter_specs.deinit(allocator);
        for (sources.items) |source| {
            if (source.kind == .app) {
                try appendAppPulseSpecs(allocator, &meter_specs, snapshot, owners, source);
            } else {
                try appendPhysicalPulseSpecs(allocator, &meter_specs, snapshot, source);
            }
        }

        return .{
            .sources = try sources.toOwnedSlice(allocator),
            .destinations = try destinations.toOwnedSlice(allocator),
            .meter_specs = try meter_specs.toOwnedSlice(allocator),
            .parking_sink_volume = if (findPulseSinkByName(snapshot, parking_sink_name)) |sink| sink.volume else 1.0,
            .parking_sink_muted = if (findPulseSinkByName(snapshot, parking_sink_name)) |sink| sink.muted else false,
        };
    }

    fn applyInventoryRefresh(self: *App, refresh: InventoryRefresh) !void {
        logAppInventoryRefresh(self.state_store, refresh.sources);
        var preserved_bus_destinations = std.ArrayList(PreservedBusDestination).empty;
        defer freePreservedBusDestinations(self.allocator, &preserved_bus_destinations);
        try collectPreservedBusDestinations(self.allocator, &preserved_bus_destinations, self.state_store);
        const restored_preserved = try self.allocator.alloc(bool, preserved_bus_destinations.items.len);
        defer self.allocator.free(restored_preserved);
        @memset(restored_preserved, false);

        try self.remapChannelBindingsForRefresh(refresh.sources);
        self.state_store.clearSources();
        self.state_store.clearChannelSources();
        self.state_store.channel_feed = .pulse_pipewire;

        for (refresh.sources) |source| {
            try self.state_store.addSource(source);
        }
        try self.rebuildChannelSources();

        self.state_store.clearDestinations();
        self.state_store.clearBusDestinations();
        var parking_state_changed = false;
        for (self.state_store.buses.items) |*bus| {
            const next_system_volume: f32 = if (bus.role != .input_stage) refresh.parking_sink_volume else 1.0;
            const next_system_muted: bool = if (bus.role != .input_stage) refresh.parking_sink_muted else false;
            parking_state_changed = parking_state_changed or
                !approxEqVolume(bus.system_volume, next_system_volume) or
                bus.system_muted != next_system_muted;
            bus.system_volume = next_system_volume;
            bus.system_muted = next_system_muted;
        }
        if (parking_state_changed) self.markRoutingDirty();
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
        // A real inventory change can mean an app stream disappeared and then came back
        // with a new sink-input/source identity. Force a routing reconciliation so
        // configured routes recover automatically after play/pause transitions.
        self.route_dirty = true;
    }

    fn remapChannelBindingsForRefresh(self: *App, next_sources: []const sources_mod.Source) !void {
        for (self.state_store.channels.items) |*channel| {
            const candidate = blk: {
                if (channel.bound_source_id) |bound_source_id| {
                    if (findStateSource(next_sources, bound_source_id) != null) continue;
                    break :blk findStateSource(self.state_store.sources.items, bound_source_id) orelse
                        syntheticSourceForChannelBinding(channel.*, bound_source_id);
                }
                break :blk syntheticSourceForUnboundChannel(channel.*) orelse continue;
            };

            const previous_bound_source_id = channel.bound_source_id;
            const mapped_index = try findMappedStateSourceIndex(self.allocator, next_sources, candidate) orelse {
                if (channelSourceKind(channel.*) == .app) {
                    std.log.info(
                        "routing app rebind pending: channel={s} previous_source={s} candidate_label={s} candidate_subtitle={s} candidate_binary={s}",
                        .{
                            channel.id,
                            previous_bound_source_id orelse "<none>",
                            candidate.label,
                            candidate.subtitle,
                            candidate.process_binary,
                        },
                    );
                } else if (channelSourceKind(channel.*) == .physical) {
                    std.log.warn(
                        "routing physical rebind pending: channel={s} previous_source={s} candidate_label={s} candidate_subtitle={s}",
                        .{
                            channel.id,
                            previous_bound_source_id orelse "<none>",
                            candidate.label,
                            candidate.subtitle,
                        },
                    );
                }
                continue;
            };
            if (channelSourceKind(channel.*) == .app) {
                const next_source = next_sources[mapped_index];
                std.log.info(
                    "routing app rebind: channel={s} previous_source={s} next_source={s} label={s} subtitle={s} binary={s}",
                    .{
                        channel.id,
                        previous_bound_source_id orelse "<none>",
                        next_source.id,
                        next_source.label,
                        next_source.subtitle,
                        next_source.process_binary,
                    },
                );
            } else if (channelSourceKind(channel.*) == .physical) {
                const next_source = next_sources[mapped_index];
                if (previous_bound_source_id == null or !std.mem.eql(u8, previous_bound_source_id.?, next_source.id)) {
                    std.log.info(
                        "routing physical rebind: channel={s} previous_source={s} next_source={s} label={s} subtitle={s}",
                        .{
                            channel.id,
                            previous_bound_source_id orelse "<none>",
                            next_source.id,
                            next_source.label,
                            next_source.subtitle,
                        },
                    );
                }
            }
            try replaceOwnedOptionalString(self.allocator, &channel.bound_source_id, next_sources[mapped_index].id);
        }
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

            const source_id = try allocStableHardwareSourceId(self.allocator, obj);
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
            if (shouldSkipGroupedAppOwner(owner)) continue;

            const resolved = try icon.resolve(self.allocator, .{
                .process_binary = owner.process_binary,
                .app_name = owner.flatpak_app_id orelse preferredOwnerIdentityName(owner),
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
                try appendAppPulseSpecs(self.allocator, &specs, snapshot, owners, source);
            } else {
                try appendPhysicalPulseSpecs(self.allocator, &specs, snapshot, source);
            }
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

fn liveAudioWorkerMain(app: *App) void {
    while (!app.live_audio_stop.load(.acquire)) {
        const started_ns = std.time.nanoTimestamp();
        if (app.pipewire_live.canPump()) {
            var pump_count: usize = 0;
            while (pump_count < 3) : (pump_count += 1) {
                app.pipewire_live.pump(if (pump_count == 2) 8 else 0) catch break;
            }
            app.last_live_generation = app.pipewire_live.discovery_generation;
        }
        app.pulse_peak.pump(8) catch {};

        const discovery_ptr = App.worker_allocator.create(live_profiler_mod.Discovery) catch {
            std.Thread.sleep(App.live_audio_poll_interval_ns);
            continue;
        };
        discovery_ptr.* = app.pipewire_live.snapshotDiscovery(App.worker_allocator) catch |err| {
            App.worker_allocator.destroy(discovery_ptr);
            if (err != error.OutOfMemory) {
                std.log.warn("live audio worker discovery failed: {s}", .{@errorName(err)});
            }
            std.Thread.sleep(App.live_audio_poll_interval_ns);
            continue;
        };

        app.live_audio_mutex.lock();
        if (app.pending_live_discovery) |pending| {
            var previous = pending.*;
            previous.deinit(App.worker_allocator);
            App.worker_allocator.destroy(pending);
        }
        app.pending_live_discovery = discovery_ptr;
        app.live_audio_mutex.unlock();

        const duration_ns = std.time.nanoTimestamp() - started_ns;
        if (duration_ns >= live_audio_worker_warn_threshold_ns and
            (app.last_live_audio_worker_warn_ns == 0 or started_ns - app.last_live_audio_worker_warn_ns >= live_audio_warn_log_interval_ns))
        {
            app.last_live_audio_worker_warn_ns = started_ns;
            std.log.warn(
                "live audio worker slow: duration_ns={d} live_generation={d}",
                .{
                    duration_ns,
                    app.last_live_generation,
                },
            );
        }

        const elapsed_ns = std.time.nanoTimestamp() - started_ns;
        if (elapsed_ns < App.live_audio_poll_interval_ns) {
            std.Thread.sleep(@intCast(App.live_audio_poll_interval_ns - elapsed_ns));
        }
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

fn computeFxRuntimeSignature(
    descriptors: []const plugin_host.PluginDescriptor,
    channel_plugins: []const plugin_chain.ChannelPlugin,
    channel_plugin_params: []const plugin_chain.ChannelPluginParam,
) u64 {
    var hasher = std.hash.Wyhash.init(0);

    for (descriptors) |descriptor| {
        hasher.update(descriptor.id);
        hasher.update(descriptor.label);
        hasher.update(descriptor.category);
        hasher.update(descriptor.bundle_name);
        hasher.update(descriptor.primary_ui_uri);
        hasher.update(std.mem.asBytes(&[_]u8{
            @intFromEnum(descriptor.backend),
            @intFromBool(descriptor.has_custom_ui),
        }));
        for (descriptor.control_ports) |port| {
            hasher.update(std.mem.asBytes(&port.index));
            hasher.update(port.symbol);
            hasher.update(port.label);
            hasher.update(std.mem.asBytes(&port.min_value));
            hasher.update(std.mem.asBytes(&port.max_value));
            hasher.update(std.mem.asBytes(&port.default_value));
            hasher.update(std.mem.asBytes(&[_]u8{
                @intFromBool(port.is_output),
                @intFromBool(port.toggled),
                @intFromBool(port.integer),
                @intFromBool(port.enumeration),
                @intFromEnum(port.sync_kind),
            }));
        }
    }

    for (channel_plugins) |channel_plugin| {
        hasher.update(channel_plugin.id);
        hasher.update(channel_plugin.channel_id);
        hasher.update(channel_plugin.descriptor_id);
        hasher.update(channel_plugin.label);
        hasher.update(std.mem.asBytes(&channel_plugin.slot));
        hasher.update(std.mem.asBytes(&[_]u8{
            @intFromEnum(channel_plugin.backend),
            @intFromBool(channel_plugin.enabled),
        }));
    }

    for (channel_plugin_params) |channel_plugin_param| {
        hasher.update(channel_plugin_param.plugin_id);
        hasher.update(channel_plugin_param.symbol);
        hasher.update(std.mem.asBytes(&channel_plugin_param.value));
    }

    return hasher.final();
}

fn logAppInventoryRefresh(state_store: *const StateStore, next_sources: []const sources_mod.Source) void {
    for (state_store.channels.items) |channel| {
        const kind = channelSourceKind(channel) orelse continue;
        if (kind != .app) continue;

        const bound_source_id = channel.bound_source_id orelse {
            std.log.info("routing app inventory: channel={s} label={s} has_no_bound_source", .{
                channel.id,
                channel.label,
            });
            continue;
        };

        const current_source = findStateSource(state_store.sources.items, bound_source_id);
        const next_source = findStateSource(next_sources, bound_source_id);

        if (current_source != null and next_source == null) {
            std.log.info("routing app inventory: channel={s} source={s} disappeared label={s} subtitle={s} binary={s}", .{
                channel.id,
                bound_source_id,
                current_source.?.label,
                current_source.?.subtitle,
                current_source.?.process_binary,
            });
            continue;
        }

        if (current_source == null and next_source != null) {
            std.log.info("routing app inventory: channel={s} source={s} appeared label={s} subtitle={s} binary={s}", .{
                channel.id,
                bound_source_id,
                next_source.?.label,
                next_source.?.subtitle,
                next_source.?.process_binary,
            });
        }
    }
}

fn syntheticSourceForChannelBinding(channel: channels_mod.Channel, source_id: []const u8) sources_mod.Source {
    return .{
        .id = source_id,
        .label = channel.label,
        .subtitle = channel.subtitle,
        .kind = channelSourceKind(channel) orelse .physical,
        .process_binary = syntheticProcessBinaryForChannel(channel),
        .icon_name = channel.icon_name,
        .icon_path = channel.icon_path,
    };
}

fn syntheticSourceForUnboundChannel(channel: channels_mod.Channel) ?sources_mod.Source {
    const kind = channelSourceKind(channel) orelse return null;
    if (channel.label.len == 0 and channel.subtitle.len == 0) return null;

    return .{
        .id = "",
        .label = channel.label,
        .subtitle = channel.subtitle,
        .kind = kind,
        .process_binary = syntheticProcessBinaryForChannel(channel),
        .icon_name = channel.icon_name,
        .icon_path = channel.icon_path,
    };
}

fn findRegistryNodeById(registry: *const pw.RegistryState, id: u32) ?pw.GlobalObject {
    for (registry.objects.items) |obj| {
        if (obj.kind != .node) continue;
        if (obj.id == id) return obj;
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

        const source_id = try allocStableHardwareSourceId(allocator, obj);
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

fn allocStableHardwareSourceId(allocator: std.mem.Allocator, obj: pw.GlobalObject) ![]u8 {
    if (obj.props.node_name) |node_name| {
        return std.fmt.allocPrint(allocator, "pw-source-{s}", .{sanitizeStableIdComponent(node_name)});
    }
    if (obj.props.node_description) |node_description| {
        return std.fmt.allocPrint(allocator, "pw-source-desc-{s}", .{sanitizeStableIdComponent(node_description)});
    }
    if (obj.props.media_name) |media_name| {
        return std.fmt.allocPrint(allocator, "pw-source-media-{s}", .{sanitizeStableIdComponent(media_name)});
    }
    return std.fmt.allocPrint(allocator, "pw-source-{d}", .{obj.id});
}

fn sanitizeStableIdComponent(value: []const u8) []const u8 {
    return value;
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
            .app_name = owner.flatpak_app_id orelse preferredOwnerIdentityName(owner),
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
            .muted = if (matched_sink) |sink| sink.muted else false,
            .volume = if (matched_sink) |sink| sink.volume else 1.0,
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

    if (state_store.buses.items.len != 0) {
        for (state_store.buses.items) |bus| {
            const expected_system_volume: f32 = if (bus.role != .input_stage) refresh.parking_sink_volume else 1.0;
            const expected_system_muted: bool = if (bus.role != .input_stage) refresh.parking_sink_muted else false;
            if (!approxEqVolume(bus.system_volume, expected_system_volume)) return false;
            if (bus.system_muted != expected_system_muted) return false;
        }
    }

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
        if (current.muted != next.muted) return false;
        if (!approxEqVolume(current.volume, next.volume)) return false;
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

fn deinitFxRouteSpecs(allocator: std.mem.Allocator, items: *std.ArrayList(FxRouteSpec)) void {
    for (items.items) |item| {
        if (item.input_target_name) |input_target_name| allocator.free(input_target_name);
        if (item.output_target_names.len == 0) continue;
        for (item.output_target_names) |output_target_name| allocator.free(output_target_name);
        allocator.free(item.output_target_names);
    }
    items.deinit(allocator);
}

fn findFxRouteSpec(items: []const FxRouteSpec, channel_id: []const u8) ?FxRouteSpec {
    for (items) |item| {
        if (std.mem.eql(u8, item.channel_id, channel_id)) return item;
    }
    return null;
}

fn routeSpecNeedsVirtualCaptureSink(spec: FxRouteSpec) bool {
    const input_target_name = spec.input_target_name orelse return false;
    return std.mem.startsWith(u8, input_target_name, "wiredeck_input_");
}

fn routeSpecUsesDirectAppCapture(specs: []const FxRouteSpec, channel_id: []const u8) bool {
    const spec = findFxRouteSpec(specs, channel_id) orelse return false;
    return spec.requires_external_capture and spec.input_port_kind == .output and spec.input_target_name != null;
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
    source: sources_mod.Source,
) !void {
    for (owners) |owner| {
        if (!try ownerMatchesAppSource(allocator, owner, source)) continue;

        for (owner.pulse_sink_input_indexes) |sink_input_index| {
            const sink_input = findPulseSinkInput(snapshot.sink_inputs, sink_input_index) orelse continue;
            const sink_index = sink_input.sink_index orelse continue;
            const sink = findPulseSink(snapshot.sinks, sink_index) orelse continue;
            const monitor_name = sink.monitor_source_name orelse continue;
            try specs.append(allocator, .{
                .source_id = try allocator.dupe(u8, source.id),
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

fn findFirstNonManagedSinkName(allocator: std.mem.Allocator, snapshot: pulse.PulseSnapshot) ?[]u8 {
    for (snapshot.sinks) |sink| {
        const current_name = sink.name orelse continue;
        if (isWiredeckManagedSinkName(current_name)) continue;
        return allocator.dupe(u8, current_name) catch null;
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
        const source_name = try output_exposure_mod.allocVirtualMicNodeName(allocator, bus.label, bus.id);
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

const FxInputBinding = struct {
    target_name: ?[]const u8 = null,
    target_node_id: ?u32 = null,
    port_kind: FxInputPortKind = .monitor,
};

const DirectAppPipewireNodeTarget = struct {
    node_id: u32,
    node_name: []u8,
};

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
    const channel = findStateChannel(state_store, channel_id) orelse return null;
    if (!channelNeedsVirtualCaptureSink(state_store, channel)) return target_sink;
    if (target_sink == null and !App.channelHasNetworkVisibleRoute(state_store, channel_id)) return null;

    const sink_name = try virtual_inputs.allocSinkName(self.allocator, "wiredeck_input_", channel_id);
    defer self.allocator.free(sink_name);

    const sink = findPulseSinkByName(pulse_snapshot, sink_name) orelse return error.CaptureSinkPending;
    return .{
        .sink_index = sink.index,
        .sink_name = sink.name.?,
    };
}

fn sinkInputTargetsVirtualCaptureSink(pulse_snapshot: pulse.PulseSnapshot, sink_input: pulse.PulseSinkInput) bool {
    const sink_index = sink_input.sink_index orelse return false;
    const sink = findPulseSink(pulse_snapshot.sinks, sink_index) orelse return false;
    const sink_name = sink.name orelse return false;
    return isVirtualCaptureSinkName(sink_name);
}

fn shouldHoldNetworkCaptureRoute(
    self: *App,
    state_store: *const StateStore,
    channel_id: []const u8,
    pulse_snapshot: pulse.PulseSnapshot,
    pulsectx: *pulse.PulseContext,
    sink_input: pulse.PulseSinkInput,
    uses_fx: bool,
) bool {
    if (!uses_fx) return false;
    const channel = findStateChannel(state_store, channel_id) orelse return false;
    if (!channelNeedsVirtualCaptureSink(state_store, channel)) return false;
    if (!App.channelHasNetworkVisibleRoute(state_store, channel_id)) return false;

    if (sinkInputTargetsVirtualCaptureSink(pulse_snapshot, sink_input)) return true;

    _ = resolveCaptureSinkForChannel(self, state_store, channel_id, pulse_snapshot, pulsectx, uses_fx) catch |err| switch (err) {
        error.CaptureSinkPending => return true,
        else => return false,
    };
    return true;
}

fn resolveFxInputBinding(
    self: *App,
    state_store: *const StateStore,
    pulse_snapshot: pulse.PulseSnapshot,
    registry: *const pw.RegistryState,
    owners: []const binder.BoundOwner,
    channel: channels_mod.Channel,
) !FxInputBinding {
    if (!channelRequiresExternalCapture(state_store, channel)) return .{};

    const bound_source_id = channel.bound_source_id orelse {
        return .{
            .target_name = try virtual_inputs.allocSinkName(self.allocator, "wiredeck_input_", channel.id),
            .port_kind = .monitor,
        };
    };
    const source = findStateSource(state_store.sources.items, bound_source_id) orelse {
        return .{
            .target_name = try virtual_inputs.allocSinkName(self.allocator, "wiredeck_input_", channel.id),
            .port_kind = .monitor,
        };
    };

    if (source.kind == .app) {
        if (appSourceHasLiveFallbackCaptureOwner(self.allocator, owners, source)) {
            if (!appSourcePrefersStableMonitorCapture(source)) {
                if (try resolveDirectAppPipewireNodeTarget(self.allocator, registry, owners, pulse_snapshot, source)) |target| {
                    const binding: FxInputBinding = .{
                        .target_name = target.node_name,
                        .target_node_id = target.node_id,
                        .port_kind = .output,
                    };
                    try self.rememberRecentAppFxBinding(channel.id, source.id, binding);
                    if (enable_routing_info_logs) {
                        std.log.info("routing fx input: channel={s} source={s} mode=direct_output target={s} node_id={d}", .{
                            channel.id,
                            bound_source_id,
                            target.node_name,
                            target.node_id,
                        });
                    }
                    return binding;
                }
            }
            const target_name = try virtual_inputs.allocSinkName(self.allocator, "wiredeck_input_", channel.id);
            const binding: FxInputBinding = .{
                .target_name = target_name,
                .port_kind = .monitor,
            };
            try self.rememberRecentAppFxBinding(channel.id, source.id, binding);
            if (enable_routing_info_logs) {
                std.log.info("routing fx input: channel={s} source={s} mode=fallback_monitor reason={s}", .{
                    channel.id,
                    bound_source_id,
                    if (appSourcePrefersStableMonitorCapture(source)) "stable_app_capture" else "sticky_app_virtual_capture",
                });
            }
            return binding;
        }
        if (self.recentAppFxBinding(channel.id, source.id)) |recent_binding| {
            if (recent_binding.port_kind == .output) {
                if (enable_routing_info_logs) {
                    std.log.info("routing fx input: channel={s} source={s} mode=hold_recent target={s} port={s}", .{
                        channel.id,
                        bound_source_id,
                        recent_binding.target_name,
                        @tagName(recent_binding.port_kind),
                    });
                }
                return .{
                    .target_name = try self.allocator.dupe(u8, recent_binding.target_name),
                    .target_node_id = recent_binding.target_node_id,
                    .port_kind = recent_binding.port_kind,
                };
            }
        }
        if (self.recentAppFxBinding(channel.id, source.id)) |recent_binding| {
            if (enable_routing_info_logs) {
                std.log.info("routing fx input: channel={s} source={s} mode=hold_recent target={s} port={s}", .{
                    channel.id,
                    bound_source_id,
                    recent_binding.target_name,
                    @tagName(recent_binding.port_kind),
                });
            }
            return .{
                .target_name = try self.allocator.dupe(u8, recent_binding.target_name),
                .target_node_id = recent_binding.target_node_id,
                .port_kind = recent_binding.port_kind,
            };
        }
        if (enable_routing_info_logs) {
            std.log.info("routing fx input: channel={s} source={s} mode=skip reason=no_live_app_owner", .{
                channel.id,
                bound_source_id,
            });
        }
        return .{};
    } else if (matchPulseSourceNameForStateSource(pulse_snapshot, source)) |source_name| {
        return .{
            .target_name = try self.allocator.dupe(u8, source_name),
            .port_kind = .capture,
        };
    }

    return .{
        .target_name = try virtual_inputs.allocSinkName(self.allocator, "wiredeck_input_", channel.id),
        .port_kind = .monitor,
    };
}

fn resolveDirectAppPipewireNodeTarget(
    allocator: std.mem.Allocator,
    registry: *const pw.RegistryState,
    owners: []const binder.BoundOwner,
    pulse_snapshot: pulse.PulseSnapshot,
    source: sources_mod.Source,
) !?DirectAppPipewireNodeTarget {
    var active_target: ?DirectAppPipewireNodeTarget = null;
    errdefer if (active_target) |target| allocator.free(target.node_name);
    var corked_target: ?DirectAppPipewireNodeTarget = null;
    errdefer if (corked_target) |target| allocator.free(target.node_name);
    var matched_owner_count: usize = 0;
    var matched_output_node_count: usize = 0;
    var corked_node_count: usize = 0;
    var ambiguous = false;

    for (owners) |owner| {
        if (!try ownerMatchesAppSource(allocator, owner, source)) continue;
        matched_owner_count += 1;
        for (registry.objects.items) |obj| {
            if (!registryOutputNodeBelongsToOwner(obj, owner)) continue;
            const pw_node_id = obj.id;
            matched_output_node_count += 1;
            const node_name = obj.props.node_name orelse continue;

            if (obj.props.object_serial) |serial| {
                const sink_input_index = std.math.cast(u32, serial) orelse continue;
                const sink_input = findPulseSinkInput(pulse_snapshot.sink_inputs, sink_input_index) orelse continue;
                if (sink_input.corked) {
                    corked_node_count += 1;
                    if (corked_target) |existing| {
                        if (existing.node_id != pw_node_id) {
                            allocator.free(existing.node_name);
                            corked_target = null;
                            ambiguous = true;
                            return null;
                        }
                    } else {
                        corked_target = .{
                            .node_id = pw_node_id,
                            .node_name = try allocator.dupe(u8, node_name),
                        };
                    }
                    continue;
                }
                if (active_target) |existing| {
                    if (existing.node_id != pw_node_id) {
                        allocator.free(existing.node_name);
                        active_target = null;
                        ambiguous = true;
                        return null;
                    }
                    continue;
                }

                active_target = .{
                    .node_id = pw_node_id,
                    .node_name = try allocator.dupe(u8, node_name),
                };
                continue;
            }

            if (active_target) |existing| {
                if (existing.node_id != pw_node_id) {
                    allocator.free(existing.node_name);
                    active_target = null;
                    ambiguous = true;
                    return null;
                }
                continue;
            }
        }
    }

    if (active_target == null and corked_target != null and !ambiguous) {
        std.log.info("routing app direct target: source={s} mode=hold_corked owners={d} output_nodes={d} corked_nodes={d}", .{
            source.id,
            matched_owner_count,
            matched_output_node_count,
            corked_node_count,
        });
        active_target = corked_target;
        corked_target = null;
    }

    if (active_target == null and matched_owner_count > 0) {
        std.log.info(
            "routing app direct target unavailable: source={s} owners={d} output_nodes={d} corked_nodes={d} ambiguous={any}",
            .{
                source.id,
                matched_owner_count,
                matched_output_node_count,
                corked_node_count,
                ambiguous,
            },
        );
    }

    return active_target;
}

fn registryOutputNodeBelongsToOwner(obj: pw.GlobalObject, owner: binder.BoundOwner) bool {
    if (obj.kind != .node) return false;
    const media_class = obj.props.media_class orelse return false;
    if (!std.mem.eql(u8, media_class, "Stream/Output/Audio")) return false;

    if (owner.pw_client_id != null and obj.props.client_id != null and owner.pw_client_id.? == obj.props.client_id.?) {
        return true;
    }

    if (owner.process_binary) |binary| {
        if (sameAppIdentityText(binary, obj.props.app_process_binary orelse "")) return true;
    }
    if (owner.app_name) |app_name| {
        if (sameAppIdentityText(app_name, obj.props.app_name orelse "")) return true;
        if (sameAppIdentityText(app_name, obj.props.node_name orelse "")) return true;
        if (sameAppIdentityText(app_name, obj.props.media_name orelse "")) return true;
    }
    if (owner.media_name) |media_name| {
        if (sameAppIdentityText(media_name, obj.props.media_name orelse "")) return true;
        if (sameAppIdentityText(media_name, obj.props.node_name orelse "")) return true;
    }

    return false;
}

fn collectActiveFxChannels(
    allocator: std.mem.Allocator,
    app: *const App,
    state_store: *const StateStore,
    pulse_snapshot: pulse.PulseSnapshot,
    channels: *std.ArrayList(channels_mod.Channel),
) !void {
    _ = app;
    _ = pulse_snapshot;
    for (state_store.channels.items) |channel| {
        const bound_source_id = channel.bound_source_id orelse continue;
        if (findStateSource(state_store.sources.items, bound_source_id) == null) continue;
        try channels.append(allocator, channel);
    }
}

fn collectExternalCaptureFxChannels(
    allocator: std.mem.Allocator,
    state_store: *const StateStore,
    fx_channels: []const channels_mod.Channel,
    channels: *std.ArrayList(channels_mod.Channel),
) !void {
    for (fx_channels) |channel| {
        if (!channelRequiresExternalCapture(state_store, channel)) continue;
        try channels.append(allocator, channel);
    }
}

fn collectVirtualCaptureFxChannels(
    allocator: std.mem.Allocator,
    state_store: *const StateStore,
    owners: []const binder.BoundOwner,
    fx_channels: []const channels_mod.Channel,
    route_specs: []const FxRouteSpec,
    channels: *std.ArrayList(channels_mod.Channel),
) !void {
    _ = state_store;
    _ = owners;
    for (fx_channels) |channel| {
        const route_spec = findFxRouteSpec(route_specs, channel.id) orelse continue;
        if (!routeSpecNeedsVirtualCaptureSink(route_spec)) continue;
        try channels.append(allocator, channel);
    }
}

fn channelUsesInternalInputPath(state_store: *const StateStore, channel: channels_mod.Channel) bool {
    if (channelHasLv2Plugin(state_store, channel.id)) return true;

    const bound_source_id = channel.bound_source_id orelse return false;
    const source = findStateSource(state_store.sources.items, bound_source_id) orelse return false;
    return isNetworkIngressSource(source);
}

fn channelRequiresExternalCapture(state_store: *const StateStore, channel: channels_mod.Channel) bool {
    const bound_source_id = channel.bound_source_id orelse return true;
    const source = findStateSource(state_store.sources.items, bound_source_id) orelse return true;
    return !isNetworkIngressSource(source);
}

fn channelNeedsVirtualCaptureSink(state_store: *const StateStore, channel: channels_mod.Channel) bool {
    const bound_source_id = channel.bound_source_id orelse return true;
    const source = findStateSource(state_store.sources.items, bound_source_id) orelse return true;
    return source.kind == .app;
}

fn channelHasActiveFallbackAppCapture(
    allocator: std.mem.Allocator,
    state_store: *const StateStore,
    owners: []const binder.BoundOwner,
    channel: channels_mod.Channel,
) bool {
    const bound_source_id = channel.bound_source_id orelse return false;
    const source = findStateSource(state_store.sources.items, bound_source_id) orelse return false;
    if (source.kind != .app) return true;

    for (owners) |owner| {
        if (!(ownerMatchesAppSource(allocator, owner, source) catch false)) continue;
        if (owner.pulse_sink_input_indexes.len > 0) return true;
    }
    return false;
}

fn channelShouldCreateFxRoute(
    allocator: std.mem.Allocator,
    state_store: *const StateStore,
    owners: []const binder.BoundOwner,
    channel: channels_mod.Channel,
    input_binding: FxInputBinding,
) bool {
    _ = allocator;
    _ = owners;
    if (!channelRequiresExternalCapture(state_store, channel)) return true;

    const bound_source_id = channel.bound_source_id orelse return input_binding.target_name != null;
    const source = findStateSource(state_store.sources.items, bound_source_id) orelse return input_binding.target_name != null;
    if (source.kind != .app) return true;
    return input_binding.target_name != null;
}

fn channelNeedsInternalFanout(
    app: *const App,
    state_store: *const StateStore,
    pulse_snapshot: pulse.PulseSnapshot,
    channel: channels_mod.Channel,
) !bool {
    var sinks = std.ArrayList(App.ChannelTargetSink).empty;
    defer sinks.deinit(app.allocator);
    try app.collectResolvedSinksForChannel(state_store, channel.id, pulse_snapshot, &sinks);
    return sinks.items.len > 1;
}

fn channelHasLv2Plugin(state_store: *const StateStore, channel_id: []const u8) bool {
    for (state_store.channel_plugins.items) |channel_plugin| {
        if (channel_plugin.backend != .lv2) continue;
        if (std.mem.eql(u8, channel_plugin.channel_id, channel_id)) return true;
    }
    return false;
}

fn isNetworkIngressSource(source: sources_mod.Source) bool {
    return (source.kind == .virtual and std.mem.eql(u8, source.process_binary, "wiredeck-client")) or
        std.mem.startsWith(u8, source.id, "wdnet-");
}

fn shouldSkipGroupedAppOwner(owner: binder.BoundOwner) bool {
    if (owner.synthetic or owner.wiredeck_managed) return true;
    if (owner.process_binary) |binary| {
        if (containsIgnoreCase(binary, "wiredeck")) return true;
        if (std.mem.eql(u8, binary, "obs") or std.mem.eql(u8, binary, "obs64")) return true;
    }
    if (owner.app_name) |app_name| {
        if (containsIgnoreCase(app_name, "wiredeck")) return true;
        if (containsIgnoreCase(app_name, "obs studio")) return true;
    }
    if (owner.flatpak_app_id) |flatpak_app_id| {
        if (containsIgnoreCase(flatpak_app_id, "wiredeck")) return true;
        if (containsIgnoreCase(flatpak_app_id, "obsproject")) return true;
    }
    return false;
}

fn isWiredeckManagedModule(name: []const u8, argument: []const u8) bool {
    if (std.mem.eql(u8, name, "module-null-sink")) {
        return containsIgnoreCase(argument, "sink_name=wiredeck_input_") or
            containsIgnoreCase(argument, "sink_name=wiredeck_fx_") or
            containsIgnoreCase(argument, "sink_name=wiredeck_output_") or
            containsIgnoreCase(argument, "sink_name=wiredeck_busmic_sink_") or
            containsIgnoreCase(argument, "sink_name=wiredeck_parking_sink");
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
    target_sink_index: ?u32,
    muted: bool,
    volume: ?f32 = null,
    block_on_failure: bool = false,
};

const ParkingSinkGain = struct {
    volume: f32 = 1.0,
    muted: bool = false,
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
    if (looksLikeDiscordCaptureOwner(owner)) return allocator.dupe(u8, "appgrp-discord");
    if (resolved.desktop_file_id) |desktop_file_id| {
        return std.fmt.allocPrint(allocator, "appgrp-{s}", .{sanitizeId(desktop_file_id)});
    }
    if (owner.flatpak_app_id) |flatpak_app_id| {
        return std.fmt.allocPrint(allocator, "appgrp-{s}", .{sanitizeId(flatpak_app_id)});
    }
    if (preferredOwnerIdentityName(owner)) |preferred_name| {
        if (preferred_name.len > 0) {
            return std.fmt.allocPrint(allocator, "appgrp-{s}", .{sanitizeId(normalizedOwnerLabel(owner))});
        }
    }
    if (owner.process_binary) |binary| {
        if (binary.len > 0) {
            return std.fmt.allocPrint(allocator, "appgrp-{s}", .{sanitizeId(binary)});
        }
    }
    if (resolved.icon_name) |icon_name| {
        return std.fmt.allocPrint(allocator, "appgrp-{s}", .{sanitizeId(icon_name)});
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
        .app_name = owner.flatpak_app_id orelse preferredOwnerIdentityName(owner),
    });
    defer icon.freeResolveResult(allocator, resolved);

    const owner_group_id = try buildGroupedAppSourceId(allocator, owner, resolved);
    defer allocator.free(owner_group_id);
    return std.mem.eql(u8, owner_group_id, grouped_source_id);
}

fn ownerMatchesAppSource(
    allocator: std.mem.Allocator,
    owner: binder.BoundOwner,
    source: sources_mod.Source,
) !bool {
    if (source.kind != .app) return false;
    if (shouldSkipGroupedAppOwner(owner)) return false;
    if (try ownerMatchesGroupedSourceId(allocator, owner, source.id)) return true;

    const source_group_id = try buildGroupedSourceIdForDiscovered(allocator, source);
    defer allocator.free(source_group_id);
    if (try ownerMatchesGroupedSourceId(allocator, owner, source_group_id)) return true;

    if (looksLikeDiscordSource(source) and looksLikeDiscordCaptureOwner(owner)) return true;
    return ownerMatchesAppSourceMetadata(owner, source);
}

fn ownerMatchesAppSourceMetadata(owner: binder.BoundOwner, source: sources_mod.Source) bool {
    const label_match = appSourceFieldMatchesOwner(source.label, owner);
    const subtitle_match = appSourceFieldMatchesOwner(source.subtitle, owner);
    const process_match = appSourceFieldMatchesOwner(source.process_binary, owner);

    if (process_match) return true;
    if (label_match and (source.subtitle.len == 0 or subtitle_match or process_match)) return true;
    if (subtitle_match and (source.label.len == 0 or label_match or process_match)) return true;
    return false;
}

fn appSourceFieldMatchesOwner(source_value: []const u8, owner: binder.BoundOwner) bool {
    return sameAppIdentityText(source_value, normalizedOwnerLabel(owner)) or
        sameAppIdentityText(source_value, normalizedOwnerSubtitle(owner)) or
        sameAppIdentityText(source_value, owner.process_binary orelse "") or
        sameAppIdentityText(source_value, owner.app_name orelse "") or
        sameAppIdentityText(source_value, owner.media_name orelse "") or
        sameAppIdentityText(source_value, owner.flatpak_app_id orelse "");
}

fn sameAppIdentityText(left: []const u8, right: []const u8) bool {
    if (!appIdentityTextLooksUsable(left) or !appIdentityTextLooksUsable(right)) return false;
    if (sameText(left, right)) return true;
    if (left.len < 4 or right.len < 4) return false;
    return containsIgnoreCase(left, right) or containsIgnoreCase(right, left);
}

fn appIdentityTextLooksUsable(value: []const u8) bool {
    if (value.len == 0) return false;
    if (containsIgnoreCase(value, "wiredeck")) return false;
    if (std.ascii.eqlIgnoreCase(value, "unknown app")) return false;
    if (std.ascii.eqlIgnoreCase(value, "audio")) return false;
    if (std.ascii.eqlIgnoreCase(value, "playback")) return false;
    if (std.ascii.eqlIgnoreCase(value, "audio stream")) return false;
    if (std.ascii.eqlIgnoreCase(value, "output stream")) return false;
    return true;
}

fn appSourceHasLiveFallbackCaptureOwner(
    allocator: std.mem.Allocator,
    owners: []const binder.BoundOwner,
    source: sources_mod.Source,
) bool {
    for (owners) |owner| {
        if (!(ownerMatchesAppSource(allocator, owner, source) catch false)) continue;
        if (owner.pulse_sink_input_indexes.len > 0) return true;
    }
    return false;
}

fn containsDesiredMove(items: []const DesiredSinkMove, sink_input_index: u32) bool {
    for (items) |item| {
        if (item.sink_input_index == sink_input_index) return true;
    }
    return false;
}


fn currentParkingSinkGain(pulse_snapshot: pulse.PulseSnapshot) ParkingSinkGain {
    if (findPulseSinkByName(pulse_snapshot, parking_sink_name)) |sink| {
        return .{
            .volume = sink.volume,
            .muted = sink.muted,
        };
    }
    return .{};
}

fn applyParkingSinkGain(base_volume: f32, base_muted: bool, gain: ParkingSinkGain) ParkingSinkGain {
    return .{
        .volume = std.math.clamp(base_volume * gain.volume, 0.0, 4.0),
        .muted = base_muted or gain.muted,
    };
}

fn hasRecordedOriginal(items: []const App.RoutedSinkInput, sink_input_index: u32) bool {
    for (items) |item| {
        if (item.sink_input_index == sink_input_index) return true;
    }
    return false;
}

fn containsBlockedSinkInput(items: []const u32, sink_input_index: u32) bool {
    for (items) |item| {
        if (item == sink_input_index) return true;
    }
    return false;
}

fn removeBlockedSinkInput(items: *std.ArrayList(u32), sink_input_index: u32) void {
    for (items.items, 0..) |item, index| {
        if (item != sink_input_index) continue;
        _ = items.orderedRemove(index);
        return;
    }
}

fn approxEqVolume(left: f32, right: f32) bool {
    return @abs(left - right) <= 0.001;
}

fn findRecordedRoutedSinkInput(items: []const App.RoutedSinkInput, sink_input_index: u32) ?App.RoutedSinkInput {
    for (items) |item| {
        if (item.sink_input_index == sink_input_index) return item;
    }
    return null;
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
    if (looksLikeDiscordVoiceEngine(source) or looksLikeDiscordSource(source)) {
        return allocator.dupe(u8, "appgrp-discord");
    }
    if (source.label.len > 0) {
        return std.fmt.allocPrint(allocator, "appgrp-{s}", .{sanitizeId(source.label)});
    }
    if (source.process_binary.len > 0) {
        return std.fmt.allocPrint(allocator, "appgrp-{s}", .{sanitizeId(source.process_binary)});
    }
    if (source.icon_name.len > 0 and !std.mem.eql(u8, source.icon_name, "application-x-executable")) {
        return std.fmt.allocPrint(allocator, "appgrp-{s}", .{sanitizeId(source.icon_name)});
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

    if (discovered_source.kind == .app) {
        const grouped_id = try buildGroupedSourceIdForDiscovered(allocator, discovered_source);
        defer allocator.free(grouped_id);
        if (findSourceIndex(items, grouped_id)) |index| return index;
    }

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
    const candidate = preferredOwnerIdentityName(owner) orelse owner.process_binary orelse "Unknown App";
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

fn preferredOwnerIdentityName(owner: binder.BoundOwner) ?[]const u8 {
    if (owner.media_name) |media_name| {
        if (ownerShouldPreferMediaName(owner) and ownerMediaNameLooksUsable(media_name)) return media_name;
    }
    return owner.app_name;
}

fn ownerShouldPreferMediaName(owner: binder.BoundOwner) bool {
    const app_name = owner.app_name orelse "";
    const process_binary = owner.process_binary orelse "";
    return containsIgnoreCase(process_binary, "wine") or
        containsIgnoreCase(process_binary, "proton") or
        containsIgnoreCase(process_binary, "steam") or
        containsIgnoreCase(process_binary, "pressure-vessel") or
        containsIgnoreCase(process_binary, "gamescope") or
        containsIgnoreCase(app_name, "wine") or
        containsIgnoreCase(app_name, "proton") or
        containsIgnoreCase(app_name, "steam_app_") or
        std.ascii.eqlIgnoreCase(app_name, "steam");
}

fn ownerMediaNameLooksUsable(media_name: []const u8) bool {
    if (media_name.len == 0) return false;
    if (containsIgnoreCase(media_name, "wiredeck")) return false;
    if (std.mem.startsWith(u8, media_name, "loopback-")) return false;
    if (std.ascii.eqlIgnoreCase(media_name, "playback")) return false;
    if (std.ascii.eqlIgnoreCase(media_name, "audio")) return false;
    if (std.ascii.eqlIgnoreCase(media_name, "audio stream")) return false;
    if (std.ascii.eqlIgnoreCase(media_name, "output stream")) return false;
    return true;
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

fn looksLikeBrowserSource(source: sources_mod.Source) bool {
    if (source.kind != .app) return false;
    return containsIgnoreCase(source.label, "firefox") or
        containsIgnoreCase(source.subtitle, "firefox") or
        containsIgnoreCase(source.process_binary, "firefox") or
        containsIgnoreCase(source.id, "firefox") or
        containsIgnoreCase(source.label, "chromium") or
        containsIgnoreCase(source.subtitle, "chromium") or
        containsIgnoreCase(source.process_binary, "chromium") or
        containsIgnoreCase(source.id, "chromium") or
        containsIgnoreCase(source.label, "chrome") or
        containsIgnoreCase(source.subtitle, "chrome") or
        containsIgnoreCase(source.process_binary, "chrome") or
        containsIgnoreCase(source.id, "chrome") or
        containsIgnoreCase(source.label, "brave") or
        containsIgnoreCase(source.subtitle, "brave") or
        containsIgnoreCase(source.process_binary, "brave") or
        containsIgnoreCase(source.id, "brave") or
        containsIgnoreCase(source.label, "vivaldi") or
        containsIgnoreCase(source.subtitle, "vivaldi") or
        containsIgnoreCase(source.process_binary, "vivaldi") or
        containsIgnoreCase(source.id, "vivaldi") or
        containsIgnoreCase(source.label, "opera") or
        containsIgnoreCase(source.subtitle, "opera") or
        containsIgnoreCase(source.process_binary, "opera") or
        containsIgnoreCase(source.id, "opera") or
        containsIgnoreCase(source.label, "edge") or
        containsIgnoreCase(source.subtitle, "edge") or
        containsIgnoreCase(source.process_binary, "edge") or
        containsIgnoreCase(source.id, "edge");
}

fn appSourcePrefersStableMonitorCapture(source: sources_mod.Source) bool {
    return looksLikeBrowserSource(source);
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

fn channelSourceKind(channel: channels_mod.Channel) ?sources_mod.SourceKind {
    return std.meta.intToEnum(sources_mod.SourceKind, channel.source_kind) catch null;
}

fn syntheticProcessBinaryForChannel(channel: channels_mod.Channel) []const u8 {
    if (channelSourceKind(channel) == .app) return channel.subtitle;
    return "";
}

fn replaceOwnedOptionalString(allocator: std.mem.Allocator, field: *?[]const u8, value: ?[]const u8) !void {
    const owned = if (value) |item| try allocator.dupe(u8, item) else null;
    if (field.*) |existing| allocator.free(existing);
    field.* = owned;
}

fn sanitizeId(value: []const u8) []const u8 {
    return value;
}

fn isWiredeckManagedSinkName(sink_name: []const u8) bool {
    return std.mem.startsWith(u8, sink_name, "wiredeck-combine-") or
        std.mem.startsWith(u8, sink_name, "wiredeck_output_") or
        std.mem.startsWith(u8, sink_name, "wiredeck_input_") or
        std.mem.startsWith(u8, sink_name, "wiredeck_fx_") or
        std.mem.startsWith(u8, sink_name, "wiredeck_busmic_sink_") or
        std.mem.startsWith(u8, sink_name, "wiredeck_parking_sink");
}

fn isVirtualCaptureSinkName(sink_name: []const u8) bool {
    return std.mem.startsWith(u8, sink_name, "wiredeck_input_");
}

fn isWiredeckManagedRegistryObject(obj: pw.types.GlobalObject) bool {
    if (obj.props.node_name) |node_name| {
        if (isWiredeckManagedNodeName(node_name)) return true;
    }
    if (obj.props.node_description) |node_description| {
        if (containsIgnoreCase(node_description, "wiredeck input ") or
            containsIgnoreCase(node_description, "wiredeck fx ") or
            containsIgnoreCase(node_description, "wiredeck level ") or
            containsIgnoreCase(node_description, "wiredeck output ") or
            containsIgnoreCase(node_description, "wiredeck "))
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
        std.mem.startsWith(u8, node_name, "wiredeck_busmic_") or
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
        .muted = if (isProfileActive(card, profile.name) and active_sink != null) active_sink.?.muted else false,
        .volume = if (isProfileActive(card, profile.name) and active_sink != null) active_sink.?.volume else 1.0,
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
