const wh = @import("windows.zig");
const w = wh.c;
const std = @import("std");
pub const ComError = error{FailedToCreateComObject};

pub const REFIID = ?*const w.IID;
pub const REFGUID = ?*const w.GUID;
