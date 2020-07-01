const std = @import("std");
const w = @import("win32").c;
const Box = @import("box.zig").Box;
const system_interaction = @import("system_interaction.zig");
const MainWindow = @import("mainwindow.zig").MainWindow;

pub export fn WinMain(hInstance: w.HINSTANCE, hPrevInstance: w.HINSTANCE, pCmdLine: w.LPWSTR, nCmdShow: c_int) callconv(.C) c_int {
    //const stdin = std.io.getStdIn().inStream();
    //_ = stdin.readByte() catch unreachable;
    var hr = w.CoInitializeEx(null, 0x2);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var main_window = MainWindow.create(hInstance, &arena.allocator) catch unreachable;
    main_window.window.show();

    var msg: w.MSG = undefined;
    while (w.GetMessageW(&msg, null, 0, 0) != 0) {
        _ = w.TranslateMessage(&msg);
        _ = w.DispatchMessageW(&msg);
    }

    return 0;
}