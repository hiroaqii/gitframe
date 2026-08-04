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
pub const repository_read_authority = @import("review/repository_read_authority.zig");
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
const diff_surface = @import("../diff_surface.zig");

pub const Focus = diff_surface.Focus;
pub const ViewOptions = diff_surface.ViewOptions;
pub const ViewerState = diff_surface.ViewerState;
pub const DiffSearchState = diff_surface.DiffSearchState;
pub const ReloadAnchor = diff_surface.ReloadAnchor;

pub const ReloadKind = enum {
    initial,
    manual,
    watch,
    action_result,
    repo_switch,
};

pub const PendingReload = struct {
    generation: u64,
    read_epoch: repository_read_authority.ReviewRepositoryReadEpoch = .{},
    kind: ReloadKind,
    anchor: ?ReloadAnchor = null,

    pub fn matchesTerminal(
        self: PendingReload,
        generation: u64,
        read_epoch: repository_read_authority.ReviewRepositoryReadEpoch,
    ) bool {
        return self.generation == generation and self.read_epoch.eql(read_epoch);
    }

    pub fn deinit(self: *PendingReload, allocator: std.mem.Allocator) void {
        if (self.anchor) |*anchor| anchor.deinit(allocator);
        self.* = undefined;
    }
};

test "pending reload matches only its exact read terminal" {
    const pending: PendingReload = .{
        .generation = 7,
        .read_epoch = .{ .value = 13 },
        .kind = .watch,
    };

    try std.testing.expect(pending.matchesTerminal(7, .{ .value = 13 }));
    try std.testing.expect(!pending.matchesTerminal(8, .{ .value = 13 }));
    try std.testing.expect(!pending.matchesTerminal(7, .{ .value = 14 }));
}

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

const CanonicalPublicationPhase = enum {
    waiting_members,
    waiting_projection,
    committing,
    aborting,
};

const CanonicalStatusCandidate = union(enum) {
    pending,
    identical,
    replacement: git_status.GitStatusState,

    pub fn deinit(self: *CanonicalStatusCandidate) void {
        switch (self.*) {
            .replacement => |*status| status.deinit(),
            .pending, .identical => {},
        }
        self.* = .pending;
    }

    pub fn ready(self: CanonicalStatusCandidate) bool {
        return switch (self) {
            .pending => false,
            .identical, .replacement => true,
        };
    }

    pub fn changesSnapshot(self: CanonicalStatusCandidate) bool {
        return switch (self) {
            .replacement => true,
            .pending, .identical => false,
        };
    }

    pub fn takeReplacement(self: *CanonicalStatusCandidate) ?git_status.GitStatusState {
        return switch (self.*) {
            .replacement => |status| blk: {
                self.* = .pending;
                break :blk status;
            },
            .pending, .identical => null,
        };
    }
};

/// Private transaction metadata for a refresh which must retain the current
/// canonical Review body until source, status, and projection agree.
///
/// The source task payload remains single-owned by `deferred_source_apply`;
/// this gate owns only its exact identity plus the accepted status candidate.
const CanonicalPublicationGate = struct {
    identity: page.RequestIdentity,
    read_epoch: repository_read_authority.ReviewRepositoryReadEpoch,
    source_generation: u64,
    kind: ReloadKind,
    repo_root: []u8,
    path_key: []u8,
    phase: CanonicalPublicationPhase = .waiting_members,
    status_generation: ?u64 = null,
    status_read_epoch: repository_read_authority.ReviewRepositoryReadEpoch = .{},
    status_background_cycle_id: ?u64 = null,
    status: CanonicalStatusCandidate = .pending,
    projection_request_id: ?u64 = null,

    pub fn deinit(self: *CanonicalPublicationGate, allocator: std.mem.Allocator) void {
        self.status.deinit();
        allocator.free(self.repo_root);
        allocator.free(self.path_key);
        self.* = undefined;
    }
};

const DeferredSourceMode = enum {
    live_drag,
    canonical_publication,
};

pub const DeferredSourceApply = struct {
    finished: load.DiffLoadFinished,
    cycle_id: u64,
    mode: DeferredSourceMode = .live_drag,

    pub fn deinit(self: *DeferredSourceApply, allocator: std.mem.Allocator) void {
        self.finished.result.deinit(allocator);
        self.* = undefined;
    }
};

