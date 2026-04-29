// macOS SystemInteraction. Composes CGWindowBackend (window enumeration +
// activation) with IconLoader (NSWorkspace-backed app icons).

const std = @import("std");
const common = @import("../../common/DesktopWindow.zig");

const CGWindowBackend = @import("CGWindowBackend.zig");
const IconLoader = @import("IconLoader.zig");

const Self = @This();

backend: CGWindowBackend,
icon_loader: IconLoader,

pub fn init(allocator: std.mem.Allocator) !Self {
    return .{
        .backend = try CGWindowBackend.init(allocator),
        .icon_loader = IconLoader.init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.backend.deinit();
    self.icon_loader.deinit();
}

pub fn getWindowList(self: *Self, allocator: std.mem.Allocator) !std.array_list.Managed(common.DesktopWindow) {
    const list = try self.backend.getWindowList(allocator);
    for (list.items) |*dw| {
        const pid = self.backend.pidFor(dw.platform_handle) orelse continue;
        dw.icon = self.icon_loader.loadFor(pid);
    }
    return list;
}

pub fn activateWindow(self: *Self, dw: common.DesktopWindow) void {
    self.backend.activate(dw);
}
