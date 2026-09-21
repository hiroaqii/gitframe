//! App-independent owned data contract for History commit and range previews.
//!
//! Git process reads, async admission, rendering, and clipboard formatting are
//! later responsibilities. This module keeps raw identity bytes and exact
//! committed-diff bases independent of those consumers.

const std = @import("std");
const commit_diff = @import("commit_diff.zig");
const path_key = @import("../path_key.zig");

pub const Timestamp = struct {
    unix_seconds: i64,
    original_offset: [5]u8,
    offset_minutes: i16,

    pub fn init(unix_seconds: i64, original_offset: []const u8) error{InvalidTimezone}!Timestamp {
        if (original_offset.len != 5 or
            (original_offset[0] != '+' and original_offset[0] != '-')) return error.InvalidTimezone;
        for (original_offset[1..]) |byte| {
            if (!std.ascii.isDigit(byte)) return error.InvalidTimezone;
        }
        const hours: i16 = @intCast((original_offset[1] - '0') * 10 + original_offset[2] - '0');
        const minutes: i16 = @intCast((original_offset[3] - '0') * 10 + original_offset[4] - '0');
        if (hours > 23 or minutes > 59) return error.InvalidTimezone;
        const magnitude = hours * 60 + minutes;
        return .{
            .unix_seconds = unix_seconds,
            .original_offset = original_offset[0..5].*,
            .offset_minutes = if (original_offset[0] == '-') -magnitude else magnitude,
        };
    }
};

pub const Identity = struct {
    name: []const u8,
    email: []const u8,

    pub fn deinit(self: *Identity, allocator: std.mem.Allocator) void {
        if (self.name.len > 0) allocator.free(self.name);
        if (self.email.len > 0) allocator.free(self.email);
        self.* = undefined;
    }
};

pub const TypedRefs = struct {
    local_branches: []const []const u8,
    tags: []const []const u8,
    remote_branches: []const []const u8,

    pub fn deinit(self: *TypedRefs, allocator: std.mem.Allocator) void {
        freeOwnedStrings(allocator, self.local_branches);
        freeOwnedStrings(allocator, self.tags);
        freeOwnedStrings(allocator, self.remote_branches);
        self.* = undefined;
    }
};

pub const SingleSummary = struct {
    selected_oid: commit_diff.ObjectId,
    parent_count: u32,
    basis: commit_diff.Basis,
};

pub const RangeSummary = struct {
    count: usize,
    oldest_oid: commit_diff.ObjectId,
    newest_oid: commit_diff.ObjectId,
    basis: commit_diff.Basis,
};

pub const SelectionSummary = union(enum) {
    single: SingleSummary,
    range: RangeSummary,

    pub fn basis(self: SelectionSummary) commit_diff.Basis {
        return switch (self) {
            .single => |single| single.basis,
            .range => |range| range.basis,
        };
    }
};

pub const SingleDetail = struct {
    summary: SingleSummary,
    author: Identity,
    authored: Timestamp,
    committer: Identity,
    committed: Timestamp,
    refs: TypedRefs,
    message: []const u8,

    pub fn deinit(self: *SingleDetail, allocator: std.mem.Allocator) void {
        self.author.deinit(allocator);
        self.committer.deinit(allocator);
        self.refs.deinit(allocator);
        if (self.message.len > 0) allocator.free(self.message);
        self.* = undefined;
    }
};

pub const Detail = union(enum) {
    single: SingleDetail,
    range: RangeSummary,

    pub fn deinit(self: *Detail, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .single => |*single| single.deinit(allocator),
            .range => {},
        }
        self.* = undefined;
    }
};

pub const DetailTooLargeStage = enum {
    commit_object,
    metadata,
    message,
    identity,
    refs,
};

pub const UnavailableReason = enum {
    repository_format_drift,
    before_missing,
    before_wrong_kind,
    after_missing,
    after_wrong_kind,
};

pub const FailureReason = enum {
    git_command,
    malformed_output,
    allocation,
    task_start,
    runtime_abandoned,
};

