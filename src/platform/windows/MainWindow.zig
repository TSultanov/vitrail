const std = @import("std");
const wh = @import("windows.zig");
const w = wh.c;
const sys = @import("SystemInteraction.zig");
const common = @import("../../common/DesktopWindow.zig");
const Grid = @import("../../common/Grid.zig");
pub const Window = @import("Window.zig");
pub const Layout = @import("Layout.zig");

const Self = @This();

pub const PlatformArgs = struct {
    hInstance: w.HINSTANCE,
};

pub const Callbacks = struct {
    activateWindow: *const fn (main_window: *Self, dw: common.DesktopWindow) anyerror!void,
    hide: *const fn (main_window: *Self) anyerror!void,
    openSettings: *const fn (main_window: *Self) anyerror!void,
};

window: *Window,
layout: *Layout,
event_handlers: Window.EventHandlers,
desktop_windows: ?std.array_list.Managed(common.DesktopWindow),
hInstance: w.HINSTANCE,
allocator: std.mem.Allocator,
callbacks: *Callbacks,

// Bridge from Layout up to this MainWindow. Layout calls .activate when a
// tile is clicked / Enter-pressed and .visibility_changed when the search
// filter or window list changes the visible tile set; we recover *Self via
// @fieldParentPtr.
layout_callbacks: Layout.Callbacks = .{
    .activate = onLayoutActivate,
    .visibility_changed = onLayoutVisibilityChanged,
},

fn onLayoutActivate(cbs: *Layout.Callbacks, dw: common.DesktopWindow) !void {
    const self: *Self = @fieldParentPtr("layout_callbacks", cbs);
    try self.callbacks.activateWindow(self, dw);
}

fn onLayoutVisibilityChanged(cbs: *Layout.Callbacks) !void {
    const self: *Self = @fieldParentPtr("layout_callbacks", cbs);
    try self.updateRegion();
}

fn onAfterDestroyHandler(event_handlers: *Window.EventHandlers, _: *Window) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    self.allocator.destroy(self.window);
    self.allocator.destroy(self.layout);
    _ = w.PostQuitMessage(0);
}

fn onKeyDownHandler(event_handlers: *Window.EventHandlers, _: *Window, wParam: w.WPARAM, _: w.LPARAM) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    if (wParam == w.VK_ESCAPE) {
        try self.callbacks.hide(self);
    } else if (wParam == w.VK_OEM_COMMA and w.GetKeyState(w.VK_CONTROL) < 0) {
        // Ctrl+, — the "Preferences" chord, forwarded here from the Layout
        // child for keys it doesn't consume.
        try self.callbacks.openSettings(self);
    }
}

fn onActivateHandler(event_handlers: *Window.EventHandlers, _: *Window, wParam: w.WPARAM, _: w.LPARAM) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    const state = wParam & 0xFFFF;
    if (state == w.WA_INACTIVE and self.desktop_windows != null) {
        try self.callbacks.hide(self);
    }
}

fn onResizeHandler(event_handlers: *Window.EventHandlers, window: *Window) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    if (window.docked) try window.dock();
    for (window.children.items) |child| try child.resize();
    try self.updateRegion();
}

/// Rebuild the popup's transparency region from the grid's current visible
/// tiles + search box. Each tile rect is extended by 1px on right and bottom
/// so the renderer's seam borders (drawn at logical x+step_x / y+step_y) stay
/// inside the region; interior overlaps are harmless under RGN_OR.
fn updateRegion(self: *Self) !void {
    var window_rect: w.RECT = undefined;
    try wh.mapFailure(w.GetWindowRect(self.window.hwnd, &window_rect));

    var layout_rect: w.RECT = undefined;
    try wh.mapFailure(w.GetWindowRect(self.layout.window.hwnd, &layout_rect));

    const layout_offset_x: c_int = layout_rect.left - window_rect.left;
    const layout_offset_y: c_int = layout_rect.top - window_rect.top;

    const dpi: c_int = @intCast(self.layout.window.dpi);
    const step_x: c_int = Grid.TILE_W + Grid.TILE_MARGIN;
    const step_y: c_int = Grid.TILE_H + Grid.TILE_MARGIN;

    const rgn = w.CreateRectRgn(0, 0, 0, 0);

    for (self.layout.grid.tiles.items) |t| {
        if (!t.visible) continue;
        const tx: c_int = layout_offset_x + w.MulDiv(t.x, dpi, 96);
        const ty: c_int = layout_offset_y + w.MulDiv(t.y, dpi, 96);
        const tx_end: c_int = layout_offset_x + w.MulDiv(t.x + step_x, dpi, 96);
        const ty_end: c_int = layout_offset_y + w.MulDiv(t.y + step_y, dpi, 96);
        const tile_rgn = w.CreateRectRgn(tx, ty, tx_end + 1, ty_end + 1);
        defer _ = w.DeleteObject(tile_rgn);
        _ = w.CombineRgn(rgn, rgn, tile_rgn, w.RGN_OR);
    }

    if (self.desktop_windows != null) {
        const sr = self.layout.grid.searchBoxRect();
        const sx: c_int = layout_offset_x + w.MulDiv(sr.x, dpi, 96);
        const sy: c_int = layout_offset_y + w.MulDiv(sr.y, dpi, 96);
        const sx_end: c_int = layout_offset_x + w.MulDiv(sr.x + sr.w, dpi, 96);
        const sy_end: c_int = layout_offset_y + w.MulDiv(sr.y + sr.h, dpi, 96);
        const sb_rgn = w.CreateRectRgn(sx, sy, sx_end, sy_end);
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

pub fn onDpiChangeHandler(event_handlers: *Window.EventHandlers, window: *Window, _: w.WPARAM, _: w.LPARAM) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);

    const dpi = w.GetDpiForWindow(window.hwnd);
    window.setDpi(dpi);
    const desktop = w.GetDesktopWindow();
    var rect: w.RECT = undefined;
    try wh.mapFailure(w.GetWindowRect(desktop, &rect));
    try window.setSizeScaled(rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top);

    try self.layout.onDpiChanged();
}

pub fn onEnableHandler(_: *Window.EventHandlers, window: *Window, wParam: w.WPARAM, _: w.LPARAM) !void {
    if (wParam == 1) {
        const desktop = w.GetDesktopWindow();
        var desktopRect: w.RECT = undefined;
        try wh.mapFailure(w.GetWindowRect(desktop, &desktopRect));
        try window.setSize(desktopRect.left, desktopRect.top, desktopRect.right - desktopRect.left, desktopRect.bottom - desktopRect.top);
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
        .event_handlers = .{
            .onAfterDestroy = onAfterDestroyHandler,
            .onKeyDown = onKeyDownHandler,
            .onPaint = onPaintHandler,
            .onResize = onResizeHandler,
            .onDpiChange = onDpiChangeHandler,
            .onEnable = onEnableHandler,
            .onActivate = onActivateHandler,
        },
        .desktop_windows = null,
        .hInstance = hInstance,
        .allocator = allocator,
        .callbacks = callbacks,
    };

    const window = try Window.create(windowConfig, &self.event_handlers, hInstance, allocator);
    self.window = window;

    self.layout = try Layout.create(hInstance, window, &self.layout_callbacks, allocator);

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
    if (desktopWindows.items.len > 0) {
        try self.layout.setDesktopWindows(desktopWindows.items);
        try self.layout.window.focus();
        try self.updateRegion();
    }
}

pub fn hideBoxes(self: *Self) !void {
    try self.layout.clear();
    self.desktop_windows = null;
    try self.updateRegion();
}
