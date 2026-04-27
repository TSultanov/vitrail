const std = @import("std");
const wh = @import("windows.zig");
const w = wh.c;
const sys = @import("SystemInteraction.zig");

pub const Callbacks = struct {
    clicked: *const fn (tile: *Self) anyerror!void,
};

const Self = @This();

const color_offset = 50;
const desktop_no_font_size = 32;

allocator: std.mem.Allocator,
desktopWindow: sys.DesktopWindow,
color: w.COLORREF,
colorFocused: w.COLORREF,
font: w.HGDIOBJ,
desktopFont: w.HGDIOBJ,
desktopNumberString: [:0]u16,
visible: bool = true,
bounds: w.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

callbacks: *Callbacks,

pub fn create(desktopWindow: sys.DesktopWindow, callbacks: *Callbacks, dpi: u32, allocator: std.mem.Allocator) !*Self {
    const desktopNumberUtf16 = blk: {
        const desktopNumber = if (desktopWindow.desktopNumber) |n|
            try std.fmt.allocPrint(allocator, "{d}", .{n + 1})
        else
            try allocator.dupe(u8, "?");
        defer allocator.free(desktopNumber);
        break :blk try std.unicode.utf8ToUtf16LeAllocZ(allocator, desktopNumber);
    };

    var self = try allocator.create(Self);
    self.* = .{
        .allocator = allocator,
        .desktopWindow = desktopWindow,
        .color = if (desktopWindow.executableName) |en| createColor(en, false) else createColor(desktopWindow.class, false),
        .colorFocused = if (desktopWindow.executableName) |en| createColor(en, true) else createColor(desktopWindow.class, true),
        .desktopNumberString = desktopNumberUtf16,
        .font = undefined,
        .desktopFont = undefined,
        .callbacks = callbacks,
    };

    try self.setFonts(dpi);

    return self;
}

pub fn destroy(self: *Self) void {
    _ = w.DeleteObject(self.font);
    _ = w.DeleteObject(self.desktopFont);
    self.allocator.free(self.desktopNumberString);
    self.allocator.destroy(self);
}

pub fn resetFonts(self: *Self, dpi: u32) !void {
    _ = w.DeleteObject(self.font);
    _ = w.DeleteObject(self.desktopFont);
    try self.setFonts(dpi);
}

fn setFonts(self: *Self, dpi: u32) !void {
    self.font = w.GetStockObject(w.DEFAULT_GUI_FONT);
    self.desktopFont = w.CreateFontW(scale(desktop_no_font_size, dpi), 0, 0, 0, w.FW_BOLD, 0, 0, 0, w.DEFAULT_CHARSET, w.OUT_TT_PRECIS, w.CLIP_DEFAULT_PRECIS, w.DEFAULT_QUALITY, w.DEFAULT_PITCH | w.FF_DONTCARE, sys.toUtf16const("Segoe UI"));
}

fn scale(x: i32, dpi: u32) i32 {
    return w.MulDiv(x, @as(i32, @intCast(dpi)), 96);
}

pub fn paint(self: *Self, hdc: w.HDC, dpi: u32, selected: bool) !void {
    const hbrushBg = w.CreateSolidBrush(0);
    defer _ = w.DeleteObject(hbrushBg);
    var bgRect = self.bounds;
    try wh.mapFailure(w.FillRect(hdc, &bgRect, hbrushBg));

    const colorFg: w.COLORREF = if (selected) self.colorFocused else self.color;
    const hbrushFg = w.CreateSolidBrush(colorFg);
    defer _ = w.DeleteObject(hbrushFg);
    var fgRect: w.RECT = .{
        .left = self.bounds.left + scale(1, dpi),
        .top = self.bounds.top + scale(1, dpi),
        .right = self.bounds.right - scale(1, dpi),
        .bottom = self.bounds.bottom - scale(1, dpi),
    };
    try wh.mapFailure(w.FillRect(hdc, &fgRect, hbrushFg));

    try self.drawDesktopNo(hdc, dpi, selected);
    try self.drawText(hdc, dpi, selected);
    try self.drawIcon(hdc, dpi);
}

pub fn drawDesktopNo(self: *Self, hdc: w.HDC, dpi: u32, selected: bool) !void {
    var rect: w.RECT = .{
        .left = self.bounds.left + scale(5, dpi),
        .top = self.bounds.top,
        .right = self.bounds.right - scale(5, dpi),
        .bottom = self.bounds.bottom - scale(5, dpi),
    };

    if (selected) {
        _ = w.SetTextColor(hdc, 0x00000000);
    } else {
        _ = w.SetTextColor(hdc, 0x00ffffff);
    }
    _ = w.SetBkMode(hdc, w.TRANSPARENT);
    _ = w.SelectObject(hdc, self.desktopFont);

    _ = w.DrawTextW(hdc, self.desktopNumberString, -1, &rect, w.DT_SINGLELINE | w.DT_TOP | w.DT_RIGHT | w.DT_WORD_ELLIPSIS);
}

