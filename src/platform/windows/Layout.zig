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

const PointerPosition = struct {
    x: i32,
    y: i32,
};

/// Hooks the Layout invokes back into its parent. `activate` fires on click /
/// Enter; `visibility_changed` fires whenever the set of *visible* tiles
/// shifts (search edit, desktop-window list change) — the parent rebuilds its
/// transparency region from `grid.tiles` in response.
pub const Callbacks = struct {
    activate: *const fn (cbs: *Callbacks, dw: common.DesktopWindow) anyerror!void,
    context_menu: *const fn (
        cbs: *Callbacks,
        stable_id: []const u8,
        can_close: bool,
        screen_x: c_int,
        screen_y: c_int,
    ) anyerror!void,
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

// A live window refresh preserves keyboard navigation until the pointer is
// used again. When pointer input is authoritative, native events can be
// reconciled against GetCursorPos after a blocking menu/refresh; synthetic
// tests retain their explicit logical coordinate instead.
pointer_position: ?PointerPosition = null,
pointer_drives_selection: bool = false,
native_pointer_events: bool = false,

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
    self.useKeyboardSelection();
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
    self.useKeyboardSelection();

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
    const effective_dpi: c_int = if (dpi == 0) 96 else dpi;
    try self.updatePointerSelection(
        w.MulDiv(x, 96, effective_dpi),
        w.MulDiv(y, 96, effective_dpi),
        true,
    );
}

fn onClickHandler(event_handlers: *Window.EventHandlers, _: *Window) !void {
    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    try self.activate();
}

fn onMouseButtonHandler(
    event_handlers: *Window.EventHandlers,
    _: *Window,
    msg: u32,
    _: u32,
    x: i16,
    y: i16,
) !void {
    if (msg != @as(u32, @intCast(w.WM_RBUTTONDOWN))) return;

    const self: *Self = @fieldParentPtr("event_handlers", event_handlers);
    const dpi: c_int = @intCast(self.window.dpi);
    const effective_dpi: c_int = if (dpi == 0) 96 else dpi;
    const logical_x = w.MulDiv(x, 96, effective_dpi);
    const logical_y = w.MulDiv(y, 96, effective_dpi);
    const tile_index = self.grid.tileAt(logical_x, logical_y) orelse return;

    self.rememberPointer(logical_x, logical_y, true);
    // Redraw synchronously so the right-clicked tile is visibly selected
    // before TrackPopupMenuEx starts its nested native event loop.
    if (self.grid.selectAt(logical_x, logical_y)) {
        try self.window.redraw();
    }

    const target = self.grid.tiles.items[tile_index].dw;
    var point = w.POINT{ .x = x, .y = y };
    if (w.ClientToScreen(self.window.hwnd, &point) == 0) return;
    try self.callbacks.context_menu(
        self.callbacks,
        target.stable_id,
        target.can_close,
        point.x,
        point.y,
    );
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
            .onMouseButton = onMouseButtonHandler,
        },
    };

    const window = try Window.create(windowConfig, &self.event_handlers, hInstance, allocator);
    window.docked = true;
    self.window = window;

    try self.ensureFonts();

    return self;
}

pub fn clear(self: *Self) !void {
    self.pointer_position = null;
    self.pointer_drives_selection = false;
    self.native_pointer_events = false;
    self.grid.dropDesktopWindows();
    self.window.redraw() catch |err| {
        // The descriptor borrow is already gone. Hiding must still commit so
        // the presenter can release its owned snapshot safely.
        std.log.warn("Windows grid-clear redraw failed: {s}", .{@errorName(err)});
    };
}

pub fn setDesktopWindows(self: *Self, dws: []const common.DesktopWindow) !void {
    try self.ensureFramebuffer(); // sets grid viewport
    try self.grid.setDesktopWindows(dws);
    // Grid acceptance is the commit point. Native repaint and region work
    // must not turn an accepted borrowed snapshot into an apparent failure.
    self.window.redraw() catch |err| {
        std.log.warn("Windows initial grid redraw failed: {s}", .{@errorName(err)});
    };
}

pub fn refreshDesktopWindows(self: *Self, dws: []const common.DesktopWindow) !void {
    try self.ensureFramebuffer(); // keeps the logical viewport current
    try self.grid.refreshDesktopWindows(dws);
    // Enumeration can briefly block the UI thread and the refreshed tiles may
    // occupy different cells. Re-hit-test the current pointer before drawing
    // the committed snapshot so selection cannot trail the system cursor.
    _ = self.selectAtCurrentPointer();
    // Grid replacement is the commit point: after it succeeds the view
    // borrows `dws`. Do not report a later best-effort native repaint/region
    // failure as a rejected snapshot, because the presenter would correctly
    // destroy a rejected list and leave the committed Grid borrowing it.
    self.window.redraw() catch |err| {
        std.log.warn("Windows live-refresh redraw failed: {s}", .{@errorName(err)});
    };
    self.callbacks.visibility_changed(self.callbacks) catch |err| {
        std.log.warn("Windows live-refresh region update failed: {s}", .{@errorName(err)});
    };
}

/// Test-only input takes a logical coordinate directly so reconciliation does
/// not replace it with the test host's unrelated physical cursor position.
pub fn synthesizeMouseMove(self: *Self, x: i32, y: i32) !void {
    try self.updatePointerSelection(x, y, false);
}

/// Test-only equivalent of movement consumed by a native popup: remember the
/// system pointer's new logical position without dispatching a grid hover yet.
pub fn synthesizeDeferredPointerPosition(self: *Self, x: i32, y: i32) void {
    self.rememberPointer(x, y, false);
}

/// Keep keyboard navigation authoritative through unrelated live refreshes.
/// Selection returns to pointer authority on the next pointer event.
pub fn useKeyboardSelection(self: *Self) void {
    self.pointer_drives_selection = false;
}

fn rememberPointer(self: *Self, x: i32, y: i32, native: bool) void {
    self.pointer_position = .{ .x = x, .y = y };
    self.pointer_drives_selection = true;
    self.native_pointer_events = native;
}

fn updatePointerSelection(self: *Self, x: i32, y: i32, native: bool) !void {
    self.rememberPointer(x, y, native);
    if (self.grid.selectAt(x, y)) {
        try self.window.redraw();
    }
}

/// Re-select the tile under the latest pointer. Native input samples the live
/// cursor instead of trusting coordinates queued before TrackPopupMenuEx or a
/// potentially slow enumeration; synthetic input keeps its explicit point.
pub fn selectAtCurrentPointer(self: *Self) bool {
    if (!self.pointer_drives_selection) return false;

    var point = self.pointer_position orelse return false;
    if (self.native_pointer_events) {
        var native_point: w.POINT = undefined;
        if (w.GetCursorPos(&native_point) == 0 or
            w.ScreenToClient(self.window.hwnd, &native_point) == 0) return false;

        const dpi: c_int = @intCast(self.window.dpi);
        const effective_dpi: c_int = if (dpi == 0) 96 else dpi;
        point = .{
            .x = w.MulDiv(native_point.x, 96, effective_dpi),
            .y = w.MulDiv(native_point.y, 96, effective_dpi),
        };
        self.pointer_position = point;
    }

    return self.grid.selectAt(point.x, point.y);
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
