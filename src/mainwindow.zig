usingnamespace @import("vitrail.zig");
pub const Window = @import("Window.zig");
pub const Layout = @import("Layout.zig");

const Self = @This();

window: *Window,
layout: Layout,

fn onDestroyHandler(window: Window) !void {
    _ = w.PostQuitMessage(0);
}

pub fn create(hInstance: w.HINSTANCE, allocator: *std.mem.Allocator) !Self {
    const windowConfig = Window.WindowParameters{ .title = toUtf16const("MainWindow") };
    const handlers = Window.WindowEventHandlers{ .onDestroy = onDestroyHandler };

    var window = try Window.create(windowConfig, handlers, hInstance, allocator);

    return Self {
        .window = window,
        .layout = try Layout.create(hInstance, window, allocator)
    };
}
