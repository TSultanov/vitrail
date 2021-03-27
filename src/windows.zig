pub usingnamespace @cImport({
    @cInclude("windows.h");
    @cInclude("commctrl.h");
    @cInclude("psapi.h");
    @cInclude("shlwapi.h");
    @cInclude("shlobj.h");
    @cInclude("shlobj_core.h");
    @cInclude("uxtheme.h");
    @cInclude("dwmapi.h");
});

//pub const HICON_a1 = *opaque {};

pub const WinApiError = error{GenericError, Failure};

pub fn mapErr(hResult: HRESULT) anyerror!void {
    if ((hResult >> 31) == SEVERITY_ERROR) {
        return WinApiError.GenericError;
    }
}

pub fn mapFailure(res: BOOL) anyerror!void {
    if(res == 0) {
        return WinApiError.Failure;
    }
}