pub const DetailResult = union(enum) {
    ready: Detail,
    too_large: DetailTooLargeStage,
    unavailable: UnavailableReason,
    failed: FailureReason,

    pub fn deinit(self: *DetailResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ready => |*detail| detail.deinit(allocator),
            .too_large, .unavailable, .failed => {},
        }
        self.* = undefined;
    }
};

pub const FileStatus = enum {
    modified,
    added,
    deleted,
    renamed,
    type_changed,

    pub fn badge(self: FileStatus) []const u8 {
        return switch (self) {
            .modified => "M",
            .added => "A",
            .deleted => "D",
            .renamed => "R",
            .type_changed => "T",
        };
    }
};

/// Single authority for a file change's status, path shape, and rename score.
/// Non-rename variants can own only one path; only the rename variant can own
/// a similarity score and old/new path pair.
pub const FileChangeKind = union(FileStatus) {
    modified: []const u8,
    added: []const u8,
    deleted: []const u8,
    renamed: Rename,
    type_changed: []const u8,

    pub const Rename = struct {
        similarity: u8,
        old: []const u8,
        new: []const u8,
    };

    pub fn status(self: FileChangeKind) FileStatus {
        return std.meta.activeTag(self);
    }

    pub fn badge(self: FileChangeKind) []const u8 {
        return self.status().badge();
    }

    pub fn canonicalPath(self: FileChangeKind) []const u8 {
        return switch (self) {
            .modified, .added, .deleted, .type_changed => |path| path,
            .renamed => |rename| rename.new,
        };
    }

    pub fn renameSimilarity(self: FileChangeKind) ?u8 {
        return switch (self) {
            .renamed => |rename| rename.similarity,
            else => null,
        };
    }

    pub fn deinit(self: *FileChangeKind, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .modified, .added, .deleted, .type_changed => |path| if (path.len > 0) allocator.free(path),
            .renamed => |rename| {
                if (rename.old.len > 0) allocator.free(rename.old);
                if (rename.new.len > 0) allocator.free(rename.new);
            },
        }
        self.* = undefined;
    }
};

pub const TextStats = struct {
    added: u64,
    removed: u64,
};

pub const StatsKind = union(enum) {
    text: TextStats,
    binary,
    mode_only,
    submodule,
};

pub const FileChange = struct {
    kind: FileChangeKind,
    old_mode: u32,
    new_mode: u32,
    old_oid: commit_diff.ObjectId,
    new_oid: commit_diff.ObjectId,
    stats: StatsKind,

    pub fn status(self: FileChange) FileStatus {
        return self.kind.status();
    }

    pub fn statusBadge(self: FileChange) []const u8 {
        return self.kind.badge();
    }

    pub fn canonicalPath(self: FileChange) []const u8 {
        return self.kind.canonicalPath();
    }

    pub fn renameSimilarity(self: FileChange) ?u8 {
        return self.kind.renameSimilarity();
    }

    pub fn deinit(self: *FileChange, allocator: std.mem.Allocator) void {
        self.kind.deinit(allocator);
        self.* = undefined;
    }
};

pub fn fileChangeLessThan(_: void, left: FileChange, right: FileChange) bool {
    return path_key.displayPathLessThan({}, left.canonicalPath(), right.canonicalPath());
}

pub const FilesTooLargeStage = enum {
    raw,
    numstat,
    file_list,
};

pub const FilesResult = union(enum) {
    ready: []FileChange,
    too_large: FilesTooLargeStage,
    unavailable: UnavailableReason,
    failed: FailureReason,

    pub fn deinit(self: *FilesResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ready => |changes| {
                for (changes) |*change| change.deinit(allocator);
                if (changes.len > 0) allocator.free(changes);
            },
            .too_large, .unavailable, .failed => {},
        }
        self.* = undefined;
    }
};

/// Generation-free owned value. Async request identity belongs to the task or
/// accepted wrapper, never to this cacheable payload.
pub const PreviewPayload = struct {
    detail: DetailResult,
    files: FilesResult,

    pub fn deinit(self: *PreviewPayload, allocator: std.mem.Allocator) void {
        self.detail.deinit(allocator);
        self.files.deinit(allocator);
        self.* = undefined;
    }
};

