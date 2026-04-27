const std = @import("std");
const wh = @import("windows.zig");
const w = wh.c;
const sys = @import("SystemInteraction.zig");
pub const Window = @import("Window.zig");

const Self = @This();
const ChildIndexMap = std.AutoArrayHashMap(w.HWND, BoxPosition);
const PosIdxMap = std.AutoArrayHashMap(BoxColRow, usize);

window: *Window,

rows_max: i64 = std.math.minInt(i64),
cols_max: i64 = std.math.minInt(i64),
rows_min: i64 = std.math.maxInt(i64),
cols_min: i64 = std.math.maxInt(i64),
allocator: std.mem.Allocator,
event_handlers: Window.EventHandlers,

pos_idx_map: PosIdxMap,
child_index_map: ChildIndexMap,

const chWidth: c_int = 100;
const chHeight: c_int = 100;
const margin: c_int = -1;

const BoxPosition = struct {
    idx: usize,
    pos: BoxColRow,
};

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

fn onPaintHandler(_: *Window.EventHandlers, window: *Window) !void {
    var ps: w.PAINTSTRUCT = undefined;
    _ = w.BeginPaint(window.hwnd, &ps);
    _ = w.EndPaint(window.hwnd, &ps);
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
    } else if (self.window.parent) |p| {
        _ = w.SendMessageW(p.hwnd, w.WM_KEYDOWN, wParam, lParam);
    }
}

fn onCharHandler(event_handlers: *Window.EventHandlers, _: *Window, wParam: w.WPARAM, lParam: w.LPARAM) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    if (self.window.parent) |p| {
        _ = w.SendMessageW(p.hwnd, w.WM_CHAR, wParam, lParam);
    }
}

fn onAfterDestroyHandler(event_handlers: *Window.EventHandlers, window: *Window) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    self.child_index_map.deinit();
    self.pos_idx_map.deinit();
    self.allocator.destroy(window);
}

fn onCommandHandler(event_handlers: *Window.EventHandlers, _: *Window, wParam: w.WPARAM, lParam: w.LPARAM) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    if (self.window.parent) |p| {
        _ = w.SendMessageW(p.hwnd, w.WM_COMMAND, wParam, lParam);
    }
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
        .child_index_map = ChildIndexMap.init(allocator),
        .pos_idx_map = PosIdxMap.init(allocator),
        .event_handlers = .{
            .onResize = onResizeHandler,
            .onPaint = onPaintHandler,
            .onKeyDown = onKeyDownHandler,
            .onAfterDestroy = onAfterDestroyHandler,
            .onChar = onCharHandler,
            .onCommand = onCommandHandler,
        },
    };

    const window: *Window = try Window.create(windowConfig, &self.event_handlers, hInstance, allocator);
    window.docked = true;

    self.window = window;
    return self;
}

pub fn clear(self: *Self) !void {
    self.child_index_map.clearAndFree();
    self.pos_idx_map.clearAndFree();
    while (self.window.children.pop()) |child| {
        child.destroy();
    }
}

pub fn layout(self: *Self, reset_focus: bool) !void {
    if (self.window.children.items.len == 0) return;

    self.child_index_map.clearAndFree();
    self.pos_idx_map.clearAndFree();

    self.rows_max = std.math.minInt(i64);
    self.cols_max = std.math.minInt(i64);
    self.rows_min = std.math.maxInt(i64);
    self.cols_min = std.math.maxInt(i64);

    const marginScaled: c_int = self.window.scaleDpi(margin);
    const chWidthScaled = self.window.scaleDpi(chWidth);
    const chHeightScaled: c_int = self.window.scaleDpi(chHeight);

    const rect = try self.window.getRect();

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

    var lowest_visible_idx: i64 = 0;

    while (idx < self.window.children.items.len and idx < maxNumberOfCells) : (idx += 1) {
        if (!self.window.children.items[@intCast(idx)].isVisible()) {
            if (lowest_visible_idx == idx) {
                lowest_visible_idx += 1;
            }
            offset -= 1;
            continue;
        }

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

        try self.child_index_map.put(self.window.children.items[@intCast(idx)].hwnd, .{ .idx = @intCast(idx), .pos = .{ .col = col, .row = row } });
        try self.pos_idx_map.put(.{ .col = col, .row = row }, @intCast(idx));

        try self.window.children.items[@intCast(idx)].setSize(x, y, chWidthScaled, chHeightScaled);
    }

    if (reset_focus) {
        if (lowest_visible_idx < self.window.children.items.len) {
            try self.window.children.items[@intCast(lowest_visible_idx)].focus();
        }
    }
}

