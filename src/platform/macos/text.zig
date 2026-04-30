// CoreText-backed glyph cache + rasterizer. Same API surface as
// platform/wayland/text.zig — we render each codepoint once into an 8-bit
// alpha bitmap via CTFontDrawGlyphs into a CGBitmapContext (kCGImageAlphaOnly),
// cache the bitmap, then alpha-blend it onto the destination ARGB buffer.

const std = @import("std");

const c = @cImport({
    @cInclude("CoreFoundation/CoreFoundation.h");
    @cInclude("CoreGraphics/CoreGraphics.h");
    @cInclude("CoreText/CoreText.h");
});

pub const Weight = enum { regular, bold };

/// Half-open pixel rect the rasterizer clips against. The caller passes its
/// framebuffer extents (or a tighter region — the search box uses its
/// interior to keep glyphs from overdrawing the border / surrounding alpha).
pub const Clip = struct { x0: i32, y0: i32, x1: i32, y1: i32 };

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    font: c.CTFontRef,
    pixel_size: u32,
    line_height: i32,
    ascent: i32,
    cache: std.AutoHashMap(u32, Glyph),

    const Glyph = struct {
        pixels: []u8, // 8-bit alpha, row-major top-down
        width: u32,
        rows: u32,
        bearing_x: i32,
        bearing_y: i32,
        advance_x: i32,
    };

    pub fn create(allocator: std.mem.Allocator, pixel_size: u32, weight: Weight) !Renderer {
        const size_f: c.CGFloat = @floatFromInt(pixel_size);
        const ui_kind: c.CTFontUIFontType = switch (weight) {
            .regular => c.kCTFontUIFontSystem,
            .bold => c.kCTFontUIFontEmphasizedSystem,
        };
        const font = c.CTFontCreateUIFontForLanguage(ui_kind, size_f, null) orelse
            return error.FontLoad;
        errdefer c.CFRelease(font);

        const ascent_f = c.CTFontGetAscent(font);
        const descent_f = c.CTFontGetDescent(font);
        const leading_f = c.CTFontGetLeading(font);

        const ascent: i32 = @intFromFloat(@ceil(ascent_f));
        const descent: i32 = @intFromFloat(@ceil(descent_f));
        const leading: i32 = @intFromFloat(@ceil(leading_f));

        return .{
            .allocator = allocator,
            .font = font,
            .pixel_size = pixel_size,
            .ascent = ascent,
            .line_height = ascent + descent + leading,
            .cache = std.AutoHashMap(u32, Glyph).init(allocator),
        };
    }

    pub fn destroy(self: *Renderer) void {
        var it = self.cache.valueIterator();
        while (it.next()) |g| self.allocator.free(g.pixels);
        self.cache.deinit();
        c.CFRelease(self.font);
    }

    fn loadGlyph(self: *Renderer, codepoint: u32) !*Glyph {
        if (self.cache.getPtr(codepoint)) |g| return g;

        // UTF-16 encode the codepoint into 1 or 2 code units for CT lookup.
        var units: [2]c.UniChar = undefined;
        var unit_count: c.CFIndex = 0;
        if (codepoint <= 0xFFFF) {
            units[0] = @intCast(codepoint);
            unit_count = 1;
        } else {
            const cp = codepoint - 0x10000;
            units[0] = @intCast(0xD800 + (cp >> 10));
            units[1] = @intCast(0xDC00 + (cp & 0x3FF));
            unit_count = 2;
        }

        var glyphs: [2]c.CGGlyph = .{ 0, 0 };
        if (!c.CTFontGetGlyphsForCharacters(self.font, &units, &glyphs, unit_count))
            return error.LoadChar;
        const glyph = glyphs[0];

        // Glyph metrics: advance + bounding box (in points, integer-rounded).
        var advance: c.CGSize = .{ .width = 0, .height = 0 };
        _ = c.CTFontGetAdvancesForGlyphs(self.font, c.kCTFontOrientationDefault, &glyph, &advance, 1);

        var bbox: c.CGRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };
        _ = c.CTFontGetBoundingRectsForGlyphs(self.font, c.kCTFontOrientationDefault, &glyph, &bbox, 1);

        // Pixel-aligned glyph cell. Add a 1px margin so antialiased edges
        // aren't clipped by ceil() rounding.
        const left: i32 = @as(i32, @intFromFloat(@floor(bbox.origin.x))) - 1;
        const bottom: i32 = @as(i32, @intFromFloat(@floor(bbox.origin.y))) - 1;
        const right: i32 = @as(i32, @intFromFloat(@ceil(bbox.origin.x + bbox.size.width))) + 1;
        const top: i32 = @as(i32, @intFromFloat(@ceil(bbox.origin.y + bbox.size.height))) + 1;

        const w_i = right - left;
        const h_i = top - bottom;
        const width: u32 = if (w_i > 0) @intCast(w_i) else 0;
        const rows: u32 = if (h_i > 0) @intCast(h_i) else 0;

        const pixels = try self.allocator.alloc(u8, @max(@as(usize, 1), width * rows));
        @memset(pixels, 0);

        if (width > 0 and rows > 0) {
            const ctx = c.CGBitmapContextCreate(
                pixels.ptr,
                width,
                rows,
                8,
                width,
                null, // alpha-only, no color space
                c.kCGImageAlphaOnly,
            );
            if (ctx) |bmp| {
                defer c.CGContextRelease(bmp);
                c.CGContextSetShouldAntialias(bmp, true);
                c.CGContextSetShouldSmoothFonts(bmp, true);
                const pos: c.CGPoint = .{
                    .x = -@as(c.CGFloat, @floatFromInt(left)),
                    .y = -@as(c.CGFloat, @floatFromInt(bottom)),
                };
                c.CTFontDrawGlyphs(self.font, &glyph, &pos, 1, bmp);
            }
        }

        const g = Glyph{
            .pixels = pixels,
            .width = width,
            .rows = rows,
            // bearing_x: pen-to-glyph-left in pixels.
            .bearing_x = left,
            // bearing_y: pen-to-glyph-top, measured upward (y grows downward
            // in our framebuffer; matches the FreeType bitmap_top semantics).
            .bearing_y = top,
            .advance_x = @intFromFloat(@round(advance.width)),
        };
        try self.cache.put(codepoint, g);
        return self.cache.getPtr(codepoint).?;
    }

    pub fn draw(
        self: *Renderer,
        pixels: []u32,
        stride: u32,
        x: i32,
        y: i32,
        text: []const u8,
        color: u32,
        clip: Clip,
    ) !i32 {
        var pen_x: i32 = x;
        var view = std.unicode.Utf8View.init(text) catch return pen_x;
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            const g = self.loadGlyph(cp) catch continue;
            blitGlyph(pixels, stride, pen_x + g.bearing_x, y - g.bearing_y, g, color, clip);
            pen_x += g.advance_x;
        }
        return pen_x;
    }

    pub fn measure(self: *Renderer, text: []const u8) !i32 {
        var w: i32 = 0;
        var view = std.unicode.Utf8View.init(text) catch return 0;
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            const g = self.loadGlyph(cp) catch continue;
            w += g.advance_x;
        }
        return w;
    }
};

