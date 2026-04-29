// KDE Plasma backend — talks to KWin via the Scripting D-Bus API.
//
// KWin's Scripting interface (org.kde.kwin.Scripting at /Scripting) lets an
// unprivileged client load a small JavaScript snippet that runs inside the
// compositor with full access to `workspace.windowList()`. We use that to
// enumerate windows server-side, applying KWin's own classification flags
// (`normalWindow`, `skipSwitcher`) to filter out desktops, docks, splashes,
// notifications, OSDs, the XWayland bridge, etc. — replacing the old fragile
// KRunner approach that needed string-match hacks per system window.
//
// The script ships its result back to us via `callDBus(...)` to a method we
// expose on our own bus connection. For activation, the script just sets
// `workspace.activeWindow` and needs no reply.

const std = @import("std");
const common = @import("../../common/DesktopWindow.zig");

const c = @cImport({
    @cInclude("systemd/sd-bus.h");
});

const Self = @This();

pub const ProbeError = error{ ServiceUnavailable, BusOpen, Probe };

const Entry = struct {
    title: [:0]u8,
    app_id: [:0]u8,
    uuid: [:0]u8, // KWin internalId, used to address the window for activation
    desktop: ?usize, // 0-based; renderer adds 1 for display
    allocator: std.mem.Allocator,

    fn destroy(self: Entry) void {
        self.allocator.free(self.title);
        self.allocator.free(self.app_id);
        self.allocator.free(self.uuid);
    }
};

const SERVICE = "org.kde.KWin";
const SCRIPTING_PATH = "/Scripting";
const SCRIPTING_IFACE = "org.kde.kwin.Scripting";
const SCRIPT_IFACE = "org.kde.kwin.Script";
const IPC_PATH = "/vitrail";
const IPC_IFACE = "org.vitrail.IPC";

allocator: std.mem.Allocator,
bus: ?*c.sd_bus,
entries: std.ArrayListUnmanaged(Entry),
ipc_slot: ?*c.sd_bus_slot = null,
// Filled in by the IPC.Submit handler when the enumeration script reports.
pending_payload: ?[]u8 = null,

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
    if (self.ipc_slot) |s| _ = c.sd_bus_slot_unref(s);
    if (self.pending_payload) |p| self.allocator.free(p);
    self.clearEntries();
    self.entries.deinit(self.allocator);
    _ = c.sd_bus_unref(self.bus);
}

pub fn getWindowList(self: *Self, allocator: std.mem.Allocator) !std.array_list.Managed(common.DesktopWindow) {
    self.clearEntries();
    try self.runEnumScript();

    std.log.debug("KdeBackend: {d} windows from KWin scripting", .{self.entries.items.len});

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
        const app_id_src = if (entry.app_id.len > 0) entry.app_id else entry.title;
        const app_id = try allocator.dupeZ(u8, app_id_src);
        errdefer allocator.free(app_id);

        try list.append(.{
            .platform_handle = idx,
            .title = title,
            .title_lower = title_lower,
            .app_id = app_id,
            .icon = null,
            .desktopNumber = entry.desktop,
            .allocator = allocator,
        });
    }

    return list;
}

pub fn activateWindow(self: *Self, dw: common.DesktopWindow) void {
    const idx = dw.platform_handle;
    if (idx >= self.entries.items.len) return;
    const uuid = self.entries.items[idx].uuid;

    var script_buf: [512]u8 = undefined;
    const script = std.fmt.bufPrint(&script_buf,
        \\const target = "{s}";
        \\const w = workspace.windowList().find(w => w.internalId.toString() === target);
        \\if (w) {{ workspace.activeWindow = w; }}
        \\
    , .{uuid}) catch return;

    self.runScript(script, "vitrail-activate") catch |e| {
        std.log.err("KdeBackend.activateWindow: {t}", .{e});
    };
}

// ─── Internals ────────────────────────────────────────────────────────────────

fn clearEntries(self: *Self) void {
    for (self.entries.items) |entry| entry.destroy();
    self.entries.clearRetainingCapacity();
}

const enum_script_template =
    \\const me = "{s}";
    \\const wins = workspace.windowList()
    \\  .filter(w => w.normalWindow && !w.skipSwitcher)
    \\  .map(w => ({{
    \\    id: w.internalId.toString(),
    \\    title: w.caption,
    \\    app: w.resourceClass,
    \\    desk: (w.desktops && w.desktops.length > 0) ? w.desktops[0].x11DesktopNumber : null,
    \\  }}));
    \\callDBus(me, "/vitrail", "org.vitrail.IPC", "Submit", JSON.stringify(wins));
    \\
;

