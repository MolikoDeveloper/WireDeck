const std = @import("std");
const host = @import("host.zig");
const build_options = @import("build_options");

const LilvBackend = if (build_options.enable_lilv) struct {
    const c = @cImport({
        @cInclude("lilv/lilv.h");
    });
    const lv2_enabled_uri = "http://lv2plug.in/ns/lv2core#enabled";
    const lv2_bypass_uri = "http://lv2plug.in/ns/ext/parameters#bypass";

    fn discover(allocator: std.mem.Allocator) ![]host.PluginDescriptor {
        const search_roots = try collectSearchRoots(allocator);
        defer freeStringList(allocator, search_roots);
        const bundle_paths = try collectBundlePaths(allocator, search_roots);
        defer freeStringList(allocator, bundle_paths);

        const world = c.lilv_world_new() orelse return try discoverWithManifestFallback(allocator);
        defer c.lilv_world_free(world);

        const input_port_class = c.lilv_new_uri(world, c.LILV_URI_INPUT_PORT) orelse return error.OutOfMemory;
        defer c.lilv_node_free(input_port_class);
        const control_port_class = c.lilv_new_uri(world, c.LILV_URI_CONTROL_PORT) orelse return error.OutOfMemory;
        defer c.lilv_node_free(control_port_class);
        const toggled_property = c.lilv_new_uri(world, c.LILV_NS_LV2 ++ "toggled") orelse return error.OutOfMemory;
        defer c.lilv_node_free(toggled_property);
        const integer_property = c.lilv_new_uri(world, c.LILV_NS_LV2 ++ "integer") orelse return error.OutOfMemory;
        defer c.lilv_node_free(integer_property);
        const enumeration_property = c.lilv_new_uri(world, c.LILV_NS_LV2 ++ "enumeration") orelse return error.OutOfMemory;
        defer c.lilv_node_free(enumeration_property);
        const enabled_designation = c.lilv_new_uri(world, lv2_enabled_uri) orelse return error.OutOfMemory;
        defer c.lilv_node_free(enabled_designation);
        const bypass_designation = c.lilv_new_uri(world, lv2_bypass_uri) orelse return error.OutOfMemory;
        defer c.lilv_node_free(bypass_designation);

        c.lilv_world_load_specifications(world);
        for (bundle_paths) |bundle_path| {
            const bundle_path_z = try allocator.dupeZ(u8, bundle_path);
            defer allocator.free(bundle_path_z);
            const bundle_uri = c.lilv_new_file_uri(world, null, bundle_path_z.ptr) orelse continue;
            defer c.lilv_node_free(bundle_uri);
            c.lilv_world_load_bundle(world, bundle_uri);
        }

        const plugins = c.lilv_world_get_all_plugins(world);
        var descriptors = std.ArrayList(host.PluginDescriptor).empty;
        errdefer descriptors.deinit(allocator);

        var iter = c.lilv_plugins_begin(plugins);
        while (!c.lilv_plugins_is_end(plugins, iter)) : (iter = c.lilv_plugins_next(plugins, iter)) {
            const plugin = c.lilv_plugins_get(plugins, iter) orelse continue;
            const uri_node = c.lilv_plugin_get_uri(plugin);
            const name_node = c.lilv_plugin_get_name(plugin);
            const category = pluginCategory(plugin);
            const bundle_name = try pluginBundleName(allocator, plugin);
            errdefer allocator.free(bundle_name);
            const control_ports = try discoverControlPorts(
                allocator,
                plugin,
                input_port_class,
                control_port_class,
                toggled_property,
                integer_property,
                enumeration_property,
                enabled_designation,
                bypass_designation,
            );
            errdefer freeControlPorts(allocator, control_ports);
            const ui_info = try discoverUiInfo(allocator, plugin);
            errdefer allocator.free(ui_info.primary_ui_uri);

            const uri = std.mem.span(c.lilv_node_as_uri(uri_node));
            const name = if (name_node != null) std.mem.span(c.lilv_node_as_string(name_node)) else uri;

            try descriptors.append(allocator, .{
                .id = try allocator.dupe(u8, uri),
                .label = try allocator.dupe(u8, name),
                .backend = .lv2,
                .category = try allocator.dupe(u8, category),
                .bundle_name = bundle_name,
                .control_ports = control_ports,
                .has_custom_ui = ui_info.has_custom_ui,
                .primary_ui_uri = ui_info.primary_ui_uri,
            });
        }

        std.mem.sort(host.PluginDescriptor, descriptors.items, {}, sortDescriptors);
        return try descriptors.toOwnedSlice(allocator);
    }

    fn pluginCategory(plugin: *const c.LilvPlugin) []const u8 {
        const klass = c.lilv_plugin_get_class(plugin);
        if (klass == null) return "lv2";
        const label_node = c.lilv_plugin_class_get_label(klass);
        if (label_node == null) return "lv2";
        return std.mem.span(c.lilv_node_as_string(label_node));
    }

    fn pluginBundleName(allocator: std.mem.Allocator, plugin: *const c.LilvPlugin) ![]u8 {
        const bundle_uri = c.lilv_plugin_get_bundle_uri(plugin);
        const bundle_uri_text = c.lilv_node_as_uri(bundle_uri);
        const path_ptr = c.lilv_file_uri_parse(bundle_uri_text, null) orelse return try allocator.dupe(u8, "lv2");
        defer c.lilv_free(path_ptr);
        const bundle_path = std.mem.span(path_ptr);
        const trimmed = std.mem.trimRight(u8, bundle_path, "/");
        return try allocator.dupe(u8, std.fs.path.basename(trimmed));
    }

    fn discoverControlPorts(
        allocator: std.mem.Allocator,
        plugin: *const c.LilvPlugin,
        input_port_class: *c.LilvNode,
        control_port_class: *c.LilvNode,
        toggled_property: *c.LilvNode,
        integer_property: *c.LilvNode,
        enumeration_property: *c.LilvNode,
        enabled_designation: *c.LilvNode,
        bypass_designation: *c.LilvNode,
    ) ![]host.PluginControlPort {
        const port_count = c.lilv_plugin_get_num_ports(plugin);
        const min_values = try allocator.alloc(f32, port_count);
        defer allocator.free(min_values);
        const max_values = try allocator.alloc(f32, port_count);
        defer allocator.free(max_values);
        const default_values = try allocator.alloc(f32, port_count);
        defer allocator.free(default_values);
        c.lilv_plugin_get_port_ranges_float(plugin, min_values.ptr, max_values.ptr, default_values.ptr);

        var ports = std.ArrayList(host.PluginControlPort).empty;
        errdefer {
            for (ports.items) |port| {
                allocator.free(port.symbol);
                allocator.free(port.label);
            }
            ports.deinit(allocator);
        }

        const enabled_port = c.lilv_plugin_get_port_by_designation(plugin, null, enabled_designation);
        const enabled_index: ?u32 = if (enabled_port != null) c.lilv_port_get_index(plugin, enabled_port) else null;
        const bypass_port = c.lilv_plugin_get_port_by_designation(plugin, null, bypass_designation);
        const bypass_index: ?u32 = if (bypass_port != null) c.lilv_port_get_index(plugin, bypass_port) else null;

        var port_index: u32 = 0;
        while (port_index < port_count) : (port_index += 1) {
            const port = c.lilv_plugin_get_port_by_index(plugin, port_index) orelse continue;
            if (!c.lilv_port_is_a(plugin, port, control_port_class)) continue;

            const symbol_node = c.lilv_port_get_symbol(plugin, port);
            const name_node = c.lilv_port_get_name(plugin, port);
            defer if (name_node != null) c.lilv_node_free(name_node);

            const symbol = std.mem.span(c.lilv_node_as_string(symbol_node));
            const label = if (name_node != null) std.mem.span(c.lilv_node_as_string(name_node)) else symbol;
            const min_value = if (std.math.isNan(min_values[port_index])) 0.0 else min_values[port_index];
            const max_value = if (std.math.isNan(max_values[port_index])) 1.0 else max_values[port_index];
            const default_value = if (std.math.isNan(default_values[port_index])) min_value else default_values[port_index];

            try ports.append(allocator, .{
                .index = port_index,
                .symbol = try allocator.dupe(u8, symbol),
                .label = try allocator.dupe(u8, label),
                .is_output = !c.lilv_port_is_a(plugin, port, input_port_class),
                .min_value = min_value,
                .max_value = max_value,
                .default_value = std.math.clamp(default_value, min_value, max_value),
                .toggled = c.lilv_port_has_property(plugin, port, toggled_property),
                .integer = c.lilv_port_has_property(plugin, port, integer_property),
                .enumeration = c.lilv_port_has_property(plugin, port, enumeration_property),
                .sync_kind = if (enabled_index != null and port_index == enabled_index.?)
                    .plugin_enabled
                else if (bypass_index != null and port_index == bypass_index.?)
                    .plugin_bypass
                else
                    .none,
            });
        }

        return try ports.toOwnedSlice(allocator);
    }

    fn freeControlPorts(allocator: std.mem.Allocator, ports: []host.PluginControlPort) void {
        for (ports) |port| {
            allocator.free(port.symbol);
            allocator.free(port.label);
        }
        allocator.free(ports);
    }

    const PluginUiInfo = struct {
        has_custom_ui: bool = false,
        primary_ui_uri: []u8,
    };

    fn discoverUiInfo(allocator: std.mem.Allocator, plugin: *const c.LilvPlugin) !PluginUiInfo {
        const uis = c.lilv_plugin_get_uis(plugin) orelse return .{ .primary_ui_uri = try allocator.dupe(u8, "") };

        if (c.lilv_uis_size(uis) == 0) {
            return .{ .primary_ui_uri = try allocator.dupe(u8, "") };
        }

        const iter = c.lilv_uis_begin(uis);
        if (c.lilv_uis_is_end(uis, iter)) {
            return .{ .primary_ui_uri = try allocator.dupe(u8, "") };
        }

        const ui = c.lilv_uis_get(uis, iter) orelse return .{ .primary_ui_uri = try allocator.dupe(u8, "") };
        const ui_uri = c.lilv_ui_get_uri(ui);
        return .{
            .has_custom_ui = true,
            .primary_ui_uri = try allocator.dupe(u8, std.mem.span(c.lilv_node_as_uri(ui_uri))),
        };
    }
} else struct {
    fn discover(allocator: std.mem.Allocator) ![]host.PluginDescriptor {
        return try discoverWithManifestFallback(allocator);
    }
};

