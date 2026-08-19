// macOS MainWindow — owns the bridge window, the framebuffer, and the
// keyboard/mouse translation. Drives the shared Grid + Renderer.

const std = @import("std");
const common = @import("../../common/DesktopWindow.zig");

const ax = @import("ax.zig");
const ax_cache = @import("ax_cache.zig");
const bridge = @import("bridge.zig");
const Keyboard = @import("Keyboard.zig");
const Mouse = @import("Mouse.zig");
const text = @import("text.zig");

// Grid + Renderer are pure logic / pure Zig software raster in common/,
// reused across platforms.
const Grid = @import("../../common/Grid.zig");
const Renderer = @import("../../common/Renderer.zig");
const input = @import("../../common/InputAction.zig");

const cg = @cImport({
    @cInclude("CoreGraphics/CoreGraphics.h");
});

const Self = @This();

pub const PlatformArgs = struct {};

pub const Callbacks = struct {
    activateWindow: *const fn (*Self, common.DesktopWindow) anyerror!void,
    closeWindow: *const fn (*Self, stable_id: []const u8) anyerror!void,
    refreshWindows: *const fn (*Self) anyerror!void,
    hide: *const fn (*Self) anyerror!void,
    openSettings: *const fn (*Self) anyerror!void,
};

const LOGICAL_FONT_TILE: u32 = 12;
const LOGICAL_FONT_SEARCH: u32 = 12;
const LOGICAL_FONT_DESKTOP: u32 = 32;

const PointerPosition = struct {
    x: i32,
    y: i32,
};

allocator: std.mem.Allocator,
callbacks: *Callbacks,

window: *bridge.VtWindow,
keyboard: Keyboard,
mouse: Mouse,
grid: Grid,
tile_text: text.Renderer,
search_text: text.Renderer,
desktop_text: text.Renderer,

// Framebuffer + image plumbing.
pixels: []u32,
physical_w: u32,
physical_h: u32,
logical_w: u32,
logical_h: u32,
scale_q120: u32,
size_dirty: bool,

running: bool,
visible: bool,
menu_tracking: bool,
refresh_pending: bool,
refresh_timer_armed: bool,
pointer_position: ?PointerPosition,
pointer_drives_selection: bool,
native_pointer_events: bool,

pub fn create(_: PlatformArgs, callbacks: *Callbacks, allocator: std.mem.Allocator) !*Self {
    bridge.vt_app_init();

    // Surface the Accessibility prompt once during launch rather than
    // lazily on the first window-list refresh, so the user can grant the
    // permission before they ever pop the switcher.
    _ = ax.promptTrust();

    // Seed the AX-element cache with a high-cap brute-force scan of every
    // currently-running app, then install observers so the cache stays
    // fresh. Runs synchronously here — vitrail's UI isn't visible yet,
    // so the few seconds it takes are invisible to the user.
    ax_cache.init(allocator) catch {};

    var self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .callbacks = callbacks,
        .window = undefined,
        .keyboard = Keyboard.init(.{ .on_action = onKeyboardAction, .ctx = self }),
        .mouse = Mouse.init(.{ .on_action = onMouseAction, .ctx = self }),
        .grid = Grid.init(allocator),
        .tile_text = undefined,
        .search_text = undefined,
        .desktop_text = undefined,
        .pixels = &.{},
        .physical_w = 0,
        .physical_h = 0,
        .logical_w = 0,
        .logical_h = 0,
        .scale_q120 = 120,
        .size_dirty = false,
        .running = true,
        .visible = false,
        .menu_tracking = false,
        .refresh_pending = false,
        .refresh_timer_armed = false,
        .pointer_position = null,
        .pointer_drives_selection = false,
        .native_pointer_events = false,
    };

    const w = bridge.vt_window_create(self, onKeyCb, onMouseCb, onResizeCb, onCloseCb) orelse
        return error.WindowCreate;
    self.window = w;

    // Bridge calls reportSize on show; until then we don't know the size.
    // Pre-create text renderers at scale 1.0; rebuildForScale() replaces them.
    self.tile_text = try text.Renderer.create(allocator, LOGICAL_FONT_TILE, .regular);
    errdefer self.tile_text.destroy();
    self.search_text = try text.Renderer.create(allocator, LOGICAL_FONT_SEARCH, .regular);
    errdefer self.search_text.destroy();
    self.desktop_text = try text.Renderer.create(allocator, LOGICAL_FONT_DESKTOP, .bold);
    errdefer self.desktop_text.destroy();

    ax_cache.setChangeCallback(onAxWindowChanged, self);
    bridge.vt_install_window_change_observer(self, onWorkspaceWindowChanged);

    return self;
}

