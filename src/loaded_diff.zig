const std = @import("std");
const ui = @import("chasen_ui");
const diff_parser = @import("diff/parser.zig");
const diff_render = @import("diff/render.zig");
const diff_view_model = @import("diff/view_model.zig");
const file_tree = @import("file_tree.zig");
const syntax_provider = @import("syntax/provider.zig");
const text_eligibility = @import("diff/text_eligibility.zig");

pub const FileTextEligibility = text_eligibility.FileTextEligibility;

pub const ChangedFileFilter = enum {
    all,
    modified,
    added,
    deleted,
    renamed,
    binary,

    pub fn next(self: ChangedFileFilter) ChangedFileFilter {
        return switch (self) {
            .all => .modified,
            .modified => .added,
            .added => .deleted,
            .deleted => .renamed,
            .renamed => .binary,
            .binary => .all,
        };
    }

    pub fn label(self: ChangedFileFilter) []const u8 {
        return switch (self) {
            .all => "all changes",
            .modified => "modified only",
            .added => "added only",
            .deleted => "deleted only",
            .renamed => "renamed only",
            .binary => "binary only",
        };
    }

    pub fn matches(self: ChangedFileFilter, status: ?file_tree.Status) bool {
        return switch (self) {
            .all => true,
            .modified => status == .modified,
            .added => status == .added,
            .deleted => status == .deleted,
            .renamed => status == .renamed,
            .binary => status == .binary,
        };
    }
};

