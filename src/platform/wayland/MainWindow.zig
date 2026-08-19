const std = @import("std");
const common = @import("../../common/DesktopWindow.zig");
const wc = @import("wayland_c.zig");
const c = wc.c;

const LayerSurface = @import("LayerSurface.zig");
const ShmPool = @import("ShmPool.zig");
const Keyboard = @import("Keyboard.zig");
const Mouse = @import("Mouse.zig");
const Cursor = @import("Cursor.zig");
const Grid = @import("../../common/Grid.zig");
const Renderer = @import("../../common/Renderer.zig");
const text = @import("text.zig");
const input = @import("../../common/InputAction.zig");

const Self = @This();

pub const PlatformArgs = struct {};

pub const Callbacks = struct {
    activateWindow: *const fn (*Self, common.DesktopWindow) anyerror!void,
    closeWindow: *const fn (*Self, stable_id: []const u8) anyerror!void,
    refreshWindows: *const fn (*Self) anyerror!void,
    hide: *const fn (*Self) anyerror!void,
    openSettings: *const fn (*Self) anyerror!void,
};

const Globals = struct {
    compositor: ?*c.wl_compositor = null,
    shm: ?*c.wl_shm = null,
    layer_shell: ?*c.zwlr_layer_shell_v1 = null,
    seat: ?*c.wl_seat = null,
    fractional_scale_mgr: ?*c.wp_fractional_scale_manager_v1 = null,
    viewporter: ?*c.wp_viewporter = null,
};

// Sized to roughly match Win32 DEFAULT_GUI_FONT (Tahoma ~9pt → ~12px) and the
// Segoe UI Bold 32pt-scaled badge used for the desktop number. Logical units —
// the actual FreeType pixel size is these values × surface scale.
const LOGICAL_FONT_TILE: u32 = 12;
const LOGICAL_FONT_SEARCH: u32 = 12;
const LOGICAL_FONT_DESKTOP: u32 = 32;
const REFRESH_DEBOUNCE_MS: i64 = 100;
const MENU_W: i32 = 120;
const MENU_H: i32 = 28;
const MENU_PAD: i32 = 8;
const MENU_LABEL = "Close window";

const ContextMenu = struct {
    stable_id: []u8,
    rect: Grid.Rect,
    enabled: bool,
};

const SelectionAuthority = enum {
    keyboard,
    pointer,
};

const PointerPoint = struct {
    x: i32,
    y: i32,
};

allocator: std.mem.Allocator,
callbacks: *Callbacks,

display: *c.wl_display,
globals: Globals,
registry_listener: c.wl_registry_listener,

layer: LayerSurface,
shm_pool: ShmPool,
keyboard: Keyboard,
mouse: Mouse,
cursor: Cursor,
seat_listener: c.wl_seat_listener,
grid: Grid,
tile_text: text.Renderer,
search_text: text.Renderer,
desktop_text: text.Renderer,

closed: bool,
running: bool,
window_event_fd: ?std.posix.fd_t,
refresh_due_ms: ?i64,
context_menu: ?ContextMenu,
pointer_x: i32,
pointer_y: i32,
pointer_inside: bool,
selection_authority: SelectionAuthority,
repaint_pending: bool,

