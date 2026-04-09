pub const BusRole = enum {
    mixer,
    input_stage,
    output,
};

pub const Bus = struct {
    id: []const u8,
    label: []const u8,
    role: BusRole = .mixer,
    hidden: bool = false,
    volume: f32 = 1.0,
    muted: bool = false,
    system_volume: f32 = 1.0,
    system_muted: bool = false,
    expose_as_microphone: bool = false,
    share_on_network: bool = false,
};
