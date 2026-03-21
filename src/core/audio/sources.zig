pub const SourceKind = enum {
    physical,
    virtual,
    app,
};

pub const Source = struct {
    id: []const u8,
    label: []const u8,
    subtitle: []const u8,
    kind: SourceKind = .physical,
    process_binary: []const u8 = "",
    icon_name: []const u8 = "",
    icon_path: []const u8 = "",
    level_left: f32 = 0.0,
    level_right: f32 = 0.0,
    level: f32 = 0.0,
    muted: bool = false,
};
