const std = @import("std");
const wh = @import("windows.zig");
const w = wh.c;
const sys = @import("SystemInteraction.zig");
const common = @import("../../common/DesktopWindow.zig");
const Grid = @import("../../common/Grid.zig");
pub const Window = @import("Window.zig");
pub const Tile = @import("Tile.zig");

const Self = @This();

window: *Window,
allocator: std.mem.Allocator,
event_handlers: Window.EventHandlers,

// Pure-logic placement + selection lives in common.Grid; this module owns
// the per-tile HWND/font/icon resources and mirrors grid coordinates into
// physical pixels via DPI scaling.
grid: Grid,
tiles: std.array_list.Managed(*Tile),
selected_idx: ?usize = null,

fn onResizeHandler(event_handlers: *Window.EventHandlers, window: *Window) !void {
    if (window.docked) {
        try window.dock();
    }

    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);

    try self.relayout();
}

fn onPaintHandler(event_handlers: *Window.EventHandlers, window: *Window) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);

    var ps: w.PAINTSTRUCT = undefined;
    const hdc = w.BeginPaint(window.hwnd, &ps);
    defer _ = w.EndPaint(window.hwnd, &ps);

    const client = try window.getClientRect();
    const width = client.right - client.left;
    const height = client.bottom - client.top;

    const memDc = w.CreateCompatibleDC(hdc);
    defer _ = w.DeleteDC(memDc);
    const memBmp = w.CreateCompatibleBitmap(hdc, width, height);
    defer _ = w.DeleteObject(memBmp);
    const oldBmp = w.SelectObject(memDc, memBmp);
    defer _ = w.SelectObject(memDc, oldBmp);

    const hbrushBg = w.CreateSolidBrush(0);
    defer _ = w.DeleteObject(hbrushBg);
    var fillRect: w.RECT = .{ .left = 0, .top = 0, .right = width, .bottom = height };
    _ = w.FillRect(memDc, &fillRect, hbrushBg);

    const dpi = window.dpi;
    for (self.tiles.items, 0..) |tile, idx| {
        if (!tile.visible) continue;
        const selected = if (self.selected_idx) |s| s == idx else false;
        try tile.paint(memDc, dpi, selected);
    }

    _ = w.BitBlt(hdc, 0, 0, width, height, memDc, 0, 0, w.SRCCOPY);
}

fn onKeyDownHandler(event_handlers: *Window.EventHandlers, _: *Window, wParam: w.WPARAM, lParam: w.LPARAM) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    if (wParam == w.VK_TAB) {
        const shiftState = w.GetAsyncKeyState(w.VK_SHIFT);
        if ((shiftState >> 15) != 0) {
            try self.prev();
        } else {
            try self.next();
        }
    } else if (wParam == w.VK_RIGHT) {
        try self.right();
    } else if (wParam == w.VK_LEFT) {
        try self.left();
    } else if (wParam == w.VK_UP) {
        try self.up();
    } else if (wParam == w.VK_DOWN) {
        try self.down();
    } else if (wParam == w.VK_RETURN) {
        try self.activate();
    } else if (self.window.parent) |p| {
        _ = w.SendMessageW(p.hwnd, w.WM_KEYDOWN, wParam, lParam);
    }
}

fn onCharHandler(event_handlers: *Window.EventHandlers, _: *Window, wParam: w.WPARAM, lParam: w.LPARAM) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    // Forwarding these to the single-line EDIT search box triggers MessageBeep;
    // their VK_* counterparts are already consumed in onKeyDownHandler.
    if (wParam == '\r' or wParam == '\t' or wParam == 0x1B) return;
    if (self.window.parent) |p| {
        _ = w.SendMessageW(p.hwnd, w.WM_CHAR, wParam, lParam);
    }
}

fn onAfterDestroyHandler(event_handlers: *Window.EventHandlers, window: *Window) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    self.grid.deinit();
    for (self.tiles.items) |tile| tile.destroy();
    self.tiles.deinit();
    self.allocator.destroy(window);
}

fn onCommandHandler(event_handlers: *Window.EventHandlers, _: *Window, wParam: w.WPARAM, lParam: w.LPARAM) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    if (self.window.parent) |p| {
        _ = w.SendMessageW(p.hwnd, w.WM_COMMAND, wParam, lParam);
    }
}

fn onMouseMoveHandler(event_handlers: *Window.EventHandlers, _: *Window, _: u64, x: i16, y: i16) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    const px: i32 = x;
    const py: i32 = y;
    for (self.tiles.items, 0..) |tile, idx| {
        if (!tile.visible) continue;
        if (px >= tile.bounds.left and px < tile.bounds.right and py >= tile.bounds.top and py < tile.bounds.bottom) {
            if (self.selected_idx == null or self.selected_idx.? != idx) {
                self.selected_idx = idx;
                self.grid.selected = idx;
                try self.window.redraw();
            }
            return;
        }
    }
}

