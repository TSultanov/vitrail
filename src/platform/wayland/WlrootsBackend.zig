const std = @import("std");
const common = @import("../../common/DesktopWindow.zig");

const c = @cImport({
    @cInclude("wayland-client-protocol.h");
    @cInclude("wlr-foreign-toplevel-management-unstable-v1-client-protocol.h");
    @cInclude("plasma-window-management-client-protocol.h");
    @cInclude("plasma-virtual-desktop-client-protocol.h");
});

const Self = @This();

const VirtualDesktopInfo = struct {
    id: []u8,
    position: usize,
    handle: ?*c.org_kde_plasma_virtual_desktop = null,
};

// Heap-allocated per window so pointer stays stable across ArrayList resizes.
const ToplevelEntry = struct {
    title: []const u8,
    app_id: []const u8,
    // wlroots does not expose an identity, so each persistent protocol entry
    // receives a monotonic id. KDE's protocol does expose the exact KWin UUID.
    stable_id: u64,
    kde_uuid: ?[:0]u8 = null,
    desktop_number: ?usize = null,
    legacy_desktop_number: ?usize = null,
    desktop_ids: std.ArrayListUnmanaged([]u8) = .{},
    has_modern_desktop_membership: bool = false,
    minimized: bool = false,
    can_close: bool = true,
    closed: bool = false,
    handle_wlr: ?*c.zwlr_foreign_toplevel_handle_v1 = null,
    handle_kde: ?*c.org_kde_plasma_window = null,
    state: *State,
    allocator: std.mem.Allocator,

    fn destroy(self: *ToplevelEntry) void {
        self.allocator.free(self.title);
        self.allocator.free(self.app_id);
        if (self.kde_uuid) |uuid| self.allocator.free(uuid);
        for (self.desktop_ids.items) |id| self.allocator.free(id);
        self.desktop_ids.deinit(self.allocator);
        if (self.handle_wlr) |h| c.zwlr_foreign_toplevel_handle_v1_destroy(h);
        if (self.handle_kde) |h| c.org_kde_plasma_window_destroy(h);
        self.allocator.destroy(self);
    }

    fn setTitle(self: *ToplevelEntry, raw: [*c]const u8) void {
        const next = self.allocator.dupe(u8, std.mem.span(raw)) catch return;
        self.allocator.free(self.title);
        self.title = next;
    }

    fn setAppId(self: *ToplevelEntry, raw: [*c]const u8) void {
        const next = self.allocator.dupe(u8, std.mem.span(raw)) catch return;
        self.allocator.free(self.app_id);
        self.app_id = next;
    }

    fn enterDesktop(self: *ToplevelEntry, id: []const u8) void {
        for (self.desktop_ids.items) |existing| {
            if (std.mem.eql(u8, existing, id)) {
                self.has_modern_desktop_membership = true;
                return;
            }
        }
        const owned = self.allocator.dupe(u8, id) catch return;
        self.desktop_ids.append(self.allocator, owned) catch {
            self.allocator.free(owned);
            return;
        };
        self.has_modern_desktop_membership = true;
    }

    fn leaveDesktop(self: *ToplevelEntry, id: []const u8) void {
        self.has_modern_desktop_membership = true;
        for (self.desktop_ids.items, 0..) |existing, idx| {
            if (!std.mem.eql(u8, existing, id)) continue;
            const owned = self.desktop_ids.orderedRemove(idx);
            self.allocator.free(owned);
            return;
        }
    }

    fn recomputeDesktopNumber(self: *ToplevelEntry) void {
        if (!self.has_modern_desktop_membership) {
            self.desktop_number = self.legacy_desktop_number;
            return;
        }
        // No memberships means the compositor considers the window present on
        // every desktop, for which Vitrail intentionally displays no badge.
        if (self.desktop_ids.items.len == 0) {
            self.desktop_number = null;
            return;
        }

        var best: ?usize = null;
        for (self.desktop_ids.items) |id| {
            const position = self.state.desktopPosition(id) orelse continue;
            best = if (best) |current| @min(current, position) else position;
        }
        // If the desktop-management global is unavailable or has not announced
        // a referenced id yet, retain the deprecated integer event as fallback.
        self.desktop_number = best orelse self.legacy_desktop_number;
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    seat: ?*c.wl_seat = null,
    foreign_toplevel_mgr: ?*c.zwlr_foreign_toplevel_manager_v1 = null,
    plasma_window_mgr: ?*c.org_kde_plasma_window_management = null,
    plasma_virtual_desktop_mgr: ?*c.org_kde_plasma_virtual_desktop_management = null,
    virtual_desktops: std.ArrayListUnmanaged(VirtualDesktopInfo) = .{},
    virtual_desktops_ready: bool = false,
    toplevels: std.ArrayListUnmanaged(*ToplevelEntry) = .{},
    next_stable_id: u64 = 1,
    dirty: bool = false,

    fn markDirty(self: *State) void {
        self.dirty = true;
    }

    fn desktopPosition(self: *const State, id: []const u8) ?usize {
        for (self.virtual_desktops.items) |desktop| {
            if (std.mem.eql(u8, desktop.id, id)) return desktop.position;
        }
        return null;
    }

    fn desktopByHandle(self: *State, handle: ?*c.org_kde_plasma_virtual_desktop) ?*VirtualDesktopInfo {
        const target = handle orelse return null;
        for (self.virtual_desktops.items) |*desktop| {
            if (desktop.handle) |candidate| {
                if (candidate == target) return desktop;
            }
        }
        return null;
    }

    fn recomputeDesktopNumbers(self: *State) void {
        for (self.toplevels.items) |entry| {
            if (!entry.closed) entry.recomputeDesktopNumber();
        }
    }

    fn deinitOwned(self: *State) void {
        for (self.toplevels.items) |entry| entry.destroy();
        self.toplevels.deinit(self.allocator);
        for (self.virtual_desktops.items) |desktop| {
            if (desktop.handle) |handle| c.org_kde_plasma_virtual_desktop_destroy(handle);
            self.allocator.free(desktop.id);
        }
        self.virtual_desktops.deinit(self.allocator);
        if (self.plasma_virtual_desktop_mgr) |mgr| {
            c.org_kde_plasma_virtual_desktop_management_destroy(mgr);
        }
    }
};

display: *c.wl_display,
state: *State,

pub fn init(allocator: std.mem.Allocator) !Self {
    const display = c.wl_display_connect(null) orelse return error.NoWaylandDisplay;
    errdefer _ = c.wl_display_disconnect(display);

    const state = try allocator.create(State);
    state.* = .{ .allocator = allocator };
    errdefer {
        state.deinitOwned();
        allocator.destroy(state);
    }

    const registry = c.wl_display_get_registry(display) orelse return error.RegistryFailed;
    _ = c.wl_registry_add_listener(registry, &registry_listener, state);
    _ = c.wl_display_roundtrip(display); // bind globals; triggers initial window events
    _ = c.wl_display_roundtrip(display); // collect initial_state / done events

    if (state.foreign_toplevel_mgr == null and state.plasma_window_mgr == null) {
        std.log.err(
            \\No Wayland window-list protocol exposed by this compositor.
            \\Tried: zwlr_foreign_toplevel_management_v1, org_kde_plasma_window_management.
            \\KWin 6.6.4 gates org_kde_plasma_window_management to privileged plasmashell only
            \\and does not yet advertise ext_foreign_toplevel_list_v1.
        , .{});
        return error.NoWindowListProtocol;
    }

    return Self{ .display = display, .state = state };
}

pub fn deinit(self: Self) void {
    self.state.deinitOwned();
    self.state.allocator.destroy(self.state);
    _ = c.wl_display_disconnect(self.display);
}

pub fn eventFd(self: *const Self) ?std.posix.fd_t {
    const fd = c.wl_display_get_fd(self.display);
    return if (fd >= 0) @intCast(fd) else null;
}

/// Consume compositor notifications after eventFd() becomes readable. The
/// caller follows this by taking a fresh snapshot; listeners below only update
/// the persistent protocol entries and mark the backend dirty.
pub fn dispatchPending(self: *Self) void {
    if (c.wl_display_dispatch_pending(self.display) < 0) {
        std.log.err("WlrootsBackend: failed to dispatch window-list events", .{});
        return;
    }

    // Manual/test-triggered refreshes can call this when no lifecycle event is
    // waiting. Check readiness so draining backend state is always nonblocking.
    const event_fd = self.eventFd() orelse return;
    var fd = [_]std.posix.pollfd{.{
        .fd = event_fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    _ = std.posix.poll(&fd, 0) catch return;
    if (fd[0].revents & std.posix.POLL.IN != 0 and c.wl_display_dispatch(self.display) < 0) {
        std.log.err("WlrootsBackend: failed to read window-list events", .{});
    }
    self.state.dirty = false;
}

pub fn hasPendingChanges(self: *const Self) bool {
    return self.state.dirty;
}

pub fn getWindowList(self: Self, allocator: std.mem.Allocator) !std.array_list.Managed(common.DesktopWindow) {
    _ = c.wl_display_roundtrip(self.display);

    std.log.debug("getWindowList: {d} toplevels collected (protocol: {s})", .{
        self.state.toplevels.items.len,
        if (self.state.foreign_toplevel_mgr != null) "wlroots" else "kde-plasma",
    });

    var list = std.array_list.Managed(common.DesktopWindow).init(allocator);
    errdefer {
        for (list.items) |dw| dw.destroy();
        list.deinit();
    }

    for (self.state.toplevels.items) |entry| {
        if (entry.closed) continue;

        const stable_id = if (entry.kde_uuid) |uuid|
            try allocator.dupeZ(u8, uuid)
        else
            try std.fmt.allocPrintSentinel(allocator, "wlroots:{d}", .{entry.stable_id}, 0);
        errdefer allocator.free(stable_id);
        const title = try allocator.dupeZ(u8, entry.title);
        errdefer allocator.free(title);
        const title_lower = try allocator.dupeZ(u8, entry.title);
        errdefer allocator.free(title_lower);
        for (title_lower) |*ch| ch.* = std.ascii.toLower(ch.*);
        const app_id = try allocator.dupeZ(u8, entry.app_id);
        errdefer allocator.free(app_id);
        const app_id_lower = try allocator.dupeZ(u8, entry.app_id);
        errdefer allocator.free(app_id_lower);
        for (app_id_lower) |*ch| ch.* = std.ascii.toLower(ch.*);

        try list.append(.{
            .stable_id = stable_id,
            .platform_handle = @intCast(entry.stable_id),
            .title = title,
            .title_lower = title_lower,
            .app_id = app_id,
            .app_id_lower = app_id_lower,
            .icon = null,
            .desktopNumber = entry.desktop_number,
            .can_close = entry.can_close,
            .allocator = allocator,
        });
    }

    return list;
}

pub fn activateWindow(self: *Self, dw: common.DesktopWindow) void {
    const entry = self.findEntry(dw.stable_id) orelse return;

    if (entry.handle_wlr) |h| {
        if (self.state.seat) |seat| {
            c.zwlr_foreign_toplevel_handle_v1_activate(h, seat);
            _ = c.wl_display_flush(self.display);
        }
    } else if (entry.handle_kde) |h| {
        const ACTIVE: u32 = 0x1; // ORG_KDE_PLASMA_WINDOW_MANAGEMENT_STATE_ACTIVE
        c.org_kde_plasma_window_set_state(h, ACTIVE, ACTIVE);
        _ = c.wl_display_flush(self.display);
    }
}

pub fn closeWindow(self: *Self, stable_id: []const u8) void {
    const entry = self.findEntry(stable_id) orelse return;
    if (!entry.can_close) return;

    if (entry.handle_wlr) |h| {
        c.zwlr_foreign_toplevel_handle_v1_close(h);
    } else if (entry.handle_kde) |h| {
        c.org_kde_plasma_window_close(h);
    } else {
        return;
    }
    _ = c.wl_display_flush(self.display);
}

pub fn quitApplication(self: *Self, stable_id: []const u8) void {
    const selected = self.findEntry(stable_id) orelse return;
    const app_id = selected.app_id;
    for (self.state.toplevels.items) |entry| {
        if (entry.closed or !std.mem.eql(u8, entry.app_id, app_id)) continue;
        if (entry.handle_wlr) |h| {
            c.zwlr_foreign_toplevel_handle_v1_close(h);
        } else if (entry.handle_kde) |h| {
            c.org_kde_plasma_window_close(h);
        }
    }
    _ = c.wl_display_flush(self.display);
}

fn findEntry(self: *Self, stable_id: []const u8) ?*ToplevelEntry {
    for (self.state.toplevels.items) |entry| {
        if (entry.closed) continue;
        if (entry.kde_uuid) |uuid| {
            if (std.mem.eql(u8, uuid, stable_id)) return entry;
        } else {
            var buf: [48]u8 = undefined;
            const id = std.fmt.bufPrint(&buf, "wlroots:{d}", .{entry.stable_id}) catch continue;
            if (std.mem.eql(u8, id, stable_id)) return entry;
        }
    }
    return null;
}

// ─── Registry listener ────────────────────────────────────────────────────────

fn registryGlobal(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const iface = std.mem.span(interface);

    if (std.mem.eql(u8, iface, "wl_seat")) {
        state.seat = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_seat_interface, @min(version, 7)));
    } else if (std.mem.eql(u8, iface, "zwlr_foreign_toplevel_manager_v1")) {
        const mgr: ?*c.zwlr_foreign_toplevel_manager_v1 = @ptrCast(c.wl_registry_bind(registry, name, &c.zwlr_foreign_toplevel_manager_v1_interface, @min(version, 3)));
        state.foreign_toplevel_mgr = mgr;
        if (mgr) |m| _ = c.zwlr_foreign_toplevel_manager_v1_add_listener(m, &foreign_toplevel_mgr_listener, state);
    } else if (std.mem.eql(u8, iface, "org_kde_plasma_window_management")) {
        const mgr: ?*c.org_kde_plasma_window_management = @ptrCast(c.wl_registry_bind(registry, name, &c.org_kde_plasma_window_management_interface, @min(version, 16)));
        state.plasma_window_mgr = mgr;
        if (mgr) |m| _ = c.org_kde_plasma_window_management_add_listener(m, &plasma_mgr_listener, state);
    } else if (std.mem.eql(u8, iface, "org_kde_plasma_virtual_desktop_management")) {
        const mgr: ?*c.org_kde_plasma_virtual_desktop_management = @ptrCast(c.wl_registry_bind(
            registry,
            name,
            &c.org_kde_plasma_virtual_desktop_management_interface,
            @min(version, 3),
        ));
        state.plasma_virtual_desktop_mgr = mgr;
        if (mgr) |m| {
            _ = c.org_kde_plasma_virtual_desktop_management_add_listener(m, &plasma_virtual_desktop_mgr_listener, state);
        }
    }
}

fn registryGlobalRemove(_: ?*anyopaque, _: ?*c.wl_registry, _: u32) callconv(.c) void {}

const registry_listener = c.wl_registry_listener{
    .global = registryGlobal,
    .global_remove = registryGlobalRemove,
};

// ─── KDE virtual desktop management listener ─────────────────────────────────

fn virtualDesktopCreated(
    data: ?*anyopaque,
    mgr: ?*c.org_kde_plasma_virtual_desktop_management,
    desktop_id: [*c]const u8,
    position_raw: u32,
) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const id = std.mem.span(desktop_id);
    const position: usize = @intCast(position_raw);

    for (state.virtual_desktops.items) |*desktop| {
        if (!std.mem.eql(u8, desktop.id, id)) continue;
        desktop.position = position;
        attachVirtualDesktopHandle(state, desktop, mgr, desktop_id);
        return;
    }

    // During the initial advertisement every event carries its final absolute
    // position. After the first done, a new desktop is an insertion and shifts
    // the positions which follow it.
    const owned = state.allocator.dupe(u8, id) catch return;
    state.virtual_desktops.ensureUnusedCapacity(state.allocator, 1) catch {
        state.allocator.free(owned);
        return;
    };
    if (state.virtual_desktops_ready) {
        for (state.virtual_desktops.items) |*desktop| {
            if (desktop.position >= position) desktop.position += 1;
        }
    }
    state.virtual_desktops.appendAssumeCapacity(.{
        .id = owned,
        .position = position,
    });
    attachVirtualDesktopHandle(
        state,
        &state.virtual_desktops.items[state.virtual_desktops.items.len - 1],
        mgr,
        desktop_id,
    );
}

