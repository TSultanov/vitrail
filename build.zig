const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{
        .whitelist = &.{
            .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
            .{ .cpu_arch = .aarch64, .os_tag = .windows, .abi = .gnu },
            .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
            .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
        },
    });

    const mock_backend = b.option(bool, "mock-backend", "Use MockBackend instead of the real SystemInteraction (for tests)") orelse false;

    const build_options = b.addOptions();
    build_options.addOption(bool, "mock_backend", mock_backend);

    switch (target.result.os.tag) {
        .windows => buildWindows(b, target, optimize, build_options, mock_backend),
        .linux => buildLinux(b, target, optimize, build_options, mock_backend),
        else => @panic("unsupported OS"),
    }
}

fn buildWindows(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, build_options: *std.Build.Step.Options, mock_backend: bool) void {
    const root = if (mock_backend) "src/main_windows_test.zig" else "src/main_windows.zig";
    const exe_mod = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
        .strip = (optimize == .ReleaseSmall),
    });
    exe_mod.addOptions("build_options", build_options);

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

const WaylandProtocol = struct {
    xml: []const u8,
    name: []const u8,
};

const wayland_protocols = [_]WaylandProtocol{
    .{ .xml = "protocols/wayland.xml", .name = "wayland-client-protocol" },
    .{ .xml = "protocols/xdg-shell.xml", .name = "xdg-shell-client-protocol" },
    .{ .xml = "protocols/xdg-activation-v1.xml", .name = "xdg-activation-v1-client-protocol" },
    .{ .xml = "protocols/wlr-layer-shell-unstable-v1.xml", .name = "wlr-layer-shell-unstable-v1-client-protocol" },
    .{ .xml = "protocols/wlr-foreign-toplevel-management-unstable-v1.xml", .name = "wlr-foreign-toplevel-management-unstable-v1-client-protocol" },
    .{ .xml = "protocols/plasma-window-management.xml", .name = "plasma-window-management-client-protocol" },
    .{ .xml = "protocols/plasma-virtual-desktop.xml", .name = "plasma-virtual-desktop-client-protocol" },
};

fn buildLinux(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, build_options: *std.Build.Step.Options, mock_backend: bool) void {
    // Generate Wayland protocol headers and private-code C files via wayland-scanner.
    var generated_headers = b.addWriteFiles();
    var proto_step = b.step("protocols", "Generate Wayland protocol bindings");

    for (wayland_protocols) |proto| {
        const header_name = b.fmt("{s}.h", .{proto.name});
        const code_name = b.fmt("{s}.c", .{proto.name});

        const gen_header = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
        gen_header.addFileArg(b.path(proto.xml));
        const header_out = gen_header.addOutputFileArg(header_name);
        _ = generated_headers.addCopyFile(header_out, header_name);
        proto_step.dependOn(&gen_header.step);

        const gen_code = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
        gen_code.addFileArg(b.path(proto.xml));
        const code_out = gen_code.addOutputFileArg(code_name);
        _ = generated_headers.addCopyFile(code_out, code_name);
        proto_step.dependOn(&gen_code.step);
    }

    const root = if (mock_backend) "src/main_wayland_test.zig" else "src/main_wayland.zig";
    const exe_mod = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    exe_mod.addOptions("build_options", build_options);

    exe_mod.addLibraryPath(.{ .cwd_relative = "/usr/lib64" });
    exe_mod.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
    exe_mod.addSystemIncludePath(.{ .cwd_relative = "/usr/include/freetype2" });
    exe_mod.linkSystemLibrary("c", .{});
    exe_mod.linkSystemLibrary("wayland-client", .{});
    exe_mod.linkSystemLibrary("wayland-cursor", .{});
    exe_mod.linkSystemLibrary("xkbcommon", .{ .use_pkg_config = .no });
    exe_mod.linkSystemLibrary("freetype", .{ .use_pkg_config = .no });
    exe_mod.linkSystemLibrary("fontconfig", .{ .use_pkg_config = .no });
    exe_mod.linkSystemLibrary("systemd", .{ .use_pkg_config = .no });
    exe_mod.addIncludePath(generated_headers.getDirectory());

    // Compile each generated private-code C file into the binary.
    for (wayland_protocols) |proto| {
        const code_name = b.fmt("{s}.c", .{proto.name});
        exe_mod.addCSourceFile(.{
            .file = generated_headers.getDirectory().path(b, code_name),
            .flags = &.{"-std=c99"},
        });
    }

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