fn freeOwnedStrings(allocator: std.mem.Allocator, items: []const []const u8) void {
    for (items) |item| if (item.len > 0) allocator.free(item);
    if (items.len > 0) allocator.free(items);
}

fn testOid(text: []const u8) !commit_diff.ObjectId {
    return commit_diff.ObjectId.parse(.sha1, text);
}

fn testOwnedStrings(values: []const []const u8) ![]const []const u8 {
    const owned = try std.testing.allocator.alloc([]const u8, values.len);
    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(owned);
    }
    for (values, 0..) |value, index| {
        owned[index] = try std.testing.allocator.dupe(u8, value);
        initialized += 1;
    }
    return owned;
}

fn testIdentity(name: []const u8, email: []const u8) !Identity {
    const owned_name = try std.testing.allocator.dupe(u8, name);
    errdefer std.testing.allocator.free(owned_name);
    const owned_email = try std.testing.allocator.dupe(u8, email);
    return .{ .name = owned_name, .email = owned_email };
}

test "History preview owned model releases ready component payloads" {
    const before = try testOid("1111111111111111111111111111111111111111");
    const after = try testOid("2222222222222222222222222222222222222222");
    const summary: SingleSummary = .{
        .selected_oid = after,
        .parent_count = 1,
        .basis = .{ .object_format = .sha1, .before = .{ .commit = before }, .after = after },
    };

    var author = try testIdentity("Author", "author@example.invalid");
    errdefer author.deinit(std.testing.allocator);
    var committer = try testIdentity("Committer", "committer@example.invalid");
    errdefer committer.deinit(std.testing.allocator);
    var refs: TypedRefs = .{
        .local_branches = try testOwnedStrings(&.{"main"}),
        .tags = &.{},
        .remote_branches = &.{},
    };
    errdefer refs.deinit(std.testing.allocator);
    refs.tags = try testOwnedStrings(&.{"v1"});
    refs.remote_branches = try testOwnedStrings(&.{"origin/main"});
    const message = try std.testing.allocator.dupe(u8, "subject\n\nbody\n");
    errdefer std.testing.allocator.free(message);

    const changes = try std.testing.allocator.alloc(FileChange, 2);
    var initialized_changes: usize = 0;
    errdefer {
        for (changes[0..initialized_changes]) |*change| change.deinit(std.testing.allocator);
        std.testing.allocator.free(changes);
    }
    changes[0] = .{
        .kind = .{ .modified = try std.testing.allocator.dupe(u8, "src/main.zig") },
        .old_mode = 0o100644,
        .new_mode = 0o100644,
        .old_oid = before,
        .new_oid = after,
        .stats = .{ .text = .{ .added = 2, .removed = 1 } },
    };
    initialized_changes += 1;
    changes[1] = .{
        .kind = .{ .renamed = .{
            .similarity = 75,
            .old = try std.testing.allocator.dupe(u8, "old -> name"),
            .new = try std.testing.allocator.dupe(u8, "new\xffname"),
        } },
        .old_mode = 0o100644,
        .new_mode = 0o100644,
        .old_oid = before,
        .new_oid = after,
        .stats = .binary,
    };
    initialized_changes += 1;

    var payload: PreviewPayload = .{
        .detail = .{ .ready = .{ .single = .{
            .summary = summary,
            .author = author,
            .authored = try Timestamp.init(1, "+0900"),
            .committer = committer,
            .committed = try Timestamp.init(2, "-0230"),
            .refs = refs,
            .message = message,
        } } },
        .files = .{ .ready = changes },
    };
    payload.deinit(std.testing.allocator);
}

test "History preview terminals and range summaries own no hidden payload" {
    const before = try testOid("1111111111111111111111111111111111111111");
    const after = try testOid("2222222222222222222222222222222222222222");
    var payload: PreviewPayload = .{
        .detail = .{ .ready = .{ .range = .{
            .count = 2,
            .oldest_oid = before,
            .newest_oid = after,
            .basis = .{ .object_format = .sha1, .before = .empty_tree, .after = after },
        } } },
        .files = .{ .too_large = .file_list },
    };
    payload.deinit(std.testing.allocator);

    var failed: PreviewPayload = .{
        .detail = .{ .unavailable = .after_missing },
        .files = .{ .failed = .malformed_output },
    };
    failed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i16, 0), (try Timestamp.init(0, "-0000")).offset_minutes);
    try std.testing.expectError(error.InvalidTimezone, Timestamp.init(0, "UTC"));
    try std.testing.expectError(error.InvalidTimezone, Timestamp.init(0, "+1260"));
    try std.testing.expectError(error.InvalidTimezone, Timestamp.init(0, "+2400"));
}

