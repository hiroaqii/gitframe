const std = @import("std");
const git_branch_status = @import("branch_status.zig");
const process_runner = @import("../process/runner.zig");

pub const max_diff_bytes = 16 * 1024 * 1024;
pub const max_status_bytes = 8 * 1024 * 1024;

pub const LoadError = error{
    StreamTooLong,
    OutOfMemory,
    SpawnFailed,
};

pub const LoadResult = union(enum) {
    /// Allocated raw diff text. Caller owns and must call `deinit`.
    ok: []u8,
    /// Allocated error message from the backend. Caller owns and must call `deinit`.
    failed: []u8,
    /// Non-owned fallback error message, used when allocation itself fails.
    failed_static: []const u8,

    pub fn deinit(self: LoadResult, allocator: std.mem.Allocator) void {
        switch (self) {
            .ok => |bytes| allocator.free(bytes),
            .failed => |message| allocator.free(message),
            .failed_static => {},
        }
    }
};

pub const StatusLoadResult = union(enum) {
    /// Allocated raw porcelain status text. Caller owns and must call `deinit`.
    ok: []u8,
    /// Allocated error message from the backend. Caller owns and must call `deinit`.
    failed: []u8,
    /// Non-owned fallback error message, used when allocation itself fails.
    failed_static: []const u8,

    pub fn deinit(self: StatusLoadResult, allocator: std.mem.Allocator) void {
        switch (self) {
            .ok => |bytes| allocator.free(bytes),
            .failed => |message| allocator.free(message),
            .failed_static => {},
        }
    }
};

pub const BranchStatusLoadResult = union(enum) {
    /// Owned branch status snapshot. Caller owns and must call `deinit`.
    ok: git_branch_status.BranchStatusBundle,
    /// Allocated error message from the backend. Caller owns and must call `deinit`.
    failed: []u8,
    /// Non-owned fallback error message, used when allocation itself fails.
    failed_static: []const u8,

    pub fn deinit(self: BranchStatusLoadResult, allocator: std.mem.Allocator) void {
        switch (self) {
            .ok => |bundle| {
                var owned = bundle;
                owned.deinit();
            },
            .failed => |message| allocator.free(message),
            .failed_static => {},
        }
    }
};

pub const OperationResult = union(enum) {
    ok,
    /// Allocated error message from Git. Caller owns and must call `deinit`.
    failed: []u8,
    /// Non-owned fallback error message, used when allocation itself fails.
    failed_static: []const u8,

    pub fn deinit(self: OperationResult, allocator: std.mem.Allocator) void {
        switch (self) {
            .ok, .failed_static => {},
            .failed => |message| allocator.free(message),
        }
    }
};

/// Git-command diff kinds only.
///
/// Raw input such as stdin or patch files belongs to diff/source.zig, not to
/// this backend boundary. Keeping this union git-only prevents future status /
/// stage / commit operations from inheriting raw-input concerns.
pub const GitDiffKind = union(enum) {
    unstaged,
    cached,
    file: FileDiffRequest,
    range: []const u8,
    no_index: PathPair,
};

pub const FileDiffBase = enum {
    unstaged,
    cached,
};

pub const FileDiffRequest = struct {
    base: FileDiffBase,
    path: []const u8,
};

pub const PathPair = struct {
    left: []const u8,
    right: []const u8,
};

/// Request for a diff produced by running Git in a concrete repository.
pub const GitDiffRequest = struct {
    repo_root: ?[]const u8,
    kind: GitDiffKind,
};

/// Request for a read-only `git status` snapshot in a concrete repository.
pub const GitStatusRequest = struct {
    repo_root: []const u8,
};

/// Request for branch/upstream/ahead-behind status in a concrete repository.
pub const BranchStatusRequest = struct {
    repo_root: []const u8,
};

pub const OperationKind = union(enum) {
    stage_file: []const u8,
    unstage_file: []const u8,
    discard_file: []const u8,
    stage_patch: StagePatchRequest,
    unstage_patch: StagePatchRequest,
    commit: CommitRequest,
    amend: CommitRequest,
    push: PushRequest,
};

pub const StagePatchRequest = struct {
    patch: []const u8,
};

pub const CommitRequest = struct {
    subject: []const u8,
    body: ?[]const u8 = null,
};

pub const PushRequest = struct {
    branch: []const u8,
    remote: []const u8,
    remote_branch: []const u8,
    /// Commit snapshot used by the pre-push safety check. The push argv uses
    /// the branch refspec; this OID only proves the branch has not moved.
    oid: []const u8,
};

/// Request for a write operation executed in a concrete repository.
///
/// The app snapshots `repo_root` and paths before spawning the task so a later
/// repo switch cannot change where the operation runs.
pub const OperationRequest = struct {
    repo_root: []const u8,
    kind: OperationKind,
    env_map: ?*const std.process.Environ.Map = null,
};

/// Minimal Git command backend boundary.
///
/// The interface starts with diff loading only. Status, stage, commit, and
/// history APIs should be added when those features are implemented, with their
/// own result shapes instead of reusing LoadResult blindly.
pub const Backend = struct {
    ptr: *anyopaque,
    load_diff_fn: *const fn (*anyopaque, std.mem.Allocator, std.Io, GitDiffRequest) LoadError!LoadResult,
    load_status_fn: *const fn (*anyopaque, std.mem.Allocator, std.Io, GitStatusRequest) LoadError!StatusLoadResult,
    load_branch_status_fn: *const fn (*anyopaque, std.mem.Allocator, std.Io, BranchStatusRequest) LoadError!BranchStatusLoadResult,
    run_operation_fn: *const fn (*anyopaque, std.mem.Allocator, std.Io, OperationRequest) LoadError!OperationResult,

    pub fn loadDiff(self: Backend, allocator: std.mem.Allocator, io: std.Io, request: GitDiffRequest) LoadError!LoadResult {
        return self.load_diff_fn(self.ptr, allocator, io, request);
    }

    pub fn loadStatus(self: Backend, allocator: std.mem.Allocator, io: std.Io, request: GitStatusRequest) LoadError!StatusLoadResult {
        return self.load_status_fn(self.ptr, allocator, io, request);
    }

    pub fn loadBranchStatus(self: Backend, allocator: std.mem.Allocator, io: std.Io, request: BranchStatusRequest) LoadError!BranchStatusLoadResult {
        return self.load_branch_status_fn(self.ptr, allocator, io, request);
    }

    pub fn runOperation(self: Backend, allocator: std.mem.Allocator, io: std.Io, request: OperationRequest) LoadError!OperationResult {
        return self.run_operation_fn(self.ptr, allocator, io, request);
    }
};

