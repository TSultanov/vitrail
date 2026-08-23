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
const ax_cache = @import("ax_cache.zig");
const bridge = @import("bridge.zig");
const cf = @import("cf.zig");
const cgs = @import("cgs.zig");

const cg = @cImport({
    @cInclude("CoreGraphics/CoreGraphics.h");
});

const Self = @This();

const PlatformHandle = struct {
    pid: i32,
    wid: u32, // CGWindowID; 0 for windowless-app placeholders.
    ax_window: ax.UIElementRef, // CFRetain'd. Null only for windowless-app
    // placeholders (running apps with zero windows that survived AX filters).
};

allocator: std.mem.Allocator,
handles: std.ArrayListUnmanaged(PlatformHandle) = .{},

var ax_warn_logged: bool = false;

const SortInfo = struct {
    rank: i64, // negative global MRU ordinal; lower sorts first
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
    releaseHandleSlice(self.handles.items);
}

fn releaseHandleSlice(handles: []const PlatformHandle) void {
    for (handles) |h| {
        if (h.ax_window) |w| cf.c.CFRelease(w);
    }
}

pub fn pidFor(self: *const Self, idx: usize) ?i32 {
    if (idx >= self.handles.items.len) return null;
    return self.handles.items[idx].pid;
}

pub fn getWindowList(self: *Self, allocator: std.mem.Allocator) !std.array_list.Managed(common.DesktopWindow) {
    // Enumeration is transactional. Keep the resolver table for the currently
    // displayed snapshot alive until a complete replacement snapshot exists.
    // This keeps activation/context-menu commands valid if AX enumeration
    // fails midway.
    var next_handles = std.ArrayListUnmanaged(PlatformHandle){};
    errdefer {
        releaseHandleSlice(next_handles.items);
        next_handles.deinit(self.allocator);
    }

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
        self.commitHandles(&next_handles);
        return list;
    }

    // The initial permission prompt is asynchronous. If the user granted
    // Accessibility after launch, initialize the observer cache on the first
    // successful enumeration instead of requiring an application restart.
    ax_cache.init(self.allocator) catch |err| {
        std.log.warn("AX observer cache initialization failed: {s}", .{@errorName(err)});
    };

    const cid = cgs.CGSMainConnectionID();

    // Track which windows are currently onscreen. This is deliberately not a
    // sort key: doing so groups the current Space ahead of all other Spaces.
    // It is only used to distinguish stale zero-Space AX entries from live
    // full-screen windows whose Space binding is transiently unavailable.
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
    const k_focused_window = cfStr("AXFocusedWindow") orelse return error.CFStringCreate;
    defer cf.c.CFRelease(k_focused_window);
    const k_main_window = cfStr("AXMainWindow") orelse return error.CFStringCreate;
    defer cf.c.CFRelease(k_main_window);
    const k_title = cfStr("AXTitle") orelse return error.CFStringCreate;
    defer cf.c.CFRelease(k_title);
    const k_subrole = cfStr("AXSubrole") orelse return error.CFStringCreate;
    defer cf.c.CFRelease(k_subrole);
    const k_size = cfStr("AXSize") orelse return error.CFStringCreate;
    defer cf.c.CFRelease(k_size);
    const k_close_button = cfStr("AXCloseButton") orelse return error.CFStringCreate;
    defer cf.c.CFRelease(k_close_button);
    const k_enabled = cfStr("AXEnabled") orelse return error.CFStringCreate;
    defer cf.c.CFRelease(k_enabled);
    const v_standard = cfStr("AXStandardWindow") orelse return error.CFStringCreate;
    defer cf.c.CFRelease(v_standard);
    const v_dialog = cfStr("AXDialog") orelse return error.CFStringCreate;
    defer cf.c.CFRelease(v_dialog);

    var pid_count: c_int = 0;
    const pids_ptr = bridge.vt_running_pids(&pid_count) orelse {
        self.commitHandles(&next_handles);
        return list;
    };
    defer bridge.vt_free(@ptrCast(pids_ptr));
    if (pid_count <= 0) {
        self.commitHandles(&next_handles);
        return list;
    }
    const pids = pids_ptr[0..@intCast(pid_count)];

    var sort_infos = std.ArrayListUnmanaged(SortInfo){};
    defer sort_infos.deinit(allocator);

    var emitted_wids = std.AutoHashMap(u32, void).init(allocator);
    defer emitted_wids.deinit();

    var ctx = EmitCtx{
        .list = &list,
        .sort_infos = &sort_infos,
        .allocator = allocator,
        .handles_allocator = self.allocator,
        .cid = cid,
        .space_index = &space_index,
        .wid_zorder = &wid_zorder,
        .emitted_wids = &emitted_wids,
        .handles = &next_handles,
        .pid = 0,
        .app_name = "",
        .app_ordinal = 0,
        .k_subrole = k_subrole,
        .k_size = k_size,
        .k_title = k_title,
        .k_close_button = k_close_button,
        .k_enabled = k_enabled,
        .v_standard = v_standard,
        .v_dialog = v_dialog,
    };

    const self_pid: i32 = std.c.getpid();
    for (pids) |pid_c| {
        const pid: i32 = @intCast(pid_c);
        if (pid == self_pid) continue; // never list vitrail itself
        const app_elem = ax.AXUIElementCreateApplication(pid) orelse continue;
        defer cf.c.CFRelease(app_elem);

        // Resolve the app name once per pid — used as fallback title and
        // as app_id (color-hash key).
        const app_name_c = bridge.vt_app_name_for_pid(pid);
        defer if (app_name_c) |p| bridge.vt_free(@ptrCast(@constCast(p)));
        ctx.pid = pid;
        ctx.app_name = if (app_name_c) |p| std.mem.sliceTo(p, 0) else "Unknown";
        ax_cache.seedFocusedWindow(pid);
        ctx.app_ordinal = bridge.vt_app_activation_ordinal(pid);
        const list_len_before = ctx.list.items.len;

        // Phase 0: AXFocusedWindow + AXMainWindow on the AXApplication.
        // Two cheap O(1) attribute reads that surface the app's most
        // recently focused window even when the app is in the background
        // and has no kAXWindowsAttribute children. Critical for long-lived
        // apps whose AX-element-IDs have grown past the brute-force cap
        // (Safari is the canonical case — its windows live around
        // ax_id≈2500+).
        for ([_]cf.c.CFStringRef{ k_focused_window, k_main_window }) |attr| {
            var w_ref: cf.c.CFTypeRef = null;
            if (ax.AXUIElementCopyAttributeValue(app_elem, attr, &w_ref) == ax.kAXErrorSuccess and w_ref != null) {
                defer cf.c.CFRelease(w_ref);
                const win_elem: ax.UIElementRef = @ptrCast(@constCast(w_ref));
                _ = try self.tryEmit(&ctx, win_elem);
            }
        }

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

        // Phase 2: walk the AX cache. Populated at startup with a
        // high-cap brute-force scan and kept fresh via AXObservers for
        // window-create/destroy events. Discovers windows that
        // kAXWindowsAttribute hides — primarily off-Space siblings of
        // multi-window apps (Ghostty with another window on a different
        // Space, Safari with windows past the brute-force cap) and
        // single-window apps whose only window is off-Space (Focus
        // To-Do, KeePassXC).
        for (ax_cache.getForPid(pid)) |cached| {
            _ = try self.tryEmit(&ctx, cached);
        }

        // Windowless-app placeholder. macOS apps routinely outlive their
        // last window (Cmd-W keeps the app running); without this, such
        // apps would silently drop out of the switcher.
        if (ctx.list.items.len == list_len_before) {
            try self.emitAppPlaceholder(&ctx);
        }
    }

    std.sort.pdqContext(0, list.items.len, SortCtx{
        .items = list.items,
        .keys = sort_infos.items,
    });

    self.commitHandles(&next_handles);

    return list;
}

