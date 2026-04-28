// Stub — full Wayland implementation in Phase 6.
const std = @import("std");
const common = @import("../../common/DesktopWindow.zig");

const Self = @This();

pub fn init() !Self {
    return Self{};
}

pub fn deinit(_: Self) void {}

pub fn getWindowList(_: Self, _: std.mem.Allocator) !std.ArrayListUnmanaged(common.DesktopWindow) {
    return std.ArrayListUnmanaged(common.DesktopWindow){};
}

pub fn activateWindow(_: *Self, _: common.DesktopWindow) void {}
