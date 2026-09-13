//! Pure Review Store path and repository-namespace staging-name vocabulary.
//! Resolution performs no filesystem operation and never creates authority.

const std = @import("std");
const committed_review = @import("../committed_review.zig");

pub const max_store_root_bytes: usize = 4095;

pub const PathError = error{InvalidStoreRoot};

/// Owned startup/helper snapshot of the configured/default Store root.
pub const Resolved = union(enum) {
    available: []u8,
    unavailable: Unavailable,

    pub const Unavailable = enum { no_state_home };

    pub fn deinit(self: *Resolved, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .available => |value| allocator.free(value),
            .unavailable => {},
        }
        self.* = .{ .unavailable = .no_state_home };
    }
};

/// Apply config > non-empty XDG_STATE_HOME > HOME without expanding input.
pub fn resolve(
    allocator: std.mem.Allocator,
    configured: ?[]const u8,
    xdg_state_home: ?[]const u8,
    home: ?[]const u8,
) (PathError || std.mem.Allocator.Error)!Resolved {
    if (configured) |value| {
        try validateAbsoluteCanonical(value);
        return .{ .available = try allocator.dupe(u8, value) };
    }
    if (nonEmpty(xdg_state_home)) |root| {
        return .{ .available = try joinDefault(allocator, root, "gitframe/ai-reviews") };
    }
    if (nonEmpty(home)) |root| {
        return .{ .available = try joinDefault(allocator, root, ".local/state/gitframe/ai-reviews") };
    }
    return .{ .unavailable = .no_state_home };
}

/// Runtime wrapper used identically by the future TUI startup and installed
/// helpers. Empty environment values are absent; no Store-specific override
/// is consulted.
pub fn resolveFromEnvironment(
    allocator: std.mem.Allocator,
    configured: ?[]const u8,
    environment: ?*const std.process.Environ.Map,
) (PathError || std.mem.Allocator.Error)!Resolved {
    const xdg = if (environment) |map| map.get("XDG_STATE_HOME") else null;
    const home = if (environment) |map| map.get("HOME") else null;
    return resolve(allocator, configured, xdg, home);
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const present = value orelse return null;
    return if (present.len == 0) null else present;
}

fn joinDefault(
    allocator: std.mem.Allocator,
    root: []const u8,
    suffix: []const u8,
) (PathError || std.mem.Allocator.Error)![]u8 {
    if (!std.mem.eql(u8, root, "/")) try validateAbsoluteCanonical(root);
    const joined = if (std.mem.eql(u8, root, "/"))
        try std.fmt.allocPrint(allocator, "/{s}", .{suffix})
    else
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, suffix });
    errdefer allocator.free(joined);
    try validateAbsoluteCanonical(joined);
    return joined;
}

/// One lossless canonical absolute POSIX spelling. `/` is never a Store root.
pub fn validateAbsoluteCanonical(value: []const u8) PathError!void {
    if (value.len == 0 or value.len > max_store_root_bytes or value[0] != '/' or
        value.len == 1 or value[value.len - 1] == '/' or
        std.mem.indexOfScalar(u8, value, 0) != null)
    {
        return error.InvalidStoreRoot;
    }
    var components = std.mem.splitScalar(u8, value[1..], '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, "..")) return error.InvalidStoreRoot;
    }
}

pub const NamespaceTempKind = enum { publish, location, draft, result };

/// Direct, full-ID key for one immutable Run location record.
pub const RunLocationName = struct {
    bytes: [41]u8,

    pub fn format(review_id: committed_review.ReviewId) RunLocationName {
        var result: RunLocationName = undefined;
        @memcpy(result.bytes[0..5], ".run-");
        const id = review_id.canonical();
        @memcpy(result.bytes[5..], &id);
        return result;
    }

    pub fn parse(raw: []const u8) error{InvalidRunLocationName}!committed_review.ReviewId {
        if (raw.len != 41 or !std.mem.startsWith(u8, raw, ".run-")) {
            return error.InvalidRunLocationName;
        }
        return committed_review.ReviewId.parse(raw[5..]) catch error.InvalidRunLocationName;
    }

    pub fn slice(self: *const RunLocationName) []const u8 {
        return &self.bytes;
    }
};

