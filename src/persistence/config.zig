const std = @import("std");
const StateStore = @import("../app/state_store.zig").StateStore;
const channels_mod = @import("../core/audio/channels.zig");
const buses_mod = @import("../core/audio/buses.zig");
const sources_mod = @import("../core/audio/sources.zig");
const destinations_mod = @import("../core/audio/destinations.zig");
const sends_mod = @import("../core/audio/sends.zig");
const network_mod = @import("../core/audio/network.zig");
const plugins_mod = @import("../plugins/chain.zig");
const host_mod = @import("../plugins/host.zig");

const StoredChannel = struct {
    id: []const u8,
    label: []const u8,
    subtitle: []const u8,
    bound_source_id: ?[]const u8 = null,
    source_kind: u8 = 2,
    icon_name: []const u8 = "",
    icon_path: []const u8 = "",
    custom_icon_name: []const u8 = "",
    custom_icon_path: []const u8 = "",
    source_ref_id: ?[]const u8 = null,
    source_ref_label: ?[]const u8 = null,
    source_ref_subtitle: ?[]const u8 = null,
    source_ref_process_binary: ?[]const u8 = null,
    source_ref_kind: ?sources_mod.SourceKind = null,
    input_bus_id: ?[]const u8 = null,
    meter_stage: channels_mod.MeterStage = .input,
    volume: f32 = 1.0,
    muted: bool = false,
};

const StoredBus = struct {
    id: []const u8,
    label: []const u8,
    role: buses_mod.BusRole = .mixer,
    hidden: bool = false,
    volume: f32 = 1.0,
    muted: bool = false,
    expose_as_microphone: bool = false,
    share_on_network: bool = false,
    expose_on_web: bool = false,
};

const StoredBusDestination = struct {
    bus_id: []const u8,
    destination_id: []const u8,
    destination_sink_name: ?[]const u8 = null,
    destination_label: ?[]const u8 = null,
    destination_subtitle: ?[]const u8 = null,
    destination_kind: ?destinations_mod.DestinationKind = null,
    enabled: bool = false,
};

const StoredSend = struct {
    channel_id: []const u8,
    bus_id: []const u8,
    gain: f32 = 1.0,
    enabled: bool = true,
    pre_fader: bool = false,
};

const StoredChannelPlugin = struct {
    id: []const u8,
    channel_id: []const u8,
    descriptor_id: []const u8,
    label: []const u8,
    backend: host_mod.PluginBackend = .lv2,
    enabled: bool = true,
    slot: u32 = 0,
};

const StoredChannelPluginParam = struct {
    plugin_id: []const u8,
    symbol: []const u8,
    value: f32 = 0.0,
};

const StoredNetworkAudio = struct {
    enabled: bool = true,
    bind_port: u16 = 45920,
    transport: network_mod.TransportKind = .udp,
    codec: network_mod.CodecKind = .pcm_float32,
    clock_mode: network_mod.ClockMode = .sender_timestamps,
    sample_rate_hz: u32 = 48_000,
    channels: u8 = 2,
    frames_per_packet: u16 = 64,
    jitter_buffer_packets: u8 = 2,
    max_clients: u8 = 8,
    allow_fec: bool = false,
    require_encryption: bool = false,
};

const StoredConfig = struct {
    version: u32 = 5,
    active_profile: []const u8 = "Default",
    network_audio: StoredNetworkAudio = .{},
    channels: []StoredChannel = &.{},
    buses: []StoredBus = &.{},
    bus_destinations: []StoredBusDestination = &.{},
    sends: []StoredSend = &.{},
    channel_plugins: []StoredChannelPlugin = &.{},
    channel_plugin_params: []StoredChannelPluginParam = &.{},
};

