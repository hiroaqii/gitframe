//! Bounded, read-only local Git contracts.
//!
//! Repository commands accept only a borrowed descriptor-bound context. The
//! caller owns that descriptor and its controlled environment for the whole
//! synchronous call; display paths never enter this module as cwd authority.

const std = @import("std");
const git_command = @import("command.zig");
const process_runner = @import("../process/runner.zig");

pub const max_diff_bytes = 16 * 1024 * 1024;
pub const max_status_bytes = 8 * 1024 * 1024;
pub const max_repository_manifest_bytes = 16 * 1024 * 1024;
pub const tracked_numstat_stdout_limit = 2 * 1024 * 1024;
pub const tracked_numstat_stderr_limit = 256 * 1024;
pub const staged_diff_capture_limit = 4 * 1024 * 1024;

pub const LoadResult = union(enum) {
    ok: []u8,
    failed: []u8,
    failed_static: []const u8,

    pub fn deinit(self: LoadResult, allocator: std.mem.Allocator) void {
        switch (self) {
            .ok, .failed => |bytes| allocator.free(bytes),
            .failed_static => {},
        }
    }
};

pub const StatusLoadResult = union(enum) {
    ok: []u8,
    failed: []u8,
    failed_static: []const u8,

    pub fn deinit(self: StatusLoadResult, allocator: std.mem.Allocator) void {
        switch (self) {
            .ok, .failed => |bytes| allocator.free(bytes),
            .failed_static => {},
        }
    }
};

pub const RepositoryManifestLoadResult = union(enum) {
    ok: []u8,
    failed: []u8,
    failed_static: []const u8,

    pub fn deinit(self: RepositoryManifestLoadResult, allocator: std.mem.Allocator) void {
        switch (self) {
            .ok, .failed => |bytes| allocator.free(bytes),
            .failed_static => {},
        }
    }
};

pub const RepositoryFileStatusLoadResult = union(enum) {
    ok: []u8,
    failed_static: []const u8,

    pub fn deinit(self: RepositoryFileStatusLoadResult, allocator: std.mem.Allocator) void {
        switch (self) {
            .ok => |bytes| allocator.free(bytes),
            .failed_static => {},
        }
    }
};

pub const GitDiffKind = union(enum) {
    unstaged,
    file: FileDiffRequest,
    range: []const u8,
};

pub const FileDiffBase = enum {
    unstaged,
    cached,
};

pub const FileDiffRequest = struct {
    base: FileDiffBase,
    path: []const u8,
};

pub const GitDiffRequest = struct {
    context: git_command.DirectoryContext,
    kind: GitDiffKind,
};

pub const ReadOrigin = enum {
    foreground,
    background,
};

pub const GitStatusRequest = struct {
    context: git_command.DirectoryContext,
    origin: ReadOrigin = .foreground,
};

pub const RepositoryManifestRequest = struct {
    context: git_command.DirectoryContext,
};

pub const RepositoryFileStatusRequest = struct {
    context: git_command.DirectoryContext,
};

pub const TrackedNumstatRequest = struct {
    context: git_command.DirectoryContext,
    paths: []const []const u8,
    staged: bool,
};

pub const TrackedNumstatResult = union(enum) {
    ok: []u8,
    unavailable,

    pub fn deinit(self: TrackedNumstatResult, allocator: std.mem.Allocator) void {
        switch (self) {
            .ok => |bytes| allocator.free(bytes),
            .unavailable => {},
        }
    }
};

pub const StagedDiffRequest = struct {
    context: git_command.DirectoryContext,
};

pub const StagedDiffResult = union(enum) {
    ok: []u8,
    failed_static: []const u8,

    pub fn deinit(self: StagedDiffResult, allocator: std.mem.Allocator) void {
        switch (self) {
            .ok => |bytes| allocator.free(bytes),
            .failed_static => {},
        }
    }
};

pub const HeadBasis = union(enum) {
    oid: []u8,
    unborn,

    pub fn deinit(self: *HeadBasis, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .oid => |oid| allocator.free(oid),
            .unborn => {},
        }
        self.* = .unborn;
    }

    pub fn eql(left: HeadBasis, right: HeadBasis) bool {
        if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
        return switch (left) {
            .oid => |oid| std.mem.eql(u8, oid, right.oid),
            .unborn => true,
        };
    }
};

pub const RepositoryPathHistoryFact = union(enum) {
    committed: i64,
    uncommitted,
};

pub const RepositoryPathHistoryKnown = struct {
    /// A positive fact is intentionally impossible to represent without the
    /// exact HEAD observation against which it was classified.
    head: HeadBasis,
    fact: RepositoryPathHistoryFact,

    pub fn deinit(self: *RepositoryPathHistoryKnown, allocator: std.mem.Allocator) void {
        self.head.deinit(allocator);
        self.* = undefined;
    }
};

pub const RepositoryPathHistoryOutcome = union(enum) {
    known: RepositoryPathHistoryKnown,
    unavailable,

    pub fn deinit(self: *RepositoryPathHistoryOutcome, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .known => |*known| known.deinit(allocator),
            .unavailable => {},
        }
        self.* = .unavailable;
    }
};

pub const RepositoryPathHistoryRequest = struct {
    context: git_command.DirectoryContext,
    /// Byte-exact repository-relative path. It is passed only as one argv item
    /// after `--`; this API performs no display conversion or rename following.
    path: []const u8,
};

const path_history_stdout_limit = 16 * 1024;
const path_history_stderr_limit = 64 * 1024;
const maximum_utc_second: i64 = 253_402_300_799;

/// Classifies the exact current path before consulting history, then proves
/// that HEAD did not move across the complete query. Mechanical failures are
/// returned to the caller, which owns the page-local unavailable terminal;
/// ambiguous Git state is represented directly as `.unavailable`.
pub fn loadRepositoryPathHistory(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: RepositoryPathHistoryRequest,
) git_command.Error!RepositoryPathHistoryOutcome {
    return loadRepositoryPathHistoryWithHook(allocator, io, request, null);
}

const BeforeHeadRecheckHook = struct {
    context: *anyopaque,
    run: *const fn (*anyopaque) void,
};

