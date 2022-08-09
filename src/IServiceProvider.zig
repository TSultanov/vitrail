const w = @import("windows.zig");
const std = @import("std");
const com = @import("com.zig");

const Self = @This();

const IID_IServiceProvider: w.IID = w.IID{
    .Data1 = 0x6D5140C1,
    .Data2 = 0x7436,
    .Data3 = 0x11CE,
    .Data4 = [8]u8{ 0x80, 0x34, 0x00, 0xAA, 0x00, 0x60, 0x09, 0xFA },
};

const CLSID_ImmersiveShell = w.CLSID{
    .Data1 = 0xC2F03A33,
    .Data2 = 0x21F5,
    .Data3 = 0x47FA,
    .Data4 = [8]u8{ 0xB4, 0xBB, 0x15, 0x63, 0x62, 0xA2, 0xF2, 0x39 },
};

const IServiceProviderVtbl = extern struct {
    QueryInterface: fn (self: *Self, riid: com.REFIID, ppvObject: [*c]?*anyopaque) callconv(.C) w.HRESULT,
    AddRef: fn (self: *Self) callconv(.C) w.ULONG,
    Release: fn (self: *Self) callconv(.C) w.ULONG,
    QueryService: fn (self: *Self, guidService: com.REFGUID, riid: com.REFIID, ppvObject: [*c]?*anyopaque) callconv(.C) w.HRESULT,
};

lpVtbl: *IServiceProviderVtbl,

pub fn QueryInterface(self: *Self, riid: com.REFIID, ppvObject: [*c][*c]anyopaque) w.HRESULT {
    return self.lpVtbl.QueryInterface(self, riid, ppvObject);
}
pub fn AddRef(self: *Self) w.ULONG {
    return self.lpVtbl.AddRef(self);
}
pub fn Release(self: *Self) w.ULONG {
    return self.lpVtbl.Release(self);
}
pub fn QueryService(self: *Self, guidService: com.REFGUID, riid: com.REFIID, ppvObject: [*c]?*anyopaque) w.HRESULT {
    return self.lpVtbl.QueryService(self, guidService, riid, ppvObject);
}

pub fn create() !*Self {
    var serviceProvider: *Self = undefined;

    var hr = w.CoCreateInstance(&CLSID_ImmersiveShell, null, w.CLSCTX_ALL, &IID_IServiceProvider, @intToPtr([*c]?*anyopaque, @ptrToInt(&serviceProvider)));
    if (hr == 0) {
        return serviceProvider;
    } else {
        return com.ComError.FailedToCreateComObject;
    }
}
