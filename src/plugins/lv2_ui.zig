const std = @import("std");
const build_options = @import("build_options");
const App = @import("../app/app.zig").App;
const StateStore = @import("../app/state_store.zig").StateStore;

pub const Lv2UiManager = if (build_options.enable_suil) struct {
    const UiCrashRecord = struct {
        count: u32 = 1,
        last_term: std.process.Child.Term,
    };

    const OpenUiProcess = struct {
        plugin_id: []u8,
        descriptor_id: []u8,
        child: std.process.Child,
        stdout_buffer: std.ArrayList(u8),
        last_param_sync_hash: u64 = 0,
        last_runtime_sync_hash: u64 = 0,

        fn deinit(self: *OpenUiProcess, allocator: std.mem.Allocator) void {
            if (self.child.term == null) {
                _ = self.child.kill() catch {};
            }
            allocator.free(self.plugin_id);
            allocator.free(self.descriptor_id);
            self.stdout_buffer.deinit(allocator);
        }
    };

    allocator: std.mem.Allocator,
    processes: std.ArrayList(OpenUiProcess),
    crashed_descriptors: std.StringHashMap(UiCrashRecord),

    pub fn init(allocator: std.mem.Allocator) Lv2UiManager {
        return .{
            .allocator = allocator,
            .processes = std.ArrayList(OpenUiProcess).empty,
            .crashed_descriptors = std.StringHashMap(UiCrashRecord).init(allocator),
        };
    }

    pub fn deinit(self: *Lv2UiManager) void {
        for (self.processes.items) |*process| process.deinit(self.allocator);
        self.processes.deinit(self.allocator);
        var iter = self.crashed_descriptors.keyIterator();
        while (iter.next()) |key| self.allocator.free(key.*);
        self.crashed_descriptors.deinit();
    }

    pub fn pump(self: *Lv2UiManager, app: *App, state_store: *StateStore) bool {
        var changed = false;
        var index: usize = 0;
        while (index < self.processes.items.len) {
            var should_remove = false;
            if (self.pumpProcess(&self.processes.items[index], app, state_store, &should_remove)) {
                changed = true;
            }
            if (should_remove) {
                self.processes.items[index].deinit(self.allocator);
                _ = self.processes.orderedRemove(index);
                continue;
            }
            index += 1;
        }
        return changed;
    }

    pub fn openPluginUi(self: *Lv2UiManager, state_store: *StateStore, plugin_id: []const u8) !void {
        if (findOpenProcess(self.processes.items, plugin_id) != null) return;

        const channel_plugin = state_store.findChannelPlugin(plugin_id) orelse return error.UnknownChannelPlugin;
        const descriptor = state_store.findPluginDescriptor(channel_plugin.descriptor_id) orelse return error.UnknownPluginDescriptor;
        if (self.crashed_descriptors.contains(descriptor.id)) return error.PluginUiDisabledAfterCrash;
        if (!descriptor.has_custom_ui or descriptor.primary_ui_uri.len == 0) return error.PluginHasNoCustomUi;

        const helper_path = try findHelperPath(self.allocator);
        defer self.allocator.free(helper_path);

        var argv_storage = std.ArrayList([]u8).empty;
        defer {
            for (argv_storage.items) |item| self.allocator.free(item);
            argv_storage.deinit(self.allocator);
        }
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(self.allocator);

        try appendOwnedArg(self.allocator, &argv_storage, &argv, helper_path);
        try appendOwnedArg(self.allocator, &argv_storage, &argv, "--plugin-uri");
        try appendOwnedArg(self.allocator, &argv_storage, &argv, descriptor.id);
        try appendOwnedArg(self.allocator, &argv_storage, &argv, "--ui-uri");
        try appendOwnedArg(self.allocator, &argv_storage, &argv, descriptor.primary_ui_uri);
        try appendOwnedArg(self.allocator, &argv_storage, &argv, "--title");
        const title = try std.fmt.allocPrint(self.allocator, "{s} UI", .{channel_plugin.label});
        defer self.allocator.free(title);
        try appendOwnedArg(self.allocator, &argv_storage, &argv, title);

        for (descriptor.control_ports) |port| {
            if (port.is_output) continue;
            const param = state_store.findChannelPluginParam(plugin_id, port.symbol) orelse continue;
            const spec = try std.fmt.allocPrint(self.allocator, "{s}={d}", .{ port.symbol, param.value });
            defer self.allocator.free(spec);
            try appendOwnedArg(self.allocator, &argv_storage, &argv, "--param");
            try appendOwnedArg(self.allocator, &argv_storage, &argv, spec);
        }

        var child = std.process.Child.init(argv.items, self.allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit;
        try child.spawn();

        const owned_plugin_id = try self.allocator.dupe(u8, plugin_id);
        errdefer self.allocator.free(owned_plugin_id);
        const owned_descriptor_id = try self.allocator.dupe(u8, descriptor.id);
        errdefer self.allocator.free(owned_descriptor_id);
        try self.processes.append(self.allocator, .{
            .plugin_id = owned_plugin_id,
            .descriptor_id = owned_descriptor_id,
            .child = child,
            .stdout_buffer = std.ArrayList(u8).empty,
        });
        self.sendStateParamUpdates(&self.processes.items[self.processes.items.len - 1], state_store);
    }

    fn findOpenProcess(items: []OpenUiProcess, plugin_id: []const u8) ?*OpenUiProcess {
        for (items) |*item| {
            if (std.mem.eql(u8, item.plugin_id, plugin_id)) return item;
        }
        return null;
    }

    fn findHelperPath(allocator: std.mem.Allocator) ![]u8 {
        const exe_path = try std.fs.selfExePathAlloc(allocator);
        defer allocator.free(exe_path);
        const exe_dir = std.fs.path.dirname(exe_path) orelse return error.HelperPathUnavailable;
        return std.fs.path.join(allocator, &.{ exe_dir, "wiredeck-lv2-ui-host" });
    }

    fn appendOwnedArg(
        allocator: std.mem.Allocator,
        storage: *std.ArrayList([]u8),
        argv: *std.ArrayList([]const u8),
        value: []const u8,
    ) !void {
        if (value.len == 0) return error.EmptyChildArgument;
        if (value.len > 16 * 1024) return error.ChildArgumentTooLong;
        if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidChildArgument;

        const owned = try allocator.dupe(u8, value);
        errdefer allocator.free(owned);
        try storage.append(allocator, owned);
        try argv.append(allocator, owned);
    }

    fn pumpProcess(self: *Lv2UiManager, process: *OpenUiProcess, app: *App, state_store: *StateStore, should_remove: *bool) bool {
        const stdout_file = process.child.stdout orelse {
            should_remove.* = true;
            return false;
        };
        const fd = stdout_file.handle;
        var fds = [_]std.posix.pollfd{
            .{
                .fd = fd,
                .events = std.posix.POLL.IN | std.posix.POLL.HUP,
                .revents = 0,
            },
        };
        const ready = std.posix.poll(&fds, 0) catch return false;

        var changed = false;
        if (ready != 0 and (fds[0].revents & std.posix.POLL.IN) != 0) {
            var buf: [512]u8 = undefined;
            const read_len = stdout_file.read(&buf) catch 0;
            if (read_len == 0) {
                self.finishProcess(process, state_store);
                should_remove.* = true;
                return false;
            }
            process.stdout_buffer.appendSlice(self.allocator, buf[0..read_len]) catch return false;
            if (processOutputLines(process, state_store)) changed = true;
        }

        if (ready != 0 and (fds[0].revents & std.posix.POLL.HUP) != 0) {
            self.finishProcess(process, state_store);
            should_remove.* = true;
        }

        self.sendStateParamUpdates(process, state_store);
        self.sendRuntimeUpdates(process, app);
        return changed;
    }

    fn processOutputLines(process: *OpenUiProcess, state_store: *StateStore) bool {
        var changed = false;
        while (std.mem.indexOfScalar(u8, process.stdout_buffer.items, '\n')) |newline| {
            const line = process.stdout_buffer.items[0..newline];
            if (handleOutputLine(process.plugin_id, line, state_store)) changed = true;
            const remaining = process.stdout_buffer.items[newline + 1 ..];
            std.mem.copyForwards(u8, process.stdout_buffer.items, remaining);
            process.stdout_buffer.items.len = remaining.len;
        }
        return changed;
    }

    fn handleOutputLine(plugin_id: []const u8, line: []const u8, state_store: *StateStore) bool {
        var it = std.mem.splitScalar(u8, line, '\t');
        const kind = it.next() orelse return false;
        if (!std.mem.eql(u8, kind, "param")) return false;
        const symbol = it.next() orelse return false;
        const raw_value = it.next() orelse return false;
        const value = std.fmt.parseFloat(f32, raw_value) catch return false;
        return state_store.setChannelPluginParamValue(plugin_id, symbol, value);
    }

    fn sendStateParamUpdates(self: *Lv2UiManager, process: *OpenUiProcess, state_store: *StateStore) void {
        const channel_plugin = state_store.findChannelPlugin(process.plugin_id) orelse return;
        const descriptor = state_store.findPluginDescriptor(channel_plugin.descriptor_id) orelse return;
        const stdin_file = process.child.stdin orelse return;

        var hasher = std.hash.Wyhash.init(0);
        var payload = std.ArrayList(u8).empty;
        defer payload.deinit(self.allocator);

        for (descriptor.control_ports) |port| {
            if (port.is_output) continue;
            const param = state_store.findChannelPluginParam(process.plugin_id, port.symbol) orelse continue;
            hasher.update(port.symbol);
            hasher.update(std.mem.asBytes(&param.value));
            payload.writer(self.allocator).print("param\t{s}\t{d}\n", .{ port.symbol, param.value }) catch return;
        }

        const hash = hasher.final();
        if (hash == process.last_param_sync_hash) return;
        stdin_file.writeAll(payload.items) catch return;
        process.last_param_sync_hash = hash;
    }

    fn sendRuntimeUpdates(self: *Lv2UiManager, process: *OpenUiProcess, app: *App) void {
        const stdin_file = process.child.stdin orelse return;

        var payload = std.ArrayList(u8).empty;
        defer payload.deinit(self.allocator);

        const hash = app.fx_runtime.writeUiUpdateLines(process.plugin_id, payload.writer(self.allocator)) catch return;
        if (hash == 0 or hash == process.last_runtime_sync_hash) return;

        stdin_file.writeAll(payload.items) catch return;
        process.last_runtime_sync_hash = hash;
    }

    fn finishProcess(self: *Lv2UiManager, process: *OpenUiProcess, state_store: *StateStore) void {
        const term = process.child.wait() catch |err| {
            std.log.warn("lv2 ui host wait failed for plugin={s}: {s}", .{ process.plugin_id, @errorName(err) });
            return;
        };
        switch (term) {
            .Exited => |code| {
                if (code != 0) self.recordCrash(process, term, state_store);
            },
            .Signal, .Stopped, .Unknown => self.recordCrash(process, term, state_store),
        }
    }

    fn recordCrash(self: *Lv2UiManager, process: *OpenUiProcess, term: std.process.Child.Term, state_store: *StateStore) void {
        const crash_count = blk: {
            const gop = self.crashed_descriptors.getOrPut(process.descriptor_id) catch {
                self.logUiCrash(process, term, state_store, 1, false);
                return;
            };
            if (gop.found_existing) {
                gop.value_ptr.count += 1;
                gop.value_ptr.last_term = term;
                break :blk gop.value_ptr.count;
            }

            gop.key_ptr.* = self.allocator.dupe(u8, process.descriptor_id) catch {
                _ = self.crashed_descriptors.remove(process.descriptor_id);
                self.logUiCrash(process, term, state_store, 1, false);
                return;
            };
            gop.value_ptr.* = .{
                .count = 1,
                .last_term = term,
            };
            break :blk gop.value_ptr.count;
        };
        self.logUiCrash(process, term, state_store, crash_count, true);
    }

    fn logUiCrash(
        self: *Lv2UiManager,
        process: *const OpenUiProcess,
        term: std.process.Child.Term,
        state_store: *StateStore,
        crash_count: u32,
        disabled: bool,
    ) void {
        _ = self;
        const channel_plugin = state_store.findChannelPlugin(process.plugin_id);
        const plugin_label = if (channel_plugin) |plugin| plugin.label else process.plugin_id;
        switch (term) {
            .Exited => |code| std.log.warn(
                "lv2 ui host exited abnormally for plugin={s} descriptor={s} code={d} crashes={d} disabled={any}",
                .{ plugin_label, process.descriptor_id, code, crash_count, disabled },
            ),
            .Signal => |signal| std.log.warn(
                "lv2 ui host crashed for plugin={s} descriptor={s} signal={d} crashes={d} disabled={any}",
                .{ plugin_label, process.descriptor_id, signal, crash_count, disabled },
            ),
            .Stopped => |signal| std.log.warn(
                "lv2 ui host stopped unexpectedly for plugin={s} descriptor={s} signal={d} crashes={d} disabled={any}",
                .{ plugin_label, process.descriptor_id, signal, crash_count, disabled },
            ),
            .Unknown => |status| std.log.warn(
                "lv2 ui host ended unexpectedly for plugin={s} descriptor={s} status={d} crashes={d} disabled={any}",
                .{ plugin_label, process.descriptor_id, status, crash_count, disabled },
            ),
        }
    }
} else struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Lv2UiManager {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Lv2UiManager) void {
        _ = self;
    }

    pub fn pump(self: *Lv2UiManager, app: *App, state_store: *StateStore) bool {
        _ = self;
        _ = app;
        _ = state_store;
        return false;
    }

    pub fn openPluginUi(self: *Lv2UiManager, state_store: *StateStore, plugin_id: []const u8) !void {
        _ = self;
        _ = state_store;
        _ = plugin_id;
        return error.SuilSupportDisabled;
    }
};
