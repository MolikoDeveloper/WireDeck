pub const WindowConfig = struct {
    title: [:0]const u8 = "WireDeck",
    width: i32 = 1480,
    height: i32 = 900,
    max_frames: ?u32 = null,
    start_hidden: bool = false,
};
