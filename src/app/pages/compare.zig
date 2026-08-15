//! Retained state owner for the read-only Compare page.
//!
//! The page owns an accepted basis and committed-diff body as one snapshot,
//! plus independent navigation, picker, refresh, and deferred-apply state.

const std = @import("std");
const ui = @import("chasen_ui");
const content_fingerprint = @import("../../content_fingerprint.zig");
const app_state = @import("../state.zig");
const app_prompt = @import("../prompt.zig");
const diff_basis = @import("../diff_basis.zig");
const diff_surface = @import("../diff_surface.zig");
const app_load = @import("../load.zig");
const load_state = @import("../load_state.zig");
const page = @import("../page.zig");
const diff_selection = @import("../../diff/selection.zig");
const diff_source = @import("../../diff/source.zig");
const file_tree = @import("../../file_tree.zig");
const git_refs = @import("../../git/refs.zig");
const review_state = @import("../../review/state.zig");
const root_capability = @import("../../repo/root_capability.zig");
const commit_time = @import("../branch_commit_time.zig");

pub const selection_source: diff_source.SourceMode = .{ .range = "compare" };

fn optionalRootIdentityEql(left: ?root_capability.Identity, right: ?root_capability.Identity) bool {
    if (left == null or right == null) return left == null and right == null;
    return left.?.eql(right.?);
}

pub const BasePickerRequest = struct {
    identity: page.RequestIdentity,
    generation: u64,
};

