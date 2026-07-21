//! Git action launch controller.
//!
//! Borrowed targets are duplicated into task-owned payloads. Owned request
//! payloads are consumed on every return path: success transfers ownership to
//! the task, and failure frees the payload before returning.
//!
//! A successful launcher returns its exact `PendingAction` only after
//! `spawnWith` accepts the task. This receipt lets the App distinguish
//! preparation from a concrete launch without inferring success from mutable
//! `ActionState` after the fact. The caller must pass that receipt through the
//! App launch coordinator exactly once before any task completion is admitted.

const std = @import("std");
const chasen = @import("chasen");

const actions = @import("actions.zig");
const git_ops = @import("git_ops.zig");
const app_state = @import("state.zig");

pub fn hasPendingAction(action_state: actions.ActionState) bool {
    return action_state.pending != null;
}

pub fn startStageFile(comptime Msg: type, ctx: *chasen.Ctx(Msg), action_state: *actions.ActionState, target: git_ops.StageTarget) !actions.PendingAction {
    const pending = action_state.begin(.stage_file);
    errdefer _ = action_state.cancelPreparing(pending);

    const Task = actions.StageFileTask(Msg);
    const task = try ctx.allocator().create(Task);
    task.* = .{
        .pending = pending,
        .repo_root = &.{},
        .path = &.{},
        .label = &.{},
        .target_kind = target.kind,
    };
    errdefer destroyFileTask(Task, ctx.allocator(), task);

    task.repo_root = try ctx.allocator().dupe(u8, target.repo_root);
    task.path = try ctx.allocator().dupe(u8, target.path);
    task.label = try ctx.allocator().dupe(u8, if (target.label.len > 0) target.label else target.path);

    try ctx.task().spawnWith(.{ .ctx = task, .run = Task.run, .failed = Task.failed });
    return pending;
}

pub fn startUnstageFile(comptime Msg: type, ctx: *chasen.Ctx(Msg), action_state: *actions.ActionState, target: git_ops.UnstageTarget) !actions.PendingAction {
    const pending = action_state.begin(.unstage_file);
    errdefer _ = action_state.cancelPreparing(pending);

    const Task = actions.UnstageFileTask(Msg);
    const task = try ctx.allocator().create(Task);
    task.* = .{
        .pending = pending,
        .repo_root = &.{},
        .path = &.{},
        .label = &.{},
        .target_kind = target.kind,
    };
    errdefer destroyFileTask(Task, ctx.allocator(), task);

    task.repo_root = try ctx.allocator().dupe(u8, target.repo_root);
    task.path = try ctx.allocator().dupe(u8, target.path);
    task.label = try ctx.allocator().dupe(u8, if (target.label.len > 0) target.label else target.path);

    try ctx.task().spawnWith(.{ .ctx = task, .run = Task.run, .failed = Task.failed });
    return pending;
}

pub fn startStageHunk(comptime Msg: type, ctx: *chasen.Ctx(Msg), action_state: *actions.ActionState, target: *git_ops.HunkStageTarget) !actions.PendingAction {
    defer consumeHunkTarget(ctx.allocator(), target);

    const pending = action_state.begin(.stage_hunk);
    errdefer _ = action_state.cancelPreparing(pending);

    const Task = actions.StageHunkTask(Msg);
    const task = try ctx.allocator().create(Task);
    task.* = .{
        .pending = pending,
        .repo_root = &.{},
        .path = &.{},
        .patch = &.{},
        .hunk_index = target.hunk_index,
        .session_mark_mutation = target.session_mark_mutation,
    };
    errdefer destroyHunkTask(Task, ctx.allocator(), task);

    task.repo_root = try ctx.allocator().dupe(u8, target.repo_root);
    task.path = try ctx.allocator().dupe(u8, target.path);
    task.patch = target.patch;
    target.patch = &.{};

    try ctx.task().spawnWith(.{ .ctx = task, .run = Task.run, .failed = Task.failed });
    return pending;
}

