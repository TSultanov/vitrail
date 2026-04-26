pub const c = @cImport({
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
    @cInclude("uxtheme.h");
    @cInclude("dwmapi.h");
});

const std = @import("std");

pub const WinApiError = error{ GenericError, Failure };

pub fn mapErr(hResult: c.HRESULT) anyerror!void {
    if ((hResult >> 31) == c.SEVERITY_ERROR) {
        return WinApiError.GenericError;
    }
}

pub fn mapFailure(res: c.BOOL) anyerror!void {
    if (res == 0) {
        const errCode = c.GetLastError();
        std.log.err("WIN32ERRCODE: {x}\n", .{errCode});

        return WinApiError.Failure;
    }
}

pub fn logGdiObjects(comptime message: []const u8) void {
    const hProc = c.GetCurrentProcess();
    const gdiObjects = c.GetGuiResources(hProc, c.GR_GDIOBJECTS);
    std.log.info("{s}: gdiObjects: {}\n", .{ message, gdiObjects });
}
