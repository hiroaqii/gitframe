//! Review-local navigation, search, folding, and mouse-selection ownership.
//!
//! App supplies committed repository/source identity plus shell-normalized content
//! geometry. This module never receives App, terminal-frame coordinates, overlays,
//! processes, or async effect handles. The small diagnostic capability preserves
//! existing user-facing search/fold messages without exposing broader shell state.

const std = @import("std");
const builtin = @import("builtin");
const chasen = @import("chasen");
const app_direction = @import("../../direction.zig");
const app_load = @import("../../load.zig");
const app_page = @import("../../page.zig");
const app_state = @import("../../state.zig");
const shell_layout = if (builtin.is_test) @import("../../shell_layout.zig") else struct {};
const review_layout = @import("layout.zig");
const review_message = @import("message.zig");
const review_projection = @import("../../review_projection.zig");
const app_review_projection = review_projection;
const review_page = @import("../review.zig");
const context = @import("../../../context.zig");
const diff_file = @import("../../../diff/file.zig");
const diff_hunk_projection = @import("../../../diff/hunk_projection.zig");
const diff_parser = @import("../../../diff/parser.zig");
const diff_render = @import("../../../diff/render.zig");
const diff_search = @import("../../../diff/search.zig");
const diff_selection = @import("../../../diff/selection.zig");
const diff_source = @import("../../../diff/source.zig");
const diff_view_model = @import("../../../diff/view_model.zig");
const file_tree = @import("../../../file_tree.zig");
const git_status = @import("../../../git/status.zig");
const loaded_diff = @import("../../../loaded_diff.zig");
const sidebar_view_model = @import("../../../sidebar/view_model.zig");
const test_support = if (builtin.is_test) @import("../../test_support.zig") else struct {};
const app_test_support = test_support;

const LoadedDiff = loaded_diff.LoadedDiff;
const ChangedFileFilter = loaded_diff.ChangedFileFilter;
const HorizontalDirection = app_direction.Horizontal;
const SizeDirection = app_direction.Size;
const VerticalDirection = app_direction.Vertical;

/// Geometry after the shell frame has converted terminal coordinates into the
/// active page content rectangle.
pub const Layout = struct { width: u16, height: u16 };

pub const DiagnosticSink = struct {
    target: *app_state.StatusMessage,

    fn set(self: DiagnosticSink, comptime fmt: []const u8, args: anytype) void {
        self.target.set(fmt, args);
    }
};

pub const MousePoint = review_message.MousePoint;

pub const DiffMouseHit = struct {
    identity: diff_selection.Identity,
    side: diff_selection.Side,
    point: diff_selection.Point,
};

pub const DiffHeaderTarget = struct {
    identity: diff_selection.HeaderIdentity,
    display_path: []const u8,
};

pub const DisplayNavigationSnapshot = struct {
    selected_target: ?context.SelectedTarget,
    selected_node: usize,
    diff_cursor: diff_view_model.BodyCoordinate,
    diff_scroll: usize,
    diff_horizontal_scroll: usize,
    sidebar_horizontal_scroll: usize,
    search_coordinate: ?diff_view_model.BodyCoordinate,
    search_match_offset: ?usize,
    display_mode: diff_render.DisplayMode,
};

pub const ActiveDiffDisplay = union(enum) {
    loaded: struct {
        file_index: usize,
        file: diff_parser.FileDiff,
        line_index: ?diff_view_model.RenderedLineIndex,
        folded_hunks: []const bool,
        staged_flags: []const bool,
    },
    combined_projection: struct {
        file: diff_parser.FileDiff,
        line_index: diff_view_model.RenderedLineIndex,
        staged_flags: []const bool,
        hunk_states: []const diff_hunk_projection.ProjectedHunkState,
    },

    pub fn file(self: ActiveDiffDisplay) diff_parser.FileDiff {
        return switch (self) {
            .loaded => |loaded| loaded.file,
            .combined_projection => |projection| projection.file,
        };
    }

    pub fn lineIndex(self: ActiveDiffDisplay) ?diff_view_model.RenderedLineIndex {
        return switch (self) {
            .loaded => |loaded| loaded.line_index,
            .combined_projection => |projection| projection.line_index,
        };
    }

    pub fn foldedHunks(self: ActiveDiffDisplay) []const bool {
        return switch (self) {
            .loaded => |loaded| loaded.folded_hunks,
            .combined_projection => &.{},
        };
    }

    pub fn stagedFlags(self: ActiveDiffDisplay) []const bool {
        return switch (self) {
            .loaded => |loaded| loaded.staged_flags,
            .combined_projection => |projection| projection.staged_flags,
        };
    }

    pub fn loadedFileIndex(self: ActiveDiffDisplay) ?usize {
        return switch (self) {
            .loaded => |loaded| loaded.file_index,
            .combined_projection => null,
        };
    }
};

pub const NormalLoadedDiffSelectionTarget = struct {
    file_index: usize,
    file: diff_parser.FileDiff,
    line_index: diff_view_model.RenderedLineIndex,
    folded_hunks: []const bool,
    identity: diff_selection.Identity,
};

pub const RawDiffPaneGeometry = struct { col: u16, width: u16 };

pub const SearchTarget = struct {
    file: diff_parser.FileDiff,
    line_index: diff_view_model.RenderedLineIndex,
    folded_hunks: []const bool,
};

