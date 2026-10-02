const std = @import("std");
const chasen = @import("chasen");
const git_remote = @import("../git/remote.zig");
const git_command = @import("../git/command.zig");
const git_operations = @import("../git/operations.zig");
const git_push = @import("../git/push.zig");
const git_ops = @import("git_ops.zig");
const process_runner = @import("../process/runner.zig");
const root_capability = @import("../repo/root_capability.zig");
const remote_request = @import("remote_request.zig");
const app_stash = @import("stash.zig");
const git_stash = @import("../git/stash.zig");

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
    amend,
    push,
    pull,
    fetch,
    switch_branch,
    create_stash,
    apply_stash,
    drop_stash,

    /// Whether an already-running background read must be discarded while
    /// this action is pending. Keep this exhaustive: adding an action must
    /// make its repository-mutation policy explicit.
    pub fn blocksBackgroundAcceptance(self: ActionKind) bool {
        return switch (self) {
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
            .create_stash,
            .apply_stash,
            .drop_stash,
            => true,
        };
    }
};

pub const PendingAction = struct {
    generation: u64,
    kind: ActionKind,
};

pub const CreateStashFinished = struct {
    pending: PendingAction,
    snapshot: app_stash.Snapshot,
    scope: git_stash.Scope,
    result: git_stash.CreateResult,

    pub fn deinit(self: *CreateStashFinished, allocator: std.mem.Allocator) void {
        self.snapshot.deinit(allocator);
        self.result.deinit(allocator);
        self.* = undefined;
    }
};

pub fn CreateStashTask(comptime Msg: type) type {
    return struct {
        pending: PendingAction,
        snapshot: ?app_stash.Snapshot,
        scope: git_stash.Scope,
        message: []u8,
        root: root_capability.RootCapability,
        environment: git_command.LocalGitEnvironment,

        pub fn run(task: *@This(), allocator: std.mem.Allocator, io: std.Io) std.Io.Cancelable!Msg {
            const result = git_stash.create(allocator, io, .{ .cwd = task.root.dir(), .environment = &task.environment }, .{
                .branch = task.snapshot.?.branch,
                .oid = task.snapshot.?.oid,
                .scope = task.scope,
                .message = task.message,
            }) catch |err| git_stash.CreateResult{ .operation = .{ .failed_static = @errorName(err) } };
            return task.finish(result);
        }

        pub fn failed(task: *@This(), failure: chasen.TaskStartError, _: std.mem.Allocator) Msg {
            return task.finish(.{ .operation = .{ .failed_static = taskFailureMessage(failure) } });
        }

        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            if (task.snapshot) |*owned| owned.deinit(allocator);
            allocator.free(task.message);
            task.environment.deinit();
            task.root.deinit();
            allocator.destroy(task);
        }

        fn finish(task: *@This(), result: git_stash.CreateResult) Msg {
            const snapshot = task.snapshot.?;
            task.snapshot = null;
            return Msg.actionFinished(.{ .create_stash = .{ .pending = task.pending, .snapshot = snapshot, .scope = task.scope, .result = result } });
        }
    };
}

pub const StashSelectionFinished = struct {
    pending: PendingAction,
    confirmation: app_stash.Selection,
    result: git_stash.SelectionResult,

    pub fn deinit(self: *StashSelectionFinished, allocator: std.mem.Allocator) void {
        self.confirmation.deinit(allocator);
        self.result.deinit(allocator);
        self.* = undefined;
    }
};

pub fn StashSelectionTask(comptime Msg: type) type {
    return struct {
        pending: PendingAction,
        confirmation: ?app_stash.Selection,
        root: root_capability.RootCapability,
        environment: git_command.LocalGitEnvironment,

        pub fn run(task: *@This(), allocator: std.mem.Allocator, io: std.Io) std.Io.Cancelable!Msg {
            const target = task.confirmation.?;
            const result = git_stash.performSelection(allocator, io, .{ .cwd = task.root.dir(), .environment = &task.environment }, .{
                .action = target.action,
                .branch = target.snapshot.branch,
                .head_oid = target.snapshot.oid,
                .selector = target.selector,
                .stash_oid = target.oid,
            });
            return task.finish(result);
        }

        pub fn failed(task: *@This(), failure: chasen.TaskStartError, _: std.mem.Allocator) Msg {
            return task.finish(.{ .operation = .{ .failed_static = taskFailureMessage(failure) } });
        }

        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            if (task.confirmation) |*owned| owned.deinit(allocator);
            task.environment.deinit();
            task.root.deinit();
            allocator.destroy(task);
        }

        fn finish(task: *@This(), result: git_stash.SelectionResult) Msg {
            const confirmation = task.confirmation.?;
            task.confirmation = null;
            return Msg.actionFinished(.{ .stash_selection = .{ .pending = task.pending, .confirmation = confirmation, .result = result } });
        }
    };
}