pub const LocalCommandBackend = struct {
    const git_diff_unstaged = [_][]const u8{ "git", "diff", "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/" };
    const git_diff_cached = [_][]const u8{ "git", "diff", "--cached", "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/" };

    pub fn backend(self: *LocalCommandBackend) Backend {
        return .{
            .ptr = self,
            .load_diff_fn = loadDiffErased,
            .load_status_fn = loadStatusErased,
            .load_branch_status_fn = loadBranchStatusErased,
            .run_operation_fn = runOperationErased,
        };
    }

    pub fn loadDiff(_: *LocalCommandBackend, allocator: std.mem.Allocator, io: std.Io, request: GitDiffRequest) LoadError!LoadResult {
        return switch (request.kind) {
            .unstaged => loadGitDiff(allocator, io, repoRoot(request), &git_diff_unstaged),
            .cached => loadGitDiff(allocator, io, repoRoot(request), &git_diff_cached),
            .file => |file| loadGitFileDiff(allocator, io, repoRoot(request), file),
            .range => |range| loadGitDiffRange(allocator, io, repoRoot(request), range),
            .no_index => |paths| loadNoIndexDiff(allocator, io, paths),
        };
    }

    pub fn loadStatus(_: *LocalCommandBackend, allocator: std.mem.Allocator, io: std.Io, request: GitStatusRequest) LoadError!StatusLoadResult {
        return loadGitStatus(allocator, io, request.repo_root);
    }

    pub fn loadBranchStatus(_: *LocalCommandBackend, allocator: std.mem.Allocator, io: std.Io, request: BranchStatusRequest) LoadError!BranchStatusLoadResult {
        return loadGitBranchStatus(allocator, io, request.repo_root);
    }

    pub fn runOperation(_: *LocalCommandBackend, allocator: std.mem.Allocator, io: std.Io, request: OperationRequest) LoadError!OperationResult {
        return switch (request.kind) {
            .stage_file => |path| runGitAdd(allocator, io, request.repo_root, path),
            .unstage_file => |path| runGitUnstage(allocator, io, request.repo_root, path),
            .discard_file => |path| runGitDiscard(allocator, io, request.repo_root, path),
            .stage_patch => |patch| runGitApplyCached(allocator, io, request.repo_root, patch.patch),
            .unstage_patch => |patch| runGitApplyCachedReverse(allocator, io, request.repo_root, patch.patch),
            .commit => |commit| runGitCommit(allocator, io, request.repo_root, commit),
            .amend => |commit| runGitAmend(allocator, io, request.repo_root, commit),
            .push => |push| runGitPush(allocator, io, request.repo_root, request.env_map, push),
        };
    }

    fn loadDiffErased(ctx: *anyopaque, allocator: std.mem.Allocator, io: std.Io, request: GitDiffRequest) LoadError!LoadResult {
        const self: *LocalCommandBackend = @ptrCast(@alignCast(ctx));
        return self.loadDiff(allocator, io, request);
    }

    fn loadStatusErased(ctx: *anyopaque, allocator: std.mem.Allocator, io: std.Io, request: GitStatusRequest) LoadError!StatusLoadResult {
        const self: *LocalCommandBackend = @ptrCast(@alignCast(ctx));
        return self.loadStatus(allocator, io, request);
    }

    fn loadBranchStatusErased(ctx: *anyopaque, allocator: std.mem.Allocator, io: std.Io, request: BranchStatusRequest) LoadError!BranchStatusLoadResult {
        const self: *LocalCommandBackend = @ptrCast(@alignCast(ctx));
        return self.loadBranchStatus(allocator, io, request);
    }

    fn runOperationErased(ctx: *anyopaque, allocator: std.mem.Allocator, io: std.Io, request: OperationRequest) LoadError!OperationResult {
        const self: *LocalCommandBackend = @ptrCast(@alignCast(ctx));
        return self.runOperation(allocator, io, request);
    }
};

fn repoRoot(request: GitDiffRequest) []const u8 {
    return request.repo_root.?;
}

fn runCapturedCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: ?[]const u8,
    argv: []const []const u8,
    stdout_limit: std.Io.Limit,
    stderr_limit: std.Io.Limit,
) LoadError!process_runner.Result {
    return process_runner.runCaptured(allocator, io, .{
        .argv = argv,
        .cwd = if (repo_root) |root| .{ .path = root } else .inherit,
        .stdout_limit = stdout_limit,
        .stderr_limit = stderr_limit,
    }) catch |err| return runnerErrorToLoadError(err);
}

fn runnerErrorToLoadError(err: process_runner.Error) LoadError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.StreamTooLong,
        else => error.SpawnFailed,
    };
}

fn loadResultFromGitCommand(allocator: std.mem.Allocator, result: process_runner.Result, fallback_label: []const u8) LoadError!LoadResult {
    switch (result.term) {
        .exited => |code| if (code == 0) {
            allocator.free(result.stderr);
            return .{ .ok = result.stdout };
        },
        else => {},
    }

    allocator.free(result.stdout);
    if (result.stderr.len > 0) return .{ .failed = result.stderr };
    allocator.free(result.stderr);

    return .{ .failed = std.fmt.allocPrint(allocator, "{s} failed: {any}", .{ fallback_label, result.term }) catch return error.OutOfMemory };
}

fn statusResultFromGitCommand(allocator: std.mem.Allocator, result: process_runner.Result, fallback_label: []const u8) LoadError!StatusLoadResult {
    switch (result.term) {
        .exited => |code| if (code == 0) {
            allocator.free(result.stderr);
            return .{ .ok = result.stdout };
        },
        else => {},
    }

    allocator.free(result.stdout);
    if (result.stderr.len > 0) return .{ .failed = result.stderr };
    allocator.free(result.stderr);

    return .{ .failed = std.fmt.allocPrint(allocator, "{s} failed: {any}", .{ fallback_label, result.term }) catch return error.OutOfMemory };
}

