const std = @import("std");
const diff_parser = @import("diff_parser.zig");

pub const Stats = struct {
    added: usize = 0,
    removed: usize = 0,

    pub fn add(self: *Stats, other: Stats) void {
        self.added += other.added;
        self.removed += other.removed;
    }
};

pub const Status = enum {
    modified,
    added,
    deleted,
    renamed,
    binary,

    pub fn badge(self: Status) []const u8 {
        return switch (self) {
            .modified => "M",
            .added => "A",
            .deleted => "D",
            .renamed => "R",
            .binary => "B",
        };
    }
};

pub fn displayPath(file: diff_parser.FileDiff) []const u8 {
    if (file.new_path) |path| return stripGitPathPrefix(path);
    if (file.old_path) |path| return stripGitPathPrefix(path);
    return file.header;
}

pub fn status(file: diff_parser.FileDiff) Status {
    // Keep more specific metadata-driven states before path-shape fallback:
    // pure renames can have no parsed old/new path headers.
    if (file.is_binary) return .binary;
    if (hasRenameMetadata(file)) return .renamed;
    if (file.old_path == null and file.new_path != null) return .added;
    if (file.old_path != null and file.new_path == null) return .deleted;
    return .modified;
}

pub fn hasModeChange(file: diff_parser.FileDiff) bool {
    for (file.metadata) |line| {
        if (std.mem.startsWith(u8, line, "old mode ") or
            std.mem.startsWith(u8, line, "new mode ") or
            hasNonRegularFileMode(line, "new file mode ") or
            hasNonRegularFileMode(line, "deleted file mode "))
        {
            return true;
        }
    }
    return false;
}

pub fn stats(file: diff_parser.FileDiff) Stats {
    var result: Stats = .{};
    for (file.hunks) |hunk| {
        for (hunk.lines) |line| {
            switch (line.kind) {
                .added => result.added += 1,
                .removed => result.removed += 1,
                else => {},
            }
        }
    }
    return result;
}

fn hasRenameMetadata(file: diff_parser.FileDiff) bool {
    for (file.metadata) |line| {
        if (std.mem.startsWith(u8, line, "rename from ") or
            std.mem.startsWith(u8, line, "rename to "))
        {
            return true;
        }
    }
    return false;
}

fn hasNonRegularFileMode(line: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, line, prefix)) return false;
    const mode = line[prefix.len..];
    return !std.mem.eql(u8, mode, "100644");
}

pub fn stripGitPathPrefix(path: []const u8) []const u8 {
    if (path.len == 0) return path;
    if (isDevNull(path)) return path;
    if (startsWithGitSidePrefix(path)) return path[2..];
    return path;
}

fn startsWithGitSidePrefix(path: []const u8) bool {
    return (path.len >= 2 and (path[0] == 'a' or path[0] == 'b') and path[1] == '/');
}

fn isDevNull(path: []const u8) bool {
    return std.mem.eql(u8, path, "/dev/null");
}

test "stripGitPathPrefix keeps dev null" {
    try std.testing.expectEqualStrings("/dev/null", stripGitPathPrefix("/dev/null"));
}

test "stripGitPathPrefix removes git side prefix" {
    try std.testing.expectEqualStrings("src/main.zig", stripGitPathPrefix("a/src/main.zig"));
    try std.testing.expectEqualStrings("src/main.zig", stripGitPathPrefix("b/src/main.zig"));
}

test "status classifies common diff file states" {
    try std.testing.expectEqual(Status.modified, status(.{
        .header = "diff --git a/a b/a",
        .old_path = "a/a",
        .new_path = "b/a",
        .metadata = &.{},
        .hunks = &.{},
    }));
    try std.testing.expectEqual(Status.added, status(.{
        .header = "diff --git a/a b/a",
        .old_path = null,
        .new_path = "b/a",
        .metadata = &.{},
        .hunks = &.{},
    }));
    try std.testing.expectEqual(Status.deleted, status(.{
        .header = "diff --git a/a b/a",
        .old_path = "a/a",
        .new_path = null,
        .metadata = &.{},
        .hunks = &.{},
    }));
    try std.testing.expectEqual(Status.renamed, status(.{
        .header = "diff --git a/old b/new",
        .old_path = "a/old",
        .new_path = "b/new",
        .metadata = &.{ "similarity index 100%", "rename from old", "rename to new" },
        .hunks = &.{},
    }));
    try std.testing.expectEqual(Status.binary, status(.{
        .header = "diff --git a/image.png b/image.png",
        .old_path = "a/image.png",
        .new_path = "b/image.png",
        .metadata = &.{"Binary files a/image.png and b/image.png differ"},
        .hunks = &.{},
        .is_binary = true,
    }));
}

test "hasModeChange detects mode metadata" {
    try std.testing.expect(hasModeChange(.{
        .header = "diff --git a/a b/a",
        .old_path = "a/a",
        .new_path = "b/a",
        .metadata = &.{ "old mode 100644", "new mode 100755" },
        .hunks = &.{},
    }));
    try std.testing.expect(hasModeChange(.{
        .header = "diff --git a/a b/a",
        .old_path = null,
        .new_path = "b/a",
        .metadata = &.{"new file mode 100755"},
        .hunks = &.{},
    }));
    try std.testing.expect(!hasModeChange(.{
        .header = "diff --git a/a b/a",
        .old_path = "a/a",
        .new_path = "b/a",
        .metadata = &.{"index 1..2 100644"},
        .hunks = &.{},
    }));
    try std.testing.expect(!hasModeChange(.{
        .header = "diff --git a/a b/a",
        .old_path = null,
        .new_path = "b/a",
        .metadata = &.{"new file mode 100644"},
        .hunks = &.{},
    }));
}
