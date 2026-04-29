// Process-wide AX-element cache. Keyed by pid. Populated at startup via a
// high-cap brute-force scan; kept fresh via AXObservers subscribed to
// kAXWindowCreated, kAXUIElementDestroyed, and kAXFocusedWindowChanged on
// each running application's AX element.
//
// This replaces per-call brute-force scans in the production path. After
// init() returns, getForPid(pid) is a fast cache walk (<1 ms) regardless
// of how long the app has been running — long-lived apps whose AX-element
// IDs are past 1000 (Safari at ~2500+ in practice) get full coverage.
//
// Threading: everything runs on the main runloop. AXObserver run-loop
// sources are added to CFRunLoopGetMain(), so callbacks fire on the same
// thread that calls getForPid. No locks needed.

const std = @import("std");
const ax = @import("ax.zig");
const bridge = @import("bridge.zig");
const cf = @import("cf.zig");

// Higher than the per-call brute-force cap (1000). The startup seed is
// paid once while vitrail's UI is hidden, so a few seconds of total
// scanning is invisible to the user.
const SCAN_CAP: u64 = 10000;
const SCAN_TIMEOUT_NS: i128 = 1 * std.time.ns_per_s;

const AppEntry = struct {
    ax_app: ax.UIElementRef, // CFRetain'd at insert.
    observer: ax.ObserverRef, // Retained by AXObserverCreate.
    windows: std.ArrayListUnmanaged(ax.UIElementRef) = .{},
};

var g_allocator: std.mem.Allocator = undefined;
var g_cache: std.AutoHashMap(i32, AppEntry) = undefined;
var g_initialized: bool = false;

// Cached notification CFString constants (avoid re-creating per callback).
var g_n_window_created: cf.c.CFStringRef = null;
var g_n_destroyed: cf.c.CFStringRef = null;
var g_n_focused_window_changed: cf.c.CFStringRef = null;

/// Initialize the cache, seed every currently-running regular-policy app,
/// and install lifecycle observers (app launch/quit) so the cache stays
/// in sync. Idempotent — calling more than once is a no-op.
pub fn init(allocator: std.mem.Allocator) !void {
    if (g_initialized) return;
    if (ax.AXIsProcessTrusted() == 0) return; // Caller logs the warning.

    g_allocator = allocator;
    g_cache = std.AutoHashMap(i32, AppEntry).init(allocator);
    g_initialized = true;

    // Bound AX call timeouts so unresponsive apps can't wedge the seed scan.
    if (ax.AXUIElementCreateSystemWide()) |sw| {
        defer cf.c.CFRelease(sw);
        _ = ax.AXUIElementSetMessagingTimeout(sw, 1.0);
    }

    g_n_window_created = cf.c.CFStringCreateWithCString(null, "AXWindowCreated", cf.c.kCFStringEncodingUTF8);
    g_n_destroyed = cf.c.CFStringCreateWithCString(null, "AXUIElementDestroyed", cf.c.kCFStringEncodingUTF8);
    g_n_focused_window_changed = cf.c.CFStringCreateWithCString(null, "AXFocusedWindowChanged", cf.c.kCFStringEncodingUTF8);

    var pid_count: c_int = 0;
    if (bridge.vt_running_pids(&pid_count)) |pids_ptr| {
        defer bridge.vt_free(@ptrCast(pids_ptr));
        if (pid_count > 0) {
            const pids = pids_ptr[0..@intCast(pid_count)];
            for (pids) |pid_c| {
                seedPid(@intCast(pid_c)) catch continue;
            }
        }
    }

    bridge.vt_install_app_lifecycle_observers(onAppLaunched, onAppTerminated);
}

/// Returns the cached AX window refs for a pid, or an empty slice if the
/// pid is unknown. The returned refs are borrowed — callers must not
/// release them.
pub fn getForPid(pid: i32) []const ax.UIElementRef {
    if (!g_initialized) return &.{};
    const entry = g_cache.getPtr(pid) orelse return &.{};
    return entry.windows.items;
}

/// Tear down every cached entry, release all retained AX refs and observer
/// run-loop sources, and reset to the uninitialized state. Production
/// long-running app doesn't call this — it relies on process teardown —
/// but short-lived diagnostic binaries (dump_windows) need it to keep
/// the GPA leak detector quiet.
pub fn deinit() void {
    if (!g_initialized) return;
    var it = g_cache.iterator();
    while (it.next()) |kv| {
        var entry = kv.value_ptr.*;
        if (entry.observer) |obs| {
            const src = ax.AXObserverGetRunLoopSource(obs);
            if (src != null) cf.c.CFRunLoopRemoveSource(cf.c.CFRunLoopGetMain(), src, cf.c.kCFRunLoopDefaultMode);
            cf.c.CFRelease(obs);
        }
        for (entry.windows.items) |w| {
            if (w) |ww| cf.c.CFRelease(ww);
        }
        entry.windows.deinit(g_allocator);
        if (entry.ax_app) |a| cf.c.CFRelease(a);
    }
    g_cache.deinit();
    if (g_n_window_created) |s| cf.c.CFRelease(s);
    if (g_n_destroyed) |s| cf.c.CFRelease(s);
    if (g_n_focused_window_changed) |s| cf.c.CFRelease(s);
    g_n_window_created = null;
    g_n_destroyed = null;
    g_n_focused_window_changed = null;
    g_initialized = false;
}

