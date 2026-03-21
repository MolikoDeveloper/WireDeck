const host = @import("host.zig");

pub const ChannelPlugin = struct {
    id: []const u8,
    channel_id: []const u8,
    descriptor_id: []const u8,
    label: []const u8,
    backend: host.PluginBackend = .lv2,
    enabled: bool = true,
    slot: u32 = 0,
};

pub const ChannelPluginParam = struct {
    plugin_id: []const u8,
    symbol: []const u8,
    value: f32 = 0.0,
};

pub const PluginChain = struct {
    channel_id: []const u8,
    plugin_count: usize = 0,
    plugins_enabled: usize = 0,
};