pub fn startUnstageHunk(comptime Msg: type, ctx: *chasen.Ctx(Msg), action_state: *actions.ActionState, target: *git_ops.HunkUnstageTarget) !actions.PendingAction {
    defer consumeHunkTarget(ctx.allocator(), target);

    const pending = action_state.begin(.unstage_hunk);
    errdefer _ = action_state.cancelPreparing(pending);

    const Task = actions.UnstageHunkTask(Msg);
    const task = try ctx.allocator().create(Task);
    task.* = .{
        .pending = pending,
        .repo_root = &.{},
        .path = &.{},
        .patch = &.{},
        .hunk_index = target.hunk_index,
        .session_mark_mutation = target.session_mark_mutation,
        .reload_after_success = target.reload_after_success,
    };
    errdefer destroyHunkTask(Task, ctx.allocator(), task);

    task.repo_root = try ctx.allocator().dupe(u8, target.repo_root);
    task.path = try ctx.allocator().dupe(u8, target.path);
    task.patch = target.patch;
    target.patch = &.{};

    try ctx.task().spawnWith(.{ .ctx = task, .run = Task.run, .failed = Task.failed });
    return pending;
}

pub fn startDiscardFile(comptime Msg: type, ctx: *chasen.Ctx(Msg), action_state: *actions.ActionState, repo_root: []const u8, path: []const u8) !actions.PendingAction {
    const pending = action_state.begin(.discard_file);
    errdefer _ = action_state.cancelPreparing(pending);

    const Task = actions.DiscardFileTask(Msg);
    const task = try ctx.allocator().create(Task);
    task.* = .{
        .pending = pending,
        .repo_root = &.{},
        .path = &.{},
    };
    errdefer destroyFileTask(Task, ctx.allocator(), task);

    task.repo_root = try ctx.allocator().dupe(u8, repo_root);
    task.path = try ctx.allocator().dupe(u8, path);

    try ctx.task().spawnWith(.{ .ctx = task, .run = Task.run, .failed = Task.failed });
    return pending;
}

pub const CommitRequest = struct {
    repo_root: []u8,
    subject: []u8,
    body: ?[]u8 = null,

    pub fn deinit(self: *CommitRequest, allocator: std.mem.Allocator) void {
        if (self.repo_root.len > 0) allocator.free(self.repo_root);
        if (self.subject.len > 0) allocator.free(self.subject);
        if (self.body) |body| allocator.free(body);
        self.* = .{ .repo_root = &.{}, .subject = &.{}, .body = null };
    }
};

pub fn startCommit(comptime Msg: type, ctx: *chasen.Ctx(Msg), action_state: *actions.ActionState, request: *CommitRequest) !actions.PendingAction {
    defer request.deinit(ctx.allocator());

    const pending = action_state.begin(.commit);
    errdefer _ = action_state.cancelPreparing(pending);

    const Task = actions.CommitTask(Msg);
    const task = try ctx.allocator().create(Task);
    task.* = .{
        .pending = pending,
        .repo_root = request.repo_root,
        .subject = request.subject,
        .body = request.body,
    };
    request.* = .{ .repo_root = &.{}, .subject = &.{}, .body = null };
    errdefer destroyCommitTask(Task, ctx.allocator(), task);

    try ctx.task().spawnWith(.{ .ctx = task, .run = Task.run, .failed = Task.failed });
    return pending;
}

pub const CommitMessageAssistRequest = struct {
    repo_root: []u8,
    action_id: []u8,
    argv: [][]u8,
    launch_revision: u64,
    mode: actions.CommitMessageAssistMode,

    pub fn deinit(self: *CommitMessageAssistRequest, allocator: std.mem.Allocator) void {
        if (self.repo_root.len > 0) allocator.free(self.repo_root);
        if (self.action_id.len > 0) allocator.free(self.action_id);
        for (self.argv) |arg| allocator.free(arg);
        if (self.argv.len > 0) allocator.free(self.argv);
        self.mode.deinit(allocator);
        self.* = .{ .repo_root = &.{}, .action_id = &.{}, .argv = &.{}, .launch_revision = 0, .mode = .generate };
    }
};

