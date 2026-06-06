// Windows host for the shared settings panel. A normal titled window that
// renders the platform-agnostic SettingsView into a DIB framebuffer (same
// software-renderer → GDI BitBlt path the overlay's Layout uses) and feeds it
// raw key / mouse-button events for press-to-bind. Closing hides the window
// (it is reused on the next open); resources free at app exit.

const std = @import("std");
const wh = @import("windows.zig");
const w = wh.c;
const sys = @import("SystemInteraction.zig");
const text = @import("text.zig");
const Config = @import("../../common/Config.zig");
const SettingsView = @import("../../common/SettingsView.zig");
const MouseButtons = @import("MouseButtons.zig");
pub const Window = @import("Window.zig");

const Self = @This();

const LOGICAL_BODY: u32 = 13;
const LOGICAL_TITLE: u32 = 18;

window: *Window,
allocator: std.mem.Allocator,
event_handlers: Window.EventHandlers,
view: SettingsView,
settings: *Config.Settings,
on_apply: *const fn (ctx: *anyopaque) void,
apply_ctx: *anyopaque,

// DIB framebuffer (top-down 32bpp), same approach as Layout.zig.
fb_pixels: []u32 = &.{},
fb_w: u32 = 0,
fb_h: u32 = 0,
dib_bitmap: ?w.HBITMAP = null,
dib_dc: ?w.HDC = null,
dib_old_bmp: ?w.HGDIOBJ = null,

body_text: text.Renderer = undefined,
title_text: text.Renderer = undefined,
fonts_dpi: u32 = 0,

// Last mouse position (logical), so the left-click handler — which gets no
// coordinates — can hit-test the panel.
last_x: i32 = 0,
last_y: i32 = 0,

pub fn create(
    hInstance: w.HINSTANCE,
    allocator: std.mem.Allocator,
    settings: *Config.Settings,
    on_apply: *const fn (ctx: *anyopaque) void,
    apply_ctx: *anyopaque,
) !*Self {
    var self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .window = undefined,
        .allocator = allocator,
        .view = SettingsView.init(settings),
        .settings = settings,
        .on_apply = on_apply,
        .apply_ctx = apply_ctx,
        .event_handlers = .{
            .onPaint = onPaintHandler,
            .onClose = onCloseHandler,
            .onKeyDown = onKeyDownHandler,
            .onMouseButton = onMouseButtonHandler,
            .onMouseMove = onMouseMoveHandler,
            .onClick = onClickHandler,
            .onResize = onResizeHandler,
            .onAfterDestroy = onAfterDestroyHandler,
        },
    };

    const cfg = Window.WindowParameters{
        .title = sys.toUtf16const("Vitrail Settings"),
        .className = sys.toUtf16const("VitrailSettings"),
        .style = w.WS_OVERLAPPED | w.WS_CAPTION | w.WS_SYSMENU | w.WS_MINIMIZEBOX,
        .width = SettingsView.DESIGN_W,
        .height = SettingsView.DESIGN_H + 32, // rough title-bar allowance
        .register_class = true,
    };
    self.window = try Window.create(cfg, &self.event_handlers, hInstance, allocator);

    try self.ensureFonts();
    self.refreshKeyboardLabel();
    return self;
}

pub fn show(self: *Self) void {
    self.view.record_target = .none;
    self.view.close_requested = false;
    self.refreshKeyboardLabel();
    _ = w.ShowWindow(self.window.hwnd, w.SW_SHOW);
    _ = w.SetForegroundWindow(self.window.hwnd);
    _ = self.window.redraw() catch {};
}

fn applyIfChanged(self: *Self) void {
    if (!self.view.changed) return;
    self.on_apply(self.apply_ctx);
    self.refreshKeyboardLabel();
    self.view.changed = false;
}

fn refreshKeyboardLabel(self: *Self) void {
    var mods_buf: [48]u8 = undefined;
    const mods = Config.modsLabel(self.settings.keyboard.mods, false, &mods_buf);
    var name_buf: [32]u8 = undefined;
    const name = keyName(self.settings.keyboard.keycode, &name_buf);
    var full: [96]u8 = undefined;
    const s = std.fmt.bufPrint(&full, "{s}{s}", .{ mods, name }) catch name;
    self.view.setKeyboardLabel(s);
}

