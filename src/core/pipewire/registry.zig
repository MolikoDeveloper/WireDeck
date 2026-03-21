const std = @import("std");
const c = @import("c.zig").c;
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const GlobalObject = types.GlobalObject;
const PwProps = types.PwProps;
const ResolvedSource = types.ResolvedSource;
const classifyType = types.classifyType;

pub const RegistrySnapshot = struct {
    sources: usize = 0,
    sinks: usize = 0,
    streams: usize = 0,

    pub fn eql(self: RegistrySnapshot, other: RegistrySnapshot) bool {
        return self.sources == other.sources and
            self.sinks == other.sinks and
            self.streams == other.streams;
    }
};

pub const RegistryState = struct {
    allocator: Allocator,
    objects: std.ArrayList(GlobalObject),
    clients: std.ArrayList(GlobalObject),

    pub fn init(allocator: Allocator) RegistryState {
        return .{
            .allocator = allocator,
            .objects = .empty,
            .clients = .empty,
        };
    }

    pub fn deinit(self: *RegistryState) void {
        deinitList(self.allocator, &self.objects);
        deinitList(self.allocator, &self.clients);
    }

    pub fn addGlobal(
        self: *RegistryState,
        id: u32,
        permissions: u32,
        type_name: []const u8,
        version: u32,
        props: ?*const c.struct_spa_dict,
    ) !void {
        const type_copy = try self.allocator.dupe(u8, type_name);
        errdefer self.allocator.free(type_copy);

        const parsed_props = try parseProps(self.allocator, props);
        errdefer deinitProps(self.allocator, &parsed_props);

        const kind = classifyType(type_name);

        const obj = GlobalObject{
            .id = id,
            .permissions = permissions,
            .version = version,
            .type_name = type_copy,
            .kind = kind,
            .props = parsed_props,
        };

        switch (kind) {
            .client => try self.clients.append(self.allocator, obj),
            else => try self.objects.append(self.allocator, obj),
        }
    }

    pub fn removeGlobal(self: *RegistryState, id: u32) void {
        if (removeFromList(self.allocator, &self.objects, id)) return;
        _ = removeFromList(self.allocator, &self.clients, id);
    }

    pub fn resolveSources(self: *RegistryState, allocator: Allocator) ![]ResolvedSource {
        var out: std.ArrayList(ResolvedSource) = .empty;
        defer out.deinit(allocator);

        for (self.objects.items) |obj| {
            if (obj.kind != .node) continue;

            const media_class = obj.props.media_class orelse continue;
            if (!std.mem.startsWith(u8, media_class, "Stream/")) continue;
            if (std.mem.indexOf(u8, media_class, "/Audio") == null) continue;

            var pid = resolvePid(obj.props);
            var binary = obj.props.app_process_binary;
            var confidence = resolveConfidence(obj.props);

            if (pid == null or binary == null) {
                if (obj.props.client_id) |cid| {
                    if (findClient(self, cid)) |client| {
                        if (pid == null) pid = resolvePid(client.props);
                        if (binary == null) binary = client.props.app_process_binary;

                        const client_conf = resolveConfidence(client.props);
                        if (@intFromEnum(client_conf) > @intFromEnum(confidence)) {
                            confidence = client_conf;
                        }
                    }
                }
            }

            const display_name = try allocator.dupe(u8, resolveDisplayName(obj.props));
            errdefer allocator.free(display_name);

            const media_class_copy = if (obj.props.media_class) |mc|
                try allocator.dupe(u8, mc)
            else
                null;
            errdefer if (media_class_copy) |mc| allocator.free(mc);

            const binary_copy = if (binary) |b|
                try allocator.dupe(u8, b)
            else
                null;
            errdefer if (binary_copy) |b| allocator.free(b);

            try out.append(allocator, .{
                .global_id = obj.id,
                .display_name = display_name,
                .process_id = pid,
                .binary = binary_copy,
                .media_class = media_class_copy,
                .confidence = confidence,
            });
        }

        return try out.toOwnedSlice(allocator);
    }

    pub fn freeResolvedSources(allocator: Allocator, items: []ResolvedSource) void {
        for (items) |item| {
            allocator.free(item.display_name);
            if (item.binary) |b| allocator.free(b);
            if (item.media_class) |mc| allocator.free(mc);
        }
        allocator.free(items);
    }

    pub fn debugDump(self: *RegistryState) void {
        std.debug.print("=== OBJECTS ===\n", .{});
        for (self.objects.items) |obj| {
            dumpObject(obj);
        }

        std.debug.print("=== CLIENTS ===\n", .{});
        for (self.clients.items) |obj| {
            dumpObject(obj);
        }
    }
};

