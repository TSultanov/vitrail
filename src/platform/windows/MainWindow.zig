const std = @import("std");
const wh = @import("windows.zig");
const w = wh.c;
const sys = @import("SystemInteraction.zig");
const input = @import("../../common/InputAction.zig");
const common = @import("../../common/DesktopWindow.zig");
const Grid = @import("../../common/Grid.zig");
pub const Window = @import("Window.zig");
pub const Layout = @import("Layout.zig");

const Self = @This();

const WM_VITRAIL_WINDOWS_CHANGED: w.UINT = @as(w.UINT, @intCast(w.WM_APP)) + 2;
const REFRESH_TIMER_ID: usize = 0x56545246; // "VTRF"
const REFRESH_DEBOUNCE_MS: w.UINT = 100;
const CONTEXT_CLOSE_COMMAND: usize = @intFromEnum(input.ContextCommand.close_window);
const CONTEXT_QUIT_COMMAND: usize = @intFromEnum(input.ContextCommand.quit_application);

// SetWinEventHook's callback has no context pointer. Only one resident Vitrail
// overlay exists, so its HWND is the narrow bridge used to post a private
// message back to the owning UI thread.
var event_sink_hwnd: w.HWND = null;

pub const PlatformArgs = struct {
    hInstance: w.HINSTANCE,
};

pub const Callbacks = struct {
    activateWindow: *const fn (main_window: *Self, dw: common.DesktopWindow) anyerror!void,
    closeWindow: *const fn (main_window: *Self, stable_id: []const u8) anyerror!void,
    quitApplication: *const fn (main_window: *Self, stable_id: []const u8) anyerror!void,
    refreshWindows: *const fn (main_window: *Self) anyerror!void,
    retryShow: *const fn (main_window: *Self, at_cursor: bool) anyerror!void,
    hide: *const fn (main_window: *Self) anyerror!void,
    openSettings: *const fn (main_window: *Self) anyerror!void,
};

window: *Window,
layout: *Layout,
event_handlers: Window.EventHandlers,
// Borrowed from MainPresenter. MainWindow and Grid never free descriptors.
desktop_windows: ?[]const common.DesktopWindow,
hInstance: w.HINSTANCE,
allocator: std.mem.Allocator,
callbacks: *Callbacks,
win_event_hook: w.HWINEVENTHOOK = null,
cloak_event_hook: w.HWINEVENTHOOK = null,
desktop_event_hook: w.HWINEVENTHOOK = null,
refresh_dirty: bool = false,
refresh_timer_armed: bool = false,
menu_tracking: bool = false,

// Bridge from Layout up to this MainWindow. Layout calls .activate when a
// tile is clicked / Enter-pressed and .visibility_changed when the search
// filter or window list changes the visible tile set; we recover *Self via
// @fieldParentPtr.
layout_callbacks: Layout.Callbacks = .{
    .activate = onLayoutActivate,
    .context_menu = onLayoutContextMenu,
    .visibility_changed = onLayoutVisibilityChanged,
},

fn onLayoutActivate(cbs: *Layout.Callbacks, dw: common.DesktopWindow) !void {
    const self: *Self = @fieldParentPtr("layout_callbacks", cbs);
    try self.callbacks.activateWindow(self, dw);
}

fn onLayoutContextMenu(
    cbs: *Layout.Callbacks,
    stable_id: []const u8,
    can_close: bool,
    screen_x: c_int,
    screen_y: c_int,
) !void {
    const self: *Self = @fieldParentPtr("layout_callbacks", cbs);
    try self.showContextMenu(stable_id, can_close, screen_x, screen_y);
}

fn onLayoutVisibilityChanged(cbs: *Layout.Callbacks) !void {
    const self: *Self = @fieldParentPtr("layout_callbacks", cbs);
    try self.updateRegion();
}

