//! Nominal run/repository identities and exact-byte SHA-256 digests.
//!
//! Review, repository-instance, and Store repository IDs intentionally remain
//! distinct Zig types even though all use canonical UUIDv4 bytes.

const std = @import("std");

/// Canonical UUIDv4 admission failure for either nominal identity domain.
pub const IdentityError = error{InvalidUuid};
/// Canonical `sha256:<lowercase hex>` admission failure.
pub const DigestError = error{InvalidDigest};

/// Immutable identity of one review run; reruns receive a new value.
pub const ReviewId = struct {
    bytes: [16]u8,

    /// Admit only lowercase canonical RFC 4122 UUIDv4 text.
    pub fn parse(text: []const u8) IdentityError!ReviewId {
        return .{ .bytes = try parseUuidV4(text) };
    }

    /// Generate UUIDv4 bytes from caller-owned randomness.
    pub fn generate(random: std.Random) ReviewId {
        var value: ReviewId = undefined;
        random.bytes(&value.bytes);
        value.bytes[6] = (value.bytes[6] & 0x0f) | 0x40;
        value.bytes[8] = (value.bytes[8] & 0x3f) | 0x80;
        return value;
    }

    /// Return the fixed-width lowercase wire representation by value.
    pub fn canonical(self: ReviewId) [36]u8 {
        return formatUuid(self.bytes);
    }

    /// Compare the complete 128-bit nominal identity.
    pub fn eql(self: ReviewId, other: ReviewId) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }
};

/// Durable identity carried by one Git common directory.
pub const RepositoryInstanceId = struct {
    bytes: [16]u8,

    pub fn parse(text: []const u8) IdentityError!RepositoryInstanceId {
        return .{ .bytes = try parseUuidV4(text) };
    }

    pub fn generate(random: std.Random) RepositoryInstanceId {
        var value: RepositoryInstanceId = undefined;
        random.bytes(&value.bytes);
        value.bytes[6] = (value.bytes[6] & 0x0f) | 0x40;
        value.bytes[8] = (value.bytes[8] & 0x3f) | 0x80;
        return value;
    }

    pub fn canonical(self: RepositoryInstanceId) [36]u8 {
        return formatUuid(self.bytes);
    }

    pub fn eql(self: RepositoryInstanceId, other: RepositoryInstanceId) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }
};

/// Local Store namespace for one repository binding, nominally distinct from
/// `ReviewId` and never inferred from remote URL or serialized in a target.
pub const ReviewRepositoryId = struct {
    bytes: [16]u8,

    /// Admit only lowercase canonical RFC 4122 UUIDv4 text.
    pub fn parse(text: []const u8) IdentityError!ReviewRepositoryId {
        return .{ .bytes = try parseUuidV4(text) };
    }

    /// Generate an ID for the durable binding owner; lookup code never calls it.
    pub fn generate(random: std.Random) ReviewRepositoryId {
        var value: ReviewRepositoryId = undefined;
        random.bytes(&value.bytes);
        value.bytes[6] = (value.bytes[6] & 0x0f) | 0x40;
        value.bytes[8] = (value.bytes[8] & 0x3f) | 0x80;
        return value;
    }

    /// Return the fixed-width lowercase wire representation by value.
    pub fn canonical(self: ReviewRepositoryId) [36]u8 {
        return formatUuid(self.bytes);
    }

    /// Compare the complete 128-bit nominal identity.
    pub fn eql(self: ReviewRepositoryId, other: ReviewRepositoryId) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }
};

/// Owned SHA-256 value with an algorithm-qualified wire spelling.
pub const Sha256Digest = struct {
    bytes: [32]u8,

    /// Parse exactly `sha256:` plus 64 lowercase hexadecimal digits.
    pub fn parse(text: []const u8) DigestError!Sha256Digest {
        if (text.len != 71 or !std.mem.eql(u8, text[0..7], "sha256:")) return error.InvalidDigest;
        var value: Sha256Digest = undefined;
        for (0..32) |index| {
            const high = hexValue(text[7 + index * 2]) orelse return error.InvalidDigest;
            const low = hexValue(text[8 + index * 2]) orelse return error.InvalidDigest;
            value.bytes[index] = (high << 4) | low;
        }
        return value;
    }

    /// Hash the caller-selected exact byte preimage without normalization.
    pub fn hash(bytes: []const u8) Sha256Digest {
        var value: Sha256Digest = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &value.bytes, .{});
        return value;
    }

    /// Return the fixed-width algorithm-qualified representation by value.
    pub fn canonical(self: Sha256Digest) [71]u8 {
        var out: [71]u8 = undefined;
        @memcpy(out[0..7], "sha256:");
        for (self.bytes, 0..) |byte, index| {
            out[7 + index * 2] = hexLower(byte >> 4);
            out[8 + index * 2] = hexLower(byte & 0x0f);
        }
        return out;
    }

    /// Compare all digest bytes with timing-safe equality.
    pub fn eql(self: Sha256Digest, other: Sha256Digest) bool {
        return std.crypto.timing_safe.eql([32]u8, self.bytes, other.bytes);
    }
};

