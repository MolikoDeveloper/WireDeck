const std = @import("std");
const StateStore = @import("../../app/state_store.zig").StateStore;
const AudioEngine = @import("engine.zig").AudioEngine;
const buses_mod = @import("buses.zig");
const bus_buffer_mod = @import("bus_consumer_buffer.zig");
const protocol = @import("obs_output_protocol.zig");

const proto = protocol.c;
const session_timeout_ns: i128 = 3 * std.time.ns_per_s;
const worker_poll_timeout_ms: i32 = 1;
const packet_frames: usize = proto.WD_OBS_DEFAULT_FRAMES_PER_PACKET;
const packet_channels: usize = proto.WD_OBS_DEFAULT_CHANNELS;
const packet_samples: usize = packet_frames * packet_channels;
const max_packet_bytes: usize = protocol.wire_audio_header_size +
    packet_frames *
        packet_channels *
        @sizeOf(i16);

const DiscoverableOutput = struct {
    id: []u8,
    label: []u8,

    fn deinit(self: *DiscoverableOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.label);
    }
};

const Session = struct {
    stream_id: u32,
    client_name: []u8,
    bus_id: []u8,
    bus_label: []u8,
    consumer_id: []u8,
    endpoint: std.net.Address,
    endpoint_text: []u8,
    sequence: u32 = 0,
    last_seen_ns: i128 = 0,
    pcm_buffer: bus_buffer_mod.BusConsumerBuffer,
    buffering: bool = true,
    next_send_time_ns: u64 = 0,

    fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        allocator.free(self.client_name);
        allocator.free(self.bus_id);
        allocator.free(self.bus_label);
        allocator.free(self.consumer_id);
        allocator.free(self.endpoint_text);
        self.pcm_buffer.deinit();
    }
};

pub const ObsOutputService = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    worker_thread: ?std.Thread = null,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    engine: ?*AudioEngine = null,
    outputs: std.ArrayList(DiscoverableOutput),
    sessions: std.ArrayList(Session),
    next_stream_id: u32 = 1,

    pub fn init(allocator: std.mem.Allocator) ObsOutputService {
        return .{
            .allocator = allocator,
            .outputs = .empty,
            .sessions = .empty,
        };
    }

    pub fn deinit(self: *ObsOutputService) void {
        self.stop();

        self.mutex.lock();
        defer self.mutex.unlock();
        self.clearSessionsLocked();
        self.clearOutputsLocked();
        self.sessions.deinit(self.allocator);
        self.outputs.deinit(self.allocator);
    }

    pub fn attachEngine(self: *ObsOutputService, engine: *AudioEngine) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.engine = engine;
    }

    pub fn start(self: *ObsOutputService) !void {
        self.mutex.lock();
        if (self.worker_thread != null) {
            self.mutex.unlock();
            return;
        }
        self.stop_requested.store(false, .release);
        self.mutex.unlock();

        self.worker_thread = try std.Thread.spawn(.{}, workerMain, .{self});
    }

    pub fn stop(self: *ObsOutputService) void {
        self.stop_requested.store(true, .release);
        wakeWorker() catch {};
        if (self.worker_thread) |thread| {
            thread.join();
            self.worker_thread = null;
        }
    }

    pub fn syncOutputs(self: *ObsOutputService, state_store: *const StateStore) !void {
        var next_outputs = std.ArrayList(DiscoverableOutput).empty;
        errdefer {
            for (next_outputs.items) |*item| item.deinit(self.allocator);
            next_outputs.deinit(self.allocator);
        }

        for (state_store.buses.items) |bus| {
            if (!busEligibleForObs(bus)) continue;
            try next_outputs.append(self.allocator, .{
                .id = try self.allocator.dupe(u8, bus.id),
                .label = try self.allocator.dupe(u8, bus.label),
            });
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        self.clearOutputsLocked();
        self.outputs.deinit(self.allocator);
        self.outputs = next_outputs;
        try self.pruneUnavailableSessionsLocked();
    }

    fn clearOutputsLocked(self: *ObsOutputService) void {
        for (self.outputs.items) |*item| item.deinit(self.allocator);
        self.outputs.clearRetainingCapacity();
    }

    fn clearSessionsLocked(self: *ObsOutputService) void {
        while (self.sessions.items.len > 0) {
            self.removeSessionLocked(self.sessions.items.len - 1);
        }
    }

    fn removeSessionLocked(self: *ObsOutputService, index: usize) void {
        var removed = self.sessions.orderedRemove(index);
        if (self.engine) |engine| engine.releaseBusTapConsumer(removed.bus_id, removed.consumer_id);
        removed.deinit(self.allocator);
    }

    fn pruneUnavailableSessionsLocked(self: *ObsOutputService) !void {
        var index: usize = 0;
        while (index < self.sessions.items.len) {
            if (self.findOutputLocked(self.sessions.items[index].bus_id) == null) {
                self.removeSessionLocked(index);
                continue;
            }
            index += 1;
        }
    }

    fn findOutputLocked(self: *ObsOutputService, bus_id: []const u8) ?DiscoverableOutput {
        for (self.outputs.items) |item| {
            if (std.mem.eql(u8, item.id, bus_id)) return item;
        }
        return null;
    }
};