pub fn create(_: PlatformArgs, callbacks: *Callbacks, allocator: std.mem.Allocator) !*Self {
    const display = c.wl_display_connect(null) orelse return error.NoWaylandDisplay;
    errdefer _ = c.wl_display_disconnect(display);

    var self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .callbacks = callbacks,
        .display = display,
        .globals = .{},
        .registry_listener = .{ .global = onRegistryGlobal, .global_remove = onRegistryRemove },
        .layer = undefined,
        .shm_pool = undefined,
        .keyboard = undefined,
        .mouse = undefined,
        .cursor = undefined,
        .seat_listener = .{ .capabilities = onSeatCaps, .name = onSeatName },
        .grid = Grid.init(allocator),
        .tile_text = undefined,
        .search_text = undefined,
        .desktop_text = undefined,
        .closed = false,
        .running = true,
        .window_event_fd = null,
        .refresh_due_ms = null,
        .context_menu = null,
        .pointer_x = 0,
        .pointer_y = 0,
        .pointer_inside = false,
        .selection_authority = .keyboard,
        .repaint_pending = false,
    };

    // Init input action sinks BEFORE the registry roundtrip — onRegistryGlobal
    // attaches the seat listener as soon as it binds the seat, and the
    // capabilities event arrives in this same roundtrip.
    try self.keyboard.init(.{ .on_action = onKeyboardAction, .ctx = self });
    self.mouse.init(.{
        .on_action = onMouseAction,
        .on_presence = onPointerPresence,
        .ctx = self,
    });

    const registry = c.wl_display_get_registry(display) orelse return error.RegistryFailed;
    _ = c.wl_registry_add_listener(registry, &self.registry_listener, self);
    _ = c.wl_display_roundtrip(display);

    if (self.globals.compositor == null or self.globals.shm == null or self.globals.layer_shell == null) {
        return error.MissingWaylandGlobals;
    }

    try self.layer.init(
        self.globals.compositor.?,
        self.globals.layer_shell.?,
        self.globals.fractional_scale_mgr,
        self.globals.viewporter,
        &self.closed,
    );

    // One roundtrip to get the configure (logical w/h). preferred_scale is
    // typically delivered alongside or shortly after; we re-check below.
    _ = c.wl_display_roundtrip(display);
    if (!self.layer.configured) return error.LayerSurfaceNotConfigured;

    // Second roundtrip lets preferred_scale settle if it didn't arrive yet.
    _ = c.wl_display_roundtrip(display);

    const phys = self.layer.physicalSize();
    try self.shm_pool.init(self.globals.shm.?, phys.w, phys.h);
    self.layer.applyViewport();
    self.layer.size_dirty = false;

    try self.cursor.init(self.globals.compositor.?, self.globals.shm.?);
    self.mouse.setCursor(&self.cursor);

    // Now that input action sinks are real (init() was called earlier, before
    // the registry roundtrip), drive a roundtrip so any seat-capabilities
    // event delivered to onSeatCaps wires the keyboard/pointer.
    _ = c.wl_display_roundtrip(display);

    self.grid.setViewport(@intCast(self.layer.width), @intCast(self.layer.height));

    self.tile_text = try text.Renderer.create(allocator, scaledFont(LOGICAL_FONT_TILE, self.layer.scale_q120), .regular);
    errdefer self.tile_text.destroy();
    self.search_text = try text.Renderer.create(allocator, scaledFont(LOGICAL_FONT_SEARCH, self.layer.scale_q120), .regular);
    errdefer self.search_text.destroy();
    self.desktop_text = try text.Renderer.create(allocator, scaledFont(LOGICAL_FONT_DESKTOP, self.layer.scale_q120), .bold);
    errdefer self.desktop_text.destroy();

    return self;
}

fn scaledFont(logical: u32, scale_q120: u32) u32 {
    return (logical * scale_q120 + 60) / 120;
}

pub fn deinit(self: *Self) void {
    self.dismissContextMenu();
    self.desktop_text.destroy();
    self.search_text.destroy();
    self.tile_text.destroy();
    self.grid.deinit();
    self.cursor.deinit();
    self.mouse.deinit();
    self.keyboard.deinit();
    self.shm_pool.deinit();
    self.layer.deinit();
    _ = c.wl_display_disconnect(self.display);
    self.allocator.destroy(self);
}

// ─── Platform contract ────────────────────────────────────────────────────────

pub fn show(self: *Self) !void {
    self.grid.clearCenter();
    try self.repaint();
    _ = c.wl_display_flush(self.display);
}

/// Wayland is launch-on-demand with no resident pointer query here, so cursor-
/// centering falls back to the centered path. Present for the shared presenter.
pub fn showAtCursor(self: *Self) !void {
    return self.show();
}

pub fn activate(_: *Self) void {}

pub fn requestQuit(self: *Self) void {
    self.running = false;
}

