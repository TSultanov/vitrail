const w = @import("windows.zig");
const std = @import("std");
const com = @import("ComInterface.zig");

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

pub fn toUtf8(str: []u16, allocator: *Allocator) ![]u8 {
    return try std.unicode.utf16leToUtf8Alloc(allocator, str);
}

pub const DesktopWindow = struct {
    hwnd: w.HWND,
    title: [:0]u16,
    class: [:0]u16,
    icon: w.HICON,
    executablePath: ?[:0]u16,
    executableName: ?[:0]u16,
    shouldShow: bool,
    desktopNumber: ?usize,
    originalAllocator: *std.mem.Allocator,

    pub fn destroy(self: DesktopWindow) !void {
        self.originalAllocator.free(self.title);
        self.originalAllocator.free(self.class);
        if (self.executablePath) |fname| self.originalAllocator.free(fname);

        _ = w.DestroyIcon(self.icon);
    }
};

fn enumWindowProc(hwnd: w.HWND, lParam: w.LPARAM) callconv(.C) c_int {
    var windows: *std.ArrayList(w.HWND) = @intToPtr(*std.ArrayList(w.HWND), @intCast(usize, lParam));

    var procId: w.DWORD = undefined;
    _ = w.GetWindowThreadProcessId(hwnd, &procId);
    var currProcId = w.GetCurrentProcessId();

    if (procId == currProcId) {
        return 1;
    }

    windows.append(hwnd) catch unreachable;

    return 1;
}

pub fn init(hInstance: w.HINSTANCE, allocator: *Allocator) !SystemInteraction {
    const serviceProvider = try com.IServiceProvider.create();
    return SystemInteraction{
        .allocator = allocator,
        .hInstance = hInstance,
        .desktopManager = try com.IVirtualDesktopManager.create(),
        .serviceProvider = serviceProvider,
        .desktopManagerInternal = try com.IVirtualDesktopManagerInternal.create(serviceProvider),
    };
}

