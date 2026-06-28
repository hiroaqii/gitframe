const std = @import("std");
const chasen = @import("chasen");

const actions = @import("actions.zig");
const git_ops = @import("git_ops.zig");

/// Starts file-level Git action tasks and owns their launch-time rollback.
///
/// On success, task ownership is transferred to Chasen's task runtime. On any
/// error before that handoff, copied task fields are freed and the pending
/// action slot is cleared so App state does not stay blocked.
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

    try ctx.task().spawnWith(task, Task.run);
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

    try ctx.task().spawnWith(task, Task.run);
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

    try ctx.task().spawnWith(task, Task.run);
}

fn destroyFileTask(comptime Task: type, allocator: std.mem.Allocator, task: *Task) void {
    if (task.repo_root.len > 0) allocator.free(task.repo_root);
    if (task.path.len > 0) allocator.free(task.path);
    allocator.destroy(task);
}
