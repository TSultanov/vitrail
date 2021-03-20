usingnamespace @import("vitrail.zig");
pub const Window = @import("window.zig").Window;
const Button = @import("button.zig").Button;

pub const MainWindow = struct {
    window: *Window(MainWindow),

    fn onDestroyHandler(widget: *MainWindow) !void {
        _ = w.PostQuitMessage(0);
    }

    pub fn create(hInstance: w.HINSTANCE, allocator: *std.mem.Allocator) !*MainWindow {
        const windowConfig = Window(MainWindow).WindowParameters { .title = toUtf16const("MainWindow") };
        const handlers = Window(MainWindow).WindowEventHandlers { .onDestroy = onDestroyHandler };

        var widget = try Window(MainWindow).create(windowConfig, handlers, hInstance, allocator);

        createWidgets(widget, hInstance, allocator);

        return widget;
    }

    pub fn createWidgets(main_window: *MainWindow, hInstance: w.HINSTANCE, allocator: *std.mem.Allocator) void
    {
        var button = Button.create(hInstance, main_window.window.system_window, allocator) catch unreachable;
        main_window.window.system_window.addChild(button.window.system_window) catch unreachable;

        button.window.system_window.show();
    }
};