fn busEligibleForObs(bus: buses_mod.Bus) bool {
    // The UI toggle now means "visible to the OBS network plugin", regardless
    // of whether the bus is a dedicated output or a mixer bus.
    return !bus.hidden and bus.share_on_network;
}

fn workerMain(service: *ObsOutputService) void {
    const sock = openUdpSocket(@intCast(proto.WD_OBS_CONTROL_PORT)) catch |err| {
        std.log.warn("obs output service unavailable: {s}", .{@errorName(err)});
        return;
    };
    defer std.posix.close(sock);

    var fds = [_]std.posix.pollfd{.{
        .fd = sock,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    var recv_buffer: [max_packet_bytes]u8 = undefined;

    while (!service.stop_requested.load(.acquire)) {
        const polled = std.posix.poll(&fds, worker_poll_timeout_ms) catch 0;
        if (polled > 0 and (fds[0].revents & std.posix.POLL.IN) != 0) {
            var source_addr: std.posix.sockaddr = undefined;
            var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
            const bytes_read = std.posix.recvfrom(sock, &recv_buffer, 0, &source_addr, &addr_len) catch 0;
            if (bytes_read >= @sizeOf(proto.wd_obs_packet_header)) {
                handlePacket(service, sock, recv_buffer[0..bytes_read], source_addr, addr_len);
            }
        }

        service.mutex.lock();
        sendAudioLocked(service, sock);
        service.mutex.unlock();
    }

    service.mutex.lock();
    defer service.mutex.unlock();
    service.clearSessionsLocked();
}

fn openUdpSocket(port: u16) !std.posix.socket_t {
    const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
    errdefer std.posix.close(sock);

    const reuse: c_int = 1;
    try std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&reuse));

    const address = try std.net.Address.parseIp("0.0.0.0", port);
    try std.posix.bind(sock, &address.any, address.getOsSockLen());
    return sock;
}

fn handlePacket(
    service: *ObsOutputService,
    sock: std.posix.socket_t,
    packet: []const u8,
    source_addr: std.posix.sockaddr,
    addr_len: std.posix.socklen_t,
) void {
    const header = std.mem.bytesToValue(proto.wd_obs_packet_header, packet[0..@sizeOf(proto.wd_obs_packet_header)]);
    if (!protocol.headerIsValid(header)) return;

    switch (header.kind) {
        proto.WD_OBS_PACKET_DISCOVER_REQUEST => handleDiscoverRequest(service, sock, header, source_addr, addr_len),
        proto.WD_OBS_PACKET_SUBSCRIBE_REQUEST => handleSubscribeRequest(service, sock, header, packet, source_addr, addr_len),
        proto.WD_OBS_PACKET_KEEPALIVE => handleKeepalive(service, header),
        proto.WD_OBS_PACKET_GOODBYE => handleGoodbye(service, header),
        else => {},
    }
}

