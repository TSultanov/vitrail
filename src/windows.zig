pub usingnamespace @cImport({
    @cDefine("_UNICODE", "1");
    @cDefine("_WIN64", "1");
    @cDefine("_AMD64_", "1");
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
});

const std = @import("std");

//pub const HICON_a1 = *opaque {};

pub const WinApiError = error{GenericError, Failure};

pub fn mapErr(hResult: HRESULT) anyerror!void {
    if ((hResult >> 31) == SEVERITY_ERROR) {
        return WinApiError.GenericError;
    }
}

pub fn mapFailure(res: BOOL) anyerror!void {
    if(res == 0) {
        var errCode = GetLastError();
        std.debug.warn("WIN32ERRCODE: {x}\n", .{errCode});

        return WinApiError.Failure;
    }
}

pub fn logGdiObjects(comptime message: []const u8) void {
    var hProc = GetCurrentProcess();
    var gdiObjects = GetGuiResources(hProc, GR_GDIOBJECTS);
    std.debug.warn("{s}: gdiObjects: {}\n", .{message, gdiObjects});
}