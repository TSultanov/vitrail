const std = @import("std");
const wh = @import("windows.zig");
const w = wh.c;
const common = @import("../../common/DesktopWindow.zig");
const Grid = @import("../../common/Grid.zig");
const Renderer = @import("../../common/Renderer.zig");
const text = @import("text.zig");
const sys = @import("SystemInteraction.zig");
pub const Window = @import("Window.zig");

const Self = @This();

const LOGICAL_FONT_TILE: u32 = 12;
const LOGICAL_FONT_SEARCH: u32 = 12;
const LOGICAL_FONT_DESKTOP: u32 = 32;

/// Hooks the Layout invokes back into its parent. `activate` fires on click /
/// Enter; `visibility_changed` fires whenever the set of *visible* tiles
/// shifts (search edit, desktop-window list change) — the parent rebuilds its
/// transparency region from `grid.tiles` in response.
pub const Callbacks = struct {
    activate: *const fn (cbs: *Callbacks, dw: common.DesktopWindow) anyerror!void,
    visibility_changed: *const fn (cbs: *Callbacks) anyerror!void,
};

window: *Window,
allocator: std.mem.Allocator,
event_handlers: Window.EventHandlers,
callbacks: *Callbacks,

grid: Grid,

// Framebuffer-backed top-down 32bpp DIB section. Zig writes pixels here via
// the Renderer; GDI BitBlts the same memory to the window on WM_PAINT.
fb_pixels: []u32 = &.{},
fb_w: u32 = 0,
fb_h: u32 = 0,
dib_bitmap: ?w.HBITMAP = null,
dib_dc: ?w.HDC = null,
dib_old_bmp: ?w.HGDIOBJ = null,

// Glyph caches; recreated when DPI changes so font sizes track the monitor.
tile_text: text.Renderer = undefined,
search_text: text.Renderer = undefined,
desktop_text: text.Renderer = undefined,
fonts_dpi: u32 = 0,

// Carries a UTF-16 high surrogate from one WM_CHAR to the matching low
// surrogate in the next message (Win32 splits non-BMP input across two
// WM_CHARs).
pending_high_surrogate: ?u16 = null,

fn onResizeHandler(event_handlers: *Window.EventHandlers, window: *Window) !void {
    if (window.docked) try window.dock();
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

fn onKeyDownHandler(event_handlers: *Window.EventHandlers, _: *Window, wParam: w.WPARAM, lParam: w.LPARAM) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    if (wParam == w.VK_TAB) {
        const shift_down = (w.GetAsyncKeyState(w.VK_SHIFT) >> 15) != 0;
        self.grid.selectNext(shift_down);
        try self.window.redraw();
    } else if (wParam == w.VK_RIGHT) {
        self.grid.selectDir(1, 0);
        try self.window.redraw();
    } else if (wParam == w.VK_LEFT) {
        self.grid.selectDir(-1, 0);
        try self.window.redraw();
    } else if (wParam == w.VK_UP) {
        self.grid.selectDir(0, -1);
        try self.window.redraw();
    } else if (wParam == w.VK_DOWN) {
        self.grid.selectDir(0, 1);
        try self.window.redraw();
    } else if (wParam == w.VK_RETURN) {
        try self.activate();
    } else if (wParam == w.VK_BACK) {
        // GetKeyState returns SHORT; high bit (0x8000) means "down".
        const ctrl_down = w.GetKeyState(w.VK_CONTROL) < 0;
        if (ctrl_down) {
            try self.grid.popSearchWord();
        } else {
            try self.grid.popSearchCodepoint();
        }
        try self.window.redraw();
        try self.callbacks.visibility_changed(self.callbacks);
    } else if (self.window.parent) |p| {
        _ = w.SendMessageW(p.hwnd, w.WM_KEYDOWN, wParam, lParam);
    }
}

fn onCharHandler(event_handlers: *Window.EventHandlers, _: *Window, wParam: w.WPARAM, _: w.LPARAM) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);

    // Skip control characters — VK_BACK / VK_RETURN / VK_TAB / VK_ESCAPE are
    // already handled (or forwarded) from onKeyDownHandler. 0x7F (DEL) is
    // what Ctrl+Backspace decodes to via TranslateMessage; ignore it here so
    // it isn't appended as a literal.
    const cu: u16 = @truncate(wParam);
    if (cu < 0x20 or cu == 0x7F) {
        self.pending_high_surrogate = null;
        return;
    }

    var utf16_buf: [2]u16 = undefined;
    var utf16_len: usize = 0;
    if (self.pending_high_surrogate) |hi| {
        self.pending_high_surrogate = null;
        if (cu >= 0xDC00 and cu <= 0xDFFF) {
            utf16_buf[0] = hi;
            utf16_buf[1] = cu;
            utf16_len = 2;
        } else {
            // Stray non-low after a high surrogate; drop the high and fall
            // through with cu treated as a fresh code unit below.
        }
    }
    if (utf16_len == 0) {
        if (cu >= 0xD800 and cu <= 0xDBFF) {
            self.pending_high_surrogate = cu;
            return;
        }
        if (cu >= 0xDC00 and cu <= 0xDFFF) return; // unpaired low
        utf16_buf[0] = cu;
        utf16_len = 1;
    }

    // Case-fold via the system-wide Unicode lowercase table to mirror the
    // pre-refactor EDIT-control behavior (CharLowerBuffW), so the existing
    // already-lowercased title/app_id strings in DesktopWindow continue to
    // match input that included uppercase characters.
    _ = w.CharLowerBuffW(&utf16_buf, @intCast(utf16_len));

    var utf8_buf: [8]u8 = undefined;
    const utf8_len = std.unicode.utf16LeToUtf8(&utf8_buf, utf16_buf[0..utf16_len]) catch return;

    try self.grid.appendSearch(utf8_buf[0..utf8_len]);
    try self.window.redraw();
    try self.callbacks.visibility_changed(self.callbacks);
}