fn commitHandles(self: *Self, next_handles: *std.ArrayListUnmanaged(PlatformHandle)) void {
    std.mem.swap(std.ArrayListUnmanaged(PlatformHandle), &self.handles, next_handles);
    releaseHandleSlice(next_handles.items);
    next_handles.deinit(self.allocator);
    next_handles.* = .{};
}

const SortCtx = struct {
    items: []common.DesktopWindow,
    keys: []SortInfo,
    pub fn lessThan(c: @This(), a: usize, b: usize) bool {
        const ka = c.keys[a];
        const kb = c.keys[b];
        if (ka.rank != kb.rank) return ka.rank < kb.rank;
        return ka.insertion < kb.insertion;
    }
    pub fn swap(c: @This(), a: usize, b: usize) void {
        std.mem.swap(common.DesktopWindow, &c.items[a], &c.items[b]);
        std.mem.swap(SortInfo, &c.keys[a], &c.keys[b]);
    }
};

/// Use one rank domain for both exact window-focus observations and the
/// cold-start app-level fallback. App ordinals occupy the even values; the
/// focused window seeded for that app occupies the following odd value.
fn mruSortRank(window_ordinal: ?i64, app_ordinal: i64) i64 {
    const ordinal = window_ordinal orelse app_ordinal * 2;
    return -ordinal;
}

