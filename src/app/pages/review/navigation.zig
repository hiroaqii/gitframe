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
const projection_component = @import("../../projection_component.zig");
const page_link = @import("../../page_link.zig");
const app_state = @import("../../state.zig");
const shell_layout = if (builtin.is_test) @import("../../shell_layout.zig") else struct {};
const review_layout = @import("layout.zig");
const review_message = @import("message.zig");
const review_projection = @import("../../review_projection.zig");
const app_review_projection = review_projection;
const review_page = @import("../review.zig");
const file_search = @import("file_search.zig");
const context = @import("../../../context.zig");
const diff_file = @import("../../../diff/file.zig");
const diff_hunk_projection = @import("../../../diff/hunk_projection.zig");
const diff_parser = @import("../../../diff/parser.zig");
const diff_presentation_identity = @import("../../../diff/presentation_identity.zig");
const diff_render = @import("../../../diff/render.zig");
const diff_search = @import("../../../diff/search.zig");
const diff_selection = @import("../../../diff/selection.zig");
const diff_source = @import("../../../diff/source.zig");
const diff_syntax_view = @import("../../../diff/syntax_view.zig");
const diff_view_model = @import("../../../diff/view_model.zig");
const file_tree = @import("../../../file_tree.zig");
const git_status = @import("../../../git/status.zig");
const loaded_diff = @import("../../../loaded_diff.zig");
const root_capability = @import("../../../repo/root_capability.zig");
const sidebar_view_model = @import("../../../sidebar/view_model.zig");
const text_projection = @import("../../../text/projection.zig");
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
    mode: diff_selection.Mode,
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
        file: diff_parser.FileDiff,
        line_index: ?diff_view_model.RenderedLineIndex,
        folded_hunks: []const bool,
        hunk_stages: diff_render.HunkStagePresentation,
        syntax: diff_syntax_view.View,
    },
    combined_projection: struct {
        file: diff_parser.FileDiff,
        line_index: diff_view_model.RenderedLineIndex,
        hunk_stages: diff_render.HunkStagePresentation,
        syntax: diff_syntax_view.View,
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

    pub fn hunkStagePresentation(self: ActiveDiffDisplay) diff_render.HunkStagePresentation {
        return switch (self) {
            .loaded => |loaded| loaded.hunk_stages,
            .combined_projection => |projection| projection.hunk_stages,
        };
    }

    pub fn syntaxView(self: ActiveDiffDisplay) diff_syntax_view.View {
        return switch (self) {
            .loaded => |loaded| loaded.syntax,
            .combined_projection => |projection| projection.syntax,
        };
    }
};

/// Converts projection-owned index membership into the renderer's explicit
/// per-hunk contract. Both normal and status-only Review routes use this one
/// conversion so they cannot disagree about a combined hunk's stage state.
pub fn projectedHunkStagePresentation(
    allocator: std.mem.Allocator,
    states: []const diff_hunk_projection.HunkStageState,
) !diff_render.HunkStagePresentation {
    if (states.len == 0) return .{ .per_hunk = &.{} };
    const presentation = try allocator.alloc(diff_render.HunkStageState, states.len);
    for (states, presentation) |state, *item| {
        item.* = if (state == .staged) .staged else .unstaged;
    }
    return .{ .per_hunk = presentation };
}

pub const invalid_utf8_body_message = "Text preview unavailable: diff content is not valid UTF-8";

pub const HunkInteractionAvailability = enum {
    available,
    unavailable,
    inert_invalid_utf8,
};

/// Single authority facade for the body currently promised by Review.
///
/// In particular, an accepted inert projection is still a displayed body; it
/// must never collapse to `none` and accidentally reveal the primary diff
/// underneath it.
pub const DisplayedReviewBody = union(enum) {
    none,
    primary: struct {
        loaded: *const LoadedDiff,
        file_index: usize,
    },
    cached: *const app_load.LoadedDiffBundle,
    combined: *const review_projection.CombinedHunkBundle,
    generated: *const review_projection.GeneratedFileBundle,
    inert_invalid_utf8: struct {
        path_key: []const u8,
        display_path: []const u8,
    },
    status: struct {
        path: []const u8,
        message: []const u8,
    },
    pending,
};

pub const NormalLoadedDiffSelectionTarget = struct {
    file_index: usize,
    file: diff_parser.FileDiff,
    line_index: diff_view_model.RenderedLineIndex,
    folded_hunks: []const bool,
    identity: diff_selection.Identity,
};

