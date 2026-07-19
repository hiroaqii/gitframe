//! Review-local selected-content and editor-target policy.
//!
//! This module derives borrowed targets or short-lived owned text from Review
//! state. It never starts foreground processes or clipboard effects; App owns
//! those physical lifecycles and consumes these typed results.

const std = @import("std");
const builtin = @import("builtin");
const app_page = if (builtin.is_test) @import("../../page.zig") else struct {};
const app_state = if (builtin.is_test) @import("../../state.zig") else struct {};
const page_link = @import("../../page_link.zig");
const review_projection = if (builtin.is_test) @import("../../review_projection.zig") else struct {};
const review_page = @import("../review.zig");
const navigation = @import("navigation.zig");
const review_reload = @import("reload.zig");
const diff_file = @import("../../../diff/file.zig");
const diff_parser = @import("../../../diff/parser.zig");
const diff_selection = @import("../../../diff/selection.zig");
const diff_source = @import("../../../diff/source.zig");
const diff_view_model = @import("../../../diff/view_model.zig");
const git_status = @import("../../../git/status.zig");
const test_support = if (builtin.is_test) @import("../../test_support.zig") else struct {};

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

    /// Derive an allocation-free Repository destination from the exact body
    /// currently promised by Review.
    ///
    /// This is deliberately stricter than `editorTarget`: removed rows never
    /// scan to a nearby current line, and sources without current-repository
    /// authority return `no_context` rather than reusing coincidental paths.
    pub fn repositoryTarget(self: View) page_link.ReviewRepositoryTarget {
        if (!diff_source.sourceAllowsRepositoryLink(self.source)) return .no_context;
        if (!self.page.activation.state.satisfiesAction(.read_diff)) return .no_context;
        const repo_root = self.repo_root orelse return .no_context;

        const displayed_body = self.navigation.displayedReviewBody();
        if (!self.displayedProjectionHasCurrentAuthority()) return .no_context;
        return switch (displayed_body) {
            .primary => |primary| self.parsedRepositoryTarget(
                primary.loaded.document.files[primary.file_index],
                switch (self.source) {
                    .unstaged => .worktree,
                    .cached => .cached,
                    else => unreachable,
                },
                repo_root,
            ),
            .cached => |bundle| self.parsedRepositoryTarget(bundle.loaded.document.files[0], .cached, repo_root),
            .combined => |bundle| repositoryTargetForParsedFile(
                bundle.displayFile(),
                self.page.viewer.diff_cursor,
                self.navigation.effectiveDisplayMode(),
                .synthetic,
                false,
            ),
            .generated => |bundle| generatedRepositoryTarget(
                bundle.path,
                bundle.source.contentLineCount(),
                self.page.viewer.diff_cursor,
            ),
            .inert_invalid_utf8 => |body| self.opaqueRepositoryTarget(repo_root, body.path_key),
            .status => |body| self.opaqueRepositoryTarget(repo_root, body.path),
            .none, .pending => .no_context,
        };
    }

    /// Rendering may retain an older same-path projection while its successor
    /// is pending. Cross-page navigation is stricter: an old request must not
    /// be rebound to a newly selected status entry merely because path text is
    /// equal. Require the complete current projection identity before using
    /// any displayed projection as Repository authority.
    fn displayedProjectionHasCurrentAuthority(self: View) bool {
        const request = self.page.review_projection.displayed.request() orelse return true;
        if (!self.navigation.displayedProjectionRequestIsActive(request.*)) return true;
        const target = (review_reload.View{
            .page = self.page,
            .navigation = self.navigation,
            .source = self.source,
            .repo_root = self.repo_root,
        }).projectionTarget() orelse return false;
        return request.matchesBorrowed(
            target.repo_root,
            target.path_key,
            target.kind,
            target.source_kind,
            self.page.source_session_revision,
            self.page.status_snapshot_revision,
        );
    }

    pub fn currentLineCopyText(self: View) ?[]const u8 {
        if (!self.navigation.bodyAllowsHunkInteraction()) return null;
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

    fn parsedRepositoryTarget(self: View, file: diff_parser.FileDiff, basis: ParsedBasis, repo_root: []const u8) page_link.ReviewRepositoryTarget {
        const current_path = diff_file.currentPathKey(file);
        const cached_line_safe = if (basis == .cached and current_path != null)
            self.cachedLineIsCurrent(repo_root, current_path.?)
        else
            false;
        return repositoryTargetForParsedFile(
            file,
            self.page.viewer.diff_cursor,
            self.navigation.effectiveDisplayMode(),
            basis,
            cached_line_safe,
        );
    }

    fn cachedLineIsCurrent(self: View, repo_root: []const u8, path: []const u8) bool {
        const entry = self.navigation.freshStatusEntryForPathKey(repo_root, path) orelse return false;
        return cachedStatusAllowsCurrentLine(entry);
    }

    fn opaqueRepositoryTarget(self: View, repo_root: []const u8, path: []const u8) page_link.ReviewRepositoryTarget {
        const selected_target = self.page.viewer.selected_target orelse return .no_context;
        return switch (selected_target) {
            .status_only => self.selectedStatusRepositoryTarget(repo_root, path),
            .diff_file => self.selectedDiffRepositoryTarget(path),
        };
    }

    fn selectedStatusRepositoryTarget(self: View, repo_root: []const u8, path: []const u8) page_link.ReviewRepositoryTarget {
        if (!self.page.status_load.isFresh()) return .no_context;
        const snapshot_root = self.page.git_status.repo_root orelse return .no_context;
        if (!std.mem.eql(u8, snapshot_root, repo_root)) return .no_context;
        const entry = self.navigation.selectedStatusEntry() orelse return .no_context;
        const selected_path = entry.canonicalPathKey() orelse return .no_context;
        if (!std.mem.eql(u8, selected_path, path)) return .no_context;
        if (statusEntryHasCurrentPath(entry)) return .{ .location = .{ .path = selected_path } };
        return .{ .unavailable = .{ .path = selected_path, .reason = .no_current_path } };
    }

    fn selectedDiffRepositoryTarget(self: View, path: []const u8) page_link.ReviewRepositoryTarget {
        const selected = self.navigation.selectedFile() orelse return .no_context;
        if (diff_file.currentPathKey(selected)) |current_path| {
            if (std.mem.eql(u8, current_path, path)) return .{ .location = .{ .path = current_path } };
        }
        const diagnostic = diff_file.canonicalPathKey(selected) orelse return .no_context;
        if (!std.mem.eql(u8, diagnostic, path)) return .no_context;
        return .{ .unavailable = .{ .path = diagnostic, .reason = .no_current_path } };
    }
};

