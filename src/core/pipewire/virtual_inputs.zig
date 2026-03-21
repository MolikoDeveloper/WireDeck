const builtin = @import("builtin");
const std = @import("std");
const channels_mod = @import("../audio/channels.zig");

pub const VirtualInputManager = struct {
    const config_revision: u32 = 2;

    pub const Config = struct {
        sink_prefix: []const u8,
        description_prefix: []const u8,
        sample_rate_hz: ?u32 = null,
    };

    const input_config = Config{
        .sink_prefix = "wiredeck_input_",
        .description_prefix = "WireDeck Input ",
    };

    const fx_config = Config{
        .sink_prefix = "wiredeck_fx_",
        .description_prefix = "WireDeck FX ",
        .sample_rate_hz = 48_000,
    };

    const ManagedInput = struct {
        channel_id: []u8,
        label: []u8,
        sink_name: []u8,
        module_id: u32,
        hidden: bool,
        filtered: bool,

        fn deinit(self: *ManagedInput, allocator: std.mem.Allocator) void {
            allocator.free(self.channel_id);
            allocator.free(self.label);
            allocator.free(self.sink_name);
        }
    };

    allocator: std.mem.Allocator,
    config: Config,
    inputs: std.ArrayList(ManagedInput),
    last_signature: u64 = 0,
    host_available: bool = true,

    pub fn init(allocator: std.mem.Allocator) VirtualInputManager {
        return .{
            .allocator = allocator,
            .config = input_config,
            .inputs = .empty,
        };
    }

    pub fn initFxStage(allocator: std.mem.Allocator) VirtualInputManager {
        return .{
            .allocator = allocator,
            .config = fx_config,
            .inputs = .empty,
        };
    }

    pub fn deinit(self: *VirtualInputManager) void {
        if (!builtin.is_test) self.unloadAllManaged() catch {};
        for (self.inputs.items) |*input| input.deinit(self.allocator);
        self.inputs.deinit(self.allocator);
    }

    pub fn cleanup(self: *VirtualInputManager) !void {
        if (builtin.is_test or !self.host_available) return;
        try self.unloadAllManaged();
        for (self.inputs.items) |*input| input.deinit(self.allocator);
        self.inputs.clearRetainingCapacity();
        self.last_signature = 0;
    }

    pub fn isHostAvailable(self: VirtualInputManager) bool {
        return self.host_available;
    }

    pub fn reset(self: *VirtualInputManager) void {
        if (!builtin.is_test) self.unloadAllManaged() catch {};
        self.host_available = true;
        self.last_signature = 0;
        for (self.inputs.items) |*input| input.deinit(self.allocator);
        self.inputs.clearRetainingCapacity();
    }

    pub fn sync(self: *VirtualInputManager, channels: []const channels_mod.Channel) !void {
        if (builtin.is_test or !self.host_available) return;

        const signature = computeChannelSignature(channels);
        if (signature == self.last_signature) return;

        var discovered = try self.listManagedInputs();
        defer {
            for (discovered.items) |*input| input.deinit(self.allocator);
            discovered.deinit(self.allocator);
        }

        for (channels) |channel| {
            const desired_sink_name = try allocSinkName(self.allocator, self.config.sink_prefix, channel.id);
            defer self.allocator.free(desired_sink_name);

            if (findInputByChannel(discovered.items, channel.id)) |existing| {
                if (!std.mem.eql(u8, existing.sink_name, desired_sink_name)) {
                    try self.unloadModule(existing.module_id);
                    try self.loadVirtualSink(channel, desired_sink_name);
                } else if (!existing.hidden or !existing.filtered) {
                    try self.unloadModule(existing.module_id);
                    try self.loadVirtualSink(channel, desired_sink_name);
                } else if (findInputByChannel(self.inputs.items, channel.id)) |known| {
                    if (!std.mem.eql(u8, known.label, channel.label)) {
                        try self.unloadModule(existing.module_id);
                        try self.loadVirtualSink(channel, desired_sink_name);
                    }
                }
            } else {
                try self.loadVirtualSink(channel, desired_sink_name);
            }
        }

        for (discovered.items) |input| {
            if (findChannelById(channels, input.channel_id) == null) {
                try self.unloadModule(input.module_id);
            }
        }

        try self.refreshKnownInputs();
        self.last_signature = signature;
    }

    fn unloadAllManaged(self: *VirtualInputManager) !void {
        var discovered = self.listManagedInputs() catch return;
        defer {
            for (discovered.items) |*input| input.deinit(self.allocator);
            discovered.deinit(self.allocator);
        }
        for (discovered.items) |input| self.unloadModule(input.module_id) catch {};
    }

    fn refreshKnownInputs(self: *VirtualInputManager) !void {
        for (self.inputs.items) |*input| input.deinit(self.allocator);
        self.inputs.clearRetainingCapacity();

        var discovered = try self.listManagedInputs();
        defer discovered.deinit(self.allocator);
        try self.inputs.appendSlice(self.allocator, discovered.items);
        discovered.clearRetainingCapacity();
    }

    fn loadVirtualSink(self: *VirtualInputManager, channel: channels_mod.Channel, sink_name: []const u8) !void {
        const escaped_label = try escapePactlValue(self.allocator, channel.label);
        defer self.allocator.free(escaped_label);

        const description = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{
            self.config.description_prefix,
            escaped_label,
        });
        defer self.allocator.free(description);

        const sink_properties = try std.fmt.allocPrint(
            self.allocator,
            "\"device.description='{s}' node.description='{s}' wiredeck.channel.id={s} node.virtual=true node.hidden=true device.class=filter media.class=Audio/Sink\"",
            .{ description, description, channel.id },
        );
        defer self.allocator.free(sink_properties);

        const sink_name_arg = try std.fmt.allocPrint(self.allocator, "sink_name={s}", .{sink_name});
        defer self.allocator.free(sink_name_arg);
        const sink_properties_arg = try std.fmt.allocPrint(self.allocator, "sink_properties={s}", .{sink_properties});
        defer self.allocator.free(sink_properties_arg);
        const rate_arg = if (self.config.sample_rate_hz) |sample_rate_hz|
            try std.fmt.allocPrint(self.allocator, "rate={d}", .{sample_rate_hz})
        else
            null;
        defer if (rate_arg) |value| self.allocator.free(value);

        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(self.allocator);
        try argv.appendSlice(self.allocator, &.{
            "pactl",
            "load-module",
            "module-null-sink",
            sink_name_arg,
            sink_properties_arg,
        });
        if (rate_arg) |value| try argv.append(self.allocator, value);

        const output = try runHostCommand(self.allocator, argv.items);
        defer self.allocator.free(output);

        const trimmed = std.mem.trim(u8, output, &std.ascii.whitespace);
        if (trimmed.len == 0) return error.VirtualInputCreateFailed;
        _ = std.fmt.parseInt(u32, trimmed, 10) catch return error.VirtualInputCreateFailed;
    }

    fn unloadModule(self: *VirtualInputManager, module_id: u32) !void {
        const rendered_id = try std.fmt.allocPrint(self.allocator, "{d}", .{module_id});
        defer self.allocator.free(rendered_id);
        _ = try runHostCommand(self.allocator, &.{ "pactl", "unload-module", rendered_id });
    }

    fn listManagedInputs(self: *VirtualInputManager) !std.ArrayList(ManagedInput) {
        var inputs = std.ArrayList(ManagedInput).empty;
        errdefer {
            for (inputs.items) |*input| input.deinit(self.allocator);
            inputs.deinit(self.allocator);
        }

        const text = runHostCommand(self.allocator, &.{ "pactl", "list", "short", "modules" }) catch |err| switch (err) {
            error.FileNotFound, error.HostCommandFailed => {
                self.host_available = false;
                return inputs;
            },
            else => return err,
        };
        defer self.allocator.free(text);

        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len == 0) continue;
            const managed = try parseManagedInputLine(self, trimmed) orelse continue;
            try inputs.append(self.allocator, managed);
        }
        return inputs;
    }
};