pub fn startCommitMessageAssist(comptime Msg: type, ctx: *chasen.Ctx(Msg), action_state: *actions.ActionState, request: *CommitMessageAssistRequest) !actions.PendingAction {
    defer request.deinit(ctx.allocator());

    const pending = action_state.begin(.assist_commit_message);
    errdefer _ = action_state.cancelPreparing(pending);

    const Task = actions.CommitMessageAssistTask(Msg);
    const task = try ctx.allocator().create(Task);
    task.* = .{
        .pending = pending,
        .repo_root = request.repo_root,
        .action_id = request.action_id,
        .argv = request.argv,
        .launch_revision = request.launch_revision,
        .mode = request.mode,
    };
    request.* = .{ .repo_root = &.{}, .action_id = &.{}, .argv = &.{}, .launch_revision = 0, .mode = .generate };
    errdefer destroyCommitMessageAssistTask(Task, ctx.allocator(), task);

    try ctx.task().spawnWith(.{ .ctx = task, .run = Task.run, .failed = Task.failed });
    return pending;
}

pub fn startAmend(comptime Msg: type, ctx: *chasen.Ctx(Msg), action_state: *actions.ActionState, confirmation: *app_state.AmendConfirmation) !actions.PendingAction {
    defer consumeAmendConfirmation(ctx.allocator(), confirmation);

    const pending = action_state.begin(.amend);
    errdefer _ = action_state.cancelPreparing(pending);

    const Task = actions.AmendTask(Msg);
    const task = try ctx.allocator().create(Task);
    task.* = .{
        .pending = pending,
        .repo_root = confirmation.repo_root,
        .subject = confirmation.subject,
        .body = confirmation.body,
    };
    confirmation.* = .{ .repo_root = &.{}, .subject = &.{}, .body = null };
    errdefer destroyCommitTask(Task, ctx.allocator(), task);

    try ctx.task().spawnWith(.{ .ctx = task, .run = Task.run, .failed = Task.failed });
    return pending;
}

pub fn startPush(
    comptime Msg: type,
    ctx: *chasen.Ctx(Msg),
    action_state: *actions.ActionState,
    env_map: ?*const std.process.Environ.Map,
    confirmation: *app_state.PushConfirmation,
) !actions.PendingAction {
    defer consumePushConfirmation(ctx.allocator(), confirmation);

    const pending = action_state.begin(.push);
    errdefer _ = action_state.cancelPreparing(pending);

    const Task = actions.PushTask(Msg);
    const task = try ctx.allocator().create(Task);
    task.* = .{
        .pending = pending,
        .mode = confirmation.mode,
        .repo_root = confirmation.repo_root,
        .branch = confirmation.branch,
        .remote = confirmation.remote,
        .remote_branch = confirmation.remote_branch,
        .oid = confirmation.oid,
        .env_map = env_map,
    };
    confirmation.* = .{
        .mode = .upstream,
        .repo_root = &.{},
        .branch = &.{},
        .remote = &.{},
        .remote_branch = &.{},
        .oid = &.{},
        .ahead_behind = null,
    };
    errdefer destroyPushTask(Task, ctx.allocator(), task);

    try ctx.task().spawnWith(.{ .ctx = task, .run = Task.run, .failed = Task.failed });
    return pending;
}

