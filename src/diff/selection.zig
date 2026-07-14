const std = @import("std");
const diff_file = @import("file.zig");
const diff_parser = @import("parser.zig");
const text_projection = @import("../text/projection.zig");

pub const Side = enum {
    old,
    new,
};

pub const Mode = enum {
    line,
    character,
};

pub const Point = struct {
    hunk_index: usize,
    line_index: usize,
    /// Byte boundaries for character mode. Line mode ignores these fields.
    leading: usize = 0,
    trailing: usize = 0,

    fn beforeOrEqual(self: Point, other: Point) bool {
        return self.hunk_index < other.hunk_index or
            (self.hunk_index == other.hunk_index and (self.line_index < other.line_index or
                (self.line_index == other.line_index and (self.leading < other.leading or
                    (self.leading == other.leading and self.trailing <= other.trailing)))));
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
    projection_file: struct {
        kind: enum { cached, combined },
        path_key: []const u8,
    },
    generated_file: struct {
        path_key: []const u8,
    },

    pub fn matchesLoadedFile(self: Identity, file_index: usize, file: diff_parser.FileDiff) bool {
        return switch (self) {
            .loaded_file => |loaded| blk: {
                if (loaded.file_index != file_index) break :blk false;
                const key = diff_file.canonicalPathKey(file) orelse break :blk false;
                break :blk std.mem.eql(u8, loaded.path_key, key);
            },
            .projection_file, .generated_file => false,
        };
    }

    pub fn eql(self: Identity, other: Identity) bool {
        return switch (self) {
            .loaded_file => |loaded| switch (other) {
                .loaded_file => |other_loaded| loaded.file_index == other_loaded.file_index and
                    std.mem.eql(u8, loaded.path_key, other_loaded.path_key),
                .projection_file, .generated_file => false,
            },
            .projection_file => |projected| switch (other) {
                .projection_file => |other_projected| projected.kind == other_projected.kind and
                    std.mem.eql(u8, projected.path_key, other_projected.path_key),
                .loaded_file, .generated_file => false,
            },
            .generated_file => |generated| switch (other) {
                .generated_file => |other_generated| std.mem.eql(u8, generated.path_key, other_generated.path_key),
                .loaded_file, .projection_file => false,
            },
        };
    }
};

pub const HeaderKind = enum {
    loaded_file,
    generated_file,
    projection_file,
};

pub const HeaderIdentity = struct {
    kind: HeaderKind,
    /// Borrowed from the active loaded/projection arena. Active selections must
    /// be cleared before the owning session/projection is destroyed or replaced.
    path_key: []const u8,

    pub fn eql(self: HeaderIdentity, other: HeaderIdentity) bool {
        return self.kind == other.kind and std.mem.eql(u8, self.path_key, other.path_key);
    }
};

pub const HeaderPathSelection = struct {
    identity: HeaderIdentity,
    moved: bool = false,

    pub fn update(self: *HeaderPathSelection) void {
        self.moved = true;
    }
};

pub const DragSelection = struct {
    identity: Identity,
    side: Side,
    mode: Mode = .line,
    anchor: Point,
    focus: Point,
    moved: bool = false,
    anchor_cell: ?Cell = null,

    pub fn init(identity: Identity, side: Side, point: Point) DragSelection {
        return .{
            .identity = identity,
            .side = side,
            .anchor = point,
            .focus = point,
        };
    }

    pub fn initAtCell(identity: Identity, side: Side, mode: Mode, point: Point, cell: Cell) DragSelection {
        return .{
            .identity = identity,
            .side = side,
            .mode = mode,
            .anchor = point,
            .focus = point,
            .anchor_cell = cell,
        };
    }

    pub fn update(self: *DragSelection, point: Point) void {
        if (point.hunk_index != self.focus.hunk_index or point.line_index != self.focus.line_index or
            point.leading != self.focus.leading or point.trailing != self.focus.trailing)
        {
            self.moved = true;
        }
        self.focus = point;
    }

    pub fn updateAtCell(self: *DragSelection, point: Point, cell: Cell) void {
        if (self.anchor_cell) |anchor_cell| {
            if (!anchor_cell.eql(cell)) self.moved = true;
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
            .mode = self.mode,
            .start = selected_range.start,
            .end = selected_range.end,
        };
    }
};

pub const Cell = struct {
    col: u16,
    row: u16,

    pub fn eql(self: Cell, other: Cell) bool {
        return self.col == other.col and self.row == other.row;
    }
};

pub const Owner = union(enum) {
    none,
    diff: DragSelection,
    diff_header: HeaderPathSelection,

    pub fn activeDiff(self: Owner) ?DragSelection {
        return switch (self) {
            .none => null,
            .diff => |selection| selection,
            .diff_header => null,
        };
    }

    pub fn activeHeader(self: Owner) ?HeaderPathSelection {
        return switch (self) {
            .none, .diff => null,
            .diff_header => |selection| selection,
        };
    }

    pub fn activeMouseSelection(self: Owner) bool {
        return switch (self) {
            .none => false,
            .diff, .diff_header => true,
        };
    }
};

pub const View = struct {
    identity: Identity,
    side: Side,
    mode: Mode = .line,
    start: Point,
    end: Point,

    pub fn range(self: View) Range {
        return .{ .start = self.start, .end = self.end };
    }
};

pub const LineVisualRange = struct {
    mode: Mode,
    byte_start: usize,
    byte_end: usize,
};

pub fn visualRangeForLine(view: View, hunk_index: usize, line_index: usize, line: diff_parser.DiffLine, side: Side) ?LineVisualRange {
    if (view.side != side or !lineVisibleOnSide(line, side)) return null;
    const range = view.range();
    if (hunk_index < range.start.hunk_index or hunk_index > range.end.hunk_index) return null;
    if (hunk_index == range.start.hunk_index and line_index < range.start.line_index) return null;
    if (hunk_index == range.end.hunk_index and line_index > range.end.line_index) return null;
    const bytes = selectedBytesForLine(line.text, view.mode, range, hunk_index, line_index) orelse return null;
    if (view.mode == .character and bytes.start == bytes.end) return null;
    return .{ .mode = view.mode, .byte_start = bytes.start, .byte_end = bytes.end };
}

pub fn pointFromLine(hunk_index: usize, line_index: usize) Point {
    return .{ .hunk_index = hunk_index, .line_index = line_index };
}

pub fn pointFromToken(hunk_index: usize, line_index: usize, token: text_projection.Token) Point {
    return .{
        .hunk_index = hunk_index,
        .line_index = line_index,
        .leading = token.leading,
        .trailing = token.trailing,
    };
}

pub fn pointFromBoundary(hunk_index: usize, line_index: usize, offset: usize) Point {
    return .{
        .hunk_index = hunk_index,
        .line_index = line_index,
        .leading = offset,
        .trailing = offset,
    };
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
    var fragments = try buildFragments(allocator, file, selection);
    defer fragments.deinit(allocator);
    return fragments.clipboardText(allocator);
}

pub const OwnedFragment = struct {
    hunk_index: usize,
    source_start: u32,
    source_end: u32,
    text: []u8,
    line_count: usize,

    fn deinit(self: *OwnedFragment, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub const OwnedFragments = struct {
    mode: Mode,
    items: []OwnedFragment,
    line_count: usize,

    pub fn deinit(self: *OwnedFragments, allocator: std.mem.Allocator) void {
        for (self.items) |*fragment| fragment.deinit(allocator);
        allocator.free(self.items);
        self.* = undefined;
    }

    pub fn clipboardText(self: OwnedFragments, allocator: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        for (self.items, 0..) |fragment, index| {
            if (index > 0) try out.writer.writeByte('\n');
            try out.writer.writeAll(fragment.text);
        }
        if (self.mode == .line and self.line_count >= 2) try out.writer.writeByte('\n');
        return out.toOwnedSlice();
    }
};

pub const BuildFragmentsError = error{ InvalidSelection, OutOfMemory };

pub fn buildFragments(allocator: std.mem.Allocator, file: diff_parser.FileDiff, selection: DragSelection) BuildFragmentsError!OwnedFragments {
    const selected_range = selection.range();
    if (selected_range.start.hunk_index >= file.hunks.len or selected_range.end.hunk_index >= file.hunks.len) {
        return .{ .mode = selection.mode, .items = try allocator.alloc(OwnedFragment, 0), .line_count = 0 };
    }

    var fragments: std.ArrayList(OwnedFragment) = .empty;
    errdefer {
        for (fragments.items) |*fragment| fragment.deinit(allocator);
        fragments.deinit(allocator);
    }
    var total_line_count: usize = 0;
    var hunk_index = selected_range.start.hunk_index;
    while (hunk_index <= selected_range.end.hunk_index) : (hunk_index += 1) {
        const hunk = file.hunks[hunk_index];
        const start_line = if (hunk_index == selected_range.start.hunk_index) selected_range.start.line_index else 0;
        const end_line = if (hunk_index == selected_range.end.hunk_index) selected_range.end.line_index else hunk.lines.len -| 1;
        if (start_line >= hunk.lines.len or hunk.lines.len == 0) continue;
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        var fragment_line_count: usize = 0;
        var source_start: ?u32 = null;
        var source_end: u32 = 0;
        var line_index = start_line;
        while (line_index < hunk.lines.len and line_index <= end_line) : (line_index += 1) {
            const line = hunk.lines[line_index];
            if (!lineVisibleOnSide(line, selection.side)) continue;
            const range = selectedBytesForLine(line.text, selection.mode, selected_range, hunk_index, line_index) orelse continue;
            if (range.start > range.end or range.end > line.text.len or
                !text_projection.validateBoundary(line.text, range.start) or
                !text_projection.validateBoundary(line.text, range.end)) return error.InvalidSelection;
            if (range.start == range.end and selected_range.start.hunk_index == selected_range.end.hunk_index and
                selected_range.start.line_index == selected_range.end.line_index) continue;
            if (fragment_line_count > 0) out.writer.writeByte('\n') catch return error.OutOfMemory;
            out.writer.writeAll(line.text[range.start..range.end]) catch return error.OutOfMemory;
            const source_line = lineNumberForSide(line, selection.side) orelse return error.InvalidSelection;
            if (source_start == null) source_start = source_line;
            source_end = source_line;
            fragment_line_count += 1;
        }
        if (fragment_line_count == 0) {
            out.deinit();
            continue;
        }
        const text = try out.toOwnedSlice();
        fragments.append(allocator, .{
            .hunk_index = hunk_index,
            .source_start = source_start.?,
            .source_end = source_end,
            .text = text,
            .line_count = fragment_line_count,
        }) catch |err| {
            allocator.free(text);
            return err;
        };
        total_line_count += fragment_line_count;
    }

    return .{
        .mode = selection.mode,
        .items = try fragments.toOwnedSlice(allocator),
        .line_count = total_line_count,
    };
}

const ByteRange = struct { start: usize, end: usize };

fn selectedBytesForLine(text: []const u8, mode: Mode, range: Range, hunk_index: usize, line_index: usize) ?ByteRange {
    if (mode == .line) return .{ .start = 0, .end = text.len };
    var start: usize = 0;
    var end: usize = text.len;
    if (hunk_index == range.start.hunk_index and line_index == range.start.line_index) start = range.start.leading;
    if (hunk_index == range.end.hunk_index and line_index == range.end.line_index) end = range.end.trailing;
    if (start > end) return null;
    return .{ .start = start, .end = end };
}

fn lineNumberForSide(line: diff_parser.DiffLine, side: Side) ?u32 {
    return switch (side) {
        .old => line.old_line,
        .new => line.new_line,
    };
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

test "character fragments copy exact forward and reverse multi-line bytes" {
    const file: diff_parser.FileDiff = .{
        .header = "diff",
        .old_path = "a/example",
        .new_path = "b/example",
        .metadata = &.{},
        .hunks = &.{.{
            .old_start = 1,
            .old_count = 2,
            .new_start = 1,
            .new_count = 2,
            .section = "",
            .lines = &.{
                .{ .kind = .context, .text = "ABCDEFG", .old_line = 1, .new_line = 1 },
                .{ .kind = .context, .text = "HIJKLMN", .old_line = 2, .new_line = 2 },
            },
        }},
    };
    const identity: Identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "example" } };
    const forward = DragSelection{
        .identity = identity,
        .side = .new,
        .mode = .character,
        .anchor = .{ .hunk_index = 0, .line_index = 0, .leading = 3, .trailing = 4 },
        .focus = .{ .hunk_index = 0, .line_index = 1, .leading = 4, .trailing = 5 },
        .moved = true,
    };
    const forward_text = try copyText(std.testing.allocator, file, forward);
    defer std.testing.allocator.free(forward_text);
    try std.testing.expectEqualStrings("DEFG\nHIJKL", forward_text);

    var reverse = forward;
    reverse.anchor = forward.focus;
    reverse.focus = forward.anchor;
    const reverse_text = try copyText(std.testing.allocator, file, reverse);
    defer std.testing.allocator.free(reverse_text);
    try std.testing.expectEqualStrings(forward_text, reverse_text);
}

test "character selection from the first token to its leading boundary keeps the token" {
    const cases = [_]struct {
        text: []const u8,
        token_end: usize,
        expected: []const u8,
    }{
        .{ .text = "ASCII", .token_end = 1, .expected = "A" },
        .{ .text = "e\u{301}rest", .token_end = 3, .expected = "e\u{301}" },
        .{ .text = "界rest", .token_end = 3, .expected = "界" },
        .{ .text = "\trest", .token_end = 1, .expected = "\t" },
    };

    for (cases) |case| {
        const lines = [_]diff_parser.DiffLine{.{
            .kind = .context,
            .text = case.text,
            .old_line = 1,
            .new_line = 1,
        }};
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
                .lines = &lines,
            }},
        };
        const selection: DragSelection = .{
            .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
            .side = .new,
            .mode = .character,
            .anchor = pointFromToken(0, 0, .{
                .leading = 0,
                .trailing = case.token_end,
                .display_start = 0,
                .display_end = 1,
            }),
            .focus = pointFromBoundary(0, 0, 0),
            .moved = true,
        };

        const copied = try copyText(std.testing.allocator, file, selection);
        defer std.testing.allocator.free(copied);
        try std.testing.expectEqualStrings(case.expected, copied);
    }
}

test "cross-hunk character fragments use one glue LF and no trailing LF" {
    const file: diff_parser.FileDiff = .{
        .header = "diff",
        .metadata = &.{},
        .hunks = &.{
            .{ .old_start = 1, .old_count = 1, .new_start = 1, .new_count = 1, .section = "", .lines = &.{.{ .kind = .context, .text = "abc", .old_line = 1, .new_line = 1 }} },
            .{ .old_start = 20, .old_count = 1, .new_start = 20, .new_count = 1, .section = "", .lines = &.{.{ .kind = .context, .text = "xyz", .old_line = 20, .new_line = 20 }} },
        },
    };
    const text = try copyText(std.testing.allocator, file, .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "example" } },
        .side = .new,
        .mode = .character,
        .anchor = .{ .hunk_index = 0, .line_index = 0, .leading = 1, .trailing = 2 },
        .focus = .{ .hunk_index = 1, .line_index = 0, .leading = 1, .trailing = 2 },
        .moved = true,
    });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("bc\nxy", text);
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
