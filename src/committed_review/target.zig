const std = @import("std");

pub const ObjectFormat = enum {
    sha1,
    sha256,

    pub fn oidHexLength(self: ObjectFormat) usize {
        return switch (self) {
            .sha1 => 40,
            .sha256 => 64,
        };
    }
};

pub const SourceKind = enum {
    branch_range,
};

pub const ObjectId = struct {
    bytes: [64]u8 = [_]u8{0} ** 64,
    len: u8 = 0,

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

    pub fn slice(self: *const ObjectId) []const u8 {
        std.debug.assert(self.len <= self.bytes.len);
        return self.bytes[0..self.len];
    }

    pub fn short(self: *const ObjectId) []const u8 {
        return self.slice()[0..@min(@as(usize, self.len), 7)];
    }

    pub fn eql(self: *const ObjectId, other: *const ObjectId) bool {
        return std.mem.eql(u8, self.slice(), other.slice());
    }

    pub fn validFor(self: *const ObjectId, format: ObjectFormat) bool {
        if (self.len != format.oidHexLength()) return false;
        for (self.slice()) |byte| if (!isLowerHex(byte)) return false;
        return true;
    }
};

pub const CommittedReviewTarget = struct {
    object_format: ObjectFormat,
    source_kind: SourceKind,
    base_oid: ObjectId,
    head_oid: ObjectId,
    diff_base_oid: ObjectId,

    pub fn validate(self: *const CommittedReviewTarget) error{InvalidTarget}!void {
        if (!self.base_oid.validFor(self.object_format) or
            !self.head_oid.validFor(self.object_format) or
            !self.diff_base_oid.validFor(self.object_format)) return error.InvalidTarget;
    }

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
