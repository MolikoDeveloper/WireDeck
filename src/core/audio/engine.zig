const std = @import("std");
const buses_mod = @import("buses.zig");
const channels_mod = @import("channels.zig");
const sends_mod = @import("sends.zig");
const FxRuntime = @import("../../plugins/fx_runtime.zig").FxRuntime;
const ChannelProcessStatus = FxRuntime.ChannelProcessStatus;

pub const MeterLevels = struct {
    left: f32 = 0.0,
    right: f32 = 0.0,
    level: f32 = 0.0,
};

pub const ChannelMetrics = struct {
    input: MeterLevels = .{},
    post_fx: MeterLevels = .{},
    post_fader: MeterLevels = .{},
    latency_frames: u32 = 0,
    sample_rate_hz: u32 = 0,
    frame_count: u32 = 0,
    generation: u64 = 0,
};

pub const BusMetrics = struct {
    mix: MeterLevels = .{},
    contributor_count: u32 = 0,
    generation: u64 = 0,
};

pub const BusPcmReadResult = struct {
    frames: usize = 0,
    sample_rate_hz: u32 = 0,
};

const ChannelState = struct {
    id: []u8,
    volume: f32 = 1.0,
    muted: bool = false,
    bound_source_id: ?[]u8 = null,
    metrics: ChannelMetrics = .{},
    render_buffer: std.ArrayList(f32),
    render_read_sample_index: usize = 0,

    fn deinit(self: *ChannelState, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        if (self.bound_source_id) |value| allocator.free(value);
        self.render_buffer.deinit(allocator);
    }
};

const BusState = struct {
    id: []u8,
    volume: f32 = 1.0,
    muted: bool = false,
    system_volume: f32 = 1.0,
    system_muted: bool = false,
    metrics: BusMetrics = .{},
    tap_cycle_token: u64 = 0,
    tap_sample_rate_hz: u32 = 0,
    tap_mix_buffer: std.ArrayList(f32),
    tap_stream_buffer: std.ArrayList(f32),
    tap_consumers: std.ArrayList(BusTapConsumer),

    fn deinit(self: *BusState, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        self.tap_mix_buffer.deinit(allocator);
        self.tap_stream_buffer.deinit(allocator);
        for (self.tap_consumers.items) |*consumer| consumer.deinit(allocator);
        self.tap_consumers.deinit(allocator);
    }
};

const BusTapConsumer = struct {
    id: []u8,
    read_sample_index: usize = 0,

    fn deinit(self: *BusTapConsumer, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
    }
};

const SendState = struct {
    channel_id: []u8,
    bus_id: []u8,
    gain: f32 = 1.0,
    enabled: bool = true,
    pre_fader: bool = false,

    fn deinit(self: *SendState, allocator: std.mem.Allocator) void {
        allocator.free(self.channel_id);
        allocator.free(self.bus_id);
    }
};

const render_sample_rate_hz: u32 = 48_000;
const render_quantum_frames: usize = 128;
const render_quantum_ns: u64 = @intCast((@as(u128, render_quantum_frames) * std.time.ns_per_s) / render_sample_rate_hz);
const max_remote_buffer_frames: usize = 4096;
const jitter_target_blocks: usize = 2;
const jitter_rebuffer_divisor: usize = 2;
const max_drift_correction_ratio: f64 = 0.01;
const render_late_warn_threshold_ns: i128 = 2 * std.time.ns_per_ms;
const render_late_warn_log_interval_ns: i128 = 1000 * std.time.ns_per_ms;

const RemoteInputState = struct {
    source_id: []u8,
    channels: u8 = 2,
    sample_rate_hz: u32 = 0,
    buffered_samples: std.ArrayList(f32),
    read_position_frames: f64 = 0.0,
    startup_buffering: bool = true,
    packet_count: u64 = 0,
    last_packet_ns: i128 = 0,

    fn init(allocator: std.mem.Allocator, source_id: []const u8) !RemoteInputState {
        return .{
            .source_id = try allocator.dupe(u8, source_id),
            .buffered_samples = .empty,
        };
    }

    fn deinit(self: *RemoteInputState, allocator: std.mem.Allocator) void {
        allocator.free(self.source_id);
        self.buffered_samples.deinit(allocator);
    }
};

