const std = @import("std");
const build_options = @import("build_options");
const chain = @import("chain.zig");
const host = @import("host.zig");
const lv2_discovery = @import("lv2.zig");
const lv2_c = if (build_options.enable_lilv) @cImport({
    @cInclude("lilv/lilv.h");
    @cInclude("lv2/atom/atom.h");
    @cInclude("lv2/buf-size/buf-size.h");
    @cInclude("lv2/options/options.h");
    @cInclude("lv2/patch/patch.h");
}) else struct {};

pub const Lv2Runtime = if (build_options.enable_lilv) struct {
    const c = @cImport({
        @cInclude("lilv/lilv.h");
        @cInclude("lv2/atom/atom.h");
        @cInclude("lv2/buf-size/buf-size.h");
        @cInclude("lv2/options/options.h");
        @cInclude("lv2/patch/patch.h");
    });

    const preferred_block_size = 256;
    const max_block_size = 4096;

    pub const UiRuntimeHandle = struct {
        instance: *c.LilvInstance,
        features: [*]const ?*const c.LV2_Feature,
    };

    pub fn writeUiUpdateLines(self: *Lv2Runtime, plugin_id: []const u8, writer: anytype) !u64 {
        const instance_index = findInstance(self.instances.items, plugin_id) orelse return 0;
        const instance = &self.instances.items[instance_index];
        var hasher = std.hash.Wyhash.init(0);
        var wrote_any = false;

        for (instance.output_control_port_indexes, instance.output_control_symbols) |port_index, symbol| {
            const value = instance.port_values[port_index];
            hasher.update(symbol);
            hasher.update(std.mem.asBytes(&value));
            try writer.print("param\t{s}\t{d}\n", .{ symbol, value });
            wrote_any = true;
        }

        for (instance.atom_buffers) |atom_buffer| {
            if (!atom_buffer.is_output) continue;
            const used_bytes = atomSequenceUsedBytes(atom_buffer.bytes) orelse continue;
            if (used_bytes.len <= @sizeOf(c.LV2_Atom_Sequence)) continue;
            hasher.update(std.mem.asBytes(&atom_buffer.port_index));
            hasher.update(used_bytes);
            try writer.print("atom\t{d}\t{X}\n", .{
                atom_buffer.port_index,
                used_bytes,
            });
            wrote_any = true;
        }

        return if (wrote_any) hasher.final() else 0;
    }

    const UridMapStore = struct {
        allocator: std.mem.Allocator,
        by_uri: std.StringHashMap(c.LV2_URID),
        by_id: std.ArrayList([:0]u8),

        fn init(allocator: std.mem.Allocator) UridMapStore {
            return .{
                .allocator = allocator,
                .by_uri = std.StringHashMap(c.LV2_URID).init(allocator),
                .by_id = std.ArrayList([:0]u8).empty,
            };
        }

        fn deinit(self: *UridMapStore) void {
            var iter = self.by_uri.keyIterator();
            while (iter.next()) |key| self.allocator.free(key.*);
            self.by_uri.deinit();
            for (self.by_id.items) |uri| self.allocator.free(uri);
            self.by_id.deinit(self.allocator);
        }

        fn map(self: *UridMapStore, uri: []const u8) c.LV2_URID {
            const owned_uri = self.allocator.dupe(u8, uri) catch return 0;
            const result = self.by_uri.getOrPut(owned_uri) catch {
                self.allocator.free(owned_uri);
                return 0;
            };
            if (result.found_existing) {
                self.allocator.free(owned_uri);
                return result.value_ptr.*;
            }

            const uri_z = self.allocator.dupeZ(u8, uri) catch {
                _ = self.by_uri.remove(owned_uri);
                self.allocator.free(owned_uri);
                return 0;
            };
            self.by_id.append(self.allocator, uri_z) catch {
                _ = self.by_uri.remove(owned_uri);
                self.allocator.free(owned_uri);
                self.allocator.free(uri_z);
                return 0;
            };

            const urid: c.LV2_URID = @intCast(self.by_id.items.len);
            result.value_ptr.* = urid;
            return urid;
        }

        fn unmap(self: *UridMapStore, urid: c.LV2_URID) ?[*:0]const u8 {
            if (urid == 0) return null;
            const index: usize = @intCast(urid - 1);
            if (index >= self.by_id.items.len) return null;
            return self.by_id.items[index].ptr;
        }
    };

    const ManagedInstance = struct {
        const RunFn = *const fn (c.LV2_Handle, u32) callconv(.c) void;

        const ManagedAtomBuffer = struct {
            port_index: u32,
            is_output: bool,
            bytes: []align(@alignOf(c.LV2_Atom_Sequence)) u8,
        };

        plugin_id: []u8,
        channel_id: []u8,
        descriptor_id: []u8,
        slot: u32 = 0,
        enabled: bool = true,
        supports_plugin_state_sync: bool = false,
        instance: *c.LilvInstance,
        lv2_handle: c.LV2_Handle,
        run_fn: RunFn,
        activated: bool = false,
        port_values: []f32,
        output_control_port_indexes: []u32,
        output_control_symbols: [][]u8,
        audio_buffers: [][]f32,
        audio_port_indexes: []u32,
        audio_port_is_output: []bool,
        atom_buffers: []ManagedAtomBuffer,

        fn deinit(self: *ManagedInstance, allocator: std.mem.Allocator) void {
            if (self.activated) c.lilv_instance_deactivate(self.instance);
            c.lilv_instance_free(self.instance);
            allocator.free(self.plugin_id);
            allocator.free(self.channel_id);
            allocator.free(self.descriptor_id);
            allocator.free(self.port_values);
            allocator.free(self.output_control_port_indexes);
            for (self.output_control_symbols) |symbol| allocator.free(symbol);
            allocator.free(self.output_control_symbols);
            for (self.audio_buffers) |buffer| allocator.free(buffer);
            allocator.free(self.audio_buffers);
            allocator.free(self.audio_port_indexes);
            allocator.free(self.audio_port_is_output);
            for (self.atom_buffers) |atom_buffer| allocator.free(atom_buffer.bytes);
            allocator.free(self.atom_buffers);
        }
    };

    const FeatureContext = struct {
        urid_store: UridMapStore,
        urid_map_feature_data: c.LV2_URID_Map,
        urid_unmap_feature_data: c.LV2_URID_Unmap,
        urid_map_feature: c.LV2_Feature,
        urid_unmap_feature: c.LV2_Feature,
        bounded_block_length_feature: c.LV2_Feature,
        options_feature: c.LV2_Feature,
        options: [2]c.LV2_Options_Option,
        max_block_length_value: i32 = max_block_size,
        atom_sequence_urid: c.LV2_URID = 0,
        atom_frame_time_urid: c.LV2_URID = 0,
        atom_object_urid: c.LV2_URID = 0,
        patch_get_urid: c.LV2_URID = 0,
        feature_ptrs: [5]?*const c.LV2_Feature,

        fn init(allocator: std.mem.Allocator) !*FeatureContext {
            const context = try allocator.create(FeatureContext);
            context.* = .{
                .urid_store = UridMapStore.init(allocator),
                .urid_map_feature_data = .{
                    .handle = undefined,
                    .map = uridMapCallback,
                },
                .urid_unmap_feature_data = .{
                    .handle = undefined,
                    .unmap = uridUnmapCallback,
                },
                .urid_map_feature = .{
                    .URI = c.LV2_URID__map,
                    .data = undefined,
                },
                .urid_unmap_feature = .{
                    .URI = c.LV2_URID__unmap,
                    .data = undefined,
                },
                .bounded_block_length_feature = .{
                    .URI = c.LV2_BUF_SIZE__boundedBlockLength,
                    .data = null,
                },
                .options_feature = .{
                    .URI = c.LV2_OPTIONS__options,
                    .data = undefined,
                },
                .options = undefined,
                .feature_ptrs = .{ null, null, null, null, null },
            };
            context.urid_map_feature_data.handle = @ptrCast(&context.urid_store);
            context.urid_unmap_feature_data.handle = @ptrCast(&context.urid_store);
            context.urid_map_feature.data = @ptrCast(&context.urid_map_feature_data);
            context.urid_unmap_feature.data = @ptrCast(&context.urid_unmap_feature_data);
            const max_block_length_urid = context.urid_store.map(c.LV2_BUF_SIZE__maxBlockLength);
            const atom_int_urid = context.urid_store.map(c.LV2_ATOM__Int);
            context.atom_sequence_urid = context.urid_store.map(c.LV2_ATOM__Sequence);
            context.atom_frame_time_urid = context.urid_store.map(c.LV2_ATOM__frameTime);
            context.atom_object_urid = context.urid_store.map(c.LV2_ATOM__Object);
            context.patch_get_urid = context.urid_store.map(c.LV2_PATCH__Get);
            context.options[0] = .{
                .context = c.LV2_OPTIONS_INSTANCE,
                .subject = 0,
                .key = max_block_length_urid,
                .size = @sizeOf(i32),
                .type = atom_int_urid,
                .value = @ptrCast(&context.max_block_length_value),
            };
            context.options[1] = .{
                .context = 0,
                .subject = 0,
                .key = 0,
                .size = 0,
                .type = 0,
                .value = null,
            };
            context.options_feature.data = @ptrCast(&context.options[0]);
            context.feature_ptrs = .{
                &context.urid_map_feature,
                &context.urid_unmap_feature,
                &context.bounded_block_length_feature,
                &context.options_feature,
                null,
            };
            return context;
        }

        fn deinit(self: *FeatureContext, allocator: std.mem.Allocator) void {
            self.urid_store.deinit();
            allocator.destroy(self);
        }
    };

    allocator: std.mem.Allocator,
    world: ?*c.LilvWorld = null,
    instances: std.ArrayList(ManagedInstance),
    feature_context: *FeatureContext,
    instances_mutex: std.Thread.Mutex = .{},
    sample_rate_hz: u32 = 48_000,
    last_signature: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Lv2Runtime {
        return .{
            .allocator = allocator,
            .instances = std.ArrayList(ManagedInstance).empty,
            .feature_context = FeatureContext.init(allocator) catch @panic("failed to initialize LV2 feature context"),
        };
    }

    pub fn deinit(self: *Lv2Runtime) void {
        self.instances_mutex.lock();
        defer self.instances_mutex.unlock();
        self.clearInstances();
        self.instances.deinit(self.allocator);
        self.feature_context.deinit(self.allocator);
        if (self.world) |world| c.lilv_world_free(world);
    }

    pub fn sync(
        self: *Lv2Runtime,
        descriptors: []const host.PluginDescriptor,
        channel_plugins: []const chain.ChannelPlugin,
        channel_plugin_params: []const chain.ChannelPluginParam,
    ) !void {
        self.instances_mutex.lock();
        defer self.instances_mutex.unlock();

        const signature = computeSignature(channel_plugins, channel_plugin_params);
        if (signature == self.last_signature) return;

        try self.ensureWorld();

        var index = self.instances.items.len;
        while (index > 0) {
            index -= 1;
            if (!containsPlugin(channel_plugins, self.instances.items[index].plugin_id)) {
                var removed = self.instances.orderedRemove(index);
                removed.deinit(self.allocator);
            }
        }

        for (channel_plugins) |channel_plugin| {
            if (channel_plugin.backend != .lv2) continue;
            const descriptor = findDescriptor(descriptors, channel_plugin.descriptor_id) orelse continue;
            if (findInstance(self.instances.items, channel_plugin.id) == null) {
                var instance = self.instantiatePlugin(channel_plugin, descriptor, channel_plugin_params) catch |err| {
                    std.debug.print(
                        "lv2: skipping plugin '{s}' ({s}) on channel '{s}': {s}\n",
                        .{ channel_plugin.label, descriptor.id, channel_plugin.channel_id, @errorName(err) },
                    );
                    continue;
                };
                errdefer instance.deinit(self.allocator);
                try self.instances.append(self.allocator, instance);
            }
        }

        for (self.instances.items) |*instance| {
            applyControlValues(instance, descriptors, channel_plugins, channel_plugin_params);
            self.ensureActivated(instance);
            for (instance.atom_buffers) |atom_buffer| {
                clearAtomSequenceBuffer(
                    atom_buffer.bytes,
                    self.feature_context.atom_sequence_urid,
                    self.feature_context.atom_frame_time_urid,
                );
                if (!atom_buffer.is_output) {
                    writeInitialPatchGet(
                        atom_buffer.bytes,
                        self.feature_context.atom_object_urid,
                        self.feature_context.patch_get_urid,
                    );
                }
            }
        }

        std.mem.sort(ManagedInstance, self.instances.items, {}, sortManagedInstances);
        self.last_signature = signature;
    }

    pub fn processChannel(self: *Lv2Runtime, channel_id: []const u8, left: []f32, right: []f32) bool {
        self.instances_mutex.lock();
        defer self.instances_mutex.unlock();

        if (left.len == 0 or left.len != right.len) return false;
        if (left.len > max_block_size) return false;

        var scratch_left: [max_block_size]f32 = undefined;
        var scratch_right: [max_block_size]f32 = undefined;
        var temp_left: [max_block_size]f32 = undefined;
        var temp_right: [max_block_size]f32 = undefined;

        @memcpy(scratch_left[0..left.len], left);
        @memcpy(scratch_right[0..left.len], right);

        var processed_any = false;
        for (self.instances.items) |*instance| {
            if (!std.mem.eql(u8, instance.channel_id, channel_id)) continue;
            if (!instance.enabled and !instance.supports_plugin_state_sync) continue;
            self.ensureActivated(instance);
            if (!processStereoInstance(instance, scratch_left[0..left.len], scratch_right[0..right.len], temp_left[0..left.len], temp_right[0..right.len])) return false;
            @memcpy(scratch_left[0..left.len], temp_left[0..left.len]);
            @memcpy(scratch_right[0..right.len], temp_right[0..right.len]);
            processed_any = true;
        }
        if (!processed_any) return false;

        @memcpy(left, scratch_left[0..left.len]);
        @memcpy(right, scratch_right[0..right.len]);
        return true;
    }

    pub fn getUiRuntimeHandle(self: *Lv2Runtime, plugin_id: []const u8) ?UiRuntimeHandle {
        self.instances_mutex.lock();
        defer self.instances_mutex.unlock();

        for (self.instances.items) |*instance| {
            if (!std.mem.eql(u8, instance.plugin_id, plugin_id)) continue;
            return .{
                .instance = instance.instance,
                .features = &self.feature_context.feature_ptrs,
            };
        }
        return null;
    }

    pub fn setSampleRate(self: *Lv2Runtime, sample_rate_hz: u32) void {
        self.instances_mutex.lock();
        defer self.instances_mutex.unlock();

        if (sample_rate_hz == 0 or sample_rate_hz == self.sample_rate_hz) return;
        self.sample_rate_hz = sample_rate_hz;
        self.clearInstances();
    }

    pub fn channelLatencyFrames(self: *Lv2Runtime, channel_id: []const u8) u32 {
        _ = self;
        _ = channel_id;
        return 0;
    }

    fn clearInstances(self: *Lv2Runtime) void {
        for (self.instances.items) |*instance| instance.deinit(self.allocator);
        self.instances.clearRetainingCapacity();
        self.last_signature = 0;
    }

    fn ensureWorld(self: *Lv2Runtime) !void {
        if (self.world != null) return;
        const world = c.lilv_world_new() orelse return error.OutOfMemory;
        errdefer c.lilv_world_free(world);
        const search_roots = try lv2_discovery.collectSearchRoots(self.allocator);
        defer freeOwnedStrings(self.allocator, search_roots);
        const bundle_paths = try lv2_discovery.collectBundlePaths(self.allocator, search_roots);
        defer freeOwnedStrings(self.allocator, bundle_paths);

        c.lilv_world_load_specifications(world);
        for (bundle_paths) |bundle_path| {
            const bundle_path_z = try self.allocator.dupeZ(u8, bundle_path);
            defer self.allocator.free(bundle_path_z);
            const bundle_uri = c.lilv_new_file_uri(world, null, bundle_path_z.ptr) orelse continue;
            defer c.lilv_node_free(bundle_uri);
            c.lilv_world_load_bundle(world, bundle_uri);
        }
        self.world = world;
    }

    fn instantiatePlugin(
        self: *Lv2Runtime,
        channel_plugin: chain.ChannelPlugin,
        descriptor: host.PluginDescriptor,
        channel_plugin_params: []const chain.ChannelPluginParam,
    ) !ManagedInstance {
        const world = self.world orelse return error.MissingLilvWorld;
        const uri_z = try self.allocator.dupeZ(u8, descriptor.id);
        defer self.allocator.free(uri_z);
        const uri_node = c.lilv_new_uri(world, uri_z.ptr) orelse return error.OutOfMemory;
        defer c.lilv_node_free(uri_node);

        const plugins = c.lilv_world_get_all_plugins(world);
        const plugin = c.lilv_plugins_get_by_uri(plugins, uri_node) orelse return error.UnknownPluginDescriptor;
        const instance = c.lilv_plugin_instantiate(plugin, @floatFromInt(self.sample_rate_hz), @ptrCast(&self.feature_context.feature_ptrs)) orelse return error.PluginInstantiationFailed;
        errdefer c.lilv_instance_free(instance);

        const lv2_descriptor = instance.*.lv2_descriptor orelse return error.PluginMissingRunCallback;
        const run_fn = lv2_descriptor.*.run orelse return error.PluginMissingRunCallback;
        const lv2_handle = instance.*.lv2_handle;

        const port_count = c.lilv_plugin_get_num_ports(plugin);
        const port_values = try self.allocator.alloc(f32, port_count);
        errdefer self.allocator.free(port_values);
        @memset(port_values, 0.0);

        var audio_buffers = std.ArrayList([]f32).empty;
        errdefer {
            for (audio_buffers.items) |buffer| self.allocator.free(buffer);
            audio_buffers.deinit(self.allocator);
        }
        var output_control_port_indexes = std.ArrayList(u32).empty;
        errdefer output_control_port_indexes.deinit(self.allocator);
        var output_control_symbols = std.ArrayList([]u8).empty;
        errdefer {
            for (output_control_symbols.items) |symbol| self.allocator.free(symbol);
            output_control_symbols.deinit(self.allocator);
        }
        var audio_port_indexes = std.ArrayList(u32).empty;
        errdefer audio_port_indexes.deinit(self.allocator);
        var audio_port_is_output = std.ArrayList(bool).empty;
        errdefer audio_port_is_output.deinit(self.allocator);
        var atom_buffers = std.ArrayList(ManagedInstance.ManagedAtomBuffer).empty;
        errdefer {
            for (atom_buffers.items) |atom_buffer| self.allocator.free(atom_buffer.bytes);
            atom_buffers.deinit(self.allocator);
        }

        const audio_port_class = c.lilv_new_uri(world, c.LILV_URI_AUDIO_PORT) orelse return error.OutOfMemory;
        defer c.lilv_node_free(audio_port_class);
        const input_port_class = c.lilv_new_uri(world, c.LILV_URI_INPUT_PORT) orelse return error.OutOfMemory;
        defer c.lilv_node_free(input_port_class);
        const control_port_class = c.lilv_new_uri(world, c.LILV_URI_CONTROL_PORT) orelse return error.OutOfMemory;
        defer c.lilv_node_free(control_port_class);
        const atom_port_class = c.lilv_new_uri(world, c.LILV_URI_ATOM_PORT) orelse return error.OutOfMemory;
        defer c.lilv_node_free(atom_port_class);

        var port_index: u32 = 0;
        while (port_index < port_count) : (port_index += 1) {
            const port = c.lilv_plugin_get_port_by_index(plugin, port_index) orelse continue;
            if (c.lilv_port_is_a(plugin, port, control_port_class)) {
                port_values[port_index] = currentControlValue(descriptor, channel_plugin.id, port_index, channel_plugin_params);
                if (findControlPortByIndex(descriptor, port_index)) |control_port| {
                    if (control_port.is_output) {
                        try output_control_port_indexes.append(self.allocator, port_index);
                        try output_control_symbols.append(self.allocator, try self.allocator.dupe(u8, control_port.symbol));
                    }
                }
                c.lilv_instance_connect_port(instance, port_index, &port_values[port_index]);
                continue;
            }
            if (c.lilv_port_is_a(plugin, port, audio_port_class)) {
                const buffer = try self.allocator.alloc(f32, max_block_size);
                @memset(buffer, 0.0);
                try audio_buffers.append(self.allocator, buffer);
                try audio_port_indexes.append(self.allocator, port_index);
                try audio_port_is_output.append(self.allocator, !c.lilv_port_is_a(plugin, port, input_port_class));
                c.lilv_instance_connect_port(instance, port_index, buffer.ptr);
                continue;
            }
            if (c.lilv_port_is_a(plugin, port, atom_port_class)) {
                const capacity: usize = 16 * 1024;
                const bytes = try self.allocator.alignedAlloc(
                    u8,
                    std.mem.Alignment.fromByteUnits(@alignOf(c.LV2_Atom_Sequence)),
                    capacity,
                );
                clearAtomSequenceBuffer(
                    bytes,
                    self.feature_context.atom_sequence_urid,
                    self.feature_context.atom_frame_time_urid,
                );
                const is_output = !c.lilv_port_is_a(plugin, port, input_port_class);
                if (!is_output) {
                    writeInitialPatchGet(
                        bytes,
                        self.feature_context.atom_object_urid,
                        self.feature_context.patch_get_urid,
                    );
                }
                try atom_buffers.append(self.allocator, .{
                    .port_index = port_index,
                    .is_output = is_output,
                    .bytes = bytes,
                });
                c.lilv_instance_connect_port(instance, port_index, bytes.ptr);
                continue;
            }
        }

        return .{
            .plugin_id = try self.allocator.dupe(u8, channel_plugin.id),
            .channel_id = try self.allocator.dupe(u8, channel_plugin.channel_id),
            .descriptor_id = try self.allocator.dupe(u8, descriptor.id),
            .slot = channel_plugin.slot,
            .enabled = channel_plugin.enabled,
            .supports_plugin_state_sync = descriptorSupportsPluginStateSync(descriptor),
            .instance = instance,
            .lv2_handle = lv2_handle,
            .run_fn = run_fn,
            .activated = false,
            .port_values = port_values,
            .output_control_port_indexes = try output_control_port_indexes.toOwnedSlice(self.allocator),
            .output_control_symbols = try output_control_symbols.toOwnedSlice(self.allocator),
            .audio_buffers = try audio_buffers.toOwnedSlice(self.allocator),
            .audio_port_indexes = try audio_port_indexes.toOwnedSlice(self.allocator),
            .audio_port_is_output = try audio_port_is_output.toOwnedSlice(self.allocator),
            .atom_buffers = try atom_buffers.toOwnedSlice(self.allocator),
        };
    }

    fn freeOwnedStrings(allocator: std.mem.Allocator, items: [][]u8) void {
        for (items) |item| allocator.free(item);
        allocator.free(items);
    }

    fn ensureActivated(self: *Lv2Runtime, instance: *ManagedInstance) void {
        _ = self;
        if (instance.activated) return;
        c.lilv_instance_activate(instance.instance);
        instance.activated = true;
    }

    fn uridMapCallback(handle: c.LV2_URID_Map_Handle, uri: [*c]const u8) callconv(.c) c.LV2_URID {
        const store: *UridMapStore = @ptrCast(@alignCast(handle));
        if (uri == null) return 0;
        return store.map(std.mem.span(uri));
    }

    fn uridUnmapCallback(handle: c.LV2_URID_Unmap_Handle, urid: c.LV2_URID) callconv(.c) ?[*:0]const u8 {
        const store: *UridMapStore = @ptrCast(@alignCast(handle));
        return store.unmap(urid);
    }
} else struct {
    pub const UiRuntimeHandle = struct {
        instance: *anyopaque,
        features: [*]const ?*const anyopaque,
    };

    pub fn init(allocator: std.mem.Allocator) Lv2Runtime {
        _ = allocator;
        return .{};
    }

    pub fn deinit(self: *Lv2Runtime) void {
        _ = self;
    }

    pub fn sync(
        self: *Lv2Runtime,
        descriptors: []const host.PluginDescriptor,
        channel_plugins: []const chain.ChannelPlugin,
        channel_plugin_params: []const chain.ChannelPluginParam,
    ) !void {
        _ = self;
        _ = descriptors;
        _ = channel_plugins;
        _ = channel_plugin_params;
    }

    pub fn processChannel(self: *Lv2Runtime, channel_id: []const u8, left: []f32, right: []f32) bool {
        _ = self;
        _ = channel_id;
        _ = left;
        _ = right;
        return false;
    }

    pub fn setSampleRate(self: *Lv2Runtime, sample_rate_hz: u32) void {
        _ = self;
        _ = sample_rate_hz;
    }

    pub fn writeUiUpdateLines(self: *Lv2Runtime, plugin_id: []const u8, writer: anytype) !u64 {
        _ = self;
        _ = plugin_id;
        _ = writer;
        return 0;
    }

    pub fn getUiRuntimeHandle(self: *Lv2Runtime, plugin_id: []const u8) ?UiRuntimeHandle {
        _ = self;
        _ = plugin_id;
        return null;
    }

    pub fn channelLatencyFrames(self: *Lv2Runtime, channel_id: []const u8) u32 {
        _ = self;
        _ = channel_id;
        return 0;
    }
};