fn parseUuidV4(text: []const u8) IdentityError![16]u8 {
    if (text.len != 36) return error.InvalidUuid;
    if (text[8] != '-' or text[13] != '-' or text[18] != '-' or text[23] != '-') return error.InvalidUuid;

    var result: [16]u8 = undefined;
    var source_index: usize = 0;
    var result_index: usize = 0;
    while (result_index < result.len) : (result_index += 1) {
        if (source_index == 8 or source_index == 13 or source_index == 18 or source_index == 23) source_index += 1;
        const high = hexValue(text[source_index]) orelse return error.InvalidUuid;
        const low = hexValue(text[source_index + 1]) orelse return error.InvalidUuid;
        result[result_index] = (high << 4) | low;
        source_index += 2;
    }
    if ((result[6] >> 4) != 4 or (result[8] & 0xc0) != 0x80) return error.InvalidUuid;
    return result;
}

fn formatUuid(bytes: [16]u8) [36]u8 {
    var result: [36]u8 = undefined;
    var source_index: usize = 0;
    var result_index: usize = 0;
    while (source_index < bytes.len) : (source_index += 1) {
        if (result_index == 8 or result_index == 13 or result_index == 18 or result_index == 23) {
            result[result_index] = '-';
            result_index += 1;
        }
        result[result_index] = hexLower(bytes[source_index] >> 4);
        result[result_index + 1] = hexLower(bytes[source_index] & 0x0f);
        result_index += 2;
    }
    return result;
}

fn hexValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        else => null,
    };
}

fn hexLower(value: u8) u8 {
    return if (value < 10) '0' + value else 'a' + (value - 10);
}

test "review and repository IDs enforce distinct canonical UUIDv4 domains" {
    const text = "123e4567-e89b-42d3-a456-426614174000";
    const review = try ReviewId.parse(text);
    const instance = try RepositoryInstanceId.parse(text);
    const repository = try ReviewRepositoryId.parse(text);
    const review_text = review.canonical();
    const instance_text = instance.canonical();
    const repository_text = repository.canonical();
    try std.testing.expectEqualStrings(text, &review_text);
    try std.testing.expectEqualStrings(text, &instance_text);
    try std.testing.expectEqualStrings(text, &repository_text);
    try std.testing.expectError(error.InvalidUuid, ReviewId.parse("123E4567-e89b-42d3-a456-426614174000"));
    try std.testing.expectError(error.InvalidUuid, ReviewId.parse("123e4567-e89b-12d3-a456-426614174000"));
    try std.testing.expectError(error.InvalidUuid, ReviewId.parse("123e4567-e89b-42d3-7456-426614174000"));
}

test "UUID generators set version and variant without coalescing domains" {
    var prng = std.Random.DefaultPrng.init(7);
    const review = ReviewId.generate(prng.random());
    const instance = RepositoryInstanceId.generate(prng.random());
    const repository = ReviewRepositoryId.generate(prng.random());
    try std.testing.expect((review.bytes[6] >> 4) == 4);
    try std.testing.expect((review.bytes[8] & 0xc0) == 0x80);
    try std.testing.expect((instance.bytes[6] >> 4) == 4);
    try std.testing.expect((instance.bytes[8] & 0xc0) == 0x80);
    try std.testing.expect((repository.bytes[6] >> 4) == 4);
    try std.testing.expect((repository.bytes[8] & 0xc0) == 0x80);
}

test "sha256 digest binds exact bytes and has one lowercase spelling" {
    const digest = Sha256Digest.hash("findings\n");
    const text = digest.canonical();
    try std.testing.expectEqual(@as(usize, 71), text.len);
    const parsed = try Sha256Digest.parse(&text);
    try std.testing.expect(digest.eql(parsed));
    var uppercase = text;
    uppercase[7] = 'A';
    try std.testing.expectError(error.InvalidDigest, Sha256Digest.parse(&uppercase));
    try std.testing.expect(!digest.eql(Sha256Digest.hash("findings")));
}
