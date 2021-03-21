usingnamespace @import("vitrail.zig");
pub const Window = @import("Window.zig");

const Self = @This();

window: *Window,

pub fn create(hInstance: w.HINSTANCE, parent: Window, allocator: *std.mem.Allocator) !Self {
    const windowConfig = Window.WindowParameters {
        .title = toUtf16const("Click me!"),
        .className = toUtf16const("BUTTON"),
        .width = 100,
        .height = 25,
        .style = w.WS_TABSTOP | w.WS_VISIBLE | w.WS_CHILD | w.BS_DEFPUSHBUTTON,
        .parent = parent,
        .register_class = false
    };
    const handlers = Window.WindowEventHandlers { };

    return Self {
        .window = try Window.create(windowConfig, handlers, hInstance, allocator);
    }
}
