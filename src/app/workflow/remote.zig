//! Changes remote-operation workflow and foreground push ownership.
//!
//! This controller owns push, pull, fetch, branch-switch, retry inspection,
//! interactive-push, and upstream-finalization state. Changes supplies synchronous target
//! and outcome ports; the root shell consumes typed reload intent. The module
//! never imports the root App, local workflow, read coordinator, or shell
//! effects.

const std = @import("std");
const builtin = @import("builtin");
const chasen = @import("chasen");

const app_actions = @import("../actions.zig");
const branch_commit_time = @import("../branch_commit_time.zig");
const effect_origin = @import("../effect_origin.zig");
const app_git_requests = @import("../git_requests.zig");
const git_ops = @import("../git_ops.zig");
const app_load = @import("../load.zig");
const app_load_state = @import("../load_state.zig");
const app_message = @import("../message.zig");
const page = @import("../page.zig");
const app_push_retry = @import("../push_retry.zig");
const remote_request = @import("../remote_request.zig");
const repo_session = @import("../repo_session.zig");
const app_state = @import("../state.zig");
const changes_action_fence = @import("../pages/changes/action_fence.zig");
const changes_operations = @import("../pages/changes/operations.zig");
const action_lifecycle = @import("action_lifecycle.zig");
const remote_state = @import("remote_state.zig");
const git_remote = @import("../../git/remote.zig");
const git_command = @import("../../git/command.zig");
const git_refs = @import("../../git/refs.zig");
const root_capability = @import("../../repo/root_capability.zig");

const BranchListLoadFinished = app_load.BranchListLoadFinished;
const BranchListLoadTask = app_load.BranchListLoadTask(app_message.Msg);

pub const State = remote_state.State;

pub const View = struct {
    state: *const State,

    pub fn pushConfirmation(self: View) ?app_state.PushConfirmation {
        return self.state.push_confirmation;
    }

    pub fn pullConfirmation(self: View) ?app_state.PullConfirmation {
        return self.state.pull_confirmation;
    }

    pub fn pushErrorMessage(self: View) ?[]const u8 {
        return self.state.push_error_message;
    }

    pub fn pushRetryTarget(self: View) ?*const app_state.PushRetryTarget {
        return self.state.push_retry.state.availableTarget();
    }

    pub fn pushRetryInspecting(self: View) bool {
        return self.state.push_retry.state == .inspecting;
    }

    pub fn branchSwitch(self: View) *const app_state.BranchSwitchState {
        return &self.state.branch_switch;
    }

    pub fn hasForeground(self: View) bool {
        return self.state.push_retry.state.hasForeground();
    }

    pub fn isFinalizing(self: View) bool {
        return self.state.push_retry.state.isFinalizing();
    }

    pub fn canceling(self: View) bool {
        return self.state.canceling_generation != null;
    }

    pub fn canCancel(self: View, pending: ?app_actions.PendingAction) bool {
        const action = pending orelse return false;
        return isBackgroundRemoteKind(action.kind) and self.state.action_control.isActive(action.generation);
    }
};

pub const RedrawSink = struct {
    skip_requested: *bool,

    fn requestSkip(self: RedrawSink) void {
        self.skip_requested.* = true;
    }
};

pub const Outcome = struct {
    reload: changes_action_fence.ReloadIntent = .none,
    cancel_local_confirmations: bool = false,
    quit_after_terminal: bool = false,
};

