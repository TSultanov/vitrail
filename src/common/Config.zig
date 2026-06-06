// Persisted user settings: the keyboard hotkey and the custom mouse button
// that summon the grid. Pure logic + std only — no platform deps — so it can
// be unit-tested standalone (`zig test src/common/Config.zig`).
//
// On-disk format is JSON (std.json round-trips the plain-scalar struct below).
// `keycode` and the mouse `code` are *platform-native* values (Apple virtual
// keycodes / NSEvent buttonNumber on macOS, VK_/XBUTTON on Windows); the file
// is therefore per-machine and not portable between OSes. That is fine — config
// lives in each OS's per-user app-data directory.

const std = @import("std");
const builtin = @import("builtin");

pub const Mods = struct {
    shift: bool = false,
    control: bool = false,
    alt: bool = false, // Option on macOS
    super: bool = false, // Command on macOS, Win key on Windows
};

pub const KeyBinding = struct {
    /// Platform-native virtual keycode. 0 means "unset" — `loadOrDefault`
    /// patches it from the platform default so a hand-edited partial file or a
    /// future schema bump still yields a working hotkey.
    keycode: u32 = 0,
    mods: Mods = .{},
};

pub const MouseButtonKind = enum { none, left, right, middle, x1, x2, other };

pub const MouseBinding = struct {
    kind: MouseButtonKind = .none,
    /// Raw platform button number/code captured at bind time. Meaningful for
    /// `.other`; for the named kinds it is informational.
    code: u32 = 0,
};

pub const Settings = struct {
    version: u32 = 1,
    keyboard: KeyBinding = .{},
    mouse: MouseBinding = .{},
    mouse_enabled: bool = true,
};

const APP_DIR = "Vitrail";
const FILE_NAME = "config.json";
const MAX_BYTES = 64 * 1024;

/// Absolute path to the config directory (caller owns the returned bytes).
pub fn configDir(allocator: std.mem.Allocator) ![]u8 {
    switch (builtin.target.os.tag) {
        .windows => {
            const base = try std.process.getEnvVarOwned(allocator, "APPDATA");
            defer allocator.free(base);
            return std.fs.path.join(allocator, &.{ base, APP_DIR });
        },
        .macos => {
            const home = try std.process.getEnvVarOwned(allocator, "HOME");
            defer allocator.free(home);
            return std.fs.path.join(allocator, &.{ home, "Library", "Application Support", APP_DIR });
        },
        else => {
            // Linux/other: XDG-ish fallback, unused by current targets.
            const home = try std.process.getEnvVarOwned(allocator, "HOME");
            defer allocator.free(home);
            return std.fs.path.join(allocator, &.{ home, ".config", "vitrail" });
        },
    }
}

/// Absolute path to the config file (caller owns the returned bytes).
pub fn configPath(allocator: std.mem.Allocator) ![]u8 {
    const dir = try configDir(allocator);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, FILE_NAME });
}

/// Load settings from disk, falling back to `fallback` if the file is missing,
/// unreadable, or unparseable. Never fails — a broken config must not stop the
/// app from starting. `fallback` is also used to fill an unset keycode.
pub fn loadOrDefault(allocator: std.mem.Allocator, fallback: Settings) Settings {
    return loadStrict(allocator, fallback) catch fallback;
}

fn loadStrict(allocator: std.mem.Allocator, fallback: Settings) !Settings {
    const path = try configPath(allocator);
    defer allocator.free(path);

    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, MAX_BYTES);
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(Settings, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    // Settings holds only scalars/enums (no pointers into the parse arena), so
    // copying the value out by-value before deinit is safe.
    var s = parsed.value;
    if (s.keyboard.keycode == 0) s.keyboard = fallback.keyboard;
    return s;
}

/// Persist settings atomically (write a temp file, then rename over the target)
/// so a crash mid-write can never leave a half-written config.
pub fn save(self: Settings, allocator: std.mem.Allocator) !void {
    const dir = try configDir(allocator);
    defer allocator.free(dir);
    try std.fs.cwd().makePath(dir);

    const path = try std.fs.path.join(allocator, &.{ dir, FILE_NAME });
    defer allocator.free(path);
    const tmp = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp);

    const json = try std.json.Stringify.valueAlloc(allocator, self, .{ .whitespace = .indent_2 });
    defer allocator.free(json);

    const file = try std.fs.cwd().createFile(tmp, .{ .truncate = true });
    {
        errdefer file.close();
        try file.writeAll(json);
    }
    file.close();

    try std.fs.cwd().rename(tmp, path);
}

// ─── Display helpers (shared by the settings UI) ─────────────────────────────