fn attachVirtualDesktopHandle(
    state: *State,
    desktop: *VirtualDesktopInfo,
    mgr: ?*c.org_kde_plasma_virtual_desktop_management,
    desktop_id: [*c]const u8,
) void {
    if (desktop.handle != null) return;
    const manager = mgr orelse return;
    const handle = c.org_kde_plasma_virtual_desktop_management_get_virtual_desktop(manager, desktop_id) orelse return;
    desktop.handle = handle;
    if (c.org_kde_plasma_virtual_desktop_add_listener(handle, &plasma_virtual_desktop_listener, state) < 0) {
        c.org_kde_plasma_virtual_desktop_destroy(handle);
        desktop.handle = null;
    }
}

fn virtualDesktopRemoved(
    data: ?*anyopaque,
    _: ?*c.org_kde_plasma_virtual_desktop_management,
    desktop_id: [*c]const u8,
) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const id = std.mem.span(desktop_id);

    var removed_position: ?usize = null;
    for (state.virtual_desktops.items, 0..) |desktop, idx| {
        if (!std.mem.eql(u8, desktop.id, id)) continue;
        const removed = state.virtual_desktops.orderedRemove(idx);
        removed_position = removed.position;
        if (removed.handle) |handle| c.org_kde_plasma_virtual_desktop_destroy(handle);
        state.allocator.free(removed.id);
        break;
    }
    if (removed_position) |position| {
        for (state.virtual_desktops.items) |*desktop| {
            if (desktop.position > position) desktop.position -= 1;
        }
    }

    // The protocol defines removal as dropping this association from every
    // window. Do this even if the desktop id was not present in our map.
    for (state.toplevels.items) |entry| {
        for (entry.desktop_ids.items) |membership| {
            if (!std.mem.eql(u8, membership, id)) continue;
            entry.leaveDesktop(id);
            break;
        }
    }
}

