//! Pure Repository source-header facts, formatting, and adaptive row layout.
//!
//! This module deliberately owns no page state and performs no filesystem,
//! Git, rendering, or input work. SH3 may project exact accepted page facts
//! into `Presentation`, while both rendering and SH5 hit testing consume the
//! same `Layout` so terminal-cell geometry cannot diverge.

const std = @import("std");
const manifest = @import("../../../repository/manifest.zig");

pub const minimum_path_width: u16 = 8;
pub const field_gap: u16 = 2;
pub const path_metadata_gap: u16 = 2;

pub const Region = struct {
    col: u16,
    width: u16,

    pub fn contains(self: Region, col: u16) bool {
        const value: u32 = col;
        const start: u32 = self.col;
        return value >= start and value < start + @as(u32, self.width);
    }
};

pub const LinePosition = struct {
    current: usize,
    total: usize,

    /// Converts the page's zero-based viewer cursor to user-facing source
    /// coordinates without exposing the synthetic row used for an empty file.
    pub fn fromCursor(cursor: usize, total: usize) LinePosition {
        if (total == 0) return .{ .current = 0, .total = 0 };
        return .{
            .current = @min(cursor, total - 1) + 1,
            .total = total,
        };
    }
};

pub const GitState = enum {
    clean,
    added,
    modified,
    unavailable,

    pub fn label(self: GitState) []const u8 {
        return switch (self) {
            .clean => "clean",
            .added => "added",
            .modified => "modified",
            .unavailable => "git ?",
        };
    }
};

/// Page-neutral facts which describe one source-header presentation basis.
/// `raw_path` remains the borrowed byte-exact identity; its escaped width is a
/// presentation fact only and must never be used to open or compare a path.
pub const Presentation = struct {
    raw_path: []const u8,
    displayed_path_width: usize,
    line_position: ?LinePosition,
    git_state: GitState,
    modified_at: ?std.Io.Timestamp,

    pub fn init(
        raw_path: []const u8,
        line_position: ?LinePosition,
        git_state: GitState,
        modified_at: ?std.Io.Timestamp,
    ) Presentation {
        return .{
            .raw_path = raw_path,
            .displayed_path_width = manifest.escapedDisplayWidth(raw_path),
            .line_position = line_position,
            .git_state = git_state,
            .modified_at = modified_at,
        };
    }
};

pub const LineLabel = struct {
    bytes: [64]u8 = undefined,
    len: u8,

    pub fn text(self: *const LineLabel) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub fn formatLinePosition(position: LinePosition) LineLabel {
    var result: LineLabel = .{ .len = 0 };
    const rendered = std.fmt.bufPrint(&result.bytes, "Ln {d}/{d}", .{
        position.current,
        position.total,
    }) catch unreachable;
    result.len = @intCast(rendered.len);
    return result;
}

pub const UtcMinute = struct {
    bytes: [17]u8,

    pub fn text(self: *const UtcMinute) []const u8 {
        return &self.bytes;
    }
};

const maximum_utc_second: u64 = 253_402_300_799; // 9999-12-31 23:59:59Z

/// Formats a raw filesystem timestamp without consulting local timezone or a
/// clock. Negative values and years outside the fixed four-digit contract are
/// omitted rather than normalized into a fabricated presentation.
pub fn formatUtcMinute(timestamp: std.Io.Timestamp) ?UtcMinute {
    if (timestamp.nanoseconds < 0) return null;
    const seconds_i96 = @divTrunc(timestamp.nanoseconds, std.time.ns_per_s);
    const seconds = std.math.cast(u64, seconds_i96) orelse return null;
    if (seconds > maximum_utc_second) return null;

    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    var result: UtcMinute = undefined;
    const rendered = std.fmt.bufPrint(&result.bytes, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
    }) catch unreachable;
    std.debug.assert(rendered.len == result.bytes.len);
    return result;
}

pub const LineField = struct {
    region: Region,
    label: LineLabel,
};

pub const GitField = struct {
    region: Region,
    state: GitState,
};

pub const MtimeField = struct {
    region: Region,
    value: UtcMinute,
};

pub const Layout = struct {
    path_area: Region = .{ .col = 0, .width = 0 },
    path_target: ?Region = null,
    line: ?LineField = null,
    git: ?GitField = null,
    mtime: ?MtimeField = null,
};

