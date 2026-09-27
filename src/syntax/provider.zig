const std = @import("std");
const diff_parser = @import("../diff/parser.zig");
const token = @import("token.zig");

pub const Side = enum {
    old,
    new,
};

pub const LineKey = struct {
    file_index: usize,
    hunk_index: usize,
    line_index: usize,
    side: Side,
};

pub const LineEntry = struct {
    old: token.LineSpans = .empty(),
    new: token.LineSpans = .empty(),

    pub fn forSide(self: LineEntry, side: Side) token.LineSpans {
        return switch (side) {
            .old => self.old,
            .new => self.new,
        };
    }
};

pub const HunkSpans = struct {
    lines: []LineEntry = &.{},
};

pub const FileSpans = struct {
    hunks: []HunkSpans = &.{},
};

pub const DocumentSpans = struct {
    files: []FileSpans = &.{},

    pub fn empty() DocumentSpans {
        return .{};
    }

    pub fn deinit(self: *DocumentSpans, allocator: std.mem.Allocator) void {
        for (self.files) |file| {
            for (file.hunks) |hunk| {
                for (hunk.lines) |line| {
                    allocator.free(line.old.spans);
                    allocator.free(line.new.spans);
                }
                allocator.free(hunk.lines);
            }
            allocator.free(file.hunks);
        }
        allocator.free(self.files);
        self.* = .empty();
    }

    pub fn lineSpans(self: DocumentSpans, key: LineKey) token.LineSpans {
        if (key.file_index >= self.files.len) return .empty();
        const file = self.files[key.file_index];
        if (key.hunk_index >= file.hunks.len) return .empty();
        const hunk = file.hunks[key.hunk_index];
        if (key.line_index >= hunk.lines.len) return .empty();
        return hunk.lines[key.line_index].forSide(key.side);
    }
};

pub const FileShape = struct {
    hunk_line_counts: []const usize,
};

pub const DocumentShape = struct {
    files: []const FileShape,
};

pub fn allocateEmpty(allocator: std.mem.Allocator, shape: DocumentShape) !DocumentSpans {
    const files = try allocator.alloc(FileSpans, shape.files.len);
    for (shape.files, files) |file, *file_spans| {
        const hunks = try allocator.alloc(HunkSpans, file.hunk_line_counts.len);
        for (file.hunk_line_counts, hunks) |line_count, *hunk_spans| {
            const lines = try allocator.alloc(LineEntry, line_count);
            @memset(lines, .{});
            hunk_spans.* = .{ .lines = lines };
        }
        file_spans.* = .{ .hunks = hunks };
    }
    return .{ .files = files };
}

pub fn allocateEmptyForDocument(allocator: std.mem.Allocator, document: diff_parser.DiffDocument) !DocumentSpans {
    const files = try allocator.alloc(FileShape, document.files.len);
    defer allocator.free(files);
    @memset(files, .{ .hunk_line_counts = &.{} });
    defer for (files) |file| allocator.free(file.hunk_line_counts);

    for (document.files, files) |file, *shape_file| {
        const counts = try allocator.alloc(usize, file.hunks.len);
        shape_file.* = .{ .hunk_line_counts = counts };
        for (file.hunks, counts) |hunk, *count| count.* = hunk.lines.len;
    }
    return allocateEmpty(allocator, .{ .files = files });
}

pub fn putLineSpans(document: *DocumentSpans, key: LineKey, spans: token.LineSpans) void {
    if (key.file_index >= document.files.len) return;
    const file = document.files[key.file_index];
    if (key.hunk_index >= file.hunks.len) return;
    const hunk = file.hunks[key.hunk_index];
    if (key.line_index >= hunk.lines.len) return;
    switch (key.side) {
        .old => hunk.lines[key.line_index].old = spans,
        .new => hunk.lines[key.line_index].new = spans,
    }
}

pub const FragmentLine = struct {
    line_index: usize,
    text: []const u8,
    start: usize,
    end: usize,
};

pub const Fragment = struct {
    text: []const u8,
    lines: []const FragmentLine,

    pub fn deinit(self: Fragment, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.lines);
    }
};

pub fn buildFragment(allocator: std.mem.Allocator, hunk: diff_parser.Hunk, side: Side) !Fragment {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    var lines: std.ArrayList(FragmentLine) = .empty;
    errdefer lines.deinit(allocator);

    for (hunk.lines, 0..) |line, line_index| {
        if (!lineBelongsToSide(line.kind, side)) continue;
        const start = text.items.len;
        try text.appendSlice(allocator, line.text);
        const end = text.items.len;
        try lines.append(allocator, .{
            .line_index = line_index,
            .text = line.text,
            .start = start,
            .end = end,
        });
        try text.append(allocator, '\n');
    }

    return .{
        .text = try text.toOwnedSlice(allocator),
        .lines = try lines.toOwnedSlice(allocator),
    };
}

pub fn lineBelongsToSide(kind: diff_parser.DiffLine.Kind, side: Side) bool {
    return switch (side) {
        .old => kind == .context or kind == .removed,
        .new => kind == .context or kind == .added,
    };
}

pub const ByteRange = struct {
    start: usize,
    end: usize,
};

