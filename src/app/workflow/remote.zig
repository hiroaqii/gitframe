//! Remote Git operations and shared branch-switch ownership.
//!
//! This controller owns push, pull, fetch, branch-switch, retry inspection,
//! interactive-push, and upstream-finalization state. Changes supplies synchronous target
//! and outcome ports; branch switching captures its own caller and snapshot.
//! The root shell consumes typed reload intent. The module
//! never imports the root App, local workflow, read coordinator, or shell
//! effects.

const std = @import("std");
const builtin = @import("builtin");
const chasen = @import("chasen");

const app_actions = @import("../actions.zig");
const diff_source = @import("../../diff/source.zig");
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
const git_ref = @import("../../git/ref.zig");
const root_capability = @import("../../repo/root_capability.zig");
const worktree_switch = @import("../worktree_switch.zig");

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

    pub fn remoteErrorOperation(self: View) ?app_state.GitErrorOperation {
        return self.state.remote_error_operation;
    }

    pub fn remoteErrorMessage(self: View) ?[]const u8 {
        return self.state.remote_error_message;
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

pub const BranchReload = union(enum) {
    changes: changes_action_fence.ReloadIntent,
    repository,
    history: bool,
    compare,
};

pub const Outcome = struct {
    branch_reload: ?BranchReload = null,
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
    branch_origin: ?effect_origin.PageOrigin,
    repository_status: *app_state.StatusMessage,
    history_status: *app_state.StatusMessage,
    compare_status: *app_state.StatusMessage,
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
        self.clearRemoteError(allocator);

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
        };
        const repository_identity = self.currentRepositoryIdentity() orelse
            return self.reject("pull unavailable: repository authority changed");
        const active_root = self.repo.activeRoot() orelse
            return self.reject("pull unavailable: no repository");
        if (!std.mem.eql(u8, active_root, target.repo_root))
            return self.reject("pull unavailable: repository authority changed");

        self.cancelPushConfirmation(allocator);
        self.cancelPullConfirmation(allocator);
        self.clearRemoteError(allocator);
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
            .upstream_ref = owned.upstream_ref,
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
        const origin = self.branch_origin orelse return .{};
        const status = self.branchStatus(origin.page_id);
        if (self.lifecycle.view().hasPending()) {
            status.set("another git action is running", .{});
            return .{};
        }
        if (origin.page_id == .changes and !diff_source.sourceAllowsStageProjection(self.operations.view().source)) {
            status.set("branch switch unavailable for this source", .{});
            return .{};
        }
        const repo_root = self.repo.activeRoot() orelse {
            status.set("branch switch unavailable: no repository", .{});
            return .{};
        };
        const identity = self.currentRepositoryIdentity() orelse {
            status.set("branch switch unavailable: repository authority changed", .{});
            return .{};
        };
        if (effect_origin.classify(.{ .page = origin }, self.effect_snapshot) != .live_active) return .{};

        self.cancelPushConfirmation(ctx.allocator());
        self.cancelPullConfirmation(ctx.allocator());
        self.clearRemoteError(ctx.allocator());
        self.clearBranchSwitch(ctx.allocator());
        errdefer {
            self.clearBranchSwitch(ctx.allocator());
            status.set("could not start branch list task", .{});
        }
        self.state.branch_switch_load_generation +%= 1;
        const generation = self.state.branch_switch_load_generation;
        self.state.branch_switch = .{
            .owner = .{ .origin = origin, .root_identity = identity.root_identity },
            .repo_root = try ctx.allocator().dupe(u8, repo_root),
            .generation = generation,
            .loading = true,
        };
        self.state.branch_switch_load_pending = generation;
        if (origin.page_id == .changes) self.operations.navigation.clearDiffSelection();
        self.overlay.openSwitchBranch(origin.page_id);

        const capability = self.repo.activeCapability() orelse return error.RepositoryReadAuthorityClosed;
        var root = try capability.duplicate();
        var root_consumed = false;
        errdefer if (!root_consumed) root.deinit();
        var environment = try git_command.LocalGitEnvironment.initFromParent(ctx.allocator(), self.env_map);
        var environment_consumed = false;
        errdefer if (!environment_consumed) environment.deinit();
        const owned_repo_root = try ctx.allocator().dupe(u8, repo_root);
        var repo_root_consumed = false;
        errdefer if (!repo_root_consumed) ctx.allocator().free(owned_repo_root);
        const task = try ctx.allocator().create(BranchListLoadTask);
        task.* = .{
            .origin = origin.page_id,
            .repo_epoch = origin.repo_epoch,
            .activation_id = origin.activation_id,
            .repo_root = owned_repo_root,
            .root = root,
            .environment = environment,
            .generation = generation,
        };
        root_consumed = true;
        environment_consumed = true;
        repo_root_consumed = true;
        errdefer task.destroy(ctx.allocator());
        _ = try ctx.task().spawnOwned(task, .{ .run = BranchListLoadTask.run, .failed = BranchListLoadTask.failed, .cleanup = BranchListLoadTask.destroy });
        return .{ .cancel_local_confirmations = true };
    }

    pub fn moveBranchSwitchSelection(self: Controller, delta: isize) void {
        const branch_switch = &self.state.branch_switch;
        if (!branch_switch.hasState() or branch_switch.loading or branch_switch.worktree_pending or branch_switch.visibleCount() == 0) return;
        branch_switch.selected_index = wrapIndex(branch_switch.selected_index, branch_switch.visibleCount(), delta);
    }

    pub fn editBranchSwitchQuery(self: Controller, allocator: std.mem.Allocator, edit: app_state.BranchSwitchState.QueryEdit) void {
        self.state.branch_switch.editQuery(allocator, edit) catch {
            if (self.state.branch_switch.owner) |owner|
                self.branchStatus(owner.origin.page_id).set("could not update branch filter", .{});
        };
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
        const owner = branch_switch.owner orelse return;
        const status = self.branchStatus(owner.origin.page_id);
        if (!self.branchOwnerMatches(owner) or self.repo.activeRoot() == null or
            !std.mem.eql(u8, self.repo.activeRoot().?, branch_switch.repo_root))
        {
            if (effect_origin.classify(.{ .page = owner.origin }, self.effect_snapshot) != .stale)
                status.set("branch switch unavailable: repository authority changed", .{});
            self.clearBranchSwitch(ctx.allocator());
            return;
        }
        if (branch_switch.loading) return status.set("branch list is still loading", .{});
        if (branch_switch.worktree_pending) return status.set("checking target worktree...", .{});
        if (branch_switch.branches.len == 0) return status.set("branch switch unavailable: no local branches", .{});
        if (self.lifecycle.view().hasPending()) return status.set("another git action is running", .{});

        const selected = branch_switch.selectedItem() orelse return;
        const local_name = git_ref.localBranchName(selected.full_ref) orelse return status.set("unsupported branch ref", .{});
        if (std.mem.startsWith(u8, local_name, "-")) return status.set("unsupported branch name", .{});
        if (selected.action(branch_switch.current_branch) == .close) {
            status.set("already on branch: {s}", .{branch_switch.current_branch});
            self.clearBranchSwitch(ctx.allocator());
            return;
        }
        if (selected.action(branch_switch.current_branch) == .open_worktree) {
            errdefer status.set("could not start worktree check", .{});
            const task = try worktree_switch.Task(app_message.Msg).create(
                ctx.allocator(),
                owner,
                branch_switch.generation,
                self.repo.activeCapability().?.*,
                self.env_map,
                local_name,
                selected.worktree_path.?,
            );
            errdefer task.destroy(ctx.allocator());
            _ = try ctx.task().spawnOwned(task, .{
                .run = worktree_switch.Task(app_message.Msg).run,
                .failed = worktree_switch.Task(app_message.Msg).failed,
                .cleanup = worktree_switch.Task(app_message.Msg).destroy,
            });
            branch_switch.worktree_pending = true;
            status.set("checking worktree for {s}...", .{selected.name});
            return;
        }

        // Allocation/preparation/spawn failures retain this valid picker for retry.
        errdefer status.set("could not start branch switch task", .{});
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
        request.target_branch = try ctx.allocator().dupe(u8, local_name);
        request.target_oid = try ctx.allocator().dupe(u8, selected.oid);
        const prepared = self.lifecycle.prepare(.switch_branch);
        errdefer self.lifecycle.rejectSpawn(prepared);
        try app_git_requests.startSwitchBranch(app_message.Msg, ctx, prepared.pending, &request, self.repo.activeCapability().?, self.env_map);
        _ = self.lifecycle.acceptSpawn(ctx.allocator(), prepared);
        self.state.branch_switch_pending = .{ .token = prepared.pending, .owner = owner };
        status.set("switching branch: {s} -> {s}", .{ branch_switch.current_branch, selected.name });
        self.clearBranchSwitch(ctx.allocator());
    }

    pub fn finishWorktreeSwitch(self: Controller, allocator: std.mem.Allocator, finished: worktree_switch.Finished) ?worktree_switch.Validated {
        var result = finished;
        defer result.deinit(allocator);
        const state = &self.state.branch_switch;
        const owner = state.owner orelse return null;
        if (!state.worktree_pending or state.generation != result.generation or
            !owner.origin.eql(result.owner.origin) or !owner.root_identity.eql(result.owner.root_identity)) return null;
        if (!self.branchOwnerMatches(owner)) {
            self.clearBranchSwitch(allocator);
            return null;
        }
        const status = self.branchStatus(owner.origin.page_id);
        self.clearBranchSwitch(allocator);
        switch (result.result) {
            .ready => |ready| {
                result.result = .{ .failed = "" };
                return ready;
            },
            .failed => |message| status.set("Worktree switch failed: {s}", .{message}),
        }
        return null;
    }

    pub fn clearRemoteError(self: Controller, allocator: std.mem.Allocator) void {
        self.clearRemoteErrorPresentation(allocator);
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
            .ok => |success| {
                if (success == .push_tracking_incomplete) {
                    self.setRemoteStatus(result.result.warnings, "push succeeded; local upstream was not configured; repository reload required", .{});
                    return .{
                        .reload = if (active_matches) .source_and_aux else .none,
                        .quit_after_terminal = quit_after_terminal,
                    };
                }
                if (active_matches) {
                    self.setRemoteStatus(result.result.warnings, "pushed: {s} -> {s}/{s}", .{ result.branch, result.remote, result.remote_branch });
                    return .{ .reload = .source_and_aux, .quit_after_terminal = quit_after_terminal };
                }
                self.setRemoteStatus(result.result.warnings, "pushed: {s}", .{result.repo_root});
            },
            .failed => |failure| {
                self.setRemoteFailureStatus(result.result.warnings, .push, failure);
                const retry_allowed = failure != .http_userinfo_rejected and
                    failure != .canceled and failure != .timed_out and !remoteOutcomeUnknown(failure);
                const retry_target = if (retry_allowed) try pushRetryTargetFromFinished(allocator, result) else null;
                errdefer if (retry_target) |owned_target| {
                    var target = owned_target;
                    target.deinit(allocator);
                };
                const presentation = try remoteFailurePresentationAlloc(allocator, .push, failure, result.result.warnings);
                defer allocator.free(presentation);
                try self.setRemoteErrorWithRetry(allocator, .push, presentation, retry_target, .changes);
                return .{
                    .reload = if (active_matches and remoteOutcomeUnknown(failure)) .source_and_aux else .none,
                    .quit_after_terminal = quit_after_terminal,
                };
            },
        }
        return .{ .quit_after_terminal = quit_after_terminal };
    }

    pub fn finishPull(self: Controller, allocator: std.mem.Allocator, finished: app_actions.PullFinished) !Outcome {
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
                .push_tracking_incomplete => unreachable, // Only push produces this terminal.
            },
            .failed => |failure| {
                self.setRemoteFailureStatus(result.result.warnings, .pull, failure);
                if (pullFailureHasDetails(failure)) {
                    const presentation = try remoteFailurePresentationAlloc(allocator, .pull, failure, result.result.warnings);
                    defer allocator.free(presentation);
                    try self.setRemoteErrorWithRetry(allocator, .pull, presentation, null, .changes);
                }
            },
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

    pub fn finishSwitchBranch(self: Controller, allocator: std.mem.Allocator, finished: app_actions.SwitchBranchFinished) !Outcome {
        var result = finished;
        defer result.deinit(allocator);
        const pending = self.state.branch_switch_pending orelse return .{};
        if (pending.token.generation != result.pending.generation or pending.token.kind != result.pending.kind) return .{};
        _ = self.acceptTerminal(allocator, result.pending, result.repo_root) orelse return .{};
        self.state.branch_switch_pending = null;
        const owner = pending.owner;
        const live = self.branchOwnerMatches(owner) and self.repo.activeRoot() != null and
            std.mem.eql(u8, self.repo.activeRoot().?, result.repo_root);
        var changes_reload: changes_action_fence.ReloadIntent = .source_and_aux;
        switch (result.result) {
            .ok => {
                // Repo-local marks belong to the completed checkout even when its
                // page has expired. Only the live Changes caller resets its view.
                const applied = self.operations.applyAcceptedOutcome(allocator, .{ .switch_branch = .{ .repo_root = result.repo_root } }, live and owner.origin.page_id == .changes);
                changes_reload = applied.reload;
                if (live) {
                    const status = self.branchStatus(owner.origin.page_id);
                    status.set("switched branch: {s} -> {s}", .{ result.old_branch, result.new_branch });
                    if (applied.local_effect_failure != null)
                        status.set("switched branch: {s} -> {s}; could not clear reviewed marks", .{ result.old_branch, result.new_branch });
                }
            },
            .failed, .failed_static => |message| {
                if (live) {
                    self.branchStatus(owner.origin.page_id).set("branch switch failed: {s}", .{git_ops.trimGitOutput(message)});
                    // Failure to copy details must not prevent read revalidation.
                    self.setRemoteErrorWithRetry(allocator, .switch_branch, message, null, owner.origin.page_id) catch {};
                }
            },
        }
        if (!live) return .{};
        if (self.active_page != owner.origin.page_id) self.redraw.requestSkip();
        return .{ .branch_reload = switch (owner.origin.page_id) {
            .changes => .{ .changes = changes_reload },
            .repository => .repository,
            .history => .{ .history = result.result == .ok },
            .compare => .compare,
        } };
    }

    pub fn finishBranchListLoad(self: Controller, allocator: std.mem.Allocator, finished: BranchListLoadFinished) !void {
        var result = finished;
        defer result.deinit(allocator);
        const owner = self.state.branch_switch.owner orelse return;
        const origin: effect_origin.PageOrigin = .{
            .page_id = result.origin,
            .repo_epoch = result.repo_epoch,
            .activation_id = result.activation_id,
        };
        // Check the captured owner before consuming pending correlation.
        if (!owner.origin.eql(origin)) return;
        switch (app_load_state.acceptBranchListResult(
            &self.state.branch_switch_load_pending,
            self.state.branch_switch.hasState(),
            self.state.branch_switch.generation,
            self.state.branch_switch.repo_root,
            result.generation,
            result.repo_root,
        )) {
            .accepted => {},
            else => return,
        }
        if (!self.branchOwnerMatches(owner)) {
            self.clearBranchSwitch(allocator);
            return;
        }
        const status = self.branchStatus(origin.page_id);
        errdefer {
            status.set("could not retain branch list", .{});
            self.clearBranchSwitch(allocator);
        }
        switch (result.result) {
            .loaded => |list| {
                // This read owns the current branch snapshot; it does not depend
                // on any Changes activation or file/status read.
                var oid: ?[]const u8 = null;
                if (list.current) |current| for (list.branches) |branch| {
                    const local_name = git_ref.localBranchName(branch.full_ref) orelse continue;
                    if (branch.kind == .local and std.mem.eql(u8, local_name, current)) {
                        oid = branch.oid;
                        break;
                    }
                };
                const target = switch (git_ops.branchSwitchTarget(result.repo_root, .{
                    .head = if (list.current) |current| .{ .branch = current } else .detached,
                    .oid = oid,
                })) {
                    .ready => |target| target,
                    .detached_head => {
                        status.set("branch switch unavailable on detached HEAD", .{});
                        self.clearBranchSwitch(allocator);
                        return;
                    },
                    else => {
                        status.set("branch switch unavailable: branch status is incomplete", .{});
                        self.clearBranchSwitch(allocator);
                        return;
                    },
                };
                const current_branch = try allocator.dupe(u8, target.branch);
                errdefer allocator.free(current_branch);
                const current_oid = try allocator.dupe(u8, target.oid);
                errdefer allocator.free(current_oid);
                branch_commit_time.sortBranches(list.branches);
                const branches = try copyBranchSwitchItems(allocator, list.branches);
                const state = &self.state.branch_switch;
                allocator.free(state.current_branch);
                allocator.free(state.current_oid);
                deinitBranchSwitchItems(allocator, state.branches);
                state.current_branch = current_branch;
                state.current_oid = current_oid;
                state.branches = branches;
                state.loading = false;
                state.selected_index = branchSwitchInitialSelection(branches);
            },
            .failed, .failed_static => |message| {
                status.set("branch list load failed: {s}", .{git_ops.trimGitOutput(message)});
                self.clearBranchSwitch(allocator);
            },
            .empty => {
                status.set("branch list load failed", .{});
                self.clearBranchSwitch(allocator);
            },
        }
        if (self.active_page != result.origin) self.redraw.requestSkip();
    }

    fn branchOwnerMatches(self: Controller, owner: app_state.BranchSwitchOwner) bool {
        return effect_origin.classify(.{ .page = owner.origin }, self.effect_snapshot) != .stale and
            self.repositoryMatches(.{ .repo_epoch = owner.origin.repo_epoch, .root_identity = owner.root_identity });
    }

    pub fn branchStatus(self: Controller, owner_page: page.Id) *app_state.StatusMessage {
        return switch (owner_page) {
            .changes => self.status,
            .repository => self.repository_status,
            .history => self.history_status,
            .compare => self.compare_status,
        };
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
            self.clearRemoteErrorPresentation(ctx.allocator());
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
            .stopped => |signal| if (active_matches) self.setForegroundStatus(foreground.warnings, "interactive push stopped and terminated: {d}", .{signal}) else self.setForegroundStatus(foreground.warnings, "interactive push stopped and terminated for {s}: {d}", .{ foreground.target.repo_root, signal }),
            .failed => |failure| if (active_matches) self.setForegroundStatus(foreground.warnings, "interactive push {s} failed: {s}", .{ @tagName(failure.stage), failure.error_name }) else self.setForegroundStatus(foreground.warnings, "interactive push {s} failed for {s}: {s}", .{ @tagName(failure.stage), foreground.target.repo_root, failure.error_name }),
            .runtime_abandoned => return .{},
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
                error.ForegroundCommandRuntimeStopped => {},
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
        self.clearRemoteErrorPresentation(ctx.allocator());
        self.setStatus("running interactive push: {s} -> {s}/{s}", .{ foreground.target.branch, foreground.target.remote, foreground.target.remote_branch });
    }

    pub fn setRemoteErrorWithRetry(
        self: Controller,
        allocator: std.mem.Allocator,
        operation: app_state.GitErrorOperation,
        message: []const u8,
        retry_target: ?app_state.PushRetryTarget,
        owner_page: page.Id,
    ) !void {
        std.debug.assert(operation == .push or retry_target == null);
        self.clearRemoteError(allocator);
        self.state.remote_error_message = try allocator.dupe(u8, message);
        self.state.remote_error_operation = operation;
        if (retry_target) |target| self.state.push_retry.state = .{ .available = .{ .target = target } };
        if (owner_page == .changes) self.operations.navigation.clearDiffSelection();
        self.overlay.openRemoteError(owner_page);
    }

    fn clearRemoteErrorPresentation(self: Controller, allocator: std.mem.Allocator) void {
        if (self.state.remote_error_message) |message| allocator.free(message);
        self.state.remote_error_operation = null;
        self.state.remote_error_message = null;
        if (self.overlay.isRemoteError()) self.overlay.close();
    }

    fn restorePushRetryTarget(self: Controller, allocator: std.mem.Allocator, target: app_state.PushRetryTarget) void {
        self.state.push_retry.restoreAvailable(allocator, target);
        self.operations.navigation.clearDiffSelection();
        self.overlay.openRemoteError(.changes);
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
    return failure == .outcome_unknown or failure == .canceled_outcome_unknown or failure == .timed_out_outcome_unknown;
}