pub const View = struct {
    page: *const review_page.ReviewPageState,
    repo_root: ?[]const u8,
    source: diff_source.SourceMode,
    layout: Layout,

    pub fn diffSelectionView(self: View) ?diff_selection.View {
        const selection = self.page.selection_owner.activeDiff() orelse return null;
        _ = self.normalLoadedDiffSelectionTarget(selection.identity) orelse return null;
        return selection.view();
    }

    pub fn diffHeaderSelectionActive(self: View) bool {
        const selection = self.page.selection_owner.activeHeader() orelse return false;
        _ = self.displayedDiffHeaderTarget(selection.identity) orelse return false;
        return true;
    }

    pub fn displayNavigationSnapshot(self: View) DisplayNavigationSnapshot {
        return .{
            .selected_target = self.page.viewer.selected_target,
            .selected_node = self.page.viewer.selected_node,
            .diff_cursor = self.page.viewer.diff_cursor,
            .diff_scroll = self.page.viewer.diff_scroll,
            .diff_horizontal_scroll = self.page.viewer.diff_horizontal_scroll,
            .sidebar_horizontal_scroll = self.page.viewer.sidebar_horizontal_scroll,
            .search_coordinate = if (self.page.search.match) |match| match.coordinate else null,
            .search_match_offset = self.page.search.match_offset,
            .display_mode = self.page.viewer.display_mode,
        };
    }

    pub fn normalLoadedDiffSelectionTarget(self: View, identity: ?diff_selection.Identity) ?NormalLoadedDiffSelectionTarget {
        if (self.selectedStatusEntry() != null) return null;
        if (self.activeGeneratedFileProjection() != null) return null;
        if (self.activeCombinedProjection() != null) return null;
        if (self.activeCachedDiffProjection() != null) return null;

        const loaded = self.activeLoadedDiffConst() orelse return null;
        const file_index = self.selectedFileIndex(loaded) orelse return null;
        if (file_index >= loaded.document.files.len) return null;
        const file = loaded.document.files[file_index];
        const path_key = diff_file.canonicalPathKey(file) orelse return null;
        const current_identity: diff_selection.Identity = .{ .loaded_file = .{
            .file_index = file_index,
            .path_key = path_key,
        } };
        if (identity) |expected| {
            if (!expected.eql(current_identity)) return null;
            if (!expected.matchesLoadedFile(file_index, file)) return null;
        }

        const mode = self.effectiveDisplayMode();
        return .{
            .file_index = file_index,
            .file = file,
            .line_index = loaded.cachedRenderedLineIndex(file_index, mode) orelse loaded.renderedLineIndex(file_index, mode),
            .folded_hunks = loaded.foldedHunksForFile(file_index),
            .identity = current_identity,
        };
    }

    pub fn displayedDiffHeaderTarget(self: View, expected: ?diff_selection.HeaderIdentity) ?DiffHeaderTarget {
        const target: DiffHeaderTarget = blk: {
            if (self.activeGeneratedFileProjection()) |bundle| {
                break :blk .{
                    .identity = .{ .kind = .generated_file, .path_key = bundle.path },
                    .display_path = bundle.path,
                };
            }
            if (self.activeCombinedProjection()) |bundle| {
                const path_key = diff_file.canonicalPathKey(bundle.projection.file) orelse return null;
                break :blk .{
                    .identity = .{ .kind = .projection_file, .path_key = path_key },
                    .display_path = diff_file.displayPath(bundle.projection.file),
                };
            }
            if (self.activeCachedDiffProjection()) |bundle| {
                if (bundle.loaded.document.files.len == 0) return null;
                const file = bundle.loaded.document.files[0];
                const path_key = diff_file.canonicalPathKey(file) orelse return null;
                break :blk .{
                    .identity = .{ .kind = .projection_file, .path_key = path_key },
                    .display_path = diff_file.displayPath(file),
                };
            }

            const loaded = self.activeLoadedDiffConst() orelse return null;
            const file_index = self.selectedFileIndex(loaded) orelse return null;
            if (file_index >= loaded.document.files.len) return null;
            const file = loaded.document.files[file_index];
            const path_key = diff_file.canonicalPathKey(file) orelse return null;
            break :blk .{
                .identity = .{ .kind = .loaded_file, .path_key = path_key },
                .display_path = diff_file.displayPath(file),
            };
        };

        if (expected) |identity| {
            if (!identity.eql(target.identity)) return null;
        }
        return target;
    }

    pub fn diffHeaderMouseHit(self: View, point: MousePoint) ?DiffHeaderTarget {
        const target = self.displayedDiffHeaderTarget(null) orelse return null;
        const raw_diff = self.rawDiffPaneGeometry() orelse return null;
        if (point.col < raw_diff.col or point.col >= raw_diff.col + raw_diff.width) return null;
        if (point.row != 0) return null;

        const local_col = point.col - raw_diff.col;
        const content_width = contentWidth(raw_diff.width);
        const content_gutter = raw_diff.width - content_width;
        if (local_col < content_gutter) return null;
        const render_col = local_col - content_gutter;
        if (render_col >= content_width) return null;

        const layout = self.displayedDiffHeaderLayout(content_width, target.display_path) orelse return null;
        const path_target = layout.path_target orelse return null;
        if (!path_target.contains(render_col)) return null;
        return target;
    }

    pub fn displayedDiffHeaderLayout(self: View, content_width: u16, display_path: []const u8) ?diff_render.HeaderLayout {
        const mode_width = diff_render.bodyWidth(content_width);
        if (self.activeGeneratedFileProjection()) |bundle| {
            return diff_render.generatedHeaderLayout(content_width, display_path, bundle.source.contentLineCount(), self.page.viewer.display_mode, mode_width);
        }
        const file = self.displayedDiffFile() orelse return null;
        return diff_render.fileHeaderLayout(content_width, display_path, file, self.page.viewer.display_mode, mode_width);
    }

    pub fn diffMouseHit(self: View, point: MousePoint) ?DiffMouseHit {
        const target = self.normalLoadedDiffSelectionTarget(null) orelse return null;
        const raw_diff = self.rawDiffPaneGeometry() orelse return null;
        if (point.col < raw_diff.col or point.col >= raw_diff.col + raw_diff.width) return null;
        if (point.row < diff_render.body_start_row) return null;

        const local_col = point.col - raw_diff.col;
        const content_width = contentWidth(raw_diff.width);
        const content_gutter = raw_diff.width - content_width;
        if (local_col < content_gutter) return null;
        const render_col = local_col - content_gutter;
        if (render_col >= content_width or render_col < diff_render.cursor_gutter_width) return null;

        const body_width = diff_render.bodyWidth(content_width);
        if (diff_render.effectiveMode(body_width, self.page.viewer.display_mode) != .side_by_side) return null;

        const body_col = render_col - diff_render.cursor_gutter_width;
        const geometry = diff_render.sideBySideGeometry(body_width);
        const side = geometry.sideAt(body_col) orelse return null;

        const visible_body_row: usize = point.row - diff_render.body_start_row;
        if (visible_body_row >= self.diffVisibleRows()) return null;
        const offset = self.page.viewer.diff_scroll + visible_body_row;
        const coordinate = diff_view_model.coordinateAtOffset(target.file, .side_by_side, offset, target.folded_hunks, target.line_index) orelse return null;
        const hunk_line = switch (coordinate) {
            .hunk_line => |line| line,
            .metadata, .binary_marker, .hunk_header => return null,
        };

        return .{
            .identity = target.identity,
            .side = side,
            .point = diff_selection.pointFromLine(hunk_line.hunk_index, hunk_line.line_index),
        };
    }

    pub fn rawDiffPaneGeometry(self: View) ?RawDiffPaneGeometry {
        const size = self.layout;
        if (size.width == 0) return null;
        if (self.page.viewer.sidebar_hidden) return .{ .col = 0, .width = size.width };

        const sidebar_width = sidebarWidth(size.width, self.page.viewer.sidebar_width);
        if (size.width <= sidebar_width + 1) return null;
        return .{
            .col = sidebar_width + 1,
            .width = size.width - sidebar_width - 1,
        };
    }

    pub fn fileTreeRootOptions(self: View) ?file_tree.RootOptions {
        const root = self.repo_root orelse return null;
        const base = std.fs.path.basename(root);
        return .{ .name = if (base.len == 0) root else base };
    }

    pub fn visibleSidebarMaxHorizontalScroll(self: View) usize {
        const loaded = self.activeLoadedDiffConst() orelse return 0;
        const width = sidebarWidth(self.layout.width, self.page.viewer.sidebar_width);
        const source = sidebar_view_model.Source{
            .tree = loaded.tree,
            .collapsed = &loaded.collapsed_dirs,
            .reviewed_files = loaded.reviewed_files,
            .visible_nodes = loaded.materializedVisibleNodes(),
        };

        var max_scroll: usize = 0;
        var visible_index: usize = 0;
        while (visible_index < loaded.visibleNodeCount()) : (visible_index += 1) {
            const row = sidebar_view_model.rowAt(source, visible_index, self.page.viewer.selected_node) orelse continue;
            max_scroll = @max(max_scroll, sidebar_view_model.maxHorizontalScroll(row, width));
        }
        return max_scroll;
    }

    pub fn visibleBodyTextMaxHorizontalScroll(self: View) usize {
        const file = self.selectedFile() orelse return 0;
        const mode = self.effectiveDisplayMode();
        const visible_rows = self.diffVisibleRows();
        if (visible_rows == 0) return 0;

        const pane_width = self.diffPaneWidth();
        const line_index = self.selectedFileCachedLineIndex(mode);
        var max_scroll: usize = 0;
        var rows = if (line_index) |index|
            diff_view_model.BodyRowIterator.initAtWithFolded(file, mode, index, self.page.viewer.diff_scroll, self.selectedFoldedHunks())
        else
            diff_view_model.BodyRowIterator.initWithFolded(file, mode, self.selectedFoldedHunks());
        var skipped: usize = if (line_index != null) self.page.viewer.diff_scroll else 0;
        var visible: usize = 0;
        while (rows.next()) |body_row| {
            if (skipped < self.page.viewer.diff_scroll) {
                skipped += 1;
                continue;
            }
            if (visible >= visible_rows) break;
            visible += 1;
            max_scroll = @max(max_scroll, maxHorizontalScrollForBodyRow(body_row, pane_width, self.page.viewer.view_options.line_numbers));
        }
        return max_scroll;
    }

    pub fn selectedProjectionLineCount(self: View) usize {
        if (self.selectedStatusEntry() == null) return 0;
        return switch (self.page.review_projection.displayed) {
            .ready => |ready| switch (ready.value) {
                .cached_diff => |bundle| if (bundle.loaded.document.files.len > 0)
                    if (bundle.loaded.cachedRenderedLineIndex(0, self.effectiveDisplayMode())) |index| index.lineCount() else 0
                else
                    0,
                .generated_added_file => |bundle| bundle.source.rowCount(),
                .combined_hunks => |bundle| bundle.projection.lineIndex(self.effectiveDisplayMode()).lineCount(),
                .status_body => 1,
            },
            .failed => 1,
            .idle => 0,
        };
    }

    pub fn remapDiffScrollForModeChange(
        self: View,
        old_mode: diff_render.DisplayMode,
        new_mode: diff_render.DisplayMode,
        old_scroll: usize,
    ) usize {
        if (old_mode == new_mode) return old_scroll;

        const old_index = self.selectedFileLineIndex(old_mode);
        const new_index = self.selectedFileLineIndex(new_mode);
        if (old_index.lineCount() == 0 or new_index.lineCount() == 0) return 0;

        const hunk_index = old_index.hunkIndexAtOffset(old_scroll) orelse {
            return @min(old_scroll, new_index.lineCount() - 1);
        };

        const old_hunk_offset = old_index.hunkOffset(hunk_index);
        const old_hunk_rows = old_index.hunkLineCount(hunk_index);
        const new_hunk_offset = new_index.hunkOffset(hunk_index);
        const new_hunk_rows = new_index.hunkLineCount(hunk_index);
        if (old_hunk_rows == 0 or new_hunk_rows == 0) return @min(new_hunk_offset, new_index.lineCount() - 1);

        const old_local = @min(old_scroll - old_hunk_offset, old_hunk_rows - 1);
        const new_local = if (old_hunk_rows <= 1)
            0
        else
            old_local * (new_hunk_rows - 1) / (old_hunk_rows - 1);
        return @min(new_hunk_offset + new_local, new_index.lineCount() - 1);
    }

    pub fn unsupportedSearchMessage(self: View) ?[]const u8 {
        if (self.activeCombinedProjection() != null) {
            return "search is unavailable for mixed staged/unstaged view";
        }
        if (self.activeGeneratedFileProjection() != null) {
            return "search is unavailable for generated file preview";
        }
        if (self.activeCachedDiffProjection() != null) {
            if (self.selectedStatusEntry()) |entry| {
                if (entry.index == .added and !entry.isUnstaged()) {
                    return "search is unavailable for staged new file preview";
                }
            }
        }
        return null;
    }

    pub fn currentSearchMatchInHunkBody(self: View, hunk_index: usize) bool {
        const match = self.page.search.match orelse return false;
        return switch (match.coordinate) {
            .hunk_line => |line| line.hunk_index == hunk_index,
            else => false,
        };
    }

    pub fn currentSelection(self: View) ?context.Selection {
        const target = self.page.viewer.selected_target orelse return null;
        return switch (target) {
            .diff_file => |file_index| if (self.activeLoadedDiffConst()) |loaded|
                self.diffFileSelection(loaded, file_index)
            else
                null,
            .status_only => |status_index| self.statusOnlySelection(status_index),
        };
    }

    pub fn selectedStagePathKey(self: View) ?[]const u8 {
        const selection = self.currentSelection() orelse return null;
        return switch (selection) {
            .diff_file => |file| file.path_key,
            .status_only => |status| status.path_key,
        };
    }

    pub fn statusEntryForPathKey(self: View, path_key: []const u8) ?git_status.StatusEntry {
        for (self.page.git_status.document.entries) |entry| {
            const entry_key = entry.canonicalPathKey() orelse continue;
            if (std.mem.eql(u8, entry_key, path_key)) return entry;
        }
        return null;
    }

    pub fn freshStatusEntryForPathKey(self: View, repo_root: []const u8, path_key: []const u8) ?git_status.StatusEntry {
        if (!self.page.status_load.isFresh()) return null;
        const snapshot_root = self.page.git_status.repo_root orelse return null;
        if (!std.mem.eql(u8, snapshot_root, repo_root)) return null;
        return self.statusEntryForPathKey(path_key);
    }

    pub fn isFreshStagedOnlyPath(self: View, repo_root: []const u8, path_key: []const u8) bool {
        const entry = self.freshStatusEntryForPathKey(repo_root, path_key) orelse return false;
        return !entry.isConflict() and entry.isStaged() and !entry.isUnstaged();
    }

    pub fn diffFileSelection(self: View, loaded: *const LoadedDiff, file_index: usize) ?context.Selection {
        if (file_index >= loaded.document.files.len) return null;
        const file = loaded.document.files[file_index];
        return .{ .diff_file = .{
            .file_index = file_index,
            .display_path = diff_file.displayPath(file),
            .path_key = diff_file.canonicalPathKey(file),
            .hunk_index = if (self.selectedHunkIndex()) |hunk_index|
                if (hunk_index < file.hunks.len) hunk_index else null
            else
                null,
        } };
    }

    pub fn statusOnlySelection(self: View, status_index: usize) ?context.Selection {
        const repo_root = self.repo_root orelse return null;
        const status_root = self.page.git_status.repo_root orelse return null;
        if (!std.mem.eql(u8, repo_root, status_root)) return null;
        if (status_index >= self.page.git_status.document.entries.len) return null;
        const entry = self.page.git_status.document.entries[status_index];
        const path_key = entry.canonicalPathKey() orelse return null;
        return .{ .status_only = .{
            .status_index = status_index,
            .path_key = path_key,
        } };
    }

    pub fn selectedStatusEntry(self: View) ?git_status.StatusEntry {
        const target = self.page.viewer.selected_target orelse return null;
        const status_index = switch (target) {
            .status_only => |index| index,
            else => return null,
        };
        if (status_index >= self.page.git_status.document.entries.len) return null;
        return self.page.git_status.document.entries[status_index];
    }

    pub fn selectedStatusLineStats(self: View) ?file_tree.Stats {
        const entry = self.selectedStatusEntry() orelse return null;
        const path_key = entry.canonicalPathKey() orelse return null;
        for (self.page.git_status.document.line_stats) |line_stats| {
            if (std.mem.eql(u8, line_stats.path_key, path_key)) return line_stats.stats;
        }
        return null;
    }

    pub fn treeOrderScopeText(self: View, allocator: std.mem.Allocator) ![]u8 {
        const repo_root = self.repo_root orelse "";
        return switch (self.source) {
            .unstaged => std.fmt.allocPrint(allocator, "{s}\x1funstaged", .{repo_root}),
            .cached => std.fmt.allocPrint(allocator, "{s}\x1fcached", .{repo_root}),
            .range => |range| std.fmt.allocPrint(allocator, "{s}\x1frange\x1f{s}", .{ repo_root, range }),
            .patch_file => |path| std.fmt.allocPrint(allocator, "{s}\x1fpatch\x1f{s}", .{ repo_root, path }),
            .stdin => std.fmt.allocPrint(allocator, "{s}\x1fstdin", .{repo_root}),
            .pager => std.fmt.allocPrint(allocator, "{s}\x1fpager", .{repo_root}),
            .no_index => |paths| std.fmt.allocPrint(allocator, "{s}\x1fno-index\x1f{s}\x1f{s}", .{ repo_root, paths.left, paths.right }),
        };
    }

    pub fn selectedFile(self: View) ?diff_parser.FileDiff {
        const loaded = self.activeLoadedDiffConst() orelse return null;
        const file_index = self.selectedFileIndex(loaded) orelse return null;
        return loaded.document.files[file_index];
    }

    pub fn displayedDiffFile(self: View) ?diff_parser.FileDiff {
        if (self.activeCombinedProjection()) |bundle| return bundle.projection.file;
        if (self.activeCachedDiffProjection()) |bundle| {
            if (bundle.loaded.document.files.len == 0) return null;
            return bundle.loaded.document.files[0];
        }
        return self.selectedFile();
    }

    pub fn displayedSearchTarget(self: View, mode: diff_render.DisplayMode) ?SearchTarget {
        if (self.activeGeneratedFileProjection() != null) return null;
        if (self.activeCombinedProjection() != null) return null;

        if (self.activeCachedDiffProjection()) |bundle| {
            if (bundle.loaded.document.files.len == 0) return null;
            return .{
                .file = bundle.loaded.document.files[0],
                .line_index = bundle.loaded.cachedRenderedLineIndex(0, mode) orelse bundle.loaded.renderedLineIndex(0, mode),
                .folded_hunks = &.{},
            };
        }

        const file = self.displayedDiffFile() orelse return null;
        return .{
            .file = file,
            .line_index = self.selectedFileLineIndex(mode),
            .folded_hunks = self.selectedFoldedHunks(),
        };
    }

    pub fn displayedGeneratedLineCount(self: View) ?usize {
        const bundle = self.activeGeneratedFileProjection() orelse return null;
        return bundle.source.rowCount();
    }

    pub fn displayedDiffLineIndex(self: View, mode: diff_render.DisplayMode) ?diff_view_model.RenderedLineIndex {
        if (self.activeCombinedProjection()) |bundle| return bundle.projection.lineIndex(mode);
        if (self.activeCachedDiffProjection()) |bundle| {
            if (bundle.loaded.document.files.len == 0) return null;
            return bundle.loaded.cachedRenderedLineIndex(0, mode);
        }
        return null;
    }

    pub fn activeDiffDisplay(self: View, allocator: std.mem.Allocator, mode: diff_render.DisplayMode) !?ActiveDiffDisplay {
        if (self.activeCombinedProjection()) |bundle| {
            const states = bundle.projection.hunk_states;
            const flags = try allocator.alloc(bool, states.len);
            for (states, flags) |state, *flag| flag.* = state.state == .staged;
            return .{ .combined_projection = .{
                .file = bundle.projection.file,
                .line_index = bundle.projection.lineIndex(mode),
                .staged_flags = flags,
                .hunk_states = states,
            } };
        }

        const loaded = self.activeLoadedDiffConst() orelse return null;
        const file_index = self.selectedFileIndex(loaded) orelse return null;
        const file = loaded.document.files[file_index];
        return .{ .loaded = .{
            .file_index = file_index,
            .file = file,
            .line_index = loaded.cachedRenderedLineIndex(file_index, mode),
            .folded_hunks = loaded.foldedHunksForFile(file_index),
            .staged_flags = try self.stagedHunkFlagsForFile(allocator, file),
        } };
    }

    pub fn activeGeneratedFileProjection(self: View) ?*const review_projection.GeneratedFileBundle {
        return switch (self.page.review_projection.displayed) {
            .ready => |*ready| blk: {
                if (ready.request.kind != .generated_added_file or !self.displayedProjectionRequestIsActive(ready.request)) break :blk null;
                break :blk switch (ready.value) {
                    .generated_added_file => |*bundle| bundle,
                    else => null,
                };
            },
            else => null,
        };
    }

    pub fn activeCachedDiffProjection(self: View) ?*const app_load.LoadedDiffBundle {
        return switch (self.page.review_projection.displayed) {
            .ready => |*ready| blk: {
                if (ready.request.kind != .cached_diff or !self.displayedProjectionRequestIsActive(ready.request)) break :blk null;
                break :blk switch (ready.value) {
                    .cached_diff => |*bundle| bundle,
                    else => null,
                };
            },
            else => null,
        };
    }

    pub fn activeCombinedProjection(self: View) ?*const review_projection.CombinedHunkBundle {
        return switch (self.page.review_projection.displayed) {
            .ready => |*ready| blk: {
                if (ready.request.kind != .combined_hunks or !self.displayedProjectionRequestIsActive(ready.request)) break :blk null;
                break :blk switch (ready.value) {
                    .combined_hunks => |*bundle| bundle,
                    else => null,
                };
            },
            else => null,
        };
    }

    pub fn displayedProjectionRequestIsActive(self: View, request: review_projection.Request) bool {
        const repo_root = self.repo_root orelse return false;
        const path_key = self.selectedStagePathKey() orelse return false;
        return request.matchesDisplayIdentity(
            repo_root,
            path_key,
            projectionSourceKind(self.source),
            self.page.source_session_revision,
        );
    }

    pub fn selectedFileLineIndex(self: View, mode: diff_render.DisplayMode) diff_view_model.RenderedLineIndex {
        if (self.displayedDiffLineIndex(mode)) |index| return index;
        const loaded = self.activeLoadedDiffConst() orelse return .{ .mode = mode };
        const file_index = self.selectedFileIndex(loaded) orelse return .{ .mode = mode };
        return loaded.renderedLineIndex(file_index, mode);
    }

    pub fn displayedDiffLineCount(self: View) usize {
        if (self.displayedGeneratedLineCount()) |line_count| return line_count;
        return self.selectedFileLineIndex(self.effectiveDisplayMode()).lineCount();
    }

    pub fn selectedFileCachedLineIndex(self: View, mode: diff_render.DisplayMode) ?diff_view_model.RenderedLineIndex {
        const loaded = self.activeLoadedDiffConst() orelse return null;
        const file_index = self.selectedFileIndex(loaded) orelse return null;
        return loaded.cachedRenderedLineIndex(file_index, mode);
    }

    pub fn selectedFoldedHunks(self: View) []const bool {
        if (self.activeCombinedProjection() != null or self.activeCachedDiffProjection() != null) return &.{};
        const loaded = self.activeLoadedDiffConst() orelse return &.{};
        const file_index = self.selectedFileIndex(loaded) orelse return &.{};
        return loaded.foldedHunksForFile(file_index);
    }

    pub fn selectedHunkOffset(self: View, mode: diff_render.DisplayMode, hunk_index: usize) usize {
        if (self.activeCombinedProjection()) |bundle| return bundle.projection.lineIndex(mode).hunkOffset(hunk_index);
        const loaded = self.activeLoadedDiffConst() orelse return 0;
        const file_index = self.selectedFileIndex(loaded) orelse return 0;
        if (loaded.rendered_line_cache.indexFor(file_index, mode)) |index| return index.hunkOffset(hunk_index);
        return diff_view_model.hunkBodyLineOffsetFolded(loaded.document.files[file_index], mode, hunk_index, loaded.foldedHunksForFile(file_index));
    }

    pub fn selectedHunkIndex(self: View) ?usize {
        return switch (self.page.viewer.diff_cursor) {
            .hunk_header => |hunk_index| hunk_index,
            .hunk_line => |line| line.hunk_index,
            .metadata, .binary_marker => null,
        };
    }

    pub fn stagedHunkFlagsForFile(self: View, allocator: std.mem.Allocator, file: diff_parser.FileDiff) ![]const bool {
        if (self.page.staged_hunks.items.items.len == 0 or file.hunks.len == 0) return &.{};
        const repo_root = self.repo_root orelse return &.{};
        const path = diff_file.canonicalPathKey(file) orelse return &.{};

        var marked_count: usize = 0;
        for (0..file.hunks.len) |hunk_index| {
            if (self.page.staged_hunks.contains(repo_root, path, hunk_index)) marked_count += 1;
        }

        if (marked_count == 0) return &.{};
        if (marked_count == file.hunks.len and self.isFreshStagedOnlyPath(repo_root, path)) return &.{};

        const flags = try allocator.alloc(bool, file.hunks.len);
        @memset(flags, false);
        for (flags, 0..) |*flag, hunk_index| {
            flag.* = self.page.staged_hunks.contains(repo_root, path, hunk_index);
        }
        return flags;
    }

    pub fn selectedDiffCursorOffset(self: View) ?usize {
        if (self.displayedGeneratedLineCount()) |line_count| {
            return switch (self.page.viewer.diff_cursor) {
                .metadata => |offset| if (offset < line_count) offset else null,
                else => null,
            };
        }

        const mode = self.effectiveDisplayMode();
        const file = self.displayedDiffFile() orelse return null;
        const index = self.displayedDiffLineIndex(mode) orelse self.selectedFileCachedLineIndex(mode);
        return diff_view_model.renderedOffsetForCoordinate(file, mode, self.page.viewer.diff_cursor, index);
    }

    pub fn selectedCoordinateAtOffset(self: View, offset: usize) ?diff_view_model.BodyCoordinate {
        if (self.displayedGeneratedLineCount()) |line_count| {
            if (offset >= line_count) return null;
            return .{ .metadata = offset };
        }

        const mode = self.effectiveDisplayMode();
        const file = self.displayedDiffFile() orelse return null;
        const index = self.displayedDiffLineIndex(mode) orelse self.selectedFileCachedLineIndex(mode);
        return diff_view_model.coordinateAtOffset(file, mode, offset, self.selectedFoldedHunks(), index);
    }

    pub fn visibleDiffCursorOffset(self: View) ?usize {
        const offset = self.selectedDiffCursorOffset() orelse return null;
        const visible_rows = self.diffVisibleRows();
        if (offset < self.page.viewer.diff_scroll) return null;
        if (visible_rows == 0 or offset >= self.page.viewer.diff_scroll + visible_rows) return null;
        return offset;
    }

    pub fn diffCursorIsVisible(self: View) bool {
        return self.visibleDiffCursorOffset() != null;
    }

    pub fn loadedFileCount(self: View) ?usize {
        const loaded = self.activeLoadedDiffConst() orelse return null;
        return loaded.document.files.len;
    }

    pub fn effectiveDisplayMode(self: View) diff_render.DisplayMode {
        return diff_render.effectiveMode(diff_render.bodyWidth(self.diffPaneWidth()), self.page.viewer.display_mode);
    }

    pub fn diffVisibleRows(self: View) usize {
        return diff_render.visibleBodyRows(self.layout.height);
    }

    pub fn diffPaneWidth(self: View) u16 {
        const width = self.layout.width;
        if (self.page.viewer.sidebar_hidden) return contentWidth(width);
        const sidebar_width = sidebarWidth(width, self.page.viewer.sidebar_width);
        if (width <= sidebar_width + 1) return 0;
        return contentWidth(width - sidebar_width - 1);
    }

    pub fn selectedFileIndex(self: View, loaded: *const LoadedDiff) ?usize {
        if (loaded.document.files.len == 0) return null;
        const file_index = self.selectedDiffFileTarget() orelse return null;
        return @min(file_index, loaded.document.files.len - 1);
    }

    pub fn selectedDiffFileTarget(self: View) ?usize {
        const target = self.page.viewer.selected_target orelse return null;
        return target.diffFileIndex();
    }

    pub fn activeLoadedDiffConst(self: View) ?*const LoadedDiff {
        return switch (self.page.load.state) {
            .loaded => |*session| &session.loaded,
            else => null,
        };
    }
};

