const std = @import("std");
const diff_file = @import("file.zig");
const diff_parser = @import("parser.zig");

pub const Side = enum {
    old,
    new,
};

pub const Point = struct {
    hunk_index: usize,
    line_index: usize,

    fn beforeOrEqual(self: Point, other: Point) bool {
        return self.hunk_index < other.hunk_index or
            (self.hunk_index == other.hunk_index and self.line_index <= other.line_index);
    }
};

pub const Range = struct {
    start: Point,
    end: Point,

    pub fn contains(self: Range, point: Point) bool {
        return self.start.beforeOrEqual(point) and point.beforeOrEqual(self.end);
    }
};

pub const Identity = union(enum) {
    loaded_file: struct {
        file_index: usize,
        /// Borrowed from the loaded diff arena. Active selections must be
        /// cleared before the loaded session is destroyed or replaced.
        path_key: []const u8,
    },

    pub fn matchesLoadedFile(self: Identity, file_index: usize, file: diff_parser.FileDiff) bool {
        return switch (self) {
            .loaded_file => |loaded| blk: {
                if (loaded.file_index != file_index) break :blk false;
                const key = diff_file.canonicalPathKey(file) orelse break :blk false;
                break :blk std.mem.eql(u8, loaded.path_key, key);
            },
        };
    }

    pub fn eql(self: Identity, other: Identity) bool {
        return switch (self) {
            .loaded_file => |loaded| switch (other) {
                .loaded_file => |other_loaded| loaded.file_index == other_loaded.file_index and
                    std.mem.eql(u8, loaded.path_key, other_loaded.path_key),
            },
        };
    }
};

pub const DragSelection = struct {
    identity: Identity,
    side: Side,
    anchor: Point,
    focus: Point,
    moved: bool = false,

    pub fn init(identity: Identity, side: Side, point: Point) DragSelection {
        return .{
            .identity = identity,
            .side = side,
            .anchor = point,
            .focus = point,
        };
    }

    pub fn update(self: *DragSelection, point: Point) void {
        if (point.hunk_index != self.focus.hunk_index or point.line_index != self.focus.line_index) {
            self.moved = true;
        }
        self.focus = point;
    }

    pub fn range(self: DragSelection) Range {
        if (self.anchor.beforeOrEqual(self.focus)) {
            return .{ .start = self.anchor, .end = self.focus };
        }
        return .{ .start = self.focus, .end = self.anchor };
    }

    pub fn view(self: DragSelection) View {
        const selected_range = self.range();
        return .{
            .identity = self.identity,
            .side = self.side,
            .start = selected_range.start,
            .end = selected_range.end,
        };
    }
};

pub const Owner = union(enum) {
    none,
    diff: DragSelection,

    pub fn activeDiff(self: Owner) ?DragSelection {
        return switch (self) {
            .none => null,
            .diff => |selection| selection,
        };
    }
};

pub const View = struct {
    identity: Identity,
    side: Side,
    start: Point,
    end: Point,

    pub fn range(self: View) Range {
        return .{ .start = self.start, .end = self.end };
    }
};

pub fn pointFromLine(hunk_index: usize, line_index: usize) Point {
    return .{ .hunk_index = hunk_index, .line_index = line_index };
}

pub fn lineVisibleOnSide(line: diff_parser.DiffLine, side: Side) bool {
    return switch (side) {
        .old => line.kind == .context or line.kind == .removed,
        .new => line.kind == .context or line.kind == .added,
    };
}

pub fn copyText(
    allocator: std.mem.Allocator,
    file: diff_parser.FileDiff,
    selection: DragSelection,
) ![]u8 {
    const selected_range = selection.range();
    if (selected_range.start.hunk_index >= file.hunks.len or selected_range.end.hunk_index >= file.hunks.len) {
        return allocator.dupe(u8, "");
    }

    var line_count: usize = 0;
    var hunk_index = selected_range.start.hunk_index;
    while (hunk_index <= selected_range.end.hunk_index) : (hunk_index += 1) {
        const hunk = file.hunks[hunk_index];
        const start_line = if (hunk_index == selected_range.start.hunk_index) selected_range.start.line_index else 0;
        const end_line = if (hunk_index == selected_range.end.hunk_index) selected_range.end.line_index else hunk.lines.len -| 1;
        if (start_line >= hunk.lines.len) continue;
        var line_index = start_line;
        while (line_index < hunk.lines.len and line_index <= end_line) : (line_index += 1) {
            if (lineVisibleOnSide(hunk.lines[line_index], selection.side)) line_count += 1;
        }
    }

    if (line_count == 0) return allocator.dupe(u8, "");

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    var emitted: usize = 0;
    hunk_index = selected_range.start.hunk_index;
    while (hunk_index <= selected_range.end.hunk_index) : (hunk_index += 1) {
        const hunk = file.hunks[hunk_index];
        const start_line = if (hunk_index == selected_range.start.hunk_index) selected_range.start.line_index else 0;
        const end_line = if (hunk_index == selected_range.end.hunk_index) selected_range.end.line_index else hunk.lines.len -| 1;
        if (start_line >= hunk.lines.len) continue;
        var line_index = start_line;
        while (line_index < hunk.lines.len and line_index <= end_line) : (line_index += 1) {
            const line = hunk.lines[line_index];
            if (!lineVisibleOnSide(line, selection.side)) continue;
            try out.writer.writeAll(line.text);
            emitted += 1;
            if (line_count > 1 or emitted < line_count) try out.writer.writeByte('\n');
        }
    }

    return try out.toOwnedSlice();
}

test "copyText preserves side-specific lines and whitespace" {
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/a b/a",
        .old_path = "a/a",
        .new_path = "b/a",
        .metadata = &.{},
        .hunks = &.{.{
            .old_start = 1,
            .old_count = 3,
            .new_start = 1,
            .new_count = 3,
            .section = "",
            .lines = &.{
                .{ .kind = .context, .text = " same ", .old_line = 1, .new_line = 1 },
                .{ .kind = .removed, .text = "", .old_line = 2 },
                .{ .kind = .added, .text = "  new", .new_line = 2 },
            },
        }},
    };

    const identity: Identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } };
    const old_text = try copyText(std.testing.allocator, file, .{
        .identity = identity,
        .side = .old,
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 0, .line_index = 2 },
        .moved = true,
    });
    defer std.testing.allocator.free(old_text);
    try std.testing.expectEqualStrings(" same \n\n", old_text);

    const new_text = try copyText(std.testing.allocator, file, .{
        .identity = identity,
        .side = .new,
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 0, .line_index = 2 },
        .moved = true,
    });
    defer std.testing.allocator.free(new_text);
    try std.testing.expectEqualStrings(" same \n  new\n", new_text);
}

test "copyText does not add trailing newline for one selected line" {
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/a b/a",
        .old_path = "a/a",
        .new_path = "b/a",
        .metadata = &.{},
        .hunks = &.{.{
            .old_start = 1,
            .old_count = 1,
            .new_start = 1,
            .new_count = 1,
            .section = "",
            .lines = &.{.{ .kind = .context, .text = "one", .old_line = 1, .new_line = 1 }},
        }},
    };

    const text = try copyText(std.testing.allocator, file, .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .side = .new,
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 0, .line_index = 0 },
        .moved = true,
    });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("one", text);
}
