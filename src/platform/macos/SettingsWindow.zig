// macOS host for the shared settings panel. Owns a titled bridge window, a
// framebuffer, the body/title glyph caches, and the platform-agnostic
// SettingsView. Feeds raw key / mouse-button events into the view for
// press-to-bind, and presents the view's render via the same CGImage→layer path
// the overlay uses. On any settings change it invokes the entry-point's `apply`
// callback (re-register hotkey + persist).

const std = @import("std");
const bridge = @import("bridge.zig");
const text = @import("text.zig");
const Keyboard = @import("Keyboard.zig");
const MouseHook = @import("MouseHook.zig");
const Config = @import("../../common/Config.zig");
const SettingsView = @import("../../common/SettingsView.zig");

const cg = @cImport({
    @cInclude("CoreGraphics/CoreGraphics.h");
});

const Self = @This();

const LOGICAL_BODY: u32 = 13;
const LOGICAL_TITLE: u32 = 18;
const kVK_Escape: c_int = 0x35;

allocator: std.mem.Allocator,
window: *bridge.VtWindow,
view: SettingsView,
settings: *Config.Settings,
on_apply: *const fn (ctx: *anyopaque) void,
// Called with the current recording state after every input event so the entry
// point can suppress/restore the global triggers during press-to-bind.
on_suppress: *const fn (ctx: *anyopaque, suppress: bool) void,
apply_ctx: *anyopaque,

body_text: text.Renderer,
title_text: text.Renderer,

pixels: []u32 = &.{},
physical_w: u32 = 0,
physical_h: u32 = 0,
scale_q120: u32 = 120,
size_dirty: bool = false,

pub fn create(
    allocator: std.mem.Allocator,
    settings: *Config.Settings,
    on_apply: *const fn (ctx: *anyopaque) void,
    on_suppress: *const fn (ctx: *anyopaque, suppress: bool) void,
    apply_ctx: *anyopaque,
) !*Self {
    var self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .window = undefined,
        .view = SettingsView.init(settings),
        .settings = settings,
        .on_apply = on_apply,
        .on_suppress = on_suppress,
        .apply_ctx = apply_ctx,
        .body_text = try text.Renderer.create(allocator, LOGICAL_BODY, .regular),
        .title_text = try text.Renderer.create(allocator, LOGICAL_TITLE, .bold),
    };
    errdefer self.body_text.destroy();
    errdefer self.title_text.destroy();

    const w = bridge.vt_settings_create(
        self,
        SettingsView.DESIGN_W,
        SettingsView.DESIGN_H,
        onKeyCb,
        onMouseCb,
        onResizeCb,
        onCloseCb,
        onCaptureCb,
    ) orelse return error.WindowCreate;
    self.window = w;

    self.refreshKeyboardLabel();
    return self;
}

pub fn destroy(self: *Self) void {
    self.title_text.destroy();
    self.body_text.destroy();
    if (self.pixels.len != 0) self.allocator.free(self.pixels);
    bridge.vt_window_destroy(self.window);
    self.allocator.destroy(self);
}

pub fn show(self: *Self) void {
    self.view.record_target = .none;
    self.view.close_requested = false;
    self.refreshKeyboardLabel();
    self.syncSuppress(); // not recording on open → triggers active
    bridge.vt_window_show(self.window);
    self.repaint() catch {};
}

fn hide(self: *Self) void {
    self.view.record_target = .none;
    self.syncSuppress(); // recording cancelled → restore triggers
    bridge.vt_window_hide(self.window);
}

fn applyIfChanged(self: *Self) void {
    if (!self.view.changed) return;
    self.on_apply(self.apply_ctx);
    self.refreshKeyboardLabel();
    self.view.changed = false;
}

/// Tell the entry point whether the settings UI is currently recording, so it
/// can suppress/restore the global keyboard hotkey + mouse hook. Idempotent on
/// the receiving side.
fn syncSuppress(self: *Self) void {
    self.on_suppress(self.apply_ctx, self.view.isRecording());
}

fn refreshKeyboardLabel(self: *Self) void {
    var mods_buf: [48]u8 = undefined;
    const mods = Config.modsLabel(self.settings.keyboard.mods, true, &mods_buf);
    var name_buf: [32]u8 = undefined;
    const name = keyName(self.settings.keyboard.keycode, &name_buf);
    var full: [96]u8 = undefined;
    const s = std.fmt.bufPrint(&full, "{s}{s}", .{ mods, name }) catch name;
    self.view.setKeyboardLabel(s);
}

// ─── Bridge callbacks (C ABI) ───────────────────────────────────────────────