test "ActionKind blocks background acceptance for Git mutations" {
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
    identity: remote_request.RemoteRequestIdentity,
    mode: git_push.Mode,
    repo_root: []u8,
    branch: []u8,
    remote: []u8,
    remote_branch: []u8,
    oid: []u8,
    result: git_remote.RemoteOperationResult,

    pub fn deinit(self: *PushFinished, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        allocator.free(self.branch);
        allocator.free(self.remote);
        allocator.free(self.remote_branch);
        allocator.free(self.oid);
        self.* = .{
            .pending = .{ .generation = 0, .kind = .push },
            .identity = .{
                .repo_epoch = 0,
                .root_identity = .{ .device = 0, .inode = 0 },
                .operation_generation = 0,
            },
            .mode = .upstream,
            .repo_root = &.{},
            .branch = &.{},
            .remote = &.{},
            .remote_branch = &.{},
            .oid = &.{},
            .result = .{ .outcome = .{ .failed = .failed } },
        };
    }
};

pub const PullFinished = struct {
    pending: PendingAction,
    identity: remote_request.RemoteRequestIdentity = .{
        .repo_epoch = 0,
        .root_identity = .{ .device = 0, .inode = 0 },
        .operation_generation = 0,
    },
    repo_root: []u8,
    branch: []u8,
    remote: []u8,
    remote_branch: []u8,
    oid: []u8,
    result: git_remote.RemoteOperationResult,

    pub fn deinit(self: *PullFinished, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        allocator.free(self.branch);
        allocator.free(self.remote);
        allocator.free(self.remote_branch);
        allocator.free(self.oid);
        self.* = .{
            .pending = .{ .generation = 0, .kind = .pull },
            .identity = .{
                .repo_epoch = 0,
                .root_identity = .{ .device = 0, .inode = 0 },
                .operation_generation = 0,
            },
            .repo_root = &.{},
            .branch = &.{},
            .remote = &.{},
            .remote_branch = &.{},
            .oid = &.{},
            .result = .{ .outcome = .{ .failed = .failed } },
        };
    }
};

