const std = @import("std");

/// Canonical repo-relative path used to connect diff files, status entries,
/// reviewed state, and action targets.
///
/// The slice is borrowed from the source document. Async payloads or persistent
/// stores must duplicate the key before keeping it beyond the active load.
pub const PathKey = []const u8;

/// Normalize a git path to a repo-relative key.
///
/// Removes `a/` and `b/` side prefixes and excludes `/dev/null`, which is a
/// diff endpoint rather than a repository path.
pub fn canonicalRepoPath(path: []const u8) ?PathKey {
    if (isDevNull(path)) return null;
    const stripped = stripGitSidePrefix(path);
    if (isDevNull(stripped) or stripped.len == 0) return null;
    return stripped;
}

pub fn stripGitSidePrefix(path: []const u8) []const u8 {
    if (path.len >= 2 and (path[0] == 'a' or path[0] == 'b') and path[1] == '/') return path[2..];
    return path;
}

pub fn isDevNull(path: []const u8) bool {
    return std.mem.eql(u8, path, "/dev/null");
}

/// Compare two sibling names using the file tree's visible contract:
/// directories first, then files, with bytewise names inside each group.
/// Callers with equal names may apply their own complete-path tie breaker.
pub fn displaySiblingOrder(
    left_is_directory: bool,
    left_name: []const u8,
    right_is_directory: bool,
    right_name: []const u8,
) std.math.Order {
    if (left_is_directory != right_is_directory) {
        return if (left_is_directory) .lt else .gt;
    }
    return std.mem.order(u8, left_name, right_name);
}

/// Order flat raw repository paths exactly as file rows appear when a file
/// tree is traversed depth first: directories before files at every level,
/// then bytewise sibling names. Display escaping is never an order key.
pub fn displayPathLessThan(_: void, left: []const u8, right: []const u8) bool {
    var left_start: usize = 0;
    var right_start: usize = 0;
    while (true) {
        const left_end = std.mem.indexOfScalarPos(u8, left, left_start, '/') orelse left.len;
        const right_end = std.mem.indexOfScalarPos(u8, right, right_start, '/') orelse right.len;
        const left_is_directory = left_end < left.len;
        const right_is_directory = right_end < right.len;

        switch (displaySiblingOrder(
            left_is_directory,
            left[left_start..left_end],
            right_is_directory,
            right[right_start..right_end],
        )) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
        if (!left_is_directory) return false;
        left_start = left_end + 1;
        right_start = right_end + 1;
    }
}

/// Allocate one collision-free quoted token for an arbitrary raw Git path.
/// Framing quotes and backslash escapes are not part of the path identity.
/// Valid printable UTF-8 is retained; controls and invalid bytes remain
/// reversible through ASCII escapes.
pub fn quotedDisplayAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.append(allocator, '"');

    var index: usize = 0;
    while (index < raw.len) {
        const byte = raw[index];
        switch (byte) {
            '\\' => {
                try output.appendSlice(allocator, "\\\\");
                index += 1;
            },
            '"' => {
                try output.appendSlice(allocator, "\\\"");
                index += 1;
            },
            '\t' => {
                try output.appendSlice(allocator, "\\t");
                index += 1;
            },
            '\n' => {
                try output.appendSlice(allocator, "\\n");
                index += 1;
            },
            '\r' => {
                try output.appendSlice(allocator, "\\r");
                index += 1;
            },
            0x00...0x08, 0x0b...0x0c, 0x0e...0x1f, 0x7f => {
                try appendEscapedByte(allocator, &output, byte);
                index += 1;
            },
            else => {
                if (byte >= 0x20 and byte <= 0x7e) {
                    try output.append(allocator, byte);
                    index += 1;
                    continue;
                }
                const sequence_len = std.unicode.utf8ByteSequenceLength(byte) catch {
                    try appendEscapedByte(allocator, &output, byte);
                    index += 1;
                    continue;
                };
                const end = std.math.add(usize, index, @as(usize, sequence_len)) catch raw.len;
                if (end > raw.len or !std.unicode.utf8ValidateSlice(raw[index..end])) {
                    try appendEscapedByte(allocator, &output, byte);
                    index += 1;
                    continue;
                }
                const scalar = std.unicode.utf8Decode(raw[index..end]) catch unreachable;
                if (scalar >= 0x80 and scalar <= 0x9f) {
                    for (raw[index..end]) |sequence_byte| {
                        try appendEscapedByte(allocator, &output, sequence_byte);
                    }
                } else {
                    try output.appendSlice(allocator, raw[index..end]);
                }
                index = end;
            },
        }
    }
    try output.append(allocator, '"');
    return output.toOwnedSlice(allocator);
}

fn appendEscapedByte(allocator: std.mem.Allocator, output: *std.ArrayList(u8), byte: u8) !void {
    const hex = "0123456789ABCDEF";
    try output.appendSlice(allocator, &.{ '\\', 'x', hex[byte >> 4], hex[byte & 0x0f] });
}

