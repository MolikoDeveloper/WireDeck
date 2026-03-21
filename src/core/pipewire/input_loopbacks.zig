const builtin = @import("builtin");
const std = @import("std");
const buses_mod = @import("../audio/buses.zig");
const channel_sources_mod = @import("../audio/channel_sources.zig");
const channels_mod = @import("../audio/channels.zig");
const sends_mod = @import("../audio/sends.zig");
const sources_mod = @import("../audio/sources.zig");

const output_prefix = "wiredeck_output_";
const input_prefix = "wiredeck_input_";
const fx_prefix = "wiredeck_fx_";

pub const InputLoopbackManager = struct {
    const RouteKind = enum(u8) {
        source_to_bus,
        source_to_fx,
        fx_to_bus,
    };

    const ManagedRoute = struct {
        kind: RouteKind,
        channel_id: []u8,
        capture_id: []u8,
        target_id: []u8,
        route_name: []u8,
        media_name: []u8,
        command: []u8,
        child: std.process.Child,
        sink_input_index: ?u32 = null,

        fn deinit(self: *ManagedRoute, allocator: std.mem.Allocator) void {
            allocator.free(self.channel_id);
            allocator.free(self.capture_id);
            allocator.free(self.target_id);
            allocator.free(self.route_name);
            allocator.free(self.media_name);
            allocator.free(self.command);
        }
    };

    allocator: std.mem.Allocator,
    routes: std.ArrayList(ManagedRoute),
    last_signature: u64 = 0,
    host_available: bool = true,

    pub fn init(allocator: std.mem.Allocator) InputLoopbackManager {
        return .{
            .allocator = allocator,
            .routes = .empty,
        };
    }

    pub fn deinit(self: *InputLoopbackManager) void {
        for (self.routes.items) |*route| {
            killChild(&route.child);
            route.deinit(self.allocator);
        }
        self.routes.deinit(self.allocator);
    }

    pub fn isHostAvailable(self: InputLoopbackManager) bool {
        return self.host_available;
    }

    pub fn reset(self: *InputLoopbackManager) void {
        for (self.routes.items) |*route| {
            killChild(&route.child);
            route.deinit(self.allocator);
        }
        self.routes.clearRetainingCapacity();
        self.host_available = true;
        self.last_signature = 0;
    }

    pub fn sync(
        self: *InputLoopbackManager,
        channels: []const channels_mod.Channel,
        sources: []const sources_mod.Source,
        channel_sources: []const channel_sources_mod.ChannelSource,
        buses: []const buses_mod.Bus,
        sends: []const sends_mod.Send,
        fx_channels: []const channels_mod.Channel,
    ) !void {
        if (builtin.is_test or !self.host_available) return;

        const signature = computeSignature(channels, sources, channel_sources, buses, sends, fx_channels);
        if (signature == self.last_signature) return;

        var desired = std.ArrayList(RouteSpec).empty;
        defer desired.deinit(self.allocator);

        try buildDesiredRoutes(
            self.allocator,
            &desired,
            channels,
            sources,
            channel_sources,
            buses,
            sends,
            fx_channels,
        );

        var index = self.routes.items.len;
        while (index > 0) {
            index -= 1;
            const route = self.routes.items[index];
            if (!containsRouteSpec(desired.items, route.kind, route.channel_id, route.capture_id, route.target_id)) {
                var removed = self.routes.orderedRemove(index);
                killChild(&removed.child);
                removed.deinit(self.allocator);
            }
        }

        for (desired.items) |spec| {
            if (findManagedRoute(self.routes.items, spec.kind, spec.channel_id, spec.capture_id, spec.target_id) == null) {
                var managed = self.spawnRoute(spec) catch |err| switch (err) {
                    error.FileNotFound => {
                        self.host_available = false;
                        return;
                    },
                    else => return err,
                };
                errdefer managed.deinit(self.allocator);
                try self.routes.append(self.allocator, managed);
            }
        }

        self.refreshSinkInputIndexes() catch |err| switch (err) {
            error.FileNotFound, error.HostCommandFailed => {
                self.host_available = false;
                return;
            },
            else => return err,
        };

        for (channels) |channel| {
            const channel_uses_fx = containsChannel(fx_channels, channel.id);
            for (self.routes.items) |route| {
                if (!std.mem.eql(u8, route.channel_id, channel.id)) continue;

                const gain = effectiveRouteGain(route, channel, sends, channel_uses_fx) orelse continue;
                self.applyRouteGain(route, gain) catch |err| switch (err) {
                    error.FileNotFound, error.HostCommandFailed => {
                        self.host_available = false;
                        return;
                    },
                    else => return err,
                };
            }
        }

        self.last_signature = signature;
    }

    fn spawnRoute(self: *InputLoopbackManager, spec: RouteSpec) !ManagedRoute {
        const route_name = try allocRouteName(self.allocator, spec.kind, spec.channel_id, spec.capture_id, spec.target_id);
        errdefer self.allocator.free(route_name);

        const media_name = try std.fmt.allocPrint(self.allocator, "wiredeck-route-{s}", .{routeNameSuffix(route_name)});
        errdefer self.allocator.free(media_name);

        const playback_name = switch (spec.kind) {
            .source_to_bus => try allocOutputSinkName(self.allocator, spec.target_id),
            .source_to_fx => try allocInputSinkName(self.allocator, spec.target_id),
            .fx_to_bus => try allocOutputSinkName(self.allocator, spec.target_id),
        };
        defer self.allocator.free(playback_name);

        const capture_target = switch (spec.kind) {
            .fx_to_bus => try allocFxSinkName(self.allocator, spec.capture_id),
            else => try self.allocator.dupe(u8, spec.capture_id),
        };
        defer self.allocator.free(capture_target);

        const capture_props = switch (spec.kind) {
            .fx_to_bus => try std.fmt.allocPrint(
                self.allocator,
                "node.passive=true stream.capture.sink=true target.object={s}",
                .{capture_target},
            ),
            else => try std.fmt.allocPrint(
                self.allocator,
                "node.passive=true target.object={s}",
                .{capture_target},
            ),
        };
        defer self.allocator.free(capture_props);

        const playback_props = try std.fmt.allocPrint(
            self.allocator,
            "node.passive=true node.dont-reconnect=true media.name={s} wiredeck.route.kind={s} wiredeck.channel.id={s} wiredeck.capture.id={s} wiredeck.target.id={s}",
            .{ media_name, @tagName(spec.kind), spec.channel_id, spec.capture_id, spec.target_id },
        );
        defer self.allocator.free(playback_props);

        const command = try buildCommand(
            self.allocator,
            route_name,
            capture_target,
            playback_name,
            capture_props,
            playback_props,
        );
        errdefer self.allocator.free(command);

        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(self.allocator);

        if (std.process.hasEnvVarConstant("FLATPAK_ID")) {
            try argv.appendSlice(self.allocator, &.{ "flatpak-spawn", "--host", "sh", "-lc", command });
        } else {
            try argv.appendSlice(self.allocator, &.{ "sh", "-lc", command });
        }

        var child = std.process.Child.init(argv.items, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        try child.spawn();

        return .{
            .kind = spec.kind,
            .channel_id = try self.allocator.dupe(u8, spec.channel_id),
            .capture_id = try self.allocator.dupe(u8, spec.capture_id),
            .target_id = try self.allocator.dupe(u8, spec.target_id),
            .route_name = route_name,
            .media_name = media_name,
            .command = command,
            .child = child,
        };
    }

    fn refreshSinkInputIndexes(self: *InputLoopbackManager) !void {
        const text = try runHostCommand(self.allocator, &.{ "pactl", "list", "sink-inputs" });
        defer self.allocator.free(text);

        for (self.routes.items) |*route| route.sink_input_index = null;

        var sections = std.mem.splitSequence(u8, text, "\n\n");
        while (sections.next()) |section| {
            const sink_input_index = parseSinkInputIndex(section) orelse continue;
            const media_name = parseSinkInputMediaName(section) orelse continue;

            for (self.routes.items) |*route| {
                if (std.mem.eql(u8, route.media_name, media_name)) {
                    route.sink_input_index = sink_input_index;
                    break;
                }
            }
        }
    }

    fn applyRouteGain(self: *InputLoopbackManager, route: ManagedRoute, gain: f32) !void {
        const sink_input_index = route.sink_input_index orelse return;
        const rendered_id = try std.fmt.allocPrint(self.allocator, "{d}", .{sink_input_index});
        defer self.allocator.free(rendered_id);

        const volume_percent = std.math.clamp(@as(u32, @intFromFloat(@round(gain * 100.0))), 0, 150);
        const volume_arg = try std.fmt.allocPrint(self.allocator, "{d}%", .{volume_percent});
        defer self.allocator.free(volume_arg);

        const output = try runHostCommand(self.allocator, &.{ "pactl", "set-sink-input-volume", rendered_id, volume_arg });
        defer self.allocator.free(output);
    }
};

const RouteSpec = struct {
    kind: InputLoopbackManager.RouteKind,
    channel_id: []const u8,
    capture_id: []const u8,
    target_id: []const u8,
};

fn buildDesiredRoutes(
    allocator: std.mem.Allocator,
    desired: *std.ArrayList(RouteSpec),
    channels: []const channels_mod.Channel,
    sources: []const sources_mod.Source,
    channel_sources: []const channel_sources_mod.ChannelSource,
    buses: []const buses_mod.Bus,
    sends: []const sends_mod.Send,
    fx_channels: []const channels_mod.Channel,
) !void {
    for (channels) |channel| {
        const channel_uses_fx = containsChannel(fx_channels, channel.id);

        for (channel_sources) |channel_source| {
            if (!channel_source.enabled) continue;
            if (!std.mem.eql(u8, channel_source.channel_id, channel.id)) continue;
            if (findSource(sources, channel_source.source_id) == null) continue;

            if (channel_uses_fx) {
                if (channelRequiresFxInput(sends, channel.id)) {
                    try desired.append(allocator, .{
                        .kind = .source_to_fx,
                        .channel_id = channel.id,
                        .capture_id = channel_source.source_id,
                        .target_id = channel.id,
                    });
                }
            } else {
                for (buses) |bus| {
                    const send = findSend(sends, channel.id, bus.id) orelse continue;
                    if (!send.enabled) continue;

                    try desired.append(allocator, .{
                        .kind = .source_to_bus,
                        .channel_id = channel.id,
                        .capture_id = channel_source.source_id,
                        .target_id = bus.id,
                    });
                }
            }
        }

        if (!channel_uses_fx) continue;

        for (buses) |bus| {
            const send = findSend(sends, channel.id, bus.id) orelse continue;
            if (!send.enabled) continue;

            try desired.append(allocator, .{
                .kind = .fx_to_bus,
                .channel_id = channel.id,
                .capture_id = channel.id,
                .target_id = bus.id,
            });
        }
    }
}

fn computeSignature(
    channels: []const channels_mod.Channel,
    sources: []const sources_mod.Source,
    channel_sources: []const channel_sources_mod.ChannelSource,
    buses: []const buses_mod.Bus,
    sends: []const sends_mod.Send,
    fx_channels: []const channels_mod.Channel,
) u64 {
    var hasher = std.hash.Wyhash.init(0);

    for (channels) |channel| {
        hasher.update(channel.id);
        hasher.update(std.mem.asBytes(&[_]u8{
            @intFromFloat(@round(channel.volume * 100.0)),
            @intFromBool(channel.muted),
        }));
    }

    for (sources) |source| {
        hasher.update(source.id);
        hasher.update(&[_]u8{@intFromEnum(source.kind)});
    }

    for (channel_sources) |item| {
        hasher.update(item.channel_id);
        hasher.update(item.source_id);
        hasher.update(&[_]u8{@intFromBool(item.enabled)});
    }

    for (buses) |bus| {
        hasher.update(bus.id);
        hasher.update(&[_]u8{0});
    }

    for (sends) |send| {
        hasher.update(send.channel_id);
        hasher.update(send.bus_id);
        hasher.update(&[_]u8{
            @intFromBool(send.enabled),
            @intFromFloat(@round(send.gain * 100.0)),
        });
    }

    for (fx_channels) |channel| {
        hasher.update(channel.id);
        hasher.update("fx");
    }

    return hasher.final();
}

fn effectiveRouteGain(
    route: InputLoopbackManager.ManagedRoute,
    channel: channels_mod.Channel,
    sends: []const sends_mod.Send,
    channel_uses_fx: bool,
) ?f32 {
    return switch (route.kind) {
        .source_to_fx => if (channel_uses_fx) 1.0 else null,
        .fx_to_bus => blk: {
            if (!channel_uses_fx) break :blk null;
            const send = findSend(sends, channel.id, route.target_id) orelse break :blk null;
            if (!send.enabled) break :blk null;
            break :blk if (channel.muted) 0.0 else std.math.clamp(channel.volume * send.gain, 0.0, 1.5);
        },
        .source_to_bus => blk: {
            const send = findSend(sends, channel.id, route.target_id) orelse break :blk null;
            if (!send.enabled) break :blk null;
            break :blk if (channel.muted) 0.0 else std.math.clamp(channel.volume * send.gain, 0.0, 1.5);
        },
    };
}

fn channelRequiresFxInput(sends: []const sends_mod.Send, channel_id: []const u8) bool {
    for (sends) |send| {
        if (!std.mem.eql(u8, send.channel_id, channel_id)) continue;
        if (send.enabled) return true;
    }
    return false;
}

fn buildCommand(
    allocator: std.mem.Allocator,
    route_name: []const u8,
    capture_id: []const u8,
    playback_name: []const u8,
    capture_props: []const u8,
    playback_props: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "exec pw-loopback --name '{s}' --capture '{s}' --playback '{s}' --capture-props '{s}' --playback-props '{s}'",
        .{ route_name, capture_id, playback_name, capture_props, playback_props },
    );
}

