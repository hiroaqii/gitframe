const std = @import("std");
const chasen = @import("chasen");
const git_backend = @import("../git/backend.zig");
const git_push = @import("../git/push.zig");
const git_ops = @import("git_ops.zig");
const external_action = @import("../external/action.zig");
const process_runner = @import("../process/runner.zig");
const context_export = @import("../context_export.zig");

/// Git operation categories that can become App-facing actions.
///
/// This is intentionally a taxonomy, not an executable backend API. Concrete
/// requests/results live next to the first implementation of each operation.
pub const ActionKind = enum {
    stage_file,
    unstage_file,
    stage_hunk,
    unstage_hunk,
    discard_file,
    commit,
    assist_commit_message,
    amend,
    push,
    pull,
    fetch,
    switch_branch,

    /// Whether an already-running background read must be discarded while
    /// this action is pending. Keep this exhaustive: adding an action must
    /// make its repository-mutation policy explicit.
    pub fn blocksBackgroundAcceptance(self: ActionKind) bool {
        return switch (self) {
            .assist_commit_message,
            => false,
            .stage_file,
            .unstage_file,
            .stage_hunk,
            .unstage_hunk,
            .discard_file,
            .commit,
            .amend,
            .push,
            .pull,
            .fetch,
            .switch_branch,
            => true,
        };
    }
};

pub const PendingAction = struct {
    generation: u64,
    kind: ActionKind,
};

pub const ActionLaunchPhase = enum {
    preparing,
    accepted,
};

/// App-owned launch state for one immutable task/result token.
///
/// Tasks carry only `PendingAction`. The phase stays here so a result cannot
/// turn allocation/preparation into a successful launch after the fact.
pub const PendingOwner = struct {
    token: PendingAction,
    launch: ActionLaunchPhase,

    pub fn matches(self: PendingOwner, pending: PendingAction) bool {
        return self.token.generation == pending.generation and self.token.kind == pending.kind;
    }
};

/// Small App-facing receiver for future Git actions.
///
/// Keep this limited to in-flight ownership. Result text remains in App's
/// status message until concrete operation result ownership exists.
pub const ActionState = struct {
    pending: ?PendingOwner = null,
    generation: u64 = 0,

    pub fn begin(self: *ActionState, kind: ActionKind) PendingAction {
        self.generation +%= 1;
        const pending: PendingAction = .{
            .generation = self.generation,
            .kind = kind,
        };
        self.pending = .{
            .token = pending,
            .launch = .preparing,
        };
        return pending;
    }

    pub fn isCurrent(self: *const ActionState, pending: PendingAction) bool {
        const current = self.pending orelse return false;
        return current.matches(pending);
    }

    pub fn isAccepted(self: *const ActionState, pending: PendingAction) bool {
        const current = self.pending orelse return false;
        return current.matches(pending) and current.launch == .accepted;
    }

    pub fn acceptLaunch(self: *ActionState, pending: PendingAction) bool {
        const current = if (self.pending) |*owner| owner else return false;
        if (!current.matches(pending) or current.launch != .preparing) return false;
        current.launch = .accepted;
        return true;
    }

    pub fn cancelPreparing(self: *ActionState, pending: PendingAction) bool {
        const current = self.pending orelse return false;
        if (!current.matches(pending) or current.launch != .preparing) return false;
        self.pending = null;
        return true;
    }

    pub fn finish(self: *ActionState, pending: PendingAction) bool {
        if (!self.isAccepted(pending)) return false;
        self.pending = null;
        return true;
    }

    pub fn clear(self: *ActionState) void {
        self.pending = null;
    }
};

test "ActionKind background acceptance policy distinguishes reads from mutations" {
    try std.testing.expect(!ActionKind.assist_commit_message.blocksBackgroundAcceptance());
    try std.testing.expect(ActionKind.stage_file.blocksBackgroundAcceptance());
    try std.testing.expect(ActionKind.fetch.blocksBackgroundAcceptance());
    try std.testing.expect(ActionKind.switch_branch.blocksBackgroundAcceptance());
}

pub const StageFileFinished = struct {
    pending: PendingAction,
    repo_root: []u8 = &.{},
    path: []u8,
    result: FileActionTaskResult,

    pub fn deinit(self: *StageFileFinished, allocator: std.mem.Allocator) void {
        if (self.repo_root.len > 0) allocator.free(self.repo_root);
        allocator.free(self.path);
        self.result.deinit(allocator);
        self.* = .{
            .pending = .{ .generation = 0, .kind = .stage_file },
            .repo_root = &.{},
            .path = &.{},
            .result = .ok,
        };
    }
};

pub const UnstageFileFinished = struct {
    pending: PendingAction,
    repo_root: []u8 = &.{},
    path: []u8,
    result: FileActionTaskResult,

    pub fn deinit(self: *UnstageFileFinished, allocator: std.mem.Allocator) void {
        if (self.repo_root.len > 0) allocator.free(self.repo_root);
        allocator.free(self.path);
        self.result.deinit(allocator);
        self.* = .{
            .pending = .{ .generation = 0, .kind = .unstage_file },
            .repo_root = &.{},
            .path = &.{},
            .result = .ok,
        };
    }
};

pub const StageHunkFinished = struct {
    pending: PendingAction,
    repo_root: []u8,
    path: []u8,
    hunk_index: usize,
    session_mark_mutation: git_ops.SessionHunkMarkMutation,
    result: FileActionTaskResult,

    pub fn deinit(self: *StageHunkFinished, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        allocator.free(self.path);
        self.result.deinit(allocator);
        self.* = .{
            .pending = .{ .generation = 0, .kind = .stage_hunk },
            .repo_root = &.{},
            .path = &.{},
            .hunk_index = 0,
            .session_mark_mutation = .none,
            .result = .ok,
        };
    }
};

pub const UnstageHunkFinished = struct {
    pending: PendingAction,
    repo_root: []u8,
    path: []u8,
    hunk_index: usize,
    session_mark_mutation: git_ops.SessionHunkMarkMutation,
    reload_after_success: bool = false,
    result: FileActionTaskResult,

    pub fn deinit(self: *UnstageHunkFinished, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        allocator.free(self.path);
        self.result.deinit(allocator);
        self.* = .{
            .pending = .{ .generation = 0, .kind = .unstage_hunk },
            .repo_root = &.{},
            .path = &.{},
            .hunk_index = 0,
            .session_mark_mutation = .none,
            .reload_after_success = false,
            .result = .ok,
        };
    }
};

pub const DiscardFileFinished = struct {
    pending: PendingAction,
    repo_root: []u8,
    path: []u8,
    result: FileActionTaskResult,

    pub fn deinit(self: *DiscardFileFinished, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        allocator.free(self.path);
        self.result.deinit(allocator);
        self.* = .{
            .pending = .{ .generation = 0, .kind = .discard_file },
            .repo_root = &.{},
            .path = &.{},
            .result = .ok,
        };
    }
};

pub const CommitFinished = struct {
    pending: PendingAction,
    repo_root: []u8,
    result: FileActionTaskResult,

    pub fn deinit(self: *CommitFinished, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        self.result.deinit(allocator);
        self.* = .{
            .pending = .{ .generation = 0, .kind = .commit },
            .repo_root = &.{},
            .result = .ok,
        };
    }
};

pub const DraftSnapshot = struct {
    subject: []u8,
    body: []u8,

    pub fn deinit(self: *DraftSnapshot, allocator: std.mem.Allocator) void {
        if (self.subject.len > 0) allocator.free(self.subject);
        if (self.body.len > 0) allocator.free(self.body);
        self.* = .{ .subject = &.{}, .body = &.{} };
    }
};

pub const CommitMessageAssistMode = union(enum) {
    generate,
    improve: DraftSnapshot,

    pub fn deinit(self: *CommitMessageAssistMode, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .generate => {},
            .improve => |*snapshot| snapshot.deinit(allocator),
        }
        self.* = .generate;
    }
};

