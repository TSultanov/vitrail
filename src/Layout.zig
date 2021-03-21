usingnamespace @import("vitrail.zig");
pub const Window = @import("Window.zig");

const Self = @This();

window: *Window,

fn onResizeHandler(window: Window) !void {
    if(window.docked)
    {
        try window.dock();
    }

    const rect = try window.getRect();

    for (window.children.items) |child| {
        //try child.setSize();
    }
}

pub fn create(hInstance: w.HINSTANCE, parent: *Window, allocator: *std.mem.Allocator) !Self {
    const windowConfig = Window.WindowParameters {
        .title = toUtf16const("SpiralLayout"),
        .className = toUtf16const("SpiralLayout"),
        .style = w.WS_VISIBLE | w.WS_CHILD,
        .parent = parent,
        .register_class = true,
    };
    const handlers = Window.WindowEventHandlers{ .onResize = onResizeHandler, };

    var window: *Window = try Window.create(windowConfig, handlers, hInstance, allocator);
    window.docked = true;
    return Self{ .window = window };
}
