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

/// Search consumes the canonical `BodyRowIterator` so rendered row order has
/// one source of truth. The fold-free `init` is deliberate policy: lines
/// inside folded hunks stay searchable — the viewer's fold state never
/// narrows the search space — and offsets therefore live in the same
/// fold-free space as `renderedOffsetForCoordinate(..., &.{}, null)`.
pub fn findMatch(
    file: diff_parser.FileDiff,
    mode: diff_view_model.DisplayMode,
    query: []const u8,
    base: ?diff_view_model.BodyCoordinate,
    direction: Direction,
) ?Match {
    if (query.len == 0) return null;

    const base_offset = if (base) |coordinate|
        diff_view_model.renderedOffsetForCoordinate(file, mode, coordinate, &.{}, null)
    else
        null;

    var first: ?Candidate = null;
    var last: ?Candidate = null;
    var after_base: ?Candidate = null;
    var before_base: ?Candidate = null;
    var offset: usize = 0;

    var rows = diff_view_model.BodyRowIterator.init(file, mode);
    while (rows.next()) |row| {
        switch (row) {
            .metadata => |line| collectCandidate(
                .{ .metadata = rows.currentMetadataIndex().? },
                line,
                query,
                offset,
                base_offset,
                &first,
                &last,
                &after_base,
                &before_base,
            ),
            .binary_marker => collectCandidate(.binary_marker, "Binary file", query, offset, base_offset, &first, &last, &after_base, &before_base),
            .hunk_header => |header| collectCandidate(.{ .hunk_header = header.hunk_index }, header.section, query, offset, base_offset, &first, &last, &after_base, &before_base),
            .unified_line => |line| collectCandidate(
                .{ .hunk_line = .{
                    .hunk_index = rows.currentHunkIndex().?,
                    .line_index = rows.currentUnifiedLineIndex().?,
                } },
                line.text,
                query,
                offset,
                base_offset,
                &first,
                &last,
                &after_base,
                &before_base,
            ),
            .side_by_side => {
                if (matchedSideBySideCoordinate(rows.currentSideBySideRow().?, rows.currentHunkIndex().?, query)) |coordinate| {
                    recordCandidate(
                        .{ .offset = offset, .match = .{ .coordinate = coordinate } },
                        base_offset,
                        &first,
                        &last,
                        &after_base,
                        &before_base,
                    );
                }
            },
        }
        offset += 1;
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

test "search match ignores hidden patch metadata" {
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/a b/a",
        .metadata = &.{ "index 1..2", "--- a/a", "+++ b/a", "old mode 100644" },
        .hunks = &.{},
    };

    try std.testing.expect(findMatch(file, .unified, "index", null, .forward) == null);
    try expectMatch(.{ .metadata = 3 }, findMatch(file, .unified, "old mode", null, .forward));
}

test "search offsets stay aligned with rendered offsets across row kinds" {
    const file = bridgeProbeFile();

    // Unified: visible metadata, headers, and every hunk line count one row
    // each; the hidden metadata line occupies no offset.
    try expectRenderedOffset(file, .unified, .{ .metadata = 1 }, 0);
    try expectRenderedOffset(file, .unified, .{ .hunk_header = 0 }, 1);
    try expectRenderedOffset(file, .unified, .{ .hunk_line = .{ .hunk_index = 0, .line_index = 0 } }, 2);
    try expectRenderedOffset(file, .unified, .{ .hunk_line = .{ .hunk_index = 0, .line_index = 1 } }, 3);
    try expectRenderedOffset(file, .unified, .{ .hunk_line = .{ .hunk_index = 0, .line_index = 2 } }, 4);
    try expectRenderedOffset(file, .unified, .{ .hunk_header = 1 }, 5);
    try expectRenderedOffset(file, .unified, .{ .hunk_line = .{ .hunk_index = 1, .line_index = 0 } }, 6);

    // Side-by-side: the removed/added pair shares one rendered row.
    try expectRenderedOffset(file, .side_by_side, .{ .metadata = 1 }, 0);
    try expectRenderedOffset(file, .side_by_side, .{ .hunk_header = 0 }, 1);
    try expectRenderedOffset(file, .side_by_side, .{ .hunk_line = .{ .hunk_index = 0, .line_index = 0 } }, 2);
    try expectRenderedOffset(file, .side_by_side, .{ .hunk_line = .{ .hunk_index = 0, .line_index = 1 } }, 3);
    try expectRenderedOffset(file, .side_by_side, .{ .hunk_line = .{ .hunk_index = 0, .line_index = 2 } }, 3);
    try expectRenderedOffset(file, .side_by_side, .{ .hunk_header = 1 }, 4);
    try expectRenderedOffset(file, .side_by_side, .{ .hunk_line = .{ .hunk_index = 1, .line_index = 0 } }, 5);

    const binary = bridgeProbeBinaryFile();
    try expectRenderedOffset(binary, .unified, .{ .metadata = 1 }, 0);
    try expectRenderedOffset(binary, .unified, .binary_marker, 1);
}

test "search base and direction probes traverse rendered row order" {
    const file = bridgeProbeFile();

    // Unified forward chain from every row kind, plus wrap at both ends.
    try expectMatch(.{ .metadata = 1 }, findMatch(file, .unified, "QQ", null, .forward));
    try expectMatch(.{ .hunk_header = 0 }, findMatch(file, .unified, "QQ", .{ .metadata = 1 }, .forward));
    try expectMatch(.{ .hunk_line = .{ .hunk_index = 0, .line_index = 0 } }, findMatch(file, .unified, "QQ", .{ .hunk_header = 0 }, .forward));
    try expectMatch(.{ .hunk_line = .{ .hunk_index = 0, .line_index = 1 } }, findMatch(file, .unified, "QQ", .{ .hunk_line = .{ .hunk_index = 0, .line_index = 0 } }, .forward));
    try expectMatch(.{ .hunk_line = .{ .hunk_index = 0, .line_index = 2 } }, findMatch(file, .unified, "QQ", .{ .hunk_line = .{ .hunk_index = 0, .line_index = 1 } }, .forward));
    try expectMatch(.{ .hunk_line = .{ .hunk_index = 1, .line_index = 0 } }, findMatch(file, .unified, "QQ", .{ .hunk_line = .{ .hunk_index = 0, .line_index = 2 } }, .forward));
    try expectMatch(.{ .metadata = 1 }, findMatch(file, .unified, "QQ", .{ .hunk_line = .{ .hunk_index = 1, .line_index = 0 } }, .forward));

    // Unified backward chain, plus wrap.
    try expectMatch(.{ .hunk_line = .{ .hunk_index = 1, .line_index = 0 } }, findMatch(file, .unified, "QQ", .{ .metadata = 1 }, .backward));
    try expectMatch(.{ .metadata = 1 }, findMatch(file, .unified, "QQ", .{ .hunk_header = 0 }, .backward));
    try expectMatch(.{ .hunk_line = .{ .hunk_index = 0, .line_index = 2 } }, findMatch(file, .unified, "QQ", .{ .hunk_line = .{ .hunk_index = 1, .line_index = 0 } }, .backward));

    // Side-by-side: the context row precedes the shared pair row; the pair
    // reports its removed side first and both sides share one offset.
    try expectMatch(.{ .hunk_line = .{ .hunk_index = 0, .line_index = 1 } }, findMatch(file, .side_by_side, "QQ", .{ .hunk_line = .{ .hunk_index = 0, .line_index = 0 } }, .forward));
    try expectMatch(.{ .hunk_line = .{ .hunk_index = 1, .line_index = 0 } }, findMatch(file, .side_by_side, "QQ", .{ .hunk_line = .{ .hunk_index = 0, .line_index = 2 } }, .forward));
    try expectMatch(.{ .hunk_line = .{ .hunk_index = 0, .line_index = 1 } }, findMatch(file, .side_by_side, "QQ", .{ .hunk_line = .{ .hunk_index = 1, .line_index = 0 } }, .backward));

    // Binary marker participates in the same offset space.
    const binary = bridgeProbeBinaryFile();
    try expectMatch(.binary_marker, findMatch(binary, .unified, "Binary", null, .forward));
    try expectMatch(.binary_marker, findMatch(binary, .unified, "Binary", .{ .metadata = 1 }, .forward));
}

test "binary file with residual hunks searches only through the binary marker" {
    // A malformed patch can leave hunks on a binary file. Rendered row order
    // ends at the binary marker, so those residual hunk rows are outside the
    // search space — matching `renderedOffsetForCoordinate`, which never
    // assigned them an offset in the first place.
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/a b/a",
        .metadata = &.{ "index 1..2", "old mode QQ" },
        .is_binary = true,
        .hunks = &.{
            .{
                .old_start = 1,
                .old_count = 1,
                .new_start = 1,
                .new_count = 1,
                .section = "QQ head",
                .lines = &.{
                    .{ .kind = .context, .text = "QQ tail", .old_line = 1, .new_line = 1 },
                },
            },
        },
    };

    try expectMatch(.{ .metadata = 1 }, findMatch(file, .unified, "QQ", null, .forward));
    try expectMatch(.{ .metadata = 1 }, findMatch(file, .unified, "QQ", null, .backward));
    try expectMatch(.binary_marker, findMatch(file, .unified, "Binary", null, .forward));
    try std.testing.expect(findMatch(file, .unified, "tail", null, .forward) == null);
    try std.testing.expect(findMatch(file, .unified, "head", null, .forward) == null);
}