pub fn deinit(self: *Self) void {
    ax_cache.setChangeCallback(null, null);
    bridge.vt_install_window_change_observer(null, null);
    bridge.vt_window_cancel_refresh(self.window);
    self.desktop_text.destroy();
    self.search_text.destroy();
    self.tile_text.destroy();
    self.grid.deinit();
    if (self.pixels.len != 0) self.allocator.free(self.pixels);
    bridge.vt_window_destroy(self.window);
    self.allocator.destroy(self);
}

// ─── Platform contract ──────────────────────────────────────────────────────

pub fn show(self: *Self) !void {
    self.visible = true;
    bridge.vt_window_move_to_main_screen(self.window);
    self.grid.clearCenter();
    bridge.vt_window_show(self.window);
    if (self.size_dirty) try self.rebuildForScale();
    try self.repaint();
}

/// Show on the pointer's display with the grid centered under the cursor.
pub fn showAtCursor(self: *Self) !void {
    var x: f64 = 0;
    var y: f64 = 0;
    self.visible = true;
    const ok = bridge.vt_window_move_to_cursor_screen(self.window, &x, &y) != 0;
    bridge.vt_window_show(self.window);
    if (self.size_dirty) try self.rebuildForScale();
    if (ok) {
        self.grid.setCenter(@intFromFloat(x), @intFromFloat(y));
    } else {
        self.grid.clearCenter();
    }
    try self.repaint();
}

pub fn activate(_: *Self) void {}

pub fn requestQuit(self: *Self) void {
    self.running = false;
    bridge.vt_app_stop();
}

pub fn setDesktopWindows(self: *Self, dws: []const common.DesktopWindow) !void {
    try self.grid.setDesktopWindows(dws);
    // Grid now borrows dws. A drawing failure must not make the presenter
    // discard that committed snapshot underneath it.
    self.repaint() catch |err| {
        std.log.warn("initial grid repaint failed: {s}", .{@errorName(err)});
    };
}

pub fn refreshDesktopWindows(self: *Self, dws: []const common.DesktopWindow) !void {
    // A last real macOS window is replaced by a windowless-app placeholder.
    // Opt into continuity for that platform-specific identity transition;
    // other platforms retain Grid's stable-id-then-rank default.
    try self.grid.refreshDesktopWindowsWithOptions(dws, .{
        .select_same_app_in_vacated_cell = true,
    });
    // A native menu runs its own event loop, and window enumeration can block
    // AppKit briefly. Re-hit-test the current system pointer so a queued event
    // or a newly-filled tile cannot leave selection behind the cursor.
    _ = self.selectAtCurrentPointer();
    // refreshDesktopWindows committed the borrow transactionally. Report
    // drawing failures without turning the ownership commit into an error.
    self.repaint() catch |err| {
        std.log.warn("refreshed grid repaint failed: {s}", .{@errorName(err)});
    };
}

pub fn hideBoxes(self: *Self) !void {
    self.visible = false;
    self.refresh_pending = false;
    self.refresh_timer_armed = false;
    self.pointer_position = null;
    self.pointer_drives_selection = false;
    self.native_pointer_events = false;
    bridge.vt_window_cancel_refresh(self.window);
    self.grid.dropDesktopWindows();
    bridge.vt_window_hide(self.window);
}

/// Coalesce platform window-change notifications at the first event's 100 ms
/// deadline. Keeping an already-armed timer is important: AX can emit title or
/// move notifications continuously, so resetting the timer on every event can
/// otherwise starve the refresh indefinitely. Hidden overlays intentionally do
/// no work; the next show starts from a fresh enumeration.
pub fn scheduleRefresh(self: *Self) void {
    if (!self.visible) return;
    self.refresh_pending = true;
    if (self.menu_tracking or self.refresh_timer_armed) return;
    self.refresh_timer_armed = true;
    bridge.vt_window_schedule_refresh(self.window, 0.1, onRefreshTimerCb);
}

pub fn dispatch(self: *Self) bool {
    if (!self.running) return false;
    return bridge.vt_app_pump_one(1) == 0;
}

// ─── Test hooks ─────────────────────────────────────────────────────────────