const ParsedBasis = enum {
    worktree,
    cached,
    synthetic,
};

fn repositoryTargetForParsedFile(
    file: diff_parser.FileDiff,
    cursor: diff_view_model.BodyCoordinate,
    mode: diff_view_model.DisplayMode,
    basis: ParsedBasis,
    cached_line_safe: bool,
) page_link.ReviewRepositoryTarget {
    const current_path = diff_file.currentPathKey(file) orelse return .{ .unavailable = .{
        .path = diff_file.canonicalPathKey(file) orelse diff_file.displayPath(file),
        .reason = .no_current_path,
    } };

    const line = switch (basis) {
        .worktree => directCurrentLine(file, cursor, mode),
        .cached => if (cached_line_safe) directCurrentLine(file, cursor, mode) else null,
        .synthetic => null,
    };
    return .{ .location = .{ .path = current_path, .line = line } };
}

fn generatedRepositoryTarget(
    path: []const u8,
    content_line_count: usize,
    cursor: diff_view_model.BodyCoordinate,
) page_link.ReviewRepositoryTarget {
    const line: ?u32 = switch (cursor) {
        .metadata => |row| if (row < content_line_count) @intCast(row + 1) else null,
        .binary_marker, .hunk_header, .hunk_line => null,
    };
    return .{ .location = .{ .path = path, .line = line } };
}

fn directCurrentLine(
    file: diff_parser.FileDiff,
    cursor: diff_view_model.BodyCoordinate,
    mode: diff_view_model.DisplayMode,
) ?u32 {
    const coordinate = switch (cursor) {
        .hunk_line => |line| line,
        .metadata, .binary_marker, .hunk_header => return null,
    };
    if (coordinate.hunk_index >= file.hunks.len) return null;
    const lines = file.hunks[coordinate.hunk_index].lines;
    if (coordinate.line_index >= lines.len) return null;
    if (mode == .unified) return lines[coordinate.line_index].new_line;

    var rows = diff_view_model.SideBySideIndexedIterator.init(lines);
    while (rows.next()) |row| {
        switch (row) {
            .single => |single| {
                if (single.line_index == coordinate.line_index) return single.line.new_line;
            },
            .paired => |pair| {
                const matches_removed = if (pair.removed) |removed| removed.line_index == coordinate.line_index else false;
                const matches_added = if (pair.added) |added| added.line_index == coordinate.line_index else false;
                if (!matches_removed and !matches_added) continue;
                return if (pair.added) |added| added.line.new_line else null;
            },
        }
    }
    return null;
}

