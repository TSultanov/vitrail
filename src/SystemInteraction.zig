const wh = @import("windows.zig");
const w = wh.c;
const std = @import("std");
const com = @import("ComInterface.zig");

var resolved_ivd_iid: ?w.IID = null;

const Self = @This();

desktopManager: *com.IVirtualDesktopManager,
serviceProvider: *com.IServiceProvider,
desktopManagerInternal: *com.IVirtualDesktopManagerInternal,

pub fn toUtf16(str: []const u8) ![:0]u16 {
    var buf: [512:0]u16 = undefined;
    _ = try std.unicode.utf8ToUtf16Le(&buf, str);
    return buf[0..];
}

pub fn toUtf16const(comptime str: []const u8) [:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(str);
}

pub fn toUtf8(str: []u16, allocator: std.mem.Allocator) ![]u8 {
    return try std.unicode.utf16LeToUtf8Alloc(allocator, str);
}

pub const DesktopWindow = struct {
    hwnd: w.HWND,
    title: [:0]u16,
    title_lower: [:0]u16,
    class: [:0]u16,
    icon: w.HICON,
    executablePath: ?[:0]u16,
    executableName: ?[:0]u16,
    shouldShow: bool,
    desktopNumber: ?usize,
    originalAllocator: std.mem.Allocator,

    pub fn destroy(self: DesktopWindow) !void {
        self.originalAllocator.free(self.title);
        self.originalAllocator.free(self.title_lower);
        self.originalAllocator.free(self.class);
        if (self.executablePath) |fname| self.originalAllocator.free(fname);

        _ = w.DestroyIcon(self.icon);
    }
};

fn enumWindowProc(hwnd: w.HWND, lParam: w.LPARAM) callconv(.c) c_int {
    const windows: *std.array_list.Managed(w.HWND) = @ptrFromInt(@as(usize, @intCast(lParam)));

    var procId: w.DWORD = undefined;
    _ = w.GetWindowThreadProcessId(hwnd, &procId);
    const currProcId = w.GetCurrentProcessId();

    if (procId == currProcId) {
        return 1;
    }

    windows.append(hwnd) catch unreachable;

    return 1;
}

pub fn init() !Self {
    const serviceProvider = try com.IServiceProvider.create();
    return Self{
        .desktopManager = try com.IVirtualDesktopManager.create(),
        .serviceProvider = serviceProvider,
        .desktopManagerInternal = try com.IVirtualDesktopManagerInternal.create(serviceProvider),
    };
}

pub fn deinit(self: Self) !void {
    self.desktopManager.Release();
    self.serviceProvider.Release();
    self.desktopManagerInternal.Release();
}

