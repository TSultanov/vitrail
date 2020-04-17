const std = @import("std");
const w = @import("win32").c;
usingnamespace @import("window.zig");
const Box = @import("box.zig").Box;
const Allocator = std.mem.Allocator;

var classRegistered: bool = false;

const chWidth: c_int = 150;
const chHeight: c_int = 32;

fn registerClass(hInstance: w.HINSTANCE, className: w.LPCWSTR) void {
    const wc: w.WNDCLASSW = .{
        .style = 0,
        .lpfnWndProc = WindowProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hInstance,
        .hIcon = null,
        .hCursor = w.LoadCursor(null, 32512),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = className,
    };

    _ = w.RegisterClassW(&wc);
}

const Child = struct {
    box: *Box, col: usize = undefined, row: usize = undefined
};

pub const Layout = struct {
    children: *std.ArrayList(*Child),
    focusedIdx: usize = 0,
    focusedCol: usize = undefined,
    focusedRow: usize = undefined,
    matrix: ?[]?usize = null,
    rows: usize = 0,
    cols: usize = 0,
    allocator: *Allocator,

    pub fn create(allocator: *Allocator) !*Layout {
        var l: *Layout = try allocator.create(Layout);
        var children: *std.ArrayList(*Child) = try allocator.create(std.ArrayList(*Child));
        children.* = std.ArrayList(*Child).init(allocator);
        l.* = Layout{
            .children = children,
            .allocator = allocator,
        };
        return l;
    }

    pub fn addChild(self: *Layout, box: *Box) !void {
        var pChild = try self.allocator.create(Child);
        pChild.* = Child{
            .box = box,
        };
        _ = try self.children.append(pChild);
        box.window.hide();
    }

    pub fn removeChildren(self: *Layout) !void {
        for (self.children.span()) |child| {
            child.*.box.*.window.hide();
            child.*.box.*.destroy();
            self.allocator.destroy(child.*.box);
            self.allocator.destroy(child);
        }
        self.children.deinit();
        self.allocator.destroy(self.children);
        self.children = try self.allocator.create(std.ArrayList(*Child));
        self.children.* = std.ArrayList(*Child).init(self.allocator);
        self.allocator.free(self.matrix.?);
        self.matrix = null;
        self.rows = 0;
    }

    pub fn isShowing(self: *Layout) bool {
        return self.children.len != 0;
    }

    pub fn switchToSelection(self: *Layout) !void {
        self.children.items[self.focusedIdx].box.*.switchToWindow();
        try self.hide();
    }

    pub fn hide(self: *Layout) !void {
        try self.removeChildren();
        self.focusedIdx = 0;
    }

    pub fn next(self: *Layout) void {
        self.children.items[self.focusedIdx].box.*.unfocus();
        if (self.focusedIdx < self.children.items.len - 1) {
            self.focusedIdx += 1;
        } else {
            self.focusedIdx = 0;
        }
        self.children.items[self.focusedIdx].box.*.focus();
        self.focusedCol = self.children.items[self.focusedIdx].col;
        self.focusedRow = self.children.items[self.focusedIdx].row;
    }

    pub fn prev(self: *Layout) void {
        self.children.items[self.focusedIdx].box.*.unfocus();
        if (self.focusedIdx > 0) {
            self.focusedIdx -= 1;
        } else {
            self.focusedIdx = self.children.items.len - 1;
        }
        self.children.items[self.focusedIdx].box.*.focus();
        self.focusedCol = self.children.items[self.focusedIdx].col;
        self.focusedRow = self.children.items[self.focusedIdx].row;
    }

    pub fn right(self: *Layout) void {
        if (self.focusedCol < self.cols and self.matrix.?[self.focusedRow * self.cols + self.focusedCol + 1] != null) {
            self.children.items[self.focusedIdx].box.*.unfocus();

            self.focusedCol += 1;

            self.focusedIdx = self.matrix.?[self.focusedRow * self.cols + self.focusedCol].?;
            self.children.items[self.focusedIdx].box.*.focus();
        }
    }

    pub fn left(self: *Layout) void {
        if (self.focusedCol >= 0 and self.matrix.?[self.focusedRow * self.cols + self.focusedCol - 1] != null) {
            self.children.items[self.focusedIdx].box.*.unfocus();

            self.focusedCol -= 1;

            self.focusedIdx = self.matrix.?[self.focusedRow * self.cols + self.focusedCol].?;
            self.children.items[self.focusedIdx].box.*.focus();
        }
    }

    pub fn down(self: *Layout) void {
        if (self.focusedRow >= 0 and self.matrix.?[(self.focusedRow - 1) * self.cols + self.focusedCol] != null) {
            self.children.items[self.focusedIdx].box.*.unfocus();

            self.focusedRow -= 1;

            self.focusedIdx = self.matrix.?[self.focusedRow * self.cols + self.focusedCol].?;
            self.children.items[self.focusedIdx].box.*.focus();
        }
    }

    pub fn up(self: *Layout) void {
        if (self.focusedRow < self.rows and self.matrix.?[(self.focusedRow + 1) * self.cols + self.focusedCol] != null) {
            self.children.items[self.focusedIdx].box.*.unfocus();

            self.focusedRow += 1;

            self.focusedIdx = self.matrix.?[self.focusedRow * self.cols + self.focusedCol].?;
            self.children.items[self.focusedIdx].box.*.focus();
        }
    }

    pub fn show(self: *Layout) void {
        for (self.children.span()) |*child| {
            child.box.*.window.show();
        }
    }

    fn layout(self: *Layout) !void {
        if (self.children.items.len == 0) return;

        for (self.children.span()) |*child| {
            child.*.box.*.window.hide();
        }

        var desktopHwnd = w.GetDesktopWindow();
        var rect: w.RECT = undefined;
        _ = w.GetWindowRect(desktopHwnd, &rect);

        var width = rect.right - rect.left;
        var height = rect.bottom - rect.top;
        var rsize = self.children.items.len;

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
                    self.children.items[i].box.*.window.setSize(cur_x, cur_y, chWidth, chHeight);
                    self.children.items[i].box.*.window.setSize(cur_x, cur_y, chWidth, chHeight);
                    self.children.items[i].box.*.window.show();
                    self.children.items[i].col = cur_col;
                    self.children.items[i].row = cur_row;
                    var matIdx = cur_row * self.cols + cur_col;
                    if (matIdx < rows * cols) {
                        self.matrix.?[matIdx] = i;
                    }
                    if (i == self.focusedIdx) {
                        self.children.items[i].box.*.focus();
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

        _ = w.SwitchToThisWindow(self.children.items[self.focusedIdx].box.*.window.hwnd, 1);
    }
};
