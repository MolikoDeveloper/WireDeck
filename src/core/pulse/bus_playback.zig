const std = @import("std");
const c = @import("c.zig").c;
const audio_engine_mod = @import("../audio/engine.zig");
const bus_buffer_mod = @import("../audio/bus_consumer_buffer.zig");

const playback_quantum_frames: usize = 128;
const playback_quantum_samples: usize = playback_quantum_frames * 2;
const playback_quantum_bytes: usize = playback_quantum_samples * @sizeOf(i16);
const enable_bus_playback_summary_logs = false;
const underrun_warn_log_interval_ns: i128 = 1000 * std.time.ns_per_ms;

pub const BusPlayback = struct {
    const target_buffer_frames = bus_buffer_mod.render_quantum_frames * 4;

    allocator: std.mem.Allocator,
    engine: *audio_engine_mod.AudioEngine,
    bus_id: []u8,
    consumer_id: []u8,
    target_sink_name: []u8,
    description: []u8,
    mainloop: ?*c.pa_threaded_mainloop = null,
    api: ?*c.pa_mainloop_api = null,
    context: ?*c.pa_context = null,
    stream: ?*c.pa_stream = null,
    feeder_thread: ?std.Thread = null,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    buffer_mutex: std.Thread.Mutex = .{},
    write_count: u64 = 0,
    nonzero_write_count: u64 = 0,
    peak_abs_sample: u16 = 0,
    underrun_count: u64 = 0,
    last_underrun_log_ns: i128 = 0,
    pcm_buffer: bus_buffer_mod.BusConsumerBuffer,

    pub fn init(
        allocator: std.mem.Allocator,
        engine: *audio_engine_mod.AudioEngine,
        bus_id: []const u8,
        consumer_id: []const u8,
        target_sink_name: []const u8,
        description: []const u8,
    ) !*BusPlayback {
        const self = try allocator.create(BusPlayback);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .engine = engine,
            .bus_id = try allocator.dupe(u8, bus_id),
            .consumer_id = try allocator.dupe(u8, consumer_id),
            .target_sink_name = try allocator.dupe(u8, target_sink_name),
            .description = try allocator.dupe(u8, description),
            .pcm_buffer = bus_buffer_mod.BusConsumerBuffer.init(allocator),
        };
        errdefer self.freeOwnedState();

        try self.connect();
        self.stop_requested.store(false, .release);
        self.feeder_thread = try std.Thread.spawn(.{}, feederMain, .{self});
        return self;
    }

    pub fn deinit(self: *BusPlayback) void {
        self.shutdown();
        if (enable_bus_playback_summary_logs) {
            std.log.info("pulse bus playback summary for {s}: writes={d} nonzero_writes={d}", .{
                self.consumer_id,
                self.write_count,
                self.nonzero_write_count,
            });
            std.log.info("pulse bus playback peak for {s}: peak_abs_sample={d}", .{
                self.consumer_id,
                self.peak_abs_sample,
            });
        }
        self.engine.releaseBusTapConsumer(self.bus_id, self.consumer_id);
        self.freeOwnedState();
        self.allocator.destroy(self);
    }

    fn connect(self: *BusPlayback) !void {
        self.mainloop = c.pa_threaded_mainloop_new() orelse return error.PulseMainloopCreateFailed;
        errdefer {
            c.pa_threaded_mainloop_free(self.mainloop);
            self.mainloop = null;
        }

        self.api = c.pa_threaded_mainloop_get_api(self.mainloop.?);
        self.context = c.pa_context_new(self.api, "wiredeck-busplay") orelse return error.PulseContextCreateFailed;
        errdefer {
            c.pa_context_unref(self.context);
            self.context = null;
        }

        c.pa_context_set_state_callback(self.context, contextStateCb, self);

        c.pa_threaded_mainloop_lock(self.mainloop.?);
        defer c.pa_threaded_mainloop_unlock(self.mainloop.?);

        if (c.pa_context_connect(self.context, null, c.PA_CONTEXT_NOFLAGS, null) < 0) {
            return error.PulseConnectFailed;
        }
        if (c.pa_threaded_mainloop_start(self.mainloop.?) < 0) {
            return error.PulseMainloopStartFailed;
        }

        try self.waitForContextReadyLocked();
        try self.createStreamLocked();
        try self.waitForStreamReadyLocked();
    }

    fn shutdown(self: *BusPlayback) void {
        self.stop_requested.store(true, .release);
        if (self.feeder_thread) |thread| {
            thread.join();
            self.feeder_thread = null;
        }
        if (self.mainloop) |mainloop| {
            c.pa_threaded_mainloop_lock(mainloop);
            if (self.stream) |stream| {
                c.pa_stream_set_write_callback(stream, null, null);
                c.pa_stream_set_state_callback(stream, null, null);
                _ = c.pa_stream_disconnect(stream);
                c.pa_stream_unref(stream);
                self.stream = null;
            }
            if (self.context) |context| {
                c.pa_context_set_state_callback(context, null, null);
                c.pa_context_disconnect(context);
                c.pa_context_unref(context);
                self.context = null;
            }
            c.pa_threaded_mainloop_unlock(mainloop);
            c.pa_threaded_mainloop_stop(mainloop);
            c.pa_threaded_mainloop_free(mainloop);
            self.mainloop = null;
            self.api = null;
        }
    }

    fn createStreamLocked(self: *BusPlayback) !void {
        const label_z = try self.allocator.dupeZ(u8, self.description);
        defer self.allocator.free(label_z);
        const sink_name_z = try self.allocator.dupeZ(u8, self.target_sink_name);
        defer self.allocator.free(sink_name_z);

        var sample_spec = c.pa_sample_spec{
            .format = c.PA_SAMPLE_S16LE,
            .rate = 48_000,
            .channels = 2,
        };
        var channel_map: c.pa_channel_map = undefined;
        _ = c.pa_channel_map_init_stereo(&channel_map);

        const stream = c.pa_stream_new(self.context, label_z.ptr, &sample_spec, &channel_map) orelse {
            return error.PulsePlaybackStreamCreateFailed;
        };
        errdefer c.pa_stream_unref(stream);

        c.pa_stream_set_state_callback(stream, streamStateCb, self);
        c.pa_stream_set_write_callback(stream, streamWriteCb, self);

        var attr = c.pa_buffer_attr{
            .maxlength = playback_quantum_bytes * 8,
            .tlength = playback_quantum_bytes * 4,
            // Start playback as soon as the first bus quantum is available instead of
            // waiting for multiple callbacks to fill a larger prebuffer.
            .prebuf = 0,
            .minreq = playback_quantum_bytes,
            .fragsize = 0,
        };
        const flags: c.pa_stream_flags_t =
            @as(c.pa_stream_flags_t, @intCast(c.PA_STREAM_DONT_MOVE)) |
            @as(c.pa_stream_flags_t, @intCast(c.PA_STREAM_AUTO_TIMING_UPDATE)) |
            @as(c.pa_stream_flags_t, @intCast(c.PA_STREAM_INTERPOLATE_TIMING)) |
            @as(c.pa_stream_flags_t, @intCast(c.PA_STREAM_ADJUST_LATENCY));

        if (c.pa_stream_connect_playback(stream, sink_name_z.ptr, &attr, flags, null, null) < 0) {
            return error.PulsePlaybackConnectFailed;
        }

        self.stream = stream;
    }

    fn waitForContextReadyLocked(self: *BusPlayback) !void {
        while (true) {
            const state = c.pa_context_get_state(self.context);
            switch (state) {
                c.PA_CONTEXT_READY => return,
                c.PA_CONTEXT_FAILED, c.PA_CONTEXT_TERMINATED => return error.PulseContextNotReady,
                else => c.pa_threaded_mainloop_wait(self.mainloop.?),
            }
        }
    }

    fn waitForStreamReadyLocked(self: *BusPlayback) !void {
        while (true) {
            const state = c.pa_stream_get_state(self.stream);
            switch (state) {
                c.PA_STREAM_READY => return,
                c.PA_STREAM_FAILED, c.PA_STREAM_TERMINATED => return error.PulsePlaybackStreamNotReady,
                else => c.pa_threaded_mainloop_wait(self.mainloop.?),
            }
        }
    }

    fn freeOwnedState(self: *BusPlayback) void {
        self.pcm_buffer.deinit();
        self.allocator.free(self.description);
        self.allocator.free(self.target_sink_name);
        self.allocator.free(self.consumer_id);
        self.allocator.free(self.bus_id);
    }

    fn feederMain(self: *BusPlayback) void {
        var scratch_buffer: [bus_buffer_mod.render_quantum_frames * bus_buffer_mod.stereo_channels]i16 = undefined;
        var next_tick_ns = std.time.nanoTimestamp();
        while (!self.stop_requested.load(.acquire)) {
            self.buffer_mutex.lock();
            _ = self.pcm_buffer.fillFromEngine(
                self.engine,
                self.bus_id,
                self.consumer_id,
                target_buffer_frames,
                scratch_buffer[0..],
            ) catch {};
            const buffered_frames = self.pcm_buffer.availableFrames();
            self.buffer_mutex.unlock();

            const step_ns: u64 = if (buffered_frames < target_buffer_frames / 2)
                @max(@as(u64, 1), bus_buffer_mod.render_quantum_ns / 2)
            else
                bus_buffer_mod.render_quantum_ns;
            next_tick_ns +%= step_ns;
            const now_ns = std.time.nanoTimestamp();
            if (next_tick_ns > now_ns) {
                std.Thread.sleep(@intCast(next_tick_ns - now_ns));
            } else {
                next_tick_ns = now_ns;
            }
        }
    }
};

