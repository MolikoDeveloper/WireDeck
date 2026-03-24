const std = @import("std");
const c = @import("../c.zig").c;
const StateStore = @import("../app/state_store.zig").StateStore;
const App = @import("../app/app.zig").App;
const channels_mod = @import("../core/audio/channels.zig");
const buses_mod = @import("../core/audio/buses.zig");
const sends_mod = @import("../core/audio/sends.zig");
const channel_sources_mod = @import("../core/audio/channel_sources.zig");
const bus_destinations_mod = @import("../core/audio/bus_destinations.zig");
const destinations_mod = @import("../core/audio/destinations.zig");
const plugins_mod = @import("../plugins/chain.zig");
const plugin_host_mod = @import("../plugins/host.zig");
const imgui = @import("../native/imgui_bridge.zig");
const Lv2UiManager = @import("../plugins/lv2_ui.zig").Lv2UiManager;
const SdlPlatform = @import("../platform/sdl.zig").SdlPlatform;
const WindowConfig = @import("../platform/window.zig").WindowConfig;
const ConfigStore = @import("../persistence/config.zig").ConfigStore;

const max_recent_events = 6;
const event_label_capacity = 96;

pub const UiShell = struct {
    const MutationResult = struct {
        changed: bool = false,
        routing_changed: bool = false,
    };

    pub fn run(config: WindowConfig, app: *App, state_store: *StateStore, config_store: ?*const ConfigStore) !void {
        const allocator = std.heap.page_allocator;
        var platform = try SdlPlatform.init(config);
        defer platform.deinit();

        const bridge = imgui.wiredeck_imgui_create(platform.window) orelse {
            std.debug.print("UI bootstrap failed: {s}\n", .{imgui.wiredeck_imgui_last_error() orelse "unknown error"});
            return error.UiBootstrapFailed;
        };
        defer imgui.wiredeck_imgui_destroy(bridge);
        const autostart_enabled = isAutostartEnabled(allocator) catch false;
        imgui.wiredeck_imgui_set_tray_autostart_enabled(bridge, @intFromBool(autostart_enabled));

        var lv2_ui_manager = Lv2UiManager.init(allocator);
        defer lv2_ui_manager.deinit();

        var channels = std.ArrayList(imgui.UiChannel).empty;
        defer channels.deinit(allocator);
        var buses = std.ArrayList(imgui.UiBus).empty;
        defer buses.deinit(allocator);
        var sends = std.ArrayList(imgui.UiSend).empty;
        defer sends.deinit(allocator);
        var sources = std.ArrayList(imgui.UiSource).empty;
        defer sources.deinit(allocator);
        var channel_sources = std.ArrayList(imgui.UiChannelSource).empty;
        defer channel_sources.deinit(allocator);
        var destinations = std.ArrayList(imgui.UiDestination).empty;
        defer destinations.deinit(allocator);
        var bus_destinations = std.ArrayList(imgui.UiBusDestination).empty;
        defer bus_destinations.deinit(allocator);
        var channel_plugins = std.ArrayList(imgui.UiChannelPlugin).empty;
        defer channel_plugins.deinit(allocator);
        var channel_plugin_params = std.ArrayList(imgui.UiChannelPluginParam).empty;
        defer channel_plugin_params.deinit(allocator);
        var noise_models = std.ArrayList(imgui.UiNoiseModel).empty;
        defer noise_models.deinit(allocator);
        var plugin_descriptors = std.ArrayList(imgui.UiPluginDescriptor).empty;
        defer plugin_descriptors.deinit(allocator);
        var recent_events = std.ArrayList(imgui.UiEvent).empty;
        defer recent_events.deinit(allocator);
        try recent_events.resize(allocator, max_recent_events);
        var recent_event_labels: [max_recent_events][event_label_capacity:0]u8 = undefined;
        var ui_strings = UiStringStorage.init(allocator);
        defer ui_strings.deinit();

        var snapshot = imgui.UiSnapshot{
            .active_profile = undefined,
            .channels = undefined,
            .channel_count = 0,
            .channel_feed_kind = 0,
            .buses = undefined,
            .bus_count = 0,
            .sends = undefined,
            .send_count = 0,
            .sources = undefined,
            .source_count = 0,
            .channel_sources = undefined,
            .channel_source_count = 0,
            .destinations = undefined,
            .destination_count = 0,
            .destination_feed_kind = 0,
            .bus_destinations = undefined,
            .bus_destination_count = 0,
            .channel_plugins = undefined,
            .channel_plugin_count = 0,
            .channel_plugin_params = undefined,
            .channel_plugin_param_count = 0,
            .noise_models = undefined,
            .noise_model_count = 0,
            .plugin_descriptors = undefined,
            .plugin_descriptor_count = 0,
            .recent_events = recent_events.items.ptr,
            .recent_event_count = 0,
            .event_count = 0,
            .request_add_input = 0,
            .request_add_output = 0,
            .request_select_source_id = zeroedBuffer(64),
            .request_rename_input_id = zeroedBuffer(64),
            .request_rename_input_label = zeroedBuffer(64),
            .request_rename_output_id = zeroedBuffer(64),
            .request_rename_output_label = zeroedBuffer(64),
            .request_delete_input_id = zeroedBuffer(64),
            .request_delete_output_id = zeroedBuffer(64),
            .request_add_plugin_channel_id = zeroedBuffer(64),
            .request_add_plugin_descriptor_id = zeroedBuffer(64),
            .request_remove_plugin_id = zeroedBuffer(64),
            .request_move_plugin_id = zeroedBuffer(64),
            .request_move_plugin_delta = 0,
            .request_open_plugin_ui_id = zeroedBuffer(64),
            .request_select_noise_model_path = zeroedBuffer(512),
        };

        while (true) {
            const ui_state = imgui.wiredeck_imgui_pump_events(bridge);
            if (ui_state < 0) {
                std.debug.print("UI event pump failed: {s}\n", .{imgui.wiredeck_imgui_last_error() orelse "unknown error"});
                return error.UiFrameFailed;
            }
            if (ui_state == 0) break;
            if (ui_state == 1) {
                app.pumpLiveAudio() catch {};
                app.maybeRefreshAudioInventory();
                _ = lv2_ui_manager.pump(app, state_store);
                try syncTrayAutostartPreference(allocator, bridge);
                app.reconcileOutputRoutingIfNeeded();
                platform.nextFrame();
                if (config.max_frames) |max_frames| {
                    if (platform.frame_count >= max_frames) break;
                }
                continue;
            }

            app.pumpLiveAudio() catch {};
            app.maybeRefreshAudioInventory();
            const lv2_ui_changed = lv2_ui_manager.pump(app, state_store);
            try ensureSnapshotCapacity(
                allocator,
                state_store,
                &channels,
                &buses,
                &sends,
                &sources,
                &channel_sources,
                &destinations,
                &bus_destinations,
                &channel_plugins,
                &channel_plugin_params,
                &noise_models,
                &plugin_descriptors,
                &snapshot,
            );
            try rebuildUiSnapshot(state_store, &snapshot, &recent_event_labels, &ui_strings);

            const keep_running = imgui.wiredeck_imgui_render_frame(bridge, &snapshot);
            if (keep_running < 0) {
                std.debug.print("UI frame failed: {s}\n", .{imgui.wiredeck_imgui_last_error() orelse "unknown error"});
                return error.UiFrameFailed;
            }
            if (keep_running == 0) break;

            const ui_changes = try syncUiChanges(state_store, &snapshot);
            var state_changed = ui_changes.changed;
            var routing_changed = ui_changes.routing_changed;
            if (lv2_ui_changed) state_changed = true;
            if (snapshot.request_open_plugin_ui_id[0] != 0) {
                defer clearBuffer(&snapshot.request_open_plugin_ui_id);
                lv2_ui_manager.openPluginUi(state_store, cStringSlice(&snapshot.request_open_plugin_ui_id)) catch |err| {
                    std.log.warn("lv2 ui open failed: {s}", .{@errorName(err)});
                };
            }
            const request_changes = try syncUiRequests(state_store, &snapshot);
            state_changed = state_changed or request_changes.changed;
            routing_changed = routing_changed or request_changes.routing_changed;
            if (routing_changed) {
                app.markRoutingDirty();
            }
            if (state_changed) {
                if (config_store) |store| {
                    store.save(state_store) catch |err| {
                        std.log.warn("config save failed: {s}", .{@errorName(err)});
                    };
                }
            }
            try syncTrayAutostartPreference(allocator, bridge);
            app.reconcileOutputRoutingIfNeeded();

            platform.nextFrame();
            if (config.max_frames) |max_frames| {
                if (platform.frame_count >= max_frames) break;
            }
        }
    }

    fn syncTrayAutostartPreference(allocator: std.mem.Allocator, bridge: *imgui.Bridge) !void {
        var enabled: c_int = 0;
        if (imgui.wiredeck_imgui_take_tray_autostart_request(bridge, &enabled) == 0) return;
        if (enabled != 0) {
            try enableAutostart(allocator);
        } else {
            disableAutostart(allocator) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
    }

    fn autostartDesktopPath(allocator: std.mem.Allocator) ![]u8 {
        const config_home = std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => blk: {
                const home = try std.process.getEnvVarOwned(allocator, "HOME");
                defer allocator.free(home);
                break :blk try std.fs.path.join(allocator, &.{ home, ".config" });
            },
            else => return err,
        };
        defer allocator.free(config_home);

        return std.fs.path.join(allocator, &.{ config_home, "autostart", "wiredeck.desktop" });
    }

    fn isAutostartEnabled(allocator: std.mem.Allocator) !bool {
        const desktop_path = try autostartDesktopPath(allocator);
        defer allocator.free(desktop_path);

        std.fs.accessAbsolute(desktop_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }

    fn enableAutostart(allocator: std.mem.Allocator) !void {
        const desktop_path = try autostartDesktopPath(allocator);
        defer allocator.free(desktop_path);

        const desktop_dir = std.fs.path.dirname(desktop_path) orelse return error.InvalidPath;
        std.fs.makeDirAbsolute(desktop_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const exe_path = try std.fs.selfExePathAlloc(allocator);
        defer allocator.free(exe_path);

        const desktop_entry = try std.fmt.allocPrint(
            allocator,
            \\[Desktop Entry]
            \\Type=Application
            \\Version=1.0
            \\Name=WireDeck
            \\Comment=WireDeck audio router
            \\Exec={s} --start-hidden
            \\Terminal=false
            \\Categories=AudioVideo;Audio;
            \\X-GNOME-Autostart-enabled=true
            \\
        ,
            .{exe_path},
        );
        defer allocator.free(desktop_entry);

        const file = try std.fs.createFileAbsolute(desktop_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(desktop_entry);
    }

    fn disableAutostart(allocator: std.mem.Allocator) !void {
        const desktop_path = try autostartDesktopPath(allocator);
        defer allocator.free(desktop_path);
        try std.fs.deleteFileAbsolute(desktop_path);
    }

    fn ensureSnapshotCapacity(
        allocator: std.mem.Allocator,
        state_store: *const StateStore,
        channels: *std.ArrayList(imgui.UiChannel),
        buses: *std.ArrayList(imgui.UiBus),
        sends: *std.ArrayList(imgui.UiSend),
        sources: *std.ArrayList(imgui.UiSource),
        channel_sources: *std.ArrayList(imgui.UiChannelSource),
        destinations: *std.ArrayList(imgui.UiDestination),
        bus_destinations: *std.ArrayList(imgui.UiBusDestination),
        channel_plugins: *std.ArrayList(imgui.UiChannelPlugin),
        channel_plugin_params: *std.ArrayList(imgui.UiChannelPluginParam),
        noise_models: *std.ArrayList(imgui.UiNoiseModel),
        plugin_descriptors: *std.ArrayList(imgui.UiPluginDescriptor),
        snapshot: *imgui.UiSnapshot,
    ) !void {
        const visible_bus_count = countVisibleBuses(state_store);
        const visible_send_count = countVisibleSends(state_store);
        const visible_bus_destination_count = countVisibleBusDestinations(state_store);

        try channels.resize(allocator, state_store.channels.items.len);
        try buses.resize(allocator, visible_bus_count);
        try sends.resize(allocator, visible_send_count);
        try sources.resize(allocator, state_store.sources.items.len);
        try channel_sources.resize(allocator, state_store.channel_sources.items.len);
        try destinations.resize(allocator, state_store.destinations.items.len);
        try bus_destinations.resize(allocator, visible_bus_destination_count);
        try channel_plugins.resize(allocator, state_store.channel_plugins.items.len);
        try channel_plugin_params.resize(allocator, state_store.channel_plugin_params.items.len);
        try noise_models.resize(allocator, 0);
        try plugin_descriptors.resize(allocator, state_store.plugin_descriptors.items.len);

        snapshot.channels = channels.items.ptr;
        snapshot.channel_count = @intCast(channels.items.len);
        snapshot.buses = buses.items.ptr;
        snapshot.bus_count = @intCast(buses.items.len);
        snapshot.sends = sends.items.ptr;
        snapshot.send_count = @intCast(sends.items.len);
        snapshot.sources = sources.items.ptr;
        snapshot.source_count = @intCast(sources.items.len);
        snapshot.channel_sources = channel_sources.items.ptr;
        snapshot.channel_source_count = @intCast(channel_sources.items.len);
        snapshot.destinations = destinations.items.ptr;
        snapshot.destination_count = @intCast(destinations.items.len);
        snapshot.bus_destinations = bus_destinations.items.ptr;
        snapshot.bus_destination_count = @intCast(bus_destinations.items.len);
        snapshot.channel_plugins = channel_plugins.items.ptr;
        snapshot.channel_plugin_count = @intCast(channel_plugins.items.len);
        snapshot.channel_plugin_params = channel_plugin_params.items.ptr;
        snapshot.channel_plugin_param_count = @intCast(channel_plugin_params.items.len);
        snapshot.noise_models = noise_models.items.ptr;
        snapshot.noise_model_count = 0;
        snapshot.plugin_descriptors = plugin_descriptors.items.ptr;
        snapshot.plugin_descriptor_count = @intCast(plugin_descriptors.items.len);
    }

    fn rebuildUiSnapshot(
        state_store: *const StateStore,
        snapshot: *imgui.UiSnapshot,
        recent_event_labels: *[max_recent_events][event_label_capacity:0]u8,
        ui_strings: *UiStringStorage,
    ) !void {
        ui_strings.clear();
        snapshot.active_profile = try ui_strings.append(state_store.active_profile);
        snapshot.channel_feed_kind = @intFromEnum(state_store.channel_feed);
        snapshot.destination_feed_kind = @intFromEnum(state_store.destination_feed);
        snapshot.event_count = 0;
        snapshot.recent_event_count = 0;
        _ = recent_event_labels;

        for (state_store.channels.items, 0..) |channel, index| {
            snapshot.channels[index] = .{
                .id = try ui_strings.append(channel.id),
                .label = try ui_strings.append(channel.label),
                .subtitle = try ui_strings.append(channel.subtitle),
                .bound_source_id = try ui_strings.append(channel.bound_source_id orelse ""),
                .source_kind = channel.source_kind,
                .icon_name = try ui_strings.append(channel.icon_name),
                .icon_path = try ui_strings.append(channel.icon_path),
                .input_bus_id = try ui_strings.append(channel.input_bus_id orelse ""),
                .meter_stage = @intFromEnum(channel.meter_stage),
                .level_left = channel.level_left,
                .level_right = channel.level_right,
                .level = channel.level,
                .volume = channel.volume,
                .muted = @intFromBool(channel.muted),
            };
        }
        var bus_index: usize = 0;
        for (state_store.buses.items) |bus| {
            if (bus.hidden) continue;
            const levels = computeBusLevels(state_store, bus.id, bus.volume, bus.muted);
            snapshot.buses[bus_index] = .{
                .id = try ui_strings.append(bus.id),
                .label = try ui_strings.append(bus.label),
                .role = @intFromEnum(bus.role),
                .hidden = @intFromBool(bus.hidden),
                .level_left = levels.left,
                .level_right = levels.right,
                .level = levels.level,
                .volume = bus.volume,
                .muted = @intFromBool(bus.muted),
                .expose_as_microphone = @intFromBool(bus.expose_as_microphone),
                .expose_on_web = @intFromBool(bus.expose_on_web),
            };
            bus_index += 1;
        }
        var send_index: usize = 0;
        for (state_store.sends.items) |send| {
            if (!isVisibleBus(state_store, send.bus_id)) continue;
            snapshot.sends[send_index] = .{
                .channel_id = try ui_strings.append(send.channel_id),
                .bus_id = try ui_strings.append(send.bus_id),
                .gain = send.gain,
                .enabled = @intFromBool(send.enabled),
                .pre_fader = @intFromBool(send.pre_fader),
            };
            send_index += 1;
        }
        for (state_store.sources.items, 0..) |source, index| {
            snapshot.sources[index] = .{
                .id = try ui_strings.append(source.id),
                .label = try ui_strings.append(source.label),
                .subtitle = try ui_strings.append(source.subtitle),
                .icon_name = try ui_strings.append(source.icon_name),
                .icon_path = try ui_strings.append(source.icon_path),
                .kind = @intFromEnum(source.kind),
                .level_left = source.level_left,
                .level_right = source.level_right,
                .level = source.level,
                .muted = @intFromBool(source.muted),
            };
        }
        for (state_store.channel_sources.items, 0..) |channel_source, index| {
            snapshot.channel_sources[index] = .{
                .channel_id = try ui_strings.append(channel_source.channel_id),
                .source_id = try ui_strings.append(channel_source.source_id),
                .enabled = @intFromBool(channel_source.enabled),
            };
        }
        for (state_store.destinations.items, 0..) |destination, index| {
            snapshot.destinations[index] = .{
                .id = try ui_strings.append(destination.id),
                .label = try ui_strings.append(destination.label),
                .subtitle = try ui_strings.append(destination.subtitle),
                .kind = @intFromEnum(destination.kind),
                .level_left = destination.level_left,
                .level_right = destination.level_right,
                .level = destination.level,
            };
        }
        var bus_destination_index: usize = 0;
        for (state_store.bus_destinations.items) |bus_destination| {
            if (!isVisibleBus(state_store, bus_destination.bus_id)) continue;
            if (findDestination(state_store, bus_destination.destination_id) == null) continue;
            snapshot.bus_destinations[bus_destination_index] = .{
                .bus_id = try ui_strings.append(bus_destination.bus_id),
                .destination_id = try ui_strings.append(bus_destination.destination_id),
                .enabled = @intFromBool(bus_destination.enabled),
            };
            bus_destination_index += 1;
        }
        for (state_store.channel_plugins.items, 0..) |channel_plugin, index| {
            snapshot.channel_plugins[index] = .{
                .id = try ui_strings.append(channel_plugin.id),
                .channel_id = try ui_strings.append(channel_plugin.channel_id),
                .descriptor_id = try ui_strings.append(channel_plugin.descriptor_id),
                .label = try ui_strings.append(channel_plugin.label),
                .backend = @intFromEnum(channel_plugin.backend),
                .enabled = @intFromBool(channel_plugin.enabled),
                .slot = @intCast(channel_plugin.slot),
            };
        }
        for (state_store.channel_plugin_params.items, 0..) |param, index| {
            const descriptor = findDescriptorForPlugin(state_store, param.plugin_id);
            const port = if (descriptor) |value| findDescriptorControlPort(value, param.symbol) else null;
            snapshot.channel_plugin_params[index] = .{
                .plugin_id = try ui_strings.append(param.plugin_id),
                .symbol = try ui_strings.append(param.symbol),
                .label = try ui_strings.append(if (port) |p| p.label else param.symbol),
                .value = param.value,
                .min_value = if (port) |p| p.min_value else 0.0,
                .max_value = if (port) |p| p.max_value else 1.0,
                .toggled = @intFromBool(if (port) |p| p.toggled else false),
                .integer = @intFromBool(if (port) |p| p.integer else false),
            };
        }
        for (state_store.plugin_descriptors.items, 0..) |descriptor, index| {
            snapshot.plugin_descriptors[index] = .{
                .id = try ui_strings.append(descriptor.id),
                .label = try ui_strings.append(descriptor.label),
                .backend = @intFromEnum(descriptor.backend),
                .category = try ui_strings.append(descriptor.category),
                .bundle_name = try ui_strings.append(descriptor.bundle_name),
                .has_custom_ui = @intFromBool(descriptor.has_custom_ui),
                .primary_ui_uri = try ui_strings.append(descriptor.primary_ui_uri),
            };
        }
    }

    fn syncUiChanges(state_store: *StateStore, snapshot: *const imgui.UiSnapshot) !MutationResult {
        var result: MutationResult = .{};
        for (state_store.channels.items, 0..) |*channel, index| {
            const next_volume = snapshot.channels[index].volume;
            const next_muted = snapshot.channels[index].muted != 0;
            const channel_changed = channel.volume != next_volume or channel.muted != next_muted;
            result.changed = result.changed or channel_changed;
            result.routing_changed = result.routing_changed or channel_changed;
            channel.volume = snapshot.channels[index].volume;
            channel.muted = next_muted;
        }
        var visible_bus_index: usize = 0;
        for (state_store.buses.items) |*bus| {
            if (bus.hidden) continue;
            const next_volume = snapshot.buses[visible_bus_index].volume;
            const next_muted = snapshot.buses[visible_bus_index].muted != 0;
            const next_expose_as_microphone = snapshot.buses[visible_bus_index].expose_as_microphone != 0;
            const next_expose_on_web = snapshot.buses[visible_bus_index].expose_on_web != 0;
            const bus_changed = bus.volume != next_volume or
                bus.muted != next_muted or
                bus.expose_as_microphone != next_expose_as_microphone or
                bus.expose_on_web != next_expose_on_web;
            result.changed = result.changed or bus_changed;
            result.routing_changed = result.routing_changed or bus_changed;
            bus.volume = next_volume;
            bus.muted = next_muted;
            bus.expose_as_microphone = next_expose_as_microphone;
            bus.expose_on_web = next_expose_on_web;
            visible_bus_index += 1;
        }
        var visible_send_index: usize = 0;
        for (state_store.sends.items) |*send| {
            if (!isVisibleBus(state_store, send.bus_id)) continue;
            const next_gain = snapshot.sends[visible_send_index].gain;
            const next_enabled = snapshot.sends[visible_send_index].enabled != 0;
            const next_pre_fader = snapshot.sends[visible_send_index].pre_fader != 0;
            const send_changed = send.gain != next_gain or send.enabled != next_enabled or send.pre_fader != next_pre_fader;
            result.changed = result.changed or send_changed;
            result.routing_changed = result.routing_changed or send_changed;
            send.gain = next_gain;
            send.enabled = next_enabled;
            send.pre_fader = next_pre_fader;
            visible_send_index += 1;
        }
        for (state_store.channel_sources.items, 0..) |*channel_source, index| {
            const next_enabled = snapshot.channel_sources[index].enabled != 0;
            const source_changed = channel_source.enabled != next_enabled;
            result.changed = result.changed or source_changed;
            result.routing_changed = result.routing_changed or source_changed;
            channel_source.enabled = next_enabled;
        }
        if (try syncChannelBindingSelections(state_store)) {
            result.changed = true;
            result.routing_changed = true;
        }
        var visible_bus_destination_index: usize = 0;
        for (state_store.bus_destinations.items) |*bus_destination| {
            if (!isVisibleBus(state_store, bus_destination.bus_id)) continue;
            if (findDestination(state_store, bus_destination.destination_id) == null) continue;
            const next_enabled = snapshot.bus_destinations[visible_bus_destination_index].enabled != 0;
            const bus_destination_changed = bus_destination.enabled != next_enabled;
            result.changed = result.changed or bus_destination_changed;
            result.routing_changed = result.routing_changed or bus_destination_changed;
            bus_destination.enabled = next_enabled;
            visible_bus_destination_index += 1;
        }
        for (state_store.channel_plugins.items, 0..) |*channel_plugin, index| {
            const next_enabled = snapshot.channel_plugins[index].enabled != 0;
            const plugin_changed = state_store.setChannelPluginEnabled(channel_plugin.id, next_enabled);
            result.changed = result.changed or plugin_changed;
            result.routing_changed = result.routing_changed or plugin_changed;
        }
        if (syncAutomaticMeterStages(state_store)) {
            result.changed = true;
        }
        for (state_store.channel_plugin_params.items, 0..) |*param, index| {
            const next_value = snapshot.channel_plugin_params[index].value;
            result.changed = result.changed or param.value != next_value;
            param.value = next_value;
        }
        return result;
    }

    fn syncUiRequests(state_store: *StateStore, snapshot: *imgui.UiSnapshot) !MutationResult {
        var result: MutationResult = .{};
        if (snapshot.request_select_source_id[0] != 0) {
            try addChannelFromSource(state_store, cStringSlice(&snapshot.request_select_source_id));
            clearBuffer(&snapshot.request_select_source_id);
            result.changed = true;
            result.routing_changed = true;
        } else if (snapshot.request_add_input != 0) {
            snapshot.request_add_input = 0;
        }
        if (snapshot.request_add_output != 0) {
            snapshot.request_add_output = 0;
            try addBus(state_store);
            result.changed = true;
            result.routing_changed = true;
        }
        if (snapshot.request_rename_input_id[0] != 0) {
            const id = cStringSlice(&snapshot.request_rename_input_id);
            const label = cStringSlice(&snapshot.request_rename_input_label);
            if (findChannel(state_store, id)) |channel| {
                try replaceOwnedString(state_store.allocator, &channel.label, label);
                result.changed = true;
            }
            clearBuffer(&snapshot.request_rename_input_id);
            clearBuffer(&snapshot.request_rename_input_label);
        }
        if (snapshot.request_rename_output_id[0] != 0) {
            const id = cStringSlice(&snapshot.request_rename_output_id);
            const label = cStringSlice(&snapshot.request_rename_output_label);
            if (findBus(state_store, id)) |bus| {
                try replaceOwnedString(state_store.allocator, &bus.label, label);
                result.changed = true;
                result.routing_changed = true;
            }
            clearBuffer(&snapshot.request_rename_output_id);
            clearBuffer(&snapshot.request_rename_output_label);
        }
        if (snapshot.request_delete_input_id[0] != 0) {
            try deleteChannel(state_store, cStringSlice(&snapshot.request_delete_input_id));
            clearBuffer(&snapshot.request_delete_input_id);
            result.changed = true;
            result.routing_changed = true;
        }
        if (snapshot.request_delete_output_id[0] != 0) {
            try deleteBus(state_store, cStringSlice(&snapshot.request_delete_output_id));
            clearBuffer(&snapshot.request_delete_output_id);
            result.changed = true;
            result.routing_changed = true;
        }
        if (snapshot.request_add_plugin_channel_id[0] != 0 and snapshot.request_add_plugin_descriptor_id[0] != 0) {
            try addPluginToChannel(state_store, cStringSlice(&snapshot.request_add_plugin_channel_id), cStringSlice(&snapshot.request_add_plugin_descriptor_id));
            clearBuffer(&snapshot.request_add_plugin_channel_id);
            clearBuffer(&snapshot.request_add_plugin_descriptor_id);
            _ = syncAutomaticMeterStages(state_store);
            result.changed = true;
            result.routing_changed = true;
        }
        if (snapshot.request_remove_plugin_id[0] != 0) {
            try removePlugin(state_store, cStringSlice(&snapshot.request_remove_plugin_id));
            clearBuffer(&snapshot.request_remove_plugin_id);
            _ = syncAutomaticMeterStages(state_store);
            result.changed = true;
            result.routing_changed = true;
        }
        if (snapshot.request_move_plugin_id[0] != 0 and snapshot.request_move_plugin_delta != 0) {
            if (movePlugin(state_store, cStringSlice(&snapshot.request_move_plugin_id), snapshot.request_move_plugin_delta)) {
                result.changed = true;
                result.routing_changed = true;
            }
            clearBuffer(&snapshot.request_move_plugin_id);
            snapshot.request_move_plugin_delta = 0;
        }
        if (snapshot.request_select_noise_model_path[0] != 0) clearBuffer(&snapshot.request_select_noise_model_path);
        return result;
    }
};

fn syncAutomaticMeterStages(state_store: *StateStore) bool {
    var changed = false;
    for (state_store.channels.items) |*channel| {
        const desired_stage: channels_mod.MeterStage = if (channelHasEnabledLv2Plugin(state_store, channel.id))
            .post_fx
        else
            .input;
        if (channel.meter_stage == desired_stage) continue;
        channel.meter_stage = desired_stage;
        changed = true;
    }
    return changed;
}

fn channelHasEnabledLv2Plugin(state_store: *const StateStore, channel_id: []const u8) bool {
    for (state_store.channel_plugins.items) |channel_plugin| {
        if (!channel_plugin.enabled) continue;
        if (channel_plugin.backend != .lv2) continue;
        if (std.mem.eql(u8, channel_plugin.channel_id, channel_id)) return true;
    }
    return false;
}

const BusLevels = struct {
    left: f32,
    right: f32,
    level: f32,
};

fn computeBusLevels(state_store: *const StateStore, bus_id: []const u8, bus_volume: f32, bus_muted: bool) BusLevels {
    if (bus_muted) return .{ .left = 0.0, .right = 0.0, .level = 0.0 };

    var left_energy: f32 = 0.0;
    var right_energy: f32 = 0.0;
    var contributors: usize = 0;

    for (state_store.sends.items) |send| {
        if (!send.enabled) continue;
        if (!std.mem.eql(u8, send.bus_id, bus_id)) continue;

        const channel = findChannelConst(state_store, send.channel_id) orelse continue;
        if (channel.muted) continue;

        const channel_gain = std.math.clamp(channel.volume * send.gain * bus_volume, 0.0, 4.0);
        const left = std.math.clamp(channel.level_left * channel_gain, 0.0, 1.0);
        const right = std.math.clamp(channel.level_right * channel_gain, 0.0, 1.0);
        if (left <= 0.00001 and right <= 0.00001) continue;

        left_energy += left * left;
        right_energy += right * right;
        contributors += 1;
    }

    if (contributors == 0) return .{ .left = 0.0, .right = 0.0, .level = 0.0 };

    const count: f32 = @floatFromInt(contributors);
    const left = std.math.clamp(@sqrt(left_energy / count), 0.0, 1.0);
    const right = std.math.clamp(@sqrt(right_energy / count), 0.0, 1.0);
    return .{
        .left = left,
        .right = right,
        .level = @max(left, right),
    };
}

fn addChannelFromSource(state_store: *StateStore, source_id: []const u8) !void {
    const selected_source = findSource(state_store, source_id) orelse return;
    if (findChannelByBoundSource(state_store, source_id) != null) return;

    const index = nextGeneratedIndexForChannels(state_store);
    const id = try std.fmt.allocPrint(state_store.allocator, "source-strip-{d}", .{index});
    defer state_store.allocator.free(id);
    const input_bus_id = try std.fmt.allocPrint(state_store.allocator, "input-stage-{d}", .{index});
    defer state_store.allocator.free(input_bus_id);

    try state_store.addBus(.{
        .id = input_bus_id,
        .label = selected_source.label,
        .role = .input_stage,
        .hidden = true,
    });
    try state_store.addChannel(.{
        .id = id,
        .label = selected_source.label,
        .subtitle = selected_source.subtitle,
        .bound_source_id = selected_source.id,
        .source_kind = @intFromEnum(selected_source.kind),
        .icon_name = selected_source.icon_name,
        .icon_path = selected_source.icon_path,
        .input_bus_id = input_bus_id,
        .meter_stage = .input,
    });
    const channel_id = state_store.channels.items[state_store.channels.items.len - 1].id;
    for (state_store.sources.items) |available_source| {
        try state_store.addChannelSource(.{
            .channel_id = channel_id,
            .source_id = available_source.id,
            .enabled = std.mem.eql(u8, available_source.id, source_id),
        });
    }
    for (state_store.buses.items) |bus| {
        try state_store.addSend(.{ .channel_id = channel_id, .bus_id = bus.id, .enabled = false });
    }
}

fn addBus(state_store: *StateStore) !void {
    const index = nextGeneratedIndexForBuses(state_store);
    const id = try std.fmt.allocPrint(state_store.allocator, "bus-{d}", .{index});
    defer state_store.allocator.free(id);
    const label = try std.fmt.allocPrint(state_store.allocator, "Bus {d}", .{index});
    defer state_store.allocator.free(label);
    try state_store.addBus(.{ .id = id, .label = label });
    const bus_id = state_store.buses.items[state_store.buses.items.len - 1].id;
    for (state_store.channels.items) |channel| {
        try state_store.addSend(.{ .channel_id = channel.id, .bus_id = bus_id, .enabled = false });
    }
    for (state_store.destinations.items) |destination| {
        try state_store.addBusDestination(.{ .bus_id = bus_id, .destination_id = destination.id, .enabled = false });
    }
}

fn deleteChannel(state_store: *StateStore, id: []const u8) !void {
    var input_bus_id: ?[]const u8 = null;
    if (findChannelIndex(state_store, id)) |index| {
        input_bus_id = state_store.channels.items[index].input_bus_id;
        freeChannel(state_store.allocator, state_store.channels.orderedRemove(index));
    }
    var i: usize = 0;
    while (i < state_store.channel_sources.items.len) {
        if (std.mem.eql(u8, state_store.channel_sources.items[i].channel_id, id)) {
            freeChannelSource(state_store.allocator, state_store.channel_sources.orderedRemove(i));
        } else i += 1;
    }
    i = 0;
    while (i < state_store.sends.items.len) {
        if (std.mem.eql(u8, state_store.sends.items[i].channel_id, id)) {
            freeSend(state_store.allocator, state_store.sends.orderedRemove(i));
        } else i += 1;
    }
    i = 0;
    while (i < state_store.channel_plugins.items.len) {
        if (std.mem.eql(u8, state_store.channel_plugins.items[i].channel_id, id)) {
            const plugin_id = state_store.channel_plugins.items[i].id;
            try removePlugin(state_store, plugin_id);
        } else i += 1;
    }
    if (input_bus_id) |owned_bus_id| {
        try deleteBus(state_store, owned_bus_id);
    }
}

fn deleteBus(state_store: *StateStore, id: []const u8) !void {
    if (findBusIndex(state_store, id)) |index| freeBus(state_store.allocator, state_store.buses.orderedRemove(index));
    var i: usize = 0;
    while (i < state_store.sends.items.len) {
        if (std.mem.eql(u8, state_store.sends.items[i].bus_id, id)) {
            freeSend(state_store.allocator, state_store.sends.orderedRemove(i));
        } else i += 1;
    }
    i = 0;
    while (i < state_store.bus_destinations.items.len) {
        if (std.mem.eql(u8, state_store.bus_destinations.items[i].bus_id, id)) {
            freeBusDestination(state_store.allocator, state_store.bus_destinations.orderedRemove(i));
        } else i += 1;
    }
}

fn addPluginToChannel(state_store: *StateStore, channel_id: []const u8, descriptor_id: []const u8) !void {
    const descriptor = findPluginDescriptor(state_store, descriptor_id) orelse return;
    const next_index = nextGeneratedIndexForPlugins(state_store);
    const plugin_id = try std.fmt.allocPrint(state_store.allocator, "plugin-{d}", .{next_index});
    defer state_store.allocator.free(plugin_id);
    try state_store.addChannelPlugin(.{
        .id = plugin_id,
        .channel_id = channel_id,
        .descriptor_id = descriptor.id,
        .label = descriptor.label,
        .backend = descriptor.backend,
        .enabled = true,
        .slot = nextPluginSlotForChannel(state_store, channel_id),
    });
    const owned_plugin_id = state_store.channel_plugins.items[state_store.channel_plugins.items.len - 1].id;
    normalizeChannelPluginSlots(state_store, channel_id);
    sortChannelPluginsBySlot(state_store);
    for (descriptor.control_ports) |port| {
        if (port.is_output) continue;
        try state_store.addChannelPluginParam(.{ .plugin_id = owned_plugin_id, .symbol = port.symbol, .value = port.default_value });
    }
    _ = state_store.setChannelPluginEnabled(owned_plugin_id, true);
}

fn removePlugin(state_store: *StateStore, id: []const u8) !void {
    var affected_channel_id: ?[]u8 = null;
    if (findPluginIndex(state_store, id)) |index| {
        affected_channel_id = try state_store.allocator.dupe(u8, state_store.channel_plugins.items[index].channel_id);
        freeChannelPlugin(state_store.allocator, state_store.channel_plugins.orderedRemove(index));
    }
    defer if (affected_channel_id) |owned| state_store.allocator.free(owned);
    var i: usize = 0;
    while (i < state_store.channel_plugin_params.items.len) {
        if (std.mem.eql(u8, state_store.channel_plugin_params.items[i].plugin_id, id)) {
            freeChannelPluginParam(state_store.allocator, state_store.channel_plugin_params.orderedRemove(i));
        } else i += 1;
    }
    if (affected_channel_id) |channel_id| {
        normalizeChannelPluginSlots(state_store, channel_id);
        sortChannelPluginsBySlot(state_store);
    }
}

fn movePlugin(state_store: *StateStore, plugin_id: []const u8, delta: i32) bool {
    const plugin_index = findPluginIndex(state_store, plugin_id) orelse return false;
    const channel_id = state_store.channel_plugins.items[plugin_index].channel_id;
    var current_position: usize = 0;
    var target_position: ?usize = null;
    var ordered_count: usize = 0;

    for (state_store.channel_plugins.items) |plugin| {
        if (!std.mem.eql(u8, plugin.channel_id, channel_id)) continue;
        if (std.mem.eql(u8, plugin.id, plugin_id)) {
            current_position = ordered_count;
        }
        ordered_count += 1;
    }
    if (ordered_count <= 1) return false;
    if (delta < 0) {
        if (current_position == 0) return false;
        target_position = current_position - 1;
    } else {
        if (current_position + 1 >= ordered_count) return false;
        target_position = current_position + 1;
    }

    var current_plugin: ?*plugins_mod.ChannelPlugin = null;
    var target_plugin: ?*plugins_mod.ChannelPlugin = null;
    ordered_count = 0;
    for (state_store.channel_plugins.items) |*plugin| {
        if (!std.mem.eql(u8, plugin.channel_id, channel_id)) continue;
        if (ordered_count == current_position) current_plugin = plugin;
        if (ordered_count == target_position.?) target_plugin = plugin;
        ordered_count += 1;
    }
    if (current_plugin == null or target_plugin == null) return false;

    const slot = current_plugin.?.slot;
    current_plugin.?.slot = target_plugin.?.slot;
    target_plugin.?.slot = slot;
    normalizeChannelPluginSlots(state_store, channel_id);
    sortChannelPluginsBySlot(state_store);
    return true;
}

fn nextPluginSlotForChannel(state_store: *const StateStore, channel_id: []const u8) u32 {
    var max_slot: u32 = 0;
    var found = false;
    for (state_store.channel_plugins.items) |plugin| {
        if (!std.mem.eql(u8, plugin.channel_id, channel_id)) continue;
        max_slot = @max(max_slot, plugin.slot);
        found = true;
    }
    return if (found) max_slot + 1 else 0;
}

fn normalizeChannelPluginSlots(state_store: *StateStore, channel_id: []const u8) void {
    var changed = true;
    while (changed) {
        changed = false;
        var i: usize = 0;
        while (i < state_store.channel_plugins.items.len) : (i += 1) {
            var j: usize = i + 1;
            while (j < state_store.channel_plugins.items.len) : (j += 1) {
                const lhs = state_store.channel_plugins.items[i];
                const rhs = state_store.channel_plugins.items[j];
                if (!std.mem.eql(u8, lhs.channel_id, channel_id) or !std.mem.eql(u8, rhs.channel_id, channel_id)) continue;
                if (lhs.slot > rhs.slot) {
                    std.mem.swap(plugins_mod.ChannelPlugin, &state_store.channel_plugins.items[i], &state_store.channel_plugins.items[j]);
                    changed = true;
                }
            }
        }
    }
    var slot: u32 = 0;
    for (state_store.channel_plugins.items) |*plugin| {
        if (!std.mem.eql(u8, plugin.channel_id, channel_id)) continue;
        plugin.slot = slot;
        slot += 1;
    }
}

fn sortChannelPluginsBySlot(state_store: *StateStore) void {
    std.mem.sort(plugins_mod.ChannelPlugin, state_store.channel_plugins.items, {}, struct {
        fn lessThan(_: void, lhs: plugins_mod.ChannelPlugin, rhs: plugins_mod.ChannelPlugin) bool {
            const channel_cmp = std.mem.order(u8, lhs.channel_id, rhs.channel_id);
            if (channel_cmp != .eq) return channel_cmp == .lt;
            if (lhs.slot != rhs.slot) return lhs.slot < rhs.slot;
            return std.mem.order(u8, lhs.id, rhs.id) == .lt;
        }
    }.lessThan);
}

fn syncChannelBindingSelections(state_store: *StateStore) !bool {
    var changed = false;

    for (state_store.channels.items) |*channel| {
        var selected_source_id: ?[]const u8 = null;
        var selected_source: ?@TypeOf(state_store.sources.items[0]) = null;

        for (state_store.channel_sources.items) |*channel_source| {
            if (!std.mem.eql(u8, channel_source.channel_id, channel.id)) continue;
            if (!channel_source.enabled) continue;

            if (selected_source_id == null) {
                selected_source_id = channel_source.source_id;
                selected_source = findSource(state_store, channel_source.source_id);
                continue;
            }

            channel_source.enabled = false;
            changed = true;
        }

        if (!optionalSlicesEql(channel.bound_source_id, selected_source_id)) {
            try replaceOwnedOptionalString(state_store.allocator, &channel.bound_source_id, selected_source_id);
            changed = true;
        }

        if (selected_source) |source| {
            if (!std.mem.eql(u8, channel.subtitle, source.subtitle)) {
                try replaceOwnedString(state_store.allocator, &channel.subtitle, source.subtitle);
                changed = true;
            }
            if (!std.mem.eql(u8, channel.icon_name, source.icon_name)) {
                try replaceOwnedString(state_store.allocator, &channel.icon_name, source.icon_name);
                changed = true;
            }
            if (!std.mem.eql(u8, channel.icon_path, source.icon_path)) {
                try replaceOwnedString(state_store.allocator, &channel.icon_path, source.icon_path);
                changed = true;
            }
            if (channel.source_kind != @intFromEnum(source.kind)) {
                channel.source_kind = @intFromEnum(source.kind);
                changed = true;
            }
        }
    }

    return changed;
}

fn findChannel(state_store: *StateStore, id: []const u8) ?*channels_mod.Channel {
    for (state_store.channels.items) |*channel| {
        if (std.mem.eql(u8, channel.id, id)) return channel;
    }
    return null;
}

fn findChannelConst(state_store: *const StateStore, id: []const u8) ?channels_mod.Channel {
    for (state_store.channels.items) |channel| {
        if (std.mem.eql(u8, channel.id, id)) return channel;
    }
    return null;
}

fn findChannelByBoundSource(state_store: *StateStore, source_id: []const u8) ?*channels_mod.Channel {
    for (state_store.channels.items) |*channel| {
        if (channel.bound_source_id) |bound_source_id| {
            if (std.mem.eql(u8, bound_source_id, source_id)) return channel;
        }
    }
    return null;
}

fn findBus(state_store: *StateStore, id: []const u8) ?*buses_mod.Bus {
    for (state_store.buses.items) |*bus| {
        if (std.mem.eql(u8, bus.id, id)) return bus;
    }
    return null;
}

fn findSource(state_store: *StateStore, id: []const u8) ?@TypeOf(state_store.sources.items[0]) {
    for (state_store.sources.items) |source| {
        if (std.mem.eql(u8, source.id, id)) return source;
    }
    return null;
}

fn findChannelIndex(state_store: *StateStore, id: []const u8) ?usize {
    for (state_store.channels.items, 0..) |channel, index| {
        if (std.mem.eql(u8, channel.id, id)) return index;
    }
    return null;
}

fn findBusIndex(state_store: *StateStore, id: []const u8) ?usize {
    for (state_store.buses.items, 0..) |bus, index| {
        if (std.mem.eql(u8, bus.id, id)) return index;
    }
    return null;
}

fn findPluginIndex(state_store: *StateStore, id: []const u8) ?usize {
    for (state_store.channel_plugins.items, 0..) |plugin, index| {
        if (std.mem.eql(u8, plugin.id, id)) return index;
    }
    return null;
}

fn findPluginDescriptor(state_store: *const StateStore, id: []const u8) ?plugin_host_mod.PluginDescriptor {
    for (state_store.plugin_descriptors.items) |descriptor| {
        if (std.mem.eql(u8, descriptor.id, id)) return descriptor;
    }
    return null;
}

fn findDescriptorForPlugin(state_store: *const StateStore, plugin_id: []const u8) ?plugin_host_mod.PluginDescriptor {
    for (state_store.channel_plugins.items) |plugin| {
        if (!std.mem.eql(u8, plugin.id, plugin_id)) continue;
        return findPluginDescriptor(state_store, plugin.descriptor_id);
    }
    return null;
}

fn findDescriptorControlPort(descriptor: plugin_host_mod.PluginDescriptor, symbol: []const u8) ?plugin_host_mod.PluginControlPort {
    for (descriptor.control_ports) |port| {
        if (std.mem.eql(u8, port.symbol, symbol)) return port;
    }
    return null;
}

fn replaceOwnedString(allocator: std.mem.Allocator, field: *[]const u8, value: []const u8) !void {
    const replacement = try allocator.dupe(u8, value);
    allocator.free(field.*);
    field.* = replacement;
}

fn replaceOwnedOptionalString(allocator: std.mem.Allocator, field: *?[]const u8, value: ?[]const u8) !void {
    const replacement = if (value) |slice| try allocator.dupe(u8, slice) else null;
    errdefer if (replacement) |owned| allocator.free(owned);

    if (field.*) |owned| allocator.free(owned);
    field.* = replacement;
}

fn freeChannel(allocator: std.mem.Allocator, channel: channels_mod.Channel) void {
    allocator.free(channel.id);
    allocator.free(channel.label);
    allocator.free(channel.subtitle);
    if (channel.bound_source_id) |value| allocator.free(value);
    allocator.free(channel.icon_name);
    allocator.free(channel.icon_path);
    if (channel.input_bus_id) |value| allocator.free(value);
}

fn nextGeneratedIndexForChannels(state_store: *const StateStore) usize {
    return nextGeneratedIndex(state_store.channels.items, "source-strip-");
}

fn nextGeneratedIndexForBuses(state_store: *const StateStore) usize {
    return nextGeneratedIndex(state_store.buses.items, "bus-");
}

fn nextGeneratedIndexForPlugins(state_store: *const StateStore) usize {
    return nextGeneratedIndex(state_store.channel_plugins.items, "plugin-");
}

fn nextGeneratedIndex(items: anytype, comptime prefix: []const u8) usize {
    var max_index: usize = 0;
    for (items) |item| {
        const parsed = parseGeneratedIndex(item.id, prefix) orelse continue;
        max_index = @max(max_index, parsed);
    }
    return max_index + 1;
}

fn parseGeneratedIndex(id: []const u8, comptime prefix: []const u8) ?usize {
    if (!std.mem.startsWith(u8, id, prefix)) return null;
    const suffix = id[prefix.len..];
    if (suffix.len == 0) return null;
    return std.fmt.parseInt(usize, suffix, 10) catch null;
}

fn optionalSlicesEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null and right == null) return true;
    if (left == null or right == null) return false;
    return std.mem.eql(u8, left.?, right.?);
}

fn freeBus(allocator: std.mem.Allocator, bus: buses_mod.Bus) void {
    allocator.free(bus.id);
    allocator.free(bus.label);
}

fn countVisibleBuses(state_store: *const StateStore) usize {
    var count: usize = 0;
    for (state_store.buses.items) |bus| {
        if (!bus.hidden) count += 1;
    }
    return count;
}

fn countVisibleSends(state_store: *const StateStore) usize {
    var count: usize = 0;
    for (state_store.sends.items) |send| {
        if (isVisibleBus(state_store, send.bus_id)) count += 1;
    }
    return count;
}

fn countVisibleBusDestinations(state_store: *const StateStore) usize {
    var count: usize = 0;
    for (state_store.bus_destinations.items) |bus_destination| {
        if (!isVisibleBus(state_store, bus_destination.bus_id)) continue;
        if (findDestination(state_store, bus_destination.destination_id) == null) continue;
        count += 1;
    }
    return count;
}

fn isVisibleBus(state_store: *const StateStore, bus_id: []const u8) bool {
    for (state_store.buses.items) |bus| {
        if (!std.mem.eql(u8, bus.id, bus_id)) continue;
        return !bus.hidden;
    }
    return false;
}

fn freeSend(allocator: std.mem.Allocator, send: sends_mod.Send) void {
    allocator.free(send.channel_id);
    allocator.free(send.bus_id);
}

fn freeChannelSource(allocator: std.mem.Allocator, channel_source: channel_sources_mod.ChannelSource) void {
    allocator.free(channel_source.channel_id);
    allocator.free(channel_source.source_id);
}

fn freeBusDestination(allocator: std.mem.Allocator, bus_destination: bus_destinations_mod.BusDestination) void {
    allocator.free(bus_destination.bus_id);
    allocator.free(bus_destination.destination_id);
    allocator.free(bus_destination.destination_sink_name);
    allocator.free(bus_destination.destination_label);
    allocator.free(bus_destination.destination_subtitle);
}

fn findDestination(state_store: *const StateStore, id: []const u8) ?destinations_mod.Destination {
    for (state_store.destinations.items) |destination| {
        if (std.mem.eql(u8, destination.id, id)) return destination;
    }
    return null;
}

fn freeChannelPlugin(allocator: std.mem.Allocator, plugin: plugins_mod.ChannelPlugin) void {
    allocator.free(plugin.id);
    allocator.free(plugin.channel_id);
    allocator.free(plugin.descriptor_id);
    allocator.free(plugin.label);
}

fn freeChannelPluginParam(allocator: std.mem.Allocator, param: plugins_mod.ChannelPluginParam) void {
    allocator.free(param.plugin_id);
    allocator.free(param.symbol);
}

fn zeroedBuffer(comptime len: usize) [len]u8 {
    return [_]u8{0} ** len;
}

fn clearBuffer(buffer: anytype) void {
    @memset(buffer[0..], 0);
}

fn cStringSlice(buffer: anytype) []const u8 {
    const slice = buffer[0..];
    const end = std.mem.indexOfScalar(u8, slice, 0) orelse slice.len;
    return slice[0..end];
}

const UiStringStorage = struct {
    allocator: std.mem.Allocator,
    values: std.ArrayList([:0]u8),

    fn init(allocator: std.mem.Allocator) UiStringStorage {
        return .{
            .allocator = allocator,
            .values = std.ArrayList([:0]u8).empty,
        };
    }

    fn deinit(self: *UiStringStorage) void {
        self.clear();
        self.values.deinit(self.allocator);
    }

    fn clear(self: *UiStringStorage) void {
        for (self.values.items) |value| self.allocator.free(value);
        self.values.clearRetainingCapacity();
    }

    fn append(self: *UiStringStorage, value: []const u8) ![*:0]const u8 {
        const owned = try self.allocator.dupeZ(u8, value);
        try self.values.append(self.allocator, owned);
        return owned.ptr;
    }
};
