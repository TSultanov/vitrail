usingnamespace @import("vitrail.zig");

const Self = @This();

hwnd: w.HWND,
hInstance: w.HINSTANCE,
children: *std.ArrayList(*Self),
event_handlers: WindowEventHandlers,
docked: bool = false,
parent: ?*Self,

pub fn dock(self: Self) !void {
    if (self.parent) |parent| {
        var rect = try parent.getRect();
        try self.setSize(0, 0, rect.right - rect.left, rect.bottom - rect.top);
    }
}

pub fn show(self: Self) bool {
    return w.ShowWindow(self.hwnd, w.SW_SHOW) != 0;
}

pub fn hide(self: Self) bool {
    return w.ShowWindow(self.hwnd, w.SW_HIDE) != 0;
}

pub fn update(self: Self) void {
    try w.mapFailure(w.UpdateWindow(self.hwnd));
}

pub fn getRgn(self: Self) w.HRGN {
    var rgn: w.HRGN = undefined;
    _ = w.GetWindowRgn(self.hwnd, rgn);
    return rgn;
}

pub fn redraw(self: Self) !void {
    try w.mapFailure(w.RedrawWindow(self.hwnd, null, null, w.RDW_INVALIDATE | w.RDW_UPDATENOW));
}

pub fn setSize(self: Self, x: c_int, y: c_int, cx: c_int, cy: c_int) !void {
    try w.mapFailure(w.SetWindowPos(self.hwnd, 0, x, y, cx, cy, w.SWP_NOZORDER));
}

pub fn getRect(self: Self) !w.RECT {
    var rect: w.RECT = undefined;
    try w.mapFailure(w.GetWindowRect(self.hwnd, &rect));
    return rect;
}

pub fn getClientRect(self: Self) w.RECT {
    var rect: w.RECT = undefined;
    try w.mapFailure(w.GetClientRect(self.hwnd, &rect));
    return rect;
}

pub fn addChild(self: Self, child: Self) !void {
    try self.children.append(child);
    try child.setParent(self);
}

pub fn setParent(self: *Self, parent: Self) !void {
    self.parent = parent;
    try w.mapFailure(w.SetParent(self.hwnd, parent.hwnd));
}

pub fn focus(self: Self) !void {
    try w.mapFailure(w.SetFocus(self.hwnd));
}

pub fn destroy(self: Self) !void {
    try w.mapFailure(w.DestroyWindow(self.hwnd));
}

pub const WindowParameters = struct { exStyle: w.DWORD = 0, className: [:0]u16 = toUtf16const("Vitrail"), title: [:0]u16 = toUtf16const("Window"), style: w.DWORD = w.WS_OVERLAPPEDWINDOW, x: c_int = 100, y: c_int = 100, width: c_int = 640, height: c_int = 480, parent: ?*Self = null, menu: w.HMENU = null, register_class: bool = true };

fn defaultHandler(window: Self) !void {}

pub const WindowEventHandlers = struct {
    onClick: fn (window: Self) anyerror!void = defaultHandler,
    onResize: fn (window: Self) anyerror!void = onResizeHandler,
    onCreate: fn (window: Self) anyerror!void = defaultHandler,
    onDestroy: fn (window: Self) anyerror!void = defaultHandler,
    onPaint: fn (window: Self) anyerror!void = onPaintHandler,
};

fn onResizeHandler(window: Self) !void {
    for (window.children.items) |child| {
        if (child.docked) {
            try child.dock();
        }
    }
}

fn onPaintHandler(window: Self) !void {
    var ps: w.PAINTSTRUCT = undefined;
    var hdc = w.BeginPaint(window.hwnd, &ps);
    defer _ = w.EndPaint(window.hwnd, &ps);
    defer _ = w.ReleaseDC(window.hwnd, hdc);
    var color = w.GetSysColor(w.COLOR_WINDOW);
    var hbrushBg = w.CreateSolidBrush(color);
    try w.mapFailure(w.FillRect(hdc, &ps.rcPaint, hbrushBg));
    try w.mapFailure(w.DeleteObject(hbrushBg));
}

fn WindowProc(hwnd: w.HWND, uMsg: w.UINT, wParam: w.WPARAM, lParam: w.LPARAM) callconv(.C) w.LRESULT {
    var wLong = w.GetWindowLongPtr(hwnd, w.GWLP_USERDATA);
    if (wLong == 0) {
        return w.DefWindowProcW(hwnd, uMsg, wParam, lParam);
    }

    var window = @intToPtr(*Self, @bitCast(usize, wLong));

    return window.wndProc(uMsg, wParam, lParam) catch return 1;
}

pub fn wndProc(self: Self, uMsg: w.UINT, wParam: w.WPARAM, lParam: w.LPARAM) !w.LRESULT {
    switch (uMsg) {
        w.WM_SIZE => {
            try self.event_handlers.onResize(self);
            return 0;
        },
        w.WM_LBUTTONDOWN => {
            try self.event_handlers.onClick(self);
            return 0;
        },
        w.WM_CREATE => {
            try self.event_handlers.onCreate(self);
            return 0;
        },
        w.WM_DESTROY => {
            try self.event_handlers.onDestroy(self);
            return 0;
        },
        w.WM_PAINT => {
            try self.event_handlers.onPaint(self);
            return 0;
        },
        else => {
            return w.DefWindowProcW(self.hwnd, uMsg, wParam, lParam);
        },
    }
}

pub fn create(window_parameters: WindowParameters, event_handlers: WindowEventHandlers, hInstance: w.HINSTANCE, allocator: *std.mem.Allocator) !*Self {
    if (window_parameters.register_class) {
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
            .lpszClassName = window_parameters.className,
        };

        try w.mapErr(w.RegisterClassW(&wc));
    }

    var parent: w.HWND = if (window_parameters.parent) |p| p.hwnd else null;
    var hwnd = w.CreateWindowExW(window_parameters.exStyle, window_parameters.className, window_parameters.title, window_parameters.style, window_parameters.x, window_parameters.y, window_parameters.width, window_parameters.height, parent, window_parameters.menu, hInstance, null);

    var children = try allocator.create(std.ArrayList(*Self));
    children.* = std.ArrayList(*Self).init(allocator);

    var window = try allocator.create(Self);
    window.* = Self{ .hwnd = hwnd, .hInstance = hInstance, .children = children, .event_handlers = event_handlers, .parent = window_parameters.parent };

    _ = w.SetWindowLongPtr(hwnd, w.GWLP_USERDATA, @bitCast(c_longlong, @ptrToInt(window)));
    var font = w.GetStockObject(w.DEFAULT_GUI_FONT);
    _ = w.SendMessage(hwnd, w.WM_SETFONT, @ptrToInt(font), 1);

    return window;
}
