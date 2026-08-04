//! Retained state owner for the read-only Compare page.
//!
//! The page owns an accepted basis and committed-diff body as one snapshot,
//! plus independent navigation, picker, refresh, and deferred-apply state.

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
const git_backend = @import("../../git/backend.zig");
const review_state = @import("../../review/state.zig");

pub const BasePickerRequest = struct {
    identity: page.RequestIdentity,
    generation: u64,
};

/// Page-owned modal list. Pending task ownership remains independent: closing
/// advances the generation, while the eventual stale Finished owns cleanup.
pub const BasePickerState = struct {
    open: bool = false,
    loading: bool = false,
    generation: u64 = 0,
    selected_index: usize = 0,
    accepted: ?git_backend.BranchList = null,
    failure: ?[]u8 = null,

    pub fn begin(self: *BasePickerState, allocator: std.mem.Allocator, identity: page.RequestIdentity) BasePickerRequest {
        self.clearAccepted(allocator);
        self.clearFailure(allocator);
        self.open = true;
        self.loading = true;
        self.selected_index = 0;
        self.advanceGeneration();
        return .{ .identity = identity, .generation = self.generation };
    }

    pub fn close(self: *BasePickerState, allocator: std.mem.Allocator) void {
        self.clearAccepted(allocator);
        self.clearFailure(allocator);
        self.open = false;
        self.loading = false;
        self.selected_index = 0;
        self.advanceGeneration();
    }

    pub fn moveSelection(self: *BasePickerState, delta: isize) void {
        const list = self.accepted orelse return;
        if (list.branches.len == 0) return;
        if (delta < 0) {
            self.selected_index = if (self.selected_index == 0) list.branches.len - 1 else self.selected_index - 1;
        } else if (delta > 0) {
            self.selected_index = (self.selected_index + 1) % list.branches.len;
        }
    }

    pub fn markFailure(self: *BasePickerState, allocator: std.mem.Allocator, message: []const u8) void {
        self.loading = false;
        self.clearFailure(allocator);
        self.failure = allocator.dupe(u8, message) catch null;
    }

    pub fn selectedTarget(self: *const BasePickerState, allocator: std.mem.Allocator) !?diff_basis.BaseTarget {
        const list = self.accepted orelse return null;
        if (self.selected_index >= list.branches.len) return null;
        const item = list.branches[self.selected_index];
        const full_ref = try allocator.dupe(u8, item.full_ref);
        errdefer allocator.free(full_ref);
        return .{
            .full_ref = full_ref,
            .display_name = try allocator.dupe(u8, item.name),
            .kind = item.kind,
        };
    }

    pub fn acceptFinished(
        self: *BasePickerState,
        allocator: std.mem.Allocator,
        repo_epoch: u64,
        activation: *const diff_surface.authority.Lifecycle,
        finished: *app_load.CompareBranchListFinished,
    ) bool {
        if (!self.open or finished.generation != self.generation) return false;
        if (!activation.acceptsRepoEpoch(finished.identity, repo_epoch)) return false;
        const current = activation.currentIdentity() orelse return false;
        if (!std.meta.eql(current, finished.identity)) return false;

        self.loading = false;
        self.clearFailure(allocator);
        switch (finished.result) {
            .loaded => |list| {
                self.clearAccepted(allocator);
                self.accepted = list;
                finished.result = .empty;
                const len = self.accepted.?.branches.len;
                if (len == 0) self.selected_index = 0 else self.selected_index = @min(self.selected_index, len - 1);
            },
            .failed => |message| {
                self.failure = message;
                finished.result = .empty;
            },
            .failed_static => |message| self.failure = allocator.dupe(u8, message) catch null,
            .empty => {},
        }
        return true;
    }

    pub fn deinit(self: *BasePickerState, allocator: std.mem.Allocator) void {
        self.clearAccepted(allocator);
        self.clearFailure(allocator);
        self.* = .{};
    }

    fn clearAccepted(self: *BasePickerState, allocator: std.mem.Allocator) void {
        if (self.accepted) |*list| list.deinit(allocator);
        self.accepted = null;
    }

    fn clearFailure(self: *BasePickerState, allocator: std.mem.Allocator) void {
        if (self.failure) |message| allocator.free(message);
        self.failure = null;
    }

    fn advanceGeneration(self: *BasePickerState) void {
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
    }
};

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
    load_failure: ?[]u8 = null,
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
        if (!self.hasAcceptedDisplay()) {
            self.load.clearCurrent(null);
            self.load.state = .loading;
        }
        return .{ .identity = identity, .generation = self.refresh_generation };
    }

    /// A new request supersedes the previous terminal diagnostic while the
    /// accepted basis and body remain visible as the refresh snapshot.
    pub fn clearRefreshFailure(self: *ComparePageState, allocator: std.mem.Allocator) void {
        self.clearBasisFailure(allocator);
        self.clearLoadFailure(allocator);
    }

    pub fn beginBasePicker(self: *ComparePageState, allocator: std.mem.Allocator) ?BasePickerRequest {
        const identity = self.activation.currentIdentity() orelse return null;
        self.selection_owner = .none;
        return self.base_picker.begin(allocator, identity);
    }

    pub fn closeBasePicker(self: *ComparePageState, allocator: std.mem.Allocator) void {
        self.base_picker.close(allocator);
    }

    pub fn chooseBasePickerTarget(self: *ComparePageState, allocator: std.mem.Allocator) !bool {
        var target = try self.base_picker.selectedTarget(allocator) orelse return false;
        errdefer target.deinit(allocator);
        self.base_picker.close(allocator);
        if (self.base_target) |*old| old.deinit(allocator);
        self.base_target = target;
        return true;
    }

    pub fn applyLoadFinished(
        self: *ComparePageState,
        allocator: std.mem.Allocator,
        repo_epoch: u64,
        repo_root: ?[]const u8,
        finished: *app_load.CompareLoadFinished,
    ) !LoadAcceptance {
        if (!self.acceptsLoadFinished(repo_epoch, finished.*)) return .stale;

        return switch (finished.result) {
            .loaded => |*bundle| result: {
                try self.commitLoaded(allocator, repo_root, bundle);
                finished.result = .empty;
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
                self.clearLoadFailure(allocator);
                _ = self.activation.finishMember(finished.identity, .source, .failed);
                break :result .basis_failed;
            },
            .failed => |message| result: {
                self.replaceLoadFailure(allocator, message) catch {};
                _ = self.activation.finishMember(finished.identity, .source, .failed);
                break :result .failed;
            },
            .failed_static => |message| result: {
                self.replaceLoadFailure(allocator, message) catch {};
                _ = self.activation.finishMember(finished.identity, .source, .failed);
                break :result .failed;
            },
            .empty => result: {
                _ = self.activation.finishMember(finished.identity, .source, .failed);
                break :result .failed;
            },
        };
    }

    pub fn acceptsFinished(self: *const ComparePageState, repo_epoch: u64, finished: app_load.CompareLoadFinished) bool {
        return self.acceptsLoadFinished(repo_epoch, finished);
    }

    pub fn takeRefreshAnchor(self: *ComparePageState) ?diff_surface.ReloadAnchor {
        const anchor = self.refresh_anchor;
        self.refresh_anchor = null;
        return anchor;
    }

    pub fn replaceRefreshAnchor(self: *ComparePageState, allocator: std.mem.Allocator, anchor: ?diff_surface.ReloadAnchor) void {
        if (self.refresh_anchor) |*old| old.deinit(allocator);
        self.refresh_anchor = anchor;
    }

    pub fn hasAcceptedDisplay(self: *const ComparePageState) bool {
        if (self.basis == null) return false;
        return switch (self.load.state) {
            .loaded, .empty => true,
            .idle, .loading, .failed => false,
        };
    }

    pub fn rejectRefresh(self: *ComparePageState, request: RefreshRequest, repo_epoch: u64) bool {
        if (request.generation != self.refresh_generation) return false;
        if (!self.activation.acceptsRepoEpoch(request.identity, repo_epoch)) return false;
        return self.activation.finishMember(request.identity, .source, .failed);
    }

    pub fn failRefresh(
        self: *ComparePageState,
        allocator: std.mem.Allocator,
        request: RefreshRequest,
        repo_epoch: u64,
        message: []const u8,
    ) void {
        if (!self.rejectRefresh(request, repo_epoch)) return;
        self.replaceLoadFailure(allocator, message) catch {};
        if (self.refresh_anchor) |*anchor| anchor.deinit(allocator);
        self.refresh_anchor = null;
    }

    pub fn markNoRepository(self: *ComparePageState, allocator: std.mem.Allocator) void {
        self.load.replaceEmpty(allocator, .no_repository);
        self.clearBasisFailure(allocator);
        self.clearLoadFailure(allocator);
        if (self.activation.currentIdentity()) |identity| {
            _ = self.activation.finishMember(identity, .source, .failed);
        }
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

    fn commitLoaded(
        self: *ComparePageState,
        allocator: std.mem.Allocator,
        repo_root: ?[]const u8,
        bundle: *app_load.CompareLoadedBundle,
    ) !void {
        const pair_changed = if (self.basis) |current|
            !std.mem.eql(u8, current.merge_base_oid.slice(), bundle.basis.merge_base_oid.slice()) or
                !std.mem.eql(u8, current.head_oid.slice(), bundle.basis.head_oid.slice())
        else
            true;

        var default_target: ?diff_basis.BaseTarget = null;
        errdefer if (default_target) |*target| target.deinit(allocator);
        if (self.base_target == null) {
            const full_ref = try allocator.dupe(u8, bundle.basis.base.full_ref);
            const display_name = allocator.dupe(u8, bundle.basis.base.display_name) catch |err| {
                allocator.free(full_ref);
                return err;
            };
            default_target = .{
                .full_ref = full_ref,
                .display_name = display_name,
                .kind = bundle.basis.base.kind,
            };
        }

        var prepared_session: ?load_state.LoadedSession = null;
        switch (bundle.diff) {
            .empty => {},
            .loaded => |*diff_bundle| {
                const arena_allocator = diff_bundle.arena.?.allocator();
                if (repo_root) |root| {
                    diff_bundle.loaded.tree = try file_tree.buildWithOptions(
                        arena_allocator,
                        diff_bundle.loaded.document,
                        null,
                        .{ .root = .{ .name = std.fs.path.basename(root) } },
                    );
                }
                const reviewed = try arena_allocator.alloc(bool, diff_bundle.loaded.document.files.len);
                for (diff_bundle.loaded.document.files, 0..) |file, index| {
                    reviewed[index] = if (pair_changed)
                        false
                    else
                        try self.reviewed_store.containsFile(allocator, repo_root, file);
                }
                diff_bundle.loaded.reviewed_files = reviewed;
                try diff_bundle.loaded.rebuildVisibleNodes(
                    arena_allocator,
                    self.review_display.hide_reviewed_files,
                    self.review_display.changed_file_filter,
                );
                prepared_session = .{
                    .arena = diff_bundle.takeArena(),
                    .loaded = diff_bundle.loaded,
                };
            },
        }
        errdefer if (prepared_session) |*session| session.deinit(null);

        self.file_search.deinit(allocator);
        if (self.completed_selection) |*selection| selection.deinit(allocator);
        self.completed_selection = null;
        self.selection_owner = .none;
        if (pair_changed) {
            self.reviewed_store.deinit(allocator);
            self.tree_order.reset(allocator);
        }
        if (self.basis) |*basis| basis.deinit(allocator);
        self.basis = bundle.basis;
        bundle.basis = undefined;

        self.load.clearCurrent(allocator);
        if (prepared_session) |session| {
            self.load.state = .{ .loaded = session };
            prepared_session = null;
        } else {
            self.load.state = .{ .empty = .no_changes };
        }
        if (default_target) |target| {
            self.base_target = target;
            default_target = null;
        }
        self.source_session_revision +%= 1;
        self.clearBasisFailure(allocator);
        self.clearLoadFailure(allocator);
    }

    fn replaceLoadFailure(self: *ComparePageState, allocator: std.mem.Allocator, message: []const u8) !void {
        const copy = try allocator.dupe(u8, message);
        self.clearLoadFailure(allocator);
        self.load_failure = copy;
    }

    fn clearLoadFailure(self: *ComparePageState, allocator: std.mem.Allocator) void {
        if (self.load_failure) |message| allocator.free(message);
        self.load_failure = null;
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
        if (self.load_failure) |message| allocator.free(message);
        self.base_picker.deinit(allocator);
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

    try std.testing.expectEqual(LoadAcceptance.stale, try state.applyLoadFinished(allocator, 9, null, &finished));
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

    try std.testing.expectEqual(LoadAcceptance.stale, try state.applyLoadFinished(allocator, 9, null, &finished));
}

test "Compare rejects a completion with stale generation" {
    const allocator = std.testing.allocator;
    var state: ComparePageState = .{};
    defer state.deinit(allocator);
    _ = state.activate(9);
    const request = state.beginRefresh().?;
    var finished = try failedFinished(allocator, request.identity, request.generation + 1, "old generation");
    defer finished.deinit(allocator);

    try std.testing.expectEqual(LoadAcceptance.stale, try state.applyLoadFinished(allocator, 9, null, &finished));
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

    try std.testing.expectEqual(LoadAcceptance.stale, try state.applyLoadFinished(allocator, 4, null, &old_finished));
    try std.testing.expectEqual(LoadAcceptance.failed, try state.applyLoadFinished(allocator, 4, null, &current_finished));
}

test "Compare moves attempted failure, replaces it, and clears it on success" {
    const allocator = std.testing.allocator;
    var state: ComparePageState = .{};
    defer state.deinit(allocator);
    _ = state.activate(6);

    const first = state.beginRefresh().?;
    var first_finished = try basisFailedFinished(allocator, first.identity, first.generation, "missing-a");
    defer first_finished.deinit(allocator);
    try std.testing.expectEqual(LoadAcceptance.basis_failed, try state.applyLoadFinished(allocator, 6, null, &first_finished));
    try std.testing.expect(first_finished.result == .empty);
    try std.testing.expectEqualStrings("missing-a", state.basis_failure.?.attempted.display_name);

    const second = state.beginRefresh().?;
    var second_finished = try basisFailedFinished(allocator, second.identity, second.generation, "missing-b");
    defer second_finished.deinit(allocator);
    try std.testing.expectEqual(LoadAcceptance.basis_failed, try state.applyLoadFinished(allocator, 6, null, &second_finished));
    try std.testing.expectEqualStrings("missing-b", state.basis_failure.?.attempted.display_name);

    const third = state.beginRefresh().?;
    var success = try loadedFinished(allocator, third.identity, third.generation);
    defer success.deinit(allocator);
    try std.testing.expectEqual(LoadAcceptance.loaded, try state.applyLoadFinished(allocator, 6, null, &success));
    try std.testing.expect(state.basis_failure == null);
    try std.testing.expect(success.result == .empty);
    try std.testing.expect(state.basis != null);
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

const compare_test_diff =
    "diff --git a/src/old.zig b/src/old.zig\n" ++
    "--- a/src/old.zig\n" ++
    "+++ b/src/old.zig\n" ++
    "@@ -1 +1 @@\n" ++
    "-old\n" ++
    "+new\n";

fn testOid(byte: u8) diff_basis.Oid {
    var result: diff_basis.Oid = .{ .len = 40 };
    @memset(result.bytes[0..40], byte);
    return result;
}

fn loadedDiffFinished(
    allocator: std.mem.Allocator,
    identity: page.RequestIdentity,
    generation: u64,
    base_byte: u8,
    head_byte: u8,
    path_diff: []const u8,
) !app_load.CompareLoadFinished {
    const full_ref = try allocator.dupe(u8, "refs/heads/main");
    errdefer allocator.free(full_ref);
    const display_name = try allocator.dupe(u8, "main");
    errdefer allocator.free(display_name);
    const head_display = try allocator.dupe(u8, "feature");
    errdefer allocator.free(head_display);
    return .{
        .identity = identity,
        .generation = generation,
        .result = .{ .loaded = .{
            .basis = .{
                .base = .{
                    .full_ref = full_ref,
                    .display_name = display_name,
                    .kind = .local,
                    .oid = testOid(base_byte),
                },
                .head_display = head_display,
                .merge_base_oid = testOid(base_byte),
                .head_oid = testOid(head_byte),
                .ahead_count = 1,
            },
            .diff = .{ .loaded = try app_load.buildLoadedBundle(allocator, path_diff) },
        } },
    };
}

test "Compare loaded acceptance atomically installs matching basis and diff" {
    const allocator = std.testing.allocator;
    var state: ComparePageState = .{};
    defer state.deinit(allocator);
    _ = state.activate(5);
    const request = state.beginRefresh().?;
    var finished = try loadedDiffFinished(allocator, request.identity, request.generation, 'a', 'b', compare_test_diff);
    defer finished.deinit(allocator);

    try std.testing.expectEqual(LoadAcceptance.loaded, try state.applyLoadFinished(allocator, 5, "/work/gitframe", &finished));
    try std.testing.expectEqualStrings("main", state.basis.?.base.display_name);
    try std.testing.expectEqualStrings("refs/heads/main", state.base_target.?.full_ref);
    const loaded = switch (state.load.state) {
        .loaded => |session| session.loaded,
        else => return error.ExpectedLoadedCompare,
    };
    try std.testing.expectEqual(@as(usize, 1), loaded.document.files.len);
    try std.testing.expectEqualStrings("b/src/old.zig", loaded.document.files[0].new_path.?);
    try std.testing.expectEqual(file_tree.Node.Kind.repo_root, loaded.tree.nodes[0].kind);
    try std.testing.expectEqualStrings("gitframe", loaded.tree.nodes[0].name);
    try std.testing.expect(finished.result == .empty);
}

test "Compare viewed store retains only for the same accepted oid pair" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { base: u8, head: u8, retained: bool }{
        .{ .base = 'a', .head = 'b', .retained = true },
        .{ .base = 'd', .head = 'b', .retained = false },
        .{ .base = 'a', .head = 'e', .retained = false },
    };

    for (cases) |case| {
        var state: ComparePageState = .{};
        defer state.deinit(allocator);
        _ = state.activate(7);
        const first = state.beginRefresh().?;
        var first_finished = try loadedDiffFinished(allocator, first.identity, first.generation, 'a', 'b', compare_test_diff);
        defer first_finished.deinit(allocator);
        _ = try state.applyLoadFinished(allocator, 7, "/repo", &first_finished);
        const first_loaded = switch (state.load.state) {
            .loaded => |*session| &session.loaded,
            else => return error.ExpectedLoadedCompare,
        };
        try state.reviewed_store.set(allocator, "/repo", first_loaded.document.files[0], true);
        first_loaded.reviewed_files[0] = true;

        const second = state.beginRefresh().?;
        var second_finished = try loadedDiffFinished(allocator, second.identity, second.generation, case.base, case.head, compare_test_diff);
        defer second_finished.deinit(allocator);
        _ = try state.applyLoadFinished(allocator, 7, "/repo", &second_finished);
        const second_loaded = switch (state.load.state) {
            .loaded => |*session| &session.loaded,
            else => return error.ExpectedLoadedCompare,
        };
        try std.testing.expectEqual(case.retained, second_loaded.reviewed_files[0]);
        try std.testing.expectEqual(
            case.retained,
            try state.reviewed_store.containsFile(allocator, "/repo", second_loaded.document.files[0]),
        );
    }
}

test "Compare failed replacement preserves accepted display and attempted intent" {
    const allocator = std.testing.allocator;
    var state: ComparePageState = .{};
    defer state.deinit(allocator);
    _ = state.activate(9);
    const initial = state.beginRefresh().?;
    var initial_finished = try loadedDiffFinished(allocator, initial.identity, initial.generation, 'a', 'b', compare_test_diff);
    defer initial_finished.deinit(allocator);
    _ = try state.applyLoadFinished(allocator, 9, "/repo", &initial_finished);

    if (state.base_target) |*target| target.deinit(allocator);
    state.base_target = .{
        .full_ref = try allocator.dupe(u8, "refs/heads/topic"),
        .display_name = try allocator.dupe(u8, "topic"),
        .kind = .local,
    };
    const retry = state.beginRefresh().?;
    var failure = try basisFailedFinished(allocator, retry.identity, retry.generation, "topic");
    defer failure.deinit(allocator);
    try std.testing.expectEqual(LoadAcceptance.basis_failed, try state.applyLoadFinished(allocator, 9, "/repo", &failure));

    try std.testing.expectEqualStrings("main", state.basis.?.base.display_name);
    try std.testing.expect(state.load.state == .loaded);
    try std.testing.expectEqualStrings("topic", state.basis_failure.?.attempted.display_name);
    try std.testing.expectEqualStrings("topic", state.base_target.?.display_name);
}

fn testBranchList(allocator: std.mem.Allocator, name: []const u8) !git_backend.BranchList {
    const branches = try allocator.alloc(git_backend.BranchListItem, 1);
    errdefer allocator.free(branches);
    branches[0] = .{
        .full_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{name}),
        .name = try allocator.dupe(u8, name),
        .kind = .local,
        .oid = try allocator.dupe(u8, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        .current = false,
    };
    return .{ .branches = branches };
}

test "Compare base picker replacement close and selection have one owner" {
    const allocator = std.testing.allocator;
    var state: ComparePageState = .{};
    defer state.deinit(allocator);
    _ = state.activate(11);

    const first = state.beginBasePicker(allocator).?;
    var first_finished: app_load.CompareBranchListFinished = .{
        .identity = first.identity,
        .generation = first.generation,
        .result = .{ .loaded = try testBranchList(allocator, "main") },
    };
    defer first_finished.deinit(allocator);
    try std.testing.expect(state.base_picker.acceptFinished(allocator, 11, &state.activation, &first_finished));
    try std.testing.expect(first_finished.result == .empty);

    const replacement = state.beginBasePicker(allocator).?;
    try std.testing.expect(state.base_picker.accepted == null);
    var stale: app_load.CompareBranchListFinished = .{
        .identity = first.identity,
        .generation = first.generation,
        .result = .{ .loaded = try testBranchList(allocator, "stale") },
    };
    defer stale.deinit(allocator);
    try std.testing.expect(!state.base_picker.acceptFinished(allocator, 11, &state.activation, &stale));

    var wrong_epoch: app_load.CompareBranchListFinished = .{
        .identity = replacement.identity,
        .generation = replacement.generation,
        .result = .{ .loaded = try testBranchList(allocator, "wrong-epoch") },
    };
    defer wrong_epoch.deinit(allocator);
    try std.testing.expect(!state.base_picker.acceptFinished(allocator, 12, &state.activation, &wrong_epoch));

    var wrong_activation: app_load.CompareBranchListFinished = .{
        .identity = page.RequestIdentity.compare(11, replacement.identity.activation_id + 1),
        .generation = replacement.generation,
        .result = .{ .loaded = try testBranchList(allocator, "wrong-activation") },
    };
    defer wrong_activation.deinit(allocator);
    try std.testing.expect(!state.base_picker.acceptFinished(allocator, 11, &state.activation, &wrong_activation));

    var replacement_finished: app_load.CompareBranchListFinished = .{
        .identity = replacement.identity,
        .generation = replacement.generation,
        .result = .{ .loaded = try testBranchList(allocator, "topic") },
    };
    defer replacement_finished.deinit(allocator);
    try std.testing.expect(state.base_picker.acceptFinished(allocator, 11, &state.activation, &replacement_finished));
    try std.testing.expect(try state.chooseBasePickerTarget(allocator));
    try std.testing.expect(!state.base_picker.open);
    try std.testing.expect(state.base_picker.accepted == null);
    try std.testing.expectEqualStrings("refs/heads/topic", state.base_target.?.full_ref);
}
