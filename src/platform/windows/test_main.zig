// Test entry point: same wWinMain shape as Entry.zig, but after show()
// runs a baked-in keystroke + snapshot script, then exits. Compiled when
// `-Dmock-backend=true`. SystemInteraction is comptime-swapped to MockBackend
// in src/platform.zig.

const wh = @import("windows.zig");
const w = wh.c;
const std = @import("std");
const MainPresenter = @import("../../MainPresenter.zig");
const test_driver = @import("test_driver.zig");

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

    var main_presenter = MainPresenter.init(.{ .hInstance = hInstanceWinApi }, std.heap.page_allocator, true) catch unreachable;

    main_presenter.show() catch unreachable;

    const script = [_]test_driver.Step{
        .{ .snapshot = "01-initial-grid" },
        .{ .key_down = w.VK_RIGHT },
        .{ .snapshot = "02-after-right" },
        .{ .char = 'f' },
        .{ .char = 'i' },
        .{ .snapshot = "03-after-fi" },
        .{ .key_down = w.VK_RETURN },
        .{ .snapshot = "04-after-enter" },
    };

    const out_dir = "C:\\Users\\Public\\vitrail-screenshots";
    test_driver.run(main_presenter.view.window.hwnd, &script, out_dir, gpa.allocator()) catch |e| {
        std.log.err("test_driver.run failed: {t}", .{e});
    };

    _ = w.PostQuitMessage(0);

    var msg: w.MSG = undefined;
    while (w.GetMessageW(&msg, null, 0, 0) != 0) {
        _ = w.TranslateMessage(&msg);
        _ = w.DispatchMessageW(&msg);
    }

    return 0;
}