pub const FetchFinished = struct {
    pending: PendingAction,
    identity: remote_request.RemoteRequestIdentity = .{
        .repo_epoch = 0,
        .root_identity = .{ .device = 0, .inode = 0 },
        .operation_generation = 0,
    },
    repo_root: []u8,
    remote: []u8,
    result: git_remote.RemoteOperationResult,

    pub fn deinit(self: *FetchFinished, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        allocator.free(self.remote);
        self.* = .{
            .pending = .{ .generation = 0, .kind = .fetch },
            .identity = .{
                .repo_epoch = 0,
                .root_identity = .{ .device = 0, .inode = 0 },
                .operation_generation = 0,
            },
            .repo_root = &.{},
            .remote = &.{},
            .result = .{ .outcome = .{ .failed = .failed } },
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
    failed: []u8,
    failed_static: []const u8,

    pub fn deinit(self: FileActionTaskResult, allocator: std.mem.Allocator) void {
        switch (self) {
            .ok, .failed_static => {},
            .failed => |message| allocator.free(message),
        }
    }
};

/// Async task for `git add -- <path>`.
///
/// The task owns copied repo/path strings because action requests cross the
/// update boundary. The result moves `path` back to App for user-facing status
/// messages.
pub fn StageFileTask(comptime Msg: type) type {
    return struct {
        pending: PendingAction,
        repo_root: []u8,
        root: root_capability.RootCapability,
        environment: git_command.LocalGitEnvironment,
        path: []u8,
        label: []u8,
        target_kind: git_ops.TargetKind,

        pub fn run(task: *@This(), allocator: std.mem.Allocator, io: std.Io) std.Io.Cancelable!Msg {
            return task.finish(runStageTarget(task.directoryContext(), task.path, task.target_kind, allocator, io));
        }

        pub fn failed(task: *@This(), failure: chasen.TaskStartError, _: std.mem.Allocator) Msg {
            return task.finish(.{ .failed_static = taskFailureMessage(failure) });
        }

        /// Release all fields not moved into the result.
        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            if (task.repo_root.len > 0) allocator.free(task.repo_root);
            if (task.path.len > 0) allocator.free(task.path);
            if (task.label.len > 0) allocator.free(task.label);
            task.environment.deinit();
            task.root.deinit();
            allocator.destroy(task);
        }

        fn finish(task: *@This(), result: FileActionTaskResult) Msg {
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

        fn directoryContext(task: *@This()) git_command.DirectoryContext {
            return .{ .cwd = task.root.dir(), .environment = &task.environment };
        }
    };
}

/// Async task for unstaging complete index units in one Git mutation.
///
/// Kept separate from StageFileTask for now so operation-specific status text
/// stays obvious; a shared helper can be introduced once a third file action
/// proves the common shape.
pub fn UnstageFileTask(comptime Msg: type) type {
    return struct {
        pending: PendingAction,
        repo_root: []u8,
        root: root_capability.RootCapability,
        environment: git_command.LocalGitEnvironment,
        paths: [][]const u8,
        label: []u8,
        target_kind: git_ops.TargetKind,

        pub fn run(task: *@This(), allocator: std.mem.Allocator, io: std.Io) std.Io.Cancelable!Msg {
            return task.finish(runUnstageTarget(task.directoryContext(), task.paths, task.target_kind, allocator, io));
        }

        pub fn failed(task: *@This(), failure: chasen.TaskStartError, _: std.mem.Allocator) Msg {
            return task.finish(.{ .failed_static = taskFailureMessage(failure) });
        }

        /// Release all fields not moved into the result.
        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            if (task.repo_root.len > 0) allocator.free(task.repo_root);
            for (task.paths) |path| allocator.free(path);
            allocator.free(task.paths);
            if (task.label.len > 0) allocator.free(task.label);
            task.environment.deinit();
            task.root.deinit();
            allocator.destroy(task);
        }

        fn finish(task: *@This(), result: FileActionTaskResult) Msg {
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

        fn directoryContext(task: *@This()) git_command.DirectoryContext {
            return .{ .cwd = task.root.dir(), .environment = &task.environment };
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
        root: root_capability.RootCapability,
        environment: git_command.LocalGitEnvironment,
        path: []u8,
        patch: []u8,
        hunk_index: usize,
        session_mark_mutation: git_ops.SessionHunkMarkMutation,

        pub fn run(task: *@This(), allocator: std.mem.Allocator, io: std.Io) std.Io.Cancelable!Msg {
            return task.finish(runStageHunk(task.directoryContext(), task.patch, allocator, io));
        }

        pub fn failed(task: *@This(), failure: chasen.TaskStartError, _: std.mem.Allocator) Msg {
            return task.finish(.{ .failed_static = taskFailureMessage(failure) });
        }

        /// Release all fields not moved into the result.
        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            if (task.repo_root.len > 0) allocator.free(task.repo_root);
            if (task.path.len > 0) allocator.free(task.path);
            allocator.free(task.patch);
            task.environment.deinit();
            task.root.deinit();
            allocator.destroy(task);
        }

        fn finish(task: *@This(), result: FileActionTaskResult) Msg {
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

        fn directoryContext(task: *@This()) git_command.DirectoryContext {
            return .{ .cwd = task.root.dir(), .environment = &task.environment };
        }
    };
}

/// Async task for `git apply --cached --reverse -` with a single-hunk patch.
pub fn UnstageHunkTask(comptime Msg: type) type {
    return struct {
        pending: PendingAction,
        repo_root: []u8,
        root: root_capability.RootCapability,
        environment: git_command.LocalGitEnvironment,
        path: []u8,
        patch: []u8,
        hunk_index: usize,
        session_mark_mutation: git_ops.SessionHunkMarkMutation,
        reload_after_success: bool = false,

        pub fn run(task: *@This(), allocator: std.mem.Allocator, io: std.Io) std.Io.Cancelable!Msg {
            return task.finish(runUnstageHunk(task.directoryContext(), task.patch, allocator, io));
        }

        pub fn failed(task: *@This(), failure: chasen.TaskStartError, _: std.mem.Allocator) Msg {
            return task.finish(.{ .failed_static = taskFailureMessage(failure) });
        }

        /// Release all fields not moved into the result.
        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            if (task.repo_root.len > 0) allocator.free(task.repo_root);
            if (task.path.len > 0) allocator.free(task.path);
            allocator.free(task.patch);
            task.environment.deinit();
            task.root.deinit();
            allocator.destroy(task);
        }

        fn finish(task: *@This(), result: FileActionTaskResult) Msg {
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

        fn directoryContext(task: *@This()) git_command.DirectoryContext {
            return .{ .cwd = task.root.dir(), .environment = &task.environment };
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
        root: root_capability.RootCapability,
        environment: git_command.LocalGitEnvironment,
        path: []u8,

        pub fn run(task: *@This(), allocator: std.mem.Allocator, io: std.Io) std.Io.Cancelable!Msg {
            return task.finish(runDiscardFile(task.directoryContext(), task.path, allocator, io));
        }

        pub fn failed(task: *@This(), failure: chasen.TaskStartError, _: std.mem.Allocator) Msg {
            return task.finish(.{ .failed_static = taskFailureMessage(failure) });
        }

        /// Release all fields not moved into the result.
        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(task.repo_root);
            if (task.path.len > 0) allocator.free(task.path);
            task.environment.deinit();
            task.root.deinit();
            allocator.destroy(task);
        }

        fn finish(task: *@This(), result: FileActionTaskResult) Msg {
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

        fn directoryContext(task: *@This()) git_command.DirectoryContext {
            return .{ .cwd = task.root.dir(), .environment = &task.environment };
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
        root: root_capability.RootCapability,
        environment: git_command.LocalGitEnvironment,
        subject: []u8,
        body: ?[]u8,

        pub fn run(task: *@This(), allocator: std.mem.Allocator, io: std.Io) std.Io.Cancelable!Msg {
            return task.finish(runCommit(task.directoryContext(), task.subject, task.body, allocator, io));
        }

        pub fn failed(task: *@This(), failure: chasen.TaskStartError, _: std.mem.Allocator) Msg {
            return task.finish(.{ .failed_static = taskFailureMessage(failure) });
        }

        /// Release all fields not moved into the result.
        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            if (task.repo_root.len > 0) allocator.free(task.repo_root);
            allocator.free(task.subject);
            if (task.body) |body| allocator.free(body);
            task.environment.deinit();
            task.root.deinit();
            allocator.destroy(task);
        }

        fn finish(task: *@This(), result: FileActionTaskResult) Msg {
            const repo_root = task.repo_root;
            task.repo_root = &.{};
            return Msg.actionFinished(.{ .commit = CommitFinished{
                .pending = task.pending,
                .repo_root = repo_root,
                .result = result,
            } });
        }

        fn directoryContext(task: *@This()) git_command.DirectoryContext {
            return .{ .cwd = task.root.dir(), .environment = &task.environment };
        }
    };
}

/// Async task for `git commit --amend -m subject [-m body]`.
pub fn AmendTask(comptime Msg: type) type {
    return struct {
        pending: PendingAction,
        repo_root: []u8,
        root: root_capability.RootCapability,
        environment: git_command.LocalGitEnvironment,
        subject: []u8,
        body: ?[]u8,

        pub fn run(task: *@This(), allocator: std.mem.Allocator, io: std.Io) std.Io.Cancelable!Msg {
            return task.finish(runAmend(task.directoryContext(), task.subject, task.body, allocator, io));
        }

        pub fn failed(task: *@This(), failure: chasen.TaskStartError, _: std.mem.Allocator) Msg {
            return task.finish(.{ .failed_static = taskFailureMessage(failure) });
        }

        /// Release all fields not moved into the result.
        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            if (task.repo_root.len > 0) allocator.free(task.repo_root);
            allocator.free(task.subject);
            if (task.body) |body| allocator.free(body);
            task.environment.deinit();
            task.root.deinit();
            allocator.destroy(task);
        }

        fn finish(task: *@This(), result: FileActionTaskResult) Msg {
            const repo_root = task.repo_root;
            task.repo_root = &.{};
            return Msg.actionFinished(.{ .amend = AmendFinished{
                .pending = task.pending,
                .repo_root = repo_root,
                .result = result,
            } });
        }

        fn directoryContext(task: *@This()) git_command.DirectoryContext {
            return .{ .cwd = task.root.dir(), .environment = &task.environment };
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
        identity: remote_request.RemoteRequestIdentity,
        mode: git_push.Mode,
        repo_root: []u8,
        branch: []u8,
        remote: []u8,
        remote_branch: []u8,
        oid: []u8,
        root: ?root_capability.RootCapability = null,
        environment: ?git_remote.OwnedRemoteEnvironment = null,
        cancellation: ?process_runner.CancellationView = null,

        pub fn run(task: *@This(), allocator: std.mem.Allocator, io: std.Io) std.Io.Cancelable!Msg {
            const root = if (task.root) |*owned| owned else @panic("background push requires root authority");
            const environment = if (task.environment) |*owned| owned else @panic("background push requires an environment");
            const result = runBackgroundPush(
                root,
                environment,
                task.cancellation orelse @panic("background push requires cancellation authority"),
                task.mode,
                task.branch,
                task.remote,
                task.remote_branch,
                task.oid,
                allocator,
                io,
            );
            return task.finish(result);
        }

        pub fn failed(task: *@This(), _: chasen.TaskStartError, _: std.mem.Allocator) Msg {
            const result = remoteTaskSpawnFailure(if (task.environment) |environment| environment.warnings else .{});
            return task.finish(result);
        }

        /// Release all fields not moved into the result.
        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            if (task.repo_root.len > 0) allocator.free(task.repo_root);
            if (task.branch.len > 0) allocator.free(task.branch);
            if (task.remote.len > 0) allocator.free(task.remote);
            if (task.remote_branch.len > 0) allocator.free(task.remote_branch);
            allocator.free(task.oid);
            if (task.root) |*root| root.deinit();
            if (task.environment) |*environment| environment.deinit();
            allocator.destroy(task);
        }

        fn finish(task: *@This(), result: git_remote.RemoteOperationResult) Msg {
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
                .identity = task.identity,
                .mode = mode,
                .repo_root = repo_root,
                .branch = branch,
                .remote = remote,
                .remote_branch = remote_branch,
                .oid = oid,
                .result = result,
            } });
        }
    };
}