fn winEventProc(
    _: w.HWINEVENTHOOK,
    event: w.DWORD,
    hwnd: w.HWND,
    id_object: w.LONG,
    id_child: w.LONG,
    _: w.DWORD,
    _: w.DWORD,
) callconv(.winapi) void {
    if (event == w.EVENT_SYSTEM_DESKTOPSWITCH) {
        if (event_sink_hwnd) |sink| {
            _ = w.PostMessageW(sink, WM_VITRAIL_WINDOWS_CHANGED, 0, 0);
        }
        return;
    }

    switch (event) {
        w.EVENT_OBJECT_CREATE,
        w.EVENT_OBJECT_DESTROY,
        w.EVENT_OBJECT_SHOW,
        w.EVENT_OBJECT_HIDE,
        w.EVENT_OBJECT_STATECHANGE,
        w.EVENT_OBJECT_LOCATIONCHANGE,
        w.EVENT_OBJECT_NAMECHANGE,
        w.EVENT_OBJECT_CLOAKED,
        w.EVENT_OBJECT_UNCLOAKED,
        => {},
        else => return,
    }

    if (hwnd == null or id_object != w.OBJID_WINDOW or id_child != w.CHILDID_SELF) return;
    // At create/show/name/state time the HWND is live, so reject child HWNDs.
    // During EVENT_OBJECT_DESTROY GetAncestor may already fail; allowing that
    // event only causes a coalesced extra refresh and ensures closures aren't
    // missed.
    if (event != w.EVENT_OBJECT_DESTROY and w.GetAncestor(hwnd, w.GA_ROOT) != hwnd) return;

    if (event == w.EVENT_OBJECT_CREATE or event == w.EVENT_OBJECT_DESTROY) {
        sys.retireWindowIdentity(hwnd);
    }

    if (event_sink_hwnd) |sink| {
        _ = w.PostMessageW(sink, WM_VITRAIL_WINDOWS_CHANGED, 0, 0);
    }
}

fn onAfterDestroyHandler(event_handlers: *Window.EventHandlers, _: *Window) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    _ = w.KillTimer(self.window.hwnd, REFRESH_TIMER_ID);
    self.refresh_timer_armed = false;
    if (self.win_event_hook) |hook| {
        _ = w.UnhookWinEvent(hook);
        self.win_event_hook = null;
    }
    if (self.cloak_event_hook) |hook| {
        _ = w.UnhookWinEvent(hook);
        self.cloak_event_hook = null;
    }
    if (self.desktop_event_hook) |hook| {
        _ = w.UnhookWinEvent(hook);
        self.desktop_event_hook = null;
    }
    if (event_sink_hwnd == self.window.hwnd) event_sink_hwnd = null;
    self.allocator.destroy(self.window);
    self.allocator.destroy(self.layout);
    _ = w.PostQuitMessage(0);
}

fn onKeyDownHandler(event_handlers: *Window.EventHandlers, _: *Window, wParam: w.WPARAM, _: w.LPARAM) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    if (wParam == w.VK_ESCAPE) {
        try self.callbacks.hide(self);
    } else if (wParam == w.VK_OEM_COMMA and w.GetKeyState(w.VK_CONTROL) < 0) {
        // Ctrl+, — the "Preferences" chord, forwarded here from the Layout
        // child for keys it doesn't consume.
        try self.callbacks.openSettings(self);
    }
}

fn onActivateHandler(event_handlers: *Window.EventHandlers, _: *Window, wParam: w.WPARAM, _: w.LPARAM) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    const state = wParam & 0xFFFF;
    if (state == w.WA_INACTIVE and self.desktop_windows != null and !self.menu_tracking) {
        try self.callbacks.hide(self);
    }
}

fn onTimerHandler(event_handlers: *Window.EventHandlers, _: *Window, wParam: w.WPARAM, _: w.LPARAM) !void {
    if (wParam != REFRESH_TIMER_ID) return;
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    _ = w.KillTimer(self.window.hwnd, REFRESH_TIMER_ID);
    self.refresh_timer_armed = false;

    if (self.desktop_windows == null) {
        self.refresh_dirty = false;
        return;
    }
    if (self.menu_tracking) {
        self.refresh_dirty = true;
        return;
    }
    if (!self.refresh_dirty) return;

    self.refresh_dirty = false;
    try self.callbacks.refreshWindows(self);
}

