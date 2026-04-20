const std = @import("std");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logFn,
};

const default_level: std.log.Level = .warn;
const env_var_name = "WIREDECK_LOG";

var runtime_level = std.atomic.Value(u8).init(@intFromEnum(default_level));

pub fn initFromEnv() void {
    runtime_level.store(@intFromEnum(readEnvLevel()), .release);
}

fn readEnvLevel() std.log.Level {
    const value = std.process.getEnvVarOwned(std.heap.page_allocator, env_var_name) catch {
        return default_level;
    };
    defer std.heap.page_allocator.free(value);
    return parseLevel(value) orelse default_level;
}

fn parseLevel(value: []const u8) ?std.log.Level {
    if (std.ascii.eqlIgnoreCase(value, "debug")) return .debug;
    if (std.ascii.eqlIgnoreCase(value, "info")) return .info;
    if (std.ascii.eqlIgnoreCase(value, "warn")) return .warn;
    if (std.ascii.eqlIgnoreCase(value, "error")) return .err;
    if (std.ascii.eqlIgnoreCase(value, "err")) return .err;
    return null;
}

pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) > runtime_level.load(.acquire)) return;

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();

    var buffer: [1024]u8 = undefined;
    const stderr = std.fs.File.stderr();
    var stderr_writer = stderr.writer(&buffer);
    const writer = &stderr_writer.interface;
    writer.print("[{s}]", .{@tagName(message_level)}) catch return;
    if (scope != .default) {
        writer.print("({s})", .{@tagName(scope)}) catch return;
    }
    writer.print(": ", .{}) catch return;
    writer.print(format, args) catch return;
    writer.print("\n", .{}) catch return;
    writer.flush() catch return;
}

test "parseLevel recognizes supported runtime values" {
    try std.testing.expectEqual(std.log.Level.debug, parseLevel("debug").?);
    try std.testing.expectEqual(std.log.Level.info, parseLevel("INFO").?);
    try std.testing.expectEqual(std.log.Level.warn, parseLevel("warn").?);
    try std.testing.expectEqual(std.log.Level.err, parseLevel("error").?);
    try std.testing.expect(parseLevel("nope") == null);
}
