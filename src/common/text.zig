// Platform-agnostic glyph cache + UTF-8 rasterizer. Each platform supplies a
// `Backend` that knows how to load the OS font and rasterize a single
// codepoint into an 8-bit alpha bitmap; everything else (caching, text
// shaping, alpha-over blending into an ARGB framebuffer) lives here once.

const std = @import("std");

pub const Weight = enum { regular, bold };

/// Half-open pixel rect the rasterizer clips against. The caller passes its
/// framebuffer extents (or a tighter region — the search box uses its
/// interior to keep glyphs from overdrawing the border / surrounding alpha).
pub const Clip = struct { x0: i32, y0: i32, x1: i32, y1: i32 };

pub const Glyph = struct {
    /// 8-bit alpha bitmap, top-down row-major, stride == width. Owned by the
    /// cache (allocated via the allocator passed to `Backend.loadGlyph`).
    pixels: []u8,
    width: u32,
    rows: u32,
    /// Pen-to-glyph-left in pixels.
    bearing_x: i32,
    /// Pen-to-glyph-top, measured upward (y grows downward in the framebuffer).
    bearing_y: i32,
    advance_x: i32,
};

/// Backend contract (duck-typed):
///   pub fn init(allocator: std.mem.Allocator, pixel_size: u32, weight: Weight) !Backend
///   pub fn deinit(self: *Backend) void
///   pub fn loadGlyph(self: *Backend, allocator: std.mem.Allocator, codepoint: u32) !Glyph
///   ascent: i32  (field on Backend)
pub fn Renderer(comptime Backend: type) type {
    return struct {
        allocator: std.mem.Allocator,
        backend: Backend,
        ascent: i32,
        cache: std.AutoHashMap(u32, Glyph),

        const Self = @This();

        pub fn create(allocator: std.mem.Allocator, pixel_size: u32, weight: Weight) !Self {
            const backend = try Backend.init(allocator, pixel_size, weight);
            return .{
                .allocator = allocator,
                .backend = backend,
                .ascent = backend.ascent,
                .cache = std.AutoHashMap(u32, Glyph).init(allocator),
            };
        }

        pub fn destroy(self: *Self) void {
            var it = self.cache.valueIterator();
            while (it.next()) |g| self.allocator.free(g.pixels);
            self.cache.deinit();
            self.backend.deinit();
        }

        fn cachedGlyph(self: *Self, codepoint: u32) !*const Glyph {
            if (self.cache.getPtr(codepoint)) |g| return g;
            const glyph = try self.backend.loadGlyph(self.allocator, codepoint);
            errdefer self.allocator.free(glyph.pixels);
            try self.cache.put(codepoint, glyph);
            return self.cache.getPtr(codepoint).?;
        }

        /// Width of `text` in pixels, without rendering.
        pub fn measure(self: *Self, text: []const u8) !i32 {
            var w: i32 = 0;
            var view = std.unicode.Utf8View.init(text) catch return 0;
            var it = view.iterator();
            while (it.nextCodepoint()) |cp| {
                const g = self.cachedGlyph(cp) catch continue;
                w += g.advance_x;
            }
            return w;
        }

        /// Render UTF-8 `text` into `pixels` (ARGB8888, `stride` u32s per row).
        /// (x, y) is the baseline-left position. Pixels outside `clip` are
        /// skipped — pass framebuffer extents for an unclipped draw, or a
        /// tighter rect when the destination must not be overdrawn (e.g. the
        /// search box interior). `color` is 0xAARRGGBB (alpha is masked).
        /// Returns the pen x position after the last glyph.
        pub fn draw(self: *Self, pixels: []u32, stride: u32, x: i32, y: i32, text: []const u8, color: u32, clip: Clip) !i32 {
            var pen_x: i32 = x;
            var view = std.unicode.Utf8View.init(text) catch return pen_x;
            var it = view.iterator();
            while (it.nextCodepoint()) |cp| {
                const g = self.cachedGlyph(cp) catch continue;
                blitGlyph(pixels, stride, pen_x + g.bearing_x, y - g.bearing_y, g, color, clip);
                pen_x += g.advance_x;
            }
            return pen_x;
        }
    };
}

fn blitGlyph(pixels: []u32, stride: u32, x: i32, y: i32, g: *const Glyph, color: u32, clip: Clip) void {
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
