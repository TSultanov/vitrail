const std = @import("std");
const MainPresenter = @import("../../MainPresenter.zig");
const HotKey = @import("HotKey.zig");
const MouseHook = @import("MouseHook.zig");
const SettingsWindow = @import("SettingsWindow.zig");
const Config = @import("../../common/Config.zig");

const App = struct {
    presenter: *MainPresenter,
    hotkey: HotKey,
    mouse_hook: MouseHook,
    settings: Config.Settings,
    allocator: std.mem.Allocator,
    settings_window: ?*SettingsWindow = null,

    /// Keyboard hotkey: summon the grid screen-centered (on the main display).
    fn onTrigger(ctx: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.presenter.show() catch |err| {
            std.log.warn("show failed: {s}", .{@errorName(err)});
        };
    }

    /// Mouse-button trigger: center under the pointer when the option is on,
    /// otherwise behave like the keyboard path.
    fn onMouseTrigger(ctx: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        const result = if (self.settings.center_on_cursor)
            self.presenter.showAtCursor()
        else
            self.presenter.show();
        result catch |err| {
            std.log.warn("show failed: {s}", .{@errorName(err)});
        };
    }

    /// The overlay asked to open settings (presenter already hid it).
    fn onOpenSettings(ctx: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (self.settings_window) |sw| {
            sw.show();
            return;
        }
        const sw = SettingsWindow.create(self.allocator, &self.settings, App.onApply, self) catch |err| {
            std.log.warn("settings window failed: {s}", .{@errorName(err)});
            return;
        };
        self.settings_window = sw;
        sw.show();
    }

    /// A binding changed in the settings UI: re-register the hotkey and persist.
    /// The mouse hook reads `settings.mouse` live, so it needs no update here.
    fn onApply(ctx: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.hotkey.rebind(HotKey.fromConfig(self.settings.keyboard)) catch |err| {
            std.log.warn("hotkey rebind failed: {s}", .{@errorName(err)});
        };
        Config.save(self.settings, self.allocator) catch |err| {
            std.log.warn("config save failed: {s}", .{@errorName(err)});
        };
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{ .safety = true }) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const test_mode = parseTestMode(allocator) catch false;

    const presenter = try MainPresenter.init(.{}, allocator, test_mode);
    defer presenter.deinit();

    // Load persisted settings; fall back to the built-in Option+Space hotkey
    // (and no mouse trigger) when there is no config yet.
    const fallback: Config.Settings = .{ .keyboard = HotKey.toConfig(HotKey.default_binding) };
    const settings = Config.loadOrDefault(allocator, fallback);

    var app: App = .{
        .presenter = presenter,
        .hotkey = undefined,
        .mouse_hook = undefined,
        .settings = settings,
        .allocator = allocator,
    };
    try app.hotkey.init(HotKey.fromConfig(app.settings.keyboard), App.onTrigger, &app);
    defer app.hotkey.deinit();

    // Global mouse-button trigger. Reads the live settings, so a button bound
    // later in the settings UI takes effect without reinstalling.
    app.mouse_hook.init(App.onMouseTrigger, &app, &app.settings.mouse, &app.settings.mouse_enabled);
    defer app.mouse_hook.deinit();
    defer if (app.settings_window) |sw| sw.destroy();

    // The overlay's Cmd+, routes here (via the presenter) to open settings.
    presenter.setOpenSettings(App.onOpenSettings, &app);

    while (presenter.view.running) {
        if (!presenter.view.dispatch()) break;
    }
}

fn parseTestMode(allocator: std.mem.Allocator) !bool {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--test-mode")) return true;
    }
    return false;
}