pub const Lv2Support = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Lv2Support {
        return .{ .allocator = allocator };
    }

    pub fn discoverDescriptors(self: *const Lv2Support) ![]host.PluginDescriptor {
        return try LilvBackend.discover(self.allocator);
    }
};

fn discoverWithManifestFallback(allocator: std.mem.Allocator) ![]host.PluginDescriptor {
    const search_roots = try collectSearchRoots(allocator);
    defer freeStringList(allocator, search_roots);
    const bundle_paths = try collectBundlePaths(allocator, search_roots);
    defer freeStringList(allocator, bundle_paths);

    var descriptors = std.ArrayList(host.PluginDescriptor).empty;
    errdefer descriptors.deinit(allocator);

    for (bundle_paths) |bundle_path| {
        const parsed = try parseBundleDescriptor(allocator, bundle_path);
        if (parsed) |descriptor| {
            try descriptors.append(allocator, descriptor);
        }
    }

    std.mem.sort(host.PluginDescriptor, descriptors.items, {}, sortDescriptors);
    return try descriptors.toOwnedSlice(allocator);
}

fn parseBundleDescriptor(allocator: std.mem.Allocator, bundle_path: []const u8) !?host.PluginDescriptor {
    var bundle_dir = try std.fs.openDirAbsolute(bundle_path, .{ .iterate = true });
    defer bundle_dir.close();

    var manifest_first = std.ArrayList([]const u8).empty;
    defer manifest_first.deinit(allocator);
    var other_ttls = std.ArrayList([]const u8).empty;
    defer other_ttls.deinit(allocator);

    var iter = bundle_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".ttl")) continue;
        if (std.mem.eql(u8, entry.name, "manifest.ttl")) {
            try manifest_first.append(allocator, try allocator.dupe(u8, entry.name));
        } else {
            try other_ttls.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }

    for (manifest_first.items) |ttl_name| {
        defer allocator.free(ttl_name);
        if (try parseDescriptorFromTtl(allocator, bundle_path, ttl_name)) |descriptor| return descriptor;
    }
    for (other_ttls.items) |ttl_name| {
        defer allocator.free(ttl_name);
        if (try parseDescriptorFromTtl(allocator, bundle_path, ttl_name)) |descriptor| return descriptor;
    }
    return null;
}

