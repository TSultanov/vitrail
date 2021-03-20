usingnamespace @import("vitrail.zig");
const MainWindow = @import("mainwindow.zig").MainWindow;
const Button = @import("button.zig").Button;

const virtualdesktopmanager = @import("virtualdesktopmanager.zig");
const virtualdesktopmanagerinternal = @import("virtualdesktopmanagerinternal.zig");
const immersiveshell = @import("immersiveshell.zig");
const IVirtualDesktop = virtualdesktopmanagerinternal.IVirtualDesktop;
const IObjectArray = @import("objectarray.zig").IObjectArray;

pub const MainController = struct {
    window: *MainWindow,

    pub fn init(hInstance: w.HINSTANCE, allocator: *std.mem.Allocator) !MainController {
        var main_window = try MainWindow.create(hInstance, allocator);

        try createWidgets(main_window, hInstance, allocator);

        main_window.window.system_window.show();
        return @This() {
            .window = main_window,
        };
    }
    
    pub fn createWidgets(main_window: *MainWindow, hInstance: w.HINSTANCE, allocator: *std.mem.Allocator) !void
    {
        var desktopManager = try virtualdesktopmanager.create();
        var serviceProvider = try immersiveshell.create();
        var desktopManagerInternal = try virtualdesktopmanagerinternal.create(serviceProvider);

        var desktopsNullable: ?*IObjectArray = undefined;
        var desktopsHr = desktopManagerInternal.GetDesktops(&desktopsNullable);
        std.debug.warn("hr: {x}\n", .{desktopsHr});

        var desktops = desktopsNullable orelse unreachable;
        
        var dCount: c_uint = undefined;
        var countHr = desktops.GetCount(&dCount);
        std.debug.warn("Desktop count: {}, hr: {x}\n", .{dCount, countHr});

        var i: usize = 0;
        while(i < dCount)
        {
            std.debug.warn("Desktop {} desktops: {x}\n", .{i, @ptrToInt(&desktops)});
            var desktop = try desktops.GetAtGeneric(i, IVirtualDesktop);

            std.debug.warn("desktop: {x}", .{desktop});

            var desktopId: w.GUID = undefined;
            _ = desktop.GetID(&desktopId);
            std.debug.warn("{}: {}\n", .{i, desktopId});
            i += 1;
        }
    }
};
