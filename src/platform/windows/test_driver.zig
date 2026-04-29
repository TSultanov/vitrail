// Windows in-process test driver. Posts WM_KEYDOWN / WM_CHAR /
// WM_MOUSEMOVE / WM_LBUTTONDOWN+UP into the main window message queue,
// drains the queue between steps, and reads state from MainPresenter.
// Build only when `-Dmock-backend=true`.

const std = @import("std");
const wh = @import("windows.zig");
const w = wh.c;
const ts = @import("../../test_scenarios.zig");
const MainPresenter = @import("../../MainPresenter.zig");
const Layout = @import("Layout.zig");

pub const Driver = struct {
    presenter: *MainPresenter,
    out_dir: []const u8,
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    // Tracks whether scenario expects window visible. We set this on reset()
    // and observe `IsWindowVisible(presenter.view.window.hwnd)` plus
    // `presenter.desktop_windows != null` for the actual state.
    initial_load_done: bool = false,

    pub fn create(allocator: std.mem.Allocator, presenter: *MainPresenter, out_dir: []const u8) !*Driver {
        std.fs.cwd().makePath(out_dir) catch {};
        const self = try allocator.create(Driver);
        self.* = .{
            .presenter = presenter,
            .out_dir = out_dir,
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
        return self;
    }

    pub fn destroy(self: *Driver) void {
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    pub fn driver(self: *Driver) ts.Driver {
        return .{ .ctx = self, .vt = &vtable };
    }

    fn dupe(self: *Driver, s: []const u8) []const u8 {
        return self.arena.allocator().dupe(u8, s) catch s;
    }

    fn cast(ctx: *anyopaque) *Driver {
        return @ptrCast(@alignCast(ctx));
    }

    const vtable = ts.Driver.VTable{
        .post_key = postKey,
        .post_char = postChar,
        .post_mouse_move = postMouseMove,
        .post_mouse_click = postMouseClick,
        .selected_app_id = selectedAppId,
        .visible_count = visibleCount,
        .search_text = searchText,
        .last_activated_app_id = lastActivatedAppId,
        .window_visible = windowVisible,
        .tile_center = tileCenter,
        .snapshot = snapshot,
        .reset = reset,
    };

    fn keyToVk(k: ts.Key) struct { vk: u32, shift: bool } {
        return switch (k) {
            .left => .{ .vk = w.VK_LEFT, .shift = false },
            .right => .{ .vk = w.VK_RIGHT, .shift = false },
            .up => .{ .vk = w.VK_UP, .shift = false },
            .down => .{ .vk = w.VK_DOWN, .shift = false },
            .tab => .{ .vk = w.VK_TAB, .shift = false },
            .shift_tab => .{ .vk = w.VK_TAB, .shift = true },
            .esc => .{ .vk = w.VK_ESCAPE, .shift = false },
            .enter => .{ .vk = w.VK_RETURN, .shift = false },
            .backspace => .{ .vk = w.VK_BACK, .shift = false },
        };
    }

    fn postKey(ctx: *anyopaque, k: ts.Key) anyerror!void {
        const self = cast(ctx);
        const layout_hwnd = self.presenter.view.layout.window.hwnd;
        const m = keyToVk(k);
        // Layout's onKeyDown reads VK_SHIFT via GetAsyncKeyState; the test
        // can't easily synthesize that. For shift+tab, route directly to
        // Layout.prev() to avoid the async-key check, otherwise post.
        if (m.shift and m.vk == w.VK_TAB) {
            self.presenter.view.layout.prev() catch {};
        } else {
            _ = w.PostMessageW(layout_hwnd, w.WM_KEYDOWN, m.vk, 0);
        }
        drain();
    }

    fn postChar(ctx: *anyopaque, cp: u21) anyerror!void {
        const self = cast(ctx);
        const search_hwnd = self.presenter.view.search_box.window.hwnd;
        // Treat the codepoint as UTF-16 BMP (sufficient for ASCII tests).
        if (cp > 0xFFFF) return;
        _ = w.PostMessageW(search_hwnd, w.WM_CHAR, @intCast(cp), 0);
        drain();
    }

    fn postMouseMove(ctx: *anyopaque, x: i32, y: i32) anyerror!void {
        const self = cast(ctx);
        const layout_hwnd = self.presenter.view.layout.window.hwnd;
        const lparam = makeLparam(x, y);
        _ = w.PostMessageW(layout_hwnd, w.WM_MOUSEMOVE, 0, lparam);
        drain();
    }

    fn postMouseClick(ctx: *anyopaque, x: i32, y: i32) anyerror!void {
        const self = cast(ctx);
        const layout = self.presenter.view.layout;

        // If (x,y) is inside any visible tile, send to layout (which becomes
        // a click → activate via onMouseMove + onClick handlers).
        var hit_tile = false;
        for (layout.tiles.items) |t| {
            if (!t.visible) continue;
            if (x >= t.bounds.left and x < t.bounds.right and y >= t.bounds.top and y < t.bounds.bottom) {
                hit_tile = true;
                break;
            }
        }

        if (hit_tile) {
            const layout_hwnd = layout.window.hwnd;
            const lparam = makeLparam(x, y);
            _ = w.PostMessageW(layout_hwnd, w.WM_MOUSEMOVE, 0, lparam);
            _ = w.PostMessageW(layout_hwnd, w.WM_LBUTTONDOWN, 1, lparam);
            _ = w.PostMessageW(layout_hwnd, w.WM_LBUTTONUP, 0, lparam);
        } else {
            // Outside-grid click: synthesize WA_INACTIVE on the main window.
            // SetWindowRgn excludes those pixels from our window, so a real
            // mouse event would route to the desktop and we'd see WA_INACTIVE
            // shortly after. We post that directly.
            const main_hwnd = self.presenter.view.window.hwnd;
            _ = w.PostMessageW(main_hwnd, w.WM_ACTIVATE, 0, 0); // WA_INACTIVE = 0
        }
        drain();
    }

    fn selectedAppId(ctx: *anyopaque) ?[]const u8 {
        const self = cast(ctx);
        const layout = self.presenter.view.layout;
        const idx = layout.selected_idx orelse return null;
        if (idx >= layout.tiles.items.len) return null;
        const tile = layout.tiles.items[idx];
        if (!tile.visible) return null;
        return self.dupe(tile.desktopWindow.app_id);
    }

    fn visibleCount(ctx: *anyopaque) usize {
        const self = cast(ctx);
        var n: usize = 0;
        for (self.presenter.view.layout.tiles.items) |t| if (t.visible) {
            n += 1;
        };
        return n;
    }

    fn searchText(ctx: *anyopaque) []const u8 {
        const self = cast(ctx);
        const utf16 = self.presenter.view.search_box.window.getText(self.allocator) catch return "";
        defer self.allocator.free(utf16);
        const utf8 = std.unicode.utf16LeToUtf8Alloc(self.arena.allocator(), utf16) catch return "";
        return utf8;
    }

    fn lastActivatedAppId(ctx: *anyopaque) ?[]const u8 {
        const self = cast(ctx);
        const s = self.presenter.si.last_activated_app_id orelse return null;
        return self.dupe(s);
    }

    fn windowVisible(ctx: *anyopaque) bool {
        const self = cast(ctx);
        return self.presenter.desktop_windows != null and
            self.presenter.view.window.isVisible();
    }

    fn tileCenter(ctx: *anyopaque, app_id: []const u8) ?ts.Point {
        const self = cast(ctx);
        for (self.presenter.view.layout.tiles.items) |t| {
            if (!t.visible) continue;
            if (std.mem.eql(u8, t.desktopWindow.app_id, app_id)) {
                return .{
                    .x = t.bounds.left + @divFloor(t.bounds.right - t.bounds.left, 2),
                    .y = t.bounds.top + @divFloor(t.bounds.bottom - t.bounds.top, 2),
                };
            }
        }
        return null;
    }

    fn snapshot(ctx: *anyopaque, name: []const u8) anyerror!void {
        const self = cast(ctx);
        drain();
        _ = w.UpdateWindow(self.presenter.view.window.hwnd);
        drain();
        const path = try std.fmt.allocPrint(self.allocator, "{s}\\{s}.bmp", .{ self.out_dir, name });
        defer self.allocator.free(path);
        dumpBmp(self.presenter.view.window.hwnd, path) catch |e| {
            std.log.err("snapshot {s}: {t}", .{ name, e });
        };
    }

    fn reset(ctx: *anyopaque) anyerror!void {
        const self = cast(ctx);
        _ = self.arena.reset(.retain_capacity);
        if (!self.initial_load_done) {
            try self.presenter.show();
            self.initial_load_done = true;
        }
        if (self.presenter.desktop_windows == null) {
            try self.presenter.show();
        } else {
            // Already visible: clear search by sending Ctrl-A + Delete to
            // the search box. Simpler: reset selection + clear underlying
            // search by setting empty text on the EDIT control.
            const empty: [1]u16 = .{0};
            _ = w.SendMessageW(self.presenter.view.search_box.window.hwnd, w.WM_SETTEXT, 0, @bitCast(@as(usize, @intFromPtr(&empty))));
            drain();
        }
        self.presenter.si.resetActivations();
    }
};

fn drain() void {
    var msg: w.MSG = undefined;
    while (w.PeekMessageW(&msg, null, 0, 0, w.PM_REMOVE) != 0) {
        _ = w.TranslateMessage(&msg);
        _ = w.DispatchMessageW(&msg);
    }
}

fn makeLparam(x: i32, y: i32) w.LPARAM {
    const lo: u32 = @bitCast(x);
    const hi: u32 = @bitCast(y);
    return @bitCast(@as(u64, lo & 0xFFFF) | (@as(u64, hi & 0xFFFF) << 16));
}

fn dumpBmp(hwnd: w.HWND, path: []const u8) !void {
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

    if (w.PrintWindow(hwnd, mem_dc, 0x2) == 0) return error.PrintWindowFailed;

    const stride: u32 = @intCast(((@as(i64, width) * 3 + 3) & ~@as(i64, 3)));
    const image_size: u32 = stride * @as(u32, @intCast(height));

    const buf = try std.heap.page_allocator.alloc(u8, image_size);
    defer std.heap.page_allocator.free(buf);

    var bi: w.BITMAPINFO = std.mem.zeroes(w.BITMAPINFO);
    bi.bmiHeader.biSize = @sizeOf(w.BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = width;
    bi.bmiHeader.biHeight = height;
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 24;
    bi.bmiHeader.biCompression = w.BI_RGB;
    bi.bmiHeader.biSizeImage = image_size;

    if (w.GetDIBits(mem_dc, bmp, 0, @intCast(height), buf.ptr, &bi, w.DIB_RGB_COLORS) == 0)
        return error.GetDIBitsFailed;

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    const file_size: u32 = 14 + 40 + image_size;
    var hdr: [14]u8 = undefined;
    hdr[0] = 'B';
    hdr[1] = 'M';
    std.mem.writeInt(u32, hdr[2..6], file_size, .little);
    std.mem.writeInt(u32, hdr[6..10], 0, .little);
    std.mem.writeInt(u32, hdr[10..14], 14 + 40, .little);
    try file.writeAll(&hdr);
    var info: [40]u8 = .{0} ** 40;
    std.mem.writeInt(u32, info[0..4], 40, .little);
    std.mem.writeInt(i32, info[4..8], width, .little);
    std.mem.writeInt(i32, info[8..12], height, .little);
    std.mem.writeInt(u16, info[12..14], 1, .little);
    std.mem.writeInt(u16, info[14..16], 24, .little);
    std.mem.writeInt(u32, info[20..24], image_size, .little);
    try file.writeAll(&info);
    try file.writeAll(buf);
}
