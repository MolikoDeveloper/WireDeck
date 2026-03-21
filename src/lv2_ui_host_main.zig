const std = @import("std");

const c = @cImport({
    @cInclude("lilv/lilv.h");
    @cInclude("suil/suil.h");
    @cInclude("gtk/gtk.h");
    @cInclude("lv2/atom/atom.h");
    @cInclude("lv2/buf-size/buf-size.h");
    @cInclude("lv2/options/options.h");
    @cInclude("lv2/patch/patch.h");
    @cInclude("lv2/urid/urid.h");
});

const lv2_ui_uri_gtk = "http://lv2plug.in/ns/extensions/ui#GtkUI";
const lv2_ui_uri_parent = "http://lv2plug.in/ns/extensions/ui#parent";
const lv2_ui_uri_idle_interface = "http://lv2plug.in/ns/extensions/ui#idleInterface";
const lv2_instance_access_uri = "http://lv2plug.in/ns/ext/instance-access";

const ControlPort = struct {
    index: u32,
    symbol: []u8,
    value: f32,
};

const UiController = struct {
    allocator: std.mem.Allocator,
    ports: []ControlPort,

    fn deinit(self: *UiController) void {
        for (self.ports) |port| self.allocator.free(port.symbol);
        self.allocator.free(self.ports);
    }
};

const UridMapStore = struct {
    allocator: std.mem.Allocator,
    by_uri: std.StringHashMap(c.LV2_URID),
    by_id: std.ArrayList([:0]u8),

    fn init(allocator: std.mem.Allocator) UridMapStore {
        return .{
            .allocator = allocator,
            .by_uri = std.StringHashMap(c.LV2_URID).init(allocator),
            .by_id = std.ArrayList([:0]u8).empty,
        };
    }

    fn deinit(self: *UridMapStore) void {
        var iter = self.by_uri.keyIterator();
        while (iter.next()) |key| self.allocator.free(key.*);
        self.by_uri.deinit();
        for (self.by_id.items) |uri| self.allocator.free(uri);
        self.by_id.deinit(self.allocator);
    }

    fn map(self: *UridMapStore, uri: []const u8) c.LV2_URID {
        const owned_uri = self.allocator.dupe(u8, uri) catch return 0;
        const result = self.by_uri.getOrPut(owned_uri) catch {
            self.allocator.free(owned_uri);
            return 0;
        };
        if (result.found_existing) {
            self.allocator.free(owned_uri);
            return result.value_ptr.*;
        }

        const uri_z = self.allocator.dupeZ(u8, uri) catch {
            _ = self.by_uri.remove(owned_uri);
            self.allocator.free(owned_uri);
            return 0;
        };
        self.by_id.append(self.allocator, uri_z) catch {
            _ = self.by_uri.remove(owned_uri);
            self.allocator.free(owned_uri);
            self.allocator.free(uri_z);
            return 0;
        };

        const urid: c.LV2_URID = @intCast(self.by_id.items.len);
        result.value_ptr.* = urid;
        return urid;
    }

    fn unmap(self: *UridMapStore, urid: c.LV2_URID) ?[*:0]const u8 {
        if (urid == 0) return null;
        const index: usize = @intCast(urid - 1);
        if (index >= self.by_id.items.len) return null;
        return self.by_id.items[index].ptr;
    }
};

