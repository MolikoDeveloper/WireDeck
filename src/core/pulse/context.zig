const std = @import("std");
const c = @import("c.zig").c;
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const PulseClient = types.PulseClient;
const PulseSink = types.PulseSink;
const PulseSource = types.PulseSource;
const PulseSinkInput = types.PulseSinkInput;
const PulseSourceOutput = types.PulseSourceOutput;
const PulseModule = types.PulseModule;
const PulseCard = types.PulseCard;
const PulseCardProfile = types.PulseCardProfile;
const PulseSnapshot = types.PulseSnapshot;

pub const PulseContext = struct {
    const poll_interval_ns = 5 * std.time.ns_per_ms;
    const connect_timeout_ns = 2 * std.time.ns_per_s;
    const query_timeout_ns = 1200 * std.time.ns_per_ms;
    const operation_timeout_ns = 900 * std.time.ns_per_ms;

    allocator: Allocator,
    mainloop: *c.pa_mainloop,
    api: *c.pa_mainloop_api,
    context: *c.pa_context,

    ready: bool,
    failed: bool,

    clients_done: bool,
    sinks_done: bool,
    sources_done: bool,
    sink_inputs_done: bool,
    source_outputs_done: bool,
    modules_done: bool,
    cards_done: bool,
    server_info_done: bool,

    clients: std.ArrayList(PulseClient),
    sinks: std.ArrayList(PulseSink),
    sources: std.ArrayList(PulseSource),
    sink_inputs: std.ArrayList(PulseSinkInput),
    source_outputs: std.ArrayList(PulseSourceOutput),
    modules: std.ArrayList(PulseModule),
    cards: std.ArrayList(PulseCard),
    default_sink_name: ?[]const u8,

    pub fn init(allocator: Allocator) !*PulseContext {
        const self = try allocator.create(PulseContext);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .mainloop = undefined,
            .api = undefined,
            .context = undefined,
            .ready = false,
            .failed = false,
            .clients_done = false,
            .sinks_done = false,
            .sources_done = false,
            .sink_inputs_done = false,
            .source_outputs_done = false,
            .modules_done = false,
            .cards_done = false,
            .server_info_done = false,
            .clients = .empty,
            .sinks = .empty,
            .sources = .empty,
            .sink_inputs = .empty,
            .source_outputs = .empty,
            .modules = .empty,
            .cards = .empty,
            .default_sink_name = null,
        };

        self.mainloop = c.pa_mainloop_new() orelse return error.PulseMainloopCreateFailed;
        errdefer c.pa_mainloop_free(self.mainloop);

        self.api = c.pa_mainloop_get_api(self.mainloop);
        self.context = c.pa_context_new(self.api, "wiredeck") orelse return error.PulseContextCreateFailed;
        errdefer c.pa_context_unref(self.context);

        c.pa_context_set_state_callback(self.context, contextStateCb, self);

        const rc = c.pa_context_connect(self.context, null, c.PA_CONTEXT_NOFLAGS, null);
        if (rc < 0) return error.PulseConnectFailed;

        try self.waitUntilReady();

        return self;
    }

    pub fn deinit(self: *PulseContext) void {
        self.clearWorkingLists();

        c.pa_context_disconnect(self.context);
        c.pa_context_unref(self.context);
        c.pa_mainloop_free(self.mainloop);

        self.allocator.destroy(self);
    }

    pub fn snapshot(self: *PulseContext, allocator: Allocator) !PulseSnapshot {
        self.resetCollectionState();
        self.clearWorkingLists();
        const start_ns = std.time.nanoTimestamp();

        var op = c.pa_context_get_client_info_list(self.context, clientInfoCb, self);
        if (op == null) return error.PulseGetClientsFailed;
        c.pa_operation_unref(op);

        op = c.pa_context_get_sink_info_list(self.context, sinkInfoCb, self);
        if (op == null) return error.PulseGetSinksFailed;
        c.pa_operation_unref(op);

        op = c.pa_context_get_source_info_list(self.context, sourceInfoCb, self);
        if (op == null) return error.PulseGetSourcesFailed;
        c.pa_operation_unref(op);

        op = c.pa_context_get_sink_input_info_list(self.context, sinkInputInfoCb, self);
        if (op == null) return error.PulseGetSinkInputsFailed;
        c.pa_operation_unref(op);

        op = c.pa_context_get_source_output_info_list(self.context, sourceOutputInfoCb, self);
        if (op == null) return error.PulseGetSourceOutputsFailed;
        c.pa_operation_unref(op);

        while (!(self.clients_done and self.sinks_done and self.sources_done and self.sink_inputs_done and self.source_outputs_done)) {
            if (deadlineReached(start_ns, query_timeout_ns)) return error.PulseQueryTimedOut;
            try self.iterateOnce();
            std.Thread.sleep(poll_interval_ns);
        }

        return .{
            .clients = try self.clients.toOwnedSlice(allocator),
            .sinks = try self.sinks.toOwnedSlice(allocator),
            .sources = try self.sources.toOwnedSlice(allocator),
            .sink_inputs = try self.sink_inputs.toOwnedSlice(allocator),
            .source_outputs = try self.source_outputs.toOwnedSlice(allocator),
        };
    }

    pub fn moveSinkInputToSink(self: *PulseContext, sink_input_index: u32, sink_index: u32) !void {
        var request = OperationRequest{};
        const start_ns = std.time.nanoTimestamp();
        const op = c.pa_context_move_sink_input_by_index(self.context, sink_input_index, sink_index, successCb, &request);
        if (op == null) return error.PulseMoveSinkInputFailed;
        defer c.pa_operation_unref(op);

        while (!request.done and !self.failed) {
            if (deadlineReached(start_ns, operation_timeout_ns)) return error.PulseOperationTimedOut;
            try self.iterateOnce();
            std.Thread.sleep(poll_interval_ns);
        }
        if (self.failed or !request.success) return error.PulseMoveSinkInputFailed;
    }

    pub fn setSinkInputMuteByIndex(self: *PulseContext, sink_input_index: u32, muted: bool) !void {
        var request = OperationRequest{};
        const start_ns = std.time.nanoTimestamp();
        const op = c.pa_context_set_sink_input_mute(self.context, sink_input_index, @intFromBool(muted), successCb, &request);
        if (op == null) return error.PulseSetSinkInputMuteFailed;
        defer c.pa_operation_unref(op);

        while (!request.done and !self.failed) {
            if (deadlineReached(start_ns, operation_timeout_ns)) return error.PulseOperationTimedOut;
            try self.iterateOnce();
            std.Thread.sleep(poll_interval_ns);
        }
        if (self.failed or !request.success) return error.PulseSetSinkInputMuteFailed;
    }

    pub fn moveSourceOutputToSource(self: *PulseContext, source_output_index: u32, source_index: u32) !void {
        var request = OperationRequest{};
        const start_ns = std.time.nanoTimestamp();
        const op = c.pa_context_move_source_output_by_index(self.context, source_output_index, source_index, successCb, &request);
        if (op == null) return error.PulseMoveSourceOutputFailed;
        defer c.pa_operation_unref(op);

        while (!request.done and !self.failed) {
            if (deadlineReached(start_ns, operation_timeout_ns)) return error.PulseOperationTimedOut;
            try self.iterateOnce();
            std.Thread.sleep(poll_interval_ns);
        }
        if (self.failed or !request.success) return error.PulseMoveSourceOutputFailed;
    }

    pub fn loadModule(self: *PulseContext, name: []const u8, argument: []const u8) !u32 {
        const name_z = try self.allocator.dupeZ(u8, name);
        defer self.allocator.free(name_z);
        const argument_z = try self.allocator.dupeZ(u8, argument);
        defer self.allocator.free(argument_z);

        var request = ModuleRequest{};
        const start_ns = std.time.nanoTimestamp();
        const op = c.pa_context_load_module(self.context, name_z.ptr, argument_z.ptr, moduleIndexCb, &request);
        if (op == null) return error.PulseLoadModuleFailed;
        defer c.pa_operation_unref(op);

        while (!request.done and !self.failed) {
            if (deadlineReached(start_ns, operation_timeout_ns)) return error.PulseOperationTimedOut;
            try self.iterateOnce();
            std.Thread.sleep(poll_interval_ns);
        }
        if (self.failed or request.module_index == null) return error.PulseLoadModuleFailed;
        return request.module_index.?;
    }

    pub fn unloadModule(self: *PulseContext, module_index: u32) !void {
        var request = OperationRequest{};
        const start_ns = std.time.nanoTimestamp();
        const op = c.pa_context_unload_module(self.context, module_index, successCb, &request);
        if (op == null) return error.PulseUnloadModuleFailed;
        defer c.pa_operation_unref(op);

        while (!request.done and !self.failed) {
            if (deadlineReached(start_ns, operation_timeout_ns)) return error.PulseOperationTimedOut;
            try self.iterateOnce();
            std.Thread.sleep(poll_interval_ns);
        }
        if (self.failed or !request.success) return error.PulseUnloadModuleFailed;
    }

    pub fn listModules(self: *PulseContext, allocator: Allocator) ![]PulseModule {
        self.modules_done = false;
        self.clearModules();
        const start_ns = std.time.nanoTimestamp();

        const op = c.pa_context_get_module_info_list(self.context, moduleInfoCb, self);
        if (op == null) return error.PulseGetModulesFailed;
        defer c.pa_operation_unref(op);

        while (!self.modules_done) {
            if (deadlineReached(start_ns, query_timeout_ns)) return error.PulseQueryTimedOut;
            try self.iterateOnce();
            std.Thread.sleep(poll_interval_ns);
        }
        if (self.failed) return error.PulseGetModulesFailed;

        return try self.modules.toOwnedSlice(allocator);
    }

    pub fn listCards(self: *PulseContext, allocator: Allocator) ![]PulseCard {
        self.cards_done = false;
        self.clearCards();
        const start_ns = std.time.nanoTimestamp();

        const op = c.pa_context_get_card_info_list(self.context, cardInfoCb, self);
        if (op == null) return error.PulseGetCardsFailed;
        defer c.pa_operation_unref(op);

        while (!self.cards_done) {
            if (deadlineReached(start_ns, query_timeout_ns)) return error.PulseQueryTimedOut;
            try self.iterateOnce();
            std.Thread.sleep(poll_interval_ns);
        }
        if (self.failed) return error.PulseGetCardsFailed;

        return try self.cards.toOwnedSlice(allocator);
    }

    pub fn setCardProfileByIndex(self: *PulseContext, card_index: u32, profile: []const u8) !void {
        const profile_z = try self.allocator.dupeZ(u8, profile);
        defer self.allocator.free(profile_z);

        var request = OperationRequest{};
        const start_ns = std.time.nanoTimestamp();
        const op = c.pa_context_set_card_profile_by_index(self.context, card_index, profile_z.ptr, successCb, &request);
        if (op == null) return error.PulseSetCardProfileFailed;
        defer c.pa_operation_unref(op);

        while (!request.done and !self.failed) {
            if (deadlineReached(start_ns, operation_timeout_ns)) return error.PulseOperationTimedOut;
            try self.iterateOnce();
            std.Thread.sleep(poll_interval_ns);
        }
        if (self.failed or !request.success) return error.PulseSetCardProfileFailed;
    }

    pub fn defaultSinkName(self: *PulseContext, allocator: Allocator) !?[]u8 {
        self.server_info_done = false;
        freeOpt(self.allocator, self.default_sink_name);
        self.default_sink_name = null;
        const start_ns = std.time.nanoTimestamp();

        const op = c.pa_context_get_server_info(self.context, serverInfoCb, self);
        if (op == null) return error.PulseGetServerInfoFailed;
        defer c.pa_operation_unref(op);

        while (!self.server_info_done) {
            if (deadlineReached(start_ns, query_timeout_ns)) return error.PulseQueryTimedOut;
            try self.iterateOnce();
            std.Thread.sleep(poll_interval_ns);
        }
        if (self.failed) return error.PulseGetServerInfoFailed;

        if (self.default_sink_name) |value| {
            return try allocator.dupe(u8, value);
        }
        return null;
    }

    fn waitUntilReady(self: *PulseContext) !void {
        const start_ns = std.time.nanoTimestamp();
        while (!self.ready and !self.failed) {
            if (deadlineReached(start_ns, connect_timeout_ns)) return error.PulseContextTimedOut;
            try self.iterateOnce();
            std.Thread.sleep(poll_interval_ns);
        }
        if (self.failed) return error.PulseContextNotReady;
    }

    fn iterateOnce(self: *PulseContext) !void {
        var retval: c_int = 0;
        const rc = c.pa_mainloop_iterate(self.mainloop, 0, &retval);
        if (rc < 0) return error.PulseMainloopIterateFailed;

        const state = c.pa_context_get_state(self.context);
        switch (state) {
            c.PA_CONTEXT_READY => self.ready = true,
            c.PA_CONTEXT_FAILED, c.PA_CONTEXT_TERMINATED => self.failed = true,
            else => {},
        }
    }

    fn resetCollectionState(self: *PulseContext) void {
        self.clients_done = false;
        self.sinks_done = false;
        self.sources_done = false;
        self.sink_inputs_done = false;
        self.source_outputs_done = false;
        self.cards_done = false;
    }

    fn clearWorkingLists(self: *PulseContext) void {
        for (self.clients.items) |item| {
            freeOpt(self.allocator, item.name);
            freeOpt(self.allocator, item.app_name);
            freeOpt(self.allocator, item.process_binary);
        }
        self.clients.deinit(self.allocator);
        self.clients = .empty;

        for (self.sinks.items) |item| {
            freeOpt(self.allocator, item.name);
            freeOpt(self.allocator, item.description);
            freeOpt(self.allocator, item.monitor_source_name);
            freeOpt(self.allocator, item.bluez5_profile);
            freeOpt(self.allocator, item.bluez5_codec);
            freeOpt(self.allocator, item.active_port_name);
            freeOpt(self.allocator, item.active_port_description);
        }
        self.sinks.deinit(self.allocator);
        self.sinks = .empty;

        for (self.sources.items) |item| {
            freeOpt(self.allocator, item.name);
            freeOpt(self.allocator, item.description);
        }
        self.sources.deinit(self.allocator);
        self.sources = .empty;

        for (self.sink_inputs.items) |item| {
            freeOpt(self.allocator, item.app_name);
            freeOpt(self.allocator, item.process_binary);
            freeOpt(self.allocator, item.media_name);
        }
        self.sink_inputs.deinit(self.allocator);
        self.sink_inputs = .empty;

        for (self.source_outputs.items) |item| {
            freeOpt(self.allocator, item.app_name);
            freeOpt(self.allocator, item.process_binary);
            freeOpt(self.allocator, item.media_name);
        }
        self.source_outputs.deinit(self.allocator);
        self.source_outputs = .empty;

        self.clearModules();
        self.clearCards();
        freeOpt(self.allocator, self.default_sink_name);
        self.default_sink_name = null;
    }

    fn clearModules(self: *PulseContext) void {
        for (self.modules.items) |item| {
            freeOpt(self.allocator, item.name);
            freeOpt(self.allocator, item.argument);
        }
        self.modules.deinit(self.allocator);
        self.modules = .empty;
    }

    fn clearCards(self: *PulseContext) void {
        for (self.cards.items) |card| {
            freeOpt(self.allocator, card.name);
            freeOpt(self.allocator, card.description);
            freeOpt(self.allocator, card.device_api);
            freeOpt(self.allocator, card.active_profile);
            for (card.profiles) |profile| {
                self.allocator.free(profile.name);
                self.allocator.free(profile.description);
            }
            self.allocator.free(card.profiles);
        }
        self.cards.deinit(self.allocator);
        self.cards = .empty;
    }
};

