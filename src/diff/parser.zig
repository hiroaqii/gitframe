const std = @import("std");

/// Parsed, normalized representation of a unified diff.
///
/// Patch text and unquoted paths borrow the input. Decoded quoted paths and
/// arrays belong to this document and are freed with `deinit`.
pub const DiffDocument = struct {
    files: []const FileDiff,
    owned_paths: []const []u8 = &.{},

    pub fn totalHunks(self: DiffDocument) usize {
        var count: usize = 0;
        for (self.files) |file| count += file.hunks.len;
        return count;
    }

    /// Free parser allocations; the caller still owns the original diff text.
    pub fn deinit(self: DiffDocument, allocator: std.mem.Allocator) void {
        for (self.files) |file| {
            for (file.hunks) |hunk| allocator.free(hunk.lines);
            allocator.free(file.hunks);
            allocator.free(file.metadata);
        }
        allocator.free(self.files);
        for (self.owned_paths) |path| allocator.free(path);
        allocator.free(self.owned_paths);
    }
};

pub const FileDiff = struct {
    /// Usually the `diff --git ...` line. Plain unified diffs without that
    /// header use the first path or hunk header that introduced the file.
    header: []const u8,
    /// Decoded repository-relative bytes. Null denotes an absent/unknown side;
    /// protocol prefixes and `/dev/null` never appear as path identities.
    old_path: ?[]const u8 = null,
    new_path: ?[]const u8 = null,
    /// File-level lines that are not hunk contents: index, mode changes,
    /// rename/copy metadata, path headers, and binary markers.
    metadata: []const []const u8,
    hunks: []const Hunk,
    is_binary: bool = false,
};

pub const Hunk = struct {
    /// The complete `@@ ... @@` line. The parser borrows the input bytes;
    /// display projections own a replacement when they normalize coordinates.
    /// Copy actions use this header, so its ranges must agree with the fields.
    header: []const u8 = "",
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
    InvalidDiffPath,
    InvalidHunkHeader,
    InvalidHunkRange,
    OutOfMemory,
};

/// Parse a unified diff, copying only paths that require C-quote decoding.
///
/// The returned document borrows patch text and unquoted paths from `text`;
/// keep `text` alive for the lifetime of the document. For long-lived app state, copy
/// `text` into the same arena used for parsing so the borrowed strings and
/// parser-allocated arrays share one cleanup boundary.
pub fn parse(allocator: std.mem.Allocator, text: []const u8) ParseError!DiffDocument {
    var parser: Parser = .{ .allocator = allocator };
    errdefer parser.deinitPartial();
    return parser.parse(text);
}