/// Page-owned modal list. Pending task ownership remains independent: closing
/// advances the generation, while the eventual stale Finished owns cleanup.
pub const BasePickerState = struct {
    pub const InputMode = enum { command, query };

    pub const Failure = union(enum) {
        owned: []u8,
        static: []const u8,

        pub fn text(self: Failure) []const u8 {
            return switch (self) {
                .owned => |message| message,
                .static => |message| message,
            };
        }

        pub fn deinit(self: Failure, allocator: std.mem.Allocator) void {
            switch (self) {
                .owned => |message| allocator.free(message),
                .static => {},
            }
        }
    };

    open: bool = false,
    loading: bool = false,
    generation: u64 = 0,
    accepted: ?git_refs.BranchList = null,
    filter: ui.ListFilter = .{},
    query: app_prompt.TextInput = .{},
    input_mode: InputMode = .command,
    render_now_unix: ?i64 = null,
    failure: ?Failure = null,

    pub fn begin(self: *BasePickerState, allocator: std.mem.Allocator, identity: page.RequestIdentity) BasePickerRequest {
        self.clearAccepted(allocator);
        self.clearFailure(allocator);
        self.open = true;
        self.loading = true;
        self.query = .{};
        self.input_mode = .command;
        self.render_now_unix = null;
        self.advanceGeneration();
        return .{ .identity = identity, .generation = self.generation };
    }

    pub fn close(self: *BasePickerState, allocator: std.mem.Allocator) void {
        self.clearAccepted(allocator);
        self.clearFailure(allocator);
        self.open = false;
        self.loading = false;
        self.query = .{};
        self.input_mode = .command;
        self.render_now_unix = null;
        self.advanceGeneration();
    }

    pub fn moveSelection(self: *BasePickerState, delta: isize) void {
        const len = self.filter.source_indexes.len;
        if (len == 0) return;
        if (delta < 0) {
            if (self.filter.list.focusedIndex() == 0) {
                self.filter.list.focus.index = len - 1;
            } else {
                self.filter.update(.move_prev);
            }
        } else if (delta > 0) {
            if (self.filter.list.focusedIndex() + 1 == len) {
                self.filter.list.focus.index = 0;
            } else {
                self.filter.update(.move_next);
            }
        }
    }

    pub fn markStaticFailure(self: *BasePickerState, allocator: std.mem.Allocator, comptime message: []const u8) void {
        self.loading = false;
        self.clearAccepted(allocator);
        self.clearFailure(allocator);
        self.query = .{};
        self.input_mode = .command;
        self.failure = .{ .static = message };
    }

    pub fn failureText(self: *const BasePickerState) ?[]const u8 {
        return if (self.failure) |failure| failure.text() else null;
    }

    pub fn visibleCount(self: *const BasePickerState) usize {
        return self.filter.source_indexes.len;
    }

    pub fn selectedSourceIndex(self: *const BasePickerState) ?usize {
        if (self.filter.source_indexes.len == 0) return null;
        return self.filter.sourceIndex(self.filter.list.focusedIndex());
    }

    pub fn selectedItem(self: *const BasePickerState) ?*const git_refs.BranchListItem {
        const list = if (self.accepted) |*value| value else return null;
        const source_index = self.selectedSourceIndex() orelse return null;
        if (source_index >= list.branches.len) return null;
        return &list.branches[source_index];
    }

    pub fn enterQuery(self: *BasePickerState) void {
        if (self.accepted == null) return;
        self.input_mode = .query;
    }

    pub fn leaveQuery(self: *BasePickerState) void {
        self.input_mode = .command;
    }

    pub fn insertQuery(self: *BasePickerState, allocator: std.mem.Allocator, codepoint: u21) !void {
        var next = self.query;
        try next.insert(codepoint);
        try self.publishQuery(allocator, next);
    }

    pub fn backspaceQuery(self: *BasePickerState, allocator: std.mem.Allocator) !void {
        var next = self.query;
        next.backspace();
        try self.publishQuery(allocator, next);
    }

    pub fn clearQuery(self: *BasePickerState, allocator: std.mem.Allocator) !void {
        try self.publishQuery(allocator, .{});
        self.input_mode = .command;
    }

    pub fn prepareModalRedraw(self: *BasePickerState, io: std.Io) void {
        self.render_now_unix = commit_time.sampleUnixSeconds(io);
    }

    pub fn selectedTarget(self: *const BasePickerState, allocator: std.mem.Allocator) !?diff_basis.BaseTarget {
        const item = (self.selectedItem() orelse return null).*;
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
            .loaded => |*list| {
                commit_time.sortBranches(list.branches);
                var next_filter: ui.ListFilter = .{};
                defer next_filter.deinit(allocator);
                self.prepareFilter(allocator, list, &next_filter, "") catch {
                    self.clearAccepted(allocator);
                    self.query = .{};
                    self.input_mode = .command;
                    self.failure = .{ .static = "Could not prepare branch filter" };
                    return true;
                };

                self.clearAccepted(allocator);
                self.accepted = list.*;
                finished.result = .empty;
                self.filter = next_filter;
                next_filter = .{};
                self.query = .{};
                self.input_mode = .command;
            },
            .failed => |message| {
                self.clearAccepted(allocator);
                self.query = .{};
                self.input_mode = .command;
                self.failure = .{ .owned = message };
                finished.result = .empty;
            },
            .failed_static => |message| {
                self.clearAccepted(allocator);
                self.query = .{};
                self.input_mode = .command;
                self.failure = .{ .static = message };
            },
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
        self.filter.deinit(allocator);
        self.filter = .{};
        if (self.accepted) |*list| list.deinit(allocator);
        self.accepted = null;
    }

    fn clearFailure(self: *BasePickerState, allocator: std.mem.Allocator) void {
        if (self.failure) |failure| failure.deinit(allocator);
        self.failure = null;
    }

    fn publishQuery(self: *BasePickerState, allocator: std.mem.Allocator, next_query: app_prompt.TextInput) !void {
        const list = if (self.accepted) |*value| value else return;
        var next_filter: ui.ListFilter = .{};
        errdefer next_filter.deinit(allocator);
        try self.prepareFilter(allocator, list, &next_filter, next_query.slice());

        self.filter.deinit(allocator);
        self.filter = next_filter;
        self.query = next_query;
    }

    fn prepareFilter(
        self: *const BasePickerState,
        allocator: std.mem.Allocator,
        list: *const git_refs.BranchList,
        destination: *ui.ListFilter,
        query_text: []const u8,
    ) !void {
        _ = self;
        const labels = try allocator.alloc([]const u8, list.branches.len);
        defer allocator.free(labels);
        for (list.branches, labels) |branch, *label| label.* = branch.full_ref;
        try destination.apply(allocator, labels, query_text);
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

/// Immutable Compare authority captured when a completed selection is
/// installed. Copy/Clear admission requires all three object ids to remain
/// equal to the currently accepted Compare snapshot.
pub const PinnedSelectionBasis = struct {
    base_oid: diff_basis.Oid,
    head_oid: diff_basis.Oid,
    diff_base_oid: diff_basis.Oid,

    pub fn init(basis: diff_basis.BranchDiffBasis) PinnedSelectionBasis {
        return .{
            .base_oid = basis.base.oid,
            .head_oid = basis.head_oid,
            .diff_base_oid = basis.merge_base_oid,
        };
    }

    pub fn eql(self: PinnedSelectionBasis, other: PinnedSelectionBasis) bool {
        return self.base_oid.eql(&other.base_oid) and
            self.head_oid.eql(&other.head_oid) and
            self.diff_base_oid.eql(&other.diff_base_oid);
    }
};

/// Display-admission evidence captured with one accepted Compare bundle.
/// This is not repository or Git operation authority.
pub const AcceptedRepositoryIdentity = struct {
    repo_epoch: u64,
    root_identity: ?root_capability.Identity,

    pub fn matches(
        self: AcceptedRepositoryIdentity,
        repo_epoch: u64,
        root_identity: ?root_capability.Identity,
    ) bool {
        return self.repo_epoch == repo_epoch and
            optionalRootIdentityEql(self.root_identity, root_identity);
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
    selection_layout_revision: u64 = 1,
    pinned_selection_basis: ?PinnedSelectionBasis = null,

    // Compare-owned basis and refresh state.
    basis: ?diff_basis.BranchDiffBasis = null,
    accepted_repository_identity: ?AcceptedRepositoryIdentity = null,
    base_target: ?diff_basis.BaseTarget = null,
    basis_failure: ?BasisFailureState = null,
    load_failure: ?[]u8 = null,
    base_picker: BasePickerState = .{},
    refresh_generation: u64 = 0,
    deferred_load_apply: ?DeferredLoadApply = null,
    refresh_anchor: ?diff_surface.ReloadAnchor = null,

    pub fn activate(self: *ComparePageState, repo_epoch: u64) u64 {
        if (self.accepted_repository_identity) |identity| {
            if (identity.repo_epoch != repo_epoch) self.accepted_repository_identity = null;
        }
        return self.activation.activate(repo_epoch, .pending, .unavailable, .unavailable);
    }

    pub fn deactivate(self: *ComparePageState) void {
        self.activation.deactivate();
    }

    pub fn advanceSelectionLayoutRevision(self: *ComparePageState) void {
        self.selection_layout_revision +%= 1;
        if (self.selection_layout_revision == 0) self.selection_layout_revision = 1;
    }

    pub fn retainedSelectionInstallAvailable(self: *const ComparePageState) bool {
        return self.currentPinnedBasis() != null and self.load.state == .loaded;
    }

    pub fn retainedSelectionAdmitted(self: *const ComparePageState) bool {
        const pinned = self.pinned_selection_basis orelse return false;
        const current = self.currentPinnedBasis() orelse return false;
        return pinned.eql(current);
    }

    pub fn installPinnedSelectionBasis(self: *ComparePageState) bool {
        const current = self.currentPinnedBasis() orelse return false;
        self.pinned_selection_basis = current;
        return true;
    }

    pub fn clearRetainedSelection(self: *ComparePageState, allocator: std.mem.Allocator) void {
        if (self.completed_selection) |*selection| selection.deinit(allocator);
        self.completed_selection = null;
        self.pinned_selection_basis = null;
        self.selection_owner = .none;
    }

    fn currentPinnedBasis(self: *const ComparePageState) ?PinnedSelectionBasis {
        return .init(self.basis orelse return null);
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
        self.accepted_repository_identity = null;
        return true;
    }

    pub fn applyLoadFinished(
        self: *ComparePageState,
        allocator: std.mem.Allocator,
        repo_epoch: u64,
        repo_root: ?[]const u8,
        root_identity: ?root_capability.Identity,
        finished: *app_load.CompareLoadFinished,
    ) !LoadAcceptance {
        if (!self.acceptsLoadFinished(repo_epoch, finished.*)) return .stale;

        return switch (finished.result) {
            .loaded => |*bundle| result: {
                try self.commitLoaded(allocator, repo_epoch, repo_root, root_identity, bundle);
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
        self.accepted_repository_identity = null;
        self.clearRetainedSelection(allocator);
        self.load.replaceEmpty(allocator, .no_repository);
        self.resetAcceptedDisplayNavigation();
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
        repo_epoch: u64,
        repo_root: ?[]const u8,
        root_identity: ?root_capability.Identity,
        bundle: *app_load.CompareLoadedBundle,
    ) !void {
        const transfer_selection = self.retainedSelectionTransfers(
            repo_epoch,
            root_identity,
            &bundle.basis,
            &bundle.diff,
        );
        const pair_changed = if (self.basis) |current|
            !current.base.oid.eql(&bundle.basis.base.oid) or
                !current.merge_base_oid.eql(&bundle.basis.merge_base_oid) or
                !current.head_oid.eql(&bundle.basis.head_oid)
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
        if (!transfer_selection) self.clearRetainedSelection(allocator);
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
            self.resetAcceptedDisplayNavigation();
        }
        if (default_target) |target| {
            self.base_target = target;
            default_target = null;
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
                .source = diff_surface.selection.SourceBasis.init(selection_source),
                .source_session_revision = self.source_session_revision,
                .display = .{ .loaded = content_fingerprint.Fingerprint.init(loaded.text) },
            };
            self.pinned_selection_basis = PinnedSelectionBasis.init(self.basis.?);
        }
        self.accepted_repository_identity = .{
            .repo_epoch = repo_epoch,
            .root_identity = root_identity,
        };
        self.clearBasisFailure(allocator);
        self.clearLoadFailure(allocator);
    }

    /// Once an accepted terminal has no selectable body, no presentation-row
    /// ordinal may survive as future source navigation. This mirrors Review's
    /// destructive display reset without importing shared geometry here.
    fn resetAcceptedDisplayNavigation(self: *ComparePageState) void {
        self.viewer.diff_scroll = 0;
        self.viewer.diff_horizontal_scroll = 0;
        self.viewer.sidebar_horizontal_scroll = 0;
        self.viewer.diff_cursor = .{ .metadata = 0 };
        self.search.match = null;
        self.search.match_offset = null;
    }

    fn retainedSelectionTransfers(
        self: *const ComparePageState,
        repo_epoch: u64,
        root_identity: ?root_capability.Identity,
        incoming_basis: *const diff_basis.BranchDiffBasis,
        incoming_diff: *const app_load.CompareDiffBundle,
    ) bool {
        const completed = self.completed_selection orelse return false;
        const pinned = self.pinned_selection_basis orelse return false;
        const current_basis = self.basis orelse return false;
        if (!pinned.eql(PinnedSelectionBasis.init(current_basis)) or
            !pinned.eql(PinnedSelectionBasis.init(incoming_basis.*))) return false;
        if (completed.token.repo_epoch != repo_epoch or
            !optionalRootIdentityEql(completed.token.root_identity, root_identity) or
            !completed.token.source.eql(diff_surface.selection.SourceBasis.init(selection_source)) or
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
            .selection_layout_revision = &self.selection_layout_revision,
            .reload_anchor = if (self.refresh_anchor) |*anchor| anchor else null,
            .live_drag_deferred_source = self.deferred_load_apply != null,
            .selection_completion_policy = .retain_with_actions,
            .retained_selection_install_available = self.retainedSelectionInstallAvailable(),
            .retained_selection_action_admitted = self.retainedSelectionAdmitted(),
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
            .selection_layout_revision = &self.selection_layout_revision,
            .reload_anchor = if (self.refresh_anchor) |*anchor| anchor else null,
            .live_drag_deferred_source = self.deferred_load_apply != null,
            .selection_completion_policy = .retain_with_actions,
            .retained_selection_install_available = self.retainedSelectionInstallAvailable(),
            .retained_selection_action_admitted = self.retainedSelectionAdmitted(),
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

    try std.testing.expectEqual(LoadAcceptance.stale, try state.applyLoadFinished(allocator, 9, null, null, &finished));
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

    try std.testing.expectEqual(LoadAcceptance.stale, try state.applyLoadFinished(allocator, 9, null, null, &finished));
}

test "Compare rejects a completion with stale generation" {
    const allocator = std.testing.allocator;
    var state: ComparePageState = .{};
    defer state.deinit(allocator);
    _ = state.activate(9);
    const request = state.beginRefresh().?;
    var finished = try failedFinished(allocator, request.identity, request.generation + 1, "old generation");
    defer finished.deinit(allocator);

    try std.testing.expectEqual(LoadAcceptance.stale, try state.applyLoadFinished(allocator, 9, null, null, &finished));
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

    try std.testing.expectEqual(LoadAcceptance.stale, try state.applyLoadFinished(allocator, 4, null, null, &old_finished));
    try std.testing.expectEqual(LoadAcceptance.failed, try state.applyLoadFinished(allocator, 4, null, null, &current_finished));
}

test "Compare moves attempted failure, replaces it, and clears it on success" {
    const allocator = std.testing.allocator;
    var state: ComparePageState = .{};
    defer state.deinit(allocator);
    _ = state.activate(6);

    const first = state.beginRefresh().?;
    var first_finished = try basisFailedFinished(allocator, first.identity, first.generation, "missing-a");
    defer first_finished.deinit(allocator);
    try std.testing.expectEqual(LoadAcceptance.basis_failed, try state.applyLoadFinished(allocator, 6, null, null, &first_finished));
    try std.testing.expect(first_finished.result == .empty);
    try std.testing.expectEqualStrings("missing-a", state.basis_failure.?.attempted.display_name);

    const second = state.beginRefresh().?;
    var second_finished = try basisFailedFinished(allocator, second.identity, second.generation, "missing-b");
    defer second_finished.deinit(allocator);
    try std.testing.expectEqual(LoadAcceptance.basis_failed, try state.applyLoadFinished(allocator, 6, null, null, &second_finished));
    try std.testing.expectEqualStrings("missing-b", state.basis_failure.?.attempted.display_name);

    const third = state.beginRefresh().?;
    var success = try loadedFinished(allocator, third.identity, third.generation);
    defer success.deinit(allocator);
    try std.testing.expectEqual(LoadAcceptance.loaded, try state.applyLoadFinished(allocator, 6, null, null, &success));
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

const compare_test_diff_changed =
    "diff --git a/src/old.zig b/src/old.zig\n" ++
    "--- a/src/old.zig\n" ++
    "+++ b/src/old.zig\n" ++
    "@@ -1 +1 @@\n" ++
    "-old\n" ++
    "+newer\n";

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

fn installTestRetainedSelection(
    state: *ComparePageState,
    allocator: std.mem.Allocator,
    repo_epoch: u64,
    root_identity: ?root_capability.Identity,
) !void {
    const loaded = switch (state.load.state) {
        .loaded => |*session| &session.loaded,
        else => return error.ExpectedLoadedCompare,
    };
    const drag: diff_selection.DragSelection = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "src/old.zig" } },
        .side = .new,
        .mode = .line,
        .anchor = .{ .hunk_index = 0, .line_index = 1 },
        .focus = .{ .hunk_index = 0, .line_index = 1 },
        .moved = true,
    };
    state.completed_selection = try diff_surface.selection.buildParsed(allocator, .{
        .repo_epoch = repo_epoch,
        .root_identity = root_identity,
        .source = diff_surface.selection.SourceBasis.init(selection_source),
        .source_session_revision = state.source_session_revision,
        .display = .{ .loaded = content_fingerprint.Fingerprint.init(loaded.text) },
    }, loaded.document.files[0], drag);
    state.pinned_selection_basis = PinnedSelectionBasis.init(state.basis.?);
}

test "Compare loaded acceptance atomically installs matching basis and diff" {
    const allocator = std.testing.allocator;
    var state: ComparePageState = .{};
    defer state.deinit(allocator);
    _ = state.activate(5);
    const request = state.beginRefresh().?;
    var finished = try loadedDiffFinished(allocator, request.identity, request.generation, 'a', 'b', compare_test_diff);
    defer finished.deinit(allocator);

    try std.testing.expectEqual(LoadAcceptance.loaded, try state.applyLoadFinished(allocator, 5, "/work/gitframe", null, &finished));
    try std.testing.expectEqualStrings("main", state.basis.?.base.display_name);
    try std.testing.expectEqualStrings("refs/heads/main", state.base_target.?.full_ref);
    try std.testing.expect(state.accepted_repository_identity.?.matches(5, null));
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

test "Compare reload transfers retained selection only across the exact repository basis and diff" {
    const allocator = std.testing.allocator;
    const root_identity: root_capability.Identity = .{ .device = 3, .inode = 7 };
    const cases = [_]struct {
        name: []const u8,
        base: u8 = 'a',
        diff_base: u8 = 'a',
        head: u8 = 'b',
        root: root_capability.Identity = root_identity,
        diff: []const u8 = compare_test_diff,
        empty: bool = false,
        transfers: bool,
    }{
        .{ .name = "exact", .transfers = true },
        .{ .name = "base", .base = 'c', .transfers = false },
        .{ .name = "diff-base", .diff_base = 'd', .transfers = false },
        .{ .name = "head", .head = 'e', .transfers = false },
        .{ .name = "root", .root = .{ .device = 3, .inode = 8 }, .transfers = false },
        .{ .name = "content", .diff = compare_test_diff_changed, .transfers = false },
        .{ .name = "empty", .empty = true, .transfers = false },
    };

    for (cases) |case| {
        var state: ComparePageState = .{};
        defer state.deinit(allocator);
        _ = state.activate(11);
        const first = state.beginRefresh().?;
        var first_finished = try loadedDiffFinished(allocator, first.identity, first.generation, 'a', 'b', compare_test_diff);
        defer first_finished.deinit(allocator);
        _ = try state.applyLoadFinished(allocator, 11, "/repo", root_identity, &first_finished);
        try installTestRetainedSelection(&state, allocator, 11, root_identity);
        const old_revision = state.source_session_revision;

        const second = state.beginRefresh().?;
        var second_finished = if (case.empty)
            try loadedFinished(allocator, second.identity, second.generation)
        else
            try loadedDiffFinished(allocator, second.identity, second.generation, case.base, case.head, case.diff);
        defer second_finished.deinit(allocator);
        if (case.empty) {
            state.viewer.diff_scroll = 17;
            state.viewer.diff_horizontal_scroll = 6;
            state.viewer.sidebar_horizontal_scroll = 3;
            state.viewer.diff_cursor = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 1 } };
        }
        second_finished.result.loaded.basis.base.oid = testOid(case.base);
        second_finished.result.loaded.basis.merge_base_oid = testOid(case.diff_base);
        second_finished.result.loaded.basis.head_oid = testOid(case.head);
        try std.testing.expectEqual(
            LoadAcceptance.loaded,
            try state.applyLoadFinished(allocator, 11, "/repo", case.root, &second_finished),
        );
        try std.testing.expectEqual(case.transfers, state.completed_selection != null);
        try std.testing.expectEqual(case.transfers, state.pinned_selection_basis != null);
        if (case.transfers) {
            try std.testing.expect(state.retainedSelectionAdmitted());
            try std.testing.expect(state.completed_selection.?.token.source_session_revision != old_revision);
            try std.testing.expect(optionalRootIdentityEql(state.completed_selection.?.token.root_identity, case.root));
        }
        if (case.empty) {
            try std.testing.expectEqual(@as(usize, 0), state.viewer.diff_scroll);
            try std.testing.expectEqual(@as(usize, 0), state.viewer.diff_horizontal_scroll);
            try std.testing.expectEqual(@as(usize, 0), state.viewer.sidebar_horizontal_scroll);
            switch (state.viewer.diff_cursor) {
                .metadata => |offset| try std.testing.expectEqual(@as(usize, 0), offset),
                else => return error.ExpectedResetDiffCursor,
            }
        }
        _ = case.name;
    }
}

test "Compare failed and stale refreshes preserve the accepted retained selection" {
    const allocator = std.testing.allocator;
    const root_identity: root_capability.Identity = .{ .device = 5, .inode = 9 };
    var state: ComparePageState = .{};
    defer state.deinit(allocator);
    _ = state.activate(13);
    const initial = state.beginRefresh().?;
    var initial_finished = try loadedDiffFinished(allocator, initial.identity, initial.generation, 'a', 'b', compare_test_diff);
    defer initial_finished.deinit(allocator);
    _ = try state.applyLoadFinished(allocator, 13, "/repo", root_identity, &initial_finished);
    try installTestRetainedSelection(&state, allocator, 13, root_identity);
    const retained_token = state.completed_selection.?.token;
    const retained_pin = state.pinned_selection_basis.?;
    const retained_revision = state.source_session_revision;

    const failed_request = state.beginRefresh().?;
    var failure = try basisFailedFinished(allocator, failed_request.identity, failed_request.generation, "missing");
    defer failure.deinit(allocator);
    try std.testing.expectEqual(
        LoadAcceptance.basis_failed,
        try state.applyLoadFinished(allocator, 13, "/repo", root_identity, &failure),
    );
    try std.testing.expect(state.completed_selection.?.token.eql(retained_token));
    try std.testing.expect(state.pinned_selection_basis.?.eql(retained_pin));

    const stale_request = state.beginRefresh().?;
    _ = state.beginRefresh().?;
    var stale = try loadedDiffFinished(allocator, stale_request.identity, stale_request.generation, 'c', 'd', compare_test_diff_changed);
    defer stale.deinit(allocator);
    try std.testing.expectEqual(
        LoadAcceptance.stale,
        try state.applyLoadFinished(allocator, 13, "/repo", root_identity, &stale),
    );
    try std.testing.expect(state.completed_selection.?.token.eql(retained_token));
    try std.testing.expect(state.pinned_selection_basis.?.eql(retained_pin));
    try std.testing.expectEqual(retained_revision, state.source_session_revision);

    state.viewer.diff_scroll = 13;
    state.viewer.diff_horizontal_scroll = 5;
    state.viewer.sidebar_horizontal_scroll = 2;
    state.markNoRepository(allocator);
    try std.testing.expect(state.completed_selection == null);
    try std.testing.expect(state.pinned_selection_basis == null);
    try std.testing.expectEqual(@as(usize, 0), state.viewer.diff_scroll);
    try std.testing.expectEqual(@as(usize, 0), state.viewer.diff_horizontal_scroll);
    try std.testing.expectEqual(@as(usize, 0), state.viewer.sidebar_horizontal_scroll);
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
        _ = try state.applyLoadFinished(allocator, 7, "/repo", null, &first_finished);
        const first_loaded = switch (state.load.state) {
            .loaded => |*session| &session.loaded,
            else => return error.ExpectedLoadedCompare,
        };
        try state.reviewed_store.set(allocator, "/repo", first_loaded.document.files[0], true);
        first_loaded.reviewed_files[0] = true;

        const second = state.beginRefresh().?;
        var second_finished = try loadedDiffFinished(allocator, second.identity, second.generation, case.base, case.head, compare_test_diff);
        defer second_finished.deinit(allocator);
        _ = try state.applyLoadFinished(allocator, 7, "/repo", null, &second_finished);
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
    _ = try state.applyLoadFinished(allocator, 9, "/repo", null, &initial_finished);

    if (state.base_target) |*target| target.deinit(allocator);
    state.base_target = .{
        .full_ref = try allocator.dupe(u8, "refs/heads/topic"),
        .display_name = try allocator.dupe(u8, "topic"),
        .kind = .local,
    };
    const retry = state.beginRefresh().?;
    var failure = try basisFailedFinished(allocator, retry.identity, retry.generation, "topic");
    defer failure.deinit(allocator);
    try std.testing.expectEqual(LoadAcceptance.basis_failed, try state.applyLoadFinished(allocator, 9, "/repo", null, &failure));

    try std.testing.expectEqualStrings("main", state.basis.?.base.display_name);
    try std.testing.expect(state.load.state == .loaded);
    try std.testing.expectEqualStrings("topic", state.basis_failure.?.attempted.display_name);
    try std.testing.expectEqualStrings("topic", state.base_target.?.display_name);
}

fn testBranchList(allocator: std.mem.Allocator, name: []const u8) !git_refs.BranchList {
    const branches = try allocator.alloc(git_refs.BranchListItem, 1);
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

const TestBranch = struct {
    full_ref: []const u8,
    name: []const u8,
    kind: git_refs.BranchKind = .local,
    timestamp: ?i64,
};

fn testBranchListFrom(allocator: std.mem.Allocator, specs: []const TestBranch) !git_refs.BranchList {
    const branches = try allocator.alloc(git_refs.BranchListItem, specs.len);
    var initialized: usize = 0;
    errdefer {
        for (branches[0..initialized]) |item| {
            allocator.free(item.full_ref);
            allocator.free(item.name);
            allocator.free(item.oid);
        }
        allocator.free(branches);
    }
    for (specs, branches) |spec, *branch| {
        const full_ref = try allocator.dupe(u8, spec.full_ref);
        errdefer allocator.free(full_ref);
        const name = try allocator.dupe(u8, spec.name);
        errdefer allocator.free(name);
        const oid = try allocator.dupe(u8, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        branch.* = .{
            .full_ref = full_ref,
            .name = name,
            .kind = spec.kind,
            .oid = oid,
            .tip_committer_unix = spec.timestamp,
        };
        initialized += 1;
    }
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

test "Compare picker and failed chosen-basis refresh retain the accepted selection authority" {
    const allocator = std.testing.allocator;
    var state: ComparePageState = .{};
    defer state.deinit(allocator);
    _ = state.activate(23);
    const initial = state.beginRefresh().?;
    var initial_finished = try loadedDiffFinished(
        allocator,
        initial.identity,
        initial.generation,
        'a',
        'b',
        compare_test_diff,
    );
    defer initial_finished.deinit(allocator);
    try std.testing.expectEqual(
        LoadAcceptance.loaded,
        try state.applyLoadFinished(allocator, 23, "/repo", null, &initial_finished),
    );
    try installTestRetainedSelection(&state, allocator, 23, null);
    const retained_token = state.completed_selection.?.token;
    const retained_pin = state.pinned_selection_basis.?;
    const retained_revision = state.source_session_revision;

    const opened = state.beginBasePicker(allocator).?;
    try std.testing.expect(state.base_picker.open);
    try std.testing.expect(state.base_picker.loading);
    try std.testing.expect(state.completed_selection.?.token.eql(retained_token));
    try std.testing.expect(state.pinned_selection_basis.?.eql(retained_pin));
    var opened_finished: app_load.CompareBranchListFinished = .{
        .identity = opened.identity,
        .generation = opened.generation,
        .result = .{ .loaded = try testBranchList(allocator, "topic") },
    };
    defer opened_finished.deinit(allocator);
    try std.testing.expect(state.base_picker.acceptFinished(
        allocator,
        23,
        &state.activation,
        &opened_finished,
    ));
    state.base_picker.enterQuery();
    for ("top") |byte| try state.base_picker.insertQuery(allocator, byte);
    try std.testing.expectEqual(@as(usize, 1), state.base_picker.visibleCount());
    try std.testing.expect(state.completed_selection.?.token.eql(retained_token));
    try std.testing.expect(state.pinned_selection_basis.?.eql(retained_pin));
    try std.testing.expect(state.retainedSelectionAdmitted());

    state.closeBasePicker(allocator);
    try std.testing.expect(!state.base_picker.open);
    try std.testing.expect(state.completed_selection.?.token.eql(retained_token));
    try std.testing.expect(state.pinned_selection_basis.?.eql(retained_pin));

    const chosen = state.beginBasePicker(allocator).?;
    var chosen_finished: app_load.CompareBranchListFinished = .{
        .identity = chosen.identity,
        .generation = chosen.generation,
        .result = .{ .loaded = try testBranchList(allocator, "topic") },
    };
    defer chosen_finished.deinit(allocator);
    try std.testing.expect(state.base_picker.acceptFinished(
        allocator,
        23,
        &state.activation,
        &chosen_finished,
    ));
    try std.testing.expect(try state.chooseBasePickerTarget(allocator));
    try std.testing.expectEqualStrings("refs/heads/topic", state.base_target.?.full_ref);
    try std.testing.expect(state.accepted_repository_identity == null);
    try std.testing.expect(state.completed_selection.?.token.eql(retained_token));
    try std.testing.expect(state.pinned_selection_basis.?.eql(retained_pin));

    const pending = state.beginRefresh().?;
    try std.testing.expect(state.completed_selection.?.token.eql(retained_token));
    try std.testing.expect(state.pinned_selection_basis.?.eql(retained_pin));
    try std.testing.expectEqual(retained_revision, state.source_session_revision);
    var failure = try failedFinished(allocator, pending.identity, pending.generation, "chosen basis failed");
    defer failure.deinit(allocator);
    try std.testing.expectEqual(
        LoadAcceptance.failed,
        try state.applyLoadFinished(allocator, 23, "/repo", null, &failure),
    );
    try std.testing.expect(state.completed_selection.?.token.eql(retained_token));
    try std.testing.expect(state.pinned_selection_basis.?.eql(retained_pin));
    try std.testing.expect(state.retainedSelectionAdmitted());
    try std.testing.expectEqual(retained_revision, state.source_session_revision);
    try std.testing.expectEqualStrings("main", state.basis.?.base.display_name);
}

test "Compare base picker owns recency order filter projection and full-ref activation" {
    const allocator = std.testing.allocator;
    var state: ComparePageState = .{};
    defer state.deinit(allocator);
    _ = state.activate(17);
    const request = state.beginBasePicker(allocator).?;
    var finished: app_load.CompareBranchListFinished = .{
        .identity = request.identity,
        .generation = request.generation,
        .result = .{ .loaded = try testBranchListFrom(allocator, &.{
            .{ .full_ref = "refs/heads/auth-old", .name = "auth-old", .timestamp = 100 },
            .{ .full_ref = "refs/remotes/origin/auth-new", .name = "origin/auth-new", .kind = .remote_tracking, .timestamp = 300 },
            .{ .full_ref = "refs/remotes/origin/z-tie", .name = "origin/z-tie", .kind = .remote_tracking, .timestamp = 200 },
            .{ .full_ref = "refs/heads/a-tie", .name = "a-tie", .timestamp = 200 },
            .{ .full_ref = "refs/heads/unknown", .name = "unknown", .timestamp = null },
        }) },
    };
    defer finished.deinit(allocator);

    try std.testing.expect(state.base_picker.acceptFinished(allocator, 17, &state.activation, &finished));
    try std.testing.expect(finished.result == .empty);
    const branches = state.base_picker.accepted.?.branches;
    try std.testing.expectEqualStrings("refs/remotes/origin/auth-new", branches[0].full_ref);
    try std.testing.expectEqualStrings("refs/heads/a-tie", branches[1].full_ref);
    try std.testing.expectEqualStrings("refs/remotes/origin/z-tie", branches[2].full_ref);
    try std.testing.expectEqualStrings("refs/heads/auth-old", branches[3].full_ref);
    try std.testing.expectEqualStrings("refs/heads/unknown", branches[4].full_ref);

    state.base_picker.enterQuery();
    for ("auth") |byte| try state.base_picker.insertQuery(allocator, byte);
    try std.testing.expectEqual(@as(usize, 2), state.base_picker.visibleCount());
    try std.testing.expectEqualStrings("refs/remotes/origin/auth-new", state.base_picker.selectedItem().?.full_ref);
    try state.base_picker.backspaceQuery(allocator);
    try std.testing.expectEqualStrings("aut", state.base_picker.query.slice());
    try std.testing.expectEqual(@as(usize, 2), state.base_picker.visibleCount());
    try state.base_picker.insertQuery(allocator, 'h');
    state.base_picker.moveSelection(1);
    const selected = try state.base_picker.selectedTarget(allocator) orelse return error.ExpectedBaseTarget;
    defer {
        var owned = selected;
        owned.deinit(allocator);
    }
    try std.testing.expectEqualStrings("refs/heads/auth-old", selected.full_ref);

    try state.base_picker.clearQuery(allocator);
    state.base_picker.enterQuery();
    for ("refs/remotes") |byte| try state.base_picker.insertQuery(allocator, byte);
    try std.testing.expectEqual(@as(usize, 2), state.base_picker.visibleCount());
    try std.testing.expectEqualStrings("refs/remotes/origin/auth-new", state.base_picker.selectedItem().?.full_ref);
    try state.base_picker.clearQuery(allocator);
    state.base_picker.enterQuery();
    for ("no-such-branch") |byte| try state.base_picker.insertQuery(allocator, byte);
    try std.testing.expectEqual(@as(usize, 0), state.base_picker.visibleCount());
    try std.testing.expect((try state.base_picker.selectedTarget(allocator)) == null);
}

test "Compare base picker publication allocation failure is terminal without partial ownership" {
    const allocator = std.testing.allocator;
    var state: ComparePageState = .{};
    defer state.deinit(allocator);
    _ = state.activate(19);
    const request = state.beginBasePicker(allocator).?;
    var finished: app_load.CompareBranchListFinished = .{
        .identity = request.identity,
        .generation = request.generation,
        .result = .{ .loaded = try testBranchList(allocator, "topic") },
    };
    defer finished.deinit(allocator);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });

    try std.testing.expect(state.base_picker.acceptFinished(failing.allocator(), 19, &state.activation, &finished));
    try std.testing.expect(!state.base_picker.loading);
    try std.testing.expect(state.base_picker.open);
    try std.testing.expect(state.base_picker.accepted == null);
    try std.testing.expectEqual(@as(usize, 0), state.base_picker.visibleCount());
    try std.testing.expectEqualStrings("Could not prepare branch filter", state.base_picker.failureText().?);
    try std.testing.expect(finished.result == .loaded);

    state.closeBasePicker(allocator);
    const retry = state.beginBasePicker(allocator).?;
    var retry_finished: app_load.CompareBranchListFinished = .{
        .identity = retry.identity,
        .generation = retry.generation,
        .result = .{ .loaded = try testBranchList(allocator, "retry") },
    };
    defer retry_finished.deinit(allocator);
    try std.testing.expect(state.base_picker.acceptFinished(allocator, 19, &state.activation, &retry_finished));
    try std.testing.expectEqualStrings("refs/heads/retry", state.base_picker.selectedItem().?.full_ref);

    const replacement = state.beginBasePicker(allocator).?;
    var replacement_finished: app_load.CompareBranchListFinished = .{
        .identity = replacement.identity,
        .generation = replacement.generation,
        .result = .{ .loaded = try testBranchList(allocator, "replacement") },
    };
    defer replacement_finished.deinit(allocator);
    var replacement_failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expect(state.base_picker.acceptFinished(
        replacement_failing.allocator(),
        19,
        &state.activation,
        &replacement_finished,
    ));
    try std.testing.expect(state.base_picker.accepted == null);
    try std.testing.expectEqualStrings("Could not prepare branch filter", state.base_picker.failureText().?);
    try std.testing.expect(replacement_finished.result == .loaded);
}

test "Compare base picker live query allocation failure preserves old projection byte-for-byte" {
    const allocator = std.testing.allocator;
    var state: ComparePageState = .{};
    defer state.deinit(allocator);
    _ = state.activate(23);
    const request = state.beginBasePicker(allocator).?;
    var finished: app_load.CompareBranchListFinished = .{
        .identity = request.identity,
        .generation = request.generation,
        .result = .{ .loaded = try testBranchListFrom(allocator, &.{
            .{ .full_ref = "refs/heads/alpha", .name = "alpha", .timestamp = 20 },
            .{ .full_ref = "refs/heads/beta", .name = "beta", .timestamp = 10 },
        }) },
    };
    defer finished.deinit(allocator);
    try std.testing.expect(state.base_picker.acceptFinished(allocator, 23, &state.activation, &finished));
    state.base_picker.moveSelection(1);

    const old_indexes = state.base_picker.filter.source_indexes.ptr;
    const old_labels = state.base_picker.filter.labels.ptr;
    const old_selected = state.base_picker.filter.list.focusedIndex();
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, state.base_picker.insertQuery(failing.allocator(), 'a'));

    try std.testing.expectEqual(@as(usize, 0), state.base_picker.query.len);
    try std.testing.expectEqual(old_indexes, state.base_picker.filter.source_indexes.ptr);
    try std.testing.expectEqual(old_labels, state.base_picker.filter.labels.ptr);
    try std.testing.expectEqual(old_selected, state.base_picker.filter.list.focusedIndex());
    try std.testing.expectEqual(@as(usize, 2), state.base_picker.visibleCount());
    try std.testing.expectEqualStrings("refs/heads/beta", state.base_picker.selectedItem().?.full_ref);
}
