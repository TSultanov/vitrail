// KDE Plasma backend — talks to KWin's KRunner WindowsRunner over D-Bus.
//
// KWin 6.x exposes its window list through the standard KRunner protocol at
// org.kde.KWin /WindowsRunner org.kde.krunner1. Match("") returns every visible
// window as an array of (matchId, title, iconName, type, relevance, props),
// and Run(matchId, "") activates the window. This is unprivileged-client safe,
// unlike org_kde_plasma_window_management which KWin gates.

const std = @import("std");
const common = @import("../../common/DesktopWindow.zig");

const c = @cImport({
    @cInclude("systemd/sd-bus.h");
});

const Self = @This();

pub const ProbeError = error{ ServiceUnavailable, BusOpen, Probe };

/// Per-window record. `matchId` is the KRunner activator key, kept in our
/// allocator so DesktopWindow.platform_handle can index us back.
const Entry = struct {
    title: [:0]u8,
    icon_name: [:0]u8,
    match_id: [:0]u8,
    allocator: std.mem.Allocator,

    fn destroy(self: Entry) void {
        self.allocator.free(self.title);
        self.allocator.free(self.icon_name);
        self.allocator.free(self.match_id);
    }
};

const SERVICE = "org.kde.KWin";
const PATH = "/WindowsRunner";
const IFACE = "org.kde.krunner1";

allocator: std.mem.Allocator,
bus: ?*c.sd_bus,
entries: std.ArrayListUnmanaged(Entry),

/// Open the user bus and confirm KWin owns `org.kde.KWin`. Returns
/// `error.ServiceUnavailable` when the service isn't present (e.g. running
/// under sway), so the dispatcher can fall back cleanly.
pub fn init(allocator: std.mem.Allocator) !Self {
    var bus: ?*c.sd_bus = null;
    if (c.sd_bus_open_user(&bus) < 0) return ProbeError.BusOpen;
    errdefer _ = c.sd_bus_unref(bus);

    if (try nameHasOwner(bus, SERVICE) == false) return ProbeError.ServiceUnavailable;

    return .{
        .allocator = allocator,
        .bus = bus,
        .entries = .{},
    };
}

pub fn deinit(self: *Self) void {
    self.clearEntries();
    self.entries.deinit(self.allocator);
    _ = c.sd_bus_unref(self.bus);
}

pub fn getWindowList(self: *Self, allocator: std.mem.Allocator) !std.array_list.Managed(common.DesktopWindow) {
    self.clearEntries();
    try self.matchAll();

    std.log.debug("KdeBackend: {d} windows from KRunner", .{self.entries.items.len});

    var list = std.array_list.Managed(common.DesktopWindow).init(allocator);
    errdefer {
        for (list.items) |dw| dw.destroy();
        list.deinit();
    }

    for (self.entries.items, 0..) |entry, idx| {
        const title = try allocator.dupeZ(u8, entry.title);
        errdefer allocator.free(title);
        const title_lower = try allocator.dupeZ(u8, entry.title);
        errdefer allocator.free(title_lower);
        for (title_lower) |*ch| ch.* = std.ascii.toLower(ch.*);
        // No real app_id from KRunner; iconName is the closest stable proxy.
        // Falls back to title for ColorHash determinism if missing.
        const app_id_src = if (entry.icon_name.len > 0) entry.icon_name else entry.title;
        const app_id = try allocator.dupeZ(u8, app_id_src);
        errdefer allocator.free(app_id);

        try list.append(.{
            .platform_handle = idx,
            .title = title,
            .title_lower = title_lower,
            .app_id = app_id,
            .icon = null,
            .desktopNumber = null,
            .allocator = allocator,
        });
    }

    return list;
}

pub fn activateWindow(self: *Self, dw: common.DesktopWindow) void {
    const idx = dw.platform_handle;
    if (idx >= self.entries.items.len) return;
    const match_id = self.entries.items[idx].match_id;

    var err: c.sd_bus_error = .{ .name = null, .message = null, ._need_free = 0 };
    defer c.sd_bus_error_free(&err);
    var reply: ?*c.sd_bus_message = null;
    defer _ = c.sd_bus_message_unref(reply);

    const r = c.sd_bus_call_method(
        self.bus,
        SERVICE,
        PATH,
        IFACE,
        "Run",
        &err,
        &reply,
        "ss",
        match_id.ptr,
        @as([*c]const u8, ""),
    );
    if (r < 0) {
        std.log.err("KdeBackend.activateWindow: Run failed: {s}", .{cstr(err.message)});
    }
}