pub fn getWindowList(self: Self, allocator: std.mem.Allocator) !std.array_list.Managed(DesktopWindow) {
    var desktopsNullable: ?*com.IObjectArray = null;
    _ = self.desktopManagerInternal.GetDesktops(&desktopsNullable);
    var desktops = desktopsNullable orelse return error.Unknown;
    defer _ = desktops.Release();

    var dCount: c_uint = 0;
    _ = desktops.GetCount(&dCount);

    var desktopsMap = std.hash_map.AutoHashMap(w.GUID, usize).init(allocator);
    defer desktopsMap.deinit();

    const ivd_iid = resolved_ivd_iid orelse blk: {
        const IVDM = @import("IVirtualDesktopManagerInternal.zig");
        for (IVDM.IVD_IID_CANDIDATES) |cand| {
            const r = desktops.GetAtWithIID(0, &cand.iid, com.IVirtualDesktop);
            if (r.hr == 0) {
                _ = r.ptr.?.Release();
                resolved_ivd_iid = cand.iid;
                break :blk cand.iid;
            }
        }
        return error.Unknown;
    };

    var i: usize = 0;
    while (i < dCount) {
        const r = desktops.GetAtWithIID(i, &ivd_iid, com.IVirtualDesktop);
        if (r.hr != 0) return error.Unknown;
        const desktop = r.ptr.?;
        var desktopId: w.GUID = undefined;
        _ = desktop.GetID(&desktopId);
        try desktopsMap.put(desktopId, i);
        i += 1;
    }

    var hwndList = std.array_list.Managed(w.HWND).init(allocator);
    defer hwndList.deinit();
    _ = w.EnumWindows(@ptrCast(&enumWindowProc), @intCast(@intFromPtr(&hwndList)));
    var windowList = std.array_list.Managed(DesktopWindow).init(allocator);
    for (hwndList.items) |hwnd| {
        const shouldShow = try shouldShowWindow(hwnd);
        if (!shouldShow) continue;
        const title = try getWindowTitle(hwnd, allocator);

        const title_lower = try allocator.allocSentinel(u16, title.len, 0);
        @memcpy(title_lower[0..title.len], title);
        _ = w.CharLowerBuffW(title_lower, @intCast(title_lower.len - 1));

        const class = try getWindowClass(hwnd, allocator);
        const icon: w.HICON = try getWindowIcon(hwnd);

        var desktopId: w.GUID = undefined;
        _ = self.desktopManager.GetWindowDesktopId(hwnd, &desktopId);

        const executablePath = try getWindowFilePath(hwnd, allocator);
        var executableName: ?[:0]u16 = null;
        if (executablePath) |ep| {
            const name: [*:0]u16 = w.PathFindFileNameW(ep);
            executableName = std.mem.span(name);
        }

        if (shouldShow) {
            try windowList.append(DesktopWindow{
                .hwnd = hwnd,
                .title = title,
                .title_lower = title_lower,
                .class = class,
                .icon = icon,
                .executablePath = executablePath,
                .executableName = executableName,
                .shouldShow = shouldShow,
                .desktopNumber = desktopsMap.get(desktopId),
                .originalAllocator = allocator,
            });
        }
    }
    return windowList;
}

fn getWindowTitle(hwnd: w.HWND, allocator: std.mem.Allocator) ![:0]u16 {
    const length = w.GetWindowTextLengthW(hwnd) + 1;
    const title: [:0]u16 = try allocator.allocSentinel(u16, @intCast(length), 0);
    @memset(title, 0);
    _ = w.GetWindowTextW(hwnd, title, length);
    return title;
}

fn getWindowClass(hwnd: w.HWND, allocator: std.mem.Allocator) ![:0]u16 {
    const class: [:0]u16 = try allocator.allocSentinel(u16, 512, 0);
    @memset(class, 0);
    _ = w.GetClassNameW(hwnd, class, 511);
    return class;
}

fn getWindowIcon(hwnd: w.HWND) !w.HICON {
    const fileIcon = try extractIconFromExecutable(hwnd);
    if (fileIcon != null) return fileIcon.?;

    var iconAddr: usize = undefined;
    const lResult = w.SendMessageTimeoutW(hwnd, w.WM_GETICON, w.ICON_BIG, 0, w.SMTO_ABORTIFHUNG, 10, &iconAddr);
    if (lResult != 0 and iconAddr != 0) {
        const icon: w.HICON = @ptrFromInt(iconAddr);
        return icon;
    }

    const wndClassLongPtr = w.GetClassLongPtrW(hwnd, w.GCLP_HICON);
    if (wndClassLongPtr != 0) {
        const icon: w.HICON = @ptrFromInt(wndClassLongPtr);
        return icon;
    }

    return @ptrCast(w.LoadIconW(null, @ptrFromInt(32512)));
}

fn getWindowFilePath(hwnd: w.HWND, allocator: std.mem.Allocator) !?[:0]u16 {
    var pid: w.DWORD = undefined;
    _ = w.GetWindowThreadProcessId(hwnd, &pid);
    const hProc: w.HANDLE = w.OpenProcess(w.PROCESS_QUERY_INFORMATION | w.PROCESS_VM_READ, 0, pid);
    defer _ = w.CloseHandle(hProc);
    const fileName: [:0]u16 = try allocator.allocSentinel(u16, 4096, 0);
    @memset(fileName, 0);
    var fileNameSize: u32 = 4096;
    const result = w.QueryFullProcessImageNameW(hProc, 0, fileName, &fileNameSize);
    if (result == 0) {
        return null;
    } else {
        return fileName;
    }
}

