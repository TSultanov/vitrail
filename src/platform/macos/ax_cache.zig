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
var g_focus_ordinals: std.AutoHashMap(u32, i64) = undefined;
var g_focus_counter: i64 = 0;
var g_initialized: bool = false;

// Cached notification CFString constants (avoid re-creating per callback).
var g_n_window_created: cf.c.CFStringRef = null;
var g_n_destroyed: cf.c.CFStringRef = null;
var g_n_focused_window_changed: cf.c.CFStringRef = null;
var g_n_title_changed: cf.c.CFStringRef = null;
var g_n_window_miniaturized: cf.c.CFStringRef = null;
var g_n_window_deminiaturized: cf.c.CFStringRef = null;
var g_n_moved: cf.c.CFStringRef = null;
var g_n_enabled_changed: cf.c.CFStringRef = null;
var g_k_close_button: cf.c.CFStringRef = null;
var g_k_focused_window: cf.c.CFStringRef = null;

pub const ChangeCallback = *const fn (ctx: *anyopaque) void;
var g_change_callback: ?ChangeCallback = null;
var g_change_ctx: ?*anyopaque = null;

/// Install the main-window invalidation sink. AX observers remain
/// process-global, but the receiver is replaceable so short-lived tests can
/// safely create and destroy a MainWindow.
pub fn setChangeCallback(callback: ?ChangeCallback, ctx: ?*anyopaque) void {
    g_change_callback = callback;
    g_change_ctx = ctx;
}

fn notifyChange() void {
    const callback = g_change_callback orelse return;
    callback(g_change_ctx orelse return);
}

/// Test-only entry point for exercising the same invalidation sink used by
/// AXObserver callbacks without requiring a real application's AX element.
pub fn notifyChangeForTest() void {
    notifyChange();
}

/// Initialize the cache, seed every currently-running regular-policy app,
/// and install lifecycle observers (app launch/quit) so the cache stays
/// in sync. Idempotent — calling more than once is a no-op.
pub fn init(allocator: std.mem.Allocator) !void {
    if (g_initialized) return;
    if (ax.AXIsProcessTrusted() == 0) return; // Caller logs the warning.

    g_allocator = allocator;
    g_cache = std.AutoHashMap(i32, AppEntry).init(allocator);
    g_focus_ordinals = std.AutoHashMap(u32, i64).init(allocator);
    g_focus_counter = 0;
    g_initialized = true;

    // Bound AX call timeouts so unresponsive apps can't wedge the seed scan.
    if (ax.AXUIElementCreateSystemWide()) |sw| {
        defer cf.c.CFRelease(sw);
        _ = ax.AXUIElementSetMessagingTimeout(sw, 1.0);
    }

    g_n_window_created = cf.c.CFStringCreateWithCString(null, "AXWindowCreated", cf.c.kCFStringEncodingUTF8);
    g_n_destroyed = cf.c.CFStringCreateWithCString(null, "AXUIElementDestroyed", cf.c.kCFStringEncodingUTF8);
    g_n_focused_window_changed = cf.c.CFStringCreateWithCString(null, "AXFocusedWindowChanged", cf.c.kCFStringEncodingUTF8);
    g_n_title_changed = cf.c.CFStringCreateWithCString(null, "AXTitleChanged", cf.c.kCFStringEncodingUTF8);
    g_n_window_miniaturized = cf.c.CFStringCreateWithCString(null, "AXWindowMiniaturized", cf.c.kCFStringEncodingUTF8);
    g_n_window_deminiaturized = cf.c.CFStringCreateWithCString(null, "AXWindowDeminiaturized", cf.c.kCFStringEncodingUTF8);
    g_n_moved = cf.c.CFStringCreateWithCString(null, "AXMoved", cf.c.kCFStringEncodingUTF8);
    g_n_enabled_changed = cf.c.CFStringCreateWithCString(null, "AXEnabledChanged", cf.c.kCFStringEncodingUTF8);
    g_k_close_button = cf.c.CFStringCreateWithCString(null, "AXCloseButton", cf.c.kCFStringEncodingUTF8);
    g_k_focused_window = cf.c.CFStringCreateWithCString(null, "AXFocusedWindow", cf.c.kCFStringEncodingUTF8);

    const seed_start_ns = std.time.nanoTimestamp();
    var seeded_apps: usize = 0;
    var seeded_windows: usize = 0;

    var pid_count: c_int = 0;
    if (bridge.vt_running_pids(&pid_count)) |pids_ptr| {
        defer bridge.vt_free(@ptrCast(pids_ptr));
        if (pid_count > 0) {
            const pids = pids_ptr[0..@intCast(pid_count)];
            // Per-pid brute-force scans are independent and dominated by
            // mach-port round-trips to other processes, so they parallelise
            // well: total wall time goes from sum-of-pids to roughly the
            // slowest single pid. Workers only do AX-element discovery; the
            // observer subscription + cache insert happens on the main
            // thread once all workers join.
            const results = g_allocator.alloc(?AppEntry, pids.len) catch null;
            defer if (results) |r| g_allocator.free(r);

            if (results) |res| {
                @memset(res, null);
                const n_workers: usize = @min(pids.len, 16);
                const threads = g_allocator.alloc(std.Thread, n_workers) catch null;
                defer if (threads) |t| g_allocator.free(t);

                var ctx = ScanCtx{
                    .pids = pids,
                    .next_idx = std.atomic.Value(usize).init(0),
                    .results = res,
                };
                var spawned: usize = 0;
                if (threads) |t| {
                    while (spawned < t.len) : (spawned += 1) {
                        t[spawned] = std.Thread.spawn(.{}, scanWorker, .{&ctx}) catch break;
                    }
                    for (t[0..spawned]) |th| th.join();
                }
                // Fallback if thread spawn failed entirely: drain the queue
                // synchronously on the main thread.
                if (spawned == 0) scanWorker(&ctx);

                for (pids, 0..) |pid_c, idx| {
                    var entry = res[idx] orelse continue;
                    const pid: i32 = @intCast(pid_c);
                    installObserver(&entry, pid);
                    const win_count = entry.windows.items.len;
                    g_cache.put(pid, entry) catch {
                        releaseEntry(&entry);
                        continue;
                    };
                    recordFocusedWindow(pid, false);
                    seeded_apps += 1;
                    seeded_windows += win_count;
                }
            }
        }
    }

    bridge.vt_install_app_lifecycle_observers(onAppLaunched, onAppTerminated);

    const elapsed_ns = std.time.nanoTimestamp() - seed_start_ns;
    const elapsed_ms: u64 = @intCast(@divTrunc(elapsed_ns, std.time.ns_per_ms));
    std.log.info("AX cache seeded: {d} app(s), {d} window(s), {d} ms — vitrail ready", .{ seeded_apps, seeded_windows, elapsed_ms });
}

