const std = @import("std");

/// Parsed, normalized representation of a unified diff.
///
/// String fields are slices into the caller-owned raw diff text. The array
/// fields are allocated with the allocator passed to `parse`.
pub const DiffDocument = struct {
    files: []const FileDiff,

    pub fn totalHunks(self: DiffDocument) usize {
        var count: usize = 0;
        for (self.files) |file| count += file.hunks.len;
        return count;
    }
};

pub const FileDiff = struct {
    /// Usually the `diff --git ...` line. Plain unified diffs without that
    /// header use the first path or hunk header that introduced the file.
    header: []const u8,
    old_path: ?[]const u8 = null,
    new_path: ?[]const u8 = null,
    /// File-level lines that are not hunk contents: index, mode changes,
    /// rename/copy metadata, path headers, and binary markers.
    metadata: []const []const u8,
    hunks: []const Hunk,
    is_binary: bool = false,
};

pub const Hunk = struct {
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    /// Optional text after the closing `@@`, often a function or section name.
    section: []const u8,
    lines: []const DiffLine,
};

pub const DiffLine = struct {
    kind: Kind,
    /// Hunk text without the unified diff prefix for content lines. Metadata
    /// lines keep their original text because their syntax varies.
    text: []const u8,
    old_line: ?u32 = null,
    new_line: ?u32 = null,

    pub const Kind = enum {
        context,
        added,
        removed,
        metadata,
    };
};

pub const ParseError = error{
    InvalidHunkHeader,
    InvalidHunkRange,
    OutOfMemory,
};

pub fn parse(allocator: std.mem.Allocator, text: []const u8) ParseError!DiffDocument {
    var parser: Parser = .{ .allocator = allocator };
    return parser.parse(text);
}

