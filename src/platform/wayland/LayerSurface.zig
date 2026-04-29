const std = @import("std");
const wc = @import("wayland_c.zig");
const c = wc.c;

const Self = @This();

surface: *c.wl_surface,
layer_surface: *c.zwlr_layer_surface_v1,
fractional_scale: ?*c.wp_fractional_scale_v1 = null,
viewport: ?*c.wp_viewport = null,
width: u32 = 0, // logical pixels (from configure)
height: u32 = 0,
configured: bool = false,
// Compositor-suggested scale, units of 1/120. Defaults to 1.0 if no
// wp_fractional_scale_v1 / preferred_scale event arrives.
scale_q120: u32 = 120,
closed_flag: *bool, // owned by parent; set to true when compositor closes the surface
// Set whenever the buffer's physical size or font sizes need to change
// (initial setup or scale/configure delta).
size_dirty: bool = false,

listener: c.zwlr_layer_surface_v1_listener,
fractional_scale_listener: c.wp_fractional_scale_v1_listener,

pub fn init(
    self: *Self,
    compositor: *c.wl_compositor,
    layer_shell: *c.zwlr_layer_shell_v1,
    fractional_scale_mgr: ?*c.wp_fractional_scale_manager_v1,
    viewporter: ?*c.wp_viewporter,
    closed_flag: *bool,
) !void {
    const surface = c.wl_compositor_create_surface(compositor) orelse return error.SurfaceCreate;
    errdefer c.wl_surface_destroy(surface);

    const ls = c.zwlr_layer_shell_v1_get_layer_surface(
        layer_shell,
        surface,
        null,
        c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
        "vitrail",
    ) orelse return error.LayerSurfaceCreate;
    errdefer c.zwlr_layer_surface_v1_destroy(ls);

    self.* = .{
        .surface = surface,
        .layer_surface = ls,
        .closed_flag = closed_flag,
        .listener = .{ .configure = onConfig, .closed = onClosed },
        .fractional_scale_listener = .{ .preferred_scale = onPreferredScale },
    };

    _ = c.zwlr_layer_surface_v1_add_listener(ls, &self.listener, self);
    c.zwlr_layer_surface_v1_set_size(ls, 0, 0);
    c.zwlr_layer_surface_v1_set_anchor(
        ls,
        c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT,
    );
    c.zwlr_layer_surface_v1_set_exclusive_zone(ls, -1);
    c.zwlr_layer_surface_v1_set_keyboard_interactivity(ls, c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE);

    if (fractional_scale_mgr) |mgr| {
        const fs = c.wp_fractional_scale_manager_v1_get_fractional_scale(mgr, surface);
        if (fs) |p| {
            self.fractional_scale = p;
            _ = c.wp_fractional_scale_v1_add_listener(p, &self.fractional_scale_listener, self);
        }
    }
    if (viewporter) |vp| {
        self.viewport = c.wp_viewporter_get_viewport(vp, surface);
    }

    c.wl_surface_commit(surface);
}

pub fn deinit(self: *Self) void {
    if (self.viewport) |v| c.wp_viewport_destroy(v);
    if (self.fractional_scale) |f| c.wp_fractional_scale_v1_destroy(f);
    c.zwlr_layer_surface_v1_destroy(self.layer_surface);
    c.wl_surface_destroy(self.surface);
}

/// Physical buffer dimensions to allocate, given the current scale.
pub fn physicalSize(self: *const Self) struct { w: u32, h: u32 } {
    const w = (self.width * self.scale_q120 + 119) / 120;
    const h = (self.height * self.scale_q120 + 119) / 120;
    return .{ .w = w, .h = h };
}

/// Tell the compositor what logical size to display our (physical) buffer at.
pub fn applyViewport(self: *Self) void {
    if (self.viewport) |v| {
        if (self.width > 0 and self.height > 0) {
            c.wp_viewport_set_destination(v, @intCast(self.width), @intCast(self.height));
        }
    }
}

pub fn attachAndCommit(self: *Self, buffer: *c.wl_buffer) void {
    const phys = self.physicalSize();
    c.wl_surface_attach(self.surface, buffer, 0, 0);
    c.wl_surface_damage_buffer(self.surface, 0, 0, @intCast(phys.w), @intCast(phys.h));
    c.wl_surface_commit(self.surface);
}

fn onConfig(data: ?*anyopaque, ls: ?*c.zwlr_layer_surface_v1, serial: u32, w: u32, h: u32) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(data));
    if (self.width != w or self.height != h) self.size_dirty = true;
    self.width = w;
    self.height = h;
    self.configured = true;
    c.zwlr_layer_surface_v1_ack_configure(ls, serial);
}

fn onClosed(data: ?*anyopaque, _: ?*c.zwlr_layer_surface_v1) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(data));
    self.closed_flag.* = true;
}

fn onPreferredScale(data: ?*anyopaque, _: ?*c.wp_fractional_scale_v1, scale: u32) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(data));
    if (scale == 0) return;
    if (self.scale_q120 != scale) self.size_dirty = true;
    self.scale_q120 = scale;
}
