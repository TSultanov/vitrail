const std = @import("std");
const wh = @import("windows.zig");
const w = wh.c;
const com = @import("com.zig");

const IID_IPropertyStore: w.IID = .{
    .Data1 = 0x886D8EEB,
    .Data2 = 0x8CF2,
    .Data3 = 0x4446,
    .Data4 = [8]u8{ 0x8D, 0x02, 0xCD, 0xBA, 0x1D, 0xBD, 0xCF, 0x99 },
};

const IID_IShellItem: w.IID = .{
    .Data1 = 0x43826D1E,
    .Data2 = 0xE718,
    .Data3 = 0x42EE,
    .Data4 = [8]u8{ 0xBC, 0x55, 0xA1, 0xE2, 0x61, 0xC3, 0x7B, 0xFE },
};

const IID_IShellItemImageFactory: w.IID = .{
    .Data1 = 0xBCC18B79,
    .Data2 = 0xBA16,
    .Data3 = 0x442F,
    .Data4 = [8]u8{ 0x80, 0xC4, 0x8A, 0x59, 0xC3, 0x0C, 0x46, 0x3B },
};

const PROPERTYKEY = extern struct {
    fmtid: w.GUID,
    pid: w.DWORD,
};

const PKEY_AppUserModel_ID: PROPERTYKEY = .{
    .fmtid = .{
        .Data1 = 0x9F4C2855,
        .Data2 = 0x9F79,
        .Data3 = 0x4B39,
        .Data4 = [8]u8{ 0xA8, 0xD0, 0xE1, 0xD4, 0x2D, 0xE1, 0xD5, 0xF3 },
    },
    .pid = 5,
};

const VT_LPWSTR: u16 = 31;

const SIIGBF_BIGGERSIZEOK: u32 = 0x01;
const SIIGBF_ICONONLY: u32 = 0x04;

const ICON_SIZE_PX: i32 = 256;

const PROPVARIANT = extern struct {
    vt: u16,
    wReserved1: u16 = 0,
    wReserved2: u16 = 0,
    wReserved3: u16 = 0,
    val: extern union {
        pwszVal: ?[*:0]u16,
        padding: [16]u8,
    },
};

const IPropertyStoreVtbl = extern struct {
    QueryInterface: *const fn (self: *IPropertyStore, riid: com.REFIID, ppvObject: [*c]?*anyopaque) callconv(.c) w.HRESULT,
    AddRef: *const fn (self: *IPropertyStore) callconv(.c) w.ULONG,
    Release: *const fn (self: *IPropertyStore) callconv(.c) w.ULONG,
    GetCount: *const fn (self: *IPropertyStore, cProps: *w.DWORD) callconv(.c) w.HRESULT,
    GetAt: *const fn (self: *IPropertyStore, iProp: w.DWORD, pkey: *PROPERTYKEY) callconv(.c) w.HRESULT,
    GetValue: *const fn (self: *IPropertyStore, key: *const PROPERTYKEY, pv: *PROPVARIANT) callconv(.c) w.HRESULT,
    SetValue: *const fn (self: *IPropertyStore, key: *const PROPERTYKEY, pv: *const PROPVARIANT) callconv(.c) w.HRESULT,
    Commit: *const fn (self: *IPropertyStore) callconv(.c) w.HRESULT,
};

const IPropertyStore = extern struct {
    lpVtbl: *IPropertyStoreVtbl,

    pub fn Release(self: *IPropertyStore) w.ULONG {
        return self.lpVtbl.Release(self);
    }
    pub fn GetValue(self: *IPropertyStore, key: *const PROPERTYKEY, pv: *PROPVARIANT) w.HRESULT {
        return self.lpVtbl.GetValue(self, key, pv);
    }
};

const IShellItemVtbl = extern struct {
    QueryInterface: *const fn (self: *IShellItem, riid: com.REFIID, ppvObject: [*c]?*anyopaque) callconv(.c) w.HRESULT,
    AddRef: *const fn (self: *IShellItem) callconv(.c) w.ULONG,
    Release: *const fn (self: *IShellItem) callconv(.c) w.ULONG,
    BindToHandler: *const fn (self: *IShellItem, pbc: ?*anyopaque, bhid: com.REFGUID, riid: com.REFIID, ppv: [*c]?*anyopaque) callconv(.c) w.HRESULT,
    GetParent: *const fn (self: *IShellItem, ppsi: [*c]?*IShellItem) callconv(.c) w.HRESULT,
    GetDisplayName: *const fn (self: *IShellItem, sigdnName: c_int, ppszName: [*c]?[*:0]u16) callconv(.c) w.HRESULT,
    GetAttributes: *const fn (self: *IShellItem, sfgaoMask: w.ULONG, psfgaoAttribs: *w.ULONG) callconv(.c) w.HRESULT,
    Compare: *const fn (self: *IShellItem, psi: *IShellItem, hint: w.DWORD, piOrder: *c_int) callconv(.c) w.HRESULT,
};

const IShellItem = extern struct {
    lpVtbl: *IShellItemVtbl,

    pub fn QueryInterface(self: *IShellItem, riid: com.REFIID, ppvObject: [*c]?*anyopaque) w.HRESULT {
        return self.lpVtbl.QueryInterface(self, riid, ppvObject);
    }
    pub fn Release(self: *IShellItem) w.ULONG {
        return self.lpVtbl.Release(self);
    }
};

