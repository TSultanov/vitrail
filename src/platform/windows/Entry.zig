const wh = @import("windows.zig");
const w = wh.c;
const std = @import("std");
const zw = std.os.windows;
const MainPresenter = @import("../../MainPresenter.zig");
const Config = @import("../../common/Config.zig");
const MouseButtons = @import("MouseButtons.zig");
const SettingsWindow = @import("SettingsWindow.zig");

const HOTKEY_ID: c_int = 0;
// Posted to the thread queue by the low-level mouse hook when the configured
// button is pressed; handled in the message loop like WM_HOTKEY.
const WM_VITRAIL_SHOW: c_uint = @as(c_uint, @intCast(w.WM_APP)) + 1;

/// Resident state the WM_HOTKEY branch, the low-level mouse hook, and the
/// settings "apply" path all read. Single-threaded app, so a module-global is
/// the simplest seam to the Win32 callbacks.
const AppState = struct {
    presenter: *MainPresenter,
    settings: Config.Settings,
    hInstance: w.HINSTANCE,
    mouse_hook: w.HHOOK = null,
    settings_window: ?*SettingsWindow = null,
    // True while the settings UI is recording a binding: the global triggers are
    // suppressed so the pressed combo/button is captured there, not fired.
    suppressed: bool = false,
};
var g_app: AppState = undefined;

/// The overlay asked to open settings (presenter already hid it). Reuses the
/// window if already created.
fn onOpenSettings(_: *anyopaque) void {
    if (g_app.settings_window) |sw| {
        sw.show();
        return;
    }
    const sw = SettingsWindow.create(g_app.hInstance, std.heap.page_allocator, &g_app.settings, onApply, onSuppress, &g_app) catch |err| {
        std.log.warn("settings window failed: {s}", .{@errorName(err)});
        return;
    };
    g_app.settings_window = sw;
    sw.show();
}

/// A binding changed in the settings UI: re-register the hotkey and persist.
/// The mouse hook reads `settings.mouse` live, so it needs no update here. While
/// suppressed (mid-recording) the hotkey stays unregistered; onSuppress
/// re-registers it from the final binding when recording ends.
fn onApply(_: *anyopaque) void {
    if (!g_app.suppressed) {
        _ = w.UnregisterHotKey(null, HOTKEY_ID);
        registerHotkey(g_app.settings.keyboard);
    }
    Config.save(g_app.settings, std.heap.page_allocator) catch |err| {
        std.log.warn("config save failed: {s}", .{@errorName(err)});
    };
}

/// Suppress (or restore) the global triggers while the settings UI records. The
/// low-level mouse hook reads `g_app.suppressed` live; the keyboard hotkey must
/// actually be unregistered so the keydown reaches the settings window.
fn onSuppress(_: *anyopaque, suppress: bool) void {
    if (g_app.suppressed == suppress) return;
    g_app.suppressed = suppress;
    if (suppress) {
        _ = w.UnregisterHotKey(null, HOTKEY_ID);
    } else {
        registerHotkey(g_app.settings.keyboard);
    }
}

/// System-wide mouse hook: posts a show request when the configured button is
/// pressed and swallows that click. All other buttons pass straight through.
fn lowLevelMouseProc(nCode: c_int, wParam: w.WPARAM, lParam: w.LPARAM) callconv(.winapi) w.LRESULT {
    if (nCode == w.HC_ACTION and !g_app.suppressed and g_app.settings.mouse_enabled) {
        const info: *w.MSLLHOOKSTRUCT = @ptrFromInt(@as(usize, @bitCast(lParam)));
        const ev = MouseButtons.classify(@as(u32, @intCast(wParam)), info.mouseData);
        if (MouseButtons.matches(g_app.settings.mouse, ev)) {
            _ = w.PostMessageW(null, WM_VITRAIL_SHOW, 0, 0);
            return 1; // swallow the trigger click
        }
    }
    return w.CallNextHookEx(null, nCode, wParam, lParam);
}

fn winMods(mods: Config.Mods) c_uint {
    var m: u32 = 0;
    if (mods.shift) m |= @as(u32, @intCast(w.MOD_SHIFT));
    if (mods.control) m |= @as(u32, @intCast(w.MOD_CONTROL));
    if (mods.alt) m |= @as(u32, @intCast(w.MOD_ALT));
    if (mods.super) m |= @as(u32, @intCast(w.MOD_WIN));
    return @as(c_uint, m);
}

fn registerHotkey(kb: Config.KeyBinding) void {
    _ = w.RegisterHotKey(null, HOTKEY_ID, winMods(kb.mods), @as(c_uint, @intCast(kb.keycode)));
}

/// Alt+Space — the built-in fallback when there is no saved config.
fn defaultKeyboard() Config.KeyBinding {
    return .{ .keycode = @as(u32, @intCast(w.VK_SPACE)), .mods = .{ .alt = true } };
}

pub export fn wWinMain(hInstance: w.HINSTANCE, hPrevInstance: w.HINSTANCE, pCmdLine: w.LPWSTR, nCmdShow: c_int) callconv(.winapi) c_int {
    _ = hPrevInstance;
    _ = pCmdLine;
    _ = nCmdShow;

    const hInstanceWinApi: w.HINSTANCE = @ptrCast(@alignCast(hInstance));
    _ = w.CoInitializeEx(null, 0x2);

    var picce = w.INITCOMMONCONTROLSEX{ .dwSize = @sizeOf(w.INITCOMMONCONTROLSEX), .dwICC = 0xff };

    _ = w.InitCommonControlsEx(&picce);

    var gpa: std.heap.DebugAllocator(.{ .safety = true }) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const test_mode = parseTestMode(gpa.allocator()) catch false;

    var main_presenter = MainPresenter.init(.{ .hInstance = hInstanceWinApi }, std.heap.page_allocator, test_mode) catch unreachable;

    const settings = Config.loadOrDefault(std.heap.page_allocator, .{ .keyboard = defaultKeyboard() });
    g_app = .{ .presenter = main_presenter, .settings = settings, .hInstance = hInstanceWinApi };

    // The overlay's Ctrl+, routes here (via the presenter) to open settings.
    main_presenter.setOpenSettings(onOpenSettings, &g_app);

    if (!test_mode) {
        registerHotkey(g_app.settings.keyboard);
        // HOOKPROC translates to a variadic fn pointer; cast our typed proc.
        g_app.mouse_hook = w.SetWindowsHookExW(w.WH_MOUSE_LL, @ptrCast(&lowLevelMouseProc), w.GetModuleHandleW(null), 0);
    }

    if (test_mode) {
        main_presenter.show() catch unreachable;
    }

    var msg: w.MSG = undefined;
    while (w.GetMessageW(&msg, null, 0, 0) != 0) {
        if (msg.message == w.WM_HOTKEY) {
            main_presenter.show() catch unreachable;
        } else if (msg.message == WM_VITRAIL_SHOW) {
            // Mouse-button trigger: center under the pointer when enabled.
            if (g_app.settings.center_on_cursor) {
                main_presenter.showAtCursor() catch unreachable;
            } else {
                main_presenter.show() catch unreachable;
            }
        } else {
            _ = w.TranslateMessage(&msg);
            _ = w.DispatchMessageW(&msg);
        }
    }

    if (g_app.mouse_hook) |h| _ = w.UnhookWindowsHookEx(h);

    return 0;
}

fn parseTestMode(allocator: std.mem.Allocator) !bool {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--test-mode")) return true;
    }
    return false;
}
