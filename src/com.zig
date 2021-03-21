const w = @import("windows.zig");
const std = @import("std");
pub const ComError = error{FailedToCreateComObject};

pub const REFIID = ?*const w.IID;
pub const REFGUID = ?*const w.GUID;