pub const Controller = struct {
    page: *review_page.ReviewPageState,
    repo_root: ?[]const u8,
    source: diff_source.SourceMode,
    layout: Layout,
    diagnostics: DiagnosticSink,

    pub fn view(self: Controller) View {
        return .{ .page = self.page, .repo_root = self.repo_root, .source = self.source, .layout = self.layout };
    }

    fn setStatus(self: Controller, comptime fmt: []const u8, args: anytype) void {
        self.diagnostics.set(fmt, args);
    }

    pub fn stableOrderOptions(self: Controller, allocator: std.mem.Allocator) file_tree.StableOrderOptions {
        return .{
            .allocator = allocator,
            .order = &self.page.tree_order,
        };
    }

    pub fn pressDiffMouse(self: Controller, point: MousePoint) void {
        self.page.viewer.focus = .diff;
        if (self.view().diffHeaderMouseHit(point)) |hit| {
            self.page.selection_owner = .{ .diff_header = .{ .identity = hit.identity } };
            return;
        }
        const hit = self.view().diffMouseHit(point) orelse {
            self.clearDiffSelection();
            return;
        };
        self.page.selection_owner = .{ .diff = diff_selection.DragSelection.init(hit.identity, hit.side, hit.point) };
    }

    pub fn dragDiffMouse(self: Controller, point_opt: ?MousePoint) void {
        const point = point_opt orelse return;
        switch (self.page.selection_owner) {
            .none => return,
            .diff_header => |*selection| selection.update(),
            .diff => |*selection| {
                const hit = self.view().diffMouseHit(point) orelse return;
                if (!selection.identity.eql(hit.identity)) return;
                selection.update(hit.point);
            },
        }
    }

    pub fn clearDiffSelection(self: Controller) void {
        self.terminateDiffSelection();
    }

    pub fn terminateDiffSelection(self: Controller) void {
        self.page.selection_owner = .none;
    }

    pub fn selectFileDelta(self: Controller, delta: i2) void {
        const loaded = self.activeLoadedDiff() orelse return;
        if (loaded.tree.nodes.len == 0 or loaded.visibleNodeCount() == 0) return;

        if (delta < 0) {
            if (loaded.previousVisibleNodeIndex(self.page.viewer.selected_node)) |previous| {
                self.selectSidebarNode(loaded, previous);
            }
        } else if (loaded.nextVisibleNodeIndex(self.page.viewer.selected_node)) |next| {
            self.selectSidebarNode(loaded, next);
        }
        self.clampSelection(loaded.document.files.len);
        self.clampDiffNavigation();
    }

    pub fn selectFileAbsolute(self: Controller, index: usize) void {
        const file_count = self.view().loadedFileCount() orelse return;
        if (file_count == 0) return;
        const target = @min(index, file_count - 1);
        if (self.view().selectedDiffFileTarget() == target) {
            if (self.activeLoadedDiff()) |loaded| {
                self.syncSidebarNodeToSelectedFile(loaded);
            }
            self.clampSelection(file_count);
            return;
        }
        self.setSelectedDiffFile(target);
        if (self.activeLoadedDiff()) |loaded| {
            self.syncSidebarNodeToSelectedFile(loaded);
        }
        self.resetDiffPosition();
        self.refreshSearchForSelectedFile();
        self.clampSelection(file_count);
        self.clampDiffNavigation();
    }

    pub fn selectLastFile(self: Controller) void {
        const file_count = self.view().loadedFileCount() orelse return;
        if (file_count == 0) return;
        self.selectFileAbsolute(file_count - 1);
    }

    pub fn selectSidebarNode(self: Controller, loaded: *LoadedDiff, node_index: usize) void {
        if (node_index >= loaded.tree.nodes.len) return;
        const previous_file = self.view().selectedDiffFileTarget();
        self.page.viewer.selected_node = node_index;
        // File rows change the active diff pane file. Directory rows only move
        // the sidebar cursor and keep the previous selected target visible.
        switch (loaded.tree.nodes[node_index].target) {
            .diff_file => |file_index| {
                self.setSelectedDiffFile(file_index);
                if (previous_file == null or file_index != previous_file.?) {
                    self.resetDiffPosition();
                    self.refreshSearchForSelectedFile();
                }
            },
            .status_entry => |status_index| {
                self.clearDiffSelection();
                self.page.viewer.selected_target = .{ .status_only = status_index };
                self.resetDiffPosition();
                self.clearSearchMatch();
            },
            .repo_root, .directory => {},
        }
    }

    pub fn toggleSelectedDirectory(self: Controller) !void {
        const loaded = self.activeLoadedDiff() orelse return;
        if (self.page.viewer.selected_node >= loaded.tree.nodes.len) return;
        const node = loaded.tree.nodes[self.page.viewer.selected_node];
        if (node.kind != .directory) return;
        const allocator = self.loadArenaAllocator() orelse return;
        try file_tree.toggle(allocator, &loaded.collapsed_dirs, node.path);
        try loaded.rebuildVisibleNodes(allocator, self.page.review_display.hide_reviewed_files, self.page.review_display.changed_file_filter);
        self.clampSelection(loaded.document.files.len);
        self.clampSidebarHorizontalScroll();
    }

    pub fn clickSidebarNode(self: Controller, node_index: usize) !void {
        if (self.page.viewer.sidebar_hidden) return;
        const loaded = self.activeLoadedDiff() orelse return;
        if (node_index >= loaded.tree.nodes.len) return;

        self.page.viewer.focus = .sidebar;
        self.selectSidebarNode(loaded, node_index);

        const node = loaded.tree.nodes[node_index];
        if (node.kind == .directory) try self.toggleSelectedDirectory();

        self.clampSelection(loaded.document.files.len);
        self.clampDiffNavigation();
    }

    pub fn expandSelectedDirectory(self: Controller) !void {
        const loaded = self.activeLoadedDiff() orelse return;
        if (self.page.viewer.selected_node >= loaded.tree.nodes.len) return;
        const node = loaded.tree.nodes[self.page.viewer.selected_node];
        if (node.kind != .directory) return;
        file_tree.expand(&loaded.collapsed_dirs, node.path);
        try loaded.rebuildVisibleNodes(self.loadArenaAllocator() orelse return, self.page.review_display.hide_reviewed_files, self.page.review_display.changed_file_filter);
        self.clampSelection(loaded.document.files.len);
        self.clampSidebarHorizontalScroll();
    }

    pub fn collapseOrSelectParentDirectory(self: Controller) !void {
        const loaded = self.activeLoadedDiff() orelse return;
        if (self.page.viewer.selected_node >= loaded.tree.nodes.len) return;
        const node = loaded.tree.nodes[self.page.viewer.selected_node];
        if (node.kind == .directory and !file_tree.isCollapsed(&loaded.collapsed_dirs, node.path)) {
            const allocator = self.loadArenaAllocator() orelse return;
            try file_tree.collapse(allocator, &loaded.collapsed_dirs, node.path);
            try loaded.rebuildVisibleNodes(allocator, self.page.review_display.hide_reviewed_files, self.page.review_display.changed_file_filter);
            self.clampSelection(loaded.document.files.len);
            self.clampSidebarHorizontalScroll();
            return;
        }
        if (loaded.tree.parentDirectoryNodeIndex(self.page.viewer.selected_node)) |parent| {
            self.page.viewer.selected_node = parent;
            self.clampSelection(loaded.document.files.len);
        }
    }

    pub fn scrollDiff(self: Controller, direction: VerticalDirection) void {
        const old_scroll = self.page.viewer.diff_scroll;
        const old_cursor_offset = self.view().selectedDiffCursorOffset();
        switch (direction) {
            .up => self.page.viewer.diff_scroll -|= 1,
            .down => self.page.viewer.diff_scroll += 1,
        }
        self.clampDiffNavigation();
        self.syncDiffCursorAfterViewportScroll(direction, old_scroll, old_cursor_offset);
    }

    pub fn scrollDiffHorizontal(self: Controller, direction: HorizontalDirection) void {
        const step: usize = 8;
        switch (direction) {
            .left => self.page.viewer.diff_horizontal_scroll -|= step,
            .right => {
                self.page.viewer.diff_horizontal_scroll += step;
                self.clampDiffHorizontalScrollToVisibleRows();
            },
        }
    }

    pub fn scrollSidebarHorizontal(self: Controller, direction: HorizontalDirection) void {
        const step: usize = 4;
        switch (direction) {
            .left => self.page.viewer.sidebar_horizontal_scroll -|= step,
            .right => {
                self.page.viewer.sidebar_horizontal_scroll += step;
                self.clampSidebarHorizontalScroll();
            },
        }
    }

    pub fn clampSidebarHorizontalScroll(self: Controller) void {
        const max_scroll = self.view().visibleSidebarMaxHorizontalScroll();
        if (self.page.viewer.sidebar_horizontal_scroll > max_scroll) {
            self.page.viewer.sidebar_horizontal_scroll = max_scroll;
        }
    }

    pub fn clampDiffHorizontalScrollToVisibleRows(self: Controller) void {
        const max_scroll = self.view().visibleBodyTextMaxHorizontalScroll();
        if (self.page.viewer.diff_horizontal_scroll > max_scroll) {
            self.page.viewer.diff_horizontal_scroll = max_scroll;
        }
    }

    pub fn pageDiff(self: Controller, direction: VerticalDirection) void {
        const rows = self.view().diffVisibleRows();
        const step: usize = @max(rows, 1);
        switch (direction) {
            .up => self.page.viewer.diff_scroll -|= step,
            .down => self.page.viewer.diff_scroll += step,
        }
        self.clampDiffNavigation();
    }

    pub fn moveDiffCursorRows(self: Controller, direction: VerticalDirection) void {
        const current = self.view().selectedDiffCursorOffset() orelse {
            self.initializeDiffCursorForSelectedFile();
            self.applyDiffCursorScrolloff();
            return;
        };
        const line_count = self.view().displayedDiffLineCount();
        if (line_count == 0) return;
        const target = switch (direction) {
            .up => current -| 1,
            .down => @min(current + 1, line_count - 1),
        };
        self.page.viewer.diff_cursor = self.view().selectedCoordinateAtOffset(target) orelse self.page.viewer.diff_cursor;
        self.applyDiffCursorScrolloff();
    }

    pub fn moveDiffCursorPage(self: Controller, direction: VerticalDirection) void {
        const current = self.view().selectedDiffCursorOffset() orelse {
            self.initializeDiffCursorForSelectedFile();
            self.applyDiffCursorScrolloff();
            return;
        };
        const line_count = self.view().displayedDiffLineCount();
        if (line_count == 0) return;
        const step = @max(self.view().diffVisibleRows(), 1);
        const target = switch (direction) {
            .up => current -| step,
            .down => @min(current + step, line_count - 1),
        };
        self.page.viewer.diff_cursor = self.view().selectedCoordinateAtOffset(target) orelse self.page.viewer.diff_cursor;
        self.applyDiffCursorScrolloff();
    }

    pub fn selectHunkDelta(self: Controller, delta: i2) void {
        const file = self.view().displayedDiffFile() orelse return;
        if (file.hunks.len == 0) return;

        const current = self.view().selectedHunkIndex();
        const target = if (delta < 0) blk: {
            if (current) |hunk_index| {
                if (self.page.viewer.diff_cursor == .hunk_line) break :blk hunk_index;
                break :blk hunk_index -| 1;
            }
            break :blk 0;
        } else blk: {
            if (current) |hunk_index| break :blk @min(hunk_index + 1, file.hunks.len - 1);
            break :blk 0;
        };
        self.page.viewer.diff_cursor = .{ .hunk_header = target };
        self.applyDiffCursorScrolloff();
    }

    pub fn toggleSelectedHunkFold(self: Controller) void {
        if (self.view().activeCombinedProjection() != null) {
            self.setStatus("hunk fold is unavailable for mixed staged/unstaged view", .{});
            return;
        }
        const loaded = self.activeLoadedDiff() orelse return;
        const file_index = self.view().selectedFileIndex(loaded) orelse return;
        if (file_index >= loaded.document.files.len) return;
        const file = loaded.document.files[file_index];
        const hunk_index = self.view().selectedHunkIndex() orelse return;
        if (hunk_index >= file.hunks.len) return;

        if (!loaded.isHunkFolded(file_index, hunk_index) and
            self.view().currentSearchMatchInHunkBody(hunk_index))
        {
            return;
        }

        const folding = !loaded.isHunkFolded(file_index, hunk_index);
        loaded.toggleHunkFold(file_index, hunk_index);
        if (folding) {
            switch (self.page.viewer.diff_cursor) {
                .hunk_line => |line| if (line.hunk_index == hunk_index) {
                    self.page.viewer.diff_cursor = .{ .hunk_header = hunk_index };
                },
                else => {},
            }
        }
        self.updateSearchMatchOffset();
        self.applyDiffCursorScrolloff();
        self.clampDiffNavigation();
    }

    pub fn scrollSelectedHunkIntoView(self: Controller) void {
        const mode = self.view().effectiveDisplayMode();
        const hunk_index = self.view().selectedHunkIndex() orelse return;
        const target = self.view().selectedHunkOffset(mode, hunk_index);
        const visible_rows = self.view().diffVisibleRows();
        if (target < self.page.viewer.diff_scroll) {
            self.page.viewer.diff_scroll = target;
        } else if (visible_rows > 0 and target >= self.page.viewer.diff_scroll + visible_rows) {
            self.page.viewer.diff_scroll = target + 1 - visible_rows;
        }
    }

    pub fn clampDiffNavigation(self: Controller) void {
        if (self.view().selectedFile() == null) {
            const line_count = self.view().selectedProjectionLineCount();
            const visible_rows = self.view().diffVisibleRows();
            const max_scroll = if (line_count > visible_rows) line_count - visible_rows else 0;
            if (self.page.viewer.diff_scroll > max_scroll) self.page.viewer.diff_scroll = max_scroll;
            return;
        }

        if (self.view().selectedDiffCursorOffset() == null) {
            self.initializeDiffCursorForSelectedFile();
        }

        const mode = self.view().effectiveDisplayMode();
        const line_count = self.view().selectedFileLineIndex(mode).lineCount();
        const visible_rows = self.view().diffVisibleRows();
        const max_scroll = if (line_count > visible_rows) line_count - visible_rows else 0;
        if (self.page.viewer.diff_scroll > max_scroll) self.page.viewer.diff_scroll = max_scroll;
    }

    pub fn clampDiffNavigationKeepingHunkVisible(self: Controller) void {
        self.clampDiffNavigation();
        self.applyDiffCursorScrolloff();
        self.clampDiffNavigation();
    }

    pub fn resetDiffPosition(self: Controller) void {
        self.page.viewer.diff_scroll = 0;
        self.initializeDiffCursorForSelectedFile();
        self.clearSearchMatch();
    }

    pub fn enterSearchMode(self: Controller) void {
        if (self.blockUnsupportedSearchTarget()) return;
        self.clearDiffSelection();
        self.page.search.input = self.page.search.query;
        self.page.search.mode = true;
    }

    pub fn cancelSearchMode(self: Controller) void {
        self.page.search.input = self.page.search.query;
        self.page.search.mode = false;
    }

    pub fn clearSearch(self: Controller) void {
        self.page.search.mode = false;
        self.page.search.input = .{};
        self.page.search.query = .{};
        self.clearSearchMatch();
    }

    /// Resets only Review-local navigation after the shell commits a different
    /// repository identity. Repository selection and reload remain shell-owned.
    pub fn resetAfterRepositorySwitch(self: Controller) void {
        self.setSelectedDiffFile(0);
        self.page.viewer.selected_node = 0;
        self.clearSearch();
    }

    pub fn enterFileSearchMode(self: Controller) void {
        self.clearDiffSelection();
        self.page.file_search_return_focus = if (self.page.viewer.sidebar_hidden) .diff else self.page.viewer.focus;
        if (!self.page.viewer.sidebar_hidden) self.page.viewer.focus = .sidebar;
        self.page.file_search.mode = true;
        self.page.file_search.input = .{};
        self.page.file_search.resetNoMatch();
    }

    pub fn cancelFileSearchMode(self: Controller, allocator: std.mem.Allocator) void {
        self.page.file_search.deinit(allocator);
        self.page.viewer.focus = if (self.page.viewer.sidebar_hidden) .diff else self.page.file_search_return_focus;
    }

    pub fn toggleReviewedFile(self: Controller, allocator: std.mem.Allocator) !void {
        const loaded = self.activeLoadedDiff() orelse return;
        if (self.page.viewer.selected_node >= loaded.tree.nodes.len) return;

        const file_index = self.view().selectedFileIndex(loaded) orelse return;
        if (file_index >= loaded.reviewed_files.len) return;
        const file = loaded.document.files[file_index];
        if (self.repo_root != null and diff_file.canonicalPathKey(file) == null) return;

        const reviewed = !loaded.reviewed_files[file_index];
        try self.page.reviewed_store.set(allocator, self.repo_root, file, reviewed);
        loaded.reviewed_files[file_index] = reviewed;
        if (self.page.review_display.hide_reviewed_files) {
            try loaded.rebuildVisibleNodes(self.loadArenaAllocator() orelse return, true, self.page.review_display.changed_file_filter);
            self.reconcileSelectionAfterVisibleNodeChange(loaded);
            self.clampSidebarHorizontalScroll();
            self.clampDiffNavigation();
        }
    }

    pub fn toggleHideReviewedFiles(self: Controller) !void {
        self.page.review_display.hide_reviewed_files = !self.page.review_display.hide_reviewed_files;
        const loaded = self.activeLoadedDiff() orelse return;
        try loaded.rebuildVisibleNodes(self.loadArenaAllocator() orelse return, self.page.review_display.hide_reviewed_files, self.page.review_display.changed_file_filter);
        self.reconcileSelectionAfterVisibleNodeChange(loaded);
        self.clampSidebarHorizontalScroll();
        self.clampDiffNavigation();
    }

    pub fn cycleChangedFileFilter(self: Controller) !void {
        self.page.review_display.changed_file_filter = self.page.review_display.changed_file_filter.next();
        const loaded = self.activeLoadedDiff() orelse return;
        try loaded.rebuildVisibleNodes(self.loadArenaAllocator() orelse return, self.page.review_display.hide_reviewed_files, self.page.review_display.changed_file_filter);
        self.reconcileSelectionAfterVisibleNodeChange(loaded);
        self.clampSidebarHorizontalScroll();
        self.clampDiffNavigation();
    }

    pub fn submitFileSearch(self: Controller, allocator: std.mem.Allocator) !void {
        const query = std.mem.trim(u8, self.page.file_search.input.slice(), " \t\r\n");
        if (query.len == 0) {
            self.cancelFileSearchMode(allocator);
            return;
        }

        const loaded = self.activeLoadedDiff() orelse {
            self.page.file_search.no_match = true;
            return;
        };
        const node_index = try self.findFileNodeWithFilter(allocator, loaded, query) orelse {
            self.page.file_search.clearFilter(allocator);
            self.page.file_search.no_match = true;
            return;
        };

        // Go-to-file should land on the file row, not on a still-collapsed
        // parent directory that hides the matched path.
        file_tree.expandAncestors(&loaded.collapsed_dirs, loaded.tree.nodes[node_index].path);
        const load_allocator = self.loadArenaAllocator() orelse {
            self.page.file_search.clearFilter(allocator);
            return;
        };
        loaded.rebuildVisibleNodes(load_allocator, self.page.review_display.hide_reviewed_files, self.page.review_display.changed_file_filter) catch {
            self.page.file_search.clearFilter(allocator);
            self.page.file_search.no_match = true;
            return;
        };
        self.selectSidebarNode(loaded, node_index);
        self.clampSelection(loaded.document.files.len);
        self.clampDiffNavigation();
        self.cancelFileSearchMode(allocator);
    }

    pub fn submitSearch(self: Controller) void {
        self.page.search.mode = false;
        if (self.blockUnsupportedSearchTarget()) return;
        self.page.search.query = self.page.search.input;
        self.clearSearchMatch();
        if (self.page.search.query.len == 0) {
            return;
        }
        self.selectSearchMatch(.forward);
    }

    pub fn selectSearchMatch(self: Controller, direction: diff_search.Direction) void {
        if (self.blockUnsupportedSearchTarget()) return;
        const mode = self.view().effectiveDisplayMode();
        const target = self.view().displayedSearchTarget(mode) orelse return;
        if (self.page.search.query.len == 0) return;

        const line_count = target.line_index.lineCount();
        if (line_count == 0) return;
        const base = if (self.page.search.match) |match| match.coordinate else null;
        const next = diff_search.findMatch(target.file, mode, self.page.search.query.slice(), base, direction) orelse {
            self.clearSearchMatch();
            return;
        };
        self.unfoldSearchMatchIfNeeded(next);
        self.setSearchMatch(next);
        self.page.viewer.diff_cursor = next.coordinate;
        self.resetDiffHorizontalScroll();
        self.applyDiffCursorScrolloff();
        self.clampDiffNavigation();
    }

    pub fn refreshSearchForSelectedFile(self: Controller) void {
        self.clearSearchMatch();
        if (self.page.search.query.len == 0) return;
        if (self.view().unsupportedSearchMessage() != null) return;
        const mode = self.view().effectiveDisplayMode();
        const target = self.view().displayedSearchTarget(mode) orelse return;
        const next = diff_search.findMatch(target.file, mode, self.page.search.query.slice(), null, .forward) orelse return;
        self.unfoldSearchMatchIfNeeded(next);
        self.setSearchMatch(next);
        self.page.viewer.diff_cursor = next.coordinate;
        self.applyDiffCursorScrolloff();
    }

    pub fn clearSearchMatch(self: Controller) void {
        self.page.search.match = null;
        self.page.search.match_offset = null;
    }

    pub fn setSearchMatch(self: Controller, match: diff_search.Match) void {
        self.page.search.match = match;
        self.updateSearchMatchOffset();
    }

    pub fn updateSearchMatchOffset(self: Controller) void {
        self.page.search.match_offset = null;
        if (self.view().unsupportedSearchMessage() != null) {
            self.clearSearchMatch();
            return;
        }
        const match = self.page.search.match orelse return;
        const mode = self.view().effectiveDisplayMode();
        const target = self.view().displayedSearchTarget(mode) orelse {
            self.clearSearchMatch();
            return;
        };
        const offset = diff_view_model.renderedOffsetForCoordinate(target.file, mode, match.coordinate, target.line_index) orelse {
            self.clearSearchMatch();
            return;
        };
        self.page.search.match_offset = offset;
    }

    pub fn blockUnsupportedSearchTarget(self: Controller) bool {
        if (self.view().unsupportedSearchMessage()) |message| {
            self.clearSearchMatch();
            self.setStatus("{s}", .{message});
            return true;
        }
        return false;
    }

    pub fn unfoldSearchMatchIfNeeded(self: Controller, match: diff_search.Match) void {
        if (self.view().activeCombinedProjection() != null or
            self.view().activeCachedDiffProjection() != null or
            self.view().activeGeneratedFileProjection() != null) return;

        const hunk_index = switch (match.coordinate) {
            .hunk_line => |line| line.hunk_index,
            else => return,
        };
        const loaded = self.activeLoadedDiff() orelse return;
        const file_index = self.view().selectedFileIndex(loaded) orelse return;
        if (!loaded.isHunkFolded(file_index, hunk_index)) return;
        loaded.setHunkFolded(file_index, hunk_index, false);
    }

    pub fn scrollSearchMatchIntoView(self: Controller) void {
        const offset = self.page.search.match_offset orelse return;
        const visible_rows = self.view().diffVisibleRows();
        if (offset < self.page.viewer.diff_scroll) {
            self.page.viewer.diff_scroll = offset;
        } else if (visible_rows > 0 and offset >= self.page.viewer.diff_scroll + visible_rows) {
            self.page.viewer.diff_scroll = offset + 1 - visible_rows;
        }
    }

    pub fn setPendingSelectionRestore(self: Controller, allocator: std.mem.Allocator, path_key: []const u8) !void {
        self.clearPendingSelectionRestore(allocator);
        const visible_row = if (self.view().activeLoadedDiffConst()) |loaded|
            loaded.visibleRowOfNode(self.page.viewer.selected_node) orelse 0
        else
            0;
        self.page.pending_selection_restore = .{
            .path_key = try allocator.dupe(u8, path_key),
            .visible_row = visible_row,
        };
    }

    pub fn clearPendingSelectionRestore(self: Controller, allocator: std.mem.Allocator) void {
        if (self.page.pending_selection_restore) |*restore| restore.deinit(allocator);
        self.page.pending_selection_restore = null;
    }

    pub fn restorePendingSelectionOrFallback(self: Controller, allocator: std.mem.Allocator, loaded: *LoadedDiff) bool {
        const restore = self.page.pending_selection_restore orelse return false;
        defer self.clearPendingSelectionRestore(allocator);

        if (findNodeByPathKey(loaded, restore.path_key)) |node_index| {
            self.selectSidebarNode(loaded, node_index);
            return true;
        }

        if (loaded.visibleNodeCount() == 0) {
            self.page.viewer.selected_target = null;
            self.page.viewer.selected_node = 0;
            return true;
        }

        const row = @min(restore.visible_row, loaded.visibleNodeCount() - 1);
        if (nearestVisibleFileNode(loaded, row)) |node_index| {
            self.selectSidebarNode(loaded, node_index);
            return true;
        }

        return false;
    }

    pub fn restorePendingSelectionByPath(self: Controller, allocator: std.mem.Allocator, loaded: *LoadedDiff) bool {
        const restore = self.page.pending_selection_restore orelse return false;
        if (findNodeByPathKey(loaded, restore.path_key)) |node_index| {
            defer self.clearPendingSelectionRestore(allocator);
            self.selectSidebarNode(loaded, node_index);
            return true;
        }
        return false;
    }

    pub fn restoreReloadAnchor(self: Controller, loaded: *LoadedDiff, anchor: *const review_page.ReloadAnchor) bool {
        const selected_same_path = if (findNodeByPathKey(loaded, anchor.path_key)) |node_index| blk: {
            self.selectSidebarNode(loaded, node_index);
            break :blk true;
        } else blk: {
            if (loaded.visibleNodeCount() == 0) {
                self.page.viewer.selected_target = null;
                self.page.viewer.selected_node = 0;
                self.resetDiffPosition();
                self.clearSearchMatch();
                return true;
            }
            const row = @min(anchor.visible_sidebar_row, loaded.visibleNodeCount() - 1);
            if (nearestVisibleFileNode(loaded, row)) |node_index| {
                self.selectSidebarNode(loaded, node_index);
                break :blk false;
            }
            return false;
        };

        self.page.viewer.sidebar_horizontal_scroll = anchor.sidebar_horizontal_scroll;
        self.page.viewer.diff_horizontal_scroll = anchor.diff_horizontal_scroll;

        if (selected_same_path and std.meta.activeTag(self.page.viewer.selected_target.?) == anchor.selected_target_tag) {
            self.page.viewer.diff_cursor = anchor.diff_cursor;
            if (self.view().selectedDiffCursorOffset() == null) {
                if (anchor.diff_cursor_offset) |offset| {
                    self.page.viewer.diff_cursor = self.view().selectedCoordinateAtOffset(offset) orelse self.page.viewer.diff_cursor;
                }
            }
        } else if (anchor.diff_cursor_offset) |offset| {
            self.page.viewer.diff_cursor = self.view().selectedCoordinateAtOffset(offset) orelse self.page.viewer.diff_cursor;
        }

        if (self.view().selectedDiffCursorOffset() == null) {
            self.initializeDiffCursorForSelectedFile();
        }

        self.page.viewer.diff_scroll = anchor.diff_scroll;
        self.clampDiffNavigation();
        self.keepDiffCursorVisible();
        self.restoreSearchFromReloadAnchor(anchor);
        self.clampSidebarHorizontalScroll();
        self.clampDiffHorizontalScrollToVisibleRows();
        return true;
    }

    pub fn keepDiffCursorVisible(self: Controller) void {
        const offset = self.view().selectedDiffCursorOffset() orelse return;
        const visible_rows = self.view().diffVisibleRows();
        if (offset < self.page.viewer.diff_scroll) {
            self.page.viewer.diff_scroll = offset;
        } else if (visible_rows > 0 and offset >= self.page.viewer.diff_scroll + visible_rows) {
            self.page.viewer.diff_scroll = offset + 1 - visible_rows;
        }
        self.clampDiffNavigation();
    }

    pub fn restoreSearchFromReloadAnchor(self: Controller, anchor: *const review_page.ReloadAnchor) void {
        self.clearSearchMatch();
        if (self.page.search.query.len == 0) return;

        if (anchor.search_coordinate) |coordinate| {
            self.page.search.match = .{ .coordinate = coordinate };
            self.updateSearchMatchOffset();
            if (self.page.search.match != null) return;
        }

        self.refreshSearchForSelectedFile();
    }

    pub fn ensureTreeOrderScope(self: Controller, allocator: std.mem.Allocator) !void {
        const scope = try self.view().treeOrderScopeText(allocator);
        defer allocator.free(scope);

        if (self.page.tree_order_scope) |current| {
            if (std.mem.eql(u8, current, scope)) return;
            allocator.free(current);
            self.page.tree_order_scope = null;
            self.page.tree_order.reset(allocator);
        }

        self.page.tree_order_scope = try allocator.dupe(u8, scope);
    }

    pub fn initializeDiffCursorForSelectedFile(self: Controller) void {
        self.page.viewer.diff_cursor = self.view().selectedCoordinateAtOffset(0) orelse .{ .metadata = 0 };
    }

    pub fn applyDiffCursorScrolloff(self: Controller) void {
        const cursor_offset = self.view().selectedDiffCursorOffset() orelse {
            self.clampDiffNavigation();
            return;
        };
        const visible_rows = self.view().diffVisibleRows();
        if (visible_rows == 0) {
            self.clampDiffNavigation();
            return;
        }
        const margin = @min(@as(usize, 8), visible_rows / 3);
        if (cursor_offset < self.page.viewer.diff_scroll + margin) {
            self.page.viewer.diff_scroll = cursor_offset -| margin;
        } else {
            const lower_edge = self.page.viewer.diff_scroll + visible_rows -| margin;
            if (cursor_offset >= lower_edge) {
                self.page.viewer.diff_scroll = cursor_offset + margin + 1 - visible_rows;
            }
        }
        self.clampDiffNavigation();
    }

    pub fn syncDiffCursorAfterViewportScroll(self: Controller, direction: VerticalDirection, old_scroll: usize, old_cursor_offset: ?usize) void {
        const line_count = self.view().selectedFileLineIndex(self.view().effectiveDisplayMode()).lineCount();
        if (line_count == 0) return;
        const visible_rows = self.view().diffVisibleRows();
        if (visible_rows == 0) return;

        // Mouse-wheel scrolling is viewport-first, but hunk actions still use
        // the diff cursor. Keep the cursor near the user's visible scroll
        // position without letting normal scrolloff pull the viewport back.
        const margin = @min(@as(usize, 8), visible_rows / 3);
        const target = if (old_cursor_offset) |offset| blk: {
            if (offset >= old_scroll and offset < old_scroll + visible_rows) {
                break :blk self.page.viewer.diff_scroll + (offset - old_scroll);
            }
            break :blk switch (direction) {
                .up => self.page.viewer.diff_scroll + margin,
                .down => self.page.viewer.diff_scroll + visible_rows - 1 -| margin,
            };
        } else blk: {
            break :blk switch (direction) {
                .up => self.page.viewer.diff_scroll + margin,
                .down => self.page.viewer.diff_scroll + visible_rows - 1 -| margin,
            };
        };

        self.page.viewer.diff_cursor = self.view().selectedCoordinateAtOffset(@min(target, line_count - 1)) orelse self.page.viewer.diff_cursor;
    }

    pub fn toggleSidebarVisibility(self: Controller) void {
        const previous_width = self.view().diffPaneWidth();
        const previous_mode = self.view().effectiveDisplayMode();
        self.page.viewer.sidebar_hidden = !self.page.viewer.sidebar_hidden;
        if (self.page.viewer.sidebar_hidden) self.page.viewer.focus = .diff;
        self.resetDiffHorizontalScrollIfPaneWidthChanged(previous_width);
        if (previous_mode != self.view().effectiveDisplayMode()) self.clearDiffSelection();
        self.clampDiffNavigationKeepingHunkVisible();
        self.updateSearchMatchOffset();
        self.scrollSearchMatchIntoView();
        self.clampDiffNavigation();
    }

    pub fn adjustSidebarWidth(self: Controller, direction: SizeDirection) void {
        const total_width = self.layout.width;
        const previous_width = self.view().diffPaneWidth();
        const previous_mode = self.view().effectiveDisplayMode();
        const current = sidebarWidth(total_width, self.page.viewer.sidebar_width);
        const step: u16 = 4;
        const next = switch (direction) {
            .shrink => if (current > step) current - step else 0,
            .grow => current +| step,
        };

        self.page.viewer.sidebar_width = sidebarWidth(total_width, next);
        self.clampSidebarHorizontalScroll();
        self.resetDiffHorizontalScrollIfPaneWidthChanged(previous_width);
        if (previous_mode != self.view().effectiveDisplayMode()) self.clearDiffSelection();
        self.clampDiffNavigationKeepingHunkVisible();
        self.updateSearchMatchOffset();
        self.scrollSearchMatchIntoView();
        self.clampDiffNavigation();
    }

    pub fn resetDiffHorizontalScroll(self: Controller) void {
        self.page.viewer.diff_horizontal_scroll = 0;
    }

    pub fn resetDiffHorizontalScrollIfPaneWidthChanged(self: Controller, previous_width: u16) void {
        if (self.view().diffPaneWidth() != previous_width) self.resetDiffHorizontalScroll();
    }

    pub fn clampSelection(self: Controller, file_count: usize) void {
        if (file_count == 0) {
            if (self.activeLoadedDiff()) |loaded| {
                if (loaded.tree.nodes.len > 0) {
                    self.page.viewer.selected_node = @min(self.page.viewer.selected_node, loaded.tree.nodes.len - 1);
                    const node = loaded.tree.nodes[self.page.viewer.selected_node];
                    self.page.viewer.selected_target = switch (node.target) {
                        .status_entry => |status_index| .{ .status_only = status_index },
                        .diff_file => |file_index| .{ .diff_file = file_index },
                        .repo_root, .directory => self.page.viewer.selected_target,
                    };
                    return;
                }
            }
            self.page.viewer.selected_target = null;
            self.page.viewer.selected_file = 0;
            self.page.viewer.selected_node = 0;
            return;
        }
        if (self.page.viewer.selected_target) |target| {
            switch (target) {
                .diff_file => |file_index| if (file_index >= file_count) {
                    self.setSelectedDiffFile(file_count - 1);
                },
                .status_only => |status_index| if (status_index >= self.page.git_status.document.entries.len) {
                    self.setSelectedDiffFile(file_count - 1);
                },
            }
        } else {
            self.setSelectedDiffFile(file_count - 1);
        }
        if (self.activeLoadedDiff()) |loaded| {
            if (self.page.viewer.selected_node >= loaded.tree.nodes.len) {
                self.syncSidebarNodeToSelectedFile(loaded);
            }
            if (loaded.visibleAncestorOrSelf(self.page.viewer.selected_node)) |visible_node| {
                self.page.viewer.selected_node = visible_node;
            } else if (self.view().selectedFileIndex(loaded)) |file_index| {
                if (loaded.tree.selectedNodeIndex(file_index)) |file_node| {
                    self.page.viewer.selected_node = file_node;
                }
            }
        }
    }

    pub fn reconcileSelectionAfterVisibleNodeChange(self: Controller, loaded: *LoadedDiff) void {
        if (loaded.visibleRowOfNode(self.page.viewer.selected_node) != null) {
            return;
        }

        if (loaded.firstVisibleFileNode()) |file_node| {
            self.selectSidebarNode(loaded, file_node);
            return;
        }

        if (loaded.visibleAncestorOrSelf(self.page.viewer.selected_node)) |visible_node| {
            self.selectSidebarNode(loaded, visible_node);
            return;
        }

        if (loaded.visibleNodeAt(0)) |node_index| {
            self.page.viewer.selected_node = node_index;
        }
    }

    pub fn setSelectedDiffFile(self: Controller, file_index: usize) void {
        const same_target = if (self.page.viewer.selected_target) |target|
            if (target.diffFileIndex()) |current| current == file_index else false
        else
            false;
        if (!same_target) self.clearDiffSelection();
        self.page.viewer.selected_target = .{ .diff_file = file_index };
        self.page.viewer.selected_file = file_index;
    }

    pub fn syncSidebarNodeToSelectedFile(self: Controller, loaded: *const LoadedDiff) void {
        const file_index = self.view().selectedFileIndex(loaded) orelse {
            self.page.viewer.selected_node = 0;
            return;
        };
        self.page.viewer.selected_node = loaded.tree.selectedNodeIndex(file_index) orelse 0;
    }

    pub fn selectFirstVisibleFile(self: Controller, loaded: *LoadedDiff) void {
        if (loaded.firstVisibleFileNode()) |node_index| {
            self.selectSidebarNode(loaded, node_index);
            return;
        }
        // Empty or fully filtered trees keep the existing fallback selection.
        self.syncSidebarNodeToSelectedFile(loaded);
    }

    pub fn materializeReviewedFiles(self: Controller, allocator: std.mem.Allocator, loaded: *LoadedDiff) !void {
        const reviewed_files = try allocator.alloc(bool, loaded.document.files.len);
        errdefer allocator.free(reviewed_files);

        for (loaded.document.files, 0..) |file, index| {
            reviewed_files[index] = try self.page.reviewed_store.containsFile(allocator, self.repo_root, file);
        }
        loaded.reviewed_files = reviewed_files;
    }

    pub fn findFileNodeWithFilter(self: Controller, allocator: std.mem.Allocator, loaded: *const LoadedDiff, query: []const u8) !?usize {
        var labels: std.ArrayList([]const u8) = .empty;
        defer labels.deinit(allocator);
        var node_indexes: std.ArrayList(usize) = .empty;
        defer node_indexes.deinit(allocator);

        for (loaded.tree.nodes, 0..) |node, index| {
            if (node.kind != .file) continue;
            if (!loaded.shouldIncludeFileNode(index, self.page.review_display.hide_reviewed_files, self.page.review_display.changed_file_filter)) continue;
            try labels.append(allocator, node.path);
            try node_indexes.append(allocator, index);
        }

        // ListFilter owns the filtered index arrays, while file path labels
        // remain borrowed from the active LoadedDiff.
        try self.page.file_search.filter.applyWithSourceIndexes(allocator, labels.items, node_indexes.items, query);
        return self.page.file_search.filter.sourceIndex(0);
    }

    pub fn loadedDiff(self: Controller) ?*LoadedDiff {
        return self.activeLoadedDiff();
    }

    pub fn activeLoadedDiff(self: Controller) ?*LoadedDiff {
        return switch (self.page.load.state) {
            .loaded => |*session| &session.loaded,
            else => null,
        };
    }

    pub fn loadArenaAllocator(self: Controller) ?std.mem.Allocator {
        return switch (self.page.load.state) {
            .loaded => |*session| session.arena.allocator(),
            .failed => |*failed| failed.arena.allocator(),
            else => null,
        };
    }
};

