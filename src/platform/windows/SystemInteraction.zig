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
allocator: std.mem.Allocator,
window_generations: std.AutoHashMap(usize, u64),
next_window_generation: u64 = 1,

// WinEvent callbacks do not carry application context. Vitrail has one
// SystemInteraction instance, registered here after it reaches its final
// address inside MainPresenter.
var lifecycle_tracker: ?*Self = null;

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

    var procId: w.DWORD = 0;
    if (w.GetWindowThreadProcessId(hwnd, &procId) == 0 or procId == 0) return 1;
    const currProcId = w.GetCurrentProcessId();

    if (procId == currProcId) {
        return 1;
    }

    windows.append(hwnd) catch unreachable;

    return 1;
}

pub fn init(allocator: std.mem.Allocator) !Self {
    const serviceProvider = try com.IServiceProvider.create();
    return Self{
        .desktopManager = try com.IVirtualDesktopManager.create(),
        .serviceProvider = serviceProvider,
        .desktopManagerInternal = try com.IVirtualDesktopManagerInternal.create(serviceProvider),
        .allocator = allocator,
        .window_generations = std.AutoHashMap(usize, u64).init(allocator),
    };
}

pub fn bindLifecycleTracker(self: *Self) void {
    lifecycle_tracker = self;
}

/// Invalidate the identity associated with an HWND at both ends of its native
/// lifetime. If Windows recycles the numeric handle before the next snapshot,
/// the replacement receives a different generation.
pub fn retireWindowIdentity(hwnd: w.HWND) void {
    const self = lifecycle_tracker orelse return;
    _ = self.window_generations.remove(@intFromPtr(hwnd));
}

pub fn deinit(self: *Self) void {
    if (lifecycle_tracker == self) lifecycle_tracker = null;
    self.window_generations.deinit();
    _ = self.desktopManager.Release();
    _ = self.serviceProvider.Release();
    _ = self.desktopManagerInternal.Release();
}

pub fn activateWindow(self: *Self, dw: common.DesktopWindow) void {
    const hwnd = self.resolveStableId(dw.stable_id) orelse return;
    if (@intFromPtr(hwnd) != dw.platform_handle) return;
    _ = w.SwitchToThisWindow(hwnd, 1);
}

/// Request the target window's ordinary graceful-close path. The stable ID is
/// decoded and checked against the current PID and lifecycle generation before
/// posting WM_CLOSE, preventing a deferred menu command from acting on a
/// recycled native handle.
pub fn closeWindow(self: *Self, dw: common.DesktopWindow) void {
    if (!dw.can_close) return;
    const hwnd = self.resolveStableId(dw.stable_id) orelse return;
    if (@intFromPtr(hwnd) != dw.platform_handle) return;
    if (!(shouldShowWindow(hwnd) catch false)) return;
    if (!canCloseWindow(hwnd)) return;
    _ = w.PostMessageW(hwnd, w.WM_CLOSE, 0, 0);
}

const QuitApplicationCtx = struct {
    pid: w.DWORD,
};

fn quitApplicationWindowProc(hwnd: w.HWND, lParam: w.LPARAM) callconv(.c) c_int {
    const ctx: *const QuitApplicationCtx = @ptrFromInt(@as(usize, @intCast(lParam)));
    if (applicationPidForWindow(hwnd) == ctx.pid) {
        _ = w.PostMessageW(hwnd, w.WM_CLOSE, 0, 0);
    }
    return 1;
}

/// Request the normal close path for every top-level window owned by the
/// target application. This preserves save prompts and avoids forcibly
/// terminating the process.
pub fn quitApplication(self: *Self, dw: common.DesktopWindow) void {
    const hwnd = self.resolveStableId(dw.stable_id) orelse return;
    if (@intFromPtr(hwnd) != dw.platform_handle) return;
    const pid = applicationPidForWindow(hwnd);
    if (pid == 0 or pid == w.GetCurrentProcessId()) return;
    var ctx = QuitApplicationCtx{ .pid = pid };
    _ = w.EnumWindows(@ptrCast(&quitApplicationWindowProc), @intCast(@intFromPtr(&ctx)));
}

pub fn getWindowList(self: *Self, allocator: std.mem.Allocator) !std.array_list.Managed(common.DesktopWindow) {
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
        defer _ = desktop.Release();
        var desktop_id = std.mem.zeroes(w.GUID);
        if (desktop.GetID(&desktop_id) == 0) {
            try desktopsMap.put(desktop_id, i);
        }
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

        const stable_id = try self.stableIdForWindow(hwnd, allocator);
        errdefer allocator.free(stable_id);

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

        var desktop_id = std.mem.zeroes(w.GUID);
        const desktop_result = self.desktopManager.GetWindowDesktopId(hwnd, &desktop_id);

        try windowList.append(common.DesktopWindow{
            .stable_id = stable_id,
            .platform_handle = @intFromPtr(hwnd),
            .title = title,
            .title_lower = title_lower,
            .app_id = app_id,
            .app_id_lower = app_id_lower,
            .icon = icon_opt,
            .desktopNumber = if (desktop_result == 0) desktopsMap.get(desktop_id) else null,
            .can_close = canCloseWindow(hwnd),
            .allocator = allocator,
        });
    }
    return windowList;
}

