pub usingnamespace @cImport({
    @cInclude("windows.h");
    @cInclude("commctrl.h");
});

pub const HICON_a1 = *opaque {};

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