// ─── Internals ────────────────────────────────────────────────────────────────

fn clearEntries(self: *Self) void {
    for (self.entries.items) |entry| entry.destroy();
    self.entries.clearRetainingCapacity();
}

fn matchAll(self: *Self) !void {
    var err: c.sd_bus_error = .{ .name = null, .message = null, ._need_free = 0 };
    defer c.sd_bus_error_free(&err);
    var reply: ?*c.sd_bus_message = null;
    defer _ = c.sd_bus_message_unref(reply);

    const r = c.sd_bus_call_method(
        self.bus,
        SERVICE,
        PATH,
        IFACE,
        "Match",
        &err,
        &reply,
        "s",
        @as([*c]const u8, ""),
    );
    if (r < 0) {
        std.log.err("KdeBackend.matchAll: Match failed: {s}", .{cstr(err.message)});
        return error.MatchFailed;
    }

    // Reply signature: a(sssida{sv})
    const TYPE_ARRAY: u8 = @intCast(c.SD_BUS_TYPE_ARRAY);
    const TYPE_STRUCT: u8 = @intCast(c.SD_BUS_TYPE_STRUCT);
    if (c.sd_bus_message_enter_container(reply, TYPE_ARRAY, "(sssida{sv})") < 0) return error.UnexpectedReply;

    while (true) {
        const stepped = c.sd_bus_message_enter_container(reply, TYPE_STRUCT, "sssida{sv}");
        if (stepped == 0) break;
        if (stepped < 0) return error.UnexpectedReply;

        var match_id_raw: [*c]const u8 = null;
        var title_raw: [*c]const u8 = null;
        var icon_raw: [*c]const u8 = null;
        var type_i: i32 = 0;
        var relevance: f64 = 0;

        if (c.sd_bus_message_read(reply, "sssid", &match_id_raw, &title_raw, &icon_raw, &type_i, &relevance) < 0)
            return error.UnexpectedReply;

        // Skip the a{sv} props dict — we don't need subtext / icon-data yet.
        if (c.sd_bus_message_skip(reply, "a{sv}") < 0) return error.UnexpectedReply;

        if (c.sd_bus_message_exit_container(reply) < 0) return error.UnexpectedReply;

        // KWin's WindowsRunner emits one match per (window, action) pair —
        // for an empty query that means several actions per window, so 2
        // windows can come back as 8+ entries (most repeated). We don't
        // know KWin's matchId format reliably across versions, so dedupe
        // by title: same window ⇒ same title.
        const title_str = cstr(title_raw);

        // Skip system/internal windows the user can't meaningfully switch to:
        //  - empty titles (placeholder/private windows)
        //  - "Wayland to X" (the XWayland bridge process)
        if (title_str.len == 0) continue;
        if (std.mem.startsWith(u8, title_str, "Wayland to X")) continue;

        var dup = false;
        for (self.entries.items) |existing| {
            if (std.mem.eql(u8, existing.title, title_str)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;

        const entry = Entry{
            .title = try self.allocator.dupeZ(u8, title_str),
            .icon_name = try self.allocator.dupeZ(u8, cstr(icon_raw)),
            .match_id = try self.allocator.dupeZ(u8, cstr(match_id_raw)),
            .allocator = self.allocator,
        };
        errdefer entry.destroy();
        try self.entries.append(self.allocator, entry);
    }

    _ = c.sd_bus_message_exit_container(reply);
}

fn nameHasOwner(bus: ?*c.sd_bus, name: [*:0]const u8) !bool {
    var err: c.sd_bus_error = .{ .name = null, .message = null, ._need_free = 0 };
    defer c.sd_bus_error_free(&err);
    var reply: ?*c.sd_bus_message = null;
    defer _ = c.sd_bus_message_unref(reply);

    const r = c.sd_bus_call_method(
        bus,
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "NameHasOwner",
        &err,
        &reply,
        "s",
        name,
    );
    if (r < 0) return ProbeError.Probe;

    var owned: c_int = 0;
    if (c.sd_bus_message_read(reply, "b", &owned) < 0) return ProbeError.Probe;
    return owned != 0;
}

fn cstr(p: [*c]const u8) []const u8 {
    if (p == null) return "";
    return std.mem.span(@as([*:0]const u8, @ptrCast(p)));
}
