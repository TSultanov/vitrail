const std = @import("std");
const sys = @import("SystemInteraction.zig");
const wh = @import("windows.zig");
const w = wh.c;

const Self = @This();

const defaultDpi = 96;

hwnd: w.HWND,
hInstance: w.HINSTANCE,
children: std.array_list.Managed(*Self),
event_handlers: *EventHandlers,
docked: bool = false,
parent: ?*Self,
dpi: u32,

pub fn dock(self: *Self) !void {
    if (self.parent) |parent| {
        const rect = try parent.getRect();
        try self.setSize(0, 0, rect.right - rect.left, rect.bottom - rect.top);
    }
}

pub fn show(self: Self) bool {
    return w.ShowWindow(self.hwnd, w.SW_SHOW) != 0;
}

pub fn hide(self: Self) bool {
    return w.ShowWindow(self.hwnd, w.SW_HIDE) != 0;
}

pub fn redraw(self: Self) !void {
    try wh.mapFailure(w.RedrawWindow(self.hwnd, null, null, w.RDW_INVALIDATE | w.RDW_UPDATENOW));
}

pub fn setSize(self: *Self, x: c_int, y: c_int, cx: c_int, cy: c_int) !void {
    try wh.mapFailure(w.SetWindowPos(self.hwnd, null, x, y, cx, cy, w.SWP_NOCOPYBITS));
}

pub fn setSizeScaled(self: *Self, x: c_int, y: c_int, cx: c_int, cy: c_int) !void {
    try wh.mapFailure(w.SetWindowPos(self.hwnd, null, self.scaleDpi(x), self.scaleDpi(y), self.scaleDpi(cx), self.scaleDpi(cy), w.SWP_NOCOPYBITS));
}

pub fn getRect(self: Self) !w.RECT {
    var rect: w.RECT = undefined;
    try wh.mapFailure(w.GetWindowRect(self.hwnd, &rect));
    return rect;
}

pub fn getClientRect(self: Self) !w.RECT {
    var rect: w.RECT = undefined;
    try wh.mapFailure(w.GetClientRect(self.hwnd, &rect));
    return rect;
}

pub fn focus(self: Self) !void {
    _ = w.SetFocus(self.hwnd);
}

pub fn activate(self: *Self) void {
    _ = w.SetActiveWindow(self.hwnd);
}

pub const WindowParameters = struct {
    exStyle: w.DWORD = 0,
    className: [:0]const u16 = sys.toUtf16const("Vitrail"),
    title: ?[:0]const u16 = sys.toUtf16const("Window"),
    style: w.DWORD = w.WS_OVERLAPPEDWINDOW,
    x: c_int = 100,
    y: c_int = 100,
    width: c_int = 640,
    height: c_int = 480,
    parent: ?*Self = null,
    menu: w.HMENU = null,
    register_class: bool = true,
};

fn defaultHandler(_: *EventHandlers, _: *Self) !void {}

fn defaultParamHandler(_: *EventHandlers, _: *Self, _: w.WPARAM, _: w.LPARAM) !void {}

pub const EventHandlers = struct {
    onClick: *const fn (self: *EventHandlers, window: *Self) anyerror!void = defaultHandler,
    onResize: *const fn (self: *EventHandlers, window: *Self) anyerror!void = onResizeHandler,
    onCreate: *const fn (self: *EventHandlers, window: *Self) anyerror!void = defaultHandler,
    onDestroy: *const fn (self: *EventHandlers, window: *Self) anyerror!void = defaultHandler,
    onAfterDestroy: *const fn (self: *EventHandlers, window: *Self) anyerror!void = defaultHandler,
    onPaint: *const fn (self: *EventHandlers, window: *Self) anyerror!void = defaultHandler,
    onDpiChange: *const fn (self: *EventHandlers, window: *Self, wParam: w.WPARAM, lParam: w.LPARAM) anyerror!void = onDpiChangeHandler,
    onMouseMove: *const fn (self: *EventHandlers, window: *Self, keys: u64, x: i16, y: i16) anyerror!void = onMouseMoveDefaultHandler,
    onActivate: *const fn (self: *EventHandlers, window: *Self, wParam: w.WPARAM, lParam: w.LPARAM) anyerror!void = defaultParamHandler,
    onSetFocus: *const fn (self: *EventHandlers, window: *Self, wParam: w.WPARAM, lParam: w.LPARAM) anyerror!void = defaultParamHandler,
    onKillFocus: *const fn (self: *EventHandlers, window: *Self, wParam: w.WPARAM, lParam: w.LPARAM) anyerror!void = defaultParamHandler,
    onKeyDown: *const fn (self: *EventHandlers, window: *Self, wParam: w.WPARAM, lParam: w.LPARAM) anyerror!void = defaultParamHandler,
    onChar: *const fn (self: *EventHandlers, window: *Self, wParam: w.WPARAM, lParam: w.LPARAM) anyerror!void = defaultParamHandler,
    onEnable: *const fn (self: *EventHandlers, window: *Self, wParam: w.WPARAM, lParam: w.LPARAM) anyerror!void = defaultParamHandler,
};

