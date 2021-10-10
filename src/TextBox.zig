const std = @import("std");
const w = @import("windows.zig");
const sys = @import("SystemInteraction.zig");
pub const Window = @import("Window.zig");

const Self = @This();

window: *Window,
event_handlers: Window.EventHandlers = .{
    .onAfterDestroy = onAfterDestroy
},

allocator: *std.mem.Allocator,

fn onAfterDestroy(event_handlers: *Window.EventHandlers, window: *Window) !void {
    var self = @fieldParentPtr(Self, "event_handlers", event_handlers);
    self.allocator.destroy(window);
}

pub fn create(hInstance: w.HINSTANCE, parent: *Window, allocator: *std.mem.Allocator) !*Self {
    const windowConfig = Window.WindowParameters {
        .title = null,
        .className = sys.toUtf16const("EDIT"),
        .width = 100, .height = 25,
        .style = w.WS_VISIBLE | w.WS_CHILD | w.ES_LEFT | w.WS_BORDER,
        .parent = parent,
        .register_class = false,
    };

    var self = try allocator.create(Self);
    self.* = .{
        .allocator = allocator,
        .window = undefined,
    };

    var window = try Window.create(windowConfig, &self.event_handlers, hInstance, allocator);
    self.window = window;

    _ = self.window.show();

    return self;
}

pub fn clearText(self: Self) !void {
    try self.window.setText(null);
}