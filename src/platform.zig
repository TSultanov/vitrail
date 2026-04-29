const builtin = @import("builtin");
const build_options = @import("build_options");

pub const impl = switch (builtin.target.os.tag) {
    .windows => @import("platform/windows/platform_impl.zig"),
    .linux => @import("platform/wayland/platform_impl.zig"),
    else => @compileError("unsupported OS"),
};

pub const PlatformArgs = impl.PlatformArgs;
pub const MainWindow = impl.MainWindow;
pub const SystemInteraction = if (build_options.mock_backend)
    @import("platform/MockBackend.zig")
else
    impl.SystemInteraction;
