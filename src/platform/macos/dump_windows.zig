// One-off debug binary: walk the same AX path the production backend uses
// and print every AX window encountered, with the kept-or-dropped tag and
// reason. Build via `zig build dump-windows`, run, inspect stderr.
//
// Mirrors AXWindowBackend.getWindowList: NSWorkspace.runningApplications →
// per-pid kAXWindowsAttribute → subrole + size filter → CGS Space lookup.

const std = @import("std");
const ax = @import("ax.zig");
const bridge = @import("bridge.zig");
const cf = @import("cf.zig");
const cgs = @import("cgs.zig");

const cg = @cImport({
    @cInclude("CoreGraphics/CoreGraphics.h");
});

fn cfStr(s: [*:0]const u8) ?cf.c.CFStringRef {
    return cf.c.CFStringCreateWithCString(null, s, cf.c.kCFStringEncodingUTF8);
}

fn copyStringAttr(allocator: std.mem.Allocator, elem: ax.UIElementRef, key: cf.c.CFStringRef) ?[]u8 {
    var ref: cf.c.CFTypeRef = null;
    if (ax.AXUIElementCopyAttributeValue(elem, key, &ref) != ax.kAXErrorSuccess) return null;
    if (ref == null) return null;
    defer cf.c.CFRelease(ref);
    const s: cf.c.CFStringRef = @ptrCast(@constCast(ref));
    return cf.cfStringDupe(allocator, s) catch null;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{ .safety = true }) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Init NSApp + install the activation observer so vt_app_activation_ordinal
    // returns the same seeded values the production app sees on cold start.
    bridge.vt_app_init();

    const print = std.debug.print;
    print("[ax] AXIsProcessTrusted = {d}\n", .{ax.AXIsProcessTrusted()});

    // Build Space-ID → 0-based-index map.
    const cid = cgs.CGSMainConnectionID();
    var space_index = std.AutoHashMap(i64, usize).init(allocator);
    defer space_index.deinit();
    if (cgs.CGSCopyManagedDisplaySpaces(cid)) |displays| {
        defer cf.c.CFRelease(displays);
        const dcount = cg.CFArrayGetCount(@ptrCast(displays));
        var di: cg.CFIndex = 0;
        print("[spaces] {d} display(s)\n", .{dcount});
        while (di < dcount) : (di += 1) {
            const dptr = cg.CFArrayGetValueAtIndex(@ptrCast(displays), di) orelse continue;
            const ddict: cf.c.CFDictionaryRef = @ptrCast(@constCast(dptr));
            const spaces_arr = cf.cfDictGetArray(ddict, "Spaces") orelse continue;
            const scount = cg.CFArrayGetCount(@ptrCast(spaces_arr));
            var si: cg.CFIndex = 0;
            while (si < scount) : (si += 1) {
                const sptr = cg.CFArrayGetValueAtIndex(@ptrCast(spaces_arr), si) orelse continue;
                const sdict: cf.c.CFDictionaryRef = @ptrCast(@constCast(sptr));
                const id_n = cf.cfDictGetNumber(sdict, "id64") orelse continue;
                const id = cf.cfNumberToI64(id_n) orelse continue;
                const idx = space_index.count();
                try space_index.put(id, idx);
            }
        }
    }

    if (ax.AXIsProcessTrusted() == 0) {
        print("[ax] not trusted — production backend would return empty list. Aborting dump.\n", .{});
        return;
    }

    // Global onscreen z-order — same map the production backend builds.
    var wid_zorder = std.AutoHashMap(u32, u32).init(allocator);
    defer wid_zorder.deinit();
    {
        const opts: u32 = cg.kCGWindowListOptionOnScreenOnly | cg.kCGWindowListExcludeDesktopElements;
        if (cg.CGWindowListCopyWindowInfo(opts, cg.kCGNullWindowID)) |arr| {
            defer cf.c.CFRelease(arr);
            const n = cg.CFArrayGetCount(@ptrCast(arr));
            var i: cg.CFIndex = 0;
            while (i < n) : (i += 1) {
                const dptr = cg.CFArrayGetValueAtIndex(@ptrCast(arr), i) orelse continue;
                const dict: cf.c.CFDictionaryRef = @ptrCast(@constCast(dptr));
                const num = cf.cfDictGetNumber(dict, "kCGWindowNumber") orelse continue;
                var v: i64 = 0;
                if (cf.c.CFNumberGetValue(num, cf.c.kCFNumberSInt64Type, &v) == 0) continue;
                const wid: u32 = @intCast(v);
                if (!wid_zorder.contains(wid)) try wid_zorder.put(wid, @intCast(i));
            }
        }
    }
    print("[zorder] {d} onscreen window(s)\n", .{wid_zorder.count()});

    const k_windows = cfStr("AXWindows") orelse return;
    defer cf.c.CFRelease(k_windows);
    const k_title = cfStr("AXTitle") orelse return;
    defer cf.c.CFRelease(k_title);
    const k_subrole = cfStr("AXSubrole") orelse return;
    defer cf.c.CFRelease(k_subrole);
    const k_role = cfStr("AXRole") orelse return;
    defer cf.c.CFRelease(k_role);
    const k_size = cfStr("AXSize") orelse return;
    defer cf.c.CFRelease(k_size);
    const k_position = cfStr("AXPosition") orelse return;
    defer cf.c.CFRelease(k_position);
    const v_standard = cfStr("AXStandardWindow") orelse return;
    defer cf.c.CFRelease(v_standard);
    const v_dialog = cfStr("AXDialog") orelse return;
    defer cf.c.CFRelease(v_dialog);

    var pid_count: c_int = 0;
    const pids_ptr = bridge.vt_running_pids(&pid_count) orelse {
        print("[pids] vt_running_pids returned null\n", .{});
        return;
    };
    defer bridge.vt_free(@ptrCast(pids_ptr));
    print("[pids] {d} regular-policy app(s)\n\n", .{pid_count});
    if (pid_count <= 0) return;
    const pids = pids_ptr[0..@intCast(pid_count)];

    // Mirrors AXWindowBackend dedupe state. emitted_wids dedupes between
    // phase-1 (AXWindows) and phase-2 (brute-force) for each pid.
    var emitted_wids = std.AutoHashMap(u32, void).init(allocator);
    defer emitted_wids.deinit();

    for (pids) |pid_c| {
        const pid: i32 = @intCast(pid_c);
        const app_elem = ax.AXUIElementCreateApplication(pid) orelse {
            print("pid={d:<6} <AXUIElementCreateApplication returned null>\n", .{pid});
            continue;
        };
        defer cf.c.CFRelease(app_elem);

        const app_name_c = bridge.vt_app_name_for_pid(pid);
        defer if (app_name_c) |p| bridge.vt_free(@ptrCast(@constCast(p)));
        const app_name: []const u8 = if (app_name_c) |p| std.mem.sliceTo(p, 0) else "(?)";
        const app_ordinal = bridge.vt_app_activation_ordinal(pid);

        // Phase 1: AXWindows.
        var wins_ref: cf.c.CFTypeRef = null;
        const err = ax.AXUIElementCopyAttributeValue(app_elem, k_windows, &wins_ref);
        if (err == ax.kAXErrorSuccess and wins_ref != null) {
            defer cf.c.CFRelease(wins_ref);
            const wins_arr: cf.c.CFArrayRef = @ptrCast(@constCast(wins_ref));
            const wcount = cg.CFArrayGetCount(@ptrCast(wins_arr));
            print("pid={d:<6} app=\"{s}\" mru={d} wins={d}\n", .{ pid, app_name, app_ordinal, wcount });
            var wi: cg.CFIndex = 0;
            while (wi < wcount) : (wi += 1) {
                const wptr = cg.CFArrayGetValueAtIndex(@ptrCast(wins_arr), wi) orelse continue;
                const win_elem: ax.UIElementRef = @ptrCast(@constCast(wptr));
                _ = try printAxWindow(allocator, win_elem, "AXWindows", k_role, k_subrole, k_title, k_size, k_position, &space_index, &wid_zorder, &emitted_wids, cid);
            }
        } else {
            const reason: []const u8 = switch (err) {
                ax.kAXErrorAPIDisabled => "axdisabled",
                ax.kAXErrorAttributeUnsupported => "unsupported",
                ax.kAXErrorNoValue => "novalue",
                else => if (err == ax.kAXErrorSuccess) "nullref" else "axerr",
            };
            print("pid={d:<6} app=\"{s}\" mru={d} wins=- [{s}={d}]\n", .{ pid, app_name, app_ordinal, reason, err });
        }

        // Phase 2: brute-force AX scan via _AXUIElementCreateWithRemoteToken.
        // Iterate ax-element-id 0..1000, capped at 100ms per app, filter
        // by AXSubrole. Discovers off-Space windows AX hides from
        // kAXWindowsAttribute.
        const before = emitted_wids.count();
        try bruteForceMirror(allocator, pid, k_role, k_subrole, k_title, k_size, k_position, &space_index, &wid_zorder, &emitted_wids, cid);
        const added = emitted_wids.count() - before;
        if (added > 0) print("  (brute-force phase 2 added {d} window(s))\n", .{added});
    }
}

