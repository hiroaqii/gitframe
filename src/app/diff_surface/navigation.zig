//! Page-independent diff navigation model helpers.
//!
//! Pages retain their public `View` / `Controller` shapes and delegate these
//! pure operations through compatibility adapters. This module must not import
//! a page namespace.

const std = @import("std");
const layout = @import("layout.zig");
const diff_surface = @import("../diff_surface.zig");
const app_direction = @import("../direction.zig");
const file_search = diff_surface.file_search;
const context = @import("../../context.zig");
const diff_file = @import("../../diff/file.zig");
const diff_hunk_projection = @import("../../diff/hunk_projection.zig");
const diff_parser = @import("../../diff/parser.zig");
const diff_render = @import("../../diff/render.zig");
const diff_selection = @import("../../diff/selection.zig");
const diff_view_model = @import("../../diff/view_model.zig");
const file_tree = @import("../../file_tree.zig");
const loaded_diff = @import("../../loaded_diff.zig");
const sidebar_view_model = @import("../../sidebar/view_model.zig");
const text_projection = @import("../../text/projection.zig");

const LoadedDiff = loaded_diff.LoadedDiff;
const HorizontalDirection = app_direction.Horizontal;

pub const ParsedSelectionTarget = diff_surface.body_resolver.ParsedSelectionTarget;

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
    region: SelectionRegion,
};

