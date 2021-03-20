pub const std = @import("std");
pub const w = @cImport({
    @cInclude("windows.h");
    @cInclude("commctrl.h");
});
pub const zw = std.os.windows;
pub const toUtf16const = @import("system_interaction.zig").toUtf16const;
pub const toUtf16 = @import("system_interaction.zig").toUtf16;