pub const CommitMessageDraft = struct {
    subject: []u8,
    body: ?[]u8 = null,
    truncated: bool = false,

    pub fn deinit(self: *CommitMessageDraft, allocator: std.mem.Allocator) void {
        allocator.free(self.subject);
        if (self.body) |body| allocator.free(body);
        self.* = .{ .subject = &.{}, .body = null, .truncated = false };
    }
};

pub const CommitMessageActionResult = union(enum) {
    ok: CommitMessageDraft,
    failed: []u8,
    failed_static: []const u8,

    pub fn deinit(self: *CommitMessageActionResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ok => |*message| message.deinit(allocator),
            .failed => |message| allocator.free(message),
            .failed_static => {},
        }
        self.* = .{ .failed_static = "commit message action failed" };
    }
};

pub const CommitMessageAssistFinished = struct {
    pending: PendingAction,
    repo_root: []u8,
    action_id: []u8,
    launch_revision: u64,
    mode: CommitMessageAssistMode,
    result: CommitMessageActionResult,

    pub fn deinit(self: *CommitMessageAssistFinished, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        allocator.free(self.action_id);
        self.mode.deinit(allocator);
        self.result.deinit(allocator);
        self.* = .{
            .pending = .{ .generation = 0, .kind = .assist_commit_message },
            .repo_root = &.{},
            .action_id = &.{},
            .launch_revision = 0,
            .mode = .generate,
            .result = .{ .failed_static = "commit message action failed" },
        };
    }
};

pub const AmendFinished = struct {
    pending: PendingAction,
    repo_root: []u8,
    result: FileActionTaskResult,

    pub fn deinit(self: *AmendFinished, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        self.result.deinit(allocator);
        self.* = .{
            .pending = .{ .generation = 0, .kind = .amend },
            .repo_root = &.{},
            .result = .ok,
        };
    }
};

pub const PushFinished = struct {
    pending: PendingAction,
    mode: git_push.Mode,
    repo_root: []u8,
    branch: []u8,
    remote: []u8,
    remote_branch: []u8,
    oid: []u8,
    result: FileActionTaskResult,

    pub fn deinit(self: *PushFinished, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        allocator.free(self.branch);
        allocator.free(self.remote);
        allocator.free(self.remote_branch);
        allocator.free(self.oid);
        self.result.deinit(allocator);
        self.* = .{
            .pending = .{ .generation = 0, .kind = .push },
            .mode = .upstream,
            .repo_root = &.{},
            .branch = &.{},
            .remote = &.{},
            .remote_branch = &.{},
            .oid = &.{},
            .result = .ok,
        };
    }
};

pub const PullFinished = struct {
    pending: PendingAction,
    repo_root: []u8,
    branch: []u8,
    remote: []u8,
    remote_branch: []u8,
    oid: []u8,
    result: FileActionTaskResult,

    pub fn deinit(self: *PullFinished, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        allocator.free(self.branch);
        allocator.free(self.remote);
        allocator.free(self.remote_branch);
        allocator.free(self.oid);
        self.result.deinit(allocator);
        self.* = .{
            .pending = .{ .generation = 0, .kind = .pull },
            .repo_root = &.{},
            .branch = &.{},
            .remote = &.{},
            .remote_branch = &.{},
            .oid = &.{},
            .result = .ok,
        };
    }
};

pub const FetchFinished = struct {
    pending: PendingAction,
    repo_root: []u8,
    remote: []u8,
    result: FileActionTaskResult,

    pub fn deinit(self: *FetchFinished, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        allocator.free(self.remote);
        self.result.deinit(allocator);
        self.* = .{
            .pending = .{ .generation = 0, .kind = .fetch },
            .repo_root = &.{},
            .remote = &.{},
            .result = .ok,
        };
    }
};

pub const SwitchBranchFinished = struct {
    pending: PendingAction,
    repo_root: []u8,
    old_branch: []u8,
    new_branch: []u8,
    result: FileActionTaskResult,

    pub fn deinit(self: *SwitchBranchFinished, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        allocator.free(self.old_branch);
        allocator.free(self.new_branch);
        self.result.deinit(allocator);
        self.* = .{
            .pending = .{ .generation = 0, .kind = .switch_branch },
            .repo_root = &.{},
            .old_branch = &.{},
            .new_branch = &.{},
            .result = .ok,
        };
    }
};

pub const FileActionTaskResult = union(enum) {
    ok,
    ok_static: []const u8,
    failed: []u8,
    failed_static: []const u8,

    pub fn deinit(self: FileActionTaskResult, allocator: std.mem.Allocator) void {
        switch (self) {
            .ok, .ok_static, .failed_static => {},
            .failed => |message| allocator.free(message),
        }
    }
};

pub const PushCredentials = struct {
    username: []u8,
    password: []u8,

    pub fn deinit(self: *PushCredentials, allocator: std.mem.Allocator) void {
        secureFree(allocator, self.username);
        secureFree(allocator, self.password);
        self.* = .{ .username = &.{}, .password = &.{} };
    }
};

/// Wipe before free because these buffers may contain one-shot HTTPS tokens.
/// A normal `@memset` before free can be optimized away in release builds.
pub fn secureFree(allocator: std.mem.Allocator, bytes: []u8) void {
    if (bytes.len == 0) return;
    std.crypto.secureZero(u8, bytes);
    allocator.free(bytes);
}

/// Async task for `git add -- <path>`.
///
/// The task owns copied repo/path strings because action requests cross the
/// update boundary. The result moves `path` back to App for user-facing status
/// messages.
pub fn StageFileTask(comptime Msg: type) type {
    return struct {
        pending: PendingAction,
        repo_root: []u8,
        path: []u8,
        label: []u8,
        target_kind: git_ops.TargetKind,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer {
                if (task.repo_root.len > 0) allocator.free(task.repo_root);
                if (task.path.len > 0) allocator.free(task.path);
                if (task.label.len > 0) allocator.free(task.label);
                allocator.destroy(task);
            }

            const result = runStageTarget(task.repo_root, task.path, task.target_kind, allocator, io);
            const path = task.label;
            task.label = &.{};
            const repo_root = task.repo_root;
            task.repo_root = &.{};

            return Msg.actionFinished(.{ .stage_file = StageFileFinished{
                .pending = task.pending,
                .repo_root = repo_root,
                .path = path,
                .result = result,
            } });
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer {
                if (task.repo_root.len > 0) allocator.free(task.repo_root);
                if (task.path.len > 0) allocator.free(task.path);
                if (task.label.len > 0) allocator.free(task.label);
                allocator.destroy(task);
            }

            const path = task.label;
            task.label = &.{};
            const repo_root = task.repo_root;
            task.repo_root = &.{};

            return Msg.actionFinished(.{ .stage_file = StageFileFinished{
                .pending = task.pending,
                .repo_root = repo_root,
                .path = path,
                .result = .{ .failed_static = taskFailureMessage(failure) },
            } });
        }
    };
}

