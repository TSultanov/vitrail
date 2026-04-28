const std = @import("std");
const common = @import("../../common/DesktopWindow.zig");

const c = @cImport({
    @cInclude("wayland-client-protocol.h");
    @cInclude("wlr-foreign-toplevel-management-unstable-v1-client-protocol.h");
    @cInclude("plasma-window-management-client-protocol.h");
    @cInclude("plasma-virtual-desktop-client-protocol.h");
});

const Self = @This();

// Heap-allocated per window so pointer stays stable across ArrayList resizes.
const ToplevelEntry = struct {
    title: []const u8,
    app_id: []const u8,
    minimized: bool = false,
    closed: bool = false,
    handle_wlr: ?*c.zwlr_foreign_toplevel_handle_v1 = null,
    handle_kde: ?*c.org_kde_plasma_window = null,
    allocator: std.mem.Allocator,

    fn destroy(self: *ToplevelEntry) void {
        self.allocator.free(self.title);
        self.allocator.free(self.app_id);
        if (self.handle_wlr) |h| c.zwlr_foreign_toplevel_handle_v1_destroy(h);
        if (self.handle_kde) |h| c.org_kde_plasma_window_destroy(h);
        self.allocator.destroy(self);
    }

    fn setTitle(self: *ToplevelEntry, raw: [*c]const u8) void {
        self.allocator.free(self.title);
        self.title = self.allocator.dupe(u8, std.mem.span(raw)) catch "";
    }

    fn setAppId(self: *ToplevelEntry, raw: [*c]const u8) void {
        self.allocator.free(self.app_id);
        self.app_id = self.allocator.dupe(u8, std.mem.span(raw)) catch "";
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    seat: ?*c.wl_seat = null,
    foreign_toplevel_mgr: ?*c.zwlr_foreign_toplevel_manager_v1 = null,
    plasma_window_mgr: ?*c.org_kde_plasma_window_management = null,
    toplevels: std.ArrayListUnmanaged(*ToplevelEntry) = .{},
};

display: *c.wl_display,
state: *State,

pub fn init(allocator: std.mem.Allocator) !Self {
    const display = c.wl_display_connect(null) orelse return error.NoWaylandDisplay;
    errdefer _ = c.wl_display_disconnect(display);

    const state = try allocator.create(State);
    errdefer allocator.destroy(state);
    state.* = .{ .allocator = allocator };

    const registry = c.wl_display_get_registry(display) orelse return error.RegistryFailed;
    _ = c.wl_registry_add_listener(registry, &registry_listener, state);
    _ = c.wl_display_roundtrip(display); // bind globals; triggers initial window events
    _ = c.wl_display_roundtrip(display); // collect initial_state / done events

    if (state.foreign_toplevel_mgr == null and state.plasma_window_mgr == null) {
        return error.NoWindowListProtocol;
    }

    return Self{ .display = display, .state = state };
}

pub fn deinit(self: Self) void {
    for (self.state.toplevels.items) |entry| entry.destroy();
    self.state.toplevels.deinit(self.state.allocator);
    self.state.allocator.destroy(self.state);
    _ = c.wl_display_disconnect(self.display);
}

pub fn getWindowList(self: Self, allocator: std.mem.Allocator) !std.array_list.Managed(common.DesktopWindow) {
    _ = c.wl_display_roundtrip(self.display);

    var list = std.array_list.Managed(common.DesktopWindow).init(allocator);
    errdefer {
        for (list.items) |dw| dw.destroy();
        list.deinit();
    }

    for (self.state.toplevels.items, 0..) |entry, idx| {
        if (entry.closed) continue;

        const title = try allocator.dupeZ(u8, entry.title);
        errdefer allocator.free(title);
        const title_lower = try allocator.dupeZ(u8, entry.title);
        errdefer allocator.free(title_lower);
        for (title_lower) |*ch| ch.* = std.ascii.toLower(ch.*);
        const app_id = try allocator.dupeZ(u8, entry.app_id);
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
    if (idx >= self.state.toplevels.items.len) return;
    const entry = self.state.toplevels.items[idx];
    if (entry.closed) return;

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
    }
}

fn registryGlobalRemove(_: ?*anyopaque, _: ?*c.wl_registry, _: u32) callconv(.c) void {}

const registry_listener = c.wl_registry_listener{
    .global = registryGlobal,
    .global_remove = registryGlobalRemove,
};

// ─── wlr-foreign-toplevel-manager listener ────────────────────────────────────

fn ftmToplevel(data: ?*anyopaque, _: ?*c.zwlr_foreign_toplevel_manager_v1, handle: ?*c.zwlr_foreign_toplevel_handle_v1) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const h = handle orelse return;

    const entry = state.allocator.create(ToplevelEntry) catch return;
    entry.* = .{
        .title = state.allocator.dupe(u8, "") catch "",
        .app_id = state.allocator.dupe(u8, "") catch "",
        .handle_wlr = h,
        .allocator = state.allocator,
    };
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

fn fthDone(_: ?*anyopaque, _: ?*c.zwlr_foreign_toplevel_handle_v1) callconv(.c) void {}

fn fthClosed(data: ?*anyopaque, _: ?*c.zwlr_foreign_toplevel_handle_v1) callconv(.c) void {
    const entry: *ToplevelEntry = @ptrCast(@alignCast(data));
    entry.closed = true;
    entry.handle_wlr = null; // ownership transferred to closed event; don't destroy
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

fn plasmaWindow(data: ?*anyopaque, _: ?*c.org_kde_plasma_window_management, handle: ?*c.org_kde_plasma_window) callconv(.c) void {
    plasmaMakeEntry(@ptrCast(@alignCast(data)), handle);
}

fn plasmaWindowWithUuid(data: ?*anyopaque, _: ?*c.org_kde_plasma_window_management, _: [*c]const u8, handle: ?*c.org_kde_plasma_window) callconv(.c) void {
    plasmaMakeEntry(@ptrCast(@alignCast(data)), handle);
}

fn plasmaMakeEntry(state: *State, handle: ?*c.org_kde_plasma_window) void {
    const h = handle orelse return;
    const entry = state.allocator.create(ToplevelEntry) catch return;
    entry.* = .{
        .title = state.allocator.dupe(u8, "") catch "",
        .app_id = state.allocator.dupe(u8, "") catch "",
        .handle_kde = h,
        .allocator = state.allocator,
    };
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
}

fn pwAppIdChanged(data: ?*anyopaque, _: ?*c.org_kde_plasma_window, app_id: [*c]const u8) callconv(.c) void {
    const entry: *ToplevelEntry = @ptrCast(@alignCast(data));
    entry.setAppId(app_id);
}

fn pwStateChanged(data: ?*anyopaque, _: ?*c.org_kde_plasma_window, flags: u32) callconv(.c) void {
    const entry: *ToplevelEntry = @ptrCast(@alignCast(data));
    entry.minimized = (flags & 0x2) != 0; // STATE_MINIMIZED = 0x2
}

fn pwUnmapped(data: ?*anyopaque, _: ?*c.org_kde_plasma_window) callconv(.c) void {
    const entry: *ToplevelEntry = @ptrCast(@alignCast(data));
    entry.closed = true;
    entry.handle_kde = null;
}

fn pwNoop0(_: ?*anyopaque, _: ?*c.org_kde_plasma_window) callconv(.c) void {}
fn pwNoop1(_: ?*anyopaque, _: ?*c.org_kde_plasma_window, _: u32) callconv(.c) void {}
fn pwNoop2(_: ?*anyopaque, _: ?*c.org_kde_plasma_window, _: [*c]const u8) callconv(.c) void {}
fn pwParentWindow(_: ?*anyopaque, _: ?*c.org_kde_plasma_window, _: ?*c.org_kde_plasma_window) callconv(.c) void {}
fn pwGeometry(_: ?*anyopaque, _: ?*c.org_kde_plasma_window, _: i32, _: i32, _: u32, _: u32) callconv(.c) void {}
fn pwPidChanged(_: ?*anyopaque, _: ?*c.org_kde_plasma_window, _: u32) callconv(.c) void {}
fn pwAppMenu(_: ?*anyopaque, _: ?*c.org_kde_plasma_window, _: [*c]const u8, _: [*c]const u8) callconv(.c) void {}
fn pwIconChanged(_: ?*anyopaque, _: ?*c.org_kde_plasma_window) callconv(.c) void {}
fn pwClientGeometry(_: ?*anyopaque, _: ?*c.org_kde_plasma_window, _: i32, _: i32, _: u32, _: u32) callconv(.c) void {}

const plasma_window_listener = c.org_kde_plasma_window_listener{
    .title_changed = pwTitleChanged,
    .app_id_changed = pwAppIdChanged,
    .state_changed = pwStateChanged,
    .virtual_desktop_changed = pwNoop1,
    .themed_icon_name_changed = pwNoop2,
    .unmapped = pwUnmapped,
    .initial_state = pwNoop0,
    .parent_window = pwParentWindow,
    .geometry = pwGeometry,
    .icon_changed = pwIconChanged,
    .pid_changed = pwPidChanged,
    .virtual_desktop_entered = pwNoop2,
    .virtual_desktop_left = pwNoop2,
    .application_menu = pwAppMenu,
    .activity_entered = pwNoop2,
    .activity_left = pwNoop2,
    .resource_name_changed = pwNoop2,
    .client_geometry = pwClientGeometry,
};
