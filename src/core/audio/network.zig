const std = @import("std");

pub const ClientPlatform = enum(u8) {
    macos,
    linux,
    windows,
};

pub const CaptureMode = enum(u8) {
    tone,
    silence,
    stdin_f32le,
    system_default,
};

pub const TransportKind = enum(u8) {
    udp,
    quic,
};

pub const CodecKind = enum(u8) {
    pcm_float32,
    pcm_s16le,
    opus_lowdelay,
};

pub const ClockMode = enum(u8) {
    sender_timestamps,
    receiver_clock,
};

pub const VirtualDeviceKind = enum(u8) {
    coreaudio_virtual_device,
    pipewire_virtual_node,
    pulseaudio_virtual_sink,
    wasapi_virtual_device,
    asio_virtual_device,
};

pub const PacketKind = enum(u8) {
    hello = 1,
    audio = 2,
    keepalive = 3,
    goodbye = 4,
};

pub const string_field_len = 64;

pub const NetworkAudioSettings = struct {
    enabled: bool = true,
    bind_port: u16 = 45920,
    transport: TransportKind = .udp,
    codec: CodecKind = .pcm_float32,
    clock_mode: ClockMode = .sender_timestamps,
    sample_rate_hz: u32 = 48_000,
    channels: u8 = 2,
    frames_per_packet: u16 = 64,
    jitter_buffer_packets: u8 = 2,
    max_clients: u8 = 8,
    allow_fec: bool = false,
    require_encryption: bool = false,
};

pub const PacketHeader = packed struct {
    magic: u32 = 0x57444E41, // "WDNA"
    version: u8 = 1,
    kind: PacketKind = .audio,
    codec: CodecKind = .pcm_float32,
    channels: u8 = 2,
    sample_rate_hz: u32 = 48_000,
    frames: u16 = 64,
    sequence: u32 = 0,
    stream_id: u32 = 0,
    sender_time_ns: u64 = 0,
    reserved: u32 = 0,
};

pub const HelloPayload = extern struct {
    client_id: [string_field_len]u8 = zeroField(),
    client_name: [string_field_len]u8 = zeroField(),
    stream_name: [string_field_len]u8 = zeroField(),
    platform: ClientPlatform = .linux,
    capture_mode: CaptureMode = .tone,
    reserved: [2]u8 = .{ 0, 0 },
};

pub const ClientCapturePlan = struct {
    platform: ClientPlatform,
    virtual_device: VirtualDeviceKind,
    prefers_system_loopback: bool,
    notes: []const u8,
};

pub fn recommendedCapturePlan(platform: ClientPlatform) ClientCapturePlan {
    return switch (platform) {
        .macos => .{
            .platform = .macos,
            .virtual_device = .coreaudio_virtual_device,
            .prefers_system_loopback = false,
            .notes = "Create a CoreAudio virtual device and stream float32 stereo at 48 kHz with 64-frame packets.",
        },
        .linux => .{
            .platform = .linux,
            .virtual_device = .pipewire_virtual_node,
            .prefers_system_loopback = false,
            .notes = "Prefer a PipeWire virtual node; fall back to a Pulse virtual sink monitor only when PipeWire is unavailable.",
        },
        .windows => .{
            .platform = .windows,
            .virtual_device = .wasapi_virtual_device,
            .prefers_system_loopback = false,
            .notes = "Use a WASAPI virtual device when possible; keep ASIO virtual routing as an advanced fallback.",
        },
    };
}

pub fn transportLabel(kind: TransportKind) []const u8 {
    return switch (kind) {
        .udp => "udp",
        .quic => "quic",
    };
}

pub fn codecLabel(kind: CodecKind) []const u8 {
    return switch (kind) {
        .pcm_float32 => "pcm-f32le",
        .pcm_s16le => "pcm-s16le",
        .opus_lowdelay => "opus-lowdelay",
    };
}

pub fn captureModeLabel(mode: CaptureMode) []const u8 {
    return switch (mode) {
        .tone => "tone",
        .silence => "silence",
        .stdin_f32le => "stdin-f32le",
        .system_default => "system-default",
    };
}

pub fn writeStringField(field: *[string_field_len]u8, value: []const u8) void {
    field.* = zeroField();
    const len = @min(field.len - 1, value.len);
    @memcpy(field[0..len], value[0..len]);
}

pub fn readStringField(field: [string_field_len]u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, &field, 0) orelse field.len;
    return field[0..end];
}

fn zeroField() [string_field_len]u8 {
    return [_]u8{0} ** string_field_len;
}
