//! Retained state owner for the read-only Review page.
//!
//! The page owns an accepted basis and committed-diff body as one snapshot,
//! plus independent navigation, picker, refresh, and deferred-apply state.

const std = @import("std");
const ui = @import("chasen_ui");
const committed_review = @import("../../committed_review.zig");
const finding_card = @import("../../ai_review/finding_card.zig");
const finding_projection = @import("../../ai_review/finding_projection.zig");
const content_fingerprint = @import("../../content_fingerprint.zig");
const context = @import("../../context.zig");
const app_state = @import("../state.zig");
const app_prompt = @import("../prompt.zig");
const diff_basis = @import("../diff_basis.zig");
const diff_surface = @import("../diff_surface.zig");
const app_load = @import("../load.zig");
const load_state = @import("../load_state.zig");
const page = @import("../page.zig");
const diff_selection = @import("../../diff/selection.zig");
const diff_render = @import("../../diff/render.zig");
const diff_source = @import("../../diff/source.zig");
const file_tree = @import("../../file_tree.zig");
const git_refs = @import("../../git/refs.zig");
const reviewed_files = @import("../../reviewed_files.zig");
const root_capability = @import("../../repo/root_capability.zig");
const review_store = @import("../../review_store.zig");
const commit_time = @import("../branch_commit_time.zig");
const human_review_decision = @import("review/human_review_decision.zig");

pub const selection_source: diff_source.SourceMode = .{ .range = "review" };

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
        finished: *app_load.ReviewBranchListFinished,
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

pub const AiReviewsRequest = struct {
    identity: page.RequestIdentity,
    generation: u64,
    root_identity: root_capability.Identity,
};

pub const AiReviewSelectionRequest = struct {
    request: AiReviewsRequest,
    store: review_store.StoreSnapshot,
    review_id: committed_review.ReviewId,
    artifacts: review_store.ArtifactSnapshot,
    direct: bool,
};

pub const AiReviewSelectionAdmission = union(enum) {
    none,
    unavailable,
    request: AiReviewSelectionRequest,
};

