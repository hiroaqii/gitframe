const std = @import("std");
const diff_file = @import("../diff/file.zig");
const diff_parser = @import("../diff/parser.zig");

/// Session-scoped source of truth for files marked as reviewed.
///
/// `LoadedDiff.reviewed_files` is only the active-load bool cache. This store
/// survives reloads and repo switches, then materializes back into that cache
/// when a document becomes active.
pub const Store = struct {
    entries: std.StringHashMapUnmanaged(void) = .empty,

    pub fn deinit(self: *Store, allocator: std.mem.Allocator) void {
        var keys = self.entries.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
        self.entries.deinit(allocator);
        self.* = .{};
    }

    pub fn set(
        self: *Store,
        allocator: std.mem.Allocator,
        repo_root: ?[]const u8,
        file: diff_parser.FileDiff,
        reviewed: bool,
    ) !void {
        // Raw stdin/patch inputs have no stable repo identity. Keep their
        // reviewed state in the active bool cache only, not in this store.
        if (repo_root == null) return;
        const key = try keyAlloc(allocator, repo_root.?, file) orelse return;
        if (reviewed) {
            if (self.entries.contains(key)) {
                allocator.free(key);
                return;
            }
            errdefer allocator.free(key);
            try self.entries.put(allocator, key, {});
            return;
        }

        defer allocator.free(key);
        if (self.entries.fetchRemove(key)) |entry| {
            allocator.free(entry.key);
        }
    }

    pub fn containsFile(
        self: *const Store,
        allocator: std.mem.Allocator,
        repo_root: ?[]const u8,
        file: diff_parser.FileDiff,
    ) !bool {
        if (repo_root == null) return false;
        const key = try keyAlloc(allocator, repo_root.?, file) orelse return false;
        defer allocator.free(key);
        return self.entries.contains(key);
    }
};

fn keyAlloc(allocator: std.mem.Allocator, repo_root: []const u8, file: diff_parser.FileDiff) !?[]u8 {
    const path = diff_file.canonicalPathKey(file) orelse return null;
    return try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ repo_root, path });
}

test "store scopes reviewed keys by repository root" {
    const allocator = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(allocator);

    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/src/main.zig b/src/main.zig",
        .old_path = "src/main.zig",
        .new_path = "src/main.zig",
        .metadata = &.{},
        .hunks = &.{},
    };

    try store.set(allocator, "/repo/one", file, true);
    try std.testing.expect(try store.containsFile(allocator, "/repo/one", file));
    try std.testing.expect(!try store.containsFile(allocator, "/repo/two", file));
}

test "store ignores files without repository identity" {
    const allocator = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(allocator);

    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/src/main.zig b/src/main.zig",
        .old_path = "src/main.zig",
        .new_path = "src/main.zig",
        .metadata = &.{},
        .hunks = &.{},
    };

    try store.set(allocator, null, file, true);
    try std.testing.expect(!try store.containsFile(allocator, null, file));
}

test "store treats files without canonical key as not reviewable" {
    const allocator = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(allocator);

    const file: diff_parser.FileDiff = .{
        .header = "metadata only",
        .old_path = null,
        .new_path = null,
        .metadata = &.{},
        .hunks = &.{},
    };

    try store.set(allocator, "/repo", file, true);
    try std.testing.expect(!try store.containsFile(allocator, "/repo", file));
}
