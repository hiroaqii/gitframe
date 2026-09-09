//! Changes-local navigation, search, folding, and mouse-selection ownership.
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
const changes_message = @import("message.zig");
const content_selection = @import("../../diff_surface/selection.zig");
const session_hunk_mark = @import("session_hunk_mark.zig");
const changes_projection = @import("../../changes_projection.zig");
const app_changes_projection = changes_projection;
const changes_page = @import("../changes.zig");
const file_search = @import("../../diff_surface/file_search.zig");
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
const test_support = if (builtin.is_test) @import("../../test_support.zig") else struct {};
const app_test_support = test_support;
const changes_body_render = @import("body_render.zig");

const LoadedDiff = loaded_diff.LoadedDiff;
const ChangedFileFilter = loaded_diff.ChangedFileFilter;
const HorizontalDirection = app_direction.Horizontal;
const SizeDirection = app_direction.Size;
const VerticalDirection = app_direction.Vertical;

const diff_surface = @import("../../diff_surface.zig");

pub const Layout = diff_surface.Layout;
pub const DiagnosticSink = diff_surface.DiagnosticSink;
pub const MousePoint = changes_message.MousePoint;
pub const DiffMouseHit = diff_surface.DiffMouseHit;
pub const DiffHeaderTarget = diff_surface.DiffHeaderTarget;
pub const DisplayNavigationSnapshot = diff_surface.DisplayNavigationSnapshot;

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
/// per-hunk contract. Both normal and status-only Changes routes use this one
/// conversion so they cannot disagree about a combined hunk's stage state.
pub fn projectedHunkStagePresentation(
    allocator: std.mem.Allocator,
    states: []const diff_hunk_projection.HunkStageState,
) !diff_render.HunkStagePresentation {
    return diff_surface.navigation.projectedHunkStagePresentation(allocator, states);
}

pub const invalid_utf8_body_message = diff_surface.invalid_utf8_body_message;

pub const HunkInteractionAvailability = diff_surface.HunkInteractionAvailability;

/// Borrowed reference to the fresh index authority paired with the current
/// presentation. The explicit union keeps a real two-component mixed
/// generation distinct from a one-component staged-only generation.
pub const HunkAuthorityRef = union(enum) {
    combined: *const changes_projection.CombinedAuthority,
    staged_only: *const changes_projection.StagedOnlyAuthority,

    pub fn hunkStageStates(self: HunkAuthorityRef) []const diff_hunk_projection.HunkStageState {
        return switch (self) {
            .combined => |authority| authority.projection.hunk_stage_states,
            .staged_only => |authority| authority.projection.hunk_stage_states,
        };
    }

    pub fn hunkActionOrigins(self: HunkAuthorityRef) []const diff_hunk_projection.HunkActionOrigin {
        return switch (self) {
            .combined => |authority| authority.projection.hunk_action_origins,
            .staged_only => |authority| authority.projection.hunk_action_origins,
        };
    }

    pub fn actionSourceFile(self: HunkAuthorityRef, origin: diff_hunk_projection.HunkActionOrigin) ?diff_parser.FileDiff {
        return switch (self) {
            .combined => |authority| authority.actionSourceFile(origin),
            .staged_only => |authority| authority.actionSourceFile(origin),
        };
    }

    pub fn statusSnapshotRevision(self: HunkAuthorityRef) u64 {
        return switch (self) {
            .combined => |authority| authority.status_snapshot_revision,
            .staged_only => |authority| authority.status_snapshot_revision,
        };
    }

    pub fn requestKind(self: HunkAuthorityRef) changes_projection.Kind {
        return switch (self) {
            .combined => .combined_hunks,
            .staged_only => .cached_diff,
        };
    }
};

/// Borrowed action facade for a retained presentation. The display file and
/// its fresh index authority may have different owners, but both are resolved
/// for only the duration of the current update.
pub const ActiveHunkAuthority = struct {
    display_file: diff_parser.FileDiff,
    authority: HunkAuthorityRef,

    pub fn hunkStageStates(self: ActiveHunkAuthority) []const diff_hunk_projection.HunkStageState {
        return self.authority.hunkStageStates();
    }

    pub fn hunkActionOrigins(self: ActiveHunkAuthority) []const diff_hunk_projection.HunkActionOrigin {
        return self.authority.hunkActionOrigins();
    }

    pub fn actionSourceFile(self: ActiveHunkAuthority, origin: diff_hunk_projection.HunkActionOrigin) ?diff_parser.FileDiff {
        return self.authority.actionSourceFile(origin);
    }
};

pub const PrimaryChangesBody = struct {
    loaded: *const LoadedDiff,
    file_index: usize,
    hunk_authority: ?HunkAuthorityRef = null,
};

/// Single authority facade for the body currently promised by Changes.
///
/// In particular, an accepted inert projection is still a displayed body; it
/// must never collapse to `none` and accidentally reveal the primary diff
/// underneath it.
pub const DisplayedChangesBody = union(enum) {
    none,
    primary: PrimaryChangesBody,
    cached: *const app_load.LoadedDiffBundle,
    combined: *const changes_projection.CombinedHunkBundle,
    retained_staged_only: *const changes_projection.RetainedStagedOnlyBundle,
    generated: *const changes_projection.GeneratedFileBundle,
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

pub const NormalLoadedDiffSelectionTarget = diff_surface.NormalLoadedDiffSelectionTarget;
pub const ParsedSelectionTarget = diff_surface.ParsedSelectionTarget;
pub const RawDiffPaneGeometry = diff_surface.RawDiffPaneGeometry;
pub const SearchTarget = diff_surface.SearchTarget;

/// Short-lived Changes-owned implementation of the page-independent body
/// resolver contract. Callers construct it on the stack for one resolver call;
/// returned borrows point into `page`, never into this adapter.
const ChangesBodyResolver = struct {
    view: View,

    fn interface(self: *ChangesBodyResolver) diff_surface.BodyResolver {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn fromContext(ctx: *anyopaque) *ChangesBodyResolver {
        return @ptrCast(@alignCast(ctx));
    }
    const vtable: diff_surface.BodyResolver.VTable = .{
        .resolvedTarget = resolvedTarget,
        .hunkStagePresentation = hunkStagePresentation,
        .contentToken = contentToken,
        .renderProjectedBody = renderProjectedBody,
        .parsedSelectionTarget = parsedSelectionTarget,
        .displayedDiffFile = displayedDiffFile,
        .displayedSearchTarget = displayedSearchTarget,
        .displayedDiffLineIndex = displayedDiffLineIndex,
        .displayedDiffLineCount = displayedDiffLineCount,
        .generatedBody = generatedBody,
        .displayedDiffHeaderTarget = displayedDiffHeaderTarget,
    };

    fn resolvedTarget(ctx: *anyopaque) diff_surface.ResolvedTarget {
        return fromContext(ctx).view.resolvedTargetDirect();
    }

    fn hunkStagePresentation(ctx: *anyopaque, allocator: std.mem.Allocator, file_index: usize) !diff_render.HunkStagePresentation {
        return fromContext(ctx).view.hunkStagePresentationDirect(allocator, file_index);
    }

    fn contentToken(ctx: *anyopaque) ?diff_surface.ContentToken {
        return fromContext(ctx).view.currentContentTokenDirect();
    }

    fn renderProjectedBody(ctx: *anyopaque, args: diff_surface.RenderProjectedBodyArgs) !void {
        return fromContext(ctx).view.renderProjectedBodyDirect(args);
    }

    fn parsedSelectionTarget(ctx: *anyopaque, expected: ?diff_selection.Identity) ?ParsedSelectionTarget {
        return fromContext(ctx).view.parsedSelectionTargetDirect(expected);
    }

    fn displayedDiffFile(ctx: *anyopaque) ?diff_parser.FileDiff {
        return fromContext(ctx).view.displayedDiffFileDirect();
    }

    fn displayedSearchTarget(ctx: *anyopaque, mode: diff_render.DisplayMode) ?SearchTarget {
        return fromContext(ctx).view.displayedSearchTargetDirect(mode);
    }

    fn displayedDiffLineIndex(ctx: *anyopaque, mode: diff_render.DisplayMode) ?diff_view_model.RenderedLineIndex {
        return fromContext(ctx).view.displayedDiffLineIndexDirect(mode);
    }

    fn displayedDiffLineCount(ctx: *anyopaque) usize {
        return fromContext(ctx).view.displayedDiffLineCountDirect();
    }

    fn generatedBody(ctx: *anyopaque) ?diff_surface.GeneratedBody {
        return fromContext(ctx).view.generatedBodyDirect();
    }

    fn displayedDiffHeaderTarget(ctx: *anyopaque, expected: ?diff_selection.HeaderIdentity) ?DiffHeaderTarget {
        return fromContext(ctx).view.displayedDiffHeaderTargetDirect(expected);
    }
};

pub const View = struct {
    page: *const changes_page.ChangesPageState,
    repo_root: ?[]const u8,
    repo_epoch: u64 = 0,
    root_identity: ?root_capability.Identity = null,
    source: diff_source.SourceMode,
    layout: Layout,
    mode_toggle_hint_width: u16 = 0,

    /// Builds the short-lived shared read-only facade for one delegated call.
    /// The const-qualified surface prevents this View from acquiring write
    /// authority while preserving the existing const page borrow.
    fn sharedView(self: View) diff_surface.navigation.View {
        return .{
            .surface = self.page.readSurface(self.source, self.layout),
            .repo_root = self.repo_root,
            .mode_toggle_hint_width = self.mode_toggle_hint_width,
        };
    }

    fn sharedBodyView(self: View, adapter: *ChangesBodyResolver) diff_surface.navigation.BodyView {
        return .{
            .view = self.sharedView(),
            .resolver = adapter.interface(),
        };
    }

    fn bodyResolverAdapter(self: View) ChangesBodyResolver {
        return .{ .view = self };
    }

    /// Builds the Changes body resolver only for the duration of one shared
    /// selected-content query. Returned borrows always point into page state.
    pub fn contentView(self: View, adapter: *ChangesBodyResolver) diff_surface.content.View {
        return .{ .navigation = self.sharedBodyView(adapter) };
    }

    pub fn contentResolverAdapter(self: View) ChangesBodyResolver {
        return self.bodyResolverAdapter();
    }

    /// Builds the shared body view for one synchronous render adapter call.
    pub fn diffSurfaceBodyView(self: View, adapter: *ChangesBodyResolver) diff_surface.navigation.BodyView {
        return self.sharedBodyView(adapter);
    }

    pub fn resolvedTarget(self: View) diff_surface.ResolvedTarget {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).resolvedTarget();
    }

    pub fn renderProjectedBody(self: View, args: diff_surface.RenderProjectedBodyArgs) !void {
        var adapter = self.bodyResolverAdapter();
        return adapter.interface().renderProjectedBody(args);
    }

    pub fn displayedChangesBody(self: View) DisplayedChangesBody {
        switch (self.page.changes_projection.displayed) {
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
                        .primary_combined_authority => |*authority| self.primaryChangesBody(.{ .combined = authority }),
                        .retained_staged_only => |*bundle| .{ .retained_staged_only = bundle },
                        .primary_staged_only_authority => |*authority| self.primaryChangesBody(.{ .staged_only = authority }),
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

        if (self.selectedStatusEntry() != null) return if (self.page.changes_projection.hasPending()) .pending else .none;

        return self.primaryChangesBody(null);
    }

    /// Exact scalar identity of the body currently promised by Changes.
    ///
    /// Selection release, hunk action resolution, and session-mark rendering
    /// share this builder so they cannot disagree about presentation lineage.
    pub fn currentContentToken(self: View) ?content_selection.ContentToken {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).currentContentToken();
    }

    fn currentContentTokenDirect(self: View) ?content_selection.ContentToken {
        const display: content_selection.DisplayBasis = switch (self.displayedChangesBody()) {
            .primary => |primary| .{ .loaded = .init(primary.loaded.text) },
            .cached => |bundle| .{ .cached_projection = .{
                .status_snapshot_revision = self.page.status_snapshot_revision,
                .cached = bundle.fingerprint,
            } },
            .combined => |bundle| .{ .combined_projection = bundle.presentation.content_token },
            .retained_staged_only => |bundle| .{ .combined_projection = bundle.presentation.content_token },
            .generated => |bundle| .{ .generated_untracked = .{
                .status_snapshot_revision = self.page.status_snapshot_revision,
                .source = bundle.fingerprint(),
            } },
            .none, .inert_invalid_utf8, .status, .pending => return null,
        };
        return .{
            .repo_epoch = self.repo_epoch,
            .root_identity = self.root_identity,
            .source = content_selection.SourceBasis.init(self.source),
            .source_session_revision = self.page.source_session_revision,
            .display = display,
        };
    }

    fn primaryChangesBody(
        self: View,
        hunk_authority: ?HunkAuthorityRef,
    ) DisplayedChangesBody {
        const loaded = self.activeLoadedDiffConst() orelse return .none;
        const file_index = self.selectedFileIndex(loaded) orelse return .none;
        if (file_index >= loaded.document.files.len) return .none;
        if (!loaded.fileTextSelectable(file_index)) {
            const file = loaded.document.files[file_index];
            const path_key = diff_file.canonicalPathKey(file) orelse diff_file.displayPath(file);
            return .{ .inert_invalid_utf8 = .{ .path_key = path_key, .display_path = diff_file.displayPath(file) } };
        }
        return .{ .primary = .{
            .loaded = loaded,
            .file_index = file_index,
            .hunk_authority = hunk_authority,
        } };
    }

    pub fn diffSelectionView(self: View) ?diff_selection.View {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).diffSelectionView();
    }

    pub fn selectionStatusPresentation(self: View) ?diff_surface.selection_action.StatusPresentation {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).selectionStatusPresentation();
    }

    pub fn keyboardSideChoiceActive(self: View) bool {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).keyboardSideChoiceActive();
    }

    pub fn renderDiffScroll(self: View) usize {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).renderDiffScroll();
    }

    pub fn renderDiffCursorOffset(self: View) ?usize {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).renderDiffCursorOffset();
    }

    pub fn retainedSelectionActionAvailable(self: View) bool {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).retainedSelectionActionAvailable();
    }

    pub fn captureSelectionViewportAnchor(self: View) ?diff_surface.selection_action.SelectionViewportAnchor {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).captureSelectionViewportAnchor();
    }

    pub fn restoredSelectionViewportScroll(
        self: View,
        anchor: diff_surface.selection_action.SelectionViewportAnchor,
    ) usize {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).restoreSelectionViewportAnchor(anchor);
    }

    pub fn selectionActionHit(self: View, point: diff_surface.MousePoint) ?diff_surface.navigation.SelectionActionHit {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).selectionActionHit(point);
    }

    pub fn diffHeaderSelectionActive(self: View) bool {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).diffHeaderSelectionActive();
    }

    pub fn displayNavigationSnapshot(self: View) DisplayNavigationSnapshot {
        return self.sharedView().displayNavigationSnapshot();
    }

    pub fn normalLoadedDiffSelectionTarget(self: View, identity: ?diff_selection.Identity) ?NormalLoadedDiffSelectionTarget {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).normalLoadedDiffSelectionTarget(identity);
    }

    pub fn parsedSelectionTarget(self: View, expected: ?diff_selection.Identity) ?ParsedSelectionTarget {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).parsedSelectionTarget(expected);
    }

    fn parsedSelectionTargetDirect(self: View, expected: ?diff_selection.Identity) ?ParsedSelectionTarget {
        const target: ParsedSelectionTarget = switch (self.displayedChangesBody()) {
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
            .retained_staged_only => |bundle| blk: {
                const path_key = diff_file.canonicalPathKey(bundle.displayFile()) orelse return null;
                break :blk .{
                    .file = bundle.displayFile(),
                    .line_index = bundle.displayLineIndex(self.effectiveDisplayMode()),
                    .folded_hunks = &.{},
                    .identity = .{ .projection_file = .{ .kind = .cached, .path_key = path_key } },
                };
            },
            .none, .generated, .inert_invalid_utf8, .status, .pending => return null,
        };
        if (expected) |identity| if (!identity.eql(target.identity)) return null;
        return target;
    }

    pub fn displayedDiffHeaderTarget(self: View, expected: ?diff_selection.HeaderIdentity) ?DiffHeaderTarget {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).displayedDiffHeaderTarget(expected);
    }

    fn displayedDiffHeaderTargetDirect(self: View, expected: ?diff_selection.HeaderIdentity) ?DiffHeaderTarget {
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
            if (self.activeRetainedStagedOnlyProjection()) |bundle| {
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
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).diffHeaderMouseHit(point);
    }

    pub fn displayedDiffHeaderLayout(self: View, content_width: u16, display_path: []const u8) ?diff_render.HeaderLayout {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).displayedDiffHeaderLayout(content_width, display_path);
    }

    pub fn diffMouseHit(self: View, point: MousePoint) ?DiffMouseHit {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).diffMouseHit(point);
    }

    pub fn diffMouseDragHit(self: View, point: MousePoint, selection: diff_selection.DragSelection) ?DiffMouseHit {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).diffMouseDragHit(point, selection);
    }

    pub fn rawDiffPaneGeometry(self: View) ?RawDiffPaneGeometry {
        return self.sharedView().rawDiffPaneGeometry();
    }

    pub fn fileTreeRootOptions(self: View) ?file_tree.RootOptions {
        return self.sharedView().fileTreeRootOptions();
    }

    pub fn visibleSidebarMaxHorizontalScroll(self: View) usize {
        return self.sharedView().visibleSidebarMaxHorizontalScroll();
    }

    pub fn visibleBodyTextMaxHorizontalScroll(self: View) usize {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).visibleBodyTextMaxHorizontalScroll();
    }

    pub fn selectedProjectionLineCount(self: View) usize {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).selectedProjectionLineCount();
    }

    fn selectedProjectionLineCountDirect(self: View) usize {
        if (self.selectedStatusEntry() == null) return 0;
        return switch (self.page.changes_projection.displayed) {
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
                .primary_combined_authority => 0,
                .retained_staged_only => |bundle| bundle.displayLineIndex(self.effectiveDisplayMode()).lineCount(),
                .primary_staged_only_authority => 0,
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
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).remapDiffScrollForModeChange(old_mode, new_mode, old_scroll);
    }

    pub fn unsupportedSearchMessage(self: View) ?[]const u8 {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).unsupportedSearchMessage();
    }

    fn searchUnavailableReasonDirect(self: View) ?diff_surface.SearchUnavailableReason {
        if (self.displayedChangesBody() == .inert_invalid_utf8) {
            return .invalid_utf8;
        }
        if (self.activeCombinedProjection() != null) {
            return .mixed_stage_view;
        }
        if (self.activeGeneratedFileProjection() != null) {
            return .generated_preview;
        }
        if (self.activeCachedDiffProjection() != null) {
            if (self.selectedStatusEntry()) |entry| {
                if (entry.index == .added and !entry.isUnstaged()) {
                    return .staged_new_preview;
                }
            }
        }
        return null;
    }

    pub fn currentSearchMatchInHunkBody(self: View, hunk_index: usize) bool {
        return self.sharedView().currentSearchMatchInHunkBody(hunk_index);
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
        return self.sharedView().selectedSidebarIdentity();
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
        return self.sharedView().diffFileSelection(loaded, file_index);
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
        return self.sharedView().treeOrderScopeText(allocator);
    }

    pub fn selectedFile(self: View) ?diff_parser.FileDiff {
        return self.sharedView().selectedFile();
    }

    pub fn displayedDiffFile(self: View) ?diff_parser.FileDiff {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).displayedDiffFile();
    }

    fn displayedDiffFileDirect(self: View) ?diff_parser.FileDiff {
        return switch (self.displayedChangesBody()) {
            .primary => |primary| primary.loaded.document.files[primary.file_index],
            .cached => |bundle| bundle.loaded.document.files[0],
            .combined => |bundle| bundle.displayFile(),
            .retained_staged_only => |bundle| bundle.displayFile(),
            .none, .generated, .inert_invalid_utf8, .status, .pending => null,
        };
    }

    pub fn displayedSearchTarget(self: View, mode: diff_render.DisplayMode) ?SearchTarget {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).displayedSearchTarget(mode);
    }

    fn displayedSearchTargetDirect(self: View, mode: diff_render.DisplayMode) ?SearchTarget {
        return switch (self.displayedChangesBody()) {
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
            .retained_staged_only => |bundle| .{
                .file = bundle.displayFile(),
                .line_index = bundle.displayLineIndex(mode),
                .folded_hunks = &.{},
            },
            .none, .combined, .generated, .inert_invalid_utf8, .status, .pending => null,
        };
    }

    pub fn displayedGeneratedLineCount(self: View) ?usize {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).displayedGeneratedLineCount();
    }

    pub fn displayedDiffLineIndex(self: View, mode: diff_render.DisplayMode) ?diff_view_model.RenderedLineIndex {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).displayedDiffLineIndex(mode);
    }

    fn displayedDiffLineIndexDirect(self: View, mode: diff_render.DisplayMode) ?diff_view_model.RenderedLineIndex {
        return switch (self.displayedChangesBody()) {
            .primary => |primary| primary.loaded.cachedRenderedLineIndex(primary.file_index, mode),
            .cached => |bundle| bundle.loaded.cachedRenderedLineIndex(0, mode),
            .combined => |bundle| bundle.displayLineIndex(mode),
            .retained_staged_only => |bundle| bundle.displayLineIndex(mode),
            .none, .generated, .inert_invalid_utf8, .status, .pending => null,
        };
    }

    fn resolvedTargetDirect(self: View) diff_surface.ResolvedTarget {
        const body = self.displayedChangesBody();
        return .{
            .kind = switch (body) {
                .none => .none,
                .primary => .primary,
                .inert_invalid_utf8 => .inert,
                .cached, .combined, .retained_staged_only, .generated, .status, .pending => .projected,
            },
            .line_count = self.selectedProjectionLineCountDirect(),
            .hunk_interaction = switch (body) {
                .primary, .cached, .combined, .retained_staged_only => .available,
                .inert_invalid_utf8 => .inert_invalid_utf8,
                .none, .generated, .status, .pending => .unavailable,
            },
            .status_rows = self.page.git_status.document.entries.len,
            .search_unavailable = self.searchUnavailableReasonDirect(),
            .search_unfold_policy = switch (body) {
                .primary => .unfold_displayed,
                .retained_staged_only => .unfold_underlying,
                .none, .cached, .combined, .generated, .inert_invalid_utf8, .status, .pending => .suppressed,
            },
            .folded_hunks_source = switch (body) {
                .cached, .combined, .retained_staged_only => .empty,
                .none, .primary, .generated, .inert_invalid_utf8, .status, .pending => .underlying_load,
            },
        };
    }

    pub fn generatedBody(self: View) ?diff_surface.GeneratedBody {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).generatedBody();
    }

    fn generatedBodyDirect(self: View) ?diff_surface.GeneratedBody {
        const bundle = self.activeGeneratedFileProjection() orelse return null;
        return .{ .path = bundle.path, .source = &bundle.source };
    }

    pub fn activeDiffDisplay(self: View, allocator: std.mem.Allocator, mode: diff_render.DisplayMode) !?ActiveDiffDisplay {
        return self.activeDiffDisplayDirect(allocator, mode);
    }

    fn activeDiffDisplayDirect(self: View, allocator: std.mem.Allocator, mode: diff_render.DisplayMode) !?ActiveDiffDisplay {
        const selected: PrimaryChangesBody = switch (self.displayedChangesBody()) {
            .combined => |bundle| {
                return .{ .combined_projection = .{
                    .file = bundle.displayFile(),
                    .line_index = bundle.displayLineIndex(mode),
                    .hunk_stages = try projectedHunkStagePresentation(allocator, bundle.hunkStageStates()),
                    .syntax = bundle.syntaxView(),
                } };
            },
            .retained_staged_only => |bundle| {
                return .{ .combined_projection = .{
                    .file = bundle.displayFile(),
                    .line_index = bundle.displayLineIndex(mode),
                    .hunk_stages = .all_staged,
                    .syntax = bundle.syntaxView(),
                } };
            },
            .cached => |bundle| {
                const loaded = &bundle.loaded;
                if (loaded.document.files.len == 0) return null;
                return .{ .loaded = .{
                    .file = loaded.document.files[0],
                    .line_index = loaded.cachedRenderedLineIndex(0, mode),
                    .folded_hunks = &.{},
                    .hunk_stages = .all_staged,
                    .syntax = .initDirect(&loaded.syntax_spans, 0),
                } };
            },
            .primary => |primary| primary,
            .none, .generated, .inert_invalid_utf8, .status, .pending => return null,
        };
        const loaded = selected.loaded;
        const file_index = selected.file_index;
        const file = loaded.document.files[file_index];
        return .{ .loaded = .{
            .file = file,
            .line_index = loaded.cachedRenderedLineIndex(file_index, mode),
            .folded_hunks = loaded.foldedHunksForFile(file_index),
            .hunk_stages = if (selected.hunk_authority) |authority|
                try projectedHunkStagePresentation(allocator, authority.hunkStageStates())
            else
                try self.hunkStagePresentationForFileDirect(allocator, file),
            .syntax = .initDirect(&loaded.syntax_spans, file_index),
        } };
    }

    fn renderProjectedBodyDirect(self: View, args: diff_surface.RenderProjectedBodyArgs) !void {
        const body = self.displayedChangesBody();
        switch (body) {
            .generated => |bundle| {
                try changes_body_render.renderGenerated(bundle, args);
                return;
            },
            .inert_invalid_utf8 => |inert| {
                try changes_body_render.renderStatus(inert.display_path, invalid_utf8_body_message, self.selectedStatusLineStats(), args);
                return;
            },
            .status => |status| {
                try changes_body_render.renderStatus(status.path, status.message, self.selectedStatusLineStats(), args);
                return;
            },
            .pending => {
                const entry = self.selectedStatusEntry() orelse return;
                const path = entry.canonicalPathKey() orelse entry.path;
                try changes_body_render.renderStatus(path, "Loading changes projection...", self.selectedStatusLineStats(), args);
                return;
            },
            .none, .primary => return,
            .cached, .combined, .retained_staged_only => {},
        }

        const mode = diff_render.effectiveMode(diff_render.bodyWidth(args.surface.size().width), args.requested_mode);
        const display = (try self.activeDiffDisplayDirect(args.surface.frameAllocator(), mode)) orelse return;
        try changes_body_render.renderParsed(.{
            .file = display.file(),
            .line_index = display.lineIndex(),
            .folded_hunks = display.foldedHunks(),
            .hunk_stages = display.hunkStagePresentation(),
            .syntax = display.syntaxView(),
        }, args);
    }

    pub fn activeGeneratedFileProjection(self: View) ?*const changes_projection.GeneratedFileBundle {
        return switch (self.displayedChangesBody()) {
            .generated => |bundle| bundle,
            else => null,
        };
    }

    pub fn activeCachedDiffProjection(self: View) ?*const app_load.LoadedDiffBundle {
        return switch (self.displayedChangesBody()) {
            .cached => |bundle| bundle,
            else => null,
        };
    }

    pub fn activeCombinedProjection(self: View) ?*const changes_projection.CombinedHunkBundle {
        return switch (self.displayedChangesBody()) {
            .combined => |bundle| bundle,
            else => null,
        };
    }

    pub fn activeRetainedStagedOnlyProjection(self: View) ?*const changes_projection.RetainedStagedOnlyBundle {
        return switch (self.displayedChangesBody()) {
            .retained_staged_only => |bundle| bundle,
            else => null,
        };
    }

    pub fn activeHunkAuthority(self: View) ?ActiveHunkAuthority {
        return switch (self.displayedChangesBody()) {
            .combined => |bundle| .{
                .display_file = bundle.displayFile(),
                .authority = .{ .combined = &bundle.authority },
            },
            .retained_staged_only => |bundle| .{
                .display_file = bundle.displayFile(),
                .authority = .{ .staged_only = &bundle.authority },
            },
            .primary => |primary| if (primary.hunk_authority) |authority| .{
                .display_file = primary.loaded.document.files[primary.file_index],
                .authority = authority,
            } else null,
            else => null,
        };
    }

    pub fn bodyAllowsHunkInteraction(self: View) bool {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).bodyAllowsHunkInteraction();
    }

    pub fn bodyAllowsHunkFold(self: View) bool {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).bodyAllowsHunkFold();
    }

    pub fn hunkInteractionAvailability(self: View) HunkInteractionAvailability {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).hunkInteractionAvailability();
    }

    pub fn displayedProjectionRequestIsActive(self: View, request: changes_projection.Request) bool {
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
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).selectedFileLineIndex(mode);
    }

    pub fn displayedDiffLineCount(self: View) usize {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).displayedDiffLineCount();
    }

    fn displayedDiffLineCountDirect(self: View) usize {
        return switch (self.displayedChangesBody()) {
            .generated => |body| body.source.rowCount(),
            // These bodies render their own single presentation row and must
            // never inherit the selected underlying diff's row count as their
            // scroll basis.
            .inert_invalid_utf8, .status, .pending => 1,
            .none => 0,
            .primary, .cached, .combined, .retained_staged_only => self.selectedFileLineIndex(self.effectiveDisplayMode()).lineCount(),
        };
    }

    pub fn selectedFileCachedLineIndex(self: View, mode: diff_render.DisplayMode) ?diff_view_model.RenderedLineIndex {
        return self.sharedView().selectedFileCachedLineIndex(mode);
    }

    pub fn selectedFoldedHunks(self: View) []const bool {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).selectedFoldedHunks();
    }

    pub fn selectedHunkIndex(self: View) ?usize {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).selectedHunkIndex();
    }

    fn rawSelectedHunkIndex(self: View) ?usize {
        return self.sharedView().rawSelectedHunkIndex();
    }

    fn hunkStagePresentationDirect(self: View, allocator: std.mem.Allocator, file_index: usize) !diff_render.HunkStagePresentation {
        return switch (self.displayedChangesBody()) {
            .combined => |bundle| projectedHunkStagePresentation(allocator, bundle.hunkStageStates()),
            .retained_staged_only, .cached => .all_staged,
            .primary => |primary| blk: {
                if (primary.hunk_authority) |authority| {
                    break :blk projectedHunkStagePresentation(allocator, authority.hunkStageStates());
                }
                if (file_index >= primary.loaded.document.files.len) break :blk .all_unstaged;
                break :blk self.hunkStagePresentationForFileDirect(allocator, primary.loaded.document.files[file_index]);
            },
            .none, .generated, .inert_invalid_utf8, .status, .pending => .all_unstaged,
        };
    }

    pub fn hunkStagePresentation(self: View, allocator: std.mem.Allocator, file_index: usize) !diff_render.HunkStagePresentation {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).hunkStagePresentation(allocator, file_index);
    }

    fn hunkStagePresentationForFileDirect(self: View, allocator: std.mem.Allocator, file: diff_parser.FileDiff) !diff_render.HunkStagePresentation {
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
        const content = self.currentContentTokenDirect() orelse return .all_unstaged;

        var marked_count: usize = 0;
        for (0..file.hunks.len) |hunk_index| {
            if (self.page.staged_hunks.containsExact(repo_root, path, .{
                .content = content,
                .display_hunk_index = hunk_index,
            })) marked_count += 1;
        }

        if (marked_count == 0) return .all_unstaged;

        const states = try allocator.alloc(diff_render.HunkStageState, file.hunks.len);
        for (states, 0..) |*state, hunk_index| {
            state.* = if (self.page.staged_hunks.containsExact(repo_root, path, .{
                .content = content,
                .display_hunk_index = hunk_index,
            })) .staged else .unstaged;
        }
        return .{ .per_hunk = states };
    }

    pub fn selectedDiffCursorOffset(self: View) ?usize {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).selectedDiffCursorOffset();
    }

    pub fn selectedCoordinateAtOffset(self: View, offset: usize) ?diff_view_model.BodyCoordinate {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).selectedCoordinateAtOffset(offset);
    }

    pub fn visibleDiffCursorOffset(self: View) ?usize {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).visibleDiffCursorOffset();
    }

    pub fn diffCursorIsVisible(self: View) bool {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyView(&adapter).diffCursorIsVisible();
    }

    pub fn loadedFileCount(self: View) ?usize {
        return self.sharedView().loadedFileCount();
    }

    pub fn effectiveDisplayMode(self: View) diff_render.DisplayMode {
        return self.sharedView().effectiveDisplayMode();
    }

    pub fn diffVisibleRows(self: View) usize {
        return self.sharedView().diffVisibleRows();
    }

    pub fn diffPaneWidth(self: View) u16 {
        return self.sharedView().diffPaneWidth();
    }

    pub fn selectedFileIndex(self: View, loaded: *const LoadedDiff) ?usize {
        return self.sharedView().selectedFileIndex(loaded);
    }

    pub fn selectedDiffFileTarget(self: View) ?usize {
        return self.sharedView().selectedDiffFileTarget();
    }

    pub fn activeLoadedDiffConst(self: View) ?*const LoadedDiff {
        return self.sharedView().activeLoadedDiffConst();
    }
};