pub fn startPull(
    comptime Msg: type,
    ctx: *chasen.Ctx(Msg),
    action_state: *actions.ActionState,
    env_map: ?*const std.process.Environ.Map,
    confirmation: *app_state.PullConfirmation,
) !actions.PendingAction {
    defer consumePullConfirmation(ctx.allocator(), confirmation);

    const pending = action_state.begin(.pull);
    errdefer _ = action_state.cancelPreparing(pending);

    const Task = actions.PullTask(Msg);
    const task = try ctx.allocator().create(Task);
    task.* = .{
        .pending = pending,
        .repo_root = confirmation.repo_root,
        .branch = confirmation.branch,
        .remote = confirmation.remote,
        .remote_branch = confirmation.remote_branch,
        .oid = confirmation.oid,
        .env_map = env_map,
    };
    confirmation.* = .{
        .repo_root = &.{},
        .branch = &.{},
        .remote = &.{},
        .remote_branch = &.{},
        .oid = &.{},
        .ahead = 0,
        .behind = 0,
    };
    errdefer destroyPullTask(Task, ctx.allocator(), task);

    try ctx.task().spawnWith(.{ .ctx = task, .run = Task.run, .failed = Task.failed });
    return pending;
}

pub const FetchRequest = struct {
    repo_root: []u8,
    remote: []u8,
};

pub fn startFetch(
    comptime Msg: type,
    ctx: *chasen.Ctx(Msg),
    action_state: *actions.ActionState,
    env_map: ?*const std.process.Environ.Map,
    request: *FetchRequest,
) !actions.PendingAction {
    defer consumeFetchRequest(ctx.allocator(), request);

    const pending = action_state.begin(.fetch);
    errdefer _ = action_state.cancelPreparing(pending);

    const Task = actions.FetchTask(Msg);
    const task = try ctx.allocator().create(Task);
    task.* = .{
        .pending = pending,
        .repo_root = request.repo_root,
        .remote = request.remote,
        .env_map = env_map,
    };
    request.* = .{ .repo_root = &.{}, .remote = &.{} };
    errdefer destroyFetchTask(Task, ctx.allocator(), task);

    try ctx.task().spawnWith(.{ .ctx = task, .run = Task.run, .failed = Task.failed });
    return pending;
}

pub const SwitchBranchRequest = struct {
    repo_root: []u8,
    expected_branch: []u8,
    expected_oid: []u8,
    target_branch: []u8,
    target_oid: []u8,

    pub fn deinit(self: *SwitchBranchRequest, allocator: std.mem.Allocator) void {
        consumeSwitchBranchRequest(allocator, self);
    }
};

pub fn startSwitchBranch(
    comptime Msg: type,
    ctx: *chasen.Ctx(Msg),
    action_state: *actions.ActionState,
    request: *SwitchBranchRequest,
) !actions.PendingAction {
    defer consumeSwitchBranchRequest(ctx.allocator(), request);

    const pending = action_state.begin(.switch_branch);
    errdefer _ = action_state.cancelPreparing(pending);

    const Task = actions.SwitchBranchTask(Msg);
    const task = try ctx.allocator().create(Task);
    task.* = .{
        .pending = pending,
        .repo_root = request.repo_root,
        .expected_branch = request.expected_branch,
        .expected_oid = request.expected_oid,
        .target_branch = request.target_branch,
        .target_oid = request.target_oid,
    };
    request.* = .{
        .repo_root = &.{},
        .expected_branch = &.{},
        .expected_oid = &.{},
        .target_branch = &.{},
        .target_oid = &.{},
    };
    errdefer destroySwitchBranchTask(Task, ctx.allocator(), task);

    try ctx.task().spawnWith(.{ .ctx = task, .run = Task.run, .failed = Task.failed });
    return pending;
}