const Parser = struct {
    allocator: std.mem.Allocator,
    files: std.ArrayList(FileDiff) = .empty,
    owned_paths: std.ArrayList([]u8) = .empty,
    current_file: ?FileBuilder = null,
    current_hunk: ?HunkBuilder = null,
    old_line: u32 = 0,
    new_line: u32 = 0,

    fn deinitPartial(self: *Parser) void {
        if (self.current_hunk) |*hunk| hunk.lines.deinit(self.allocator);
        self.current_hunk = null;

        if (self.current_file) |*file| {
            for (file.hunks.items) |hunk| self.allocator.free(hunk.lines);
            file.hunks.deinit(self.allocator);
            file.metadata.deinit(self.allocator);
        }
        self.current_file = null;

        for (self.files.items) |file| {
            for (file.hunks) |hunk| self.allocator.free(hunk.lines);
            self.allocator.free(file.hunks);
            self.allocator.free(file.metadata);
        }
        self.files.deinit(self.allocator);
        for (self.owned_paths.items) |path| self.allocator.free(path);
        self.owned_paths.deinit(self.allocator);
    }

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
        const owned_paths = try self.owned_paths.toOwnedSlice(self.allocator);
        errdefer {
            for (owned_paths) |path| self.allocator.free(path);
            self.allocator.free(owned_paths);
        }
        return .{
            .files = try self.files.toOwnedSlice(self.allocator),
            .owned_paths = owned_paths,
        };
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
            self.current_file.?.old_endpoint = line[4..];
            try self.current_file.?.metadata.append(self.allocator, line);
        } else if (std.mem.startsWith(u8, line, "+++ ")) {
            try self.ensureFile(line);
            self.current_file.?.new_endpoint = line[4..];
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
            var old_path = if (file.old_endpoint) |raw| try self.parseEndpoint(raw, 'a') else null;
            var new_path = if (file.new_endpoint) |raw| try self.parseEndpoint(raw, 'b') else null;
            if (file.old_endpoint == null and file.new_endpoint == null) {
                for (file.metadata.items) |line| {
                    if (std.mem.startsWith(u8, line, "rename from ")) old_path = try self.decodePath(line[12..]);
                    if (std.mem.startsWith(u8, line, "rename to ")) new_path = try self.decodePath(line[10..]);
                    if (std.mem.startsWith(u8, line, "copy from ")) old_path = try self.decodePath(line[10..]);
                    if (std.mem.startsWith(u8, line, "copy to ")) new_path = try self.decodePath(line[8..]);
                }
                if (old_path == null and new_path == null) {
                    old_path = try self.samePathHeader(file.header);
                    new_path = old_path;
                }
                for (file.metadata.items) |line| {
                    if (std.mem.startsWith(u8, line, "new file mode ")) old_path = null;
                    if (std.mem.startsWith(u8, line, "deleted file mode ")) new_path = null;
                }
            }
            const metadata = try file.metadata.toOwnedSlice(self.allocator);
            errdefer self.allocator.free(metadata);

            const hunks = try file.hunks.toOwnedSlice(self.allocator);
            errdefer {
                for (hunks) |hunk| self.allocator.free(hunk.lines);
                self.allocator.free(hunks);
            }

            try self.files.append(self.allocator, .{
                .header = file.header,
                .old_path = old_path,
                .new_path = new_path,
                .metadata = metadata,
                .hunks = hunks,
                .is_binary = file.is_binary,
            });
        }
        self.current_file = null;
    }

    fn parseEndpoint(self: *Parser, raw: []const u8, side: u8) ParseError!?[]const u8 {
        const end = if (std.mem.startsWith(u8, raw, "\""))
            try quotedPathLength(raw)
        else
            std.mem.indexOfScalar(u8, raw, '\t') orelse raw.len;
        if (end < raw.len and raw[end] != '\t') return error.InvalidDiffPath;
        const decoded = try self.decodePath(raw[0..end]);
        if (std.mem.eql(u8, decoded, "/dev/null")) return null;
        const path = if (decoded.len >= 2 and decoded[0] == side and decoded[1] == '/') decoded[2..] else decoded;
        if (path.len == 0) return error.InvalidDiffPath;
        return path;
    }

    /// Git's metadata-only non-rename header repeats the same path on both
    /// sides. Equal halves preserve spaces, even a literal ` b/` in the name.
    fn samePathHeader(self: *Parser, header: []const u8) ParseError!?[]const u8 {
        const prefix = "diff --git ";
        if (!std.mem.startsWith(u8, header, prefix)) return null;
        const raw = header[prefix.len..];
        const split = if (std.mem.startsWith(u8, raw, "\""))
            try quotedPathLength(raw)
        else if (raw.len % 2 == 1)
            raw.len / 2
        else
            return null;
        if (split >= raw.len or raw[split] != ' ') return null;
        const old = try self.decodePath(raw[0..split]);
        const new = try self.decodePath(raw[split + 1 ..]);
        if (!std.mem.startsWith(u8, old, "a/") or !std.mem.startsWith(u8, new, "b/")) return null;
        if (old.len <= 2 or !std.mem.eql(u8, old[2..], new[2..])) return null;
        return old[2..];
    }

    fn decodePath(self: *Parser, raw: []const u8) ParseError![]const u8 {
        if (raw.len == 0) return error.InvalidDiffPath;
        if (raw[0] != '"') {
            if (std.mem.indexOfScalar(u8, raw, 0) != null) return error.InvalidDiffPath;
            return raw;
        }
        if (try quotedPathLength(raw) != raw.len) return error.InvalidDiffPath;
        const decoded = try self.allocator.alloc(u8, raw.len - 2);
        errdefer self.allocator.free(decoded);
        var input: usize = 1;
        var written: usize = 0;
        const end = raw.len - 1;
        while (input < end) {
            var byte = raw[input];
            input += 1;
            if (byte == '\\') {
                if (input >= end) return error.InvalidDiffPath;
                const escape = raw[input];
                input += 1;
                byte = switch (escape) {
                    'a' => 7,
                    'b' => 8,
                    't' => '\t',
                    'n' => '\n',
                    'v' => 11,
                    'f' => 12,
                    'r' => '\r',
                    '\\', '"' => escape,
                    '0'...'3' => blk: {
                        if (end - input < 2) return error.InvalidDiffPath;
                        const second = raw[input];
                        const third = raw[input + 1];
                        if (second < '0' or second > '7' or third < '0' or third > '7') return error.InvalidDiffPath;
                        const value = (escape - '0') * 64 + (second - '0') * 8 + (third - '0');
                        input += 2;
                        break :blk value;
                    },
                    else => return error.InvalidDiffPath,
                };
            }
            if (byte == 0) return error.InvalidDiffPath;
            decoded[written] = byte;
            written += 1;
        }
        if (written == 0) return error.InvalidDiffPath;
        try self.owned_paths.append(self.allocator, decoded);
        return decoded[0..written];
    }

    fn startHunk(self: *Parser, parsed: ParsedHunkHeader) ParseError!void {
        try self.ensureFile(parsed.header);
        try self.finishHunk();
        self.current_hunk = .{
            .header = parsed.header,
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
            const lines = try hunk.lines.toOwnedSlice(self.allocator);
            errdefer self.allocator.free(lines);

            try self.current_file.?.hunks.append(self.allocator, .{
                .header = hunk.header,
                .old_start = hunk.old_start,
                .old_count = hunk.old_count,
                .new_start = hunk.new_start,
                .new_count = hunk.new_count,
                .section = hunk.section,
                .lines = lines,
            });
        }
        self.current_hunk = null;
    }

    fn parseHunkLine(self: *Parser, line: []const u8) ParseError!void {
        // Empty interior lines are context; Parser.parse discards the final LF.
        if (line.len == 0) return self.appendHunkLine(.context, line, self.old_line, self.new_line);
        switch (line[0]) {
            ' ' => try self.appendHunkLine(.context, line[1..], self.old_line, self.new_line),
            '+' => try self.appendHunkLine(.added, line[1..], null, self.new_line),
            '-' => try self.appendHunkLine(.removed, line[1..], self.old_line, null),
            else => try self.appendHunkLine(.metadata, line, null, null),
        }
    }

    fn appendHunkLine(self: *Parser, kind: DiffLine.Kind, text: []const u8, old_line: ?u32, new_line: ?u32) ParseError!void {
        // Validate actual consumption too: a malformed body may exceed its header.
        if (old_line != null) {
            self.old_line = std.math.add(u32, self.old_line, 1) catch return error.InvalidHunkRange;
            self.current_hunk.?.old_seen = std.math.add(u32, self.current_hunk.?.old_seen, 1) catch return error.InvalidHunkRange;
        }
        if (new_line != null) {
            self.new_line = std.math.add(u32, self.new_line, 1) catch return error.InvalidHunkRange;
            self.current_hunk.?.new_seen = std.math.add(u32, self.current_hunk.?.new_seen, 1) catch return error.InvalidHunkRange;
        }
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
    old_endpoint: ?[]const u8 = null,
    new_endpoint: ?[]const u8 = null,
    metadata: std.ArrayList([]const u8) = .empty,
    hunks: std.ArrayList(Hunk) = .empty,
    is_binary: bool = false,
};

