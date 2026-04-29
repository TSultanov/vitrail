const std = @import("std");
const wh = @import("windows.zig");
const w = wh.c;
const sys = @import("SystemInteraction.zig");
const common = @import("../../common/DesktopWindow.zig");
pub const Window = @import("Window.zig");
pub const Layout = @import("Layout.zig");
pub const Tile = @import("Tile.zig");
pub const TextBox = @import("TextBox.zig");

const Self = @This();

const search_box_width = 100;
const search_box_height = 20;

pub const PlatformArgs = struct {
    hInstance: w.HINSTANCE,
};

pub const Callbacks = struct {
    activateWindow: *const fn (main_window: *Self, dw: common.DesktopWindow) anyerror!void,
    hide: *const fn (main_window: *Self) anyerror!void,
};

window: *Window,
layout: *Layout,
search_box: *TextBox,
event_handlers: Window.EventHandlers,
desktop_windows: ?std.array_list.Managed(common.DesktopWindow),
hInstance: w.HINSTANCE,
allocator: std.mem.Allocator,
callbacks: *Callbacks,
font: w.HGDIOBJ,
previous_hidden: bool = false,

tile_callbacks: Tile.Callbacks = .{
    .clicked = tileCallback,
},

fn onAfterDestroyHandler(event_handlers: *Window.EventHandlers, _: *Window) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);

    _ = w.DeleteObject(self.font);

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

fn onActivateHandler(event_handlers: *Window.EventHandlers, _: *Window, wParam: w.WPARAM, _: w.LPARAM) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    const state = wParam & 0xFFFF;
    if (state == w.WA_INACTIVE and self.desktop_windows != null) {
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

    try self.updateRegion();
}

fn updateRegion(self: *Self) !void {
    var window_rect: w.RECT = undefined;
    try wh.mapFailure(w.GetWindowRect(self.window.hwnd, &window_rect));

    var layout_rect: w.RECT = undefined;
    try wh.mapFailure(w.GetWindowRect(self.layout.window.hwnd, &layout_rect));

    const layout_offset_x = layout_rect.left - window_rect.left;
    const layout_offset_y = layout_rect.top - window_rect.top;

    const rgn = w.CreateRectRgn(0, 0, 0, 0);

    for (self.layout.tiles.items) |tile| {
        if (!tile.visible) continue;
        const tile_rgn = w.CreateRectRgn(
            tile.bounds.left + layout_offset_x,
            tile.bounds.top + layout_offset_y,
            tile.bounds.right + layout_offset_x,
            tile.bounds.bottom + layout_offset_y,
        );
        defer _ = w.DeleteObject(tile_rgn);
        _ = w.CombineRgn(rgn, rgn, tile_rgn, w.RGN_OR);
    }

    if (self.search_box.window.isVisible()) {
        var rect: w.RECT = undefined;
        try wh.mapFailure(w.GetWindowRect(self.search_box.window.hwnd, &rect));
        const sb_rgn = w.CreateRectRgn(
            rect.left - window_rect.left,
            rect.top - window_rect.top,
            rect.right - window_rect.left,
            rect.bottom - window_rect.top,
        );
        defer _ = w.DeleteObject(sb_rgn);
        _ = w.CombineRgn(rgn, rgn, sb_rgn, w.RGN_OR);
    }

    _ = w.SetWindowRgn(self.window.hwnd, rgn, 1);
}