fn parseDescriptorFromTtl(allocator: std.mem.Allocator, bundle_path: []const u8, ttl_name: []const u8) !?host.PluginDescriptor {
    const ttl_path = try std.fs.path.join(allocator, &.{ bundle_path, ttl_name });
    defer allocator.free(ttl_path);

    const file = try std.fs.openFileAbsolute(ttl_path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(allocator, 8 * 1024 * 1024);
    defer allocator.free(contents);

    const uri = parsePluginUri(contents) orelse return null;
    const label = parseQuotedValueAfter(contents, "doap:name") orelse parseQuotedValueAfter(contents, "rdfs:label") orelse uri;

    return .{
        .id = try allocator.dupe(u8, uri),
        .label = try allocator.dupe(u8, label),
        .backend = .lv2,
        .category = try allocator.dupe(u8, "lv2"),
        .bundle_name = try allocator.dupe(u8, std.fs.path.basename(bundle_path)),
        .primary_ui_uri = try allocator.dupe(u8, ""),
    };
}

pub fn collectBundlePaths(allocator: std.mem.Allocator, search_roots: [][]u8) ![][]u8 {
    var bundles = std.ArrayList([]u8).empty;
    errdefer freeCollectedStrings(allocator, &bundles);

    var unique_paths = std.StringHashMap(void).init(allocator);
    var preferred_bundle_names = std.StringHashMap(void).init(allocator);
    defer {
        var iter = unique_paths.keyIterator();
        while (iter.next()) |key| allocator.free(key.*);
        unique_paths.deinit();

        var names_iter = preferred_bundle_names.keyIterator();
        while (names_iter.next()) |key| allocator.free(key.*);
        preferred_bundle_names.deinit();
    }

    for (search_roots) |root_path| {
        var root_dir = std.fs.openDirAbsolute(root_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer root_dir.close();

        var walker = try root_dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .directory) continue;
            if (!std.mem.endsWith(u8, entry.path, ".lv2")) continue;

            const bundle_path = try std.fs.path.join(allocator, &.{ root_path, entry.path });
            errdefer allocator.free(bundle_path);
            const path_key = try allocator.dupe(u8, bundle_path);
            errdefer allocator.free(path_key);

            const path_result = try unique_paths.getOrPut(path_key);
            if (path_result.found_existing) {
                allocator.free(bundle_path);
                allocator.free(path_key);
                continue;
            }

            const bundle_name = std.fs.path.basename(bundle_path);
            const bundle_name_key = try allocator.dupe(u8, bundle_name);
            errdefer allocator.free(bundle_name_key);
            const bundle_name_result = try preferred_bundle_names.getOrPut(bundle_name_key);
            if (bundle_name_result.found_existing) {
                _ = unique_paths.remove(path_key);
                allocator.free(bundle_path);
                allocator.free(bundle_name_key);
                allocator.free(path_key);
                continue;
            }

            try bundles.append(allocator, bundle_path);
        }
    }

    return try bundles.toOwnedSlice(allocator);
}

