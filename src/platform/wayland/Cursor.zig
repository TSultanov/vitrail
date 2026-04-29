// Loads the system cursor theme via libwayland-cursor and applies the
// "default" pointer image to wl_pointer on enter. Without this, our surface
// receives pointer focus but the compositor doesn't show a cursor.
const std = @import("std");
const wc = @import("wayland_c.zig");
const c = wc.c;

const Self = @This();

theme: ?*c.wl_cursor_theme = null,
cursor_surface: ?*c.wl_surface = null,
cursor: ?*c.wl_cursor = null,

pub fn init(self: *Self, compositor: *c.wl_compositor, shm: *c.wl_shm) !void {
    self.* = .{};
    // Honor XCURSOR_THEME / XCURSOR_SIZE if set; pass null + 24 to fall back.
    const theme_name: ?[*:0]const u8 = if (std.posix.getenv("XCURSOR_THEME")) |t| @ptrCast(t.ptr) else null;
    const size: c_int = if (std.posix.getenv("XCURSOR_SIZE")) |s| std.fmt.parseInt(c_int, s, 10) catch 24 else 24;

    self.theme = c.wl_cursor_theme_load(theme_name, size, shm) orelse return error.CursorThemeLoad;
    errdefer if (self.theme) |t| c.wl_cursor_theme_destroy(t);

    // Try a few common names; some themes don't include "default".
    const names = [_][*:0]const u8{ "default", "left_ptr", "arrow" };
    for (names) |n| {
        if (c.wl_cursor_theme_get_cursor(self.theme, n)) |cur| {
            self.cursor = cur;
            break;
        }
    }
    if (self.cursor == null) return error.CursorImageMissing;

    self.cursor_surface = c.wl_compositor_create_surface(compositor) orelse return error.CursorSurfaceCreate;
}

pub fn deinit(self: *Self) void {
    if (self.cursor_surface) |s| c.wl_surface_destroy(s);
    if (self.theme) |t| c.wl_cursor_theme_destroy(t);
}

/// Apply the cursor to the pointer for this enter event.
pub fn apply(self: *Self, pointer: *c.wl_pointer, serial: u32) void {
    const cursor = self.cursor orelse return;
    const surface = self.cursor_surface orelse return;
    if (cursor.*.image_count == 0) return;
    const image = cursor.*.images[0].*;
    const buf = c.wl_cursor_image_get_buffer(cursor.*.images[0]) orelse return;
    c.wl_surface_attach(surface, buf, 0, 0);
    c.wl_surface_damage(surface, 0, 0, @intCast(image.width), @intCast(image.height));
    c.wl_surface_commit(surface);
    c.wl_pointer_set_cursor(pointer, serial, surface, @intCast(image.hotspot_x), @intCast(image.hotspot_y));
}