fn operationResultFromGitCommand(allocator: std.mem.Allocator, result: process_runner.Result, fallback_label: []const u8) LoadError!OperationResult {
    allocator.free(result.stdout);
    switch (result.term) {
        .exited => |code| if (code == 0) {
            allocator.free(result.stderr);
            return .ok;
        },
        else => {},
    }

    if (result.stderr.len > 0) return .{ .failed = result.stderr };
    allocator.free(result.stderr);

    return .{ .failed = std.fmt.allocPrint(allocator, "{s} failed: {any}", .{ fallback_label, result.term }) catch return error.OutOfMemory };
}

fn loadGitDiff(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, argv: []const []const u8) LoadError!LoadResult {
    // Use structured argv and force stable path prefixes so display/editor
    // paths do not depend on user diff.mnemonicPrefix/diff.noprefix config.
    const result = try runCapturedCommand(allocator, io, repo_root, argv, .limited(max_diff_bytes), .limited(256 * 1024));
    return loadResultFromGitCommand(allocator, result, "git diff");
}

fn loadGitDiffRange(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, range: []const u8) LoadError!LoadResult {
    const argv = [_][]const u8{ "git", "diff", "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/", range };
    return loadGitDiff(allocator, io, repo_root, &argv);
}

fn loadGitFileDiff(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, request: FileDiffRequest) LoadError!LoadResult {
    return switch (request.base) {
        .unstaged => {
            const argv = [_][]const u8{ "git", "diff", "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/", "--", request.path };
            return loadGitDiff(allocator, io, repo_root, &argv);
        },
        .cached => {
            const argv = [_][]const u8{ "git", "diff", "--cached", "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/", "--", request.path };
            return loadGitDiff(allocator, io, repo_root, &argv);
        },
    };
}

fn loadGitStatus(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8) LoadError!StatusLoadResult {
    const argv = [_][]const u8{ "git", "status", "--porcelain=v1", "-z", "-uall" };
    const result = try runCapturedCommand(allocator, io, repo_root, &argv, .limited(max_status_bytes), .limited(256 * 1024));
    return statusResultFromGitCommand(allocator, result, "git status");
}

fn loadGitBranchStatus(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8) LoadError!BranchStatusLoadResult {
    var builder = git_branch_status.Builder.init(allocator);
    defer builder.deinit();

    const head_argv = [_][]const u8{ "git", "symbolic-ref", "--quiet", "--short", "HEAD" };
    const head_result = try runGitBranchStatusCommand(allocator, io, repo_root, &head_argv);
    defer head_result.deinit(allocator);

    switch (head_result.term) {
        .exited => |code| if (code == 0) {
            try builder.setBranchHead(trimLineEnd(head_result.stdout));
        } else {
            builder.setDetached();
        },
        else => return branchStatusCommandFailure(allocator, "git symbolic-ref", head_result),
    }

    const oid_argv = [_][]const u8{ "git", "rev-parse", "--verify", "HEAD" };
    const oid_result = try runGitBranchStatusCommand(allocator, io, repo_root, &oid_argv);
    defer oid_result.deinit(allocator);
    switch (oid_result.term) {
        .exited => |code| if (code == 0) {
            try builder.setOid(trimLineEnd(oid_result.stdout));
        },
        else => return branchStatusCommandFailure(allocator, "git rev-parse HEAD", oid_result),
    }

    const upstream_argv = [_][]const u8{ "git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}" };
    const upstream_result = try runGitBranchStatusCommand(allocator, io, repo_root, &upstream_argv);
    defer upstream_result.deinit(allocator);
    var has_upstream = false;
    switch (upstream_result.term) {
        .exited => |code| if (code == 0) {
            has_upstream = true;
            try builder.setUpstream(trimLineEnd(upstream_result.stdout));
        } else {
            // No upstream is a normal local-branch/detached state; push/pull
            // gates need to distinguish it from an actual status load failure.
        },
        else => return branchStatusCommandFailure(allocator, "git rev-parse upstream", upstream_result),
    }

    if (has_upstream) {
        const ab_argv = [_][]const u8{ "git", "rev-list", "--left-right", "--count", "HEAD...@{upstream}" };
        const ab_result = try runGitBranchStatusCommand(allocator, io, repo_root, &ab_argv);
        defer ab_result.deinit(allocator);
        switch (ab_result.term) {
            .exited => |code| if (code == 0) {
                const counts = try parseRevListAheadBehind(ab_result.stdout);
                builder.setAheadBehind(counts.ahead, counts.behind);
            } else {
                return branchStatusCommandFailure(allocator, "git rev-list ahead/behind", ab_result);
            },
            else => return branchStatusCommandFailure(allocator, "git rev-list ahead/behind", ab_result),
        }
    }

    return .{ .ok = builder.finish() };
}

fn runGitBranchStatusCommand(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, argv: []const []const u8) LoadError!process_runner.Result {
    return process_runner.runCaptured(allocator, io, .{
        .argv = argv,
        .cwd = .{ .path = repo_root },
        .stdout_limit = .limited(4 * 1024),
        .stderr_limit = .limited(16 * 1024),
    }) catch |err| return runnerErrorToLoadError(err);
}

fn freeRunResult(allocator: std.mem.Allocator, result: std.process.RunResult) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn branchStatusCommandFailure(allocator: std.mem.Allocator, label: []const u8, result: process_runner.Result) LoadError!BranchStatusLoadResult {
    if (result.stderr.len > 0) return .{ .failed = try std.fmt.allocPrint(allocator, "{s} failed: {s}", .{ label, trimLineEnd(result.stderr) }) };
    return .{ .failed = try std.fmt.allocPrint(allocator, "{s} failed: {any}", .{ label, result.term }) };
}

fn trimLineEnd(text: []const u8) []const u8 {
    return std.mem.trimEnd(u8, text, "\r\n");
}

const RevListAheadBehind = struct {
    ahead: u32,
    behind: u32,
};