const Parser = struct {
    allocator: std.mem.Allocator,
    files: std.ArrayList(FileDiff) = .empty,
    current_file: ?FileBuilder = null,
    current_hunk: ?HunkBuilder = null,
    old_line: u32 = 0,
    new_line: u32 = 0,

    fn parse(self: *Parser, text: []const u8) ParseError!DiffDocument {
        // Avoid splitScalar here: a trailing '\n' would produce a phantom empty
        // line and corrupt the final hunk's line count.
        var start: usize = 0;
        while (start < text.len) {
            const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
            const raw_line = text[start..end];
            const line = stripTrailingCarriageReturn(raw_line);
            try self.parseLine(line);
            start = if (end < text.len) end + 1 else text.len;
        }

        try self.finishHunk();
        try self.finishFile();
        return .{ .files = try self.files.toOwnedSlice(self.allocator) };
    }

    fn parseLine(self: *Parser, line: []const u8) ParseError!void {
        // Plain unified diffs do not have `diff --git` file headers, so hunk
        // line counts are the only reliable boundary before the next `---`.
        if (self.current_hunk != null and self.current_hunk.?.isComplete() and !std.mem.startsWith(u8, line, "\\")) {
            try self.finishHunk();
        }

        if (std.mem.startsWith(u8, line, "diff --git ")) {
            try self.startFile(line);
        } else if (std.mem.startsWith(u8, line, "@@ ")) {
            try self.startHunk(try parseHunkHeader(line));
        } else if (self.current_hunk != null) {
            // Hunk contents can legitimately be `--- ...` or `+++ ...`.
            // Once inside a hunk, only an explicit hunk/file boundary above
            // should be interpreted structurally.
            try self.parseHunkLine(line);
        } else if (std.mem.startsWith(u8, line, "--- ")) {
            // After a completed hunk, a new old-path header starts the next
            // plain unified diff file.
            if (self.current_file != null and self.current_file.?.hunks.items.len > 0) {
                try self.finishFile();
            }
            try self.ensureFile(line);
            self.current_file.?.old_path = parsePath(line[4..]);
            try self.current_file.?.metadata.append(self.allocator, line);
        } else if (std.mem.startsWith(u8, line, "+++ ")) {
            try self.ensureFile(line);
            self.current_file.?.new_path = parsePath(line[4..]);
            try self.current_file.?.metadata.append(self.allocator, line);
        } else if (self.current_file != null) {
            if (std.mem.startsWith(u8, line, "Binary files ")) self.current_file.?.is_binary = true;
            try self.current_file.?.metadata.append(self.allocator, line);
        }
    }

    fn startFile(self: *Parser, header: []const u8) ParseError!void {
        // A new file header closes any previous hunk/file currently being built.
        try self.finishHunk();
        try self.finishFile();
        self.current_file = .{ .header = header };
    }

    fn ensureFile(self: *Parser, header: []const u8) ParseError!void {
        if (self.current_file == null) self.current_file = .{ .header = header };
    }

    fn finishFile(self: *Parser) ParseError!void {
        if (self.current_file) |*file| {
            try self.files.append(self.allocator, .{
                .header = file.header,
                .old_path = file.old_path,
                .new_path = file.new_path,
                .metadata = try file.metadata.toOwnedSlice(self.allocator),
                .hunks = try file.hunks.toOwnedSlice(self.allocator),
                .is_binary = file.is_binary,
            });
        }
        self.current_file = null;
    }

    fn startHunk(self: *Parser, parsed: ParsedHunkHeader) ParseError!void {
        try self.ensureFile(parsed.header);
        try self.finishHunk();
        self.current_hunk = .{
            .old_start = parsed.old_start,
            .old_count = parsed.old_count,
            .new_start = parsed.new_start,
            .new_count = parsed.new_count,
            .section = parsed.section,
        };
        // These counters are assigned to DiffLine as lines are consumed. That
        // keeps renderers from re-deriving line numbers from hunk ranges.
        self.old_line = parsed.old_start;
        self.new_line = parsed.new_start;
    }

    fn finishHunk(self: *Parser) ParseError!void {
        if (self.current_hunk) |*hunk| {
            try self.current_file.?.hunks.append(self.allocator, .{
                .old_start = hunk.old_start,
                .old_count = hunk.old_count,
                .new_start = hunk.new_start,
                .new_count = hunk.new_count,
                .section = hunk.section,
                .lines = try hunk.lines.toOwnedSlice(self.allocator),
            });
        }
        self.current_hunk = null;
    }

    fn parseHunkLine(self: *Parser, line: []const u8) ParseError!void {
        // An empty line inside a hunk is a context line. A final trailing
        // newline is filtered by Parser.parse before it reaches this point.
        if (line.len == 0) {
            try self.appendHunkLine(.context, line, self.old_line, self.new_line);
            self.old_line += 1;
            self.new_line += 1;
            self.current_hunk.?.old_seen += 1;
            self.current_hunk.?.new_seen += 1;
            return;
        }

        switch (line[0]) {
            ' ' => {
                try self.appendHunkLine(.context, line[1..], self.old_line, self.new_line);
                self.old_line += 1;
                self.new_line += 1;
                self.current_hunk.?.old_seen += 1;
                self.current_hunk.?.new_seen += 1;
            },
            '+' => {
                try self.appendHunkLine(.added, line[1..], null, self.new_line);
                self.new_line += 1;
                self.current_hunk.?.new_seen += 1;
            },
            '-' => {
                try self.appendHunkLine(.removed, line[1..], self.old_line, null);
                self.old_line += 1;
                self.current_hunk.?.old_seen += 1;
            },
            '\\' => try self.appendHunkLine(.metadata, line, null, null),
            else => try self.appendHunkLine(.metadata, line, null, null),
        }
    }

    fn appendHunkLine(self: *Parser, kind: DiffLine.Kind, text: []const u8, old_line: ?u32, new_line: ?u32) ParseError!void {
        try self.current_hunk.?.lines.append(self.allocator, .{
            .kind = kind,
            .text = text,
            .old_line = old_line,
            .new_line = new_line,
        });
    }
};

