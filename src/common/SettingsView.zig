// Shared settings panel: pure layout + software render + a press-to-bind input
// state machine. Modeled on Grid.zig — no platform deps. Each platform hosts it
// in a small titled window, feeds it raw key/mouse-button events, reads the
// `changed`/`close_requested` flags, and presents the framebuffer this renders.
//
// Coordinates are logical (DPI-independent), like Grid: hit-testing works in
// logical space; `render` scales to physical pixels via scale_q120.

const std = @import("std");
const Config = @import("Config.zig");
const Renderer = @import("Renderer.zig");

const Self = @This();

/// Logical design size; the host sizes the window's client area to this.
pub const DESIGN_W: i32 = 440;
pub const DESIGN_H: i32 = 280;

const MARGIN: i32 = 20;
const ROW_H: i32 = 28;
const BTN_W: i32 = 110;
const BTN_H: i32 = 26;
const VALUE_X: i32 = 150;
const ROW1_Y: i32 = 60;
const ROW2_Y: i32 = 104;
const TOGGLE_Y: i32 = 148;
const TOGGLE2_Y: i32 = 184;
const CHECK_SZ: i32 = 16;

const COL_BG: u32 = 0xFFF2F2F2;
const COL_TEXT: u32 = 0xFF1A1A1A;
const COL_MUTED: u32 = 0xFF6A6A6A;
const COL_BTN_BG: u32 = 0xFFFFFFFF;
const COL_BORDER: u32 = 0xFF9A9A9A;
const COL_HILITE: u32 = 0xFF2E6FDB;
const COL_HILITE_TEXT: u32 = 0xFFFFFFFF;

pub const Region = enum { none, record_keyboard, record_mouse, toggle_mouse, toggle_center, close };
pub const RecordTarget = enum { none, keyboard, mouse };

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    fn contains(r: Rect, px: i32, py: i32) bool {
        return px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h;
    }
};

pub const Rects = struct {
    record_keyboard: Rect,
    record_mouse: Rect,
    toggle_mouse: Rect,
    toggle_center: Rect,
    close: Rect,
};

settings: *Config.Settings,
viewport_w: i32 = DESIGN_W,
viewport_h: i32 = DESIGN_H,
record_target: RecordTarget = .none,
/// Set when `settings` is mutated; the host persists + applies, then clears it.
changed: bool = false,
close_requested: bool = false,
/// Host-supplied display string for the current keyboard binding (the key name
/// is platform-specific, so the host formats it). Refreshed on open and after a
/// successful keyboard capture.
keyboard_label: [96]u8 = undefined,
keyboard_label_len: usize = 0,

pub fn init(settings: *Config.Settings) Self {
    return .{ .settings = settings };
}

pub fn setViewport(self: *Self, w: i32, h: i32) void {
    self.viewport_w = w;
    self.viewport_h = h;
}

pub fn setKeyboardLabel(self: *Self, bytes: []const u8) void {
    const n = @min(bytes.len, self.keyboard_label.len);
    @memcpy(self.keyboard_label[0..n], bytes[0..n]);
    self.keyboard_label_len = n;
}

fn keyboardLabel(self: *const Self) []const u8 {
    return self.keyboard_label[0..self.keyboard_label_len];
}

pub fn isRecording(self: *const Self) bool {
    return self.record_target != .none;
}

/// Interactive-element rectangles in logical coordinates. `render` and
/// `regionAt` both derive from this so they always agree.
pub fn layout(self: *const Self) Rects {
    const btn_x = self.viewport_w - MARGIN - BTN_W;
    return .{
        .record_keyboard = .{ .x = btn_x, .y = ROW1_Y, .w = BTN_W, .h = BTN_H },
        .record_mouse = .{ .x = btn_x, .y = ROW2_Y, .w = BTN_W, .h = BTN_H },
        .toggle_mouse = .{ .x = MARGIN, .y = TOGGLE_Y, .w = CHECK_SZ, .h = CHECK_SZ },
        .toggle_center = .{ .x = MARGIN, .y = TOGGLE2_Y, .w = CHECK_SZ, .h = CHECK_SZ },
        .close = .{ .x = self.viewport_w - MARGIN - 90, .y = self.viewport_h - MARGIN - 28, .w = 90, .h = 28 },
    };
}

