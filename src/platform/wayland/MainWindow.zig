const std = @import("std");
const common = @import("../../common/DesktopWindow.zig");
const wc = @import("wayland_c.zig");
const c = wc.c;

const LayerSurface = @import("LayerSurface.zig");
const ShmPool = @import("ShmPool.zig");
const Keyboard = @import("Keyboard.zig");
const Mouse = @import("Mouse.zig");
const Cursor = @import("Cursor.zig");
const Grid = @import("../../common/Grid.zig");
const Renderer = @import("../../common/Renderer.zig");
const text = @import("text.zig");
const input = @import("../../common/InputAction.zig");

const Self = @This();

pub const PlatformArgs = struct {};

pub const Callbacks = struct {
    activateWindow: *const fn (*Self, common.DesktopWindow) anyerror!void,
    hide: *const fn (*Self) anyerror!void,
    openSettings: *const fn (*Self) anyerror!void,
};

const Globals = struct {
    compositor: ?*c.wl_compositor = null,
    shm: ?*c.wl_shm = null,
    layer_shell: ?*c.zwlr_layer_shell_v1 = null,
    seat: ?*c.wl_seat = null,
    fractional_scale_mgr: ?*c.wp_fractional_scale_manager_v1 = null,
    viewporter: ?*c.wp_viewporter = null,
};

// Sized to roughly match Win32 DEFAULT_GUI_FONT (Tahoma ~9pt → ~12px) and the
// Segoe UI Bold 32pt-scaled badge used for the desktop number. Logical units —
// the actual FreeType pixel size is these values × surface scale.
const LOGICAL_FONT_TILE: u32 = 12;
const LOGICAL_FONT_SEARCH: u32 = 12;
const LOGICAL_FONT_DESKTOP: u32 = 32;

allocator: std.mem.Allocator,
callbacks: *Callbacks,

display: *c.wl_display,
globals: Globals,
registry_listener: c.wl_registry_listener,

layer: LayerSurface,
shm_pool: ShmPool,
keyboard: Keyboard,
mouse: Mouse,
cursor: Cursor,
seat_listener: c.wl_seat_listener,
grid: Grid,
tile_text: text.Renderer,
search_text: text.Renderer,
desktop_text: text.Renderer,

closed: bool,
running: bool,

pub fn create(_: PlatformArgs, callbacks: *Callbacks, allocator: std.mem.Allocator) !*Self {
    const display = c.wl_display_connect(null) orelse return error.NoWaylandDisplay;
    errdefer _ = c.wl_display_disconnect(display);

    var self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .callbacks = callbacks,
        .display = display,
        .globals = .{},
        .registry_listener = .{ .global = onRegistryGlobal, .global_remove = onRegistryRemove },
        .layer = undefined,
        .shm_pool = undefined,
        .keyboard = undefined,
        .mouse = undefined,
        .cursor = undefined,
        .seat_listener = .{ .capabilities = onSeatCaps, .name = onSeatName },
        .grid = Grid.init(allocator),
        .tile_text = undefined,
        .search_text = undefined,
        .desktop_text = undefined,
        .closed = false,
        .running = true,
    };

    // Init input action sinks BEFORE the registry roundtrip — onRegistryGlobal
    // attaches the seat listener as soon as it binds the seat, and the
    // capabilities event arrives in this same roundtrip.
    try self.keyboard.init(.{ .on_action = onKeyboardAction, .ctx = self });
    self.mouse.init(.{ .on_action = onMouseAction, .ctx = self });

    const registry = c.wl_display_get_registry(display) orelse return error.RegistryFailed;
    _ = c.wl_registry_add_listener(registry, &self.registry_listener, self);
    _ = c.wl_display_roundtrip(display);

    if (self.globals.compositor == null or self.globals.shm == null or self.globals.layer_shell == null) {
        return error.MissingWaylandGlobals;
    }

    try self.layer.init(
        self.globals.compositor.?,
        self.globals.layer_shell.?,
        self.globals.fractional_scale_mgr,
        self.globals.viewporter,
        &self.closed,
    );

    // One roundtrip to get the configure (logical w/h). preferred_scale is
    // typically delivered alongside or shortly after; we re-check below.
    _ = c.wl_display_roundtrip(display);
    if (!self.layer.configured) return error.LayerSurfaceNotConfigured;

    // Second roundtrip lets preferred_scale settle if it didn't arrive yet.
    _ = c.wl_display_roundtrip(display);

    const phys = self.layer.physicalSize();
    try self.shm_pool.init(self.globals.shm.?, phys.w, phys.h);
    self.layer.applyViewport();
    self.layer.size_dirty = false;

    try self.cursor.init(self.globals.compositor.?, self.globals.shm.?);
    self.mouse.setCursor(&self.cursor);

    // Now that input action sinks are real (init() was called earlier, before
    // the registry roundtrip), drive a roundtrip so any seat-capabilities
    // event delivered to onSeatCaps wires the keyboard/pointer.
    _ = c.wl_display_roundtrip(display);

    self.grid.setViewport(@intCast(self.layer.width), @intCast(self.layer.height));

    self.tile_text = try text.Renderer.create(allocator, scaledFont(LOGICAL_FONT_TILE, self.layer.scale_q120), .regular);
    errdefer self.tile_text.destroy();
    self.search_text = try text.Renderer.create(allocator, scaledFont(LOGICAL_FONT_SEARCH, self.layer.scale_q120), .regular);
    errdefer self.search_text.destroy();
    self.desktop_text = try text.Renderer.create(allocator, scaledFont(LOGICAL_FONT_DESKTOP, self.layer.scale_q120), .bold);
    errdefer self.desktop_text.destroy();

    return self;
}

