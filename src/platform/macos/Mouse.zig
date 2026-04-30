// Translates raw bridge mouse events (kind, x, y) to the platform-agnostic
// MouseAction union defined in common/InputAction.zig.

const input = @import("../../common/InputAction.zig");

const Self = @This();

pub const Action = input.MouseAction;
pub const Callbacks = input.MouseCallbacks;

callbacks: Callbacks,

pub fn init(callbacks: Callbacks) Self {
    return .{ .callbacks = callbacks };
}

pub fn handle(self: *Self, kind: c_int, x: f64, y: f64) void {
    const ix: i32 = @intFromFloat(x);
    const iy: i32 = @intFromFloat(y);
    switch (kind) {
        0 => self.callbacks.on_action(self.callbacks.ctx, .{ .move = .{ .x = ix, .y = iy } }),
        1 => self.callbacks.on_action(self.callbacks.ctx, .{ .click = .{ .x = ix, .y = iy } }),
        else => {},
    }
}

pub fn synthesize(self: *Self, action: Action) void {
    self.callbacks.on_action(self.callbacks.ctx, action);
}