const EmitCtx = struct {
    list: *std.array_list.Managed(common.DesktopWindow),
    sort_infos: *std.ArrayListUnmanaged(SortInfo),
    allocator: std.mem.Allocator,
    handles_allocator: std.mem.Allocator,
    cid: cgs.ConnectionID,
    space_index: *std.AutoHashMap(i64, usize),
    wid_zorder: *std.AutoHashMap(u32, u32),
    emitted_wids: *std.AutoHashMap(u32, void),
    handles: *std.ArrayListUnmanaged(PlatformHandle),
    pid: i32,
    app_name: []const u8,
    app_ordinal: i64,
    k_subrole: cf.c.CFStringRef,
    k_size: cf.c.CFStringRef,
    k_title: cf.c.CFStringRef,
    k_close_button: cf.c.CFStringRef,
    k_enabled: cf.c.CFStringRef,
    v_standard: cf.c.CFStringRef,
    v_dialog: cf.c.CFStringRef,
};

/// Applies subrole + size + wid filters to an AX window element. On pass,
/// retains the element, registers a handle, and appends a DesktopWindow.
/// Returns true on emit, false on filter rejection. Errors only on OOM /
/// allocator failure.
fn tryEmit(_: *Self, ctx: *EmitCtx, win_elem: ax.UIElementRef) !bool {
    // Cheap windowness + dedupe gate before the more expensive subrole
    // copy. Cache walk has already filtered by _AXUIElementGetWindow, so
    // this re-check is redundant for that path — but it's still cheap and
    // dedupes between Phase 0/1/2 (the same wid surfaces from multiple
    // sources for most apps; Mail.app at login also returns dup children).
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

    // Resolve Space membership before allocating. sc==0 → no Space binding;
    // sc==1 → that Space; sc>1 → sticky (desktop_number = null).
    // sc==0 is unreliable for full-screen windows (CGSCopySpacesForWindows can
    // transiently return empty), so only drop when the window is off-screen.
    const space_lookup: union(enum) { drop, keep_unknown, idx: ?usize } = blk: {
        var wid_val: c_int = @intCast(wid);
        const wid_cfnum = cf.c.CFNumberCreate(null, cf.c.kCFNumberIntType, &wid_val) orelse break :blk .keep_unknown;
        defer cf.c.CFRelease(wid_cfnum);
        var wid_ptrs = [_]?*const anyopaque{wid_cfnum};
        const wids_arr = cf.c.CFArrayCreate(null, &wid_ptrs, 1, &cf.c.kCFTypeArrayCallBacks) orelse break :blk .keep_unknown;
        defer cf.c.CFRelease(wids_arr);
        const spaces_arr = cgs.CGSCopySpacesForWindows(ctx.cid, cgs.SPACE_MASK_ALL, wids_arr) orelse break :blk .keep_unknown;
        defer cf.c.CFRelease(spaces_arr);
        const sc = cg.CFArrayGetCount(@ptrCast(spaces_arr));
        const space_id: ?i64 = if (sc == 1) sidblk: {
            const sptr = cg.CFArrayGetValueAtIndex(@ptrCast(spaces_arr), 0) orelse break :sidblk null;
            const sn: cf.c.CFNumberRef = @ptrCast(@constCast(sptr));
            break :sidblk cf.cfNumberToI64(sn);
        } else null;
        const verdict = classifySpaceBinding(sc, space_id, ctx.wid_zorder.contains(wid));
        switch (verdict) {
            .drop => break :blk .drop,
            .keep_unknown => break :blk .keep_unknown,
            .single_space => |sid| break :blk .{ .idx = ctx.space_index.get(sid) },
        }
    };
    const desktop_number: ?usize = switch (space_lookup) {
        .drop => return false,
        .keep_unknown => null,
        .idx => |i| i,
    };
    // Phase 0/1 can surface a window whose high AX element ID was missed by
    // the bounded startup scan. Adopt it into the observer cache so later
    // self-close/title/desktop changes still invalidate the live grid.
    ax_cache.observeWindow(ctx.pid, win_elem);

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

    const app_id_lower = try ctx.allocator.allocSentinel(u8, app_id_z.len, 0);
    errdefer ctx.allocator.free(app_id_lower);
    for (app_id_z, 0..) |ch, i| app_id_lower[i] = std.ascii.toLower(ch);

    const stable_id = try std.fmt.allocPrintSentinel(
        ctx.allocator,
        "mac-window:{d}:{d}",
        .{ ctx.pid, wid },
        0,
    );
    errdefer ctx.allocator.free(stable_id);

    _ = cf.c.CFRetain(win_elem);
    const idx = ctx.handles.items.len;
    ctx.handles.append(ctx.handles_allocator, .{
        .pid = ctx.pid,
        .wid = wid,
        .ax_window = win_elem,
    }) catch |e| {
        cf.c.CFRelease(win_elem);
        return e;
    };

    // Make the descriptor append the final fallible ownership transfer. If
    // sort/map growth fails first, the local errdefers still own every string;
    // once append succeeds this function cannot fail and the list owns them.
    const insertion: u32 = @intCast(ctx.list.items.len);
    const sort_info: SortInfo = .{
        .rank = mruSortRank(ax_cache.focusOrdinal(wid), ctx.app_ordinal),
        .insertion = insertion,
    };
    try ctx.sort_infos.append(ctx.allocator, sort_info);
    try ctx.emitted_wids.put(wid, {});
    try ctx.list.append(.{
        .stable_id = stable_id,
        .platform_handle = idx,
        .title = title_z,
        .title_lower = title_lower,
        .app_id = app_id_z,
        .app_id_lower = app_id_lower,
        .icon = null,
        .desktopNumber = desktop_number,
        .can_close = hasUsableCloseButton(win_elem, ctx.k_close_button, ctx.k_enabled),
        .allocator = ctx.allocator,
    });
    return true;
}

