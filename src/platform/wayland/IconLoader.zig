// app_id (and optional .desktop hint) → RgbaIcon, via the freedesktop icon
// theme directories. KDE's KdeBackend provides the .desktop hint
// (Window.desktopFileName); wlroots has none and we fall back to using
// app_id directly.
//
// Resolution order for a given (app_id, hint):
//   1. Locate `.desktop` file: try {hint, app_id, lowercase, suffix-after-dot}
//      under $XDG_DATA_HOME/applications + each $XDG_DATA_DIRS/applications.
//   2. Parse the first `Icon=` line from that .desktop. If none, the icon
//      name *is* the lookup key.
//   3. Walk hicolor + the active KDE/GTK themes for matching files in
//      preference order: PNG sizes near 48 first, then SVG, then pixmaps.
//   4. Decode (libpng or librsvg) into a heap RgbaIcon.
//
// Cache is keyed by app_id; both successes and failures are memoised so
// repeated getWindowList passes cost essentially nothing.

const std = @import("std");
const common = @import("../../common/DesktopWindow.zig");

const c = @cImport({
    @cInclude("stdint.h");
    @cInclude("stdlib.h");
});

extern fn vitrail_decode_png(path: [*:0]const u8, out_pixels: *[*]u8, out_w: *u32, out_h: *u32) c_int;
extern fn vitrail_decode_svg(path: [*:0]const u8, target: u32, out_pixels: *[*]u8, out_w: *u32, out_h: *u32) c_int;

const Self = @This();

const ICON_DECODE_TARGET: u32 = 128;
// Search sizes preferred near our render target (logical 48 → up to ~96 at 2×).
const PNG_SIZE_PREF = [_]u32{ 48, 64, 32, 96, 128, 24, 22, 16, 256 };

allocator: std.mem.Allocator,
cache: std.StringHashMapUnmanaged(?common.RgbaIcon) = .{},
// Owned copies of the keys we hand to `cache`.
key_arena: std.heap.ArenaAllocator,
// Cached XDG search roots (computed once).
data_dirs: std.ArrayListUnmanaged([]const u8) = .{},
home: ?[]const u8 = null,
data_dirs_arena: std.heap.ArenaAllocator,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .allocator = allocator,
        .key_arena = std.heap.ArenaAllocator.init(allocator),
        .data_dirs_arena = std.heap.ArenaAllocator.init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    var it = self.cache.valueIterator();
    while (it.next()) |v| {
        if (v.*) |ic| ic.destroy();
    }
    self.cache.deinit(self.allocator);
    self.key_arena.deinit();
    self.data_dirs.deinit(self.data_dirs_arena.allocator());
    self.data_dirs_arena.deinit();
}

/// Returns a fresh allocator-owned dupe of the resolved icon, or null on
/// any failure.
pub fn loadFor(self: *Self, dw: *const common.DesktopWindow) ?common.RgbaIcon {
    const app_id = std.mem.sliceTo(dw.app_id, 0);
    if (app_id.len == 0) return null;

    if (self.cache.get(app_id)) |cached| {
        return dupeIcon(self.allocator, cached);
    }

    const desktop_hint: ?[]const u8 = if (dw.desktop_file) |df|
        std.mem.sliceTo(df, 0)
    else
        null;

    const resolved = self.resolve(app_id, desktop_hint);
    const key_owned = self.key_arena.allocator().dupe(u8, app_id) catch return null;
    self.cache.put(self.allocator, key_owned, resolved) catch {
        if (resolved) |ic| ic.destroy();
        return null;
    };
    return dupeIcon(self.allocator, resolved);
}

fn dupeIcon(allocator: std.mem.Allocator, src: ?common.RgbaIcon) ?common.RgbaIcon {
    const ic = src orelse return null;
    const pixels = allocator.dupe(u8, ic.pixels) catch return null;
    return .{
        .pixels = pixels,
        .width = ic.width,
        .height = ic.height,
        .allocator = allocator,
    };
}

// ─── Resolution ───────────────────────────────────────────────────────────────