pub const ConfigStore = struct {
    allocator: std.mem.Allocator,
    config_path: []const u8,

    pub fn init(allocator: std.mem.Allocator) !ConfigStore {
        const path = try defaultPath(allocator);
        defer allocator.free(path);
        return initWithPath(allocator, path);
    }

    pub fn initWithPath(allocator: std.mem.Allocator, path: []const u8) !ConfigStore {
        return .{
            .allocator = allocator,
            .config_path = try allocator.dupe(u8, path),
        };
    }

    pub fn deinit(self: *ConfigStore) void {
        self.allocator.free(self.config_path);
    }

    pub fn load(self: *const ConfigStore, state_store: *StateStore) !bool {
        const file = std.fs.openFileAbsolute(self.config_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer file.close();

        const bytes = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(bytes);

        if (std.mem.trim(u8, bytes, &std.ascii.whitespace).len == 0) return false;

        const parsed = std.json.parseFromSlice(StoredConfig, self.allocator, bytes, .{
            .ignore_unknown_fields = true,
        }) catch |err| switch (err) {
            error.UnexpectedEndOfInput,
            error.SyntaxError,
            error.InvalidNumber,
            error.Overflow,
            error.UnknownField,
            error.DuplicateField,
            error.MissingField,
            => return false,
            else => return err,
        };
        defer parsed.deinit();

        try applyLoadedConfig(state_store, parsed.value);
        return true;
    }

    pub fn save(self: *const ConfigStore, state_store: *const StateStore) !void {
        if (isSuspiciousRoutingState(state_store)) {
            std.log.warn("config save skipped: suspicious routing state detected", .{});
            return error.SuspiciousRoutingState;
        }

        const parent_dir = std.fs.path.dirname(self.config_path) orelse return error.InvalidConfigPath;
        std.fs.makeDirAbsolute(parent_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const backup_path = try std.fmt.allocPrint(self.allocator, "{s}.bak", .{self.config_path});
        defer self.allocator.free(backup_path);
        std.fs.copyFileAbsolute(self.config_path, backup_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const config = try makeStoredConfig(allocator, state_store);

        const file = try std.fs.createFileAbsolute(self.config_path, .{ .truncate = true });
        defer file.close();

        var out: std.io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var stringify_stream: std.json.Stringify = .{
            .writer = &out.writer,
            .options = .{ .whitespace = .indent_2 },
        };
        try stringify_stream.write(config);
        try file.writeAll(out.written());
        try file.writeAll("\n");
    }
};

fn defaultPath(allocator: std.mem.Allocator) ![]u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.NoHomeDirectory,
        else => return err,
    };
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".config", "wiredeck", "config.json" });
}