fn allocRouteName(
    allocator: std.mem.Allocator,
    kind: InputLoopbackManager.RouteKind,
    channel_id: []const u8,
    capture_id: []const u8,
    target_id: []const u8,
) ![]u8 {
    const raw = try std.fmt.allocPrint(
        allocator,
        "wiredeck_{s}_{s}_{s}_{s}",
        .{ @tagName(kind), channel_id, capture_id, target_id },
    );
    defer allocator.free(raw);

    var out = try allocator.alloc(u8, raw.len);
    for (raw, 0..) |char, index| {
        out[index] = if (std.ascii.isAlphanumeric(char)) std.ascii.toLower(char) else '_';
    }
    return out;
}

fn routeNameSuffix(route_name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, route_name, "wiredeck_")) return route_name["wiredeck_".len..];
    return route_name;
}

fn allocOutputSinkName(allocator: std.mem.Allocator, bus_id: []const u8) ![]u8 {
    var sink_name = try allocator.alloc(u8, output_prefix.len + bus_id.len);
    @memcpy(sink_name[0..output_prefix.len], output_prefix);
    for (bus_id, output_prefix.len..) |char, index| {
        sink_name[index] = if (std.ascii.isAlphanumeric(char)) std.ascii.toLower(char) else '_';
    }
    return sink_name;
}