fn extractIconFromExecutable(hwnd: w.HWND) !?w.HICON {
    var filePathBuf = [_]u8{0} ** 8194;
    var fba = std.heap.FixedBufferAllocator.init(&filePathBuf);
    const windowFileName = try getWindowFilePath(hwnd, fba.allocator());
    if (windowFileName) |fileName| {
        defer fba.allocator().free(fileName);
        const iconIndex: w.WORD = 0;
        var largeIcon: w.HICON = undefined;
        var smallIcon: w.HICON = undefined;
        _ = w.SHDefExtractIconW(fileName, iconIndex, 0, &largeIcon, &smallIcon, 0);
        _ = w.DestroyIcon(smallIcon);
        return largeIcon;
    }

    return null;
}

fn shouldShowWindow(hwnd: w.HWND) !bool {
    const owner = w.GetWindow(hwnd, w.GW_OWNER);
    var ownerVisible = false;
    if (owner != null) {
        var ownerPwi: w.WINDOWINFO = undefined;
        _ = w.GetWindowInfo(hwnd, &ownerPwi);
        ownerVisible = ownerPwi.dwStyle & @as(c_ulong, @intCast(w.WS_VISIBLE)) != 0;
    }

    var pwi: w.WINDOWINFO = undefined;
    _ = w.GetWindowInfo(hwnd, &pwi);

    const titleLength = w.GetWindowTextLengthW(hwnd);

    const isVisible = pwi.dwStyle & @as(c_ulong, @intCast(w.WS_VISIBLE)) != 0;
    const hasTitle = titleLength > 0;
    const isAppWindow = pwi.dwExStyle & @as(c_ulong, @intCast(w.WS_EX_APPWINDOW)) != 0;
    const isToolWindow = (pwi.dwExStyle & @as(c_ulong, @intCast(w.WS_EX_TOOLWINDOW)) != 0);
    const isNoActivate = pwi.dwExStyle & @as(c_ulong, @intCast(w.WS_EX_NOACTIVATE)) != 0;
    const isDisabled = pwi.dwStyle & @as(c_ulong, @intCast(w.WS_DISABLED)) != 0;

    if (!isVisible) return false;
    if (!hasTitle) return false;
    if (isDisabled) return false;
    if (isAppWindow) return true;
    if (isToolWindow) return false;
    if (isNoActivate) return true;
    if (!(owner == null or !ownerVisible)) return false;

    const taskListDeletedProp = toUtf16const("ITaskList_Deleted");
    const taskListDeleted = w.GetPropW(hwnd, taskListDeletedProp);
    defer if (taskListDeleted != null) {
        _ = w.CloseHandle(taskListDeleted);
    };
    if (taskListDeleted != null) return false;

    var classBuf = [_]u8{0} ** 1026;
    var fba = std.heap.FixedBufferAllocator.init(&classBuf);
    const class = try getWindowClass(hwnd, fba.allocator());
    defer fba.allocator().free(class);

    const coreWindowClass = toUtf16const("Windows.UI.Core.CoreWindow");
    if (std.mem.eql(u16, class, coreWindowClass)) return false;

    const uwpAppClass = toUtf16const("ApplicationFrameWindow");
    const isUwpApp = std.mem.eql(u16, class, uwpAppClass);

    if (isUwpApp) {
        var validCloak: bool = false;
        _ = w.EnumPropsExA(hwnd, @ptrCast(&verifyUwpCloak), @intCast(@intFromPtr(&validCloak)));
        return validCloak;
    }

    return true;
}

fn verifyUwpCloak(_: w.HWND, str: w.LPSTR, handle: w.HANDLE, ptr: w.ULONG_PTR) callconv(.c) c_int {
    const cloakType = "ApplicationViewCloakType";
    if (@intFromPtr(str) > 0xffff) {
        const prop = std.mem.span(str);
        if (std.mem.eql(u8, cloakType, prop)) {
            if (@intFromPtr(handle) != 1) {
                const pValidCloak: *bool = @ptrFromInt(ptr);
                pValidCloak.* = true;
            }
            return 0;
        }
    }
    return 1;
}
