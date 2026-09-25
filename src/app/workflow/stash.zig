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
const local = @import("local.zig");

pub const State = struct {
    create: ?stash.Create = null,

    pub fn dialog(self: *const State) ?*const stash.Create {
        return if (self.create) |*value| value else null;
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.create) |*value| value.deinit(allocator);
        self.* = .{};
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
        if (self.overlay.isCreateStash()) self.overlay.close();
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
        const applied = if (same_repo) self.operations.applyAcceptedOutcome(allocator, .{ .create_stash = .{ .repo_root = finished.snapshot.repo_root } }, active) else operations.OutcomeApply{};
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