fn parseRevListAheadBehind(text: []const u8) LoadError!RevListAheadBehind {
    var iter = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const ahead_text = iter.next() orelse return error.SpawnFailed;
    const behind_text = iter.next() orelse return error.SpawnFailed;
    return .{
        .ahead = std.fmt.parseInt(u32, ahead_text, 10) catch return error.SpawnFailed,
        .behind = std.fmt.parseInt(u32, behind_text, 10) catch return error.SpawnFailed,
    };
}

fn runGitAdd(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, path: []const u8) LoadError!OperationResult {
    const argv = [_][]const u8{ "git", "add", "--", path };
    const result = try runCapturedCommand(allocator, io, repo_root, &argv, .limited(64 * 1024), .limited(256 * 1024));
    return operationResultFromGitCommand(allocator, result, "git add");
}

fn runGitUnstage(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, path: []const u8) LoadError!OperationResult {
    const argv = [_][]const u8{ "git", "restore", "--staged", "--", path };
    const result = try runCapturedCommand(allocator, io, repo_root, &argv, .limited(64 * 1024), .limited(256 * 1024));
    return operationResultFromGitCommand(allocator, result, "git restore --staged");
}

fn runGitDiscard(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, path: []const u8) LoadError!OperationResult {
    const argv = [_][]const u8{ "git", "restore", "--", path };
    const result = try runCapturedCommand(allocator, io, repo_root, &argv, .limited(64 * 1024), .limited(256 * 1024));
    return operationResultFromGitCommand(allocator, result, "git restore");
}

fn runGitApplyCached(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, patch: []const u8) LoadError!OperationResult {
    const argv = [_][]const u8{ "git", "apply", "--cached", "--whitespace=nowarn", "-" };
    const result = process_runner.runWithStdin(allocator, io, .{
        .argv = &argv,
        .cwd = .{ .path = repo_root },
        .stdin = patch,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(256 * 1024),
    }) catch |err| return runnerErrorToLoadError(err);

    return operationResultFromGitCommand(allocator, result, "git apply --cached");
}

fn runGitApplyCachedReverse(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, patch: []const u8) LoadError!OperationResult {
    const argv = [_][]const u8{ "git", "apply", "--cached", "--reverse", "--whitespace=nowarn", "-" };
    const result = process_runner.runWithStdin(allocator, io, .{
        .argv = &argv,
        .cwd = .{ .path = repo_root },
        .stdin = patch,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(256 * 1024),
    }) catch |err| return runnerErrorToLoadError(err);

    return operationResultFromGitCommand(allocator, result, "git apply --cached --reverse");
}

fn runGitCommit(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, request: CommitRequest) LoadError!OperationResult {
    return runGitCommitLike(allocator, io, repo_root, request, false);
}

fn runGitAmend(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, request: CommitRequest) LoadError!OperationResult {
    return runGitCommitLike(allocator, io, repo_root, request, true);
}

fn runGitPush(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, parent_env: ?*const std.process.Environ.Map, request: PushRequest) LoadError!OperationResult {
    if (!try verifyPushSnapshot(allocator, io, repo_root, request)) {
        return .{ .failed_static = "Branch changed before push; reload and try again" };
    }
    if (parent_env) |env| {
        if (env.get("GIT_SSH_COMMAND")) |ssh_command| {
            if (sshBatchModeState(ssh_command) == .interactive) {
                return .{ .failed_static = "Push requires non-interactive SSH; remove BatchMode=no from GIT_SSH_COMMAND" };
            }
        }
    }

    var env = try pushEnvironment(allocator, parent_env);
    defer env.deinit();

    const refspec = std.fmt.allocPrint(allocator, "refs/heads/{s}:refs/heads/{s}", .{ request.branch, request.remote_branch }) catch return error.OutOfMemory;
    defer allocator.free(refspec);

    const argv = [_][]const u8{ "git", "push", request.remote, refspec };
    const result = std.process.run(allocator, io, .{
        .argv = &argv,
        .cwd = .{ .path = repo_root },
        .environ_map = &env,
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(256 * 1024),
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.StreamTooLong,
        else => error.SpawnFailed,
    };

    allocator.free(result.stdout);
    switch (result.term) {
        .exited => |code| if (code == 0) {
            allocator.free(result.stderr);
            return .ok;
        },
        else => {},
    }

    if (result.stderr.len > 0) {
        const message = try pushFailureWithDiagnostics(allocator, io, &env, result.stderr);
        return .{ .failed = message };
    }
    allocator.free(result.stderr);

    return .{ .failed = std.fmt.allocPrint(allocator, "git push failed: {any}", .{result.term}) catch return error.OutOfMemory };
}

fn pushFailureWithDiagnostics(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, stderr: []u8) LoadError![]u8 {
    if (!isSshPublicKeyFailure(stderr)) return stderr;
    errdefer allocator.free(stderr);

    const normalized = try normalizeSshPublicKeyFailureForDisplay(allocator, stderr);
    defer allocator.free(normalized);

    const diagnosis = try sshPublicKeyFailureDiagnosis(allocator, io, env);
    const combined = std.fmt.allocPrint(
        allocator,
        "{s}\n\nGitFrame diagnosis:\n  {s}\n\nSuggested fix:\n{s}",
        .{ trimLineEnd(normalized), diagnosis.message, diagnosis.suggestion },
    ) catch return error.OutOfMemory;
    allocator.free(stderr);
    return combined;
}

fn isSshPublicKeyFailure(message: []const u8) bool {
    return std.mem.indexOf(u8, message, "Permission denied (publickey)") != null;
}

fn normalizeSshPublicKeyFailureForDisplay(allocator: std.mem.Allocator, stderr: []const u8) LoadError![]u8 {
    const line_normalized = try normalizeLineEndings(allocator, stderr);
    defer allocator.free(line_normalized);

    const fatal_separated = try insertLineBeforeToken(allocator, line_normalized, "fatal:");
    defer allocator.free(fatal_separated);

    return replaceAll(
        allocator,
        fatal_separated,
        "Please make sure you have the correct access rights\nand the repository exists.",
        "Please make sure you have the correct access rights and the repository exists.",
    );
}

fn normalizeLineEndings(allocator: std.mem.Allocator, text: []const u8) LoadError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\r') {
            try out.append(allocator, '\n');
            i += 1;
            if (i < text.len and text[i] == '\n') i += 1;
            continue;
        }
        try out.append(allocator, text[i]);
        i += 1;
    }

    return out.toOwnedSlice(allocator);
}