const FeatureContext = struct {
    urid_store: UridMapStore,
    urid_map_feature_data: c.LV2_URID_Map,
    urid_unmap_feature_data: c.LV2_URID_Unmap,
    urid_map_feature: c.LV2_Feature,
    urid_unmap_feature: c.LV2_Feature,
    bounded_block_length_feature: c.LV2_Feature,
    options_feature: c.LV2_Feature,
    options: [2]c.LV2_Options_Option,
    max_block_length_value: i32 = 256,
    feature_ptrs: [5]?*const c.LV2_Feature,

    fn init(allocator: std.mem.Allocator) !*FeatureContext {
        const context = try allocator.create(FeatureContext);
        context.* = .{
            .urid_store = UridMapStore.init(allocator),
            .urid_map_feature_data = .{
                .handle = undefined,
                .map = uridMapCallback,
            },
            .urid_unmap_feature_data = .{
                .handle = undefined,
                .unmap = uridUnmapCallback,
            },
            .urid_map_feature = .{
                .URI = c.LV2_URID__map,
                .data = undefined,
            },
            .urid_unmap_feature = .{
                .URI = c.LV2_URID__unmap,
                .data = undefined,
            },
            .bounded_block_length_feature = .{
                .URI = c.LV2_BUF_SIZE__boundedBlockLength,
                .data = null,
            },
            .options_feature = .{
                .URI = c.LV2_OPTIONS__options,
                .data = undefined,
            },
            .options = undefined,
            .feature_ptrs = .{ null, null, null, null, null },
        };
        context.urid_map_feature_data.handle = @ptrCast(&context.urid_store);
        context.urid_unmap_feature_data.handle = @ptrCast(&context.urid_store);
        context.urid_map_feature.data = @ptrCast(&context.urid_map_feature_data);
        context.urid_unmap_feature.data = @ptrCast(&context.urid_unmap_feature_data);

        const max_block_length_urid = context.urid_store.map(c.LV2_BUF_SIZE__maxBlockLength);
        const atom_int_urid = context.urid_store.map(c.LV2_ATOM__Int);
        context.options[0] = .{
            .context = c.LV2_OPTIONS_INSTANCE,
            .subject = 0,
            .key = max_block_length_urid,
            .size = @sizeOf(i32),
            .type = atom_int_urid,
            .value = @ptrCast(&context.max_block_length_value),
        };
        context.options[1] = .{
            .context = 0,
            .subject = 0,
            .key = 0,
            .size = 0,
            .type = 0,
            .value = null,
        };
        context.options_feature.data = @ptrCast(&context.options[0]);
        context.feature_ptrs = .{
            &context.urid_map_feature,
            &context.urid_unmap_feature,
            &context.bounded_block_length_feature,
            &context.options_feature,
            null,
        };
        return context;
    }

    fn deinit(self: *FeatureContext, allocator: std.mem.Allocator) void {
        self.urid_store.deinit();
        allocator.destroy(self);
    }
};

const CliOptions = struct {
    plugin_uri: []const u8,
    ui_uri: []const u8,
    title: []const u8,
    params: []const []const u8,
};

const Lv2UiIdleInterface = extern struct {
    idle: ?*const fn (?*anyopaque) callconv(.c) c_int,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const options = try parseArgs(allocator);
    const feature_context = try FeatureContext.init(allocator);
    defer feature_context.deinit(allocator);

    if (c.gtk_init_check(null, null) == 0) return error.GtkInitializationFailed;

    const world = c.lilv_world_new() orelse return error.OutOfMemory;
    defer c.lilv_world_free(world);
    c.lilv_world_load_all(world);

    const plugin = try findPlugin(world, options.plugin_uri);
    const ui = try findUi(world, plugin, options.ui_uri);
    const ui_type_uri = try resolveSupportedUiType(world, ui);
    const bundle_path = try parseFileUri(allocator, c.lilv_node_as_uri(c.lilv_ui_get_bundle_uri(ui)));
    const binary_path = try parseFileUri(allocator, c.lilv_node_as_uri(c.lilv_ui_get_binary_uri(ui)));

    const plugin_uri_z = try allocator.dupeZ(u8, options.plugin_uri);
    const ui_uri_z = try allocator.dupeZ(u8, options.ui_uri);
    const ui_type_uri_z = try allocator.dupeZ(u8, ui_type_uri);
    const bundle_path_z = try allocator.dupeZ(u8, bundle_path);
    const binary_path_z = try allocator.dupeZ(u8, binary_path);
    const title_z = try allocator.dupeZ(u8, options.title);

    const instance = c.lilv_plugin_instantiate(plugin, 48_000.0, @ptrCast(&feature_context.feature_ptrs)) orelse return error.PluginInstantiationFailed;
    defer c.lilv_instance_free(instance);

    var controller = try buildController(allocator, plugin, options.params);
    defer controller.deinit();
    connectPorts(instance, plugin, controller.ports);

    const window = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL) orelse return error.GtkWindowCreateFailed;
    const container = c.gtk_vbox_new(0, 0) orelse return error.GtkContainerCreateFailed;
    c.gtk_container_add(@ptrCast(window), container);
    c.gtk_window_set_title(@ptrCast(window), title_z.ptr);
    c.gtk_window_set_default_size(@ptrCast(window), 720, 520);
    _ = c.g_signal_connect_data(
        window,
        "delete-event",
        @ptrCast(&c.gtk_main_quit),
        null,
        null,
        0,
    );

    const host = c.suil_host_new(portWriteCallback, portIndexCallback, null, null) orelse return error.SuilHostCreateFailed;
    defer c.suil_host_free(host);

    var parent_feature = c.LV2_Feature{
        .URI = lv2_ui_uri_parent.ptr,
        .data = container,
    };
    const lilv_instance: [*c]const c.LilvInstance = @ptrCast(instance);
    var instance_access_feature = c.LV2_Feature{
        .URI = lv2_instance_access_uri.ptr,
        .data = c.lilv_instance_get_handle(lilv_instance),
    };
    var features: [8]?*const c.LV2_Feature = .{ null, null, null, null, null, null, null, null };
    var feature_count: usize = 0;
    while (feature_context.feature_ptrs[feature_count] != null and feature_count < features.len - 3) : (feature_count += 1) {
        features[feature_count] = feature_context.feature_ptrs[feature_count];
    }
    features[feature_count] = &parent_feature;
    features[feature_count + 1] = &instance_access_feature;
    features[feature_count + 2] = null;

    const suil_instance = c.suil_instance_new(
        host,
        @ptrCast(&controller),
        lv2_ui_uri_gtk.ptr,
        plugin_uri_z.ptr,
        ui_uri_z.ptr,
        ui_type_uri_z.ptr,
        bundle_path_z.ptr,
        binary_path_z.ptr,
        @ptrCast(&features[0]),
    ) orelse return error.SuilInstanceCreateFailed;
    defer c.suil_instance_free(suil_instance);

    const widget = c.suil_instance_get_widget(suil_instance) orelse return error.SuilWidgetUnavailable;
    const gtk_widget: *c.GtkWidget = @ptrCast(@alignCast(widget));
    c.gtk_container_add(@ptrCast(container), gtk_widget);

    for (controller.ports) |port| {
        if (port.index == std.math.maxInt(u32)) continue;
        var value = port.value;
        c.suil_instance_port_event(suil_instance, port.index, @sizeOf(f32), 0, &value);
    }

    if (extensionInterface(Lv2UiIdleInterface, suil_instance, lv2_ui_uri_idle_interface)) |idle_interface| {
        const idle_state = try allocator.create(IdleState);
        idle_state.* = .{
            .allocator = allocator,
            .controller = &controller,
            .instance = suil_instance,
            .idle_interface = idle_interface,
            .stdin_buffer = std.ArrayList(u8).empty,
        };
        _ = c.g_timeout_add(16, idleTickCallback, idle_state);
    }

    c.gtk_widget_show_all(window);
    c.gtk_main();
}

