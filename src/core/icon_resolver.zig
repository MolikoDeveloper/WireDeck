const std = @import("std");

const Allocator = std.mem.Allocator;

pub const ResolveInput = struct {
    process_binary: ?[]const u8 = null,
    app_name: ?[]const u8 = null,
    startup_wm_class: ?[]const u8 = null,
};

pub const DesktopEntry = struct {
    desktop_file_path: []const u8,
    desktop_file_id: []const u8,

    name: ?[]const u8 = null,
    exec: ?[]const u8 = null,
    try_exec: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    startup_wm_class: ?[]const u8 = null,
};

pub const ResolveResult = struct {
    desktop_file_path: ?[]const u8 = null,
    desktop_file_id: ?[]const u8 = null,
    desktop_name: ?[]const u8 = null,

    icon_name: ?[]const u8 = null,
    icon_path: ?[]const u8 = null,

    score: u32 = 0,
};

pub fn resolve(
    allocator: Allocator,
    input: ResolveInput,
) !ResolveResult {
    var best: ?DesktopEntry = null;
    var best_score: u32 = 0;

    const desktop_paths = try collectDesktopSearchPaths(allocator);
    defer freeStringList(allocator, desktop_paths);

    for (desktop_paths) |base_path| {
        try scanDesktopDir(
            allocator,
            base_path,
            input,
            &best,
            &best_score,
        );
    }

    if (best == null) {
        return .{};
    }

    const chosen = best.?;

    errdefer freeDesktopEntry(allocator, chosen);

    var result = ResolveResult{
        .desktop_file_path = try allocator.dupe(u8, chosen.desktop_file_path),
        .desktop_file_id = try allocator.dupe(u8, chosen.desktop_file_id),
        .desktop_name = if (chosen.name) |v| try allocator.dupe(u8, v) else null,
        .icon_name = if (chosen.icon) |v| try allocator.dupe(u8, v) else null,
        .icon_path = null,
        .score = best_score,
    };

    if (chosen.icon) |icon_value| {
        if (std.fs.path.isAbsolute(icon_value)) {
            if (fileExistsAbsolute(icon_value)) {
                result.icon_path = try allocator.dupe(u8, icon_value);
            }
        } else {
            result.icon_path = try resolveIconPath(allocator, icon_value);
            if (result.icon_path == null) {
                result.icon_path = try resolveIconPathForFlatpakApp(allocator, chosen.desktop_file_path, icon_value);
            }
        }
    }

    freeDesktopEntry(allocator, chosen);
    return result;
}

pub fn freeResolveResult(allocator: Allocator, result: ResolveResult) void {
    freeOpt(allocator, result.desktop_file_path);
    freeOpt(allocator, result.desktop_file_id);
    freeOpt(allocator, result.desktop_name);
    freeOpt(allocator, result.icon_name);
    freeOpt(allocator, result.icon_path);
}

fn scanDesktopDir(
    allocator: Allocator,
    base_path: []const u8,
    input: ResolveInput,
    best: *?DesktopEntry,
    best_score: *u32,
) !void {
    var dir = std.fs.openDirAbsolute(base_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.path, ".desktop")) continue;

        const full_path = try std.fs.path.join(allocator, &.{ base_path, entry.path });
        defer allocator.free(full_path);

        const parsed = parseDesktopEntryFile(allocator, full_path) catch continue;
        defer freeDesktopEntry(allocator, parsed);

        const score = scoreDesktopEntry(parsed, input);
        if (score == 0) continue;

        if (best.* == null or score > best_score.*) {
            if (best.*) |prev| freeDesktopEntry(allocator, prev);

            best.* = try cloneDesktopEntry(allocator, parsed);
            best_score.* = score;
        }
    }
}

fn parseDesktopEntryFile(
    allocator: Allocator,
    path: []const u8,
) !DesktopEntry {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, 1024 * 128);
    defer allocator.free(contents);

    var in_desktop_entry = false;

    var entry = DesktopEntry{
        .desktop_file_path = try allocator.dupe(u8, path),
        .desktop_file_id = try allocator.dupe(u8, std.fs.path.basename(path)),
    };
    errdefer freeDesktopEntry(allocator, entry);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        if (line[0] == '[' and line[line.len - 1] == ']') {
            in_desktop_entry = std.mem.eql(u8, line, "[Desktop Entry]");
            continue;
        }

        if (!in_desktop_entry) continue;

        const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq_idx], " \t\r");
        const value = std.mem.trim(u8, line[eq_idx + 1 ..], " \t\r");

        if (std.mem.startsWith(u8, key, "Name[")) continue;
        if (std.mem.startsWith(u8, key, "Icon[")) continue;

        if (std.mem.eql(u8, key, "Name")) {
            replaceDup(allocator, &entry.name, value) catch {};
        } else if (std.mem.eql(u8, key, "Exec")) {
            replaceDup(allocator, &entry.exec, value) catch {};
        } else if (std.mem.eql(u8, key, "TryExec")) {
            replaceDup(allocator, &entry.try_exec, value) catch {};
        } else if (std.mem.eql(u8, key, "Icon")) {
            replaceDup(allocator, &entry.icon, value) catch {};
        } else if (std.mem.eql(u8, key, "StartupWMClass")) {
            replaceDup(allocator, &entry.startup_wm_class, value) catch {};
        }
    }

    return entry;
}