fn makeStoredConfig(allocator: std.mem.Allocator, state_store: *const StateStore) !StoredConfig {
    const channels = try allocator.alloc(StoredChannel, state_store.channels.items.len);
    for (state_store.channels.items, 0..) |channel, index| {
        const source = if (channel.bound_source_id) |bound_id| findSource(state_store, bound_id) else null;
        channels[index] = .{
            .id = channel.id,
            .label = channel.label,
            .subtitle = channel.subtitle,
            .bound_source_id = channel.bound_source_id,
            .source_kind = channel.source_kind,
            .icon_name = channel.icon_name,
            .icon_path = channel.icon_path,
            .custom_icon_name = channel.custom_icon_name,
            .custom_icon_path = channel.custom_icon_path,
            .source_ref_id = if (source) |item| item.id else channel.bound_source_id,
            .source_ref_label = if (source) |item| item.label else fallbackStoredChannelLabel(channel),
            .source_ref_subtitle = if (source) |item| item.subtitle else fallbackStoredChannelSubtitle(channel),
            .source_ref_process_binary = if (source) |item| item.process_binary else fallbackStoredChannelProcessBinary(channel),
            .source_ref_kind = if (source) |item| item.kind else storedChannelSourceKind(channel),
            .input_bus_id = channel.input_bus_id,
            .meter_stage = channel.meter_stage,
            .volume = channel.volume,
            .muted = channel.muted,
        };
    }

    var persisted_bus_count: usize = 0;
    for (state_store.buses.items) |bus| {
        if (shouldPersistBus(bus)) persisted_bus_count += 1;
    }
    const buses = try allocator.alloc(StoredBus, persisted_bus_count);
    {
        var index: usize = 0;
        for (state_store.buses.items) |bus| {
            if (!shouldPersistBus(bus)) continue;
            buses[index] = .{
                .id = bus.id,
                .label = bus.label,
                .role = bus.role,
                .hidden = bus.hidden,
                .volume = bus.volume,
                .muted = bus.muted,
                .expose_as_microphone = bus.expose_as_microphone,
                .share_on_network = bus.share_on_network,
                .expose_on_web = bus.share_on_network,
            };
            index += 1;
        }
    }

    var persisted_bus_destination_count: usize = 0;
    for (state_store.bus_destinations.items) |item| {
        if (!isPersistedBusId(state_store, item.bus_id)) continue;
        persisted_bus_destination_count += 1;
    }
    const bus_destinations = try allocator.alloc(StoredBusDestination, persisted_bus_destination_count);
    {
        var index: usize = 0;
        for (state_store.bus_destinations.items) |item| {
            if (!isPersistedBusId(state_store, item.bus_id)) continue;
            const destination = findDestination(state_store, item.destination_id);
            bus_destinations[index] = .{
                .bus_id = item.bus_id,
                .destination_id = item.destination_id,
                .destination_sink_name = if (destination) |value| value.pulse_sink_name else item.destination_sink_name,
                .destination_label = if (destination) |value| value.label else item.destination_label,
                .destination_subtitle = if (destination) |value| value.subtitle else item.destination_subtitle,
                .destination_kind = if (destination) |value| value.kind else item.destination_kind,
                .enabled = item.enabled,
            };
            index += 1;
        }
    }

    var persisted_send_count: usize = 0;
    for (state_store.sends.items) |item| {
        if (!isPersistedBusId(state_store, item.bus_id)) continue;
        persisted_send_count += 1;
    }
    const sends = try allocator.alloc(StoredSend, persisted_send_count);
    {
        var index: usize = 0;
        for (state_store.sends.items) |item| {
            if (!isPersistedBusId(state_store, item.bus_id)) continue;
            sends[index] = .{
                .channel_id = item.channel_id,
                .bus_id = item.bus_id,
                .gain = item.gain,
                .enabled = item.enabled,
                .pre_fader = item.pre_fader,
            };
            index += 1;
        }
    }

    const channel_plugins = try allocator.alloc(StoredChannelPlugin, state_store.channel_plugins.items.len);
    for (state_store.channel_plugins.items, 0..) |item, index| {
        channel_plugins[index] = .{
            .id = item.id,
            .channel_id = item.channel_id,
            .descriptor_id = item.descriptor_id,
            .label = item.label,
            .backend = item.backend,
            .enabled = item.enabled,
            .slot = item.slot,
        };
    }

    const channel_plugin_params = try allocator.alloc(StoredChannelPluginParam, state_store.channel_plugin_params.items.len);
    for (state_store.channel_plugin_params.items, 0..) |item, index| {
        channel_plugin_params[index] = .{
            .plugin_id = item.plugin_id,
            .symbol = item.symbol,
            .value = item.value,
        };
    }

    return .{
        .active_profile = state_store.active_profile,
        .network_audio = .{
            .enabled = state_store.network_audio.enabled,
            .bind_port = state_store.network_audio.bind_port,
            .transport = state_store.network_audio.transport,
            .codec = state_store.network_audio.codec,
            .clock_mode = state_store.network_audio.clock_mode,
            .sample_rate_hz = state_store.network_audio.sample_rate_hz,
            .channels = state_store.network_audio.channels,
            .frames_per_packet = state_store.network_audio.frames_per_packet,
            .jitter_buffer_packets = state_store.network_audio.jitter_buffer_packets,
            .max_clients = state_store.network_audio.max_clients,
            .allow_fec = state_store.network_audio.allow_fec,
            .require_encryption = state_store.network_audio.require_encryption,
        },
        .channels = channels,
        .buses = buses,
        .bus_destinations = bus_destinations,
        .sends = sends,
        .channel_plugins = channel_plugins,
        .channel_plugin_params = channel_plugin_params,
    };
}