fn resolve(self: *Self, app_id: []const u8, hint: ?[]const u8) ?common.RgbaIcon {
    self.ensureRoots() catch return null;

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Step 1: find a .desktop file. Try the hint first, then app_id and
    // common variations.
    var icon_name: ?[]const u8 = null;
    var candidates_buf: [6][]const u8 = undefined;
    const candidates: []const []const u8 = pickDesktopCandidates(app_id, hint, &candidates_buf);
    for (candidates) |cand| {
        if (self.findDesktopFile(a, cand)) |path| {
            if (parseIconLine(a, path)) |name| {
                icon_name = name;
                break;
            }
        }
    }
    // Step 2: fall back to using app_id (or last suffix) as the icon name.
    if (icon_name == null) {
        icon_name = lastDotSuffix(hint orelse app_id);
    }
    const name = icon_name.?;
    if (name.len == 0) return null;

    // Step 3: if Icon= already gave us an absolute path, use it directly.
    if (name.len > 0 and name[0] == '/') {
        return decodeAuto(self.allocator, a, name);
    }

    // Step 4: walk theme dirs.
    if (self.findIconFile(a, name)) |found| {
        return decodeAuto(self.allocator, a, found);
    }
    return null;
}

fn pickDesktopCandidates(app_id: []const u8, hint: ?[]const u8, buf: *[6][]const u8) []const []const u8 {
    var n: usize = 0;
    if (hint) |h| {
        if (h.len > 0) {
            buf[n] = h;
            n += 1;
        }
    }
    buf[n] = app_id;
    n += 1;
    // Suffix after last dot — handles "org.mozilla.firefox" → "firefox".
    const suf = lastDotSuffix(app_id);
    if (suf.len > 0 and !std.mem.eql(u8, suf, app_id)) {
        buf[n] = suf;
        n += 1;
    }
    return buf[0..n];
}

fn lastDotSuffix(s: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, s, '.')) |i| {
        if (i + 1 < s.len) return s[i + 1 ..];
    }
    return s;
}

fn ensureRoots(self: *Self) !void {
    if (self.home != null) return;
    const a = self.data_dirs_arena.allocator();
    self.home = std.process.getEnvVarOwned(a, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (std.process.getEnvVarOwned(a, "XDG_DATA_HOME")) |v| {
        try self.data_dirs.append(a, v);
    } else |_| {
        if (self.home) |h| {
            try self.data_dirs.append(a, try std.fmt.allocPrint(a, "{s}/.local/share", .{h}));
        }
    }
    if (std.process.getEnvVarOwned(a, "XDG_DATA_DIRS")) |v| {
        var it = std.mem.splitScalar(u8, v, ':');
        while (it.next()) |part| {
            if (part.len > 0) try self.data_dirs.append(a, try a.dupe(u8, part));
        }
    } else |_| {
        try self.data_dirs.append(a, "/usr/local/share");
        try self.data_dirs.append(a, "/usr/share");
    }
}

fn findDesktopFile(self: *Self, a: std.mem.Allocator, name: []const u8) ?[]const u8 {
    for (self.data_dirs.items) |root| {
        const path = std.fmt.allocPrint(a, "{s}/applications/{s}.desktop", .{ root, name }) catch continue;
        if (fileExists(path)) return path;
    }
    return null;
}

fn parseIconLine(a: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const f = std.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    const data = f.readToEndAlloc(a, 256 * 1024) catch return null;
    // Find a line starting with "Icon=" outside the [Desktop Action ...] groups.
    // The first Icon= we encounter is reliably from [Desktop Entry] in practice;
    // strict spec compliance would track group headers, but actions list their
    // own Icon= last and apps are robust to either.
    var lines = std.mem.splitScalar(u8, data, '\n');
    var in_entry = true;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '[') {
            in_entry = std.mem.eql(u8, trimmed, "[Desktop Entry]");
            continue;
        }
        if (!in_entry) continue;
        if (std.mem.startsWith(u8, trimmed, "Icon=")) {
            const v = std.mem.trim(u8, trimmed["Icon=".len..], " \t\r");
            return a.dupe(u8, v) catch null;
        }
    }
    return null;
}