fn expectRenderedOffset(
    file: diff_parser.FileDiff,
    mode: diff_view_model.DisplayMode,
    coordinate: diff_view_model.BodyCoordinate,
    expected: usize,
) !void {
    try std.testing.expectEqual(
        @as(?usize, expected),
        diff_view_model.renderedOffsetForCoordinate(file, mode, coordinate, &.{}, null),
    );
}

fn bridgeProbeFile() diff_parser.FileDiff {
    return .{
        .header = "diff --git a/a b/a",
        .old_path = "a",
        .new_path = "a",
        .metadata = &.{ "index 1..2", "old mode QQ" },
        .hunks = &.{
            .{
                .old_start = 1,
                .old_count = 2,
                .new_start = 1,
                .new_count = 2,
                .section = "QQ head",
                .lines = &.{
                    .{ .kind = .context, .text = "QQ ctx", .old_line = 1, .new_line = 1 },
                    .{ .kind = .removed, .text = "QQ gone", .old_line = 2 },
                    .{ .kind = .added, .text = "QQ came", .new_line = 2 },
                },
            },
            .{
                .old_start = 20,
                .old_count = 1,
                .new_start = 20,
                .new_count = 1,
                .section = "plain",
                .lines = &.{
                    .{ .kind = .context, .text = "QQ tail", .old_line = 20, .new_line = 20 },
                },
            },
        },
    };
}

fn bridgeProbeBinaryFile() diff_parser.FileDiff {
    return .{
        .header = "diff --git a/a b/a",
        .metadata = &.{ "index 1..2", "old mode QQ" },
        .is_binary = true,
        .hunks = &.{},
    };
}

fn expectMatch(expected: diff_view_model.BodyCoordinate, actual: ?Match) !void {
    try std.testing.expect(actual != null);
    try std.testing.expect(std.meta.eql(expected, actual.?.coordinate));
}

fn testFileWithHunks() diff_parser.FileDiff {
    return .{
        .header = "diff --git a/a b/a",
        .old_path = "a",
        .new_path = "a",
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
