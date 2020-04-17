const std = @import("std");
const w = @import("win32").c;
const com = @import("com.zig");

const CLSID_VirtualDesktopManager: w.CLSID = w.CLSID {
    .Data1 = 0xaa509086,
    .Data2 = 0x5ca9,
    .Data3 = 0x4c25,
    .Data4 = [8]u8 {0x8f, 0x95, 0x58, 0x9d, 0x3c, 0x07, 0xb4, 0x8a},
};

const IID_IVirtualDesktopManager: w.IID = w.IID {
    .Data1 = 0xa5cd92ff,
    .Data2 = 0x29be,
    .Data3 = 0x454c,
    .Data4 = [8]u8 {0x8d, 0x04, 0xd8, 0x28, 0x79, 0xfb, 0x3f, 0x1b},
};

const IID_IServiceProvider: w.IID = w.IID {
    .Data1 = 0x6D5140C1,
    .Data2 = 0x7436,
    .Data3 = 0x11CE,
    .Data4 = [8]u8 {0x80, 0x34, 0x00, 0xAA, 0x00, 0x60, 0x09, 0xFA},
};

const CLSID_VirtualDesktopAPI_Unknown = w.CLSID {
    .Data1 = 0xC5E0CDCA,
    .Data2 = 0x7B6E,
    .Data3 = 0x41B2,
    .Data4 = [8]u8 {0x9F, 0xC4, 0xD9, 0x39, 0x75, 0xCC, 0x46, 0x7B},
};

const IID_IVirtualDesktopManagerInternal = w.IID {
    .Data1 = 0xEF9F1A6C,
    .Data2 = 0xD3CC,
    .Data3 = 0x4358,
    .Data4 = [8]u8 {0xB7, 0x12, 0xF8, 0x4B, 0x63, 0x5B, 0xEB, 0xE7},
};

const IVirtualDesktopManagerVtbl = extern struct {
    QueryInterface: extern fn (This: [*c]IVirtualDesktopManager, riid: com.REFIID, ppvObject: [*c]?*c_void) callconv(.C) w.HRESULT,
    AddRef: extern fn (This: [*c]IVirtualDesktopManager) callconv(.C) w.ULONG,
    Release: extern fn (This: [*c]IVirtualDesktopManager) callconv(.C) w.ULONG,
    IsWindowOnCurrentVirtualDesktop: extern fn (This: [*c]IVirtualDesktopManager, topLevelWindow: w.HWND, onCurrentDesktop: [*c]w.BOOL) callconv(.C) w.HRESULT,
    GetWindowDesktopId: extern fn (This: [*c]IVirtualDesktopManager, topLevelWindow: w.HWND, desktopId: [*c]w.GUID) callconv(.C) w.HRESULT,
    MoveWindowToDesktop: extern fn (This: [*c]IVirtualDesktopManager, topLevelWindow: w.HWND, desktopId: [*c]w.GUID) callconv(.C) w.HRESULT,
};

const IVirtualDesktopManager = extern struct {
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
    pub fn IsWindowOnCurrentVirtualDesktop(self: *IVirtualDesktopManager, topLevelWindow: w.HWND, onCurrentDesktop: [*c]BOOL) w.HRESULT {
        return self.lpVtbl.*.IsWindowOnCurrentVirtualDesktop(self, topLevelWindow, onCurrentDesktop);
    }
    pub fn GetWindowDesktopId(self: *IVirtualDesktopManager, topLevelWindow: w.HWND, desktopId: [*c]w.GUID) w.HRESULT {
        return self.lpVtbl.*.GetWindowDesktopId(self, topLevelWindow, desktopId);
    }
    pub fn MoveWindowToDesktop(self: *IVirtualDesktopManager, topLevelWindow: w.HWND, desktopId: [*c]w.GUID) w.HRESULT {
        return self.lpVtbl.*.MoveWindowToDesktop(self, topLevelWindow, desktopId);
    }
};

const IApplicationView = @OpaqueType();

const IVirtualDesktopVtbl = extern struct {
    QueryInterface: extern fn (This: [*c]IVirtualDesktop, riid: com.REFIID, ppvObject: [*c]?*c_void) callconv(.C) w.HRESULT,
    AddRef: extern fn (This: [*c]IVirtualDesktop) callconv(.C) w.ULONG,
    Release: extern fn (This: [*c]IVirtualDesktop) callconv(.C) w.ULONG,
    IsViewVisible: extern fn (This: [*c]IVirtualDesktop, pView: [*c]IApplicationView, pfVisible: [*c]c_int) callconv(.C) w.HRESULT,
    GetID: extern fn (This: [*c]IVirtualDesktop, pGuid: [*c]w.GUID) callconv(.C) w.HRESULT,
};

const IVirtualDesktop = extern struct {
    lpVtbl: [*c]IVirtualDesktopVtbl,

    pub fn QueryInterface(self: *IVirtualDesktop, riid: com.REFIID, ppvObject: [*c][*c]c_void) w.HRESULT {
        return self.lpVtbl.*.QueryInterface(self, riid, ppvObject);
    }
    pub fn AddRef(self: *IVirtualDesktop) w.ULONG {
        return self.lpVtbl.*.AddRef(self);
    }
    pub fn Release(self: *IVirtualDesktop) w.ULONG {
        return self.lpVtbl.*.Release(self);
    }
    pub fn IsViewVisible(self: *IVirtualDesktop, pView: [*c]IApplicationView, pfVisible: [*c]c_int) w.HRESULT {
        return self.lpVtbl.*.IsViewVisible(self, pView, pfVisible);
    }
    pub fn GetID(self: *IVirtualDesktop, pGuid: [*c]w.GUID) w.HRESULT {
        return self.lpVtbl.*.GetID(self, pGuid);
    }
};