/// Emit a synthetic entry representing a running app with no surviving
/// windows. Activation routes through `vt_activate_pid`, which lets the
/// OS deliver `applicationShouldHandleReopen:hasVisibleWindows:NO` so
/// the target app reopens its main window per its own conventions.
fn emitAppPlaceholder(_: *Self, ctx: *EmitCtx) !void {
    const title_z = try ctx.allocator.dupeZ(u8, ctx.app_name);
    errdefer ctx.allocator.free(title_z);

    const title_lower = try ctx.allocator.allocSentinel(u8, title_z.len, 0);
    errdefer ctx.allocator.free(title_lower);
    for (title_z, 0..) |ch, i| title_lower[i] = std.ascii.toLower(ch);

    const app_id_z = try ctx.allocator.dupeZ(u8, ctx.app_name);
    errdefer ctx.allocator.free(app_id_z);

    const app_id_lower = try ctx.allocator.allocSentinel(u8, app_id_z.len, 0);
    errdefer ctx.allocator.free(app_id_lower);
    for (app_id_z, 0..) |ch, i| app_id_lower[i] = std.ascii.toLower(ch);

    const stable_id = try std.fmt.allocPrintSentinel(
        ctx.allocator,
        "mac-app:{d}",
        .{ctx.pid},
        0,
    );
    errdefer ctx.allocator.free(stable_id);

    const idx = ctx.handles.items.len;
    try ctx.handles.append(ctx.handles_allocator, .{
        .pid = ctx.pid,
        .wid = 0,
        .ax_window = null,
    });

    const insertion: u32 = @intCast(ctx.list.items.len);
    try ctx.sort_infos.append(ctx.allocator, .{
        .rank = mruSortRank(null, ctx.app_ordinal),
        .insertion = insertion,
    });
    try ctx.list.append(.{
        .stable_id = stable_id,
        .platform_handle = idx,
        .title = title_z,
        .title_lower = title_lower,
        .app_id = app_id_z,
        .app_id_lower = app_id_lower,
        .icon = null,
        .desktopNumber = null,
        .can_close = false,
        .allocator = ctx.allocator,
    });
}

