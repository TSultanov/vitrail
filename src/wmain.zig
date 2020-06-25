const std = @import("std");
const w = @import("win32").c;
const Window = @import("window.zig").Window;
const WindowParameters = @import("window.zig").WindowParameters;

fn WindowProc(hwnd: w.HWND, uMsg: w.UINT, wParam: w.WPARAM, lParam: w.LPARAM) w.LRESULT {
    return switch (uMsg) {
        w.WM_DESTROY => {
            return 0;
        },
        w.WM_CREATE => {
            return 0;
        },
        else => w.DefWindowProcW(hwnd, uMsg, wParam, lParam)
    };
}

pub export fn WinMain(hInstance: w.HINSTANCE, hPrevInstance: w.HINSTANCE, pCmdLine: w.LPWSTR, nCmdShow: c_int) callconv(.C) c_int {
    const stdin = std.io.getStdIn().inStream();
    _ = stdin.readByte() catch unreachable;
    var hr = w.CoInitializeEx(null, 0x2);

    var window = Window.create(WindowParameters {.wndProc = WindowProc}, hInstance);
    window.show();

    var msg: w.MSG = undefined;
    while (w.GetMessageW(&msg, null, 0, 0) != 0) {
        _ = w.TranslateMessage(&msg);
        _ = w.DispatchMessageW(&msg);
    }

    return 0;
}