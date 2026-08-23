const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform.zig");
const common = @import("common/DesktopWindow.zig");

const MainWindow = platform.MainWindow;
const SystemInteraction = platform.SystemInteraction;

const Self = @This();

allocator: std.mem.Allocator,
view: *MainWindow,
desktop_windows: ?std.array_list.Managed(common.DesktopWindow) = null,
test_mode: bool = false,
refresh_in_progress: bool = false,
refresh_pending: bool = false,

window_callbacks: MainWindow.Callbacks = .{
    .activateWindow = activateWindow,
    .closeWindow = closeWindow,
    .quitApplication = quitApplication,
    .refreshWindows = refreshWindows,
    .retryShow = retryShow,
    .hide = hide,
    .openSettings = openSettings,
},
si: SystemInteraction,

// Set by the platform entry point: invoked (after the overlay is hidden) when
// the user asks to open settings from the overlay. The entry point owns the
// settings window + the hotkey/mouse-hook re-binding, which are platform-
// specific, so the presenter just forwards the request.
on_open_settings: ?*const fn (ctx: *anyopaque) void = null,
on_open_settings_ctx: *anyopaque = undefined,

pub fn init(args: platform.PlatformArgs, allocator: std.mem.Allocator, test_mode: bool) !*Self {
    var self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .view = undefined,
        .si = try SystemInteraction.init(allocator),
        .test_mode = test_mode,
    };
    errdefer self.si.deinit();

    if (builtin.target.os.tag == .windows) {
        self.si.bindLifecycleTracker();
    }

    self.view = try MainWindow.create(args, &self.window_callbacks, self.allocator);
    if (builtin.target.os.tag == .linux) {
        self.view.setWindowEventFd(self.si.eventFd());
    }

    return self;
}

fn createWidgets(self: *Self) !void {
    self.view.activate();
    var fresh = try self.si.getWindowList(self.allocator);
    var committed = false;
    defer if (!committed) destroyWindowList(&fresh);

    if (fresh.items.len == 0) {
        try self.dismissEmpty();
        return;
    }

    try self.view.setDesktopWindows(fresh.items);
    self.desktop_windows = fresh;
    committed = true;

    // Only pump input inside KDE enumeration waits after the presenter owns
    // its first snapshot. During initial enumeration there is no grid session
    // for input to act on or safely dismiss.
    if (builtin.target.os.tag == .linux) {
        self.si.setRefreshWaitPump(MainWindow.pumpRefreshWait, self.view);
    }

    // Some Linux backends must pump their notification connection while
    // enumerating. If that consumed a change newer than the committed
    // snapshot, reconcile it immediately even on the initial show.
    if (builtin.target.os.tag == .linux and self.si.hasPendingChanges()) {
        self.refreshWindowList() catch |err| {
            std.log.warn("initial trailing window refresh failed: {s}", .{@errorName(err)});
        };
    }
}

fn activateWindow(main_window: *MainWindow, dw: common.DesktopWindow) !void {
    const self: *Self = @fieldParentPtr("window_callbacks", main_window.callbacks);
    self.si.activateWindow(dw);
    try hide(self.view);
}

fn closeWindow(main_window: *MainWindow, stable_id: []const u8) !void {
    const self: *Self = @fieldParentPtr("window_callbacks", main_window.callbacks);
    const dw = self.windowById(stable_id) orelse return;
    if (!dw.can_close) return;
    self.si.closeWindow(dw);
    // Closing is asynchronous on macOS, and some applications do not deliver
    // every AX lifecycle notification reliably. Schedule the same coalesced
    // reconciliation used by external window-change events as a fallback.
    if (builtin.target.os.tag == .macos) main_window.scheduleRefresh();
    // A synchronous Linux backend call can pump and drain its notification
    // connection while issuing the request. Reconcile any generic change it
    // observed instead of waiting for an fd edge that has already been read.
    if (builtin.target.os.tag == .linux and self.si.hasPendingChanges()) {
        try self.refreshWindowList();
    }
}

fn quitApplication(main_window: *MainWindow, stable_id: []const u8) !void {
    const self: *Self = @fieldParentPtr("window_callbacks", main_window.callbacks);
    const dw = self.windowById(stable_id) orelse return;
    self.si.quitApplication(dw);
    // Application termination is asynchronous on macOS. Keep the same
    // reconciliation fallback used by Close window for apps with incomplete
    // accessibility lifecycle notifications.
    if (builtin.target.os.tag == .macos) main_window.scheduleRefresh();
    if (builtin.target.os.tag == .linux and self.si.hasPendingChanges()) {
        try self.refreshWindowList();
    }
}

fn refreshWindows(main_window: *MainWindow) !void {
    const self: *Self = @fieldParentPtr("window_callbacks", main_window.callbacks);
    try self.refreshWindowList();
}

fn retryShow(main_window: *MainWindow, at_cursor: bool) !void {
    const self: *Self = @fieldParentPtr("window_callbacks", main_window.callbacks);
    if (at_cursor) {
        try self.showAtCursor();
    } else {
        try self.show();
    }
}

