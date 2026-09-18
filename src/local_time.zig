//! Shared conversion and presentation of Unix timestamps in the process-local
//! timezone. Stored timestamps remain timezone-neutral Unix seconds; only the
//! display projection consults the host timezone.

const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("time.h");
});

pub const maximum_display_unix_second: i64 = 253_402_300_799; // 9999-12-31 23:59:59Z

pub const CalendarSecond = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    utc_offset_minutes: i16,
};

pub const Exact = struct {
    bytes: [26]u8,

    pub fn text(self: *const Exact) []const u8 {
        return &self.bytes;
    }
};

pub const Minute = struct {
    bytes: [23]u8,

    pub fn text(self: *const Minute) []const u8 {
        return &self.bytes;
    }
};

pub fn isDisplayTimestamp(timestamp: i64) bool {
    return timestamp >= 0 and timestamp <= maximum_display_unix_second;
}

/// Converts an instant through the process-local timezone. On Linux and macOS,
/// libc resolves `TZ` when present and otherwise uses the host configuration.
pub fn fromUnixSeconds(unix_seconds: i64) ?CalendarSecond {
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) return null;
    const seconds = std.math.cast(c.time_t, unix_seconds) orelse return null;
    var calendar: c.struct_tm = undefined;
    if (c.localtime_r(&seconds, &calendar) == null) return null;

    const offset_seconds = localOffsetSeconds(calendar) orelse return null;
    if (@rem(offset_seconds, 60) != 0) return null;
    const value: CalendarSecond = .{
        .year = std.math.cast(u16, calendar.tm_year + 1900) orelse return null,
        .month = std.math.cast(u8, calendar.tm_mon + 1) orelse return null,
        .day = std.math.cast(u8, calendar.tm_mday) orelse return null,
        .hour = std.math.cast(u8, calendar.tm_hour) orelse return null,
        .minute = std.math.cast(u8, calendar.tm_min) orelse return null,
        .second = std.math.cast(u8, calendar.tm_sec) orelse return null,
        .utc_offset_minutes = std.math.cast(i16, @divTrunc(offset_seconds, 60)) orelse return null,
    };
    return if (validCalendar(value)) value else null;
}

pub fn formatExact(timestamp: ?i64) ?Exact {
    const value = timestamp orelse return null;
    if (!isDisplayTimestamp(value)) return null;
    const calendar = fromUnixSeconds(value) orelse return null;
    return formatExactCalendar(calendar);
}

pub fn formatMinute(timestamp: ?i64) ?Minute {
    const value = timestamp orelse return null;
    if (!isDisplayTimestamp(value)) return null;
    const calendar = fromUnixSeconds(value) orelse return null;
    return formatMinuteCalendar(calendar);
}

pub fn formatDate(timestamp: ?i64) ?[10]u8 {
    const exact = formatExact(timestamp) orelse return null;
    return exact.bytes[0..10].*;
}

fn localOffsetSeconds(calendar: c.struct_tm) ?i64 {
    if (comptime @hasField(c.struct_tm, "tm_gmtoff")) {
        return std.math.cast(i64, calendar.tm_gmtoff);
    }
    if (comptime @hasField(c.struct_tm, "__tm_gmtoff")) {
        return std.math.cast(i64, calendar.__tm_gmtoff);
    }
    return null;
}

fn formatExactCalendar(calendar: CalendarSecond) ?Exact {
    if (!validCalendar(calendar)) return null;
    const offset: i32 = calendar.utc_offset_minutes;
    const offset_magnitude: u32 = @intCast(if (offset < 0) -offset else offset);
    var result: Exact = undefined;
    const rendered = std.fmt.bufPrint(&result.bytes, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} {c}{d:0>2}:{d:0>2}", .{
        calendar.year,
        calendar.month,
        calendar.day,
        calendar.hour,
        calendar.minute,
        calendar.second,
        if (offset < 0) @as(u8, '-') else @as(u8, '+'),
        offset_magnitude / 60,
        offset_magnitude % 60,
    }) catch return null;
    std.debug.assert(rendered.len == result.bytes.len);
    return result;
}

