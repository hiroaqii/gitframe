//! Page-independent diff navigation model helpers.
//!
//! Pages retain their public `View` / `Controller` shapes and delegate these
//! pure operations through compatibility adapters. This module must not import
//! a page namespace.

const std = @import("std");
const layout = @import("layout.zig");
const diff_surface = @import("../diff_surface.zig");
const drag_auto_scroll = @import("../drag_auto_scroll.zig");
const app_direction = @import("../direction.zig");
const cursor_viewport = @import("../cursor_viewport.zig");
const file_search = diff_surface.file_search;
const context = @import("../../context.zig");
const diff_file = @import("../../diff/file.zig");
const diff_hunk_projection = @import("../../diff/hunk_projection.zig");
const diff_parser = @import("../../diff/parser.zig");
const diff_render = @import("../../diff/render.zig");
const diff_search = @import("../../diff/search.zig");
const diff_selection = @import("../../diff/selection.zig");
const diff_view_model = @import("../../diff/view_model.zig");
const file_tree = @import("../../file_tree.zig");
const loaded_diff = @import("../../loaded_diff.zig");
const sidebar_view_model = @import("../../sidebar/view_model.zig");
const text_projection = @import("chasen_ui").text_projection;
const selection_action = @import("selection_action.zig");

const LoadedDiff = loaded_diff.LoadedDiff;
const HorizontalDirection = app_direction.Horizontal;
const SizeDirection = app_direction.Size;
const VerticalDirection = app_direction.Vertical;
const review_tab_width: usize = 4;

pub const ParsedSelectionTarget = diff_surface.body_resolver.ParsedSelectionTarget;

pub fn resolvedTargetAllowsHunkFold(target: diff_surface.ResolvedTarget) bool {
    return target.hunk_interaction == .available and
        target.folded_hunks_source == .underlying_load;
}

pub const SelectionRegion = struct {
    side: diff_selection.Side,
    mode: diff_selection.Mode,
    text_cell: usize,
    leading_boundary: bool = false,
};

pub const ParsedMouseLine = struct {
    hunk_index: usize,
    line_index: usize,
    line: diff_parser.DiffLine,
    /// Side/character geometry exists only in side-by-side presentation.
    region: ?SelectionRegion,
};

/// One cell in the painted diff-body presentation. Source and full-width card
/// columns are relative to the diff surface after the search-marker gutter;
/// pane card columns are relative to the exact pane child passed to its
/// painter. Page adapters may interpret tokens, but shared diff geometry stays
/// authoritative.
pub const PresentationCellHit = union(enum) {
    source: struct { source_offset: usize, local_col: u16 },
    card: struct { token: usize, local_row: usize, local_col: u16 },
    spacer: struct { local_col: u16 },
};

pub const KeyboardLineHit = struct {
    source_offset: usize,
    hit: diff_surface.DiffMouseHit,
};

pub const KeyboardLineStart = union(enum) {
    unavailable,
    direct: diff_surface.DiffMouseHit,
    choose: diff_selection.KeyboardSideChoice,
};

pub const BeginKeyboardLineSelectionTerminal = enum {
    started,
    choosing_side,
    unavailable,
};

const KeyboardSideCandidate = struct {
    point: diff_selection.Point,
    text: []const u8,
};

const KeyboardSideCandidates = struct {
    identity: diff_selection.Identity,
    before: ?KeyboardSideCandidate,
    after: ?KeyboardSideCandidate,
};

pub const SelectionActionHit = struct {
    target: ?selection_action.StatusAction,
};

pub const ResidualSelectionOwner = struct {
    ctx: *anyopaque,
    callback: *const fn (ctx: *anyopaque) void,

    pub fn clear(self: ResidualSelectionOwner) void {
        self.callback(self.ctx);
    }
};

/// Allocator-bound transaction used by every in-place change to the source-row
/// mapping. The viewport is captured while the old mapping is still live; all
/// selection owners are retired before mutation; completion advances exactly
/// one layout revision and restores the semantic viewport in the new mapping.
pub const SelectionMappingCleanup = struct {
    allocator: std.mem.Allocator,
    residual_owner: ?ResidualSelectionOwner = null,

    pub const Prepared = struct {
        viewport: ?selection_action.SelectionViewportAnchor,
    };

    pub fn prepare(self: SelectionMappingCleanup, body: BodyController) Prepared {
        const viewport = body.captureSelectionViewportAnchor();
        body.controller.clearDiffSelection();
        if (body.controller.surface.completed_selection.*) |*completed| {
            completed.deinit(self.allocator);
            body.controller.surface.completed_selection.* = null;
        }
        if (self.residual_owner) |owner| owner.clear();
        return .{ .viewport = viewport };
    }

    pub fn complete(_: SelectionMappingCleanup, body: BodyController, prepared: Prepared) void {
        body.controller.advanceSelectionLayoutRevision();
        if (prepared.viewport) |anchor| body.restoreSelectionViewportAnchor(anchor);
    }
};