const IdleState = struct {
    allocator: std.mem.Allocator,
    controller: *UiController,
    instance: *c.SuilInstance,
    idle_interface: *const Lv2UiIdleInterface,
    stdin_buffer: std.ArrayList(u8),
};

fn parseArgs(allocator: std.mem.Allocator) !CliOptions {
    const args = try std.process.argsAlloc(allocator);
    if (args.len < 7) return error.InvalidArguments;

    var plugin_uri: ?[]const u8 = null;
    var ui_uri: ?[]const u8 = null;
    var title: ?[]const u8 = null;
    var params = std.ArrayList([]const u8).empty;

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--plugin-uri")) {
            index += 1;
            plugin_uri = args[index];
            continue;
        }
        if (std.mem.eql(u8, arg, "--ui-uri")) {
            index += 1;
            ui_uri = args[index];
            continue;
        }
        if (std.mem.eql(u8, arg, "--title")) {
            index += 1;
            title = args[index];
            continue;
        }
        if (std.mem.eql(u8, arg, "--param")) {
            index += 1;
            try params.append(allocator, args[index]);
            continue;
        }
        return error.InvalidArguments;
    }

    return .{
        .plugin_uri = plugin_uri orelse return error.InvalidArguments,
        .ui_uri = ui_uri orelse return error.InvalidArguments,
        .title = title orelse return error.InvalidArguments,
        .params = try params.toOwnedSlice(allocator),
    };
}

fn findPlugin(world: *c.LilvWorld, plugin_uri: []const u8) !*const c.LilvPlugin {
    const uri_z = try std.heap.page_allocator.dupeZ(u8, plugin_uri);
    defer std.heap.page_allocator.free(uri_z);
    const uri_node = c.lilv_new_uri(world, uri_z.ptr) orelse return error.OutOfMemory;
    defer c.lilv_node_free(uri_node);
    const plugins = c.lilv_world_get_all_plugins(world);
    return c.lilv_plugins_get_by_uri(plugins, uri_node) orelse error.UnknownPluginDescriptor;
}