fn virtualDesktopManagerDone(
    data: ?*anyopaque,
    _: ?*c.org_kde_plasma_virtual_desktop_management,
) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    state.virtual_desktops_ready = true;
    state.recomputeDesktopNumbers();
    state.markDirty();
}

fn virtualDesktopRows(
    _: ?*anyopaque,
    _: ?*c.org_kde_plasma_virtual_desktop_management,
    _: u32,
) callconv(.c) void {}

const plasma_virtual_desktop_mgr_listener = c.org_kde_plasma_virtual_desktop_management_listener{
    .desktop_created = virtualDesktopCreated,
    .desktop_removed = virtualDesktopRemoved,
    .done = virtualDesktopManagerDone,
    .rows = virtualDesktopRows,
};

// ─── KDE virtual desktop object listener ─────────────────────────────────────

fn virtualDesktopObjectId(
    _: ?*anyopaque,
    _: ?*c.org_kde_plasma_virtual_desktop,
    _: [*c]const u8,
) callconv(.c) void {}

fn virtualDesktopObjectName(
    _: ?*anyopaque,
    _: ?*c.org_kde_plasma_virtual_desktop,
    _: [*c]const u8,
) callconv(.c) void {}

fn virtualDesktopObjectState(
    _: ?*anyopaque,
    _: ?*c.org_kde_plasma_virtual_desktop,
) callconv(.c) void {}

