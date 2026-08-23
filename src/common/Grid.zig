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

pub const RefreshOptions = struct {
    /// Preserve selection across a platform-specific identity transition when
    /// a replacement represents the same non-empty app as the selected tile.
    /// Disabled by default: on most platforms this could treat an unrelated
    /// new window from the same app as the vanished window.
    select_same_app_replacement: bool = false,
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
    self.dropDesktopWindows();
    self.tiles.deinit(self.allocator);
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
    // Use the same staged rebuild as a live replacement. If allocation fails,
    // the Grid remains empty instead of borrowing a snapshot the presenter
    // correctly treats as uncommitted and destroys.
    try self.refreshDesktopWindows(dws);
}

/// Transactionally replace the borrowed window snapshot while preserving the
/// current overlay session. Candidate tiles are fully rebuilt in a separate
/// Grid so removals compact the layout and an allocation failure leaves this
/// instance untouched.
pub fn refreshDesktopWindows(self: *Self, dws: []const common.DesktopWindow) !void {
    try self.refreshDesktopWindowsWithOptions(dws, .{});
}

pub fn refreshDesktopWindowsWithOptions(
    self: *Self,
    dws: []const common.DesktopWindow,
    options: RefreshOptions,
) !void {
    const selected_tile: ?Tile = if (self.selected) |idx|
        if (idx < self.tiles.items.len and self.tiles.items[idx].visible)
            self.tiles.items[idx]
        else
            null
    else
        null;
    const selected_id: ?[]const u8 = if (selected_tile) |tile| tile.dw.stable_id else null;

    // If the selected window vanishes, keep the same visible-rank slot. This
    // chooses the following tile after a removal, or the preceding tile when
    // the removed item was last.
    var selected_visible_rank: usize = 0;
    if (self.selected) |sel| {
        for (self.tiles.items[0..@min(sel, self.tiles.items.len)]) |tile| {
            if (tile.visible) selected_visible_rank += 1;
        }
    }

    var staged = Self.init(self.allocator);
    defer staged.deinit();
    staged.viewport_w = self.viewport_w;
    staged.viewport_h = self.viewport_h;
    staged.center = self.center;
    staged.search_len = self.search_len;
    if (self.search_len > 0) {
        @memcpy(staged.search[0..self.search_len], self.search[0..self.search_len]);
    }
    staged.desktop_windows = dws;
    try staged.rebuild();

    var selected_by_id: ?usize = null;
    if (selected_id) |id| {
        for (staged.tiles.items, 0..) |tile, idx| {
            if (tile.visible and std.mem.eql(u8, tile.dw.stable_id, id)) {
                selected_by_id = idx;
                break;
            }
        }
    }
    var selected_same_app: ?usize = null;
    if (selected_by_id == null and options.select_same_app_replacement) {
        // macOS replaces an app's last real-window entry with a windowless-app
        // placeholder. Its stable identity necessarily changes, but it still
        // represents the same app. Preserve that semantic selection before
        // falling back to list rank.
        if (selected_tile) |old| {
            // Empty app identifiers carry no identity and must never make two
            // otherwise-unrelated entries equivalent.
            if (old.dw.app_id.len != 0) {
                for (staged.tiles.items, 0..) |tile, idx| {
                    if (!tile.visible) continue;
                    if (!std.mem.eql(u8, tile.dw.app_id, old.dw.app_id)) continue;
                    selected_same_app = idx;
                    break;
                }
            }
        }
    }
    if (selected_by_id) |idx| {
        staged.selected = idx;
    } else if (selected_same_app) |idx| {
        staged.selected = idx;
    } else {
        staged.selected = visibleIndexAtRank(staged.tiles.items, selected_visible_rank);
    }

    std.mem.swap(std.ArrayListUnmanaged(Tile), &self.tiles, &staged.tiles);
    self.desktop_windows = dws;
    self.selected = staged.selected;
    self.offset_x = staged.offset_x;
    self.offset_y = staged.offset_y;
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
        // Cap the vertical center so the central tile clears the bottom-pinned
        // search box row. Without this, a click in the bottom-most row drops the
        // central tile onto the search box; it gets skipped and the whole grid
        // bumps up a row, wasting the space just above the search box. Capping
        // here makes a near-bottom click hug the search box instead.
        const cy_top = @divFloor(TILE_H, 2);
        const cy_bot = @max(cy_top, h_i - SEARCH_H - @divFloor(TILE_H, 2));
        const cy_c = std.math.clamp(c.y, cy_top, cy_bot);
        self.offset_x = cx_c - default_cx;
        self.offset_y = cy_c - default_cy;
    }
    // Probe spiral cells outward from the center and place each tile at the next
    // cell whose actual rect is fully on-screen and clear of the search box,
    // skipping cells that don't fit (which is what prevents clipping/overlap once
    // the cursor offset shifts the grid toward an edge). Every on-screen cell
    // relative to a clamped center lies within spiral ring max(cols, rows), so
    // this bounds the probe for the (rare) "more windows than fit" case.
    const cols: i32 = @max(@as(i32, 1), @divFloor(w_i, tile_step_x));
    const rows: i32 = @max(@as(i32, 1), @divFloor(grid_h, tile_step_y));
    const span: i32 = @max(cols, rows) + 1;
    const max_probe: usize = @intCast((2 * span + 1) * (2 * span + 1));
    const search_rect = self.searchBoxRect();

    var probe: usize = 0;
    for (dws) |dw| {
        if (!matchesFilter(filter, dw)) {
            try self.tiles.append(self.allocator, .{ .dw = dw, .x = 0, .y = 0, .visible = false });
            continue;
        }

        var placed = false;
        while (probe < max_probe) {
            const col = spiral.numToCol(probe);
            const row = spiral.numToRow(probe);
            probe += 1;
            const cx = default_cx + col * tile_step_x - @divFloor(TILE_W, 2) + self.offset_x;
            const cy = default_cy + row * tile_step_y - @divFloor(TILE_H, 2) + self.offset_y;
            if (positionFits(w_i, h_i, search_rect, cx, cy)) {
                try self.tiles.append(self.allocator, .{ .dw = dw, .x = cx, .y = cy, .visible = true });
                placed = true;
                break;
            }
        }
        if (!placed) {
            try self.tiles.append(self.allocator, .{ .dw = dw, .x = 0, .y = 0, .visible = false });
        }
    }

    if (self.selected) |sel| {
        if (sel >= self.tiles.items.len or !self.tiles.items[sel].visible) self.selected = firstVisible(self.tiles.items);
    } else {
        self.selected = firstVisible(self.tiles.items);
    }
}

