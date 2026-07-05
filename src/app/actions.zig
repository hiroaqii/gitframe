const std = @import("std");
const chasen = @import("chasen");
const git_backend = @import("../git/backend.zig");
const git_ops = @import("git_ops.zig");

/// Git operation categories that can become App-facing actions.
///
/// This is intentionally a taxonomy, not an executable backend API. Concrete
/// requests/results live next to the first implementation of each operation.
pub const ActionKind = enum {
    refresh_status,
    stage_file,
    unstage_file,
    stage_hunk,
    unstage_hunk,
    discard_file,
    commit,
    amend,
    push,
    pull,
    fetch,
    switch_branch,
};

pub const PendingAction = struct {
    generation: u64,
    kind: ActionKind,
};

/// Small App-facing receiver for future Git actions.
///
/// Keep this limited to in-flight ownership. Result text remains in App's
/// status message until concrete operation result ownership exists.
pub const ActionState = struct {
    pending: ?PendingAction = null,
    generation: u64 = 0,

    pub fn begin(self: *ActionState, kind: ActionKind) PendingAction {
        self.generation +%= 1;
        const pending: PendingAction = .{
            .generation = self.generation,
            .kind = kind,
        };
        self.pending = pending;
        return pending;
    }

    pub fn isCurrent(self: *const ActionState, pending: PendingAction) bool {
        const current = self.pending orelse return false;
        return current.generation == pending.generation and current.kind == pending.kind;
    }

    pub fn finish(self: *ActionState, pending: PendingAction) bool {
        if (!self.isCurrent(pending)) return false;
        self.pending = null;
        return true;
    }

    pub fn clear(self: *ActionState) void {
        self.pending = null;
    }
};

pub const StageFileFinished = struct {
    pending: PendingAction,
    path: []u8,
    result: FileActionTaskResult,

    pub fn deinit(self: *StageFileFinished, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.result.deinit(allocator);
        self.* = .{
            .pending = .{ .generation = 0, .kind = .stage_file },
            .path = &.{},
            .result = .ok,
        };
    }
};

pub const UnstageFileFinished = struct {
    pending: PendingAction,
    path: []u8,
    result: FileActionTaskResult,

    pub fn deinit(self: *UnstageFileFinished, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.result.deinit(allocator);
        self.* = .{
            .pending = .{ .generation = 0, .kind = .unstage_file },
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
    mark_source: git_ops.HunkMarkSource = .session,
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
            .mark_source = .session,
            .result = .ok,
        };
    }
};

pub const UnstageHunkFinished = struct {
    pending: PendingAction,
    repo_root: []u8,
    path: []u8,
    hunk_index: usize,
    mark_source: git_ops.HunkMarkSource = .session,
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
            .mark_source = .session,
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

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer {
                allocator.free(task.repo_root);
                if (task.path.len > 0) allocator.free(task.path);
                allocator.destroy(task);
            }

            const result = runStageFile(task.repo_root, task.path, allocator, io);
            const path = task.path;
            task.path = &.{};

            return Msg.actionFinished(.{ .stage_file = StageFileFinished{
                .pending = task.pending,
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

            const path = task.path;
            task.path = &.{};

            return Msg.actionFinished(.{ .stage_file = StageFileFinished{
                .pending = task.pending,
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

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer {
                allocator.free(task.repo_root);
                if (task.path.len > 0) allocator.free(task.path);
                allocator.destroy(task);
            }

            const result = runUnstageFile(task.repo_root, task.path, allocator, io);
            const path = task.path;
            task.path = &.{};

            return Msg.actionFinished(.{ .unstage_file = UnstageFileFinished{
                .pending = task.pending,
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

            const path = task.path;
            task.path = &.{};

            return Msg.actionFinished(.{ .unstage_file = UnstageFileFinished{
                .pending = task.pending,
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
        mark_source: git_ops.HunkMarkSource = .session,

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
                .mark_source = task.mark_source,
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
                .mark_source = task.mark_source,
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
        mark_source: git_ops.HunkMarkSource = .session,
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
                .mark_source = task.mark_source,
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
                .mark_source = task.mark_source,
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

            const result = runPush(task.repo_root, task.branch, task.remote, task.remote_branch, task.oid, task.env_map, if (task.credentials) |credentials| credentials else null, allocator, io);
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
    };
}

pub fn runStageFile(repo_root: []const u8, path: []const u8, allocator: std.mem.Allocator, io: std.Io) FileActionTaskResult {
    return runOperationMapped("Stage", .{
        .repo_root = repo_root,
        .kind = .{ .stage_file = path },
    }, allocator, io);
}

pub fn runUnstageFile(repo_root: []const u8, path: []const u8, allocator: std.mem.Allocator, io: std.Io) FileActionTaskResult {
    return runOperationMapped("Unstage", .{
        .repo_root = repo_root,
        .kind = .{ .unstage_file = path },
    }, allocator, io);
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

pub fn runAmend(repo_root: []const u8, subject: []const u8, body: ?[]const u8, allocator: std.mem.Allocator, io: std.Io) FileActionTaskResult {
    return runOperationMapped("Amend", .{
        .repo_root = repo_root,
        .kind = .{ .amend = .{ .subject = subject, .body = body } },
    }, allocator, io);
}

pub fn runPush(repo_root: []const u8, branch: []const u8, remote: []const u8, remote_branch: []const u8, oid: []const u8, env_map: ?*const std.process.Environ.Map, credentials: ?PushCredentials, allocator: std.mem.Allocator, io: std.Io) FileActionTaskResult {
    return runOperationMapped("Push", .{
        .repo_root = repo_root,
        .kind = .{ .push = .{
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

    const first = state.begin(.refresh_status);
    try std.testing.expect(state.isCurrent(first));

    const second = state.begin(.stage_file);
    try std.testing.expect(!state.isCurrent(first));
    try std.testing.expect(state.isCurrent(second));

    try std.testing.expect(!state.finish(first));
    try std.testing.expect(state.finish(second));
    try std.testing.expect(state.pending == null);
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

    const task = try allocator.create(Task);
    task.* = .{
        .pending = .{ .generation = 7, .kind = .stage_hunk },
        .repo_root = try allocator.dupe(u8, "/repo"),
        .path = try allocator.dupe(u8, "src/main.zig"),
        .patch = try allocator.dupe(u8, "patch"),
        .hunk_index = 3,
        .mark_source = .session,
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