fn deadlineReached(start_ns: i128, timeout_ns: i128) bool {
    return std.time.nanoTimestamp() - start_ns >= timeout_ns;
}

const OperationRequest = struct {
    done: bool = false,
    success: bool = false,
};

const ModuleRequest = struct {
    done: bool = false,
    module_index: ?u32 = null,
};

fn contextStateCb(_: ?*c.pa_context, userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
}

fn successCb(_: ?*c.pa_context, success: c_int, userdata: ?*anyopaque) callconv(.c) void {
    const request: *OperationRequest = @ptrCast(@alignCast(userdata orelse return));
    request.done = true;
    request.success = success != 0;
}

fn moduleIndexCb(_: ?*c.pa_context, index: u32, userdata: ?*anyopaque) callconv(.c) void {
    const request: *ModuleRequest = @ptrCast(@alignCast(userdata orelse return));
    request.done = true;
    request.module_index = if (index == c.PA_INVALID_INDEX) null else index;
}

fn moduleInfoCb(
    _: ?*c.pa_context,
    info: ?*const c.pa_module_info,
    eol: c_int,
    userdata: ?*anyopaque,
) callconv(.c) void {
    const self: *PulseContext = @ptrCast(@alignCast(userdata.?));

    if (eol != 0) {
        self.modules_done = true;
        return;
    }

    const i = info orelse return;
    self.modules.append(self.allocator, .{
        .index = i.index,
        .name = dupCStr(self.allocator, i.name),
        .argument = dupCStr(self.allocator, i.argument),
    }) catch {};
}

