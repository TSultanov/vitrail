const std = @import("std");
const MainPresenter = @import("../../MainPresenter.zig");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{ .safety = true }) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const test_mode = parseTestMode(allocator) catch false;

    var presenter = try MainPresenter.init(.{}, allocator, test_mode);

    // Launch-on-demand: surface the grid immediately on start.
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
