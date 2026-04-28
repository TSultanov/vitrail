const std = @import("std");

const c = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("fontconfig/fontconfig.h");
});

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    library: c.FT_Library,
    face: c.FT_Face,
    pixel_size: u32,
    line_height: i32,
    ascent: i32,
    cache: std.AutoHashMap(u32, Glyph),

    const Glyph = struct {
        // Grayscale alpha bitmap, owned.
        pixels: []u8,
        width: u32,
        rows: u32,
        // Pen offsets in pixels (FreeType bitmap_left/top).
        bearing_x: i32,
        bearing_y: i32,
        advance_x: i32,
    };

    pub fn create(allocator: std.mem.Allocator, pixel_size: u32) !Renderer {
        var library: c.FT_Library = undefined;
        if (c.FT_Init_FreeType(&library) != 0) return error.FreeTypeInit;
        errdefer _ = c.FT_Done_FreeType(library);

        const font_path = try resolveFont(allocator);
        defer allocator.free(font_path);

        var face: c.FT_Face = undefined;
        if (c.FT_New_Face(library, font_path.ptr, 0, &face) != 0) return error.FontLoad;
        errdefer _ = c.FT_Done_Face(face);

        if (c.FT_Set_Pixel_Sizes(face, 0, pixel_size) != 0) return error.SetSize;

        // metrics->ascender / descender are in 26.6 fixed point.
        const ascent: i32 = @intCast(@divTrunc(face.*.size.*.metrics.ascender, 64));
        const descent: i32 = @intCast(@divTrunc(face.*.size.*.metrics.descender, 64));

        return .{
            .allocator = allocator,
            .library = library,
            .face = face,
            .pixel_size = pixel_size,
            .ascent = ascent,
            .line_height = ascent - descent,
            .cache = std.AutoHashMap(u32, Glyph).init(allocator),
        };
    }

    pub fn destroy(self: *Renderer) void {
        var it = self.cache.valueIterator();
        while (it.next()) |g| self.allocator.free(g.pixels);
        self.cache.deinit();
        _ = c.FT_Done_Face(self.face);
        _ = c.FT_Done_FreeType(self.library);
    }

    fn loadGlyph(self: *Renderer, codepoint: u32) !*Glyph {
        if (self.cache.getPtr(codepoint)) |g| return g;

        if (c.FT_Load_Char(self.face, codepoint, c.FT_LOAD_RENDER) != 0) return error.LoadChar;
        const slot = self.face.*.glyph;
        const bm = slot.*.bitmap;

        const pixels = try self.allocator.alloc(u8, bm.width * bm.rows);
        // FreeType rows may have negative pitch (top-down). Copy row by row to normalize.
        const pitch_abs: usize = @intCast(@abs(bm.pitch));
        if (bm.pitch >= 0) {
            for (0..bm.rows) |row| {
                const src = bm.buffer[row * pitch_abs ..][0..bm.width];
                @memcpy(pixels[row * bm.width ..][0..bm.width], src);
            }
        } else {
            for (0..bm.rows) |row| {
                const src_row = bm.rows - 1 - row;
                const src = bm.buffer[src_row * pitch_abs ..][0..bm.width];
                @memcpy(pixels[row * bm.width ..][0..bm.width], src);
            }
        }

        const glyph = Glyph{
            .pixels = pixels,
            .width = bm.width,
            .rows = bm.rows,
            .bearing_x = slot.*.bitmap_left,
            .bearing_y = slot.*.bitmap_top,
            .advance_x = @intCast(@divTrunc(slot.*.advance.x, 64)),
        };
        try self.cache.put(codepoint, glyph);
        return self.cache.getPtr(codepoint).?;
    }

    /// Render UTF-8 `text` into `pixels` (ARGB8888, `stride` u32s per row, `pw` × `ph` viewport).
    /// (x, y) is the baseline-left position. `color` is 0xAARRGGBB (alpha is masked).
    /// Returns the pen x position after the last glyph.
    pub fn draw(self: *Renderer, pixels: []u32, stride: u32, pw: u32, ph: u32, x: i32, y: i32, text: []const u8, color: u32) !i32 {
        var pen_x: i32 = x;
        var view = std.unicode.Utf8View.init(text) catch return pen_x;
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            const g = self.loadGlyph(cp) catch continue;
            blitGlyph(pixels, stride, pw, ph, pen_x + g.bearing_x, y - g.bearing_y, g, color);
            pen_x += g.advance_x;
        }
        return pen_x;
    }

    /// Width of `text` in pixels, without rendering.
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

fn blitGlyph(pixels: []u32, stride: u32, pw: u32, ph: u32, x: i32, y: i32, g: *const Renderer.Glyph, color: u32) void {
    const r: u32 = (color >> 16) & 0xFF;
    const gg: u32 = (color >> 8) & 0xFF;
    const b: u32 = color & 0xFF;

    var row: u32 = 0;
    while (row < g.rows) : (row += 1) {
        const py = y + @as(i32, @intCast(row));
        if (py < 0 or py >= @as(i32, @intCast(ph))) continue;
        var col: u32 = 0;
        while (col < g.width) : (col += 1) {
            const px = x + @as(i32, @intCast(col));
            if (px < 0 or px >= @as(i32, @intCast(pw))) continue;
            const alpha: u32 = g.pixels[row * g.width + col];
            if (alpha == 0) continue;

            const idx: usize = @as(usize, @intCast(py)) * stride + @as(usize, @intCast(px));
            const dst = pixels[idx];

            const dr = (dst >> 16) & 0xFF;
            const dg = (dst >> 8) & 0xFF;
            const db = dst & 0xFF;
            const da = (dst >> 24) & 0xFF;

            // Source-over blend with premultiplied glyph alpha.
            const inv: u32 = 255 - alpha;
            const out_r = (r * alpha + dr * inv) / 255;
            const out_g = (gg * alpha + dg * inv) / 255;
            const out_b = (b * alpha + db * inv) / 255;
            const out_a = @min(255, da + alpha);

            pixels[idx] = (@as(u32, @intCast(out_a)) << 24) | (@as(u32, @intCast(out_r)) << 16) | (@as(u32, @intCast(out_g)) << 8) | @as(u32, @intCast(out_b));
        }
    }
}

fn resolveFont(allocator: std.mem.Allocator) ![:0]u8 {
    if (c.FcInit() == 0) return error.FontconfigInit;

    const pattern = c.FcNameParse("sans-serif") orelse return error.FontconfigPattern;
    defer c.FcPatternDestroy(pattern);

    _ = c.FcConfigSubstitute(null, pattern, c.FcMatchPattern);
    c.FcDefaultSubstitute(pattern);

    var result: c.FcResult = undefined;
    const matched = c.FcFontMatch(null, pattern, &result) orelse return error.FontconfigNoMatch;
    defer c.FcPatternDestroy(matched);

    var file: [*c]c.FcChar8 = undefined;
    if (c.FcPatternGetString(matched, c.FC_FILE, 0, &file) != c.FcResultMatch) return error.FontconfigNoFile;

    const path = std.mem.span(@as([*:0]const u8, @ptrCast(file)));
    return try allocator.dupeZ(u8, path);
}
