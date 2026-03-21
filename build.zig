const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});
    const enable_lilv = b.option(bool, "enable-lilv", "Enable Lilv-backed LV2 discovery") orelse false;
    const enable_suil = b.option(bool, "enable-suil", "Enable GTK2/Suil LV2 custom UI hosting") orelse false;

    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_lilv", enable_lilv);
    build_options.addOption(bool, "enable_suil", enable_suil);

    const mod = b.addModule("wiredeck", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "build_options", .module = build_options.createModule() },
        },
    });

    const exe = b.addExecutable(.{
        .name = "wiredeck",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wiredeck", .module = mod },
            },
        }),
    });

    if (enable_lilv and enable_suil) {
        const helper = b.addExecutable(.{
            .name = "wiredeck-lv2-ui-host",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/lv2_ui_host_main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        helper.linkLibC();
        helper.linkSystemLibrary("lilv-0");
        helper.linkSystemLibrary("suil-0");
        helper.linkSystemLibrary("gtk+-2.0");
        helper.linkSystemLibrary("gtk+-x11-2.0");
        helper.linkSystemLibrary("x11");
        b.installArtifact(helper);
    }

    if (enable_lilv and enable_suil) {
        const plugin_lib = b.addLibrary(.{
            .name = "wiredeck_cuda_denoiser",
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        plugin_lib.addIncludePath(b.path("src/lv2_plugins/wiredeck_cuda_denoiser"));
        plugin_lib.addCSourceFiles(.{
            .files = &.{
                "src/lv2_plugins/wiredeck_cuda_denoiser/wiredeck_cuda_denoiser.c",
                "src/lv2_plugins/wiredeck_cuda_denoiser/cuda_probe.c",
                "src/lv2_plugins/wiredeck_cuda_denoiser/cuda_backend.c",
                "src/lv2_plugins/wiredeck_cuda_denoiser/cuda_session.c",
                "src/lv2_plugins/wiredeck_cuda_denoiser/config_store.c",
                "src/lv2_plugins/wiredeck_cuda_denoiser/inference_frontend.c",
                "src/lv2_plugins/wiredeck_cuda_denoiser/shared_runtime_cache.c",
                "src/lv2_plugins/wiredeck_cuda_denoiser/wdgp_runtime.c",
            },
            .flags = &.{ "-std=c99", "-Wno-deprecated-declarations" },
        });
        plugin_lib.linkSystemLibrary("dl");
        plugin_lib.linkSystemLibrary("pthread");
        b.installArtifact(plugin_lib);

        const plugin_ui_lib = b.addLibrary(.{
            .name = "wiredeck_cuda_denoiser_ui",
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        plugin_ui_lib.addIncludePath(b.path("src/lv2_plugins/wiredeck_cuda_denoiser"));
        plugin_ui_lib.addCSourceFiles(.{
            .files = &.{
                "src/lv2_plugins/wiredeck_cuda_denoiser/wiredeck_cuda_denoiser_ui.c",
                "src/lv2_plugins/wiredeck_cuda_denoiser/cuda_probe.c",
                "src/lv2_plugins/wiredeck_cuda_denoiser/cuda_backend.c",
                "src/lv2_plugins/wiredeck_cuda_denoiser/cuda_session.c",
                "src/lv2_plugins/wiredeck_cuda_denoiser/config_store.c",
                "src/lv2_plugins/wiredeck_cuda_denoiser/shared_runtime_cache.c",
                "src/lv2_plugins/wiredeck_cuda_denoiser/wdgp_runtime.c",
            },
            .flags = &.{ "-std=c99", "-Wno-deprecated-declarations" },
        });
        plugin_ui_lib.linkSystemLibrary("dl");
        plugin_ui_lib.linkSystemLibrary("pthread");
        plugin_ui_lib.linkSystemLibrary("gtk+-2.0");
        plugin_ui_lib.linkSystemLibrary("gtk+-x11-2.0");
        plugin_ui_lib.linkSystemLibrary("x11");
        b.installArtifact(plugin_ui_lib);
    }

    b.installArtifact(exe);
    mod.link_libc = true;
    mod.link_libcpp = true;
    mod.linkSystemLibrary("pipewire-0.3", .{ .needed = true });
    mod.linkSystemLibrary("spa-0.2", .{ .needed = true });
    mod.linkSystemLibrary("pulse", .{ .needed = true });
    mod.linkSystemLibrary("vulkan", .{ .needed = true });
    if (enable_lilv) {
        mod.linkSystemLibrary("lilv-0", .{ .needed = true });
    }

    linkStaticSdl(b, mod);
    linkStaticPkgRootWithDynamicPrivate(mod, "png16", "libpng", &.{"png16"});
    linkStaticPkgRootWithDynamicPrivate(mod, "MagickWand", "MagickWand", &.{
        "MagickWand",
        "MagickWand-6.Q16",
        "MagickCore",
        "MagickCore-6.Q16",
    });
    linkStaticPkgRootWithDynamicPrivate(mod, "MagickCore", "MagickCore", &.{
        "MagickCore",
        "MagickCore-6.Q16",
    });

    mod.addIncludePath(b.path("src/native"));
    mod.addIncludePath(b.path("src/core/pipewire"));
    mod.addIncludePath(b.path("vendor/cimgui/imgui"));
    mod.addIncludePath(b.path("vendor/cimgui/imgui/backends"));

    mod.addCSourceFiles(.{
        .files = &.{
            "src/native/imgui_bridge.cpp",
            "vendor/cimgui/imgui/imgui.cpp",
            "vendor/cimgui/imgui/imgui_draw.cpp",
            "vendor/cimgui/imgui/imgui_tables.cpp",
            "vendor/cimgui/imgui/imgui_widgets.cpp",
            "vendor/cimgui/imgui/backends/imgui_impl_sdl3.cpp",
            "vendor/cimgui/imgui/backends/imgui_impl_vulkan.cpp",
        },
        .flags = &.{"-std=c++17"},
    });
    mod.addCSourceFile(.{
        .file = b.path("src/core/pipewire/spa_helpers.c"),
    });

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    if (enable_lilv) {
        mod_tests.linkSystemLibrary("lilv-0");
        exe_tests.linkSystemLibrary("lilv-0");
    }

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}

fn linkStaticSdl(b: *std.Build, mod: *std.Build.Module) void {
    mod.addIncludePath(b.path(".cache/sdl3-prefix/include"));
    mod.addLibraryPath(b.path(".cache/sdl3-prefix/lib"));
    if (pathExists(".cache/sdl3-prefix/lib64")) {
        mod.addLibraryPath(b.path(".cache/sdl3-prefix/lib64"));
    }
    mod.linkSystemLibrary("SDL3", .{
        .needed = true,
        .use_pkg_config = .no,
        .preferred_link_mode = .static,
        .search_strategy = .mode_first,
    });
    linkDynamicPrivatePkgLibs(mod, "sdl3", &.{"SDL3"});
}

fn linkStaticPkgRootWithDynamicPrivate(
    mod: *std.Build.Module,
    root_lib_name: []const u8,
    pkg_name: []const u8,
    skip_libs: []const []const u8,
) void {
    mod.linkSystemLibrary(root_lib_name, .{
        .needed = true,
        .preferred_link_mode = .static,
        .search_strategy = .mode_first,
    });
    linkDynamicPrivatePkgLibs(mod, pkg_name, skip_libs);
}

fn linkDynamicPrivatePkgLibs(
    mod: *std.Build.Module,
    pkg_name: []const u8,
    skip_libs: []const []const u8,
) void {
    const allocator = mod.owner.allocator;
    const output = pkgConfigQuery(allocator, &.{ pkg_name, "--libs", "--static" }) catch return;
    defer allocator.free(output);

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    var tokens = std.mem.tokenizeAny(u8, output, " \r\n\t");
    while (tokens.next()) |token| {
        if (std.mem.eql(u8, token, "-L")) {
            const path = tokens.next() orelse break;
            mod.addLibraryPath(.{ .cwd_relative = path });
            continue;
        }
        if (std.mem.startsWith(u8, token, "-L")) {
            mod.addLibraryPath(.{ .cwd_relative = token["-L".len..] });
            continue;
        }
        if (std.mem.eql(u8, token, "-l")) {
            const lib_name = tokens.next() orelse break;
            linkDynamicSystemLibUnlessSkipped(mod, &seen, lib_name, skip_libs);
            continue;
        }
        if (std.mem.startsWith(u8, token, "-l")) {
            linkDynamicSystemLibUnlessSkipped(mod, &seen, token["-l".len..], skip_libs);
            continue;
        }
        if (std.mem.eql(u8, token, "-pthread")) {
            linkDynamicSystemLibUnlessSkipped(mod, &seen, "pthread", skip_libs);
        }
    }
}

fn linkDynamicSystemLibUnlessSkipped(
    mod: *std.Build.Module,
    seen: *std.StringHashMap(void),
    lib_name: []const u8,
    skip_libs: []const []const u8,
) void {
    for (skip_libs) |skip_lib| {
        if (std.mem.eql(u8, lib_name, skip_lib)) return;
    }
    const entry = seen.getOrPut(lib_name) catch @panic("OOM");
    if (entry.found_existing) return;
    if (tryLinkVersionedSharedObject(mod, lib_name)) return;
    mod.linkSystemLibrary(lib_name, .{
        .preferred_link_mode = .dynamic,
        .search_strategy = .mode_first,
    });
}

fn tryLinkVersionedSharedObject(mod: *std.Build.Module, lib_name: []const u8) bool {
    const candidates = versionedSharedObjectCandidates(lib_name) orelse return false;
    for (candidates) |candidate| {
        if (!pathExistsAbsolute(candidate)) continue;
        mod.addObjectFile(.{ .cwd_relative = candidate });
        return true;
    }
    return false;
}

fn versionedSharedObjectCandidates(lib_name: []const u8) ?[]const []const u8 {
    if (std.mem.eql(u8, lib_name, "fftw3")) {
        return &.{
            "/lib/x86_64-linux-gnu/libfftw3.so.3",
            "/usr/lib/x86_64-linux-gnu/libfftw3.so.3",
        };
    }
    if (std.mem.eql(u8, lib_name, "gomp")) {
        return &.{
            "/lib/x86_64-linux-gnu/libgomp.so.1",
            "/usr/lib/x86_64-linux-gnu/libgomp.so.1",
            "/usr/lib/gcc/x86_64-linux-gnu/14/libgomp.so",
            "/usr/lib/gcc/x86_64-linux-gnu/13/libgomp.so",
            "/usr/lib/gcc/x86_64-linux-gnu/12/libgomp.so",
        };
    }
    return null;
}

fn pathExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn pathExistsAbsolute(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn pkgConfigQuery(allocator: std.mem.Allocator, args: []const []const u8) ![]u8 {
    const argv = try allocator.alloc([]const u8, args.len + 1);
    defer allocator.free(argv);
    argv[0] = "pkg-config";
    @memcpy(argv[1..], args);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    });
    defer allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| {
            if (code != 0) return error.PkgConfigFailed;
        },
        else => return error.PkgConfigFailed,
    }
    return result.stdout;
}