pub const Controller = struct {
    page: *changes_page.ChangesPageState,
    repo_root: ?[]const u8,
    repo_epoch: u64 = 0,
    root_identity: ?root_capability.Identity = null,
    source: diff_source.SourceMode,
    layout: Layout,
    mode_toggle_hint_width: u16 = 0,
    diagnostics: DiagnosticSink,

    fn sharedController(self: Controller) diff_surface.navigation.Controller {
        return .{
            .surface = self.page.diffSurface(self.source, self.layout),
            .repo_root = self.repo_root,
            .repo_epoch = self.repo_epoch,
            .mode_toggle_hint_width = self.mode_toggle_hint_width,
            .diagnostics = self.diagnostics,
        };
    }

    fn sharedBodyController(self: Controller, adapter: *ChangesBodyResolver) diff_surface.navigation.BodyController {
        return .{
            .controller = self.sharedController(),
            .resolver = adapter.interface(),
        };
    }

    fn bodyResolverAdapter(self: Controller) ChangesBodyResolver {
        return .{ .view = self.view() };
    }

    pub const UpdateAdapter = struct {
        navigation: Controller,
        resolver: ChangesBodyResolver,

        pub fn shared(self: *UpdateAdapter) diff_surface.update.Controller {
            return .{
                .navigation = self.navigation.sharedBodyController(&self.resolver),
                .toggle_hunk_fold = .{ .ctx = self, .callback = toggleHunkFold },
            };
        }

        fn toggleHunkFold(ctx: *anyopaque) void {
            const self: *UpdateAdapter = @ptrCast(@alignCast(ctx));
            self.navigation.toggleSelectedHunkFold();
        }
    };

    pub fn updateAdapter(self: Controller) UpdateAdapter {
        return .{
            .navigation = self,
            .resolver = self.bodyResolverAdapter(),
        };
    }

    pub fn view(self: Controller) View {
        return .{
            .page = self.page,
            .repo_root = self.repo_root,
            .repo_epoch = self.repo_epoch,
            .root_identity = self.root_identity,
            .source = self.source,
            .layout = self.layout,
            .mode_toggle_hint_width = self.mode_toggle_hint_width,
        };
    }

    pub fn setStatus(self: Controller, comptime fmt: []const u8, args: anytype) void {
        self.sharedController().setStatus(fmt, args);
    }

    pub fn stableOrderOptions(self: Controller, allocator: std.mem.Allocator) file_tree.StableOrderOptions {
        return self.sharedController().stableOrderOptions(allocator);
    }

    fn rebuildVisibleNodes(self: Controller, loaded: *LoadedDiff, allocator: std.mem.Allocator) !void {
        try self.sharedController().rebuildVisibleNodes(loaded, allocator);
    }

    pub fn pressDiffMouse(self: Controller, point: MousePoint) void {
        var adapter = self.bodyResolverAdapter();
        self.sharedBodyController(&adapter).pressDiffMouse(point);
    }

    pub fn dragDiffMouse(self: Controller, point_opt: ?MousePoint) void {
        var adapter = self.bodyResolverAdapter();
        self.sharedBodyController(&adapter).dragDiffMouse(point_opt);
    }

    pub fn clearDiffSelection(self: Controller) void {
        self.sharedController().clearDiffSelection();
    }

    pub fn clearMouseDiffSelection(self: Controller) void {
        self.sharedController().clearMouseDiffSelection();
    }

    pub fn clearKeyboardSideChoice(self: Controller) void {
        self.sharedController().clearKeyboardSideChoice();
    }

    pub fn clearCompletedSelectionWithViewport(self: Controller, allocator: std.mem.Allocator) void {
        var adapter = self.bodyResolverAdapter();
        self.sharedController().clearCompletedSelectionWithViewport(adapter.interface(), allocator);
    }

    pub fn clearCompletedSelectionAfterCopy(
        self: Controller,
        allocator: std.mem.Allocator,
        generation: u64,
    ) bool {
        return self.sharedController().clearCompletedSelectionAfterCopy(allocator, generation);
    }

    pub fn captureSelectionViewportAnchor(self: Controller) ?diff_surface.selection_action.SelectionViewportAnchor {
        return self.view().captureSelectionViewportAnchor();
    }

    pub fn restoreSelectionViewportAnchor(self: Controller, anchor: diff_surface.selection_action.SelectionViewportAnchor) void {
        self.page.viewer.diff_scroll = self.view().restoredSelectionViewportScroll(anchor);
    }

    pub fn selectFileDelta(self: Controller, delta: i2) void {
        var adapter = self.bodyResolverAdapter();
        self.sharedBodyController(&adapter).selectFileDelta(delta);
    }

    pub fn selectFileAbsolute(self: Controller, index: usize) void {
        var adapter = self.bodyResolverAdapter();
        self.sharedBodyController(&adapter).selectFileAbsolute(index);
    }

    pub fn selectLastFile(self: Controller) void {
        var adapter = self.bodyResolverAdapter();
        self.sharedBodyController(&adapter).selectLastFile();
    }

    pub fn selectSidebarNode(self: Controller, loaded: *LoadedDiff, node_index: usize) void {
        var adapter = self.bodyResolverAdapter();
        self.sharedBodyController(&adapter).selectSidebarNode(loaded, node_index);
    }

    pub fn toggleSelectedDirectory(self: Controller) !void {
        var adapter = self.bodyResolverAdapter();
        try self.sharedBodyController(&adapter).toggleSelectedDirectory();
    }

    pub fn clickSidebarNode(self: Controller, node_index: usize) !void {
        var adapter = self.bodyResolverAdapter();
        try self.sharedBodyController(&adapter).clickSidebarNode(node_index);
    }

    pub fn expandSelectedDirectory(self: Controller) !void {
        var adapter = self.bodyResolverAdapter();
        try self.sharedBodyController(&adapter).expandSelectedDirectory();
    }

    pub fn collapseOrSelectParentDirectory(self: Controller) !void {
        var adapter = self.bodyResolverAdapter();
        try self.sharedBodyController(&adapter).collapseOrSelectParentDirectory();
    }

    pub fn scrollDiff(self: Controller, direction: VerticalDirection) void {
        var adapter = self.bodyResolverAdapter();
        self.sharedBodyController(&adapter).scrollDiff(direction);
    }

    pub fn scrollDiffHorizontal(self: Controller, direction: HorizontalDirection) void {
        var adapter = self.bodyResolverAdapter();
        self.sharedBodyController(&adapter).scrollDiffHorizontal(direction);
    }

    pub fn scrollSidebarHorizontal(self: Controller, direction: HorizontalDirection) void {
        self.sharedController().scrollSidebarHorizontal(direction);
    }

    pub fn clampSidebarHorizontalScroll(self: Controller) void {
        self.sharedController().clampSidebarHorizontalScroll();
    }

    pub fn clampDiffHorizontalScrollToVisibleRows(self: Controller) void {
        var adapter = self.bodyResolverAdapter();
        self.sharedBodyController(&adapter).clampDiffHorizontalScrollToVisibleRows();
    }

    pub fn moveDiffCursorRows(self: Controller, direction: VerticalDirection) void {
        var adapter = self.bodyResolverAdapter();
        self.sharedBodyController(&adapter).moveDiffCursorRows(direction);
    }

    pub fn moveDiffCursorPage(self: Controller, direction: VerticalDirection) void {
        var adapter = self.bodyResolverAdapter();
        self.sharedBodyController(&adapter).moveDiffCursorPage(direction);
    }

    pub fn selectHunkDelta(self: Controller, delta: i2) void {
        var adapter = self.bodyResolverAdapter();
        self.sharedBodyController(&adapter).selectHunkDelta(delta);
    }

    pub fn toggleSelectedHunkFold(self: Controller) void {
        const target = self.view().resolvedTarget();
        if (target.hunk_interaction != .available) return;
        if (!diff_surface.navigation.resolvedTargetAllowsHunkFold(target)) {
            self.setStatus("hunk fold is unavailable for projected view", .{});
            return;
        }
        const hunk_index = self.view().selectedHunkIndex();
        const before_folded = if (hunk_index) |index| blk: {
            const folded = self.view().selectedFoldedHunks();
            break :blk if (index < folded.len) folded[index] else null;
        } else null;
        const viewport_anchor = self.captureSelectionViewportAnchor();
        var adapter = self.bodyResolverAdapter();
        self.sharedBodyController(&adapter).toggleSelectedHunkFold();
        const changed = if (hunk_index) |index| blk: {
            const folded = self.view().selectedFoldedHunks();
            break :blk index < folded.len and before_folded != null and folded[index] != before_folded.?;
        } else false;
        if (changed) {
            self.page.advanceSelectionLayoutRevision();
            if (viewport_anchor) |anchor| self.restoreSelectionViewportAnchor(anchor);
        }
    }

    pub fn clampDiffNavigation(self: Controller) void {
        var adapter = self.bodyResolverAdapter();
        self.sharedBodyController(&adapter).clampDiffNavigation();
    }

    pub fn clampDiffNavigationKeepingHunkVisible(self: Controller) void {
        var adapter = self.bodyResolverAdapter();
        self.sharedBodyController(&adapter).clampDiffNavigationKeepingHunkVisible();
    }

    pub fn resetDiffPosition(self: Controller) void {
        var adapter = self.bodyResolverAdapter();
        self.sharedBodyController(&adapter).resetDiffPosition();
    }

    pub fn enterSearchMode(self: Controller) void {
        var adapter = self.bodyResolverAdapter();
        self.sharedBodyController(&adapter).enterSearchMode();
    }

    pub fn cancelSearchMode(self: Controller) void {
        self.sharedController().cancelSearchMode();
    }

    pub fn clearSearch(self: Controller) void {
        self.sharedController().clearSearch();
    }

    /// Resets only Changes-local navigation after the shell commits a different
    /// repository identity. Repository selection and reload remain shell-owned.
    pub fn resetAfterRepositorySwitch(self: Controller) void {
        self.sharedController().resetAfterRepositorySwitch();
    }

    pub fn enterFileSearchMode(self: Controller, allocator: std.mem.Allocator) void {
        self.sharedController().enterFileSearchMode(allocator);
    }

    pub fn cancelFileSearchMode(self: Controller, allocator: std.mem.Allocator) void {
        self.sharedController().cancelFileSearchMode(allocator);
    }

    /// Rebuild the candidate projection from the current accepted sidebar
    /// without making a model replacement depend on search allocation. A
    /// failed rebuild keeps the prompt/input alive but publishes no candidate,
    /// so render and submit cannot observe a stale path borrow.
    pub fn rebuildFileSearchProjection(self: Controller, allocator: std.mem.Allocator) void {
        self.sharedController().rebuildFileSearchProjection(allocator);
    }

    fn currentFileSearchBasis(self: Controller) ?file_search.Basis {
        return self.sharedController().currentFileSearchBasis();
    }

    pub fn toggleReviewedFile(self: Controller, allocator: std.mem.Allocator) !void {
        var adapter = self.bodyResolverAdapter();
        try self.sharedBodyController(&adapter).toggleReviewedFile(allocator);
    }

    pub fn toggleHideReviewedFiles(self: Controller, allocator: std.mem.Allocator) !void {
        var adapter = self.bodyResolverAdapter();
        try self.sharedBodyController(&adapter).toggleHideReviewedFiles(allocator);
    }

    pub fn cycleChangedFileFilter(self: Controller, allocator: std.mem.Allocator) !void {
        var adapter = self.bodyResolverAdapter();
        try self.sharedBodyController(&adapter).cycleChangedFileFilter(allocator);
    }

    /// Replace the accepted Changes file-visibility lens transactionally.
    /// Search allocation is deliberately after the primary commit: failure
    /// may make the prompt unavailable, but cannot reject a valid lens change.
    fn replaceFileVisibilityLens(
        self: Controller,
        allocator: std.mem.Allocator,
        visible_allocator: std.mem.Allocator,
        hide_reviewed_files: bool,
        changed_file_filter: ChangedFileFilter,
    ) !void {
        var adapter = self.bodyResolverAdapter();
        try self.sharedBodyController(&adapter).replaceFileVisibilityLens(
            allocator,
            visible_allocator,
            hide_reviewed_files,
            changed_file_filter,
        );
    }

    pub fn submitFileSearch(self: Controller, allocator: std.mem.Allocator) void {
        var adapter = self.bodyResolverAdapter();
        self.sharedBodyController(&adapter).submitFileSearch(allocator);
    }

    fn submitFileSearchWithVisibleAllocator(
        self: Controller,
        allocator: std.mem.Allocator,
        visible_allocator_override: ?std.mem.Allocator,
    ) void {
        var adapter = self.bodyResolverAdapter();
        self.sharedBodyController(&adapter).submitFileSearchWithVisibleAllocator(
            allocator,
            visible_allocator_override,
        );
    }

    pub fn submitSearch(self: Controller) void {
        var adapter = self.bodyResolverAdapter();
        self.sharedBodyController(&adapter).submitSearch();
    }

    pub fn selectSearchMatch(self: Controller, direction: diff_search.Direction) void {
        var adapter = self.bodyResolverAdapter();
        self.sharedBodyController(&adapter).selectSearchMatch(direction);
    }

    pub fn refreshSearchForSelectedFile(self: Controller) void {
        var adapter = self.bodyResolverAdapter();
        self.sharedBodyController(&adapter).refreshSearchForSelectedFile();
    }

    pub fn clearSearchMatch(self: Controller) void {
        self.sharedController().clearSearchMatch();
    }

    pub fn setSearchMatch(self: Controller, match: diff_search.Match) void {
        var adapter = self.bodyResolverAdapter();
        self.sharedBodyController(&adapter).setSearchMatch(match);
    }

    pub fn updateSearchMatchOffset(self: Controller) void {
        var adapter = self.bodyResolverAdapter();
        self.sharedBodyController(&adapter).updateSearchMatchOffset();
    }

    pub fn blockUnsupportedSearchTarget(self: Controller) bool {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyController(&adapter).blockUnsupportedSearchTarget();
    }

    pub fn unfoldSearchMatchIfNeeded(self: Controller, match: diff_search.Match) void {
        var adapter = self.bodyResolverAdapter();
        self.sharedBodyController(&adapter).unfoldSearchMatchIfNeeded(match);
    }

    pub fn scrollSearchMatchIntoView(self: Controller) void {
        var adapter = self.bodyResolverAdapter();
        self.sharedBodyController(&adapter).scrollSearchMatchIntoView();
    }

    pub fn prepareActionCursor(
        self: Controller,
        allocator: std.mem.Allocator,
        repo_epoch: u64,
        root_identity: root_capability.Identity,
        kind: changes_page.action_cursor.TargetKind,
        path_key: []const u8,
    ) !changes_page.action_cursor.Prepared {
        const visible_row = if (self.view().activeLoadedDiffConst()) |loaded|
            loaded.visibleRowOfNode(self.page.viewer.selected_node) orelse 0
        else
            0;
        return changes_page.action_cursor.Prepared.init(
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
        prepared: *changes_page.action_cursor.Prepared,
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
        target: *const changes_page.action_cursor.Target,
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
        file_tree.expandAncestors(&loaded.collapsed_dirs, loaded.tree.nodes[node_index].path);
        prepared.commit(
            self.page.review_display.hide_reviewed_files,
            self.page.review_display.changed_file_filter,
        );
        return loaded.visibleRowOfNode(node_index) != null;
    }

    pub fn restoreReloadAnchor(self: Controller, loaded: *LoadedDiff, anchor: *const changes_page.ReloadAnchor) bool {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyController(&adapter).restoreReloadAnchor(loaded, anchor);
    }

    pub fn restoreSidebarIdentity(
        self: Controller,
        loaded: *LoadedDiff,
        identity: context.SidebarIdentity,
    ) bool {
        var adapter = self.bodyResolverAdapter();
        return self.sharedBodyController(&adapter).restoreSidebarIdentity(loaded, identity);
    }

    pub fn keepDiffCursorVisible(self: Controller) void {
        var adapter = self.bodyResolverAdapter();
        self.sharedBodyController(&adapter).keepDiffCursorVisible();
    }

    pub fn restoreSearchFromReloadAnchor(self: Controller, anchor: *const changes_page.ReloadAnchor) void {
        var adapter = self.bodyResolverAdapter();
        self.sharedBodyController(&adapter).restoreSearchFromReloadAnchor(anchor);
    }

    pub fn ensureTreeOrderScope(self: Controller, allocator: std.mem.Allocator) !void {
        try self.sharedController().ensureTreeOrderScope(allocator);
    }

    pub fn initializeDiffCursorForSelectedFile(self: Controller) void {
        var adapter = self.bodyResolverAdapter();
        self.sharedBodyController(&adapter).initializeDiffCursorForSelectedFile();
    }

    pub fn placeDiffCursorInComfortBand(self: Controller) void {
        var adapter = self.bodyResolverAdapter();
        self.sharedBodyController(&adapter).placeDiffCursorInComfortBand();
    }

    pub fn toggleSidebarVisibility(self: Controller) void {
        var adapter = self.bodyResolverAdapter();
        self.sharedBodyController(&adapter).toggleSidebarVisibility();
    }

    pub fn adjustSidebarWidth(self: Controller, direction: SizeDirection) void {
        var adapter = self.bodyResolverAdapter();
        self.sharedBodyController(&adapter).adjustSidebarWidth(direction);
    }

    pub fn resetDiffHorizontalScroll(self: Controller) void {
        self.sharedController().resetDiffHorizontalScroll();
    }

    pub fn resetDiffHorizontalScrollIfPaneWidthChanged(self: Controller, previous_width: u16) void {
        self.sharedController().resetDiffHorizontalScrollIfPaneWidthChanged(previous_width);
    }

    pub fn clampSelection(self: Controller, file_count: usize) void {
        var adapter = self.bodyResolverAdapter();
        self.sharedBodyController(&adapter).clampSelection(file_count);
    }

    pub fn reconcileSelectionAfterVisibleNodeChange(self: Controller, loaded: *LoadedDiff) void {
        var adapter = self.bodyResolverAdapter();
        self.sharedBodyController(&adapter).reconcileSelectionAfterVisibleNodeChange(loaded);
    }

    pub fn setSelectedDiffFile(self: Controller, file_index: usize) void {
        self.sharedController().setSelectedDiffFile(file_index);
    }

    pub fn syncSidebarNodeToSelectedFile(self: Controller, loaded: *const LoadedDiff) void {
        self.sharedController().syncSidebarNodeToSelectedFile(loaded);
    }

    pub fn selectFirstVisibleFile(self: Controller, loaded: *LoadedDiff) void {
        var adapter = self.bodyResolverAdapter();
        self.sharedBodyController(&adapter).selectFirstVisibleFile(loaded);
    }

    pub fn materializeReviewedFiles(self: Controller, allocator: std.mem.Allocator, loaded: *LoadedDiff) !void {
        try self.sharedController().materializeReviewedFiles(allocator, loaded);
    }

    pub fn activeLoadedDiff(self: Controller) ?*LoadedDiff {
        return self.sharedController().activeLoadedDiff();
    }

    pub const ExactPathTarget = union(enum) {
        ready: usize,
        unavailable: page_link.ChangesUnavailableReason,
    };

    pub const ExactPathRevealResult = union(enum) {
        selected: usize,
        unchanged: usize,
        unavailable: page_link.ChangesUnavailableReason,
    };

    /// Classify one Repository path against the accepted retained Changes
    /// without changing folds, filters, selection, search, or diff position.
    /// The mutation half consumes only the `ready` node synchronously;
    /// an unavailable result is never retained for a future reload.
    pub fn exactPathTarget(self: Controller, intent: page_link.ChangesLocationIntent) ExactPathTarget {
        if (!diff_source.sourceAllowsRepositoryLink(self.source)) {
            return .{ .unavailable = .source_unavailable };
        }
        const active_root = self.root_identity orelse return .{ .unavailable = .repository_mismatch };
        if (intent.repo_epoch != self.repo_epoch or !intent.root_identity.eql(active_root)) {
            return .{ .unavailable = .repository_mismatch };
        }
        const loaded = self.activeLoadedDiff() orelse return .{ .unavailable = .no_accepted_changes };
        const node_index = findFileNodeByPathKey(loaded, intent.path) orelse
            return .{ .unavailable = .path_not_found };
        if (!loaded.shouldIncludeFileNode(
            node_index,
            self.page.review_display.hide_reviewed_files,
            self.page.review_display.changed_file_filter,
        )) return .{ .unavailable = .hidden_by_filters };
        return .{ .ready = node_index };
    }

    /// Reveal and select one exact file without retaining the borrowed request.
    /// Fallible visible-tree preparation completes before
    /// collapsed ancestors or Changes navigation state can change.
    pub fn revealExactPath(self: Controller, intent: page_link.ChangesLocationIntent) !ExactPathRevealResult {
        return self.revealExactPathWithAllocator(intent, null);
    }

    fn revealExactPathWithAllocator(
        self: Controller,
        intent: page_link.ChangesLocationIntent,
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

    /// Commit one already validated exact file node through the Changes
    /// ancestor-reveal and navigation transaction. Candidate/path admission and
    /// caller-specific failure policy deliberately remain outside this helper.
    fn revealAndSelectExactNode(
        self: Controller,
        loaded: *LoadedDiff,
        node_index: usize,
        visible_allocator: ?std.mem.Allocator,
    ) !void {
        var adapter = self.bodyResolverAdapter();
        try self.sharedBodyController(&adapter).revealAndSelectExactNode(
            loaded,
            node_index,
            visible_allocator,
        );
    }

    pub fn loadArenaAllocator(self: Controller) ?std.mem.Allocator {
        return self.sharedController().loadArenaAllocator();
    }
};

pub fn findNodeBySidebarIdentity(
    loaded: *const LoadedDiff,
    identity: context.SidebarIdentity,
) ?usize {
    return diff_surface.navigation.findNodeBySidebarIdentity(loaded, identity);
}

fn typedActionNode(
    loaded: *const LoadedDiff,
    target: *const changes_page.action_cursor.Target,
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
    return diff_surface.navigation.findFileNodeByPathKey(loaded, path_key);
}

pub fn nearestVisibleFileNode(loaded: *const LoadedDiff, visible_row: usize) ?usize {
    return diff_surface.navigation.nearestVisibleFileNode(loaded, visible_row);
}

fn projectionSourceKind(source: diff_source.SourceMode) changes_projection.SourceKind {
    return switch (source) {
        .cached => .cached,
        else => .unstaged,
    };
}

const SelectionRegion = diff_surface.SelectionRegion;
const ParsedMouseLine = diff_surface.ParsedMouseLine;

fn parsedMouseLine(
    target: ParsedSelectionTarget,
    body_col: u16,
    body_width: u16,
    display_mode: diff_render.DisplayMode,
    offset: usize,
    line_numbers: bool,
    locked: ?diff_selection.DragSelection,
) ?ParsedMouseLine {
    return diff_surface.navigation.parsedMouseLine(target, body_col, body_width, display_mode, offset, line_numbers, locked);
}

fn indexedLineForSide(row: diff_view_model.SideBySideIndexedRow, side: diff_selection.Side) ?diff_view_model.IndexedDiffLine {
    return diff_surface.navigation.indexedLineForSide(row, side);
}

fn selectionRegionForUnified(body_col: u16, line_numbers: bool, line: diff_parser.DiffLine, locked: ?diff_selection.DragSelection) ?SelectionRegion {
    return diff_surface.navigation.selectionRegionForUnified(body_col, line_numbers, line, locked);
}

fn selectionRegionForGenerated(body_col: u16, body_width: u16, display_mode: diff_render.DisplayMode, line_numbers: bool, locked: ?diff_selection.DragSelection) ?SelectionRegion {
    return diff_surface.navigation.selectionRegionForGenerated(body_col, body_width, display_mode, line_numbers, locked);
}

fn pointForTextCell(hunk_index: usize, line_index: usize, text: []const u8, mode: diff_selection.Mode, horizontal_scroll: usize, viewport_cell: usize) ?diff_selection.Point {
    return diff_surface.navigation.pointForTextCell(hunk_index, line_index, text, mode, horizontal_scroll, viewport_cell);
}

fn contentWidth(width: u16) u16 {
    return diff_surface.navigation.contentWidth(width);
}

fn sidebarWidth(total_width: u16, preferred_width: ?u16) u16 {
    return diff_surface.navigation.sidebarWidth(total_width, preferred_width);
}

fn maxHorizontalScrollForBodyRow(body_row: diff_view_model.BodyRow, body_width: u16, line_numbers: bool) usize {
    return diff_surface.navigation.maxHorizontalScrollForBodyRow(body_row, body_width, line_numbers);
}

fn maxHorizontalScrollForSideBySideRow(side_row: diff_view_model.SideBySideRow, body_width: u16, line_numbers: bool) usize {
    return diff_surface.navigation.maxHorizontalScrollForSideBySideRow(side_row, body_width, line_numbers);
}

fn visibleTextWidth(total_width: u16, text_col: u16) u16 {
    return diff_surface.navigation.visibleTextWidth(total_width, text_col);
}

fn maxHorizontalScrollForText(text: []const u8, visible_width: u16) usize {
    return diff_surface.navigation.maxHorizontalScrollForText(text, visible_width);
}

const TestHarness = struct {
    const PageStates = struct {
        changes: changes_page.ChangesPageState = .{},
    };

    pages: PageStates = .{},
    status: app_state.StatusMessage = .{},
    source: diff_source.SourceMode = .unstaged,
    repo_root: ?[]const u8 = null,
    repo_epoch: u64 = 0,
    root_identity: ?root_capability.Identity = null,
    terminal_size: chasen.Size = .{ .width = 100, .height = 20 },
    allocator: ?std.mem.Allocator = null,

    fn init(page: changes_page.ChangesPageState, terminal_size: chasen.Size) TestHarness {
        return .{
            .pages = .{ .changes = page },
            .terminal_size = terminal_size,
        };
    }

    fn controller(self: *TestHarness) Controller {
        const body_size = shell_layout.compute(self.terminal_size, .{ .page_bar_visible = true }).bodySize();
        return .{
            .page = &self.pages.changes,
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
            .page = &self.pages.changes,
            .repo_root = self.repo_root,
            .repo_epoch = self.repo_epoch,
            .root_identity = self.root_identity,
            .source = self.source,
            .layout = .{ .width = body_size.width, .height = body_size.height },
        };
    }

    fn changesNavigation(self: *TestHarness) Controller {
        return self.controller();
    }

    fn changesNavigationView(self: *const TestHarness) View {
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
        self.pages.changes.source_session_revision +%= 1;
        self.controller().clearDiffSelection();
        self.pages.changes.load.clearCurrent(self.allocator);
        if (self.allocator) |allocator| {
            self.pages.changes.changes_projection.deinit(allocator);
            self.pages.changes.staged_hunks.clear(allocator);
        }
        self.pages.changes.viewer.diff_scroll = 0;
        self.pages.changes.viewer.diff_horizontal_scroll = 0;
        self.pages.changes.viewer.sidebar_horizontal_scroll = 0;
        self.pages.changes.viewer.diff_cursor = .{ .metadata = 0 };
        self.controller().clearSearchMatch();
    }
};

const displayed_body_horizontal_scroll_wide_text =
    "wide-0123456789-abcdefghijklmnopqrstuvwxyz-ABCDEFGHIJKLMNOPQRSTUVWXYZ-" ++
    "0123456789-abcdefghijklmnopqrstuvwxyz-ABCDEFGHIJKLMNOPQRSTUVWXYZ-" ++
    "0123456789-abcdefghijklmnopqrstuvwxyz-ABCDEFGHIJKLMNOPQRSTUVWXYZ";

const displayed_body_horizontal_scroll_cached_patch =
    "diff --git a/a b/a\n" ++
    "index 1111111..2222222 100644\n" ++
    "--- a/a\n" ++
    "+++ b/a\n" ++
    "@@ -10 +10 @@\n" ++
    "-old staged\n" ++
    "+" ++ displayed_body_horizontal_scroll_wide_text ++ "\n";

const displayed_body_horizontal_scroll_unstaged_patch =
    "diff --git a/a b/a\n" ++
    "index 2222222..3333333 100644\n" ++
    "--- a/a\n" ++
    "+++ b/a\n" ++
    "@@ -20 +20 @@\n" ++
    "-old unstaged\n" ++
    "+new unstaged\n";

const displayed_body_horizontal_scroll_retained_authority_patch =
    "diff --git a/a b/a\n" ++
    "index 1111111..3333333 100644\n" ++
    "--- a/a\n" ++
    "+++ b/a\n" ++
    "@@ -10 +10 @@\n" ++
    "-old staged\n" ++
    "+" ++ displayed_body_horizontal_scroll_wide_text ++ "\n" ++
    "@@ -20 +20 @@\n" ++
    "-old unstaged\n" ++
    "+new unstaged\n";

fn prepareStatusOnlyHorizontalScrollHarness(
    harness: *TestHarness,
    allocator: std.mem.Allocator,
    status_text: []const u8,
) !void {
    harness.repo_root = "/repo";
    _ = harness.pages.changes.activation.activate(0, .fresh, .fresh, .fresh);
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, status_text);
    try harness.pages.changes.git_status.replace("/repo", &status_bundle);
}

fn initProjectionHunkFoldHarness(allocator: std.mem.Allocator) !TestHarness {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    var loaded = app_test_support.loadedDiffOne();
    loaded.collapsed_hunks = try arena.allocator().alloc(bool, loaded.document.totalHunks());
    @memset(loaded.collapsed_hunks, false);
    loaded.rendered_line_cache = try diff_view_model.RenderedLineCache.build(arena.allocator(), loaded.document);

    return TestHarness.init(.{
        .load = app_test_support.loadStateWithArena(arena, loaded),
        .viewer = .{
            .selected_target = .{ .diff_file = 0 },
            .diff_cursor = .{ .hunk_header = 0 },
            .diff_scroll = 2,
            .diff_horizontal_scroll = 3,
        },
        .search = .{
            .match = .{ .coordinate = .{ .metadata = 0 } },
            .match_offset = 0,
        },
    }, .{ .width = 100, .height = 12 });
}

fn installCachedHunkFoldProjection(
    harness: *TestHarness,
    allocator: std.mem.Allocator,
) !void {
    var cached_bundle = try app_load.buildLoadedBundle(
        allocator,
        displayed_body_horizontal_scroll_cached_patch,
    );
    errdefer cached_bundle.deinit();
    var request = try changes_projection.testing.cloneRequest(
        allocator,
        harness.pages.changes.activation.currentIdentity().?,
        1,
        "/repo",
        "a",
        .cached_diff,
        .unstaged,
        harness.pages.changes.source_session_revision,
        harness.pages.changes.status_snapshot_revision,
    );
    errdefer request.deinit(allocator);
    harness.pages.changes.changes_projection.installReady(.{
        .request = request,
        .value = .{ .cached_diff = cached_bundle },
    });
}

fn expectProjectionHunkFoldDenied(
    harness: *TestHarness,
    allocator: std.mem.Allocator,
) !void {
    const active = harness.controller().activeLoadedDiff() orelse return error.ExpectedLoadedDiff;
    const folded_before = active.isHunkFolded(0, 0);
    const unified_lines_before = active.renderedLineIndex(0, .unified).lineCount();
    const unified_hunk_lines_before = active.renderedLineIndex(0, .unified).hunkLineCount(0);
    const side_by_side_lines_before = active.renderedLineIndex(0, .side_by_side).lineCount();
    const cursor_before = harness.pages.changes.viewer.diff_cursor;
    const scroll_before = harness.pages.changes.viewer.diff_scroll;
    const horizontal_scroll_before = harness.pages.changes.viewer.diff_horizontal_scroll;
    const search_before = harness.pages.changes.search;

    try std.testing.expectEqual(HunkInteractionAvailability.available, harness.view().hunkInteractionAvailability());
    try std.testing.expect(harness.view().selectedHunkIndex() != null);
    try std.testing.expect(!harness.view().bodyAllowsHunkFold());
    try std.testing.expectEqual(@as(usize, 0), harness.view().selectedFoldedHunks().len);
    var display_arena: std.heap.ArenaAllocator = .init(allocator);
    defer display_arena.deinit();
    const display = (try harness.view().activeDiffDisplay(display_arena.allocator(), .unified)) orelse
        return error.ExpectedActiveDiffDisplay;
    try std.testing.expectEqual(@as(usize, 0), display.foldedHunks().len);

    var controller = harness.controller();
    var resolver = controller.bodyResolverAdapter();
    controller.sharedBodyController(&resolver).toggleSelectedHunkFold();
    try std.testing.expectEqual(folded_before, active.isHunkFolded(0, 0));
    try std.testing.expectEqual(unified_lines_before, active.renderedLineIndex(0, .unified).lineCount());
    try std.testing.expectEqual(unified_hunk_lines_before, active.renderedLineIndex(0, .unified).hunkLineCount(0));
    try std.testing.expectEqual(side_by_side_lines_before, active.renderedLineIndex(0, .side_by_side).lineCount());
    try std.testing.expectEqualDeep(cursor_before, harness.pages.changes.viewer.diff_cursor);
    try std.testing.expectEqual(scroll_before, harness.pages.changes.viewer.diff_scroll);
    try std.testing.expectEqual(horizontal_scroll_before, harness.pages.changes.viewer.diff_horizontal_scroll);
    try std.testing.expectEqualDeep(search_before, harness.pages.changes.search);
    try std.testing.expectEqualStrings("", harness.status.text());

    harness.controller().toggleSelectedHunkFold();
    try std.testing.expectEqual(folded_before, active.isHunkFolded(0, 0));
    try std.testing.expectEqual(unified_lines_before, active.renderedLineIndex(0, .unified).lineCount());
    try std.testing.expectEqual(unified_hunk_lines_before, active.renderedLineIndex(0, .unified).hunkLineCount(0));
    try std.testing.expectEqual(side_by_side_lines_before, active.renderedLineIndex(0, .side_by_side).lineCount());
    try std.testing.expectEqualDeep(cursor_before, harness.pages.changes.viewer.diff_cursor);
    try std.testing.expectEqual(scroll_before, harness.pages.changes.viewer.diff_scroll);
    try std.testing.expectEqual(horizontal_scroll_before, harness.pages.changes.viewer.diff_horizontal_scroll);
    try std.testing.expectEqualDeep(search_before, harness.pages.changes.search);
    try std.testing.expectEqualStrings(
        "hunk fold is unavailable for projected view",
        harness.status.text(),
    );
}

fn expectResolverRenderContains(harness: *TestHarness, needle: []const u8) !void {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 12);
    defer ts.deinit();
    try harness.view().renderProjectedBody(.{
        .surface = &ts.surface,
        .requested_mode = harness.pages.changes.viewer.display_mode,
        .scroll = harness.pages.changes.viewer.diff_scroll,
        .horizontal_scroll = harness.pages.changes.viewer.diff_horizontal_scroll,
        .pane_active = true,
        .line_numbers = harness.pages.changes.viewer.view_options.line_numbers,
        .highlighted_hunk = harness.view().selectedHunkIndex(),
        .cursor_offset = harness.view().visibleDiffCursorOffset(),
        .palette = .default(),
        .selection = harness.view().diffSelectionView(),
        .header_selection = harness.view().diffHeaderSelectionActive(),
    });
    try test_support.expectSnapshotContains(&ts, needle);
}