const FileBuilder = struct {
    header: []const u8,
    old_path: ?[]const u8 = null,
    new_path: ?[]const u8 = null,
    metadata: std.ArrayList([]const u8) = .empty,
    hunks: std.ArrayList(Hunk) = .empty,
    is_binary: bool = false,
};

const HunkBuilder = struct {
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    old_seen: u32 = 0,
    new_seen: u32 = 0,
    section: []const u8,
    lines: std.ArrayList(DiffLine) = .empty,

    fn isComplete(self: HunkBuilder) bool {
        return self.old_seen >= self.old_count and self.new_seen >= self.new_count;
    }
};

const ParsedHunkHeader = struct {
    header: []const u8,
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    section: []const u8,
};

fn parseHunkHeader(line: []const u8) ParseError!ParsedHunkHeader {
    // Unified hunk headers are `@@ -old,count +new,count @@ optional section`.
    // Git omits `,count` when the count is one; parseRange handles that form.
    const close = std.mem.indexOfPos(u8, line, 3, "@@") orelse return error.InvalidHunkHeader;
    const ranges = std.mem.trim(u8, line[2..close], " ");
    const section = std.mem.trim(u8, line[close + 2 ..], " ");

    var parts = std.mem.splitScalar(u8, ranges, ' ');
    const old_part = parts.next() orelse return error.InvalidHunkHeader;
    const new_part = parts.next() orelse return error.InvalidHunkHeader;
    if (parts.next() != null) return error.InvalidHunkHeader;

    const old_range = try parseRange(old_part, '-');
    const new_range = try parseRange(new_part, '+');
    return .{
        .header = line,
        .old_start = old_range.start,
        .old_count = old_range.count,
        .new_start = new_range.start,
        .new_count = new_range.count,
        .section = section,
    };
}

const LineRange = struct {
    start: u32,
    count: u32,
};

fn parseRange(part: []const u8, expected_prefix: u8) ParseError!LineRange {
    if (part.len < 2 or part[0] != expected_prefix) return error.InvalidHunkRange;
    const body = part[1..];
    if (std.mem.indexOfScalar(u8, body, ',')) |comma| {
        return .{
            .start = std.fmt.parseInt(u32, body[0..comma], 10) catch return error.InvalidHunkRange,
            .count = std.fmt.parseInt(u32, body[comma + 1 ..], 10) catch return error.InvalidHunkRange,
        };
    }

    return .{
        .start = std.fmt.parseInt(u32, body, 10) catch return error.InvalidHunkRange,
        .count = 1,
    };
}

fn parsePath(raw: []const u8) ?[]const u8 {
    const path = std.mem.trim(u8, raw, " \t");
    if (std.mem.eql(u8, path, "/dev/null")) return null;
    return path;
}