const ScanCtx = struct {
    pids: []const c_int,
    next_idx: std.atomic.Value(usize),
    results: []?AppEntry, // index-parallel to pids; null if scan skipped.
};

/// Worker: pulls pids off the shared atomic counter and scans each. Safe to
/// call from any thread because: (a) AX element creation/release is process-
/// global and not bound to a runloop, (b) each worker only writes to its
/// own results[idx] slot, (c) g_allocator is the caller's allocator which
/// must be thread-safe (Zig std allocators are by default).
fn scanWorker(ctx: *ScanCtx) void {
    while (true) {
        const i = ctx.next_idx.fetchAdd(1, .monotonic);
        if (i >= ctx.pids.len) return;
        const pid: i32 = @intCast(ctx.pids[i]);
        const ax_app = ax.AXUIElementCreateApplication(pid) orelse continue;
        var entry: AppEntry = .{ .ax_app = ax_app, .observer = null };
        bruteForceScanInto(&entry, pid);
        ctx.results[i] = entry;
    }
}

/// Returns the cached AX window refs for a pid, or an empty slice if the
/// pid is unknown. The returned refs are borrowed — callers must not
/// release them.
pub fn getForPid(pid: i32) []const ax.UIElementRef {
    if (!g_initialized) return &.{};
    const entry = g_cache.getPtr(pid) orelse return &.{};
    return entry.windows.items;
}

/// Returns the global focus ordinal recorded for a window. The initial value
/// is derived from app activation recency; subsequent AX focus notifications
/// monotonically promote the actual window, giving us cross-Space window MRU.
pub fn focusOrdinal(wid: u32) ?i64 {
    if (!g_initialized) return null;
    return g_focus_ordinals.get(wid);
}

/// Refresh the focused-window seed for an app during enumeration. This covers
/// apps that do not reliably deliver AXFocusedWindowChanged while preserving
/// any newer ordinal already learned from an observer notification.
pub fn seedFocusedWindow(pid: i32) void {
    if (!g_initialized) return;
    recordFocusedWindow(pid, false);
}