fn virtualDesktopObjectDone(
    data: ?*anyopaque,
    _: ?*c.org_kde_plasma_virtual_desktop,
) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    state.recomputeDesktopNumbers();
    state.markDirty();
}

fn virtualDesktopObjectRemoved(
    data: ?*anyopaque,
    desktop_handle: ?*c.org_kde_plasma_virtual_desktop,
) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const desktop = state.desktopByHandle(desktop_handle) orelse return;
    if (desktop.handle) |handle| c.org_kde_plasma_virtual_desktop_destroy(handle);
    desktop.handle = null;
}

fn virtualDesktopObjectPosition(
    data: ?*anyopaque,
    desktop_handle: ?*c.org_kde_plasma_virtual_desktop,
    position: u32,
) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const desktop = state.desktopByHandle(desktop_handle) orelse return;
    desktop.position = @intCast(position);
}

const plasma_virtual_desktop_listener = c.org_kde_plasma_virtual_desktop_listener{
    .desktop_id = virtualDesktopObjectId,
    .name = virtualDesktopObjectName,
    .activated = virtualDesktopObjectState,
    .deactivated = virtualDesktopObjectState,
    .done = virtualDesktopObjectDone,
    .removed = virtualDesktopObjectRemoved,
    .position = virtualDesktopObjectPosition,
};