const AdjacentDesktop = enum {
    LeftDirection = 3,
    RightDirection = 4,
};

const IVirtualDesktopManagerInternalVtbl = extern struct {
    QueryInterface: extern fn (This: [*c]IVirtualDesktopManagerInternal, riid: com.REFIID, ppvObject: [*c]?*c_void) callconv(.C) w.HRESULT,
    AddRef: extern fn (This: [*c]IVirtualDesktopManagerInternal) callconv(.C) w.ULONG,
    Release: extern fn (This: [*c]IVirtualDesktopManagerInternal) callconv(.C) w.ULONG,
    GetCount: extern fn(This: [*c]IVirtualDesktopManagerInternal, pCount: [*c]c_int) callconv(.C) w.HRESULT,
    MoveViewDesktop: extern fn(This: [*c]IVirtualDesktopManagerInternal, pView: [*c]IApplicationView, pDesktop: [*c]IVirtualDesktop) callconv(.C) w.HRESULT,
    GetCurrentDesktop: extern fn(This: [*c]IVirtualDesktopManagerInternal, desktop: [*c][*c]IVirtualDesktop) callconv(.C) w.HRESULT,
    GetDesktops: extern fn(This: [*c]IVirtualDesktopManagerInternal, ppDesktops: [*c][*c]IVirtualDesktop) callconv(.C) w.HRESULT,
    GetAdjacentDesktop: extern fn(This: [*c]IVirtualDesktopManagerInternal, pDesktopReference: [*c]IVirtualDesktop, uDirection: AdjacentDesktop, ppAdjacentDesktop: [*c][*c]IVirtualDesktop) callconv(.C) w.HRESULT,
    SwitchDesktop: extern fn(This: [*c]IVirtualDesktopManagerInternal, pDesktop: [*c]IVirtualDesktop) callconv(.C) w.HRESULT,
    CreateDesktopW: extern fn(This: [*c]IVirtualDesktopManagerInternal, ppNewDesktop: [*c][*c]IVirtualDesktop) callconv(.C) w.HRESULT,
    RemoveDesktop: extern fn(This: [*c]IVirtualDesktopManagerInternal, pRemove: [*c]IVirtualDesktop, pFallbackDesktop: [*c]IVirtualDesktop) callconv(.C) w.HRESULT,
};

const IVirtualDesktopManagerInternal = extern struct {
    lpVtbl: [*c]IVirtualDesktopManagerInternalVtbl,

    pub fn QueryInterface(self: *IVirtualDesktopManagerInternal, riid: com.REFIID, ppvObject: [*c][*c]c_void) w.HRESULT {
        return self.lpVtbl.*.QueryInterface(self, riid, ppvObject);
    }
    pub fn AddRef(self: *IVirtualDesktopManagerInternal) w.ULONG {
        return self.lpVtbl.*.AddRef(self);
    }
    pub fn Release(self: *IVirtualDesktopManagerInternal) w.ULONG {
        return self.lpVtbl.*.Release(self);
    }
    pub fn GetCount(self: *IVirtualDesktopManagerInternal, pCount: [*c]c_int) w.HRESULT {
        return self.lpVtbl.*.GetCount(self, pCount);
    }
    pub fn MoveViewDesktop(self: *IVirtualDesktopManagerInternal, pView: [*c]IApplicationView, pDesktop: [*c]IVirtualDesktop) w.HRESULT {
        return self.lpVtbl.*.MoveViewDesktop(self, pView, pDesktop);
    }
    pub fn GetCurrentDesktop(self: *IVirtualDesktopManagerInternal, desktop: [*c][*c]IVirtualDesktop) w.HRESULT {
        return self.lpVtbl.*.GetCurrentDesktop(self, desktop);
    }
    pub fn GetDesktops(self: *IVirtualDesktopManagerInternal, ppDesktops: [*c][*c]IVirtualDesktop) w.HRESULT {
        return self.lpVtbl.*.GetDesktops(self, ppDesktops);
    }
    pub fn GetAdjacentDesktop(self: *IVirtualDesktopManagerInternal, pDesktopReference: [*c]IVirtualDesktop, uDirection: AdjacentDesktop, ppAdjacentDesktop: [*c][*c]IVirtualDesktop) w.HRESULT {
        return self.lpVtbl.*.GetAdjacentDesktop(self, pDesktopReference, uDirection, ppAdjacentDesktop);
    }
    pub fn SwitchDesktop(self: *IVirtualDesktopManagerInternal, pDesktop: [*c]IVirtualDesktop) w.HRESULT {
        return self.lpVtbl.*.SwitchDesktop(self, pDesktop);
    }
    pub fn CreateDesktopW(self: *IVirtualDesktopManagerInternal, ppNewDesktop: [*c][*c]IVirtualDesktop) w.HRESULT {
        return self.lpVtbl.*.CreateDesktopW(self, ppNewDesktop);
    }
    pub fn RemoveDesktop(self: *IVirtualDesktopManagerInternal, pRemove: [*c]IVirtualDesktop, pFallbackDesktop: [*c]IVirtualDesktop) w.HRESULT {
        return self.lpVtbl.*.RemoveDesktop(self, pRemove, pFallbackDesktop);
    }
};

pub fn create() !*IVirtualDesktopManager {
    var virtualDesktopManager: *IVirtualDesktopManager = undefined;
    var hr = w.CoCreateInstance(&CLSID_VirtualDesktopManager, null, com.CLSCTX_ALL, &IID_IVirtualDesktopManager, @intToPtr([*c]?*c_void, @ptrToInt(&virtualDesktopManager)));
    if (hr == 0) {
        return virtualDesktopManager;
    } else {
        return com.ComError.FailedToCreateComObject;
    }
}