fn handleDiscoverRequest(
    service: *ObsOutputService,
    sock: std.posix.socket_t,
    header: proto.wd_obs_packet_header,
    source_addr: std.posix.sockaddr,
    addr_len: std.posix.socklen_t,
) void {
    var response = std.mem.zeroes(proto.wd_obs_discover_response);
    response.header.magic = proto.WD_OBS_PROTOCOL_MAGIC;
    response.header.version = proto.WD_OBS_PROTOCOL_VERSION;
    response.header.kind = proto.WD_OBS_PACKET_DISCOVER_RESPONSE;
    response.header.request_id = header.request_id;

    service.mutex.lock();
    defer service.mutex.unlock();

    const count = @min(service.outputs.items.len, @as(usize, proto.WD_OBS_MAX_OUTPUTS));
    const endpoint = std.net.Address.initPosix(@alignCast(&source_addr));
    std.log.info("obs output discovery: request_id={d} from={f} outputs={d}", .{
        header.request_id,
        endpoint,
        count,
    });
    response.output_count = @intCast(count);
    for (service.outputs.items[0..count], 0..) |output, index| {
        protocol.writeStringField(response.outputs[index].id[0..], output.id);
        protocol.writeStringField(response.outputs[index].label[0..], output.label);
    }

    _ = std.posix.sendto(sock, std.mem.asBytes(&response), 0, &source_addr, addr_len) catch {};
}

fn handleSubscribeRequest(
    service: *ObsOutputService,
    sock: std.posix.socket_t,
    header: proto.wd_obs_packet_header,
    packet: []const u8,
    source_addr: std.posix.sockaddr,
    addr_len: std.posix.socklen_t,
) void {
    if (packet.len < @sizeOf(proto.wd_obs_subscribe_request)) return;
    const request = std.mem.bytesToValue(proto.wd_obs_subscribe_request, packet[0..@sizeOf(proto.wd_obs_subscribe_request)]);
    const client_name_raw = protocol.readStringField(request.client_name[0..]);
    const bus_id = protocol.readStringField(request.bus_id[0..]);
    const client_name = if (client_name_raw.len == 0) "OBS Studio" else client_name_raw;

    var response = std.mem.zeroes(proto.wd_obs_subscribe_response);
    response.header.magic = proto.WD_OBS_PROTOCOL_MAGIC;
    response.header.version = proto.WD_OBS_PROTOCOL_VERSION;
    response.header.kind = proto.WD_OBS_PACKET_SUBSCRIBE_RESPONSE;
    response.header.request_id = header.request_id;
    response.channels = proto.WD_OBS_DEFAULT_CHANNELS;
    response.frames_per_packet = proto.WD_OBS_DEFAULT_FRAMES_PER_PACKET;
    response.sample_rate_hz = proto.WD_OBS_DEFAULT_SAMPLE_RATE;

    const endpoint = std.net.Address.initPosix(@alignCast(&source_addr));
    const endpoint_text = std.fmt.allocPrint(service.allocator, "{f}", .{endpoint}) catch return;
    defer service.allocator.free(endpoint_text);

    //std.log.info("obs output subscribe: request_id={d} client={s} bus={s} from={s}", .{
    //    header.request_id,
    //    client_name,
    //    bus_id,
    //    endpoint_text,
    //});

    service.mutex.lock();
    defer service.mutex.unlock();

    const output = service.findOutputLocked(bus_id) orelse {
        //std.log.warn("obs output subscribe rejected: bus={s} from={s} reason=unavailable", .{
        //    bus_id,
        //    endpoint_text,
        //});
        protocol.writeStringField(response.message[0..], "Output not available in Wiredeck");
        _ = std.posix.sendto(sock, std.mem.asBytes(&response), 0, &source_addr, addr_len) catch {};
        return;
    };

    const session = findSessionForEndpointLocked(service, endpoint_text, bus_id) orelse createSessionLocked(service, client_name, output, endpoint, endpoint_text) catch {
        std.log.warn("obs output subscribe rejected: bus={s} from={s} reason=session_alloc", .{
            bus_id,
            endpoint_text,
        });
        protocol.writeStringField(response.message[0..], "Unable to allocate OBS stream session");
        _ = std.posix.sendto(sock, std.mem.asBytes(&response), 0, &source_addr, addr_len) catch {};
        return;
    };

    session.client_name = replaceOwnedString(service.allocator, session.client_name, client_name) catch session.client_name;
    session.bus_label = replaceOwnedString(service.allocator, session.bus_label, output.label) catch session.bus_label;
    session.endpoint = endpoint;
    session.endpoint_text = replaceOwnedString(service.allocator, session.endpoint_text, endpoint_text) catch session.endpoint_text;
    session.last_seen_ns = std.time.nanoTimestamp();
    session.sequence = 0;
    session.pcm_buffer.clear();
    session.buffering = true;
    session.next_send_time_ns = 0;

    response.header.stream_id = session.stream_id;
    response.accepted = 1;
    protocol.writeStringField(response.bus_id[0..], session.bus_id);
    protocol.writeStringField(response.bus_label[0..], session.bus_label);
    protocol.writeStringField(response.message[0..], "Subscribed");
    std.log.info("obs output subscribe accepted: stream_id={d} bus={s} label={s} to={s}", .{
        session.stream_id,
        session.bus_id,
        session.bus_label,
        endpoint_text,
    });
    _ = std.posix.sendto(sock, std.mem.asBytes(&response), 0, &source_addr, addr_len) catch {};
}