// ─── wlr-foreign-toplevel-manager listener ────────────────────────────────────

fn ftmToplevel(data: ?*anyopaque, _: ?*c.zwlr_foreign_toplevel_manager_v1, handle: ?*c.zwlr_foreign_toplevel_handle_v1) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const h = handle orelse return;

    const entry = state.allocator.create(ToplevelEntry) catch {
        c.zwlr_foreign_toplevel_handle_v1_destroy(h);
        return;
    };
    const title = state.allocator.dupe(u8, "") catch {
        state.allocator.destroy(entry);
        c.zwlr_foreign_toplevel_handle_v1_destroy(h);
        return;
    };
    const app_id = state.allocator.dupe(u8, "") catch {
        state.allocator.free(title);
        state.allocator.destroy(entry);
        c.zwlr_foreign_toplevel_handle_v1_destroy(h);
        return;
    };
    entry.* = .{
        .title = title,
        .app_id = app_id,
        .stable_id = state.next_stable_id,
        .handle_wlr = h,
        .state = state,
        .allocator = state.allocator,
    };
    state.next_stable_id +%= 1;
    if (state.next_stable_id == 0) state.next_stable_id = 1;
    state.toplevels.append(state.allocator, entry) catch {
        entry.destroy();
        return;
    };
    _ = c.zwlr_foreign_toplevel_handle_v1_add_listener(h, &foreign_toplevel_handle_listener, entry);
}

