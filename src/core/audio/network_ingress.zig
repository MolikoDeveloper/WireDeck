const std = @import("std");
const AudioEngine = @import("engine.zig").AudioEngine;
const sources_mod = @import("sources.zig");
const network_mod = @import("network.zig");

const max_packet_bytes: usize = 64 * 1024;

pub const NetworkAudioService = struct {
    pub const ServiceState = enum {
        stopped,
        configured,
        accepting,
    };

    pub const PlannedSessionStatus = enum {
        planned,
        waiting_for_client,
        active,
        stale,
    };

    pub const PlannedSessionSpec = struct {
        channel_id: []const u8,
        client_name: []const u8,
        stream_name: []const u8,
        platform: network_mod.ClientPlatform,
        requested_channels: u8 = 2,
    };

    pub const PlannedSession = struct {
        id: []u8,
        channel_id: []u8,
        client_name: []u8,
        stream_name: []u8,
        platform: network_mod.ClientPlatform,
        transport: network_mod.TransportKind,
        codec: network_mod.CodecKind,
        sample_rate_hz: u32,
        channels: u8,
        frames_per_packet: u16,
        expected_device: network_mod.VirtualDeviceKind,
        status: PlannedSessionStatus = .planned,
        latency_budget_ms: u16 = 8,

        fn deinit(self: *PlannedSession, allocator: std.mem.Allocator) void {
            allocator.free(self.id);
            allocator.free(self.channel_id);
            allocator.free(self.client_name);
            allocator.free(self.stream_name);
        }
    };

    const RemoteSource = struct {
        id: []u8,
        client_id: []u8,
        client_name: []u8,
        stream_name: []u8,
        address_text: []u8,
        platform: network_mod.ClientPlatform,
        capture_mode: network_mod.CaptureMode,
        codec: network_mod.CodecKind,
        sample_rate_hz: u32,
        channels: u8,
        level_left: f32 = 0.0,
        level_right: f32 = 0.0,
        level: f32 = 0.0,
        last_seen_ns: i128 = 0,
        packet_count: u64 = 0,

        fn deinit(self: *RemoteSource, allocator: std.mem.Allocator) void {
            allocator.free(self.id);
            allocator.free(self.client_id);
            allocator.free(self.client_name);
            allocator.free(self.stream_name);
            allocator.free(self.address_text);
        }
    };

    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    settings: network_mod.NetworkAudioSettings = .{},
    state: ServiceState = .stopped,
    sessions: std.ArrayList(PlannedSession),
    remote_sources: std.ArrayList(RemoteSource),
    engine: ?*AudioEngine = null,
    listener_thread: ?std.Thread = null,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(allocator: std.mem.Allocator) NetworkAudioService {
        return .{
            .allocator = allocator,
            .sessions = .empty,
            .remote_sources = .empty,
        };
    }

    pub fn deinit(self: *NetworkAudioService) void {
        self.stop();
        self.clearSessions();
        self.clearRemoteSources();
        self.sessions.deinit(self.allocator);
        self.remote_sources.deinit(self.allocator);
    }

    pub fn configure(self: *NetworkAudioService, settings: network_mod.NetworkAudioSettings) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.settings = settings;
        self.state = if (!settings.enabled)
            .stopped
        else if (self.remote_sources.items.len == 0)
            .configured
        else
            .accepting;
    }

    pub fn attachEngine(self: *NetworkAudioService, engine: *AudioEngine) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.engine = engine;
    }

    pub fn start(self: *NetworkAudioService) void {
        self.mutex.lock();
        if (!self.settings.enabled or self.listener_thread != null) {
            self.state = if (self.settings.enabled) .configured else .stopped;
            self.mutex.unlock();
            return;
        }
        self.stop_requested.store(false, .release);
        self.state = .accepting;
        self.mutex.unlock();

        self.listener_thread = std.Thread.spawn(.{}, listenerMain, .{self}) catch {
            self.mutex.lock();
            self.state = .configured;
            self.mutex.unlock();
            return;
        };
    }

    pub fn stop(self: *NetworkAudioService) void {
        self.stop_requested.store(true, .release);
        wakeListener(self.snapshotSettings()) catch {};
        if (self.listener_thread) |thread| {
            thread.join();
            self.listener_thread = null;
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        self.state = .stopped;
        for (self.sessions.items) |*session| {
            if (session.status == .active) session.status = .stale;
        }
    }

    pub fn registerPlannedSession(self: *NetworkAudioService, spec: PlannedSessionSpec) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.sessions.items) |*session| {
            if (!std.mem.eql(u8, session.channel_id, spec.channel_id)) continue;
            if (!std.mem.eql(u8, session.client_name, spec.client_name)) continue;
            session.stream_name = try replaceOwnedString(self.allocator, session.stream_name, spec.stream_name);
            session.platform = spec.platform;
            session.transport = self.settings.transport;
            session.codec = self.settings.codec;
            session.sample_rate_hz = self.settings.sample_rate_hz;
            session.channels = @max(@as(u8, 1), spec.requested_channels);
            session.frames_per_packet = self.settings.frames_per_packet;
            session.expected_device = network_mod.recommendedCapturePlan(spec.platform).virtual_device;
            session.status = .waiting_for_client;
            self.state = .accepting;
            return;
        }

        const plan = network_mod.recommendedCapturePlan(spec.platform);
        const session_id = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{
            spec.channel_id,
            spec.client_name,
        });
        errdefer self.allocator.free(session_id);

        try self.sessions.append(self.allocator, .{
            .id = session_id,
            .channel_id = try self.allocator.dupe(u8, spec.channel_id),
            .client_name = try self.allocator.dupe(u8, spec.client_name),
            .stream_name = try self.allocator.dupe(u8, spec.stream_name),
            .platform = spec.platform,
            .transport = self.settings.transport,
            .codec = self.settings.codec,
            .sample_rate_hz = self.settings.sample_rate_hz,
            .channels = @max(@as(u8, 1), spec.requested_channels),
            .frames_per_packet = self.settings.frames_per_packet,
            .expected_device = plan.virtual_device,
            .status = .waiting_for_client,
        });
        self.state = .accepting;
    }

    pub fn snapshotSettings(self: *NetworkAudioService) network_mod.NetworkAudioSettings {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.settings;
    }

    pub fn describeEndpoint(self: *NetworkAudioService, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        return std.fmt.allocPrint(allocator, "{s}://0.0.0.0:{d}/{s}/{d}hz/{d}f", .{
            network_mod.transportLabel(self.settings.transport),
            self.settings.bind_port,
            network_mod.codecLabel(self.settings.codec),
            self.settings.sample_rate_hz,
            self.settings.frames_per_packet,
        });
    }

    pub fn clientPlan(self: *NetworkAudioService, platform: network_mod.ClientPlatform) network_mod.ClientCapturePlan {
        _ = self;
        return network_mod.recommendedCapturePlan(platform);
    }

    pub fn appendSnapshotSources(self: *NetworkAudioService, allocator: std.mem.Allocator, out: *std.ArrayList(sources_mod.Source)) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const stale_before_ns = std.time.nanoTimestamp() - 5 * std.time.ns_per_s;
        for (self.remote_sources.items) |source| {
            if (source.last_seen_ns < stale_before_ns) continue;
            const subtitle = try std.fmt.allocPrint(allocator, "{s} / {s} / {s}", .{
                @tagName(source.platform),
                source.client_name,
                source.address_text,
            });
            errdefer allocator.free(subtitle);

            try out.append(allocator, .{
                .id = try allocator.dupe(u8, source.id),
                .label = try allocator.dupe(u8, source.stream_name),
                .subtitle = subtitle,
                .kind = .virtual,
                .process_binary = try allocator.dupe(u8, "wiredeck-client"),
                .icon_name = try allocator.dupe(u8, "world"),
                .icon_path = try allocator.dupe(u8, ""),
                .level_left = source.level_left,
                .level_right = source.level_right,
                .level = source.level,
                .muted = false,
            });
        }
    }

    pub fn applyToSources(self: *NetworkAudioService, sources: []sources_mod.Source) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const stale_before_ns = std.time.nanoTimestamp() - 5 * std.time.ns_per_s;
        for (self.remote_sources.items) |source| {
            if (source.last_seen_ns < stale_before_ns) continue;
            for (sources) |*item| {
                if (!std.mem.eql(u8, item.id, source.id)) continue;
                item.level_left = source.level_left;
                item.level_right = source.level_right;
                item.level = source.level;
                item.muted = false;
                break;
            }
        }
    }

    fn clearSessions(self: *NetworkAudioService) void {
        for (self.sessions.items) |*session| session.deinit(self.allocator);
        self.sessions.clearRetainingCapacity();
    }

    fn clearRemoteSources(self: *NetworkAudioService) void {
        for (self.remote_sources.items) |*source| {
            if (self.engine) |engine| engine.deactivateRemoteSource(source.id);
            source.deinit(self.allocator);
        }
        self.remote_sources.clearRetainingCapacity();
    }
};