fn toLogical(self: *Self, x: i16, y: i16) struct { x: i32, y: i32 } {
    const dpi: c_int = @intCast(self.window.dpi);
    return .{ .x = w.MulDiv(x, 96, dpi), .y = w.MulDiv(y, 96, dpi) };
}

// ─── Event handlers ──────────────────────────────────────────────────────────

fn onCloseHandler(_: *Window.EventHandlers, window: *Window) !void {
    // Hide instead of destroy so the same window is reused on the next open.
    _ = w.ShowWindow(window.hwnd, w.SW_HIDE);
}

fn onMouseMoveHandler(event_handlers: *Window.EventHandlers, _: *Window, _: u64, x: i16, y: i16) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    const p = self.toLogical(x, y);
    self.last_x = p.x;
    self.last_y = p.y;
}

fn onClickHandler(event_handlers: *Window.EventHandlers, _: *Window) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    _ = self.view.click(self.last_x, self.last_y);
    if (self.view.close_requested) {
        _ = w.ShowWindow(self.window.hwnd, w.SW_HIDE);
        self.view.close_requested = false;
        return;
    }
    self.applyIfChanged();
    try self.window.redraw();
}

fn onMouseButtonHandler(event_handlers: *Window.EventHandlers, _: *Window, msg: u32, mouse_data: u32, _: i16, _: i16) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    if (!self.view.isRecording()) return;
    const binding = MouseButtons.classify(msg, mouse_data);
    if (self.view.captureMouseButton(binding)) self.applyIfChanged();
    try self.window.redraw();
}

fn onKeyDownHandler(event_handlers: *Window.EventHandlers, _: *Window, wParam: w.WPARAM, _: w.LPARAM) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    const vk: u32 = @intCast(wParam);
    if (self.view.isRecording()) {
        if (vk == w.VK_ESCAPE) {
            _ = self.view.cancelRecording();
        } else if (!isModifierVk(vk)) {
            if (self.view.captureKey(vk, winMods())) self.applyIfChanged();
        }
        try self.window.redraw();
    } else if (vk == w.VK_ESCAPE) {
        _ = w.ShowWindow(self.window.hwnd, w.SW_HIDE);
    }
}

fn onResizeHandler(event_handlers: *Window.EventHandlers, _: *Window) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    try self.window.redraw();
}

fn onPaintHandler(event_handlers: *Window.EventHandlers, window: *Window) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    var ps: w.PAINTSTRUCT = undefined;
    const hdc = w.BeginPaint(window.hwnd, &ps);
    defer _ = w.EndPaint(window.hwnd, &ps);

    try self.ensureFramebuffer();
    try self.ensureFonts();
    self.renderFrame();

    _ = w.BitBlt(hdc, 0, 0, @intCast(self.fb_w), @intCast(self.fb_h), self.dib_dc.?, 0, 0, w.SRCCOPY);
}

fn onAfterDestroyHandler(event_handlers: *Window.EventHandlers, window: *Window) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    self.releaseFonts();
    self.releaseFramebuffer();
    self.allocator.destroy(window);
}

// ─── Framebuffer + fonts (mirrors Layout.zig) ────────────────────────────────