pub const AudioEngine = struct {
    allocator: std.mem.Allocator,
    state_mutex: std.Thread.Mutex = .{},
    audio_mutex: std.Thread.Mutex = .{},
    render_thread: ?std.Thread = null,
    render_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    last_render_late_warn_ns: i128 = 0,
    render_generation: u64 = 0,
    graph_signature: u64 = 0,
    channels: std.ArrayList(ChannelState),
    buses: std.ArrayList(BusState),
    sends: std.ArrayList(SendState),
    remote_inputs: std.ArrayList(RemoteInputState),

    pub fn init(allocator: std.mem.Allocator) AudioEngine {
        return .{
            .allocator = allocator,
            .channels = .empty,
            .buses = .empty,
            .sends = .empty,
            .remote_inputs = .empty,
        };
    }

    pub fn start(self: *AudioEngine) !void {
        if (self.render_thread != null) return;
        self.render_stop.store(false, .release);
        self.render_thread = try std.Thread.spawn(.{}, renderWorkerMain, .{self});
    }

    pub fn stop(self: *AudioEngine) void {
        self.render_stop.store(true, .release);
        if (self.render_thread) |thread| {
            thread.join();
            self.render_thread = null;
        }
    }

    pub fn deinit(self: *AudioEngine) void {
        self.stop();
        self.lockStateAndAudio();
        defer self.unlockStateAndAudio();

        clearChannelStates(self.allocator, &self.channels);
        clearBusStates(self.allocator, &self.buses);
        clearSendStates(self.allocator, &self.sends);
        clearRemoteInputStates(self.allocator, &self.remote_inputs);
        self.channels.deinit(self.allocator);
        self.buses.deinit(self.allocator);
        self.sends.deinit(self.allocator);
        self.remote_inputs.deinit(self.allocator);
    }

    pub fn syncGraph(
        self: *AudioEngine,
        channels: []const channels_mod.Channel,
        buses: []const buses_mod.Bus,
        sends: []const sends_mod.Send,
    ) !void {
        self.lockStateAndAudio();
        defer self.unlockStateAndAudio();

        const next_signature = computeGraphSignature(channels, buses, sends);
        if ((self.channels.items.len != 0 or self.buses.items.len != 0 or self.sends.items.len != 0) and
            next_signature == self.graph_signature)
        {
            return;
        }

        var next_channels = std.ArrayList(ChannelState).empty;
        errdefer clearChannelStates(self.allocator, &next_channels);
        for (channels) |channel| {
            const previous = findChannelStatePtr(self.channels.items, channel.id);
            try next_channels.append(self.allocator, .{
                .id = try self.allocator.dupe(u8, channel.id),
                .volume = channel.volume,
                .muted = channel.muted,
                .bound_source_id = if (channel.bound_source_id) |value| try self.allocator.dupe(u8, value) else null,
                .metrics = if (previous) |state| state.metrics else .{},
                .render_buffer = .empty,
            });
            if (previous) |state| {
                next_channels.items[next_channels.items.len - 1].render_buffer = state.render_buffer;
                next_channels.items[next_channels.items.len - 1].render_read_sample_index = state.render_read_sample_index;
                state.render_buffer = .empty;
                state.render_read_sample_index = 0;
            }
        }

        var next_buses = std.ArrayList(BusState).empty;
        errdefer clearBusStates(self.allocator, &next_buses);
        for (buses) |bus| {
            const previous = findBusStatePtr(self.buses.items, bus.id);
            var next_bus: BusState = .{
                .id = try self.allocator.dupe(u8, bus.id),
                .volume = bus.volume,
                .muted = bus.muted,
                .system_volume = bus.system_volume,
                .system_muted = bus.system_muted,
                .metrics = if (previous) |state| state.metrics else .{},
                .tap_cycle_token = if (previous) |state| state.tap_cycle_token else 0,
                .tap_sample_rate_hz = if (previous) |state| state.tap_sample_rate_hz else 0,
                .tap_mix_buffer = .empty,
                .tap_stream_buffer = .empty,
                .tap_consumers = .empty,
            };
            if (previous) |state| {
                next_bus.tap_mix_buffer = state.tap_mix_buffer;
                next_bus.tap_stream_buffer = state.tap_stream_buffer;
                next_bus.tap_consumers = state.tap_consumers;
                state.tap_cycle_token = 0;
                state.tap_sample_rate_hz = 0;
                state.tap_mix_buffer = .empty;
                state.tap_stream_buffer = .empty;
                state.tap_consumers = .empty;
            }
            try next_buses.append(self.allocator, next_bus);
        }

        var next_sends = std.ArrayList(SendState).empty;
        errdefer clearSendStates(self.allocator, &next_sends);
        for (sends) |send| {
            try next_sends.append(self.allocator, .{
                .channel_id = try self.allocator.dupe(u8, send.channel_id),
                .bus_id = try self.allocator.dupe(u8, send.bus_id),
                .gain = send.gain,
                .enabled = send.enabled,
                .pre_fader = send.pre_fader,
            });
        }

        clearChannelStates(self.allocator, &self.channels);
        clearBusStates(self.allocator, &self.buses);
        clearSendStates(self.allocator, &self.sends);
        self.channels.deinit(self.allocator);
        self.buses.deinit(self.allocator);
        self.sends.deinit(self.allocator);
        self.channels = next_channels;
        self.buses = next_buses;
        self.sends = next_sends;
        self.recomputeBusMetricsLocked();
        if (next_signature != self.graph_signature) {
            self.graph_signature = next_signature;
            std.log.info("audio engine graph sync: channels={any} buses={any} sends={any}", .{
                channels.len,
                buses.len,
                sends.len,
            });
        }
    }

    pub fn populateChannelInput(
        self: *AudioEngine,
        channel_id: []const u8,
        left: []f32,
        right: []f32,
        sample_rate_hz: u32,
    ) bool {
        if (left.len == 0 or left.len != right.len) return false;

        self.state_mutex.lock();
        defer self.state_mutex.unlock();

        const channel = findChannelStatePtr(self.channels.items, channel_id) orelse return false;
        const bound_source_id = channel.bound_source_id orelse return false;
        const remote = findRemoteInputStatePtr(self.remote_inputs.items, bound_source_id) orelse return false;

        drainRemoteFramesLocked(remote, left, right, sample_rate_hz);
        compactRemoteInputLocked(remote);
        return true;
    }

    pub fn processChannel(
        self: *AudioEngine,
        runtime: *FxRuntime,
        channel_id: []const u8,
        left: []f32,
        right: []f32,
        sample_rate_hz: u32,
        cycle_token: u64,
    ) bool {
        return switch (self.processChannelStatus(runtime, channel_id, left, right, sample_rate_hz, cycle_token)) {
            .processed, .bypass_no_chain => true,
            .bypass_busy, .bypass_failed => false,
        };
    }

    pub fn processChannelStatus(
        self: *AudioEngine,
        runtime: *FxRuntime,
        channel_id: []const u8,
        left: []f32,
        right: []f32,
        sample_rate_hz: u32,
        cycle_token: u64,
    ) ChannelProcessStatus {
        if (left.len == 0 or left.len != right.len) return .bypass_failed;
        _ = cycle_token;

        const input_levels = measureLevels(left, right);
        const processed = runtime.processChannelStatus(channel_id, left, right);

        var channel_volume: f32 = 1.0;
        var channel_muted = false;
        self.state_mutex.lock();
        if (findChannelStatePtr(self.channels.items, channel_id)) |channel| {
            channel_volume = channel.volume;
            channel_muted = channel.muted;
        }
        self.state_mutex.unlock();
        const post_fx_levels = measureLevels(left, right);

        self.state_mutex.lock();
        if (findChannelStatePtr(self.channels.items, channel_id)) |channel| {
            self.render_generation += 1;
            channel.metrics.input = input_levels;
            channel.metrics.post_fx = post_fx_levels;
            channel.metrics.post_fader = applyChannelFader(post_fx_levels, channel_volume, channel_muted);
            channel.metrics.latency_frames = runtime.channelLatencyFrames(channel_id);
            channel.metrics.sample_rate_hz = sample_rate_hz;
            channel.metrics.frame_count = @intCast(left.len);
            channel.metrics.generation = self.render_generation;
        }
        self.state_mutex.unlock();

        self.audio_mutex.lock();
        defer self.audio_mutex.unlock();
        const channel = findChannelStatePtr(self.channels.items, channel_id) orelse return processed;
        appendChannelRenderAudioLocked(self.allocator, channel, left, right, sample_rate_hz) catch {};
        return processed;
    }

    pub fn channelLevels(self: *AudioEngine, channel_id: []const u8, stage: channels_mod.MeterStage) ?MeterLevels {
        if (!self.state_mutex.tryLock()) return null;
        defer self.state_mutex.unlock();

        const channel = findChannelState(self.channels.items, channel_id) orelse return null;
        if (channel.metrics.generation == 0) return null;
        return switch (stage) {
            .input => channel.metrics.input,
            .post_fx => channel.metrics.post_fx,
            .post_fader => channel.metrics.post_fader,
        };
    }

    pub fn busLevels(self: *AudioEngine, bus_id: []const u8) ?BusMetrics {
        if (!self.state_mutex.tryLock()) return null;
        defer self.state_mutex.unlock();

        const bus = findBusState(self.buses.items, bus_id) orelse return null;
        if (bus.metrics.generation == 0) return null;
        return bus.metrics;
    }

    pub fn readBusPcmS16(self: *AudioEngine, bus_id: []const u8, out: []i16) BusPcmReadResult {
        return self.readBusPcmS16ForConsumer(bus_id, "__default__", out);
    }

    pub fn readBusPcmS16ForConsumer(
        self: *AudioEngine,
        bus_id: []const u8,
        consumer_id: []const u8,
        out: []i16,
    ) BusPcmReadResult {
        if (out.len < 2) return .{};

        while (true) {
            self.audio_mutex.lock();
            const bus = findBusStatePtr(self.buses.items, bus_id) orelse {
                self.audio_mutex.unlock();
                return .{};
            };
            const consumer = ensureBusTapConsumerLocked(self.allocator, bus, consumer_id) catch {
                self.audio_mutex.unlock();
                return .{};
            };
            const needs_render = self.render_thread == null and consumer.read_sample_index >= bus.tap_stream_buffer.items.len;
            if (!needs_render) {
                if (consumer.read_sample_index >= bus.tap_stream_buffer.items.len) {
                    compactBusTapStreamLocked(self.allocator, bus);
                    const sample_rate_hz = bus.tap_sample_rate_hz;
                    self.audio_mutex.unlock();
                    return .{ .sample_rate_hz = sample_rate_hz };
                }

                const available_samples = @min(out.len, bus.tap_stream_buffer.items.len - consumer.read_sample_index);
                if (available_samples < 2) {
                    const sample_rate_hz = bus.tap_sample_rate_hz;
                    self.audio_mutex.unlock();
                    return .{ .sample_rate_hz = sample_rate_hz };
                }

                for (0..available_samples) |index| {
                    const sample = std.math.clamp(bus.tap_stream_buffer.items[consumer.read_sample_index + index], -1.0, 1.0);
                    out[index] = @intFromFloat(@round(sample * 32767.0));
                }
                consumer.read_sample_index += available_samples;
                compactBusTapStreamLocked(self.allocator, bus);
                const sample_rate_hz = bus.tap_sample_rate_hz;
                self.audio_mutex.unlock();
                return .{
                    .frames = available_samples / 2,
                    .sample_rate_hz = sample_rate_hz,
                };
            }
            self.audio_mutex.unlock();
            self.renderQuantum(out.len / 2);
        }
    }

    pub fn releaseBusTapConsumer(self: *AudioEngine, bus_id: []const u8, consumer_id: []const u8) void {
        self.audio_mutex.lock();
        defer self.audio_mutex.unlock();

        const bus = findBusStatePtr(self.buses.items, bus_id) orelse return;
        releaseBusTapConsumerLocked(self.allocator, bus, consumer_id);
        compactBusTapStreamLocked(self.allocator, bus);
    }

    pub fn ingestRemoteFloat32(
        self: *AudioEngine,
        source_id: []const u8,
        channels: u8,
        sample_rate_hz: u32,
        samples: []align(1) const f32,
    ) !void {
        const remote_channels = @max(@as(u8, 1), channels);
        if (samples.len == 0) return;

        self.state_mutex.lock();
        defer self.state_mutex.unlock();

        const remote = try ensureRemoteInputStateLocked(self, source_id);
        compactRemoteInputLocked(remote);

        const base_len = remote.buffered_samples.items.len;
        try remote.buffered_samples.resize(self.allocator, base_len + samples.len);
        for (samples, 0..) |sample, index| {
            remote.buffered_samples.items[base_len + index] = sample;
        }
        remote.channels = remote_channels;
        remote.sample_rate_hz = sample_rate_hz;
        remote.packet_count += 1;
        remote.last_packet_ns = std.time.nanoTimestamp();
        trimRemoteInputLocked(remote);
    }

    pub fn ingestRemoteS16(
        self: *AudioEngine,
        source_id: []const u8,
        channels: u8,
        sample_rate_hz: u32,
        samples: []align(1) const i16,
    ) !void {
        const remote_channels = @max(@as(u8, 1), channels);
        if (samples.len == 0) return;

        self.state_mutex.lock();
        defer self.state_mutex.unlock();

        const remote = try ensureRemoteInputStateLocked(self, source_id);
        compactRemoteInputLocked(remote);

        const base_len = remote.buffered_samples.items.len;
        try remote.buffered_samples.resize(self.allocator, base_len + samples.len);
        for (samples, 0..) |sample, index| {
            remote.buffered_samples.items[base_len + index] = @as(f32, @floatFromInt(sample)) / 32768.0;
        }

        remote.channels = remote_channels;
        remote.sample_rate_hz = sample_rate_hz;
        remote.packet_count += 1;
        remote.last_packet_ns = std.time.nanoTimestamp();
        trimRemoteInputLocked(remote);
    }

    pub fn deactivateRemoteSource(self: *AudioEngine, source_id: []const u8) void {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();

        const remote = findRemoteInputStatePtr(self.remote_inputs.items, source_id) orelse return;
        remote.buffered_samples.clearRetainingCapacity();
        remote.read_position_frames = 0.0;
        remote.startup_buffering = true;
        remote.last_packet_ns = 0;
        remote.packet_count = 0;
    }

    fn recomputeBusMetricsLocked(self: *AudioEngine) void {
        for (self.buses.items) |*bus| {
            if (bus.muted or bus.system_muted) {
                bus.metrics = .{};
                continue;
            }

            var left_energy: f32 = 0.0;
            var right_energy: f32 = 0.0;
            var contributors: u32 = 0;

            for (self.sends.items) |send| {
                if (!send.enabled) continue;
                if (!std.mem.eql(u8, send.bus_id, bus.id)) continue;

                const channel = findChannelState(self.channels.items, send.channel_id) orelse continue;
                if (channel.metrics.generation == 0) continue;
                if (channel.muted) continue;

                const source = if (send.pre_fader) channel.metrics.post_fx else channel.metrics.post_fader;
                const send_gain = std.math.clamp(send.gain * bus.volume * bus.system_volume, 0.0, 4.0);
                const left = std.math.clamp(source.left * send_gain, 0.0, 1.0);
                const right = std.math.clamp(source.right * send_gain, 0.0, 1.0);
                if (left <= 0.00001 and right <= 0.00001) continue;

                left_energy += left * left;
                right_energy += right * right;
                contributors += 1;
            }

            if (contributors == 0) {
                bus.metrics = .{};
                continue;
            }

            const contributor_count: f32 = @floatFromInt(contributors);
            const left = std.math.clamp(@sqrt(left_energy / contributor_count), 0.0, 1.0);
            const right = std.math.clamp(@sqrt(right_energy / contributor_count), 0.0, 1.0);
            bus.metrics = .{
                .mix = .{
                    .left = left,
                    .right = right,
                    .level = @max(left, right),
                },
                .contributor_count = contributors,
                .generation = self.render_generation,
            };
        }
    }

    fn renderQuantum(self: *AudioEngine, frame_count: usize) void {
        self.lockStateAndAudio();
        defer self.unlockStateAndAudio();
        renderBusQuantumLocked(self, frame_count);
    }

    fn lockStateAndAudio(self: *AudioEngine) void {
        self.state_mutex.lock();
        self.audio_mutex.lock();
    }

    fn unlockStateAndAudio(self: *AudioEngine) void {
        self.audio_mutex.unlock();
        self.state_mutex.unlock();
    }
};