/// One keyboard-only history modal. The phase is the operation discriminator;
/// the optional scan snapshot is retained only across selection/return states
/// that must restore the ready list after cancellation or failure.
pub const AiReviewsPickerState = struct {
    pub const InputMode = enum { command, query };
    pub const EmptyKind = enum { no_reviews, invalid_only };
    pub const InteractionCapabilities = struct {
        list: bool = false,
        retry: bool = false,
        cancel: bool = false,
        close: bool = false,
    };
    pub const Phase = union(enum) {
        closed,
        scan_loading,
        ready,
        empty: EmptyKind,
        scan_failed: []const u8,
        selection_loading: struct { review_id: committed_review.ReviewId, direct: bool },
        selection_failed: struct { review_id: committed_review.ReviewId, direct: bool, message: []const u8 },
        return_loading: struct { direct: bool },
        return_failed: struct { direct: bool, message: []const u8 },
    };

    phase: Phase = .closed,
    generation: u64 = 0,
    identity: ?page.RequestIdentity = null,
    root_identity: ?root_capability.Identity = null,
    scan_result: ?review_store.ScanResult = null,
    search_labels: [][]u8 = &.{},
    filter: ui.ListFilter = .{},
    query: app_prompt.TextInput = .{},
    input_mode: InputMode = .command,
    focus: usize = 0,
    refocus_review_id: ?committed_review.ReviewId = null,
    render_now_unix: ?i64 = null,

    pub fn isOpen(self: *const AiReviewsPickerState) bool {
        return self.phase != .closed;
    }

    pub fn queryMode(self: *const AiReviewsPickerState) bool {
        return self.input_mode == .query;
    }

    pub fn loading(self: *const AiReviewsPickerState) bool {
        return switch (self.phase) {
            .scan_loading, .selection_loading, .return_loading => true,
            else => false,
        };
    }

    /// The phase and retained snapshot together are the single authority for
    /// both rendered commands and state admission.
    pub fn interactionCapabilities(self: *const AiReviewsPickerState) InteractionCapabilities {
        const retained_list = self.scan_result != null;
        return switch (self.phase) {
            .closed => .{},
            .scan_loading, .selection_loading, .return_loading => .{ .retry = true, .cancel = true },
            .ready, .empty => .{ .list = retained_list, .retry = true, .close = true },
            .scan_failed => .{ .retry = true, .close = true },
            .selection_failed, .return_failed => .{ .list = retained_list, .retry = true, .close = true },
        };
    }

    pub fn beginScan(
        self: *AiReviewsPickerState,
        allocator: std.mem.Allocator,
        identity: page.RequestIdentity,
        root_identity: root_capability.Identity,
        preferred: ?committed_review.ReviewId,
        retain_query: bool,
    ) AiReviewsRequest {
        const retained_query = if (retain_query) self.query else app_prompt.TextInput{};
        self.clearSnapshot(allocator);
        self.query = retained_query;
        self.input_mode = .command;
        self.focus = 0;
        self.refocus_review_id = preferred;
        self.render_now_unix = null;
        self.identity = identity;
        self.root_identity = root_identity;
        self.advanceGeneration();
        self.phase = .scan_loading;
        return self.currentRequest();
    }

    pub fn markScanFailure(self: *AiReviewsPickerState, message: []const u8) void {
        if (self.phase != .scan_loading) return;
        self.phase = .{ .scan_failed = message };
    }

    pub fn acceptScan(
        self: *AiReviewsPickerState,
        allocator: std.mem.Allocator,
        repo_epoch: u64,
        root_identity: ?root_capability.Identity,
        store_identity: review_store.ConfigurationIdentity,
        activation: *const diff_surface.authority.Lifecycle,
        finished: *app_load.ReviewHistoryScanFinished,
    ) bool {
        if (self.phase != .scan_loading or
            !self.accepts(finished.identity, finished.generation, repo_epoch, root_identity, store_identity, finished.store_identity, activation)) return false;

        switch (finished.result) {
            .failed_static => |message| self.phase = .{ .scan_failed = message },
            .scanned => |*result| {
                switch (result.*) {
                    .failure => |failure| {
                        self.phase = .{ .scan_failed = scanFailureText(failure) };
                        return true;
                    },
                    else => {},
                }
                self.scan_result = result.*;
                finished.result = .empty;
                self.rebuildSearch(allocator) catch {
                    self.clearSnapshot(allocator);
                    self.phase = .{ .scan_failed = "Could not prepare AI review filter" };
                    return true;
                };
                const visible_rows = self.rows();
                if (visible_rows.len == 0) {
                    self.phase = .{ .empty = if (self.skippedCount() > 0) .invalid_only else .no_reviews };
                    self.focus = 0;
                } else {
                    self.phase = .ready;
                    self.focusPreferred();
                }
            },
            .empty => self.phase = .{ .scan_failed = "Could not load AI reviews" },
        }
        return true;
    }

    pub fn beginSelectedRun(self: *AiReviewsPickerState) AiReviewSelectionAdmission {
        if (!self.interactionCapabilities().list) return .none;
        const row = self.selectedRow() orelse return .none;
        if (row.availability == .missing) return .unavailable;
        self.input_mode = .command;
        self.advanceGeneration();
        self.phase = .{ .selection_loading = .{ .review_id = row.review_id, .direct = false } };
        const history_value = self.history() orelse return .none;
        return .{ .request = .{
            .request = self.currentRequest(),
            .store = history_value.snapshot,
            .review_id = row.review_id,
            .artifacts = row.artifact_snapshot,
            .direct = false,
        } };
    }

    pub fn retrySelectedRun(self: *AiReviewsPickerState) AiReviewSelectionAdmission {
        const selection_loading = switch (self.phase) {
            .selection_loading => |value| value,
            else => return .none,
        };
        if (selection_loading.direct or self.scan_result == null) return .none;
        const review_id = selection_loading.review_id;
        self.restoreListPhase();
        self.focusReviewId(review_id);
        return self.beginSelectedRun();
    }

    pub fn beginDirectSelection(
        self: *AiReviewsPickerState,
        allocator: std.mem.Allocator,
        identity: page.RequestIdentity,
        root_identity: root_capability.Identity,
        store: review_store.StoreSnapshot,
        review_id: committed_review.ReviewId,
        artifacts: review_store.ArtifactSnapshot,
    ) AiReviewSelectionRequest {
        self.clearSnapshot(allocator);
        self.query = .{};
        self.input_mode = .command;
        self.identity = identity;
        self.root_identity = root_identity;
        self.advanceGeneration();
        self.phase = .{ .selection_loading = .{ .review_id = review_id, .direct = true } };
        return .{
            .request = self.currentRequest(),
            .store = store,
            .review_id = review_id,
            .artifacts = artifacts,
            .direct = true,
        };
    }

    pub fn beginNormalReturn(self: *AiReviewsPickerState, direct: bool) ?AiReviewsRequest {
        if (self.identity == null or self.root_identity == null) return null;
        self.input_mode = .command;
        self.advanceGeneration();
        self.phase = .{ .return_loading = .{ .direct = direct } };
        return self.currentRequest();
    }

    pub fn beginDirectNormalReturn(
        self: *AiReviewsPickerState,
        allocator: std.mem.Allocator,
        identity: page.RequestIdentity,
        root_identity: root_capability.Identity,
    ) AiReviewsRequest {
        self.clearSnapshot(allocator);
        self.query = .{};
        self.input_mode = .command;
        self.identity = identity;
        self.root_identity = root_identity;
        self.advanceGeneration();
        self.phase = .{ .return_loading = .{ .direct = true } };
        return self.currentRequest();
    }

    pub fn acceptsSelection(
        self: *const AiReviewsPickerState,
        repo_epoch: u64,
        root_identity: ?root_capability.Identity,
        store_identity: review_store.ConfigurationIdentity,
        activation: *const diff_surface.authority.Lifecycle,
        finished: app_load.ReviewHistorySelectionFinished,
    ) bool {
        const phase_loading = switch (self.phase) {
            .selection_loading => |value| value,
            else => return false,
        };
        return phase_loading.review_id.eql(finished.review_id) and
            self.accepts(finished.identity, finished.generation, repo_epoch, root_identity, store_identity, finished.store_identity, activation);
    }

    pub fn failSelection(
        self: *AiReviewsPickerState,
        review_id: committed_review.ReviewId,
        failure: review_store.SelectionFailure,
    ) void {
        const phase_loading = switch (self.phase) {
            .selection_loading => |value| value,
            else => return,
        };
        if (failure == .target_unavailable) {
            if (self.history()) |history_value| for (history_value.rows) |*row| {
                if (row.review_id.eql(review_id)) row.availability = .missing;
            };
        }
        self.phase = .{ .selection_failed = .{
            .review_id = review_id,
            .direct = phase_loading.direct,
            .message = selectionFailureText(failure),
        } };
    }

    pub fn failSelectionStatic(self: *AiReviewsPickerState, review_id: committed_review.ReviewId, message: []const u8) void {
        const phase_loading = switch (self.phase) {
            .selection_loading => |value| value,
            else => return,
        };
        self.phase = .{ .selection_failed = .{ .review_id = review_id, .direct = phase_loading.direct, .message = message } };
    }

    pub fn acceptsNormalReturn(
        self: *const AiReviewsPickerState,
        repo_epoch: u64,
        root_identity: ?root_capability.Identity,
        store_identity: review_store.ConfigurationIdentity,
        activation: *const diff_surface.authority.Lifecycle,
        finished: app_load.ReviewHistoryNormalReturnFinished,
    ) bool {
        if (self.phase != .return_loading) return false;
        return self.accepts(finished.identity, finished.generation, repo_epoch, root_identity, store_identity, finished.store_identity, activation);
    }

    pub fn failNormalReturn(self: *AiReviewsPickerState, message: []const u8) void {
        const phase_loading = switch (self.phase) {
            .return_loading => |value| value,
            else => return,
        };
        self.phase = .{ .return_failed = .{ .direct = phase_loading.direct, .message = message } };
    }

    pub fn cancelLoading(self: *AiReviewsPickerState, allocator: std.mem.Allocator) void {
        const restore = switch (self.phase) {
            .selection_loading => |value| !value.direct,
            .return_loading => |value| !value.direct,
            else => false,
        };
        self.advanceGeneration();
        if (restore and self.scan_result != null) {
            self.restoreListPhase();
        } else {
            self.close(allocator);
        }
    }

    pub fn close(self: *AiReviewsPickerState, allocator: std.mem.Allocator) void {
        self.clearSnapshot(allocator);
        self.phase = .closed;
        self.identity = null;
        self.root_identity = null;
        self.query = .{};
        self.input_mode = .command;
        self.focus = 0;
        self.refocus_review_id = null;
        self.render_now_unix = null;
        self.advanceGeneration();
    }

    pub fn moveSelection(self: *AiReviewsPickerState, delta: isize) void {
        if (!self.listInteractive()) return;
        const count = self.filter.source_indexes.len + 1;
        if (delta < 0) self.focus = if (self.focus == 0) count - 1 else self.focus - 1;
        if (delta > 0) self.focus = if (self.focus + 1 == count) 0 else self.focus + 1;
        self.syncFilterFocus();
    }

    pub fn enterQuery(self: *AiReviewsPickerState) void {
        if (!self.listInteractive()) return;
        self.input_mode = .query;
    }

    pub fn leaveQuery(self: *AiReviewsPickerState) void {
        self.input_mode = .command;
    }

    pub fn insertQuery(self: *AiReviewsPickerState, allocator: std.mem.Allocator, codepoint: u21) !void {
        var next = self.query;
        try next.insert(codepoint);
        try self.publishQuery(allocator, next);
    }

    pub fn backspaceQuery(self: *AiReviewsPickerState, allocator: std.mem.Allocator) !void {
        var next = self.query;
        next.backspace();
        try self.publishQuery(allocator, next);
    }

    pub fn clearQueryOrLeave(self: *AiReviewsPickerState, allocator: std.mem.Allocator) !void {
        if (self.query.len > 0) {
            try self.publishQuery(allocator, .{});
        } else {
            self.input_mode = .command;
        }
    }

    pub fn selectedRow(self: *const AiReviewsPickerState) ?*const review_store.RunSummary {
        if (self.focus == 0) return null;
        const history_value = self.historyConst() orelse return null;
        const source_index = self.filter.sourceIndex(self.focus - 1) orelse return null;
        if (source_index >= history_value.rows.len) return null;
        return &history_value.rows[source_index];
    }

    pub fn selectedIsNormal(self: *const AiReviewsPickerState) bool {
        return self.focus == 0 and self.listInteractive();
    }

    pub fn rows(self: *const AiReviewsPickerState) []const review_store.RunSummary {
        const history_value = self.historyConst() orelse return &.{};
        return history_value.rows;
    }

    pub fn skippedCount(self: *const AiReviewsPickerState) usize {
        const history_value = self.historyConst() orelse return 0;
        return history_value.skipped_count;
    }

    pub fn firstDiagnostic(self: *const AiReviewsPickerState) ?[]const u8 {
        const history_value = self.historyConst() orelse return null;
        if (history_value.diagnostics.len == 0) return null;
        return history_value.diagnostics[0].text;
    }

    pub fn prepareModalRedraw(self: *AiReviewsPickerState, io: std.Io) void {
        if (self.isOpen()) {
            self.render_now_unix = commit_time.sampleUnixSeconds(io);
        } else {
            self.render_now_unix = null;
        }
    }

    pub fn deinit(self: *AiReviewsPickerState, allocator: std.mem.Allocator) void {
        self.clearSnapshot(allocator);
        self.* = .{};
    }

    fn currentRequest(self: *const AiReviewsPickerState) AiReviewsRequest {
        return .{
            .identity = self.identity.?,
            .generation = self.generation,
            .root_identity = self.root_identity.?,
        };
    }

    fn accepts(
        self: *const AiReviewsPickerState,
        identity: page.RequestIdentity,
        generation: u64,
        repo_epoch: u64,
        root_identity: ?root_capability.Identity,
        expected_store: review_store.ConfigurationIdentity,
        finished_store: review_store.ConfigurationIdentity,
        activation: *const diff_surface.authority.Lifecycle,
    ) bool {
        if (generation != self.generation or self.identity == null or self.root_identity == null) return false;
        if (!std.meta.eql(self.identity.?, identity) or !self.root_identity.?.eql(root_identity orelse return false)) return false;
        if (!expected_store.eql(finished_store)) return false;
        if (!activation.acceptsRepoEpoch(identity, repo_epoch)) return false;
        const current = activation.currentIdentity() orelse return false;
        return std.meta.eql(current, identity);
    }

    fn listInteractive(self: *const AiReviewsPickerState) bool {
        return self.interactionCapabilities().list;
    }

    fn restoreListPhase(self: *AiReviewsPickerState) void {
        self.phase = if (self.rows().len == 0)
            .{ .empty = if (self.skippedCount() > 0) .invalid_only else .no_reviews }
        else
            .ready;
    }

    fn history(self: *AiReviewsPickerState) ?*review_store.History {
        const result = if (self.scan_result) |*value| value else return null;
        return switch (result.*) {
            .history => |*history_value| history_value,
            else => null,
        };
    }

    fn historyConst(self: *const AiReviewsPickerState) ?*const review_store.History {
        const result = if (self.scan_result) |*value| value else return null;
        return switch (result.*) {
            .history => |*history_value| history_value,
            else => null,
        };
    }

    fn publishQuery(self: *AiReviewsPickerState, allocator: std.mem.Allocator, next: app_prompt.TextInput) !void {
        const preferred = if (self.focus == 0) null else if (self.selectedRow()) |row| row.review_id else null;
        var next_filter: ui.ListFilter = .{};
        errdefer next_filter.deinit(allocator);
        const labels: []const []const u8 = self.search_labels;
        try next_filter.apply(allocator, labels, next.slice());
        self.filter.deinit(allocator);
        self.filter = next_filter;
        self.query = next;
        self.focus = 0;
        if (preferred) |review_id| self.focusReviewId(review_id);
    }

    fn rebuildSearch(self: *AiReviewsPickerState, allocator: std.mem.Allocator) !void {
        self.clearSearch(allocator);
        const rows_value = self.rows();
        const labels = try allocator.alloc([]u8, rows_value.len);
        errdefer allocator.free(labels);
        var initialized: usize = 0;
        errdefer for (labels[0..initialized]) |label| allocator.free(label);
        for (rows_value, labels) |row, *label| {
            const review_id = row.review_id.canonical();
            label.* = try std.fmt.allocPrint(allocator, "{s} {s} {s} {s} {s} {s} {s} {s}", .{
                row.producer_name,
                row.producer_model orelse "",
                runSummaryStatusText(row.status),
                row.base_label orelse "",
                row.target.base_oid.short(),
                row.head_label orelse "",
                row.target.head_oid.short(),
                &review_id,
            });
            initialized += 1;
        }
        self.search_labels = labels;
        const borrowed: []const []const u8 = labels;
        try self.filter.apply(allocator, borrowed, self.query.slice());
    }

    fn clearSnapshot(self: *AiReviewsPickerState, allocator: std.mem.Allocator) void {
        self.clearSearch(allocator);
        if (self.scan_result) |*result| result.deinit(allocator);
        self.scan_result = null;
    }

    fn clearSearch(self: *AiReviewsPickerState, allocator: std.mem.Allocator) void {
        self.filter.deinit(allocator);
        self.filter = .{};
        for (self.search_labels) |label| allocator.free(label);
        allocator.free(self.search_labels);
        self.search_labels = &.{};
    }

    fn focusPreferred(self: *AiReviewsPickerState) void {
        self.focus = 0;
        if (self.refocus_review_id) |review_id| self.focusReviewId(review_id);
        self.refocus_review_id = null;
    }

    fn focusReviewId(self: *AiReviewsPickerState, review_id: committed_review.ReviewId) void {
        const history_value = self.historyConst() orelse return;
        for (self.filter.source_indexes, 0..) |source_index, visible_index| {
            if (source_index < history_value.rows.len and history_value.rows[source_index].review_id.eql(review_id)) {
                self.focus = visible_index + 1;
                self.syncFilterFocus();
                return;
            }
        }
    }

    fn syncFilterFocus(self: *AiReviewsPickerState) void {
        if (self.focus == 0 or self.filter.source_indexes.len == 0) return;
        self.filter.list.focus.index = @min(self.focus - 1, self.filter.source_indexes.len - 1);
    }

    fn advanceGeneration(self: *AiReviewsPickerState) void {
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
    }
};