pub fn PullTask(comptime Msg: type) type {
    return struct {
        pending: PendingAction,
        identity: remote_request.RemoteRequestIdentity = .{
            .repo_epoch = 0,
            .root_identity = .{ .device = 0, .inode = 0 },
            .operation_generation = 0,
        },
        repo_root: []u8,
        branch: []u8,
        remote: []u8,
        remote_branch: []u8,
        upstream_ref: []u8,
        oid: []u8,
        env_map: ?*const std.process.Environ.Map = null,
        root: ?root_capability.RootCapability = null,
        environment: ?git_remote.OwnedRemoteEnvironment = null,
        cancellation: ?process_runner.CancellationView = null,

        pub fn run(task: *@This(), allocator: std.mem.Allocator, io: std.Io) std.Io.Cancelable!Msg {
            const root = if (task.root) |*owned| owned else @panic("background pull requires root authority");
            const environment = if (task.environment) |*owned| owned else @panic("background pull requires an environment");
            return task.finish(runBackgroundPull(
                root,
                environment,
                task.cancellation orelse @panic("background pull requires cancellation authority"),
                task.branch,
                task.remote,
                task.remote_branch,
                task.upstream_ref,
                task.oid,
                allocator,
                io,
            ));
        }

        pub fn failed(task: *@This(), _: chasen.TaskStartError, _: std.mem.Allocator) Msg {
            return task.finish(remoteTaskSpawnFailure(if (task.environment) |environment| environment.warnings else .{}));
        }

        /// Release all fields not moved into the result.
        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            if (task.repo_root.len > 0) allocator.free(task.repo_root);
            if (task.branch.len > 0) allocator.free(task.branch);
            if (task.remote.len > 0) allocator.free(task.remote);
            if (task.remote_branch.len > 0) allocator.free(task.remote_branch);
            allocator.free(task.upstream_ref);
            allocator.free(task.oid);
            if (task.root) |*root| root.deinit();
            if (task.environment) |*environment| environment.deinit();
            allocator.destroy(task);
        }

        fn finish(task: *@This(), result: git_remote.RemoteOperationResult) Msg {
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
                .identity = task.identity,
                .repo_root = repo_root,
                .branch = branch,
                .remote = remote,
                .remote_branch = remote_branch,
                .oid = oid,
                .result = result,
            } });
        }
    };
}

