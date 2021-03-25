usingnamespace @import("vitrail.zig");
const com = @import("ComInterface.zig");
const MainWindow = @import("MainWindow.zig");
const Button = @import("Button.zig");
const SystemInteraction = @import("SystemInteraction.zig");

const Self = @This();

window: *MainWindow,

pub fn init(hInstance: w.HINSTANCE, allocator: *std.mem.Allocator) !Self {
    var main_window = try MainWindow.create(hInstance, allocator);

    try createWidgets(main_window, hInstance, allocator);

    _ = main_window.window.show();
    return Self{
        .window = main_window,
    };
}

pub fn createWidgets(main_window: *MainWindow, hInstance: w.HINSTANCE, allocator: *std.mem.Allocator) !void {
    var si = SystemInteraction.init(hInstance, allocator);

    var windows = try si.getWindowList();

    for (windows) |window| {
        var titleUtf8 = try toUtf8(window.title, allocator);
        defer allocator.free(titleUtf8);
        var classUtf8 = try toUtf8(window.class, allocator);
        defer allocator.free(classUtf8);

        var executableNameUtf8: []u8 = if(window.executableName) |en| try toUtf8(en, allocator) else "";

        std.debug.warn("Window \"{s}\", class: \"{s}\", executableName: \"{s}\", desktop {}\n", .{ titleUtf8, classUtf8, executableNameUtf8, window.desktopNumber });
    }

    try main_window.setDesktopWindows(windows);
}
