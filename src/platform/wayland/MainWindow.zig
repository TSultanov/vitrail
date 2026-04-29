const std = @import("std");
const common = @import("../../common/DesktopWindow.zig");
const wc = @import("wayland_c.zig");
const c = wc.c;

const LayerSurface = @import("LayerSurface.zig");
const ShmPool = @import("ShmPool.zig");
const Keyboard = @import("Keyboard.zig");
const Grid = @import("Grid.zig");
const Renderer = @import("Renderer.zig");
const text = @import("text.zig");

const Self = @This();

pub const PlatformArgs = struct {};

pub const Callbacks = struct {
    activateWindow: *const fn (*Self, common.DesktopWindow) anyerror!void,
    hide: *const fn (*Self) anyerror!void,
};

const Globals = struct {
    compositor: ?*c.wl_compositor = null,
    shm: ?*c.wl_shm = null,
    layer_shell: ?*c.zwlr_layer_shell_v1 = null,
    seat: ?*c.wl_seat = null,
};

// Sized to roughly match Win32 DEFAULT_GUI_FONT (Tahoma ~9pt → ~12px) and the
// Segoe UI Bold 32pt-scaled badge used for the desktop number.
const FONT_TILE: u32 = 12;
const FONT_SEARCH: u32 = 12;
const FONT_DESKTOP: u32 = 32;

allocator: std.mem.Allocator,
callbacks: *Callbacks,

display: *c.wl_display,
globals: Globals,
registry_listener: c.wl_registry_listener,

layer: LayerSurface,
shm_pool: ShmPool,
keyboard: Keyboard,
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
        .grid = Grid.init(allocator),
        .tile_text = undefined,
        .search_text = undefined,
        .desktop_text = undefined,
        .closed = false,
        .running = true,
    };

    const registry = c.wl_display_get_registry(display) orelse return error.RegistryFailed;
    _ = c.wl_registry_add_listener(registry, &self.registry_listener, self);
    _ = c.wl_display_roundtrip(display);

    if (self.globals.compositor == null or self.globals.shm == null or self.globals.layer_shell == null) {
        return error.MissingWaylandGlobals;
    }

    try self.layer.init(self.globals.compositor.?, self.globals.layer_shell.?, &self.closed);

    _ = c.wl_display_roundtrip(display);
    if (!self.layer.configured) return error.LayerSurfaceNotConfigured;

    try self.shm_pool.init(self.globals.shm.?, self.layer.width, self.layer.height);
    try self.keyboard.init(.{ .on_action = onKeyboardAction, .ctx = self });
    if (self.globals.seat) |seat| self.keyboard.attachSeat(seat);

    self.grid.setViewport(@intCast(self.layer.width), @intCast(self.layer.height));

    self.tile_text = try text.Renderer.create(allocator, FONT_TILE, .regular);
    errdefer self.tile_text.destroy();
    self.search_text = try text.Renderer.create(allocator, FONT_SEARCH, .regular);
    errdefer self.search_text.destroy();
    self.desktop_text = try text.Renderer.create(allocator, FONT_DESKTOP, .bold);
    errdefer self.desktop_text.destroy();

    return self;
}

pub fn deinit(self: *Self) void {
    self.desktop_text.destroy();
    self.search_text.destroy();
    self.tile_text.destroy();
    self.grid.deinit();
    self.keyboard.deinit();
    self.shm_pool.deinit();
    self.layer.deinit();
    _ = c.wl_display_disconnect(self.display);
    self.allocator.destroy(self);
}

// ─── Platform contract ────────────────────────────────────────────────────────

pub fn show(self: *Self) !void {
    try self.repaint();
    _ = c.wl_display_flush(self.display);
}

pub fn activate(_: *Self) void {}

pub fn requestQuit(self: *Self) void {
    self.running = false;
}

pub fn setDesktopWindows(self: *Self, dws: std.array_list.Managed(common.DesktopWindow)) !void {
    try self.grid.setDesktopWindows(dws);
    try self.repaint();
    _ = c.wl_display_flush(self.display);
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
    const buf = self.shm_pool.acquire() orelse return;
    Renderer.render(
        buf.pixels,
        self.layer.width,
        self.layer.height,
        &self.grid,
        &self.tile_text,
        &self.search_text,
        &self.desktop_text,
        .{},
    );
    self.layer.attachAndCommit(buf.buf);
    self.shm_pool.submit(buf);
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
        self.globals.seat = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_seat_interface, @min(version, 7)));
    }
}

fn onRegistryRemove(_: ?*anyopaque, _: ?*c.wl_registry, _: u32) callconv(.c) void {}

// ─── Keyboard action sink ─────────────────────────────────────────────────────

fn onKeyboardAction(ctx: *anyopaque, action: Keyboard.Action) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    switch (action) {
        .quit => self.callbacks.hide(self) catch {},
        .activate => self.activateSelected(),
        .next => self.grid.selectNext(false),
        .prev => self.grid.selectNext(true),
        .move => |m| self.grid.selectDir(m.dx, m.dy),
        .backspace => self.grid.popSearchCodepoint() catch {},
        .insert => |bytes| self.grid.appendSearch(bytes) catch {},
    }
    self.repaint() catch {};
    _ = c.wl_display_flush(self.display);
}
