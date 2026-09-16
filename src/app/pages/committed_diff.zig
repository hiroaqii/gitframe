//! Shared retained state for read-only committed-diff pages.
//!
//! History, Compare, and AI Reviews own independent activation, selection or
//! target, request, modal, and diagnostics. This component owns only the diff
//! interaction state whose contract is identical for those pages.

const std = @import("std");
const content_fingerprint = @import("../../content_fingerprint.zig");
const app_state = @import("../state.zig");
const diff_surface = @import("../diff_surface.zig");
const load_state = @import("../load_state.zig");
const app_load = @import("../load.zig");
const committed_review = @import("../../committed_review.zig");
const git_committed_review = @import("../../git/committed_review.zig");
const diff_selection = @import("../../diff/selection.zig");
const diff_source = @import("../../diff/source.zig");
const file_tree = @import("../../file_tree.zig");
const reviewed_files = @import("../../reviewed_files.zig");
const root_capability = @import("../../repo/root_capability.zig");

pub const AcceptedRepositoryIdentity = struct {
    repo_epoch: u64,
    root_identity: ?root_capability.Identity,

    pub fn matches(
        self: AcceptedRepositoryIdentity,
        repo_epoch: u64,
        root_identity: ?root_capability.Identity,
    ) bool {
        return self.repo_epoch == repo_epoch and optionalRootIdentityEql(self.root_identity, root_identity);
    }
};

/// Page-local presentation identity used only to admit retained selection
/// actions for the exact committed diff still on screen. This is deliberately
/// not a durable review target: Compare keeps its review target, while History
/// pins the already-resolved direct endpoint basis.
pub const PresentationIdentity = union(enum) {
    review_target: committed_review.CommittedReviewTarget,
    diff_basis: git_committed_review.CommittedDiffBasis,

    pub fn eql(self: PresentationIdentity, other: PresentationIdentity) bool {
        return switch (self) {
            .review_target => |target| switch (other) {
                .review_target => |candidate| target.eql(&candidate),
                .diff_basis => false,
            },
            .diff_basis => |basis| switch (other) {
                .review_target => false,
                .diff_basis => |candidate| std.meta.eql(basis, candidate),
            },
        };
    }
};

pub const PinnedSelectionBasis = struct {
    identity: PresentationIdentity,

    pub fn init(target: committed_review.CommittedReviewTarget) PinnedSelectionBasis {
        return .{ .identity = .{ .review_target = target } };
    }

    pub fn initIdentity(identity: PresentationIdentity) PinnedSelectionBasis {
        return .{ .identity = identity };
    }

    pub fn eql(self: PinnedSelectionBasis, other: PinnedSelectionBasis) bool {
        return self.identity.eql(other.identity);
    }
};

pub const SurfaceOwner = struct {
    activation: *diff_surface.authority.Lifecycle,
    status: *app_state.StatusMessage,
    source: diff_source.SourceMode,
    layout: diff_surface.Layout,
    current_target: ?committed_review.CommittedReviewTarget,
    presentation_identity: ?PresentationIdentity = null,
    live_drag_deferred_source: bool,

    fn currentPresentation(self: SurfaceOwner) ?PresentationIdentity {
        return self.presentation_identity orelse if (self.current_target) |target|
            PresentationIdentity{ .review_target = target }
        else
            null;
    }
};

pub const ReadSurfaceOwner = struct {
    activation: *const diff_surface.authority.Lifecycle,
    status: *const app_state.StatusMessage,
    source: diff_source.SourceMode,
    layout: diff_surface.Layout,
    current_target: ?committed_review.CommittedReviewTarget,
    presentation_identity: ?PresentationIdentity = null,
    live_drag_deferred_source: bool,

    fn currentPresentation(self: ReadSurfaceOwner) ?PresentationIdentity {
        return self.presentation_identity orelse if (self.current_target) |target|
            PresentationIdentity{ .review_target = target }
        else
            null;
    }
};

