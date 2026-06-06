// Maps Win32 mouse-button messages to the platform-neutral Config.MouseBinding.
// Shared by the low-level mouse hook (Entry.zig, the global trigger) and the
// settings window's press-to-bind capture, so recording and matching agree.

const wh = @import("windows.zig");
const w = wh.c;
const Config = @import("../../common/Config.zig");

/// `msg` is a WM_*BUTTONDOWN message id; `mouse_data` is the wParam-style value
/// whose high word carries the X-button index for WM_XBUTTONDOWN (and the
/// MSLLHOOKSTRUCT.mouseData field in the LL hook).
pub fn classify(msg: u32, mouse_data: u32) Config.MouseBinding {
    if (msg == @as(u32, @intCast(w.WM_LBUTTONDOWN))) return .{ .kind = .left, .code = 0 };
    if (msg == @as(u32, @intCast(w.WM_RBUTTONDOWN))) return .{ .kind = .right, .code = 1 };
    if (msg == @as(u32, @intCast(w.WM_MBUTTONDOWN))) return .{ .kind = .middle, .code = 2 };
    if (msg == @as(u32, @intCast(w.WM_XBUTTONDOWN))) {
        const xb: u32 = (mouse_data >> 16) & 0xFFFF;
        return switch (xb) {
            1 => .{ .kind = .x1, .code = 1 },
            2 => .{ .kind = .x2, .code = 2 },
            else => .{ .kind = .other, .code = xb },
        };
    }
    return .{ .kind = .none };
}

pub fn matches(cfg: Config.MouseBinding, ev: Config.MouseBinding) bool {
    if (cfg.kind == .none or ev.kind == .none) return false;
    if (cfg.kind != ev.kind) return false;
    if (cfg.kind == .other) return cfg.code == ev.code;
    return true;
}