fn insertLineBeforeToken(allocator: std.mem.Allocator, text: []const u8, token: []const u8) LoadError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (std.mem.indexOfPos(u8, text, index, token)) |token_index| {
        try out.appendSlice(allocator, text[index..token_index]);
        if (token_index > 0 and text[token_index - 1] != '\n') {
            try out.append(allocator, '\n');
        }
        try out.appendSlice(allocator, token);
        index = token_index + token.len;
    }
    try out.appendSlice(allocator, text[index..]);

    return out.toOwnedSlice(allocator);
}

fn replaceAll(allocator: std.mem.Allocator, text: []const u8, needle: []const u8, replacement: []const u8) LoadError![]u8 {
    if (needle.len == 0) return allocator.dupe(u8, text) catch return error.OutOfMemory;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (std.mem.indexOfPos(u8, text, index, needle)) |match_index| {
        try out.appendSlice(allocator, text[index..match_index]);
        try out.appendSlice(allocator, replacement);
        index = match_index + needle.len;
    }
    try out.appendSlice(allocator, text[index..]);

    return out.toOwnedSlice(allocator);
}

const SshPublicKeyDiagnostic = struct {
    message: []const u8,
    suggestion: []const u8,
};

const ssh_agent_not_visible_suggestion =
    \\  1. Check whether ssh-agent is visible:
    \\     echo $SSH_AUTH_SOCK
    \\  2. If it is empty, start ssh-agent:
    \\     eval "$(ssh-agent -s)"
    \\  3. Add the key used for this repository:
    \\     ssh-add <path-to-your-git-ssh-key>
    \\     Example: ssh-add ~/.ssh/id_ed25519
    \\  4. Start GitFrame again from the same shell.
;