pub const State = struct {
    load: load_state.LoadRuntimeState = .{},
    viewer: diff_surface.ViewerState = .{},
    search: diff_surface.DiffSearchState = .{},
    file_search: diff_surface.file_search.State = .{},
    file_search_return_focus: diff_surface.Focus = .sidebar,
    accepted_sidebar_revision: u64 = 1,
    review_display: app_state.ReviewDisplayState = .{},
    reviewed_store: reviewed_files.Store = .{},
    tree_order: file_tree.StableOrder = .{},
    tree_order_scope: ?[]u8 = null,
    selection_owner: diff_selection.Owner = .none,
    completed_selection: ?diff_surface.selection.CompletedSelection = null,
    selection_generation: u64 = 0,
    source_session_revision: u64 = 0,
    pending_initial_first_visible_selection: bool = false,
    selection_layout_revision: u64 = 1,
    pinned_selection_basis: ?PinnedSelectionBasis = null,
    accepted_repository_identity: ?AcceptedRepositoryIdentity = null,
    reload_anchor: ?diff_surface.ReloadAnchor = null,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.selection_owner = .none;
        if (self.completed_selection) |*selection| selection.deinit(allocator);
        self.file_search.deinit(allocator);
        self.load.clearCurrent(allocator);
        self.reviewed_store.deinit(allocator);
        self.tree_order.deinit(allocator);
        if (self.tree_order_scope) |scope| allocator.free(scope);
        if (self.reload_anchor) |*anchor| anchor.deinit(allocator);
        self.* = .{};
    }

    pub fn advanceSelectionLayoutRevision(self: *State) void {
        self.selection_layout_revision +%= 1;
        if (self.selection_layout_revision == 0) self.selection_layout_revision = 1;
    }

    pub fn clearRetainedSelection(self: *State, allocator: std.mem.Allocator) void {
        if (self.completed_selection) |*selection| selection.deinit(allocator);
        self.completed_selection = null;
        self.pinned_selection_basis = null;
        self.selection_owner = .none;
    }

    pub fn retainedSelectionInstallAvailable(
        self: *const State,
        current_target: ?committed_review.CommittedReviewTarget,
    ) bool {
        return self.retainedSelectionInstallAvailableWithIdentity(if (current_target) |target|
            .{ .review_target = target }
        else
            null);
    }

    pub fn retainedSelectionInstallAvailableWithIdentity(
        self: *const State,
        current_identity: ?PresentationIdentity,
    ) bool {
        return current_identity != null and self.load.state == .loaded;
    }

    pub fn retainedSelectionAdmitted(
        self: *const State,
        current_target: ?committed_review.CommittedReviewTarget,
    ) bool {
        return self.retainedSelectionAdmittedWithIdentity(if (current_target) |target|
            .{ .review_target = target }
        else
            null);
    }

    pub fn retainedSelectionAdmittedWithIdentity(
        self: *const State,
        current_identity: ?PresentationIdentity,
    ) bool {
        const pinned = self.pinned_selection_basis orelse return false;
        const current = current_identity orelse return false;
        return pinned.eql(.initIdentity(current));
    }

    pub fn installPinnedPresentationIdentity(
        self: *State,
        current_identity: ?PresentationIdentity,
    ) bool {
        const identity = current_identity orelse return false;
        self.pinned_selection_basis = .initIdentity(identity);
        return true;
    }

    pub fn installPinnedSelectionBasis(
        self: *State,
        current_target: ?committed_review.CommittedReviewTarget,
    ) bool {
        return self.installPinnedPresentationIdentity(if (current_target) |target|
            .{ .review_target = target }
        else
            null);
    }

    pub fn takeReloadAnchor(self: *State) ?diff_surface.ReloadAnchor {
        const anchor = self.reload_anchor;
        self.reload_anchor = null;
        return anchor;
    }

    pub fn replaceReloadAnchor(
        self: *State,
        allocator: std.mem.Allocator,
        anchor: ?diff_surface.ReloadAnchor,
    ) void {
        if (self.reload_anchor) |*old| old.deinit(allocator);
        self.reload_anchor = anchor;
    }

    pub fn clearReloadAnchor(self: *State, allocator: std.mem.Allocator) void {
        if (self.reload_anchor) |*anchor| anchor.deinit(allocator);
        self.reload_anchor = null;
    }

    pub fn hasAcceptedDiff(self: *const State) bool {
        return switch (self.load.state) {
            .loaded, .empty => true,
            .idle, .loading, .failed => false,
        };
    }

    pub fn resetAcceptedDisplayNavigation(self: *State) void {
        self.viewer.diff_scroll = 0;
        self.viewer.diff_horizontal_scroll = 0;
        self.viewer.sidebar_horizontal_scroll = 0;
        self.viewer.diff_cursor = .{ .metadata = 0 };
        self.search.match = null;
        self.search.match_offset = null;
    }

    pub fn retainedSelectionTransfers(
        self: *const State,
        repo_epoch: u64,
        root_identity: ?root_capability.Identity,
        source: diff_source.SourceMode,
        current_target: ?committed_review.CommittedReviewTarget,
        incoming_target: committed_review.CommittedReviewTarget,
        incoming_diff: *const app_load.CommittedDiffBundle,
    ) bool {
        return self.retainedSelectionTransfersWithIdentity(
            repo_epoch,
            root_identity,
            source,
            if (current_target) |target| .{ .review_target = target } else null,
            .{ .review_target = incoming_target },
            incoming_diff,
        );
    }

    pub fn retainedSelectionTransfersWithIdentity(
        self: *const State,
        repo_epoch: u64,
        root_identity: ?root_capability.Identity,
        source: diff_source.SourceMode,
        current_identity: ?PresentationIdentity,
        incoming_identity: PresentationIdentity,
        incoming_diff: *const app_load.CommittedDiffBundle,
    ) bool {
        const completed = self.completed_selection orelse return false;
        const pinned = self.pinned_selection_basis orelse return false;
        const current = current_identity orelse return false;
        if (!pinned.eql(.initIdentity(current)) or !pinned.eql(.initIdentity(incoming_identity))) return false;
        if (completed.token.repo_epoch != repo_epoch or
            !optionalRootIdentityEql(completed.token.root_identity, root_identity) or
            !completed.token.source.eql(diff_surface.selection.SourceBasis.init(source)) or
            completed.token.source_session_revision != self.source_session_revision) return false;
        const current_loaded = switch (self.load.state) {
            .loaded => |session| &session.loaded,
            else => return false,
        };
        const incoming_loaded = switch (incoming_diff.*) {
            .loaded => |bundle| &bundle.loaded,
            .empty => return false,
        };
        const outgoing_fingerprint = content_fingerprint.Fingerprint.init(current_loaded.text);
        const incoming_fingerprint = content_fingerprint.Fingerprint.init(incoming_loaded.text);
        return switch (completed.token.display) {
            .loaded => |fingerprint| fingerprint.eql(outgoing_fingerprint) and fingerprint.eql(incoming_fingerprint),
            else => false,
        };
    }

    /// Prepare the complete replacement before releasing the current snapshot,
    /// then publish all shared diff state without a partial ownership terminal.
    pub fn replaceDiff(
        self: *State,
        allocator: std.mem.Allocator,
        repo_epoch: u64,
        repo_root: ?[]const u8,
        root_identity: ?root_capability.Identity,
        source: diff_source.SourceMode,
        current_target: committed_review.CommittedReviewTarget,
        pair_changed: bool,
        transfer_selection: bool,
        incoming: *app_load.CommittedDiffBundle,
    ) !void {
        return self.replaceDiffWithIdentity(
            allocator,
            repo_epoch,
            repo_root,
            root_identity,
            source,
            .{ .review_target = current_target },
            pair_changed,
            transfer_selection,
            incoming,
        );
    }

    pub fn replaceDiffWithIdentity(
        self: *State,
        allocator: std.mem.Allocator,
        repo_epoch: u64,
        repo_root: ?[]const u8,
        root_identity: ?root_capability.Identity,
        source: diff_source.SourceMode,
        current_identity: PresentationIdentity,
        pair_changed: bool,
        transfer_selection: bool,
        incoming: *app_load.CommittedDiffBundle,
    ) !void {
        var prepared_session: ?load_state.LoadedSession = null;
        switch (incoming.*) {
            .empty => {},
            .loaded => |*bundle| {
                const arena_allocator = bundle.arena.?.allocator();
                if (repo_root) |root| {
                    bundle.loaded.tree = try file_tree.buildWithOptions(
                        arena_allocator,
                        bundle.loaded.document,
                        null,
                        .{ .root = .{ .name = std.fs.path.basename(root) } },
                    );
                }
                const reviewed = try arena_allocator.alloc(bool, bundle.loaded.document.files.len);
                for (bundle.loaded.document.files, 0..) |file, index| {
                    reviewed[index] = if (pair_changed)
                        false
                    else
                        try self.reviewed_store.containsFile(allocator, repo_root, file);
                }
                bundle.loaded.reviewed_files = reviewed;
                try bundle.loaded.rebuildVisibleNodes(
                    arena_allocator,
                    self.review_display.hide_reviewed_files,
                    self.review_display.changed_file_filter,
                );
                prepared_session = .{
                    .arena = bundle.takeArena(),
                    .loaded = bundle.loaded,
                };
            },
        }
        errdefer if (prepared_session) |*session| session.deinit(null);

        self.file_search.deinit(allocator);
        if (!transfer_selection) self.clearRetainedSelection(allocator);
        self.selection_owner = .none;
        if (pair_changed) {
            self.reviewed_store.deinit(allocator);
            self.tree_order.reset(allocator);
        }
        self.load.clearCurrent(allocator);
        if (prepared_session) |session| {
            self.load.state = .{ .loaded = session };
            prepared_session = null;
        } else {
            self.load.state = .{ .empty = .no_changes };
            self.resetAcceptedDisplayNavigation();
        }
        self.source_session_revision +%= 1;
        if (transfer_selection) {
            const loaded = switch (self.load.state) {
                .loaded => |*session| &session.loaded,
                else => unreachable,
            };
            self.completed_selection.?.token = .{
                .repo_epoch = repo_epoch,
                .root_identity = root_identity,
                .source = diff_surface.selection.SourceBasis.init(source),
                .source_session_revision = self.source_session_revision,
                .display = .{ .loaded = content_fingerprint.Fingerprint.init(loaded.text) },
            };
            self.pinned_selection_basis = .initIdentity(current_identity);
        }
        self.accepted_repository_identity = .{
            .repo_epoch = repo_epoch,
            .root_identity = root_identity,
        };
    }

    pub fn diffSurface(self: *State, owner: SurfaceOwner) diff_surface.DiffSurface {
        const presentation = owner.currentPresentation();
        return .{
            .activation = owner.activation,
            .status = owner.status,
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
            .selection_generation = &self.selection_generation,
            .source_session_revision = &self.source_session_revision,
            .pending_initial_first_visible_selection = &self.pending_initial_first_visible_selection,
            .selection_layout_revision = &self.selection_layout_revision,
            .reload_anchor = if (self.reload_anchor) |*anchor| anchor else null,
            .live_drag_deferred_source = owner.live_drag_deferred_source,
            .selection_completion_policy = .retain_with_actions,
            .retained_selection_install_available = self.retainedSelectionInstallAvailableWithIdentity(presentation),
            .retained_selection_action_admitted = self.retainedSelectionAdmittedWithIdentity(presentation),
            .source = owner.source,
            .layout = owner.layout,
        };
    }

    pub fn readSurface(self: *const State, owner: ReadSurfaceOwner) diff_surface.ReadSurface {
        const presentation = owner.currentPresentation();
        return .{
            .activation = owner.activation,
            .status = owner.status,
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
            .selection_generation = &self.selection_generation,
            .source_session_revision = &self.source_session_revision,
            .pending_initial_first_visible_selection = &self.pending_initial_first_visible_selection,
            .selection_layout_revision = &self.selection_layout_revision,
            .reload_anchor = if (self.reload_anchor) |*anchor| anchor else null,
            .live_drag_deferred_source = owner.live_drag_deferred_source,
            .selection_completion_policy = .retain_with_actions,
            .retained_selection_install_available = self.retainedSelectionInstallAvailableWithIdentity(presentation),
            .retained_selection_action_admitted = self.retainedSelectionAdmittedWithIdentity(presentation),
            .source = owner.source,
            .layout = owner.layout,
        };
    }
};

