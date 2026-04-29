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
};

const fixtures = [_]Fixture{
    .{ .title = "VS Code — vitrail", .app_id = "code", .desktop = 1 },
    .{ .title = "Firefox — issue tracker", .app_id = "firefox", .desktop = 1 },
    .{ .title = "Terminal — zig build", .app_id = "terminal", .desktop = 2 },
    .{ .title = "Slack — engineering", .app_id = "slack", .desktop = 2 },
    .{ .title = "Spotify", .app_id = "spotify", .desktop = 3 },
    .{ .title = "Email — Inbox (3)", .app_id = "thunderbird", .desktop = 1 },
    .{ .title = "Notes — design doc", .app_id = "obsidian", .desktop = 3 },
    .{ .title = "Figma — vitrail mockups", .app_id = "figma", .desktop = 2 },
};

allocator: std.mem.Allocator,
activated_count: usize = 0,
last_activated_app_id: ?[]const u8 = null,

pub fn init(allocator: std.mem.Allocator) !Self {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn getWindowList(self: *Self, allocator: std.mem.Allocator) !std.array_list.Managed(common.DesktopWindow) {
    _ = self;
    var list = std.array_list.Managed(common.DesktopWindow).init(allocator);
    errdefer {
        for (list.items) |dw| dw.destroy();
        list.deinit();
    }

    for (fixtures, 0..) |f, idx| {
        const title = try allocator.dupeZ(u8, f.title);
        errdefer allocator.free(title);
        const title_lower = try allocator.dupeZ(u8, f.title);
        errdefer allocator.free(title_lower);
        for (title_lower) |*ch| ch.* = std.ascii.toLower(ch.*);
        const app_id = try allocator.dupeZ(u8, f.app_id);
        errdefer allocator.free(app_id);

        try list.append(.{
            .platform_handle = idx,
            .title = title,
            .title_lower = title_lower,
            .app_id = app_id,
            .icon = null,
            .desktopNumber = f.desktop,
            .allocator = allocator,
        });
    }

    return list;
}

pub fn activateWindow(self: *Self, dw: common.DesktopWindow) void {
    self.activated_count += 1;
    self.last_activated_app_id = fixtures[dw.platform_handle].app_id;
    std.log.info("MockBackend.activateWindow: {s}", .{fixtures[dw.platform_handle].app_id});
}
