const std = @import("std");
const wiredeck = @import("wiredeck");
const c = @cImport({
    @cInclude("sys/file.h");
    @cInclude("signal.h");
    @cInclude("unistd.h");
});

const CliOptions = struct {
    headless: bool = false,
    frames: ?u32 = null,
    start_hidden: bool = false,
    convert_app: ?[]const u8 = null,
    print_source_activity: bool = false,
    source_filter: ?[]const u8 = null,
    activity_ticks: u32 = 120,
    cleanup_audio_state: bool = false,
    cleanup_watchdog_pid: ?u32 = null,
};

pub fn main() !void {
    const options = try parseArgs(std.heap.page_allocator);
    wiredeck.RuntimeShutdown.installSignalHandlers();

    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa_state.deinit();
        if (leaked == .leak) std.log.err("memory leak detected", .{});
    }

    const gpa = gpa_state.allocator();

    if (options.cleanup_watchdog_pid) |pid| {
        try runCleanupWatchdog(gpa, pid);
        return;
    }

    if (options.cleanup_audio_state) {
        try cleanupManagedAudioState(gpa);
        return;
    }

    var instance_guard = try SingleInstanceGuard.acquire(gpa);
    defer instance_guard.release();
    var state_store = wiredeck.StateStore.init(gpa);
    defer state_store.deinit();

    var app = wiredeck.App.init(gpa, &state_store);
    defer app.deinit();

    var config_store = try wiredeck.ConfigStore.init(gpa);
    defer config_store.deinit();
    try app.prepareBootstrapState();
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
        app.reconcileCurrentRoutingNow() catch |err| {
            if (err != error.CaptureSinkPending) {
                std.log.warn("startup routing reconcile failed: {s}", .{@errorName(err)});
            }
        };
    }
    app.reconcileCurrentRoutingNow() catch |err| {
        if (err != error.CaptureSinkPending) {
            std.log.warn("startup routing reconcile failed: {s}", .{@errorName(err)});
        }
    };
    if (loaded_config) app.markRoutingDirty();
    app.startBackgroundServices();
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

    if (!options.headless) {
        try wiredeck.UiShell.run(.{
            .title = "WireDeck",
            .max_frames = options.frames,
            .start_hidden = options.start_hidden,
        }, &app, &state_store, &config_store);
    }
}

const SingleInstanceGuard = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    path: []u8,

    fn acquire(allocator: std.mem.Allocator) !SingleInstanceGuard {
        const path = try defaultLockPath(allocator);
        errdefer allocator.free(path);

        const parent_dir = std.fs.path.dirname(path) orelse return error.InvalidLockPath;
        std.fs.makeDirAbsolute(parent_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const file = try std.fs.createFileAbsolute(path, .{
            .read = true,
            .truncate = false,
        });
        errdefer file.close();

        if (c.flock(file.handle, c.LOCK_EX | c.LOCK_NB) != 0) {
            return error.WireDeckAlreadyRunning;
        }

        return .{
            .allocator = allocator,
            .file = file,
            .path = path,
        };
    }

    fn release(self: *SingleInstanceGuard) void {
        _ = c.flock(self.file.handle, c.LOCK_UN);
        self.file.close();
        self.allocator.free(self.path);
    }
};

fn defaultLockPath(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "XDG_RUNTIME_DIR")) |runtime_dir| {
        defer allocator.free(runtime_dir);
        return std.fs.path.join(allocator, &.{ runtime_dir, "wiredeck.lock" });
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }

    const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.NoHomeDirectory,
        else => return err,
    };
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".config", "wiredeck", "instance.lock" });
}

