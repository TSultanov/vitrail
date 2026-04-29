// Cross-platform UI test scenarios. Each scenario exercises a user flow
// against a duck-typed Driver; platform-specific test_main builds a Driver
// over its real presenter and runs them all.
const std = @import("std");

pub const Key = enum { left, right, up, down, tab, shift_tab, esc, enter, backspace };
pub const Point = struct { x: i32, y: i32 };

pub const Driver = struct {
    ctx: *anyopaque,
    vt: *const VTable,

    pub const VTable = struct {
        post_key: *const fn (ctx: *anyopaque, key: Key) anyerror!void,
        post_char: *const fn (ctx: *anyopaque, codepoint: u21) anyerror!void,
        post_mouse_move: *const fn (ctx: *anyopaque, x: i32, y: i32) anyerror!void,
        post_mouse_click: *const fn (ctx: *anyopaque, x: i32, y: i32) anyerror!void,
        selected_app_id: *const fn (ctx: *anyopaque) ?[]const u8,
        visible_count: *const fn (ctx: *anyopaque) usize,
        search_text: *const fn (ctx: *anyopaque) []const u8,
        last_activated_app_id: *const fn (ctx: *anyopaque) ?[]const u8,
        window_visible: *const fn (ctx: *anyopaque) bool,
        tile_center: *const fn (ctx: *anyopaque, app_id: []const u8) ?Point,
        snapshot: *const fn (ctx: *anyopaque, name: []const u8) anyerror!void,
        reset: *const fn (ctx: *anyopaque) anyerror!void,
    };

    fn postKey(self: *Driver, k: Key) !void {
        return self.vt.post_key(self.ctx, k);
    }
    fn postChar(self: *Driver, cp: u21) !void {
        return self.vt.post_char(self.ctx, cp);
    }
    fn postMouseMove(self: *Driver, x: i32, y: i32) !void {
        return self.vt.post_mouse_move(self.ctx, x, y);
    }
    fn postMouseClick(self: *Driver, x: i32, y: i32) !void {
        return self.vt.post_mouse_click(self.ctx, x, y);
    }
    fn selectedAppId(self: *Driver) ?[]const u8 {
        return self.vt.selected_app_id(self.ctx);
    }
    fn visibleCount(self: *Driver) usize {
        return self.vt.visible_count(self.ctx);
    }
    fn searchText(self: *Driver) []const u8 {
        return self.vt.search_text(self.ctx);
    }
    fn lastActivatedAppId(self: *Driver) ?[]const u8 {
        return self.vt.last_activated_app_id(self.ctx);
    }
    fn windowVisible(self: *Driver) bool {
        return self.vt.window_visible(self.ctx);
    }
    fn tileCenter(self: *Driver, app_id: []const u8) ?Point {
        return self.vt.tile_center(self.ctx, app_id);
    }
    fn snapshot(self: *Driver, name: []const u8) !void {
        return self.vt.snapshot(self.ctx, name);
    }
    fn reset(self: *Driver) !void {
        return self.vt.reset(self.ctx);
    }
};

pub const Scenario = struct {
    name: []const u8,
    run: *const fn (d: *Driver) anyerror!void,
};

pub const all = [_]Scenario{
    .{ .name = "01-arrow-keys-move-selection", .run = scenario1 },
    .{ .name = "02-tab-and-shift-tab", .run = scenario2 },
    .{ .name = "03-esc-closes", .run = scenario3 },
    .{ .name = "04-enter-activates", .run = scenario4 },
    .{ .name = "05-alpha-typing-filters", .run = scenario5 },
    .{ .name = "06-mouse-move-changes-selection", .run = scenario6 },
    .{ .name = "07-mouse-click-activates", .run = scenario7 },
    .{ .name = "08-click-outside-closes", .run = scenario8 },
};

