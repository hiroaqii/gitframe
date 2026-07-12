//! Review-local selected-content and editor-target policy.
//!
//! This module derives borrowed targets or short-lived owned text from Review
//! state. It never starts foreground processes or clipboard effects; App owns
//! those physical lifecycles and consumes these typed results.

const std = @import("std");
const review_page = @import("../review.zig");
const navigation = @import("navigation.zig");
const diff_file = @import("../../../diff/file.zig");
const diff_parser = @import("../../../diff/parser.zig");
const diff_selection = @import("../../../diff/selection.zig");
const diff_source = @import("../../../diff/source.zig");
const diff_view_model = @import("../../../diff/view_model.zig");

pub const EditorTarget = struct {
    repo_root: []const u8,
    path: []const u8,
    line: ?u32,
};

pub const EditorTargetResult = union(enum) {
    ready: EditorTarget,
    unavailable_source,
    no_repo,
    no_path,
    directory_unsupported,
    deleted_file,
    stale_source,
};

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
    page: *const review_page.ReviewPageState,
    navigation: navigation.View,
    source: diff_source.SourceMode,
    repo_root: ?[]const u8,

    pub fn editorTarget(self: View) EditorTargetResult {
        // Editor actions target the current worktree path, never a staged or
        // synthetic projection which happens to render the same path.
        if (!diff_source.sourceAllowsEditorAction(self.source)) return .unavailable_source;
        if (!self.page.activation.state.satisfiesAction(.read_diff)) return .stale_source;
        const repo_root = self.repo_root orelse return .no_repo;
        const action_target = selectedSidebarTarget(self.navigation) orelse return .no_path;

        return switch (action_target.kind) {
            .repository, .directory => .directory_unsupported,
            .file => if (self.editorTargetIsDeleted(repo_root, action_target.path))
                .deleted_file
            else
                .{ .ready = .{
                    .repo_root = repo_root,
                    .path = action_target.path,
                    .line = self.editorTargetLine(),
                } },
        };
    }

    pub fn currentLineCopyText(self: View) ?[]const u8 {
        const coordinate = switch (self.page.viewer.diff_cursor) {
            .hunk_line => |line| line,
            .metadata, .binary_marker, .hunk_header => return null,
        };
        const file = self.navigation.displayedDiffFile() orelse return null;
        if (coordinate.hunk_index >= file.hunks.len) return null;
        const hunk = file.hunks[coordinate.hunk_index];
        if (coordinate.line_index >= hunk.lines.len) return null;

        return switch (self.navigation.effectiveDisplayMode()) {
            .unified => hunk.lines[coordinate.line_index].text,
            .side_by_side => sideBySideLineCopyText(hunk, coordinate.line_index),
        };
    }

    pub fn selectedHunkCopyText(self: View, allocator: std.mem.Allocator) !HunkCopyResult {
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

    fn editorTargetIsDeleted(self: View, repo_root: []const u8, path_key: []const u8) bool {
        if (self.navigation.freshStatusEntryForPathKey(repo_root, path_key)) |entry| {
            return entry.worktree == .deleted or (entry.index == .deleted and !entry.isUnstaged());
        }

        const file = self.navigation.selectedFile() orelse return false;
        const selected_key = diff_file.canonicalPathKey(file) orelse return false;
        if (!std.mem.eql(u8, selected_key, path_key)) return false;
        return diff_file.status(file) == .deleted;
    }

    fn editorTargetLine(self: View) ?u32 {
        const file = self.navigation.selectedFile() orelse return null;
        return switch (self.page.viewer.diff_cursor) {
            .hunk_line => |line| worktreeLineForHunkLine(file, line.hunk_index, line.line_index),
            .hunk_header => |hunk_index| worktreeLineForHunkLine(file, hunk_index, 0),
            else => null,
        };
    }
};

const SidebarTarget = struct {
    kind: enum { repository, directory, file },
    path: []const u8,
};

fn selectedSidebarTarget(view: navigation.View) ?SidebarTarget {
    const loaded = view.activeLoadedDiffConst() orelse return null;
    const node_index = view.page.viewer.selected_node;
    if (node_index >= loaded.tree.nodes.len) return null;
    const node = loaded.tree.nodes[node_index];
    return switch (node.target) {
        .repo_root => .{ .kind = .repository, .path = "" },
        .directory => |path| .{ .kind = .directory, .path = if (path.len > 0) path else node.path },
        .diff_file, .status_entry => .{ .kind = .file, .path = if (node.path_key.len > 0) node.path_key else node.path },
    };
}

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

fn worktreeLineForHunkLine(file: diff_parser.FileDiff, hunk_index: usize, line_index: usize) ?u32 {
    if (hunk_index >= file.hunks.len) return null;
    const lines = file.hunks[hunk_index].lines;
    if (lines.len == 0) return null;

    if (line_index < lines.len) {
        if (lines[line_index].new_line) |line| return line;
    }
    var index = line_index;
    while (index < lines.len) : (index += 1) {
        if (lines[index].new_line) |line| return line;
    }
    index = @min(line_index, lines.len - 1);
    while (true) {
        if (lines[index].new_line) |line| return line;
        if (index == 0) break;
        index -= 1;
    }
    return null;
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

test "worktree editor line falls forward then backward across removed lines" {
    const file: diff_parser.FileDiff = .{
        .header = "",
        .metadata = &.{},
        .hunks = &.{.{
            .old_start = 1,
            .old_count = 3,
            .new_start = 1,
            .new_count = 2,
            .section = "",
            .lines = &.{
                .{ .kind = .context, .text = "one", .old_line = 1, .new_line = 1 },
                .{ .kind = .removed, .text = "old", .old_line = 2 },
                .{ .kind = .context, .text = "three", .old_line = 3, .new_line = 2 },
            },
        }},
    };
    try std.testing.expectEqual(@as(?u32, 2), worktreeLineForHunkLine(file, 0, 1));
    try std.testing.expectEqual(@as(?u32, 2), worktreeLineForHunkLine(file, 0, 99));
}