fn scaledFont(logical: u32, scale_q120: u32) u32 {
    return (logical * scale_q120 + 60) / 120;
}

pub fn deinit(self: *Self) void {
    self.desktop_text.destroy();
    self.search_text.destroy();
    self.tile_text.destroy();
    self.grid.deinit();
    self.cursor.deinit();
    self.mouse.deinit();
    self.keyboard.deinit();
    self.shm_pool.deinit();
    self.layer.deinit();
    _ = c.wl_display_disconnect(self.display);
    self.allocator.destroy(self);
}

// ─── Platform contract ────────────────────────────────────────────────────────

pub fn show(self: *Self) !void {
    self.grid.clearCenter();
    try self.repaint();
    _ = c.wl_display_flush(self.display);
}

/// Wayland is launch-on-demand with no resident pointer query here, so cursor-
/// centering falls back to the centered path. Present for the shared presenter.
pub fn showAtCursor(self: *Self) !void {
    return self.show();
}

pub fn activate(_: *Self) void {}

pub fn requestQuit(self: *Self) void {
    self.running = false;
}

pub fn setDesktopWindows(self: *Self, dws: std.array_list.Managed(common.DesktopWindow)) !void {
    try self.grid.setDesktopWindows(dws.items);
    try self.repaint();
    _ = c.wl_display_flush(self.display);
}

// ─── Test hooks ───────────────────────────────────────────────────────────────
// Direct entry points for the in-process test driver. Production code never
// calls these; they let tests bypass wl_keyboard / wl_pointer.

pub fn synthesizeKey(self: *Self, action: Keyboard.Action) void {
    onKeyboardAction(self, action);
}
pub fn synthesizeMouse(self: *Self, action: Mouse.Action) void {
    onMouseAction(self, action);
}
pub fn renderInto(self: *Self, pixels: []u32) void {
    // Test driver renders at scale 1.0 into a logical-sized buffer.
    Renderer.render(
        pixels,
        self.layer.width,
        self.layer.height,
        120,
        &self.grid,
        &self.tile_text,
        &self.search_text,
        &self.desktop_text,
        .{},
    );
}
pub fn viewportSize(self: *const Self) struct { w: u32, h: u32 } {
    return .{ .w = self.layer.width, .h = self.layer.height };
}

pub fn hideBoxes(self: *Self) !void {
    self.grid.dropDesktopWindows();
}

/// Pumps one batch of Wayland events. Returns false if the connection died or
/// the compositor closed our surface.
pub fn dispatch(self: *Self) bool {
    if (self.closed) return false;
    return c.wl_display_dispatch(self.display) >= 0;
}

// ─── Internal helpers ────────────────────────────────────────────────────────

fn repaint(self: *Self) !void {
    if (self.layer.size_dirty) try self.rebuildForScale();
    const buf = self.shm_pool.acquire() orelse return;
    const phys = self.layer.physicalSize();
    Renderer.render(
        buf.pixels,
        phys.w,
        phys.h,
        self.layer.scale_q120,
        &self.grid,
        &self.tile_text,
        &self.search_text,
        &self.desktop_text,
        .{},
    );
    self.layer.attachAndCommit(buf.buf);
    self.shm_pool.submit(buf);
}

