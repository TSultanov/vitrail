usingnamespace @import("vitrail.zig");
pub const Window = @import("Window.zig");

const DesktopWindow = @import("SystemInteraction.zig").DesktopWindow;

pub const Callbacks = struct {
    clicked: fn (tile: *Self) anyerror!void,
};

const Self = @This();

const color_offset = 50;
const desktop_no_font_size = 32;

allocator: *std.mem.Allocator,
window: *Window,
event_handlers: Window.EventHandlers,
selected: bool,
desktopWindow: DesktopWindow,
color: w.COLORREF,
colorFocused: w.COLORREF,
font: w.HGDIOBJ,
desktopFont: w.HGDIOBJ,
desktopNumberString: [:0]u16,

callbacks: *Callbacks,

fn onAfterDestroy(event_handlers: *Window.EventHandlers, window: *Window) !void {
    var self = @fieldParentPtr(Self, "event_handlers", event_handlers);
    self.allocator.free(self.desktopNumberString);
    self.allocator.destroy(window);
}

fn onDestroy(event_handlers: *Window.EventHandlers, window: *Window) !void {
    var self = @fieldParentPtr(Self, "event_handlers", event_handlers);
    _ = w.DeleteObject(self.font);
    _ = w.DeleteObject(self.desktopFont);
}

pub fn onClick(event_handlers: *Window.EventHandlers, window: *Window) !void {
    const self = @fieldParentPtr(Self, "event_handlers", event_handlers);
    try self.callbacks.clicked(self);
}

pub fn onPaint(event_handlers: *Window.EventHandlers, window: *Window) !void {
    const self = @fieldParentPtr(Self, "event_handlers", event_handlers);

    var ps: w.PAINTSTRUCT = undefined;
    var hdc = w.BeginPaint(self.window.hwnd, &ps);
    defer _ = w.EndPaint(self.window.hwnd, &ps);
    defer _ = w.ReleaseDC(self.window.hwnd, hdc);

    var hbrushBg = w.CreateSolidBrush(0);
    defer _ = w.DeleteObject(hbrushBg);
    try w.mapFailure(w.FillRect(hdc, &ps.rcPaint, hbrushBg));

    var colorFg: w.COLORREF = if (self.selected) self.colorFocused else self.color;
    var hbrushFg = w.CreateSolidBrush(colorFg);
    defer _ = w.DeleteObject(hbrushFg);
    var rect = try self.window.getClientRect();
    rect.left = window.scaleDpi(1);
    rect.top = window.scaleDpi(1);
    rect.right -= window.scaleDpi(1);
    rect.bottom -= window.scaleDpi(1);
    try w.mapFailure(w.FillRect(hdc, &rect, hbrushFg));

    try self.drawDesktopNo(hdc);
    try self.drawText(hdc);
    try self.drawIcon(hdc);
}

pub fn onDpiChange(event_handlers: *Window.EventHandlers, window: *Window, wParam: w.WPARAM, lParam: w.LPARAM) !void {
    window.dpi = w.GetDpiForWindow(window.hwnd);
    const rect = @intToPtr(*w.RECT, @intCast(usize, lParam));
    try window.setSize(rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top);

    const self = @fieldParentPtr(Self, "event_handlers", event_handlers);
    _ = w.DeleteObject(self.font);
    _ = w.DeleteObject(self.desktopFont);
    try self.setFonts();
}

pub fn onMouseMove(event_handlers: *Window.EventHandlers, window: *Window, keys: u64, x: i16, y: i16) !void {
    const self = @fieldParentPtr(Self, "event_handlers", event_handlers);
    try self.window.focus();
}

fn onSetFocus(event_handlers: *Window.EventHandlers, window: *Window, wParam: w.WPARAM, lParam: w.LPARAM) !void {
    var self = @fieldParentPtr(Self, "event_handlers", event_handlers);
    try self.select();
}

fn onKillFocus(event_handlers: *Window.EventHandlers, window: *Window, wParam: w.WPARAM, lParam: w.LPARAM) !void {
    var self = @fieldParentPtr(Self, "event_handlers", event_handlers);
    try self.unselect();
}

fn select(self: *Self) !void {
    self.selected = true;
    try self.window.redraw();
}

fn unselect(self: *Self) !void {
    self.selected = false;
    try self.window.redraw();
}

fn onKeyDown(event_handlers: *Window.EventHandlers, window: *Window, wParam: w.WPARAM, lParam: w.LPARAM) !void {
    var self = @fieldParentPtr(Self, "event_handlers", event_handlers);

    if(wParam == w.VK_RETURN) {
         // Handle return
        try self.callbacks.clicked(self);
    }
    else
    if(self.window.parent) |p| {
        // Relay event to parent if key is not return
        _ = w.SendMessage(p.hwnd, w.WM_KEYDOWN, wParam, lParam);
    }
}

