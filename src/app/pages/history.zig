//! History page state and catalog task admission.

const std = @import("std");
const app_load = @import("../load.zig");
const app_page = @import("../page.zig");
const app_state = @import("../state.zig");
const root_capability = @import("../../repo/root_capability.zig");
const catalog = @import("history/catalog.zig");
const input = @import("history/input.zig");

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
            self.repo_epoch = repo_epoch;
            self.root_identity = null;
            self.needs_initial = false;
            self.load_state = .no_repository;
            return;
        };
        const same_repository = self.repo_epoch == repo_epoch and
            self.root_identity != null and self.root_identity.?.eql(root);
        if (!same_repository) self.catalog.clear(allocator);
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
        self.pending = null;
        self.repo_epoch = repo_epoch;
        self.root_identity = identity;
        self.needs_continuation = false;
        self.needs_initial = self.active and identity != null;
        self.load_state = if (identity == null) .no_repository else if (self.active) .loading else .idle;
    }

    pub fn requestReload(self: *HistoryPageState) void {
        self.pending = null;
        self.needs_continuation = false;
        if (!self.active or self.root_identity == null) {
            self.needs_initial = false;
            self.load_state = .no_repository;
            return;
        }
        self.needs_initial = true;
        self.load_state = .loading;
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
                    .initial => try self.catalog.replace(allocator, page),
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
            .owned_noop => {},
        }
    }

    pub fn inputContext(self: *const HistoryPageState, effective: @import("keymap").Effective) input.Context {
        return .{
            .loading = self.load_state == .loading,
            .more_row_selected = self.catalog.moreRowSelected(),
            .keymap = effective,
        };
    }
};

test "History logical cancellation makes an arriving catalog result stale" {
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
    state.cancelLoad();
    try std.testing.expectEqual(LoadState.idle, state.load_state);
    try std.testing.expectEqualStrings("History load canceled", state.status.text());

    var finished: app_load.HistoryCatalogFinished = .{
        .identity = identity,
        .root_identity = root_identity,
        .generation = 3,
        .request = .initial,
        .result = .{ .failure = .git_command_failed },
    };
    try std.testing.expectEqual(
        ApplyOutcome.discarded,
        try state.applyFinished(std.testing.allocator, identity, root_identity, &finished),
    );
}