/// Writes a modifier prefix like "⌃⌥" (symbols) or "Ctrl+Alt+" (text) into
/// `buf` and returns the slice. `symbols` picks the macOS glyph style.
pub fn modsLabel(mods: Mods, symbols: bool, buf: []u8) []const u8 {
    const Part = struct { on: bool, s: []const u8 };
    var w: usize = 0;
    const parts = if (symbols)
        [_]Part{
            .{ .on = mods.control, .s = "⌃" },
            .{ .on = mods.alt, .s = "⌥" },
            .{ .on = mods.shift, .s = "⇧" },
            .{ .on = mods.super, .s = "⌘" },
        }
    else
        [_]Part{
            .{ .on = mods.control, .s = "Ctrl+" },
            .{ .on = mods.alt, .s = "Alt+" },
            .{ .on = mods.shift, .s = "Shift+" },
            .{ .on = mods.super, .s = "Win+" },
        };
    for (parts) |p| {
        if (!p.on) continue;
        if (w + p.s.len > buf.len) break;
        @memcpy(buf[w..][0..p.s.len], p.s);
        w += p.s.len;
    }
    return buf[0..w];
}

/// Human label for a mouse binding, e.g. "Button 4 (back)" or "None".
pub fn mouseButtonLabel(mb: MouseBinding, buf: []u8) []const u8 {
    const fixed: ?[]const u8 = switch (mb.kind) {
        .none => "None",
        .left => "Left button",
        .right => "Right button",
        .middle => "Middle button",
        .x1 => "Button 4 (back)",
        .x2 => "Button 5 (forward)",
        .other => null,
    };
    if (fixed) |s| {
        const n = @min(s.len, buf.len);
        @memcpy(buf[0..n], s[0..n]);
        return buf[0..n];
    }
    return std.fmt.bufPrint(buf, "Button (code {d})", .{mb.code}) catch buf[0..0];
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "round-trips through json" {
    const a = std.testing.allocator;
    const original: Settings = .{
        .keyboard = .{ .keycode = 49, .mods = .{ .alt = true } },
        .mouse = .{ .kind = .x1, .code = 4 },
        .mouse_enabled = true,
    };
    const json = try std.json.Stringify.valueAlloc(a, original, .{ .whitespace = .indent_2 });
    defer a.free(json);

    var parsed = try std.json.parseFromSlice(Settings, a, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expectEqual(original.keyboard.keycode, parsed.value.keyboard.keycode);
    try std.testing.expectEqual(original.keyboard.mods.alt, parsed.value.keyboard.mods.alt);
    try std.testing.expectEqual(MouseButtonKind.x1, parsed.value.mouse.kind);
    try std.testing.expectEqual(@as(u32, 4), parsed.value.mouse.code);
}

test "unset keycode is patched from fallback" {
    const a = std.testing.allocator;
    // A partial file with no keyboard field at all.
    const json = "{\"version\":1,\"mouse\":{\"kind\":\"x2\",\"code\":5}}";
    var parsed = try std.json.parseFromSlice(Settings, a, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var s = parsed.value;
    try std.testing.expectEqual(@as(u32, 0), s.keyboard.keycode);
    const fallback: Settings = .{ .keyboard = .{ .keycode = 0x20, .mods = .{ .alt = true } } };
    if (s.keyboard.keycode == 0) s.keyboard = fallback.keyboard;
    try std.testing.expectEqual(@as(u32, 0x20), s.keyboard.keycode);
    try std.testing.expectEqual(MouseButtonKind.x2, s.mouse.kind);
}

test "ignores unknown fields" {
    const a = std.testing.allocator;
    const json = "{\"version\":1,\"keyboard\":{\"keycode\":49,\"mods\":{\"alt\":true}},\"future_field\":42}";
    var parsed = try std.json.parseFromSlice(Settings, a, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 49), parsed.value.keyboard.keycode);
}

test "mods label symbols and text" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("⌥", modsLabel(.{ .alt = true }, true, &buf));
    try std.testing.expectEqualStrings("⌃⌘", modsLabel(.{ .control = true, .super = true }, true, &buf));
    try std.testing.expectEqualStrings("Alt+", modsLabel(.{ .alt = true }, false, &buf));
    try std.testing.expectEqualStrings("Ctrl+Shift+", modsLabel(.{ .control = true, .shift = true }, false, &buf));
}

test "mouse button labels" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("None", mouseButtonLabel(.{ .kind = .none }, &buf));
    try std.testing.expectEqualStrings("Button 4 (back)", mouseButtonLabel(.{ .kind = .x1, .code = 3 }, &buf));
    try std.testing.expectEqualStrings("Button (code 9)", mouseButtonLabel(.{ .kind = .other, .code = 9 }, &buf));
}