pub fn create(hInstance: w.HINSTANCE, parent: *Window, desktopWindow: DesktopWindow, callbacks: *Callbacks, allocator: *std.mem.Allocator) !*Self {
    const windowConfig = Window.WindowParameters {
        .title = desktopWindow.title,
        .className = toUtf16const("VitrailTile"),
        .width = 100, .height = 25,
        .style = w.WS_VISIBLE | w.WS_CHILD,
        .parent = parent,
        .register_class = true
    };

    var desktopNumberUtf16 = blk: {
            var desktopNumber = try std.fmt.allocPrint(allocator, "{d}", .{desktopWindow.desktopNumber.? + 1});
            break :blk try std.unicode.utf8ToUtf16LeWithNull(allocator, desktopNumber);
    };

    var self = try allocator.create(Self);
    self.* = .{
        .allocator = allocator,
        .window = undefined,
        .selected = false,
        .desktopWindow = desktopWindow,
        .color = if (desktopWindow.executableName) |en| createColor(en, false) else createColor(desktopWindow.class, false),
        .colorFocused = if (desktopWindow.executableName) |en| createColor(en, true) else createColor(desktopWindow.class, true),
        .desktopNumberString = desktopNumberUtf16,
        .font = undefined,
        .desktopFont = undefined,
        .event_handlers = .{
            .onClick = onClick,
            .onPaint = onPaint,
            .onDpiChange = onDpiChange,
            .onMouseMove = onMouseMove,
            .onSetFocus = onSetFocus,
            .onKillFocus = onKillFocus,
            .onKeyDown = onKeyDown,
            .onDestroy = onDestroy,
            .onAfterDestroy = onAfterDestroy
        },
        .callbacks = callbacks
    };

    var window = try Window.create(windowConfig, &self.event_handlers, hInstance, allocator);
    self.window = window;
    _ = w.SetLayeredWindowAttributes(window.hwnd, 0, 255, w.LWA_ALPHA);

    // _ = w.SetWindowLong(window.hwnd, w.GWL_EXSTYLE, w.WS_EX_LAYERED);
    // _ = w.SetLayeredWindowAttributes(window.hwnd, 0, 255, w.LWA_ALPHA);

    try self.setFonts();

    return self;
}

fn setFonts(self: *Self) !void {
    self.font = w.GetStockObject(w.DEFAULT_GUI_FONT);
    self.desktopFont = w.CreateFontW(self.window.scaleDpi(desktop_no_font_size), 0, 0, 0, w.FW_BOLD, 0, 0, 0, w.DEFAULT_CHARSET, 
                        w.OUT_TT_PRECIS, w.CLIP_DEFAULT_PRECIS, w.DEFAULT_QUALITY, 
                        w.DEFAULT_PITCH | w.FF_DONTCARE, toUtf16const("Segoe UI"));
}

pub fn drawDesktopNo(self: Self, hdc: w.HDC) !void {
    var rect = try self.window.getClientRect();
    rect.left = self.window.scaleDpi(5);
    rect.right -= self.window.scaleDpi(5);
    rect.bottom -= self.window.scaleDpi(5);

    if(self.selected) {
        _ = w.SetTextColor(hdc, 0x00000000);
    } else {
        _ = w.SetTextColor(hdc, 0x00ffffff);
    }
    _ = w.SetBkMode(hdc, w.TRANSPARENT);
    _ = w.SelectObject(hdc, self.desktopFont);

    _ = w.DrawTextW(hdc, self.desktopNumberString, -1, &rect, w.DT_SINGLELINE | w.DT_TOP | w.DT_RIGHT | w.DT_WORD_ELLIPSIS);
}

pub fn drawText(self: Self, hdc: w.HDC) !void {
    var rect = try self.window.getClientRect();
    rect.left = self.window.scaleDpi(5);
    rect.right -= self.window.scaleDpi(5);
    rect.bottom -= self.window.scaleDpi(5);
    if(self.selected) {
        _ = w.SetTextColor(hdc, 0x00ffffff);
    } else {
        _ = w.SetTextColor(hdc, 0x00000000);
    }
    _ = w.SetBkMode(hdc, w.TRANSPARENT);
    _ = w.SelectObject(hdc, self.font);
    _ = w.DrawTextW(hdc, self.desktopWindow.title, -1, &rect, w.DT_SINGLELINE | w.DT_BOTTOM | w.DT_CENTER | w.DT_WORD_ELLIPSIS);
}

pub fn drawIcon(self: Self, hdc: w.HDC) !void {
    var rect = try self.window.getRect();

    const margin_top = self.window.scaleDpi(14);
    const margin_left = self.window.scaleDpi(14);
    const margin_right = self.window.scaleDpi(14);
    const margin_bot = self.window.scaleDpi(26);

    rect.top += margin_top;
    rect.bottom -= margin_bot;
    rect.left += margin_left;
    rect.right -= margin_right;

    const center_x = @divFloor((rect.right - rect.left), 2) + margin_left;
    const center_y = @divFloor((rect.bottom - rect.top), 2) + margin_top;
    const icon_size = std.math.min((rect.bottom - rect.top), (rect.right - rect.left));

    var icon_x = center_x - @divFloor(icon_size, 2);
    var icon_y = center_y - @divFloor(icon_size, 2);
    _ = w.DrawIconEx(hdc, icon_x, icon_y, self.desktopWindow.icon, icon_size, icon_size, 0, null, w.DI_NORMAL);
}

fn createColor(text: []const u16, focused: bool) w.COLORREF {
    var crc = getCrc16(text, text.len);

    var pre_h: u16 = (((crc >> 8) & 0xFF) + color_offset) % 256;
    var pre_s = ((crc << 0) & 0xFF);
    var h: f32 = @intToFloat(f32, pre_h) / 255.0;
    var s: f32 = 0.1 + @intToFloat(f32, pre_s) / 512.0;
    var l: f32 = if (focused) 0.4 else 0.6;

    var q = if (l < 0.5) l * (1.0 + s) else l + s - l * s;
    var p = 2.0 * l - q;
    var r = hue2rgb(p, q, h + 1.0 / 3.0);
    var g = hue2rgb(p, q, h);
    var b = hue2rgb(p, q, h - 1.0 / 3.0);

    var ri: w.COLORREF = @floatToInt(w.COLORREF, r * 255);
    var bi: w.COLORREF = @floatToInt(w.COLORREF, b * 255);
    var gi: w.COLORREF = @floatToInt(w.COLORREF, g * 255);

    var color = ri + (gi << 8) + (bi << 16);

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
        data = 0xff & a[i];
        while (j > 0) : (j -= 1)
        {
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