fn findIconFile(self: *Self, a: std.mem.Allocator, name: []const u8) ?[]const u8 {
    // Themes to search — active KDE theme via `kreadconfig5`-style file
    // lookup is overkill; covering Breeze (KDE default), Adwaita (GNOME
    // default) and hicolor catches near-everything on Fedora.
    const themes = [_][]const u8{ "breeze", "Adwaita", "hicolor" };

    // PNG size variants under each theme.
    for (self.data_dirs.items) |root| {
        for (themes) |theme| {
            for (PNG_SIZE_PREF) |sz| {
                const path = std.fmt.allocPrint(a, "{s}/icons/{s}/{d}x{d}/apps/{s}.png", .{ root, theme, sz, sz, name }) catch continue;
                if (fileExists(path)) return path;
            }
        }
    }
    // Scalable SVG under each theme.
    for (self.data_dirs.items) |root| {
        for (themes) |theme| {
            const path = std.fmt.allocPrint(a, "{s}/icons/{s}/scalable/apps/{s}.svg", .{ root, theme, name }) catch continue;
            if (fileExists(path)) return path;
        }
    }
    // KDE Breeze nests by category (apps/16/, apps/32/, ...) — try a few.
    for (self.data_dirs.items) |root| {
        for ([_][]const u8{ "breeze", "Adwaita" }) |theme| {
            for ([_]u32{ 48, 64, 32, 22, 16 }) |sz| {
                const path = std.fmt.allocPrint(a, "{s}/icons/{s}/apps/{d}/{s}.svg", .{ root, theme, sz, name }) catch continue;
                if (fileExists(path)) return path;
            }
        }
    }
    // /usr/share/pixmaps fallback (legacy apps).
    for (self.data_dirs.items) |root| {
        for ([_][]const u8{ "png", "svg", "xpm" }) |ext| {
            const path = std.fmt.allocPrint(a, "{s}/pixmaps/{s}.{s}", .{ root, name, ext }) catch continue;
            if (fileExists(path)) return path;
        }
    }
    return null;
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

// ─── Decoding ─────────────────────────────────────────────────────────────────

fn decodeAuto(out_alloc: std.mem.Allocator, scratch: std.mem.Allocator, path: []const u8) ?common.RgbaIcon {
    const path_z = scratch.dupeZ(u8, path) catch return null;
    if (std.mem.endsWith(u8, path, ".png")) return decodePng(out_alloc, path_z);
    if (std.mem.endsWith(u8, path, ".svg")) return decodeSvg(out_alloc, path_z);
    return null;
}

fn decodePng(out_alloc: std.mem.Allocator, path_z: [:0]const u8) ?common.RgbaIcon {
    var raw: [*]u8 = undefined;
    var w: u32 = 0;
    var h: u32 = 0;
    if (vitrail_decode_png(path_z.ptr, &raw, &w, &h) != 0) return null;
    defer c.free(raw);
    if (w == 0 or h == 0) return null;
    const size: usize = @as(usize, w) * @as(usize, h) * 4;
    const pixels = out_alloc.dupe(u8, raw[0..size]) catch return null;
    return .{ .pixels = pixels, .width = w, .height = h, .allocator = out_alloc };
}

fn decodeSvg(out_alloc: std.mem.Allocator, path_z: [:0]const u8) ?common.RgbaIcon {
    var raw: [*]u8 = undefined;
    var w: u32 = 0;
    var h: u32 = 0;
    if (vitrail_decode_svg(path_z.ptr, ICON_DECODE_TARGET, &raw, &w, &h) != 0) return null;
    defer c.free(raw);
    if (w == 0 or h == 0) return null;
    const size: usize = @as(usize, w) * @as(usize, h) * 4;
    const pixels = out_alloc.dupe(u8, raw[0..size]) catch return null;
    return .{ .pixels = pixels, .width = w, .height = h, .allocator = out_alloc };
}