pub const ParsedSelectionTarget = struct {
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

    pub fn displayedReviewBody(self: View) DisplayedReviewBody {
        switch (self.page.review_projection.displayed) {
            .ready => |*ready| {
                if (self.displayedProjectionRequestIsActive(ready.request)) {
                    return switch (ready.value) {
                        .cached_diff => |*bundle| blk: {
                            if (bundle.loaded.document.files.len == 0) break :blk .none;
                            const file = bundle.loaded.document.files[0];
                            if (!bundle.loaded.fileTextSelectable(0)) break :blk .{ .inert_invalid_utf8 = .{
                                .path_key = ready.request.path_key,
                                .display_path = diff_file.displayPath(file),
                            } };
                            break :blk .{ .cached = bundle };
                        },
                        .generated_added_file => |*bundle| .{ .generated = bundle },
                        .combined_hunks => |*bundle| .{ .combined = bundle },
                        .inert_combined => .{ .inert_invalid_utf8 = .{
                            .path_key = ready.request.path_key,
                            .display_path = ready.request.path_key,
                        } },
                        .status_body => |*body| .{ .status = .{ .path = body.path, .message = body.message } },
                    };
                }
            },
            .failed => |*failed| {
                if (self.displayedProjectionRequestIsActive(failed.request)) {
                    return .{ .status = .{ .path = failed.body.path, .message = failed.body.message } };
                }
            },
            .idle => {},
        }

        if (self.selectedStatusEntry() != null) return if (self.page.review_projection.hasPending()) .pending else .none;

        const loaded = self.activeLoadedDiffConst() orelse return .none;
        const file_index = self.selectedFileIndex(loaded) orelse return .none;
        if (file_index >= loaded.document.files.len) return .none;
        if (!loaded.fileTextSelectable(file_index)) {
            const file = loaded.document.files[file_index];
            const path_key = diff_file.canonicalPathKey(file) orelse diff_file.displayPath(file);
            return .{ .inert_invalid_utf8 = .{ .path_key = path_key, .display_path = diff_file.displayPath(file) } };
        }
        return .{ .primary = .{ .loaded = loaded, .file_index = file_index } };
    }

    pub fn diffSelectionView(self: View) ?diff_selection.View {
        const selection = self.page.selection_owner.activeDiff() orelse return null;
        switch (selection.identity) {
            .generated_file => |generated| {
                const bundle = self.activeGeneratedFileProjection() orelse return null;
                if (!std.mem.eql(u8, generated.path_key, bundle.path)) return null;
            },
            .loaded_file, .projection_file => _ = self.parsedSelectionTarget(selection.identity) orelse return null,
        }
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
        const primary = switch (self.displayedReviewBody()) {
            .primary => |primary| primary,
            else => return null,
        };
        const loaded = primary.loaded;
        const file_index = primary.file_index;
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

    pub fn parsedSelectionTarget(self: View, expected: ?diff_selection.Identity) ?ParsedSelectionTarget {
        const target: ParsedSelectionTarget = switch (self.displayedReviewBody()) {
            .primary => |primary| blk: {
                const file = primary.loaded.document.files[primary.file_index];
                const path_key = diff_file.canonicalPathKey(file) orelse return null;
                const mode = self.effectiveDisplayMode();
                break :blk .{
                    .file = file,
                    .line_index = primary.loaded.cachedRenderedLineIndex(primary.file_index, mode) orelse primary.loaded.renderedLineIndex(primary.file_index, mode),
                    .folded_hunks = primary.loaded.foldedHunksForFile(primary.file_index),
                    .identity = .{ .loaded_file = .{ .file_index = primary.file_index, .path_key = path_key } },
                };
            },
            .cached => |bundle| blk: {
                const file = bundle.loaded.document.files[0];
                const path_key = diff_file.canonicalPathKey(file) orelse return null;
                const mode = self.effectiveDisplayMode();
                break :blk .{
                    .file = file,
                    .line_index = bundle.loaded.cachedRenderedLineIndex(0, mode) orelse bundle.loaded.renderedLineIndex(0, mode),
                    .folded_hunks = &.{},
                    .identity = .{ .projection_file = .{ .kind = .cached, .path_key = path_key } },
                };
            },
            .combined => |bundle| blk: {
                const path_key = diff_file.canonicalPathKey(bundle.displayFile()) orelse return null;
                break :blk .{
                    .file = bundle.displayFile(),
                    .line_index = bundle.displayLineIndex(self.effectiveDisplayMode()),
                    .folded_hunks = &.{},
                    .identity = .{ .projection_file = .{ .kind = .combined, .path_key = path_key } },
                };
            },
            .none, .generated, .inert_invalid_utf8, .status, .pending => return null,
        };
        if (expected) |identity| if (!identity.eql(target.identity)) return null;
        return target;
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
                const path_key = diff_file.canonicalPathKey(bundle.displayFile()) orelse return null;
                break :blk .{
                    .identity = .{ .kind = .projection_file, .path_key = path_key },
                    .display_path = diff_file.displayPath(bundle.displayFile()),
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
        return self.diffMouseHitLocked(point, null);
    }

    pub fn diffMouseDragHit(self: View, point: MousePoint, selection: diff_selection.DragSelection) ?DiffMouseHit {
        return self.diffMouseHitLocked(point, selection);
    }

    fn diffMouseHitLocked(self: View, point: MousePoint, locked: ?diff_selection.DragSelection) ?DiffMouseHit {
        const raw_diff = self.rawDiffPaneGeometry() orelse return null;
        if (point.col < raw_diff.col or point.col >= raw_diff.col + raw_diff.width) return null;
        if (point.row < diff_render.body_start_row) return null;

        const local_col = point.col - raw_diff.col;
        const content_width = contentWidth(raw_diff.width);
        const content_gutter = raw_diff.width - content_width;
        if (local_col < content_gutter) return null;
        const render_col = local_col - content_gutter;
        if (render_col >= content_width or render_col < diff_render.cursor_gutter_width) return null;

        const body_col = render_col - diff_render.cursor_gutter_width;
        const visible_body_row: usize = point.row - diff_render.body_start_row;
        if (visible_body_row >= self.diffVisibleRows()) return null;
        const offset = self.page.viewer.diff_scroll + visible_body_row;
        const body_width = diff_render.bodyWidth(content_width);
        const display_mode = diff_render.effectiveMode(body_width, self.page.viewer.display_mode);

        if (self.parsedSelectionTarget(if (locked) |selection| selection.identity else null)) |target| {
            const hit = parsedMouseLine(target, body_col, body_width, display_mode, offset, self.page.viewer.view_options.line_numbers, locked) orelse return null;
            const model_mode = if (locked) |selection| selection.mode else hit.region.mode;
            const point_value = if (hit.region.leading_boundary)
                diff_selection.pointFromBoundary(hit.hunk_index, hit.line_index, 0)
            else
                pointForTextCell(hit.hunk_index, hit.line_index, hit.line.text, model_mode, hit.region.text_cell +| self.page.viewer.diff_horizontal_scroll) orelse return null;
            return .{
                .identity = target.identity,
                .side = hit.region.side,
                .mode = model_mode,
                .point = point_value,
            };
        }

        const generated = self.activeGeneratedFileProjection() orelse return null;
        const line = generated.source.lineBody(offset) orelse return null;
        const region = selectionRegionForGenerated(body_col, body_width, display_mode, self.page.viewer.view_options.line_numbers, locked) orelse return null;
        const model_mode = if (locked) |selection| selection.mode else region.mode;
        return .{
            .identity = .{ .generated_file = .{ .path_key = generated.path } },
            .side = .new,
            .mode = model_mode,
            .point = if (region.leading_boundary)
                diff_selection.pointFromBoundary(0, offset, 0)
            else
                pointForTextCell(0, offset, line, model_mode, region.text_cell +| self.page.viewer.diff_horizontal_scroll) orelse return null,
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
            .root_disclosure = loaded.root_disclosure,
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
        if (self.displayedReviewBody() == .inert_invalid_utf8) return 0;
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
                    if (!bundle.loaded.fileTextSelectable(0))
                        1
                    else if (bundle.loaded.cachedRenderedLineIndex(0, self.effectiveDisplayMode())) |index|
                        index.lineCount()
                    else
                        0
                else
                    0,
                .generated_added_file => |bundle| bundle.source.rowCount(),
                .combined_hunks => |bundle| bundle.displayLineIndex(self.effectiveDisplayMode()).lineCount(),
                .inert_combined => 1,
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
        if (self.displayedReviewBody() == .inert_invalid_utf8) {
            return "search is unavailable because diff content is not valid UTF-8";
        }
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

    /// Stable identity of the sidebar cursor, independent from the sticky
    /// file/status target displayed in the main pane.
    pub fn selectedSidebarIdentity(self: View) ?context.SidebarIdentity {
        const loaded = self.activeLoadedDiffConst() orelse return null;
        if (self.page.viewer.selected_node >= loaded.tree.nodes.len) return null;
        const node = loaded.tree.nodes[self.page.viewer.selected_node];
        return switch (node.kind) {
            .repo_root => .repo_root,
            .directory => .{ .directory = node.path },
            .file => .{ .file = if (node.path_key.len > 0) node.path_key else node.path },
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
            .hunk_index = if (self.rawSelectedHunkIndex()) |hunk_index|
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
        return switch (self.displayedReviewBody()) {
            .primary => |primary| primary.loaded.document.files[primary.file_index],
            .cached => |bundle| bundle.loaded.document.files[0],
            .combined => |bundle| bundle.displayFile(),
            .none, .generated, .inert_invalid_utf8, .status, .pending => null,
        };
    }

    pub fn displayedSearchTarget(self: View, mode: diff_render.DisplayMode) ?SearchTarget {
        return switch (self.displayedReviewBody()) {
            .cached => |bundle| .{
                .file = bundle.loaded.document.files[0],
                .line_index = bundle.loaded.cachedRenderedLineIndex(0, mode) orelse bundle.loaded.renderedLineIndex(0, mode),
                .folded_hunks = &.{},
            },
            .primary => |primary| .{
                .file = primary.loaded.document.files[primary.file_index],
                .line_index = primary.loaded.renderedLineIndex(primary.file_index, mode),
                .folded_hunks = primary.loaded.foldedHunksForFile(primary.file_index),
            },
            .none, .combined, .generated, .inert_invalid_utf8, .status, .pending => null,
        };
    }

    pub fn displayedGeneratedLineCount(self: View) ?usize {
        const bundle = self.activeGeneratedFileProjection() orelse return null;
        return bundle.source.rowCount();
    }

    pub fn displayedDiffLineIndex(self: View, mode: diff_render.DisplayMode) ?diff_view_model.RenderedLineIndex {
        if (self.activeCombinedProjection()) |bundle| return bundle.displayLineIndex(mode);
        if (self.activeCachedDiffProjection()) |bundle| {
            if (bundle.loaded.document.files.len == 0) return null;
            return bundle.loaded.cachedRenderedLineIndex(0, mode);
        }
        return null;
    }

    pub fn activeDiffDisplay(self: View, allocator: std.mem.Allocator, mode: diff_render.DisplayMode) !?ActiveDiffDisplay {
        const selected: struct { loaded: *const LoadedDiff, file_index: usize } = switch (self.displayedReviewBody()) {
            .combined => |bundle| {
                return .{ .combined_projection = .{
                    .file = bundle.displayFile(),
                    .line_index = bundle.displayLineIndex(mode),
                    .hunk_stages = try projectedHunkStagePresentation(allocator, bundle.hunkStageStates()),
                    .syntax = bundle.syntaxView(),
                } };
            },
            .cached => |bundle| {
                const loaded = &bundle.loaded;
                if (loaded.document.files.len == 0) return null;
                return .{ .loaded = .{
                    .file = loaded.document.files[0],
                    .line_index = loaded.cachedRenderedLineIndex(0, mode),
                    .folded_hunks = loaded.foldedHunksForFile(0),
                    .hunk_stages = .all_staged,
                    .syntax = .initDirect(&loaded.syntax_spans, 0),
                } };
            },
            .primary => |primary| .{ .loaded = primary.loaded, .file_index = primary.file_index },
            .none, .generated, .inert_invalid_utf8, .status, .pending => return null,
        };
        const loaded = selected.loaded;
        const file_index = selected.file_index;
        const file = loaded.document.files[file_index];
        return .{ .loaded = .{
            .file = file,
            .line_index = loaded.cachedRenderedLineIndex(file_index, mode),
            .folded_hunks = loaded.foldedHunksForFile(file_index),
            .hunk_stages = try self.hunkStagePresentationForFile(allocator, file),
            .syntax = .initDirect(&loaded.syntax_spans, file_index),
        } };
    }

    pub fn activeGeneratedFileProjection(self: View) ?*const review_projection.GeneratedFileBundle {
        return switch (self.displayedReviewBody()) {
            .generated => |bundle| bundle,
            else => null,
        };
    }

    pub fn activeCachedDiffProjection(self: View) ?*const app_load.LoadedDiffBundle {
        return switch (self.displayedReviewBody()) {
            .cached => |bundle| bundle,
            else => null,
        };
    }

    pub fn activeCombinedProjection(self: View) ?*const review_projection.CombinedHunkBundle {
        return switch (self.displayedReviewBody()) {
            .combined => |bundle| bundle,
            else => null,
        };
    }

    pub fn bodyAllowsHunkInteraction(self: View) bool {
        return self.hunkInteractionAvailability() == .available;
    }

    pub fn hunkInteractionAvailability(self: View) HunkInteractionAvailability {
        return switch (self.displayedReviewBody()) {
            .primary, .cached, .combined => .available,
            .inert_invalid_utf8 => .inert_invalid_utf8,
            .none, .generated, .status, .pending => .unavailable,
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
        if (self.displayedReviewBody() == .inert_invalid_utf8) return .{ .mode = mode };
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
        if (!self.bodyAllowsHunkInteraction()) return 0;
        if (self.activeCombinedProjection()) |bundle| return bundle.displayLineIndex(mode).hunkOffset(hunk_index);
        const loaded = self.activeLoadedDiffConst() orelse return 0;
        const file_index = self.selectedFileIndex(loaded) orelse return 0;
        if (loaded.rendered_line_cache.indexFor(file_index, mode)) |index| return index.hunkOffset(hunk_index);
        return diff_view_model.hunkBodyLineOffsetFolded(loaded.document.files[file_index], mode, hunk_index, loaded.foldedHunksForFile(file_index));
    }

    pub fn selectedHunkIndex(self: View) ?usize {
        if (!self.bodyAllowsHunkInteraction()) return null;
        return self.rawSelectedHunkIndex();
    }

    fn rawSelectedHunkIndex(self: View) ?usize {
        return switch (self.page.viewer.diff_cursor) {
            .hunk_header => |hunk_index| hunk_index,
            .hunk_line => |line| line.hunk_index,
            .metadata, .binary_marker => null,
        };
    }

    pub fn hunkStagePresentationForFile(self: View, allocator: std.mem.Allocator, file: diff_parser.FileDiff) !diff_render.HunkStagePresentation {
        switch (self.source) {
            .cached => return .all_staged,
            .unstaged => {},
            .stdin, .pager, .patch_file, .range, .no_index => return .all_unstaged,
        }
        if (file.hunks.len == 0) return .all_unstaged;
        const repo_root = self.repo_root orelse return .all_unstaged;
        const path = diff_file.canonicalPathKey(file) orelse return .all_unstaged;
        if (self.isFreshStagedOnlyPath(repo_root, path)) return .all_staged;
        if (self.page.staged_hunks.items.items.len == 0) return .all_unstaged;

        var marked_count: usize = 0;
        for (0..file.hunks.len) |hunk_index| {
            if (self.page.staged_hunks.contains(repo_root, path, hunk_index)) marked_count += 1;
        }

        if (marked_count == 0) return .all_unstaged;

        const states = try allocator.alloc(diff_render.HunkStageState, file.hunks.len);
        for (states, 0..) |*state, hunk_index| {
            state.* = if (self.page.staged_hunks.contains(repo_root, path, hunk_index)) .staged else .unstaged;
        }
        return .{ .per_hunk = states };
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
    repo_epoch: u64 = 0,
    root_identity: ?root_capability.Identity = null,
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

    fn rebuildVisibleNodes(self: Controller, loaded: *LoadedDiff, allocator: std.mem.Allocator) !void {
        try loaded.rebuildVisibleNodes(
            allocator,
            self.page.viewer.root_disclosure,
            self.page.review_display.hide_reviewed_files,
            self.page.review_display.changed_file_filter,
        );
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
        self.page.selection_owner = .{ .diff = diff_selection.DragSelection.initAtCell(
            hit.identity,
            hit.side,
            hit.mode,
            hit.point,
            .{ .col = point.col, .row = point.row },
        ) };
    }

    pub fn dragDiffMouse(self: Controller, point_opt: ?MousePoint) void {
        const point = point_opt orelse return;
        switch (self.page.selection_owner) {
            .none => return,
            .diff_header => |*selection| selection.update(),
            .diff => |*selection| {
                const hit = self.view().diffMouseDragHit(point, selection.*) orelse return;
                if (!selection.identity.eql(hit.identity)) return;
                selection.updateAtCell(hit.point, .{ .col = point.col, .row = point.row });
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
        if (node.kind != .repo_root and node.kind != .directory) return;
        const allocator = self.loadArenaAllocator() orelse return;
        var prepared = try loaded.prepareVisibleNodeRebuild(allocator);
        switch (node.kind) {
            .repo_root => self.page.viewer.root_disclosure = self.page.viewer.root_disclosure.toggled(),
            .directory => try file_tree.toggle(allocator, &loaded.collapsed_dirs, node.path),
            .file => unreachable,
        }
        prepared.commit(
            self.page.viewer.root_disclosure,
            self.page.review_display.hide_reviewed_files,
            self.page.review_display.changed_file_filter,
        );
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
        if (node.kind == .repo_root or node.kind == .directory) try self.toggleSelectedDirectory();

        self.clampSelection(loaded.document.files.len);
        self.clampDiffNavigation();
    }

    pub fn expandSelectedDirectory(self: Controller) !void {
        const loaded = self.activeLoadedDiff() orelse return;
        if (self.page.viewer.selected_node >= loaded.tree.nodes.len) return;
        const node = loaded.tree.nodes[self.page.viewer.selected_node];
        switch (node.kind) {
            .repo_root => if (self.page.viewer.root_disclosure == .expanded) return,
            .directory => if (!file_tree.isCollapsed(&loaded.collapsed_dirs, node.path)) return,
            .file => return,
        }
        const allocator = self.loadArenaAllocator() orelse return;
        var prepared = try loaded.prepareVisibleNodeRebuild(allocator);
        switch (node.kind) {
            .repo_root => self.page.viewer.root_disclosure = .expanded,
            .directory => file_tree.expand(&loaded.collapsed_dirs, node.path),
            .file => unreachable,
        }
        prepared.commit(
            self.page.viewer.root_disclosure,
            self.page.review_display.hide_reviewed_files,
            self.page.review_display.changed_file_filter,
        );
        self.clampSelection(loaded.document.files.len);
        self.clampSidebarHorizontalScroll();
    }

    pub fn collapseOrSelectParentDirectory(self: Controller) !void {
        const loaded = self.activeLoadedDiff() orelse return;
        if (self.page.viewer.selected_node >= loaded.tree.nodes.len) return;
        const node = loaded.tree.nodes[self.page.viewer.selected_node];
        const expanded_target = switch (node.kind) {
            .repo_root => self.page.viewer.root_disclosure == .expanded,
            .directory => !file_tree.isCollapsed(&loaded.collapsed_dirs, node.path),
            .file => false,
        };
        if (expanded_target) {
            const allocator = self.loadArenaAllocator() orelse return;
            var prepared = try loaded.prepareVisibleNodeRebuild(allocator);
            switch (node.kind) {
                .repo_root => self.page.viewer.root_disclosure = .collapsed,
                .directory => try file_tree.collapse(allocator, &loaded.collapsed_dirs, node.path),
                .file => unreachable,
            }
            prepared.commit(
                self.page.viewer.root_disclosure,
                self.page.review_display.hide_reviewed_files,
                self.page.review_display.changed_file_filter,
            );
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
            .right => self.page.viewer.diff_horizontal_scroll += step,
        }
        self.clampDiffHorizontalScrollToVisibleRows();
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
        if (!self.view().bodyAllowsHunkInteraction()) return;
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
        if (!self.view().bodyAllowsHunkInteraction()) return;
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
        if (self.view().displayedReviewBody() == .inert_invalid_utf8) {
            self.page.viewer.diff_cursor = .{ .metadata = 0 };
            self.page.viewer.diff_scroll = 0;
            self.page.viewer.diff_horizontal_scroll = 0;
            return;
        }
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
        self.page.viewer.root_disclosure = .expanded;
        self.clearSearch();
    }

    pub fn enterFileSearchMode(self: Controller, allocator: std.mem.Allocator) void {
        self.clearDiffSelection();
        self.page.file_search_return_focus = if (self.page.viewer.sidebar_hidden) .diff else self.page.viewer.focus;
        if (!self.page.viewer.sidebar_hidden) self.page.viewer.focus = .sidebar;
        self.page.file_search.mode = true;
        self.page.file_search.input = .{};
        self.page.file_search.resetNoMatch();
        // Empty input is an authoritative all-eligible-files projection, not
        // a sentinel state. This also establishes the unavailable terminal
        // immediately when no accepted sidebar can supply candidates.
        self.rebuildFileSearchProjection(allocator);
    }

    pub fn cancelFileSearchMode(self: Controller, allocator: std.mem.Allocator) void {
        self.page.file_search.deinit(allocator);
        self.page.viewer.focus = if (self.page.viewer.sidebar_hidden) .diff else self.page.file_search_return_focus;
    }

    /// Rebuild the candidate projection from the current accepted sidebar
    /// without making a model replacement depend on search allocation. A
    /// failed rebuild keeps the prompt/input alive but publishes no candidate,
    /// so render and submit cannot observe a stale path borrow.
    pub fn rebuildFileSearchProjection(self: Controller, allocator: std.mem.Allocator) void {
        if (!self.page.file_search.mode) {
            self.page.file_search.markProjectionUnavailable(allocator);
            return;
        }
        const loaded = self.activeLoadedDiff() orelse {
            self.page.file_search.markProjectionUnavailable(allocator);
            return;
        };
        const basis = self.currentFileSearchBasis() orelse {
            self.page.file_search.markProjectionUnavailable(allocator);
            return;
        };
        const query = std.mem.trim(u8, self.page.file_search.input.slice(), " \t\r\n");
        var projection = file_search.buildProjection(allocator, loaded, query, .{
            .basis = basis,
            .hide_reviewed_files = self.page.review_display.hide_reviewed_files,
            .changed_file_filter = self.page.review_display.changed_file_filter,
        }) catch {
            self.page.file_search.markProjectionUnavailable(allocator);
            return;
        };
        self.page.file_search.publish(allocator, &projection);
    }

    fn currentFileSearchBasis(self: Controller) ?file_search.Basis {
        _ = self.view().activeLoadedDiffConst() orelse return null;
        const basis: file_search.Basis = .{
            .repo_epoch = self.repo_epoch,
            .source_session_revision = self.page.source_session_revision,
            .accepted_sidebar_revision = self.page.accepted_sidebar_revision,
        };
        return if (basis.valid()) basis else null;
    }

    pub fn toggleReviewedFile(self: Controller, allocator: std.mem.Allocator) !void {
        const loaded = self.activeLoadedDiff() orelse return;
        if (self.page.viewer.selected_node >= loaded.tree.nodes.len) return;

        const file_index = self.view().selectedFileIndex(loaded) orelse return;
        if (file_index >= loaded.reviewed_files.len) return;
        const file = loaded.document.files[file_index];
        if (self.repo_root != null and diff_file.canonicalPathKey(file) == null) return;

        const reviewed = !loaded.reviewed_files[file_index];
        if (self.page.review_display.hide_reviewed_files) {
            // Prepare the primary visible-tree replacement before changing
            // reviewed authority. Once that primary operation can commit, the
            // old search projection must be revoked before eligibility changes.
            var prepared = try loaded.prepareVisibleNodeRebuild(self.loadArenaAllocator() orelse unreachable);
            try self.page.reviewed_store.set(allocator, self.repo_root, file, reviewed);
            self.page.advanceAcceptedSidebarRevision(allocator);
            loaded.reviewed_files[file_index] = reviewed;
            prepared.commit(
                self.page.viewer.root_disclosure,
                self.page.review_display.hide_reviewed_files,
                self.page.review_display.changed_file_filter,
            );
            self.reconcileSelectionAfterVisibleNodeChange(loaded);
            self.clampSidebarHorizontalScroll();
            self.clampDiffNavigation();
            self.rebuildFileSearchProjection(allocator);
            return;
        }

        try self.page.reviewed_store.set(allocator, self.repo_root, file, reviewed);
        loaded.reviewed_files[file_index] = reviewed;
    }

    pub fn toggleHideReviewedFiles(self: Controller, allocator: std.mem.Allocator) !void {
        try self.replaceFileVisibilityLens(
            allocator,
            self.loadArenaAllocator() orelse allocator,
            !self.page.review_display.hide_reviewed_files,
            self.page.review_display.changed_file_filter,
        );
    }

    pub fn cycleChangedFileFilter(self: Controller, allocator: std.mem.Allocator) !void {
        try self.replaceFileVisibilityLens(
            allocator,
            self.loadArenaAllocator() orelse allocator,
            self.page.review_display.hide_reviewed_files,
            self.page.review_display.changed_file_filter.next(),
        );
    }

    /// Replace the accepted Review file-visibility lens transactionally.
    /// Search allocation is deliberately after the primary commit: failure
    /// may make the prompt unavailable, but cannot reject a valid lens change.
    fn replaceFileVisibilityLens(
        self: Controller,
        allocator: std.mem.Allocator,
        visible_allocator: std.mem.Allocator,
        hide_reviewed_files: bool,
        changed_file_filter: ChangedFileFilter,
    ) !void {
        if (self.activeLoadedDiff()) |loaded| {
            var prepared = try loaded.prepareVisibleNodeRebuild(visible_allocator);
            self.page.advanceAcceptedSidebarRevision(allocator);
            self.page.review_display.hide_reviewed_files = hide_reviewed_files;
            self.page.review_display.changed_file_filter = changed_file_filter;
            prepared.commit(
                self.page.viewer.root_disclosure,
                hide_reviewed_files,
                changed_file_filter,
            );
            self.reconcileSelectionAfterVisibleNodeChange(loaded);
            self.clampSidebarHorizontalScroll();
            self.clampDiffNavigation();
        } else {
            // Lens state is retained across unloaded states. Revoke any
            // projection defensively and give the next accepted sidebar a new
            // namespace even though there is no visible tree to rebuild now.
            self.page.advanceAcceptedSidebarRevision(allocator);
            self.page.review_display.hide_reviewed_files = hide_reviewed_files;
            self.page.review_display.changed_file_filter = changed_file_filter;
        }
        self.rebuildFileSearchProjection(allocator);
    }

    pub fn submitFileSearch(self: Controller, allocator: std.mem.Allocator) void {
        self.submitFileSearchWithVisibleAllocator(allocator, null);
    }

    fn submitFileSearchWithVisibleAllocator(
        self: Controller,
        allocator: std.mem.Allocator,
        visible_allocator_override: ?std.mem.Allocator,
    ) void {
        if (!self.page.file_search.projection_available) return;
        const candidate = self.page.file_search.focusedCandidate() orelse {
            if (self.page.file_search.filter.labels.len == 0) {
                self.page.file_search.no_match = true;
            } else {
                self.page.file_search.markProjectionUnavailable(allocator);
            }
            return;
        };
        const loaded = self.activeLoadedDiff() orelse {
            self.page.file_search.markProjectionUnavailable(allocator);
            return;
        };
        const basis = self.currentFileSearchBasis() orelse {
            self.page.file_search.markProjectionUnavailable(allocator);
            return;
        };
        const node_index = candidate.node_index;
        if (node_index >= loaded.tree.nodes.len or
            !candidate.matchesNode(basis, node_index, loaded.tree.nodes[node_index]) or
            !loaded.shouldIncludeFileNode(
                node_index,
                self.page.review_display.hide_reviewed_files,
                self.page.review_display.changed_file_filter,
            ))
        {
            self.page.file_search.markProjectionUnavailable(allocator);
            return;
        }

        self.revealAndSelectExactNode(
            loaded,
            node_index,
            visible_allocator_override orelse self.loadArenaAllocator(),
        ) catch {
            self.setStatus("Could not reveal file search result", .{});
            return;
        };
        self.page.file_search.deinit(allocator);
        self.page.viewer.focus = .diff;
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

    pub fn prepareActionCursor(
        self: Controller,
        allocator: std.mem.Allocator,
        repo_epoch: u64,
        root_identity: root_capability.Identity,
        kind: review_page.action_cursor.TargetKind,
        path_key: []const u8,
    ) !review_page.action_cursor.Prepared {
        const visible_row = if (self.view().activeLoadedDiffConst()) |loaded|
            loaded.visibleRowOfNode(self.page.viewer.selected_node) orelse 0
        else
            0;
        return review_page.action_cursor.Prepared.init(
            allocator,
            repo_epoch,
            root_identity,
            kind,
            path_key,
            visible_row,
        );
    }

    pub fn installActionCursor(
        self: Controller,
        allocator: std.mem.Allocator,
        prepared: *review_page.action_cursor.Prepared,
        action_generation: u64,
    ) void {
        self.page.action_cursor.install(allocator, prepared, action_generation);
    }

    pub fn clearActionCursor(self: Controller, allocator: std.mem.Allocator) void {
        self.page.action_cursor.clear(allocator);
    }

    /// Rebind the tree cursor after one member replaces the tree, but retain
    /// the action owner until the exact source/status pair is terminal.
    pub fn remapActionCursor(self: Controller, loaded: *LoadedDiff) bool {
        const target = self.page.action_cursor.restoreTarget() orelse return false;
        return self.restoreTypedActionTarget(loaded, target, false);
    }

    /// Consume one terminal action owner and restore its typed target exactly
    /// once against the final coherent projection.
    pub fn finalizeActionCursor(self: Controller, allocator: std.mem.Allocator) bool {
        var owner = self.page.action_cursor.takeTerminal() orelse return false;
        defer owner.deinit(allocator);
        if (!owner.mayRestore()) return true;
        const loaded = self.activeLoadedDiff() orelse return true;
        _ = self.restoreTypedActionTarget(loaded, &owner.target, true);
        self.clampSelection(loaded.document.files.len);
        self.clampDiffNavigation();
        return true;
    }

    fn restoreTypedActionTarget(
        self: Controller,
        loaded: *LoadedDiff,
        target: *const review_page.action_cursor.Target,
        final: bool,
    ) bool {
        if (typedActionNode(loaded, target)) |node_index| {
            if (loaded.visibleRowOfNode(node_index) != null) {
                self.selectSidebarNode(loaded, node_index);
                return true;
            }
            if (final and self.actionTargetIncludedByFilters(loaded, node_index)) {
                if (self.revealActionNode(loaded, node_index)) {
                    self.selectSidebarNode(loaded, node_index);
                    return true;
                }
            }
        }

        if (target.kind == .directory or target.kind == .repository_root) {
            if (deepestVisibleTypedAncestor(loaded, target.path_key)) |node_index| {
                self.selectSidebarNode(loaded, node_index);
                return true;
            }
            return false;
        }

        if (loaded.visibleNodeCount() == 0) {
            self.page.viewer.selected_target = null;
            self.page.viewer.selected_node = 0;
            return true;
        }
        const row = @min(target.visible_row, loaded.visibleNodeCount() - 1);
        if (nearestVisibleFileNode(loaded, row)) |node_index| {
            self.selectSidebarNode(loaded, node_index);
            return true;
        }
        return false;
    }

    fn actionTargetIncludedByFilters(self: Controller, loaded: *const LoadedDiff, node_index: usize) bool {
        if (node_index >= loaded.tree.nodes.len) return false;
        const node = loaded.tree.nodes[node_index];
        return switch (node.kind) {
            .file => loaded.shouldIncludeFileNode(
                node_index,
                self.page.review_display.hide_reviewed_files,
                self.page.review_display.changed_file_filter,
            ),
            .repo_root, .directory => blk: {
                for (loaded.tree.nodes, 0..) |candidate, candidate_index| {
                    if (candidate.kind != .file) continue;
                    if (node.kind == .directory and !file_tree.isPathAncestor(node.path, candidate.path)) continue;
                    if (loaded.shouldIncludeFileNode(
                        candidate_index,
                        self.page.review_display.hide_reviewed_files,
                        self.page.review_display.changed_file_filter,
                    )) break :blk true;
                }
                break :blk false;
            },
        };
    }

    fn revealActionNode(self: Controller, loaded: *LoadedDiff, node_index: usize) bool {
        const allocator = self.loadArenaAllocator() orelse return false;
        var prepared = loaded.prepareVisibleNodeRebuild(allocator) catch return false;
        self.page.viewer.root_disclosure = .expanded;
        file_tree.expandAncestors(&loaded.collapsed_dirs, loaded.tree.nodes[node_index].path);
        prepared.commit(
            self.page.viewer.root_disclosure,
            self.page.review_display.hide_reviewed_files,
            self.page.review_display.changed_file_filter,
        );
        return loaded.visibleRowOfNode(node_index) != null;
    }

    pub fn restoreReloadAnchor(self: Controller, loaded: *LoadedDiff, anchor: *const review_page.ReloadAnchor) bool {
        const selected_same_path = if (findFileNodeByPathKey(loaded, anchor.path_key)) |node_index| blk: {
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

        // Directory/root selection is independent from the sticky diff body.
        // Restore it only after rebinding the body file so selecting a
        // directory cannot accidentally replace the displayed target.
        _ = self.restoreSidebarIdentity(loaded, anchor.sidebar_identity);

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
        // Anchors address the complete tree, while root/directory disclosure
        // controls its materialized rows. Preserve the restored diff target,
        // but never leave the sidebar cursor on a hidden descendant.
        self.reconcileSelectionAfterVisibleNodeChange(loaded);
        return true;
    }

    pub fn restoreSidebarIdentity(
        self: Controller,
        loaded: *LoadedDiff,
        identity: context.SidebarIdentity,
    ) bool {
        const node_index = findNodeBySidebarIdentity(loaded, identity) orelse return false;
        self.selectSidebarNode(loaded, node_index);
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

    pub fn loadedDiff(self: Controller) ?*LoadedDiff {
        return self.activeLoadedDiff();
    }

    pub fn activeLoadedDiff(self: Controller) ?*LoadedDiff {
        return switch (self.page.load.state) {
            .loaded => |*session| &session.loaded,
            else => null,
        };
    }

    pub const ExactPathTarget = union(enum) {
        ready: usize,
        unavailable: page_link.ReviewUnavailableReason,
    };

    pub const ExactPathRevealResult = union(enum) {
        selected: usize,
        unchanged: usize,
        unavailable: page_link.ReviewUnavailableReason,
    };

    /// Classify one Repository path against the accepted retained Review
    /// without changing folds, filters, selection, search, or diff position.
    /// Slice D's mutation half consumes only the `ready` node synchronously;
    /// an unavailable result is never retained for a future reload.
    pub fn exactPathTarget(self: Controller, intent: page_link.ReviewLocationIntent) ExactPathTarget {
        if (!diff_source.sourceAllowsRepositoryLink(self.source)) {
            return .{ .unavailable = .source_unavailable };
        }
        const active_root = self.root_identity orelse return .{ .unavailable = .repository_mismatch };
        if (intent.repo_epoch != self.repo_epoch or !intent.root_identity.eql(active_root)) {
            return .{ .unavailable = .repository_mismatch };
        }
        const loaded = self.activeLoadedDiff() orelse return .{ .unavailable = .no_accepted_review };
        const node_index = findFileNodeByPathKey(loaded, intent.path) orelse
            return .{ .unavailable = .path_not_found };
        if (!loaded.shouldIncludeFileNode(
            node_index,
            self.page.review_display.hide_reviewed_files,
            self.page.review_display.changed_file_filter,
        )) return .{ .unavailable = .hidden_by_filters };
        return .{ .ready = node_index };
    }

    /// Reveal and select one D1-classified exact file without retaining the
    /// borrowed request. Fallible visible-tree preparation completes before
    /// collapsed ancestors or Review navigation state can change.
    pub fn revealExactPath(self: Controller, intent: page_link.ReviewLocationIntent) !ExactPathRevealResult {
        return self.revealExactPathWithAllocator(intent, null);
    }

    fn revealExactPathWithAllocator(
        self: Controller,
        intent: page_link.ReviewLocationIntent,
        allocator_override: ?std.mem.Allocator,
    ) !ExactPathRevealResult {
        const node_index = switch (self.exactPathTarget(intent)) {
            .unavailable => |reason| return .{ .unavailable = reason },
            .ready => |ready| ready,
        };
        const loaded = self.activeLoadedDiff() orelse unreachable;
        const selected_target_matches = if (self.page.viewer.selected_target) |selected| switch (loaded.tree.nodes[node_index].target) {
            .diff_file => |file_index| selected == .diff_file and selected.diff_file == file_index,
            .status_entry => |status_index| selected == .status_only and selected.status_only == status_index,
            .repo_root, .directory => false,
        } else false;
        // Matching selection identity is insufficient when a retained fold
        // currently hides that node from the materialized sidebar.
        if (self.page.viewer.selected_node == node_index and
            selected_target_matches and
            loaded.visibleRowOfNode(node_index) != null)
        {
            return .{ .unchanged = node_index };
        }

        try self.revealAndSelectExactNode(
            loaded,
            node_index,
            allocator_override orelse self.loadArenaAllocator(),
        );
        return .{ .selected = node_index };
    }

    /// Commit one already validated exact file node through the single Review
    /// disclosure and navigation transaction. Candidate/path admission and
    /// caller-specific failure policy deliberately remain outside this helper.
    fn revealAndSelectExactNode(
        self: Controller,
        loaded: *LoadedDiff,
        node_index: usize,
        visible_allocator: ?std.mem.Allocator,
    ) !void {
        std.debug.assert(node_index < loaded.tree.nodes.len);
        std.debug.assert(loaded.tree.nodes[node_index].kind == .file);
        if (loaded.visibleRowOfNode(node_index) == null) {
            const allocator = visible_allocator orelse return error.MissingVisibleNodeAllocator;
            var prepared = try loaded.prepareVisibleNodeRebuild(allocator);
            self.page.viewer.root_disclosure = .expanded;
            file_tree.expandAncestors(&loaded.collapsed_dirs, loaded.tree.nodes[node_index].path);
            prepared.commit(
                self.page.viewer.root_disclosure,
                self.page.review_display.hide_reviewed_files,
                self.page.review_display.changed_file_filter,
            );
        }

        self.selectSidebarNode(loaded, node_index);
        self.clampSelection(loaded.document.files.len);
        self.clampDiffNavigation();
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

pub fn findNodeBySidebarIdentity(
    loaded: *const LoadedDiff,
    identity: context.SidebarIdentity,
) ?usize {
    for (loaded.tree.nodes, 0..) |node, index| {
        switch (identity) {
            .repo_root => if (node.kind == .repo_root) return index,
            .directory => |path| {
                if (node.kind == .directory and std.mem.eql(u8, node.path, path)) return index;
            },
            .file => |path_key| {
                if (node.kind != .file) continue;
                const node_key = if (node.path_key.len > 0) node.path_key else node.path;
                if (std.mem.eql(u8, node_key, path_key)) return index;
            },
        }
    }
    return null;
}

fn typedActionNode(
    loaded: *const LoadedDiff,
    target: *const review_page.action_cursor.Target,
) ?usize {
    for (loaded.tree.nodes, 0..) |node, index| {
        const kind_matches = switch (target.kind) {
            .repository_root => node.kind == .repo_root,
            .directory => node.kind == .directory,
            .file => node.kind == .file,
        };
        if (!kind_matches) continue;
        if (target.kind == .repository_root) return index;
        const node_key = if (node.path_key.len > 0) node.path_key else node.path;
        if (std.mem.eql(u8, node_key, target.path_key)) return index;
    }
    return null;
}

/// Honest transient/final fallback for directory-like action targets. The
/// deepest materialized directory ancestor wins; the typed repository root is
/// the last fallback. A nearby file is never substituted.
fn deepestVisibleTypedAncestor(loaded: *const LoadedDiff, path_key: []const u8) ?usize {
    var best_directory: ?usize = null;
    var best_len: usize = 0;
    var root: ?usize = null;
    for (loaded.tree.nodes, 0..) |node, index| {
        if (loaded.visibleRowOfNode(index) == null) continue;
        switch (node.kind) {
            .repo_root => root = index,
            .directory => {
                if (!file_tree.isPathAncestor(node.path, path_key)) continue;
                if (node.path.len >= best_len) {
                    best_directory = index;
                    best_len = node.path.len;
                }
            },
            .file => {},
        }
    }
    return best_directory orelse root;
}

pub fn findFileNodeByPathKey(loaded: *const LoadedDiff, path_key: []const u8) ?usize {
    for (loaded.tree.nodes, 0..) |node, index| {
        if (node.kind != .file) continue;
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

const SelectionRegion = struct {
    side: diff_selection.Side,
    mode: diff_selection.Mode,
    text_cell: usize,
    leading_boundary: bool = false,
};

const ParsedMouseLine = struct {
    hunk_index: usize,
    line_index: usize,
    line: diff_parser.DiffLine,
    region: SelectionRegion,
};

fn parsedMouseLine(
    target: ParsedSelectionTarget,
    body_col: u16,
    body_width: u16,
    display_mode: diff_render.DisplayMode,
    offset: usize,
    line_numbers: bool,
    locked: ?diff_selection.DragSelection,
) ?ParsedMouseLine {
    var rows = if (target.line_index.mode == display_mode and target.line_index.hunk_offsets.len == target.file.hunks.len)
        diff_view_model.BodyRowIterator.initAtWithFolded(target.file, display_mode, target.line_index, offset, target.folded_hunks)
    else
        diff_view_model.BodyRowIterator.initWithFolded(target.file, display_mode, target.folded_hunks);
    var skipped: usize = if (target.line_index.hunk_offsets.len == target.file.hunks.len) offset else 0;
    var row = rows.next() orelse return null;
    while (skipped < offset) : (skipped += 1) row = rows.next() orelse return null;
    const hunk_index = rows.currentHunkIndex() orelse return null;
    return switch (row) {
        .unified_line => |line| blk: {
            const line_index = rows.currentUnifiedLineIndex() orelse return null;
            const region = selectionRegionForUnified(body_col, line_numbers, line, locked) orelse return null;
            break :blk .{ .hunk_index = hunk_index, .line_index = line_index, .line = line, .region = region };
        },
        .side_by_side => blk: {
            const indexed = rows.currentSideBySideRow() orelse return null;
            const geometry = diff_render.sideBySideGeometry(body_width);
            const side = geometry.sideAt(body_col) orelse return null;
            if (locked) |selection| if (selection.side != side) return null;
            const side_region = switch (side) {
                .old => geometry.old,
                .new => geometry.new,
            };
            const local_col = body_col - side_region.col;
            const text_col = diff_render.lineTextStart(line_numbers, .side_by_side);
            const mode: diff_selection.Mode = if (locked) |selection| selection.mode else if (local_col < text_col) .line else .character;
            const text_cell: usize = if (local_col > text_col) local_col - text_col else 0;
            const selected_line = indexedLineForSide(indexed, side) orelse return null;
            break :blk .{
                .hunk_index = hunk_index,
                .line_index = selected_line.line_index,
                .line = selected_line.line,
                .region = .{
                    .side = side,
                    .mode = mode,
                    .text_cell = text_cell,
                    .leading_boundary = locked != null and mode == .character and local_col < text_col,
                },
            };
        },
        .metadata, .binary_marker, .hunk_header => null,
    };
}

fn indexedLineForSide(row: diff_view_model.SideBySideIndexedRow, side: diff_selection.Side) ?diff_view_model.IndexedDiffLine {
    return switch (row) {
        .single => |line| if (diff_selection.lineVisibleOnSide(line.line, side)) line else null,
        .paired => |pair| switch (side) {
            .old => pair.removed,
            .new => pair.added,
        },
    };
}

fn selectionRegionForUnified(body_col: u16, line_numbers: bool, line: diff_parser.DiffLine, locked: ?diff_selection.DragSelection) ?SelectionRegion {
    const text_col = diff_render.lineTextStart(line_numbers, .unified);
    const side: diff_selection.Side = if (locked) |selection|
        selection.side
    else if (line_numbers and body_col < 5)
        .old
    else if (line_numbers and body_col < 10)
        .new
    else switch (line.kind) {
        .removed => .old,
        .added, .context => .new,
        .metadata => return null,
    };
    if (!diff_selection.lineVisibleOnSide(line, side)) return null;
    const mode: diff_selection.Mode = if (locked) |selection| selection.mode else if (body_col < text_col) .line else .character;
    return .{
        .side = side,
        .mode = mode,
        .text_cell = if (body_col > text_col) body_col - text_col else 0,
        .leading_boundary = locked != null and mode == .character and body_col < text_col,
    };
}

fn selectionRegionForGenerated(body_col: u16, body_width: u16, display_mode: diff_render.DisplayMode, line_numbers: bool, locked: ?diff_selection.DragSelection) ?SelectionRegion {
    if (locked) |selection| if (selection.side != .new) return null;
    const local_col = switch (display_mode) {
        .unified => body_col,
        .side_by_side => blk: {
            const geometry = diff_render.sideBySideGeometry(body_width);
            if (geometry.sideAt(body_col) != .new) return null;
            break :blk body_col - geometry.new.col;
        },
    };
    const text_col = diff_render.lineTextStart(line_numbers, if (display_mode == .unified) .unified else .side_by_side);
    const mode: diff_selection.Mode = if (locked) |selection| selection.mode else if (local_col < text_col) .line else .character;
    return .{
        .side = .new,
        .mode = mode,
        .text_cell = if (local_col > text_col) local_col - text_col else 0,
        .leading_boundary = locked != null and mode == .character and local_col < text_col,
    };
}

fn pointForTextCell(hunk_index: usize, line_index: usize, text: []const u8, mode: diff_selection.Mode, cell: usize) ?diff_selection.Point {
    if (mode == .line) return diff_selection.pointFromLine(hunk_index, line_index);
    return switch (text_projection.hitAtDisplayCell(text, cell) orelse return null) {
        .token => |token| diff_selection.pointFromToken(hunk_index, line_index, token),
        .boundary => |boundary| diff_selection.pointFromBoundary(hunk_index, line_index, boundary.offset),
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
    const width = text_projection.displayWidth(text) catch return 0;
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
    repo_epoch: u64 = 0,
    root_identity: ?root_capability.Identity = null,
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
            .repo_epoch = self.repo_epoch,
            .root_identity = self.root_identity,
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

fn exactReviewIntent(app: *const TestHarness, path: []const u8) page_link.ReviewLocationIntent {
    return .{
        .repo_epoch = app.repo_epoch,
        .root_identity = app.root_identity.?,
        .path = path,
    };
}

fn expectExactPathReady(target: Controller.ExactPathTarget, expected_node: usize) !void {
    switch (target) {
        .ready => |node_index| try std.testing.expectEqual(expected_node, node_index),
        .unavailable => |reason| {
            std.debug.print("expected exact Review path, found unavailable reason {s}\n", .{@tagName(reason)});
            return error.TestUnexpectedResult;
        },
    }
}

fn expectExactPathUnavailable(
    target: Controller.ExactPathTarget,
    expected: page_link.ReviewUnavailableReason,
) !void {
    switch (target) {
        .ready => |node_index| {
            std.debug.print("expected unavailable Review path, found node {d}\n", .{node_index});
            return error.TestUnexpectedResult;
        },
        .unavailable => |actual| try std.testing.expectEqual(expected, actual),
    }
}

fn expectExactPathRevealSelected(result: Controller.ExactPathRevealResult, expected_node: usize) !void {
    switch (result) {
        .selected => |node_index| try std.testing.expectEqual(expected_node, node_index),
        .unchanged => return error.TestUnexpectedUnchanged,
        .unavailable => return error.TestUnexpectedUnavailable,
    }
}

fn expectExactPathRevealUnchanged(result: Controller.ExactPathRevealResult, expected_node: usize) !void {
    switch (result) {
        .unchanged => |node_index| try std.testing.expectEqual(expected_node, node_index),
        .selected => return error.TestUnexpectedSelection,
        .unavailable => return error.TestUnexpectedUnavailable,
    }
}

fn expectExactPathRevealUnavailable(
    result: Controller.ExactPathRevealResult,
    expected: page_link.ReviewUnavailableReason,
) !void {
    switch (result) {
        .unavailable => |actual| try std.testing.expectEqual(expected, actual),
        .selected => return error.TestUnexpectedSelection,
        .unchanged => return error.TestUnexpectedUnchanged,
    }
}

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
    app.pages.review.file_search.input = .{};
    @memcpy(app.pages.review.file_search.input.buffer[0..query.len], query);
    app.pages.review.file_search.input.len = query.len;
    app.pages.review.file_search.input.cursor = query.len;
}

fn setAndRebuildFileSearch(app: *TestHarness, query: []const u8) void {
    setFileSearchInput(app, query);
    app.reviewNavigation().rebuildFileSearchProjection(std.testing.allocator);
}

const file_search_nested_nodes = [_]file_tree.Node{
    .{ .kind = .directory, .name = "src", .path = "src", .path_key = "src", .depth = 0 },
    .{ .kind = .file, .name = "a", .path = "src/a", .path_key = "src/a", .depth = 1, .target = .{ .diff_file = 0 } },
    .{ .kind = .file, .name = "b", .path = "src/b", .path_key = "src/b", .depth = 1, .target = .{ .diff_file = 1 } },
};

const file_search_rooted_nested_nodes = [_]file_tree.Node{
    .{ .kind = .repo_root, .name = "repo", .path = "", .depth = 0, .target = .repo_root },
    .{ .kind = .directory, .name = "src", .path = "src", .path_key = "src", .depth = 1 },
    .{ .kind = .file, .name = "a", .path = "src/a", .path_key = "src/a", .depth = 2, .target = .{ .diff_file = 0 } },
    .{ .kind = .file, .name = "b", .path = "src/b", .path_key = "src/b", .depth = 2, .target = .{ .diff_file = 1 } },
};

fn fileSearchLoadedNested() LoadedDiff {
    var loaded = app_test_support.loadedDiffNested();
    loaded.tree.nodes = &file_search_nested_nodes;
    return loaded;
}

fn fileSearchLoadedRootedNested() LoadedDiff {
    var loaded = app_test_support.loadedDiffRootedNested();
    loaded.tree.nodes = &file_search_rooted_nested_nodes;
    return loaded;
}

const file_search_lens_nodes = [_]file_tree.Node{
    .{ .kind = .file, .name = "a", .path = "a", .path_key = "a", .depth = 0, .status = .modified, .target = .{ .diff_file = 0 } },
    .{ .kind = .file, .name = "b", .path = "b", .path_key = "b", .depth = 0, .status = .added, .target = .{ .diff_file = 1 } },
};

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
    }, .{ .width = 100, .height = 9 });

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

test "Review mouse selection ignores the opposite side and resumes on its locked side" {
    var harness = TestHarness.init(.{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{
            .display_mode = .side_by_side,
            .sidebar_hidden = true,
        },
    }, .{ .width = 140, .height = 12 });

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
    try std.testing.expectEqual(@as(usize, 0), dragged.focus.line_index);
    try std.testing.expect(!dragged.moved);

    harness.controller().dragDiffMouse(.{
        .col = 10,
        .row = diff_render.body_start_row + 3,
    });
    const resumed = harness.pages.review.selection_owner.activeDiff() orelse return error.ExpectedDiffSelection;
    try std.testing.expectEqual(diff_selection.Side.old, resumed.side);
    try std.testing.expectEqual(@as(usize, 2), resumed.focus.line_index);
    try std.testing.expect(resumed.moved);
}

test "unified body selects characters while gutter keeps line gestures semantic" {
    const lines = [_]diff_parser.DiffLine{
        .{ .kind = .context, .text = "ABCDEFG", .old_line = 1, .new_line = 1 },
        .{ .kind = .context, .text = "HIJKLMN", .old_line = 2, .new_line = 2 },
    };
    const files = [_]diff_parser.FileDiff{.{
        .header = "diff --git a/a b/a",
        .old_path = "a/a",
        .new_path = "b/a",
        .metadata = &.{},
        .hunks = &.{.{
            .old_start = 1,
            .old_count = 2,
            .new_start = 1,
            .new_count = 2,
            .section = "",
            .lines = &lines,
        }},
    }};
    const eligibility = [_]loaded_diff.FileTextEligibility{.selectable_utf8};
    const tree = [_]file_tree.Node{.{ .kind = .file, .name = "a", .path = "a", .depth = 0, .target = .{ .diff_file = 0 } }};
    const loaded: loaded_diff.LoadedDiff = .{
        .text = "",
        .document = .{ .files = &files },
        .file_text_eligibility = &eligibility,
        .tree = .{ .nodes = &tree },
        .bytes = 0,
        .lines = 0,
    };
    var harness = TestHarness.init(.{
        .load = test_support.loadState(loaded),
        .viewer = .{ .display_mode = .unified, .sidebar_hidden = true },
    }, .{ .width = 100, .height = 12 });

    const raw = harness.view().rawDiffPaneGeometry().?;
    const content_width = contentWidth(raw.width);
    const content_gutter = raw.width - content_width;
    const text_start = raw.col + content_gutter + diff_render.cursor_gutter_width + diff_render.lineTextStart(true, .unified);

    harness.controller().pressDiffMouse(.{ .col = text_start + 3, .row = diff_render.body_start_row + 1 });
    harness.controller().dragDiffMouse(.{ .col = text_start + 4, .row = diff_render.body_start_row + 2 });
    const characters = harness.pages.review.selection_owner.activeDiff() orelse return error.ExpectedDiffSelection;
    try std.testing.expectEqual(diff_selection.Mode.character, characters.mode);
    try std.testing.expectEqual(diff_selection.Side.new, characters.side);
    const range = characters.range();
    try std.testing.expectEqual(@as(usize, 3), range.start.leading);
    try std.testing.expectEqual(@as(usize, 4), range.start.trailing);
    try std.testing.expectEqual(@as(usize, 4), range.end.leading);
    try std.testing.expectEqual(@as(usize, 5), range.end.trailing);
    const copied = try diff_selection.copyText(std.testing.allocator, files[0], characters);
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings("DEFG\nHIJKL", copied);

    // Continuing a character gesture into its own gutter means the leading
    // line boundary; it does not silently switch to whole-line mode.
    const new_line_number_col = raw.col + content_gutter + diff_render.cursor_gutter_width + 6;
    harness.controller().dragDiffMouse(.{ .col = new_line_number_col, .row = diff_render.body_start_row + 1 });
    const into_gutter = harness.pages.review.selection_owner.activeDiff() orelse return error.ExpectedDiffSelection;
    try std.testing.expectEqual(diff_selection.Mode.character, into_gutter.mode);
    try std.testing.expectEqual(@as(usize, 0), into_gutter.focus.leading);
    try std.testing.expectEqual(@as(usize, 0), into_gutter.focus.trailing);

    harness.controller().clearDiffSelection();
    harness.controller().pressDiffMouse(.{ .col = text_start, .row = diff_render.body_start_row + 1 });
    harness.controller().dragDiffMouse(.{ .col = new_line_number_col, .row = diff_render.body_start_row + 1 });
    const first_token_to_gutter = harness.pages.review.selection_owner.activeDiff() orelse return error.ExpectedDiffSelection;
    const first_token_copy = try diff_selection.copyText(std.testing.allocator, files[0], first_token_to_gutter);
    defer std.testing.allocator.free(first_token_copy);
    try std.testing.expectEqualStrings("A", first_token_copy);

    harness.controller().clearDiffSelection();
    harness.controller().pressDiffMouse(.{ .col = new_line_number_col, .row = diff_render.body_start_row + 1 });
    harness.controller().dragDiffMouse(.{ .col = text_start + 4, .row = diff_render.body_start_row + 2 });
    const lines_selected = harness.pages.review.selection_owner.activeDiff() orelse return error.ExpectedDiffSelection;
    try std.testing.expectEqual(diff_selection.Mode.line, lines_selected.mode);
    try std.testing.expectEqual(diff_selection.Side.new, lines_selected.side);
}

test "invalid primary file is inert while its valid sibling remains selectable" {
    const eligibility = [_]loaded_diff.FileTextEligibility{ .selectable_utf8, .inert_invalid_utf8 };
    var loaded = test_support.loadedDiffTwo();
    loaded.file_text_eligibility = &eligibility;
    var harness = TestHarness.init(.{
        .load = test_support.loadState(loaded),
        .viewer = .{
            .selected_target = .{ .diff_file = 1 },
            .selected_file = 1,
            .selected_node = 1,
            .diff_cursor = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 0 } },
            .display_mode = .unified,
            .sidebar_hidden = true,
        },
    }, .{ .width = 100, .height = 12 });

    try std.testing.expect(harness.view().displayedReviewBody() == .inert_invalid_utf8);
    try std.testing.expect(!harness.view().bodyAllowsHunkInteraction());
    try std.testing.expect(harness.view().selectedHunkIndex() == null);
    try std.testing.expect(harness.view().displayedDiffFile() == null);
    try std.testing.expect(harness.view().unsupportedSearchMessage() != null);
    harness.pages.review.viewer.diff_scroll = 99;
    harness.pages.review.viewer.diff_horizontal_scroll = 99;
    harness.controller().clampDiffNavigation();
    try std.testing.expectEqual(diff_view_model.BodyCoordinate{ .metadata = 0 }, harness.pages.review.viewer.diff_cursor);
    try std.testing.expectEqual(@as(usize, 0), harness.pages.review.viewer.diff_scroll);
    try std.testing.expectEqual(@as(usize, 0), harness.pages.review.viewer.diff_horizontal_scroll);
    harness.controller().pageDiff(.down);
    harness.controller().scrollDiff(.down);
    harness.controller().scrollDiffHorizontal(.right);
    harness.controller().selectHunkDelta(1);
    harness.controller().toggleSelectedHunkFold();
    try std.testing.expectEqual(diff_view_model.BodyCoordinate{ .metadata = 0 }, harness.pages.review.viewer.diff_cursor);
    try std.testing.expectEqual(@as(usize, 0), harness.pages.review.viewer.diff_scroll);
    try std.testing.expectEqual(@as(usize, 0), harness.pages.review.viewer.diff_horizontal_scroll);
    harness.controller().pressDiffMouse(.{ .col = 12, .row = diff_render.body_start_row + 1 });
    try std.testing.expect(harness.pages.review.selection_owner == .none);

    harness.controller().selectFileAbsolute(0);
    try std.testing.expect(harness.view().displayedReviewBody() == .primary);
    try std.testing.expect(harness.view().bodyAllowsHunkInteraction());
    harness.controller().pressDiffMouse(.{ .col = 12, .row = diff_render.body_start_row + 1 });
    try std.testing.expect(harness.pages.review.selection_owner.activeDiff() != null);
}

test "invalid cached projection cannot fall through to primary hunk authority" {
    const allocator = std.testing.allocator;
    const invalid_patch =
        "diff --git a/a b/a\n" ++
        "index 1111111..2222222 100644\n" ++
        "--- a/a\n" ++
        "+++ b/a\n" ++
        "@@ -1 +1 @@\n" ++
        "-old\n" ++
        "+bad\xff\n";
    var cached = try app_load.buildLoadedBundle(allocator, invalid_patch);
    var cached_owned = true;
    defer if (cached_owned) cached.deinit();

    var harness = TestHarness.init(.{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{
            .selected_target = .{ .status_only = 0 },
            .diff_cursor = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 0 } },
            .display_mode = .unified,
            .sidebar_hidden = true,
        },
    }, .{ .width = 100, .height = 12 });
    harness.repo_root = "/repo";
    _ = harness.pages.review.activation.activate(0, .fresh, .fresh, .fresh);
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "M  a\x00");
    try harness.pages.review.git_status.replace("/repo", &status_bundle);
    harness.pages.review.review_projection.installReady(.{
        .request = try review_projection.cloneRequest(
            allocator,
            harness.pages.review.activation.currentIdentity().?,
            1,
            "/repo",
            "a",
            .cached_diff,
            .unstaged,
            0,
            0,
        ),
        .value = .{ .cached_diff = cached },
    });
    cached_owned = false;
    defer harness.pages.review.deinit(allocator);

    try std.testing.expect(harness.view().displayedReviewBody() == .inert_invalid_utf8);
    try std.testing.expect(!harness.view().bodyAllowsHunkInteraction());
    try std.testing.expect(harness.view().activeCachedDiffProjection() == null);
    try std.testing.expect(harness.view().displayedDiffFile() == null);
    try std.testing.expect(harness.view().selectedHunkIndex() == null);
    harness.pages.review.viewer.diff_scroll = 99;
    harness.pages.review.viewer.diff_horizontal_scroll = 99;
    harness.controller().clampDiffNavigation();
    try std.testing.expectEqual(diff_view_model.BodyCoordinate{ .metadata = 0 }, harness.pages.review.viewer.diff_cursor);
    try std.testing.expectEqual(@as(usize, 0), harness.pages.review.viewer.diff_scroll);
    try std.testing.expectEqual(@as(usize, 0), harness.pages.review.viewer.diff_horizontal_scroll);
    harness.controller().pageDiff(.down);
    harness.controller().scrollDiff(.down);
    harness.controller().scrollDiffHorizontal(.right);
    try std.testing.expectEqual(@as(usize, 0), harness.pages.review.viewer.diff_scroll);
    try std.testing.expectEqual(@as(usize, 0), harness.pages.review.viewer.diff_horizontal_scroll);
    harness.controller().pressDiffMouse(.{ .col = 12, .row = diff_render.body_start_row + 1 });
    try std.testing.expect(harness.pages.review.selection_owner == .none);
}

test "either invalid combined component remains inert without primary navigation fallback" {
    const allocator = std.testing.allocator;
    const valid_patch =
        "diff --git a/a b/a\n" ++
        "index 1111111..2222222 100644\n" ++
        "--- a/a\n" ++
        "+++ b/a\n" ++
        "@@ -1 +1 @@\n" ++
        "-old\n" ++
        "+valid\n";
    const invalid_patch =
        "diff --git a/a b/a\n" ++
        "index 1111111..2222222 100644\n" ++
        "--- a/a\n" ++
        "+++ b/a\n" ++
        "@@ -1 +1 @@\n" ++
        "-old\n" ++
        "+bad\xff\n";

    for ([_]bool{ true, false }) |cached_is_invalid| {
        var cached = try app_load.buildLoadedBundle(allocator, if (cached_is_invalid) invalid_patch else valid_patch);
        var cached_owned = true;
        defer if (cached_owned) cached.deinit();
        var unstaged = try app_load.buildLoadedBundle(allocator, if (cached_is_invalid) valid_patch else invalid_patch);
        var unstaged_owned = true;
        defer if (unstaged_owned) unstaged.deinit();

        var harness = TestHarness.init(.{
            .load = test_support.loadState(test_support.loadedDiffOne()),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .diff_cursor = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 0 } },
                .diff_scroll = 99,
                .diff_horizontal_scroll = 99,
                .display_mode = .unified,
                .sidebar_hidden = true,
            },
        }, .{ .width = 100, .height = 12 });
        harness.repo_root = "/repo";
        _ = harness.pages.review.activation.activate(0, .fresh, .fresh, .fresh);
        var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
        try harness.pages.review.git_status.replace("/repo", &status_bundle);
        harness.pages.review.review_projection.installReady(.{
            .request = try review_projection.cloneRequest(
                allocator,
                harness.pages.review.activation.currentIdentity().?,
                1,
                "/repo",
                "a",
                .combined_hunks,
                .unstaged,
                0,
                0,
            ),
            .value = .{ .inert_combined = .{
                .cached_bundle = cached,
                .unstaged_bundle = unstaged,
            } },
        });
        cached_owned = false;
        unstaged_owned = false;
        defer harness.pages.review.deinit(allocator);

        try std.testing.expect(harness.view().displayedReviewBody() == .inert_invalid_utf8);
        try std.testing.expect(harness.view().activeCombinedProjection() == null);
        try std.testing.expect(harness.view().displayedDiffFile() == null);
        try std.testing.expect(harness.view().selectedHunkIndex() == null);
        try std.testing.expectEqual(HunkInteractionAvailability.inert_invalid_utf8, harness.view().hunkInteractionAvailability());
        harness.controller().clampDiffNavigation();
        harness.controller().pageDiff(.down);
        harness.controller().scrollDiff(.down);
        harness.controller().scrollDiffHorizontal(.right);
        harness.controller().selectHunkDelta(1);
        harness.controller().toggleSelectedHunkFold();
        try std.testing.expectEqual(diff_view_model.BodyCoordinate{ .metadata = 0 }, harness.pages.review.viewer.diff_cursor);
        try std.testing.expectEqual(@as(usize, 0), harness.pages.review.viewer.diff_scroll);
        try std.testing.expectEqual(@as(usize, 0), harness.pages.review.viewer.diff_horizontal_scroll);
    }
}

test "cached combined and generated displayed bodies expose typed mouse identities" {
    const allocator = std.testing.allocator;

    // Staged-only cached projection.
    var cached_harness = TestHarness.init(.{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .status_only = 0 }, .display_mode = .unified, .sidebar_hidden = true },
    }, .{ .width = 100, .height = 12 });
    cached_harness.repo_root = "/repo";
    _ = cached_harness.pages.review.activation.activate(0, .fresh, .fresh, .fresh);
    var cached_status = try git_status.StatusBundle.parseOwned(allocator, "M  a\x00");
    try cached_harness.pages.review.git_status.replace("/repo", &cached_status);
    cached_harness.pages.review.review_projection.installReady(.{
        .request = try review_projection.cloneRequest(allocator, cached_harness.pages.review.activation.currentIdentity().?, 1, "/repo", "a", .cached_diff, .unstaged, 0, 0),
        .value = .{ .cached_diff = try app_load.buildLoadedBundle(allocator, test_support.diff_cached_projection) },
    });
    defer cached_harness.pages.review.deinit(allocator);
    const cached_raw = cached_harness.view().rawDiffPaneGeometry().?;
    const cached_content_width = contentWidth(cached_raw.width);
    const cached_text = cached_raw.col + (cached_raw.width - cached_content_width) + diff_render.cursor_gutter_width + diff_render.lineTextStart(true, .unified);
    cached_harness.controller().pressDiffMouse(.{ .col = cached_text + 1, .row = diff_render.body_start_row + 1 });
    const cached_selection = cached_harness.pages.review.selection_owner.activeDiff() orelse return error.ExpectedDiffSelection;
    try std.testing.expectEqual(diff_selection.Mode.character, cached_selection.mode);
    try std.testing.expect(cached_selection.identity == .projection_file);
    try std.testing.expect(cached_selection.identity.projection_file.kind == .cached);

    // Mixed cached/unstaged projection.
    var combined_harness = TestHarness.init(.{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .diff_file = 0 }, .display_mode = .unified, .sidebar_hidden = true },
    }, .{ .width = 100, .height = 12 });
    combined_harness.repo_root = "/repo";
    _ = combined_harness.pages.review.activation.activate(0, .fresh, .fresh, .fresh);
    var combined_status = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try combined_harness.pages.review.git_status.replace("/repo", &combined_status);
    var cached_bundle = try app_load.buildLoadedBundle(allocator, test_support.diff_cached_projection);
    var cached_owned = true;
    defer if (cached_owned) cached_bundle.deinit();
    var unstaged_bundle = try app_load.buildLoadedBundle(allocator, test_support.diff_unstaged_projection);
    var unstaged_owned = true;
    defer if (unstaged_owned) unstaged_bundle.deinit();
    var cached_authority = try projection_component.ParsedComponent.parse(allocator, test_support.diff_cached_projection);
    var cached_authority_owned = true;
    defer if (cached_authority_owned) cached_authority.deinit();
    var unstaged_authority = try projection_component.ParsedComponent.parse(allocator, test_support.diff_unstaged_projection);
    var unstaged_authority_owned = true;
    defer if (unstaged_authority_owned) unstaged_authority.deinit();
    var presentation_arena = std.heap.ArenaAllocator.init(allocator);
    var presentation_owned = true;
    defer if (presentation_owned) presentation_arena.deinit();
    var authority_arena = std.heap.ArenaAllocator.init(allocator);
    var authority_owned = true;
    defer if (authority_owned) authority_arena.deinit();
    const projection = try diff_hunk_projection.buildWithAllocators(
        presentation_arena.allocator(),
        authority_arena.allocator(),
        cached_bundle.loaded.document.files[0],
        unstaged_bundle.loaded.document.files[0],
    );
    combined_harness.pages.review.review_projection.installReady(.{
        .request = try review_projection.cloneRequest(allocator, combined_harness.pages.review.activation.currentIdentity().?, 1, "/repo", "a", .combined_hunks, .unstaged, 0, 0),
        .value = .{ .combined_hunks = .{
            .presentation = .{
                .arena = presentation_arena,
                .projection = projection.presentation,
                .cached_bundle = cached_bundle,
                .unstaged_bundle = unstaged_bundle,
                .fingerprint = diff_presentation_identity.fingerprint(projection.presentation.file),
                .content_token = .init(1),
            },
            .authority = .{
                .arena = authority_arena,
                .projection = projection.authority,
                .cached_component = cached_authority,
                .unstaged_component = unstaged_authority,
                .status_snapshot_revision = 0,
            },
        } },
    });
    presentation_owned = false;
    authority_owned = false;
    cached_owned = false;
    unstaged_owned = false;
    cached_authority_owned = false;
    unstaged_authority_owned = false;
    defer combined_harness.pages.review.deinit(allocator);
    const combined_raw = combined_harness.view().rawDiffPaneGeometry().?;
    const combined_content_width = contentWidth(combined_raw.width);
    const combined_text = combined_raw.col + (combined_raw.width - combined_content_width) + diff_render.cursor_gutter_width + diff_render.lineTextStart(true, .unified);
    combined_harness.controller().pressDiffMouse(.{ .col = combined_text + 1, .row = diff_render.body_start_row + 1 });
    const combined_selection = combined_harness.pages.review.selection_owner.activeDiff() orelse return error.ExpectedDiffSelection;
    try std.testing.expect(combined_selection.identity == .projection_file);
    try std.testing.expect(combined_selection.identity.projection_file.kind == .combined);

    // Generated untracked preview uses its own non-hunk identity.
    var generated_harness = TestHarness.init(.{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .status_only = 0 }, .display_mode = .unified, .sidebar_hidden = true },
    }, .{ .width = 100, .height = 12 });
    generated_harness.repo_root = "/repo";
    _ = generated_harness.pages.review.activation.activate(0, .fresh, .fresh, .fresh);
    var generated_status = try git_status.StatusBundle.parseOwned(allocator, "?? a\x00");
    try generated_harness.pages.review.git_status.replace("/repo", &generated_status);
    generated_harness.pages.review.review_projection.installReady(.{
        .request = try review_projection.cloneRequest(allocator, generated_harness.pages.review.activation.currentIdentity().?, 1, "/repo", "a", .generated_added_file, .unstaged, 0, 0),
        .value = .{ .generated_added_file = try review_projection.generatedFileFromContent(allocator, "a", "ABCDEFG\n") },
    });
    defer generated_harness.pages.review.deinit(allocator);
    const generated_raw = generated_harness.view().rawDiffPaneGeometry().?;
    const generated_content_width = contentWidth(generated_raw.width);
    const generated_text = generated_raw.col + (generated_raw.width - generated_content_width) + diff_render.cursor_gutter_width + diff_render.lineTextStart(true, .unified);
    generated_harness.controller().pressDiffMouse(.{ .col = generated_text + 3, .row = diff_render.body_start_row });
    const generated_selection = generated_harness.pages.review.selection_owner.activeDiff() orelse return error.ExpectedDiffSelection;
    try std.testing.expect(generated_selection.identity == .generated_file);
    try std.testing.expectEqual(diff_selection.Mode.character, generated_selection.mode);
    try std.testing.expectEqual(@as(usize, 3), generated_selection.anchor.leading);
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
    }, .{ .width = 100, .height = 9 });

    const snapshot = harness.view().displayNavigationSnapshot();
    try std.testing.expectEqual(@as(usize, 4), snapshot.diff_scroll);
    try std.testing.expectEqual(@as(?usize, 6), snapshot.search_match_offset);

    var anchor: review_page.ReloadAnchor = .{
        .path_key = try allocator.dupe(u8, "a"),
        .sidebar_identity = .{ .file = try allocator.dupe(u8, "a") },
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
        .terminal_size = .{ .width = 140, .height = 9 },
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
        .terminal_size = .{ .width = 140, .height = 10 },
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
        .terminal_size = .{ .width = 140, .height = 9 },
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
        .terminal_size = .{ .width = 140, .height = 9 },
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

test "repository root disclosure toggles typed projection and retains diff target" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), app_test_support.loadedDiffRootedNested()),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_file = 1,
                .selected_node = 0,
            },
        } },
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer app.clearLoadedDiff();

    try app.reviewNavigation().toggleSelectedDirectory();

    var loaded = app.reviewNavigation().loadedDiff().?;
    try std.testing.expectEqual(file_tree.RootDisclosure.collapsed, app.pages.review.viewer.root_disclosure);
    try std.testing.expectEqual(file_tree.RootDisclosure.collapsed, loaded.root_disclosure);
    try std.testing.expectEqual(@as(usize, 1), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(?usize, 0), loaded.visibleNodeAt(0));
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.review.viewer.selected_target.?);
    try std.testing.expect(!file_tree.isCollapsed(&loaded.collapsed_dirs, ""));

    try app.reviewNavigation().expandSelectedDirectory();

    loaded = app.reviewNavigation().loadedDiff().?;
    try std.testing.expectEqual(file_tree.RootDisclosure.expanded, app.pages.review.viewer.root_disclosure);
    try std.testing.expectEqual(file_tree.RootDisclosure.expanded, loaded.root_disclosure);
    try std.testing.expectEqual(@as(usize, 4), loaded.visibleNodeCount());
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.review.viewer.selected_target.?);
}