fn computeSignature(channel_plugins: []const chain.ChannelPlugin, channel_plugin_params: []const chain.ChannelPluginParam) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (channel_plugins) |channel_plugin| {
        hasher.update(channel_plugin.id);
        hasher.update(channel_plugin.descriptor_id);
        hasher.update(channel_plugin.channel_id);
        hasher.update(&[_]u8{
            @intFromBool(channel_plugin.enabled),
            @intCast(channel_plugin.slot & 0xff),
        });
    }
    for (channel_plugin_params) |channel_plugin_param| {
        hasher.update(channel_plugin_param.plugin_id);
        hasher.update(channel_plugin_param.symbol);
        hasher.update(std.mem.asBytes(&channel_plugin_param.value));
    }
    return hasher.final();
}

fn containsPlugin(channel_plugins: []const chain.ChannelPlugin, plugin_id: []const u8) bool {
    for (channel_plugins) |channel_plugin| {
        if (channel_plugin.backend == .lv2 and std.mem.eql(u8, channel_plugin.id, plugin_id)) return true;
    }
    return false;
}

fn findDescriptor(descriptors: []const host.PluginDescriptor, descriptor_id: []const u8) ?host.PluginDescriptor {
    for (descriptors) |descriptor| {
        if (std.mem.eql(u8, descriptor.id, descriptor_id)) return descriptor;
    }
    return null;
}