/// Async task for `git restore --staged -- <path>`.
///
/// Kept separate from StageFileTask for now so operation-specific status text
/// stays obvious; a shared helper can be introduced once a third file action
/// proves the common shape.
pub fn UnstageFileTask(comptime Msg: type) type {
    return struct {
        pending: PendingAction,
        repo_root: []u8,
        path: []u8,
        label: []u8,
        target_kind: git_ops.TargetKind,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer {
                if (task.repo_root.len > 0) allocator.free(task.repo_root);
                if (task.path.len > 0) allocator.free(task.path);
                if (task.label.len > 0) allocator.free(task.label);
                allocator.destroy(task);
            }

            const result = runUnstageTarget(task.repo_root, task.path, task.target_kind, allocator, io);
            const path = task.label;
            task.label = &.{};
            const repo_root = task.repo_root;
            task.repo_root = &.{};

            return Msg.actionFinished(.{ .unstage_file = UnstageFileFinished{
                .pending = task.pending,
                .repo_root = repo_root,
                .path = path,
                .result = result,
            } });
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer {
                if (task.repo_root.len > 0) allocator.free(task.repo_root);
                if (task.path.len > 0) allocator.free(task.path);
                if (task.label.len > 0) allocator.free(task.label);
                allocator.destroy(task);
            }

            const path = task.label;
            task.label = &.{};
            const repo_root = task.repo_root;
            task.repo_root = &.{};

            return Msg.actionFinished(.{ .unstage_file = UnstageFileFinished{
                .pending = task.pending,
                .repo_root = repo_root,
                .path = path,
                .result = .{ .failed_static = taskFailureMessage(failure) },
            } });
        }
    };
}

/// Async task for `git apply --cached -` with a single-hunk patch.
///
/// The patch is generated before spawning so the task never re-reads App state
/// after the user may have moved to another file or repository.
pub fn StageHunkTask(comptime Msg: type) type {
    return struct {
        pending: PendingAction,
        repo_root: []u8,
        path: []u8,
        patch: []u8,
        hunk_index: usize,
        session_mark_mutation: git_ops.SessionHunkMarkMutation,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer {
                if (task.repo_root.len > 0) allocator.free(task.repo_root);
                if (task.path.len > 0) allocator.free(task.path);
                allocator.free(task.patch);
                allocator.destroy(task);
            }

            const result = runStageHunk(task.repo_root, task.patch, allocator, io);
            const repo_root = task.repo_root;
            const path = task.path;
            task.repo_root = &.{};
            task.path = &.{};

            return Msg.actionFinished(.{ .stage_hunk = StageHunkFinished{
                .pending = task.pending,
                .repo_root = repo_root,
                .path = path,
                .hunk_index = task.hunk_index,
                .session_mark_mutation = task.session_mark_mutation,
                .result = result,
            } });
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer {
                if (task.repo_root.len > 0) allocator.free(task.repo_root);
                if (task.path.len > 0) allocator.free(task.path);
                allocator.free(task.patch);
                allocator.destroy(task);
            }

            const repo_root = task.repo_root;
            const path = task.path;
            task.repo_root = &.{};
            task.path = &.{};

            return Msg.actionFinished(.{ .stage_hunk = StageHunkFinished{
                .pending = task.pending,
                .repo_root = repo_root,
                .path = path,
                .hunk_index = task.hunk_index,
                .session_mark_mutation = task.session_mark_mutation,
                .result = .{ .failed_static = taskFailureMessage(failure) },
            } });
        }
    };
}

/// Async task for `git apply --cached --reverse -` with a single-hunk patch.
pub fn UnstageHunkTask(comptime Msg: type) type {
    return struct {
        pending: PendingAction,
        repo_root: []u8,
        path: []u8,
        patch: []u8,
        hunk_index: usize,
        session_mark_mutation: git_ops.SessionHunkMarkMutation,
        reload_after_success: bool = false,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer {
                if (task.repo_root.len > 0) allocator.free(task.repo_root);
                if (task.path.len > 0) allocator.free(task.path);
                allocator.free(task.patch);
                allocator.destroy(task);
            }

            const result = runUnstageHunk(task.repo_root, task.patch, allocator, io);
            const repo_root = task.repo_root;
            const path = task.path;
            task.repo_root = &.{};
            task.path = &.{};

            return Msg.actionFinished(.{ .unstage_hunk = UnstageHunkFinished{
                .pending = task.pending,
                .repo_root = repo_root,
                .path = path,
                .hunk_index = task.hunk_index,
                .session_mark_mutation = task.session_mark_mutation,
                .reload_after_success = task.reload_after_success,
                .result = result,
            } });
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer {
                if (task.repo_root.len > 0) allocator.free(task.repo_root);
                if (task.path.len > 0) allocator.free(task.path);
                allocator.free(task.patch);
                allocator.destroy(task);
            }

            const repo_root = task.repo_root;
            const path = task.path;
            task.repo_root = &.{};
            task.path = &.{};

            return Msg.actionFinished(.{ .unstage_hunk = UnstageHunkFinished{
                .pending = task.pending,
                .repo_root = repo_root,
                .path = path,
                .hunk_index = task.hunk_index,
                .session_mark_mutation = task.session_mark_mutation,
                .reload_after_success = task.reload_after_success,
                .result = .{ .failed_static = taskFailureMessage(failure) },
            } });
        }
    };
}

/// Async task for `git restore -- <path>`.
///
/// This intentionally discards only unstaged tracked changes. Untracked file
/// deletion and staged discard need separate confirmation contracts.
pub fn DiscardFileTask(comptime Msg: type) type {
    return struct {
        pending: PendingAction,
        repo_root: []u8,
        path: []u8,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer {
                allocator.free(task.repo_root);
                if (task.path.len > 0) allocator.free(task.path);
                allocator.destroy(task);
            }

            const result = runDiscardFile(task.repo_root, task.path, allocator, io);
            const repo_root = task.repo_root;
            const path = task.path;
            task.repo_root = &.{};
            task.path = &.{};

            return Msg.actionFinished(.{ .discard_file = DiscardFileFinished{
                .pending = task.pending,
                .repo_root = repo_root,
                .path = path,
                .result = result,
            } });
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer {
                allocator.free(task.repo_root);
                if (task.path.len > 0) allocator.free(task.path);
                allocator.destroy(task);
            }

            const repo_root = task.repo_root;
            const path = task.path;
            task.repo_root = &.{};
            task.path = &.{};

            return Msg.actionFinished(.{ .discard_file = DiscardFileFinished{
                .pending = task.pending,
                .repo_root = repo_root,
                .path = path,
                .result = .{ .failed_static = taskFailureMessage(failure) },
            } });
        }
    };
}

/// Async task for `git commit -m subject [-m body]`.
///
/// The task snapshots repo/message ownership so the user can switch repository
/// while Git is running without changing where the commit is applied.
pub fn CommitTask(comptime Msg: type) type {
    return struct {
        pending: PendingAction,
        repo_root: []u8,
        subject: []u8,
        body: ?[]u8,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer {
                if (task.repo_root.len > 0) allocator.free(task.repo_root);
                allocator.free(task.subject);
                if (task.body) |body| allocator.free(body);
                allocator.destroy(task);
            }

            const result = runCommit(task.repo_root, task.subject, task.body, allocator, io);
            const repo_root = task.repo_root;
            task.repo_root = &.{};

            return Msg.actionFinished(.{ .commit = CommitFinished{
                .pending = task.pending,
                .repo_root = repo_root,
                .result = result,
            } });
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer {
                if (task.repo_root.len > 0) allocator.free(task.repo_root);
                allocator.free(task.subject);
                if (task.body) |body| allocator.free(body);
                allocator.destroy(task);
            }

            const repo_root = task.repo_root;
            task.repo_root = &.{};

            return Msg.actionFinished(.{ .commit = CommitFinished{
                .pending = task.pending,
                .repo_root = repo_root,
                .result = .{ .failed_static = taskFailureMessage(failure) },
            } });
        }
    };
}