/// Exact repository-namespace sibling staging name shared by every later writer.
pub const NamespaceTempName = struct {
    kind: NamespaceTempKind,
    review_id: committed_review.ReviewId,
    token: [16]u8,

    pub const max_name_bytes: usize = 83;

    pub const Formatted = struct {
        bytes: [max_name_bytes]u8 = undefined,
        len: u8 = 0,

        pub fn slice(self: *const Formatted) []const u8 {
            return self.bytes[0..self.len];
        }
    };

    pub fn parse(name: []const u8) error{InvalidNamespaceTempName}!NamespaceTempName {
        const matched = prefixKind(name) orelse return error.InvalidNamespaceTempName;
        const rest = name[matched.prefix.len..];
        if (rest.len != 36 + 1 + 32 or rest[36] != '-') return error.InvalidNamespaceTempName;
        const review_id = committed_review.ReviewId.parse(rest[0..36]) catch
            return error.InvalidNamespaceTempName;
        var token: [16]u8 = undefined;
        for (0..token.len) |index| {
            const high = lowerHexValue(rest[37 + index * 2]) orelse
                return error.InvalidNamespaceTempName;
            const low = lowerHexValue(rest[38 + index * 2]) orelse
                return error.InvalidNamespaceTempName;
            token[index] = (high << 4) | low;
        }
        return .{ .kind = matched.kind, .review_id = review_id, .token = token };
    }

    pub fn format(self: NamespaceTempName) Formatted {
        const prefix = kindPrefix(self.kind);
        const id = self.review_id.canonical();
        var result: Formatted = .{};
        var cursor: usize = 0;
        @memcpy(result.bytes[cursor..][0..prefix.len], prefix);
        cursor += prefix.len;
        @memcpy(result.bytes[cursor..][0..id.len], &id);
        cursor += id.len;
        result.bytes[cursor] = '-';
        cursor += 1;
        for (self.token) |byte| {
            result.bytes[cursor] = lowerHex(byte >> 4);
            result.bytes[cursor + 1] = lowerHex(byte & 0x0f);
            cursor += 2;
        }
        result.len = @intCast(cursor);
        return result;
    }
};

const PrefixMatch = struct { prefix: []const u8, kind: NamespaceTempKind };

fn prefixKind(name: []const u8) ?PrefixMatch {
    inline for (.{
        PrefixMatch{ .prefix = ".tmp-publish-", .kind = .publish },
        PrefixMatch{ .prefix = ".tmp-location-", .kind = .location },
        PrefixMatch{ .prefix = ".tmp-draft-", .kind = .draft },
        PrefixMatch{ .prefix = ".tmp-result-", .kind = .result },
    }) |candidate| {
        if (std.mem.startsWith(u8, name, candidate.prefix)) return candidate;
    }
    return null;
}

fn kindPrefix(kind: NamespaceTempKind) []const u8 {
    return switch (kind) {
        .publish => ".tmp-publish-",
        .location => ".tmp-location-",
        .draft => ".tmp-draft-",
        .result => ".tmp-result-",
    };
}

fn lowerHexValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        else => null,
    };
}

fn lowerHex(value: u8) u8 {
    return if (value < 10) '0' + value else 'a' + value - 10;
}

