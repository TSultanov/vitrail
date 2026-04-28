const std = @import("std");
const wh = @import("windows.zig");
const w = wh.c;
const common = @import("../../common/DesktopWindow.zig");

/// Convert an HICON to platform-agnostic RGBA pixel data.
/// Uses DrawIconEx into a DIB section so all icon formats (masked, 8bpp, 32bpp) work.
/// The caller owns the returned RgbaIcon. The HICON is NOT destroyed.
pub fn hIconToRgba(icon: w.HICON, allocator: std.mem.Allocator) !common.RgbaIcon {
    var info: w.ICONINFO = undefined;
    if (w.GetIconInfo(icon, &info) == 0) return error.GetIconInfoFailed;
    defer if (info.hbmColor != null) { _ = w.DeleteObject(info.hbmColor); };
    defer if (info.hbmMask != null) { _ = w.DeleteObject(info.hbmMask); };

    // Query the bitmap dimensions from whichever handle is available
    const bm_src = if (info.hbmColor != null) info.hbmColor else info.hbmMask;
    if (bm_src == null) return error.NoIconBitmap;
    var bm: w.BITMAP = undefined;
    if (w.GetObjectW(bm_src, @sizeOf(w.BITMAP), &bm) == 0) return error.GetObjectFailed;

    const width: u32 = @intCast(bm.bmWidth);
    const raw_h: i32 = bm.bmHeight;
    const height: u32 = @intCast(if (raw_h < 0) -raw_h else raw_h);
    if (width == 0 or height == 0) return error.ZeroSizeIcon;

    // Create a top-down 32bpp DIB section to render into
    var bmi: w.BITMAPINFO = std.mem.zeroes(w.BITMAPINFO);
    bmi.bmiHeader.biSize = @sizeOf(w.BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = @intCast(width);
    bmi.bmiHeader.biHeight = -@as(i32, @intCast(height));
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = 0; // BI_RGB

    var bits: ?*anyopaque = null;
    const screen_dc = w.GetDC(null);
    defer _ = w.ReleaseDC(null, screen_dc);

    const hbm_dib = w.CreateDIBSection(screen_dc, &bmi, w.DIB_RGB_COLORS, &bits, null, 0);
    if (hbm_dib == null) return error.CreateDIBSectionFailed;
    defer _ = w.DeleteObject(hbm_dib);

    const mem_dc = w.CreateCompatibleDC(screen_dc);
    defer _ = w.DeleteDC(mem_dc);
    const old_bmp = w.SelectObject(mem_dc, hbm_dib);
    defer _ = w.SelectObject(mem_dc, old_bmp);

    // Fill with transparent black before drawing (so undrawn pixels are transparent)
    const black_brush = w.CreateSolidBrush(0);
    defer _ = w.DeleteObject(black_brush);
    var clear_rect = w.RECT{ .left = 0, .top = 0, .right = @intCast(width), .bottom = @intCast(height) };
    _ = w.FillRect(mem_dc, &clear_rect, black_brush);

    _ = w.DrawIconEx(mem_dc, 0, 0, icon, @intCast(width), @intCast(height), 0, null, w.DI_NORMAL);

    // Copy the BGRA DIB pixels and swap to RGBA
    const pixel_count = width * height;
    const pixels = try allocator.alloc(u8, pixel_count * 4);
    errdefer allocator.free(pixels);

    const src: [*]const u8 = @ptrCast(bits.?);
    @memcpy(pixels, src[0 .. pixel_count * 4]);

    for (0..pixel_count) |i| {
        const b = pixels[i * 4 + 0];
        pixels[i * 4 + 0] = pixels[i * 4 + 2]; // R ← B
        pixels[i * 4 + 2] = b; // B ← R
    }

    return common.RgbaIcon{
        .pixels = pixels,
        .width = width,
        .height = height,
        .allocator = allocator,
    };
}

/// Convert RgbaIcon back to an HICON for GDI rendering with DrawIconEx.
/// The caller is responsible for DestroyIcon on the result.
/// Returns null on failure rather than propagating errors.
pub fn rgbaToHIcon(rgba: common.RgbaIcon, allocator: std.mem.Allocator) ?w.HICON {
    return rgbaToHIconImpl(rgba, allocator) catch return null;
}

fn rgbaToHIconImpl(rgba: common.RgbaIcon, allocator: std.mem.Allocator) !w.HICON {
    const width = rgba.width;
    const height = rgba.height;

    var bmi: w.BITMAPINFO = std.mem.zeroes(w.BITMAPINFO);
    bmi.bmiHeader.biSize = @sizeOf(w.BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = @intCast(width);
    bmi.bmiHeader.biHeight = -@as(i32, @intCast(height));
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = 0; // BI_RGB

    var bits: ?*anyopaque = null;
    const screen_dc = w.GetDC(null);
    defer _ = w.ReleaseDC(null, screen_dc);

    const hbm_color = w.CreateDIBSection(screen_dc, &bmi, w.DIB_RGB_COLORS, &bits, null, 0);
    if (hbm_color == null) return error.CreateDIBSectionFailed;
    defer _ = w.DeleteObject(hbm_color);

    // Copy RGBA → BGRA with alpha preserved
    const dst: [*]u8 = @ptrCast(bits.?);
    const src = rgba.pixels;
    for (0..width * height) |i| {
        dst[i * 4 + 0] = src[i * 4 + 2]; // B ← R
        dst[i * 4 + 1] = src[i * 4 + 1]; // G
        dst[i * 4 + 2] = src[i * 4 + 0]; // R ← B
        dst[i * 4 + 3] = src[i * 4 + 3]; // A
    }

    // 1bpp mask: all zeros means "use color bitmap alpha for transparency"
    const mask_stride = (width + 31) / 32 * 4;
    const mask_bytes = try allocator.alloc(u8, mask_stride * height);
    defer allocator.free(mask_bytes);
    @memset(mask_bytes, 0);

    const hbm_mask = w.CreateBitmap(@intCast(width), @intCast(height), 1, 1, mask_bytes.ptr);
    if (hbm_mask == null) return error.CreateMaskFailed;
    defer _ = w.DeleteObject(hbm_mask);

    const icon_info = w.ICONINFO{
        .fIcon = 1,
        .xHotspot = 0,
        .yHotspot = 0,
        .hbmMask = hbm_mask,
        .hbmColor = hbm_color,
    };
    const icon = w.CreateIconIndirect(&icon_info);
    if (@intFromPtr(icon) == 0) return error.CreateIconIndirectFailed;
    return icon;
}