fn applyLoadedConfig(state_store: *StateStore, config: StoredConfig) !void {
    try state_store.setActiveProfile(config.active_profile);
    state_store.network_audio = .{
        .enabled = config.network_audio.enabled,
        .bind_port = config.network_audio.bind_port,
        .transport = config.network_audio.transport,
        .codec = config.network_audio.codec,
        .clock_mode = config.network_audio.clock_mode,
        .sample_rate_hz = config.network_audio.sample_rate_hz,
        .channels = config.network_audio.channels,
        .frames_per_packet = config.network_audio.frames_per_packet,
        .jitter_buffer_packets = config.network_audio.jitter_buffer_packets,
        .max_clients = config.network_audio.max_clients,
        .allow_fec = config.network_audio.allow_fec,
        .require_encryption = config.network_audio.require_encryption,
    };

    state_store.clearChannelPluginParams();
    state_store.clearChannelPlugins();
    state_store.clearSends();
    state_store.clearBusDestinations();
    state_store.clearChannelSources();
    state_store.clearBuses();
    state_store.clearChannels();

    try seedStoredSourceReferences(state_store, config.channels);

    var loaded_channel_ids = std.ArrayList(LoadedChannelId).empty;
    defer {
        for (loaded_channel_ids.items) |item| {
            state_store.allocator.free(item.original_id);
            state_store.allocator.free(item.actual_id);
        }
        loaded_channel_ids.deinit(state_store.allocator);
    }

    for (config.buses) |bus| {
        if (!shouldPersistStoredBus(bus)) continue;
        if (hasBus(state_store, bus.id)) continue;
        try state_store.addBus(.{
            .id = bus.id,
            .label = bus.label,
            .role = bus.role,
            .hidden = bus.hidden,
            .volume = bus.volume,
            .muted = bus.muted,
            .expose_as_microphone = bus.expose_as_microphone,
            .share_on_network = bus.share_on_network or bus.expose_on_web,
        });
    }

    var loaded_channel_index: usize = 0;
    for (config.channels) |channel| {
        const resolved_source_id = resolveStoredChannelSource(state_store, channel);
        if (hasEquivalentStoredChannel(state_store, channel, resolved_source_id)) continue;
        loaded_channel_index += 1;
        const channel_id = try std.fmt.allocPrint(state_store.allocator, "source-strip-{d}", .{loaded_channel_index});
        defer state_store.allocator.free(channel_id);
        const input_bus_id = try std.fmt.allocPrint(state_store.allocator, "input-stage-{d}", .{loaded_channel_index});
        defer state_store.allocator.free(input_bus_id);

        try state_store.addBus(.{
            .id = input_bus_id,
            .label = channel.label,
            .role = .input_stage,
            .hidden = true,
            .volume = 1.0,
            .muted = false,
        });
        try state_store.addChannel(.{
            .id = channel_id,
            .label = channel.label,
            .subtitle = channel.subtitle,
            .bound_source_id = resolved_source_id,
            .source_kind = channel.source_kind,
            .icon_name = channel.icon_name,
            .icon_path = channel.icon_path,
            .custom_icon_name = channel.custom_icon_name,
            .custom_icon_path = channel.custom_icon_path,
            .input_bus_id = input_bus_id,
            .meter_stage = channel.meter_stage,
            .volume = channel.volume,
            .muted = channel.muted,
        });
        try loaded_channel_ids.append(state_store.allocator, .{
            .original_id = try state_store.allocator.dupe(u8, channel.id),
            .actual_id = try state_store.allocator.dupe(u8, channel_id),
        });
    }

    try rebuildChannelSources(state_store);
    try rebuildBusDestinations(state_store, config.bus_destinations);

    for (config.sends) |send| {
        const actual_channel_id = resolveLoadedChannelIdForSend(loaded_channel_ids.items, state_store, send.channel_id, send.bus_id) orelse continue;
        if (!hasBus(state_store, send.bus_id)) continue;
        try state_store.addSend(.{
            .channel_id = actual_channel_id,
            .bus_id = send.bus_id,
            .gain = send.gain,
            .enabled = send.enabled,
            .pre_fader = send.pre_fader,
        });
    }
    try ensureSendMatrix(state_store);

    for (config.channel_plugins) |plugin| {
        const actual_channel_id = resolveLoadedChannelId(loaded_channel_ids.items, state_store, plugin.channel_id) orelse continue;
        if (!hasPluginDescriptor(state_store, plugin.descriptor_id)) continue;
        try state_store.addChannelPlugin(.{
            .id = plugin.id,
            .channel_id = actual_channel_id,
            .descriptor_id = plugin.descriptor_id,
            .label = plugin.label,
            .backend = plugin.backend,
            .enabled = plugin.enabled,
            .slot = plugin.slot,
        });
    }

    for (config.channel_plugin_params) |param| {
        if (!hasPlugin(state_store, param.plugin_id)) continue;
        try state_store.addChannelPluginParam(.{
            .plugin_id = param.plugin_id,
            .symbol = param.symbol,
            .value = param.value,
        });
    }
}