fn findUi(world: *c.LilvWorld, plugin: *const c.LilvPlugin, ui_uri: []const u8) !*const c.LilvUI {
    const ui_uri_z = try std.heap.page_allocator.dupeZ(u8, ui_uri);
    defer std.heap.page_allocator.free(ui_uri_z);
    const ui_uri_node = c.lilv_new_uri(world, ui_uri_z.ptr) orelse return error.OutOfMemory;
    defer c.lilv_node_free(ui_uri_node);
    const uis = c.lilv_plugin_get_uis(plugin) orelse return error.PluginHasNoCustomUi;
    return c.lilv_uis_get_by_uri(uis, ui_uri_node) orelse error.PluginHasNoCustomUi;
}

fn resolveSupportedUiType(world: *c.LilvWorld, ui: *const c.LilvUI) ![]const u8 {
    const host_type = c.lilv_new_uri(world, lv2_ui_uri_gtk.ptr) orelse return error.OutOfMemory;
    defer c.lilv_node_free(host_type);
    var ui_type_node: ?*const c.LilvNode = null;
    if (c.lilv_ui_is_supported(ui, c.suil_ui_supported, host_type, &ui_type_node) == 0) {
        return error.UnsupportedUiType;
    }
    return std.mem.span(c.lilv_node_as_uri(ui_type_node));
}

fn parseFileUri(allocator: std.mem.Allocator, uri: [*c]const u8) ![]u8 {
    const path_ptr = c.lilv_file_uri_parse(uri, null) orelse return error.InvalidLilvFileUri;
    defer c.lilv_free(path_ptr);
    return try allocator.dupe(u8, std.mem.span(path_ptr));
}

fn buildController(allocator: std.mem.Allocator, plugin: *const c.LilvPlugin, raw_params: []const []const u8) !UiController {
    const port_count = c.lilv_plugin_get_num_ports(plugin);
    var ports = std.ArrayList(ControlPort).empty;
    errdefer {
        for (ports.items) |port| allocator.free(port.symbol);
        ports.deinit(allocator);
    }

    var index: u32 = 0;
    while (index < port_count) : (index += 1) {
        const port = c.lilv_plugin_get_port_by_index(plugin, index) orelse continue;
        const symbol_node = c.lilv_port_get_symbol(plugin, port) orelse continue;
        const symbol = std.mem.span(c.lilv_node_as_string(symbol_node));
        const value = findParamValue(raw_params, symbol) orelse 0.0;
        try ports.append(allocator, .{
            .index = index,
            .symbol = try allocator.dupe(u8, symbol),
            .value = value,
        });
    }

    return .{
        .allocator = allocator,
        .ports = try ports.toOwnedSlice(allocator),
    };
}

fn findParamValue(raw_params: []const []const u8, symbol: []const u8) ?f32 {
    for (raw_params) |entry| {
        const equals = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (!std.mem.eql(u8, entry[0..equals], symbol)) continue;
        return std.fmt.parseFloat(f32, entry[equals + 1 ..]) catch null;
    }
    return null;
}

fn connectPorts(instance: *c.LilvInstance, plugin: *const c.LilvPlugin, ports: []ControlPort) void {
    const port_count = c.lilv_plugin_get_num_ports(plugin);
    var scratch = [_]f32{0} ** 2;
    var index: u32 = 0;
    while (index < port_count) : (index += 1) {
        if (findControlPort(ports, index)) |port| {
            c.lilv_instance_connect_port(instance, index, @constCast(&port.value));
            continue;
        }
        const buffer_ptr: [*]f32 = &scratch;
        c.lilv_instance_connect_port(instance, index, buffer_ptr);
    }
}

fn findControlPort(ports: []ControlPort, index: u32) ?*ControlPort {
    for (ports) |*port| {
        if (port.index == index) return port;
    }
    return null;
}

fn extensionInterface(comptime T: type, instance: *c.SuilInstance, uri: []const u8) ?*const T {
    const uri_z = std.heap.page_allocator.dupeZ(u8, uri) catch return null;
    defer std.heap.page_allocator.free(uri_z);
    const raw = c.suil_instance_extension_data(instance, uri_z.ptr) orelse return null;
    return @ptrCast(@alignCast(raw));
}

fn portWriteCallback(
    controller_ptr: c.SuilController,
    port_index: u32,
    buffer_size: u32,
    protocol: u32,
    buffer: ?*const anyopaque,
) callconv(.c) void {
    if (controller_ptr == null or buffer == null) return;
    if (protocol != 0 or buffer_size < @sizeOf(f32)) return;
    const controller: *UiController = @ptrCast(@alignCast(controller_ptr));
    const value: *const f32 = @ptrCast(@alignCast(buffer));
    for (controller.ports) |*port| {
        if (port.index != port_index) continue;
        port.value = value.*;
        emitParamUpdate(port.symbol, value.*);
        break;
    }
}

