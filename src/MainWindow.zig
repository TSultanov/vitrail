const std = @import("std");
const wh = @import("windows.zig");
const w = wh.c;
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
    activateWindow: *const fn (main_window: *Self, dw: sys.DesktopWindow) anyerror!void,
    hide: *const fn (main_window: *Self) anyerror!void,
};

window: *Window,
layout: *Layout,
search_box: *TextBox,
event_handlers: Window.EventHandlers,
desktop_windows: ?std.array_list.Managed(sys.DesktopWindow),
hInstance: w.HINSTANCE,
allocator: std.mem.Allocator,
callbacks: *Callbacks,
boxes: std.array_list.Managed(*Tile),
font: w.HGDIOBJ,
desktopHwndTileMap: DesktopHwndTile,
previous_hidden: bool = false,

tile_callbacks: Tile.Callbacks = .{
    .clicked = tileCallback,
},

fn onAfterDestroyHandler(event_handlers: *Window.EventHandlers, _: *Window) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);

    _ = w.DeleteObject(self.font);

    while (self.boxes.pop()) |box| {
        self.allocator.destroy(box);
    }

    self.boxes.deinit();
    self.allocator.destroy(self.window);
    self.allocator.destroy(self.layout);
    self.allocator.destroy(self.search_box);

    _ = w.PostQuitMessage(0);
}

fn onKeyDownHandler(event_handlers: *Window.EventHandlers, _: *Window, wParam: w.WPARAM, _: w.LPARAM) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    if (wParam == w.VK_ESCAPE) {
        try self.callbacks.hide(self);
    }
}

fn onCharHandler(event_handlers: *Window.EventHandlers, _: *Window, wParam: w.WPARAM, lParam: w.LPARAM) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    _ = w.SendMessageW(self.search_box.window.hwnd, w.WM_CHAR, wParam, lParam);
}

fn onResizeHandler(event_handlers: *Window.EventHandlers, window: *Window) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    if (window.docked) {
        try window.dock();
    }

    for (window.children.items) |child| {
        if (child.hwnd == self.search_box.window.hwnd) {
            const rect = try self.window.getRect();
            const xm = @divFloor(rect.right - rect.left, 2);
            const x = xm - @divFloor(child.scaleDpi(search_box_width), 2);

            const y = rect.bottom - child.scaleDpi(100);

            try child.setSize(x, y, child.scaleDpi(search_box_width), child.scaleDpi(search_box_height));
        } else {
            try child.resize();
        }
    }
}

fn onPaintHandler(_: *Window.EventHandlers, window: *Window) !void {
    var ps: w.PAINTSTRUCT = undefined;
    const hdc = w.BeginPaint(window.hwnd, &ps);
    defer _ = w.EndPaint(window.hwnd, &ps);
    defer _ = w.ReleaseDC(window.hwnd, hdc);
    const hbrushBg = w.CreateSolidBrush(0xff000000);
    defer wh.mapFailure(w.DeleteObject(hbrushBg)) catch std.debug.panic("Failed to call DeleteObject() on {*}\n", .{hbrushBg});
    try wh.mapFailure(w.FillRect(hdc, &ps.rcPaint, hbrushBg));
}

fn onCommandHandler(event_handlers: *Window.EventHandlers, _: *Window, wParam: w.WPARAM, lParam: w.LPARAM) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    const command = wParam >> 16;
    const controlHandle: w.HWND = @ptrFromInt(@as(usize, @intCast(lParam)));
    if (self.search_box.window.hwnd == controlHandle) {
        if (command == w.EN_CHANGE) {
            try self.updateVisibility();
        }
    }
}

pub fn onDpiChangeHandler(event_handlers: *Window.EventHandlers, window: *Window, _: w.WPARAM, _: w.LPARAM) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);

    const dpi = w.GetDpiForWindow(window.hwnd);
    window.setDpi(dpi);
    const desktop = w.GetDesktopWindow();
    var rect: w.RECT = undefined;
    try wh.mapFailure(w.GetWindowRect(desktop, &rect));
    try window.setSizeScaled(rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top);

    for (self.boxes.items) |box| {
        try box.resetFonts();
    }
}

