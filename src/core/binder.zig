const std = @import("std");
const pw = @import("pipewire.zig");
const pulse = @import("pulse.zig");

const Allocator = std.mem.Allocator;

pub const BoundNode = struct {
    pw_node_id: u32,
    pw_client_id: ?u32,
    app_name: ?[]const u8,
    node_name: ?[]const u8,
    media_class: ?[]const u8,
};

pub const BoundOwner = struct {
    reported_pid: ?u32,
    real_pid: ?u32,
    pid_valid: bool,
    pid_rejection_reason: ?[]const u8,

    process_binary: ?[]const u8,
    app_name: ?[]const u8,
    media_name: ?[]const u8,
    flatpak_app_id: ?[]const u8,

    pulse_client_index: ?u32,
    pulse_sink_input_indexes: []u32,
    pulse_source_output_indexes: []u32,

    pw_client_id: ?u32,
    pw_node_ids: []u32,

    confidence: Confidence,
    synthetic: bool = false,
    wiredeck_managed: bool = false,

    pub const Confidence = enum {
        low,
        medium,
        high,
    };
};

pub fn bind(
    allocator: Allocator,
    registry: *const pw.RegistryState,
    snapshot: pulse.PulseSnapshot,
) ![]BoundOwner {
    var out: std.ArrayList(BoundOwner) = .empty;
    defer out.deinit(allocator);

    for (snapshot.sink_inputs) |si| {
        const match = findBestPwMatchForPlayback(registry, si);
        const owner = try makeOwnerFromSinkInput(allocator, registry, match, si);
        if (findEquivalentIndex(out.items, owner)) |index| {
            try mergeBoundOwner(allocator, &out.items[index], owner);
            freeBoundOwner(allocator, owner);
        } else {
            try out.append(allocator, owner);
        }
    }

    for (snapshot.source_outputs) |so| {
        const match = findBestPwMatchForCapture(registry, so);
        const owner = try makeOwnerFromSourceOutput(allocator, registry, match, so);
        if (findEquivalentIndex(out.items, owner)) |index| {
            try mergeBoundOwner(allocator, &out.items[index], owner);
            freeBoundOwner(allocator, owner);
        } else {
            try out.append(allocator, owner);
        }
    }

    return try out.toOwnedSlice(allocator);
}

pub fn freeBoundOwners(allocator: Allocator, items: []BoundOwner) void {
    for (items) |item| {
        freeBoundOwner(allocator, item);
    }
    allocator.free(items);
}

fn freeBoundOwner(allocator: Allocator, item: BoundOwner) void {
    freeOpt(allocator, item.pid_rejection_reason);
    freeOpt(allocator, item.process_binary);
    freeOpt(allocator, item.app_name);
    freeOpt(allocator, item.media_name);
    freeOpt(allocator, item.flatpak_app_id);

    allocator.free(item.pulse_sink_input_indexes);
    allocator.free(item.pulse_source_output_indexes);
    allocator.free(item.pw_node_ids);
}

fn makeOwnerFromSinkInput(
    allocator: Allocator,
    registry: *const pw.RegistryState,
    match: ?PwMatch,
    si: pulse.PulseSinkInput,
) !BoundOwner {
    const app_name = if (si.app_name) |v| try allocator.dupe(u8, v) else null;
    errdefer freeOpt(allocator, app_name);

    const binary = if (si.process_binary) |v| try allocator.dupe(u8, v) else null;
    errdefer freeOpt(allocator, binary);
    const media_name = if (si.media_name) |v| try allocator.dupe(u8, v) else null;
    errdefer freeOpt(allocator, media_name);

    const pid_info = try validatePid(allocator, si.process_id);
    errdefer freeOpt(allocator, pid_info.rejection_reason);

    var sink_indexes = std.ArrayList(u32).empty;
    defer sink_indexes.deinit(allocator);
    try sink_indexes.append(allocator, si.index);

    var source_indexes = std.ArrayList(u32).empty;
    defer source_indexes.deinit(allocator);

    var pw_nodes = std.ArrayList(u32).empty;
    defer pw_nodes.deinit(allocator);

    var flatpak_app_id: ?[]const u8 = null;
    if (pid_info.validated_pid) |pid| {
        flatpak_app_id = try getFlatpakAppIdForPid(allocator, pid);
    }

    var pw_client_id: ?u32 = null;
    var confidence: BoundOwner.Confidence = .low;

    if (match) |m| {
        pw_client_id = m.pw_client_id;
        try pw_nodes.append(allocator, m.pw_node_id);
        confidence = m.confidence;
    } else {
        confidence = if (pid_info.validated_pid != null) .medium else .low;
    }

    if (!pid_info.is_valid and confidence == .high) {
        confidence = .medium;
    }

    const wiredeck_managed = isWiredeckManagedPwMatch(registry, match) or
        pulseStreamLooksWiredeckManaged(si.app_name, si.process_binary, si.media_name);
    const synthetic = wiredeck_managed or pulseSinkInputLooksSynthetic(si, match);

    return .{
        .reported_pid = si.process_id,
        .real_pid = pid_info.validated_pid,
        .pid_valid = pid_info.is_valid,
        .pid_rejection_reason = pid_info.rejection_reason,

        .process_binary = binary,
        .app_name = app_name,
        .media_name = media_name,
        .flatpak_app_id = flatpak_app_id,

        .pulse_client_index = si.client_index,
        .pulse_sink_input_indexes = try sink_indexes.toOwnedSlice(allocator),
        .pulse_source_output_indexes = try source_indexes.toOwnedSlice(allocator),

        .pw_client_id = pw_client_id,
        .pw_node_ids = try pw_nodes.toOwnedSlice(allocator),

        .confidence = confidence,
        .synthetic = synthetic,
        .wiredeck_managed = wiredeck_managed,
    };
}