fn contextStateCb(_: ?*c.pa_context, userdata: ?*anyopaque) callconv(.c) void {
    const self: *BusPlayback = @ptrCast(@alignCast(userdata orelse return));
    c.pa_threaded_mainloop_signal(self.mainloop, 0);
}

fn streamStateCb(_: ?*c.pa_stream, userdata: ?*anyopaque) callconv(.c) void {
    const self: *BusPlayback = @ptrCast(@alignCast(userdata orelse return));
    c.pa_threaded_mainloop_signal(self.mainloop, 0);
}

fn streamWriteCb(stream: ?*c.pa_stream, nbytes: usize, userdata: ?*anyopaque) callconv(.c) void {
    const self: *BusPlayback = @ptrCast(@alignCast(userdata orelse return));
    const pulse_stream = stream orelse return;
    const bytes_per_frame = @sizeOf(i16) * 2;
    var frames_to_write: usize = playback_quantum_frames;
    if (nbytes != 0 and nbytes != std.math.maxInt(usize)) {
        const requested_frames = nbytes / bytes_per_frame;
        if (requested_frames > 0) {
            frames_to_write = requested_frames;
        }
    }
    var remaining_frames = @max(@as(usize, 1), frames_to_write);
    var wrote_nonzero = false;
    var scratch_buffer: [bus_buffer_mod.render_quantum_frames * bus_buffer_mod.stereo_channels]i16 = undefined;

    while (remaining_frames > 0) {
        const frames_this_write = @min(remaining_frames, playback_quantum_frames);
        const sample_count = std.math.mul(usize, frames_this_write, 2) catch return;

        var sample_buffer: [playback_quantum_samples]i16 = undefined;
        @memset(&sample_buffer, 0);
        self.buffer_mutex.lock();
        const available_before_fill = self.pcm_buffer.availableFrames();
        if (self.pcm_buffer.availableFrames() < frames_this_write) {
            _ = self.pcm_buffer.fillFromEngine(
                self.engine,
                self.bus_id,
                self.consumer_id,
                frames_this_write,
                scratch_buffer[0..],
            ) catch {};
        }
        const available_before_drain = self.pcm_buffer.availableFrames();
        const drained_frames = self.pcm_buffer.drainFrames(sample_buffer[0..sample_count], frames_this_write);
        self.buffer_mutex.unlock();

        if (drained_frames < frames_this_write) {
            self.underrun_count += 1;
            const now_ns = std.time.nanoTimestamp();
            if (self.last_underrun_log_ns == 0 or now_ns - self.last_underrun_log_ns >= underrun_warn_log_interval_ns) {
                self.last_underrun_log_ns = now_ns;
                std.log.warn(
                    "pulse bus playback underrun: bus={s} sink={s} requested_frames={d} drained_frames={d} available_before_fill={d} available_before_drain={d} underruns={d}",
                    .{
                        self.bus_id,
                        self.target_sink_name,
                        frames_this_write,
                        drained_frames,
                        available_before_fill,
                        available_before_drain,
                        self.underrun_count,
                    },
                );
            }
        }

        var nonzero = false;
        for (sample_buffer[0 .. drained_frames * bus_buffer_mod.stereo_channels]) |sample| {
            const magnitude: u16 = @intCast(@abs(sample));
            self.peak_abs_sample = @max(self.peak_abs_sample, magnitude);
            if (sample != 0) {
                nonzero = true;
                wrote_nonzero = true;
            }
        }

        if (c.pa_stream_write(
            pulse_stream,
            sample_buffer[0..sample_count].ptr,
            sample_count * @sizeOf(i16),
            null,
            0,
            c.PA_SEEK_RELATIVE,
        ) < 0) {
            return;
        }

        self.write_count += 1;
        remaining_frames -= frames_this_write;
    }

    if (wrote_nonzero) self.nonzero_write_count += 1;
}
