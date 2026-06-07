const std = @import("std");
const diff_parser = @import("diff_parser.zig");
const diff_render = @import("diff_render.zig");

pub const Direction = enum {
    forward,
    backward,
};

pub fn findMatch(file: diff_parser.FileDiff, mode: diff_render.DisplayMode, query: []const u8, base: usize, direction: Direction) ?usize {
    if (query.len == 0) return null;

    const line_count = diff_render.renderedBodyLineCount(file, mode);
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

fn bodyLineMatches(file: diff_parser.FileDiff, mode: diff_render.DisplayMode, target: usize, query: []const u8) bool {
    var offset: usize = 0;

    for (file.metadata) |line| {
        if (offset == target) return containsIgnoreCase(line, query);
        offset += 1;
    }

    for (file.hunks) |hunk| {
        if (offset == target) return containsIgnoreCase(hunk.section, query);
        offset += 1;

        switch (mode) {
            .unified => {
                for (hunk.lines) |line| {
                    if (offset == target) return containsIgnoreCase(line.text, query);
                    offset += 1;
                }
            },
            .side_by_side => {
                var index: usize = 0;
                while (index < hunk.lines.len) {
                    const line = hunk.lines[index];
                    if (line.kind == .removed and index + 1 < hunk.lines.len and hunk.lines[index + 1].kind == .added) {
                        if (offset == target) {
                            return containsIgnoreCase(line.text, query) or containsIgnoreCase(hunk.lines[index + 1].text, query);
                        }
                        index += 2;
                    } else {
                        if (offset == target) return containsIgnoreCase(line.text, query);
                        index += 1;
                    }
                    offset += 1;
                }
            },
        }
    }

    return false;
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
