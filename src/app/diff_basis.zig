//! Page-independent identity and ownership types for read-only committed diffs.
//!
//! Review v1 constructs branch bases. Future History source kinds are added to
//! the versioned committed-review contract when their semantics exist; this
//! module does not reserve a lossy placeholder authority.

const std = @import("std");
const committed_review = @import("../committed_review.zig");
const git_ref = @import("../git/ref.zig");

/// Git object id storage for SHA-1 (40 hex) and SHA-256 (64 hex) repositories.
pub const Oid = committed_review.ObjectId;

pub const BaseKind = git_ref.BranchKind;

/// User intent: which full ref should be resolved by the next Review load.
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

    pub fn clone(self: BaseSelection, allocator: std.mem.Allocator) !BaseSelection {
        const full_ref = try allocator.dupe(u8, self.full_ref);
        errdefer allocator.free(full_ref);
        return .{
            .full_ref = full_ref,
            .display_name = try allocator.dupe(u8, self.display_name),
            .kind = self.kind,
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
    target: committed_review.CommittedReviewTarget,
    ahead_count: usize,

    pub fn clone(self: BranchDiffBasis, allocator: std.mem.Allocator) !BranchDiffBasis {
        var base = try self.base.clone(allocator);
        errdefer base.deinit(allocator);
        return .{
            .base = base,
            .head_display = try allocator.dupe(u8, self.head_display),
            .target = self.target,
            .ahead_count = self.ahead_count,
        };
    }

    pub fn deinit(self: *BranchDiffBasis, allocator: std.mem.Allocator) void {
        self.base.deinit(allocator);
        allocator.free(self.head_display);
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
        },
        .head_display = try allocator.dupe(u8, "feature/compare"),
        .target = .{
            .object_format = .sha1,
            .source_kind = .branch_range,
            .base_oid = .{},
            .head_oid = .{},
            .diff_base_oid = .{},
        },
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
