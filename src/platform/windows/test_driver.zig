// Scriptable harness for the Windows build: posts WM_KEYDOWN/WM_CHAR into the
// main window message queue, drains messages between steps, and dumps the
// rendered window to a 24-bit BMP at chosen checkpoints. Wired in only when
// `-Dmock-backend=true`.

const std = @import("std");
const wh = @import("windows.zig");
const w = wh.c;

pub const Step = union(enum) {
    char: u16,            // posts WM_CHAR with this UTF-16 codepoint
    key_down: u16,        // posts WM_KEYDOWN with this VK_*
    snapshot: []const u8, // dumps client BMP to <out_dir>/<name>.bmp
};

pub fn run(hwnd: w.HWND, script: []const Step, out_dir: []const u8, allocator: std.mem.Allocator) !void {
    std.fs.cwd().makePath(out_dir) catch {};

    for (script) |step| {
        switch (step) {
            .char => |cp| {
                _ = w.PostMessageW(hwnd, w.WM_CHAR, cp, 0);
            },
            .key_down => |vk| {
                _ = w.PostMessageW(hwnd, w.WM_KEYDOWN, vk, 0);
                _ = w.PostMessageW(hwnd, w.WM_KEYUP, vk, 0);
            },
            .snapshot => |name| {
                drainMessages();
                _ = w.UpdateWindow(hwnd);
                drainMessages();

                const path = try std.fmt.allocPrint(allocator, "{s}/{s}.bmp", .{ out_dir, name });
                defer allocator.free(path);
                dumpToBmp(hwnd, path) catch |e| {
                    std.log.err("test_driver: snapshot {s} failed: {t}", .{ name, e });
                };
            },
        }
    }

    drainMessages();
}

fn drainMessages() void {
    var msg: w.MSG = undefined;
    while (w.PeekMessageW(&msg, null, 0, 0, w.PM_REMOVE) != 0) {
        _ = w.TranslateMessage(&msg);
        _ = w.DispatchMessageW(&msg);
    }
}

fn dumpToBmp(hwnd: w.HWND, path: []const u8) !void {
    var rect: w.RECT = undefined;
    try wh.mapFailure(w.GetClientRect(hwnd, &rect));
    const width: i32 = rect.right - rect.left;
    const height: i32 = rect.bottom - rect.top;
    if (width <= 0 or height <= 0) return error.EmptyClientRect;

    const screen_dc = w.GetDC(null);
    defer _ = w.ReleaseDC(null, screen_dc);

    const mem_dc = w.CreateCompatibleDC(screen_dc);
    defer _ = w.DeleteDC(mem_dc);

    const bmp = w.CreateCompatibleBitmap(screen_dc, width, height);
    defer _ = w.DeleteObject(bmp);

    const old_obj = w.SelectObject(mem_dc, bmp);
    defer _ = w.SelectObject(mem_dc, old_obj);

    // PrintWindow with PW_RENDERFULLCONTENT (0x2) renders the whole window to
    // mem_dc, ignoring SetWindowRgn clipping — gives a deterministic capture.
    if (w.PrintWindow(hwnd, mem_dc, 0x2) == 0) return error.PrintWindowFailed;

    const stride: u32 = @intCast(((@as(i64, width) * 3 + 3) & ~@as(i64, 3)));
    const image_size: u32 = stride * @as(u32, @intCast(height));

    const buf = try std.heap.page_allocator.alloc(u8, image_size);
    defer std.heap.page_allocator.free(buf);

    var bi: w.BITMAPINFO = std.mem.zeroes(w.BITMAPINFO);
    bi.bmiHeader.biSize = @sizeOf(w.BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = width;
    bi.bmiHeader.biHeight = height; // positive = bottom-up rows in `buf`
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 24;
    bi.bmiHeader.biCompression = w.BI_RGB;
    bi.bmiHeader.biSizeImage = image_size;

    if (w.GetDIBits(mem_dc, bmp, 0, @intCast(height), buf.ptr, &bi, w.DIB_RGB_COLORS) == 0)
        return error.GetDIBitsFailed;

    // Write BMP file: 14-byte file header + 40-byte info header + pixel data.
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    const file_size: u32 = 14 + 40 + image_size;
    const pixel_offset: u32 = 14 + 40;

    var hdr: [14]u8 = undefined;
    hdr[0] = 'B';
    hdr[1] = 'M';
    std.mem.writeInt(u32, hdr[2..6], file_size, .little);
    std.mem.writeInt(u32, hdr[6..10], 0, .little);
    std.mem.writeInt(u32, hdr[10..14], pixel_offset, .little);
    try file.writeAll(&hdr);

    var info: [40]u8 = undefined;
    @memset(&info, 0);
    std.mem.writeInt(u32, info[0..4], 40, .little);
    std.mem.writeInt(i32, info[4..8], width, .little);
    std.mem.writeInt(i32, info[8..12], height, .little);
    std.mem.writeInt(u16, info[12..14], 1, .little);
    std.mem.writeInt(u16, info[14..16], 24, .little);
    std.mem.writeInt(u32, info[16..20], 0, .little);
    std.mem.writeInt(u32, info[20..24], image_size, .little);
    try file.writeAll(&info);

    try file.writeAll(buf);

    std.log.info("test_driver: wrote {s} ({d}x{d})", .{ path, width, height });
}