fn makeOwnerFromSourceOutput(
    allocator: Allocator,
    registry: *const pw.RegistryState,
    match: ?PwMatch,
    so: pulse.PulseSourceOutput,
) !BoundOwner {
    const app_name = if (so.app_name) |v| try allocator.dupe(u8, v) else null;
    errdefer freeOpt(allocator, app_name);

    const binary = if (so.process_binary) |v| try allocator.dupe(u8, v) else null;
    errdefer freeOpt(allocator, binary);
    const media_name = if (so.media_name) |v| try allocator.dupe(u8, v) else null;
    errdefer freeOpt(allocator, media_name);

    const pid_info = try validatePid(allocator, so.process_id);
    errdefer freeOpt(allocator, pid_info.rejection_reason);

    var sink_indexes = std.ArrayList(u32).empty;
    defer sink_indexes.deinit(allocator);

    var source_indexes = std.ArrayList(u32).empty;
    defer source_indexes.deinit(allocator);
    try source_indexes.append(allocator, so.index);

    var pw_nodes = std.ArrayList(u32).empty;
    defer pw_nodes.deinit(allocator);

    var flatpak_app_id: ?[]const u8 = null;
    if (pid_info.validated_pid) |pid| {
        flatpak_app_id = try getFlatpakAppIdForPid(allocator, pid);
    }

    var pw_client_id: ?u32 = null;
    var confidence: BoundOwner.Confidence = .low;

    if (match) |m| {
        pw_client_id = m.pw_client_id;
        try pw_nodes.append(allocator, m.pw_node_id);
        confidence = m.confidence;
    } else {
        confidence = if (pid_info.validated_pid != null) .medium else .low;
    }

    if (!pid_info.is_valid and confidence == .high) {
        confidence = .medium;
    }

    const wiredeck_managed = isWiredeckManagedPwMatch(registry, match) or
        pulseStreamLooksWiredeckManaged(so.app_name, so.process_binary, so.media_name);
    const synthetic = wiredeck_managed or pulseSourceOutputLooksSynthetic(so, match);

    return .{
        .reported_pid = so.process_id,
        .real_pid = pid_info.validated_pid,
        .pid_valid = pid_info.is_valid,
        .pid_rejection_reason = pid_info.rejection_reason,

        .process_binary = binary,
        .app_name = app_name,
        .media_name = media_name,
        .flatpak_app_id = flatpak_app_id,

        .pulse_client_index = so.client_index,
        .pulse_sink_input_indexes = try sink_indexes.toOwnedSlice(allocator),
        .pulse_source_output_indexes = try source_indexes.toOwnedSlice(allocator),

        .pw_client_id = pw_client_id,
        .pw_node_ids = try pw_nodes.toOwnedSlice(allocator),

        .confidence = confidence,
        .synthetic = synthetic,
        .wiredeck_managed = wiredeck_managed,
    };
}

const PwMatch = struct {
    pw_node_id: u32,
    pw_client_id: ?u32,
    confidence: BoundOwner.Confidence,
};

fn findBestPwMatchForPlayback(
    registry: *const pw.RegistryState,
    si: pulse.PulseSinkInput,
) ?PwMatch {
    var best: ?PwMatch = null;
    var best_score: u32 = 0;

    for (registry.objects.items) |obj| {
        if (obj.kind != .node) continue;

        const media_class = obj.props.media_class orelse continue;
        if (!std.mem.eql(u8, media_class, "Stream/Output/Audio")) continue;

        var score: u32 = 0;

        if (sameOptStr(obj.props.app_name, si.app_name)) score += 50;
        if (sameOptStr(obj.props.node_name, si.app_name)) score += 25;
        if (sameOptStr(obj.props.node_description, si.media_name)) score += 10;
        if (sameOptStr(obj.props.media_name, si.media_name)) score += 10;

        if (score == 0) continue;

        if (best == null or score > best_score) {
            best_score = score;
            best = .{
                .pw_node_id = obj.id,
                .pw_client_id = obj.props.client_id,
                .confidence = if (score >= 50) .high else .medium,
            };
        }
    }

    return best;
}

