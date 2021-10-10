pub const w = @import("windows.zig");
pub const std = @import("std");
pub const zw = std.os.windows;
pub const toUtf16const = @import("SystemInteraction.zig").toUtf16const;
pub const toUtf16 = @import("SystemInteraction.zig").toUtf16;
pub const toUtf8 = @import("SystemInteraction.zig").toUtf8;
const MainPresenter = @import("MainPresenter.zig");

pub export fn wWinMain(hInstance: zw.HINSTANCE, hPrevInstance: ?zw.HINSTANCE, pCmdLine: w.LPWSTR, nCmdShow: c_int) callconv(std.os.windows.WINAPI) c_int {
    _ = hPrevInstance;
    _ = pCmdLine;
    _ = nCmdShow;

    const hInstanceWinApi = @ptrCast(w.HINSTANCE, @alignCast(4, hInstance));
    _ = w.CoInitializeEx(null, 0x2);

    var picce = w.INITCOMMONCONTROLSEX{ .dwSize = @sizeOf(w.INITCOMMONCONTROLSEX), .dwICC = 0xff };

    _ = w.InitCommonControlsEx(&picce);

    var gpa = std.heap.GeneralPurposeAllocator(.{.safety = true}){};
    defer std.debug.assert(!gpa.deinit());

    _ = w.RegisterHotKey(null, 0, w.MOD_ALT, w.VK_SPACE);

    var main_presenter = MainPresenter.init(hInstanceWinApi, std.heap.page_allocator) catch unreachable;

    var msg: w.MSG = undefined;
    while (w.GetMessageW(&msg, null, 0, 0) != 0) {
        if (msg.message == w.WM_HOTKEY)
        {
            main_presenter.show() catch unreachable;
        }
        else
        {
            _ = w.TranslateMessage(&msg);
            _ = w.DispatchMessageW(&msg);
        }
    }

    return 0;
}