pub fn FetchTask(comptime Msg: type) type {
    return struct {
        pending: PendingAction,
        identity: remote_request.RemoteRequestIdentity = .{
            .repo_epoch = 0,
            .root_identity = .{ .device = 0, .inode = 0 },
            .operation_generation = 0,
        },
        repo_root: []u8,
        remote: []u8,
        env_map: ?*const std.process.Environ.Map = null,
        root: ?root_capability.RootCapability = null,
        environment: ?git_remote.OwnedRemoteEnvironment = null,
        cancellation: ?process_runner.CancellationView = null,

        pub fn run(task: *@This(), allocator: std.mem.Allocator, io: std.Io) std.Io.Cancelable!Msg {
            const root = if (task.root) |*owned| owned else @panic("background fetch requires root authority");
            const environment = if (task.environment) |*owned| owned else @panic("background fetch requires an environment");
            return task.finish(runBackgroundFetch(
                root,
                environment,
                task.cancellation orelse @panic("background fetch requires cancellation authority"),
                task.remote,
                allocator,
                io,
            ));
        }

        pub fn failed(task: *@This(), _: chasen.TaskStartError, _: std.mem.Allocator) Msg {
            return task.finish(remoteTaskSpawnFailure(if (task.environment) |environment| environment.warnings else .{}));
        }

        /// Release all fields not moved into the result.
        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            if (task.repo_root.len > 0) allocator.free(task.repo_root);
            allocator.free(task.remote);
            if (task.root) |*root| root.deinit();
            if (task.environment) |*environment| environment.deinit();
            allocator.destroy(task);
        }

        fn finish(task: *@This(), result: git_remote.RemoteOperationResult) Msg {
            const repo_root = task.repo_root;
            const remote = task.remote;
            task.repo_root = &.{};
            task.remote = &.{};
            return Msg.actionFinished(.{ .fetch = FetchFinished{
                .pending = task.pending,
                .identity = task.identity,
                .repo_root = repo_root,
                .remote = remote,
                .result = result,
            } });
        }
    };
}

pub fn SwitchBranchTask(comptime Msg: type) type {
    return struct {
        pending: PendingAction,
        repo_root: []u8,
        root: root_capability.RootCapability,
        environment: git_command.LocalGitEnvironment,
        expected_branch: []u8,
        expected_oid: []u8,
        target_branch: []u8,
        target_oid: []u8,

        pub fn run(task: *@This(), allocator: std.mem.Allocator, io: std.Io) std.Io.Cancelable!Msg {
            return task.finish(runSwitchBranch(task.directoryContext(), task.expected_branch, task.expected_oid, task.target_branch, task.target_oid, allocator, io));
        }

        pub fn failed(task: *@This(), failure: chasen.TaskStartError, _: std.mem.Allocator) Msg {
            return task.finish(.{ .failed_static = taskFailureMessage(failure) });
        }

        /// Release all fields not moved into the result.
        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            if (task.repo_root.len > 0) allocator.free(task.repo_root);
            if (task.expected_branch.len > 0) allocator.free(task.expected_branch);
            allocator.free(task.expected_oid);
            if (task.target_branch.len > 0) allocator.free(task.target_branch);
            allocator.free(task.target_oid);
            task.environment.deinit();
            task.root.deinit();
            allocator.destroy(task);
        }

        fn finish(task: *@This(), result: FileActionTaskResult) Msg {
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

        fn directoryContext(task: *@This()) git_command.DirectoryContext {
            return .{ .cwd = task.root.dir(), .environment = &task.environment };
        }
    };
}

pub fn taskFailureMessage(failure: chasen.TaskStartError) []const u8 {
    return @errorName(failure);
}

pub fn runStageFile(context: git_command.DirectoryContext, path: []const u8, allocator: std.mem.Allocator, io: std.Io) FileActionTaskResult {
    return runOperationMapped("Stage", .{
        .context = context,
        .kind = .{ .stage_file = path },
    }, allocator, io);
}

pub fn runStageTarget(context: git_command.DirectoryContext, path: []const u8, target_kind: git_ops.TargetKind, allocator: std.mem.Allocator, io: std.Io) FileActionTaskResult {
    return switch (target_kind) {
        .repository => runOperationMapped("Stage", .{
            .context = context,
            .kind = .stage_all,
        }, allocator, io),
        .file, .directory => runStageFile(context, path, allocator, io),
    };
}

