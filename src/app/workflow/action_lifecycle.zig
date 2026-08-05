//! Sole owner for Git action launch/terminal correlation and spinner state.
//!
//! Task launchers prepare owned payloads, but only this controller commits an
//! accepted launch. Mutating launches close Review read authority in the same
//! synchronous transition; exact terminals reopen it before retiring the
//! action token. The controller owns no task payloads.

const std = @import("std");
const builtin = @import("builtin");
const chasen = @import("chasen");

const app_actions = @import("../actions.zig");
const app_message = @import("../message.zig");
const action_fence = @import("../pages/review/action_fence.zig");

const spinner_timer_id = "gitframe.git_action_spinner";
const spinner_interval_ns = 120 * std.time.ns_per_ms;

pub const ActionRuntime = struct {
    pending: ?PendingOwner = null,
    generation_value: u64 = 0,
    spinner_tick: u8 = 0,
    spinner_timer_running: bool = false,

    pub fn view(self: *const ActionRuntime) View {
        return .{ .runtime = self };
    }
};

pub const View = struct {
    runtime: *const ActionRuntime,

    pub fn hasPending(self: View) bool {
        return self.runtime.pending != null;
    }

    pub fn acceptedPending(self: View) ?app_actions.PendingAction {
        const owner = self.runtime.pending orelse return null;
        return if (owner.phase == .accepted) owner.token else null;
    }

    pub fn generation(self: View) u64 {
        return self.runtime.generation_value;
    }

    pub fn isCurrent(self: View, pending_action: app_actions.PendingAction) bool {
        const owner = self.runtime.pending orelse return false;
        return owner.matches(pending_action);
    }

    pub fn isAccepted(self: View, pending_action: app_actions.PendingAction) bool {
        const owner = self.runtime.pending orelse return false;
        return owner.matches(pending_action) and owner.phase == .accepted;
    }

    pub fn spinnerTick(self: View) u8 {
        return self.runtime.spinner_tick;
    }

    pub fn spinnerPresentation(self: View) ?SpinnerPresentation {
        const pending_action = self.acceptedPending() orelse return null;
        return .{ .kind = pending_action.kind, .tick = self.runtime.spinner_tick };
    }
};

pub const SpinnerPresentation = struct {
    kind: app_actions.ActionKind,
    tick: u8,
};

pub const PreparedLaunch = struct {
    pending: app_actions.PendingAction,
};

pub const AcceptedLaunch = struct {
    pending: app_actions.PendingAction,
};

const LaunchPhase = enum { preparing, accepted };

const PendingOwner = struct {
    token: app_actions.PendingAction,
    phase: LaunchPhase,

    fn matches(self: PendingOwner, pending_action: app_actions.PendingAction) bool {
        return self.token.generation == pending_action.generation and self.token.kind == pending_action.kind;
    }
};

pub const TerminalTarget = enum {
    current_review,
    detached_review,
};

pub const TerminalAdmission = union(enum) {
    rejected,
    accepted: struct {
        pending: app_actions.PendingAction,
        target: TerminalTarget,
    },
};

pub const Controller = struct {
    runtime: *ActionRuntime,
    fence: action_fence.Controller,

    pub fn view(self: Controller) View {
        return self.runtime.view();
    }

    pub fn prepare(self: Controller, kind: app_actions.ActionKind) PreparedLaunch {
        if (self.view().hasPending()) @panic("action prepare requires an idle runtime");
        self.runtime.generation_value +%= 1;
        const pending_action: app_actions.PendingAction = .{
            .generation = self.runtime.generation_value,
            .kind = kind,
        };
        self.runtime.pending = .{ .token = pending_action, .phase = .preparing };
        return .{ .pending = pending_action };
    }

    pub fn rejectSpawn(self: Controller, prepared: PreparedLaunch) void {
        const pending_action = prepared.pending;
        const owner = self.runtime.pending orelse
            @panic("action spawn rejection has no preparing owner");
        if (!owner.matches(pending_action) or owner.phase != .preparing) {
            @panic("action spawn rejection did not match its preparing owner");
        }
        self.runtime.pending = null;
    }

    /// Commits a concrete queued task and closes mutation read authority before
    /// returning to the update dispatcher.
    pub fn acceptSpawn(
        self: Controller,
        allocator: std.mem.Allocator,
        prepared: PreparedLaunch,
    ) AcceptedLaunch {
        const pending_action = prepared.pending;
        const owner = if (self.runtime.pending) |*pending_owner| pending_owner else @panic("action launch acceptance has no preparing owner");
        if (!owner.matches(pending_action) or owner.phase != .preparing) {
            @panic("action launch acceptance did not match its preparing owner");
        }
        owner.phase = .accepted;
        if (pending_action.kind.blocksBackgroundAcceptance()) {
            if (!self.fence.closeForAcceptedMutation(allocator, pending_action)) {
                @panic("accepted mutating action could not close Review read authority");
            }
        }
        return .{ .pending = pending_action };
    }

    /// Accepts only the exact current launched action. Mutations reopen their
    /// matching fence and queue recovery before the runtime becomes idle.
    pub fn finishExact(
        self: Controller,
        allocator: std.mem.Allocator,
        pending_action: app_actions.PendingAction,
        repo_root: []const u8,
        current_review_root: ?[]const u8,
    ) TerminalAdmission {
        if (!self.view().isAccepted(pending_action)) return .rejected;
        if (pending_action.kind.blocksBackgroundAcceptance() and
            !self.fence.reopenForExactTerminal(pending_action))
        {
            @panic("exact mutating action terminal could not reopen Review read authority");
        }
        var target: TerminalTarget = .detached_review;
        if (current_review_root) |current_root| {
            if (std.mem.eql(u8, current_root, repo_root)) target = .current_review;
        }
        if (target == .detached_review and pending_action.kind.blocksBackgroundAcceptance()) {
            self.fence.discardDetachedTerminal(allocator, pending_action);
        }
        self.runtime.pending = null;
        return .{ .accepted = .{
            .pending = pending_action,
            .target = target,
        } };
    }

    pub fn clearMatchingActionCursor(
        self: Controller,
        allocator: std.mem.Allocator,
        generation_value: u64,
    ) void {
        _ = self.fence.clearMatchingActionCursor(allocator, generation_value);
    }

    /// Closing the commit panel cancels only a matching message-assist owner.
    /// Its eventual task terminal becomes stale and cannot affect a later panel.
    pub fn cancelAcceptedCommitAssist(self: Controller) bool {
        const pending_owner = self.runtime.pending orelse return false;
        if (pending_owner.token.kind != .assist_commit_message) return false;
        if (pending_owner.phase != .accepted) @panic("commit assist cancellation requires an accepted owner");
        self.runtime.pending = null;
        return true;
    }

    /// Returns true when an idle tick should suppress redraw.
    pub fn tick(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) bool {
        if (self.runtime.pending) |owner| {
            if (owner.phase != .accepted) @panic("preparing action crossed the update boundary");
        } else {
            self.runtime.spinner_tick = 0;
            self.runtime.spinner_timer_running = false;
            ctx.timer().cancel(spinner_timer_id) catch {};
            return true;
        }
        self.runtime.spinner_tick +%= 1;
        return false;
    }

    pub fn reconcileSpinner(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) void {
        if (self.runtime.pending) |owner| {
            if (owner.phase != .accepted) @panic("preparing action crossed the update boundary");
            if (self.runtime.spinner_timer_running) return;
            ctx.timer().every(spinner_timer_id, spinner_interval_ns, .git_action_spinner_tick) catch return;
            self.runtime.spinner_timer_running = true;
            return;
        }

        if (!self.runtime.spinner_timer_running) return;
        self.runtime.spinner_timer_running = false;
        self.runtime.spinner_tick = 0;
        ctx.timer().cancel(spinner_timer_id) catch {};
    }
};

