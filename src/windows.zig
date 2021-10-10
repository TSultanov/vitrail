const w = @cImport({
    @cDefine("WINVER", "0x0606");
    @cDefine("_UNICODE", "1");
    @cDefine("UNICODE", "1");
    @cDefine("_WIN64", "1");
    @cDefine("_AMD64_", "1");
    @cDefine("__LP64__", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
    @cUndef("NO_STRICT");
    @cInclude("commctrl.h");
    @cInclude("psapi.h");
    @cInclude("shlwapi.h");
    @cInclude("shlobj.h");
    // @cInclude("shlobj_core.h");
    @cInclude("uxtheme.h");
    @cInclude("dwmapi.h");
    @cInclude("servprov.h");
    @cInclude("ObjectArray.h");
    @cInclude("ShObjIdl_core.h");
});

pub usingnamespace w;

const std = @import("std");

//pub const HICON_a1 = *opaque {};

pub const WinApiError = error{GenericError, Failure};

pub fn mapErr(hResult: w.HRESULT) anyerror!void {
    if ((hResult >> 31) == w.SEVERITY_ERROR) {
        return WinApiError.GenericError;
    }
}

pub fn mapFailure(res: w.BOOL) anyerror!void {
    if(res == 0) {
        var errCode = w.GetLastError();
        std.debug.warn("WIN32ERRCODE: {x}\n", .{errCode});

        return WinApiError.Failure;
    }
}

pub fn logGdiObjects(comptime message: []const u8) void {
    var hProc = w.GetCurrentProcess();
    var gdiObjects = w.GetGuiResources(hProc, w.GR_GDIOBJECTS);
    std.debug.warn("{s}: gdiObjects: {}\n", .{message, gdiObjects});
}