const std = @import("std");
const Builder = @import("std").build.Builder;
const builtin = @import("builtin");

const w = @import("build/windows.zig");

const PathType = enum {
    Lib,
    Include,
    Bin
};

fn descU8(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn getSdkPath(b: *Builder, comptime pathType: PathType) ![]u8 {
    const systemRoot = std.process.getEnvVarOwned(b.allocator, "SystemRoot") catch unreachable;
    defer b.allocator.free(systemRoot);
    const kitsRoot = try w.getRegSzValue(b.allocator, w.HKEY_LOCAL_MACHINE, "SOFTWARE\\Microsoft\\Windows Kits\\Installed Roots\\", "KitsRoot10");
    defer b.allocator.free(kitsRoot);
    const sdkVersions = try w.regEnumKeys(b.allocator, w.HKEY_LOCAL_MACHINE, "SOFTWARE\\Microsoft\\Windows Kits\\Installed Roots\\");
    defer sdkVersions.deinit();
    defer for(sdkVersions.items) |version| {
        b.allocator.free(version);
    };
    const maxVersion = std.sort.max([]u8, sdkVersions.items, {}, descU8);
    const pathTypeStr = switch(pathType) {
        .Lib => "Lib",
        .Include => "Include",
        .Bin => "Bin"
    };
    if(maxVersion) |version| {
        const sdkBase = try std.fs.path.join(b.allocator, &.{kitsRoot, pathTypeStr, version});
        return sdkBase;
    }
    @panic("Can't find installed Windows SDK");
}

pub fn build(b: *Builder) void {
    const binPath = getSdkPath(b, .Bin) catch unreachable;
    const mtPath = std.fs.path.join(b.allocator, &.{binPath, "X64\\mt.exe"}) catch unreachable;

    // const includePath = getSdkPath(b, .Include) catch unreachable;
    // const umPath = std.fs.path.join(b.allocator, &.{includePath, "um"}) catch unreachable;
    // const sharedPath = std.fs.path.join(b.allocator, &.{includePath, "shared"}) catch unreachable;

    // const mode = b.standardReleaseOptions();
    const exe = b.addExecutable("vitrail", "src/wmain.zig");
    exe.setTarget(.{.cpu_arch = .x86_64, .os_tag = .windows, .abi = .msvc});
    exe.subsystem = .Windows;
    // if(b.release_mode == std.builtin.Mode.ReleaseSmall) {
    //     exe.strip = true;
    //     exe.link_function_sections = true;
    //     // exe.single_threaded = true;
    // }
    // exe.addIncludeDir(umPath);
    // exe.addIncludeDir(sharedPath);
    exe.single_threaded = true;
    exe.linkSystemLibrary("c");
    exe.linkSystemLibrary("gdi32");
    exe.linkSystemLibrary("user32");
    exe.linkSystemLibrary("Shell32");
    exe.linkSystemLibrary("kernel32");
    exe.linkSystemLibrary("ComCtl32");
    exe.linkSystemLibrary("Ole32");
    exe.linkSystemLibrary("Shlwapi");
    exe.linkSystemLibrary("Dwmapi");
    // exe.setBuildMode(mode);
    exe.install();

    var run_mt = b.addSystemCommand(&[_][]const u8{
        mtPath, "-nologo", "-manifest", "src/app.manifest",
        b.fmt("-outputresource:{s}\\{s}", .{b.exe_dir, exe.out_filename})
    });
    run_mt.step.dependOn(&exe.step);

    b.default_step.dependOn(&run_mt.step);

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
