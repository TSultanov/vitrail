// Translates raw bridge mouse events (kind, x, y) to the platform-agnostic
// Action union. Mirrors the Wayland Mouse.zig contract.

const Self = @This();

pub const Action = union(enum) {
    move: struct { x: i32, y: i32 },
    click: struct { x: i32, y: i32 },
};

pub const Callbacks = struct {
    on_action: *const fn (ctx: *anyopaque, action: Action) void,
    ctx: *anyopaque,
};

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
