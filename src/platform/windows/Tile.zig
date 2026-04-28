const std = @import("std");
const wh = @import("windows.zig");
const w = wh.c;
const common = @import("../../common/DesktopWindow.zig");
const icon_rgba_mod = @import("icon_rgba.zig");
const ColorHash = @import("../../common/ColorHash.zig");

pub const Callbacks = struct {
    clicked: *const fn (tile: *Self) anyerror!void,
};

const Self = @This();

const desktop_no_font_size = 32;

allocator: std.mem.Allocator,
desktopWindow: common.DesktopWindow,
hicon: ?w.HICON,
color: w.COLORREF,
colorFocused: w.COLORREF,
font: w.HGDIOBJ,
desktopFont: w.HGDIOBJ,
desktopNumberString: [:0]u16,
visible: bool = true,
bounds: w.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

callbacks: *Callbacks,

pub fn create(desktopWindow: common.DesktopWindow, callbacks: *Callbacks, dpi: u32, allocator: std.mem.Allocator) !*Self {
    const desktopNumberUtf16 = blk: {
        const desktopNumber = if (desktopWindow.desktopNumber) |n|
            try std.fmt.allocPrint(allocator, "{d}", .{n + 1})
        else
            try allocator.dupe(u8, "?");
        defer allocator.free(desktopNumber);
        break :blk try std.unicode.utf8ToUtf16LeAllocZ(allocator, desktopNumber);
    };

    const hicon = if (desktopWindow.icon) |rgba| icon_rgba_mod.rgbaToHIcon(rgba, allocator) else null;

    var self = try allocator.create(Self);
    self.* = .{
        .allocator = allocator,
        .desktopWindow = desktopWindow,
        .hicon = hicon,
        .color = @intCast(ColorHash.createColor(desktopWindow.app_id, false)),
        .colorFocused = @intCast(ColorHash.createColor(desktopWindow.app_id, true)),
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
    if (self.hicon) |ic| _ = w.DestroyIcon(ic);
    self.allocator.destroy(self);
}

pub fn resetFonts(self: *Self, dpi: u32) !void {
    _ = w.DeleteObject(self.font);
    _ = w.DeleteObject(self.desktopFont);
    try self.setFonts(dpi);
}

fn setFonts(self: *Self, dpi: u32) !void {
    const segoe_ui = std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI");
    self.font = w.GetStockObject(w.DEFAULT_GUI_FONT);
    self.desktopFont = w.CreateFontW(scale(desktop_no_font_size, dpi), 0, 0, 0, w.FW_BOLD, 0, 0, 0, w.DEFAULT_CHARSET, w.OUT_TT_PRECIS, w.CLIP_DEFAULT_PRECIS, w.DEFAULT_QUALITY, w.DEFAULT_PITCH | w.FF_DONTCARE, segoe_ui);
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
    var title_buf: [512]u16 = undefined;
    const title_utf16_len = std.unicode.utf8ToUtf16Le(&title_buf, self.desktopWindow.title) catch 0;

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
    _ = w.DrawTextW(hdc, @ptrCast(&title_buf), @intCast(title_utf16_len), &rect, w.DT_SINGLELINE | w.DT_BOTTOM | w.DT_CENTER | w.DT_WORD_ELLIPSIS);
}

pub fn drawIcon(self: *Self, hdc: w.HDC, dpi: u32) !void {
    const hicon = self.hicon orelse return;

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
    _ = w.DrawIconEx(hdc, icon_x, icon_y, hicon, icon_size, icon_size, 0, null, w.DI_NORMAL);
}
