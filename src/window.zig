const std = @import("std");
const w = @import("win32").c;
const toUtf16const = @import("system_interaction.zig").toUtf16const;

pub const WindowParameters = struct {
    exStyle: w.DWORD = 0,
    className: w.LPCWSTR = toUtf16const("Vitrail"),
    title: w.LPCWSTR = toUtf16const("Window"),
    style: w.DWORD = w.WS_OVERLAPPEDWINDOW,
    x: c_int = 100,
    y: c_int = 100,
    width: c_int = 640,
    height: c_int = 480,
    //parent: ?Window = null,
    menu: w.HMENU = null,
};

pub fn Window(comptime T: type) type {
    return struct {
        hwnd: w.HWND,
        hInstance: w.HINSTANCE,
        dock: bool = false,
        eventHandlers: WindowEventHandlers,
        children: *std.ArrayList(*Window(T)),
        widget: *T,

        fn WindowProc(hwnd: w.HWND, uMsg: w.UINT, wParam: w.WPARAM, lParam: w.LPARAM) callconv(.C) w.LRESULT {
            var wLong = w.GetWindowLongPtr(hwnd, w.GWLP_USERDATA);
            if(wLong == 0) {
                return w.DefWindowProcW(hwnd, uMsg, wParam, lParam);
            }

            var window = @intToPtr(*Window(T), @bitCast(usize, wLong));

            return window.wndProc(uMsg, wParam, lParam) catch return 1;
        }
        //pub const WndProc = fn (self: Window(T), uMsg: w.UINT, wParam: w.WPARAM, lParam: w.LPARAM) w.LRESULT;
        pub const WindowEventHandlers = struct {
            onClick: fn (widget: *T) anyerror!void = defaultHandler,
            onResize: fn (widget: *T) anyerror!void = onResizeHandler,
            onCreate: fn(widget: *T) anyerror!void = defaultHandler,
            onDestroy: fn (widget: *T) anyerror!void = defaultHandler,
            onPaint: fn (widget: *T) anyerror!void = defaultHandler,
        };

        fn defaultHandler(widget: *T) !void {}

        fn onResizeHandler(widget: *T) !void {
            for(widget.window.children.items) |wnd| {
                widget.window.dockChild(wnd);
            }
        }
        pub fn wndProc(self: Window(T), uMsg: w.UINT, wParam: w.WPARAM, lParam: w.LPARAM) !w.LRESULT {
            switch(uMsg) {
                w.WM_SIZE => {
                    try self.eventHandlers.onResize(self.widget);
                    return 0;
                },
                w.WM_LBUTTONDOWN => {
                    try self.eventHandlers.onClick(self.widget);
                    return 0;
                },
                w.WM_CREATE => {
                    try self.eventHandlers.onCreate(self.widget);
                    return 0;
                },
                w.WM_DESTROY => {
                    try self.eventHandlers.onDestroy(self.widget);
                    return 0;
                },
                w.WM_PAINT => {
                    try self.eventHandlers.onPaint(self.widget);
                    return 0;
                },
                else => {
                    return w.DefWindowProcW(self.hwnd, uMsg, wParam, lParam);
                }
            }
        }

        pub fn create(windowParameters: WindowParameters, eventHandlers: WindowEventHandlers, hInstance: w.HINSTANCE, allocator: *std.mem.Allocator, widget: *T) !*Window(T) {
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

            var parent: w.HWND = null;//if(windowParameters.parent) |p| p.hwnd else null;
            var hwnd = w.CreateWindowExW(windowParameters.exStyle, windowParameters.className, windowParameters.title, windowParameters.style, windowParameters.x, windowParameters.y, windowParameters.width, windowParameters.height, parent, windowParameters.menu, hInstance, null);

            var children = try allocator.create(std.ArrayList(*Window(T)));
            children.* = std.ArrayList(*Window(T)).init(allocator);
            var window = try allocator.create(Window(T));
            window.* = Window(T) {
                .hwnd = hwnd,
                .hInstance = hInstance,
                .children = children,
                .eventHandlers = eventHandlers,
                .widget = widget
            };

            _ = w.SetWindowLongPtr(hwnd, w.GWLP_USERDATA, @bitCast(c_longlong, @ptrToInt(window)));

            return window;
        }

        pub fn show(self: Window(T)) void {
            _ = w.ShowWindow(self.hwnd, w.SW_SHOW);
        }

        pub fn hide(self: Window(T)) void {
            _ = w.ShowWindow(self.hwnd, w.SW_HIDE);
        }

        pub fn update(self: Window(T)) void {
            _ = w.UpdateWindow(self.hwnd);
        }

        pub fn getRgn(self: Window(T)) w.HRGN {
            var rgn: w.HRGN = undefined;
            _ = w.GetWindowRgn(self.hwnd, rgn);
            return rgn;
        }

        pub fn redraw(self: Window(T)) void {
            _ = w.RedrawWindow(self.hwnd, null, null, w.RDW_INVALIDATE | w.RDW_UPDATENOW);
        }

        pub fn setSize(self: Window(T), x: c_int, y: c_int, cx: c_int, cy: c_int) void {
            _ = w.SetWindowPos(self.hwnd, 0, x, y, cx, cy, w.SWP_NOZORDER);
        }

        pub fn getRect(self: Window(T)) w.RECT {
            var rect: w.RECT = undefined;
            _ = w.GetWindowRect(self.hwnd, &rect);
            return rect;
        }

        pub fn getClientRect(self: Window(T)) w.RECT {
            var rect: w.RECT = undefined;
            _ = w.GetClientRect(self.hwnd, &rect);
            return rect;
        }

        pub fn dockChild(self: Window(T), child: *Window(T)) void {
            var rect = self.getRect();
            child.*.setSize(0, 0, rect.right - rect.left, rect.bottom - rect.top);
        }

        pub fn addChild(self: Window(T), child: *Window(T)) !void {
            try self.children.append(child);
        }

        pub fn setParent(self: Window(T), parent: Window(T)) void {
            _ = w.SetParent(self.hwnd, parent.hwnd);
        }

        pub fn focus(self: Window(T)) void {
            _ = w.SetFocus(self.hwnd);
        }

        pub fn destroy(self: Window(T)) void {
            _ = w.DestroyWindow(self.hwnd);
        }
    };
}
