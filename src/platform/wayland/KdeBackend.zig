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
const RefreshWait = @import("RefreshWait.zig");

const c = @cImport({
    @cInclude("systemd/sd-bus.h");
});

const Self = @This();

pub const ProbeError = error{ ServiceUnavailable, BusOpen, Probe };
pub const WaitPump = *const fn (ctx: *anyopaque) bool;

const Entry = struct {
    title: [:0]u8,
    app_id: [:0]u8,
    uuid: [:0]u8, // KWin internalId, used to address the window for activation
    can_close: bool,
    desktop: ?usize, // 0-based; renderer adds 1 for display
    desktop_file: ?[:0]u8, // Window.desktopFileName from KWin; null if KWin didn't have one
    allocator: std.mem.Allocator,

    fn destroy(self: Entry) void {
        self.allocator.free(self.title);
        self.allocator.free(self.app_id);
        self.allocator.free(self.uuid);
        if (self.desktop_file) |df| self.allocator.free(df);
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
watcher_plugin: ?[:0]u8 = null,
dirty: bool = false,
wait_pump: ?WaitPump = null,
wait_pump_ctx: ?*anyopaque = null,

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
    if (self.watcher_plugin) |plugin| {
        self.unloadScript(plugin) catch {};
        self.allocator.free(plugin);
    }
    if (self.ipc_slot) |s| _ = c.sd_bus_slot_unref(s);
    if (self.pending_payload) |p| self.allocator.free(p);
    self.clearEntries();
    self.entries.deinit(self.allocator);
    _ = c.sd_bus_unref(self.bus);
}

pub fn eventFd(self: *const Self) ?std.posix.fd_t {
    const fd = c.sd_bus_get_fd(self.bus);
    return if (fd >= 0) @intCast(fd) else null;
}

/// Called between short sd-bus wait slices while a KWin enumeration script is
/// outstanding. MainWindow uses it to read and dispatch its own Wayland
/// connection, keeping pointer hover responsive without sharing either
/// backend's protocol objects.
pub fn setWaitPump(self: *Self, callback: WaitPump, ctx: *anyopaque) void {
    self.wait_pump = callback;
    self.wait_pump_ctx = ctx;
}

/// Consume all queued watcher notifications after eventFd() becomes readable.
pub fn dispatchPending(self: *Self) void {
    while (true) {
        const r = c.sd_bus_process(self.bus, null);
        if (r <= 0) break;
    }
    self.dirty = false;
}

pub fn hasPendingChanges(self: *const Self) bool {
    return self.dirty;
}

pub fn getWindowList(self: *Self, allocator: std.mem.Allocator) !std.array_list.Managed(common.DesktopWindow) {
    try self.ensureWatcher();
    self.dirty = false;
    try self.runEnumScript();
    // runEnumScript pumps sd-bus while awaiting its payload. If that consumes
    // a watcher notification from a concurrent window change, take one
    // coalesced trailing snapshot now; the bus fd is no longer readable, so
    // MainWindow would otherwise have no reason to schedule it.
    if (self.dirty) {
        self.dirty = false;
        try self.runEnumScript();
    }

    std.log.debug("KdeBackend: {d} windows from KWin scripting", .{self.entries.items.len});

    var list = std.array_list.Managed(common.DesktopWindow).init(allocator);
    errdefer {
        for (list.items) |dw| dw.destroy();
        list.deinit();
    }

    for (self.entries.items, 0..) |entry, idx| {
        const stable_id = try allocator.dupeZ(u8, entry.uuid);
        errdefer allocator.free(stable_id);
        const title = try allocator.dupeZ(u8, entry.title);
        errdefer allocator.free(title);
        const title_lower = try allocator.dupeZ(u8, entry.title);
        errdefer allocator.free(title_lower);
        for (title_lower) |*ch| ch.* = std.ascii.toLower(ch.*);
        const app_id_src = if (entry.app_id.len > 0) entry.app_id else entry.title;
        const app_id = try allocator.dupeZ(u8, app_id_src);
        errdefer allocator.free(app_id);
        const app_id_lower = try allocator.dupeZ(u8, app_id_src);
        errdefer allocator.free(app_id_lower);
        for (app_id_lower) |*ch| ch.* = std.ascii.toLower(ch.*);

        const desktop_file: ?[:0]u8 = if (entry.desktop_file) |df|
            try allocator.dupeZ(u8, df)
        else
            null;
        errdefer if (desktop_file) |df| allocator.free(df);

        try list.append(.{
            .stable_id = stable_id,
            .platform_handle = idx,
            .title = title,
            .title_lower = title_lower,
            .app_id = app_id,
            .app_id_lower = app_id_lower,
            .desktop_file = desktop_file,
            .icon = null,
            .desktopNumber = entry.desktop,
            .can_close = entry.can_close,
            .allocator = allocator,
        });
    }

    return list;
}

pub fn activateWindow(self: *Self, dw: common.DesktopWindow) void {
    const entry = self.findEntry(dw.stable_id) orelse return;
    const uuid = entry.uuid;

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

pub fn closeWindow(self: *Self, stable_id: []const u8) void {
    const entry = self.findEntry(stable_id) orelse return;
    if (!entry.can_close) return;

    var script_buf: [640]u8 = undefined;
    const script = std.fmt.bufPrint(&script_buf,
        \\const target = "{s}";
        \\const w = workspace.windowList().find(w => w.internalId.toString() === target);
        \\if (w && w.closeable) {{ w.closeWindow(); }}
        \\
    , .{entry.uuid}) catch return;

    self.runScript(script, "vitrail-close") catch |e| {
        std.log.err("KdeBackend.closeWindow: {t}", .{e});
    };
}

pub fn quitApplication(self: *Self, stable_id: []const u8) void {
    const entry = self.findEntry(stable_id) orelse return;

    var script_buf: [1024]u8 = undefined;
    const script = std.fmt.bufPrint(&script_buf,
        \\const target = "{s}";
        \\const selected = workspace.windowList().find(w => w.internalId.toString() === target);
        \\if (selected) {{
        \\  workspace.windowList()
        \\    .filter(w => w.normalWindow && !w.skipSwitcher && w.resourceClass === selected.resourceClass)
        \\    .forEach(w => {{ if (w.closeable) w.closeWindow(); }});
        \\}}
        \\
    , .{entry.uuid}) catch return;

    self.runScript(script, "vitrail-quit-application") catch |e| {
        std.log.err("KdeBackend.quitApplication: {t}", .{e});
    };
}

// ─── Internals ────────────────────────────────────────────────────────────────

fn clearEntries(self: *Self) void {
    for (self.entries.items) |entry| entry.destroy();
    self.entries.clearRetainingCapacity();
}

fn findEntry(self: *Self, stable_id: []const u8) ?*const Entry {
    for (self.entries.items) |*entry| {
        if (std.mem.eql(u8, entry.uuid, stable_id)) return entry;
    }
    return null;
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
    \\    df: w.desktopFileName || "",
    \\    closeable: !!w.closeable,
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

    try self.ensureIpc();

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

        // KWin can take up to the full two-second deadline to answer. Slice
        // that wait only when the overlay supplied a pump, so its independent
        // Wayland socket keeps delivering pointer and buffer-release events.
        if (self.wait_pump) |pump| {
            if (!pump(self.wait_pump_ctx orelse unreachable)) {
                return error.OverlayStopped;
            }
            // Pumped input may synchronously issue another D-Bus operation,
            // which can receive our enumeration payload as a side effect.
            if (self.pending_payload != null) break;
        }
        _ = c.sd_bus_wait(
            self.bus,
            RefreshWait.timeoutSlice(timeout_us, self.wait_pump != null),
        );
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
    df: []const u8 = "",
    closeable: bool = true,
};

fn parsePayload(self: *Self, json: []const u8) !void {
    var parsed = try std.json.parseFromSlice([]WindowJson, self.allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var fresh: std.ArrayListUnmanaged(Entry) = .{};
    errdefer {
        for (fresh.items) |entry| entry.destroy();
        fresh.deinit(self.allocator);
    }

    for (parsed.value) |w| {
        const desktop: ?usize = if (w.desk) |d| (if (d >= 1) d - 1 else 0) else null;
        const desktop_file: ?[:0]u8 = if (w.df.len > 0) try self.allocator.dupeZ(u8, w.df) else null;
        errdefer if (desktop_file) |df| self.allocator.free(df);
        const title = try self.allocator.dupeZ(u8, w.title);
        errdefer self.allocator.free(title);
        const app_id = try self.allocator.dupeZ(u8, w.app);
        errdefer self.allocator.free(app_id);
        const uuid = try self.allocator.dupeZ(u8, w.id);
        errdefer self.allocator.free(uuid);
        const entry = Entry{
            .title = title,
            .app_id = app_id,
            .uuid = uuid,
            .can_close = w.closeable,
            .desktop = desktop,
            .desktop_file = desktop_file,
            .allocator = self.allocator,
        };
        try fresh.append(self.allocator, entry);
    }

    var old = self.entries;
    self.entries = fresh;
    for (old.items) |entry| entry.destroy();
    old.deinit(self.allocator);
}

const watcher_script_template =
    \\const me = "{s}";
    \\function vitrailChanged() {{
    \\  callDBus(me, "/vitrail", "org.vitrail.IPC", "Submit", "__vitrail_changed__");
    \\}}
    \\function vitrailWatch(w) {{
    \\  const names = ["captionChanged", "desktopsChanged", "minimizedChanged",
    \\    "closeableChanged", "skipSwitcherChanged", "desktopFileNameChanged",
    \\    "windowClassChanged"];
    \\  for (const name of names) {{
    \\    const signal = w[name];
    \\    if (signal && signal.connect) signal.connect(vitrailChanged);
    \\  }}
    \\}}
    \\workspace.windowList().forEach(vitrailWatch);
    \\workspace.windowAdded.connect(w => {{ vitrailWatch(w); vitrailChanged(); }});
    \\workspace.windowRemoved.connect(vitrailChanged);
    \\
;

fn ensureIpc(self: *Self) !void {
    if (self.ipc_slot != null) return;
    var slot: ?*c.sd_bus_slot = null;
    const r = vitrail_register_ipc(self.bus, &slot, IPC_PATH, IPC_IFACE, self);
    if (r < 0) return error.AddObjectVtable;
    self.ipc_slot = slot;
}

fn ensureWatcher(self: *Self) !void {
    if (self.watcher_plugin != null) return;
    try self.ensureIpc();

    var unique_name_raw: [*c]const u8 = null;
    if (c.sd_bus_get_unique_name(self.bus, &unique_name_raw) < 0) return error.NoUniqueName;
    const unique_name = cstr(unique_name_raw);

    var script_buf: [2048]u8 = undefined;
    const script = try std.fmt.bufPrint(&script_buf, watcher_script_template, .{unique_name});
    const plugin = try std.fmt.allocPrintSentinel(
        self.allocator,
        "vitrail-watch-{d}",
        .{std.os.linux.getpid()},
        0,
    );
    errdefer self.allocator.free(plugin);
    try self.runPersistentScript(script, plugin);
    self.watcher_plugin = plugin;
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

/// Load and run a script which remains installed until deinit. Used only for
/// the window lifecycle watcher; one-shot activation/enumeration scripts keep
/// using runScript above.
fn runPersistentScript(self: *Self, script: []const u8, plugin_name: [*:0]const u8) !void {
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

    const load_result = c.sd_bus_call_method(
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
    if (load_result < 0) return error.LoadScript;

    var script_id: i32 = 0;
    if (c.sd_bus_message_read(reply, "i", &script_id) < 0) return error.LoadScript;

    var script_path_buf: [64]u8 = undefined;
    const script_path = try std.fmt.bufPrintZ(&script_path_buf, "/Scripting/Script{d}", .{script_id});
    var run_reply: ?*c.sd_bus_message = null;
    defer _ = c.sd_bus_message_unref(run_reply);
    if (c.sd_bus_call_method(
        self.bus,
        SERVICE,
        script_path.ptr,
        SCRIPT_IFACE,
        "run",
        &err,
        &run_reply,
        "",
    ) < 0) return error.RunScript;
}

fn unloadScript(self: *Self, plugin_name: [*:0]const u8) !void {
    var reply: ?*c.sd_bus_message = null;
    defer _ = c.sd_bus_message_unref(reply);
    if (c.sd_bus_call_method(
        self.bus,
        SERVICE,
        SCRIPTING_PATH,
        SCRIPTING_IFACE,
        "unloadScript",
        null,
        &reply,
        "s",
        plugin_name,
    ) < 0) return error.UnloadScript;
}

// IPC: KWin script calls Submit(string json) on us. Vtable wired in C
// (see kde_dbus_shim.c); this is the method handler the C side delegates to.
extern fn vitrail_register_ipc(bus: ?*c.sd_bus, slot: *?*c.sd_bus_slot, path: [*:0]const u8, iface: [*:0]const u8, userdata: ?*anyopaque) c_int;

export fn vitrail_ipc_submit_handler(msg: ?*c.sd_bus_message, userdata: ?*anyopaque, _: ?*c.sd_bus_error) callconv(.c) c_int {
    const self: *Self = @ptrCast(@alignCast(userdata));
    var payload_raw: [*c]const u8 = null;
    if (c.sd_bus_message_read(msg, "s", &payload_raw) < 0) return -1;
    const payload = cstr(payload_raw);

    if (std.mem.eql(u8, payload, "__vitrail_changed__")) {
        self.dirty = true;
    } else {
        if (self.pending_payload) |p| self.allocator.free(p);
        self.pending_payload = self.allocator.dupe(u8, payload) catch null;
    }

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
