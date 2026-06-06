// Pure logic: tile placement (spiral), search filter, selection. No platform deps.
const std = @import("std");
const common = @import("DesktopWindow.zig");
const spiral = @import("SpiralLayout.zig");

const Self = @This();

pub const TILE_W: i32 = 100;
pub const TILE_H: i32 = 100;
// Tiles are placed edge-to-edge (no overlap, no gap). Each tile owns its
// left + top 1px border; right + bottom borders are painted only on the
// outer tiles (those without a visible neighbor in that direction). The
// rendering pass takes care of this — see common/Renderer.zig. Using a
// non-negative margin keeps internal and external borders the same 1px
// thickness at any scale, including macOS scaled-Retina modes where the
// compositor downsamples a 1px-overlap design unevenly.
pub const TILE_MARGIN: i32 = 0;
pub const SEARCH_H: i32 = 20;
pub const SEARCH_W: i32 = 100;
// Windows places the search box ~100px above the bottom edge.
pub const SEARCH_BOTTOM_OFFSET: i32 = 100;
const GRID_BOTTOM_PAD: i32 = SEARCH_BOTTOM_OFFSET + SEARCH_H;

pub const Tile = struct {
    dw: common.DesktopWindow,
    x: i32,
    y: i32,
    visible: bool,
};

allocator: std.mem.Allocator,
// Borrowed; the caller (MainPresenter) owns the underlying allocations and
// is responsible for destroying the DesktopWindows.
desktop_windows: ?[]const common.DesktopWindow = null,
tiles: std.ArrayListUnmanaged(Tile) = .{},
search: [256]u8 = undefined,
search_len: usize = 0,
selected: ?usize = null,
viewport_w: i32 = 0,
viewport_h: i32 = 0,
// Optional cursor-anchored center (logical). When set, the grid is translated
// so its center lands here; null = viewport-centered (default). offset_x/offset_y
// are the derived translation, recomputed each rebuild and read by the renderer.
center: ?struct { x: i32, y: i32 } = null,
offset_x: i32 = 0,
offset_y: i32 = 0,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Self) void {
    self.tiles.deinit(self.allocator);
    self.dropDesktopWindows();
}

pub fn setViewport(self: *Self, w: i32, h: i32) void {
    self.viewport_w = w;
    self.viewport_h = h;
}

/// Anchor the grid's center at (x, y) in logical viewport coordinates. The next
/// rebuild clamps it so the central tile stays on-screen.
pub fn setCenter(self: *Self, x: i32, y: i32) void {
    self.center = .{ .x = x, .y = y };
}

/// Revert to viewport-centered layout.
pub fn clearCenter(self: *Self) void {
    self.center = null;
}

pub fn setDesktopWindows(self: *Self, dws: []const common.DesktopWindow) !void {
    self.dropDesktopWindows();
    self.desktop_windows = dws;
    self.search_len = 0;
    self.selected = null;
    try self.rebuild();
}

pub fn dropDesktopWindows(self: *Self) void {
    self.desktop_windows = null;
    self.tiles.clearRetainingCapacity();
    self.search_len = 0;
    self.selected = null;
}

pub fn searchSlice(self: *const Self) []const u8 {
    return self.search[0..self.search_len];
}

pub fn appendSearch(self: *Self, bytes: []const u8) !void {
    if (self.search_len + bytes.len > self.search.len) return;
    @memcpy(self.search[self.search_len..][0..bytes.len], bytes);
    self.search_len += bytes.len;
    try self.rebuild();
}

/// Replace the entire search buffer. Used by platforms (Windows) where the
/// search text lives in a native control (a Win32 EDIT) and the grid mirrors
/// it on text-change notifications instead of owning the input directly.
pub fn setSearch(self: *Self, bytes: []const u8) !void {
    if (bytes.len > self.search.len) return;
    @memcpy(self.search[0..bytes.len], bytes);
    self.search_len = bytes.len;
    try self.rebuild();
}

pub fn popSearchCodepoint(self: *Self) !void {
    if (self.search_len == 0) return;
    while (self.search_len > 0) {
        self.search_len -= 1;
        if ((self.search[self.search_len] & 0xC0) != 0x80) break;
    }
    try self.rebuild();
}