fn findInstance(items: anytype, plugin_id: []const u8) ?usize {
    for (items, 0..) |item, index| {
        if (std.mem.eql(u8, item.plugin_id, plugin_id)) return index;
    }
    return null;
}

fn currentControlValue(
    descriptor: host.PluginDescriptor,
    plugin_id: []const u8,
    port_index: u32,
    channel_plugin_params: []const chain.ChannelPluginParam,
) f32 {
    for (descriptor.control_ports) |control_port| {
        if (control_port.index != port_index) continue;
        for (channel_plugin_params) |channel_plugin_param| {
            if (std.mem.eql(u8, channel_plugin_param.plugin_id, plugin_id) and std.mem.eql(u8, channel_plugin_param.symbol, control_port.symbol)) {
                return channel_plugin_param.value;
            }
        }
        return control_port.default_value;
    }
    return 0.0;
}

fn findControlPortByIndex(descriptor: host.PluginDescriptor, port_index: u32) ?host.PluginControlPort {
    for (descriptor.control_ports) |control_port| {
        if (control_port.index == port_index) return control_port;
    }
    return null;
}

fn applyControlValues(instance: anytype, descriptors: []const host.PluginDescriptor, channel_plugins: []const chain.ChannelPlugin, channel_plugin_params: []const chain.ChannelPluginParam) void {
    const descriptor = findDescriptor(descriptors, instance.descriptor_id) orelse return;
    const channel_plugin = findChannelPlugin(channel_plugins, instance.plugin_id) orelse return;
    instance.enabled = channel_plugin.enabled;
    instance.slot = channel_plugin.slot;
    for (descriptor.control_ports) |control_port| {
        if (control_port.is_output) continue;
        const value = switch (control_port.sync_kind) {
            .plugin_enabled => syncedToggleValue(control_port, channel_plugin.enabled),
            .plugin_bypass => syncedToggleValue(control_port, !channel_plugin.enabled),
            .none => currentControlValue(descriptor, instance.plugin_id, control_port.index, channel_plugin_params),
        };
        instance.port_values[control_port.index] = value;
    }
}

