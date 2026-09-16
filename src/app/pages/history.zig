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
    target_subject: []u8,

    pub fn init(
        allocator: std.mem.Allocator,
        request: git_history.SelectionRequest,
        snapshot: *const git_history.Snapshot,
        records: []const git_history.Record,
    ) !AcceptedSelection {
        const selected_index = switch (request.intent) {
            .single => |single| single.index,
            .range => |range| range.newest_index,
        };
        if (selected_index >= records.len or !records[selected_index].oid.eql(&request.basis.after))
            return error.InvalidSelection;
        var origin = try cloneHeadDisplay(allocator, snapshot.display);
        errdefer origin.deinit(allocator);
        const target_subject = try allocator.dupe(u8, records[selected_index].subject);
        return .{
            .request = request,
            .origin = origin,
            .selected_parent_count = records[selected_index].parent_count,
            .target_subject = target_subject,
        };
    }

    pub fn deinit(self: *AcceptedSelection, allocator: std.mem.Allocator) void {
        self.origin.deinit(allocator);
        allocator.free(self.target_subject);
        self.* = undefined;
    }

    pub fn presentationIdentity(self: AcceptedSelection) committed_diff.PresentationIdentity {
        return .{ .diff_basis = self.request.basis };
    }
};

pub const ApplyOutcome = enum { discarded, changed, failed };

pub const HistoryPageState = struct {
    activation: diff_surface.authority.Lifecycle = .init(.history),
    repo_epoch: u64 = 0,
    root_identity: ?root_capability.Identity = null,
    generation: u64 = 0,
    pending: ?Pending = null,
    needs_initial: bool = false,
    needs_continuation: bool = false,
    load_state: LoadState = .idle,
    catalog: catalog.State = .{},
    draft: selection.Draft = .single,
    render_now_unix: ?i64 = null,
    current_view: CurrentView = .picker,
    accepted: ?AcceptedSelection = null,
    diff: committed_diff.State = .{},
    status: app_state.StatusMessage = .{},

    pub fn deinit(self: *HistoryPageState, allocator: std.mem.Allocator) void {
        self.catalog.deinit(allocator);
        if (self.accepted) |*accepted| accepted.deinit(allocator);
        self.diff.deinit(allocator);
        self.* = .{};
    }

    pub fn activate(self: *HistoryPageState, allocator: std.mem.Allocator, repo_epoch: u64, identity: ?root_capability.Identity) void {
        self.pending = null;
        self.needs_continuation = false;
        const root = identity orelse {
            self.catalog.clear(allocator);
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
        self.needs_initial = true;
        self.load_state = .loading;
        self.status.clear();
    }

    pub fn deactivate(self: *HistoryPageState) void {
        self.diff.selection_owner = .none;
        self.activation.deactivate();
        self.pending = null;
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
        self.catalog.clear(allocator);
        self.draft = .single;
        self.render_now_unix = null;
        self.clearAccepted(allocator);
        self.activation.deactivate();
        self.pending = null;
        self.repo_epoch = repo_epoch;
        self.root_identity = identity;
        self.needs_continuation = false;
        self.needs_initial = false;
        self.load_state = if (identity == null) .no_repository else .idle;
    }

    pub fn requestReload(self: *HistoryPageState) void {
        if (self.draft.isRange()) {
            self.status.set("Cancel range selection before reloading", .{});
            return;
        }
        self.pending = null;
        self.needs_continuation = false;
        if (self.activation.currentIdentity() == null or self.root_identity == null) {
            self.needs_initial = false;
            self.load_state = .no_repository;
            return;
        }
        self.needs_initial = true;
        self.load_state = .loading;
        self.draft = .single;
    }

    pub fn requestContinuation(self: *HistoryPageState) void {
        if (self.activation.currentIdentity() == null or self.pending != null or !self.catalog.moreRowSelected()) return;
        self.needs_continuation = true;
        self.load_state = .loading;
    }

    pub fn cancelLoad(self: *HistoryPageState) void {
        if (self.pending == null and !self.needs_initial and !self.needs_continuation) return;
        const was_diff = if (self.pending) |pending| std.meta.activeTag(pending) == .diff else false;
        self.pending = null;
        self.needs_initial = false;
        self.needs_continuation = false;
        self.load_state = if (self.catalog.snapshot == null)
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
    }

    pub fn nextRequest(self: *HistoryPageState) ?app_load.HistoryCatalogRequest {
        if (self.activation.currentIdentity() == null or self.pending != null or self.root_identity == null) return null;
        if (self.needs_initial) return .initial;
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
        self.pending = null;
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
                self.load_state = .failed;
                self.status.set("History load failed: {s}", .{@tagName(failure)});
                return .failed;
            },
            .loaded => |*page| {
                switch (pending.request) {
                    .initial => {
                        try self.catalog.replace(allocator, page);
                        self.draft = .single;
                        self.render_now_unix = finished.render_now_unix;
                    },
                    .continuation => try self.catalog.append(allocator, page),
                }
                self.load_state = if (self.catalog.records.items.len == 0) .empty else .loaded;
                self.status.clear();
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
        switch (msg) {
            .move_previous => self.catalog.movePrevious(body_height),
            .move_next => self.catalog.moveNext(body_height),
            .page_up => self.catalog.pageUp(body_height),
            .page_down => self.catalog.pageDown(body_height),
            .first => self.catalog.first(body_height),
            .last => self.catalog.last(body_height),
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
            .load_diff, .open_picker, .common => unreachable,
            .owned_noop => {},
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

    pub fn inputContext(self: *const HistoryPageState, effective: @import("keymap").Effective) input.Context {
        return .{
            .loading = self.load_state == .loading,
            .diff_view = self.current_view == .diff and self.accepted != null,
            .more_row_selected = self.catalog.moreRowSelected(),
            .picker_ready = self.catalog.records.items.len > 0,
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

    pub fn openPicker(self: *HistoryPageState) void {
        if (self.accepted == null) return;
        self.diff.selection_owner = .none;
        self.current_view = .picker;
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
};

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
        .request = .initial,
    });

    const head = try git_history.ObjectId.parse(.sha1, "2222222222222222222222222222222222222222");
    const root = try git_history.ObjectId.parse(.sha1, "1111111111111111111111111111111111111111");
    var initial: app_load.HistoryCatalogFinished = .{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 3,
        .request = .initial,
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

    state.armCatalog(.{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 5,
        .request = .initial,
    });
    var failed: app_load.HistoryCatalogFinished = .{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 5,
        .request = .initial,
        .render_now_unix = 300,
        .result = .{ .failure = .git_command_failed },
    };
    try std.testing.expectEqual(ApplyOutcome.failed, try state.applyFinished(allocator, identity, root_identity, &failed));
    try std.testing.expectEqual(@as(?i64, 100), state.render_now_unix);

    state.armCatalog(.{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 6,
        .request = .initial,
    });
    var stale: app_load.HistoryCatalogFinished = .{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 7,
        .request = .initial,
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

    state.requestReload();
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
    try std.testing.expectEqualStrings("newest", state.accepted.?.target_subject);
    try std.testing.expect(state.diff.load.state == .loaded);

    state.openPicker();
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
    state.cancelLoad();
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

    if (state.catalog.snapshot) |*snapshot| {
        snapshot.display.deinit(allocator);
        snapshot.display = .detached;
    }
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
    try std.testing.expectEqualStrings("newest", state.accepted.?.target_subject);
    try std.testing.expect(state.diff.load.state == .loaded);
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
