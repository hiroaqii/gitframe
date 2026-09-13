//! Bounded, allocation-free names persisted by Review Store schema version 1.

const std = @import("std");
const committed_review = @import("../committed_review.zig");

pub const max_repository_display_bytes: usize = 246;
pub const max_component_bytes: usize = 255;

pub const RepositoryNameError = error{InvalidRepositoryName};

pub const RepositoryDisplayName = struct {
    bytes: [max_repository_display_bytes]u8 = undefined,
    len: u8,

    /// Build the creation-time display name from Git's main-worktree basename.
    /// Only trailing ASCII hyphens are removed.
    pub fn fromMainWorktreeBasename(raw: []const u8) RepositoryNameError!RepositoryDisplayName {
        if (!std.unicode.utf8ValidateSlice(raw)) return error.InvalidRepositoryName;
        if (std.mem.indexOfScalar(u8, raw, '/') != null) return error.InvalidRepositoryName;
        for (raw) |byte| if (byte <= 0x1f or byte == 0x7f) return error.InvalidRepositoryName;

        var end = raw.len;
        while (end > 0 and raw[end - 1] == '-') end -= 1;
        return fromStored(raw[0..end]);
    }

    /// Admit the exact persisted spelling. A stored trailing hyphen is not
    /// canonical and is rejected instead of normalized.
    pub fn fromStored(raw: []const u8) RepositoryNameError!RepositoryDisplayName {
        if (raw.len == 0 or raw.len > max_repository_display_bytes) return error.InvalidRepositoryName;
        if (!std.unicode.utf8ValidateSlice(raw)) return error.InvalidRepositoryName;
        if (std.mem.indexOfScalar(u8, raw, '/') != null) return error.InvalidRepositoryName;
        for (raw) |byte| if (byte <= 0x1f or byte == 0x7f) return error.InvalidRepositoryName;
        if (raw[raw.len - 1] == '-' or
            std.mem.eql(u8, raw, ".") or
            std.mem.eql(u8, raw, "..")) return error.InvalidRepositoryName;

        var result: RepositoryDisplayName = .{ .len = @intCast(raw.len) };
        @memcpy(result.bytes[0..raw.len], raw);
        return result;
    }

    pub fn slice(self: *const RepositoryDisplayName) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(self: *const RepositoryDisplayName, other: *const RepositoryDisplayName) bool {
        return std.mem.eql(u8, self.slice(), other.slice());
    }
};

pub const RepositoryDirectoryName = struct {
    bytes: [max_component_bytes]u8 = undefined,
    len: u8,

    pub fn format(
        display: *const RepositoryDisplayName,
        repository_id: committed_review.ReviewRepositoryId,
    ) RepositoryDirectoryName {
        var result: RepositoryDirectoryName = .{ .len = @intCast(display.len + 9) };
        @memcpy(result.bytes[0..display.len], display.slice());
        result.bytes[display.len] = '-';
        const canonical = repository_id.canonical();
        @memcpy(result.bytes[display.len + 1 ..][0..8], canonical[0..8]);
        return result;
    }

    pub fn fromStored(
        raw: []const u8,
        display: *const RepositoryDisplayName,
        repository_id: committed_review.ReviewRepositoryId,
    ) RepositoryNameError!RepositoryDirectoryName {
        const expected = format(display, repository_id);
        if (!std.mem.eql(u8, raw, expected.slice())) return error.InvalidRepositoryName;
        return expected;
    }

    pub fn slice(self: *const RepositoryDirectoryName) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(self: *const RepositoryDirectoryName, other: *const RepositoryDirectoryName) bool {
        return std.mem.eql(u8, self.slice(), other.slice());
    }
};

test "review repository name trims only trailing hyphens and keeps UTF-8 case" {
    const display = try RepositoryDisplayName.fromMainWorktreeBasename("GitFrame-枝---");
    try std.testing.expectEqualStrings("GitFrame-枝", display.slice());
    const repository_id = try committed_review.ReviewRepositoryId.parse("123e4567-e89b-42d3-a456-426614174000");
    const directory = RepositoryDirectoryName.format(&display, repository_id);
    try std.testing.expectEqualStrings("GitFrame-枝-123e4567", directory.slice());
    const parsed = try RepositoryDirectoryName.fromStored(directory.slice(), &display, repository_id);
    try std.testing.expect(directory.eql(&parsed));
}

test "review repository name rejects malformed and noncanonical values without repair" {
    const invalid = [_][]const u8{ "", "-", "---", ".", "..", "repo/name", "repo\n", "repo\x7f", "bad\xff" };
    for (invalid) |value| {
        try std.testing.expectError(error.InvalidRepositoryName, RepositoryDisplayName.fromMainWorktreeBasename(value));
    }
    try std.testing.expectError(error.InvalidRepositoryName, RepositoryDisplayName.fromStored("repo-"));
}

test "review repository name enforces exact 246 and 255 byte boundaries" {
    var maximum = [_]u8{'a'} ** max_repository_display_bytes;
    const display = try RepositoryDisplayName.fromMainWorktreeBasename(&maximum);
    const repository_id = try committed_review.ReviewRepositoryId.parse("123e4567-e89b-42d3-a456-426614174000");
    const directory = RepositoryDirectoryName.format(&display, repository_id);
    try std.testing.expectEqual(max_component_bytes, directory.slice().len);

    var oversized = [_]u8{'a'} ** (max_repository_display_bytes + 1);
    try std.testing.expectError(error.InvalidRepositoryName, RepositoryDisplayName.fromMainWorktreeBasename(&oversized));
}