/// Active parsed diff plus the UI-derived indexes for the current document.
///
/// The parser owns the immutable diff data in an arena. This type keeps the
/// mutable, per-load view state that is cheap to discard on reload.
pub const LoadedDiff = struct {
    text: []const u8,
    document: diff_parser.DiffDocument,
    /// Required total sidecar aligned exactly with `document.files`.
    ///
    /// Invalid UTF-8 paths remain byte-exact; only body text classification
    /// controls entry into Unicode-aware rendering and interaction paths.
    file_text_eligibility: []const FileTextEligibility,
    syntax_spans: syntax_provider.DocumentSpans = .empty(),
    tree: file_tree.FileTree,
    /// Rendered row prefix cache for O(1) counts and viewport start lookup.
    rendered_line_cache: diff_view_model.RenderedLineCache = .{},
    collapsed_dirs: file_tree.CollapsedSet = .empty,
    /// Flat hunk fold state. hunkOrdinal(file, hunk) maps file-local hunks into
    /// this array so the state can stay compact and cache-friendly.
    collapsed_hunks: []bool = &.{},
    /// Active-load cache materialized from the session reviewed store. The
    /// store is the source of truth; this slice keeps sidebar filtering O(1).
    reviewed_files: []bool = &.{},
    /// Visible tree node indexes after fold/filter/reviewed rules are applied.
    /// Rebuild only when those rules change, not on every frame.
    visible_nodes: []usize = &.{},
    visible_node_count: usize = 0,
    bytes: usize,
    lines: usize,

    pub fn fileTextEligibility(self: *const LoadedDiff, file_index: usize) FileTextEligibility {
        std.debug.assert(self.file_text_eligibility.len == self.document.files.len);
        std.debug.assert(file_index < self.file_text_eligibility.len);
        return self.file_text_eligibility[file_index];
    }

    pub fn fileTextSelectable(self: *const LoadedDiff, file_index: usize) bool {
        return self.fileTextEligibility(file_index).selectable();
    }

    pub fn rebuildVisibleNodes(
        self: *LoadedDiff,
        allocator: std.mem.Allocator,
        hide_reviewed: bool,
        status_filter: ChangedFileFilter,
    ) !void {
        var prepared = try self.prepareVisibleNodeRebuild(allocator);
        prepared.commit(hide_reviewed, status_filter);
    }

    /// Prepare rebuild storage without publishing it as the active
    /// materialization. Dropping the returned value is a semantic no-op; its
    /// commit method installs only a completely populated candidate.
    pub fn prepareVisibleNodeRebuild(self: *LoadedDiff, allocator: std.mem.Allocator) !PreparedVisibleNodeRebuild {
        const candidate = if (self.visible_nodes.len >= self.tree.nodes.len)
            self.visible_nodes
        else
            try allocator.alloc(usize, self.tree.nodes.len);
        return .{
            .target = self,
            .candidate = candidate,
            .tree_node_count = self.tree.nodes.len,
        };
    }

    fn shouldIncludeVisibleNode(self: *const LoadedDiff, node_index: usize, hide_reviewed: bool, status_filter: ChangedFileFilter) bool {
        if (!self.tree.isVisible(node_index, &self.collapsed_dirs)) return false;
        if (!hide_reviewed and status_filter == .all) return true;

        const node = self.tree.nodes[node_index];
        return switch (node.kind) {
            .file => self.shouldIncludeFileNode(node_index, hide_reviewed, status_filter),
            .repo_root, .directory => self.hasMatchingFileDescendant(node_index, hide_reviewed, status_filter),
        };
    }

    pub fn shouldIncludeFileNode(self: *const LoadedDiff, node_index: usize, hide_reviewed: bool, status_filter: ChangedFileFilter) bool {
        if (hide_reviewed and self.isReviewedFileNode(node_index)) return false;
        return status_filter.matches(self.tree.nodes[node_index].status);
    }

    pub fn isFileReviewedNode(self: *const LoadedDiff, node_index: usize) bool {
        if (node_index >= self.tree.nodes.len) return false;
        return self.isReviewedFileNode(node_index);
    }

    fn isReviewedFileNode(self: *const LoadedDiff, node_index: usize) bool {
        const file_index = self.tree.nodes[node_index].diffFileIndex() orelse return false;
        return file_index < self.reviewed_files.len and self.reviewed_files[file_index];
    }

    fn hasMatchingFileDescendant(self: *const LoadedDiff, directory_index: usize, hide_reviewed: bool, status_filter: ChangedFileFilter) bool {
        if (directory_index >= self.tree.nodes.len) return false;

        const directory = self.tree.nodes[directory_index];
        if (directory.kind != .directory and directory.kind != .repo_root) return false;

        for (self.tree.nodes, 0..) |node, index| {
            if (node.kind != .file) continue;
            if (directory.kind == .directory and !file_tree.isPathAncestor(directory.path, node.path)) continue;
            if (self.shouldIncludeFileNode(index, hide_reviewed, status_filter)) return true;
        }
        return false;
    }

    pub fn materializedVisibleNodes(self: *const LoadedDiff) ?[]const usize {
        // Production load always calls rebuildVisibleNodes. The fallback keeps
        // tests that construct LoadedDiff directly on the old tree traversal.
        if (self.visible_nodes.len == 0 and self.tree.nodes.len > 0) return null;
        return self.visible_nodes[0..self.visible_node_count];
    }

    pub fn visibleNodeCount(self: *const LoadedDiff) usize {
        if (self.materializedVisibleNodes()) |nodes| return nodes.len;
        return self.tree.visibleNodeCount(&self.collapsed_dirs);
    }

    pub fn visibleNodeAt(self: *const LoadedDiff, visible_index: usize) ?usize {
        if (self.materializedVisibleNodes()) |nodes| {
            return if (visible_index < nodes.len) nodes[visible_index] else null;
        }
        return self.tree.visibleNodeAt(&self.collapsed_dirs, visible_index);
    }

    pub fn sidebarVisibleRange(self: *const LoadedDiff, selected_node: usize, visible_rows: usize) ui.ListViewport.Range {
        const selected_row = self.visibleRowOfNode(selected_node) orelse 0;
        return ui.ListViewport.visibleRange(self.visibleNodeCount(), selected_row, visible_rows);
    }

    pub fn sidebarNodeAtBodyRow(self: *const LoadedDiff, selected_node: usize, visible_rows: usize, body_row: usize) ?usize {
        if (body_row >= visible_rows) return null;
        const range = self.sidebarVisibleRange(selected_node, visible_rows);
        const visible_index = range.start + body_row;
        if (visible_index >= range.end) return null;
        return self.visibleNodeAt(visible_index);
    }

    pub fn renderedLineIndex(self: *const LoadedDiff, file_index: usize, mode: diff_render.DisplayMode) diff_view_model.RenderedLineIndex {
        if (self.rendered_line_cache.indexFor(file_index, mode)) |index| return index;
        if (file_index >= self.document.files.len) return .{ .mode = mode };

        const file = self.document.files[file_index];
        return .{
            .mode = mode,
            .total_rows = diff_view_model.renderedBodyLineCountFolded(file, mode, self.foldedHunksForFile(file_index)),
        };
    }

    pub fn cachedRenderedLineIndex(self: *const LoadedDiff, file_index: usize, mode: diff_render.DisplayMode) ?diff_view_model.RenderedLineIndex {
        return self.rendered_line_cache.indexFor(file_index, mode);
    }

    pub fn foldedHunksForFile(self: *const LoadedDiff, file_index: usize) []const bool {
        const start = self.hunkOrdinal(file_index, 0) orelse return &.{};
        if (file_index >= self.document.files.len) return &.{};
        const len = self.document.files[file_index].hunks.len;
        if (start + len > self.collapsed_hunks.len) return &.{};
        return self.collapsed_hunks[start .. start + len];
    }

    fn hunkOrdinal(self: *const LoadedDiff, file_index: usize, hunk_index: usize) ?usize {
        if (file_index >= self.document.files.len) return null;
        if (hunk_index >= self.document.files[file_index].hunks.len) return null;
        var ordinal: usize = 0;
        for (self.document.files[0..file_index]) |file| ordinal += file.hunks.len;
        return ordinal + hunk_index;
    }

    pub fn isHunkFolded(self: *const LoadedDiff, file_index: usize, hunk_index: usize) bool {
        const ordinal = self.hunkOrdinal(file_index, hunk_index) orelse return false;
        return ordinal < self.collapsed_hunks.len and self.collapsed_hunks[ordinal];
    }

    pub fn toggleHunkFold(self: *LoadedDiff, file_index: usize, hunk_index: usize) void {
        self.setHunkFolded(file_index, hunk_index, !self.isHunkFolded(file_index, hunk_index));
    }

    pub fn setHunkFolded(self: *LoadedDiff, file_index: usize, hunk_index: usize, folded: bool) void {
        const ordinal = self.hunkOrdinal(file_index, hunk_index) orelse return;
        if (ordinal >= self.collapsed_hunks.len) return;
        if (self.collapsed_hunks[ordinal] == folded) return;
        self.collapsed_hunks[ordinal] = folded;
        self.rendered_line_cache.recomputeFile(self.document, file_index, self.foldedHunksForFile(file_index));
    }

    pub fn visibleRowOfNode(self: *const LoadedDiff, node_index: usize) ?usize {
        if (self.materializedVisibleNodes()) |nodes| {
            for (nodes, 0..) |index, row| {
                if (index == node_index) return row;
            }
            return null;
        }
        return self.tree.visibleRowOfNode(&self.collapsed_dirs, node_index);
    }

    pub fn nextVisibleNodeIndex(self: *const LoadedDiff, node_index: usize) ?usize {
        const row = self.visibleRowOfNode(node_index) orelse
            return self.tree.nextVisibleNodeIndex(&self.collapsed_dirs, node_index);
        return self.visibleNodeAt(row + 1);
    }

    pub fn previousVisibleNodeIndex(self: *const LoadedDiff, node_index: usize) ?usize {
        const row = self.visibleRowOfNode(node_index) orelse
            return self.tree.previousVisibleNodeIndex(&self.collapsed_dirs, node_index);
        if (row == 0) return null;
        return self.visibleNodeAt(row - 1);
    }

    pub fn visibleAncestorOrSelf(self: *const LoadedDiff, node_index: usize) ?usize {
        if (self.visibleRowOfNode(node_index) != null) return node_index;
        if (self.materializedVisibleNodes() != null) {
            if (node_index >= self.tree.nodes.len) return null;
            const node = self.tree.nodes[node_index];
            var index = node_index;
            while (index > 0) {
                index -= 1;
                const candidate = self.tree.nodes[index];
                if (candidate.kind != .directory and candidate.kind != .repo_root) continue;
                if (candidate.depth >= node.depth) continue;
                if (candidate.kind == .directory and !file_tree.isPathAncestor(candidate.path, node.path)) continue;
                if (self.visibleRowOfNode(index) != null) return index;
            }
            return null;
        }
        return self.tree.visibleAncestorOrSelf(&self.collapsed_dirs, node_index);
    }

    pub fn firstVisibleFileNode(self: *const LoadedDiff) ?usize {
        const count = self.visibleNodeCount();
        var visible_index: usize = 0;
        while (visible_index < count) : (visible_index += 1) {
            const node_index = self.visibleNodeAt(visible_index) orelse continue;
            if (self.tree.nodes[node_index].diffFileIndex() != null) return node_index;
        }
        return null;
    }
};