pub const Controller = struct {
    state: *State,
    lifecycle: action_lifecycle.Controller,
    operations: changes_operations.Controller,
    repo: repo_session.View,
    current_changes_root: ?[]const u8,
    env_map: ?*std.process.Environ.Map,
    active_page: page.Id,
    changes_origin: effect_origin.PageOrigin,
    effect_snapshot: effect_origin.Snapshot,
    status: *app_state.StatusMessage,
    overlay: *app_state.OverlayState,
    redraw: RedrawSink,

    pub fn view(self: Controller) View {
        return .{ .state = self.state };
    }

    /// Requests generation-scoped cancellation without retiring the action
    /// owner or reopening its read fence. The exact terminal does both.
    pub fn cancelActiveRemote(self: Controller, defer_quit: bool) bool {
        const pending = self.lifecycle.view().acceptedPending() orelse return false;
        if (self.state.push_retry.state.isFinalizing() and pending.kind == .push) {
            if (defer_quit) self.state.quit_after_remote_terminal = true;
            self.setStatus("finalizing upstream...", .{});
            return defer_quit;
        }
        if (!isBackgroundRemoteKind(pending.kind)) return false;
        if (!self.state.action_control.isActive(pending.generation)) return false;
        if (defer_quit) self.state.quit_after_remote_terminal = true;
        if (self.state.action_control.requestCancel(pending.generation)) {
            self.state.canceling_generation = pending.generation;
            self.setStatus("canceling...", .{});
        }
        return true;
    }

    pub fn requestPush(self: Controller, allocator: std.mem.Allocator) !Outcome {
        if (self.lifecycle.view().hasPending()) {
            self.setStatus("another git action is running", .{});
            return .{};
        }

        const target = switch (self.operations.view().pushTarget()) {
            .ready => |target| target,
            .unavailable_source => return self.reject("push unavailable for this source"),
            .no_repo => return self.reject("push unavailable: no repository"),
            .loading_branch_status => return self.reject("branch status is still loading"),
            .detached_head => return self.reject("push unavailable on detached HEAD"),
            .branch_unavailable => return self.reject("push unavailable: branch is unknown"),
            .no_upstream => return self.reject("push unavailable: no upstream branch"),
            .upstream_not_remote_branch => return self.reject("push unavailable: unsupported upstream"),
            .branch_status_unavailable => return self.reject("push unavailable: branch status is incomplete"),
            .pull_first => return self.reject("push blocked: pull/rebase remote changes first"),
            .nothing_to_push => return self.reject("nothing to push"),
        };
        const repository_identity = self.currentRepositoryIdentity() orelse
            return self.reject("push unavailable: repository authority changed");
        const active_root = self.repo.activeRoot() orelse
            return self.reject("push unavailable: no repository");
        if (!std.mem.eql(u8, active_root, target.repo_root))
            return self.reject("push unavailable: repository authority changed");

        self.cancelPushConfirmation(allocator);
        self.cancelPullConfirmation(allocator);
        self.clearPushError(allocator);

        var proposal = try self.operations.view().ownPushProposal(allocator, repository_identity, target);
        var proposal_consumed = false;
        defer if (!proposal_consumed) proposal.deinit(allocator);
        const owned = proposal.push;
        self.state.push_confirmation = .{
            .repository_identity = owned.repository_identity,
            .mode = owned.mode,
            .repo_root = owned.repo_root,
            .branch = owned.branch,
            .remote = owned.remote,
            .remote_branch = owned.remote_branch,
            .oid = owned.oid,
            .ahead_behind = owned.ahead_behind,
        };
        proposal_consumed = true;
        self.operations.navigation.clearDiffSelection();
        self.overlay.openPushBranch();
        return .{ .cancel_local_confirmations = true };
    }

    pub fn confirmPush(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        if (self.lifecycle.view().hasPending()) {
            self.setStatus("another git action is running", .{});
            return;
        }
        var confirmation = self.state.push_confirmation orelse return;
        self.state.push_confirmation = null;
        var confirmation_consumed = false;
        defer if (!confirmation_consumed) confirmation.deinit(ctx.allocator());
        if (!self.repositoryMatches(confirmation.repository_identity) or
            self.repo.activeRoot() == null or
            !std.mem.eql(u8, self.repo.activeRoot().?, confirmation.repo_root))
        {
            self.setStatus("push unavailable: repository authority changed", .{});
            if (self.overlay.isPushBranch()) self.overlay.close();
            return;
        }
        self.setStatus("pushing: {s} -> {s}/{s}", .{ confirmation.branch, confirmation.remote, confirmation.remote_branch });
        const prepared = self.lifecycle.prepare(.push);
        var root: ?root_capability.RootCapability = self.retainBackgroundRoot() catch |err| {
            self.lifecycle.rejectSpawn(prepared);
            self.setStatus("push unavailable: repository authority could not be retained", .{});
            return err;
        };
        defer if (root) |*owned| owned.deinit();
        var environment: ?git_remote.OwnedRemoteEnvironment = git_remote.buildRemoteEnvironment(
            ctx.allocator(),
            self.env_map,
            .background,
        ) catch |err| {
            self.lifecycle.rejectSpawn(prepared);
            self.setStatus("could not prepare background push", .{});
            return err;
        };
        defer if (environment) |*owned| owned.deinit();
        self.beginRemoteControl(prepared.pending);
        confirmation_consumed = true;
        app_git_requests.startPush(
            app_message.Msg,
            ctx,
            prepared.pending,
            &root,
            &environment,
            self.state.action_control.cancellationView(prepared.pending.generation),
            &confirmation,
        ) catch |err| {
            _ = self.state.action_control.finish(prepared.pending.generation);
            self.lifecycle.rejectSpawn(prepared);
            self.setStatus("could not start push task", .{});
            if (self.overlay.isPushBranch()) self.overlay.close();
            return err;
        };
        _ = self.lifecycle.acceptSpawn(ctx.allocator(), prepared);
        self.overlay.close();
    }

    pub fn cancelPushConfirmation(self: Controller, allocator: std.mem.Allocator) void {
        if (self.state.push_confirmation) |*confirmation| confirmation.deinit(allocator);
        self.state.push_confirmation = null;
        if (self.overlay.isPushBranch()) self.overlay.close();
    }

    pub fn requestPull(self: Controller, allocator: std.mem.Allocator) !Outcome {
        if (self.lifecycle.view().hasPending()) {
            self.setStatus("another git action is running", .{});
            return .{};
        }
        const target = switch (self.operations.view().pullTarget()) {
            .ready => |target| target,
            .unavailable_source => return self.reject("pull unavailable for this source"),
            .no_repo => return self.reject("pull unavailable: no repository"),
            .loading_branch_status => return self.reject("branch status is still loading"),
            .detached_head => return self.reject("pull unavailable on detached HEAD"),
            .branch_unavailable => return self.reject("pull unavailable: branch is unknown"),
            .no_upstream => return self.reject("pull unavailable: no upstream branch"),
            .upstream_not_remote_branch => return self.reject("pull unavailable: unsupported upstream"),
            .branch_status_unavailable => return self.reject("pull unavailable: branch status is incomplete"),
            .status_loading => return self.reject("status is still loading"),
            .status_stale => return self.reject("pull unavailable: status is stale"),
            .dirty_worktree => return self.reject("pull blocked: commit, stage, or discard local changes first"),
            .untracked_files_present => return self.reject("pull blocked: untracked files present"),
        };
        const repository_identity = self.currentRepositoryIdentity() orelse
            return self.reject("pull unavailable: repository authority changed");
        const active_root = self.repo.activeRoot() orelse
            return self.reject("pull unavailable: no repository");
        if (!std.mem.eql(u8, active_root, target.repo_root))
            return self.reject("pull unavailable: repository authority changed");

        self.cancelPushConfirmation(allocator);
        self.cancelPullConfirmation(allocator);
        self.clearPushError(allocator);
        var proposal = try self.operations.view().ownPullProposal(allocator, target);
        var proposal_consumed = false;
        defer if (!proposal_consumed) proposal.deinit(allocator);
        const owned = proposal.pull;
        self.state.pull_confirmation = .{
            .repository_identity = repository_identity,
            .repo_root = owned.repo_root,
            .branch = owned.branch,
            .remote = owned.remote,
            .remote_branch = owned.remote_branch,
            .oid = owned.oid,
            .ahead = owned.ahead,
            .behind = owned.behind,
        };
        proposal_consumed = true;
        self.operations.navigation.clearDiffSelection();
        self.overlay.openPullBranch();
        return .{ .cancel_local_confirmations = true };
    }

    pub fn confirmPull(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        if (self.lifecycle.view().hasPending()) {
            self.setStatus("another git action is running", .{});
            return;
        }
        var confirmation = self.state.pull_confirmation orelse return;
        self.state.pull_confirmation = null;
        var confirmation_consumed = false;
        defer if (!confirmation_consumed) confirmation.deinit(ctx.allocator());
        if (!self.repositoryMatches(confirmation.repository_identity) or
            self.repo.activeRoot() == null or
            !std.mem.eql(u8, self.repo.activeRoot().?, confirmation.repo_root))
        {
            self.setStatus("pull unavailable: repository authority changed", .{});
            if (self.overlay.isPullBranch()) self.overlay.close();
            return;
        }
        self.setStatus("pulling: {s} <- {s}/{s}", .{ confirmation.branch, confirmation.remote, confirmation.remote_branch });
        const prepared = self.lifecycle.prepare(.pull);
        var root: ?root_capability.RootCapability = self.retainBackgroundRoot() catch |err| {
            self.lifecycle.rejectSpawn(prepared);
            self.setStatus("pull unavailable: repository authority could not be retained", .{});
            return err;
        };
        defer if (root) |*owned| owned.deinit();
        var environment: ?git_remote.OwnedRemoteEnvironment = git_remote.buildRemoteEnvironment(
            ctx.allocator(),
            self.env_map,
            .background,
        ) catch |err| {
            self.lifecycle.rejectSpawn(prepared);
            self.setStatus("could not prepare background pull", .{});
            return err;
        };
        defer if (environment) |*owned| owned.deinit();
        self.beginRemoteControl(prepared.pending);
        confirmation_consumed = true;
        app_git_requests.startPull(
            app_message.Msg,
            ctx,
            prepared.pending,
            &root,
            &environment,
            self.state.action_control.cancellationView(prepared.pending.generation),
            &confirmation,
        ) catch |err| {
            _ = self.state.action_control.finish(prepared.pending.generation);
            self.lifecycle.rejectSpawn(prepared);
            self.setStatus("could not start pull task", .{});
            if (self.overlay.isPullBranch()) self.overlay.close();
            return err;
        };
        _ = self.lifecycle.acceptSpawn(ctx.allocator(), prepared);
        self.overlay.close();
    }

    pub fn cancelPullConfirmation(self: Controller, allocator: std.mem.Allocator) void {
        if (self.state.pull_confirmation) |*confirmation| confirmation.deinit(allocator);
        self.state.pull_confirmation = null;
        if (self.overlay.isPullBranch()) self.overlay.close();
    }

    pub fn requestFetch(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        if (self.lifecycle.view().hasPending()) {
            self.setStatus("another git action is running", .{});
            return;
        }
        const target = switch (self.operations.view().fetchTarget()) {
            .ready => |target| target,
            .unavailable_source => return self.rejectVoid("fetch unavailable for this source"),
            .no_repo => return self.rejectVoid("fetch unavailable: no repository"),
            .loading_branch_status => return self.rejectVoid("branch status is still loading"),
            .detached_head => return self.rejectVoid("fetch unavailable on detached HEAD"),
            .branch_unavailable => return self.rejectVoid("fetch unavailable: branch is unknown"),
            .no_upstream => return self.rejectVoid("fetch unavailable: no upstream remote"),
            .upstream_not_remote => return self.rejectVoid("fetch unavailable: unsupported upstream"),
        };
        const repository_identity = self.currentRepositoryIdentity() orelse
            return self.rejectVoid("fetch unavailable: repository authority changed");
        const active_root = self.repo.activeRoot() orelse
            return self.rejectVoid("fetch unavailable: no repository");
        if (!std.mem.eql(u8, active_root, target.repo_root))
            return self.rejectVoid("fetch unavailable: repository authority changed");

        var proposal = try self.operations.view().ownFetchProposal(ctx.allocator(), target);
        var proposal_consumed = false;
        defer if (!proposal_consumed) proposal.deinit(ctx.allocator());
        const owned = proposal.fetch;
        var request: app_git_requests.FetchRequest = .{
            .repository_identity = repository_identity,
            .repo_root = owned.repo_root,
            .remote = owned.remote,
        };
        proposal_consumed = true;
        var request_consumed = false;
        defer if (!request_consumed) request.deinit(ctx.allocator());
        self.setStatus("fetching: {s}", .{target.remote});
        const prepared = self.lifecycle.prepare(.fetch);
        var root: ?root_capability.RootCapability = self.retainBackgroundRoot() catch |err| {
            self.lifecycle.rejectSpawn(prepared);
            self.setStatus("fetch unavailable: repository authority could not be retained", .{});
            return err;
        };
        defer if (root) |*owned_root| owned_root.deinit();
        var environment: ?git_remote.OwnedRemoteEnvironment = git_remote.buildRemoteEnvironment(
            ctx.allocator(),
            self.env_map,
            .background,
        ) catch |err| {
            self.lifecycle.rejectSpawn(prepared);
            self.setStatus("could not prepare background fetch", .{});
            return err;
        };
        defer if (environment) |*owned_environment| owned_environment.deinit();
        self.beginRemoteControl(prepared.pending);
        // startFetch consumes the request on both task admission success and
        // rejection; until this call the controller remains its owner.
        request_consumed = true;
        app_git_requests.startFetch(
            app_message.Msg,
            ctx,
            prepared.pending,
            &root,
            &environment,
            self.state.action_control.cancellationView(prepared.pending.generation),
            &request,
        ) catch |err| {
            _ = self.state.action_control.finish(prepared.pending.generation);
            self.lifecycle.rejectSpawn(prepared);
            self.setStatus("could not start fetch task", .{});
            return err;
        };
        _ = self.lifecycle.acceptSpawn(ctx.allocator(), prepared);
    }

    pub fn requestBranchSwitch(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !Outcome {
        if (self.lifecycle.view().hasPending()) {
            self.setStatus("another git action is running", .{});
            return .{};
        }
        const target = switch (self.operations.view().branchSwitchTarget()) {
            .ready => |target| target,
            .unavailable_source => return self.reject("branch switch unavailable for this source"),
            .no_repo => return self.reject("branch switch unavailable: no repository"),
            .loading_branch_status => return self.reject("branch status is still loading"),
            .detached_head => return self.reject("branch switch unavailable on detached HEAD"),
            .branch_unavailable => return self.reject("branch switch unavailable: branch is unknown"),
            .branch_status_unavailable => return self.reject("branch switch unavailable: branch status is incomplete"),
            .status_loading => return self.reject("status is still loading"),
            .status_stale => return self.reject("branch switch unavailable: status is stale"),
            .dirty_worktree => return self.reject("branch switch blocked: commit, stage, or discard local changes first"),
            .untracked_files_present => return self.reject("branch switch blocked: untracked files present"),
        };

        self.cancelPushConfirmation(ctx.allocator());
        self.cancelPullConfirmation(ctx.allocator());
        self.clearPushError(ctx.allocator());
        self.clearBranchSwitch(ctx.allocator());
        self.state.branch_switch_load_generation +%= 1;
        const generation = self.state.branch_switch_load_generation;

        var proposal = try self.operations.view().ownBranchSwitchProposal(ctx.allocator(), target);
        var proposal_consumed = false;
        defer if (!proposal_consumed) proposal.deinit(ctx.allocator());
        const owned = proposal.switch_branch;
        self.state.branch_switch = .{
            .repo_root = owned.repo_root,
            .current_branch = owned.branch,
            .current_oid = owned.oid,
            .generation = generation,
            .loading = true,
        };
        proposal_consumed = true;
        self.state.branch_switch_load_pending = generation;
        self.operations.navigation.clearDiffSelection();
        self.overlay.openSwitchBranch();
        errdefer self.clearBranchSwitch(ctx.allocator());

        const capability = self.repo.activeCapability() orelse return error.RepositoryReadAuthorityClosed;
        var root = try capability.duplicate();
        var root_consumed = false;
        errdefer if (!root_consumed) root.deinit();
        var environment = try git_command.LocalGitEnvironment.initFromParent(ctx.allocator(), self.env_map);
        var environment_consumed = false;
        errdefer if (!environment_consumed) environment.deinit();
        const owned_repo_root = try ctx.allocator().dupe(u8, target.repo_root);
        var repo_root_consumed = false;
        errdefer if (!repo_root_consumed) ctx.allocator().free(owned_repo_root);
        const task = try ctx.allocator().create(BranchListLoadTask);
        task.* = .{
            .origin = .changes,
            .repo_epoch = self.repo.epoch(),
            .activation_id = self.changes_origin.activation_id,
            .repo_root = owned_repo_root,
            .root = root,
            .environment = environment,
            .generation = generation,
        };
        root_consumed = true;
        environment_consumed = true;
        repo_root_consumed = true;
        errdefer task.destroy(ctx.allocator());
        try ctx.task().spawnWith(.{ .ctx = task, .run = BranchListLoadTask.run, .failed = BranchListLoadTask.failed });
        return .{ .cancel_local_confirmations = true };
    }

    pub fn moveBranchSwitchSelection(self: Controller, delta: isize) void {
        const branch_switch = &self.state.branch_switch;
        if (!branch_switch.hasState() or branch_switch.loading or branch_switch.branches.len == 0) return;
        branch_switch.selected_index = wrapIndex(branch_switch.selected_index, branch_switch.branches.len, delta);
    }

    pub fn prepareBranchSwitchModalRedraw(self: Controller, io: std.Io) void {
        const branch_switch = &self.state.branch_switch;
        if (!self.overlay.isSwitchBranch() or
            !branch_switch.hasState() or
            branch_switch.loading or
            branch_switch.branches.len == 0) return;
        branch_switch.render_now_unix = branch_commit_time.sampleUnixSeconds(io);
    }

    pub fn confirmBranchSwitch(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        const branch_switch = &self.state.branch_switch;
        if (!branch_switch.hasState()) return;
        if (branch_switch.loading) return self.rejectVoid("branch list is still loading");
        if (branch_switch.branches.len == 0) return self.rejectVoid("branch switch unavailable: no local branches");
        if (self.lifecycle.view().hasPending()) return self.rejectVoid("another git action is running");

        const selected = branch_switch.branches[branch_switch.selected_index];
        if (selected.current or std.mem.eql(u8, selected.name, branch_switch.current_branch)) {
            self.setStatus("already on branch: {s}", .{branch_switch.current_branch});
            self.clearBranchSwitch(ctx.allocator());
            return;
        }

        var request: app_git_requests.SwitchBranchRequest = .{
            .repo_root = &.{},
            .expected_branch = &.{},
            .expected_oid = &.{},
            .target_branch = &.{},
            .target_oid = &.{},
        };
        defer request.deinit(ctx.allocator());
        request.repo_root = try ctx.allocator().dupe(u8, branch_switch.repo_root);
        request.expected_branch = try ctx.allocator().dupe(u8, branch_switch.current_branch);
        request.expected_oid = try ctx.allocator().dupe(u8, branch_switch.current_oid);
        request.target_branch = try ctx.allocator().dupe(u8, selected.name);
        request.target_oid = try ctx.allocator().dupe(u8, selected.oid);
        self.setStatus("switching branch: {s} -> {s}", .{ branch_switch.current_branch, selected.name });
        const prepared = self.lifecycle.prepare(.switch_branch);
        const capability = self.repo.activeCapability() orelse {
            self.lifecycle.rejectSpawn(prepared);
            self.setStatus("branch switch unavailable: repository authority changed", .{});
            return;
        };
        app_git_requests.startSwitchBranch(app_message.Msg, ctx, prepared.pending, &request, capability, self.env_map) catch |err| {
            self.lifecycle.rejectSpawn(prepared);
            self.setStatus("could not start branch switch task", .{});
            return err;
        };
        _ = self.lifecycle.acceptSpawn(ctx.allocator(), prepared);
        self.clearBranchSwitch(ctx.allocator());
    }

    pub fn clearPushError(self: Controller, allocator: std.mem.Allocator) void {
        self.clearPushErrorPresentation(allocator);
        self.state.push_retry.state.deinit(allocator);
    }

    pub fn clearBranchSwitch(self: Controller, allocator: std.mem.Allocator) void {
        self.state.clearBranchSwitch(allocator, self.overlay);
    }

    pub fn runInteractivePush(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        if (self.lifecycle.view().hasPending()) return self.rejectVoid("another git action is running");
        try self.startPushInspection(ctx, "interactive push retry is not available for this failure");
    }

    pub fn finishPush(self: Controller, allocator: std.mem.Allocator, finished: app_actions.PushFinished) !Outcome {
        var result = finished;
        defer result.deinit(allocator);
        const terminal = self.acceptTerminal(allocator, result.pending, result.repo_root) orelse return .{};
        const active_matches = terminal.target == .current_changes;
        const quit_after_terminal = self.finishRemoteControl(result.pending);
        if (!self.remoteRequestMatches(result.identity) or
            result.identity.operation_generation != result.pending.generation)
            return .{ .quit_after_terminal = quit_after_terminal };
        switch (result.result.outcome) {
            .ok => {
                if (active_matches) {
                    self.setRemoteStatus(result.result.warnings, "pushed: {s} -> {s}/{s}", .{ result.branch, result.remote, result.remote_branch });
                    return .{ .reload = .source_and_aux, .quit_after_terminal = quit_after_terminal };
                }
                self.setRemoteStatus(result.result.warnings, "pushed: {s}", .{result.repo_root});
            },
            .failed => |failure| {
                self.setRemoteFailureStatus(result.result.warnings, .push, failure);
                const retry_allowed = failure != .http_userinfo_rejected and !remoteOutcomeUnknown(failure);
                const retry_target = if (retry_allowed) try pushRetryTargetFromFinished(allocator, result) else null;
                errdefer if (retry_target) |owned_target| {
                    var target = owned_target;
                    target.deinit(allocator);
                };
                const presentation = try remoteFailurePresentationAlloc(allocator, .push, failure, result.result.warnings);
                defer allocator.free(presentation);
                try self.setPushErrorWithRetry(allocator, presentation, retry_target);
                return .{
                    .reload = if (active_matches and remoteOutcomeUnknown(failure)) .source_and_aux else .none,
                    .quit_after_terminal = quit_after_terminal,
                };
            },
        }
        return .{ .quit_after_terminal = quit_after_terminal };
    }

    pub fn finishPull(self: Controller, allocator: std.mem.Allocator, finished: app_actions.PullFinished) Outcome {
        var result = finished;
        defer result.deinit(allocator);
        const terminal = self.acceptTerminal(allocator, result.pending, result.repo_root) orelse return .{};
        const quit_after_terminal = self.finishRemoteControl(result.pending);
        if (!self.remoteRequestMatches(result.identity) or
            result.identity.operation_generation != result.pending.generation)
            return .{ .quit_after_terminal = quit_after_terminal };
        const active_matches = terminal.target == .current_changes;
        switch (result.result.outcome) {
            .ok => |success| switch (success) {
                .completed => if (active_matches) {
                    self.setRemoteStatus(result.result.warnings, "pulled: {s} <- {s}/{s}", .{ result.branch, result.remote, result.remote_branch });
                } else {
                    self.setRemoteStatus(result.result.warnings, "pulled: {s}", .{result.repo_root});
                },
                .already_up_to_date => self.setRemoteStatus(result.result.warnings, "already up to date", .{}),
            },
            .failed => |failure| self.setRemoteFailureStatus(result.result.warnings, .pull, failure),
        }
        return .{
            .reload = if (active_matches) .source_and_aux else .none,
            .quit_after_terminal = quit_after_terminal,
        };
    }

    pub fn finishFetch(self: Controller, allocator: std.mem.Allocator, finished: app_actions.FetchFinished) Outcome {
        var result = finished;
        defer result.deinit(allocator);
        const terminal = self.acceptTerminal(allocator, result.pending, result.repo_root) orelse return .{};
        const quit_after_terminal = self.finishRemoteControl(result.pending);
        if (!self.remoteRequestMatches(result.identity) or
            result.identity.operation_generation != result.pending.generation)
            return .{ .quit_after_terminal = quit_after_terminal };
        const active_matches = terminal.target == .current_changes;
        switch (result.result.outcome) {
            .ok => if (active_matches) {
                self.setRemoteStatus(result.result.warnings, "fetched: {s}", .{result.remote});
            } else {
                self.setRemoteStatus(result.result.warnings, "fetched: {s}", .{result.repo_root});
            },
            .failed => |failure| self.setRemoteFailureStatus(result.result.warnings, .fetch, failure),
        }
        return .{
            .reload = if (active_matches) .source_and_aux else .none,
            .quit_after_terminal = quit_after_terminal,
        };
    }

    pub fn finishSwitchBranch(self: Controller, allocator: std.mem.Allocator, finished: app_actions.SwitchBranchFinished) Outcome {
        var result = finished;
        defer result.deinit(allocator);
        const terminal = self.acceptTerminal(allocator, result.pending, result.repo_root) orelse return .{};
        const active_matches = terminal.target == .current_changes;
        switch (result.result) {
            .ok => {
                const applied = self.operations.applyAcceptedOutcome(allocator, .{ .switch_branch = .{ .repo_root = result.repo_root } }, active_matches);
                if (active_matches) {
                    self.setStatus("switched branch: {s} -> {s}", .{ result.old_branch, result.new_branch });
                    if (applied.local_effect_failure != null) {
                        self.setStatus("switched branch: {s} -> {s}; could not clear reviewed marks", .{ result.old_branch, result.new_branch });
                    }
                } else {
                    self.setStatus("switched branch: {s}", .{result.repo_root});
                }
                return .{ .reload = applied.reload };
            },
            .failed, .failed_static => {
                _ = self.setActionFailureStatus("branch switch", result.result);
                return .{ .reload = if (active_matches) .source_and_aux else .none };
            },
        }
    }

    pub fn finishBranchListLoad(self: Controller, allocator: std.mem.Allocator, finished: BranchListLoadFinished) !void {
        var result = finished;
        defer result.deinit(allocator);
        if (result.repo_epoch != self.repo.epoch()) return;
        switch (app_load_state.acceptBranchListResult(
            &self.state.branch_switch_load_pending,
            self.state.branch_switch.hasState(),
            self.state.branch_switch.generation,
            self.state.branch_switch.repo_root,
            result.generation,
            result.repo_root,
        )) {
            .accepted => {},
            .no_pending,
            .stale_pending_generation,
            .missing_state,
            .stale_state_generation,
            .repo_mismatch,
            => return,
        }
        const origin: effect_origin.Origin = .{ .page = .{
            .page_id = result.origin,
            .repo_epoch = result.repo_epoch,
            .activation_id = result.activation_id,
        } };
        const live = effect_origin.classify(origin, self.effect_snapshot) != .stale;
        switch (result.result) {
            .loaded => |list| {
                branch_commit_time.sortBranches(list.branches);
                const branches = try copyBranchSwitchItems(allocator, list.branches);
                errdefer deinitBranchSwitchItems(allocator, branches);
                deinitBranchSwitchItems(allocator, self.state.branch_switch.branches);
                self.state.branch_switch.branches = branches;
                self.state.branch_switch.loading = false;
                self.state.branch_switch.selected_index = branchSwitchInitialSelection(branches);
            },
            .failed => |message| {
                if (live) self.setStatus("branch list load failed: {s}", .{git_ops.trimGitOutput(message)});
                self.clearBranchSwitch(allocator);
            },
            .failed_static => |message| {
                if (live) self.setStatus("branch list load failed: {s}", .{message});
                self.clearBranchSwitch(allocator);
            },
            .empty => {
                if (live) self.setStatus("branch list load failed", .{});
                self.clearBranchSwitch(allocator);
            },
        }
        if (self.active_page != result.origin) self.redraw.requestSkip();
    }

    pub fn finishPushInspection(self: Controller, ctx: *chasen.Ctx(app_message.Msg), finished: app_push_retry.Finished) !void {
        var result = finished;
        defer result.deinit(ctx.allocator());
        const inspecting = switch (self.state.push_retry.state) {
            .inspecting => |inspecting| inspecting,
            else => return,
        };
        if (!inspecting.accepts(result)) return;
        self.state.push_retry.state = .idle;
        if (!self.remoteRequestMatches(result.identity)) return;
        const origin: effect_origin.Origin = .{ .page = result.origin };
        if (effect_origin.classify(origin, self.effect_snapshot) == .stale) {
            self.clearPushErrorPresentation(ctx.allocator());
            return;
        }
        switch (result.outcome) {
            .ready => try self.startInteractivePushAfterInspection(
                ctx,
                result.identity,
                result.origin,
                result.takeRoot(),
                result.target.take(),
                result.warnings,
            ),
            .branch_changed => {
                self.restorePushRetryTarget(ctx.allocator(), result.target.take());
                self.setForegroundStatus(result.warnings, "push retry unavailable: branch changed; reload and try again", .{});
            },
            .oid_changed => {
                self.restorePushRetryTarget(ctx.allocator(), result.target.take());
                self.setForegroundStatus(result.warnings, "push retry unavailable: commit changed; reload and try again", .{});
            },
            .failed => |failure| {
                self.restorePushRetryTarget(ctx.allocator(), result.target.take());
                self.setRemoteFailureStatus(result.warnings, .push, failure);
            },
        }
        if (self.active_page != result.origin.page_id) self.redraw.requestSkip();
    }

    pub fn finishPushForeground(self: Controller, ctx: *chasen.Ctx(app_message.Msg), result: chasen.ForegroundCommandResult) !Outcome {
        const allocator = ctx.allocator();
        var foreground = switch (self.state.push_retry.state) {
            .foreground => |foreground| foreground,
            else => return .{},
        };
        if (foreground.request_id.id != result.request_id.id) return .{};
        self.state.push_retry.state = .idle;

        const origin: effect_origin.Origin = .{ .page = foreground.origin };
        const liveness = effect_origin.classify(origin, self.effect_snapshot);
        const set_upstream_succeeded = foreground.target.mode == .set_upstream and switch (result.outcome) {
            .exited => |code| code == 0,
            else => false,
        };
        if (set_upstream_succeeded) {
            if (!self.lifecycle.view().isAccepted(foreground.pending)) {
                foreground.deinit(allocator);
                return .{};
            }
            if (!self.remoteRequestMatches(foreground.identity) or liveness == .stale) {
                const outcome = self.finishUpstreamPartial(
                    allocator,
                    foreground.pending,
                    foreground.target.repo_root,
                    foreground.identity,
                    foreground.origin,
                    foreground.warnings,
                );
                foreground.deinit(allocator);
                return outcome;
            }

            var environment: ?git_remote.OwnedRemoteEnvironment = git_remote.buildRemoteEnvironment(
                allocator,
                self.env_map,
                .local_finalizer,
            ) catch {
                const outcome = self.finishUpstreamPartial(
                    allocator,
                    foreground.pending,
                    foreground.target.repo_root,
                    foreground.identity,
                    foreground.origin,
                    foreground.warnings,
                );
                foreground.deinit(allocator);
                return outcome;
            };
            defer if (environment) |*owned| owned.deinit();
            environment.?.warnings.merge(foreground.warnings);

            var root: ?root_capability.RootCapability = foreground.root;
            defer if (root) |*owned| owned.deinit();
            var target = foreground.target.take();
            defer target.deinit(allocator);
            const metadata: app_push_retry.Finalizing = .{
                .pending = foreground.pending,
                .identity = foreground.identity,
                .origin = foreground.origin,
            };
            app_push_retry.startFinalization(
                app_message.Msg,
                ctx,
                metadata,
                &root,
                &environment,
                &target,
                foreground.warnings,
            ) catch {
                return self.finishUpstreamPartial(
                    allocator,
                    foreground.pending,
                    target.repo_root,
                    foreground.identity,
                    foreground.origin,
                    foreground.warnings,
                );
            };
            self.state.push_retry.state = .{ .finalizing = metadata };
            self.setStatus("finalizing upstream...", .{});
            return .{};
        }

        defer foreground.deinit(allocator);
        const terminal = self.acceptTerminal(allocator, foreground.pending, foreground.target.repo_root) orelse return .{};
        if (!self.remoteRequestMatches(foreground.identity)) return .{};
        const active_matches = terminal.target == .current_changes;
        if (liveness == .stale) {
            self.redraw.requestSkip();
            return .{};
        }
        switch (result.outcome) {
            .exited => |code| if (code == 0) {
                if (active_matches) self.setForegroundStatus(foreground.warnings, "pushed interactively: {s} -> {s}/{s}", .{ foreground.target.branch, foreground.target.remote, foreground.target.remote_branch }) else self.setForegroundStatus(foreground.warnings, "pushed interactively: {s}", .{foreground.target.repo_root});
            } else if (active_matches) self.setForegroundStatus(foreground.warnings, "interactive push exited: {d}", .{code}) else self.setForegroundStatus(foreground.warnings, "interactive push exited for {s}: {d}", .{ foreground.target.repo_root, code }),
            .signaled => |signal| if (active_matches) self.setForegroundStatus(foreground.warnings, "interactive push signal: {d}", .{signal}) else self.setForegroundStatus(foreground.warnings, "interactive push signal for {s}: {d}", .{ foreground.target.repo_root, signal }),
            .spawn_failed => |err| if (active_matches) self.setForegroundStatus(foreground.warnings, "interactive push spawn failed: {s}", .{err}) else self.setForegroundStatus(foreground.warnings, "interactive push spawn failed for {s}: {s}", .{ foreground.target.repo_root, err }),
            .wait_failed => |err| if (active_matches) self.setForegroundStatus(foreground.warnings, "interactive push wait failed: {s}", .{err}) else self.setForegroundStatus(foreground.warnings, "interactive push wait failed for {s}: {s}", .{ foreground.target.repo_root, err }),
        }
        if (liveness == .live_inactive) {
            self.redraw.requestSkip();
            return .{};
        }
        return .{ .reload = if (active_matches) .source_and_aux else .none };
    }

    pub fn finishPushUpstreamFinalize(self: Controller, allocator: std.mem.Allocator, result: app_push_retry.FinalizeFinished) Outcome {
        const finalizing = switch (self.state.push_retry.state) {
            .finalizing => |finalizing| finalizing,
            else => return .{},
        };
        if (!finalizing.accepts(result)) return .{};
        self.state.push_retry.state = .idle;
        const request_matches = self.remoteRequestMatches(result.identity);
        const terminal = self.acceptTerminal(
            allocator,
            finalizing.pending,
            if (request_matches) self.current_changes_root orelse "" else "",
        ) orelse return .{};
        const quit_after_terminal = self.takeDeferredQuit();
        if (!request_matches) {
            self.redraw.requestSkip();
            return .{ .quit_after_terminal = quit_after_terminal };
        }
        const origin: effect_origin.Origin = .{ .page = finalizing.origin };
        const liveness = effect_origin.classify(origin, self.effect_snapshot);
        if (liveness == .stale) {
            self.redraw.requestSkip();
            return .{ .quit_after_terminal = quit_after_terminal };
        }
        switch (result.outcome) {
            .configured, .already_configured => self.setRemoteStatus(
                result.warnings,
                "push completed; local upstream configured",
                .{},
            ),
            else => self.setRemoteStatus(
                result.warnings,
                "push succeeded; local upstream was not configured; repository reload required",
                .{},
            ),
        }
        if (liveness == .live_inactive) self.redraw.requestSkip();
        return .{
            .reload = if (terminal.target == .current_changes) .source_and_aux else .none,
            .quit_after_terminal = quit_after_terminal,
        };
    }

    fn startPushInspection(self: Controller, ctx: *chasen.Ctx(app_message.Msg), unavailable_message: []const u8) !void {
        if (self.state.push_retry.state == .inspecting) return self.rejectVoid("push retry inspection already running");
        const available_target = self.state.push_retry.state.availableTarget() orelse
            return self.rejectVoid(unavailable_message);
        const repository_identity: remote_request.RepositoryIdentity = .{
            .repo_epoch = available_target.repo_epoch,
            .root_identity = available_target.root_identity,
        };
        if (!self.repositoryMatches(repository_identity))
            return self.rejectVoid("push retry unavailable: repository authority changed");
        const capability = self.repo.activeCapability() orelse
            return self.rejectVoid("push retry unavailable: repository authority changed");
        var root: ?root_capability.RootCapability = capability.duplicate() catch {
            return self.rejectVoid("push retry unavailable: repository authority could not be retained");
        };
        defer if (root) |*owned| owned.deinit();
        var environment: ?git_remote.OwnedRemoteEnvironment = try git_remote.buildRemoteEnvironment(
            ctx.allocator(),
            self.env_map,
            .inspection,
        );
        defer if (environment) |*owned| owned.deinit();
        var started = self.state.push_retry.beginInspection(self.changes_origin) orelse return self.rejectVoid(unavailable_message);
        app_push_retry.startInspection(app_message.Msg, ctx, started.metadata, &root, &environment, &started.target) catch |err| {
            self.restorePushRetryTarget(ctx.allocator(), started.target.take());
            self.setStatus("could not start push retry inspection", .{});
            return err;
        };
        self.setStatus("checking push retry target...", .{});
    }

    fn startInteractivePushAfterInspection(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        identity: remote_request.RemoteRequestIdentity,
        origin: effect_origin.PageOrigin,
        owned_root: root_capability.RootCapability,
        owned_target: app_state.PushRetryTarget,
        inspection_warnings: git_remote.RemoteWarningSet,
    ) !void {
        var root: ?root_capability.RootCapability = owned_root;
        defer if (root) |*owned| owned.deinit();
        var target = owned_target;
        errdefer target.deinit(ctx.allocator());
        if (self.lifecycle.view().hasPending()) {
            self.restorePushRetryTarget(ctx.allocator(), target.take());
            self.setForegroundStatus(inspection_warnings, "another git action is running", .{});
            return;
        }
        var prepared_push = git_remote.prepareForegroundPush(
            ctx.allocator(),
            self.env_map,
            .{
                .mode = target.mode,
                .branch = target.branch,
                .remote = target.remote,
                .remote_branch = target.remote_branch,
                .oid = target.oid,
            },
            inspection_warnings,
        ) catch {
            self.restorePushRetryTarget(ctx.allocator(), target.take());
            self.setForegroundStatus(inspection_warnings, "interactive push could not be queued", .{});
            return;
        };
        defer prepared_push.deinit(ctx.allocator());
        const prepared = self.lifecycle.prepare(.push);
        const request_id = ctx.terminal().runForegroundCommand(.{
            .argv = &prepared_push.argv,
            .cwd = .{ .dir = root.?.dir() },
            .environment = .{ .replace = &prepared_push.environment.map },
            .finished = app_message.Msg.pushForegroundFinished,
        }) catch |err| {
            self.lifecycle.rejectSpawn(prepared);
            self.restorePushRetryTarget(ctx.allocator(), target.take());
            switch (err) {
                error.ForegroundCommandLimitExceeded => self.setForegroundStatus(prepared_push.environment.warnings, "interactive push already queued", .{}),
                error.ForegroundCommandEmptyArgv => self.setForegroundStatus(prepared_push.environment.warnings, "interactive push command is empty", .{}),
                error.ForegroundCommandCwdUnsupported => self.setForegroundStatus(prepared_push.environment.warnings, "interactive push unavailable on this platform", .{}),
                error.ForegroundCommandInvalidCwd => self.setForegroundStatus(prepared_push.environment.warnings, "interactive push repository authority is invalid", .{}),
                error.ForegroundCommandProcessFdQuotaExceeded,
                error.ForegroundCommandSystemFdQuotaExceeded,
                error.ForegroundCommandDuplicateCwdFailed,
                => self.setForegroundStatus(prepared_push.environment.warnings, "interactive push could not retain repository authority", .{}),
                error.OutOfMemory => self.setForegroundStatus(prepared_push.environment.warnings, "interactive push could not be queued", .{}),
            }
            return;
        };
        const accepted = self.lifecycle.acceptSpawn(ctx.allocator(), prepared);
        self.state.push_retry.state = .{ .foreground = .{
            .request_id = request_id,
            .pending = accepted.pending,
            .identity = identity,
            .origin = origin,
            .root = root.?,
            .target = target.take(),
            .warnings = prepared_push.environment.warnings,
        } };
        root = null;
        const foreground = &self.state.push_retry.state.foreground;
        self.clearPushErrorPresentation(ctx.allocator());
        self.setStatus("running interactive push: {s} -> {s}/{s}", .{ foreground.target.branch, foreground.target.remote, foreground.target.remote_branch });
    }

    fn setPushErrorWithRetry(self: Controller, allocator: std.mem.Allocator, message: []const u8, retry_target: ?app_state.PushRetryTarget) !void {
        self.clearPushError(allocator);
        self.state.push_error_message = try allocator.dupe(u8, message);
        if (retry_target) |target| self.state.push_retry.state = .{ .available = .{ .target = target } };
        self.operations.navigation.clearDiffSelection();
        self.overlay.openPushError();
    }

    fn clearPushErrorPresentation(self: Controller, allocator: std.mem.Allocator) void {
        if (self.state.push_error_message) |message| allocator.free(message);
        self.state.push_error_message = null;
        if (self.overlay.isPushError()) self.overlay.close();
    }

    fn restorePushRetryTarget(self: Controller, allocator: std.mem.Allocator, target: app_state.PushRetryTarget) void {
        self.state.push_retry.restoreAvailable(allocator, target);
        self.operations.navigation.clearDiffSelection();
        self.overlay.openPushError();
    }

    fn finishUpstreamPartial(
        self: Controller,
        allocator: std.mem.Allocator,
        pending: app_actions.PendingAction,
        repo_root: []const u8,
        identity: remote_request.RemoteRequestIdentity,
        origin_page: effect_origin.PageOrigin,
        warnings: git_remote.RemoteWarningSet,
    ) Outcome {
        const terminal = self.acceptTerminal(allocator, pending, repo_root) orelse return .{};
        const quit_after_terminal = self.takeDeferredQuit();
        const origin: effect_origin.Origin = .{ .page = origin_page };
        const liveness = effect_origin.classify(origin, self.effect_snapshot);
        if (self.remoteRequestMatches(identity) and liveness != .stale) {
            self.setRemoteStatus(warnings, "push succeeded; local upstream was not configured; repository reload required", .{});
        }
        if (liveness != .live_active) self.redraw.requestSkip();
        return .{
            .reload = if (liveness != .stale and terminal.target == .current_changes and self.remoteRequestMatches(identity)) .source_and_aux else .none,
            .quit_after_terminal = quit_after_terminal,
        };
    }

    fn currentRepositoryIdentity(self: Controller) ?remote_request.RepositoryIdentity {
        const identity = self.repo.activeIdentity() orelse return null;
        const capability = self.repo.activeCapability() orelse return null;
        if (!capability.identity.eql(identity)) return null;
        return .{
            .repo_epoch = self.repo.epoch(),
            .root_identity = identity,
        };
    }

    fn retainBackgroundRoot(self: Controller) !root_capability.RootCapability {
        const identity = self.currentRepositoryIdentity() orelse return error.RepositoryAuthorityChanged;
        const capability = self.repo.activeCapability() orelse return error.RepositoryAuthorityChanged;
        const duplicate = try capability.duplicate();
        if (!duplicate.identity.eql(identity.root_identity)) {
            var invalid = duplicate;
            invalid.deinit();
            return error.RepositoryAuthorityChanged;
        }
        return duplicate;
    }

    fn beginRemoteControl(self: Controller, pending: app_actions.PendingAction) void {
        std.debug.assert(isBackgroundRemoteKind(pending.kind));
        self.state.canceling_generation = null;
        self.state.quit_after_remote_terminal = false;
        self.state.action_control.begin(pending.generation);
    }

    fn finishRemoteControl(self: Controller, pending: app_actions.PendingAction) bool {
        if (!self.state.action_control.finish(pending.generation)) return false;
        self.state.canceling_generation = null;
        return self.takeDeferredQuit();
    }

    fn takeDeferredQuit(self: Controller) bool {
        const quit_after_terminal = self.state.quit_after_remote_terminal;
        self.state.quit_after_remote_terminal = false;
        return quit_after_terminal;
    }

    fn repositoryMatches(self: Controller, expected: remote_request.RepositoryIdentity) bool {
        const current = self.currentRepositoryIdentity() orelse return false;
        return current.eql(expected);
    }

    fn remoteRequestMatches(self: Controller, expected: remote_request.RemoteRequestIdentity) bool {
        return self.repositoryMatches(expected.repository());
    }

    fn acceptTerminal(self: Controller, allocator: std.mem.Allocator, pending: app_actions.PendingAction, repo_root: []const u8) ?action_lifecycle.AcceptedTerminal {
        return switch (self.lifecycle.finishExact(allocator, pending, repo_root, self.current_changes_root)) {
            .rejected => null,
            .accepted => |accepted| accepted,
        };
    }

    fn setActionFailureStatus(self: Controller, comptime prefix: []const u8, result: app_actions.FileActionTaskResult) bool {
        switch (result) {
            .ok => return false,
            .failed => |message| self.setStatus(prefix ++ " failed: {s}", .{git_ops.trimGitOutput(message)}),
            .failed_static => |message| self.setStatus(prefix ++ " failed: {s}", .{message}),
        }
        return true;
    }

    fn reject(self: Controller, message: []const u8) Outcome {
        self.setStatus("{s}", .{message});
        return .{};
    }

    fn rejectVoid(self: Controller, message: []const u8) void {
        self.setStatus("{s}", .{message});
    }

    fn setStatus(self: Controller, comptime fmt: []const u8, args: anytype) void {
        self.status.set(fmt, args);
    }

    fn setRemoteStatus(
        self: Controller,
        warnings: git_remote.RemoteWarningSet,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        const warning = remoteWarningMessage(warnings) orelse {
            self.status.set(fmt, args);
            return;
        };
        var buffer: [112]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, fmt, args) catch "remote operation completed";
        self.status.set("{s}; {s}", .{ warning, message });
    }

    fn setRemoteFailureStatus(
        self: Controller,
        warnings: git_remote.RemoteWarningSet,
        kind: RemotePresentationKind,
        failure: git_remote.RemoteFailure,
    ) void {
        if (!remoteOutcomeUnknown(failure)) {
            self.setRemoteStatus(warnings, "{s} failed: {s}", .{ @tagName(kind), remoteFailureMessage(kind, failure) });
            return;
        }
        const warning = remoteWarningMessage(warnings) orelse {
            self.status.set("{s} failed: {s}", .{ @tagName(kind), remoteFailureMessage(kind, failure) });
            return;
        };
        self.status.set("{s} failed: {s}; {s}", .{ @tagName(kind), remoteFailureMessage(kind, failure), warning });
    }

    fn setForegroundStatus(
        self: Controller,
        warnings: git_remote.RemoteWarningSet,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        const warning = remoteWarningMessage(warnings) orelse {
            self.status.set(fmt, args);
            return;
        };
        var buffer: [112]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, fmt, args) catch "interactive push completed";
        self.status.set("{s}; {s}", .{ warning, message });
    }
};

