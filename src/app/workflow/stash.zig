//! Changes stash dialog and its concrete mutation lifecycle.
const std = @import("std");
const chasen = @import("chasen");
const ui = @import("chasen_ui");
const stash = @import("../stash.zig");
const actions = @import("../actions.zig");
const requests = @import("../git_requests.zig");
const message = @import("../message.zig");
const state = @import("../state.zig");
const operations = @import("../pages/changes/operations.zig");
const repo_session = @import("../repo_session.zig");
const lifecycle = @import("action_lifecycle.zig");
const load = @import("../load.zig");
const load_state = @import("../load_state.zig");
const git_command = @import("../../git/command.zig");
const local = @import("local.zig");

pub const State = struct {
    create: ?stash.Create = null,
    catalog: ?stash.Catalog = null,
    load_generation: u64 = 0,

    pub fn list(self: *const State) ?*const stash.Catalog {
        return if (self.catalog) |*value| value else null;
    }

    pub fn dialog(self: *const State) ?*const stash.Create {
        return if (self.create) |*value| value else null;
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.create) |*value| value.deinit(allocator);
        if (self.catalog) |*value| value.deinit(allocator);
        // Closing/reopening a dialog must not admit an earlier in-flight read.
        self.* = .{ .load_generation = self.load_generation };
    }
};

pub const Finish = struct {
    intent: local.ActionReloadIntent,
    error_message: ?[]u8 = null,
};