fn measureLevels(left: []const f32, right: []const f32) MeterLevels {
    var peak_left: f32 = 0.0;
    var peak_right: f32 = 0.0;

    for (left, right) |sample_left, sample_right| {
        peak_left = @max(peak_left, @abs(sample_left));
        peak_right = @max(peak_right, @abs(sample_right));
    }

    peak_left = std.math.clamp(peak_left, 0.0, 1.0);
    peak_right = std.math.clamp(peak_right, 0.0, 1.0);
    return .{
        .left = peak_left,
        .right = peak_right,
        .level = @max(peak_left, peak_right),
    };
}

fn measureInterleavedLevels(samples: []const f32) MeterLevels {
    if (samples.len < 2) return .{};

    var peak_left: f32 = 0.0;
    var peak_right: f32 = 0.0;
    var index: usize = 0;
    while (index + 1 < samples.len) : (index += 2) {
        peak_left = @max(peak_left, @abs(samples[index]));
        peak_right = @max(peak_right, @abs(samples[index + 1]));
    }

    peak_left = std.math.clamp(peak_left, 0.0, 1.0);
    peak_right = std.math.clamp(peak_right, 0.0, 1.0);
    return .{
        .left = peak_left,
        .right = peak_right,
        .level = @max(peak_left, peak_right),
    };
}

