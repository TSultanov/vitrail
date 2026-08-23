const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{
        .whitelist = &.{
            .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
            .{ .cpu_arch = .aarch64, .os_tag = .windows, .abi = .gnu },
            .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
            .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
            .{ .cpu_arch = .x86_64, .os_tag = .macos },
            .{ .cpu_arch = .aarch64, .os_tag = .macos },
        },
    });

    const mock_backend = b.option(bool, "mock-backend", "Use MockBackend instead of the real SystemInteraction (for tests)") orelse false;

    const build_options = b.addOptions();
    build_options.addOption(bool, "mock_backend", mock_backend);

    switch (target.result.os.tag) {
        .windows => buildWindows(b, target, optimize, build_options, mock_backend),
        .linux => buildLinux(b, target, optimize, build_options, mock_backend),
        .macos => buildMacos(b, target, optimize, build_options, mock_backend),
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
    .{ .xml = "protocols/fractional-scale-v1.xml", .name = "fractional-scale-v1-client-protocol" },
    .{ .xml = "protocols/viewporter.xml", .name = "viewporter-client-protocol" },
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
    exe_mod.addSystemIncludePath(.{ .cwd_relative = "/usr/include/glib-2.0" });
    exe_mod.addSystemIncludePath(.{ .cwd_relative = "/usr/lib64/glib-2.0/include" });
    exe_mod.addSystemIncludePath(.{ .cwd_relative = "/usr/include/cairo" });
    exe_mod.addSystemIncludePath(.{ .cwd_relative = "/usr/include/librsvg-2.0" });
    exe_mod.addSystemIncludePath(.{ .cwd_relative = "/usr/include/gdk-pixbuf-2.0" });
    exe_mod.linkSystemLibrary("c", .{});
    exe_mod.linkSystemLibrary("wayland-client", .{});
    exe_mod.linkSystemLibrary("wayland-cursor", .{});
    exe_mod.linkSystemLibrary("xkbcommon", .{ .use_pkg_config = .no });
    exe_mod.linkSystemLibrary("freetype", .{ .use_pkg_config = .no });
    exe_mod.linkSystemLibrary("fontconfig", .{ .use_pkg_config = .no });
    exe_mod.linkSystemLibrary("systemd", .{ .use_pkg_config = .no });
    exe_mod.linkSystemLibrary("png", .{ .use_pkg_config = .no });
    exe_mod.linkSystemLibrary("rsvg-2", .{ .use_pkg_config = .no });
    exe_mod.linkSystemLibrary("cairo", .{ .use_pkg_config = .no });
    exe_mod.linkSystemLibrary("gobject-2.0", .{ .use_pkg_config = .no });
    exe_mod.linkSystemLibrary("glib-2.0", .{ .use_pkg_config = .no });
    exe_mod.linkSystemLibrary("gio-2.0", .{ .use_pkg_config = .no });
    exe_mod.addIncludePath(generated_headers.getDirectory());

    // Compile each generated private-code C file into the binary.
    for (wayland_protocols) |proto| {
        const code_name = b.fmt("{s}.c", .{proto.name});
        exe_mod.addCSourceFile(.{
            .file = generated_headers.getDirectory().path(b, code_name),
            .flags = &.{"-std=c99"},
        });
    }

    // sd-bus vtable construction can't go through translate-c (bitfield union),
    // so it's a small C shim built into the binary. Only needed for the
    // production build — the mock backend doesn't reach KdeBackend.
    if (!mock_backend) {
        exe_mod.addCSourceFile(.{
            .file = b.path("src/platform/wayland/kde_dbus_shim.c"),
            .flags = &.{"-std=c99"},
        });
        exe_mod.addCSourceFile(.{
            .file = b.path("src/platform/wayland/png_decode.c"),
            .flags = &.{"-std=c99"},
        });
        exe_mod.addCSourceFile(.{
            .file = b.path("src/platform/wayland/svg_decode.c"),
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

fn buildMacos(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, build_options: *std.Build.Step.Options, mock_backend: bool) void {
    const root = if (mock_backend) "src/main_macos_test.zig" else "src/main_macos.zig";
    const exe_mod = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        // Multi-threaded so the AX-cache startup seed can scan apps in
        // parallel. Threads are otherwise unused — vitrail's UI loop
        // and Cocoa bridge run entirely on the main thread.
        .single_threaded = false,
    });
    exe_mod.addOptions("build_options", build_options);

    exe_mod.linkSystemLibrary("c", .{});
    exe_mod.linkFramework("Cocoa", .{});
    exe_mod.linkFramework("CoreFoundation", .{});
    exe_mod.linkFramework("CoreGraphics", .{});
    exe_mod.linkFramework("CoreText", .{});
    exe_mod.linkFramework("ApplicationServices", .{});
    exe_mod.linkFramework("Carbon", .{});
    exe_mod.linkFramework("QuartzCore", .{});

    exe_mod.addCSourceFile(.{
        .file = b.path("src/platform/macos/cocoa_bridge.m"),
        .flags = &.{ "-fobjc-arc", "-Wno-deprecated-declarations" },
    });

    const exe = b.addExecutable(.{
        .name = "vitrail",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    // Assemble a minimal .app bundle so accessibility prompts attach to a
    // stable bundle id and LSUIElement (no Dock icon) takes effect.
    const bundle_step = b.step("bundle", "Assemble Vitrail.app bundle");
    const wf = b.addWriteFiles();
    const plist = wf.add("Vitrail.app/Contents/Info.plist", info_plist);
    const pkginfo = wf.add("Vitrail.app/Contents/PkgInfo", "APPL????");
    bundle_step.dependOn(&wf.step);

    const install_plist = b.addInstallFile(plist, "Vitrail.app/Contents/Info.plist");
    const install_pkginfo = b.addInstallFile(pkginfo, "Vitrail.app/Contents/PkgInfo");
    const install_exe = b.addInstallFile(exe.getEmittedBin(), "Vitrail.app/Contents/MacOS/vitrail");
    bundle_step.dependOn(&install_plist.step);
    bundle_step.dependOn(&install_pkginfo.step);
    bundle_step.dependOn(&install_exe.step);
    b.getInstallStep().dependOn(bundle_step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Debug-only: dump every AX window the production backend would
    // consider, with kept-or-dropped tag and reason. Run via
    // `zig build dump-windows`.
    const dump_mod = b.createModule(.{
        .root_source_file = b.path("src/platform/macos/dump_windows.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = false,
    });
    dump_mod.linkSystemLibrary("c", .{});
    dump_mod.linkFramework("Cocoa", .{});
    dump_mod.linkFramework("CoreFoundation", .{});
    dump_mod.linkFramework("CoreGraphics", .{});
    dump_mod.linkFramework("ApplicationServices", .{});
    dump_mod.linkFramework("QuartzCore", .{});
    dump_mod.addCSourceFile(.{
        .file = b.path("src/platform/macos/cocoa_bridge.m"),
        .flags = &.{ "-fobjc-arc", "-Wno-deprecated-declarations" },
    });
    const dump_exe = b.addExecutable(.{
        .name = "dump_windows",
        .root_module = dump_mod,
    });
    const dump_run = b.addRunArtifact(dump_exe);
    const dump_step = b.step("dump-windows", "Dump AX window enumeration");
    dump_step.dependOn(&dump_run.step);
}

const info_plist =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    \\<plist version="1.0">
    \\<dict>
    \\    <key>CFBundleDevelopmentRegion</key>
    \\    <string>en</string>
    \\    <key>CFBundleExecutable</key>
    \\    <string>vitrail</string>
    \\    <key>CFBundleIdentifier</key>
    \\    <string>com.github.TSultanov.vitrail</string>
    \\    <key>CFBundleInfoDictionaryVersion</key>
    \\    <string>6.0</string>
    \\    <key>CFBundleName</key>
    \\    <string>Vitrail</string>
    \\    <key>CFBundlePackageType</key>
    \\    <string>APPL</string>
    \\    <key>CFBundleShortVersionString</key>
    \\    <string>0.0.0</string>
    \\    <key>CFBundleVersion</key>
    \\    <string>0</string>
    \\    <key>LSMinimumSystemVersion</key>
    \\    <string>11.0</string>
    \\    <key>LSUIElement</key>
    \\    <true/>
    \\    <key>NSHighResolutionCapable</key>
    \\    <true/>
    \\    <key>NSAccessibilityUsageDescription</key>
    \\    <string>Vitrail uses Accessibility to switch to and close the window you pick.</string>
    \\</dict>
    \\</plist>
    \\
;
