const w = @import("windows.zig");
const std = @import("std");
const com = @import("com.zig");

const CLSID_VirtualDesktopManager: w.CLSID = w.CLSID{
    .Data1 = 0xaa509086,
    .Data2 = 0x5ca9,
    .Data3 = 0x4c25,
    .Data4 = [8]u8{ 0x8f, 0x95, 0x58, 0x9d, 0x3c, 0x07, 0xb4, 0x8a },
};

const IID_IVirtualDesktopManager: w.IID = w.IID{
    .Data1 = 0xa5cd92ff,
    .Data2 = 0x29be,
    .Data3 = 0x454c,
    .Data4 = [8]u8{ 0x8d, 0x04, 0xd8, 0x28, 0x79, 0xfb, 0x3f, 0x1b },
};

const IVirtualDesktopManagerVtbl = extern struct {
    QueryInterface: fn (This: [*c]IVirtualDesktopManager, riid: com.REFIID, ppvObject: [*c]?*c_void) callconv(.C) w.HRESULT,
    AddRef: fn (This: [*c]IVirtualDesktopManager) callconv(.C) w.ULONG,
    Release: fn (This: [*c]IVirtualDesktopManager) callconv(.C) w.ULONG,
    IsWindowOnCurrentVirtualDesktop: fn (This: [*c]IVirtualDesktopManager, topLevelWindow: w.HWND, onCurrentDesktop: [*c]w.BOOL) callconv(.C) w.HRESULT,
    GetWindowDesktopId: fn (This: [*c]IVirtualDesktopManager, topLevelWindow: w.HWND, desktopId: [*c]w.GUID) callconv(.C) w.HRESULT,
    MoveWindowToDesktop: fn (This: [*c]IVirtualDesktopManager, topLevelWindow: w.HWND, desktopId: [*c]w.GUID) callconv(.C) w.HRESULT,
};

pub const IVirtualDesktopManager = extern struct {
    lpVtbl: [*c]IVirtualDesktopManagerVtbl,

    pub fn QueryInterface(self: *IVirtualDesktopManager, riid: com.REFIID, ppvObject: [*c][*c]c_void) w.HRESULT {
        return self.lpVtbl.*.QueryInterface(self, riid, ppvObject);
    }
    pub fn AddRef(self: *IVirtualDesktopManager) w.ULONG {
        return self.lpVtbl.*.AddRef(self);
    }
    pub fn Release(self: *IVirtualDesktopManager) w.ULONG {
        return self.lpVtbl.*.Release(self);
    }
    pub fn IsWindowOnCurrentVirtualDesktop(self: *IVirtualDesktopManager, topLevelWindow: w.HWND, onCurrentDesktop: [*c]w.BOOL) w.HRESULT {
        return self.lpVtbl.*.IsWindowOnCurrentVirtualDesktop(self, topLevelWindow, onCurrentDesktop);
    }
    pub fn GetWindowDesktopId(self: *IVirtualDesktopManager, topLevelWindow: w.HWND, desktopId: [*c]w.GUID) w.HRESULT {
        return self.lpVtbl.*.GetWindowDesktopId(self, topLevelWindow, desktopId);
    }
    pub fn MoveWindowToDesktop(self: *IVirtualDesktopManager, topLevelWindow: w.HWND, desktopId: [*c]w.GUID) w.HRESULT {
        return self.lpVtbl.*.MoveWindowToDesktop(self, topLevelWindow, desktopId);
    }

    pub fn create() !*IVirtualDesktopManager {
        var virtualDesktopManager: *IVirtualDesktopManager = undefined;
        var hr = w.CoCreateInstance(&CLSID_VirtualDesktopManager, null, w.CLSCTX_ALL, &IID_IVirtualDesktopManager, @intToPtr([*c]?*c_void, @ptrToInt(&virtualDesktopManager)));
        if (hr == 0) {
            return virtualDesktopManager;
        } else {
            return com.ComError.FailedToCreateComObject;
        }
    }
};
