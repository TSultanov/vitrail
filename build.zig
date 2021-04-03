const std = @import("std");
const Builder = @import("std").build.Builder;
const builtin = @import("builtin");

const PathType = enum {
    Lib,
    Include,
    Bin
};

fn getSdkPath(allocator: *std.mem.Allocator, comptime pathType: PathType) ![]u8 {
    const systemRoot = std.process.getEnvVarOwned(allocator, "SystemRoot") catch unreachable;
    defer allocator.free(systemRoot);
    // Sin: using shell as a library. But take alook at this API: https://docs.microsoft.com/en-us/windows/win32/sysinfo/enumerating-registry-subkeys, I'm too lazy to call it directly
    const powershellPath = std.fmt.allocPrint(allocator, "{s}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", .{systemRoot}) catch unreachable;
    defer allocator.free(powershellPath);

    const locateResult = std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = &.{powershellPath, "-NonInteractive", "-File", ".\\build\\LocateWinSDK.ps1", switch (pathType) { .Lib => "Lib", .Include => "Include", .Bin => "Bin" }}
        }) catch unreachable;
    defer allocator.free(locateResult.stderr);
    const sdkBase = locateResult.stdout;
    return sdkBase;
}

pub fn build(b: *Builder) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());

    const includePath = getSdkPath(&gpa.allocator, .Include) catch unreachable;
    defer gpa.allocator.free(includePath);

    const ucrtPath = b.fmt("{s}/ucrt", .{includePath});
    const umPath = b.fmt("{s}/um", .{includePath});
    const sharedPath = b.fmt("{s}/shared", .{includePath});

    const libPath = getSdkPath(&gpa.allocator, .Lib) catch unreachable;
    defer gpa.allocator.free(libPath);

    const umLibPath = b.fmt("{s}/um/X64", .{libPath});

    const binPath = getSdkPath(&gpa.allocator, .Bin) catch unreachable;
    defer gpa.allocator.free(binPath);

    const mtPath = b.fmt("{s}/X64/mt.exe", .{binPath});

    const mode = b.standardReleaseOptions();
    const exe = b.addExecutable("vitrail", "src/wmain.zig");
    //exe.linkSystemLibrary("c");
    exe.addIncludeDir(ucrtPath);
    exe.addIncludeDir(umPath);
    exe.addIncludeDir(sharedPath);
    // This path must be removed
    exe.addIncludeDir("C:/Program Files (x86)/Microsoft Visual Studio/2019/Community/VC/Tools/MSVC/14.28.29333/include");
    exe.addLibPath(umLibPath);
    exe.linkSystemLibrary("gdi32");
    exe.linkSystemLibrary("user32");
    exe.linkSystemLibrary("Shell32");
    exe.linkSystemLibrary("kernel32");
    exe.linkSystemLibrary("ComCtl32");
    exe.linkSystemLibrary("Ole32");
    exe.linkSystemLibrary("Shlwapi");
    exe.linkSystemLibrary("Dwmapi");
    exe.setBuildMode(mode);
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