fn onAppMessageHandler(
    event_handlers: *Window.EventHandlers,
    _: *Window,
    msg: w.UINT,
    _: w.WPARAM,
    _: w.LPARAM,
) !void {
    if (msg != WM_VITRAIL_WINDOWS_CHANGED) return;
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    self.scheduleRefresh();
}

fn onResizeHandler(event_handlers: *Window.EventHandlers, window: *Window) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    if (window.docked) try window.dock();
    for (window.children.items) |child| try child.resize();
    try self.updateRegion();
}

/// Rebuild the popup's transparency region from the grid's current visible
/// tiles + search box. Each tile rect is extended by 1px on right and bottom
/// so the renderer's seam borders (drawn at logical x+step_x / y+step_y) stay
/// inside the region; interior overlaps are harmless under RGN_OR.
fn updateRegion(self: *Self) !void {
    var window_rect: w.RECT = undefined;
    try wh.mapFailure(w.GetWindowRect(self.window.hwnd, &window_rect));

    var layout_rect: w.RECT = undefined;
    try wh.mapFailure(w.GetWindowRect(self.layout.window.hwnd, &layout_rect));

    const layout_offset_x: c_int = layout_rect.left - window_rect.left;
    const layout_offset_y: c_int = layout_rect.top - window_rect.top;

    const dpi: c_int = @intCast(self.layout.window.dpi);
    const step_x: c_int = Grid.TILE_W + Grid.TILE_MARGIN;
    const step_y: c_int = Grid.TILE_H + Grid.TILE_MARGIN;

    const rgn = w.CreateRectRgn(0, 0, 0, 0);

    for (self.layout.grid.tiles.items) |t| {
        if (!t.visible) continue;
        const tx: c_int = layout_offset_x + w.MulDiv(t.x, dpi, 96);
        const ty: c_int = layout_offset_y + w.MulDiv(t.y, dpi, 96);
        const tx_end: c_int = layout_offset_x + w.MulDiv(t.x + step_x, dpi, 96);
        const ty_end: c_int = layout_offset_y + w.MulDiv(t.y + step_y, dpi, 96);
        const tile_rgn = w.CreateRectRgn(tx, ty, tx_end + 1, ty_end + 1);
        defer _ = w.DeleteObject(tile_rgn);
        _ = w.CombineRgn(rgn, rgn, tile_rgn, w.RGN_OR);
    }

    if (self.desktop_windows != null) {
        const sr = self.layout.grid.searchBoxRect();
        const sx: c_int = layout_offset_x + w.MulDiv(sr.x, dpi, 96);
        const sy: c_int = layout_offset_y + w.MulDiv(sr.y, dpi, 96);
        const sx_end: c_int = layout_offset_x + w.MulDiv(sr.x + sr.w, dpi, 96);
        const sy_end: c_int = layout_offset_y + w.MulDiv(sr.y + sr.h, dpi, 96);
        const sb_rgn = w.CreateRectRgn(sx, sy, sx_end, sy_end);
        defer _ = w.DeleteObject(sb_rgn);
        _ = w.CombineRgn(rgn, rgn, sb_rgn, w.RGN_OR);
    }

    _ = w.SetWindowRgn(self.window.hwnd, rgn, 1);
}

fn onPaintHandler(_: *Window.EventHandlers, window: *Window) !void {
    var ps: w.PAINTSTRUCT = undefined;
    _ = w.BeginPaint(window.hwnd, &ps);
    _ = w.EndPaint(window.hwnd, &ps);
}

pub fn onDpiChangeHandler(event_handlers: *Window.EventHandlers, window: *Window, _: w.WPARAM, _: w.LPARAM) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);

    const dpi = w.GetDpiForWindow(window.hwnd);
    window.setDpi(dpi);
    const desktop = w.GetDesktopWindow();
    var rect: w.RECT = undefined;
    try wh.mapFailure(w.GetWindowRect(desktop, &rect));
    try window.setSizeScaled(rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top);

    try self.layout.onDpiChanged();
}

