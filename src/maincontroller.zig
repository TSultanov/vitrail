usingnamespace @import("vitrail.zig");
const MainWindow = @import("mainwindow.zig");
//const Button = @import("button.zig").Button;

const virtualdesktopmanager = @import("virtualdesktopmanager.zig");
const virtualdesktopmanagerinternal = @import("virtualdesktopmanagerinternal.zig");
const immersiveshell = @import("immersiveshell.zig");
const IVirtualDesktop = virtualdesktopmanagerinternal.IVirtualDesktop;
const IObjectArray = @import("objectarray.zig").IObjectArray;

const system_interaction = @import("system_interaction.zig");


pub const MainController = struct {
    window: MainWindow,

    pub fn init(hInstance: w.HINSTANCE, allocator: *std.mem.Allocator) !MainController {
        var main_window = try MainWindow.create(hInstance, allocator);

        try createWidgets(main_window, hInstance, allocator);

        main_window.window.show();
        return @This() {
            .window = main_window,
        };
    }
    
    pub fn createWidgets(main_window: MainWindow, hInstance: w.HINSTANCE, allocator: *std.mem.Allocator) !void
    {
        var desktopManager = try virtualdesktopmanager.create();
        defer _ = desktopManager.Release();
        var serviceProvider = try immersiveshell.create();
        defer _ = serviceProvider.Release();
        var desktopManagerInternal = try virtualdesktopmanagerinternal.create(serviceProvider);
        defer _ = desktopManagerInternal.Release();

        var desktopsNullable: ?*IObjectArray = undefined;
        var desktopsHr = desktopManagerInternal.GetDesktops(&desktopsNullable);

        std.debug.warn("hr: {x}\n", .{desktopsHr});

        var desktops = desktopsNullable orelse unreachable;
        defer _ = desktops.Release();
        
        var dCount: c_uint = undefined;
        var countHr = desktops.GetCount(&dCount);
        std.debug.warn("Desktop count: {}, hr: {x}\n", .{dCount, countHr});

        var desktopsMap = std.hash_map.AutoHashMap(w.GUID, usize).init(allocator);

        var i: usize = 0;
        while(i < dCount)
        {
            std.debug.warn("Desktop {} desktops: {x}\n", .{i, @ptrToInt(&desktops)});
            var desktop = try desktops.GetAtGeneric(i, IVirtualDesktop);

            std.debug.warn("desktop: {x}", .{desktop});

            var desktopId: w.GUID = undefined;
            _ = desktop.GetID(&desktopId);
            try desktopsMap.put(desktopId, i);
            std.debug.warn("{}: {}\n", .{i, desktopId});
            i += 1;
        }

        var si = system_interaction.init(hInstance, allocator);

        var windows = try si.getWindowList();

        for(windows) |window| {
            var desktopId: w.GUID = undefined;
            _ = desktopManager.GetWindowDesktopId(window.hwnd, &desktopId);

            if(desktopId.Data1 != 0 and desktopId.Data2 != 0 and desktopId.Data3 != 0)
            {
                var desktopNumber = desktopsMap.get(desktopId);

                std.debug.warn("Window \"{s}\", shouldShow: {any}, desktop {}\n", .{toUtf8(window.title, allocator), window.shouldShow, desktopNumber});
            }
        }
    }
};