fn ftmFinished(_: ?*anyopaque, _: ?*c.zwlr_foreign_toplevel_manager_v1) callconv(.c) void {}

const foreign_toplevel_mgr_listener = c.zwlr_foreign_toplevel_manager_v1_listener{
    .toplevel = ftmToplevel,
    .finished = ftmFinished,
};

// ─── wlr-foreign-toplevel-handle listener ─────────────────────────────────────

fn fthTitle(data: ?*anyopaque, _: ?*c.zwlr_foreign_toplevel_handle_v1, title: [*c]const u8) callconv(.c) void {
    const entry: *ToplevelEntry = @ptrCast(@alignCast(data));
    entry.setTitle(title);
}

fn fthAppId(data: ?*anyopaque, _: ?*c.zwlr_foreign_toplevel_handle_v1, app_id: [*c]const u8) callconv(.c) void {
    const entry: *ToplevelEntry = @ptrCast(@alignCast(data));
    entry.setAppId(app_id);
}

fn fthOutputEnter(_: ?*anyopaque, _: ?*c.zwlr_foreign_toplevel_handle_v1, _: ?*c.wl_output) callconv(.c) void {}
fn fthOutputLeave(_: ?*anyopaque, _: ?*c.zwlr_foreign_toplevel_handle_v1, _: ?*c.wl_output) callconv(.c) void {}

fn fthState(data: ?*anyopaque, _: ?*c.zwlr_foreign_toplevel_handle_v1, states: ?*c.wl_array) callconv(.c) void {
    const entry: *ToplevelEntry = @ptrCast(@alignCast(data));
    entry.minimized = false;
    const arr = states orelse return;
    const vals: [*]const u32 = @ptrCast(@alignCast(arr.data));
    const count = arr.size / @sizeOf(u32);
    for (vals[0..count]) |s| {
        if (s == c.ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_MINIMIZED) entry.minimized = true;
    }
}

fn fthDone(data: ?*anyopaque, _: ?*c.zwlr_foreign_toplevel_handle_v1) callconv(.c) void {
    const entry: *ToplevelEntry = @ptrCast(@alignCast(data));
    entry.state.markDirty();
}

fn fthClosed(data: ?*anyopaque, _: ?*c.zwlr_foreign_toplevel_handle_v1) callconv(.c) void {
    const entry: *ToplevelEntry = @ptrCast(@alignCast(data));
    if (entry.handle_wlr) |handle| {
        c.zwlr_foreign_toplevel_handle_v1_destroy(handle);
    }
    entry.closed = true;
    entry.handle_wlr = null;
    entry.state.markDirty();
}

fn fthParent(_: ?*anyopaque, _: ?*c.zwlr_foreign_toplevel_handle_v1, _: ?*c.zwlr_foreign_toplevel_handle_v1) callconv(.c) void {}

const foreign_toplevel_handle_listener = c.zwlr_foreign_toplevel_handle_v1_listener{
    .title = fthTitle,
    .app_id = fthAppId,
    .output_enter = fthOutputEnter,
    .output_leave = fthOutputLeave,
    .state = fthState,
    .done = fthDone,
    .closed = fthClosed,
    .parent = fthParent,
};