fn scoreDesktopEntry(entry: DesktopEntry, input: ResolveInput) u32 {
    var score: u32 = 0;

    if (input.process_binary) |binary| {
        if (entry.try_exec) |try_exec| {
            if (execMatchesBinary(try_exec, binary)) score += 120;
        }
        if (entry.exec) |exec_value| {
            if (execMatchesBinary(exec_value, binary)) score += 100;
        }
        if (entry.desktop_file_id.len > 0) {
            const stem = stripDesktopSuffix(entry.desktop_file_id);
            if (nameLooselyMatches(stem, binary)) score += 40;
        }
        if (entry.name) |name| {
            if (nameLooselyMatches(name, binary)) score += 20;
        }
    }

    if (input.app_name) |app_name| {
        if (entry.name) |name| {
            if (nameLooselyMatches(name, app_name)) score += 80;
        }
        if (entry.startup_wm_class) |wm| {
            if (nameLooselyMatches(wm, app_name)) score += 60;
        }
        const stem = stripDesktopSuffix(entry.desktop_file_id);
        if (nameLooselyMatches(stem, app_name)) score += 35;
    }

    if (input.startup_wm_class) |wmc| {
        if (entry.startup_wm_class) |wm| {
            if (nameLooselyMatches(wm, wmc)) score += 100;
        }
    }

    return score;
}

fn execMatchesBinary(exec_value: []const u8, binary: []const u8) bool {
    const token = firstExecToken(exec_value) orelse return false;
    return binaryMatchesExecToken(binary, token);
}

fn firstExecToken(exec_value: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, exec_value, " \t");
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        if (tok[0] == '%') continue;
        return tok;
    }
    return null;
}

fn binaryMatchesExecToken(binary: []const u8, token: []const u8) bool {
    const token_base = std.fs.path.basename(token);
    if (nameLooselyMatches(token_base, binary)) return true;
    if (nameLooselyMatches(token, binary)) return true;
    return false;
}

fn nameLooselyMatches(a: []const u8, b: []const u8) bool {
    if (asciiEqIgnoreCase(a, b)) return true;

    // Try matching on the last segment of dotted or dashed names (e.g. "com.discordapp.Discord" -> "Discord").
    if (asciiEqIgnoreCase(lastSegment(a, '.'), b)) return true;
    if (asciiEqIgnoreCase(lastSegment(a, '-'), b)) return true;
    if (asciiEqIgnoreCase(lastSegment(b, '.'), a)) return true;
    if (asciiEqIgnoreCase(lastSegment(b, '-'), a)) return true;

    const a_norm = normalizeTemp(a);
    const b_norm = normalizeTemp(b);
    return std.mem.eql(u8, a_norm, b_norm);
}

fn lastSegment(s: []const u8, sep: u8) []const u8 {
    var i: usize = s.len;
    while (i > 0) : (i -= 1) {
        if (s[i - 1] == sep) {
            return s[i..];
        }
    }
    return s;
}

fn normalizeTemp(s: []const u8) []const u8 {
    return s;
}

fn asciiEqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (std.ascii.toLower(a[i]) != std.ascii.toLower(b[i])) return false;
    }
    return true;
}

fn stripDesktopSuffix(name: []const u8) []const u8 {
    if (std.mem.endsWith(u8, name, ".desktop")) {
        return name[0 .. name.len - ".desktop".len];
    }
    return name;
}

fn resolveIconPath(
    allocator: Allocator,
    icon_name: []const u8,
) !?[]const u8 {
    const roots = try collectIconSearchPaths(allocator);
    defer freeStringList(allocator, roots);

    for (roots) |root| {
        const found = try resolveIconPathInRoot(allocator, root, icon_name);
        if (found) |path| return path;
    }

    return null;
}

