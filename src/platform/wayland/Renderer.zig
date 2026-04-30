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
const Grid = @import("../../common/Grid.zig");

pub const Theme = struct {
    transparent: u32 = 0x00000000,
    tile_border: u32 = 0xFF000000,
    search_bg: u32 = 0xFFFFFFFF,
    search_border: u32 = 0xFF808080,
    search_text: u32 = 0xFF000000,
};

pub const TILE_TEXT_PAD: i32 = 5;
// Icon margins mirror the Windows Tile.drawIcon layout (Tile.zig:147-150):
// the icon fills as large as possible inside an inset rect, then is
// centered within that rect.
pub const TILE_ICON_MARGIN_TOP: i32 = 20;
pub const TILE_ICON_MARGIN_SIDE: i32 = 14;
pub const TILE_ICON_MARGIN_BOT: i32 = 32;
pub const SEARCH_PAD: i32 = 4;

pub fn render(
    pixels: []u32,
    pw: u32,
    ph: u32,
    scale_q120: u32,
    grid: *const Grid,
    tile_text: anytype,
    search_text: anytype,
    desktop_text: anytype,
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
    const step_x: i32 = Grid.TILE_W + Grid.TILE_MARGIN;
    const step_y: i32 = Grid.TILE_H + Grid.TILE_MARGIN;

    // Pass 1: tile fills + content (icons, title, desktop badge). Drawn first
    // so that adjacent tiles painted in spiral order can freely overlap into
    // each other's edge columns — the borders go on top in pass 2.
    for (grid.tiles.items, 0..) |tile, idx| {
        if (!tile.visible) continue;
        const selected = if (grid.selected) |s| s == idx else false;

        const tx = S.s(tile.x);
        const ty = S.s(tile.y);

        const fill: u32 = 0xFF000000 | ColorHash.createColor(tile.dw.app_id, selected);
        fillRect(pixels, pw, tx, ty, tile_w, tile_h, fill);

        // Application icon: square, centered inside the same inset rect the
        // Windows Tile uses (margins above/below/sides). Size is the largest
        // square that fits the inset.
        if (tile.dw.icon) |ic| {
            const m_top = S.s(TILE_ICON_MARGIN_TOP);
            const m_side = S.s(TILE_ICON_MARGIN_SIDE);
            const m_bot = S.s(TILE_ICON_MARGIN_BOT);
            const inner_w = tile_w - 2 * m_side;
            const inner_h = tile_h - m_top - m_bot;
            if (inner_w > 0 and inner_h > 0) {
                const icon_size = @min(inner_w, inner_h);
                const icon_x = tx + m_side + @divFloor(inner_w - icon_size, 2);
                const icon_y = ty + m_top + @divFloor(inner_h - icon_size, 2);
                blitRgba(pixels, pw, ph, icon_x, icon_y, icon_size, icon_size, &ic);
            }
        }

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

    // Pass 2: 1px borders anchored at logical column/row boundaries. Each
    // tile owns the seams to its right and bottom — they live at the
    // physical pixel that maps to the logical x + step_x / y + step_y, so
    // they line up with whatever sits in the next column/row regardless of
    // floor() rounding. Left and top edges are painted only when no
    // neighbor exists on that side (otherwise the neighbor's right/bottom
    // border already covers the same physical line). Lengths run all the
    // way to the corner pixel so adjacent borders meet cleanly when four
    // tiles share a corner — and outer L-corners stay continuous.
    for (grid.tiles.items) |tile| {
        if (!tile.visible) continue;
        const tx = S.s(tile.x);
        const ty = S.s(tile.y);
        const tx_end = S.s(tile.x + step_x);
        const ty_end = S.s(tile.y + step_y);
        const span_w = tx_end - tx + 1;
        const span_h = ty_end - ty + 1;

        fillRect(pixels, pw, tx_end, ty, 1, span_h, theme.tile_border);
        fillRect(pixels, pw, tx, ty_end, span_w, 1, theme.tile_border);
        if (!hasVisibleNeighbor(grid, tile, -step_x, 0))
            fillRect(pixels, pw, tx, ty, 1, span_h, theme.tile_border);
        if (!hasVisibleNeighbor(grid, tile, 0, -step_y))
            fillRect(pixels, pw, tx, ty, span_w, 1, theme.tile_border);
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
}

fn hasVisibleNeighbor(grid: *const Grid, tile: Grid.Tile, dx: i32, dy: i32) bool {
    const nx = tile.x + dx;
    const ny = tile.y + dy;
    for (grid.tiles.items) |o| {
        if (!o.visible) continue;
        if (o.x == nx and o.y == ny) return true;
    }
    return false;
}

fn clipForWidth(s: []const u8, r: anytype, max_w: i32) []const u8 {
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

/// Nearest-neighbour scale + alpha-over of an RGBA8 source onto the BGRA(8888)
/// pixel buffer. Source is straight-alpha (un-premultiplied). Destination
/// pixels are 0xAARRGGBB on little-endian (matching the rest of Renderer).
fn blitRgba(pixels: []u32, stride: u32, ph: u32, x: i32, y: i32, dst_w: i32, dst_h: i32, src: *const common.RgbaIcon) void {
    if (dst_w <= 0 or dst_h <= 0) return;
    if (src.width == 0 or src.height == 0) return;

    const max_row = @as(i32, @intCast(ph));
    const x0 = @max(0, x);
    const y0 = @max(0, y);
    const x1 = @min(@as(i32, @intCast(stride)), x + dst_w);
    const y1 = @min(max_row, y + dst_h);
    if (x0 >= x1 or y0 >= y1) return;

    var py: i32 = y0;
    while (py < y1) : (py += 1) {
        const dy = py - y; // 0..dst_h
        const sy_u: u64 = (@as(u64, @intCast(dy)) * src.height) / @as(u64, @intCast(dst_h));
        const row_off: usize = @as(usize, @intCast(py)) * stride;
        const src_row_off: usize = @as(usize, @intCast(sy_u)) * src.width * 4;
        var px: i32 = x0;
        while (px < x1) : (px += 1) {
            const dx = px - x;
            const sx_u: u64 = (@as(u64, @intCast(dx)) * src.width) / @as(u64, @intCast(dst_w));
            const sp = src_row_off + @as(usize, @intCast(sx_u)) * 4;
            const sr: u32 = src.pixels[sp + 0];
            const sg: u32 = src.pixels[sp + 1];
            const sb: u32 = src.pixels[sp + 2];
            const sa: u32 = src.pixels[sp + 3];
            if (sa == 0) continue;
            const dst_idx = row_off + @as(usize, @intCast(px));
            if (sa == 255) {
                pixels[dst_idx] = 0xFF000000 | (sr << 16) | (sg << 8) | sb;
                continue;
            }
            const dst = pixels[dst_idx];
            const dr: u32 = (dst >> 16) & 0xFF;
            const dg: u32 = (dst >> 8) & 0xFF;
            const db: u32 = dst & 0xFF;
            const inv: u32 = 255 - sa;
            const r = (sr * sa + dr * inv + 127) / 255;
            const g = (sg * sa + dg * inv + 127) / 255;
            const b = (sb * sa + db * inv + 127) / 255;
            pixels[dst_idx] = 0xFF000000 | (r << 16) | (g << 8) | b;
        }
    }
}

pub fn drawRect(pixels: []u32, stride: u32, x: i32, y: i32, rw: i32, rh: i32, color: u32) void {
    fillRect(pixels, stride, x, y, rw, 1, color);
    fillRect(pixels, stride, x, y + rh - 1, rw, 1, color);
    fillRect(pixels, stride, x, y, 1, rh, color);
    fillRect(pixels, stride, x + rw - 1, y, 1, rh, color);
}
