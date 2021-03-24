usingnamespace @import("vitrail.zig");
pub const Window = @import("Window.zig");

const DesktopWindow = @import("SystemInteraction.zig").DesktopWindow;

const Self = @This();

const color_offset = 100;

window: *Window,
event_handlers: Window.EventHandlers,
tile_event_handlers: *EventHandlers,
selected: bool,
desktopWindow: DesktopWindow,
color: w.COLORREF,
colorFocused: w.COLORREF,
font: w.HGDIOBJ,

pub const EventHandlers = struct {
    onClick: fn (self: *EventHandlers, tile: *Self) anyerror!void,
};

pub fn onClick(event_handlers: *Window.EventHandlers, window: *Window) !void {
    const self = @fieldParentPtr(Self, "event_handlers", event_handlers);
    try self.tile_event_handlers.onClick(self.tile_event_handlers, self);
}

pub fn onPaint(event_handlers: *Window.EventHandlers, window: *Window) !void {
    const self = @fieldParentPtr(Self, "event_handlers", event_handlers);

    var ps: w.PAINTSTRUCT = undefined;
    var hdc = w.BeginPaint(self.window.hwnd, &ps);
    defer _ = w.EndPaint(self.window.hwnd, &ps);
    defer _ = w.ReleaseDC(self.window.hwnd, hdc);

    var colorFg: w.COLORREF = undefined;

    if (self.selected) {
        colorFg = self.colorFocused;
    } else {
        colorFg = self.color;
    }
    var hbrushFg = w.CreateSolidBrush(colorFg);
    defer _ = w.DeleteObject(hbrushFg);
    var rect = try self.window.getClientRect();
    // rect.left = 1;
    // rect.top = 1;
    // rect.right -= 1;
    // rect.bottom -= 1;
    _ = w.FillRect(hdc, &rect, hbrushFg);

    try self.drawText(hdc);
    try self.drawIcon(hdc);
}

pub fn create(hInstance: w.HINSTANCE, parent: *Window, desktopWindow: DesktopWindow, eventHandlers: *EventHandlers, allocator: *std.mem.Allocator) !*Self {
    const windowConfig = Window.WindowParameters {
        .title = desktopWindow.title,
        .className = toUtf16const("VitrailTile"),
        .width = 100, .height = 25,
        .style = w.WS_TABSTOP | w.WS_VISIBLE | w.WS_CHILD,
        .parent = parent,
        .register_class = true
    };

    var self = try allocator.create(Self);
    self.* = .{
        .window = undefined,
        .tile_event_handlers = eventHandlers,
        .selected = false,
        .desktopWindow = desktopWindow,
        .color = createColor(desktopWindow.class, false),
        .colorFocused = createColor(desktopWindow.class, true),
        .font = w.GetStockObject(w.DEFAULT_GUI_FONT),
        .event_handlers = .{
            .onClick = onClick,
            .onPaint = onPaint
        },
    };

    var window = try Window.create(windowConfig, &self.event_handlers, hInstance, allocator);
    self.window = window;

    return self;
}

pub fn drawText(self: Self, hdc: w.HDC) !void {
    var rect = try self.window.getClientRect();
    rect.left = 24;
    rect.right -= 2;
    if(self.selected) {
        _ = w.SetTextColor(hdc, 0x00ffffff);
    } else {
        _ = w.SetTextColor(hdc, 0x00000000);
    }
    _ = w.SetBkMode(hdc, w.TRANSPARENT);
    _ = w.SelectObject(hdc, self.font);
    _ = w.DrawTextW(hdc, self.desktopWindow.title, -1, &rect, w.DT_SINGLELINE | w.DT_VCENTER | w.DT_LEFT);
}

pub fn drawIcon(self: Self, hdc: w.HDC) !void {
    var rect = try self.window.getRect();
    var height = rect.bottom - rect.top;
    var padding = @divFloor(height - 16, 2);
    //_ = w.DrawIconEx(hdc, 4, padding, self.desktopWindow.icon, 16, 16, 0, null, w.DI_NORMAL);
}

fn createColor(text: []const u16, focused: bool) w.COLORREF {
    var crc = getCrc16(text, text.len);

    var pre_h: u16 = (((crc >> 8) & 0xFF) + color_offset) % 256;
    var pre_s = ((crc << 0) & 0xFF);
    var h: f32 = @intToFloat(f32, pre_h) / 255.0;
    var s: f32 = 0.1 + @intToFloat(f32, pre_s) / 512.0;
    var l: f32 = if (focused) 0.3 else 0.6;

    var q = if (l < 0.5) l * (1.0 + s) else l + s - l * s;
    var p = 2.0 * l - q;
    var r = hue2rgb(p, q, h + 1.0 / 3.0);
    var g = hue2rgb(p, q, h);
    var b = hue2rgb(p, q, h - 1.0 / 3.0);

    var ri: w.COLORREF = @floatToInt(w.COLORREF, r * 255);
    var bi: w.COLORREF = @floatToInt(w.COLORREF, b * 255);
    var gi: w.COLORREF = @floatToInt(w.COLORREF, g * 255);

    var color = ri + (bi << 8) + (gi << 16);
    return color;
}

fn getCrc16(a: []const u16, len: usize) u16 {
    var crc16_poly: u16 = 0x8408;

    var data: u16 = undefined;
    var crc: u16 = 0xffff;
    if (len == 0)
        return (~crc);

    var i: usize = 0;
    while (i < len) : (i += 1) {
        var j: usize = 8;
        while (j > 0) : (j -= 1)
        {
            data = 0xff & a[j];
            if ((crc & 0x0001) ^ (data & 0x0001) != 0) {
                crc = (crc >> 1) ^ crc16_poly;
            } else {
                crc >>= 1;
            }
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