pub fn setDesktopWindows(self: *Self, dws: []const common.DesktopWindow) !void {
    try self.grid.setDesktopWindows(dws);
    _ = self.rehitPointerSelection();
    self.repaint() catch |err| {
        // The borrowed snapshot is committed at this point; returning an error
        // would make the presenter free it while Grid still references it.
        std.log.err("Wayland initial grid repaint failed: {t}", .{err});
    };
    _ = c.wl_display_flush(self.display);
}

/// Replace the borrowed snapshot while retaining the visible session's search,
/// selection, and context-menu target by stable identity.
pub fn refreshDesktopWindows(self: *Self, dws: []const common.DesktopWindow) !void {
    try self.grid.refreshDesktopWindows(dws);

    if (self.context_menu) |*menu| {
        var found = false;
        for (dws) |dw| {
            if (!std.mem.eql(u8, dw.stable_id, menu.stable_id)) continue;
            menu.enabled = dw.can_close;
            found = true;
            break;
        }
        if (!found) self.dismissContextMenu();
    }

    // Grid preserves identity/rank by default, but once pointer input has
    // taken control the tile currently under the pointer is authoritative.
    // Do not retarget underneath an open popup or clobber keyboard navigation.
    _ = self.rehitPointerSelection();

    self.repaint() catch |err| {
        // refreshDesktopWindows has already swapped the borrowed slice. Treat
        // drawing as best-effort so presenter ownership can commit in lockstep.
        std.log.err("Wayland refreshed grid repaint failed: {t}", .{err});
    };
    _ = c.wl_display_flush(self.display);
}

pub fn setWindowEventFd(self: *Self, fd: ?std.posix.fd_t) void {
    self.window_event_fd = fd;
}

/// Coalesce lifecycle bursts into one refresh at the end of a 100ms window.
pub fn scheduleRefresh(self: *Self) void {
    if (self.grid.desktop_windows == null) return;
    if (self.refresh_due_ms == null) {
        self.refresh_due_ms = std.time.milliTimestamp() + REFRESH_DEBOUNCE_MS;
    }
}

// ─── Test hooks ───────────────────────────────────────────────────────────────
// Direct entry points for the in-process test driver. Production code never
// calls these; they let tests bypass wl_keyboard / wl_pointer.

pub fn synthesizeKey(self: *Self, action: Keyboard.Action) void {
    onKeyboardAction(self, action);
}
pub fn synthesizeMouse(self: *Self, action: Mouse.Action) void {
    handleMouseAction(self, action, pointInsideViewport(self, mousePoint(action)));
}
pub fn renderInto(self: *Self, pixels: []u32) void {
    // Test driver renders at scale 1.0 into a logical-sized buffer.
    self.renderFrame(pixels, self.layer.width, self.layer.height, 120);
}
pub fn viewportSize(self: *const Self) struct { w: u32, h: u32 } {
    return .{ .w = self.layer.width, .h = self.layer.height };
}

pub fn hideBoxes(self: *Self) !void {
    self.dismissContextMenu();
    self.refresh_due_ms = null;
    self.pointer_inside = false;
    self.selection_authority = .keyboard;
    self.repaint_pending = false;
    self.grid.dropDesktopWindows();
}

/// Pumps one batch of Wayland events. Returns false if the connection died or
/// the compositor closed our surface.
pub fn dispatch(self: *Self) bool {
    if (self.closed) return false;
    if (c.wl_display_dispatch_pending(self.display) < 0) return false;
    self.servicePendingRepaint();
    _ = c.wl_display_flush(self.display);

    var poll_fds: [2]std.posix.pollfd = undefined;
    poll_fds[0] = .{
        .fd = @intCast(c.wl_display_get_fd(self.display)),
        .events = std.posix.POLL.IN,
        .revents = 0,
    };
    var poll_len: usize = 1;

    // Once a refresh is scheduled, temporarily stop polling the external fd.
    // It remains readable while events accumulate, and the eventual refresh
    // drains all of them before enumeration. This avoids a busy loop.
    if (self.window_event_fd) |fd| {
        if (self.refresh_due_ms == null) {
            poll_fds[1] = .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 };
            poll_len = 2;
        }
    }

    const timeout = self.refreshPollTimeout();
    _ = std.posix.poll(poll_fds[0..poll_len], timeout) catch return false;

    const failure_events = std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL;
    if (poll_fds[0].revents & failure_events != 0) return false;
    if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
        if (c.wl_display_dispatch(self.display) < 0) return false;
        // wl_buffer.release callbacks only mark their ShmPool buffers free.
        // Retry here, while MainWindow is known to be alive, instead of
        // retaining a callback pointer that could outlive it.
        self.servicePendingRepaint();
    }

    if (poll_len == 2) {
        if (poll_fds[1].revents & std.posix.POLL.IN != 0) self.scheduleRefresh();
        if (poll_fds[1].revents & failure_events != 0) self.window_event_fd = null;
    }

    self.serviceScheduledRefresh();
    self.servicePendingRepaint();
    return !self.closed;
}

