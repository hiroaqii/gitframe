//! History page state and catalog task admission.

const std = @import("std");
const app_load = @import("../load.zig");
const app_page = @import("../page.zig");
const app_state = @import("../state.zig");
const root_capability = @import("../../repo/root_capability.zig");
const catalog = @import("history/catalog.zig");
const input = @import("history/input.zig");
const selection = @import("history/selection.zig");
const git_history = @import("../../git/history.zig");

pub const Msg = input.Msg;

pub const LoadState = enum {
    idle,
    no_repository,
    loading,
    loaded,
    empty,
    failed,
};

pub const Pending = struct {
    identity: app_page.RequestIdentity,
    root_identity: root_capability.Identity,
    generation: u64,
    request: app_load.HistoryCatalogRequest,

    pub fn matches(self: Pending, finished: *const app_load.HistoryCatalogFinished) bool {
        return std.meta.eql(self.identity, finished.identity) and
            self.root_identity.eql(finished.root_identity) and
            self.generation == finished.generation and
            std.meta.eql(self.request, finished.request);
    }
};

pub const ApplyOutcome = enum { discarded, changed, failed };

pub const HistoryPageState = struct {
    active: bool = false,
    activation_id: u64 = 0,
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
    status: app_state.StatusMessage = .{},

    pub fn deinit(self: *HistoryPageState, allocator: std.mem.Allocator) void {
        self.catalog.deinit(allocator);
        self.* = .{};
    }

    pub fn activate(self: *HistoryPageState, allocator: std.mem.Allocator, repo_epoch: u64, identity: ?root_capability.Identity) void {
        self.active = true;
        self.activation_id +%= 1;
        if (self.activation_id == 0) self.activation_id = 1;
        self.pending = null;
        self.needs_continuation = false;
        const root = identity orelse {
            self.catalog.clear(allocator);
            self.draft = .single;
            self.render_now_unix = null;
            self.repo_epoch = repo_epoch;
            self.root_identity = null;
            self.needs_initial = false;
            self.load_state = .no_repository;
            return;
        };
        const same_repository = self.repo_epoch == repo_epoch and
            self.root_identity != null and self.root_identity.?.eql(root);
        if (!same_repository) {
            self.catalog.clear(allocator);
            self.draft = .single;
            self.render_now_unix = null;
        }
        self.repo_epoch = repo_epoch;
        self.root_identity = root;
        self.needs_initial = true;
        self.load_state = .loading;
        self.status.clear();
    }

    pub fn deactivate(self: *HistoryPageState) void {
        self.active = false;
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
        self.pending = null;
        self.repo_epoch = repo_epoch;
        self.root_identity = identity;
        self.needs_continuation = false;
        self.needs_initial = self.active and identity != null;
        self.load_state = if (identity == null) .no_repository else if (self.active) .loading else .idle;
    }

    pub fn requestReload(self: *HistoryPageState) void {
        if (self.draft.isRange()) {
            self.status.set("Cancel range selection before reloading", .{});
            return;
        }
        self.pending = null;
        self.needs_continuation = false;
        if (!self.active or self.root_identity == null) {
            self.needs_initial = false;
            self.load_state = .no_repository;
            return;
        }
        self.needs_initial = true;
        self.load_state = .loading;
        self.draft = .single;
    }

    pub fn requestContinuation(self: *HistoryPageState) void {
        if (!self.active or self.pending != null or !self.catalog.moreRowSelected()) return;
        self.needs_continuation = true;
        self.load_state = .loading;
    }

    pub fn cancelLoad(self: *HistoryPageState) void {
        if (self.pending == null and !self.needs_initial and !self.needs_continuation) return;
        self.pending = null;
        self.needs_initial = false;
        self.needs_continuation = false;
        self.load_state = if (self.catalog.snapshot == null)
            .idle
        else if (self.catalog.records.items.len == 0)
            .empty
        else
            .loaded;
        self.status.set("History load canceled", .{});
    }

    pub fn nextRequest(self: *HistoryPageState) ?app_load.HistoryCatalogRequest {
        if (!self.active or self.pending != null or self.root_identity == null) return null;
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

    pub fn arm(self: *HistoryPageState, pending: Pending) void {
        self.pending = pending;
        self.needs_initial = false;
        self.needs_continuation = false;
        self.load_state = .loading;
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
        if (pending.generation != generation) return;
        self.pending = null;
        self.load_state = .failed;
        self.status.set("History load could not be started", .{});
    }

    pub fn applyFinished(
        self: *HistoryPageState,
        allocator: std.mem.Allocator,
        current_identity: app_page.RequestIdentity,
        current_root: ?root_capability.Identity,
        finished: *app_load.HistoryCatalogFinished,
    ) !ApplyOutcome {
        const pending = self.pending orelse return .discarded;
        if (!pending.matches(finished)) return .discarded;
        self.pending = null;
        const root = current_root orelse return .discarded;
        if (!self.active or !std.meta.eql(current_identity, pending.identity) or !root.eql(pending.root_identity))
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
            .cancel_draft => if (!self.draft.clearAnchor()) {
                self.status.set("No previously selected diff", .{});
            },
            .unsupported_search => self.status.set("Commit search is not available in v1", .{}),
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
            .more_row_selected = self.catalog.moreRowSelected(),
            .picker_ready = self.catalog.records.items.len > 0,
            .keymap = effective,
        };
    }
};

test "History completion adopts only an admitted initial presentation clock" {
    const allocator = std.testing.allocator;
    const identity = app_page.RequestIdentity.history(9, 4);
    const root_identity: root_capability.Identity = .{ .device = 7, .inode = 11 };
    var state: HistoryPageState = .{
        .active = true,
        .activation_id = 4,
        .repo_epoch = 9,
        .root_identity = root_identity,
        .load_state = .loading,
        .pending = .{
            .identity = identity,
            .root_identity = root_identity,
            .generation = 3,
            .request = .initial,
        },
    };
    defer state.deinit(allocator);

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

    state.arm(.{
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

    state.arm(.{
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

    state.arm(.{
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

    var state: HistoryPageState = .{ .active = true, .load_state = .loaded };
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
