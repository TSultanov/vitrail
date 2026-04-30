// FreeType + Fontconfig glyph backend for the shared rasterizer in
// common/text.zig. Fontconfig resolves the system font path; FreeType
// rasterizes each codepoint to an 8-bit alpha bitmap. The cache + blit
// live in common/text.zig.

const std = @import("std");
const common_text = @import("../../common/text.zig");

pub const Weight = common_text.Weight;
pub const Clip = common_text.Clip;

const c = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("fontconfig/fontconfig.h");
});

const Backend = struct {
    library: c.FT_Library,
    face: c.FT_Face,
    ascent: i32,

    pub fn init(allocator: std.mem.Allocator, pixel_size: u32, weight: Weight) !Backend {
        var library: c.FT_Library = undefined;
        if (c.FT_Init_FreeType(&library) != 0) return error.FreeTypeInit;
        errdefer _ = c.FT_Done_FreeType(library);

        const font_path = try resolveFont(allocator, weight);
        defer allocator.free(font_path);

        var face: c.FT_Face = undefined;
        if (c.FT_New_Face(library, font_path.ptr, 0, &face) != 0) return error.FontLoad;
        errdefer _ = c.FT_Done_Face(face);

        if (c.FT_Set_Pixel_Sizes(face, 0, pixel_size) != 0) return error.SetSize;

        // metrics.ascender is in 26.6 fixed point.
        const ascent: i32 = @intCast(@divTrunc(face.*.size.*.metrics.ascender, 64));

        return .{
            .library = library,
            .face = face,
            .ascent = ascent,
        };
    }

    pub fn deinit(self: *Backend) void {
        _ = c.FT_Done_Face(self.face);
        _ = c.FT_Done_FreeType(self.library);
    }

    pub fn loadGlyph(self: *Backend, allocator: std.mem.Allocator, codepoint: u32) !common_text.Glyph {
        if (c.FT_Load_Char(self.face, codepoint, c.FT_LOAD_RENDER) != 0) return error.LoadChar;
        const slot = self.face.*.glyph;
        const bm = slot.*.bitmap;

        const pixels = try allocator.alloc(u8, bm.width * bm.rows);
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

        return .{
            .pixels = pixels,
            .width = bm.width,
            .rows = bm.rows,
            .bearing_x = slot.*.bitmap_left,
            .bearing_y = slot.*.bitmap_top,
            .advance_x = @intCast(@divTrunc(slot.*.advance.x, 64)),
        };
    }
};

pub const Renderer = common_text.Renderer(Backend);

fn resolveFont(allocator: std.mem.Allocator, weight: Weight) ![:0]u8 {
    if (c.FcInit() == 0) return error.FontconfigInit;

    const name: [*:0]const u8 = switch (weight) {
        .regular => "sans-serif",
        .bold => "sans-serif:bold",
    };
    const pattern = c.FcNameParse(@ptrCast(name)) orelse return error.FontconfigPattern;
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