/// Move-only-by-convention rebuild transaction returned only by
/// `LoadedDiff.prepareVisibleNodeRebuild`.
///
/// The captured node count closes the candidate-capacity obligation at
/// preparation time. FileTree nodes are immutable for a LoadedDiff session.
const PreparedVisibleNodeRebuild = struct {
    target: *LoadedDiff,
    candidate: []usize,
    tree_node_count: usize,

    pub fn commit(self: *PreparedVisibleNodeRebuild, hide_reviewed: bool, status_filter: ChangedFileFilter) void {
        const target = self.target;
        const candidate = self.candidate;
        var count: usize = 0;
        for (0..self.tree_node_count) |index| {
            if (!target.shouldIncludeVisibleNode(index, hide_reviewed, status_filter)) continue;
            candidate[count] = index;
            count += 1;
        }
        target.visible_nodes = candidate;
        target.visible_node_count = count;
        self.* = undefined;
    }
};

test "repository root visibility follows filtered file descendants" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const nodes = [_]file_tree.Node{
        .{ .kind = .repo_root, .name = "repo", .path = "", .depth = 0, .target = .repo_root },
        .{ .kind = .file, .name = "added.zig", .path = "added.zig", .depth = 1, .status = .added, .target = .{ .diff_file = 0 } },
        .{ .kind = .file, .name = "deleted.zig", .path = "deleted.zig", .depth = 1, .status = .deleted, .target = .{ .diff_file = 1 } },
    };

    var loaded: LoadedDiff = .{
        .text = "",
        .document = .{ .files = &.{} },
        .file_text_eligibility = &.{},
        .tree = .{ .nodes = &nodes },
        .bytes = 0,
        .lines = 0,
    };

    try loaded.rebuildVisibleNodes(allocator, false, .added);
    try std.testing.expectEqual(@as(usize, 2), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(usize, 0), loaded.visibleNodeAt(0).?);
    try std.testing.expectEqual(@as(usize, 1), loaded.visibleNodeAt(1).?);

    try loaded.rebuildVisibleNodes(allocator, false, .modified);
    try std.testing.expectEqual(@as(usize, 0), loaded.visibleNodeCount());
}

