// Carbon RegisterEventHotKey wrapper. Carbon is C-callable, so this is a
// pure-Zig module — no Obj-C bridging needed. The handler runs on the main
// thread (event loop) and forwards the press into a Zig callback.

const std = @import("std");
const Config = @import("../../common/Config.zig");

const c = @cImport({
    @cInclude("Carbon/Carbon.h");
});

pub const Modifiers = packed struct(u32) {
    shift: bool = false,
    control: bool = false,
    option: bool = false,
    command: bool = false,
    _padding: u28 = 0,

    fn toCarbon(self: Modifiers) u32 {
        var m: u32 = 0;
        if (self.shift) m |= c.shiftKey;
        if (self.control) m |= c.controlKey;
        if (self.option) m |= c.optionKey;
        if (self.command) m |= c.cmdKey;
        return m;
    }
};

pub const Binding = struct {
    keycode: u32,
    modifiers: Modifiers,
};

// Option+Space — the default binding. Cmd+Space is Spotlight and
// Cmd+Option+Space is "Search this Mac" in Finder.
pub const default_binding: Binding = .{
    .keycode = c.kVK_Space,
    .modifiers = .{ .option = true },
};

/// Convert the platform-neutral config binding into a Carbon binding. alt maps
/// to Option, super to Command — the macOS modifier naming.
pub fn fromConfig(kb: Config.KeyBinding) Binding {
    return .{
        .keycode = kb.keycode,
        .modifiers = .{
            .shift = kb.mods.shift,
            .control = kb.mods.control,
            .option = kb.mods.alt,
            .command = kb.mods.super,
        },
    };
}

/// Inverse of `fromConfig` — used to seed the config fallback from
/// `default_binding`.
pub fn toConfig(b: Binding) Config.KeyBinding {
    return .{
        .keycode = b.keycode,
        .mods = .{
            .shift = b.modifiers.shift,
            .control = b.modifiers.control,
            .alt = b.modifiers.option,
            .super = b.modifiers.command,
        },
    };
}

pub const Callback = *const fn (ctx: *anyopaque) void;

const Self = @This();

ref: c.EventHotKeyRef = null,
handler_ref: c.EventHandlerRef = null,
on_press: Callback,
ctx: *anyopaque,

pub fn init(self: *Self, binding: Binding, on_press: Callback, ctx: *anyopaque) !void {
    self.* = .{
        .on_press = on_press,
        .ctx = ctx,
    };

    var spec = c.EventTypeSpec{
        .eventClass = c.kEventClassKeyboard,
        .eventKind = c.kEventHotKeyPressed,
    };
    const status = c.InstallEventHandler(
        c.GetApplicationEventTarget(),
        eventHandler,
        1,
        &spec,
        @ptrCast(self),
        &self.handler_ref,
    );
    if (status != 0) return error.InstallEventHandlerFailed;
    errdefer _ = c.RemoveEventHandler(self.handler_ref);

    try self.rebind(binding);
}

/// Replace the registered key combo at runtime. Unregisters the previous combo
/// (the installed event handler stays put) and registers the new one. Used when
/// the user edits the hotkey in the settings UI.
pub fn rebind(self: *Self, binding: Binding) !void {
    if (self.ref != null) {
        _ = c.UnregisterEventHotKey(self.ref);
        self.ref = null;
    }
    const id = c.EventHotKeyID{ .signature = signature("vtkl"), .id = 1 };
    const reg = c.RegisterEventHotKey(
        binding.keycode,
        binding.modifiers.toCarbon(),
        id,
        c.GetApplicationEventTarget(),
        0,
        &self.ref,
    );
    if (reg != 0) return error.RegisterHotKeyFailed;
}

/// Unregister the current combo while keeping the installed event handler, so
/// the keydown flows to the focused window (used while the settings UI records a
/// new combo). Re-arm with `rebind`.
pub fn unregister(self: *Self) void {
    if (self.ref != null) {
        _ = c.UnregisterEventHotKey(self.ref);
        self.ref = null;
    }
}

pub fn deinit(self: *Self) void {
    if (self.ref != null) _ = c.UnregisterEventHotKey(self.ref);
    if (self.handler_ref != null) _ = c.RemoveEventHandler(self.handler_ref);
}

fn signature(comptime s: *const [4]u8) c.OSType {
    return (@as(u32, s[0]) << 24) | (@as(u32, s[1]) << 16) | (@as(u32, s[2]) << 8) | @as(u32, s[3]);
}

fn eventHandler(
    _: c.EventHandlerCallRef,
    _: c.EventRef,
    user_data: ?*anyopaque,
) callconv(.c) c.OSStatus {
    const self: *Self = @ptrCast(@alignCast(user_data orelse return c.eventNotHandledErr));
    self.on_press(self.ctx);
    return 0; // noErr
}
