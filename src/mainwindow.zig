const std = @import("std");
const w = @import("windows.zig");
const sys = @import("SystemInteraction.zig");
pub const Window = @import("Window.zig");
pub const Layout = @import("Layout.zig");
pub const Tile = @import("Tile.zig");
pub const TextBox = @import("TextBox.zig");

const Self = @This();

const DesktopHwndTile = std.AutoArrayHashMap(w.HWND, *Tile);

const search_box_width = 100;
const search_box_height = 20;

pub const Callbacks = struct {
    activateWindow: fn(main_window: *Self, dw: sys.DesktopWindow) anyerror!void,
    hide: fn(main_window: *Self) anyerror!void
};

window: *Window,
layout: *Layout,
search_box: *TextBox,
event_handlers: Window.EventHandlers,
desktop_windows: ?std.ArrayList(sys.DesktopWindow),
hInstance: w.HINSTANCE,
allocator: std.mem.Allocator,
callbacks: *Callbacks,
boxes: std.ArrayList(*Tile),
font: w.HGDIOBJ,
desktopHwndTileMap: DesktopHwndTile,
previous_hidden: bool = false,

tile_callbacks: Tile.Callbacks = .{
    .clicked = tileCallback
},

fn onAfterDestroyHandler(event_handlers: *Window.EventHandlers, _: *Window) !void {
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

fn onKeyDownHandler(event_handlers: *Window.EventHandlers, _: *Window, wParam: w.WPARAM, _: w.LPARAM) !void {
    var self = @fieldParentPtr(Self, "event_handlers", event_handlers);
    if(wParam == w.VK_ESCAPE)
    {
        try self.callbacks.hide(self);
    }
    else
    {
        //_ = w.SendMessageW(self.search_box.window.hwnd, w.WM_KEYDOWN, wParam, lParam);
    }
}

fn onCharHandler(event_handlers: *Window.EventHandlers, _: *Window, wParam: w.WPARAM, lParam: w.LPARAM) !void {
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

fn onPaintHandler(_: *Window.EventHandlers, window: *Window) !void {
    var ps: w.PAINTSTRUCT = undefined;
    var hdc = w.BeginPaint(window.hwnd, &ps);
    defer _ = w.EndPaint(window.hwnd, &ps);
    defer _ = w.ReleaseDC(window.hwnd, hdc);
    var hbrushBg = w.CreateSolidBrush(0xff000000);
    defer w.mapFailure(w.DeleteObject(hbrushBg)) catch std.debug.panic("Failed to call DeleteObject() on {*}\n", .{hbrushBg});
    try w.mapFailure(w.FillRect(hdc, &ps.rcPaint, hbrushBg));
}

fn onCommandHandler(event_handlers: *Window.EventHandlers, _: *Window, wParam: w.WPARAM, lParam: w.LPARAM) !void {
    var self = @fieldParentPtr(Self, "event_handlers", event_handlers);
    const command = wParam >> 16;
    const controlHandle: w.HWND = @intToPtr(w.HWND, @intCast(usize, lParam));
    if(self.search_box.window.hwnd == controlHandle)
    {
        if(command == w.EN_CHANGE)
        {
            try self.updateVisibility();
        }
    }
}

pub fn onDpiChangeHandler(event_handlers: *Window.EventHandlers, window: *Window, _: w.WPARAM, _: w.LPARAM) !void {
    var self = @fieldParentPtr(Self, "event_handlers", event_handlers);
    
    const dpi = w.GetDpiForWindow(window.hwnd);
    window.setDpi(dpi);
    const desktop = w.GetDesktopWindow();
    var rect: w.RECT = undefined;
    try w.mapFailure(w.GetWindowRect(desktop, &rect));
    try window.setSizeScaled(rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top);

    for(self.boxes.items) |box| {
        try box.resetFonts();
    }
}

pub fn onEnableHandler(event_handlers: *Window.EventHandlers, window: *Window, wParam: w.WPARAM, _: w.LPARAM) !void {
    if(wParam == 1) {
        const desktop = w.GetDesktopWindow();
        var desktopRect: w.RECT = undefined;
        try w.mapFailure(w.GetWindowRect(desktop, &desktopRect));
        try window.setSize(desktopRect.left, desktopRect.top, desktopRect.right - desktopRect.left, desktopRect.bottom - desktopRect.top);

        var self = @fieldParentPtr(Self, "event_handlers", event_handlers);
        try self.layout.layout(false);
    }
}

pub fn create(hInstance: w.HINSTANCE, callbacks: *Callbacks, allocator: std.mem.Allocator) !*Self {
    const desktop = w.GetDesktopWindow();
    var desktopRect: w.RECT = undefined;
    try w.mapFailure(w.GetWindowRect(desktop, &desktopRect));

    const windowConfig = Window.WindowParameters {
        .exStyle = w.WS_EX_TOPMOST | w.WS_EX_TOOLWINDOW,
        .x = desktopRect.left,
        .y = desktopRect.top,
        .width = desktopRect.right,
        .height = desktopRect.bottom,
        .title = sys.toUtf16const("MainWindow"),
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
            .onCommand = onCommandHandler,
            .onDpiChange = onDpiChangeHandler,
            .onEnable = onEnableHandler
        },
        .desktop_windows = null,
        .hInstance = hInstance,
        .allocator = allocator,
        .callbacks = callbacks,
        .boxes = std.ArrayList(*Tile).init(allocator),
        .font = undefined,
        .desktopHwndTileMap = DesktopHwndTile.init(allocator),
    };

    var window = try Window.create(windowConfig, &self.event_handlers, hInstance, allocator);
    self.window = window;
    _ = w.SetWindowLongW(window.hwnd, w.GWL_STYLE, 0);
    _ = w.SetWindowLongW(window.hwnd, 
              w.GWL_EXSTYLE, 
              w.GetWindowLongW(window.hwnd, w.GWL_EXSTYLE) | w.WS_EX_LAYERED);
    _ = w.SetLayeredWindowAttributes(window.hwnd, 0x00ff00ff, 255, w.LWA_COLORKEY);
    // const margins = w.MARGINS {
    //     .cxLeftWidth = -1,
    //     .cxRightWidth = -1,
    //     .cyTopHeight = -1,
    //     .cyBottomHeight = -1
    // };
    //_ = w.DwmExtendFrameIntoClientArea(window.hwnd, &margins);

    self.layout = try Layout.create(hInstance, window, allocator);

    self.search_box = try TextBox.create(hInstance, window, allocator);
    _ = self.search_box.window.hide();

    try self.setFonts();

    return self;
}

pub fn setDesktopWindows(self: *Self, desktopWindows: std.ArrayList(sys.DesktopWindow)) !void {
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
    self.desktopHwndTileMap.clearAndFree();
}

fn updateVisibility(self: *Self) !void {
    const search_text = try self.search_box.window.getText(self.allocator);
    defer self.allocator.free(search_text);

    const search_text_lower = try self.allocator.allocSentinel(u16, search_text.len, 0);
    defer self.allocator.free(search_text_lower);
    std.mem.copy(u16, search_text_lower, search_text);
    _ = w.CharLowerBuffW(search_text_lower, @intCast(c_ulong, search_text_lower.len-1));

    if(self.desktop_windows) |desktop_windows| {
        var reset_focus = self.previous_hidden;

        var hidden_num: usize = 0;

        for(desktop_windows.items) |dw| {
            if(self.desktopHwndTileMap.get(dw.hwnd)) |tile|
            {
                if(search_text.len <= 1)
                {
                    _ = tile.window.show();
                }
                else
                {
                    if(std.mem.containsAtLeast(u16, dw.title_lower[0..(dw.title.len-1)], 1, search_text_lower[0..(search_text.len-1)]) )
                    {
                        _ = tile.window.show();
                    }
                    else
                    {
                        if(tile.selected)
                        {
                            reset_focus = true;
                        }
                        hidden_num += 1;
                        _ = tile.window.hide();
                    }
                }
            }
        }

        if(hidden_num == desktop_windows.items.len)
        {
            self.previous_hidden = true;
        }
        else
        {
            self.previous_hidden = false;
        }

        try self.layout.layout(reset_focus);
    }
}

fn updateBoxes(self: *Self) !void {
    if(self.desktop_windows) |desktop_windows| {
        if(desktop_windows.items.len > 0)
        {
            for (desktop_windows.items) |dw| {
                var box = try Tile.create(self.hInstance, self.layout.window, dw, &self.tile_callbacks, self.allocator);
                try self.boxes.append(box);
                try self.desktopHwndTileMap.put(dw.hwnd, box);
            }
            try self.search_box.clearText();
            self.previous_hidden = false;
            try self.layout.layout(true);
            _ = self.search_box.window.show();
            try self.search_box.window.bringToTop();
        }
    }

    //try self.updateVisibilityMask();
}

// fn updateVisibilityMask(self: Self) !void {
//     const rgn = try self.layout.window.getChildRgn();
//     _ = w.SetWindowRgn(self.window.hwnd, rgn, 1);
// }

fn setFonts(self: *Self) !void {
    self.font = w.GetStockObject(w.DEFAULT_GUI_FONT);
}
