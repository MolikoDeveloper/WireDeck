const std = @import("std");
const channels_mod = @import("../core/audio/channels.zig");
const buses_mod = @import("../core/audio/buses.zig");
const sources_mod = @import("../core/audio/sources.zig");
const channel_sources_mod = @import("../core/audio/channel_sources.zig");
const destinations_mod = @import("../core/audio/destinations.zig");
const bus_destinations_mod = @import("../core/audio/bus_destinations.zig");
const sends_mod = @import("../core/audio/sends.zig");
const plugins_mod = @import("../plugins/chain.zig");
const plugin_host_mod = @import("../plugins/host.zig");

pub const StateStore = struct {
    pub const DestinationFeed = enum {
        unavailable,
        pipewire,
    };

    pub const ChannelFeed = enum {
        bootstrap,
        pulse_pipewire,
    };

    allocator: std.mem.Allocator,
    active_profile: []const u8,
    active_profile_owned: bool,
    channel_feed: ChannelFeed,
    destination_feed: DestinationFeed,
    channels: std.ArrayList(channels_mod.Channel),
    buses: std.ArrayList(buses_mod.Bus),
    sources: std.ArrayList(sources_mod.Source),
    channel_sources: std.ArrayList(channel_sources_mod.ChannelSource),
    destinations: std.ArrayList(destinations_mod.Destination),
    bus_destinations: std.ArrayList(bus_destinations_mod.BusDestination),
    sends: std.ArrayList(sends_mod.Send),
    channel_plugins: std.ArrayList(plugins_mod.ChannelPlugin),
    channel_plugin_params: std.ArrayList(plugins_mod.ChannelPluginParam),
    plugin_descriptors: std.ArrayList(plugin_host_mod.PluginDescriptor),

    pub fn init(allocator: std.mem.Allocator) StateStore {
        return .{
            .allocator = allocator,
            .active_profile = "Default",
            .active_profile_owned = false,
            .channel_feed = .bootstrap,
            .destination_feed = .unavailable,
            .channels = .empty,
            .buses = .empty,
            .sources = .empty,
            .channel_sources = .empty,
            .destinations = .empty,
            .bus_destinations = .empty,
            .sends = .empty,
            .channel_plugins = .empty,
            .channel_plugin_params = .empty,
            .plugin_descriptors = .empty,
        };
    }

    pub fn deinit(self: *StateStore) void {
        if (self.active_profile_owned) self.allocator.free(self.active_profile);
        self.clearPluginDescriptors();
        self.clearChannelPluginParams();
        self.clearChannelPlugins();
        self.clearSends();
        self.clearBusDestinations();
        self.clearDestinations();
        self.clearChannelSources();
        self.clearSources();
        self.clearBuses();
        self.clearChannels();

        self.sends.deinit(self.allocator);
        self.bus_destinations.deinit(self.allocator);
        self.destinations.deinit(self.allocator);
        self.channel_sources.deinit(self.allocator);
        self.sources.deinit(self.allocator);
        self.buses.deinit(self.allocator);
        self.channels.deinit(self.allocator);
        self.channel_plugins.deinit(self.allocator);
        self.channel_plugin_params.deinit(self.allocator);
        self.plugin_descriptors.deinit(self.allocator);
    }

    pub fn setActiveProfile(self: *StateStore, value: []const u8) !void {
        const owned = try self.allocator.dupe(u8, value);
        if (self.active_profile_owned) self.allocator.free(self.active_profile);
        self.active_profile = owned;
        self.active_profile_owned = true;
    }

    pub fn addChannel(self: *StateStore, channel: channels_mod.Channel) !void {
        try self.channels.append(self.allocator, .{
            .id = try self.allocator.dupe(u8, channel.id),
            .label = try self.allocator.dupe(u8, channel.label),
            .subtitle = try self.allocator.dupe(u8, channel.subtitle),
            .bound_source_id = if (channel.bound_source_id) |value| try self.allocator.dupe(u8, value) else null,
            .source_kind = channel.source_kind,
            .icon_name = try self.allocator.dupe(u8, channel.icon_name),
            .icon_path = try self.allocator.dupe(u8, channel.icon_path),
            .custom_icon_name = try self.allocator.dupe(u8, channel.custom_icon_name),
            .custom_icon_path = try self.allocator.dupe(u8, channel.custom_icon_path),
            .input_bus_id = if (channel.input_bus_id) |value| try self.allocator.dupe(u8, value) else null,
            .meter_stage = channel.meter_stage,
            .level_left = channel.level_left,
            .level_right = channel.level_right,
            .level = channel.level,
            .volume = channel.volume,
            .muted = channel.muted,
        });
    }

    pub fn addBus(self: *StateStore, bus: buses_mod.Bus) !void {
        try self.buses.append(self.allocator, .{
            .id = try self.allocator.dupe(u8, bus.id),
            .label = try self.allocator.dupe(u8, bus.label),
            .role = bus.role,
            .hidden = bus.hidden,
            .volume = bus.volume,
            .muted = bus.muted,
            .expose_as_microphone = bus.expose_as_microphone,
            .expose_on_web = bus.expose_on_web,
        });
    }

    pub fn addSource(self: *StateStore, source: sources_mod.Source) !void {
        try self.sources.append(self.allocator, .{
            .id = try self.allocator.dupe(u8, source.id),
            .label = try self.allocator.dupe(u8, source.label),
            .subtitle = try self.allocator.dupe(u8, source.subtitle),
            .kind = source.kind,
            .process_binary = try self.allocator.dupe(u8, source.process_binary),
            .icon_name = try self.allocator.dupe(u8, source.icon_name),
            .icon_path = try self.allocator.dupe(u8, source.icon_path),
            .level_left = source.level_left,
            .level_right = source.level_right,
            .level = source.level,
            .muted = source.muted,
        });
    }

    pub fn addChannelSource(self: *StateStore, channel_source: channel_sources_mod.ChannelSource) !void {
        try self.channel_sources.append(self.allocator, .{
            .channel_id = try self.allocator.dupe(u8, channel_source.channel_id),
            .source_id = try self.allocator.dupe(u8, channel_source.source_id),
            .enabled = channel_source.enabled,
        });
    }

    pub fn addDestination(self: *StateStore, destination: destinations_mod.Destination) !void {
        try self.destinations.append(self.allocator, .{
            .id = try self.allocator.dupe(u8, destination.id),
            .label = try self.allocator.dupe(u8, destination.label),
            .subtitle = try self.allocator.dupe(u8, destination.subtitle),
            .kind = destination.kind,
            .level_left = destination.level_left,
            .level_right = destination.level_right,
            .level = destination.level,
            .pulse_sink_index = destination.pulse_sink_index,
            .pulse_sink_name = try self.allocator.dupe(u8, destination.pulse_sink_name),
            .pulse_card_index = destination.pulse_card_index,
            .pulse_card_profile = try self.allocator.dupe(u8, destination.pulse_card_profile),
        });
    }

    pub fn addBusDestination(self: *StateStore, bus_destination: bus_destinations_mod.BusDestination) !void {
        try self.bus_destinations.append(self.allocator, .{
            .bus_id = try self.allocator.dupe(u8, bus_destination.bus_id),
            .destination_id = try self.allocator.dupe(u8, bus_destination.destination_id),
            .destination_sink_name = try self.allocator.dupe(u8, bus_destination.destination_sink_name),
            .destination_label = try self.allocator.dupe(u8, bus_destination.destination_label),
            .destination_subtitle = try self.allocator.dupe(u8, bus_destination.destination_subtitle),
            .destination_kind = bus_destination.destination_kind,
            .enabled = bus_destination.enabled,
        });
    }

    pub fn addSend(self: *StateStore, send: sends_mod.Send) !void {
        try self.sends.append(self.allocator, .{
            .channel_id = try self.allocator.dupe(u8, send.channel_id),
            .bus_id = try self.allocator.dupe(u8, send.bus_id),
            .gain = send.gain,
            .enabled = send.enabled,
            .pre_fader = send.pre_fader,
        });
    }

    pub fn addChannelPlugin(self: *StateStore, channel_plugin: plugins_mod.ChannelPlugin) !void {
        try self.channel_plugins.append(self.allocator, .{
            .id = try self.allocator.dupe(u8, channel_plugin.id),
            .channel_id = try self.allocator.dupe(u8, channel_plugin.channel_id),
            .descriptor_id = try self.allocator.dupe(u8, channel_plugin.descriptor_id),
            .label = try self.allocator.dupe(u8, channel_plugin.label),
            .backend = channel_plugin.backend,
            .enabled = channel_plugin.enabled,
            .slot = channel_plugin.slot,
        });
    }

    pub fn addChannelPluginParam(self: *StateStore, param: plugins_mod.ChannelPluginParam) !void {
        try self.channel_plugin_params.append(self.allocator, .{
            .plugin_id = try self.allocator.dupe(u8, param.plugin_id),
            .symbol = try self.allocator.dupe(u8, param.symbol),
            .value = param.value,
        });
    }

    pub fn addPluginDescriptor(self: *StateStore, descriptor: plugin_host_mod.PluginDescriptor) !void {
        const ports = try self.allocator.alloc(plugin_host_mod.PluginControlPort, descriptor.control_ports.len);
        errdefer self.allocator.free(ports);

        for (descriptor.control_ports, 0..) |port, index| {
            ports[index] = .{
                .index = port.index,
                .symbol = try self.allocator.dupe(u8, port.symbol),
                .label = try self.allocator.dupe(u8, port.label),
                .is_output = port.is_output,
                .min_value = port.min_value,
                .max_value = port.max_value,
                .default_value = port.default_value,
                .toggled = port.toggled,
                .integer = port.integer,
                .enumeration = port.enumeration,
                .sync_kind = port.sync_kind,
            };
        }

        try self.plugin_descriptors.append(self.allocator, .{
            .id = try self.allocator.dupe(u8, descriptor.id),
            .label = try self.allocator.dupe(u8, descriptor.label),
            .backend = descriptor.backend,
            .category = try self.allocator.dupe(u8, descriptor.category),
            .bundle_name = try self.allocator.dupe(u8, descriptor.bundle_name),
            .control_ports = ports,
            .has_custom_ui = descriptor.has_custom_ui,
            .primary_ui_uri = try self.allocator.dupe(u8, descriptor.primary_ui_uri),
        });
    }

    pub fn findChannelPlugin(self: *StateStore, id: []const u8) ?*plugins_mod.ChannelPlugin {
        for (self.channel_plugins.items) |*plugin| {
            if (std.mem.eql(u8, plugin.id, id)) return plugin;
        }
        return null;
    }

    pub fn findPluginDescriptor(self: *StateStore, id: []const u8) ?*plugin_host_mod.PluginDescriptor {
        for (self.plugin_descriptors.items) |*descriptor| {
            if (std.mem.eql(u8, descriptor.id, id)) return descriptor;
        }
        return null;
    }

    pub fn findChannelPluginParam(self: *StateStore, plugin_id: []const u8, symbol: []const u8) ?*plugins_mod.ChannelPluginParam {
        for (self.channel_plugin_params.items) |*param| {
            if (!std.mem.eql(u8, param.plugin_id, plugin_id)) continue;
            if (std.mem.eql(u8, param.symbol, symbol)) return param;
        }
        return null;
    }

    pub fn ensureChannelPluginParam(self: *StateStore, plugin_id: []const u8, symbol: []const u8, default_value: f32) !*plugins_mod.ChannelPluginParam {
        if (self.findChannelPluginParam(plugin_id, symbol)) |param| return param;
        try self.addChannelPluginParam(.{
            .plugin_id = plugin_id,
            .symbol = symbol,
            .value = default_value,
        });
        return self.findChannelPluginParam(plugin_id, symbol).?;
    }

    pub fn setChannelPluginParamValue(self: *StateStore, plugin_id: []const u8, symbol: []const u8, value: f32) bool {
        const param = blk: {
            if (self.findChannelPluginParam(plugin_id, symbol)) |existing| break :blk existing;

            const channel_plugin = self.findChannelPlugin(plugin_id) orelse return false;
            const descriptor = self.findPluginDescriptor(channel_plugin.descriptor_id) orelse return false;
            const control_port = findDescriptorControlPort(descriptor.control_ports, symbol) orelse return false;
            _ = self.ensureChannelPluginParam(plugin_id, symbol, control_port.default_value) catch return false;
            break :blk self.findChannelPluginParam(plugin_id, symbol).?;
        };
        var changed = false;
        if (!std.math.approxEqAbs(f32, param.value, value, 0.00001)) {
            param.value = value;
            changed = true;
        }

        const channel_plugin = self.findChannelPlugin(plugin_id) orelse return changed;
        const descriptor = self.findPluginDescriptor(channel_plugin.descriptor_id) orelse return changed;
        const control_port = findDescriptorControlPort(descriptor.control_ports, symbol) orelse return changed;
        switch (control_port.sync_kind) {
            .none => return changed,
            .plugin_enabled => return self.setChannelPluginEnabled(plugin_id, value >= 0.5) or changed,
            .plugin_bypass => return self.setChannelPluginEnabled(plugin_id, value < 0.5) or changed,
        }
    }

    pub fn setChannelPluginEnabled(self: *StateStore, plugin_id: []const u8, enabled: bool) bool {
        const channel_plugin = self.findChannelPlugin(plugin_id) orelse return false;
        var changed = false;
        if (channel_plugin.enabled != enabled) {
            channel_plugin.enabled = enabled;
            changed = true;
        }

        const descriptor = self.findPluginDescriptor(channel_plugin.descriptor_id) orelse return changed;
        for (descriptor.control_ports) |control_port| {
            const target_value = switch (control_port.sync_kind) {
                .none => continue,
                .plugin_enabled => syncedToggleValue(control_port, enabled),
                .plugin_bypass => syncedToggleValue(control_port, !enabled),
            };
            const param = self.findChannelPluginParam(plugin_id, control_port.symbol) orelse continue;
            if (std.math.approxEqAbs(f32, param.value, target_value, 0.00001)) continue;
            param.value = target_value;
            changed = true;
        }
        return changed;
    }

    pub fn ensurePluginParamsMatchDescriptors(self: *StateStore) !bool {
        var changed = false;
        for (self.channel_plugins.items) |channel_plugin| {
            const descriptor = self.findPluginDescriptor(channel_plugin.descriptor_id) orelse continue;
            for (descriptor.control_ports) |control_port| {
                if (self.findChannelPluginParam(channel_plugin.id, control_port.symbol) != null) continue;
                _ = try self.ensureChannelPluginParam(channel_plugin.id, control_port.symbol, control_port.default_value);
                changed = true;
            }
        }
        return changed;
    }

    pub fn clearChannels(self: *StateStore) void {
        for (self.channels.items) |item| {
            self.allocator.free(item.id);
            self.allocator.free(item.label);
            self.allocator.free(item.subtitle);
            if (item.bound_source_id) |value| self.allocator.free(value);
            self.allocator.free(item.icon_name);
            self.allocator.free(item.icon_path);
            self.allocator.free(item.custom_icon_name);
            self.allocator.free(item.custom_icon_path);
            if (item.input_bus_id) |value| self.allocator.free(value);
        }
        self.channels.clearRetainingCapacity();
    }

    pub fn clearBuses(self: *StateStore) void {
        for (self.buses.items) |item| {
            self.allocator.free(item.id);
            self.allocator.free(item.label);
        }
        self.buses.clearRetainingCapacity();
    }

    pub fn clearSources(self: *StateStore) void {
        for (self.sources.items) |item| {
            self.allocator.free(item.id);
            self.allocator.free(item.label);
            self.allocator.free(item.subtitle);
            self.allocator.free(item.process_binary);
            self.allocator.free(item.icon_name);
            self.allocator.free(item.icon_path);
        }
        self.sources.clearRetainingCapacity();
    }

    pub fn clearChannelSources(self: *StateStore) void {
        for (self.channel_sources.items) |item| {
            self.allocator.free(item.channel_id);
            self.allocator.free(item.source_id);
        }
        self.channel_sources.clearRetainingCapacity();
    }

    pub fn clearDestinations(self: *StateStore) void {
        for (self.destinations.items) |item| {
            self.allocator.free(item.id);
            self.allocator.free(item.label);
            self.allocator.free(item.subtitle);
            self.allocator.free(item.pulse_sink_name);
            self.allocator.free(item.pulse_card_profile);
        }
        self.destinations.clearRetainingCapacity();
    }

    pub fn clearBusDestinations(self: *StateStore) void {
        for (self.bus_destinations.items) |item| {
            self.allocator.free(item.bus_id);
            self.allocator.free(item.destination_id);
            self.allocator.free(item.destination_sink_name);
            self.allocator.free(item.destination_label);
            self.allocator.free(item.destination_subtitle);
        }
        self.bus_destinations.clearRetainingCapacity();
    }

    pub fn clearSends(self: *StateStore) void {
        for (self.sends.items) |item| {
            self.allocator.free(item.channel_id);
            self.allocator.free(item.bus_id);
        }
        self.sends.clearRetainingCapacity();
    }

    pub fn clearChannelPlugins(self: *StateStore) void {
        for (self.channel_plugins.items) |item| {
            self.allocator.free(item.id);
            self.allocator.free(item.channel_id);
            self.allocator.free(item.descriptor_id);
            self.allocator.free(item.label);
        }
        self.channel_plugins.clearRetainingCapacity();
    }

    pub fn clearChannelPluginParams(self: *StateStore) void {
        for (self.channel_plugin_params.items) |item| {
            self.allocator.free(item.plugin_id);
            self.allocator.free(item.symbol);
        }
        self.channel_plugin_params.clearRetainingCapacity();
    }

    pub fn clearPluginDescriptors(self: *StateStore) void {
        for (self.plugin_descriptors.items) |descriptor| {
            self.allocator.free(descriptor.id);
            self.allocator.free(descriptor.label);
            self.allocator.free(descriptor.category);
            self.allocator.free(descriptor.bundle_name);
            self.allocator.free(descriptor.primary_ui_uri);
            for (descriptor.control_ports) |port| {
                self.allocator.free(port.symbol);
                self.allocator.free(port.label);
            }
            self.allocator.free(descriptor.control_ports);
        }
        self.plugin_descriptors.clearRetainingCapacity();
    }
};

fn findDescriptorControlPort(ports: []const plugin_host_mod.PluginControlPort, symbol: []const u8) ?plugin_host_mod.PluginControlPort {
    for (ports) |port| {
        if (std.mem.eql(u8, port.symbol, symbol)) return port;
    }
    return null;
}

fn syncedToggleValue(port: plugin_host_mod.PluginControlPort, enabled: bool) f32 {
    const low = std.math.clamp(0.0, port.min_value, port.max_value);
    const high = std.math.clamp(1.0, port.min_value, port.max_value);
    return if (enabled) high else low;
}
