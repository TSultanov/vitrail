// macOS MainWindow — owns the bridge window, the framebuffer, and the
// keyboard/mouse translation. Drives the shared Grid + Renderer.

const std = @import("std");
const builtin = @import("builtin");
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
    hide: *const fn (*Self) anyerror!void,
};

const LOGICAL_FONT_TILE: u32 = 12;
const LOGICAL_FONT_SEARCH: u32 = 12;
const LOGICAL_FONT_DESKTOP: u32 = 32;

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

    return self;
}

pub fn deinit(self: *Self) void {
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
    bridge.vt_window_show(self.window);
    if (self.size_dirty) try self.rebuildForScale();
    try self.repaint();
}

pub fn activate(_: *Self) void {}

pub fn requestQuit(self: *Self) void {
    self.running = false;
    bridge.vt_app_stop();
}

pub fn setDesktopWindows(self: *Self, dws: std.array_list.Managed(common.DesktopWindow)) !void {
    try self.grid.setDesktopWindows(dws.items);
    try self.repaint();
}

pub fn hideBoxes(self: *Self) !void {
    self.grid.dropDesktopWindows();
    bridge.vt_window_hide(self.window);
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

// ─── Action sinks ───────────────────────────────────────────────────────────

fn hooks(self: *Self) input.Hooks {
    return .{ .ctx = self, .hide = onHookHide, .activate_selected = onHookActivate };
}
fn onHookHide(ctx: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.callbacks.hide(self) catch {};
}
fn onHookActivate(ctx: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.activateSelected();
}

fn onKeyboardAction(ctx: *anyopaque, action: input.KeyAction) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    input.dispatchKey(&self.grid, self.hooks(), action);
    self.repaint() catch {};
}

fn onMouseAction(ctx: *anyopaque, action: input.MouseAction) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    input.dispatchMouse(&self.grid, self.hooks(), action);
    self.repaint() catch {};
}