fn bruteForceMirror(
    allocator: std.mem.Allocator,
    pid: i32,
    k_role: cf.c.CFStringRef,
    k_subrole: cf.c.CFStringRef,
    k_title: cf.c.CFStringRef,
    k_size: cf.c.CFStringRef,
    k_position: cf.c.CFStringRef,
    space_index: *std.AutoHashMap(i64, usize),
    wid_zorder: *std.AutoHashMap(u32, u32),
    emitted_wids: *std.AutoHashMap(u32, void),
    cid: cgs.ConnectionID,
) !void {
    var token: [20]u8 = std.mem.zeroes([20]u8);
    std.mem.writeInt(i32, token[0..4], pid, .little);
    std.mem.writeInt(i32, token[8..12], 0x636f636f, .little);

    const start_ns = std.time.nanoTimestamp();
    var ax_id: u64 = 0;
    while (ax_id < 1000) : (ax_id += 1) {
        std.mem.writeInt(u64, token[12..20], ax_id, .little);
        const data = cf.c.CFDataCreate(null, &token, 20) orelse continue;
        defer cf.c.CFRelease(data);
        const elem = ax._AXUIElementCreateWithRemoteToken(data) orelse continue;
        defer cf.c.CFRelease(elem);

        var wid: u32 = 0;
        if (ax._AXUIElementGetWindow(elem, &wid) != ax.kAXErrorSuccess) continue;
        if (wid == 0) continue;
        if (emitted_wids.contains(wid)) continue;

        _ = try printAxWindow(allocator, elem, "BruteForce", k_role, k_subrole, k_title, k_size, k_position, space_index, wid_zorder, emitted_wids, cid);

        if ((std.time.nanoTimestamp() - start_ns) > 100 * std.time.ns_per_ms) break;
    }
}

