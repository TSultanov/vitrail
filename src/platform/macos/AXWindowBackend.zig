// AX-driven window backend. Walks NSWorkspace.runningApplications via the
// Cocoa bridge, asks each app's AXUIElement for kAXWindowsAttribute, and
// filters on subrole + size. Same shape as the previous CG-driven backend
// (init / deinit / getWindowList / pidFor / activate); SystemInteraction
// only changes the imported file.
//
// Why AX instead of CGWindowListCopyWindowInfo:
//   * Phantoms (Calendar / Claude / Activity Monitor's "Dock Icon Host"
//     etc.) never appear because dead AX windows aren't returned.
//   * macOS native window tabs collapse for free — AX returns one entry
//     per visible tabbed window, not one per tab.
//   * Empty kCGWindowName no longer drops legitimate off-Space windows
//     (Focus To-Do, Music's mini-player). We fall back to the app name.
//
// CGS is still used for Space-membership lookup (the desktop badge).

const std = @import("std");
const common = @import("../../common/DesktopWindow.zig");
const ax = @import("ax.zig");
const bridge = @import("bridge.zig");
const cf = @import("cf.zig");
const cgs = @import("cgs.zig");

const cg = @cImport({
    @cInclude("CoreGraphics/CoreGraphics.h");
});

const Self = @This();

const PlatformHandle = struct {
    pid: i32,
    wid: u32, // CGWindowID; used for phase-2 dedupe.
    ax_window: ax.UIElementRef, // CFRetain'd. Always non-null with the
    // brute-force phase-2 path (we get a real AX element back from
    // _AXUIElementCreateWithRemoteToken — no CG-only entries any more).
};

allocator: std.mem.Allocator,
handles: std.ArrayListUnmanaged(PlatformHandle) = .{},

var ax_warn_logged: bool = false;

const SortInfo = struct {
    group: u8, // 0 = current-Space (in z-order map), 1 = off-Space
    rank: i64, // group 0: z-index ascending; group 1: -activation_ordinal
    insertion: u32, // stable tiebreak
};

pub fn init(allocator: std.mem.Allocator) !Self {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Self) void {
    self.releaseHandles();
    self.handles.deinit(self.allocator);
}

fn releaseHandles(self: *Self) void {
    for (self.handles.items) |h| {
        if (h.ax_window) |w| cf.c.CFRelease(w);
    }
}

pub fn pidFor(self: *const Self, idx: usize) ?i32 {
    if (idx >= self.handles.items.len) return null;
    return self.handles.items[idx].pid;
}

