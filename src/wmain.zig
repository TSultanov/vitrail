usingnamespace @import("vitrail.zig");
const MainWindow = @import("mainwindow.zig").MainWindow;
const Button = @import("button.zig").Button;

const tagINITCOMMONCONTROLSEX = extern struct {
  dwSize: w.DWORD,
  dwICC: w.DWORD
};

const INITCOMMONCONTROLSEX = tagINITCOMMONCONTROLSEX;
const LPINITCOMMONCONTROLSEX = [*c]tagINITCOMMONCONTROLSEX;

extern "Comctl32" fn InitCommonControlsEx(picce: [*c]INITCOMMONCONTROLSEX) callconv(.C) w.BOOL;

pub export fn WinMain(hInstance: w.HINSTANCE, hPrevInstance: w.HINSTANCE, pCmdLine: w.LPWSTR, nCmdShow: c_int) callconv(.C) c_int {
    //const stdin = std.io.getStdIn().inStream();
    //_ = stdin.readByte() catch unreachable;
    var hr = w.CoInitializeEx(null, 0x2);

    var picce = INITCOMMONCONTROLSEX {
        .dwSize = @sizeOf(INITCOMMONCONTROLSEX),
        .dwICC = 0xff
    };

    _ = InitCommonControlsEx(&picce);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var main_window = MainWindow.create(hInstance, &arena.allocator) catch unreachable;

    var button = Button.create(hInstance, main_window.window.system_window, &arena.allocator) catch unreachable;
    main_window.window.system_window.addChild(button.window.system_window) catch unreachable;

    button.window.system_window.show();
    main_window.window.system_window.show();

    var msg: w.MSG = undefined;
    while (w.GetMessageW(&msg, null, 0, 0) != 0) {
        _ = w.TranslateMessage(&msg);
        _ = w.DispatchMessageW(&msg);
    }

    return 0;
}