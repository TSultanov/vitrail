const std = @import("std");
const builtin = @import("builtin");
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
    .openSettings = openSettings,
},
si: SystemInteraction,

// Set by the platform entry point: invoked (after the overlay is hidden) when
// the user asks to open settings from the overlay. The entry point owns the
// settings window + the hotkey/mouse-hook re-binding, which are platform-
// specific, so the presenter just forwards the request.
on_open_settings: ?*const fn (ctx: *anyopaque) void = null,
on_open_settings_ctx: *anyopaque = undefined,

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

/// Register the platform handler that actually presents the settings window.
pub fn setOpenSettings(self: *Self, cb: *const fn (ctx: *anyopaque) void, ctx: *anyopaque) void {
    self.on_open_settings = cb;
    self.on_open_settings_ctx = ctx;
}

fn openSettings(main_window: *MainWindow) !void {
    const self: *Self = @fieldParentPtr("window_callbacks", main_window.callbacks);
    // Dismiss the overlay first, then hand off to the platform entry point.
    try hide(self.view);
    if (self.on_open_settings) |cb| cb(self.on_open_settings_ctx);
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

    // On Wayland the launch-on-demand model means hide ⇒ exit (the
    // compositor's hotkey re-launches the binary). On Windows the binary
    // stays resident so the registered Alt+Space hotkey can re-show it,
    // unless test_mode forces an exit.
    if (builtin.target.os.tag == .linux or self.test_mode) {
        self.view.requestQuit();
    }
}

pub fn show(self: *Self) !void {
    try self.view.show();
    try self.createWidgets();
}

/// Like `show`, but positions the overlay on the pointer's display and centers
/// the grid under the cursor. Used by the mouse-button trigger when the
/// `center_on_cursor` option is enabled.
pub fn showAtCursor(self: *Self) !void {
    try self.view.showAtCursor();
    try self.createWidgets();
}

pub fn deinit(self: *Self) void {
    if (self.desktop_windows) |dws| {
        for (dws.items) |dw| dw.destroy();
        var owned = dws;
        owned.deinit();
        self.desktop_windows = null;
    }
    self.si.deinit();
    self.view.deinit();
    self.allocator.destroy(self);
}
