const std = @import("std");
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
    /// Allocated raw branch status text. Caller owns and must call `deinit`.
    ok: []u8,
    /// Allocated error message from the backend. Caller owns and must call `deinit`.
    failed: []u8,
    /// Non-owned fallback error message, used when allocation itself fails.
    failed_static: []const u8,

    pub fn deinit(self: BranchStatusLoadResult, allocator: std.mem.Allocator) void {
        switch (self) {
            .ok => |bytes| allocator.free(bytes),
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
};

pub const StagePatchRequest = struct {
    patch: []const u8,
};

pub const CommitRequest = struct {
    subject: []const u8,
    body: ?[]const u8 = null,
};

/// Request for a write operation executed in a concrete repository.
///
/// The app snapshots `repo_root` and paths before spawning the task so a later
/// repo switch cannot change where the operation runs.
pub const OperationRequest = struct {
    repo_root: []const u8,
    kind: OperationKind,
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

fn loadGitDiff(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, argv: []const []const u8) LoadError!LoadResult {
    // Use structured argv and force stable path prefixes so display/editor
    // paths do not depend on user diff.mnemonicPrefix/diff.noprefix config.
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .path = repo_root },
        .stdout_limit = .limited(max_diff_bytes),
        .stderr_limit = .limited(256 * 1024),
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.StreamTooLong,
        else => error.SpawnFailed,
    };

    switch (result.term) {
        .exited => |code| if (code == 0) {
            allocator.free(result.stderr);
            return .{ .ok = result.stdout };
        },
        else => {},
    }

    allocator.free(result.stdout);
    // Prefer Git's stderr when available; it usually contains the actionable
    // reason, for example "not a git repository".
    if (result.stderr.len > 0) return .{ .failed = result.stderr };
    allocator.free(result.stderr);

    return .{ .failed = std.fmt.allocPrint(allocator, "git diff failed: {any}", .{result.term}) catch return error.OutOfMemory };
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
    const result = std.process.run(allocator, io, .{
        .argv = &argv,
        .cwd = .{ .path = repo_root },
        .stdout_limit = .limited(max_status_bytes),
        .stderr_limit = .limited(256 * 1024),
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.StreamTooLong,
        else => error.SpawnFailed,
    };

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

    return .{ .failed = std.fmt.allocPrint(allocator, "git status failed: {any}", .{result.term}) catch return error.OutOfMemory };
}

fn loadGitBranchStatus(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8) LoadError!BranchStatusLoadResult {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const head_argv = [_][]const u8{ "git", "symbolic-ref", "--quiet", "--short", "HEAD" };
    const head_result = try runGitBranchStatusCommand(allocator, io, repo_root, &head_argv);
    defer freeRunResult(allocator, head_result);

    switch (head_result.term) {
        .exited => |code| if (code == 0) {
            try appendBranchStatusLine(&out, allocator, "# branch.head {s}\n", .{trimLineEnd(head_result.stdout)});
        } else {
            try out.appendSlice(allocator, "# branch.head (detached)\n");
        },
        else => return branchStatusCommandFailure(allocator, "git symbolic-ref", head_result),
    }

    const oid_argv = [_][]const u8{ "git", "rev-parse", "--verify", "HEAD" };
    const oid_result = try runGitBranchStatusCommand(allocator, io, repo_root, &oid_argv);
    defer freeRunResult(allocator, oid_result);
    switch (oid_result.term) {
        .exited => |code| if (code == 0) {
            try appendBranchStatusLine(&out, allocator, "# branch.oid {s}\n", .{trimLineEnd(oid_result.stdout)});
        },
        else => return branchStatusCommandFailure(allocator, "git rev-parse HEAD", oid_result),
    }

    const upstream_argv = [_][]const u8{ "git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}" };
    const upstream_result = try runGitBranchStatusCommand(allocator, io, repo_root, &upstream_argv);
    defer freeRunResult(allocator, upstream_result);
    var upstream: ?[]const u8 = null;
    switch (upstream_result.term) {
        .exited => |code| if (code == 0) {
            upstream = trimLineEnd(upstream_result.stdout);
            try appendBranchStatusLine(&out, allocator, "# branch.upstream {s}\n", .{upstream.?});
        } else {
            // No upstream is a normal local-branch/detached state; push/pull
            // gates need to distinguish it from an actual status load failure.
        },
        else => return branchStatusCommandFailure(allocator, "git rev-parse upstream", upstream_result),
    }

    if (upstream) |_| {
        const ab_argv = [_][]const u8{ "git", "rev-list", "--left-right", "--count", "HEAD...@{upstream}" };
        const ab_result = try runGitBranchStatusCommand(allocator, io, repo_root, &ab_argv);
        defer freeRunResult(allocator, ab_result);
        switch (ab_result.term) {
            .exited => |code| if (code == 0) {
                const counts = try parseRevListAheadBehind(ab_result.stdout);
                try appendBranchStatusLine(&out, allocator, "# branch.ab +{d} -{d}\n", .{ counts.ahead, counts.behind });
            } else {
                return branchStatusCommandFailure(allocator, "git rev-list ahead/behind", ab_result);
            },
            else => return branchStatusCommandFailure(allocator, "git rev-list ahead/behind", ab_result),
        }
    }

    return .{ .ok = try out.toOwnedSlice(allocator) };
}

fn runGitBranchStatusCommand(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, argv: []const []const u8) LoadError!std.process.RunResult {
    return std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .path = repo_root },
        .stdout_limit = .limited(4 * 1024),
        .stderr_limit = .limited(16 * 1024),
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.StreamTooLong,
        else => error.SpawnFailed,
    };
}