pub fn regionAt(self: *const Self, x: i32, y: i32) Region {
    const r = self.layout();
    // Let each toggle's whole label row be clickable, not just the box.
    const mouse_row: Rect = .{ .x = MARGIN, .y = TOGGLE_Y, .w = self.viewport_w - 2 * MARGIN, .h = CHECK_SZ };
    const center_row: Rect = .{ .x = MARGIN, .y = TOGGLE2_Y, .w = self.viewport_w - 2 * MARGIN, .h = CHECK_SZ };
    if (r.record_keyboard.contains(x, y)) return .record_keyboard;
    if (r.record_mouse.contains(x, y)) return .record_mouse;
    if (mouse_row.contains(x, y)) return .toggle_mouse;
    if (center_row.contains(x, y)) return .toggle_center;
    if (r.close.contains(x, y)) return .close;
    return .none;
}

/// Handle a click at logical (x, y). Returns the region acted on.
pub fn click(self: *Self, x: i32, y: i32) Region {
    const region = self.regionAt(x, y);
    switch (region) {
        .record_keyboard => self.record_target = .keyboard,
        .record_mouse => self.record_target = .mouse,
        .toggle_mouse => {
            self.settings.mouse_enabled = !self.settings.mouse_enabled;
            self.changed = true;
        },
        .toggle_center => {
            self.settings.center_on_cursor = !self.settings.center_on_cursor;
            self.changed = true;
        },
        .close => self.close_requested = true,
        .none => {},
    }
    return region;
}

/// Press-to-bind: record a raw keyboard event as the new hotkey. The host calls
/// this only for non-modifier key-downs (and passes the live modifier state).
/// Returns true if a binding was captured.
pub fn captureKey(self: *Self, keycode: u32, mods: Config.Mods) bool {
    if (self.record_target != .keyboard) return false;
    self.settings.keyboard = .{ .keycode = keycode, .mods = mods };
    self.record_target = .none;
    self.changed = true;
    return true;
}

/// Press-to-bind: record a mouse button as the trigger. Left/none are refused
/// (binding the left button would break normal clicking). Returns true if a
/// binding was captured.
pub fn captureMouseButton(self: *Self, binding: Config.MouseBinding) bool {
    if (self.record_target != .mouse) return false;
    if (binding.kind == .none or binding.kind == .left) return false;
    self.settings.mouse = binding;
    self.record_target = .none;
    self.changed = true;
    return true;
}

/// Cancel an in-progress recording (e.g. host saw Escape). Returns true if a
/// recording was active.
pub fn cancelRecording(self: *Self) bool {
    if (self.record_target == .none) return false;
    self.record_target = .none;
    return true;
}

// ─── Render ──────────────────────────────────────────────────────────────────

/// Draw the panel into `pixels` (ARGB8888, `pw` u32s per row). `text` is a
/// duck-typed glyph renderer (the host's body font); `title` a bold/larger one.
pub fn render(self: *const Self, pixels: []u32, pw: u32, ph: u32, scale_q120: u32, text: anytype, title: anytype) void {
    const S = struct {
        q: u32,
        fn s(self2: @This(), v: i32) i32 {
            return @divFloor(v * @as(i32, @intCast(self2.q)), 120);
        }
    }{ .q = scale_q120 };

    // Anonymous-struct clip literals only coerce to the text renderer's Clip
    // type at the call site (not through a stored const/param), so each draw
    // below builds its own with the framebuffer extents.
    const cw: i32 = @intCast(pw);
    const ch: i32 = @intCast(ph);
    Renderer.fillRect(pixels, pw, 0, 0, @intCast(pw), @intCast(ph), COL_BG);

    // Heading.
    _ = title.draw(pixels, pw, S.s(MARGIN), S.s(24) + title.ascent, "Vitrail Settings", COL_TEXT, .{ .x0 = 0, .y0 = 0, .x1 = cw, .y1 = ch }) catch 0;

    // Row 1: keyboard shortcut.
    drawLabel(pixels, pw, S, text, MARGIN, ROW1_Y, "Keyboard shortcut", COL_TEXT, cw, ch);
    if (self.record_target == .keyboard) {
        drawLabel(pixels, pw, S, text, VALUE_X, ROW1_Y, "Press a shortcut…", COL_HILITE, cw, ch);
    } else {
        const lbl = if (self.keyboard_label_len > 0) self.keyboardLabel() else "(unset)";
        drawLabel(pixels, pw, S, text, VALUE_X, ROW1_Y, lbl, COL_MUTED, cw, ch);
    }
    drawButton(pixels, pw, S, text, self.btnRect(ROW1_Y), "Record", self.record_target == .keyboard, cw, ch);

    // Row 2: mouse button.
    drawLabel(pixels, pw, S, text, MARGIN, ROW2_Y, "Mouse button", COL_TEXT, cw, ch);
    if (self.record_target == .mouse) {
        drawLabel(pixels, pw, S, text, VALUE_X, ROW2_Y, "Press a button…", COL_HILITE, cw, ch);
    } else {
        var buf: [64]u8 = undefined;
        const lbl = Config.mouseButtonLabel(self.settings.mouse, &buf);
        drawLabel(pixels, pw, S, text, VALUE_X, ROW2_Y, lbl, COL_MUTED, cw, ch);
    }
    drawButton(pixels, pw, S, text, self.btnRect(ROW2_Y), "Record", self.record_target == .mouse, cw, ch);

    // Toggles.
    drawCheckbox(pixels, pw, S, text, TOGGLE_Y, self.settings.mouse_enabled, "Enable mouse-button trigger", cw, ch);
    drawCheckbox(pixels, pw, S, text, TOGGLE2_Y, self.settings.center_on_cursor, "Center grid at cursor (mouse)", cw, ch);

    // Close button (bottom-right).
    const r = self.layout();
    drawButton(pixels, pw, S, text, r.close, "Close", false, cw, ch);
}