/// KDE's KWin enumeration response arrives over D-Bus and can take up to two
/// seconds. This callback is invoked between short D-Bus wait slices to service
/// the overlay's independent Wayland connection without entering the normal
/// refresh scheduler recursively.
pub fn pumpRefreshWait(ctx: *anyopaque) bool {
    const self: *Self = @ptrCast(@alignCast(ctx));
    if (!self.running or self.closed) return false;

    // First deliver anything libwayland already read. These callbacks may hide
    // or quit the overlay; MainPresenter revalidates snapshot ownership after
    // enumeration before touching its previously-owned descriptor list.
    if (c.wl_display_dispatch_pending(self.display) < 0) {
        self.closed = true;
        return false;
    }
    self.servicePendingRepaint();
    if (!self.running or self.closed) {
        _ = c.wl_display_flush(self.display);
        return false;
    }

    // Use prepare/read/cancel so this path performs a real nonblocking socket
    // read when data is available and never risks waiting inside
    // wl_display_dispatch.
    while (c.wl_display_prepare_read(self.display) != 0) {
        if (c.wl_display_dispatch_pending(self.display) < 0) {
            self.closed = true;
            return false;
        }
        self.servicePendingRepaint();
        if (!self.running or self.closed) {
            _ = c.wl_display_flush(self.display);
            return false;
        }
    }

    // Canonical libwayland ordering: once a read is prepared, flush outgoing
    // requests before waiting for socket readability. Every exit below pairs
    // this successful prepare with either read_events or cancel_read.
    _ = c.wl_display_flush(self.display);

    var fd = [_]std.posix.pollfd{.{
        .fd = @intCast(c.wl_display_get_fd(self.display)),
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    _ = std.posix.poll(&fd, 0) catch {
        c.wl_display_cancel_read(self.display);
        _ = c.wl_display_flush(self.display);
        return self.running and !self.closed;
    };

    const failure_events = std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL;
    if (fd[0].revents & failure_events != 0) {
        c.wl_display_cancel_read(self.display);
        self.closed = true;
        return false;
    }
    if (fd[0].revents & std.posix.POLL.IN == 0) {
        c.wl_display_cancel_read(self.display);
        _ = c.wl_display_flush(self.display);
        return self.running and !self.closed;
    }
    if (c.wl_display_read_events(self.display) < 0) {
        self.closed = true;
        return false;
    }
    if (c.wl_display_dispatch_pending(self.display) < 0) {
        self.closed = true;
        return false;
    }
    self.servicePendingRepaint();
    _ = c.wl_display_flush(self.display);
    return self.running and !self.closed;
}

// ─── Internal helpers ────────────────────────────────────────────────────────

fn repaint(self: *Self) !void {
    if (self.layer.size_dirty) try self.rebuildForScale();
    const buf = self.shm_pool.acquire() orelse {
        // Rendering is state-derived, so one durable bit is enough: the next
        // free buffer always receives the newest grid/menu state.
        self.repaint_pending = true;
        return;
    };
    const phys = self.layer.physicalSize();
    self.renderFrame(buf.pixels, phys.w, phys.h, self.layer.scale_q120);
    self.layer.attachAndCommit(buf.buf);
    self.shm_pool.submit(buf);
    self.repaint_pending = false;
}

fn servicePendingRepaint(self: *Self) void {
    if (!self.repaint_pending) return;
    self.repaint() catch |err| {
        std.log.err("Wayland deferred repaint failed: {t}", .{err});
        return;
    };
    if (!self.repaint_pending) _ = c.wl_display_flush(self.display);
}

fn renderFrame(self: *Self, pixels: []u32, width: u32, height: u32, scale_q120: u32) void {
    Renderer.render(
        pixels,
        width,
        height,
        scale_q120,
        &self.grid,
        &self.tile_text,
        &self.search_text,
        &self.desktop_text,
        .{},
    );
    self.renderContextMenu(pixels, width, height, scale_q120);
}

fn renderContextMenu(self: *Self, pixels: []u32, width: u32, height: u32, scale_q120: u32) void {
    const menu = self.context_menu orelse return;
    const Scale = struct {
        q: u32,
        fn apply(s: @This(), value: i32) i32 {
            return @divFloor(value * @as(i32, @intCast(s.q)), 120);
        }
    };
    const scale = Scale{ .q = scale_q120 };
    const x = scale.apply(menu.rect.x);
    const y = scale.apply(menu.rect.y);
    const w = scale.apply(menu.rect.w);
    const h = scale.apply(menu.rect.h);

    // A small shadow keeps the popup legible over both selected and
    // unselected tiles without requiring another compositor surface.
    Renderer.fillRect(pixels, width, x + scale.apply(2), y + scale.apply(2), w, h, 0x70000000);
    Renderer.fillRect(pixels, width, x, y, w, h, 0xFFF7F7F7);
    Renderer.drawRect(pixels, width, x, y, w, h, 0xFF505050);

    const color: u32 = if (menu.enabled) 0xFF111111 else 0xFF888888;
    const label_x = x + scale.apply(MENU_PAD);
    const baseline = y + h - @divFloor(h - self.tile_text.ascent, 2);
    _ = self.tile_text.draw(
        pixels,
        width,
        label_x,
        baseline,
        MENU_LABEL,
        color,
        .{ .x0 = x + 1, .y0 = y + 1, .x1 = @as(i32, @intCast(width)), .y1 = @as(i32, @intCast(height)) },
    ) catch 0;
}

fn refreshPollTimeout(self: *const Self) i32 {
    const due = self.refresh_due_ms orelse return -1;
    const remaining = due - std.time.milliTimestamp();
    if (remaining <= 0) return 0;
    return @intCast(@min(remaining, std.math.maxInt(i32)));
}

fn serviceScheduledRefresh(self: *Self) void {
    const due = self.refresh_due_ms orelse return;
    if (std.time.milliTimestamp() < due) return;
    // Clear first so a lifecycle event received during enumeration can queue a
    // trailing refresh instead of being lost.
    self.refresh_due_ms = null;
    self.callbacks.refreshWindows(self) catch |err| {
        std.log.err("Wayland live window refresh failed: {t}", .{err});
    };
}

fn openContextMenu(self: *Self, x: i32, y: i32) void {
    const tile_idx = self.grid.tileAt(x, y) orelse {
        self.dismissContextMenu();
        return;
    };
    const tile = self.grid.tiles.items[tile_idx];
    self.grid.selected = tile_idx;

    const stable_id = self.allocator.dupe(u8, tile.dw.stable_id) catch {
        self.dismissContextMenu();
        return;
    };
    self.dismissContextMenu();

    const max_x = @max(0, self.grid.viewport_w - MENU_W);
    const max_y = @max(0, self.grid.viewport_h - MENU_H);
    const menu_x = std.math.clamp(x, 0, max_x);
    const preferred_y = if (y + MENU_H <= self.grid.viewport_h) y else y - MENU_H;
    const menu_y = std.math.clamp(preferred_y, 0, max_y);
    self.context_menu = .{
        .stable_id = stable_id,
        .rect = .{ .x = menu_x, .y = menu_y, .w = MENU_W, .h = MENU_H },
        .enabled = tile.dw.can_close,
    };
}

fn dismissContextMenu(self: *Self) void {
    if (self.context_menu) |menu| self.allocator.free(menu.stable_id);
    self.context_menu = null;
}

fn pointInside(rect: Grid.Rect, x: i32, y: i32) bool {
    return x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h;
}

fn mousePoint(action: input.MouseAction) PointerPoint {
    return switch (action) {
        inline else => |point| .{ .x = point.x, .y = point.y },
    };
}

fn pointInsideViewport(self: *const Self, point: PointerPoint) bool {
    return point.x >= 0 and point.x < self.grid.viewport_w and
        point.y >= 0 and point.y < self.grid.viewport_h;
}

fn rehitPointerSelection(self: *Self) bool {
    if (self.context_menu != null or
        self.selection_authority != .pointer or
        !self.pointer_inside)
    {
        return false;
    }
    return self.grid.selectAt(self.pointer_x, self.pointer_y);
}

fn invokeContextClose(self: *Self) void {
    const menu = self.context_menu orelse return;
    if (!menu.enabled) return;

    // Take ownership out of the field before invoking the presenter. A
    // synchronous refresh may update or dismiss menu state.
    self.context_menu = null;
    defer self.allocator.free(menu.stable_id);
    self.callbacks.closeWindow(self, menu.stable_id) catch |err| {
        std.log.err("Wayland close request failed: {t}", .{err});
        return;
    };
}

fn rebuildForScale(self: *Self) !void {
    self.shm_pool.deinit();
    const phys = self.layer.physicalSize();
    try self.shm_pool.init(self.globals.shm.?, phys.w, phys.h);
    self.layer.applyViewport();

    self.tile_text.destroy();
    self.search_text.destroy();
    self.desktop_text.destroy();
    self.tile_text = try text.Renderer.create(self.allocator, scaledFont(LOGICAL_FONT_TILE, self.layer.scale_q120), .regular);
    self.search_text = try text.Renderer.create(self.allocator, scaledFont(LOGICAL_FONT_SEARCH, self.layer.scale_q120), .regular);
    self.desktop_text = try text.Renderer.create(self.allocator, scaledFont(LOGICAL_FONT_DESKTOP, self.layer.scale_q120), .bold);

    self.grid.setViewport(@intCast(self.layer.width), @intCast(self.layer.height));
    self.layer.size_dirty = false;
}

fn activateSelected(self: *Self) void {
    const dw = self.grid.selectedWindow() orelse return;
    self.callbacks.activateWindow(self, dw) catch {};
}

// ─── Registry global callbacks ────────────────────────────────────────────────

fn onRegistryGlobal(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32, iface: [*c]const u8, version: u32) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(data));
    const s = std.mem.span(iface);
    if (std.mem.eql(u8, s, "wl_compositor")) {
        self.globals.compositor = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_compositor_interface, @min(version, 5)));
    } else if (std.mem.eql(u8, s, "wl_shm")) {
        self.globals.shm = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_shm_interface, @min(version, 1)));
    } else if (std.mem.eql(u8, s, "zwlr_layer_shell_v1")) {
        self.globals.layer_shell = @ptrCast(c.wl_registry_bind(registry, name, &c.zwlr_layer_shell_v1_interface, @min(version, 4)));
    } else if (std.mem.eql(u8, s, "wl_seat")) {
        const seat: *c.wl_seat = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_seat_interface, @min(version, 7)));
        self.globals.seat = seat;
        // Attach the seat listener immediately so the capabilities event,
        // which the compositor sends right after binding, lands in our
        // onSeatCaps callback in this same roundtrip.
        _ = c.wl_seat_add_listener(seat, &self.seat_listener, self);
    } else if (std.mem.eql(u8, s, "wp_fractional_scale_manager_v1")) {
        self.globals.fractional_scale_mgr = @ptrCast(c.wl_registry_bind(registry, name, &c.wp_fractional_scale_manager_v1_interface, @min(version, 1)));
    } else if (std.mem.eql(u8, s, "wp_viewporter")) {
        self.globals.viewporter = @ptrCast(c.wl_registry_bind(registry, name, &c.wp_viewporter_interface, @min(version, 1)));
    }
}