pub fn runSummaryStatusText(status: review_store.RunSummaryStatus) []const u8 {
    return switch (status) {
        .new => "new",
        .draft => "draft",
        .approved => "approved",
        .needs_changes => "needs changes",
        .canceled => "canceled",
    };
}

fn scanFailureText(failure: review_store.ScanFailure) []const u8 {
    return switch (failure) {
        .repository_invalid => "Could not load AI reviews: repository invalid",
        .store_invalid => "Could not load AI reviews: Store invalid",
        .store_unavailable => "Could not load AI reviews: Store unavailable",
        .unsupported_platform => "Could not load AI reviews: unsupported platform",
        .unsupported_filesystem => "Could not load AI reviews: unsupported filesystem",
        .registry_invalid => "Could not load AI reviews: registry invalid",
        .registry_unavailable => "Could not load AI reviews: registry unavailable",
        .namespace_invalid => "Could not load AI reviews: namespace invalid",
        .enumeration_failed => "Could not load AI reviews: scan failed",
        .scan_limit_exceeded => "Could not load AI reviews: scan limit exceeded",
        .git_failed => "Could not load AI reviews: Git read failed",
    };
}

fn selectionFailureText(failure: review_store.SelectionFailure) []const u8 {
    return switch (failure) {
        .repository_unavailable => "Could not load AI review: repository unavailable",
        .root_drift => "Could not load AI review: Store changed",
        .binding_drift => "Could not load AI review: repository binding changed",
        .run_invalid => "Could not load AI review: Run invalid",
        .artifact_drift => "Could not load AI review: artifacts changed",
        .target_unavailable => "Review target unavailable; restore objects and press r",
        .git_failed => "Could not load AI review: Git read failed",
        .projection_failed => "Could not load AI review: projection failed",
    };
}

/// A live drag may defer an entire atomic Review completion. This owner never
/// splits basis from diff; replacement and page teardown release both through
/// the normal undelivered-completion contract.
pub const DeferredLoadApply = struct {
    finished: app_load.ReviewLoadFinished,

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

/// Immutable Review authority captured when a completed selection is
/// installed. Copy/Clear admission uses the portable target's structural
/// equality instead of a second three-OID authority.
pub const PinnedSelectionBasis = struct {
    target: committed_review.CommittedReviewTarget,

    pub fn init(basis: diff_basis.BranchDiffBasis) PinnedSelectionBasis {
        return .{ .target = basis.target };
    }

    pub fn eql(self: PinnedSelectionBasis, other: PinnedSelectionBasis) bool {
        return self.target.eql(&other.target);
    }
};

/// Display-admission evidence captured with one accepted Review bundle.
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

pub const NormalPresentation = struct {
    basis: diff_basis.BranchDiffBasis,

    pub fn deinit(self: *NormalPresentation, allocator: std.mem.Allocator) void {
        self.basis.deinit(allocator);
        self.* = undefined;
    }
};

pub const PinnedAiPresentation = struct {
    selection: review_store.SelectedRunRead,
    base_display: []u8,
    head_display: []u8,
    finding_presentation_cache: ?FindingPresentationCache = null,

    pub fn deinit(self: *PinnedAiPresentation, allocator: std.mem.Allocator) void {
        if (self.finding_presentation_cache) |*cache| cache.deinit(allocator);
        allocator.free(self.head_display);
        allocator.free(self.base_display);
        self.selection.deinit(allocator);
        self.* = undefined;
    }

    pub fn reviewId(self: *const PinnedAiPresentation) committed_review.ReviewId {
        return self.selection.artifacts.manifest.value.review_id;
    }

    pub fn target(self: *const PinnedAiPresentation) committed_review.CommittedReviewTarget {
        return self.selection.artifacts.manifest.value.target;
    }

    pub fn binding(self: *const PinnedAiPresentation) review_store.ReviewRunBinding {
        const manifest = &self.selection.artifacts.manifest.value;
        return .{
            .review_repository_id = manifest.review_repository_id,
            .review_id = manifest.review_id,
            .target = manifest.target,
            .findings_digest = manifest.findings_digest,
        };
    }
};

pub const FindingCardContent = struct {
    producer: []const u8,
    model: ?[]const u8,
    title: []const u8,
    body: []const u8,
    suggestion: ?[]const u8,
};

pub const FindingPresentationKey = struct {
    identity: finding_projection.Identity,
    source_session_revision: u64,
    selected_target: ?context.SelectedTarget,
    pane_width: u16,
    mode: diff_render.DisplayMode,
    selection_layout_revision: u64,

    pub fn eql(self: FindingPresentationKey, other: FindingPresentationKey) bool {
        return finding_card.identityEql(self.identity, other.identity) and
            self.source_session_revision == other.source_session_revision and
            std.meta.eql(self.selected_target, other.selected_target) and
            self.pane_width == other.pane_width and
            self.mode == other.mode and
            self.selection_layout_revision == other.selection_layout_revision;
    }
};

pub const FindingBodyKey = struct {
    finding_id: finding_card.FindingId,
    width: u16,

    pub fn eql(self: *const FindingBodyKey, model: finding_card.FindingCardModel, width: u16) bool {
        return self.width == width and self.finding_id.eqlSlice(model.finding_id);
    }
};

pub const FindingPresentationFrame = struct {
    row_plan: finding_card.RowPlan,
    presentation_rows: diff_render.PresentationRows,
};

pub const CachedFindingBody = struct {
    text: []const u8,
    row_starts: []const usize,

    pub fn rowCount(self: CachedFindingBody) usize {
        return self.row_starts.len;
    }
};

/// Bounded derived storage subordinate to one accepted selected-Run owner.
/// Its frame and body values only borrow the enclosing selection and these
/// slices; they never own another decoded Finding collection.
pub const FindingPresentationCache = struct {
    models: []finding_card.FindingCardModel,
    groups: []finding_card.Group,
    cards: []finding_card.FindingCardModel,
    cursors: []usize,
    inputs: []diff_render.InlineBlockInput,
    blocks: []diff_render.InlineBlock,
    body_display: []u8,
    body_row_starts: []usize,
    frame_key: ?FindingPresentationKey = null,
    frame: ?FindingPresentationFrame = null,
    body_key: ?FindingBodyKey = null,
    body_text_len: usize = 0,
    body_row_count: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        selection: *const review_store.SelectedRunRead,
        source_lines: ?usize,
    ) (std.mem.Allocator.Error || error{InvalidFindingPresentationCache})!?FindingPresentationCache {
        const entry_capacity = selection.finding_projection.entries.len;
        if (entry_capacity == 0) return null;
        if (entry_capacity > committed_review.limits.max_findings) {
            return error.InvalidFindingPresentationCache;
        }
        const block_capacity = std.math.mul(usize, entry_capacity, 2) catch
            return error.InvalidFindingPresentationCache;
        const inserted_bound = std.math.mul(
            usize,
            entry_capacity,
            finding_card.expanded_rows + finding_card.group_spacer_rows,
        ) catch return error.InvalidFindingPresentationCache;
        if (source_lines) |lines| {
            _ = std.math.add(usize, lines, inserted_bound) catch
                return error.InvalidFindingPresentationCache;
        }

        var body_capacity: usize = 0;
        const value = &selection.artifacts.findings.value;
        for (value.findings) |finding| {
            body_capacity = @max(body_capacity, findingCardDisplayTextLength(.{
                .producer = value.producer.name,
                .model = value.producer.model,
                .title = finding.title,
                .body = finding.body,
                .suggestion = finding.suggestion,
            }));
        }
        const row_capacity = std.math.add(usize, body_capacity, 1) catch
            return error.InvalidFindingPresentationCache;

        const models = try allocator.alloc(finding_card.FindingCardModel, entry_capacity);
        errdefer allocator.free(models);
        const groups = try allocator.alloc(finding_card.Group, entry_capacity);
        errdefer allocator.free(groups);
        const cards = try allocator.alloc(finding_card.FindingCardModel, entry_capacity);
        errdefer allocator.free(cards);
        const cursors = try allocator.alloc(usize, entry_capacity);
        errdefer allocator.free(cursors);
        const inputs = try allocator.alloc(diff_render.InlineBlockInput, block_capacity);
        errdefer allocator.free(inputs);
        const blocks = try allocator.alloc(diff_render.InlineBlock, block_capacity);
        errdefer allocator.free(blocks);
        const body_display = try allocator.alloc(u8, body_capacity);
        errdefer allocator.free(body_display);
        const body_row_starts = try allocator.alloc(usize, row_capacity);
        return .{
            .models = models,
            .groups = groups,
            .cards = cards,
            .cursors = cursors,
            .inputs = inputs,
            .blocks = blocks,
            .body_display = body_display,
            .body_row_starts = body_row_starts,
        };
    }

    pub fn deinit(self: *FindingPresentationCache, allocator: std.mem.Allocator) void {
        allocator.free(self.body_row_starts);
        allocator.free(self.body_display);
        allocator.free(self.blocks);
        allocator.free(self.inputs);
        allocator.free(self.cursors);
        allocator.free(self.cards);
        allocator.free(self.groups);
        allocator.free(self.models);
        self.* = undefined;
    }

    pub fn invalidateFrame(self: *FindingPresentationCache) void {
        self.frame_key = null;
        self.frame = null;
        self.invalidateBody();
    }

    pub fn invalidateBody(self: *FindingPresentationCache) void {
        self.body_key = null;
        self.body_text_len = 0;
        self.body_row_count = 0;
    }

    pub fn logicalCapacityBytes(self: *const FindingPresentationCache) usize {
        return self.models.len * @sizeOf(finding_card.FindingCardModel) +
            self.groups.len * @sizeOf(finding_card.Group) +
            self.cards.len * @sizeOf(finding_card.FindingCardModel) +
            self.cursors.len * @sizeOf(usize) +
            self.inputs.len * @sizeOf(diff_render.InlineBlockInput) +
            self.blocks.len * @sizeOf(diff_render.InlineBlock) +
            self.body_display.len +
            self.body_row_starts.len * @sizeOf(usize);
    }
};

