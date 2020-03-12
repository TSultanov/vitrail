const std = @import("std");
const w = @import("win32").c;
const Layout = @import("layout.zig").Layout;
const Box = @import("box.zig").Box;
const Window = @import("window.zig").Window;

var layout: *Layout = undefined;
var globalHInstance: w.HINSTANCE = undefined;
var defaultIcon: w.HICON = undefined;

fn handleKeydown(wParam: w.WPARAM, lParam: w.LPARAM) void {
    switch (wParam) {
        w.VK_TAB => {
            layout.next();
        },
        w.VK_RIGHT => {
            layout.right();
        },
        w.VK_LEFT => {
            layout.left();
        },
        w.VK_UP => {
            layout.up();
        },
        w.VK_DOWN => {
            layout.down();
        },
        w.VK_ESCAPE => {
            layout.removeChildren();
        },
        w.VK_RETURN => {
            layout.switchToSelection();
        },
        else => {},
    }
}

fn registerClass(hInstance: w.HINSTANCE, className: w.LPCWSTR) void {
    const wc: w.WNDCLASSW = .{
        .style = 0,
        .lpfnWndProc = WindowProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hInstance,
        .hIcon = null,
        .hCursor = w.LoadCursor(null, 32512),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = className,
    };

    _ = w.RegisterClassW(&wc);
}

pub export fn WinMain(hInstance: w.HINSTANCE, hPrevInstance: w.HINSTANCE, pCmdLine: w.LPWSTR, nCmdShow: c_int) callconv(.C) c_int {
    globalHInstance = hInstance;
    _ = w.AllocConsole();

    layout = Layout.create();

    defaultIcon = w.LoadIconW(null, 32512);

    //Create invisible window just for message loop
    comptime var className: w.LPCWSTR = Window.toUtf16("MosaicSwitcher") catch unreachable;
    registerClass(hInstance, className);
    comptime var windowName: w.LPCWSTR = Window.toUtf16("MosaicSwitcher") catch unreachable;
    var invWindow = Window.create(0, className, windowName, w.WS_BORDER, 0, 0, 0, 0, null, null, hInstance, null);
    _ = w.SetWindowLong(invWindow.hwnd, w.GWL_STYLE, 0);

    installKeyboardHook();

    var msg: w.MSG = undefined;
    while (w.GetMessageW(&msg, null, 0, 0) != 0) {
        if (msg.message == w.WM_KEYDOWN) {
            handleKeydown(msg.wParam, msg.lParam);
        }
        else if (msg.message == w.WM_HOTKEY){
            showLayout();
        } else {
            _ = w.TranslateMessage(&msg);
            _ = w.DispatchMessage(&msg);
        }
    }

    return 0;
}

fn showLayout() void {
    if(!layout.isShowing()) {
        _ = w.EnumWindows(enumWindowProc, 0);
        layout.layout();
    }
}

fn getWindowTitle(hwnd: w.HWND) w.LPCWSTR {
    var title: *[512]u16 = std.heap.c_allocator.create([512]u16) catch unreachable;
    for (title[0..512]) |*b| b.* = 0;
    _ = w.GetWindowTextW(hwnd, title, 512);

    return title;
}

fn getWindowClass(hwnd: w.HWND) []const u16 {
    var class: *[512]u16 = std.heap.c_allocator.create([512]u16) catch unreachable;
    for (class[0..512]) |*b| b.* = 0;
    _ = w.RealGetWindowClassW(hwnd, class, 512);
    return class;
}

fn getWindowIcon(hwnd: w.HWND) w.HICON {
    var iconAddr: c_ulonglong = undefined;
    var lResult = w.SendMessageTimeoutW(hwnd, w.WM_GETICON, w.ICON_SMALL2, 0, w.SMTO_ABORTIFHUNG, 10, &iconAddr);
    if(lResult != 0 and iconAddr != 0)
    {
        var icon: w.HICON = @intToPtr(w.HICON, @intCast(usize, iconAddr));
        return icon;
    }

    var wndClassU = w.GetClassLongPtrW(hwnd, w.GCL_HICON);
    if(wndClassU != 0)
    {
        var icon: w.HICON = @intToPtr(w.HICON, wndClassU);
        return icon;
    }

    return defaultIcon;
}

fn enumWindowProc(hwnd: w.HWND, lParam: w.LPARAM) callconv(.C) c_int {
    var procId = w.GetWindowThreadProcessId(hwnd, null);
    var currProcId = w.GetCurrentProcessId();

    if(procId == currProcId) {
        std.debug.warn("Ignoring ourselves\n", .{});
        return 1;
    }

    var shouldShow = shouldShowWindow(hwnd);

    if(shouldShow)
    {
        var title = getWindowTitle(hwnd);
        var class = getWindowClass(hwnd);
        var icon: w.HICON = getWindowIcon(hwnd);
        var box = Box.create(globalHInstance, title, class, icon, hwnd) catch unreachable;
        layout.addChild(box);
    }
    return 1;
}