const IShellItemImageFactoryVtbl = extern struct {
    QueryInterface: *const fn (self: *IShellItemImageFactory, riid: com.REFIID, ppvObject: [*c]?*anyopaque) callconv(.c) w.HRESULT,
    AddRef: *const fn (self: *IShellItemImageFactory) callconv(.c) w.ULONG,
    Release: *const fn (self: *IShellItemImageFactory) callconv(.c) w.ULONG,
    GetImage: *const fn (self: *IShellItemImageFactory, size: w.SIZE, flags: u32, phbm: *w.HBITMAP) callconv(.c) w.HRESULT,
};

const IShellItemImageFactory = extern struct {
    lpVtbl: *IShellItemImageFactoryVtbl,

    pub fn Release(self: *IShellItemImageFactory) w.ULONG {
        return self.lpVtbl.Release(self);
    }
    pub fn GetImage(self: *IShellItemImageFactory, size: w.SIZE, flags: u32, phbm: *w.HBITMAP) w.HRESULT {
        return self.lpVtbl.GetImage(self, size, flags, phbm);
    }
};

extern "shell32" fn SHGetPropertyStoreForWindow(
    hwnd: w.HWND,
    riid: com.REFIID,
    ppv: [*c]?*anyopaque,
) callconv(.c) w.HRESULT;

extern "shell32" fn SHCreateItemFromParsingName(
    pszPath: [*:0]const u16,
    pbc: ?*anyopaque,
    riid: com.REFIID,
    ppv: [*c]?*anyopaque,
) callconv(.c) w.HRESULT;

extern "ole32" fn PropVariantClear(pvar: *PROPVARIANT) callconv(.c) w.HRESULT;

fn getAumid(hwnd: w.HWND, buf: []u16) ?[:0]u16 {
    var store_raw: ?*anyopaque = null;
    const hr = SHGetPropertyStoreForWindow(hwnd, &IID_IPropertyStore, &store_raw);
    if (hr != 0 or store_raw == null) return null;
    const store: *IPropertyStore = @ptrCast(@alignCast(store_raw));
    defer _ = store.Release();

    var pv: PROPVARIANT = std.mem.zeroes(PROPVARIANT);
    const hr2 = store.GetValue(&PKEY_AppUserModel_ID, &pv);
    defer _ = PropVariantClear(&pv);
    if (hr2 != 0) return null;
    if (pv.vt != VT_LPWSTR) return null;
    const src = pv.val.pwszVal orelse return null;

    var i: usize = 0;
    while (src[i] != 0) : (i += 1) {
        if (i + 1 >= buf.len) return null;
        buf[i] = src[i];
    }
    buf[i] = 0;
    return buf[0..i :0];
}

fn getShellItemImageForAumid(aumid: [:0]const u16, size_px: i32) ?w.HBITMAP {
    const prefix = std.unicode.utf8ToUtf16LeStringLiteral("shell:AppsFolder\\");
    var path_buf: [512]u16 = undefined;
    if (prefix.len + aumid.len + 1 > path_buf.len) return null;
    @memcpy(path_buf[0..prefix.len], prefix);
    @memcpy(path_buf[prefix.len..][0..aumid.len], aumid);
    path_buf[prefix.len + aumid.len] = 0;
    const path: [*:0]const u16 = @ptrCast(&path_buf);

    var item_raw: ?*anyopaque = null;
    const hr = SHCreateItemFromParsingName(path, null, &IID_IShellItem, &item_raw);
    if (hr != 0 or item_raw == null) return null;
    const item: *IShellItem = @ptrCast(@alignCast(item_raw));
    defer _ = item.Release();

    var factory_raw: ?*anyopaque = null;
    const hr2 = item.QueryInterface(&IID_IShellItemImageFactory, &factory_raw);
    if (hr2 != 0 or factory_raw == null) return null;
    const factory: *IShellItemImageFactory = @ptrCast(@alignCast(factory_raw));
    defer _ = factory.Release();

    var hbmp: w.HBITMAP = null;
    const size: w.SIZE = .{ .cx = size_px, .cy = size_px };
    const hr3 = factory.GetImage(size, SIIGBF_BIGGERSIZEOK | SIIGBF_ICONONLY, &hbmp);
    if (hr3 != 0 or hbmp == null) return null;
    return hbmp;
}

fn hbitmapToHicon(hbmp: w.HBITMAP) ?w.HICON {
    var bm: w.BITMAP = undefined;
    const got = w.GetObjectW(hbmp, @sizeOf(w.BITMAP), &bm);
    if (got == 0) {
        _ = w.DeleteObject(hbmp);
        return null;
    }

    const mask = w.CreateBitmap(bm.bmWidth, bm.bmHeight, 1, 1, null);
    if (mask == null) {
        _ = w.DeleteObject(hbmp);
        return null;
    }

    var ii: w.ICONINFO = .{
        .fIcon = 1,
        .xHotspot = 0,
        .yHotspot = 0,
        .hbmMask = mask,
        .hbmColor = hbmp,
    };
    const icon = w.CreateIconIndirect(&ii);
    _ = w.DeleteObject(mask);
    _ = w.DeleteObject(hbmp);
    if (icon == null) return null;
    return icon;
}

pub fn tryGetUwpIcon(hwnd: w.HWND) ?w.HICON {
    var aumid_buf: [256]u16 = undefined;
    const aumid = getAumid(hwnd, &aumid_buf) orelse return null;
    const hbmp = getShellItemImageForAumid(aumid, ICON_SIZE_PX) orelse return null;
    return hbitmapToHicon(hbmp);
}