fn buildLilvSearchPath(allocator: std.mem.Allocator, search_roots: [][]u8) ![]u8 {
    if (search_roots.len == 0) return try allocator.dupe(u8, "");
    return try std.mem.join(allocator, ":", search_roots);
}

fn freeStringList(allocator: std.mem.Allocator, items: [][]u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

fn freeCollectedStrings(allocator: std.mem.Allocator, items: *std.ArrayList([]u8)) void {
    for (items.items) |item| allocator.free(item);
    items.deinit(allocator);
}

fn parsePluginUri(contents: []const u8) ?[]const u8 {
    const plugin_tag = " a lv2:Plugin";
    const plugin_index = std.mem.indexOf(u8, contents, plugin_tag) orelse return null;
    const subject_end = std.mem.lastIndexOfScalar(u8, contents[0..plugin_index], '>') orelse return null;
    const subject_start = std.mem.lastIndexOfScalar(u8, contents[0..subject_end], '<') orelse return null;
    if (subject_start + 1 >= subject_end) return null;
    return std.mem.trim(u8, contents[subject_start + 1 .. subject_end], &std.ascii.whitespace);
}

fn parseQuotedValueAfter(contents: []const u8, needle: []const u8) ?[]const u8 {
    const index = std.mem.indexOf(u8, contents, needle) orelse return null;
    const tail = contents[index + needle.len ..];
    const first_quote = std.mem.indexOfScalar(u8, tail, '"') orelse return null;
    const rest = tail[first_quote + 1 ..];
    const second_quote = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..second_quote];
}

