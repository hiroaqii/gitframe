//! Shared retained state for read-only committed-diff pages.
//!
//! History and Compare own independent activation, selection or
//! target, request, modal, and diagnostics. This component owns only the diff
//! interaction state whose contract is identical for those pages.

const std = @import("std");
const content_fingerprint = @import("../../content_fingerprint.zig");
const app_state = @import("../state.zig");
const diff_surface = @import("../diff_surface.zig");
const load_state = @import("../load_state.zig");
const app_load = @import("../load.zig");
const commit_diff = @import("../../git/commit_diff.zig");
const diff_presentation_identity = @import("../../diff/presentation_identity.zig");
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
/// not durable product state: Compare keeps its target, while History
/// pins the already-resolved direct endpoint basis.
pub const PresentationIdentity = union(enum) {
    target: commit_diff.Target,
    diff_basis: commit_diff.Basis,

    pub fn eql(self: PresentationIdentity, other: PresentationIdentity) bool {
        return switch (self) {
            .target => |target| switch (other) {
                .target => |candidate| target.eql(&candidate),
                .diff_basis => false,
            },
            .diff_basis => |basis| switch (other) {
                .target => false,
                .diff_basis => |candidate| std.meta.eql(basis, candidate),
            },
        };
    }
};

pub const PinnedSelectionBasis = struct {
    identity: PresentationIdentity,

    pub fn init(target: commit_diff.Target) PinnedSelectionBasis {
        return .{ .identity = .{ .target = target } };
    }

    pub fn initIdentity(identity: PresentationIdentity) PinnedSelectionBasis {
        return .{ .identity = identity };
    }

    pub fn eql(self: PinnedSelectionBasis, other: PinnedSelectionBasis) bool {
        return self.identity.eql(other.identity);
    }
};

pub const RetainedSelectionTransfer = enum {
    none,
    preserve_exact_folds,
};

pub const SurfaceOwner = struct {
    activation: *diff_surface.authority.Lifecycle,
    status: *app_state.StatusMessage,
    source: diff_source.SourceMode,
    layout: diff_surface.Layout,
    current_target: ?commit_diff.Target,
    presentation_identity: ?PresentationIdentity = null,
    live_drag_deferred_source: bool,

    fn currentPresentation(self: SurfaceOwner) ?PresentationIdentity {
        return self.presentation_identity orelse if (self.current_target) |target|
            PresentationIdentity{ .target = target }
        else
            null;
    }
};

