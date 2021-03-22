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
        std.debug.warn("Window \"{s}\", shouldShow: {any}, desktop {}\n", .{ toUtf8(window.title, allocator), window.shouldShow, window.desktopNumber });
    }

    try main_window.setDesktopWindows(windows);
}
