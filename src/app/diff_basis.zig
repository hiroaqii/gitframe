//! Page-independent identity and ownership types for read-only committed diffs.
//!
//! Compare v1 constructs branch bases. The tagged `DiffBasis` is defined now
//! so later History work can add its lossless commit-detail payload without
//! changing consumers back to an untagged branch-only contract.

const std = @import("std");
const git_ref = @import("../git/ref.zig");

/// Git object id storage for SHA-1 (40 hex) and SHA-256 (64 hex) repositories.
pub const Oid = struct {
    bytes: [64]u8 = [_]u8{0} ** 64,
    len: u8 = 0,

    pub fn slice(self: *const Oid) []const u8 {
        std.debug.assert(self.len <= self.bytes.len);
        return self.bytes[0..self.len];
    }

    pub fn short(self: *const Oid) []const u8 {
        return self.slice()[0..@min(@as(usize, self.len), 7)];
    }

    pub fn eql(self: *const Oid, other: *const Oid) bool {
        return std.mem.eql(u8, self.slice(), other.slice());
    }
};

pub const BaseKind = git_ref.BranchKind;

/// User intent: which full ref should be resolved by the next Compare load.
pub const BaseTarget = struct {
    full_ref: []u8,
    display_name: []u8,
    kind: BaseKind,

    pub fn clone(self: BaseTarget, allocator: std.mem.Allocator) !BaseTarget {
        const full_ref = try allocator.dupe(u8, self.full_ref);
        errdefer allocator.free(full_ref);
        return .{
            .full_ref = full_ref,
            .display_name = try allocator.dupe(u8, self.display_name),
            .kind = self.kind,
        };
    }

    pub fn deinit(self: *BaseTarget, allocator: std.mem.Allocator) void {
        allocator.free(self.full_ref);
        allocator.free(self.display_name);
        self.* = undefined;
    }
};

/// One resolved base. Display text is deliberately separate from Git authority.
pub const BaseSelection = struct {
    full_ref: []u8,
    display_name: []u8,
    kind: BaseKind,
    oid: Oid,

    pub fn clone(self: BaseSelection, allocator: std.mem.Allocator) !BaseSelection {
        const full_ref = try allocator.dupe(u8, self.full_ref);
        errdefer allocator.free(full_ref);
        return .{
            .full_ref = full_ref,
            .display_name = try allocator.dupe(u8, self.display_name),
            .kind = self.kind,
            .oid = self.oid,
        };
    }

    pub fn deinit(self: *BaseSelection, allocator: std.mem.Allocator) void {
        allocator.free(self.full_ref);
        allocator.free(self.display_name);
        self.* = undefined;
    }
};

/// Accepted, atomically resolved header identity for one branch diff bundle.
pub const BranchDiffBasis = struct {
    base: BaseSelection,
    head_display: []u8,
    merge_base_oid: Oid,
    head_oid: Oid,
    ahead_count: usize,

    pub fn clone(self: BranchDiffBasis, allocator: std.mem.Allocator) !BranchDiffBasis {
        var base = try self.base.clone(allocator);
        errdefer base.deinit(allocator);
        return .{
            .base = base,
            .head_display = try allocator.dupe(u8, self.head_display),
            .merge_base_oid = self.merge_base_oid,
            .head_oid = self.head_oid,
            .ahead_count = self.ahead_count,
        };
    }

    pub fn deinit(self: *BranchDiffBasis, allocator: std.mem.Allocator) void {
        self.base.deinit(allocator);
        allocator.free(self.head_display);
        self.* = undefined;
    }
};

/// Reserved for a future lossless History payload with selected parent/root,
/// merge policy, and ordered parents. Compare never constructs this minimal
/// identity placeholder.
pub const CommitDiffBasis = struct {
    selected_commit_oid: Oid,
};

pub const DiffBasis = union(enum) {
    branch: BranchDiffBasis,
    commit: CommitDiffBasis,

    pub fn deinit(self: *DiffBasis, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .branch => |*branch| branch.deinit(allocator),
            .commit => {},
        }
        self.* = undefined;
    }
};

pub const BasisFailure = enum {
    missing_base_ref,
    no_merge_base,
    head_unresolved,
};

test "oid exposes full and seven-column short forms" {
    var oid: Oid = .{};
    const value = "0123456789abcdef0123456789abcdef01234567";
    @memcpy(oid.bytes[0..value.len], value);
    oid.len = value.len;

    try std.testing.expectEqualStrings(value, oid.slice());
    try std.testing.expectEqualStrings("0123456", oid.short());
}

test "branch basis clone owns every display and authority slice" {
    const allocator = std.testing.allocator;
    var original: BranchDiffBasis = .{
        .base = .{
            .full_ref = try allocator.dupe(u8, "refs/remotes/origin/main"),
            .display_name = try allocator.dupe(u8, "origin/main"),
            .kind = .remote_tracking,
            .oid = .{},
        },
        .head_display = try allocator.dupe(u8, "feature/compare"),
        .merge_base_oid = .{},
        .head_oid = .{},
        .ahead_count = 3,
    };
    defer original.deinit(allocator);

    var cloned = try original.clone(allocator);
    defer cloned.deinit(allocator);

    try std.testing.expectEqualStrings(original.base.full_ref, cloned.base.full_ref);
    try std.testing.expect(original.base.full_ref.ptr != cloned.base.full_ref.ptr);
    try std.testing.expectEqualStrings(original.base.display_name, cloned.base.display_name);
    try std.testing.expect(original.base.display_name.ptr != cloned.base.display_name.ptr);
    try std.testing.expectEqualStrings(original.head_display, cloned.head_display);
    try std.testing.expect(original.head_display.ptr != cloned.head_display.ptr);
}

test "diff basis retains a distinct future commit tag" {
    const branch: DiffBasis = .{ .branch = .{
        .base = .{ .full_ref = &.{}, .display_name = &.{}, .kind = .local, .oid = .{} },
        .head_display = &.{},
        .merge_base_oid = .{},
        .head_oid = .{},
        .ahead_count = 0,
    } };
    const commit: DiffBasis = .{ .commit = .{ .selected_commit_oid = .{} } };
    try std.testing.expect(branch == .branch);
    try std.testing.expect(commit == .commit);
}
