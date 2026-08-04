//! Bounded current-source Git decoration.
//!
//! A map is indexed by the same zero-based real source rows as
//! `repository/source.zig::Document`. It deliberately has no old-side rows,
//! staging authority, or diff-text ownership; unified patch bytes and parser
//! arrays remain task-local while only one byte per current row is retained.

const std = @import("std");
const diff_parser = @import("../diff/parser.zig");
const selected_document = @import("document.zig");

pub const Kind = enum(u8) {
    none,
    added,
    modified,
};

pub const Map = struct {
    rows: []Kind = &.{},

    pub fn deinit(self: *Map, allocator: std.mem.Allocator) void {
        allocator.free(self.rows);
        self.* = .{};
    }

    pub fn row(self: *const Map, line_index: usize) Kind {
        return if (line_index < self.rows.len) self.rows[line_index] else .none;
    }

    pub fn isEmpty(self: *const Map) bool {
        for (self.rows) |kind| if (kind != .none) return false;
        return true;
    }
};

pub const BuildError = diff_parser.ParseError || error{
    TooManyRows,
    MultipleFiles,
    MissingNewLine,
    LineOutOfRange,
};

pub fn allAdded(allocator: std.mem.Allocator, content_line_count: usize) BuildError!Map {
    const map = try empty(allocator, content_line_count);
    @memset(map.rows, .added);
    return map;
}

pub fn fromPatch(
    allocator: std.mem.Allocator,
    patch: []const u8,
    content_line_count: usize,
) BuildError!Map {
    var map = try empty(allocator, content_line_count);
    errdefer map.deinit(allocator);

    const document = try diff_parser.parse(allocator, patch);
    defer document.deinit(allocator);
    if (document.files.len > 1) return error.MultipleFiles;
    if (document.files.len == 0) return map;

    for (document.files[0].hunks) |hunk| {
        const incoming: Kind = if (hunk.old_count == 0) .added else .modified;
        for (hunk.lines) |line| {
            if (line.kind != .added) continue;
            const one_based = line.new_line orelse return error.MissingNewLine;
            if (one_based == 0) return error.LineOutOfRange;
            const line_index: usize = @intCast(one_based - 1);
            if (line_index >= map.rows.len) return error.LineOutOfRange;
            map.rows[line_index] = mergeKind(map.rows[line_index], incoming);
        }
    }
    return map;
}

fn empty(allocator: std.mem.Allocator, content_line_count: usize) BuildError!Map {
    if (content_line_count > selected_document.max_text_bytes) return error.TooManyRows;
    const rows = try allocator.alloc(Kind, content_line_count);
    @memset(rows, .none);
    return .{ .rows = rows };
}

fn mergeKind(existing: Kind, incoming: Kind) Kind {
    if (existing == .modified or incoming == .modified) return .modified;
    if (existing == .added or incoming == .added) return .added;
    return .none;
}

/// Materializes the source model's logical line terminators for raw no-index
/// comparison. CRLF becomes LF on both sides; no other bytes are transformed.
pub fn normalizeCrlfAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const output = try allocator.alloc(u8, bytes.len);
    errdefer allocator.free(output);
    var read_index: usize = 0;
    var write_index: usize = 0;
    while (read_index < bytes.len) : (read_index += 1) {
        if (bytes[read_index] == '\r' and read_index + 1 < bytes.len and bytes[read_index + 1] == '\n') continue;
        output[write_index] = bytes[read_index];
        write_index += 1;
    }
    return allocator.realloc(output, write_index);
}

test "change map marks insertion replacement and excludes context and deletion" {
    const patch =
        \\diff --git a/a.zig b/a.zig
        \\--- a/a.zig
        \\+++ b/a.zig
        \\@@ -1,0 +2,1 @@
        \\+inserted
        \\@@ -4,1 +5,1 @@
        \\-old
        \\+replacement
        \\@@ -8,1 +9,0 @@
        \\-deleted
        \\
    ;
    var map = try fromPatch(std.testing.allocator, patch, 10);
    defer map.deinit(std.testing.allocator);

    try std.testing.expectEqual(Kind.added, map.row(1));
    try std.testing.expectEqual(Kind.modified, map.row(4));
    try std.testing.expectEqual(Kind.none, map.row(0));
    try std.testing.expectEqual(Kind.none, map.row(8));
}

test "change map resolves empty patch and all-added empty source" {
    var unchanged = try fromPatch(std.testing.allocator, "", 3);
    defer unchanged.deinit(std.testing.allocator);
    try std.testing.expect(unchanged.isEmpty());

    var empty_added = try allAdded(std.testing.allocator, 0);
    defer empty_added.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), empty_added.rows.len);
}

test "change map rejects a new-side row outside accepted source" {
    const patch =
        \\diff --git a/a b/a
        \\--- a/a
        \\+++ b/a
        \\@@ -0,0 +3,1 @@
        \\+late
        \\
    ;
    try std.testing.expectError(error.LineOutOfRange, fromPatch(std.testing.allocator, patch, 2));
}

test "change map handles context deletion-only and deterministic overlapping severity" {
    const patch =
        \\diff --git a/a b/a
        \\--- a/a
        \\+++ b/a
        \\@@ -1,3 +1,3 @@
        \\ context
        \\-old
        \\+replacement
        \\ tail
        \\@@ -0,0 +2,1 @@
        \\+also insertion
        \\@@ -4,1 +4,0 @@
        \\-deleted only
        \\
    ;
    var map = try fromPatch(std.testing.allocator, patch, 3);
    defer map.deinit(std.testing.allocator);
    try std.testing.expectEqual(Kind.none, map.row(0));
    try std.testing.expectEqual(Kind.modified, map.row(1));
    try std.testing.expectEqual(Kind.none, map.row(2));
}

test "text limit contract change map accepted row ceiling" {
    const patch =
        \\diff --git a/a b/a
        \\--- a/a
        \\+++ b/a
        \\@@ -0,0 +1,1 @@
        \\+a
        \\diff --git a/b b/b
        \\--- a/b
        \\+++ b/b
        \\@@ -0,0 +1,1 @@
        \\+b
        \\
    ;
    try std.testing.expectError(error.MultipleFiles, fromPatch(std.testing.allocator, patch, 1));
    var maximum = try allAdded(std.testing.allocator, selected_document.max_text_bytes);
    defer maximum.deinit(std.testing.allocator);
    try std.testing.expectEqual(selected_document.max_text_bytes, maximum.rows.len);
    try std.testing.expectError(error.TooManyRows, allAdded(std.testing.allocator, selected_document.max_text_bytes + 1));
}

test "change map releases every retained allocation on allocation failure" {
    const patch =
        \\diff --git a/a b/a
        \\--- a/a
        \\+++ b/a
        \\@@ -1,1 +1,1 @@
        \\-old
        \\+new
        \\
    ;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn build(allocator: std.mem.Allocator, input: []const u8) !void {
            var map = try fromPatch(allocator, input, 1);
            defer map.deinit(allocator);
        }
    }.build, .{patch});
}

test "logical comparison normalization changes only CRLF" {
    const normalized = try normalizeCrlfAlloc(std.testing.allocator, "a\r\nb\rc\n");
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings("a\nb\rc\n", normalized);
}
