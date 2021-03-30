usingnamespace @import("vitrail.zig");
pub const Window = @import("Window.zig");
pub const Layout = @import("Layout.zig");
pub const Tile = @import("Tile.zig");
pub const TextBox = @import("TextBox.zig");
pub const DesktopWindow = @import("SystemInteraction.zig").DesktopWindow;

const Self = @This();

const search_box_width = 100;
const search_box_height = 20;

pub const Callbacks = struct {
    activateWindow: fn(main_window: *Self, dw: DesktopWindow) anyerror!void,
    hide: fn(main_window: *Self) anyerror!void
};

window: *Window,
layout: *Layout,
search_box: *TextBox,
event_handlers: Window.EventHandlers,
desktop_windows: ?std.ArrayList(DesktopWindow),
hInstance: w.HINSTANCE,
allocator: *std.mem.Allocator,
callbacks: *Callbacks,
boxes: std.ArrayList(*Tile),
font: w.HGDIOBJ,

tile_callbacks: Tile.Callbacks = .{
    .clicked = tileCallback
},

fn onAfterDestroyHandler(event_handlers: *Window.EventHandlers, window: *Window) !void {
    var self = @fieldParentPtr(Self, "event_handlers", event_handlers);

    _ = w.DeleteObject(self.font);

    while (self.boxes.popOrNull()) |box| {
        self.allocator.destroy(box);
    }

    self.boxes.deinit();
    self.allocator.destroy(self.window);
    self.allocator.destroy(self.layout);
    self.allocator.destroy(self.search_box);

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
    else
    {
        _ = w.SendMessageW(self.search_box.window.hwnd, w.WM_KEYDOWN, wParam, lParam);
    }
}

fn onCharHandler(event_handlers: *Window.EventHandlers, window: *Window, wParam: w.WPARAM, lParam: w.LPARAM) !void {
    var self = @fieldParentPtr(Self, "event_handlers", event_handlers);
    _ = w.SendMessageW(self.search_box.window.hwnd, w.WM_CHAR, wParam, lParam);
}

fn onResizeHandler(event_handlers: *Window.EventHandlers, window: *Window) !void {
    var self = @fieldParentPtr(Self, "event_handlers", event_handlers);
    if(window.docked)
    {
        try window.dock();
    }

    for (window.children.items) |child| {
        if(child.hwnd == self.search_box.window.hwnd)
        {
            var rect = try self.window.getRect();
            const xm = @divFloor(rect.right - rect.left, 2);
            const x = xm - @divFloor(child.scaleDpi(search_box_width), 2);
            
            const y = rect.bottom - child.scaleDpi(200);

            try child.setSize(x, y, child.scaleDpi(search_box_width), child.scaleDpi(search_box_height));
        }
        else
        {
            try child.resize();
        }
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
        //.x = desktopRect.left,
        //.y = desktopRect.top,
        //.width = desktopRect.right,
        //.height = desktopRect.bottom,
        .title = toUtf16const("MainWindow"),
        .style = w.WS_OVERLAPPEDWINDOW
    };

    var self = try allocator.create(Self);
    self.* = .{
        .window = undefined,
        .layout = undefined,
        .search_box = undefined,
        .event_handlers = .{
            .onAfterDestroy = onAfterDestroyHandler,
            .onKeyDown = onKeyDownHandler,
            .onPaint = onPaintHandler,
            .onResize = onResizeHandler,
            .onChar = onCharHandler,
        },
        .desktop_windows = null,
        .hInstance = hInstance,
        .allocator = allocator,
        .callbacks = callbacks,
        .boxes = std.ArrayList(*Tile).init(allocator),
        .font = undefined
    };

    var window = try Window.create(windowConfig, &self.event_handlers, hInstance, allocator);
    self.window = window;
    //_ = w.SetWindowLong(window.hwnd, w.GWL_STYLE, 0);
    // _ = w.SetWindowLong(window.hwnd, 
    //           w.GWL_EXSTYLE, 
    //           w.GetWindowLong(window.hwnd, w.GWL_EXSTYLE) | w.WS_EX_LAYERED);
    //_ = w.SetLayeredWindowAttributes(window.hwnd, 0x00ff00ff, 255, w.LWA_COLORKEY);
    const margins = w.MARGINS {
        .cxLeftWidth = -1,
        .cxRightWidth = -1,
        .cyTopHeight = -1,
        .cyBottomHeight = -1
    };
    //_ = w.DwmExtendFrameIntoClientArea(window.hwnd, &margins);

    self.layout = try Layout.create(hInstance, window, allocator);

    self.search_box = try TextBox.create(hInstance, window, allocator);

    try self.setFonts();

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
    _ = self.search_box.window.hide();
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
    _ = self.search_box.window.show();
    try self.search_box.window.bringToTop();

    //try self.updateVisibilityMask();
}

fn updateVisibilityMask(self: Self) !void {
    const rgn = try self.layout.window.getChildRgn();
    //_ = w.SetWindowRgn(self.window.hwnd, rgn, 1);
}

fn setFonts(self: *Self) !void {
    self.font = w.GetStockObject(w.DEFAULT_GUI_FONT);
}