/// Async task for commit-message assistance.
///
/// The task intentionally collects the staged diff itself before invoking the
/// user command. Running `git diff --cached` in App update handling would block
/// the UI and could mix a diff with metadata from another load generation.
pub fn CommitMessageAssistTask(comptime Msg: type) type {
    return struct {
        pending: PendingAction,
        repo_root: []u8,
        action_id: []u8,
        argv: [][]u8,
        launch_revision: u64,
        mode: CommitMessageAssistMode,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer destroyCommitMessageAssistTask(@This(), allocator, task);

            const result = runCommitMessageAssist(task.repo_root, task.action_id, task.argv, task.mode, allocator, io);
            const repo_root = task.repo_root;
            const action_id = task.action_id;
            const mode = task.mode;
            task.repo_root = &.{};
            task.action_id = &.{};
            task.mode = .generate;

            return Msg.actionFinished(.{ .assist_commit_message = CommitMessageAssistFinished{
                .pending = task.pending,
                .repo_root = repo_root,
                .action_id = action_id,
                .launch_revision = task.launch_revision,
                .mode = mode,
                .result = result,
            } });
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer destroyCommitMessageAssistTask(@This(), allocator, task);

            const repo_root = task.repo_root;
            const action_id = task.action_id;
            const mode = task.mode;
            task.repo_root = &.{};
            task.action_id = &.{};
            task.mode = .generate;

            return Msg.actionFinished(.{ .assist_commit_message = CommitMessageAssistFinished{
                .pending = task.pending,
                .repo_root = repo_root,
                .action_id = action_id,
                .launch_revision = task.launch_revision,
                .mode = mode,
                .result = .{ .failed_static = taskFailureMessage(failure) },
            } });
        }
    };
}

/// Async task for `git commit --amend -m subject [-m body]`.
pub fn AmendTask(comptime Msg: type) type {
    return struct {
        pending: PendingAction,
        repo_root: []u8,
        subject: []u8,
        body: ?[]u8,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer {
                if (task.repo_root.len > 0) allocator.free(task.repo_root);
                allocator.free(task.subject);
                if (task.body) |body| allocator.free(body);
                allocator.destroy(task);
            }

            const result = runAmend(task.repo_root, task.subject, task.body, allocator, io);
            const repo_root = task.repo_root;
            task.repo_root = &.{};

            return Msg.actionFinished(.{ .amend = AmendFinished{
                .pending = task.pending,
                .repo_root = repo_root,
                .result = result,
            } });
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer {
                if (task.repo_root.len > 0) allocator.free(task.repo_root);
                allocator.free(task.subject);
                if (task.body) |body| allocator.free(body);
                allocator.destroy(task);
            }

            const repo_root = task.repo_root;
            task.repo_root = &.{};

            return Msg.actionFinished(.{ .amend = AmendFinished{
                .pending = task.pending,
                .repo_root = repo_root,
                .result = .{ .failed_static = taskFailureMessage(failure) },
            } });
        }
    };
}

/// Async task for non-interactive `git push`.
///
/// The branch/upstream/oid snapshot is captured before confirmation and
/// rechecked by the backend immediately before pushing.
pub fn PushTask(comptime Msg: type) type {
    return struct {
        pending: PendingAction,
        mode: git_push.Mode,
        repo_root: []u8,
        branch: []u8,
        remote: []u8,
        remote_branch: []u8,
        oid: []u8,
        env_map: ?*const std.process.Environ.Map = null,
        credentials: ?PushCredentials = null,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer {
                if (task.repo_root.len > 0) allocator.free(task.repo_root);
                if (task.branch.len > 0) allocator.free(task.branch);
                if (task.remote.len > 0) allocator.free(task.remote);
                if (task.remote_branch.len > 0) allocator.free(task.remote_branch);
                allocator.free(task.oid);
                if (task.credentials) |*credentials| credentials.deinit(allocator);
                allocator.destroy(task);
            }

            const result = runPush(task.mode, task.repo_root, task.branch, task.remote, task.remote_branch, task.oid, task.env_map, if (task.credentials) |credentials| credentials else null, allocator, io);
            const mode = task.mode;
            const repo_root = task.repo_root;
            const branch = task.branch;
            const remote = task.remote;
            const remote_branch = task.remote_branch;
            const oid = task.oid;
            task.repo_root = &.{};
            task.branch = &.{};
            task.remote = &.{};
            task.remote_branch = &.{};
            task.oid = &.{};

            return Msg.actionFinished(.{ .push = PushFinished{
                .pending = task.pending,
                .mode = mode,
                .repo_root = repo_root,
                .branch = branch,
                .remote = remote,
                .remote_branch = remote_branch,
                .oid = oid,
                .result = result,
            } });
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer {
                if (task.repo_root.len > 0) allocator.free(task.repo_root);
                if (task.branch.len > 0) allocator.free(task.branch);
                if (task.remote.len > 0) allocator.free(task.remote);
                if (task.remote_branch.len > 0) allocator.free(task.remote_branch);
                allocator.free(task.oid);
                if (task.credentials) |*credentials| credentials.deinit(allocator);
                allocator.destroy(task);
            }

            const repo_root = task.repo_root;
            const mode = task.mode;
            const branch = task.branch;
            const remote = task.remote;
            const remote_branch = task.remote_branch;
            const oid = task.oid;
            task.repo_root = &.{};
            task.branch = &.{};
            task.remote = &.{};
            task.remote_branch = &.{};
            task.oid = &.{};

            return Msg.actionFinished(.{ .push = PushFinished{
                .pending = task.pending,
                .mode = mode,
                .repo_root = repo_root,
                .branch = branch,
                .remote = remote,
                .remote_branch = remote_branch,
                .oid = oid,
                .result = .{ .failed_static = taskFailureMessage(failure) },
            } });
        }
    };
}

pub fn PullTask(comptime Msg: type) type {
    return struct {
        pending: PendingAction,
        repo_root: []u8,
        branch: []u8,
        remote: []u8,
        remote_branch: []u8,
        oid: []u8,
        env_map: ?*const std.process.Environ.Map = null,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer {
                if (task.repo_root.len > 0) allocator.free(task.repo_root);
                if (task.branch.len > 0) allocator.free(task.branch);
                if (task.remote.len > 0) allocator.free(task.remote);
                if (task.remote_branch.len > 0) allocator.free(task.remote_branch);
                allocator.free(task.oid);
                allocator.destroy(task);
            }

            const result = runPullRefresh(task.repo_root, task.branch, task.remote, task.remote_branch, task.oid, task.env_map, allocator, io);
            const repo_root = task.repo_root;
            const branch = task.branch;
            const remote = task.remote;
            const remote_branch = task.remote_branch;
            const oid = task.oid;
            task.repo_root = &.{};
            task.branch = &.{};
            task.remote = &.{};
            task.remote_branch = &.{};
            task.oid = &.{};

            return Msg.actionFinished(.{ .pull = PullFinished{
                .pending = task.pending,
                .repo_root = repo_root,
                .branch = branch,
                .remote = remote,
                .remote_branch = remote_branch,
                .oid = oid,
                .result = result,
            } });
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer {
                if (task.repo_root.len > 0) allocator.free(task.repo_root);
                if (task.branch.len > 0) allocator.free(task.branch);
                if (task.remote.len > 0) allocator.free(task.remote);
                if (task.remote_branch.len > 0) allocator.free(task.remote_branch);
                allocator.free(task.oid);
                allocator.destroy(task);
            }

            const repo_root = task.repo_root;
            const branch = task.branch;
            const remote = task.remote;
            const remote_branch = task.remote_branch;
            const oid = task.oid;
            task.repo_root = &.{};
            task.branch = &.{};
            task.remote = &.{};
            task.remote_branch = &.{};
            task.oid = &.{};

            return Msg.actionFinished(.{ .pull = PullFinished{
                .pending = task.pending,
                .repo_root = repo_root,
                .branch = branch,
                .remote = remote,
                .remote_branch = remote_branch,
                .oid = oid,
                .result = .{ .failed_static = taskFailureMessage(failure) },
            } });
        }
    };
}

