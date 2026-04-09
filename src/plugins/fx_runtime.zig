const std = @import("std");
const chain = @import("chain.zig");
const host = @import("host.zig");
const Lv2Runtime = @import("lv2_runtime.zig").Lv2Runtime;

pub const FxRuntime = struct {
    pub const ChannelProcessStatus = enum(u8) {
        processed,
        bypass_no_chain,
        bypass_busy,
        bypass_failed,
    };

    allocator: std.mem.Allocator,
    lv2: Lv2Runtime,

    pub fn init(allocator: std.mem.Allocator) FxRuntime {
        return .{
            .allocator = allocator,
            .lv2 = Lv2Runtime.init(allocator),
        };
    }

    pub fn deinit(self: *FxRuntime) void {
        self.lv2.deinit();
    }

    pub fn sync(
        self: *FxRuntime,
        descriptors: []const host.PluginDescriptor,
        channel_plugins: []const chain.ChannelPlugin,
        channel_plugin_params: []const chain.ChannelPluginParam,
    ) !void {
        _ = self.allocator;
        try self.lv2.sync(descriptors, channel_plugins, channel_plugin_params);
    }

    pub fn processChannelStatus(self: *FxRuntime, channel_id: []const u8, left: []f32, right: []f32) ChannelProcessStatus {
        return self.lv2.processChannelStatus(channel_id, left, right);
    }

    pub fn processChannel(self: *FxRuntime, channel_id: []const u8, left: []f32, right: []f32) bool {
        return switch (self.processChannelStatus(channel_id, left, right)) {
            .processed, .bypass_no_chain => true,
            .bypass_busy, .bypass_failed => false,
        };
    }

    pub fn setSampleRate(self: *FxRuntime, sample_rate_hz: u32) void {
        self.lv2.setSampleRate(sample_rate_hz);
    }

    pub fn writeUiUpdateLines(self: *FxRuntime, plugin_id: []const u8, writer: anytype) !u64 {
        return try self.lv2.writeUiUpdateLines(plugin_id, writer);
    }

    pub fn getUiRuntimeHandle(self: *FxRuntime, plugin_id: []const u8) ?Lv2Runtime.UiRuntimeHandle {
        return self.lv2.getUiRuntimeHandle(plugin_id);
    }

    pub fn channelLatencyFrames(self: *FxRuntime, channel_id: []const u8) u32 {
        return self.lv2.channelLatencyFrames(channel_id);
    }
};
