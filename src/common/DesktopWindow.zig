const std = @import("std");

pub const RgbaIcon = struct {
    pixels: []u8, // RGBA, width*height*4 bytes, top-down row order
    width: u32,
    height: u32,
    allocator: std.mem.Allocator,

    pub fn destroy(self: RgbaIcon) void {
        self.allocator.free(self.pixels);
    }
};

/// Platform-agnostic window descriptor. All strings are UTF-8 and null-terminated.
///
/// `stable_id` is an opaque, platform-defined identity that remains the same
/// across live window-list refreshes. UI state and deferred commands use it
/// instead of titles, array indexes, or native handles (all of which can
/// change or be reused).
///
/// `platform_handle` is an opaque operational token whose meaning is defined
/// by the platform layer. MainPresenter never dereferences it; it passes the
/// whole DesktopWindow back to SystemInteraction after resolving `stable_id`
/// against the current snapshot.
pub const DesktopWindow = struct {
    stable_id: [:0]u8, // allocator-owned exact identity bytes
    platform_handle: usize, // Win32: @intFromPtr(HWND); Wayland: index into handle table
    title: [:0]u8, // UTF-8, allocator-owned
    title_lower: [:0]u8, // UTF-8 lowercase for search, allocator-owned
    app_id: [:0]u8, // Win32 class name or Wayland app_id; used for color hashing
    app_id_lower: [:0]u8, // UTF-8 lowercase of app_id for search, allocator-owned
    // .desktop file basename (no .desktop suffix) the window's compositor
    // associates with this window. KDE provides it via Window.desktopFileName;
    // wlroots/Windows leave it null. Used as a strong icon-lookup hint.
    desktop_file: ?[:0]u8 = null,
    icon: ?RgbaIcon,
    desktopNumber: ?usize,
    can_close: bool = true,
    allocator: std.mem.Allocator,

    pub fn destroy(self: DesktopWindow) void {
        self.allocator.free(self.stable_id);
        self.allocator.free(self.title);
        self.allocator.free(self.title_lower);
        self.allocator.free(self.app_id);
        self.allocator.free(self.app_id_lower);
        if (self.desktop_file) |df| self.allocator.free(df);
        if (self.icon) |ic| ic.destroy();
    }
};