fn sortDescriptors(_: void, lhs: host.PluginDescriptor, rhs: host.PluginDescriptor) bool {
    if (!std.mem.eql(u8, lhs.bundle_name, rhs.bundle_name)) {
        return std.ascii.lessThanIgnoreCase(lhs.bundle_name, rhs.bundle_name);
    }
    return std.ascii.lessThanIgnoreCase(lhs.label, rhs.label);
}

pub fn collectSearchRoots(allocator: std.mem.Allocator) ![][]u8 {
    var unique = std.StringHashMap(void).init(allocator);
    defer {
        var iter = unique.keyIterator();
        while (iter.next()) |key| allocator.free(key.*);
        unique.deinit();
    }

    var roots = std.ArrayList([]u8).empty;
    errdefer freeCollectedStrings(allocator, &roots);

    if (std.process.getEnvVarOwned(allocator, "LV2_PATH")) |env_value| {
        defer allocator.free(env_value);
        var parts = std.mem.splitScalar(u8, env_value, ':');
        while (parts.next()) |part| {
            const trimmed = std.mem.trim(u8, part, &std.ascii.whitespace);
            if (trimmed.len == 0) continue;
            try appendSearchRootIfExists(allocator, &roots, &unique, trimmed);
        }
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }

    const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return try roots.toOwnedSlice(allocator),
        else => return err,
    };
    defer allocator.free(home);

    const candidates = [_][]const u8{
        ".lv2",
        "/usr/lib/lv2",
        "/usr/local/lib/lv2",
        "/usr/lib64/lv2",
        "/usr/local/lib64/lv2",
    };

    for (candidates) |candidate| {
        const full_path = if (std.fs.path.isAbsolute(candidate))
            try allocator.dupe(u8, candidate)
        else
            try std.fs.path.join(allocator, &.{ home, candidate });
        defer allocator.free(full_path);
        try appendSearchRootIfExists(allocator, &roots, &unique, full_path);
    }

    return try roots.toOwnedSlice(allocator);
}