pub fn FetchTask(comptime Msg: type) type {
    return struct {
        pending: PendingAction,
        repo_root: []u8,
        remote: []u8,
        env_map: ?*const std.process.Environ.Map = null,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer {
                if (task.repo_root.len > 0) allocator.free(task.repo_root);
                allocator.free(task.remote);
                allocator.destroy(task);
            }

            const result = runFetch(task.repo_root, task.remote, task.env_map, allocator, io);
            const repo_root = task.repo_root;
            const remote = task.remote;
            task.repo_root = &.{};
            task.remote = &.{};

            return Msg.actionFinished(.{ .fetch = FetchFinished{
                .pending = task.pending,
                .repo_root = repo_root,
                .remote = remote,
                .result = result,
            } });
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer {
                if (task.repo_root.len > 0) allocator.free(task.repo_root);
                allocator.free(task.remote);
                allocator.destroy(task);
            }

            const repo_root = task.repo_root;
            const remote = task.remote;
            task.repo_root = &.{};
            task.remote = &.{};

            return Msg.actionFinished(.{ .fetch = FetchFinished{
                .pending = task.pending,
                .repo_root = repo_root,
                .remote = remote,
                .result = .{ .failed_static = taskFailureMessage(failure) },
            } });
        }
    };
}

pub fn SwitchBranchTask(comptime Msg: type) type {
    return struct {
        pending: PendingAction,
        repo_root: []u8,
        expected_branch: []u8,
        expected_oid: []u8,
        target_branch: []u8,
        target_oid: []u8,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer {
                if (task.repo_root.len > 0) allocator.free(task.repo_root);
                if (task.expected_branch.len > 0) allocator.free(task.expected_branch);
                allocator.free(task.expected_oid);
                if (task.target_branch.len > 0) allocator.free(task.target_branch);
                allocator.free(task.target_oid);
                allocator.destroy(task);
            }

            const result = runSwitchBranch(task.repo_root, task.expected_branch, task.expected_oid, task.target_branch, task.target_oid, allocator, io);
            const repo_root = task.repo_root;
            const old_branch = task.expected_branch;
            const new_branch = task.target_branch;
            task.repo_root = &.{};
            task.expected_branch = &.{};
            task.target_branch = &.{};

            return Msg.actionFinished(.{ .switch_branch = SwitchBranchFinished{
                .pending = task.pending,
                .repo_root = repo_root,
                .old_branch = old_branch,
                .new_branch = new_branch,
                .result = result,
            } });
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer {
                if (task.repo_root.len > 0) allocator.free(task.repo_root);
                if (task.expected_branch.len > 0) allocator.free(task.expected_branch);
                allocator.free(task.expected_oid);
                if (task.target_branch.len > 0) allocator.free(task.target_branch);
                allocator.free(task.target_oid);
                allocator.destroy(task);
            }

            const repo_root = task.repo_root;
            const old_branch = task.expected_branch;
            const new_branch = task.target_branch;
            task.repo_root = &.{};
            task.expected_branch = &.{};
            task.target_branch = &.{};

            return Msg.actionFinished(.{ .switch_branch = SwitchBranchFinished{
                .pending = task.pending,
                .repo_root = repo_root,
                .old_branch = old_branch,
                .new_branch = new_branch,
                .result = .{ .failed_static = taskFailureMessage(failure) },
            } });
        }
    };
}

fn taskFailureMessage(failure: chasen.TaskFailure) []const u8 {
    return switch (failure) {
        .start_failed => |message| message,
        .runtime_abandoned => "runtime shutting down",
    };
}

pub fn runStageFile(repo_root: []const u8, path: []const u8, allocator: std.mem.Allocator, io: std.Io) FileActionTaskResult {
    return runOperationMapped("Stage", .{
        .repo_root = repo_root,
        .kind = .{ .stage_file = path },
    }, allocator, io);
}

pub fn runStageTarget(repo_root: []const u8, path: []const u8, target_kind: git_ops.TargetKind, allocator: std.mem.Allocator, io: std.Io) FileActionTaskResult {
    return switch (target_kind) {
        .repository => runOperationMapped("Stage", .{
            .repo_root = repo_root,
            .kind = .stage_all,
        }, allocator, io),
        .file, .directory => runStageFile(repo_root, path, allocator, io),
    };
}

pub fn runUnstageFile(repo_root: []const u8, path: []const u8, allocator: std.mem.Allocator, io: std.Io) FileActionTaskResult {
    return runOperationMapped("Unstage", .{
        .repo_root = repo_root,
        .kind = .{ .unstage_file = path },
    }, allocator, io);
}

pub fn runUnstageTarget(repo_root: []const u8, path: []const u8, target_kind: git_ops.TargetKind, allocator: std.mem.Allocator, io: std.Io) FileActionTaskResult {
    return switch (target_kind) {
        .repository => runOperationMapped("Unstage", .{
            .repo_root = repo_root,
            .kind = .unstage_all,
        }, allocator, io),
        .file, .directory => runUnstageFile(repo_root, path, allocator, io),
    };
}

pub fn runStageHunk(repo_root: []const u8, patch: []const u8, allocator: std.mem.Allocator, io: std.Io) FileActionTaskResult {
    return runOperationMapped("Stage hunk", .{
        .repo_root = repo_root,
        .kind = .{ .stage_patch = .{ .patch = patch } },
    }, allocator, io);
}

pub fn runUnstageHunk(repo_root: []const u8, patch: []const u8, allocator: std.mem.Allocator, io: std.Io) FileActionTaskResult {
    return runOperationMapped("Unstage hunk", .{
        .repo_root = repo_root,
        .kind = .{ .unstage_patch = .{ .patch = patch } },
    }, allocator, io);
}

pub fn runDiscardFile(repo_root: []const u8, path: []const u8, allocator: std.mem.Allocator, io: std.Io) FileActionTaskResult {
    return runOperationMapped("Discard", .{
        .repo_root = repo_root,
        .kind = .{ .discard_file = path },
    }, allocator, io);
}

pub fn runCommit(repo_root: []const u8, subject: []const u8, body: ?[]const u8, allocator: std.mem.Allocator, io: std.Io) FileActionTaskResult {
    return runOperationMapped("Commit", .{
        .repo_root = repo_root,
        .kind = .{ .commit = .{ .subject = subject, .body = body } },
    }, allocator, io);
}

fn destroyCommitMessageAssistTask(comptime Task: type, allocator: std.mem.Allocator, task: *Task) void {
    if (task.repo_root.len > 0) allocator.free(task.repo_root);
    if (task.action_id.len > 0) allocator.free(task.action_id);
    for (task.argv) |arg| allocator.free(arg);
    allocator.free(task.argv);
    task.mode.deinit(allocator);
    allocator.destroy(task);
}

const staged_diff_json_limit = 256 * 1024;
// Capture a larger diff before truncating the JSON payload. This lets normal
// large diffs produce a truncated prompt while still bounding accidental huge
// stdout from Git before it enters JSON construction.
const staged_diff_capture_limit = 4 * 1024 * 1024;

pub fn runCommitMessageAssist(repo_root: []const u8, action_id: []const u8, argv: []const []const u8, mode: CommitMessageAssistMode, allocator: std.mem.Allocator, io: std.Io) CommitMessageActionResult {
    const staged_diff = collectStagedDiff(allocator, repo_root, io) catch |err|
        return stagedDiffFailure(allocator, err);
    var owned_staged_diff = staged_diff;
    defer owned_staged_diff.deinit(allocator);

    const stdin_json = switch (mode) {
        .generate => buildStagedDiffJson(allocator, repo_root, owned_staged_diff.diff, owned_staged_diff.truncated),
        .improve => |snapshot| buildCommitMessageContextJson(allocator, repo_root, snapshot.subject, snapshot.body, owned_staged_diff.diff, owned_staged_diff.truncated),
    } catch |err| return allocFailure(allocator, "commit message action json failed: {s}", .{@errorName(err)});
    defer allocator.free(stdin_json);

    const action_result = external_action.run(allocator, io, .{
        .id = .custom,
        .argv = argv,
        .stdin_json = stdin_json,
        .cwd = repo_root,
    }) catch |err| return allocFailure(allocator, "external action failed: {s}", .{@errorName(err)});
    var owned_action_result = action_result;
    defer owned_action_result.deinit(allocator);

    return switch (owned_action_result) {
        .ok => |*output| parseCommitMessageDraft(allocator, output.stdout, owned_staged_diff.truncated),
        .failed => |*output| actionOutputFailure(allocator, action_id, output.*),
        .spawn_failed => |*output| actionOutputFailure(allocator, action_id, output.*),
        .runner_failed => |*output| actionOutputFailure(allocator, action_id, output.*),
    };
}

