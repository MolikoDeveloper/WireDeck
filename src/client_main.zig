const builtin = @import("builtin");
const std = @import("std");
const network_mod = @import("core/audio/network.zig");

const CliOptions = struct {
    server_host: []const u8 = "127.0.0.1",
    server_port: u16 = 45920,
    client_id: []const u8 = "default",
    client_name: []const u8 = "WireDeck Client",
    stream_name: []const u8 = "Remote Audio",
    capture_mode: network_mod.CaptureMode = .tone,
    sample_rate_hz: u32 = 48_000,
    channels: u8 = 2,
    frames_per_packet: u16 = 64,
    duration_seconds: ?u32 = null,
    tone_hz: f32 = 440.0,
};

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa_state.deinit();
        if (leaked == .leak) std.log.err("memory leak detected", .{});
    }
    const allocator = gpa_state.allocator();
    const options = try parseArgs(allocator);

    if (options.capture_mode == .system_default) {
        const plan = network_mod.recommendedCapturePlan(nativePlatform());
        std.log.err("system capture not implemented yet for {s}; expected device kind: {s}", .{
            @tagName(plan.platform),
            @tagName(plan.virtual_device),
        });
        return error.UnsupportedCaptureMode;
    }

    const server = try std.net.Address.resolveIp(options.server_host, options.server_port);
    const sock = try std.posix.socket(server.any.family, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
    defer std.posix.close(sock);

    const stream_id: u32 = @truncate(@as(u64, @intCast(std.time.nanoTimestamp())));
    var hello_header = network_mod.PacketHeader{
        .kind = .hello,
        .codec = .pcm_float32,
        .channels = options.channels,
        .sample_rate_hz = options.sample_rate_hz,
        .frames = options.frames_per_packet,
        .stream_id = stream_id,
        .sender_time_ns = @intCast(std.time.nanoTimestamp()),
    };
    var hello_payload = network_mod.HelloPayload{
        .platform = nativePlatform(),
        .capture_mode = options.capture_mode,
    };
    network_mod.writeStringField(&hello_payload.client_id, options.client_id);
    network_mod.writeStringField(&hello_payload.client_name, options.client_name);
    network_mod.writeStringField(&hello_payload.stream_name, options.stream_name);
    try sendPacket(sock, server, std.mem.asBytes(&hello_header), std.mem.asBytes(&hello_payload));

    var packet_index: u32 = 0;
    var last_hello_ns: i128 = std.time.nanoTimestamp();
    var last_keepalive_ns: i128 = std.time.nanoTimestamp();
    const max_frames = options.frames_per_packet;
    const sample_capacity = @as(usize, max_frames) * @as(usize, options.channels);
    var sample_storage = try allocator.alloc(f32, sample_capacity);
    defer allocator.free(sample_storage);
    const packet_capacity = @sizeOf(network_mod.PacketHeader) + sample_capacity * @sizeOf(f32);
    var packet_buffer = try allocator.alloc(u8, packet_capacity);
    defer allocator.free(packet_buffer);

    const start_ns = std.time.nanoTimestamp();
    var stdin = std.fs.File.stdin();
    var phase: f32 = 0.0;

    while (true) {
        if (options.duration_seconds) |duration_seconds| {
            if (std.time.nanoTimestamp() - start_ns >= @as(i128, duration_seconds) * std.time.ns_per_s) break;
        }

        const frame_count = switch (options.capture_mode) {
            .tone => generateTone(sample_storage, options.channels, options.frames_per_packet, options.tone_hz, options.sample_rate_hz, &phase),
            .silence => generateSilence(sample_storage, options.channels, options.frames_per_packet),
            .stdin_f32le => try readStdinFloat32(&stdin, sample_storage, options.channels, options.frames_per_packet),
            .system_default => unreachable,
        };
        if (frame_count == 0) break;

        var header = network_mod.PacketHeader{
            .kind = .audio,
            .codec = .pcm_float32,
            .channels = options.channels,
            .sample_rate_hz = options.sample_rate_hz,
            .frames = @intCast(frame_count),
            .sequence = packet_index,
            .stream_id = stream_id,
            .sender_time_ns = @intCast(std.time.nanoTimestamp()),
        };

        const payload_bytes = frameCountBytes(frame_count, options.channels, @sizeOf(f32));
        @memcpy(packet_buffer[0..@sizeOf(network_mod.PacketHeader)], std.mem.asBytes(&header));
        const payload_dst = packet_buffer[@sizeOf(network_mod.PacketHeader) .. @sizeOf(network_mod.PacketHeader) + payload_bytes];
        @memcpy(payload_dst, std.mem.sliceAsBytes(sample_storage[0 .. frame_count * options.channels]));
        _ = try std.posix.sendto(sock, packet_buffer[0 .. @sizeOf(network_mod.PacketHeader) + payload_bytes], 0, &server.any, server.getOsSockLen());

        packet_index +%= 1;
        if (std.time.nanoTimestamp() - last_hello_ns >= 2 * std.time.ns_per_s) {
            hello_header.sender_time_ns = @intCast(std.time.nanoTimestamp());
            try sendPacket(sock, server, std.mem.asBytes(&hello_header), std.mem.asBytes(&hello_payload));
            last_hello_ns = std.time.nanoTimestamp();
        }
        if (std.time.nanoTimestamp() - last_keepalive_ns >= std.time.ns_per_s) {
            var keepalive = header;
            keepalive.kind = .keepalive;
            keepalive.frames = 0;
            try sendPacket(sock, server, std.mem.asBytes(&keepalive), "");
            last_keepalive_ns = std.time.nanoTimestamp();
        }

        const sleep_ns = @as(u64, frame_count) * std.time.ns_per_s / options.sample_rate_hz;
        std.Thread.sleep(sleep_ns);
    }

    var goodbye = hello_header;
    goodbye.kind = .goodbye;
    goodbye.frames = 0;
    goodbye.sequence = packet_index;
    goodbye.sender_time_ns = @intCast(std.time.nanoTimestamp());
    try sendPacket(sock, server, std.mem.asBytes(&goodbye), "");
}

