const std = @import("std");
const git_backend = @import("../git/backend.zig");

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
    switch_branch,
};

pub const PendingAction = struct {
    generation: u64,
    kind: ActionKind,
};

pub const HunkMarkSource = enum {
    session,
    projection,
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
    mark_source: HunkMarkSource = .session,
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
    mark_source: HunkMarkSource = .session,
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
        mark_source: HunkMarkSource = .session,

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
        mark_source: HunkMarkSource = .session,
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
    };
}

pub fn runStageFile(repo_root: []const u8, path: []const u8, allocator: std.mem.Allocator, io: std.Io) FileActionTaskResult {
    var local_backend: git_backend.LocalCommandBackend = .{};
    const raw_result = local_backend.backend().runOperation(allocator, io, .{
        .repo_root = repo_root,
        .kind = .{ .stage_file = path },
    }) catch |err| {
        return .{
            .failed = std.fmt.allocPrint(allocator, "Stage failed: {s}", .{@errorName(err)}) catch
                return .{ .failed_static = "Stage failed: OutOfMemory" },
        };
    };

    return switch (raw_result) {
        .ok => .ok,
        .failed => |message| .{ .failed = message },
        .failed_static => |message| .{ .failed_static = message },
    };
}

pub fn runUnstageFile(repo_root: []const u8, path: []const u8, allocator: std.mem.Allocator, io: std.Io) FileActionTaskResult {
    var local_backend: git_backend.LocalCommandBackend = .{};
    const raw_result = local_backend.backend().runOperation(allocator, io, .{
        .repo_root = repo_root,
        .kind = .{ .unstage_file = path },
    }) catch |err| {
        return .{
            .failed = std.fmt.allocPrint(allocator, "Unstage failed: {s}", .{@errorName(err)}) catch
                return .{ .failed_static = "Unstage failed: OutOfMemory" },
        };
    };

    return switch (raw_result) {
        .ok => .ok,
        .failed => |message| .{ .failed = message },
        .failed_static => |message| .{ .failed_static = message },
    };
}

pub fn runStageHunk(repo_root: []const u8, patch: []const u8, allocator: std.mem.Allocator, io: std.Io) FileActionTaskResult {
    var local_backend: git_backend.LocalCommandBackend = .{};
    const raw_result = local_backend.backend().runOperation(allocator, io, .{
        .repo_root = repo_root,
        .kind = .{ .stage_patch = .{ .patch = patch } },
    }) catch |err| {
        return .{
            .failed = std.fmt.allocPrint(allocator, "Stage hunk failed: {s}", .{@errorName(err)}) catch
                return .{ .failed_static = "Stage hunk failed: OutOfMemory" },
        };
    };

    return switch (raw_result) {
        .ok => .ok,
        .failed => |message| .{ .failed = message },
        .failed_static => |message| .{ .failed_static = message },
    };
}

pub fn runUnstageHunk(repo_root: []const u8, patch: []const u8, allocator: std.mem.Allocator, io: std.Io) FileActionTaskResult {
    var local_backend: git_backend.LocalCommandBackend = .{};
    const raw_result = local_backend.backend().runOperation(allocator, io, .{
        .repo_root = repo_root,
        .kind = .{ .unstage_patch = .{ .patch = patch } },
    }) catch |err| {
        return .{
            .failed = std.fmt.allocPrint(allocator, "Unstage hunk failed: {s}", .{@errorName(err)}) catch
                return .{ .failed_static = "Unstage hunk failed: OutOfMemory" },
        };
    };

    return switch (raw_result) {
        .ok => .ok,
        .failed => |message| .{ .failed = message },
        .failed_static => |message| .{ .failed_static = message },
    };
}

pub fn runDiscardFile(repo_root: []const u8, path: []const u8, allocator: std.mem.Allocator, io: std.Io) FileActionTaskResult {
    var local_backend: git_backend.LocalCommandBackend = .{};
    const raw_result = local_backend.backend().runOperation(allocator, io, .{
        .repo_root = repo_root,
        .kind = .{ .discard_file = path },
    }) catch |err| {
        return .{
            .failed = std.fmt.allocPrint(allocator, "Discard failed: {s}", .{@errorName(err)}) catch
                return .{ .failed_static = "Discard failed: OutOfMemory" },
        };
    };

    return switch (raw_result) {
        .ok => .ok,
        .failed => |message| .{ .failed = message },
        .failed_static => |message| .{ .failed_static = message },
    };
}

pub fn runCommit(repo_root: []const u8, subject: []const u8, body: ?[]const u8, allocator: std.mem.Allocator, io: std.Io) FileActionTaskResult {
    var local_backend: git_backend.LocalCommandBackend = .{};
    const raw_result = local_backend.backend().runOperation(allocator, io, .{
        .repo_root = repo_root,
        .kind = .{ .commit = .{ .subject = subject, .body = body } },
    }) catch |err| {
        return .{
            .failed = std.fmt.allocPrint(allocator, "Commit failed: {s}", .{@errorName(err)}) catch
                return .{ .failed_static = "Commit failed: OutOfMemory" },
        };
    };

    return switch (raw_result) {
        .ok => .ok,
        .failed => |message| .{ .failed = message },
        .failed_static => |message| .{ .failed_static = message },
    };
}

pub fn runAmend(repo_root: []const u8, subject: []const u8, body: ?[]const u8, allocator: std.mem.Allocator, io: std.Io) FileActionTaskResult {
    var local_backend: git_backend.LocalCommandBackend = .{};
    const raw_result = local_backend.backend().runOperation(allocator, io, .{
        .repo_root = repo_root,
        .kind = .{ .amend = .{ .subject = subject, .body = body } },
    }) catch |err| {
        return .{
            .failed = std.fmt.allocPrint(allocator, "Amend failed: {s}", .{@errorName(err)}) catch
                return .{ .failed_static = "Amend failed: OutOfMemory" },
        };
    };

    return switch (raw_result) {
        .ok => .ok,
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