fn sshPublicKeyFailureDiagnosis(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) LoadError!SshPublicKeyDiagnostic {
    // `env` is the effective push environment: pushEnvironment mutates Git
    // prompt settings, but preserves SSH_AUTH_SOCK for this diagnostic.
    const auth_sock = env.get("SSH_AUTH_SOCK") orelse return .{
        .message = "SSH_AUTH_SOCK is not set; ssh-agent is not visible to GitFrame",
        .suggestion = ssh_agent_not_visible_suggestion,
    };
    if (auth_sock.len == 0) return .{
        .message = "SSH_AUTH_SOCK is empty; ssh-agent is not visible to GitFrame",
        .suggestion = ssh_agent_not_visible_suggestion,
    };

    const argv = [_][]const u8{ "ssh-add", "-l" };
    const result = std.process.run(allocator, io, .{
        .argv = &argv,
        .environ_map = env,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => .{
            .message = "could not inspect ssh-agent with ssh-add -l",
            .suggestion =
            \\  1. Check whether ssh-agent is visible:
            \\     echo $SSH_AUTH_SOCK
            \\  2. Check whether it is usable:
            \\     ssh-add -l
            \\  3. Start GitFrame again from the same shell after ssh-add succeeds.
            ,
        },
    };
    defer freeRunResult(allocator, result);

    switch (result.term) {
        .exited => |code| {
            if (code == 0) {
                return .{
                    .message = "ssh-agent is reachable and has identities",
                    .suggestion =
                    \\  1. Check the loaded SSH keys:
                    \\     ssh-add -l
                    \\  2. Confirm the key is registered with GitHub.
                    \\  3. Confirm this account can push to the repository.
                    \\  4. Check ~/.ssh/config if this host uses a custom key.
                    ,
                };
            }
            if (std.mem.indexOf(u8, result.stdout, "The agent has no identities") != null or
                std.mem.indexOf(u8, result.stderr, "The agent has no identities") != null)
            {
                return .{
                    .message = "ssh-agent is reachable but has no identities loaded",
                    .suggestion =
                    \\  1. Check loaded keys:
                    \\     ssh-add -l
                    \\  2. Add the key used for this repository:
                    \\     ssh-add <path-to-your-git-ssh-key>
                    \\     Example: ssh-add ~/.ssh/id_ed25519
                    \\  3. Start GitFrame again from the same shell.
                    ,
                };
            }
            if (std.mem.indexOf(u8, result.stderr, "Could not open a connection to your authentication agent") != null) {
                return .{
                    .message = "SSH_AUTH_SOCK is set, but ssh-add cannot connect to the agent",
                    .suggestion =
                    \\  1. Check whether ssh-agent is usable:
                    \\     ssh-add -l
                    \\  2. If it cannot connect, restart ssh-agent:
                    \\     eval "$(ssh-agent -s)"
                    \\  3. Add the key used for this repository:
                    \\     ssh-add <path-to-your-git-ssh-key>
                    \\     Example: ssh-add ~/.ssh/id_ed25519
                    \\  4. Start GitFrame again from the same shell.
                    ,
                };
            }
            return .{
                .message = "ssh-add -l could not confirm a usable key",
                .suggestion =
                \\  1. Check whether ssh-agent is usable:
                \\     ssh-add -l
                \\  2. Check GitHub key registration and repository access.
                \\  3. Check ~/.ssh/config if this host uses a custom key.
                ,
            };
        },
        else => return .{
            .message = "ssh-add -l did not exit normally",
            .suggestion =
            \\  1. Check whether ssh-agent is visible:
            \\     echo $SSH_AUTH_SOCK
            \\  2. Check whether it is usable:
            \\     ssh-add -l
            \\  3. Start GitFrame again from the same shell after ssh-add succeeds.
            ,
        },
    }
}

fn verifyPushSnapshot(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, request: PushRequest) LoadError!bool {
    const branch_argv = [_][]const u8{ "git", "symbolic-ref", "--quiet", "--short", "HEAD" };
    const branch_result = try runGitBranchStatusCommand(allocator, io, repo_root, &branch_argv);
    defer branch_result.deinit(allocator);
    switch (branch_result.term) {
        .exited => |code| if (code != 0) return false,
        else => return false,
    }
    if (!std.mem.eql(u8, trimLineEnd(branch_result.stdout), request.branch)) return false;

    const oid_argv = [_][]const u8{ "git", "rev-parse", "--verify", "HEAD" };
    const oid_result = try runGitBranchStatusCommand(allocator, io, repo_root, &oid_argv);
    defer oid_result.deinit(allocator);
    switch (oid_result.term) {
        .exited => |code| if (code != 0) return false,
        else => return false,
    }
    return std.mem.eql(u8, trimLineEnd(oid_result.stdout), request.oid);
}

fn pushEnvironment(allocator: std.mem.Allocator, parent_env: ?*const std.process.Environ.Map) LoadError!std.process.Environ.Map {
    var env = if (parent_env) |map|
        map.clone(allocator) catch return error.OutOfMemory
    else
        std.process.Environ.Map.init(allocator);
    errdefer env.deinit();

    env.put("GIT_TERMINAL_PROMPT", "0") catch return error.OutOfMemory;

    const existing_ssh = env.get("GIT_SSH_COMMAND");
    const ssh_command = if (existing_ssh) |value|
        switch (sshBatchModeState(value)) {
            .batch => allocator.dupe(u8, value) catch return error.OutOfMemory,
            .interactive => return error.SpawnFailed,
            .unspecified => std.fmt.allocPrint(allocator, "{s} -o BatchMode=yes", .{value}) catch return error.OutOfMemory,
        }
    else
        allocator.dupe(u8, "ssh -o BatchMode=yes") catch return error.OutOfMemory;
    defer allocator.free(ssh_command);
    env.put("GIT_SSH_COMMAND", ssh_command) catch return error.OutOfMemory;

    return env;
}

const SshBatchModeState = enum {
    unspecified,
    batch,
    interactive,
};

fn sshBatchModeState(command: []const u8) SshBatchModeState {
    if (indexOfIgnoreCase(command, "batchmode=no") != null) return .interactive;
    if (indexOfIgnoreCase(command, "batchmode no") != null) return .interactive;
    if (indexOfIgnoreCase(command, "batchmode=yes") != null) return .batch;
    if (indexOfIgnoreCase(command, "batchmode yes") != null) return .batch;
    // A bare/unknown BatchMode spelling is ambiguous, so keep push fail-fast
    // instead of trying to override a user-provided SSH command.
    if (indexOfIgnoreCase(command, "batchmode") != null) return .interactive;
    return .unspecified;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn runGitCommitLike(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, request: CommitRequest, amend: bool) LoadError!OperationResult {
    const argv_subject = [_][]const u8{ "git", "commit", "-m", request.subject };
    const argv_with_body = [_][]const u8{ "git", "commit", "-m", request.subject, "-m", request.body orelse "" };
    const amend_argv_subject = [_][]const u8{ "git", "commit", "--amend", "-m", request.subject };
    const amend_argv_with_body = [_][]const u8{ "git", "commit", "--amend", "-m", request.subject, "-m", request.body orelse "" };
    const argv = if (amend)
        if (request.body == null) amend_argv_subject[0..] else amend_argv_with_body[0..]
    else if (request.body == null) argv_subject[0..] else argv_with_body[0..];

    const result = try runCapturedCommand(allocator, io, repo_root, argv, .limited(256 * 1024), .limited(256 * 1024));
    return operationResultFromGitCommand(allocator, result, "git commit");
}

fn loadNoIndexDiff(allocator: std.mem.Allocator, io: std.Io, paths: PathPair) LoadError!LoadResult {
    const argv = [_][]const u8{
        "git",
        "diff",
        "--no-index",
        "--no-color",
        "--no-ext-diff",
        "--src-prefix=a/",
        "--dst-prefix=b/",
        "--",
        paths.left,
        paths.right,
    };

    // `git diff --no-index` returns 1 for "differences found", which is the
    // normal case for an external diff viewer. Only accept that widened success
    // when stdout actually contains a diff; path errors also return 1 but only
    // explain the failure on stderr.
    const result = std.process.run(allocator, io, .{
        .argv = &argv,
        .stdout_limit = .limited(max_diff_bytes),
        .stderr_limit = .limited(256 * 1024),
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.StreamTooLong,
        else => error.SpawnFailed,
    };

    if (isNoIndexSuccess(result.term, result.stdout.len)) {
        allocator.free(result.stderr);
        return .{ .ok = result.stdout };
    }

    allocator.free(result.stdout);
    if (result.stderr.len > 0) return .{ .failed = result.stderr };
    allocator.free(result.stderr);

    return .{ .failed = std.fmt.allocPrint(allocator, "git diff --no-index failed: {any}", .{result.term}) catch return error.OutOfMemory };
}

fn isNoIndexSuccess(term: std.process.Child.Term, stdout_len: usize) bool {
    return switch (term) {
        .exited => |code| code == 0 or (code == 1 and stdout_len > 0),
        else => false,
    };
}

test "LocalCommandBackend exposes backend interface" {
    var local_backend: LocalCommandBackend = .{};
    const backend = local_backend.backend();

    try std.testing.expect(backend.ptr == @as(*anyopaque, @ptrCast(&local_backend)));
}

test "Backend exposes status load interface" {
    var local_backend: LocalCommandBackend = .{};
    const backend = local_backend.backend();

    try std.testing.expect(backend.ptr == @as(*anyopaque, @ptrCast(&local_backend)));
}

test "Backend exposes operation interface" {
    var local_backend: LocalCommandBackend = .{};
    const backend = local_backend.backend();

    try std.testing.expect(backend.ptr == @as(*anyopaque, @ptrCast(&local_backend)));

    const request: OperationRequest = .{
        .repo_root = "/repo",
        .kind = .{ .unstage_file = "src/app.zig" },
    };
    try std.testing.expectEqualStrings("/repo", request.repo_root);
    try std.testing.expectEqualStrings("src/app.zig", request.kind.unstage_file);

    const commit_request: OperationRequest = .{
        .repo_root = "/repo",
        .kind = .{ .commit = .{ .subject = "subject", .body = "body" } },
    };
    try std.testing.expectEqualStrings("subject", commit_request.kind.commit.subject);
    try std.testing.expectEqualStrings("body", commit_request.kind.commit.body.?);

    const patch_request: OperationRequest = .{
        .repo_root = "/repo",
        .kind = .{ .stage_patch = .{ .patch = "diff --git a/a b/a\n" } },
    };
    try std.testing.expectEqualStrings("diff --git a/a b/a\n", patch_request.kind.stage_patch.patch);

    const amend_request: OperationRequest = .{
        .repo_root = "/repo",
        .kind = .{ .amend = .{ .subject = "subject", .body = null } },
    };
    try std.testing.expectEqualStrings("subject", amend_request.kind.amend.subject);

    const push_request: OperationRequest = .{
        .repo_root = "/repo",
        .kind = .{ .push = .{
            .branch = "feature",
            .remote = "origin",
            .remote_branch = "main",
            .oid = "abc123",
        } },
    };
    try std.testing.expectEqualStrings("feature", push_request.kind.push.branch);
    try std.testing.expectEqualStrings("origin", push_request.kind.push.remote);
    try std.testing.expectEqualStrings("main", push_request.kind.push.remote_branch);
    try std.testing.expectEqualStrings("abc123", push_request.kind.push.oid);
}

test "pushEnvironment disables interactive credential prompts" {
    var env = try pushEnvironment(std.testing.allocator, null);
    defer env.deinit();

    try std.testing.expectEqualStrings("0", env.get("GIT_TERMINAL_PROMPT").?);
    try std.testing.expectEqualStrings("ssh -o BatchMode=yes", env.get("GIT_SSH_COMMAND").?);
}

test "pushEnvironment preserves existing ssh command while adding BatchMode" {
    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    try parent.put("GIT_SSH_COMMAND", "ssh -i /tmp/key");
    try parent.put("HOME", "/home/test");

    var env = try pushEnvironment(std.testing.allocator, &parent);
    defer env.deinit();

    try std.testing.expectEqualStrings("0", env.get("GIT_TERMINAL_PROMPT").?);
    try std.testing.expectEqualStrings("ssh -i /tmp/key -o BatchMode=yes", env.get("GIT_SSH_COMMAND").?);
    try std.testing.expectEqualStrings("/home/test", env.get("HOME").?);
}

test "pushEnvironment preserves existing BatchMode yes and rejects BatchMode no" {
    var parent_yes = std.process.Environ.Map.init(std.testing.allocator);
    defer parent_yes.deinit();
    try parent_yes.put("GIT_SSH_COMMAND", "ssh -o BatchMode=yes -i /tmp/key");

    var env = try pushEnvironment(std.testing.allocator, &parent_yes);
    defer env.deinit();
    try std.testing.expectEqualStrings("ssh -o BatchMode=yes -i /tmp/key", env.get("GIT_SSH_COMMAND").?);

    var parent_no = std.process.Environ.Map.init(std.testing.allocator);
    defer parent_no.deinit();
    try parent_no.put("GIT_SSH_COMMAND", "ssh -o BatchMode=no -i /tmp/key");
    try std.testing.expectError(error.SpawnFailed, pushEnvironment(std.testing.allocator, &parent_no));
}

test "pushFailureWithDiagnostics explains missing ssh-agent socket" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    const stderr = try std.testing.allocator.dupe(
        u8,
        "git@github.com: Permission denied (publickey).fatal: Could not read from remote repository.\r\n\r\n" ++
            "Please make sure you have the correct access rights\nand the repository exists.\n",
    );
    const message = try pushFailureWithDiagnostics(std.testing.allocator, std.testing.io, &env, stderr);
    defer std.testing.allocator.free(message);

    try std.testing.expect(std.mem.indexOf(u8, message, "Permission denied (publickey).\nfatal:") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "Please make sure you have the correct access rights and the repository exists.") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "GitFrame diagnosis:\n  SSH_AUTH_SOCK is not set") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "Suggested fix:\n  1. Check whether ssh-agent is visible:") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "  3. Add the key used for this repository:") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "     ssh-add <path-to-your-git-ssh-key>") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "     Example: ssh-add ~/.ssh/id_ed25519") != null);
}

