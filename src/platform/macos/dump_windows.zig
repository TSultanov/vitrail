// One-off debug binary: dump every entry CGWindowListCopyWindowInfo returns
// with the same options the production code uses, plus all the fields we
// filter on. Build via `zig build dump-windows`, run, inspect stderr.

const std = @import("std");
const cf = @import("cf.zig");
const cgs = @import("cgs.zig");

const cg = @cImport({
    @cInclude("CoreGraphics/CoreGraphics.h");
});

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{ .safety = true }) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const print = std.debug.print;

    // Build Space-ID → index map for context.
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
            print("[spaces] display {d}: {d} space(s)\n", .{ di, scount });
            var si: cg.CFIndex = 0;
            while (si < scount) : (si += 1) {
                const sptr = cg.CFArrayGetValueAtIndex(@ptrCast(spaces_arr), si) orelse continue;
                const sdict: cf.c.CFDictionaryRef = @ptrCast(@constCast(sptr));
                const id_n = cf.cfDictGetNumber(sdict, "id64") orelse continue;
                const id = cf.cfNumberToI64(id_n) orelse continue;
                const idx = space_index.count();
                try space_index.put(id, idx);
                print("[spaces]   id64={d} → idx={d}\n", .{ id, idx });
            }
        }
    } else {
        print("[spaces] CGSCopyManagedDisplaySpaces returned null\n", .{});
    }

    const variants = [_]struct { label: []const u8, opts: cg.CGWindowListOption }{
        .{ .label = "OnScreenOnly", .opts = cg.kCGWindowListOptionOnScreenOnly | cg.kCGWindowListExcludeDesktopElements },
        .{ .label = "All", .opts = cg.kCGWindowListOptionAll | cg.kCGWindowListExcludeDesktopElements },
    };
    for (variants) |variant| {
        const label = variant.label;
        const opts = variant.opts;
        print("\n========== {s} ==========\n", .{label});

        var seen_tabs = std.AutoHashMap(u64, void).init(allocator);
        defer seen_tabs.deinit();

        const arr = cg.CGWindowListCopyWindowInfo(opts, cg.kCGNullWindowID);
        if (arr == null) {
            print("  CGWindowListCopyWindowInfo returned null\n", .{});
            continue;
        }
        defer cf.c.CFRelease(arr);

        const count = cg.CFArrayGetCount(@ptrCast(arr));
        print("  {d} entries\n", .{count});

        var i: cg.CFIndex = 0;
        while (i < count) : (i += 1) {
            const dict_ptr = cg.CFArrayGetValueAtIndex(@ptrCast(arr), i) orelse continue;
            const dict: cf.c.CFDictionaryRef = @ptrCast(@constCast(dict_ptr));

            const layer: i64 = if (cf.cfDictGetNumber(dict, "kCGWindowLayer")) |n|
                cf.cfNumberToI64(n) orelse 999
            else
                999;
            const pid: i64 = if (cf.cfDictGetNumber(dict, "kCGWindowOwnerPID")) |n|
                cf.cfNumberToI64(n) orelse -1
            else
                -1;
            const wid: i64 = if (cf.cfDictGetNumber(dict, "kCGWindowNumber")) |n|
                cf.cfNumberToI64(n) orelse -1
            else
                -1;
            const store: i64 = if (cf.cfDictGetNumber(dict, "kCGWindowStoreType")) |n|
                cf.cfNumberToI64(n) orelse -1
            else
                -1;
            const alpha: f64 = blk: {
                const n = cf.cfDictGetNumber(dict, "kCGWindowAlpha") orelse break :blk -1;
                var v: f64 = 0;
                if (cf.c.CFNumberGetValue(n, cf.c.kCFNumberFloat64Type, &v) == 0) break :blk -1;
                break :blk v;
            };
            const onscreen: i64 = if (cf.cfDictGetNumber(dict, "kCGWindowIsOnscreen")) |n|
                cf.cfNumberToI64(n) orelse -1
            else
                -1;

            var bx: f64 = 0;
            var by: f64 = 0;
            var bw: f64 = 0;
            var bh: f64 = 0;
            if (cf.c.CFDictionaryGetValue(dict, blk: {
                const k = cf.c.CFStringCreateWithCString(null, "kCGWindowBounds", cf.c.kCFStringEncodingUTF8) orelse break :blk null;
                break :blk k;
            })) |bv| {
                const bdict: cf.c.CFDictionaryRef = @ptrCast(@constCast(bv));
                var rect: cg.CGRect = undefined;
                if (cg.CGRectMakeWithDictionaryRepresentation(@ptrCast(bdict), &rect)) {
                    bx = rect.origin.x;
                    by = rect.origin.y;
                    bw = rect.size.width;
                    bh = rect.size.height;
                }
            }
            const sharing: i64 = if (cf.cfDictGetNumber(dict, "kCGWindowSharingState")) |n|
                cf.cfNumberToI64(n) orelse -1
            else
                -1;
            const memuse: i64 = if (cf.cfDictGetNumber(dict, "kCGWindowMemoryUsage")) |n|
                cf.cfNumberToI64(n) orelse -1
            else
                -1;

            const owner_buf = blk: {
                const s = cf.cfDictGetString(dict, "kCGWindowOwnerName") orelse break :blk null;
                break :blk cf.cfStringDupe(allocator, s) catch null;
            };
            defer if (owner_buf) |b| allocator.free(b);
            const title_buf = blk: {
                const s = cf.cfDictGetString(dict, "kCGWindowName") orelse break :blk null;
                break :blk cf.cfStringDupe(allocator, s) catch null;
            };
            defer if (title_buf) |b| allocator.free(b);

            // Lookup space.
            var sid_text: [64]u8 = undefined;
            const sid_str = blk: {
                if (wid < 0) break :blk @as([]const u8, "?");
                var wid_val: c_int = @intCast(wid);
                const wid_cfnum = cf.c.CFNumberCreate(null, cf.c.kCFNumberIntType, &wid_val) orelse
                    break :blk @as([]const u8, "?");
                defer cf.c.CFRelease(wid_cfnum);
                var wid_ptrs = [_]?*const anyopaque{wid_cfnum};
                const wids_arr = cf.c.CFArrayCreate(null, &wid_ptrs, 1, &cf.c.kCFTypeArrayCallBacks) orelse
                    break :blk @as([]const u8, "?");
                defer cf.c.CFRelease(wids_arr);
                const spaces_arr = cgs.CGSCopySpacesForWindows(cid, cgs.SPACE_MASK_ALL, wids_arr) orelse
                    break :blk @as([]const u8, "null");
                defer cf.c.CFRelease(spaces_arr);
                const sc = cg.CFArrayGetCount(@ptrCast(spaces_arr));
                if (sc == 0) break :blk @as([]const u8, "[]");
                if (sc == 1) {
                    const sptr = cg.CFArrayGetValueAtIndex(@ptrCast(spaces_arr), 0) orelse
                        break :blk @as([]const u8, "?");
                    const sn: cf.c.CFNumberRef = @ptrCast(@constCast(sptr));
                    const sid = cf.cfNumberToI64(sn) orelse break :blk @as([]const u8, "?");
                    if (space_index.get(sid)) |idx| {
                        break :blk std.fmt.bufPrint(&sid_text, "{d}→idx{d}", .{ sid, idx }) catch "?";
                    }
                    break :blk std.fmt.bufPrint(&sid_text, "{d}→?", .{sid}) catch "?";
                }
                break :blk std.fmt.bufPrint(&sid_text, "many({d})", .{sc}) catch "?";
            };

            // Apply production filter and tag.
            const has_title = if (title_buf) |b| b.len > 0 else false;
            const is_onscreen = onscreen == 1;
            const has_no_space = std.mem.eql(u8, sid_str, "[]");
            const passes_filter = layer == 0 and
                bw >= 100 and bh >= 50 and
                (is_onscreen or has_title) and
                !(has_no_space and !is_onscreen);
            const tab_key: u64 = blk: {
                var h = std.hash.Wyhash.init(0);
                h.update(std.mem.asBytes(&pid));
                const x_i: i32 = @intFromFloat(@round(bx));
                const y_i: i32 = @intFromFloat(@round(by));
                const x_b: i32 = @divFloor(x_i, 100);
                const y_b: i32 = @divFloor(y_i, 100);
                const w_i: i32 = @intFromFloat(@round(bw));
                const h_i: i32 = @intFromFloat(@round(bh));
                h.update(std.mem.asBytes(&x_b));
                h.update(std.mem.asBytes(&y_b));
                h.update(std.mem.asBytes(&w_i));
                h.update(std.mem.asBytes(&h_i));
                break :blk h.final();
            };
            const is_tab_dup = passes_filter and seen_tabs.contains(tab_key);
            if (passes_filter and !is_tab_dup) try seen_tabs.put(tab_key, {});
            const passes = passes_filter and !is_tab_dup;
            const tag: []const u8 = if (passes) "KEEP" else if (is_tab_dup) "TAB " else "drop";
            print("  [{s}] pid={d:>5} wid={d:>6} L={d:>3} st={d} a={d:.1} on={d:>2} share={d} mem={d:>9} pos=({d:>5.0},{d:>5.0}) {d:>4.0}x{d:<4.0} space={s:<14} owner={s:<24} title={s}\n", .{
                tag,
                pid,
                wid,
                layer,
                store,
                alpha,
                onscreen,
                sharing,
                memuse,
                bx,
                by,
                bw,
                bh,
                sid_str,
                if (owner_buf) |b| b else "(null)",
                if (title_buf) |b| b else "(null)",
            });
        }
    }
}