pub fn activate(self: *Self, dw: common.DesktopWindow) void {
    const h = self.resolve(dw) orelse return;
    if (h.ax_window) |w| {
        var current_wid: u32 = 0;
        if (ax._AXUIElementGetWindow(w, &current_wid) != ax.kAXErrorSuccess or current_wid != h.wid) return;
        if (cfStr("AXMain")) |k_main| {
            defer cf.c.CFRelease(k_main);
            _ = ax.AXUIElementSetAttributeValue(w, k_main, cf.c.kCFBooleanTrue);
        }
        if (cfStr("AXRaise")) |k_raise| {
            defer cf.c.CFRelease(k_raise);
            _ = ax.AXUIElementPerformAction(w, k_raise);
        }
        _ = bridge.vt_activate_pid(h.pid);
    } else {
        // Windowless-app placeholder. Plain activate* APIs only swap the
        // menubar; the app's reopen handler (which is what spawns a new
        // window for Mail/Calendar/Preview) only fires when the OS routes
        // through Launch Services. vt_reopen_pid does that.
        _ = bridge.vt_reopen_pid(h.pid);
    }
}

/// Gracefully close the exact current window identified by the descriptor.
/// The stable ID is re-resolved against the atomically committed handle table
/// and the AX element's current CGWindowID is validated before pressing its
/// standard close button.
pub fn close(self: *Self, dw: common.DesktopWindow) void {
    const h = self.resolve(dw) orelse return;
    const window = h.ax_window orelse return;

    var current_wid: u32 = 0;
    if (ax._AXUIElementGetWindow(window, &current_wid) != ax.kAXErrorSuccess or current_wid != h.wid) return;

    const k_close_button = cfStr("AXCloseButton") orelse return;
    defer cf.c.CFRelease(k_close_button);
    const k_enabled = cfStr("AXEnabled") orelse return;
    defer cf.c.CFRelease(k_enabled);
    const close_button = copyUsableCloseButton(window, k_close_button, k_enabled) orelse return;
    defer cf.c.CFRelease(close_button);

    const k_press = cfStr("AXPress") orelse return;
    defer cf.c.CFRelease(k_press);
    _ = ax.AXUIElementPerformAction(close_button, k_press);
}

fn resolve(self: *const Self, dw: common.DesktopWindow) ?PlatformHandle {
    if (dw.platform_handle < self.handles.items.len) {
        const candidate = self.handles.items[dw.platform_handle];
        if (handleMatchesStableId(candidate, dw.stable_id)) return candidate;
    }
    for (self.handles.items) |candidate| {
        if (handleMatchesStableId(candidate, dw.stable_id)) return candidate;
    }
    return null;
}

