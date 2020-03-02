const std = @import("std");
const w = @import("win32").c;
usingnamespace @import("window.zig");
const Box = @import("box.zig").Box;

var classRegistered: bool = false;

const chWidth: c_int = 150;
const chHeight: c_int = 32;

//var layouts = std.hash_map.AutoHashMap(w.HWND, *Layout).init(std.heap.c_allocator);

var layoutInstance: ?*Layout = null;

fn WindowProc(hwnd: w.HWND, uMsg: w.UINT, wParam: w.WPARAM, lParam: w.LPARAM) callconv(.C) w.LRESULT {
    if (layouts.contains(hwnd)) {
        var l = layoutInstance;
        return switch (uMsg) {
            w.WM_DESTROY => {
                w.PostQuitMessage(0);
                return 0;
            },
            w.WM_CREATE => {
                return 0;
            },
            w.WM_SIZE => {
                l.layout();
                return 0;
            },
            w.WM_PAINT => {
                var ps: w.PAINTSTRUCT = undefined;
                var hdc = w.BeginPaint(hwnd, &ps);

                var hbrush = w.CreateSolidBrush(0x555555);

                _ = w.FillRect(hdc, &ps.rcPaint, hbrush);

                _ = w.EndPaint(hwnd, &ps);
                return 0;
            },
            w.WM_KEYDOWN => {
                std.debug.warn("Layout: WM_KEYDOWN: {}\n", .{wParam});
                switch (wParam) {
                    w.VK_TAB => {
                        l.?.next();
                    },
                    w.VK_RIGHT => {
                        l.?.right();
                    },
                    w.VK_LEFT => {
                        l.?.left();
                    },
                    w.VK_UP => {
                        l.?.up();
                    },
                    w.VK_DOWN => {
                        l.?.down();
                    },
                    else => {
                        return 0;
                    },
                }
                return 0;
            },
            w.WM_COMMAND => {
                std.debug.warn("Layout: WM_COMMAND: {}\n", .{wParam});
                return 0;
            },
            else => w.DefWindowProcW(hwnd, uMsg, wParam, lParam),
        };
    } else {
        return w.DefWindowProcW(hwnd, uMsg, wParam, lParam);
    }
}

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
    //parent: Window,
    //window: Window,
    children: std.ArrayList(Child),
    focusedIdx: usize = 0,
    focusedCol: usize = undefined,
    focusedRow: usize = undefined,
    matrix: ?[]?usize = null,
    rows: usize = 0,
    cols: usize = 0,

    pub fn create() *Layout {
        if (layoutInstance != null) {
            return layoutInstance.?;
        }

        var l: *Layout = std.heap.c_allocator.create(Layout) catch unreachable;
        l.* = Layout{
            .children = std.ArrayList(Child).init(std.heap.c_allocator),
        };
        layoutInstance = l;
        return l;
    }

    pub fn addChild(self: *Layout, box: *Box) void {
        var child = Child{
            .box = box,
        };
        _ = self.children.append(child) catch unreachable;
        box.window.hide();
    }

    pub fn removeChildren(self: *Layout) void {
        //TODO: implement cleaning with proper windows destroying
        for (self.children.span()) |*child| {
            child.box.*.window.hide();
            child.box.*.destroy();
        }
        self.children.deinit();
        self.children = std.ArrayList(Child).init(std.heap.c_allocator);
        std.heap.c_allocator.free(self.matrix.?);
        self.matrix = null;
        self.rows = 0;
    }

    pub fn isShowing(self: *Layout) bool {
        return self.children.len != 0;
    }

    pub fn switchToSelection(self: *Layout) void {
        var hwnd = self.children.at(self.focusedIdx).box.*.hwnd;
        self.hide();

        _ = w.SwitchToThisWindow(hwnd, 1);
    }

    pub fn hide(self: *Layout) void {
        self.removeChildren();
        self.focusedIdx = 0;
    }

    pub fn next(self: *Layout) void {
        self.children.at(self.focusedIdx).box.*.unfocus();
        if (self.focusedIdx < self.children.len - 1) {
            self.focusedIdx += 1;
        } else {
            self.focusedIdx = 0;
        }
        self.children.at(self.focusedIdx).box.*.focus();
        self.focusedCol = self.children.at(self.focusedIdx).col;
        self.focusedRow = self.children.at(self.focusedIdx).row;
        std.debug.warn("idx: {}\n", .{self.focusedIdx});
    }

    pub fn prev(self: *Layout) void {
        if (self.focusedIdx > 0) {
            self.focusedIdx -= 1;
        } else {
            self.focusedIdx = self.children.len - 1;
        }
        self.children.at(self.focusedIdx).window.focus();
        self.focusedCol = self.children.at(self.focusedIdx).col;
        self.focusedRow = self.children.at(self.focusedIdx).row;
    }

    pub fn right(self: *Layout) void {
        if (self.focusedCol < self.cols and self.matrix.?[self.focusedRow * self.cols + self.focusedCol + 1] != null) {
            self.children.at(self.focusedIdx).box.*.unfocus();

            self.focusedCol += 1;

            self.focusedIdx = self.matrix.?[self.focusedRow * self.cols + self.focusedCol].?;
            self.children.at(self.focusedIdx).box.*.focus();
        }
    }

    pub fn left(self: *Layout) void {
        if (self.focusedCol >= 0 and self.matrix.?[self.focusedRow * self.cols + self.focusedCol - 1] != null) {
            self.children.at(self.focusedIdx).box.*.unfocus();

            self.focusedCol -= 1;

            self.focusedIdx = self.matrix.?[self.focusedRow * self.cols + self.focusedCol].?;
            self.children.at(self.focusedIdx).box.*.focus();
        }
    }

    pub fn down(self: *Layout) void {
        if (self.focusedRow >= 0 and self.matrix.?[(self.focusedRow - 1) * self.cols + self.focusedCol] != null) {
            self.children.at(self.focusedIdx).box.*.unfocus();

            self.focusedRow -= 1;

            self.focusedIdx = self.matrix.?[self.focusedRow * self.cols + self.focusedCol].?;
            self.children.at(self.focusedIdx).box.*.focus();
        }
    }

    pub fn up(self: *Layout) void {
        if (self.focusedRow < self.rows and self.matrix.?[(self.focusedRow + 1) * self.cols + self.focusedCol] != null) {
            self.children.at(self.focusedIdx).box.*.unfocus();

            self.focusedRow += 1;

            self.focusedIdx = self.matrix.?[self.focusedRow * self.cols + self.focusedCol].?;
            self.children.at(self.focusedIdx).box.*.focus();
        }
    }

    pub fn show(self: *Layout) void {
        for (self.children.span()) |*child| {
            child.box.*.window.show();
        }
    }

    fn layout(self: *Layout) void {
        for (self.children.span()) |*child| {
            child.*.box.*.window.hide();
        }

        var desktopHwnd = w.GetDesktopWindow();
        var rect: w.RECT = undefined;
        _ = w.GetWindowRect(desktopHwnd, &rect);

        var width = rect.right - rect.left;
        var height = rect.bottom - rect.top;
        var rsize = self.children.len;

        var rows = @intCast(usize, @divFloor(height, chHeight));
        var cols = @intCast(usize, @divFloor(width, chWidth));
        self.rows = rows;
        self.cols = cols;

        var cur_x = @divFloor(width, 2) - @divFloor(chWidth, 2);
        var cur_y = @divFloor(height, 2) - @divFloor(chHeight, 2);
        var cur_col = @divFloor(cols, 2);
        var cur_row = @divFloor(rows, 2);

        if (self.matrix != null) {
            std.heap.c_allocator.free(self.matrix.?);
        }
        self.matrix = std.heap.c_allocator.alloc(?usize, cols * rows) catch unreachable;
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
                    self.children.at(i).box.*.window.setSize(cur_x, cur_y, chWidth, chHeight);
                    self.children.at(i).box.*.window.setSize(cur_x, cur_y, chWidth, chHeight);
                    self.children.at(i).box.*.window.show();
                    self.children.at(i).col = cur_col;
                    self.children.at(i).row = cur_row;
                    var matIdx = cur_row * self.cols + cur_col;
                    if (matIdx < rows * cols) {
                        self.matrix.?[matIdx] = i;
                    }
                    if (i == self.focusedIdx) {
                        self.children.at(i).box.*.focus();
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

        _ = w.SetForegroundWindow(self.children.at(self.focusedIdx).box.*.window.hwnd);
        _ = w.SetActiveWindow(self.children.at(self.focusedIdx).box.*.window.hwnd);
    }
};
