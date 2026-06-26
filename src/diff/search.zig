const std = @import("std");
const diff_parser = @import("parser.zig");
const diff_view_model = @import("view_model.zig");

pub const Direction = enum {
    forward,
    backward,
};

pub const Match = struct {
    coordinate: diff_view_model.BodyCoordinate,
};

const Candidate = struct {
    offset: usize,
    match: Match,
};

pub fn findMatch(
    file: diff_parser.FileDiff,
    mode: diff_view_model.DisplayMode,
    query: []const u8,
    base: ?diff_view_model.BodyCoordinate,
    direction: Direction,
) ?Match {
    if (query.len == 0) return null;

    const base_offset = if (base) |coordinate|
        diff_view_model.renderedOffsetForCoordinate(file, mode, coordinate, null)
    else
        null;

    var first: ?Candidate = null;
    var last: ?Candidate = null;
    var after_base: ?Candidate = null;
    var before_base: ?Candidate = null;
    var offset: usize = 0;

    for (file.metadata, 0..) |line, index| {
        if (!diff_view_model.isVisibleMetadataLine(line)) continue;
        collectCandidate(.{ .metadata = index }, line, query, offset, base_offset, &first, &last, &after_base, &before_base);
        offset += 1;
    }

    if (file.is_binary) {
        collectCandidate(.binary_marker, "Binary file", query, offset, base_offset, &first, &last, &after_base, &before_base);
        offset += 1;
    }

    for (file.hunks, 0..) |hunk, hunk_index| {
        collectCandidate(.{ .hunk_header = hunk_index }, hunk.section, query, offset, base_offset, &first, &last, &after_base, &before_base);
        offset += 1;

        switch (mode) {
            .unified => {
                for (hunk.lines, 0..) |line, line_index| {
                    collectCandidate(
                        .{ .hunk_line = .{ .hunk_index = hunk_index, .line_index = line_index } },
                        line.text,
                        query,
                        offset,
                        base_offset,
                        &first,
                        &last,
                        &after_base,
                        &before_base,
                    );
                    offset += 1;
                }
            },
            .side_by_side => {
                var rows = diff_view_model.SideBySideIndexedIterator.init(hunk.lines);
                while (rows.next()) |row| {
                    if (matchedSideBySideCoordinate(row, hunk_index, query)) |coordinate| {
                        recordCandidate(
                            .{ .offset = offset, .match = .{ .coordinate = coordinate } },
                            base_offset,
                            &first,
                            &last,
                            &after_base,
                            &before_base,
                        );
                    }
                    offset += 1;
                }
            },
        }
    }

    const selected = switch (direction) {
        .forward => (if (base_offset != null) after_base else first) orelse first,
        .backward => (if (base_offset != null) before_base else last) orelse last,
    } orelse return null;
    return selected.match;
}

fn collectCandidate(
    coordinate: diff_view_model.BodyCoordinate,
    text: []const u8,
    query: []const u8,
    offset: usize,
    base_offset: ?usize,
    first: *?Candidate,
    last: *?Candidate,
    after_base: *?Candidate,
    before_base: *?Candidate,
) void {
    if (!containsIgnoreCase(text, query)) return;
    recordCandidate(.{ .offset = offset, .match = .{ .coordinate = coordinate } }, base_offset, first, last, after_base, before_base);
}

fn recordCandidate(
    candidate: Candidate,
    base_offset: ?usize,
    first: *?Candidate,
    last: *?Candidate,
    after_base: *?Candidate,
    before_base: *?Candidate,
) void {
    if (first.* == null) first.* = candidate;
    last.* = candidate;

    if (base_offset) |base| {
        if (candidate.offset > base and after_base.* == null) after_base.* = candidate;
        if (candidate.offset < base) before_base.* = candidate;
    }
}

fn matchedSideBySideCoordinate(
    row: diff_view_model.SideBySideIndexedRow,
    hunk_index: usize,
    query: []const u8,
) ?diff_view_model.BodyCoordinate {
    return switch (row) {
        .single => |line| if (containsIgnoreCase(line.line.text, query))
            .{ .hunk_line = .{ .hunk_index = hunk_index, .line_index = line.line_index } }
        else
            null,
        .paired => |pair| blk: {
            if (pair.removed) |line| {
                if (containsIgnoreCase(line.line.text, query)) {
                    break :blk .{ .hunk_line = .{ .hunk_index = hunk_index, .line_index = line.line_index } };
                }
            }
            if (pair.added) |line| {
                if (containsIgnoreCase(line.line.text, query)) {
                    break :blk .{ .hunk_line = .{ .hunk_index = hunk_index, .line_index = line.line_index } };
                }
            }
            break :blk null;
        },
    };
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) return true;
    }
    return false;
}