fn ensureFramebuffer(self: *Self) !void {
    const client = try self.window.getClientRect();
    const phys_w: u32 = @intCast(@max(@as(i32, 1), client.right - client.left));
    const phys_h: u32 = @intCast(@max(@as(i32, 1), client.bottom - client.top));

    if (phys_w != self.fb_w or phys_h != self.fb_h or self.dib_bitmap == null) {
        self.releaseFramebuffer();

        var bmi: w.BITMAPINFO = std.mem.zeroes(w.BITMAPINFO);
        bmi.bmiHeader.biSize = @sizeOf(w.BITMAPINFOHEADER);
        bmi.bmiHeader.biWidth = @intCast(phys_w);
        bmi.bmiHeader.biHeight = -@as(i32, @intCast(phys_h));
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32;
        bmi.bmiHeader.biCompression = 0;

        var bits: ?*anyopaque = null;
        const screen_dc = w.GetDC(null);
        defer _ = w.ReleaseDC(null, screen_dc);

        const hbm = w.CreateDIBSection(screen_dc, &bmi, w.DIB_RGB_COLORS, &bits, null, 0);
        if (@intFromPtr(hbm) == 0 or bits == null) return error.CreateDIBSectionFailed;
        errdefer _ = w.DeleteObject(hbm);

        const mem_dc = w.CreateCompatibleDC(screen_dc);
        if (@intFromPtr(mem_dc) == 0) return error.CreateCompatibleDC;
        errdefer _ = w.DeleteDC(mem_dc);

        const old_bmp = w.SelectObject(mem_dc, hbm);

        self.dib_bitmap = hbm;
        self.dib_dc = mem_dc;
        self.dib_old_bmp = old_bmp;
        self.fb_w = phys_w;
        self.fb_h = phys_h;
        self.fb_pixels = @as([*]u32, @ptrCast(@alignCast(bits.?)))[0 .. phys_w * phys_h];
    }

    const dpi: c_int = @intCast(self.window.dpi);
    const lw = w.MulDiv(@as(c_int, @intCast(phys_w)), 96, dpi);
    const lh = w.MulDiv(@as(c_int, @intCast(phys_h)), 96, dpi);
    self.view.setViewport(lw, lh);
}

fn releaseFramebuffer(self: *Self) void {
    if (self.dib_dc) |mem_dc| {
        if (self.dib_old_bmp) |old| _ = w.SelectObject(mem_dc, old);
        _ = w.DeleteDC(mem_dc);
    }
    if (self.dib_bitmap) |hbm| _ = w.DeleteObject(hbm);
    self.dib_dc = null;
    self.dib_old_bmp = null;
    self.dib_bitmap = null;
    self.fb_pixels = &.{};
    self.fb_w = 0;
    self.fb_h = 0;
}

fn ensureFonts(self: *Self) !void {
    const dpi = self.window.dpi;
    if (self.fonts_dpi == dpi) return;
    self.releaseFonts();
    self.body_text = try text.Renderer.create(self.allocator, scaledFont(LOGICAL_BODY, dpi), .regular);
    errdefer self.body_text.destroy();
    self.title_text = try text.Renderer.create(self.allocator, scaledFont(LOGICAL_TITLE, dpi), .bold);
    self.fonts_dpi = dpi;
}

fn releaseFonts(self: *Self) void {
    if (self.fonts_dpi == 0) return;
    self.body_text.destroy();
    self.title_text.destroy();
    self.fonts_dpi = 0;
}

fn renderFrame(self: *Self) void {
    const dpi: u32 = @intCast(self.window.dpi);
    const scale_q120: u32 = (dpi * 120) / 96;
    self.view.render(self.fb_pixels, self.fb_w, self.fb_h, scale_q120, &self.body_text, &self.title_text);
}

fn scaledFont(logical: u32, dpi: u32) u32 {
    return (logical * dpi + 48) / 96;
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

fn winMods() Config.Mods {
    return .{
        .shift = w.GetKeyState(w.VK_SHIFT) < 0,
        .control = w.GetKeyState(w.VK_CONTROL) < 0,
        .alt = w.GetKeyState(w.VK_MENU) < 0,
        .super = (w.GetKeyState(w.VK_LWIN) < 0) or (w.GetKeyState(w.VK_RWIN) < 0),
    };
}

fn isModifierVk(vk: u32) bool {
    return switch (vk) {
        0x10, 0x11, 0x12, 0x5B, 0x5C, 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5 => true,
        else => false,
    };
}

fn keyName(vk: u32, buf: []u8) []const u8 {
    return switch (vk) {
        0x20 => "Space",
        0x0D => "Enter",
        0x09 => "Tab",
        0x1B => "Esc",
        0x25 => "Left",
        0x26 => "Up",
        0x27 => "Right",
        0x28 => "Down",
        0x30...0x39 => oneChar(buf, @intCast('0' + (vk - 0x30))),
        0x41...0x5A => oneChar(buf, @intCast('A' + (vk - 0x41))),
        else => std.fmt.bufPrint(buf, "Key {d}", .{vk}) catch "?",
    };
}

fn oneChar(buf: []u8, ch: u8) []const u8 {
    buf[0] = ch;
    return buf[0..1];
}
