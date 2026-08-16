//! Page-independent read-only diff surface shared by Changes and, from issue
//! #34 on, the Compare page.
//!
//! This module owns the shared view-state vocabulary (viewer, search,
//! file-search, selection, activation) and the `DiffSurface` pointer bundle
//! that page adapters build per call. It must not import any page namespace
//! (`pages/changes*`, `pages/compare*`): pages depend on the surface, never the
//! other way around.

const std = @import("std");
const load_state = @import("load_state.zig");
const app_state = @import("state.zig");
const prompt = @import("prompt.zig");
const context = @import("../context.zig");
const diff_render = @import("../diff/render.zig");
const diff_search = @import("../diff/search.zig");
const diff_selection = @import("../diff/selection.zig");
const diff_source = @import("../diff/source.zig");
const diff_parser = @import("../diff/parser.zig");
const diff_view_model = @import("../diff/view_model.zig");
const file_tree = @import("../file_tree.zig");
const review_session_state = @import("../review_session/state.zig");

pub const authority = @import("diff_surface/authority.zig");
pub const body_resolver = @import("diff_surface/body_resolver.zig");
pub const content = @import("diff_surface/content.zig");
pub const file_search = @import("diff_surface/file_search.zig");
pub const input = @import("diff_surface/input.zig");
pub const layout = @import("diff_surface/layout.zig");
pub const message = @import("diff_surface/message.zig");
pub const navigation = @import("diff_surface/navigation.zig");
pub const selection = @import("diff_surface/selection.zig");
pub const selection_action = @import("diff_surface/selection_action.zig");
pub const update = @import("diff_surface/update.zig");
pub const view = @import("diff_surface/view.zig");

pub const Focus = enum {
    sidebar,
    diff,

    pub fn toggled(self: Focus) Focus {
        return switch (self) {
            .sidebar => .diff,
            .diff => .sidebar,
        };
    }
};

/// Page-owned completion behavior for an otherwise shared mouse-selection
/// transaction.
pub const SelectionCompletionPolicy = enum {
    copy_on_release,
    retain_with_actions,
};

pub const ViewOptions = struct {
    line_numbers: bool = true,

    pub fn toggleLineNumbers(self: *ViewOptions) void {
        self.line_numbers = !self.line_numbers;
    }
};

pub const ViewerState = struct {
    /// Sticky target shown in the diff pane or used by file actions.
    ///
    /// Directory sidebar rows can be selected without changing this value.
    selected_target: ?context.SelectedTarget = .{ .diff_file = 0 },
    /// Sidebar cursor. This may point at a directory, diff file, or later a
    /// status-only row; it is not necessarily the action target.
    selected_node: usize = 0,
    focus: Focus = .sidebar,
    sidebar_hidden: bool = false,
    sidebar_width: ?u16 = null,
    sidebar_horizontal_scroll: usize = 0,
    diff_scroll: usize = 0,
    diff_horizontal_scroll: usize = 0,
    diff_cursor: diff_view_model.BodyCoordinate = .{ .metadata = 0 },
    display_mode: diff_render.DisplayMode = .side_by_side,
    keyboard_selection_side: diff_selection.Side = .new,
    view_options: ViewOptions = .{},
};

pub const DiffSearchState = struct {
    mode: bool = false,
    input: prompt.TextInput = .{},
    query: prompt.TextInput = .{},
    match: ?diff_search.Match = null,
    /// Rendered body-line offset cache for match. Recomputed when display
    /// mode, fold state, or selected file changes.
    match_offset: ?usize = null,
};

