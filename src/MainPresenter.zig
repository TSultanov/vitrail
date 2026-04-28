const std = @import("std");
const platform = @import("platform.zig");
const common = @import("common/DesktopWindow.zig");

const MainWindow = platform.MainWindow;
const SystemInteraction = platform.SystemInteraction;

const Self = @This();

allocator: std.mem.Allocator,
view: *MainWindow,
desktop_windows: ?std.array_list.Managed(common.DesktopWindow) = null,
test_mode: bool = false,

window_callbacks: MainWindow.Callbacks = .{
    .activateWindow = activateWindow,
    .hide = hide,
},
si: SystemInteraction,

pub fn init(args: platform.PlatformArgs, allocator: std.mem.Allocator, test_mode: bool) !*Self {
    var self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .view = undefined,
        .si = try SystemInteraction.init(allocator),
        .test_mode = test_mode,
    };

    self.view = try MainWindow.create(args, &self.window_callbacks, self.allocator);

    return self;
}

fn createWidgets(self: *Self) !void {
    self.view.activate();
    self.desktop_windows = try self.si.getWindowList(self.allocator);
    if (self.desktop_windows) |desktop_windows| {
        try self.view.setDesktopWindows(desktop_windows);
    }
}

fn activateWindow(main_window: *MainWindow, dw: common.DesktopWindow) !void {
    const self: *Self = @fieldParentPtr("window_callbacks", main_window.callbacks);
    self.si.activateWindow(dw);
    try hide(self.view);
}

fn hide(main_window: *MainWindow) !void {
    const self: *Self = @fieldParentPtr("window_callbacks", main_window.callbacks);

    try self.view.hideBoxes();

    if (self.desktop_windows) |desktop_windows| {
        for (desktop_windows.items) |desktop_window| {
            desktop_window.destroy();
        }
        desktop_windows.deinit();
        self.desktop_windows = null;
    }

    if (self.test_mode) {
        self.view.requestQuit();
    }
}

pub fn show(self: *Self) !void {
    try self.view.show();
    try self.createWidgets();
}