fn drawCheckbox(pixels: []u32, pw: u32, S: anytype, text: anytype, y: i32, checked: bool, label: []const u8, cw: i32, ch: i32) void {
    const box_x = S.s(MARGIN);
    const box_y = S.s(y);
    const box = S.s(CHECK_SZ);
    Renderer.fillRect(pixels, pw, box_x, box_y, box, box, COL_BTN_BG);
    Renderer.drawRect(pixels, pw, box_x, box_y, box, box, COL_BORDER);
    if (checked) {
        const inset = S.s(4);
        Renderer.fillRect(pixels, pw, box_x + inset, box_y + inset, box - 2 * inset, box - 2 * inset, COL_HILITE);
    }
    drawLabel(pixels, pw, S, text, MARGIN + CHECK_SZ + 8, y - 4, label, COL_TEXT, cw, ch);
}

fn btnRect(self: *const Self, row_y: i32) Rect {
    return .{ .x = self.viewport_w - MARGIN - BTN_W, .y = row_y, .w = BTN_W, .h = BTN_H };
}

fn drawLabel(pixels: []u32, pw: u32, S: anytype, text: anytype, x: i32, y: i32, str: []const u8, color: u32, cw: i32, ch: i32) void {
    const baseline = S.s(y) + text.ascent;
    _ = text.draw(pixels, pw, S.s(x), baseline, str, color, .{ .x0 = 0, .y0 = 0, .x1 = cw, .y1 = ch }) catch 0;
}

fn drawButton(pixels: []u32, pw: u32, S: anytype, text: anytype, rect: Rect, label: []const u8, highlighted: bool, cw: i32, ch: i32) void {
    const x = S.s(rect.x);
    const y = S.s(rect.y);
    const rw = S.s(rect.x + rect.w) - x;
    const rh = S.s(rect.y + rect.h) - y;
    Renderer.fillRect(pixels, pw, x, y, rw, rh, if (highlighted) COL_HILITE else COL_BTN_BG);
    Renderer.drawRect(pixels, pw, x, y, rw, rh, COL_BORDER);
    const tw = text.measure(label) catch 0;
    const tx = x + @divFloor(rw - tw, 2);
    const baseline = y + @divFloor(rh + text.ascent, 2);
    _ = text.draw(pixels, pw, tx, baseline, label, if (highlighted) COL_HILITE_TEXT else COL_TEXT, .{ .x0 = 0, .y0 = 0, .x1 = cw, .y1 = ch }) catch 0;
}

// ─── Tests (pure state machine + hit-testing) ────────────────────────────────

test "regionAt maps button centers" {
    var settings: Config.Settings = .{};
    var v = Self.init(&settings);
    v.setViewport(DESIGN_W, DESIGN_H);
    const r = v.layout();
    const center = struct {
        fn c(rect: Rect) [2]i32 {
            return .{ rect.x + @divFloor(rect.w, 2), rect.y + @divFloor(rect.h, 2) };
        }
    }.c;
    const k = center(r.record_keyboard);
    try std.testing.expectEqual(Region.record_keyboard, v.regionAt(k[0], k[1]));
    const m = center(r.record_mouse);
    try std.testing.expectEqual(Region.record_mouse, v.regionAt(m[0], m[1]));
    const cl = center(r.close);
    try std.testing.expectEqual(Region.close, v.regionAt(cl[0], cl[1]));
    try std.testing.expectEqual(Region.none, v.regionAt(0, 0));
}

