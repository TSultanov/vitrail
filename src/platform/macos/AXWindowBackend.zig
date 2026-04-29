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
    ax_window: ax.UIElementRef, // CFRetain'd; released in clearHandles/deinit.
};

allocator: std.mem.Allocator,
handles: std.ArrayListUnmanaged(PlatformHandle) = .{},

var ax_warn_logged: bool = false;

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
    const k_main = cfStr("AXMainWindow") orelse return error.CFStringCreate;
    defer cf.c.CFRelease(k_main);
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

    var ctx = EmitCtx{
        .list = &list,
        .allocator = allocator,
        .cid = cid,
        .space_index = &space_index,
        .pid = 0,
        .app_name = "",
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

        // Try kAXWindowsAttribute first — gets all current-Space windows.
        var wins_ref: cf.c.CFTypeRef = null;
        const wins_err = ax.AXUIElementCopyAttributeValue(app_elem, k_windows, &wins_ref);
        var emitted_any = false;
        if (wins_err == ax.kAXErrorSuccess and wins_ref != null) {
            defer cf.c.CFRelease(wins_ref);
            const wins_arr: cf.c.CFArrayRef = @ptrCast(@constCast(wins_ref));
            const wcount = cg.CFArrayGetCount(@ptrCast(wins_arr));
            var wi: cg.CFIndex = 0;
            while (wi < wcount) : (wi += 1) {
                const wptr = cg.CFArrayGetValueAtIndex(@ptrCast(wins_arr), wi) orelse continue;
                const win_elem: ax.UIElementRef = @ptrCast(@constCast(wptr));
                if (try self.tryEmit(&ctx, win_elem)) emitted_any = true;
            }
        }

        // Fallback: kAXMainWindowAttribute. macOS returns an empty
        // kAXWindowsAttribute for apps whose windows live on other Spaces
        // (Focus To-Do, Safari with off-Space windows, etc.). Phantoms
        // (Calendar / Claude with no real windows) error here with
        // kAXErrorNoValue, so this is also the structural anti-phantom
        // test in the off-Space path.
        if (!emitted_any) {
            var main_ref: cf.c.CFTypeRef = null;
            if (ax.AXUIElementCopyAttributeValue(app_elem, k_main, &main_ref) == ax.kAXErrorSuccess and main_ref != null) {
                defer cf.c.CFRelease(main_ref);
                const main_elem: ax.UIElementRef = @ptrCast(@constCast(main_ref));
                _ = try self.tryEmit(&ctx, main_elem);
            }
        }
    }

    return list;
}

const EmitCtx = struct {
    list: *std.array_list.Managed(common.DesktopWindow),
    allocator: std.mem.Allocator,
    cid: cgs.ConnectionID,
    space_index: *std.AutoHashMap(i64, usize),
    pid: i32,
    app_name: []const u8,
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
    if (!matchesAnyString(win_elem, ctx.k_subrole, &.{ ctx.v_standard, ctx.v_dialog })) return false;

    var size_ref: cf.c.CFTypeRef = null;
    if (ax.AXUIElementCopyAttributeValue(win_elem, ctx.k_size, &size_ref) != ax.kAXErrorSuccess) return false;
    if (size_ref == null) return false;
    defer cf.c.CFRelease(size_ref);
    var size: cg.CGSize = .{ .width = 0, .height = 0 };
    if (ax.AXValueGetValue(@ptrCast(@constCast(size_ref)), ax.kAXValueTypeCGSize, &size) == 0) return false;
    if (size.width < 100 or size.height < 50) return false;

    var wid: u32 = 0;
    if (ax._AXUIElementGetWindow(win_elem, &wid) != ax.kAXErrorSuccess) return false;

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

    const desktop_number: ?usize = blk: {
        var wid_val: c_int = @intCast(wid);
        const wid_cfnum = cf.c.CFNumberCreate(null, cf.c.kCFNumberIntType, &wid_val) orelse break :blk null;
        defer cf.c.CFRelease(wid_cfnum);
        var wid_ptrs = [_]?*const anyopaque{wid_cfnum};
        const wids_arr = cf.c.CFArrayCreate(null, &wid_ptrs, 1, &cf.c.kCFTypeArrayCallBacks) orelse break :blk null;
        defer cf.c.CFRelease(wids_arr);
        const spaces_arr = cgs.CGSCopySpacesForWindows(ctx.cid, cgs.SPACE_MASK_ALL, wids_arr) orelse break :blk null;
        defer cf.c.CFRelease(spaces_arr);
        const sc = cg.CFArrayGetCount(@ptrCast(spaces_arr));
        if (sc != 1) break :blk null;
        const sptr = cg.CFArrayGetValueAtIndex(@ptrCast(spaces_arr), 0) orelse break :blk null;
        const sn: cf.c.CFNumberRef = @ptrCast(@constCast(sptr));
        const sid = cf.cfNumberToI64(sn) orelse break :blk null;
        break :blk ctx.space_index.get(sid);
    };

    _ = cf.c.CFRetain(win_elem);
    const idx = self.handles.items.len;
    self.handles.append(self.allocator, .{ .pid = ctx.pid, .ax_window = win_elem }) catch |e| {
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