fn isBackgroundRemoteKind(kind: app_actions.ActionKind) bool {
    return switch (kind) {
        .push, .pull, .fetch => true,
        else => false,
    };
}

fn remoteOutcomeUnknown(failure: git_remote.RemoteFailure) bool {
    return failure == .canceled_outcome_unknown or failure == .timed_out_outcome_unknown;
}

const RemotePresentationKind = enum { push, pull, fetch };

fn remoteFailureMessage(kind: RemotePresentationKind, failure: git_remote.RemoteFailure) []const u8 {
    return switch (failure) {
        .authentication_required => if (kind == .push)
            "authentication is required; press i to continue in the native terminal"
        else
            "authentication is required; configure a credential helper or retry in an external terminal",
        .ssh_public_key => "SSH public-key authentication failed; check ssh-agent and repository access",
        .http_userinfo_rejected => "remote URL contains embedded user information; replace it with a credential-free URL",
        .canceled_outcome_unknown => "remote operation canceled; outcome is unknown; repository reload required",
        .timed_out_outcome_unknown => "remote operation timed out; outcome is unknown; repository reload required",
        .spawn_failed => "remote command could not be started",
        .failed => if (kind == .push)
            "remote operation failed; press i to retry in the native terminal"
        else
            "remote operation failed; retry in an external terminal",
    };
}

