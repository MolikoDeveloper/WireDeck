const std = @import("std");

pub const c = @cImport({
    @cInclude("wiredeck_obs_output_protocol.h");
});

pub const wire_audio_header_size: usize = 36;

pub fn writeStringField(field: []u8, value: []const u8) void {
    @memset(field, 0);
    const len = @min(field.len - 1, value.len);
    @memcpy(field[0..len], value[0..len]);
}

pub fn readStringField(field: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, field, 0) orelse field.len;
    return field[0..end];
}

pub fn headerIsValid(header: c.wd_obs_packet_header) bool {
    return header.magic == c.WD_OBS_PROTOCOL_MAGIC and header.version == c.WD_OBS_PROTOCOL_VERSION;
}

pub fn writeAudioPacketHeader(
    out: []u8,
    stream_id: u32,
    codec: u8,
    channels: u8,
    frames: u16,
    sample_rate_hz: u32,
    sequence: u32,
    sender_time_ns: u64,
) void {
    std.debug.assert(out.len >= wire_audio_header_size);

    std.mem.writeInt(u32, out[0..4], c.WD_OBS_PROTOCOL_MAGIC, .little);
    out[4] = c.WD_OBS_PROTOCOL_VERSION;
    out[5] = c.WD_OBS_PACKET_AUDIO;
    std.mem.writeInt(u16, out[6..8], 0, .little);
    std.mem.writeInt(u32, out[8..12], 0, .little);
    std.mem.writeInt(u32, out[12..16], stream_id, .little);
    out[16] = codec;
    out[17] = channels;
    std.mem.writeInt(u16, out[18..20], frames, .little);
    std.mem.writeInt(u32, out[20..24], sample_rate_hz, .little);
    std.mem.writeInt(u32, out[24..28], sequence, .little);
    std.mem.writeInt(u64, out[28..36], sender_time_ns, .little);
}