fn shouldPersistBus(bus: buses_mod.Bus) bool {
    return !bus.hidden and bus.role != .input_stage;
}

fn shouldPersistStoredBus(bus: StoredBus) bool {
    return !bus.hidden and bus.role != .input_stage;
}

fn isPersistedBusId(state_store: *const StateStore, bus_id: []const u8) bool {
    const bus = findBus(state_store, bus_id) orelse return false;
    return shouldPersistBus(bus);
}

fn findBus(state_store: *const StateStore, id: []const u8) ?buses_mod.Bus {
    for (state_store.buses.items) |bus| {
        if (std.mem.eql(u8, bus.id, id)) return bus;
    }
    return null;
}

const LoadedChannelId = struct {
    original_id: []const u8,
    actual_id: []const u8,
};

fn hasChannelBoundSource(state_store: *const StateStore, source_id: []const u8) bool {
    for (state_store.channels.items) |channel| {
        const bound_source_id = channel.bound_source_id orelse continue;
        if (std.mem.eql(u8, bound_source_id, source_id)) return true;
    }
    return false;
}

fn hasEquivalentStoredChannel(
    state_store: *const StateStore,
    stored_channel: StoredChannel,
    resolved_source_id: ?[]const u8,
) bool {
    if (resolved_source_id) |source_id| {
        if (hasChannelBoundSource(state_store, source_id)) return true;
    }

    for (state_store.channels.items) |channel| {
        if (!channelRepresentsEquivalentStoredSource(channel, stored_channel)) continue;
        return true;
    }
    return false;
}

fn resolveLoadedChannelIdForSend(
    loaded: []LoadedChannelId,
    state_store: *const StateStore,
    original_channel_id: []const u8,
    bus_id: []const u8,
) ?[]const u8 {
    for (loaded) |item| {
        if (!std.mem.eql(u8, item.original_id, original_channel_id)) continue;
        if (!hasSend(state_store, item.actual_id, bus_id)) return item.actual_id;
    }
    if (hasChannel(state_store, original_channel_id) and !hasSend(state_store, original_channel_id, bus_id)) {
        return original_channel_id;
    }
    return null;
}

fn resolveLoadedChannelId(
    loaded: []LoadedChannelId,
    state_store: *const StateStore,
    original_channel_id: []const u8,
) ?[]const u8 {
    for (loaded) |item| {
        if (std.mem.eql(u8, item.original_id, original_channel_id)) return item.actual_id;
    }
    if (hasChannel(state_store, original_channel_id)) return original_channel_id;
    return null;
}

fn hasSend(state_store: *const StateStore, channel_id: []const u8, bus_id: []const u8) bool {
    for (state_store.sends.items) |send| {
        if (!std.mem.eql(u8, send.channel_id, channel_id)) continue;
        if (std.mem.eql(u8, send.bus_id, bus_id)) return true;
    }
    return false;
}

