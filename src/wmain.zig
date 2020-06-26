const std = @import("std");
const w = @import("win32").c;
const Window = @import("window.zig").Window;
const WindowParameters = @import("window.zig").WindowParameters;
const WindowEventHandlers = @import("window.zig").WindowEventHandlers;

fn onDestroyHandler(window: Window) !void {
    _ = w.PostQuitMessage(0);
}

pub export fn WinMain(hInstance: w.HINSTANCE, hPrevInstance: w.HINSTANCE, pCmdLine: w.LPWSTR, nCmdShow: c_int) callconv(.C) c_int {
    //const stdin = std.io.getStdIn().inStream();
    //_ = stdin.readByte() catch unreachable;
    var hr = w.CoInitializeEx(null, 0x2);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var window = Window.create(WindowParameters {}, WindowEventHandlers { .onDestroy = onDestroyHandler }, hInstance, &arena.allocator) catch unreachable;
    window.show();

    var msg: w.MSG = undefined;
    while (w.GetMessageW(&msg, null, 0, 0) != 0) {
        _ = w.TranslateMessage(&msg);
        _ = w.DispatchMessageW(&msg);
    }

    return 0;
}