fn computeChannelSignature(channels: []const channels_mod.Channel) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (channels) |channel| {
        hasher.update(channel.id);
        hasher.update(&[_]u8{0});
        hasher.update(channel.label);
        hasher.update(&[_]u8{0});
    }
    hasher.update(std.mem.asBytes(&[_]u32{VirtualInputManager.config_revision}));
    return hasher.final();
}

pub fn allocSinkName(allocator: std.mem.Allocator, prefix: []const u8, channel_id: []const u8) ![]u8 {
    var sink_name = try allocator.alloc(u8, prefix.len + channel_id.len);
    @memcpy(sink_name[0..prefix.len], prefix);
    for (channel_id, prefix.len..) |char, index| {
        sink_name[index] = if (std.ascii.isAlphanumeric(char)) std.ascii.toLower(char) else '_';
    }
    return sink_name;
}

fn escapePactlValue(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    for (value) |char| {
        if (char == '"' or char == '\\') try out.append(allocator, '\\');
        try out.append(allocator, char);
    }
    return out.toOwnedSlice(allocator);
}

fn runHostCommand(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const max_output_bytes = 4 * 1024 * 1024;
    const use_flatpak_host = std.process.hasEnvVarConstant("FLATPAK_ID");
    const command_argv = if (use_flatpak_host) blk: {
        const host_argv = try allocator.alloc([]const u8, argv.len + 2);
        host_argv[0] = "flatpak-spawn";
        host_argv[1] = "--host";
        @memcpy(host_argv[2..], argv);
        break :blk host_argv;
    } else argv;
    defer if (use_flatpak_host) allocator.free(command_argv);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = command_argv,
        .max_output_bytes = max_output_bytes,
    });
    errdefer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                allocator.free(result.stdout);
                return error.HostCommandFailed;
            }
        },
        else => {
            allocator.free(result.stdout);
            return error.HostCommandFailed;
        },
    }

    return result.stdout;
}