const HunkBuilder = struct {
    header: []const u8,
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
    const range: LineRange = if (std.mem.indexOfScalar(u8, body, ',')) |comma| .{
        .start = std.fmt.parseInt(u32, body[0..comma], 10) catch return error.InvalidHunkRange,
        .count = std.fmt.parseInt(u32, body[comma + 1 ..], 10) catch return error.InvalidHunkRange,
    } else .{
        .start = std.fmt.parseInt(u32, body, 10) catch return error.InvalidHunkRange,
        .count = 1,
    };
    // Consumers use the exclusive end as well as individual line numbers.
    _ = std.math.add(u32, range.start, range.count) catch return error.InvalidHunkRange;
    return range;
}

fn quotedPathLength(raw: []const u8) ParseError!usize {
    var index: usize = 1;
    while (index < raw.len) : (index += 1) {
        if (raw[index] == '"') return index + 1;
        if (raw[index] == '\\') index += 1;
    }
    return error.InvalidDiffPath;
}

fn stripTrailingCarriageReturn(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

test "diff path endpoints preserve raw bytes and encoded patch text" {
    const cases = [_]struct { old: []const u8, new: []const u8, path: []const u8 }{
        .{ .old = "a/a/victim", .new = "b/a/victim", .path = "a/victim" },
        .{ .old = "a/b/victim", .new = "b/b/victim", .path = "b/victim" },
        .{ .old = "a/has space \t", .new = "b/has space \t", .path = "has space " },
        .{ .old = "\"a/tail\\t\"", .new = "\"b/tail\\t\"", .path = "tail\t" },
        .{ .old = "\"a/quote\\\"slash\\\\\"", .new = "\"b/quote\\\"slash\\\\\"", .path = "quote\"slash\\" },
        .{ .old = "\"a/\\a\\b\\t\\n\\v\\f\\r\"", .new = "\"b/\\a\\b\\t\\n\\v\\f\\r\"", .path = "\x07\x08\t\n\x0b\x0c\r" },
        .{ .old = "\"a/\\346\\227\\245\\346\\234\\254\\350\\252\\236.txt\"", .new = "\"b/\\346\\227\\245\\346\\234\\254\\350\\252\\236.txt\"", .path = "日本語.txt" },
        .{ .old = "\"a/\\377.txt\"", .new = "\"b/\\377.txt\"", .path = "\xff.txt" },
    };
    for (cases) |case| {
        const text = try std.fmt.allocPrint(std.testing.allocator, "--- {s}\n+++ {s}\n@@ -1 +1 @@\n-old\n+new\n", .{ case.old, case.new });
        defer std.testing.allocator.free(text);
        const doc = try parse(std.testing.allocator, text);
        defer doc.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(case.path, doc.files[0].old_path.?);
        try std.testing.expectEqualStrings(case.path, doc.files[0].new_path.?);
        try std.testing.expectEqualStrings(text[0..std.mem.indexOfScalar(u8, text, '\n').?], doc.files[0].metadata[0]);
        try std.testing.expectEqualStrings("old", doc.files[0].hunks[0].lines[0].text);
    }
}

test "diff metadata resolves raw sides without whitespace splitting" {
    const cases = [_]struct { text: []const u8, old: ?[]const u8, new: ?[]const u8 }{
        .{ .text = "diff --git a/part b/name  b/part b/name \nold mode 100644\nnew mode 100755\n", .old = "part b/name ", .new = "part b/name " },
        .{ .text = "diff --git \"a/tail\\t\" \"b/tail\\t\"\nold mode 100644\nnew mode 100755\n", .old = "tail\t", .new = "tail\t" },
        .{ .text = "diff --git a/image.bin b/image.bin\nBinary files a/image.bin and b/image.bin differ\n", .old = "image.bin", .new = "image.bin" },
        .{ .text = "diff --git a/empty b/empty\nnew file mode 100644\n", .old = null, .new = "empty" },
        .{ .text = "diff --git a/empty b/empty\ndeleted file mode 100644\n", .old = "empty", .new = null },
        .{ .text = "diff --git a/old b/new\nrename from \"old\\t.txt\"\nrename to \"a/new\\377\"\n", .old = "old\t.txt", .new = "a/new\xff" },
        .{ .text = "diff --git a/a/old b/b/new\ncopy from a/old\ncopy to b/new\n", .old = "a/old", .new = "b/new" },
        .{ .text = "diff --git a/new b/new\n--- /dev/null\n+++ b/new\n@@ -0,0 +1 @@\n+new\n", .old = null, .new = "new" },
        .{ .text = "diff --git a/old b/old\n--- a/old\n+++ /dev/null\n@@ -1 +0,0 @@\n-old\n", .old = "old", .new = null },
        .{ .text = "diff --git a/old b/new\nindex 111..222\n", .old = null, .new = null },
    };
    for (cases) |case| {
        const doc = try parse(std.testing.allocator, case.text);
        defer doc.deinit(std.testing.allocator);
        const file = doc.files[0];
        if (case.old) |path| {
            try std.testing.expectEqualStrings(path, file.old_path.?);
        } else try std.testing.expect(file.old_path == null);
        if (case.new) |path| {
            try std.testing.expectEqualStrings(path, file.new_path.?);
        } else try std.testing.expect(file.new_path == null);
    }
}

test "diff path rejects malformed endpoints and cleans earlier decoded files" {
    const invalid = [_][]const u8{
        "",            "a/",          "\"\"",        "\"a/unterminated", "\"a/\\q\"", "\"a/\\12\"",
        "\"a/\\400\"", "\"a/\\0_1\"", "\"a/\\000\"", "\"a/ok\"junk",     "a/\x00",
    };
    for (invalid) |endpoint| {
        const text = try std.fmt.allocPrint(std.testing.allocator, "diff --git a/good b/good\n--- \"a/good\\t\"\n+++ \"b/good\\t\"\ndiff --git a/bad b/bad\n--- {s}\n+++ b/bad\n", .{endpoint});
        defer std.testing.allocator.free(text);
        try std.testing.expectError(error.InvalidDiffPath, parse(std.testing.allocator, text));
    }
}

test "diff path allocations clean up on every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseQuotedPathAllocationCase, .{});
}

