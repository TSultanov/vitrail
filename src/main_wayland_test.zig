const std = @import("std");

pub const std_options: std.Options = .{ .log_level = .debug };
pub const main = @import("platform/wayland/test_main.zig").main;