fn stagedDiffFailure(allocator: std.mem.Allocator, err: anyerror) CommitMessageActionResult {
    return switch (err) {
        error.NoStagedChanges => .{ .failed_static = "no staged changes" },
        error.InvalidStagedDiff => .{ .failed_static = "staged diff is not valid UTF-8" },
        error.StagedDiffFailed => .{ .failed_static = "staged diff failed" },
        else => allocFailure(allocator, "staged diff failed: {s}", .{@errorName(err)}),
    };
}

const StagedDiffPayload = struct {
    diff: []u8,
    truncated: bool,

    pub fn deinit(self: *StagedDiffPayload, allocator: std.mem.Allocator) void {
        if (self.diff.len > 0) allocator.free(self.diff);
        self.* = .{ .diff = &.{}, .truncated = false };
    }
};

fn collectStagedDiff(allocator: std.mem.Allocator, repo_root: []const u8, io: std.Io) !StagedDiffPayload {
    const diff_argv = [_][]const u8{ "git", "diff", "--cached", "--no-ext-diff", "--no-color" };
    const diff_result = process_runner.runCaptured(allocator, io, .{
        .argv = &diff_argv,
        .cwd = .{ .path = repo_root },
        .stdout_limit = .limited(staged_diff_capture_limit),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| return err;
    defer diff_result.deinit(allocator);

    switch (diff_result.term) {
        .exited => |code| if (code != 0) return error.StagedDiffFailed,
        else => return error.StagedDiffFailed,
    }

    if (validateStagedDiffForJson(diff_result.stdout)) |failure| {
        if (std.mem.eql(u8, failure, "no staged changes")) return error.NoStagedChanges;
        return error.InvalidStagedDiff;
    }

    const truncate = truncateDiff(diff_result.stdout, staged_diff_json_limit);
    return .{
        .diff = try allocator.dupe(u8, truncate.bytes),
        .truncated = truncate.truncated,
    };
}

const TruncatedDiff = struct {
    bytes: []const u8,
    truncated: bool,
};

fn truncateDiff(bytes: []const u8, limit: usize) TruncatedDiff {
    if (bytes.len <= limit) return .{ .bytes = bytes, .truncated = false };

    var end = limit;
    while (end > 0 and !std.unicode.utf8ValidateSlice(bytes[0..end])) : (end -= 1) {}
    if (end == 0) return .{ .bytes = bytes[0..0], .truncated = true };
    if (std.mem.lastIndexOfScalar(u8, bytes[0..end], '\n')) |newline| {
        if (newline > 0) end = newline + 1;
    }
    return .{ .bytes = bytes[0..end], .truncated = true };
}

fn validateStagedDiffForJson(diff: []const u8) ?[]const u8 {
    if (std.mem.trim(u8, diff, " \t\r\n").len == 0) return "no staged changes";
    if (!std.unicode.utf8ValidateSlice(diff)) return "staged diff is not valid UTF-8";
    return null;
}

fn buildStagedDiffJson(allocator: std.mem.Allocator, repo_root: []const u8, diff: []const u8, truncated: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    try out.writer.writeAll("{\"schema_version\":1,\"kind\":\"staged_diff\",\"repo_root\":");
    try context_export.writeStringValue(&out.writer, repo_root);
    try out.writer.writeAll(",\"source\":\"worktree\",\"diff_format\":\"git_unified\",\"truncated\":");
    try out.writer.writeAll(if (truncated) "true" else "false");
    try out.writer.writeAll(",\"diff\":");
    try context_export.writeStringValue(&out.writer, diff);
    try out.writer.writeAll("}\n");
    return try out.toOwnedSlice();
}

fn buildCommitMessageContextJson(allocator: std.mem.Allocator, repo_root: []const u8, subject: []const u8, body: []const u8, diff: []const u8, truncated: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    try out.writer.writeAll("{\"schema_version\":1,\"kind\":\"commit_message_context\",\"repo_root\":");
    try context_export.writeStringValue(&out.writer, repo_root);
    try out.writer.writeAll(",\"source\":\"worktree\",\"draft\":{\"subject\":");
    try context_export.writeStringValue(&out.writer, subject);
    try out.writer.writeAll(",\"body\":");
    try context_export.writeStringValue(&out.writer, body);
    try out.writer.writeAll("},\"staged_diff\":{\"diff_format\":\"git_unified\",\"truncated\":");
    try out.writer.writeAll(if (truncated) "true" else "false");
    try out.writer.writeAll(",\"diff\":");
    try context_export.writeStringValue(&out.writer, diff);
    try out.writer.writeAll("}}\n");
    return try out.toOwnedSlice();
}

fn parseCommitMessageDraft(allocator: std.mem.Allocator, stdout: []const u8, truncated_input: bool) CommitMessageActionResult {
    const trimmed = trimTrailingNewlines(stdout);
    if (trimmed.len == 0) return .{ .failed_static = "generated commit message is empty" };
    if (!std.unicode.utf8ValidateSlice(trimmed)) return .{ .failed_static = "generated commit message is not valid UTF-8" };
    if (containsDisallowedControl(trimmed)) return .{ .failed_static = "generated commit message contains control characters" };

    const first_newline = std.mem.indexOfScalar(u8, trimmed, '\n');
    const subject_raw = if (first_newline) |index| trimmed[0..index] else trimmed;
    const body_raw = if (first_newline) |index| std.mem.trim(u8, trimmed[index + 1 ..], " \t\r\n") else "";
    const subject = std.mem.trim(u8, subject_raw, " \t\r");
    if (subject.len == 0) return .{ .failed_static = "generated commit message subject is empty" };

    const subject_owned = allocator.dupe(u8, subject) catch return .{ .failed_static = "generated commit message failed: OutOfMemory" };
    const body_owned = if (body_raw.len == 0) null else allocator.dupe(u8, body_raw) catch {
        allocator.free(subject_owned);
        return .{ .failed_static = "generated commit message failed: OutOfMemory" };
    };

    return .{ .ok = .{
        .subject = subject_owned,
        .body = body_owned,
        .truncated = truncated_input,
    } };
}

fn trimTrailingNewlines(text: []const u8) []const u8 {
    var end = text.len;
    while (end > 0 and (text[end - 1] == '\n' or text[end - 1] == '\r')) : (end -= 1) {}
    return text[0..end];
}

fn containsDisallowedControl(text: []const u8) bool {
    var iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (iter.nextCodepoint()) |codepoint| {
        if (codepoint == '\n') continue;
        if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint <= 0x9f)) return true;
    }
    return false;
}

fn actionOutputFailure(allocator: std.mem.Allocator, action_id: []const u8, output: external_action.CommandOutput) CommitMessageActionResult {
    if (output.message.len > 0) return allocFailure(allocator, "{s}: {s}", .{ action_id, output.message });
    if (output.stderr.len > 0) return allocFailure(allocator, "{s}: {s}", .{ action_id, shortLine(output.stderr) });
    return allocFailure(allocator, "{s} failed", .{action_id});
}

fn shortLine(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const line = if (std.mem.indexOfScalar(u8, trimmed, '\n')) |index| trimmed[0..index] else trimmed;
    return if (line.len > 160) line[0..160] else line;
}

