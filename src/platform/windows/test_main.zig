// Windows test entry point. Boots the app with MockBackend (comptime-swapped
// in src/platform.zig), then runs the cross-platform scenarios; exits with
// the failure count.
const wh = @import("windows.zig");
const w = wh.c;
const std = @import("std");
const MainPresenter = @import("../../MainPresenter.zig");
const TestDriver = @import("test_driver.zig").Driver;
const ts = @import("../../test_scenarios.zig");

pub export fn wWinMain(hInstance: w.HINSTANCE, hPrevInstance: w.HINSTANCE, pCmdLine: w.LPWSTR, nCmdShow: c_int) callconv(.winapi) c_int {
    _ = hPrevInstance;
    _ = pCmdLine;
    _ = nCmdShow;

    const hInstanceWinApi: w.HINSTANCE = @ptrCast(@alignCast(hInstance));
    _ = w.CoInitializeEx(null, 0x2);
    var picce = w.INITCOMMONCONTROLSEX{ .dwSize = @sizeOf(w.INITCOMMONCONTROLSEX), .dwICC = 0xff };
    _ = w.InitCommonControlsEx(&picce);

    var gpa: std.heap.DebugAllocator(.{ .safety = true }) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const presenter = MainPresenter.init(.{ .hInstance = hInstanceWinApi }, std.heap.page_allocator, false) catch unreachable;

    const out_dir = "C:\\Users\\Public\\vitrail-screenshots";
    const driver = TestDriver.create(allocator, presenter, out_dir) catch unreachable;
    defer driver.destroy();

    var d = driver.driver();
    const fails = ts.runAll(&d);

    std.debug.print("\n{d} of {d} scenarios failed\n", .{ fails, ts.all.len });
    return @intCast(fails);
}
