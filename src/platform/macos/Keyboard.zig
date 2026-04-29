// macOS keyboard event translation. Maps NSEvent virtual keycodes to the
// platform-agnostic Action union used by the rest of the app. Mirrors the
// Wayland Keyboard.zig contract.

const std = @import("std");

const Self = @This();

pub const Action = union(enum) {
    quit,
    activate,
    next,
    prev,
    move: struct { dx: i32, dy: i32 },
    backspace,
    insert: []const u8, // UTF-8; valid only for the duration of the callback
};

pub const Callbacks = struct {
    on_action: *const fn (ctx: *anyopaque, action: Action) void,
    ctx: *anyopaque,
};

callbacks: Callbacks,

// Apple virtual keycodes (HIToolbox/Events.h). Stable across keyboard layouts.
const kVK_Return: c_int = 0x24;
const kVK_Tab: c_int = 0x30;
const kVK_Delete: c_int = 0x33; // backspace
const kVK_Escape: c_int = 0x35;
const kVK_ANSI_KeypadEnter: c_int = 0x4C;
const kVK_LeftArrow: c_int = 0x7B;
const kVK_RightArrow: c_int = 0x7C;
const kVK_DownArrow: c_int = 0x7D;
const kVK_UpArrow: c_int = 0x7E;

// NSEventModifierFlagShift mask
const NS_MOD_SHIFT: u32 = 1 << 17;

pub fn init(callbacks: Callbacks) Self {
    return .{ .callbacks = callbacks };
}

pub fn handle(self: *Self, virtual_keycode: c_int, modifiers: u32, utf8: []const u8) void {
    const emit = self.callbacks.on_action;
    const ctx = self.callbacks.ctx;

    switch (virtual_keycode) {
        kVK_Escape => emit(ctx, .quit),
        kVK_Return, kVK_ANSI_KeypadEnter => emit(ctx, .activate),
        kVK_Tab => {
            if ((modifiers & NS_MOD_SHIFT) != 0) emit(ctx, .prev) else emit(ctx, .next);
        },
        kVK_LeftArrow => emit(ctx, .{ .move = .{ .dx = -1, .dy = 0 } }),
        kVK_RightArrow => emit(ctx, .{ .move = .{ .dx = 1, .dy = 0 } }),
        kVK_UpArrow => emit(ctx, .{ .move = .{ .dx = 0, .dy = -1 } }),
        kVK_DownArrow => emit(ctx, .{ .move = .{ .dx = 0, .dy = 1 } }),
        kVK_Delete => emit(ctx, .backspace),
        else => {
            if (utf8.len == 0) return;
            // Filter out C0 controls and DEL — those arrived via the keyCode
            // branches above for keys we care about.
            if (utf8[0] < 0x20 or utf8[0] == 0x7F) return;
            emit(ctx, .{ .insert = utf8 });
        },
    }
}

pub fn synthesize(self: *Self, action: Action) void {
    self.callbacks.on_action(self.callbacks.ctx, action);
}
