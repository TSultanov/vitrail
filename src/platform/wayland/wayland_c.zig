// Single shared @cImport so Wayland opaque types are identical across modules.
// (Each @cImport invocation produces distinct opaque types; importing `c` from
// this module keeps all files agreeing on `*wl_display`, `*wl_surface`, etc.)
pub const c = @cImport({
    @cInclude("wayland-client-protocol.h");
    @cInclude("wayland-cursor.h");
    @cInclude("wlr-layer-shell-unstable-v1-client-protocol.h");
    @cInclude("fractional-scale-v1-client-protocol.h");
    @cInclude("viewporter-client-protocol.h");
    @cInclude("xkbcommon/xkbcommon.h");
});