fn applyChannelFader(levels: MeterLevels, channel_volume: f32, channel_muted: bool) MeterLevels {
    if (channel_muted) return .{};

    const gain = std.math.clamp(channel_volume, 0.0, 4.0);
    const left = std.math.clamp(levels.left * gain, 0.0, 1.0);
    const right = std.math.clamp(levels.right * gain, 0.0, 1.0);
    return .{
        .left = left,
        .right = right,
        .level = @max(left, right),
    };
}

fn approxEq(left: f32, right: f32) bool {
    return @abs(left - right) <= 0.001;
}

fn clearChannelStates(allocator: std.mem.Allocator, items: *std.ArrayList(ChannelState)) void {
    for (items.items) |*item| item.deinit(allocator);
    items.clearRetainingCapacity();
}

fn clearBusStates(allocator: std.mem.Allocator, items: *std.ArrayList(BusState)) void {
    for (items.items) |*item| item.deinit(allocator);
    items.clearRetainingCapacity();
}

fn clearSendStates(allocator: std.mem.Allocator, items: *std.ArrayList(SendState)) void {
    for (items.items) |*item| item.deinit(allocator);
    items.clearRetainingCapacity();
}

fn clearRemoteInputStates(allocator: std.mem.Allocator, items: *std.ArrayList(RemoteInputState)) void {
    for (items.items) |*item| item.deinit(allocator);
    items.clearRetainingCapacity();
}

