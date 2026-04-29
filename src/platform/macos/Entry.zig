const std = @import("std");
const MainPresenter = @import("../../MainPresenter.zig");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{ .safety = true }) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const test_mode = parseTestMode(allocator) catch false;

    const presenter = try MainPresenter.init(.{}, allocator, test_mode);
    defer presenter.deinit();

    // Phase 6 will register a global hot key (Carbon RegisterEventHotKey) that
    // calls presenter.show() on demand. For now show on launch so the build
    // path is exercisable end-to-end.
    try presenter.show();

    while (presenter.view.running) {
        if (!presenter.view.dispatch()) break;
    }
}

fn parseTestMode(allocator: std.mem.Allocator) !bool {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--test-mode")) return true;
    }
    return false;
}