fn expectResolverRenderOmits(harness: *TestHarness, needle: []const u8) !void {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 12);
    defer ts.deinit();
    try harness.view().renderProjectedBody(.{
        .surface = &ts.surface,
        .requested_mode = harness.pages.changes.viewer.display_mode,
        .scroll = harness.pages.changes.viewer.diff_scroll,
        .horizontal_scroll = harness.pages.changes.viewer.diff_horizontal_scroll,
        .pane_active = true,
        .line_numbers = harness.pages.changes.viewer.view_options.line_numbers,
        .highlighted_hunk = harness.view().selectedHunkIndex(),
        .cursor_offset = harness.view().visibleDiffCursorOffset(),
        .palette = .default(),
        .selection = harness.view().diffSelectionView(),
        .header_selection = harness.view().diffHeaderSelectionActive(),
    });
    try test_support.expectSnapshotNotContains(&ts, needle);
}

fn installCombinedHorizontalScrollProjection(
    harness: *TestHarness,
    allocator: std.mem.Allocator,
) !void {
    var cached_bundle = try app_load.buildLoadedBundle(allocator, displayed_body_horizontal_scroll_cached_patch);
    errdefer cached_bundle.deinit();
    var unstaged_bundle = try app_load.buildLoadedBundle(allocator, displayed_body_horizontal_scroll_unstaged_patch);
    errdefer unstaged_bundle.deinit();
    var cached_authority = try projection_component.ParsedComponent.parse(allocator, displayed_body_horizontal_scroll_cached_patch);
    errdefer cached_authority.deinit();
    var unstaged_authority = try projection_component.ParsedComponent.parse(allocator, displayed_body_horizontal_scroll_unstaged_patch);
    errdefer unstaged_authority.deinit();
    var presentation_arena = std.heap.ArenaAllocator.init(allocator);
    errdefer presentation_arena.deinit();
    var authority_arena = std.heap.ArenaAllocator.init(allocator);
    errdefer authority_arena.deinit();
    const projection = try diff_hunk_projection.buildWithAllocators(
        presentation_arena.allocator(),
        authority_arena.allocator(),
        cached_bundle.loaded.document.files[0],
        unstaged_bundle.loaded.document.files[0],
    );
    var request = try changes_projection.testing.cloneRequest(
        allocator,
        harness.pages.changes.activation.currentIdentity().?,
        1,
        "/repo",
        "a",
        .combined_hunks,
        .unstaged,
        harness.pages.changes.source_session_revision,
        harness.pages.changes.status_snapshot_revision,
    );
    errdefer request.deinit(allocator);

    harness.pages.changes.changes_projection.installReady(.{
        .request = request,
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
                .status_snapshot_revision = harness.pages.changes.status_snapshot_revision,
            },
        } },
    });
}

fn retainCombinedHorizontalScrollProjection(
    harness: *TestHarness,
    allocator: std.mem.Allocator,
) !void {
    const displayed = harness.pages.changes.changes_projection.displayed.ready.value.combined_hunks.displayFile();
    var cached_component = try projection_component.ParsedComponent.parse(
        allocator,
        displayed_body_horizontal_scroll_retained_authority_patch,
    );
    errdefer cached_component.deinit();
    if (!diff_presentation_identity.exactEqual(displayed, cached_component.document.files[0])) {
        return error.InvalidHorizontalScrollTestFixture;
    }

    const authority_allocator = cached_component.arena.?.allocator();
    const hunk_count = cached_component.document.files[0].hunks.len;
    const stage_states = try authority_allocator.alloc(diff_hunk_projection.HunkStageState, hunk_count);
    @memset(stage_states, .staged);
    const action_origins = try authority_allocator.alloc(diff_hunk_projection.HunkActionOrigin, hunk_count);
    for (action_origins, 0..) |*origin, hunk_index| {
        origin.* = .{ .cached = hunk_index };
    }

    var request = try changes_projection.testing.cloneRequest(
        allocator,
        harness.pages.changes.activation.currentIdentity().?,
        2,
        "/repo",
        "a",
        .cached_diff,
        .unstaged,
        harness.pages.changes.source_session_revision,
        harness.pages.changes.status_snapshot_revision,
    );
    errdefer request.deinit(allocator);
    var candidate: changes_projection.StagedOnlyReuseCandidate = .{
        .fingerprint = diff_presentation_identity.fingerprint(cached_component.document.files[0]),
        .fresh_authority = .{
            .projection = .{
                .hunk_stage_states = stage_states,
                .hunk_action_origins = action_origins,
            },
            .cached_component = cached_component,
            .status_snapshot_revision = harness.pages.changes.status_snapshot_revision,
        },
    };
    harness.pages.changes.changes_projection.installRetainedStagedOnlyReuse(
        allocator,
        request,
        &candidate,
    );
    candidate.deinit();
}

fn expectDisplayedBodyHorizontalScrollGeometry(harness: *TestHarness) !void {
    harness.terminal_size = .{ .width = 140, .height = 16 };
    harness.pages.changes.viewer.diff_scroll = 0;
    inline for ([_]diff_render.DisplayMode{ .unified, .side_by_side }) |mode| {
        harness.pages.changes.viewer.display_mode = mode;
        harness.pages.changes.viewer.view_options.line_numbers = true;
        const with_line_numbers = harness.view().visibleBodyTextMaxHorizontalScroll();
        const expected_with_line_numbers: usize = switch (mode) {
            .unified => 76,
            .side_by_side => 139,
        };
        try std.testing.expectEqual(expected_with_line_numbers, with_line_numbers);

        harness.pages.changes.viewer.diff_horizontal_scroll = 0;
        harness.controller().scrollDiffHorizontal(.right);
        try std.testing.expectEqual(@as(usize, 8), harness.pages.changes.viewer.diff_horizontal_scroll);

        harness.pages.changes.viewer.view_options.line_numbers = false;
        const without_line_numbers = harness.view().visibleBodyTextMaxHorizontalScroll();
        const expected_without_line_numbers: usize = switch (mode) {
            .unified => 66,
            .side_by_side => 134,
        };
        try std.testing.expectEqual(expected_without_line_numbers, without_line_numbers);
    }

    harness.terminal_size = .{ .width = 60, .height = 16 };
    harness.pages.changes.viewer.view_options.line_numbers = true;
    harness.pages.changes.viewer.display_mode = .side_by_side;
    try std.testing.expectEqual(diff_render.DisplayMode.unified, harness.view().effectiveDisplayMode());
    const requested_side_by_side = harness.view().visibleBodyTextMaxHorizontalScroll();
    harness.pages.changes.viewer.display_mode = .unified;
    try std.testing.expectEqual(requested_side_by_side, harness.view().visibleBodyTextMaxHorizontalScroll());
}

fn exactChangesIntent(app: *const TestHarness, path: []const u8) page_link.ChangesLocationIntent {
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
            std.debug.print("expected exact Changes path, found unavailable reason {s}\n", .{@tagName(reason)});
            return error.TestUnexpectedResult;
        },
    }
}

