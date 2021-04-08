const w = @import("windows.zig");
const std = @import("std");
pub const ComError = error{FailedToCreateComObject};

pub const REFIID = ?*const w.IID;
pub const REFGUID = ?*const w.GUID;

pub fn IUnknown(comptime Self: type) type {
    return struct {
        pub fn AddRef(self: Self) w.ULONG {
            return self.i.lpVtbl.*.AddRef.?(self.i);
        }
        pub fn Release(self: Self) w.ULONG {
            return self.i.lpVtbl.*.Release.?(self.i);
        }
        pub fn QueryService(self: Self, guidService: REFGUID, riid: REFIID, ppvObject: [*c]?*c_void) w.HRESULT {
            return self.i.lpVtbl.*.QueryService.?(self.i, guidService, riid, ppvObject);
        }
    };
}

pub fn ComInterface(comptime Self: type, comptime iid: w.IID, comptime clsid: w.CLSID, comptime Vtbl: type, comptime Interface: type) type {
    return struct {
        pub usingnamespace IUnknown(Self);

        pub fn create() !Self {
            var interface: *Interface = undefined;

            var hr = w.CoCreateInstance(&clsid, null, w.CLSCTX_ALL, &iid, @intToPtr([*c]?*c_void, @ptrToInt(&interface)));
            if (hr == 0) {
                return Self{
                    .i = interface
                };
            } else {
                return ComError.FailedToCreateComObject;
            }
        }
    };
}