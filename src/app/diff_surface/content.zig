//! Page-independent selected diff content.
//!
//! This module derives borrowed or short-lived owned copy text from a shared
//! body view. It has no clipboard or process authority; callers own those
//! physical effects and the lifetime of every owned result.

const std = @import("std");
const navigation = @import("navigation.zig");
const diff_parser = @import("../../diff/parser.zig");
const diff_selection = @import("../../diff/selection.zig");
const diff_view_model = @import("../../diff/view_model.zig");

pub const HunkCopyResult = union(enum) {
    ready: []u8,
    no_hunk,
    no_new_side,

    pub fn deinit(self: *HunkCopyResult, allocator: std.mem.Allocator) void {
        if (self.* == .ready) allocator.free(self.ready);
        self.* = undefined;
    }
};

pub const View = struct {
    navigation: navigation.BodyView,

    pub fn currentLineCopyText(self: View) ?[]const u8 {
        if (!self.navigation.bodyAllowsHunkInteraction()) return null;
        const coordinate = switch (self.navigation.view.surface.viewer.diff_cursor) {
            .hunk_line => |line| line,
            .metadata, .binary_marker, .hunk_header => return null,
        };
        const file = self.navigation.displayedDiffFile() orelse return null;
        if (coordinate.hunk_index >= file.hunks.len) return null;
        const hunk = file.hunks[coordinate.hunk_index];
        if (coordinate.line_index >= hunk.lines.len) return null;

        return switch (self.navigation.view.effectiveDisplayMode()) {
            .unified => hunk.lines[coordinate.line_index].text,
            .side_by_side => sideBySideLineCopyText(hunk, coordinate.line_index),
        };
    }

    pub fn selectedHunkCopyText(self: View, allocator: std.mem.Allocator) !HunkCopyResult {
        if (!self.navigation.bodyAllowsHunkInteraction()) return .no_hunk;
        const hunk_index = self.navigation.selectedHunkIndex() orelse return .no_hunk;
        const file = self.navigation.displayedDiffFile() orelse return .no_hunk;
        if (hunk_index >= file.hunks.len) return .no_hunk;

        const text = try newSideHunkCopyText(allocator, file.hunks[hunk_index]);
        if (text.len == 0) {
            allocator.free(text);
            return .no_new_side;
        }
        return .{ .ready = text };
    }

    pub fn diffSelectionCopyText(
        self: View,
        allocator: std.mem.Allocator,
        selection: diff_selection.DragSelection,
    ) !?[]u8 {
        const target = self.navigation.normalLoadedDiffSelectionTarget(selection.identity) orelse return null;
        return try diff_selection.copyText(allocator, target.file, selection);
    }

    pub fn diffHeaderPath(
        self: View,
        selection: diff_selection.HeaderPathSelection,
    ) ?[]const u8 {
        const target = self.navigation.displayedDiffHeaderTarget(selection.identity) orelse return null;
        return target.display_path;
    }
};

fn sideBySideLineCopyText(hunk: diff_parser.Hunk, line_index: usize) ?[]const u8 {
    var rows = diff_view_model.SideBySideIndexedIterator.init(hunk.lines);
    while (rows.next()) |row| {
        switch (row) {
            .single => |line| if (line.line_index == line_index) return line.line.text,
            .paired => |pair| {
                const matches_removed = if (pair.removed) |removed| removed.line_index == line_index else false;
                const matches_added = if (pair.added) |added| added.line_index == line_index else false;
                if (!matches_removed and !matches_added) continue;
                if (pair.added) |added| return added.line.text;
                if (pair.removed) |removed| return removed.line.text;
            },
        }
    }
    return null;
}

fn newSideHunkCopyText(allocator: std.mem.Allocator, hunk: diff_parser.Hunk) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    for (hunk.lines) |line| {
        switch (line.kind) {
            .context, .added => {
                try out.writer.writeAll(line.text);
                try out.writer.writeByte('\n');
            },
            .removed, .metadata => {},
        }
    }
    return try out.toOwnedSlice();
}

test "side-by-side copy prefers paired new side" {
    const hunk: diff_parser.Hunk = .{
        .old_start = 1,
        .old_count = 1,
        .new_start = 1,
        .new_count = 1,
        .section = "",
        .lines = &.{
            .{ .kind = .removed, .text = "old", .old_line = 1 },
            .{ .kind = .added, .text = "new", .new_line = 1 },
        },
    };
    try std.testing.expectEqualStrings("new", sideBySideLineCopyText(hunk, 0).?);
}

test "side-by-side copy falls back to removed side" {
    const hunk: diff_parser.Hunk = .{
        .old_start = 1,
        .old_count = 1,
        .new_start = 1,
        .new_count = 0,
        .section = "",
        .lines = &.{.{ .kind = .removed, .text = "deleted", .old_line = 1 }},
    };
    try std.testing.expectEqualStrings("deleted", sideBySideLineCopyText(hunk, 0).?);
}

test "new-side hunk copy is undecorated and keeps trailing newline" {
    const hunk: diff_parser.Hunk = .{
        .old_start = 1,
        .old_count = 2,
        .new_start = 1,
        .new_count = 2,
        .section = "",
        .lines = &.{
            .{ .kind = .context, .text = "one", .old_line = 1, .new_line = 1 },
            .{ .kind = .removed, .text = "old", .old_line = 2 },
            .{ .kind = .added, .text = "new", .new_line = 2 },
        },
    };
    const text = try newSideHunkCopyText(std.testing.allocator, hunk);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("one\nnew\n", text);
}
