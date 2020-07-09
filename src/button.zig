usingnamespace @import("vitrail.zig");
pub const Window = @import("window.zig").Window;
pub const SystemWindow = @import("window.zig").SystemWindow;

pub const Button = struct {
    window: *Window(@This()),

    pub fn create(hInstance: w.HINSTANCE, parent: SystemWindow, allocator: *std.mem.Allocator) !*@This() {
        const windowConfig = Window(@This()).WindowParameters {
            .title = toUtf16const("Click me!"),
            .className = toUtf16const("BUTTON"),
            .width = 100,
            .height = 25,
            .style = w.WS_TABSTOP | w.WS_VISIBLE | w.WS_CHILD | w.BS_DEFPUSHBUTTON,
            .parent = parent,
            .register_class = false
        };
        const handlers = Window(@This()).WindowEventHandlers { };

        var widget = try Window(@This()).create(windowConfig, handlers, hInstance, allocator);

        return widget;
    }
};