fn listenerMain(service: *NetworkAudioService) void {
    const settings = service.snapshotSettings();
    if (!settings.enabled or settings.transport != .udp) return;

    const sock = openUdpSocket(settings.bind_port) catch return;
    defer std.posix.close(sock);

    var fds = [_]std.posix.pollfd{.{
        .fd = sock,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    var recv_buffer: [max_packet_bytes]u8 = undefined;

    while (!service.stop_requested.load(.acquire)) {
        _ = std.posix.poll(&fds, 200) catch continue;
        if ((fds[0].revents & std.posix.POLL.IN) == 0) continue;

        var source_addr: std.posix.sockaddr = undefined;
        var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
        const bytes_read = std.posix.recvfrom(sock, &recv_buffer, 0, &source_addr, &addr_len) catch continue;
        if (bytes_read < @sizeOf(network_mod.PacketHeader)) continue;

        const header = std.mem.bytesToValue(network_mod.PacketHeader, recv_buffer[0..@sizeOf(network_mod.PacketHeader)]);
        switch (header.kind) {
            .hello => handleHelloPacket(service, header, recv_buffer[@sizeOf(network_mod.PacketHeader)..bytes_read], source_addr),
            .audio => handleAudioPacket(service, header, recv_buffer[@sizeOf(network_mod.PacketHeader)..bytes_read], source_addr),
            .keepalive => handleKeepalivePacket(service, header, source_addr),
            .goodbye => handleGoodbyePacket(service, header),
        }
    }
}

fn openUdpSocket(port: u16) !std.posix.socket_t {
    const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
    errdefer std.posix.close(sock);

    try std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&@as(c_int, 1)));
    const address = std.net.Address.parseIp("0.0.0.0", port) catch return error.InvalidIPAddressFormat;
    try std.posix.bind(sock, &address.any, address.getOsSockLen());
    return sock;
}

