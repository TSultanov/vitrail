const std = @import("std");
const wc = @import("wayland_c.zig");
const c = wc.c;
const input = @import("../../common/InputAction.zig");

const Self = @This();

pub const Action = input.KeyAction;
pub const Callbacks = input.KeyCallbacks;

xkb_ctx: ?*c.xkb_context,
xkb_state: ?*c.xkb_state,
keyboard: ?*c.wl_keyboard = null,
kb_listener: c.wl_keyboard_listener,
callbacks: Callbacks,

pub fn init(self: *Self, callbacks: Callbacks) !void {
    self.* = .{
        .xkb_ctx = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse return error.XkbContextNew,
        .xkb_state = null,
        .kb_listener = .{
            .keymap = onKeymap,
            .enter = onEnter,
            .leave = onLeave,
            .key = onKey,
            .modifiers = onMods,
            .repeat_info = onRepeatInfo,
        },
        .callbacks = callbacks,
    };
}

pub fn deinit(self: *Self) void {
    if (self.xkb_state) |s| c.xkb_state_unref(s);
    if (self.xkb_ctx) |ctx| c.xkb_context_unref(ctx);
    if (self.keyboard) |kb| c.wl_keyboard_destroy(kb);
}

pub fn attachKeyboard(self: *Self, kb: *c.wl_keyboard) void {
    self.keyboard = kb;
    _ = c.wl_keyboard_add_listener(kb, &self.kb_listener, self);
}

/// Synthesize an action — used by the in-process test driver.
pub fn synthesize(self: *Self, action: Action) void {
    self.callbacks.on_action(self.callbacks.ctx, action);
}

fn onKeymap(data: ?*anyopaque, _: ?*c.wl_keyboard, format: u32, fd: i32, size: u32) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(data));
    defer std.posix.close(fd);
    if (format != c.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) return;
    const ctx = self.xkb_ctx orelse return;

    const ptr = std.posix.mmap(null, size, std.posix.PROT.READ, .{ .TYPE = .PRIVATE }, fd, 0) catch return;
    defer std.posix.munmap(@alignCast(ptr));

    const keymap = c.xkb_keymap_new_from_string(ctx, ptr.ptr, c.XKB_KEYMAP_FORMAT_TEXT_V1, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse return;
    defer c.xkb_keymap_unref(keymap);

    if (self.xkb_state) |s| c.xkb_state_unref(s);
    self.xkb_state = c.xkb_state_new(keymap);
}

fn onEnter(_: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, _: ?*c.wl_surface, _: ?*c.wl_array) callconv(.c) void {}
fn onLeave(_: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, _: ?*c.wl_surface) callconv(.c) void {}

fn onKey(data: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, _: u32, key: u32, state: u32) callconv(.c) void {
    if (state != c.WL_KEYBOARD_KEY_STATE_PRESSED) return;
    const self: *Self = @ptrCast(@alignCast(data));
    const xkb_state = self.xkb_state orelse return;

    const keycode = key + 8; // evdev → xkb offset
    const sym = c.xkb_state_key_get_one_sym(xkb_state, keycode);

    const emit = self.callbacks.on_action;
    const ctx = self.callbacks.ctx;

    switch (sym) {
        c.XKB_KEY_Escape => emit(ctx, .quit),
        c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => emit(ctx, .activate),
        c.XKB_KEY_Tab => emit(ctx, .next),
        c.XKB_KEY_ISO_Left_Tab => emit(ctx, .prev),
        c.XKB_KEY_Right => emit(ctx, .{ .move = .{ .dx = 1, .dy = 0 } }),
        c.XKB_KEY_Left => emit(ctx, .{ .move = .{ .dx = -1, .dy = 0 } }),
        c.XKB_KEY_Down => emit(ctx, .{ .move = .{ .dx = 0, .dy = 1 } }),
        c.XKB_KEY_Up => emit(ctx, .{ .move = .{ .dx = 0, .dy = -1 } }),
        c.XKB_KEY_BackSpace => {
            const ctrl_held = c.xkb_state_mod_name_is_active(xkb_state, "Control", c.XKB_STATE_MODS_EFFECTIVE) > 0;
            if (ctrl_held) emit(ctx, .delete_word) else emit(ctx, .backspace);
        },
        else => {
            var buf: [16]u8 = undefined;
            const n = c.xkb_state_key_get_utf8(xkb_state, keycode, &buf, buf.len);
            if (n > 0 and buf[0] >= 0x20 and buf[0] != 0x7F) {
                emit(ctx, .{ .insert = buf[0..@intCast(n)] });
            }
        },
    }
}

fn onMods(data: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, mods_dep: u32, mods_lat: u32, mods_lock: u32, group: u32) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(data));
    if (self.xkb_state) |s| _ = c.xkb_state_update_mask(s, mods_dep, mods_lat, mods_lock, 0, 0, group);
}

fn onRepeatInfo(_: ?*anyopaque, _: ?*c.wl_keyboard, _: i32, _: i32) callconv(.c) void {}
