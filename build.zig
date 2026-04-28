const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = @import("builtin").cpu.arch,
            .os_tag = .windows,
            .abi = .gnu,
        },
        .whitelist = &.{
            .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
            .{ .cpu_arch = .aarch64, .os_tag = .windows, .abi = .gnu },
            .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
            .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
        },
    });

    switch (target.result.os.tag) {
        .windows => buildWindows(b, target, optimize),
        .linux => buildLinux(b, target, optimize),
        else => @panic("unsupported OS"),
    }
}

fn buildWindows(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/platform/windows/Entry.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
        .strip = (optimize == .ReleaseSmall),
    });

    exe_mod.linkSystemLibrary("c", .{});
    exe_mod.linkSystemLibrary("gdi32", .{});
    exe_mod.linkSystemLibrary("user32", .{});
    exe_mod.linkSystemLibrary("Shell32", .{});
    exe_mod.linkSystemLibrary("kernel32", .{});
    exe_mod.linkSystemLibrary("ComCtl32", .{});
    exe_mod.linkSystemLibrary("Ole32", .{});
    exe_mod.linkSystemLibrary("Shlwapi", .{});
    exe_mod.linkSystemLibrary("Dwmapi", .{});

    const exe = b.addExecutable(.{
        .name = "vitrail",
        .root_module = exe_mod,
        .win32_manifest = b.path("src/app.manifest"),
    });
    exe.subsystem = .Windows;
    exe.mingw_unicode_entry_point = true;
    if (optimize == .ReleaseSmall) {
        exe.link_function_sections = true;
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

fn buildLinux(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/platform/wayland/Entry.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });

    // Wayland system libraries — to be expanded in Phase 5.
    exe_mod.linkSystemLibrary("c", .{});

    const exe = b.addExecutable(.{
        .name = "vitrail",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
