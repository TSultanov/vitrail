const std = @import("std");
const w = @import("win32").c;

const ComError = error {
    FailedToCreateComObject
};

const CLSCTX_INPROC_SERVER      = 0x1;
const CLSCTX_INPROC_HANDLER     = 0x2;
const CLSCTX_LOCAL_SERVER       = 0x4;
const CLSCTX_INPROC_SERVER16    = 0x8;
const CLSCTX_REMOTE_SERVER      = 0x10;
const CLSCTX_INPROC_HANDLER16       = 0x20;
const CLSCTX_RESERVED1          = 0x40;
const CLSCTX_RESERVED2          = 0x80;
const CLSCTX_RESERVED3          = 0x100;
const CLSCTX_RESERVED4          = 0x200;
const CLSCTX_NO_CODE_DOWNLOAD       = 0x400;
const CLSCTX_RESERVED5          = 0x800;
const CLSCTX_NO_CUSTOM_MARSHAL      = 0x1000;
const CLSCTX_ENABLE_CODE_DOWNLOAD   = 0x2000;
const CLSCTX_NO_FAILURE_LOG     = 0x4000;
const CLSCTX_DISABLE_AAA        = 0x8000;
const CLSCTX_ENABLE_AAA         = 0x10000;
const CLSCTX_FROM_DEFAULT_CONTEXT   = 0x20000;
const CLSCTX_ACTIVATE_32_BIT_SERVER = 0x40000;
const CLSCTX_ACTIVATE_64_BIT_SERVER = 0x80000;
const CLSCTX_INPROC         = CLSCTX_INPROC_SERVER|CLSCTX_INPROC_HANDLER;
const CLSCTX_SERVER         = CLSCTX_INPROC_SERVER|CLSCTX_LOCAL_SERVER|CLSCTX_REMOTE_SERVER;
const CLSCTX_ALL            = CLSCTX_SERVER|CLSCTX_INPROC_HANDLER;

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

const REFIID = [*c]const w.IID;

const IVirtualDesktopManagerVtbl = extern struct {
    QueryInterface: extern fn (This: [*c]IVirtualDesktopManager, riid: REFIID, ppvObject: [*c]?*c_void) callconv(.C) w.HRESULT,
    AddRef: extern fn (This: [*c]IVirtualDesktopManager) callconv(.C) w.ULONG,
    Release: extern fn (This: [*c]IVirtualDesktopManager) callconv(.C) w.ULONG,
    IsWindowOnCurrentVirtualDesktop: extern fn (This: [*c]IVirtualDesktopManager, topLevelWindow: w.HWND, onCurrentDesktop: [*c]w.BOOL) callconv(.C) w.HRESULT,
    GetWindowDesktopId: extern fn (This: [*c]IVirtualDesktopManager, topLevelWindow: w.HWND, desktopId: [*c]w.GUID) callconv(.C) w.HRESULT,
    MoveWindowToDesktop: extern fn (This: [*c]IVirtualDesktopManager, topLevelWindow: w.HWND, desktopId: [*c]w.GUID) callconv(.C) w.HRESULT,
};

const IVirtualDesktopManager = extern struct {
    lpVtbl: [*c]IVirtualDesktopManagerVtbl,
        
    pub fn QueryInterface(self: *IVirtualDesktopManager, riid: REFIID, ppvObject: [*c][*c]c_void) w.HRESULT {
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
    IsViewVisible: extern fn (This: [*c]IVirtualDesktop, pView: [*c]IApplicationView, pfVisible: [*c]c_int) callconv(.C) w.HRESULT,
    GetID: extern fn (This: [*c]IVirtualDesktop, pGuid: [*c]w.GUID) callconv(.C) w.HRESULT,
};

const IVirtualDesktop = extern struct {
    lpVtbl: [*c]IVirtualDesktopVtbl,

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
};

pub fn create() !*IVirtualDesktopManager {
    var virtualDesktopManager: *IVirtualDesktopManager = undefined;
    var hr = w.CoCreateInstance(&CLSID_VirtualDesktopManager, null, CLSCTX_ALL, &IID_IVirtualDesktopManager, @intToPtr([*c]?*c_void, @ptrToInt(&virtualDesktopManager)));
    if (hr == 0) {
        return virtualDesktopManager;
    } else {
        return ComError.FailedToCreateComObject;
    }
}