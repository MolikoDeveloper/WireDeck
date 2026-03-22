const std = @import("std");
const c = @cImport({
    @cInclude("lv2/core/lv2.h");
    @cInclude("wiredeck_cuda_denoiser_shared.h");
});

extern fn lv2_descriptor(index: u32) ?*const c.LV2_Descriptor;

const InputMode = enum {
    dual_mono,
    left_only,
};

const Scenario = struct {
    sample_rate_hz: f64,
    block_size: u32,
    input_mode: InputMode,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const bundle_path = try resolveBundlePath(allocator);
    defer allocator.free(bundle_path);

    const scenarios = [_]Scenario{
        .{ .sample_rate_hz = 48_000.0, .block_size = 64, .input_mode = .dual_mono },
        .{ .sample_rate_hz = 48_000.0, .block_size = 64, .input_mode = .left_only },
        .{ .sample_rate_hz = 48_000.0, .block_size = 128, .input_mode = .dual_mono },
        .{ .sample_rate_hz = 48_000.0, .block_size = 128, .input_mode = .left_only },
        .{ .sample_rate_hz = 48_000.0, .block_size = 256, .input_mode = .dual_mono },
        .{ .sample_rate_hz = 48_000.0, .block_size = 256, .input_mode = .left_only },
        .{ .sample_rate_hz = 44_100.0, .block_size = 128, .input_mode = .dual_mono },
        .{ .sample_rate_hz = 44_100.0, .block_size = 128, .input_mode = .left_only },
    };

    std.debug.print("wiredeck cuda rt harness\nbundle={s}\n\n", .{bundle_path});
    for (scenarios) |scenario| {
        try runScenario(allocator, bundle_path, scenario);
    }
}

fn resolveBundlePath(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "WIREDECK_RT_HARNESS_BUNDLE")) |value| {
        return value;
    } else |_| {}

    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return allocator.dupe(u8, "src/lv2_plugins/wiredeck_cuda_denoiser.bundle");
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.lv2/wiredeck-cuda-denoiser.lv2", .{home});
}

