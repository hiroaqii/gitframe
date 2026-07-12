const std = @import("std");

/// Content identity for one exact bounded byte sequence.
///
/// The value detects equal accepted content across reload domains. It does not
/// prove filesystem-object identity or that a concurrent read was a snapshot.
pub const Fingerprint = struct {
    byte_len: u64,
    digest: [32]u8,

    pub fn init(bytes: []const u8) Fingerprint {
        var digest: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(bytes, &digest, .{});
        return .{
            .byte_len = @intCast(bytes.len),
            .digest = digest,
        };
    }

    pub fn eql(lhs: Fingerprint, rhs: Fingerprint) bool {
        return lhs.byte_len == rhs.byte_len and std.mem.eql(u8, &lhs.digest, &rhs.digest);
    }
};

test "content fingerprint includes exact bytes and length" {
    const first = Fingerprint.init("abc");
    try std.testing.expect(first.eql(Fingerprint.init("abc")));
    try std.testing.expect(!first.eql(Fingerprint.init("abd")));
    try std.testing.expect(!first.eql(Fingerprint.init("abc\n")));
    try std.testing.expect(Fingerprint.init("").eql(Fingerprint.init("")));
}