fn decodeQuotedForTest(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    if (encoded.len < 2 or encoded[0] != '"' or encoded[encoded.len - 1] != '"') {
        return error.InvalidQuotedPath;
    }
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var index: usize = 1;
    while (index + 1 < encoded.len) {
        if (encoded[index] != '\\') {
            if (encoded[index] == '"') return error.InvalidQuotedPath;
            try output.append(allocator, encoded[index]);
            index += 1;
            continue;
        }
        if (index + 2 >= encoded.len) return error.InvalidQuotedPath;
        switch (encoded[index + 1]) {
            '\\' => try output.append(allocator, '\\'),
            '"' => try output.append(allocator, '"'),
            't' => try output.append(allocator, '\t'),
            'n' => try output.append(allocator, '\n'),
            'r' => try output.append(allocator, '\r'),
            'x' => {
                if (index + 4 >= encoded.len) return error.InvalidQuotedPath;
                const high = hexValue(encoded[index + 2]) orelse return error.InvalidQuotedPath;
                const low = hexValue(encoded[index + 3]) orelse return error.InvalidQuotedPath;
                try output.append(allocator, high * 16 + low);
                index += 4;
                continue;
            },
            else => return error.InvalidQuotedPath,
        }
        index += 2;
    }
    return output.toOwnedSlice(allocator);
}

fn hexValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

test "canonical repo path strips git side prefixes" {
    try std.testing.expectEqualStrings("src/main.zig", canonicalRepoPath("a/src/main.zig").?);
    try std.testing.expectEqualStrings("src/main.zig", canonicalRepoPath("b/src/main.zig").?);
    try std.testing.expectEqualStrings("src/main.zig", canonicalRepoPath("src/main.zig").?);
}

test "canonical repo path excludes dev null and empty paths" {
    try std.testing.expect(canonicalRepoPath("/dev/null") == null);
    try std.testing.expect(canonicalRepoPath("") == null);
}

test "strip git side prefix only removes exact side directories" {
    try std.testing.expectEqualStrings("a", stripGitSidePrefix("a"));
    try std.testing.expectEqualStrings("b", stripGitSidePrefix("b"));
    try std.testing.expectEqualStrings("ab/src/main.zig", stripGitSidePrefix("ab/src/main.zig"));
    try std.testing.expectEqualStrings("ba/src/main.zig", stripGitSidePrefix("ba/src/main.zig"));
    try std.testing.expectEqualStrings("src/main.zig", stripGitSidePrefix("a/src/main.zig"));
    try std.testing.expectEqualStrings("src/main.zig", stripGitSidePrefix("b/src/main.zig"));
}

test "quoted diff paths are not unquoted yet" {
    try std.testing.expectEqualStrings("\"a/src/main.zig\"", canonicalRepoPath("\"a/src/main.zig\"").?);
}

test "History preview path order matches directory-first file traversal" {
    var paths = [_][]const u8{
        "a.zig",
        "src/z.zig",
        "docs/readme.md",
        "src/lib/root.zig",
        "b.zig",
        "src/a.zig",
    };
    std.mem.sort([]const u8, &paths, {}, displayPathLessThan);
    const expected = [_][]const u8{
        "docs/readme.md",
        "src/lib/root.zig",
        "src/a.zig",
        "src/z.zig",
        "a.zig",
        "b.zig",
    };
    for (expected, paths) |want, actual| try std.testing.expectEqualStrings(want, actual);
}

test "History preview quoted path tokens round trip arbitrary Git bytes" {
    const cases = [_][]const u8{
        "plain path/界.txt",
        "literal -> arrow/old new",
        "quote\"and\\backslash",
        "tab\tline\nreturn\r",
        "controls\x00\x1f\x7f\xc2\x80",
        "invalid\xff\xc3x\x80",
    };
    for (cases) |raw| {
        const encoded = try quotedDisplayAlloc(std.testing.allocator, raw);
        defer std.testing.allocator.free(encoded);
        try std.testing.expect(encoded.len >= 2);
        try std.testing.expectEqual(@as(u8, '"'), encoded[0]);
        try std.testing.expectEqual(@as(u8, '"'), encoded[encoded.len - 1]);
        try std.testing.expect(std.mem.indexOfScalar(u8, encoded[1 .. encoded.len - 1], '\n') == null);
        const decoded = try decodeQuotedForTest(std.testing.allocator, encoded);
        defer std.testing.allocator.free(decoded);
        try std.testing.expectEqualSlices(u8, raw, decoded);
    }
}

test "History preview quoted tokens keep rename delimiter inside framing" {
    const left = try quotedDisplayAlloc(std.testing.allocator, "a -> b\"\\");
    defer std.testing.allocator.free(left);
    const right = try quotedDisplayAlloc(std.testing.allocator, "b -> c\t\xff");
    defer std.testing.allocator.free(right);
    try std.testing.expectEqualStrings("\"a -> b\\\"\\\\\"", left);
    try std.testing.expectEqualStrings("\"b -> c\\t\\xFF\"", right);
}