test "review history backend path resolution is pure and precedence bounded" {
    const allocator = std.testing.allocator;
    var configured = try resolve(allocator, "/configured/store", "/xdg", "/home/test");
    defer configured.deinit(allocator);
    try std.testing.expectEqualStrings("/configured/store", configured.available);

    var xdg = try resolve(allocator, null, "/xdg", "/home/test");
    defer xdg.deinit(allocator);
    try std.testing.expectEqualStrings("/xdg/gitframe/ai-reviews", xdg.available);

    var fallback = try resolve(allocator, null, "", "/home/test");
    defer fallback.deinit(allocator);
    try std.testing.expectEqualStrings("/home/test/.local/state/gitframe/ai-reviews", fallback.available);

    var root_base = try resolve(allocator, null, "/", null);
    defer root_base.deinit(allocator);
    try std.testing.expectEqualStrings("/gitframe/ai-reviews", root_base.available);

    var missing = try resolve(allocator, null, null, null);
    defer missing.deinit(allocator);
    try std.testing.expectEqual(Resolved.Unavailable.no_state_home, missing.unavailable);
}

test "review history backend environment resolver has no private override" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("XDG_STATE_HOME", "/state");
    try environment.put("GITFRAME_AI_REVIEW_STORE_ROOT", "/not-authority");
    var resolved = try resolveFromEnvironment(std.testing.allocator, null, &environment);
    defer resolved.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/state/gitframe/ai-reviews", resolved.available);
    try std.testing.expectError(
        error.InvalidStoreRoot,
        resolveFromEnvironment(std.testing.allocator, "relative", &environment),
    );
}

test "review history backend canonical Store paths reject expansion and aliases" {
    const invalid = [_][]const u8{
        "", "/", "relative", "~/store", "$HOME/store", "/a/", "/a//b", "/a/./b", "/a/../b",
    };
    for (invalid) |value| try std.testing.expectError(error.InvalidStoreRoot, validateAbsoluteCanonical(value));
    try validateAbsoluteCanonical("/a/non-utf8-\xff");

    const exact = try std.testing.allocator.alloc(u8, max_store_root_bytes);
    defer std.testing.allocator.free(exact);
    @memset(exact, 'a');
    exact[0] = '/';
    try validateAbsoluteCanonical(exact);
    const too_long = try std.testing.allocator.alloc(u8, max_store_root_bytes + 1);
    defer std.testing.allocator.free(too_long);
    @memset(too_long, 'a');
    too_long[0] = '/';
    try std.testing.expectError(error.InvalidStoreRoot, validateAbsoluteCanonical(too_long));
}

test "review history backend NamespaceTempName has one exact shared grammar" {
    const review_id = try committed_review.ReviewId.parse("123e4567-e89b-42d3-a456-426614174000");
    const token = [_]u8{0xab} ** 16;
    inline for (.{ NamespaceTempKind.publish, .location, .draft, .result }) |kind| {
        const value: NamespaceTempName = .{ .kind = kind, .review_id = review_id, .token = token };
        const formatted = value.format();
        const parsed = try NamespaceTempName.parse(formatted.slice());
        try std.testing.expectEqual(kind, parsed.kind);
        try std.testing.expect(parsed.review_id.eql(review_id));
        try std.testing.expectEqualSlices(u8, &token, &parsed.token);
    }

    const invalid = [_][]const u8{
        ".tmp-publish-123e4567-e89b-42d3-a456-426614174000-ABABABABABABABABABABABABABABABAB",
        ".tmp-private-123e4567-e89b-42d3-a456-426614174000-abababababababababababababababab",
        ".tmp-draft-123e4567-e89b-42d3-a456-426614174000-abab",
    };
    for (invalid) |name| try std.testing.expectError(error.InvalidNamespaceTempName, NamespaceTempName.parse(name));
}

test "review run location key is exactly the complete canonical UUID" {
    const review_id = try committed_review.ReviewId.parse("123e4567-e89b-42d3-a456-426614174000");
    const name = RunLocationName.format(review_id);
    try std.testing.expectEqualStrings(".run-123e4567-e89b-42d3-a456-426614174000", name.slice());
    try std.testing.expect((try RunLocationName.parse(name.slice())).eql(review_id));
    try std.testing.expectError(error.InvalidRunLocationName, RunLocationName.parse("123e4567-e89b-42d3-a456-426614174000"));
}
