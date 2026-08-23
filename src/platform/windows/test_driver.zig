// Windows in-process test driver. Posts keyboard/click messages into the real
// window queue, uses explicit logical pointer coordinates for hover
// reconciliation, drains between steps, and reads state directly from Grid.
// Build only when `-Dmock-backend=true`.

const std = @import("std");
const wh = @import("windows.zig");
const w = wh.c;
const ts = @import("../../test_scenarios.zig");
const MainPresenter = @import("../../MainPresenter.zig");
const Layout = @import("Layout.zig");
const Grid = @import("../../common/Grid.zig");

pub const Driver = struct {
    presenter: *MainPresenter,
    out_dir: []const u8,
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
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
        .post_context_close = postContextClose,
        .post_context_quit = postContextQuit,
        .close_external = closeExternal,
        .selected_app_id = selectedAppId,
        .visible_count = visibleCount,
        .search_text = searchText,
        .last_activated_app_id = lastActivatedAppId,
        .last_closed_app_id = lastClosedAppId,
        .last_quit_app_id = lastQuitAppId,
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
        const layout = self.presenter.view.layout;
        const m = keyToVk(k);
        // Layout's onKeyDown reads VK_SHIFT via GetAsyncKeyState; the test
        // can't easily synthesize that. For shift+tab, mutate the grid
        // directly to avoid the async-key check, otherwise post the message.
        if (m.shift and m.vk == w.VK_TAB) {
            layout.useKeyboardSelection();
            layout.grid.selectNext(true);
            layout.window.redraw() catch {};
        } else {
            _ = w.PostMessageW(layout.window.hwnd, w.WM_KEYDOWN, m.vk, 0);
        }
        drain();
    }

    fn postChar(ctx: *anyopaque, cp: u21) anyerror!void {
        const self = cast(ctx);
        // Treat the codepoint as UTF-16 BMP (sufficient for ASCII tests).
        if (cp > 0xFFFF) return;
        _ = w.PostMessageW(self.presenter.view.layout.window.hwnd, w.WM_CHAR, @intCast(cp), 0);
        drain();
    }

    fn postMouseMove(ctx: *anyopaque, x: i32, y: i32) anyerror!void {
        const self = cast(ctx);
        const layout = self.presenter.view.layout;
        try layout.synthesizeMouseMove(x, y);
        drain();
    }

    fn postMouseClick(ctx: *anyopaque, x: i32, y: i32) anyerror!void {
        const self = cast(ctx);
        const layout = self.presenter.view.layout;

        const inside_tile = layout.grid.tileAt(x, y) != null;

        if (inside_tile) {
            // Keep the explicit test coordinate pointer-authoritative without
            // consulting the host's unrelated physical cursor.
            try layout.synthesizeMouseMove(x, y);
            const phys = logicalToPhysical(layout, x, y);
            const lparam = makeLparam(phys.x, phys.y);
            _ = w.PostMessageW(layout.window.hwnd, w.WM_LBUTTONDOWN, 1, lparam);
            _ = w.PostMessageW(layout.window.hwnd, w.WM_LBUTTONUP, 0, lparam);
        } else {
            // Outside-grid click: synthesize WA_INACTIVE on the main window.
            // SetWindowRgn excludes those pixels from our window, so a real
            // mouse event would route to the desktop and trigger WA_INACTIVE
            // shortly after.
            _ = w.PostMessageW(self.presenter.view.window.hwnd, w.WM_ACTIVATE, 0, 0);
        }
        drain();
    }

    /// Exercise the semantic result of choosing the native context-menu item
    /// without entering TrackPopupMenuEx's blocking nested loop in CI.
    fn postContextClose(ctx: *anyopaque, x: i32, y: i32) anyerror!void {
        const self = cast(ctx);
        const layout = self.presenter.view.layout;
        const tile_index = layout.grid.tileAt(x, y) orelse return error.NoTile;
        const target = layout.grid.tiles.items[tile_index].dw;

        // Model movement consumed by TrackPopupMenuEx. Verify both the
        // post-menu live-pointer re-hit and the same re-hit during a refresh.
        var expected_stable_id: ?[]const u8 = null;
        for (layout.grid.tiles.items, 0..) |tile, idx| {
            if (!tile.visible or idx == tile_index) continue;
            expected_stable_id = self.dupe(tile.dw.stable_id);
            layout.synthesizeDeferredPointerPosition(
                tile.x + @divFloor(Grid.TILE_W, 2),
                tile.y + @divFloor(Grid.TILE_H, 2),
            );
            if (!layout.selectAtCurrentPointer()) return error.PostMenuPointerNotSelected;
            const selected = layout.grid.selectedWindow() orelse return error.LostPointerSelection;
            if (!std.mem.eql(u8, expected_stable_id.?, selected.stable_id)) {
                return error.PostMenuPointerMismatch;
            }

            // Restore the menu target while retaining the deferred pointer.
            // refreshDesktopWindows must re-hit it after the target disappears.
            layout.grid.selected = tile_index;
            break;
        }

        try self.presenter.view.callbacks.closeWindow(self.presenter.view, target.stable_id);
        try self.presenter.refreshWindowList();
        drain();

        if (expected_stable_id) |expected| {
            const selected = layout.grid.selectedWindow() orelse return error.LostPointerSelection;
            if (!std.mem.eql(u8, expected, selected.stable_id)) {
                return error.RefreshPointerMismatch;
            }
        }
    }

    fn postContextQuit(ctx: *anyopaque, x: i32, y: i32) anyerror!void {
        const self = cast(ctx);
        const layout = self.presenter.view.layout;
        const tile_index = layout.grid.tileAt(x, y) orelse return error.NoTile;
        const target = layout.grid.tiles.items[tile_index].dw;
        try self.presenter.view.callbacks.quitApplication(self.presenter.view, target.stable_id);
        try self.presenter.refreshWindowList();
        drain();
    }

    fn closeExternal(ctx: *anyopaque, app_id: []const u8) anyerror!void {
        const self = cast(ctx);
        if (!self.presenter.si.closeExternally(app_id)) return error.NoWindow;
        try self.presenter.refreshWindowList();
        drain();
    }

    fn selectedAppId(ctx: *anyopaque) ?[]const u8 {
        const self = cast(ctx);
        const dw = self.presenter.view.layout.grid.selectedWindow() orelse return null;
        return self.dupe(dw.app_id);
    }

    fn visibleCount(ctx: *anyopaque) usize {
        const self = cast(ctx);
        var n: usize = 0;
        for (self.presenter.view.layout.grid.tiles.items) |t| if (t.visible) {
            n += 1;
        };
        return n;
    }

    fn searchText(ctx: *anyopaque) []const u8 {
        const self = cast(ctx);
        return self.dupe(self.presenter.view.layout.grid.searchSlice());
    }

    fn lastActivatedAppId(ctx: *anyopaque) ?[]const u8 {
        const self = cast(ctx);
        const s = self.presenter.si.last_activated_app_id orelse return null;
        return self.dupe(s);
    }

    fn lastClosedAppId(ctx: *anyopaque) ?[]const u8 {
        const self = cast(ctx);
        const s = self.presenter.si.last_closed_app_id orelse return null;
        return self.dupe(s);
    }

    fn lastQuitAppId(ctx: *anyopaque) ?[]const u8 {
        const self = cast(ctx);
        const s = self.presenter.si.last_quit_app_id orelse return null;
        return self.dupe(s);
    }

    fn windowVisible(ctx: *anyopaque) bool {
        const self = cast(ctx);
        return self.presenter.desktop_windows != null and
            self.presenter.view.window.isVisible();
    }

    fn tileCenter(ctx: *anyopaque, app_id: []const u8) ?ts.Point {
        const self = cast(ctx);
        const c = self.presenter.view.layout.grid.tileCenter(app_id) orelse return null;
        return .{ .x = c.x, .y = c.y };
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
        // Reset backend mutations first, then reconcile an already-visible
        // presenter so a window closed by the previous scenario is restored
        // in the borrowed grid snapshot before search/selection are reset.
        self.presenter.si.resetActions();
        if (!self.initial_load_done) {
            try self.presenter.show();
            self.initial_load_done = true;
        }
        if (self.presenter.desktop_windows == null) {
            try self.presenter.show();
        } else {
            try self.presenter.refreshWindowList();
            // Already visible: reset the grid's search buffer, rebuild
            // visibility, redraw, and refresh the window region.
            self.presenter.view.layout.grid.search_len = 0;
            try self.presenter.view.layout.grid.rebuild();
            try self.presenter.view.layout.window.redraw();
            self.presenter.view.layout_callbacks.visibility_changed(&self.presenter.view.layout_callbacks) catch {};
            drain();
        }
    }
};

fn logicalToPhysical(layout: *Layout, x: i32, y: i32) struct { x: i32, y: i32 } {
    const dpi: c_int = @intCast(layout.window.dpi);
    return .{ .x = w.MulDiv(x, dpi, 96), .y = w.MulDiv(y, dpi, 96) };
}

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
