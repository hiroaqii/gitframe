//! History page state and catalog task admission.

const std = @import("std");
const app_load = @import("../load.zig");
const app_page = @import("../page.zig");
const app_state = @import("../state.zig");
const diff_surface = @import("../diff_surface.zig");
const diff_source = @import("../../diff/source.zig");
const root_capability = @import("../../repo/root_capability.zig");
const committed_diff = @import("committed_diff.zig");
const catalog = @import("history/catalog.zig");
const input = @import("history/input.zig");
pub const interaction = @import("history/interaction.zig");
pub const preview = @import("history/preview.zig");
const selection = @import("history/selection.zig");
const git_history = @import("../../git/history.zig");

pub const Msg = input.Msg;
pub const selection_source: diff_source.SourceMode = .{ .range = "history" };

pub const CurrentView = enum { picker, diff };

pub const LoadState = enum {
    idle,
    no_repository,
    loading,
    loaded,
    empty,
    failed,
};

pub const CatalogPending = struct {
    identity: app_page.RequestIdentity,
    root_identity: root_capability.Identity,
    generation: u64,
    request: app_load.HistoryCatalogRequest,

    pub fn matches(self: CatalogPending, finished: *const app_load.HistoryCatalogFinished) bool {
        return std.meta.eql(self.identity, finished.identity) and
            self.root_identity.eql(finished.root_identity) and
            self.generation == finished.generation and
            std.meta.eql(self.request, finished.request);
    }
};

pub const DiffPending = struct {
    identity: app_page.RequestIdentity,
    root_identity: root_capability.Identity,
    generation: u64,
    request: git_history.SelectionRequest,

    pub fn matches(self: DiffPending, finished: *const app_load.HistoryDiffFinished) bool {
        return std.meta.eql(self.identity, finished.identity) and
            self.root_identity.eql(finished.root_identity) and
            self.generation == finished.generation and
            std.meta.eql(self.request, finished.request);
    }
};

pub const Pending = union(enum) {
    catalog: CatalogPending,
    diff: DiffPending,
};

pub const AcceptedSelection = struct {
    request: git_history.SelectionRequest,
    origin: git_history.HeadDisplay,
    selected_parent_count: u16,
    picker_scroll: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        request: git_history.SelectionRequest,
        snapshot: *const git_history.Snapshot,
        records: []const git_history.Record,
        picker_scroll: usize,
    ) !AcceptedSelection {
        const selected_index = switch (request.intent) {
            .single => |single| single.index,
            .range => |range| range.newest_index,
        };
        if (selected_index >= records.len or !records[selected_index].oid.eql(&request.basis.after))
            return error.InvalidSelection;
        const origin = try cloneHeadDisplay(allocator, snapshot.display);
        return .{
            .request = request,
            .origin = origin,
            .selected_parent_count = records[selected_index].parent_count,
            .picker_scroll = picker_scroll,
        };
    }

    pub fn deinit(self: *AcceptedSelection, allocator: std.mem.Allocator) void {
        self.origin.deinit(allocator);
        self.* = undefined;
    }

    pub fn presentationIdentity(self: AcceptedSelection) committed_diff.PresentationIdentity {
        return .{ .diff_basis = self.request.basis };
    }
};

pub const ApplyOutcome = enum { discarded, changed, failed };

