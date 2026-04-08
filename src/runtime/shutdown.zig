const std = @import("std");

const c = @cImport({
    @cInclude("signal.h");
});

var shutdown_requested = std.atomic.Value(bool).init(false);

pub fn installSignalHandlers() void {
    shutdown_requested.store(false, .release);
    _ = c.signal(c.SIGINT, handleSignal);
    _ = c.signal(c.SIGTERM, handleSignal);
}

pub fn isRequested() bool {
    return shutdown_requested.load(.acquire);
}

pub fn request() void {
    shutdown_requested.store(true, .release);
}

fn handleSignal(_: c_int) callconv(.c) void {
    shutdown_requested.store(true, .release);
}
