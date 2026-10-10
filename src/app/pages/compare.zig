//! Retained state owner for live committed branch comparison.

const std = @import("std");
const ui = @import("chasen_ui");
const app_state = @import("../state.zig");
const app_prompt = @import("../prompt.zig");
const app_load = @import("../load.zig");
const committed_diff = @import("committed_diff.zig");
const diff_basis = @import("../diff_basis.zig");
const diff_surface = @import("../diff_surface.zig");
const diff_source = @import("../../diff/source.zig");
const git_refs = @import("../../git/refs.zig");
const page = @import("../page.zig");
const root_capability = @import("../../repo/root_capability.zig");
const commit_time = @import("../branch_commit_time.zig");

pub const selection_source: diff_source.SourceMode = .{ .range = "compare" };

pub const BasePickerRequest = struct {
    identity: page.RequestIdentity,
    generation: u64,
};

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
            if (self.filter.list.focusedIndex() == 0) self.filter.list.focus.index = len - 1 else self.filter.update(.move_prev);
        } else if (delta > 0) {
            if (self.filter.list.focusedIndex() + 1 == len) self.filter.list.focus.index = 0 else self.filter.update(.move_next);
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
        if (!activation.acceptsPageInstance(finished.identity, repo_epoch)) return false;

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

pub const LoadAcceptance = enum { stale, loaded, basis_failed, failed };

pub const BasisFailureState = struct {
    kind: diff_basis.BasisFailure,
    attempted: diff_basis.BaseTarget,

    pub fn deinit(self: *BasisFailureState, allocator: std.mem.Allocator) void {
        self.attempted.deinit(allocator);
        self.* = undefined;
    }
};

pub const ComparePageState = struct {
    transition_publication: @import("../screen_transition.zig").Publication = .none,
    activation: diff_surface.authority.Lifecycle = .init(.compare),
    status: app_state.StatusMessage = .{},
    diff: committed_diff.State = .{},
    basis: ?diff_basis.BranchDiffBasis = null,
    base_target: ?diff_basis.BaseTarget = null,
    basis_failure: ?BasisFailureState = null,
    load_failure: ?[]u8 = null,
    base_picker: BasePickerState = .{},
    refresh_generation: u64 = 0,
    deferred_load_apply: ?DeferredLoadApply = null,

    pub fn activate(self: *ComparePageState, repo_epoch: u64) u64 {
        if (self.diff.accepted_repository_identity) |identity| {
            if (identity.repo_epoch != repo_epoch) self.diff.accepted_repository_identity = null;
        }
        return self.activation.activate(repo_epoch, .pending, .unavailable, .unavailable);
    }

    pub fn deactivate(self: *ComparePageState) void {
        self.diff.selection_owner = .none;
        self.activation.deactivate();
    }

    pub fn currentTarget(self: *const ComparePageState) ?@import("../../git/commit_diff.zig").Target {
        return if (self.basis) |basis| basis.target else null;
    }

    pub fn hasAcceptedDisplay(self: *const ComparePageState) bool {
        return self.basis != null and self.diff.hasAcceptedDiff();
    }

    pub fn beginRefresh(self: *ComparePageState) ?RefreshRequest {
        const identity = self.activation.currentIdentity() orelse return null;
        self.refresh_generation +%= 1;
        if (self.refresh_generation == 0) self.refresh_generation = 1;
        self.activation.markPending(.source);
        if (!self.hasAcceptedDisplay()) {
            self.diff.load.clearCurrent(null);
            self.diff.load.state = .loading;
        }
        return .{ .identity = identity, .generation = self.refresh_generation };
    }

    pub fn clearRefreshFailure(self: *ComparePageState, allocator: std.mem.Allocator) void {
        self.clearBasisFailure(allocator);
        self.clearLoadFailure(allocator);
    }

    pub fn beginBasePicker(self: *ComparePageState, allocator: std.mem.Allocator) ?BasePickerRequest {
        const identity = self.activation.currentIdentity() orelse return null;
        if (self.diff.selection_owner.activeMouseSelection() or
            self.diff.selection_owner.activeKeyboardSideChoice() != null)
        {
            self.diff.selection_owner = .none;
        }
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
        self.diff.accepted_repository_identity = null;
        return true;
    }

    pub fn acceptsFinished(self: *const ComparePageState, repo_epoch: u64, finished: app_load.CompareLoadFinished) bool {
        return finished.generation == self.refresh_generation and
            self.activation.acceptsPageInstance(finished.identity, repo_epoch);
    }

    pub fn applyLoadFinished(
        self: *ComparePageState,
        allocator: std.mem.Allocator,
        repo_epoch: u64,
        repo_root: ?[]const u8,
        root_identity: ?root_capability.Identity,
        finished: *app_load.CompareLoadFinished,
    ) !LoadAcceptance {
        if (!self.acceptsFinished(repo_epoch, finished.*)) return .stale;
        return switch (finished.result) {
            .loaded => |*bundle| result: {
                try self.commitLoaded(allocator, repo_epoch, repo_root, root_identity, bundle);
                finished.result = .empty;
                _ = self.activation.finishMember(finished.identity, .source, .fresh);
                self.transition_publication = .accepted;
                break :result .loaded;
            },
            .basis_failed => |failure| result: {
                self.clearBasisFailure(allocator);
                self.basis_failure = .{ .kind = failure.kind, .attempted = failure.attempted };
                finished.result = .empty;
                self.clearLoadFailure(allocator);
                _ = self.activation.finishMember(finished.identity, .source, .failed);
                self.transition_publication = .failed;
                break :result .basis_failed;
            },
            .failed => |message| result: {
                self.replaceLoadFailure(allocator, message) catch {};
                _ = self.activation.finishMember(finished.identity, .source, .failed);
                self.transition_publication = .failed;
                break :result .failed;
            },
            .failed_static => |message| result: {
                self.replaceLoadFailure(allocator, message) catch {};
                _ = self.activation.finishMember(finished.identity, .source, .failed);
                self.transition_publication = .failed;
                break :result .failed;
            },
            .empty => result: {
                _ = self.activation.finishMember(finished.identity, .source, .failed);
                self.transition_publication = .failed;
                break :result .failed;
            },
        };
    }

    pub fn rejectRefresh(self: *ComparePageState, request: RefreshRequest, repo_epoch: u64) bool {
        if (request.generation != self.refresh_generation or
            !self.activation.acceptsPageInstance(request.identity, repo_epoch)) return false;
        _ = self.activation.finishMember(request.identity, .source, .failed);
        self.transition_publication = .failed;
        return true;
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
        self.diff.clearReloadAnchor(allocator);
    }

    pub fn markNoRepository(self: *ComparePageState, allocator: std.mem.Allocator) void {
        self.diff.accepted_repository_identity = null;
        self.diff.clearRetainedSelection(allocator);
        self.diff.load.replaceEmpty(allocator, .no_repository);
        self.diff.resetAcceptedDisplayNavigation();
        self.clearRefreshFailure(allocator);
        if (self.activation.currentIdentity()) |identity| {
            _ = self.activation.finishMember(identity, .source, .failed);
            self.transition_publication = .failed;
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

    pub fn diffSurface(self: *ComparePageState, layout: diff_surface.Layout) diff_surface.DiffSurface {
        return self.diff.diffSurface(.{
            .activation = &self.activation,
            .status = &self.status,
            .source = selection_source,
            .layout = layout,
            .current_target = self.currentTarget(),
            .live_drag_deferred_source = self.deferred_load_apply != null,
        });
    }

    pub fn readSurface(self: *const ComparePageState, layout: diff_surface.Layout) diff_surface.ReadSurface {
        return self.diff.readSurface(.{
            .activation = &self.activation,
            .status = &self.status,
            .source = selection_source,
            .layout = layout,
            .current_target = self.currentTarget(),
            .live_drag_deferred_source = self.deferred_load_apply != null,
        });
    }

    pub fn deinit(self: *ComparePageState, allocator: std.mem.Allocator) void {
        self.diff.deinit(allocator);
        if (self.basis) |*basis| basis.deinit(allocator);
        if (self.base_target) |*target| target.deinit(allocator);
        if (self.basis_failure) |*failure| failure.deinit(allocator);
        if (self.load_failure) |message| allocator.free(message);
        self.base_picker.deinit(allocator);
        if (self.deferred_load_apply) |*deferred| deferred.deinit(allocator);
        self.* = .{};
    }

    fn commitLoaded(
        self: *ComparePageState,
        allocator: std.mem.Allocator,
        repo_epoch: u64,
        repo_root: ?[]const u8,
        root_identity: ?root_capability.Identity,
        bundle: *app_load.CompareLoadedBundle,
    ) !void {
        const old_target = self.currentTarget();
        const transfer_selection = self.diff.retainedSelectionTransfers(
            repo_epoch,
            root_identity,
            selection_source,
            old_target,
            bundle.basis.target,
            &bundle.diff,
        );
        const pair_changed = if (old_target) |target| !target.eql(&bundle.basis.target) else true;

        var default_target: ?diff_basis.BaseTarget = null;
        errdefer if (default_target) |*target| target.deinit(allocator);
        if (self.base_target == null) {
            const full_ref = try allocator.dupe(u8, bundle.basis.base.full_ref);
            default_target = .{
                .full_ref = full_ref,
                .display_name = allocator.dupe(u8, bundle.basis.base.display_name) catch |err| {
                    allocator.free(full_ref);
                    return err;
                },
                .kind = bundle.basis.base.kind,
            };
        }

        try self.diff.replaceDiff(
            allocator,
            repo_epoch,
            repo_root,
            root_identity,
            selection_source,
            bundle.basis.target,
            pair_changed,
            transfer_selection,
            &bundle.diff,
        );
        if (self.basis) |*basis| basis.deinit(allocator);
        self.basis = bundle.basis;
        bundle.basis = undefined;
        if (default_target) |target| {
            self.base_target = target;
            default_target = null;
        }
        self.clearRefreshFailure(allocator);
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

    fn clearBasisFailure(self: *ComparePageState, allocator: std.mem.Allocator) void {
        if (self.basis_failure) |*failure| failure.deinit(allocator);
        self.basis_failure = null;
    }
};

test "Compare activation and retained diff state are independent" {
    const allocator = std.testing.allocator;
    var state: ComparePageState = .{};
    defer state.deinit(allocator);
    const first = state.activate(9);
    state.diff.viewer.diff_scroll = .{ .logical = 7 };
    state.deactivate();
    const second = state.activate(9);
    try std.testing.expect(first != second);
    try std.testing.expectEqual(@as(usize, 7), state.diff.viewer.diff_scroll.row());
    try std.testing.expectEqual(page.Id.compare, state.activation.currentIdentity().?.origin);
}
