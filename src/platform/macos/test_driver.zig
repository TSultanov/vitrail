// In-process macOS test driver. Same shape as the Wayland version: synthesizes
// keyboard/mouse actions directly into the MainWindow action sinks (bypassing
// NSEvent), writes snapshots as 24-bit BMPs.

const std = @import("std");
const ts = @import("../../test_scenarios.zig");
const MainPresenter = @import("../../MainPresenter.zig");
const MainWindow = @import("MainWindow.zig");
const Keyboard = @import("Keyboard.zig");
const Mouse = @import("Mouse.zig");
const bridge = @import("bridge.zig");
const cf = @import("cf.zig");
const ax_cache = @import("ax_cache.zig");

pub const Driver = struct {
    presenter: *MainPresenter,
    out_dir: []const u8,
    snap_pixels: []u32,
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    initial_load_done: bool = false,

    pub fn create(allocator: std.mem.Allocator, presenter: *MainPresenter, out_dir: []const u8) !*Driver {
        std.fs.cwd().makePath(out_dir) catch {};
        const sz = presenter.view.viewportSize();
        const px = try allocator.alloc(u32, sz.w * sz.h);
        const self = try allocator.create(Driver);
        self.* = .{
            .presenter = presenter,
            .out_dir = out_dir,
            .snap_pixels = px,
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
        return self;
    }

    pub fn destroy(self: *Driver) void {
        self.arena.deinit();
        self.allocator.free(self.snap_pixels);
        self.allocator.destroy(self);
    }

    fn dupe(self: *Driver, s: []const u8) []const u8 {
        return self.arena.allocator().dupe(u8, s) catch s;
    }

    pub fn driver(self: *Driver) ts.Driver {
        return .{ .ctx = self, .vt = &vtable };
    }

    const vtable = ts.Driver.VTable{
        .post_key = postKey,
        .post_char = postChar,
        .post_mouse_move = postMouseMove,
        .post_mouse_click = postMouseClick,
        .post_context_close = postContextClose,
        .close_external = closeExternal,
        .selected_app_id = selectedAppId,
        .visible_count = visibleCount,
        .search_text = searchText,
        .last_activated_app_id = lastActivatedAppId,
        .last_closed_app_id = lastClosedAppId,
        .window_visible = windowVisible,
        .tile_center = tileCenter,
        .snapshot = snapshot,
        .reset = reset,
    };

    fn cast(ctx: *anyopaque) *Driver {
        return @ptrCast(@alignCast(ctx));
    }

    fn keyToAction(k: ts.Key) Keyboard.Action {
        return switch (k) {
            .left => .{ .move = .{ .dx = -1, .dy = 0 } },
            .right => .{ .move = .{ .dx = 1, .dy = 0 } },
            .up => .{ .move = .{ .dx = 0, .dy = -1 } },
            .down => .{ .move = .{ .dx = 0, .dy = 1 } },
            .tab => .next,
            .shift_tab => .prev,
            .esc => .quit,
            .enter => .activate,
            .backspace => .backspace,
        };
    }

    fn postKey(ctx: *anyopaque, k: ts.Key) anyerror!void {
        const self = cast(ctx);
        self.presenter.view.synthesizeKey(keyToAction(k));
    }

    fn postChar(ctx: *anyopaque, cp: u21) anyerror!void {
        const self = cast(ctx);
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidCodepoint;
        self.presenter.view.synthesizeKey(.{ .insert = buf[0..n] });
    }

    fn postMouseMove(ctx: *anyopaque, x: i32, y: i32) anyerror!void {
        const self = cast(ctx);
        self.presenter.view.synthesizeMouse(.{ .move = .{ .x = x, .y = y } });
    }

    fn postMouseClick(ctx: *anyopaque, x: i32, y: i32) anyerror!void {
        const self = cast(ctx);
        self.presenter.view.synthesizeMouse(.{ .click = .{ .x = x, .y = y } });
    }

    /// Exercise the semantic result of the native menu without entering
    /// AppKit's blocking menu-tracking loop in the automated scenario.
    fn postContextClose(ctx: *anyopaque, x: i32, y: i32) anyerror!void {
        const self = cast(ctx);
        self.presenter.view.synthesizeMouse(.{ .move = .{ .x = x, .y = y } });
        const target = self.presenter.view.grid.selectedWindow() orelse return error.NoTile;
        const stable_id = self.dupe(target.stable_id);
        const can_close = target.can_close;
        try self.presenter.view.callbacks.closeWindow(self.presenter.view, target.stable_id);
        if (can_close) try self.waitForStableIdGone(stable_id);
    }

    fn closeExternal(ctx: *anyopaque, app_id: []const u8) anyerror!void {
        const self = cast(ctx);
        if (!self.presenter.si.closeExternally(app_id)) return error.NoWindow;
        try self.waitForAppIdGone(app_id);
    }

    fn waitForStableIdGone(self: *Driver, stable_id: []const u8) !void {
        const deadline_ms = std.time.milliTimestamp() + 1000;
        while (self.presenter.desktop_windows != null and
            self.gridContainsStableId(stable_id))
        {
            try self.driveWindowChangeNotifications(deadline_ms);
        }
    }

    fn waitForAppIdGone(self: *Driver, app_id: []const u8) !void {
        const deadline_ms = std.time.milliTimestamp() + 1000;
        while (self.presenter.desktop_windows != null and
            self.presenter.view.grid.tileCenter(app_id) != null)
        {
            try self.driveWindowChangeNotifications(deadline_ms);
        }
    }

    fn driveWindowChangeNotifications(_: *Driver, deadline_ms: i64) !void {
        if (std.time.milliTimestamp() >= deadline_ms) {
            return error.AutomaticRefreshTimeout;
        }

        // Exercise both production invalidation sinks and keep doing so faster
        // than the 100 ms refresh interval. A resettable debounce timer is
        // starved by this loop; a fixed-deadline coalescer still fires.
        ax_cache.notifyChangeForTest();
        bridge.vt_test_post_window_change_notification();
        _ = cf.c.CFRunLoopRunInMode(
            cf.c.kCFRunLoopDefaultMode,
            0.01,
            0,
        );
    }

    fn gridContainsStableId(self: *Driver, stable_id: []const u8) bool {
        for (self.presenter.view.grid.tiles.items) |tile| {
            if (std.mem.eql(u8, tile.dw.stable_id, stable_id)) return true;
        }
        return false;
    }

    fn selectedAppId(ctx: *anyopaque) ?[]const u8 {
        const self = cast(ctx);
        const dw = self.presenter.view.grid.selectedWindow() orelse return null;
        return self.dupe(dw.app_id);
    }

    fn visibleCount(ctx: *anyopaque) usize {
        const self = cast(ctx);
        var n: usize = 0;
        for (self.presenter.view.grid.tiles.items) |t| if (t.visible) {
            n += 1;
        };
        return n;
    }

    fn searchText(ctx: *anyopaque) []const u8 {
        const self = cast(ctx);
        return self.dupe(self.presenter.view.grid.searchSlice());
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

    fn windowVisible(ctx: *anyopaque) bool {
        const self = cast(ctx);
        return self.presenter.desktop_windows != null;
    }

    fn tileCenter(ctx: *anyopaque, app_id: []const u8) ?ts.Point {
        const self = cast(ctx);
        const c = self.presenter.view.grid.tileCenter(app_id) orelse return null;
        return .{ .x = c.x, .y = c.y };
    }

    fn snapshot(ctx: *anyopaque, name: []const u8) anyerror!void {
        const self = cast(ctx);
        self.presenter.view.renderInto(self.snap_pixels);

        const sz = self.presenter.view.viewportSize();
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.bmp", .{ self.out_dir, name });
        defer self.allocator.free(path);
        try writeBmp24(path, sz.w, sz.h, self.snap_pixels);
    }

    fn reset(ctx: *anyopaque) anyerror!void {
        const self = cast(ctx);
        _ = self.arena.reset(.retain_capacity);
        self.presenter.si.resetActions();

        if (!self.initial_load_done) {
            try self.presenter.show();
            self.initial_load_done = true;
        } else if (self.presenter.desktop_windows == null) {
            try self.presenter.show();
        } else {
            self.presenter.view.grid.search_len = 0;
            try self.presenter.refreshWindowList();
        }
    }
};

fn writeBmp24(path: []const u8, width: u32, height: u32, argb: []const u32) !void {
    const w_i: i32 = @intCast(width);
    const h_i: i32 = @intCast(height);
    const stride: u32 = (width * 3 + 3) & ~@as(u32, 3);
    const image_size: u32 = stride * height;
    const file_size: u32 = 14 + 40 + image_size;

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    var hdr: [14]u8 = undefined;
    hdr[0] = 'B';
    hdr[1] = 'M';
    std.mem.writeInt(u32, hdr[2..6], file_size, .little);
    std.mem.writeInt(u32, hdr[6..10], 0, .little);
    std.mem.writeInt(u32, hdr[10..14], 14 + 40, .little);
    try file.writeAll(&hdr);

    var info: [40]u8 = .{0} ** 40;
    std.mem.writeInt(u32, info[0..4], 40, .little);
    std.mem.writeInt(i32, info[4..8], w_i, .little);
    std.mem.writeInt(i32, info[8..12], h_i, .little);
    std.mem.writeInt(u16, info[12..14], 1, .little);
    std.mem.writeInt(u16, info[14..16], 24, .little);
    std.mem.writeInt(u32, info[20..24], image_size, .little);
    try file.writeAll(&info);

    const row_buf = try std.heap.page_allocator.alloc(u8, stride);
    defer std.heap.page_allocator.free(row_buf);

    var y: i64 = @as(i64, h_i) - 1;
    while (y >= 0) : (y -= 1) {
        @memset(row_buf, 0);
        const row = argb[@as(usize, @intCast(y)) * width ..][0..width];
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const px = row[x];
            row_buf[x * 3 + 0] = @truncate(px); // B
            row_buf[x * 3 + 1] = @truncate(px >> 8); // G
            row_buf[x * 3 + 2] = @truncate(px >> 16); // R
        }
        try file.writeAll(row_buf);
    }
}
