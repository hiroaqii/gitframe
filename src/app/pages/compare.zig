//! Retained state owner for the read-only Compare page.
//!
//! S3 installs the page identity and independent state skeleton. Loading,
//! picker ownership, committed-diff rendering, and page-local input are wired
//! by S4-S6; until then the shell renders the explicit not-loaded placeholder.

const std = @import("std");
const app_state = @import("../state.zig");
const diff_basis = @import("../diff_basis.zig");
const diff_surface = @import("../diff_surface.zig");
const app_load = @import("../load.zig");
const load_state = @import("../load_state.zig");
const page = @import("../page.zig");
const diff_selection = @import("../../diff/selection.zig");
const diff_source = @import("../../diff/source.zig");
const file_tree = @import("../../file_tree.zig");
const review_state = @import("../../review/state.zig");

/// S6 replaces this scaffold with the owned asynchronous picker state.
pub const BasePickerState = struct {};

/// A live drag may defer an entire atomic Compare completion. This owner never
/// splits basis from diff; replacement and page teardown release both through
/// the normal undelivered-completion contract.
pub const DeferredLoadApply = struct {
    finished: app_load.CompareLoadFinished,

    pub fn deinit(self: *DeferredLoadApply, allocator: std.mem.Allocator) void {
        self.finished.deinit(allocator);
        self.* = undefined;
    }
};

pub const RefreshRequest = struct {
    identity: page.RequestIdentity,
    generation: u64,
};

pub const LoadAcceptance = enum {
    stale,
    loaded,
    basis_failed,
    failed,
};

pub const BasisFailureState = struct {
    kind: diff_basis.BasisFailure,
    attempted: diff_basis.BaseTarget,

    pub fn deinit(self: *BasisFailureState, allocator: std.mem.Allocator) void {
        self.attempted.deinit(allocator);
        self.* = undefined;
    }
};

pub const ComparePageState = struct {
    // Independently owned fields exposed through DiffSurface.
    activation: diff_surface.authority.Lifecycle = .init(.compare),
    status: app_state.StatusMessage = .{},
    load: load_state.LoadRuntimeState = .{},
    viewer: diff_surface.ViewerState = .{},
    search: diff_surface.DiffSearchState = .{},
    file_search: diff_surface.file_search.State = .{},
    file_search_return_focus: diff_surface.Focus = .sidebar,
    accepted_sidebar_revision: u64 = 1,
    review_display: app_state.ReviewDisplayState = .{},
    reviewed_store: review_state.Store = .{},
    tree_order: file_tree.StableOrder = .{},
    tree_order_scope: ?[]u8 = null,
    selection_owner: diff_selection.Owner = .none,
    completed_selection: ?diff_surface.selection.CompletedSelection = null,
    source_session_revision: u64 = 0,
    pending_initial_first_visible_selection: bool = false,

    // Compare-owned basis and refresh state.
    basis: ?diff_basis.BranchDiffBasis = null,
    base_target: ?diff_basis.BaseTarget = null,
    basis_failure: ?BasisFailureState = null,
    base_picker: BasePickerState = .{},
    refresh_generation: u64 = 0,
    deferred_load_apply: ?DeferredLoadApply = null,
    refresh_anchor: ?diff_surface.ReloadAnchor = null,

    pub fn activate(self: *ComparePageState, repo_epoch: u64) u64 {
        return self.activation.activate(repo_epoch, .pending, .unavailable, .unavailable);
    }

    pub fn deactivate(self: *ComparePageState) void {
        self.activation.deactivate();
    }

    pub fn beginRefresh(self: *ComparePageState) ?RefreshRequest {
        const identity = self.activation.currentIdentity() orelse return null;
        self.refresh_generation +%= 1;
        if (self.refresh_generation == 0) self.refresh_generation = 1;
        self.activation.markPending(.source);
        return .{ .identity = identity, .generation = self.refresh_generation };
    }

    /// Admission-only S5 handler. A loaded result deliberately stays in
    /// `finished` so the shell's defer can release it immediately; S6 replaces
    /// that terminal with the atomic page commit.
    pub fn acceptLoadFinished(
        self: *ComparePageState,
        allocator: std.mem.Allocator,
        repo_epoch: u64,
        finished: *app_load.CompareLoadFinished,
    ) LoadAcceptance {
        if (!self.acceptsLoadFinished(repo_epoch, finished.*)) return .stale;

        return switch (finished.result) {
            .loaded => result: {
                self.clearBasisFailure(allocator);
                _ = self.activation.finishMember(finished.identity, .source, .fresh);
                break :result .loaded;
            },
            .basis_failed => |failure| result: {
                self.clearBasisFailure(allocator);
                self.basis_failure = .{
                    .kind = failure.kind,
                    .attempted = failure.attempted,
                };
                finished.result = .empty;
                _ = self.activation.finishMember(finished.identity, .source, .failed);
                break :result .basis_failed;
            },
            .failed, .failed_static, .empty => result: {
                _ = self.activation.finishMember(finished.identity, .source, .failed);
                break :result .failed;
            },
        };
    }

    pub fn rejectRefresh(self: *ComparePageState, request: RefreshRequest, repo_epoch: u64) bool {
        if (request.generation != self.refresh_generation) return false;
        if (!self.activation.acceptsRepoEpoch(request.identity, repo_epoch)) return false;
        return self.activation.finishMember(request.identity, .source, .failed);
    }

    pub fn replaceDeferredLoad(
        self: *ComparePageState,
        allocator: std.mem.Allocator,
        finished: app_load.CompareLoadFinished,
    ) void {
        if (self.deferred_load_apply) |*deferred| deferred.deinit(allocator);
        self.deferred_load_apply = .{ .finished = finished };
    }

    fn acceptsLoadFinished(
        self: *const ComparePageState,
        repo_epoch: u64,
        finished: app_load.CompareLoadFinished,
    ) bool {
        if (finished.generation != self.refresh_generation) return false;
        if (!self.activation.acceptsRepoEpoch(finished.identity, repo_epoch)) return false;
        const current = self.activation.currentIdentity() orelse return false;
        return std.meta.eql(current, finished.identity);
    }

    fn clearBasisFailure(self: *ComparePageState, allocator: std.mem.Allocator) void {
        if (self.basis_failure) |*failure| failure.deinit(allocator);
        self.basis_failure = null;
    }

    pub fn deinit(self: *ComparePageState, allocator: std.mem.Allocator) void {
        self.selection_owner = .none;
        if (self.completed_selection) |*selection| selection.deinit(allocator);
        // Candidate paths borrow the accepted load owner.
        self.file_search.deinit(allocator);
        self.load.clearCurrent(allocator);
        self.reviewed_store.deinit(allocator);
        self.tree_order.deinit(allocator);
        if (self.tree_order_scope) |scope| allocator.free(scope);
        if (self.refresh_anchor) |*anchor| anchor.deinit(allocator);
        if (self.basis) |*basis| basis.deinit(allocator);
        if (self.base_target) |*target| target.deinit(allocator);
        if (self.basis_failure) |*failure| failure.deinit(allocator);
        if (self.deferred_load_apply) |*deferred| deferred.deinit(allocator);
        self.* = .{};
    }

    pub fn diffSurface(
        self: *ComparePageState,
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
            .reload_anchor = if (self.refresh_anchor) |*anchor| anchor else null,
            .live_drag_deferred_source = self.deferred_load_apply != null,
            .source = source,
            .layout = layout,
        };
    }

    pub fn readSurface(
        self: *const ComparePageState,
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
            .reload_anchor = if (self.refresh_anchor) |*anchor| anchor else null,
            .live_drag_deferred_source = self.deferred_load_apply != null,
            .source = source,
            .layout = layout,
        };
    }
};