fn stripTrailingCarriageReturn(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

test "parse unified diff with one file and one hunk" {
    const text =
        \\diff --git a/src/main.zig b/src/main.zig
        \\index 1234567..89abcde 100644
        \\--- a/src/main.zig
        \\+++ b/src/main.zig
        \\@@ -1,2 +1,3 @@ fn main
        \\ const std = @import("std");
        \\-const old = true;
        \\+const new = true;
        \\+const added = true;
        \\
    ;

    const doc = try parse(std.testing.allocator, text);
    defer freeDocument(std.testing.allocator, doc);

    try std.testing.expectEqual(@as(usize, 1), doc.files.len);
    try std.testing.expectEqual(@as(usize, 1), doc.totalHunks());
    try std.testing.expectEqualStrings("a/src/main.zig", doc.files[0].old_path.?);
    try std.testing.expectEqualStrings("b/src/main.zig", doc.files[0].new_path.?);
    try std.testing.expectEqual(@as(u32, 1), doc.files[0].hunks[0].old_start);
    try std.testing.expectEqual(@as(u32, 3), doc.files[0].hunks[0].new_count);
    try std.testing.expectEqual(DiffLine.Kind.removed, doc.files[0].hunks[0].lines[1].kind);
    try std.testing.expectEqual(@as(u32, 2), doc.files[0].hunks[0].lines[1].old_line.?);
    try std.testing.expect(doc.files[0].hunks[0].lines[1].new_line == null);
}

test "parse multiple files and binary metadata" {
    const text =
        \\diff --git a/a.txt b/a.txt
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\diff --git a/image.png b/image.png
        \\Binary files a/image.png and b/image.png differ
        \\
    ;

    const doc = try parse(std.testing.allocator, text);
    defer freeDocument(std.testing.allocator, doc);

    try std.testing.expectEqual(@as(usize, 2), doc.files.len);
    try std.testing.expectEqual(@as(usize, 1), doc.totalHunks());
    try std.testing.expect(doc.files[1].is_binary);
}

test "parse hunk ranges without explicit counts" {
    const text =
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -4 +5 @@
        \\-old
        \\+new
        \\
    ;

    const doc = try parse(std.testing.allocator, text);
    defer freeDocument(std.testing.allocator, doc);

    try std.testing.expectEqual(@as(u32, 4), doc.files[0].hunks[0].old_start);
    try std.testing.expectEqual(@as(u32, 1), doc.files[0].hunks[0].old_count);
    try std.testing.expectEqual(@as(u32, 5), doc.files[0].hunks[0].new_start);
    try std.testing.expectEqual(@as(u32, 1), doc.files[0].hunks[0].new_count);
}

test "parse hunk lines that look like file path headers" {
    const text =
        \\--- a/markers.txt
        \\+++ b/markers.txt
        \\@@ -1,2 +1,2 @@
        \\--- separator
        \\+++ separator
        \\
    ;

    const doc = try parse(std.testing.allocator, text);
    defer freeDocument(std.testing.allocator, doc);

    const lines = doc.files[0].hunks[0].lines;
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqual(DiffLine.Kind.removed, lines[0].kind);
    try std.testing.expectEqualStrings("-- separator", lines[0].text);
    try std.testing.expectEqual(DiffLine.Kind.added, lines[1].kind);
    try std.testing.expectEqualStrings("++ separator", lines[1].text);
    try std.testing.expectEqualStrings("a/markers.txt", doc.files[0].old_path.?);
    try std.testing.expectEqualStrings("b/markers.txt", doc.files[0].new_path.?);
}

test "parse plain unified diff with multiple files" {
    const text =
        \\--- old/one.txt
        \\+++ new/one.txt
        \\@@ -1 +1 @@
        \\-one old
        \\+one new
        \\--- old/two.txt
        \\+++ new/two.txt
        \\@@ -1 +1 @@
        \\-two old
        \\+two new
        \\
    ;

    const doc = try parse(std.testing.allocator, text);
    defer freeDocument(std.testing.allocator, doc);

    try std.testing.expectEqual(@as(usize, 2), doc.files.len);
    try std.testing.expectEqualStrings("old/one.txt", doc.files[0].old_path.?);
    try std.testing.expectEqualStrings("new/one.txt", doc.files[0].new_path.?);
    try std.testing.expectEqualStrings("old/two.txt", doc.files[1].old_path.?);
    try std.testing.expectEqualStrings("new/two.txt", doc.files[1].new_path.?);
    try std.testing.expectEqualStrings("one old", doc.files[0].hunks[0].lines[0].text);
    try std.testing.expectEqualStrings("two old", doc.files[1].hunks[0].lines[0].text);
}

test "parse ignores trailing newline after final hunk line" {
    const text =
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\
    ;

    const doc = try parse(std.testing.allocator, text);
    defer freeDocument(std.testing.allocator, doc);

    const lines = doc.files[0].hunks[0].lines;
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqual(DiffLine.Kind.removed, lines[0].kind);
    try std.testing.expectEqual(DiffLine.Kind.added, lines[1].kind);
}

fn freeDocument(allocator: std.mem.Allocator, doc: DiffDocument) void {
    for (doc.files) |file| {
        for (file.hunks) |hunk| allocator.free(hunk.lines);
        allocator.free(file.hunks);
        allocator.free(file.metadata);
    }
    allocator.free(doc.files);
}
