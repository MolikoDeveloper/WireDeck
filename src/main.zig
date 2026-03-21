const std = @import("std");
const wiredeck = @import("wiredeck");

const CliOptions = struct {
    headless: bool = false,
    frames: ?u32 = null,
    start_hidden: bool = false,
    convert_app: ?[]const u8 = null,
    print_source_activity: bool = false,
    source_filter: ?[]const u8 = null,
    activity_ticks: u32 = 120,
};

pub fn main() !void {
    const options = try parseArgs(std.heap.page_allocator);

    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa_state.deinit();
        if (leaked == .leak) std.log.err("memory leak detected", .{});
    }

    const gpa = gpa_state.allocator();

    var state_store = wiredeck.StateStore.init(gpa);
    defer state_store.deinit();

    var app = wiredeck.App.init(gpa, &state_store);
    defer app.deinit();

    var config_store = try wiredeck.ConfigStore.init(gpa);
    defer config_store.deinit();
    try app.bootstrap();
    app.cleanupStartupBindings() catch |err| {
        std.log.warn("startup routing cleanup failed: {s}", .{@errorName(err)});
    };
    const loaded_config = config_store.load(&state_store) catch |err| blk: {
        std.log.warn("config load failed: {s}", .{@errorName(err)});
        break :blk false;
    };
    if (loaded_config) {
        app.normalizeConfiguredBindingsToDefault() catch |err| {
            std.log.warn("startup route normalization failed: {s}", .{@errorName(err)});
        };
        app.markRoutingDirty();
        app.reconcileOutputRoutingIfNeeded();
    }
    defer {
        config_store.save(&state_store) catch |err| {
            std.log.warn("config save failed: {s}", .{@errorName(err)});
        };
    }

    if (options.convert_app) |app_name| {
        try convertAppIcon(&state_store, app_name);
        return;
    }

    if (options.print_source_activity) {
        try printSourceActivity(&app, &state_store, options.source_filter, options.activity_ticks);
        return;
    }

    printBootstrapLog(&state_store);

    if (!options.headless) {
        try wiredeck.UiShell.run(.{
            .title = "WireDeck",
            .max_frames = options.frames,
            .start_hidden = options.start_hidden,
        }, &app, &state_store, &config_store);
    }
}

