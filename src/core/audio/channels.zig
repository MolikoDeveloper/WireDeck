pub const MeterStage = enum {
    input,
    post_fx,
    post_fader,
};

pub const Channel = struct {
    id: []const u8,
    label: []const u8,
    subtitle: []const u8,
    bound_source_id: ?[]const u8 = null,
    source_kind: u8 = 2,
    icon_name: []const u8 = "",
    icon_path: []const u8 = "",
    custom_icon_name: []const u8 = "",
    custom_icon_path: []const u8 = "",
    input_bus_id: ?[]const u8 = null,
    meter_stage: MeterStage = .input,
    level_left: f32 = 0.0,
    level_right: f32 = 0.0,
    level: f32 = 0.0,
    volume: f32 = 1.0,
    muted: bool = false,
};