pub const ReloadAnchor = struct {
    /// Sticky main-pane file identity. A directory/root sidebar cursor does not
    /// replace this target.
    path_key: []u8,
    /// Exact sidebar cursor identity, independently owned from `path_key`.
    sidebar_identity: context.SidebarIdentity,
    selected_target_tag: std.meta.Tag(context.SelectedTarget),
    visible_sidebar_row: usize,
    diff_cursor: diff_view_model.BodyCoordinate,
    diff_cursor_offset: ?usize,
    diff_scroll: usize,
    selection_viewport: ?selection_action.SelectionViewportAnchor = null,
    diff_horizontal_scroll: usize,
    sidebar_horizontal_scroll: usize,
    search_coordinate: ?diff_view_model.BodyCoordinate,

    pub fn deinit(self: *ReloadAnchor, allocator: std.mem.Allocator) void {
        allocator.free(self.path_key);
        switch (self.sidebar_identity) {
            .repo_root => {},
            inline .directory, .file => |path| allocator.free(path),
        }
        self.* = undefined;
    }
};

/// Geometry after the shell frame has converted terminal coordinates into the
/// active page content rectangle.
pub const Layout = struct { width: u16, height: u16 };

pub const DiagnosticSink = struct {
    target: *app_state.StatusMessage,

    pub fn set(self: DiagnosticSink, comptime fmt: []const u8, args: anytype) void {
        self.target.set(fmt, args);
    }
};

pub const MousePoint = struct { col: u16, row: u16 };

pub const DiffMouseHit = struct {
    identity: diff_selection.Identity,
    side: diff_selection.Side,
    mode: diff_selection.Mode,
    point: diff_selection.Point,
};

pub const BodyResolver = body_resolver.BodyResolver;
pub const ContentToken = body_resolver.ContentToken;
pub const DiffHeaderTarget = body_resolver.DiffHeaderTarget;
pub const FoldedHunksSource = body_resolver.FoldedHunksSource;
pub const GeneratedBody = body_resolver.GeneratedBody;
pub const ReducedBodyKind = body_resolver.ReducedBodyKind;
pub const RenderProjectedBodyArgs = body_resolver.RenderProjectedBodyArgs;
pub const ResolvedTarget = body_resolver.ResolvedTarget;
pub const SearchUnavailableReason = body_resolver.SearchUnavailableReason;
pub const SearchUnfoldPolicy = body_resolver.SearchUnfoldPolicy;

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

pub const invalid_utf8_body_message = "Text preview unavailable: diff content is not valid UTF-8";

pub const HunkInteractionAvailability = body_resolver.HunkInteractionAvailability;

pub const NormalLoadedDiffSelectionTarget = struct {
    file_index: usize,
    file: diff_parser.FileDiff,
    line_index: diff_view_model.RenderedLineIndex,
    folded_hunks: []const bool,
    identity: diff_selection.Identity,
};

pub const ParsedSelectionTarget = body_resolver.ParsedSelectionTarget;
pub const SelectionRegion = navigation.SelectionRegion;
pub const ParsedMouseLine = navigation.ParsedMouseLine;

pub const RawDiffPaneGeometry = struct { col: u16, width: u16 };

pub const SearchTarget = body_resolver.SearchTarget;

/// Const-qualified projection of the shared surface for rendering and other
/// read-only consumers. It mirrors `DiffSurface` exactly, but its shared
/// state pointers cannot be used to acquire write authority.
pub const ReadSurface = struct {
    activation: *const authority.Lifecycle,
    status: *const app_state.StatusMessage,
    load: *const load_state.LoadRuntimeState,
    viewer: *const ViewerState,
    search: *const DiffSearchState,
    file_search: *const file_search.State,
    file_search_return_focus: *const Focus,
    accepted_sidebar_revision: *const u64,
    review_display: *const app_state.ReviewDisplayState,
    reviewed_store: *const review_session_state.Store,
    tree_order: *const file_tree.StableOrder,
    tree_order_scope: *const ?[]u8,
    selection_owner: *const diff_selection.Owner,
    completed_selection: *const ?selection.CompletedSelection,
    source_session_revision: *const u64,
    pending_initial_first_visible_selection: *const bool,
    selection_layout_revision: *const u64,
    reload_anchor: ?*const ReloadAnchor,
    live_drag_deferred_source: bool,
    selection_completion_policy: SelectionCompletionPolicy,
    retained_selection_install_available: bool = true,
    retained_selection_action_admitted: bool = true,
    source: diff_source.SourceMode,
    layout: Layout,
};

