const std = @import("std");
const wh = @import("windows.zig");
const w = wh.c;
const com = @import("ComInterface.zig");
const MainWindow = @import("MainWindow.zig");
const SystemInteraction = @import("SystemInteraction.zig");

const Self = @This();

allocator: std.mem.Allocator,
view: *MainWindow,
hInstance: w.HINSTANCE,
desktop_windows: ?std.array_list.Managed(SystemInteraction.DesktopWindow) = null,
test_mode: bool = false,

window_callbacks: MainWindow.Callbacks = .{
    .activateWindow = activateWindow,
    .hide = hide,
},
si: SystemInteraction,

pub fn init(hInstance: w.HINSTANCE, allocator: std.mem.Allocator, test_mode: bool) !*Self {
    var self = try allocator.create(Self);
    self.* = .{
        .allocator = allocator,
        .view = undefined,
        .si = try SystemInteraction.init(),
        .hInstance = hInstance,
        .test_mode = test_mode,
    };

    const main_window = try MainWindow.create(self.hInstance, &self.window_callbacks, self.allocator);

    self.view = main_window;

    _ = main_window.window.show();

    return self;
}

fn createWidgets(self: *Self) !void {
    self.view.window.activate();
    _ = w.SetForegroundWindow(self.view.window.hwnd);
    self.desktop_windows = try self.si.getWindowList(self.allocator);
    if (self.desktop_windows) |desktop_windows| {
        try self.view.setDesktopWindows(desktop_windows);
    }
}

fn activateWindow(main_window: *MainWindow, dw: SystemInteraction.DesktopWindow) !void {
    const self: *Self = @fieldParentPtr("window_callbacks", main_window.callbacks);
    _ = w.SwitchToThisWindow(dw.hwnd, 1);
    try hide(self.view);
}

fn hide(main_window: *MainWindow) !void {
    const self: *Self = @fieldParentPtr("window_callbacks", main_window.callbacks);

    try self.view.hideBoxes();

    if (self.desktop_windows) |desktop_windows| {
        for (desktop_windows.items) |desktop_window| {
            try desktop_window.destroy();
        }

        desktop_windows.deinit();
        self.desktop_windows = null;
    }

    if (self.test_mode) {
        w.PostQuitMessage(0);
    }
}

pub fn show(self: *Self) !void {
    _ = self.view.window.show();
    try self.createWidgets();
}
