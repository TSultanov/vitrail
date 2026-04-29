// Window enumeration via CGWindowListCopyWindowInfo + activation via the
// bridge's NSRunningApplication wrapper. Pure-C path on the enumeration side;
// only the activation hop touches Cocoa.

const std = @import("std");
const common = @import("../../common/DesktopWindow.zig");
const bridge = @import("bridge.zig");
const cf = @import("cf.zig");

const cg = @cImport({
    @cInclude("CoreGraphics/CoreGraphics.h");
});

const Self = @This();

const PlatformHandle = struct {
    pid: i32,
    window_id: u32,
};

allocator: std.mem.Allocator,
// Stable backing store for the platform_handle the caller stores in
// DesktopWindow.platform_handle (we cast usize ↔ index).
handles: std.ArrayListUnmanaged(PlatformHandle) = .{},

pub fn init(allocator: std.mem.Allocator) !Self {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Self) void {
    self.handles.deinit(self.allocator);
}

pub fn getWindowList(self: *Self, allocator: std.mem.Allocator) !std.array_list.Managed(common.DesktopWindow) {
    self.handles.clearRetainingCapacity();

    const options: cg.CGWindowListOption =
        cg.kCGWindowListOptionOnScreenOnly | cg.kCGWindowListExcludeDesktopElements;
    const arr = cg.CGWindowListCopyWindowInfo(options, cg.kCGNullWindowID) orelse
        return error.CGWindowListFailed;
    defer cf.c.CFRelease(arr);

    const own_pid: i32 = @intCast(std.posix.system.getpid());

    var list = std.array_list.Managed(common.DesktopWindow).init(allocator);
    errdefer {
        for (list.items) |dw| dw.destroy();
        list.deinit();
    }

    const count = cg.CFArrayGetCount(@ptrCast(arr));
    var i: cg.CFIndex = 0;
    while (i < count) : (i += 1) {
        const dict_ptr = cg.CFArrayGetValueAtIndex(@ptrCast(arr), i) orelse continue;
        const dict: cf.c.CFDictionaryRef = @ptrCast(@constCast(dict_ptr));

        // Filter: only normal-layer (0), on-screen, with a positive alpha.
        const layer = blk: {
            const n = cf.cfDictGetNumber(dict, "kCGWindowLayer") orelse continue;
            break :blk cf.cfNumberToI64(n) orelse continue;
        };
        if (layer != 0) continue;

        const pid_n = cf.cfDictGetNumber(dict, "kCGWindowOwnerPID") orelse continue;
        const pid = cf.cfNumberToI64(pid_n) orelse continue;
        if (pid == own_pid) continue;

        const wid_n = cf.cfDictGetNumber(dict, "kCGWindowNumber") orelse continue;
        const wid = cf.cfNumberToI64(wid_n) orelse continue;

        // Owner name is always present; window name is gated on Screen
        // Recording permission. Fall back to owner name when the title is
        // missing so the grid is still usable without permission.
        const owner_str = cf.cfDictGetString(dict, "kCGWindowOwnerName");
        const title_str = cf.cfDictGetString(dict, "kCGWindowName");

        const title_src: cf.c.CFStringRef = if (title_str) |t|
            if (cf.c.CFStringGetLength(t) > 0) t else (owner_str orelse continue)
        else
            (owner_str orelse continue);

        const title = try cf.cfStringDupeZ(allocator, title_src);
        errdefer allocator.free(title);

        const title_lower = try allocator.allocSentinel(u8, title.len, 0);
        errdefer allocator.free(title_lower);
        for (title, 0..) |ch, idx| title_lower[idx] = std.ascii.toLower(ch);

        const app_id_src = owner_str orelse title_src;
        const app_id = try cf.cfStringDupeZ(allocator, app_id_src);
        errdefer allocator.free(app_id);

        const idx = self.handles.items.len;
        try self.handles.append(self.allocator, .{ .pid = @intCast(pid), .window_id = @intCast(wid) });

        try list.append(.{
            .platform_handle = idx,
            .title = title,
            .title_lower = title_lower,
            .app_id = app_id,
            .icon = null,
            .desktopNumber = null,
            .allocator = allocator,
        });
    }

    return list;
}

pub fn pidFor(self: *const Self, idx: usize) ?i32 {
    if (idx >= self.handles.items.len) return null;
    return self.handles.items[idx].pid;
}

pub fn activate(self: *Self, dw: common.DesktopWindow) void {
    const pid = self.pidFor(dw.platform_handle) orelse return;
    _ = bridge.vt_activate_pid(pid);
}
