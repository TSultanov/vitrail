// Pure software renderer: composites tiles + search box into an ARGB buffer.
const std = @import("std");
const common = @import("../../common/DesktopWindow.zig");
const ColorHash = @import("../../common/ColorHash.zig");
const text = @import("text.zig");
const Grid = @import("Grid.zig");

pub const Theme = struct {
    bg: u32 = 0xCC101018,
    search_bg: u32 = 0xFF1E1E2E,
    search_border: u32 = 0xFF666688,
    search_text: u32 = 0xFFE0E0FF,
    tile_text: u32 = 0xFFFFFFFF,
    select_border: u32 = 0xFFFFFFFF,
};

pub const TILE_TEXT_PAD: i32 = 6;
pub const SEARCH_PAD: i32 = 10;

pub fn render(
    pixels: []u32,
    w: u32,
    h: u32,
    grid: *const Grid,
    tile_text: *text.Renderer,
    search_text: *text.Renderer,
    theme: Theme,
) void {
    fillRect(pixels, w, 0, 0, @intCast(w), @intCast(h), theme.bg);

    for (grid.tiles.items, 0..) |tile, idx| {
        if (!tile.visible) continue;
        const selected = if (grid.selected) |s| s == idx else false;
        const bg: u32 = 0xFF000000 | ColorHash.createColor(tile.dw.app_id, selected);
        fillRect(pixels, w, tile.x, tile.y, Grid.TILE_W, Grid.TILE_H, bg);

        if (selected) {
            drawRect(pixels, w, tile.x, tile.y, Grid.TILE_W, Grid.TILE_H, theme.select_border);
            drawRect(pixels, w, tile.x + 1, tile.y + 1, Grid.TILE_W - 2, Grid.TILE_H - 2, theme.select_border);
        }

        const baseline = tile.y + Grid.TILE_H - TILE_TEXT_PAD;
        const clipped = clipForWidth(tile.dw.title, tile_text, Grid.TILE_W - 2 * TILE_TEXT_PAD);
        _ = tile_text.draw(pixels, w, w, h, tile.x + TILE_TEXT_PAD, baseline, clipped, theme.tile_text) catch 0;
    }

    const sx: i32 = @divFloor(@as(i32, @intCast(w)) - Grid.SEARCH_W, 2);
    const sy: i32 = @as(i32, @intCast(h)) - Grid.SEARCH_H - 8;
    fillRect(pixels, w, sx, sy, Grid.SEARCH_W, Grid.SEARCH_H, theme.search_bg);
    drawRect(pixels, w, sx, sy, Grid.SEARCH_W, Grid.SEARCH_H, theme.search_border);
    const search = grid.searchSlice();
    if (search.len > 0) {
        const baseline = sy + Grid.SEARCH_H - @divFloor(Grid.SEARCH_H - search_text.ascent, 2);
        _ = search_text.draw(pixels, w, w, h, sx + SEARCH_PAD, baseline, search, theme.search_text) catch 0;
    }
    _ = common; // (kept for future per-tile icon support)
}

fn clipForWidth(s: []const u8, r: *text.Renderer, max_w: i32) []const u8 {
    var view = std.unicode.Utf8View.init(s) catch return s[0..0];
    var it = view.iterator();
    var width: i32 = 0;
    var last_end: usize = 0;
    while (it.nextCodepointSlice()) |slice| {
        const adv = r.measure(slice) catch 0;
        if (width + adv > max_w) return s[0..last_end];
        width += adv;
        last_end = it.i;
    }
    return s[0..last_end];
}

pub fn fillRect(pixels: []u32, stride: u32, x: i32, y: i32, rw: i32, rh: i32, color: u32) void {
    if (rw <= 0 or rh <= 0) return;
    const x0 = @max(0, x);
    const y0 = @max(0, y);
    const x1 = @min(@as(i32, @intCast(stride)), x + rw);
    const max_row = @as(i32, @intCast(pixels.len / stride));
    const y1 = @min(max_row, y + rh);
    if (x0 >= x1 or y0 >= y1) return;

    var py: i32 = y0;
    while (py < y1) : (py += 1) {
        const row_off: usize = @as(usize, @intCast(py)) * stride;
        var px: i32 = x0;
        while (px < x1) : (px += 1) {
            pixels[row_off + @as(usize, @intCast(px))] = color;
        }
    }
}

pub fn drawRect(pixels: []u32, stride: u32, x: i32, y: i32, rw: i32, rh: i32, color: u32) void {
    fillRect(pixels, stride, x, y, rw, 1, color);
    fillRect(pixels, stride, x, y + rh - 1, rw, 1, color);
    fillRect(pixels, stride, x, y, 1, rh, color);
    fillRect(pixels, stride, x + rw - 1, y, 1, rh, color);
}