pub fn runUnstageTarget(context: git_command.DirectoryContext, paths: []const []const u8, target_kind: git_ops.TargetKind, allocator: std.mem.Allocator, io: std.Io) FileActionTaskResult {
    return runOperationMapped("Unstage", .{
        .context = context,
        .kind = switch (target_kind) {
            .repository => .unstage_all,
            .file, .directory => .{ .unstage_paths = paths },
        },
    }, allocator, io);
}

pub fn runStageHunk(context: git_command.DirectoryContext, patch: []const u8, allocator: std.mem.Allocator, io: std.Io) FileActionTaskResult {
    return runOperationMapped("Stage hunk", .{
        .context = context,
        .kind = .{ .stage_patch = .{ .patch = patch } },
    }, allocator, io);
}

pub fn runUnstageHunk(context: git_command.DirectoryContext, patch: []const u8, allocator: std.mem.Allocator, io: std.Io) FileActionTaskResult {
    return runOperationMapped("Unstage hunk", .{
        .context = context,
        .kind = .{ .unstage_patch = .{ .patch = patch } },
    }, allocator, io);
}

pub fn runDiscardFile(context: git_command.DirectoryContext, path: []const u8, allocator: std.mem.Allocator, io: std.Io) FileActionTaskResult {
    return runOperationMapped("Discard", .{
        .context = context,
        .kind = .{ .discard_file = path },
    }, allocator, io);
}

pub fn runCommit(context: git_command.DirectoryContext, subject: []const u8, body: ?[]const u8, allocator: std.mem.Allocator, io: std.Io) FileActionTaskResult {
    return runOperationMapped("Commit", .{
        .context = context,
        .kind = .{ .commit = .{ .subject = subject, .body = body } },
    }, allocator, io);
}

pub fn runAmend(context: git_command.DirectoryContext, subject: []const u8, body: ?[]const u8, allocator: std.mem.Allocator, io: std.Io) FileActionTaskResult {
    return runOperationMapped("Amend", .{
        .context = context,
        .kind = .{ .amend = .{ .subject = subject, .body = body } },
    }, allocator, io);
}

const remote_operation_timeout = std.Io.Duration.fromSeconds(120);

fn remoteProcessControl(io: std.Io, cancellation: process_runner.CancellationView) process_runner.ProcessControl {
    return .{
        .deadline = std.Io.Clock.Timestamp.fromNow(io, .{
            .raw = remote_operation_timeout,
            .clock = .awake,
        }),
        .cancellation = cancellation,
    };
}

pub fn runBackgroundPush(
    root: *const root_capability.RootCapability,
    environment: *const git_remote.OwnedRemoteEnvironment,
    cancellation: process_runner.CancellationView,
    mode: git_push.Mode,
    branch: []const u8,
    remote: []const u8,
    remote_branch: []const u8,
    oid: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,
) git_remote.RemoteOperationResult {
    return git_remote.runOperation(allocator, io, .{
        .root = root,
        .environment = environment,
        .control = remoteProcessControl(io, cancellation),
        .kind = .{ .push = .{
            .mode = mode,
            .branch = branch,
            .remote = remote,
            .remote_branch = remote_branch,
            .oid = oid,
        } },
    });
}

pub fn runBackgroundPull(
    root: *const root_capability.RootCapability,
    environment: *const git_remote.OwnedRemoteEnvironment,
    cancellation: process_runner.CancellationView,
    branch: []const u8,
    remote: []const u8,
    remote_branch: []const u8,
    upstream_ref: []const u8,
    oid: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,
) git_remote.RemoteOperationResult {
    return git_remote.runOperation(allocator, io, .{
        .root = root,
        .environment = environment,
        .control = remoteProcessControl(io, cancellation),
        .kind = .{ .pull_refresh_ff_only = .{
            .branch = branch,
            .remote = remote,
            .remote_branch = remote_branch,
            .upstream_ref = upstream_ref,
            .oid = oid,
        } },
    });
}

pub fn runBackgroundFetch(
    root: *const root_capability.RootCapability,
    environment: *const git_remote.OwnedRemoteEnvironment,
    cancellation: process_runner.CancellationView,
    remote: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,
) git_remote.RemoteOperationResult {
    return git_remote.runOperation(allocator, io, .{
        .root = root,
        .environment = environment,
        .control = remoteProcessControl(io, cancellation),
        .kind = .{ .fetch = .{ .remote = remote } },
    });
}

fn remoteTaskSpawnFailure(warnings: git_remote.RemoteWarningSet) git_remote.RemoteOperationResult {
    return .{
        .outcome = .{ .failed = .spawn_failed },
        .warnings = warnings,
    };
}

pub fn runSwitchBranch(context: git_command.DirectoryContext, expected_branch: []const u8, expected_oid: []const u8, target_branch: []const u8, target_oid: []const u8, allocator: std.mem.Allocator, io: std.Io) FileActionTaskResult {
    return runOperationMapped("Branch switch", .{
        .context = context,
        .kind = .{ .switch_branch = .{
            .expected_branch = expected_branch,
            .expected_oid = expected_oid,
            .target_branch = target_branch,
            .target_oid = target_oid,
        } },
    }, allocator, io);
}