fn serverInfoCb(
    _: ?*c.pa_context,
    info: ?*const c.pa_server_info,
    userdata: ?*anyopaque,
) callconv(.c) void {
    const self: *PulseContext = @ptrCast(@alignCast(userdata.?));
    const i = info orelse {
        self.server_info_done = true;
        return;
    };

    freeOpt(self.allocator, self.default_sink_name);
    self.default_sink_name = dupCStr(self.allocator, i.default_sink_name);
    self.server_info_done = true;
}

fn clientInfoCb(
    _: ?*c.pa_context,
    info: ?*const c.pa_client_info,
    eol: c_int,
    userdata: ?*anyopaque,
) callconv(.c) void {
    const self: *PulseContext = @ptrCast(@alignCast(userdata.?));

    if (eol != 0) {
        self.clients_done = true;
        return;
    }

    const i = info orelse return;

    const item = PulseClient{
        .index = i.index,
        .name = dupCStr(self.allocator, i.name),
        .app_name = dupProp(self.allocator, i.proplist, c.PA_PROP_APPLICATION_NAME),
        .process_id = parseU32Maybe(getProp(i.proplist, c.PA_PROP_APPLICATION_PROCESS_ID)),
        .process_binary = dupProp(self.allocator, i.proplist, c.PA_PROP_APPLICATION_PROCESS_BINARY),
    };

    self.clients.append(self.allocator, item) catch {};
}