fn onRegistryRemove(_: ?*anyopaque, _: ?*c.wl_registry, _: u32) callconv(.c) void {}

// ─── Seat capability dispatcher ───────────────────────────────────────────────

fn onSeatCaps(data: ?*anyopaque, seat: ?*c.wl_seat, caps: u32) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(data));
    std.log.debug("wl_seat caps: 0x{x}", .{caps});
    if (caps & c.WL_SEAT_CAPABILITY_KEYBOARD != 0 and self.keyboard.keyboard == null) {
        if (c.wl_seat_get_keyboard(seat)) |kb| self.keyboard.attachKeyboard(kb);
    }
    if (caps & c.WL_SEAT_CAPABILITY_POINTER != 0 and self.mouse.pointer == null) {
        if (c.wl_seat_get_pointer(seat)) |p| self.mouse.attachPointer(p);
    }
}

fn onSeatName(_: ?*anyopaque, _: ?*c.wl_seat, _: [*c]const u8) callconv(.c) void {}

// ─── Action sinks ─────────────────────────────────────────────────────────────

fn hooks(self: *Self) input.Hooks {
    return .{ .ctx = self, .hide = onHookHide, .activate_selected = onHookActivate, .open_settings = onHookOpenSettings };
}
fn onHookHide(ctx: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.callbacks.hide(self) catch {};
}
fn onHookActivate(ctx: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.activateSelected();
}
fn onHookOpenSettings(ctx: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    // No settings UI on Wayland; forward to the (no-op) presenter handler.
    self.callbacks.openSettings(self) catch {};
}