fn freeRunResult(allocator: std.mem.Allocator, result: std.process.RunResult) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn branchStatusCommandFailure(allocator: std.mem.Allocator, label: []const u8, result: std.process.RunResult) LoadError!BranchStatusLoadResult {
    if (result.stderr.len > 0) return .{ .failed = try std.fmt.allocPrint(allocator, "{s} failed: {s}", .{ label, trimLineEnd(result.stderr) }) };
    return .{ .failed = try std.fmt.allocPrint(allocator, "{s} failed: {any}", .{ label, result.term }) };
}

fn appendBranchStatusLine(out: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) LoadError!void {
    const text = std.fmt.allocPrint(allocator, fmt, args) catch return error.OutOfMemory;
    defer allocator.free(text);
    out.appendSlice(allocator, text) catch return error.OutOfMemory;
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
    const result = std.process.run(allocator, io, .{
        .argv = &argv,
        .cwd = .{ .path = repo_root },
        .stdout_limit = .limited(64 * 1024),
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

    if (result.stderr.len > 0) return .{ .failed = result.stderr };
    allocator.free(result.stderr);

    return .{ .failed = std.fmt.allocPrint(allocator, "git add failed: {any}", .{result.term}) catch return error.OutOfMemory };
}

fn runGitUnstage(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, path: []const u8) LoadError!OperationResult {
    const argv = [_][]const u8{ "git", "restore", "--staged", "--", path };
    const result = std.process.run(allocator, io, .{
        .argv = &argv,
        .cwd = .{ .path = repo_root },
        .stdout_limit = .limited(64 * 1024),
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

    if (result.stderr.len > 0) return .{ .failed = result.stderr };
    allocator.free(result.stderr);

    return .{ .failed = std.fmt.allocPrint(allocator, "git restore --staged failed: {any}", .{result.term}) catch return error.OutOfMemory };
}

fn runGitDiscard(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, path: []const u8) LoadError!OperationResult {
    const argv = [_][]const u8{ "git", "restore", "--", path };
    const result = std.process.run(allocator, io, .{
        .argv = &argv,
        .cwd = .{ .path = repo_root },
        .stdout_limit = .limited(64 * 1024),
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

    if (result.stderr.len > 0) return .{ .failed = result.stderr };
    allocator.free(result.stderr);

    return .{ .failed = std.fmt.allocPrint(allocator, "git restore failed: {any}", .{result.term}) catch return error.OutOfMemory };
}

fn runGitApplyCached(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, patch: []const u8) LoadError!OperationResult {
    const argv = [_][]const u8{ "git", "apply", "--cached", "--whitespace=nowarn", "-" };
    const result = process_runner.runWithStdin(allocator, io, .{
        .argv = &argv,
        .cwd = .{ .path = repo_root },
        .stdin = patch,
        .stdout_limit = .limited(64 * 1024),
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

    if (result.stderr.len > 0) return .{ .failed = result.stderr };
    allocator.free(result.stderr);

    return .{ .failed = std.fmt.allocPrint(allocator, "git apply --cached failed: {any}", .{result.term}) catch return error.OutOfMemory };
}

fn runGitApplyCachedReverse(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, patch: []const u8) LoadError!OperationResult {
    const argv = [_][]const u8{ "git", "apply", "--cached", "--reverse", "--whitespace=nowarn", "-" };
    const result = process_runner.runWithStdin(allocator, io, .{
        .argv = &argv,
        .cwd = .{ .path = repo_root },
        .stdin = patch,
        .stdout_limit = .limited(64 * 1024),
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

    if (result.stderr.len > 0) return .{ .failed = result.stderr };
    allocator.free(result.stderr);

    return .{ .failed = std.fmt.allocPrint(allocator, "git apply --cached --reverse failed: {any}", .{result.term}) catch return error.OutOfMemory };
}

fn runGitCommit(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, request: CommitRequest) LoadError!OperationResult {
    return runGitCommitLike(allocator, io, repo_root, request, false);
}

fn runGitAmend(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, request: CommitRequest) LoadError!OperationResult {
    return runGitCommitLike(allocator, io, repo_root, request, true);
}

fn runGitCommitLike(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, request: CommitRequest, amend: bool) LoadError!OperationResult {
    const argv_subject = [_][]const u8{ "git", "commit", "-m", request.subject };
    const argv_with_body = [_][]const u8{ "git", "commit", "-m", request.subject, "-m", request.body orelse "" };
    const amend_argv_subject = [_][]const u8{ "git", "commit", "--amend", "-m", request.subject };
    const amend_argv_with_body = [_][]const u8{ "git", "commit", "--amend", "-m", request.subject, "-m", request.body orelse "" };
    const argv = if (amend)
        if (request.body == null) amend_argv_subject[0..] else amend_argv_with_body[0..]
    else if (request.body == null) argv_subject[0..] else argv_with_body[0..];

    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .path = repo_root },
        .stdout_limit = .limited(256 * 1024),
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

    if (result.stderr.len > 0) return .{ .failed = result.stderr };
    allocator.free(result.stderr);

    return .{ .failed = std.fmt.allocPrint(allocator, "git commit failed: {any}", .{result.term}) catch return error.OutOfMemory };
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

    const text = switch (result) {
        .ok => |bytes| bytes,
        .failed, .failed_static => return error.UnexpectedBranchStatusFailure,
    };

    try std.testing.expect(std.mem.indexOf(u8, text, "# branch.head main\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "# branch.upstream ") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "# branch.ab ") == null);
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