fn sinkInfoCb(
    _: ?*c.pa_context,
    info: ?*const c.pa_sink_info,
    eol: c_int,
    userdata: ?*anyopaque,
) callconv(.c) void {
    const self: *PulseContext = @ptrCast(@alignCast(userdata.?));

    if (eol != 0) {
        self.sinks_done = true;
        return;
    }

    const i = info orelse return;
    self.sinks.append(self.allocator, .{
        .index = i.index,
        .name = dupCStr(self.allocator, i.name),
        .description = dupCStr(self.allocator, i.description),
        .monitor_source_name = dupCStr(self.allocator, i.monitor_source_name),
        .card_index = if (i.card != c.PA_INVALID_INDEX) i.card else null,
        .bluez5_profile = dupProp(self.allocator, i.proplist, "api.bluez5.profile"),
        .bluez5_codec = dupProp(self.allocator, i.proplist, "api.bluez5.codec"),
        .active_port_name = if (i.active_port != null) dupCStr(self.allocator, i.active_port.*.name) else null,
        .active_port_description = if (i.active_port != null) dupCStr(self.allocator, i.active_port.*.description) else null,
    }) catch {};
}

fn cardInfoCb(
    _: ?*c.pa_context,
    info: ?*const c.pa_card_info,
    eol: c_int,
    userdata: ?*anyopaque,
) callconv(.c) void {
    const self: *PulseContext = @ptrCast(@alignCast(userdata.?));

    if (eol != 0) {
        self.cards_done = true;
        return;
    }

    const i = info orelse return;
    const profiles = dupCardProfiles(self.allocator, i) catch return;
    self.cards.append(self.allocator, .{
        .index = i.index,
        .name = dupCStr(self.allocator, i.name),
        .description = dupProp(self.allocator, i.proplist, "device.description"),
        .device_api = dupProp(self.allocator, i.proplist, "device.api"),
        .active_profile = if (i.active_profile2 != null) dupCStr(self.allocator, i.active_profile2.*.name) else null,
        .profiles = profiles,
    }) catch {};
}