fn cachedStatusAllowsCurrentLine(entry: git_status.StatusEntry) bool {
    if (entry.raw[1] != ' ' or entry.worktree != .unmodified or entry.isConflict()) return false;
    return switch (entry.index) {
        .modified, .added, .renamed, .copied => true,
        .unmodified, .deleted, .untracked, .ignored, .unmerged, .unknown => false,
    };
}

fn statusEntryHasCurrentPath(entry: git_status.StatusEntry) bool {
    return entry.worktree != .deleted and !(entry.index == .deleted and !entry.isUnstaged());
}

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

fn expectRepositoryLocation(target: page_link.ReviewRepositoryTarget, expected_path: []const u8, expected_line: ?u32) !void {
    try std.testing.expect(target == .location);
    try std.testing.expectEqualStrings(expected_path, target.location.path);
    try std.testing.expectEqual(expected_line, target.location.line);
}

fn reviewContentTestView(page: *const review_page.ReviewPageState, source: diff_source.SourceMode) View {
    const review_navigation: navigation.View = .{
        .page = page,
        .repo_root = "/repo",
        .source = source,
        .layout = .{ .width = 100, .height = 30 },
    };
    return .{
        .page = page,
        .navigation = review_navigation,
        .source = source,
        .repo_root = "/repo",
    };
}

test "repository target maps only a direct unified current-side line" {
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/a b/a",
        .old_path = "a/a",
        .new_path = "b/a",
        .metadata = &.{},
        .hunks = &.{.{
            .old_start = 4,
            .old_count = 3,
            .new_start = 4,
            .new_count = 3,
            .section = "",
            .lines = &.{
                .{ .kind = .context, .text = "same", .old_line = 4, .new_line = 4 },
                .{ .kind = .removed, .text = "old", .old_line = 5 },
                .{ .kind = .added, .text = "new", .new_line = 5 },
            },
        }},
    };

    try expectRepositoryLocation(repositoryTargetForParsedFile(
        file,
        .{ .hunk_line = .{ .hunk_index = 0, .line_index = 0 } },
        .unified,
        .worktree,
        false,
    ), "a", 4);
    try expectRepositoryLocation(repositoryTargetForParsedFile(
        file,
        .{ .hunk_line = .{ .hunk_index = 0, .line_index = 1 } },
        .unified,
        .worktree,
        false,
    ), "a", null);
    try expectRepositoryLocation(repositoryTargetForParsedFile(
        file,
        .{ .hunk_header = 0 },
        .unified,
        .worktree,
        false,
    ), "a", null);
}

test "repository target side-by-side pair uses added line but pure removal has none" {
    const paired: diff_parser.FileDiff = .{
        .header = "diff --git a/a b/a",
        .old_path = "a/a",
        .new_path = "b/a",
        .metadata = &.{},
        .hunks = &.{.{
            .old_start = 7,
            .old_count = 1,
            .new_start = 7,
            .new_count = 1,
            .section = "",
            .lines = &.{
                .{ .kind = .removed, .text = "old", .old_line = 7 },
                .{ .kind = .added, .text = "new", .new_line = 7 },
            },
        }},
    };
    try expectRepositoryLocation(repositoryTargetForParsedFile(
        paired,
        .{ .hunk_line = .{ .hunk_index = 0, .line_index = 0 } },
        .side_by_side,
        .worktree,
        false,
    ), "a", 7);

    const removed_only: diff_parser.FileDiff = .{
        .header = "diff --git a/a b/a",
        .old_path = "a/a",
        .new_path = "b/a",
        .metadata = &.{},
        .hunks = &.{.{
            .old_start = 9,
            .old_count = 1,
            .new_start = 9,
            .new_count = 0,
            .section = "",
            .lines = &.{.{ .kind = .removed, .text = "gone", .old_line = 9 }},
        }},
    };
    try expectRepositoryLocation(repositoryTargetForParsedFile(
        removed_only,
        .{ .hunk_line = .{ .hunk_index = 0, .line_index = 0 } },
        .side_by_side,
        .worktree,
        false,
    ), "a", null);
}