pub fn findNodeByPathKey(loaded: *const LoadedDiff, path_key: []const u8) ?usize {
    for (loaded.tree.nodes, 0..) |node, index| {
        const node_key = if (node.path_key.len > 0) node.path_key else node.path;
        if (std.mem.eql(u8, node_key, path_key)) return index;
    }
    return null;
}

pub fn nearestVisibleFileNode(loaded: *const LoadedDiff, visible_row: usize) ?usize {
    var row = visible_row;
    while (row < loaded.visibleNodeCount()) : (row += 1) {
        const node_index = loaded.visibleNodeAt(row) orelse continue;
        if (loaded.tree.nodes[node_index].kind == .file) return node_index;
    }

    row = @min(visible_row, loaded.visibleNodeCount() - 1);
    while (true) {
        const node_index = loaded.visibleNodeAt(row) orelse return null;
        if (loaded.tree.nodes[node_index].kind == .file) return node_index;
        if (row == 0) break;
        row -= 1;
    }
    return null;
}

fn projectionSourceKind(source: diff_source.SourceMode) review_projection.SourceKind {
    return switch (source) {
        .cached => .cached,
        else => .unstaged,
    };
}

fn contentWidth(width: u16) u16 {
    return review_layout.diffContentWidth(width);
}

fn sidebarWidth(total_width: u16, preferred_width: ?u16) u16 {
    return review_layout.sidebarWidth(total_width, preferred_width);
}

