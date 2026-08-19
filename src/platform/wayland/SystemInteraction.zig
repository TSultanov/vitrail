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
        .wlroots => |*b| try b.getWindowList(allocator),
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

pub fn closeWindow(self: *Self, dw: common.DesktopWindow) void {
    switch (self.backend) {
        .kde => |*b| b.closeWindow(dw.stable_id),
        .wlroots => |*b| b.closeWindow(dw.stable_id),
    }
}

/// File descriptor carrying push-driven window-list notifications. MainWindow
/// polls it beside the overlay's own Wayland display and asks MainPresenter to
/// refresh after a short debounce.
pub fn eventFd(self: *const Self) ?std.posix.fd_t {
    return switch (self.backend) {
        .kde => |*b| b.eventFd(),
        .wlroots => |*b| b.eventFd(),
    };
}

/// Let the KDE backend keep the overlay's separate Wayland connection moving
/// while it awaits a KWin enumeration response. wlroots enumeration already
/// uses Wayland roundtrips and does not enter the KDE D-Bus wait.
pub fn setRefreshWaitPump(
    self: *Self,
    callback: KdeBackend.WaitPump,
    ctx: *anyopaque,
) void {
    switch (self.backend) {
        .kde => |*b| b.setWaitPump(callback, ctx),
        .wlroots => {},
    }
}

/// Consume all currently queued backend events before taking a fresh snapshot.
pub fn dispatchPending(self: *Self) void {
    switch (self.backend) {
        .kde => |*b| b.dispatchPending(),
        .wlroots => |*b| b.dispatchPending(),
    }
}

/// Enumeration itself pumps the backend connection. If it consumed a change
/// newer than the snapshot it just built, the presenter immediately takes a
/// trailing snapshot instead of waiting for an already-drained fd edge.
pub fn hasPendingChanges(self: *const Self) bool {
    return switch (self.backend) {
        .kde => |*b| b.hasPendingChanges(),
        .wlroots => |*b| b.hasPendingChanges(),
    };
}
