const std = @import("std");
const wh = @import("windows.zig");
const w = wh.c;
const sys = @import("SystemInteraction.zig");
const spiral = @import("../../common/SpiralLayout.zig");
const numToRow = spiral.numToRow;
const numToCol = spiral.numToCol;
pub const Window = @import("Window.zig");
pub const Tile = @import("Tile.zig");

const Self = @This();
const PosIdxMap = std.AutoArrayHashMap(BoxColRow, usize);
const IdxPosMap = std.AutoArrayHashMap(usize, BoxColRow);

window: *Window,

rows_max: i64 = std.math.minInt(i64),
cols_max: i64 = std.math.minInt(i64),
rows_min: i64 = std.math.maxInt(i64),
cols_min: i64 = std.math.maxInt(i64),
allocator: std.mem.Allocator,
event_handlers: Window.EventHandlers,

pos_idx_map: PosIdxMap,
idx_pos_map: IdxPosMap,
tiles: std.array_list.Managed(*Tile),
selected_idx: ?usize = null,

const chWidth: c_int = 100;
const chHeight: c_int = 100;
const margin: c_int = -1;

const BoxColRow = struct {
    col: i32,
    row: i32,
};

fn onResizeHandler(event_handlers: *Window.EventHandlers, window: *Window) !void {
    if (window.docked) {
        try window.dock();
    }

    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);

    try self.layout(false);
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
    self.idx_pos_map.deinit();
    self.pos_idx_map.deinit();
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
        .idx_pos_map = IdxPosMap.init(allocator),
        .pos_idx_map = PosIdxMap.init(allocator),
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
    self.idx_pos_map.clearAndFree();
    self.pos_idx_map.clearAndFree();
    for (self.tiles.items) |tile| tile.destroy();
    self.tiles.clearRetainingCapacity();
    self.selected_idx = null;
    try self.window.redraw();
}

pub fn layout(self: *Self, reset_focus: bool) !void {
    if (self.tiles.items.len == 0) {
        try self.window.redraw();
        return;
    }

    self.idx_pos_map.clearAndFree();
    self.pos_idx_map.clearAndFree();

    self.rows_max = std.math.minInt(i64);
    self.cols_max = std.math.minInt(i64);
    self.rows_min = std.math.maxInt(i64);
    self.cols_min = std.math.maxInt(i64);

    const marginScaled: c_int = self.window.scaleDpi(margin);
    const chWidthScaled = self.window.scaleDpi(chWidth);
    const chHeightScaled: c_int = self.window.scaleDpi(chHeight);

    const rect = try self.window.getClientRect();

    const width = rect.right - rect.left;
    const height = rect.bottom - rect.top;

    const rows = @divFloor(height, chHeightScaled + marginScaled);
    const cols = @divFloor(width, chWidthScaled + marginScaled);

    const maxNumberOfCells = (cols - 1) * (rows - 1);
    const rowMax = @divFloor(rows, 2);
    const rowMin = -@divFloor(rows, 2) + 1;
    const colMax = @divFloor(cols, 2);
    const colMin = -@divFloor(cols, 2) + 1;

    var idx: i64 = 0;
    var offset: i64 = 0;

    var lowest_visible_idx: i64 = -1;

    while (idx < self.tiles.items.len and idx < maxNumberOfCells) : (idx += 1) {
        const tile = self.tiles.items[@intCast(idx)];
        if (!tile.visible) {
            offset -= 1;
            continue;
        }

        if (lowest_visible_idx == -1) lowest_visible_idx = idx;

        var col = numToCol(@intCast(idx + offset));
        var row = numToRow(@intCast(idx + offset));
        while ((col < colMin or col > colMax or row < rowMin or row > rowMax) and (idx + offset < maxNumberOfCells)) {
            offset += 1;
            col = numToCol(@intCast(idx + offset));
            row = numToRow(@intCast(idx + offset));
        }

        self.cols_max = @max(self.cols_max, col);
        self.cols_min = @max(self.cols_min, col);
        self.rows_max = @max(self.rows_max, row);
        self.rows_min = @max(self.rows_min, row);

        const x = @divFloor(width, 2) + col * (chWidthScaled + marginScaled) - @divFloor(chWidthScaled, 2);
        const y = @divFloor(height, 2) + row * (chHeightScaled + marginScaled) - @divFloor(chHeightScaled, 2);

        tile.bounds = .{ .left = x, .top = y, .right = x + chWidthScaled, .bottom = y + chHeightScaled };

        try self.idx_pos_map.put(@intCast(idx), .{ .col = col, .row = row });
        try self.pos_idx_map.put(.{ .col = col, .row = row }, @intCast(idx));
    }

    if (reset_focus) {
        if (lowest_visible_idx >= 0) {
            self.selected_idx = @intCast(lowest_visible_idx);
        } else {
            self.selected_idx = null;
        }
    } else if (self.selected_idx) |s| {
        if (s >= self.tiles.items.len or !self.tiles.items[s].visible) {
            if (lowest_visible_idx >= 0) {
                self.selected_idx = @intCast(lowest_visible_idx);
            } else {
                self.selected_idx = null;
            }
        }
    }

    try self.window.redraw();
}

