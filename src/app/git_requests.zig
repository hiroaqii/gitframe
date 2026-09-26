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
const remote_request = @import("remote_request.zig");
const app_state = @import("state.zig");
const git_remote = @import("../git/remote.zig");
const git_command = @import("../git/command.zig");
const process_runner = @import("../process/runner.zig");
const root_capability = @import("../repo/root_capability.zig");

pub fn startCreateStash(comptime Msg: type, ctx: *chasen.Ctx(Msg), pending: actions.PendingAction, dialog: *const @import("stash.zig").Create, root: *const root_capability.RootCapability, parent_environment: ?*const std.process.Environ.Map) !void {
    requireKind(pending, .create_stash);
    var authority = try LocalTaskAuthority.init(ctx.allocator(), root, parent_environment);
    errdefer authority.deinit();
    var snapshot = try dialog.snapshot.clone(ctx.allocator());
    errdefer snapshot.deinit(ctx.allocator());
    const message = try dialog.gitMessage(ctx.allocator());
    errdefer ctx.allocator().free(message);
    const Task = actions.CreateStashTask(Msg);
    const task = try ctx.allocator().create(Task);
    errdefer ctx.allocator().destroy(task);
    task.* = .{ .pending = pending, .snapshot = snapshot, .scope = dialog.scope, .message = message, .root = authority.root, .environment = authority.environment };
    try ctx.task().spawnWith(.{ .ctx = task, .run = Task.run, .failed = Task.failed });
}

pub fn startStashSelection(comptime Msg: type, ctx: *chasen.Ctx(Msg), pending: actions.PendingAction, confirmation: *const @import("stash.zig").Selection, root: *const root_capability.RootCapability, parent_environment: ?*const std.process.Environ.Map) !void {
    requireKind(pending, if (confirmation.action == .apply) .apply_stash else .drop_stash);
    var authority = try LocalTaskAuthority.init(ctx.allocator(), root, parent_environment);
    errdefer authority.deinit();
    var owned = try confirmation.clone(ctx.allocator());
    errdefer owned.deinit(ctx.allocator());
    const Task = actions.StashSelectionTask(Msg);
    const task = try ctx.allocator().create(Task);
    errdefer ctx.allocator().destroy(task);
    task.* = .{ .pending = pending, .confirmation = owned, .root = authority.root, .environment = authority.environment };
    try ctx.task().spawnWith(.{ .ctx = task, .run = Task.run, .failed = Task.failed });
}

pub fn startStageFile(comptime Msg: type, ctx: *chasen.Ctx(Msg), pending: actions.PendingAction, target: git_ops.StageTarget, root: *const root_capability.RootCapability, parent_environment: ?*const std.process.Environ.Map) !void {
    requireKind(pending, .stage_file);

    var authority = try LocalTaskAuthority.init(ctx.allocator(), root, parent_environment);
    var authority_consumed = false;
    defer if (!authority_consumed) authority.deinit();

    const Task = actions.StageFileTask(Msg);
    const task = try ctx.allocator().create(Task);
    task.* = .{
        .pending = pending,
        .repo_root = &.{},
        .root = authority.root,
        .environment = authority.environment,
        .path = &.{},
        .label = &.{},
        .target_kind = target.kind,
    };
    authority_consumed = true;
    errdefer destroyFileTask(Task, ctx.allocator(), task);

    task.repo_root = try ctx.allocator().dupe(u8, target.repo_root);
    task.path = try ctx.allocator().dupe(u8, target.path);
    task.label = try ctx.allocator().dupe(u8, if (target.label.len > 0) target.label else target.path);

    try ctx.task().spawnWith(.{ .ctx = task, .run = Task.run, .failed = Task.failed });
}

pub fn startUnstageFile(comptime Msg: type, ctx: *chasen.Ctx(Msg), pending: actions.PendingAction, target: git_ops.UnstageTarget, root: *const root_capability.RootCapability, parent_environment: ?*const std.process.Environ.Map) !void {
    requireKind(pending, .unstage_file);

    var authority = try LocalTaskAuthority.init(ctx.allocator(), root, parent_environment);
    var authority_consumed = false;
    defer if (!authority_consumed) authority.deinit();

    const Task = actions.UnstageFileTask(Msg);
    const task = try ctx.allocator().create(Task);
    task.* = .{
        .pending = pending,
        .repo_root = &.{},
        .root = authority.root,
        .environment = authority.environment,
        .path = &.{},
        .label = &.{},
        .target_kind = target.kind,
    };
    authority_consumed = true;
    errdefer destroyFileTask(Task, ctx.allocator(), task);

    task.repo_root = try ctx.allocator().dupe(u8, target.repo_root);
    task.path = try ctx.allocator().dupe(u8, target.path);
    task.label = try ctx.allocator().dupe(u8, if (target.label.len > 0) target.label else target.path);

    try ctx.task().spawnWith(.{ .ctx = task, .run = Task.run, .failed = Task.failed });
}

