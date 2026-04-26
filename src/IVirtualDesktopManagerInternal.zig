const wh = @import("windows.zig");
const w = wh.c;
const std = @import("std");
const com = @import("com.zig");
const IServiceProvider = @import("IServiceProvider.zig");
const IObjectArray = @import("IObjectArray.zig").IObjectArray;

// Microsoft rotates this IID across Windows 11 builds; probe each at runtime.
const IID_CANDIDATES = [_]struct { name: []const u8, iid: w.IID }{
    .{
        .name = "F31574D6-B682-4CDC-BD56-1827860ABEC6 (Win10/early Win11)",
        .iid = w.IID{ .Data1 = 0xF31574D6, .Data2 = 0xB682, .Data3 = 0x4CDC, .Data4 = [8]u8{ 0xBD, 0x56, 0x18, 0x27, 0x86, 0x0A, 0xBE, 0xC6 } },
    },
    .{
        .name = "B2F925B9-5A0F-4D2E-9F4D-2B1507593C10 (Win11 22621)",
        .iid = w.IID{ .Data1 = 0xB2F925B9, .Data2 = 0x5A0F, .Data3 = 0x4D2E, .Data4 = [8]u8{ 0x9F, 0x4D, 0x2B, 0x15, 0x07, 0x59, 0x3C, 0x10 } },
    },
    .{
        .name = "A3175F2D-239C-4BD2-8AA0-EEBA8B0B138E (Win11 23H2/24H2)",
        .iid = w.IID{ .Data1 = 0xA3175F2D, .Data2 = 0x239C, .Data3 = 0x4BD2, .Data4 = [8]u8{ 0x8A, 0xA0, 0xEE, 0xBA, 0x8B, 0x0B, 0x13, 0x8E } },
    },
    .{
        .name = "4970BA3D-FD4E-4647-BEA3-D89076EF4B9C (Win11 24H2 26100)",
        .iid = w.IID{ .Data1 = 0x4970BA3D, .Data2 = 0xFD4E, .Data3 = 0x4647, .Data4 = [8]u8{ 0xBE, 0xA3, 0xD8, 0x90, 0x76, 0xEF, 0x4B, 0x9C } },
    },
    .{
        .name = "53F5CA0B-158F-4124-900C-057E60B1A6F1 (Win11 Insider)",
        .iid = w.IID{ .Data1 = 0x53F5CA0B, .Data2 = 0x158F, .Data3 = 0x4124, .Data4 = [8]u8{ 0x90, 0x0C, 0x05, 0x7E, 0x60, 0xB1, 0xA6, 0xF1 } },
    },
};

const CLSID_VirtualDesktopAPI_Unknown = w.CLSID{
    .Data1 = 0xC5E0CDCA,
    .Data2 = 0x7B6E,
    .Data3 = 0x41B2,
    .Data4 = [8]u8{ 0x9F, 0xC4, 0xD9, 0x39, 0x75, 0xCC, 0x46, 0x7B },
};

//{FF72FFDD-BE7E-43FC-9C03-AD81681E88E4}
const IID_IVirtualDesktop = w.IID{
    .Data1 = 0xFF72FFDD,
    .Data2 = 0xBE7E,
    .Data3 = 0x43FC,
    .Data4 = [8]u8{ 0x9C, 0x03, 0xAD, 0x81, 0x68, 0x1E, 0x88, 0xE4 },
};

pub const IVD_IID_CANDIDATES = [_]struct { name: []const u8, iid: w.IID }{
    .{
        .name = "FF72FFDD-BE7E-43FC-9C03-AD81681E88E4 (Win10)",
        .iid = w.IID{ .Data1 = 0xFF72FFDD, .Data2 = 0xBE7E, .Data3 = 0x43FC, .Data4 = [8]u8{ 0x9C, 0x03, 0xAD, 0x81, 0x68, 0x1E, 0x88, 0xE4 } },
    },
    .{
        .name = "62FDF88B-11CA-4AFB-8BD8-2296DFAE49E2 (Win11 22000)",
        .iid = w.IID{ .Data1 = 0x62FDF88B, .Data2 = 0x11CA, .Data3 = 0x4AFB, .Data4 = [8]u8{ 0x8B, 0xD8, 0x22, 0x96, 0xDF, 0xAE, 0x49, 0xE2 } },
    },
    .{
        .name = "536D3495-B208-4CC9-AE26-DE8111275BF8 (Win11 22621)",
        .iid = w.IID{ .Data1 = 0x536D3495, .Data2 = 0xB208, .Data3 = 0x4CC9, .Data4 = [8]u8{ 0xAE, 0x26, 0xDE, 0x81, 0x11, 0x27, 0x5B, 0xF8 } },
    },
    .{
        .name = "3F07F4BE-B107-441A-AF0F-39D82529072C (Win11 23H2)",
        .iid = w.IID{ .Data1 = 0x3F07F4BE, .Data2 = 0xB107, .Data3 = 0x441A, .Data4 = [8]u8{ 0xAF, 0x0F, 0x39, 0xD8, 0x25, 0x29, 0x07, 0x2C } },
    },
    .{
        .name = "8AC9D33B-99A2-4D7B-A4D8-D7B7DDDC9E12 (Win11 24H2)",
        .iid = w.IID{ .Data1 = 0x8AC9D33B, .Data2 = 0x99A2, .Data3 = 0x4D7B, .Data4 = [8]u8{ 0xA4, 0xD8, 0xD7, 0xB7, 0xDD, 0xDC, 0x9E, 0x12 } },
    },
};

