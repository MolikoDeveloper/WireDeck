const std = @import("std");
const c = @import("c.zig").c;

pub const ObjectKind = enum {
    client,
    node,
    port,
    link,
    metadata,
    device,
    other,
};

pub const PwProps = struct {
    app_name: ?[]const u8 = null,
    app_process_id: ?u32 = null,
    app_process_binary: ?[]const u8 = null,
    app_icon_name: ?[]const u8 = null,
    sec_pid: ?u32 = null,

    media_name: ?[]const u8 = null,
    media_class: ?[]const u8 = null,

    node_name: ?[]const u8 = null,
    node_description: ?[]const u8 = null,
    device_api: ?[]const u8 = null,
    bluez5_profile: ?[]const u8 = null,
    bluez5_codec: ?[]const u8 = null,

    object_serial: ?u64 = null,
    client_id: ?u32 = null,
};

pub const GlobalObject = struct {
    id: u32,
    permissions: u32,
    version: u32,
    type_name: []const u8,
    kind: ObjectKind,
    props: PwProps,
};

pub const ResolvedSource = struct {
    global_id: u32,
    display_name: []const u8,
    process_id: ?u32,
    binary: ?[]const u8,
    media_class: ?[]const u8,
    confidence: Confidence,

    pub const Confidence = enum {
        low,
        medium,
        high,
    };
};

pub fn classifyType(type_name: []const u8) ObjectKind {
    if (std.mem.eql(u8, type_name, std.mem.sliceTo(c.PW_TYPE_INTERFACE_Node, 0))) return .node;
    if (std.mem.eql(u8, type_name, std.mem.sliceTo(c.PW_TYPE_INTERFACE_Client, 0))) return .client;
    if (std.mem.eql(u8, type_name, std.mem.sliceTo(c.PW_TYPE_INTERFACE_Port, 0))) return .port;
    if (std.mem.eql(u8, type_name, std.mem.sliceTo(c.PW_TYPE_INTERFACE_Link, 0))) return .link;
    if (std.mem.eql(u8, type_name, std.mem.sliceTo(c.PW_TYPE_INTERFACE_Metadata, 0))) return .metadata;
    if (std.mem.eql(u8, type_name, std.mem.sliceTo(c.PW_TYPE_INTERFACE_Device, 0))) return .device;
    return .other;
}