fn runEnumScript(self: *Self) !void {
    // Get the bus connection's unique name so the KWin script can callDBus
    // back to us.
    var unique_name_raw: [*c]const u8 = null;
    if (c.sd_bus_get_unique_name(self.bus, &unique_name_raw) < 0) return error.NoUniqueName;
    const unique_name = cstr(unique_name_raw);

    // Register an object handling org.vitrail.IPC.Submit if not already.
    if (self.ipc_slot == null) {
        var slot: ?*c.sd_bus_slot = null;
        const r = vitrail_register_ipc(self.bus, &slot, IPC_PATH, IPC_IFACE, self);
        if (r < 0) return error.AddObjectVtable;
        self.ipc_slot = slot;
    }

    var script_buf: [1024]u8 = undefined;
    const script = try std.fmt.bufPrint(&script_buf, enum_script_template, .{unique_name});

    if (self.pending_payload) |p| {
        self.allocator.free(p);
        self.pending_payload = null;
    }

    try self.runScript(script, "vitrail-enum");

    // Pump the bus for up to 2 seconds waiting for the script to call us back.
    const deadline_ns = std.time.nanoTimestamp() + 2 * std.time.ns_per_s;
    while (self.pending_payload == null) {
        const now = std.time.nanoTimestamp();
        if (now >= deadline_ns) return error.EnumTimeout;
        const timeout_us: u64 = @intCast(@divTrunc(deadline_ns - now, std.time.ns_per_us));
        _ = c.sd_bus_process(self.bus, null);
        if (self.pending_payload != null) break;
        _ = c.sd_bus_wait(self.bus, timeout_us);
    }

    const json = self.pending_payload.?;
    defer {
        self.allocator.free(json);
        self.pending_payload = null;
    }

    try self.parsePayload(json);
}

const WindowJson = struct {
    id: []const u8,
    title: []const u8,
    app: []const u8,
    desk: ?u32 = null,
};

fn parsePayload(self: *Self, json: []const u8) !void {
    var parsed = try std.json.parseFromSlice([]WindowJson, self.allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    for (parsed.value) |w| {
        const desktop: ?usize = if (w.desk) |d| (if (d >= 1) d - 1 else 0) else null;
        const entry = Entry{
            .title = try self.allocator.dupeZ(u8, w.title),
            .app_id = try self.allocator.dupeZ(u8, w.app),
            .uuid = try self.allocator.dupeZ(u8, w.id),
            .desktop = desktop,
            .allocator = self.allocator,
        };
        errdefer entry.destroy();
        try self.entries.append(self.allocator, entry);
    }
}

/// Write `script` to a fresh temp file, loadScript + run + unloadScript.
fn runScript(self: *Self, script: []const u8, plugin_name: [*:0]const u8) !void {
    // Build a per-call unique temp path. Zig's posix doesn't expose mkstemp,
    // and a (pid, monotonic-ns) suffix is unique enough — the file is
    // unlinked moments later.
    var path_buf: [64:0]u8 = undefined;
    const tmpl = try std.fmt.bufPrintZ(&path_buf, "/tmp/vitrail-kwin-{d}-{d}.js", .{ std.os.linux.getpid(), std.time.nanoTimestamp() });

    {
        const file = try std.fs.cwd().createFileZ(tmpl, .{ .exclusive = true });
        defer file.close();
        try file.writeAll(script);
    }
    defer std.fs.cwd().deleteFileZ(tmpl) catch {};

    var err: c.sd_bus_error = .{ .name = null, .message = null, ._need_free = 0 };
    defer c.sd_bus_error_free(&err);

    var reply: ?*c.sd_bus_message = null;
    defer _ = c.sd_bus_message_unref(reply);

    const r1 = c.sd_bus_call_method(
        self.bus,
        SERVICE,
        SCRIPTING_PATH,
        SCRIPTING_IFACE,
        "loadScript",
        &err,
        &reply,
        "ss",
        tmpl.ptr,
        plugin_name,
    );
    if (r1 < 0) {
        std.log.err("KdeBackend.runScript: loadScript failed: {s}", .{cstr(err.message)});
        return error.LoadScript;
    }

    var script_id: i32 = 0;
    if (c.sd_bus_message_read(reply, "i", &script_id) < 0) return error.LoadScript;

    var script_path_buf: [64]u8 = undefined;
    const script_path = try std.fmt.bufPrintZ(&script_path_buf, "/Scripting/Script{d}", .{script_id});

    var run_reply: ?*c.sd_bus_message = null;
    defer _ = c.sd_bus_message_unref(run_reply);
    const r2 = c.sd_bus_call_method(
        self.bus,
        SERVICE,
        script_path.ptr,
        SCRIPT_IFACE,
        "run",
        &err,
        &run_reply,
        "",
    );
    if (r2 < 0) {
        std.log.err("KdeBackend.runScript: run failed: {s}", .{cstr(err.message)});
        // try to clean up regardless
    }

    var unload_reply: ?*c.sd_bus_message = null;
    defer _ = c.sd_bus_message_unref(unload_reply);
    _ = c.sd_bus_call_method(
        self.bus,
        SERVICE,
        SCRIPTING_PATH,
        SCRIPTING_IFACE,
        "unloadScript",
        null,
        &unload_reply,
        "s",
        plugin_name,
    );
}

// IPC: KWin script calls Submit(string json) on us. Vtable wired in C
// (see kde_dbus_shim.c); this is the method handler the C side delegates to.
extern fn vitrail_register_ipc(bus: ?*c.sd_bus, slot: *?*c.sd_bus_slot, path: [*:0]const u8, iface: [*:0]const u8, userdata: ?*anyopaque) c_int;

export fn vitrail_ipc_submit_handler(msg: ?*c.sd_bus_message, userdata: ?*anyopaque, _: ?*c.sd_bus_error) callconv(.c) c_int {
    const self: *Self = @ptrCast(@alignCast(userdata));
    var payload_raw: [*c]const u8 = null;
    if (c.sd_bus_message_read(msg, "s", &payload_raw) < 0) return -1;
    const payload = cstr(payload_raw);

    if (self.pending_payload) |p| self.allocator.free(p);
    self.pending_payload = self.allocator.dupe(u8, payload) catch null;

    _ = c.sd_bus_reply_method_return(msg, "");
    return 1;
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
