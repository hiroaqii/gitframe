//! Borrowed line fragments. Projection owns grapheme, byte and source TAB geometry.
const std = @import("std");
const projection = @import("chasen_ui").text_projection;

pub const Fragment = struct {
    tokens: projection.TokenIterator,
    cells: projection.CellRange,
    bytes: projection.ByteRange,
    continuation: bool,
    placeholder: bool = false,
    replacement: ?projection.Token = null,

    pub fn segments(self: Fragment) Segments {
        if (self.replacement) |token| return .{ .replacement = .{
            .token = token,
            .global_cells = token.cellRange(),
            .viewport_cells = .{ .start = 0, .end = 1 },
            .materialization = .{ .source = "�" },
        } };
        return .{ .projected = .{
            .line = self.tokens.line,
            .tokens = self.tokens,
            .viewport_start = self.cells.start,
            .viewport_end = self.cells.end,
        } };
    }

    pub fn hitCell(self: Fragment, cell: usize) ?projection.CellHit {
        if (self.placeholder) return null;
        var visible = self.segments();
        while (visible.next()) |segment| {
            if (cell >= segment.viewport_cells.start and cell < segment.viewport_cells.end)
                return .{ .token = segment.token };
        }
        // Row padding belongs to this fragment, never to the next row's token.
        return .{ .boundary = .{ .byte_offset = self.bytes.end, .cell = self.cells.end } };
    }
};

pub const Segments = union(enum) {
    projected: projection.VisibleIterator,
    replacement: ?projection.VisibleSegment,

    pub fn next(self: *Segments) ?projection.VisibleSegment {
        return switch (self.*) {
            .projected => |*iterator| iterator.next(),
            .replacement => |*segment| blk: {
                const result = segment.*;
                segment.* = null;
                break :blk result;
            },
        };
    }
};

pub const Iterator = struct {
    tokens: projection.TokenIterator,
    width: usize,
    cell: usize = 0,
    byte: usize = 0,
    emitted: bool = false,
    done: bool = false,

    pub fn init(text: projection.Projection, width: usize) Iterator {
        return .{ .tokens = text.tokens(), .width = width };
    }

    pub fn next(self: *Iterator) ?Fragment {
        if (self.done) return null;
        var fragment: Fragment = .{
            .tokens = self.tokens,
            .cells = .{ .start = self.cell, .end = self.cell },
            .bytes = .{ .start = self.byte, .end = self.byte },
            .continuation = self.emitted,
        };
        self.emitted = true;
        if (self.width == 0) {
            self.done = true;
            fragment.placeholder = true;
            return fragment;
        }
        while (true) {
            const before = self.tokens;
            const token = self.tokens.next() orelse {
                self.done = true;
                break;
            };
            const remaining = token.cell_end - self.cell;
            if (remaining == 0) {
                self.byte = token.byte_end;
                fragment.bytes.end = token.byte_end;
                continue;
            }
            const used = self.cell - fragment.cells.start;
            const room = self.width -| used;
            if (fragment.replacement != null or room == 0) {
                self.tokens = before;
                break;
            }
            const tab = std.mem.eql(u8, token.bytes(self.tokens.line), "\t");
            if (!tab and remaining > room) {
                if (used != 0) {
                    self.tokens = before;
                    break;
                }
                // The pane cannot show this grapheme at any row boundary.
                fragment.replacement = token;
            } else if (tab and remaining > room) {
                self.cell += room;
                self.byte = token.byte_start;
                self.tokens = before;
                fragment.cells.end = self.cell;
                fragment.bytes.end = token.byte_end;
                break;
            }
            self.cell = token.cell_end;
            self.byte = token.byte_end;
            fragment.cells.end = self.cell;
            fragment.bytes.end = token.byte_end;
        }
        return fragment;
    }

    pub fn height(self: Iterator) usize {
        var iterator = self;
        var count: usize = 0;
        while (iterator.next() != null) count += 1;
        return count;
    }
};

test "wrap fragments preserve atomic graphemes and source TAB stops at finite widths" {
    const cases = [_]struct { text: []const u8, width: usize, rows: []const []const u8 }{
        .{ .text = "abc界z", .width = 4, .rows = &.{ "abc", "界z" } },
        .{ .text = "abc👩‍💻z", .width = 4, .rows = &.{ "abc", "👩‍💻z" } },
        .{ .text = "e\u{301}\t界z", .width = 3, .rows = &.{ "e\u{301}  ", " 界", "z" } },
        .{ .text = "界x", .width = 1, .rows = &.{ "�", "x" } },
        .{ .text = "界", .width = 0, .rows = &.{""} },
        .{ .text = "", .width = 4, .rows = &.{""} },
        .{ .text = "\u{200b}", .width = 1, .rows = &.{""} },
        .{ .text = "x\u{200b}", .width = 1, .rows = &.{"x"} },
    };
    for (cases) |case| {
        const text = try projection.Projection.init(case.text, .{ .tab_width = 4 });
        var iterator = Iterator.init(text, case.width);
        try std.testing.expectEqual(case.rows.len, iterator.height());
        for (case.rows, 0..) |expected, row| {
            const fragment = iterator.next().?;
            try std.testing.expectEqual(row != 0, fragment.continuation);
            var actual: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer actual.deinit();
            var segments = fragment.segments();
            while (segments.next()) |segment| switch (segment.materialization) {
                .source => |bytes| try actual.writer.writeAll(bytes),
                .spaces => |count| try actual.writer.splatByteAll(' ', count),
            };
            try std.testing.expectEqualStrings(expected, actual.written());
            if (case.width == 0) try std.testing.expect(fragment.hitCell(0) == null);
        }
        try std.testing.expect(iterator.next() == null);
    }
}
