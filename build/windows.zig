const std = @import("std");
const builtin = @import("builtin");

pub const WINAPI: std.builtin.CallingConvention = if (builtin.target.cpu.arch == .i386)
    .Stdcall
else
    .C;

pub const HKEY__ = opaque {};
pub const HKEY = *HKEY__;
pub const PVOID = *c_void;
pub const WCHAR = u16;
pub const LPCWSTR = ?[*:0]const WCHAR;
pub const DWORD = u32;
pub const LPDWORD = ?*DWORD;
pub const LONG = i32;
pub const LSTATUS = LONG;
pub const LPWSTR = ?[*:0]WCHAR;
pub const ACCESS_MASK = DWORD;
pub const REGSAM = ACCESS_MASK;

pub const FILETIME = extern struct {
    dwLowDateTime: DWORD,
    dwHighDateTime: DWORD,
};

pub const PFILETIME = ?*FILETIME;

pub const WinError = error {
    RegQueryError,
    RegEnumError
};

extern "advapi32" fn RegGetValueW(
    hKey: HKEY,
    lpSubKey: LPCWSTR,
    lpValue: LPCWSTR,
    dwFlags: DWORD,
    pdwType: LPDWORD,
    pvData: PVOID,
    pcbData: LPDWORD
) callconv(WINAPI) LSTATUS;

pub extern "advapi32" fn RegOpenKeyExW(
    hKey: HKEY,
    lpSubKey: LPCWSTR,
    ulOptions: DWORD,
    samDesired: REGSAM,
    phkResult: *HKEY,
) callconv(WINAPI) LSTATUS;

pub extern "advapi32" fn RegEnumKeyExW(
    hKey: HKEY,
    dwIndex: DWORD,
    lpName: LPWSTR,
    lpcchName: LPDWORD,
    lpReserved: LPDWORD,
    lpClass: LPWSTR,
    lpcchClass: LPDWORD,
    lpftLastWriteTime: PFILETIME 
) callconv(WINAPI) LSTATUS;

pub extern "advapi32" fn RegCloseKey(
    hKey: HKEY
) callconv(WINAPI) LSTATUS;

pub const HKEY_LOCAL_MACHINE: HKEY = @intToPtr(HKEY, 0x80000002);
const RRF_RT_REG_SZ: DWORD = 0x00000002;
const KEY_READ: REGSAM = 0x20019;

const ERROR_MORE_DATA: LSTATUS = 234;
const ERROR_NO_MORE_ITEMS: LSTATUS = 259;
const ERROR_SUCCESS: LSTATUS = 0;

pub fn getRegSzValue(allocator: *std.mem.Allocator, hive: HKEY, subKey: []const u8, value: []const u8) ![:0]const u8 {
    const subKeyUtf16 = try std.unicode.utf8ToUtf16LeWithNull(allocator, subKey);
    defer allocator.free(subKeyUtf16);

    const valueUtf16 = try std.unicode.utf8ToUtf16LeWithNull(allocator, value);
    defer allocator.free(valueUtf16);

    var cbData: DWORD = 4096;
    const data = try allocator.allocSentinel(u16, cbData / 2, 0);
    std.mem.set(u16, data, 0);
    defer allocator.free(data);

    var errorCode = RegGetValueW(hive, subKeyUtf16, valueUtf16, RRF_RT_REG_SZ, null, @ptrCast(*c_void, data), &cbData);
    if(errorCode != 0) {
        return WinError.RegQueryError;
    }

    const dataUtf8 = try std.unicode.utf16leToUtf8AllocZ(allocator, data[0..(cbData/2-1)]);

    return dataUtf8;
}

pub fn regEnumKeys(allocator: *std.mem.Allocator, hive: HKEY, subKey: []const u8) !std.ArrayList([:0]u8) {
    const subKeyUtf16 = try std.unicode.utf8ToUtf16LeWithNull(allocator, subKey);
    defer allocator.free(subKeyUtf16);

    var key: HKEY = undefined;

    const openError = RegOpenKeyExW(hive, subKeyUtf16, 0, KEY_READ, &key);
    if(openError != 0) {
        return WinError.RegQueryError;
    }
    defer _ = RegCloseKey(key);

    var keys = std.ArrayList([:0]u8).init(allocator);

    var i: DWORD = 0;
    while(true) : (i += 1) {
        var cchName: DWORD = 4096;
        const name = try allocator.allocSentinel(u16, cchName, 0);
        std.mem.set(u16, name, 0);
        defer allocator.free(name);

        const errorCode = RegEnumKeyExW(key, i, name, &cchName, null, null, null, null);
        if(errorCode == ERROR_MORE_DATA) {
            return error.RegEnumError; // TODO: implement buffer resizing
        }
        if(errorCode == ERROR_NO_MORE_ITEMS) {
            break;
        }

        const nameUtf8 = try std.unicode.utf16leToUtf8AllocZ(allocator, name[0..cchName]);
        try keys.append(nameUtf8);
    }

    return keys;
}