test "Compare owns an independent shared diff surface state" {
    const allocator = std.testing.allocator;
    var state: ComparePageState = .{};
    defer state.deinit(allocator);

    var surface = state.diffSurface(.{ .range = "0000000..1111111" }, .{ .width = 80, .height = 24 });
    surface.viewer.diff_scroll = 7;
    surface.search.mode = true;

    try std.testing.expectEqual(@as(usize, 7), state.viewer.diff_scroll);
    try std.testing.expect(state.search.mode);
    try std.testing.expect(surface.viewer == &state.viewer);
    try std.testing.expect(surface.source == .range);
}

test "Compare activation uses its own retained lifecycle" {
    var state: ComparePageState = .{};
    const first = state.activate(9);
    state.deactivate();
    const second = state.activate(9);

    try std.testing.expect(first != 0);
    try std.testing.expectEqual(first + 1, second);
    try std.testing.expectEqual(page.Id.compare, state.activation.currentIdentity().?.origin);
}

fn failedFinished(
    allocator: std.mem.Allocator,
    identity: page.RequestIdentity,
    generation: u64,
    message: []const u8,
) !app_load.CompareLoadFinished {
    return .{
        .identity = identity,
        .generation = generation,
        .result = .{ .failed = try allocator.dupe(u8, message) },
    };
}

fn basisFailedFinished(
    allocator: std.mem.Allocator,
    identity: page.RequestIdentity,
    generation: u64,
    name: []const u8,
) !app_load.CompareLoadFinished {
    const full_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{name});
    errdefer allocator.free(full_ref);
    return .{
        .identity = identity,
        .generation = generation,
        .result = .{ .basis_failed = .{
            .kind = .missing_base_ref,
            .attempted = .{
                .full_ref = full_ref,
                .display_name = try allocator.dupe(u8, name),
                .kind = .local,
            },
        } },
    };
}

