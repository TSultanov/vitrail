usingnamespace @import("vitrail.zig");
const MainController = @import("MainController.zig");

//pub export fn wWinMain(hInstance: zw.HINSTANCE, hPrevInstance: ?zw.HINSTANCE, pCmdLine: w.LPWSTR, nCmdShow: c_int) callconv(.C) c_int {
pub export fn main() void {
    const hInstanceWinApi = w.GetModuleHandleW(null); //@ptrCast(w.HINSTANCE, @alignCast(4, hInstance));
    //const stdin = std.io.getStdIn().inStream();
    //_ = stdin.readByte() catch unreachable;
    var hr = w.CoInitializeEx(null, 0x2);

    var picce = w.INITCOMMONCONTROLSEX{ .dwSize = @sizeOf(w.INITCOMMONCONTROLSEX), .dwICC = 0xff };

    _ = w.InitCommonControlsEx(&picce);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var main_window = MainController.init(hInstanceWinApi, &arena.allocator) catch unreachable;

    var msg: w.MSG = undefined;
    while (w.GetMessageW(&msg, null, 0, 0) != 0) {
        _ = w.TranslateMessage(&msg);
        _ = w.DispatchMessageW(&msg);
    }

    return; // 0;
}