pub fn startCredentialedPush(
    comptime Msg: type,
    ctx: *chasen.Ctx(Msg),
    action_state: *actions.ActionState,
    env_map: ?*const std.process.Environ.Map,
    target: *app_state.PushRetryTarget,
    credentials: *actions.PushCredentials,
) !actions.PendingAction {
    // This function consumes credentials on every return path. Keeping cleanup
    // here prevents caller/task rollback paths from both freeing the same
    // secret buffers if spawning fails after task construction.
    defer credentials.deinit(ctx.allocator());

    const pending = action_state.begin(.push);
    errdefer _ = action_state.cancelPreparing(pending);

    const Task = actions.PushTask(Msg);
    const task = try ctx.allocator().create(Task);
    task.* = .{
        .pending = pending,
        .mode = target.mode,
        .repo_root = target.repo_root,
        .branch = target.branch,
        .remote = target.remote,
        .remote_branch = target.remote_branch,
        .oid = target.oid,
        .env_map = env_map,
        .credentials = credentials.*,
    };
    // The task now owns the secret buffers; empty the caller-visible struct so
    // the function-level defer becomes a no-op for credentials on success or
    // spawn rollback.
    credentials.* = .{ .username = &.{}, .password = &.{} };
    target.* = .{
        .repo_root = &.{},
        .branch = &.{},
        .remote = &.{},
        .remote_branch = &.{},
        .oid = &.{},
        .mode = .upstream,
        .remote_url = target.remote_url,
    };
    errdefer destroyPushTask(Task, ctx.allocator(), task);

    try ctx.task().spawnWith(.{ .ctx = task, .run = Task.run, .failed = Task.failed });
    if (target.remote_url) |remote_url| ctx.allocator().free(remote_url);
    target.* = .{
        .repo_root = &.{},
        .branch = &.{},
        .remote = &.{},
        .remote_branch = &.{},
        .oid = &.{},
        .mode = .upstream,
        .remote_url = null,
    };
    return pending;
}

fn destroyFileTask(comptime Task: type, allocator: std.mem.Allocator, task: *Task) void {
    if (task.repo_root.len > 0) allocator.free(task.repo_root);
    if (task.path.len > 0) allocator.free(task.path);
    if (@hasField(Task, "label") and task.label.len > 0) allocator.free(task.label);
    allocator.destroy(task);
}

fn consumeHunkTarget(allocator: std.mem.Allocator, target: anytype) void {
    if (target.patch.len > 0) allocator.free(target.patch);
    target.patch = &.{};
}

fn consumeAmendConfirmation(allocator: std.mem.Allocator, confirmation: *app_state.AmendConfirmation) void {
    if (confirmation.repo_root.len > 0) allocator.free(confirmation.repo_root);
    if (confirmation.subject.len > 0) allocator.free(confirmation.subject);
    if (confirmation.body) |body| allocator.free(body);
    confirmation.* = .{ .repo_root = &.{}, .subject = &.{}, .body = null };
}

fn consumePushConfirmation(allocator: std.mem.Allocator, confirmation: *app_state.PushConfirmation) void {
    if (confirmation.repo_root.len > 0) allocator.free(confirmation.repo_root);
    if (confirmation.branch.len > 0) allocator.free(confirmation.branch);
    if (confirmation.remote.len > 0) allocator.free(confirmation.remote);
    if (confirmation.remote_branch.len > 0) allocator.free(confirmation.remote_branch);
    if (confirmation.oid.len > 0) allocator.free(confirmation.oid);
    confirmation.* = .{
        .repo_root = &.{},
        .branch = &.{},
        .remote = &.{},
        .remote_branch = &.{},
        .oid = &.{},
        .mode = .upstream,
        .ahead_behind = null,
    };
}

fn consumePullConfirmation(allocator: std.mem.Allocator, confirmation: *app_state.PullConfirmation) void {
    if (confirmation.repo_root.len > 0) allocator.free(confirmation.repo_root);
    if (confirmation.branch.len > 0) allocator.free(confirmation.branch);
    if (confirmation.remote.len > 0) allocator.free(confirmation.remote);
    if (confirmation.remote_branch.len > 0) allocator.free(confirmation.remote_branch);
    if (confirmation.oid.len > 0) allocator.free(confirmation.oid);
    confirmation.* = .{
        .repo_root = &.{},
        .branch = &.{},
        .remote = &.{},
        .remote_branch = &.{},
        .oid = &.{},
        .ahead = 0,
        .behind = 0,
    };
}

