const std = @import("std");
const diff_parser = @import("diff/parser.zig");
const diff_render = @import("diff/render.zig");
const diff_view_model = @import("diff/view_model.zig");
const file_tree = @import("file_tree.zig");
const sidebar_view_model = @import("sidebar_view_model.zig");

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

    pub fn rebuildVisibleNodes(
        self: *LoadedDiff,
        allocator: std.mem.Allocator,
        hide_reviewed: bool,
        status_filter: ChangedFileFilter,
    ) !void {
        if (self.visible_nodes.len < self.tree.nodes.len) {
            self.visible_nodes = try allocator.alloc(usize, self.tree.nodes.len);
        }

        var count: usize = 0;
        for (self.tree.nodes, 0..) |_, index| {
            if (!self.shouldIncludeVisibleNode(index, hide_reviewed, status_filter)) continue;
            self.visible_nodes[count] = index;
            count += 1;
        }
        self.visible_node_count = count;
    }

    fn shouldIncludeVisibleNode(self: *const LoadedDiff, node_index: usize, hide_reviewed: bool, status_filter: ChangedFileFilter) bool {
        if (!self.tree.isVisible(node_index, &self.collapsed_dirs)) return false;
        if (!hide_reviewed and status_filter == .all) return true;

        const node = self.tree.nodes[node_index];
        return switch (node.kind) {
            .file => self.shouldIncludeFileNode(node_index, hide_reviewed, status_filter),
            .directory => self.hasMatchingFileDescendant(node_index, hide_reviewed, status_filter),
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
        const file_index = self.tree.nodes[node_index].file_index orelse return false;
        return file_index < self.reviewed_files.len and self.reviewed_files[file_index];
    }

    fn hasMatchingFileDescendant(self: *const LoadedDiff, directory_index: usize, hide_reviewed: bool, status_filter: ChangedFileFilter) bool {
        if (directory_index >= self.tree.nodes.len) return false;

        const directory = self.tree.nodes[directory_index];
        if (directory.kind != .directory) return false;

        for (self.tree.nodes, 0..) |node, index| {
            if (node.kind != .file) continue;
            if (!file_tree.isPathAncestor(directory.path, node.path)) continue;
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

    pub fn sidebarRowAt(self: *const LoadedDiff, visible_index: usize, selected_node: usize) ?sidebar_view_model.Row {
        // This is still a small projection into sidebar view-model rows. If the
        // sidebar renderer grows, move this projection to the sidebar layer and
        // keep LoadedDiff focused on visible node access.
        if (self.materializedVisibleNodes()) |nodes| {
            return sidebar_view_model.visibleRowAt(self.tree, &self.collapsed_dirs, self.reviewed_files, nodes, visible_index, selected_node);
        }

        const node_index = self.visibleNodeAt(visible_index) orelse return null;
        return sidebar_view_model.rowForNode(self.tree, &self.collapsed_dirs, self.reviewed_files, node_index, selected_node);
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
                if (candidate.kind != .directory) continue;
                if (candidate.depth >= node.depth) continue;
                if (!file_tree.isPathAncestor(candidate.path, node.path)) continue;
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
            if (self.tree.nodes[node_index].file_index != null) return node_index;
        }
        return null;
    }
};
