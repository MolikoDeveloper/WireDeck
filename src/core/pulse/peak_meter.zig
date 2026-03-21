const std = @import("std");
const c = @import("c.zig").c;
const sources_mod = @import("../audio/sources.zig");

const AtomicU32 = std.atomic.Value(u32);

pub const MeterSpec = struct {
    source_id: []const u8,
    channel_id: ?[]const u8 = null,
    pulse_source_name: []const u8,
    sink_input_index: ?u32 = null,
    channels: u8 = 2,
};

pub const PeakMonitor = struct {
    const Meter = struct {
        source_id: []u8,
        channel_id: ?[]u8,
        pulse_source_name: []u8,
        sink_input_index: ?u32,
        channels: u8,
        stream: *c.pa_stream,
        left_peak_milli: AtomicU32 = AtomicU32.init(0),
        right_peak_milli: AtomicU32 = AtomicU32.init(0),

        fn deinit(self: *Meter, allocator: std.mem.Allocator) void {
            c.pa_stream_set_read_callback(self.stream, null, null);
            c.pa_stream_set_state_callback(self.stream, null, null);
            _ = c.pa_stream_disconnect(self.stream);
            c.pa_stream_unref(self.stream);
            allocator.free(self.source_id);
            if (self.channel_id) |channel_id| allocator.free(channel_id);
            allocator.free(self.pulse_source_name);
            allocator.destroy(self);
        }
    };

    allocator: std.mem.Allocator,
    mainloop: ?*c.pa_threaded_mainloop = null,
    api: ?*c.pa_mainloop_api = null,
    context: ?*c.pa_context = null,
    ready: bool = false,
    failed: bool = false,
    meters: std.ArrayList(*Meter),

    pub fn init(allocator: std.mem.Allocator) PeakMonitor {
        return .{
            .allocator = allocator,
            .meters = .empty,
        };
    }

    pub fn connect(self: *PeakMonitor) !void {
        if (self.context != null) return;

        self.ready = false;
        self.failed = false;

        self.mainloop = c.pa_threaded_mainloop_new() orelse return error.PulseMainloopCreateFailed;
        errdefer {
            c.pa_threaded_mainloop_free(self.mainloop);
            self.mainloop = null;
        }

        self.api = c.pa_threaded_mainloop_get_api(self.mainloop.?);
        self.context = c.pa_context_new(self.api, "wiredeck-peak") orelse return error.PulseContextCreateFailed;
        errdefer {
            c.pa_context_disconnect(self.context);
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

        while (true) {
            const state = c.pa_context_get_state(self.context);
            switch (state) {
                c.PA_CONTEXT_READY => {
                    self.ready = true;
                    return;
                },
                c.PA_CONTEXT_FAILED, c.PA_CONTEXT_TERMINATED => {
                    self.failed = true;
                    return error.PulseContextNotReady;
                },
                else => c.pa_threaded_mainloop_wait(self.mainloop.?),
            }
        }
    }

    pub fn deinit(self: *PeakMonitor) void {
        if (self.mainloop) |mainloop| {
            c.pa_threaded_mainloop_lock(mainloop);
            self.clearMetersLocked();
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
        } else {
            self.clearMeters();
        }

        self.meters.deinit(self.allocator);
        self.ready = false;
        self.failed = false;
    }

    pub fn pump(_: *PeakMonitor, _: i32) !void {}

    pub fn sync(self: *PeakMonitor, specs: []const MeterSpec) !void {
        try self.connect();
        const mainloop = self.mainloop.?;
        c.pa_threaded_mainloop_lock(mainloop);
        defer c.pa_threaded_mainloop_unlock(mainloop);

        if (self.matchesSpecs(specs)) return;
        self.clearMetersLocked();
        for (specs) |spec| {
            const meter = try self.createMeterLocked(spec);
            try self.meters.append(self.allocator, meter);
        }
    }

    pub fn wouldChange(self: *const PeakMonitor, specs: []const MeterSpec) bool {
        return !self.matchesSpecs(specs);
    }

    pub fn applyToSources(self: *const PeakMonitor, sources: []sources_mod.Source) void {
        for (self.meters.items) |meter| {
            for (sources) |*source| {
                if (!std.mem.eql(u8, source.id, meter.source_id)) continue;
                const left = @as(f32, @floatFromInt(meter.left_peak_milli.load(.monotonic))) / 1000.0;
                const right = @as(f32, @floatFromInt(meter.right_peak_milli.load(.monotonic))) / 1000.0;
                source.level_left = left;
                source.level_right = right;
                source.level = @max(left, right);
            }
        }
    }

    pub fn applyToChannels(self: *const PeakMonitor, channels: anytype) void {
        for (self.meters.items) |meter| {
            const channel_id = meter.channel_id orelse continue;
            for (channels) |*channel| {
                if (!std.mem.eql(u8, channel.id, channel_id)) continue;
                const left = @as(f32, @floatFromInt(meter.left_peak_milli.load(.monotonic))) / 1000.0;
                const right = @as(f32, @floatFromInt(meter.right_peak_milli.load(.monotonic))) / 1000.0;
                channel.level_left = left;
                channel.level_right = right;
                channel.level = @max(left, right);
            }
        }
    }

    fn clearMeters(self: *PeakMonitor) void {
        for (self.meters.items) |meter| meter.deinit(self.allocator);
        self.meters.clearRetainingCapacity();
    }

    fn clearMetersLocked(self: *PeakMonitor) void {
        for (self.meters.items) |meter| meter.deinit(self.allocator);
        self.meters.clearRetainingCapacity();
    }

    fn matchesSpecs(self: *const PeakMonitor, specs: []const MeterSpec) bool {
        if (self.meters.items.len != specs.len) return false;
        for (self.meters.items, specs) |meter, spec| {
            if (!std.mem.eql(u8, meter.source_id, spec.source_id)) return false;
            if ((meter.channel_id == null) != (spec.channel_id == null)) return false;
            if (meter.channel_id != null and !std.mem.eql(u8, meter.channel_id.?, spec.channel_id.?)) return false;
            if (!std.mem.eql(u8, meter.pulse_source_name, spec.pulse_source_name)) return false;
            if (meter.sink_input_index != spec.sink_input_index) return false;
            if (meter.channels != spec.channels) return false;
        }
        return true;
    }

    fn createMeterLocked(self: *PeakMonitor, spec: MeterSpec) !*Meter {
        const meter = try self.allocator.create(Meter);
        errdefer self.allocator.destroy(meter);

        const source_id = try self.allocator.dupe(u8, spec.source_id);
        errdefer self.allocator.free(source_id);
        const channel_id = if (spec.channel_id) |value|
            try self.allocator.dupe(u8, value)
        else
            null;
        errdefer if (channel_id) |value| self.allocator.free(value);
        const pulse_source_name = try self.allocator.dupe(u8, spec.pulse_source_name);
        errdefer self.allocator.free(pulse_source_name);
        const label = try std.fmt.allocPrint(self.allocator, "WireDeck Peak {s}", .{spec.source_id});
        defer self.allocator.free(label);
        const label_z = try self.allocator.dupeZ(u8, label);
        defer self.allocator.free(label_z);
        const source_name_z = try self.allocator.dupeZ(u8, spec.pulse_source_name);
        defer self.allocator.free(source_name_z);

        var sample_spec = c.pa_sample_spec{
            .format = c.PA_SAMPLE_FLOAT32NE,
            .rate = 48000,
            .channels = @max(@as(u8, 1), spec.channels),
        };
        var channel_map: c.pa_channel_map = undefined;
        if (sample_spec.channels <= 1) {
            _ = c.pa_channel_map_init_mono(&channel_map);
        } else {
            _ = c.pa_channel_map_init_stereo(&channel_map);
            sample_spec.channels = 2;
        }
        const stream = c.pa_stream_new(self.context, label_z.ptr, &sample_spec, &channel_map) orelse return error.PulsePeakStreamCreateFailed;
        errdefer c.pa_stream_unref(stream);

        meter.* = .{
            .source_id = source_id,
            .channel_id = channel_id,
            .pulse_source_name = pulse_source_name,
            .sink_input_index = spec.sink_input_index,
            .channels = sample_spec.channels,
            .stream = stream,
        };

        c.pa_stream_set_read_callback(stream, streamReadCb, meter);
        c.pa_stream_set_state_callback(stream, streamStateCb, self);
        if (spec.sink_input_index) |sink_input_index| {
            if (c.pa_stream_set_monitor_stream(stream, sink_input_index) < 0) {
                return error.PulsePeakMonitorStreamFailed;
            }
        }

        var attr = c.pa_buffer_attr{
            .maxlength = @sizeOf(f32) * @as(u32, sample_spec.channels) * 2048,
            .tlength = 0,
            .prebuf = 0,
            .minreq = 0,
            .fragsize = @sizeOf(f32) * @as(u32, sample_spec.channels) * 128,
        };
        const flags: c.pa_stream_flags_t =
            @as(c.pa_stream_flags_t, @intCast(c.PA_STREAM_DONT_MOVE)) |
            @as(c.pa_stream_flags_t, @intCast(c.PA_STREAM_ADJUST_LATENCY)) |
            @as(c.pa_stream_flags_t, @intCast(c.PA_STREAM_AUTO_TIMING_UPDATE));

        if (c.pa_stream_connect_record(stream, source_name_z.ptr, &attr, flags) < 0) {
            return error.PulsePeakConnectFailed;
        }

        return meter;
    }
};

fn contextStateCb(context: ?*c.pa_context, userdata: ?*anyopaque) callconv(.c) void {
    const self: *PeakMonitor = @ptrCast(@alignCast(userdata orelse return));
    const state = c.pa_context_get_state(context);
    switch (state) {
        c.PA_CONTEXT_READY => self.ready = true,
        c.PA_CONTEXT_FAILED, c.PA_CONTEXT_TERMINATED => self.failed = true,
        else => {},
    }
    if (self.mainloop) |mainloop| {
        c.pa_threaded_mainloop_signal(mainloop, 0);
    }
}

fn streamStateCb(_: ?*c.pa_stream, userdata: ?*anyopaque) callconv(.c) void {
    const self: *PeakMonitor = @ptrCast(@alignCast(userdata orelse return));
    if (self.mainloop) |mainloop| {
        c.pa_threaded_mainloop_signal(mainloop, 0);
    }
}

fn streamReadCb(stream: ?*c.pa_stream, nbytes: usize, userdata: ?*anyopaque) callconv(.c) void {
    _ = nbytes;
    const meter: *PeakMonitor.Meter = @ptrCast(@alignCast(userdata orelse return));
    const pulse_stream = stream orelse return;
    var raw_data: ?*const anyopaque = null;
    var raw_nbytes: usize = 0;
    if (c.pa_stream_peek(pulse_stream, &raw_data, &raw_nbytes) < 0) return;
    defer _ = c.pa_stream_drop(pulse_stream);

    if (raw_data == null or raw_nbytes == 0) return;
    const sample_spec = c.pa_stream_get_sample_spec(pulse_stream) orelse return;
    const channels: usize = if (sample_spec.*.channels == 0) 1 else sample_spec.*.channels;
    const total_samples = raw_nbytes / @sizeOf(f32);
    if (total_samples == 0) return;

    const samples = @as([*]const f32, @ptrCast(@alignCast(raw_data.?)))[0..total_samples];
    var left_peak: f32 = 0.0;
    var right_peak: f32 = 0.0;
    if (channels == 1) {
        for (samples) |sample| {
            const amplitude = @abs(sample);
            if (amplitude > left_peak) left_peak = amplitude;
        }
        right_peak = left_peak;
    } else {
        var index: usize = 0;
        while (index < samples.len) : (index += channels) {
            const left_sample = samples[index];
            const right_sample = samples[@min(index + 1, samples.len - 1)];
            const left = @abs(left_sample);
            const right = @abs(right_sample);
            if (left > left_peak) left_peak = left;
            if (right > right_peak) right_peak = right;
        }
    }

    meter.left_peak_milli.store(levelToMilli(left_peak), .monotonic);
    meter.right_peak_milli.store(levelToMilli(right_peak), .monotonic);
}

fn levelToMilli(value: f32) u32 {
    const clamped = std.math.clamp(value, 0.0, 1.0);
    return @intFromFloat(@round(clamped * 1000.0));
}