/// Owns a projection completion which arrived while its displayed diff was
/// borrowed by a live mouse drag. Source completions are drained first because
/// they can advance the source session and make this result stale. The complete
/// request remains the single read-epoch owner while deferred; do not mirror a
/// second scalar here which could diverge from the task result provenance.
pub const DeferredProjectionApply = struct {
    finished: load.ReviewProjectionFinished,

    pub fn deinit(self: *DeferredProjectionApply, allocator: std.mem.Allocator) void {
        self.finished.deinit(allocator);
        self.* = undefined;
    }
};

pub const ReviewPageState = struct {
    activation: authority.Lifecycle = .init(.review),
    repository_read_authority: repository_read_authority.ReviewRepositoryReadAuthority = .{},
    status: app_state.StatusMessage = .{},
    load: load_state.LoadRuntimeState = .{},
    auto_reload: auto_reload.State = .{},
    deferred_source_apply: ?DeferredSourceApply = null,
    deferred_projection_apply: ?DeferredProjectionApply = null,
    canonical_publication: ?CanonicalPublicationGate = null,
    canonical_status_drain: ?auto_reload.AuxiliaryTerminal = null,
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

    /// Only an ordinary source completion deferred behind a live drag borrows
    /// display state strongly enough to block a page transition. Canonical
    /// publication owns no live pointer borrow and is retired by the Review
    /// owner when an allowed page exit commits.
    pub fn deferredSourceBlocksPageTransition(self: *const ReviewPageState) bool {
        const deferred = self.deferred_source_apply orelse return false;
        return deferred.mode == .live_drag;
    }

    /// Invalidate every candidate borrow before the accepted sidebar owner is
    /// replaced, then open a new semantic namespace for later publication.
    /// Prompt mode and input intentionally survive so the replacement path can
    /// rebuild the same query after its primary model has committed.
    pub fn advanceAcceptedSidebarRevision(self: *ReviewPageState, allocator: ?std.mem.Allocator) void {
        file_search.advanceAcceptedSidebarRevision(
            &self.file_search,
            &self.accepted_sidebar_revision,
            allocator,
        );
    }

    pub fn deinit(self: *ReviewPageState, allocator: std.mem.Allocator) void {
        self.selection_owner = .none;
        if (self.completed_selection) |*selection| selection.deinit(allocator);
        if (self.deferred_source_apply) |*deferred| deferred.deinit(allocator);
        if (self.deferred_projection_apply) |*deferred| deferred.deinit(allocator);
        if (self.canonical_publication) |*gate| gate.deinit(allocator);
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

    /// Builds the page-independent read-only surface view over this page's
    /// shared fields. The bundle is a short-lived borrow for the current
    /// update/render call; nothing may retain it across a state mutation.
    pub fn diffSurface(
        self: *ReviewPageState,
        source: diff_source.SourceMode,
        layout: diff_surface.Layout,
    ) diff_surface.DiffSurface {
        return .{
            .activation = &self.activation,
            .status = &self.status,
            .load = &self.load,
            .viewer = &self.viewer,
            .search = &self.search,
            .file_search = &self.file_search,
            .file_search_return_focus = &self.file_search_return_focus,
            .accepted_sidebar_revision = &self.accepted_sidebar_revision,
            .review_display = &self.review_display,
            .reviewed_store = &self.reviewed_store,
            .tree_order = &self.tree_order,
            .tree_order_scope = &self.tree_order_scope,
            .selection_owner = &self.selection_owner,
            .completed_selection = &self.completed_selection,
            .source_session_revision = &self.source_session_revision,
            .pending_initial_first_visible_selection = &self.pending_initial_first_visible_selection,
            .reload_anchor = if (self.pending_reload) |*pending|
                (if (pending.anchor) |*anchor| anchor else null)
            else
                null,
            .live_drag_deferred_source = self.deferredSourceBlocksPageTransition(),
            .source = source,
            .layout = layout,
        };
    }

    /// Builds the const-qualified projection used by shared read-only views.
    pub fn readSurface(
        self: *const ReviewPageState,
        source: diff_source.SourceMode,
        layout: diff_surface.Layout,
    ) diff_surface.ReadSurface {
        return .{
            .activation = &self.activation,
            .status = &self.status,
            .load = &self.load,
            .viewer = &self.viewer,
            .search = &self.search,
            .file_search = &self.file_search,
            .file_search_return_focus = &self.file_search_return_focus,
            .accepted_sidebar_revision = &self.accepted_sidebar_revision,
            .review_display = &self.review_display,
            .reviewed_store = &self.reviewed_store,
            .tree_order = &self.tree_order,
            .tree_order_scope = &self.tree_order_scope,
            .selection_owner = &self.selection_owner,
            .completed_selection = &self.completed_selection,
            .source_session_revision = &self.source_session_revision,
            .pending_initial_first_visible_selection = &self.pending_initial_first_visible_selection,
            .reload_anchor = if (self.pending_reload) |*pending|
                (if (pending.anchor) |*anchor| anchor else null)
            else
                null,
            .live_drag_deferred_source = self.deferredSourceBlocksPageTransition(),
            .source = source,
            .layout = layout,
        };
    }
};

test "diffSurface adapter exposes shared field pointers without copying" {
    const allocator = std.testing.allocator;
    var state: ReviewPageState = .{};
    defer state.deinit(allocator);

    var surface = state.diffSurface(.unstaged, .{ .width = 80, .height = 24 });
    try std.testing.expectEqual(&state.activation, surface.activation);
    try std.testing.expectEqual(&state.status, surface.status);
    try std.testing.expectEqual(&state.load, surface.load);
    try std.testing.expectEqual(&state.viewer, surface.viewer);
    try std.testing.expectEqual(&state.search, surface.search);
    try std.testing.expectEqual(&state.file_search, surface.file_search);
    try std.testing.expectEqual(&state.file_search_return_focus, surface.file_search_return_focus);
    try std.testing.expectEqual(&state.accepted_sidebar_revision, surface.accepted_sidebar_revision);
    try std.testing.expectEqual(&state.review_display, surface.review_display);
    try std.testing.expectEqual(&state.reviewed_store, surface.reviewed_store);
    try std.testing.expectEqual(&state.tree_order, surface.tree_order);
    try std.testing.expectEqual(&state.tree_order_scope, surface.tree_order_scope);
    try std.testing.expectEqual(&state.selection_owner, surface.selection_owner);
    try std.testing.expectEqual(&state.completed_selection, surface.completed_selection);
    try std.testing.expectEqual(&state.source_session_revision, surface.source_session_revision);
    try std.testing.expectEqual(&state.pending_initial_first_visible_selection, surface.pending_initial_first_visible_selection);
    try std.testing.expect(surface.reload_anchor == null);
    try std.testing.expect(!surface.live_drag_deferred_source);
    try std.testing.expectEqual(diff_source.SourceMode.unstaged, surface.source);
    try std.testing.expectEqual(diff_surface.Layout{ .width = 80, .height = 24 }, surface.layout);

    const const_state: *const ReviewPageState = &state;
    const read_surface = const_state.readSurface(.cached, .{ .width = 96, .height = 31 });
    try std.testing.expectEqual(&state.activation, read_surface.activation);
    try std.testing.expectEqual(&state.status, read_surface.status);
    try std.testing.expectEqual(&state.load, read_surface.load);
    try std.testing.expectEqual(&state.viewer, read_surface.viewer);
    try std.testing.expectEqual(&state.search, read_surface.search);
    try std.testing.expectEqual(&state.file_search, read_surface.file_search);
    try std.testing.expectEqual(&state.file_search_return_focus, read_surface.file_search_return_focus);
    try std.testing.expectEqual(&state.accepted_sidebar_revision, read_surface.accepted_sidebar_revision);
    try std.testing.expectEqual(&state.review_display, read_surface.review_display);
    try std.testing.expectEqual(&state.reviewed_store, read_surface.reviewed_store);
    try std.testing.expectEqual(&state.tree_order, read_surface.tree_order);
    try std.testing.expectEqual(&state.tree_order_scope, read_surface.tree_order_scope);
    try std.testing.expectEqual(&state.selection_owner, read_surface.selection_owner);
    try std.testing.expectEqual(&state.completed_selection, read_surface.completed_selection);
    try std.testing.expectEqual(&state.source_session_revision, read_surface.source_session_revision);
    try std.testing.expectEqual(&state.pending_initial_first_visible_selection, read_surface.pending_initial_first_visible_selection);
    try std.testing.expect(read_surface.reload_anchor == null);
    try std.testing.expect(!read_surface.live_drag_deferred_source);
    try std.testing.expectEqual(diff_source.SourceMode.cached, read_surface.source);
    try std.testing.expectEqual(diff_surface.Layout{ .width = 96, .height = 31 }, read_surface.layout);

    const narrowed = surface.readOnly();
    try std.testing.expectEqual(surface.activation, narrowed.activation);
    try std.testing.expectEqual(surface.status, narrowed.status);
    try std.testing.expectEqual(surface.load, narrowed.load);
    try std.testing.expectEqual(surface.viewer, narrowed.viewer);
    try std.testing.expectEqual(surface.search, narrowed.search);
    try std.testing.expectEqual(surface.file_search, narrowed.file_search);
    try std.testing.expectEqual(surface.file_search_return_focus, narrowed.file_search_return_focus);
    try std.testing.expectEqual(surface.accepted_sidebar_revision, narrowed.accepted_sidebar_revision);
    try std.testing.expectEqual(surface.review_display, narrowed.review_display);
    try std.testing.expectEqual(surface.reviewed_store, narrowed.reviewed_store);
    try std.testing.expectEqual(surface.tree_order, narrowed.tree_order);
    try std.testing.expectEqual(surface.tree_order_scope, narrowed.tree_order_scope);
    try std.testing.expectEqual(surface.selection_owner, narrowed.selection_owner);
    try std.testing.expectEqual(surface.completed_selection, narrowed.completed_selection);
    try std.testing.expectEqual(surface.source_session_revision, narrowed.source_session_revision);
    try std.testing.expectEqual(surface.pending_initial_first_visible_selection, narrowed.pending_initial_first_visible_selection);
    try std.testing.expectEqual(surface.reload_anchor, narrowed.reload_anchor);
    try std.testing.expectEqual(surface.live_drag_deferred_source, narrowed.live_drag_deferred_source);
    try std.testing.expectEqual(surface.source, narrowed.source);
    try std.testing.expectEqual(surface.layout, narrowed.layout);

    surface.viewer.diff_scroll = 7;
    try std.testing.expectEqual(@as(usize, 7), state.viewer.diff_scroll);

    state.pending_reload = .{
        .generation = 1,
        .kind = .manual,
        .anchor = .{
            .path_key = try allocator.dupe(u8, "src/main.zig"),
            .sidebar_identity = .repo_root,
            .selected_target_tag = .diff_file,
            .visible_sidebar_row = 0,
            .diff_cursor = .{ .metadata = 0 },
            .diff_cursor_offset = null,
            .diff_scroll = 0,
            .diff_horizontal_scroll = 0,
            .sidebar_horizontal_scroll = 0,
            .search_coordinate = null,
        },
    };
    state.deferred_source_apply = .{
        .finished = .{
            .identity = page.RequestIdentity.review(0, 1),
            .generation = 2,
            .result = .{ .failed_static = "surface test terminal" },
        },
        .cycle_id = 1,
    };

    const resolved = state.diffSurface(.unstaged, .{ .width = 80, .height = 24 });
    try std.testing.expect(resolved.reload_anchor != null);
    try std.testing.expectEqualStrings("src/main.zig", resolved.reload_anchor.?.path_key);
    try std.testing.expect(resolved.live_drag_deferred_source);
}

test "ReviewPageState initializes reload policy and owns lifecycle cleanup" {
    const allocator = std.testing.allocator;
    var state: ReviewPageState = .{};
    errdefer state.deinit(allocator);
    state.init(.inherit, .{}, .unstaged);
    try std.testing.expect(state.auto_reload.enabled());
    try std.testing.expect(state.repository_read_authority.mayStartRepositoryRead());

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
            .sidebar_identity = .{ .file = try allocator.dupe(u8, "src/main.zig") },
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
            .sidebar_identity = .{ .file = try allocator.dupe(u8, "src/original.zig") },
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
            .sidebar_identity = .{ .file = try allocator.dupe(u8, "src/override.zig") },
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

test "Review canonical publication page transition distinguishes live drag from canonical deferred source" {
    const allocator = std.testing.allocator;
    var state: ReviewPageState = .{};
    defer state.deinit(allocator);
    state.deferred_source_apply = .{
        .finished = .{
            .identity = page.RequestIdentity.review(0, 1),
            .generation = 5,
            .result = .{ .failed_static = "test terminal" },
        },
        .cycle_id = 2,
    };

    try std.testing.expect(state.deferredSourceBlocksPageTransition());
    state.deferred_source_apply.?.mode = .canonical_publication;
    try std.testing.expect(!state.deferredSourceBlocksPageTransition());
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

    try state.staged_hunks.addExact(allocator, "/repo", "src/main.zig", .{
        .content = .{
            .repo_epoch = 1,
            .root_identity = null,
            .source = review_selection.SourceBasis.init(.unstaged),
            .source_session_revision = 1,
            .display = .{ .loaded = .init("diff") },
        },
        .display_hunk_index = 2,
    });

    const order_key = try allocator.dupe(u8, "src/main.zig");
    state.tree_order.keys.append(allocator, order_key) catch |err| {
        allocator.free(order_key);
        return err;
    };

    state.review_projection.pending = try review_projection.testing.cloneRequest(
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
    var displayed_request = try review_projection.testing.cloneRequest(
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
