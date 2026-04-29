// Pure software renderer matching the Windows look.
// - Background is transparent (alpha=0); only tile rects + search box are opaque.
//   This mirrors the Windows app's effective transparency via SetWindowRgn.
// - Each tile: 1px opaque-black outer border, then a colored fill inset by 1px
//   (ColorHash.createColor(app_id, selected)).
// - Title: white when selected, black when not — same flip the Windows Tile uses.
// - Desktop number badge: top-right, bold, color flipped from title.
// - Search box: white fill, 1px gray border, black text — Win32 EDIT default look.
const std = @import("std");
const common = @import("../../common/DesktopWindow.zig");
const ColorHash = @import("../../common/ColorHash.zig");
const text = @import("text.zig");
const Grid = @import("Grid.zig");

pub const Theme = struct {
    transparent: u32 = 0x00000000,
    tile_border: u32 = 0xFF000000,
    search_bg: u32 = 0xFFFFFFFF,
    search_border: u32 = 0xFF808080,
    search_text: u32 = 0xFF000000,
};

pub const TILE_TEXT_PAD: i32 = 5;
pub const SEARCH_PAD: i32 = 4;

pub fn render(
    pixels: []u32,
    pw: u32,
    ph: u32,
    scale_q120: u32,
    grid: *const Grid,
    tile_text: *text.Renderer,
    search_text: *text.Renderer,
    desktop_text: *text.Renderer,
    theme: Theme,
) void {
    // Convert a logical-pixel coordinate or length to physical pixels using
    // the surface's fractional scale (Wayland units of 1/120).
    const S = struct {
        q: u32,
        fn s(self: @This(), v: i32) i32 {
            return @divFloor(v * @as(i32, @intCast(self.q)), 120);
        }
    }{ .q = scale_q120 };

    // Fill viewport with transparent pixels — outside tiles + search the
    // compositor's desktop shows through.
    fillRect(pixels, pw, 0, 0, @intCast(pw), @intCast(ph), theme.transparent);

    const tile_w = S.s(Grid.TILE_W);
    const tile_h = S.s(Grid.TILE_H);
    const tile_pad = S.s(TILE_TEXT_PAD);

    for (grid.tiles.items, 0..) |tile, idx| {
        if (!tile.visible) continue;
        const selected = if (grid.selected) |s| s == idx else false;

        const tx = S.s(tile.x);
        const ty = S.s(tile.y);

        // 1px opaque-black border, then colored fill inset by 1px.
        fillRect(pixels, pw, tx, ty, tile_w, tile_h, theme.tile_border);
        const fill: u32 = 0xFF000000 | ColorHash.createColor(tile.dw.app_id, selected);
        fillRect(pixels, pw, tx + 1, ty + 1, tile_w - 2, tile_h - 2, fill);

        const title_color: u32 = if (selected) 0xFFFFFFFF else 0xFF000000;
        const desktop_color: u32 = if (selected) 0xFF000000 else 0xFFFFFFFF;

        // Title: bottom-center.
        const title_baseline = ty + tile_h - tile_pad;
        const max_w = tile_w - 2 * tile_pad;
        const clipped = clipForWidth(tile.dw.title, tile_text, max_w);
        const title_w = tile_text.measure(clipped) catch 0;
        const title_x = tx + @divFloor(tile_w - title_w, 2);
        _ = tile_text.draw(pixels, pw, pw, ph, title_x, title_baseline, clipped, title_color) catch 0;

        // Desktop number: top-right corner.
        var buf: [16]u8 = undefined;
        const desktop_str: []const u8 = if (tile.dw.desktopNumber) |n|
            std.fmt.bufPrint(&buf, "{d}", .{n + 1}) catch ""
        else
            "";
        const dn_w = desktop_text.measure(desktop_str) catch 0;
        const dn_x = tx + tile_w - tile_pad - dn_w;
        const dn_baseline = ty + desktop_text.ascent + S.s(2);
        _ = desktop_text.draw(pixels, pw, pw, ph, dn_x, dn_baseline, desktop_str, desktop_color) catch 0;
    }

    // Search box — white fill, gray border, black text.
    const search_w = S.s(Grid.SEARCH_W);
    const search_h = S.s(Grid.SEARCH_H);
    const search_pad = S.s(SEARCH_PAD);
    const sx: i32 = @divFloor(@as(i32, @intCast(pw)) - search_w, 2);
    const sy: i32 = @as(i32, @intCast(ph)) - S.s(Grid.SEARCH_BOTTOM_OFFSET);
    fillRect(pixels, pw, sx, sy, search_w, search_h, theme.search_bg);
    drawRect(pixels, pw, sx, sy, search_w, search_h, theme.search_border);
    const search = grid.searchSlice();
    if (search.len > 0) {
        const baseline = sy + search_h - @divFloor(search_h - search_text.ascent, 2);
        _ = search_text.draw(pixels, pw, pw, ph, sx + search_pad, baseline, search, theme.search_text) catch 0;
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
