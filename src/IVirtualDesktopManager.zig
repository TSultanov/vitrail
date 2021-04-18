const w = @import("windows.zig");
const std = @import("std");
const com = @import("com.zig");

const Self = @This();

const CLSID_VirtualDesktopManager: w.CLSID = w.CLSID{
    .Data1 = 0xaa509086,
    .Data2 = 0x5ca9,
    .Data3 = 0x4c25,
    .Data4 = [8]u8{ 0x8f, 0x95, 0x58, 0x9d, 0x3c, 0x07, 0xb4, 0x8a },
};

const IID_IVirtualDesktopManager: w.IID = w.IID{
    .Data1 = 0xa5cd92ff,
    .Data2 = 0x29be,
    .Data3 = 0x454c,
    .Data4 = [8]u8{ 0x8d, 0x04, 0xd8, 0x28, 0x79, 0xfb, 0x3f, 0x1b },
};

i: *w.IVirtualDesktopManager,

pub usingnamespace com.ComInterface(Self, IID_IVirtualDesktopManager, CLSID_VirtualDesktopManager, w.IVirtualDesktopManagerVtbl, w.IVirtualDesktopManager);

pub fn IsWindowOnCurrentVirtualDesktop(self: Self, topLevelWindow: w.HWND, onCurrentDesktop: [*c]BOOL) w.HRESULT {
    return self.i.lpVtbl.*.IsWindowOnCurrentVirtualDesktop.?(self.i, topLevelWindow, onCurrentDesktop);
}
pub fn GetWindowDesktopId(self: Self, topLevelWindow: w.HWND, desktopId: [*c]w.GUID) w.HRESULT {
    return self.i.lpVtbl.*.GetWindowDesktopId.?(self.i, topLevelWindow, desktopId);
}
pub fn MoveWindowToDesktop(self: Self, topLevelWindow: w.HWND, desktopId: [*c]w.GUID) w.HRESULT {
    return self.i.lpVtbl.*.MoveWindowToDesktop.?(self.i, topLevelWindow, desktopId);
}