fn computeGraphSignature(
    channels: []const channels_mod.Channel,
    buses: []const buses_mod.Bus,
    sends: []const sends_mod.Send,
) u64 {
    var hasher = std.hash.Wyhash.init(0);

    for (channels) |channel| {
        hasher.update(channel.id);
        hasher.update(std.mem.asBytes(&channel.volume));
        hasher.update(std.mem.asBytes(&channel.muted));
        hasher.update(std.mem.asBytes(&channel.system_volume));
        hasher.update(std.mem.asBytes(&channel.system_muted));
        if (channel.bound_source_id) |bound_source_id| hasher.update(bound_source_id);
    }
    for (buses) |bus| {
        hasher.update(bus.id);
        hasher.update(std.mem.asBytes(&bus.volume));
        hasher.update(std.mem.asBytes(&bus.muted));
        hasher.update(std.mem.asBytes(&bus.system_volume));
        hasher.update(std.mem.asBytes(&bus.system_muted));
        hasher.update(std.mem.asBytes(&bus.share_on_network));
        hasher.update(std.mem.asBytes(&bus.expose_as_microphone));
    }
    for (sends) |send| {
        hasher.update(send.channel_id);
        hasher.update(send.bus_id);
        hasher.update(std.mem.asBytes(&send.gain));
        hasher.update(std.mem.asBytes(&send.enabled));
        hasher.update(std.mem.asBytes(&send.pre_fader));
    }

    return hasher.final();
}

fn findChannelState(items: []const ChannelState, channel_id: []const u8) ?ChannelState {
    for (items) |item| {
        if (std.mem.eql(u8, item.id, channel_id)) return item;
    }
    return null;
}

fn findChannelStatePtr(items: []ChannelState, channel_id: []const u8) ?*ChannelState {
    for (items) |*item| {
        if (std.mem.eql(u8, item.id, channel_id)) return item;
    }
    return null;
}

fn findBusState(items: []const BusState, bus_id: []const u8) ?BusState {
    for (items) |item| {
        if (std.mem.eql(u8, item.id, bus_id)) return item;
    }
    return null;
}

fn findBusStatePtr(items: []BusState, bus_id: []const u8) ?*BusState {
    for (items) |*item| {
        if (std.mem.eql(u8, item.id, bus_id)) return item;
    }
    return null;
}

fn findRemoteInputStatePtr(items: []RemoteInputState, source_id: []const u8) ?*RemoteInputState {
    for (items) |*item| {
        if (std.mem.eql(u8, item.source_id, source_id)) return item;
    }
    return null;
}

fn ensureRemoteInputStateLocked(self: *AudioEngine, source_id: []const u8) !*RemoteInputState {
    if (findRemoteInputStatePtr(self.remote_inputs.items, source_id)) |remote| return remote;
    try self.remote_inputs.append(self.allocator, try RemoteInputState.init(self.allocator, source_id));
    return &self.remote_inputs.items[self.remote_inputs.items.len - 1];
}

fn compactRemoteInputLocked(remote: *RemoteInputState) void {
    const channels = @max(@as(usize, 1), remote.channels);
    const total_frames = remote.buffered_samples.items.len / channels;
    const consumed_frames = @min(total_frames, @as(usize, @intFromFloat(@floor(remote.read_position_frames))));
    if (consumed_frames == 0) return;
    if (consumed_frames >= total_frames) {
        remote.buffered_samples.clearRetainingCapacity();
        remote.read_position_frames = 0.0;
        remote.startup_buffering = true;
        return;
    }

    const consumed_samples = consumed_frames * channels;
    const remaining = remote.buffered_samples.items.len - consumed_samples;
    std.mem.copyForwards(f32, remote.buffered_samples.items[0..remaining], remote.buffered_samples.items[consumed_samples..]);
    remote.buffered_samples.items.len = remaining;
    remote.read_position_frames -= @as(f64, @floatFromInt(consumed_frames));
}

fn trimRemoteInputLocked(remote: *RemoteInputState) void {
    const max_frames = max_remote_buffer_frames;
    const buffered_frames = bufferedFrameCountLocked(remote);
    if (buffered_frames <= max_frames) return;

    const overflow = buffered_frames - max_frames;
    remote.read_position_frames += @as(f64, @floatFromInt(overflow));
    compactRemoteInputLocked(remote);
}

fn drainRemoteFramesLocked(remote: *RemoteInputState, left: []f32, right: []f32, sample_rate_hz: u32) void {
    zeroOutput(left, right);

    const output_rate_hz = if (sample_rate_hz != 0) sample_rate_hz else remote.sample_rate_hz;
    const source_rate_hz = if (remote.sample_rate_hz != 0) remote.sample_rate_hz else output_rate_hz;
    if (output_rate_hz == 0 or source_rate_hz == 0) return;

    const target_buffer_frames = std.math.clamp(left.len * jitter_target_blocks, left.len, max_remote_buffer_frames / 2);
    const rebuffer_threshold = std.math.clamp(left.len / jitter_rebuffer_divisor, 2, target_buffer_frames);
    const buffered_frames = bufferedFrameCountLocked(remote);
    if (buffered_frames == 0) {
        remote.startup_buffering = true;
        remote.read_position_frames = 0.0;
        return;
    }

    if (remote.startup_buffering) {
        if (buffered_frames < target_buffer_frames) return;
        remote.startup_buffering = false;
    } else if (buffered_frames < rebuffer_threshold) {
        remote.startup_buffering = true;
        return;
    }

    const base_ratio = @as(f64, @floatFromInt(source_rate_hz)) / @as(f64, @floatFromInt(output_rate_hz));
    const error_frames = @as(f64, @floatFromInt(buffered_frames)) - @as(f64, @floatFromInt(target_buffer_frames));
    const normalized_error = std.math.clamp(error_frames / @as(f64, @floatFromInt(@max(@as(usize, 1), target_buffer_frames))), -1.0, 1.0);
    const playback_ratio = std.math.clamp(
        base_ratio * (1.0 + normalized_error * max_drift_correction_ratio),
        0.5,
        2.0,
    );

    var position = remote.read_position_frames;
    for (left, right) |*left_sample, *right_sample| {
        const stereo = sampleRemoteStereo(remote, position) orelse break;
        left_sample.* = stereo.left;
        right_sample.* = stereo.right;
        position += playback_ratio;
    }

    remote.read_position_frames = position;
}