fn maxHorizontalScrollForBodyRow(body_row: diff_view_model.BodyRow, pane_width: u16, line_numbers: bool) usize {
    return switch (body_row) {
        .unified_line => |line| maxHorizontalScrollForText(line.text, visibleTextWidth(pane_width, diff_render.lineTextStart(line_numbers, .unified))),
        .side_by_side => |side_row| maxHorizontalScrollForSideBySideRow(side_row, pane_width, line_numbers),
        else => 0,
    };
}

fn maxHorizontalScrollForSideBySideRow(side_row: diff_view_model.SideBySideRow, pane_width: u16, line_numbers: bool) usize {
    const gutter_col = pane_width / 2;
    const new_col = gutter_col + 1;
    const text_col = diff_render.lineTextStart(line_numbers, .side_by_side);
    const old_text_width: u16 = visibleTextWidth(gutter_col, text_col);
    const new_width: u16 = if (pane_width > new_col) pane_width - new_col else 0;
    const new_text_width: u16 = visibleTextWidth(new_width, text_col);
    var max_scroll: usize = 0;
    switch (side_row) {
        .single => |line| {
            switch (line.kind) {
                .added => max_scroll = @max(max_scroll, maxHorizontalScrollForText(line.text, new_text_width)),
                .context => {
                    max_scroll = @max(max_scroll, maxHorizontalScrollForText(line.text, old_text_width));
                    max_scroll = @max(max_scroll, maxHorizontalScrollForText(line.text, new_text_width));
                },
                else => max_scroll = @max(max_scroll, maxHorizontalScrollForText(line.text, old_text_width)),
            }
        },
        .paired => |pair| {
            if (pair.removed) |line| max_scroll = @max(max_scroll, maxHorizontalScrollForText(line.text, old_text_width));
            if (pair.added) |line| max_scroll = @max(max_scroll, maxHorizontalScrollForText(line.text, new_text_width));
        },
    }
    return max_scroll;
}

fn visibleTextWidth(total_width: u16, text_col: u16) u16 {
    return if (total_width > text_col) total_width - text_col else 0;
}

fn maxHorizontalScrollForText(text: []const u8, visible_width: u16) usize {
    const width = chasen.text.displayWidth(text);
    if (width <= visible_width) return 0;
    return width - visible_width;
}

const TestHarness = struct {
    const PageStates = struct {
        review: review_page.ReviewPageState = .{},
    };

    pages: PageStates = .{},
    status: app_state.StatusMessage = .{},
    source: diff_source.SourceMode = .unstaged,
    repo_root: ?[]const u8 = null,
    terminal_size: chasen.Size = .{ .width = 100, .height = 20 },
    allocator: ?std.mem.Allocator = null,

    fn init(page: review_page.ReviewPageState, terminal_size: chasen.Size) TestHarness {
        return .{
            .pages = .{ .review = page },
            .terminal_size = terminal_size,
        };
    }

    fn controller(self: *TestHarness) Controller {
        const body_size = shell_layout.compute(self.terminal_size, .{ .page_bar_visible = true }).bodySize();
        return .{
            .page = &self.pages.review,
            .repo_root = self.repo_root,
            .source = self.source,
            .layout = .{ .width = body_size.width, .height = body_size.height },
            .diagnostics = .{ .target = &self.status },
        };
    }

    fn view(self: *const TestHarness) View {
        const body_size = shell_layout.compute(self.terminal_size, .{ .page_bar_visible = true }).bodySize();
        return .{
            .page = &self.pages.review,
            .repo_root = self.repo_root,
            .source = self.source,
            .layout = .{ .width = body_size.width, .height = body_size.height },
        };
    }

    fn reviewNavigation(self: *TestHarness) Controller {
        return self.controller();
    }

    fn reviewNavigationView(self: *const TestHarness) View {
        return self.view();
    }

    fn selectedHunkIndex(self: *const TestHarness) ?usize {
        return self.view().selectedHunkIndex();
    }

    fn visibleDiffCursorOffset(self: *const TestHarness) ?usize {
        return self.view().visibleDiffCursorOffset();
    }

    fn selectedStatusEntry(self: *const TestHarness) ?git_status.StatusEntry {
        return self.view().selectedStatusEntry();
    }

    fn clearLoadedDiff(self: *TestHarness) void {
        self.pages.review.source_session_revision +%= 1;
        self.controller().clearDiffSelection();
        self.pages.review.load.clearCurrent(self.allocator);
        if (self.allocator) |allocator| {
            self.pages.review.review_projection.deinit(allocator);
            self.pages.review.staged_hunks.clear(allocator);
        }
        self.pages.review.viewer.diff_scroll = 0;
        self.pages.review.viewer.diff_horizontal_scroll = 0;
        self.pages.review.viewer.sidebar_horizontal_scroll = 0;
        self.pages.review.viewer.diff_cursor = .{ .metadata = 0 };
        self.controller().clearSearchMatch();
    }
};

fn expectSearchCoordinate(app: *const TestHarness, expected: diff_view_model.BodyCoordinate) !void {
    try std.testing.expect(app.pages.review.search.match != null);
    try std.testing.expect(std.meta.eql(expected, app.pages.review.search.match.?.coordinate));
}

fn setDiffSearchQuery(app: *TestHarness, query: []const u8) void {
    @memcpy(app.pages.review.search.query.buffer[0..query.len], query);
    app.pages.review.search.query.len = query.len;
    app.pages.review.search.query.cursor = query.len;
    @memcpy(app.pages.review.search.input.buffer[0..query.len], query);
    app.pages.review.search.input.len = query.len;
    app.pages.review.search.input.cursor = query.len;
}

fn setDiffSearchInput(app: *TestHarness, query: []const u8) void {
    @memcpy(app.pages.review.search.input.buffer[0..query.len], query);
    app.pages.review.search.input.len = query.len;
    app.pages.review.search.input.cursor = query.len;
}

fn setFileSearchInput(app: *TestHarness, query: []const u8) void {
    @memcpy(app.pages.review.file_search.input.buffer[0..query.len], query);
    app.pages.review.file_search.input.len = query.len;
    app.pages.review.file_search.input.cursor = query.len;
}

test "Review navigation keeps diff position at file selection boundary" {
    var harness = TestHarness.init(.{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{
            .diff_scroll = 4,
            .diff_cursor = .{ .hunk_header = 1 },
        },
    }, .{ .width = 100, .height = 8 });

    harness.controller().selectFileDelta(-1);
    try std.testing.expectEqual(@as(usize, 0), harness.pages.review.viewer.selected_file);
    try std.testing.expectEqual(@as(usize, 4), harness.pages.review.viewer.diff_scroll);
    try std.testing.expectEqual(@as(?usize, 1), harness.view().selectedHunkIndex());

    harness.controller().selectFileAbsolute(0);
    try std.testing.expectEqual(@as(usize, 4), harness.pages.review.viewer.diff_scroll);
    try std.testing.expectEqual(@as(?usize, 1), harness.view().selectedHunkIndex());
}

test "Review navigation keeps selected hunk visible across mode changes" {
    var harness = TestHarness.init(.{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{
            .display_mode = .unified,
            .diff_cursor = .{ .hunk_header = 1 },
        },
    }, .{ .width = 100, .height = 8 });

    harness.controller().scrollSelectedHunkIntoView();
    try std.testing.expect(harness.pages.review.viewer.diff_scroll > 0);

    harness.pages.review.viewer.display_mode = .side_by_side;
    harness.controller().clampDiffNavigationKeepingHunkVisible();

    const target = diff_view_model.hunkBodyLineOffset(
        test_support.file_with_hunks,
        harness.view().effectiveDisplayMode(),
        harness.view().selectedHunkIndex().?,
    );
    const visible_rows = harness.view().diffVisibleRows();
    try std.testing.expect(target >= harness.pages.review.viewer.diff_scroll);
    try std.testing.expect(target < harness.pages.review.viewer.diff_scroll + visible_rows);
}

test "Review navigation initializes cursor at first rendered body row" {
    var metadata = TestHarness.init(.{
        .load = test_support.loadState(test_support.loadedDiffMetadataOnly()),
    }, .{ .width = 100, .height = 12 });
    metadata.controller().initializeDiffCursorForSelectedFile();
    try std.testing.expectEqual(diff_view_model.BodyCoordinate{ .metadata = 1 }, metadata.pages.review.viewer.diff_cursor);
    try std.testing.expectEqual(@as(?usize, 0), metadata.view().visibleDiffCursorOffset());

    var binary = TestHarness.init(.{
        .load = test_support.loadState(test_support.loadedDiffBinaryOnly()),
    }, .{ .width = 100, .height = 12 });
    binary.controller().initializeDiffCursorForSelectedFile();
    try std.testing.expectEqual(diff_view_model.BodyCoordinate.binary_marker, binary.pages.review.viewer.diff_cursor);
    try std.testing.expectEqual(@as(?usize, 0), binary.view().visibleDiffCursorOffset());
}

test "Review mouse selection stays on its originating diff side" {
    var harness = TestHarness.init(.{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{
            .display_mode = .side_by_side,
            .sidebar_hidden = true,
        },
    }, .{ .width = 140, .height = 11 });

    harness.controller().pressDiffMouse(.{
        .col = 4,
        .row = diff_render.body_start_row + 1,
    });
    const started = harness.pages.review.selection_owner.activeDiff() orelse return error.ExpectedDiffSelection;
    try std.testing.expectEqual(diff_selection.Side.old, started.side);
    try std.testing.expectEqual(@as(usize, 0), started.focus.line_index);

    harness.controller().dragDiffMouse(.{
        .col = 72,
        .row = diff_render.body_start_row + 3,
    });
    const dragged = harness.pages.review.selection_owner.activeDiff() orelse return error.ExpectedDiffSelection;
    try std.testing.expectEqual(diff_selection.Side.old, dragged.side);
    try std.testing.expectEqual(@as(usize, 2), dragged.focus.line_index);
    try std.testing.expect(dragged.moved);
}

test "Review navigation snapshot and reload restore share the page owner" {
    const allocator = std.testing.allocator;
    var harness = TestHarness.init(.{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{
            .selected_target = .{ .diff_file = 0 },
            .selected_node = 0,
            .display_mode = .unified,
            .diff_cursor = .{ .hunk_header = 1 },
            .diff_scroll = 4,
            .diff_horizontal_scroll = 3,
            .sidebar_horizontal_scroll = 2,
        },
        .search = .{
            .match = .{ .coordinate = .{ .hunk_header = 1 } },
            .match_offset = 6,
        },
    }, .{ .width = 100, .height = 8 });

    const snapshot = harness.view().displayNavigationSnapshot();
    try std.testing.expectEqual(@as(usize, 4), snapshot.diff_scroll);
    try std.testing.expectEqual(@as(?usize, 6), snapshot.search_match_offset);

    var anchor: review_page.ReloadAnchor = .{
        .path_key = try allocator.dupe(u8, "a"),
        .selected_target_tag = .diff_file,
        .visible_sidebar_row = 0,
        .diff_cursor = snapshot.diff_cursor,
        .diff_cursor_offset = harness.view().selectedDiffCursorOffset(),
        .diff_scroll = snapshot.diff_scroll,
        .diff_horizontal_scroll = snapshot.diff_horizontal_scroll,
        .sidebar_horizontal_scroll = snapshot.sidebar_horizontal_scroll,
        .search_coordinate = snapshot.search_coordinate,
    };
    defer anchor.deinit(allocator);

    harness.pages.review.viewer.diff_cursor = .{ .metadata = 0 };
    harness.pages.review.viewer.diff_scroll = 0;
    harness.pages.review.viewer.diff_horizontal_scroll = 0;
    harness.pages.review.viewer.sidebar_horizontal_scroll = 0;
    harness.pages.review.search.match = null;
    harness.pages.review.search.match_offset = null;

    const loaded = harness.controller().activeLoadedDiff() orelse return error.ExpectedLoadedDiff;
    try std.testing.expect(harness.controller().restoreReloadAnchor(loaded, &anchor));
    try std.testing.expectEqual(snapshot.diff_cursor, harness.pages.review.viewer.diff_cursor);
    try std.testing.expect(harness.pages.review.viewer.diff_scroll >= snapshot.diff_scroll);
    try std.testing.expect(harness.view().visibleDiffCursorOffset() != null);
    try std.testing.expect(harness.pages.review.viewer.diff_horizontal_scroll <= snapshot.diff_horizontal_scroll);
    try std.testing.expect(harness.pages.review.viewer.sidebar_horizontal_scroll <= snapshot.sidebar_horizontal_scroll);
}

