const std = @import("std");
const w = = @cImport({
    @cInclude("windows.h");
});
const com = @import("com.zig");

pub const ObjectArrayError = error {
    InvalidType,
    Unknown
};

pub const IObjectArrayVtbl = extern struct {
    QueryInterface: extern fn (This: [*c]IObjectArray, riid: com.REFIID, ppvObject: [*c]?*c_void) callconv(.C) w.HRESULT,
    AddRef: extern fn (This: [*c]IObjectArray) callconv(.C) w.ULONG,
    Release: extern fn (This: [*c]IObjectArray) callconv(.C) w.ULONG,
    GetCount: extern fn (This: [*c]IObjectArray, pcObjects: [*c]w.UINT) callconv(.C) w.HRESULT,
    GetAt: extern fn (This: [*c]IObjectArray, uiIndex: w.UINT, riid: com.REFIID, ppv: [*c]?*c_void) callconv(.C) w.HRESULT,
};

pub const IObjectArray = extern struct {
    lpVtbl: [*c]IObjectArrayVtbl,
    
    pub fn QueryInterface(self: *IObjectArray, riid: com.REFIID, ppvObject: [*c]?*c_void) w.HRESULT {
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
        var iid = std.meta.fieldInfo(T, "iid").default_value orelse return ObjectArrayError.InvalidType;

        var object: ?*c_void = undefined;
        std.debug.warn("IObjectArray GetAtGeneric iid: {x}\n", .{@ptrToInt(&iid)});
        var hr = self.lpVtbl.*.GetAt(self, @intCast(w.UINT, uiIndex), &iid, &object);
        std.debug.warn("IObjectArray GetAtGeneric hr: {x}\n", .{@bitCast(u32, hr)});

        if(hr == 0) {
            return @ptrCast(*T, @alignCast(@alignOf(T), object.?));
        } else {
            std.debug.warn("IObjectArray GetAtGeneric hr: {x}\n", .{@bitCast(u32, hr)});
            return ObjectArrayError.Unknown;
        }
    }
};