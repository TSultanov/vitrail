const wh = @import("../windows.zig");
const w = wh.c;
const std = @import("std");
const com = @import("com.zig");

pub const ObjectArrayError = error{ InvalidType, Unknown };

pub const IObjectArrayVtbl = extern struct {
    QueryInterface: *const fn (This: [*c]IObjectArray, riid: com.REFIID, ppvObject: [*c]?*anyopaque) callconv(.c) w.HRESULT,
    AddRef: *const fn (This: [*c]IObjectArray) callconv(.c) w.ULONG,
    Release: *const fn (This: [*c]IObjectArray) callconv(.c) w.ULONG,
    GetCount: *const fn (This: [*c]IObjectArray, pcObjects: [*c]w.UINT) callconv(.c) w.HRESULT,
    GetAt: *const fn (This: [*c]IObjectArray, uiIndex: w.UINT, riid: com.REFIID, ppv: [*c]?*anyopaque) callconv(.c) w.HRESULT,
};

pub const IObjectArray = extern struct {
    lpVtbl: [*c]IObjectArrayVtbl,

    pub fn QueryInterface(self: *IObjectArray, riid: com.REFIID, ppvObject: [*c]?*anyopaque) w.HRESULT {
        return self.lpVtbl.*.QueryInterface(self, riid, ppvObject);
    }
    pub fn AddRef(self: *IObjectArray) w.ULONG {
        return self.lpVtbl.*.AddRef(self);
    }
    pub fn Release(self: *IObjectArray) w.ULONG {
        return self.lpVtbl.*.Release(self);
    }
    pub fn GetCount(self: *IObjectArray, pcObjects: [*c]w.UINT) w.HRESULT {
        return self.lpVtbl.*.GetCount(self, pcObjects);
    }
    pub fn GetAtGeneric(self: *IObjectArray, uiIndex: usize, comptime T: type) !*T {
        const iid_default = std.meta.fieldInfo(T, .iid).defaultValue() orelse return ObjectArrayError.InvalidType;
        var iid = iid_default;

        var object: ?*anyopaque = undefined;
        const hr = self.lpVtbl.*.GetAt(self, @intCast(uiIndex), &iid, &object);

        if (hr == 0) {
            return @ptrCast(@alignCast(object.?));
        } else {
            return ObjectArrayError.Unknown;
        }
    }

    pub fn GetAtWithIID(self: *IObjectArray, uiIndex: usize, iid: *const w.IID, comptime T: type) struct { hr: w.HRESULT, ptr: ?*T } {
        var object: ?*anyopaque = undefined;
        const hr = self.lpVtbl.*.GetAt(self, @intCast(uiIndex), iid, &object);
        if (hr == 0) {
            return .{ .hr = hr, .ptr = @ptrCast(@alignCast(object.?)) };
        }
        return .{ .hr = hr, .ptr = null };
    }
};
