//! Shared ordering and presentation for branch-tip commit times.

const std = @import("std");
const git_refs = @import("../git/refs.zig");
const local_time = @import("../local_time.zig");

pub const Relative = struct {
    bytes: [24]u8 = undefined,
    len: u8 = 0,

    pub fn text(self: *const Relative) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// Samples the real clock as a floored Unix second. An unavailable/zero
/// resolution clock and values outside the page's i64 vocabulary fail closed.
pub fn sampleUnixSeconds(io: std.Io) ?i64 {
    const resolution = std.Io.Clock.real.resolution(io) catch return null;
    if (resolution.nanoseconds == 0) return null;
    const timestamp = std.Io.Clock.real.now(io);
    const seconds = @divFloor(timestamp.nanoseconds, std.time.ns_per_s);
    return std.math.cast(i64, seconds);
}

/// Known timestamps sort newest first. Unknown timestamps follow every known
/// value, and full-ref bytes provide the deterministic tie-break in both cases.
pub fn sortBranches(branches: []git_refs.BranchListItem) void {
    std.mem.sort(git_refs.BranchListItem, branches, {}, lessThan);
}

fn lessThan(_: void, lhs: git_refs.BranchListItem, rhs: git_refs.BranchListItem) bool {
    if (lhs.tip_committer_unix) |left| {
        if (rhs.tip_committer_unix) |right| {
            if (left != right) return left > right;
        } else return true;
    } else if (rhs.tip_committer_unix != null) return false;
    return std.mem.order(u8, lhs.full_ref, rhs.full_ref) == .lt;
}

pub fn formatRelative(timestamp: ?i64, now_unix: ?i64) Relative {
    const value = timestamp orelse return literalRelative("—");
    const now = now_unix orelse return literalRelative("—");
    if (!local_time.isDisplayTimestamp(value)) return literalRelative("—");
    if (value > now) return literalRelative("future");

    const age: i128 = @as(i128, now) - @as(i128, value);
    if (age < 60) return literalRelative("now");
    if (age < 60 * 60) return numericRelative(@divFloor(age, 60), "m ago");
    if (age < 24 * 60 * 60) return numericRelative(@divFloor(age, 60 * 60), "h ago");
    return numericRelative(@divFloor(age, 24 * 60 * 60), "d ago");
}

fn literalRelative(text: []const u8) Relative {
    var result: Relative = .{};
    @memcpy(result.bytes[0..text.len], text);
    result.len = @intCast(text.len);
    return result;
}

fn numericRelative(value: i128, suffix: []const u8) Relative {
    var result: Relative = .{};
    const rendered = std.fmt.bufPrint(&result.bytes, "{d}{s}", .{ value, suffix }) catch
        return literalRelative("—");
    result.len = @intCast(rendered.len);
    return result;
}

fn testItem(full_ref: []u8, timestamp: ?i64) git_refs.BranchListItem {
    return .{
        .full_ref = full_ref,
        .name = full_ref,
        .kind = .local,
        .oid = full_ref,
        .tip_committer_unix = timestamp,
    };
}

test "commit time total order is descending with full-ref ties and unknown last" {
    var newest = "refs/heads/newest".*;
    var tie_z = "refs/heads/z-tie".*;
    var tie_a = "refs/heads/a-tie".*;
    var unknown_b = "refs/heads/b-unknown".*;
    var unknown_a = "refs/heads/a-unknown".*;
    var branches = [_]git_refs.BranchListItem{
        testItem(&unknown_b, null),
        testItem(&tie_z, 20),
        testItem(&newest, 30),
        testItem(&unknown_a, null),
        testItem(&tie_a, 20),
    };

    sortBranches(&branches);

    try std.testing.expectEqualStrings("refs/heads/newest", branches[0].full_ref);
    try std.testing.expectEqualStrings("refs/heads/a-tie", branches[1].full_ref);
    try std.testing.expectEqualStrings("refs/heads/z-tie", branches[2].full_ref);
    try std.testing.expectEqualStrings("refs/heads/a-unknown", branches[3].full_ref);
    try std.testing.expectEqualStrings("refs/heads/b-unknown", branches[4].full_ref);
}

test "relative commit time covers exact boundaries future and unavailable values" {
    const now: i64 = 10_000_000;
    const cases = [_]struct { timestamp: ?i64, current: ?i64, expected: []const u8 }{
        .{ .timestamp = now, .current = now, .expected = "now" },
        .{ .timestamp = now - 59, .current = now, .expected = "now" },
        .{ .timestamp = now - 60, .current = now, .expected = "1m ago" },
        .{ .timestamp = now - 3_599, .current = now, .expected = "59m ago" },
        .{ .timestamp = now - 3_600, .current = now, .expected = "1h ago" },
        .{ .timestamp = now - 86_399, .current = now, .expected = "23h ago" },
        .{ .timestamp = now - 86_400, .current = now, .expected = "1d ago" },
        .{ .timestamp = now + 1, .current = now, .expected = "future" },
        .{ .timestamp = -1, .current = now, .expected = "—" },
        .{ .timestamp = local_time.maximum_display_unix_second + 1, .current = now, .expected = "—" },
        .{ .timestamp = null, .current = now, .expected = "—" },
        .{ .timestamp = now, .current = null, .expected = "—" },
    };
    for (cases) |case| {
        const actual = formatRelative(case.timestamp, case.current);
        try std.testing.expectEqualStrings(case.expected, actual.text());
    }
}
