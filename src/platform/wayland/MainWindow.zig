// Stub — full Wayland UI implementation in Phase 7.
const std = @import("std");
const common = @import("../../common/DesktopWindow.zig");

const Self = @This();

pub const PlatformArgs = struct {};

pub const Callbacks = struct {
    activateWindow: *const fn (*Self, common.DesktopWindow) anyerror!void,
    hide: *const fn (*Self) anyerror!void,
};

pub fn create(_: PlatformArgs, _: *Callbacks, _: std.mem.Allocator) !*Self {
    unreachable;
}

pub fn show(_: *Self) !void {}
pub fn activate(_: *Self) void {}
pub fn requestQuit(_: *Self) void {}
pub fn setDesktopWindows(_: *Self, _: anytype) !void {}
pub fn hideBoxes(_: *Self) !void {}
