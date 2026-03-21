const channels = @import("channels.zig");
const buses = @import("buses.zig");
const destinations = @import("destinations.zig");
const sends = @import("sends.zig");

pub const AudioCore = struct {
    pub fn defaultChannels() [3]channels.Channel {
        return .{
            .{ .id = "mic", .label = "Mic", .subtitle = "Input group" },
            .{ .id = "game", .label = "Game", .subtitle = "Input group" },
            .{ .id = "chat", .label = "Chat", .subtitle = "Input group" },
        };
    }

    pub fn defaultBuses() [2]buses.Bus {
        return .{
            .{ .id = "headphones", .label = "Headphones", .role = .output },
            .{ .id = "stream", .label = "Stream Mix", .role = .output },
        };
    }

    pub fn defaultDestinations() [0]destinations.Destination {
        return .{};
    }

    pub fn defaultSends() [6]sends.Send {
        return .{
            .{ .channel_id = "mic", .bus_id = "headphones" },
            .{ .channel_id = "mic", .bus_id = "stream" },
            .{ .channel_id = "game", .bus_id = "headphones" },
            .{ .channel_id = "game", .bus_id = "stream", .enabled = false },
            .{ .channel_id = "chat", .bus_id = "headphones", .enabled = false },
            .{ .channel_id = "chat", .bus_id = "stream", .gain = 0.8 },
        };
    }
};