pub fn refreshWindowList(self: *Self) !void {
    if (self.desktop_windows == null) return;
    if (self.refresh_in_progress) {
        self.refresh_pending = true;
        return;
    }

    self.refresh_in_progress = true;
    defer self.refresh_in_progress = false;

    while (true) {
        self.refresh_pending = false;
        if (builtin.target.os.tag == .linux) self.si.dispatchPending();
        try self.refreshOnce();
        if (builtin.target.os.tag == .linux and self.si.hasPendingChanges()) {
            self.refresh_pending = true;
        }
        if (!self.refresh_pending or self.desktop_windows == null) break;
    }
}

fn refreshOnce(self: *Self) !void {
    var fresh = try self.si.getWindowList(self.allocator);
    var committed = false;
    defer if (!committed) destroyWindowList(&fresh);

    // KDE enumeration pumps the overlay's Wayland connection while waiting.
    // A delivered click/key event may hide the overlay and release the old
    // snapshot reentrantly, so resolve ownership only after that wait.
    const current = self.desktop_windows orelse return;

    try self.reconcileOrder(current.items, &fresh);

    if (fresh.items.len == 0) {
        try hide(self.view);
        return;
    }

    try self.view.refreshDesktopWindows(fresh.items);
    var old = current;
    self.desktop_windows = fresh;
    committed = true;
    destroyWindowList(&old);
}

/// Preserve surviving windows' relative order for the lifetime of the visible
/// overlay and append genuinely new windows in backend enumeration order.
fn reconcileOrder(
    self: *Self,
    old: []const common.DesktopWindow,
    fresh: *std.array_list.Managed(common.DesktopWindow),
) !void {
    if (fresh.items.len < 2 or old.len == 0) return;

    const used = try self.allocator.alloc(bool, fresh.items.len);
    defer self.allocator.free(used);
    @memset(used, false);

    var ordered = std.array_list.Managed(common.DesktopWindow).init(self.allocator);
    errdefer ordered.deinit();
    try ordered.ensureTotalCapacity(fresh.items.len);

    for (old) |previous| {
        for (fresh.items, 0..) |candidate, idx| {
            if (used[idx]) continue;
            if (!std.mem.eql(u8, previous.stable_id, candidate.stable_id)) continue;
            ordered.appendAssumeCapacity(candidate);
            used[idx] = true;
            break;
        }
    }
    for (fresh.items, 0..) |candidate, idx| {
        if (!used[idx]) ordered.appendAssumeCapacity(candidate);
    }

    // Ownership of every descriptor moved into `ordered`; only discard the
    // old array-list storage.
    fresh.deinit();
    fresh.* = ordered;
}

fn windowById(self: *Self, stable_id: []const u8) ?common.DesktopWindow {
    const windows = self.desktop_windows orelse return null;
    for (windows.items) |dw| {
        if (std.mem.eql(u8, dw.stable_id, stable_id)) return dw;
    }
    return null;
}

/// Register the platform handler that actually presents the settings window.
pub fn setOpenSettings(self: *Self, cb: *const fn (ctx: *anyopaque) void, ctx: *anyopaque) void {
    self.on_open_settings = cb;
    self.on_open_settings_ctx = ctx;
}

fn openSettings(main_window: *MainWindow) !void {
    const self: *Self = @fieldParentPtr("window_callbacks", main_window.callbacks);
    // Dismiss the overlay first, then hand off to the platform entry point.
    try hide(self.view);
    if (self.on_open_settings) |cb| cb(self.on_open_settings_ctx);
}

fn hide(main_window: *MainWindow) !void {
    const self: *Self = @fieldParentPtr("window_callbacks", main_window.callbacks);

    try self.view.hideBoxes();

    if (self.desktop_windows) |desktop_windows| {
        var owned = desktop_windows;
        destroyWindowList(&owned);
        self.desktop_windows = null;
    }

    // On Wayland the launch-on-demand model means hide ⇒ exit (the
    // compositor's hotkey re-launches the binary). On Windows the binary
    // stays resident so the registered Alt+Space hotkey can re-show it,
    // unless test_mode forces an exit.
    if (builtin.target.os.tag == .linux or self.test_mode) {
        self.view.requestQuit();
    }
}

fn dismissEmpty(self: *Self) !void {
    try self.view.hideBoxes();
    if (builtin.target.os.tag == .linux or self.test_mode) {
        self.view.requestQuit();
    }
}

pub fn isVisible(self: *const Self) bool {
    return self.desktop_windows != null;
}

pub fn show(self: *Self) !void {
    if (self.desktop_windows != null) return;
    try self.view.show();
    try self.createWidgets();
}

/// Like `show`, but positions the overlay on the pointer's display and centers
/// the grid under the cursor. Used by the mouse-button trigger when the
/// `center_on_cursor` option is enabled.
pub fn showAtCursor(self: *Self) !void {
    if (self.desktop_windows != null) return;
    try self.view.showAtCursor();
    try self.createWidgets();
}

pub fn deinit(self: *Self) void {
    if (self.desktop_windows) |dws| {
        var owned = dws;
        destroyWindowList(&owned);
        self.desktop_windows = null;
    }
    self.si.deinit();
    self.view.deinit();
    self.allocator.destroy(self);
}

fn destroyWindowList(list: *std.array_list.Managed(common.DesktopWindow)) void {
    for (list.items) |dw| dw.destroy();
    list.deinit();
}