pub fn startStageHunk(comptime Msg: type, ctx: *chasen.Ctx(Msg), pending: actions.PendingAction, target: *git_ops.HunkStageTarget, root: *const root_capability.RootCapability, parent_environment: ?*const std.process.Environ.Map) !void {
    defer consumeHunkTarget(ctx.allocator(), target);
    requireKind(pending, .stage_hunk);

    var authority = try LocalTaskAuthority.init(ctx.allocator(), root, parent_environment);
    var authority_consumed = false;
    defer if (!authority_consumed) authority.deinit();

    const Task = actions.StageHunkTask(Msg);
    const task = try ctx.allocator().create(Task);
    task.* = .{
        .pending = pending,
        .repo_root = &.{},
        .root = authority.root,
        .environment = authority.environment,
        .path = &.{},
        .patch = &.{},
        .hunk_index = target.hunk_index,
        .session_mark_mutation = target.session_mark_mutation,
    };
    authority_consumed = true;
    errdefer destroyHunkTask(Task, ctx.allocator(), task);

    task.repo_root = try ctx.allocator().dupe(u8, target.repo_root);
    task.path = try ctx.allocator().dupe(u8, target.path);
    task.patch = target.patch;
    target.patch = &.{};

    try ctx.task().spawnWith(.{ .ctx = task, .run = Task.run, .failed = Task.failed });
}

pub fn startUnstageHunk(comptime Msg: type, ctx: *chasen.Ctx(Msg), pending: actions.PendingAction, target: *git_ops.HunkUnstageTarget, root: *const root_capability.RootCapability, parent_environment: ?*const std.process.Environ.Map) !void {
    defer consumeHunkTarget(ctx.allocator(), target);
    requireKind(pending, .unstage_hunk);

    var authority = try LocalTaskAuthority.init(ctx.allocator(), root, parent_environment);
    var authority_consumed = false;
    defer if (!authority_consumed) authority.deinit();

    const Task = actions.UnstageHunkTask(Msg);
    const task = try ctx.allocator().create(Task);
    task.* = .{
        .pending = pending,
        .repo_root = &.{},
        .root = authority.root,
        .environment = authority.environment,
        .path = &.{},
        .patch = &.{},
        .hunk_index = target.hunk_index,
        .session_mark_mutation = target.session_mark_mutation,
        .reload_after_success = target.reload_after_success,
    };
    authority_consumed = true;
    errdefer destroyHunkTask(Task, ctx.allocator(), task);

    task.repo_root = try ctx.allocator().dupe(u8, target.repo_root);
    task.path = try ctx.allocator().dupe(u8, target.path);
    task.patch = target.patch;
    target.patch = &.{};

    try ctx.task().spawnWith(.{ .ctx = task, .run = Task.run, .failed = Task.failed });
}

