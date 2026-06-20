const std = @import("std");

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

/// Git-command diff kinds only.
///
/// Raw input such as stdin or patch files belongs to diff/source.zig, not to
/// this backend boundary. Keeping this union git-only prevents future status /
/// stage / commit operations from inheriting raw-input concerns.
pub const GitDiffKind = union(enum) {
    unstaged,
    cached,
    range: []const u8,
    no_index: PathPair,
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

/// Minimal Git command backend boundary.
///
/// The interface starts with diff loading only. Status, stage, commit, and
/// history APIs should be added when those features are implemented, with their
/// own result shapes instead of reusing LoadResult blindly.
pub const Backend = struct {
    ptr: *anyopaque,
    load_diff_fn: *const fn (*anyopaque, std.mem.Allocator, std.Io, GitDiffRequest) LoadError!LoadResult,
    load_status_fn: *const fn (*anyopaque, std.mem.Allocator, std.Io, GitStatusRequest) LoadError!StatusLoadResult,

    pub fn loadDiff(self: Backend, allocator: std.mem.Allocator, io: std.Io, request: GitDiffRequest) LoadError!LoadResult {
        return self.load_diff_fn(self.ptr, allocator, io, request);
    }

    pub fn loadStatus(self: Backend, allocator: std.mem.Allocator, io: std.Io, request: GitStatusRequest) LoadError!StatusLoadResult {
        return self.load_status_fn(self.ptr, allocator, io, request);
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
        };
    }

    pub fn loadDiff(_: *LocalCommandBackend, allocator: std.mem.Allocator, io: std.Io, request: GitDiffRequest) LoadError!LoadResult {
        return switch (request.kind) {
            .unstaged => loadGitDiff(allocator, io, repoRoot(request), &git_diff_unstaged),
            .cached => loadGitDiff(allocator, io, repoRoot(request), &git_diff_cached),
            .range => |range| loadGitDiffRange(allocator, io, repoRoot(request), range),
            .no_index => |paths| loadNoIndexDiff(allocator, io, paths),
        };
    }

    pub fn loadStatus(_: *LocalCommandBackend, allocator: std.mem.Allocator, io: std.Io, request: GitStatusRequest) LoadError!StatusLoadResult {
        return loadGitStatus(allocator, io, request.repo_root);
    }

    fn loadDiffErased(ctx: *anyopaque, allocator: std.mem.Allocator, io: std.Io, request: GitDiffRequest) LoadError!LoadResult {
        const self: *LocalCommandBackend = @ptrCast(@alignCast(ctx));
        return self.loadDiff(allocator, io, request);
    }

    fn loadStatusErased(ctx: *anyopaque, allocator: std.mem.Allocator, io: std.Io, request: GitStatusRequest) LoadError!StatusLoadResult {
        const self: *LocalCommandBackend = @ptrCast(@alignCast(ctx));
        return self.loadStatus(allocator, io, request);
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
