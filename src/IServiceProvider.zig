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

i: *w.IServiceProvider,

pub usingnamespace com.ComInterface(Self, IID_IServiceProvider, CLSID_ImmersiveShell, w.IServiceProviderVtbl, w.IServiceProvider);


pub fn QueryService(self: Self, guidService: com.REFGUID, riid: com.REFIID, ppvObject: [*c]?*c_void) w.HRESULT {
    return self.i.lpVtbl.*.QueryService.?(self.i, guidService, riid, ppvObject);
}