/// Returns the number of failed scenarios.
pub fn runAll(d: *Driver) u32 {
    var fails: u32 = 0;
    for (all) |s| {
        if (d.reset()) {} else |e| {
            std.debug.print("RESET {s}: {t}\n", .{ s.name, e });
            fails += 1;
            continue;
        }
        if (s.run(d)) {
            std.debug.print("PASS {s}\n", .{s.name});
            d.snapshot(s.name) catch {};
        } else |e| {
            std.debug.print("FAIL {s}: {t}\n", .{ s.name, e });
            d.snapshot(s.name) catch {};
            fails += 1;
        }
    }
    return fails;
}

fn expect(cond: bool) !void {
    if (!cond) return error.AssertionFailed;
}

fn expectStrEq(a: []const u8, b: []const u8) !void {
    if (!std.mem.eql(u8, a, b)) return error.AssertionFailed;
}

fn expectStrNeq(a: []const u8, b: []const u8) !void {
    if (std.mem.eql(u8, a, b)) return error.AssertionFailed;
}

// 1. Arrow keys move selection.
fn scenario1(d: *Driver) !void {
    const start = d.selectedAppId() orelse return error.NoInitialSelection;
    try d.postKey(.right);
    const after_right = d.selectedAppId() orelse return error.LostSelection;
    try expectStrNeq(start, after_right);
    try d.postKey(.left);
    const after_left = d.selectedAppId() orelse return error.LostSelection;
    // Mirror move should return to start.
    try expectStrEq(start, after_left);
    try d.postKey(.down);
    const after_down = d.selectedAppId() orelse return error.LostSelection;
    try expectStrNeq(start, after_down);
    try d.postKey(.up);
    const after_up = d.selectedAppId() orelse return error.LostSelection;
    try expectStrEq(start, after_up);
}

// 2. Tab / Shift-Tab cycle in order.
fn scenario2(d: *Driver) !void {
    const a = d.selectedAppId() orelse return error.NoInitialSelection;
    try d.postKey(.tab);
    const b = d.selectedAppId() orelse return error.LostSelection;
    try expectStrNeq(a, b);
    try d.postKey(.shift_tab);
    const c = d.selectedAppId() orelse return error.LostSelection;
    try expectStrEq(a, c);
}

// 3. Esc closes the grid.
fn scenario3(d: *Driver) !void {
    try expect(d.windowVisible());
    try d.postKey(.esc);
    try expect(!d.windowVisible());
}

// 4. Enter activates the selected window.
fn scenario4(d: *Driver) !void {
    const sel = d.selectedAppId() orelse return error.NoInitialSelection;
    try d.postKey(.enter);
    const act = d.lastActivatedAppId() orelse return error.NoActivation;
    try expectStrEq(sel, act);
}

// 5. Typing filters tiles.
fn scenario5(d: *Driver) !void {
    try d.postChar('f');
    try d.postChar('i');
    try expectStrEq("fi", d.searchText());
    // Of the 8 mock fixtures, only "Firefox" and "Figma" contain "fi".
    const visible = d.visibleCount();
    if (visible != 2) {
        std.log.err("scenario5: visible={d}, expected 2", .{visible});
        return error.AssertionFailed;
    }
}

// 6. Mouse move selects the tile under the cursor.
fn scenario6(d: *Driver) !void {
    const target = d.tileCenter("spotify") orelse return error.NoTile;
    try d.postMouseMove(target.x, target.y);
    const sel = d.selectedAppId() orelse return error.LostSelection;
    try expectStrEq("spotify", sel);
}

// 7. Mouse click on a tile activates it.
fn scenario7(d: *Driver) !void {
    const target = d.tileCenter("slack") orelse return error.NoTile;
    try d.postMouseClick(target.x, target.y);
    const act = d.lastActivatedAppId() orelse return error.NoActivation;
    try expectStrEq("slack", act);
}

// 8. Click outside the grid closes it.
fn scenario8(d: *Driver) !void {
    try expect(d.windowVisible());
    try d.postMouseClick(5, 5); // top-left corner — empty
    try expect(!d.windowVisible());
}
