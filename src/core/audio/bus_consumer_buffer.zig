const std = @import("std");
const AudioEngine = @import("engine.zig").AudioEngine;

pub const render_sample_rate_hz: u32 = 48_000;
pub const render_quantum_frames: usize = 128;
pub const render_quantum_ns: u64 = @intCast((@as(u128, render_quantum_frames) * std.time.ns_per_s) / render_sample_rate_hz);
pub const stereo_channels: usize = 2;

pub const BusConsumerBuffer = struct {
    allocator: std.mem.Allocator,
    samples: std.ArrayList(i16),
    read_index: usize = 0,
    sample_rate_hz: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) BusConsumerBuffer {
        return .{
            .allocator = allocator,
            .samples = .empty,
        };
    }

    pub fn deinit(self: *BusConsumerBuffer) void {
        self.samples.deinit(self.allocator);
    }

    pub fn clear(self: *BusConsumerBuffer) void {
        self.samples.clearRetainingCapacity();
        self.read_index = 0;
        self.sample_rate_hz = 0;
    }

    pub fn availableSamples(self: *const BusConsumerBuffer) usize {
        if (self.read_index >= self.samples.items.len) return 0;
        return self.samples.items.len - self.read_index;
    }

    pub fn availableFrames(self: *const BusConsumerBuffer) usize {
        return self.availableSamples() / stereo_channels;
    }

    pub fn effectiveSampleRate(self: *const BusConsumerBuffer, fallback: u32) u32 {
        return if (self.sample_rate_hz != 0) self.sample_rate_hz else fallback;
    }

    pub fn fillFromEngine(
        self: *BusConsumerBuffer,
        engine: *AudioEngine,
        bus_id: []const u8,
        consumer_id: []const u8,
        target_frames: usize,
        scratch: []i16,
    ) !usize {
        if (target_frames == 0 or scratch.len < stereo_channels) return self.availableFrames();

        while (self.availableFrames() < target_frames) {
            const missing_frames = target_frames - self.availableFrames();
            const request_frames = @min(missing_frames, scratch.len / stereo_channels);
            if (request_frames == 0) break;

            const read = engine.readBusPcmS16ForConsumer(
                bus_id,
                consumer_id,
                scratch[0 .. request_frames * stereo_channels],
            );
            if (read.sample_rate_hz != 0) self.sample_rate_hz = read.sample_rate_hz;
            if (read.frames == 0) break;

            try self.appendSamples(scratch[0 .. read.frames * stereo_channels]);
            if (read.frames < request_frames) break;
        }

        return self.availableFrames();
    }

    pub fn drainFrames(self: *BusConsumerBuffer, out: []i16, frame_count: usize) usize {
        if (frame_count == 0 or out.len < stereo_channels) return 0;
        const sample_count = @min(out.len, frame_count * stereo_channels);
        const available_samples = @min(sample_count, self.availableSamples());
        if (available_samples < stereo_channels) return 0;

        @memcpy(out[0..available_samples], self.samples.items[self.read_index .. self.read_index + available_samples]);
        self.read_index += available_samples;
        self.compact();
        return available_samples / stereo_channels;
    }

    fn appendSamples(self: *BusConsumerBuffer, samples: []const i16) !void {
        if (samples.len == 0) return;
        self.compact();
        try self.samples.appendSlice(self.allocator, samples);
    }

    fn compact(self: *BusConsumerBuffer) void {
        if (self.read_index == 0) return;
        if (self.read_index >= self.samples.items.len) {
            self.samples.clearRetainingCapacity();
            self.read_index = 0;
            return;
        }

        const remaining = self.samples.items.len - self.read_index;
        std.mem.copyForwards(i16, self.samples.items[0..remaining], self.samples.items[self.read_index..][0..remaining]);
        self.samples.items.len = remaining;
        self.read_index = 0;
    }
};
