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

pub fn displayPath(file: diff_parser.FileDiff) []const u8 {
    if (file.new_path) |path| return stripGitPathPrefix(path);
    if (file.old_path) |path| return stripGitPathPrefix(path);
    return file.header;
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