test "repository root mouse click selects and toggles the real target" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), app_test_support.loadedDiffRootedNested()),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_file = 1,
                .selected_node = 3,
                .focus = .diff,
            },
        } },
    };
    defer app.clearLoadedDiff();

    try app.reviewNavigation().clickSidebarNode(0);

    const loaded = app.reviewNavigation().loadedDiff().?;
    try std.testing.expectEqual(review_page.Focus.sidebar, app.pages.review.viewer.focus);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(file_tree.RootDisclosure.collapsed, app.pages.review.viewer.root_disclosure);
    try std.testing.expectEqual(@as(usize, 1), loaded.visibleNodeCount());
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.review.viewer.selected_target.?);
}

test "repository switch resets Review root disclosure" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_file = 1,
                .selected_node = 3,
                .root_disclosure = .collapsed,
            },
            .search = .{
                .mode = true,
            },
        } },
    };
    setDiffSearchQuery(&app, "needle");

    app.reviewNavigation().resetAfterRepositorySwitch();

    try std.testing.expectEqual(file_tree.RootDisclosure.expanded, app.pages.review.viewer.root_disclosure);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, app.pages.review.viewer.selected_target.?);
    try std.testing.expect(!app.pages.review.search.mode);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.search.input.len);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.search.query.len);
}

