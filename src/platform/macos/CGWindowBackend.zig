// Window enumeration via CGWindowListCopyWindowInfo + activation via the
// bridge's NSRunningApplication wrapper. Pure-C path on the enumeration side;
// only the activation hop touches Cocoa.

const std = @import("std");
const common = @import("../../common/DesktopWindow.zig");
const bridge = @import("bridge.zig");
const cf = @import("cf.zig");
const cgs = @import("cgs.zig");

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

    // Build a Space-ID → flat 0-based-index map, matching Mission-Control
    // ordering (displays in the order CGS reports, Spaces in left-to-right
    // order within each). The renderer reads `desktopNumber` 0-indexed and
    // formats it as `n + 1` for the badge.
    const cid = cgs.CGSMainConnectionID();
    var space_index = std.AutoHashMap(i64, usize).init(allocator);
    defer space_index.deinit();
    if (cgs.CGSCopyManagedDisplaySpaces(cid)) |displays| {
        defer cf.c.CFRelease(displays);
        const dcount = cg.CFArrayGetCount(@ptrCast(displays));
        var di: cg.CFIndex = 0;
        while (di < dcount) : (di += 1) {
            const dptr = cg.CFArrayGetValueAtIndex(@ptrCast(displays), di) orelse continue;
            const ddict: cf.c.CFDictionaryRef = @ptrCast(@constCast(dptr));
            const spaces_arr = cf.cfDictGetArray(ddict, "Spaces") orelse continue;
            const scount = cg.CFArrayGetCount(@ptrCast(spaces_arr));
            var si: cg.CFIndex = 0;
            while (si < scount) : (si += 1) {
                const sptr = cg.CFArrayGetValueAtIndex(@ptrCast(spaces_arr), si) orelse continue;
                const sdict: cf.c.CFDictionaryRef = @ptrCast(@constCast(sptr));
                const id_n = cf.cfDictGetNumber(sdict, "id64") orelse continue;
                const id = cf.cfNumberToI64(id_n) orelse continue;
                const idx = space_index.count();
                try space_index.put(id, idx);
            }
        }
    }

    // kCGWindowListOptionAll (vs OnScreenOnly) returns windows on every
    // Space, including full-screen apps which each live in their own Space.
    const options: cg.CGWindowListOption =
        cg.kCGWindowListOptionAll | cg.kCGWindowListExcludeDesktopElements;
    const arr = cg.CGWindowListCopyWindowInfo(options, cg.kCGNullWindowID) orelse
        return error.CGWindowListFailed;
    defer cf.c.CFRelease(arr);

    const own_pid: i32 = @intCast(std.posix.system.getpid());

    var list = std.array_list.Managed(common.DesktopWindow).init(allocator);
    errdefer {
        for (list.items) |dw| dw.destroy();
        list.deinit();
    }

    // Dedupe macOS native window tabs: each tab is a distinct CGWindow
    // even though only one is visible. Tabs of one window share exact
    // size and near-identical origin (Ghostty/Terminal report each tab
    // at the parent window's frame, with small per-tab drift). Key on
    // (pid, x_bucket(100), y_bucket(100), w, h): same app, same size,
    // origin within a 100-px cell. Two genuinely distinct windows of
    // the same app at this granularity is unusual; tabs always collide.
    // First-seen wins, and the on-screen tab appears first in the
    // CGWindowListCopyWindowInfo order, so the visible one survives.
    // AltTab/Rectangle use the Accessibility API (kAXTabsAttribute);
    // this heuristic avoids that dependency.
    var seen_tabs = std.AutoHashMap(u64, void).init(allocator);
    defer seen_tabs.deinit();

    const count = cg.CFArrayGetCount(@ptrCast(arr));
    var i: cg.CFIndex = 0;
    while (i < count) : (i += 1) {
        const dict_ptr = cg.CFArrayGetValueAtIndex(@ptrCast(arr), i) orelse continue;
        const dict: cf.c.CFDictionaryRef = @ptrCast(@constCast(dict_ptr));

        // Filter: only normal-layer (0).
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

        // Bounds: drop the 1728×33 menu-bar strips (one per app per Space)
        // and tiny tooltip surfaces. Real user windows are >> 100×50.
        const bounds_dict_v = cf.c.CFDictionaryGetValue(dict, blk: {
            const k = cf.c.CFStringCreateWithCString(null, "kCGWindowBounds", cf.c.kCFStringEncodingUTF8) orelse break :blk null;
            break :blk k;
        });
        if (bounds_dict_v == null) continue;
        const bounds_dict: cf.c.CFDictionaryRef = @ptrCast(@constCast(bounds_dict_v));
        var bounds_rect: cg.CGRect = undefined;
        if (!cg.CGRectMakeWithDictionaryRepresentation(@ptrCast(bounds_dict), &bounds_rect)) continue;
        if (bounds_rect.size.width < 100 or bounds_rect.size.height < 50) continue;

        // Owner name is always present; window name is gated on Screen
        // Recording permission.
        const owner_str = cf.cfDictGetString(dict, "kCGWindowOwnerName");
        const title_str = cf.cfDictGetString(dict, "kCGWindowName");

        const has_title = if (title_str) |t| cf.c.CFStringGetLength(t) > 0 else false;

        const is_onscreen = blk: {
            const n = cf.cfDictGetNumber(dict, "kCGWindowIsOnscreen") orelse break :blk false;
            const v = cf.cfNumberToI64(n) orelse 0;
            break :blk v != 0;
        };
        if (!is_onscreen and !has_title) continue;

        // Look up the window's Space membership via CGS. Used for two
        // things: filtering hidden helper windows, and resolving the
        // 0-based desktop index for the badge. Real off-screen windows
        // (Anki/Safari/Calendar on other Spaces) report ≥1 Space; pure
        // hidden state (Activity Monitor's "Dock Icon Host", AdGuard
        // Mini's hidden popover, Anki's preferences sheet) report 0.
        // CGSCopySpacesForWindows is the only way to tell them apart —
        // they all have plausible bounds and titles otherwise.
        const SpaceInfo = struct { count: c_long, single_idx: ?usize };
        const space_info: SpaceInfo = blk: {
            var wid_val: c_int = @intCast(wid);
            const wid_cfnum = cf.c.CFNumberCreate(null, cf.c.kCFNumberIntType, &wid_val) orelse
                break :blk .{ .count = -1, .single_idx = null };
            defer cf.c.CFRelease(wid_cfnum);
            var wid_ptrs = [_]?*const anyopaque{wid_cfnum};
            const wids_arr = cf.c.CFArrayCreate(null, &wid_ptrs, 1, &cf.c.kCFTypeArrayCallBacks) orelse
                break :blk .{ .count = -1, .single_idx = null };
            defer cf.c.CFRelease(wids_arr);
            const spaces_arr = cgs.CGSCopySpacesForWindows(cid, cgs.SPACE_MASK_ALL, wids_arr) orelse
                break :blk .{ .count = -1, .single_idx = null };
            defer cf.c.CFRelease(spaces_arr);
            const sc = cg.CFArrayGetCount(@ptrCast(spaces_arr));
            if (sc != 1) break :blk .{ .count = sc, .single_idx = null };
            const sptr = cg.CFArrayGetValueAtIndex(@ptrCast(spaces_arr), 0) orelse
                break :blk .{ .count = sc, .single_idx = null };
            const sn: cf.c.CFNumberRef = @ptrCast(@constCast(sptr));
            const sid = cf.cfNumberToI64(sn) orelse break :blk .{ .count = sc, .single_idx = null };
            break :blk .{ .count = sc, .single_idx = space_index.get(sid) };
        };
        if (!is_onscreen and space_info.count == 0) continue;

        const title_src: cf.c.CFStringRef = if (has_title) title_str.? else (owner_str orelse continue);

        const title = try cf.cfStringDupeZ(allocator, title_src);
        errdefer allocator.free(title);

        // Tab dedupe: (pid, x_bucket, y_bucket, w, h).
        const dedupe_key: u64 = blk: {
            var h = std.hash.Wyhash.init(0);
            h.update(std.mem.asBytes(&pid));
            const x_i: i32 = @intFromFloat(@round(bounds_rect.origin.x));
            const y_i: i32 = @intFromFloat(@round(bounds_rect.origin.y));
            const x_b: i32 = @divFloor(x_i, 100);
            const y_b: i32 = @divFloor(y_i, 100);
            const w_i: i32 = @intFromFloat(@round(bounds_rect.size.width));
            const h_i: i32 = @intFromFloat(@round(bounds_rect.size.height));
            h.update(std.mem.asBytes(&x_b));
            h.update(std.mem.asBytes(&y_b));
            h.update(std.mem.asBytes(&w_i));
            h.update(std.mem.asBytes(&h_i));
            break :blk h.final();
        };
        if (seen_tabs.contains(dedupe_key)) {
            allocator.free(title);
            continue;
        }
        try seen_tabs.put(dedupe_key, {});

        const title_lower = try allocator.allocSentinel(u8, title.len, 0);
        errdefer allocator.free(title_lower);
        for (title, 0..) |ch, idx| title_lower[idx] = std.ascii.toLower(ch);

        const app_id_src = owner_str orelse title_src;
        const app_id = try cf.cfStringDupeZ(allocator, app_id_src);
        errdefer allocator.free(app_id);

        // 1 Space → that index; 0 or many → null. Many = "Show on All
        // Spaces"; the renderer leaves the badge blank for null, matching
        // the KdeBackend's all-desktops convention.
        const desktop_number: ?usize = space_info.single_idx;

        const idx = self.handles.items.len;
        try self.handles.append(self.allocator, .{ .pid = @intCast(pid), .window_id = @intCast(wid) });

        try list.append(.{
            .platform_handle = idx,
            .title = title,
            .title_lower = title_lower,
            .app_id = app_id,
            .icon = null,
            .desktopNumber = desktop_number,
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