fn descriptorSupportsPluginStateSync(descriptor: host.PluginDescriptor) bool {
    for (descriptor.control_ports) |control_port| {
        if (control_port.sync_kind != .none and !control_port.is_output) return true;
    }
    return false;
}

fn findChannelPlugin(channel_plugins: []const chain.ChannelPlugin, plugin_id: []const u8) ?chain.ChannelPlugin {
    for (channel_plugins) |channel_plugin| {
        if (std.mem.eql(u8, channel_plugin.id, plugin_id)) return channel_plugin;
    }
    return null;
}

fn syncedToggleValue(control_port: host.PluginControlPort, enabled: bool) f32 {
    const low = std.math.clamp(0.0, control_port.min_value, control_port.max_value);
    const high = std.math.clamp(1.0, control_port.min_value, control_port.max_value);
    return if (enabled) high else low;
}

fn sortManagedInstances(_: void, lhs: Lv2Runtime.ManagedInstance, rhs: Lv2Runtime.ManagedInstance) bool {
    const channel_cmp = std.mem.order(u8, lhs.channel_id, rhs.channel_id);
    if (channel_cmp != .eq) return channel_cmp == .lt;
    if (lhs.slot != rhs.slot) return lhs.slot < rhs.slot;
    return pluginNumericSuffix(lhs.plugin_id) < pluginNumericSuffix(rhs.plugin_id);
}