/// Short-lived read-only facade over one page's shared diff surface.
///
/// The pointer bundle remains owned by the page and is rebuilt for every
/// delegated call. Methods in this view must not mutate the pointed-to state.
pub const View = struct {
    surface: diff_surface.ReadSurface,
    repo_root: ?[]const u8,

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
            max_scroll = @max(max_scroll, sidebar_view_model.maxHorizontalScroll(row, width));
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
        return diff_render.effectiveMode(diff_render.bodyWidth(self.diffPaneWidth()), self.surface.viewer.display_mode);
    }

    pub fn diffVisibleRows(self: View) usize {
        return diff_render.visibleBodyRows(self.surface.layout.height);
    }

    pub fn diffPaneWidth(self: View) u16 {
        const width = self.surface.layout.width;
        if (self.surface.viewer.sidebar_hidden) return contentWidth(width);
        const sidebar_width = sidebarWidth(width, self.surface.viewer.sidebar_width);
        if (width <= sidebar_width + 1) return 0;
        return contentWidth(width - sidebar_width - 1);
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
        return self.resolver.displayedDiffLineCount();
    }

    pub fn hunkStagePresentation(self: BodyView, allocator: std.mem.Allocator, file_index: usize) !diff_render.HunkStagePresentation {
        return self.resolver.hunkStagePresentation(allocator, file_index);
    }

    pub fn diffSelectionView(self: BodyView) ?diff_selection.View {
        const drag = self.view.surface.selection_owner.activeDiff() orelse return null;
        switch (drag.identity) {
            .generated_file => |generated| {
                const body = self.generatedBody() orelse return null;
                if (!std.mem.eql(u8, generated.path_key, body.path)) return null;
            },
            .loaded_file, .projection_file => _ = self.parsedSelectionTarget(drag.identity) orelse return null,
        }
        return drag.view();
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
            return diff_render.generatedHeaderLayout(content_width, display_path, body.source.contentLineCount(), self.view.surface.viewer.display_mode, mode_width);
        }
        const file = self.displayedDiffFile() orelse return null;
        return diff_render.fileHeaderLayout(content_width, display_path, file, self.view.surface.viewer.display_mode, mode_width);
    }

    pub fn diffMouseHit(self: BodyView, point: diff_surface.MousePoint) ?diff_surface.DiffMouseHit {
        return self.diffMouseHitLocked(point, null);
    }

    pub fn diffMouseDragHit(self: BodyView, point: diff_surface.MousePoint, drag: diff_selection.DragSelection) ?diff_surface.DiffMouseHit {
        return self.diffMouseHitLocked(point, drag);
    }

    fn diffMouseHitLocked(self: BodyView, point: diff_surface.MousePoint, locked: ?diff_selection.DragSelection) ?diff_surface.DiffMouseHit {
        const raw_diff = self.view.rawDiffPaneGeometry() orelse return null;
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
        if (visible_body_row >= self.view.diffVisibleRows()) return null;
        const offset = self.view.surface.viewer.diff_scroll + visible_body_row;
        const body_width = diff_render.bodyWidth(content_width);
        const display_mode = diff_render.effectiveMode(body_width, self.view.surface.viewer.display_mode);

        if (self.parsedSelectionTarget(if (locked) |selection_value| selection_value.identity else null)) |target| {
            const hit = parsedMouseLine(target, body_col, body_width, display_mode, offset, self.view.surface.viewer.view_options.line_numbers, locked) orelse return null;
            const model_mode = if (locked) |selection_value| selection_value.mode else hit.region.mode;
            const point_value = if (hit.region.leading_boundary)
                diff_selection.pointFromBoundary(hit.hunk_index, hit.line_index, 0)
            else
                pointForTextCell(hit.hunk_index, hit.line_index, hit.line.text, model_mode, hit.region.text_cell +| self.view.surface.viewer.diff_horizontal_scroll) orelse return null;
            return .{
                .identity = target.identity,
                .side = hit.region.side,
                .mode = model_mode,
                .point = point_value,
            };
        }

        const generated = self.generatedBody() orelse return null;
        const line = generated.source.lineBody(offset) orelse return null;
        const region = selectionRegionForGenerated(body_col, body_width, display_mode, self.view.surface.viewer.view_options.line_numbers, locked) orelse return null;
        const model_mode = if (locked) |selection_value| selection_value.mode else region.mode;
        return .{
            .identity = .{ .generated_file = .{ .path_key = generated.path } },
            .side = .new,
            .mode = model_mode,
            .point = if (region.leading_boundary)
                diff_selection.pointFromBoundary(0, offset, 0)
            else
                pointForTextCell(0, offset, line, model_mode, region.text_cell +| self.view.surface.viewer.diff_horizontal_scroll) orelse return null,
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

        const pane_width = self.view.diffPaneWidth();
        if (self.generatedBody()) |body| {
            const row_count = body.source.rowCount();
            const first_row = @min(self.view.surface.viewer.diff_scroll, row_count);
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
                    pane_width,
                    self.view.surface.viewer.view_options.line_numbers,
                ));
            }
            return max_scroll;
        }

        const file = self.displayedDiffFile() orelse return 0;
        const line_index = self.displayedDiffLineIndex(mode);
        var max_scroll: usize = 0;
        var rows = if (line_index) |index|
            diff_view_model.BodyRowIterator.initAtWithFolded(file, mode, index, self.view.surface.viewer.diff_scroll, self.selectedFoldedHunks())
        else
            diff_view_model.BodyRowIterator.initWithFolded(file, mode, self.selectedFoldedHunks());
        var skipped: usize = if (line_index != null) self.view.surface.viewer.diff_scroll else 0;
        var visible: usize = 0;
        while (rows.next()) |body_row| {
            if (skipped < self.view.surface.viewer.diff_scroll) {
                skipped += 1;
                continue;
            }
            if (visible >= visible_rows) break;
            visible += 1;
            max_scroll = @max(max_scroll, maxHorizontalScrollForBodyRow(body_row, pane_width, self.view.surface.viewer.view_options.line_numbers));
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
        return diff_view_model.renderedOffsetForCoordinate(file, mode, self.view.surface.viewer.diff_cursor, index);
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

    pub fn visibleDiffCursorOffset(self: BodyView) ?usize {
        const offset = self.selectedDiffCursorOffset() orelse return null;
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
    diagnostics: diff_surface.DiagnosticSink,

    pub fn view(self: Controller) View {
        return .{
            .surface = self.surface.readOnly(),
            .repo_root = self.repo_root,
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
        self.clearDiffSelection();
        self.surface.file_search_return_focus.* = if (self.surface.viewer.sidebar_hidden) .diff else self.surface.viewer.focus;
        if (!self.surface.viewer.sidebar_hidden) self.surface.viewer.focus = .sidebar;
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

pub fn indexedLineForSide(row: diff_view_model.SideBySideIndexedRow, side: diff_selection.Side) ?diff_view_model.IndexedDiffLine {
    return switch (row) {
        .single => |line| if (diff_selection.lineVisibleOnSide(line.line, side)) line else null,
        .paired => |pair| switch (side) {
            .old => pair.removed,
            .new => pair.added,
        },
    };
}

pub fn selectionRegionForUnified(body_col: u16, line_numbers: bool, line: diff_parser.DiffLine, locked: ?diff_selection.DragSelection) ?SelectionRegion {
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

pub fn selectionRegionForGenerated(body_col: u16, body_width: u16, display_mode: diff_render.DisplayMode, line_numbers: bool, locked: ?diff_selection.DragSelection) ?SelectionRegion {
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

pub fn pointForTextCell(hunk_index: usize, line_index: usize, text: []const u8, mode: diff_selection.Mode, cell: usize) ?diff_selection.Point {
    if (mode == .line) return diff_selection.pointFromLine(hunk_index, line_index);
    return switch (text_projection.hitAtDisplayCell(text, cell) orelse return null) {
        .token => |token| diff_selection.pointFromToken(hunk_index, line_index, token),
        .boundary => |boundary| diff_selection.pointFromBoundary(hunk_index, line_index, boundary.offset),
    };
}

pub fn contentWidth(width: u16) u16 {
    return layout.diffContentWidth(width);
}

pub fn sidebarWidth(total_width: u16, preferred_width: ?u16) u16 {
    return layout.sidebarWidth(total_width, preferred_width);
}

pub fn maxHorizontalScrollForBodyRow(body_row: diff_view_model.BodyRow, pane_width: u16, line_numbers: bool) usize {
    return switch (body_row) {
        .unified_line => |line| maxHorizontalScrollForText(line.text, visibleTextWidth(pane_width, diff_render.lineTextStart(line_numbers, .unified))),
        .side_by_side => |side_row| maxHorizontalScrollForSideBySideRow(side_row, pane_width, line_numbers),
        else => 0,
    };
}

pub fn maxHorizontalScrollForSideBySideRow(side_row: diff_view_model.SideBySideRow, pane_width: u16, line_numbers: bool) usize {
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

pub fn visibleTextWidth(total_width: u16, text_col: u16) u16 {
    return if (total_width > text_col) total_width - text_col else 0;
}

pub fn maxHorizontalScrollForText(text: []const u8, visible_width: u16) usize {
    const width = text_projection.displayWidth(text) catch return 0;
    if (width <= visible_width) return 0;
    return width - visible_width;
}
