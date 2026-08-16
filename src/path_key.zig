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