fn pluginNumericSuffix(plugin_id: []const u8) u32 {
    const prefix = "plugin-";
    if (!std.mem.startsWith(u8, plugin_id, prefix)) return 0;
    return std.fmt.parseInt(u32, plugin_id[prefix.len..], 10) catch 0;
}

fn processStereoInstance(
    instance: *Lv2Runtime.ManagedInstance,
    in_left: []const f32,
    in_right: []const f32,
    out_left: []f32,
    out_right: []f32,
) bool {
    if (in_left.len != in_right.len or in_left.len != out_left.len or in_left.len != out_right.len) return false;
    if (instance.audio_buffers.len == 0) return false;

    const audio_len = in_left.len;
    var output_slot: usize = 0;

    var processed: usize = 0;
    while (processed < audio_len) {
        const frames = @min(Lv2Runtime.preferred_block_size, audio_len - processed);
        prepareOutputBuffers(instance);
        loadProcessingWindow(instance, in_left, in_right, processed, frames);
        instance.run_fn(instance.lv2_handle, @intCast(frames));
        storeProcessingWindow(instance, out_left, out_right, processed, frames, &output_slot);
        processed += frames;
    }

    if (output_slot == 0) {
        @memcpy(out_left, in_left);
        @memcpy(out_right, in_right);
    } else if (output_slot == 1) {
        @memcpy(out_right, out_left);
    }
    return true;
}

