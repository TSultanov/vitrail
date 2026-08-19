// Per-pid icon cache. Defers to the Cocoa bridge for fetching the actual
// NSImage → RGBA conversion; the cache itself is plain Zig keyed by pid.

const std = @import("std");
const common = @import("../../common/DesktopWindow.zig");
const bridge = @import("bridge.zig");

const c = @cImport({
    @cInclude("stdlib.h");
});

const Self = @This();

const ICON_TARGET: c_int = 128;

allocator: std.mem.Allocator,
cache: std.AutoHashMapUnmanaged(i32, ?common.RgbaIcon) = .{},

pub fn init(allocator: std.mem.Allocator) Self {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Self) void {
    var it = self.cache.valueIterator();
    while (it.next()) |v| if (v.*) |ic| ic.destroy();
    self.cache.deinit(self.allocator);
}

pub fn loadFor(self: *Self, pid: i32) ?common.RgbaIcon {
    if (self.cache.get(pid)) |cached| {
        return dupeIcon(self.allocator, cached);
    }
    const resolved = self.resolve(pid);
    self.cache.put(self.allocator, pid, resolved) catch {
        if (resolved) |ic| ic.destroy();
        return null;
    };
    return dupeIcon(self.allocator, resolved);
}

pub fn pruneExcept(self: *Self, live_pids: *const std.AutoHashMap(i32, void)) void {
    var stale = std.ArrayListUnmanaged(i32){};
    defer stale.deinit(self.allocator);

    var it = self.cache.keyIterator();
    while (it.next()) |pid| {
        if (!live_pids.contains(pid.*)) {
            stale.append(self.allocator, pid.*) catch return;
        }
    }
    for (stale.items) |pid| {
        const removed = self.cache.fetchRemove(pid) orelse continue;
        if (removed.value) |icon| icon.destroy();
    }
}

fn resolve(self: *Self, pid: i32) ?common.RgbaIcon {
    var raw: [*]u8 = undefined;
    var w: u32 = 0;
    var h: u32 = 0;
    if (bridge.vt_icon_for_pid(pid, ICON_TARGET, &raw, &w, &h) != 0) return null;
    defer c.free(raw);
    if (w == 0 or h == 0) return null;
    const size: usize = @as(usize, w) * @as(usize, h) * 4;
    const pixels = self.allocator.dupe(u8, raw[0..size]) catch return null;
    return .{ .pixels = pixels, .width = w, .height = h, .allocator = self.allocator };
}

fn dupeIcon(allocator: std.mem.Allocator, src: ?common.RgbaIcon) ?common.RgbaIcon {
    const ic = src orelse return null;
    const pixels = allocator.dupe(u8, ic.pixels) catch return null;
    return .{
        .pixels = pixels,
        .width = ic.width,
        .height = ic.height,
        .allocator = allocator,
    };
}