test "search match wraps through unified body lines" {
    const file = testFileWithHunks();

    try expectMatch(.{ .hunk_header = 1 }, findMatch(file, .unified, "second", null, .forward));
    try expectMatch(.{ .hunk_line = .{ .hunk_index = 0, .line_index = 3 } }, findMatch(file, .unified, "NEW", .{ .hunk_line = .{ .hunk_index = 0, .line_index = 1 } }, .forward));
    try expectMatch(.{ .hunk_line = .{ .hunk_index = 1, .line_index = 2 } }, findMatch(file, .unified, "new", null, .backward));
}

test "search match checks both sides of side-by-side pairs" {
    const file = testFileWithHunks();

    try expectMatch(.{ .hunk_line = .{ .hunk_index = 0, .line_index = 3 } }, findMatch(file, .side_by_side, "new", null, .forward));
    try expectMatch(.{ .hunk_line = .{ .hunk_index = 0, .line_index = 2 } }, findMatch(file, .side_by_side, "old", null, .forward));
}

test "search match follows side-by-side block pairing" {
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/a b/a",
        .metadata = &.{},
        .hunks = &.{
            .{
                .old_start = 1,
                .old_count = 2,
                .new_start = 1,
                .new_count = 2,
                .section = "block",
                .lines = &.{
                    .{ .kind = .removed, .text = "old one", .old_line = 1 },
                    .{ .kind = .removed, .text = "old two", .old_line = 2 },
                    .{ .kind = .added, .text = "new one", .new_line = 1 },
                    .{ .kind = .added, .text = "new two", .new_line = 2 },
                },
            },
        },
    };

    try expectMatch(.{ .hunk_line = .{ .hunk_index = 0, .line_index = 2 } }, findMatch(file, .side_by_side, "new one", null, .forward));
    try expectMatch(.{ .hunk_line = .{ .hunk_index = 0, .line_index = 3 } }, findMatch(file, .side_by_side, "new two", null, .forward));
}

test "search match does not repeat paired row when base is added side" {
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/a b/a",
        .metadata = &.{},
        .hunks = &.{
            .{
                .old_start = 1,
                .old_count = 2,
                .new_start = 1,
                .new_count = 2,
                .section = "block",
                .lines = &.{
                    .{ .kind = .removed, .text = "same old one", .old_line = 1 },
                    .{ .kind = .removed, .text = "same old two", .old_line = 2 },
                    .{ .kind = .added, .text = "same new one", .new_line = 1 },
                    .{ .kind = .added, .text = "same new two", .new_line = 2 },
                },
            },
        },
    };

    try expectMatch(
        .{ .hunk_line = .{ .hunk_index = 0, .line_index = 1 } },
        findMatch(file, .side_by_side, "same", .{ .hunk_line = .{ .hunk_index = 0, .line_index = 2 } }, .forward),
    );
}

fn expectMatch(expected: diff_view_model.BodyCoordinate, actual: ?Match) !void {
    try std.testing.expect(actual != null);
    try std.testing.expect(std.meta.eql(expected, actual.?.coordinate));
}

fn testFileWithHunks() diff_parser.FileDiff {
    return .{
        .header = "diff --git a/a b/a",
        .old_path = "a/a",
        .new_path = "b/a",
        .metadata = &.{ "index 1..2", "--- a/a", "+++ b/a" },
        .hunks = &.{
            .{
                .old_start = 1,
                .old_count = 5,
                .new_start = 1,
                .new_count = 5,
                .section = "first",
                .lines = &.{
                    .{ .kind = .context, .text = "one", .old_line = 1, .new_line = 1 },
                    .{ .kind = .context, .text = "two", .old_line = 2, .new_line = 2 },
                    .{ .kind = .removed, .text = "old", .old_line = 3 },
                    .{ .kind = .added, .text = "new", .new_line = 3 },
                    .{ .kind = .context, .text = "four", .old_line = 4, .new_line = 4 },
                },
            },
            .{
                .old_start = 20,
                .old_count = 3,
                .new_start = 20,
                .new_count = 3,
                .section = "second",
                .lines = &.{
                    .{ .kind = .context, .text = "late one", .old_line = 20, .new_line = 20 },
                    .{ .kind = .removed, .text = "late old", .old_line = 21 },
                    .{ .kind = .added, .text = "late new", .new_line = 21 },
                },
            },
        },
    };
}