fn prepareOutputBuffers(instance: *Lv2Runtime.ManagedInstance) void {
    for (instance.audio_buffers, 0..) |buffer, index| {
        if (instance.audio_port_is_output[index]) @memset(buffer, 0.0);
    }
}

fn loadProcessingWindow(instance: *Lv2Runtime.ManagedInstance, in_left: []const f32, in_right: []const f32, offset: usize, frames: usize) void {
    var input_slot: usize = 0;
    for (instance.audio_buffers, 0..) |buffer, index| {
        if (instance.audio_port_is_output[index]) continue;
        @memset(buffer, 0.0);
        const dest = buffer[0..frames];
        switch (input_slot) {
            0 => @memcpy(dest, in_left[offset .. offset + frames]),
            1 => @memcpy(dest, in_right[offset .. offset + frames]),
            else => {},
        }
        input_slot += 1;
    }
}

fn storeProcessingWindow(
    instance: *Lv2Runtime.ManagedInstance,
    out_left: []f32,
    out_right: []f32,
    offset: usize,
    frames: usize,
    output_slot_counter: *usize,
) void {
    var local_output_slot: usize = 0;
    for (instance.audio_buffers, 0..) |buffer, index| {
        if (!instance.audio_port_is_output[index]) continue;
        switch (local_output_slot) {
            0 => @memcpy(out_left[offset .. offset + frames], buffer[0..frames]),
            1 => @memcpy(out_right[offset .. offset + frames], buffer[0..frames]),
            else => {},
        }
        local_output_slot += 1;
    }
    output_slot_counter.* = local_output_slot;
}