fn rebuildChannelSources(state_store: *StateStore) !void {
    for (state_store.channels.items) |channel| {
        for (state_store.sources.items) |source| {
            try state_store.addChannelSource(.{
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

fn rebuildBusDestinations(state_store: *StateStore, stored: []const StoredBusDestination) !void {
    const restored = try state_store.allocator.alloc(bool, stored.len);
    defer state_store.allocator.free(restored);
    @memset(restored, false);

    for (state_store.buses.items) |bus| {
        for (state_store.destinations.items) |destination| {
            const stored_index = findStoredBusDestinationIndex(stored, bus.id, destination);
            if (stored_index) |index| restored[index] = true;
            try state_store.addBusDestination(.{
                .bus_id = bus.id,
                .destination_id = destination.id,
                .destination_sink_name = destination.pulse_sink_name,
                .destination_label = destination.label,
                .destination_subtitle = destination.subtitle,
                .destination_kind = destination.kind,
                .enabled = if (stored_index) |index| stored[index].enabled else false,
            });
        }
    }

    for (stored, 0..) |item, index| {
        if (restored[index]) continue;
        if (!hasBus(state_store, item.bus_id)) continue;
        try state_store.addBusDestination(.{
            .bus_id = item.bus_id,
            .destination_id = item.destination_id,
            .destination_sink_name = item.destination_sink_name orelse "",
            .destination_label = item.destination_label orelse "",
            .destination_subtitle = item.destination_subtitle orelse "",
            .destination_kind = item.destination_kind,
            .enabled = item.enabled,
        });
    }
}

fn ensureSendMatrix(state_store: *StateStore) !void {
    for (state_store.channels.items) |channel| {
        for (state_store.buses.items) |bus| {
            if (hasSend(state_store, channel.id, bus.id)) continue;
            try state_store.addSend(.{
                .channel_id = channel.id,
                .bus_id = bus.id,
                .enabled = false,
            });
        }
    }
}

fn seedStoredSourceReferences(state_store: *StateStore, channels: []const StoredChannel) !void {
    for (channels) |channel| {
        const kind = channel.source_ref_kind orelse storedChannelSourceKind(channel) orelse continue;
        const source_id = try storedReferenceSourceId(state_store.allocator, channel);
        defer state_store.allocator.free(source_id);

        if (findSource(state_store, source_id) != null) continue;

        try state_store.addSource(.{
            .id = source_id,
            .label = if (channel.source_ref_label) |value| value else channel.label,
            .subtitle = if (channel.source_ref_subtitle) |value| value else channel.subtitle,
            .kind = kind,
            .process_binary = if (channel.source_ref_process_binary) |value| value else (fallbackStoredChannelProcessBinaryLoaded(channel) orelse ""),
            .icon_name = channel.icon_name,
            .icon_path = channel.icon_path,
        });
    }
}

fn findStoredBusDestinationIndex(
    stored: []const StoredBusDestination,
    bus_id: []const u8,
    destination: destinations_mod.Destination,
) ?usize {
    if (isWiredeckManagedSinkName(destination.pulse_sink_name)) return null;
    for (stored, 0..) |item, index| {
        if (!std.mem.eql(u8, item.bus_id, bus_id)) continue;
        if (std.mem.eql(u8, item.destination_id, destination.id)) return index;
        if (item.destination_sink_name) |sink_name| {
            if (isWiredeckManagedSinkName(sink_name)) continue;
            if (destination.pulse_sink_name.len != 0 and std.mem.eql(u8, destination.pulse_sink_name, sink_name)) return index;
        }
        if (item.destination_label) |label| {
            if (!std.mem.eql(u8, destination.label, label)) continue;
            if (item.destination_subtitle) |subtitle| {
                if (!std.mem.eql(u8, destination.subtitle, subtitle)) continue;
            }
            if (item.destination_kind) |kind| {
                if (destination.kind != kind) continue;
            }
            return index;
        }
    }
    return null;
}

fn resolveStoredChannelSource(state_store: *const StateStore, channel: StoredChannel) ?[]const u8 {
    if (channel.bound_source_id) |bound_source_id| {
        if (findSource(state_store, bound_source_id)) |source| return source.id;
    }
    if (channel.source_ref_id) |source_ref_id| {
        if (findSource(state_store, source_ref_id)) |source| return source.id;
    }
    if (channel.source_ref_id == null and channel.bound_source_id == null) {
        const synthetic_ref_id = storedReferenceSourceId(state_store.allocator, channel) catch null orelse return null;
        defer state_store.allocator.free(synthetic_ref_id);
        if (findSource(state_store, synthetic_ref_id)) |source| return source.id;
    }
    if (channel.source_ref_process_binary) |process_binary| {
        for (state_store.sources.items) |source| {
            if (source.process_binary.len == 0) continue;
            if (!std.mem.eql(u8, source.process_binary, process_binary)) continue;
            if (channel.source_ref_kind) |kind| {
                if (source.kind != kind) continue;
            }
            return source.id;
        }
    }
    if (channel.source_ref_label) |label| {
        for (state_store.sources.items) |source| {
            if (!std.mem.eql(u8, source.label, label)) continue;
            if (channel.source_ref_subtitle) |subtitle| {
                if (!std.mem.eql(u8, source.subtitle, subtitle)) continue;
            }
            if (channel.source_ref_kind) |kind| {
                if (source.kind != kind) continue;
            }
            return source.id;
        }
    }
    if (channel.source_kind == @intFromEnum(sources_mod.SourceKind.app) and channel.subtitle.len > 0) {
        for (state_store.sources.items) |source| {
            if (source.kind != .app) continue;
            if (source.process_binary.len == 0) continue;
            if (std.mem.eql(u8, source.process_binary, channel.subtitle)) return source.id;
        }
    }
    if (channel.label.len > 0) {
        const channel_kind = storedChannelSourceKind(channel);
        for (state_store.sources.items) |source| {
            if (!std.mem.eql(u8, source.label, channel.label)) continue;
            if (channel.subtitle.len > 0 and !std.mem.eql(u8, source.subtitle, channel.subtitle)) continue;
            if (channel_kind) |kind| {
                if (source.kind != kind) continue;
            }
            return source.id;
        }
    }
    return null;
}

fn channelRepresentsEquivalentStoredSource(channel: channels_mod.Channel, stored_channel: StoredChannel) bool {
    const channel_kind = storedChannelSourceKind(channel) orelse return false;
    const stored_kind = storedChannelSourceKind(stored_channel) orelse return false;
    if (channel_kind != stored_kind) return false;

    if (stored_kind == .app) {
        const stored_process_binary = storedChannelProcessBinary(stored_channel);
        if (channel.subtitle.len > 0 and stored_process_binary.len > 0 and std.ascii.eqlIgnoreCase(channel.subtitle, stored_process_binary)) {
            return true;
        }

        const stored_label = storedChannelLabel(stored_channel);
        if (channel.label.len > 0 and stored_label.len > 0 and std.ascii.eqlIgnoreCase(channel.label, stored_label)) {
            return true;
        }

        const stored_subtitle = storedChannelSubtitle(stored_channel);
        if (channel.subtitle.len > 0 and stored_subtitle.len > 0 and std.ascii.eqlIgnoreCase(channel.subtitle, stored_subtitle)) {
            return true;
        }

        return false;
    }

    const stored_label = storedChannelLabel(stored_channel);
    if (channel.label.len > 0 and stored_label.len > 0 and std.ascii.eqlIgnoreCase(channel.label, stored_label)) {
        const stored_subtitle = storedChannelSubtitle(stored_channel);
        if (channel.subtitle.len == 0 or stored_subtitle.len == 0) return true;
        return std.ascii.eqlIgnoreCase(channel.subtitle, stored_subtitle);
    }

    return false;
}

fn storedChannelProcessBinary(channel: StoredChannel) []const u8 {
    if (channel.source_ref_process_binary) |value| return value;
    if (storedChannelSourceKind(channel) == .app) return channel.subtitle;
    return "";
}

fn storedChannelLabel(channel: StoredChannel) []const u8 {
    if (channel.source_ref_label) |value| return value;
    return channel.label;
}

fn storedChannelSubtitle(channel: StoredChannel) []const u8 {
    if (channel.source_ref_subtitle) |value| return value;
    return channel.subtitle;
}

fn fallbackStoredChannelLabel(channel: channels_mod.Channel) ?[]const u8 {
    if (channel.label.len == 0) return null;
    return channel.label;
}

fn fallbackStoredChannelSubtitle(channel: channels_mod.Channel) ?[]const u8 {
    if (channel.subtitle.len == 0) return null;
    return channel.subtitle;
}

fn fallbackStoredChannelProcessBinary(channel: channels_mod.Channel) ?[]const u8 {
    if (channel.source_kind != @intFromEnum(sources_mod.SourceKind.app)) return null;
    if (channel.subtitle.len == 0) return null;
    return channel.subtitle;
}

fn fallbackStoredChannelProcessBinaryLoaded(channel: StoredChannel) ?[]const u8 {
    if (channel.source_kind != @intFromEnum(sources_mod.SourceKind.app)) return null;
    if (channel.subtitle.len == 0) return null;
    return channel.subtitle;
}

fn storedReferenceSourceId(allocator: std.mem.Allocator, channel: StoredChannel) ![]u8 {
    if (channel.source_ref_id) |value| return allocator.dupe(u8, value);
    if (channel.bound_source_id) |value| return allocator.dupe(u8, value);
    return std.fmt.allocPrint(allocator, "stored-source-ref-{s}", .{channel.id});
}

fn storedChannelSourceKind(channel: anytype) ?sources_mod.SourceKind {
    return std.meta.intToEnum(sources_mod.SourceKind, channel.source_kind) catch null;
}

fn findSource(state_store: *const StateStore, id: []const u8) ?sources_mod.Source {
    for (state_store.sources.items) |source| {
        if (std.mem.eql(u8, source.id, id)) return source;
    }
    return null;
}

fn findDestination(state_store: *const StateStore, id: []const u8) ?destinations_mod.Destination {
    for (state_store.destinations.items) |destination| {
        if (std.mem.eql(u8, destination.id, id)) return destination;
    }
    return null;
}

fn hasChannel(state_store: *const StateStore, id: []const u8) bool {
    for (state_store.channels.items) |item| {
        if (std.mem.eql(u8, item.id, id)) return true;
    }
    return false;
}

fn hasBus(state_store: *const StateStore, id: []const u8) bool {
    for (state_store.buses.items) |item| {
        if (std.mem.eql(u8, item.id, id)) return true;
    }
    return false;
}

fn hasPlugin(state_store: *const StateStore, id: []const u8) bool {
    for (state_store.channel_plugins.items) |item| {
        if (std.mem.eql(u8, item.id, id)) return true;
    }
    return false;
}

fn hasPluginDescriptor(state_store: *const StateStore, id: []const u8) bool {
    for (state_store.plugin_descriptors.items) |item| {
        if (std.mem.eql(u8, item.id, id)) return true;
    }
    return false;
}

fn isWiredeckManagedSinkName(sink_name: []const u8) bool {
    return std.mem.startsWith(u8, sink_name, "wiredeck-combine-") or
        std.mem.startsWith(u8, sink_name, "wiredeck_output_") or
        std.mem.startsWith(u8, sink_name, "wiredeck_input_") or
        std.mem.startsWith(u8, sink_name, "wiredeck_fx_") or
        std.mem.startsWith(u8, sink_name, "wiredeck_busmic_sink_") or
        std.mem.startsWith(u8, sink_name, "wiredeck_parking_sink");
}

fn isSuspiciousRoutingState(state_store: *const StateStore) bool {
    var visible_bus_count: usize = 0;
    for (state_store.buses.items) |bus| {
        if (bus.hidden) continue;
        if (bus.role == .input_stage) continue;
        visible_bus_count += 1;
    }

    if (visible_bus_count > 1) return false;
    if (state_store.channels.items.len <= 1) return false;

    for (state_store.sends.items) |send| {
        if (send.enabled) return false;
    }

    return true;
}