fn expectExactPathUnavailable(
    target: Controller.ExactPathTarget,
    expected: page_link.ChangesUnavailableReason,
) !void {
    switch (target) {
        .ready => |node_index| {
            std.debug.print("expected unavailable Changes path, found node {d}\n", .{node_index});
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
    expected: page_link.ChangesUnavailableReason,
) !void {
    switch (result) {
        .unavailable => |actual| try std.testing.expectEqual(expected, actual),
        .selected => return error.TestUnexpectedSelection,
        .unchanged => return error.TestUnexpectedUnchanged,
    }
}

fn expectSearchCoordinate(app: *const TestHarness, expected: diff_view_model.BodyCoordinate) !void {
    try std.testing.expect(app.pages.changes.search.match != null);
    try std.testing.expect(std.meta.eql(expected, app.pages.changes.search.match.?.coordinate));
}

fn setDiffSearchQuery(app: *TestHarness, query: []const u8) void {
    @memcpy(app.pages.changes.search.query.buffer[0..query.len], query);
    app.pages.changes.search.query.len = query.len;
    app.pages.changes.search.query.cursor = query.len;
    @memcpy(app.pages.changes.search.input.buffer[0..query.len], query);
    app.pages.changes.search.input.len = query.len;
    app.pages.changes.search.input.cursor = query.len;
}

fn setDiffSearchInput(app: *TestHarness, query: []const u8) void {
    @memcpy(app.pages.changes.search.input.buffer[0..query.len], query);
    app.pages.changes.search.input.len = query.len;
    app.pages.changes.search.input.cursor = query.len;
}

fn setFileSearchInput(app: *TestHarness, query: []const u8) void {
    app.pages.changes.file_search.input = .{};
    @memcpy(app.pages.changes.file_search.input.buffer[0..query.len], query);
    app.pages.changes.file_search.input.len = query.len;
    app.pages.changes.file_search.input.cursor = query.len;
}

fn setAndRebuildFileSearch(app: *TestHarness, query: []const u8) void {
    setFileSearchInput(app, query);
    app.changesNavigation().rebuildFileSearchProjection(std.testing.allocator);
}

fn applySharedNavigation(app: *TestHarness, msg: diff_surface.message.Msg) !bool {
    var adapter = app.controller().updateAdapter();
    var outcome = try adapter.shared().apply(null, msg);
    defer outcome.deinit(null);
    return outcome.display_navigation_changed;
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

test "Changes navigation keeps diff position at file selection boundary" {
    var harness = TestHarness.init(.{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{
            .diff_scroll = 4,
            .diff_cursor = .{ .hunk_header = 1 },
        },
    }, .{ .width = 100, .height = 8 });

    harness.controller().selectFileDelta(-1);
    const loaded = harness.controller().activeLoadedDiff().?;
    try std.testing.expectEqual(@as(?usize, 0), harness.view().selectedFileIndex(loaded));
    try std.testing.expectEqual(@as(usize, 4), harness.pages.changes.viewer.diff_scroll);
    try std.testing.expectEqual(@as(?usize, 1), harness.view().selectedHunkIndex());

    harness.controller().selectFileAbsolute(0);
    try std.testing.expectEqual(@as(usize, 4), harness.pages.changes.viewer.diff_scroll);
    try std.testing.expectEqual(@as(?usize, 1), harness.view().selectedHunkIndex());
}

test "Changes navigation keeps diff cursor visible across mode changes" {
    var harness = TestHarness.init(.{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{
            .display_mode = .unified,
            .diff_cursor = .{ .hunk_header = 1 },
        },
    }, .{ .width = 100, .height = 9 });

    harness.controller().placeDiffCursorInComfortBand();
    try std.testing.expect(harness.pages.changes.viewer.diff_scroll > 0);

    harness.pages.changes.viewer.display_mode = .side_by_side;
    harness.controller().clampDiffNavigationKeepingHunkVisible();

    const target = diff_view_model.hunkBodyLineOffset(
        test_support.file_with_hunks,
        harness.view().effectiveDisplayMode(),
        harness.view().selectedHunkIndex().?,
    );
    const visible_rows = harness.view().diffVisibleRows();
    try std.testing.expect(target >= harness.pages.changes.viewer.diff_scroll);
    try std.testing.expect(target < harness.pages.changes.viewer.diff_scroll + visible_rows);
}

test "Changes navigation initializes cursor at first rendered body row" {
    var metadata = TestHarness.init(.{
        .load = test_support.loadState(test_support.loadedDiffMetadataOnly()),
    }, .{ .width = 100, .height = 12 });
    metadata.controller().initializeDiffCursorForSelectedFile();
    try std.testing.expectEqual(diff_view_model.BodyCoordinate{ .metadata = 1 }, metadata.pages.changes.viewer.diff_cursor);
    try std.testing.expectEqual(@as(?usize, 0), metadata.view().visibleDiffCursorOffset());
    const metadata_cursor = metadata.pages.changes.viewer.diff_cursor;
    metadata.controller().scrollDiff(.down);
    try std.testing.expectEqual(@as(usize, 0), metadata.pages.changes.viewer.diff_scroll);
    try std.testing.expectEqual(metadata_cursor, metadata.pages.changes.viewer.diff_cursor);

    var binary = TestHarness.init(.{
        .load = test_support.loadState(test_support.loadedDiffBinaryOnly()),
    }, .{ .width = 100, .height = 12 });
    binary.controller().initializeDiffCursorForSelectedFile();
    try std.testing.expectEqual(diff_view_model.BodyCoordinate.binary_marker, binary.pages.changes.viewer.diff_cursor);
    try std.testing.expectEqual(@as(?usize, 0), binary.view().visibleDiffCursorOffset());
    const binary_cursor = binary.pages.changes.viewer.diff_cursor;
    const binary_snapshot = binary.view().displayNavigationSnapshot();
    for ([_]diff_surface.message.Msg{
        .document_first,
        .document_last,
        .half_page_up,
        .half_page_down,
        .page_diff_up,
        .page_diff_down,
    }) |msg| {
        try std.testing.expect(!try applySharedNavigation(&binary, msg));
        try std.testing.expectEqualDeep(binary_snapshot, binary.view().displayNavigationSnapshot());
    }
    binary.controller().scrollDiff(.down);
    try std.testing.expectEqual(@as(usize, 0), binary.pages.changes.viewer.diff_scroll);
    try std.testing.expectEqual(binary_cursor, binary.pages.changes.viewer.diff_cursor);
}

test "document navigation applies first last half and full page on rendered rows" {
    var harness = TestHarness.init(.{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{
            .display_mode = .unified,
            .sidebar_hidden = true,
        },
    }, .{ .width = 140, .height = 15 });
    const visible_rows = harness.view().diffVisibleRows();
    const margin = @min(@as(usize, 8), visible_rows / 3);
    const band_last = visible_rows - 1 -| margin;
    const line_count = harness.view().displayedDiffLineCount();

    harness.pages.changes.viewer.diff_cursor = harness.view().selectedCoordinateAtOffset(0) orelse
        return error.ExpectedCoordinate;
    try std.testing.expect(try applySharedNavigation(&harness, .half_page_down));
    try std.testing.expectEqual(
        @as(?usize, @min(@max(visible_rows / 2, 1), line_count - 1)),
        harness.view().selectedDiffCursorOffset(),
    );
    try std.testing.expect(try applySharedNavigation(&harness, .document_last));
    try std.testing.expectEqual(@as(?usize, line_count - 1), harness.view().selectedDiffCursorOffset());
    try std.testing.expect(try applySharedNavigation(&harness, .document_first));
    try std.testing.expectEqual(@as(?usize, 0), harness.view().selectedDiffCursorOffset());

    const viewport_cases = [_]struct { height: u16, visible_rows: usize }{
        .{ .height = 8, .visible_rows = 0 },
        .{ .height = 9, .visible_rows = 1 },
        .{ .height = 10, .visible_rows = 2 },
        .{ .height = 11, .visible_rows = 3 },
        .{ .height = 12, .visible_rows = 4 },
    };
    for (viewport_cases) |case| {
        harness.terminal_size.height = case.height;
        try std.testing.expectEqual(case.visible_rows, harness.view().diffVisibleRows());
        harness.pages.changes.viewer.diff_cursor = harness.view().selectedCoordinateAtOffset(0) orelse
            return error.ExpectedCoordinate;
        _ = try applySharedNavigation(&harness, .half_page_down);
        const half_step = @max(harness.view().diffVisibleRows() / 2, 1);
        try std.testing.expectEqual(
            @as(?usize, @min(half_step, line_count - 1)),
            harness.view().selectedDiffCursorOffset(),
        );
    }
    harness.terminal_size.height = 15;
    harness.pages.changes.viewer.display_mode = .side_by_side;
    _ = try applySharedNavigation(&harness, .document_last);
    _ = try applySharedNavigation(&harness, .document_first);
    harness.pages.changes.viewer.display_mode = .unified;

    harness.pages.changes.viewer.diff_cursor = harness.view().selectedCoordinateAtOffset(band_last - 1) orelse
        return error.ExpectedCoordinate;
    harness.controller().moveDiffCursorRows(.down);
    try std.testing.expectEqual(@as(usize, 0), harness.pages.changes.viewer.diff_scroll);
    try std.testing.expectEqual(@as(?usize, band_last), harness.view().selectedDiffCursorOffset());

    harness.controller().moveDiffCursorRows(.down);
    try std.testing.expectEqual(@as(usize, 1), harness.pages.changes.viewer.diff_scroll);
    try std.testing.expectEqual(@as(?usize, band_last + 1), harness.view().selectedDiffCursorOffset());

    harness.pages.changes.viewer.diff_scroll = 0;
    harness.pages.changes.viewer.diff_cursor = harness.view().selectedCoordinateAtOffset(0) orelse
        return error.ExpectedCoordinate;
    _ = try applySharedNavigation(&harness, .page_diff_down);
    const page_offset = harness.view().selectedDiffCursorOffset() orelse return error.ExpectedCursorOffset;
    try std.testing.expectEqual(@as(usize, visible_rows), page_offset);
    try std.testing.expectEqual(
        @min(page_offset -| (visible_rows / 2), line_count -| visible_rows),
        harness.pages.changes.viewer.diff_scroll,
    );

    harness.pages.changes.viewer.diff_scroll = 0;
    harness.pages.changes.viewer.diff_cursor = .{ .hunk_header = 0 };
    harness.controller().selectHunkDelta(1);
    const hunk_offset = harness.view().selectedDiffCursorOffset() orelse return error.ExpectedCursorOffset;
    const hunk_row = hunk_offset - harness.pages.changes.viewer.diff_scroll;
    try std.testing.expect(hunk_row >= margin and hunk_row <= band_last);

    harness.pages.changes.viewer.diff_scroll = 0;
    setDiffSearchQuery(&harness, "new");
    harness.controller().submitSearch();
    const search_offset = harness.view().selectedDiffCursorOffset() orelse return error.ExpectedCursorOffset;
    const search_row = search_offset - harness.pages.changes.viewer.diff_scroll;
    try std.testing.expect(search_row >= margin and search_row <= band_last);

    harness.terminal_size.height = 8;
    harness.pages.changes.viewer.diff_scroll = 1;
    harness.pages.changes.viewer.diff_cursor = .{ .hunk_header = 0 };
    const zero_height_cursor = harness.pages.changes.viewer.diff_cursor;
    harness.controller().scrollDiff(.down);
    try std.testing.expectEqual(@as(usize, 2), harness.pages.changes.viewer.diff_scroll);
    try std.testing.expectEqual(zero_height_cursor, harness.pages.changes.viewer.diff_cursor);
}

test "reload search fallback resyncs match without interactive cursor placement" {
    var harness = TestHarness.init(.{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{
            .display_mode = .unified,
            .sidebar_hidden = true,
            .diff_cursor = .{ .hunk_header = 0 },
        },
    }, .{ .width = 140, .height = 15 });
    setDiffSearchQuery(&harness, "late old");

    var path_key = [_]u8{'a'};
    var sidebar_path = [_]u8{'a'};
    const invalid_coordinate: diff_view_model.BodyCoordinate = .{ .hunk_line = .{
        .hunk_index = 99,
        .line_index = 0,
    } };
    var anchor: diff_surface.ReloadAnchor = .{
        .path_key = path_key[0..],
        .sidebar_identity = .{ .file = sidebar_path[0..] },
        .selected_target_tag = .diff_file,
        .visible_sidebar_row = 0,
        .diff_cursor = harness.pages.changes.viewer.diff_cursor,
        .diff_cursor_offset = 0,
        .diff_scroll = 0,
        .diff_horizontal_scroll = 0,
        .sidebar_horizontal_scroll = 0,
        .search_coordinate = invalid_coordinate,
    };

    const cursor_before = harness.pages.changes.viewer.diff_cursor;
    harness.controller().restoreSearchFromReloadAnchor(&anchor);

    try std.testing.expectEqual(cursor_before, harness.pages.changes.viewer.diff_cursor);
    try std.testing.expectEqual(@as(usize, 0), harness.pages.changes.viewer.diff_scroll);
    const match = harness.pages.changes.search.match orelse return error.ExpectedSearchMatch;
    try std.testing.expect(!std.meta.eql(invalid_coordinate, match.coordinate));
    try std.testing.expect(harness.pages.changes.search.match_offset != null);
}

test "Changes mouse selection ignores the opposite side and resumes on its locked side" {
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
    const started = harness.pages.changes.selection_owner.activeDiff() orelse return error.ExpectedDiffSelection;
    try std.testing.expectEqual(diff_selection.Side.old, started.side);
    try std.testing.expectEqual(@as(usize, 0), started.focus.line_index);

    harness.controller().dragDiffMouse(.{
        .col = 72,
        .row = diff_render.body_start_row + 3,
    });
    const dragged = harness.pages.changes.selection_owner.activeDiff() orelse return error.ExpectedDiffSelection;
    try std.testing.expectEqual(diff_selection.Side.old, dragged.side);
    try std.testing.expectEqual(@as(usize, 0), dragged.focus.line_index);
    try std.testing.expect(!dragged.moved);

    harness.controller().dragDiffMouse(.{
        .col = 10,
        .row = diff_render.body_start_row + 3,
    });
    const resumed = harness.pages.changes.selection_owner.activeDiff() orelse return error.ExpectedDiffSelection;
    try std.testing.expectEqual(diff_selection.Side.old, resumed.side);
    try std.testing.expectEqual(@as(usize, 2), resumed.focus.line_index);
    try std.testing.expect(resumed.moved);
}

test "Changes mouse selection projects scrolled TAB wide combining and emoji cells atomically" {
    const text = "a\t界e\u{301}👩‍💻z";
    const scroll: usize = 2;
    const cases = [_]struct {
        viewport_cell: usize,
        leading: usize,
        trailing: usize,
    }{
        .{ .viewport_cell = 0, .leading = 1, .trailing = 2 },
        .{ .viewport_cell = 1, .leading = 1, .trailing = 2 },
        .{ .viewport_cell = 2, .leading = 2, .trailing = 5 },
        .{ .viewport_cell = 3, .leading = 2, .trailing = 5 },
        .{ .viewport_cell = 4, .leading = 5, .trailing = 8 },
        .{ .viewport_cell = 5, .leading = 8, .trailing = 19 },
        .{ .viewport_cell = 6, .leading = 8, .trailing = 19 },
        .{ .viewport_cell = 7, .leading = 19, .trailing = 20 },
    };

    for (cases) |case| {
        const point = pointForTextCell(3, 4, text, .character, scroll, case.viewport_cell) orelse return error.ExpectedSelectionPoint;
        try std.testing.expectEqual(@as(usize, 3), point.hunk_index);
        try std.testing.expectEqual(@as(usize, 4), point.line_index);
        try std.testing.expectEqual(case.leading, point.leading);
        try std.testing.expectEqual(case.trailing, point.trailing);
    }

    const trailing = pointForTextCell(3, 4, text, .character, scroll, 8) orelse return error.ExpectedTrailingBoundary;
    try std.testing.expectEqual(text.len, trailing.leading);
    try std.testing.expectEqual(text.len, trailing.trailing);

    const saturated = pointForTextCell(3, 4, text, .character, std.math.maxInt(usize), 1) orelse return error.ExpectedTrailingBoundary;
    try std.testing.expectEqual(text.len, saturated.leading);
    try std.testing.expectEqual(text.len, saturated.trailing);

    const invalid = [_]u8{0xff};
    try std.testing.expect(pointForTextCell(3, 4, &invalid, .character, 0, 0) == null);
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
    const characters = harness.pages.changes.selection_owner.activeDiff() orelse return error.ExpectedDiffSelection;
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
    const into_gutter = harness.pages.changes.selection_owner.activeDiff() orelse return error.ExpectedDiffSelection;
    try std.testing.expectEqual(diff_selection.Mode.character, into_gutter.mode);
    try std.testing.expectEqual(@as(usize, 0), into_gutter.focus.leading);
    try std.testing.expectEqual(@as(usize, 0), into_gutter.focus.trailing);

    harness.controller().clearDiffSelection();
    harness.controller().pressDiffMouse(.{ .col = text_start, .row = diff_render.body_start_row + 1 });
    harness.controller().dragDiffMouse(.{ .col = new_line_number_col, .row = diff_render.body_start_row + 1 });
    const first_token_to_gutter = harness.pages.changes.selection_owner.activeDiff() orelse return error.ExpectedDiffSelection;
    const first_token_copy = try diff_selection.copyText(std.testing.allocator, files[0], first_token_to_gutter);
    defer std.testing.allocator.free(first_token_copy);
    try std.testing.expectEqualStrings("A", first_token_copy);

    harness.controller().clearDiffSelection();
    harness.controller().pressDiffMouse(.{ .col = new_line_number_col, .row = diff_render.body_start_row + 1 });
    harness.controller().dragDiffMouse(.{ .col = text_start + 4, .row = diff_render.body_start_row + 2 });
    const lines_selected = harness.pages.changes.selection_owner.activeDiff() orelse return error.ExpectedDiffSelection;
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
            .selected_node = 1,
            .diff_cursor = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 0 } },
            .display_mode = .unified,
            .sidebar_hidden = true,
        },
    }, .{ .width = 100, .height = 12 });

    try std.testing.expect(harness.view().displayedChangesBody() == .inert_invalid_utf8);
    try std.testing.expect(!harness.view().bodyAllowsHunkInteraction());
    try std.testing.expect(harness.view().selectedHunkIndex() == null);
    try std.testing.expect(harness.view().displayedDiffFile() == null);
    try std.testing.expect(harness.view().unsupportedSearchMessage() != null);
    harness.pages.changes.viewer.diff_scroll = 99;
    harness.pages.changes.viewer.diff_horizontal_scroll = 99;
    harness.controller().clampDiffNavigation();
    try std.testing.expectEqual(diff_view_model.BodyCoordinate{ .metadata = 0 }, harness.pages.changes.viewer.diff_cursor);
    try std.testing.expectEqual(@as(usize, 0), harness.pages.changes.viewer.diff_scroll);
    try std.testing.expectEqual(@as(usize, 0), harness.pages.changes.viewer.diff_horizontal_scroll);
    const inert_snapshot = harness.view().displayNavigationSnapshot();
    for ([_]diff_surface.message.Msg{
        .document_first,
        .document_last,
        .half_page_up,
        .half_page_down,
        .page_diff_up,
        .page_diff_down,
    }) |msg| {
        try std.testing.expect(!try applySharedNavigation(&harness, msg));
        try std.testing.expectEqualDeep(inert_snapshot, harness.view().displayNavigationSnapshot());
    }
    harness.controller().moveDiffCursorPage(.down);
    harness.controller().scrollDiff(.down);
    harness.controller().scrollDiffHorizontal(.right);
    harness.controller().selectHunkDelta(1);
    harness.controller().toggleSelectedHunkFold();
    try std.testing.expectEqual(diff_view_model.BodyCoordinate{ .metadata = 0 }, harness.pages.changes.viewer.diff_cursor);
    try std.testing.expectEqual(@as(usize, 0), harness.pages.changes.viewer.diff_scroll);
    try std.testing.expectEqual(@as(usize, 0), harness.pages.changes.viewer.diff_horizontal_scroll);
    harness.controller().pressDiffMouse(.{ .col = 12, .row = diff_render.body_start_row + 1 });
    try std.testing.expect(harness.pages.changes.selection_owner == .none);

    harness.controller().selectFileAbsolute(0);
    try std.testing.expect(harness.view().displayedChangesBody() == .primary);
    try std.testing.expectEqualDeep(diff_surface.ResolvedTarget{
        .kind = .primary,
        .line_count = 0,
        .hunk_interaction = .available,
        .status_rows = 0,
        .search_unavailable = null,
        .search_unfold_policy = .unfold_displayed,
        .folded_hunks_source = .underlying_load,
    }, harness.view().resolvedTarget());
    try std.testing.expect(harness.view().bodyAllowsHunkInteraction());
    harness.controller().pressDiffMouse(.{ .col = 12, .row = diff_render.body_start_row + 1 });
    try std.testing.expect(harness.pages.changes.selection_owner.activeDiff() != null);
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
    _ = harness.pages.changes.activation.activate(0, .fresh, .fresh, .fresh);
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "M  a\x00");
    try harness.pages.changes.git_status.replace("/repo", &status_bundle);
    harness.pages.changes.changes_projection.installReady(.{
        .request = try changes_projection.testing.cloneRequest(
            allocator,
            harness.pages.changes.activation.currentIdentity().?,
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
    defer harness.pages.changes.deinit(allocator);

    try std.testing.expect(harness.view().displayedChangesBody() == .inert_invalid_utf8);
    try std.testing.expect(!harness.view().bodyAllowsHunkInteraction());
    try std.testing.expect(harness.view().activeCachedDiffProjection() == null);
    try std.testing.expect(harness.view().displayedDiffFile() == null);
    try std.testing.expect(harness.view().selectedHunkIndex() == null);
    harness.pages.changes.viewer.diff_scroll = 99;
    harness.pages.changes.viewer.diff_horizontal_scroll = 99;
    harness.controller().clampDiffNavigation();
    try std.testing.expectEqual(diff_view_model.BodyCoordinate{ .metadata = 0 }, harness.pages.changes.viewer.diff_cursor);
    try std.testing.expectEqual(@as(usize, 0), harness.pages.changes.viewer.diff_scroll);
    try std.testing.expectEqual(@as(usize, 0), harness.pages.changes.viewer.diff_horizontal_scroll);
    harness.controller().moveDiffCursorPage(.down);
    harness.controller().scrollDiff(.down);
    harness.controller().scrollDiffHorizontal(.right);
    try std.testing.expectEqual(@as(usize, 0), harness.pages.changes.viewer.diff_scroll);
    try std.testing.expectEqual(@as(usize, 0), harness.pages.changes.viewer.diff_horizontal_scroll);
    harness.controller().pressDiffMouse(.{ .col = 12, .row = diff_render.body_start_row + 1 });
    try std.testing.expect(harness.pages.changes.selection_owner == .none);
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
        _ = harness.pages.changes.activation.activate(0, .fresh, .fresh, .fresh);
        var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
        try harness.pages.changes.git_status.replace("/repo", &status_bundle);
        harness.pages.changes.changes_projection.installReady(.{
            .request = try changes_projection.testing.cloneRequest(
                allocator,
                harness.pages.changes.activation.currentIdentity().?,
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
        defer harness.pages.changes.deinit(allocator);

        try std.testing.expect(harness.view().displayedChangesBody() == .inert_invalid_utf8);
        try std.testing.expect(harness.view().activeCombinedProjection() == null);
        try std.testing.expect(harness.view().displayedDiffFile() == null);
        try std.testing.expect(harness.view().selectedHunkIndex() == null);
        try std.testing.expectEqual(HunkInteractionAvailability.inert_invalid_utf8, harness.view().hunkInteractionAvailability());
        harness.controller().clampDiffNavigation();
        harness.controller().moveDiffCursorPage(.down);
        harness.controller().scrollDiff(.down);
        harness.controller().scrollDiffHorizontal(.right);
        harness.controller().selectHunkDelta(1);
        harness.controller().toggleSelectedHunkFold();
        try std.testing.expectEqual(diff_view_model.BodyCoordinate{ .metadata = 0 }, harness.pages.changes.viewer.diff_cursor);
        try std.testing.expectEqual(@as(usize, 0), harness.pages.changes.viewer.diff_scroll);
        try std.testing.expectEqual(@as(usize, 0), harness.pages.changes.viewer.diff_horizontal_scroll);
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
    _ = cached_harness.pages.changes.activation.activate(0, .fresh, .fresh, .fresh);
    var cached_status = try git_status.StatusBundle.parseOwned(allocator, "M  a\x00");
    try cached_harness.pages.changes.git_status.replace("/repo", &cached_status);
    cached_harness.pages.changes.changes_projection.installReady(.{
        .request = try changes_projection.testing.cloneRequest(allocator, cached_harness.pages.changes.activation.currentIdentity().?, 1, "/repo", "a", .cached_diff, .unstaged, 0, 0),
        .value = .{ .cached_diff = try app_load.buildLoadedBundle(allocator, test_support.diff_cached_projection) },
    });
    defer cached_harness.pages.changes.deinit(allocator);
    const cached_raw = cached_harness.view().rawDiffPaneGeometry().?;
    const cached_content_width = contentWidth(cached_raw.width);
    const cached_text = cached_raw.col + (cached_raw.width - cached_content_width) + diff_render.cursor_gutter_width + diff_render.lineTextStart(true, .unified);
    cached_harness.controller().pressDiffMouse(.{ .col = cached_text + 1, .row = diff_render.body_start_row + 1 });
    const cached_selection = cached_harness.pages.changes.selection_owner.activeDiff() orelse return error.ExpectedDiffSelection;
    try std.testing.expectEqual(diff_selection.Mode.character, cached_selection.mode);
    try std.testing.expect(cached_selection.identity == .projection_file);
    try std.testing.expect(cached_selection.identity.projection_file.kind == .cached);

    // Mixed cached/unstaged projection.
    var combined_harness = TestHarness.init(.{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .diff_file = 0 }, .display_mode = .unified, .sidebar_hidden = true },
    }, .{ .width = 100, .height = 12 });
    combined_harness.repo_root = "/repo";
    _ = combined_harness.pages.changes.activation.activate(0, .fresh, .fresh, .fresh);
    var combined_status = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try combined_harness.pages.changes.git_status.replace("/repo", &combined_status);
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
    combined_harness.pages.changes.changes_projection.installReady(.{
        .request = try changes_projection.testing.cloneRequest(allocator, combined_harness.pages.changes.activation.currentIdentity().?, 1, "/repo", "a", .combined_hunks, .unstaged, 0, 0),
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
    defer combined_harness.pages.changes.deinit(allocator);
    const combined_raw = combined_harness.view().rawDiffPaneGeometry().?;
    const combined_content_width = contentWidth(combined_raw.width);
    const combined_text = combined_raw.col + (combined_raw.width - combined_content_width) + diff_render.cursor_gutter_width + diff_render.lineTextStart(true, .unified);
    combined_harness.controller().pressDiffMouse(.{ .col = combined_text + 1, .row = diff_render.body_start_row + 1 });
    const combined_selection = combined_harness.pages.changes.selection_owner.activeDiff() orelse return error.ExpectedDiffSelection;
    try std.testing.expect(combined_selection.identity == .projection_file);
    try std.testing.expect(combined_selection.identity.projection_file.kind == .combined);

    // Generated untracked preview uses its own non-hunk identity.
    var generated_harness = TestHarness.init(.{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .status_only = 0 }, .display_mode = .unified, .sidebar_hidden = true },
    }, .{ .width = 100, .height = 12 });
    generated_harness.repo_root = "/repo";
    _ = generated_harness.pages.changes.activation.activate(0, .fresh, .fresh, .fresh);
    var generated_status = try git_status.StatusBundle.parseOwned(allocator, "?? a\x00");
    try generated_harness.pages.changes.git_status.replace("/repo", &generated_status);
    generated_harness.pages.changes.changes_projection.installReady(.{
        .request = try changes_projection.testing.cloneRequest(allocator, generated_harness.pages.changes.activation.currentIdentity().?, 1, "/repo", "a", .generated_added_file, .unstaged, 0, 0),
        .value = .{ .generated_added_file = try changes_projection.generatedFileFromContent(allocator, "a", "ABCDEFG\n") },
    });
    defer generated_harness.pages.changes.deinit(allocator);
    const generated_raw = generated_harness.view().rawDiffPaneGeometry().?;
    const generated_content_width = contentWidth(generated_raw.width);
    const generated_text = generated_raw.col + (generated_raw.width - generated_content_width) + diff_render.cursor_gutter_width + diff_render.lineTextStart(true, .unified);
    generated_harness.controller().pressDiffMouse(.{ .col = generated_text + 3, .row = diff_render.body_start_row });
    const generated_selection = generated_harness.pages.changes.selection_owner.activeDiff() orelse return error.ExpectedDiffSelection;
    try std.testing.expect(generated_selection.identity == .generated_file);
    try std.testing.expectEqual(diff_selection.Mode.character, generated_selection.mode);
    try std.testing.expectEqual(@as(usize, 3), generated_selection.anchor.leading);

    generated_harness.controller().clearDiffSelection();
    generated_harness.pages.changes.viewer.display_mode = .side_by_side;
    generated_harness.pages.changes.viewer.focus = .diff;
    generated_harness.pages.changes.viewer.diff_cursor = .{ .metadata = 0 };
    var generated_adapter = generated_harness.controller().updateAdapter();
    var generated_keyboard = try generated_adapter.shared().apply(null, .begin_keyboard_line_selection);
    generated_keyboard.deinit(null);
    const generated_keyboard_selection = generated_harness.pages.changes.selection_owner.activeDiff() orelse
        return error.ExpectedDiffSelection;
    try std.testing.expect(generated_keyboard_selection.identity == .generated_file);
    try std.testing.expectEqual(diff_selection.Side.new, generated_keyboard_selection.side);
    try std.testing.expectEqual(diff_selection.Origin.keyboard_line, generated_keyboard_selection.origin);
    try std.testing.expectEqual(@as(usize, 0), generated_keyboard_selection.focus.line_index);
}

test "Changes navigation snapshot and reload restore share the page owner" {
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

    var anchor: changes_page.ReloadAnchor = .{
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

    harness.pages.changes.viewer.diff_cursor = .{ .metadata = 0 };
    harness.pages.changes.viewer.diff_scroll = 0;
    harness.pages.changes.viewer.diff_horizontal_scroll = 0;
    harness.pages.changes.viewer.sidebar_horizontal_scroll = 0;
    harness.pages.changes.search.match = null;
    harness.pages.changes.search.match_offset = null;

    const loaded = harness.controller().activeLoadedDiff() orelse return error.ExpectedLoadedDiff;
    try std.testing.expect(harness.controller().restoreReloadAnchor(loaded, &anchor));
    try std.testing.expectEqual(snapshot.diff_cursor, harness.pages.changes.viewer.diff_cursor);
    try std.testing.expect(harness.pages.changes.viewer.diff_scroll >= snapshot.diff_scroll);
    try std.testing.expect(harness.view().visibleDiffCursorOffset() != null);
    try std.testing.expect(harness.pages.changes.viewer.diff_horizontal_scroll <= snapshot.diff_horizontal_scroll);
    try std.testing.expect(harness.pages.changes.viewer.sidebar_horizontal_scroll <= snapshot.sidebar_horizontal_scroll);
}

test "sidebar visibility toggle uses full diff width and keeps selection" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{
                .focus = .sidebar,
                .selected_node = 1,
                .display_mode = .side_by_side,
            },
        } },
        .terminal_size = .{ .width = 80, .height = 8 },
    };

    try std.testing.expectEqual(diff_render.DisplayMode.unified, app.changesNavigationView().effectiveDisplayMode());

    app.changesNavigation().toggleSidebarVisibility();

    try std.testing.expect(app.pages.changes.viewer.sidebar_hidden);
    try std.testing.expectEqual(changes_page.Focus.diff, app.pages.changes.viewer.focus);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, app.pages.changes.viewer.selected_target.?);
    try std.testing.expectEqual(@as(usize, 1), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(diff_render.DisplayMode.side_by_side, app.changesNavigationView().effectiveDisplayMode());

    app.changesNavigation().toggleSidebarVisibility();

    try std.testing.expect(!app.pages.changes.viewer.sidebar_hidden);
    try std.testing.expectEqual(changes_page.Focus.diff, app.pages.changes.viewer.focus);
    try std.testing.expectEqual(diff_render.DisplayMode.unified, app.changesNavigationView().effectiveDisplayMode());
}

test "sidebar width adjustment clamps and affects effective mode" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{ .display_mode = .side_by_side },
        } },
        .terminal_size = .{ .width = 104, .height = 8 },
    };

    try std.testing.expectEqual(@as(?u16, null), app.pages.changes.viewer.sidebar_width);
    try std.testing.expectEqual(diff_render.DisplayMode.unified, app.changesNavigationView().effectiveDisplayMode());

    app.changesNavigation().adjustSidebarWidth(.shrink);
    try std.testing.expectEqual(@as(?u16, 30), app.pages.changes.viewer.sidebar_width);
    try std.testing.expectEqual(diff_render.DisplayMode.unified, app.changesNavigationView().effectiveDisplayMode());

    app.changesNavigation().adjustSidebarWidth(.shrink);
    try std.testing.expectEqual(@as(?u16, 26), app.pages.changes.viewer.sidebar_width);
    try std.testing.expectEqual(diff_render.DisplayMode.side_by_side, app.changesNavigationView().effectiveDisplayMode());

    app.changesNavigation().adjustSidebarWidth(.grow);
    try std.testing.expectEqual(@as(?u16, 30), app.pages.changes.viewer.sidebar_width);
}

