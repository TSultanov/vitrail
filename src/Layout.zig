usingnamespace @import("vitrail.zig");
pub const Window = @import("Window.zig");

const Self = @This();

window: *Window,

matrix: ?[]?usize = null,
focusedIdx: usize = 0,
focusedCol: usize = undefined,
focusedRow: usize = undefined,
rows: usize = 0,
cols: usize = 0,
allocator: *std.mem.Allocator,
event_handlers: Window.EventHandlers,

const chWidth: c_int = 101;
const chHeight: c_int = 101;
const margin: c_int = -1;

fn onResizeHandler(event_handlers: *Window.EventHandlers, window: *Window) !void {
    if(window.docked)
    {
        try window.dock();
    }

    const rect = try window.getRect();

    const self = @fieldParentPtr(Self, "event_handlers", event_handlers);

    try self.layout();
}

fn onPaintHandler(event_handlers: *Window.EventHandlers, window: *Window) !void {
    var ps: w.PAINTSTRUCT = undefined;
    var hdc = w.BeginPaint(window.hwnd, &ps);
    defer _ = w.EndPaint(window.hwnd, &ps);
    defer _ = w.ReleaseDC(window.hwnd, hdc);
    //var color = w.GetSysColor(w.COLOR_WINDOW);
    var hbrushBg = w.CreateSolidBrush(0x00000000);
    defer w.mapFailure(w.DeleteObject(hbrushBg)) catch std.debug.panic("Failed to call DeleteObject() on {*}\n", .{hbrushBg});
    try w.mapFailure(w.FillRect(hdc, &ps.rcPaint, hbrushBg));
}

pub fn create(hInstance: w.HINSTANCE, parent: *Window, allocator: *std.mem.Allocator) !*Self {
    const windowConfig = Window.WindowParameters {
        .title = toUtf16const("SpiralLayout"),
        .className = toUtf16const("SpiralLayout"),
        .style = w.WS_VISIBLE | w.WS_CHILD,
        .parent = parent,
        .register_class = true
    };
    var self = try allocator.create(Self);
    self.* = .{
        .window = undefined,
        .allocator = allocator,
        .event_handlers = .{ .onResize = onResizeHandler, .onPaint = onPaintHandler }
    };
    
    var window: *Window = try Window.create(windowConfig, &self.event_handlers, hInstance, allocator);
    window.docked = true;

    self.window = window;
    return self;
}

pub fn clear(self: *Self) !void {
    //var wnd: ?*Window = self.window.children.popOrNull();

    while (self.window.children.popOrNull()) |window|
    {
        try window.destroy();
        self.allocator.destroy(window);
    }
}

fn layout(self: *Self) !void {
    if (self.window.children.items.len == 0) return;

    for (self.window.children.items) |child| {
        _ = child.hide();
    }

    var rect = try self.window.getRect();

    var width = rect.right - rect.left;
    var height = rect.bottom - rect.top;
    var rsize = self.window.children.items.len;

    var rows = @intCast(usize, @divFloor(height, chHeight));
    var cols = @intCast(usize, @divFloor(width, chWidth));
    self.rows = rows;
    self.cols = cols;

    var cur_x = @divFloor(width, 2) - @divFloor(chWidth, 2);
    var cur_y = @divFloor(height, 2) - @divFloor(chHeight, 2);
    var cur_col = @divFloor(cols, 2);
    var cur_row = @divFloor(rows, 2);

    if (self.matrix != null) {
        self.allocator.free(self.matrix.?);
    }
    self.matrix = try self.allocator.alloc(?usize, cols * rows);
    for (self.matrix.?) |*elem| {
        elem.* = null;
    }

    var i: usize = 0;
    var offset: usize = 0;
    var max_offset = @divFloor(width * 2, chWidth) + @divFloor(height * 2, chHeight);
    var side: usize = 0;
    while (i < rsize) {
        var j: usize = 0;
        while (true) {
            if (i == rsize) {
                break;
            }
            if (cur_x >= 0 and cur_x + chWidth <= width and cur_y >= 0 and cur_y + chHeight <= height) {
                offset = 0;
                try self.window.children.items[i].setSize(cur_x, cur_y, chWidth - margin, chHeight - margin);
                _ = self.window.children.items[i].show();
                var matIdx = cur_row * self.cols + cur_col;
                if (matIdx < rows * cols) {
                    self.matrix.?[matIdx] = i;
                }
                if (i == self.focusedIdx) {
                    try self.window.children.items[i].focus();
                    self.focusedCol = cur_col;
                    self.focusedRow = cur_row;
                }
                i += 1;
            } else {
                offset += 1;
            }

            if (side != 0) {
                if (j % (side * 4) < side or j % (side * 4) >= side * 3) {
                    if (cur_col < cols) {
                        cur_x += chWidth;
                        cur_col += 1;
                    }
                } else {
                    if (cur_col > 0) {
                        cur_x -= chWidth;
                        cur_col -= 1;
                    }
                }
                if (j % (side * 4) < side * 2) {
                    if (cur_row > 0) {
                        cur_y += chHeight;
                        cur_row -= 1;
                    }
                } else {
                    if (cur_row < rows) {
                        cur_y -= chHeight;
                        cur_row += 1;
                    }
                }
            }
            j += 1;

            if (j >= side * 4) {
                break;
            }
        }
        if (offset >= max_offset) {
            break;
        }
        side += 1;
        cur_x = @divFloor(width, 2) - @divFloor(chWidth, 2);
        cur_y -= chHeight;
        cur_col = @divFloor(cols, 2);
        cur_row += 1;
    }

    try self.window.children.items[self.focusedIdx].focus();
}
