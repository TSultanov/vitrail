// extern declarations for the C symbols exposed by cocoa_bridge.m. Kept in
// hand-written Zig (rather than @cImport) so the build doesn't depend on a
// macOS SDK header path translate-c can find.

pub const VtWindow = opaque {};

pub const KeyCb = *const fn (
    ctx: ?*anyopaque,
    virtual_keycode: c_int,
    modifiers: u32,
    utf8: [*c]const u8,
    utf8_len: c_int,
) callconv(.c) void;

pub const MouseCb = *const fn (
    ctx: ?*anyopaque,
    kind: c_int,
    x: f64,
    y: f64,
) callconv(.c) void;

pub const ResizeCb = *const fn (
    ctx: ?*anyopaque,
    physical_w: u32,
    physical_h: u32,
    logical_w: u32,
    logical_h: u32,
    backing_scale: f64,
) callconv(.c) void;

pub const CloseCb = *const fn (ctx: ?*anyopaque) callconv(.c) void;

pub extern "c" fn vt_app_init() void;
pub extern "c" fn vt_app_pump_one(blocking: c_int) c_int;
pub extern "c" fn vt_app_stop() void;

pub extern "c" fn vt_window_create(
    ctx: ?*anyopaque,
    on_key: KeyCb,
    on_mouse: MouseCb,
    on_resize: ResizeCb,
    on_close: CloseCb,
) ?*VtWindow;
pub extern "c" fn vt_window_show(w: *VtWindow) void;
pub extern "c" fn vt_window_hide(w: *VtWindow) void;
pub extern "c" fn vt_window_destroy(w: *VtWindow) void;
pub extern "c" fn vt_window_set_image(w: *VtWindow, cg_image: ?*const anyopaque) void;
pub extern "c" fn vt_window_logical_size(w: *VtWindow, out_w: *u32, out_h: *u32) void;
pub extern "c" fn vt_window_backing_scale(w: *VtWindow) f64;

pub extern "c" fn vt_activate_pid(pid: c_int) c_int;
pub extern "c" fn vt_reopen_pid(pid: c_int) c_int;
pub extern "c" fn vt_icon_for_pid(
    pid: c_int,
    target_size: c_int,
    out_rgba: *[*]u8,
    out_w: *u32,
    out_h: *u32,
) c_int;
pub extern "c" fn vt_app_name_for_pid(pid: c_int) ?[*:0]u8;

// Returns a malloc'd array of `*out_count` pids for regular-activation-
// policy apps, excluding our own pid. Caller frees with vt_free.
pub extern "c" fn vt_running_pids(out_count: *c_int) ?[*]c_int;
pub extern "c" fn vt_free(p: ?*anyopaque) void;

// Monotonic counter for app activations. Higher = more recently activated.
// Returns 0 for pids the observer hasn't seen.
pub extern "c" fn vt_app_activation_ordinal(pid: c_int) i64;

pub const PidCb = *const fn (pid: c_int) callconv(.c) void;
// Installs main-thread callbacks for NSWorkspaceDidLaunchApplication and
// NSWorkspaceDidTerminateApplication. Idempotent.
pub extern "c" fn vt_install_app_lifecycle_observers(on_launch: PidCb, on_terminate: PidCb) void;