fn loadRepositoryPathHistoryWithHook(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: RepositoryPathHistoryRequest,
    before_head_recheck: ?BeforeHeadRecheckHook,
) git_command.Error!RepositoryPathHistoryOutcome {
    var before = (try readHeadBasis(allocator, io, request.context)) orelse return .unavailable;
    var before_moved = false;
    defer if (!before_moved) before.deinit(allocator);

    const in_head = switch (before) {
        .oid => |oid| (try pathInHeadTree(allocator, io, request.context, oid, request.path)) orelse
            return .unavailable,
        .unborn => false,
    };
    const in_index = (try exactPathPresence(
        allocator,
        io,
        request.context,
        &.{ "git", "--no-optional-locks", "--literal-pathspecs", "ls-files", "-z", "--cached", "--", request.path },
        request.path,
    )) orelse return .unavailable;
    const untracked = (try exactPathPresence(
        allocator,
        io,
        request.context,
        &.{ "git", "--no-optional-locks", "--literal-pathspecs", "ls-files", "-z", "--others", "--exclude-standard", "--", request.path },
        request.path,
    )) orelse return .unavailable;
    if (in_index and untracked) return .unavailable;

    const fact: RepositoryPathHistoryFact = switch (classifyCurrentPath(in_head, in_index, untracked)) {
        .uncommitted => .uncommitted,
        .history => .{ .committed = (try lastCommitTimestamp(
            allocator,
            io,
            request.context,
            before.oid,
            request.path,
        )) orelse return .unavailable },
        .unavailable => return .unavailable,
    };

    if (before_head_recheck) |hook| hook.run(hook.context);
    var after = (try readHeadBasis(allocator, io, request.context)) orelse return .unavailable;
    defer after.deinit(allocator);
    if (!before.eql(after)) return .unavailable;

    before_moved = true;
    return .{ .known = .{ .head = before, .fact = fact } };
}

fn readHeadBasis(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
) git_command.Error!?HeadBasis {
    const oid_result = try runPathHistoryCommand(
        allocator,
        io,
        context,
        &.{ "git", "--no-optional-locks", "rev-parse", "--verify", "HEAD" },
    );
    defer oid_result.deinit(allocator);
    if (exitedWith(oid_result.term, 0)) {
        const oid = exactLine(oid_result.stdout) orelse return null;
        if (!validObjectId(oid)) return null;
        return .{ .oid = allocator.dupe(u8, oid) catch return error.OutOfMemory };
    }

    const symbolic_result = try runPathHistoryCommand(
        allocator,
        io,
        context,
        &.{ "git", "--no-optional-locks", "symbolic-ref", "-q", "HEAD" },
    );
    defer symbolic_result.deinit(allocator);
    if (!exitedWith(symbolic_result.term, 0)) return null;
    const reference = exactLine(symbolic_result.stdout) orelse return null;
    if (!std.mem.startsWith(u8, reference, "refs/") or reference.len <= "refs/".len) return null;

    const ref_result = try runPathHistoryCommand(
        allocator,
        io,
        context,
        &.{ "git", "--no-optional-locks", "show-ref", "--verify", "--quiet", reference },
    );
    defer ref_result.deinit(allocator);
    if (!exitedWith(ref_result.term, 1) or ref_result.stdout.len != 0) return null;
    return .unborn;
}

fn pathInHeadTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    oid: []const u8,
    path: []const u8,
) git_command.Error!?bool {
    const result = try runPathHistoryCommand(
        allocator,
        io,
        context,
        &.{ "git", "--no-optional-locks", "--literal-pathspecs", "ls-tree", "-z", oid, "--", path },
    );
    defer result.deinit(allocator);
    if (!exitedWith(result.term, 0) or result.stderr.len != 0) return null;
    if (result.stdout.len == 0) return false;
    if (result.stdout[result.stdout.len - 1] != 0 or
        std.mem.indexOfScalar(u8, result.stdout[0 .. result.stdout.len - 1], 0) != null)
    {
        return null;
    }
    const record = result.stdout[0 .. result.stdout.len - 1];
    const tab = std.mem.indexOfScalar(u8, record, '\t') orelse return null;
    if (tab == 0 or !std.mem.eql(u8, record[tab + 1 ..], path)) return null;
    var fields = std.mem.tokenizeScalar(u8, record[0..tab], ' ');
    const mode = fields.next() orelse return null;
    const kind = fields.next() orelse return null;
    const object_id = fields.next() orelse return null;
    if (fields.next() != null or mode.len != 6 or
        !(std.mem.eql(u8, kind, "blob") or std.mem.eql(u8, kind, "commit")) or
        !validObjectId(object_id)) return null;
    for (mode) |byte| if (byte < '0' or byte > '7') return null;
    return true;
}

fn exactPathPresence(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    argv: []const []const u8,
    path: []const u8,
) git_command.Error!?bool {
    const result = try runPathHistoryCommand(allocator, io, context, argv);
    defer result.deinit(allocator);
    if (!exitedWith(result.term, 0) or result.stderr.len != 0) return null;
    if (result.stdout.len == 0) return false;
    if (result.stdout.len != path.len + 1 or result.stdout[result.stdout.len - 1] != 0) return null;
    return std.mem.eql(u8, result.stdout[0..path.len], path);
}

fn lastCommitTimestamp(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    head_oid: []const u8,
    path: []const u8,
) git_command.Error!?i64 {
    const result = try runPathHistoryCommand(
        allocator,
        io,
        context,
        &.{ "git", "--no-pager", "--no-optional-locks", "--literal-pathspecs", "log", "--no-color", "--no-follow", "-1", "--format=%H%x00%ct", head_oid, "--", path },
    );
    defer result.deinit(allocator);
    if (!exitedWith(result.term, 0) or result.stderr.len != 0) return null;
    const line = exactLine(result.stdout) orelse return null;
    const parsed = parseHistoryRecord(line) orelse return null;

    const shallow_result = try runPathHistoryCommand(
        allocator,
        io,
        context,
        &.{ "git", "--no-optional-locks", "rev-parse", "--is-shallow-repository" },
    );
    defer shallow_result.deinit(allocator);
    if (!exitedWith(shallow_result.term, 0) or shallow_result.stderr.len != 0) return null;
    const shallow = exactLine(shallow_result.stdout) orelse return null;
    if (std.mem.eql(u8, shallow, "true")) {
        if (!(try commitHasLocallyVisibleParent(allocator, io, context, parsed.oid))) return null;
    } else if (!std.mem.eql(u8, shallow, "false")) {
        return null;
    }
    return parsed.timestamp;
}