fn bufferedFrameCountLocked(remote: *const RemoteInputState) usize {
    const channels = @max(@as(usize, 1), remote.channels);
    const total_frames = remote.buffered_samples.items.len / channels;
    const consumed_frames = @min(total_frames, @as(usize, @intFromFloat(@floor(remote.read_position_frames))));
    return total_frames - consumed_frames;
}

fn sampleRemoteStereo(remote: *const RemoteInputState, position_frames: f64) ?MeterLevels {
    const channels = @max(@as(usize, 1), remote.channels);
    const total_frames = remote.buffered_samples.items.len / channels;
    if (total_frames == 0 or position_frames < 0.0) return null;

    const frame_index = @as(usize, @intFromFloat(@floor(position_frames)));
    if (frame_index >= total_frames) return null;
    const next_frame_index = @min(frame_index + 1, total_frames - 1);
    const fraction = @as(f32, @floatCast(position_frames - @floor(position_frames)));

    const left_a = sampleRemoteChannel(remote, frame_index, 0);
    const left_b = sampleRemoteChannel(remote, next_frame_index, 0);
    const right_a = sampleRemoteChannel(remote, frame_index, 1);
    const right_b = sampleRemoteChannel(remote, next_frame_index, 1);
    return .{
        .left = std.math.lerp(left_a, left_b, fraction),
        .right = std.math.lerp(right_a, right_b, fraction),
        .level = 0.0,
    };
}

fn sampleRemoteChannel(remote: *const RemoteInputState, frame_index: usize, channel_index: usize) f32 {
    const channels = @max(@as(usize, 1), remote.channels);
    const base = frame_index * channels;
    const sample_index = base + @min(channel_index, channels - 1);
    if (sample_index >= remote.buffered_samples.items.len) return 0.0;
    if (channel_index > 0 and channels == 1) return remote.buffered_samples.items[base];
    return remote.buffered_samples.items[sample_index];
}

fn zeroOutput(left: []f32, right: []f32) void {
    @memset(left, 0.0);
    @memset(right, 0.0);
}

fn renderWorkerMain(engine: *AudioEngine) void {
    var next_tick_ns = std.time.nanoTimestamp();
    while (!engine.render_stop.load(.acquire)) {
        engine.renderQuantum(render_quantum_frames);
        next_tick_ns += render_quantum_ns;
        const now_ns = std.time.nanoTimestamp();
        if (next_tick_ns > now_ns) {
            std.Thread.sleep(@intCast(next_tick_ns - now_ns));
        } else {
            const late_ns = now_ns - next_tick_ns;
            if (late_ns >= render_late_warn_threshold_ns and
                (engine.last_render_late_warn_ns == 0 or now_ns - engine.last_render_late_warn_ns >= render_late_warn_log_interval_ns))
            {
                engine.last_render_late_warn_ns = now_ns;
                std.log.warn("audio render worker late: late_ns={d} quantum_frames={d}", .{
                    late_ns,
                    render_quantum_frames,
                });
            }
            next_tick_ns = now_ns;
        }
    }
}

fn appendChannelRenderAudioLocked(
    allocator: std.mem.Allocator,
    channel: *ChannelState,
    left: []const f32,
    right: []const f32,
    sample_rate_hz: u32,
) !void {
    if (left.len == 0 or left.len != right.len) return;

    if (sample_rate_hz == 0 or sample_rate_hz == render_sample_rate_hz) {
        const base_len = channel.render_buffer.items.len;
        try channel.render_buffer.resize(allocator, base_len + left.len * 2);
        for (left, right, 0..) |left_sample, right_sample, frame_index| {
            const base = base_len + frame_index * 2;
            channel.render_buffer.items[base] = left_sample;
            channel.render_buffer.items[base + 1] = right_sample;
        }
        return;
    }

    const output_frames = @max(@as(usize, 1), @as(usize, @intFromFloat(@ceil(
        @as(f64, @floatFromInt(left.len)) * @as(f64, @floatFromInt(render_sample_rate_hz)) / @as(f64, @floatFromInt(sample_rate_hz)),
    ))));
    const base_len = channel.render_buffer.items.len;
    try channel.render_buffer.resize(allocator, base_len + output_frames * 2);

    const rate_ratio = @as(f64, @floatFromInt(sample_rate_hz)) / @as(f64, @floatFromInt(render_sample_rate_hz));
    for (0..output_frames) |frame_index| {
        const source_position = @as(f64, @floatFromInt(frame_index)) * rate_ratio;
        const source_index = @min(@as(usize, @intFromFloat(@floor(source_position))), left.len - 1);
        const next_source_index = @min(source_index + 1, left.len - 1);
        const fraction = @as(f32, @floatCast(source_position - @floor(source_position)));
        const base = base_len + frame_index * 2;
        channel.render_buffer.items[base] = std.math.lerp(left[source_index], left[next_source_index], fraction);
        channel.render_buffer.items[base + 1] = std.math.lerp(right[source_index], right[next_source_index], fraction);
    }
}