fn handleKeepalive(service: *ObsOutputService, header: proto.wd_obs_packet_header) void {
    service.mutex.lock();
    defer service.mutex.unlock();

    const session = findSessionByStreamIdLocked(service, header.stream_id) orelse return;
    session.last_seen_ns = std.time.nanoTimestamp();
}

fn handleGoodbye(service: *ObsOutputService, header: proto.wd_obs_packet_header) void {
    service.mutex.lock();
    defer service.mutex.unlock();

    const index = findSessionIndexByStreamIdLocked(service, header.stream_id) orelse return;
    service.removeSessionLocked(index);
}

fn createSessionLocked(
    service: *ObsOutputService,
    client_name: []const u8,
    output: DiscoverableOutput,
    endpoint: std.net.Address,
    endpoint_text: []const u8,
) !*Session {
    const stream_id = nextStreamIdLocked(service);
    const consumer_id = try std.fmt.allocPrint(service.allocator, "obs:{d}", .{stream_id});
    errdefer service.allocator.free(consumer_id);

    try service.sessions.append(service.allocator, .{
        .stream_id = stream_id,
        .client_name = try service.allocator.dupe(u8, client_name),
        .bus_id = try service.allocator.dupe(u8, output.id),
        .bus_label = try service.allocator.dupe(u8, output.label),
        .consumer_id = consumer_id,
        .endpoint = endpoint,
        .endpoint_text = try service.allocator.dupe(u8, endpoint_text),
        .last_seen_ns = std.time.nanoTimestamp(),
        .pcm_buffer = bus_buffer_mod.BusConsumerBuffer.init(service.allocator),
    });
    return &service.sessions.items[service.sessions.items.len - 1];
}

fn nextStreamIdLocked(service: *ObsOutputService) u32 {
    if (service.next_stream_id == 0) service.next_stream_id = 1;
    const next = service.next_stream_id;
    service.next_stream_id +%= 1;
    if (service.next_stream_id == 0) service.next_stream_id = 1;
    return next;
}

fn findSessionForEndpointLocked(service: *ObsOutputService, endpoint_text: []const u8, bus_id: []const u8) ?*Session {
    for (service.sessions.items) |*session| {
        if (!std.mem.eql(u8, session.endpoint_text, endpoint_text)) continue;
        if (!std.mem.eql(u8, session.bus_id, bus_id)) continue;
        return session;
    }
    return null;
}

fn findSessionByStreamIdLocked(service: *ObsOutputService, stream_id: u32) ?*Session {
    for (service.sessions.items) |*session| {
        if (session.stream_id == stream_id) return session;
    }
    return null;
}

fn findSessionIndexByStreamIdLocked(service: *ObsOutputService, stream_id: u32) ?usize {
    for (service.sessions.items, 0..) |session, index| {
        if (session.stream_id == stream_id) return index;
    }
    return null;
}