fn sourceInfoCb(
    _: ?*c.pa_context,
    info: ?*const c.pa_source_info,
    eol: c_int,
    userdata: ?*anyopaque,
) callconv(.c) void {
    const self: *PulseContext = @ptrCast(@alignCast(userdata.?));

    if (eol != 0) {
        self.sources_done = true;
        return;
    }

    const i = info orelse return;
    self.sources.append(self.allocator, .{
        .index = i.index,
        .name = dupCStr(self.allocator, i.name),
        .description = dupCStr(self.allocator, i.description),
        .monitor_of_sink = if (i.monitor_of_sink != c.PA_INVALID_INDEX) i.monitor_of_sink else null,
        .channels = @intCast(if (i.sample_spec.channels == 0) 2 else i.sample_spec.channels),
    }) catch {};
}

fn sinkInputInfoCb(
    _: ?*c.pa_context,
    info: ?*const c.pa_sink_input_info,
    eol: c_int,
    userdata: ?*anyopaque,
) callconv(.c) void {
    const self: *PulseContext = @ptrCast(@alignCast(userdata.?));

    if (eol != 0) {
        self.sink_inputs_done = true;
        return;
    }

    const i = info orelse return;

    const item = PulseSinkInput{
        .index = i.index,
        .client_index = if (i.client != c.PA_INVALID_INDEX) i.client else null,
        .sink_index = if (i.sink != c.PA_INVALID_INDEX) i.sink else null,
        .muted = i.mute != 0,
        .app_name = dupProp(self.allocator, i.proplist, c.PA_PROP_APPLICATION_NAME),
        .process_id = parseU32Maybe(getProp(i.proplist, c.PA_PROP_APPLICATION_PROCESS_ID)),
        .process_binary = dupProp(self.allocator, i.proplist, c.PA_PROP_APPLICATION_PROCESS_BINARY),
        .media_name = dupProp(self.allocator, i.proplist, c.PA_PROP_MEDIA_NAME),
        .channels = @intCast(if (i.sample_spec.channels == 0) 2 else i.sample_spec.channels),
    };

    self.sink_inputs.append(self.allocator, item) catch {};
}