test "left and right navigation use repository root as a directory parent" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), app_test_support.loadedDiffRootedNested()),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_file = 0,
                .selected_node = 1,
            },
        } },
    };
    defer app.clearLoadedDiff();

    try app.reviewNavigation().collapseOrSelectParentDirectory();
    var loaded = app.reviewNavigation().loadedDiff().?;
    try std.testing.expect(file_tree.isCollapsed(&loaded.collapsed_dirs, "src"));
    try std.testing.expectEqual(@as(usize, 2), loaded.visibleNodeCount());

    try app.reviewNavigation().collapseOrSelectParentDirectory();
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.selected_node);

    try app.reviewNavigation().collapseOrSelectParentDirectory();
    loaded = app.reviewNavigation().loadedDiff().?;
    try std.testing.expectEqual(file_tree.RootDisclosure.collapsed, app.pages.review.viewer.root_disclosure);
    try std.testing.expectEqual(@as(usize, 1), loaded.visibleNodeCount());

    try app.reviewNavigation().expandSelectedDirectory();
    loaded = app.reviewNavigation().loadedDiff().?;
    try std.testing.expectEqual(file_tree.RootDisclosure.expanded, app.pages.review.viewer.root_disclosure);
    try std.testing.expect(file_tree.isCollapsed(&loaded.collapsed_dirs, "src"));
    try std.testing.expectEqual(@as(usize, 2), loaded.visibleNodeCount());
}

