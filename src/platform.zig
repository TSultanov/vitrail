const builtin = @import("builtin");

pub const impl = switch (builtin.target.os.tag) {
    .windows => @import("platform/windows/platform_impl.zig"),
    .linux => @import("platform/wayland/platform_impl.zig"),
    else => @compileError("unsupported OS"),
};

pub const PlatformArgs = impl.PlatformArgs;
pub const SystemInteraction = impl.SystemInteraction;
pub const MainWindow = impl.MainWindow;