/// Resolve presentation text only through one accepted selected-run owner.
/// Independently supplied bytes or decoded payload values cannot cross this
/// boundary.
pub fn findingCardContent(
    selection: *const review_store.SelectedRunRead,
    model: finding_card.FindingCardModel,
) ?FindingCardContent {
    if (!finding_card.identityEql(selection.finding_projection.identity, model.identity)) return null;
    if (model.entry_index >= selection.finding_projection.entries.len or
        model.entry_index >= selection.artifacts.findings.value.findings.len) return null;
    const entry = selection.finding_projection.entries[model.entry_index];
    const finding = selection.artifacts.findings.value.findings[model.entry_index];
    const span = switch (entry.outcome) {
        .mapped => |value| value,
        else => return null,
    };
    if (!std.mem.eql(u8, entry.finding_id, model.finding_id) or
        !std.mem.eql(u8, finding.finding_id.bytes, model.finding_id) or
        !std.meta.eql(span, model.span) or entry.side != model.side or
        entry.severity != model.severity) return null;
    const producer = selection.artifacts.findings.value.producer;
    return .{
        .producer = producer.name,
        .model = producer.model,
        .title = finding.title,
        .body = finding.body,
        .suggestion = finding.suggestion,
    };
}

pub fn findingCardDisplayText(
    allocator: std.mem.Allocator,
    content: FindingCardContent,
) std.mem.Allocator.Error![]u8 {
    const text = try allocator.alloc(u8, findingCardDisplayTextLength(content));
    return findingCardDisplayTextInto(text, content);
}

pub fn findingCardDisplayTextLength(content: FindingCardContent) usize {
    if (content.model) |model| {
        if (content.suggestion) |suggestion| return std.fmt.count(
            "Producer: {s}\nModel: {s}\n\n{s}\n\nSuggestion:\n{s}",
            .{ content.producer, model, content.body, suggestion },
        );
        return std.fmt.count(
            "Producer: {s}\nModel: {s}\n\n{s}",
            .{ content.producer, model, content.body },
        );
    }
    if (content.suggestion) |suggestion| return std.fmt.count(
        "Producer: {s}\n\n{s}\n\nSuggestion:\n{s}",
        .{ content.producer, content.body, suggestion },
    );
    return std.fmt.count("Producer: {s}\n\n{s}", .{ content.producer, content.body });
}

pub fn findingCardDisplayTextInto(buffer: []u8, content: FindingCardContent) []u8 {
    if (content.model) |model| {
        if (content.suggestion) |suggestion| return std.fmt.bufPrint(
            buffer,
            "Producer: {s}\nModel: {s}\n\n{s}\n\nSuggestion:\n{s}",
            .{ content.producer, model, content.body, suggestion },
        ) catch unreachable;
        return std.fmt.bufPrint(
            buffer,
            "Producer: {s}\nModel: {s}\n\n{s}",
            .{ content.producer, model, content.body },
        ) catch unreachable;
    }
    if (content.suggestion) |suggestion| return std.fmt.bufPrint(
        buffer,
        "Producer: {s}\n\n{s}\n\nSuggestion:\n{s}",
        .{ content.producer, content.body, suggestion },
    ) catch unreachable;
    return std.fmt.bufPrint(buffer, "Producer: {s}\n\n{s}", .{ content.producer, content.body }) catch unreachable;
}

pub fn findingCardMaxBodyScroll(
    allocator: std.mem.Allocator,
    content: FindingCardContent,
    width: u16,
) std.mem.Allocator.Error!usize {
    if (width == 0) return 0;
    const text = try findingCardDisplayText(allocator, content);
    defer allocator.free(text);
    const rows = ui.Paragraph.init(.{ .text = text }).lineCount(width);
    return rows -| 5;
}

pub fn findingCardContentWidth(row_width: u16) u16 {
    return row_width -| 1;
}

test "Finding card content width reserves the painter border across wrap boundaries" {
    try std.testing.expectEqual(@as(u16, 0), findingCardContentWidth(0));
    try std.testing.expectEqual(@as(u16, 0), findingCardContentWidth(1));
    try std.testing.expectEqual(@as(u16, 19), findingCardContentWidth(20));
    const content: FindingCardContent = .{
        .producer = "agent",
        .model = null,
        .title = "wrap",
        .body = "012345678901234567890123456789012345678901234567890123456789",
        .suggestion = null,
    };
    const narrow = try findingCardMaxBodyScroll(std.testing.allocator, content, findingCardContentWidth(10));
    const wide = try findingCardMaxBodyScroll(std.testing.allocator, content, findingCardContentWidth(20));
    try std.testing.expect(narrow > wide);
}

test "Finding presentation cache boundary capacity stays below five MiB" {
    const per_entry = @sizeOf(finding_card.FindingCardModel) * 2 +
        @sizeOf(finding_card.Group) +
        @sizeOf(usize) +
        @sizeOf(diff_render.InlineBlockInput) * 2 +
        @sizeOf(diff_render.InlineBlock) * 2;
    try std.testing.expectEqual(@as(usize, 856), per_entry);
    const maximum_display = "Producer: ".len + committed_review.limits.max_short_text_bytes +
        "\nModel: ".len + committed_review.limits.max_short_text_bytes +
        "\n\n".len + committed_review.limits.max_body_bytes +
        "\n\nSuggestion:\n".len + committed_review.limits.max_body_bytes;
    try std.testing.expectEqual(@as(usize, 131_618), maximum_display);
    const logical_capacity = committed_review.limits.max_findings * per_entry +
        maximum_display + (maximum_display + 1) * @sizeOf(usize);
    try std.testing.expectEqual(@as(usize, 4_690_746), logical_capacity);
    try std.testing.expect(logical_capacity < 5 * 1024 * 1024);
}

test "Finding display text fills its exact admitted buffer" {
    const content: FindingCardContent = .{
        .producer = "reviewer",
        .model = "model",
        .title = "not part of body presentation",
        .body = "body",
        .suggestion = "replacement",
    };
    var buffer: [128]u8 = undefined;
    const text = findingCardDisplayTextInto(&buffer, content);
    try std.testing.expectEqual(findingCardDisplayTextLength(content), text.len);
    try std.testing.expectEqualStrings(
        "Producer: reviewer\nModel: model\n\nbody\n\nSuggestion:\nreplacement",
        text,
    );
}

pub const Presentation = union(enum) {
    normal: NormalPresentation,
    pinned_ai: PinnedAiPresentation,

    pub fn deinit(self: *Presentation, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*value| value.deinit(allocator),
        }
        self.* = undefined;
    }

    pub fn target(self: *const Presentation) committed_review.CommittedReviewTarget {
        return switch (self.*) {
            .normal => |*normal| normal.basis.target,
            .pinned_ai => |*pinned| pinned.target(),
        };
    }
};