fn sendAudioLocked(service: *ObsOutputService, sock: std.posix.socket_t) void {
    const engine = service.engine orelse return;
    const now = std.time.nanoTimestamp();
    var packet_samples_buffer: [packet_samples]i16 = undefined;
    var pull_samples_buffer: [bus_buffer_mod.render_quantum_frames * packet_channels]i16 = undefined;
    var packet_buffer: [max_packet_bytes]u8 = undefined;

    var index: usize = 0;
    while (index < service.sessions.items.len) {
        const session = &service.sessions.items[index];
        if (now - session.last_seen_ns > session_timeout_ns or service.findOutputLocked(session.bus_id) == null) {
            service.removeSessionLocked(index);
            continue;
        }

        const target_frames = if (session.buffering) packet_frames * 2 else packet_frames;
        _ = session.pcm_buffer.fillFromEngine(
            engine,
            session.bus_id,
            session.consumer_id,
            target_frames,
            pull_samples_buffer[0..],
        ) catch {};

        const sample_rate_hz = session.pcm_buffer.effectiveSampleRate(proto.WD_OBS_DEFAULT_SAMPLE_RATE);
        const packet_duration_ns = packetDurationNs(sample_rate_hz);

        if (session.buffering) {
            if (session.pcm_buffer.availableFrames() < target_frames) {
                index += 1;
                continue;
            }
            session.buffering = false;
            session.next_send_time_ns = @intCast(now);
        }

        if (session.next_send_time_ns == 0) session.next_send_time_ns = @intCast(now);
        if (now > @as(i128, @intCast(session.next_send_time_ns)) + @as(i128, @intCast(packet_duration_ns * 3))) {
            session.next_send_time_ns = @intCast(now);
        }

        var packets_sent: usize = 0;
        while (!session.buffering and @as(i128, @intCast(session.next_send_time_ns)) <= now) {
            if (session.pcm_buffer.availableFrames() < packet_frames) {
                _ = session.pcm_buffer.fillFromEngine(
                    engine,
                    session.bus_id,
                    session.consumer_id,
                    packet_frames,
                    pull_samples_buffer[0..],
                ) catch {};
                if (session.pcm_buffer.availableFrames() < packet_frames) {
                    session.buffering = true;
                    session.next_send_time_ns = 0;
                    break;
                }
            }

            const read_frames = session.pcm_buffer.drainFrames(packet_samples_buffer[0..], packet_frames);
            if (read_frames < packet_frames) {
                session.buffering = true;
                session.next_send_time_ns = 0;
                break;
            }

            const sender_time_ns = session.next_send_time_ns;
            const sequence = session.sequence;
            session.sequence +%= 1;

            const payload_bytes = read_frames * packet_channels * @sizeOf(i16);
            const total_bytes = protocol.wire_audio_header_size + payload_bytes;
            protocol.writeAudioPacketHeader(
                packet_buffer[0..protocol.wire_audio_header_size],
                session.stream_id,
                proto.WD_OBS_AUDIO_CODEC_PCM_S16LE,
                proto.WD_OBS_DEFAULT_CHANNELS,
                @intCast(read_frames),
                sample_rate_hz,
                sequence,
                sender_time_ns,
            );
            @memcpy(
                packet_buffer[protocol.wire_audio_header_size..total_bytes],
                std.mem.sliceAsBytes(packet_samples_buffer[0 .. read_frames * packet_channels]),
            );
            _ = std.posix.sendto(sock, packet_buffer[0..total_bytes], 0, &session.endpoint.any, session.endpoint.getOsSockLen()) catch {};

            session.next_send_time_ns +%= packet_duration_ns;
            packets_sent += 1;
            if (packets_sent >= 2) break;
        }
        index += 1;
    }
}

fn packetDurationNs(sample_rate_hz: u32) u64 {
    const rate = if (sample_rate_hz != 0) sample_rate_hz else proto.WD_OBS_DEFAULT_SAMPLE_RATE;
    return @intCast((@as(u128, packet_frames) * std.time.ns_per_s) / rate);
}

fn replaceOwnedString(allocator: std.mem.Allocator, old_value: []u8, new_value: []const u8) ![]u8 {
    const owned = try allocator.dupe(u8, new_value);
    allocator.free(old_value);
    return owned;
}

fn wakeWorker() !void {
    const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
    defer std.posix.close(sock);

    const address = try std.net.Address.parseIp("127.0.0.1", @intCast(proto.WD_OBS_CONTROL_PORT));
    var packet = std.mem.zeroes(proto.wd_obs_keepalive);
    packet.header.magic = proto.WD_OBS_PROTOCOL_MAGIC;
    packet.header.version = proto.WD_OBS_PROTOCOL_VERSION;
    packet.header.kind = proto.WD_OBS_PACKET_KEEPALIVE;
    _ = try std.posix.sendto(sock, std.mem.asBytes(&packet), 0, &address.any, address.getOsSockLen());
}