const CurrentPathClass = enum { history, uncommitted, unavailable };

fn classifyCurrentPath(in_head: bool, in_index: bool, untracked: bool) CurrentPathClass {
    if (in_index and untracked) return .unavailable;
    if (!in_head and (in_index or untracked)) return .uncommitted;
    if (in_head and !in_index and untracked) return .uncommitted;
    if (in_head and in_index) return .history;
    return .unavailable;
}

const ParsedHistoryRecord = struct { oid: []const u8, timestamp: i64 };

fn parseHistoryRecord(line: []const u8) ?ParsedHistoryRecord {
    const separator = std.mem.indexOfScalar(u8, line, 0) orelse return null;
    if (std.mem.indexOfScalarPos(u8, line, separator + 1, 0) != null) return null;
    const oid = line[0..separator];
    if (!validObjectId(oid)) return null;
    const timestamp = std.fmt.parseInt(i64, line[separator + 1 ..], 10) catch return null;
    if (timestamp < 0 or timestamp > maximum_utc_second) return null;
    return .{ .oid = oid, .timestamp = timestamp };
}

fn commitHasLocallyVisibleParent(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    commit_oid: []const u8,
) git_command.Error!bool {
    const result = try runPathHistoryCommand(
        allocator,
        io,
        context,
        &.{ "git", "--no-optional-locks", "rev-list", "--parents", "-n", "1", commit_oid },
    );
    defer result.deinit(allocator);
    if (!exitedWith(result.term, 0) or result.stderr.len != 0) return false;
    const line = exactLine(result.stdout) orelse return false;
    var words = std.mem.tokenizeScalar(u8, line, ' ');
    const commit = words.next() orelse return false;
    if (!std.mem.eql(u8, commit, commit_oid)) return false;
    const parent = words.next() orelse return false;
    if (!validObjectId(parent)) return false;

    const parent_result = try runPathHistoryCommand(
        allocator,
        io,
        context,
        &.{ "git", "--no-optional-locks", "cat-file", "-e", parent },
    );
    defer parent_result.deinit(allocator);
    return exitedWith(parent_result.term, 0) and
        parent_result.stdout.len == 0 and parent_result.stderr.len == 0;
}

fn runPathHistoryCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    argv: []const []const u8,
) git_command.Error!process_runner.Result {
    return git_command.runCaptured(allocator, io, context, .{
        .argv = argv,
        .stdout_limit = .limited(path_history_stdout_limit),
        .stderr_limit = .limited(path_history_stderr_limit),
    });
}

fn exitedWith(term: std.process.Child.Term, expected: u8) bool {
    return switch (term) {
        .exited => |code| code == expected,
        else => false,
    };
}

fn exactLine(bytes: []const u8) ?[]const u8 {
    if (bytes.len < 2 or bytes[bytes.len - 1] != '\n') return null;
    const line = bytes[0 .. bytes.len - 1];
    if (std.mem.indexOfScalar(u8, line, '\n') != null or std.mem.indexOfScalar(u8, line, '\r') != null) return null;
    return line;
}

fn validObjectId(oid: []const u8) bool {
    if (oid.len != 40 and oid.len != 64) return false;
    for (oid) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

const git_diff_unstaged = [_][]const u8{ "git", "diff", "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/" };
const foreground_status_argv = [_][]const u8{ "git", "status", "--porcelain=v1", "-z", "-uall" };
const background_status_argv = [_][]const u8{ "git", "--no-optional-locks", "status", "--porcelain=v1", "-z", "-uall" };
const repository_manifest_argv = [_][]const u8{
    "git",
    "--no-optional-locks",
    "ls-files",
    "-z",
    "--cached",
    "--others",
    "--exclude-standard",
    "--deduplicate",
};
const repository_file_status_argv = [_][]const u8{
    "git",
    "--no-optional-locks",
    "status",
    "--porcelain=v1",
    "-z",
    "-uall",
};

pub fn loadDiff(allocator: std.mem.Allocator, io: std.Io, request: GitDiffRequest) git_command.Error!LoadResult {
    return switch (request.kind) {
        .unstaged => loadGitDiff(allocator, io, request.context, &git_diff_unstaged),
        .file => |file| loadGitFileDiff(allocator, io, request.context, file),
        .range => |range| loadGitDiffRange(allocator, io, request.context, range),
    };
}

pub fn loadStatus(allocator: std.mem.Allocator, io: std.Io, request: GitStatusRequest) git_command.Error!StatusLoadResult {
    const result = try git_command.runCaptured(allocator, io, request.context, .{
        .argv = statusArgvForOrigin(request.origin),
        .stdout_limit = .limited(max_status_bytes),
        .stderr_limit = .limited(256 * 1024),
    });
    return statusResultFromGitCommand(allocator, result, "git status");
}

pub fn loadRepositoryManifest(allocator: std.mem.Allocator, io: std.Io, request: RepositoryManifestRequest) git_command.Error!RepositoryManifestLoadResult {
    const result = try git_command.runCaptured(allocator, io, request.context, .{
        .argv = repositoryManifestArgv(),
        .stdout_limit = .limited(max_repository_manifest_bytes),
        .stderr_limit = .limited(256 * 1024),
    });
    return repositoryManifestResultFromGitCommand(allocator, result);
}

pub fn loadRepositoryFileStatus(allocator: std.mem.Allocator, io: std.Io, request: RepositoryFileStatusRequest) git_command.Error!RepositoryFileStatusLoadResult {
    const result = try git_command.runCaptured(allocator, io, request.context, .{
        .argv = repositoryFileStatusArgv(),
        .stdout_limit = .limited(max_status_bytes),
        .stderr_limit = .limited(256 * 1024),
    });
    return repositoryFileStatusResultFromGitCommand(allocator, result);
}

pub fn loadTrackedNumstat(allocator: std.mem.Allocator, io: std.Io, request: TrackedNumstatRequest) git_command.Error!TrackedNumstatResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &git_command.literal_pathspec_prefix);
    try argv.append(allocator, "diff");
    if (request.staged) try argv.append(allocator, "--cached");
    try argv.append(allocator, "--no-renames");
    try argv.append(allocator, "--numstat");
    try argv.append(allocator, "-z");
    try argv.append(allocator, "--");
    for (request.paths) |path| try argv.append(allocator, path);

    const result = try git_command.runCaptured(allocator, io, request.context, .{
        .argv = argv.items,
        .stdout_limit = .limited(tracked_numstat_stdout_limit),
        .stderr_limit = .limited(tracked_numstat_stderr_limit),
    });
    switch (result.term) {
        .exited => |code| if (code == 0) {
            allocator.free(result.stderr);
            return .{ .ok = result.stdout };
        },
        else => {},
    }
    result.deinit(allocator);
    return .unavailable;
}