fn runOperationMapped(comptime prefix: []const u8, request: git_operations.OperationRequest, allocator: std.mem.Allocator, io: std.Io) FileActionTaskResult {
    const raw_result = git_operations.runOperation(allocator, io, request) catch |err| {
        return .{
            .failed = std.fmt.allocPrint(allocator, prefix ++ " failed: {s}", .{@errorName(err)}) catch
                return .{ .failed_static = prefix ++ " failed: OutOfMemory" },
        };
    };
    return switch (raw_result) {
        .ok => .ok,
        .failed => |message| .{ .failed = message },
        .failed_static => |message| .{ .failed_static = message },
    };
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
    var root = try root_capability.RootCapability.openCanonical("/");
    errdefer root.deinit();
    var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, null);
    errdefer environment.deinit();
    const repo_root = try allocator.dupe(u8, "/__gitframe_missing_repo__");
    errdefer allocator.free(repo_root);
    const path = try allocator.dupe(u8, "src/main.zig");
    errdefer allocator.free(path);
    const label = try allocator.dupe(u8, "src/main.zig");
    errdefer allocator.free(label);
    const task = try allocator.create(Task);
    task.* = .{
        .pending = pending,
        .repo_root = repo_root,
        .root = root,
        .environment = environment,
        .path = path,
        .label = label,
        .target_kind = .file,
    };
    return task;
}

fn makeUnstageFileTaskForTest(allocator: std.mem.Allocator, pending: PendingAction) !*UnstageFileTask(FileTaskTestMsg) {
    const Task = UnstageFileTask(FileTaskTestMsg);
    var root = try root_capability.RootCapability.openCanonical("/");
    errdefer root.deinit();
    var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, null);
    errdefer environment.deinit();
    const repo_root = try allocator.dupe(u8, "/__gitframe_missing_repo__");
    errdefer allocator.free(repo_root);
    const paths = try allocator.alloc([]const u8, 2);
    @memset(paths, &.{});
    errdefer {
        for (paths) |path| allocator.free(path);
        allocator.free(paths);
    }
    paths[0] = try allocator.dupe(u8, "src/main.zig");
    paths[1] = try allocator.dupe(u8, "old/main.zig");
    const label = try allocator.dupe(u8, "src/main.zig");
    errdefer allocator.free(label);
    const task = try allocator.create(Task);
    task.* = .{
        .pending = pending,
        .repo_root = repo_root,
        .root = root,
        .environment = environment,
        .paths = paths,
        .label = label,
        .target_kind = .file,
    };
    return task;
}

fn expectRootCapabilityClosedForTest(observer: root_capability.RootCapability) !void {
    if (observer.duplicate()) |unexpected| {
        var owned = unexpected;
        owned.deinit();
        return error.ExpectedClosedRootCapability;
    } else |err| try std.testing.expectEqual(error.InvalidRootCapability, err);
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
    const root_observer = task.root;

    var ctx: chasen.testing.TestCtx(FileTaskTestMsg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();
    _ = try ctx.ctx.task().spawnOwned(task, .{ .run = Task.run, .failed = Task.failed, .cleanup = Task.destroy });
    var entries = ctx.takeTask(0).?;
    defer entries.deinit();
    var finished = expectStageFileFinished(try entries.run());
    defer finished.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 11), finished.pending.generation);
    try std.testing.expectEqual(ActionKind.stage_file, finished.pending.kind);
    try std.testing.expectEqualStrings("/__gitframe_missing_repo__", finished.repo_root);
    try std.testing.expectEqualStrings("src/main.zig", finished.path);
    try std.testing.expectEqual(FileActionTaskResult.failed, std.meta.activeTag(finished.result));
    try expectRootCapabilityClosedForTest(root_observer);
}

test "StageFileTask failed frees borrowed command path and moves label" {
    const allocator = std.testing.allocator;
    const Task = StageFileTask(FileTaskTestMsg);
    const task = try makeStageFileTaskForTest(allocator, .{ .generation = 12, .kind = .stage_file });
    const root_observer = task.root;

    var ctx: chasen.testing.TestCtx(FileTaskTestMsg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();
    _ = try ctx.ctx.task().spawnOwned(task, .{ .run = Task.run, .failed = Task.failed, .cleanup = Task.destroy });
    var entries = ctx.takeTask(0).?;
    defer entries.deinit();
    var finished = expectStageFileFinished(try entries.fail(error.ConcurrencyUnavailable));
    defer finished.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 12), finished.pending.generation);
    try std.testing.expectEqual(ActionKind.stage_file, finished.pending.kind);
    try std.testing.expectEqualStrings("/__gitframe_missing_repo__", finished.repo_root);
    try std.testing.expectEqualStrings("src/main.zig", finished.path);
    try std.testing.expectEqualStrings("ConcurrencyUnavailable", switch (finished.result) {
        .failed_static => |message| message,
        else => return error.UnexpectedResult,
    });
    try expectRootCapabilityClosedForTest(root_observer);
}