fn renderBusQuantumLocked(self: *AudioEngine, frame_count: usize) void {
    if (frame_count == 0) return;

    const sample_count = frame_count * 2;
    self.render_generation += 1;

    for (self.buses.items) |*bus| {
        if (prepareBusTapMixLocked(self, bus, frame_count, render_sample_rate_hz, 0)) |_| {} else |_| {
            bus.metrics = .{};
            continue;
        }
        @memset(bus.tap_mix_buffer.items, 0.0);
    }

    for (self.sends.items) |send| {
        if (!send.enabled) continue;

        const channel = findChannelStatePtr(self.channels.items, send.channel_id) orelse continue;
        const bus = findBusStatePtr(self.buses.items, send.bus_id) orelse continue;
        if (bus.muted or bus.system_muted) continue;
        if (channel.muted) continue;

        const gain = if (send.pre_fader)
            std.math.clamp(send.gain * bus.volume * bus.system_volume, 0.0, 4.0)
        else
            std.math.clamp(send.gain * bus.volume * bus.system_volume * channel.volume, 0.0, 4.0);
        if (gain <= 0.00001) continue;

        for (0..frame_count) |frame_index| {
            const source_base = channel.render_read_sample_index + frame_index * 2;
            const left_sample = if (source_base < channel.render_buffer.items.len) channel.render_buffer.items[source_base] else 0.0;
            const right_sample = if (source_base + 1 < channel.render_buffer.items.len) channel.render_buffer.items[source_base + 1] else left_sample;
            const bus_base = frame_index * 2;
            bus.tap_mix_buffer.items[bus_base] += std.math.clamp(left_sample * gain, -1.0, 1.0);
            bus.tap_mix_buffer.items[bus_base + 1] += std.math.clamp(right_sample * gain, -1.0, 1.0);
        }
    }

    for (self.buses.items) |*bus| {
        bus.tap_sample_rate_hz = render_sample_rate_hz;
        const mix_levels = measureInterleavedLevels(bus.tap_mix_buffer.items);
        bus.metrics = .{
            .mix = mix_levels,
            .contributor_count = countBusContributorsLocked(self, bus.id),
            .generation = self.render_generation,
        };
        if (bus.tap_consumers.items.len == 0) {
            bus.tap_stream_buffer.clearRetainingCapacity();
            continue;
        }
        bus.tap_stream_buffer.appendSlice(self.allocator, bus.tap_mix_buffer.items) catch {};
        compactBusTapStreamLocked(self.allocator, bus);
    }

    for (self.channels.items) |*channel| {
        channel.render_read_sample_index += sample_count;
        compactChannelRenderBufferLocked(channel);
    }
}

fn prepareBusTapMixLocked(
    self: *AudioEngine,
    bus: *BusState,
    frame_count: usize,
    sample_rate_hz: u32,
    cycle_token: u64,
) !void {
    const sample_count = frame_count * 2;
    if (bus.tap_cycle_token != cycle_token or bus.tap_mix_buffer.items.len != sample_count) {
        try bus.tap_mix_buffer.resize(self.allocator, sample_count);
        bus.tap_cycle_token = cycle_token;
    }
    if (sample_rate_hz != 0) bus.tap_sample_rate_hz = sample_rate_hz;
}

fn compactChannelRenderBufferLocked(channel: *ChannelState) void {
    if (channel.render_read_sample_index == 0) return;
    if (channel.render_read_sample_index >= channel.render_buffer.items.len) {
        channel.render_buffer.clearRetainingCapacity();
        channel.render_read_sample_index = 0;
        return;
    }

    const remaining = channel.render_buffer.items.len - channel.render_read_sample_index;
    std.mem.copyForwards(
        f32,
        channel.render_buffer.items[0..remaining],
        channel.render_buffer.items[channel.render_read_sample_index..][0..remaining],
    );
    channel.render_buffer.items.len = remaining;
    channel.render_read_sample_index = 0;
}

fn ensureBusTapConsumerLocked(
    allocator: std.mem.Allocator,
    bus: *BusState,
    consumer_id: []const u8,
) !*BusTapConsumer {
    for (bus.tap_consumers.items) |*consumer| {
        if (std.mem.eql(u8, consumer.id, consumer_id)) return consumer;
    }

    try bus.tap_consumers.append(allocator, .{
        .id = try allocator.dupe(u8, consumer_id),
        .read_sample_index = 0,
    });
    return &bus.tap_consumers.items[bus.tap_consumers.items.len - 1];
}

fn releaseBusTapConsumerLocked(
    allocator: std.mem.Allocator,
    bus: *BusState,
    consumer_id: []const u8,
) void {
    for (bus.tap_consumers.items, 0..) |consumer, index| {
        if (!std.mem.eql(u8, consumer.id, consumer_id)) continue;
        var removed = bus.tap_consumers.orderedRemove(index);
        removed.deinit(allocator);
        return;
    }
}

fn compactBusTapStreamLocked(allocator: std.mem.Allocator, bus: *BusState) void {
    if (bus.tap_consumers.items.len == 0) {
        bus.tap_stream_buffer.clearRetainingCapacity();
        return;
    }

    var min_read_sample_index = bus.tap_consumers.items[0].read_sample_index;
    for (bus.tap_consumers.items[1..]) |consumer| {
        min_read_sample_index = @min(min_read_sample_index, consumer.read_sample_index);
    }
    if (min_read_sample_index == 0) return;

    const remaining = bus.tap_stream_buffer.items.len - @min(min_read_sample_index, bus.tap_stream_buffer.items.len);
    if (remaining > 0) {
        std.mem.copyForwards(
            f32,
            bus.tap_stream_buffer.items[0..remaining],
            bus.tap_stream_buffer.items[min_read_sample_index..][0..remaining],
        );
    }
    bus.tap_stream_buffer.items.len = remaining;
    for (bus.tap_consumers.items) |*consumer| {
        consumer.read_sample_index -= @min(consumer.read_sample_index, min_read_sample_index);
    }

    if (bus.tap_stream_buffer.items.len == 0) {
        bus.tap_stream_buffer.clearRetainingCapacity();
    } else {
        _ = allocator;
    }
}