fn onKeyCb(ctx: ?*anyopaque, virtual_keycode: c_int, modifiers: u32, _: [*c]const u8, _: c_int) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    if (self.view.isRecording()) {
        if (virtual_keycode == kVK_Escape) {
            _ = self.view.cancelRecording();
        } else {
            // keyDown only fires for non-modifier keys, so this is a real key.
            if (self.view.captureKey(@intCast(virtual_keycode), Keyboard.modsFromFlags(modifiers)))
                self.applyIfChanged();
        }
    } else if (virtual_keycode == kVK_Escape) {
        self.hide();
        return;
    }
    self.syncSuppress();
    self.repaint() catch {};
}

fn onMouseCb(ctx: ?*anyopaque, kind: c_int, x: f64, y: f64) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    if (kind != 1) return; // left button down only
    _ = self.view.click(@intFromFloat(x), @intFromFloat(y));
    if (self.view.close_requested) {
        self.hide();
        return;
    }
    self.applyIfChanged();
    self.syncSuppress();
    self.repaint() catch {};
}

fn onCaptureCb(ctx: ?*anyopaque, is_right: c_int, button_number: c_long) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    if (!self.view.isRecording()) return;
    const binding = MouseHook.classifyButtonNumber(is_right != 0, @intCast(button_number));
    if (self.view.captureMouseButton(binding)) self.applyIfChanged();
    self.syncSuppress();
    self.repaint() catch {};
}

fn onResizeCb(ctx: ?*anyopaque, pw: u32, ph: u32, lw: u32, lh: u32, scale: f64) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    const new_q120: u32 = @intFromFloat(@round(scale * 120));
    if (self.physical_w != pw or self.physical_h != ph or self.scale_q120 != new_q120) {
        self.size_dirty = true;
    }
    self.physical_w = pw;
    self.physical_h = ph;
    self.scale_q120 = new_q120;
    self.view.setViewport(@intCast(lw), @intCast(lh));
}

fn onCloseCb(ctx: ?*anyopaque) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    // The window has been ordered out by AppKit; just reset transient state so
    // a later re-open starts clean. The object is kept for reuse.
    self.view.record_target = .none;
    self.syncSuppress(); // restore triggers if closed mid-recording
}

// ─── Repaint ────────────────────────────────────────────────────────────────

fn repaint(self: *Self) !void {
    if (self.size_dirty) try self.rebuildForScale();
    if (self.pixels.len == 0 or self.physical_w == 0 or self.physical_h == 0) return;

    self.view.render(self.pixels, self.physical_w, self.physical_h, self.scale_q120, &self.body_text, &self.title_text);

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
        8,
        32,
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

    self.body_text.destroy();
    self.title_text.destroy();
    self.body_text = try text.Renderer.create(self.allocator, scaledFont(LOGICAL_BODY, self.scale_q120), .regular);
    self.title_text = try text.Renderer.create(self.allocator, scaledFont(LOGICAL_TITLE, self.scale_q120), .bold);
    self.size_dirty = false;
}

fn scaledFont(logical: u32, scale_q120: u32) u32 {
    return (logical * scale_q120 + 60) / 120;
}

// ─── Key name table (Apple virtual keycodes) ─────────────────────────────────

fn keyName(keycode: u32, buf: []u8) []const u8 {
    if (keycode < KEY_NAMES.len) {
        if (KEY_NAMES[keycode]) |n| return n;
    }
    return std.fmt.bufPrint(buf, "Key {d}", .{keycode}) catch "?";
}

const KEY_NAMES = blk: {
    var t = [_]?[]const u8{null} ** 128;
    t[0] = "A";
    t[1] = "S";
    t[2] = "D";
    t[3] = "F";
    t[4] = "H";
    t[5] = "G";
    t[6] = "Z";
    t[7] = "X";
    t[8] = "C";
    t[9] = "V";
    t[11] = "B";
    t[12] = "Q";
    t[13] = "W";
    t[14] = "E";
    t[15] = "R";
    t[16] = "Y";
    t[17] = "T";
    t[18] = "1";
    t[19] = "2";
    t[20] = "3";
    t[21] = "4";
    t[22] = "6";
    t[23] = "5";
    t[24] = "=";
    t[25] = "9";
    t[26] = "7";
    t[27] = "-";
    t[28] = "8";
    t[29] = "0";
    t[30] = "]";
    t[31] = "O";
    t[32] = "U";
    t[33] = "[";
    t[34] = "I";
    t[35] = "P";
    t[36] = "Return";
    t[37] = "L";
    t[38] = "J";
    t[39] = "'";
    t[40] = "K";
    t[41] = ";";
    t[42] = "\\";
    t[43] = ",";
    t[44] = "/";
    t[45] = "N";
    t[46] = "M";
    t[47] = ".";
    t[48] = "Tab";
    t[49] = "Space";
    t[50] = "`";
    t[51] = "Delete";
    t[53] = "Esc";
    t[123] = "←";
    t[124] = "→";
    t[125] = "↓";
    t[126] = "↑";
    break :blk t;
};
