pub const Send = struct {
    channel_id: []const u8,
    bus_id: []const u8,
    gain: f32 = 1.0,
    enabled: bool = true,
    pre_fader: bool = false,
};
