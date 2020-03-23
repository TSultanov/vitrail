const std = @import("std");
const w = @import("win32").c;
const Layout = @import("layout.zig").Layout;
const Box = @import("box.zig").Box;
const Window = @import("window.zig").Window;
const si = @import("system_interaction.zig");
const virtualdesktop = @import("virtualdesktop.zig");

var layout: ?*Layout = undefined;
var globalHInstance: w.HINSTANCE = undefined;
var systemInteraction: si.SystemInteraction = undefined;
var arena: *std.heap.ArenaAllocator = undefined;

fn handleKeydown(wParam: w.WPARAM, lParam: w.LPARAM) void {
    switch (wParam) {
        w.VK_TAB => {
            var shiftPressed = w.GetKeyState(w.VK_SHIFT);
            if(shiftPressed != 0) {
                layout.?.prev();
            } else {
                layout.?.next();
            }
        },
        w.VK_RIGHT => {
            layout.?.right();
        },
        w.VK_LEFT => {
            layout.?.left();
        },
        w.VK_UP => {
            layout.?.up();
        },
        w.VK_DOWN => {
            layout.?.down();
        },
        w.VK_ESCAPE => {
            layout.?.removeChildren() catch unreachable;
            cleanup();
        },
        w.VK_RETURN => {
            layout.?.switchToSelection() catch unreachable;
            cleanup();
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
    //_ = w.FreeConsole();

    _ = w.CoInitializeEx(null, 0x2| 0x4);

    //Create invisible window just for message loop
    comptime var className: w.LPCWSTR = Window.toUtf16("MosaicSwitcher") catch unreachable;
    registerClass(hInstance, className);
    comptime var windowName: w.LPCWSTR = Window.toUtf16("MosaicSwitcher") catch unreachable;
    var invWindow = Window.create(0, className, windowName, w.WS_BORDER, 0, 0, 0, 0, null, null, hInstance, null);
    _ = w.SetWindowLong(invWindow.hwnd, w.GWL_STYLE, 0);

    globalHInstance = hInstance;

    arena = std.heap.c_allocator.create(std.heap.ArenaAllocator) catch unreachable;
    defer std.heap.c_allocator.destroy(arena);

    installKeyboardHook();

    showLayout() catch unreachable;

    var msg: w.MSG = undefined;
    while (w.GetMessageW(&msg, null, 0, 0) != 0) {
        if (msg.message == w.WM_KEYDOWN) {
            handleKeydown(msg.wParam, msg.lParam);
        }
        else if (msg.message == w.WM_HOTKEY){
            //TOOD: complain and die on error;
            showLayout() catch unreachable;
        } else {
            _ = w.TranslateMessage(&msg);
            _ = w.DispatchMessage(&msg);
        }
    }

    return 0;
}

fn cleanup() void {
    arena.deinit();
    layout = null;
}

fn showLayout() !void {
    if(layout == null) {
        arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        systemInteraction = si.init(globalHInstance, &arena.allocator);

        var desktopManager = try virtualdesktop.create();

        var desktopWindows = try systemInteraction.getWindowList();
        layout = try Layout.create(&arena.allocator);
        for (desktopWindows) |dWindow| {
            if(dWindow.shouldShow) {
                var box = try Box.create(globalHInstance, dWindow.title, dWindow.class, dWindow.icon, dWindow.hwnd, &arena.allocator);
                var dId: w.GUID = undefined;
                _ = desktopManager.GetWindowDesktopId(dWindow.hwnd, &dId);
                std.debug.warn("hwnd: {}, windowsDesktopId: {}\n", .{dWindow.hwnd, dId});
                try layout.?.addChild(box);
            }
        }
        try layout.?.layout();

        _ = desktopManager.Release();
    }
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

fn installKeyboardHook() void {
    _ = w.RegisterHotKey(null, 0, w.MOD_ALT, w.VK_SPACE);
}