/// A tile rect at (cx, cy) is placeable if it is fully within the viewport and
/// clear of the search box's row — the whole horizontal band at the search box's
/// height is off-limits (not just the box itself), so no tile sits level with the
/// search text.
fn positionFits(viewport_w: i32, viewport_h: i32, sr: Rect, cx: i32, cy: i32) bool {
    if (cx < 0 or cy < 0 or cx + TILE_W > viewport_w or cy + TILE_H > viewport_h) return false;
    return !(cy < sr.y + sr.h and cy + TILE_H > sr.y);
}

fn matchesFilter(filter: []const u8, dw: common.DesktopWindow) bool {
    return filter.len == 0 or
        std.mem.indexOf(u8, dw.title_lower, filter) != null or
        std.mem.indexOf(u8, dw.app_id_lower, filter) != null;
}

fn firstVisible(tiles: []const Tile) ?usize {
    for (tiles, 0..) |t, i| if (t.visible) return i;
    return null;
}

fn visibleIndexAtRank(tiles: []const Tile, requested_rank: usize) ?usize {
    var visible_count: usize = 0;
    for (tiles) |tile| {
        if (tile.visible) visible_count += 1;
    }
    if (visible_count == 0) return null;

    const rank = @min(requested_rank, visible_count - 1);
    var current: usize = 0;
    for (tiles, 0..) |tile, idx| {
        if (!tile.visible) continue;
        if (current == rank) return idx;
        current += 1;
    }
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

pub fn selectedWindowId(self: *const Self) ?[]const u8 {
    const dw = self.selectedWindow() orelse return null;
    return dw.stable_id;
}

pub fn windowById(self: *const Self, stable_id: []const u8) ?common.DesktopWindow {
    for (self.tiles.items) |tile| {
        if (std.mem.eql(u8, tile.dw.stable_id, stable_id)) return tile.dw;
    }
    return null;
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

fn testDw(name: [:0]const u8) common.DesktopWindow {
    return .{
        .stable_id = @constCast(name),
        .platform_handle = 0,
        .title = @constCast(name),
        .title_lower = @constCast(name),
        .app_id = @constCast(name),
        .app_id_lower = @constCast(name),
        .icon = null,
        .desktopNumber = null,
        .allocator = undefined, // Grid borrows; never frees these.
    };
}

fn testDwWithMetadata(
    stable_id: [:0]const u8,
    title: [:0]const u8,
    title_lower: [:0]const u8,
    app_id: [:0]const u8,
    app_id_lower: [:0]const u8,
    desktop_file: ?[:0]const u8,
    desktop_number: ?usize,
    can_close: bool,
) common.DesktopWindow {
    return .{
        .stable_id = @constCast(stable_id),
        .platform_handle = 0,
        .title = @constCast(title),
        .title_lower = @constCast(title_lower),
        .app_id = @constCast(app_id),
        .app_id_lower = @constCast(app_id_lower),
        .desktop_file = if (desktop_file) |value| @constCast(value) else null,
        .icon = null,
        .desktopNumber = desktop_number,
        .can_close = can_close,
        .allocator = undefined, // Grid borrows; never frees these.
    };
}

fn countVisible(tiles: []const Tile) usize {
    var count: usize = 0;
    for (tiles) |tile| {
        if (tile.visible) count += 1;
    }
    return count;
}

test "live refresh preserves session state and selection by stable id" {
    var g = Self.init(std.testing.allocator);
    defer g.deinit();
    g.setViewport(1000, 800);

    const initial = [_]common.DesktopWindow{
        testDw("alpha"),
        testDw("beta"),
        testDw("gamma"),
    };
    try g.setDesktopWindows(&initial);
    const beta = g.tileCenter("beta").?;
    _ = g.selectAt(beta.x, beta.y);
    try g.appendSearch("a");
    g.setCenter(320, 240);
    try g.rebuild();

    const refreshed = [_]common.DesktopWindow{
        testDw("gamma"),
        testDw("beta"),
        testDw("alpha"),
    };
    try g.refreshDesktopWindows(&refreshed);

    try std.testing.expectEqualStrings("a", g.searchSlice());
    try std.testing.expectEqualStrings("beta", g.selectedWindowId().?);
    try std.testing.expect(g.center != null);
    try std.testing.expectEqual(@as(i32, 320), g.center.?.x);
    try std.testing.expectEqual(@as(i32, 240), g.center.?.y);
}

test "live refresh admits new windows and replaces metadata for stable identities" {
    var g = Self.init(std.testing.allocator);
    defer g.deinit();
    g.setViewport(1000, 800);

    const initial = [_]common.DesktopWindow{
        testDwWithMetadata(
            "window-1",
            "Work draft",
            "work draft",
            "editor",
            "editor",
            "editor",
            1,
            true,
        ),
        testDwWithMetadata(
            "window-2",
            "Browser",
            "browser",
            "browser",
            "browser",
            null,
            2,
            true,
        ),
    };
    try g.setDesktopWindows(&initial);
    try g.appendSearch("work");
    const selected_before = g.selectedWindow() orelse return error.NoSelection;
    try std.testing.expectEqualStrings("window-1", selected_before.stable_id);
    const refreshed = [_]common.DesktopWindow{
        testDwWithMetadata(
            "window-2",
            "Browser",
            "browser",
            "browser",
            "browser",
            null,
            2,
            true,
        ),
        testDwWithMetadata(
            "window-1",
            "Roadmap",
            "roadmap",
            "workbench",
            "workbench",
            "workbench-nightly",
            4,
            false,
        ),
        testDwWithMetadata(
            "window-3",
            "Work chat",
            "work chat",
            "messenger",
            "messenger",
            "messenger",
            3,
            true,
        ),
    };
    try g.refreshDesktopWindows(&refreshed);

    try std.testing.expectEqualStrings("work", g.searchSlice());
    try std.testing.expectEqual(@as(usize, 2), countVisible(g.tiles.items));
    try std.testing.expectEqualStrings("window-1", g.selectedWindowId().?);
    try std.testing.expect(g.tileCenter("messenger") != null);

    const current = g.windowById("window-1") orelse return error.WindowMissing;
    try std.testing.expectEqualStrings("Roadmap", current.title);
    try std.testing.expectEqualStrings("workbench", current.app_id);
    try std.testing.expectEqualStrings("workbench-nightly", current.desktop_file.?);
    try std.testing.expectEqual(@as(?usize, 4), current.desktopNumber);
    try std.testing.expect(!current.can_close);
}

test "live refresh reapplies search to changed metadata and selects a visible survivor" {
    var g = Self.init(std.testing.allocator);
    defer g.deinit();
    g.setViewport(1000, 800);

    const initial = [_]common.DesktopWindow{
        testDwWithMetadata("window-1", "Project", "project", "editor", "editor", null, 1, true),
        testDwWithMetadata("window-2", "Project chat", "project chat", "chat", "chat", null, 1, true),
    };
    try g.setDesktopWindows(&initial);
    try g.appendSearch("project");
    const chat = g.tileCenter("chat").?;
    _ = g.selectAt(chat.x, chat.y);
    try std.testing.expectEqualStrings("window-2", g.selectedWindowId().?);

    const refreshed = [_]common.DesktopWindow{
        testDwWithMetadata("window-1", "Project", "project", "editor", "editor", null, 1, true),
        testDwWithMetadata("window-2", "Conversation", "conversation", "chat", "chat", null, 2, true),
    };
    try g.refreshDesktopWindows(&refreshed);

    try std.testing.expectEqualStrings("project", g.searchSlice());
    try std.testing.expectEqual(@as(usize, 1), countVisible(g.tiles.items));
    try std.testing.expectEqualStrings("window-1", g.selectedWindowId().?);
}

test "live refresh to an empty snapshot clears tiles and selection without resetting search" {
    var g = Self.init(std.testing.allocator);
    defer g.deinit();
    g.setViewport(1000, 800);

    const initial = [_]common.DesktopWindow{ testDw("alpha"), testDw("beta") };
    try g.setDesktopWindows(&initial);
    try g.appendSearch("a");
    try g.refreshDesktopWindows(&[_]common.DesktopWindow{});

    try std.testing.expectEqual(@as(usize, 0), g.tiles.items.len);
    try std.testing.expect(g.selectedWindow() == null);
    try std.testing.expectEqualStrings("a", g.searchSlice());
}

test "live refresh selects the same visible rank when selected window disappears" {
    var g = Self.init(std.testing.allocator);
    defer g.deinit();
    g.setViewport(1000, 800);

    const initial = [_]common.DesktopWindow{
        testDw("alpha"),
        testDw("beta"),
        testDw("gamma"),
    };
    try g.setDesktopWindows(&initial);
    const beta = g.tileCenter("beta").?;
    _ = g.selectAt(beta.x, beta.y);

    const refreshed = [_]common.DesktopWindow{
        testDw("alpha"),
        testDw("gamma"),
    };
    try g.refreshDesktopWindows(&refreshed);
    try std.testing.expectEqualStrings("gamma", g.selectedWindowId().?);
}

test "live refresh selects a same-app replacement after compact relayout" {
    var g = Self.init(std.testing.allocator);
    defer g.deinit();
    g.setViewport(1000, 800);

    const initial = [_]common.DesktopWindow{
        testDw("alpha"),
        testDwWithMetadata(
            "mac-window:42:7",
            "Notes",
            "notes",
            "Notes",
            "notes",
            null,
            null,
            true,
        ),
        testDw("gamma"),
    };
    try g.setDesktopWindows(&initial);
    const selected_cell = g.tileCenter("Notes").?;
    _ = g.selectAt(selected_cell.x, selected_cell.y);

    const refreshed = [_]common.DesktopWindow{
        testDw("alpha"),
        testDw("gamma"),
        testDwWithMetadata(
            "mac-app:42",
            "Notes",
            "notes",
            "Notes",
            "notes",
            null,
            null,
            false,
        ),
    };
    try g.refreshDesktopWindowsWithOptions(&refreshed, .{
        .select_same_app_replacement = true,
    });

    try std.testing.expectEqualStrings("mac-app:42", g.selectedWindowId().?);
    try std.testing.expectEqual(selected_cell, g.tileCenter("gamma").?);
    const replacement_cell = g.tileCenter("Notes").?;
    try std.testing.expect(selected_cell.x != replacement_cell.x or selected_cell.y != replacement_cell.y);
}

test "live refresh does not select a same-app newcomer by default" {
    var g = Self.init(std.testing.allocator);
    defer g.deinit();
    g.setViewport(1000, 800);

    const initial = [_]common.DesktopWindow{
        testDw("alpha"),
        testDwWithMetadata(
            "old-window",
            "Notes",
            "notes",
            "notes-app",
            "notes-app",
            null,
            null,
            true,
        ),
        testDw("gamma"),
    };
    try g.setDesktopWindows(&initial);
    const selected_cell = g.tileCenter("notes-app").?;
    _ = g.selectAt(selected_cell.x, selected_cell.y);

    const refreshed = [_]common.DesktopWindow{
        testDw("alpha"),
        testDw("gamma"),
        testDwWithMetadata(
            "new-window",
            "Another note",
            "another note",
            "notes-app",
            "notes-app",
            null,
            null,
            true,
        ),
    };
    try g.refreshDesktopWindows(&refreshed);

    // Default selection continuity is by stable id and then visible rank, so
    // the next ranked survivor wins and compacts into the removed tile's cell.
    try std.testing.expectEqualStrings("gamma", g.selectedWindowId().?);
    try std.testing.expectEqual(selected_cell, g.tileCenter("gamma").?);
}

test "same-app replacement continuity does not match empty app identifiers" {
    var g = Self.init(std.testing.allocator);
    defer g.deinit();
    g.setViewport(1000, 800);

    const initial = [_]common.DesktopWindow{
        testDw("alpha"),
        testDwWithMetadata(
            "old-window",
            "Untitled",
            "untitled",
            "",
            "",
            null,
            null,
            true,
        ),
        testDw("gamma"),
    };
    try g.setDesktopWindows(&initial);
    const selected_cell = .{
        .x = g.tiles.items[1].x + @divFloor(TILE_W, 2),
        .y = g.tiles.items[1].y + @divFloor(TILE_H, 2),
    };
    _ = g.selectAt(selected_cell.x, selected_cell.y);

    const refreshed = [_]common.DesktopWindow{
        testDw("alpha"),
        testDw("gamma"),
        testDwWithMetadata(
            "new-window",
            "Other untitled",
            "other untitled",
            "",
            "",
            null,
            null,
            true,
        ),
    };
    try g.refreshDesktopWindowsWithOptions(&refreshed, .{
        .select_same_app_replacement = true,
    });

    try std.testing.expectEqualStrings("gamma", g.selectedWindowId().?);
}

test "live refresh compacts surviving tiles after a removal" {
    var g = Self.init(std.testing.allocator);
    defer g.deinit();
    g.setViewport(1000, 800);

    const initial = [_]common.DesktopWindow{
        testDw("alpha"),
        testDw("beta"),
        testDw("gamma"),
        testDw("delta"),
    };
    try g.setDesktopWindows(&initial);
    const beta_before = g.tileCenter("beta").?;

    const refreshed = [_]common.DesktopWindow{
        testDw("alpha"),
        testDw("gamma"),
        testDw("delta"),
    };
    try g.refreshDesktopWindows(&refreshed);

    try std.testing.expectEqual(beta_before, g.tileCenter("gamma").?);
}

test "tiles pack on-screen and clear of the search box when centered near a corner" {
    var g = Self.init(std.testing.allocator);
    defer g.deinit();
    g.setViewport(1000, 800);

    var dws: [20]common.DesktopWindow = undefined;
    for (&dws) |*d| d.* = testDw("app");
    g.setCenter(20, 20); // near the top-left corner
    try g.setDesktopWindows(&dws);

    const sr = g.searchBoxRect();
    var visible: usize = 0;
    for (g.tiles.items) |t| {
        if (!t.visible) continue;
        visible += 1;
        // Fully on-screen.
        try std.testing.expect(t.x >= 0 and t.y >= 0);
        try std.testing.expect(t.x + TILE_W <= 1000 and t.y + TILE_H <= 800);
        // Clear of the search box's row (full-width band at its height).
        const overlap = t.y < sr.y + sr.h and t.y + TILE_H > sr.y;
        try std.testing.expect(!overlap);
    }
    // 1000x800 has ample room for 20 tiles even packed from a corner.
    try std.testing.expectEqual(@as(usize, 20), visible);
}

test "click near the bottom edge hugs the search box (no wasted row)" {
    var g = Self.init(std.testing.allocator);
    defer g.deinit();
    g.setViewport(1000, 800);

    var dws: [10]common.DesktopWindow = undefined;
    for (&dws) |*d| d.* = testDw("app");
    g.setCenter(500, 790); // bottom edge, horizontally centered
    try g.setDesktopWindows(&dws);

    const sr = g.searchBoxRect();
    var max_bottom: i32 = 0;
    for (g.tiles.items) |t| {
        if (!t.visible) continue;
        max_bottom = @max(max_bottom, t.y + TILE_H);
    }
    // The lowest tile sits right on the search box's top — no wasted row above it.
    try std.testing.expectEqual(sr.y, max_bottom);
}