fn parseQuotedPathAllocationCase(allocator: std.mem.Allocator) !void {
    const text = "diff --git \"a/file\\t\" \"b/file\\t\"\n--- \"a/file\\t\"\n+++ \"b/file\\t\"\n@@ -1 +1 @@\n-old\n+new\ndiff --git a/old b/new\nrename from \"old\\377\"\nrename to \"b/new\\t\"\n";
    const doc = try parse(allocator, text);
    defer doc.deinit(allocator);
    try std.testing.expectEqualStrings("file\t", doc.files[0].new_path.?);
    try std.testing.expectEqualStrings("b/new\t", doc.files[1].new_path.?);
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
    defer doc.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.files.len);
    try std.testing.expectEqual(@as(usize, 1), doc.totalHunks());
    try std.testing.expectEqualStrings("src/main.zig", doc.files[0].old_path.?);
    try std.testing.expectEqualStrings("src/main.zig", doc.files[0].new_path.?);
    try std.testing.expectEqual(@as(u32, 1), doc.files[0].hunks[0].old_start);
    try std.testing.expectEqual(@as(u32, 3), doc.files[0].hunks[0].new_count);
    try std.testing.expectEqualStrings("@@ -1,2 +1,3 @@ fn main", doc.files[0].hunks[0].header);
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
    defer doc.deinit(std.testing.allocator);

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
    defer doc.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 4), doc.files[0].hunks[0].old_start);
    try std.testing.expectEqual(@as(u32, 1), doc.files[0].hunks[0].old_count);
    try std.testing.expectEqual(@as(u32, 5), doc.files[0].hunks[0].new_start);
    try std.testing.expectEqual(@as(u32, 1), doc.files[0].hunks[0].new_count);
    try std.testing.expectEqualStrings("@@ -4 +5 @@", doc.files[0].hunks[0].header);
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
    defer doc.deinit(std.testing.allocator);

    const lines = doc.files[0].hunks[0].lines;
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqual(DiffLine.Kind.removed, lines[0].kind);
    try std.testing.expectEqualStrings("-- separator", lines[0].text);
    try std.testing.expectEqual(DiffLine.Kind.added, lines[1].kind);
    try std.testing.expectEqualStrings("++ separator", lines[1].text);
    try std.testing.expectEqualStrings("markers.txt", doc.files[0].old_path.?);
    try std.testing.expectEqualStrings("markers.txt", doc.files[0].new_path.?);
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
    defer doc.deinit(std.testing.allocator);

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
    defer doc.deinit(std.testing.allocator);

    const lines = doc.files[0].hunks[0].lines;
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqual(DiffLine.Kind.removed, lines[0].kind);
    try std.testing.expectEqual(DiffLine.Kind.added, lines[1].kind);
}