fn nextVisible(self: *Self, from: usize) ?usize {
    var i: usize = from + 1;
    while (i < self.tiles.items.len) : (i += 1) {
        if (self.tiles.items[i].visible and self.idx_pos_map.contains(i)) return i;
    }
    i = 0;
    while (i <= from) : (i += 1) {
        if (self.tiles.items[i].visible and self.idx_pos_map.contains(i)) return i;
    }
    return null;
}

fn prevVisible(self: *Self, from: usize) ?usize {
    if (from > 0) {
        var i: usize = from;
        while (i > 0) {
            i -= 1;
            if (self.tiles.items[i].visible and self.idx_pos_map.contains(i)) return i;
        }
    }
    var j: usize = self.tiles.items.len;
    while (j > from) {
        j -= 1;
        if (self.tiles.items[j].visible and self.idx_pos_map.contains(j)) return j;
    }
    return null;
}

fn setSelected(self: *Self, idx: usize) !void {
    if (self.selected_idx == null or self.selected_idx.? != idx) {
        self.selected_idx = idx;
        try self.window.redraw();
    }
}

pub fn next(self: *Self) !void {
    const cur = self.selected_idx orelse return;
    if (self.nextVisible(cur)) |i| try self.setSelected(i);
}

pub fn prev(self: *Self) !void {
    const cur = self.selected_idx orelse return;
    if (self.prevVisible(cur)) |i| try self.setSelected(i);
}

pub fn right(self: *Self) !void {
    const cur = self.selected_idx orelse return;
    const pos = self.idx_pos_map.get(cur) orelse return;
    if (self.pos_idx_map.get(.{ .col = pos.col + 1, .row = pos.row })) |i| try self.setSelected(i);
}

pub fn left(self: *Self) !void {
    const cur = self.selected_idx orelse return;
    const pos = self.idx_pos_map.get(cur) orelse return;
    if (self.pos_idx_map.get(.{ .col = pos.col - 1, .row = pos.row })) |i| try self.setSelected(i);
}

pub fn down(self: *Self) !void {
    const cur = self.selected_idx orelse return;
    const pos = self.idx_pos_map.get(cur) orelse return;
    if (self.pos_idx_map.get(.{ .col = pos.col, .row = pos.row + 1 })) |i| try self.setSelected(i);
}

pub fn up(self: *Self) !void {
    const cur = self.selected_idx orelse return;
    const pos = self.idx_pos_map.get(cur) orelse return;
    if (self.pos_idx_map.get(.{ .col = pos.col, .row = pos.row - 1 })) |i| try self.setSelected(i);
}

pub fn activate(self: *Self) !void {
    const idx = self.selected_idx orelse return;
    if (idx >= self.tiles.items.len) return;
    const tile = self.tiles.items[idx];
    if (!tile.visible) return;
    try tile.callbacks.clicked(tile);
}

