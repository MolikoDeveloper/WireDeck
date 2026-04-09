pub const DestinationKind = enum {
    physical,
    virtual,
    device,
};

pub const Destination = struct {
    id: []const u8,
    label: []const u8,
    subtitle: []const u8,
    kind: DestinationKind,
    level_left: f32 = 0.0,
    level_right: f32 = 0.0,
    level: f32 = 0.0,
    muted: bool = false,
    volume: f32 = 1.0,
    pulse_sink_index: ?u32 = null,
    pulse_sink_name: []const u8 = "",
    pulse_card_index: ?u32 = null,
    pulse_card_profile: []const u8 = "",
};
