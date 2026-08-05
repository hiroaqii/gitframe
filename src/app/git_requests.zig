//! Git action launch controller.
//!
//! Borrowed targets are duplicated into task-owned payloads. Owned request
//! payloads are consumed on every return path: success transfers ownership to
//! the task, and failure frees the payload before returning.
//!
//! The action lifecycle prepares the exact `PendingAction` before entering a
//! launcher. These functions either queue a task carrying that token or return
//! an error; the caller then rejects or accepts the same token synchronously.

const std = @import("std");
const chasen = @import("chasen");

const actions = @import("actions.zig");
const git_ops = @import("git_ops.zig");
const app_state = @import("state.zig");

pub fn startStageFile(comptime Msg: type, ctx: *chasen.Ctx(Msg), pending: actions.PendingAction, target: git_ops.StageTarget) !void {
    requireKind(pending, .stage_file);

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
}

pub fn startUnstageFile(comptime Msg: type, ctx: *chasen.Ctx(Msg), pending: actions.PendingAction, target: git_ops.UnstageTarget) !void {
    requireKind(pending, .unstage_file);

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
}

pub fn startStageHunk(comptime Msg: type, ctx: *chasen.Ctx(Msg), pending: actions.PendingAction, target: *git_ops.HunkStageTarget) !void {
    defer consumeHunkTarget(ctx.allocator(), target);
    requireKind(pending, .stage_hunk);

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
}

pub fn startUnstageHunk(comptime Msg: type, ctx: *chasen.Ctx(Msg), pending: actions.PendingAction, target: *git_ops.HunkUnstageTarget) !void {
    defer consumeHunkTarget(ctx.allocator(), target);
    requireKind(pending, .unstage_hunk);

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
}

pub fn startDiscardFile(comptime Msg: type, ctx: *chasen.Ctx(Msg), pending: actions.PendingAction, repo_root: []const u8, path: []const u8) !void {
    requireKind(pending, .discard_file);

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

pub fn startCommit(comptime Msg: type, ctx: *chasen.Ctx(Msg), pending: actions.PendingAction, request: *CommitRequest) !void {
    defer request.deinit(ctx.allocator());
    requireKind(pending, .commit);

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

pub fn startCommitMessageAssist(comptime Msg: type, ctx: *chasen.Ctx(Msg), pending: actions.PendingAction, request: *CommitMessageAssistRequest) !void {
    defer request.deinit(ctx.allocator());
    requireKind(pending, .assist_commit_message);

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
    errdefer actions.destroyCommitMessageAssistTask(Task, ctx.allocator(), task);

    try ctx.task().spawnWith(.{ .ctx = task, .run = Task.run, .failed = Task.failed });
}

pub fn startAmend(comptime Msg: type, ctx: *chasen.Ctx(Msg), pending: actions.PendingAction, confirmation: *app_state.AmendConfirmation) !void {
    defer consumeAmendConfirmation(ctx.allocator(), confirmation);
    requireKind(pending, .amend);

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
}

pub fn startPush(
    comptime Msg: type,
    ctx: *chasen.Ctx(Msg),
    pending: actions.PendingAction,
    env_map: ?*const std.process.Environ.Map,
    confirmation: *app_state.PushConfirmation,
) !void {
    defer consumePushConfirmation(ctx.allocator(), confirmation);
    requireKind(pending, .push);

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
}

pub fn startPull(
    comptime Msg: type,
    ctx: *chasen.Ctx(Msg),
    pending: actions.PendingAction,
    env_map: ?*const std.process.Environ.Map,
    confirmation: *app_state.PullConfirmation,
) !void {
    defer consumePullConfirmation(ctx.allocator(), confirmation);
    requireKind(pending, .pull);

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
}

pub const FetchRequest = struct {
    repo_root: []u8,
    remote: []u8,

    pub fn deinit(self: *FetchRequest, allocator: std.mem.Allocator) void {
        consumeFetchRequest(allocator, self);
    }
};

pub fn startFetch(
    comptime Msg: type,
    ctx: *chasen.Ctx(Msg),
    pending: actions.PendingAction,
    env_map: ?*const std.process.Environ.Map,
    request: *FetchRequest,
) !void {
    defer consumeFetchRequest(ctx.allocator(), request);
    requireKind(pending, .fetch);

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
    pending: actions.PendingAction,
    request: *SwitchBranchRequest,
) !void {
    defer consumeSwitchBranchRequest(ctx.allocator(), request);
    requireKind(pending, .switch_branch);

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
}

pub fn startCredentialedPush(
    comptime Msg: type,
    ctx: *chasen.Ctx(Msg),
    pending: actions.PendingAction,
    env_map: ?*const std.process.Environ.Map,
    target: *app_state.PushRetryTarget,
    credentials: *actions.PushCredentials,
) !void {
    // This function consumes credentials on every return path. Keeping cleanup
    // here prevents caller/task rollback paths from both freeing the same
    // secret buffers if spawning fails after task construction.
    defer credentials.deinit(ctx.allocator());

    requireKind(pending, .push);

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
}

fn destroyFileTask(comptime Task: type, allocator: std.mem.Allocator, task: *Task) void {
    if (task.repo_root.len > 0) allocator.free(task.repo_root);
    if (task.path.len > 0) allocator.free(task.path);
    if (@hasField(Task, "label") and task.label.len > 0) allocator.free(task.label);
    allocator.destroy(task);
}

fn requireKind(pending: actions.PendingAction, expected: actions.ActionKind) void {
    if (pending.kind != expected) @panic("Git action launcher received the wrong action kind");
}

fn consumeHunkTarget(allocator: std.mem.Allocator, target: anytype) void {
    target.deinit(allocator);
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

fn destroyPushTask(comptime Task: type, allocator: std.mem.Allocator, task: *Task) void {
    if (task.repo_root.len > 0) allocator.free(task.repo_root);
    if (task.branch.len > 0) allocator.free(task.branch);
    if (task.remote.len > 0) allocator.free(task.remote);
    if (task.remote_branch.len > 0) allocator.free(task.remote_branch);
    if (task.oid.len > 0) allocator.free(task.oid);
    if (task.credentials) |*credentials| credentials.deinit(allocator);
    allocator.destroy(task);
}