pub fn loadStagedDiff(allocator: std.mem.Allocator, io: std.Io, request: StagedDiffRequest) git_command.Error!StagedDiffResult {
    const argv = [_][]const u8{ "git", "diff", "--cached", "--no-ext-diff", "--no-color" };
    const result = try git_command.runCaptured(allocator, io, request.context, .{
        .argv = &argv,
        .stdout_limit = .limited(staged_diff_capture_limit),
        .stderr_limit = .limited(64 * 1024),
    });
    switch (result.term) {
        .exited => |code| if (code == 0) {
            allocator.free(result.stderr);
            return .{ .ok = result.stdout };
        },
        else => {},
    }
    result.deinit(allocator);
    return .{ .failed_static = "staged diff failed" };
}

fn loadGitDiff(allocator: std.mem.Allocator, io: std.Io, context: git_command.DirectoryContext, argv: []const []const u8) git_command.Error!LoadResult {
    const result = try git_command.runCaptured(allocator, io, context, .{
        .argv = argv,
        .stdout_limit = .limited(max_diff_bytes),
        .stderr_limit = .limited(256 * 1024),
    });
    return loadResultFromGitCommand(allocator, result, "git diff");
}

fn loadGitDiffRange(allocator: std.mem.Allocator, io: std.Io, context: git_command.DirectoryContext, range: []const u8) git_command.Error!LoadResult {
    const argv = [_][]const u8{ "git", "diff", "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/", range };
    return loadGitDiff(allocator, io, context, &argv);
}

fn loadGitFileDiff(allocator: std.mem.Allocator, io: std.Io, context: git_command.DirectoryContext, request: FileDiffRequest) git_command.Error!LoadResult {
    return switch (request.base) {
        .unstaged => {
            const argv = git_command.literal_pathspec_prefix ++ [_][]const u8{ "diff", "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/", "--", request.path };
            return loadGitDiff(allocator, io, context, &argv);
        },
        .cached => {
            const argv = git_command.literal_pathspec_prefix ++ [_][]const u8{ "diff", "--cached", "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/", "--", request.path };
            return loadGitDiff(allocator, io, context, &argv);
        },
    };
}

fn loadResultFromGitCommand(allocator: std.mem.Allocator, result: process_runner.Result, fallback_label: []const u8) git_command.Error!LoadResult {
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

fn statusResultFromGitCommand(allocator: std.mem.Allocator, result: process_runner.Result, fallback_label: []const u8) git_command.Error!StatusLoadResult {
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

fn repositoryManifestResultFromGitCommand(allocator: std.mem.Allocator, result: process_runner.Result) git_command.Error!RepositoryManifestLoadResult {
    switch (result.term) {
        .exited => |code| if (code == 0) {
            allocator.free(result.stderr);
            return .{ .ok = result.stdout };
        },
        else => {},
    }
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    return .{ .failed_static = "Repository manifest could not be loaded" };
}

fn repositoryFileStatusResultFromGitCommand(allocator: std.mem.Allocator, result: process_runner.Result) RepositoryFileStatusLoadResult {
    switch (result.term) {
        .exited => |code| if (code == 0) {
            allocator.free(result.stderr);
            return .{ .ok = result.stdout };
        },
        else => {},
    }
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    return .{ .failed_static = "Repository file status could not be loaded" };
}

fn statusArgvForOrigin(origin: ReadOrigin) []const []const u8 {
    return switch (origin) {
        .foreground => &foreground_status_argv,
        .background => &background_status_argv,
    };
}

fn repositoryManifestArgv() []const []const u8 {
    return &repository_manifest_argv;
}

fn repositoryFileStatusArgv() []const []const u8 {
    return &repository_file_status_argv;
}

fn testingLocalGitEnvironment(allocator: std.mem.Allocator) !git_command.LocalGitEnvironment {
    var parent = try std.testing.environ.createMap(allocator);
    defer parent.deinit();
    return git_command.LocalGitEnvironment.initFromParent(allocator, &parent);
}

fn loadRepositoryFileStatusForTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
) !RepositoryFileStatusLoadResult {
    var environment = try testingLocalGitEnvironment(allocator);
    defer environment.deinit();
    return loadRepositoryFileStatus(allocator, io, .{
        .context = .{ .cwd = cwd, .environment = &environment },
    });
}

fn loadRepositoryManifestForTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
) !RepositoryManifestLoadResult {
    var environment = try testingLocalGitEnvironment(allocator);
    defer environment.deinit();
    return loadRepositoryManifest(allocator, io, .{
        .context = .{ .cwd = cwd, .environment = &environment },
    });
}

fn runTestGit(io: std.Io, argv: []const []const u8, cwd: std.Io.Dir) !void {
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.GitCommandFailed;
}

fn runTestGitFailure(io: std.Io, argv: []const []const u8, cwd: std.Io.Dir) !void {
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    switch (result.term) {
        .exited => |code| if (code != 0) return,
        else => {},
    }
    return error.ExpectedGitCommandFailure;
}

fn gitOutputAlloc(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    switch (result.term) {
        .exited => |code| if (code == 0) {
            std.testing.allocator.free(result.stderr);
            return result.stdout;
        },
        else => {},
    }
    std.testing.allocator.free(result.stdout);
    std.testing.allocator.free(result.stderr);
    return error.GitCommandFailed;
}