pub const HistoryPageState = struct {
    transition_publication: @import("../screen_transition.zig").Publication = .none,
    activation: diff_surface.authority.Lifecycle = .init(.history),
    repo_epoch: u64 = 0,
    root_identity: ?root_capability.Identity = null,
    generation: u64 = 0,
    pending: ?Pending = null,
    needs_probe: ?app_load.HistoryProbeReason = null,
    needs_initial: bool = false,
    initial_policy: app_load.HistoryInitialPolicy = .reset,
    needs_continuation: bool = false,
    load_state: LoadState = .idle,
    catalog: catalog.State = .{},
    catalog_hidden: bool = false,
    observed_context: ?git_history.Snapshot = null,
    draft: selection.Draft = .single,
    render_now_unix: ?i64 = null,
    current_view: CurrentView = .picker,
    accepted: ?AcceptedSelection = null,
    interaction_state: interaction.State = .{},
    preview_state: preview.State = .{},
    diff: committed_diff.State = .{},
    status: app_state.StatusMessage = .{},

    pub fn deinit(self: *HistoryPageState, allocator: std.mem.Allocator) void {
        self.catalog.deinit(allocator);
        if (self.observed_context) |*snapshot| snapshot.deinit(allocator);
        if (self.accepted) |*accepted| accepted.deinit(allocator);
        self.preview_state.deinit(allocator);
        self.diff.deinit(allocator);
        self.* = .{};
    }

    pub fn activate(self: *HistoryPageState, allocator: std.mem.Allocator, repo_epoch: u64, identity: ?root_capability.Identity) void {
        self.preview_state.invalidate(allocator);
        self.pending = null;
        self.needs_probe = null;
        self.needs_initial = false;
        self.needs_continuation = false;
        const root = identity orelse {
            self.catalog.clear(allocator);
            self.clearObservedContext(allocator);
            self.catalog_hidden = false;
            self.draft = .single;
            self.render_now_unix = null;
            self.clearAccepted(allocator);
            self.repo_epoch = repo_epoch;
            self.root_identity = null;
            self.needs_initial = false;
            self.load_state = .no_repository;
            _ = self.activation.activate(repo_epoch, .unavailable, .unavailable, .unavailable);
            return;
        };
        const same_repository = self.repo_epoch == repo_epoch and
            self.root_identity != null and self.root_identity.?.eql(root);
        if (!same_repository) {
            self.catalog.clear(allocator);
            self.clearObservedContext(allocator);
            self.catalog_hidden = false;
            self.draft = .single;
            self.render_now_unix = null;
            self.clearAccepted(allocator);
        }
        self.repo_epoch = repo_epoch;
        self.root_identity = root;
        _ = self.activation.activate(
            repo_epoch,
            if (self.accepted != null) .immutable else .unavailable,
            .unavailable,
            .unavailable,
        );
        if (same_repository and (self.catalog.snapshot != null or self.accepted != null)) {
            self.needs_probe = .activation;
        } else {
            self.needs_initial = true;
            self.initial_policy = .reset;
        }
        self.catalog_hidden = self.current_view == .picker;
        self.load_state = .loading;
        self.status.clear();
    }

    pub fn deactivate(self: *HistoryPageState) void {
        self.preview_state.deactivate();
        self.diff.selection_owner = .none;
        self.activation.deactivate();
        self.pending = null;
        self.needs_probe = null;
        self.needs_initial = false;
        self.needs_continuation = false;
        if (self.catalog.snapshot != null) self.load_state = if (self.catalog.records.items.len == 0) .empty else .loaded;
    }

    pub fn repositoryChanged(
        self: *HistoryPageState,
        allocator: std.mem.Allocator,
        repo_epoch: u64,
        identity: ?root_capability.Identity,
    ) void {
        self.preview_state.invalidate(allocator);
        self.catalog.clear(allocator);
        self.clearObservedContext(allocator);
        self.catalog_hidden = false;
        self.draft = .single;
        self.render_now_unix = null;
        self.clearAccepted(allocator);
        self.activation.deactivate();
        self.pending = null;
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        self.needs_probe = null;
        self.repo_epoch = repo_epoch;
        self.root_identity = identity;
        self.needs_continuation = false;
        self.needs_initial = false;
        self.load_state = if (identity == null) .no_repository else .idle;
    }

    pub fn requestReload(self: *HistoryPageState, allocator: std.mem.Allocator) void {
        if (self.current_view == .picker and !self.catalog_hidden and self.draft.isRange()) {
            self.status.set("Cancel range selection before reloading", .{});
            return;
        }
        self.beginRevalidation(allocator, .reload);
    }

    pub fn branchSwitchFinished(self: *HistoryPageState, allocator: std.mem.Allocator, succeeded: bool) void {
        self.diff.selection_owner = .none;
        if (self.activation.currentIdentity()) |identity| {
            _ = self.activation.finishMember(identity, .source, if (self.accepted != null) .immutable else .unavailable);
        }
        if (succeeded and self.current_view == .picker) self.draft = .single;
        // Failure rechecks HEAD even during a range draft, preserving that draft
        // only when the activation probe finds the same branch context.
        self.beginRevalidation(allocator, if (succeeded) .reload else .activation);
    }

    fn beginRevalidation(self: *HistoryPageState, allocator: std.mem.Allocator, reason: app_load.HistoryProbeReason) void {
        self.preview_state.invalidate(allocator);
        self.pending = null;
        self.needs_probe = null;
        self.needs_initial = false;
        self.needs_continuation = false;
        if (self.activation.currentIdentity() == null or self.root_identity == null) {
            self.needs_initial = false;
            self.load_state = .no_repository;
            return;
        }
        self.needs_probe = reason;
        self.load_state = .loading;
        self.catalog_hidden = self.current_view == .picker;
        self.status.clear();
    }

    pub fn requestContinuation(self: *HistoryPageState) void {
        if (self.activation.currentIdentity() == null or self.pending != null or self.catalog_hidden or !self.catalog.moreRowSelected()) return;
        self.needs_continuation = true;
        self.load_state = .loading;
    }

    pub fn cancelLoad(self: *HistoryPageState) void {
        if (self.pending == null and self.needs_probe == null and !self.needs_initial and !self.needs_continuation) {
            if (self.current_view == .picker and self.catalog_hidden and self.accepted != null) {
                self.current_view = .diff;
                self.status.clear();
            }
            return;
        }
        const return_to_accepted = self.current_view == .picker and self.catalog_hidden and self.accepted != null;
        const was_diff = if (self.pending) |pending| std.meta.activeTag(pending) == .diff else false;
        const retain_hidden_catalog = self.current_view == .picker and self.catalog_hidden and
            self.catalog.snapshot != null and !was_diff;
        self.pending = null;
        self.needs_probe = null;
        self.needs_initial = false;
        self.needs_continuation = false;
        self.catalog_hidden = retain_hidden_catalog;
        self.load_state = if (retain_hidden_catalog)
            .failed
        else if (self.catalog.snapshot == null)
            .idle
        else if (self.catalog.records.items.len == 0)
            .empty
        else
            .loaded;
        if (was_diff) {
            if (self.activation.currentIdentity()) |identity| {
                _ = self.activation.finishMember(identity, .source, if (self.accepted != null) .immutable else .unavailable);
            }
            self.status.set("History diff load canceled", .{});
        } else {
            self.status.set("History load canceled", .{});
        }
        if (return_to_accepted) {
            self.current_view = .diff;
            self.status.clear();
        }
    }

    pub fn nextRequest(self: *HistoryPageState) ?app_load.HistoryCatalogRequest {
        if (self.activation.currentIdentity() == null or self.pending != null or self.root_identity == null) return null;
        if (self.needs_probe) |reason| return .{ .probe = reason };
        if (self.needs_initial) return .{ .initial = self.initial_policy };
        if (self.needs_continuation) {
            const snapshot = self.catalog.snapshot orelse return null;
            const cursor = self.catalog.continuation orelse return null;
            return .{ .continuation = .{ .format = snapshot.object_format, .cursor = cursor } };
        }
        return null;
    }

    pub fn reserveGeneration(self: *HistoryPageState) u64 {
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        return self.generation;
    }

    pub fn armCatalog(self: *HistoryPageState, pending: CatalogPending) void {
        self.pending = .{ .catalog = pending };
        self.needs_probe = null;
        self.needs_initial = false;
        self.needs_continuation = false;
        self.load_state = .loading;
    }

    pub fn armDiff(self: *HistoryPageState, pending: DiffPending) void {
        self.pending = .{ .diff = pending };
        self.load_state = .loading;
        self.activation.markPending(.source);
    }

    pub fn rejectPreparation(self: *HistoryPageState) void {
        self.transition_publication = .failed;
        self.pending = null;
        self.needs_probe = null;
        self.needs_initial = false;
        self.needs_continuation = false;
        self.load_state = .failed;
        self.status.set("History load could not be prepared", .{});
    }

    pub fn rejectSpawn(self: *HistoryPageState, generation: u64) void {
        const pending = self.pending orelse return;
        const catalog_pending = switch (pending) {
            .catalog => |value| value,
            .diff => return,
        };
        if (catalog_pending.generation != generation) return;
        self.transition_publication = .failed;
        self.pending = null;
        self.load_state = .failed;
        self.status.set("History load could not be started", .{});
    }

    pub fn rejectDiffPreparation(self: *HistoryPageState, message: []const u8) void {
        self.load_state = if (self.catalog.records.items.len == 0) .empty else .loaded;
        self.status.set("{s}", .{message});
    }

    pub fn rejectDiffSpawn(self: *HistoryPageState, generation: u64, message: []const u8) void {
        const pending = self.pending orelse return;
        const diff_pending = switch (pending) {
            .diff => |value| value,
            .catalog => return,
        };
        if (diff_pending.generation != generation) return;
        self.pending = null;
        self.rejectDiffPreparation(message);
        if (self.activation.currentIdentity()) |identity| {
            _ = self.activation.finishMember(identity, .source, if (self.accepted != null) .immutable else .failed);
        }
    }

    pub fn applyFinished(
        self: *HistoryPageState,
        allocator: std.mem.Allocator,
        current_identity: app_page.RequestIdentity,
        current_root: ?root_capability.Identity,
        finished: *app_load.HistoryCatalogFinished,
    ) !ApplyOutcome {
        const pending_value = self.pending orelse return .discarded;
        const pending = switch (pending_value) {
            .catalog => |value| value,
            .diff => return .discarded,
        };
        if (!pending.matches(finished)) return .discarded;
        self.pending = null;
        const root = current_root orelse return .discarded;
        const active_identity = self.activation.currentIdentity() orelse return .discarded;
        if (!std.meta.eql(active_identity, current_identity) or
            !std.meta.eql(current_identity, pending.identity) or !root.eql(pending.root_identity))
            return .discarded;

        switch (finished.result) {
            .failure => |failure| {
                if (std.meta.activeTag(pending.request) == .probe and self.current_view == .diff and self.accepted != null) {
                    self.load_state = if (self.catalog.records.items.len == 0) .empty else .loaded;
                    self.status.set("History HEAD check failed: {s}", .{@tagName(failure)});
                } else {
                    self.load_state = .failed;
                    self.status.set("History load failed: {s}", .{@tagName(failure)});
                }
                self.transition_publication = .failed;
                return .failed;
            },
            .loaded => |*page| {
                switch (pending.request) {
                    .probe => |reason| {
                        const outcome = self.applyProbe(allocator, reason, page);
                        self.transition_publication = if (outcome == .failed) .failed else if (self.needs_initial) .none else .accepted;
                        return outcome;
                    },
                    .initial => |policy| try self.applyInitial(allocator, policy, page, finished.render_now_unix),
                    .continuation => {
                        try self.catalog.append(allocator, page);
                        self.preview_state.catalogPublished(allocator);
                    },
                }
                if (std.meta.activeTag(pending.request) == .continuation) {
                    self.load_state = if (self.catalog.records.items.len == 0) .empty else .loaded;
                    self.status.clear();
                }
                self.transition_publication = .accepted;
                return .changed;
            },
        }
    }

    pub fn beginDiffRequest(self: *HistoryPageState) ?git_history.SelectionRequest {
        if (self.pending != null or self.activation.currentIdentity() == null or self.root_identity == null) return null;
        return switch (self.selectionRequest()) {
            .request => |request| request,
            .unavailable => |unavailable| blk: {
                switch (unavailable) {
                    .missing_first_parent => |missing| self.status.set(
                        "History diff unavailable: first parent {s} is missing",
                        .{missing.oid.short()},
                    ),
                    else => self.status.set("History diff unavailable: {s}", .{@tagName(unavailable)}),
                }
                break :blk null;
            },
        };
    }

    pub fn applyDiffFinished(
        self: *HistoryPageState,
        allocator: std.mem.Allocator,
        repo_root: ?[]const u8,
        current_identity: app_page.RequestIdentity,
        current_root: ?root_capability.Identity,
        finished: *app_load.HistoryDiffFinished,
    ) !ApplyOutcome {
        const pending_value = self.pending orelse return .discarded;
        const pending = switch (pending_value) {
            .diff => |value| value,
            .catalog => return .discarded,
        };
        if (!pending.matches(finished)) return .discarded;
        self.pending = null;
        const root = current_root orelse return .discarded;
        const active_identity = self.activation.currentIdentity() orelse return .discarded;
        if (!std.meta.eql(active_identity, current_identity) or
            !std.meta.eql(current_identity, pending.identity) or !root.eql(pending.root_identity))
            return .discarded;

        switch (finished.result) {
            .loaded => |*incoming| {
                const snapshot = if (self.catalog.snapshot) |*value| value else return .discarded;
                if (!selectionMatchesCatalog(snapshot, self.catalog.records.items, pending.request)) {
                    self.load_state = if (self.catalog.records.items.len == 0) .empty else .loaded;
                    self.status.set("History selection changed before its diff completed", .{});
                    _ = self.activation.finishMember(current_identity, .source, if (self.accepted != null) .immutable else .failed);
                    return .failed;
                }
                var accepted = try AcceptedSelection.init(
                    allocator,
                    pending.request,
                    snapshot,
                    self.catalog.records.items,
                    self.catalog.scroll,
                );
                var accepted_owned = true;
                defer if (accepted_owned) accepted.deinit(allocator);
                const incoming_identity = accepted.presentationIdentity();
                const current_presentation = if (self.accepted) |value| value.presentationIdentity() else null;
                const transfer_selection = self.diff.retainedSelectionTransfersWithIdentity(
                    self.repo_epoch,
                    current_root,
                    selection_source,
                    current_presentation,
                    incoming_identity,
                    incoming,
                );
                const pair_changed = if (current_presentation) |current|
                    !current.eql(incoming_identity)
                else
                    true;
                try self.diff.replaceDiffWithIdentity(
                    allocator,
                    self.repo_epoch,
                    repo_root,
                    current_root,
                    selection_source,
                    incoming_identity,
                    pair_changed,
                    transfer_selection,
                    incoming,
                );
                finished.result = .empty;
                if (self.accepted) |*old| old.deinit(allocator);
                self.accepted = accepted;
                accepted_owned = false;
                self.current_view = .diff;
                self.load_state = .loaded;
                self.status.clear();
                _ = self.activation.finishMember(current_identity, .source, .immutable);
                return .changed;
            },
            .unavailable => |failure| {
                self.load_state = if (self.catalog.records.items.len == 0) .empty else .loaded;
                self.status.set("History diff unavailable: {s}", .{@tagName(failure)});
                _ = self.activation.finishMember(current_identity, .source, if (self.accepted != null) .immutable else .failed);
                return .failed;
            },
            .failed_static => |message| {
                self.load_state = if (self.catalog.records.items.len == 0) .empty else .loaded;
                self.status.set("{s}", .{message});
                _ = self.activation.finishMember(current_identity, .source, if (self.accepted != null) .immutable else .failed);
                return .failed;
            },
            .empty => return .discarded,
        }
    }

    pub fn applyInput(self: *HistoryPageState, msg: Msg, body_height: u16) void {
        const previous_cursor = self.catalog.cursor;
        const previous_anchor = self.draft.anchor();
        switch (msg) {
            .move_previous => self.catalog.movePrevious(body_height),
            .move_next => self.catalog.moveNext(body_height),
            .page_up => self.catalog.pageUp(body_height),
            .page_down => self.catalog.pageDown(body_height),
            .first => self.catalog.first(body_height),
            .last => self.catalog.last(body_height),
            .select_row => |index| {
                self.interaction_state.focus = .history;
                self.catalog.select(index, body_height);
            },
            .load_older => self.requestContinuation(),
            .cancel_load => self.cancelLoad(),
            .toggle_range => if (self.catalog.moreRowSelected()) {
                self.status.set("Press Enter to load older commits", .{});
            } else if (self.catalog.records.items.len > 0) {
                self.draft.toggleAnchor(self.catalog.cursor);
            },
            .cancel_draft => if (!self.returnToAccepted() and !self.draft.clearAnchor())
                self.status.set("No previously selected diff", .{}),
            .unsupported_search => self.status.set("Commit search is not available in v1", .{}),
            .load_diff, .open_picker, .focus_next, .focus_previous, .focus_pane, .move_detail, .move_files, .scroll_files, .adjust_width, .copy_detail, .common => unreachable,
            .owned_noop => {},
        }
        if (previous_cursor != self.catalog.cursor or previous_anchor != self.draft.anchor()) {
            self.interaction_state.selectionChanged();
        }
    }

    pub fn selectionRequest(self: *const HistoryPageState) git_history.SelectionResolution {
        const snapshot = if (self.catalog.snapshot) |*value| value else return .{ .unavailable = .empty_catalog };
        return git_history.resolveSelection(
            snapshot,
            self.catalog.records.items,
            self.draft.anchor(),
            self.catalog.cursor,
        );
    }

    /// Resolve the current picker selection and update the preview queue. The
    /// caller owns task dispatch for a `.start_debounce` outcome.
    pub fn queueCurrentPreview(self: *HistoryPageState, allocator: std.mem.Allocator) ?preview.QueueOutcome {
        if (self.current_view != .picker or self.catalog_hidden or self.load_state != .loaded) return null;
        const page_identity = self.activation.currentIdentity() orelse {
            self.preview_state.clearSelection(allocator);
            return null;
        };
        const root = self.root_identity orelse {
            self.preview_state.clearSelection(allocator);
            return null;
        };
        const request = switch (self.selectionRequest()) {
            .request => |value| value,
            .unavailable => {
                self.preview_state.clearSelection(allocator);
                return null;
            },
        };
        const selected_index = switch (request.intent) {
            .single => |single| single.index,
            .range => |range| range.newest_index,
        };
        if (selected_index >= self.catalog.records.items.len) {
            self.preview_state.clearSelection(allocator);
            return null;
        }
        return self.preview_state.queue(allocator, .{
            .page = page_identity,
            .root = root,
            .catalog_instance = self.preview_state.catalog_instance,
            .selection = preview.summaryForRequest(
                request,
                self.catalog.records.items[selected_index].parent_count,
            ),
        }, request);
    }

    pub fn inputContext(self: *const HistoryPageState, effective: @import("keymap").Effective) input.Context {
        return .{
            .loading = self.current_view == .picker and self.load_state == .loading,
            .diff_view = self.current_view == .diff and self.accepted != null,
            .focus = self.interaction_state.focus,
            .more_row_selected = !self.catalog_hidden and self.catalog.moreRowSelected(),
            .picker_ready = !self.catalog_hidden and self.catalog.records.items.len > 0,
            .picker_can_move_previous = !self.catalog_hidden and self.catalog.canMovePrevious(),
            .picker_can_move_next = !self.catalog_hidden and self.catalog.canMoveNext(),
            .return_to_accepted = self.current_view == .picker and self.accepted != null and
                (self.load_state != .loading or self.catalog_hidden),
            .common = .{
                .search_mode = self.diff.search.mode,
                .file_search_mode = self.diff.file_search.mode,
                .search_query_len = self.diff.search.query.len,
                .focus = self.diff.viewer.focus,
                .sidebar_hidden = self.diff.viewer.sidebar_hidden,
                .side_by_side = self.diff.viewer.display_mode == .side_by_side,
                .selection_owner = diff_surface.input.selectionOwnerKind(self.diff.selection_owner),
                .retained_selection_action_available = self.diff.completed_selection != null,
                .keymap = effective,
            },
            .keymap = effective,
        };
    }

    pub fn currentPresentationIdentity(self: *const HistoryPageState) ?committed_diff.PresentationIdentity {
        return if (self.accepted) |accepted| accepted.presentationIdentity() else null;
    }

    pub fn currentHeadContext(self: *const HistoryPageState) ?*const git_history.Snapshot {
        if (self.observed_context) |*snapshot| return snapshot;
        if (!self.catalog_hidden) if (self.catalog.snapshot) |*snapshot| return snapshot;
        return null;
    }

    pub fn acceptedContextChanged(self: *const HistoryPageState) bool {
        const accepted = self.accepted orelse return false;
        const current = self.currentHeadContext() orelse return false;
        return current.object_format != accepted.request.basis.object_format or
            !optionalOidEql(current.head, accepted.request.snapshot_head) or
            !headDisplayEql(current.display, accepted.origin);
    }

    pub fn openPicker(self: *HistoryPageState, _: std.mem.Allocator) void {
        if (self.accepted == null) return;
        self.diff.selection_owner = .none;
        self.current_view = .picker;
        self.pending = null;
        self.needs_probe = .open_picker;
        self.needs_initial = false;
        self.needs_continuation = false;
        self.catalog_hidden = true;
        self.load_state = .loading;
        self.status.clear();
    }

    pub fn returnToAccepted(self: *HistoryPageState) bool {
        if (self.accepted == null) return false;
        self.current_view = .diff;
        self.status.clear();
        return true;
    }

    fn clearAccepted(self: *HistoryPageState, allocator: std.mem.Allocator) void {
        if (self.accepted) |*accepted| accepted.deinit(allocator);
        self.accepted = null;
        self.current_view = .picker;
        self.diff.deinit(allocator);
    }

    fn applyProbe(
        self: *HistoryPageState,
        allocator: std.mem.Allocator,
        reason: app_load.HistoryProbeReason,
        page: *git_history.Page,
    ) ApplyOutcome {
        if (page.records.len != 0 or page.continuation != null) {
            self.load_state = .failed;
            self.status.set("History HEAD check returned an invalid result", .{});
            return .failed;
        }
        const incoming = if (page.snapshot) |*snapshot| snapshot else {
            self.load_state = .failed;
            self.status.set("History HEAD check returned no context", .{});
            return .failed;
        };
        const current = if (self.catalog.snapshot) |*snapshot| snapshot else null;
        const unchanged = if (current) |snapshot| snapshotEql(snapshot, incoming) else false;

        if (unchanged and reason != .reload) {
            self.clearObservedContext(allocator);
            self.catalog_hidden = false;
            self.load_state = if (self.catalog.records.items.len == 0) .empty else .loaded;
            self.status.clear();
            if (reason == .open_picker and !self.restoreAcceptedDraft()) {
                self.resetDraft("History changed; draft selection reset");
            }
            return .changed;
        }

        const same_branch_context = if (current) |snapshot| sameBranchContext(snapshot.display, incoming.display) else false;
        self.preview_state.invalidate(allocator);
        self.clearObservedContext(allocator);
        self.observed_context = page.takeSnapshot();
        self.needs_initial = true;
        self.initial_policy = switch (reason) {
            .activation => if (same_branch_context and self.current_view == .picker) .preserve_draft else .reset,
            .open_picker => .restore_accepted,
            .reload => .reset,
        };
        self.catalog_hidden = self.current_view == .picker;
        self.load_state = .loading;
        self.status.clear();
        return .changed;
    }

    fn applyInitial(
        self: *HistoryPageState,
        allocator: std.mem.Allocator,
        requested_policy: app_load.HistoryInitialPolicy,
        page: *git_history.Page,
        render_now_unix: ?i64,
    ) !void {
        const incoming = if (page.snapshot) |*snapshot| snapshot else return error.MissingInitialSnapshot;
        const previous = if (self.catalog.snapshot) |*snapshot| snapshot else null;
        const policy: app_load.HistoryInitialPolicy = if (previous) |snapshot|
            if (sameBranchContext(snapshot.display, incoming.display) or snapshotEql(snapshot, incoming)) requested_policy else .reset
        else
            .reset;
        const restore: ?PickerRestore = switch (policy) {
            .reset => null,
            .preserve_draft => switch (self.selectionRequest()) {
                .request => |request| .{ .request = request, .scroll = self.catalog.scroll },
                .unavailable => null,
            },
            .restore_accepted => if (self.accepted) |accepted| .{
                .request = accepted.request,
                .scroll = accepted.picker_scroll,
            } else null,
        };

        try self.catalog.replace(allocator, page);
        self.preview_state.catalogPublished(allocator);
        self.draft = .single;
        const restored = if (restore) |value| self.restorePicker(value) else false;
        if (policy != .reset and !restored) {
            self.resetDraft("History changed; draft selection reset");
        } else {
            self.status.clear();
        }
        self.clearObservedContext(allocator);
        self.catalog_hidden = false;
        self.render_now_unix = render_now_unix;
        self.load_state = if (self.catalog.records.items.len == 0) .empty else .loaded;
    }

    fn restoreAcceptedDraft(self: *HistoryPageState) bool {
        const accepted = self.accepted orelse return false;
        return self.restorePicker(.{ .request = accepted.request, .scroll = accepted.picker_scroll });
    }

    fn restorePicker(self: *HistoryPageState, restore: PickerRestore) bool {
        const positions = mappedSelectionPositions(self.catalog.records.items, restore.request.intent) orelse return false;
        const snapshot = if (self.catalog.snapshot) |*value| value else return false;
        const candidate = switch (git_history.resolveSelection(snapshot, self.catalog.records.items, positions.anchor, positions.cursor)) {
            .request => |request| request,
            .unavailable => return false,
        };
        if (!std.meta.eql(candidate.basis, restore.request.basis)) return false;
        self.catalog.cursor = positions.cursor;
        self.catalog.scroll = shiftedScroll(restore.scroll, intentCursor(restore.request.intent), positions.cursor);
        self.draft = if (positions.anchor) |anchor| .{ .range = anchor } else .single;
        return true;
    }

    fn resetDraft(self: *HistoryPageState, message: []const u8) void {
        self.draft = .single;
        self.catalog.cursor = 0;
        self.catalog.scroll = 0;
        self.status.set("{s}", .{message});
    }

    fn clearObservedContext(self: *HistoryPageState, allocator: std.mem.Allocator) void {
        if (self.observed_context) |*snapshot| snapshot.deinit(allocator);
        self.observed_context = null;
    }
};

