// macOS keyboard event translation. Maps NSEvent virtual keycodes to the
// platform-agnostic KeyAction union defined in common/InputAction.zig.

const std = @import("std");
const input = @import("../../common/InputAction.zig");

const Self = @This();

pub const Action = input.KeyAction;
pub const Callbacks = input.KeyCallbacks;

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

// NSEvent modifier flag masks (NSEventModifierFlag* in <AppKit/NSEvent.h>).
const NS_MOD_SHIFT: u32 = 1 << 17;
const NS_MOD_COMMAND: u32 = 1 << 20;

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
        kVK_Delete => {
            if ((modifiers & NS_MOD_COMMAND) != 0) emit(ctx, .delete_word) else emit(ctx, .backspace);
        },
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