test "repository target distinguishes deleted path from removed row in extant file" {
    const deleted: diff_parser.FileDiff = .{
        .header = "diff --git a/old.zig b/old.zig",
        .old_path = "a/old.zig",
        .new_path = "/dev/null",
        .metadata = &.{"deleted file mode 100644"},
        .hunks = &.{.{
            .old_start = 1,
            .old_count = 1,
            .new_start = 0,
            .new_count = 0,
            .section = "",
            .lines = &.{.{ .kind = .removed, .text = "gone", .old_line = 1 }},
        }},
    };
    const target = repositoryTargetForParsedFile(
        deleted,
        .{ .hunk_line = .{ .hunk_index = 0, .line_index = 0 } },
        .unified,
        .worktree,
        false,
    );
    try std.testing.expect(target == .unavailable);
    try std.testing.expectEqualStrings("old.zig", target.unavailable.path);
    try std.testing.expectEqual(page_link.RepositoryUnavailableReason.no_current_path, target.unavailable.reason);
}

test "repository target uses metadata-only rename current path" {
    const renamed: diff_parser.FileDiff = .{
        .header = "diff --git a/old.zig b/new.zig",
        .old_path = null,
        .new_path = null,
        .metadata = &.{ "rename from old.zig", "rename to new.zig" },
        .hunks = &.{},
    };
    try expectRepositoryLocation(repositoryTargetForParsedFile(
        renamed,
        .{ .metadata = 0 },
        .unified,
        .worktree,
        false,
    ), "new.zig", null);
}

test "cached line eligibility is a closed porcelain worktree-space set" {
    try std.testing.expect(cachedStatusAllowsCurrentLine(.{
        .path = "a",
        .raw = .{ 'M', ' ' },
        .index = .modified,
        .worktree = .unmodified,
    }));
    try std.testing.expect(cachedStatusAllowsCurrentLine(.{
        .path = "a",
        .raw = .{ 'A', ' ' },
        .index = .added,
        .worktree = .unmodified,
    }));
    try std.testing.expect(!cachedStatusAllowsCurrentLine(.{
        .path = "a",
        .raw = .{ 'M', 'M' },
        .index = .modified,
        .worktree = .modified,
    }));
    try std.testing.expect(!cachedStatusAllowsCurrentLine(.{
        .path = "a",
        .raw = .{ 'D', ' ' },
        .index = .deleted,
        .worktree = .unmodified,
    }));
    try std.testing.expect(!cachedStatusAllowsCurrentLine(.{
        .path = "a",
        .raw = .{ 'U', 'U' },
        .index = .unmerged,
        .worktree = .unmerged,
    }));
    try std.testing.expect(!cachedStatusAllowsCurrentLine(.{
        .path = "a",
        .raw = .{ 'T', ' ' },
        .index = .unknown,
        .worktree = .unmodified,
    }));
    try std.testing.expect(!cachedStatusAllowsCurrentLine(.{
        .path = "a",
        .raw = .{ '?', '?' },
        .index = .unmodified,
        .worktree = .untracked,
    }));
}

test "cached and synthetic parsed targets never claim an unproven line" {
    const file = test_support.file_with_hunks;
    const cursor: diff_view_model.BodyCoordinate = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 0 } };
    try expectRepositoryLocation(repositoryTargetForParsedFile(file, cursor, .unified, .cached, false), "a", null);
    try expectRepositoryLocation(repositoryTargetForParsedFile(file, cursor, .unified, .cached, true), "a", 1);
    try expectRepositoryLocation(repositoryTargetForParsedFile(file, cursor, .unified, .synthetic, true), "a", null);
}

test "generated target maps only a real source row" {
    try expectRepositoryLocation(generatedRepositoryTarget("new.zig", 3, .{ .metadata = 1 }), "new.zig", 2);
    try expectRepositoryLocation(generatedRepositoryTarget("new.zig", 0, .{ .metadata = 0 }), "new.zig", null);
    try expectRepositoryLocation(generatedRepositoryTarget("new.zig", 3, .{ .hunk_header = 0 }), "new.zig", null);
}