const PickerRestore = struct {
    request: git_history.SelectionRequest,
    scroll: usize,
};

const PickerPositions = struct {
    cursor: usize,
    anchor: ?usize,
};

fn snapshotEql(a: *const git_history.Snapshot, b: *const git_history.Snapshot) bool {
    return a.object_format == b.object_format and optionalOidEql(a.head, b.head) and headDisplayEql(a.display, b.display);
}

fn optionalOidEql(a: ?git_history.ObjectId, b: ?git_history.ObjectId) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.eql(&b.?);
}

fn headDisplayEql(a: git_history.HeadDisplay, b: git_history.HeadDisplay) bool {
    return switch (a) {
        .branch => |branch| switch (b) {
            .branch => |other| std.mem.eql(u8, branch, other),
            else => false,
        },
        .detached => b == .detached,
        .unborn => |branch| switch (b) {
            .unborn => |other| std.mem.eql(u8, branch, other),
            else => false,
        },
    };
}

fn sameBranchContext(a: git_history.HeadDisplay, b: git_history.HeadDisplay) bool {
    return switch (a) {
        .branch => |branch| switch (b) {
            .branch => |other| std.mem.eql(u8, branch, other),
            else => false,
        },
        .detached, .unborn => false,
    };
}

fn mappedSelectionPositions(records: []const git_history.Record, intent: git_history.SelectionIntent) ?PickerPositions {
    return switch (intent) {
        .single => |single| .{
            .cursor = findRecord(records, single.oid) orelse return null,
            .anchor = null,
        },
        .range => |range| blk: {
            const anchor_oid = if (range.anchor_index == range.newest_index) range.newest_oid else range.oldest_oid;
            const cursor_oid = if (range.cursor_index == range.newest_index) range.newest_oid else range.oldest_oid;
            break :blk .{
                .cursor = findRecord(records, cursor_oid) orelse return null,
                .anchor = findRecord(records, anchor_oid) orelse return null,
            };
        },
    };
}