pub fn appendRangeSpans(
    allocator: std.mem.Allocator,
    line_maps: []const FragmentLine,
    line_lists: []std.ArrayList(token.TokenSpan),
    range: ByteRange,
    role: token.TokenRole,
) !void {
    if (range.end <= range.start) return;
    for (line_maps, 0..) |line_map, index| {
        if (range.end <= line_map.start) continue;
        if (range.start >= line_map.end) continue;
        const clipped_start = @max(range.start, line_map.start);
        const clipped_end = @min(range.end, line_map.end);
        if (clipped_end <= clipped_start) continue;
        try line_lists[index].append(allocator, .{
            .start = clipped_start - line_map.start,
            .end = clipped_end - line_map.start,
            .role = role,
        });
    }
}

test "DocumentSpans uses parsed diff identity and side as lookup key" {
    const hunk_line_counts = [_]usize{1};
    const files = [_]FileShape{.{ .hunk_line_counts = &hunk_line_counts }};

    var spans = try allocateEmpty(std.testing.allocator, .{ .files = &files });
    defer spans.deinit(std.testing.allocator);

    const old_spans = try std.testing.allocator.dupe(token.TokenSpan, &[_]token.TokenSpan{.{ .start = 0, .end = 5, .role = .keyword }});
    const new_spans = try std.testing.allocator.dupe(token.TokenSpan, &[_]token.TokenSpan{.{ .start = 6, .end = 11, .role = .variable }});
    putLineSpans(&spans, .{ .file_index = 0, .hunk_index = 0, .line_index = 0, .side = .old }, .{ .spans = old_spans });
    putLineSpans(&spans, .{ .file_index = 0, .hunk_index = 0, .line_index = 0, .side = .new }, .{ .spans = new_spans });

    try std.testing.expectEqual(token.TokenRole.keyword, spans.lineSpans(.{ .file_index = 0, .hunk_index = 0, .line_index = 0, .side = .old }).spans[0].role);
    try std.testing.expectEqual(token.TokenRole.variable, spans.lineSpans(.{ .file_index = 0, .hunk_index = 0, .line_index = 0, .side = .new }).spans[0].role);
}

test "allocateEmptyForDocument allocates parsed diff shape" {
    const document: diff_parser.DiffDocument = .{ .files = &.{
        .{
            .header = "diff --git a/a b/a",
            .metadata = &.{},
            .hunks = &.{.{
                .old_start = 1,
                .old_count = 2,
                .new_start = 1,
                .new_count = 2,
                .section = "",
                .lines = &.{
                    .{ .kind = .removed, .text = "old", .old_line = 1 },
                    .{ .kind = .added, .text = "new", .new_line = 1 },
                },
            }},
        },
    } };

    var spans = try allocateEmptyForDocument(std.testing.allocator, document);
    defer spans.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), spans.files.len);
    try std.testing.expectEqual(@as(usize, 1), spans.files[0].hunks.len);
    try std.testing.expectEqual(@as(usize, 2), spans.files[0].hunks[0].lines.len);
}

test "buildFragment reconstructs side-specific hunk text and line map" {
    const hunk: diff_parser.Hunk = .{
        .old_start = 1,
        .old_count = 2,
        .new_start = 1,
        .new_count = 2,
        .section = "",
        .lines = &.{
            .{ .kind = .context, .text = "same\r", .old_line = 1, .new_line = 1 },
            .{ .kind = .removed, .text = "old", .old_line = 2 },
            .{ .kind = .added, .text = "new", .new_line = 2 },
        },
    };

    const old_fragment = try buildFragment(std.testing.allocator, hunk, .old);
    defer old_fragment.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("same\r\nold\n", old_fragment.text);
    try std.testing.expectEqual(@as(usize, 0), old_fragment.lines[0].line_index);
    try std.testing.expectEqual(@as(usize, 1), old_fragment.lines[1].line_index);

    const new_fragment = try buildFragment(std.testing.allocator, hunk, .new);
    defer new_fragment.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("same\r\nnew\n", new_fragment.text);
    try std.testing.expectEqual(@as(usize, 0), new_fragment.lines[0].line_index);
    try std.testing.expectEqual(@as(usize, 2), new_fragment.lines[1].line_index);
    try std.testing.expectEqual(@as(usize, 5), new_fragment.lines[0].end);
    try std.testing.expectEqual(@as(usize, 6), new_fragment.lines[1].start);
    try std.testing.expectEqual(@as(usize, 9), new_fragment.lines[1].end);
}

test "appendRangeSpans maps fragment byte ranges to line-local spans" {
    const line_maps = [_]FragmentLine{
        .{ .line_index = 0, .text = "abc", .start = 0, .end = 3 },
        .{ .line_index = 1, .text = "def", .start = 4, .end = 7 },
    };
    var line_lists = [_]std.ArrayList(token.TokenSpan){ .empty, .empty };
    defer for (&line_lists) |*list| list.deinit(std.testing.allocator);

    try appendRangeSpans(std.testing.allocator, &line_maps, &line_lists, .{ .start = 2, .end = 6 }, .keyword);

    try std.testing.expectEqual(@as(usize, 1), line_lists[0].items.len);
    try std.testing.expectEqual(token.TokenSpan{ .start = 2, .end = 3, .role = .keyword }, line_lists[0].items[0]);
    try std.testing.expectEqual(@as(usize, 1), line_lists[1].items.len);
    try std.testing.expectEqual(token.TokenSpan{ .start = 0, .end = 2, .role = .keyword }, line_lists[1].items[0]);
}