fn emitParamUpdate(symbol: []const u8, value: f32) void {
    var line: [256]u8 = undefined;
    const written = std.fmt.bufPrint(&line, "param\t{s}\t{d}\n", .{ symbol, value }) catch return;
    std.fs.File.stdout().writeAll(written) catch return;
}

fn portIndexCallback(controller_ptr: c.SuilController, port_symbol: [*c]const u8) callconv(.c) u32 {
    if (controller_ptr == null or port_symbol == null) return std.math.maxInt(u32);
    const controller: *UiController = @ptrCast(@alignCast(controller_ptr));
    const symbol = std.mem.span(port_symbol);
    for (controller.ports) |port| {
        if (std.mem.eql(u8, port.symbol, symbol)) return port.index;
    }
    return std.math.maxInt(u32);
}

fn idleTickCallback(data: ?*anyopaque) callconv(.c) c_int {
    const state: *IdleState = @ptrCast(@alignCast(data orelse return 0));
    const idle = state.idle_interface.idle orelse return 1;
    _ = idle(c.suil_instance_get_handle(state.instance));
    pumpStdinUiEvents(state);
    return 1;
}

fn pumpStdinUiEvents(state: *IdleState) void {
    var fds = [_]std.posix.pollfd{
        .{
            .fd = std.posix.STDIN_FILENO,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };
    const ready = std.posix.poll(&fds, 0) catch return;
    if (ready == 0 or (fds[0].revents & std.posix.POLL.IN) == 0) return;

    var temp: [4096]u8 = undefined;
    const stdin_file = std.fs.File.stdin();
    const read_len = stdin_file.read(&temp) catch return;
    if (read_len == 0) return;
    state.stdin_buffer.appendSlice(state.allocator, temp[0..read_len]) catch return;

    while (std.mem.indexOfScalar(u8, state.stdin_buffer.items, '\n')) |newline| {
        const line = state.stdin_buffer.items[0..newline];
        handleIncomingUiLine(state, line);
        const remaining = state.stdin_buffer.items[newline + 1 ..];
        std.mem.copyForwards(u8, state.stdin_buffer.items, remaining);
        state.stdin_buffer.items.len = remaining.len;
    }
}

fn handleIncomingUiLine(state: *IdleState, line: []const u8) void {
    var it = std.mem.splitScalar(u8, line, '\t');
    const kind = it.next() orelse return;
    if (std.mem.eql(u8, kind, "atom")) {
        const port_text = it.next() orelse return;
        const hex_text = it.next() orelse return;
        const port_index = std.fmt.parseInt(u32, port_text, 10) catch return;
        if (hex_text.len == 0 or (hex_text.len % 2) != 0) return;

        const decoded = state.allocator.alloc(u8, hex_text.len / 2) catch return;
        defer state.allocator.free(decoded);
        _ = std.fmt.hexToBytes(decoded, hex_text) catch return;
        c.suil_instance_port_event(state.instance, port_index, @intCast(decoded.len), 0, decoded.ptr);
        return;
    }
    if (std.mem.eql(u8, kind, "param")) {
        const symbol = it.next() orelse return;
        const value_text = it.next() orelse return;
        const value = std.fmt.parseFloat(f32, value_text) catch return;
        const port_index = findControllerPortIndex(state.controller, symbol);
        if (port_index == std.math.maxInt(u32)) return;
        var temp = value;
        c.suil_instance_port_event(state.instance, port_index, @sizeOf(f32), 0, &temp);
    }
}

fn findControllerPortIndex(controller: *UiController, symbol: []const u8) u32 {
    for (controller.ports) |port| {
        if (std.mem.eql(u8, port.symbol, symbol)) return port.index;
    }
    return std.math.maxInt(u32);
}

fn uridMapCallback(handle: ?*anyopaque, uri_ptr: [*c]const u8) callconv(.c) c.LV2_URID {
    if (handle == null or uri_ptr == null) return 0;
    const store: *UridMapStore = @ptrCast(@alignCast(handle));
    return store.map(std.mem.span(uri_ptr));
}

fn uridUnmapCallback(handle: ?*anyopaque, urid: c.LV2_URID) callconv(.c) [*c]const u8 {
    if (handle == null) return null;
    const store: *UridMapStore = @ptrCast(@alignCast(handle));
    return store.unmap(urid);
}