test "sidebar width remains stored while sidebar is hidden" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{ .display_mode = .side_by_side },
        } },
        .terminal_size = .{ .width = 104, .height = 8 },
    };

    app.changesNavigation().adjustSidebarWidth(.shrink);
    app.changesNavigation().toggleSidebarVisibility();
    app.changesNavigation().adjustSidebarWidth(.shrink);

    try std.testing.expect(app.pages.changes.viewer.sidebar_hidden);
    try std.testing.expectEqual(@as(?u16, 26), app.pages.changes.viewer.sidebar_width);
    try std.testing.expectEqual(diff_render.DisplayMode.side_by_side, app.changesNavigationView().effectiveDisplayMode());

    app.changesNavigation().toggleSidebarVisibility();

    try std.testing.expect(!app.pages.changes.viewer.sidebar_hidden);
    try std.testing.expectEqual(@as(?u16, 26), app.pages.changes.viewer.sidebar_width);
    try std.testing.expectEqual(diff_render.DisplayMode.side_by_side, app.changesNavigationView().effectiveDisplayMode());
}

test "horizontal scroll uses diff focus arrows and clamps to visible text" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffWide()),
            .viewer = .{ .focus = .diff, .display_mode = .unified },
        } },
        .terminal_size = .{ .width = 80, .height = 12 },
    };

    app.changesNavigation().scrollDiffHorizontal(.right);
    try std.testing.expectEqual(@as(usize, 8), app.pages.changes.viewer.diff_horizontal_scroll);

    for (0..20) |_| app.changesNavigation().scrollDiffHorizontal(.right);
    try std.testing.expect(app.pages.changes.viewer.diff_horizontal_scroll > 0);
    try std.testing.expect(app.pages.changes.viewer.diff_horizontal_scroll <= app.changesNavigationView().visibleBodyTextMaxHorizontalScroll());

    app.changesNavigation().scrollDiffHorizontal(.left);
    try std.testing.expect(app.pages.changes.viewer.diff_horizontal_scroll <= app.changesNavigationView().visibleBodyTextMaxHorizontalScroll());
}

test "displayed body horizontal scroll preserves primary behavior without a cached index" {
    var harness = TestHarness.init(.{
        .load = test_support.loadState(test_support.loadedDiffWide()),
        .viewer = .{
            .focus = .diff,
            .display_mode = .unified,
        },
    }, .{ .width = 80, .height = 12 });

    try std.testing.expect(harness.view().displayedChangesBody() == .primary);
    try expectResolverRenderOmits(&harness, "hunks");
    try std.testing.expect(harness.view().displayedDiffLineIndex(.unified) == null);
    const with_line_numbers = harness.view().visibleBodyTextMaxHorizontalScroll();
    try std.testing.expectEqual(@as(usize, 35), with_line_numbers);

    harness.controller().scrollDiffHorizontal(.right);
    try std.testing.expectEqual(@as(usize, 8), harness.pages.changes.viewer.diff_horizontal_scroll);
    harness.pages.changes.viewer.view_options.line_numbers = false;
    try std.testing.expectEqual(@as(usize, 25), harness.view().visibleBodyTextMaxHorizontalScroll());
}

test "displayed body horizontal scroll uses cached combined retained and generated authority" {
    const allocator = std.testing.allocator;

    var cached = TestHarness.init(.{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{
            .selected_target = .{ .status_only = 0 },
            .focus = .diff,
            .sidebar_hidden = true,
        },
    }, .{ .width = 140, .height = 16 });
    try prepareStatusOnlyHorizontalScrollHarness(&cached, allocator, "M  a\x00");
    var cached_bundle = try app_load.buildLoadedBundle(
        allocator,
        displayed_body_horizontal_scroll_cached_patch,
    );
    try std.testing.expect(cached_bundle.loaded.collapsed_hunks.len > 0);
    cached_bundle.loaded.collapsed_hunks[0] = true;
    cached.pages.changes.changes_projection.installReady(.{
        .request = try changes_projection.testing.cloneRequest(
            allocator,
            cached.pages.changes.activation.currentIdentity().?,
            1,
            "/repo",
            "a",
            .cached_diff,
            .unstaged,
            cached.pages.changes.source_session_revision,
            cached.pages.changes.status_snapshot_revision,
        ),
        .value = .{ .cached_diff = cached_bundle },
    });
    defer cached.pages.changes.deinit(allocator);
    try std.testing.expect(cached.view().displayedChangesBody() == .cached);
    const cached_target = cached.view().resolvedTarget();
    try std.testing.expectEqual(diff_surface.ReducedBodyKind.projected, cached_target.kind);
    try std.testing.expect(cached_target.line_count > 0);
    try std.testing.expectEqual(HunkInteractionAvailability.available, cached_target.hunk_interaction);
    try std.testing.expectEqual(@as(usize, 1), cached_target.status_rows);
    try std.testing.expectEqual(@as(?diff_surface.SearchUnavailableReason, null), cached_target.search_unavailable);
    try std.testing.expectEqual(diff_surface.SearchUnfoldPolicy.suppressed, cached_target.search_unfold_policy);
    try std.testing.expectEqual(diff_surface.FoldedHunksSource.empty, cached_target.folded_hunks_source);
    try expectResolverRenderContains(&cached, "hunks");
    try expectResolverRenderContains(&cached, "wide-0123456789");
    try expectDisplayedBodyHorizontalScrollGeometry(&cached);

    var combined = TestHarness.init(.{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{
            .selected_target = .{ .diff_file = 0 },
            .focus = .diff,
            .sidebar_hidden = true,
        },
    }, .{ .width = 140, .height = 16 });
    try prepareStatusOnlyHorizontalScrollHarness(&combined, allocator, "MM a\x00");
    try installCombinedHorizontalScrollProjection(&combined, allocator);
    defer combined.pages.changes.deinit(allocator);
    try std.testing.expect(combined.view().displayedChangesBody() == .combined);
    const combined_target = combined.view().resolvedTarget();
    try std.testing.expectEqual(diff_surface.ReducedBodyKind.projected, combined_target.kind);
    try std.testing.expectEqual(@as(usize, 0), combined_target.line_count);
    try std.testing.expectEqual(HunkInteractionAvailability.available, combined_target.hunk_interaction);
    try std.testing.expectEqual(@as(?diff_surface.SearchUnavailableReason, .mixed_stage_view), combined_target.search_unavailable);
    try std.testing.expectEqual(diff_surface.SearchUnfoldPolicy.suppressed, combined_target.search_unfold_policy);
    try std.testing.expectEqual(diff_surface.FoldedHunksSource.empty, combined_target.folded_hunks_source);
    try expectResolverRenderContains(&combined, "hunks");
    try expectDisplayedBodyHorizontalScrollGeometry(&combined);

    var retained = TestHarness.init(.{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{
            .selected_target = .{ .diff_file = 0 },
            .focus = .diff,
            .sidebar_hidden = true,
        },
    }, .{ .width = 140, .height = 16 });
    try prepareStatusOnlyHorizontalScrollHarness(&retained, allocator, "MM a\x00");
    try installCombinedHorizontalScrollProjection(&retained, allocator);
    var staged_status = try git_status.StatusBundle.parseOwned(allocator, "M  a\x00");
    try retained.pages.changes.git_status.replace("/repo", &staged_status);
    try retainCombinedHorizontalScrollProjection(&retained, allocator);
    defer retained.pages.changes.deinit(allocator);
    try std.testing.expect(retained.view().displayedChangesBody() == .retained_staged_only);
    const retained_target = retained.view().resolvedTarget();
    try std.testing.expectEqual(diff_surface.ReducedBodyKind.projected, retained_target.kind);
    try std.testing.expectEqual(@as(usize, 0), retained_target.line_count);
    try std.testing.expectEqual(HunkInteractionAvailability.available, retained_target.hunk_interaction);
    try std.testing.expectEqual(@as(?diff_surface.SearchUnavailableReason, null), retained_target.search_unavailable);
    try std.testing.expectEqual(diff_surface.SearchUnfoldPolicy.unfold_underlying, retained_target.search_unfold_policy);
    try std.testing.expectEqual(diff_surface.FoldedHunksSource.empty, retained_target.folded_hunks_source);
    try expectResolverRenderContains(&retained, "hunks");
    try expectDisplayedBodyHorizontalScrollGeometry(&retained);

    var generated = TestHarness.init(.{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{
            .selected_target = .{ .status_only = 0 },
            .focus = .diff,
            .sidebar_hidden = true,
        },
    }, .{ .width = 140, .height = 16 });
    try prepareStatusOnlyHorizontalScrollHarness(&generated, allocator, "?? a\x00");
    generated.pages.changes.changes_projection.installReady(.{
        .request = try changes_projection.testing.cloneRequest(
            allocator,
            generated.pages.changes.activation.currentIdentity().?,
            1,
            "/repo",
            "a",
            .generated_added_file,
            .unstaged,
            generated.pages.changes.source_session_revision,
            generated.pages.changes.status_snapshot_revision,
        ),
        .value = .{ .generated_added_file = try changes_projection.generatedFileFromContent(
            allocator,
            "a",
            displayed_body_horizontal_scroll_wide_text ++ "\n",
        ) },
    });
    defer generated.pages.changes.deinit(allocator);
    try std.testing.expect(generated.view().displayedChangesBody() == .generated);
    const generated_target = generated.view().resolvedTarget();
    try std.testing.expectEqual(diff_surface.ReducedBodyKind.projected, generated_target.kind);
    try std.testing.expect(generated_target.line_count > 0);
    try std.testing.expectEqual(HunkInteractionAvailability.unavailable, generated_target.hunk_interaction);
    try std.testing.expectEqual(@as(?diff_surface.SearchUnavailableReason, .generated_preview), generated_target.search_unavailable);
    try std.testing.expectEqual(diff_surface.SearchUnfoldPolicy.suppressed, generated_target.search_unfold_policy);
    try std.testing.expectEqual(diff_surface.FoldedHunksSource.underlying_load, generated_target.folded_hunks_source);
    try expectResolverRenderContains(&generated, "generated");
    try expectDisplayedBodyHorizontalScrollGeometry(&generated);
}

test "displayed body horizontal scroll follows generated visible rows" {
    const allocator = std.testing.allocator;
    const content =
        "short\n" ++
        "short\n" ++
        "short\n" ++
        "short\n" ++
        "short\n" ++
        "short\n" ++
        "short\n" ++
        "short\n" ++
        "short\n" ++
        "short\n" ++
        "short\n" ++
        "short\n" ++
        displayed_body_horizontal_scroll_wide_text ++ "\n";
    var harness = TestHarness.init(.{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{
            .selected_target = .{ .status_only = 0 },
            .focus = .diff,
            .display_mode = .unified,
            .sidebar_hidden = true,
        },
    }, .{ .width = 80, .height = 12 });
    try prepareStatusOnlyHorizontalScrollHarness(&harness, allocator, "?? a\x00");
    harness.pages.changes.changes_projection.installReady(.{
        .request = try changes_projection.testing.cloneRequest(
            allocator,
            harness.pages.changes.activation.currentIdentity().?,
            1,
            "/repo",
            "a",
            .generated_added_file,
            .unstaged,
            harness.pages.changes.source_session_revision,
            harness.pages.changes.status_snapshot_revision,
        ),
        .value = .{ .generated_added_file = try changes_projection.generatedFileFromContent(
            allocator,
            "a",
            content,
        ) },
    });
    defer harness.pages.changes.deinit(allocator);

    try std.testing.expect(harness.view().diffVisibleRows() > 0);
    try std.testing.expect(harness.view().diffVisibleRows() < 12);
    try std.testing.expectEqual(@as(usize, 0), harness.view().visibleBodyTextMaxHorizontalScroll());

    harness.pages.changes.viewer.diff_scroll = 12;
    const visible_max = harness.view().visibleBodyTextMaxHorizontalScroll();
    try std.testing.expect(visible_max > 0);
    harness.pages.changes.viewer.diff_horizontal_scroll = std.math.maxInt(usize);
    harness.controller().clampDiffHorizontalScrollToVisibleRows();
    try std.testing.expectEqual(visible_max, harness.pages.changes.viewer.diff_horizontal_scroll);
}

test "displayed body horizontal scroll keeps non-scrollable terminals at zero" {
    const allocator = std.testing.allocator;

    var none = TestHarness.init(.{
        .load = test_support.loadState(test_support.loadedDiffWide()),
        .viewer = .{ .selected_target = .{ .status_only = 0 }, .sidebar_hidden = true },
    }, .{ .width = 80, .height = 12 });
    try prepareStatusOnlyHorizontalScrollHarness(&none, allocator, "M  a\x00");
    defer none.pages.changes.deinit(allocator);
    try std.testing.expect(none.view().displayedChangesBody() == .none);
    try std.testing.expectEqualDeep(diff_surface.ResolvedTarget{
        .kind = .none,
        .line_count = 0,
        .hunk_interaction = .unavailable,
        .status_rows = 1,
        .search_unavailable = null,
        .search_unfold_policy = .suppressed,
        .folded_hunks_source = .underlying_load,
    }, none.view().resolvedTarget());
    try expectResolverRenderOmits(&none, "status:");
    none.pages.changes.viewer.diff_horizontal_scroll = 99;
    none.controller().clampDiffHorizontalScrollToVisibleRows();
    try std.testing.expectEqual(@as(usize, 0), none.pages.changes.viewer.diff_horizontal_scroll);

    var pending = TestHarness.init(.{
        .load = test_support.loadState(test_support.loadedDiffWide()),
        .viewer = .{ .selected_target = .{ .status_only = 0 }, .sidebar_hidden = true },
    }, .{ .width = 80, .height = 12 });
    try prepareStatusOnlyHorizontalScrollHarness(&pending, allocator, "M  a\x00");
    pending.pages.changes.changes_projection.pending = try changes_projection.testing.cloneRequest(
        allocator,
        pending.pages.changes.activation.currentIdentity().?,
        1,
        "/repo",
        "a",
        .cached_diff,
        .unstaged,
        pending.pages.changes.source_session_revision,
        pending.pages.changes.status_snapshot_revision,
    );
    defer pending.pages.changes.deinit(allocator);
    try std.testing.expect(pending.view().displayedChangesBody() == .pending);
    try std.testing.expectEqualDeep(diff_surface.ResolvedTarget{
        .kind = .projected,
        .line_count = 0,
        .hunk_interaction = .unavailable,
        .status_rows = 1,
        .search_unavailable = null,
        .search_unfold_policy = .suppressed,
        .folded_hunks_source = .underlying_load,
    }, pending.view().resolvedTarget());
    try expectResolverRenderContains(&pending, "Loading changes projection...");
    try std.testing.expectEqual(@as(usize, 0), pending.view().visibleBodyTextMaxHorizontalScroll());

    var status = TestHarness.init(.{
        .load = test_support.loadState(test_support.loadedDiffWide()),
        .viewer = .{ .selected_target = .{ .status_only = 0 }, .sidebar_hidden = true },
    }, .{ .width = 80, .height = 12 });
    try prepareStatusOnlyHorizontalScrollHarness(&status, allocator, "M  a\x00");
    status.pages.changes.changes_projection.installReady(.{
        .request = try changes_projection.testing.cloneRequest(
            allocator,
            status.pages.changes.activation.currentIdentity().?,
            1,
            "/repo",
            "a",
            .cached_diff,
            .unstaged,
            status.pages.changes.source_session_revision,
            status.pages.changes.status_snapshot_revision,
        ),
        .value = .{ .status_body = try changes_projection.statusBodyAlloc(
            allocator,
            "a",
            "No staged diff.",
            .{},
        ) },
    });
    defer status.pages.changes.deinit(allocator);
    try std.testing.expect(status.view().displayedChangesBody() == .status);
    try std.testing.expectEqual(@as(usize, 1), status.view().displayedDiffLineCount());
    try std.testing.expectEqualDeep(diff_surface.ResolvedTarget{
        .kind = .projected,
        .line_count = 1,
        .hunk_interaction = .unavailable,
        .status_rows = 1,
        .search_unavailable = null,
        .search_unfold_policy = .suppressed,
        .folded_hunks_source = .underlying_load,
    }, status.view().resolvedTarget());
    try expectResolverRenderContains(&status, "No staged diff.");
    try std.testing.expectEqual(@as(usize, 0), status.view().visibleBodyTextMaxHorizontalScroll());
    const status_cursor = status.pages.changes.viewer.diff_cursor;
    status.controller().scrollDiff(.down);
    try std.testing.expectEqual(@as(usize, 0), status.pages.changes.viewer.diff_scroll);
    try std.testing.expectEqual(status_cursor, status.pages.changes.viewer.diff_cursor);

    const invalid_patch =
        "diff --git a/a b/a\n" ++
        "--- a/a\n" ++
        "+++ b/a\n" ++
        "@@ -1 +1 @@\n" ++
        "-old\n" ++
        "+bad\xff\n";
    var inert = TestHarness.init(.{
        .load = test_support.loadState(test_support.loadedDiffWide()),
        .viewer = .{ .selected_target = .{ .status_only = 0 }, .sidebar_hidden = true },
    }, .{ .width = 80, .height = 12 });
    try prepareStatusOnlyHorizontalScrollHarness(&inert, allocator, "M  a\x00");
    inert.pages.changes.changes_projection.installReady(.{
        .request = try changes_projection.testing.cloneRequest(
            allocator,
            inert.pages.changes.activation.currentIdentity().?,
            1,
            "/repo",
            "a",
            .cached_diff,
            .unstaged,
            inert.pages.changes.source_session_revision,
            inert.pages.changes.status_snapshot_revision,
        ),
        .value = .{ .cached_diff = try app_load.buildLoadedBundle(allocator, invalid_patch) },
    });
    defer inert.pages.changes.deinit(allocator);
    try std.testing.expect(inert.view().displayedChangesBody() == .inert_invalid_utf8);
    try std.testing.expectEqualDeep(diff_surface.ResolvedTarget{
        .kind = .inert,
        .line_count = 1,
        .hunk_interaction = .inert_invalid_utf8,
        .status_rows = 1,
        .search_unavailable = .invalid_utf8,
        .search_unfold_policy = .suppressed,
        .folded_hunks_source = .underlying_load,
    }, inert.view().resolvedTarget());
    try expectResolverRenderContains(&inert, "Text preview unavailable");
    try std.testing.expectEqual(@as(usize, 0), inert.view().visibleBodyTextMaxHorizontalScroll());
}

test "none body preserves underlying folded hunks through resolver seam" {
    const allocator = std.testing.allocator;
    var collapsed = [_]bool{ true, false };
    var loaded = test_support.loadedDiffOne();
    loaded.collapsed_hunks = &collapsed;
    var harness = TestHarness.init(.{
        .load = test_support.loadState(loaded),
        .viewer = .{ .selected_target = .{ .diff_file = 0 } },
    }, .{ .width = 80, .height = 12 });
    harness.repo_root = "/repo";
    _ = harness.pages.changes.activation.activate(0, .fresh, .fresh, .fresh);
    harness.pages.changes.changes_projection.installReady(.{
        .request = try changes_projection.testing.cloneRequest(
            allocator,
            harness.pages.changes.activation.currentIdentity().?,
            1,
            "/repo",
            "a",
            .cached_diff,
            .unstaged,
            harness.pages.changes.source_session_revision,
            harness.pages.changes.status_snapshot_revision,
        ),
        .value = .{ .cached_diff = try app_load.buildLoadedBundle(allocator, "") },
    });
    defer harness.pages.changes.deinit(allocator);

    try std.testing.expect(harness.view().displayedChangesBody() == .none);
    try std.testing.expectEqual(diff_surface.FoldedHunksSource.underlying_load, harness.view().resolvedTarget().folded_hunks_source);
    try std.testing.expectEqualSlices(bool, &collapsed, harness.view().selectedFoldedHunks());
    const snapshot = harness.view().displayNavigationSnapshot();
    for ([_]diff_surface.message.Msg{
        .document_first,
        .document_last,
        .half_page_up,
        .half_page_down,
        .page_diff_up,
        .page_diff_down,
    }) |msg| {
        try std.testing.expect(!try applySharedNavigation(&harness, msg));
        try std.testing.expectEqualDeep(snapshot, harness.view().displayNavigationSnapshot());
    }
}

test "layout changes reset horizontal scroll only when diff pane width changes" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffWide()),
            .viewer = .{
                .display_mode = .side_by_side,
                .diff_horizontal_scroll = 16,
            },
        } },
        .terminal_size = .{ .width = 100, .height = 8 },
    };

    app.changesNavigation().toggleSidebarVisibility();
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.viewer.diff_horizontal_scroll);

    app.pages.changes.viewer.diff_horizontal_scroll = 16;
    app.changesNavigation().adjustSidebarWidth(.shrink);
    try std.testing.expectEqual(@as(usize, 16), app.pages.changes.viewer.diff_horizontal_scroll);

    app.changesNavigation().toggleSidebarVisibility();
    app.pages.changes.viewer.diff_horizontal_scroll = 16;
    app.changesNavigation().adjustSidebarWidth(.shrink);
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.viewer.diff_horizontal_scroll);
}

test "search resync without pane width change keeps horizontal scroll" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffWide()),
            .viewer = .{
                .display_mode = .side_by_side,
                .sidebar_hidden = true,
            },
        } },
        .terminal_size = .{ .width = 100, .height = 8 },
    };

    setDiffSearchQuery(&app, "wide");
    app.changesNavigation().submitSearch();
    app.pages.changes.viewer.diff_horizontal_scroll = 16;

    app.changesNavigation().adjustSidebarWidth(.shrink);

    try std.testing.expectEqual(@as(usize, 16), app.pages.changes.viewer.diff_horizontal_scroll);
}

test "diff wheel scroll brings an invisible cursor into the moved viewport" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{
                .display_mode = .unified,
                .sidebar_hidden = true,
                .diff_scroll = 2,
                .diff_cursor = .{ .hunk_header = 0 },
            },
        } },
        .terminal_size = .{ .width = 140, .height = 15 },
    };

    try std.testing.expect(app.visibleDiffCursorOffset() == null);

    app.changesNavigation().scrollDiff(.down);

    try std.testing.expect(app.visibleDiffCursorOffset() != null);
}

test "diff wheel comfort keeps band cursor screen position stable" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{
                .display_mode = .unified,
                .sidebar_hidden = true,
                .diff_scroll = 1,
            },
        } },
        .terminal_size = .{ .width = 140, .height = 15 },
    };
    const old_scroll = app.pages.changes.viewer.diff_scroll;
    const visible_rows = app.changesNavigationView().diffVisibleRows();
    const margin = @min(@as(usize, 8), visible_rows / 3);
    const old_offset = old_scroll + margin;
    app.pages.changes.viewer.diff_cursor = app.changesNavigationView().selectedCoordinateAtOffset(old_offset) orelse return error.ExpectedCoordinate;

    app.changesNavigation().scrollDiff(.down);

    const new_offset = app.changesNavigationView().selectedDiffCursorOffset() orelse return error.ExpectedCursorOffset;
    try std.testing.expectEqual(old_scroll + 1, app.pages.changes.viewer.diff_scroll);
    try std.testing.expectEqual(old_offset - old_scroll, new_offset - app.pages.changes.viewer.diff_scroll);
}

test "diff wheel comfort recenters edge cursor only after viewport movement" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{
                .display_mode = .unified,
                .sidebar_hidden = true,
            },
        } },
        .terminal_size = .{ .width = 140, .height = 15 },
    };
    const line_count = app.changesNavigationView().selectedFileLineIndex(app.changesNavigationView().effectiveDisplayMode()).lineCount();
    const visible_rows = app.changesNavigationView().diffVisibleRows();

    app.pages.changes.viewer.diff_scroll = 0;
    app.pages.changes.viewer.diff_cursor = app.changesNavigationView().selectedCoordinateAtOffset(line_count - 1) orelse return error.ExpectedCoordinate;
    app.changesNavigation().scrollDiff(.up);
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.viewer.diff_scroll);
    try std.testing.expectEqual(line_count - 2, app.changesNavigationView().selectedDiffCursorOffset().?);

    app.changesNavigation().scrollDiff(.down);
    try std.testing.expectEqual(@as(usize, 1), app.pages.changes.viewer.diff_scroll);
    try std.testing.expectEqual(
        @min(app.pages.changes.viewer.diff_scroll + visible_rows / 2, line_count - 1),
        app.changesNavigationView().selectedDiffCursorOffset().?,
    );

    app.pages.changes.viewer.diff_scroll = line_count - visible_rows;
    app.pages.changes.viewer.diff_cursor = app.changesNavigationView().selectedCoordinateAtOffset(0) orelse return error.ExpectedCoordinate;
    app.changesNavigation().scrollDiff(.up);
    try std.testing.expectEqual(line_count - visible_rows - 1, app.pages.changes.viewer.diff_scroll);
    try std.testing.expectEqual(
        app.pages.changes.viewer.diff_scroll + visible_rows / 2,
        app.changesNavigationView().selectedDiffCursorOffset().?,
    );
}

test "diff wheel steps to both content edges in long and short viewports" {
    for ([_]diff_render.DisplayMode{ .unified, .side_by_side }) |mode| {
        for ([_]u16{ 10, 40 }) |height| {
            var app = TestHarness.init(.{
                .load = test_support.loadState(test_support.loadedDiffOne()),
                .viewer = .{ .display_mode = mode, .sidebar_hidden = true },
            }, .{ .width = 140, .height = height });
            const view = app.changesNavigationView();
            const rows = view.selectedFileLineIndex(view.effectiveDisplayMode()).lineCount();
            const max_scroll = rows -| view.diffVisibleRows();
            for ([_]VerticalDirection{ .up, .down }) |direction| {
                var expected = rows / 2;
                app.pages.changes.viewer.diff_cursor = view.selectedCoordinateAtOffset(expected).?;
                const scroll = if (direction == .up) 0 else max_scroll;
                app.pages.changes.viewer.diff_scroll = scroll;
                for (0..rows + 2) |_| {
                    expected = if (direction == .up) expected -| 1 else @min(expected + 1, rows - 1);
                    app.controller().scrollDiff(direction);
                    try std.testing.expectEqual(expected, view.selectedDiffCursorOffset().?);
                    try std.testing.expectEqual(scroll, app.pages.changes.viewer.diff_scroll);
                }
            }
        }
    }
}

test "diff row movement continues from wheel-synced visible cursor" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{
                .display_mode = .unified,
                .sidebar_hidden = true,
            },
        } },
        .terminal_size = .{ .width = 140, .height = 15 },
    };
    const line_count = app.changesNavigationView().selectedFileLineIndex(app.changesNavigationView().effectiveDisplayMode()).lineCount();
    app.pages.changes.viewer.diff_scroll = 0;
    app.pages.changes.viewer.diff_cursor = app.changesNavigationView().selectedCoordinateAtOffset(line_count - 1) orelse return error.ExpectedCoordinate;

    app.changesNavigation().scrollDiff(.down);
    const synced_offset = app.changesNavigationView().selectedDiffCursorOffset() orelse return error.ExpectedCursorOffset;
    app.changesNavigation().moveDiffCursorRows(.down);

    try std.testing.expectEqual(synced_offset + 1, app.changesNavigationView().selectedDiffCursorOffset().?);
}

