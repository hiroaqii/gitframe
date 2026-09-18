//! Pure Repository source-header facts, formatting, and adaptive row layout.
//!
//! This module deliberately owns no page state and performs no filesystem,
//! Git, rendering, or input work. It projects exact accepted page facts into
//! `Presentation`; rendering and hit testing consume the same `Layout` so
//! terminal-cell geometry cannot diverge.

const std = @import("std");
const manifest = @import("../../../repository/manifest.zig");
const local_time = @import("../../../local_time.zig");

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

    pub fn marker(self: GitState) []const u8 {
        return switch (self) {
            .clean => "",
            .added => "A",
            .modified => "M",
            .unavailable => "?",
        };
    }
};

pub const CommitFact = union(enum) {
    committed: i64,
    uncommitted,
    unavailable,
};

/// Page-neutral facts which describe one source-header presentation basis.
/// `raw_path` remains the borrowed byte-exact identity; its escaped width is a
/// presentation fact only and must never be used to open or compare a path.
pub const Presentation = struct {
    raw_path: []const u8,
    displayed_path_width: usize,
    line_position: ?LinePosition,
    git_state: GitState,
    commit_fact: CommitFact,

    pub fn init(
        raw_path: []const u8,
        line_position: ?LinePosition,
        git_state: GitState,
        commit_fact: CommitFact,
    ) Presentation {
        return .{
            .raw_path = raw_path,
            .displayed_path_width = manifest.escapedDisplayWidth(raw_path),
            .line_position = line_position,
            .git_state = git_state,
            .commit_fact = commit_fact,
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

pub const CommitLabel = struct {
    bytes: [30]u8 = undefined,
    len: u8,
    width: u8,

    pub fn text(self: *const CommitLabel) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub fn formatCommitFact(fact: CommitFact) CommitLabel {
    var result: CommitLabel = .{ .len = 0, .width = 0 };
    switch (fact) {
        .committed => |seconds| if (local_time.formatMinute(seconds)) |minute| {
            const label = std.fmt.bufPrint(&result.bytes, "commit {s}", .{minute.text()}) catch unreachable;
            result.len = @intCast(label.len);
            result.width = @intCast(label.len);
        } else {
            const label = "commit —";
            @memcpy(result.bytes[0..label.len], label);
            result.len = label.len;
            result.width = 8;
        },
        .uncommitted => {
            const label = "uncommitted";
            @memcpy(result.bytes[0..label.len], label);
            result.len = label.len;
            result.width = label.len;
        },
        .unavailable => {
            const label = "commit —";
            @memcpy(result.bytes[0..label.len], label);
            result.len = label.len;
            result.width = 8;
        },
    }
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

pub const CommitField = struct {
    region: Region,
    value: CommitLabel,
};

pub const Layout = struct {
    path_area: Region = .{ .col = 0, .width = 0 },
    path_target: ?Region = null,
    line: ?LineField = null,
    git: ?GitField = null,
    commit: ?CommitField = null,
};

/// Computes the complete row-0 geometry and already-formatted metadata fields.
/// Optional fields are removed in line, commit, Git order until at least eight
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
    const git_marker = presentation.git_state.marker();
    const commit_label = formatCommitFact(presentation.commit_fact);

    var include_line = line_label != null;
    var include_git = git_marker.len > 0;
    var include_commit = true;
    while (true) {
        const metadata_width = metadataGroupWidth(
            if (include_line) line_label.?.len else null,
            if (include_git) git_marker.len else null,
            if (include_commit) commit_label.width else null,
        );
        const required = @as(usize, minimum_path_width) +
            (if (metadata_width > 0) @as(usize, path_metadata_gap) else 0) +
            metadata_width;
        if (required <= content_width) break;
        if (include_line) {
            include_line = false;
            continue;
        }
        if (include_commit) {
            include_commit = false;
            continue;
        }
        if (include_git) {
            include_git = false;
            continue;
        }
        break;
    }

    const metadata_width = metadataGroupWidth(
        if (include_line) line_label.?.len else null,
        if (include_git) git_marker.len else null,
        if (include_commit) commit_label.width else null,
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
        if (include_git or include_commit) field_col += field_gap;
    }
    if (include_git) {
        result.git = .{
            .region = .{ .col = @intCast(field_col), .width = @intCast(git_marker.len) },
            .state = presentation.git_state,
        };
        field_col += git_marker.len;
        if (include_commit) field_col += field_gap;
    }
    if (include_commit) {
        result.commit = .{
            .region = .{ .col = @intCast(field_col), .width = commit_label.width },
            .value = commit_label,
        };
        field_col += commit_label.width;
    }
    std.debug.assert(field_col == content_end);
    return result;
}

fn metadataGroupWidth(line: ?usize, git: ?usize, commit: ?usize) usize {
    var width: usize = 0;
    var count: usize = 0;
    for ([_]?usize{ line, git, commit }) |field| if (field) |field_width| {
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

test "repository source header Git markers are compact and omit clean state" {
    try std.testing.expectEqualStrings("", GitState.clean.marker());
    try std.testing.expectEqualStrings("A", GitState.added.marker());
    try std.testing.expectEqualStrings("M", GitState.modified.marker());
    try std.testing.expectEqualStrings("?", GitState.unavailable.marker());
}

test "repository source header uses shared local minute formatting" {
    const minute = local_time.formatMinute(951_827_640).?;
    const committed = formatCommitFact(.{ .committed = 951_827_640 });
    var expected_buffer: [30]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buffer, "commit {s}", .{minute.text()});
    try std.testing.expectEqualStrings(expected, committed.text());
    try std.testing.expectEqual(@as(u8, 30), committed.width);
    const uncommitted = formatCommitFact(.uncommitted);
    try std.testing.expectEqualStrings("uncommitted", uncommitted.text());
    const unavailable = formatCommitFact(.unavailable);
    try std.testing.expectEqualStrings("commit —", unavailable.text());
    try std.testing.expectEqual(@as(u8, 8), unavailable.width);
    try std.testing.expectEqualStrings("commit —", formatCommitFact(.{ .committed = -1 }).text());
}

test "repository source header presentation measures escaped raw path" {
    const presentation = Presentation.init(
        "日本語\\\xff",
        null,
        .unavailable,
        .unavailable,
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
        .{ .committed = 951_827_640 },
    );

    const wide = layout(80, presentation);
    try std.testing.expect(wide.line != null);
    try std.testing.expect(wide.git != null);
    try std.testing.expect(wide.commit != null);
    try std.testing.expectEqual(@as(u16, 1), wide.path_area.col);
    try std.testing.expect(wide.path_area.width >= minimum_path_width);
    try std.testing.expectEqual(@as(u16, 12), wide.path_target.?.width);
    try std.testing.expectEqual(@as(u16, 79), wide.commit.?.region.col + wide.commit.?.region.width);

    const without_line = layout(56, presentation);
    try std.testing.expect(without_line.line == null);
    try std.testing.expect(without_line.git != null);
    try std.testing.expect(without_line.commit != null);

    const git_only = layout(34, presentation);
    try std.testing.expect(git_only.line == null);
    try std.testing.expect(git_only.git != null);
    try std.testing.expect(git_only.commit == null);

    const path_only = layout(12, presentation);
    try std.testing.expect(path_only.line == null);
    try std.testing.expect(path_only.git == null);
    try std.testing.expect(path_only.commit == null);
    try std.testing.expectEqual(@as(u16, 10), path_only.path_area.width);
}

test "repository source header layout preserves path target and tiny bounds" {
    const short = Presentation.init("a", null, .clean, .unavailable);
    const wide = layout(40, short);
    try std.testing.expect(wide.git == null);
    try std.testing.expectEqual(@as(u16, 1), wide.path_target.?.width);
    try std.testing.expect(!wide.path_target.?.contains(0));
    try std.testing.expect(!wide.path_target.?.contains(2));

    try std.testing.expect(layout(0, short).path_target == null);
    try std.testing.expect(layout(1, short).path_target == null);
    const width_two = layout(2, short);
    try std.testing.expectEqual(Region{ .col = 1, .width = 1 }, width_two.path_area);
    try std.testing.expectEqual(Region{ .col = 1, .width = 1 }, width_two.path_target.?);

    const wide_first = Presentation.init("👩‍🚀x", null, .clean, .unavailable);
    const width_three = layout(3, wide_first);
    try std.testing.expectEqual(@as(u16, 1), width_three.path_area.width);
    try std.testing.expect(width_three.path_target == null);

    const empty = Presentation.init("", null, .clean, .unavailable);
    try std.testing.expect(layout(40, empty).path_target == null);
}

test "repository source header renders invalid timestamp as whole unavailable fact" {
    const presentation = Presentation.init(
        "src/main.zig",
        null,
        .unavailable,
        .{ .committed = -1 },
    );
    const result = layout(80, presentation);
    try std.testing.expect(result.line == null);
    try std.testing.expect(result.git != null);
    try std.testing.expectEqual(GitState.unavailable, result.git.?.state);
    try std.testing.expect(result.commit != null);
    try std.testing.expectEqualStrings("commit —", result.commit.?.value.text());
}