pub fn drawText(self: *Self, hdc: w.HDC, dpi: u32, selected: bool) !void {
    var rect: w.RECT = .{
        .left = self.bounds.left + scale(5, dpi),
        .top = self.bounds.top,
        .right = self.bounds.right - scale(5, dpi),
        .bottom = self.bounds.bottom - scale(5, dpi),
    };
    if (selected) {
        _ = w.SetTextColor(hdc, 0x00ffffff);
    } else {
        _ = w.SetTextColor(hdc, 0x00000000);
    }
    _ = w.SetBkMode(hdc, w.TRANSPARENT);
    _ = w.SelectObject(hdc, self.font);
    _ = w.DrawTextW(hdc, self.desktopWindow.title, -1, &rect, w.DT_SINGLELINE | w.DT_BOTTOM | w.DT_CENTER | w.DT_WORD_ELLIPSIS);
}

pub fn drawIcon(self: *Self, hdc: w.HDC, dpi: u32) !void {
    const margin_top = scale(20, dpi);
    const margin_left = scale(14, dpi);
    const margin_right = scale(14, dpi);
    const margin_bot = scale(32, dpi);

    const inner_left = self.bounds.left + margin_left;
    const inner_top = self.bounds.top + margin_top;
    const inner_right = self.bounds.right - margin_right;
    const inner_bottom = self.bounds.bottom - margin_bot;

    const inner_w = inner_right - inner_left;
    const inner_h = inner_bottom - inner_top;
    const icon_size = @min(inner_h, inner_w);

    const center_x = inner_left + @divFloor(inner_w, 2);
    const center_y = inner_top + @divFloor(inner_h, 2);

    const icon_x = center_x - @divFloor(icon_size, 2);
    const icon_y = center_y - @divFloor(icon_size, 2);
    _ = w.DrawIconEx(hdc, icon_x, icon_y, self.desktopWindow.icon, icon_size, icon_size, 0, null, w.DI_NORMAL);
}

fn createColor(text: []const u16, focused: bool) w.COLORREF {
    const crc = getCrc16(text, text.len);

    const pre_h: u16 = (((crc >> 8) & 0xFF) + color_offset) % 256;
    const pre_s = ((crc << 0) & 0xFF);
    const h: f32 = @as(f32, @floatFromInt(pre_h)) / 255.0;
    const s: f32 = 0.1 + @as(f32, @floatFromInt(pre_s)) / 512.0;
    const l: f32 = if (focused) 0.4 else 0.6;

    const q = if (l < 0.5) l * (1.0 + s) else l + s - l * s;
    const p = 2.0 * l - q;
    const r = hue2rgb(p, q, h + 1.0 / 3.0);
    const g = hue2rgb(p, q, h);
    const b = hue2rgb(p, q, h - 1.0 / 3.0);

    const ri: w.COLORREF = @intFromFloat(r * 255);
    const bi: w.COLORREF = @intFromFloat(b * 255);
    const gi: w.COLORREF = @intFromFloat(g * 255);

    const color = ri + (gi << 8) + (bi << 16);

    return color;
}

fn getCrc16(a: []const u16, len: usize) u16 {
    const crc16_poly: u16 = 0x8408;

    var data: u16 = undefined;
    var crc: u16 = 0xffff;
    if (len == 0)
        return (~crc);

    var i: usize = 0;
    while (i < len) : (i += 1) {
        var j: usize = 8;
        data = 0xff & a[i];
        while (j > 0) : (j -= 1) {
            if ((crc & 0x0001) ^ (data & 0x0001) != 0) {
                crc = (crc >> 1) ^ crc16_poly;
            } else {
                crc >>= 1;
            }

            data >>= 1;
        }
    }

    crc = ~crc;
    data = crc;
    crc = (crc << 8) | (data >> 8 & 0xff);
    return crc;
}

fn hue2rgb(p: f32, q: f32, ti: f32) f32 {
    var t: f32 = ti;
    if (t < 0.0)
        t += 1.0;
    if (t > 1.0)
        t -= 1.0;
    if (t < 1.0 / 6.0)
        return (p + (q - p) * 6.0 * t);
    if (t < 1.0 / 2.0)
        return q;
    if (t < 2.0 / 3.0)
        return (p + (q - p) * (2.0 / 3.0 - t) * 6.0);
    return p;
}