const IApplicationView = extern struct {
    unused: u8,
};

const IVirtualDesktopVtbl = extern struct {
    QueryInterface: *const fn (This: [*c]IVirtualDesktop, riid: com.REFIID, ppvObject: [*c]?*anyopaque) callconv(.c) w.HRESULT,
    AddRef: *const fn (This: [*c]IVirtualDesktop) callconv(.c) w.ULONG,
    Release: *const fn (This: [*c]IVirtualDesktop) callconv(.c) w.ULONG,
    IsViewVisible: *const fn (This: [*c]IVirtualDesktop, pView: [*c]IApplicationView, pfVisible: [*c]c_int) callconv(.c) w.HRESULT,
    GetID: *const fn (This: [*c]IVirtualDesktop, pGuid: [*c]w.GUID) callconv(.c) w.HRESULT,
};

pub const IVirtualDesktop = extern struct {
    lpVtbl: [*c]IVirtualDesktopVtbl,
    iid: w.IID = IID_IVirtualDesktop,

    pub fn QueryInterface(self: *IVirtualDesktop, riid: com.REFIID, ppvObject: [*c]?*anyopaque) w.HRESULT {
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
    QueryInterface: *const fn (This: [*c]IVirtualDesktopManagerInternal, riid: com.REFIID, ppvObject: [*c]?*anyopaque) callconv(.c) w.HRESULT,
    AddRef: *const fn (This: [*c]IVirtualDesktopManagerInternal) callconv(.c) w.ULONG,
    Release: *const fn (This: [*c]IVirtualDesktopManagerInternal) callconv(.c) w.ULONG,
    GetCount: *const fn (This: [*c]IVirtualDesktopManagerInternal, pCount: [*c]c_int) callconv(.c) w.HRESULT,
    MoveViewDesktop: *const fn (This: [*c]IVirtualDesktopManagerInternal, pView: [*c]IApplicationView, pDesktop: [*c]IVirtualDesktop) callconv(.c) w.HRESULT,
    CanViewMoveDesktops: *const fn (This: [*c]IVirtualDesktopManagerInternal, pView: [*c]IApplicationView, pfCanViewMoveDesktops: [*c]c_int) callconv(.c) w.HRESULT,
    GetCurrentDesktop: *const fn (This: [*c]IVirtualDesktopManagerInternal, desktop: [*c][*c]IVirtualDesktop) callconv(.c) w.HRESULT,
    GetDesktops: *const fn (This: [*c]IVirtualDesktopManagerInternal, ppDesktops: [*c][*c]IObjectArray) callconv(.c) w.HRESULT,
    GetAdjacentDesktop: *const fn (This: [*c]IVirtualDesktopManagerInternal, pDesktopReference: [*c]IVirtualDesktop, uDirection: AdjacentDesktop, ppAdjacentDesktop: [*c][*c]IVirtualDesktop) callconv(.c) w.HRESULT,
    SwitchDesktop: *const fn (This: [*c]IVirtualDesktopManagerInternal, pDesktop: [*c]IVirtualDesktop) callconv(.c) w.HRESULT,
    CreateDesktopW: *const fn (This: [*c]IVirtualDesktopManagerInternal, ppNewDesktop: [*c][*c]IVirtualDesktop) callconv(.c) w.HRESULT,
    RemoveDesktop: *const fn (This: [*c]IVirtualDesktopManagerInternal, pRemove: [*c]IVirtualDesktop, pFallbackDesktop: [*c]IVirtualDesktop) callconv(.c) w.HRESULT,
    FindDesktop: *const fn (This: [*c]IVirtualDesktopManagerInternal, desktopId: [*c]w.GUID, ppDesktop: [*c][*c]IVirtualDesktop) callconv(.c) w.HRESULT,
};

pub const IVirtualDesktopManagerInternal = extern struct {
    lpVtbl: [*c]IVirtualDesktopManagerInternalVtbl,

    pub fn QueryInterface(self: *IVirtualDesktopManagerInternal, riid: com.REFIID, ppvObject: [*c][*c]anyopaque) w.HRESULT {
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
    pub fn GetDesktops(self: *IVirtualDesktopManagerInternal, ppDesktops: [*c]?*IObjectArray) w.HRESULT {
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

    pub fn create(serviceProvider: *IServiceProvider) !*IVirtualDesktopManagerInternal {
        var virtualDesktopManagerInternal: *IVirtualDesktopManagerInternal = undefined;
        for (IID_CANDIDATES) |cand| {
            const hr = serviceProvider.QueryService(&CLSID_VirtualDesktopAPI_Unknown, &cand.iid, @ptrFromInt(@intFromPtr(&virtualDesktopManagerInternal)));
            if (hr == 0) return virtualDesktopManagerInternal;
        }
        return com.ComError.FailedToCreateComObject;
    }
};

const AdjacentDesktop = enum(c_int) {
    LeftDirection = 3,
    RightDirection = 4,
};