fn loadedFinished(
    allocator: std.mem.Allocator,
    identity: page.RequestIdentity,
    generation: u64,
) !app_load.CompareLoadFinished {
    const full_ref = try allocator.dupe(u8, "refs/heads/main");
    errdefer allocator.free(full_ref);
    const display_name = try allocator.dupe(u8, "main");
    errdefer allocator.free(display_name);
    return .{
        .identity = identity,
        .generation = generation,
        .result = .{ .loaded = .{
            .basis = .{
                .base = .{
                    .full_ref = full_ref,
                    .display_name = display_name,
                    .kind = .local,
                    .oid = .{},
                },
                .head_display = try allocator.dupe(u8, "feature"),
                .merge_base_oid = .{},
                .head_oid = .{},
                .ahead_count = 1,
            },
            .diff = .empty,
        } },
    };
}

test "Compare rejects a completion with stale repository epoch" {
    const allocator = std.testing.allocator;
    var state: ComparePageState = .{};
    defer state.deinit(allocator);
    const activation_id = state.activate(9);
    const request = state.beginRefresh().?;
    var finished = try failedFinished(allocator, page.RequestIdentity.compare(8, activation_id), request.generation, "old repo");
    defer finished.deinit(allocator);

    try std.testing.expectEqual(LoadAcceptance.stale, state.acceptLoadFinished(allocator, 9, &finished));
}

test "Compare rejects a completion with stale activation" {
    const allocator = std.testing.allocator;
    var state: ComparePageState = .{};
    defer state.deinit(allocator);
    const old_activation = state.activate(9);
    _ = state.beginRefresh().?;
    state.deactivate();
    _ = state.activate(9);
    const current = state.beginRefresh().?;
    var finished = try failedFinished(allocator, page.RequestIdentity.compare(9, old_activation), current.generation, "old activation");
    defer finished.deinit(allocator);

    try std.testing.expectEqual(LoadAcceptance.stale, state.acceptLoadFinished(allocator, 9, &finished));
}

test "Compare rejects a completion with stale generation" {
    const allocator = std.testing.allocator;
    var state: ComparePageState = .{};
    defer state.deinit(allocator);
    _ = state.activate(9);
    const request = state.beginRefresh().?;
    var finished = try failedFinished(allocator, request.identity, request.generation + 1, "old generation");
    defer finished.deinit(allocator);

    try std.testing.expectEqual(LoadAcceptance.stale, state.acceptLoadFinished(allocator, 9, &finished));
}

test "Compare replacement makes the older pending completion stale" {
    const allocator = std.testing.allocator;
    var state: ComparePageState = .{};
    defer state.deinit(allocator);
    _ = state.activate(4);
    const first = state.beginRefresh().?;
    const replacement = state.beginRefresh().?;
    var old_finished = try failedFinished(allocator, first.identity, first.generation, "replaced");
    defer old_finished.deinit(allocator);
    var current_finished = try failedFinished(allocator, replacement.identity, replacement.generation, "current");
    defer current_finished.deinit(allocator);

    try std.testing.expectEqual(LoadAcceptance.stale, state.acceptLoadFinished(allocator, 4, &old_finished));
    try std.testing.expectEqual(LoadAcceptance.failed, state.acceptLoadFinished(allocator, 4, &current_finished));
}

test "Compare moves attempted failure, replaces it, and clears it on success" {
    const allocator = std.testing.allocator;
    var state: ComparePageState = .{};
    defer state.deinit(allocator);
    _ = state.activate(6);

    const first = state.beginRefresh().?;
    var first_finished = try basisFailedFinished(allocator, first.identity, first.generation, "missing-a");
    defer first_finished.deinit(allocator);
    try std.testing.expectEqual(LoadAcceptance.basis_failed, state.acceptLoadFinished(allocator, 6, &first_finished));
    try std.testing.expect(first_finished.result == .empty);
    try std.testing.expectEqualStrings("missing-a", state.basis_failure.?.attempted.display_name);

    const second = state.beginRefresh().?;
    var second_finished = try basisFailedFinished(allocator, second.identity, second.generation, "missing-b");
    defer second_finished.deinit(allocator);
    try std.testing.expectEqual(LoadAcceptance.basis_failed, state.acceptLoadFinished(allocator, 6, &second_finished));
    try std.testing.expectEqualStrings("missing-b", state.basis_failure.?.attempted.display_name);

    const third = state.beginRefresh().?;
    var success = try loadedFinished(allocator, third.identity, third.generation);
    defer success.deinit(allocator);
    try std.testing.expectEqual(LoadAcceptance.loaded, state.acceptLoadFinished(allocator, 6, &success));
    try std.testing.expect(state.basis_failure == null);
    // S5 admission intentionally leaves the atomic loaded bundle in Finished;
    // the defer above is its one terminal cleanup until S6 installs it.
    try std.testing.expect(success.result == .loaded);
}

test "Compare deferred completion replacement and page deinit release exactly once" {
    const allocator = std.testing.allocator;
    var state: ComparePageState = .{};
    _ = state.activate(3);
    const request = state.beginRefresh().?;
    state.replaceDeferredLoad(allocator, try failedFinished(allocator, request.identity, request.generation, "first"));
    state.replaceDeferredLoad(allocator, try failedFinished(allocator, request.identity, request.generation, "second"));
    state.deinit(allocator);
}