test "file search selects matching file and expands ancestors" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), fileSearchLoadedNested()),
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
    setAndRebuildFileSearch(&app, "src/b");

    app.reviewNavigation().submitFileSearch(std.testing.allocator);

    loaded = app.reviewNavigation().loadedDiff().?;
    try std.testing.expect(!file_tree.isCollapsed(&loaded.collapsed_dirs, "src"));
    try std.testing.expectEqual(@as(usize, 2), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_file);
    try std.testing.expect(!app.pages.review.file_search.mode);
    try std.testing.expectEqual(review_page.Focus.diff, app.pages.review.viewer.focus);
}

test "file search expands collapsed repository root before selecting its match" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), fileSearchLoadedRootedNested()),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_file = 0,
                .selected_node = 0,
                .root_disclosure = .collapsed,
            },
            .file_search = .{ .mode = true },
        } },
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer app.clearLoadedDiff();

    const loaded = app.reviewNavigation().loadedDiff().?;
    try loaded.rebuildVisibleNodes(
        app.reviewNavigation().loadArenaAllocator().?,
        app.pages.review.viewer.root_disclosure,
        false,
        .all,
    );
    try file_tree.collapse(app.reviewNavigation().loadArenaAllocator().?, &loaded.collapsed_dirs, "src");
    setAndRebuildFileSearch(&app, "src/b");

    app.reviewNavigation().submitFileSearch(std.testing.allocator);

    try std.testing.expectEqual(file_tree.RootDisclosure.expanded, app.pages.review.viewer.root_disclosure);
    try std.testing.expectEqual(file_tree.RootDisclosure.expanded, loaded.root_disclosure);
    try std.testing.expect(!file_tree.isCollapsed(&loaded.collapsed_dirs, "src"));
    try std.testing.expect(!file_tree.isCollapsed(&loaded.collapsed_dirs, ""));
    try std.testing.expectEqual(@as(usize, 3), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.review.viewer.selected_target.?);
    try std.testing.expect(!app.pages.review.file_search.mode);
    try std.testing.expectEqual(review_page.Focus.diff, app.pages.review.viewer.focus);
}

