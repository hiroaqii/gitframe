const std = @import("std");
const path_key = @import("../path_key.zig");
const diff_parser = @import("parser.zig");

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

/// Canonical key for cross-model state such as reviewed files.
///
/// New-side paths win for normal/rename/copy diffs. Deleted files fall back to
/// the old path. Metadata-only renames use `rename to`/`copy to` when no path
/// headers are present.
pub fn canonicalPathKey(file: diff_parser.FileDiff) ?[]const u8 {
    if (currentPathKey(file)) |key| return key;
    if (file.old_path) |path| return path_key.canonicalRepoPath(path);
    return null;
}

/// Current-side repository path only.
///
/// Unlike `canonicalPathKey`, this never falls back to the old side of a
/// deletion. Cross-page Repository navigation uses this distinction to avoid
/// presenting a deleted path as a current working-tree destination.
pub fn currentPathKey(file: diff_parser.FileDiff) ?[]const u8 {
    if (file.new_path) |path| {
        if (path_key.canonicalRepoPath(path)) |key| return key;
    }
    if (metadataPath(file, "rename to ")) |path| return path_key.canonicalRepoPath(path);
    if (metadataPath(file, "copy to ")) |path| return path_key.canonicalRepoPath(path);
    return null;
}

pub fn editorPath(file: diff_parser.FileDiff) ?[]const u8 {
    const path = file.new_path orelse return null;
    if (path_key.isDevNull(path)) return null;
    return stripGitPathPrefix(path);
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
    if (path_key.isDevNull(path)) return path;
    return path_key.stripGitSidePrefix(path);
}

fn metadataPath(file: diff_parser.FileDiff, prefix: []const u8) ?[]const u8 {
    for (file.metadata) |line| {
        if (std.mem.startsWith(u8, line, prefix)) return line[prefix.len..];
    }
    return null;
}

test "stripGitPathPrefix keeps dev null" {
    try std.testing.expectEqualStrings("/dev/null", stripGitPathPrefix("/dev/null"));
}

test "stripGitPathPrefix removes git side prefix" {
    try std.testing.expectEqualStrings("src/main.zig", stripGitPathPrefix("a/src/main.zig"));
    try std.testing.expectEqualStrings("src/main.zig", stripGitPathPrefix("b/src/main.zig"));
}

test "editorPath opens the new side only" {
    try std.testing.expectEqualStrings("src/main.zig", editorPath(.{
        .header = "diff --git a/src/main.zig b/src/main.zig",
        .old_path = "a/src/main.zig",
        .new_path = "b/src/main.zig",
        .metadata = &.{},
        .hunks = &.{},
    }).?);
    try std.testing.expect(editorPath(.{
        .header = "diff --git a/src/main.zig b/src/main.zig",
        .old_path = "a/src/main.zig",
        .new_path = null,
        .metadata = &.{},
        .hunks = &.{},
    }) == null);
    try std.testing.expect(editorPath(.{
        .header = "diff --git a/src/main.zig b/src/main.zig",
        .old_path = "a/src/main.zig",
        .new_path = "/dev/null",
        .metadata = &.{},
        .hunks = &.{},
    }) == null);
}

test "canonicalPathKey prefers new path and normalizes deleted paths" {
    try std.testing.expectEqualStrings("src/new.zig", canonicalPathKey(.{
        .header = "diff --git a/src/old.zig b/src/new.zig",
        .old_path = "a/src/old.zig",
        .new_path = "b/src/new.zig",
        .metadata = &.{ "rename from src/old.zig", "rename to src/new.zig" },
        .hunks = &.{},
    }).?);
    try std.testing.expectEqualStrings("src/deleted.zig", canonicalPathKey(.{
        .header = "diff --git a/src/deleted.zig b/src/deleted.zig",
        .old_path = "a/src/deleted.zig",
        .new_path = null,
        .metadata = &.{},
        .hunks = &.{},
    }).?);
    try std.testing.expect(canonicalPathKey(.{
        .header = "diff --git a/missing b/missing",
        .old_path = null,
        .new_path = "/dev/null",
        .metadata = &.{},
        .hunks = &.{},
    }) == null);
}

test "canonicalPathKey uses metadata-only rename target" {
    try std.testing.expectEqualStrings("src/new.zig", canonicalPathKey(.{
        .header = "diff --git a/src/old.zig b/src/new.zig",
        .old_path = null,
        .new_path = null,
        .metadata = &.{ "rename from src/old.zig", "rename to src/new.zig" },
        .hunks = &.{},
    }).?);
}

test "currentPathKey never falls back to deleted old side" {
    try std.testing.expect(currentPathKey(.{
        .header = "diff --git a/src/deleted.zig b/src/deleted.zig",
        .old_path = "a/src/deleted.zig",
        .new_path = "/dev/null",
        .metadata = &.{"deleted file mode 100644"},
        .hunks = &.{},
    }) == null);
    try std.testing.expectEqualStrings("src/deleted.zig", canonicalPathKey(.{
        .header = "diff --git a/src/deleted.zig b/src/deleted.zig",
        .old_path = "a/src/deleted.zig",
        .new_path = "/dev/null",
        .metadata = &.{"deleted file mode 100644"},
        .hunks = &.{},
    }).?);
}

test "currentPathKey accepts new and metadata-only rename paths" {
    try std.testing.expectEqualStrings("src/current.zig", currentPathKey(.{
        .header = "diff --git a/src/old.zig b/src/current.zig",
        .old_path = "a/src/old.zig",
        .new_path = "b/src/current.zig",
        .metadata = &.{},
        .hunks = &.{},
    }).?);
    try std.testing.expectEqualStrings("src/renamed.zig", currentPathKey(.{
        .header = "diff --git a/src/old.zig b/src/renamed.zig",
        .old_path = null,
        .new_path = null,
        .metadata = &.{ "rename from src/old.zig", "rename to src/renamed.zig" },
        .hunks = &.{},
    }).?);
}

test "displayPath keeps non git-side prefixes" {
    try std.testing.expectEqualStrings("src/main.zig", displayPath(.{
        .header = "diff --git src/main.zig src/main.zig",
        .old_path = "src/main.zig",
        .new_path = "src/main.zig",
        .metadata = &.{},
        .hunks = &.{},
    }));
    try std.testing.expectEqualStrings("new/one.txt", displayPath(.{
        .header = "--- old/one.txt",
        .old_path = "old/one.txt",
        .new_path = "new/one.txt",
        .metadata = &.{},
        .hunks = &.{},
    }));
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
