usingnamespace @import("vitrail.zig");
pub const Window = @import("window.zig").Window;

pub const Button = struct {
    window: *Window(@This()),

    pub fn create(hInstance: w.HINSTANCE, allocator: *std.mem.Allocator) !*@This() {
        const title = toUtf16const("Click me!");
        const class = toUtf16const("BUTTON");
        const windowConfig = Window(@This()).WindowParameters {
            .title = title,
            .className = class,
            .width = 100,
            .height = 25,
            .style = w.WS_TABSTOP | w.WS_VISIBLE | w.WS_CHILD | w.BS_DEFPUSHBUTTON
        };
        const handlers = Window(@This()).WindowEventHandlers { };

        var widget = try Window(@This()).create(windowConfig, handlers, hInstance, allocator);

        return widget;
    }
};
