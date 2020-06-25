const std = @import("std");
const w = @import("win32").c;
const toUtf16const = @import("system_interaction.zig").toUtf16const;

fn WindowProc(hwnd: w.HWND, uMsg: w.UINT, wParam: w.WPARAM, lParam: w.LPARAM) callconv(.C) w.LRESULT {
    var wLong = w.GetWindowLongPtr(hwnd, w.GWLP_USERDATA);
    if(wLong == 0) {
        return w.DefWindowProcW(hwnd, uMsg, wParam, lParam);
    }

    var wndProc = @intToPtr(WndProc, @bitCast(usize, wLong));
    return wndProc(hwnd, uMsg, wParam, lParam);
}

pub const WndProc = fn (hWnd: w.HWND, uMsg: w.UINT, wParam: w.WPARAM, lParam: w.LPARAM) w.LRESULT;

pub const WindowParameters = struct {
    exStyle: w.DWORD = 0,
    className: w.LPCWSTR = toUtf16const("Vitrail"),
    title: w.LPCWSTR = toUtf16const("Window"),
    style: w.DWORD = w.WS_OVERLAPPEDWINDOW,
    x: c_int = 100,
    y: c_int = 100,
    width: c_int = 100,
    height: c_int = 100,
    parent: ?Window = null,
    menu: w.HMENU = null,
    wndProc: WndProc
};

pub const Window = struct {
    hwnd: w.HWND,
    hInstance: w.HINSTANCE,

    pub fn create(windowParameters: WindowParameters, hInstance: w.HINSTANCE) Window {
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
            .lpszClassName = windowParameters.className,
        };

        _ = w.RegisterClassW(&wc);

        var hwnd = w.CreateWindowExW(windowParameters.exStyle, windowParameters.className, windowParameters.title, windowParameters.style, windowParameters.x, windowParameters.y, windowParameters.width, windowParameters.height, if(windowParameters.parent) |p| p.hwnd else null, windowParameters.menu, hInstance, null);

        _ = w.SetWindowLongPtr(hwnd, w.GWLP_USERDATA, @bitCast(c_longlong, @ptrToInt(windowParameters.wndProc)));

        return Window{
            .hwnd = hwnd,
            .hInstance = hInstance,
        };
    }

    pub fn show(self: Window) void {
        _ = w.ShowWindow(self.hwnd, w.SW_SHOW);
    }

    pub fn hide(self: Window) void {
        _ = w.ShowWindow(self.hwnd, w.SW_HIDE);
    }

    pub fn update(self: Window) void {
        _ = w.UpdateWindow(self.hwnd);
    }

    pub fn getRgn(self: Window) w.HRGN {
        var rgn: w.HRGN = undefined;
        _ = w.GetWindowRgn(self.hwnd, rgn);
        return rgn;
    }

    pub fn redraw(self: Window) void {
        //var rect = self.getRect();
        //var rgn = self.getRgn();
        //std.debug.warn("Redraw on {} {} {} {}\n", .{rect.left, rect.right, rect.top, rect.bottom});
        _ = w.RedrawWindow(self.hwnd, null, null, w.RDW_INVALIDATE | w.RDW_UPDATENOW);
    }

    pub fn setSize(self: Window, x: c_int, y: c_int, cx: c_int, cy: c_int) void {
        _ = w.SetWindowPos(self.hwnd, 0, x, y, cx, cy, w.SWP_NOZORDER);
    }

    pub fn getRect(self: Window) w.RECT {
        var rect: w.RECT = undefined;
        _ = w.GetWindowRect(self.hwnd, &rect);
        return rect;
    }

    pub fn getClientRect(self: Window) w.RECT {
        var rect: w.RECT = undefined;
        _ = w.GetClientRect(self.hwnd, &rect);
        return rect;
    }

    pub fn dockChild(self: Window, child: *Window) void {
        var rect = self.getRect();
        child.*.setSize(0, 0, rect.right - rect.left, rect.bottom - rect.top);
    }

    pub fn setParent(self: Window, parent: Window) void {
        _ = w.SetParent(self.hwnd, parent.hwnd);
    }

    pub fn focus(self: Window) void {
        _ = w.SetFocus(self.hwnd);
    }

    pub fn destroy(self: Window) void {
        _ = w.DestroyWindow(self.hwnd);
    }

    pub fn loop(self: Window) void {
        var msg: w.MSG = undefined;

        while (w.GetMessageW(&msg, self.hwnd, 0, 0) != 0) {
            _ = w.TranslateMessage(&msg);
            _ = w.DispatchMessageW(&msg);
        }
    }
};
