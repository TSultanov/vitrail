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
/// `platform_handle` is an opaque value whose meaning is defined by the platform layer;
/// MainPresenter never dereferences it — it passes the whole DesktopWindow back to
/// SystemInteraction.activateWindow().
pub const DesktopWindow = struct {
    platform_handle: usize, // Win32: @intFromPtr(HWND); Wayland: index into handle table
    title: [:0]u8, // UTF-8, allocator-owned
    title_lower: [:0]u8, // UTF-8 lowercase for search, allocator-owned
    app_id: [:0]u8, // Win32 class name or Wayland app_id; used for color hashing
    icon: ?RgbaIcon,
    desktopNumber: ?usize,
    allocator: std.mem.Allocator,

    pub fn destroy(self: DesktopWindow) void {
        self.allocator.free(self.title);
        self.allocator.free(self.title_lower);
        self.allocator.free(self.app_id);
        if (self.icon) |ic| ic.destroy();
    }
};
