const std = @import("std");
const wc = @import("wayland_c.zig");
const c = wc.c;

const Self = @This();

surface: *c.wl_surface,
layer_surface: *c.zwlr_layer_surface_v1,
width: u32 = 0,
height: u32 = 0,
configured: bool = false,
closed_flag: *bool, // owned by parent; set to true when compositor closes the surface

listener: c.zwlr_layer_surface_v1_listener,

pub fn init(
    self: *Self,
    compositor: *c.wl_compositor,
    layer_shell: *c.zwlr_layer_shell_v1,
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
    c.wl_surface_commit(surface);
}

pub fn deinit(self: *Self) void {
    c.zwlr_layer_surface_v1_destroy(self.layer_surface);
    c.wl_surface_destroy(self.surface);
}

pub fn attachAndCommit(self: *Self, buffer: *c.wl_buffer) void {
    c.wl_surface_attach(self.surface, buffer, 0, 0);
    c.wl_surface_damage_buffer(self.surface, 0, 0, @intCast(self.width), @intCast(self.height));
    c.wl_surface_commit(self.surface);
}

fn onConfig(data: ?*anyopaque, ls: ?*c.zwlr_layer_surface_v1, serial: u32, w: u32, h: u32) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(data));
    self.width = w;
    self.height = h;
    self.configured = true;
    c.zwlr_layer_surface_v1_ack_configure(ls, serial);
}

fn onClosed(data: ?*anyopaque, _: ?*c.zwlr_layer_surface_v1) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(data));
    self.closed_flag.* = true;
}