pub fn synthesizeKey(self: *Self, action: Keyboard.Action) void {
    onKeyboardAction(self, action);
}
pub fn synthesizeMouse(self: *Self, action: Mouse.Action) void {
    self.native_pointer_events = false;
    onMouseAction(self, action);
}
pub fn renderInto(self: *Self, pixels: []u32) void {
    Renderer.render(
        pixels,
        self.logical_w,
        self.logical_h,
        120,
        &self.grid,
        &self.tile_text,
        &self.search_text,
        &self.desktop_text,
        .{},
    );
}
pub fn viewportSize(self: *const Self) struct { w: u32, h: u32 } {
    return .{ .w = self.logical_w, .h = self.logical_h };
}

// ─── Repaint ────────────────────────────────────────────────────────────────

fn repaint(self: *Self) !void {
    if (self.size_dirty) try self.rebuildForScale();
    if (self.pixels.len == 0 or self.physical_w == 0 or self.physical_h == 0) return;

    Renderer.render(
        self.pixels,
        self.physical_w,
        self.physical_h,
        self.scale_q120,
        &self.grid,
        &self.tile_text,
        &self.search_text,
        &self.desktop_text,
        .{},
    );

    // Wrap our framebuffer as a CGImage and hand it to the bridge. The image
    // owns a reference to the data via the data provider and is released
    // after the bridge stores it in the layer.
    const stride = self.physical_w * 4;
    const cs = cg.CGColorSpaceCreateDeviceRGB() orelse return error.ColorSpace;
    defer cg.CGColorSpaceRelease(cs);
    const provider = cg.CGDataProviderCreateWithData(
        null,
        @ptrCast(self.pixels.ptr),
        @as(usize, stride) * self.physical_h,
        null,
    ) orelse return error.DataProvider;
    defer cg.CGDataProviderRelease(provider);

    const bitmap_info: u32 = cg.kCGImageAlphaPremultipliedFirst | cg.kCGBitmapByteOrder32Little;
    const img = cg.CGImageCreate(
        self.physical_w,
        self.physical_h,
        8, // bits per component
        32, // bits per pixel
        stride,
        cs,
        bitmap_info,
        provider,
        null,
        false,
        cg.kCGRenderingIntentDefault,
    ) orelse return error.ImageCreate;
    defer cg.CGImageRelease(img);

    bridge.vt_window_set_image(self.window, img);
}

fn rebuildForScale(self: *Self) !void {
    if (self.physical_w == 0 or self.physical_h == 0) return;
    if (self.pixels.len != 0) {
        self.allocator.free(self.pixels);
        self.pixels = &.{};
    }
    self.pixels = try self.allocator.alloc(u32, @as(usize, self.physical_w) * self.physical_h);

    self.tile_text.destroy();
    self.search_text.destroy();
    self.desktop_text.destroy();
    self.tile_text = try text.Renderer.create(self.allocator, scaledFont(LOGICAL_FONT_TILE, self.scale_q120), .regular);
    self.search_text = try text.Renderer.create(self.allocator, scaledFont(LOGICAL_FONT_SEARCH, self.scale_q120), .regular);
    self.desktop_text = try text.Renderer.create(self.allocator, scaledFont(LOGICAL_FONT_DESKTOP, self.scale_q120), .bold);

    self.grid.setViewport(@intCast(self.logical_w), @intCast(self.logical_h));
    self.size_dirty = false;
}

fn scaledFont(logical: u32, scale_q120: u32) u32 {
    return (logical * scale_q120 + 60) / 120;
}

fn activateSelected(self: *Self) void {
    const dw = self.grid.selectedWindow() orelse return;
    self.callbacks.activateWindow(self, dw) catch {};
}

// ─── Bridge callbacks (C ABI) ───────────────────────────────────────────────

fn onKeyCb(ctx: ?*anyopaque, virtual_keycode: c_int, modifiers: u32, utf8: [*c]const u8, utf8_len: c_int) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    const slice: []const u8 = if (utf8_len > 0 and utf8 != null)
        utf8[0..@intCast(utf8_len)]
    else
        &.{};
    self.keyboard.handle(virtual_keycode, modifiers, slice);
}

fn onMouseCb(ctx: ?*anyopaque, kind: c_int, x: f64, y: f64) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.native_pointer_events = true;
    self.mouse.handle(kind, x, y);
}

fn onResizeCb(ctx: ?*anyopaque, pw: u32, ph: u32, lw: u32, lh: u32, scale: f64) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    const new_q120: u32 = @intFromFloat(@round(scale * 120));
    if (self.physical_w != pw or self.physical_h != ph or self.logical_w != lw or self.logical_h != lh or self.scale_q120 != new_q120) {
        self.size_dirty = true;
    }
    self.physical_w = pw;
    self.physical_h = ph;
    self.logical_w = lw;
    self.logical_h = lh;
    self.scale_q120 = new_q120;
}