fn findRecord(records: []const git_history.Record, oid: git_history.ObjectId) ?usize {
    for (records, 0..) |record, index| if (record.oid.eql(&oid)) return index;
    return null;
}

fn intentCursor(intent: git_history.SelectionIntent) usize {
    return switch (intent) {
        .single => |single| single.index,
        .range => |range| range.cursor_index,
    };
}

fn shiftedScroll(scroll: usize, old_cursor: usize, new_cursor: usize) usize {
    if (new_cursor >= old_cursor) return scroll +| (new_cursor - old_cursor);
    return scroll -| (old_cursor - new_cursor);
}

fn cloneHeadDisplay(allocator: std.mem.Allocator, display: git_history.HeadDisplay) !git_history.HeadDisplay {
    return switch (display) {
        .branch => |branch| .{ .branch = try allocator.dupe(u8, branch) },
        .detached => .detached,
        .unborn => |branch| .{ .unborn = try allocator.dupe(u8, branch) },
    };
}

fn selectionMatchesCatalog(
    snapshot: *const git_history.Snapshot,
    records: []const git_history.Record,
    request: git_history.SelectionRequest,
) bool {
    var anchor: ?usize = null;
    const cursor = switch (request.intent) {
        .single => |single| single.index,
        .range => |range| blk: {
            anchor = range.anchor_index;
            break :blk range.cursor_index;
        },
    };
    return switch (git_history.resolveSelection(snapshot, records, anchor, cursor)) {
        .request => |candidate| std.meta.eql(candidate, request),
        .unavailable => false,
    };
}

test "History row selection focuses the catalog and resets preview scrolling" {
    var records: [3]git_history.Record = undefined;
    var state: HistoryPageState = .{
        .catalog = .{ .records = .{ .items = &records, .capacity = records.len } },
        .interaction_state = .{
            .focus = .changed_files,
            .detail_anchor = .{ .block_index = 1, .source_byte_offset = 3 },
            .files_vertical_offset = 2,
            .files_horizontal_offset = 4,
        },
    };

    state.applyInput(.{ .select_row = 2 }, 24);

    try std.testing.expectEqual(interaction.Focus.history, state.interaction_state.focus);
    try std.testing.expectEqual(@as(usize, 2), state.catalog.cursor);
    try std.testing.expectEqual(interaction.ContentAnchor{}, state.interaction_state.detail_anchor);
    try std.testing.expectEqual(@as(usize, 0), state.interaction_state.files_vertical_offset);
    try std.testing.expectEqual(@as(usize, 0), state.interaction_state.files_horizontal_offset);
    state.catalog.records = .empty;
}

test "History preview lifecycle stays independent of catalog and diff pending" {
    const allocator = std.testing.allocator;
    const page_identity = app_page.RequestIdentity.history(3, 5);
    const root_identity: root_capability.Identity = .{ .device = 7, .inode = 11 };
    const selected = try git_history.ObjectId.parse(.sha1, "2222222222222222222222222222222222222222");
    const request: git_history.SelectionRequest = .{
        .snapshot_head = selected,
        .intent = .{ .single = .{ .index = 0, .oid = selected } },
        .basis = .{ .object_format = .sha1, .before = .empty_tree, .after = selected },
    };
    var state: HistoryPageState = .{};
    defer state.deinit(allocator);
    state.pending = .{ .catalog = .{
        .identity = page_identity,
        .root_identity = root_identity,
        .generation = 13,
        .request = .{ .probe = .reload },
    } };
    const catalog_pending = state.pending.?;
    try std.testing.expectEqual(preview.QueueOutcome.start_debounce, state.preview_state.queue(allocator, .{
        .page = page_identity,
        .root = root_identity,
        .catalog_instance = 17,
        .selection = preview.summaryForRequest(request, 0),
    }, request));
    try std.testing.expect(std.meta.eql(catalog_pending, state.pending.?));

    const stamp = state.preview_state.reserveDebounce().?;
    state.preview_state.armDebounce(stamp);
    state.pending = .{ .diff = .{
        .identity = page_identity,
        .root_identity = root_identity,
        .generation = 19,
        .request = request,
    } };
    const diff_pending = state.pending.?;
    try std.testing.expectEqual(
        preview.DebounceOutcome.settled,
        state.preview_state.finishDebounce(stamp, .{ .failed = .task_start }),
    );
    try std.testing.expect(std.meta.eql(diff_pending, state.pending.?));
}