/// Ensure a window surfaced by ordinary AX enumeration is retained in the
/// cache and subscribed to lifecycle/metadata notifications. This closes the
/// gap for high AX-element IDs that a bounded startup scan did not reach.
/// The ref is borrowed; addWindow retains it only when it is genuinely new.
pub fn observeWindow(pid: i32, window: ax.UIElementRef) void {
    if (!g_initialized) return;
    const entry = g_cache.getPtr(pid) orelse return;
    addWindow(entry, window, pid);
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
            if (src != null) cf.c.CFRunLoopRemoveSource(cf.c.CFRunLoopGetMain(), src, cf.c.kCFRunLoopCommonModes);
            cf.c.CFRelease(obs);
        }
        for (entry.windows.items) |w| {
            if (w) |ww| cf.c.CFRelease(ww);
        }
        entry.windows.deinit(g_allocator);
        if (entry.ax_app) |a| cf.c.CFRelease(a);
    }
    g_cache.deinit();
    g_focus_ordinals.deinit();
    if (g_n_window_created) |s| cf.c.CFRelease(s);
    if (g_n_destroyed) |s| cf.c.CFRelease(s);
    if (g_n_focused_window_changed) |s| cf.c.CFRelease(s);
    if (g_n_title_changed) |s| cf.c.CFRelease(s);
    if (g_n_window_miniaturized) |s| cf.c.CFRelease(s);
    if (g_n_window_deminiaturized) |s| cf.c.CFRelease(s);
    if (g_n_moved) |s| cf.c.CFRelease(s);
    if (g_n_enabled_changed) |s| cf.c.CFRelease(s);
    if (g_k_close_button) |s| cf.c.CFRelease(s);
    if (g_k_focused_window) |s| cf.c.CFRelease(s);
    g_n_window_created = null;
    g_n_destroyed = null;
    g_n_focused_window_changed = null;
    g_n_title_changed = null;
    g_n_window_miniaturized = null;
    g_n_window_deminiaturized = null;
    g_n_moved = null;
    g_n_enabled_changed = null;
    g_k_close_button = null;
    g_k_focused_window = null;
    g_focus_counter = 0;
    g_change_callback = null;
    g_change_ctx = null;
    g_initialized = false;
}

/// Brute-force-scan a pid, build its AppEntry, and install the observer.
/// Skips pids already in the cache (no-op). Used by the app-launch
/// lifecycle path; the startup-time path goes through the parallel
/// scanner instead.
fn seedPid(pid: i32) !void {
    if (g_cache.contains(pid)) return;

    const ax_app = ax.AXUIElementCreateApplication(pid) orelse return;
    var entry: AppEntry = .{ .ax_app = ax_app, .observer = null };

    bruteForceScanInto(&entry, pid);
    installObserver(&entry, pid);

    try g_cache.put(pid, entry);
    recordFocusedWindow(pid, false);
}

/// Create the per-app AXObserver, subscribe it to window-create / focus /
/// per-window destroy notifications, and add its run-loop source to the
/// main runloop. Must run on the main thread (AXObserverAddNotification +
/// CFRunLoopAddSource interact with the runloop).
fn installObserver(entry: *AppEntry, pid: i32) void {
    var observer: ax.ObserverRef = null;
    if (ax.AXObserverCreate(pid, observerCallback, &observer) != ax.kAXErrorSuccess or observer == null) return;
    entry.observer = observer;
    const refcon: ?*anyopaque = @ptrFromInt(@as(usize, @intCast(pid)));
    _ = ax.AXObserverAddNotification(observer, entry.ax_app, g_n_window_created, refcon);
    _ = ax.AXObserverAddNotification(observer, entry.ax_app, g_n_focused_window_changed, refcon);
    for (entry.windows.items) |w| {
        subscribeWindowNotifications(observer, w, refcon);
    }
    const src = ax.AXObserverGetRunLoopSource(observer);
    if (src != null) {
        cf.c.CFRunLoopAddSource(cf.c.CFRunLoopGetMain(), src, cf.c.kCFRunLoopCommonModes);
    }
}

fn subscribeWindowNotifications(
    observer: ax.ObserverRef,
    window: ax.UIElementRef,
    refcon: ?*anyopaque,
) void {
    _ = ax.AXObserverAddNotification(observer, window, g_n_destroyed, refcon);
    _ = ax.AXObserverAddNotification(observer, window, g_n_title_changed, refcon);
    _ = ax.AXObserverAddNotification(observer, window, g_n_window_miniaturized, refcon);
    _ = ax.AXObserverAddNotification(observer, window, g_n_window_deminiaturized, refcon);
    _ = ax.AXObserverAddNotification(observer, window, g_n_moved, refcon);

    var close_button_ref: cf.c.CFTypeRef = null;
    if (ax.AXUIElementCopyAttributeValue(window, g_k_close_button, &close_button_ref) == ax.kAXErrorSuccess and close_button_ref != null) {
        defer cf.c.CFRelease(close_button_ref);
        const close_button: ax.UIElementRef = @ptrCast(@constCast(close_button_ref));
        _ = ax.AXObserverAddNotification(observer, close_button, g_n_enabled_changed, refcon);
    }
}