fn handleHelloPacket(
    service: *NetworkAudioService,
    header: network_mod.PacketHeader,
    payload: []const u8,
    source_addr: std.posix.sockaddr,
) void {
    if (payload.len < @sizeOf(network_mod.HelloPayload)) return;
    const hello = std.mem.bytesToValue(network_mod.HelloPayload, payload[0..@sizeOf(network_mod.HelloPayload)]);

    service.mutex.lock();
    defer service.mutex.unlock();

    const client_id = network_mod.readStringField(hello.client_id);
    const stream_name = network_mod.readStringField(hello.stream_name);
    const client_name = network_mod.readStringField(hello.client_name);
    const source_id = buildRemoteSourceId(service.allocator, client_id, header.stream_id) catch return;
    defer service.allocator.free(source_id);
    const address_text = formatSourceAddress(service.allocator, source_addr) catch return;
    defer service.allocator.free(address_text);

    if (findRemoteSource(service.remote_sources.items, source_id)) |remote| {
        remote.client_name = replaceOwnedString(service.allocator, remote.client_name, client_name) catch remote.client_name;
        remote.stream_name = replaceOwnedString(service.allocator, remote.stream_name, stream_name) catch remote.stream_name;
        remote.address_text = replaceOwnedString(service.allocator, remote.address_text, address_text) catch remote.address_text;
        remote.platform = hello.platform;
        remote.capture_mode = hello.capture_mode;
        remote.codec = header.codec;
        remote.channels = header.channels;
        remote.sample_rate_hz = header.sample_rate_hz;
        remote.last_seen_ns = std.time.nanoTimestamp();
    } else {
        service.remote_sources.append(service.allocator, .{
            .id = service.allocator.dupe(u8, source_id) catch return,
            .client_id = service.allocator.dupe(u8, client_id) catch return,
            .client_name = service.allocator.dupe(u8, if (client_name.len == 0) "WireDeck Client" else client_name) catch return,
            .stream_name = service.allocator.dupe(u8, if (stream_name.len == 0) "Remote Stream" else stream_name) catch return,
            .address_text = service.allocator.dupe(u8, address_text) catch return,
            .platform = hello.platform,
            .capture_mode = hello.capture_mode,
            .codec = header.codec,
            .sample_rate_hz = header.sample_rate_hz,
            .channels = @max(@as(u8, 1), header.channels),
            .last_seen_ns = std.time.nanoTimestamp(),
        }) catch return;
    }

    markMatchingSessionActive(service.sessions.items, client_name, stream_name);
}