fn trimLineEnd(text: []const u8) []const u8 {
    return std.mem.trimEnd(u8, text, "\r\n");
}

fn containsNulPath(bytes: []const u8, expected: []const u8) bool {
    var start: usize = 0;
    while (start < bytes.len) {
        const end = std.mem.indexOfScalarPos(u8, bytes, start, 0) orelse return false;
        if (std.mem.eql(u8, bytes[start..end], expected)) return true;
        start = end + 1;
    }
    return false;
}

test "repository manifest argv is read-only NUL-delimited and deduplicated" {
    const argv = repositoryManifestArgv();
    try std.testing.expectEqualStrings("git", argv[0]);
    try std.testing.expectEqualStrings("--no-optional-locks", argv[1]);
    try std.testing.expectEqualStrings("ls-files", argv[2]);
    try std.testing.expectEqualStrings("-z", argv[3]);
    try std.testing.expectEqualStrings("--deduplicate", argv[7]);
}

test "repository file status argv is descriptor-safe porcelain v1" {
    const argv = repositoryFileStatusArgv();
    try std.testing.expectEqualSlices([]const u8, &repository_file_status_argv, argv);
    try std.testing.expectEqualStrings("git", argv[0]);
    try std.testing.expectEqualStrings("--no-optional-locks", argv[1]);
    try std.testing.expectEqualStrings("status", argv[2]);
    try std.testing.expectEqualStrings("--porcelain=v1", argv[3]);
    try std.testing.expectEqualStrings("-z", argv[4]);
    try std.testing.expectEqualStrings("-uall", argv[5]);
}