pub const ReviewPageState = struct {
    // Independently owned fields exposed through DiffSurface.
    activation: diff_surface.authority.Lifecycle = .init(.review),
    status: app_state.StatusMessage = .{},
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

    // Review-owned basis and refresh state.
    presentation: ?Presentation = null,
    accepted_repository_identity: ?AcceptedRepositoryIdentity = null,
    base_target: ?diff_basis.BaseTarget = null,
    basis_failure: ?BasisFailureState = null,
    load_failure: ?[]u8 = null,
    base_picker: BasePickerState = .{},
    ai_reviews: AiReviewsPickerState = .{},
    human_review_decision: human_review_decision.State = .{},
    finding_card: finding_card.State = .unfocused,
    refresh_generation: u64 = 0,
    deferred_load_apply: ?DeferredLoadApply = null,
    refresh_anchor: ?diff_surface.ReloadAnchor = null,

    pub fn activate(self: *ReviewPageState, repo_epoch: u64) u64 {
        if (self.accepted_repository_identity) |identity| {
            if (identity.repo_epoch != repo_epoch) self.accepted_repository_identity = null;
        }
        return self.activation.activate(repo_epoch, .pending, .unavailable, .unavailable);
    }

    pub fn deactivate(self: *ReviewPageState) void {
        self.selection_owner = .none;
        self.finding_card = .unfocused;
        self.human_review_decision.close();
        self.activation.deactivate();
    }

    pub fn isPinnedAi(self: *const ReviewPageState) bool {
        const presentation = self.presentation orelse return false;
        return presentation == .pinned_ai;
    }

    pub fn activeAiReviewId(self: *const ReviewPageState) ?committed_review.ReviewId {
        const presentation = if (self.presentation) |*value| value else return null;
        return switch (presentation.*) {
            .pinned_ai => |*pinned| pinned.reviewId(),
            .normal => null,
        };
    }

    pub fn isCurrentReviewTarget(self: *const ReviewPageState, target: *const committed_review.CommittedReviewTarget) bool {
        const presentation = if (self.presentation) |*value| value else return false;
        const active_target = presentation.target();
        return active_target.eql(target);
    }

    pub fn normalBasis(self: *ReviewPageState) ?*diff_basis.BranchDiffBasis {
        const presentation = if (self.presentation) |*value| value else return null;
        return switch (presentation.*) {
            .normal => |*normal| &normal.basis,
            .pinned_ai => null,
        };
    }

    pub fn normalBasisConst(self: *const ReviewPageState) ?*const diff_basis.BranchDiffBasis {
        const presentation = if (self.presentation) |*value| value else return null;
        return switch (presentation.*) {
            .normal => |*normal| &normal.basis,
            .pinned_ai => null,
        };
    }

    pub fn pinnedAi(self: *ReviewPageState) ?*PinnedAiPresentation {
        const presentation = if (self.presentation) |*value| value else return null;
        return switch (presentation.*) {
            .pinned_ai => |*pinned| pinned,
            .normal => null,
        };
    }

    pub fn pinnedAiConst(self: *const ReviewPageState) ?*const PinnedAiPresentation {
        const presentation = if (self.presentation) |*value| value else return null;
        return switch (presentation.*) {
            .pinned_ai => |*pinned| pinned,
            .normal => null,
        };
    }

    pub fn contentForFindingCard(self: *const ReviewPageState, model: finding_card.FindingCardModel) ?FindingCardContent {
        const pinned = self.pinnedAiConst() orelse return null;
        return findingCardContent(&pinned.selection, model);
    }

    pub fn cachedFindingBody(
        self: *const ReviewPageState,
        model: finding_card.FindingCardModel,
        width: u16,
    ) ?CachedFindingBody {
        const pinned = self.pinnedAiConst() orelse return null;
        const cache = if (pinned.finding_presentation_cache) |*value| value else return null;
        const frame_key = cache.frame_key orelse return null;
        if (!finding_card.identityEql(frame_key.identity, model.identity)) return null;
        const body_key = cache.body_key orelse return null;
        if (!body_key.eql(model, width)) return null;
        if (cache.body_text_len > cache.body_display.len or
            cache.body_row_count > cache.body_row_starts.len) return null;
        return .{
            .text = cache.body_display[0..cache.body_text_len],
            .row_starts = cache.body_row_starts[0..cache.body_row_count],
        };
    }

    pub fn releaseFindingPresentationCache(self: *ReviewPageState, allocator: std.mem.Allocator) void {
        const pinned = self.pinnedAi() orelse return;
        if (pinned.finding_presentation_cache) |*cache| cache.deinit(allocator);
        pinned.finding_presentation_cache = null;
    }

    pub fn advanceSelectionLayoutRevision(self: *ReviewPageState) void {
        self.selection_layout_revision +%= 1;
        if (self.selection_layout_revision == 0) self.selection_layout_revision = 1;
    }

    pub fn retainedSelectionInstallAvailable(self: *const ReviewPageState) bool {
        return self.currentPinnedBasis() != null and self.load.state == .loaded;
    }

    pub fn retainedSelectionAdmitted(self: *const ReviewPageState) bool {
        const pinned = self.pinned_selection_basis orelse return false;
        const current = self.currentPinnedBasis() orelse return false;
        return pinned.eql(current);
    }

    pub fn installPinnedSelectionBasis(self: *ReviewPageState) bool {
        const current = self.currentPinnedBasis() orelse return false;
        self.pinned_selection_basis = current;
        return true;
    }

    pub fn clearRetainedSelection(self: *ReviewPageState, allocator: std.mem.Allocator) void {
        if (self.completed_selection) |*selection| selection.deinit(allocator);
        self.completed_selection = null;
        self.pinned_selection_basis = null;
        self.selection_owner = .none;
    }

    fn currentPinnedBasis(self: *const ReviewPageState) ?PinnedSelectionBasis {
        const presentation = if (self.presentation) |*value| value else return null;
        return .{ .target = presentation.target() };
    }

    pub fn beginRefresh(self: *ReviewPageState) ?RefreshRequest {
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

    /// A fully prepared pinned presentation supersedes every older ordinary
    /// source refresh. Retire both in-flight authority and any completion
    /// deferred behind a live selection before installing the pinned bundle.
    pub fn retireOrdinaryRefreshForPinnedAcceptance(
        self: *ReviewPageState,
        allocator: std.mem.Allocator,
    ) void {
        self.refresh_generation +%= 1;
        if (self.refresh_generation == 0) self.refresh_generation = 1;
        if (self.activation.currentIdentity()) |identity| {
            _ = self.activation.finishMember(identity, .source, .fresh);
        }
        if (self.deferred_load_apply) |*deferred| deferred.deinit(allocator);
        self.deferred_load_apply = null;
        if (self.refresh_anchor) |*anchor| anchor.deinit(allocator);
        self.refresh_anchor = null;
    }

    /// A new request supersedes the previous terminal diagnostic while the
    /// accepted basis and body remain visible as the refresh snapshot.
    pub fn clearRefreshFailure(self: *ReviewPageState, allocator: std.mem.Allocator) void {
        self.clearBasisFailure(allocator);
        self.clearLoadFailure(allocator);
    }

    pub fn beginBasePicker(self: *ReviewPageState, allocator: std.mem.Allocator) ?BasePickerRequest {
        const identity = self.activation.currentIdentity() orelse return null;
        if (self.selection_owner.activeMouseSelection() or
            self.selection_owner.activeKeyboardSideChoice() != null)
        {
            self.selection_owner = .none;
        }
        return self.base_picker.begin(allocator, identity);
    }

    pub fn closeBasePicker(self: *ReviewPageState, allocator: std.mem.Allocator) void {
        self.base_picker.close(allocator);
    }

    pub fn chooseBasePickerTarget(self: *ReviewPageState, allocator: std.mem.Allocator) !bool {
        var target = try self.base_picker.selectedTarget(allocator) orelse return false;
        errdefer target.deinit(allocator);
        self.base_picker.close(allocator);
        if (self.base_target) |*old| old.deinit(allocator);
        self.base_target = target;
        self.accepted_repository_identity = null;
        return true;
    }

    pub fn applyLoadFinished(
        self: *ReviewPageState,
        allocator: std.mem.Allocator,
        repo_epoch: u64,
        repo_root: ?[]const u8,
        root_identity: ?root_capability.Identity,
        finished: *app_load.ReviewLoadFinished,
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

    pub fn acceptsFinished(self: *const ReviewPageState, repo_epoch: u64, finished: app_load.ReviewLoadFinished) bool {
        return self.acceptsLoadFinished(repo_epoch, finished);
    }

    pub fn takeRefreshAnchor(self: *ReviewPageState) ?diff_surface.ReloadAnchor {
        const anchor = self.refresh_anchor;
        self.refresh_anchor = null;
        return anchor;
    }

    pub fn replaceRefreshAnchor(self: *ReviewPageState, allocator: std.mem.Allocator, anchor: ?diff_surface.ReloadAnchor) void {
        if (self.refresh_anchor) |*old| old.deinit(allocator);
        self.refresh_anchor = anchor;
    }

    pub fn hasAcceptedDisplay(self: *const ReviewPageState) bool {
        if (self.presentation == null) return false;
        return switch (self.load.state) {
            .loaded, .empty => true,
            .idle, .loading, .failed => false,
        };
    }

    pub fn rejectRefresh(self: *ReviewPageState, request: RefreshRequest, repo_epoch: u64) bool {
        if (request.generation != self.refresh_generation) return false;
        if (!self.activation.acceptsRepoEpoch(request.identity, repo_epoch)) return false;
        return self.activation.finishMember(request.identity, .source, .failed);
    }

    pub fn failRefresh(
        self: *ReviewPageState,
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

    pub fn markNoRepository(self: *ReviewPageState, allocator: std.mem.Allocator) void {
        self.human_review_decision.close();
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
        self: *ReviewPageState,
        allocator: std.mem.Allocator,
        finished: app_load.ReviewLoadFinished,
    ) void {
        if (self.deferred_load_apply) |*deferred| deferred.deinit(allocator);
        self.deferred_load_apply = .{ .finished = finished };
    }

    fn acceptsLoadFinished(
        self: *const ReviewPageState,
        repo_epoch: u64,
        finished: app_load.ReviewLoadFinished,
    ) bool {
        if (finished.generation != self.refresh_generation) return false;
        if (!self.activation.acceptsRepoEpoch(finished.identity, repo_epoch)) return false;
        const current = self.activation.currentIdentity() orelse return false;
        return std.meta.eql(current, finished.identity);
    }

    fn clearBasisFailure(self: *ReviewPageState, allocator: std.mem.Allocator) void {
        if (self.basis_failure) |*failure| failure.deinit(allocator);
        self.basis_failure = null;
    }

    fn commitLoaded(
        self: *ReviewPageState,
        allocator: std.mem.Allocator,
        repo_epoch: u64,
        repo_root: ?[]const u8,
        root_identity: ?root_capability.Identity,
        bundle: *app_load.ReviewLoadedBundle,
    ) !void {
        const transfer_selection = self.retainedSelectionTransfers(
            repo_epoch,
            root_identity,
            &bundle.basis,
            &bundle.diff,
        );
        const pair_changed = if (self.presentation) |*current|
            !current.target().eql(&bundle.basis.target)
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
        if (self.presentation) |*presentation| presentation.deinit(allocator);
        self.presentation = .{ .normal = .{ .basis = bundle.basis } };
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
            self.pinned_selection_basis = self.currentPinnedBasis();
        }
        self.accepted_repository_identity = .{
            .repo_epoch = repo_epoch,
            .root_identity = root_identity,
        };
        self.clearBasisFailure(allocator);
        self.clearLoadFailure(allocator);
    }

    pub fn commitNormalReturn(
        self: *ReviewPageState,
        allocator: std.mem.Allocator,
        repo_epoch: u64,
        repo_root: ?[]const u8,
        root_identity: ?root_capability.Identity,
        bundle: *app_load.ReviewLoadedBundle,
    ) !void {
        self.human_review_decision.close();
        try self.commitLoaded(allocator, repo_epoch, repo_root, root_identity, bundle);
        self.finding_card = .unfocused;
        self.advanceSelectionLayoutRevision();
    }

    pub fn commitPinnedAi(
        self: *ReviewPageState,
        allocator: std.mem.Allocator,
        repo_epoch: u64,
        repo_root: ?[]const u8,
        root_identity: ?root_capability.Identity,
        bundle: *app_load.PinnedReviewLoadedBundle,
    ) !void {
        const next_finding_card = self.finding_card.transferred(&bundle.selection.finding_projection);
        const manifest = &bundle.selection.artifacts.manifest.value;
        const target = manifest.target;
        const pair_changed = if (self.presentation) |*current| !current.target().eql(&target) else true;

        const source_lines: ?usize = switch (bundle.diff) {
            .loaded => |*diff_bundle| diff_bundle.loaded.lines,
            .empty => null,
        };
        var finding_presentation_cache = try FindingPresentationCache.init(
            allocator,
            &bundle.selection,
            source_lines,
        );
        errdefer if (finding_presentation_cache) |*cache| cache.deinit(allocator);

        const base_label = if (manifest.display) |display| display.base_label else null;
        const head_label = if (manifest.display) |display| display.head_label else null;
        const base_display = if (base_label) |label|
            try std.fmt.allocPrint(allocator, "AI {s}@{s}", .{ label, target.base_oid.short() })
        else
            try std.fmt.allocPrint(allocator, "AI {s}", .{target.base_oid.short()});
        errdefer allocator.free(base_display);
        const head_display = if (head_label) |label|
            try std.fmt.allocPrint(allocator, "{s}@{s}", .{ label, target.head_oid.short() })
        else
            try allocator.dupe(u8, target.head_oid.short());
        errdefer allocator.free(head_display);

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

        self.human_review_decision.close();
        self.retireOrdinaryRefreshForPinnedAcceptance(allocator);
        self.file_search.deinit(allocator);
        self.clearRetainedSelection(allocator);
        if (pair_changed) {
            self.reviewed_store.deinit(allocator);
            self.tree_order.reset(allocator);
        }
        if (self.presentation) |*presentation| presentation.deinit(allocator);
        self.presentation = .{ .pinned_ai = .{
            .selection = bundle.selection,
            .base_display = base_display,
            .head_display = head_display,
            .finding_presentation_cache = finding_presentation_cache,
        } };
        bundle.selection = undefined;
        finding_presentation_cache = null;
        self.finding_card = next_finding_card;
        self.advanceSelectionLayoutRevision();

        self.load.clearCurrent(allocator);
        if (prepared_session) |session| {
            self.load.state = .{ .loaded = session };
            prepared_session = null;
        } else {
            self.load.state = .{ .empty = .no_changes };
            self.resetAcceptedDisplayNavigation();
        }
        self.source_session_revision +%= 1;
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
    fn resetAcceptedDisplayNavigation(self: *ReviewPageState) void {
        self.viewer.diff_scroll = 0;
        self.viewer.diff_horizontal_scroll = 0;
        self.viewer.sidebar_horizontal_scroll = 0;
        self.viewer.diff_cursor = .{ .metadata = 0 };
        self.search.match = null;
        self.search.match_offset = null;
    }

    fn retainedSelectionTransfers(
        self: *const ReviewPageState,
        repo_epoch: u64,
        root_identity: ?root_capability.Identity,
        incoming_basis: *const diff_basis.BranchDiffBasis,
        incoming_diff: *const app_load.ReviewDiffBundle,
    ) bool {
        const completed = self.completed_selection orelse return false;
        const pinned = self.pinned_selection_basis orelse return false;
        const current_basis = self.normalBasisConst() orelse return false;
        if (!pinned.eql(PinnedSelectionBasis.init(current_basis.*)) or
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

    fn replaceLoadFailure(self: *ReviewPageState, allocator: std.mem.Allocator, message: []const u8) !void {
        const copy = try allocator.dupe(u8, message);
        self.clearLoadFailure(allocator);
        self.load_failure = copy;
    }

    fn clearLoadFailure(self: *ReviewPageState, allocator: std.mem.Allocator) void {
        if (self.load_failure) |message| allocator.free(message);
        self.load_failure = null;
    }

    pub fn deinit(self: *ReviewPageState, allocator: std.mem.Allocator) void {
        self.selection_owner = .none;
        if (self.completed_selection) |*selection| selection.deinit(allocator);
        // Candidate paths borrow the accepted load owner.
        self.file_search.deinit(allocator);
        self.releaseFindingPresentationCache(allocator);
        self.load.clearCurrent(allocator);
        self.reviewed_store.deinit(allocator);
        self.tree_order.deinit(allocator);
        if (self.tree_order_scope) |scope| allocator.free(scope);
        if (self.refresh_anchor) |*anchor| anchor.deinit(allocator);
        if (self.presentation) |*presentation| presentation.deinit(allocator);
        if (self.base_target) |*target| target.deinit(allocator);
        if (self.basis_failure) |*failure| failure.deinit(allocator);
        if (self.load_failure) |message| allocator.free(message);
        self.base_picker.deinit(allocator);
        self.ai_reviews.deinit(allocator);
        self.human_review_decision.deinit();
        if (self.deferred_load_apply) |*deferred| deferred.deinit(allocator);
        self.* = .{};
    }

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
            .selection_generation = &self.selection_generation,
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
            .selection_generation = &self.selection_generation,
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

test "Review owns an independent shared diff surface state" {
    const allocator = std.testing.allocator;
    var state: ReviewPageState = .{};
    defer state.deinit(allocator);

    var surface = state.diffSurface(.{ .range = "0000000..1111111" }, .{ .width = 80, .height = 24 });
    surface.viewer.diff_scroll = 7;
    surface.search.mode = true;

    try std.testing.expectEqual(@as(usize, 7), state.viewer.diff_scroll);
    try std.testing.expect(state.search.mode);
    try std.testing.expect(surface.viewer == &state.viewer);
    try std.testing.expect(surface.source == .range);
}

test "Review activation uses its own retained lifecycle" {
    var state: ReviewPageState = .{};
    const first = state.activate(9);
    state.deactivate();
    const second = state.activate(9);

    try std.testing.expect(first != 0);
    try std.testing.expectEqual(first + 1, second);
    try std.testing.expectEqual(page.Id.review, state.activation.currentIdentity().?.origin);
}

fn failedFinished(
    allocator: std.mem.Allocator,
    identity: page.RequestIdentity,
    generation: u64,
    message: []const u8,
) !app_load.ReviewLoadFinished {
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
) !app_load.ReviewLoadFinished {
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
) !app_load.ReviewLoadFinished {
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
                },
                .head_display = try allocator.dupe(u8, "feature"),
                .target = .{
                    .object_format = .sha1,
                    .source_kind = .branch_range,
                    .base_oid = .{},
                    .head_oid = .{},
                    .diff_base_oid = .{},
                },
                .ahead_count = 1,
            },
            .diff = .empty,
        } },
    };
}

test "Review rejects a completion with stale repository epoch" {
    const allocator = std.testing.allocator;
    var state: ReviewPageState = .{};
    defer state.deinit(allocator);
    const activation_id = state.activate(9);
    const request = state.beginRefresh().?;
    var finished = try failedFinished(allocator, page.RequestIdentity.review(8, activation_id), request.generation, "old repo");
    defer finished.deinit(allocator);

    try std.testing.expectEqual(LoadAcceptance.stale, try state.applyLoadFinished(allocator, 9, null, null, &finished));
}

test "Review rejects a completion with stale activation" {
    const allocator = std.testing.allocator;
    var state: ReviewPageState = .{};
    defer state.deinit(allocator);
    const old_activation = state.activate(9);
    _ = state.beginRefresh().?;
    state.deactivate();
    _ = state.activate(9);
    const current = state.beginRefresh().?;
    var finished = try failedFinished(allocator, page.RequestIdentity.review(9, old_activation), current.generation, "old activation");
    defer finished.deinit(allocator);

    try std.testing.expectEqual(LoadAcceptance.stale, try state.applyLoadFinished(allocator, 9, null, null, &finished));
}

test "Review rejects a completion with stale generation" {
    const allocator = std.testing.allocator;
    var state: ReviewPageState = .{};
    defer state.deinit(allocator);
    _ = state.activate(9);
    const request = state.beginRefresh().?;
    var finished = try failedFinished(allocator, request.identity, request.generation + 1, "old generation");
    defer finished.deinit(allocator);

    try std.testing.expectEqual(LoadAcceptance.stale, try state.applyLoadFinished(allocator, 9, null, null, &finished));
}

test "Review replacement makes the older pending completion stale" {
    const allocator = std.testing.allocator;
    var state: ReviewPageState = .{};
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

test "Review moves attempted failure, replaces it, and clears it on success" {
    const allocator = std.testing.allocator;
    var state: ReviewPageState = .{};
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
    try std.testing.expect(state.normalBasisConst() != null);
}

test "Review deferred completion replacement and page deinit release exactly once" {
    const allocator = std.testing.allocator;
    var state: ReviewPageState = .{};
    _ = state.activate(3);
    const request = state.beginRefresh().?;
    state.replaceDeferredLoad(allocator, try failedFinished(allocator, request.identity, request.generation, "first"));
    state.replaceDeferredLoad(allocator, try failedFinished(allocator, request.identity, request.generation, "second"));
    state.deinit(allocator);
}

const review_test_diff =
    "diff --git a/src/old.zig b/src/old.zig\n" ++
    "--- a/src/old.zig\n" ++
    "+++ b/src/old.zig\n" ++
    "@@ -1 +1 @@\n" ++
    "-old\n" ++
    "+new\n";

const review_test_diff_changed =
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
) !app_load.ReviewLoadFinished {
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
                },
                .head_display = head_display,
                .target = .{
                    .object_format = .sha1,
                    .source_kind = .branch_range,
                    .base_oid = testOid(base_byte),
                    .head_oid = testOid(head_byte),
                    .diff_base_oid = testOid(base_byte),
                },
                .ahead_count = 1,
            },
            .diff = .{ .loaded = try app_load.buildLoadedBundle(allocator, path_diff) },
        } },
    };
}