pub fn onEnableHandler(_: *Window.EventHandlers, window: *Window, wParam: w.WPARAM, _: w.LPARAM) !void {
    if (wParam == 1) {
        const desktop = w.GetDesktopWindow();
        var desktopRect: w.RECT = undefined;
        try wh.mapFailure(w.GetWindowRect(desktop, &desktopRect));
        try window.setSize(desktopRect.left, desktopRect.top, desktopRect.right - desktopRect.left, desktopRect.bottom - desktopRect.top);
    }
}

pub fn create(args: PlatformArgs, callbacks: *Callbacks, allocator: std.mem.Allocator) !*Self {
    const hInstance = args.hInstance;
    const desktop = w.GetDesktopWindow();
    var desktopRect: w.RECT = undefined;
    try wh.mapFailure(w.GetWindowRect(desktop, &desktopRect));

    const windowConfig = Window.WindowParameters{
        .exStyle = w.WS_EX_TOPMOST | w.WS_EX_TOOLWINDOW,
        .x = desktopRect.left,
        .y = desktopRect.top,
        .width = desktopRect.right,
        .height = desktopRect.bottom,
        .title = sys.toUtf16const("MainWindow"),
        .style = w.WS_POPUP,
    };

    var self = try allocator.create(Self);
    self.* = .{
        .window = undefined,
        .layout = undefined,
        .event_handlers = .{
            .onAfterDestroy = onAfterDestroyHandler,
            .onKeyDown = onKeyDownHandler,
            .onPaint = onPaintHandler,
            .onResize = onResizeHandler,
            .onDpiChange = onDpiChangeHandler,
            .onEnable = onEnableHandler,
            .onActivate = onActivateHandler,
            .onTimer = onTimerHandler,
            .onAppMessage = onAppMessageHandler,
        },
        .desktop_windows = null,
        .hInstance = hInstance,
        .allocator = allocator,
        .callbacks = callbacks,
        .win_event_hook = null,
        .cloak_event_hook = null,
        .desktop_event_hook = null,
        .refresh_dirty = false,
        .refresh_timer_armed = false,
        .menu_tracking = false,
    };

    const window = try Window.create(windowConfig, &self.event_handlers, hInstance, allocator);
    self.window = window;

    self.layout = try Layout.create(hInstance, window, &self.layout_callbacks, allocator);

    try window.setSize(desktopRect.left, desktopRect.top, desktopRect.right - desktopRect.left, desktopRect.bottom - desktopRect.top);

    event_sink_hwnd = window.hwnd;
    self.win_event_hook = w.SetWinEventHook(
        w.EVENT_OBJECT_CREATE,
        w.EVENT_OBJECT_NAMECHANGE,
        null,
        @ptrCast(&winEventProc),
        0,
        0,
        w.WINEVENT_OUTOFCONTEXT | w.WINEVENT_SKIPOWNPROCESS,
    );
    self.cloak_event_hook = w.SetWinEventHook(
        w.EVENT_OBJECT_CLOAKED,
        w.EVENT_OBJECT_UNCLOAKED,
        null,
        @ptrCast(&winEventProc),
        0,
        0,
        w.WINEVENT_OUTOFCONTEXT | w.WINEVENT_SKIPOWNPROCESS,
    );
    self.desktop_event_hook = w.SetWinEventHook(
        w.EVENT_SYSTEM_DESKTOPSWITCH,
        w.EVENT_SYSTEM_DESKTOPSWITCH,
        null,
        @ptrCast(&winEventProc),
        0,
        0,
        w.WINEVENT_OUTOFCONTEXT | w.WINEVENT_SKIPOWNPROCESS,
    );

    return self;
}

pub fn show(self: *Self) !void {
    // Keyboard / non-centered path: (re)home the overlay on the primary monitor
    // and drop any cursor centering.
    const desktop = w.GetDesktopWindow();
    var rect: w.RECT = undefined;
    try wh.mapFailure(w.GetWindowRect(desktop, &rect));
    try self.window.setSize(rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top);
    self.window.setDpi(w.GetDpiForWindow(self.window.hwnd));
    self.layout.grid.clearCenter();
    _ = self.window.show();
}

