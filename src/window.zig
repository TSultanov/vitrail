usingnamespace @import("vitrail.zig");

pub const SystemWindow = struct {
    hwnd: w.HWND,
    hInstance: w.HINSTANCE,
    children: *std.ArrayList(@This()),

    pub fn dockChild(self: @This(), child: @This()) void {
        var rect = self.getRect();
        child.setSize(0, 0, rect.right - rect.left, rect.bottom - rect.top);
    }

    pub fn show(self: @This()) void {
        _ = w.ShowWindow(self.hwnd, w.SW_SHOW);
    }

    pub fn hide(self: @This()) void {
        _ = w.ShowWindow(self.hwnd, w.SW_HIDE);
    }

    pub fn update(self: @This()) void {
        _ = w.UpdateWindow(self.hwnd);
    }

    pub fn getRgn(self: @This()) w.HRGN {
        var rgn: w.HRGN = undefined;
        _ = w.GetWindowRgn(self.hwnd, rgn);
        return rgn;
    }

    pub fn redraw(self: @This()) void {
        _ = w.RedrawWindow(self.hwnd, null, null, w.RDW_INVALIDATE | w.RDW_UPDATENOW);
    }

    pub fn setSize(self: @This(), x: c_int, y: c_int, cx: c_int, cy: c_int) void {
        _ = w.SetWindowPos(self.hwnd, 0, x, y, cx, cy, w.SWP_NOZORDER);
    }

    pub fn getRect(self: @This()) w.RECT {
        var rect: w.RECT = undefined;
        _ = w.GetWindowRect(self.hwnd, &rect);
        return rect;
    }

    pub fn getClientRect(self: @This()) w.RECT {
        var rect: w.RECT = undefined;
        _ = w.GetClientRect(self.hwnd, &rect);
        return rect;
    }    

    pub fn addChild(self: @This(), child: @This()) !void {
        try self.children.append(child);
        child.setParent(self);
    }

    pub fn setParent(self: @This(), parent: @This()) void {
        _ = w.SetParent(self.hwnd, parent.hwnd);
    }

    pub fn focus(self: @This()) void {
        _ = w.SetFocus(self.hwnd);
    }

    pub fn destroy(self: @This()) void {
        _ = w.DestroyWindow(self.hwnd);
    }
};

pub fn Window(comptime T: type) type {
    return struct {
        system_window: SystemWindow,
        event_handlers: WindowEventHandlers,
        widget: *T,
        pub const WindowParameters = struct {
            exStyle: w.DWORD = 0,
            className: [:0]u16 = toUtf16const("Vitrail"),
            title: [:0]u16 = toUtf16const("Window"),
            style: w.DWORD = w.WS_OVERLAPPEDWINDOW,
            x: c_int = 100,
            y: c_int = 100,
            width: c_int = 640,
            height: c_int = 480,
            parent: ?SystemWindow = null,
            menu: w.HMENU = null,
            register_class: bool = true
        };

        pub const WindowEventHandlers = struct {
            onClick: fn (widget: *T) anyerror!void = defaultHandler,
            onResize: fn (widget: *T) anyerror!void = onResizeHandler,
            onCreate: fn(widget: *T) anyerror!void = defaultHandler,
            onDestroy: fn (widget: *T) anyerror!void = defaultHandler,
            onPaint: fn (widget: *T) anyerror!void = onPaintHandler,
        };

        fn defaultHandler(widget: *T) !void {}

        fn onResizeHandler(widget: *T) !void {

        }

        fn onPaintHandler(widget: *T) !void {
            var ps: w.PAINTSTRUCT = undefined;
            var hdc = w.BeginPaint(widget.window.system_window.hwnd, &ps);
            defer _ = w.EndPaint(widget.window.system_window.hwnd, &ps);
            defer _ = w.ReleaseDC(widget.window.system_window.hwnd, hdc);
            var color = w.GetSysColor(w.COLOR_WINDOW);
            var hbrushBg = w.CreateSolidBrush(color);
            defer _ = w.DeleteObject(hbrushBg);
            _ = w.FillRect(hdc, &ps.rcPaint, hbrushBg);
        }

        fn WindowProc(hwnd: w.HWND, uMsg: w.UINT, wParam: w.WPARAM, lParam: w.LPARAM) callconv(.C) w.LRESULT {
            var wLong = w.GetWindowLongPtr(hwnd, w.GWLP_USERDATA);
            if(wLong == 0) {
                return w.DefWindowProcW(hwnd, uMsg, wParam, lParam);
            }

            var window = @intToPtr(*Window(T), @bitCast(usize, wLong));

            return window.wndProc(uMsg, wParam, lParam) catch return 1;
        }

        pub fn wndProc(self: Window(T), uMsg: w.UINT, wParam: w.WPARAM, lParam: w.LPARAM) !w.LRESULT {
            switch(uMsg) {
                w.WM_SIZE => {
                    try self.event_handlers.onResize(self.widget);
                    return 0;
                },
                w.WM_LBUTTONDOWN => {
                    try self.event_handlers.onClick(self.widget);
                    return 0;
                },
                w.WM_CREATE => {
                    try self.event_handlers.onCreate(self.widget);
                    return 0;
                },
                w.WM_DESTROY => {
                    try self.event_handlers.onDestroy(self.widget);
                    return 0;
                },
                w.WM_PAINT => {
                    try self.event_handlers.onPaint(self.widget);
                    return 0;
                },
                else => {
                    return w.DefWindowProcW(self.system_window.hwnd, uMsg, wParam, lParam);
                }
            }
        }

        pub fn create(window_parameters: WindowParameters, event_handlers: WindowEventHandlers, hInstance: w.HINSTANCE, allocator: *std.mem.Allocator) !*T {
            if(window_parameters.register_class) {
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

                _ = w.RegisterClassW(&wc);
            }

            var parent: w.HWND = if (window_parameters.parent) |p| p.hwnd else null;
            var hwnd = w.CreateWindowExW(window_parameters.exStyle, window_parameters.className, window_parameters.title, window_parameters.style, window_parameters.x, window_parameters.y, window_parameters.width, window_parameters.height, parent, window_parameters.menu, hInstance, null);

            var children = try allocator.create(std.ArrayList(SystemWindow));
            children.* = std.ArrayList(SystemWindow).init(allocator);
            var system_window = SystemWindow {
                .hwnd = hwnd,
                .hInstance = hInstance,
                .children = children
            };

            var window = try allocator.create(Window(T));
            window.* = Window(T) {
                .system_window = system_window,
                .event_handlers = event_handlers,
                .widget = undefined
            };

            _ = w.SetWindowLongPtr(hwnd, w.GWLP_USERDATA, @bitCast(c_longlong, @ptrToInt(window)));
            var font = w.GetStockObject(w.DEFAULT_GUI_FONT);
            _ = w.SendMessage(hwnd, w.WM_SETFONT, @ptrToInt(font), 1);

            var widget = try allocator.create(T);
            widget.* = T {
                .window = window
            };
            window.widget = widget;

            return widget;
        }
    };
}