/// Free everything an AppEntry owns. Used when the cache insert fails
/// after a successful scan (rare — only on OOM).
fn releaseEntry(entry: *AppEntry) void {
    if (entry.observer) |obs| {
        const src = ax.AXObserverGetRunLoopSource(obs);
        if (src != null) cf.c.CFRunLoopRemoveSource(cf.c.CFRunLoopGetMain(), src, cf.c.kCFRunLoopCommonModes);
        cf.c.CFRelease(obs);
    }
    for (entry.windows.items) |w| {
        if (w) |ww| cf.c.CFRelease(ww);
    }
    entry.windows.deinit(g_allocator);
    if (entry.ax_app) |a| cf.c.CFRelease(a);
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
        if (src != null) cf.c.CFRunLoopRemoveSource(cf.c.CFRunLoopGetMain(), src, cf.c.kCFRunLoopCommonModes);
        cf.c.CFRelease(obs);
    }
    for (entry.windows.items) |w| {
        if (w) |ww| {
            var wid: u32 = 0;
            if (ax._AXUIElementGetWindow(ww, &wid) == ax.kAXErrorSuccess and wid != 0) {
                _ = g_focus_ordinals.remove(wid);
            }
            cf.c.CFRelease(ww);
        }
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
        // This notification is registered on the AXApplication, so `element`
        // is commonly the application rather than the newly focused window.
        // Read AXFocusedWindow explicitly and promote that concrete CGWindowID.
        recordFocusedWindow(pid, true);
    } else if (cf.c.CFStringCompare(notification, g_n_destroyed, 0) == 0) {
        removeWindow(entry, element);
    }
    // Creation/destruction, title changes, minimize/restore, focus, and moves
    // all flow through the same debounced refresh path. Calling this even when
    // addWindow deduped is intentional: focus/metadata can still affect order
    // or rendering.
    notifyChange();
}

fn recordFocusedWindow(pid: i32, promote: bool) void {
    const entry = g_cache.getPtr(pid) orelse return;
    var focused_ref: cf.c.CFTypeRef = null;
    if (ax.AXUIElementCopyAttributeValue(entry.ax_app, g_k_focused_window, &focused_ref) != ax.kAXErrorSuccess or focused_ref == null) return;
    defer cf.c.CFRelease(focused_ref);
    const focused: ax.UIElementRef = @ptrCast(@constCast(focused_ref));
    addWindow(entry, focused, pid);

    var wid: u32 = 0;
    if (ax._AXUIElementGetWindow(focused, &wid) != ax.kAXErrorSuccess or wid == 0) return;

    const app_ordinal = bridge.vt_app_activation_ordinal(pid);
    const seed = app_ordinal * 2 + 1;
    const ordinal = if (promote)
        @max(g_focus_counter + 1, seed)
    else
        @max(g_focus_ordinals.get(wid) orelse 0, seed);
    g_focus_ordinals.put(wid, ordinal) catch return;
    g_focus_counter = @max(g_focus_counter, ordinal);
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
        subscribeWindowNotifications(obs, win, refcon);
    }
}

fn removeWindow(entry: *AppEntry, win: ax.UIElementRef) void {
    if (win == null) return;
    var i: usize = 0;
    while (i < entry.windows.items.len) : (i += 1) {
        const existing = entry.windows.items[i];
        // Apple documents the element delivered with AXUIElementDestroyed as
        // invalid except for equality comparison; it is not guaranteed to be
        // the same pointer that was originally retained in the cache.
        if (existing == win or
            (existing != null and cf.c.CFEqual(existing, win) != 0))
        {
            var wid: u32 = 0;
            if (ax._AXUIElementGetWindow(existing, &wid) == ax.kAXErrorSuccess and wid != 0) {
                _ = g_focus_ordinals.remove(wid);
            }
            const ref = entry.windows.swapRemove(i);
            if (ref) |r| cf.c.CFRelease(r);
            return;
        }
    }
}

fn onAppLaunched(pid: c_int) callconv(.c) void {
    if (!g_initialized) return;
    seedPid(@intCast(pid)) catch {};
    notifyChange();
}

fn onAppTerminated(pid: c_int) callconv(.c) void {
    if (!g_initialized) return;
    releasePid(@intCast(pid));
    notifyChange();
}