test "opaque status target distinguishes current path from deletion" {
    try std.testing.expect(statusEntryHasCurrentPath(.{
        .path = "current.zig",
        .raw = .{ 'M', ' ' },
        .index = .modified,
        .worktree = .unmodified,
    }));
    try std.testing.expect(!statusEntryHasCurrentPath(.{
        .path = "deleted.zig",
        .raw = .{ ' ', 'D' },
        .index = .unmodified,
        .worktree = .deleted,
    }));
    try std.testing.expect(!statusEntryHasCurrentPath(.{
        .path = "staged-delete.zig",
        .raw = .{ 'D', ' ' },
        .index = .deleted,
        .worktree = .unmodified,
    }));
    try std.testing.expect(statusEntryHasCurrentPath(.{
        .path = "recreated.zig",
        .raw = .{ 'D', 'M' },
        .index = .deleted,
        .worktree = .modified,
    }));
}

test "Review repository target reads accepted primary body without editor fallback" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{
            .selected_target = .{ .diff_file = 0 },
            .diff_cursor = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 0 } },
            .display_mode = .unified,
        },
    };
    defer page.deinit(allocator);
    _ = page.activation.activate(4, .fresh, .fresh, .fresh);

    var view = reviewContentTestView(&page, .unstaged);
    try expectRepositoryLocation(view.repositoryTarget(), "a", 1);

    page.viewer.diff_cursor = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 2 } };
    try expectRepositoryLocation(view.repositoryTarget(), "a", null);

    page.activation.deactivate();
    try std.testing.expect(view.repositoryTarget() == .no_context);
    _ = page.activation.activate(4, .fresh, .fresh, .fresh);
    view.source = .{ .range = "HEAD~1..HEAD" };
    view.navigation.source = view.source;
    try std.testing.expect(view.repositoryTarget() == .no_context);
}

test "Review cached target requires fresh exact status with no worktree change" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{
            .selected_target = .{ .diff_file = 0 },
            .diff_cursor = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 0 } },
            .display_mode = .unified,
        },
    };
    defer page.deinit(allocator);
    _ = page.activation.activate(4, .fresh, .fresh, .fresh);

    var clean_status = try git_status.StatusBundle.parseOwned(allocator, "M  a\x00");
    try page.git_status.replace("/repo", &clean_status);
    const view = reviewContentTestView(&page, .cached);
    try expectRepositoryLocation(view.repositoryTarget(), "a", 1);

    var changed_status = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try page.git_status.replace("/repo", &changed_status);
    try expectRepositoryLocation(view.repositoryTarget(), "a", null);

    page.status_load.freshness = .stale_refresh;
    try expectRepositoryLocation(view.repositoryTarget(), "a", null);
}

test "Review repository target reports accepted deleted file as unavailable" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffTwoWithStatuses()),
        .viewer = .{
            .selected_target = .{ .diff_file = 1 },
            .selected_file = 1,
            .selected_node = 1,
            .diff_cursor = .{ .metadata = 0 },
            .display_mode = .unified,
        },
    };
    defer page.deinit(allocator);
    _ = page.activation.activate(4, .fresh, .fresh, .fresh);

    const target = reviewContentTestView(&page, .unstaged).repositoryTarget();
    try std.testing.expect(target == .unavailable);
    try std.testing.expectEqualStrings("src/deleted.zig", target.unavailable.path);
}

fn installStatusBody(
    page: *review_page.ReviewPageState,
    allocator: std.mem.Allocator,
    path: []const u8,
    kind: review_projection.Kind,
) !void {
    const request = try review_projection.cloneRequest(
        allocator,
        app_page.RequestIdentity.review(4, 1),
        1,
        "/repo",
        path,
        kind,
        .unstaged,
        page.source_session_revision,
        page.status_snapshot_revision,
    );
    errdefer {
        var owned_request = request;
        owned_request.deinit(allocator);
    }
    page.review_projection.displayed = .{ .ready = .{
        .request = request,
        .value = .{ .status_body = try review_projection.statusBodyAlloc(allocator, path, "Preview unavailable", .{}) },
    } };
}

fn reviewReloadTestController(
    page: *review_page.ReviewPageState,
    status: *app_state.StatusMessage,
) review_reload.Controller {
    return .{
        .page = page,
        .navigation = .{
            .page = page,
            .repo_root = "/repo",
            .source = .unstaged,
            .layout = .{ .width = 100, .height = 30 },
            .diagnostics = .{ .target = status },
        },
        .source = .unstaged,
        .repo_root = "/repo",
        .repo_epoch = 4,
    };
}