pub const SystemInteraction = struct {
    allocator: *Allocator,
    hInstance: w.HINSTANCE,
    desktopManager: *com.IVirtualDesktopManager,
    serviceProvider: *com.IServiceProvider,
    desktopManagerInternal: *com.IVirtualDesktopManagerInternal,

    pub fn getWindowList(self: @This()) !std.ArrayList(DesktopWindow) { //TODO: accept allocator as function argument, remove dependency on hInstance
        var desktopsNullable: ?*com.IObjectArray = undefined;
        var desktopsHr = self.desktopManagerInternal.GetDesktops(&desktopsNullable);
        var desktops = desktopsNullable orelse unreachable;
        defer _ = desktops.Release();

        var dCount: c_uint = undefined;
        var countHr = desktops.GetCount(&dCount);

        var desktopsMap = std.hash_map.AutoHashMap(w.GUID, usize).init(self.allocator);
        defer desktopsMap.deinit();

        var i: usize = 0;
        while (i < dCount) {
            var desktop = try desktops.GetAtGeneric(i, com.IVirtualDesktop);
            var desktopId: w.GUID = undefined;
            _ = desktop.GetID(&desktopId);
            try desktopsMap.put(desktopId, i);
            i += 1;
        }

        var hwndList = std.ArrayList(w.HWND).init(self.allocator);
        defer hwndList.deinit();
        _ = w.EnumWindows(enumWindowProc, @intCast(c_longlong, @ptrToInt(&hwndList)));
        var windowList = std.ArrayList(DesktopWindow).init(self.allocator); //TODO check for memory leak here
        for (hwndList.items) |hwnd| {
            var shouldShow = try self.shouldShowWindow(hwnd);
            if(!shouldShow) continue;
            var title = try self.getWindowTitle(hwnd);
            var class = try self.getWindowClass(hwnd);
            var icon: w.HICON = try self.getWindowIcon(hwnd);

            var desktopId: w.GUID = undefined;
            _ = self.desktopManager.GetWindowDesktopId(hwnd, &desktopId);

            var executablePath = try self.getWindowFilePath(hwnd);
            var executableName: ?[:0]u16 = null;
            if (executablePath) |ep| {
                var name: [*:0]u16 = w.PathFindFileNameW(ep);
                executableName = std.mem.spanZ(name);
            }

            if (shouldShow) {
                try windowList.append(DesktopWindow {
                     .hwnd = hwnd,
                     .title = title,
                     .class = class,
                     .icon = icon,
                     .executablePath = executablePath,
                     .executableName = executableName,
                     .shouldShow = shouldShow,
                     .desktopNumber = desktopsMap.get(desktopId),
                     .originalAllocator = self.allocator
                });
            }
        }
        return windowList;
    }

    fn getWindowTitle(self: @This(), hwnd: w.HWND) ![:0]u16 {
        const length = w.GetWindowTextLengthW(hwnd) + 1;
        const title: [:0]u16 = try self.allocator.allocSentinel(u16, @intCast(usize, length), 0);
        std.mem.set(u16, title, 0);
        _ = w.GetWindowTextW(hwnd, title, length);
        return title;
    }

    fn getWindowClass(self: @This(), hwnd: w.HWND) ![:0]u16 {
        const class: [:0]u16 = try self.allocator.allocSentinel(u16, 512, 0);
        std.mem.set(u16, class, 0);
        _ = w.GetClassNameW(hwnd, class, 511);
        return class;
    }

    fn getWindowIcon(self: @This(), hwnd: w.HWND) !w.HICON {
        var iconAddr: c_ulonglong = undefined;
        // var lResult = w.SendMessageTimeoutW(hwnd, w.WM_GETICON, w.ICON_SMALL2, 0, w.SMTO_ABORTIFHUNG, 10, &iconAddr);
        // if (lResult != 0 and iconAddr != 0) {
        //     var icon: w.HICON = @intToPtr(w.HICON, @intCast(usize, iconAddr));
        //     return icon;
        // }

        // var wndClassLongPtr = w.GetClassLongPtrW(hwnd, w.GCLP_HICON);
        // if (wndClassLongPtr != 0) {
        //     var icon: w.HICON = @intToPtr(w.HICON, wndClassLongPtr);
        //     return icon;
        // }

        var fileIcon = try self.extractIconFromExecutable(hwnd);
        if (fileIcon != null) return fileIcon.?;

        return @ptrCast(w.HICON, w.LoadIconW(null, 32512));
    }

    fn getWindowFilePath(self: @This(), hwnd: w.HWND) !?[:0]u16 {
        var pid: w.DWORD = undefined;
        _ = w.GetWindowThreadProcessId(hwnd, &pid);
        var hProc: w.HANDLE = w.OpenProcess(w.PROCESS_QUERY_INFORMATION | w.PROCESS_VM_READ, 0, pid);
        defer _ = w.CloseHandle(hProc);
        const fileName: [:0]u16 = try self.allocator.allocSentinel(u16, 1024, 0);
        std.mem.set(u16, fileName, 0);
        var fileNameSize: u32 = 1024;
        var result = w.QueryFullProcessImageNameW(hProc, 0, fileName, &fileNameSize);
        if (result == 0) {
            return null;
        }
        else {
            return fileName;
        }
    }

    fn extractIconFromExecutable(self: @This(), hwnd: w.HWND) !?w.HICON {
        var windowFileName = try self.getWindowFilePath(hwnd);
        if(windowFileName) |fileName| {
            defer self.allocator.free(fileName);
            var iconIndex: w.WORD = 0;
            var largeIcon: w.HICON = undefined;
            var smallIcon: w.HICON = undefined;
            _ = w.SHDefExtractIconW(fileName, iconIndex, 0, &largeIcon, &smallIcon, 0); //TODO: process errors
            _ = w.DestroyIcon(smallIcon);
            return largeIcon;
        }

        return null;
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
        if (taskListDeleted != null) return false;

        var class = try self.getWindowClass(hwnd);

        comptime var coreWindowClass = try toUtf16("Windows.UI.Core.CoreWindow");
        if (std.mem.eql(u16, class, coreWindowClass)) return false;

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
    if (@ptrToInt(str) > 0xffff) {
        var prop = std.mem.spanZ(str);
        if (std.mem.eql(u8, cloakType, prop)) {
            if (@ptrToInt(handle) != 1) {
                var pValidCloak = @intToPtr(*bool, ptr);
                pValidCloak.* = true;
            }
            return 0;
        }
    }
    return 1;
}