/// Borrowed, per-call capability over one page's shared diff state.
///
/// Pages own the fields; an adapter (`ChangesPageState.diffSurface`) builds this
/// bundle on demand, so no field moves and no long-lived aliasing exists. The
/// two partial-lift members are narrowed on purpose: the surface sees a reload
/// anchor and whether a live-drag deferred source apply is held, never the
/// page's rich reload/deferred owners (issue #34 design, field table).
/// Read-only consumers must narrow it with `readOnly` or construct a
/// `ReadSurface` directly from a const page borrow.
pub const DiffSurface = struct {
    activation: *authority.Lifecycle,
    status: *app_state.StatusMessage,
    load: *load_state.LoadRuntimeState,
    viewer: *ViewerState,
    search: *DiffSearchState,
    file_search: *file_search.State,
    file_search_return_focus: *Focus,
    accepted_sidebar_revision: *u64,
    review_display: *app_state.ReviewDisplayState,
    reviewed_store: *review_session_state.Store,
    tree_order: *file_tree.StableOrder,
    tree_order_scope: *?[]u8,
    selection_owner: *diff_selection.Owner,
    completed_selection: *?selection.CompletedSelection,
    source_session_revision: *u64,
    pending_initial_first_visible_selection: *bool,
    selection_layout_revision: *u64,
    reload_anchor: ?*const ReloadAnchor,
    live_drag_deferred_source: bool,
    selection_completion_policy: SelectionCompletionPolicy,
    retained_selection_install_available: bool = true,
    retained_selection_action_admitted: bool = true,
    source: diff_source.SourceMode,
    layout: Layout,

    /// Drops write capability while preserving the exact borrowed field set.
    pub fn readOnly(self: DiffSurface) ReadSurface {
        return .{
            .activation = self.activation,
            .status = self.status,
            .load = self.load,
            .viewer = self.viewer,
            .search = self.search,
            .file_search = self.file_search,
            .file_search_return_focus = self.file_search_return_focus,
            .accepted_sidebar_revision = self.accepted_sidebar_revision,
            .review_display = self.review_display,
            .reviewed_store = self.reviewed_store,
            .tree_order = self.tree_order,
            .tree_order_scope = self.tree_order_scope,
            .selection_owner = self.selection_owner,
            .completed_selection = self.completed_selection,
            .source_session_revision = self.source_session_revision,
            .pending_initial_first_visible_selection = self.pending_initial_first_visible_selection,
            .selection_layout_revision = self.selection_layout_revision,
            .reload_anchor = self.reload_anchor,
            .live_drag_deferred_source = self.live_drag_deferred_source,
            .selection_completion_policy = self.selection_completion_policy,
            .retained_selection_install_available = self.retained_selection_install_available,
            .retained_selection_action_admitted = self.retained_selection_action_admitted,
            .source = self.source,
            .layout = self.layout,
        };
    }
};

test {
    _ = authority;
    _ = body_resolver;
    _ = content;
    _ = file_search;
    _ = layout;
    _ = navigation;
    _ = selection;
    _ = selection_action;
    _ = update;
    _ = view;

    const mutable_fields = std.meta.fields(DiffSurface);
    const read_fields = std.meta.fields(ReadSurface);
    try std.testing.expectEqual(mutable_fields.len, read_fields.len);
    inline for (mutable_fields, read_fields) |mutable_field, read_field| {
        try std.testing.expectEqualStrings(mutable_field.name, read_field.name);
        if (@typeInfo(mutable_field.type) == .pointer) {
            const mutable_pointer = @typeInfo(mutable_field.type).pointer;
            const read_pointer = @typeInfo(read_field.type).pointer;
            try std.testing.expect(!mutable_pointer.is_const);
            try std.testing.expect(read_pointer.is_const);
            try std.testing.expect(mutable_pointer.child == read_pointer.child);
        } else {
            try std.testing.expect(mutable_field.type == read_field.type);
        }
    }
}