test "Review opaque status target preserves selected duplicate-path entry identity" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .viewer = .{ .selected_target = .{ .status_only = 1 } },
    };
    defer page.deinit(allocator);
    _ = page.activation.activate(4, .fresh, .fresh, .fresh);
    try installStatusBody(&page, allocator, "f", .generated_added_file);

    var deleted_then_untracked = try git_status.StatusBundle.parseOwned(allocator, "D  f\x00?? f\x00");
    try page.git_status.replace("/repo", &deleted_then_untracked);
    try expectRepositoryLocation(reviewContentTestView(&page, .unstaged).repositoryTarget(), "f", null);

    var untracked_then_deleted = try git_status.StatusBundle.parseOwned(allocator, "?? f\x00D  f\x00");
    try page.git_status.replace("/repo", &untracked_then_deleted);
    page.viewer.selected_target = .{ .status_only = 0 };
    try expectRepositoryLocation(reviewContentTestView(&page, .unstaged).repositoryTarget(), "f", null);

    page.viewer.selected_target = .{ .status_only = 1 };
    try std.testing.expect(reviewContentTestView(&page, .unstaged).repositoryTarget() == .no_context);

    var status: app_state.StatusMessage = .{};
    const reload = reviewReloadTestController(&page, &status);
    var update = try reload.prepareProjection(allocator);
    defer update.deinit(allocator);
    try std.testing.expect(page.review_projection.pending != null);
    try std.testing.expectEqual(review_projection.Kind.cached_diff, page.review_projection.pending.?.kind);
    try std.testing.expect(page.review_projection.displayed == .ready);
    try std.testing.expect(page.review_projection.displayed.ready.value == .status_body);
    try std.testing.expect(reviewContentTestView(&page, .unstaged).repositoryTarget() == .no_context);

    var command = update.takeCommand() orelse return error.TestExpectedEqual;
    var command_owned = true;
    defer if (command_owned) command.deinit(allocator);
    var task_request = switch (command) {
        .review_projection => |request| request,
        else => return error.TestExpectedEqual,
    };
    command_owned = false;
    var request_owned = true;
    defer if (request_owned) task_request.deinit(allocator);
    var failed_body = try review_projection.statusBodyAlloc(allocator, "f", "Cached preview unavailable", .{});
    var finished: review_projection.Finished = .{
        .request = task_request,
        .result = .{ .failed = failed_body },
    };
    request_owned = false;
    task_request = undefined;
    failed_body = undefined;
    var result_transferred = false;
    defer if (!result_transferred) finished.deinit(allocator);
    result_transferred = (try reload.applyProjectionFinished(allocator, &finished)).result_transferred;
    try std.testing.expect(result_transferred);

    const deleted_target = reviewContentTestView(&page, .unstaged).repositoryTarget();
    try std.testing.expect(deleted_target == .unavailable);
    try std.testing.expectEqualStrings("f", deleted_target.unavailable.path);
    try std.testing.expectEqual(page_link.RepositoryUnavailableReason.no_current_path, deleted_target.unavailable.reason);
}

test "Review projection target rejects retained ready body while same path successor is pending" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .viewer = .{ .selected_target = .{ .status_only = 1 } },
    };
    defer page.deinit(allocator);
    _ = page.activation.activate(4, .fresh, .fresh, .fresh);

    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "D  f\x00?? f\x00");
    try page.git_status.replace("/repo", &status_bundle);
    const request = try review_projection.cloneRequest(
        allocator,
        app_page.RequestIdentity.review(4, 1),
        1,
        "/repo",
        "f",
        .generated_added_file,
        .unstaged,
        page.source_session_revision,
        page.status_snapshot_revision,
    );
    errdefer {
        var owned_request = request;
        owned_request.deinit(allocator);
    }
    page.review_projection.displayed = .{ .ready = .{
        .request = request,
        .value = .{ .generated_added_file = try review_projection.generatedFileFromContent(allocator, "f", "current\n") },
    } };
    try expectRepositoryLocation(reviewContentTestView(&page, .unstaged).repositoryTarget(), "f", 1);

    page.viewer.selected_target = .{ .status_only = 0 };
    var status: app_state.StatusMessage = .{};
    var update = try reviewReloadTestController(&page, &status).prepareProjection(allocator);
    defer update.deinit(allocator);

    try std.testing.expect(page.review_projection.pending != null);
    try std.testing.expectEqual(review_projection.Kind.cached_diff, page.review_projection.pending.?.kind);
    try std.testing.expect(page.review_projection.displayed == .ready);
    try std.testing.expect(page.review_projection.displayed.ready.value == .generated_added_file);
    try std.testing.expect(reviewContentTestView(&page, .unstaged).repositoryTarget() == .no_context);
}