fn handleAudioPacket(
    service: *NetworkAudioService,
    header: network_mod.PacketHeader,
    payload: []const u8,
    source_addr: std.posix.sockaddr,
) void {
    const channels = @max(@as(u8, 1), header.channels);
    const expected_bytes = switch (header.codec) {
        .pcm_float32 => @as(usize, header.frames) * channels * @sizeOf(f32),
        .pcm_s16le => @as(usize, header.frames) * channels * @sizeOf(i16),
        .opus_lowdelay => payload.len,
    };
    if (header.codec != .opus_lowdelay and payload.len < expected_bytes) return;

    service.mutex.lock();
    defer service.mutex.unlock();

    const source_id = buildRemoteSourceId(service.allocator, "", header.stream_id) catch return;
    defer service.allocator.free(source_id);
    const remote = findRemoteSourceByStreamId(service.remote_sources.items, header.stream_id) orelse blk: {
        const address_text = formatSourceAddress(service.allocator, source_addr) catch break :blk null;
        defer service.allocator.free(address_text);

        service.remote_sources.append(service.allocator, .{
            .id = service.allocator.dupe(u8, source_id) catch break :blk null,
            .client_id = service.allocator.dupe(u8, "") catch break :blk null,
            .client_name = service.allocator.dupe(u8, "WireDeck Client") catch break :blk null,
            .stream_name = service.allocator.dupe(u8, "Remote Stream") catch break :blk null,
            .address_text = service.allocator.dupe(u8, address_text) catch break :blk null,
            .platform = .linux,
            .capture_mode = .tone,
            .codec = header.codec,
            .sample_rate_hz = header.sample_rate_hz,
            .channels = channels,
            .last_seen_ns = std.time.nanoTimestamp(),
        }) catch break :blk null;
        break :blk &service.remote_sources.items[service.remote_sources.items.len - 1];
    } orelse return;

    const levels = switch (header.codec) {
        .pcm_float32 => measureFloatPayload(payload[0..expected_bytes], channels),
        .pcm_s16le => measureS16Payload(payload[0..expected_bytes], channels),
        .opus_lowdelay => remoteLevelFallback(remote),
    };
    remote.codec = header.codec;
    remote.sample_rate_hz = header.sample_rate_hz;
    remote.channels = channels;
    remote.level_left = levels.level_left;
    remote.level_right = levels.level_right;
    remote.level = levels.level;
    remote.last_seen_ns = std.time.nanoTimestamp();
    remote.packet_count += 1;

    if (service.engine) |engine| switch (header.codec) {
        .pcm_float32 => {
            const samples = std.mem.bytesAsSlice(f32, payload[0..expected_bytes]);
            engine.ingestRemoteFloat32(remote.id, channels, header.sample_rate_hz, samples) catch {};
        },
        .pcm_s16le => {
            const samples = std.mem.bytesAsSlice(i16, payload[0..expected_bytes]);
            engine.ingestRemoteS16(remote.id, channels, header.sample_rate_hz, samples) catch {};
        },
        .opus_lowdelay => {},
    };
}

fn handleKeepalivePacket(service: *NetworkAudioService, header: network_mod.PacketHeader, source_addr: std.posix.sockaddr) void {
    service.mutex.lock();
    defer service.mutex.unlock();

    const remote = findRemoteSourceByStreamId(service.remote_sources.items, header.stream_id) orelse return;
    const address_text = formatSourceAddress(service.allocator, source_addr) catch return;
    defer service.allocator.free(address_text);
    remote.address_text = replaceOwnedString(service.allocator, remote.address_text, address_text) catch remote.address_text;
    remote.last_seen_ns = std.time.nanoTimestamp();
}

fn handleGoodbyePacket(service: *NetworkAudioService, header: network_mod.PacketHeader) void {
    service.mutex.lock();
    defer service.mutex.unlock();

    const remote = findRemoteSourceByStreamId(service.remote_sources.items, header.stream_id) orelse return;
    remote.last_seen_ns = 0;
    remote.level_left = 0.0;
    remote.level_right = 0.0;
    remote.level = 0.0;
    if (service.engine) |engine| engine.deactivateRemoteSource(remote.id);
}

fn measureFloatPayload(payload: []const u8, channels: u8) sources_mod.Source {
    const samples = std.mem.bytesAsSlice(f32, payload);
    var left_peak: f32 = 0.0;
    var right_peak: f32 = 0.0;
    if (channels <= 1) {
        for (samples) |sample| left_peak = @max(left_peak, @abs(sample));
        right_peak = left_peak;
    } else {
        var index: usize = 0;
        while (index + 1 < samples.len) : (index += channels) {
            left_peak = @max(left_peak, @abs(samples[index]));
            right_peak = @max(right_peak, @abs(samples[index + 1]));
        }
    }
    return .{
        .id = "",
        .label = "",
        .subtitle = "",
        .level_left = std.math.clamp(left_peak, 0.0, 1.0),
        .level_right = std.math.clamp(right_peak, 0.0, 1.0),
        .level = std.math.clamp(@max(left_peak, right_peak), 0.0, 1.0),
    };
}

