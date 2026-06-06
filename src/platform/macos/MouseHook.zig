// Global mouse-button trigger for macOS, built on a CGEventTap (plain C, like
// the Carbon HotKey module — no Obj-C needed). Watches system-wide right- and
// other-mouse button presses; when one matches the configured binding it fires
// the trigger callback (which shows the grid).
//
// Permission model: an *active* tap that can swallow the click needs
// Accessibility (already requested by the app for window raising). If the active
// tap can't be created we fall back to a *listen-only* tap (Input Monitoring),
// which still detects the press but cannot consume it. We surface the Input
// Monitoring prompt at startup rather than lazily — see the project memory note
// on prompting for OS permissions during init.

const std = @import("std");
const Config = @import("../../common/Config.zig");

const c = @cImport({
    @cInclude("CoreGraphics/CoreGraphics.h");
    @cInclude("CoreFoundation/CoreFoundation.h");
});

pub const Callback = *const fn (ctx: *anyopaque) void;

const Self = @This();

tap: c.CFMachPortRef = null,
source: c.CFRunLoopSourceRef = null,
listen_only: bool = false,
on_press: Callback,
ctx: *anyopaque,
// Live pointers into the app's settings so edits in the settings UI take
// effect without reinstalling the tap.
button: *const Config.MouseBinding,
enabled: *const bool,

/// Map a raw macOS mouse event (right-button flag + NSEvent/CGEvent
/// buttonNumber) to a platform-neutral binding. Single source of truth shared
/// by the trigger tap here and the settings-window press-to-bind capture, so
/// recording and matching always agree. macOS numbering: 0 left, 1 right,
/// 2 middle, 3 back, 4 forward.
pub fn classifyButtonNumber(is_right: bool, button_number: i64) Config.MouseBinding {
    if (is_right) return .{ .kind = .right, .code = 1 };
    const code: u32 = @intCast(@max(@as(i64, 0), button_number));
    return switch (button_number) {
        0 => .{ .kind = .left, .code = 0 },
        2 => .{ .kind = .middle, .code = code },
        3 => .{ .kind = .x1, .code = code },
        4 => .{ .kind = .x2, .code = code },
        else => .{ .kind = .other, .code = code },
    };
}

fn matches(cfg: Config.MouseBinding, ev: Config.MouseBinding) bool {
    if (cfg.kind == .none) return false;
    if (cfg.kind != ev.kind) return false;
    if (cfg.kind == .other) return cfg.code == ev.code;
    return true;
}

/// Install the tap. Non-fatal: on permission failure it logs and leaves the
/// hook inert (the keyboard hotkey still works).
pub fn init(
    self: *Self,
    on_press: Callback,
    ctx: *anyopaque,
    button: *const Config.MouseBinding,
    enabled: *const bool,
) void {
    self.* = .{ .on_press = on_press, .ctx = ctx, .button = button, .enabled = enabled };

    // Surface the Input Monitoring prompt during launch.
    _ = c.CGRequestListenEventAccess();

    const one: u64 = 1;
    const mask: c.CGEventMask =
        (one << @as(u6, @intCast(c.kCGEventOtherMouseDown))) |
        (one << @as(u6, @intCast(c.kCGEventRightMouseDown)));

    // Prefer an active tap (can swallow the trigger click); fall back to
    // listen-only if Accessibility isn't granted.
    var listen_only = false;
    var tap = c.CGEventTapCreate(c.kCGSessionEventTap, c.kCGHeadInsertEventTap, c.kCGEventTapOptionDefault, mask, tapCallback, self);
    if (tap == null) {
        tap = c.CGEventTapCreate(c.kCGSessionEventTap, c.kCGHeadInsertEventTap, c.kCGEventTapOptionListenOnly, mask, tapCallback, self);
        listen_only = true;
    }
    if (tap == null) {
        std.log.warn("mouse trigger disabled: could not create event tap (grant Input Monitoring / Accessibility)", .{});
        return;
    }

    const source = c.CFMachPortCreateRunLoopSource(null, tap, 0);
    if (source == null) {
        c.CFRelease(@ptrCast(tap));
        std.log.warn("mouse trigger disabled: run-loop source creation failed", .{});
        return;
    }
    c.CFRunLoopAddSource(c.CFRunLoopGetMain(), source, c.kCFRunLoopCommonModes);
    c.CGEventTapEnable(tap, true);

    self.tap = tap;
    self.source = source;
    self.listen_only = listen_only;
}

pub fn deinit(self: *Self) void {
    if (self.source) |s| {
        c.CFRunLoopRemoveSource(c.CFRunLoopGetMain(), s, c.kCFRunLoopCommonModes);
        c.CFRelease(@ptrCast(s));
        self.source = null;
    }
    if (self.tap) |t| {
        c.CGEventTapEnable(t, false);
        c.CFRelease(@ptrCast(t));
        self.tap = null;
    }
}

fn tapCallback(
    _: c.CGEventTapProxy,
    etype: c.CGEventType,
    event: c.CGEventRef,
    user_info: ?*anyopaque,
) callconv(.c) c.CGEventRef {
    const self: *Self = @ptrCast(@alignCast(user_info orelse return event));

    // The system disables a slow/blocked tap; re-enable and pass through.
    if (etype == c.kCGEventTapDisabledByTimeout or etype == c.kCGEventTapDisabledByUserInput) {
        if (self.tap) |t| c.CGEventTapEnable(t, true);
        return event;
    }

    if (!self.enabled.*) return event;

    const is_right = etype == c.kCGEventRightMouseDown;
    const bn = c.CGEventGetIntegerValueField(event, c.kCGMouseEventButtonNumber);
    const ev = classifyButtonNumber(is_right, bn);
    if (!matches(self.button.*, ev)) return event;

    self.on_press(self.ctx);
    // Swallow the trigger click when we have an active tap; a listen-only tap
    // can't, so the button keeps its normal function.
    return if (self.listen_only) event else null;
}