fn allocFailure(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) CommitMessageActionResult {
    const message = std.fmt.allocPrint(allocator, fmt, args) catch return .{ .failed_static = "commit message action failed: OutOfMemory" };
    return .{ .failed = message };
}

pub fn runAmend(repo_root: []const u8, subject: []const u8, body: ?[]const u8, allocator: std.mem.Allocator, io: std.Io) FileActionTaskResult {
    return runOperationMapped("Amend", .{
        .repo_root = repo_root,
        .kind = .{ .amend = .{ .subject = subject, .body = body } },
    }, allocator, io);
}

pub fn runPush(mode: git_push.Mode, repo_root: []const u8, branch: []const u8, remote: []const u8, remote_branch: []const u8, oid: []const u8, env_map: ?*const std.process.Environ.Map, credentials: ?PushCredentials, allocator: std.mem.Allocator, io: std.Io) FileActionTaskResult {
    return runOperationMapped("Push", .{
        .repo_root = repo_root,
        .kind = .{ .push = .{
            .mode = mode,
            .branch = branch,
            .remote = remote,
            .remote_branch = remote_branch,
            .oid = oid,
            .credentials = if (credentials) |credential| .{
                .username = credential.username,
                .password = credential.password,
            } else null,
        } },
        .env_map = env_map,
    }, allocator, io);
}

pub fn runPullRefresh(repo_root: []const u8, branch: []const u8, remote: []const u8, remote_branch: []const u8, oid: []const u8, env_map: ?*const std.process.Environ.Map, allocator: std.mem.Allocator, io: std.Io) FileActionTaskResult {
    return runOperationMapped("Pull", .{
        .repo_root = repo_root,
        .kind = .{ .pull_refresh_ff_only = .{
            .branch = branch,
            .remote = remote,
            .remote_branch = remote_branch,
            .oid = oid,
        } },
        .env_map = env_map,
    }, allocator, io);
}

pub fn runFetch(repo_root: []const u8, remote: []const u8, env_map: ?*const std.process.Environ.Map, allocator: std.mem.Allocator, io: std.Io) FileActionTaskResult {
    return runOperationMapped("Fetch", .{
        .repo_root = repo_root,
        .kind = .{ .fetch = .{ .remote = remote } },
        .env_map = env_map,
    }, allocator, io);
}

pub fn runSwitchBranch(repo_root: []const u8, expected_branch: []const u8, expected_oid: []const u8, target_branch: []const u8, target_oid: []const u8, allocator: std.mem.Allocator, io: std.Io) FileActionTaskResult {
    return runOperationMapped("Branch switch", .{
        .repo_root = repo_root,
        .kind = .{ .switch_branch = .{
            .expected_branch = expected_branch,
            .expected_oid = expected_oid,
            .target_branch = target_branch,
            .target_oid = target_oid,
        } },
    }, allocator, io);
}

fn runOperationMapped(comptime prefix: []const u8, request: git_backend.OperationRequest, allocator: std.mem.Allocator, io: std.Io) FileActionTaskResult {
    var local_backend: git_backend.LocalCommandBackend = .{};
    const raw_result = local_backend.backend().runOperation(allocator, io, request) catch |err| {
        return .{
            .failed = std.fmt.allocPrint(allocator, prefix ++ " failed: {s}", .{@errorName(err)}) catch
                return .{ .failed_static = prefix ++ " failed: OutOfMemory" },
        };
    };
    return switch (raw_result) {
        .ok => .ok,
        .ok_static => |message| .{ .ok_static = message },
        .failed => |message| .{ .failed = message },
        .failed_static => |message| .{ .failed_static = message },
    };
}

test "ActionState tracks current pending action" {
    var state: ActionState = .{};

    const first = state.begin(.assist_commit_message);
    try std.testing.expect(state.isCurrent(first));
    try std.testing.expect(!state.isAccepted(first));
    try std.testing.expect(!state.finish(first));

    const second = state.begin(.stage_file);
    try std.testing.expect(!state.isCurrent(first));
    try std.testing.expect(state.isCurrent(second));

    try std.testing.expect(!state.acceptLaunch(first));
    try std.testing.expect(state.acceptLaunch(second));
    try std.testing.expect(state.isAccepted(second));
    try std.testing.expect(!state.acceptLaunch(second));
    try std.testing.expect(!state.finish(first));
    try std.testing.expect(state.finish(second));
    try std.testing.expect(state.pending == null);
}

test "ActionState cancels only exact preparing owner" {
    var state: ActionState = .{};

    const preparing = state.begin(.pull);
    try std.testing.expect(!state.cancelPreparing(.{ .generation = preparing.generation + 1, .kind = preparing.kind }));
    try std.testing.expect(state.cancelPreparing(preparing));
    try std.testing.expect(state.pending == null);

    const accepted = state.begin(.fetch);
    try std.testing.expect(state.acceptLaunch(accepted));
    try std.testing.expect(!state.cancelPreparing(accepted));
    try std.testing.expect(state.isAccepted(accepted));
}

test "parseCommitMessageDraft splits subject and body" {
    var result = parseCommitMessageDraft(std.testing.allocator, "Add commit generator\n\nUse staged diff input.\n", false);
    defer result.deinit(std.testing.allocator);

    switch (result) {
        .ok => |message| {
            try std.testing.expectEqualStrings("Add commit generator", message.subject);
            try std.testing.expectEqualStrings("Use staged diff input.", message.body.?);
            try std.testing.expect(!message.truncated);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseCommitMessageDraft rejects control characters" {
    var result = parseCommitMessageDraft(std.testing.allocator, "Bad \x1b[31mmessage", false);
    defer result.deinit(std.testing.allocator);

    switch (result) {
        .failed_static => |message| try std.testing.expectEqualStrings("generated commit message contains control characters", message),
        else => return error.TestUnexpectedResult,
    }
}

test "buildStagedDiffJson escapes diff content" {
    const diff =
        \\diff --git a/a.zig b/a.zig
        \\+const text = "quoted\\value";
        \\
    ;
    const json = try buildStagedDiffJson(std.testing.allocator, "/repo", diff, true);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"staged_diff\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"truncated\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\\\"quoted") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "value\\\"") != null);
}

test "buildCommitMessageContextJson includes draft and staged diff" {
    const diff =
        \\diff --git a/a.zig b/a.zig
        \\+const text = "quoted\\value";
        \\
    ;
    const json = try buildCommitMessageContextJson(std.testing.allocator, "/repo", "Draft subject", "Draft body", diff, true);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"commit_message_context\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"subject\":\"Draft subject\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"body\":\"Draft body\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"staged_diff\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"truncated\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\\\"quoted") != null);
}

test "truncateDiff keeps valid utf8 prefix" {
    const text = "line1\nline2\n日本語\nline4\n";
    const truncated = truncateDiff(text, "line1\nline2\n日".len);
    try std.testing.expect(truncated.truncated);
    try std.testing.expect(std.unicode.utf8ValidateSlice(truncated.bytes));
}

test "validateStagedDiffForJson rejects empty and invalid utf8 diffs" {
    try std.testing.expectEqualStrings("no staged changes", validateStagedDiffForJson("").?);
    const invalid = [_]u8{ 'd', 'i', 'f', 'f', '\n', 0xff };
    try std.testing.expectEqualStrings("staged diff is not valid UTF-8", validateStagedDiffForJson(&invalid).?);
    try std.testing.expect(validateStagedDiffForJson("diff --git a/a b/a\n+ok\n") == null);
}

const FileTaskTestActionMsg = union(enum) {
    stage_file: StageFileFinished,
    unstage_file: UnstageFileFinished,
};

const FileTaskTestMsg = union(enum) {
    action: FileTaskTestActionMsg,

    pub fn actionFinished(msg: FileTaskTestActionMsg) @This() {
        return .{ .action = msg };
    }
};