pub fn onEnableHandler(event_handlers: *Window.EventHandlers, window: *Window, wParam: w.WPARAM, _: w.LPARAM) !void {
    if (wParam == 1) {
        const desktop = w.GetDesktopWindow();
        var desktopRect: w.RECT = undefined;
        try wh.mapFailure(w.GetWindowRect(desktop, &desktopRect));
        try window.setSize(desktopRect.left, desktopRect.top, desktopRect.right - desktopRect.left, desktopRect.bottom - desktopRect.top);

        const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
        try self.layout.layout(false);
    }
}

pub fn create(hInstance: w.HINSTANCE, callbacks: *Callbacks, allocator: std.mem.Allocator) !*Self {
    const desktop = w.GetDesktopWindow();
    var desktopRect: w.RECT = undefined;
    try wh.mapFailure(w.GetWindowRect(desktop, &desktopRect));

    const windowConfig = Window.WindowParameters{
        .exStyle = w.WS_EX_TOPMOST | w.WS_EX_TOOLWINDOW | w.WS_EX_LAYERED,
        .x = desktopRect.left,
        .y = desktopRect.top,
        .width = desktopRect.right,
        .height = desktopRect.bottom,
        .title = sys.toUtf16const("MainWindow"),
        .style = w.WS_POPUP,
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
            .onEnable = onEnableHandler,
        },
        .desktop_windows = null,
        .hInstance = hInstance,
        .allocator = allocator,
        .callbacks = callbacks,
        .boxes = std.array_list.Managed(*Tile).init(allocator),
        .font = undefined,
        .desktopHwndTileMap = DesktopHwndTile.init(allocator),
    };

    const window = try Window.create(windowConfig, &self.event_handlers, hInstance, allocator);
    self.window = window;
    _ = w.SetLayeredWindowAttributes(window.hwnd, 0x00ff00ff, 255, w.LWA_COLORKEY);

    self.layout = try Layout.create(hInstance, window, allocator);

    self.search_box = try TextBox.create(hInstance, window, allocator);
    _ = self.search_box.window.hide();

    try self.setFonts();

    try window.setSize(desktopRect.left, desktopRect.top, desktopRect.right - desktopRect.left, desktopRect.bottom - desktopRect.top);

    return self;
}

pub fn setDesktopWindows(self: *Self, desktopWindows: std.array_list.Managed(sys.DesktopWindow)) !void {
    try self.hideBoxes();
    self.desktop_windows = desktopWindows;
    try self.updateBoxes();
}

fn tileCallback(tile: *Tile) !void {
    const self: *Self = @fieldParentPtr("tile_callbacks", tile.callbacks);

    try self.callbacks.activateWindow(self, tile.desktopWindow);
}

pub fn hideBoxes(self: *Self) !void {
    try self.layout.clear();
    _ = self.search_box.window.hide();
    while (self.boxes.pop()) |box| {
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
    @memcpy(search_text_lower[0..search_text.len], search_text);
    _ = w.CharLowerBuffW(search_text_lower, @intCast(search_text_lower.len - 1));

    if (self.desktop_windows) |desktop_windows| {
        var reset_focus = self.previous_hidden;

        var hidden_num: usize = 0;

        for (desktop_windows.items) |dw| {
            if (self.desktopHwndTileMap.get(dw.hwnd)) |tile| {
                if (search_text.len <= 1) {
                    _ = tile.window.show();
                } else {
                    if (std.mem.containsAtLeast(u16, dw.title_lower[0..(dw.title.len - 1)], 1, search_text_lower[0..(search_text.len - 1)])) {
                        _ = tile.window.show();
                    } else {
                        if (tile.selected) {
                            reset_focus = true;
                        }
                        hidden_num += 1;
                        _ = tile.window.hide();
                    }
                }
            }
        }

        if (hidden_num == desktop_windows.items.len) {
            self.previous_hidden = true;
        } else {
            self.previous_hidden = false;
        }

        try self.layout.layout(reset_focus);
    }
}

fn updateBoxes(self: *Self) !void {
    if (self.desktop_windows) |desktop_windows| {
        if (desktop_windows.items.len > 0) {
            for (desktop_windows.items) |dw| {
                const box = try Tile.create(self.hInstance, self.layout.window, dw, &self.tile_callbacks, self.allocator);
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
}

fn setFonts(self: *Self) !void {
    self.font = w.GetStockObject(w.DEFAULT_GUI_FONT);
}