fn remoteWarningMessage(warnings: git_remote.RemoteWarningSet) ?[]const u8 {
    if (warnings.git_plaintext_store) return "warning: credential.helper may store credentials in plaintext";
    if (warnings.gcm_plaintext_store) return "warning: Git Credential Manager plaintext storage is configured";
    if (warnings.potential_plaintext_store) return "warning: scoped credential helpers may store credentials in plaintext";
    if (warnings.helper_policy_unknown) return "warning: credential helper storage policy is unknown";
    if (warnings.proxy_credentials_omitted) return "warning: credential-bearing proxy was omitted";
    return null;
}

const ssh_public_key_push_details =
    \\SSH public-key authentication failed.
    \\
    \\Check in your terminal:
    \\
    \\1. Check the keys loaded in ssh-agent:
    \\     ssh-add -l
    \\   If ssh-agent cannot be reached, check its setup
    \\   in the shell used to start GitFrame.
    \\
    \\2. If the key you use is not loaded, add it:
    \\     ssh-add <path-to-your-key>
    \\     Example: ssh-add ~/.ssh/id_ed25519
    \\   Replace the example path with your actual key path
    \\   (for example, ~/.ssh/id_rsa).
    \\
    \\3. If your key is already loaded, check:
    \\   - Public-key registration on the Git hosting service
    \\   - Your account's push permission
    \\   - The host/key settings in ~/.ssh/config