fn parseArgs(allocator: std.mem.Allocator) !CliOptions {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var options = CliOptions{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--server")) {
            index += 1;
            if (index >= args.len) return error.MissingServerHost;
            options.server_host = try allocator.dupe(u8, args[index]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--port")) {
            index += 1;
            if (index >= args.len) return error.MissingPort;
            options.server_port = try std.fmt.parseInt(u16, args[index], 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--client-id")) {
            index += 1;
            if (index >= args.len) return error.MissingClientId;
            options.client_id = try allocator.dupe(u8, args[index]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--client-name")) {
            index += 1;
            if (index >= args.len) return error.MissingClientName;
            options.client_name = try allocator.dupe(u8, args[index]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--stream-name")) {
            index += 1;
            if (index >= args.len) return error.MissingStreamName;
            options.stream_name = try allocator.dupe(u8, args[index]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--capture")) {
            index += 1;
            if (index >= args.len) return error.MissingCaptureMode;
            options.capture_mode = parseCaptureMode(args[index]) orelse return error.UnknownCaptureMode;
            continue;
        }
        if (std.mem.eql(u8, arg, "--sample-rate")) {
            index += 1;
            if (index >= args.len) return error.MissingSampleRate;
            options.sample_rate_hz = try std.fmt.parseInt(u32, args[index], 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--channels")) {
            index += 1;
            if (index >= args.len) return error.MissingChannels;
            options.channels = try std.fmt.parseInt(u8, args[index], 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--frames")) {
            index += 1;
            if (index >= args.len) return error.MissingFrames;
            options.frames_per_packet = try std.fmt.parseInt(u16, args[index], 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--duration")) {
            index += 1;
            if (index >= args.len) return error.MissingDuration;
            options.duration_seconds = try std.fmt.parseInt(u32, args[index], 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--tone-hz")) {
            index += 1;
            if (index >= args.len) return error.MissingToneHz;
            options.tone_hz = try std.fmt.parseFloat(f32, args[index]);
            continue;
        }
        return error.UnknownArgument;
    }
    return options;
}

fn parseCaptureMode(value: []const u8) ?network_mod.CaptureMode {
    if (std.mem.eql(u8, value, "tone")) return .tone;
    if (std.mem.eql(u8, value, "silence")) return .silence;
    if (std.mem.eql(u8, value, "stdin-f32le")) return .stdin_f32le;
    if (std.mem.eql(u8, value, "system")) return .system_default;
    return null;
}

fn nativePlatform() network_mod.ClientPlatform {
    return switch (builtin.os.tag) {
        .macos => .macos,
        .windows => .windows,
        else => .linux,
    };
}

fn sendPacket(sock: std.posix.socket_t, server: std.net.Address, header_bytes: []const u8, payload_bytes: []const u8) !void {
    var buffer: [@sizeOf(network_mod.PacketHeader) + @sizeOf(network_mod.HelloPayload)]u8 = undefined;
    const total = header_bytes.len + payload_bytes.len;
    if (total > buffer.len) {
        _ = try std.posix.sendto(sock, header_bytes, 0, &server.any, server.getOsSockLen());
        if (payload_bytes.len > 0) _ = try std.posix.sendto(sock, payload_bytes, 0, &server.any, server.getOsSockLen());
        return;
    }
    @memcpy(buffer[0..header_bytes.len], header_bytes);
    @memcpy(buffer[header_bytes.len..total], payload_bytes);
    _ = try std.posix.sendto(sock, buffer[0..total], 0, &server.any, server.getOsSockLen());
}

fn frameCountBytes(frames: usize, channels: u8, sample_size: usize) usize {
    return frames * @as(usize, channels) * sample_size;
}

fn generateTone(storage: []f32, channels: u8, frames_per_packet: u16, tone_hz: f32, sample_rate_hz: u32, phase: *f32) usize {
    const frames: usize = frames_per_packet;
    const chan_count: usize = channels;
    const phase_step = 2.0 * std.math.pi * tone_hz / @as(f32, @floatFromInt(sample_rate_hz));
    var frame: usize = 0;
    while (frame < frames) : (frame += 1) {
        const sample = @sin(phase.*) * 0.20;
        phase.* += phase_step;
        var channel_index: usize = 0;
        while (channel_index < chan_count) : (channel_index += 1) {
            storage[frame * chan_count + channel_index] = sample;
        }
    }
    return frames;
}

fn generateSilence(storage: []f32, channels: u8, frames_per_packet: u16) usize {
    const sample_count = @as(usize, channels) * @as(usize, frames_per_packet);
    @memset(storage[0..sample_count], 0.0);
    return frames_per_packet;
}

fn readStdinFloat32(stdin: *std.fs.File, storage: []f32, channels: u8, frames_per_packet: u16) !usize {
    const bytes = std.mem.sliceAsBytes(storage[0 .. @as(usize, channels) * @as(usize, frames_per_packet)]);
    const read_len = try stdin.read(bytes);
    if (read_len == 0) return 0;
    if (read_len < bytes.len) @memset(bytes[read_len..], 0);
    return read_len / (@as(usize, channels) * @sizeOf(f32));
}