/// Show on the monitor under the pointer with the grid centered at the cursor.
pub fn showAtCursor(self: *Self) !void {
    // Best-effort: relocate the overlay to the monitor under the pointer.
    self.moveToCursorMonitor();
    _ = self.window.show();

    // Center at the cursor using the overlay's *actual* client mapping. This is
    // robust whether or not the move happened, and avoids the by-value POINT
    // monitor APIs (MonitorFromPoint) that misbehave on aarch64-windows. The
    // overlay is a borderless popup at the monitor origin, so ScreenToClient
    // gives the cursor in the grid's logical viewport space. Crucially we never
    // fall back to the centered show() (which would clear the center).
    var pt: w.POINT = undefined;
    if (w.GetCursorPos(&pt) != 0 and w.ScreenToClient(self.layout.window.hwnd, &pt) != 0) {
        const dpi: c_int = @intCast(self.layout.window.dpi);
        const eff: c_int = if (dpi == 0) 96 else dpi;
        self.layout.grid.setCenter(w.MulDiv(pt.x, 96, eff), w.MulDiv(pt.y, 96, eff));
    } else {
        self.layout.grid.clearCenter();
    }
}

const MonitorSearch = struct {
    pt: w.POINT,
    found: bool = false,
    rect: w.RECT = undefined,
};

fn monitorEnumProc(_: w.HMONITOR, _: w.HDC, lprc: *w.RECT, lparam: w.LPARAM) callconv(.winapi) w.BOOL {
    const ctx: *MonitorSearch = @ptrFromInt(@as(usize, @bitCast(lparam)));
    const r = lprc.*;
    if (ctx.pt.x >= r.left and ctx.pt.x < r.right and ctx.pt.y >= r.top and ctx.pt.y < r.bottom) {
        ctx.rect = r;
        ctx.found = true;
        return 0; // stop enumeration
    }
    return 1; // continue
}

/// Move the overlay to the monitor under the cursor when that differs from where
/// it currently sits. Best-effort: any failure leaves the overlay in place (the
/// caller still centers correctly via ScreenToClient). Uses EnumDisplayMonitors
/// — its callback receives each monitor's RECT by pointer — to avoid the
/// by-value POINT ABI of MonitorFromPoint on aarch64-windows.
fn moveToCursorMonitor(self: *Self) void {
    var pt: w.POINT = undefined;
    if (w.GetCursorPos(&pt) == 0) return;
    var ctx = MonitorSearch{ .pt = pt };
    _ = w.EnumDisplayMonitors(null, null, @ptrCast(&monitorEnumProc), @bitCast(@intFromPtr(&ctx)));
    if (!ctx.found) return;
    const m = ctx.rect;

    var cur: w.RECT = undefined;
    if (w.GetWindowRect(self.window.hwnd, &cur) != 0 and
        cur.left == m.left and cur.top == m.top and
        cur.right == m.right and cur.bottom == m.bottom) return; // already there

    self.window.setSize(m.left, m.top, m.right - m.left, m.bottom - m.top) catch return;
    self.window.setDpi(w.GetDpiForWindow(self.window.hwnd));
}

/// On Windows, teardown is driven by WM_DESTROY (`onAfterDestroyHandler`),
/// not an explicit deinit; this exists so MainPresenter.deinit can call
/// `view.deinit()` symmetrically across platforms.
pub fn deinit(_: *Self) void {}

pub fn activate(self: *Self) void {
    self.window.activate();
    _ = w.SetForegroundWindow(self.window.hwnd);
}

pub fn requestQuit(_: *Self) void {
    w.PostQuitMessage(0);
}

fn armRefreshTimer(self: *Self) void {
    if (self.desktop_windows == null or
        self.menu_tracking or
        self.refresh_timer_armed)
    {
        return;
    }
    self.refresh_timer_armed =
        w.SetTimer(self.window.hwnd, REFRESH_TIMER_ID, REFRESH_DEBOUNCE_MS, null) != 0;
}

