// macOS test entry point. Default: runs the cross-platform scenarios with
// an in-process driver and exits with the failure count. With env var
// VITRAIL_INTERACTIVE=1: runs the production event loop against MockBackend
// (no automated input), useful for manually verifying that the real
// AppKit event paths work.
const std = @import("std");
const MainPresenter = @import("../../MainPresenter.zig");
const TestDriver = @import("test_driver.zig").Driver;
const ts = @import("../../test_scenarios.zig");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{ .safety = true }) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const presenter = try MainPresenter.init(.{}, allocator, true);
    defer presenter.deinit();

    if (std.posix.getenv("VITRAIL_INTERACTIVE")) |_| {
        try presenter.show();
        while (presenter.view.running) {
            if (!presenter.view.dispatch()) break;
        }
        return;
    }

    const driver = try TestDriver.create(allocator, presenter, "/tmp/vitrail-macos-tests");
    defer driver.destroy();

    var d = driver.driver();
    const fails = ts.runAll(&d);

    std.debug.print("\n{d} of {d} scenarios failed\n", .{ fails, ts.all.len });
    std.process.exit(if (fails == 0) 0 else 1);
}