const WindowIdentity = struct {
    pid: w.DWORD,
    hwnd_value: usize,
    generation: u64,
};

fn stableIdForWindow(self: *Self, hwnd: w.HWND, allocator: std.mem.Allocator) ![:0]u8 {
    var pid: w.DWORD = 0;
    if (w.GetWindowThreadProcessId(hwnd, &pid) == 0 or pid == 0) return error.InvalidWindow;

    const hwnd_value = @intFromPtr(hwnd);
    const generation = self.window_generations.get(hwnd_value) orelse blk: {
        const next = self.next_window_generation;
        self.next_window_generation +%= 1;
        if (self.next_window_generation == 0) self.next_window_generation = 1;
        try self.window_generations.put(hwnd_value, next);
        break :blk next;
    };

    return std.fmt.allocPrintSentinel(
        allocator,
        "win:{d}:{x}:{d}",
        .{ pid, hwnd_value, generation },
        0,
    );
}

fn parseStableId(stable_id: []const u8) ?WindowIdentity {
    var parts = std.mem.splitScalar(u8, stable_id, ':');
    if (!std.mem.eql(u8, parts.next() orelse return null, "win")) return null;
    const pid_text = parts.next() orelse return null;
    const hwnd_text = parts.next() orelse return null;
    const generation_text = parts.next() orelse return null;
    if (parts.next() != null or pid_text.len == 0 or hwnd_text.len == 0 or generation_text.len == 0) return null;

    return .{
        .pid = std.fmt.parseInt(w.DWORD, pid_text, 10) catch return null,
        .hwnd_value = std.fmt.parseInt(usize, hwnd_text, 16) catch return null,
        .generation = std.fmt.parseInt(u64, generation_text, 10) catch return null,
    };
}

fn resolveStableId(self: *Self, stable_id: []const u8) ?w.HWND {
    const identity = parseStableId(stable_id) orelse return null;
    if (identity.pid == 0 or identity.hwnd_value == 0 or identity.generation == 0) return null;
    if (self.window_generations.get(identity.hwnd_value) != identity.generation) return null;

    const hwnd: w.HWND = @ptrFromInt(identity.hwnd_value);
    if (w.IsWindow(hwnd) == 0) return null;

    var current_pid: w.DWORD = 0;
    if (w.GetWindowThreadProcessId(hwnd, &current_pid) == 0 or current_pid != identity.pid) return null;
    return hwnd;
}

fn canCloseWindow(hwnd: w.HWND) bool {
    const menu = w.GetSystemMenu(hwnd, 0) orelse return false;
    const state = w.GetMenuState(menu, w.SC_CLOSE, w.MF_BYCOMMAND);
    if (state == std.math.maxInt(w.UINT)) return false;
    return state & (w.MF_DISABLED | w.MF_GRAYED) == 0;
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

fn applicationPidForWindow(hwnd: w.HWND) w.DWORD {
    const process_window = if (isUwpFrame(hwnd)) getUwpContentWindow(hwnd) orelse hwnd else hwnd;
    var pid: w.DWORD = 0;
    _ = w.GetWindowThreadProcessId(process_window, &pid);
    return pid;
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
            // WM_GETICON returns a handle owned by the target window. Copy it
            // so the enumeration caller can destroy its result safely.
            const copy = w.CopyIcon(@ptrFromInt(iconAddr));
            if (copy != null) return copy;
        }
    }

    for ([_]c_int{ w.GCLP_HICON, w.GCLP_HICONSM }) |which| {
        const ptr = w.GetClassLongPtrW(realHwnd, which);
        if (ptr != 0) {
            // Class icons are shared; take an owned copy before returning.
            const copy = w.CopyIcon(@ptrFromInt(ptr));
            if (copy != null) return copy;
        }
    }

    if (try extractIconFromExecutable(realHwnd)) |icon| return icon;

    const shared = w.LoadIconW(null, @ptrFromInt(32512));
    if (shared == null) return error.NoWindowIcon;
    return w.CopyIcon(shared) orelse error.NoWindowIcon;
}

fn getWindowFilePath(hwnd: w.HWND, allocator: std.mem.Allocator) !?[:0]u16 {
    var pid: w.DWORD = 0;
    if (w.GetWindowThreadProcessId(hwnd, &pid) == 0 or pid == 0) return null;
    const hProc: w.HANDLE = w.OpenProcess(w.PROCESS_QUERY_INFORMATION | w.PROCESS_VM_READ, 0, pid);
    if (hProc == null) return null;
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
        var ownerPwi = std.mem.zeroes(w.WINDOWINFO);
        ownerPwi.cbSize = @sizeOf(w.WINDOWINFO);
        if (w.GetWindowInfo(owner, &ownerPwi) == 0) return false;
        ownerVisible = ownerPwi.dwStyle & @as(c_ulong, @intCast(w.WS_VISIBLE)) != 0;
    }

    var pwi = std.mem.zeroes(w.WINDOWINFO);
    pwi.cbSize = @sizeOf(w.WINDOWINFO);
    if (w.GetWindowInfo(hwnd, &pwi) == 0) return false;

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
