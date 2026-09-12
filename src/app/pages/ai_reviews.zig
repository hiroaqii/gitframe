//! Retained state owner for the read-only AI Reviews page.
//!
//! The page owns one selected immutable Run and its committed-diff body as a
//! snapshot, plus independent navigation, picker, Finding, human-review, and
//! exact-Run refresh state.

const std = @import("std");
const ui = @import("chasen_ui");
const committed_review = @import("../../committed_review.zig");
const finding_card = @import("../../ai_review/finding_card.zig");
const finding_projection = @import("../../ai_review/finding_projection.zig");
const context = @import("../../context.zig");
const app_state = @import("../state.zig");
const app_prompt = @import("../prompt.zig");
const diff_surface = @import("../diff_surface.zig");
const app_load = @import("../load.zig");
const page = @import("../page.zig");
const committed_diff = @import("committed_diff.zig");
const diff_render = @import("../../diff/render.zig");
const diff_source = @import("../../diff/source.zig");
const root_capability = @import("../../repo/root_capability.zig");
const review_store = @import("../../review_store.zig");
const commit_time = @import("../branch_commit_time.zig");
const human_review_decision = @import("ai_reviews/human_review_decision.zig");
const delete_confirmation = @import("ai_reviews/delete_confirmation.zig");

pub const selection_source: diff_source.SourceMode = .{ .range = "review" };

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

    /// Direct selection reloads refresh the already-visible selected Run and
    /// never present the keyboard-owned Reviews picker. Their failures return
    /// to the closed phase and are reported through the page-local status.
    pub fn isPickerVisible(self: *const AiReviewsPickerState) bool {
        return switch (self.phase) {
            .closed => false,
            .selection_loading => |selection| !selection.direct,
            .selection_failed => |selection| !selection.direct,
            else => true,
        };
    }

    pub fn queryMode(self: *const AiReviewsPickerState) bool {
        return self.input_mode == .query;
    }

    pub fn loading(self: *const AiReviewsPickerState) bool {
        return switch (self.phase) {
            .scan_loading, .selection_loading => true,
            else => false,
        };
    }

    /// The phase and retained snapshot together are the single authority for
    /// both rendered commands and state admission.
    pub fn interactionCapabilities(self: *const AiReviewsPickerState) InteractionCapabilities {
        const retained_list = self.scan_result != null;
        return switch (self.phase) {
            .closed => .{},
            .scan_loading, .selection_loading => .{ .retry = true, .cancel = true },
            .ready, .empty => .{ .list = retained_list, .retry = true, .close = true },
            .scan_failed => .{ .retry = true, .close = true },
            .selection_failed => .{ .list = retained_list, .retry = true, .close = true },
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
        finished: *app_load.AiReviewScanFinished,
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

    pub fn acceptsSelection(
        self: *const AiReviewsPickerState,
        repo_epoch: u64,
        root_identity: ?root_capability.Identity,
        store_identity: review_store.ConfigurationIdentity,
        activation: *const diff_surface.authority.Lifecycle,
        finished: app_load.AiReviewSelectionFinished,
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

    pub fn cancelLoading(self: *AiReviewsPickerState, allocator: std.mem.Allocator) void {
        const restore = switch (self.phase) {
            .selection_loading => |value| !value.direct,
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
        const count = self.filter.source_indexes.len;
        if (count == 0) return;
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
        const history_value = self.historyConst() orelse return null;
        const source_index = self.filter.sourceIndex(self.focus) orelse return null;
        if (source_index >= history_value.rows.len) return null;
        return &history_value.rows[source_index];
    }

    pub fn selectedStoreSnapshot(self: *const AiReviewsPickerState) ?review_store.StoreSnapshot {
        const history_value = self.historyConst() orelse return null;
        return history_value.snapshot;
    }

    /// Prefer the next visible row, then the previous one, after deleting the
    /// focused Run. The returned identity remains valid after the scan owner is
    /// released because ReviewId is a value type.
    pub fn adjacentSelectedReviewId(self: *const AiReviewsPickerState) ?committed_review.ReviewId {
        const history_value = self.historyConst() orelse return null;
        const count = self.filter.source_indexes.len;
        if (count <= 1 or self.focus >= count) return null;
        const visible_index = if (self.focus + 1 < count) self.focus + 1 else self.focus - 1;
        const source_index = self.filter.sourceIndex(visible_index) orelse return null;
        if (source_index >= history_value.rows.len) return null;
        return history_value.rows[source_index].review_id;
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
        return activation.acceptsPageInstance(identity, repo_epoch);
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
        const preferred = if (self.selectedRow()) |row| row.review_id else null;
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
                self.focus = visible_index;
                self.syncFilterFocus();
                return;
            }
        }
    }

    fn syncFilterFocus(self: *AiReviewsPickerState) void {
        if (self.filter.source_indexes.len == 0) return;
        self.filter.list.focus.index = @min(self.focus, self.filter.source_indexes.len - 1);
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

pub const SelectedRunPresentation = struct {
    selection: review_store.SelectedRunRead,
    base_display: []u8,
    head_display: []u8,
    finding_presentation_cache: ?FindingPresentationCache = null,

    pub fn deinit(self: *SelectedRunPresentation, allocator: std.mem.Allocator) void {
        if (self.finding_presentation_cache) |*cache| cache.deinit(allocator);
        allocator.free(self.head_display);
        allocator.free(self.base_display);
        self.selection.deinit(allocator);
        self.* = undefined;
    }

    pub fn reviewId(self: *const SelectedRunPresentation) committed_review.ReviewId {
        return self.selection.artifacts.manifest.value.review_id;
    }

    pub fn target(self: *const SelectedRunPresentation) committed_review.CommittedReviewTarget {
        return self.selection.artifacts.manifest.value.target;
    }

    pub fn binding(self: *const SelectedRunPresentation) review_store.ReviewRunBinding {
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
        entry.start_line != model.anchor_range.start_line or
        entry.end_line != model.anchor_range.end_line or
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
    return rows -| finding_card.body_rows;
}

pub const FindingCardLayout = struct {
    // Coordinates are local to either the unified diff surface or one
    // side-by-side pane. Keep the hunk-guide gutter and one blank cell before
    // the left rail; reserve one blank cell after the right rail.
    pub const border_left_col: u16 = diff_render.cursor_gutter_width + 1;
    pub const content_col: u16 = border_left_col + 1;
    pub const right_padding: u16 = 1;

    pub fn borderRightCol(row_width: u16) ?u16 {
        if (row_width <= border_left_col + right_padding) return null;
        const right_col = row_width - 1 - right_padding;
        return if (right_col > border_left_col) right_col else null;
    }

    pub fn expandedContentWidth(row_width: u16) u16 {
        const right_col = borderRightCol(row_width) orelse return 0;
        return right_col -| content_col;
    }

    pub fn collapsedContentWidth(row_width: u16) u16 {
        return row_width -| content_col;
    }
};

pub fn findingCardContentWidth(row_width: u16) u16 {
    return FindingCardLayout.expandedContentWidth(row_width);
}

test "Finding card content width reserves the painter border across wrap boundaries" {
    try std.testing.expectEqual(diff_render.cursor_gutter_width + 1, FindingCardLayout.border_left_col);
    try std.testing.expectEqual(FindingCardLayout.border_left_col + 1, FindingCardLayout.content_col);
    try std.testing.expect(FindingCardLayout.borderRightCol(5) == null);
    try std.testing.expectEqual(@as(u16, 4), FindingCardLayout.borderRightCol(6).?);
    try std.testing.expectEqual(@as(u16, 18), FindingCardLayout.borderRightCol(20).?);
    try std.testing.expectEqual(@as(u16, 0), findingCardContentWidth(0));
    try std.testing.expectEqual(@as(u16, 0), findingCardContentWidth(1));
    try std.testing.expectEqual(@as(u16, 0), findingCardContentWidth(2));
    try std.testing.expectEqual(@as(u16, 0), findingCardContentWidth(5));
    try std.testing.expectEqual(@as(u16, 0), findingCardContentWidth(6));
    try std.testing.expectEqual(@as(u16, 14), findingCardContentWidth(20));
    try std.testing.expectEqual(@as(u16, 16), FindingCardLayout.collapsedContentWidth(20));
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
    try std.testing.expectEqual(@as(usize, 872), per_entry);
    const maximum_display = "Producer: ".len + committed_review.limits.max_short_text_bytes +
        "\nModel: ".len + committed_review.limits.max_short_text_bytes +
        "\n\n".len + committed_review.limits.max_body_bytes +
        "\n\nSuggestion:\n".len + committed_review.limits.max_body_bytes;
    try std.testing.expectEqual(@as(usize, 131_618), maximum_display);
    const logical_capacity = committed_review.limits.max_findings * per_entry +
        maximum_display + (maximum_display + 1) * @sizeOf(usize);
    try std.testing.expectEqual(@as(usize, 4_756_282), logical_capacity);
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

/// AI Reviews owns only one selected immutable Run plus its page-local picker,
/// Finding, and human-review state. Compare state is structurally unreachable.
pub const AiReviewsPageState = struct {
    activation: diff_surface.authority.Lifecycle = .init(.ai_reviews),
    status: app_state.StatusMessage = .{},
    diff: committed_diff.State = .{},
    selected_run: ?SelectedRunPresentation = null,
    picker: AiReviewsPickerState = .{},
    delete_confirmation: delete_confirmation.State = .{},
    human_review_decision: human_review_decision.State = .{},
    finding_card: finding_card.State = .unfocused,

    pub fn activate(self: *AiReviewsPageState, repo_epoch: u64) u64 {
        if (self.activation.next_activation_id == 0) {
            return self.activation.activate(
                repo_epoch,
                if (self.selected_run != null) .immutable else .unavailable,
                .unavailable,
                .unavailable,
            );
        }
        return self.activation.reactivateRetained(
            repo_epoch,
            if (self.directRefreshPending()) .pending else if (self.selected_run != null) .immutable else .unavailable,
            .unavailable,
            .unavailable,
        );
    }

    pub fn deactivate(self: *AiReviewsPageState) void {
        self.diff.selection_owner = .none;
        self.human_review_decision.close();
        self.activation.deactivate();
    }

    pub fn hasAcceptedDisplay(self: *const AiReviewsPageState) bool {
        return self.selected_run != null and self.diff.hasAcceptedDiff();
    }

    pub fn activeReviewId(self: *const AiReviewsPageState) ?committed_review.ReviewId {
        const selected = if (self.selected_run) |*value| value else return null;
        return selected.reviewId();
    }

    pub fn isCurrentReview(self: *const AiReviewsPageState, review_id: committed_review.ReviewId) bool {
        const current = self.activeReviewId() orelse return false;
        return current.eql(review_id);
    }

    pub fn currentTarget(self: *const AiReviewsPageState) ?committed_review.CommittedReviewTarget {
        const selected = if (self.selected_run) |*value| value else return null;
        return selected.target();
    }

    pub fn isCurrentReviewTarget(self: *const AiReviewsPageState, target: *const committed_review.CommittedReviewTarget) bool {
        const current = self.currentTarget() orelse return false;
        return current.eql(target);
    }

    pub fn selectedRun(self: *AiReviewsPageState) ?*SelectedRunPresentation {
        return if (self.selected_run) |*value| value else null;
    }

    pub fn selectedRunConst(self: *const AiReviewsPageState) ?*const SelectedRunPresentation {
        return if (self.selected_run) |*value| value else null;
    }

    pub fn contentForFindingCard(self: *const AiReviewsPageState, model: finding_card.FindingCardModel) ?FindingCardContent {
        const selected = self.selectedRunConst() orelse return null;
        return findingCardContent(&selected.selection, model);
    }

    pub fn cachedFindingBody(
        self: *const AiReviewsPageState,
        model: finding_card.FindingCardModel,
        width: u16,
    ) ?CachedFindingBody {
        const selected = self.selectedRunConst() orelse return null;
        const cache = if (selected.finding_presentation_cache) |*value| value else return null;
        const frame_key = cache.frame_key orelse return null;
        if (!finding_card.identityEql(frame_key.identity, model.identity)) return null;
        const body_key = cache.body_key orelse return null;
        if (!body_key.eql(model, width)) return null;
        if (cache.body_text_len > cache.body_display.len or cache.body_row_count > cache.body_row_starts.len) return null;
        return .{
            .text = cache.body_display[0..cache.body_text_len],
            .row_starts = cache.body_row_starts[0..cache.body_row_count],
        };
    }

    pub fn releaseFindingPresentationCache(self: *AiReviewsPageState, allocator: std.mem.Allocator) void {
        const selected = self.selectedRun() orelse return;
        if (selected.finding_presentation_cache) |*cache| cache.deinit(allocator);
        selected.finding_presentation_cache = null;
    }

    pub fn advanceSelectionLayoutRevision(self: *AiReviewsPageState) void {
        self.diff.advanceSelectionLayoutRevision();
    }

    pub fn clearRetainedSelection(self: *AiReviewsPageState, allocator: std.mem.Allocator) void {
        self.diff.clearRetainedSelection(allocator);
    }

    /// Release a clean selected Run without affecting the open history picker.
    pub fn closeSelectedRun(self: *AiReviewsPageState, allocator: std.mem.Allocator) void {
        self.human_review_decision.close();
        self.finding_card = .unfocused;
        self.diff.deinit(allocator);
        self.diff = .{};
        if (self.selected_run) |*selected| selected.deinit(allocator);
        self.selected_run = null;
        if (self.activation.currentIdentity()) |identity| {
            _ = self.activation.finishMember(identity, .source, .unavailable);
        }
    }

    pub fn commitSelectedRun(
        self: *AiReviewsPageState,
        allocator: std.mem.Allocator,
        repo_epoch: u64,
        repo_root: ?[]const u8,
        root_identity: ?root_capability.Identity,
        bundle: *app_load.AiReviewLoadedBundle,
    ) !void {
        const manifest = &bundle.selection.artifacts.manifest.value;
        const target = manifest.target;
        const pair_changed = if (self.currentTarget()) |current| !current.eql(&target) else true;
        const source_lines: ?usize = switch (bundle.diff) {
            .loaded => |*diff_bundle| diff_bundle.loaded.lines,
            .empty => null,
        };
        var cache = try FindingPresentationCache.init(allocator, &bundle.selection, source_lines);
        errdefer if (cache) |*value| value.deinit(allocator);
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

        try self.diff.replaceDiff(
            allocator,
            repo_epoch,
            repo_root,
            root_identity,
            selection_source,
            target,
            pair_changed,
            false,
            &bundle.diff,
        );
        self.human_review_decision.close();
        self.diff.clearRetainedSelection(allocator);
        if (self.selected_run) |*old| old.deinit(allocator);
        self.selected_run = .{
            .selection = bundle.selection,
            .base_display = base_display,
            .head_display = head_display,
            .finding_presentation_cache = cache,
        };
        bundle.selection = undefined;
        cache = null;
        self.finding_card = .unfocused;
        self.advanceSelectionLayoutRevision();
    }

    pub fn diffSurface(self: *AiReviewsPageState, layout: diff_surface.Layout) diff_surface.DiffSurface {
        return self.diff.diffSurface(.{
            .activation = &self.activation,
            .status = &self.status,
            .source = selection_source,
            .layout = layout,
            .current_target = self.currentTarget(),
            .live_drag_deferred_source = false,
        });
    }

    pub fn readSurface(self: *const AiReviewsPageState, layout: diff_surface.Layout) diff_surface.ReadSurface {
        return self.diff.readSurface(.{
            .activation = &self.activation,
            .status = &self.status,
            .source = selection_source,
            .layout = layout,
            .current_target = self.currentTarget(),
            .live_drag_deferred_source = false,
        });
    }

    pub fn deinit(self: *AiReviewsPageState, allocator: std.mem.Allocator) void {
        self.diff.deinit(allocator);
        if (self.selected_run) |*selected| selected.deinit(allocator);
        self.picker.deinit(allocator);
        self.delete_confirmation.deinit(allocator);
        self.human_review_decision.deinit();
        self.* = .{};
    }

    fn directRefreshPending(self: *const AiReviewsPageState) bool {
        return switch (self.picker.phase) {
            .selection_loading => |loading| loading.direct,
            else => false,
        };
    }
};

test "AI Reviews reuses its retained activation without selecting a Run" {
    const allocator = std.testing.allocator;
    var state: AiReviewsPageState = .{};
    defer state.deinit(allocator);

    const first = state.activate(9);
    state.diff.viewer.diff_scroll = 7;
    state.deactivate();
    const second = state.activate(9);

    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(usize, 7), state.diff.viewer.diff_scroll);
    try std.testing.expectEqual(page.Id.ai_reviews, state.activation.currentIdentity().?.origin);
    try std.testing.expect(state.selectedRunConst() == null);

    const rows = try allocator.alloc(review_store.RunSummary, 2);
    const target: committed_review.CommittedReviewTarget = .{
        .object_format = .sha1,
        .source_kind = .branch_range,
        .base_oid = try committed_review.ObjectId.parse(.sha1, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        .head_oid = try committed_review.ObjectId.parse(.sha1, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
        .diff_base_oid = try committed_review.ObjectId.parse(.sha1, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
    };
    for (rows, 0..) |*row, index| {
        row.* = .{
            .review_id = try committed_review.ReviewId.parse(if (index == 0)
                "123e4567-e89b-42d3-a456-426614174000"
            else
                "223e4567-e89b-42d3-a456-426614174000"),
            .target = target,
            .status = if (index == 0) .approved else .needs_changes,
            .created_at = if (index == 0) "2026-09-12T09:00:00Z".* else "2026-09-12T09:01:00Z".*,
            .created_at_unix = 1_000 + @as(i64, @intCast(index)),
            .producer_name = try allocator.dupe(u8, if (index == 0) "first" else "second"),
            .producer_model = null,
            .base_label = try allocator.dupe(u8, "release-base"),
            .head_label = try allocator.dupe(u8, "feature-head"),
            .finding_count = @intCast(index + 1),
            .availability = .available,
            .artifact_snapshot = .{
                .manifest_digest = committed_review.Sha256Digest.hash(if (index == 0) "manifest-a" else "manifest-b"),
                .findings_digest = committed_review.Sha256Digest.hash(if (index == 0) "findings-a" else "findings-b"),
                .draft_state = .absent,
                .draft_digest = null,
                .result_digest = null,
            },
        };
    }
    state.picker.scan_result = .{ .history = .{
        .snapshot = .{
            .root_device = 1,
            .root_inode = 2,
            .repository_locator = .{ .device = 3, .inode = 4 },
            .review_repository_id = try committed_review.ReviewRepositoryId.parse("323e4567-e89b-42d3-a456-426614174000"),
        },
        .rows = rows,
        .diagnostics = try allocator.alloc(review_store.Diagnostic, 0),
        .skipped_count = 0,
        .orphan_count = 0,
    } };
    try state.picker.rebuildSearch(allocator);
    const search_labels: []const []const u8 = state.picker.search_labels;
    try state.picker.filter.apply(allocator, search_labels, "release-base");
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, state.picker.filter.source_indexes);
    try state.picker.filter.apply(allocator, search_labels, "feature-head");
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, state.picker.filter.source_indexes);
}