/// Coalesce platform lifecycle bursts at the first event's deadline. WinEvent
/// can emit name or location changes continuously, and resetting SetTimer for
/// each one would otherwise starve the refresh. Calls made while a native menu
/// is tracking remain dirty and are armed when its nested event loop exits.
pub fn scheduleRefresh(self: *Self) void {
    if (self.desktop_windows == null) return;
    self.refresh_dirty = true;
    self.armRefreshTimer();
}

fn finishMenuTracking(self: *Self) void {
    self.menu_tracking = false;
    if (self.refresh_dirty) self.armRefreshTimer();
}

fn showContextMenu(
    self: *Self,
    stable_id: []const u8,
    can_close: bool,
    screen_x: c_int,
    screen_y: c_int,
) !void {
    const menu = w.CreatePopupMenu();
    if (menu == null) return error.CreatePopupMenuFailed;
    defer _ = w.DestroyMenu(menu);

    const enabled_flags: w.UINT = if (can_close)
        w.MF_STRING
    else
        w.MF_STRING | w.MF_DISABLED | w.MF_GRAYED;
    if (w.AppendMenuW(
        menu,
        enabled_flags,
        CONTEXT_CLOSE_COMMAND,
        sys.toUtf16const("Close window"),
    ) == 0) return error.AppendMenuFailed;
    if (w.AppendMenuW(menu, w.MF_SEPARATOR, 0, null) == 0) return error.AppendMenuFailed;
    if (w.AppendMenuW(
        menu,
        w.MF_STRING,
        CONTEXT_QUIT_COMMAND,
        sys.toUtf16const("Quit application"),
    ) == 0) return error.AppendMenuFailed;

    self.menu_tracking = true;
    defer self.finishMenuTracking();

    _ = w.SetForegroundWindow(self.window.hwnd);
    const command = w.TrackPopupMenuEx(
        menu,
        w.TPM_RIGHTBUTTON | w.TPM_RETURNCMD | w.TPM_NONOTIFY,
        screen_x,
        screen_y,
        self.window.hwnd,
        null,
    );

    // TrackPopupMenuEx runs a nested native loop and consumes pointer movement.
    // Reconcile against the current cursor before handling the captured target;
    // this updates hover without changing which window the command applies to.
    if (self.layout.selectAtCurrentPointer()) {
        self.layout.window.redraw() catch |err| {
            std.log.warn("Windows post-menu pointer redraw failed: {s}", .{@errorName(err)});
        };
    }

    if (can_close and command == CONTEXT_CLOSE_COMMAND) {
        try self.callbacks.closeWindow(self, stable_id);
    } else if (command == CONTEXT_QUIT_COMMAND) {
        try self.callbacks.quitApplication(self, stable_id);
    }
}

pub fn setDesktopWindows(self: *Self, desktopWindows: []const common.DesktopWindow) !void {
    try self.hideBoxes();
    if (desktopWindows.len > 0) {
        try self.layout.setDesktopWindows(desktopWindows);
    }
    // Publish the borrow only after Grid has accepted the snapshot. Everything
    // below is best-effort native presentation and cannot reject ownership.
    self.desktop_windows = desktopWindows;
    self.layout.window.focus() catch |err| {
        std.log.warn("Windows initial grid focus failed: {s}", .{@errorName(err)});
    };
    self.updateRegion() catch |err| {
        std.log.warn("Windows initial grid region update failed: {s}", .{@errorName(err)});
    };
}

pub fn refreshDesktopWindows(self: *Self, desktopWindows: []const common.DesktopWindow) !void {
    try self.layout.refreshDesktopWindows(desktopWindows);
    self.desktop_windows = desktopWindows;
}

pub fn hideBoxes(self: *Self) !void {
    _ = w.KillTimer(self.window.hwnd, REFRESH_TIMER_ID);
    self.refresh_dirty = false;
    self.refresh_timer_armed = false;
    try self.layout.clear();
    self.desktop_windows = null;
    self.updateRegion() catch |err| {
        std.log.warn("Windows hidden-region update failed: {s}", .{@errorName(err)});
    };
}