test "diff header mouse press starts header path owner only on path target" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{
                .display_mode = .side_by_side,
                .sidebar_hidden = true,
            },
        } },
        .terminal_size = .{ .width = 140, .height = 10 },
    };

    app.changesNavigation().pressDiffMouse(.{ .col = 1, .row = 0 });
    const header = app.pages.changes.selection_owner.activeHeader() orelse return error.ExpectedHeaderSelection;
    try std.testing.expectEqual(diff_selection.HeaderKind.loaded_file, header.identity.kind);
    try std.testing.expectEqualStrings("a", header.identity.path_key);

    app.changesNavigation().dragDiffMouse(.{ .col = 4, .row = diff_render.body_start_row + 1 });
    try std.testing.expect(app.pages.changes.selection_owner.activeHeader() != null);
    try std.testing.expect(app.pages.changes.selection_owner.activeDiff() == null);

    app.changesNavigation().clearDiffSelection();
    app.changesNavigation().pressDiffMouse(.{ .col = 120, .row = 0 });
    try std.testing.expect(app.pages.changes.selection_owner.activeHeader() == null);
    try std.testing.expect(app.pages.changes.selection_owner.activeDiff() == null);
}

test "sidebar layout fallback clears active diff mouse drag" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{
                .display_mode = .side_by_side,
                .sidebar_hidden = true,
            },
        } },
        .terminal_size = .{ .width = 90, .height = 10 },
    };

    app.changesNavigation().pressDiffMouse(.{ .col = 4, .row = diff_render.body_start_row + 1 });
    try std.testing.expect(app.pages.changes.selection_owner.activeDiff() != null);

    app.changesNavigation().toggleSidebarVisibility();
    try std.testing.expectEqual(diff_render.DisplayMode.unified, app.changesNavigationView().effectiveDisplayMode());
    try std.testing.expect(app.pages.changes.selection_owner.activeDiff() == null);
}

test "sidebar width growth fallback clears active diff mouse drag" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{
                .display_mode = .side_by_side,
                .sidebar_hidden = false,
                .sidebar_width = 31,
            },
        } },
        .terminal_size = .{ .width = 110, .height = 10 },
    };

    try std.testing.expectEqual(diff_render.DisplayMode.side_by_side, app.changesNavigationView().effectiveDisplayMode());
    app.changesNavigation().pressDiffMouse(.{ .col = 37, .row = diff_render.body_start_row + 1 });
    try std.testing.expect(app.pages.changes.selection_owner.activeDiff() != null);

    app.changesNavigation().adjustSidebarWidth(.grow);
    try std.testing.expectEqual(diff_render.DisplayMode.unified, app.changesNavigationView().effectiveDisplayMode());
    try std.testing.expect(app.pages.changes.selection_owner.activeDiff() == null);
}

test "diff scroll cursor sync keeps search state" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
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
    app.changesNavigation().submitSearch();
    const old_match = app.pages.changes.search.match orelse return error.ExpectedSearchMatch;
    const old_match_offset = app.pages.changes.search.match_offset;

    app.changesNavigation().scrollDiff(.down);

    try std.testing.expect(std.meta.eql(old_match, app.pages.changes.search.match.?));
    try std.testing.expectEqual(old_match_offset, app.pages.changes.search.match_offset);
}

test "display mode scroll remap preserves hunk-local ratio" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var loaded = app_test_support.loadedDiffOne();
    loaded.rendered_line_cache = try diff_view_model.RenderedLineCache.build(allocator, loaded.document);

    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(loaded),
            .viewer = .{
                .display_mode = .unified,
                .sidebar_hidden = true,
            },
        } },
        .terminal_size = .{ .width = 140, .height = 8 },
    };

    const old_index = app.changesNavigationView().selectedFileLineIndex(.unified);
    const old_scroll = old_index.hunkOffset(0) + 3;
    const new_scroll = app.changesNavigationView().remapDiffScrollForModeChange(.unified, .side_by_side, old_scroll);

    const hunk_index = old_index.hunkIndexAtOffset(old_scroll) orelse return error.ExpectedHunkOffset;
    const new_index = app.changesNavigationView().selectedFileLineIndex(.side_by_side);
    const old_local = old_scroll - old_index.hunkOffset(hunk_index);
    const expected_local = old_local * (new_index.hunkLineCount(hunk_index) - 1) / (old_index.hunkLineCount(hunk_index) - 1);
    try std.testing.expectEqual(new_index.hunkOffset(hunk_index) + expected_local, new_scroll);
}

test "mode change resyncs search match to rendered body offsets" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{ .display_mode = .unified },
        } },
        .terminal_size = .{ .width = 140, .height = 14 },
    };
    setDiffSearchQuery(&app, "late new");

    app.changesNavigation().submitSearch();
    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 1, .line_index = 2 } });
    try std.testing.expectEqual(@as(?usize, 9), app.pages.changes.search.match_offset);

    app.pages.changes.viewer.display_mode = .side_by_side;
    app.changesNavigation().clampDiffNavigationKeepingHunkVisible();
    app.changesNavigation().updateSearchMatchOffset();

    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 1, .line_index = 2 } });
    try std.testing.expectEqual(@as(?usize, 7), app.pages.changes.search.match_offset);
    try std.testing.expect(app.pages.changes.search.match_offset.? >= app.pages.changes.viewer.diff_scroll);
    try std.testing.expect(app.pages.changes.search.match_offset.? < app.pages.changes.viewer.diff_scroll + app.changesNavigationView().diffVisibleRows());
}

test "mode change keeps search near later matches" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{ .display_mode = .unified },
        } },
        .terminal_size = .{ .width = 140, .height = 8 },
    };
    setDiffSearchQuery(&app, "new");

    app.changesNavigation().submitSearch();
    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 0, .line_index = 3 } });
    try std.testing.expectEqual(@as(?usize, 4), app.pages.changes.search.match_offset);
    app.changesNavigation().selectSearchMatch(.forward);
    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 1, .line_index = 2 } });
    try std.testing.expectEqual(@as(?usize, 9), app.pages.changes.search.match_offset);

    app.pages.changes.viewer.display_mode = .side_by_side;
    app.changesNavigation().clampDiffNavigationKeepingHunkVisible();
    app.changesNavigation().updateSearchMatchOffset();

    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 1, .line_index = 2 } });
    try std.testing.expectEqual(@as(?usize, 7), app.pages.changes.search.match_offset);
}

test "projection hunk fold authority denies cached projection mutation" {
    const allocator = std.testing.allocator;
    var app = try initProjectionHunkFoldHarness(allocator);
    try prepareStatusOnlyHorizontalScrollHarness(&app, allocator, "M  a\x00");
    try installCachedHunkFoldProjection(&app, allocator);
    defer app.pages.changes.deinit(allocator);

    try std.testing.expect(app.view().displayedChangesBody() == .cached);
    try expectProjectionHunkFoldDenied(&app, allocator);
}

test "projection hunk fold authority denies combined projection mutation" {
    const allocator = std.testing.allocator;
    var app = try initProjectionHunkFoldHarness(allocator);
    try prepareStatusOnlyHorizontalScrollHarness(&app, allocator, "MM a\x00");
    try installCombinedHorizontalScrollProjection(&app, allocator);
    defer app.pages.changes.deinit(allocator);

    try std.testing.expect(app.view().displayedChangesBody() == .combined);
    try expectProjectionHunkFoldDenied(&app, allocator);
}

test "projection hunk fold authority denies retained staged-only projection mutation" {
    const allocator = std.testing.allocator;
    var app = try initProjectionHunkFoldHarness(allocator);
    try prepareStatusOnlyHorizontalScrollHarness(&app, allocator, "MM a\x00");
    try installCombinedHorizontalScrollProjection(&app, allocator);
    var staged_status = try git_status.StatusBundle.parseOwned(allocator, "M  a\x00");
    try app.pages.changes.git_status.replace("/repo", &staged_status);
    try retainCombinedHorizontalScrollProjection(&app, allocator);
    defer app.pages.changes.deinit(allocator);

    try std.testing.expect(app.view().displayedChangesBody() == .retained_staged_only);
    try expectProjectionHunkFoldDenied(&app, allocator);
}

test "folded coordinate offset uses display folds without a cached index" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    const allocator = arena.allocator();
    var loaded = app_test_support.loadedDiffOne();
    loaded.collapsed_hunks = try allocator.alloc(bool, loaded.document.totalHunks());
    @memset(loaded.collapsed_hunks, false);
    loaded.collapsed_hunks[0] = true;

    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadStateWithArena(arena, loaded),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .diff_cursor = .{ .hunk_header = 1 },
            },
        } },
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer app.clearLoadedDiff();

    try std.testing.expect(app.changesNavigationView().displayedDiffLineIndex(.unified) == null);
    try std.testing.expectEqual(
        @as(?usize, diff_view_model.hunkBodyLineOffsetFolded(
            app_test_support.file_with_hunks,
            .unified,
            1,
            &.{ true, false },
        )),
        app.changesNavigationView().selectedDiffCursorOffset(),
    );

    app.pages.changes.viewer.diff_cursor = .{ .hunk_line = .{
        .hunk_index = 0,
        .line_index = 0,
    } };
    try std.testing.expect(app.changesNavigationView().selectedDiffCursorOffset() == null);

    _ = try applySharedNavigation(&app, .document_last);
    const line_count = app.changesNavigationView().displayedDiffLineCount();
    try std.testing.expectEqual(@as(?usize, line_count - 1), app.changesNavigationView().selectedDiffCursorOffset());
    try std.testing.expect(loaded.collapsed_hunks[0]);
}

test "projection hunk fold authority preserves primary fold behavior" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    const allocator = arena.allocator();
    var loaded = app_test_support.loadedDiffOne();
    loaded.collapsed_hunks = try allocator.alloc(bool, loaded.document.totalHunks());
    @memset(loaded.collapsed_hunks, false);
    loaded.rendered_line_cache = try diff_view_model.RenderedLineCache.build(allocator, loaded.document);

    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadStateWithArena(arena, loaded),
            .viewer = .{ .diff_cursor = .{ .hunk_line = .{
                .hunk_index = 0,
                .line_index = 3,
            } } },
        } },
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer app.clearLoadedDiff();

    try std.testing.expect(app.changesNavigationView().bodyAllowsHunkFold());
    try std.testing.expectEqual(@as(usize, 10), app.changesNavigationView().selectedFileLineIndex(.unified).lineCount());
    var controller = app.controller();
    var resolver = controller.bodyResolverAdapter();
    controller.sharedBodyController(&resolver).toggleSelectedHunkFold();

    const active = app.changesNavigation().activeLoadedDiff().?;
    try std.testing.expect(active.isHunkFolded(0, 0));
    try std.testing.expectEqualDeep(
        diff_view_model.BodyCoordinate{ .hunk_header = 0 },
        app.pages.changes.viewer.diff_cursor,
    );
    try std.testing.expectEqual(@as(usize, 5), app.changesNavigationView().selectedFileLineIndex(.unified).lineCount());
    try std.testing.expectEqual(@as(usize, 1), active.renderedLineIndex(0, .unified).hunkLineCount(0));
    try std.testing.expectEqual(@as(usize, 4), app.changesNavigationView().selectedFileLineIndex(.side_by_side).lineCount());
    try std.testing.expectEqual(@as(usize, 1), active.renderedLineIndex(0, .side_by_side).hunkLineCount(0));

    app.changesNavigation().toggleSelectedHunkFold();
    try std.testing.expect(!active.isHunkFolded(0, 0));
    try std.testing.expectEqual(@as(usize, 10), app.changesNavigationView().selectedFileLineIndex(.unified).lineCount());
    try std.testing.expectEqual(@as(usize, 6), active.renderedLineIndex(0, .unified).hunkLineCount(0));
    try std.testing.expectEqual(@as(usize, 8), app.changesNavigationView().selectedFileLineIndex(.side_by_side).lineCount());
    try std.testing.expectEqual(@as(usize, 5), active.renderedLineIndex(0, .side_by_side).hunkLineCount(0));
    try std.testing.expectEqualStrings("", app.status.text());
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
        .pages = .{ .changes = .{
            .load = app_test_support.loadStateWithArena(arena, loaded),
        } },
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer app.clearLoadedDiff();
    setDiffSearchQuery(&app, "new");

    app.changesNavigation().submitSearch();

    const active = app.changesNavigation().activeLoadedDiff().?;
    try std.testing.expect(!active.isHunkFolded(0, 0));
    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 0, .line_index = 3 } });
    try std.testing.expectEqual(@as(?usize, 4), app.pages.changes.search.match_offset);
}

test "projection hunk fold authority preserves retained staged-only search unfold" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    var loaded = app_test_support.loadedDiffOne();
    loaded.collapsed_hunks = try arena.allocator().alloc(bool, loaded.document.totalHunks());
    @memset(loaded.collapsed_hunks, false);
    loaded.rendered_line_cache = try diff_view_model.RenderedLineCache.build(arena.allocator(), loaded.document);

    var app = TestHarness.init(.{
        .load = app_test_support.loadStateWithArena(arena, loaded),
        .viewer = .{ .selected_target = .{ .diff_file = 0 } },
    }, .{ .width = 100, .height = 12 });
    try prepareStatusOnlyHorizontalScrollHarness(&app, allocator, "MM a\x00");
    try installCombinedHorizontalScrollProjection(&app, allocator);
    var staged_status = try git_status.StatusBundle.parseOwned(allocator, "M  a\x00");
    try app.pages.changes.git_status.replace("/repo", &staged_status);
    try retainCombinedHorizontalScrollProjection(&app, allocator);
    defer app.pages.changes.deinit(allocator);

    const active = app.controller().activeLoadedDiff() orelse return error.ExpectedLoadedDiff;
    active.setHunkFolded(0, 0, true);
    try std.testing.expect(active.isHunkFolded(0, 0));
    try std.testing.expectEqual(
        diff_surface.SearchUnfoldPolicy.unfold_underlying,
        app.view().resolvedTarget().search_unfold_policy,
    );

    app.controller().unfoldSearchMatchIfNeeded(.{ .coordinate = .{ .hunk_line = .{
        .hunk_index = 0,
        .line_index = 0,
    } } });
    try std.testing.expect(!active.isHunkFolded(0, 0));
}

test "manual fold keeps hunk open when it contains active search match" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    const allocator = arena.allocator();
    var loaded = app_test_support.loadedDiffOne();
    loaded.collapsed_hunks = try allocator.alloc(bool, loaded.document.totalHunks());
    @memset(loaded.collapsed_hunks, false);
    loaded.rendered_line_cache = try diff_view_model.RenderedLineCache.build(allocator, loaded.document);

    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadStateWithArena(arena, loaded),
        } },
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer app.clearLoadedDiff();
    setDiffSearchQuery(&app, "new");
    app.changesNavigation().submitSearch();

    app.changesNavigation().toggleSelectedHunkFold();

    const active = app.changesNavigation().activeLoadedDiff().?;
    try std.testing.expect(!active.isHunkFolded(0, 0));
    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 0, .line_index = 3 } });
    try std.testing.expectEqual(@as(?usize, 4), app.pages.changes.search.match_offset);
}

test "file change resyncs retained search query to selected file" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffTwo()),
            .viewer = .{ .display_mode = .unified },
        } },
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    setDiffSearchQuery(&app, "target");

    app.changesNavigation().selectFileAbsolute(1);

    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.changes.viewer.selected_target.?);
    try expectSearchCoordinate(&app, .{ .metadata = 0 });
    try std.testing.expectEqual(@as(?usize, 0), app.pages.changes.search.match_offset);
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.viewer.diff_scroll);
}

test "sidebar navigation can select directories without changing selected file" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffNested()),
            .viewer = .{
                .selected_node = 1,
            },
        } },
        .terminal_size = .{ .width = 100, .height = 12 },
    };

    app.changesNavigation().selectFileDelta(-1);
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, app.pages.changes.viewer.selected_target.?);

    app.changesNavigation().selectFileDelta(1);
    try std.testing.expectEqual(@as(usize, 1), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, app.pages.changes.viewer.selected_target.?);

    app.changesNavigation().selectFileDelta(1);
    try std.testing.expectEqual(@as(usize, 2), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.changes.viewer.selected_target.?);
}

test "toggling selected directory collapses visible descendants" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), app_test_support.loadedDiffNested()),
            .viewer = .{
                .selected_node = 0,
            },
        } },
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer app.clearLoadedDiff();

    try app.changesNavigation().toggleSelectedDirectory();

    const loaded = app.pages.changes.load.state.loaded.loaded;
    try std.testing.expect(file_tree.isCollapsed(&loaded.collapsed_dirs, "src"));
    try std.testing.expectEqual(@as(usize, 1), loaded.tree.visibleNodeCount(&loaded.collapsed_dirs));
    try std.testing.expect(loaded.visible_nodes.len >= loaded.tree.nodes.len);
    try std.testing.expectEqual(@as(usize, 1), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(?usize, 0), loaded.visibleNodeAt(0));
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.viewer.selected_node);
}

test "changes root expansion ignores toggle and expand while retaining diff target" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), app_test_support.loadedDiffRootedNested()),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_node = 0,
            },
        } },
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer app.clearLoadedDiff();

    try app.changesNavigation().toggleSelectedDirectory();

    var loaded = app.changesNavigation().activeLoadedDiff().?;
    try std.testing.expectEqual(@as(usize, 4), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(?usize, 0), loaded.visibleNodeAt(0));
    try std.testing.expectEqual(@as(u16, 1), loaded.tree.nodes[loaded.visibleNodeAt(1).?].depth);
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.changes.viewer.selected_target.?);
    try std.testing.expect(!file_tree.isCollapsed(&loaded.collapsed_dirs, ""));

    try app.changesNavigation().expandSelectedDirectory();

    loaded = app.changesNavigation().activeLoadedDiff().?;
    try std.testing.expectEqual(@as(usize, 4), loaded.visibleNodeCount());
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.changes.viewer.selected_target.?);
}

test "changes root expansion mouse click selects root without hiding children" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), app_test_support.loadedDiffRootedNested()),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_node = 3,
                .focus = .diff,
            },
        } },
    };
    defer app.clearLoadedDiff();

    try app.changesNavigation().clickSidebarNode(0);

    const loaded = app.changesNavigation().activeLoadedDiff().?;
    try std.testing.expectEqual(changes_page.Focus.sidebar, app.pages.changes.viewer.focus);
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(@as(usize, 4), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(u16, 1), loaded.tree.nodes[loaded.visibleNodeAt(1).?].depth);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.changes.viewer.selected_target.?);
}

test "repository switch resets Changes navigation" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_node = 3,
            },
            .search = .{
                .mode = true,
            },
        } },
    };
    setDiffSearchQuery(&app, "needle");

    app.changesNavigation().resetAfterRepositorySwitch();

    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, app.pages.changes.viewer.selected_target.?);
    try std.testing.expect(!app.pages.changes.search.mode);
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.search.input.len);
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.search.query.len);
}

test "changes root expansion keeps left and right on root as no-ops" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), app_test_support.loadedDiffRootedNested()),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_node = 1,
            },
        } },
    };
    defer app.clearLoadedDiff();

    try app.changesNavigation().collapseOrSelectParentDirectory();
    var loaded = app.changesNavigation().activeLoadedDiff().?;
    try std.testing.expect(file_tree.isCollapsed(&loaded.collapsed_dirs, "src"));
    try std.testing.expectEqual(@as(usize, 2), loaded.visibleNodeCount());

    try app.changesNavigation().collapseOrSelectParentDirectory();
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.viewer.selected_node);

    try app.changesNavigation().collapseOrSelectParentDirectory();
    loaded = app.changesNavigation().activeLoadedDiff().?;
    try std.testing.expectEqual(@as(usize, 2), loaded.visibleNodeCount());

    try app.changesNavigation().expandSelectedDirectory();
    loaded = app.changesNavigation().activeLoadedDiff().?;
    try std.testing.expect(file_tree.isCollapsed(&loaded.collapsed_dirs, "src"));
    try std.testing.expectEqual(@as(usize, 2), loaded.visibleNodeCount());
}

test "file search selects matching file and expands ancestors" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), fileSearchLoadedNested()),
            .viewer = .{
                .selected_node = 0,
            },
            .file_search = .{ .mode = true },
        } },
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer app.clearLoadedDiff();

    var loaded = app.changesNavigation().activeLoadedDiff().?;
    try file_tree.collapse(app.changesNavigation().loadArenaAllocator().?, &loaded.collapsed_dirs, "src");
    setAndRebuildFileSearch(&app, "src/b");

    app.changesNavigation().submitFileSearch(std.testing.allocator);

    loaded = app.changesNavigation().activeLoadedDiff().?;
    try std.testing.expect(!file_tree.isCollapsed(&loaded.collapsed_dirs, "src"));
    try std.testing.expectEqual(@as(usize, 2), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.changes.viewer.selected_target.?);
    try std.testing.expect(!app.pages.changes.file_search.mode);
    try std.testing.expectEqual(changes_page.Focus.diff, app.pages.changes.viewer.focus);
}

test "changes root expansion file search reveals only collapsed ancestors" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), fileSearchLoadedRootedNested()),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_node = 0,
            },
            .file_search = .{ .mode = true },
        } },
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer app.clearLoadedDiff();

    const loaded = app.changesNavigation().activeLoadedDiff().?;
    try loaded.rebuildVisibleNodes(
        app.changesNavigation().loadArenaAllocator().?,
        false,
        .all,
    );
    try file_tree.collapse(app.changesNavigation().loadArenaAllocator().?, &loaded.collapsed_dirs, "src");
    try loaded.rebuildVisibleNodes(
        app.changesNavigation().loadArenaAllocator().?,
        false,
        .all,
    );
    setAndRebuildFileSearch(&app, "src/b");

    app.changesNavigation().submitFileSearch(std.testing.allocator);

    try std.testing.expect(!file_tree.isCollapsed(&loaded.collapsed_dirs, "src"));
    try std.testing.expect(!file_tree.isCollapsed(&loaded.collapsed_dirs, ""));
    try std.testing.expectEqual(@as(usize, 3), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.changes.viewer.selected_target.?);
    try std.testing.expect(!app.pages.changes.file_search.mode);
    try std.testing.expectEqual(changes_page.Focus.diff, app.pages.changes.viewer.focus);
}

test "changes transition exact lookup accepts diff status and collapsed raw paths" {
    const identity: root_capability.Identity = .{ .device = 3, .inode = 5 };
    {
        var app: TestHarness = .{
            .pages = .{ .changes = .{
                .load = app_test_support.loadState(app_test_support.loadedDiffNested()),
                .viewer = .{ .selected_node = 1 },
            } },
            .repo_epoch = 4,
            .root_identity = identity,
        };
        defer app.clearLoadedDiff();

        const loaded = app.changesNavigation().activeLoadedDiff().?;
        try file_tree.collapse(app.changesNavigation().loadArenaAllocator().?, &loaded.collapsed_dirs, "src");

        try expectExactPathReady(
            app.changesNavigation().exactPathTarget(exactChangesIntent(&app, "src/b")),
            2,
        );
        try std.testing.expect(file_tree.isCollapsed(&loaded.collapsed_dirs, "src"));
        try std.testing.expectEqual(@as(usize, 1), app.pages.changes.viewer.selected_node);
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
            .pages = .{ .changes = .{
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
            app.changesNavigation().exactPathTarget(exactChangesIntent(&app, raw_path)),
            0,
        );
    }
}

test "changes transition exact lookup rejects non-current repository sources" {
    const identity: root_capability.Identity = .{ .device = 3, .inode = 5 };
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffNested()),
            .viewer = .{ .selected_node = 1 },
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
            app.changesNavigation().exactPathTarget(exactChangesIntent(&app, "src/a")),
            .source_unavailable,
        );
        try std.testing.expectEqual(@as(usize, 1), app.pages.changes.viewer.selected_node);
    }

    app.source = .cached;
    try expectExactPathReady(
        app.changesNavigation().exactPathTarget(exactChangesIntent(&app, "src/a")),
        1,
    );
}

