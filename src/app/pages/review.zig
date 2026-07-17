const std = @import("std");
const auto_reload = @import("../auto_reload.zig");
const load = @import("../load.zig");
const load_state = @import("../load_state.zig");
const page = @import("../page.zig");
const prompt = @import("../prompt.zig");
const review_projection = @import("../review_projection.zig");
const app_state = @import("../state.zig");
pub const action_cursor = @import("review/action_cursor.zig");
const authority = @import("review/authority.zig");
pub const file_search = @import("review/file_search.zig");
const review_selection = @import("review/selection.zig");
const config = @import("../../config.zig");
const context = @import("../../context.zig");
const diff_render = @import("../../diff/render.zig");
const diff_search = @import("../../diff/search.zig");
const diff_selection = @import("../../diff/selection.zig");
const diff_source = @import("../../diff/source.zig");
const diff_view_model = @import("../../diff/view_model.zig");
const file_tree = @import("../../file_tree.zig");
const git_branch_status = @import("../../git/branch_status.zig");
const git_status = @import("../../git/status.zig");
const review_state = @import("../../review/state.zig");

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
    /// Transitional cache for older tests and helpers. Runtime reads should go
    /// through selectedFileIndex().
    /// TODO(phase8): remove after status-only targets replace diff-file-only
    /// assumptions across the app.
    selected_file: usize = 0,
    /// Sidebar cursor. This may point at a directory, diff file, or later a
    /// status-only row; it is not necessarily the action target.
    selected_node: usize = 0,
    focus: Focus = .sidebar,
    sidebar_hidden: bool = false,
    sidebar_width: ?u16 = null,
    sidebar_horizontal_scroll: usize = 0,
    /// Page-local authority for the repository-root disclosure. Directory
    /// folds remain per-load path state; the path-less root must not be stored
    /// in that map under an empty-string key.
    root_disclosure: file_tree.RootDisclosure = .expanded,
    diff_scroll: usize = 0,
    diff_horizontal_scroll: usize = 0,
    diff_cursor: diff_view_model.BodyCoordinate = .{ .metadata = 0 },
    display_mode: diff_render.DisplayMode = .side_by_side,
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

pub const ReloadKind = enum {
    initial,
    manual,
    watch,
    action_result,
    repo_switch,
};

pub const ReloadAnchor = struct {
    path_key: []u8,
    selected_target_tag: std.meta.Tag(context.SelectedTarget),
    visible_sidebar_row: usize,
    diff_cursor: diff_view_model.BodyCoordinate,
    diff_cursor_offset: ?usize,
    diff_scroll: usize,
    diff_horizontal_scroll: usize,
    sidebar_horizontal_scroll: usize,
    search_coordinate: ?diff_view_model.BodyCoordinate,

    pub fn deinit(self: *ReloadAnchor, allocator: std.mem.Allocator) void {
        allocator.free(self.path_key);
        self.* = undefined;
    }
};

pub const PendingReload = struct {
    generation: u64,
    kind: ReloadKind,
    anchor: ?ReloadAnchor = null,

    pub fn deinit(self: *PendingReload, allocator: std.mem.Allocator) void {
        if (self.anchor) |*anchor| anchor.deinit(allocator);
        self.* = undefined;
    }
};

pub const PendingDisplayNavigationRestore = struct {
    repo_root: []u8,
    source_kind: review_projection.SourceKind,
    source_session_revision: u64,
    original: ReloadAnchor,
    override: ?ReloadAnchor = null,
    captured_input_revision: u64,

    pub fn deinit(self: *PendingDisplayNavigationRestore, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        self.original.deinit(allocator);
        if (self.override) |*anchor| anchor.deinit(allocator);
        self.* = undefined;
    }

    pub fn authoritative(self: *const PendingDisplayNavigationRestore) *const ReloadAnchor {
        return if (self.override) |*anchor| anchor else &self.original;
    }
};

pub const DeferredSourceApply = struct {
    finished: load.DiffLoadFinished,
    cycle_id: u64,

    pub fn deinit(self: *DeferredSourceApply, allocator: std.mem.Allocator) void {
        self.finished.result.deinit(allocator);
        self.* = undefined;
    }
};

/// Owns a projection completion which arrived while its displayed diff was
/// borrowed by a live mouse drag. Source completions are drained first because
/// they can advance the source session and make this result stale.
pub const DeferredProjectionApply = struct {
    finished: load.ReviewProjectionFinished,

    pub fn deinit(self: *DeferredProjectionApply, allocator: std.mem.Allocator) void {
        self.finished.deinit(allocator);
        self.* = undefined;
    }
};