fn onKeyboardAction(ctx: *anyopaque, action: input.KeyAction) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.selection_authority = .keyboard;
    if (self.context_menu != null) {
        switch (action) {
            .quit => self.dismissContextMenu(),
            .activate => self.invokeContextClose(),
            else => {}, // Menu tracking suppresses navigation/search underneath.
        }
    } else {
        input.dispatchKey(&self.grid, self.hooks(), action);
    }
    self.repaint() catch {};
    _ = c.wl_display_flush(self.display);
}

fn onMouseAction(ctx: *anyopaque, action: input.MouseAction) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    handleMouseAction(self, action, self.mouse.inside);
}

fn onPointerPresence(ctx: *anyopaque, inside: bool, x: i32, y: i32) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.pointer_x = x;
    self.pointer_y = y;
    self.pointer_inside = inside;
    if (!inside) return;

    // Enter is itself fresh pointer input. Select immediately rather than
    // waiting for a motion event, while a later key action can still take
    // authority back and keep it across refreshes.
    self.selection_authority = .pointer;
    if (self.rehitPointerSelection()) {
        self.repaint() catch {};
        _ = c.wl_display_flush(self.display);
    }
}

fn handleMouseAction(self: *Self, action: input.MouseAction, pointer_inside: bool) void {
    const point = mousePoint(action);
    self.pointer_x = point.x;
    self.pointer_y = point.y;
    self.pointer_inside = pointer_inside;
    self.selection_authority = .pointer;

    const menu_was_open = self.context_menu != null;
    var repaint_needed = false;
    if (self.context_menu) |menu| {
        switch (action) {
            // Keep the latest pointer coordinates, but do not retarget or
            // repaint the underlying grid while tracking the popup.
            .move => {},
            .click => |m| {
                if (pointInside(menu.rect, m.x, m.y)) {
                    self.invokeContextClose();
                } else {
                    self.dismissContextMenu();
                }
                repaint_needed = true;
            },
            .context => |m| {
                // Right-clicking another tile moves the menu; empty space only
                // dismisses the existing popup.
                self.openContextMenu(m.x, m.y);
                repaint_needed = true;
            },
        }
    } else {
        switch (action) {
            .move => |m| {
                // Full-frame software rendering is expensive; a motion within
                // the already-selected tile has no visual effect.
                repaint_needed = self.grid.selectAt(m.x, m.y);
            },
            .click => {
                input.dispatchMouse(&self.grid, self.hooks(), action);
                repaint_needed = true;
            },
            .context => |m| {
                self.openContextMenu(m.x, m.y);
                repaint_needed = true;
            },
        }
    }

    if (menu_was_open and self.context_menu == null) {
        repaint_needed = self.rehitPointerSelection() or repaint_needed;
    }

    if (repaint_needed) {
        self.repaint() catch {};
        _ = c.wl_display_flush(self.display);
    }
}