/// Short-lived read-only facade over one page's shared diff surface.
///
/// The pointer bundle remains owned by the page and is rebuilt for every
/// delegated call. Methods in this view must not mutate the pointed-to state.
pub const View = struct {
    surface: diff_surface.ReadSurface,
    repo_root: ?[]const u8,
    mode_toggle_hint_width: u16 = 0,
    presentation_rows: ?*const diff_render.PresentationRows = null,

    pub fn displayNavigationSnapshot(self: View) diff_surface.DisplayNavigationSnapshot {
        return .{
            .selected_target = self.surface.viewer.selected_target,
            .selected_node = self.surface.viewer.selected_node,
            .diff_cursor = self.surface.viewer.diff_cursor,
            .diff_scroll = self.surface.viewer.diff_scroll,
            .diff_horizontal_scroll = self.surface.viewer.diff_horizontal_scroll,
            .sidebar_horizontal_scroll = self.surface.viewer.sidebar_horizontal_scroll,
            .search_coordinate = if (self.surface.search.match) |match| match.coordinate else null,
            .search_match_offset = self.surface.search.match_offset,
            .display_mode = self.surface.viewer.display_mode,
        };
    }

    pub fn rawDiffPaneGeometry(self: View) ?diff_surface.RawDiffPaneGeometry {
        const size = self.surface.layout;
        if (size.width == 0) return null;
        if (self.surface.viewer.sidebar_hidden) return .{ .col = 0, .width = size.width };

        const sidebar_width = sidebarWidth(size.width, self.surface.viewer.sidebar_width);
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
        const width = sidebarWidth(self.surface.layout.width, self.surface.viewer.sidebar_width);
        const source = sidebar_view_model.Source{
            .tree = loaded.tree,
            .collapsed = &loaded.collapsed_dirs,
            .reviewed_files = loaded.reviewed_files,
            .visible_nodes = loaded.materializedVisibleNodes(),
        };

        var max_scroll: usize = 0;
        var visible_index: usize = 0;
        while (visible_index < loaded.visibleNodeCount()) : (visible_index += 1) {
            const row = sidebar_view_model.rowAt(source, visible_index, self.surface.viewer.selected_node) orelse continue;
            const row_max = sidebar_view_model.maxHorizontalScroll(row, width);
            max_scroll = @max(max_scroll, row_max);
        }
        return max_scroll;
    }

    pub fn currentSearchMatchInHunkBody(self: View, hunk_index: usize) bool {
        const match = self.surface.search.match orelse return false;
        return switch (match.coordinate) {
            .hunk_line => |line| line.hunk_index == hunk_index,
            else => false,
        };
    }

    pub fn selectedSidebarIdentity(self: View) ?context.SidebarIdentity {
        const loaded = self.activeLoadedDiffConst() orelse return null;
        if (self.surface.viewer.selected_node >= loaded.tree.nodes.len) return null;
        const node = loaded.tree.nodes[self.surface.viewer.selected_node];
        return switch (node.kind) {
            .repo_root => .repo_root,
            .directory => .{ .directory = node.path },
            .file => .{ .file = if (node.path_key.len > 0) node.path_key else node.path },
        };
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

    pub fn treeOrderScopeText(self: View, allocator: std.mem.Allocator) ![]u8 {
        const repo_root = self.repo_root orelse "";
        return switch (self.surface.source) {
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

    pub fn selectedFileCachedLineIndex(self: View, mode: diff_render.DisplayMode) ?diff_view_model.RenderedLineIndex {
        const loaded = self.activeLoadedDiffConst() orelse return null;
        const file_index = self.selectedFileIndex(loaded) orelse return null;
        return loaded.cachedRenderedLineIndex(file_index, mode);
    }

    pub fn rawSelectedHunkIndex(self: View) ?usize {
        return switch (self.surface.viewer.diff_cursor) {
            .hunk_header => |hunk_index| hunk_index,
            .hunk_line => |line| line.hunk_index,
            .metadata, .binary_marker => null,
        };
    }

    pub fn loadedFileCount(self: View) ?usize {
        const loaded = self.activeLoadedDiffConst() orelse return null;
        return loaded.document.files.len;
    }

    pub fn effectiveDisplayMode(self: View) diff_render.DisplayMode {
        return effectiveDisplayModeForLayout(self.surface.viewer, self.surface.layout);
    }

    pub fn diffVisibleRows(self: View) usize {
        return diff_render.visibleBodyRows(self.surface.layout.height);
    }

    pub fn diffPaneWidth(self: View) u16 {
        return diffPaneWidthForLayout(self.surface.viewer, self.surface.layout);
    }

    pub fn selectedFileIndex(self: View, loaded: *const LoadedDiff) ?usize {
        if (loaded.document.files.len == 0) return null;
        const file_index = self.selectedDiffFileTarget() orelse return null;
        return @min(file_index, loaded.document.files.len - 1);
    }

    pub fn selectedDiffFileTarget(self: View) ?usize {
        const target = self.surface.viewer.selected_target orelse return null;
        return target.diffFileIndex();
    }

    pub fn activeLoadedDiffConst(self: View) ?*const LoadedDiff {
        return switch (self.surface.load.state) {
            .loaded => |*session| &session.loaded,
            else => null,
        };
    }
};

/// Read-only diff view whose body-dependent operations require a resolver at
/// construction time. The resolver context is valid only for the synchronous
/// delegated call that owns this value.
pub const BodyView = struct {
    view: View,
    resolver: diff_surface.BodyResolver,

    pub fn parsedSelectionTarget(self: BodyView, expected: ?diff_selection.Identity) ?diff_surface.ParsedSelectionTarget {
        return self.resolver.parsedSelectionTarget(expected);
    }

    pub fn displayedDiffHeaderTarget(self: BodyView, expected: ?diff_selection.HeaderIdentity) ?diff_surface.DiffHeaderTarget {
        return self.resolver.displayedDiffHeaderTarget(expected);
    }

    pub fn displayedDiffFile(self: BodyView) ?diff_parser.FileDiff {
        return self.resolver.displayedDiffFile();
    }

    pub fn generatedBody(self: BodyView) ?diff_surface.GeneratedBody {
        return self.resolver.generatedBody();
    }

    pub fn displayedDiffLineIndex(self: BodyView, mode: diff_render.DisplayMode) ?diff_view_model.RenderedLineIndex {
        return self.resolver.displayedDiffLineIndex(mode);
    }

    pub fn resolvedTarget(self: BodyView) diff_surface.ResolvedTarget {
        return self.resolver.resolvedTarget();
    }

    pub fn currentContentToken(self: BodyView) ?diff_surface.ContentToken {
        return self.resolver.contentToken();
    }

    pub fn displayedSearchTarget(self: BodyView, mode: diff_render.DisplayMode) ?diff_surface.SearchTarget {
        return self.resolver.displayedSearchTarget(mode);
    }

    pub fn displayedDiffLineCount(self: BodyView) usize {
        return self.sourceDiffLineCount();
    }

    pub fn sourceDiffLineCount(self: BodyView) usize {
        return self.resolver.displayedDiffLineCount();
    }

    pub fn presentationDiffLineCount(self: BodyView) usize {
        const rows = self.view.presentation_rows orelse return self.sourceDiffLineCount();
        if (rows.source_rows != self.sourceDiffLineCount()) return self.sourceDiffLineCount();
        return rows.total_rows;
    }

    pub fn hunkStagePresentation(self: BodyView, allocator: std.mem.Allocator, file_index: usize) !diff_render.HunkStagePresentation {
        return self.resolver.hunkStagePresentation(allocator, file_index);
    }

    pub fn renderProjectedBody(self: BodyView, args: diff_surface.RenderProjectedBodyArgs) !void {
        return self.resolver.renderProjectedBody(args);
    }

    pub fn diffSelectionView(self: BodyView) ?diff_selection.View {
        if (self.view.surface.selection_owner.activeDiff()) |drag| {
            switch (drag.identity) {
                .generated_file => |generated| {
                    const body = self.generatedBody() orelse return null;
                    if (!std.mem.eql(u8, generated.path_key, body.path)) return null;
                },
                .loaded_file, .projection_file => _ = self.parsedSelectionTarget(drag.identity) orelse return null,
            }
            return drag.view();
        }
        return (self.retainedSelectionPresentation() orelse return null).view;
    }

    pub fn dragSelectionIdentityCurrent(self: BodyView, drag: diff_selection.DragSelection) bool {
        return switch (drag.identity) {
            .generated_file => |generated| blk: {
                const body = self.generatedBody() orelse break :blk false;
                break :blk std.mem.eql(u8, generated.path_key, body.path);
            },
            .loaded_file, .projection_file => self.parsedSelectionTarget(drag.identity) != null,
        };
    }

    pub fn retainedSelectionPresentation(self: BodyView) ?selection_action.Presentation {
        if (self.view.surface.selection_completion_policy != .retain_with_actions) return null;
        if (!self.view.surface.retained_selection_action_admitted) return null;
        const completed = self.view.surface.completed_selection.* orelse return null;
        const token = self.currentContentToken() orelse return null;
        if (!completed.token.eql(token)) return null;
        if (completed.selection_layout_revision != self.view.surface.selection_layout_revision.*) return null;

        return switch (completed.value) {
            .parsed_diff => |parsed| blk: {
                const target = self.parsedSelectionTarget(null) orelse break :blk null;
                const current_path = diff_file.canonicalPathKey(target.file) orelse break :blk null;
                if (!std.mem.eql(u8, parsed.canonical_path, current_path)) break :blk null;
                if (parsed.range.start.hunk_index >= target.file.hunks.len or parsed.range.end.hunk_index >= target.file.hunks.len) break :blk null;
                if (parsed.range.start.line_index >= target.file.hunks[parsed.range.start.hunk_index].lines.len or
                    parsed.range.end.line_index >= target.file.hunks[parsed.range.end.hunk_index].lines.len) break :blk null;

                break :blk switch (parsed.content) {
                    .source_side => |source| if (self.view.effectiveDisplayMode() != .side_by_side) null else .{
                        .view = .{
                            .identity = target.identity,
                            .content = .{ .source_side = .{ .side = source.side, .mode = source.mode } },
                            .start = parsed.range.start,
                            .end = parsed.range.end,
                        },
                        .line_count = source.fragments.line_count,
                    },
                    .unified_diff => |unified| if (self.view.effectiveDisplayMode() != .unified) null else .{
                        .view = .{
                            .identity = target.identity,
                            .content = .unified_diff,
                            .start = parsed.range.start,
                            .end = parsed.range.end,
                            .selected_points = unified.points,
                        },
                        .line_count = unified.line_count,
                    },
                };
            },
            .generated_untracked => |generated| blk: {
                const body = self.generatedBody() orelse break :blk null;
                if (!std.mem.eql(u8, generated.path, body.path)) break :blk null;
                if (generated.range.start.hunk_index != 0 or generated.range.end.hunk_index != 0) break :blk null;
                const source_rows = body.source.rowCount();
                if (generated.range.start.line_index >= source_rows or generated.range.end.line_index >= source_rows) break :blk null;
                break :blk switch (generated.content) {
                    .source_side => |source| if (self.view.effectiveDisplayMode() != .side_by_side) null else .{
                        .view = .{
                            .identity = .{ .generated_file = .{ .path_key = body.path } },
                            .content = .{ .source_side = .{ .side = .new, .mode = source.mode } },
                            .start = generated.range.start,
                            .end = generated.range.end,
                        },
                        .line_count = source.fragment.line_count,
                    },
                    .unified_diff => |unified| if (self.view.effectiveDisplayMode() != .unified) null else .{
                        .view = .{
                            .identity = .{ .generated_file = .{ .path_key = body.path } },
                            .content = .unified_diff,
                            .start = generated.range.start,
                            .end = generated.range.end,
                            .selected_points = unified.points,
                        },
                        .line_count = unified.line_count,
                    },
                };
            },
        };
    }

    pub fn activeKeyboardSelectionPresentation(self: BodyView) ?selection_action.Presentation {
        const drag = self.view.surface.selection_owner.activeDiff() orelse return null;
        if (drag.origin != .keyboard_line or drag.mode() != .line or drag.selected_line_count == 0) return null;
        const selected_range = drag.range();

        return switch (drag.identity) {
            .loaded_file, .projection_file => blk: {
                const target = self.parsedSelectionTarget(drag.identity) orelse break :blk null;
                if (selected_range.start.hunk_index >= target.file.hunks.len or selected_range.end.hunk_index >= target.file.hunks.len) break :blk null;
                if (selected_range.start.line_index >= target.file.hunks[selected_range.start.hunk_index].lines.len or
                    selected_range.end.line_index >= target.file.hunks[selected_range.end.hunk_index].lines.len) break :blk null;

                break :blk .{
                    .view = drag.view(),
                    .line_count = drag.selected_line_count,
                };
            },
            .generated_file => |generated| blk: {
                const body = self.generatedBody() orelse break :blk null;
                if (!std.mem.eql(u8, generated.path_key, body.path)) break :blk null;
                if (selected_range.start.hunk_index != 0 or selected_range.end.hunk_index != 0) break :blk null;
                const source_rows = body.source.rowCount();
                if (selected_range.start.line_index >= source_rows or selected_range.end.line_index >= source_rows) break :blk null;
                break :blk .{
                    .view = drag.view(),
                    .line_count = drag.selected_line_count,
                };
            },
        };
    }

    pub fn selectionPresentation(self: BodyView) ?selection_action.Presentation {
        return self.activeKeyboardSelectionPresentation() orelse self.retainedSelectionPresentation();
    }

    pub fn selectionStatusPresentation(self: BodyView) ?selection_action.StatusPresentation {
        const active_keyboard = self.activeKeyboardSelectionPresentation();
        const presentation = active_keyboard orelse (self.retainedSelectionPresentation() orelse return null);
        var status = presentation.status();
        if (self.contextCopyAvailable() and presentation.view.content == .source_side) status.actions = .source_context;
        if (self.view.effectiveDisplayMode() == .side_by_side and active_keyboard == null) status.side = .none;
        return status;
    }

    pub fn contextCopyAvailable(self: BodyView) bool {
        return self.view.surface.context_copy_available and self.view.effectiveDisplayMode() == .side_by_side;
    }

    pub fn keyboardSideChoiceActive(self: BodyView) bool {
        const choice = self.view.surface.selection_owner.activeKeyboardSideChoice() orelse return false;
        return self.keyboardSideChoiceHit(choice, .old) != null and self.keyboardSideChoiceHit(choice, .new) != null;
    }

    pub fn retainedSelectionActionAvailable(self: BodyView) bool {
        return self.selectionPresentation() != null;
    }

    pub fn selectionActionHit(self: BodyView, point: diff_surface.MousePoint) ?SelectionActionHit {
        const presentation = self.selectionStatusPresentation() orelse return null;
        const raw_diff = self.view.rawDiffPaneGeometry() orelse return null;
        if (point.col < raw_diff.col or point.col >= raw_diff.col + raw_diff.width) return null;
        if (point.row != 1) return null;
        const local_col = point.col - raw_diff.col;
        if (local_col == 0 or raw_diff.width <= 1) return .{ .target = null };
        const layout_value = selection_action.statusLayout(
            .{ .col = 1, .width = raw_diff.width - 1 },
            presentation,
        );
        return .{ .target = layout_value.targetAt(local_col) };
    }

    pub fn renderDiffScroll(self: BodyView) usize {
        return self.view.surface.viewer.diff_scroll;
    }

    pub fn renderDiffCursorOffset(self: BodyView) ?usize {
        return self.visibleDiffCursorOffset();
    }

    pub fn diffHeaderSelectionActive(self: BodyView) bool {
        const header = self.view.surface.selection_owner.activeHeader() orelse return false;
        _ = self.displayedDiffHeaderTarget(header.identity) orelse return false;
        return true;
    }

    pub fn normalLoadedDiffSelectionTarget(self: BodyView, identity: ?diff_selection.Identity) ?diff_surface.NormalLoadedDiffSelectionTarget {
        const target = self.parsedSelectionTarget(identity) orelse return null;
        const loaded_identity = switch (target.identity) {
            .loaded_file => |loaded| loaded,
            .projection_file, .generated_file => return null,
        };
        return .{
            .file_index = loaded_identity.file_index,
            .file = target.file,
            .line_index = target.line_index,
            .folded_hunks = target.folded_hunks,
            .identity = target.identity,
        };
    }

    pub fn diffHeaderMouseHit(self: BodyView, point: diff_surface.MousePoint) ?diff_surface.DiffHeaderTarget {
        const target = self.displayedDiffHeaderTarget(null) orelse return null;
        const raw_diff = self.view.rawDiffPaneGeometry() orelse return null;
        if (point.col < raw_diff.col or point.col >= raw_diff.col + raw_diff.width) return null;
        if (point.row != 0) return null;

        const local_col = point.col - raw_diff.col;
        const content_width = contentWidth(raw_diff.width);
        const content_gutter = raw_diff.width - content_width;
        if (local_col < content_gutter) return null;
        const render_col = local_col - content_gutter;
        if (render_col >= content_width) return null;

        const header_layout = self.displayedDiffHeaderLayout(content_width, target.display_path) orelse return null;
        const path_target = header_layout.path_target orelse return null;
        if (!path_target.contains(render_col)) return null;
        return target;
    }

    pub fn displayedDiffHeaderLayout(self: BodyView, content_width: u16, display_path: []const u8) ?diff_render.HeaderLayout {
        const mode_width = diff_render.bodyWidth(content_width);
        if (self.generatedBody()) |body| {
            return diff_render.generatedHeaderLayout(
                content_width,
                display_path,
                body.source.contentLineCount(),
                self.view.surface.viewer.display_mode,
                mode_width,
                self.view.mode_toggle_hint_width,
            );
        }
        const file = self.displayedDiffFile() orelse return null;
        return diff_render.fileHeaderLayout(
            content_width,
            display_path,
            file,
            self.view.surface.viewer.display_mode,
            mode_width,
            self.view.mode_toggle_hint_width,
        );
    }

    pub fn diffMouseHit(self: BodyView, point: diff_surface.MousePoint) ?diff_surface.DiffMouseHit {
        return self.diffMouseHitLocked(point, null);
    }

    pub fn presentationCellHit(self: BodyView, point: diff_surface.MousePoint) ?PresentationCellHit {
        const raw_diff = self.view.rawDiffPaneGeometry() orelse return null;
        if (point.col < raw_diff.col or point.col >= raw_diff.col + raw_diff.width) return null;
        if (point.row < diff_render.body_start_row) return null;

        const raw_local_col = point.col - raw_diff.col;
        const content_width = contentWidth(raw_diff.width);
        const content_gutter = raw_diff.width - content_width;
        if (raw_local_col < content_gutter) return null;
        const local_col = raw_local_col - content_gutter;
        if (local_col >= content_width) return null;

        const visible_body_row: usize = point.row - diff_render.body_start_row;
        if (visible_body_row >= self.view.diffVisibleRows()) return null;
        const presentation_offset = self.view.surface.viewer.diff_scroll + visible_body_row;
        const source_rows = self.sourceDiffLineCount();
        if (self.view.presentation_rows) |rows| {
            if (rows.source_rows != source_rows) return null;
            const mode = self.view.effectiveDisplayMode();
            const geometry = diff_render.sideBySideGeometry(diff_render.bodyWidth(content_width));
            const hit = rows.hitAtCell(presentation_offset, local_col, mode, geometry) orelse return null;
            return switch (hit) {
                .source => |source| .{ .source = .{
                    .source_offset = source.source_offset,
                    .local_col = source.local_col,
                } },
                .card => |card| .{ .card = .{
                    .token = card.token,
                    .local_row = card.local_row,
                    .local_col = card.local_col,
                } },
                .spacer => |spacer| .{ .spacer = .{ .local_col = spacer.local_col } },
                .padding, .separator, .gutter => .{ .spacer = .{ .local_col = local_col } },
            };
        }
        if (presentation_offset >= source_rows) return null;
        return .{ .source = .{ .source_offset = presentation_offset, .local_col = local_col } };
    }

    /// Resolve one line-wise endpoint from semantic body presentation without
    /// terminal coordinates. Presentation-only rows and opposite-side holes
    /// never become endpoints.
    pub fn keyboardLineHitAtOffset(
        self: BodyView,
        source_offset: usize,
        requested_side: ?diff_selection.Side,
    ) ?diff_surface.DiffMouseHit {
        const display_mode = self.view.effectiveDisplayMode();
        if (self.generatedBody()) |body| {
            if (source_offset >= body.source.rowCount()) return null;
            const content: diff_selection.Content = switch (display_mode) {
                .unified => blk: {
                    if (requested_side != null) return null;
                    break :blk .unified_diff;
                },
                .side_by_side => blk: {
                    if (requested_side == .old) return null;
                    break :blk .{ .source_side = .{ .side = .new } };
                },
            };
            return .{
                .identity = .{ .generated_file = .{ .path_key = body.path } },
                .content = content,
                .point = diff_selection.pointFromLine(0, source_offset),
            };
        }

        const target = self.parsedSelectionTarget(null) orelse return null;
        const mode = display_mode;
        const has_index = target.line_index.mode == mode and target.line_index.hunk_offsets.len == target.file.hunks.len;
        var rows = if (has_index)
            diff_view_model.BodyRowIterator.initAtWithFolded(
                target.file,
                mode,
                target.line_index,
                source_offset,
                target.folded_hunks,
            )
        else
            diff_view_model.BodyRowIterator.initWithFolded(target.file, mode, target.folded_hunks);
        var skipped: usize = if (has_index) source_offset else 0;
        var row = rows.next() orelse return null;
        while (skipped < source_offset) : (skipped += 1) row = rows.next() orelse return null;

        const hunk_index = rows.currentHunkIndex() orelse return null;
        return switch (row) {
            .unified_line => |line| blk: {
                if (requested_side != null or !diff_selection.lineSelectableInUnified(line)) break :blk null;
                break :blk .{
                    .identity = target.identity,
                    .content = .unified_diff,
                    .point = diff_selection.pointFromLine(hunk_index, rows.currentUnifiedLineIndex() orelse break :blk null),
                };
            },
            .side_by_side => blk: {
                const side = requested_side orelse diff_selection.Side.new;
                const indexed = rows.currentSideBySideRow() orelse break :blk null;
                const line = indexedLineForSide(indexed, side) orelse break :blk null;
                break :blk .{
                    .identity = target.identity,
                    .content = .{ .source_side = .{ .side = side } },
                    .point = diff_selection.pointFromLine(hunk_index, line.line_index),
                };
            },
            .metadata, .binary_marker, .hunk_header => null,
        };
    }

    pub fn keyboardLineStartAtOffset(self: BodyView, source_offset: usize) KeyboardLineStart {
        const candidates = self.keyboardSideCandidatesAtOffset(source_offset) orelse return .unavailable;
        const before = candidates.before;
        const after = candidates.after;
        if (before == null and after == null) return .unavailable;
        if (before == null) return .{ .direct = keyboardCandidateHit(candidates.identity, .new, after.?) };
        if (after == null) return .{ .direct = keyboardCandidateHit(candidates.identity, .old, before.?) };
        if (std.mem.eql(u8, before.?.text, after.?.text)) {
            return .{ .direct = keyboardCandidateHit(candidates.identity, .new, after.?) };
        }
        return .{ .choose = .{
            .identity = candidates.identity,
            .before = before.?.point,
            .after = after.?.point,
        } };
    }

    fn keyboardSideCandidatesAtOffset(self: BodyView, source_offset: usize) ?KeyboardSideCandidates {
        if (self.view.effectiveDisplayMode() != .side_by_side) return null;
        if (self.generatedBody()) |body| {
            if (source_offset >= body.source.rowCount()) return null;
            const text = body.source.lineBody(source_offset) orelse return null;
            return .{
                .identity = .{ .generated_file = .{ .path_key = body.path } },
                .before = null,
                .after = .{ .point = diff_selection.pointFromLine(0, source_offset), .text = text },
            };
        }

        const target = self.parsedSelectionTarget(null) orelse return null;
        const has_index = target.line_index.mode == .side_by_side and target.line_index.hunk_offsets.len == target.file.hunks.len;
        var rows = if (has_index)
            diff_view_model.BodyRowIterator.initAtWithFolded(
                target.file,
                .side_by_side,
                target.line_index,
                source_offset,
                target.folded_hunks,
            )
        else
            diff_view_model.BodyRowIterator.initWithFolded(target.file, .side_by_side, target.folded_hunks);
        var skipped: usize = if (has_index) source_offset else 0;
        var row = rows.next() orelse return null;
        while (skipped < source_offset) : (skipped += 1) row = rows.next() orelse return null;
        switch (row) {
            .side_by_side => {},
            .metadata, .binary_marker, .hunk_header, .unified_line => return null,
        }
        const indexed = rows.currentSideBySideRow() orelse return null;
        const hunk_index = rows.currentHunkIndex() orelse return null;
        return .{
            .identity = target.identity,
            .before = keyboardSideCandidate(indexed, hunk_index, .old),
            .after = keyboardSideCandidate(indexed, hunk_index, .new),
        };
    }

    pub fn keyboardSideChoiceHit(
        self: BodyView,
        choice: diff_selection.KeyboardSideChoice,
        side: diff_selection.Side,
    ) ?diff_surface.DiffMouseHit {
        const target = self.parsedSelectionTarget(choice.identity) orelse return null;
        if (self.view.effectiveDisplayMode() != .side_by_side) return null;
        const offset = diff_view_model.renderedOffsetForCoordinate(
            target.file,
            .side_by_side,
            .{ .hunk_line = .{
                .hunk_index = choice.before.hunk_index,
                .line_index = choice.before.line_index,
            } },
            target.folded_hunks,
            target.line_index,
        ) orelse return null;
        const candidates = self.keyboardSideCandidatesAtOffset(offset) orelse return null;
        if (!choice.identity.eql(candidates.identity)) return null;
        const before = candidates.before orelse return null;
        const after = candidates.after orelse return null;
        if (!before.point.eql(choice.before) or !after.point.eql(choice.after)) return null;
        return keyboardCandidateHit(
            candidates.identity,
            side,
            if (side == .old) before else after,
        );
    }

    pub fn keyboardLineHitNearOffset(
        self: BodyView,
        source_offset: usize,
        requested_side: ?diff_selection.Side,
    ) ?KeyboardLineHit {
        const line_count = self.sourceDiffLineCount();
        if (line_count == 0) return null;
        const start = @min(source_offset, line_count - 1);
        if (self.keyboardLineHitAtOffset(start, requested_side)) |hit| {
            return .{ .source_offset = start, .hit = hit };
        }

        var forward = start +| 1;
        while (forward < line_count) : (forward += 1) {
            if (self.keyboardLineHitAtOffset(forward, requested_side)) |hit| {
                return .{ .source_offset = forward, .hit = hit };
            }
        }
        var backward = start;
        while (backward > 0) {
            backward -= 1;
            if (self.keyboardLineHitAtOffset(backward, requested_side)) |hit| {
                return .{ .source_offset = backward, .hit = hit };
            }
        }
        return null;
    }

    pub fn keyboardLineSourceOffset(self: BodyView, selection: diff_selection.DragSelection) ?usize {
        return switch (selection.identity) {
            .generated_file => |generated| blk: {
                const body = self.generatedBody() orelse break :blk null;
                const content_valid = switch (self.view.effectiveDisplayMode()) {
                    .unified => selection.content == .unified_diff,
                    .side_by_side => if (selection.sourceSide()) |source| source.side == .new else false,
                };
                if (!std.mem.eql(u8, generated.path_key, body.path) or !content_valid or
                    selection.focus.hunk_index != 0 or selection.focus.line_index >= body.source.rowCount()) break :blk null;
                break :blk selection.focus.line_index;
            },
            .loaded_file, .projection_file => blk: {
                const target = self.parsedSelectionTarget(selection.identity) orelse break :blk null;
                if (selection.focus.hunk_index >= target.file.hunks.len) break :blk null;
                const hunk = target.file.hunks[selection.focus.hunk_index];
                if (selection.focus.line_index >= hunk.lines.len) break :blk null;
                const selectable = switch (selection.content) {
                    .unified_diff => diff_selection.lineSelectableInUnified(hunk.lines[selection.focus.line_index]),
                    .source_side => |source| diff_selection.lineVisibleOnSide(hunk.lines[selection.focus.line_index], source.side),
                };
                if (!selectable) break :blk null;
                break :blk diff_view_model.renderedOffsetForCoordinate(
                    target.file,
                    self.view.effectiveDisplayMode(),
                    .{ .hunk_line = .{
                        .hunk_index = selection.focus.hunk_index,
                        .line_index = selection.focus.line_index,
                    } },
                    target.folded_hunks,
                    target.line_index,
                );
            },
        };
    }

    pub fn diffMouseDragHit(self: BodyView, point: diff_surface.MousePoint, drag: diff_selection.DragSelection) ?diff_surface.DiffMouseHit {
        return self.diffMouseHitLocked(point, drag);
    }

    fn diffMouseHitLocked(self: BodyView, point: diff_surface.MousePoint, locked: ?diff_selection.DragSelection) ?diff_surface.DiffMouseHit {
        const cell = self.presentationCellHit(point) orelse return null;
        const source = switch (cell) {
            .source => |value| value,
            .card, .spacer => return null,
        };
        if (source.local_col < diff_render.cursor_gutter_width) return null;
        const body_col = source.local_col - diff_render.cursor_gutter_width;
        const body_width = diff_render.bodyWidth(self.view.diffPaneWidth());
        const offset = source.source_offset;
        const display_mode = diff_render.effectiveMode(body_width, self.view.surface.viewer.display_mode);

        if (self.parsedSelectionTarget(if (locked) |selection_value| selection_value.identity else null)) |target| {
            const hit = parsedMouseLine(target, body_col, body_width, display_mode, offset, self.view.surface.viewer.view_options.line_numbers, locked) orelse return null;
            if (display_mode == .unified) return .{
                .identity = target.identity,
                .content = .unified_diff,
                .point = diff_selection.pointFromLine(hit.hunk_index, hit.line_index),
            };
            const region = hit.region orelse return null;
            const model_mode = if (locked) |selection_value| selection_value.mode() else region.mode;
            const point_value = if (region.leading_boundary)
                diff_selection.pointFromBoundary(hit.hunk_index, hit.line_index, 0)
            else
                pointForTextCell(hit.hunk_index, hit.line_index, hit.line.text, model_mode, self.view.surface.viewer.diff_horizontal_scroll, region.text_cell) orelse return null;
            return .{
                .identity = target.identity,
                .content = .{ .source_side = .{ .side = region.side, .mode = model_mode } },
                .point = point_value,
            };
        }

        const generated = self.generatedBody() orelse return null;
        const line = generated.source.lineBody(offset) orelse return null;
        if (display_mode == .unified) {
            if (locked) |selection_value| if (selection_value.content != .unified_diff) return null;
            return .{
                .identity = .{ .generated_file = .{ .path_key = generated.path } },
                .content = .unified_diff,
                .point = diff_selection.pointFromLine(0, offset),
            };
        }
        const region = selectionRegionForGenerated(body_col, body_width, display_mode, self.view.surface.viewer.view_options.line_numbers, locked) orelse return null;
        const model_mode = if (locked) |selection_value| selection_value.mode() else region.mode;
        return .{
            .identity = .{ .generated_file = .{ .path_key = generated.path } },
            .content = .{ .source_side = .{ .side = .new, .mode = model_mode } },
            .point = if (region.leading_boundary)
                diff_selection.pointFromBoundary(0, offset, 0)
            else
                pointForTextCell(0, offset, line, model_mode, self.view.surface.viewer.diff_horizontal_scroll, region.text_cell) orelse return null,
        };
    }

    pub fn displayedGeneratedLineCount(self: BodyView) ?usize {
        const generated = self.generatedBody() orelse return null;
        return generated.source.rowCount();
    }

    pub fn visibleBodyTextMaxHorizontalScroll(self: BodyView) usize {
        const mode = self.view.effectiveDisplayMode();
        const visible_rows = self.view.diffVisibleRows();
        if (visible_rows == 0) return 0;

        const body_width = diff_render.bodyWidth(self.view.diffPaneWidth());
        if (self.generatedBody()) |body| {
            const row_count = body.source.rowCount();
            const first_row = @min(self.renderDiffScroll(), row_count);
            const end_row = @min(first_row +| visible_rows, row_count);
            var max_scroll: usize = 0;
            for (first_row..end_row) |row_index| {
                const line: diff_parser.DiffLine = .{
                    .kind = .added,
                    .text = body.source.lineBody(row_index) orelse continue,
                    .new_line = @intCast(row_index + 1),
                };
                const body_row: diff_view_model.BodyRow = switch (mode) {
                    .unified => .{ .unified_line = line },
                    .side_by_side => .{ .side_by_side = .{ .paired = .{ .added = line } } },
                };
                max_scroll = @max(max_scroll, maxHorizontalScrollForBodyRow(
                    body_row,
                    body_width,
                    self.view.surface.viewer.view_options.line_numbers,
                ));
            }
            return max_scroll;
        }

        const file = self.displayedDiffFile() orelse return 0;
        const line_index = self.displayedDiffLineIndex(mode);
        var max_scroll: usize = 0;
        var rows = if (line_index) |index|
            diff_view_model.BodyRowIterator.initAtWithFolded(file, mode, index, self.renderDiffScroll(), self.selectedFoldedHunks())
        else
            diff_view_model.BodyRowIterator.initWithFolded(file, mode, self.selectedFoldedHunks());
        var skipped: usize = if (line_index != null) self.renderDiffScroll() else 0;
        var visible: usize = 0;
        while (rows.next()) |body_row| {
            if (skipped < self.renderDiffScroll()) {
                skipped += 1;
                continue;
            }
            if (visible >= visible_rows) break;
            visible += 1;
            max_scroll = @max(max_scroll, maxHorizontalScrollForBodyRow(body_row, body_width, self.view.surface.viewer.view_options.line_numbers));
        }
        return max_scroll;
    }

    pub fn selectedProjectionLineCount(self: BodyView) usize {
        return self.resolvedTarget().line_count;
    }

    pub fn remapDiffScrollForModeChange(
        self: BodyView,
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

    pub fn unsupportedSearchMessage(self: BodyView) ?[]const u8 {
        const reason = self.resolvedTarget().search_unavailable orelse return null;
        return reason.message();
    }

    pub fn bodyAllowsHunkInteraction(self: BodyView) bool {
        return self.hunkInteractionAvailability() == .available;
    }

    pub fn bodyAllowsHunkFold(self: BodyView) bool {
        const target = self.resolvedTarget();
        return resolvedTargetAllowsHunkFold(target);
    }

    pub fn hunkInteractionAvailability(self: BodyView) diff_surface.HunkInteractionAvailability {
        return self.resolvedTarget().hunk_interaction;
    }

    pub fn selectedFileLineIndex(self: BodyView, mode: diff_render.DisplayMode) diff_view_model.RenderedLineIndex {
        if (self.resolvedTarget().kind == .inert) return .{ .mode = mode };
        if (self.displayedDiffLineIndex(mode)) |index| return index;
        const loaded = self.view.activeLoadedDiffConst() orelse return .{ .mode = mode };
        const file_index = self.view.selectedFileIndex(loaded) orelse return .{ .mode = mode };
        return loaded.renderedLineIndex(file_index, mode);
    }

    pub fn selectedFoldedHunks(self: BodyView) []const bool {
        if (self.resolvedTarget().folded_hunks_source == .empty) return &.{};
        const loaded = self.view.activeLoadedDiffConst() orelse return &.{};
        const file_index = self.view.selectedFileIndex(loaded) orelse return &.{};
        return loaded.foldedHunksForFile(file_index);
    }

    pub fn selectedHunkIndex(self: BodyView) ?usize {
        if (!self.bodyAllowsHunkInteraction()) return null;
        return self.view.rawSelectedHunkIndex();
    }

    pub fn selectedDiffCursorOffset(self: BodyView) ?usize {
        if (self.displayedGeneratedLineCount()) |line_count| {
            return switch (self.view.surface.viewer.diff_cursor) {
                .metadata => |offset| if (offset < line_count) offset else null,
                else => null,
            };
        }

        const mode = self.view.effectiveDisplayMode();
        const file = self.displayedDiffFile() orelse return null;
        const index = self.displayedDiffLineIndex(mode) orelse self.view.selectedFileCachedLineIndex(mode);
        return diff_view_model.renderedOffsetForCoordinate(file, mode, self.view.surface.viewer.diff_cursor, self.selectedFoldedHunks(), index);
    }

    pub fn selectedCoordinateAtOffset(self: BodyView, offset: usize) ?diff_view_model.BodyCoordinate {
        if (self.displayedGeneratedLineCount()) |line_count| {
            if (offset >= line_count) return null;
            return .{ .metadata = offset };
        }

        const mode = self.view.effectiveDisplayMode();
        const file = self.displayedDiffFile() orelse return null;
        const index = self.displayedDiffLineIndex(mode) orelse self.view.selectedFileCachedLineIndex(mode);
        return diff_view_model.coordinateAtOffset(file, mode, offset, self.selectedFoldedHunks(), index);
    }

    pub fn sourceToPresentationOffset(self: BodyView, source_offset: usize) ?usize {
        const rows = self.view.presentation_rows orelse
            return if (source_offset < self.sourceDiffLineCount()) source_offset else null;
        if (rows.source_rows != self.sourceDiffLineCount()) return null;
        return rows.sourceToPresentation(source_offset);
    }

    pub fn presentationToSourceOffset(self: BodyView, presentation_offset: usize) ?usize {
        const rows = self.view.presentation_rows orelse
            return if (presentation_offset < self.sourceDiffLineCount()) presentation_offset else null;
        if (rows.source_rows != self.sourceDiffLineCount()) return null;
        const hit = rows.hitAtPresentation(presentation_offset) orelse return null;
        return switch (hit) {
            .source => |source_offset| source_offset,
            .card, .pane, .spacer => null,
        };
    }

    pub fn sourceAnchorAtOrBeforePresentation(self: BodyView, presentation_offset: usize) ?usize {
        const rows = self.view.presentation_rows orelse
            return if (self.sourceDiffLineCount() == 0) null else @min(presentation_offset, self.sourceDiffLineCount() - 1);
        if (rows.source_rows != self.sourceDiffLineCount()) return null;
        return rows.sourceAnchorAtOrBeforePresentation(presentation_offset);
    }

    pub fn selectedDiffCursorPresentationOffset(self: BodyView) ?usize {
        return self.sourceToPresentationOffset(self.selectedDiffCursorOffset() orelse return null);
    }

    pub fn selectedCoordinateAtPresentationOffset(self: BodyView, offset: usize) ?diff_view_model.BodyCoordinate {
        return self.selectedCoordinateAtOffset(self.presentationToSourceOffset(offset) orelse return null);
    }

    pub fn selectionViewportBasis(self: BodyView) selection_action.ViewportBasis {
        return .{
            .layout_revision = self.view.surface.selection_layout_revision.*,
            .mapping_variant = @intFromEnum(self.view.effectiveDisplayMode()),
            .source_rows = self.sourceDiffLineCount(),
            .presentation_rows = self.presentationDiffLineCount(),
        };
    }

    fn semanticSourceAtOffset(self: BodyView, source_offset: usize) selection_action.SemanticSource {
        if (self.generatedBody() != null) return .{ .generated_row = source_offset };
        if (self.selectedCoordinateAtOffset(source_offset)) |coordinate| return .{ .parsed = coordinate };
        return .none;
    }

    fn resolveSemanticSource(self: BodyView, semantic: selection_action.SemanticSource) ?usize {
        return switch (semantic) {
            .none => null,
            .generated_row => |row| if (self.generatedBody() != null and row < self.sourceDiffLineCount()) row else null,
            .parsed => |coordinate| blk: {
                if (self.generatedBody() != null) break :blk null;
                const mode = self.view.effectiveDisplayMode();
                const file = self.displayedDiffFile() orelse break :blk null;
                const index = self.displayedDiffLineIndex(mode) orelse self.view.selectedFileCachedLineIndex(mode);
                break :blk diff_view_model.renderedOffsetForCoordinate(
                    file,
                    mode,
                    coordinate,
                    self.selectedFoldedHunks(),
                    index,
                );
            },
        };
    }

    pub fn captureSelectionViewportAnchor(self: BodyView) ?selection_action.SelectionViewportAnchor {
        if (self.selectionPresentation() == null) return null;
        const basis = self.selectionViewportBasis();
        if (basis.source_rows == 0) return null;
        const source_anchor = self.sourceAnchorAtOrBeforePresentation(self.view.surface.viewer.diff_scroll) orelse return null;
        const position = selection_action.captureAnchorPosition(basis.source_rows, source_anchor);
        return .{
            .semantic_source = self.semanticSourceAtOffset(position.source_offset_fallback),
            .source_offset_fallback = position.source_offset_fallback,
            .raw_presentation_scroll = self.view.surface.viewer.diff_scroll,
            .basis = basis,
        };
    }

    pub fn restoreSelectionViewportAnchor(self: BodyView, anchor: selection_action.SelectionViewportAnchor) usize {
        return selection_action.restoreViewportAnchor(
            anchor,
            self.selectionViewportBasis(),
            if (self.resolveSemanticSource(anchor.semantic_source)) |source_offset|
                self.sourceToPresentationOffset(source_offset)
            else
                null,
            self.sourceToPresentationOffset(anchor.source_offset_fallback),
            self.view.diffVisibleRows(),
        );
    }

    pub fn visibleDiffCursorOffset(self: BodyView) ?usize {
        const offset = self.selectedDiffCursorPresentationOffset() orelse return null;
        const visible_rows = self.view.diffVisibleRows();
        if (offset < self.view.surface.viewer.diff_scroll) return null;
        if (visible_rows == 0 or offset >= self.view.surface.viewer.diff_scroll + visible_rows) return null;
        return offset;
    }

    pub fn diffCursorIsVisible(self: BodyView) bool {
        return self.visibleDiffCursorOffset() != null;
    }
};

/// Short-lived mutable facade for page-independent model operations.
///
/// Views created from this controller receive only the const-qualified
/// projection. The mutable capability remains private to controller methods.
pub const Controller = struct {
    surface: diff_surface.DiffSurface,
    repo_root: ?[]const u8,
    repo_epoch: u64 = 0,
    mode_toggle_hint_width: u16 = 0,
    presentation_rows: ?*const diff_render.PresentationRows = null,
    diagnostics: diff_surface.DiagnosticSink,

    pub fn view(self: Controller) View {
        return .{
            .surface = self.surface.readOnly(),
            .repo_root = self.repo_root,
            .mode_toggle_hint_width = self.mode_toggle_hint_width,
            .presentation_rows = self.presentation_rows,
        };
    }

    pub fn setStatus(self: Controller, comptime fmt: []const u8, args: anytype) void {
        self.diagnostics.set(fmt, args);
    }

    pub fn stableOrderOptions(self: Controller, allocator: std.mem.Allocator) file_tree.StableOrderOptions {
        return .{
            .allocator = allocator,
            .order = self.surface.tree_order,
        };
    }

    pub fn rebuildVisibleNodes(self: Controller, loaded: *LoadedDiff, allocator: std.mem.Allocator) !void {
        try loaded.rebuildVisibleNodes(
            allocator,
            self.surface.review_display.hide_reviewed_files,
            self.surface.review_display.changed_file_filter,
        );
    }

    pub fn clearDiffSelection(self: Controller) void {
        self.surface.selection_owner.* = .none;
    }

    pub fn clearMouseDiffSelection(self: Controller) void {
        if (self.surface.selection_owner.activeMouseSelection()) self.clearDiffSelection();
    }

    pub fn clearKeyboardSideChoice(self: Controller) void {
        if (self.surface.selection_owner.activeKeyboardSideChoice() != null) self.clearDiffSelection();
    }

    pub fn focusSidebar(self: Controller) bool {
        if (self.surface.viewer.sidebar_hidden) return false;
        self.surface.viewer.focus = .sidebar;
        self.clearKeyboardSideChoice();
        return true;
    }

    pub fn advanceSelectionLayoutRevision(self: Controller) void {
        self.surface.selection_layout_revision.* +%= 1;
        if (self.surface.selection_layout_revision.* == 0) self.surface.selection_layout_revision.* = 1;
    }

    pub fn clearCompletedSelectionWithViewport(self: Controller, resolver: diff_surface.BodyResolver, allocator: std.mem.Allocator) void {
        const body = (BodyController{ .controller = self, .resolver = resolver }).view();
        const anchor = body.captureSelectionViewportAnchor();
        self.clearDiffSelection();
        if (self.surface.completed_selection.*) |*completed| completed.deinit(allocator);
        self.surface.completed_selection.* = null;
        if (anchor) |value| {
            const incoming = (BodyController{ .controller = self, .resolver = resolver }).view();
            self.surface.viewer.diff_scroll = incoming.restoreSelectionViewportAnchor(value);
        }
    }

    /// Admit asynchronous clipboard success only for the exact retained
    /// selection generation which produced the request. A newer live owner is
    /// deliberately left untouched.
    pub fn clearCompletedSelectionAfterCopy(
        self: Controller,
        allocator: std.mem.Allocator,
        generation: u64,
    ) bool {
        if (self.surface.selection_generation.* != generation or
            self.surface.completed_selection.* == null)
        {
            return false;
        }
        if (self.surface.completed_selection.*) |*completed| completed.deinit(allocator);
        self.surface.completed_selection.* = null;
        return true;
    }

    pub fn scrollSidebarHorizontal(self: Controller, direction: HorizontalDirection) void {
        const step: usize = 4;
        switch (direction) {
            .left => self.surface.viewer.sidebar_horizontal_scroll -|= step,
            .right => {
                self.surface.viewer.sidebar_horizontal_scroll += step;
                self.clampSidebarHorizontalScroll();
            },
        }
    }

    pub fn clampSidebarHorizontalScroll(self: Controller) void {
        const max_scroll = self.view().visibleSidebarMaxHorizontalScroll();
        if (self.surface.viewer.sidebar_horizontal_scroll > max_scroll) {
            self.surface.viewer.sidebar_horizontal_scroll = max_scroll;
        }
    }

    pub fn cancelSearchMode(self: Controller) void {
        self.surface.search.input = self.surface.search.query;
        self.surface.search.mode = false;
    }

    pub fn clearSearch(self: Controller) void {
        self.surface.search.mode = false;
        self.surface.search.input = .{};
        self.surface.search.query = .{};
        self.clearSearchMatch();
    }

    pub fn resetAfterRepositorySwitch(self: Controller) void {
        self.setSelectedDiffFile(0);
        self.surface.viewer.selected_node = 0;
        self.clearSearch();
    }

    pub fn enterFileSearchMode(self: Controller, allocator: std.mem.Allocator) void {
        self.clearMouseDiffSelection();
        self.clearKeyboardSideChoice();
        self.surface.file_search_return_focus.* = if (self.surface.viewer.sidebar_hidden) .diff else self.surface.viewer.focus;
        _ = self.focusSidebar();
        self.surface.file_search.mode = true;
        self.surface.file_search.input = .{};
        self.surface.file_search.resetNoMatch();
        // Empty input is an authoritative all-eligible-files projection, not
        // a sentinel state. This also establishes the unavailable terminal
        // immediately when no accepted sidebar can supply candidates.
        self.rebuildFileSearchProjection(allocator);
    }

    pub fn cancelFileSearchMode(self: Controller, allocator: std.mem.Allocator) void {
        self.surface.file_search.deinit(allocator);
        self.surface.viewer.focus = if (self.surface.viewer.sidebar_hidden) .diff else self.surface.file_search_return_focus.*;
    }

    pub fn rebuildFileSearchProjection(self: Controller, allocator: std.mem.Allocator) void {
        if (!self.surface.file_search.mode) {
            self.surface.file_search.markProjectionUnavailable(allocator);
            return;
        }
        const loaded = self.activeLoadedDiff() orelse {
            self.surface.file_search.markProjectionUnavailable(allocator);
            return;
        };
        const basis = self.currentFileSearchBasis() orelse {
            self.surface.file_search.markProjectionUnavailable(allocator);
            return;
        };
        const query = std.mem.trim(u8, self.surface.file_search.input.slice(), " \t\r\n");
        var projection = file_search.buildProjection(allocator, loaded, query, .{
            .basis = basis,
            .hide_reviewed_files = self.surface.review_display.hide_reviewed_files,
            .changed_file_filter = self.surface.review_display.changed_file_filter,
        }) catch {
            self.surface.file_search.markProjectionUnavailable(allocator);
            return;
        };
        self.surface.file_search.publish(allocator, &projection);
    }

    pub fn currentFileSearchBasis(self: Controller) ?file_search.Basis {
        _ = self.view().activeLoadedDiffConst() orelse return null;
        const basis: file_search.Basis = .{
            .repo_epoch = self.repo_epoch,
            .source_session_revision = self.surface.source_session_revision.*,
            .accepted_sidebar_revision = self.surface.accepted_sidebar_revision.*,
        };
        return if (basis.valid()) basis else null;
    }

    pub fn advanceAcceptedSidebarRevision(self: Controller, allocator: ?std.mem.Allocator) void {
        file_search.advanceAcceptedSidebarRevision(
            self.surface.file_search,
            self.surface.accepted_sidebar_revision,
            allocator,
        );
    }

    pub fn clearSearchMatch(self: Controller) void {
        self.surface.search.match = null;
        self.surface.search.match_offset = null;
    }

    pub fn scrollSearchMatchIntoView(self: Controller) void {
        const offset = self.surface.search.match_offset orelse return;
        const visible_rows = self.view().diffVisibleRows();
        if (offset < self.surface.viewer.diff_scroll) {
            self.surface.viewer.diff_scroll = offset;
        } else if (visible_rows > 0 and offset >= self.surface.viewer.diff_scroll + visible_rows) {
            self.surface.viewer.diff_scroll = offset + 1 - visible_rows;
        }
    }

    pub fn ensureTreeOrderScope(self: Controller, allocator: std.mem.Allocator) !void {
        const scope = try self.view().treeOrderScopeText(allocator);
        defer allocator.free(scope);

        if (self.surface.tree_order_scope.*) |current| {
            if (std.mem.eql(u8, current, scope)) return;
            allocator.free(current);
            self.surface.tree_order_scope.* = null;
            self.surface.tree_order.reset(allocator);
        }

        self.surface.tree_order_scope.* = try allocator.dupe(u8, scope);
    }

    pub fn resetDiffHorizontalScroll(self: Controller) void {
        self.surface.viewer.diff_horizontal_scroll = 0;
    }

    pub fn resetDiffHorizontalScrollIfPaneWidthChanged(self: Controller, previous_width: u16) void {
        if (self.view().diffPaneWidth() != previous_width) self.resetDiffHorizontalScroll();
    }

    pub fn setSelectedDiffFile(self: Controller, file_index: usize) void {
        const same_target = if (self.surface.viewer.selected_target) |target|
            if (target.diffFileIndex()) |current| current == file_index else false
        else
            false;
        if (!same_target) self.clearDiffSelection();
        self.surface.viewer.selected_target = .{ .diff_file = file_index };
    }

    pub fn syncSidebarNodeToSelectedFile(self: Controller, loaded: *const LoadedDiff) void {
        const file_index = self.view().selectedFileIndex(loaded) orelse {
            self.surface.viewer.selected_node = 0;
            return;
        };
        self.surface.viewer.selected_node = loaded.tree.selectedNodeIndex(file_index) orelse 0;
    }

    pub fn materializeReviewedFiles(self: Controller, allocator: std.mem.Allocator, loaded: *LoadedDiff) !void {
        const reviewed_files = try allocator.alloc(bool, loaded.document.files.len);
        errdefer allocator.free(reviewed_files);

        for (loaded.document.files, 0..) |file, index| {
            reviewed_files[index] = try self.surface.reviewed_store.containsFile(allocator, self.repo_root, file);
        }
        loaded.reviewed_files = reviewed_files;
    }

    pub fn activeLoadedDiff(self: Controller) ?*LoadedDiff {
        return switch (self.surface.load.state) {
            .loaded => |*session| &session.loaded,
            else => null,
        };
    }

    pub fn loadArenaAllocator(self: Controller) ?std.mem.Allocator {
        return switch (self.surface.load.state) {
            .loaded => |*session| session.arena.allocator(),
            .failed => |*failed| failed.arena.allocator(),
            else => null,
        };
    }
};

/// Short-lived mutable facade for body-aware navigation operations.
///
/// The resolver context is borrowed only for the synchronous delegated call
/// that owns this value. Mutation methods re-resolve body borrows after state
/// changes rather than retaining them in the controller.
pub const BodyController = struct {
    controller: Controller,
    resolver: diff_surface.BodyResolver,

    pub fn view(self: BodyController) BodyView {
        return .{
            .view = self.controller.view(),
            .resolver = self.resolver,
        };
    }

    pub fn scrollSearchMatchIntoView(self: BodyController) void {
        const source_offset = self.controller.surface.search.match_offset orelse return;
        const offset = self.view().sourceToPresentationOffset(source_offset) orelse return;
        const visible_rows = self.controller.view().diffVisibleRows();
        if (offset < self.controller.surface.viewer.diff_scroll) {
            self.controller.surface.viewer.diff_scroll = offset;
        } else if (visible_rows > 0 and offset >= self.controller.surface.viewer.diff_scroll + visible_rows) {
            self.controller.surface.viewer.diff_scroll = offset + 1 - visible_rows;
        }
    }

    pub fn captureSelectionViewportAnchor(self: BodyController) ?selection_action.SelectionViewportAnchor {
        return self.view().captureSelectionViewportAnchor();
    }

    pub fn restoreSelectionViewportAnchor(self: BodyController, anchor: selection_action.SelectionViewportAnchor) void {
        self.controller.surface.viewer.diff_scroll = self.view().restoreSelectionViewportAnchor(anchor);
    }

    pub fn clearCompletedSelectionAfterCopy(
        self: BodyController,
        allocator: std.mem.Allocator,
        generation: u64,
    ) bool {
        return self.controller.clearCompletedSelectionAfterCopy(allocator, generation);
    }

    pub fn toggleReviewedFile(
        self: BodyController,
        cleanup: SelectionMappingCleanup,
        allocator: std.mem.Allocator,
    ) !void {
        const loaded = self.controller.activeLoadedDiff() orelse return;
        if (self.controller.surface.viewer.selected_node >= loaded.tree.nodes.len) return;

        const file_index = self.controller.view().selectedFileIndex(loaded) orelse return;
        if (file_index >= loaded.reviewed_files.len) return;
        const file = loaded.document.files[file_index];
        if (self.controller.repo_root != null and diff_file.canonicalPathKey(file) == null) return;

        const reviewed = !loaded.reviewed_files[file_index];
        if (self.controller.surface.review_display.hide_reviewed_files) {
            // Prepare the primary visible-tree replacement before changing
            // reviewed authority. Once that primary operation can commit, the
            // old search projection must be revoked before eligibility changes.
            var prepared = try loaded.prepareVisibleNodeRebuild(self.controller.loadArenaAllocator() orelse unreachable);
            try self.controller.surface.reviewed_store.set(allocator, self.controller.repo_root, file, reviewed);
            self.controller.advanceAcceptedSidebarRevision(allocator);
            loaded.reviewed_files[file_index] = reviewed;
            prepared.commit(
                self.controller.surface.review_display.hide_reviewed_files,
                self.controller.surface.review_display.changed_file_filter,
            );
            self.reconcileSelectionAfterVisibleNodeChange(cleanup, loaded);
            self.controller.clampSidebarHorizontalScroll();
            self.clampDiffNavigation();
            self.controller.rebuildFileSearchProjection(allocator);
            return;
        }

        try self.controller.surface.reviewed_store.set(allocator, self.controller.repo_root, file, reviewed);
        loaded.reviewed_files[file_index] = reviewed;
    }

    pub fn toggleHideReviewedFiles(
        self: BodyController,
        cleanup: SelectionMappingCleanup,
        allocator: std.mem.Allocator,
    ) !void {
        try self.replaceFileVisibilityLens(
            cleanup,
            allocator,
            self.controller.loadArenaAllocator() orelse allocator,
            !self.controller.surface.review_display.hide_reviewed_files,
            self.controller.surface.review_display.changed_file_filter,
        );
    }

    pub fn cycleChangedFileFilter(
        self: BodyController,
        cleanup: SelectionMappingCleanup,
        allocator: std.mem.Allocator,
    ) !void {
        try self.replaceFileVisibilityLens(
            cleanup,
            allocator,
            self.controller.loadArenaAllocator() orelse allocator,
            self.controller.surface.review_display.hide_reviewed_files,
            self.controller.surface.review_display.changed_file_filter.next(),
        );
    }

    /// Replace the accepted file-visibility lens transactionally. Search
    /// allocation follows the primary commit so its failure cannot reject a
    /// valid lens change.
    pub fn replaceFileVisibilityLens(
        self: BodyController,
        cleanup: SelectionMappingCleanup,
        allocator: std.mem.Allocator,
        visible_allocator: std.mem.Allocator,
        hide_reviewed_files: bool,
        changed_file_filter: loaded_diff.ChangedFileFilter,
    ) !void {
        if (self.controller.activeLoadedDiff()) |loaded| {
            var prepared = try loaded.prepareVisibleNodeRebuild(visible_allocator);
            self.controller.advanceAcceptedSidebarRevision(allocator);
            self.controller.surface.review_display.hide_reviewed_files = hide_reviewed_files;
            self.controller.surface.review_display.changed_file_filter = changed_file_filter;
            prepared.commit(hide_reviewed_files, changed_file_filter);
            self.reconcileSelectionAfterVisibleNodeChange(cleanup, loaded);
            self.controller.clampSidebarHorizontalScroll();
            self.clampDiffNavigation();
        } else {
            // Lens state is retained across unloaded states. Revoke any
            // projection defensively and give the next accepted sidebar a new
            // namespace even though there is no visible tree to rebuild now.
            self.controller.advanceAcceptedSidebarRevision(allocator);
            self.controller.surface.review_display.hide_reviewed_files = hide_reviewed_files;
            self.controller.surface.review_display.changed_file_filter = changed_file_filter;
        }
        self.controller.rebuildFileSearchProjection(allocator);
    }

    pub fn submitFileSearch(
        self: BodyController,
        cleanup: SelectionMappingCleanup,
        allocator: std.mem.Allocator,
    ) void {
        self.submitFileSearchWithVisibleAllocator(cleanup, allocator, null);
    }

    pub fn submitFileSearchWithVisibleAllocator(
        self: BodyController,
        cleanup: SelectionMappingCleanup,
        allocator: std.mem.Allocator,
        visible_allocator_override: ?std.mem.Allocator,
    ) void {
        if (!self.controller.surface.file_search.projection_available) return;
        const candidate = self.controller.surface.file_search.focusedCandidate() orelse {
            if (self.controller.surface.file_search.filter.labels.len == 0) {
                self.controller.surface.file_search.no_match = true;
            } else {
                self.controller.surface.file_search.markProjectionUnavailable(allocator);
            }
            return;
        };
        const loaded = self.controller.activeLoadedDiff() orelse {
            self.controller.surface.file_search.markProjectionUnavailable(allocator);
            return;
        };
        const basis = self.controller.currentFileSearchBasis() orelse {
            self.controller.surface.file_search.markProjectionUnavailable(allocator);
            return;
        };
        const node_index = candidate.node_index;
        if (node_index >= loaded.tree.nodes.len or
            !candidate.matchesNode(basis, node_index, loaded.tree.nodes[node_index]) or
            !loaded.shouldIncludeFileNode(
                node_index,
                self.controller.surface.review_display.hide_reviewed_files,
                self.controller.surface.review_display.changed_file_filter,
            ))
        {
            self.controller.surface.file_search.markProjectionUnavailable(allocator);
            return;
        }

        self.revealAndSelectExactNode(
            cleanup,
            loaded,
            node_index,
            visible_allocator_override orelse self.controller.loadArenaAllocator(),
        ) catch {
            self.controller.setStatus("Could not reveal file search result", .{});
            return;
        };
        self.controller.surface.file_search.deinit(allocator);
        self.controller.surface.viewer.focus = .diff;
    }

    /// Commit one already validated exact file node through the shared
    /// ancestor-reveal and navigation transaction.
    pub fn revealAndSelectExactNode(
        self: BodyController,
        cleanup: SelectionMappingCleanup,
        loaded: *LoadedDiff,
        node_index: usize,
        visible_allocator: ?std.mem.Allocator,
    ) !void {
        std.debug.assert(node_index < loaded.tree.nodes.len);
        std.debug.assert(loaded.tree.nodes[node_index].kind == .file);
        if (loaded.visibleRowOfNode(node_index) == null) {
            const allocator = visible_allocator orelse return error.MissingVisibleNodeAllocator;
            var prepared = try loaded.prepareVisibleNodeRebuild(allocator);
            file_tree.expandAncestors(&loaded.collapsed_dirs, loaded.tree.nodes[node_index].path);
            prepared.commit(
                self.controller.surface.review_display.hide_reviewed_files,
                self.controller.surface.review_display.changed_file_filter,
            );
        }

        self.selectSidebarNode(cleanup, loaded, node_index);
        self.clampSelection(loaded.document.files.len);
        self.clampDiffNavigation();
    }

    pub fn restoreReloadAnchor(
        self: BodyController,
        cleanup: SelectionMappingCleanup,
        loaded: *LoadedDiff,
        anchor: *const diff_surface.ReloadAnchor,
    ) bool {
        const selected_same_path = if (findFileNodeByPathKey(loaded, anchor.path_key)) |node_index| blk: {
            self.selectSidebarNode(cleanup, loaded, node_index);
            break :blk true;
        } else blk: {
            if (loaded.visibleNodeCount() == 0) {
                self.controller.surface.viewer.selected_target = null;
                self.controller.surface.viewer.selected_node = 0;
                self.resetDiffPosition();
                self.controller.clearSearchMatch();
                return true;
            }
            const row = @min(anchor.visible_sidebar_row, loaded.visibleNodeCount() - 1);
            if (nearestVisibleFileNode(loaded, row)) |node_index| {
                self.selectSidebarNode(cleanup, loaded, node_index);
                break :blk false;
            }
            return false;
        };

        // Directory/root selection is independent from the sticky diff body.
        // Restore it only after rebinding the body file so selecting a
        // directory cannot accidentally replace the displayed target.
        _ = self.restoreSidebarIdentity(cleanup, loaded, anchor.sidebar_identity);

        self.controller.surface.viewer.sidebar_horizontal_scroll = anchor.sidebar_horizontal_scroll;
        self.controller.surface.viewer.diff_horizontal_scroll = anchor.diff_horizontal_scroll;

        if (selected_same_path and std.meta.activeTag(self.controller.surface.viewer.selected_target.?) == anchor.selected_target_tag) {
            self.controller.surface.viewer.diff_cursor = anchor.diff_cursor;
            if (self.view().selectedDiffCursorOffset() == null) {
                if (anchor.diff_cursor_offset) |offset| {
                    self.controller.surface.viewer.diff_cursor = self.view().selectedCoordinateAtOffset(offset) orelse self.controller.surface.viewer.diff_cursor;
                }
            }
        } else if (anchor.diff_cursor_offset) |offset| {
            self.controller.surface.viewer.diff_cursor = self.view().selectedCoordinateAtOffset(offset) orelse self.controller.surface.viewer.diff_cursor;
        }

        if (self.view().selectedDiffCursorOffset() == null) {
            self.initializeDiffCursorForSelectedFile();
        }

        self.controller.surface.viewer.diff_scroll = if (anchor.selection_viewport) |selection_anchor|
            self.view().restoreSelectionViewportAnchor(selection_anchor)
        else
            anchor.diff_scroll;
        self.clampDiffNavigation();
        self.keepDiffCursorVisible();
        self.restoreSearchFromReloadAnchor(cleanup, anchor);
        self.controller.clampSidebarHorizontalScroll();
        self.clampDiffHorizontalScrollToVisibleRows();
        // Anchors address the complete tree, while root/directory disclosure
        // controls its materialized rows. Preserve the restored diff target,
        // but never leave the sidebar cursor on a hidden descendant.
        self.reconcileSelectionAfterVisibleNodeChange(cleanup, loaded);
        return true;
    }

    pub fn restoreSidebarIdentity(
        self: BodyController,
        cleanup: SelectionMappingCleanup,
        loaded: *LoadedDiff,
        identity: context.SidebarIdentity,
    ) bool {
        const node_index = findNodeBySidebarIdentity(loaded, identity) orelse return false;
        self.selectSidebarNode(cleanup, loaded, node_index);
        return true;
    }

    pub fn restoreSearchFromReloadAnchor(
        self: BodyController,
        cleanup: SelectionMappingCleanup,
        anchor: *const diff_surface.ReloadAnchor,
    ) void {
        self.controller.clearSearchMatch();
        if (self.controller.surface.search.query.len == 0) return;

        if (anchor.search_coordinate) |coordinate| {
            self.controller.surface.search.match = .{ .coordinate = coordinate };
            self.updateSearchMatchOffset();
            if (self.controller.surface.search.match != null) return;
        }

        _ = self.refreshSearchMatchForSelectedFile(cleanup);
        self.clampDiffNavigation();
        self.keepDiffCursorVisible();
    }

    pub fn toggleSidebarVisibility(self: BodyController, cleanup: SelectionMappingCleanup) void {
        const previous_width = self.controller.view().diffPaneWidth();
        const previous_mode = self.controller.view().effectiveDisplayMode();
        var prospective = self.controller.surface.viewer.*;
        prospective.sidebar_hidden = !prospective.sidebar_hidden;
        const next_mode = effectiveDisplayModeForLayout(&prospective, self.controller.surface.layout);
        const prepared = if (previous_mode != next_mode) cleanup.prepare(self) else null;
        self.controller.surface.viewer.sidebar_hidden = !self.controller.surface.viewer.sidebar_hidden;
        if (self.controller.surface.viewer.sidebar_hidden) self.controller.surface.viewer.focus = .diff;
        self.controller.resetDiffHorizontalScrollIfPaneWidthChanged(previous_width);
        if (previous_mode != self.controller.view().effectiveDisplayMode()) {
            cleanup.complete(self, prepared.?);
        }
        self.clampDiffNavigationKeepingHunkVisible();
        self.updateSearchMatchOffset();
        self.scrollSearchMatchIntoView();
        self.clampDiffNavigation();
    }

    pub fn adjustSidebarWidth(self: BodyController, cleanup: SelectionMappingCleanup, direction: SizeDirection) void {
        const total_width = self.controller.surface.layout.width;
        const previous_width = self.controller.view().diffPaneWidth();
        const previous_mode = self.controller.view().effectiveDisplayMode();
        const current = sidebarWidth(total_width, self.controller.surface.viewer.sidebar_width);
        const step: u16 = 4;
        const next = switch (direction) {
            .shrink => if (current > step) current - step else 0,
            .grow => current +| step,
        };

        var prospective = self.controller.surface.viewer.*;
        prospective.sidebar_width = sidebarWidth(total_width, next);
        const next_mode = effectiveDisplayModeForLayout(&prospective, self.controller.surface.layout);
        const prepared = if (previous_mode != next_mode) cleanup.prepare(self) else null;
        self.controller.surface.viewer.sidebar_width = sidebarWidth(total_width, next);
        self.controller.clampSidebarHorizontalScroll();
        self.controller.resetDiffHorizontalScrollIfPaneWidthChanged(previous_width);
        if (previous_mode != self.controller.view().effectiveDisplayMode()) {
            cleanup.complete(self, prepared.?);
        }
        self.clampDiffNavigationKeepingHunkVisible();
        self.updateSearchMatchOffset();
        self.scrollSearchMatchIntoView();
        self.clampDiffNavigation();
    }

    pub fn pressDiffMouse(self: BodyController, point: diff_surface.MousePoint) void {
        self.controller.surface.viewer.focus = .diff;
        const body = self.view();
        if (body.presentationCellHit(point)) |cell| switch (cell) {
            .source => |source| if (body.selectedCoordinateAtOffset(source.source_offset)) |coordinate| {
                self.controller.surface.viewer.diff_cursor = coordinate;
            },
            .card, .spacer => {},
        };
        if (body.diffHeaderMouseHit(point)) |hit| {
            self.controller.surface.selection_owner.* = .{ .diff_header = .{ .identity = hit.identity } };
            return;
        }
        const hit = body.diffMouseHit(point) orelse {
            self.controller.clearDiffSelection();
            return;
        };
        self.controller.surface.selection_owner.* = .{ .diff = diff_selection.DragSelection.initContentAtCell(
            hit.identity,
            hit.content,
            hit.point,
            .{ .col = point.col, .row = point.row },
        ) };
    }

    pub fn chooseKeyboardSelectionSide(self: BodyController, side: diff_selection.Side) bool {
        const choice = self.controller.surface.selection_owner.activeKeyboardSideChoice() orelse return false;
        const hit = self.view().keyboardSideChoiceHit(choice, side) orelse {
            self.controller.clearDiffSelection();
            return false;
        };
        self.controller.surface.selection_owner.* = .{ .diff = diff_selection.DragSelection.initContentKeyboardLine(
            hit.identity,
            hit.content,
            hit.point,
        ) };
        return true;
    }

    pub fn switchKeyboardSelectionSide(self: BodyController, side: diff_selection.Side) bool {
        const active = self.controller.surface.selection_owner.activeDiff() orelse return false;
        if (active.origin != .keyboard_line or active.selected_line_count != 1 or active.selectedSide() == side) return false;
        const offset = self.view().keyboardLineSourceOffset(active) orelse return false;
        const candidates = self.view().keyboardSideCandidatesAtOffset(offset) orelse return false;
        if (!active.identity.eql(candidates.identity)) return false;
        const candidate = (if (side == .old) candidates.before else candidates.after) orelse return false;
        self.controller.surface.selection_owner.* = .{ .diff = diff_selection.DragSelection.initKeyboardLine(
            candidates.identity,
            side,
            candidate.point,
        ) };
        self.controller.surface.viewer.diff_cursor = self.view().selectedCoordinateAtOffset(offset) orelse
            self.controller.surface.viewer.diff_cursor;
        self.keepDiffCursorVisible();
        return true;
    }

    pub fn beginKeyboardLineSelection(self: BodyController) BeginKeyboardLineSelectionTerminal {
        if (self.controller.surface.viewer.focus != .diff or self.controller.surface.selection_owner.* != .none) return .unavailable;
        if (self.view().selectedDiffCursorOffset() == null) self.initializeDiffCursorForSelectedFile();
        const current = self.view().selectedDiffCursorOffset() orelse return .unavailable;
        if (self.controller.view().effectiveDisplayMode() == .side_by_side) {
            switch (self.view().keyboardLineStartAtOffset(current)) {
                .unavailable => return .unavailable,
                .choose => |choice| {
                    self.controller.surface.selection_owner.* = .{ .keyboard_side_choice = choice };
                    return .choosing_side;
                },
                .direct => |hit| {
                    self.controller.surface.selection_owner.* = .{ .diff = diff_selection.DragSelection.initContentKeyboardLine(
                        hit.identity,
                        hit.content,
                        hit.point,
                    ) };
                    self.keepDiffCursorVisible();
                    return .started;
                },
            }
        }
        const resolved = self.view().keyboardLineHitNearOffset(current, null) orelse return .unavailable;
        self.controller.surface.selection_owner.* = .{ .diff = diff_selection.DragSelection.initContentKeyboardLine(
            resolved.hit.identity,
            resolved.hit.content,
            resolved.hit.point,
        ) };
        self.controller.surface.viewer.diff_cursor = self.view().selectedCoordinateAtOffset(resolved.source_offset) orelse
            self.controller.surface.viewer.diff_cursor;
        self.keepDiffCursorVisible();
        return .started;
    }

    pub fn moveKeyboardLineSelection(self: BodyController, direction: VerticalDirection) bool {
        const active = self.controller.surface.selection_owner.activeDiff() orelse return false;
        if (active.origin != .keyboard_line or active.selected_line_count == 0) return false;
        const current = self.view().keyboardLineSourceOffset(active) orelse return false;
        const line_count = self.view().sourceDiffLineCount();
        if (line_count == 0) return false;

        var offset = current;
        while (true) {
            offset = switch (direction) {
                .up => if (offset == 0) return false else offset - 1,
                .down => if (offset + 1 >= line_count) return false else offset + 1,
            };
            const hit = self.view().keyboardLineHitAtOffset(offset, active.selectedSide()) orelse continue;
            if (!active.identity.eql(hit.identity)) return false;
            const step = self.keyboardLineStepDistance(active, hit.point) orelse return false;
            if (step == 0) continue;
            const shrinking = switch (direction) {
                .up => active.focus.order(active.anchor) == .gt,
                .down => active.focus.order(active.anchor) == .lt,
            };
            const next_count = if (shrinking)
                active.selected_line_count -| step
            else
                active.selected_line_count +| step;
            if (next_count == 0) return false;

            switch (self.controller.surface.selection_owner.*) {
                .diff => |*selection| selection.updateKeyboardLine(hit.point, next_count),
                .none, .diff_header, .keyboard_side_choice => return false,
            }
            self.controller.surface.viewer.diff_cursor = self.view().selectedCoordinateAtOffset(offset) orelse
                self.controller.surface.viewer.diff_cursor;
            self.keepDiffCursorVisible();
            return true;
        }
    }

    fn keyboardLineStepDistance(self: BodyController, active: diff_selection.DragSelection, target: diff_selection.Point) ?usize {
        return switch (active.identity) {
            .generated_file => |generated| blk: {
                const body = self.view().generatedBody() orelse break :blk null;
                const content_valid = switch (active.content) {
                    .unified_diff => true,
                    .source_side => |source| source.side == .new,
                };
                if (!std.mem.eql(u8, generated.path_key, body.path) or !content_valid or
                    active.focus.hunk_index != 0 or target.hunk_index != 0) break :blk null;
                break :blk if (active.focus.line_index > target.line_index)
                    active.focus.line_index - target.line_index
                else
                    target.line_index - active.focus.line_index;
            },
            .loaded_file, .projection_file => blk: {
                const parsed = self.view().parsedSelectionTarget(active.identity) orelse break :blk null;
                break :blk switch (active.content) {
                    .unified_diff => diff_selection.unifiedLineDistance(parsed.file, parsed.folded_hunks, active.focus, target),
                    .source_side => |source| diff_selection.semanticLineDistance(parsed.file, source.side, active.focus, target),
                };
            },
        };
    }

    pub fn dragDiffMouse(self: BodyController, point_opt: ?diff_surface.MousePoint) void {
        const point = point_opt orelse return;
        switch (self.controller.surface.selection_owner.*) {
            .none, .keyboard_side_choice => return,
            .diff_header => |*selection| selection.update(),
            .diff => |*selection| {
                if (selection.origin != .mouse) return;
                const hit = self.view().diffMouseDragHit(point, selection.*) orelse return;
                if (!selection.identity.eql(hit.identity)) return;
                selection.updateAtCell(hit.point, .{ .col = point.col, .row = point.row });
            },
        }
    }

    /// One timer-owned semantic drag step. Scrolling is committed before the
    /// endpoint is re-hit-tested so the updated endpoint always comes from
    /// selectable source content.
    pub fn autoScrollDiffMouse(self: BodyController, step: drag_auto_scroll.Step) drag_auto_scroll.StepOutcome {
        const drag = self.controller.surface.selection_owner.activeDiff() orelse {
            self.controller.clearDiffSelection();
            return .stale_owner;
        };
        if (drag.origin != .mouse) return .stale_owner;
        if (!self.view().dragSelectionIdentityCurrent(drag)) {
            self.controller.clearDiffSelection();
            return .stale_owner;
        }

        const old_scroll = self.controller.surface.viewer.diff_scroll;
        self.scrollDiffWithOrigin(if (step.direction == .up) .up else .down, .drag);
        if (self.controller.surface.viewer.diff_scroll == old_scroll) return .content_edge;

        const endpoint: diff_surface.MousePoint = .{
            .col = step.endpoint.col,
            .row = step.endpoint.row,
        };
        if (self.view().selectionActionHit(endpoint) != null) return .moved;
        const hit = self.view().diffMouseDragHit(endpoint, drag) orelse return .moved;
        if (!drag.identity.eql(hit.identity)) {
            self.controller.clearDiffSelection();
            return .stale_owner;
        }
        switch (self.controller.surface.selection_owner.*) {
            .diff => |*selection| selection.updateAtCell(
                hit.point,
                .{ .col = endpoint.col, .row = endpoint.row },
            ),
            .none, .diff_header, .keyboard_side_choice => {
                self.controller.clearDiffSelection();
                return .stale_owner;
            },
        }
        return .moved;
    }

    /// Body navigation follows eligible file nodes, independently of the tree
    /// cursor, directory disclosure, and the currently loaded body content.
    pub fn selectAdjacentFile(self: BodyController, cleanup: SelectionMappingCleanup, delta: i2) !void {
        if (self.controller.surface.viewer.focus != .diff or self.controller.surface.selection_owner.* != .none) return;
        const loaded = self.controller.activeLoadedDiff() orelse return;
        const selected = self.controller.surface.viewer.selected_target orelse return;
        const sidebar_target: context.SidebarTarget = switch (selected) {
            .diff_file => |index| .{ .diff_file = index },
            .status_only => |index| .{ .status_entry = index },
        };
        const origin = for (loaded.tree.nodes, 0..) |node, index| {
            if (node.kind == .file and std.meta.eql(node.target, sidebar_target)) break index;
        } else return;
        const display = self.controller.surface.review_display;
        if (!loaded.shouldIncludeFileNode(origin, display.hide_reviewed_files, display.changed_file_filter)) return;

        var index = origin;
        const destination = while (true) {
            if (delta < 0) {
                if (index == 0) return;
                index -= 1;
            } else {
                index += 1;
                if (index >= loaded.tree.nodes.len) return;
            }
            if (loaded.tree.nodes[index].kind == .file and
                loaded.shouldIncludeFileNode(index, display.hide_reviewed_files, display.changed_file_filter)) break index;
        };

        // Finish the only fallible preparation before clearing any retained
        // selection or search. The ordinary reveal then needs no allocation.
        if (loaded.visibleRowOfNode(destination) == null) {
            const allocator = self.controller.loadArenaAllocator() orelse return error.MissingVisibleNodeAllocator;
            var prepared = try loaded.prepareVisibleNodeRebuild(allocator);
            file_tree.expandAncestors(&loaded.collapsed_dirs, loaded.tree.nodes[destination].path);
            prepared.commit(display.hide_reviewed_files, display.changed_file_filter);
        }
        self.controller.clearCompletedSelectionWithViewport(self.resolver, cleanup.allocator);
        if (cleanup.residual_owner) |owner| owner.clear();
        self.controller.clearSearch();
        try self.revealAndSelectExactNode(cleanup, loaded, destination, self.controller.loadArenaAllocator());
        self.resetDiffPosition();
        self.controller.resetDiffHorizontalScroll();
    }

    pub fn selectFileDelta(self: BodyController, cleanup: SelectionMappingCleanup, delta: i2) void {
        const loaded = self.controller.activeLoadedDiff() orelse return;
        if (loaded.tree.nodes.len == 0 or loaded.visibleNodeCount() == 0) return;

        if (delta < 0) {
            if (loaded.previousVisibleNodeIndex(self.controller.surface.viewer.selected_node)) |previous| {
                self.selectSidebarNode(cleanup, loaded, previous);
            }
        } else if (loaded.nextVisibleNodeIndex(self.controller.surface.viewer.selected_node)) |next| {
            self.selectSidebarNode(cleanup, loaded, next);
        }
        self.clampSelection(loaded.document.files.len);
        self.clampDiffNavigation();
    }

    pub fn selectFileAbsolute(self: BodyController, cleanup: SelectionMappingCleanup, index: usize) void {
        const file_count = self.controller.view().loadedFileCount() orelse return;
        if (file_count == 0) return;
        const target = @min(index, file_count - 1);
        if (self.controller.view().selectedDiffFileTarget() == target) {
            if (self.controller.activeLoadedDiff()) |loaded| {
                self.controller.syncSidebarNodeToSelectedFile(loaded);
            }
            self.clampSelection(file_count);
            return;
        }
        self.controller.setSelectedDiffFile(target);
        if (self.controller.activeLoadedDiff()) |loaded| {
            self.controller.syncSidebarNodeToSelectedFile(loaded);
        }
        self.resetDiffPosition();
        self.refreshSearchForSelectedFile(cleanup);
        self.clampSelection(file_count);
        self.clampDiffNavigation();
    }

    pub fn selectLastFile(self: BodyController, cleanup: SelectionMappingCleanup) void {
        const file_count = self.controller.view().loadedFileCount() orelse return;
        if (file_count == 0) return;
        self.selectFileAbsolute(cleanup, file_count - 1);
    }

    pub fn selectSidebarNode(
        self: BodyController,
        cleanup: SelectionMappingCleanup,
        loaded: *LoadedDiff,
        node_index: usize,
    ) void {
        if (node_index >= loaded.tree.nodes.len) return;
        const previous_file = self.controller.view().selectedDiffFileTarget();
        self.controller.surface.viewer.selected_node = node_index;
        // File rows change the active diff pane file. Directory rows only move
        // the sidebar cursor and keep the previous selected target visible.
        switch (loaded.tree.nodes[node_index].target) {
            .diff_file => |file_index| {
                self.controller.setSelectedDiffFile(file_index);
                if (previous_file == null or file_index != previous_file.?) {
                    self.resetDiffPosition();
                    self.refreshSearchForSelectedFile(cleanup);
                }
            },
            .status_entry => |status_index| {
                self.controller.clearDiffSelection();
                self.controller.surface.viewer.selected_target = .{ .status_only = status_index };
                self.resetDiffPosition();
                self.controller.clearSearchMatch();
            },
            .repo_root, .directory => {},
        }
    }

    pub fn toggleSelectedDirectory(self: BodyController) !void {
        const loaded = self.controller.activeLoadedDiff() orelse return;
        if (self.controller.surface.viewer.selected_node >= loaded.tree.nodes.len) return;
        const node = loaded.tree.nodes[self.controller.surface.viewer.selected_node];
        if (node.kind != .directory) return;
        const allocator = self.controller.loadArenaAllocator() orelse return;
        var prepared = try loaded.prepareVisibleNodeRebuild(allocator);
        try file_tree.toggle(allocator, &loaded.collapsed_dirs, node.path);
        prepared.commit(
            self.controller.surface.review_display.hide_reviewed_files,
            self.controller.surface.review_display.changed_file_filter,
        );
        self.clampSelection(loaded.document.files.len);
        self.controller.clampSidebarHorizontalScroll();
    }

    pub fn clickSidebarNode(self: BodyController, cleanup: SelectionMappingCleanup, node_index: usize) !void {
        if (self.controller.surface.viewer.sidebar_hidden) return;
        const loaded = self.controller.activeLoadedDiff() orelse return;
        if (node_index >= loaded.tree.nodes.len) return;

        _ = self.controller.focusSidebar();
        self.selectSidebarNode(cleanup, loaded, node_index);

        const node = loaded.tree.nodes[node_index];
        if (node.kind == .directory) try self.toggleSelectedDirectory();

        self.clampSelection(loaded.document.files.len);
        self.clampDiffNavigation();
    }

    pub fn expandSelectedDirectory(self: BodyController) !void {
        const loaded = self.controller.activeLoadedDiff() orelse return;
        if (self.controller.surface.viewer.selected_node >= loaded.tree.nodes.len) return;
        const node = loaded.tree.nodes[self.controller.surface.viewer.selected_node];
        switch (node.kind) {
            .directory => if (!file_tree.isCollapsed(&loaded.collapsed_dirs, node.path)) return,
            .repo_root, .file => return,
        }
        const allocator = self.controller.loadArenaAllocator() orelse return;
        var prepared = try loaded.prepareVisibleNodeRebuild(allocator);
        file_tree.expand(&loaded.collapsed_dirs, node.path);
        prepared.commit(
            self.controller.surface.review_display.hide_reviewed_files,
            self.controller.surface.review_display.changed_file_filter,
        );
        self.clampSelection(loaded.document.files.len);
        self.controller.clampSidebarHorizontalScroll();
    }

    pub fn collapseOrSelectParentDirectory(self: BodyController) !void {
        const loaded = self.controller.activeLoadedDiff() orelse return;
        if (self.controller.surface.viewer.selected_node >= loaded.tree.nodes.len) return;
        const node = loaded.tree.nodes[self.controller.surface.viewer.selected_node];
        if (node.kind == .directory and !file_tree.isCollapsed(&loaded.collapsed_dirs, node.path)) {
            const allocator = self.controller.loadArenaAllocator() orelse return;
            var prepared = try loaded.prepareVisibleNodeRebuild(allocator);
            try file_tree.collapse(allocator, &loaded.collapsed_dirs, node.path);
            prepared.commit(
                self.controller.surface.review_display.hide_reviewed_files,
                self.controller.surface.review_display.changed_file_filter,
            );
            self.clampSelection(loaded.document.files.len);
            self.controller.clampSidebarHorizontalScroll();
            return;
        }
        if (loaded.tree.parentDirectoryNodeIndex(self.controller.surface.viewer.selected_node)) |parent| {
            self.controller.surface.viewer.selected_node = parent;
            self.clampSelection(loaded.document.files.len);
        }
    }

    pub fn scrollDiff(self: BodyController, direction: VerticalDirection) void {
        self.scrollDiffWithOrigin(direction, .pointer);
    }

    fn scrollDiffWithOrigin(self: BodyController, direction: VerticalDirection, origin: enum { pointer, drag }) void {
        const bounds = self.diffCursorBounds();
        const old_scroll = bounds.clampScroll(self.controller.surface.viewer.diff_scroll);
        const old_cursor_offset = self.view().selectedDiffCursorPresentationOffset();
        const requested_scroll = switch (direction) {
            .up => old_scroll -| 1,
            .down => old_scroll +| 1,
        };
        const new_scroll = bounds.clampScroll(requested_scroll);
        self.controller.surface.viewer.diff_scroll = new_scroll;
        if (bounds.visible_rows == 0) return;
        if (old_scroll == new_scroll) {
            if (origin == .drag or self.controller.surface.selection_owner.activeKeyboardLineSelection()) return;
            // Step source ordinals, skipping inserted presentation-only rows.
            const cursor = self.view().selectedDiffCursorOffset() orelse return;
            const rows = self.view().sourceDiffLineCount();
            if (rows == 0) return;
            const target = switch (direction) {
                .up => cursor -| 1,
                .down => @min(cursor +| 1, rows - 1),
            };
            self.controller.surface.viewer.diff_cursor = self.view().selectedCoordinateAtOffset(target) orelse
                self.controller.surface.viewer.diff_cursor;
            return;
        }

        const target = cursor_viewport.retargetCursorAfterViewportScroll(
            bounds,
            old_scroll,
            new_scroll,
            old_cursor_offset,
        ) orelse return;
        self.controller.surface.viewer.diff_cursor = self.view().selectedCoordinateAtPresentationOffset(target) orelse
            self.controller.surface.viewer.diff_cursor;
    }

    pub fn scrollDiffHorizontal(self: BodyController, direction: HorizontalDirection) void {
        const step: usize = 8;
        switch (direction) {
            .left => self.controller.surface.viewer.diff_horizontal_scroll -|= step,
            .right => self.controller.surface.viewer.diff_horizontal_scroll += step,
        }
        self.clampDiffHorizontalScrollToVisibleRows();
    }

    pub fn clampDiffHorizontalScrollToVisibleRows(self: BodyController) void {
        const max_scroll = self.view().visibleBodyTextMaxHorizontalScroll();
        if (self.controller.surface.viewer.diff_horizontal_scroll > max_scroll) {
            self.controller.surface.viewer.diff_horizontal_scroll = max_scroll;
        }
    }

    pub fn moveDiffCursorRows(self: BodyController, direction: VerticalDirection) void {
        const current = self.view().selectedDiffCursorOffset() orelse {
            self.initializeDiffCursorForSelectedFile();
            self.placeDiffCursorInComfortBand();
            return;
        };
        const line_count = self.view().sourceDiffLineCount();
        if (line_count == 0) return;
        const target = switch (direction) {
            .up => current -| 1,
            .down => @min(current +| 1, line_count - 1),
        };
        self.controller.surface.viewer.diff_cursor = self.view().selectedCoordinateAtOffset(target) orelse self.controller.surface.viewer.diff_cursor;
        self.placeDiffCursorInComfortBand();
    }

    pub fn moveDiffCursorFirst(self: BodyController) void {
        self.moveDiffCursorToDocumentEdge(false);
    }

    pub fn moveDiffCursorLast(self: BodyController) void {
        self.moveDiffCursorToDocumentEdge(true);
    }

    pub fn moveDiffCursorHalfPage(self: BodyController, direction: VerticalDirection) void {
        const step = @max(self.controller.view().diffVisibleRows() / 2, 1);
        self.moveDiffCursorByDocumentStep(direction, step);
    }

    pub fn moveDiffCursorPage(self: BodyController, direction: VerticalDirection) void {
        const step = @max(self.controller.view().diffVisibleRows(), 1);
        self.moveDiffCursorByDocumentStep(direction, step);
    }

    fn moveDiffCursorToDocumentEdge(self: BodyController, last: bool) void {
        const line_count = self.documentNavigationLineCount() orelse return;
        const target = if (last) line_count - 1 else 0;
        self.commitDocumentNavigation(target);
    }

    fn moveDiffCursorByDocumentStep(self: BodyController, direction: VerticalDirection, step: usize) void {
        const line_count = self.documentNavigationLineCount() orelse return;
        const current = self.view().selectedDiffCursorOffset();
        const target = if (current) |offset| switch (direction) {
            .up => offset -| step,
            .down => @min(offset +| step, line_count - 1),
        } else 0;
        self.commitDocumentNavigation(target);
    }

    fn documentNavigationLineCount(self: BodyController) ?usize {
        const body = self.view();
        switch (body.resolvedTarget().kind) {
            .none, .inert => return null,
            .primary, .projected => {},
        }
        if (body.displayedDiffFile()) |file| if (file.is_binary) return null;
        const line_count = body.sourceDiffLineCount();
        return if (line_count == 0) null else line_count;
    }

    fn commitDocumentNavigation(self: BodyController, target: usize) void {
        const coordinate = self.view().selectedCoordinateAtOffset(target) orelse return;
        self.controller.surface.viewer.diff_cursor = coordinate;
        self.centerDiffCursor();
    }

    pub fn selectHunkDelta(self: BodyController, delta: i2) void {
        if (!self.view().bodyAllowsHunkInteraction()) return;
        const file = self.view().displayedDiffFile() orelse return;
        if (file.hunks.len == 0) return;

        const current = self.view().selectedHunkIndex();
        const target = if (delta < 0) blk: {
            if (current) |hunk_index| {
                if (self.controller.surface.viewer.diff_cursor == .hunk_line) break :blk hunk_index;
                break :blk hunk_index -| 1;
            }
            break :blk 0;
        } else blk: {
            if (current) |hunk_index| break :blk @min(hunk_index + 1, file.hunks.len - 1);
            break :blk 0;
        };
        self.controller.surface.viewer.diff_cursor = .{ .hunk_header = target };
        self.placeDiffCursorInComfortBand();
    }

    pub fn toggleSelectedHunkFold(self: BodyController, cleanup: SelectionMappingCleanup) void {
        if (!self.view().bodyAllowsHunkFold()) return;
        const loaded = self.controller.activeLoadedDiff() orelse return;
        const file_index = self.controller.view().selectedFileIndex(loaded) orelse return;
        if (file_index >= loaded.document.files.len) return;
        const file = loaded.document.files[file_index];
        const hunk_index = self.view().selectedHunkIndex() orelse return;
        if (hunk_index >= file.hunks.len) return;

        if (!loaded.isHunkFolded(file_index, hunk_index) and
            self.controller.view().currentSearchMatchInHunkBody(hunk_index))
        {
            return;
        }

        const prepared = cleanup.prepare(self);
        const folding = !loaded.isHunkFolded(file_index, hunk_index);
        loaded.toggleHunkFold(file_index, hunk_index);
        if (folding) {
            switch (self.controller.surface.viewer.diff_cursor) {
                .hunk_line => |line| if (line.hunk_index == hunk_index) {
                    self.controller.surface.viewer.diff_cursor = .{ .hunk_header = hunk_index };
                },
                else => {},
            }
        }
        self.updateSearchMatchOffset();
        cleanup.complete(self, prepared);
        self.keepDiffCursorVisible();
    }

    pub fn clampDiffNavigation(self: BodyController) void {
        if (self.view().resolvedTarget().kind == .inert) {
            self.controller.surface.viewer.diff_cursor = .{ .metadata = 0 };
            self.controller.surface.viewer.diff_scroll = 0;
            self.controller.surface.viewer.diff_horizontal_scroll = 0;
            return;
        }
        const bounds = self.diffCursorBounds();
        if (bounds.content_rows > 0 and self.view().selectedDiffCursorOffset() == null) {
            self.initializeDiffCursorForSelectedFile();
        }
        self.controller.surface.viewer.diff_scroll = bounds.clampScroll(self.controller.surface.viewer.diff_scroll);
    }

    pub fn clampDiffNavigationKeepingHunkVisible(self: BodyController) void {
        self.clampDiffNavigation();
        self.keepDiffCursorVisible();
    }

    pub fn resetDiffPosition(self: BodyController) void {
        self.controller.surface.viewer.diff_scroll = 0;
        self.initializeDiffCursorForSelectedFile();
        self.controller.clearSearchMatch();
    }

    pub fn enterSearchMode(self: BodyController) void {
        if (self.blockUnsupportedSearchTarget()) return;
        self.controller.clearMouseDiffSelection();
        self.controller.surface.search.input = self.controller.surface.search.query;
        self.controller.surface.search.mode = true;
    }

    pub fn submitSearch(self: BodyController, cleanup: SelectionMappingCleanup) void {
        self.controller.surface.search.mode = false;
        if (self.blockUnsupportedSearchTarget()) return;
        self.controller.surface.search.query = self.controller.surface.search.input;
        self.controller.clearSearchMatch();
        if (self.controller.surface.search.query.len == 0) return;
        self.selectSearchMatch(cleanup, .forward);
    }

    pub fn selectSearchMatch(
        self: BodyController,
        cleanup: SelectionMappingCleanup,
        direction: diff_search.Direction,
    ) void {
        if (self.blockUnsupportedSearchTarget()) return;
        const mode = self.controller.view().effectiveDisplayMode();
        const target = self.view().displayedSearchTarget(mode) orelse return;
        if (self.controller.surface.search.query.len == 0) return;

        const line_count = target.line_index.lineCount();
        if (line_count == 0) return;
        const base = if (self.controller.surface.search.match) |match| match.coordinate else null;
        const next = diff_search.findMatch(target.file, mode, self.controller.surface.search.query.slice(), base, direction) orelse {
            self.controller.clearSearchMatch();
            return;
        };
        self.unfoldSearchMatchIfNeeded(cleanup, next);
        self.setSearchMatch(next);
        self.controller.surface.viewer.diff_cursor = next.coordinate;
        self.controller.resetDiffHorizontalScroll();
        self.placeDiffCursorInComfortBand();
    }

    pub fn refreshSearchForSelectedFile(self: BodyController, cleanup: SelectionMappingCleanup) void {
        const next = self.refreshSearchMatchForSelectedFile(cleanup) orelse return;
        self.controller.surface.viewer.diff_cursor = next.coordinate;
        self.placeDiffCursorInComfortBand();
    }

    fn refreshSearchMatchForSelectedFile(
        self: BodyController,
        cleanup: SelectionMappingCleanup,
    ) ?diff_search.Match {
        self.controller.clearSearchMatch();
        if (self.controller.surface.search.query.len == 0) return null;
        if (self.view().unsupportedSearchMessage() != null) return null;
        const mode = self.controller.view().effectiveDisplayMode();
        const target = self.view().displayedSearchTarget(mode) orelse return null;
        const next = diff_search.findMatch(target.file, mode, self.controller.surface.search.query.slice(), null, .forward) orelse return null;
        self.unfoldSearchMatchIfNeeded(cleanup, next);
        self.setSearchMatch(next);
        return next;
    }

    pub fn setSearchMatch(self: BodyController, match: diff_search.Match) void {
        self.controller.surface.search.match = match;
        self.updateSearchMatchOffset();
    }

    pub fn updateSearchMatchOffset(self: BodyController) void {
        self.controller.surface.search.match_offset = null;
        if (self.view().unsupportedSearchMessage() != null) {
            self.controller.clearSearchMatch();
            return;
        }
        const match = self.controller.surface.search.match orelse return;
        const mode = self.controller.view().effectiveDisplayMode();
        const target = self.view().displayedSearchTarget(mode) orelse {
            self.controller.clearSearchMatch();
            return;
        };
        const offset = diff_view_model.renderedOffsetForCoordinate(target.file, mode, match.coordinate, target.folded_hunks, target.line_index) orelse {
            self.controller.clearSearchMatch();
            return;
        };
        self.controller.surface.search.match_offset = offset;
    }

    pub fn blockUnsupportedSearchTarget(self: BodyController) bool {
        if (self.view().unsupportedSearchMessage()) |message| {
            self.controller.clearSearchMatch();
            self.controller.setStatus("{s}", .{message});
            return true;
        }
        return false;
    }

    pub fn unfoldSearchMatchIfNeeded(
        self: BodyController,
        cleanup: SelectionMappingCleanup,
        match: diff_search.Match,
    ) void {
        if (self.view().resolvedTarget().search_unfold_policy == .suppressed) return;

        const hunk_index = switch (match.coordinate) {
            .hunk_line => |line| line.hunk_index,
            else => return,
        };
        const loaded = self.controller.activeLoadedDiff() orelse return;
        const file_index = self.controller.view().selectedFileIndex(loaded) orelse return;
        if (!loaded.isHunkFolded(file_index, hunk_index)) return;
        const prepared = cleanup.prepare(self);
        loaded.setHunkFolded(file_index, hunk_index, false);
        cleanup.complete(self, prepared);
    }

    pub fn keepDiffCursorVisible(self: BodyController) void {
        const offset = self.view().selectedDiffCursorPresentationOffset() orelse return;
        self.controller.surface.viewer.diff_scroll = cursor_viewport.keepCursorVisible(
            self.diffCursorBounds(),
            self.controller.surface.viewer.diff_scroll,
            offset,
        );
    }

    pub fn clampSelection(self: BodyController, file_count: usize) void {
        if (file_count == 0) {
            if (self.controller.activeLoadedDiff()) |loaded| {
                if (loaded.tree.nodes.len > 0) {
                    self.controller.surface.viewer.selected_node = @min(self.controller.surface.viewer.selected_node, loaded.tree.nodes.len - 1);
                    const node = loaded.tree.nodes[self.controller.surface.viewer.selected_node];
                    self.controller.surface.viewer.selected_target = switch (node.target) {
                        .status_entry => |status_index| .{ .status_only = status_index },
                        .diff_file => |file_index| .{ .diff_file = file_index },
                        .repo_root, .directory => self.controller.surface.viewer.selected_target,
                    };
                    return;
                }
            }
            self.controller.surface.viewer.selected_target = null;
            self.controller.surface.viewer.selected_node = 0;
            return;
        }
        if (self.controller.surface.viewer.selected_target) |target| {
            switch (target) {
                .diff_file => |file_index| if (file_index >= file_count) {
                    self.controller.setSelectedDiffFile(file_count - 1);
                },
                .status_only => |status_index| if (status_index >= self.view().resolvedTarget().status_rows) {
                    self.controller.setSelectedDiffFile(file_count - 1);
                },
            }
        } else {
            self.controller.setSelectedDiffFile(file_count - 1);
        }
        if (self.controller.activeLoadedDiff()) |loaded| {
            if (self.controller.surface.viewer.selected_node >= loaded.tree.nodes.len) {
                self.controller.syncSidebarNodeToSelectedFile(loaded);
            }
            if (loaded.visibleAncestorOrSelf(self.controller.surface.viewer.selected_node)) |visible_node| {
                self.controller.surface.viewer.selected_node = visible_node;
            } else if (self.controller.view().selectedFileIndex(loaded)) |file_index| {
                if (loaded.tree.selectedNodeIndex(file_index)) |file_node| {
                    self.controller.surface.viewer.selected_node = file_node;
                }
            }
        }
    }

    pub fn reconcileSelectionAfterVisibleNodeChange(
        self: BodyController,
        cleanup: SelectionMappingCleanup,
        loaded: *LoadedDiff,
    ) void {
        if (loaded.visibleRowOfNode(self.controller.surface.viewer.selected_node) != null) return;

        if (loaded.firstVisibleFileNode()) |file_node| {
            self.selectSidebarNode(cleanup, loaded, file_node);
            return;
        }

        if (loaded.visibleAncestorOrSelf(self.controller.surface.viewer.selected_node)) |visible_node| {
            self.selectSidebarNode(cleanup, loaded, visible_node);
            return;
        }

        if (loaded.visibleNodeAt(0)) |node_index| {
            self.controller.surface.viewer.selected_node = node_index;
        }
    }

    pub fn selectFirstVisibleFile(
        self: BodyController,
        cleanup: SelectionMappingCleanup,
        loaded: *LoadedDiff,
    ) void {
        if (loaded.firstVisibleFileNode()) |node_index| {
            self.selectSidebarNode(cleanup, loaded, node_index);
            return;
        }
        // Empty or fully filtered trees keep the existing fallback selection.
        self.controller.syncSidebarNodeToSelectedFile(loaded);
    }

    pub fn initializeDiffCursorForSelectedFile(self: BodyController) void {
        self.controller.surface.viewer.diff_cursor = self.view().selectedCoordinateAtOffset(0) orelse .{ .metadata = 0 };
    }

    fn diffCursorBounds(self: BodyController) cursor_viewport.Bounds {
        return .{
            .content_rows = self.view().presentationDiffLineCount(),
            .visible_rows = self.controller.view().diffVisibleRows(),
        };
    }

    pub fn placeDiffCursorInComfortBand(self: BodyController) void {
        const cursor_offset = self.view().selectedDiffCursorPresentationOffset() orelse {
            self.clampDiffNavigation();
            return;
        };
        self.controller.surface.viewer.diff_scroll = cursor_viewport.placeCursorInComfortBand(
            self.diffCursorBounds(),
            self.controller.surface.viewer.diff_scroll,
            cursor_offset,
        );
    }

    pub fn centerDiffCursor(self: BodyController) void {
        const cursor_offset = self.view().selectedDiffCursorPresentationOffset() orelse {
            self.clampDiffNavigation();
            return;
        };
        self.controller.surface.viewer.diff_scroll = cursor_viewport.centerCursor(
            self.diffCursorBounds(),
            self.controller.surface.viewer.diff_scroll,
            cursor_offset,
        );
    }
};

/// Converts projection-owned index membership into the renderer's explicit
/// per-hunk contract.
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

pub fn parsedMouseLine(
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
            if (!diff_selection.lineSelectableInUnified(line)) return null;
            if (locked) |selection| if (selection.content != .unified_diff) return null;
            const line_index = rows.currentUnifiedLineIndex() orelse return null;
            break :blk .{ .hunk_index = hunk_index, .line_index = line_index, .line = line, .region = null };
        },
        .side_by_side => blk: {
            const indexed = rows.currentSideBySideRow() orelse return null;
            const geometry = diff_render.sideBySideGeometry(body_width);
            const side = geometry.sideAt(body_col) orelse return null;
            if (locked) |selection| {
                const source = selection.sourceSide() orelse return null;
                if (source.side != side) return null;
            }
            const side_region = switch (side) {
                .old => geometry.old,
                .new => geometry.new,
            };
            const local_col = body_col - side_region.col;
            const text_col = diff_render.lineTextStart(line_numbers, .side_by_side);
            const mode: diff_selection.Mode = if (locked) |selection| selection.mode() else if (local_col < text_col) .line else .character;
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

pub fn indexedLineForSide(row: diff_view_model.SideBySideIndexedRow, side: diff_selection.Side) ?diff_view_model.IndexedDiffLine {
    return switch (row) {
        .single => |line| if (diff_selection.lineVisibleOnSide(line.line, side)) line else null,
        .paired => |pair| switch (side) {
            .old => pair.removed,
            .new => pair.added,
        },
    };
}

fn keyboardSideCandidate(
    row: diff_view_model.SideBySideIndexedRow,
    hunk_index: usize,
    side: diff_selection.Side,
) ?KeyboardSideCandidate {
    const indexed = indexedLineForSide(row, side) orelse return null;
    return .{
        .point = diff_selection.pointFromLine(hunk_index, indexed.line_index),
        .text = indexed.line.text,
    };
}

fn keyboardCandidateHit(
    identity: diff_selection.Identity,
    side: diff_selection.Side,
    candidate: KeyboardSideCandidate,
) diff_surface.DiffMouseHit {
    return .{
        .identity = identity,
        .content = .{ .source_side = .{ .side = side } },
        .point = candidate.point,
    };
}

pub fn selectionRegionForGenerated(body_col: u16, body_width: u16, display_mode: diff_render.DisplayMode, line_numbers: bool, locked: ?diff_selection.DragSelection) ?SelectionRegion {
    if (display_mode != .side_by_side) return null;
    if (locked) |selection| {
        const source = selection.sourceSide() orelse return null;
        if (source.side != .new) return null;
    }
    const local_col = switch (display_mode) {
        .unified => unreachable,
        .side_by_side => blk: {
            const geometry = diff_render.sideBySideGeometry(body_width);
            if (geometry.sideAt(body_col) != .new) return null;
            break :blk body_col - geometry.new.col;
        },
    };
    const text_col = diff_render.lineTextStart(line_numbers, if (display_mode == .unified) .unified else .side_by_side);
    const mode: diff_selection.Mode = if (locked) |selection| selection.mode() else if (local_col < text_col) .line else .character;
    return .{
        .side = .new,
        .mode = mode,
        .text_cell = if (local_col > text_col) local_col - text_col else 0,
        .leading_boundary = locked != null and mode == .character and local_col < text_col,
    };
}

pub fn pointForTextCell(hunk_index: usize, line_index: usize, text: []const u8, mode: diff_selection.Mode, horizontal_scroll: usize, viewport_cell: usize) ?diff_selection.Point {
    if (mode == .line) return diff_selection.pointFromLine(hunk_index, line_index);
    const projection = text_projection.Projection.init(text, .{ .tab_width = review_tab_width }) catch return null;
    return switch (projection.hitViewportCell(horizontal_scroll, viewport_cell)) {
        .token => |token| diff_selection.pointFromToken(hunk_index, line_index, token),
        .boundary => |boundary| diff_selection.pointFromBoundary(hunk_index, line_index, boundary.byte_offset),
    };
}

pub fn contentWidth(width: u16) u16 {
    return layout.diffContentWidth(width);
}

pub fn diffPaneWidthForLayout(viewer: *const diff_surface.ViewerState, surface_layout: diff_surface.Layout) u16 {
    const width = surface_layout.width;
    if (viewer.sidebar_hidden) return contentWidth(width);
    const sidebar_width = sidebarWidth(width, viewer.sidebar_width);
    if (width <= sidebar_width + 1) return 0;
    return contentWidth(width - sidebar_width - 1);
}

pub fn effectiveDisplayModeForLayout(viewer: *const diff_surface.ViewerState, surface_layout: diff_surface.Layout) diff_render.DisplayMode {
    return diff_render.effectiveMode(
        diff_render.bodyWidth(diffPaneWidthForLayout(viewer, surface_layout)),
        viewer.display_mode,
    );
}

pub fn sidebarWidth(total_width: u16, preferred_width: ?u16) u16 {
    return layout.sidebarWidth(total_width, preferred_width);
}

pub fn maxHorizontalScrollForBodyRow(body_row: diff_view_model.BodyRow, body_width: u16, line_numbers: bool) usize {
    return switch (body_row) {
        .unified_line => |line| maxHorizontalScrollForText(line.text, visibleTextWidth(body_width, diff_render.lineTextStart(line_numbers, .unified))),
        .side_by_side => |side_row| maxHorizontalScrollForSideBySideRow(side_row, body_width, line_numbers),
        else => 0,
    };
}

pub fn maxHorizontalScrollForSideBySideRow(side_row: diff_view_model.SideBySideRow, body_width: u16, line_numbers: bool) usize {
    const geometry = diff_render.sideBySideGeometry(body_width);
    const text_col = diff_render.lineTextStart(line_numbers, .side_by_side);
    const old_text_width: u16 = visibleTextWidth(geometry.old.width, text_col);
    const new_text_width: u16 = visibleTextWidth(geometry.new.width, text_col);
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

pub fn visibleTextWidth(total_width: u16, text_col: u16) u16 {
    return if (total_width > text_col) total_width - text_col else 0;
}

pub fn maxHorizontalScrollForText(text: []const u8, visible_width: u16) usize {
    const projection = text_projection.Projection.init(text, .{ .tab_width = review_tab_width }) catch return 0;
    const width = projection.displayWidth();
    if (width <= visible_width) return 0;
    return width - visible_width;
}
