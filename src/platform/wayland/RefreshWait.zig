const std = @import("std");

/// Keep the overlay event loop responsive while KDE's enumeration script is
/// waiting for its D-Bus callback. Without a pump, preserve sd-bus's original
/// full-deadline wait.
pub const PUMP_SLICE_US: u64 = 8_000;

pub fn timeoutSlice(remaining_us: u64, pump_enabled: bool) u64 {
    if (!pump_enabled) return remaining_us;
    return @min(remaining_us, PUMP_SLICE_US);
}

test "KDE wait pumping bounds long waits without extending short deadlines" {
    try std.testing.expectEqual(@as(u64, 2_000_000), timeoutSlice(2_000_000, false));
    try std.testing.expectEqual(PUMP_SLICE_US, timeoutSlice(2_000_000, true));
    try std.testing.expectEqual(@as(u64, 1_250), timeoutSlice(1_250, true));
}