fn onAfterDestroyHandler(event_handlers: *Window.EventHandlers, window: *Window) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    self.releaseFonts();
    self.releaseFramebuffer();
    self.grid.deinit();
    self.allocator.destroy(window);
}

fn onMouseMoveHandler(event_handlers: *Window.EventHandlers, _: *Window, _: u64, x: i16, y: i16) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    const dpi: c_int = @intCast(self.window.dpi);
    const lx = w.MulDiv(x, 96, dpi);
    const ly = w.MulDiv(y, 96, dpi);
    if (self.grid.selectAt(lx, ly)) {
        try self.window.redraw();
    }
}

fn onClickHandler(event_handlers: *Window.EventHandlers, _: *Window) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    try self.activate();
}

pub fn create(hInstance: w.HINSTANCE, parent: *Window, callbacks: *Callbacks, allocator: std.mem.Allocator) !*Self {
    const windowConfig = Window.WindowParameters{
        .title = sys.toUtf16const("SpiralLayout"),
        .className = sys.toUtf16const("SpiralLayout"),
        .style = w.WS_VISIBLE | w.WS_CHILD | w.WS_CLIPSIBLINGS,
        .parent = parent,
        .register_class = true,
    };
    var self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .window = undefined,
        .allocator = allocator,
        .grid = Grid.init(allocator),
        .callbacks = callbacks,
        .event_handlers = .{
            .onResize = onResizeHandler,
            .onPaint = onPaintHandler,
            .onKeyDown = onKeyDownHandler,
            .onChar = onCharHandler,
            .onAfterDestroy = onAfterDestroyHandler,
            .onMouseMove = onMouseMoveHandler,
            .onClick = onClickHandler,
        },
    };

    const window = try Window.create(windowConfig, &self.event_handlers, hInstance, allocator);
    window.docked = true;
    self.window = window;

    try self.ensureFonts();

    return self;
}

pub fn clear(self: *Self) !void {
    self.grid.dropDesktopWindows();
    try self.window.redraw();
}

pub fn setDesktopWindows(self: *Self, dws: []const common.DesktopWindow) !void {
    try self.ensureFramebuffer(); // sets grid viewport
    try self.grid.setDesktopWindows(dws);
    try self.window.redraw();
    try self.callbacks.visibility_changed(self.callbacks);
}

pub fn activate(self: *Self) !void {
    const dw = self.grid.selectedWindow() orelse return;
    try self.callbacks.activate(self.callbacks, dw);
}

pub fn onDpiChanged(self: *Self) !void {
    // Force the framebuffer to be reallocated at the next paint, and rebuild
    // the glyph caches at the new pixel size.
    self.releaseFramebuffer();
    try self.ensureFonts();
    try self.window.redraw();
}

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
        bmi.bmiHeader.biCompression = 0; // BI_RGB

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

    // Keep the grid's logical viewport in sync with the framebuffer; spiral
    // placement + visibility are functions of logical dimensions.
    const dpi: c_int = @intCast(self.window.dpi);
    const lw = w.MulDiv(@as(c_int, @intCast(phys_w)), 96, dpi);
    const lh = w.MulDiv(@as(c_int, @intCast(phys_h)), 96, dpi);
    self.grid.setViewport(lw, lh);
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
    self.tile_text = try text.Renderer.create(self.allocator, scaledFont(LOGICAL_FONT_TILE, dpi), .regular);
    errdefer self.tile_text.destroy();
    self.search_text = try text.Renderer.create(self.allocator, scaledFont(LOGICAL_FONT_SEARCH, dpi), .regular);
    errdefer self.search_text.destroy();
    self.desktop_text = try text.Renderer.create(self.allocator, scaledFont(LOGICAL_FONT_DESKTOP, dpi), .bold);
    self.fonts_dpi = dpi;
}

fn releaseFonts(self: *Self) void {
    if (self.fonts_dpi == 0) return;
    self.tile_text.destroy();
    self.search_text.destroy();
    self.desktop_text.destroy();
    self.fonts_dpi = 0;
}

fn renderFrame(self: *Self) void {
    const dpi: u32 = @intCast(self.window.dpi);
    const scale_q120: u32 = (dpi * 120) / 96;
    Renderer.render(
        self.fb_pixels,
        self.fb_w,
        self.fb_h,
        scale_q120,
        &self.grid,
        &self.tile_text,
        &self.search_text,
        &self.desktop_text,
        .{},
    );
}

fn scaledFont(logical: u32, dpi: u32) u32 {
    return (logical * dpi + 48) / 96;
}
