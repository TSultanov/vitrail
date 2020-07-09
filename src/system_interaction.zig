const std = @import("std");
const w = @import("win32").c;
const Allocator = std.mem.Allocator;

pub fn toUtf16(str: []const u8) ![:0]u16 {
    var buf: [512:0]u16 = undefined;
    _ = try std.unicode.utf8ToUtf16Le(&buf, str);
    return buf[0..];
}

pub fn toUtf16const(comptime str: []const u8) [:0]u16 {
    comptime var utf16str = toUtf16(str) catch unreachable;
    return utf16str;
}

pub const DesktopWindow = struct {
    hwnd: w.HWND,
    title: []u16,
    class: []u16,
    icon: w.HICON,
    shouldShow: bool,
};

fn enumWindowProc(hwnd: w.HWND, lParam: w.LPARAM) callconv(.C) c_int {
    var windows: *std.ArrayList(w.HWND) = @intToPtr(*std.ArrayList(w.HWND), @intCast(usize, lParam));

    var procId: w.DWORD = undefined;
    _ = w.GetWindowThreadProcessId(hwnd, &procId);
    var currProcId = w.GetCurrentProcessId();

    if(procId == currProcId) {
        return 1;
    }

    windows.append(hwnd) catch unreachable;
    
    return 1;
}

pub fn init(hInstance: w.HINSTANCE, allocator: *Allocator) SystemInteraction {
    return SystemInteraction {
        .allocator = allocator,
        .hInstance = hInstance,
    };
}