test "click starts recording; captureKey binds and clears" {
    var settings: Config.Settings = .{};
    var v = Self.init(&settings);
    v.setViewport(DESIGN_W, DESIGN_H);
    const r = v.layout();
    _ = v.click(r.record_keyboard.x + 1, r.record_keyboard.y + 1);
    try std.testing.expect(v.isRecording());
    try std.testing.expect(v.captureKey(49, .{ .alt = true }));
    try std.testing.expect(!v.isRecording());
    try std.testing.expect(v.changed);
    try std.testing.expectEqual(@as(u32, 49), settings.keyboard.keycode);
    try std.testing.expect(settings.keyboard.mods.alt);
}

test "captureMouseButton refuses left and none" {
    var settings: Config.Settings = .{};
    var v = Self.init(&settings);
    v.record_target = .mouse;
    try std.testing.expect(!v.captureMouseButton(.{ .kind = .left }));
    try std.testing.expect(!v.captureMouseButton(.{ .kind = .none }));
    try std.testing.expect(v.isRecording()); // still recording after refusal
    try std.testing.expect(v.captureMouseButton(.{ .kind = .x1, .code = 3 }));
    try std.testing.expectEqual(Config.MouseButtonKind.x1, settings.mouse.kind);
    try std.testing.expect(!v.isRecording());
}

test "toggles flip flags; close requests close" {
    var settings: Config.Settings = .{ .mouse_enabled = true, .center_on_cursor = true };
    var v = Self.init(&settings);
    v.setViewport(DESIGN_W, DESIGN_H);

    try std.testing.expectEqual(Region.toggle_mouse, v.regionAt(MARGIN + 1, TOGGLE_Y + 1));
    _ = v.click(MARGIN + 1, TOGGLE_Y + 1);
    try std.testing.expect(!settings.mouse_enabled);
    try std.testing.expect(v.changed);

    v.changed = false;
    try std.testing.expectEqual(Region.toggle_center, v.regionAt(MARGIN + 1, TOGGLE2_Y + 1));
    _ = v.click(MARGIN + 1, TOGGLE2_Y + 1);
    try std.testing.expect(!settings.center_on_cursor);
    try std.testing.expect(v.changed);

    const r = v.layout();
    _ = v.click(r.close.x + 1, r.close.y + 1);
    try std.testing.expect(v.close_requested);
}

test "cancelRecording clears state" {
    var settings: Config.Settings = .{};
    var v = Self.init(&settings);
    v.record_target = .keyboard;
    try std.testing.expect(v.cancelRecording());
    try std.testing.expect(!v.isRecording());
    try std.testing.expect(!v.cancelRecording());
}

// Duck-typed stand-in for the platform glyph renderer, so render's geometry +
// scaling can be exercised headlessly (no font backend) and asserted not to
// write outside the framebuffer.
const StubText = struct {
    ascent: i32 = 10,
    fn measure(_: *StubText, s: []const u8) !i32 {
        return @intCast(s.len * 7);
    }
    fn draw(_: *StubText, _: []u32, _: u32, x: i32, _: i32, _: []const u8, _: u32, _: anytype) !i32 {
        return x;
    }
};

test "render fills the panel and stays in bounds" {
    const a = std.testing.allocator;
    var settings: Config.Settings = .{ .mouse = .{ .kind = .x1, .code = 3 }, .mouse_enabled = true };
    var v = Self.init(&settings);
    v.setViewport(DESIGN_W, DESIGN_H);
    v.setKeyboardLabel("⌥Space");

    const px = try a.alloc(u32, @intCast(DESIGN_W * DESIGN_H));
    defer a.free(px);
    @memset(px, 0);

    var body = StubText{};
    var title = StubText{};
    // Render at 1x and at 1.5x to exercise the scale path too.
    v.render(px, @intCast(DESIGN_W), @intCast(DESIGN_H), 120, &body, &title);
    try std.testing.expectEqual(COL_BG, px[0]);
    v.render(px, @intCast(DESIGN_W), @intCast(DESIGN_H), 180, &body, &title);
    try std.testing.expectEqual(COL_BG, px[0]);

    // Recording states render distinct prompts without crashing.
    v.record_target = .keyboard;
    v.render(px, @intCast(DESIGN_W), @intCast(DESIGN_H), 120, &body, &title);
    v.record_target = .mouse;
    v.render(px, @intCast(DESIGN_W), @intCast(DESIGN_H), 120, &body, &title);
}