fn resolveIconPathInRoot(
    allocator: Allocator,
    root: []const u8,
    icon_name: []const u8,
) !?[]const u8 {
    const exts = [_][]const u8{ ".png", ".svg", ".xpm" };

    const debug = std.posix.getenv("WIREDECK_ICON_DEBUG") != null;
    if (debug) std.debug.print("resolveIconPath: icon_name={s}\n", .{icon_name});

    for (exts) |ext| {
        const icon_file_name = try std.mem.concat(allocator, u8, &.{ icon_name, ext });
        defer allocator.free(icon_file_name);

        const direct = try std.fs.path.join(allocator, &.{ root, icon_file_name });
        defer allocator.free(direct);
        if (debug) std.debug.print(" trying candidate: {s}\n", .{direct});
        if (fileExistsAbsolute(direct)) {
            if (debug) std.debug.print("  found: {s}\n", .{direct});
            return try allocator.dupe(u8, direct);
        }
    }

    const themes = try collectThemeNames(allocator);
    defer freeStringList(allocator, themes);

    for (themes) |theme| {
        const found = try recursiveFindIconInTheme(allocator, root, theme, icon_name);
        if (found) |path| return path;
    }

    const found = try recursiveFindInPixmaps(allocator, root, icon_name);
    if (found) |path| return path;

    return null;
}

fn resolveIconPathForFlatpakApp(
    allocator: Allocator,
    desktop_file_path: []const u8,
    icon_name: []const u8,
) !?[]const u8 {
    // Follow symlinks in case the desktop file is a flatpak exports symlink.
    // This ensures we can map to the actual flatpak app directory when searching for icons.
    var real_desktop_path: []const u8 = desktop_file_path;
    var real_desktop_path_alloc: ?[]const u8 = null;
    const resolved = std.fs.realpathAlloc(allocator, desktop_file_path) catch null;
    if (resolved) |r| {
        real_desktop_path = r;
        real_desktop_path_alloc = r;
    }
    defer if (real_desktop_path_alloc) |p| allocator.free(p);

    const markers = [_][]const u8{ "/export/share/applications/", "/exports/share/applications/" };
    for (markers) |marker| {
        if (std.mem.indexOf(u8, real_desktop_path, marker)) |pos| {
            const base = real_desktop_path[0..pos];
            const icons_root = try std.fs.path.join(allocator, &.{ base, "files", "share", "icons" });
            defer allocator.free(icons_root);

            const found = try resolveIconPathInRoot(allocator, icons_root, icon_name);
            if (found) |path| return path;
        }
    }
    return null;
}

fn recursiveFindIconInTheme(
    allocator: Allocator,
    root: []const u8,
    theme: []const u8,
    icon_name: []const u8,
) !?[]const u8 {
    const debug = std.posix.getenv("WIREDECK_ICON_DEBUG") != null;
    if (debug) std.debug.print("recursiveFindIconInTheme: root={s} theme={s} icon={s}\n", .{ root, theme, icon_name });

    const base = try std.fs.path.join(allocator, &.{ root, theme });
    defer allocator.free(base);

    var dir = std.fs.openDirAbsolute(base, .{ .iterate = true }) catch return null;
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;

        const base_name = std.fs.path.basename(entry.path);
        const matches = iconFileMatches(base_name, icon_name);
        if (debug) std.debug.print("  entry={s} basename={s} matches={s}\n", .{ entry.path, base_name, if (matches) "1" else "0" });
        if (!matches) continue;

        const full = try std.fs.path.join(allocator, &.{ base, entry.path });
        if (debug) std.debug.print("  FOUND full={s}\n", .{full});
        return full;
    }

    if (!std.mem.eql(u8, theme, "hicolor")) {
        return try recursiveFindIconInTheme(allocator, root, "hicolor", icon_name);
    }

    return null;
}

fn recursiveFindInPixmaps(
    allocator: Allocator,
    root: []const u8,
    icon_name: []const u8,
) !?[]const u8 {
    const debug = std.posix.getenv("WIREDECK_ICON_DEBUG") != null;
    if (debug) std.debug.print("recursiveFindInPixmaps: root={s} icon={s}\n", .{ root, icon_name });

    const pixmaps = try std.fs.path.join(allocator, &.{ root, "..", "pixmaps" });
    defer allocator.free(pixmaps);

    var dir = std.fs.openDirAbsolute(pixmaps, .{ .iterate = true }) catch return null;
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;

        const base_name = std.fs.path.basename(entry.path);
        if (!iconFileMatches(base_name, icon_name)) continue;

        const full = try std.fs.path.join(allocator, &.{ pixmaps, entry.path });
        return full;
    }

    return null;
}