/// Brute-force-scan a pid, build its AppEntry, and install the observer.
/// Skips pids already in the cache (no-op).
fn seedPid(pid: i32) !void {
    if (g_cache.contains(pid)) return;

    const ax_app = ax.AXUIElementCreateApplication(pid) orelse return;
    var entry: AppEntry = .{ .ax_app = ax_app, .observer = null };

    bruteForceScanInto(&entry, pid);

    var observer: ax.ObserverRef = null;
    if (ax.AXObserverCreate(pid, observerCallback, &observer) == ax.kAXErrorSuccess and observer != null) {
        entry.observer = observer;
        const refcon: ?*anyopaque = @ptrFromInt(@as(usize, @intCast(pid)));
        _ = ax.AXObserverAddNotification(observer, ax_app, g_n_window_created, refcon);
        _ = ax.AXObserverAddNotification(observer, ax_app, g_n_focused_window_changed, refcon);
        for (entry.windows.items) |w| {
            _ = ax.AXObserverAddNotification(observer, w, g_n_destroyed, refcon);
        }
        const src = ax.AXObserverGetRunLoopSource(observer);
        if (src != null) {
            cf.c.CFRunLoopAddSource(cf.c.CFRunLoopGetMain(), src, cf.c.kCFRunLoopDefaultMode);
        }
    }

    try g_cache.put(pid, entry);
}

/// Iterates ax-element-id 0..SCAN_CAP using the private remote-token API,
/// retains every element that returns a non-zero CGWindowID, appends to
/// `entry.windows`. Stops at SCAN_TIMEOUT_NS. Mirrors the production
/// brute-force in AXWindowBackend but at a higher cap and timeout.
fn bruteForceScanInto(entry: *AppEntry, pid: i32) void {
    var token: [20]u8 = std.mem.zeroes([20]u8);
    std.mem.writeInt(i32, token[0..4], pid, .little);
    std.mem.writeInt(i32, token[8..12], 0x636f636f, .little);

    const start_ns = std.time.nanoTimestamp();
    var ax_id: u64 = 0;
    while (ax_id < SCAN_CAP) : (ax_id += 1) {
        std.mem.writeInt(u64, token[12..20], ax_id, .little);
        const data = cf.c.CFDataCreate(null, &token, 20) orelse continue;
        defer cf.c.CFRelease(data);
        const elem = ax._AXUIElementCreateWithRemoteToken(data) orelse continue;

        var wid: u32 = 0;
        if (ax._AXUIElementGetWindow(elem, &wid) != ax.kAXErrorSuccess or wid == 0) {
            cf.c.CFRelease(elem);
            continue;
        }

        // Element survives — keep the +1 retain and append.
        entry.windows.append(g_allocator, elem) catch {
            cf.c.CFRelease(elem);
        };

        if ((std.time.nanoTimestamp() - start_ns) > SCAN_TIMEOUT_NS) break;
    }
}

fn releasePid(pid: i32) void {
    const kv = g_cache.fetchRemove(pid) orelse return;
    var entry = kv.value;
    if (entry.observer) |obs| {
        const src = ax.AXObserverGetRunLoopSource(obs);
        if (src != null) cf.c.CFRunLoopRemoveSource(cf.c.CFRunLoopGetMain(), src, cf.c.kCFRunLoopDefaultMode);
        cf.c.CFRelease(obs);
    }
    for (entry.windows.items) |w| {
        if (w) |ww| cf.c.CFRelease(ww);
    }
    entry.windows.deinit(g_allocator);
    if (entry.ax_app) |a| cf.c.CFRelease(a);
}

fn observerCallback(
    observer: ax.ObserverRef,
    element: ax.UIElementRef,
    notification: cf.c.CFStringRef,
    refcon: ?*anyopaque,
) callconv(.c) void {
    _ = observer;
    if (refcon == null) return;
    const pid: i32 = @intCast(@intFromPtr(refcon));
    const entry = g_cache.getPtr(pid) orelse return;

    if (cf.c.CFStringCompare(notification, g_n_window_created, 0) == 0) {
        addWindow(entry, element, pid);
    } else if (cf.c.CFStringCompare(notification, g_n_focused_window_changed, 0) == 0) {
        addWindow(entry, element, pid);
    } else if (cf.c.CFStringCompare(notification, g_n_destroyed, 0) == 0) {
        removeWindow(entry, element);
    }
}

fn addWindow(entry: *AppEntry, win: ax.UIElementRef, pid: i32) void {
    if (win == null) return;
    var wid: u32 = 0;
    if (ax._AXUIElementGetWindow(win, &wid) != ax.kAXErrorSuccess or wid == 0) return;
    for (entry.windows.items) |existing| {
        var ewid: u32 = 0;
        if (ax._AXUIElementGetWindow(existing, &ewid) == ax.kAXErrorSuccess and ewid == wid) return;
    }
    _ = cf.c.CFRetain(win);
    entry.windows.append(g_allocator, win) catch {
        cf.c.CFRelease(win);
        return;
    };
    if (entry.observer) |obs| {
        const refcon: ?*anyopaque = @ptrFromInt(@as(usize, @intCast(pid)));
        _ = ax.AXObserverAddNotification(obs, win, g_n_destroyed, refcon);
    }
}

fn removeWindow(entry: *AppEntry, win: ax.UIElementRef) void {
    if (win == null) return;
    var i: usize = 0;
    while (i < entry.windows.items.len) : (i += 1) {
        if (entry.windows.items[i] == win) {
            const ref = entry.windows.swapRemove(i);
            if (ref) |r| cf.c.CFRelease(r);
            return;
        }
    }
}

fn onAppLaunched(pid: c_int) callconv(.c) void {
    if (!g_initialized) return;
    seedPid(@intCast(pid)) catch {};
}

fn onAppTerminated(pid: c_int) callconv(.c) void {
    if (!g_initialized) return;
    releasePid(@intCast(pid));
}