fn formatMinuteCalendar(calendar: CalendarSecond) ?Minute {
    if (!validCalendar(calendar)) return null;
    const offset: i32 = calendar.utc_offset_minutes;
    const offset_magnitude: u32 = @intCast(if (offset < 0) -offset else offset);
    var result: Minute = undefined;
    const rendered = std.fmt.bufPrint(&result.bytes, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} {c}{d:0>2}:{d:0>2}", .{
        calendar.year,
        calendar.month,
        calendar.day,
        calendar.hour,
        calendar.minute,
        if (offset < 0) @as(u8, '-') else @as(u8, '+'),
        offset_magnitude / 60,
        offset_magnitude % 60,
    }) catch return null;
    std.debug.assert(rendered.len == result.bytes.len);
    return result;
}

fn validCalendar(value: CalendarSecond) bool {
    if (value.year == 0 or value.year > 9999 or value.month == 0 or value.month > 12 or
        value.hour > 23 or value.minute > 59 or value.second > 59 or
        value.utc_offset_minutes < -24 * 60 or value.utc_offset_minutes > 24 * 60)
    {
        return false;
    }
    const days = [_]u8{ 31, if (isLeapYear(value.year)) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return value.day != 0 and value.day <= days[value.month - 1];
}

fn isLeapYear(year: u16) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

test "local timestamp formatting keeps calendar date seconds and signed offset" {
    const east = formatExactCalendar(.{
        .year = 2026,
        .month = 9,
        .day = 18,
        .hour = 21,
        .minute = 30,
        .second = 45,
        .utc_offset_minutes = 9 * 60,
    }).?;
    try std.testing.expectEqualStrings("2026-09-18 21:30:45 +09:00", east.text());

    const west = formatExactCalendar(.{
        .year = 2024,
        .month = 2,
        .day = 29,
        .hour = 3,
        .minute = 4,
        .second = 5,
        .utc_offset_minutes = -(3 * 60 + 30),
    }).?;
    try std.testing.expectEqualStrings("2024-02-29 03:04:05 -03:30", west.text());
    try std.testing.expect(formatExactCalendar(.{
        .year = 2023,
        .month = 2,
        .day = 29,
        .hour = 0,
        .minute = 0,
        .second = 0,
        .utc_offset_minutes = 0,
    }) == null);

    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        const epoch = formatExact(0) orelse return error.LocalTimeUnavailable;
        try std.testing.expectEqual(@as(usize, 26), epoch.text().len);
        const date = formatDate(0).?;
        try std.testing.expectEqualStrings(epoch.text()[0..10], &date);
    }
    try std.testing.expect(formatExact(null) == null);
    try std.testing.expect(formatExact(-1) == null);
    try std.testing.expect(formatExact(maximum_display_unix_second + 1) == null);
}

test "local minute formatting omits seconds and keeps signed offset" {
    const east = formatMinuteCalendar(.{
        .year = 2026,
        .month = 9,
        .day = 18,
        .hour = 21,
        .minute = 30,
        .second = 45,
        .utc_offset_minutes = 9 * 60,
    }).?;
    try std.testing.expectEqualStrings("2026-09-18 21:30 +09:00", east.text());

    const west = formatMinuteCalendar(.{
        .year = 2024,
        .month = 2,
        .day = 29,
        .hour = 3,
        .minute = 4,
        .second = 59,
        .utc_offset_minutes = -(3 * 60 + 30),
    }).?;
    try std.testing.expectEqualStrings("2024-02-29 03:04 -03:30", west.text());

    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        const epoch = formatMinute(0) orelse return error.LocalTimeUnavailable;
        try std.testing.expectEqual(@as(usize, 23), epoch.text().len);
    }
    try std.testing.expect(formatMinute(null) == null);
    try std.testing.expect(formatMinute(-1) == null);
    try std.testing.expect(formatMinute(maximum_display_unix_second + 1) == null);
}