test "changes transition exact lookup skips colliding directories before files" {
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
        .pages = .{ .changes = .{
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
        replacement_app.changesNavigation().exactPathTarget(exactChangesIntent(&replacement_app, "src")),
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
        .pages = .{ .changes = .{
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
        directory_app.changesNavigation().exactPathTarget(exactChangesIntent(&directory_app, "src")),
        .path_not_found,
    );

    const legacy_nodes = [_]file_tree.Node{
        .{ .kind = .directory, .name = "legacy", .path = "legacy", .depth = 0 },
        .{ .kind = .file, .name = "legacy", .path = "legacy", .depth = 0, .target = .{ .status_entry = 0 } },
    };
    var legacy_app: TestHarness = .{
        .pages = .{ .changes = .{
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
        legacy_app.changesNavigation().exactPathTarget(exactChangesIntent(&legacy_app, "legacy")),
        1,
    );
}

test "changes transition exact lookup preserves reviewed and changed filters" {
    const identity: root_capability.Identity = .{ .device = 3, .inode = 5 };
    {
        var reviewed = [_]bool{ true, false };
        var app: TestHarness = .{
            .pages = .{ .changes = .{
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
            app.changesNavigation().exactPathTarget(exactChangesIntent(&app, "src/a")),
            .hidden_by_filters,
        );
        try expectExactPathReady(
            app.changesNavigation().exactPathTarget(exactChangesIntent(&app, "src/b")),
            2,
        );
        try std.testing.expect(app.pages.changes.review_display.hide_reviewed_files);
    }

    {
        var app: TestHarness = .{
            .pages = .{ .changes = .{
                .load = app_test_support.loadState(app_test_support.loadedDiffTwoWithStatuses()),
                .review_display = .{ .changed_file_filter = .added },
            } },
            .repo_epoch = 4,
            .root_identity = identity,
        };
        defer app.clearLoadedDiff();

        try expectExactPathUnavailable(
            app.changesNavigation().exactPathTarget(exactChangesIntent(&app, "src/deleted.zig")),
            .hidden_by_filters,
        );
        try expectExactPathReady(
            app.changesNavigation().exactPathTarget(exactChangesIntent(&app, "src/added.zig")),
            0,
        );
        try std.testing.expectEqual(ChangedFileFilter.added, app.pages.changes.review_display.changed_file_filter);
    }
}

test "changes transition exact lookup rejects identity absence and non-file paths" {
    const identity: root_capability.Identity = .{ .device = 3, .inode = 5 };
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffNested()),
            .viewer = .{ .selected_node = 1 },
        } },
        .repo_epoch = 4,
        .root_identity = identity,
    };
    defer app.clearLoadedDiff();

    var wrong_epoch = exactChangesIntent(&app, "src/b");
    wrong_epoch.repo_epoch += 1;
    try expectExactPathUnavailable(app.changesNavigation().exactPathTarget(wrong_epoch), .repository_mismatch);

    var wrong_root = exactChangesIntent(&app, "src/b");
    wrong_root.root_identity.inode += 1;
    try expectExactPathUnavailable(app.changesNavigation().exactPathTarget(wrong_root), .repository_mismatch);
    try expectExactPathUnavailable(
        app.changesNavigation().exactPathTarget(exactChangesIntent(&app, "missing.zig")),
        .path_not_found,
    );
    try expectExactPathUnavailable(
        app.changesNavigation().exactPathTarget(exactChangesIntent(&app, "src")),
        .path_not_found,
    );
    try std.testing.expectEqual(@as(usize, 1), app.pages.changes.viewer.selected_node);

    app.clearLoadedDiff();
    try expectExactPathUnavailable(
        app.changesNavigation().exactPathTarget(exactChangesIntent(&app, "src/b")),
        .no_accepted_changes,
    );

    app.root_identity = null;
    const explicit_intent: page_link.ChangesLocationIntent = .{
        .repo_epoch = app.repo_epoch,
        .root_identity = identity,
        .path = "src/b",
    };
    try expectExactPathUnavailable(app.changesNavigation().exactPathTarget(explicit_intent), .repository_mismatch);
}

test "changes transition exact reveal expands only target ancestors and selects normally" {
    const identity: root_capability.Identity = .{ .device = 3, .inode = 5 };
    var app: TestHarness = .{
        .pages = .{ .changes = .{
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
    const allocator = app.changesNavigation().loadArenaAllocator().?;
    const loaded = app.changesNavigation().activeLoadedDiff().?;
    try file_tree.collapse(allocator, &loaded.collapsed_dirs, "src");
    try file_tree.collapse(allocator, &loaded.collapsed_dirs, "lib");
    setDiffSearchQuery(&app, "target");

    try expectExactPathRevealSelected(
        try app.changesNavigation().revealExactPath(exactChangesIntent(&app, "src/b")),
        4,
    );

    try std.testing.expect(!file_tree.isCollapsed(&loaded.collapsed_dirs, "src"));
    try std.testing.expect(file_tree.isCollapsed(&loaded.collapsed_dirs, "lib"));
    try std.testing.expectEqual(@as(?usize, 4), loaded.visibleNodeAt(3));
    try std.testing.expectEqual(@as(usize, 4), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.changes.viewer.selected_target.?);
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.viewer.diff_scroll);
    try std.testing.expectEqual(@as(usize, 3), app.pages.changes.viewer.diff_horizontal_scroll);
    try std.testing.expectEqual(@as(usize, 2), app.pages.changes.viewer.sidebar_horizontal_scroll);
    try std.testing.expectEqual(changes_page.Focus.diff, app.pages.changes.viewer.focus);
    try std.testing.expectEqual(diff_render.DisplayMode.unified, app.pages.changes.viewer.display_mode);
    try std.testing.expectEqualStrings("target", app.pages.changes.search.query.slice());
    try std.testing.expect(app.pages.changes.selection_owner == .none);
}

test "changes transition exact reveal selects status-only and reports unchanged" {
    const identity: root_capability.Identity = .{ .device = 3, .inode = 5 };
    const nodes = [_]file_tree.Node{
        .{ .kind = .file, .name = "a", .path = "a", .depth = 0, .target = .{ .diff_file = 0 } },
        .{ .kind = .file, .name = "new.zig", .path = "new.zig", .depth = 0, .target = .{ .status_entry = 0 }, .status = .added },
    };
    var app: TestHarness = .{
        .pages = .{ .changes = .{
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
                .selected_node = 0,
                .display_mode = .unified,
            },
        } },
        .repo_epoch = 4,
        .root_identity = identity,
    };
    defer app.clearLoadedDiff();
    defer app.pages.changes.git_status.deinit();
    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? new.zig\x00");
    try app.pages.changes.git_status.replace("/repo", &status_bundle);

    try expectExactPathRevealSelected(
        try app.changesNavigation().revealExactPath(exactChangesIntent(&app, "new.zig")),
        1,
    );
    try std.testing.expectEqual(@as(usize, 1), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .status_only = 0 }, app.pages.changes.viewer.selected_target.?);
    try std.testing.expectEqual(diff_render.DisplayMode.unified, app.pages.changes.viewer.display_mode);

    app.pages.changes.viewer.diff_scroll = 9;
    try expectExactPathRevealUnchanged(
        try app.changesNavigation().revealExactPath(exactChangesIntent(&app, "new.zig")),
        1,
    );
    try std.testing.expectEqual(@as(usize, 9), app.pages.changes.viewer.diff_scroll);
    try std.testing.expectEqual(context.SelectedTarget{ .status_only = 0 }, app.pages.changes.viewer.selected_target.?);
}

test "changes transition selected exact node still reveals collapsed ancestor" {
    const identity: root_capability.Identity = .{ .device = 3, .inode = 5 };
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), app_test_support.loadedDiffNested()),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_node = 2,
            },
        } },
        .repo_epoch = 4,
        .root_identity = identity,
    };
    defer app.clearLoadedDiff();
    const loaded = app.changesNavigation().activeLoadedDiff().?;
    try file_tree.collapse(app.changesNavigation().loadArenaAllocator().?, &loaded.collapsed_dirs, "src");
    try std.testing.expectEqual(@as(?usize, null), loaded.visibleRowOfNode(2));

    try expectExactPathRevealSelected(
        try app.changesNavigation().revealExactPath(exactChangesIntent(&app, "src/b")),
        2,
    );

    try std.testing.expect(!file_tree.isCollapsed(&loaded.collapsed_dirs, "src"));
    try std.testing.expectEqual(@as(?usize, 2), loaded.visibleRowOfNode(2));
    try std.testing.expectEqual(@as(usize, 2), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.changes.viewer.selected_target.?);
}

test "changes root expansion exact reveal expands only ordinary ancestors" {
    const identity: root_capability.Identity = .{ .device = 3, .inode = 5 };
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), app_test_support.loadedDiffRootedNested()),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_node = 0,
            },
        } },
        .repo_epoch = 4,
        .root_identity = identity,
    };
    defer app.clearLoadedDiff();
    const loaded = app.changesNavigation().activeLoadedDiff().?;
    const allocator = app.changesNavigation().loadArenaAllocator().?;
    try file_tree.collapse(allocator, &loaded.collapsed_dirs, "src");
    try loaded.rebuildVisibleNodes(allocator, false, .all);
    try std.testing.expectEqual(@as(?usize, null), loaded.visibleRowOfNode(3));

    try expectExactPathRevealSelected(
        try app.changesNavigation().revealExactPath(exactChangesIntent(&app, "src/b")),
        3,
    );

    try std.testing.expect(!file_tree.isCollapsed(&loaded.collapsed_dirs, "src"));
    try std.testing.expectEqual(@as(?usize, 3), loaded.visibleRowOfNode(3));
    try std.testing.expectEqual(@as(usize, 3), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.changes.viewer.selected_target.?);
}

test "changes transition unavailable exact reveal preserves navigation folds and filters" {
    const identity: root_capability.Identity = .{ .device = 3, .inode = 5 };
    var reviewed = [_]bool{ true, false };
    var app: TestHarness = .{
        .pages = .{ .changes = .{
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
    const loaded = app.changesNavigation().activeLoadedDiff().?;
    try file_tree.collapse(app.changesNavigation().loadArenaAllocator().?, &loaded.collapsed_dirs, "src");

    try expectExactPathRevealUnavailable(
        try app.changesNavigation().revealExactPath(exactChangesIntent(&app, "src/a")),
        .hidden_by_filters,
    );
    try std.testing.expect(file_tree.isCollapsed(&loaded.collapsed_dirs, "src"));
    try std.testing.expect(app.pages.changes.review_display.hide_reviewed_files);
    try std.testing.expectEqual(@as(usize, 2), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.changes.viewer.selected_target.?);
    try std.testing.expectEqual(@as(usize, 6), app.pages.changes.viewer.diff_scroll);
    try std.testing.expectEqual(@as(usize, 2), app.pages.changes.viewer.diff_horizontal_scroll);
    try std.testing.expect(std.meta.eql(
        diff_view_model.BodyCoordinate{ .metadata = 1 },
        app.pages.changes.viewer.diff_cursor,
    ));
}

test "changes transition exact reveal allocation failure rolls back before ancestor expansion" {
    const identity: root_capability.Identity = .{ .device = 3, .inode = 5 };
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffNested()),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
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
    const loaded = app.changesNavigation().activeLoadedDiff().?;
    try file_tree.collapse(app.changesNavigation().loadArenaAllocator().?, &loaded.collapsed_dirs, "src");
    const visible_before = loaded.visibleNodeCount();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });

    try std.testing.expectError(
        error.OutOfMemory,
        app.changesNavigation().revealExactPathWithAllocator(
            exactChangesIntent(&app, "src/b"),
            failing.allocator(),
        ),
    );

    try std.testing.expect(file_tree.isCollapsed(&loaded.collapsed_dirs, "src"));
    try std.testing.expectEqual(visible_before, loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(usize, 1), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, app.pages.changes.viewer.selected_target.?);
    try std.testing.expectEqual(@as(usize, 7), app.pages.changes.viewer.diff_scroll);
    try std.testing.expectEqual(@as(usize, 4), app.pages.changes.viewer.diff_horizontal_scroll);
    try std.testing.expectEqual(@as(usize, 3), app.pages.changes.viewer.sidebar_horizontal_scroll);
    try std.testing.expectEqual(changes_page.Focus.diff, app.pages.changes.viewer.focus);
    try std.testing.expectEqual(diff_render.DisplayMode.unified, app.pages.changes.viewer.display_mode);
    try std.testing.expect(app.pages.changes.selection_owner.activeHeader() != null);
}

test "file search keeps prompt open on no match" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(fileSearchLoadedNested()),
            .file_search = .{ .mode = true },
        } },
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    setAndRebuildFileSearch(&app, "missing");

    defer app.pages.changes.file_search.deinit(std.testing.allocator);

    app.changesNavigation().submitFileSearch(std.testing.allocator);

    try std.testing.expect(app.pages.changes.file_search.mode);
    try std.testing.expect(app.pages.changes.file_search.no_match);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, app.pages.changes.viewer.selected_target.?);
}

test "file search skips hidden reviewed matches" {
    var reviewed = [_]bool{ true, false };
    var app: TestHarness = .{
        .pages = .{ .changes = .{
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
    try app.changesNavigation().activeLoadedDiff().?.rebuildVisibleNodes(
        app.changesNavigation().loadArenaAllocator().?,
        true,
        .all,
    );
    setAndRebuildFileSearch(&app, "src");

    app.changesNavigation().submitFileSearch(std.testing.allocator);

    try std.testing.expect(!app.pages.changes.file_search.mode);
    try std.testing.expect(!app.pages.changes.file_search.no_match);
    try std.testing.expectEqual(@as(usize, 2), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.changes.viewer.selected_target.?);
    try std.testing.expectEqual(changes_page.Focus.diff, app.pages.changes.viewer.focus);
}

test "file search empty Enter accepts the first exact candidate" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(fileSearchLoadedNested()),
            .viewer = .{ .focus = .diff },
        } },
        .terminal_size = .{ .width = 100, .height = 12 },
    };

    app.changesNavigation().enterFileSearchMode(std.testing.allocator);
    try std.testing.expectEqual(changes_page.Focus.sidebar, app.pages.changes.viewer.focus);
    setAndRebuildFileSearch(&app, "   ");

    app.changesNavigation().submitFileSearch(std.testing.allocator);

    try std.testing.expect(!app.pages.changes.file_search.mode);
    try std.testing.expectEqual(changes_page.Focus.diff, app.pages.changes.viewer.focus);
    try std.testing.expectEqual(@as(usize, 1), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, app.pages.changes.viewer.selected_target.?);
}

test "file search Enter commits the displayed moved candidate" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(fileSearchLoadedNested()),
            .viewer = .{ .selected_target = .{ .diff_file = 0 }, .selected_node = 1, .focus = .diff },
        } },
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer app.clearLoadedDiff();

    app.changesNavigation().enterFileSearchMode(std.testing.allocator);
    app.pages.changes.file_search.move(1);
    try std.testing.expectEqualStrings("src/b", app.pages.changes.file_search.focusedCandidate().?.path_key);

    app.changesNavigation().submitFileSearch(std.testing.allocator);

    try std.testing.expect(!app.pages.changes.file_search.mode);
    try std.testing.expectEqual(@as(usize, 2), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.changes.viewer.selected_target.?);
    try std.testing.expectEqual(changes_page.Focus.diff, app.pages.changes.viewer.focus);
}

test "file search Enter keeps unavailable and stale projections inert" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(fileSearchLoadedNested()),
            .viewer = .{ .selected_target = .{ .diff_file = 0 }, .selected_node = 1 },
            .file_search = .{ .mode = true },
        } },
    };
    defer app.clearLoadedDiff();

    app.changesNavigation().submitFileSearch(std.testing.allocator);
    try std.testing.expect(app.pages.changes.file_search.mode);
    try std.testing.expect(!app.pages.changes.file_search.projection_available);
    try std.testing.expectEqual(@as(usize, 1), app.pages.changes.viewer.selected_node);

    app.changesNavigation().rebuildFileSearchProjection(std.testing.allocator);
    try std.testing.expect(app.pages.changes.file_search.projection_available);
    app.pages.changes.accepted_sidebar_revision += 1;

    app.changesNavigation().submitFileSearch(std.testing.allocator);

    try std.testing.expect(app.pages.changes.file_search.mode);
    try std.testing.expect(!app.pages.changes.file_search.projection_available);
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.file_search.candidates.len);
    try std.testing.expectEqual(@as(usize, 1), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, app.pages.changes.viewer.selected_target.?);
    try std.testing.expectEqual(changes_page.Focus.sidebar, app.pages.changes.viewer.focus);
}

test "file search disclosure allocation failure preserves prompt folds and selection" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), fileSearchLoadedNested()),
            .viewer = .{ .selected_target = .{ .diff_file = 0 }, .selected_node = 1 },
            .file_search = .{ .mode = true },
        } },
    };
    defer app.clearLoadedDiff();
    defer app.pages.changes.file_search.deinit(std.testing.allocator);

    const loaded = app.changesNavigation().activeLoadedDiff().?;
    try file_tree.collapse(app.changesNavigation().loadArenaAllocator().?, &loaded.collapsed_dirs, "src");
    setAndRebuildFileSearch(&app, "src/b");
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });

    app.changesNavigation().submitFileSearchWithVisibleAllocator(std.testing.allocator, failing.allocator());

    try std.testing.expect(app.pages.changes.file_search.mode);
    try std.testing.expect(app.pages.changes.file_search.projection_available);
    try std.testing.expectEqualStrings("src/b", app.pages.changes.file_search.focusedCandidate().?.path_key);
    try std.testing.expect(file_tree.isCollapsed(&loaded.collapsed_dirs, "src"));
    try std.testing.expectEqual(@as(usize, 1), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, app.pages.changes.viewer.selected_target.?);
    try std.testing.expectEqual(changes_page.Focus.sidebar, app.pages.changes.viewer.focus);
    try std.testing.expectEqualStrings("Could not reveal file search result", app.status.text());
}

test "file search Enter commits an exact status-only candidate" {
    const nodes = [_]file_tree.Node{
        .{ .kind = .file, .name = "a", .path = "a", .path_key = "a", .depth = 0, .target = .{ .diff_file = 0 } },
        .{ .kind = .file, .name = "new.zig", .path = "new.zig", .path_key = "new.zig", .depth = 0, .target = .{ .status_entry = 0 }, .status = .added },
    };
    var app: TestHarness = .{
        .pages = .{ .changes = .{
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
    defer app.pages.changes.git_status.deinit();
    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? new.zig\x00");
    try app.pages.changes.git_status.replace("/repo", &status_bundle);
    setAndRebuildFileSearch(&app, "new.zig");

    app.changesNavigation().submitFileSearch(std.testing.allocator);

    try std.testing.expect(!app.pages.changes.file_search.mode);
    try std.testing.expectEqual(@as(usize, 1), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .status_only = 0 }, app.pages.changes.viewer.selected_target.?);
    try std.testing.expectEqual(changes_page.Focus.diff, app.pages.changes.viewer.focus);
}

test "file search keeps diff focus while sidebar is hidden" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), fileSearchLoadedNested()),
            .viewer = .{ .focus = .diff, .sidebar_hidden = true },
        } },
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer app.clearLoadedDiff();

    app.changesNavigation().enterFileSearchMode(std.testing.allocator);
    try std.testing.expectEqual(changes_page.Focus.diff, app.pages.changes.viewer.focus);
    setAndRebuildFileSearch(&app, "   ");

    app.changesNavigation().submitFileSearch(std.testing.allocator);

    try std.testing.expect(!app.pages.changes.file_search.mode);
    try std.testing.expectEqual(changes_page.Focus.diff, app.pages.changes.viewer.focus);

    app.changesNavigation().enterFileSearchMode(std.testing.allocator);
    setAndRebuildFileSearch(&app, "src/b");

    app.changesNavigation().submitFileSearch(std.testing.allocator);

    try std.testing.expect(!app.pages.changes.file_search.mode);
    try std.testing.expectEqual(changes_page.Focus.diff, app.pages.changes.viewer.focus);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.changes.viewer.selected_target.?);
}

test "selectedStagePathKey accepts diff and status-only selections" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffTwoWithStatuses()),
            .viewer = .{ .selected_target = .{ .diff_file = 0 } },
        } },
        .repo_root = "/repo",
    };
    defer app.clearLoadedDiff();

    try std.testing.expectEqualStrings("src/added.zig", app.changesNavigationView().selectedStagePathKey().?);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? src/new.zig\x00");
    defer app.pages.changes.git_status.deinit();
    try app.pages.changes.git_status.replace("/repo", &status_bundle);
    app.pages.changes.viewer.selected_target = .{ .status_only = 0 };

    try std.testing.expectEqualStrings("src/new.zig", app.changesNavigationView().selectedStagePathKey().?);
}

test "cached preview uses displayed diff for cursor movement" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = .{ .generation = 7 },
            .status_load = .{ .generation = 3 },
            .viewer = .{ .selected_target = .{ .status_only = 0 }, .diff_cursor = .{ .hunk_header = 0 } },
        } },
        .terminal_size = .{ .width = 100, .height = 40 },
        .source = .unstaged,
        .repo_root = "/repo",
    };
    defer app.pages.changes.git_status.deinit();
    defer app.pages.changes.changes_projection.deinit(std.testing.allocator);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  a\x00");
    try app.pages.changes.git_status.replace("/repo", &status_bundle);

    const request = try app_changes_projection.testing.cloneRequest(
        std.testing.allocator,
        app_page.RequestIdentity.changes(0, 1),
        1,
        "/repo",
        "a",
        .cached_diff,
        .unstaged,
        app.pages.changes.source_session_revision,
        app.pages.changes.status_snapshot_revision,
    );
    app.pages.changes.changes_projection.displayed = .{ .ready = .{
        .request = request,
        .value = .{ .cached_diff = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_cached_projection) },
    } };

    try std.testing.expectEqual(@as(?usize, 0), app.visibleDiffCursorOffset());
    app.changesNavigation().moveDiffCursorRows(.down);
    try std.testing.expectEqual(@as(?usize, 1), app.visibleDiffCursorOffset());
    app.changesNavigation().selectHunkDelta(1);
    try std.testing.expectEqual(diff_view_model.BodyCoordinate{ .hunk_header = 0 }, app.pages.changes.viewer.diff_cursor);
}

test "cached preview supports diff search" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = .{ .generation = 7 },
            .status_load = .{ .generation = 3 },
            .viewer = .{ .selected_target = .{ .status_only = 0 }, .diff_cursor = .{ .hunk_header = 0 } },
        } },
        .terminal_size = .{ .width = 100, .height = 40 },
        .source = .unstaged,
        .repo_root = "/repo",
    };
    defer app.pages.changes.git_status.deinit();
    defer app.pages.changes.changes_projection.deinit(std.testing.allocator);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  a\x00");
    try app.pages.changes.git_status.replace("/repo", &status_bundle);

    const request = try app_changes_projection.testing.cloneRequest(
        std.testing.allocator,
        app_page.RequestIdentity.changes(0, 1),
        1,
        "/repo",
        "a",
        .cached_diff,
        .unstaged,
        app.pages.changes.source_session_revision,
        app.pages.changes.status_snapshot_revision,
    );
    app.pages.changes.changes_projection.displayed = .{ .ready = .{
        .request = request,
        .value = .{ .cached_diff = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_cached_projection) },
    } };

    setDiffSearchInput(&app, "staged");
    app.changesNavigation().submitSearch();

    try std.testing.expect(app.pages.changes.search.match != null);
    try std.testing.expectEqual(diff_view_model.BodyCoordinate{
        .hunk_line = .{ .hunk_index = 0, .line_index = 1 },
    }, app.pages.changes.search.match.?.coordinate);
    try std.testing.expectEqual(@as(?usize, 2), app.pages.changes.search.match_offset);
    try std.testing.expectEqual(app.pages.changes.search.match.?.coordinate, app.pages.changes.viewer.diff_cursor);
}

test "retained cached projection keeps all-staged authority on diff-file route" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .status_load = .{ .generation = 3, .pending = .{ .generation = 3 } },
            .viewer = .{ .selected_target = .{ .diff_file = 0 }, .diff_cursor = .{ .hunk_header = 0 } },
        } },
        .terminal_size = .{ .width = 100, .height = 40 },
        .source = .unstaged,
        .repo_root = "/repo",
    };
    defer app.pages.changes.changes_projection.deinit(std.testing.allocator);
    defer app.pages.changes.staged_hunks.deinit(std.testing.allocator);

    const request = try app_changes_projection.testing.cloneRequest(
        std.testing.allocator,
        app_page.RequestIdentity.changes(0, 1),
        1,
        "/repo",
        "a",
        .cached_diff,
        .unstaged,
        app.pages.changes.source_session_revision,
        app.pages.changes.status_snapshot_revision,
    );
    app.pages.changes.changes_projection.displayed = .{ .ready = .{
        .request = request,
        .value = .{ .cached_diff = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_cached_projection) },
    } };

    try std.testing.expect(app.changesNavigationView().displayedChangesBody() == .cached);
    const without_marks = (try app.changesNavigationView().activeDiffDisplay(arena.allocator(), .unified)) orelse return error.ExpectedCachedDisplay;
    try std.testing.expect(without_marks.hunkStagePresentation() == .all_staged);

    const cached_mark_key: session_hunk_mark.Key = .{
        .content = app.changesNavigationView().currentContentToken() orelse return error.ExpectedContentToken,
        .display_hunk_index = 0,
    };
    try app.pages.changes.staged_hunks.addExact(std.testing.allocator, "/repo", "a", cached_mark_key);
    const with_marks = (try app.changesNavigationView().activeDiffDisplay(arena.allocator(), .unified)) orelse return error.ExpectedCachedDisplay;
    try std.testing.expect(with_marks.hunkStagePresentation() == .all_staged);
}

test "generated preview uses metadata cursor rows and ignores hunk movement" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = .{ .generation = 7 },
            .status_load = .{ .generation = 3 },
            .viewer = .{ .selected_target = .{ .status_only = 0 }, .diff_cursor = .{ .metadata = 0 } },
        } },
        .terminal_size = .{ .width = 100, .height = 11 },
        .source = .unstaged,
        .repo_root = "/repo",
    };
    defer app.pages.changes.git_status.deinit();
    defer app.pages.changes.changes_projection.deinit(std.testing.allocator);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? src/new.zig\x00");
    try app.pages.changes.git_status.replace("/repo", &status_bundle);

    const request = try app_changes_projection.testing.cloneRequest(
        std.testing.allocator,
        app_page.RequestIdentity.changes(0, 1),
        1,
        "/repo",
        "src/new.zig",
        .generated_added_file,
        .unstaged,
        app.pages.changes.source_session_revision,
        app.pages.changes.status_snapshot_revision,
    );
    app.pages.changes.changes_projection.displayed = .{ .ready = .{
        .request = request,
        .value = .{ .generated_added_file = try app_changes_projection.generatedFileFromContent(
            std.testing.allocator,
            "src/new.zig",
            "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n",
        ) },
    } };

    try std.testing.expectEqual(@as(?usize, 0), app.visibleDiffCursorOffset());
    app.changesNavigation().moveDiffCursorRows(.down);
    try std.testing.expectEqual(diff_view_model.BodyCoordinate{ .metadata = 1 }, app.pages.changes.viewer.diff_cursor);
    try std.testing.expectEqual(@as(?usize, 1), app.visibleDiffCursorOffset());
    app.changesNavigation().selectHunkDelta(1);
    try std.testing.expectEqual(diff_view_model.BodyCoordinate{ .metadata = 1 }, app.pages.changes.viewer.diff_cursor);

    _ = try applySharedNavigation(&app, .document_last);
    try std.testing.expectEqual(@as(?usize, 7), app.visibleDiffCursorOffset());
    _ = try applySharedNavigation(&app, .document_first);
    try std.testing.expectEqual(@as(?usize, 0), app.visibleDiffCursorOffset());
    _ = try applySharedNavigation(&app, .half_page_down);
    try std.testing.expectEqual(
        @as(?usize, @min(@max(app.view().diffVisibleRows() / 2, 1), 7)),
        app.visibleDiffCursorOffset(),
    );

    app.pages.changes.viewer.diff_scroll = 0;
    app.pages.changes.viewer.diff_cursor = .{ .metadata = 0 };
    app.changesNavigation().scrollDiff(.down);
    try std.testing.expectEqual(@as(usize, 1), app.pages.changes.viewer.diff_scroll);
    try std.testing.expectEqual(diff_view_model.BodyCoordinate{ .metadata = 2 }, app.pages.changes.viewer.diff_cursor);
}

test "generated preview blocks diff search" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = .{ .generation = 7 },
            .status_load = .{ .generation = 3 },
            .viewer = .{ .selected_target = .{ .status_only = 0 }, .diff_cursor = .{ .metadata = 0 } },
        } },
        .terminal_size = .{ .width = 100, .height = 40 },
        .source = .unstaged,
        .repo_root = "/repo",
    };
    defer app.pages.changes.git_status.deinit();
    defer app.pages.changes.changes_projection.deinit(std.testing.allocator);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? src/new.zig\x00");
    try app.pages.changes.git_status.replace("/repo", &status_bundle);

    const request = try app_changes_projection.testing.cloneRequest(
        std.testing.allocator,
        app_page.RequestIdentity.changes(0, 1),
        1,
        "/repo",
        "src/new.zig",
        .generated_added_file,
        .unstaged,
        app.pages.changes.source_session_revision,
        app.pages.changes.status_snapshot_revision,
    );
    app.pages.changes.changes_projection.displayed = .{ .ready = .{
        .request = request,
        .value = .{ .generated_added_file = try app_changes_projection.generatedFileFromContent(std.testing.allocator, "src/new.zig", "one\ntwo\nthree\n") },
    } };

    app.changesNavigation().enterSearchMode();
    try std.testing.expect(!app.pages.changes.search.mode);
    try std.testing.expectEqualStrings("search is unavailable for generated file preview", app.status.text());

    setDiffSearchInput(&app, "two");
    app.changesNavigation().submitSearch();
    try std.testing.expect(app.pages.changes.search.match == null);
    try std.testing.expect(app.pages.changes.search.match_offset == null);
    try std.testing.expectEqualStrings("search is unavailable for generated file preview", app.status.text());
}

test "staged new file preview blocks diff search" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = .{ .generation = 7 },
            .status_load = .{ .generation = 3 },
            .viewer = .{ .selected_target = .{ .status_only = 0 }, .diff_cursor = .{ .hunk_header = 0 } },
        } },
        .terminal_size = .{ .width = 100, .height = 40 },
        .source = .unstaged,
        .repo_root = "/repo",
    };
    defer app.pages.changes.git_status.deinit();
    defer app.pages.changes.changes_projection.deinit(std.testing.allocator);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "A  src/new.zig\x00");
    try app.pages.changes.git_status.replace("/repo", &status_bundle);

    const request = try app_changes_projection.testing.cloneRequest(
        std.testing.allocator,
        app_page.RequestIdentity.changes(0, 1),
        1,
        "/repo",
        "src/new.zig",
        .cached_diff,
        .unstaged,
        app.pages.changes.source_session_revision,
        app.pages.changes.status_snapshot_revision,
    );
    app.pages.changes.changes_projection.displayed = .{ .ready = .{
        .request = request,
        .value = .{ .cached_diff = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_cached_projection) },
    } };
    try std.testing.expectEqual(
        @as(?diff_surface.SearchUnavailableReason, .staged_new_preview),
        app.changesNavigationView().resolvedTarget().search_unavailable,
    );

    app.changesNavigation().enterSearchMode();
    try std.testing.expect(!app.pages.changes.search.mode);
    try std.testing.expectEqualStrings("search is unavailable for staged new file preview", app.status.text());

    setDiffSearchInput(&app, "staged");
    app.changesNavigation().submitSearch();
    try std.testing.expect(app.pages.changes.search.match == null);
    try std.testing.expect(app.pages.changes.search.match_offset == null);
    try std.testing.expectEqualStrings("search is unavailable for staged new file preview", app.status.text());
}

