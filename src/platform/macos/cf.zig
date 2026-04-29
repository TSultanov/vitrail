// CoreFoundation helpers for the macOS backend. Pure C → Zig glue, no Cocoa.

const std = @import("std");

pub const c = @cImport({
    @cInclude("CoreFoundation/CoreFoundation.h");
});

/// Copies a CFStringRef into an allocator-owned UTF-8 buffer.
pub fn cfStringDupe(allocator: std.mem.Allocator, str: c.CFStringRef) ![]u8 {
    const len_utf16 = c.CFStringGetLength(str);
    const max_utf8 = c.CFStringGetMaximumSizeForEncoding(len_utf16, c.kCFStringEncodingUTF8) + 1;
    const buf = try allocator.alloc(u8, @intCast(max_utf8));
    errdefer allocator.free(buf);
    if (c.CFStringGetCString(str, buf.ptr, max_utf8, c.kCFStringEncodingUTF8) == 0) {
        return error.CFStringConvert;
    }
    const used = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return try allocator.realloc(buf, used);
}

/// Same but produces a sentinel-terminated slice for callers that want a [:0]u8.
pub fn cfStringDupeZ(allocator: std.mem.Allocator, str: c.CFStringRef) ![:0]u8 {
    const slice = try cfStringDupe(allocator, str);
    defer allocator.free(slice);
    return try allocator.dupeZ(u8, slice);
}

pub fn cfNumberToI64(num: c.CFNumberRef) ?i64 {
    var v: i64 = 0;
    if (c.CFNumberGetValue(num, c.kCFNumberSInt64Type, &v) == 0) return null;
    return v;
}

pub fn cfDictGetString(dict: c.CFDictionaryRef, key: [*:0]const u8) c.CFStringRef {
    const k = c.CFStringCreateWithCString(null, key, c.kCFStringEncodingUTF8) orelse return null;
    defer c.CFRelease(k);
    const v = c.CFDictionaryGetValue(dict, k) orelse return null;
    return @ptrCast(@constCast(v));
}

pub fn cfDictGetNumber(dict: c.CFDictionaryRef, key: [*:0]const u8) c.CFNumberRef {
    const k = c.CFStringCreateWithCString(null, key, c.kCFStringEncodingUTF8) orelse return null;
    defer c.CFRelease(k);
    const v = c.CFDictionaryGetValue(dict, k) orelse return null;
    return @ptrCast(@constCast(v));
}
