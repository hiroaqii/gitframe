const std = @import("std");
const diff_file = @import("diff_file.zig");
const diff_parser = @import("diff_parser.zig");

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
        const key = try keyAlloc(allocator, repo_root, file);
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
        const key = try keyAlloc(allocator, repo_root, file);
        defer allocator.free(key);
        return self.entries.contains(key);
    }
};

fn keyAlloc(allocator: std.mem.Allocator, repo_root: ?[]const u8, file: diff_parser.FileDiff) ![]u8 {
    const path = diff_file.displayPath(file);
    return if (repo_root) |root|
        std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ root, path })
    else
        allocator.dupe(u8, path);
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
