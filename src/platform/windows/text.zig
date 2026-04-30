// GDI glyph backend for the shared rasterizer in common/text.zig.
// One memory DC owns a "Segoe UI" HFONT for the lifetime of the backend;
// each codepoint is rasterized via GetGlyphOutlineW(GGO_GRAY8_BITMAP) into
// an 8-bit alpha bitmap. The cache + blit live in common/text.zig.

const std = @import("std");
const wh = @import("windows.zig");
const w = wh.c;
const common_text = @import("../../common/text.zig");

pub const Weight = common_text.Weight;
pub const Clip = common_text.Clip;

const Backend = struct {
    hdc: w.HDC,
    hfont: w.HFONT,
    old_font: w.HGDIOBJ,
    ascent: i32,

    pub fn init(_: std.mem.Allocator, pixel_size: u32, weight: Weight) !Backend {
        const segoe_ui = std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI");
        const fw: c_int = if (weight == .bold) w.FW_BOLD else w.FW_NORMAL;
        // Negative cHeight = "size in pixels" (per MSDN). Matches the
        // pixel_size contract used by the macOS/Wayland backends.
        const hfont: w.HFONT = @ptrCast(w.CreateFontW(
            -@as(i32, @intCast(pixel_size)),
            0,
            0,
            0,
            fw,
            0,
            0,
            0,
            w.DEFAULT_CHARSET,
            w.OUT_TT_PRECIS,
            w.CLIP_DEFAULT_PRECIS,
            w.CLEARTYPE_QUALITY,
            w.DEFAULT_PITCH | w.FF_DONTCARE,
            segoe_ui,
        ));
        if (@intFromPtr(hfont) == 0) return error.FontLoad;
        errdefer _ = w.DeleteObject(hfont);

        const hdc = w.CreateCompatibleDC(null);
        if (@intFromPtr(hdc) == 0) return error.HdcCreate;
        errdefer _ = w.DeleteDC(hdc);

        const old_font = w.SelectObject(hdc, hfont);

        var tm: w.TEXTMETRICW = undefined;
        if (w.GetTextMetricsW(hdc, &tm) == 0) return error.GetMetrics;

        return .{
            .hdc = hdc,
            .hfont = hfont,
            .old_font = old_font,
            .ascent = tm.tmAscent,
        };
    }

    pub fn deinit(self: *Backend) void {
        _ = w.SelectObject(self.hdc, self.old_font);
        _ = w.DeleteObject(self.hfont);
        _ = w.DeleteDC(self.hdc);
    }

    pub fn loadGlyph(self: *Backend, allocator: std.mem.Allocator, codepoint: u32) !common_text.Glyph {
        // GetGlyphOutlineW takes a UTF-16 code unit. Drop supplementary-plane
        // codepoints; the search box / window titles in this app are BMP only.
        if (codepoint > 0xFFFF) return error.LoadChar;

        const mat = w.MAT2{
            .eM11 = .{ .fract = 0, .value = 1 },
            .eM12 = .{ .fract = 0, .value = 0 },
            .eM21 = .{ .fract = 0, .value = 0 },
            .eM22 = .{ .fract = 0, .value = 1 },
        };

        var gm: w.GLYPHMETRICS = undefined;
        const size = w.GetGlyphOutlineW(self.hdc, @intCast(codepoint), w.GGO_GRAY8_BITMAP, &gm, 0, null, &mat);
        if (size == w.GDI_ERROR) return error.LoadChar;

        const black_w: u32 = gm.gmBlackBoxX;
        const black_h: u32 = gm.gmBlackBoxY;

        const pixels = try allocator.alloc(u8, @max(@as(usize, 1), black_w * black_h));
        errdefer allocator.free(pixels);
        @memset(pixels, 0);

        if (size > 0 and black_w > 0 and black_h > 0) {
            // GDI bitmap rows are DWORD-aligned; size from the metrics call
            // already accounts for that padding.
            const src_buf = try allocator.alloc(u8, size);
            defer allocator.free(src_buf);

            const written = w.GetGlyphOutlineW(self.hdc, @intCast(codepoint), w.GGO_GRAY8_BITMAP, &gm, size, src_buf.ptr, &mat);
            if (written == w.GDI_ERROR) return error.LoadChar;

            const src_stride: u32 = @intCast(size / black_h);
            // Pack the DWORD-aligned source rows into a tight width-stride
            // bitmap and scale 0..64 → 0..255.
            for (0..black_h) |row| {
                const src = src_buf[row * src_stride ..][0..black_w];
                const dst = pixels[row * black_w ..][0..black_w];
                for (src, dst) |s, *d| {
                    const v: u32 = @as(u32, s) * 255 / 64;
                    d.* = @intCast(@min(@as(u32, 255), v));
                }
            }
        }

        return .{
            .pixels = pixels,
            .width = black_w,
            .rows = black_h,
            // gmptGlyphOrigin.x = pen-to-glyph-left, gmptGlyphOrigin.y =
            // baseline-to-glyph-top (positive upward) — same convention as
            // FreeType's bitmap_top and CoreText's `top`.
            .bearing_x = gm.gmptGlyphOrigin.x,
            .bearing_y = gm.gmptGlyphOrigin.y,
            .advance_x = gm.gmCellIncX,
        };
    }
};

pub const Renderer = common_text.Renderer(Backend);