test "repository file status reports real intent-to-add as current added path" {
    const repository_change_index = @import("../repository/change_index.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try work.writeFile(io, .{ .sub_path = "intent.zig", .data = "const value = 1;\n" });
    try runTestGit(io, &.{ "git", "add", "-N", "intent.zig" }, work);

    var result = try loadRepositoryFileStatusForTest(std.testing.allocator, io, work);
    const bytes = switch (result) {
        .ok => |owned| blk: {
            result = .{ .failed_static = "consumed" };
            break :blk owned;
        },
        .failed_static => return error.UnexpectedRepositoryFileStatusFailure,
    };
    var index = try repository_change_index.parseOwned(std.testing.allocator, bytes);
    defer index.deinit(std.testing.allocator);
    try std.testing.expectEqual(repository_change_index.Kind.added, index.kindForPath("intent.zig").?);
}

test "repository file status descriptor cwd survives path replacement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "work", .default_dir);
    var committed = try tmp.dir.openDir(io, "work", .{});
    defer committed.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, committed);
    try committed.writeFile(io, .{ .sub_path = "committed.txt", .data = "old\n" });

    try tmp.dir.rename("work", tmp.dir, "old-work", io);
    try tmp.dir.createDir(io, "work", .default_dir);
    var replacement = try tmp.dir.openDir(io, "work", .{});
    defer replacement.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, replacement);
    try replacement.writeFile(io, .{ .sub_path = "replacement.txt", .data = "new\n" });

    const result = try loadRepositoryFileStatusForTest(std.testing.allocator, io, committed);
    defer result.deinit(std.testing.allocator);
    const bytes = switch (result) {
        .ok => |owned| owned,
        .failed_static => return error.UnexpectedRepositoryFileStatusFailure,
    };
    try std.testing.expect(std.mem.indexOf(u8, bytes, "committed.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "replacement.txt") == null);
}

test "repository file status with rename detection disabled keeps only current path" {
    const repository_change_index = @import("../repository/change_index.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try work.writeFile(io, .{ .sub_path = "old.zig", .data = "const value = 1;\n" });
    try runTestGit(io, &.{ "git", "add", "old.zig" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" }, work);
    try runTestGit(io, &.{ "git", "config", "status.renames", "false" }, work);
    try work.rename("old.zig", work, "new.zig", io);

    var result = try loadRepositoryFileStatusForTest(std.testing.allocator, io, work);
    const bytes = switch (result) {
        .ok => |owned| blk: {
            result = .{ .failed_static = "consumed" };
            break :blk owned;
        },
        .failed_static => return error.UnexpectedRepositoryFileStatusFailure,
    };
    var index = try repository_change_index.parseOwned(std.testing.allocator, bytes);
    defer index.deinit(std.testing.allocator);
    try std.testing.expect(index.kindForPath("old.zig") == null);
    try std.testing.expectEqual(repository_change_index.Kind.added, index.kindForPath("new.zig").?);
}

test "repository file status classifies a dirty submodule gitlink" {
    const repository_change_index = @import("../repository/change_index.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    try tmp.dir.createDir(io, "child", .default_dir);
    var child = try tmp.dir.openDir(io, "child", .{});
    defer child.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, child);
    try child.writeFile(io, .{ .sub_path = "source.zig", .data = "const value = 1;\n" });
    try runTestGit(io, &.{ "git", "add", "source.zig" }, child);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" }, child);
    const child_path = try tmp.dir.realPathFileAlloc(io, "child", allocator);
    defer allocator.free(child_path);

    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try runTestGit(io, &.{ "git", "-c", "protocol.file.allow=always", "submodule", "add", child_path, "vendor/sub" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "submodule" }, work);
    var checked_out_child = try work.openDir(io, "vendor/sub", .{});
    defer checked_out_child.close(io);
    try checked_out_child.writeFile(io, .{ .sub_path = "source.zig", .data = "const value = 2;\n" });

    var result = try loadRepositoryFileStatusForTest(allocator, io, work);
    const bytes = switch (result) {
        .ok => |owned| blk: {
            result = .{ .failed_static = "consumed" };
            break :blk owned;
        },
        .failed_static => return error.UnexpectedRepositoryFileStatusFailure,
    };
    var index = try repository_change_index.parseOwned(allocator, bytes);
    defer index.deinit(allocator);
    try std.testing.expectEqual(repository_change_index.Kind.modified, index.kindForPath("vendor/sub").?);
}

test "repository file status failure does not expose diagnostics" {
    const secret = "/private/worktree/token-123";
    const raw = process_runner.Result{
        .term = .{ .exited = 128 },
        .stdout = try std.testing.allocator.alloc(u8, 0),
        .stderr = try std.fmt.allocPrint(std.testing.allocator, "fatal at {s}\n", .{secret}),
    };
    const result = repositoryFileStatusResultFromGitCommand(std.testing.allocator, raw);
    defer result.deinit(std.testing.allocator);
    switch (result) {
        .failed_static => |message| {
            try std.testing.expectEqualStrings("Repository file status could not be loaded", message);
            try std.testing.expect(std.mem.indexOf(u8, message, secret) == null);
        },
        .ok => return error.ExpectedRepositoryFileStatusFailure,
    }
}

test "repository manifest backend deduplicates a real three-stage conflict" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);

    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try work.writeFile(io, .{ .sub_path = "conflict.txt", .data = "base\n" });
    try runTestGit(io, &.{ "git", "add", "conflict.txt" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" }, work);
    try runTestGit(io, &.{ "git", "checkout", "-b", "side" }, work);
    try work.writeFile(io, .{ .sub_path = "conflict.txt", .data = "side\n" });
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-am", "side" }, work);
    try runTestGit(io, &.{ "git", "checkout", "main" }, work);
    try work.writeFile(io, .{ .sub_path = "conflict.txt", .data = "main\n" });
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-am", "main" }, work);
    try runTestGitFailure(io, &.{ "git", "merge", "side" }, work);

    const result = try loadRepositoryManifestForTest(std.testing.allocator, io, work);
    defer result.deinit(std.testing.allocator);
    const bytes = switch (result) {
        .ok => |value| value,
        else => return error.UnexpectedRepositoryManifestFailure,
    };
    try std.testing.expectEqualStrings("conflict.txt\x00", bytes);
}

test "repository manifest backend accepts gitlink as one path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);

    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try work.writeFile(io, .{ .sub_path = "README.md", .data = "base\n" });
    try runTestGit(io, &.{ "git", "add", "README.md" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" }, work);
    const oid_output = try gitOutputAlloc(io, work, &.{ "git", "rev-parse", "HEAD" });
    defer std.testing.allocator.free(oid_output);
    const cache_info = try std.fmt.allocPrint(std.testing.allocator, "160000,{s},vendor/sub", .{trimLineEnd(oid_output)});
    defer std.testing.allocator.free(cache_info);
    try runTestGit(io, &.{ "git", "update-index", "--add", "--cacheinfo", cache_info }, work);

    const result = try loadRepositoryManifestForTest(std.testing.allocator, io, work);
    defer result.deinit(std.testing.allocator);
    const bytes = switch (result) {
        .ok => |value| value,
        else => return error.UnexpectedRepositoryManifestFailure,
    };
    try std.testing.expect(std.mem.indexOf(u8, bytes, "vendor/sub\x00") != null);
}

test "repository manifest backend includes tracked and non-ignored untracked paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);

    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try work.writeFile(io, .{ .sub_path = "tracked.log", .data = "tracked\n" });
    try runTestGit(io, &.{ "git", "add", "tracked.log" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" }, work);
    try work.writeFile(io, .{ .sub_path = ".gitignore", .data = "*.log\n" });
    try work.writeFile(io, .{ .sub_path = "ignored.log", .data = "ignored\n" });
    try work.writeFile(io, .{ .sub_path = "visible.txt", .data = "visible\n" });

    const result = try loadRepositoryManifestForTest(std.testing.allocator, io, work);
    defer result.deinit(std.testing.allocator);
    const bytes = switch (result) {
        .ok => |value| value,
        else => return error.UnexpectedRepositoryManifestFailure,
    };
    try std.testing.expect(containsNulPath(bytes, "tracked.log"));
    try std.testing.expect(containsNulPath(bytes, ".gitignore"));
    try std.testing.expect(containsNulPath(bytes, "visible.txt"));
    try std.testing.expect(!containsNulPath(bytes, "ignored.log"));
}

test "repository manifest descriptor cwd stays on committed directory after path replacement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "work", .default_dir);
    var committed = try tmp.dir.openDir(io, "work", .{});
    defer committed.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, committed);
    try committed.writeFile(io, .{ .sub_path = "committed.txt", .data = "old\n" });

    try tmp.dir.rename("work", tmp.dir, "old-work", io);
    try tmp.dir.createDir(io, "work", .default_dir);
    var replacement = try tmp.dir.openDir(io, "work", .{});
    defer replacement.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, replacement);
    try replacement.writeFile(io, .{ .sub_path = "replacement.txt", .data = "new\n" });

    const result = try loadRepositoryManifestForTest(std.testing.allocator, io, committed);
    defer result.deinit(std.testing.allocator);
    const bytes = switch (result) {
        .ok => |value| value,
        else => return error.UnexpectedRepositoryManifestFailure,
    };
    try std.testing.expect(containsNulPath(bytes, "committed.txt"));
    try std.testing.expect(!containsNulPath(bytes, "replacement.txt"));
}

test "repository manifest unsupported option is a typed failure" {
    const secret = "/private/worktree/token-123";
    const result = process_runner.Result{
        .term = .{ .exited = 129 },
        .stdout = try std.testing.allocator.alloc(u8, 0),
        .stderr = try std.fmt.allocPrint(std.testing.allocator, "error at {s}: unknown option `deduplicate`\n", .{secret}),
    };
    const mapped = try repositoryManifestResultFromGitCommand(std.testing.allocator, result);
    defer mapped.deinit(std.testing.allocator);
    switch (mapped) {
        .failed_static => |message| {
            try std.testing.expectEqualStrings("Repository manifest could not be loaded", message);
            try std.testing.expect(std.mem.indexOf(u8, message, secret) == null);
            try std.testing.expect(std.mem.indexOf(u8, message, "deduplicate") == null);
        },
        else => return error.ExpectedRepositoryManifestFailure,
    }
}

test "background status suppresses optional locks without changing foreground argv" {
    try std.testing.expectEqualSlices([]const u8, &foreground_status_argv, statusArgvForOrigin(.foreground));
    try std.testing.expectEqualSlices([]const u8, &background_status_argv, statusArgvForOrigin(.background));
    try std.testing.expectEqualStrings("status", statusArgvForOrigin(.foreground)[1]);
    try std.testing.expectEqualStrings("--no-optional-locks", statusArgvForOrigin(.background)[1]);
    try std.testing.expectEqualStrings("status", statusArgvForOrigin(.background)[2]);
}

test "GitDiffRequest cannot represent raw input sources" {
    var environment = try testingLocalGitEnvironment(std.testing.allocator);
    defer environment.deinit();
    const request = GitDiffRequest{
        .context = .{ .cwd = std.Io.Dir.cwd(), .environment = &environment },
        .kind = .unstaged,
    };

    try std.testing.expectEqual(std.Io.Dir.cwd().handle, request.context.cwd.handle);
    try std.testing.expect(request.kind == .unstaged);
}

fn runTestGitWithDates(
    io: std.Io,
    cwd: std.Io.Dir,
    message: []const u8,
    author_date: []const u8,
    committer_date: []const u8,
) !void {
    var environment = try std.testing.environ.createMap(std.testing.allocator);
    defer environment.deinit();
    try environment.put("GIT_AUTHOR_DATE", author_date);
    try environment.put("GIT_COMMITTER_DATE", committer_date);
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{
            "git",
            "-c",
            "user.name=Path History Test",
            "-c",
            "user.email=path-history@example.invalid",
            "commit",
            "-m",
            message,
        },
        .cwd = .{ .dir = cwd },
        .environ_map = &environment,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    if (!exitedWith(result.term, 0)) return error.GitCommandFailed;
}

fn loadPathHistoryForTest(cwd: std.Io.Dir, path: []const u8) !RepositoryPathHistoryOutcome {
    var environment = try testingLocalGitEnvironment(std.testing.allocator);
    defer environment.deinit();
    return loadRepositoryPathHistory(std.testing.allocator, std.testing.io, .{
        .context = .{ .cwd = cwd, .environment = &environment },
        .path = path,
    });
}

fn expectCommittedPath(cwd: std.Io.Dir, path: []const u8, expected: i64) !void {
    var outcome = try loadPathHistoryForTest(cwd, path);
    defer outcome.deinit(std.testing.allocator);
    switch (outcome) {
        .known => |known| {
            try std.testing.expect(known.head == .oid);
            switch (known.fact) {
                .committed => |timestamp| try std.testing.expectEqual(expected, timestamp),
                .uncommitted => return error.ExpectedCommittedPath,
            }
        },
        .unavailable => return error.ExpectedCommittedPath,
    }
}

fn expectUncommittedPath(cwd: std.Io.Dir, path: []const u8, expected_head: std.meta.Tag(HeadBasis)) !void {
    var outcome = try loadPathHistoryForTest(cwd, path);
    defer outcome.deinit(std.testing.allocator);
    switch (outcome) {
        .known => |known| {
            try std.testing.expectEqual(expected_head, std.meta.activeTag(known.head));
            try std.testing.expect(known.fact == .uncommitted);
        },
        .unavailable => return error.ExpectedUncommittedPath,
    }
}

fn expectUnavailablePath(cwd: std.Io.Dir, path: []const u8) !void {
    var outcome = try loadPathHistoryForTest(cwd, path);
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expect(outcome == .unavailable);
}

test "repository path history classification prioritizes current exact path state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, tmp.dir);

    const magic_path = ":(glob)literal[1].txt";
    const invalid_path = "invalid-\xff.txt";
    try tmp.dir.writeFile(io, .{ .sub_path = "tracked.txt", .data = "tracked base\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "history.txt", .data = "old history\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "cached.txt", .data = "cached base\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "rename-old.txt", .data = "rename base\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "pending-old.txt", .data = "pending rename\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "-leading.txt", .data = "leading\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = magic_path, .data = "magic\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = invalid_path, .data = "invalid\n" });
    try runTestGit(io, &.{ "git", "--literal-pathspecs", "add", "--", "tracked.txt", "history.txt", "cached.txt", "rename-old.txt", "pending-old.txt", "-leading.txt", magic_path, invalid_path }, tmp.dir);
    try runTestGitWithDates(io, tmp.dir, "base", "@946684800 +0000", "@951827640 +0000");

    try runTestGit(io, &.{ "git", "rm", "--", "history.txt" }, tmp.dir);
    try runTestGit(io, &.{ "git", "mv", "--", "rename-old.txt", "rename-new.txt" }, tmp.dir);
    try runTestGitWithDates(io, tmp.dir, "delete and rename", "@951827650 +0000", "@951827700 +0000");
    try runTestGit(io, &.{ "git", "mv", "--", "pending-old.txt", "pending-new.txt" }, tmp.dir);

    // A filesystem/content change does not alter the Git-history fact.
    try tmp.dir.writeFile(io, .{ .sub_path = "tracked.txt", .data = "tracked modified later\n" });
    try expectCommittedPath(tmp.dir, "tracked.txt", 951_827_640);
    try expectCommittedPath(tmp.dir, "rename-new.txt", 951_827_700);
    try expectCommittedPath(tmp.dir, "-leading.txt", 951_827_640);
    try expectCommittedPath(tmp.dir, magic_path, 951_827_640);
    try expectCommittedPath(tmp.dir, invalid_path, 951_827_640);

    // Every case below has old or potential history, but current state wins.
    try tmp.dir.writeFile(io, .{ .sub_path = "history.txt", .data = "recreated\n" });
    try runTestGit(io, &.{ "git", "rm", "--cached", "--", "cached.txt" }, tmp.dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "untracked.txt", .data = "new\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "intent.txt", .data = "intent\n" });
    try runTestGit(io, &.{ "git", "add", "-N", "--", "intent.txt" }, tmp.dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "index-only.txt", .data = "index\n" });
    try runTestGit(io, &.{ "git", "add", "--", "index-only.txt" }, tmp.dir);
    try tmp.dir.deleteFile(io, "index-only.txt");

    try expectUncommittedPath(tmp.dir, "history.txt", .oid);
    try expectUncommittedPath(tmp.dir, "cached.txt", .oid);
    try expectUncommittedPath(tmp.dir, "untracked.txt", .oid);
    try expectUncommittedPath(tmp.dir, "intent.txt", .oid);
    try expectUncommittedPath(tmp.dir, "index-only.txt", .oid);
    try expectUncommittedPath(tmp.dir, "pending-new.txt", .oid);
}

test "repository path history handles unborn ignored and corrupt HEAD without fabricated facts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, tmp.dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "new.txt", .data = "new\n" });
    try expectUncommittedPath(tmp.dir, "new.txt", .unborn);

    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "ignored.txt\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ignored.txt", .data = "ignored\n" });
    try expectUnavailablePath(tmp.dir, "ignored.txt");

    try tmp.dir.writeFile(io, .{ .sub_path = ".git/HEAD", .data = "not a valid HEAD\n" });
    try expectUnavailablePath(tmp.dir, "new.txt");
}

test "repository path history parsers reject ambiguous state and malformed timestamps" {
    try std.testing.expectEqual(CurrentPathClass.history, classifyCurrentPath(true, true, false));
    try std.testing.expectEqual(CurrentPathClass.uncommitted, classifyCurrentPath(false, true, false));
    try std.testing.expectEqual(CurrentPathClass.uncommitted, classifyCurrentPath(false, false, true));
    try std.testing.expectEqual(CurrentPathClass.uncommitted, classifyCurrentPath(true, false, true));
    try std.testing.expectEqual(CurrentPathClass.unavailable, classifyCurrentPath(true, false, false));
    try std.testing.expectEqual(CurrentPathClass.unavailable, classifyCurrentPath(false, false, false));
    try std.testing.expectEqual(CurrentPathClass.unavailable, classifyCurrentPath(true, true, true));

    const oid = "0123456789abcdef0123456789abcdef01234567";
    try std.testing.expectEqual(@as(i64, 42), parseHistoryRecord(oid ++ "\x0042").?.timestamp);
    try std.testing.expect(parseHistoryRecord(oid ++ "\x00-1") == null);
    try std.testing.expect(parseHistoryRecord(oid ++ "\x00253402300800") == null);
    try std.testing.expect(parseHistoryRecord(oid ++ "\x009223372036854775808") == null);
    try std.testing.expect(parseHistoryRecord(oid ++ "\x0042\x00extra") == null);
    try std.testing.expect(parseHistoryRecord("bad\x0042") == null);

    const fields = @typeInfo(RepositoryPathHistoryKnown).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expect(fields[0].type == HeadBasis);
}

test "repository path history accepts recent shallow commit and rejects shallow boundary" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "source", .default_dir);
    var source = try tmp.dir.openDir(io, "source", .{});
    defer source.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, source);
    try source.writeFile(io, .{ .sub_path = "tracked.txt", .data = "one\n" });
    try runTestGit(io, &.{ "git", "add", "tracked.txt" }, source);
    try runTestGitWithDates(io, source, "root", "@951827500 +0000", "@951827500 +0000");
    try source.writeFile(io, .{ .sub_path = "other.txt", .data = "two\n" });
    try runTestGit(io, &.{ "git", "add", "other.txt" }, source);
    try runTestGitWithDates(io, source, "parent", "@951827600 +0000", "@951827600 +0000");
    try source.writeFile(io, .{ .sub_path = "tracked.txt", .data = "three\n" });
    try runTestGit(io, &.{ "git", "add", "tracked.txt" }, source);
    try runTestGitWithDates(io, source, "latest", "@951827700 +0000", "@951827700 +0000");

    const source_path = try tmp.dir.realPathFileAlloc(io, "source", allocator);
    defer allocator.free(source_path);
    const source_url = try std.fmt.allocPrint(allocator, "file://{s}", .{source_path});
    defer allocator.free(source_url);
    try runTestGit(io, &.{ "git", "clone", "--depth=2", source_url, "recent" }, tmp.dir);
    try runTestGit(io, &.{ "git", "clone", "--depth=1", source_url, "boundary" }, tmp.dir);
    var recent = try tmp.dir.openDir(io, "recent", .{});
    defer recent.close(io);
    var boundary = try tmp.dir.openDir(io, "boundary", .{});
    defer boundary.close(io);

    try expectCommittedPath(recent, "tracked.txt", 951_827_700);
    try expectUnavailablePath(boundary, "tracked.txt");
}

