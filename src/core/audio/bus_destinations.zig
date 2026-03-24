const destinations_mod = @import("destinations.zig");

pub const BusDestination = struct {
    bus_id: []const u8,
    destination_id: []const u8,
    destination_sink_name: []const u8 = "",
    destination_label: []const u8 = "",
    destination_subtitle: []const u8 = "",
    destination_kind: ?destinations_mod.DestinationKind = null,
    enabled: bool = false,
};