fn makeStageFileTaskForTest(allocator: std.mem.Allocator, pending: PendingAction) !*StageFileTask(FileTaskTestMsg) {
    const Task = StageFileTask(FileTaskTestMsg);
    const task = try allocator.create(Task);
    task.* = .{
        .pending = pending,
        .repo_root = try allocator.dupe(u8, "/__gitframe_missing_repo__"),
        .path = try allocator.dupe(u8, "src/main.zig"),
        .label = try allocator.dupe(u8, "src/main.zig"),
        .target_kind = .file,
    };
    return task;
}

fn makeUnstageFileTaskForTest(allocator: std.mem.Allocator, pending: PendingAction) !*UnstageFileTask(FileTaskTestMsg) {
    const Task = UnstageFileTask(FileTaskTestMsg);
    const task = try allocator.create(Task);
    task.* = .{
        .pending = pending,
        .repo_root = try allocator.dupe(u8, "/__gitframe_missing_repo__"),
        .path = try allocator.dupe(u8, "src/main.zig"),
        .label = try allocator.dupe(u8, "src/main.zig"),
        .target_kind = .file,
    };
    return task;
}

fn expectStageFileFinished(msg: FileTaskTestMsg) StageFileFinished {
    return switch (msg) {
        .action => |action| switch (action) {
            .stage_file => |payload| payload,
            else => unreachable,
        },
    };
}

fn expectUnstageFileFinished(msg: FileTaskTestMsg) UnstageFileFinished {
    return switch (msg) {
        .action => |action| switch (action) {
            .unstage_file => |payload| payload,
            else => unreachable,
        },
    };
}

test "StageFileTask run frees borrowed command path and moves label" {
    const allocator = std.testing.allocator;
    const Task = StageFileTask(FileTaskTestMsg);
    const task = try makeStageFileTaskForTest(allocator, .{ .generation = 11, .kind = .stage_file });

    var finished = expectStageFileFinished(Task.run(task, allocator, std.testing.io));
    defer finished.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 11), finished.pending.generation);
    try std.testing.expectEqual(ActionKind.stage_file, finished.pending.kind);
    try std.testing.expectEqualStrings("/__gitframe_missing_repo__", finished.repo_root);
    try std.testing.expectEqualStrings("src/main.zig", finished.path);
    try std.testing.expectEqual(FileActionTaskResult.failed, std.meta.activeTag(finished.result));
}

test "StageFileTask failed frees borrowed command path and moves label" {
    const allocator = std.testing.allocator;
    const Task = StageFileTask(FileTaskTestMsg);
    const task = try makeStageFileTaskForTest(allocator, .{ .generation = 12, .kind = .stage_file });

    var finished = expectStageFileFinished(Task.failed(task, .{ .start_failed = "OutOfMemory" }, allocator));
    defer finished.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 12), finished.pending.generation);
    try std.testing.expectEqual(ActionKind.stage_file, finished.pending.kind);
    try std.testing.expectEqualStrings("/__gitframe_missing_repo__", finished.repo_root);
    try std.testing.expectEqualStrings("src/main.zig", finished.path);
    try std.testing.expectEqualStrings("OutOfMemory", switch (finished.result) {
        .failed_static => |message| message,
        else => return error.UnexpectedResult,
    });
}

test "UnstageFileTask run frees borrowed command path and moves label" {
    const allocator = std.testing.allocator;
    const Task = UnstageFileTask(FileTaskTestMsg);
    const task = try makeUnstageFileTaskForTest(allocator, .{ .generation = 13, .kind = .unstage_file });

    var finished = expectUnstageFileFinished(Task.run(task, allocator, std.testing.io));
    defer finished.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 13), finished.pending.generation);
    try std.testing.expectEqual(ActionKind.unstage_file, finished.pending.kind);
    try std.testing.expectEqualStrings("/__gitframe_missing_repo__", finished.repo_root);
    try std.testing.expectEqualStrings("src/main.zig", finished.path);
    try std.testing.expectEqual(FileActionTaskResult.failed, std.meta.activeTag(finished.result));
}

test "UnstageFileTask failed frees borrowed command path and moves label" {
    const allocator = std.testing.allocator;
    const Task = UnstageFileTask(FileTaskTestMsg);
    const task = try makeUnstageFileTaskForTest(allocator, .{ .generation = 14, .kind = .unstage_file });

    var finished = expectUnstageFileFinished(Task.failed(task, .{ .start_failed = "OutOfMemory" }, allocator));
    defer finished.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 14), finished.pending.generation);
    try std.testing.expectEqual(ActionKind.unstage_file, finished.pending.kind);
    try std.testing.expectEqualStrings("/__gitframe_missing_repo__", finished.repo_root);
    try std.testing.expectEqualStrings("src/main.zig", finished.path);
    try std.testing.expectEqualStrings("OutOfMemory", switch (finished.result) {
        .failed_static => |message| message,
        else => return error.UnexpectedResult,
    });
}

test "StageHunkTask failed preserves identity and transfers moved fields" {
    const TestActionMsg = union(enum) {
        stage_hunk: StageHunkFinished,
    };
    const TestMsg = union(enum) {
        action: TestActionMsg,

        pub fn actionFinished(msg: TestActionMsg) @This() {
            return .{ .action = msg };
        }
    };
    const Task = StageHunkTask(TestMsg);
    const allocator = std.testing.allocator;
    const mark_key: git_ops.SessionHunkMarkKey = .{
        .content = .{
            .repo_epoch = 2,
            .root_identity = null,
            .source = .init(.unstaged),
            .source_session_revision = 4,
            .display = .{ .loaded = .init("diff") },
        },
        .display_hunk_index = 3,
    };

    const task = try allocator.create(Task);
    task.* = .{
        .pending = .{ .generation = 7, .kind = .stage_hunk },
        .repo_root = try allocator.dupe(u8, "/repo"),
        .path = try allocator.dupe(u8, "src/main.zig"),
        .patch = try allocator.dupe(u8, "patch"),
        .hunk_index = 3,
        .session_mark_mutation = .{ .add = mark_key },
    };

    const msg = Task.failed(task, .{ .start_failed = "OutOfMemory" }, allocator);
    var finished = switch (msg) {
        .action => |action| switch (action) {
            .stage_hunk => |payload| payload,
        },
    };
    defer finished.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 7), finished.pending.generation);
    try std.testing.expectEqual(ActionKind.stage_hunk, finished.pending.kind);
    try std.testing.expectEqual(@as(usize, 3), finished.hunk_index);
    try std.testing.expect(finished.session_mark_mutation == .add);
    try std.testing.expect(finished.session_mark_mutation.add.eql(mark_key));
    try std.testing.expectEqualStrings("/repo", finished.repo_root);
    try std.testing.expectEqualStrings("src/main.zig", finished.path);
    try std.testing.expectEqualStrings("OutOfMemory", switch (finished.result) {
        .failed_static => |message| message,
        else => return error.UnexpectedResult,
    });
}

test "runOperationMapped preserves action failure prefixes" {
    var result = runStageFile("/__gitframe_missing_repo__", "src/main.zig", std.testing.allocator, std.testing.io);
    defer result.deinit(std.testing.allocator);

    const message = switch (result) {
        .failed => |text| text,
        else => return error.UnexpectedResult,
    };
    try std.testing.expect(std.mem.startsWith(u8, message, "Stage failed: "));

    var commit_result = runCommit("/__gitframe_missing_repo__", "subject", null, std.testing.allocator, std.testing.io);
    defer commit_result.deinit(std.testing.allocator);

    const commit_message = switch (commit_result) {
        .failed => |text| text,
        else => return error.UnexpectedResult,
    };
    try std.testing.expect(std.mem.startsWith(u8, commit_message, "Commit failed: "));
}