fn clearAtomSequenceBuffer(
    bytes: []align(@alignOf(lv2_c.LV2_Atom_Sequence)) u8,
    sequence_urid: lv2_c.LV2_URID,
    frame_time_urid: lv2_c.LV2_URID,
) void {
    const sequence: *lv2_c.LV2_Atom_Sequence = @ptrCast(@alignCast(bytes.ptr));
    @memset(bytes, 0);
    sequence.atom.type = sequence_urid;
    sequence.atom.size = @sizeOf(lv2_c.LV2_Atom_Sequence_Body);
    sequence.body.unit = frame_time_urid;
    sequence.body.pad = 0;
}

fn writeInitialPatchGet(
    bytes: []align(@alignOf(lv2_c.LV2_Atom_Sequence)) u8,
    atom_object_urid: lv2_c.LV2_URID,
    patch_get_urid: lv2_c.LV2_URID,
) void {
    if (bytes.len < @sizeOf(lv2_c.LV2_Atom_Sequence) + @sizeOf(lv2_c.LV2_Atom_Event) + @sizeOf(lv2_c.LV2_Atom_Object_Body)) {
        return;
    }

    const sequence: *lv2_c.LV2_Atom_Sequence = @ptrCast(@alignCast(bytes.ptr));
    const event_ptr: [*]u8 = bytes.ptr + @sizeOf(lv2_c.LV2_Atom_Sequence);
    const event: *lv2_c.LV2_Atom_Event = @ptrCast(@alignCast(event_ptr));
    const object_body_ptr: [*]u8 = event_ptr + @sizeOf(lv2_c.LV2_Atom_Event);
    const object_body: *lv2_c.LV2_Atom_Object_Body = @ptrCast(@alignCast(object_body_ptr));

    event.time.frames = 0;
    event.body.type = atom_object_urid;
    event.body.size = @sizeOf(lv2_c.LV2_Atom_Object_Body);
    object_body.id = 0;
    object_body.otype = patch_get_urid;
    sequence.atom.size = @sizeOf(lv2_c.LV2_Atom_Sequence_Body) + @sizeOf(lv2_c.LV2_Atom_Event) + @sizeOf(lv2_c.LV2_Atom_Object_Body);
}

fn atomSequenceUsedBytes(bytes: []align(@alignOf(lv2_c.LV2_Atom_Sequence)) u8) ?[]const u8 {
    if (bytes.len < @sizeOf(lv2_c.LV2_Atom)) return null;
    const atom: *const lv2_c.LV2_Atom = @ptrCast(@alignCast(bytes.ptr));
    const total_size = @sizeOf(lv2_c.LV2_Atom) + atom.size;
    if (total_size > bytes.len) return null;
    return bytes[0..total_size];
}
