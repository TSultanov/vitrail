const std = @import("std");
const w = @import("win32").c;
const com = @import("com.zig");
const IServiceProvider = @import("immersiveshell.zig").IServiceProvider;

//{F31574D6-B682-4CDC-BD56-1827860ABEC6}
const IID_IVirtualDesktopManagerInternal = w.IID {
    .Data1 = 0xF31574D6,
    .Data2 = 0xB682,
    .Data3 = 0x4CDC,
    .Data4 = [8]u8 {0xBD, 0x56, 0x18, 0x27, 0x86, 0x0A, 0xBE, 0xC6},
};

const CLSID_VirtualDesktopAPI_Unknown = w.CLSID {
    .Data1 = 0xC5E0CDCA,
    .Data2 = 0x7B6E,
    .Data3 = 0x41B2,
    .Data4 = [8]u8 {0x9F, 0xC4, 0xD9, 0x39, 0x75, 0xCC, 0x46, 0x7B},
};

const IApplicationView = extern struct {
    unused: u8,
};

const IVirtualDesktopVtbl = extern struct {
    QueryInterface: extern fn (This: [*c]IVirtualDesktop, riid: com.REFIID, ppvObject: [*c]?*c_void) callconv(.C) w.HRESULT,
    AddRef: extern fn (This: [*c]IVirtualDesktop) callconv(.C) w.ULONG,
    Release: extern fn (This: [*c]IVirtualDesktop) callconv(.C) w.ULONG,
    IsViewVisible: extern fn (This: [*c]IVirtualDesktop, pView: [*c]IApplicationView, pfVisible: [*c]c_int) callconv(.C) w.HRESULT,
    GetID: extern fn (This: [*c]IVirtualDesktop, pGuid: [*c]w.GUID) callconv(.C) w.HRESULT,
};

pub const IVirtualDesktop = extern struct {
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

const AdjacentDesktop = enum(c_int) {
    LeftDirection = 3,
    RightDirection = 4,
};

pub fn create(serviceProvider: *IServiceProvider) !*IVirtualDesktopManagerInternal {
    var virtualDesktopManagerInternal: *IVirtualDesktopManagerInternal = undefined;
    var hr = serviceProvider.QueryService(&CLSID_VirtualDesktopAPI_Unknown, &IID_IVirtualDesktopManagerInternal, @intToPtr([*c]?*c_void, @ptrToInt(&virtualDesktopManagerInternal)));
    if (hr == 0) {
        return virtualDesktopManagerInternal;
    } else {
        std.debug.warn("virtualDesktopManagerInternal hr: {x}\n", .{@bitCast(u32, hr)});
        return com.ComError.FailedToCreateComObject;
    }
}