fn blitGlyph(pixels: []u32, stride: u32, x: i32, y: i32, g: *const Renderer.Glyph, color: u32, clip: Clip) void {
    const r: u32 = (color >> 16) & 0xFF;
    const gg: u32 = (color >> 8) & 0xFF;
    const b: u32 = color & 0xFF;

    var row: u32 = 0;
    while (row < g.rows) : (row += 1) {
        const py = y + @as(i32, @intCast(row));
        if (py < clip.y0 or py >= clip.y1) continue;
        var col: u32 = 0;
        while (col < g.width) : (col += 1) {
            const px = x + @as(i32, @intCast(col));
            if (px < clip.x0 or px >= clip.x1) continue;
            const alpha: u32 = g.pixels[row * g.width + col];
            if (alpha == 0) continue;

            const idx: usize = @as(usize, @intCast(py)) * stride + @as(usize, @intCast(px));
            const dst = pixels[idx];
            const dr = (dst >> 16) & 0xFF;
            const dg = (dst >> 8) & 0xFF;
            const db = dst & 0xFF;
            const da = (dst >> 24) & 0xFF;

            const inv: u32 = 255 - alpha;
            const out_r: u32 = (r * alpha + dr * inv) / 255;
            const out_g: u32 = (gg * alpha + dg * inv) / 255;
            const out_b: u32 = (b * alpha + db * inv) / 255;
            const out_a: u32 = @min(@as(u32, 255), da + alpha);

            pixels[idx] = (out_a << 24) | (out_r << 16) | (out_g << 8) | out_b;
        }
    }
}
