// Deterministic SystemInteraction stand-in for visual + interactive tests.
// Wired in at compile time when `-Dmock-backend=true`. Returns a fixed window
// list, records activations.

const std = @import("std");
const common = @import("../common/DesktopWindow.zig");

const Self = @This();

const Fixture = struct {
    title: []const u8,
    app_id: []const u8,
    desktop: ?usize,
    can_close: bool = true,
};

const fixtures = [_]Fixture{
    .{ .title = "VS Code — vitrail", .app_id = "code", .desktop = 1 },
    .{ .title = "Firefox — issue tracker", .app_id = "firefox", .desktop = 1 },
    .{ .title = "Terminal — zig build", .app_id = "terminal", .desktop = 2 },
    .{ .title = "Slack — engineering", .app_id = "slack", .desktop = 2 },
    .{ .title = "Spotify", .app_id = "spotify", .desktop = 3 },
    .{ .title = "Email — Inbox (3)", .app_id = "thunderbird", .desktop = 1 },
    .{ .title = "Notes — design doc", .app_id = "obsidian", .desktop = 3, .can_close = false },
    .{ .title = "Figma — vitrail mockups", .app_id = "figma", .desktop = 2 },
};

allocator: std.mem.Allocator,
activated_count: usize = 0,
last_activated_app_id: ?[]const u8 = null,
closed_count: usize = 0,
last_closed_app_id: ?[]const u8 = null,
closed: [fixtures.len]bool = .{false} ** fixtures.len,

pub fn init(allocator: std.mem.Allocator) !Self {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn bindLifecycleTracker(_: *Self) void {}

pub fn getWindowList(self: *Self, allocator: std.mem.Allocator) !std.array_list.Managed(common.DesktopWindow) {
    var list = std.array_list.Managed(common.DesktopWindow).init(allocator);
    errdefer {
        for (list.items) |dw| dw.destroy();
        list.deinit();
    }

    for (fixtures, 0..) |f, idx| {
        if (self.closed[idx]) continue;
        const stable_id = try allocator.dupeZ(u8, f.app_id);
        errdefer allocator.free(stable_id);
        const title = try allocator.dupeZ(u8, f.title);
        errdefer allocator.free(title);
        const title_lower = try allocator.dupeZ(u8, f.title);
        errdefer allocator.free(title_lower);
        for (title_lower) |*ch| ch.* = std.ascii.toLower(ch.*);
        const app_id = try allocator.dupeZ(u8, f.app_id);
        errdefer allocator.free(app_id);
        const app_id_lower = try allocator.dupeZ(u8, f.app_id);
        errdefer allocator.free(app_id_lower);
        for (app_id_lower) |*ch| ch.* = std.ascii.toLower(ch.*);

        try list.append(.{
            .stable_id = stable_id,
            .platform_handle = idx,
            .title = title,
            .title_lower = title_lower,
            .app_id = app_id,
            .app_id_lower = app_id_lower,
            .icon = null,
            .desktopNumber = f.desktop,
            .can_close = f.can_close,
            .allocator = allocator,
        });
    }

    return list;
}

pub fn activateWindow(self: *Self, dw: common.DesktopWindow) void {
    if (dw.platform_handle >= fixtures.len or self.closed[dw.platform_handle]) return;
    self.activated_count += 1;
    self.last_activated_app_id = fixtures[dw.platform_handle].app_id;
    std.log.info("MockBackend.activateWindow: {s}", .{fixtures[dw.platform_handle].app_id});
}

pub fn closeWindow(self: *Self, dw: common.DesktopWindow) void {
    if (dw.platform_handle >= fixtures.len or self.closed[dw.platform_handle] or !dw.can_close) return;
    self.closed[dw.platform_handle] = true;
    self.closed_count += 1;
    self.last_closed_app_id = fixtures[dw.platform_handle].app_id;
    std.log.info("MockBackend.closeWindow: {s}", .{fixtures[dw.platform_handle].app_id});
}

pub fn closeExternally(self: *Self, app_id: []const u8) bool {
    for (fixtures, 0..) |fixture, idx| {
        if (!std.mem.eql(u8, fixture.app_id, app_id) or self.closed[idx]) continue;
        self.closed[idx] = true;
        return true;
    }
    return false;
}

pub fn reopenAll(self: *Self) void {
    @memset(self.closed[0..], false);
}

/// Forget mutations and recorded actions — used between test scenarios.
pub fn resetActions(self: *Self) void {
    self.activated_count = 0;
    self.last_activated_app_id = null;
    self.closed_count = 0;
    self.last_closed_app_id = null;
    @memset(self.closed[0..], false);
}

// Linux's presenter wires the real backend event fd into the Wayland loop.
// The deterministic mock has no external source; test drivers trigger refresh
// explicitly after mutating it.
pub fn eventFd(_: *Self) ?std.posix.fd_t {
    return null;
}

pub fn setRefreshWaitPump(
    _: *Self,
    _: *const fn (ctx: *anyopaque) bool,
    _: *anyopaque,
) void {}

pub fn dispatchPending(_: *Self) void {}

pub fn hasPendingChanges(_: *const Self) bool {
    return false;
}