;

fn remoteFailurePresentationAlloc(
    allocator: std.mem.Allocator,
    kind: RemotePresentationKind,
    failure: git_remote.RemoteFailure,
    warnings: git_remote.RemoteWarningSet,
) ![]u8 {
    const message = if (kind == .push and failure == .ssh_public_key)
        ssh_public_key_push_details
    else
        remoteFailureMessage(kind, failure);
    if (remoteWarningMessage(warnings)) |warning| {
        return std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ message, warning });
    }
    return allocator.dupe(u8, message);
}

fn copyBranchSwitchItems(allocator: std.mem.Allocator, source: []const git_refs.BranchListItem) ![]app_state.BranchSwitchItem {
    const items = try allocator.alloc(app_state.BranchSwitchItem, source.len);
    errdefer allocator.free(items);
    var initialized: usize = 0;
    errdefer for (items[0..initialized]) |*item| item.deinit(allocator);
    for (source, 0..) |branch, index| {
        items[index] = .{
            .name = try allocator.dupe(u8, branch.name),
            .oid = &.{},
            .current = branch.current,
            .tip_committer_unix = branch.tip_committer_unix,
        };
        initialized += 1;
        items[index].oid = try allocator.dupe(u8, branch.oid);
    }
    return items;
}

fn deinitBranchSwitchItems(allocator: std.mem.Allocator, items: []app_state.BranchSwitchItem) void {
    for (items) |*item| item.deinit(allocator);
    if (items.len > 0) allocator.free(items);
}