test "staged new file preview does not refresh existing search query" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = .{ .generation = 7 },
            .status_load = .{ .generation = 3 },
            .viewer = .{ .selected_target = .{ .status_only = 0 }, .diff_cursor = .{ .hunk_header = 0 } },
        } },
        .terminal_size = .{ .width = 100, .height = 40 },
        .source = .unstaged,
        .repo_root = "/repo",
    };
    defer app.pages.changes.git_status.deinit();
    defer app.pages.changes.changes_projection.deinit(std.testing.allocator);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "A  src/new.zig\x00");
    try app.pages.changes.git_status.replace("/repo", &status_bundle);

    const request = try app_changes_projection.testing.cloneRequest(
        std.testing.allocator,
        app_page.RequestIdentity.changes(0, 1),
        1,
        "/repo",
        "src/new.zig",
        .cached_diff,
        .unstaged,
        app.pages.changes.source_session_revision,
        app.pages.changes.status_snapshot_revision,
    );
    app.pages.changes.changes_projection.displayed = .{ .ready = .{
        .request = request,
        .value = .{ .cached_diff = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_cached_projection) },
    } };

    app.pages.changes.search.query.insertSlice("staged") catch unreachable;
    app.changesNavigation().refreshSearchForSelectedFile();

    try std.testing.expect(app.pages.changes.search.match == null);
    try std.testing.expect(app.pages.changes.search.match_offset == null);
}

test "hunk stage presentation classifies direct source authority" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
        } },
        .allocator = std.testing.allocator,
        .repo_root = "/repo",
    };

    const unstaged = try app.changesNavigationView().hunkStagePresentation(std.testing.allocator, 0);
    try std.testing.expect(unstaged == .all_unstaged);

    app.source = .cached;
    const cached = try app.changesNavigationView().hunkStagePresentation(std.testing.allocator, 0);
    try std.testing.expect(cached == .all_staged);

    app.source = .{ .range = "HEAD~1..HEAD" };
    const historical = try app.changesNavigationView().hunkStagePresentation(std.testing.allocator, 0);
    try std.testing.expect(historical == .all_unstaged);
}

test "hunk stage presentation keeps partial session marks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
        } },
        .allocator = std.testing.allocator,
        .repo_root = "/repo",
    };
    defer app.pages.changes.staged_hunks.deinit(std.testing.allocator);
    defer app.pages.changes.git_status.deinit();

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "MM a\x00");
    try app.pages.changes.git_status.replace("/repo", &status_bundle);
    const mark_key: session_hunk_mark.Key = .{
        .content = app.changesNavigationView().currentContentToken() orelse return error.ExpectedContentToken,
        .display_hunk_index = 0,
    };
    try app.pages.changes.staged_hunks.addExact(std.testing.allocator, "/repo", "a", mark_key);

    const presentation = try app.changesNavigationView().hunkStagePresentation(arena.allocator(), 0);
    try std.testing.expect(presentation == .per_hunk);
    try std.testing.expectEqual(diff_render.HunkStageState.staged, presentation.stateForHunk(0));
    try std.testing.expectEqual(diff_render.HunkStageState.unstaged, presentation.stateForHunk(1));
}

test "hunk stage presentation uses all-staged only for fresh staged-only status" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
        } },
        .allocator = std.testing.allocator,
        .repo_root = "/repo",
    };
    defer app.pages.changes.staged_hunks.deinit(std.testing.allocator);
    defer app.pages.changes.git_status.deinit();

    var staged_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  a\x00");
    try app.pages.changes.git_status.replace("/repo", &staged_bundle);
    const staged = try app.changesNavigationView().hunkStagePresentation(arena.allocator(), 0);
    try std.testing.expect(staged == .all_staged);

    const content = app.changesNavigationView().currentContentToken() orelse return error.ExpectedContentToken;
    try app.pages.changes.staged_hunks.addExact(std.testing.allocator, "/repo", "a", .{
        .content = content,
        .display_hunk_index = 0,
    });
    try app.pages.changes.staged_hunks.addExact(std.testing.allocator, "/repo", "a", .{
        .content = content,
        .display_hunk_index = 1,
    });
    const hunk_by_hunk = try app.changesNavigationView().hunkStagePresentation(arena.allocator(), 0);
    try std.testing.expect(hunk_by_hunk == .all_staged);

    var mixed_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "MM a\x00");
    try app.pages.changes.git_status.replace("/repo", &mixed_bundle);
    const mixed = try app.changesNavigationView().hunkStagePresentation(arena.allocator(), 0);
    try std.testing.expect(mixed == .per_hunk);
    try std.testing.expectEqual(diff_render.HunkStageState.staged, mixed.stateForHunk(0));
    try std.testing.expectEqual(diff_render.HunkStageState.staged, mixed.stateForHunk(1));

    app.pages.changes.status_load.pending = .{ .generation = 1 };
    const stale = try app.changesNavigationView().hunkStagePresentation(arena.allocator(), 0);
    try std.testing.expect(stale == .per_hunk);
    try std.testing.expectEqual(diff_render.HunkStageState.staged, stale.stateForHunk(0));
    try std.testing.expectEqual(diff_render.HunkStageState.staged, stale.stateForHunk(1));

    app.pages.changes.status_load.pending = null;
    var other_repo_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  a\x00");
    try app.pages.changes.git_status.replace("/other", &other_repo_bundle);
    const other_repo = try app.changesNavigationView().hunkStagePresentation(arena.allocator(), 0);
    try std.testing.expect(other_repo == .per_hunk);
    try std.testing.expectEqual(diff_render.HunkStageState.staged, other_repo.stateForHunk(0));
    try std.testing.expectEqual(diff_render.HunkStageState.staged, other_repo.stateForHunk(1));
}

test "typed action cursor remaps a directory without changing the sticky diff target" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffNested()),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_node = 1,
            },
        } },
    };
    defer app.pages.changes.action_cursor.deinit(std.testing.allocator);

    var prepared = try changes_page.action_cursor.Prepared.init(
        std.testing.allocator,
        3,
        .{ .device = 5, .inode = 8 },
        .directory,
        "src",
        1,
    );
    app.pages.changes.action_cursor.install(std.testing.allocator, &prepared, 7);
    const loaded = app.changesNavigation().activeLoadedDiff().?;

    try std.testing.expect(app.changesNavigation().remapActionCursor(loaded));
    try std.testing.expect(app.pages.changes.action_cursor.hasOwner());
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.changes.viewer.selected_target.?);
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
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(loaded),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_node = 1,
            },
        } },
    };
    defer app.pages.changes.action_cursor.deinit(std.testing.allocator);

    var prepared = try changes_page.action_cursor.Prepared.init(
        std.testing.allocator,
        3,
        .{ .device = 5, .inode = 8 },
        .repository_root,
        "",
        1,
    );
    app.pages.changes.action_cursor.install(std.testing.allocator, &prepared, 7);

    try std.testing.expect(app.changesNavigation().remapActionCursor(app.changesNavigation().activeLoadedDiff().?));
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, app.pages.changes.viewer.selected_target.?);
}

test "changes root expansion terminal file action reveals an ordinary folded ancestor" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), app_test_support.loadedDiffRootedNested()),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_node = 1,
            },
        } },
    };
    defer app.clearLoadedDiff();
    defer app.pages.changes.action_cursor.deinit(std.testing.allocator);

    try app.changesNavigation().toggleSelectedDirectory();
    const loaded = app.changesNavigation().activeLoadedDiff().?;
    try std.testing.expect(file_tree.isCollapsed(&loaded.collapsed_dirs, "src"));
    try std.testing.expectEqual(@as(usize, 2), loaded.visibleNodeCount());

    var prepared = try changes_page.action_cursor.Prepared.init(
        std.testing.allocator,
        3,
        .{ .device = 5, .inode = 8 },
        .file,
        "src/b",
        0,
    );
    app.pages.changes.action_cursor.install(std.testing.allocator, &prepared, 7);
    try std.testing.expect(app.pages.changes.action_cursor.promote(7, 3, .{ .device = 5, .inode = 8 }, .source_and_status));
    try std.testing.expect(app.pages.changes.action_cursor.startMember(7, .source, 11));
    try std.testing.expect(app.pages.changes.action_cursor.startMember(7, .status, 12));
    try std.testing.expect(app.pages.changes.action_cursor.finishMember(7, 3, .status, 12, true));
    try std.testing.expect(app.pages.changes.action_cursor.finishMember(7, 3, .source, 11, true));

    try std.testing.expect(app.changesNavigation().finalizeActionCursor(std.testing.allocator));
    try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
    try std.testing.expect(!file_tree.isCollapsed(&loaded.collapsed_dirs, "src"));
    try std.testing.expectEqual(@as(usize, 3), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.changes.viewer.selected_target.?);
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
    try loaded.rebuildVisibleNodes(arena.allocator(), false, .added);
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadStateWithArena(arena, loaded),
            .review_display = .{ .changed_file_filter = .added },
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_node = 0,
            },
        } },
    };
    defer app.clearLoadedDiff();
    defer app.pages.changes.action_cursor.deinit(std.testing.allocator);

    var prepared = try changes_page.action_cursor.Prepared.init(
        std.testing.allocator,
        3,
        .{ .device = 5, .inode = 8 },
        .directory,
        "src",
        0,
    );
    app.pages.changes.action_cursor.install(std.testing.allocator, &prepared, 7);
    try std.testing.expect(app.pages.changes.action_cursor.promote(7, 3, .{ .device = 5, .inode = 8 }, .source_and_status));
    try std.testing.expect(app.pages.changes.action_cursor.failMemberBeforeStart(7, .source));
    try std.testing.expect(app.pages.changes.action_cursor.failMemberBeforeStart(7, .status));

    try std.testing.expect(app.changesNavigation().finalizeActionCursor(std.testing.allocator));
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(file_tree.Node.Kind.repo_root, app.changesNavigation().activeLoadedDiff().?.tree.nodes[0].kind);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, app.pages.changes.viewer.selected_target.?);
}

test "disappeared file action cursor keeps the existing nearest-file fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var loaded = app_test_support.loadedDiffRootedNested();
    try loaded.rebuildVisibleNodes(arena.allocator(), false, .all);
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadStateWithArena(arena, loaded),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_node = 2,
            },
        } },
    };
    defer app.clearLoadedDiff();
    defer app.pages.changes.action_cursor.deinit(std.testing.allocator);

    var prepared = try changes_page.action_cursor.Prepared.init(
        std.testing.allocator,
        3,
        .{ .device = 5, .inode = 8 },
        .file,
        "src/discarded.zig",
        3,
    );
    app.pages.changes.action_cursor.install(std.testing.allocator, &prepared, 7);
    try std.testing.expect(app.pages.changes.action_cursor.promote(7, 3, .{ .device = 5, .inode = 8 }, .source_and_status));
    try std.testing.expect(app.pages.changes.action_cursor.failMemberBeforeStart(7, .source));
    try std.testing.expect(app.pages.changes.action_cursor.failMemberBeforeStart(7, .status));

    try std.testing.expect(app.changesNavigation().finalizeActionCursor(std.testing.allocator));
    try std.testing.expectEqual(@as(usize, 3), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.changes.viewer.selected_target.?);
}

test "changed file filter keeps only matching status rows" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), app_test_support.loadedDiffTwoWithStatuses()),
            .review_display = .{ .changed_file_filter = .added },
            .viewer = .{
                .selected_node = 1,
                .selected_target = .{ .diff_file = 1 },
            },
        } },
    };
    defer app.clearLoadedDiff();

    try app.changesNavigation().activeLoadedDiff().?.rebuildVisibleNodes(
        app.changesNavigation().loadArenaAllocator().?,
        false,
        app.pages.changes.review_display.changed_file_filter,
    );

    const loaded = app.changesNavigation().activeLoadedDiff().?;
    try std.testing.expectEqual(@as(usize, 1), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(?usize, 0), loaded.visibleNodeAt(0));
}

test "cycling changed file filter rebuilds visible nodes and reconciles selection" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), app_test_support.loadedDiffTwoWithStatuses()),
            .viewer = .{
                .selected_node = 1,
                .selected_target = .{ .diff_file = 1 },
            },
        } },
    };
    defer app.clearLoadedDiff();

    try app.changesNavigation().cycleChangedFileFilter(std.testing.allocator);

    const loaded = app.changesNavigation().activeLoadedDiff().?;
    try std.testing.expectEqual(ChangedFileFilter.modified, app.pages.changes.review_display.changed_file_filter);
    try std.testing.expectEqual(@as(usize, 0), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(usize, 1), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.changes.viewer.selected_target.?);
}

test "file visibility lens replaces candidate basis and rebuilds retained query" {
    var reviewed = [_]bool{ true, false };
    var app: TestHarness = .{
        .pages = .{ .changes = .{
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
    defer app.pages.changes.file_search.deinit(std.testing.allocator);
    setFileSearchInput(&app, "");
    app.changesNavigation().rebuildFileSearchProjection(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), app.pages.changes.file_search.candidates.len);

    try app.changesNavigation().toggleHideReviewedFiles(std.testing.allocator);

    try std.testing.expect(app.pages.changes.review_display.hide_reviewed_files);
    try std.testing.expectEqual(@as(u64, 2), app.pages.changes.accepted_sidebar_revision);
    try std.testing.expect(app.pages.changes.file_search.mode);
    try std.testing.expect(app.pages.changes.file_search.projection_available);
    try std.testing.expectEqual(@as(usize, 1), app.pages.changes.file_search.candidates.len);
    try std.testing.expectEqualStrings("b", app.pages.changes.file_search.focusedCandidate().?.path_key);
    try std.testing.expectEqual(@as(u64, 2), app.pages.changes.file_search.basis.?.accepted_sidebar_revision);

    try app.changesNavigation().toggleHideReviewedFiles(std.testing.allocator);
    try app.changesNavigation().cycleChangedFileFilter(std.testing.allocator);

    try std.testing.expect(!app.pages.changes.review_display.hide_reviewed_files);
    try std.testing.expectEqual(ChangedFileFilter.modified, app.pages.changes.review_display.changed_file_filter);
    try std.testing.expectEqual(@as(u64, 4), app.pages.changes.accepted_sidebar_revision);
    try std.testing.expect(app.pages.changes.file_search.projection_available);
    try std.testing.expectEqual(@as(usize, 1), app.pages.changes.file_search.candidates.len);
    try std.testing.expectEqualStrings("a", app.pages.changes.file_search.focusedCandidate().?.path_key);
    try std.testing.expectEqual(@as(u64, 4), app.pages.changes.file_search.basis.?.accepted_sidebar_revision);
}

test "file visibility lens preparation failure preserves old lens and candidates" {
    var reviewed = [_]bool{ false, false };
    var partial_visible_nodes = [_]usize{0};
    var app: TestHarness = .{
        .pages = .{ .changes = .{
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
    defer app.pages.changes.file_search.deinit(std.testing.allocator);
    app.changesNavigation().rebuildFileSearchProjection(std.testing.allocator);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });

    try std.testing.expectError(
        error.OutOfMemory,
        app.changesNavigation().replaceFileVisibilityLens(
            std.testing.allocator,
            failing.allocator(),
            true,
            .all,
        ),
    );

    try std.testing.expect(!app.pages.changes.review_display.hide_reviewed_files);
    try std.testing.expectEqual(@as(u64, 1), app.pages.changes.accepted_sidebar_revision);
    try std.testing.expect(app.pages.changes.file_search.projection_available);
    try std.testing.expectEqual(@as(usize, 2), app.pages.changes.file_search.candidates.len);
    try std.testing.expectEqual(@as(usize, 1), app.changesNavigation().activeLoadedDiff().?.visibleNodeCount());
}

test "candidate rebuild failure cannot reject committed file visibility lens" {
    var reviewed = [_]bool{ true, false };
    var app: TestHarness = .{
        .pages = .{ .changes = .{
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
    defer app.pages.changes.file_search.deinit(std.testing.allocator);
    setFileSearchInput(&app, "b");
    app.changesNavigation().rebuildFileSearchProjection(std.testing.allocator);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });

    try app.changesNavigation().replaceFileVisibilityLens(
        failing.allocator(),
        app.changesNavigation().loadArenaAllocator().?,
        true,
        .all,
    );

    try std.testing.expect(app.pages.changes.review_display.hide_reviewed_files);
    try std.testing.expectEqual(@as(u64, 2), app.pages.changes.accepted_sidebar_revision);
    try std.testing.expectEqual(@as(usize, 1), app.changesNavigation().activeLoadedDiff().?.visibleNodeCount());
    try std.testing.expect(app.pages.changes.file_search.mode);
    try std.testing.expectEqualStrings("b", app.pages.changes.file_search.input.slice());
    try std.testing.expect(!app.pages.changes.file_search.projection_available);
    try std.testing.expect(app.pages.changes.file_search.focusedCandidate() == null);
}

test "file search skips files outside active changed filter" {
    const nodes = [_]file_tree.Node{
        .{ .kind = .file, .name = "added.zig", .path = "src/added.zig", .path_key = "src/added.zig", .depth = 1, .target = .{ .diff_file = 0 }, .status = .added },
        .{ .kind = .file, .name = "deleted.zig", .path = "src/deleted.zig", .path_key = "src/deleted.zig", .depth = 1, .target = .{ .diff_file = 1 }, .status = .deleted },
    };
    var loaded = app_test_support.loadedDiffTwoWithStatuses();
    loaded.tree.nodes = &nodes;
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(loaded),
            .file_search = .{ .mode = true },
            .review_display = .{ .changed_file_filter = .added },
        } },
    };
    setAndRebuildFileSearch(&app, "deleted");
    defer app.pages.changes.file_search.deinit(std.testing.allocator);

    app.changesNavigation().submitFileSearch(std.testing.allocator);

    try std.testing.expect(app.pages.changes.file_search.mode);
    try std.testing.expect(app.pages.changes.file_search.no_match);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, app.pages.changes.viewer.selected_target.?);
}

test "toggleReviewedFile toggles selected diff target" {
    var reviewed = [_]bool{ false, false };
    var app: TestHarness = .{
        .pages = .{ .changes = .{
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
            },
        } },
    };
    defer app.pages.changes.reviewed_store.deinit(std.testing.allocator);

    try app.changesNavigation().toggleReviewedFile(std.testing.allocator);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, &reviewed);

    app.pages.changes.viewer.selected_node = 1;
    try app.changesNavigation().toggleReviewedFile(std.testing.allocator);
    try std.testing.expectEqualSlices(bool, &.{ false, false }, &reviewed);

    try app.changesNavigation().toggleReviewedFile(std.testing.allocator);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, &reviewed);
}

test "toggleReviewedFile uses selected target while cursor is on directory" {
    var reviewed = [_]bool{ false, false };
    var app: TestHarness = .{
        .pages = .{ .changes = .{
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
            },
        } },
    };
    defer app.pages.changes.reviewed_store.deinit(std.testing.allocator);

    try app.changesNavigation().toggleReviewedFile(std.testing.allocator);
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
        .pages = .{ .changes = .{
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

    try app.changesNavigation().toggleReviewedFile(std.testing.allocator);
    try std.testing.expectEqualSlices(bool, &.{false}, &reviewed);
}

test "raw reviewed state stays in active load only" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffTwo()),
            .viewer = .{
                .selected_node = 0,
            },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.clearLoadedDiff();
    defer app.pages.changes.reviewed_store.deinit(std.testing.allocator);

    var loaded = app.changesNavigation().activeLoadedDiff().?;
    try app.changesNavigation().materializeReviewedFiles(std.testing.allocator, loaded);
    app.pages.changes.load.state.loaded.reviewed_files_owned = true;

    try app.changesNavigation().toggleReviewedFile(std.testing.allocator);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, loaded.reviewed_files);

    app.clearLoadedDiff();
    app.pages.changes.load.state = .{ .loaded = app_test_support.loadedSession(app_test_support.loadedDiffTwo()) };
    loaded = app.changesNavigation().activeLoadedDiff().?;
    try app.changesNavigation().materializeReviewedFiles(std.testing.allocator, loaded);
    app.pages.changes.load.state.loaded.reviewed_files_owned = true;

    try std.testing.expectEqualSlices(bool, &.{ false, false }, loaded.reviewed_files);
}

test "hide reviewed files removes reviewed file rows from visible list" {
    var reviewed = [_]bool{ true, false };
    var app: TestHarness = .{
        .pages = .{ .changes = .{
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
            },
        } },
    };
    defer app.clearLoadedDiff();

    try app.changesNavigation().toggleHideReviewedFiles(std.testing.allocator);

    const loaded = app.changesNavigation().activeLoadedDiff().?;
    try std.testing.expect(app.pages.changes.review_display.hide_reviewed_files);
    try std.testing.expectEqual(@as(usize, 2), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(?usize, 0), loaded.visibleNodeAt(0));
    try std.testing.expectEqual(@as(?usize, 2), loaded.visibleNodeAt(1));
    try std.testing.expectEqual(@as(usize, 2), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.changes.viewer.selected_target.?);
}

test "hide reviewed files removes directories with no visible file descendants" {
    var reviewed = [_]bool{ true, true };
    var app: TestHarness = .{
        .pages = .{ .changes = .{
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
            },
        } },
    };
    defer app.clearLoadedDiff();

    try app.changesNavigation().toggleHideReviewedFiles(std.testing.allocator);

    const loaded = app.changesNavigation().activeLoadedDiff().?;
    try std.testing.expectEqual(@as(usize, 0), loaded.visibleNodeCount());
}

test "hide reviewed files keeps directories for non-contiguous unreviewed descendants" {
    var reviewed = [_]bool{ true, false };
    var app: TestHarness = .{
        .pages = .{ .changes = .{
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
            },
        } },
    };
    defer app.clearLoadedDiff();

    try app.changesNavigation().toggleHideReviewedFiles(std.testing.allocator);

    const loaded = app.changesNavigation().activeLoadedDiff().?;
    try std.testing.expectEqual(@as(usize, 2), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(?usize, 0), loaded.visibleNodeAt(0));
    try std.testing.expectEqual(@as(?usize, 4), loaded.visibleNodeAt(1));
}

test "marking a visible file as reviewed while hidden moves selection" {
    var reviewed = [_]bool{ false, false };
    var app: TestHarness = .{
        .pages = .{ .changes = .{
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
            },
            .review_display = .{ .hide_reviewed_files = true },
        } },
    };
    defer app.clearLoadedDiff();
    defer app.pages.changes.reviewed_store.deinit(std.testing.allocator);
    try app.changesNavigation().activeLoadedDiff().?.rebuildVisibleNodes(
        app.changesNavigation().loadArenaAllocator().?,
        true,
        .all,
    );

    try app.changesNavigation().toggleReviewedFile(std.testing.allocator);

    const loaded = app.changesNavigation().activeLoadedDiff().?;
    try std.testing.expectEqualSlices(bool, &.{ true, false }, &reviewed);
    try std.testing.expectEqual(@as(usize, 2), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(?usize, 0), loaded.visibleNodeAt(0));
    try std.testing.expectEqual(@as(?usize, 2), loaded.visibleNodeAt(1));
    try std.testing.expectEqual(@as(usize, 2), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.changes.viewer.selected_target.?);
}

test "marking reviewed under hidden lens rebuilds file search eligibility" {
    var reviewed = [_]bool{ false, false };
    var app: TestHarness = .{
        .pages = .{ .changes = .{
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
            },
            .file_search = .{ .mode = true },
            .review_display = .{ .hide_reviewed_files = true },
        } },
    };
    defer app.clearLoadedDiff();
    defer app.pages.changes.reviewed_store.deinit(std.testing.allocator);
    defer app.pages.changes.file_search.deinit(std.testing.allocator);
    try app.changesNavigation().activeLoadedDiff().?.rebuildVisibleNodes(
        app.changesNavigation().loadArenaAllocator().?,
        true,
        .all,
    );
    app.changesNavigation().rebuildFileSearchProjection(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), app.pages.changes.file_search.candidates.len);

    try app.changesNavigation().toggleReviewedFile(std.testing.allocator);

    try std.testing.expectEqualSlices(bool, &.{ true, false }, &reviewed);
    try std.testing.expectEqual(@as(u64, 2), app.pages.changes.accepted_sidebar_revision);
    try std.testing.expect(app.pages.changes.file_search.projection_available);
    try std.testing.expectEqual(@as(usize, 1), app.pages.changes.file_search.candidates.len);
    try std.testing.expectEqualStrings("b", app.pages.changes.file_search.focusedCandidate().?.path_key);
    try std.testing.expectEqual(@as(u64, 2), app.pages.changes.file_search.basis.?.accepted_sidebar_revision);
}

test "canceling edited search restores committed query and match" {
    var app: TestHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .search = .{
                .match = .{ .coordinate = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 3 } } },
                .match_offset = 4,
            },
        } },
        .terminal_size = .{ .width = 90, .height = 11 },
    };
    setDiffSearchQuery(&app, "new");

    app.changesNavigation().enterSearchMode();
    app.pages.changes.search.input.backspace();
    try app.pages.changes.search.input.insert('x');
    app.changesNavigation().cancelSearchMode();

    try std.testing.expectEqualStrings("new", app.pages.changes.search.query.slice());
    try std.testing.expectEqualStrings("new", app.pages.changes.search.input.slice());
    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 0, .line_index = 3 } });
    try std.testing.expectEqual(@as(?usize, 4), app.pages.changes.search.match_offset);
}

test "reviewed state is scoped by explicit repository identity" {
    const allocator = std.testing.allocator;
    var app: TestHarness = .{ .repo_root = "/work/one" };
    defer app.pages.changes.reviewed_store.deinit(allocator);

    try app.pages.changes.reviewed_store.set(
        allocator,
        app.repo_root,
        app_test_support.files_two[0],
        true,
    );

    var loaded_one = app_test_support.loadedDiffTwo();
    try app.changesNavigation().materializeReviewedFiles(allocator, &loaded_one);
    defer allocator.free(loaded_one.reviewed_files);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, loaded_one.reviewed_files);

    app.repo_root = "/work/two";
    var loaded_two = app_test_support.loadedDiffTwo();
    try app.changesNavigation().materializeReviewedFiles(allocator, &loaded_two);
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
        @as(usize, 9),
        maxHorizontalScrollForBodyRow(.{ .side_by_side = .{ .single = line } }, diff_render.bodyWidth(80), true),
    );
    try std.testing.expect(
        maxHorizontalScrollForBodyRow(.{ .side_by_side = .{ .single = line } }, diff_render.bodyWidth(80), false) <
            maxHorizontalScrollForBodyRow(.{ .side_by_side = .{ .single = line } }, diff_render.bodyWidth(80), true),
    );
}