fn iconFileMatches(file_name: []const u8, icon_name: []const u8) bool {
    const stem = std.fs.path.stem(file_name);
    return asciiEqIgnoreCase(stem, icon_name);
}

fn collectDesktopSearchPaths(allocator: Allocator) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    defer out.deinit(allocator);

    if (std.posix.getenv("XDG_DATA_HOME")) |xdg_home| {
        const p = try std.fs.path.join(allocator, &.{ xdg_home, "applications" });
        try appendUniqueOwned(allocator, &out, p);
    } else if (std.posix.getenv("HOME")) |home| {
        const p = try std.fs.path.join(allocator, &.{ home, ".local/share/applications" });
        try appendUniqueOwned(allocator, &out, p);
    }

    if (std.posix.getenv("HOME")) |home| {
        const flatpak_user = try std.fs.path.join(allocator, &.{ home, ".local/share/flatpak/exports/share/applications" });
        try appendUniqueOwned(allocator, &out, flatpak_user);
    }

    try appendUniqueOwned(allocator, &out, try allocator.dupe(u8, "/var/lib/flatpak/exports/share/applications"));

    const xdg_data_dirs = if (std.posix.getenv("XDG_DATA_DIRS")) |v|
        v
    else
        "/usr/local/share:/usr/share";

    var it = std.mem.splitScalar(u8, xdg_data_dirs, ':');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        const p = try std.fs.path.join(allocator, &.{ part, "applications" });
        try appendUniqueOwned(allocator, &out, p);
    }

    return try out.toOwnedSlice(allocator);
}

fn collectIconSearchPaths(allocator: Allocator) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    defer out.deinit(allocator);

    if (std.posix.getenv("HOME")) |home| {
        try appendUniqueOwned(allocator, &out, try std.fs.path.join(allocator, &.{ home, ".icons" }));
        try appendUniqueOwned(allocator, &out, try std.fs.path.join(allocator, &.{ home, ".local/share/icons" }));
    }

    try appendUniqueOwned(allocator, &out, try allocator.dupe(u8, "/usr/share/icons"));
    try appendUniqueOwned(allocator, &out, try allocator.dupe(u8, "/usr/local/share/icons"));

    return try out.toOwnedSlice(allocator);
}

fn collectThemeNames(allocator: Allocator) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    defer out.deinit(allocator);

    if (std.posix.getenv("ICON_THEME")) |theme| {
        try appendUniqueOwned(allocator, &out, try allocator.dupe(u8, theme));
    }

    try appendUniqueOwned(allocator, &out, try allocator.dupe(u8, "Papirus"));
    try appendUniqueOwned(allocator, &out, try allocator.dupe(u8, "Adwaita"));
    try appendUniqueOwned(allocator, &out, try allocator.dupe(u8, "hicolor"));

    return try out.toOwnedSlice(allocator);
}

fn appendUniqueOwned(
    allocator: Allocator,
    list: *std.ArrayList([]const u8),
    value: []const u8,
) !void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, value)) {
            allocator.free(value);
            return;
        }
    }
    try list.append(allocator, value);
}

fn cloneDesktopEntry(allocator: Allocator, entry: DesktopEntry) !DesktopEntry {
    return .{
        .desktop_file_path = try allocator.dupe(u8, entry.desktop_file_path),
        .desktop_file_id = try allocator.dupe(u8, entry.desktop_file_id),
        .name = if (entry.name) |v| try allocator.dupe(u8, v) else null,
        .exec = if (entry.exec) |v| try allocator.dupe(u8, v) else null,
        .try_exec = if (entry.try_exec) |v| try allocator.dupe(u8, v) else null,
        .icon = if (entry.icon) |v| try allocator.dupe(u8, v) else null,
        .startup_wm_class = if (entry.startup_wm_class) |v| try allocator.dupe(u8, v) else null,
    };
}

fn freeDesktopEntry(allocator: Allocator, entry: DesktopEntry) void {
    allocator.free(entry.desktop_file_path);
    allocator.free(entry.desktop_file_id);
    freeOpt(allocator, entry.name);
    freeOpt(allocator, entry.exec);
    freeOpt(allocator, entry.try_exec);
    freeOpt(allocator, entry.icon);
    freeOpt(allocator, entry.startup_wm_class);
}

fn replaceDup(
    allocator: Allocator,
    dst: *?[]const u8,
    value: []const u8,
) !void {
    freeOpt(allocator, dst.*);
    dst.* = try allocator.dupe(u8, value);
}

fn fileExistsAbsolute(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn freeStringList(allocator: Allocator, items: [][]const u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

fn freeOpt(allocator: Allocator, value: ?[]const u8) void {
    if (value) |v| allocator.free(v);
}