const HeadMoveTestHook = struct {
    cwd: std.Io.Dir,
    target_oid: []const u8,
    failed: bool = false,

    fn run(raw: *anyopaque) void {
        const self: *HeadMoveTestHook = @ptrCast(@alignCast(raw));
        runTestGit(std.testing.io, &.{ "git", "update-ref", "HEAD", self.target_oid }, self.cwd) catch {
            self.failed = true;
        };
    }
};

test "repository path history rejects HEAD movement across the query" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, tmp.dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "tracked.txt", .data = "base\n" });
    try runTestGit(io, &.{ "git", "add", "tracked.txt" }, tmp.dir);
    try runTestGitWithDates(io, tmp.dir, "base", "@951827600 +0000", "@951827600 +0000");
    const old_output = try gitOutputAlloc(io, tmp.dir, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(old_output);
    const old_oid = trimLineEnd(old_output);
    try tmp.dir.writeFile(io, .{ .sub_path = "successor.txt", .data = "successor\n" });
    try runTestGit(io, &.{ "git", "add", "successor.txt" }, tmp.dir);
    try runTestGitWithDates(io, tmp.dir, "successor", "@951827700 +0000", "@951827700 +0000");
    const new_output = try gitOutputAlloc(io, tmp.dir, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(new_output);
    const new_oid = trimLineEnd(new_output);
    try runTestGit(io, &.{ "git", "reset", "--hard", old_oid }, tmp.dir);

    var environment = try testingLocalGitEnvironment(allocator);
    defer environment.deinit();
    var hook = HeadMoveTestHook{ .cwd = tmp.dir, .target_oid = new_oid };
    var outcome = try loadRepositoryPathHistoryWithHook(
        allocator,
        io,
        .{
            .context = .{ .cwd = tmp.dir, .environment = &environment },
            .path = "tracked.txt",
        },
        .{ .context = &hook, .run = HeadMoveTestHook.run },
    );
    defer outcome.deinit(allocator);
    try std.testing.expect(!hook.failed);
    try std.testing.expect(outcome == .unavailable);
}