test "review transition D1 exact lookup accepts diff status and collapsed raw paths" {
    const identity: root_capability.Identity = .{ .device = 3, .inode = 5 };
    {
        var app: TestHarness = .{
            .pages = .{ .review = .{
                .load = app_test_support.loadState(app_test_support.loadedDiffNested()),
                .viewer = .{ .selected_node = 1, .selected_file = 0 },
            } },
            .repo_epoch = 4,
            .root_identity = identity,
        };
        defer app.clearLoadedDiff();

        const loaded = app.reviewNavigation().loadedDiff().?;
        try file_tree.collapse(app.reviewNavigation().loadArenaAllocator().?, &loaded.collapsed_dirs, "src");

        try expectExactPathReady(
            app.reviewNavigation().exactPathTarget(exactReviewIntent(&app, "src/b")),
            2,
        );
        try std.testing.expect(file_tree.isCollapsed(&loaded.collapsed_dirs, "src"));
        try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_node);
    }

    {
        const raw_path = "new-\xff.zig";
        const status_nodes = [_]file_tree.Node{.{
            .kind = .file,
            .name = "new-invalid.zig",
            .path = "new-invalid.zig",
            .path_key = raw_path,
            .depth = 0,
            .target = .{ .status_entry = 0 },
            .status = .added,
        }};
        var app: TestHarness = .{
            .pages = .{ .review = .{
                .load = app_test_support.loadState(.{
                    .text = "",
                    .document = .{ .files = &.{} },
                    .file_text_eligibility = &.{},
                    .tree = .{ .nodes = &status_nodes },
                    .collapsed_dirs = .{},
                    .bytes = 0,
                    .lines = 0,
                }),
            } },
            .repo_epoch = 4,
            .root_identity = identity,
        };
        defer app.clearLoadedDiff();

        try expectExactPathReady(
            app.reviewNavigation().exactPathTarget(exactReviewIntent(&app, raw_path)),
            0,
        );
    }
}

test "review transition D1 exact lookup rejects non-current repository sources" {
    const identity: root_capability.Identity = .{ .device = 3, .inode = 5 };
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffNested()),
            .viewer = .{ .selected_node = 1, .selected_file = 0 },
        } },
        .repo_epoch = 4,
        .root_identity = identity,
    };
    defer app.clearLoadedDiff();

    const unsupported = [_]diff_source.SourceMode{
        .stdin,
        .{ .pager = "external diff" },
        .{ .patch_file = "change.patch" },
        .{ .range = "HEAD~1..HEAD" },
        .{ .no_index = .{ .left = "left", .right = "right" } },
    };
    for (unsupported) |source| {
        app.source = source;
        try expectExactPathUnavailable(
            app.reviewNavigation().exactPathTarget(exactReviewIntent(&app, "src/a")),
            .source_unavailable,
        );
        try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_node);
    }

    app.source = .cached;
    try expectExactPathReady(
        app.reviewNavigation().exactPathTarget(exactReviewIntent(&app, "src/a")),
        1,
    );
}

test "review transition D1 exact lookup skips colliding directories before files" {
    const identity: root_capability.Identity = .{ .device = 3, .inode = 5 };
    const replacement_diff =
        \\diff --git a/src/a b/src/a
        \\deleted file mode 100644
        \\--- a/src/a
        \\+++ /dev/null
        \\@@ -1 +0,0 @@
        \\-old nested file
        \\diff --git a/src b/src
        \\new file mode 100644
        \\--- /dev/null
        \\+++ b/src
        \\@@ -0,0 +1 @@
        \\+new top-level file
        \\
    ;
    var replacement_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer replacement_arena.deinit();
    const replacement_allocator = replacement_arena.allocator();
    const replacement_document = try diff_parser.parse(replacement_allocator, replacement_diff);
    const replacement_tree = try file_tree.build(replacement_allocator, replacement_document);
    try std.testing.expectEqual(@as(usize, 3), replacement_tree.nodes.len);
    try std.testing.expectEqual(file_tree.Node.Kind.directory, replacement_tree.nodes[0].kind);
    try std.testing.expectEqualStrings("src", replacement_tree.nodes[0].path);
    try std.testing.expectEqual(file_tree.Node.Kind.file, replacement_tree.nodes[2].kind);
    try std.testing.expectEqualStrings("src", replacement_tree.nodes[2].path_key);

    var replacement_app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(.{
                .text = replacement_diff,
                .document = replacement_document,
                .file_text_eligibility = &.{ .selectable_utf8, .selectable_utf8 },
                .tree = replacement_tree,
                .collapsed_dirs = .{},
                .bytes = replacement_diff.len,
                .lines = 0,
            }),
        } },
        .repo_epoch = 4,
        .root_identity = identity,
    };
    defer replacement_app.clearLoadedDiff();
    try expectExactPathReady(
        replacement_app.reviewNavigation().exactPathTarget(exactReviewIntent(&replacement_app, "src")),
        2,
    );

    const directory_only_diff =
        \\diff --git a/src/a b/src/a
        \\deleted file mode 100644
        \\--- a/src/a
        \\+++ /dev/null
        \\@@ -1 +0,0 @@
        \\-old nested file
        \\
    ;
    var directory_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer directory_arena.deinit();
    const directory_allocator = directory_arena.allocator();
    const directory_document = try diff_parser.parse(directory_allocator, directory_only_diff);
    const directory_tree = try file_tree.build(directory_allocator, directory_document);
    var directory_app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(.{
                .text = directory_only_diff,
                .document = directory_document,
                .file_text_eligibility = &.{.selectable_utf8},
                .tree = directory_tree,
                .collapsed_dirs = .{},
                .bytes = directory_only_diff.len,
                .lines = 0,
            }),
        } },
        .repo_epoch = 4,
        .root_identity = identity,
    };
    defer directory_app.clearLoadedDiff();
    try expectExactPathUnavailable(
        directory_app.reviewNavigation().exactPathTarget(exactReviewIntent(&directory_app, "src")),
        .path_not_found,
    );

    const legacy_nodes = [_]file_tree.Node{
        .{ .kind = .directory, .name = "legacy", .path = "legacy", .depth = 0 },
        .{ .kind = .file, .name = "legacy", .path = "legacy", .depth = 0, .target = .{ .status_entry = 0 } },
    };
    var legacy_app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(.{
                .text = "",
                .document = .{ .files = &.{} },
                .file_text_eligibility = &.{},
                .tree = .{ .nodes = &legacy_nodes },
                .collapsed_dirs = .{},
                .bytes = 0,
                .lines = 0,
            }),
        } },
        .repo_epoch = 4,
        .root_identity = identity,
    };
    defer legacy_app.clearLoadedDiff();
    try expectExactPathReady(
        legacy_app.reviewNavigation().exactPathTarget(exactReviewIntent(&legacy_app, "legacy")),
        1,
    );
}

test "review transition D1 exact lookup preserves reviewed and changed filters" {
    const identity: root_capability.Identity = .{ .device = 3, .inode = 5 };
    {
        var reviewed = [_]bool{ true, false };
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
                .review_display = .{ .hide_reviewed_files = true },
            } },
            .repo_epoch = 4,
            .root_identity = identity,
        };
        defer app.clearLoadedDiff();

        try expectExactPathUnavailable(
            app.reviewNavigation().exactPathTarget(exactReviewIntent(&app, "src/a")),
            .hidden_by_filters,
        );
        try expectExactPathReady(
            app.reviewNavigation().exactPathTarget(exactReviewIntent(&app, "src/b")),
            2,
        );
        try std.testing.expect(app.pages.review.review_display.hide_reviewed_files);
    }

    {
        var app: TestHarness = .{
            .pages = .{ .review = .{
                .load = app_test_support.loadState(app_test_support.loadedDiffTwoWithStatuses()),
                .review_display = .{ .changed_file_filter = .added },
            } },
            .repo_epoch = 4,
            .root_identity = identity,
        };
        defer app.clearLoadedDiff();

        try expectExactPathUnavailable(
            app.reviewNavigation().exactPathTarget(exactReviewIntent(&app, "src/deleted.zig")),
            .hidden_by_filters,
        );
        try expectExactPathReady(
            app.reviewNavigation().exactPathTarget(exactReviewIntent(&app, "src/added.zig")),
            0,
        );
        try std.testing.expectEqual(ChangedFileFilter.added, app.pages.review.review_display.changed_file_filter);
    }
}

test "review transition D1 exact lookup rejects identity absence and non-file paths" {
    const identity: root_capability.Identity = .{ .device = 3, .inode = 5 };
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffNested()),
            .viewer = .{ .selected_node = 1, .selected_file = 0 },
        } },
        .repo_epoch = 4,
        .root_identity = identity,
    };
    defer app.clearLoadedDiff();

    var wrong_epoch = exactReviewIntent(&app, "src/b");
    wrong_epoch.repo_epoch += 1;
    try expectExactPathUnavailable(app.reviewNavigation().exactPathTarget(wrong_epoch), .repository_mismatch);

    var wrong_root = exactReviewIntent(&app, "src/b");
    wrong_root.root_identity.inode += 1;
    try expectExactPathUnavailable(app.reviewNavigation().exactPathTarget(wrong_root), .repository_mismatch);
    try expectExactPathUnavailable(
        app.reviewNavigation().exactPathTarget(exactReviewIntent(&app, "missing.zig")),
        .path_not_found,
    );
    try expectExactPathUnavailable(
        app.reviewNavigation().exactPathTarget(exactReviewIntent(&app, "src")),
        .path_not_found,
    );
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_node);

    app.clearLoadedDiff();
    try expectExactPathUnavailable(
        app.reviewNavigation().exactPathTarget(exactReviewIntent(&app, "src/b")),
        .no_accepted_review,
    );

    app.root_identity = null;
    const explicit_intent: page_link.ReviewLocationIntent = .{
        .repo_epoch = app.repo_epoch,
        .root_identity = identity,
        .path = "src/b",
    };
    try expectExactPathUnavailable(app.reviewNavigation().exactPathTarget(explicit_intent), .repository_mismatch);
}

test "review transition D2b exact reveal expands only target ancestors and selects normally" {
    const identity: root_capability.Identity = .{ .device = 3, .inode = 5 };
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), .{
                .text = "",
                .document = .{ .files = &app_test_support.files_two },
                .file_text_eligibility = &.{ .selectable_utf8, .selectable_utf8 },
                .tree = .{ .nodes = &app_test_support.tree_non_contiguous_nodes },
                .collapsed_dirs = .{},
                .bytes = 0,
                .lines = 0,
            }),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_file = 0,
                .selected_node = 3,
                .focus = .diff,
                .diff_scroll = 8,
                .diff_horizontal_scroll = 3,
                .sidebar_horizontal_scroll = 2,
                .diff_cursor = .{ .hunk_header = 0 },
                .display_mode = .unified,
            },
            .selection_owner = .{ .diff_header = .{ .identity = .{
                .kind = .loaded_file,
                .path_key = "src/a",
            } } },
        } },
        .repo_epoch = 4,
        .root_identity = identity,
    };
    defer app.clearLoadedDiff();
    const allocator = app.reviewNavigation().loadArenaAllocator().?;
    const loaded = app.reviewNavigation().loadedDiff().?;
    try file_tree.collapse(allocator, &loaded.collapsed_dirs, "src");
    try file_tree.collapse(allocator, &loaded.collapsed_dirs, "lib");
    setDiffSearchQuery(&app, "target");

    try expectExactPathRevealSelected(
        try app.reviewNavigation().revealExactPath(exactReviewIntent(&app, "src/b")),
        4,
    );

    try std.testing.expect(!file_tree.isCollapsed(&loaded.collapsed_dirs, "src"));
    try std.testing.expect(file_tree.isCollapsed(&loaded.collapsed_dirs, "lib"));
    try std.testing.expectEqual(@as(?usize, 4), loaded.visibleNodeAt(3));
    try std.testing.expectEqual(@as(usize, 4), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_file);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.review.viewer.selected_target.?);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.diff_scroll);
    try std.testing.expectEqual(@as(usize, 3), app.pages.review.viewer.diff_horizontal_scroll);
    try std.testing.expectEqual(@as(usize, 2), app.pages.review.viewer.sidebar_horizontal_scroll);
    try std.testing.expectEqual(review_page.Focus.diff, app.pages.review.viewer.focus);
    try std.testing.expectEqual(diff_render.DisplayMode.unified, app.pages.review.viewer.display_mode);
    try std.testing.expectEqualStrings("target", app.pages.review.search.query.slice());
    try std.testing.expect(app.pages.review.selection_owner == .none);
}

test "review transition D2b exact reveal selects status-only and reports unchanged" {
    const identity: root_capability.Identity = .{ .device = 3, .inode = 5 };
    const nodes = [_]file_tree.Node{
        .{ .kind = .file, .name = "a", .path = "a", .depth = 0, .target = .{ .diff_file = 0 } },
        .{ .kind = .file, .name = "new.zig", .path = "new.zig", .depth = 0, .target = .{ .status_entry = 0 }, .status = .added },
    };
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(.{
                .text = "",
                .document = .{ .files = &app_test_support.files_one },
                .file_text_eligibility = &.{.selectable_utf8},
                .tree = .{ .nodes = &nodes },
                .collapsed_dirs = .{},
                .bytes = 0,
                .lines = 0,
            }),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_file = 0,
                .selected_node = 0,
                .display_mode = .unified,
            },
        } },
        .repo_epoch = 4,
        .root_identity = identity,
    };
    defer app.clearLoadedDiff();
    defer app.pages.review.git_status.deinit();
    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? new.zig\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);

    try expectExactPathRevealSelected(
        try app.reviewNavigation().revealExactPath(exactReviewIntent(&app, "new.zig")),
        1,
    );
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .status_only = 0 }, app.pages.review.viewer.selected_target.?);
    try std.testing.expectEqual(diff_render.DisplayMode.unified, app.pages.review.viewer.display_mode);

    app.pages.review.viewer.diff_scroll = 9;
    try expectExactPathRevealUnchanged(
        try app.reviewNavigation().revealExactPath(exactReviewIntent(&app, "new.zig")),
        1,
    );
    try std.testing.expectEqual(@as(usize, 9), app.pages.review.viewer.diff_scroll);
    try std.testing.expectEqual(context.SelectedTarget{ .status_only = 0 }, app.pages.review.viewer.selected_target.?);
}

test "review transition D2b selected exact node still reveals collapsed ancestor" {
    const identity: root_capability.Identity = .{ .device = 3, .inode = 5 };
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), app_test_support.loadedDiffNested()),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_file = 1,
                .selected_node = 2,
            },
        } },
        .repo_epoch = 4,
        .root_identity = identity,
    };
    defer app.clearLoadedDiff();
    const loaded = app.reviewNavigation().loadedDiff().?;
    try file_tree.collapse(app.reviewNavigation().loadArenaAllocator().?, &loaded.collapsed_dirs, "src");
    try std.testing.expectEqual(@as(?usize, null), loaded.visibleRowOfNode(2));

    try expectExactPathRevealSelected(
        try app.reviewNavigation().revealExactPath(exactReviewIntent(&app, "src/b")),
        2,
    );

    try std.testing.expect(!file_tree.isCollapsed(&loaded.collapsed_dirs, "src"));
    try std.testing.expectEqual(@as(?usize, 2), loaded.visibleRowOfNode(2));
    try std.testing.expectEqual(@as(usize, 2), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.review.viewer.selected_target.?);
}

