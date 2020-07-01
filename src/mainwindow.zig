const std = @import("std");
const w = @import("win32").c;
const Window = @import("window.zig").Window;
const WindowParameters = @import("window.zig").WindowParameters;
const WindowEventHandlers = @import("window.zig").WindowEventHandlers;
const toUtf16const = @import("system_interaction.zig").toUtf16const;

pub const MainWindow = struct {
    window: *Window(MainWindow),

    fn onDestroyHandler(widget: *MainWindow) !void {
        _ = w.PostQuitMessage(0);
    }

    pub fn create(hInstance: w.HINSTANCE, allocator: *std.mem.Allocator) !*MainWindow {
        const title = toUtf16const("MainWindow");
        const windowConfig = WindowParameters { .title = title  };
        const handlers = Window(MainWindow).WindowEventHandlers { .onDestroy = onDestroyHandler };

        var widget = try allocator.create(MainWindow);
        widget.* = MainWindow {
            .window = try Window(MainWindow).create(windowConfig, handlers, hInstance, allocator, widget)
        };

        return widget;
    }
};