test "History completion adopts only an admitted initial presentation clock" {
    const allocator = std.testing.allocator;
    const identity = app_page.RequestIdentity.history(9, 4);
    const root_identity: root_capability.Identity = .{ .device = 7, .inode = 11 };
    var state: HistoryPageState = .{
        .repo_epoch = 9,
        .root_identity = root_identity,
        .load_state = .loading,
    };
    defer state.deinit(allocator);
    state.activation.next_activation_id = 3;
    _ = state.activation.activate(9, .unavailable, .unavailable, .unavailable);
    state.armCatalog(.{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 3,
        .request = .{ .initial = .reset },
    });

    const head = try git_history.ObjectId.parse(.sha1, "2222222222222222222222222222222222222222");
    const root = try git_history.ObjectId.parse(.sha1, "1111111111111111111111111111111111111111");
    var initial: app_load.HistoryCatalogFinished = .{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 3,
        .request = .{ .initial = .reset },
        .render_now_unix = 100,
        .result = .{ .loaded = .{
            .snapshot = .{
                .object_format = .sha1,
                .head = head,
                .display = .{ .branch = try allocator.dupe(u8, "main") },
            },
            .records = try allocator.alloc(git_history.Record, 1),
            .continuation = root,
        } },
    };
    initial.result.loaded.records[0] = try pickerTestRecord(allocator, head, 1, .{ .available = root }, "head");
    defer initial.deinit(allocator);
    try std.testing.expectEqual(
        ApplyOutcome.changed,
        try state.applyFinished(allocator, identity, root_identity, &initial),
    );
    try std.testing.expectEqual(@as(?i64, 100), state.render_now_unix);
    try std.testing.expectEqual(@as(u64, 1), state.preview_state.catalog_instance);
    try std.testing.expectEqual(
        preview.QueueOutcome.start_debounce,
        state.queueCurrentPreview(allocator).?,
    );
    const preview_key = state.preview_state.current_key.?;
    state.current_view = .diff;
    try std.testing.expect(state.queueCurrentPreview(allocator) == null);
    try std.testing.expect(state.preview_state.current_key.?.eql(preview_key));
    state.current_view = .picker;

    state.armCatalog(.{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 4,
        .request = .{ .continuation = .{ .format = .sha1, .cursor = root } },
    });
    var continuation: app_load.HistoryCatalogFinished = .{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 4,
        .request = .{ .continuation = .{ .format = .sha1, .cursor = root } },
        .render_now_unix = 200,
        .result = .{ .loaded = .{ .records = try allocator.alloc(git_history.Record, 1) } },
    };
    continuation.result.loaded.records[0] = try pickerTestRecord(allocator, root, 0, .true_root, "root");
    defer continuation.deinit(allocator);
    try std.testing.expectEqual(
        ApplyOutcome.changed,
        try state.applyFinished(allocator, identity, root_identity, &continuation),
    );
    try std.testing.expectEqual(@as(?i64, 100), state.render_now_unix);
    try std.testing.expectEqual(@as(u64, 2), state.preview_state.catalog_instance);
    try std.testing.expect(state.preview_state.current_key == null);

    state.armCatalog(.{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 5,
        .request = .{ .initial = .reset },
    });
    var failed: app_load.HistoryCatalogFinished = .{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 5,
        .request = .{ .initial = .reset },
        .render_now_unix = 300,
        .result = .{ .failure = .git_command_failed },
    };
    try std.testing.expectEqual(ApplyOutcome.failed, try state.applyFinished(allocator, identity, root_identity, &failed));
    try std.testing.expectEqual(@as(?i64, 100), state.render_now_unix);
    try std.testing.expectEqual(@as(u64, 2), state.preview_state.catalog_instance);

    state.armCatalog(.{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 6,
        .request = .{ .initial = .reset },
    });
    var stale: app_load.HistoryCatalogFinished = .{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 7,
        .request = .{ .initial = .reset },
        .render_now_unix = 400,
        .result = .{ .failure = .git_command_failed },
    };
    try std.testing.expectEqual(ApplyOutcome.discarded, try state.applyFinished(allocator, identity, root_identity, &stale));
    try std.testing.expectEqual(@as(?i64, 100), state.render_now_unix);

    state.cancelLoad();
    try std.testing.expectEqual(LoadState.loaded, state.load_state);
    try std.testing.expectEqualStrings("History load canceled", state.status.text());
}

test "History picker preserves its anchor across older-page append and resolves one snapshot" {
    const allocator = std.testing.allocator;
    const head = try git_history.ObjectId.parse(.sha1, "3333333333333333333333333333333333333333");
    const middle = try git_history.ObjectId.parse(.sha1, "2222222222222222222222222222222222222222");
    const root = try git_history.ObjectId.parse(.sha1, "1111111111111111111111111111111111111111");
    var initial: git_history.Page = .{
        .snapshot = .{
            .object_format = .sha1,
            .head = head,
            .display = .{ .branch = try allocator.dupe(u8, "main") },
        },
        .records = try allocator.alloc(git_history.Record, 2),
        .continuation = root,
    };
    initial.records[0] = try pickerTestRecord(allocator, head, 1, .{ .available = middle }, "head");
    initial.records[1] = try pickerTestRecord(allocator, middle, 1, .{ .available = root }, "middle");
    defer initial.deinit(allocator);

    var state: HistoryPageState = .{ .load_state = .loaded };
    defer state.deinit(allocator);
    try state.catalog.replace(allocator, &initial);
    state.applyInput(.toggle_range, 24);
    try std.testing.expectEqual(@as(?usize, 0), state.draft.anchor());
    state.catalog.last(24);
    try std.testing.expect(state.catalog.moreRowSelected());
    state.applyInput(.toggle_range, 24);
    try std.testing.expectEqualStrings("Press Enter to load older commits", state.status.text());
    try std.testing.expectEqual(@as(?usize, 0), state.draft.anchor());

    var older: git_history.Page = .{ .records = try allocator.alloc(git_history.Record, 1) };
    older.records[0] = try pickerTestRecord(allocator, root, 0, .true_root, "root");
    defer older.deinit(allocator);
    try state.catalog.append(allocator, &older);
    try std.testing.expectEqual(@as(usize, 2), state.catalog.cursor);
    try std.testing.expectEqual(selection.Direction.toward_older, state.draft.direction(state.catalog.cursor).?);
    const request = state.selectionRequest().request;
    try std.testing.expectEqual(@as(usize, 3), request.intent.commitCount());
    try std.testing.expect(request.basis.before == .empty_tree);

    state.requestReload(allocator);
    try std.testing.expectEqual(LoadState.loaded, state.load_state);
    try std.testing.expectEqualStrings("Cancel range selection before reloading", state.status.text());
    state.applyInput(.cancel_draft, 24);
    try std.testing.expect(!state.draft.isRange());
    state.applyInput(.cancel_draft, 24);
    try std.testing.expectEqualStrings("No previously selected diff", state.status.text());
    state.applyInput(.unsupported_search, 24);
    try std.testing.expectEqualStrings("Commit search is not available in v1", state.status.text());
}

test "History diff completion publishes atomically and failure or cancel preserves the accepted diff" {
    const allocator = std.testing.allocator;
    const root_identity: root_capability.Identity = .{ .device = 17, .inode = 19 };
    const newest = try git_history.ObjectId.parse(.sha1, "2222222222222222222222222222222222222222");
    const root = try git_history.ObjectId.parse(.sha1, "1111111111111111111111111111111111111111");
    var initial: git_history.Page = .{
        .snapshot = .{
            .object_format = .sha1,
            .head = newest,
            .display = .{ .branch = try allocator.dupe(u8, "main") },
        },
        .records = try allocator.alloc(git_history.Record, 2),
    };
    initial.records[0] = try pickerTestRecord(allocator, newest, 1, .{ .available = root }, "newest");
    initial.records[1] = try pickerTestRecord(allocator, root, 0, .true_root, "root");
    defer initial.deinit(allocator);

    var state: HistoryPageState = .{
        .repo_epoch = 9,
        .root_identity = root_identity,
        .load_state = .loaded,
    };
    defer state.deinit(allocator);
    _ = state.activation.activate(9, .unavailable, .unavailable, .unavailable);
    const identity = state.activation.currentIdentity().?;
    try state.catalog.replace(allocator, &initial);

    const first_request = state.selectionRequest().request;
    state.armDiff(.{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 1,
        .request = first_request,
    });
    const patch =
        "diff --git a/file.txt b/file.txt\n" ++
        "--- a/file.txt\n" ++
        "+++ b/file.txt\n" ++
        "@@ -1 +1 @@\n" ++
        "-old\n" ++
        "+new\n";
    var success: app_load.HistoryDiffFinished = .{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 1,
        .request = first_request,
        .result = .{ .loaded = .{ .loaded = try app_load.buildLoadedBundle(allocator, patch) } },
    };
    defer success.deinit(allocator);
    try std.testing.expectEqual(
        ApplyOutcome.changed,
        try state.applyDiffFinished(allocator, null, identity, root_identity, &success),
    );
    try std.testing.expectEqual(CurrentView.diff, state.current_view);
    try std.testing.expect(state.accepted.?.request.basis.after.eql(&newest));
    try std.testing.expectEqualStrings("main", state.accepted.?.origin.branch);
    try std.testing.expect(state.diff.load.state == .loaded);

    state.openPicker(allocator);
    const picker_probe_request = state.nextRequest().?;
    state.armCatalog(.{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 20,
        .request = picker_probe_request,
    });
    var picker_probe: app_load.HistoryCatalogFinished = .{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 20,
        .request = picker_probe_request,
        .result = .{ .loaded = try pickerProbePage(allocator, newest, "main") },
    };
    defer picker_probe.deinit(allocator);
    try std.testing.expectEqual(
        ApplyOutcome.changed,
        try state.applyFinished(allocator, identity, root_identity, &picker_probe),
    );
    state.catalog.cursor = 1;
    const root_request = state.selectionRequest().request;
    state.armDiff(.{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 2,
        .request = root_request,
    });
    var failed: app_load.HistoryDiffFinished = .{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 2,
        .request = root_request,
        .result = .{ .unavailable = .projection_git_command_failed },
    };
    try std.testing.expectEqual(
        ApplyOutcome.failed,
        try state.applyDiffFinished(allocator, null, identity, root_identity, &failed),
    );
    try std.testing.expectEqual(CurrentView.picker, state.current_view);
    try std.testing.expect(state.accepted.?.request.basis.after.eql(&newest));

    state.armDiff(.{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 3,
        .request = root_request,
    });
    try std.testing.expect(state.inputContext(.{}).loading);
    try std.testing.expect(!state.inputContext(.{}).return_to_accepted);
    state.cancelLoad();
    try std.testing.expectEqual(CurrentView.picker, state.current_view);
    var canceled: app_load.HistoryDiffFinished = .{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 3,
        .request = root_request,
        .result = .empty,
    };
    try std.testing.expectEqual(
        ApplyOutcome.discarded,
        try state.applyDiffFinished(allocator, null, identity, root_identity, &canceled),
    );
    try std.testing.expect(state.returnToAccepted());
    try std.testing.expect(state.accepted.?.request.basis.after.eql(&newest));

    state.armDiff(.{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 4,
        .request = root_request,
    });
    var allocation_failure: app_load.HistoryDiffFinished = .{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 4,
        .request = root_request,
        .result = .{ .loaded = .{ .loaded = try app_load.buildLoadedBundle(allocator, patch) } },
    };
    defer allocation_failure.deinit(allocator);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        state.applyDiffFinished(failing.allocator(), null, identity, root_identity, &allocation_failure),
    );
    try std.testing.expectEqual(CurrentView.diff, state.current_view);
    try std.testing.expect(state.accepted.?.request.basis.after.eql(&newest));
    try std.testing.expectEqualStrings("main", state.accepted.?.origin.branch);
    try std.testing.expect(state.diff.load.state == .loaded);
}