test "review transition expands typed repository root before exact reveal" {
    const identity: root_capability.Identity = .{ .device = 3, .inode = 5 };
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), app_test_support.loadedDiffRootedNested()),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_file = 1,
                .selected_node = 0,
                .root_disclosure = .collapsed,
            },
        } },
        .repo_epoch = 4,
        .root_identity = identity,
    };
    defer app.clearLoadedDiff();
    const loaded = app.reviewNavigation().loadedDiff().?;
    const allocator = app.reviewNavigation().loadArenaAllocator().?;
    try file_tree.collapse(allocator, &loaded.collapsed_dirs, "src");
    try loaded.rebuildVisibleNodes(allocator, .collapsed, false, .all);
    try std.testing.expectEqual(@as(?usize, null), loaded.visibleRowOfNode(3));

    try expectExactPathRevealSelected(
        try app.reviewNavigation().revealExactPath(exactReviewIntent(&app, "src/b")),
        3,
    );

    try std.testing.expectEqual(file_tree.RootDisclosure.expanded, app.pages.review.viewer.root_disclosure);
    try std.testing.expectEqual(file_tree.RootDisclosure.expanded, loaded.root_disclosure);
    try std.testing.expect(!file_tree.isCollapsed(&loaded.collapsed_dirs, "src"));
    try std.testing.expectEqual(@as(?usize, 3), loaded.visibleRowOfNode(3));
    try std.testing.expectEqual(@as(usize, 3), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.review.viewer.selected_target.?);
}

test "review transition D2b unavailable result preserves navigation folds and filters" {
    const identity: root_capability.Identity = .{ .device = 3, .inode = 5 };
    var reviewed = [_]bool{ true, false };
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
                .selected_target = .{ .diff_file = 1 },
                .selected_file = 1,
                .selected_node = 2,
                .diff_scroll = 6,
                .diff_horizontal_scroll = 2,
                .diff_cursor = .{ .metadata = 1 },
            },
            .review_display = .{ .hide_reviewed_files = true },
        } },
        .repo_epoch = 4,
        .root_identity = identity,
    };
    defer app.clearLoadedDiff();
    const loaded = app.reviewNavigation().loadedDiff().?;
    try file_tree.collapse(app.reviewNavigation().loadArenaAllocator().?, &loaded.collapsed_dirs, "src");

    try expectExactPathRevealUnavailable(
        try app.reviewNavigation().revealExactPath(exactReviewIntent(&app, "src/a")),
        .hidden_by_filters,
    );
    try std.testing.expect(file_tree.isCollapsed(&loaded.collapsed_dirs, "src"));
    try std.testing.expect(app.pages.review.review_display.hide_reviewed_files);
    try std.testing.expectEqual(@as(usize, 2), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.review.viewer.selected_target.?);
    try std.testing.expectEqual(@as(usize, 6), app.pages.review.viewer.diff_scroll);
    try std.testing.expectEqual(@as(usize, 2), app.pages.review.viewer.diff_horizontal_scroll);
    try std.testing.expect(std.meta.eql(
        diff_view_model.BodyCoordinate{ .metadata = 1 },
        app.pages.review.viewer.diff_cursor,
    ));
}

test "review transition D2b allocation failure rolls back before ancestor expansion" {
    const identity: root_capability.Identity = .{ .device = 3, .inode = 5 };
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffNested()),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_file = 0,
                .selected_node = 1,
                .focus = .diff,
                .diff_scroll = 7,
                .diff_horizontal_scroll = 4,
                .sidebar_horizontal_scroll = 3,
                .diff_cursor = .{ .hunk_header = 0 },
                .display_mode = .unified,
            },
            .review_display = .{ .changed_file_filter = .all },
            .selection_owner = .{ .diff_header = .{ .identity = .{
                .kind = .loaded_file,
                .path_key = "src/a",
            } } },
        } },
        .repo_epoch = 4,
        .root_identity = identity,
    };
    defer app.clearLoadedDiff();
    const loaded = app.reviewNavigation().loadedDiff().?;
    try file_tree.collapse(app.reviewNavigation().loadArenaAllocator().?, &loaded.collapsed_dirs, "src");
    const visible_before = loaded.visibleNodeCount();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });

    try std.testing.expectError(
        error.OutOfMemory,
        app.reviewNavigation().revealExactPathWithAllocator(
            exactReviewIntent(&app, "src/b"),
            failing.allocator(),
        ),
    );

    try std.testing.expect(file_tree.isCollapsed(&loaded.collapsed_dirs, "src"));
    try std.testing.expectEqual(visible_before, loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, app.pages.review.viewer.selected_target.?);
    try std.testing.expectEqual(@as(usize, 7), app.pages.review.viewer.diff_scroll);
    try std.testing.expectEqual(@as(usize, 4), app.pages.review.viewer.diff_horizontal_scroll);
    try std.testing.expectEqual(@as(usize, 3), app.pages.review.viewer.sidebar_horizontal_scroll);
    try std.testing.expectEqual(review_page.Focus.diff, app.pages.review.viewer.focus);
    try std.testing.expectEqual(diff_render.DisplayMode.unified, app.pages.review.viewer.display_mode);
    try std.testing.expect(app.pages.review.selection_owner.activeHeader() != null);
}

test "file search keeps prompt open on no match" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(fileSearchLoadedNested()),
            .file_search = .{ .mode = true },
        } },
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    setAndRebuildFileSearch(&app, "missing");

    defer app.pages.review.file_search.deinit(std.testing.allocator);

    app.reviewNavigation().submitFileSearch(std.testing.allocator);

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
                .tree = .{ .nodes = &file_search_nested_nodes },
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
    try app.reviewNavigation().loadedDiff().?.rebuildVisibleNodes(
        app.reviewNavigation().loadArenaAllocator().?,
        app.pages.review.viewer.root_disclosure,
        true,
        .all,
    );
    setAndRebuildFileSearch(&app, "src");

    app.reviewNavigation().submitFileSearch(std.testing.allocator);

    try std.testing.expect(!app.pages.review.file_search.mode);
    try std.testing.expect(!app.pages.review.file_search.no_match);
    try std.testing.expectEqual(@as(usize, 2), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_file);
    try std.testing.expectEqual(review_page.Focus.diff, app.pages.review.viewer.focus);
}

test "file search empty Enter accepts the first exact candidate" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(fileSearchLoadedNested()),
            .viewer = .{ .focus = .diff },
        } },
        .terminal_size = .{ .width = 100, .height = 12 },
    };

    app.reviewNavigation().enterFileSearchMode(std.testing.allocator);
    try std.testing.expectEqual(review_page.Focus.sidebar, app.pages.review.viewer.focus);
    setAndRebuildFileSearch(&app, "   ");

    app.reviewNavigation().submitFileSearch(std.testing.allocator);

    try std.testing.expect(!app.pages.review.file_search.mode);
    try std.testing.expectEqual(review_page.Focus.diff, app.pages.review.viewer.focus);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.selected_file);
}

test "file search Enter commits the displayed moved candidate" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(fileSearchLoadedNested()),
            .viewer = .{ .selected_target = .{ .diff_file = 0 }, .selected_file = 0, .selected_node = 1, .focus = .diff },
        } },
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer app.clearLoadedDiff();

    app.reviewNavigation().enterFileSearchMode(std.testing.allocator);
    app.pages.review.file_search.move(1);
    try std.testing.expectEqualStrings("src/b", app.pages.review.file_search.focusedCandidate().?.path_key);

    app.reviewNavigation().submitFileSearch(std.testing.allocator);

    try std.testing.expect(!app.pages.review.file_search.mode);
    try std.testing.expectEqual(@as(usize, 2), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_file);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.review.viewer.selected_target.?);
    try std.testing.expectEqual(review_page.Focus.diff, app.pages.review.viewer.focus);
}

test "file search Enter keeps unavailable and stale projections inert" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(fileSearchLoadedNested()),
            .viewer = .{ .selected_target = .{ .diff_file = 0 }, .selected_file = 0, .selected_node = 1 },
            .file_search = .{ .mode = true },
        } },
    };
    defer app.clearLoadedDiff();

    app.reviewNavigation().submitFileSearch(std.testing.allocator);
    try std.testing.expect(app.pages.review.file_search.mode);
    try std.testing.expect(!app.pages.review.file_search.projection_available);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_node);

    app.reviewNavigation().rebuildFileSearchProjection(std.testing.allocator);
    try std.testing.expect(app.pages.review.file_search.projection_available);
    app.pages.review.accepted_sidebar_revision += 1;

    app.reviewNavigation().submitFileSearch(std.testing.allocator);

    try std.testing.expect(app.pages.review.file_search.mode);
    try std.testing.expect(!app.pages.review.file_search.projection_available);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.file_search.candidates.len);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, app.pages.review.viewer.selected_target.?);
    try std.testing.expectEqual(review_page.Focus.sidebar, app.pages.review.viewer.focus);
}

test "file search disclosure allocation failure preserves prompt folds and selection" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), fileSearchLoadedNested()),
            .viewer = .{ .selected_target = .{ .diff_file = 0 }, .selected_file = 0, .selected_node = 1 },
            .file_search = .{ .mode = true },
        } },
    };
    defer app.clearLoadedDiff();
    defer app.pages.review.file_search.deinit(std.testing.allocator);

    const loaded = app.reviewNavigation().loadedDiff().?;
    try file_tree.collapse(app.reviewNavigation().loadArenaAllocator().?, &loaded.collapsed_dirs, "src");
    setAndRebuildFileSearch(&app, "src/b");
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });

    app.reviewNavigation().submitFileSearchWithVisibleAllocator(std.testing.allocator, failing.allocator());

    try std.testing.expect(app.pages.review.file_search.mode);
    try std.testing.expect(app.pages.review.file_search.projection_available);
    try std.testing.expectEqualStrings("src/b", app.pages.review.file_search.focusedCandidate().?.path_key);
    try std.testing.expect(file_tree.isCollapsed(&loaded.collapsed_dirs, "src"));
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, app.pages.review.viewer.selected_target.?);
    try std.testing.expectEqual(review_page.Focus.sidebar, app.pages.review.viewer.focus);
    try std.testing.expectEqualStrings("Could not reveal file search result", app.status.text());
}

test "file search Enter commits an exact status-only candidate" {
    const nodes = [_]file_tree.Node{
        .{ .kind = .file, .name = "a", .path = "a", .path_key = "a", .depth = 0, .target = .{ .diff_file = 0 } },
        .{ .kind = .file, .name = "new.zig", .path = "new.zig", .path_key = "new.zig", .depth = 0, .target = .{ .status_entry = 0 }, .status = .added },
    };
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(.{
                .text = "",
                .document = .{ .files = &app_test_support.files_one },
                .file_text_eligibility = &.{.selectable_utf8},
                .tree = .{ .nodes = &nodes },
                .bytes = 0,
                .lines = 0,
            }),
            .viewer = .{ .selected_target = .{ .diff_file = 0 } },
            .file_search = .{ .mode = true },
        } },
        .repo_root = "/repo",
    };
    defer app.clearLoadedDiff();
    defer app.pages.review.git_status.deinit();
    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? new.zig\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);
    setAndRebuildFileSearch(&app, "new.zig");

    app.reviewNavigation().submitFileSearch(std.testing.allocator);

    try std.testing.expect(!app.pages.review.file_search.mode);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .status_only = 0 }, app.pages.review.viewer.selected_target.?);
    try std.testing.expectEqual(review_page.Focus.diff, app.pages.review.viewer.focus);
}

test "file search keeps diff focus while sidebar is hidden" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), fileSearchLoadedNested()),
            .viewer = .{ .focus = .diff, .sidebar_hidden = true },
        } },
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer app.clearLoadedDiff();

    app.reviewNavigation().enterFileSearchMode(std.testing.allocator);
    try std.testing.expectEqual(review_page.Focus.diff, app.pages.review.viewer.focus);
    setAndRebuildFileSearch(&app, "   ");

    app.reviewNavigation().submitFileSearch(std.testing.allocator);

    try std.testing.expect(!app.pages.review.file_search.mode);
    try std.testing.expectEqual(review_page.Focus.diff, app.pages.review.viewer.focus);

    app.reviewNavigation().enterFileSearchMode(std.testing.allocator);
    setAndRebuildFileSearch(&app, "src/b");

    app.reviewNavigation().submitFileSearch(std.testing.allocator);

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

test "retained cached projection keeps all-staged authority on diff-file route" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .status_load = .{ .generation = 3, .pending = .{ .generation = 3 } },
            .viewer = .{ .selected_target = .{ .diff_file = 0 }, .diff_cursor = .{ .hunk_header = 0 } },
        } },
        .terminal_size = .{ .width = 100, .height = 40 },
        .source = .unstaged,
        .repo_root = "/repo",
    };
    defer app.pages.review.review_projection.deinit(std.testing.allocator);
    defer app.pages.review.staged_hunks.deinit(std.testing.allocator);

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

    try std.testing.expect(app.reviewNavigationView().displayedReviewBody() == .cached);
    const without_marks = (try app.reviewNavigationView().activeDiffDisplay(arena.allocator(), .unified)) orelse return error.ExpectedCachedDisplay;
    try std.testing.expect(without_marks.hunkStagePresentation() == .all_staged);

    try app.pages.review.staged_hunks.add(std.testing.allocator, "/repo", "a", 0);
    const with_marks = (try app.reviewNavigationView().activeDiffDisplay(arena.allocator(), .unified)) orelse return error.ExpectedCachedDisplay;
    try std.testing.expect(with_marks.hunkStagePresentation() == .all_staged);
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

test "hunk stage presentation classifies direct source authority" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
        } },
        .allocator = std.testing.allocator,
        .repo_root = "/repo",
    };

    const unstaged = try app.reviewNavigationView().hunkStagePresentationForFile(std.testing.allocator, app_test_support.file_with_hunks);
    try std.testing.expect(unstaged == .all_unstaged);

    app.source = .cached;
    const cached = try app.reviewNavigationView().hunkStagePresentationForFile(std.testing.allocator, app_test_support.file_with_hunks);
    try std.testing.expect(cached == .all_staged);

    app.source = .{ .range = "HEAD~1..HEAD" };
    const historical = try app.reviewNavigationView().hunkStagePresentationForFile(std.testing.allocator, app_test_support.file_with_hunks);
    try std.testing.expect(historical == .all_unstaged);
}

test "hunk stage presentation keeps partial session marks" {
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

    const presentation = try app.reviewNavigationView().hunkStagePresentationForFile(arena.allocator(), app_test_support.file_with_hunks);
    try std.testing.expect(presentation == .per_hunk);
    try std.testing.expectEqual(diff_render.HunkStageState.staged, presentation.stateForHunk(0));
    try std.testing.expectEqual(diff_render.HunkStageState.unstaged, presentation.stateForHunk(1));
}

test "hunk stage presentation uses all-staged only for fresh staged-only status" {
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

    var staged_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  a\x00");
    try app.pages.review.git_status.replace("/repo", &staged_bundle);
    const staged = try app.reviewNavigationView().hunkStagePresentationForFile(arena.allocator(), app_test_support.file_with_hunks);
    try std.testing.expect(staged == .all_staged);

    try app.pages.review.staged_hunks.add(std.testing.allocator, "/repo", "a", 0);
    try app.pages.review.staged_hunks.add(std.testing.allocator, "/repo", "a", 1);
    const hunk_by_hunk = try app.reviewNavigationView().hunkStagePresentationForFile(arena.allocator(), app_test_support.file_with_hunks);
    try std.testing.expect(hunk_by_hunk == .all_staged);

    var mixed_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "MM a\x00");
    try app.pages.review.git_status.replace("/repo", &mixed_bundle);
    const mixed = try app.reviewNavigationView().hunkStagePresentationForFile(arena.allocator(), app_test_support.file_with_hunks);
    try std.testing.expect(mixed == .per_hunk);
    try std.testing.expectEqual(diff_render.HunkStageState.staged, mixed.stateForHunk(0));
    try std.testing.expectEqual(diff_render.HunkStageState.staged, mixed.stateForHunk(1));

    app.pages.review.status_load.pending = .{ .generation = 1 };
    const stale = try app.reviewNavigationView().hunkStagePresentationForFile(arena.allocator(), app_test_support.file_with_hunks);
    try std.testing.expect(stale == .per_hunk);
    try std.testing.expectEqual(diff_render.HunkStageState.staged, stale.stateForHunk(0));
    try std.testing.expectEqual(diff_render.HunkStageState.staged, stale.stateForHunk(1));

    app.pages.review.status_load.pending = null;
    var other_repo_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  a\x00");
    try app.pages.review.git_status.replace("/other", &other_repo_bundle);
    const other_repo = try app.reviewNavigationView().hunkStagePresentationForFile(arena.allocator(), app_test_support.file_with_hunks);
    try std.testing.expect(other_repo == .per_hunk);
    try std.testing.expectEqual(diff_render.HunkStageState.staged, other_repo.stateForHunk(0));
    try std.testing.expectEqual(diff_render.HunkStageState.staged, other_repo.stateForHunk(1));
}

