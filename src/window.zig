usingnamespace @import("vitrail.zig");

const Self = @This();

const defaultDpi = 96;

hwnd: w.HWND,
hInstance: w.HINSTANCE,
children: std.ArrayList(*Self),
event_handlers: *EventHandlers,
docked: bool = false,
parent: ?*Self,
dpi: u32,

pub fn dock(self: *Self) !void {
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

pub fn setSize(self: *Self, x: c_int, y: c_int, cx: c_int, cy: c_int) !void {
    try w.mapFailure(w.SetWindowPos(self.hwnd, null, x, y, cx, cy, w.SWP_NOCOPYBITS));
}

pub fn setSizeScaled(self: *Self, x: c_int, y: c_int, cx: c_int, cy: c_int) !void {
    try w.mapFailure(w.SetWindowPos(self.hwnd, null, self.scaleDpi(x), self.scaleDpi(y), self.scaleDpi(cx), self.scaleDpi(cy), w.SWP_NOCOPYBITS));
}

pub fn getRect(self: Self) !w.RECT {
    var rect: w.RECT = undefined;
    try w.mapFailure(w.GetWindowRect(self.hwnd, &rect));
    return rect;
}

pub fn getClientRect(self: Self) !w.RECT {
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
    _ = w.SetFocus(self.hwnd);
}

pub fn destroy(self: Self) void {
    for(self.children.items) |child| {
        child.destroy();
    }

    _ = w.DestroyWindow(self.hwnd);
}

pub fn activate(self: *Self) void {
    _ = w.SetActiveWindow(self.hwnd);
}

pub const WindowParameters = struct {
    exStyle: w.DWORD = 0,
    className: [:0]u16 = toUtf16const("Vitrail"),
    title: ?[:0]u16 = toUtf16const("Window"),
    style: w.DWORD = w.WS_OVERLAPPEDWINDOW,
    x: c_int = 100,
    y: c_int = 100,
    width: c_int = 640,
    height: c_int = 480,
    parent: ?*Self = null,
    menu: w.HMENU = null,
    register_class: bool = true
};

fn defaultHandler(event_handlers: *EventHandlers, window: *Self) !void {}

fn defaultParamHandler(event_handlers: *EventHandlers, window: *Self, wParam: w.WPARAM, lParam: w.LPARAM) !void {}

pub const EventHandlers = struct {
    onClick: fn (self: *EventHandlers, window: *Self) anyerror!void = defaultHandler,
    onResize: fn (self: *EventHandlers, window: *Self) anyerror!void = onResizeHandler,
    onCreate: fn (self: *EventHandlers, window: *Self) anyerror!void = defaultHandler,
    onDestroy: fn (self: *EventHandlers, window: *Self) anyerror!void = defaultHandler,
    onAfterDestroy: fn (self: *EventHandlers, window: *Self) anyerror!void = defaultHandler,
    onPaint: fn (self: *EventHandlers, window: *Self) anyerror!void = onPaintHandler,
    onCommand: fn (self: *EventHandlers, window: *Self, wParam: w.WPARAM, lParam: w.LPARAM) anyerror!void = defaultParamHandler,
    onNotify: fn (self: *EventHandlers, window: *Self) anyerror!void = defaultHandler,
    onDpiChange: fn(self: *EventHandlers, window: *Self, wParam: w.WPARAM, lParam: w.LPARAM) anyerror!void = onDpiChangeHandler,
    onMouseMove: fn(self: *EventHandlers, window: *Self, keys: u64, x: i16, y: i16) anyerror!void = onMouseMoveDefaultHandler,
    onMouseLeave: fn (self: *EventHandlers, window: *Self) anyerror!void = defaultHandler,
    onActivate: fn (self: *EventHandlers, window: *Self, wParam: w.WPARAM, lParam: w.LPARAM) anyerror!void = defaultParamHandler,
    onSetFocus: fn (self: *EventHandlers, window: *Self, wParam: w.WPARAM, lParam: w.LPARAM) anyerror!void = defaultParamHandler,
    onKillFocus: fn (self: *EventHandlers, window: *Self, wParam: w.WPARAM, lParam: w.LPARAM) anyerror!void = defaultParamHandler,
    onKeyDown: fn (self: *EventHandlers, window: *Self, wParam: w.WPARAM, lParam: w.LPARAM) anyerror!void = defaultParamHandler,
    onChar: fn (self: *EventHandlers, window: *Self, wParam: w.WPARAM, lParam: w.LPARAM) anyerror!void = defaultParamHandler,
};

pub fn onMouseMoveDefaultHandler(event_handlers: *EventHandlers, window: *Self, keys: u64, x: i16, y: i16) !void {}

pub fn onDpiChangeHandler(event_handlers: *EventHandlers, window: *Self, wParam: w.WPARAM, lParam: w.LPARAM) !void {
    window.dpi = w.GetDpiForWindow(window.hwnd);
    const rect = @intToPtr(*w.RECT, @intCast(usize, lParam));
    try window.setSize(rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top);
}

fn onResizeHandler(event_handlers: *EventHandlers, window: *Self) !void {
    if(window.docked)
    {
        try window.dock();
    }

    for (window.children.items) |child| {
        try child.resize();
    }
}

pub fn resize(self: *Self) !void {
    try self.event_handlers.onResize(self.event_handlers, self);
}

fn onPaintHandler(event_handlers: *EventHandlers, window: *Self) !void {
    var ps: w.PAINTSTRUCT = undefined;
    var hdc = w.BeginPaint(window.hwnd, &ps);
    defer _ = w.EndPaint(window.hwnd, &ps);
    defer _ = w.ReleaseDC(window.hwnd, hdc);
    var hbrushBg = w.CreateSolidBrush(0x00aaaaaa);
    defer w.mapFailure(w.DeleteObject(hbrushBg)) catch std.debug.panic("Failed to call DeleteObject() on {*}\n", .{hbrushBg});
    try w.mapFailure(w.FillRect(hdc, &ps.rcPaint, hbrushBg));
}

fn WindowProc(hwnd: w.HWND, uMsg: w.UINT, wParam: w.WPARAM, lParam: w.LPARAM) callconv(std.os.windows.WINAPI) w.LRESULT {
    var wLong = w.GetWindowLongPtr(hwnd, w.GWLP_USERDATA);
    if (wLong == 0) {
        return w.DefWindowProcW(hwnd, uMsg, wParam, lParam);
    }

    var window = @intToPtr(*Self, @bitCast(usize, wLong));

    return window.wndProc(uMsg, wParam, lParam) catch return 1;
}

pub fn wndProc(self: *Self, uMsg: w.UINT, wParam: w.WPARAM, lParam: w.LPARAM) !w.LRESULT {
    switch (uMsg) {
        w.WM_SIZE => {
            try self.event_handlers.onResize(self.event_handlers, self);
            return 0;
        },
        w.WM_LBUTTONDOWN => {
            try self.event_handlers.onClick(self.event_handlers, self);
            return 0;
        },
        w.WM_MOUSEMOVE => {
            const x: i16 = @intCast(i16, lParam & 0xff);
            const y: i16 = @intCast(i16, (lParam >> 16) & 0xff);
            try self.event_handlers.onMouseMove(self.event_handlers, self, wParam, x, y);
            self.startMouseTracking();
            return 0;
        },
        w.WM_MOUSELEAVE => {
            try self.event_handlers.onMouseLeave(self.event_handlers, self);
            return 0;
        },
        w.WM_CREATE => {
            try self.event_handlers.onCreate(self.event_handlers, self);
            return 0;
        },
        w.WM_DESTROY => {
            try self.event_handlers.onDestroy(self.event_handlers, self);
            return 0;
        },
        w.WM_NCDESTROY => {
            try self.event_handlers.onAfterDestroy(self.event_handlers, self);
            return 0;
        },
        w.WM_PAINT => {
            try self.event_handlers.onPaint(self.event_handlers, self);
            return 0;
        },
        w.WM_COMMAND => {
            try self.event_handlers.onCommand(self.event_handlers, self, wParam, lParam);
            return 0;
        },
        w.WM_NOTIFY => {
            try self.event_handlers.onNotify(self.event_handlers, self);
            return 0;
        },
        w.WM_DPICHANGED => {
            try self.event_handlers.onDpiChange(self.event_handlers, self, wParam, lParam);
            return 0;
        },
        w.WM_ACTIVATE => {
            try self.event_handlers.onActivate(self.event_handlers, self, wParam, lParam);
            return 0;  
        },
        w.WM_SETFOCUS => {
            try self.event_handlers.onSetFocus(self.event_handlers, self, wParam, lParam);
            return 0;  
        },
        w.WM_KILLFOCUS => {
            try self.event_handlers.onKillFocus(self.event_handlers, self, wParam, lParam);
            return 0;  
        },
        w.WM_KEYDOWN => {
            try self.event_handlers.onKeyDown(self.event_handlers, self, wParam, lParam);
            return 0;
        },
        w.WM_CHAR => {
            try self.event_handlers.onChar(self.event_handlers, self, wParam, lParam);
            return 0;
        },
        else => {
            return w.DefWindowProcW(self.hwnd, uMsg, wParam, lParam);
        },
    }
}

pub fn create(window_parameters: WindowParameters, event_handlers: *EventHandlers, hInstance: w.HINSTANCE, allocator: *std.mem.Allocator) !*Self {
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
    var hwnd = w.CreateWindowExW(window_parameters.exStyle, window_parameters.className, if (window_parameters.title) |title| title else null, window_parameters.style, window_parameters.x, window_parameters.y, window_parameters.width, window_parameters.height, parent, window_parameters.menu, hInstance, null);

    var window = try allocator.create(Self);
    window.* = Self {
        .hwnd = hwnd,
        .hInstance = hInstance,
        .children = std.ArrayList(*Self).init(allocator),
        .event_handlers = event_handlers,
        .parent = window_parameters.parent,
        .dpi = w.GetDpiForWindow(hwnd),
    };

    if(window.parent) |p| {
        try p.children.append(window);
    }

    var rect = try window.getRect();
    try window.setSize(rect.left, rect.top, window.scaleDpi(rect.right - rect.left), window.scaleDpi(rect.bottom - rect.top));

    _ = w.SetWindowLongPtr(hwnd, w.GWLP_USERDATA, @bitCast(c_longlong, @ptrToInt(window)));
    var font = w.GetStockObject(w.DEFAULT_GUI_FONT);
    _ = w.SendMessage(hwnd, w.WM_SETFONT, @ptrToInt(font), 1);

    return window;
}

pub fn startMouseTracking(self: Self) void {
    var config: w.TRACKMOUSEEVENT = .{
        .cbSize = @sizeOf(w.TRACKMOUSEEVENT),
        .dwFlags = w.TME_LEAVE,
        .hwndTrack = self.hwnd,
        .dwHoverTime = w.HOVER_DEFAULT
    };

    _ = w.TrackMouseEvent(&config);
}

pub fn scaleDpi(self: Self, x: i32) i32 {
    return w.MulDiv(x, @intCast(i32, self.dpi), defaultDpi);
}

pub fn unscaleDpi(self: Self, x: i32) i32 {
    return w.MulDiv(x, defaultDpi, @intCast(i32, self.dpi));
}

pub fn getChildRgn(self: Self) !w.HRGN {
    var hRgn = w.CreateRectRgn(0,0,0,0);
    for(self.children.items) |child| {
        std.debug.warn("Gettign rgn of {*}\n", .{child.hwnd});
        var childRgn = child.getRgn();
        defer _ = w.DeleteObject(childRgn);
        var newRgn: w.HRGN = undefined;
        _ = w.CombineRgn(newRgn, hRgn, childRgn, w.RGN_OR);
        _ = w.DeleteObject(hRgn);
        hRgn = newRgn;
    }
    return hRgn;
}

pub fn bringToTop(self: Self) !void {
    try w.mapErr(w.BringWindowToTop(self.hwnd));
}

pub fn setFont(self: Self, font: w.HGDIOBJ) !void {
    _ = SendMessage(self.hwnd, w.WM_SETFONT, font, 0);
}