test "visible node rebuild preparation failure preserves the retained materialization" {
    const nodes = [_]file_tree.Node{
        .{ .kind = .file, .name = "a", .path = "a", .depth = 0, .target = .{ .diff_file = 0 } },
        .{ .kind = .file, .name = "b", .path = "b", .depth = 0, .target = .{ .diff_file = 1 } },
    };
    var retained = [_]usize{7};
    var loaded: LoadedDiff = .{
        .text = "",
        .document = .{ .files = &.{} },
        .file_text_eligibility = &.{},
        .tree = .{ .nodes = &nodes },
        .visible_nodes = &retained,
        .visible_node_count = 1,
        .bytes = 0,
        .lines = 0,
    };
    const retained_ptr = loaded.visible_nodes.ptr;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });

    try std.testing.expectError(error.OutOfMemory, loaded.prepareVisibleNodeRebuild(failing.allocator()));

    try std.testing.expectEqual(retained_ptr, loaded.visible_nodes.ptr);
    try std.testing.expectEqual(@as(usize, 1), loaded.visible_node_count);
    try std.testing.expectEqual(@as(usize, 7), loaded.visible_nodes[0]);
}

test "discarded visible node rebuild preparation preserves active and fallback views" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const nodes = [_]file_tree.Node{
        .{ .kind = .file, .name = "a", .path = "a", .depth = 0, .target = .{ .diff_file = 0 } },
        .{ .kind = .file, .name = "b", .path = "b", .depth = 0, .target = .{ .diff_file = 1 } },
    };

    var retained = [_]usize{1};
    var active: LoadedDiff = .{
        .text = "",
        .document = .{ .files = &.{} },
        .file_text_eligibility = &.{},
        .tree = .{ .nodes = &nodes },
        .visible_nodes = &retained,
        .visible_node_count = 1,
        .bytes = 0,
        .lines = 0,
    };
    const retained_ptr = active.visible_nodes.ptr;
    _ = try active.prepareVisibleNodeRebuild(allocator);
    try std.testing.expectEqual(retained_ptr, active.visible_nodes.ptr);
    try std.testing.expectEqual(@as(usize, 1), active.visibleNodeCount());
    try std.testing.expectEqual(@as(?usize, 1), active.visibleNodeAt(0));

    var fallback: LoadedDiff = .{
        .text = "",
        .document = .{ .files = &.{} },
        .file_text_eligibility = &.{},
        .tree = .{ .nodes = &nodes },
        .bytes = 0,
        .lines = 0,
    };
    try std.testing.expectEqual(@as(?[]const usize, null), fallback.materializedVisibleNodes());
    _ = try fallback.prepareVisibleNodeRebuild(allocator);
    try std.testing.expectEqual(@as(?[]const usize, null), fallback.materializedVisibleNodes());
    try std.testing.expectEqual(@as(usize, 2), fallback.visibleNodeCount());
    try std.testing.expectEqual(@as(?usize, 0), fallback.visibleNodeAt(0));
    try std.testing.expectEqual(@as(?usize, 1), fallback.visibleNodeAt(1));
}

test "prepared visible node rebuild commits infallibly after fold changes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const nodes = [_]file_tree.Node{
        .{ .kind = .directory, .name = "src", .path = "src", .depth = 0 },
        .{ .kind = .file, .name = "main.zig", .path = "src/main.zig", .depth = 1, .target = .{ .diff_file = 0 } },
    };
    var loaded: LoadedDiff = .{
        .text = "",
        .document = .{ .files = &.{} },
        .file_text_eligibility = &.{},
        .tree = .{ .nodes = &nodes },
        .bytes = 0,
        .lines = 0,
    };

    var collapsed = try loaded.prepareVisibleNodeRebuild(allocator);
    try file_tree.collapse(allocator, &loaded.collapsed_dirs, "src");
    collapsed.commit(false, .all);
    try std.testing.expectEqual(@as(usize, 1), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(?usize, 0), loaded.visibleNodeAt(0));

    var expanded = try loaded.prepareVisibleNodeRebuild(allocator);
    file_tree.expandAncestors(&loaded.collapsed_dirs, "src/main.zig");
    expanded.commit(false, .all);
    try std.testing.expectEqual(@as(usize, 2), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(?usize, 1), loaded.visibleNodeAt(1));
}