fn parseManagedInputLine(self: *VirtualInputManager, line: []const u8) !?VirtualInputManager.ManagedInput {
    var fields = std.mem.splitScalar(u8, line, '\t');
    const id_text = fields.next() orelse return null;
    const module_name = fields.next() orelse return null;
    const args = fields.rest();

    if (!std.mem.eql(u8, module_name, "module-null-sink")) return null;
    const sink_name = extractArgValue(args, "sink_name=") orelse return null;
    if (!std.mem.startsWith(u8, sink_name, self.config.sink_prefix)) return null;

    const channel_id = sink_name[self.config.sink_prefix.len..];
    const module_id = std.fmt.parseInt(u32, id_text, 10) catch return null;
    const label = extractPropertyValue(args, "device.description=") orelse sink_name;

    return .{
        .channel_id = try self.allocator.dupe(u8, channel_id),
        .label = try self.allocator.dupe(u8, stripDescriptionPrefix(label, self.config.description_prefix)),
        .sink_name = try self.allocator.dupe(u8, sink_name),
        .module_id = module_id,
        .hidden = std.mem.indexOf(u8, args, "node.hidden=true") != null,
        .filtered = std.mem.indexOf(u8, args, "device.class=filter") != null,
    };
}

fn stripDescriptionPrefix(label: []const u8, prefix: []const u8) []const u8 {
    if (std.mem.startsWith(u8, label, prefix)) return label[prefix.len..];
    return label;
}

fn extractArgValue(args: []const u8, key: []const u8) ?[]const u8 {
    var parts = std.mem.tokenizeScalar(u8, args, ' ');
    while (parts.next()) |part| {
        if (std.mem.startsWith(u8, part, key)) return trimQuotes(part[key.len..]);
    }
    return null;
}

fn extractPropertyValue(args: []const u8, key: []const u8) ?[]const u8 {
    const properties_index = std.mem.indexOf(u8, args, "sink_properties=") orelse return null;
    const properties = args[properties_index + "sink_properties=".len ..];
    const key_index = std.mem.indexOf(u8, properties, key) orelse return null;
    const value_start = key_index + key.len;
    const tail = properties[value_start..];
    if (tail.len == 0) return null;
    if (tail[0] == '"' or tail[0] == '\'') {
        const quote = tail[0];
        const quoted_end = std.mem.indexOfScalarPos(u8, tail, 1, quote) orelse return null;
        return tail[1..quoted_end];
    }
    const end = std.mem.indexOfScalar(u8, tail, ' ') orelse tail.len;
    return trimQuotes(tail[0..end]);
}

fn trimQuotes(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, "\"'");
}

fn findChannelById(channels: []const channels_mod.Channel, channel_id: []const u8) ?channels_mod.Channel {
    for (channels) |channel| {
        if (std.mem.eql(u8, channel.id, channel_id)) return channel;
    }
    return null;
}

fn findInputByChannel(inputs: []const VirtualInputManager.ManagedInput, channel_id: []const u8) ?VirtualInputManager.ManagedInput {
    for (inputs) |input| {
        if (std.mem.eql(u8, input.channel_id, channel_id)) return input;
    }
    return null;
}

test "parse managed input line extracts module id and channel id" {
    const allocator = std.testing.allocator;
    var manager = VirtualInputManager.init(allocator);
    const line =
        "321\tmodule-null-sink\tsink_name=wiredeck_input_mic sink_properties=\"device.description='WireDeck Input Mic' node.description='WireDeck Input Mic'\"";
    const parsed = (try parseManagedInputLine(&manager, line)).?;
    defer {
        var value = parsed;
        value.deinit(allocator);
    }

    try std.testing.expectEqual(@as(u32, 321), parsed.module_id);
    try std.testing.expectEqualStrings("mic", parsed.channel_id);
    try std.testing.expectEqualStrings("Mic", parsed.label);
    try std.testing.expectEqualStrings("wiredeck_input_mic", parsed.sink_name);
}
