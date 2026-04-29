const wh = @import("windows.zig");
const w = wh.c;
const std = @import("std");
const com = @import("com/ComInterface.zig");
const UwpIcon = @import("UwpIcon.zig");
const common = @import("../../common/DesktopWindow.zig");
const icon_rgba = @import("icon_rgba.zig");

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

pub fn init(_: std.mem.Allocator) !Self {
    const serviceProvider = try com.IServiceProvider.create();
    return Self{
        .desktopManager = try com.IVirtualDesktopManager.create(),
        .serviceProvider = serviceProvider,
        .desktopManagerInternal = try com.IVirtualDesktopManagerInternal.create(serviceProvider),
    };
}

pub fn deinit(self: Self) void {
    self.desktopManager.Release();
    self.serviceProvider.Release();
    self.desktopManagerInternal.Release();
}

pub fn activateWindow(_: *Self, dw: common.DesktopWindow) void {
    const hwnd: w.HWND = @ptrFromInt(dw.platform_handle);
    _ = w.SwitchToThisWindow(hwnd, 1);
}

pub fn getWindowList(self: Self, allocator: std.mem.Allocator) !std.array_list.Managed(common.DesktopWindow) {
    var desktopsNullable: ?*com.IObjectArray = null;
    _ = self.desktopManagerInternal.GetDesktops(&desktopsNullable);
    var desktops = desktopsNullable orelse return error.Unknown;
    defer _ = desktops.Release();

    var dCount: c_uint = 0;
    _ = desktops.GetCount(&dCount);

    var desktopsMap = std.hash_map.AutoHashMap(w.GUID, usize).init(allocator);
    defer desktopsMap.deinit();

    const ivd_iid = resolved_ivd_iid orelse blk: {
        const IVDM = @import("com/IVirtualDesktopManagerInternal.zig");
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

    var windowList = std.array_list.Managed(common.DesktopWindow).init(allocator);
    errdefer {
        for (windowList.items) |dw| dw.destroy();
        windowList.deinit();
    }

    for (hwndList.items) |hwnd| {
        const shouldShow = try shouldShowWindow(hwnd);
        if (!shouldShow) continue;

        const title_utf16 = try getWindowTitle(hwnd, allocator);
        defer allocator.free(title_utf16);

        const title_lower_utf16 = try allocator.allocSentinel(u16, title_utf16.len, 0);
        defer allocator.free(title_lower_utf16);
        @memcpy(title_lower_utf16[0..title_utf16.len], title_utf16);
        if (title_lower_utf16.len > 0) {
            _ = w.CharLowerBuffW(title_lower_utf16, @intCast(title_lower_utf16.len - 1));
        }

        const actual_title = std.mem.sliceTo(title_utf16, 0);
        const title = try std.unicode.utf16LeToUtf8AllocZ(allocator, actual_title);
        errdefer allocator.free(title);

        const actual_lower = std.mem.sliceTo(title_lower_utf16, 0);
        const title_lower = try std.unicode.utf16LeToUtf8AllocZ(allocator, actual_lower);
        errdefer allocator.free(title_lower);

        const class_utf16 = try getWindowClass(hwnd, allocator);
        defer allocator.free(class_utf16);
        const actual_class = std.mem.sliceTo(class_utf16, 0);
        const app_id = try std.unicode.utf16LeToUtf8AllocZ(allocator, actual_class);
        errdefer allocator.free(app_id);
        const app_id_lower = try allocator.dupeZ(u8, app_id);
        errdefer allocator.free(app_id_lower);
        for (app_id_lower) |*ch| ch.* = std.ascii.toLower(ch.*);

        const icon_opt: ?common.RgbaIcon = blk: {
            const hicon = getWindowIcon(hwnd) catch break :blk null;
            const rgba = icon_rgba.hIconToRgba(hicon, allocator) catch {
                _ = w.DestroyIcon(hicon);
                break :blk null;
            };
            _ = w.DestroyIcon(hicon);
            break :blk rgba;
        };
        errdefer if (icon_opt) |ic| ic.destroy();

        var desktopId: w.GUID = undefined;
        _ = self.desktopManager.GetWindowDesktopId(hwnd, &desktopId);

        try windowList.append(common.DesktopWindow{
            .platform_handle = @intFromPtr(hwnd),
            .title = title,
            .title_lower = title_lower,
            .app_id = app_id,
            .app_id_lower = app_id_lower,
            .icon = icon_opt,
            .desktopNumber = desktopsMap.get(desktopId),
            .allocator = allocator,
        });
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

fn getClassName(hwnd: w.HWND, buf: []u16) []u16 {
    const n = w.GetClassNameW(hwnd, buf.ptr, @intCast(buf.len));
    if (n <= 0) return buf[0..0];
    return buf[0..@intCast(n)];
}

fn classEquals(hwnd: w.HWND, comptime literal: []const u8) bool {
    var buf: [256]u16 = undefined;
    const class = getClassName(hwnd, &buf);
    return std.mem.eql(u16, class, toUtf16const(literal));
}

const FindUwpCtx = struct {
    host_pid: w.DWORD,
    found: ?w.HWND,
};

fn findUwpChildProc(hwnd: w.HWND, lParam: w.LPARAM) callconv(.c) c_int {
    const ctx: *FindUwpCtx = @ptrFromInt(@as(usize, @intCast(lParam)));
    var pid: w.DWORD = 0;
    _ = w.GetWindowThreadProcessId(hwnd, &pid);
    if (pid != 0 and pid != ctx.host_pid) {
        ctx.found = hwnd;
        return 0;
    }
    return 1;
}

fn getUwpContentWindow(hwnd: w.HWND) ?w.HWND {
    var host_pid: w.DWORD = 0;
    _ = w.GetWindowThreadProcessId(hwnd, &host_pid);
    var ctx = FindUwpCtx{ .host_pid = host_pid, .found = null };
    _ = w.EnumChildWindows(hwnd, @ptrCast(&findUwpChildProc), @intCast(@intFromPtr(&ctx)));
    return ctx.found;
}

fn isUwpFrame(hwnd: w.HWND) bool {
    return classEquals(hwnd, "ApplicationFrameWindow");
}

fn getWindowIcon(hwnd: w.HWND) !w.HICON {
    if (isUwpFrame(hwnd)) {
        if (UwpIcon.tryGetUwpIcon(hwnd)) |icon| return icon;
    }
    const realHwnd: w.HWND = if (isUwpFrame(hwnd)) (getUwpContentWindow(hwnd) orelse hwnd) else hwnd;

    for ([_]w.WPARAM{ w.ICON_BIG, w.ICON_SMALL2, w.ICON_SMALL }) |which| {
        var iconAddr: usize = 0;
        const lResult = w.SendMessageTimeoutW(realHwnd, w.WM_GETICON, which, 0, w.SMTO_ABORTIFHUNG, 100, &iconAddr);
        if (lResult != 0 and iconAddr != 0) {
            return @ptrFromInt(iconAddr);
        }
    }

    for ([_]c_int{ w.GCLP_HICON, w.GCLP_HICONSM }) |which| {
        const ptr = w.GetClassLongPtrW(realHwnd, which);
        if (ptr != 0) return @ptrFromInt(ptr);
    }

    if (try extractIconFromExecutable(realHwnd)) |icon| return icon;

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

        var largeIconEx: w.HICON = null;
        var smallIconEx: w.HICON = null;
        const extracted = w.ExtractIconExW(fileName, 0, &largeIconEx, &smallIconEx, 1);
        if (extracted > 0 and @intFromPtr(largeIconEx) != 0) {
            if (@intFromPtr(smallIconEx) != 0) _ = w.DestroyIcon(smallIconEx);
            return largeIconEx;
        }
        if (@intFromPtr(smallIconEx) != 0) _ = w.DestroyIcon(smallIconEx);

        var largeIcon: w.HICON = null;
        var smallIcon: w.HICON = null;
        _ = w.SHDefExtractIconW(fileName, 0, 0, &largeIcon, &smallIcon, 0);
        if (@intFromPtr(smallIcon) != 0) _ = w.DestroyIcon(smallIcon);
        if (@intFromPtr(largeIcon) != 0) return largeIcon;
        return null;
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

    if (classEquals(hwnd, "Windows.UI.Core.CoreWindow")) return false;

    if (classEquals(hwnd, "ApplicationFrameWindow")) {
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
