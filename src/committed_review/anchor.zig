const std = @import("std");
const identity = @import("identity.zig");

pub const AnchorSide = enum {
    before,
    after,
};

pub const CodeAnchor = struct {
    path_bytes: []const u8,
    display_path: ?[]const u8 = null,
    side: AnchorSide,
    start_line: u32,
    end_line: u32,
    content_digest: identity.Sha256Digest,
    quoted_text: ?[]const u8 = null,

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