fn destroyPullTask(comptime Task: type, allocator: std.mem.Allocator, task: *Task) void {
    if (task.repo_root.len > 0) allocator.free(task.repo_root);
    if (task.branch.len > 0) allocator.free(task.branch);
    if (task.remote.len > 0) allocator.free(task.remote);
    if (task.remote_branch.len > 0) allocator.free(task.remote_branch);
    if (task.oid.len > 0) allocator.free(task.oid);
    allocator.destroy(task);
}

fn consumeFetchRequest(allocator: std.mem.Allocator, request: *FetchRequest) void {
    if (request.repo_root.len > 0) allocator.free(request.repo_root);
    if (request.remote.len > 0) allocator.free(request.remote);
    request.* = .{ .repo_root = &.{}, .remote = &.{} };
}

fn destroyFetchTask(comptime Task: type, allocator: std.mem.Allocator, task: *Task) void {
    if (task.repo_root.len > 0) allocator.free(task.repo_root);
    if (task.remote.len > 0) allocator.free(task.remote);
    allocator.destroy(task);
}

fn consumeSwitchBranchRequest(allocator: std.mem.Allocator, request: *SwitchBranchRequest) void {
    if (request.repo_root.len > 0) allocator.free(request.repo_root);
    if (request.expected_branch.len > 0) allocator.free(request.expected_branch);
    if (request.expected_oid.len > 0) allocator.free(request.expected_oid);
    if (request.target_branch.len > 0) allocator.free(request.target_branch);
    if (request.target_oid.len > 0) allocator.free(request.target_oid);
    request.* = .{
        .repo_root = &.{},
        .expected_branch = &.{},
        .expected_oid = &.{},
        .target_branch = &.{},
        .target_oid = &.{},
    };
}

fn destroySwitchBranchTask(comptime Task: type, allocator: std.mem.Allocator, task: *Task) void {
    if (task.repo_root.len > 0) allocator.free(task.repo_root);
    if (task.expected_branch.len > 0) allocator.free(task.expected_branch);
    if (task.expected_oid.len > 0) allocator.free(task.expected_oid);
    if (task.target_branch.len > 0) allocator.free(task.target_branch);
    if (task.target_oid.len > 0) allocator.free(task.target_oid);
    allocator.destroy(task);
}

fn destroyHunkTask(comptime Task: type, allocator: std.mem.Allocator, task: *Task) void {
    if (task.repo_root.len > 0) allocator.free(task.repo_root);
    if (task.path.len > 0) allocator.free(task.path);
    if (task.patch.len > 0) allocator.free(task.patch);
    allocator.destroy(task);
}

fn destroyCommitTask(comptime Task: type, allocator: std.mem.Allocator, task: *Task) void {
    if (task.repo_root.len > 0) allocator.free(task.repo_root);
    if (task.subject.len > 0) allocator.free(task.subject);
    if (task.body) |body| allocator.free(body);
    allocator.destroy(task);
}

fn destroyCommitMessageAssistTask(comptime Task: type, allocator: std.mem.Allocator, task: *Task) void {
    if (task.repo_root.len > 0) allocator.free(task.repo_root);
    if (task.action_id.len > 0) allocator.free(task.action_id);
    for (task.argv) |arg| allocator.free(arg);
    if (task.argv.len > 0) allocator.free(task.argv);
    task.mode.deinit(allocator);
    allocator.destroy(task);
}

fn destroyPushTask(comptime Task: type, allocator: std.mem.Allocator, task: *Task) void {
    if (task.repo_root.len > 0) allocator.free(task.repo_root);
    if (task.branch.len > 0) allocator.free(task.branch);
    if (task.remote.len > 0) allocator.free(task.remote);
    if (task.remote_branch.len > 0) allocator.free(task.remote_branch);
    if (task.oid.len > 0) allocator.free(task.oid);
    if (task.credentials) |*credentials| credentials.deinit(allocator);
    allocator.destroy(task);
}
