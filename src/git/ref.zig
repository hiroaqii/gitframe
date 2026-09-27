//! Page-independent Git reference vocabulary shared by loaders and consumers.

const std = @import("std");

pub const BranchKind = enum {
    local,
    remote_tracking,
};

/// Exact local branch name, independent of Git's ambiguous short display name.
pub fn localBranchName(full_ref: []const u8) ?[]const u8 {
    const prefix = "refs/heads/";
    if (!std.mem.startsWith(u8, full_ref, prefix) or full_ref.len == prefix.len) return null;
    return full_ref[prefix.len..];
}