test "UnstageFileTask run frees borrowed command path and moves label" {
    const allocator = std.testing.allocator;
    const Task = UnstageFileTask(FileTaskTestMsg);
    const task = try makeUnstageFileTaskForTest(allocator, .{ .generation = 13, .kind = .unstage_file });
    const root_observer = task.root;

    var ctx: chasen.testing.TestCtx(FileTaskTestMsg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();
    _ = try ctx.ctx.task().spawnOwned(task, .{ .run = Task.run, .failed = Task.failed, .cleanup = Task.destroy });
    var entries = ctx.takeTask(0).?;
    defer entries.deinit();
    var finished = expectUnstageFileFinished(try entries.run());
    defer finished.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 13), finished.pending.generation);
    try std.testing.expectEqual(ActionKind.unstage_file, finished.pending.kind);
    try std.testing.expectEqualStrings("/__gitframe_missing_repo__", finished.repo_root);
    try std.testing.expectEqualStrings("src/main.zig", finished.path);
    try std.testing.expectEqual(FileActionTaskResult.failed, std.meta.activeTag(finished.result));
    try expectRootCapabilityClosedForTest(root_observer);
}

test "UnstageFileTask failed frees borrowed command path and moves label" {
    const allocator = std.testing.allocator;
    const Task = UnstageFileTask(FileTaskTestMsg);
    const task = try makeUnstageFileTaskForTest(allocator, .{ .generation = 14, .kind = .unstage_file });
    const root_observer = task.root;

    var ctx: chasen.testing.TestCtx(FileTaskTestMsg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();
    _ = try ctx.ctx.task().spawnOwned(task, .{ .run = Task.run, .failed = Task.failed, .cleanup = Task.destroy });
    var entries = ctx.takeTask(0).?;
    defer entries.deinit();
    var finished = expectUnstageFileFinished(try entries.fail(error.OutOfMemory));
    defer finished.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 14), finished.pending.generation);
    try std.testing.expectEqual(ActionKind.unstage_file, finished.pending.kind);
    try std.testing.expectEqualStrings("/__gitframe_missing_repo__", finished.repo_root);
    try std.testing.expectEqualStrings("src/main.zig", finished.path);
    try std.testing.expectEqualStrings("OutOfMemory", switch (finished.result) {
        .failed_static => |message| message,
        else => return error.UnexpectedResult,
    });
    try expectRootCapabilityClosedForTest(root_observer);
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
    var root = try root_capability.RootCapability.openCanonical("/");
    var authority_consumed = false;
    errdefer if (!authority_consumed) root.deinit();
    var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, null);
    errdefer if (!authority_consumed) environment.deinit();
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
        .root = root,
        .environment = environment,
        .path = try allocator.dupe(u8, "src/main.zig"),
        .patch = try allocator.dupe(u8, "patch"),
        .hunk_index = 3,
        .session_mark_mutation = .{ .add = mark_key },
    };
    authority_consumed = true;
    const root_observer = task.root;

    const msg = Task.failed(task, error.OutOfMemory, allocator);

    Task.destroy(task, allocator);
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
    try expectRootCapabilityClosedForTest(root_observer);
}

test "runOperationMapped preserves action failure prefixes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const context: git_command.DirectoryContext = .{
        .cwd = tmp.dir,
        .environment = &environment,
    };

    var stage_allocator_state = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const stage_allocator = stage_allocator_state.allocator();
    var result = runStageFile(context, "src/main.zig", stage_allocator, std.testing.io);
    defer result.deinit(stage_allocator);

    const message = switch (result) {
        .failed => |text| text,
        .failed_static => |text| text,
        else => return error.UnexpectedResult,
    };
    try std.testing.expect(std.mem.startsWith(u8, message, "Stage failed: "));

    var commit_allocator_state = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const commit_allocator = commit_allocator_state.allocator();
    var commit_result = runCommit(context, "subject", null, commit_allocator, std.testing.io);
    defer commit_result.deinit(commit_allocator);

    const commit_message = switch (commit_result) {
        .failed => |text| text,
        .failed_static => |text| text,
        else => return error.UnexpectedResult,
    };
    try std.testing.expect(std.mem.startsWith(u8, commit_message, "Commit failed: "));
}

test "owned StageFileTask discard and queued cancellation release without a message" {
    const allocator = std.testing.allocator;
    const Task = StageFileTask(FileTaskTestMsg);
    for ([_]bool{ false, true }) |cancel| {
        const task = try makeStageFileTaskForTest(allocator, .{ .generation = 15, .kind = .stage_file });
        const root_observer = task.root;
        var ctx: chasen.testing.TestCtx(FileTaskTestMsg) = undefined;
        ctx.init(allocator, std.testing.io);
        defer ctx.deinit();
        const id = try ctx.ctx.task().spawnOwned(task, .{ .run = Task.run, .failed = Task.failed, .cleanup = Task.destroy });
        if (cancel) {
            ctx.ctx.task().requestCancel(id);
            var entries = ctx.takeTask(0).?;
            defer entries.deinit();
            try std.testing.expectError(error.Canceled, entries.run());
        } else {
            ctx.discardPendingTasks();
        }
        try expectRootCapabilityClosedForTest(root_observer);
        try std.testing.expectEqual(@as(usize, 0), ctx.pendingTaskCount());
    }
}
