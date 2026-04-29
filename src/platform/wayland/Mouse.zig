// wl_pointer wrapper. Tracks the latest cursor position from enter/motion
// events and emits a Mouse.Action on motion + on left-button-down.
const std = @import("std");
const wc = @import("wayland_c.zig");
const c = wc.c;
const Cursor = @import("Cursor.zig");

const Self = @This();

pub const Action = union(enum) {
    move: struct { x: i32, y: i32 },
    click: struct { x: i32, y: i32 },
};

pub const Callbacks = struct {
    on_action: *const fn (ctx: *anyopaque, action: Action) void,
    ctx: *anyopaque,
};

pointer: ?*c.wl_pointer = null,
pointer_listener: c.wl_pointer_listener,
callbacks: Callbacks,
cursor: ?*Cursor = null,

cur_x: i32 = 0,
cur_y: i32 = 0,
inside: bool = false,

pub fn init(self: *Self, callbacks: Callbacks) void {
    self.* = .{
        .pointer_listener = .{
            .enter = onEnter,
            .leave = onLeave,
            .motion = onMotion,
            .button = onButton,
            .axis = onAxis,
            .frame = onFrame,
            .axis_source = onAxisSource,
            .axis_stop = onAxisStop,
            .axis_discrete = onAxisDiscrete,
            .axis_value120 = onAxisValue120,
            .axis_relative_direction = onAxisRelativeDirection,
        },
        .callbacks = callbacks,
    };
}

pub fn deinit(self: *Self) void {
    if (self.pointer) |p| c.wl_pointer_destroy(p);
}

pub fn attachPointer(self: *Self, pointer: *c.wl_pointer) void {
    self.pointer = pointer;
    _ = c.wl_pointer_add_listener(pointer, &self.pointer_listener, self);
}

pub fn setCursor(self: *Self, cursor: *Cursor) void {
    self.cursor = cursor;
}

fn onEnter(data: ?*anyopaque, _: ?*c.wl_pointer, serial: u32, _: ?*c.wl_surface, sx: c.wl_fixed_t, sy: c.wl_fixed_t) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(data));
    self.cur_x = wlFixedToInt(sx);
    self.cur_y = wlFixedToInt(sy);
    self.inside = true;
    if (self.cursor) |cur| if (self.pointer) |p| cur.apply(p, serial);
}

fn onLeave(data: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: ?*c.wl_surface) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(data));
    self.inside = false;
}

fn onMotion(data: ?*anyopaque, _: ?*c.wl_pointer, _: u32, sx: c.wl_fixed_t, sy: c.wl_fixed_t) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(data));
    self.cur_x = wlFixedToInt(sx);
    self.cur_y = wlFixedToInt(sy);
    self.callbacks.on_action(self.callbacks.ctx, .{ .move = .{ .x = self.cur_x, .y = self.cur_y } });
}

fn onButton(data: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: u32, button: u32, state: u32) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(data));
    // BTN_LEFT == 0x110 (linux/input-event-codes.h). Single-click on press.
    if (button != 0x110) return;
    if (state != c.WL_POINTER_BUTTON_STATE_PRESSED) return;
    self.callbacks.on_action(self.callbacks.ctx, .{ .click = .{ .x = self.cur_x, .y = self.cur_y } });
}

fn onAxis(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: u32, _: c.wl_fixed_t) callconv(.c) void {}
fn onFrame(_: ?*anyopaque, _: ?*c.wl_pointer) callconv(.c) void {}
fn onAxisSource(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32) callconv(.c) void {}
fn onAxisStop(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: u32) callconv(.c) void {}
fn onAxisDiscrete(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: i32) callconv(.c) void {}
fn onAxisValue120(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: i32) callconv(.c) void {}
fn onAxisRelativeDirection(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: u32) callconv(.c) void {}

fn wlFixedToInt(v: c.wl_fixed_t) i32 {
    return @intCast(v >> 8);
}