// ─── KDE plasma window management listener ────────────────────────────────────

fn plasmaWindow(_: ?*anyopaque, _: ?*c.org_kde_plasma_window_management, _: u32) callconv(.c) void {
    // Deprecated event — superseded by window_with_uuid; takes a uint internal id.
    // We rely on window_with_uuid (since v13) and ignore the legacy callback.
}

fn plasmaWindowWithUuid(data: ?*anyopaque, mgr: ?*c.org_kde_plasma_window_management, _: u32, uuid: [*c]const u8) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const m = mgr orelse return;
    const handle = c.org_kde_plasma_window_management_get_window_by_uuid(m, uuid);
    plasmaMakeEntry(state, handle, std.mem.span(uuid));
}

fn plasmaMakeEntry(state: *State, handle: ?*c.org_kde_plasma_window, uuid: []const u8) void {
    const h = handle orelse return;
    const entry = state.allocator.create(ToplevelEntry) catch {
        c.org_kde_plasma_window_destroy(h);
        return;
    };
    const title = state.allocator.dupe(u8, "") catch {
        state.allocator.destroy(entry);
        c.org_kde_plasma_window_destroy(h);
        return;
    };
    const app_id = state.allocator.dupe(u8, "") catch {
        state.allocator.free(title);
        state.allocator.destroy(entry);
        c.org_kde_plasma_window_destroy(h);
        return;
    };
    const kde_uuid = state.allocator.dupeZ(u8, uuid) catch {
        state.allocator.free(app_id);
        state.allocator.free(title);
        state.allocator.destroy(entry);
        c.org_kde_plasma_window_destroy(h);
        return;
    };
    entry.* = .{
        .title = title,
        .app_id = app_id,
        .stable_id = state.next_stable_id,
        .kde_uuid = kde_uuid,
        .handle_kde = h,
        .state = state,
        .allocator = state.allocator,
    };
    state.next_stable_id +%= 1;
    if (state.next_stable_id == 0) state.next_stable_id = 1;
    state.toplevels.append(state.allocator, entry) catch {
        entry.destroy();
        return;
    };
    _ = c.org_kde_plasma_window_add_listener(h, &plasma_window_listener, entry);
}

fn plasmaShowDesktopChanged(_: ?*anyopaque, _: ?*c.org_kde_plasma_window_management, _: u32) callconv(.c) void {}
fn plasmaStackingOrderChanged(_: ?*anyopaque, _: ?*c.org_kde_plasma_window_management, _: ?*c.wl_array) callconv(.c) void {}
fn plasmaStackingOrderUuidChanged(_: ?*anyopaque, _: ?*c.org_kde_plasma_window_management, _: [*c]const u8) callconv(.c) void {}
fn plasmaStackingOrderChanged2(_: ?*anyopaque, _: ?*c.org_kde_plasma_window_management) callconv(.c) void {}

const plasma_mgr_listener = c.org_kde_plasma_window_management_listener{
    .show_desktop_changed = plasmaShowDesktopChanged,
    .window = plasmaWindow,
    .stacking_order_changed = plasmaStackingOrderChanged,
    .stacking_order_uuid_changed = plasmaStackingOrderUuidChanged,
    .window_with_uuid = plasmaWindowWithUuid,
    .stacking_order_changed_2 = plasmaStackingOrderChanged2,
};

// ─── KDE plasma window listener ───────────────────────────────────────────────

fn pwTitleChanged(data: ?*anyopaque, _: ?*c.org_kde_plasma_window, title: [*c]const u8) callconv(.c) void {
    const entry: *ToplevelEntry = @ptrCast(@alignCast(data));
    entry.setTitle(title);
    entry.state.markDirty();
}

fn pwAppIdChanged(data: ?*anyopaque, _: ?*c.org_kde_plasma_window, app_id: [*c]const u8) callconv(.c) void {
    const entry: *ToplevelEntry = @ptrCast(@alignCast(data));
    entry.setAppId(app_id);
    entry.state.markDirty();
}

fn pwStateChanged(data: ?*anyopaque, _: ?*c.org_kde_plasma_window, flags: u32) callconv(.c) void {
    const entry: *ToplevelEntry = @ptrCast(@alignCast(data));
    entry.minimized = (flags & 0x2) != 0; // STATE_MINIMIZED = 0x2
    entry.can_close = (flags & 0x100) != 0; // STATE_CLOSEABLE = 0x100
    entry.state.markDirty();
}