fn onCloseCb(ctx: ?*anyopaque) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    // Resign-key fires on the overlay losing focus; treat like Esc on Windows.
    self.callbacks.hide(self) catch {};
}

fn onWorkspaceWindowChanged(ctx: ?*anyopaque) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.scheduleRefresh();
}

fn onAxWindowChanged(ctx: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.scheduleRefresh();
}

fn onRefreshTimerCb(ctx: ?*anyopaque) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.refresh_timer_armed = false;
    if (!self.visible) {
        self.refresh_pending = false;
        return;
    }
    if (self.menu_tracking) {
        self.refresh_pending = true;
        return;
    }
    self.refresh_pending = false;
    self.callbacks.refreshWindows(self) catch |err| {
        std.log.warn("live window refresh failed: {s}", .{@errorName(err)});
    };
}

// ─── Action sinks ───────────────────────────────────────────────────────────

fn hooks(self: *Self) input.Hooks {
    return .{ .ctx = self, .hide = onHookHide, .activate_selected = onHookActivate, .open_settings = onHookOpenSettings };
}
fn onHookHide(ctx: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.callbacks.hide(self) catch {};
}
fn onHookActivate(ctx: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.activateSelected();
}
fn onHookOpenSettings(ctx: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.callbacks.openSettings(self) catch {};
}

fn onKeyboardAction(ctx: *anyopaque, action: input.KeyAction) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    // Keep keyboard navigation authoritative until the pointer is used again;
    // an unrelated live refresh must not snap selection back under an old
    // mouse coordinate.
    self.pointer_drives_selection = false;
    input.dispatchKey(&self.grid, self.hooks(), action);
    self.repaint() catch {};
}

fn onMouseAction(ctx: *anyopaque, action: input.MouseAction) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    switch (action) {
        .move => |point| {
            self.rememberPointer(point.x, point.y);
            // Rendering a physical full-screen framebuffer is relatively
            // expensive on Retina displays. Queued movement inside the same
            // tile has no visual effect and should not trigger another render.
            if (self.grid.selectAt(point.x, point.y)) {
                self.repaint() catch {};
            }
        },
        .click => |point| {
            self.rememberPointer(point.x, point.y);
            input.dispatchMouse(&self.grid, self.hooks(), action);
            self.repaint() catch {};
        },
        .context => |point| {
            self.rememberPointer(point.x, point.y);
            self.openContextMenu(point.x, point.y);
        },
    }
}

fn rememberPointer(self: *Self, x: i32, y: i32) void {
    self.pointer_position = .{ .x = x, .y = y };
    self.pointer_drives_selection = true;
}

/// Select the tile under the latest pointer position. Native input samples the
/// live system pointer instead of trusting a possibly queued NSEvent. Synthetic
/// test input keeps using its explicit coordinate.
fn selectAtCurrentPointer(self: *Self) bool {
    if (!self.pointer_drives_selection) return false;

    var point = self.pointer_position orelse return false;
    if (self.native_pointer_events) {
        var x: f64 = 0;
        var y: f64 = 0;
        if (bridge.vt_window_mouse_position(self.window, &x, &y) == 0) return false;
        point = .{ .x = @intFromFloat(x), .y = @intFromFloat(y) };
        self.pointer_position = point;
    }
    return self.grid.selectAt(point.x, point.y);
}

fn openContextMenu(self: *Self, x: i32, y: i32) void {
    if (self.grid.tileAt(x, y) == null) return;
    _ = self.grid.selectAt(x, y);
    self.repaint() catch {};

    const target = self.grid.selectedWindow() orelse return;
    const stable_id = self.allocator.dupe(u8, target.stable_id) catch return;
    defer self.allocator.free(stable_id);

    self.menu_tracking = true;
    const selected = bridge.vt_window_show_context_menu(
        self.window,
        @floatFromInt(x),
        @floatFromInt(y),
        @intFromBool(target.can_close),
    ) != 0;
    self.menu_tracking = false;

    // NSMenu consumes movement while its nested tracking loop is active.
    // Reconcile once at dismissal instead of replaying an obsolete event.
    if (self.selectAtCurrentPointer()) {
        self.repaint() catch {};
    }

    if (selected and target.can_close) {
        self.callbacks.closeWindow(self, stable_id) catch |err| {
            std.log.warn("close-window command failed: {s}", .{@errorName(err)});
        };
    }
    // A timer can fire inside AppKit's nested menu-tracking loop. Its refresh
    // is deliberately deferred until the copied menu target has been handled.
    if (self.refresh_pending) self.scheduleRefresh();
}