fn printAxWindow(
    allocator: std.mem.Allocator,
    win_elem: ax.UIElementRef,
    source: []const u8,
    k_role: cf.c.CFStringRef,
    k_subrole: cf.c.CFStringRef,
    k_title: cf.c.CFStringRef,
    k_size: cf.c.CFStringRef,
    k_position: cf.c.CFStringRef,
    space_index: *std.AutoHashMap(i64, usize),
    wid_zorder: *std.AutoHashMap(u32, u32),
    emitted_wids: *std.AutoHashMap(u32, void),
    cid: cgs.ConnectionID,
) !bool {
    const print = std.debug.print;

    const role = copyStringAttr(allocator, win_elem, k_role) orelse try allocator.dupe(u8, "(?)");
    defer allocator.free(role);
    const subrole = copyStringAttr(allocator, win_elem, k_subrole) orelse try allocator.dupe(u8, "(?)");
    defer allocator.free(subrole);
    const title = copyStringAttr(allocator, win_elem, k_title) orelse try allocator.dupe(u8, "");
    defer allocator.free(title);

    var size: cg.CGSize = .{ .width = 0, .height = 0 };
    var have_size = false;
    {
        var size_ref: cf.c.CFTypeRef = null;
        if (ax.AXUIElementCopyAttributeValue(win_elem, k_size, &size_ref) == ax.kAXErrorSuccess and size_ref != null) {
            defer cf.c.CFRelease(size_ref);
            have_size = ax.AXValueGetValue(@ptrCast(@constCast(size_ref)), ax.kAXValueTypeCGSize, &size) != 0;
        }
    }

    var pos: cg.CGPoint = .{ .x = 0, .y = 0 };
    {
        var pos_ref: cf.c.CFTypeRef = null;
        if (ax.AXUIElementCopyAttributeValue(win_elem, k_position, &pos_ref) == ax.kAXErrorSuccess and pos_ref != null) {
            defer cf.c.CFRelease(pos_ref);
            _ = ax.AXValueGetValue(@ptrCast(@constCast(pos_ref)), ax.kAXValueTypeCGPoint, &pos);
        }
    }

    var wid: u32 = 0;
    const wid_err = ax._AXUIElementGetWindow(win_elem, &wid);

    const subrole_ok = std.mem.eql(u8, subrole, "AXStandardWindow") or std.mem.eql(u8, subrole, "AXDialog");
    const size_ok = have_size and size.width >= 100 and size.height >= 50;
    const wid_ok = wid_err == ax.kAXErrorSuccess;
    const passes = subrole_ok and size_ok and wid_ok;

    var sid_text: [64]u8 = undefined;
    const sid_str: []const u8 = if (!wid_ok) "?" else blk: {
        var wid_val: c_int = @intCast(wid);
        const wid_cfnum = cf.c.CFNumberCreate(null, cf.c.kCFNumberIntType, &wid_val) orelse break :blk "?";
        defer cf.c.CFRelease(wid_cfnum);
        var wid_ptrs = [_]?*const anyopaque{wid_cfnum};
        const wids_arr = cf.c.CFArrayCreate(null, &wid_ptrs, 1, &cf.c.kCFTypeArrayCallBacks) orelse break :blk "?";
        defer cf.c.CFRelease(wids_arr);
        const spaces_arr = cgs.CGSCopySpacesForWindows(cid, cgs.SPACE_MASK_ALL, wids_arr) orelse break :blk "null";
        defer cf.c.CFRelease(spaces_arr);
        const sc = cg.CFArrayGetCount(@ptrCast(spaces_arr));
        if (sc == 0) break :blk "[]";
        if (sc == 1) {
            const sptr = cg.CFArrayGetValueAtIndex(@ptrCast(spaces_arr), 0) orelse break :blk "?";
            const sn: cf.c.CFNumberRef = @ptrCast(@constCast(sptr));
            const sid = cf.cfNumberToI64(sn) orelse break :blk "?";
            if (space_index.get(sid)) |idx| {
                break :blk std.fmt.bufPrint(&sid_text, "{d}→idx{d}", .{ sid, idx }) catch "?";
            }
            break :blk std.fmt.bufPrint(&sid_text, "{d}→?", .{sid}) catch "?";
        }
        break :blk std.fmt.bufPrint(&sid_text, "many({d})", .{sc}) catch "?";
    };

    const tag: []const u8 = if (passes)
        "KEEP"
    else if (!subrole_ok)
        "drop:subrole"
    else if (!size_ok)
        "drop:size"
    else
        "drop:wid";

    var z_text: [16]u8 = undefined;
    const z_str: []const u8 = if (wid_ok) blk: {
        if (wid_zorder.get(wid)) |z| break :blk std.fmt.bufPrint(&z_text, "{d}", .{z}) catch "?";
        break :blk "-";
    } else "?";

    print("  [{s:<12}] src={s:<12} role={s:<12} subrole={s:<20} wid={d:>6} z={s:<3} pos=({d:>5.0},{d:>5.0}) {d:>4.0}x{d:<4.0} space={s:<14} title=\"{s}\"\n", .{
        tag,
        source,
        role,
        subrole,
        wid,
        z_str,
        pos.x,
        pos.y,
        size.width,
        size.height,
        sid_str,
        title,
    });

    if (passes) try emitted_wids.put(wid, {});
    return passes;
}
