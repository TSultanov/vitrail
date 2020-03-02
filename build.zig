const Builder = @import("std").build.Builder;
const builtin = @import("builtin");

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const exe = b.addExecutable("vitrail", "src/main.zig");
    exe.setTarget(.{.cpu_arch=.x86_64, .os_tag=.windows, .abi=.gnu});
    exe.addPackagePath("win32", "./dependencies/zig-win32/src/main.zig");
    exe.addLibPath("/usr/x86_64-w64-mingw32/lib/");
    //exe.addIncludeDir("C:/Program Files (x86)/Windows Kits/10/Include/10.0.18362.0/um/x64");
    //exe.addLibPath("C:/Program Files (x86)/Windows Kits/10/Lib/10.0.18362.0/um/x64");
    exe.linkSystemLibrary("c");
    exe.linkSystemLibrary("gdi32");
    exe.linkSystemLibrary("user32");
    exe.linkSystemLibrary("kernel32");
    exe.setBuildMode(mode);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