fn sourceOutputInfoCb(
    _: ?*c.pa_context,
    info: ?*const c.pa_source_output_info,
    eol: c_int,
    userdata: ?*anyopaque,
) callconv(.c) void {
    const self: *PulseContext = @ptrCast(@alignCast(userdata.?));

    if (eol != 0) {
        self.source_outputs_done = true;
        return;
    }

    const i = info orelse return;

    const item = PulseSourceOutput{
        .index = i.index,
        .client_index = if (i.client != c.PA_INVALID_INDEX) i.client else null,
        .source_index = if (i.source != c.PA_INVALID_INDEX) i.source else null,
        .app_name = dupProp(self.allocator, i.proplist, c.PA_PROP_APPLICATION_NAME),
        .process_id = parseU32Maybe(getProp(i.proplist, c.PA_PROP_APPLICATION_PROCESS_ID)),
        .process_binary = dupProp(self.allocator, i.proplist, c.PA_PROP_APPLICATION_PROCESS_BINARY),
        .media_name = dupProp(self.allocator, i.proplist, c.PA_PROP_MEDIA_NAME),
        .channels = @intCast(if (i.sample_spec.channels == 0) 2 else i.sample_spec.channels),
    };

    self.source_outputs.append(self.allocator, item) catch {};
}

fn getProp(proplist: ?*const c.pa_proplist, key: [*c]const u8) ?[]const u8 {
    const p = proplist orelse return null;
    const raw = c.pa_proplist_gets(p, key);
    if (raw == null) return null;
    return std.mem.span(raw);
}

fn dupProp(allocator: Allocator, proplist: ?*const c.pa_proplist, key: [*c]const u8) ?[]const u8 {
    const value = getProp(proplist, key) orelse return null;
    return allocator.dupe(u8, value) catch null;
}

fn dupCStr(allocator: Allocator, value: ?[*:0]const u8) ?[]const u8 {
    const v = value orelse return null;
    return allocator.dupe(u8, std.mem.span(v)) catch null;
}

fn parseU32Maybe(value: ?[]const u8) ?u32 {
    const s = value orelse return null;
    return std.fmt.parseUnsigned(u32, s, 10) catch null;
}

fn freeOpt(allocator: Allocator, value: ?[]const u8) void {
    if (value) |v| allocator.free(v);
}

fn dupCardProfiles(allocator: Allocator, card_info: *const c.pa_card_info) ![]PulseCardProfile {
    const profile_ptrs = card_info.profiles2 orelse return allocator.alloc(PulseCardProfile, 0);
    var count: usize = 0;
    while (profile_ptrs[count] != null) : (count += 1) {}

    const profiles = try allocator.alloc(PulseCardProfile, count);
    errdefer {
        var i: usize = 0;
        while (i < count) : (i += 1) {
            allocator.free(profiles[i].name);
            allocator.free(profiles[i].description);
        }
        allocator.free(profiles);
    }

    for (0..count) |index| {
        const profile = profile_ptrs[index].?;
        profiles[index] = .{
            .name = try allocator.dupe(u8, std.mem.span(profile.*.name)),
            .description = try allocator.dupe(u8, std.mem.span(profile.*.description)),
            .n_sinks = profile.*.n_sinks,
            .n_sources = profile.*.n_sources,
            .priority = profile.*.priority,
            .available = profile.*.available != 0,
        };
    }
    return profiles;
}