pub const ReviewPageState = struct {
    activation: authority.Lifecycle = .{},
    status: app_state.StatusMessage = .{},
    load: load_state.LoadRuntimeState = .{},
    auto_reload: auto_reload.State = .{},
    deferred_source_apply: ?DeferredSourceApply = null,
    deferred_projection_apply: ?DeferredProjectionApply = null,
    viewer: ViewerState = .{},
    search: DiffSearchState = .{},
    file_search: file_search.State = .{},
    file_search_return_focus: Focus = .sidebar,
    review_display: app_state.ReviewDisplayState = .{},
    staged_hunks: app_state.StagedHunkMarks = .{},
    review_projection: review_projection.State = .{},
    review_projection_next_id: u64 = 0,
    source_session_revision: u64 = 0,
    /// Semantic generation of accepted sidebar rows. Zero is reserved as an
    /// invalid candidate basis, so the first accepted namespace starts at one.
    accepted_sidebar_revision: u64 = 1,
    status_snapshot_revision: u64 = 0,
    pending_display_navigation_restore: ?PendingDisplayNavigationRestore = null,
    display_navigation_input_revision: u64 = 0,
    git_status: git_status.GitStatusState = .{},
    status_load: auto_reload.AuxiliaryTracker = .{},
    pending_reload: ?PendingReload = null,
    branch_status: git_branch_status.State = .{},
    branch_status_load: auto_reload.AuxiliaryTracker = .{},
    pending_initial_first_visible_selection: bool = false,
    tree_order: file_tree.StableOrder = .{},
    tree_order_scope: ?[]u8 = null,
    action_cursor: action_cursor.State = .{},
    reviewed_store: review_state.Store = .{},
    selection_owner: diff_selection.Owner = .none,
    completed_selection: ?review_selection.CompletedSelection = null,

    pub fn init(
        self: *ReviewPageState,
        cli: diff_source.AutoReloadOverride,
        user: config.ReloadConfig,
        source: diff_source.SourceMode,
    ) void {
        self.auto_reload = .init(cli, user, source);
    }

    /// Invalidate every candidate borrow before the accepted sidebar owner is
    /// replaced, then open a new semantic namespace for later publication.
    /// Prompt mode and input intentionally survive so the replacement path can
    /// rebuild the same query after its primary model has committed.
    pub fn advanceAcceptedSidebarRevision(self: *ReviewPageState, allocator: ?std.mem.Allocator) void {
        if (allocator) |owner| {
            self.file_search.markProjectionUnavailable(owner);
        } else {
            std.debug.assert(!self.file_search.projection_available);
            std.debug.assert(self.file_search.candidates.len == 0);
            std.debug.assert(self.file_search.basis == null);
            std.debug.assert(self.file_search.filter.labels.len == 0);
        }
        self.accepted_sidebar_revision = file_search.nextAcceptedSidebarRevision(self.accepted_sidebar_revision);
    }

    pub fn deinit(self: *ReviewPageState, allocator: std.mem.Allocator) void {
        self.selection_owner = .none;
        if (self.completed_selection) |*selection| selection.deinit(allocator);
        if (self.deferred_source_apply) |*deferred| deferred.deinit(allocator);
        if (self.deferred_projection_apply) |*deferred| deferred.deinit(allocator);
        // File-search candidates borrow paths from the accepted load arena.
        // Release their containers before load teardown frees that owner.
        self.file_search.deinit(allocator);
        self.load.clearCurrent(allocator);
        self.git_status.deinit();
        self.branch_status.deinit();
        self.reviewed_store.deinit(allocator);
        self.staged_hunks.deinit(allocator);
        self.review_projection.deinit(allocator);
        self.tree_order.deinit(allocator);
        if (self.tree_order_scope) |scope| allocator.free(scope);
        self.action_cursor.deinit(allocator);
        if (self.pending_reload) |*pending| pending.deinit(allocator);
        if (self.pending_display_navigation_restore) |*restore| restore.deinit(allocator);
        self.* = .{};
    }
};