test "typed action cursor remaps a directory without changing the sticky diff target" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffNested()),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_node = 1,
            },
        } },
    };
    defer app.pages.review.action_cursor.deinit(std.testing.allocator);

    var prepared = try review_page.action_cursor.Prepared.init(
        std.testing.allocator,
        3,
        .{ .device = 5, .inode = 8 },
        .directory,
        "src",
        1,
    );
    app.pages.review.action_cursor.install(std.testing.allocator, &prepared, 7);
    const loaded = app.reviewNavigation().loadedDiff().?;

    try std.testing.expect(app.reviewNavigation().remapActionCursor(loaded));
    try std.testing.expect(app.pages.review.action_cursor.hasOwner());
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.review.viewer.selected_target.?);
}

test "typed action cursor remaps a repository root without changing the sticky diff target" {
    const nodes = [_]file_tree.Node{
        .{ .kind = .repo_root, .name = "repo", .path = "", .depth = 0, .target = .repo_root },
        .{ .kind = .file, .name = "main.zig", .path = "src/main.zig", .path_key = "src/main.zig", .depth = 1, .target = .{ .diff_file = 0 } },
    };
    var visible_nodes = [_]usize{ 0, 1 };
    const loaded: LoadedDiff = .{
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
            .load = app_test_support.loadState(loaded),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_node = 1,
            },
        } },
    };
    defer app.pages.review.action_cursor.deinit(std.testing.allocator);

    var prepared = try review_page.action_cursor.Prepared.init(
        std.testing.allocator,
        3,
        .{ .device = 5, .inode = 8 },
        .repository_root,
        "",
        1,
    );
    app.pages.review.action_cursor.install(std.testing.allocator, &prepared, 7);

    try std.testing.expect(app.reviewNavigation().remapActionCursor(app.reviewNavigation().loadedDiff().?));
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, app.pages.review.viewer.selected_target.?);
}

test "terminal directory action cursor reveals exact target under collapsed repository root" {
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), app_test_support.loadedDiffRootedNested()),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_file = 1,
                .selected_node = 0,
            },
        } },
    };
    defer app.clearLoadedDiff();
    defer app.pages.review.action_cursor.deinit(std.testing.allocator);

    try app.reviewNavigation().toggleSelectedDirectory();
    const loaded = app.reviewNavigation().loadedDiff().?;
    try std.testing.expectEqual(file_tree.RootDisclosure.collapsed, loaded.root_disclosure);

    var prepared = try review_page.action_cursor.Prepared.init(
        std.testing.allocator,
        3,
        .{ .device = 5, .inode = 8 },
        .directory,
        "src",
        0,
    );
    app.pages.review.action_cursor.install(std.testing.allocator, &prepared, 7);
    try std.testing.expect(app.pages.review.action_cursor.promote(7, 3, .{ .device = 5, .inode = 8 }, .source_and_status));
    try std.testing.expect(app.pages.review.action_cursor.startMember(7, .source, 11));
    try std.testing.expect(app.pages.review.action_cursor.startMember(7, .status, 12));
    try std.testing.expect(app.pages.review.action_cursor.finishMember(7, 3, .status, 12, true));
    try std.testing.expect(app.pages.review.action_cursor.finishMember(7, 3, .source, 11, true));

    try std.testing.expect(app.reviewNavigation().finalizeActionCursor(std.testing.allocator));
    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
    try std.testing.expectEqual(file_tree.RootDisclosure.expanded, loaded.root_disclosure);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.review.viewer.selected_target.?);
}

test "filtered directory action cursor falls back to repository root instead of another file" {
    const nodes = [_]file_tree.Node{
        .{ .kind = .repo_root, .name = "repo", .path = "", .depth = 0, .target = .repo_root },
        .{ .kind = .directory, .name = "src", .path = "src", .depth = 1 },
        .{ .kind = .file, .name = "a", .path = "src/a", .depth = 2, .target = .{ .diff_file = 0 }, .status = .modified },
        .{ .kind = .directory, .name = "lib", .path = "lib", .depth = 1 },
        .{ .kind = .file, .name = "b", .path = "lib/b", .depth = 2, .target = .{ .diff_file = 1 }, .status = .added },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var loaded = app_test_support.loadedDiffTwo();
    loaded.tree = .{ .nodes = &nodes };
    try loaded.rebuildVisibleNodes(arena.allocator(), .expanded, false, .added);
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(arena, loaded),
            .review_display = .{ .changed_file_filter = .added },
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_file = 0,
                .selected_node = 0,
            },
        } },
    };
    defer app.clearLoadedDiff();
    defer app.pages.review.action_cursor.deinit(std.testing.allocator);

    var prepared = try review_page.action_cursor.Prepared.init(
        std.testing.allocator,
        3,
        .{ .device = 5, .inode = 8 },
        .directory,
        "src",
        0,
    );
    app.pages.review.action_cursor.install(std.testing.allocator, &prepared, 7);
    try std.testing.expect(app.pages.review.action_cursor.promote(7, 3, .{ .device = 5, .inode = 8 }, .source_and_status));
    try std.testing.expect(app.pages.review.action_cursor.failMemberBeforeStart(7, .source));
    try std.testing.expect(app.pages.review.action_cursor.failMemberBeforeStart(7, .status));

    try std.testing.expect(app.reviewNavigation().finalizeActionCursor(std.testing.allocator));
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(file_tree.Node.Kind.repo_root, app.reviewNavigation().loadedDiff().?.tree.nodes[0].kind);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, app.pages.review.viewer.selected_target.?);
}

test "disappeared file action cursor keeps the existing nearest-file fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var loaded = app_test_support.loadedDiffRootedNested();
    try loaded.rebuildVisibleNodes(arena.allocator(), .expanded, false, .all);
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(arena, loaded),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_file = 0,
                .selected_node = 2,
            },
        } },
    };
    defer app.clearLoadedDiff();
    defer app.pages.review.action_cursor.deinit(std.testing.allocator);

    var prepared = try review_page.action_cursor.Prepared.init(
        std.testing.allocator,
        3,
        .{ .device = 5, .inode = 8 },
        .file,
        "src/discarded.zig",
        3,
    );
    app.pages.review.action_cursor.install(std.testing.allocator, &prepared, 7);
    try std.testing.expect(app.pages.review.action_cursor.promote(7, 3, .{ .device = 5, .inode = 8 }, .source_and_status));
    try std.testing.expect(app.pages.review.action_cursor.failMemberBeforeStart(7, .source));
    try std.testing.expect(app.pages.review.action_cursor.failMemberBeforeStart(7, .status));

    try std.testing.expect(app.reviewNavigation().finalizeActionCursor(std.testing.allocator));
    try std.testing.expectEqual(@as(usize, 3), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.review.viewer.selected_target.?);
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

    try app.reviewNavigation().loadedDiff().?.rebuildVisibleNodes(
        app.reviewNavigation().loadArenaAllocator().?,
        app.pages.review.viewer.root_disclosure,
        false,
        app.pages.review.review_display.changed_file_filter,
    );

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

    try app.reviewNavigation().cycleChangedFileFilter(std.testing.allocator);

    const loaded = app.reviewNavigation().loadedDiff().?;
    try std.testing.expectEqual(ChangedFileFilter.modified, app.pages.review.review_display.changed_file_filter);
    try std.testing.expectEqual(@as(usize, 0), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_file);
}

test "file visibility lens replaces candidate basis and rebuilds retained query" {
    var reviewed = [_]bool{ true, false };
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(.{
                .text = "",
                .document = .{ .files = &app_test_support.files_two },
                .file_text_eligibility = &.{ .selectable_utf8, .selectable_utf8 },
                .tree = .{ .nodes = &file_search_lens_nodes },
                .reviewed_files = &reviewed,
                .collapsed_dirs = .{},
                .bytes = 0,
                .lines = 0,
            }),
            .file_search = .{ .mode = true },
        } },
    };
    defer app.clearLoadedDiff();
    defer app.pages.review.file_search.deinit(std.testing.allocator);
    setFileSearchInput(&app, "");
    app.reviewNavigation().rebuildFileSearchProjection(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), app.pages.review.file_search.candidates.len);

    try app.reviewNavigation().toggleHideReviewedFiles(std.testing.allocator);

    try std.testing.expect(app.pages.review.review_display.hide_reviewed_files);
    try std.testing.expectEqual(@as(u64, 2), app.pages.review.accepted_sidebar_revision);
    try std.testing.expect(app.pages.review.file_search.mode);
    try std.testing.expect(app.pages.review.file_search.projection_available);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.file_search.candidates.len);
    try std.testing.expectEqualStrings("b", app.pages.review.file_search.focusedCandidate().?.path_key);
    try std.testing.expectEqual(@as(u64, 2), app.pages.review.file_search.basis.?.accepted_sidebar_revision);

    try app.reviewNavigation().toggleHideReviewedFiles(std.testing.allocator);
    try app.reviewNavigation().cycleChangedFileFilter(std.testing.allocator);

    try std.testing.expect(!app.pages.review.review_display.hide_reviewed_files);
    try std.testing.expectEqual(ChangedFileFilter.modified, app.pages.review.review_display.changed_file_filter);
    try std.testing.expectEqual(@as(u64, 4), app.pages.review.accepted_sidebar_revision);
    try std.testing.expect(app.pages.review.file_search.projection_available);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.file_search.candidates.len);
    try std.testing.expectEqualStrings("a", app.pages.review.file_search.focusedCandidate().?.path_key);
    try std.testing.expectEqual(@as(u64, 4), app.pages.review.file_search.basis.?.accepted_sidebar_revision);
}

test "file visibility lens preparation failure preserves old lens and candidates" {
    var reviewed = [_]bool{ false, false };
    var partial_visible_nodes = [_]usize{0};
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(.{
                .text = "",
                .document = .{ .files = &app_test_support.files_two },
                .file_text_eligibility = &.{ .selectable_utf8, .selectable_utf8 },
                .tree = .{ .nodes = &file_search_lens_nodes },
                .reviewed_files = &reviewed,
                .visible_nodes = &partial_visible_nodes,
                .visible_node_count = 1,
                .collapsed_dirs = .{},
                .bytes = 0,
                .lines = 0,
            }),
            .file_search = .{ .mode = true },
        } },
    };
    defer app.clearLoadedDiff();
    defer app.pages.review.file_search.deinit(std.testing.allocator);
    app.reviewNavigation().rebuildFileSearchProjection(std.testing.allocator);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });

    try std.testing.expectError(
        error.OutOfMemory,
        app.reviewNavigation().replaceFileVisibilityLens(
            std.testing.allocator,
            failing.allocator(),
            true,
            .all,
        ),
    );

    try std.testing.expect(!app.pages.review.review_display.hide_reviewed_files);
    try std.testing.expectEqual(@as(u64, 1), app.pages.review.accepted_sidebar_revision);
    try std.testing.expect(app.pages.review.file_search.projection_available);
    try std.testing.expectEqual(@as(usize, 2), app.pages.review.file_search.candidates.len);
    try std.testing.expectEqual(@as(usize, 1), app.reviewNavigation().loadedDiff().?.visibleNodeCount());
}

test "candidate rebuild failure cannot reject committed file visibility lens" {
    var reviewed = [_]bool{ true, false };
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(.{
                .text = "",
                .document = .{ .files = &app_test_support.files_two },
                .file_text_eligibility = &.{ .selectable_utf8, .selectable_utf8 },
                .tree = .{ .nodes = &file_search_lens_nodes },
                .reviewed_files = &reviewed,
                .collapsed_dirs = .{},
                .bytes = 0,
                .lines = 0,
            }),
            .file_search = .{ .mode = true },
        } },
    };
    defer app.clearLoadedDiff();
    defer app.pages.review.file_search.deinit(std.testing.allocator);
    setFileSearchInput(&app, "b");
    app.reviewNavigation().rebuildFileSearchProjection(std.testing.allocator);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });

    try app.reviewNavigation().replaceFileVisibilityLens(
        failing.allocator(),
        app.reviewNavigation().loadArenaAllocator().?,
        true,
        .all,
    );

    try std.testing.expect(app.pages.review.review_display.hide_reviewed_files);
    try std.testing.expectEqual(@as(u64, 2), app.pages.review.accepted_sidebar_revision);
    try std.testing.expectEqual(@as(usize, 1), app.reviewNavigation().loadedDiff().?.visibleNodeCount());
    try std.testing.expect(app.pages.review.file_search.mode);
    try std.testing.expectEqualStrings("b", app.pages.review.file_search.input.slice());
    try std.testing.expect(!app.pages.review.file_search.projection_available);
    try std.testing.expect(app.pages.review.file_search.focusedCandidate() == null);
}

test "file search skips files outside active changed filter" {
    const nodes = [_]file_tree.Node{
        .{ .kind = .file, .name = "added.zig", .path = "src/added.zig", .path_key = "src/added.zig", .depth = 1, .target = .{ .diff_file = 0 }, .status = .added },
        .{ .kind = .file, .name = "deleted.zig", .path = "src/deleted.zig", .path_key = "src/deleted.zig", .depth = 1, .target = .{ .diff_file = 1 }, .status = .deleted },
    };
    var loaded = app_test_support.loadedDiffTwoWithStatuses();
    loaded.tree.nodes = &nodes;
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(loaded),
            .file_search = .{ .mode = true },
            .review_display = .{ .changed_file_filter = .added },
        } },
    };
    setAndRebuildFileSearch(&app, "deleted");
    defer app.pages.review.file_search.deinit(std.testing.allocator);

    app.reviewNavigation().submitFileSearch(std.testing.allocator);

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

    try app.reviewNavigation().toggleHideReviewedFiles(std.testing.allocator);

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

    try app.reviewNavigation().toggleHideReviewedFiles(std.testing.allocator);

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

    try app.reviewNavigation().toggleHideReviewedFiles(std.testing.allocator);

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
    try app.reviewNavigation().loadedDiff().?.rebuildVisibleNodes(
        app.reviewNavigation().loadArenaAllocator().?,
        app.pages.review.viewer.root_disclosure,
        true,
        .all,
    );

    try app.reviewNavigation().toggleReviewedFile(std.testing.allocator);

    const loaded = app.reviewNavigation().loadedDiff().?;
    try std.testing.expectEqualSlices(bool, &.{ true, false }, &reviewed);
    try std.testing.expectEqual(@as(usize, 2), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(?usize, 0), loaded.visibleNodeAt(0));
    try std.testing.expectEqual(@as(?usize, 2), loaded.visibleNodeAt(1));
    try std.testing.expectEqual(@as(usize, 2), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_file);
}

test "marking reviewed under hidden lens rebuilds file search eligibility" {
    var reviewed = [_]bool{ false, false };
    var app: TestHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), .{
                .text = "",
                .document = .{ .files = &app_test_support.files_two },
                .file_text_eligibility = &.{ .selectable_utf8, .selectable_utf8 },
                .tree = .{ .nodes = &file_search_lens_nodes },
                .reviewed_files = &reviewed,
                .collapsed_dirs = .{},
                .bytes = 0,
                .lines = 0,
            }),
            .viewer = .{
                .selected_node = 0,
                .selected_target = .{ .diff_file = 0 },
                .selected_file = 0,
            },
            .file_search = .{ .mode = true },
            .review_display = .{ .hide_reviewed_files = true },
        } },
    };
    defer app.clearLoadedDiff();
    defer app.pages.review.reviewed_store.deinit(std.testing.allocator);
    defer app.pages.review.file_search.deinit(std.testing.allocator);
    try app.reviewNavigation().loadedDiff().?.rebuildVisibleNodes(
        app.reviewNavigation().loadArenaAllocator().?,
        app.pages.review.viewer.root_disclosure,
        true,
        .all,
    );
    app.reviewNavigation().rebuildFileSearchProjection(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), app.pages.review.file_search.candidates.len);

    try app.reviewNavigation().toggleReviewedFile(std.testing.allocator);

    try std.testing.expectEqualSlices(bool, &.{ true, false }, &reviewed);
    try std.testing.expectEqual(@as(u64, 2), app.pages.review.accepted_sidebar_revision);
    try std.testing.expect(app.pages.review.file_search.projection_available);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.file_search.candidates.len);
    try std.testing.expectEqualStrings("b", app.pages.review.file_search.focusedCandidate().?.path_key);
    try std.testing.expectEqual(@as(u64, 2), app.pages.review.file_search.basis.?.accepted_sidebar_revision);
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