fn onPaintHandler(_: *Window.EventHandlers, window: *Window) !void {
    var ps: w.PAINTSTRUCT = undefined;
    _ = w.BeginPaint(window.hwnd, &ps);
    _ = w.EndPaint(window.hwnd, &ps);
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

    for (self.layout.tiles.items) |tile| {
        try tile.resetFonts(self.layout.window.dpi);
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

pub fn create(args: PlatformArgs, callbacks: *Callbacks, allocator: std.mem.Allocator) !*Self {
    const hInstance = args.hInstance;
    const desktop = w.GetDesktopWindow();
    var desktopRect: w.RECT = undefined;
    try wh.mapFailure(w.GetWindowRect(desktop, &desktopRect));

    const windowConfig = Window.WindowParameters{
        .exStyle = w.WS_EX_TOPMOST | w.WS_EX_TOOLWINDOW,
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
            .onActivate = onActivateHandler,
        },
        .desktop_windows = null,
        .hInstance = hInstance,
        .allocator = allocator,
        .callbacks = callbacks,
        .font = undefined,
    };

    const window = try Window.create(windowConfig, &self.event_handlers, hInstance, allocator);
    self.window = window;

    self.layout = try Layout.create(hInstance, window, allocator);

    self.search_box = try TextBox.create(hInstance, window, allocator);
    _ = self.search_box.window.hide();

    try self.setFonts();

    try window.setSize(desktopRect.left, desktopRect.top, desktopRect.right - desktopRect.left, desktopRect.bottom - desktopRect.top);

    return self;
}

pub fn show(self: *Self) !void {
    _ = self.window.show();
}

/// On Windows, teardown is driven by WM_DESTROY (`onAfterDestroyHandler`),
/// not an explicit deinit; this exists so MainPresenter.deinit can call
/// `view.deinit()` symmetrically across platforms.
pub fn deinit(_: *Self) void {}

pub fn activate(self: *Self) void {
    self.window.activate();
    _ = w.SetForegroundWindow(self.window.hwnd);
}

pub fn requestQuit(_: *Self) void {
    w.PostQuitMessage(0);
}

pub fn setDesktopWindows(self: *Self, desktopWindows: std.array_list.Managed(common.DesktopWindow)) !void {
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
    self.desktop_windows = null;
    try self.updateRegion();
}

fn updateVisibility(self: *Self) !void {
    const search_utf16 = try self.search_box.window.getText(self.allocator);
    defer self.allocator.free(search_utf16);

    const search_lower_utf16 = try self.allocator.allocSentinel(u16, search_utf16.len, 0);
    defer self.allocator.free(search_lower_utf16);
    @memcpy(search_lower_utf16[0..search_utf16.len], search_utf16);
    if (search_lower_utf16.len > 0) {
        _ = w.CharLowerBuffW(search_lower_utf16, @intCast(search_lower_utf16.len - 1));
    }

    // Convert the lowercased search query to UTF-8 for comparison with dw.title_lower
    var search_utf8_buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&search_utf8_buf);
    const search_actual = std.mem.sliceTo(search_lower_utf16, 0);
    const search_utf8: []const u8 = std.unicode.utf16LeToUtf8Alloc(fba.allocator(), search_actual) catch "";

    var reset_focus = self.previous_hidden;
    var hidden_num: usize = 0;

    for (self.layout.tiles.items) |tile| {
        const dw = tile.desktopWindow;
        if (search_utf8.len <= 1) {
            tile.visible = true;
        } else {
            if (std.mem.containsAtLeast(u8, dw.title_lower, 1, search_utf8)) {
                tile.visible = true;
            } else {
                if (self.layout.selected_idx) |s| {
                    if (s < self.layout.tiles.items.len and self.layout.tiles.items[s] == tile) {
                        reset_focus = true;
                    }
                }
                hidden_num += 1;
                tile.visible = false;
            }
        }
    }

    if (hidden_num == self.layout.tiles.items.len) {
        self.previous_hidden = true;
    } else {
        self.previous_hidden = false;
    }

    try self.layout.layout(reset_focus);
    try self.updateRegion();
}

fn updateBoxes(self: *Self) !void {
    if (self.desktop_windows) |desktop_windows| {
        if (desktop_windows.items.len > 0) {
            for (desktop_windows.items) |dw| {
                const tile = try Tile.create(dw, &self.tile_callbacks, self.layout.window.dpi, self.allocator);
                try self.layout.addTile(tile);
            }
            try self.search_box.clearText();
            self.previous_hidden = false;
            try self.layout.layout(true);
            _ = self.search_box.window.show();
            try self.search_box.window.bringToTop();
            try self.layout.window.focus();
            try self.updateRegion();
        }
    }
}

fn setFonts(self: *Self) !void {
    self.font = w.GetStockObject(w.DEFAULT_GUI_FONT);
}