fn handleMatchesStableId(handle: PlatformHandle, stable_id: []const u8) bool {
    var buf: [96]u8 = undefined;
    const expected = if (handle.wid == 0)
        std.fmt.bufPrint(&buf, "mac-app:{d}", .{handle.pid}) catch return false
    else
        std.fmt.bufPrint(&buf, "mac-window:{d}:{d}", .{ handle.pid, handle.wid }) catch return false;
    return std.mem.eql(u8, expected, stable_id);
}

fn hasUsableCloseButton(
    window: ax.UIElementRef,
    k_close_button: cf.c.CFStringRef,
    k_enabled: cf.c.CFStringRef,
) bool {
    const button = copyUsableCloseButton(window, k_close_button, k_enabled) orelse return false;
    cf.c.CFRelease(button);
    return true;
}

fn copyUsableCloseButton(
    window: ax.UIElementRef,
    k_close_button: cf.c.CFStringRef,
    k_enabled: cf.c.CFStringRef,
) ax.UIElementRef {
    var button_ref: cf.c.CFTypeRef = null;
    if (ax.AXUIElementCopyAttributeValue(window, k_close_button, &button_ref) != ax.kAXErrorSuccess or button_ref == null) {
        return null;
    }
    const button: ax.UIElementRef = @ptrCast(@constCast(button_ref));

    var enabled_ref: cf.c.CFTypeRef = null;
    if (ax.AXUIElementCopyAttributeValue(button, k_enabled, &enabled_ref) == ax.kAXErrorSuccess and enabled_ref != null) {
        defer cf.c.CFRelease(enabled_ref);
        const enabled: cf.c.CFBooleanRef = @ptrCast(@constCast(enabled_ref));
        if (cf.c.CFBooleanGetValue(enabled) == 0) {
            cf.c.CFRelease(button_ref);
            return null;
        }
    }
    return button;
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

/// How a window's Space binding decides whether to keep it. sc==0 (no Space)
/// is only treated as "stale, closed" when the window is off-screen; full-screen
/// windows can transiently report zero Spaces while still on-screen, and must
/// not be dropped or the switcher shows them intermittently.
const SpaceBindingVerdict = union(enum) {
    drop,
    keep_unknown,
    single_space: i64,
};

fn classifySpaceBinding(sc: cg.CFIndex, space_id: ?i64, on_screen: bool) SpaceBindingVerdict {
    if (sc == 0) {
        if (on_screen) return .keep_unknown;
        return .drop;
    }
    if (sc != 1) return .keep_unknown;
    return .{ .single_space = space_id orelse return .keep_unknown };
}

test "classifySpaceBinding keeps on-screen windows with an empty Space binding" {
    // Full-screen windows can transiently report zero Spaces while on-screen;
    // dropping them made only one of several same-named full-screen windows show.
    const verdict = classifySpaceBinding(0, null, true);
    try std.testing.expectEqual(SpaceBindingVerdict.keep_unknown, verdict);
}

test "classifySpaceBinding drops off-screen windows with no Space binding" {
    const verdict = classifySpaceBinding(0, null, false);
    try std.testing.expectEqual(SpaceBindingVerdict.drop, verdict);
}

test "classifySpaceBinding resolves a single Space binding" {
    const verdict = classifySpaceBinding(1, 206, false);
    try std.testing.expectEqual(SpaceBindingVerdict{ .single_space = 206 }, verdict);
}

test "classifySpaceBinding keeps sticky multi-Space windows with unknown desktop" {
    const verdict = classifySpaceBinding(3, null, false);
    try std.testing.expectEqual(SpaceBindingVerdict.keep_unknown, verdict);
}

test "window focus MRU outranks app fallback regardless of Space" {
    try std.testing.expect(mruSortRank(43, 1) < mruSortRank(null, 20));
}

test "cold-start fallback follows app activation MRU" {
    try std.testing.expect(mruSortRank(null, 20) < mruSortRank(null, 10));
}
