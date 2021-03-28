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
desktop_windows: ?std.ArrayList(DesktopWindow),
hInstance: w.HINSTANCE,
allocator: *std.mem.Allocator,
callbacks: *Callbacks,
boxes: std.ArrayList(*Tile),

tile_callbacks: Tile.Callbacks = .{
    .clicked = tileCallback
},

fn onAfterDestroyHandler(event_handlers: *Window.EventHandlers, window: *Window) !void {
    var self = @fieldParentPtr(Self, "event_handlers", event_handlers);

    while (self.boxes.popOrNull()) |box| {
        self.allocator.destroy(box);
    }

    self.boxes.deinit();
    self.allocator.destroy(self.window);
    self.allocator.destroy(self.layout);

    // if(self.desktop_windows) |desktop_windows| {
    //     for (desktop_windows.items) |dw| {
    //         try dw.destroy();
    //     }
    //     desktop_windows.deinit();
    // }

    _ = w.PostQuitMessage(0);
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
    var hbrushBg = w.CreateSolidBrush(0xff000000);
    defer w.mapFailure(w.DeleteObject(hbrushBg)) catch std.debug.panic("Failed to call DeleteObject() on {*}\n", .{hbrushBg});
    try w.mapFailure(w.FillRect(hdc, &ps.rcPaint, hbrushBg));
}

pub fn create(hInstance: w.HINSTANCE, callbacks: *Callbacks, allocator: *std.mem.Allocator) !*Self {
    const desktop = w.GetDesktopWindow();
    var desktopRect: w.RECT = undefined;
    try w.mapFailure(w.GetWindowRect(desktop, &desktopRect));

    const windowConfig = Window.WindowParameters {
        .exStyle = w.WS_EX_TOPMOST | w.WS_EX_TOOLWINDOW,
        .x = desktopRect.left,
        .y = desktopRect.top,
        .width = desktopRect.right,
        .height = desktopRect.bottom,
        .title = toUtf16const("MainWindow"),
        .style = w.WS_OVERLAPPEDWINDOW
    };

    var self = try allocator.create(Self);
    self.* = .{
        .window = undefined,
        .layout = undefined,
        .event_handlers = .{
            .onAfterDestroy = onAfterDestroyHandler,
            .onKeyDown = onKeyDownHandler,
            .onPaint = onPaintHandler
        },
        .desktop_windows = null,
        .hInstance = hInstance,
        .allocator = allocator,
        .callbacks = callbacks,
        .boxes = std.ArrayList(*Tile).init(allocator)
    };

    var window = try Window.create(windowConfig, &self.event_handlers, hInstance, allocator);
    self.window = window;
    _ = w.SetWindowLong(window.hwnd, w.GWL_STYLE, 0);
    _ = w.SetWindowLong(window.hwnd, 
              w.GWL_EXSTYLE, 
              w.GetWindowLong(window.hwnd, w.GWL_EXSTYLE) | w.WS_EX_LAYERED);
    _ = w.SetLayeredWindowAttributes(window.hwnd, 0x00ff00ff, 255, w.LWA_COLORKEY);
    const margins = w.MARGINS {
        .cxLeftWidth = -1,
        .cxRightWidth = -1,
        .cyTopHeight = -1,
        .cyBottomHeight = -1
    };
    //_ = w.DwmExtendFrameIntoClientArea(window.hwnd, &margins);

    self.layout = try Layout.create(hInstance, window, allocator);

    return self;
}

pub fn setDesktopWindows(self: *Self, desktopWindows: std.ArrayList(DesktopWindow)) !void {
    try self.hideBoxes();
    self.desktop_windows = desktopWindows;
    try self.updateBoxes();
}

fn tileCallback(tile: *Tile) !void {
    const self = @fieldParentPtr(Self, "tile_callbacks", tile.callbacks);

    try self.callbacks.activateWindow(self, tile.desktopWindow);
}

pub fn hideBoxes(self: *Self) !void {
    try self.layout.clear();
    while (self.boxes.popOrNull()) |box| {
        self.allocator.destroy(box);
    }
    self.desktop_windows = null;
}

fn updateBoxes(self: *Self) !void {
    if(self.desktop_windows) |desktop_windows| {
        for (desktop_windows.items) |dw| {
            var box = try Tile.create(self.hInstance, self.layout.window, dw, &self.tile_callbacks, self.allocator);
            try self.boxes.append(box);
        }

        try self.layout.layout();
    }

    //try self.updateVisibilityMask();
}

fn updateVisibilityMask(self: Self) !void {
    const rgn = try self.layout.window.getChildRgn();
    //_ = w.SetWindowRgn(self.window.hwnd, rgn, 1);
}