fn findBestPwMatchForCapture(
    registry: *const pw.RegistryState,
    so: pulse.PulseSourceOutput,
) ?PwMatch {
    var best: ?PwMatch = null;
    var best_score: u32 = 0;

    for (registry.objects.items) |obj| {
        if (obj.kind != .node) continue;

        const media_class = obj.props.media_class orelse continue;
        if (!std.mem.eql(u8, media_class, "Stream/Input/Audio")) continue;

        var score: u32 = 0;

        if (sameOptStr(obj.props.app_name, so.app_name)) score += 50;
        if (sameOptStr(obj.props.node_name, so.app_name)) score += 25;
        if (sameOptStr(obj.props.node_description, so.media_name)) score += 10;
        if (sameOptStr(obj.props.media_name, so.media_name)) score += 10;

        if (score == 0) continue;

        if (best == null or score > best_score) {
            best_score = score;
            best = .{
                .pw_node_id = obj.id,
                .pw_client_id = obj.props.client_id,
                .confidence = if (score >= 50) .high else .medium,
            };
        }
    }

    return best;
}

const PidInfo = struct {
    reported_pid: ?u32,
    validated_pid: ?u32,
    is_valid: bool,
    rejection_reason: ?[]const u8,
};

fn validatePid(allocator: Allocator, pid: ?u32) !PidInfo {
    const reported = pid orelse {
        return .{
            .reported_pid = null,
            .validated_pid = null,
            .is_valid = false,
            .rejection_reason = try allocator.dupe(u8, "missing"),
        };
    };

    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/status", .{reported}) catch {
        return .{
            .reported_pid = reported,
            .validated_pid = null,
            .is_valid = false,
            .rejection_reason = try allocator.dupe(u8, "path-fmt-failed"),
        };
    };

    const file = std.fs.openFileAbsolute(path, .{}) catch {
        return .{
            .reported_pid = reported,
            .validated_pid = null,
            .is_valid = false,
            .rejection_reason = try allocator.dupe(u8, "proc-missing"),
        };
    };
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, 8192);
    defer allocator.free(contents);

    var is_kthread = false;
    var name: ?[]const u8 = null;

    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "Name:\t")) {
            name = std.mem.trim(u8, line["Name:\t".len..], " \t\r");
        } else if (std.mem.eql(u8, line, "Kthread:\t1")) {
            is_kthread = true;
        }
    }

    if (is_kthread) {
        return .{
            .reported_pid = reported,
            .validated_pid = null,
            .is_valid = false,
            .rejection_reason = try allocator.dupe(u8, "kthread"),
        };
    }

    if (name) |n| {
        if (std.mem.startsWith(u8, n, "kworker") or
            std.mem.startsWith(u8, n, "rcu_") or
            std.mem.startsWith(u8, n, "migration") or
            std.mem.startsWith(u8, n, "ksoftirqd"))
        {
            return .{
                .reported_pid = reported,
                .validated_pid = null,
                .is_valid = false,
                .rejection_reason = try allocator.dupe(u8, "kernel-worker"),
            };
        }
    }

    return .{
        .reported_pid = reported,
        .validated_pid = reported,
        .is_valid = true,
        .rejection_reason = null,
    };
}

fn getFlatpakAppIdForPid(allocator: Allocator, pid: u32) !?[]const u8 {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/environ", .{pid}) catch return null;

    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, 8192);
    defer allocator.free(contents);

    var it = std.mem.splitScalar(u8, contents, 0);
    while (it.next()) |entry| {
        if (std.mem.startsWith(u8, entry, "FLATPAK_ID=")) {
            const value = entry["FLATPAK_ID=".len..];
            return try allocator.dupe(u8, value);
        }
    }

    return null;
}

fn findEquivalentIndex(items: []const BoundOwner, candidate: BoundOwner) ?usize {
    for (items, 0..) |item, index| {
        if (item.reported_pid != candidate.reported_pid) continue;
        if (item.real_pid != candidate.real_pid) continue;
        if (item.pulse_client_index != candidate.pulse_client_index) continue;
        if (item.pw_client_id != candidate.pw_client_id) continue;
        if (!sameOptStr(item.process_binary, candidate.process_binary)) continue;
        if (!sameOptStr(item.app_name, candidate.app_name)) continue;
        return index;
    }
    return null;
}

