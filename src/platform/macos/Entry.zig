const std = @import("std");
const MainPresenter = @import("../../MainPresenter.zig");
const HotKey = @import("HotKey.zig");

const App = struct {
    presenter: *MainPresenter,
    hotkey: HotKey,

    fn onHotkey(ctx: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.presenter.show() catch |err| {
            std.log.warn("show failed: {s}", .{@errorName(err)});
        };
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{ .safety = true }) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const test_mode = parseTestMode(allocator) catch false;

    const presenter = try MainPresenter.init(.{}, allocator, test_mode);
    defer presenter.deinit();

    var app: App = .{ .presenter = presenter, .hotkey = undefined };
    try app.hotkey.init(HotKey.default_binding, App.onHotkey, &app);
    defer app.hotkey.deinit();

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