pub fn getWindowList(self: *Self, allocator: std.mem.Allocator) !std.array_list.Managed(common.DesktopWindow) {
    self.releaseHandles();
    self.handles.clearRetainingCapacity();

    var list = std.array_list.Managed(common.DesktopWindow).init(allocator);
    errdefer {
        for (list.items) |dw| dw.destroy();
        list.deinit();
    }

    if (ax.AXIsProcessTrusted() == 0) {
        if (!ax_warn_logged) {
            ax_warn_logged = true;
            std.log.warn("AX permission not granted; window list will be empty until granted via System Settings → Privacy & Security → Accessibility.", .{});
        }
        return list;
    }

    const cid = cgs.CGSMainConnectionID();

    // Global onscreen z-order map (CGWindowID → front-to-back rank). Off-Space
    // windows aren't onscreen and so won't have an entry here — they fall
    // back to per-app activation ordinal in the sort below.
    var wid_zorder = std.AutoHashMap(u32, u32).init(allocator);
    defer wid_zorder.deinit();
    {
        const opts: u32 = cg.kCGWindowListOptionOnScreenOnly | cg.kCGWindowListExcludeDesktopElements;
        if (cg.CGWindowListCopyWindowInfo(opts, cg.kCGNullWindowID)) |arr| {
            defer cf.c.CFRelease(arr);
            const n = cg.CFArrayGetCount(@ptrCast(arr));
            var i: cg.CFIndex = 0;
            while (i < n) : (i += 1) {
                const dptr = cg.CFArrayGetValueAtIndex(@ptrCast(arr), i) orelse continue;
                const dict: cf.c.CFDictionaryRef = @ptrCast(@constCast(dptr));
                const num = cf.cfDictGetNumber(dict, "kCGWindowNumber") orelse continue;
                var v: i64 = 0;
                if (cf.c.CFNumberGetValue(num, cf.c.kCFNumberSInt64Type, &v) == 0) continue;
                const wid: u32 = @intCast(v);
                if (!wid_zorder.contains(wid)) try wid_zorder.put(wid, @intCast(i));
            }
        }
    }

    // Build Space-ID → 0-based-index map (Mission Control left-to-right
    // ordering). Lifted from the previous CG backend.
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

    // Pre-build CFString keys (one allocation each, reused across the
    // whole walk).
    const k_windows = cfStr("AXWindows") orelse return error.CFStringCreate;
    defer cf.c.CFRelease(k_windows);
    const k_title = cfStr("AXTitle") orelse return error.CFStringCreate;
    defer cf.c.CFRelease(k_title);
    const k_subrole = cfStr("AXSubrole") orelse return error.CFStringCreate;
    defer cf.c.CFRelease(k_subrole);
    const k_size = cfStr("AXSize") orelse return error.CFStringCreate;
    defer cf.c.CFRelease(k_size);
    const v_standard = cfStr("AXStandardWindow") orelse return error.CFStringCreate;
    defer cf.c.CFRelease(v_standard);
    const v_dialog = cfStr("AXDialog") orelse return error.CFStringCreate;
    defer cf.c.CFRelease(v_dialog);

    var pid_count: c_int = 0;
    const pids_ptr = bridge.vt_running_pids(&pid_count) orelse return list;
    defer bridge.vt_free(@ptrCast(pids_ptr));
    if (pid_count <= 0) return list;
    const pids = pids_ptr[0..@intCast(pid_count)];

    var sort_infos = std.ArrayListUnmanaged(SortInfo){};
    defer sort_infos.deinit(allocator);

    var emitted_wids = std.AutoHashMap(u32, void).init(allocator);
    defer emitted_wids.deinit();

    var ctx = EmitCtx{
        .list = &list,
        .sort_infos = &sort_infos,
        .allocator = allocator,
        .cid = cid,
        .space_index = &space_index,
        .wid_zorder = &wid_zorder,
        .emitted_wids = &emitted_wids,
        .pid = 0,
        .app_name = "",
        .app_ordinal = 0,
        .k_subrole = k_subrole,
        .k_size = k_size,
        .k_title = k_title,
        .v_standard = v_standard,
        .v_dialog = v_dialog,
    };

    for (pids) |pid_c| {
        const pid: i32 = @intCast(pid_c);
        const app_elem = ax.AXUIElementCreateApplication(pid) orelse continue;
        defer cf.c.CFRelease(app_elem);

        // Resolve the app name once per pid — used as fallback title and
        // as app_id (color-hash key).
        const app_name_c = bridge.vt_app_name_for_pid(pid);
        defer if (app_name_c) |p| bridge.vt_free(@ptrCast(@constCast(p)));
        ctx.pid = pid;
        ctx.app_name = if (app_name_c) |p| std.mem.sliceTo(p, 0) else "Unknown";
        ctx.app_ordinal = bridge.vt_app_activation_ordinal(pid);

        // Phase 1: kAXWindowsAttribute. Returns current-Space windows and
        // sometimes off-Space ones, depending on app. Apps whose windows
        // are *all* on other Spaces tend to return an empty array here.
        var wins_ref: cf.c.CFTypeRef = null;
        if (ax.AXUIElementCopyAttributeValue(app_elem, k_windows, &wins_ref) == ax.kAXErrorSuccess and wins_ref != null) {
            defer cf.c.CFRelease(wins_ref);
            const wins_arr: cf.c.CFArrayRef = @ptrCast(@constCast(wins_ref));
            const wcount = cg.CFArrayGetCount(@ptrCast(wins_arr));
            var wi: cg.CFIndex = 0;
            while (wi < wcount) : (wi += 1) {
                const wptr = cg.CFArrayGetValueAtIndex(@ptrCast(wins_arr), wi) orelse continue;
                const win_elem: ax.UIElementRef = @ptrCast(@constCast(wptr));
                _ = try self.tryEmit(&ctx, win_elem);
            }
        }

        // Phase 2: brute-force AX scan via the private
        // _AXUIElementCreateWithRemoteToken API. Discovers windows that
        // kAXWindowsAttribute hides — primarily off-Space siblings of
        // multi-window apps (Safari with a window in native fullscreen,
        // Ghostty with another window on a different Space) and
        // single-window apps whose only window is off-Space (Focus
        // To-Do, KeePassXC).
        try self.bruteForceAxScan(&ctx, pid);
    }

    std.sort.pdqContext(0, list.items.len, SortCtx{
        .items = list.items,
        .keys = sort_infos.items,
    });

    return list;
}