fn rebuildForScale(self: *Self) !void {
    self.shm_pool.deinit();
    const phys = self.layer.physicalSize();
    try self.shm_pool.init(self.globals.shm.?, phys.w, phys.h);
    self.layer.applyViewport();

    self.tile_text.destroy();
    self.search_text.destroy();
    self.desktop_text.destroy();
    self.tile_text = try text.Renderer.create(self.allocator, scaledFont(LOGICAL_FONT_TILE, self.layer.scale_q120), .regular);
    self.search_text = try text.Renderer.create(self.allocator, scaledFont(LOGICAL_FONT_SEARCH, self.layer.scale_q120), .regular);
    self.desktop_text = try text.Renderer.create(self.allocator, scaledFont(LOGICAL_FONT_DESKTOP, self.layer.scale_q120), .bold);

    self.grid.setViewport(@intCast(self.layer.width), @intCast(self.layer.height));
    self.layer.size_dirty = false;
}

fn activateSelected(self: *Self) void {
    const dw = self.grid.selectedWindow() orelse return;
    self.callbacks.activateWindow(self, dw) catch {};
}

// ─── Registry global callbacks ────────────────────────────────────────────────

fn onRegistryGlobal(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32, iface: [*c]const u8, version: u32) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(data));
    const s = std.mem.span(iface);
    if (std.mem.eql(u8, s, "wl_compositor")) {
        self.globals.compositor = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_compositor_interface, @min(version, 5)));
    } else if (std.mem.eql(u8, s, "wl_shm")) {
        self.globals.shm = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_shm_interface, @min(version, 1)));
    } else if (std.mem.eql(u8, s, "zwlr_layer_shell_v1")) {
        self.globals.layer_shell = @ptrCast(c.wl_registry_bind(registry, name, &c.zwlr_layer_shell_v1_interface, @min(version, 4)));
    } else if (std.mem.eql(u8, s, "wl_seat")) {
        const seat: *c.wl_seat = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_seat_interface, @min(version, 7)));
        self.globals.seat = seat;
        // Attach the seat listener immediately so the capabilities event,
        // which the compositor sends right after binding, lands in our
        // onSeatCaps callback in this same roundtrip.
        _ = c.wl_seat_add_listener(seat, &self.seat_listener, self);
    } else if (std.mem.eql(u8, s, "wp_fractional_scale_manager_v1")) {
        self.globals.fractional_scale_mgr = @ptrCast(c.wl_registry_bind(registry, name, &c.wp_fractional_scale_manager_v1_interface, @min(version, 1)));
    } else if (std.mem.eql(u8, s, "wp_viewporter")) {
        self.globals.viewporter = @ptrCast(c.wl_registry_bind(registry, name, &c.wp_viewporter_interface, @min(version, 1)));
    }
}

fn onRegistryRemove(_: ?*anyopaque, _: ?*c.wl_registry, _: u32) callconv(.c) void {}

// ─── Seat capability dispatcher ───────────────────────────────────────────────

fn onSeatCaps(data: ?*anyopaque, seat: ?*c.wl_seat, caps: u32) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(data));
    std.log.debug("wl_seat caps: 0x{x}", .{caps});
    if (caps & c.WL_SEAT_CAPABILITY_KEYBOARD != 0 and self.keyboard.keyboard == null) {
        if (c.wl_seat_get_keyboard(seat)) |kb| self.keyboard.attachKeyboard(kb);
    }
    if (caps & c.WL_SEAT_CAPABILITY_POINTER != 0 and self.mouse.pointer == null) {
        if (c.wl_seat_get_pointer(seat)) |p| self.mouse.attachPointer(p);
    }
}

fn onSeatName(_: ?*anyopaque, _: ?*c.wl_seat, _: [*c]const u8) callconv(.c) void {}

// ─── Action sinks ─────────────────────────────────────────────────────────────

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
    // No settings UI on Wayland; forward to the (no-op) presenter handler.
    self.callbacks.openSettings(self) catch {};
}

fn onKeyboardAction(ctx: *anyopaque, action: input.KeyAction) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    input.dispatchKey(&self.grid, self.hooks(), action);
    self.repaint() catch {};
    _ = c.wl_display_flush(self.display);
}

fn onMouseAction(ctx: *anyopaque, action: input.MouseAction) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    input.dispatchMouse(&self.grid, self.hooks(), action);
    self.repaint() catch {};
    _ = c.wl_display_flush(self.display);
}
