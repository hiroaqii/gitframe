//! Portable location authority within exact committed blob bytes.
//!
//! Anchors identify content independently of diff hunks, patch positions,
//! rendered rows, display paths, and provider-specific inline placement.

const std = @import("std");
const identity = @import("identity.zig");

/// Chooses the target tree: `before` is `diff_base_oid`; `after` is `head_oid`.
pub const AnchorSide = enum {
    before,
    after,
};

/// Content-bound source location suitable for durable findings and results.
/// All slices borrow their containing parsed artifact owner.
pub const CodeAnchor = struct {
    /// Lossless repository-relative Git path bytes; the only path authority.
    path_bytes: []const u8,
    /// Optional safe UTF-8 label for humans; never used to locate or retarget.
    display_path: ?[]const u8 = null,
    side: AnchorSide,
    /// First selected committed line, using a 1-based inclusive coordinate.
    start_line: u32,
    /// Last selected committed line, also 1-based and inclusive.
    end_line: u32,
    /// SHA-256 of the exact selected blob-byte range, including original line
    /// endings and a final LF when that LF belongs to the selected range.
    content_digest: identity.Sha256Digest,
    /// Optional producer context for display; it does not authorize placement.
    quoted_text: ?[]const u8 = null,

    /// Compare every durable authority and optional presentation field.
    pub fn eql(self: CodeAnchor, other: CodeAnchor) bool {
        return std.mem.eql(u8, self.path_bytes, other.path_bytes) and
            optionalTextEql(self.display_path, other.display_path) and
            self.side == other.side and
            self.start_line == other.start_line and
            self.end_line == other.end_line and
            self.content_digest.eql(other.content_digest) and
            optionalTextEql(self.quoted_text, other.quoted_text);
    }
};

fn optionalTextEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

test "anchor equality keeps raw path and committed range authority" {
    const anchor: CodeAnchor = .{
        .path_bytes = "src/main.zig",
        .side = .after,
        .start_line = 2,
        .end_line = 3,
        .content_digest = identity.Sha256Digest.hash("two\nthree\n"),
    };
    var changed = anchor;
    changed.end_line = 4;
    try std.testing.expect(anchor.eql(anchor));
    try std.testing.expect(!anchor.eql(changed));
}