fn onClickHandler(event_handlers: *Window.EventHandlers, _: *Window) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    try self.activate();
}

pub fn create(hInstance: w.HINSTANCE, parent: *Window, allocator: std.mem.Allocator) !*Self {
    const windowConfig = Window.WindowParameters{
        .title = sys.toUtf16const("SpiralLayout"),
        .className = sys.toUtf16const("SpiralLayout"),
        .style = w.WS_VISIBLE | w.WS_CHILD | w.WS_CLIPSIBLINGS,
        .parent = parent,
        .register_class = true,
    };
    var self = try allocator.create(Self);
    self.* = .{
        .window = undefined,
        .allocator = allocator,
        .grid = Grid.init(allocator),
        .tiles = std.array_list.Managed(*Tile).init(allocator),
        .event_handlers = .{
            .onResize = onResizeHandler,
            .onPaint = onPaintHandler,
            .onKeyDown = onKeyDownHandler,
            .onAfterDestroy = onAfterDestroyHandler,
            .onChar = onCharHandler,
            .onCommand = onCommandHandler,
            .onMouseMove = onMouseMoveHandler,
            .onClick = onClickHandler,
        },
    };

    const window: *Window = try Window.create(windowConfig, &self.event_handlers, hInstance, allocator);
    window.docked = true;

    self.window = window;
    return self;
}

pub fn addTile(self: *Self, tile: *Tile) !void {
    try self.tiles.append(tile);
}

pub fn clear(self: *Self) !void {
    self.grid.dropDesktopWindows();
    for (self.tiles.items) |tile| tile.destroy();
    self.tiles.clearRetainingCapacity();
    self.selected_idx = null;
    try self.window.redraw();
}

/// Hand the grid a fresh window list. Caller still owns the slice.
pub fn setDesktopWindows(self: *Self, dws: []const common.DesktopWindow) !void {
    try self.updateGridViewport();
    try self.grid.setDesktopWindows(dws);
    self.mirrorFromGrid();
    try self.window.redraw();
}

/// Update the grid's search filter (UTF-8 lowercased). Keeps tile selection
/// stable when the previously-selected tile remains visible.
pub fn setSearch(self: *Self, utf8: []const u8) !void {
    try self.updateGridViewport();
    try self.grid.setSearch(utf8);
    self.mirrorFromGrid();
    try self.window.redraw();
}

fn relayout(self: *Self) !void {
    try self.updateGridViewport();
    try self.grid.rebuild();
    self.mirrorFromGrid();
    try self.window.redraw();
}

fn updateGridViewport(self: *Self) !void {
    const client = try self.window.getClientRect();
    const dpi = self.window.dpi;
    const phys_w = client.right - client.left;
    const phys_h = client.bottom - client.top;
    const lw = w.MulDiv(phys_w, 96, @intCast(dpi));
    const lh = w.MulDiv(phys_h, 96, @intCast(dpi));
    self.grid.setViewport(lw, lh);
}

fn mirrorFromGrid(self: *Self) void {
    const dpi = self.window.dpi;
    for (self.tiles.items, 0..) |tile, i| {
        if (i >= self.grid.tiles.items.len) {
            tile.visible = false;
            continue;
        }
        const gt = self.grid.tiles.items[i];
        tile.visible = gt.visible;
        if (gt.visible) {
            const x = w.MulDiv(gt.x, @intCast(dpi), 96);
            const y = w.MulDiv(gt.y, @intCast(dpi), 96);
            const ww = w.MulDiv(Grid.TILE_W, @intCast(dpi), 96);
            const hh = w.MulDiv(Grid.TILE_H, @intCast(dpi), 96);
            tile.bounds = .{ .left = x, .top = y, .right = x + ww, .bottom = y + hh };
        }
    }
    self.selected_idx = self.grid.selected;
}

fn applySelection(self: *Self) !void {
    self.selected_idx = self.grid.selected;
    try self.window.redraw();
}

pub fn next(self: *Self) !void {
    self.grid.selectNext(false);
    try self.applySelection();
}

pub fn prev(self: *Self) !void {
    self.grid.selectNext(true);
    try self.applySelection();
}

pub fn right(self: *Self) !void {
    self.grid.selectDir(1, 0);
    try self.applySelection();
}

pub fn left(self: *Self) !void {
    self.grid.selectDir(-1, 0);
    try self.applySelection();
}

pub fn down(self: *Self) !void {
    self.grid.selectDir(0, 1);
    try self.applySelection();
}

pub fn up(self: *Self) !void {
    self.grid.selectDir(0, -1);
    try self.applySelection();
}

pub fn activate(self: *Self) !void {
    const idx = self.selected_idx orelse return;
    if (idx >= self.tiles.items.len) return;
    const tile = self.tiles.items[idx];
    if (!tile.visible) return;
    try tile.callbacks.clicked(tile);
}
