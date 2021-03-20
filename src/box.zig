const w = @import("windows.zig");
const std = @import("std");
const Window = @import("window.zig").Window;
const WindowParameters = @import("window.zig").WindowParameters;
const WindowEventHandlers = @import("window.zig").WindowEventHandlers;
const si = @import("system_interaction.zig");
const Allocator = std.mem.Allocator;

var classRegistered: bool = false;

var boxes = std.hash_map.AutoHashMap(w.HWND, *Box).init(std.heap.c_allocator);

const color_offset = 100;

pub const Box = struct {
    window: *Window,
    focused: bool = false,
    title: []const u16,
    color: w.COLORREF,
    colorFocused: w.COLORREF,
    font: w.HGDIOBJ,
    icon: w.HICON,
    hwnd: w.HWND,

    const Self = @This();

    pub fn focus(self: *Box) void {
        self.focused = true;
        self.window.redraw();
    }

    pub fn unfocus(self: *Box) void {
        self.focused = false;
        self.window.redraw();
    }

    pub fn switchToWindow(self: Box) void {
        _ = w.SwitchToThisWindow(self.hwnd, 1);
    }

    pub fn onClick(window: Window) !void {
        //Hacky way to switch to window and close ourselves, consider implementing it properly.
        const self = @fieldParentPtr(Self, "window", window);
        self.switchToWindow();
        //_ = w.PostMessageW(hwnd, w.WM_KEYDOWN, w.VK_ESCAPE, 0);
    }

    pub fn onPaint(window: Window) !void {
        const self = @fieldParentPtr(Self, "window", window);
        var ps: w.PAINTSTRUCT = undefined;
        var hdc = w.BeginPaint(window.hwnd, &ps);

        var hbrushBg = w.CreateSolidBrush(0);
        defer _ = w.DeleteObject(hbrushBg);
        _ = w.FillRect(hdc, &ps.rcPaint, hbrushBg);

        var colorFg: w.COLORREF = undefined;

        if (self.focused) {
            colorFg = self.colorFocused;
        } else {
            colorFg = self.color;
        }
        var hbrushFg = w.CreateSolidBrush(colorFg);
        defer _ = w.DeleteObject(hbrushFg);
        var rect = self.window.getClientRect();
        rect.left = 1;
        rect.top = 1;
        rect.right -= 1;
        rect.bottom -= 1;
        _ = w.FillRect(hdc, &rect, hbrushFg);

        self.drawText(hdc);
        self.drawIcon(hdc);

        _ = w.EndPaint(window.hwnd, &ps);
        _ = w.ReleaseDC(window.hwnd, hdc);
    }

    pub fn create(hInstance: w.HINSTANCE, title: []const u16, class: []const u16, icon: w.HICON, hwnd: w.HWND, allocator: *Allocator) !*Box {
        comptime var className: w.LPCWSTR = try si.toUtf16("MosaicBox");

        var windowTitle: w.LPCWSTR = try si.toUtf16("Box");

        var windowParameters = WindowParameters {
            .exStyle = w.WS_EX_TOPMOST | w.WS_EX_TOOLWINDOW,
            .className = className,
            .title = windowTitle,
            .style = w.WS_BORDER,
            .x = 0,
            .y = 0,
            .width = 200,
            .height = 200,
        };

        var eventHandlers = WindowEventHandlers {
            .onClick = onClick,
            .onPaint = onPaint
        };

        var window = try Window.create(windowParameters, eventHandlers, hInstance, allocator);

        _ = w.SetWindowLong(window.hwnd, w.GWL_STYLE, 0);
        var font = w.GetStockObject(w.DEFAULT_GUI_FONT);
        _ = w.SendMessage(window.hwnd, w.WM_SETFONT, @ptrToInt(font), 1);

        var l: *Box = try allocator.create(Box);

        var classUtf8: [512]u8 = undefined;
        _ = try std.unicode.utf16leToUtf8(classUtf8[0..], class);

        l.* = Box{
            .window = window,
            .title = title,
            .color = createColor(classUtf8[0..], false),
            .colorFocused = createColor(classUtf8[0..], true),
            .font = font,
            .icon = icon,
            .hwnd = hwnd,
        };
        _ = try boxes.put(window.hwnd, l);
        return l;
    }

    pub fn drawText(self: Box, hdc: w.HDC) void {
        var rect = self.window.getClientRect();
        rect.left = 24;
        rect.right -= 2;
        if(self.focused) {
            _ = w.SetTextColor(hdc, 0x00ffffff);
        } else {
            _ = w.SetTextColor(hdc, 0x00000000);
        }
        _ = w.SetBkMode(hdc, w.TRANSPARENT);
        _ = w.SelectObject(hdc, self.font);
        _ = w.DrawTextW(hdc, &self.title[0], -1, &rect, w.DT_SINGLELINE | w.DT_VCENTER | w.DT_LEFT);
    }

    pub fn drawIcon(self: Box, hdc: w.HDC) void {
        var rect = self.window.getRect();
        var height = rect.bottom - rect.top;
        var padding = @divFloor(height - 16, 2);
        _ = w.DrawIconEx(hdc, 4, padding, self.icon, 16, 16, 0, null, w.DI_NORMAL);
    }

    fn createColor(text: []const u8, focused: bool) w.COLORREF {
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

    fn getCrc16(a: []const u8, len: usize) u16 {
        var crc16_poly: u16 = 0x8408;

        var data: u16 = undefined;
        var crc: u16 = 0xffff;
        if (len == 0)
            return (~crc);

        var i: usize = 0;
        while (i < len) : (i += 1) {
            var j: usize = 8;
            while (j > 0) : (j -= 1)
            //for (int i =0, data= (guint)0xff & a[i];  i < 8;  i++, data >>= 1)
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

    pub fn destroy(self: *Box) void {
        self.window.destroy();
        _ = boxes.remove(self.hwnd);
        _ = w.DestroyIcon(self.icon);
    }
};