test "History lifecycle reuses one context and preserves a valid draft across HEAD advance" {
    const allocator = std.testing.allocator;
    const root_identity: root_capability.Identity = .{ .device = 23, .inode = 29 };
    const newest = try git_history.ObjectId.parse(.sha1, "dddddddddddddddddddddddddddddddddddddddd");
    const middle = try git_history.ObjectId.parse(.sha1, "cccccccccccccccccccccccccccccccccccccccc");
    const root = try git_history.ObjectId.parse(.sha1, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    const advanced = try git_history.ObjectId.parse(.sha1, "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee");
    const replacement = try git_history.ObjectId.parse(.sha1, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");

    var state: HistoryPageState = .{
        .repo_epoch = 4,
        .root_identity = root_identity,
        .load_state = .loaded,
    };
    defer state.deinit(allocator);
    var original = try pickerPage(allocator, "main", &.{ newest, middle, root });
    defer original.deinit(allocator);
    try state.catalog.replace(allocator, &original);
    state.catalog.cursor = 1;
    state.catalog.scroll = 0;
    state.draft = .{ .range = 0 };
    const retained_subject = state.catalog.records.items[0].subject.ptr;
    _ = state.activation.activate(4, .unavailable, .unavailable, .unavailable);
    try std.testing.expectEqual(preview.QueueOutcome.start_debounce, state.queueCurrentPreview(allocator).?);
    state.deactivate();
    try std.testing.expect(state.preview_state.current_key == null);

    state.activate(allocator, 4, root_identity);
    const same_request = state.nextRequest().?;
    try std.testing.expectEqual(app_load.HistoryProbeReason.activation, same_request.probe);
    const same_identity = state.activation.currentIdentity().?;
    state.armCatalog(.{
        .identity = same_identity,
        .root_identity = root_identity,
        .generation = 1,
        .request = same_request,
    });
    var same = app_load.HistoryCatalogFinished{
        .identity = same_identity,
        .root_identity = root_identity,
        .generation = 1,
        .request = same_request,
        .result = .{ .loaded = try pickerProbePage(allocator, newest, "main") },
    };
    defer same.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, try state.applyFinished(allocator, same_identity, root_identity, &same));
    try std.testing.expect(!state.catalog_hidden);
    try std.testing.expectEqual(@as(usize, 1), state.catalog.cursor);
    try std.testing.expectEqual(@as(?usize, 0), state.draft.anchor());
    try std.testing.expectEqual(retained_subject, state.catalog.records.items[0].subject.ptr);

    state.deactivate();
    state.activate(allocator, 4, root_identity);
    const advance_probe_request = state.nextRequest().?;
    const advance_identity = state.activation.currentIdentity().?;
    state.armCatalog(.{
        .identity = advance_identity,
        .root_identity = root_identity,
        .generation = 2,
        .request = advance_probe_request,
    });
    var advance_probe = app_load.HistoryCatalogFinished{
        .identity = advance_identity,
        .root_identity = root_identity,
        .generation = 2,
        .request = advance_probe_request,
        .result = .{ .loaded = try pickerProbePage(allocator, advanced, "main") },
    };
    defer advance_probe.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, try state.applyFinished(allocator, advance_identity, root_identity, &advance_probe));
    const advance_initial_request = state.nextRequest().?;
    try std.testing.expectEqual(app_load.HistoryInitialPolicy.preserve_draft, advance_initial_request.initial);
    state.armCatalog(.{
        .identity = advance_identity,
        .root_identity = root_identity,
        .generation = 3,
        .request = advance_initial_request,
    });
    var advance_initial = app_load.HistoryCatalogFinished{
        .identity = advance_identity,
        .root_identity = root_identity,
        .generation = 3,
        .request = advance_initial_request,
        .render_now_unix = 200,
        .result = .{ .loaded = try pickerPage(allocator, "main", &.{ advanced, newest, middle, root }) },
    };
    defer advance_initial.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, try state.applyFinished(allocator, advance_identity, root_identity, &advance_initial));
    try std.testing.expectEqual(@as(usize, 2), state.catalog.cursor);
    try std.testing.expectEqual(@as(?usize, 1), state.draft.anchor());
    try std.testing.expectEqual(selection.Direction.toward_older, state.draft.direction(state.catalog.cursor).?);
    try std.testing.expectEqual(@as(usize, 1), state.catalog.scroll);
    try std.testing.expectEqual(@as(?i64, 200), state.render_now_unix);

    state.deactivate();
    state.activate(allocator, 4, root_identity);
    const reset_probe_request = state.nextRequest().?;
    const reset_identity = state.activation.currentIdentity().?;
    state.armCatalog(.{
        .identity = reset_identity,
        .root_identity = root_identity,
        .generation = 4,
        .request = reset_probe_request,
    });
    var reset_probe = app_load.HistoryCatalogFinished{
        .identity = reset_identity,
        .root_identity = root_identity,
        .generation = 4,
        .request = reset_probe_request,
        .result = .{ .loaded = try pickerProbePage(allocator, replacement, "main") },
    };
    defer reset_probe.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, try state.applyFinished(allocator, reset_identity, root_identity, &reset_probe));
    const reset_initial_request = state.nextRequest().?;
    state.armCatalog(.{
        .identity = reset_identity,
        .root_identity = root_identity,
        .generation = 5,
        .request = reset_initial_request,
    });
    var reset_initial = app_load.HistoryCatalogFinished{
        .identity = reset_identity,
        .root_identity = root_identity,
        .generation = 5,
        .request = reset_initial_request,
        .render_now_unix = 300,
        .result = .{ .loaded = try pickerPage(allocator, "main", &.{replacement}) },
    };
    defer reset_initial.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, try state.applyFinished(allocator, reset_identity, root_identity, &reset_initial));
    try std.testing.expectEqual(@as(usize, 0), state.catalog.cursor);
    try std.testing.expect(state.draft.anchor() == null);
    try std.testing.expectEqualStrings("History changed; draft selection reset", state.status.text());

    try std.testing.expectEqual(preview.QueueOutcome.start_debounce, state.queueCurrentPreview(allocator).?);
    state.requestReload(allocator);
    try std.testing.expect(state.preview_state.current_key == null);
    const reload_probe_request = state.nextRequest().?;
    try std.testing.expectEqual(app_load.HistoryProbeReason.reload, reload_probe_request.probe);
    state.armCatalog(.{
        .identity = reset_identity,
        .root_identity = root_identity,
        .generation = 6,
        .request = reload_probe_request,
    });
    var reload_probe = app_load.HistoryCatalogFinished{
        .identity = reset_identity,
        .root_identity = root_identity,
        .generation = 6,
        .request = reload_probe_request,
        .result = .{ .loaded = try pickerProbePage(allocator, replacement, "main") },
    };
    defer reload_probe.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, try state.applyFinished(allocator, reset_identity, root_identity, &reload_probe));
    try std.testing.expectEqual(app_load.HistoryInitialPolicy.reset, state.nextRequest().?.initial);
    const reload_initial_request = state.nextRequest().?;
    state.armCatalog(.{
        .identity = reset_identity,
        .root_identity = root_identity,
        .generation = 7,
        .request = reload_initial_request,
    });
    var reload_initial = app_load.HistoryCatalogFinished{
        .identity = reset_identity,
        .root_identity = root_identity,
        .generation = 7,
        .request = reload_initial_request,
        .result = .{ .loaded = try pickerPage(allocator, "main", &.{replacement}) },
    };
    defer reload_initial.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, try state.applyFinished(allocator, reset_identity, root_identity, &reload_initial));

    state.deactivate();
    state.activate(allocator, 4, root_identity);
    const changed_probe_request = state.nextRequest().?;
    const changed_identity = state.activation.currentIdentity().?;
    state.armCatalog(.{
        .identity = changed_identity,
        .root_identity = root_identity,
        .generation = 8,
        .request = changed_probe_request,
    });
    var changed_probe = app_load.HistoryCatalogFinished{
        .identity = changed_identity,
        .root_identity = root_identity,
        .generation = 8,
        .request = changed_probe_request,
        .result = .{ .loaded = try pickerProbePage(allocator, advanced, "feature") },
    };
    defer changed_probe.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, try state.applyFinished(allocator, changed_identity, root_identity, &changed_probe));
    const changed_initial_request = state.nextRequest().?;
    state.armCatalog(.{
        .identity = changed_identity,
        .root_identity = root_identity,
        .generation = 9,
        .request = changed_initial_request,
    });
    state.cancelLoad();
    try std.testing.expect(state.catalog_hidden);
    try std.testing.expectEqual(LoadState.failed, state.load_state);
    try std.testing.expect(!state.inputContext(.{}).picker_ready);
    try std.testing.expect(input.keyToMsg(state.inputContext(.{}), .{ .codepoint = 'j' }) == null);
    try std.testing.expect(input.keyToMsg(state.inputContext(.{}), .{ .codepoint = 0x0d }) == null);
    const canceled_context = state.currentHeadContext().?;
    try std.testing.expect(canceled_context.head.?.eql(&advanced));
    try std.testing.expect(std.meta.activeTag(canceled_context.display) == .branch);
    try std.testing.expectEqualStrings("feature", canceled_context.display.branch);
    state.requestReload(allocator);
    try std.testing.expectEqual(app_load.HistoryProbeReason.reload, state.nextRequest().?.probe);
    try std.testing.expect(state.currentHeadContext().?.head.?.eql(&advanced));
}