fn branchSwitchInitialSelection(branches: []const app_state.BranchSwitchItem) usize {
    for (branches, 0..) |branch, index| if (!branch.current) return index;
    return 0;
}

fn wrapIndex(current: usize, len: usize, delta: isize) usize {
    if (len == 0) return 0;
    const signed_len: isize = @intCast(len);
    const signed_current: isize = @intCast(current % len);
    return @intCast(@mod(signed_current + delta, signed_len));
}

fn pushRetryTargetFromFinished(allocator: std.mem.Allocator, finished: app_actions.PushFinished) !app_state.PushRetryTarget {
    var target: app_state.PushRetryTarget = .{
        .repo_epoch = finished.identity.repo_epoch,
        .root_identity = finished.identity.root_identity,
        .mode = finished.mode,
        .repo_root = try allocator.dupe(u8, finished.repo_root),
        .branch = &.{},
        .remote = &.{},
        .remote_branch = &.{},
        .oid = &.{},
    };
    errdefer target.deinit(allocator);
    target.branch = try allocator.dupe(u8, finished.branch);
    target.remote = try allocator.dupe(u8, finished.remote);
    target.remote_branch = try allocator.dupe(u8, finished.remote_branch);
    target.oid = try allocator.dupe(u8, finished.oid);
    return target;
}

pub const testing = if (builtin.is_test) struct {
    pub fn setPushErrorWithRetry(
        controller: Controller,
        allocator: std.mem.Allocator,
        message: []const u8,
        retry_target: ?app_state.PushRetryTarget,
    ) !void {
        try controller.setPushErrorWithRetry(allocator, message, retry_target);
    }

    pub fn clearForeground(state: *State, allocator: std.mem.Allocator) void {
        if (state.push_retry.state == .foreground) state.push_retry.state.deinit(allocator);
    }
} else struct {};