/// Computes the complete row-0 geometry and already-formatted metadata fields.
/// Optional fields are removed in mtime, Git, line order until at least eight
/// path cells plus a two-cell group boundary fit. The path target covers only
/// cells the bounded escaped-path renderer can actually emit.
pub fn layout(width: u16, presentation: Presentation) Layout {
    const pane_width: usize = width;
    if (pane_width <= 1) return .{};

    const left_inset: usize = 1;
    // Preserve right padding when there is at least one possible content cell.
    const content_end: usize = if (pane_width >= 3) pane_width - 1 else pane_width;
    const content_width = content_end - left_inset;

    const line_label: ?LineLabel = if (presentation.line_position) |position|
        formatLinePosition(position)
    else
        null;
    const mtime_value: ?UtcMinute = if (presentation.modified_at) |timestamp|
        formatUtcMinute(timestamp)
    else
        null;

    var include_line = line_label != null;
    var include_git = true;
    var include_mtime = mtime_value != null;
    while (true) {
        const metadata_width = metadataGroupWidth(
            if (include_line) line_label.?.len else null,
            if (include_git) presentation.git_state.label().len else null,
            if (include_mtime) mtime_value.?.bytes.len else null,
        );
        const required = @as(usize, minimum_path_width) +
            (if (metadata_width > 0) @as(usize, path_metadata_gap) else 0) +
            metadata_width;
        if (required <= content_width) break;
        if (include_mtime) {
            include_mtime = false;
            continue;
        }
        if (include_git) {
            include_git = false;
            continue;
        }
        if (include_line) {
            include_line = false;
            continue;
        }
        break;
    }

    const metadata_width = metadataGroupWidth(
        if (include_line) line_label.?.len else null,
        if (include_git) presentation.git_state.label().len else null,
        if (include_mtime) mtime_value.?.bytes.len else null,
    );
    const metadata_col = content_end - metadata_width;
    const path_end = if (metadata_width > 0)
        metadata_col - @as(usize, path_metadata_gap)
    else
        content_end;
    var result: Layout = .{
        .path_area = .{
            .col = @intCast(left_inset),
            .width = @intCast(path_end - left_inset),
        },
    };
    const path_width = manifest.displayWindowWidth(
        presentation.raw_path,
        0,
        result.path_area.width,
    );
    if (path_width > 0) {
        result.path_target = .{
            .col = result.path_area.col,
            .width = @intCast(path_width),
        };
    }

    var field_col = metadata_col;
    if (include_line) {
        const label = line_label.?;
        result.line = .{
            .region = .{ .col = @intCast(field_col), .width = label.len },
            .label = label,
        };
        field_col += label.len;
        if (include_git or include_mtime) field_col += field_gap;
    }
    if (include_git) {
        const label = presentation.git_state.label();
        result.git = .{
            .region = .{ .col = @intCast(field_col), .width = @intCast(label.len) },
            .state = presentation.git_state,
        };
        field_col += label.len;
        if (include_mtime) field_col += field_gap;
    }
    if (include_mtime) {
        const value = mtime_value.?;
        result.mtime = .{
            .region = .{ .col = @intCast(field_col), .width = @intCast(value.bytes.len) },
            .value = value,
        };
        field_col += value.bytes.len;
    }
    std.debug.assert(field_col == content_end);
    return result;
}

fn metadataGroupWidth(line: ?usize, git: ?usize, mtime: ?usize) usize {
    var width: usize = 0;
    var count: usize = 0;
    for ([_]?usize{ line, git, mtime }) |field| if (field) |field_width| {
        if (count > 0) width += field_gap;
        width += field_width;
        count += 1;
    };
    return width;
}

test "repository source header line position uses real content coordinates" {
    try std.testing.expectEqual(LinePosition{ .current = 0, .total = 0 }, LinePosition.fromCursor(99, 0));
    try std.testing.expectEqual(LinePosition{ .current = 1, .total = 3 }, LinePosition.fromCursor(0, 3));
    try std.testing.expectEqual(LinePosition{ .current = 3, .total = 3 }, LinePosition.fromCursor(20, 3));
    try std.testing.expectEqual(
        LinePosition{ .current = std.math.maxInt(usize), .total = std.math.maxInt(usize) },
        LinePosition.fromCursor(std.math.maxInt(usize), std.math.maxInt(usize)),
    );

    const empty = formatLinePosition(.{ .current = 0, .total = 0 });
    try std.testing.expectEqualStrings("Ln 0/0", empty.text());
    const current = formatLinePosition(.{ .current = 42, .total = 8713 });
    try std.testing.expectEqualStrings("Ln 42/8713", current.text());
}

test "repository source header Git labels remain typed aggregate facts" {
    try std.testing.expectEqualStrings("clean", GitState.clean.label());
    try std.testing.expectEqualStrings("added", GitState.added.label());
    try std.testing.expectEqualStrings("modified", GitState.modified.label());
    try std.testing.expectEqualStrings("git ?", GitState.unavailable.label());
}