fn mergeBoundOwner(allocator: Allocator, target: *BoundOwner, candidate: BoundOwner) !void {
    try appendUniqueU32s(allocator, &target.pulse_sink_input_indexes, candidate.pulse_sink_input_indexes);
    try appendUniqueU32s(allocator, &target.pulse_source_output_indexes, candidate.pulse_source_output_indexes);
    try appendUniqueU32s(allocator, &target.pw_node_ids, candidate.pw_node_ids);

    if (target.flatpak_app_id == null and candidate.flatpak_app_id != null) {
        target.flatpak_app_id = try allocator.dupe(u8, candidate.flatpak_app_id.?);
    }
    if (target.process_binary == null and candidate.process_binary != null) {
        target.process_binary = try allocator.dupe(u8, candidate.process_binary.?);
    }
    if (target.app_name == null and candidate.app_name != null) {
        target.app_name = try allocator.dupe(u8, candidate.app_name.?);
    }
    if (target.media_name == null and candidate.media_name != null) {
        target.media_name = try allocator.dupe(u8, candidate.media_name.?);
    }
    if (target.confidence == .low and candidate.confidence != .low) {
        target.confidence = candidate.confidence;
    } else if (target.confidence == .medium and candidate.confidence == .high) {
        target.confidence = .high;
    }
    target.synthetic = target.synthetic or candidate.synthetic;
    target.wiredeck_managed = target.wiredeck_managed or candidate.wiredeck_managed;
}

fn pulseSinkInputLooksSynthetic(si: pulse.PulseSinkInput, match: ?PwMatch) bool {
    const media_name = si.media_name orelse "";
    if (std.mem.startsWith(u8, media_name, "loopback-")) return true;
    if (match != null and std.mem.startsWith(u8, si.app_name orelse "", "output.loopback-")) return true;
    return si.client_index == null and
        si.process_id == null and
        si.app_name == null and
        si.process_binary == null;
}

fn pulseSourceOutputLooksSynthetic(so: pulse.PulseSourceOutput, match: ?PwMatch) bool {
    const media_name = so.media_name orelse "";
    if (std.mem.startsWith(u8, media_name, "loopback-")) return true;
    if (match != null and std.mem.startsWith(u8, so.app_name orelse "", "input.loopback-")) return true;
    return so.client_index == null and
        so.process_id == null and
        so.app_name == null and
        so.process_binary == null;
}

fn pulseStreamLooksWiredeckManaged(app_name: ?[]const u8, process_binary: ?[]const u8, media_name: ?[]const u8) bool {
    return containsIgnoreCase(app_name orelse "", "wiredeck") or
        containsIgnoreCase(process_binary orelse "", "wiredeck") or
        containsIgnoreCase(media_name orelse "", "wiredeck");
}

fn isWiredeckManagedPwMatch(registry: *const pw.RegistryState, match: ?PwMatch) bool {
    const pw_match = match orelse return false;
    for (registry.objects.items) |obj| {
        if (obj.kind != .node) continue;
        if (obj.id != pw_match.pw_node_id) continue;
        return isWiredeckManagedNode(obj);
    }
    return false;
}

fn isWiredeckManagedNode(obj: pw.GlobalObject) bool {
    if (obj.props.node_name) |node_name| {
        if (std.mem.startsWith(u8, node_name, "wiredeck_input_") or
            std.mem.startsWith(u8, node_name, "wiredeck_output_") or
            std.mem.startsWith(u8, node_name, "wiredeck_busmic_") or
            std.mem.startsWith(u8, node_name, "wiredeck_fx_") or
            std.mem.startsWith(u8, node_name, "wiredeck_parking_sink") or
            std.mem.startsWith(u8, node_name, "wiredeck_meter_") or
            std.mem.startsWith(u8, node_name, "WireDeck FX ") or
            std.mem.startsWith(u8, node_name, "output.loopback-") or
            std.mem.startsWith(u8, node_name, "input.loopback-"))
        {
            return true;
        }
    }
    return containsIgnoreCase(obj.props.node_description orelse "", "wiredeck") or
        containsIgnoreCase(obj.props.media_name orelse "", "wiredeck");
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

fn appendUniqueU32s(allocator: Allocator, target: *[]u32, extra: []const u32) !void {
    var merged = std.ArrayList(u32).empty;
    defer merged.deinit(allocator);

    for (target.*) |value| {
        try merged.append(allocator, value);
    }
    for (extra) |value| {
        var exists = false;
        for (merged.items) |current| {
            if (current == value) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            try merged.append(allocator, value);
        }
    }

    allocator.free(target.*);
    target.* = try merged.toOwnedSlice(allocator);
}

fn sameOptStr(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn freeOpt(allocator: Allocator, value: ?[]const u8) void {
    if (value) |v| allocator.free(v);
}