fn installTestRetainedSelection(
    state: *ReviewPageState,
    allocator: std.mem.Allocator,
    repo_epoch: u64,
    root_identity: ?root_capability.Identity,
) !void {
    const loaded = switch (state.load.state) {
        .loaded => |*session| &session.loaded,
        else => return error.ExpectedLoadedReview,
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
    state.pinned_selection_basis = PinnedSelectionBasis.init(state.normalBasisConst().?.*);
}

test "Review loaded acceptance atomically installs matching basis and diff" {
    const allocator = std.testing.allocator;
    var state: ReviewPageState = .{};
    defer state.deinit(allocator);
    _ = state.activate(5);
    const request = state.beginRefresh().?;
    var finished = try loadedDiffFinished(allocator, request.identity, request.generation, 'a', 'b', review_test_diff);
    defer finished.deinit(allocator);

    try std.testing.expectEqual(LoadAcceptance.loaded, try state.applyLoadFinished(allocator, 5, "/work/gitframe", null, &finished));
    try std.testing.expectEqualStrings("main", state.normalBasisConst().?.base.display_name);
    try std.testing.expectEqualStrings("refs/heads/main", state.base_target.?.full_ref);
    try std.testing.expect(state.accepted_repository_identity.?.matches(5, null));
    const loaded = switch (state.load.state) {
        .loaded => |session| session.loaded,
        else => return error.ExpectedLoadedReview,
    };
    try std.testing.expectEqual(@as(usize, 1), loaded.document.files.len);
    try std.testing.expectEqualStrings("b/src/old.zig", loaded.document.files[0].new_path.?);
    try std.testing.expectEqual(file_tree.Node.Kind.repo_root, loaded.tree.nodes[0].kind);
    try std.testing.expectEqualStrings("gitframe", loaded.tree.nodes[0].name);
    try std.testing.expect(finished.result == .empty);
}

test "Review reload transfers retained selection only across the exact repository basis and diff" {
    const allocator = std.testing.allocator;
    const root_identity: root_capability.Identity = .{ .device = 3, .inode = 7 };
    const cases = [_]struct {
        name: []const u8,
        base: u8 = 'a',
        diff_base: u8 = 'a',
        head: u8 = 'b',
        root: root_capability.Identity = root_identity,
        diff: []const u8 = review_test_diff,
        empty: bool = false,
        transfers: bool,
    }{
        .{ .name = "exact", .transfers = true },
        .{ .name = "base", .base = 'c', .transfers = false },
        .{ .name = "diff-base", .diff_base = 'd', .transfers = false },
        .{ .name = "head", .head = 'e', .transfers = false },
        .{ .name = "root", .root = .{ .device = 3, .inode = 8 }, .transfers = false },
        .{ .name = "content", .diff = review_test_diff_changed, .transfers = false },
        .{ .name = "empty", .empty = true, .transfers = false },
    };

    for (cases) |case| {
        var state: ReviewPageState = .{};
        defer state.deinit(allocator);
        _ = state.activate(11);
        const first = state.beginRefresh().?;
        var first_finished = try loadedDiffFinished(allocator, first.identity, first.generation, 'a', 'b', review_test_diff);
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
        second_finished.result.loaded.basis.target.base_oid = testOid(case.base);
        second_finished.result.loaded.basis.target.diff_base_oid = testOid(case.diff_base);
        second_finished.result.loaded.basis.target.head_oid = testOid(case.head);
        state.selection_owner = .{ .keyboard_side_choice = .{
            .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "src/old.zig" } },
            .before = .{ .hunk_index = 0, .line_index = 0 },
            .after = .{ .hunk_index = 0, .line_index = 1 },
        } };
        try std.testing.expectEqual(
            LoadAcceptance.loaded,
            try state.applyLoadFinished(allocator, 11, "/repo", case.root, &second_finished),
        );
        try std.testing.expect(state.selection_owner == .none);
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

test "Review failed and stale refreshes preserve the accepted retained selection" {
    const allocator = std.testing.allocator;
    const root_identity: root_capability.Identity = .{ .device = 5, .inode = 9 };
    var state: ReviewPageState = .{};
    defer state.deinit(allocator);
    _ = state.activate(13);
    const initial = state.beginRefresh().?;
    var initial_finished = try loadedDiffFinished(allocator, initial.identity, initial.generation, 'a', 'b', review_test_diff);
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
    var stale = try loadedDiffFinished(allocator, stale_request.identity, stale_request.generation, 'c', 'd', review_test_diff_changed);
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

test "Review viewed store retains only for the same accepted oid pair" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { base: u8, head: u8, retained: bool }{
        .{ .base = 'a', .head = 'b', .retained = true },
        .{ .base = 'd', .head = 'b', .retained = false },
        .{ .base = 'a', .head = 'e', .retained = false },
    };

    for (cases) |case| {
        var state: ReviewPageState = .{};
        defer state.deinit(allocator);
        _ = state.activate(7);
        const first = state.beginRefresh().?;
        var first_finished = try loadedDiffFinished(allocator, first.identity, first.generation, 'a', 'b', review_test_diff);
        defer first_finished.deinit(allocator);
        _ = try state.applyLoadFinished(allocator, 7, "/repo", null, &first_finished);
        const first_loaded = switch (state.load.state) {
            .loaded => |*session| &session.loaded,
            else => return error.ExpectedLoadedReview,
        };
        try state.reviewed_store.set(allocator, "/repo", first_loaded.document.files[0], true);
        first_loaded.reviewed_files[0] = true;

        const second = state.beginRefresh().?;
        var second_finished = try loadedDiffFinished(allocator, second.identity, second.generation, case.base, case.head, review_test_diff);
        defer second_finished.deinit(allocator);
        _ = try state.applyLoadFinished(allocator, 7, "/repo", null, &second_finished);
        const second_loaded = switch (state.load.state) {
            .loaded => |*session| &session.loaded,
            else => return error.ExpectedLoadedReview,
        };
        try std.testing.expectEqual(case.retained, second_loaded.reviewed_files[0]);
        try std.testing.expectEqual(
            case.retained,
            try state.reviewed_store.containsFile(allocator, "/repo", second_loaded.document.files[0]),
        );
    }
}

test "Review failed replacement preserves accepted display and attempted intent" {
    const allocator = std.testing.allocator;
    var state: ReviewPageState = .{};
    defer state.deinit(allocator);
    _ = state.activate(9);
    const initial = state.beginRefresh().?;
    var initial_finished = try loadedDiffFinished(allocator, initial.identity, initial.generation, 'a', 'b', review_test_diff);
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

    try std.testing.expectEqualStrings("main", state.normalBasisConst().?.base.display_name);
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

test "Review base picker replacement close and selection have one owner" {
    const allocator = std.testing.allocator;
    var state: ReviewPageState = .{};
    defer state.deinit(allocator);
    _ = state.activate(11);

    state.selection_owner = .{ .keyboard_side_choice = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .before = .{ .hunk_index = 0, .line_index = 0 },
        .after = .{ .hunk_index = 0, .line_index = 1 },
    } };
    const first = state.beginBasePicker(allocator).?;
    try std.testing.expect(state.selection_owner == .none);
    var first_finished: app_load.ReviewBranchListFinished = .{
        .identity = first.identity,
        .generation = first.generation,
        .result = .{ .loaded = try testBranchList(allocator, "main") },
    };
    defer first_finished.deinit(allocator);
    try std.testing.expect(state.base_picker.acceptFinished(allocator, 11, &state.activation, &first_finished));
    try std.testing.expect(first_finished.result == .empty);

    const replacement = state.beginBasePicker(allocator).?;
    try std.testing.expect(state.base_picker.accepted == null);
    var stale: app_load.ReviewBranchListFinished = .{
        .identity = first.identity,
        .generation = first.generation,
        .result = .{ .loaded = try testBranchList(allocator, "stale") },
    };
    defer stale.deinit(allocator);
    try std.testing.expect(!state.base_picker.acceptFinished(allocator, 11, &state.activation, &stale));

    var wrong_epoch: app_load.ReviewBranchListFinished = .{
        .identity = replacement.identity,
        .generation = replacement.generation,
        .result = .{ .loaded = try testBranchList(allocator, "wrong-epoch") },
    };
    defer wrong_epoch.deinit(allocator);
    try std.testing.expect(!state.base_picker.acceptFinished(allocator, 12, &state.activation, &wrong_epoch));

    var wrong_activation: app_load.ReviewBranchListFinished = .{
        .identity = page.RequestIdentity.review(11, replacement.identity.activation_id + 1),
        .generation = replacement.generation,
        .result = .{ .loaded = try testBranchList(allocator, "wrong-activation") },
    };
    defer wrong_activation.deinit(allocator);
    try std.testing.expect(!state.base_picker.acceptFinished(allocator, 11, &state.activation, &wrong_activation));

    var replacement_finished: app_load.ReviewBranchListFinished = .{
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

test "Review picker and failed chosen-basis refresh retain the accepted selection authority" {
    const allocator = std.testing.allocator;
    var state: ReviewPageState = .{};
    defer state.deinit(allocator);
    _ = state.activate(23);
    const initial = state.beginRefresh().?;
    var initial_finished = try loadedDiffFinished(
        allocator,
        initial.identity,
        initial.generation,
        'a',
        'b',
        review_test_diff,
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
    var opened_finished: app_load.ReviewBranchListFinished = .{
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
    var chosen_finished: app_load.ReviewBranchListFinished = .{
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
    try std.testing.expectEqualStrings("main", state.normalBasisConst().?.base.display_name);
}

test "Review base picker owns recency order filter projection and full-ref activation" {
    const allocator = std.testing.allocator;
    var state: ReviewPageState = .{};
    defer state.deinit(allocator);
    _ = state.activate(17);
    const request = state.beginBasePicker(allocator).?;
    var finished: app_load.ReviewBranchListFinished = .{
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

test "AI Reviews picker rejects stale scan completion and admits exact generation root and store" {
    const allocator = std.testing.allocator;
    var store = try review_store.ConfiguredStore.initConfigured(allocator, "/store");
    defer store.deinit(allocator);
    const store_identity = store.identity();
    var state: ReviewPageState = .{};
    defer state.deinit(allocator);
    _ = state.activate(7);
    const identity = state.activation.currentIdentity().?;
    const root_identity: root_capability.Identity = .{ .device = 11, .inode = 13 };
    const request = state.ai_reviews.beginScan(allocator, identity, root_identity, null, false);

    var stale: app_load.ReviewHistoryScanFinished = .{
        .identity = request.identity,
        .generation = request.generation + 1,
        .store_identity = store_identity,
        .result = .{ .failed_static = "stale" },
    };
    defer stale.deinit(allocator);
    try std.testing.expect(!state.ai_reviews.acceptScan(
        allocator,
        7,
        root_identity,
        store_identity,
        &state.activation,
        &stale,
    ));
    try std.testing.expect(state.ai_reviews.phase == .scan_loading);

    var exact: app_load.ReviewHistoryScanFinished = .{
        .identity = request.identity,
        .generation = request.generation,
        .store_identity = store_identity,
        .result = .{ .failed_static = "Could not load AI reviews: test" },
    };
    defer exact.deinit(allocator);
    try std.testing.expect(state.ai_reviews.acceptScan(
        allocator,
        7,
        root_identity,
        store_identity,
        &state.activation,
        &exact,
    ));
    try std.testing.expect(state.ai_reviews.phase == .scan_failed);
    try std.testing.expect(!state.ai_reviews.interactionCapabilities().list);
    state.ai_reviews.moveSelection(1);
    state.ai_reviews.enterQuery();
    try std.testing.expect(!state.ai_reviews.queryMode());
    try std.testing.expect(state.ai_reviews.beginSelectedRun() == .none);
}

test "AI Reviews picker direct normal return cancellation closes without leaving retained state" {
    const allocator = std.testing.allocator;
    var picker: AiReviewsPickerState = .{};
    defer picker.deinit(allocator);
    _ = picker.beginDirectNormalReturn(
        allocator,
        page.RequestIdentity.review(5, 9),
        .{ .device = 2, .inode = 3 },
    );
    try std.testing.expect(picker.phase == .return_loading);
    picker.cancelLoading(allocator);
    try std.testing.expect(!picker.isOpen());
    try std.testing.expect(picker.scan_result == null);

    _ = picker.beginDirectNormalReturn(
        allocator,
        page.RequestIdentity.review(5, 10),
        .{ .device = 2, .inode = 3 },
    );
    picker.failNormalReturn("direct return failed");
    try std.testing.expect(!picker.interactionCapabilities().list);
    try std.testing.expect(picker.beginSelectedRun() == .none);

    const direct = picker.beginDirectSelection(
        allocator,
        page.RequestIdentity.review(5, 11),
        .{ .device = 2, .inode = 3 },
        undefined,
        try committed_review.ReviewId.parse("823e4567-e89b-42d3-a456-426614174000"),
        undefined,
    );
    try std.testing.expect(direct.direct);
    picker.failSelectionStatic(
        try committed_review.ReviewId.parse("823e4567-e89b-42d3-a456-426614174000"),
        "direct selection failed",
    );
    try std.testing.expect(!picker.interactionCapabilities().list);
    picker.moveSelection(1);
    picker.enterQuery();
    try std.testing.expect(!picker.queryMode());
}

test "AI Reviews picker failed Run B and normal return preserve accepted presentation A" {
    const allocator = std.testing.allocator;
    var state: ReviewPageState = .{};
    defer state.deinit(allocator);
    state.presentation = .{ .normal = .{ .basis = .{
        .base = .{
            .full_ref = try allocator.dupe(u8, "refs/heads/main"),
            .display_name = try allocator.dupe(u8, "main"),
            .kind = .local,
        },
        .head_display = try allocator.dupe(u8, "topic"),
        .target = .{ .object_format = .sha1, .source_kind = .branch_range, .base_oid = testOid('a'), .head_oid = testOid('b'), .diff_base_oid = testOid('a') },
        .ahead_count = 1,
    } } };
    _ = state.activate(9);
    const identity = state.activation.currentIdentity().?;
    const root_identity: root_capability.Identity = .{ .device = 4, .inode = 8 };
    const review_id = try committed_review.ReviewId.parse("923e4567-e89b-42d3-a456-426614174000");
    const rows = try allocator.alloc(review_store.RunSummary, 1);
    rows[0] = .{
        .review_id = review_id,
        .target = .{ .object_format = .sha1, .source_kind = .branch_range, .base_oid = testOid('c'), .head_oid = testOid('d'), .diff_base_oid = testOid('c') },
        .status = .approved,
        .created_at = "2026-08-20T00:00:00Z".*,
        .created_at_unix = 1,
        .producer_name = try allocator.dupe(u8, "reviewer"),
        .producer_model = null,
        .base_label = null,
        .head_label = null,
        .finding_count = 0,
        .availability = .available,
        .artifact_snapshot = .{
            .manifest_digest = committed_review.Sha256Digest.hash("manifest"),
            .findings_digest = committed_review.Sha256Digest.hash("findings"),
            .draft_state = .absent,
            .draft_digest = null,
            .result_digest = null,
        },
    };
    state.ai_reviews.identity = identity;
    state.ai_reviews.root_identity = root_identity;
    state.ai_reviews.phase = .ready;
    state.ai_reviews.scan_result = .{ .history = .{
        .snapshot = undefined,
        .rows = rows,
        .diagnostics = try allocator.alloc(review_store.Diagnostic, 0),
        .skipped_count = 0,
        .orphan_count = 0,
    } };
    try state.ai_reviews.rebuildSearch(allocator);
    state.ai_reviews.focus = 1;
    try std.testing.expect(std.mem.indexOf(u8, state.ai_reviews.search_labels[0], "ccccccc") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.ai_reviews.search_labels[0], "ddddddd") != null);
    try std.testing.expect(!state.isCurrentReviewTarget(&rows[0].target));
    const normal_target = state.normalBasisConst().?.target;
    try std.testing.expect(state.isCurrentReviewTarget(&normal_target));

    const status_cases = [_]struct { status: review_store.RunSummaryStatus, query: []const u8 }{
        .{ .status = .new, .query = "new" },
        .{ .status = .draft, .query = "draft" },
        .{ .status = .approved, .query = "approved" },
        .{ .status = .needs_changes, .query = "needs changes" },
        .{ .status = .canceled, .query = "canceled" },
    };
    for (status_cases) |case| {
        rows[0].status = case.status;
        rows[0].availability = if (case.status == .needs_changes) .missing else .available;
        try state.ai_reviews.publishQuery(allocator, .{});
        try state.ai_reviews.rebuildSearch(allocator);
        state.ai_reviews.enterQuery();
        for (case.query) |byte| try state.ai_reviews.insertQuery(allocator, byte);
        try std.testing.expectEqual(@as(usize, 1), state.ai_reviews.filter.source_indexes.len);
        try state.ai_reviews.clearQueryOrLeave(allocator);
        state.ai_reviews.leaveQuery();
    }
    rows[0].status = .approved;
    rows[0].availability = .available;
    try state.ai_reviews.rebuildSearch(allocator);
    state.ai_reviews.focus = 1;

    const request = switch (state.ai_reviews.beginSelectedRun()) {
        .request => |value| value,
        else => return error.ExpectedAiReviewSelection,
    };
    try std.testing.expect(request.review_id.eql(review_id));
    try std.testing.expect(!request.direct);
    const retried = switch (state.ai_reviews.retrySelectedRun()) {
        .request => |value| value,
        else => return error.ExpectedAiReviewSelectionRetry,
    };
    try std.testing.expect(retried.review_id.eql(review_id));
    try std.testing.expect(!retried.direct);
    try std.testing.expect(retried.request.generation != request.request.generation);
    state.ai_reviews.failSelectionStatic(review_id, "Run B failed");
    try std.testing.expect(state.ai_reviews.interactionCapabilities().list);
    try std.testing.expectEqualStrings("main", state.normalBasisConst().?.base.display_name);
    const accepted_head = testOid('b');
    try std.testing.expectEqualStrings(accepted_head.slice(), state.normalBasisConst().?.target.head_oid.slice());

    _ = state.ai_reviews.beginNormalReturn(false).?;
    state.ai_reviews.failNormalReturn("normal return failed");
    try std.testing.expectEqualStrings("main", state.normalBasisConst().?.base.display_name);
    try std.testing.expect(state.ai_reviews.phase == .return_failed);
    try std.testing.expect(state.ai_reviews.interactionCapabilities().list);
    const retained_retry = switch (state.ai_reviews.beginSelectedRun()) {
        .request => |value| value,
        else => return error.ExpectedRetainedSelectionAfterReturnFailure,
    };
    try std.testing.expect(retained_retry.review_id.eql(review_id));
}

test "Review base picker publication allocation failure is terminal without partial ownership" {
    const allocator = std.testing.allocator;
    var state: ReviewPageState = .{};
    defer state.deinit(allocator);
    _ = state.activate(19);
    const request = state.beginBasePicker(allocator).?;
    var finished: app_load.ReviewBranchListFinished = .{
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
    var retry_finished: app_load.ReviewBranchListFinished = .{
        .identity = retry.identity,
        .generation = retry.generation,
        .result = .{ .loaded = try testBranchList(allocator, "retry") },
    };
    defer retry_finished.deinit(allocator);
    try std.testing.expect(state.base_picker.acceptFinished(allocator, 19, &state.activation, &retry_finished));
    try std.testing.expectEqualStrings("refs/heads/retry", state.base_picker.selectedItem().?.full_ref);

    const replacement = state.beginBasePicker(allocator).?;
    var replacement_finished: app_load.ReviewBranchListFinished = .{
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

test "Review base picker live query allocation failure preserves old projection byte-for-byte" {
    const allocator = std.testing.allocator;
    var state: ReviewPageState = .{};
    defer state.deinit(allocator);
    _ = state.activate(23);
    const request = state.beginBasePicker(allocator).?;
    var finished: app_load.ReviewBranchListFinished = .{
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
