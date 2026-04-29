// Multi-backend dispatcher. Probes KDE's KRunner D-Bus first (works on KWin
// where the Wayland window-list protocols are gated), then falls back to
// the wlroots Wayland branch (Sway, Hyprland).
const std = @import("std");
const common = @import("../../common/DesktopWindow.zig");

const KdeBackend = @import("KdeBackend.zig");
const WlrootsBackend = @import("WlrootsBackend.zig");
const IconLoader = @import("IconLoader.zig");

const Self = @This();

const Backend = union(enum) {
    kde: KdeBackend,
    wlroots: WlrootsBackend,
};

backend: Backend,
icon_loader: IconLoader,

pub fn init(allocator: std.mem.Allocator) !Self {
    if (KdeBackend.init(allocator)) |kde| {
        std.log.debug("SystemInteraction: using KDE D-Bus backend", .{});
        return .{ .backend = .{ .kde = kde }, .icon_loader = IconLoader.init(allocator) };
    } else |kde_err| {
        std.log.debug("SystemInteraction: KDE backend unavailable ({t}); trying wlroots", .{kde_err});
    }

    if (WlrootsBackend.init(allocator)) |wlr| {
        std.log.debug("SystemInteraction: using wlroots Wayland backend", .{});
        return .{ .backend = .{ .wlroots = wlr }, .icon_loader = IconLoader.init(allocator) };
    } else |wlr_err| {
        std.log.err(
            \\No working window-list backend found.
            \\Tried KDE D-Bus (KRunner /WindowsRunner) and wlroots Wayland
            \\(zwlr_foreign_toplevel_management_v1).
            \\KWin must be running and own org.kde.KWin, or the compositor
            \\must implement the wlroots foreign-toplevel protocol.
        , .{});
        return wlr_err;
    }
}

pub fn deinit(self: *Self) void {
    switch (self.backend) {
        .kde => |*b| b.deinit(),
        .wlroots => |b| b.deinit(),
    }
    self.icon_loader.deinit();
}

pub fn getWindowList(self: *Self, allocator: std.mem.Allocator) !std.array_list.Managed(common.DesktopWindow) {
    const list = switch (self.backend) {
        .kde => |*b| try b.getWindowList(allocator),
        .wlroots => |b| try b.getWindowList(allocator),
    };
    for (list.items) |*dw| dw.icon = self.icon_loader.loadFor(dw);
    return list;
}

pub fn activateWindow(self: *Self, dw: common.DesktopWindow) void {
    switch (self.backend) {
        .kde => |*b| b.activateWindow(dw),
        .wlroots => |*b| b.activateWindow(dw),
    }
}