test "ReviewPageState initializes reload policy and owns lifecycle cleanup" {
    const allocator = std.testing.allocator;
    var state: ReviewPageState = .{};
    errdefer state.deinit(allocator);
    state.init(.inherit, .{}, .unstaged);
    try std.testing.expect(state.auto_reload.enabled());

    state.deferred_source_apply = .{
        .finished = .{
            .identity = page.RequestIdentity.review(0, 1),
            .generation = 5,
            .result = .{ .failed = try allocator.dupe(u8, "deferred failure") },
        },
        .cycle_id = 2,
    };
    state.tree_order_scope = try allocator.dupe(u8, "/repo");
    var prepared_cursor = try action_cursor.Prepared.init(
        allocator,
        2,
        .{ .device = 3, .inode = 5 },
        .file,
        "src/main.zig",
        3,
    );
    state.action_cursor.install(allocator, &prepared_cursor, 11);
    state.pending_reload = .{
        .generation = 7,
        .kind = .manual,
        .anchor = .{
            .path_key = try allocator.dupe(u8, "src/main.zig"),
            .selected_target_tag = .diff_file,
            .visible_sidebar_row = 3,
            .diff_cursor = .{ .metadata = 0 },
            .diff_cursor_offset = null,
            .diff_scroll = 0,
            .diff_horizontal_scroll = 0,
            .sidebar_horizontal_scroll = 0,
            .search_coordinate = null,
        },
    };
    state.pending_display_navigation_restore = .{
        .repo_root = try allocator.dupe(u8, "/repo"),
        .source_kind = .unstaged,
        .source_session_revision = 11,
        .original = .{
            .path_key = try allocator.dupe(u8, "src/original.zig"),
            .selected_target_tag = .diff_file,
            .visible_sidebar_row = 4,
            .diff_cursor = .{ .metadata = 0 },
            .diff_cursor_offset = null,
            .diff_scroll = 1,
            .diff_horizontal_scroll = 2,
            .sidebar_horizontal_scroll = 3,
            .search_coordinate = null,
        },
        .override = .{
            .path_key = try allocator.dupe(u8, "src/override.zig"),
            .selected_target_tag = .diff_file,
            .visible_sidebar_row = 5,
            .diff_cursor = .{ .metadata = 0 },
            .diff_cursor_offset = null,
            .diff_scroll = 4,
            .diff_horizontal_scroll = 5,
            .sidebar_horizontal_scroll = 6,
            .search_coordinate = null,
        },
        .captured_input_revision = 12,
    };

    state.deinit(allocator);
    state.deinit(allocator);

    try std.testing.expectEqual(Focus.sidebar, state.viewer.focus);
    try std.testing.expect(state.deferred_source_apply == null);
    try std.testing.expect(state.tree_order_scope == null);
    try std.testing.expect(!state.action_cursor.hasOwner());
    try std.testing.expect(state.pending_reload == null);
    try std.testing.expect(state.pending_display_navigation_restore == null);
}

test "ReviewPageState deinit releases loaded snapshots and file filter" {
    const allocator = std.testing.allocator;
    var state: ReviewPageState = .{};
    errdefer state.deinit(allocator);

    try state.load.replaceFailed(allocator, "load failure");

    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "?? src/new.zig\x00");
    errdefer status_bundle.deinit();
    try state.git_status.replace("/repo", &status_bundle);

    var branch_builder = git_branch_status.Builder.init(allocator);
    errdefer branch_builder.deinit();
    try branch_builder.setOid("abc123");
    try branch_builder.setBranchHead("main");
    try branch_builder.setUpstream("origin/main");
    var branch_bundle = branch_builder.finish();
    errdefer branch_bundle.deinit();
    try state.branch_status.replace("/repo", &branch_bundle);

    const labels = [_][]const u8{ "src/main.zig", "src/other.zig" };
    try state.file_search.filter.apply(allocator, &labels, "main");

    state.deinit(allocator);
    state.deinit(allocator);

    try std.testing.expectEqual(load_state.LoadState.idle, state.load.state);
    try std.testing.expect(state.git_status.repo_root == null);
    try std.testing.expect(state.branch_status.repo_root == null);
    try std.testing.expectEqual(@as(usize, 0), state.file_search.filter.labels.len);
}

test "ReviewPageState deinit releases stores projection and stable order" {
    const allocator = std.testing.allocator;
    var state: ReviewPageState = .{};
    errdefer state.deinit(allocator);

    const reviewed_key = try allocator.dupe(u8, "/repo\x00src/main.zig");
    state.reviewed_store.entries.put(allocator, reviewed_key, {}) catch |err| {
        allocator.free(reviewed_key);
        return err;
    };

    try state.staged_hunks.add(allocator, "/repo", "src/main.zig", 2);

    const order_key = try allocator.dupe(u8, "src/main.zig");
    state.tree_order.keys.append(allocator, order_key) catch |err| {
        allocator.free(order_key);
        return err;
    };

    state.review_projection.pending = try review_projection.cloneRequest(
        allocator,
        page.RequestIdentity.review(0, 1),
        1,
        "/repo",
        "src/pending.zig",
        .cached_diff,
        .unstaged,
        3,
        4,
    );
    var displayed_request = try review_projection.cloneRequest(
        allocator,
        page.RequestIdentity.review(0, 1),
        2,
        "/repo",
        "src/displayed.zig",
        .generated_added_file,
        .unstaged,
        3,
        4,
    );
    var displayed_request_owned = true;
    errdefer if (displayed_request_owned) displayed_request.deinit(allocator);
    var displayed_body = try review_projection.statusBodyAlloc(
        allocator,
        "src/displayed.zig",
        "projection failed",
        .{},
    );
    var displayed_body_owned = true;
    errdefer if (displayed_body_owned) displayed_body.deinit(allocator);
    state.review_projection.displayed = .{ .failed = .{
        .request = displayed_request,
        .body = displayed_body,
    } };
    displayed_request_owned = false;
    displayed_body_owned = false;

    state.deinit(allocator);
    state.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), state.reviewed_store.entries.count());
    try std.testing.expectEqual(@as(usize, 0), state.staged_hunks.items.items.len);
    try std.testing.expect(!state.review_projection.hasPending());
    try std.testing.expect(!state.review_projection.hasDisplayed());
    try std.testing.expectEqual(@as(usize, 0), state.tree_order.keys.items.len);
}