fn pullFailureHasDetails(failure: git_remote.RemoteFailure) bool {
    return failure == .ssh_public_key or failure == .authentication_required;
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
        .canceled => "remote operation canceled before repository updates",
        .timed_out => "remote operation timed out before repository updates",
        .outcome_unknown => "remote operation outcome is unknown; repository reload required",
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

const ssh_public_key_details =
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
    \\   - Your account's access to the repository
    \\   - The host/key settings in ~/.ssh/config
;

const pull_authentication_required_details =
    \\Authentication is required for pull.
    \\
    \\Configure a credential helper, or retry the pull in an external
    \\terminal where Git can prompt for credentials.
;

fn remoteFailurePresentationAlloc(
    allocator: std.mem.Allocator,
    kind: RemotePresentationKind,
    failure: git_remote.RemoteFailure,
    warnings: git_remote.RemoteWarningSet,
) ![]u8 {
    const message = switch (failure) {
        .ssh_public_key => ssh_public_key_details,
        .authentication_required => if (kind == .pull)
            pull_authentication_required_details
        else
            remoteFailureMessage(kind, failure),
        else => remoteFailureMessage(kind, failure),
    };
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
            .full_ref = &.{},
            .name = try allocator.dupe(u8, branch.name),
            .oid = &.{},
            .current = branch.current,
            .tip_committer_unix = branch.tip_committer_unix,
        };
        initialized += 1;
        items[index].full_ref = try allocator.dupe(u8, branch.full_ref);
        items[index].oid = try allocator.dupe(u8, branch.oid);
        if (branch.worktree_path) |path| items[index].worktree_path = try allocator.dupe(u8, path);
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
    pub fn setRemoteErrorWithRetry(
        controller: Controller,
        allocator: std.mem.Allocator,
        operation: app_state.GitErrorOperation,
        message: []const u8,
        retry_target: ?app_state.PushRetryTarget,
    ) !void {
        try controller.setRemoteErrorWithRetry(allocator, operation, message, retry_target, .changes);
    }

    pub fn clearForeground(state: *State, allocator: std.mem.Allocator) void {
        if (state.push_retry.state == .foreground) state.push_retry.state.deinit(allocator);
    }
} else struct {};