fn appendSearchRootIfExists(
    allocator: std.mem.Allocator,
    roots: *std.ArrayList([]u8),
    unique: *std.StringHashMap(void),
    candidate: []const u8,
) !void {
    var dir = std.fs.openDirAbsolute(candidate, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    dir.close();

    const key = try allocator.dupe(u8, candidate);
    errdefer allocator.free(key);
    const result = try unique.getOrPut(key);
    if (result.found_existing) {
        allocator.free(key);
        return;
    }
    try roots.append(allocator, try allocator.dupe(u8, candidate));
}

test "fallback parser extracts lv2 descriptor from ttl" {
    const ttl =
        \\@prefix lv2: <http://lv2plug.in/ns/lv2core#> .
        \\@prefix doap: <http://usefulinc.com/ns/doap#> .
        \\
        \\<https://example.org/plugins/test>
        \\    a lv2:Plugin ;
        \\    doap:name "Test Plugin" .
    ;

    try std.testing.expectEqualStrings("https://example.org/plugins/test", parsePluginUri(ttl).?);
    try std.testing.expectEqualStrings("Test Plugin", parseQuotedValueAfter(ttl, "doap:name").?);
}

test "collectBundlePaths finds lv2 bundles in nested directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("downloads/LV2/demo.lv2");
    try tmp.dir.writeFile(.{
        .sub_path = "downloads/LV2/demo.lv2/manifest.ttl",
        .data =
        \\@prefix lv2: <http://lv2plug.in/ns/lv2core#> .
        \\@prefix doap: <http://usefulinc.com/ns/doap#> .
        \\
        \\<https://example.org/plugins/demo>
        \\    a lv2:Plugin ;
        \\    doap:name "Demo Plugin" .
        ,
    });

    const root_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);

    const roots = try std.testing.allocator.dupe([]u8, &.{root_path});
    defer std.testing.allocator.free(roots);
    const bundles = try collectBundlePaths(std.testing.allocator, roots);
    defer freeStringList(std.testing.allocator, bundles);

    try std.testing.expectEqual(@as(usize, 1), bundles.len);
    try std.testing.expect(std.mem.endsWith(u8, bundles[0], "downloads/LV2/demo.lv2"));
}

test "collectBundlePaths prefers earlier roots for duplicate bundle names" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("home/.lv2/demo.lv2");
    try tmp.dir.makePath("usr/lib/lv2/demo.lv2");
    try tmp.dir.writeFile(.{
        .sub_path = "home/.lv2/demo.lv2/manifest.ttl",
        .data =
        \\@prefix lv2: <http://lv2plug.in/ns/lv2core#> .
        \\<https://example.org/plugins/demo-dev> a lv2:Plugin .
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "usr/lib/lv2/demo.lv2/manifest.ttl",
        .data =
        \\@prefix lv2: <http://lv2plug.in/ns/lv2core#> .
        \\<https://example.org/plugins/demo-system> a lv2:Plugin .
        ,
    });

    const home_root = try tmp.dir.realpathAlloc(std.testing.allocator, "home/.lv2");
    defer std.testing.allocator.free(home_root);
    const system_root = try tmp.dir.realpathAlloc(std.testing.allocator, "usr/lib/lv2");
    defer std.testing.allocator.free(system_root);

    const roots = try std.testing.allocator.alloc([]u8, 2);
    defer std.testing.allocator.free(roots);
    roots[0] = home_root;
    roots[1] = system_root;

    const bundles = try collectBundlePaths(std.testing.allocator, roots);
    defer freeStringList(std.testing.allocator, bundles);

    try std.testing.expectEqual(@as(usize, 1), bundles.len);
    try std.testing.expect(std.mem.startsWith(u8, bundles[0], home_root));
}

test "buildLilvSearchPath joins official roots" {
    const allocator = std.testing.allocator;
    const roots = try allocator.alloc([]u8, 2);
    defer allocator.free(roots);
    roots[0] = try allocator.dupe(u8, "/home/test/.lv2");
    roots[1] = try allocator.dupe(u8, "/usr/lib/lv2");
    defer allocator.free(roots[0]);
    defer allocator.free(roots[1]);

    const search_path = try buildLilvSearchPath(allocator, roots);
    defer allocator.free(search_path);

    try std.testing.expectEqualStrings("/home/test/.lv2:/usr/lib/lv2", search_path);
}