pub const ReadSurfaceOwner = struct {
    activation: *const diff_surface.authority.Lifecycle,
    status: *const app_state.StatusMessage,
    source: diff_source.SourceMode,
    layout: diff_surface.Layout,
    current_target: ?commit_diff.Target,
    presentation_identity: ?PresentationIdentity = null,
    live_drag_deferred_source: bool,

    fn currentPresentation(self: ReadSurfaceOwner) ?PresentationIdentity {
        return self.presentation_identity orelse if (self.current_target) |target|
            PresentationIdentity{ .target = target }
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
        current_target: ?commit_diff.Target,
    ) bool {
        return self.retainedSelectionInstallAvailableWithIdentity(if (current_target) |target|
            .{ .target = target }
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
        current_target: ?commit_diff.Target,
    ) bool {
        return self.retainedSelectionAdmittedWithIdentity(if (current_target) |target|
            .{ .target = target }
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
        current_target: ?commit_diff.Target,
    ) bool {
        return self.installPinnedPresentationIdentity(if (current_target) |target|
            .{ .target = target }
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
        current_target: ?commit_diff.Target,
        incoming_target: commit_diff.Target,
        incoming_diff: *const app_load.CommittedDiffBundle,
    ) RetainedSelectionTransfer {
        return self.retainedSelectionTransfersWithIdentity(
            repo_epoch,
            root_identity,
            source,
            if (current_target) |target| .{ .target = target } else null,
            .{ .target = incoming_target },
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
    ) RetainedSelectionTransfer {
        const completed = self.completed_selection orelse return .none;
        const pinned = self.pinned_selection_basis orelse return .none;
        const current = current_identity orelse return .none;
        if (!pinned.eql(.initIdentity(current)) or !pinned.eql(.initIdentity(incoming_identity))) return .none;
        if (completed.selection_layout_revision != self.selection_layout_revision) return .none;
        if (completed.token.repo_epoch != repo_epoch or
            !optionalRootIdentityEql(completed.token.root_identity, root_identity) or
            !completed.token.source.eql(diff_surface.selection.SourceBasis.init(source)) or
            completed.token.source_session_revision != self.source_session_revision) return .none;
        const current_loaded = switch (self.load.state) {
            .loaded => |session| &session.loaded,
            else => return .none,
        };
        const incoming_loaded = switch (incoming_diff.*) {
            .loaded => |bundle| &bundle.loaded,
            .empty => return .none,
        };
        const outgoing_fingerprint = content_fingerprint.Fingerprint.init(current_loaded.text);
        const incoming_fingerprint = content_fingerprint.Fingerprint.init(incoming_loaded.text);
        const fingerprint_matches = switch (completed.token.display) {
            .loaded => |fingerprint| fingerprint.eql(outgoing_fingerprint) and fingerprint.eql(incoming_fingerprint),
            else => false,
        };
        if (!fingerprint_matches or !exactFoldTopology(current_loaded, incoming_loaded)) return .none;
        return .preserve_exact_folds;
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
        current_target: commit_diff.Target,
        pair_changed: bool,
        transfer_selection: RetainedSelectionTransfer,
        incoming: *app_load.CommittedDiffBundle,
    ) !void {
        return self.replaceDiffWithIdentity(
            allocator,
            repo_epoch,
            repo_root,
            root_identity,
            source,
            .{ .target = current_target },
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
        transfer_selection: RetainedSelectionTransfer,
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

        if (transfer_selection == .preserve_exact_folds) {
            const outgoing = switch (self.load.state) {
                .loaded => |*session| &session.loaded,
                else => unreachable,
            };
            const prepared = &prepared_session.?.loaded;
            std.debug.assert(outgoing.collapsed_hunks.len == prepared.collapsed_hunks.len);
            @memcpy(prepared.collapsed_hunks, outgoing.collapsed_hunks);
            for (prepared.document.files, 0..) |_, file_index| {
                prepared.rendered_line_cache.recomputeFile(
                    prepared.document,
                    file_index,
                    prepared.foldedHunksForFile(file_index),
                );
            }
        }

        self.file_search.deinit(allocator);
        if (transfer_selection == .none) self.clearRetainedSelection(allocator);
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
        if (transfer_selection == .preserve_exact_folds) {
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
            .context_copy_available = self.retainedSelectionInstallAvailableWithIdentity(presentation),
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
            .context_copy_available = self.retainedSelectionInstallAvailableWithIdentity(presentation),
            .source = owner.source,
            .layout = owner.layout,
        };
    }
};

fn exactFoldTopology(outgoing: *const @import("../../loaded_diff.zig").LoadedDiff, incoming: *const @import("../../loaded_diff.zig").LoadedDiff) bool {
    if (outgoing.document.files.len != incoming.document.files.len or
        outgoing.collapsed_hunks.len != incoming.collapsed_hunks.len)
        return false;
    for (outgoing.document.files, incoming.document.files) |old_file, new_file| {
        if (old_file.hunks.len != new_file.hunks.len or
            !diff_presentation_identity.exactEqual(old_file, new_file))
            return false;
    }
    return true;
}

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

test "committed diff selection pin admits one exact History basis without changing targets" {
    var state: State = .{};
    const before = try commit_diff.ObjectId.parse(.sha1, "1111111111111111111111111111111111111111");
    const after = try commit_diff.ObjectId.parse(.sha1, "2222222222222222222222222222222222222222");
    const basis: commit_diff.Basis = .{
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

test "committed diff exact reload preserves folds selection pin and indexes for Compare and History identities" {
    const allocator = std.testing.allocator;
    const before = try commit_diff.ObjectId.parse(.sha1, "1111111111111111111111111111111111111111");
    const after = try commit_diff.ObjectId.parse(.sha1, "2222222222222222222222222222222222222222");
    const target: commit_diff.Target = .{
        .object_format = .sha1,
        .base_oid = before,
        .head_oid = after,
        .diff_base_oid = before,
    };
    const basis: commit_diff.Basis = .{
        .object_format = .sha1,
        .before = .{ .commit = before },
        .after = after,
    };
    const cases = [_]struct {
        identity: PresentationIdentity,
        source: diff_source.SourceMode,
    }{
        .{ .identity = .{ .target = target }, .source = .{ .range = "compare" } },
        .{ .identity = .{ .diff_basis = basis }, .source = .{ .range = "history" } },
    };
    const patch =
        "diff --git a/a b/a\n" ++
        "--- a/a\n" ++
        "+++ b/a\n" ++
        "@@ -1,3 +1,3 @@ first\n" ++
        " one\n" ++
        "-old\n" ++
        "+new\n" ++
        " two\n" ++
        "@@ -10,2 +10,2 @@ second\n" ++
        " ten\n" ++
        "-older\n" ++
        "+newer\n";
    const changed_patch =
        "diff --git a/a b/a\n" ++
        "--- a/a\n" ++
        "+++ b/a\n" ++
        "@@ -1,3 +1,3 @@ first\n" ++
        " one\n" ++
        "-old\n" ++
        "+new\n" ++
        " two\n" ++
        "@@ -10,2 +10,2 @@ second\n" ++
        " ten\n" ++
        "-older\n" ++
        "+newest\n";

    for (cases) |case| {
        var state: State = .{};
        defer state.deinit(allocator);

        var initial: app_load.CommittedDiffBundle = .{ .loaded = try app_load.buildLoadedBundle(allocator, patch) };
        defer initial.deinit();
        try state.replaceDiffWithIdentity(
            allocator,
            7,
            null,
            null,
            case.source,
            case.identity,
            true,
            .none,
            &initial,
        );
        const loaded = switch (state.load.state) {
            .loaded => |*session| &session.loaded,
            else => return error.ExpectedLoadedDiff,
        };
        try std.testing.expectEqual(@as(usize, 2), loaded.document.files[0].hunks.len);
        loaded.setHunkFolded(0, 1, true);
        const folded_unified_rows = loaded.renderedLineIndex(0, .unified).lineCount();
        const folded_side_rows = loaded.renderedLineIndex(0, .side_by_side).lineCount();

        var selection = diff_selection.DragSelection.initUnified(
            .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
            .{ .hunk_index = 0, .line_index = 0 },
        );
        selection.focus = .{ .hunk_index = 0, .line_index = 3 };
        selection.moved = true;
        state.completed_selection = try diff_surface.selection.buildParsedFolded(
            allocator,
            .{
                .repo_epoch = 7,
                .root_identity = null,
                .source = diff_surface.selection.SourceBasis.init(case.source),
                .source_session_revision = state.source_session_revision,
                .display = .{ .loaded = content_fingerprint.Fingerprint.init(loaded.text) },
            },
            loaded.document.files[0],
            loaded.foldedHunksForFile(0),
            state.selection_layout_revision,
            selection,
        );
        try std.testing.expect(state.installPinnedPresentationIdentity(case.identity));
        const clipboard_before = try state.completed_selection.?.clipboardText(allocator);
        defer allocator.free(clipboard_before);
        const layout_revision = state.selection_layout_revision;

        var identical: app_load.CommittedDiffBundle = .{ .loaded = try app_load.buildLoadedBundle(allocator, patch) };
        defer identical.deinit();
        try std.testing.expect(!identical.loaded.loaded.isHunkFolded(0, 1));
        const transfer = state.retainedSelectionTransfersWithIdentity(
            7,
            null,
            case.source,
            case.identity,
            case.identity,
            &identical,
        );
        try std.testing.expectEqual(RetainedSelectionTransfer.preserve_exact_folds, transfer);
        try state.replaceDiffWithIdentity(
            allocator,
            7,
            null,
            null,
            case.source,
            case.identity,
            false,
            transfer,
            &identical,
        );

        const transferred = switch (state.load.state) {
            .loaded => |*session| &session.loaded,
            else => return error.ExpectedTransferredDiff,
        };
        try std.testing.expect(transferred.isHunkFolded(0, 1));
        try std.testing.expectEqual(folded_unified_rows, transferred.renderedLineIndex(0, .unified).lineCount());
        try std.testing.expectEqual(folded_side_rows, transferred.renderedLineIndex(0, .side_by_side).lineCount());
        try std.testing.expectEqual(layout_revision, state.selection_layout_revision);
        try std.testing.expect(state.retainedSelectionAdmittedWithIdentity(case.identity));
        try std.testing.expectEqual(state.source_session_revision, state.completed_selection.?.token.source_session_revision);
        const clipboard_after = try state.completed_selection.?.clipboardText(allocator);
        defer allocator.free(clipboard_after);
        try std.testing.expectEqualStrings(clipboard_before, clipboard_after);

        transferred.setHunkFolded(0, 1, false);
        const unfolded_unified_rows = transferred.renderedLineIndex(0, .unified).lineCount();
        const unfolded_side_rows = transferred.renderedLineIndex(0, .side_by_side).lineCount();
        var unfolded_identical: app_load.CommittedDiffBundle = .{ .loaded = try app_load.buildLoadedBundle(allocator, patch) };
        defer unfolded_identical.deinit();
        const unfolded_transfer = state.retainedSelectionTransfersWithIdentity(
            7,
            null,
            case.source,
            case.identity,
            case.identity,
            &unfolded_identical,
        );
        try std.testing.expectEqual(RetainedSelectionTransfer.preserve_exact_folds, unfolded_transfer);
        try state.replaceDiffWithIdentity(
            allocator,
            7,
            null,
            null,
            case.source,
            case.identity,
            false,
            unfolded_transfer,
            &unfolded_identical,
        );
        const unfolded = switch (state.load.state) {
            .loaded => |*session| &session.loaded,
            else => return error.ExpectedTransferredDiff,
        };
        try std.testing.expect(!unfolded.isHunkFolded(0, 1));
        try std.testing.expectEqual(unfolded_unified_rows, unfolded.renderedLineIndex(0, .unified).lineCount());
        try std.testing.expectEqual(unfolded_side_rows, unfolded.renderedLineIndex(0, .side_by_side).lineCount());
        try std.testing.expectEqual(layout_revision, state.selection_layout_revision);
        try std.testing.expect(state.retainedSelectionAdmittedWithIdentity(case.identity));
        const unfolded_clipboard = try state.completed_selection.?.clipboardText(allocator);
        defer allocator.free(unfolded_clipboard);
        try std.testing.expectEqualStrings(clipboard_before, unfolded_clipboard);

        var changed: app_load.CommittedDiffBundle = .{ .loaded = try app_load.buildLoadedBundle(allocator, changed_patch) };
        defer changed.deinit();
        const rejected = state.retainedSelectionTransfersWithIdentity(
            7,
            null,
            case.source,
            case.identity,
            case.identity,
            &changed,
        );
        try std.testing.expectEqual(RetainedSelectionTransfer.none, rejected);
        try state.replaceDiffWithIdentity(
            allocator,
            7,
            null,
            null,
            case.source,
            case.identity,
            false,
            rejected,
            &changed,
        );
        try std.testing.expect(state.completed_selection == null);
        try std.testing.expect(state.pinned_selection_basis == null);
    }
}