fn parseArgs(allocator: std.mem.Allocator) !CliOptions {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var options = CliOptions{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--headless")) {
            options.headless = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--frames")) {
            index += 1;
            if (index >= args.len) return error.MissingFramesValue;
            options.frames = try std.fmt.parseInt(u32, args[index], 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--start-hidden")) {
            options.start_hidden = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--convert-app")) {
            index += 1;
            if (index >= args.len) return error.MissingConvertAppValue;
            options.convert_app = try allocator.dupe(u8, args[index]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--print-source-activity")) {
            options.print_source_activity = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--source-filter")) {
            index += 1;
            if (index >= args.len) return error.MissingSourceFilterValue;
            options.source_filter = try allocator.dupe(u8, args[index]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--activity-ticks")) {
            index += 1;
            if (index >= args.len) return error.MissingActivityTicksValue;
            options.activity_ticks = try std.fmt.parseInt(u32, args[index], 10);
            continue;
        }
        return error.UnknownArgument;
    }
    return options;
}

fn convertAppIcon(state_store: *const wiredeck.StateStore, app_name: []const u8) !void {
    const source = findAppSource(state_store, app_name) orelse return error.SourceNotFound;
    if (source.icon_path.len == 0) return error.SourceHasNoIconPath;

    const icon_path_z = try std.heap.page_allocator.dupeZ(u8, source.icon_path);
    defer std.heap.page_allocator.free(icon_path_z);

    var output_buffer: [std.fs.max_path_bytes]u8 = std.mem.zeroes([std.fs.max_path_bytes]u8);
    if (wiredeck.ImGuiBridge.wiredeck_imgui_convert_icon_path(icon_path_z.ptr, &output_buffer, output_buffer.len) == 0) {
        std.debug.print("icon conversion failed: {s}\n", .{wiredeck.ImGuiBridge.wiredeck_imgui_last_error() orelse "unknown error"});
        return error.IconConvertFailed;
    }

    const rendered_path = std.mem.sliceTo(&output_buffer, 0);
    std.debug.print("converted app={s} source={s} icon={s} -> {s}\n", .{
        app_name,
        source.label,
        source.icon_path,
        rendered_path,
    });
}

fn printSourceActivity(
    app: *wiredeck.App,
    state_store: *const wiredeck.StateStore,
    source_filter: ?[]const u8,
    activity_ticks: u32,
) !void {
    std.debug.print("WireDeck source activity\n", .{});
    if (source_filter) |filter| {
        std.debug.print("filter: {s}\n", .{filter});
    }
    std.debug.print("ticks: {d}\n\n", .{activity_ticks});

    app.refreshAudioInventory() catch {};
    std.Thread.sleep(120 * std.time.ns_per_ms);

    var tick: u32 = 0;
    while (tick < activity_ticks) : (tick += 1) {
        try app.pumpLiveAudio();
        var discovery = try app.pipewire_live.snapshotDiscovery(std.heap.page_allocator);
        defer discovery.deinit(std.heap.page_allocator);

        std.debug.print("[tick {d}]\n", .{tick});

        var matched_channels = false;
        std.debug.print("strips\n", .{});
        for (state_store.channels.items) |channel| {
            const needle = source_filter orelse "";
            const matches = source_filter == null or
                containsIgnoreCase(channel.id, needle) or
                containsIgnoreCase(channel.label, needle) or
                containsIgnoreCase(channel.subtitle, needle) or
                (channel.bound_source_id != null and containsIgnoreCase(channel.bound_source_id.?, needle));
            if (!matches) continue;
            matched_channels = true;
            var left_db_buf: [24]u8 = undefined;
            var right_db_buf: [24]u8 = undefined;
            var mono_db_buf: [24]u8 = undefined;
            std.debug.print(
                "  strip={s}\n    label={s}\n    source={s}\n    L={d:.4} {s}\n    R={d:.4} {s}\n    peak={d:.4} {s}\n    muted={any}\n",
                .{
                    channel.id,
                    channel.label,
                    channel.bound_source_id orelse "",
                    channel.level_left,
                    dbLabel(&left_db_buf, channel.level_left),
                    channel.level_right,
                    dbLabel(&right_db_buf, channel.level_right),
                    channel.level,
                    dbLabel(&mono_db_buf, channel.level),
                    channel.muted,
                },
            );
        }
        if (!matched_channels) {
            std.debug.print("  none\n", .{});
        }

        var matched_any = false;
        std.debug.print("state sources\n", .{});
        for (state_store.sources.items) |source| {
            if (!sourceMatchesFilter(source, source_filter)) continue;
            matched_any = true;
            var left_db_buf: [24]u8 = undefined;
            var right_db_buf: [24]u8 = undefined;
            var mono_db_buf: [24]u8 = undefined;
            std.debug.print(
                "  source={s}\n    kind={s}\n    label={s}\n    subtitle={s}\n    L={d:.4} {s}\n    R={d:.4} {s}\n    peak={d:.4} {s}\n    muted={any}\n",
                .{
                    source.id,
                    @tagName(source.kind),
                    source.label,
                    source.subtitle,
                    source.level_left,
                    dbLabel(&left_db_buf, source.level_left),
                    source.level_right,
                    dbLabel(&right_db_buf, source.level_right),
                    source.level,
                    dbLabel(&mono_db_buf, source.level),
                    source.muted,
                },
            );
        }
        if (!matched_any) {
            std.debug.print("  none\n", .{});
        }

        var matched_discovery = false;
        std.debug.print("raw discovery (channels={d})\n", .{discovery.channels.items.len});
        for (discovery.channels.items) |source| {
            if (!sourceMatchesFilter(source, source_filter)) continue;
            matched_discovery = true;
            var left_db_buf: [24]u8 = undefined;
            var right_db_buf: [24]u8 = undefined;
            var mono_db_buf: [24]u8 = undefined;
            std.debug.print(
                "  raw={s}\n    kind={s}\n    label={s}\n    subtitle={s}\n    L={d:.4} {s}\n    R={d:.4} {s}\n    peak={d:.4} {s}\n    muted={any}\n",
                .{
                    source.id,
                    @tagName(source.kind),
                    source.label,
                    source.subtitle,
                    source.level_left,
                    dbLabel(&left_db_buf, source.level_left),
                    source.level_right,
                    dbLabel(&right_db_buf, source.level_right),
                    source.level,
                    dbLabel(&mono_db_buf, source.level),
                    source.muted,
                },
            );
        }
        if (!matched_discovery) {
            std.debug.print("  none\n", .{});
        }
        std.debug.print("\n", .{});
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
}

fn findAppSource(state_store: *const wiredeck.StateStore, app_name: []const u8) ?wiredeck.Source {
    for (state_store.sources.items) |source| {
        if (source.kind != .app) continue;
        if (std.ascii.eqlIgnoreCase(source.label, app_name)) return source;
        if (std.ascii.eqlIgnoreCase(source.process_binary, app_name)) return source;
        if (std.ascii.eqlIgnoreCase(source.id, app_name)) return source;
    }
    for (state_store.sources.items) |source| {
        if (source.kind != .app) continue;
        if (containsIgnoreCase(source.label, app_name)) return source;
        if (containsIgnoreCase(source.process_binary, app_name)) return source;
        if (containsIgnoreCase(source.id, app_name)) return source;
    }
    return null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

fn sourceMatchesFilter(source: wiredeck.Source, filter: ?[]const u8) bool {
    const needle = filter orelse return true;
    return containsIgnoreCase(source.id, needle) or
        containsIgnoreCase(source.label, needle) or
        containsIgnoreCase(source.subtitle, needle) or
        containsIgnoreCase(source.process_binary, needle);
}

fn linearToDb(value: f32) f32 {
    if (value <= 0.000001) return -120.0;
    return 20.0 * std.math.log10(value);
}

fn dbLabel(buf: []u8, value: f32) []const u8 {
    if (value <= 0.000001) return "-inf dBFS";
    return std.fmt.bufPrint(buf, "{d:.1} dBFS", .{linearToDb(value)}) catch "-err dBFS";
}

fn printBootstrapLog(state_store: *const wiredeck.StateStore) void {
    std.debug.print(
        "WireDeck V2 bootstrap ready\nactive profile: {s}\nchannels: {d}\nbuses: {d}\nsources: {d}\ndestinations: {d}\n",
        .{
            state_store.active_profile,
            state_store.channels.items.len,
            state_store.buses.items.len,
            state_store.sources.items.len,
            state_store.destinations.items.len,
        },
    );

    std.debug.print("\n[channels]\n", .{});
    for (state_store.channels.items) |channel| {
        std.debug.print(
            "channel {s} label={s} subtitle={s} volume={d:.2} muted={any}\n",
            .{ channel.id, channel.label, channel.subtitle, channel.volume, channel.muted },
        );
    }

    std.debug.print("\n[buses]\n", .{});
    for (state_store.buses.items) |bus| {
        std.debug.print(
            "bus {s} label={s} volume={d:.2} muted={any}\n",
            .{ bus.id, bus.label, bus.volume, bus.muted },
        );
    }

    std.debug.print("\n[sources]\n", .{});
    for (state_store.sources.items) |source| {
        std.debug.print(
            "source {s} kind={s} label={s} subtitle={s} icon={s} icon_path={s} binary={s} level={d:.2} muted={any}\n",
            .{
                source.id,
                @tagName(source.kind),
                source.label,
                source.subtitle,
                source.icon_name,
                source.icon_path,
                source.process_binary,
                source.level,
                source.muted,
            },
        );
    }

    std.debug.print("\n[destinations]\n", .{});
    for (state_store.destinations.items) |destination| {
        std.debug.print(
            "destination {s} kind={s} label={s} subtitle={s}\n",
            .{
                destination.id,
                @tagName(destination.kind),
                destination.label,
                destination.subtitle,
            },
        );
    }
}

test "state store initializes empty" {
    var store = wiredeck.StateStore.init(std.testing.allocator);
    defer store.deinit();

    try std.testing.expectEqual(@as(usize, 0), store.channels.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.sources.items.len);
}

test "audio core defaults remain available" {
    const defaults = wiredeck.AudioCore.defaultChannels();
    try std.testing.expectEqual(@as(usize, 3), defaults.len);
    try std.testing.expectEqualStrings("mic", defaults[0].id);
}

test "parse args symbol remains reachable" {
    _ = parseArgs;
    try std.testing.expect(true);
}