pub fn popSearchWord(self: *Self) !void {
    if (self.search_len == 0) return;
    // Drop trailing whitespace, then drop the run of non-whitespace bytes
    // before it. Mirrors readline's word-erase semantics.
    while (self.search_len > 0) {
        const b = self.search[self.search_len - 1];
        if (b != ' ' and b != '\t') break;
        self.search_len -= 1;
    }
    while (self.search_len > 0) {
        const b = self.search[self.search_len - 1];
        if (b == ' ' or b == '\t') break;
        self.search_len -= 1;
    }
    try self.rebuild();
}

pub fn rebuild(self: *Self) !void {
    self.tiles.clearRetainingCapacity();
    const dws = self.desktop_windows orelse return;

    const filter = self.searchSlice();

    const w_i = self.viewport_w;
    const h_i = self.viewport_h;
    const grid_h = h_i - GRID_BOTTOM_PAD;
    const tile_step_x = TILE_W + TILE_MARGIN;
    const tile_step_y = TILE_H + TILE_MARGIN;

    // Translation that moves the grid's center to the requested cursor point,
    // clamped so the central tile stays fully on-screen. Zero when uncentered.
    const default_cx = @divFloor(w_i, 2);
    const default_cy = @divFloor(grid_h, 2);
    self.offset_x = 0;
    self.offset_y = 0;
    if (self.center) |c| {
        const cx_c = std.math.clamp(c.x, @divFloor(TILE_W, 2), w_i - @divFloor(TILE_W, 2));
        const cy_c = std.math.clamp(c.y, @divFloor(TILE_H, 2), h_i - @divFloor(TILE_H, 2));
        self.offset_x = cx_c - default_cx;
        self.offset_y = cy_c - default_cy;
    }
    const cols: i32 = @max(@as(i32, 1), @divFloor(w_i, tile_step_x));
    const rows: i32 = @max(@as(i32, 1), @divFloor(grid_h, tile_step_y));
    const col_max: i32 = @divFloor(cols, 2);
    const col_min: i32 = -col_max + 1;
    const row_max: i32 = @divFloor(rows, 2);
    const row_min: i32 = -row_max + 1;

    var visible_idx: usize = 0;
    for (dws) |dw| {
        const matches = filter.len == 0 or
            std.mem.indexOf(u8, dw.title_lower, filter) != null or
            std.mem.indexOf(u8, dw.app_id_lower, filter) != null;
        if (!matches) {
            try self.tiles.append(self.allocator, .{ .dw = dw, .x = 0, .y = 0, .visible = false });
            continue;
        }

        const col = spiral.numToCol(visible_idx);
        const row = spiral.numToRow(visible_idx);
        if (col < col_min or col > col_max or row < row_min or row > row_max) {
            try self.tiles.append(self.allocator, .{ .dw = dw, .x = 0, .y = 0, .visible = false });
            continue;
        }

        const cx = default_cx + col * tile_step_x - @divFloor(TILE_W, 2) + self.offset_x;
        const cy = default_cy + row * tile_step_y - @divFloor(TILE_H, 2) + self.offset_y;
        try self.tiles.append(self.allocator, .{ .dw = dw, .x = cx, .y = cy, .visible = true });
        visible_idx += 1;
    }

    if (self.selected) |sel| {
        if (sel >= self.tiles.items.len or !self.tiles.items[sel].visible) self.selected = firstVisible(self.tiles.items);
    } else {
        self.selected = firstVisible(self.tiles.items);
    }
}

fn firstVisible(tiles: []const Tile) ?usize {
    for (tiles, 0..) |t, i| if (t.visible) return i;
    return null;
}

pub fn selectNext(self: *Self, reverse: bool) void {
    const n = self.tiles.items.len;
    if (n == 0) return;
    const cur = self.selected orelse 0;
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        const idx = if (reverse) (cur + n - i) % n else (cur + i) % n;
        if (self.tiles.items[idx].visible) {
            self.selected = idx;
            return;
        }
    }
}

pub fn selectDir(self: *Self, dx: i32, dy: i32) void {
    const cur = self.selected orelse return;
    if (cur >= self.tiles.items.len) return;
    const t = self.tiles.items[cur];
    if (!t.visible) return;
    const tx = t.x + @divFloor(TILE_W, 2);
    const ty = t.y + @divFloor(TILE_H, 2);

    var best: ?usize = null;
    var best_dist: i64 = std.math.maxInt(i64);
    for (self.tiles.items, 0..) |o, i| {
        if (i == cur or !o.visible) continue;
        const ox = o.x + @divFloor(TILE_W, 2);
        const oy = o.y + @divFloor(TILE_H, 2);
        const ddx: i64 = ox - tx;
        const ddy: i64 = oy - ty;
        if (dx != 0 and ddx * dx <= 0) continue;
        if (dy != 0 and ddy * dy <= 0) continue;
        const dist = ddx * ddx + ddy * ddy;
        if (dist < best_dist) {
            best_dist = dist;
            best = i;
        }
    }
    if (best) |b| self.selected = b;
}