fn runScenario(
    allocator: std.mem.Allocator,
    bundle_path: []const u8,
    scenario: Scenario,
) !void {
    const descriptor = lv2_descriptor(0) orelse return error.MissingPluginDescriptor;
    const instantiate = descriptor.*.instantiate orelse return error.MissingInstantiate;
    const connect_port = descriptor.*.connect_port orelse return error.MissingConnectPort;
    const run = descriptor.*.run orelse return error.MissingRun;
    const cleanup = descriptor.*.cleanup orelse return error.MissingCleanup;
    const activate = descriptor.*.activate;
    const deactivate = descriptor.*.deactivate;

    var enabled: f32 = 1.0;
    var reduction: f32 = 0.8;
    var buffer_ms: f32 = 12.0;
    var mix: f32 = 1.0;
    var output_gain_db: f32 = 0.0;
    var gpu_index: f32 = 0.0;
    var model_index: f32 = 0.0;
    var cuda_available: f32 = 0.0;
    var gpu_count: f32 = 0.0;
    var model_count: f32 = 0.0;
    var status_code: f32 = 0.0;
    var input_level: f32 = 0.0;
    var output_level: f32 = 0.0;
    var model_loaded: f32 = 0.0;
    var runtime_phase: f32 = 0.0;

    const input_l = try allocator.alloc(f32, scenario.block_size);
    defer allocator.free(input_l);
    const input_r = try allocator.alloc(f32, scenario.block_size);
    defer allocator.free(input_r);
    const output_l = try allocator.alloc(f32, scenario.block_size);
    defer allocator.free(output_l);
    const output_r = try allocator.alloc(f32, scenario.block_size);
    defer allocator.free(output_r);

    const seconds_to_run: f64 = 2.0;
    const total_frames = @as(u64, @intFromFloat(scenario.sample_rate_hz * seconds_to_run));
    const call_count = @as(usize, @intCast((total_frames + scenario.block_size - 1) / scenario.block_size));
    const timings_ns = try allocator.alloc(u64, call_count);
    defer allocator.free(timings_ns);

    const bundle_path_z = try allocator.dupeZ(u8, bundle_path);
    defer allocator.free(bundle_path_z);

    const instance = instantiate(descriptor, scenario.sample_rate_hz, bundle_path_z.ptr, null) orelse return error.InstantiateFailed;
    defer cleanup(instance);

    connect_port(instance, c.WD_PORT_ENABLED, &enabled);
    connect_port(instance, c.WD_PORT_THRESHOLD, &reduction);
    connect_port(instance, c.WD_PORT_BUFFER_MS, &buffer_ms);
    connect_port(instance, c.WD_PORT_MIX, &mix);
    connect_port(instance, c.WD_PORT_OUTPUT_GAIN_DB, &output_gain_db);
    connect_port(instance, c.WD_PORT_GPU_INDEX, &gpu_index);
    connect_port(instance, c.WD_PORT_MODEL_INDEX, &model_index);
    connect_port(instance, c.WD_PORT_CUDA_AVAILABLE, &cuda_available);
    connect_port(instance, c.WD_PORT_GPU_COUNT, &gpu_count);
    connect_port(instance, c.WD_PORT_MODEL_COUNT, &model_count);
    connect_port(instance, c.WD_PORT_STATUS_CODE, &status_code);
    connect_port(instance, c.WD_PORT_INPUT_LEVEL, &input_level);
    connect_port(instance, c.WD_PORT_OUTPUT_LEVEL, &output_level);
    connect_port(instance, c.WD_PORT_MODEL_LOADED, &model_loaded);
    connect_port(instance, c.WD_PORT_RUNTIME_PHASE, &runtime_phase);
    connect_port(instance, c.WD_PORT_INPUT_L, input_l.ptr);
    connect_port(instance, c.WD_PORT_INPUT_R, input_r.ptr);
    connect_port(instance, c.WD_PORT_OUTPUT_L, output_l.ptr);
    connect_port(instance, c.WD_PORT_OUTPUT_R, output_r.ptr);

    if (activate) |activate_fn| {
        activate_fn(instance);
    }
    defer {
        if (deactivate) |deactivate_fn| {
            deactivate_fn(instance);
        }
    }

    {
        var warmup_step: usize = 0;
        while (warmup_step < 200 and model_loaded < 0.5 and status_code != @as(f32, @floatFromInt(c.WD_STATUS_SAMPLE_RATE_MISMATCH))) : (warmup_step += 1) {
            fillInputBlock(input_l, input_r, 0, scenario, null);
            run(instance, scenario.block_size);
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    var prng = std.Random.DefaultPrng.init(0x5eed1234);
    var random = prng.random();
    var frame_cursor: u64 = 0;
    var total_elapsed_ns: u128 = 0;
    var max_elapsed_ns: u64 = 0;
    var overrun_count: usize = 0;
    const deadline_ns = @as(u64, @intFromFloat((@as(f64, @floatFromInt(scenario.block_size)) * std.time.ns_per_s) / scenario.sample_rate_hz));

    for (timings_ns, 0..) |*timing, call_index| {
        _ = call_index;
        fillInputBlock(input_l, input_r, frame_cursor, scenario, &random);
        const start_ns = std.time.nanoTimestamp();
        run(instance, scenario.block_size);
        const elapsed_ns = @as(u64, @intCast(std.time.nanoTimestamp() - start_ns));
        timing.* = elapsed_ns;
        total_elapsed_ns += elapsed_ns;
        if (elapsed_ns > max_elapsed_ns) {
            max_elapsed_ns = elapsed_ns;
        }
        if (elapsed_ns > deadline_ns) {
            overrun_count += 1;
        }
        frame_cursor += scenario.block_size;
    }

    const average_elapsed_ns = if (timings_ns.len == 0) 0 else @as(u64, @intCast(total_elapsed_ns / timings_ns.len));
    std.debug.print(
        "sr={d} block={d} mode={s} calls={d} deadline_ns={d} avg_ns={d} max_ns={d} overruns={d} status={d} phase={d} loaded={d}\n",
        .{
            @as(u32, @intFromFloat(scenario.sample_rate_hz)),
            scenario.block_size,
            inputModeLabel(scenario.input_mode),
            timings_ns.len,
            deadline_ns,
            average_elapsed_ns,
            max_elapsed_ns,
            overrun_count,
            @as(i32, @intFromFloat(status_code)),
            @as(i32, @intFromFloat(runtime_phase)),
            @as(i32, @intFromFloat(model_loaded)),
        },
    );
}

fn fillInputBlock(
    input_l: []f32,
    input_r: []f32,
    frame_cursor: u64,
    scenario: Scenario,
    random: ?*std.Random,
) void {
    const two_pi = 2.0 * std.math.pi;
    for (input_l, input_r, 0..) |*left, *right, sample_index| {
        const frame_index = frame_cursor + sample_index;
        const t = @as(f64, @floatFromInt(frame_index)) / scenario.sample_rate_hz;
        const voice = 0.14 * std.math.sin(two_pi * 220.0 * t);
        const random_noise = if (random) |value| (value.float(f32) - 0.5) * 0.02 else 0.0;
        const noise = 0.03 * std.math.sin(two_pi * 1777.0 * t) + random_noise;
        const sample = @as(f32, @floatCast(voice + noise));
        left.* = sample;
        right.* = switch (scenario.input_mode) {
            .dual_mono => sample,
            .left_only => 0.0,
        };
    }
}

fn inputModeLabel(mode: InputMode) []const u8 {
    return switch (mode) {
        .dual_mono => "dual-mono",
        .left_only => "left-only",
    };
}