fn dumpObject(obj: GlobalObject) void {
    std.debug.print(
        \\obj id={} type={s} kind={s}
        \\  client_id={any}
        \\  app_name={any}
        \\  app_process_id={any}
        \\  app_process_binary={any}
        \\  sec_pid={any}
        \\  media_name={any}
        \\  media_class={any}
        \\  node_name={any}
        \\  node_description={any}
        \\
    , .{
        obj.id,
        obj.type_name,
        @tagName(obj.kind),
        obj.props.client_id,
        obj.props.app_name,
        obj.props.app_process_id,
        obj.props.app_process_binary,
        obj.props.sec_pid,
        obj.props.media_name,
        obj.props.media_class,
        obj.props.node_name,
        obj.props.node_description,
    });
}

fn deinitList(allocator: Allocator, list: *std.ArrayList(GlobalObject)) void {
    for (list.items) |obj| {
        deinitObject(allocator, obj);
    }
    list.deinit(allocator);
}

fn removeFromList(
    allocator: Allocator,
    list: *std.ArrayList(GlobalObject),
    id: u32,
) bool {
    var i: usize = 0;
    while (i < list.items.len) : (i += 1) {
        if (list.items[i].id == id) {
            const obj = list.swapRemove(i);
            deinitObject(allocator, obj);
            return true;
        }
    }
    return false;
}

fn deinitObject(allocator: Allocator, obj: GlobalObject) void {
    allocator.free(obj.type_name);
    deinitProps(allocator, &obj.props);
}

fn findClient(self: *RegistryState, id: u32) ?GlobalObject {
    for (self.clients.items) |client| {
        if (client.id == id) return client;
    }
    return null;
}

fn freeOpt(allocator: Allocator, s: ?[]const u8) void {
    if (s) |v| allocator.free(v);
}

fn deinitProps(allocator: Allocator, props: *const PwProps) void {
    freeOpt(allocator, props.app_name);
    freeOpt(allocator, props.app_process_binary);
    freeOpt(allocator, props.app_icon_name);
    freeOpt(allocator, props.media_name);
    freeOpt(allocator, props.media_class);
    freeOpt(allocator, props.node_name);
    freeOpt(allocator, props.node_description);
    freeOpt(allocator, props.device_api);
    freeOpt(allocator, props.bluez5_profile);
    freeOpt(allocator, props.bluez5_codec);
}

fn parseProps(allocator: Allocator, dict: ?*const c.struct_spa_dict) !PwProps {
    var props = PwProps{};

    props.app_name = try dupDictValue(allocator, dict, c.PW_KEY_APP_NAME);
    props.app_process_binary = try dupDictValue(allocator, dict, c.PW_KEY_APP_PROCESS_BINARY);
    props.app_icon_name = try dupDictValue(allocator, dict, c.PW_KEY_APP_ICON_NAME);
    props.media_name = try dupDictValue(allocator, dict, c.PW_KEY_MEDIA_NAME);
    props.media_class = try dupDictValue(allocator, dict, c.PW_KEY_MEDIA_CLASS);
    props.node_name = try dupDictValue(allocator, dict, c.PW_KEY_NODE_NAME);
    props.node_description = try dupDictValue(allocator, dict, c.PW_KEY_NODE_DESCRIPTION);
    props.device_api = try dupDictValue(allocator, dict, "device.api");
    props.bluez5_profile = try dupDictValue(allocator, dict, "api.bluez5.profile");
    props.bluez5_codec = try dupDictValue(allocator, dict, "api.bluez5.codec");

    props.client_id = parseU32Maybe(dictGet(dict, c.PW_KEY_CLIENT_ID));
    props.app_process_id = parseU32Maybe(dictGet(dict, c.PW_KEY_APP_PROCESS_ID));
    props.sec_pid = parseU32Maybe(dictGet(dict, c.PW_KEY_SEC_PID));

    return props;
}

fn dictGet(dict: ?*const c.struct_spa_dict, key: [*c]const u8) ?[]const u8 {
    const d = dict orelse return null;
    const value = c.spa_dict_lookup(d, key);
    if (value == null) return null;
    return std.mem.span(value);
}

fn dupDictValue(
    allocator: Allocator,
    dict: ?*const c.struct_spa_dict,
    key: [*c]const u8,
) !?[]const u8 {
    const value = dictGet(dict, key) orelse return null;
    return try allocator.dupe(u8, value);
}

fn parseU32Maybe(value: ?[]const u8) ?u32 {
    const s = value orelse return null;
    return std.fmt.parseUnsigned(u32, s, 10) catch null;
}

fn resolvePid(props: PwProps) ?u32 {
    if (props.app_process_id) |pid| return pid;
    return null;
}

fn resolveBridgePid(props: PwProps) ?u32 {
    if (props.sec_pid) |pid| return pid;
    return null;
}

fn resolveDisplayName(props: PwProps) []const u8 {
    if (props.app_name) |v| return v;
    if (props.node_description) |v| return v;
    if (props.media_name) |v| return v;
    if (props.node_name) |v| return v;
    return "Unknown";
}

fn resolveConfidence(props: PwProps) ResolvedSource.Confidence {
    if (props.app_process_id != null and props.app_process_binary != null) return .high;
    if (props.app_process_id != null or props.app_process_binary != null) return .medium;
    return .low;
}