test "parse skips git show preamble before diff header" {
    const text =
        \\commit 1111111111111111111111111111111111111111
        \\Author: Example <example@example.com>
        \\
        \\    subject line
        \\
        \\diff --git a/src/app.zig b/src/app.zig
        \\index 1111111..2222222 100644
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\
    ;

    const doc = try parse(std.testing.allocator, text);
    defer doc.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.files.len);
    try std.testing.expectEqualStrings("diff --git a/src/app.zig b/src/app.zig", doc.files[0].header);
    try std.testing.expectEqual(@as(usize, 1), doc.files[0].hunks.len);
}

test "parse non-diff text as empty document" {
    const text =
        \\commit 1111111111111111111111111111111111111111
        \\Author: Example <example@example.com>
        \\
        \\    subject line only
        \\
    ;

    const doc = try parse(std.testing.allocator, text);
    defer doc.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), doc.files.len);
}

test "parse cleans partial allocations on error" {
    const text =
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\@@ invalid
        \\
    ;

    try std.testing.expectError(error.InvalidHunkHeader, parse(std.testing.allocator, text));
}

test "parse checks declared and consumed coordinate boundaries" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{
        "@@ -4294967295 +4294967295 @@\n context\n",
        "@@ -1 +4294967295,2 @@\n",
        "@@ -4294967295,2 +1 @@\n",
        "@@ -4294967296,0 +1 @@\n",
        "@@ -4294967294 +1,2 @@\n context\n-overrun\n",
        "@@ -1,2 +4294967294 @@\n context\n+overrun\n",
    }) |text| try std.testing.expectError(error.InvalidHunkRange, parse(allocator, text));
    const valid = try parse(allocator, "@@ -4294967294 +4294967294 @@\n context\n@@ -4294967295,0 +4294967295,0 @@\n");
    defer valid.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 4294967294), valid.files[0].hunks[0].lines[0].new_line.?);
    try std.testing.expectEqual(@as(usize, 2), valid.files[0].hunks.len);
}