test "sidebar visibility toggle uses full diff width and keeps selection" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{
                .focus = .sidebar,
                .selected_file = 0,
                .selected_node = 1,
                .display_mode = .side_by_side,
            },
        } },
        .terminal_size = .{ .width = 80, .height = 8 },
    };

    try std.testing.expectEqual(diff_render.DisplayMode.unified, app.reviewNavigationView().effectiveDisplayMode());

    app.reviewNavigation().toggleSidebarVisibility();

    try std.testing.expect(app.pages.review.viewer.sidebar_hidden);
    try std.testing.expectEqual(review_page.Focus.diff, app.pages.review.viewer.focus);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.selected_file);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(diff_render.DisplayMode.side_by_side, app.reviewNavigationView().effectiveDisplayMode());

    app.reviewNavigation().toggleSidebarVisibility();

    try std.testing.expect(!app.pages.review.viewer.sidebar_hidden);
    try std.testing.expectEqual(review_page.Focus.diff, app.pages.review.viewer.focus);
    try std.testing.expectEqual(diff_render.DisplayMode.unified, app.reviewNavigationView().effectiveDisplayMode());
}

test "sidebar width adjustment clamps and affects effective mode" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{ .display_mode = .side_by_side },
        } },
        .terminal_size = .{ .width = 104, .height = 8 },
    };

    try std.testing.expectEqual(@as(?u16, null), app.pages.review.viewer.sidebar_width);
    try std.testing.expectEqual(diff_render.DisplayMode.unified, app.reviewNavigationView().effectiveDisplayMode());

    app.reviewNavigation().adjustSidebarWidth(.shrink);
    try std.testing.expectEqual(@as(?u16, 30), app.pages.review.viewer.sidebar_width);
    try std.testing.expectEqual(diff_render.DisplayMode.unified, app.reviewNavigationView().effectiveDisplayMode());

    app.reviewNavigation().adjustSidebarWidth(.shrink);
    try std.testing.expectEqual(@as(?u16, 26), app.pages.review.viewer.sidebar_width);
    try std.testing.expectEqual(diff_render.DisplayMode.side_by_side, app.reviewNavigationView().effectiveDisplayMode());

    app.reviewNavigation().adjustSidebarWidth(.grow);
    try std.testing.expectEqual(@as(?u16, 30), app.pages.review.viewer.sidebar_width);
}

test "sidebar width remains stored while sidebar is hidden" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{ .display_mode = .side_by_side },
        } },
        .terminal_size = .{ .width = 104, .height = 8 },
    };

    app.reviewNavigation().adjustSidebarWidth(.shrink);
    app.reviewNavigation().toggleSidebarVisibility();
    app.reviewNavigation().adjustSidebarWidth(.shrink);

    try std.testing.expect(app.pages.review.viewer.sidebar_hidden);
    try std.testing.expectEqual(@as(?u16, 26), app.pages.review.viewer.sidebar_width);
    try std.testing.expectEqual(diff_render.DisplayMode.side_by_side, app.reviewNavigationView().effectiveDisplayMode());

    app.reviewNavigation().toggleSidebarVisibility();

    try std.testing.expect(!app.pages.review.viewer.sidebar_hidden);
    try std.testing.expectEqual(@as(?u16, 26), app.pages.review.viewer.sidebar_width);
    try std.testing.expectEqual(diff_render.DisplayMode.side_by_side, app.reviewNavigationView().effectiveDisplayMode());
}

test "horizontal scroll uses diff focus arrows and clamps to visible text" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffWide()),
            .viewer = .{ .focus = .diff, .display_mode = .unified },
        } },
        .terminal_size = .{ .width = 80, .height = 12 },
    };

    app.reviewNavigation().scrollDiffHorizontal(.right);
    try std.testing.expectEqual(@as(usize, 8), app.pages.review.viewer.diff_horizontal_scroll);

    for (0..20) |_| app.reviewNavigation().scrollDiffHorizontal(.right);
    try std.testing.expect(app.pages.review.viewer.diff_horizontal_scroll > 0);
    try std.testing.expect(app.pages.review.viewer.diff_horizontal_scroll <= app.reviewNavigationView().visibleBodyTextMaxHorizontalScroll());

    app.reviewNavigation().scrollDiffHorizontal(.left);
    try std.testing.expect(app.pages.review.viewer.diff_horizontal_scroll <= app.reviewNavigationView().visibleBodyTextMaxHorizontalScroll());
}

test "layout changes reset horizontal scroll only when diff pane width changes" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffWide()),
            .viewer = .{
                .display_mode = .side_by_side,
                .diff_horizontal_scroll = 16,
            },
        } },
        .terminal_size = .{ .width = 100, .height = 8 },
    };

    app.reviewNavigation().toggleSidebarVisibility();
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.diff_horizontal_scroll);

    app.pages.review.viewer.diff_horizontal_scroll = 16;
    app.reviewNavigation().adjustSidebarWidth(.shrink);
    try std.testing.expectEqual(@as(usize, 16), app.pages.review.viewer.diff_horizontal_scroll);

    app.reviewNavigation().toggleSidebarVisibility();
    app.pages.review.viewer.diff_horizontal_scroll = 16;
    app.reviewNavigation().adjustSidebarWidth(.shrink);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.diff_horizontal_scroll);
}

test "search resync without pane width change keeps horizontal scroll" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffWide()),
            .viewer = .{
                .display_mode = .side_by_side,
                .sidebar_hidden = true,
            },
        } },
        .terminal_size = .{ .width = 100, .height = 8 },
    };

    setDiffSearchQuery(&app, "wide");
    app.reviewNavigation().submitSearch();
    app.pages.review.viewer.diff_horizontal_scroll = 16;

    app.reviewNavigation().adjustSidebarWidth(.shrink);

    try std.testing.expectEqual(@as(usize, 16), app.pages.review.viewer.diff_horizontal_scroll);
}

test "mouse diff scroll keeps cursor in the viewport" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{
                .display_mode = .unified,
                .sidebar_hidden = true,
                .diff_scroll = 12,
                .diff_cursor = .{ .hunk_header = 0 },
            },
        } },
        .terminal_size = .{ .width = 140, .height = 8 },
    };

    try std.testing.expect(app.visibleDiffCursorOffset() == null);

    app.reviewNavigation().scrollDiff(.down);

    try std.testing.expect(app.visibleDiffCursorOffset() != null);
}

test "diff scroll keeps visible cursor screen position stable" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{
                .display_mode = .unified,
                .sidebar_hidden = true,
                .diff_scroll = 3,
            },
        } },
        .terminal_size = .{ .width = 140, .height = 9 },
    };
    const old_scroll = app.pages.review.viewer.diff_scroll;
    const old_offset = old_scroll + 1;
    app.pages.review.viewer.diff_cursor = app.reviewNavigationView().selectedCoordinateAtOffset(old_offset) orelse return error.ExpectedCoordinate;

    app.reviewNavigation().scrollDiff(.down);

    const new_offset = app.reviewNavigationView().selectedDiffCursorOffset() orelse return error.ExpectedCursorOffset;
    try std.testing.expectEqual(old_offset - old_scroll, new_offset - app.pages.review.viewer.diff_scroll);
}

test "diff scroll syncs invisible cursor to scrolloff margin" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{
                .display_mode = .unified,
                .sidebar_hidden = true,
            },
        } },
        .terminal_size = .{ .width = 140, .height = 8 },
    };
    const line_count = app.reviewNavigationView().selectedFileLineIndex(app.reviewNavigationView().effectiveDisplayMode()).lineCount();
    const visible_rows = app.reviewNavigationView().diffVisibleRows();
    const margin = @min(@as(usize, 8), visible_rows / 3);

    app.pages.review.viewer.diff_scroll = 0;
    app.pages.review.viewer.diff_cursor = app.reviewNavigationView().selectedCoordinateAtOffset(line_count - 1) orelse return error.ExpectedCoordinate;
    app.reviewNavigation().scrollDiff(.up);
    try std.testing.expectEqual(app.pages.review.viewer.diff_scroll + margin, app.reviewNavigationView().selectedDiffCursorOffset().?);

    app.pages.review.viewer.diff_scroll = line_count - visible_rows;
    app.pages.review.viewer.diff_cursor = app.reviewNavigationView().selectedCoordinateAtOffset(0) orelse return error.ExpectedCoordinate;
    app.reviewNavigation().scrollDiff(.down);
    try std.testing.expectEqual(app.pages.review.viewer.diff_scroll + visible_rows - 1 -| margin, app.reviewNavigationView().selectedDiffCursorOffset().?);
}

test "diff row movement continues from wheel-synced visible cursor" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{
                .display_mode = .unified,
                .sidebar_hidden = true,
            },
        } },
        .terminal_size = .{ .width = 140, .height = 8 },
    };
    const line_count = app.reviewNavigationView().selectedFileLineIndex(app.reviewNavigationView().effectiveDisplayMode()).lineCount();
    app.pages.review.viewer.diff_scroll = 0;
    app.pages.review.viewer.diff_cursor = app.reviewNavigationView().selectedCoordinateAtOffset(line_count - 1) orelse return error.ExpectedCoordinate;

    app.reviewNavigation().scrollDiff(.up);
    const synced_offset = app.reviewNavigationView().selectedDiffCursorOffset() orelse return error.ExpectedCursorOffset;
    app.reviewNavigation().moveDiffCursorRows(.down);

    try std.testing.expectEqual(synced_offset + 1, app.reviewNavigationView().selectedDiffCursorOffset().?);
}

test "diff header mouse press starts header path owner only on path target" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{
                .display_mode = .side_by_side,
                .sidebar_hidden = true,
            },
        } },
        .terminal_size = .{ .width = 140, .height = 10 },
    };

    app.reviewNavigation().pressDiffMouse(.{ .col = 1, .row = 0 });
    const header = app.pages.review.selection_owner.activeHeader() orelse return error.ExpectedHeaderSelection;
    try std.testing.expectEqual(diff_selection.HeaderKind.loaded_file, header.identity.kind);
    try std.testing.expectEqualStrings("a", header.identity.path_key);

    app.reviewNavigation().dragDiffMouse(.{ .col = 4, .row = diff_render.body_start_row + 1 });
    try std.testing.expect(app.pages.review.selection_owner.activeHeader() != null);
    try std.testing.expect(app.pages.review.selection_owner.activeDiff() == null);

    app.reviewNavigation().clearDiffSelection();
    app.reviewNavigation().pressDiffMouse(.{ .col = 120, .row = 0 });
    try std.testing.expect(app.pages.review.selection_owner.activeHeader() == null);
    try std.testing.expect(app.pages.review.selection_owner.activeDiff() == null);
}

test "sidebar layout fallback clears active diff mouse drag" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{
                .display_mode = .side_by_side,
                .sidebar_hidden = true,
            },
        } },
        .terminal_size = .{ .width = 90, .height = 10 },
    };

    app.reviewNavigation().pressDiffMouse(.{ .col = 4, .row = diff_render.body_start_row + 1 });
    try std.testing.expect(app.pages.review.selection_owner.activeDiff() != null);

    app.reviewNavigation().toggleSidebarVisibility();
    try std.testing.expectEqual(diff_render.DisplayMode.unified, app.reviewNavigationView().effectiveDisplayMode());
    try std.testing.expect(app.pages.review.selection_owner.activeDiff() == null);
}

test "sidebar width growth fallback clears active diff mouse drag" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{
                .display_mode = .side_by_side,
                .sidebar_hidden = false,
                .sidebar_width = 31,
            },
        } },
        .terminal_size = .{ .width = 110, .height = 10 },
    };

    try std.testing.expectEqual(diff_render.DisplayMode.side_by_side, app.reviewNavigationView().effectiveDisplayMode());
    app.reviewNavigation().pressDiffMouse(.{ .col = 37, .row = diff_render.body_start_row + 1 });
    try std.testing.expect(app.pages.review.selection_owner.activeDiff() != null);

    app.reviewNavigation().adjustSidebarWidth(.grow);
    try std.testing.expectEqual(diff_render.DisplayMode.unified, app.reviewNavigationView().effectiveDisplayMode());
    try std.testing.expect(app.pages.review.selection_owner.activeDiff() == null);
}

test "diff scroll cursor sync keeps search state" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{
                .display_mode = .unified,
                .sidebar_hidden = true,
                .diff_scroll = 12,
                .diff_cursor = .{ .hunk_header = 0 },
            },
        } },
        .terminal_size = .{ .width = 140, .height = 8 },
    };
    setDiffSearchQuery(&app, "late new");
    app.reviewNavigation().submitSearch();
    const old_match = app.pages.review.search.match orelse return error.ExpectedSearchMatch;
    const old_match_offset = app.pages.review.search.match_offset;

    app.reviewNavigation().scrollDiff(.down);

    try std.testing.expect(std.meta.eql(old_match, app.pages.review.search.match.?));
    try std.testing.expectEqual(old_match_offset, app.pages.review.search.match_offset);
}

test "display mode scroll remap preserves hunk-local ratio" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var loaded = app_test_support.loadedDiffOne();
    loaded.rendered_line_cache = try diff_view_model.RenderedLineCache.build(allocator, loaded.document);

    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(loaded),
            .viewer = .{
                .display_mode = .unified,
                .sidebar_hidden = true,
            },
        } },
        .terminal_size = .{ .width = 140, .height = 8 },
    };

    const old_index = app.reviewNavigationView().selectedFileLineIndex(.unified);
    const old_scroll = old_index.hunkOffset(0) + 3;
    const new_scroll = app.reviewNavigationView().remapDiffScrollForModeChange(.unified, .side_by_side, old_scroll);

    const hunk_index = old_index.hunkIndexAtOffset(old_scroll) orelse return error.ExpectedHunkOffset;
    const new_index = app.reviewNavigationView().selectedFileLineIndex(.side_by_side);
    const old_local = old_scroll - old_index.hunkOffset(hunk_index);
    const expected_local = old_local * (new_index.hunkLineCount(hunk_index) - 1) / (old_index.hunkLineCount(hunk_index) - 1);
    try std.testing.expectEqual(new_index.hunkOffset(hunk_index) + expected_local, new_scroll);
}

test "mode change resyncs search match to rendered body offsets" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{ .display_mode = .unified },
        } },
        .terminal_size = .{ .width = 140, .height = 14 },
    };
    setDiffSearchQuery(&app, "late new");

    app.reviewNavigation().submitSearch();
    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 1, .line_index = 2 } });
    try std.testing.expectEqual(@as(?usize, 9), app.pages.review.search.match_offset);

    app.pages.review.viewer.display_mode = .side_by_side;
    app.reviewNavigation().clampDiffNavigationKeepingHunkVisible();
    app.reviewNavigation().updateSearchMatchOffset();

    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 1, .line_index = 2 } });
    try std.testing.expectEqual(@as(?usize, 7), app.pages.review.search.match_offset);
    try std.testing.expect(app.pages.review.search.match_offset.? >= app.pages.review.viewer.diff_scroll);
    try std.testing.expect(app.pages.review.search.match_offset.? < app.pages.review.viewer.diff_scroll + app.reviewNavigationView().diffVisibleRows());
}

test "mode change keeps search near later matches" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{ .display_mode = .unified },
        } },
        .terminal_size = .{ .width = 140, .height = 8 },
    };
    setDiffSearchQuery(&app, "new");

    app.reviewNavigation().submitSearch();
    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 0, .line_index = 3 } });
    try std.testing.expectEqual(@as(?usize, 4), app.pages.review.search.match_offset);
    app.reviewNavigation().selectSearchMatch(.forward);
    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 1, .line_index = 2 } });
    try std.testing.expectEqual(@as(?usize, 9), app.pages.review.search.match_offset);

    app.pages.review.viewer.display_mode = .side_by_side;
    app.reviewNavigation().clampDiffNavigationKeepingHunkVisible();
    app.reviewNavigation().updateSearchMatchOffset();

    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 1, .line_index = 2 } });
    try std.testing.expectEqual(@as(?usize, 7), app.pages.review.search.match_offset);
}