pub fn selectedWindow(self: *const Self) ?common.DesktopWindow {
    const idx = self.selected orelse return null;
    if (idx >= self.tiles.items.len) return null;
    const t = self.tiles.items[idx];
    if (!t.visible) return null;
    return t.dw;
}

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

pub fn searchBoxRect(self: *const Self) Rect {
    // Shift with the grid, but clamp to the viewport so the box stays visible
    // when the cursor (and thus the grid) is near a screen edge.
    var sx = @divFloor(self.viewport_w - SEARCH_W, 2) + self.offset_x;
    var sy = self.viewport_h - SEARCH_BOTTOM_OFFSET + self.offset_y;
    sx = std.math.clamp(sx, 0, @max(0, self.viewport_w - SEARCH_W));
    sy = std.math.clamp(sy, 0, @max(0, self.viewport_h - SEARCH_H));
    return .{ .x = sx, .y = sy, .w = SEARCH_W, .h = SEARCH_H };
}

pub fn tileAt(self: *const Self, x: i32, y: i32) ?usize {
    for (self.tiles.items, 0..) |t, i| {
        if (!t.visible) continue;
        if (x >= t.x and x < t.x + TILE_W and y >= t.y and y < t.y + TILE_H) return i;
    }
    return null;
}

/// Returns true if selection changed.
pub fn selectAt(self: *Self, x: i32, y: i32) bool {
    const i = self.tileAt(x, y) orelse return false;
    if (self.selected) |s| if (s == i) return false;
    self.selected = i;
    return true;
}

pub fn isInsideSearchBox(self: *const Self, x: i32, y: i32) bool {
    const r = self.searchBoxRect();
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
}

/// Center coordinate of the visible tile matching app_id, or null.
pub fn tileCenter(self: *const Self, app_id: []const u8) ?struct { x: i32, y: i32 } {
    for (self.tiles.items) |t| {
        if (!t.visible) continue;
        if (std.mem.eql(u8, t.dw.app_id, app_id)) {
            return .{ .x = t.x + @divFloor(TILE_W, 2), .y = t.y + @divFloor(TILE_H, 2) };
        }
    }
    return null;
}

test "setCenter translates grid and search box; clearCenter reverts" {
    var g = Self.init(std.testing.allocator);
    defer g.deinit();
    g.setViewport(1000, 800);
    try g.setDesktopWindows(&[_]common.DesktopWindow{}); // empty: runs rebuild, no tiles

    // Default: viewport-centered, no offset.
    try std.testing.expectEqual(@as(i32, 0), g.offset_x);
    try std.testing.expectEqual(@as(i32, 0), g.offset_y);

    // Center near top-left. default center = (500, (800-120)/2 = 340).
    g.setCenter(300, 250);
    try g.rebuild();
    try std.testing.expectEqual(@as(i32, -200), g.offset_x);
    try std.testing.expectEqual(@as(i32, -90), g.offset_y);
    const sr = g.searchBoxRect(); // base (450, 700) + offset
    try std.testing.expectEqual(@as(i32, 250), sr.x);
    try std.testing.expectEqual(@as(i32, 610), sr.y);

    // Extreme corner clamps the center tile on-screen and the search box too.
    g.setCenter(-5000, 5000);
    try g.rebuild();
    try std.testing.expectEqual(@as(i32, @divFloor(TILE_W, 2) - 500), g.offset_x);
    const sr2 = g.searchBoxRect();
    try std.testing.expect(sr2.x >= 0 and sr2.x <= 1000 - SEARCH_W);
    try std.testing.expect(sr2.y >= 0 and sr2.y <= 800 - SEARCH_H);

    g.clearCenter();
    try g.rebuild();
    try std.testing.expectEqual(@as(i32, 0), g.offset_x);
    try std.testing.expectEqual(@as(i32, 0), g.offset_y);
}
