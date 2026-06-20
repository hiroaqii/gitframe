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
    result: StageFileTaskResult,

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

pub const StageFileTaskResult = union(enum) {
    ok,
    failed: []u8,
    failed_static: []const u8,

    pub fn deinit(self: StageFileTaskResult, allocator: std.mem.Allocator) void {
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

            return @unionInit(Msg, "stage_file_finished", StageFileFinished{
                .pending = task.pending,
                .path = path,
                .result = result,
            });
        }
    };
}

pub fn runStageFile(repo_root: []const u8, path: []const u8, allocator: std.mem.Allocator, io: std.Io) StageFileTaskResult {
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