test "toggle selected hunk fold updates active rendered line cache" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    const allocator = arena.allocator();
    var loaded = app_test_support.loadedDiffOne();
    loaded.collapsed_hunks = try allocator.alloc(bool, loaded.document.totalHunks());
    @memset(loaded.collapsed_hunks, false);
    loaded.rendered_line_cache = try diff_view_model.RenderedLineCache.build(allocator, loaded.document);

    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(arena, loaded),
            .viewer = .{ .diff_cursor = .{ .hunk_header = 0 } },
        } },
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer app.clearLoadedDiff();

    try std.testing.expectEqual(@as(usize, 10), app.reviewNavigationView().selectedFileLineIndex(.unified).lineCount());
    app.reviewNavigation().toggleSelectedHunkFold();

    const active = app.reviewNavigation().loadedDiff().?;
    try std.testing.expect(active.isHunkFolded(0, 0));
    try std.testing.expectEqual(@as(usize, 5), app.reviewNavigationView().selectedFileLineIndex(.unified).lineCount());
    try std.testing.expectEqual(@as(usize, 1), active.renderedLineIndex(0, .unified).hunkLineCount(0));
    try std.testing.expectEqual(@as(usize, 4), app.reviewNavigationView().selectedFileLineIndex(.side_by_side).lineCount());
    try std.testing.expectEqual(@as(usize, 1), active.renderedLineIndex(0, .side_by_side).hunkLineCount(0));
}

test "search unfolds folded hunk body matches before setting offset" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    const allocator = arena.allocator();
    var loaded = app_test_support.loadedDiffOne();
    loaded.collapsed_hunks = try allocator.alloc(bool, loaded.document.totalHunks());
    @memset(loaded.collapsed_hunks, false);
    loaded.rendered_line_cache = try diff_view_model.RenderedLineCache.build(allocator, loaded.document);
    loaded.setHunkFolded(0, 0, true);

    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(arena, loaded),
        } },
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer app.clearLoadedDiff();
    setDiffSearchQuery(&app, "new");

    app.reviewNavigation().submitSearch();

    const active = app.reviewNavigation().loadedDiff().?;
    try std.testing.expect(!active.isHunkFolded(0, 0));
    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 0, .line_index = 3 } });
    try std.testing.expectEqual(@as(?usize, 4), app.pages.review.search.match_offset);
}

test "manual fold keeps hunk open when it contains active search match" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    const allocator = arena.allocator();
    var loaded = app_test_support.loadedDiffOne();
    loaded.collapsed_hunks = try allocator.alloc(bool, loaded.document.totalHunks());
    @memset(loaded.collapsed_hunks, false);
    loaded.rendered_line_cache = try diff_view_model.RenderedLineCache.build(allocator, loaded.document);

    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(arena, loaded),
        } },
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer app.clearLoadedDiff();
    setDiffSearchQuery(&app, "new");
    app.reviewNavigation().submitSearch();

    app.reviewNavigation().toggleSelectedHunkFold();

    const active = app.reviewNavigation().loadedDiff().?;
    try std.testing.expect(!active.isHunkFolded(0, 0));
    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 0, .line_index = 3 } });
    try std.testing.expectEqual(@as(?usize, 4), app.pages.review.search.match_offset);
}

test "file change resyncs retained search query to selected file" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffTwo()),
            .viewer = .{ .display_mode = .unified },
        } },
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    setDiffSearchQuery(&app, "target");

    app.reviewNavigation().selectFileAbsolute(1);

    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_file);
    try expectSearchCoordinate(&app, .{ .metadata = 0 });
    try std.testing.expectEqual(@as(?usize, 0), app.pages.review.search.match_offset);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.diff_scroll);
}

test "sidebar navigation can select directories without changing selected file" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffNested()),
            .viewer = .{
                .selected_file = 0,
                .selected_node = 1,
            },
        } },
        .terminal_size = .{ .width = 100, .height = 12 },
    };

    app.reviewNavigation().selectFileDelta(-1);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.selected_file);

    app.reviewNavigation().selectFileDelta(1);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.selected_file);

    app.reviewNavigation().selectFileDelta(1);
    try std.testing.expectEqual(@as(usize, 2), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_file);
}

test "toggling selected directory collapses visible descendants" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), app_test_support.loadedDiffNested()),
            .viewer = .{
                .selected_file = 0,
                .selected_node = 0,
            },
        } },
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer app.clearLoadedDiff();

    try app.reviewNavigation().toggleSelectedDirectory();

    const loaded = app.pages.review.load.state.loaded.loaded;
    try std.testing.expect(file_tree.isCollapsed(&loaded.collapsed_dirs, "src"));
    try std.testing.expectEqual(@as(usize, 1), loaded.tree.visibleNodeCount(&loaded.collapsed_dirs));
    try std.testing.expect(loaded.visible_nodes.len >= loaded.tree.nodes.len);
    try std.testing.expectEqual(@as(usize, 1), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(?usize, 0), loaded.visibleNodeAt(0));
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.selected_node);
}

test "file search selects matching file and expands ancestors" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), app_test_support.loadedDiffNested()),
            .viewer = .{
                .selected_file = 0,
                .selected_node = 0,
            },
            .file_search = .{ .mode = true },
        } },
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer app.clearLoadedDiff();

    var loaded = app.reviewNavigation().loadedDiff().?;
    try file_tree.collapse(app.reviewNavigation().loadArenaAllocator().?, &loaded.collapsed_dirs, "src");
    setFileSearchInput(&app, "src/b");

    try app.reviewNavigation().submitFileSearch(std.testing.allocator);

    loaded = app.reviewNavigation().loadedDiff().?;
    try std.testing.expect(!file_tree.isCollapsed(&loaded.collapsed_dirs, "src"));
    try std.testing.expectEqual(@as(usize, 2), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_file);
    try std.testing.expect(!app.pages.review.file_search.mode);
}

test "file search keeps prompt open on no match" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffNested()),
            .file_search = .{ .mode = true },
        } },
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    setFileSearchInput(&app, "missing");

    defer app.pages.review.file_search.deinit(std.testing.allocator);

    try app.reviewNavigation().submitFileSearch(std.testing.allocator);

    try std.testing.expect(app.pages.review.file_search.mode);
    try std.testing.expect(app.pages.review.file_search.no_match);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.selected_file);
}

test "file search skips hidden reviewed matches" {
    var reviewed = [_]bool{ true, false };
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), .{
                .text = "",
                .document = .{ .files = &app_test_support.files_two },
                .file_text_eligibility = &.{ .selectable_utf8, .selectable_utf8 },
                .tree = .{ .nodes = &app_test_support.tree_nested_nodes },
                .reviewed_files = &reviewed,
                .collapsed_dirs = .{},
                .bytes = 0,
                .lines = 0,
            }),
            .file_search = .{ .mode = true },
            .review_display = .{ .hide_reviewed_files = true },
        } },
    };
    defer app.clearLoadedDiff();
    try app.reviewNavigation().loadedDiff().?.rebuildVisibleNodes(app.reviewNavigation().loadArenaAllocator().?, true, .all);
    setFileSearchInput(&app, "src");

    try app.reviewNavigation().submitFileSearch(std.testing.allocator);

    try std.testing.expect(!app.pages.review.file_search.mode);
    try std.testing.expect(!app.pages.review.file_search.no_match);
    try std.testing.expectEqual(@as(usize, 2), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_file);
}

test "file search trims empty input and restores focus on cancel" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffNested()),
            .viewer = .{ .focus = .diff },
        } },
        .terminal_size = .{ .width = 100, .height = 12 },
    };

    app.reviewNavigation().enterFileSearchMode();
    try std.testing.expectEqual(review_page.Focus.sidebar, app.pages.review.viewer.focus);
    setFileSearchInput(&app, "   ");

    try app.reviewNavigation().submitFileSearch(std.testing.allocator);

    try std.testing.expect(!app.pages.review.file_search.mode);
    try std.testing.expectEqual(review_page.Focus.diff, app.pages.review.viewer.focus);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.selected_file);
}

test "file search keeps diff focus while sidebar is hidden" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), app_test_support.loadedDiffNested()),
            .viewer = .{ .focus = .diff, .sidebar_hidden = true },
        } },
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer app.clearLoadedDiff();

    app.reviewNavigation().enterFileSearchMode();
    try std.testing.expectEqual(review_page.Focus.diff, app.pages.review.viewer.focus);
    setFileSearchInput(&app, "   ");

    try app.reviewNavigation().submitFileSearch(std.testing.allocator);

    try std.testing.expect(!app.pages.review.file_search.mode);
    try std.testing.expectEqual(review_page.Focus.diff, app.pages.review.viewer.focus);

    app.reviewNavigation().enterFileSearchMode();
    setFileSearchInput(&app, "src/b");

    try app.reviewNavigation().submitFileSearch(std.testing.allocator);

    try std.testing.expect(!app.pages.review.file_search.mode);
    try std.testing.expectEqual(review_page.Focus.diff, app.pages.review.viewer.focus);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_file);
}

test "selectedStagePathKey accepts diff and status-only selections" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffTwoWithStatuses()),
            .viewer = .{ .selected_target = .{ .diff_file = 0 } },
        } },
        .repo_root = "/repo",
    };
    defer app.clearLoadedDiff();

    try std.testing.expectEqualStrings("src/added.zig", app.reviewNavigationView().selectedStagePathKey().?);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? src/new.zig\x00");
    defer app.pages.review.git_status.deinit();
    try app.pages.review.git_status.replace("/repo", &status_bundle);
    app.pages.review.viewer.selected_target = .{ .status_only = 0 };

    try std.testing.expectEqualStrings("src/new.zig", app.reviewNavigationView().selectedStagePathKey().?);
}

test "cached preview uses displayed diff for cursor movement" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = .{ .generation = 7 },
            .status_load = .{ .generation = 3 },
            .viewer = .{ .selected_target = .{ .status_only = 0 }, .diff_cursor = .{ .hunk_header = 0 } },
        } },
        .terminal_size = .{ .width = 100, .height = 40 },
        .source = .unstaged,
        .repo_root = "/repo",
    };
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.review_projection.deinit(std.testing.allocator);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  a\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);

    const request = try app_review_projection.cloneRequest(
        std.testing.allocator,
        app_page.RequestIdentity.review(0, 1),
        1,
        "/repo",
        "a",
        .cached_diff,
        .unstaged,
        app.pages.review.source_session_revision,
        app.pages.review.status_snapshot_revision,
    );
    app.pages.review.review_projection.displayed = .{ .ready = .{
        .request = request,
        .value = .{ .cached_diff = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_cached_projection) },
    } };

    try std.testing.expectEqual(@as(?usize, 0), app.visibleDiffCursorOffset());
    app.reviewNavigation().moveDiffCursorRows(.down);
    try std.testing.expectEqual(@as(?usize, 1), app.visibleDiffCursorOffset());
    app.reviewNavigation().selectHunkDelta(1);
    try std.testing.expectEqual(diff_view_model.BodyCoordinate{ .hunk_header = 0 }, app.pages.review.viewer.diff_cursor);
}

test "cached preview supports diff search" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = .{ .generation = 7 },
            .status_load = .{ .generation = 3 },
            .viewer = .{ .selected_target = .{ .status_only = 0 }, .diff_cursor = .{ .hunk_header = 0 } },
        } },
        .terminal_size = .{ .width = 100, .height = 40 },
        .source = .unstaged,
        .repo_root = "/repo",
    };
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.review_projection.deinit(std.testing.allocator);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  a\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);

    const request = try app_review_projection.cloneRequest(
        std.testing.allocator,
        app_page.RequestIdentity.review(0, 1),
        1,
        "/repo",
        "a",
        .cached_diff,
        .unstaged,
        app.pages.review.source_session_revision,
        app.pages.review.status_snapshot_revision,
    );
    app.pages.review.review_projection.displayed = .{ .ready = .{
        .request = request,
        .value = .{ .cached_diff = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_cached_projection) },
    } };

    setDiffSearchInput(&app, "staged");
    app.reviewNavigation().submitSearch();

    try std.testing.expect(app.pages.review.search.match != null);
    try std.testing.expectEqual(diff_view_model.BodyCoordinate{
        .hunk_line = .{ .hunk_index = 0, .line_index = 1 },
    }, app.pages.review.search.match.?.coordinate);
    try std.testing.expectEqual(@as(?usize, 2), app.pages.review.search.match_offset);
    try std.testing.expectEqual(app.pages.review.search.match.?.coordinate, app.pages.review.viewer.diff_cursor);
}

test "generated preview uses metadata cursor rows and ignores hunk movement" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = .{ .generation = 7 },
            .status_load = .{ .generation = 3 },
            .viewer = .{ .selected_target = .{ .status_only = 0 }, .diff_cursor = .{ .metadata = 0 } },
        } },
        .terminal_size = .{ .width = 100, .height = 40 },
        .source = .unstaged,
        .repo_root = "/repo",
    };
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.review_projection.deinit(std.testing.allocator);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? src/new.zig\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);

    const request = try app_review_projection.cloneRequest(
        std.testing.allocator,
        app_page.RequestIdentity.review(0, 1),
        1,
        "/repo",
        "src/new.zig",
        .generated_added_file,
        .unstaged,
        app.pages.review.source_session_revision,
        app.pages.review.status_snapshot_revision,
    );
    app.pages.review.review_projection.displayed = .{ .ready = .{
        .request = request,
        .value = .{ .generated_added_file = try app_review_projection.generatedFileFromContent(std.testing.allocator, "src/new.zig", "one\ntwo\nthree\n") },
    } };

    try std.testing.expectEqual(@as(?usize, 0), app.visibleDiffCursorOffset());
    app.reviewNavigation().moveDiffCursorRows(.down);
    try std.testing.expectEqual(diff_view_model.BodyCoordinate{ .metadata = 1 }, app.pages.review.viewer.diff_cursor);
    try std.testing.expectEqual(@as(?usize, 1), app.visibleDiffCursorOffset());
    app.reviewNavigation().selectHunkDelta(1);
    try std.testing.expectEqual(diff_view_model.BodyCoordinate{ .metadata = 1 }, app.pages.review.viewer.diff_cursor);
}

test "generated preview blocks diff search" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = .{ .generation = 7 },
            .status_load = .{ .generation = 3 },
            .viewer = .{ .selected_target = .{ .status_only = 0 }, .diff_cursor = .{ .metadata = 0 } },
        } },
        .terminal_size = .{ .width = 100, .height = 40 },
        .source = .unstaged,
        .repo_root = "/repo",
    };
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.review_projection.deinit(std.testing.allocator);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? src/new.zig\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);

    const request = try app_review_projection.cloneRequest(
        std.testing.allocator,
        app_page.RequestIdentity.review(0, 1),
        1,
        "/repo",
        "src/new.zig",
        .generated_added_file,
        .unstaged,
        app.pages.review.source_session_revision,
        app.pages.review.status_snapshot_revision,
    );
    app.pages.review.review_projection.displayed = .{ .ready = .{
        .request = request,
        .value = .{ .generated_added_file = try app_review_projection.generatedFileFromContent(std.testing.allocator, "src/new.zig", "one\ntwo\nthree\n") },
    } };

    app.reviewNavigation().enterSearchMode();
    try std.testing.expect(!app.pages.review.search.mode);
    try std.testing.expectEqualStrings("search is unavailable for generated file preview", app.status.text());

    setDiffSearchInput(&app, "two");
    app.reviewNavigation().submitSearch();
    try std.testing.expect(app.pages.review.search.match == null);
    try std.testing.expect(app.pages.review.search.match_offset == null);
    try std.testing.expectEqualStrings("search is unavailable for generated file preview", app.status.text());
}

test "staged new file preview blocks diff search" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = .{ .generation = 7 },
            .status_load = .{ .generation = 3 },
            .viewer = .{ .selected_target = .{ .status_only = 0 }, .diff_cursor = .{ .hunk_header = 0 } },
        } },
        .terminal_size = .{ .width = 100, .height = 40 },
        .source = .unstaged,
        .repo_root = "/repo",
    };
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.review_projection.deinit(std.testing.allocator);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "A  src/new.zig\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);

    const request = try app_review_projection.cloneRequest(
        std.testing.allocator,
        app_page.RequestIdentity.review(0, 1),
        1,
        "/repo",
        "src/new.zig",
        .cached_diff,
        .unstaged,
        app.pages.review.source_session_revision,
        app.pages.review.status_snapshot_revision,
    );
    app.pages.review.review_projection.displayed = .{ .ready = .{
        .request = request,
        .value = .{ .cached_diff = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_cached_projection) },
    } };

    app.reviewNavigation().enterSearchMode();
    try std.testing.expect(!app.pages.review.search.mode);
    try std.testing.expectEqualStrings("search is unavailable for staged new file preview", app.status.text());

    setDiffSearchInput(&app, "staged");
    app.reviewNavigation().submitSearch();
    try std.testing.expect(app.pages.review.search.match == null);
    try std.testing.expect(app.pages.review.search.match_offset == null);
    try std.testing.expectEqualStrings("search is unavailable for staged new file preview", app.status.text());
}

test "staged new file preview does not refresh existing search query" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = .{ .generation = 7 },
            .status_load = .{ .generation = 3 },
            .viewer = .{ .selected_target = .{ .status_only = 0 }, .diff_cursor = .{ .hunk_header = 0 } },
        } },
        .terminal_size = .{ .width = 100, .height = 40 },
        .source = .unstaged,
        .repo_root = "/repo",
    };
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.review_projection.deinit(std.testing.allocator);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "A  src/new.zig\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);

    const request = try app_review_projection.cloneRequest(
        std.testing.allocator,
        app_page.RequestIdentity.review(0, 1),
        1,
        "/repo",
        "src/new.zig",
        .cached_diff,
        .unstaged,
        app.pages.review.source_session_revision,
        app.pages.review.status_snapshot_revision,
    );
    app.pages.review.review_projection.displayed = .{ .ready = .{
        .request = request,
        .value = .{ .cached_diff = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_cached_projection) },
    } };

    app.pages.review.search.query.insertSlice("staged") catch unreachable;
    app.reviewNavigation().refreshSearchForSelectedFile();

    try std.testing.expect(app.pages.review.search.match == null);
    try std.testing.expect(app.pages.review.search.match_offset == null);
}

