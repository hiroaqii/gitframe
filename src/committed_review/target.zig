//! Portable identity of the committed Git revision pair under review.
//!
//! These values describe authority, not a materialized patch or a display
//! selection. They contain no repository, ref, worktree, or process identity.

const std = @import("std");

/// Object-id width used by every OID in one target.
pub const ObjectFormat = enum {
    sha1,
    sha256,

    /// Exact lowercase hexadecimal width for this Git object format.
    pub fn oidHexLength(self: ObjectFormat) usize {
        return switch (self) {
            .sha1 => 40,
            .sha256 => 64,
        };
    }
};

/// Versioned origin semantics for a target. `branch_range` means an explicit
/// base and head resolved to commits plus their exact-one best merge base.
pub const SourceKind = enum {
    branch_range,
};

/// Inline-owned canonical lowercase hexadecimal Git object ID.
pub const ObjectId = struct {
    /// Fixed-capacity storage; only `bytes[0..len]` is initialized authority.
    bytes: [64]u8 = [_]u8{0} ** 64,
    /// Number of authoritative hexadecimal bytes, fixed by `ObjectFormat`.
    len: u8 = 0,

    /// Parse one full OID; abbreviations are never portable target authority.
    pub fn parse(format: ObjectFormat, text: []const u8) error{InvalidObjectId}!ObjectId {
        if (text.len != format.oidHexLength()) return error.InvalidObjectId;
        var result: ObjectId = .{};
        for (text, 0..) |byte, index| {
            if (!isLowerHex(byte)) return error.InvalidObjectId;
            result.bytes[index] = byte;
        }
        result.len = @intCast(text.len);
        return result;
    }

    /// Borrow the initialized canonical OID bytes from this value.
    pub fn slice(self: *const ObjectId) []const u8 {
        std.debug.assert(self.len <= self.bytes.len);
        return self.bytes[0..self.len];
    }

    /// Borrow at most seven leading bytes for non-authoritative display only.
    pub fn short(self: *const ObjectId) []const u8 {
        return self.slice()[0..@min(@as(usize, self.len), 7)];
    }

    /// Compare the complete initialized hexadecimal representation.
    pub fn eql(self: *const ObjectId, other: *const ObjectId) bool {
        return std.mem.eql(u8, self.slice(), other.slice());
    }

    /// Check both canonical spelling and the exact width of `format`.
    pub fn validFor(self: *const ObjectId, format: ObjectFormat) bool {
        if (self.len != format.oidHexLength()) return false;
        for (self.slice()) |byte| if (!isLowerHex(byte)) return false;
        return true;
    }
};

/// Complete portable authority for one committed branch-range review.
/// Equality is exactly these five fields; patch bytes, labels, ahead counts,
/// repository identity, and provider state are deliberately absent.
pub const CommittedReviewTarget = struct {
    object_format: ObjectFormat,
    /// Determines how the OIDs were pinned, not which UI mode displays them.
    source_kind: SourceKind,
    /// Commit selected by caller base policy before merge-base calculation.
    base_oid: ObjectId,
    /// Exact reviewed commit; committed attributes are read from this tree.
    head_oid: ObjectId,
    /// Exact-one best merge base used as the left endpoint of the projection.
    /// It may differ from `base_oid` when the selected base is not an ancestor.
    diff_base_oid: ObjectId,

    /// Enforce format-width and lowercase invariants for all three OIDs.
    pub fn validate(self: *const CommittedReviewTarget) error{InvalidTarget}!void {
        if (!self.base_oid.validFor(self.object_format) or
            !self.head_oid.validFor(self.object_format) or
            !self.diff_base_oid.validFor(self.object_format)) return error.InvalidTarget;
    }

    /// Structural portable equality; no local projection data participates.
    pub fn eql(self: *const CommittedReviewTarget, other: *const CommittedReviewTarget) bool {
        return self.object_format == other.object_format and
            self.source_kind == other.source_kind and
            self.base_oid.eql(&other.base_oid) and
            self.head_oid.eql(&other.head_oid) and
            self.diff_base_oid.eql(&other.diff_base_oid);
    }
};

fn isLowerHex(byte: u8) bool {
    return switch (byte) {
        '0'...'9', 'a'...'f' => true,
        else => false,
    };
}

test "object IDs enforce object format width and lowercase wire spelling" {
    const sha1 = try ObjectId.parse(.sha1, "0123456789abcdef0123456789abcdef01234567");
    try std.testing.expectEqualStrings("0123456", sha1.short());
    try std.testing.expectError(error.InvalidObjectId, ObjectId.parse(.sha1, "0123456789ABCDEF0123456789abcdef01234567"));
    try std.testing.expectError(error.InvalidObjectId, ObjectId.parse(.sha256, "0123456789abcdef0123456789abcdef01234567"));
}

test "target equality is exactly its five portable fields" {
    const oid = try ObjectId.parse(.sha1, "0123456789abcdef0123456789abcdef01234567");
    const target: CommittedReviewTarget = .{
        .object_format = .sha1,
        .source_kind = .branch_range,
        .base_oid = oid,
        .head_oid = oid,
        .diff_base_oid = oid,
    };
    try target.validate();
    try std.testing.expect(target.eql(&target));
}