fn parseArgs(allocator: std.mem.Allocator) !CliOptions {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var options = CliOptions{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) {
            continue;
        }
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
        if (std.mem.eql(u8, arg, "--cleanup-audio-state")) {
            options.cleanup_audio_state = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--cleanup-watchdog-pid")) {
            index += 1;
            if (index >= args.len) return error.MissingCleanupWatchdogPidValue;
            options.cleanup_watchdog_pid = try std.fmt.parseInt(u32, args[index], 10);
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

fn spawnCleanupWatchdog(allocator: std.mem.Allocator) !void {
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);

    const pid_arg = try std.fmt.allocPrint(allocator, "{d}", .{c.getpid()});
    defer allocator.free(pid_arg);

    var child = std.process.Child.init(&.{ exe_path, "--cleanup-watchdog-pid", pid_arg }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.request_resource_usage_statistics = false;
    child.spawn() catch |err| {
        std.log.warn("cleanup watchdog spawn failed: {s}", .{@errorName(err)});
        return;
    };
}

fn runCleanupWatchdog(allocator: std.mem.Allocator, pid: u32) !void {
    _ = allocator;
    while (true) {
        std.Thread.sleep(200 * std.time.ns_per_ms);
        const rc = c.kill(@intCast(pid), 0);
        if (rc == 0) continue;
        break;
    }
    cleanupManagedAudioState(std.heap.page_allocator) catch {};
}

fn cleanupManagedAudioState(allocator: std.mem.Allocator) !void {
    std.log.info("shutdown cleanup: probing managed audio state", .{});
    var state_store = wiredeck.StateStore.init(allocator);
    defer state_store.deinit();

    var app = wiredeck.App.init(allocator, &state_store);
    defer app.deinit();

    try app.cleanupStartupBindings();
    std.log.info("shutdown cleanup: startup bindings cleared", .{});
    wiredeck.OutputExposure.cleanupManagedVirtualMicState(allocator) catch |err| {
        std.log.warn("managed virtual mic cleanup failed: {s}", .{@errorName(err)});
    };
    std.log.info("shutdown cleanup: default audio source restored", .{});
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
            if (app.audio_engine.channelLevels(channel.id, .post_fx)) |levels| {
                var post_fx_left_db_buf: [24]u8 = undefined;
                var post_fx_right_db_buf: [24]u8 = undefined;
                var post_fx_peak_db_buf: [24]u8 = undefined;
                std.debug.print(
                    "    engine.post_fx L={d:.4} {s} R={d:.4} {s} peak={d:.4} {s}\n",
                    .{
                        levels.left,
                        dbLabel(&post_fx_left_db_buf, levels.left),
                        levels.right,
                        dbLabel(&post_fx_right_db_buf, levels.right),
                        levels.level,
                        dbLabel(&post_fx_peak_db_buf, levels.level),
                    },
                );
            }
            if (app.audio_engine.channelLevels(channel.id, .post_fader)) |levels| {
                var post_fader_left_db_buf: [24]u8 = undefined;
                var post_fader_right_db_buf: [24]u8 = undefined;
                var post_fader_peak_db_buf: [24]u8 = undefined;
                std.debug.print(
                    "    engine.post_fader L={d:.4} {s} R={d:.4} {s} peak={d:.4} {s}\n",
                    .{
                        levels.left,
                        dbLabel(&post_fader_left_db_buf, levels.left),
                        levels.right,
                        dbLabel(&post_fader_right_db_buf, levels.right),
                        levels.level,
                        dbLabel(&post_fader_peak_db_buf, levels.level),
                    },
                );
            }
        }
        if (!matched_channels) {
            std.debug.print("  none\n", .{});
        }

        var matched_buses = false;
        std.debug.print("engine buses\n", .{});
        for (state_store.buses.items) |bus| {
            const needle = source_filter orelse "";
            const matches = source_filter == null or
                containsIgnoreCase(bus.id, needle) or
                containsIgnoreCase(bus.label, needle);
            if (!matches) continue;
            matched_buses = true;
            if (app.audio_engine.busLevels(bus.id)) |levels| {
                var bus_left_db_buf: [24]u8 = undefined;
                var bus_right_db_buf: [24]u8 = undefined;
                var bus_peak_db_buf: [24]u8 = undefined;
                std.debug.print(
                    "  bus={s}\n    label={s}\n    contributors={d}\n    L={d:.4} {s}\n    R={d:.4} {s}\n    peak={d:.4} {s}\n",
                    .{
                        bus.id,
                        bus.label,
                        levels.contributor_count,
                        levels.mix.left,
                        dbLabel(&bus_left_db_buf, levels.mix.left),
                        levels.mix.right,
                        dbLabel(&bus_right_db_buf, levels.mix.right),
                        levels.mix.level,
                        dbLabel(&bus_peak_db_buf, levels.mix.level),
                    },
                );
            } else {
                std.debug.print("  bus={s}\n    label={s}\n    no engine levels yet\n", .{ bus.id, bus.label });
            }
        }
        if (!matched_buses) {
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