fn countBusContributorsLocked(self: *const AudioEngine, bus_id: []const u8) u32 {
    var contributors: u32 = 0;
    for (self.sends.items) |send| {
        if (!send.enabled) continue;
        if (!std.mem.eql(u8, send.bus_id, bus_id)) continue;

        const channel = findChannelState(self.channels.items, send.channel_id) orelse continue;
        if (channel.muted) continue;
        const gain = if (send.pre_fader)
            std.math.clamp(send.gain, 0.0, 4.0)
        else
            std.math.clamp(send.gain * channel.volume, 0.0, 4.0);
        if (gain <= 0.00001) continue;
        contributors += 1;
    }
    return contributors;
}

test "syncGraph preserves unread bus tap data across graph changes" {
    const allocator = std.testing.allocator;

    var engine = AudioEngine.init(allocator);
    defer engine.deinit();

    var runtime = FxRuntime.init(allocator);
    defer runtime.deinit();

    const channels = [_]channels_mod.Channel{
        .{ .id = "channel-1", .label = "Channel 1", .subtitle = "test" },
    };
    const buses = [_]buses_mod.Bus{
        .{ .id = "bus-1", .label = "Bus 1" },
    };
    const sends = [_]sends_mod.Send{
        .{ .channel_id = "channel-1", .bus_id = "bus-1" },
    };

    try engine.syncGraph(&channels, &buses, &sends);

    var left = [_]f32{ 0.25, 0.25, 0.25, 0.25 };
    var right = [_]f32{ 0.5, 0.5, 0.5, 0.5 };
    try std.testing.expect(engine.processChannel(&runtime, "channel-1", &left, &right, 48_000, 64));
    try std.testing.expect(engine.processChannel(&runtime, "channel-1", &left, &right, 48_000, 68));

    var first_read: [4]i16 = undefined;
    const first = engine.readBusPcmS16ForConsumer("bus-1", "consumer-1", &first_read);
    try std.testing.expectEqual(@as(usize, 2), first.frames);

    const changed_channels = [_]channels_mod.Channel{
        .{ .id = "channel-1", .label = "Channel 1", .subtitle = "test", .volume = 0.8 },
    };
    try engine.syncGraph(&changed_channels, &buses, &sends);

    var second_read: [4]i16 = undefined;
    const second = engine.readBusPcmS16ForConsumer("bus-1", "consumer-1", &second_read);
    try std.testing.expectEqual(@as(usize, 2), second.frames);
}

test "internal render mixes multiple channels on a bus independently of callback cycle" {
    const allocator = std.testing.allocator;

    var engine = AudioEngine.init(allocator);
    defer engine.deinit();

    var runtime = FxRuntime.init(allocator);
    defer runtime.deinit();

    const channels = [_]channels_mod.Channel{
        .{ .id = "channel-1", .label = "Channel 1", .subtitle = "test" },
        .{ .id = "channel-2", .label = "Channel 2", .subtitle = "test" },
    };
    const buses = [_]buses_mod.Bus{
        .{ .id = "bus-1", .label = "Bus 1" },
    };
    const sends = [_]sends_mod.Send{
        .{ .channel_id = "channel-1", .bus_id = "bus-1" },
        .{ .channel_id = "channel-2", .bus_id = "bus-1" },
    };

    try engine.syncGraph(&channels, &buses, &sends);

    var left_a = [_]f32{ 0.1, 0.1, 0.1, 0.1 };
    var right_a = [_]f32{ 0.1, 0.1, 0.1, 0.1 };
    var left_b = [_]f32{ 0.2, 0.2, 0.2, 0.2 };
    var right_b = [_]f32{ 0.2, 0.2, 0.2, 0.2 };
    try std.testing.expect(engine.processChannel(&runtime, "channel-1", &left_a, &right_a, render_sample_rate_hz, 64));
    try std.testing.expect(engine.processChannel(&runtime, "channel-2", &left_b, &right_b, render_sample_rate_hz, 1024));

    engine.renderQuantum(4);

    var mixed: [8]i16 = undefined;
    const read = engine.readBusPcmS16ForConsumer("bus-1", "consumer-1", &mixed);
    try std.testing.expectEqual(@as(usize, 4), read.frames);
    try std.testing.expect(mixed[0] > 9000);
    try std.testing.expect(mixed[1] > 9000);
}

test "muted channel is excluded from bus mix even for pre-fader sends" {
    const allocator = std.testing.allocator;

    var engine = AudioEngine.init(allocator);
    defer engine.deinit();

    var runtime = FxRuntime.init(allocator);
    defer runtime.deinit();

    const channels = [_]channels_mod.Channel{
        .{ .id = "channel-1", .label = "Channel 1", .subtitle = "test", .muted = true },
    };
    const buses = [_]buses_mod.Bus{
        .{ .id = "bus-1", .label = "Bus 1" },
    };
    const sends = [_]sends_mod.Send{
        .{ .channel_id = "channel-1", .bus_id = "bus-1", .pre_fader = true },
    };

    try engine.syncGraph(&channels, &buses, &sends);

    var left = [_]f32{ 0.5, 0.5, 0.5, 0.5 };
    var right = [_]f32{ 0.5, 0.5, 0.5, 0.5 };
    try std.testing.expect(engine.processChannel(&runtime, "channel-1", &left, &right, render_sample_rate_hz, 64));

    engine.renderQuantum(4);

    var mixed: [8]i16 = undefined;
    const read = engine.readBusPcmS16ForConsumer("bus-1", "consumer-1", &mixed);
    try std.testing.expectEqual(@as(usize, 4), read.frames);
    for (mixed) |sample| try std.testing.expectEqual(@as(i16, 0), sample);
}
