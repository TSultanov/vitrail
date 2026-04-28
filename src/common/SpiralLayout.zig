const std = @import("std");

pub fn numToRow(n: usize) i32 {
    const nf: f64 = @floatFromInt(n);
    const layer: i32 = @intFromFloat(std.math.floor(0.25 * (1 + std.math.sqrt(8 * nf + 1))));
    const layerCellsCount = 4 * layer;
    const sideCellsCount = if (n == 0) 1 else @divTrunc(layerCellsCount, 4);
    const layerStart = if (n == 0) 0 else layer * (2 * layer - 1);
    const layerPosition: i32 = @as(i32, @intCast(n)) - layerStart;
    const side = std.math.ceil(@as(f64, @floatFromInt(layerPosition + 1)) / @as(f64, @floatFromInt(2 * sideCellsCount))) - 1;
    const offset: i32 = if (n == 0) 0 else (if (side == 0) layerPosition else layerCellsCount - layerPosition);
    const row = offset - layer;
    return row;
}

pub fn numToCol(n: usize) i32 {
    const nf: f64 = @floatFromInt(n);
    const layer: i32 = @intFromFloat(std.math.ceil(0.5 * (std.math.sqrt(2 * nf + 1) - 1)));
    const layerCellsCount = 4 * layer;
    const sideCellsCount = if (n == 0) 1 else @divTrunc(layerCellsCount, 4);
    const layerStart = if (n == 0) 0 else 2 * (layer - 1) * ((layer - 1) + 1) + 1;
    const layerPosition: i32 = @as(i32, @intCast(n)) - layerStart;
    const side = std.math.ceil(@as(f64, @floatFromInt(layerPosition + 1)) / @as(f64, @floatFromInt(2 * sideCellsCount))) - 1;
    const offset: i32 = if (n == 0) 0 else (if (side == 0) layerPosition + 1 else layerCellsCount - layerPosition - 1);
    const col = offset - layer;
    return col;
}