fn allocInputSinkName(allocator: std.mem.Allocator, channel_id: []const u8) ![]u8 {
    var sink_name = try allocator.alloc(u8, input_prefix.len + channel_id.len);
    @memcpy(sink_name[0..input_prefix.len], input_prefix);
    for (channel_id, input_prefix.len..) |char, index| {
        sink_name[index] = if (std.ascii.isAlphanumeric(char)) std.ascii.toLower(char) else '_';
    }
    return sink_name;
}

fn allocFxSinkName(allocator: std.mem.Allocator, channel_id: []const u8) ![]u8 {
    var sink_name = try allocator.alloc(u8, fx_prefix.len + channel_id.len);
    @memcpy(sink_name[0..fx_prefix.len], fx_prefix);
    for (channel_id, fx_prefix.len..) |char, index| {
        sink_name[index] = if (std.ascii.isAlphanumeric(char)) std.ascii.toLower(char) else '_';
    }
    return sink_name;
}

fn containsRouteSpec(
    specs: []const RouteSpec,
    kind: InputLoopbackManager.RouteKind,
    channel_id: []const u8,
    capture_id: []const u8,
    target_id: []const u8,
) bool {
    for (specs) |spec| {
        if (spec.kind == kind and
            std.mem.eql(u8, spec.channel_id, channel_id) and
            std.mem.eql(u8, spec.capture_id, capture_id) and
            std.mem.eql(u8, spec.target_id, target_id))
        {
            return true;
        }
    }
    return false;
}

