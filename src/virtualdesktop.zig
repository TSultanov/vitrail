const w = @import("win32").c;

const ComError = error {
    FailedToCreateComObject
};

//pub const CLXCTX = enum {
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
//};

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
};

const IIVirtualDesktopManager = struct {
    virtualDesktopManager: IVirtualDesktopManager,

    pub fn QueryInterface(self: *IIVirtualDesktopManager, riid: REFIID, ppvObject: [*c][*c]c_void) w.HRESULT {
        return self.virtualDesktopManager.lpVtbl.*.QueryInterface(&self.virtualDesktopManager, riid, ppvObject);
    }
    pub fn AddRef(self: *IIVirtualDesktopManager) w.ULONG {
        return self.virtualDesktopManager.lpVtbl.*.AddRef(&self.virtualDesktopManager);
    }
    pub fn Release(self: *IIVirtualDesktopManager) w.ULONG {
        return self.virtualDesktopManager.lpVtbl.*.Release(&self.virtualDesktopManager);
    }
    pub fn IsWindowOnCurrentVirtualDesktop(self: *IIVirtualDesktopManager, topLevelWindow: w.HWND, onCurrentDesktop: [*c]BOOL) w.HRESULT {
        return self.virtualDesktopManager.lpVtbl.*.IsWindowOnCurrentVirtualDesktop(&self.virtualDesktopManager, topLevelWindow, onCurrentDesktop);
    }
    pub fn GetWindowDesktopId(self: *IIVirtualDesktopManager, topLevelWindow: w.HWND, desktopId: [*c]w.GUID) w.HRESULT {
        return self.virtualDesktopManager.lpVtbl.*.GetWindowDesktopId(&self.virtualDesktopManager, topLevelWindow, desktopId);
    }
    pub fn MoveWindowToDesktop(self: *IIVirtualDesktopManager, topLevelWindow: w.HWND, desktopId: [*c]w.GUID) w.HRESULT {
        return self.virtualDesktopManager.lpVtbl.*.MoveWindowToDesktop(&self.virtualDesktopManager, topLevelWindow, desktopId);
    }
};

pub fn create() !IIVirtualDesktopManager {
    var virtualDesktopManager: IVirtualDesktopManager = undefined;
    var hr = w.CoCreateInstance(&CLSID_VirtualDesktopManager, null, CLSCTX_ALL, &IID_IVirtualDesktopManager, @intToPtr([*c]?*c_void, @ptrToInt(&virtualDesktopManager)));
    if (hr == 0) {
        return IIVirtualDesktopManager {
            .virtualDesktopManager = virtualDesktopManager
        };
    } else {
        return ComError.FailedToCreateComObject;
    }
}