pub const testing = if (builtin.is_test) struct {
    pub fn installAccepted(
        runtime: *ActionRuntime,
        pending_action: app_actions.PendingAction,
    ) void {
        runtime.generation_value = @max(runtime.generation_value, pending_action.generation);
        runtime.pending = .{ .token = pending_action, .phase = .accepted };
    }

    pub fn clear(runtime: *ActionRuntime) void {
        runtime.pending = null;
    }

    pub fn setSpinner(runtime: *ActionRuntime, tick_value: u8, timer_running: bool) void {
        runtime.spinner_tick = tick_value;
        runtime.spinner_timer_running = timer_running;
    }

    pub fn spinnerTick(runtime: *const ActionRuntime) u8 {
        return runtime.spinner_tick;
    }

    pub fn spinnerTimerRunning(runtime: *const ActionRuntime) bool {
        return runtime.spinner_timer_running;
    }
} else struct {};

const UnitHarness = if (builtin.is_test) struct {
    const review_page = @import("../pages/review.zig");

    runtime: ActionRuntime = .{},
    review: review_page.ReviewPageState = .{},

    fn controller(self: *@This()) Controller {
        return .{
            .runtime = &self.runtime,
            .fence = .{
                .read_authority = &self.review.repository_read_authority,
                .activation = &self.review.activation,
                .action_cursor = &self.review.action_cursor,
                .auto_reload = &self.review.auto_reload,
                .review_projection = &self.review.review_projection,
                .deferred_projection_apply = &self.review.deferred_projection_apply,
            },
        };
    }

    fn finish(self: *@This(), pending: app_actions.PendingAction) bool {
        return switch (self.controller().finishExact(
            std.testing.allocator,
            pending,
            "",
            null,
        )) {
            .rejected => false,
            .accepted => true,
        };
    }
} else struct {};

test "ActionState tracks current pending action" {
    var harness: UnitHarness = .{};
    const prepared = harness.controller().prepare(.assist_commit_message);
    try std.testing.expect(harness.runtime.view().isCurrent(prepared.pending));
    try std.testing.expect(!harness.runtime.view().isAccepted(prepared.pending));

    const accepted = harness.controller().acceptSpawn(std.testing.allocator, prepared);
    try std.testing.expect(harness.runtime.view().isAccepted(accepted.pending));
    try std.testing.expect(harness.finish(accepted.pending));
    try std.testing.expect(!harness.runtime.view().hasPending());
}

test "ActionState cancels only exact preparing owner" {
    var harness: UnitHarness = .{};
    const preparing = harness.controller().prepare(.pull);
    const wrong: app_actions.PendingAction = .{
        .generation = preparing.pending.generation + 1,
        .kind = .pull,
    };
    try std.testing.expect(!harness.runtime.view().isCurrent(wrong));
    try std.testing.expect(harness.runtime.view().isCurrent(preparing.pending));
    harness.controller().rejectSpawn(preparing);
    try std.testing.expect(!harness.runtime.view().hasPending());

    const accepted_prepared = harness.controller().prepare(.fetch);
    const accepted = harness.controller().acceptSpawn(std.testing.allocator, accepted_prepared);
    try std.testing.expect(harness.runtime.view().isAccepted(accepted.pending));
    try std.testing.expect(harness.finish(accepted.pending));
}