fn pwUnmapped(data: ?*anyopaque, _: ?*c.org_kde_plasma_window) callconv(.c) void {
    const entry: *ToplevelEntry = @ptrCast(@alignCast(data));
    if (entry.handle_kde) |handle| {
        c.org_kde_plasma_window_destroy(handle);
    }
    entry.closed = true;
    entry.handle_kde = null;
    entry.state.markDirty();
}

fn pwInitialState(data: ?*anyopaque, _: ?*c.org_kde_plasma_window) callconv(.c) void {
    const entry: *ToplevelEntry = @ptrCast(@alignCast(data));
    entry.state.markDirty();
}
fn pwNoop1u(_: ?*anyopaque, _: ?*c.org_kde_plasma_window, _: u32) callconv(.c) void {}
fn pwVirtualDesktopChanged(data: ?*anyopaque, _: ?*c.org_kde_plasma_window, number: i32) callconv(.c) void {
    const entry: *ToplevelEntry = @ptrCast(@alignCast(data));
    entry.legacy_desktop_number = if (number >= 0) @intCast(number) else null;
    entry.recomputeDesktopNumber();
    entry.state.markDirty();
}
fn pwVirtualDesktopEntered(data: ?*anyopaque, _: ?*c.org_kde_plasma_window, desktop_id: [*c]const u8) callconv(.c) void {
    const entry: *ToplevelEntry = @ptrCast(@alignCast(data));
    entry.enterDesktop(std.mem.span(desktop_id));
    entry.recomputeDesktopNumber();
    entry.state.markDirty();
}
fn pwVirtualDesktopLeft(data: ?*anyopaque, _: ?*c.org_kde_plasma_window, desktop_id: [*c]const u8) callconv(.c) void {
    const entry: *ToplevelEntry = @ptrCast(@alignCast(data));
    entry.leaveDesktop(std.mem.span(desktop_id));
    entry.recomputeDesktopNumber();
    entry.state.markDirty();
}
fn pwChanged2(data: ?*anyopaque, _: ?*c.org_kde_plasma_window, _: [*c]const u8) callconv(.c) void {
    const entry: *ToplevelEntry = @ptrCast(@alignCast(data));
    entry.state.markDirty();
}
fn pwParentWindow(_: ?*anyopaque, _: ?*c.org_kde_plasma_window, _: ?*c.org_kde_plasma_window) callconv(.c) void {}
fn pwGeometry(_: ?*anyopaque, _: ?*c.org_kde_plasma_window, _: i32, _: i32, _: u32, _: u32) callconv(.c) void {}
// pid_changed listener uses pwNoop1u above
fn pwAppMenu(_: ?*anyopaque, _: ?*c.org_kde_plasma_window, _: [*c]const u8, _: [*c]const u8) callconv(.c) void {}
fn pwIconChanged(data: ?*anyopaque, _: ?*c.org_kde_plasma_window) callconv(.c) void {
    const entry: *ToplevelEntry = @ptrCast(@alignCast(data));
    entry.state.markDirty();
}
fn pwClientGeometry(_: ?*anyopaque, _: ?*c.org_kde_plasma_window, _: i32, _: i32, _: u32, _: u32) callconv(.c) void {}

const plasma_window_listener = c.org_kde_plasma_window_listener{
    .title_changed = pwTitleChanged,
    .app_id_changed = pwAppIdChanged,
    .state_changed = pwStateChanged,
    .virtual_desktop_changed = pwVirtualDesktopChanged,
    .themed_icon_name_changed = pwChanged2,
    .unmapped = pwUnmapped,
    .initial_state = pwInitialState,
    .parent_window = pwParentWindow,
    .geometry = pwGeometry,
    .icon_changed = pwIconChanged,
    .pid_changed = pwNoop1u,
    .virtual_desktop_entered = pwVirtualDesktopEntered,
    .virtual_desktop_left = pwVirtualDesktopLeft,
    .application_menu = pwAppMenu,
    .activity_entered = pwChanged2,
    .activity_left = pwChanged2,
    .resource_name_changed = pwChanged2,
    .client_geometry = pwClientGeometry,
};
