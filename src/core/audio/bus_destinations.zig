pub const BusDestination = struct {
    bus_id: []const u8,
    destination_id: []const u8,
    enabled: bool = false,
};