test "pushFailureWithDiagnostics explains empty ssh-agent socket" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("SSH_AUTH_SOCK", "");

    const stderr = try std.testing.allocator.dupe(u8, "git@github.com: Permission denied (publickey).\n");
    const message = try pushFailureWithDiagnostics(std.testing.allocator, std.testing.io, &env, stderr);
    defer std.testing.allocator.free(message);

    try std.testing.expect(std.mem.indexOf(u8, message, "GitFrame diagnosis:\n  SSH_AUTH_SOCK is empty") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "Suggested fix:\n  1. Check whether ssh-agent is visible:") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "  4. Start GitFrame again from the same shell.") != null);
}

test "pushFailureWithDiagnostics leaves non-publickey failures unchanged" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    const stderr = try std.testing.allocator.dupe(u8, "fatal: non-fast-forward\n");
    const message = try pushFailureWithDiagnostics(std.testing.allocator, std.testing.io, &env, stderr);
    defer std.testing.allocator.free(message);

    try std.testing.expectEqualStrings("fatal: non-fast-forward\n", message);
}

test "LocalCommandBackend push rejects stale oid before contacting remote" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);

    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try work.writeFile(io, .{ .sub_path = "README.md", .data = "hello\n" });
    try runTestGit(io, &.{ "git", "add", "README.md" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "initial" }, work);

    const repo_root = try tmp.dir.realPathFileAlloc(io, "work", std.testing.allocator);
    defer std.testing.allocator.free(repo_root);

    var local_backend: LocalCommandBackend = .{};
    const result = try local_backend.runOperation(std.testing.allocator, io, .{
        .repo_root = repo_root,
        .kind = .{ .push = .{
            .branch = "main",
            .remote = "missing",
            .remote_branch = "main",
            .oid = "not-the-current-oid",
        } },
    });
    defer result.deinit(std.testing.allocator);

    switch (result) {
        .failed_static => |message| try std.testing.expectEqualStrings("Branch changed before push; reload and try again", message),
        else => return error.ExpectedStalePushFailure,
    }
}