test "History preview file changes sort by raw canonical path" {
    const oid = try testOid("1111111111111111111111111111111111111111");
    var changes = [_]FileChange{
        .{ .kind = .{ .modified = "a.zig" }, .old_mode = 0, .new_mode = 0, .old_oid = oid, .new_oid = oid, .stats = .mode_only },
        .{ .kind = .{ .renamed = .{ .similarity = 100, .old = "z-old", .new = "src/z.zig" } }, .old_mode = 0, .new_mode = 0, .old_oid = oid, .new_oid = oid, .stats = .binary },
        .{ .kind = .{ .added = "docs/readme.md" }, .old_mode = 0, .new_mode = 0, .old_oid = oid, .new_oid = oid, .stats = .{ .text = .{ .added = 1, .removed = 0 } } },
        .{ .kind = .{ .modified = "src/lib/root.zig" }, .old_mode = 0, .new_mode = 0, .old_oid = oid, .new_oid = oid, .stats = .submodule },
    };
    std.mem.sort(FileChange, &changes, {}, fileChangeLessThan);
    const expected = [_][]const u8{ "docs/readme.md", "src/lib/root.zig", "src/z.zig", "a.zig" };
    for (expected, changes) |want, change| {
        try std.testing.expectEqualStrings(want, change.canonicalPath());
    }
}

test "History preview file change kind derives every status path and cleanup" {
    const oid = try testOid("1111111111111111111111111111111111111111");
    var changes = [_]FileChange{
        .{ .kind = .{ .modified = try std.testing.allocator.dupe(u8, "modified") }, .old_mode = 0, .new_mode = 0, .old_oid = oid, .new_oid = oid, .stats = .mode_only },
        .{ .kind = .{ .added = try std.testing.allocator.dupe(u8, "added") }, .old_mode = 0, .new_mode = 0, .old_oid = oid, .new_oid = oid, .stats = .mode_only },
        .{ .kind = .{ .deleted = try std.testing.allocator.dupe(u8, "deleted") }, .old_mode = 0, .new_mode = 0, .old_oid = oid, .new_oid = oid, .stats = .mode_only },
        .{ .kind = .{ .renamed = .{
            .similarity = 87,
            .old = try std.testing.allocator.dupe(u8, "old"),
            .new = try std.testing.allocator.dupe(u8, "new"),
        } }, .old_mode = 0, .new_mode = 0, .old_oid = oid, .new_oid = oid, .stats = .mode_only },
        .{ .kind = .{ .type_changed = try std.testing.allocator.dupe(u8, "type-changed") }, .old_mode = 0, .new_mode = 0, .old_oid = oid, .new_oid = oid, .stats = .mode_only },
    };
    defer for (&changes) |*change| change.deinit(std.testing.allocator);

    const expected_statuses = [_]FileStatus{ .modified, .added, .deleted, .renamed, .type_changed };
    const expected_badges = [_][]const u8{ "M", "A", "D", "R", "T" };
    const expected_paths = [_][]const u8{ "modified", "added", "deleted", "new", "type-changed" };
    for (changes, expected_statuses, expected_badges, expected_paths) |change, status, badge, canonical_path| {
        try std.testing.expectEqual(status, change.status());
        try std.testing.expectEqualStrings(badge, change.statusBadge());
        try std.testing.expectEqualStrings(canonical_path, change.canonicalPath());
    }
    try std.testing.expect(changes[0].renameSimilarity() == null);
    try std.testing.expectEqual(@as(?u8, 87), changes[3].renameSimilarity());
    switch (changes[3].kind) {
        .renamed => |rename| {
            try std.testing.expectEqualStrings("old", rename.old);
            try std.testing.expectEqualStrings("new", rename.new);
        },
        else => return error.ExpectedRename,
    }
}
