const std = @import("std");

pub const PluginBackend = enum(u8) {
    builtin,
    native,
    lv2,
};

pub const PluginControlSync = enum(u8) {
    none,
    plugin_enabled,
    plugin_bypass,
};

pub const PluginControlPort = struct {
    index: u32 = 0,
    symbol: []const u8,
    label: []const u8,
    is_output: bool = false,
    min_value: f32 = 0.0,
    max_value: f32 = 1.0,
    default_value: f32 = 0.0,
    toggled: bool = false,
    integer: bool = false,
    enumeration: bool = false,
    sync_kind: PluginControlSync = .none,
};

pub const PluginDescriptor = struct {
    id: []const u8,
    label: []const u8,
    backend: PluginBackend,
    category: []const u8,
    bundle_name: []const u8 = "",
    control_ports: []const PluginControlPort = &.{},
    has_custom_ui: bool = false,
    primary_ui_uri: []const u8 = "",
};

pub const PluginHost = struct {
    pub fn descriptors() []const PluginDescriptor {
        return &.{};
    }

    pub fn findDescriptor(id: []const u8) ?PluginDescriptor {
        for (descriptors()) |descriptor| {
            if (std.mem.eql(u8, descriptor.id, id)) return descriptor;
        }
        return null;
    }
};
