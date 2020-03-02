const std = @import("std");
const w = @import("win32").c;

pub const Window = struct {
    hwnd: w.HWND,
    title: w.LPCWSTR,
    className: w.LPCWSTR,
    hInstance: w.HINSTANCE,

    pub fn create(exStyle: w.DWORD, className: w.LPCWSTR, title: w.LPCWSTR, style: w.DWORD, x: c_int, y: c_int, width: c_int, height: c_int, parent: ?Window, menu: w.HMENU, hInstance: w.HINSTANCE, lpParam: w.LPVOID) Window {
        var hwnd = w.CreateWindowExW(exStyle, className, title, style, x, y, width, height, if (parent == null) null else parent.?.hwnd, menu, hInstance, lpParam);
        return Window{
            .hwnd = hwnd,
            .title = title,
            .className = className,
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
            _ = w.DispatchMessage(&msg);
        }
    }

    pub fn toUtf16(str: []const u8) ![:0]u16 {
        var buf: [512]u16 = undefined;
        _ = try std.unicode.utf8ToUtf16Le(&buf, str);
        return buf[0..:0];
    }
};