pub fn onMouseMoveDefaultHandler(_: *EventHandlers, _: *Self, _: u64, _: i16, _: i16) !void {}

pub fn onDpiChangeHandler(_: *EventHandlers, window: *Self, _: w.WPARAM, lParam: w.LPARAM) !void {
    const dpi = w.GetDpiForWindow(window.hwnd);
    window.setDpi(dpi);
    if (lParam != 0) {
        const rect: *w.RECT = @ptrFromInt(@as(usize, @intCast(lParam)));
        try window.setSizeScaled(rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top);
    }
}

pub fn setDpi(self: *Self, dpi: u32) void {
    self.dpi = dpi;
    for (self.children.items) |child| {
        child.setDpi(dpi);
    }
    _ = w.SendMessageW(self.hwnd, w.WM_SIZE, 0, 0);
}

fn onResizeHandler(_: *EventHandlers, window: *Self) !void {
    if (window.docked) {
        try window.dock();
    }

    for (window.children.items) |child| {
        try child.resize();
    }
}

pub fn resize(self: *Self) !void {
    try self.event_handlers.onResize(self.event_handlers, self);
}

fn WindowProc(hwnd: w.HWND, uMsg: w.UINT, wParam: w.WPARAM, lParam: w.LPARAM) callconv(.winapi) w.LRESULT {
    const wLong = w.GetWindowLongPtrW(hwnd, w.GWLP_USERDATA);
    if (wLong == 0) {
        return w.DefWindowProcW(hwnd, uMsg, wParam, lParam);
    }

    const window: *Self = @ptrFromInt(@as(usize, @bitCast(wLong)));

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
            const x: i16 = @truncate(lParam);
            const y: i16 = @truncate(lParam >> 16);
            try self.event_handlers.onMouseMove(self.event_handlers, self, wParam, x, y);
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
        w.WM_ENABLE => {
            try self.event_handlers.onEnable(self.event_handlers, self, wParam, lParam);
            return 0;
        },
        else => {
            return w.DefWindowProcW(self.hwnd, uMsg, wParam, lParam);
        },
    }
}

pub fn create(window_parameters: WindowParameters, event_handlers: *EventHandlers, hInstance: w.HINSTANCE, allocator: std.mem.Allocator) !*Self {
    if (window_parameters.register_class) {
        const wc: w.WNDCLASSW = .{
            .style = 0,
            .lpfnWndProc = WindowProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hInstance,
            .hIcon = null,
            .hCursor = w.LoadCursorW(null, @ptrFromInt(32512)),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = window_parameters.className,
        };

        try wh.mapErr(w.RegisterClassW(&wc));
    }

    const parent: w.HWND = if (window_parameters.parent) |p| p.hwnd else null;
    const hwnd = w.CreateWindowExW(window_parameters.exStyle, window_parameters.className, if (window_parameters.title) |title| title else null, window_parameters.style, window_parameters.x, window_parameters.y, window_parameters.width, window_parameters.height, parent, window_parameters.menu, hInstance, null);

    var window = try allocator.create(Self);
    window.* = Self{
        .hwnd = hwnd,
        .hInstance = hInstance,
        .children = std.array_list.Managed(*Self).init(allocator),
        .event_handlers = event_handlers,
        .parent = window_parameters.parent,
        .dpi = w.GetDpiForWindow(hwnd),
    };

    if (window.parent) |p| {
        try p.children.append(window);
    }

    const rect = try window.getRect();
    try window.setSize(rect.left, rect.top, window.scaleDpi(rect.right - rect.left), window.scaleDpi(rect.bottom - rect.top));

    _ = w.SetWindowLongPtrW(hwnd, w.GWLP_USERDATA, @bitCast(@as(c_ulonglong, @intFromPtr(window))));
    const font = w.GetStockObject(w.DEFAULT_GUI_FONT);
    _ = w.SendMessageW(hwnd, w.WM_SETFONT, @intFromPtr(font), 1);

    return window;
}

pub fn scaleDpi(self: Self, x: i32) i32 {
    return w.MulDiv(x, @as(i32, @intCast(self.dpi)), defaultDpi);
}

pub fn isVisible(self: Self) bool {
    return w.IsWindowVisible(self.hwnd) != 0;
}