test "stagedHunkFlagsForFile keeps partial staged display flags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
        } },
        .allocator = std.testing.allocator,
        .repo_root = "/repo",
    };
    defer app.pages.review.staged_hunks.deinit(std.testing.allocator);
    defer app.pages.review.git_status.deinit();

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "MM a\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);
    try app.pages.review.staged_hunks.add(std.testing.allocator, "/repo", "a", 0);

    const flags = try app.reviewNavigationView().stagedHunkFlagsForFile(arena.allocator(), app_test_support.file_with_hunks);
    try std.testing.expectEqual(@as(usize, 2), flags.len);
    try std.testing.expect(flags[0]);
    try std.testing.expect(!flags[1]);
}

test "stagedHunkFlagsForFile normalizes all staged hunks only when status is staged-only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
        } },
        .allocator = std.testing.allocator,
        .repo_root = "/repo",
    };
    defer app.pages.review.staged_hunks.deinit(std.testing.allocator);
    defer app.pages.review.git_status.deinit();

    try app.pages.review.staged_hunks.add(std.testing.allocator, "/repo", "a", 0);
    try app.pages.review.staged_hunks.add(std.testing.allocator, "/repo", "a", 1);

    var staged_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  a\x00");
    try app.pages.review.git_status.replace("/repo", &staged_bundle);
    try std.testing.expectEqual(@as(usize, 0), (try app.reviewNavigationView().stagedHunkFlagsForFile(arena.allocator(), app_test_support.file_with_hunks)).len);

    var mixed_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "MM a\x00");
    try app.pages.review.git_status.replace("/repo", &mixed_bundle);
    const mixed_flags = try app.reviewNavigationView().stagedHunkFlagsForFile(arena.allocator(), app_test_support.file_with_hunks);
    try std.testing.expectEqual(@as(usize, 2), mixed_flags.len);
    try std.testing.expect(mixed_flags[0]);
    try std.testing.expect(mixed_flags[1]);

    app.pages.review.status_load.pending = .{ .generation = 1 };
    const stale_flags = try app.reviewNavigationView().stagedHunkFlagsForFile(arena.allocator(), app_test_support.file_with_hunks);
    try std.testing.expectEqual(@as(usize, 2), stale_flags.len);
    try std.testing.expect(stale_flags[0]);
    try std.testing.expect(stale_flags[1]);

    app.pages.review.status_load.pending = null;
    var other_repo_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  a\x00");
    try app.pages.review.git_status.replace("/other", &other_repo_bundle);
    const missing_flags = try app.reviewNavigationView().stagedHunkFlagsForFile(arena.allocator(), app_test_support.file_with_hunks);
    try std.testing.expectEqual(@as(usize, 2), missing_flags.len);
    try std.testing.expect(missing_flags[0]);
    try std.testing.expect(missing_flags[1]);
}

test "pending selection restore can restore directory nodes" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffNested()),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_node = 1,
            },
        } },
    };
    defer app.reviewNavigation().clearPendingSelectionRestore(std.testing.allocator);

    try app.reviewNavigation().setPendingSelectionRestore(std.testing.allocator, "src");
    var loaded = app_test_support.loadedDiffNested();

    try std.testing.expect(app.reviewNavigation().restorePendingSelectionOrFallback(std.testing.allocator, &loaded));
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.review.viewer.selected_target.?);
}

test "pending selection restore can restore repository root node" {
    const nodes = [_]file_tree.Node{
        .{ .kind = .repo_root, .name = "repo", .path = "", .depth = 0, .target = .repo_root },
        .{ .kind = .file, .name = "main.zig", .path = "src/main.zig", .path_key = "src/main.zig", .depth = 1, .target = .{ .diff_file = 0 } },
    };
    var visible_nodes = [_]usize{ 0, 1 };
    var loaded: LoadedDiff = .{
        .text = "",
        .document = .{ .files = &app_test_support.files_one },
        .file_text_eligibility = &.{.selectable_utf8},
        .tree = .{ .nodes = &nodes },
        .visible_nodes = &visible_nodes,
        .visible_node_count = 2,
        .bytes = 0,
        .lines = 0,
    };
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_node = 1,
            },
        } },
    };
    defer app.reviewNavigation().clearPendingSelectionRestore(std.testing.allocator);

    try app.reviewNavigation().setPendingSelectionRestore(std.testing.allocator, "");

    try std.testing.expect(app.reviewNavigation().restorePendingSelectionOrFallback(std.testing.allocator, &loaded));
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, app.pages.review.viewer.selected_target.?);
}

test "changed file filter keeps only matching status rows" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), app_test_support.loadedDiffTwoWithStatuses()),
            .review_display = .{ .changed_file_filter = .added },
            .viewer = .{
                .selected_node = 1,
                .selected_target = .{ .diff_file = 1 },
                .selected_file = 1,
            },
        } },
    };
    defer app.clearLoadedDiff();

    try app.reviewNavigation().loadedDiff().?.rebuildVisibleNodes(app.reviewNavigation().loadArenaAllocator().?, false, app.pages.review.review_display.changed_file_filter);

    const loaded = app.reviewNavigation().loadedDiff().?;
    try std.testing.expectEqual(@as(usize, 1), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(?usize, 0), loaded.visibleNodeAt(0));
}

test "cycling changed file filter rebuilds visible nodes and reconciles selection" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), app_test_support.loadedDiffTwoWithStatuses()),
            .viewer = .{
                .selected_node = 1,
                .selected_target = .{ .diff_file = 1 },
                .selected_file = 1,
            },
        } },
    };
    defer app.clearLoadedDiff();

    try app.reviewNavigation().cycleChangedFileFilter();

    const loaded = app.reviewNavigation().loadedDiff().?;
    try std.testing.expectEqual(ChangedFileFilter.modified, app.pages.review.review_display.changed_file_filter);
    try std.testing.expectEqual(@as(usize, 0), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_file);
}

test "file search skips files outside active changed filter" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffTwoWithStatuses()),
            .file_search = .{ .mode = true },
            .review_display = .{ .changed_file_filter = .added },
        } },
    };
    setFileSearchInput(&app, "deleted");
    defer app.pages.review.file_search.deinit(std.testing.allocator);

    try app.reviewNavigation().submitFileSearch(std.testing.allocator);

    try std.testing.expect(app.pages.review.file_search.mode);
    try std.testing.expect(app.pages.review.file_search.no_match);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.selected_file);
}

test "toggleReviewedFile toggles selected diff target" {
    var reviewed = [_]bool{ false, false };
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(.{
                .text = "",
                .document = .{ .files = &app_test_support.files_two },
                .file_text_eligibility = &.{ .selectable_utf8, .selectable_utf8 },
                .tree = .{ .nodes = &app_test_support.tree_nested_nodes },
                .reviewed_files = &reviewed,
                .collapsed_dirs = .{},
                .bytes = 0,
                .lines = 0,
            }),
            .viewer = .{
                .selected_node = 0,
                .selected_file = 0,
            },
        } },
    };
    defer app.pages.review.reviewed_store.deinit(std.testing.allocator);

    try app.reviewNavigation().toggleReviewedFile(std.testing.allocator);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, &reviewed);

    app.pages.review.viewer.selected_node = 1;
    try app.reviewNavigation().toggleReviewedFile(std.testing.allocator);
    try std.testing.expectEqualSlices(bool, &.{ false, false }, &reviewed);

    try app.reviewNavigation().toggleReviewedFile(std.testing.allocator);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, &reviewed);
}

test "toggleReviewedFile uses selected target while cursor is on directory" {
    var reviewed = [_]bool{ false, false };
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(.{
                .text = "",
                .document = .{ .files = &app_test_support.files_two },
                .file_text_eligibility = &.{ .selectable_utf8, .selectable_utf8 },
                .tree = .{ .nodes = &app_test_support.tree_nested_nodes },
                .reviewed_files = &reviewed,
                .collapsed_dirs = .{},
                .bytes = 0,
                .lines = 0,
            }),
            .viewer = .{
                .selected_node = 0,
                .selected_target = .{ .diff_file = 1 },
                .selected_file = 1,
            },
        } },
    };
    defer app.pages.review.reviewed_store.deinit(std.testing.allocator);

    try app.reviewNavigation().toggleReviewedFile(std.testing.allocator);
    try std.testing.expectEqualSlices(bool, &.{ false, true }, &reviewed);
}

test "toggleReviewedFile ignores unkeyable files in repository input" {
    const unkeyable_files = [_]diff_parser.FileDiff{.{
        .header = "metadata only",
        .old_path = null,
        .new_path = null,
        .metadata = &.{},
        .hunks = &.{},
    }};
    const nodes = [_]file_tree.Node{
        .{ .kind = .file, .name = "metadata", .path = "metadata", .depth = 0, .target = .{ .diff_file = 0 } },
    };
    var reviewed = [_]bool{false};
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(.{
                .text = "",
                .document = .{ .files = &unkeyable_files },
                .file_text_eligibility = &.{.selectable_utf8},
                .tree = .{ .nodes = &nodes },
                .reviewed_files = &reviewed,
                .collapsed_dirs = .{},
                .bytes = 0,
                .lines = 0,
            }),
        } },
        .repo_root = "/repo",
    };

    try app.reviewNavigation().toggleReviewedFile(std.testing.allocator);
    try std.testing.expectEqualSlices(bool, &.{false}, &reviewed);
}

test "raw reviewed state stays in active load only" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffTwo()),
            .viewer = .{
                .selected_node = 0,
                .selected_file = 0,
            },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.clearLoadedDiff();
    defer app.pages.review.reviewed_store.deinit(std.testing.allocator);

    var loaded = app.reviewNavigation().loadedDiff().?;
    try app.reviewNavigation().materializeReviewedFiles(std.testing.allocator, loaded);
    app.pages.review.load.state.loaded.reviewed_files_owned = true;

    try app.reviewNavigation().toggleReviewedFile(std.testing.allocator);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, loaded.reviewed_files);

    app.clearLoadedDiff();
    app.pages.review.load.state = .{ .loaded = app_test_support.loadedSession(app_test_support.loadedDiffTwo()) };
    loaded = app.reviewNavigation().loadedDiff().?;
    try app.reviewNavigation().materializeReviewedFiles(std.testing.allocator, loaded);
    app.pages.review.load.state.loaded.reviewed_files_owned = true;

    try std.testing.expectEqualSlices(bool, &.{ false, false }, loaded.reviewed_files);
}

test "hide reviewed files removes reviewed file rows from visible list" {
    var reviewed = [_]bool{ true, false };
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), .{
                .text = "",
                .document = .{ .files = &app_test_support.files_two },
                .file_text_eligibility = &.{ .selectable_utf8, .selectable_utf8 },
                .tree = .{ .nodes = &app_test_support.tree_nested_nodes },
                .reviewed_files = &reviewed,
                .collapsed_dirs = .{},
                .bytes = 0,
                .lines = 0,
            }),
            .viewer = .{
                .selected_node = 1,
                .selected_file = 0,
            },
        } },
    };
    defer app.clearLoadedDiff();

    try app.reviewNavigation().toggleHideReviewedFiles();

    const loaded = app.reviewNavigation().loadedDiff().?;
    try std.testing.expect(app.pages.review.review_display.hide_reviewed_files);
    try std.testing.expectEqual(@as(usize, 2), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(?usize, 0), loaded.visibleNodeAt(0));
    try std.testing.expectEqual(@as(?usize, 2), loaded.visibleNodeAt(1));
    try std.testing.expectEqual(@as(usize, 2), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_file);
}

test "hide reviewed files removes directories with no visible file descendants" {
    var reviewed = [_]bool{ true, true };
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), .{
                .text = "",
                .document = .{ .files = &app_test_support.files_two },
                .file_text_eligibility = &.{ .selectable_utf8, .selectable_utf8 },
                .tree = .{ .nodes = &app_test_support.tree_nested_nodes },
                .reviewed_files = &reviewed,
                .collapsed_dirs = .{},
                .bytes = 0,
                .lines = 0,
            }),
            .viewer = .{
                .selected_node = 1,
                .selected_file = 0,
            },
        } },
    };
    defer app.clearLoadedDiff();

    try app.reviewNavigation().toggleHideReviewedFiles();

    const loaded = app.reviewNavigation().loadedDiff().?;
    try std.testing.expectEqual(@as(usize, 0), loaded.visibleNodeCount());
}

test "hide reviewed files keeps directories for non-contiguous unreviewed descendants" {
    var reviewed = [_]bool{ true, false };
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), .{
                .text = "",
                .document = .{ .files = &app_test_support.files_two },
                .file_text_eligibility = &.{ .selectable_utf8, .selectable_utf8 },
                .tree = .{ .nodes = &app_test_support.tree_non_contiguous_nodes },
                .reviewed_files = &reviewed,
                .collapsed_dirs = .{},
                .bytes = 0,
                .lines = 0,
            }),
            .viewer = .{
                .selected_node = 1,
                .selected_file = 0,
            },
        } },
    };
    defer app.clearLoadedDiff();

    try app.reviewNavigation().toggleHideReviewedFiles();

    const loaded = app.reviewNavigation().loadedDiff().?;
    try std.testing.expectEqual(@as(usize, 2), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(?usize, 0), loaded.visibleNodeAt(0));
    try std.testing.expectEqual(@as(?usize, 4), loaded.visibleNodeAt(1));
}

test "marking a visible file as reviewed while hidden moves selection" {
    var reviewed = [_]bool{ false, false };
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), .{
                .text = "",
                .document = .{ .files = &app_test_support.files_two },
                .file_text_eligibility = &.{ .selectable_utf8, .selectable_utf8 },
                .tree = .{ .nodes = &app_test_support.tree_nested_nodes },
                .reviewed_files = &reviewed,
                .collapsed_dirs = .{},
                .bytes = 0,
                .lines = 0,
            }),
            .viewer = .{
                .selected_node = 1,
                .selected_file = 0,
            },
            .review_display = .{ .hide_reviewed_files = true },
        } },
    };
    defer app.clearLoadedDiff();
    defer app.pages.review.reviewed_store.deinit(std.testing.allocator);
    try app.reviewNavigation().loadedDiff().?.rebuildVisibleNodes(app.reviewNavigation().loadArenaAllocator().?, true, .all);

    try app.reviewNavigation().toggleReviewedFile(std.testing.allocator);

    const loaded = app.reviewNavigation().loadedDiff().?;
    try std.testing.expectEqualSlices(bool, &.{ true, false }, &reviewed);
    try std.testing.expectEqual(@as(usize, 2), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(?usize, 0), loaded.visibleNodeAt(0));
    try std.testing.expectEqual(@as(?usize, 2), loaded.visibleNodeAt(1));
    try std.testing.expectEqual(@as(usize, 2), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_file);
}

test "canceling edited search restores committed query and match" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .search = .{
                .match = .{ .coordinate = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 3 } } },
                .match_offset = 4,
            },
        } },
        .terminal_size = .{ .width = 90, .height = 11 },
    };
    setDiffSearchQuery(&app, "new");

    app.reviewNavigation().enterSearchMode();
    app.pages.review.search.input.backspace();
    try app.pages.review.search.input.insert('x');
    app.reviewNavigation().cancelSearchMode();

    try std.testing.expectEqualStrings("new", app.pages.review.search.query.slice());
    try std.testing.expectEqualStrings("new", app.pages.review.search.input.slice());
    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 0, .line_index = 3 } });
    try std.testing.expectEqual(@as(?usize, 4), app.pages.review.search.match_offset);
}

test "reviewed state is scoped by explicit repository identity" {
    const allocator = std.testing.allocator;
    var app: TestHarness = .{ .repo_root = "/work/one" };
    defer app.pages.review.reviewed_store.deinit(allocator);

    try app.pages.review.reviewed_store.set(
        allocator,
        app.repo_root,
        app_test_support.files_two[0],
        true,
    );

    var loaded_one = app_test_support.loadedDiffTwo();
    try app.reviewNavigation().materializeReviewedFiles(allocator, &loaded_one);
    defer allocator.free(loaded_one.reviewed_files);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, loaded_one.reviewed_files);

    app.repo_root = "/work/two";
    var loaded_two = app_test_support.loadedDiffTwo();
    try app.reviewNavigation().materializeReviewedFiles(allocator, &loaded_two);
    defer allocator.free(loaded_two.reviewed_files);
    try std.testing.expectEqualSlices(bool, &.{ false, false }, loaded_two.reviewed_files);
}

test "side-by-side context horizontal clamp checks both columns" {
    const line = diff_parser.DiffLine{
        .kind = .context,
        .text = "0123456789012345678901234567890123456789",
        .old_line = 1,
        .new_line = 1,
    };

    try std.testing.expectEqual(
        @as(usize, 8),
        maxHorizontalScrollForBodyRow(.{ .side_by_side = .{ .single = line } }, 80, true),
    );
    try std.testing.expect(
        maxHorizontalScrollForBodyRow(.{ .side_by_side = .{ .single = line } }, 80, false) <
            maxHorizontalScrollForBodyRow(.{ .side_by_side = .{ .single = line } }, 80, true),
    );
}
