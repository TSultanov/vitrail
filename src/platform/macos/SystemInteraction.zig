// macOS SystemInteraction. Composes AXWindowBackend (window enumeration +
// activation) with IconLoader (NSWorkspace-backed app icons).

const std = @import("std");
const common = @import("../../common/DesktopWindow.zig");

const AXWindowBackend = @import("AXWindowBackend.zig");
const IconLoader = @import("IconLoader.zig");

const Self = @This();

backend: AXWindowBackend,
icon_loader: IconLoader,

pub fn init(allocator: std.mem.Allocator) !Self {
    return .{
        .backend = try AXWindowBackend.init(allocator),
        .icon_loader = IconLoader.init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.backend.deinit();
    self.icon_loader.deinit();
}

pub fn getWindowList(self: *Self, allocator: std.mem.Allocator) !std.array_list.Managed(common.DesktopWindow) {
    const list = try self.backend.getWindowList(allocator);

    // Drop icon entries for processes no longer represented by the current
    // snapshot. This prevents a later PID reuse from inheriting a terminated
    // application's cached image.
    var live_pids = std.AutoHashMap(i32, void).init(allocator);
    defer live_pids.deinit();
    var complete_live_set = true;
    for (list.items) |dw| {
        const pid = self.backend.pidFor(dw.platform_handle) orelse continue;
        live_pids.put(pid, {}) catch {
            complete_live_set = false;
            break;
        };
    }
    if (complete_live_set) self.icon_loader.pruneExcept(&live_pids);

    for (list.items) |*dw| {
        const pid = self.backend.pidFor(dw.platform_handle) orelse continue;
        dw.icon = self.icon_loader.loadFor(pid);
    }
    return list;
}

pub fn activateWindow(self: *Self, dw: common.DesktopWindow) void {
    self.backend.activate(dw);
}

pub fn closeWindow(self: *Self, dw: common.DesktopWindow) void {
    self.backend.close(dw);
}

pub fn quitApplication(self: *Self, dw: common.DesktopWindow) void {
    self.backend.quitApplication(dw);
}