fn shouldShowWindow(hwnd: w.HWND) bool {
    var owner = w.GetWindow(hwnd, w.GW_OWNER);
    var ownerVisible = false;
    if (owner != null) {
        var ownerPwi: w.WINDOWINFO = undefined;
        _ = w.GetWindowInfo(hwnd, &ownerPwi);
        ownerVisible = ownerPwi.dwStyle & @intCast(c_ulong, w.WS_VISIBLE) != 0;
    }

    var pwi: w.WINDOWINFO = undefined;
    _ = w.GetWindowInfo(hwnd, &pwi);

    var titleLength = w.GetWindowTextLengthW(hwnd);

    var isVisible = pwi.dwStyle & @intCast(c_ulong, w.WS_VISIBLE) != 0;
    var hasTitle = titleLength > 0;
    var isAppWindow = pwi.dwExStyle & @intCast(c_ulong, w.WS_EX_APPWINDOW) != 0;
    var isToolWindow = (pwi.dwExStyle & @intCast(c_ulong, w.WS_EX_TOOLWINDOW) != 0);
    var isNoActivate = pwi.dwExStyle & @intCast(c_ulong, w.WS_EX_NOACTIVATE) != 0;
    var isDisabled = pwi.dwStyle & @intCast(c_ulong, w.WS_DISABLED) != 0;

    if (!isVisible) return false;
    if (!hasTitle) return false;
    if (isDisabled) return false;
    if (isAppWindow) return true;
    if (isToolWindow) return false;
    if (isNoActivate) return true;
    if (!(owner == null or !ownerVisible)) return false;

    comptime var taskListDeletedProp = Window.toUtf16("ITaskList_Deleted") catch unreachable;
    var taskListDeleted = w.GetPropW(hwnd, taskListDeletedProp);
    if(taskListDeleted != null) return false;
    
    var class = getWindowClass(hwnd);

    comptime var coreWindowClass = Window.toUtf16("Windows.UI.Core.CoreWindow") catch unreachable;
    if(std.mem.eql(u16, class, coreWindowClass)) return false;

    comptime var uwpAppClass = Window.toUtf16("ApplicationFrameWindow") catch unreachable;
    var isUwpApp = std.mem.eql(u16, class, uwpAppClass);
    comptime var cloakType = "ApplicationViewCloakType";
    // if (isUwpApp) {
    //     var cloakProp = w.GetProp(hwnd, cloakType);
    //     if(cloakProp != null) {
    //         var cloakStr = @ptrToInt(cloakProp.?);
    //         if (cloakStr == '2') return true;
    //     }
    //     return false;
    // }

    return true;
}

fn WindowProc(hwnd: w.HWND, uMsg: w.UINT, wParam: w.WPARAM, lParam: w.LPARAM) callconv(.C) w.LRESULT {
    return switch (uMsg) {
        w.WM_DESTROY => {
            w.PostQuitMessage(0);
            return 0;
        },
        w.WM_PAINT => {
            return 0;
        },
        else => w.DefWindowProcW(hwnd, uMsg, wParam, lParam),
    };
}

fn altTabHook(nCode: w.INT, wParam: w.WPARAM, lParam: w.LPARAM) callconv(.C) w.LRESULT {
    var pkbhs: w.LPKBDLLHOOKSTRUCT = @intToPtr(w.LPKBDLLHOOKSTRUCT, @intCast(usize, lParam));

    const LLKHF_UP = w.KF_UP >> 8;
    const LLKHF_ALTDOWN = w.KF_ALTDOWN >> 8;


    return switch (nCode) {
        0 => {
            //var isWinPressed = w.GetAsyncKeyState(w.VK_LWIN) & (1<<8) != 0;
            if(pkbhs.*.vkCode == w.VK_CAPITAL and pkbhs.*.flags & LLKHF_ALTDOWN != 0) {
                if (pkbhs.*.flags & LLKHF_UP == 0) {
                    showLayout();
                }
                return 1;
            }
            if(layout.isShowing() and pkbhs.*.flags & LLKHF_UP == 0) {
                handleKeydown(pkbhs.*.vkCode, 0);
                return 1;
            }
            return w.CallNextHookEx(null, nCode, wParam, lParam);
        },
        else => {
            return w.CallNextHookEx(null, nCode, wParam, lParam);
        },
    };
}

fn installKeyboardHook() void {
    //_ = w.SetWindowsHookEx(w.WH_KEYBOARD_LL, altTabHook, null, 0);
    _ = w.RegisterHotKey(null, 0, w.MOD_ALT, w.VK_SPACE);
}