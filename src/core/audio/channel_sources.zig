pub const ChannelSource = struct {
    channel_id: []const u8,
    source_id: []const u8,
    enabled: bool = false,
};
