// CoreText glyph backend for the shared rasterizer in common/text.zig.
// Each codepoint is rendered into an 8-bit alpha bitmap via CTFontDrawGlyphs
// into a CGBitmapContext (kCGImageAlphaOnly); the cache + blit live in
// common/text.zig.

const std = @import("std");
const common_text = @import("../../common/text.zig");

pub const Weight = common_text.Weight;
pub const Clip = common_text.Clip;

const c = @cImport({
    @cInclude("CoreFoundation/CoreFoundation.h");
    @cInclude("CoreGraphics/CoreGraphics.h");
    @cInclude("CoreText/CoreText.h");
});

const Backend = struct {
    font: c.CTFontRef,
    ascent: i32,

    pub fn init(_: std.mem.Allocator, pixel_size: u32, weight: Weight) !Backend {
        const size_f: c.CGFloat = @floatFromInt(pixel_size);
        const ui_kind: c.CTFontUIFontType = switch (weight) {
            .regular => c.kCTFontUIFontSystem,
            .bold => c.kCTFontUIFontEmphasizedSystem,
        };
        const font = c.CTFontCreateUIFontForLanguage(ui_kind, size_f, null) orelse
            return error.FontLoad;
        const ascent_f = c.CTFontGetAscent(font);
        return .{
            .font = font,
            .ascent = @intFromFloat(@ceil(ascent_f)),
        };
    }

    pub fn deinit(self: *Backend) void {
        c.CFRelease(self.font);
    }

    pub fn loadGlyph(self: *Backend, allocator: std.mem.Allocator, codepoint: u32) !common_text.Glyph {
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

        const pixels = try allocator.alloc(u8, @max(@as(usize, 1), width * rows));
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

        return .{
            .pixels = pixels,
            .width = width,
            .rows = rows,
            .bearing_x = left,
            .bearing_y = top,
            .advance_x = @intFromFloat(@round(advance.width)),
        };
    }
};

pub const Renderer = common_text.Renderer(Backend);
