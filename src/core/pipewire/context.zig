const std = @import("std");
const c = @import("c.zig").c;
const RegistryState = @import("registry.zig").RegistryState;
const ResolvedSource = @import("types.zig").ResolvedSource;

const Allocator = std.mem.Allocator;

pub const PipewireContext = struct {
    allocator: Allocator,
    loop: *c.struct_pw_main_loop,
    pw_loop: *c.struct_pw_loop,
    context: *c.struct_pw_context,
    core: *c.struct_pw_core,
    registry: *c.struct_pw_registry,

    registry_listener: c.struct_spa_hook,
    core_listener: c.struct_spa_hook,

    registry_state: RegistryState,
    roundtrip_done: bool,
    pending_seq: i32,

    pub fn init(allocator: Allocator) !*PipewireContext {
        c.pw_init(null, null);

        const self = try allocator.create(PipewireContext);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .loop = undefined,
            .pw_loop = undefined,
            .context = undefined,
            .core = undefined,
            .registry = undefined,
            .registry_listener = std.mem.zeroes(c.struct_spa_hook),
            .core_listener = std.mem.zeroes(c.struct_spa_hook),
            .registry_state = RegistryState.init(allocator),
            .roundtrip_done = false,
            .pending_seq = -1,
        };

        self.loop = c.pw_main_loop_new(null) orelse return error.PwMainLoopCreateFailed;
        errdefer c.pw_main_loop_destroy(self.loop);

        self.pw_loop = c.pw_main_loop_get_loop(self.loop);

        self.context = c.pw_context_new(c.pw_main_loop_get_loop(self.loop), null, 0) orelse {
            return error.PwContextCreateFailed;
        };
        errdefer c.pw_context_destroy(self.context);

        self.core = c.pw_context_connect(self.context, null, 0) orelse {
            return error.PwCoreConnectFailed;
        };
        errdefer _ = c.pw_core_disconnect(self.core);

        _ = c.pw_core_add_listener(
            self.core,
            &self.core_listener,
            &core_events,
            self,
        );

        self.registry = c.pw_core_get_registry(
            self.core,
            c.PW_VERSION_REGISTRY,
            0,
        ) orelse return error.PwRegistryGetFailed;

        _ = c.pw_registry_add_listener(
            self.registry,
            &self.registry_listener,
            &registry_events,
            self,
        );

        return self;
    }

    pub fn deinit(self: *PipewireContext) void {
        c.spa_hook_remove(&self.registry_listener);
        c.spa_hook_remove(&self.core_listener);

        self.registry_state.deinit();

        c.pw_proxy_destroy(@ptrCast(self.registry));
        _ = c.pw_core_disconnect(self.core);
        c.pw_context_destroy(self.context);
        c.pw_main_loop_destroy(self.loop);

        self.allocator.destroy(self);
    }

    pub fn scan(self: *PipewireContext) !void {
        self.roundtrip_done = false;

        const seq = c.pw_core_sync(self.core, c.PW_ID_CORE, 0);
        if (seq < 0) return error.PwCoreSyncFailed;
        self.pending_seq = seq;

        while (!self.roundtrip_done) {
            const rc = c.pw_loop_iterate(self.pw_loop, -1);
            if (rc < 0) return error.PwLoopIterateFailed;
        }
    }

    pub fn resolvedSources(self: *PipewireContext, allocator: Allocator) ![]ResolvedSource {
        return self.registry_state.resolveSources(allocator);
    }

    fn onGlobal(
        self: *PipewireContext,
        id: u32,
        permissions: u32,
        type_name: [*c]const u8,
        version: u32,
        props: ?*const c.struct_spa_dict,
    ) void {
        const type_span = std.mem.span(type_name);
        self.registry_state.addGlobal(id, permissions, type_span, version, props) catch {};
    }

    fn onGlobalRemove(self: *PipewireContext, id: u32) void {
        self.registry_state.removeGlobal(id);
    }

    fn onCoreDone(self: *PipewireContext, id: u32, seq: i32) void {
        _ = id;
        if (seq == self.pending_seq) {
            self.roundtrip_done = true;
        }
    }
};

fn registryEventGlobal(
    data: ?*anyopaque,
    id: u32,
    permissions: u32,
    type_name: [*c]const u8,
    version: u32,
    props: ?*const c.struct_spa_dict,
) callconv(.c) void {
    const self: *PipewireContext = @ptrCast(@alignCast(data.?));
    self.onGlobal(id, permissions, type_name, version, props);
}

fn registryEventGlobalRemove(
    data: ?*anyopaque,
    id: u32,
) callconv(.c) void {
    const self: *PipewireContext = @ptrCast(@alignCast(data.?));
    self.onGlobalRemove(id);
}

fn coreEventDone(
    data: ?*anyopaque,
    id: u32,
    seq: i32,
) callconv(.c) void {
    const self: *PipewireContext = @ptrCast(@alignCast(data.?));
    self.onCoreDone(id, seq);
}

fn coreEventError(
    data: ?*anyopaque,
    id: u32,
    seq: i32,
    res: i32,
    message: [*c]const u8,
) callconv(.c) void {
    _ = data;
    std.log.err("pipewire core error: id={} seq={} res={} msg={s}", .{
        id,
        seq,
        res,
        std.mem.span(message),
    });
}

const registry_events = c.struct_pw_registry_events{
    .version = c.PW_VERSION_REGISTRY_EVENTS,
    .global = registryEventGlobal,
    .global_remove = registryEventGlobalRemove,
};

const core_events = c.struct_pw_core_events{
    .version = c.PW_VERSION_CORE_EVENTS,
    .info = null,
    .done = coreEventDone,
    .ping = null,
    .@"error" = coreEventError,
    .remove_id = null,
    .bound_id = null,
    .add_mem = null,
    .remove_mem = null,
    .bound_props = null,
};
