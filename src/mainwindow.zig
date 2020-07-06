usingnamespace @import("vitrail.zig");
pub const Window = @import("window.zig").Window;

pub const MainWindow = struct {
    window: *Window(MainWindow),

    fn onDestroyHandler(widget: *MainWindow) !void {
        _ = w.PostQuitMessage(0);
    }

    pub fn create(hInstance: w.HINSTANCE, allocator: *std.mem.Allocator) !*MainWindow {
        const title = toUtf16const("MainWindow");
        const windowConfig = Window(MainWindow).WindowParameters { .title = title  };
        const handlers = Window(MainWindow).WindowEventHandlers { .onDestroy = onDestroyHandler };

        var widget = try allocator.create(MainWindow);
        widget.* = MainWindow {
            .window = try Window(MainWindow).create(windowConfig, handlers, hInstance, allocator, widget)
        };

        return widget;
    }
};