fn optionalRootIdentityEql(left: ?root_capability.Identity, right: ?root_capability.Identity) bool {
    if (left == null or right == null) return left == null and right == null;
    return left.?.eql(right.?);
}

test "committed diff state owns shared navigation without page target authority" {
    const allocator = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(allocator);
    var activation = diff_surface.authority.Lifecycle.init(.compare);
    var status: app_state.StatusMessage = .{};
    _ = activation.activate(4, .pending, .unavailable, .unavailable);

    var surface = state.diffSurface(.{
        .activation = &activation,
        .status = &status,
        .source = .{ .range = "compare" },
        .layout = .{ .width = 80, .height = 24 },
        .current_target = null,
        .live_drag_deferred_source = false,
    });
    surface.viewer.diff_scroll = 7;
    surface.search.mode = true;

    try std.testing.expectEqual(@as(usize, 7), state.viewer.diff_scroll);
    try std.testing.expect(state.search.mode);
    try std.testing.expect(surface.viewer == &state.viewer);
}

test "committed diff selection pin admits one exact History basis without changing review targets" {
    var state: State = .{};
    const before = try git_committed_review.ObjectId.parse(.sha1, "1111111111111111111111111111111111111111");
    const after = try git_committed_review.ObjectId.parse(.sha1, "2222222222222222222222222222222222222222");
    const basis: git_committed_review.CommittedDiffBasis = .{
        .object_format = .sha1,
        .before = .{ .commit = before },
        .after = after,
    };
    const identity: PresentationIdentity = .{ .diff_basis = basis };
    try std.testing.expect(state.installPinnedPresentationIdentity(identity));
    try std.testing.expect(state.retainedSelectionAdmittedWithIdentity(identity));

    var different = basis;
    different.after = before;
    try std.testing.expect(!state.retainedSelectionAdmittedWithIdentity(.{ .diff_basis = different }));
    try std.testing.expect(!state.retainedSelectionAdmitted(null));
}
