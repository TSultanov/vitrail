const std = @import("std");
const common = @import("common/DesktopWindow.zig");
const MockBackend = @import("platform/MockBackend.zig");

test "mock close command ignores a descriptor which is not closeable" {
    var backend = try MockBackend.init(std.testing.allocator);
    defer backend.deinit();

    var windows = try backend.getWindowList(std.testing.allocator);
    defer {
        for (windows.items) |dw| dw.destroy();
        windows.deinit();
    }

    var obsidian: ?common.DesktopWindow = null;
    for (windows.items) |dw| {
        if (std.mem.eql(u8, dw.app_id, "obsidian")) {
            obsidian = dw;
            break;
        }
    }

    const target = obsidian orelse return error.MissingFixture;
    try std.testing.expect(!target.can_close);
    backend.closeWindow(target);
    try std.testing.expectEqual(@as(usize, 0), backend.closed_count);
    try std.testing.expect(backend.last_closed_app_id == null);
    try std.testing.expect(!backend.closed[target.platform_handle]);
}