/// Brute-force AX scan: builds the 20-byte remote token (pid | 0 |
/// magic "cooo" | ax-element-id) and iterates element-ids 0..1000,
/// constructing AXUIElements via the private
/// _AXUIElementCreateWithRemoteToken. Filters by `_AXUIElementGetWindow`
/// (cheap windowness test), then hands surviving elements to `tryEmit`
/// which applies the subrole/size/wid-dedupe filters and retains on
/// accept. 100ms timeout per app caps cost on apps with thousands of
/// UI elements.
fn bruteForceAxScan(self: *Self, ctx: *EmitCtx, pid: i32) !void {
    var token: [20]u8 = std.mem.zeroes([20]u8);
    std.mem.writeInt(i32, token[0..4], pid, .little);
    std.mem.writeInt(i32, token[8..12], 0x636f636f, .little);

    const start_ns = std.time.nanoTimestamp();
    var ax_id: u64 = 0;
    while (ax_id < 1000) : (ax_id += 1) {
        std.mem.writeInt(u64, token[12..20], ax_id, .little);
        const data = cf.c.CFDataCreate(null, &token, 20) orelse continue;
        defer cf.c.CFRelease(data);
        const elem = ax._AXUIElementCreateWithRemoteToken(data) orelse continue;
        defer cf.c.CFRelease(elem);

        // Cheap "is this a window?" filter — non-window AX elements
        // (buttons, groups, etc.) error here. Skips ~999/1000 iterations
        // for typical apps without paying for an attribute copy.
        var wid: u32 = 0;
        if (ax._AXUIElementGetWindow(elem, &wid) != ax.kAXErrorSuccess) continue;
        if (wid == 0) continue;

        _ = try self.tryEmit(ctx, elem);

        if ((std.time.nanoTimestamp() - start_ns) > 100 * std.time.ns_per_ms) break;
    }
}

const SortCtx = struct {
    items: []common.DesktopWindow,
    keys: []SortInfo,
    pub fn lessThan(c: @This(), a: usize, b: usize) bool {
        const ka = c.keys[a];
        const kb = c.keys[b];
        if (ka.group != kb.group) return ka.group < kb.group;
        if (ka.rank != kb.rank) return ka.rank < kb.rank;
        return ka.insertion < kb.insertion;
    }
    pub fn swap(c: @This(), a: usize, b: usize) void {
        std.mem.swap(common.DesktopWindow, &c.items[a], &c.items[b]);
        std.mem.swap(SortInfo, &c.keys[a], &c.keys[b]);
    }
};