fn measureS16Payload(payload: []const u8, channels: u8) sources_mod.Source {
    const samples = std.mem.bytesAsSlice(i16, payload);
    var left_peak: f32 = 0.0;
    var right_peak: f32 = 0.0;
    if (channels <= 1) {
        for (samples) |sample| left_peak = @max(left_peak, @as(f32, @floatFromInt(@abs(sample))) / 32768.0);
        right_peak = left_peak;
    } else {
        var index: usize = 0;
        while (index + 1 < samples.len) : (index += channels) {
            left_peak = @max(left_peak, @as(f32, @floatFromInt(@abs(samples[index]))) / 32768.0);
            right_peak = @max(right_peak, @as(f32, @floatFromInt(@abs(samples[index + 1]))) / 32768.0);
        }
    }
    return .{
        .id = "",
        .label = "",
        .subtitle = "",
        .level_left = std.math.clamp(left_peak, 0.0, 1.0),
        .level_right = std.math.clamp(right_peak, 0.0, 1.0),
        .level = std.math.clamp(@max(left_peak, right_peak), 0.0, 1.0),
    };
}

fn remoteLevelFallback(remote: *NetworkAudioService.RemoteSource) sources_mod.Source {
    return .{
        .id = "",
        .label = "",
        .subtitle = "",
        .level_left = remote.level_left,
        .level_right = remote.level_right,
        .level = remote.level,
    };
}

fn buildRemoteSourceId(allocator: std.mem.Allocator, client_id: []const u8, stream_id: u32) ![]u8 {
    if (client_id.len > 0) {
        return std.fmt.allocPrint(allocator, "wdnet-{s}-{d}", .{ sanitizeId(client_id), stream_id });
    }
    return std.fmt.allocPrint(allocator, "wdnet-stream-{d}", .{stream_id});
}

fn findRemoteSource(items: []NetworkAudioService.RemoteSource, id: []const u8) ?*NetworkAudioService.RemoteSource {
    for (items) |*item| {
        if (std.mem.eql(u8, item.id, id)) return item;
    }
    return null;
}

fn findRemoteSourceByStreamId(items: []NetworkAudioService.RemoteSource, stream_id: u32) ?*NetworkAudioService.RemoteSource {
    for (items) |*item| {
        if (parseStreamId(item.id) == stream_id) return item;
    }
    return null;
}

fn parseStreamId(id: []const u8) u32 {
    if (std.mem.lastIndexOfScalar(u8, id, '-')) |index| {
        return std.fmt.parseInt(u32, id[index + 1 ..], 10) catch 0;
    }
    return 0;
}

fn sanitizeId(input: []const u8) []const u8 {
    return input;
}

fn formatSourceAddress(allocator: std.mem.Allocator, source_addr: std.posix.sockaddr) ![]u8 {
    const address = std.net.Address.initPosix(@alignCast(&source_addr));
    return std.fmt.allocPrint(allocator, "{f}", .{address});
}

fn replaceOwnedString(allocator: std.mem.Allocator, old_value: []u8, new_value: []const u8) ![]u8 {
    const replacement = try allocator.dupe(u8, new_value);
    allocator.free(old_value);
    return replacement;
}

fn markMatchingSessionActive(sessions: []NetworkAudioService.PlannedSession, client_name: []const u8, stream_name: []const u8) void {
    for (sessions) |*session| {
        if (client_name.len > 0 and !std.ascii.eqlIgnoreCase(session.client_name, client_name)) continue;
        if (stream_name.len > 0 and !std.ascii.eqlIgnoreCase(session.stream_name, stream_name)) continue;
        session.status = .active;
    }
}

fn wakeListener(settings: network_mod.NetworkAudioSettings) !void {
    if (!settings.enabled or settings.transport != .udp) return;
    const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
    defer std.posix.close(sock);
    const address = try std.net.Address.parseIp("127.0.0.1", settings.bind_port);
    var header = network_mod.PacketHeader{
        .kind = .keepalive,
        .codec = settings.codec,
        .channels = settings.channels,
        .sample_rate_hz = settings.sample_rate_hz,
        .frames = 0,
    };
    _ = try std.posix.sendto(sock, std.mem.asBytes(&header), 0, &address.any, address.getOsSockLen());
}