pub const SystemInteraction = struct {
    allocator: *Allocator,
    hInstance: w.HINSTANCE,

    pub fn getWindowList(self: @This()) ![]DesktopWindow {
        var hwndList = std.ArrayList(w.HWND).init(self.allocator);
        _ = w.EnumWindows(enumWindowProc, @intCast(c_longlong, @ptrToInt(&hwndList)));
        var windowList = std.ArrayList(DesktopWindow).init(self.allocator);
        for (hwndList.span()) |hwnd| {
            try windowList.append(try self.hwndToDesktopWindow(hwnd));
        }
        return windowList.span();
    }

    fn hwndToDesktopWindow(self: @This(), hwnd: w.HWND) !DesktopWindow {
        var shouldShow = self.shouldShowWindow(hwnd);
        var title = try self.getWindowTitle(hwnd);
        var class = try self.getWindowClass(hwnd);
        var icon: w.HICON = try self.getWindowIcon(hwnd);
        var dwindow = DesktopWindow {
            .hwnd = hwnd,
            .title = title,
            .class = class[0..],
            .icon = icon,
            .shouldShow = try shouldShow,
        };
        return dwindow;
    }

    fn getWindowTitle(self: @This(), hwnd: w.HWND) ![]u16 {
        var title: []u16 = try self.allocator.alloc(u16, 512);
        for (title[0..512]) |*b| b.* = 0;
        _ = w.GetWindowTextW(hwnd, &title[0], 512);

        return title;
    }

    fn getWindowClass(self: @This(), hwnd: w.HWND) ![]u16 {
        var class: []u16 = try self.allocator.alloc(u16, 512);
        for (class[0..512]) |*b| b.* = 0;
        
        _ = w.RealGetWindowClassW(hwnd, &class[0], 512);
        return class;
    }

    fn getWindowIcon(self: @This(), hwnd: w.HWND) !w.HICON {
        var iconAddr: c_ulonglong = undefined;
        var lResult = w.SendMessageTimeoutW(hwnd, w.WM_GETICON, w.ICON_SMALL2, 0, w.SMTO_ABORTIFHUNG, 10, &iconAddr);
        if(lResult != 0 and iconAddr != 0)
        {
            var icon: w.HICON = @intToPtr(w.HICON, @intCast(usize, iconAddr));
            return icon;
        }

        var wndClassU = w.GetClassLongPtrW(hwnd, w.GCL_HICON);
        if(wndClassU != 0)
        {
            var icon: w.HICON = @intToPtr(w.HICON, wndClassU);
            return icon;
        }

        var fileIcon = try self.extractIconFromExecutable(hwnd);
        if(fileIcon != null) return fileIcon;

        return w.LoadIconW(null, 32512);
    }

    fn extractIconFromExecutable(self: @This(), hwnd: w.HWND) !w.HICON {
        var pid: w.DWORD = undefined;
        _ = w.GetWindowThreadProcessId(hwnd, &pid);
        var hProc = w.OpenProcess(w.PROCESS_QUERY_INFORMATION | w.PROCESS_VM_READ, 0, pid);
        defer _ = w.CloseHandle(hProc);
        var fileName: *[1024]u16 = try self.allocator.create([1024]u16);
        defer self.allocator.free(fileName);
        for (fileName[0..1024]) |*b| b.* = 0;
        var result = w.GetModuleFileNameW(@ptrCast(w.HMODULE, @alignCast(4, hProc)), fileName, 1024);
        if(result == 0) return null;

        var iconIndex: w.WORD = 0;
        var icon = w.ExtractAssociatedIconW(self.hInstance, fileName, &iconIndex);
        return icon;
    }

    fn shouldShowWindow(self: @This(), hwnd: w.HWND) !bool {
        var owner = w.GetWindow(hwnd, w.GW_OWNER);
        var ownerVisible = false;
        if (owner != null) {
            var ownerPwi: w.WINDOWINFO = undefined;
            _ = w.GetWindowInfo(hwnd, &ownerPwi);
            ownerVisible = ownerPwi.dwStyle & @intCast(c_ulong, w.WS_VISIBLE) != 0;
        }

        var pwi: w.WINDOWINFO = undefined;
        _ = w.GetWindowInfo(hwnd, &pwi);

        var titleLength = w.GetWindowTextLengthW(hwnd);

        var isVisible = pwi.dwStyle & @intCast(c_ulong, w.WS_VISIBLE) != 0;
        var hasTitle = titleLength > 0;
        var isAppWindow = pwi.dwExStyle & @intCast(c_ulong, w.WS_EX_APPWINDOW) != 0;
        var isToolWindow = (pwi.dwExStyle & @intCast(c_ulong, w.WS_EX_TOOLWINDOW) != 0);
        var isNoActivate = pwi.dwExStyle & @intCast(c_ulong, w.WS_EX_NOACTIVATE) != 0;
        var isDisabled = pwi.dwStyle & @intCast(c_ulong, w.WS_DISABLED) != 0;

        if (!isVisible) return false;
        if (!hasTitle) return false;
        if (isDisabled) return false;
        if (isAppWindow) return true;
        if (isToolWindow) return false;
        if (isNoActivate) return true;
        if (!(owner == null or !ownerVisible)) return false;

        comptime var taskListDeletedProp = try toUtf16("ITaskList_Deleted");
        var taskListDeleted = w.GetPropW(hwnd, taskListDeletedProp);
        if(taskListDeleted != null) return false;
        
        var class = try self.getWindowClass(hwnd);

        comptime var coreWindowClass = try toUtf16("Windows.UI.Core.CoreWindow");
        if(std.mem.eql(u16, class, coreWindowClass)) return false;

        comptime var uwpAppClass = try toUtf16("ApplicationFrameWindow");
        var isUwpApp = std.mem.eql(u16, class, uwpAppClass);
        comptime var cloakType = "ApplicationViewCloakType";

        if (isUwpApp) {
            var validCloak: bool = false;
            _ = w.EnumPropsExA(hwnd, verifyUwpCloak, @intCast(c_longlong, @ptrToInt(&validCloak)));
            return validCloak;
        }

        return true;
    }
};

fn verifyUwpCloak(hwnd: w.HWND, str: w.LPSTR, handle: w.HANDLE, ptr: w.ULONG_PTR) callconv(.C) c_int {
    comptime var cloakType = "ApplicationViewCloakType";
    if(@ptrToInt(str) > 0xffff) {
        var prop = std.mem.spanZ(str);
        if(std.mem.eql(u8, cloakType, prop)) {
            if(@ptrToInt(handle) != 1) {
                var pValidCloak = @intToPtr(*bool, ptr);
                pValidCloak.* = true;
            }
            return 0;
        }
    }
    return 1;
}