test "repository source header UTC minute formatting is deterministic and bounded" {
    const epoch = formatUtcMinute(.zero).?;
    try std.testing.expectEqualStrings("1970-01-01 00:00Z", epoch.text());

    const before_minute = formatUtcMinute(.{ .nanoseconds = 59 * std.time.ns_per_s + 999_999_999 }).?;
    try std.testing.expectEqualStrings("1970-01-01 00:00Z", before_minute.text());
    const next_minute = formatUtcMinute(.{ .nanoseconds = 60 * std.time.ns_per_s }).?;
    try std.testing.expectEqualStrings("1970-01-01 00:01Z", next_minute.text());

    const leap = formatUtcMinute(.{ .nanoseconds = 951_827_640 * std.time.ns_per_s }).?;
    try std.testing.expectEqualStrings("2000-02-29 12:34Z", leap.text());
    const upper = formatUtcMinute(.{
        .nanoseconds = @as(i96, maximum_utc_second) * std.time.ns_per_s,
    }).?;
    try std.testing.expectEqualStrings("9999-12-31 23:59Z", upper.text());

    try std.testing.expect(formatUtcMinute(.{ .nanoseconds = -1 }) == null);
    try std.testing.expect(formatUtcMinute(.{
        .nanoseconds = (@as(i96, maximum_utc_second) + 1) * std.time.ns_per_s,
    }) == null);
}

test "repository source header presentation measures escaped raw path" {
    const presentation = Presentation.init(
        "日本語\\\xff",
        null,
        .unavailable,
        null,
    );
    try std.testing.expectEqual(
        manifest.escapedDisplayWidth(presentation.raw_path),
        presentation.displayed_path_width,
    );
    try std.testing.expectEqual(@as(usize, 12), presentation.displayed_path_width);
}

test "repository source header layout removes metadata in approved priority order" {
    const presentation = Presentation.init(
        "src/main.zig",
        .{ .current = 42, .total = 8713 },
        .modified,
        .{ .nanoseconds = 951_827_640 * std.time.ns_per_s },
    );

    const wide = layout(80, presentation);
    try std.testing.expect(wide.line != null);
    try std.testing.expect(wide.git != null);
    try std.testing.expect(wide.mtime != null);
    try std.testing.expectEqual(@as(u16, 1), wide.path_area.col);
    try std.testing.expect(wide.path_area.width >= minimum_path_width);
    try std.testing.expectEqual(@as(u16, 12), wide.path_target.?.width);
    try std.testing.expectEqual(@as(u16, 79), wide.mtime.?.region.col + wide.mtime.?.region.width);

    const without_mtime = layout(50, presentation);
    try std.testing.expect(without_mtime.line != null);
    try std.testing.expect(without_mtime.git != null);
    try std.testing.expect(without_mtime.mtime == null);

    const line_only = layout(29, presentation);
    try std.testing.expect(line_only.line != null);
    try std.testing.expect(line_only.git == null);
    try std.testing.expect(line_only.mtime == null);

    const path_only = layout(19, presentation);
    try std.testing.expect(path_only.line == null);
    try std.testing.expect(path_only.git == null);
    try std.testing.expect(path_only.mtime == null);
    try std.testing.expectEqual(@as(u16, 17), path_only.path_area.width);
}

test "repository source header layout preserves path target and tiny bounds" {
    const short = Presentation.init("a", null, .clean, null);
    const wide = layout(40, short);
    try std.testing.expect(wide.git != null);
    try std.testing.expectEqual(@as(u16, 1), wide.path_target.?.width);
    try std.testing.expect(!wide.path_target.?.contains(0));
    try std.testing.expect(!wide.path_target.?.contains(2));

    try std.testing.expect(layout(0, short).path_target == null);
    try std.testing.expect(layout(1, short).path_target == null);
    const width_two = layout(2, short);
    try std.testing.expectEqual(Region{ .col = 1, .width = 1 }, width_two.path_area);
    try std.testing.expectEqual(Region{ .col = 1, .width = 1 }, width_two.path_target.?);

    const wide_first = Presentation.init("👩‍🚀x", null, .clean, null);
    const width_three = layout(3, wide_first);
    try std.testing.expectEqual(@as(u16, 1), width_three.path_area.width);
    try std.testing.expect(width_three.path_target == null);

    const empty = Presentation.init("", null, .clean, null);
    try std.testing.expect(layout(40, empty).path_target == null);
}

test "repository source header layout omits unrepresentable mtime without dropping Git" {
    const presentation = Presentation.init(
        "src/main.zig",
        null,
        .unavailable,
        .{ .nanoseconds = -1 },
    );
    const result = layout(80, presentation);
    try std.testing.expect(result.line == null);
    try std.testing.expect(result.git != null);
    try std.testing.expectEqual(GitState.unavailable, result.git.?.state);
    try std.testing.expect(result.mtime == null);
}
