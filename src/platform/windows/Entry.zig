const wh = @import("windows.zig");
const w = wh.c;
const std = @import("std");
const zw = std.os.windows;
const MainPresenter = @import("../../MainPresenter.zig");

pub export fn wWinMain(hInstance: w.HINSTANCE, hPrevInstance: w.HINSTANCE, pCmdLine: w.LPWSTR, nCmdShow: c_int) callconv(.winapi) c_int {
    _ = hPrevInstance;
    _ = pCmdLine;
    _ = nCmdShow;

    const hInstanceWinApi: w.HINSTANCE = @ptrCast(@alignCast(hInstance));
    _ = w.CoInitializeEx(null, 0x2);

    var picce = w.INITCOMMONCONTROLSEX{ .dwSize = @sizeOf(w.INITCOMMONCONTROLSEX), .dwICC = 0xff };

    _ = w.InitCommonControlsEx(&picce);

    var gpa: std.heap.DebugAllocator(.{ .safety = true }) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const test_mode = parseTestMode(gpa.allocator()) catch false;

    if (!test_mode) {
        _ = w.RegisterHotKey(null, 0, w.MOD_ALT, w.VK_SPACE);
    }

    var main_presenter = MainPresenter.init(.{ .hInstance = hInstanceWinApi }, std.heap.page_allocator, test_mode) catch unreachable;

    if (test_mode) {
        main_presenter.show() catch unreachable;
    }

    var msg: w.MSG = undefined;
    while (w.GetMessageW(&msg, null, 0, 0) != 0) {
        if (msg.message == w.WM_HOTKEY) {
            main_presenter.show() catch unreachable;
        } else {
            _ = w.TranslateMessage(&msg);
            _ = w.DispatchMessageW(&msg);
        }
    }

    return 0;
}

fn parseTestMode(allocator: std.mem.Allocator) !bool {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--test-mode")) return true;
    }
    return false;
}
