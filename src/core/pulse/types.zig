const std = @import("std");

pub const PulseClient = struct {
    index: u32,
    name: ?[]const u8 = null,
    app_name: ?[]const u8 = null,
    process_id: ?u32 = null,
    process_binary: ?[]const u8 = null,
};

pub const PulseSink = struct {
    index: u32,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    monitor_source_name: ?[]const u8 = null,
    muted: bool = false,
    volume: f32 = 1.0,
    card_index: ?u32 = null,
    bluez5_profile: ?[]const u8 = null,
    bluez5_codec: ?[]const u8 = null,
    active_port_name: ?[]const u8 = null,
    active_port_description: ?[]const u8 = null,
};

pub const PulseCardProfile = struct {
    name: []const u8,
    description: []const u8,
    n_sinks: u32 = 0,
    n_sources: u32 = 0,
    priority: u32 = 0,
    available: bool = true,
};

pub const PulseCard = struct {
    index: u32,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    device_api: ?[]const u8 = null,
    active_profile: ?[]const u8 = null,
    profiles: []PulseCardProfile = &.{},
};

pub const PulseSource = struct {
    index: u32,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    monitor_of_sink: ?u32 = null,
    channels: u8 = 2,
};

pub const PulseSinkInput = struct {
    index: u32,
    client_index: ?u32 = null,
    sink_index: ?u32 = null,
    corked: bool = false,
    muted: bool = false,
    volume: f32 = 1.0,
    app_name: ?[]const u8 = null,
    process_id: ?u32 = null,
    process_binary: ?[]const u8 = null,
    media_name: ?[]const u8 = null,
    channels: u8 = 2,
};

pub const PulseSourceOutput = struct {
    index: u32,
    module_index: ?u32 = null,
    client_index: ?u32 = null,
    source_index: ?u32 = null,
    app_name: ?[]const u8 = null,
    process_id: ?u32 = null,
    process_binary: ?[]const u8 = null,
    media_name: ?[]const u8 = null,
    channels: u8 = 2,
};

pub const PulseModule = struct {
    index: u32,
    name: ?[]const u8 = null,
    argument: ?[]const u8 = null,
};

pub const PulseSnapshot = struct {
    clients: []PulseClient,
    sinks: []PulseSink,
    sources: []PulseSource,
    sink_inputs: []PulseSinkInput,
    source_outputs: []PulseSourceOutput,
};

pub fn freeSnapshot(allocator: std.mem.Allocator, snapshot: PulseSnapshot) void {
    for (snapshot.clients) |item| {
        freeOpt(allocator, item.name);
        freeOpt(allocator, item.app_name);
        freeOpt(allocator, item.process_binary);
    }
    allocator.free(snapshot.clients);

    for (snapshot.sinks) |item| {
        freeOpt(allocator, item.name);
        freeOpt(allocator, item.description);
        freeOpt(allocator, item.monitor_source_name);
        freeOpt(allocator, item.bluez5_profile);
        freeOpt(allocator, item.bluez5_codec);
        freeOpt(allocator, item.active_port_name);
        freeOpt(allocator, item.active_port_description);
    }
    allocator.free(snapshot.sinks);

    for (snapshot.sources) |item| {
        freeOpt(allocator, item.name);
        freeOpt(allocator, item.description);
    }
    allocator.free(snapshot.sources);

    for (snapshot.sink_inputs) |item| {
        freeOpt(allocator, item.app_name);
        freeOpt(allocator, item.process_binary);
        freeOpt(allocator, item.media_name);
    }
    allocator.free(snapshot.sink_inputs);

    for (snapshot.source_outputs) |item| {
        freeOpt(allocator, item.app_name);
        freeOpt(allocator, item.process_binary);
        freeOpt(allocator, item.media_name);
    }
    allocator.free(snapshot.source_outputs);
}

pub fn freeModules(allocator: std.mem.Allocator, modules: []PulseModule) void {
    for (modules) |item| {
        freeOpt(allocator, item.name);
        freeOpt(allocator, item.argument);
    }
    allocator.free(modules);
}

pub fn freeCards(allocator: std.mem.Allocator, cards: []PulseCard) void {
    for (cards) |card| {
        freeOpt(allocator, card.name);
        freeOpt(allocator, card.description);
        freeOpt(allocator, card.device_api);
        freeOpt(allocator, card.active_profile);
        for (card.profiles) |profile| {
            allocator.free(profile.name);
            allocator.free(profile.description);
        }
        allocator.free(card.profiles);
    }
    allocator.free(cards);
}

fn freeOpt(allocator: std.mem.Allocator, value: ?[]const u8) void {
    if (value) |v| allocator.free(v);
}