pub const Controller = struct {
    state: *State,
    lifecycle: lifecycle.Controller,
    operations: operations.Controller,
    repo: repo_session.View,
    current_changes_root: ?[]const u8,
    may_open: bool,
    env_map: ?*const std.process.Environ.Map,
    status: *state.StatusMessage,
    overlay: *state.OverlayState,

    pub fn update(self: Controller, ctx: *chasen.Ctx(message.Msg), msg: stash.Msg) !void {
        switch (msg) {
            .open_list => try self.openList(ctx),
            .close_list => self.cancel(ctx.allocator()),
            .request_selection => |action| try self.requestSelection(ctx.allocator(), action),
            .confirm_selection => try self.confirmSelection(ctx),
            .cancel_selection => if (self.state.catalog) |*catalog| catalog.cancelSelection(ctx.allocator()),
            .previous, .next, .first => if (self.state.catalog) |*catalog| {
                if (catalog.confirmation == null) switch (msg) {
                    .previous => catalog.focus.movePrev(),
                    .next => catalog.focus.moveNext(),
                    .first => catalog.focus.index = 0,
                    else => unreachable,
                };
            },
            .open => try self.open(ctx.allocator()),
            .cancel => self.cancel(ctx.allocator()),
            .confirm => try self.confirm(ctx),
            else => {
                if (!self.overlay.isCreateStash()) return;
                const dialog = if (self.state.create) |*value| value else return;
                switch (msg) {
                    .tab => dialog.focus = if (dialog.focus == .scope) .message else .scope,
                    .scope_previous => if (dialog.focus == .scope) {
                        dialog.scope = .all;
                    },
                    .scope_next => if (dialog.focus == .scope) {
                        if (self.operations.view().stashTarget(true)) |target| if (target.has_staged) {
                            dialog.scope = .staged;
                        };
                    },
                    .text => |text| if (dialog.focus == .message) {
                        try dialog.edit(text);
                    },
                    .paste => |text| if (dialog.focus == .message) {
                        try dialog.paste(text);
                    },
                    else => unreachable,
                }
            },
        }
    }

    fn open(self: Controller, allocator: std.mem.Allocator) !void {
        if (!self.may_open or self.overlay.kind != .none or self.lifecycle.view().hasPending()) return;
        const target = self.operations.view().stashTarget(false) orelse {
            self.status.set("stash unavailable: reload status and a known HEAD first", .{});
            return;
        };
        if (!target.has_all) {
            self.status.set("no changes to stash", .{});
            return;
        }
        const identity = self.repo.activeIdentity() orelse return;
        var snapshot = try stash.Snapshot.init(allocator, target.repo_root, self.repo.epoch(), identity, target.branch, target.oid);
        errdefer snapshot.deinit(allocator);
        var input = try ui.TextInput.init(allocator, .{ .placeholder = "Optional message" });
        errdefer input.deinit();
        self.state.deinit(allocator);
        self.state.create = .{ .snapshot = snapshot, .message = input };
        self.overlay.openCreateStash();
    }

    fn cancel(self: Controller, allocator: std.mem.Allocator) void {
        self.state.deinit(allocator);
        if (self.overlay.isCreateStash() or self.overlay.isStashes()) self.overlay.close();
    }

    fn confirm(self: Controller, ctx: *chasen.Ctx(message.Msg)) !void {
        if (!self.overlay.isCreateStash() or self.lifecycle.view().hasPending()) return;
        const dialog = self.state.dialog() orelse return;
        const target = self.operations.view().stashTarget(true) orelse {
            self.status.set("stash target is stale; cancel and reload", .{});
            return;
        };
        const snapshot = dialog.snapshot;
        if (!self.matchesRepo(snapshot) or !snapshot.matchesTarget(target.branch, target.oid)) {
            self.status.set("stash target changed; cancel and reopen", .{});
            return;
        }
        if (!(if (dialog.scope == .all) target.has_all else target.has_staged)) {
            self.status.set("no changes in selected stash scope", .{});
            return;
        }
        const root = self.repo.activeCapability() orelse return;
        const prepared = self.lifecycle.prepare(.create_stash);
        requests.startCreateStash(message.Msg, ctx, prepared.pending, dialog, root, self.env_map) catch |err| {
            self.lifecycle.rejectSpawn(prepared);
            self.status.set("could not start stash task: {s}", .{@errorName(err)});
            return;
        };
        _ = self.lifecycle.acceptSpawn(ctx.allocator(), prepared);
        self.status.set("creating stash: {s}", .{dialog.scope.label()});
        self.cancel(ctx.allocator());
    }

    fn currentSnapshot(self: Controller, allocator: std.mem.Allocator) !?stash.Snapshot {
        const target = self.operations.view().stashTarget(true) orelse return null;
        const identity = self.repo.activeIdentity() orelse return null;
        return try stash.Snapshot.init(allocator, target.repo_root, self.repo.epoch(), identity, target.branch, target.oid);
    }

    fn openList(self: Controller, ctx: *chasen.Ctx(message.Msg)) !void {
        if (!self.may_open or self.overlay.kind != .none or self.lifecycle.view().hasPending()) return;
        const root = self.repo.activeCapability() orelse return;
        var snapshot = try self.currentSnapshot(ctx.allocator()) orelse {
            self.status.set("Stashes unavailable: reload a known HEAD first", .{});
            return;
        };
        errdefer snapshot.deinit(ctx.allocator());
        var owned_root = try root.duplicate();
        errdefer owned_root.deinit();
        var environment = try git_command.LocalGitEnvironment.initFromParent(ctx.allocator(), self.env_map);
        errdefer environment.deinit();
        var owned_snapshot = try snapshot.clone(ctx.allocator());
        errdefer owned_snapshot.deinit(ctx.allocator());
        const Task = load.StashListLoadTask(message.Msg);
        const task = try ctx.allocator().create(Task);
        errdefer ctx.allocator().destroy(task);
        const generation = self.state.load_generation + 1;
        task.* = .{ .snapshot = owned_snapshot, .generation = generation, .root = owned_root, .environment = environment };
        _ = try ctx.task().spawnOwned(task, .{ .run = Task.run, .failed = Task.failed, .cleanup = Task.destroy });
        self.state.deinit(ctx.allocator());
        self.state.load_generation = generation;
        self.state.catalog = .{ .snapshot = snapshot, .pending = generation };
        self.overlay.openStashes();
    }

    pub fn finishList(self: Controller, allocator: std.mem.Allocator, value: load.StashListLoadFinished) void {
        var result = value;
        defer result.deinit(allocator);
        if (!self.overlay.isStashes() or !self.matchesRepo(result.snapshot)) return;
        const catalog = if (self.state.catalog) |*catalog| catalog else return;
        if (load_state.acceptBranchListResult(&catalog.pending, true, self.state.load_generation, catalog.snapshot.repo_root, result.generation, result.snapshot.repo_root) != .accepted) return;
        catalog.result.deinit(allocator);
        catalog.result = result.result;
        result.result = .empty;
        catalog.focus = .{ .len = if (catalog.result == .loaded) catalog.result.loaded.entries.len else 0 };
    }

    fn requestSelection(self: Controller, allocator: std.mem.Allocator, action: @import("../../git/stash.zig").SelectionAction) !void {
        if (!self.overlay.isStashes() or self.lifecycle.view().hasPending()) return;
        const catalog = if (self.state.catalog) |*value| value else return;
        if (catalog.confirmation != null or catalog.pending != null or catalog.result != .loaded or catalog.focus.len == 0) return;
        if (!self.matchesRepo(catalog.snapshot)) return;
        var snapshot = try self.currentSnapshot(allocator) orelse {
            self.status.set("Stash action unavailable: reload the current branch first", .{});
            return;
        };
        defer snapshot.deinit(allocator);
        catalog.confirmation = try stash.Selection.init(allocator, snapshot, catalog.result.loaded.entries[catalog.focus.index], action, catalog.focus.index);
    }

    fn confirmSelection(self: Controller, ctx: *chasen.Ctx(message.Msg)) !void {
        if (!self.overlay.isStashes() or self.lifecycle.view().hasPending()) return;
        const catalog = self.state.list() orelse return;
        const confirmation = if (catalog.confirmation) |*value| value else return;
        const target = self.operations.view().stashTarget(true) orelse {
            self.status.set("Stash target unavailable; cancel and reload", .{});
            return;
        };
        if (!self.matchesRepo(confirmation.snapshot) or !confirmation.snapshot.matchesTarget(target.branch, target.oid) or !std.mem.eql(u8, confirmation.snapshot.oid, target.oid)) {
            self.status.set("Stash target changed; cancel and reopen confirmation", .{});
            return;
        }
        const root = self.repo.activeCapability() orelse return;
        const prepared = self.lifecycle.prepare(if (confirmation.action == .apply) .apply_stash else .drop_stash);
        requests.startStashSelection(message.Msg, ctx, prepared.pending, confirmation, root, self.env_map) catch |err| {
            self.lifecycle.rejectSpawn(prepared);
            self.status.set("could not start stash task: {s}", .{@errorName(err)});
            return;
        };
        _ = self.lifecycle.acceptSpawn(ctx.allocator(), prepared);
        self.status.set("{s} {s}", .{ if (confirmation.action == .apply) "applying" else "dropping", confirmation.selector });
        self.cancel(ctx.allocator());
    }

    pub fn finishSelection(self: Controller, allocator: std.mem.Allocator, finished: *actions.StashSelectionFinished) ?Finish {
        const snapshot = finished.confirmation.snapshot;
        const same_repo = self.matchesRepo(snapshot);
        const terminal = switch (self.lifecycle.finishExact(allocator, finished.pending, snapshot.repo_root, if (same_repo) self.current_changes_root else null)) {
            .rejected => return null,
            .accepted => |accepted| accepted,
        };
        const active = terminal.target == .current_changes;
        const applied = if (same_repo) self.operations.applyAcceptedOutcome(allocator, .{ .stash = .{ .repo_root = snapshot.repo_root } }, active) else operations.OutcomeApply{};
        var outcome = Finish{ .intent = .{ .pending = finished.pending, .active_matches = active, .reload = applied.reload } };
        if (!active) return outcome;
        const dropping = finished.confirmation.action == .drop;
        if (dropping or finished.result.refreshed_catalog != null) {
            const owned_snapshot = snapshot.clone(allocator) catch null;
            if (owned_snapshot) |owned| {
                self.state.deinit(allocator);
                const refreshed: @import("../../git/stash.zig").ListResult = finished.result.refreshed_catalog orelse .{ .failed_static = "Stash task did not refresh the list; close and reopen Stashes" };
                self.state.catalog = .{
                    .snapshot = owned,
                    .pending = null,
                    .result = refreshed,
                    .focus = .{ .len = if (refreshed == .loaded) refreshed.loaded.entries.len else 0, .index = finished.confirmation.list_index },
                    .notice = if (dropping) null else "Selected stash changed; list reloaded. Select again.",
                };
                const focus = &self.state.catalog.?.focus;
                focus.index = @min(focus.index, focus.len -| 1);
                finished.result.refreshed_catalog = null;
                self.overlay.openStashes();
                if (!dropping) {
                    self.status.set("selected stash changed; list reloaded", .{});
                    return outcome;
                }
            }
        }
        if (dropping) {
            switch (finished.result.operation) {
                .ok => self.status.set("stash dropped; inspect Stashes", .{}),
                .failed, .failed_static => |detail| {
                    self.status.set("stash drop failed; inspect the refreshed list", .{});
                    outcome.error_message = std.fmt.allocPrint(allocator, "{s}\n\nDrop may not have completed. The stash list was refreshed where possible.\nClose this error to inspect it before retrying.", .{detail}) catch null;
                },
            }
            return outcome;
        }
        switch (finished.result.operation) {
            .ok => self.status.set("stash applied; stash retained", .{}),
            .failed, .failed_static => |detail| {
                self.status.set("stash apply failed; stash retained", .{});
                outcome.error_message = std.fmt.allocPrint(allocator, "{s}\n\nStash retained. Changes will be reloaded.\nReopen Stashes to reload the list before retrying.", .{detail}) catch null;
            },
        }
        return outcome;
    }

    /// A retained catalog under a drop error is display-only until that error closes.
    pub fn restoreList(self: Controller, allocator: std.mem.Allocator) void {
        const catalog = self.state.list() orelse return;
        if (!self.may_open or self.overlay.kind != .none or !self.matchesRepo(catalog.snapshot)) {
            self.state.deinit(allocator);
            return;
        }
        self.overlay.openStashes();
    }

    fn matchesRepo(self: Controller, snapshot: stash.Snapshot) bool {
        const identity = self.repo.activeIdentity() orelse return false;
        const root = self.repo.activeRoot() orelse return false;
        return self.repo.epoch() == snapshot.epoch and identity.eql(snapshot.identity) and std.mem.eql(u8, root, snapshot.repo_root);
    }

    /// The caller owns/deinitializes the result, including stale terminals.
    pub fn finish(self: Controller, allocator: std.mem.Allocator, finished: *const actions.CreateStashFinished) ?Finish {
        const same_repo = self.matchesRepo(finished.snapshot);
        const terminal = switch (self.lifecycle.finishExact(allocator, finished.pending, finished.snapshot.repo_root, if (same_repo) self.current_changes_root else null)) {
            .rejected => return null,
            .accepted => |accepted| accepted,
        };
        const active = terminal.target == .current_changes;
        const applied = if (same_repo) self.operations.applyAcceptedOutcome(allocator, .{ .stash = .{ .repo_root = finished.snapshot.repo_root } }, active) else operations.OutcomeApply{};
        var outcome = Finish{ .intent = .{ .pending = finished.pending, .active_matches = active, .reload = applied.reload } };
        if (!active) return outcome;
        const saved: ?[]const u8 = finished.result.saved_oid;
        const saved_text: []const u8 = saved orelse "unknown";
        switch (finished.result.operation) {
            .ok => self.status.set("stash created: {s} ({s})", .{ finished.scope.label(), saved_text[0..@min(12, saved_text.len)] }),
            .failed, .failed_static => |detail| {
                self.status.set("stash failed; saved stash: {s}", .{if (saved) |oid| oid[0..@min(12, oid.len)] else "not identified"});
                outcome.error_message = std.fmt.allocPrint(allocator, "{s}\n\nSaved stash: {s}\nStashes are retained. Changes will be reloaded.", .{ detail, saved orelse "not identified; inspect git stash list" }) catch null;
            },
        }
        return outcome;
    }
};
