//! Owned vocabulary for contextual navigation between application pages.
//!
//! Source pages derive borrowed targets from their accepted models. The shell
//! converts a target into `RepositoryIncoming` before mutating page activation;
//! after that fallible allocation, later slices can move the value into the
//! Repository page without retaining pointers into Review-owned arenas.

const std = @import("std");
const root_capability = @import("../repo/root_capability.zig");

pub const RepositoryUnavailableReason = enum {
    no_current_path,
    path_not_found,
    source_unavailable,
    request_failed,

    pub fn message(self: RepositoryUnavailableReason) []const u8 {
        return switch (self) {
            .no_current_path => "Review target has no current working-tree path",
            .path_not_found => "Review target is not available in Repository",
            .source_unavailable => "Review target source is unavailable",
            .request_failed => "Could not load Review target in Repository",
        };
    }
};

pub const BorrowedRepositoryLocation = struct {
    path: []const u8,
    /// One-based best-effort current-file line. This is a navigation hint, not
    /// a durable content anchor.
    line: ?u32 = null,
};

pub const BorrowedRepositoryUnavailable = struct {
    /// Diagnostic path only. It is not claimed to exist in the current tree.
    path: []const u8,
    reason: RepositoryUnavailableReason,
};

/// Allocation-free classification derived from accepted Review state.
pub const ReviewRepositoryTarget = union(enum) {
    no_context,
    location: BorrowedRepositoryLocation,
    unavailable: BorrowedRepositoryUnavailable,
};

/// Borrowed Repository -> Review request used only for synchronous exact
/// lookup. The path remains Repository-owned until the shell finishes the
/// transition; Review never retains this value for a later reload.
pub const ReviewLocationIntent = struct {
    repo_epoch: u64,
    root_identity: root_capability.Identity,
    path: []const u8,
};

pub const ReviewUnavailableReason = enum {
    source_unavailable,
    no_accepted_review,
    repository_mismatch,
    path_not_found,
    hidden_by_filters,

    pub fn message(self: ReviewUnavailableReason) []const u8 {
        return switch (self) {
            .source_unavailable => "Current Review source cannot link to Repository files",
            .no_accepted_review => "No accepted Review is available",
            .repository_mismatch => "Repository changed before Review navigation",
            .path_not_found => "Repository file is not part of the current Review",
            .hidden_by_filters => "Repository file is hidden by Review filters",
        };
    }
};

pub const RepositoryLocationIntent = struct {
    repo_epoch: u64,
    root_identity: root_capability.Identity,
    path: []u8,
    line: ?u32,

    pub fn deinit(self: *RepositoryLocationIntent, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const RepositoryUnavailable = struct {
    repo_epoch: u64,
    root_identity: root_capability.Identity,
    path: []u8,
    reason: RepositoryUnavailableReason,

    pub fn deinit(self: *RepositoryUnavailable, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

/// Move-only shell handoff value.
///
/// `initOwned` is the fallible prepare phase. Later page wiring must make
/// owner installation allocation-free and infallible; a post-activation
/// rollback is intentionally not part of this type's contract.
pub const RepositoryIncoming = union(enum) {
    no_context,
    location: RepositoryLocationIntent,
    unavailable: RepositoryUnavailable,

    pub fn initOwned(
        allocator: std.mem.Allocator,
        repo_epoch: u64,
        root_identity: root_capability.Identity,
        target: ReviewRepositoryTarget,
    ) !RepositoryIncoming {
        return switch (target) {
            .no_context => .no_context,
            .location => |location| .{ .location = .{
                .repo_epoch = repo_epoch,
                .root_identity = root_identity,
                .path = try allocator.dupe(u8, location.path),
                .line = location.line,
            } },
            .unavailable => |unavailable| .{ .unavailable = .{
                .repo_epoch = repo_epoch,
                .root_identity = root_identity,
                .path = try allocator.dupe(u8, unavailable.path),
                .reason = unavailable.reason,
            } },
        };
    }

    pub fn deinit(self: *RepositoryIncoming, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .no_context => {},
            .location => |*location| location.deinit(allocator),
            .unavailable => |*unavailable| unavailable.deinit(allocator),
        }
        self.* = undefined;
    }
};

test "RepositoryIncoming owns location path and identity" {
    const allocator = std.testing.allocator;
    var path = [_]u8{ 's', 'r', 'c', '/', 'a' };
    var incoming = try RepositoryIncoming.initOwned(
        allocator,
        7,
        .{ .device = 11, .inode = 13 },
        .{ .location = .{ .path = &path, .line = 42 } },
    );
    defer incoming.deinit(allocator);

    path[4] = 'b';
    try std.testing.expect(incoming == .location);
    try std.testing.expectEqualStrings("src/a", incoming.location.path);
    try std.testing.expectEqual(@as(u64, 7), incoming.location.repo_epoch);
    try std.testing.expect(incoming.location.root_identity.eql(.{ .device = 11, .inode = 13 }));
    try std.testing.expectEqual(@as(?u32, 42), incoming.location.line);
}

test "RepositoryIncoming owns invalid UTF-8 unavailable diagnostic path" {
    const allocator = std.testing.allocator;
    var path = [_]u8{ 'o', 'l', 'd', '/', 0xff };
    var incoming = try RepositoryIncoming.initOwned(
        allocator,
        3,
        .{ .device = 5, .inode = 8 },
        .{ .unavailable = .{ .path = &path, .reason = .no_current_path } },
    );
    defer incoming.deinit(allocator);

    path[0] = 'x';
    try std.testing.expect(incoming == .unavailable);
    try std.testing.expectEqualSlices(u8, &.{ 'o', 'l', 'd', '/', 0xff }, incoming.unavailable.path);
    try std.testing.expectEqual(RepositoryUnavailableReason.no_current_path, incoming.unavailable.reason);
}

test "RepositoryIncoming allocation failure leaves borrowed target untouched" {
    var path = [_]u8{ 'a', '.', 'z', 'i', 'g' };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, RepositoryIncoming.initOwned(
        failing.allocator(),
        1,
        .{ .device = 2, .inode = 3 },
        .{ .location = .{ .path = &path, .line = 1 } },
    ));
    try std.testing.expectEqualStrings("a.zig", &path);
}

test "RepositoryIncoming no context allocates nothing" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var incoming = try RepositoryIncoming.initOwned(
        failing.allocator(),
        1,
        .{ .device = 2, .inode = 3 },
        .no_context,
    );
    defer incoming.deinit(failing.allocator());
    try std.testing.expect(incoming == .no_context);
}

test "Repository unavailable diagnostics are closed static messages" {
    inline for (std.meta.tags(RepositoryUnavailableReason)) |reason| {
        try std.testing.expect(reason.message().len > 0);
    }
}

test "Review unavailable diagnostics are closed static messages" {
    inline for (std.meta.tags(ReviewUnavailableReason)) |reason| {
        try std.testing.expect(reason.message().len > 0);
    }
}
