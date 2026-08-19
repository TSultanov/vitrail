// Platform-agnostic input action types and the dispatcher that turns them into
// grid mutations. Each platform's Keyboard.zig / Mouse.zig translates raw
// device events (xkb keysyms, NSEvent virtual keycodes, Win32 messages) into
// a KeyAction / MouseAction; this module is the single source of truth for
// what each action does.

const Grid = @import("Grid.zig");

pub const KeyAction = union(enum) {
    quit,
    activate,
    next,
    prev,
    move: struct { dx: i32, dy: i32 },
    backspace,
    delete_word,
    open_settings,
    insert: []const u8, // UTF-8; valid only for the duration of the callback
};

pub const MouseAction = union(enum) {
    move: struct { x: i32, y: i32 },
    click: struct { x: i32, y: i32 },
    context: struct { x: i32, y: i32 },
};

pub const ContextCommand = enum {
    close_window,
};

pub const KeyCallbacks = struct {
    on_action: *const fn (ctx: *anyopaque, action: KeyAction) void,
    ctx: *anyopaque,
};

pub const MouseCallbacks = struct {
    on_action: *const fn (ctx: *anyopaque, action: MouseAction) void,
    ctx: *anyopaque,
};

/// Side-effect callbacks dispatchKey/dispatchMouse need on top of the Grid.
/// Both share `ctx` — typically the platform's *MainWindow.
pub const Hooks = struct {
    hide: *const fn (ctx: *anyopaque) void,
    activate_selected: *const fn (ctx: *anyopaque) void,
    open_settings: *const fn (ctx: *anyopaque) void,
    ctx: *anyopaque,
};

/// Apply a key action to the grid. Repaint/flush is the caller's
/// responsibility — this function only mutates state.
pub fn dispatchKey(grid: *Grid, hooks: Hooks, action: KeyAction) void {
    switch (action) {
        .quit => hooks.hide(hooks.ctx),
        .activate => hooks.activate_selected(hooks.ctx),
        .next => grid.selectNext(false),
        .prev => grid.selectNext(true),
        .move => |m| grid.selectDir(m.dx, m.dy),
        .backspace => grid.popSearchCodepoint() catch {},
        .delete_word => grid.popSearchWord() catch {},
        .open_settings => hooks.open_settings(hooks.ctx),
        .insert => |bytes| grid.appendSearch(bytes) catch {},
    }
}

/// Apply a mouse action to the grid. Repaint/flush is the caller's
/// responsibility.
pub fn dispatchMouse(grid: *Grid, hooks: Hooks, action: MouseAction) void {
    switch (action) {
        .move => |m| {
            _ = grid.selectAt(m.x, m.y);
        },
        .click => |m| {
            if (grid.tileAt(m.x, m.y) != null) {
                _ = grid.selectAt(m.x, m.y);
                hooks.activate_selected(hooks.ctx);
            } else if (!grid.isInsideSearchBox(m.x, m.y)) {
                hooks.hide(hooks.ctx);
            }
        },
        // Context-menu presentation is platform-specific. MainWindow handles
        // this action after selecting/repainting so native menus appear over
        // the updated selection.
        .context => |m| {
            _ = grid.selectAt(m.x, m.y);
        },
    }
}