pub fn startDiscardFile(comptime Msg: type, ctx: *chasen.Ctx(Msg), pending: actions.PendingAction, repo_root: []const u8, path: []const u8, root: *const root_capability.RootCapability, parent_environment: ?*const std.process.Environ.Map) !void {
    requireKind(pending, .discard_file);

    var authority = try LocalTaskAuthority.init(ctx.allocator(), root, parent_environment);
    var authority_consumed = false;
    defer if (!authority_consumed) authority.deinit();

    const Task = actions.DiscardFileTask(Msg);
    const task = try ctx.allocator().create(Task);
    task.* = .{
        .pending = pending,
        .repo_root = &.{},
        .root = authority.root,
        .environment = authority.environment,
        .path = &.{},
    };
    authority_consumed = true;
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

pub fn startCommit(comptime Msg: type, ctx: *chasen.Ctx(Msg), pending: actions.PendingAction, request: *CommitRequest, root: *const root_capability.RootCapability, parent_environment: ?*const std.process.Environ.Map) !void {
    defer request.deinit(ctx.allocator());
    requireKind(pending, .commit);

    var authority = try LocalTaskAuthority.init(ctx.allocator(), root, parent_environment);
    var authority_consumed = false;
    defer if (!authority_consumed) authority.deinit();

    const Task = actions.CommitTask(Msg);
    const task = try ctx.allocator().create(Task);
    task.* = .{
        .pending = pending,
        .repo_root = request.repo_root,
        .root = authority.root,
        .environment = authority.environment,
        .subject = request.subject,
        .body = request.body,
    };
    authority_consumed = true;
    request.* = .{ .repo_root = &.{}, .subject = &.{}, .body = null };
    errdefer destroyCommitTask(Task, ctx.allocator(), task);

    try ctx.task().spawnWith(.{ .ctx = task, .run = Task.run, .failed = Task.failed });
}

pub fn startAmend(comptime Msg: type, ctx: *chasen.Ctx(Msg), pending: actions.PendingAction, confirmation: *app_state.AmendConfirmation, root: *const root_capability.RootCapability, parent_environment: ?*const std.process.Environ.Map) !void {
    defer consumeAmendConfirmation(ctx.allocator(), confirmation);
    requireKind(pending, .amend);

    var authority = try LocalTaskAuthority.init(ctx.allocator(), root, parent_environment);
    var authority_consumed = false;
    defer if (!authority_consumed) authority.deinit();

    const Task = actions.AmendTask(Msg);
    const task = try ctx.allocator().create(Task);
    task.* = .{
        .pending = pending,
        .repo_root = confirmation.repo_root,
        .root = authority.root,
        .environment = authority.environment,
        .subject = confirmation.subject,
        .body = confirmation.body,
    };
    authority_consumed = true;
    confirmation.* = .{ .repo_root = &.{}, .subject = &.{}, .body = null };
    errdefer destroyCommitTask(Task, ctx.allocator(), task);

    try ctx.task().spawnWith(.{ .ctx = task, .run = Task.run, .failed = Task.failed });
}

pub fn startPush(
    comptime Msg: type,
    ctx: *chasen.Ctx(Msg),
    pending: actions.PendingAction,
    root: *?root_capability.RootCapability,
    environment: *?git_remote.OwnedRemoteEnvironment,
    cancellation: process_runner.CancellationView,
    confirmation: *app_state.PushConfirmation,
) !void {
    defer consumePushConfirmation(ctx.allocator(), confirmation);
    requireKind(pending, .push);

    const Task = actions.PushTask(Msg);
    const task = try ctx.allocator().create(Task);
    task.* = .{
        .pending = pending,
        .identity = .{
            .repo_epoch = confirmation.repository_identity.repo_epoch,
            .root_identity = confirmation.repository_identity.root_identity,
            .operation_generation = pending.generation,
        },
        .mode = confirmation.mode,
        .repo_root = confirmation.repo_root,
        .branch = confirmation.branch,
        .remote = confirmation.remote,
        .remote_branch = confirmation.remote_branch,
        .oid = confirmation.oid,
        .root = root.* orelse @panic("background push requires an owned root"),
        .environment = environment.* orelse @panic("background push requires an owned environment"),
        .cancellation = cancellation,
    };
    root.* = null;
    environment.* = null;
    confirmation.* = .{
        .repository_identity = .{
            .repo_epoch = 0,
            .root_identity = .{ .device = 0, .inode = 0 },
        },
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
    root: *?root_capability.RootCapability,
    environment: *?git_remote.OwnedRemoteEnvironment,
    cancellation: process_runner.CancellationView,
    confirmation: *app_state.PullConfirmation,
) !void {
    defer consumePullConfirmation(ctx.allocator(), confirmation);
    requireKind(pending, .pull);

    const Task = actions.PullTask(Msg);
    const task = try ctx.allocator().create(Task);
    task.* = .{
        .pending = pending,
        .identity = .{
            .repo_epoch = confirmation.repository_identity.repo_epoch,
            .root_identity = confirmation.repository_identity.root_identity,
            .operation_generation = pending.generation,
        },
        .repo_root = confirmation.repo_root,
        .branch = confirmation.branch,
        .remote = confirmation.remote,
        .remote_branch = confirmation.remote_branch,
        .oid = confirmation.oid,
        .root = root.* orelse @panic("background pull requires an owned root"),
        .environment = environment.* orelse @panic("background pull requires an owned environment"),
        .cancellation = cancellation,
    };
    root.* = null;
    environment.* = null;
    confirmation.* = .{
        .repository_identity = .{
            .repo_epoch = 0,
            .root_identity = .{ .device = 0, .inode = 0 },
        },
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
    repository_identity: remote_request.RepositoryIdentity = .{
        .repo_epoch = 0,
        .root_identity = .{ .device = 0, .inode = 0 },
    },
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
    root: *?root_capability.RootCapability,
    environment: *?git_remote.OwnedRemoteEnvironment,
    cancellation: process_runner.CancellationView,
    request: *FetchRequest,
) !void {
    defer consumeFetchRequest(ctx.allocator(), request);
    requireKind(pending, .fetch);

    const Task = actions.FetchTask(Msg);
    const task = try ctx.allocator().create(Task);
    task.* = .{
        .pending = pending,
        .identity = .{
            .repo_epoch = request.repository_identity.repo_epoch,
            .root_identity = request.repository_identity.root_identity,
            .operation_generation = pending.generation,
        },
        .repo_root = request.repo_root,
        .remote = request.remote,
        .root = root.* orelse @panic("background fetch requires an owned root"),
        .environment = environment.* orelse @panic("background fetch requires an owned environment"),
        .cancellation = cancellation,
    };
    root.* = null;
    environment.* = null;
    request.* = .{
        .repository_identity = .{
            .repo_epoch = 0,
            .root_identity = .{ .device = 0, .inode = 0 },
        },
        .repo_root = &.{},
        .remote = &.{},
    };
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
    root: *const root_capability.RootCapability,
    parent_environment: ?*const std.process.Environ.Map,
) !void {
    defer consumeSwitchBranchRequest(ctx.allocator(), request);
    requireKind(pending, .switch_branch);

    var authority = try LocalTaskAuthority.init(ctx.allocator(), root, parent_environment);
    var authority_consumed = false;
    defer if (!authority_consumed) authority.deinit();

    const Task = actions.SwitchBranchTask(Msg);
    const task = try ctx.allocator().create(Task);
    task.* = .{
        .pending = pending,
        .repo_root = request.repo_root,
        .root = authority.root,
        .environment = authority.environment,
        .expected_branch = request.expected_branch,
        .expected_oid = request.expected_oid,
        .target_branch = request.target_branch,
        .target_oid = request.target_oid,
    };
    authority_consumed = true;
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

const LocalTaskAuthority = struct {
    root: root_capability.RootCapability,
    environment: git_command.LocalGitEnvironment,

    fn init(
        allocator: std.mem.Allocator,
        root: *const root_capability.RootCapability,
        parent_environment: ?*const std.process.Environ.Map,
    ) !LocalTaskAuthority {
        var owned_root = try root.duplicate();
        errdefer owned_root.deinit();
        return .{
            .root = owned_root,
            .environment = try git_command.LocalGitEnvironment.initFromParent(allocator, parent_environment),
        };
    }

    fn deinit(self: *LocalTaskAuthority) void {
        self.environment.deinit();
        self.root.deinit();
        self.* = undefined;
    }
};

fn destroyFileTask(comptime Task: type, allocator: std.mem.Allocator, task: *Task) void {
    if (task.repo_root.len > 0) allocator.free(task.repo_root);
    if (task.path.len > 0) allocator.free(task.path);
    if (@hasField(Task, "label") and task.label.len > 0) allocator.free(task.label);
    task.environment.deinit();
    task.root.deinit();
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
        .repository_identity = .{
            .repo_epoch = 0,
            .root_identity = .{ .device = 0, .inode = 0 },
        },
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
        .repository_identity = .{
            .repo_epoch = 0,
            .root_identity = .{ .device = 0, .inode = 0 },
        },
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
    if (task.root) |*root| root.deinit();
    if (task.environment) |*environment| environment.deinit();
    allocator.destroy(task);
}

fn consumeFetchRequest(allocator: std.mem.Allocator, request: *FetchRequest) void {
    if (request.repo_root.len > 0) allocator.free(request.repo_root);
    if (request.remote.len > 0) allocator.free(request.remote);
    request.* = .{
        .repository_identity = .{
            .repo_epoch = 0,
            .root_identity = .{ .device = 0, .inode = 0 },
        },
        .repo_root = &.{},
        .remote = &.{},
    };
}

fn destroyFetchTask(comptime Task: type, allocator: std.mem.Allocator, task: *Task) void {
    if (task.repo_root.len > 0) allocator.free(task.repo_root);
    if (task.remote.len > 0) allocator.free(task.remote);
    if (task.root) |*root| root.deinit();
    if (task.environment) |*environment| environment.deinit();
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
    task.environment.deinit();
    task.root.deinit();
    allocator.destroy(task);
}

fn destroyHunkTask(comptime Task: type, allocator: std.mem.Allocator, task: *Task) void {
    if (task.repo_root.len > 0) allocator.free(task.repo_root);
    if (task.path.len > 0) allocator.free(task.path);
    if (task.patch.len > 0) allocator.free(task.patch);
    task.environment.deinit();
    task.root.deinit();
    allocator.destroy(task);
}

fn destroyCommitTask(comptime Task: type, allocator: std.mem.Allocator, task: *Task) void {
    if (task.repo_root.len > 0) allocator.free(task.repo_root);
    if (task.subject.len > 0) allocator.free(task.subject);
    if (task.body) |body| allocator.free(body);
    task.environment.deinit();
    task.root.deinit();
    allocator.destroy(task);
}

fn destroyPushTask(comptime Task: type, allocator: std.mem.Allocator, task: *Task) void {
    if (task.repo_root.len > 0) allocator.free(task.repo_root);
    if (task.branch.len > 0) allocator.free(task.branch);
    if (task.remote.len > 0) allocator.free(task.remote);
    if (task.remote_branch.len > 0) allocator.free(task.remote_branch);
    if (task.oid.len > 0) allocator.free(task.oid);
    if (task.root) |*root| root.deinit();
    if (task.environment) |*environment| environment.deinit();
    allocator.destroy(task);
}
