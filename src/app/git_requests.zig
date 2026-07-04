//! Git action launch controller.
//!
//! Borrowed targets are duplicated into task-owned payloads. Owned request
//! payloads are consumed on every return path: success transfers ownership to
//! the task, and failure frees the payload before returning.

const std = @import("std");
const chasen = @import("chasen");

const actions = @import("actions.zig");
const git_ops = @import("git_ops.zig");
const app_state = @import("state.zig");

pub fn hasPendingAction(action_state: actions.ActionState) bool {
    return action_state.pending != null;
}

pub fn startStageFile(comptime Msg: type, ctx: *chasen.Ctx(Msg), action_state: *actions.ActionState, target: git_ops.StageTarget) !void {
    const pending = action_state.begin(.stage_file);
    errdefer _ = action_state.finish(pending);

    const Task = actions.StageFileTask(Msg);
    const task = try ctx.allocator().create(Task);
    task.* = .{
        .pending = pending,
        .repo_root = &.{},
        .path = &.{},
    };
    errdefer destroyFileTask(Task, ctx.allocator(), task);

    task.repo_root = try ctx.allocator().dupe(u8, target.repo_root);
    task.path = try ctx.allocator().dupe(u8, target.path);

    try ctx.task().spawnWith(.{ .ctx = task, .run = Task.run, .failed = Task.failed });
}

pub fn startUnstageFile(comptime Msg: type, ctx: *chasen.Ctx(Msg), action_state: *actions.ActionState, target: git_ops.UnstageTarget) !void {
    const pending = action_state.begin(.unstage_file);
    errdefer _ = action_state.finish(pending);

    const Task = actions.UnstageFileTask(Msg);
    const task = try ctx.allocator().create(Task);
    task.* = .{
        .pending = pending,
        .repo_root = &.{},
        .path = &.{},
    };
    errdefer destroyFileTask(Task, ctx.allocator(), task);

    task.repo_root = try ctx.allocator().dupe(u8, target.repo_root);
    task.path = try ctx.allocator().dupe(u8, target.path);

    try ctx.task().spawnWith(.{ .ctx = task, .run = Task.run, .failed = Task.failed });
}

pub fn startStageHunk(comptime Msg: type, ctx: *chasen.Ctx(Msg), action_state: *actions.ActionState, target: *git_ops.HunkStageTarget) !void {
    defer consumeHunkTarget(ctx.allocator(), target);

    const pending = action_state.begin(.stage_hunk);
    errdefer _ = action_state.finish(pending);

    const Task = actions.StageHunkTask(Msg);
    const task = try ctx.allocator().create(Task);
    task.* = .{
        .pending = pending,
        .repo_root = &.{},
        .path = &.{},
        .patch = &.{},
        .hunk_index = target.hunk_index,
        .mark_source = target.mark_source,
    };
    errdefer destroyHunkTask(Task, ctx.allocator(), task);

    task.repo_root = try ctx.allocator().dupe(u8, target.repo_root);
    task.path = try ctx.allocator().dupe(u8, target.path);
    task.patch = target.patch;
    target.patch = &.{};

    try ctx.task().spawnWith(.{ .ctx = task, .run = Task.run, .failed = Task.failed });
}

pub fn startUnstageHunk(comptime Msg: type, ctx: *chasen.Ctx(Msg), action_state: *actions.ActionState, target: *git_ops.HunkUnstageTarget) !void {
    defer consumeHunkTarget(ctx.allocator(), target);

    const pending = action_state.begin(.unstage_hunk);
    errdefer _ = action_state.finish(pending);

    const Task = actions.UnstageHunkTask(Msg);
    const task = try ctx.allocator().create(Task);
    task.* = .{
        .pending = pending,
        .repo_root = &.{},
        .path = &.{},
        .patch = &.{},
        .hunk_index = target.hunk_index,
        .mark_source = target.mark_source,
        .reload_after_success = target.reload_after_success,
    };
    errdefer destroyHunkTask(Task, ctx.allocator(), task);

    task.repo_root = try ctx.allocator().dupe(u8, target.repo_root);
    task.path = try ctx.allocator().dupe(u8, target.path);
    task.patch = target.patch;
    target.patch = &.{};

    try ctx.task().spawnWith(.{ .ctx = task, .run = Task.run, .failed = Task.failed });
}

pub fn startDiscardFile(comptime Msg: type, ctx: *chasen.Ctx(Msg), action_state: *actions.ActionState, repo_root: []const u8, path: []const u8) !void {
    const pending = action_state.begin(.discard_file);
    errdefer _ = action_state.finish(pending);

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

pub fn startCommit(comptime Msg: type, ctx: *chasen.Ctx(Msg), action_state: *actions.ActionState, request: *CommitRequest) !void {
    defer request.deinit(ctx.allocator());

    const pending = action_state.begin(.commit);
    errdefer _ = action_state.finish(pending);

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

pub fn startAmend(comptime Msg: type, ctx: *chasen.Ctx(Msg), action_state: *actions.ActionState, confirmation: *app_state.AmendConfirmation) !void {
    defer consumeAmendConfirmation(ctx.allocator(), confirmation);

    const pending = action_state.begin(.amend);
    errdefer _ = action_state.finish(pending);

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
    action_state: *actions.ActionState,
    env_map: ?*const std.process.Environ.Map,
    confirmation: *app_state.PushConfirmation,
) !void {
    defer consumePushConfirmation(ctx.allocator(), confirmation);

    const pending = action_state.begin(.push);
    errdefer _ = action_state.finish(pending);

    const Task = actions.PushTask(Msg);
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
    errdefer destroyPushTask(Task, ctx.allocator(), task);

    try ctx.task().spawnWith(.{ .ctx = task, .run = Task.run, .failed = Task.failed });
}

fn destroyFileTask(comptime Task: type, allocator: std.mem.Allocator, task: *Task) void {
    if (task.repo_root.len > 0) allocator.free(task.repo_root);
    if (task.path.len > 0) allocator.free(task.path);
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
        .ahead = 0,
        .behind = 0,
    };
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
    allocator.destroy(task);
}
