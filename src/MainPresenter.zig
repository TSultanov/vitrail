usingnamespace @import("vitrail.zig");
const com = @import("ComInterface.zig");
const MainWindow = @import("MainWindow.zig");
const Button = @import("Button.zig");
const SystemInteraction = @import("SystemInteraction.zig");

const Self = @This();

allocator: *std.mem.Allocator,
//arena: std.heap.ArenaAllocator,
window: ?*MainWindow,
hInstance: w.HINSTANCE,
desktop_windows: ?std.ArrayList(SystemInteraction.DesktopWindow) = null,

window_callbacks: MainWindow.Callbacks = .{
    .activateWindow = activateWindow,
    .hide = destroyWidgets
},
si: SystemInteraction,

pub fn init(hInstance: w.HINSTANCE, allocator: *std.mem.Allocator) !*Self {
    var self = try allocator.create(Self);
    self.* = .{
        .allocator = allocator,
        //.arena = std.heap.ArenaAllocator.init(allocator),
        .window = null,
        .si = try SystemInteraction.init(),
        .hInstance = hInstance
    };

    var main_window = try MainWindow.create(self.hInstance, &self.window_callbacks, self.allocator);

    self.window = main_window;

    //try self.createWidgets();
    _ = main_window.window.show();
    main_window.window.activate();

    return self;
}

pub fn createWidgets(self: *Self) !void {
    if(self.window) |view| {
        try destroyWidgets(view);
        self.desktop_windows = try self.si.getWindowList(self.allocator);
        if(self.desktop_windows) |desktop_windows| {
            try view.setDesktopWindows(desktop_windows);
        }
    }
}

pub fn hideWidgets(self: *Self) !void {
    self.window.destroy();
}

fn activateWindow(main_window: *MainWindow, dw: SystemInteraction.DesktopWindow) !void {
    const self = @fieldParentPtr(Self, "window_callbacks", main_window.callbacks);

    var titleUtf8 = try toUtf8(dw.title, self.allocator);
    defer self.allocator.free(titleUtf8);
    std.debug.warn("Switching to {s}\n", .{titleUtf8});
}

fn destroyWidgets(main_window: *MainWindow) !void {
    const self = @fieldParentPtr(Self, "window_callbacks", main_window.callbacks);

    //main_window.window.destroy();
    if(self.window) |window| {
        try window.hideBoxes();

        if(self.desktop_windows) |desktop_windows| {
            for(desktop_windows.items) |desktop_window| {
                try desktop_window.destroy();
            }

            desktop_windows.deinit();
            self.desktop_windows = null;
        }

        //self.arena.deinit();
        //self.arena = std.heap.ArenaAllocator.init(self.allocator);
        // self.allocator.destroy(window);
        // self.window = null;
    }
    //_ = w.PostQuitMessage(0);
}

pub fn show(self: *Self) !void {
    try self.createWidgets();
    // if(self.window == null) {
    //     var main_window = try MainWindow.create(self.hInstance, &self.window_callbacks, self.allocator);

    //     self.window = main_window;

    //     try self.createWidgets();
    //     _ = main_window.window.show();
    //     main_window.window.activate();
    // }
}