const EmitCtx = struct {
    list: *std.array_list.Managed(common.DesktopWindow),
    sort_infos: *std.ArrayListUnmanaged(SortInfo),
    allocator: std.mem.Allocator,
    cid: cgs.ConnectionID,
    space_index: *std.AutoHashMap(i64, usize),
    wid_zorder: *std.AutoHashMap(u32, u32),
    emitted_wids: *std.AutoHashMap(u32, void),
    pid: i32,
    app_name: []const u8,
    app_ordinal: i64,
    k_subrole: cf.c.CFStringRef,
    k_size: cf.c.CFStringRef,
    k_title: cf.c.CFStringRef,
    v_standard: cf.c.CFStringRef,
    v_dialog: cf.c.CFStringRef,
};

/// Applies subrole + size + wid filters to an AX window element. On pass,
/// retains the element, registers a handle, and appends a DesktopWindow.
/// Returns true on emit, false on filter rejection. Errors only on OOM /
/// allocator failure.
fn tryEmit(self: *Self, ctx: *EmitCtx, win_elem: ax.UIElementRef) !bool {
    // Cheap windowness + dedupe gate before the more expensive subrole
    // copy. Brute-force phase 2 calls _AXUIElementGetWindow already, so
    // this is redundant in that path, but it's still cheap and lets phase
    // 1 (raw kAXWindowsAttribute children) reject duplicates AX returns
    // (Mail.app at login is a known offender).
    var wid: u32 = 0;
    if (ax._AXUIElementGetWindow(win_elem, &wid) != ax.kAXErrorSuccess) return false;
    if (wid == 0) return false;
    if (ctx.emitted_wids.contains(wid)) return false;

    if (!matchesAnyString(win_elem, ctx.k_subrole, &.{ ctx.v_standard, ctx.v_dialog })) return false;

    var size_ref: cf.c.CFTypeRef = null;
    if (ax.AXUIElementCopyAttributeValue(win_elem, ctx.k_size, &size_ref) != ax.kAXErrorSuccess) return false;
    if (size_ref == null) return false;
    defer cf.c.CFRelease(size_ref);
    var size: cg.CGSize = .{ .width = 0, .height = 0 };
    if (ax.AXValueGetValue(@ptrCast(@constCast(size_ref)), ax.kAXValueTypeCGSize, &size) == 0) return false;
    if (size.width < 100 or size.height < 50) return false;

    // Resolve Space membership. Done before the title/app_id allocations
    // so the sc==0 stale-wid filter doesn't leak. sc==0 → no Space
    // binding (closed terminal sessions, etc. — drop). sc==1 → single
    // known Space; sc>1 → sticky/multi-Space (desktop_number = null).
    const space_lookup: union(enum) { drop, idx: ?usize } = blk: {
        var wid_val: c_int = @intCast(wid);
        const wid_cfnum = cf.c.CFNumberCreate(null, cf.c.kCFNumberIntType, &wid_val) orelse break :blk .{ .idx = null };
        defer cf.c.CFRelease(wid_cfnum);
        var wid_ptrs = [_]?*const anyopaque{wid_cfnum};
        const wids_arr = cf.c.CFArrayCreate(null, &wid_ptrs, 1, &cf.c.kCFTypeArrayCallBacks) orelse break :blk .{ .idx = null };
        defer cf.c.CFRelease(wids_arr);
        const spaces_arr = cgs.CGSCopySpacesForWindows(ctx.cid, cgs.SPACE_MASK_ALL, wids_arr) orelse break :blk .{ .idx = null };
        defer cf.c.CFRelease(spaces_arr);
        const sc = cg.CFArrayGetCount(@ptrCast(spaces_arr));
        if (sc == 0) break :blk .drop;
        if (sc != 1) break :blk .{ .idx = null };
        const sptr = cg.CFArrayGetValueAtIndex(@ptrCast(spaces_arr), 0) orelse break :blk .{ .idx = null };
        const sn: cf.c.CFNumberRef = @ptrCast(@constCast(sptr));
        const sid = cf.cfNumberToI64(sn) orelse break :blk .{ .idx = null };
        break :blk .{ .idx = ctx.space_index.get(sid) };
    };
    const desktop_number: ?usize = switch (space_lookup) {
        .drop => return false,
        .idx => |i| i,
    };

    const title_z: [:0]u8 = blk: {
        var title_ref: cf.c.CFTypeRef = null;
        if (ax.AXUIElementCopyAttributeValue(win_elem, ctx.k_title, &title_ref) == ax.kAXErrorSuccess and title_ref != null) {
            defer cf.c.CFRelease(title_ref);
            const s: cf.c.CFStringRef = @ptrCast(@constCast(title_ref));
            if (cf.c.CFStringGetLength(s) > 0) {
                break :blk try cf.cfStringDupeZ(ctx.allocator, s);
            }
        }
        break :blk try ctx.allocator.dupeZ(u8, ctx.app_name);
    };
    errdefer ctx.allocator.free(title_z);

    const title_lower = try ctx.allocator.allocSentinel(u8, title_z.len, 0);
    errdefer ctx.allocator.free(title_lower);
    for (title_z, 0..) |ch, i| title_lower[i] = std.ascii.toLower(ch);

    const app_id_z = try ctx.allocator.dupeZ(u8, ctx.app_name);
    errdefer ctx.allocator.free(app_id_z);

    _ = cf.c.CFRetain(win_elem);
    const idx = self.handles.items.len;
    self.handles.append(self.allocator, .{
        .pid = ctx.pid,
        .wid = wid,
        .ax_window = win_elem,
    }) catch |e| {
        cf.c.CFRelease(win_elem);
        return e;
    };

    try ctx.list.append(.{
        .platform_handle = idx,
        .title = title_z,
        .title_lower = title_lower,
        .app_id = app_id_z,
        .icon = null,
        .desktopNumber = desktop_number,
        .allocator = ctx.allocator,
    });

    const insertion: u32 = @intCast(ctx.list.items.len - 1);
    const sort_info: SortInfo = if (ctx.wid_zorder.get(wid)) |z|
        .{ .group = 0, .rank = @intCast(z), .insertion = insertion }
    else
        .{ .group = 1, .rank = -ctx.app_ordinal, .insertion = insertion };
    try ctx.sort_infos.append(ctx.allocator, sort_info);
    try ctx.emitted_wids.put(wid, {});
    return true;
}