pub fn next(self: *Self) !void {
    const focused_hwnd = w.GetFocus();
    if (self.child_index_map.get(focused_hwnd)) |box_position| {
        if (box_position.idx < self.window.children.items.len - 1) {
            try self.window.children.items[box_position.idx + 1].focus();
        } else {
            try self.window.children.items[0].focus();
        }
    }
}

pub fn prev(self: *Self) !void {
    const focused_hwnd = w.GetFocus();
    if (self.child_index_map.get(focused_hwnd)) |box_position| {
        if (box_position.idx > 0) {
            try self.window.children.items[box_position.idx - 1].focus();
        } else {
            try self.window.children.items[self.window.children.items.len - 1].focus();
        }
    }
}

pub fn right(self: *Self) !void {
    const focused_hwnd = w.GetFocus();
    if (self.child_index_map.get(focused_hwnd)) |box_position| {
        if (self.pos_idx_map.get(.{ .col = box_position.pos.col + 1, .row = box_position.pos.row })) |pos| {
            try self.window.children.items[pos].focus();
        }
    }
}

pub fn left(self: *Self) !void {
    const focused_hwnd = w.GetFocus();
    if (self.child_index_map.get(focused_hwnd)) |box_position| {
        if (self.pos_idx_map.get(.{ .col = box_position.pos.col - 1, .row = box_position.pos.row })) |pos| {
            try self.window.children.items[pos].focus();
        }
    }
}

pub fn down(self: *Self) !void {
    const focused_hwnd = w.GetFocus();
    if (self.child_index_map.get(focused_hwnd)) |box_position| {
        if (self.pos_idx_map.get(.{ .col = box_position.pos.col, .row = box_position.pos.row + 1 })) |pos| {
            try self.window.children.items[pos].focus();
        }
    }
}

pub fn up(self: *Self) !void {
    const focused_hwnd = w.GetFocus();
    if (self.child_index_map.get(focused_hwnd)) |box_position| {
        if (self.pos_idx_map.get(.{ .col = box_position.pos.col, .row = box_position.pos.row - 1 })) |pos| {
            try self.window.children.items[pos].focus();
        }
    }
}

fn numToRow(n: usize) i32 {
    const nf: f64 = @floatFromInt(n);
    const layer: i32 = @intFromFloat(std.math.floor(0.25 * (1 + std.math.sqrt(8 * nf + 1))));
    const layerCellsCount = 4 * layer;
    const sideCellsCount = if (n == 0) 1 else @divTrunc(layerCellsCount, 4);
    const layerStart = if (n == 0) 0 else layer * (2 * layer - 1);
    const layerPosition: i32 = @as(i32, @intCast(n)) - layerStart;
    const side = std.math.ceil(@as(f64, @floatFromInt(layerPosition + 1)) / @as(f64, @floatFromInt(2 * sideCellsCount))) - 1;
    const offset: i32 = if (n == 0) 0 else (if (side == 0) layerPosition else layerCellsCount - layerPosition);
    const row = offset - layer;
    return row;
}

fn numToCol(n: usize) i32 {
    const nf: f64 = @floatFromInt(n);
    const layer: i32 = @intFromFloat(std.math.ceil(0.5 * (std.math.sqrt(2 * nf + 1) - 1)));
    const layerCellsCount = 4 * layer;
    const sideCellsCount = if (n == 0) 1 else @divTrunc(layerCellsCount, 4);
    const layerStart = if (n == 0) 0 else 2 * (layer - 1) * ((layer - 1) + 1) + 1;
    const layerPosition: i32 = @as(i32, @intCast(n)) - layerStart;
    const side = std.math.ceil(@as(f64, @floatFromInt(layerPosition + 1)) / @as(f64, @floatFromInt(2 * sideCellsCount))) - 1;
    const offset: i32 = if (n == 0) 0 else (if (side == 0) layerPosition + 1 else layerCellsCount - layerPosition - 1);
    const col = offset - layer;
    return col;
}
