const std = @import("std");
const diff_parser = @import("diff_parser.zig");
const diff_view_model = @import("diff_view_model.zig");

pub const Direction = enum {
    forward,
    backward,
};

pub fn findMatch(file: diff_parser.FileDiff, mode: diff_view_model.DisplayMode, query: []const u8, base: usize, direction: Direction) ?usize {
    if (query.len == 0) return null;

    const line_count = diff_view_model.renderedBodyLineCount(file, mode);
    if (line_count == 0) return null;

    var step: usize = 1;
    while (step <= line_count) : (step += 1) {
        const offset = switch (direction) {
            .forward => (base + step) % line_count,
            .backward => (base + line_count - step) % line_count,
        };
        if (bodyLineMatches(file, mode, offset, query)) return offset;
    }
    return null;
}

fn bodyLineMatches(file: diff_parser.FileDiff, mode: diff_view_model.DisplayMode, target: usize, query: []const u8) bool {
    var rows = diff_view_model.BodyRowIterator.init(file, mode);
    var offset: usize = 0;
    while (rows.next()) |row| {
        if (offset == target) return bodyRowMatches(row, query);
        offset += 1;
    }
    return false;
}

fn bodyRowMatches(row: diff_view_model.BodyRow, query: []const u8) bool {
    return switch (row) {
        .metadata => |line| containsIgnoreCase(line, query),
        .binary_marker => containsIgnoreCase("Binary file", query),
        .hunk_header => |hunk| containsIgnoreCase(hunk.section, query),
        .unified_line => |line| containsIgnoreCase(line.text, query),
        .side_by_side => |side_row| sideBySideRowMatches(side_row, query),
    };
}

fn sideBySideRowMatches(row: diff_view_model.SideBySideRow, query: []const u8) bool {
    return switch (row) {
        .single => |line| containsIgnoreCase(line.text, query),
        .paired => |pair| (if (pair.removed) |line| containsIgnoreCase(line.text, query) else false) or
            (if (pair.added) |line| containsIgnoreCase(line.text, query) else false),
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

    try std.testing.expectEqual(@as(?usize, 9), findMatch(file, .unified, "second", 0, .forward));
    try std.testing.expectEqual(@as(?usize, 7), findMatch(file, .unified, "NEW", 6, .forward));
    try std.testing.expectEqual(@as(?usize, 12), findMatch(file, .unified, "new", 6, .backward));
}

test "search match checks both sides of side-by-side pairs" {
    const file = testFileWithHunks();

    try std.testing.expectEqual(@as(?usize, 6), findMatch(file, .side_by_side, "new", 0, .forward));
    try std.testing.expectEqual(@as(?usize, 6), findMatch(file, .side_by_side, "old", 0, .forward));
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

    try std.testing.expectEqual(@as(?usize, 1), findMatch(file, .side_by_side, "new one", 0, .forward));
    try std.testing.expectEqual(@as(?usize, 2), findMatch(file, .side_by_side, "new two", 0, .forward));
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