pub fn activate(self: *Self, dw: common.DesktopWindow) void {
    if (dw.platform_handle >= self.handles.items.len) return;
    const h = self.handles.items[dw.platform_handle];
    if (h.ax_window) |w| {
        if (cfStr("AXMain")) |k_main| {
            defer cf.c.CFRelease(k_main);
            _ = ax.AXUIElementSetAttributeValue(w, k_main, cf.c.kCFBooleanTrue);
        }
        if (cfStr("AXRaise")) |k_raise| {
            defer cf.c.CFRelease(k_raise);
            _ = ax.AXUIElementPerformAction(w, k_raise);
        }
    }
    _ = bridge.vt_activate_pid(h.pid);
}

fn cfStr(s: [*:0]const u8) ?cf.c.CFStringRef {
    return cf.c.CFStringCreateWithCString(null, s, cf.c.kCFStringEncodingUTF8);
}

/// Returns true iff `attr` on `elem` resolves to a CFString equal to one of
/// `candidates` (CFStringCompare with no options).
fn matchesAnyString(
    elem: ax.UIElementRef,
    attr: cf.c.CFStringRef,
    candidates: []const cf.c.CFStringRef,
) bool {
    var ref: cf.c.CFTypeRef = null;
    if (ax.AXUIElementCopyAttributeValue(elem, attr, &ref) != ax.kAXErrorSuccess) return false;
    if (ref == null) return false;
    defer cf.c.CFRelease(ref);
    const s: cf.c.CFStringRef = @ptrCast(@constCast(ref));
    for (candidates) |c| {
        if (cf.c.CFStringCompare(s, c, 0) == 0) return true;
    }
    return false;
}