test "History picker revalidates accepted context and repository replacement fences old completion" {
    const allocator = std.testing.allocator;
    const root_identity: root_capability.Identity = .{ .device = 31, .inode = 37 };
    const replacement_identity: root_capability.Identity = .{ .device = 41, .inode = 43 };
    const newest = try git_history.ObjectId.parse(.sha1, "3333333333333333333333333333333333333333");
    const root = try git_history.ObjectId.parse(.sha1, "2222222222222222222222222222222222222222");
    const feature = try git_history.ObjectId.parse(.sha1, "4444444444444444444444444444444444444444");

    var state: HistoryPageState = .{
        .repo_epoch = 7,
        .root_identity = root_identity,
        .load_state = .loaded,
    };
    defer state.deinit(allocator);
    var original = try pickerPage(allocator, "main", &.{ newest, root });
    defer original.deinit(allocator);
    try state.catalog.replace(allocator, &original);
    state.catalog.cursor = 1;
    state.catalog.scroll = 1;
    state.draft = .{ .range = 0 };
    _ = state.activation.activate(7, .immutable, .unavailable, .unavailable);
    const accepted_request = state.selectionRequest().request;
    try std.testing.expect(std.meta.activeTag(accepted_request.intent) == .range);
    state.accepted = try AcceptedSelection.init(
        allocator,
        accepted_request,
        &state.catalog.snapshot.?,
        state.catalog.records.items,
        state.catalog.scroll,
    );
    state.current_view = .diff;
    state.diff.viewer = .{
        .selected_node = 3,
        .focus = .diff,
        .diff_scroll = 7,
        .display_mode = .unified,
    };
    const accepted_origin = state.accepted.?.origin.branch.ptr;
    const accepted_basis = state.accepted.?.request.basis;

    state.deactivate();
    state.activate(allocator, 7, root_identity);
    try std.testing.expectEqual(app_load.HistoryProbeReason.activation, state.nextRequest().?.probe);
    try std.testing.expectEqual(CurrentView.diff, state.current_view);
    try std.testing.expectEqual(accepted_origin, state.accepted.?.origin.branch.ptr);
    try std.testing.expectEqual(@as(usize, 3), state.diff.viewer.selected_node);
    try std.testing.expectEqual(@as(usize, 7), state.diff.viewer.diff_scroll);
    try std.testing.expect(state.diff.viewer.display_mode == .unified);
    state.cancelLoad();

    state.openPicker(allocator);
    const same_request = state.nextRequest().?;
    const identity = state.activation.currentIdentity().?;
    state.armCatalog(.{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 1,
        .request = same_request,
    });
    var same = app_load.HistoryCatalogFinished{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 1,
        .request = same_request,
        .result = .{ .loaded = try pickerProbePage(allocator, newest, "main") },
    };
    defer same.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, try state.applyFinished(allocator, identity, root_identity, &same));
    try std.testing.expectEqual(@as(usize, 1), state.catalog.cursor);
    try std.testing.expectEqual(@as(usize, 1), state.catalog.scroll);
    try std.testing.expect(state.draft.isRange());

    try std.testing.expect(state.returnToAccepted());
    state.openPicker(allocator);
    const range_failure_probe_request = state.nextRequest().?;
    state.armCatalog(.{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 2,
        .request = range_failure_probe_request,
    });
    var range_failure_probe = app_load.HistoryCatalogFinished{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 2,
        .request = range_failure_probe_request,
        .result = .{ .loaded = try pickerProbePage(allocator, feature, "broken") },
    };
    defer range_failure_probe.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, try state.applyFinished(allocator, identity, root_identity, &range_failure_probe));
    const range_failure_request = state.nextRequest().?;
    state.armCatalog(.{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 3,
        .request = range_failure_request,
    });
    var range_failure = app_load.HistoryCatalogFinished{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 3,
        .request = range_failure_request,
        .result = .{ .failure = .git_command_failed },
    };
    defer range_failure.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.failed, try state.applyFinished(allocator, identity, root_identity, &range_failure));
    try std.testing.expect(state.catalog_hidden);
    try std.testing.expect(state.draft.isRange());
    state.requestReload(allocator);
    const range_retry_request = state.nextRequest().?;
    try std.testing.expectEqual(app_load.HistoryProbeReason.reload, range_retry_request.probe);
    const retry_context = state.currentHeadContext().?;
    try std.testing.expect(retry_context.head.?.eql(&feature));
    try std.testing.expect(std.meta.activeTag(retry_context.display) == .branch);
    try std.testing.expectEqualStrings("broken", retry_context.display.branch);
    state.armCatalog(.{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 4,
        .request = range_retry_request,
    });
    try std.testing.expect(state.inputContext(.{}).loading);
    try std.testing.expect(state.inputContext(.{}).return_to_accepted);
    try std.testing.expectEqual(
        Msg.cancel_load,
        input.keyToMsg(state.inputContext(.{}), .{ .codepoint = 0x1b }).?,
    );
    state.applyInput(.cancel_load, 24);
    try std.testing.expectEqual(CurrentView.diff, state.current_view);
    try std.testing.expect(state.catalog_hidden);
    try std.testing.expect(state.acceptedContextChanged());
    try std.testing.expect(state.currentHeadContext().?.head.?.eql(&feature));
    try std.testing.expect(std.meta.eql(accepted_basis, state.accepted.?.request.basis));

    state.openPicker(allocator);
    const branch_probe_request = state.nextRequest().?;
    state.armCatalog(.{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 5,
        .request = branch_probe_request,
    });
    var branch_probe = app_load.HistoryCatalogFinished{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 5,
        .request = branch_probe_request,
        .result = .{ .loaded = try pickerProbePage(allocator, feature, "feature") },
    };
    defer branch_probe.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, try state.applyFinished(allocator, identity, root_identity, &branch_probe));
    const branch_initial_request = state.nextRequest().?;
    try std.testing.expectEqual(app_load.HistoryInitialPolicy.restore_accepted, branch_initial_request.initial);
    state.armCatalog(.{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 6,
        .request = branch_initial_request,
    });
    var branch_initial = app_load.HistoryCatalogFinished{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 6,
        .request = branch_initial_request,
        .result = .{ .loaded = try pickerPage(allocator, "feature", &.{feature}) },
    };
    defer branch_initial.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, try state.applyFinished(allocator, identity, root_identity, &branch_initial));
    try std.testing.expect(state.accepted != null);
    try std.testing.expect(state.acceptedContextChanged());
    try std.testing.expectEqual(@as(usize, 0), state.catalog.cursor);
    try std.testing.expect(state.draft.anchor() == null);

    try std.testing.expectEqual(
        Msg.cancel_draft,
        input.keyToMsg(state.inputContext(.{}), .{ .codepoint = 0x1b }).?,
    );
    state.applyInput(.cancel_draft, 24);
    try std.testing.expectEqual(CurrentView.diff, state.current_view);
    try std.testing.expect(std.meta.eql(accepted_basis, state.accepted.?.request.basis));

    state.openPicker(allocator);
    const unborn_probe_request = state.nextRequest().?;
    state.armCatalog(.{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 7,
        .request = unborn_probe_request,
    });
    var unborn_probe = app_load.HistoryCatalogFinished{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 7,
        .request = unborn_probe_request,
        .result = .{ .loaded = try pickerUnbornPage(allocator, "future") },
    };
    defer unborn_probe.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, try state.applyFinished(allocator, identity, root_identity, &unborn_probe));
    const unborn_initial_request = state.nextRequest().?;
    state.armCatalog(.{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 8,
        .request = unborn_initial_request,
    });
    var unborn_initial = app_load.HistoryCatalogFinished{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 8,
        .request = unborn_initial_request,
        .result = .{ .loaded = try pickerUnbornPage(allocator, "future") },
    };
    defer unborn_initial.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, try state.applyFinished(allocator, identity, root_identity, &unborn_initial));
    try std.testing.expectEqual(LoadState.empty, state.load_state);
    try std.testing.expectEqual(@as(usize, 0), state.catalog.records.items.len);
    try std.testing.expect(std.meta.eql(accepted_basis, state.accepted.?.request.basis));
    try std.testing.expectEqual(
        Msg.cancel_draft,
        input.keyToMsg(state.inputContext(.{}), .{ .codepoint = 0x1b }).?,
    );
    state.applyInput(.cancel_draft, 24);
    try std.testing.expectEqual(CurrentView.diff, state.current_view);

    state.openPicker(allocator);
    const detached_probe_request = state.nextRequest().?;
    state.armCatalog(.{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 9,
        .request = detached_probe_request,
    });
    var detached_probe = app_load.HistoryCatalogFinished{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 9,
        .request = detached_probe_request,
        .result = .{ .loaded = .{ .snapshot = .{
            .object_format = .sha1,
            .head = feature,
            .display = .detached,
        } } },
    };
    defer detached_probe.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, try state.applyFinished(allocator, identity, root_identity, &detached_probe));
    try std.testing.expectEqual(app_load.HistoryInitialPolicy.restore_accepted, state.nextRequest().?.initial);
    state.cancelLoad();
    try std.testing.expectEqual(CurrentView.diff, state.current_view);
    try std.testing.expect(state.acceptedContextChanged());

    state.openPicker(allocator);
    const cancel_request = state.nextRequest().?;
    state.armCatalog(.{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 10,
        .request = cancel_request,
    });
    state.cancelLoad();
    try std.testing.expectEqual(CurrentView.diff, state.current_view);
    var canceled = app_load.HistoryCatalogFinished{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 10,
        .request = cancel_request,
        .result = .{ .loaded = try pickerProbePage(allocator, feature, "feature") },
    };
    defer canceled.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.discarded, try state.applyFinished(allocator, identity, root_identity, &canceled));

    state.openPicker(allocator);
    const failed_probe_request = state.nextRequest().?;
    state.armCatalog(.{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 11,
        .request = failed_probe_request,
    });
    var failed_probe = app_load.HistoryCatalogFinished{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 11,
        .request = failed_probe_request,
        .result = .{ .loaded = try pickerProbePage(allocator, feature, "broken") },
    };
    defer failed_probe.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, try state.applyFinished(allocator, identity, root_identity, &failed_probe));
    const failed_request = state.nextRequest().?;
    state.armCatalog(.{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 12,
        .request = failed_request,
    });
    var failed = app_load.HistoryCatalogFinished{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 12,
        .request = failed_request,
        .result = .{ .failure = .git_command_failed },
    };
    defer failed.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.failed, try state.applyFinished(allocator, identity, root_identity, &failed));
    try std.testing.expect(state.accepted != null);
    try std.testing.expect(!state.inputContext(.{}).loading);
    try std.testing.expect(state.inputContext(.{}).return_to_accepted);
    try std.testing.expect(std.meta.eql(accepted_basis, state.accepted.?.request.basis));
    try std.testing.expectEqual(
        Msg.cancel_draft,
        input.keyToMsg(state.inputContext(.{}), .{ .codepoint = 0x1b }).?,
    );
    state.applyInput(.cancel_draft, 24);
    try std.testing.expectEqual(CurrentView.diff, state.current_view);

    state.openPicker(allocator);
    const stale_request = state.nextRequest().?;
    state.armCatalog(.{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 13,
        .request = stale_request,
    });
    state.repositoryChanged(allocator, 8, replacement_identity);
    try std.testing.expect(state.accepted == null);
    try std.testing.expect(state.catalog.snapshot == null);
    var stale = app_load.HistoryCatalogFinished{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 13,
        .request = stale_request,
        .result = .{ .loaded = try pickerProbePage(allocator, feature, "feature") },
    };
    defer stale.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.discarded, try state.applyFinished(allocator, identity, replacement_identity, &stale));
}

