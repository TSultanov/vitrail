usingnamespace @import("vitrail.zig");
pub const Window = @import("Window.zig");

const Self = @This();

window: *Window,
event_handlers: Window.EventHandlers,
button_event_handlers: *EventHandlers,

pub const EventHandlers = struct {
    onClick: fn (self: *EventHandlers, button: *Self) anyerror!void,
};

pub fn onClickHandler(event_handlers: *Window.EventHandlers, window: *Window) !void {
    const self = @fieldParentPtr(Self, "event_handlers", event_handlers);
    try self.button_event_handlers.onClick(self.button_event_handlers, self);
}

pub fn create(hInstance: w.HINSTANCE, parent: *Window, label: [:0]u16, eventHandlers: *EventHandlers, allocator: *std.mem.Allocator) !*Self {
    const windowConfig = Window.WindowParameters{ .title = label, .className = toUtf16const("BUTTON"), .width = 100, .height = 25, .style = w.WS_TABSTOP | w.WS_VISIBLE | w.WS_CHILD | w.BS_DEFPUSHBUTTON, .parent = parent, .register_class = false };

    var self = try allocator.create(Self);
    self.* = .{
        .window = undefined,
        .button_event_handlers = eventHandlers,
        .event_handlers = .{ .onClick = onClickHandler },
    };

    var window = try Window.create(windowConfig, &self.event_handlers, hInstance, allocator);
    self.window = window;

    return self;
}