fn findManagedRoute(
    routes: []const InputLoopbackManager.ManagedRoute,
    kind: InputLoopbackManager.RouteKind,
    channel_id: []const u8,
    capture_id: []const u8,
    target_id: []const u8,
) ?usize {
    for (routes, 0..) |route, index| {
        if (route.kind == kind and
            std.mem.eql(u8, route.channel_id, channel_id) and
            std.mem.eql(u8, route.capture_id, capture_id) and
            std.mem.eql(u8, route.target_id, target_id))
        {
            return index;
        }
    }
    return null;
}

fn containsChannel(channels: []const channels_mod.Channel, channel_id: []const u8) bool {
    for (channels) |channel| {
        if (std.mem.eql(u8, channel.id, channel_id)) return true;
    }
    return false;
}

fn findSend(sends: []const sends_mod.Send, channel_id: []const u8, bus_id: []const u8) ?sends_mod.Send {
    for (sends) |send| {
        if (std.mem.eql(u8, send.channel_id, channel_id) and std.mem.eql(u8, send.bus_id, bus_id)) return send;
    }
    return null;
}

fn findSource(sources: []const sources_mod.Source, source_id: []const u8) ?sources_mod.Source {
    for (sources) |source| {
        if (std.mem.eql(u8, source.id, source_id)) return source;
    }
    return null;
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

fn killChild(child: *std.process.Child) void {
    _ = child.kill() catch {};
}

fn parseSinkInputIndex(section: []const u8) ?u32 {
    const header_end = std.mem.indexOfScalar(u8, section, '\n') orelse section.len;
    const header = std.mem.trim(u8, section[0..header_end], &std.ascii.whitespace);
    if (!std.mem.startsWith(u8, header, "Sink Input #")) return null;
    return std.fmt.parseInt(u32, header["Sink Input #".len..], 10) catch null;
}

fn parseSinkInputMediaName(section: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, section, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (!std.mem.startsWith(u8, trimmed, "media.name = ")) continue;
        return std.mem.trim(u8, trimmed["media.name = ".len..], "\"");
    }
    return null;
}