test "LocalCommandBackend push reports remote failure after snapshot check passes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);

    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try work.writeFile(io, .{ .sub_path = "README.md", .data = "hello\n" });
    try runTestGit(io, &.{ "git", "add", "README.md" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "initial" }, work);

    const repo_root = try tmp.dir.realPathFileAlloc(io, "work", std.testing.allocator);
    defer std.testing.allocator.free(repo_root);
    const oid = try gitOutputAlloc(io, work, &.{ "git", "rev-parse", "--verify", "HEAD" });
    defer std.testing.allocator.free(oid);

    var local_backend: LocalCommandBackend = .{};
    const result = try local_backend.runOperation(std.testing.allocator, io, .{
        .repo_root = repo_root,
        .kind = .{ .push = .{
            .branch = "main",
            .remote = "missing",
            .remote_branch = "main",
            .oid = trimLineEnd(oid),
        } },
    });
    defer result.deinit(std.testing.allocator);

    switch (result) {
        .failed => |message| try std.testing.expect(message.len > 0),
        else => return error.ExpectedRemotePushFailure,
    }
}

test "LocalCommandBackend push succeeds to a local bare remote" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try runTestGit(io, &.{ "git", "init", "--bare", "remote.git" }, tmp.dir);
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);

    const remote_root = try tmp.dir.realPathFileAlloc(io, "remote.git", std.testing.allocator);
    defer std.testing.allocator.free(remote_root);
    const repo_root = try tmp.dir.realPathFileAlloc(io, "work", std.testing.allocator);
    defer std.testing.allocator.free(repo_root);

    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try runTestGit(io, &.{ "git", "remote", "add", "origin", remote_root }, work);
    try work.writeFile(io, .{ .sub_path = "README.md", .data = "hello\n" });
    try runTestGit(io, &.{ "git", "add", "README.md" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "initial" }, work);

    const oid = try gitOutputAlloc(io, work, &.{ "git", "rev-parse", "--verify", "HEAD" });
    defer std.testing.allocator.free(oid);

    var local_backend: LocalCommandBackend = .{};
    const result = try local_backend.runOperation(std.testing.allocator, io, .{
        .repo_root = repo_root,
        .kind = .{ .push = .{
            .branch = "main",
            .remote = "origin",
            .remote_branch = "main",
            .oid = trimLineEnd(oid),
        } },
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(OperationResult.ok, result);
}

test "LocalCommandBackend loads branch status without upstream" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, tmp.dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "README.md", .data = "hello\n" });
    try runTestGit(io, &.{ "git", "add", "README.md" }, tmp.dir);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "initial" }, tmp.dir);

    const repo_root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(repo_root);

    var local_backend: LocalCommandBackend = .{};
    const result = try local_backend.loadBranchStatus(std.testing.allocator, io, .{ .repo_root = repo_root });
    defer result.deinit(std.testing.allocator);

    const status = switch (result) {
        .ok => |bundle| bundle.status,
        .failed, .failed_static => return error.UnexpectedBranchStatusFailure,
    };

    try std.testing.expectEqualStrings("main", status.branchName().?);
    try std.testing.expect(status.oid != null);
    try std.testing.expect(status.upstream == null);
    try std.testing.expect(status.ahead_behind == null);
}

test "LocalCommandBackend loads branch status with upstream" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try runTestGit(io, &.{ "git", "init", "--bare", "remote.git" }, tmp.dir);
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);

    const remote_root = try tmp.dir.realPathFileAlloc(io, "remote.git", std.testing.allocator);
    defer std.testing.allocator.free(remote_root);
    const repo_root = try tmp.dir.realPathFileAlloc(io, "work", std.testing.allocator);
    defer std.testing.allocator.free(repo_root);

    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try runTestGit(io, &.{ "git", "remote", "add", "origin", remote_root }, work);
    try work.writeFile(io, .{ .sub_path = "README.md", .data = "hello\n" });
    try runTestGit(io, &.{ "git", "add", "README.md" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "initial" }, work);
    try runTestGit(io, &.{ "git", "push", "-u", "origin", "main" }, work);

    var local_backend: LocalCommandBackend = .{};
    const result = try local_backend.loadBranchStatus(std.testing.allocator, io, .{ .repo_root = repo_root });
    defer result.deinit(std.testing.allocator);

    const status = switch (result) {
        .ok => |bundle| bundle.status,
        .failed, .failed_static => return error.UnexpectedBranchStatusFailure,
    };

    try std.testing.expectEqualStrings("main", status.branchName().?);
    try std.testing.expectEqualStrings("origin/main", status.upstream.?.name);
    try std.testing.expectEqualStrings("origin", status.upstream.?.remote);
    try std.testing.expectEqualStrings("main", status.upstream.?.remote_branch);
    try std.testing.expectEqual(@as(u32, 0), status.ahead_behind.?.ahead);
    try std.testing.expectEqual(@as(u32, 0), status.ahead_behind.?.behind);
}

fn runTestGit(io: std.Io, argv: []const []const u8, cwd: std.Io.Dir) !void {
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer freeRunResult(std.testing.allocator, result);

    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.GitCommandFailed;
}

fn gitOutputAlloc(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    errdefer freeRunResult(std.testing.allocator, result);
    switch (result.term) {
        .exited => |code| if (code == 0) {
            std.testing.allocator.free(result.stderr);
            return result.stdout;
        },
        else => {},
    }
    freeRunResult(std.testing.allocator, result);
    return error.GitCommandFailed;
}

test "GitDiffRequest cannot represent raw input sources" {
    const request = GitDiffRequest{
        .repo_root = "/repo",
        .kind = .unstaged,
    };

    try std.testing.expectEqualStrings("/repo", request.repo_root.?);
    try std.testing.expect(request.kind == .unstaged);
}

test "no-index diff treats exit one as success only with diff output" {
    try std.testing.expect(isNoIndexSuccess(.{ .exited = 0 }, 0));
    try std.testing.expect(isNoIndexSuccess(.{ .exited = 1 }, 1));
    try std.testing.expect(!isNoIndexSuccess(.{ .exited = 1 }, 0));
    try std.testing.expect(!isNoIndexSuccess(.{ .exited = 2 }, 1));
    try std.testing.expect(!isNoIndexSuccess(.{ .unknown = 9 }, 1));
}