fn pickerProbePage(
    allocator: std.mem.Allocator,
    head: git_history.ObjectId,
    branch: []const u8,
) !git_history.Page {
    return .{ .snapshot = .{
        .object_format = .sha1,
        .head = head,
        .display = .{ .branch = try allocator.dupe(u8, branch) },
    } };
}

fn pickerUnbornPage(allocator: std.mem.Allocator, branch: []const u8) !git_history.Page {
    return .{ .snapshot = .{
        .object_format = .sha1,
        .head = null,
        .display = .{ .unborn = try allocator.dupe(u8, branch) },
    } };
}

fn pickerPage(
    allocator: std.mem.Allocator,
    branch: []const u8,
    oids: []const git_history.ObjectId,
) !git_history.Page {
    std.debug.assert(oids.len > 0);
    const records = try allocator.alloc(git_history.Record, oids.len);
    var initialized: usize = 0;
    errdefer {
        for (records[0..initialized]) |*record| record.deinit(allocator);
        allocator.free(records);
    }
    for (oids, 0..) |oid, index| {
        var subject_buffer: [32]u8 = undefined;
        const subject = try std.fmt.bufPrint(&subject_buffer, "commit {d}", .{index});
        records[index] = try pickerTestRecord(
            allocator,
            oid,
            if (index + 1 < oids.len) 1 else 0,
            if (index + 1 < oids.len) .{ .available = oids[index + 1] } else .true_root,
            subject,
        );
        initialized += 1;
    }
    const owned_branch = try allocator.dupe(u8, branch);
    return .{
        .snapshot = .{
            .object_format = .sha1,
            .head = oids[0],
            .display = .{ .branch = owned_branch },
        },
        .records = records,
    };
}

fn pickerTestRecord(
    allocator: std.mem.Allocator,
    oid: git_history.ObjectId,
    parent_count: u16,
    first_parent: git_history.FirstParent,
    subject: []const u8,
) !git_history.Record {
    const author = try allocator.dupe(u8, "Test");
    errdefer allocator.free(author);
    const decorations = try allocator.dupe(u8, "");
    errdefer allocator.free(decorations);
    const owned_subject = try allocator.dupe(u8, subject);
    return .{
        .oid = oid,
        .parent_count = parent_count,
        .first_parent = first_parent,
        .author = author,
        .committer_unix = 0,
        .decorations = decorations,
        .subject = owned_subject,
    };
}

test "History branch switch resets picker only on success and preserves accepted range meaning" {
    const allocator = std.testing.allocator;
    const root_identity: root_capability.Identity = .{ .device = 31, .inode = 37 };
    const old = try git_history.ObjectId.parse(.sha1, "2222222222222222222222222222222222222222");
    const parent = try git_history.ObjectId.parse(.sha1, "1111111111111111111111111111111111111111");
    const advanced = try git_history.ObjectId.parse(.sha1, "3333333333333333333333333333333333333333");
    const cases = [_]struct { success: bool, branch: []const u8, policy: app_load.HistoryInitialPolicy }{
        .{ .success = true, .branch = "feature", .policy = .reset },
        .{ .success = false, .branch = "main", .policy = .preserve_draft },
        .{ .success = false, .branch = "feature", .policy = .reset },
    };
    for (cases) |case| {
        var state: HistoryPageState = .{ .repo_epoch = 4, .root_identity = root_identity, .load_state = .loaded };
        defer state.deinit(allocator);
        _ = state.activation.activate(4, .immutable, .unavailable, .unavailable);
        const identity = state.activation.currentIdentity().?;
        var original = try pickerPage(allocator, "main", &.{ old, parent });
        defer original.deinit(allocator);
        try state.catalog.replace(allocator, &original);
        state.draft = .{ .range = 0 };
        state.catalog.cursor = 1;
        const accepted_request = state.selectionRequest().request;
        state.accepted = try AcceptedSelection.init(allocator, accepted_request, &state.catalog.snapshot.?, state.catalog.records.items, 0);
        _ = state.queueCurrentPreview(allocator);
        state.armCatalog(.{ .identity = identity, .root_identity = root_identity, .generation = 1, .request = .{ .initial = .reset } });
        state.branchSwitchFinished(allocator, case.success);
        try std.testing.expect(state.pending == null);
        try std.testing.expect(state.preview_state.current_key == null);
        try std.testing.expectEqual(!case.success, state.draft.isRange());
        const request = state.nextRequest().?;
        try std.testing.expectEqual(if (case.success) app_load.HistoryProbeReason.reload else .activation, request.probe);
        state.armCatalog(.{ .identity = identity, .root_identity = root_identity, .generation = 2, .request = request });
        var probe: app_load.HistoryCatalogFinished = .{
            .identity = identity,
            .root_identity = root_identity,
            .generation = 2,
            .request = request,
            .result = .{ .loaded = try pickerProbePage(allocator, advanced, case.branch) },
        };
        defer probe.deinit(allocator);
        _ = try state.applyFinished(allocator, identity, root_identity, &probe);
        try std.testing.expectEqual(case.policy, state.nextRequest().?.initial);
        // The accepted range is an immutable selection, separate from the new picker draft.
        state.current_view = .diff;
        state.diff.viewer.diff_scroll = 7;
        state.branchSwitchFinished(allocator, case.success);
        try std.testing.expectEqual(CurrentView.diff, state.current_view);
        try std.testing.expectEqualDeep(accepted_request, state.accepted.?.request);
        try std.testing.expectEqual(@as(usize, 2), state.accepted.?.request.intent.commitCount());
        try std.testing.expectEqual(@as(usize, 7), state.diff.viewer.diff_scroll);
    }
}
