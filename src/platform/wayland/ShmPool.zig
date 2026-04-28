const std = @import("std");
const wc = @import("wayland_c.zig");
const c = wc.c;

const Self = @This();

pub const Buffer = struct {
    buf: *c.wl_buffer,
    pixels: []u32,
    busy: bool = false,
};

fd: std.posix.fd_t,
pool: *c.wl_shm_pool,
map: []align(std.heap.page_size_min) u8,
buffers: [2]Buffer,
cur: u1 = 0,
listener: [2]c.wl_buffer_listener,

pub fn init(self: *Self, shm: *c.wl_shm, width: u32, height: u32) !void {
    const stride: usize = width * 4;
    const frame_bytes: usize = stride * height;
    const total: usize = frame_bytes * 2;

    const fd = try std.posix.memfd_create("vitrail-shm", 0);
    errdefer std.posix.close(fd);
    try std.posix.ftruncate(fd, total);

    const map = try std.posix.mmap(null, total, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .SHARED }, fd, 0);
    errdefer std.posix.munmap(map);

    const pool = c.wl_shm_create_pool(shm, fd, @intCast(total)) orelse return error.PoolCreate;
    errdefer c.wl_shm_pool_destroy(pool);

    const w_i: i32 = @intCast(width);
    const h_i: i32 = @intCast(height);
    const stride_i: i32 = @intCast(stride);
    const frame_words: usize = stride / 4 * height;
    const base: [*]u32 = @ptrCast(@alignCast(map.ptr));

    self.* = .{
        .fd = fd,
        .pool = pool,
        .map = map,
        .buffers = undefined,
        .listener = .{
            .{ .release = onRelease0 },
            .{ .release = onRelease1 },
        },
    };

    inline for (0..2) |i| {
        const buf = c.wl_shm_pool_create_buffer(
            pool,
            @intCast(frame_bytes * i),
            w_i,
            h_i,
            stride_i,
            c.WL_SHM_FORMAT_ARGB8888,
        ) orelse return error.BufferCreate;
        self.buffers[i] = .{
            .buf = buf,
            .pixels = base[i * frame_words .. (i + 1) * frame_words],
            .busy = false,
        };
        _ = c.wl_buffer_add_listener(buf, &self.listener[i], self);
    }
}

pub fn deinit(self: *Self) void {
    for (self.buffers) |b| c.wl_buffer_destroy(b.buf);
    c.wl_shm_pool_destroy(self.pool);
    std.posix.munmap(self.map);
    std.posix.close(self.fd);
}

/// Returns the next free buffer to render into, or null if both are still busy.
pub fn acquire(self: *Self) ?*Buffer {
    if (!self.buffers[self.cur].busy) return &self.buffers[self.cur];
    const other: u1 = self.cur ^ 1;
    if (!self.buffers[other].busy) {
        self.cur = other;
        return &self.buffers[self.cur];
    }
    return null;
}

/// Mark the current buffer busy (called after attach+commit). Flips `cur` so the
/// next acquire prefers the other buffer.
pub fn submit(self: *Self, buf: *Buffer) void {
    buf.busy = true;
    self.cur ^= 1;
}

fn onRelease0(data: ?*anyopaque, _: ?*c.wl_buffer) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(data));
    self.buffers[0].busy = false;
}

fn onRelease1(data: ?*anyopaque, _: ?*c.wl_buffer) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(data));
    self.buffers[1].busy = false;
}
