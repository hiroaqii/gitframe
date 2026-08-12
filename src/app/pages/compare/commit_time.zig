//! Compare-owned ordering and presentation for branch-tip commit times.

const std = @import("std");
const git_refs = @import("../../../git/refs.zig");

pub const Relative = struct {
    bytes: [24]u8 = undefined,
    len: u8 = 0,

    pub fn text(self: *const Relative) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const ExactUtc = struct {
    bytes: [26]u8,

    pub fn text(self: *const ExactUtc) []const u8 {
        return &self.bytes;
    }
};

const maximum_utc_second: i64 = 253_402_300_799; // 9999-12-31 23:59:59Z

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
    if (formatExactUtc(value) == null) return literalRelative("—");
    if (value > now) return literalRelative("future");

    const age: i128 = @as(i128, now) - @as(i128, value);
    if (age < 60) return literalRelative("now");
    if (age < 60 * 60) return numericRelative(@divFloor(age, 60), "m ago");
    if (age < 24 * 60 * 60) return numericRelative(@divFloor(age, 60 * 60), "h ago");
    return numericRelative(@divFloor(age, 24 * 60 * 60), "d ago");
}

pub fn formatExactUtc(timestamp: ?i64) ?ExactUtc {
    const value = timestamp orelse return null;
    if (value < 0 or value > maximum_utc_second) return null;
    const seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(value) };
    const year_day = seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = seconds.getDaySeconds();
    var result: ExactUtc = undefined;
    const rendered = std.fmt.bufPrint(&result.bytes, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} +00:00", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch unreachable;
    std.debug.assert(rendered.len == result.bytes.len);
    return result;
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
        .{ .timestamp = maximum_utc_second + 1, .current = now, .expected = "—" },
        .{ .timestamp = null, .current = now, .expected = "—" },
        .{ .timestamp = now, .current = null, .expected = "—" },
    };
    for (cases) |case| {
        const actual = formatRelative(case.timestamp, case.current);
        try std.testing.expectEqualStrings(case.expected, actual.text());
    }
}

test "exact commit time is deterministic UTC and rejects unrepresentable values" {
    const epoch = formatExactUtc(0).?;
    try std.testing.expectEqualStrings("1970-01-01 00:00:00 +00:00", epoch.text());
    const last = formatExactUtc(maximum_utc_second).?;
    try std.testing.expectEqualStrings("9999-12-31 23:59:59 +00:00", last.text());
    try std.testing.expect(formatExactUtc(null) == null);
    try std.testing.expect(formatExactUtc(-1) == null);
    try std.testing.expect(formatExactUtc(maximum_utc_second + 1) == null);
}
