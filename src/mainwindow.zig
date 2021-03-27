usingnamespace @import("vitrail.zig");
pub const Window = @import("Window.zig");
pub const Layout = @import("Layout.zig");
pub const Tile = @import("Tile.zig");
pub const DesktopWindow = @import("SystemInteraction.zig").DesktopWindow;

const Self = @This();

pub const Callbacks = struct {
    activateWindow: fn(main_window: *Self, dw: DesktopWindow) anyerror!void,
    hide: fn(main_window: *Self) anyerror!void
};

window: *Window,
layout: *Layout,
event_handlers: Window.EventHandlers,
desktop_windows: []DesktopWindow,
hInstance: w.HINSTANCE,
allocator: *std.mem.Allocator,
callbacks: *Callbacks,

tile_callbacks: Tile.Callbacks = .{
    .clicked = tileCallback
},

fn onDestroyHandler(event_handlers: *Window.EventHandlers, window: *Window) !void {
    //_ = w.PostQuitMessage(0);
}

fn onKeyDownHandler(event_handlers: *Window.EventHandlers, window: *Window, wParam: w.WPARAM, lParam: w.LPARAM) !void {
    var self = @fieldParentPtr(Self, "event_handlers", event_handlers);
    if(wParam == w.VK_ESCAPE)
    {
        try self.callbacks.hide(self);
    }
}

fn onPaintHandler(event_handlers: *Window.EventHandlers, window: *Window) !void {
    var ps: w.PAINTSTRUCT = undefined;
    var hdc = w.BeginPaint(window.hwnd, &ps);
    defer _ = w.EndPaint(window.hwnd, &ps);
    defer _ = w.ReleaseDC(window.hwnd, hdc);
    var hbrushBg = w.CreateSolidBrush(0xaa000000);
    defer w.mapFailure(w.DeleteObject(hbrushBg)) catch std.debug.panic("Failed to call DeleteObject() on {*}\n", .{hbrushBg});
    try w.mapFailure(w.FillRect(hdc, &ps.rcPaint, hbrushBg));
}

pub fn create(hInstance: w.HINSTANCE, callbacks: *Callbacks, allocator: *std.mem.Allocator) !*Self {
    const desktop = w.GetDesktopWindow();
    var desktopRect: w.RECT = undefined;
    try w.mapFailure(w.GetWindowRect(desktop, &desktopRect));

    const windowConfig = Window.WindowParameters {
        .exStyle = w.WS_EX_LAYERED | w.WS_EX_TOPMOST | w.WS_EX_TOOLWINDOW,
        .x = desktopRect.left,
        .y = desktopRect.top,
        .width = desktopRect.right,
        .height = desktopRect.bottom,
        .title = toUtf16const("MainWindow"),
        .style = w.WS_BORDER
    };

    var self = try allocator.create(Self);
    self.* = .{
        .window = undefined,
        .layout = undefined,
        .event_handlers = .{
            .onDestroy = onDestroyHandler,
            .onKeyDown = onKeyDownHandler,
            .onPaint = onPaintHandler
        },
        .desktop_windows = undefined,
        .hInstance = hInstance,
        .allocator = allocator,
        .callbacks = callbacks
    };

    var window = try Window.create(windowConfig, &self.event_handlers, hInstance, allocator);
    self.window = window;
    _ = w.SetWindowLong(window.hwnd, w.GWL_STYLE, 0);
    _ = w.SetLayeredWindowAttributes(window.hwnd, 0, 255, w.LWA_ALPHA);
    const margins = w.MARGINS {
        .cxLeftWidth = -1,
        .cxRightWidth = -1,
        .cyTopHeight = -1,
        .cyBottomHeight = -1
    };
    _ = w.DwmExtendFrameIntoClientArea(window.hwnd, &margins);

    self.layout = try Layout.create(hInstance, window, allocator);

    return self;
}

pub fn setDesktopWindows(self: *Self, desktopWindows: []DesktopWindow) !void {
    self.desktop_windows = desktopWindows;
    try self.updateBoxes();
}

fn tileCallback(tile: *Tile) !void {
    const self = @fieldParentPtr(Self, "tile_callbacks", tile.callbacks);

    try self.callbacks.activateWindow(self, tile.desktopWindow);
}

fn updateBoxes(self: *Self) !void {
    try self.layout.clear();

    for (self.desktop_windows) |dw| {
        var button = Tile.create(self.hInstance, self.layout.window, dw, &self.tile_callbacks, self.allocator);
    }

    try self.updateVisibilityMask();
}

fn updateVisibilityMask(self: Self) !void {
    const rgn = try self.layout.window.getChildRgn();
    defer _ = w.DeleteObject(rgn);
    _ = w.SetWindowRgn(self.window.hwnd, rgn, 1);
}