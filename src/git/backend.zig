const std = @import("std");
const git_ref = @import("ref.zig");
const git_branch_status = @import("branch_status.zig");
const git_push = @import("push.zig");
const process_runner = @import("../process/runner.zig");
const repository_change_map = @import("../repository/change_map.zig");

pub const max_diff_bytes = 16 * 1024 * 1024;
pub const max_status_bytes = 8 * 1024 * 1024;
pub const max_repository_manifest_bytes = 16 * 1024 * 1024;
pub const max_branch_list_bytes = 4 * 1024 * 1024;

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

pub const RepositoryManifestLoadResult = union(enum) {
    /// Owned raw NUL-delimited `git ls-files` output.
    ok: []u8,
    failed: []u8,
    failed_static: []const u8,

    pub fn deinit(self: RepositoryManifestLoadResult, allocator: std.mem.Allocator) void {
        switch (self) {
            .ok => |bytes| allocator.free(bytes),
            .failed => |message| allocator.free(message),
            .failed_static => {},
        }
    }
};

/// Optional Repository-tree status snapshot. This is deliberately separate
/// from Review's string-root status API: Repository tasks remain committed to
/// the already-open root descriptor for both manifest and status reads.
pub const RepositoryFileStatusLoadResult = union(enum) {
    /// Owned porcelain-v1 `-z` bytes.
    ok: []u8,
    failed_static: []const u8,

    pub fn deinit(self: RepositoryFileStatusLoadResult, allocator: std.mem.Allocator) void {
        switch (self) {
            .ok => |bytes| allocator.free(bytes),
            .failed_static => {},
        }
    }
};

/// Bounded raw-object comparison for one Repository source gutter.
pub const RepositoryFileChangeLoadResult = union(enum) {
    /// The pinned HEAD tree has no blob for this path, or HEAD is unborn.
    all_added,
    /// Owned zero-context no-index patch from the pinned blob to `source_bytes`.
    patch: []u8,
    /// The pinned blob and current logical source are identical.
    unchanged,
    /// Static failure only: raw Git/path/source/temp details are never UI text.
    failed_static: []const u8,

    pub fn deinit(self: RepositoryFileChangeLoadResult, allocator: std.mem.Allocator) void {
        switch (self) {
            .patch => |bytes| allocator.free(bytes),
            .all_added, .unchanged, .failed_static => {},
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

pub const BranchKind = git_ref.BranchKind;

pub const BranchListItem = struct {
    /// Full Git ref used as operation authority.
    full_ref: []u8,
    /// Short name used for display. This can collide across ref namespaces.
    name: []u8,
    kind: BranchKind,
    oid: []u8,
    current: bool = false,
};

pub const BranchList = struct {
    current: ?[]u8 = null,
    branches: []BranchListItem = &.{},

    pub fn deinit(self: *BranchList, allocator: std.mem.Allocator) void {
        if (self.current) |current| allocator.free(current);
        for (self.branches) |item| {
            allocator.free(item.full_ref);
            allocator.free(item.name);
            allocator.free(item.oid);
        }
        allocator.free(self.branches);
        self.* = .{};
    }
};

pub const BranchListLoadResult = union(enum) {
    ok: BranchList,
    failed: []u8,
    failed_static: []const u8,

    pub fn deinit(self: BranchListLoadResult, allocator: std.mem.Allocator) void {
        switch (self) {
            .ok => |list| {
                var owned = list;
                owned.deinit(allocator);
            },
            .failed => |message| allocator.free(message),
            .failed_static => {},
        }
    }
};

pub const OperationResult = union(enum) {
    ok,
    /// Non-owned success message for operations that completed without a
    /// content-changing action, for example fetch-first pull finding the branch
    /// already up to date.
    ok_static: []const u8,
    /// Allocated error message from Git. Caller owns and must call `deinit`.
    failed: []u8,
    /// Non-owned fallback error message, used when allocation itself fails.
    failed_static: []const u8,

    pub fn deinit(self: OperationResult, allocator: std.mem.Allocator) void {
        switch (self) {
            .ok, .ok_static, .failed_static => {},
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
pub const ReadOrigin = enum {
    foreground,
    background,
};

pub const GitStatusRequest = struct {
    repo_root: []const u8,
    origin: ReadOrigin = .foreground,
};

pub const RepositoryManifestRequest = struct {
    /// Borrowed descriptor cwd. The caller keeps it alive through command wait.
    cwd: std.Io.Dir,
};

pub const RepositoryFileStatusRequest = struct {
    /// Borrowed descriptor cwd. The caller keeps it alive through command wait.
    cwd: std.Io.Dir,
};

pub const RepositoryFileChangeRequest = struct {
    /// Borrowed descriptor cwd kept alive by the synchronous task call.
    cwd: std.Io.Dir,
    /// Borrowed byte-exact manifest path; every Git pathspec command is literal.
    path: []const u8,
    /// Borrowed immutable descriptor-safe task snapshot, never page memory.
    source_bytes: []const u8,
    /// Borrowed absolute user-private temp base selected by the App shell.
    temp_base_path: []const u8 = "/tmp",
};

/// Concrete repository authority accepted by branch-status reads.
///
/// Unlike `std.process.Child.Cwd`, this deliberately has no ambient `.inherit`
/// case. The caller must name a path or keep a directory descriptor alive for
/// the complete synchronous backend call.
pub const BranchStatusCwd = union(enum) {
    path: []const u8,
    dir: std.Io.Dir,
};

/// Request for branch/upstream/ahead-behind status in a concrete repository.
pub const BranchStatusRequest = struct {
    /// Borrowed authority kept valid for the synchronous backend call. Every
    /// command contributing to one status snapshot receives this exact cwd.
    cwd: BranchStatusCwd,
    /// Borrowed parent environment used only as input to the branch-status
    /// sanitizer. Null means an empty controlled environment, never inheritance.
    parent_env: ?*const std.process.Environ.Map,
};

pub const BranchListScope = enum {
    local,
    local_and_remote,
};

pub const BranchListEnvironment = union(enum) {
    /// Legacy shell branch switching keeps the process environment unchanged.
    inherited,
    /// Repository-sensitive callers clone this parent and remove every GIT_*
    /// override before invoking Git. Null means a deliberately empty parent.
    controlled: ?*const std.process.Environ.Map,
};

pub const BranchListRequest = struct {
    /// Borrowed physical repository authority kept alive for this complete
    /// synchronous snapshot. Path authority remains available for the legacy
    /// shell branch-switch caller; Compare supplies a descriptor.
    cwd: BranchStatusCwd,
    environment: BranchListEnvironment,
    scope: BranchListScope,
};

/// Borrowed user intent for one committed branch comparison.
///
/// `full_ref` is the only Git authority. The other fields cross the backend
/// boundary solely so the accepted snapshot can retain the exact picker text
/// and kind without re-deriving them from an ambiguous short name.
pub const CompareTargetSpec = struct {
    full_ref: []const u8,
    display_name: []const u8,
    kind: BranchKind,
};

pub const CompareTarget = struct {
    full_ref: []u8,
    display_name: []u8,
    kind: BranchKind,

    pub fn deinit(self: *CompareTarget, allocator: std.mem.Allocator) void {
        allocator.free(self.full_ref);
        allocator.free(self.display_name);
        self.* = undefined;
    }
};

pub const CompareBasisFailure = enum {
    missing_base_ref,
    no_merge_base,
    head_unresolved,
};

/// Raw, independently owned output of the pinned Compare Git read.
///
/// Oids and ahead text remain raw here. The app task validates their syntax
/// before constructing its page-independent `diff_basis` values.
pub const CompareSnapshot = struct {
    target: CompareTarget,
    base_oid: []u8,
    head_oid: []u8,
    head_name: ?[]u8,
    merge_base_oid: []u8,
    ahead_count: []u8,
    diff: []u8,

    pub fn deinit(self: *CompareSnapshot, allocator: std.mem.Allocator) void {
        self.target.deinit(allocator);
        allocator.free(self.base_oid);
        allocator.free(self.head_oid);
        if (self.head_name) |name| allocator.free(name);
        allocator.free(self.merge_base_oid);
        allocator.free(self.ahead_count);
        allocator.free(self.diff);
        self.* = undefined;
    }
};

pub const CompareSnapshotResult = union(enum) {
    snapshot: CompareSnapshot,
    basis_failed: struct {
        kind: CompareBasisFailure,
        attempted: CompareTarget,
    },
    failed: []u8,
    failed_static: []const u8,

    pub fn deinit(self: *CompareSnapshotResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .snapshot => |*snapshot| snapshot.deinit(allocator),
            .basis_failed => |*failure| failure.attempted.deinit(allocator),
            .failed => |message| allocator.free(message),
            .failed_static => {},
        }
        self.* = .{ .failed_static = "" };
    }
};

pub const CompareSnapshotRequest = struct {
    /// Borrowed descriptor authority retained by the synchronous caller.
    cwd: std.Io.Dir,
    /// Null means a deliberately empty environment, never ambient inheritance.
    parent_env: ?*const std.process.Environ.Map,
    /// Null asks the backend to run the reviewed origin/HEAD -> main -> master
    /// fallback. A non-null value is resolved exactly once by full ref.
    target: ?CompareTargetSpec,
};

pub const OperationKind = union(enum) {
    stage_file: []const u8,
    unstage_file: []const u8,
    stage_all,
    unstage_all,
    discard_file: []const u8,
    stage_patch: StagePatchRequest,
    unstage_patch: StagePatchRequest,
    commit: CommitRequest,
    amend: CommitRequest,
    push: PushRequest,
    pull_refresh_ff_only: PullRequest,
    fetch: FetchRequest,
    switch_branch: SwitchBranchRequest,
};

pub const StagePatchRequest = struct {
    patch: []const u8,
};

pub const CommitRequest = struct {
    subject: []const u8,
    body: ?[]const u8 = null,
};

pub const PushRequest = struct {
    mode: git_push.Mode = .upstream,
    branch: []const u8,
    remote: []const u8,
    remote_branch: []const u8,
    /// Commit snapshot used by the pre-push safety check. The push argv uses
    /// the branch refspec; this OID only proves the branch has not moved.
    oid: []const u8,
    credentials: ?PushCredentials = null,
};

pub const PullRequest = struct {
    branch: []const u8,
    remote: []const u8,
    remote_branch: []const u8,
    /// Commit snapshot used by the pre-pull safety check. Pull mutates the
    /// current branch, so the backend must fail closed if the confirmation was
    /// approved for an older HEAD.
    oid: []const u8,
};

pub const FetchRequest = struct {
    remote: []const u8,
};

pub const SwitchBranchRequest = struct {
    expected_branch: []const u8,
    expected_oid: []const u8,
    target_branch: []const u8,
    target_oid: []const u8,
};

pub const PushCredentials = struct {
    username: []const u8,
    password: []const u8,
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

pub const LocalCommandBackend = struct {
    const git_diff_unstaged = [_][]const u8{ "git", "diff", "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/" };
    const git_diff_cached = [_][]const u8{ "git", "diff", "--cached", "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/" };

    pub fn loadDiff(allocator: std.mem.Allocator, io: std.Io, request: GitDiffRequest) LoadError!LoadResult {
        return switch (request.kind) {
            .unstaged => loadGitDiff(allocator, io, repoRoot(request), &git_diff_unstaged),
            .cached => loadGitDiff(allocator, io, repoRoot(request), &git_diff_cached),
            .file => |file| loadGitFileDiff(allocator, io, repoRoot(request), file),
            .range => |range| loadGitDiffRange(allocator, io, repoRoot(request), range),
            .no_index => |paths| loadNoIndexDiff(allocator, io, paths),
        };
    }

    pub fn loadStatus(allocator: std.mem.Allocator, io: std.Io, request: GitStatusRequest) LoadError!StatusLoadResult {
        return loadGitStatus(allocator, io, request);
    }

    pub fn loadRepositoryManifest(allocator: std.mem.Allocator, io: std.Io, request: RepositoryManifestRequest) LoadError!RepositoryManifestLoadResult {
        return loadGitRepositoryManifest(allocator, io, request.cwd);
    }

    pub fn loadRepositoryFileStatus(allocator: std.mem.Allocator, io: std.Io, request: RepositoryFileStatusRequest) LoadError!RepositoryFileStatusLoadResult {
        return loadGitRepositoryFileStatus(allocator, io, request.cwd);
    }

    pub fn loadRepositoryFileChange(allocator: std.mem.Allocator, io: std.Io, request: RepositoryFileChangeRequest) LoadError!RepositoryFileChangeLoadResult {
        return loadGitRepositoryFileChange(allocator, io, request);
    }

    pub fn loadBranchStatus(allocator: std.mem.Allocator, io: std.Io, request: BranchStatusRequest) LoadError!BranchStatusLoadResult {
        return loadGitBranchStatus(allocator, io, request);
    }

    pub fn loadBranchList(allocator: std.mem.Allocator, io: std.Io, request: BranchListRequest) LoadError!BranchListLoadResult {
        return loadGitBranchList(allocator, io, request);
    }

    pub fn loadCompareSnapshot(allocator: std.mem.Allocator, io: std.Io, request: CompareSnapshotRequest) LoadError!CompareSnapshotResult {
        return loadGitCompareSnapshot(allocator, io, request);
    }

    pub fn runOperation(allocator: std.mem.Allocator, io: std.Io, request: OperationRequest) LoadError!OperationResult {
        return switch (request.kind) {
            .stage_file => |path| runGitAdd(allocator, io, request.repo_root, path),
            .unstage_file => |path| runGitUnstage(allocator, io, request.repo_root, path),
            .stage_all => runGitAddAll(allocator, io, request.repo_root),
            .unstage_all => runGitUnstageAll(allocator, io, request.repo_root),
            .discard_file => |path| runGitDiscard(allocator, io, request.repo_root, path),
            .stage_patch => |patch| runGitApplyCached(allocator, io, request.repo_root, patch.patch),
            .unstage_patch => |patch| runGitApplyCachedReverse(allocator, io, request.repo_root, patch.patch),
            .commit => |commit| runGitCommit(allocator, io, request.repo_root, commit),
            .amend => |commit| runGitAmend(allocator, io, request.repo_root, commit),
            .push => |push| runGitPush(allocator, io, request.repo_root, request.env_map, push),
            .pull_refresh_ff_only => |pull| runGitPullRefresh(allocator, io, request.repo_root, request.env_map, pull),
            .fetch => |fetch| runGitFetch(allocator, io, request.repo_root, request.env_map, fetch),
            .switch_branch => |switch_branch| runGitSwitchBranch(allocator, io, request.repo_root, switch_branch),
        };
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

fn repositoryManifestResultFromGitCommand(allocator: std.mem.Allocator, result: process_runner.Result) LoadError!RepositoryManifestLoadResult {
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
    // Status is an optional tree decoration. Raw Git diagnostics (including
    // repository paths) never cross this backend boundary into page status.
    return .{ .failed_static = "Repository file status could not be loaded" };
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

fn operationResultFromGitStdinCommand(
    allocator: std.mem.Allocator,
    detailed: process_runner.DetailedResult,
    fallback_label: []const u8,
) LoadError!OperationResult {
    return switch (detailed) {
        .ok => |result| operationResultFromGitCommand(allocator, result, fallback_label),
        .failed => |failure_value| {
            var failure = failure_value;
            defer failure.deinit(allocator);

            const error_name = failure.errorName();
            return switch (failure) {
                .stdin => |*stdin_failure| {
                    if (stdin_failure.result.stderr.len > 0) {
                        const result = stdin_failure.takeResult();
                        allocator.free(result.stdout);
                        return .{ .failed = result.stderr };
                    }

                    const message = std.fmt.allocPrint(
                        allocator,
                        "{s} failed during stdin ({s}): {any}",
                        .{ fallback_label, error_name, stdin_failure.result.term },
                    ) catch return error.OutOfMemory;
                    const result = stdin_failure.takeResult();
                    result.deinit(allocator);
                    return .{ .failed = message };
                },
                else => runnerErrorToLoadError(failure.toError()),
            };
        },
    };
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

const foreground_status_argv = [_][]const u8{ "git", "status", "--porcelain=v1", "-z", "-uall" };
const background_status_argv = [_][]const u8{ "git", "--no-optional-locks", "status", "--porcelain=v1", "-z", "-uall" };

fn statusArgvForOrigin(origin: ReadOrigin) []const []const u8 {
    return switch (origin) {
        .foreground => &foreground_status_argv,
        .background => &background_status_argv,
    };
}

fn loadGitStatus(allocator: std.mem.Allocator, io: std.Io, request: GitStatusRequest) LoadError!StatusLoadResult {
    const argv = statusArgvForOrigin(request.origin);
    const result = try runCapturedCommand(allocator, io, request.repo_root, argv, .limited(max_status_bytes), .limited(256 * 1024));
    return statusResultFromGitCommand(allocator, result, "git status");
}

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

fn repositoryManifestArgv() []const []const u8 {
    return &repository_manifest_argv;
}

fn loadGitRepositoryManifest(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir) LoadError!RepositoryManifestLoadResult {
    const result = process_runner.runCaptured(allocator, io, .{
        .argv = repositoryManifestArgv(),
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(max_repository_manifest_bytes),
        .stderr_limit = .limited(256 * 1024),
    }) catch |err| return runnerErrorToLoadError(err);
    return repositoryManifestResultFromGitCommand(allocator, result);
}

const repository_file_status_argv = [_][]const u8{
    "git",
    "--no-optional-locks",
    "status",
    "--porcelain=v1",
    "-z",
    "-uall",
};

fn repositoryFileStatusArgv() []const []const u8 {
    return &repository_file_status_argv;
}

fn loadGitRepositoryFileStatus(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir) LoadError!RepositoryFileStatusLoadResult {
    const result = process_runner.runCaptured(allocator, io, .{
        .argv = repositoryFileStatusArgv(),
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(max_status_bytes),
        .stderr_limit = .limited(256 * 1024),
    }) catch |err| return runnerErrorToLoadError(err);
    return repositoryFileStatusResultFromGitCommand(allocator, result);
}

const repository_change_small_output_limit = 256 * 1024;

const HeadState = union(enum) {
    unborn,
    present: []const u8,
};

const AttributeValue = enum { unspecified, unset };

const AttributeState = struct {
    filter: AttributeValue,
    working_tree_encoding: AttributeValue,

    fn eql(self: AttributeState, other: AttributeState) bool {
        return self.filter == other.filter and self.working_tree_encoding == other.working_tree_encoding;
    }
};

const TreeBlob = struct {
    oid: []const u8,
};

const RepositoryChangePhaseHook = struct {
    context: *anyopaque,
    run: *const fn (*anyopaque, std.Io, std.Io.Dir) LoadError!void,

    fn invoke(self: RepositoryChangePhaseHook, io: std.Io, cwd: std.Io.Dir) LoadError!void {
        return self.run(self.context, io, cwd);
    }
};

const RepositoryChangeWriteTarget = enum { head, current };

/// Private deterministic seams for contracts that require a mutation between
/// synchronous Git commands. Production always passes null so test vocabulary
/// does not become part of the public backend namespace.
const RepositoryChangeTestHooks = struct {
    command_index: usize = 0,
    fail_command_at: ?usize = null,
    limit_command_at: ?usize = null,
    forced_stdout_limit: usize = 0,
    fail_write: ?RepositoryChangeWriteTarget = null,
    fail_temp_open: bool = false,
    temp_name_token: ?[]const u8 = null,
    force_cleanup_failure: bool = false,
    after_head_resolved: ?RepositoryChangePhaseHook = null,
    after_blob_loaded: ?RepositoryChangePhaseHook = null,
};

fn loadGitRepositoryFileChange(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: RepositoryFileChangeRequest,
) LoadError!RepositoryFileChangeLoadResult {
    return loadGitRepositoryFileChangeWithHooks(allocator, io, request, null);
}

fn loadGitRepositoryFileChangeWithHooks(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: RepositoryFileChangeRequest,
    hooks: ?*RepositoryChangeTestHooks,
) LoadError!RepositoryFileChangeLoadResult {
    const head_result = try runRepositoryChangeCommand(allocator, io, request.cwd, &.{
        "git",
        "--no-optional-locks",
        "--literal-pathspecs",
        "status",
        "--porcelain=v2",
        "--branch",
        "-z",
        "--untracked-files=no",
        "--",
        request.path,
    }, &.{}, repository_change_small_output_limit, hooks);
    defer head_result.deinit(allocator);
    if (!termExited(head_result.term, 0)) return .{ .failed_static = "Repository change basis unavailable" };
    const head = parsePorcelainHead(head_result.stdout) orelse return .{ .failed_static = "Repository change basis unavailable" };
    if (head == .unborn) return .all_added;
    if (hooks) |test_hooks| if (test_hooks.after_head_resolved) |hook| try hook.invoke(io, request.cwd);

    const treeish = std.fmt.allocPrint(allocator, "{s}^{{tree}}", .{head.present}) catch return error.OutOfMemory;
    defer allocator.free(treeish);
    const tree_result = try runRepositoryChangeCommand(allocator, io, request.cwd, &.{
        "git",
        "--no-optional-locks",
        "rev-parse",
        "--verify",
        treeish,
    }, &.{}, 128, hooks);
    defer tree_result.deinit(allocator);
    if (!termExited(tree_result.term, 0)) return .{ .failed_static = "Repository change basis unavailable" };
    const tree_oid = trimSingleLine(tree_result.stdout);
    if (!isObjectId(tree_oid)) return .{ .failed_static = "Repository change basis unavailable" };

    const entry_result = try runRepositoryChangeCommand(allocator, io, request.cwd, &.{
        "git",
        "--no-optional-locks",
        "--literal-pathspecs",
        "ls-tree",
        "-z",
        "--full-tree",
        tree_oid,
        "--",
        request.path,
    }, &.{}, repository_change_small_output_limit, hooks);
    defer entry_result.deinit(allocator);
    if (!termExited(entry_result.term, 0)) return .{ .failed_static = "Repository change basis unavailable" };
    const blob = parseTreeBlob(entry_result.stdout, request.path) catch return .{ .failed_static = "Repository change basis unavailable" };
    if (blob == null) return .all_added;

    const attributes_before = try loadSafeRepositoryChangeAttributes(allocator, io, request.cwd, request.path, hooks) orelse
        return .{ .failed_static = "Repository change attributes unavailable" };

    const blob_result = try runRepositoryChangeCommand(allocator, io, request.cwd, &.{
        "git",
        "--no-optional-locks",
        "cat-file",
        "blob",
        blob.?.oid,
    }, &.{}, max_diff_bytes, hooks);
    defer blob_result.deinit(allocator);
    if (!termExited(blob_result.term, 0)) return .{ .failed_static = "Repository change basis unavailable" };
    if (hooks) |test_hooks| if (test_hooks.after_blob_loaded) |hook| try hook.invoke(io, request.cwd);

    const head_logical = repository_change_map.normalizeCrlfAlloc(allocator, blob_result.stdout) catch return error.OutOfMemory;
    defer allocator.free(head_logical);
    const current_logical = repository_change_map.normalizeCrlfAlloc(allocator, request.source_bytes) catch return error.OutOfMemory;
    defer allocator.free(current_logical);

    var temp = try ComparisonTemp.init(
        allocator,
        io,
        request.temp_base_path,
        if (hooks) |test_hooks| test_hooks.temp_name_token else null,
        if (hooks) |test_hooks| test_hooks.fail_temp_open else false,
    );
    var temp_active = true;
    defer if (temp_active) temp.deinitBestEffort(allocator, io);
    if (hooks) |test_hooks| if (test_hooks.fail_write == .head) return error.SpawnFailed;
    try writePrivateComparisonFile(io, temp.dir, "head", head_logical);
    if (hooks) |test_hooks| if (test_hooks.fail_write == .current) return error.SpawnFailed;
    try writePrivateComparisonFile(io, temp.dir, "current", current_logical);

    const diff_result = try runRepositoryChangeCommand(allocator, io, temp.dir, &.{
        "git",
        "diff",
        "--no-index",
        "--text",
        "--unified=0",
        "--no-color",
        "--no-ext-diff",
        "--no-textconv",
        "--no-renames",
        "--src-prefix=a/",
        "--dst-prefix=b/",
        "--",
        "head",
        "current",
    }, &.{}, max_diff_bytes, hooks);
    errdefer diff_result.deinit(allocator);

    const attributes_after = try loadSafeRepositoryChangeAttributes(allocator, io, request.cwd, request.path, hooks) orelse {
        diff_result.deinit(allocator);
        return .{ .failed_static = "Repository change attributes unavailable" };
    };
    if (!attributes_before.eql(attributes_after)) {
        diff_result.deinit(allocator);
        return .{ .failed_static = "Repository change attributes changed" };
    }

    const candidate: RepositoryFileChangeLoadResult = candidate: {
        switch (diff_result.term) {
            .exited => |code| switch (code) {
                0 => {
                    diff_result.deinit(allocator);
                    break :candidate .unchanged;
                },
                1 => {
                    allocator.free(diff_result.stderr);
                    break :candidate .{ .patch = diff_result.stdout };
                },
                else => {},
            },
            else => {},
        }
        diff_result.deinit(allocator);
        break :candidate .{ .failed_static = "Repository source comparison failed" };
    };

    // A patch is not a successful backend result until its raw materialization
    // is gone. This terminal consumes the temp owner even on delete failure;
    // the candidate is then released and only static optional unavailability
    // can escape. The defer remains solely for error unwind before this point.
    const cleaned = temp.finish(allocator, io, if (hooks) |test_hooks| test_hooks.force_cleanup_failure else false);
    temp_active = false;
    if (!cleaned) {
        candidate.deinit(allocator);
        return .{ .failed_static = "Repository comparison cleanup failed" };
    }
    return candidate;
}

fn runRepositoryChangeCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    argv: []const []const u8,
    stdin: []const u8,
    stdout_limit: usize,
    hooks: ?*RepositoryChangeTestHooks,
) LoadError!process_runner.Result {
    var effective_stdout_limit = stdout_limit;
    if (hooks) |test_hooks| {
        const command_index = test_hooks.command_index;
        test_hooks.command_index += 1;
        if (test_hooks.fail_command_at == command_index) return error.SpawnFailed;
        if (test_hooks.limit_command_at == command_index) effective_stdout_limit = @min(effective_stdout_limit, test_hooks.forced_stdout_limit);
    }
    return process_runner.runWithStdin(allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdin = stdin,
        .stdout_limit = .limited(effective_stdout_limit),
        .stderr_limit = .limited(repository_change_small_output_limit),
    }) catch |err| return runnerErrorToLoadError(err);
}

fn termExited(term: std.process.Child.Term, expected: u8) bool {
    return switch (term) {
        .exited => |code| code == expected,
        else => false,
    };
}

fn parsePorcelainHead(output: []const u8) ?HeadState {
    const prefix = "# branch.oid ";
    var start: usize = 0;
    while (start < output.len) {
        const newline = std.mem.indexOfAnyPos(u8, output, start, "\n\x00") orelse output.len;
        const record = output[start..newline];
        if (std.mem.startsWith(u8, record, prefix)) {
            const value = record[prefix.len..];
            if (std.mem.eql(u8, value, "(initial)")) return .unborn;
            if (isObjectId(value)) return .{ .present = value };
            return null;
        }
        start = if (newline < output.len) newline + 1 else output.len;
    }
    return null;
}

fn trimSingleLine(output: []const u8) []const u8 {
    return std.mem.trim(u8, output, "\r\n");
}

fn isObjectId(value: []const u8) bool {
    if (value.len != 40 and value.len != 64) return false;
    for (value) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

fn parseTreeBlob(output: []const u8, expected_path: []const u8) !?TreeBlob {
    if (output.len == 0) return null;
    const record_end = std.mem.indexOfScalar(u8, output, 0) orelse return error.MalformedTreeEntry;
    if (record_end + 1 != output.len) return error.MultipleTreeEntries;
    const record = output[0..record_end];
    const tab = std.mem.indexOfScalar(u8, record, '\t') orelse return error.MalformedTreeEntry;
    const metadata = record[0..tab];
    const path = record[tab + 1 ..];
    if (!std.mem.eql(u8, path, expected_path)) return error.UnexpectedTreePath;
    var fields = std.mem.splitScalar(u8, metadata, ' ');
    const mode = fields.next() orelse return error.MalformedTreeEntry;
    const kind = fields.next() orelse return error.MalformedTreeEntry;
    const oid = fields.next() orelse return error.MalformedTreeEntry;
    if (fields.next() != null) return error.MalformedTreeEntry;
    if ((!std.mem.eql(u8, mode, "100644") and !std.mem.eql(u8, mode, "100755")) or
        !std.mem.eql(u8, kind, "blob") or !isObjectId(oid)) return error.UnsupportedTreeEntry;
    return .{ .oid = oid };
}

fn loadSafeRepositoryChangeAttributes(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    path: []const u8,
    hooks: ?*RepositoryChangeTestHooks,
) LoadError!?AttributeState {
    const stdin = allocator.alloc(u8, path.len + 1) catch return error.OutOfMemory;
    defer allocator.free(stdin);
    @memcpy(stdin[0..path.len], path);
    stdin[path.len] = 0;
    const result = try runRepositoryChangeCommand(allocator, io, cwd, &.{
        "git",
        "--no-optional-locks",
        "--literal-pathspecs",
        "check-attr",
        "-z",
        "--stdin",
        "filter",
        "working-tree-encoding",
    }, stdin, repository_change_small_output_limit, hooks);
    defer result.deinit(allocator);
    if (!termExited(result.term, 0)) return null;
    return parseSafeAttributes(result.stdout, path);
}

fn parseSafeAttributes(output: []const u8, expected_path: []const u8) ?AttributeState {
    var fields = std.mem.splitScalar(u8, output, 0);
    const first_path = fields.next() orelse return null;
    const first_name = fields.next() orelse return null;
    const first_value = fields.next() orelse return null;
    const second_path = fields.next() orelse return null;
    const second_name = fields.next() orelse return null;
    const second_value = fields.next() orelse return null;
    if (fields.next()) |tail| if (tail.len != 0 or fields.next() != null) return null;
    if (!std.mem.eql(u8, first_path, expected_path) or !std.mem.eql(u8, second_path, expected_path) or
        !std.mem.eql(u8, first_name, "filter") or !std.mem.eql(u8, second_name, "working-tree-encoding")) return null;
    return .{
        .filter = parseSafeAttributeValue(first_value) orelse return null,
        .working_tree_encoding = parseSafeAttributeValue(second_value) orelse return null,
    };
}

fn parseSafeAttributeValue(value: []const u8) ?AttributeValue {
    if (std.mem.eql(u8, value, "unspecified")) return .unspecified;
    if (std.mem.eql(u8, value, "unset")) return .unset;
    return null;
}

const ComparisonTemp = struct {
    base_dir: std.Io.Dir,
    dir: std.Io.Dir,
    dir_name: []u8,

    fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        configured_base: []const u8,
        name_token: ?[]const u8,
        fail_open: bool,
    ) LoadError!ComparisonTemp {
        const preferred = if (std.fs.path.isAbsolute(configured_base)) configured_base else "/tmp";
        var base_dir = std.Io.Dir.openDirAbsolute(io, preferred, .{}) catch
            std.Io.Dir.openDirAbsolute(io, "/tmp", .{}) catch return error.SpawnFailed;
        errdefer base_dir.close(io);
        const now = std.Io.Clock.now(.awake, io).nanoseconds;
        for (0..16) |attempt| {
            const dir_name = if (name_token) |token|
                std.fmt.allocPrint(allocator, "gitframe-change-{s}-{d}", .{ token, attempt }) catch return error.OutOfMemory
            else
                std.fmt.allocPrint(allocator, "gitframe-change-{d}-{d}", .{ now, attempt }) catch return error.OutOfMemory;
            base_dir.createDir(io, dir_name, .fromMode(0o700)) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    allocator.free(dir_name);
                    continue;
                },
                else => {
                    allocator.free(dir_name);
                    return error.SpawnFailed;
                },
            };
            if (fail_open) {
                base_dir.deleteTree(io, dir_name) catch {};
                allocator.free(dir_name);
                return error.SpawnFailed;
            }
            const dir = base_dir.openDir(io, dir_name, .{}) catch {
                base_dir.deleteTree(io, dir_name) catch {};
                allocator.free(dir_name);
                return error.SpawnFailed;
            };
            return .{ .base_dir = base_dir, .dir = dir, .dir_name = dir_name };
        }
        return error.SpawnFailed;
    }

    /// Consumes every handle/name owner and reports whether recursive removal
    /// completed. `force_failure` is a test-only simulation of a filesystem
    /// refusal and deliberately leaves the private directory for the fixture
    /// to inspect and remove.
    fn finish(self: *ComparisonTemp, allocator: std.mem.Allocator, io: std.Io, force_failure: bool) bool {
        self.dir.close(io);
        const removed = if (force_failure) false else blk: {
            self.base_dir.deleteTree(io, self.dir_name) catch break :blk false;
            break :blk true;
        };
        self.base_dir.close(io);
        allocator.free(self.dir_name);
        self.* = undefined;
        return removed;
    }

    fn deinitBestEffort(self: *ComparisonTemp, allocator: std.mem.Allocator, io: std.Io) void {
        _ = self.finish(allocator, io, false);
    }
};

fn writePrivateComparisonFile(io: std.Io, dir: std.Io.Dir, name: []const u8, contents: []const u8) LoadError!void {
    var file = dir.createFile(io, name, .{ .exclusive = true, .permissions = .fromMode(0o600) }) catch return error.SpawnFailed;
    defer file.close(io);
    file.writeStreamingAll(io, contents) catch return error.SpawnFailed;
}

fn repositoryChangeMapForTest(cwd: std.Io.Dir, path: []const u8, source_bytes: []const u8, temp_base_path: []const u8) !repository_change_map.Map {
    const result = try LocalCommandBackend.loadRepositoryFileChange(std.testing.allocator, std.testing.io, .{
        .cwd = cwd,
        .path = path,
        .source_bytes = source_bytes,
        .temp_base_path = temp_base_path,
    });
    defer result.deinit(std.testing.allocator);
    return switch (result) {
        .all_added => repository_change_map.allAdded(std.testing.allocator, testContentLineCount(source_bytes)),
        .patch => |patch| repository_change_map.fromPatch(std.testing.allocator, patch, testContentLineCount(source_bytes)),
        .unchanged => repository_change_map.fromPatch(std.testing.allocator, "", testContentLineCount(source_bytes)),
        .failed_static => error.UnexpectedRepositoryChangeFailure,
    };
}

fn testContentLineCount(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    var count: usize = 1;
    for (bytes[0 .. bytes.len - 1]) |byte| if (byte == '\n') {
        count += 1;
    };
    return count;
}

test "repository change backend compares current source with pinned HEAD independent of index" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try work.writeFile(io, .{ .sub_path = "source.zig", .data = "keep\nold\nremoved\n" });
    try runTestGit(io, &.{ "git", "add", "source.zig" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" }, work);

    try runTestGit(io, &.{ "git", "rm", "--cached", "--", "source.zig" }, work);
    var index_absent_unchanged = try repositoryChangeMapForTest(work, "source.zig", "keep\nold\nremoved\n", "/tmp");
    defer index_absent_unchanged.deinit(std.testing.allocator);
    try std.testing.expect(index_absent_unchanged.isEmpty());
    try runTestGit(io, &.{ "git", "add", "source.zig" }, work);

    const current = "keep\nnew\nadded\n";
    try work.writeFile(io, .{ .sub_path = "source.zig", .data = current });
    var before_stage = try repositoryChangeMapForTest(work, "source.zig", current, "/tmp");
    defer before_stage.deinit(std.testing.allocator);
    try std.testing.expectEqual(repository_change_map.Kind.modified, before_stage.row(1));
    try std.testing.expectEqual(repository_change_map.Kind.modified, before_stage.row(2));
    try std.testing.expectEqual(repository_change_map.Kind.none, before_stage.row(0));

    try runTestGit(io, &.{ "git", "add", "source.zig" }, work);
    var staged = try repositoryChangeMapForTest(work, "source.zig", current, "/tmp");
    defer staged.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(repository_change_map.Kind, before_stage.rows, staged.rows);

    const mixed_current = "keep\nnewer\nadded\n";
    try work.writeFile(io, .{ .sub_path = "source.zig", .data = mixed_current });
    var mixed = try repositoryChangeMapForTest(work, "source.zig", mixed_current, "/tmp");
    defer mixed.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(repository_change_map.Kind, before_stage.rows, mixed.rows);

    try runTestGit(io, &.{ "git", "rm", "--cached", "-f", "--", "source.zig" }, work);
    var removed_from_index = try repositoryChangeMapForTest(work, "source.zig", mixed_current, "/tmp");
    defer removed_from_index.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(repository_change_map.Kind, before_stage.rows, removed_from_index.rows);
}

test "repository change backend marks new and unborn current rows as added including empty source" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "committed", .default_dir);
    var committed = try tmp.dir.openDir(io, "committed", .{});
    defer committed.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, committed);
    try committed.writeFile(io, .{ .sub_path = "README", .data = "base\n" });
    try runTestGit(io, &.{ "git", "add", "README" }, committed);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" }, committed);

    var untracked = try repositoryChangeMapForTest(committed, "new.zig", "one\ntwo\n", "/tmp");
    defer untracked.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(repository_change_map.Kind, &.{ .added, .added }, untracked.rows);
    try committed.writeFile(io, .{ .sub_path = "new.zig", .data = "one\ntwo\n" });
    try runTestGit(io, &.{ "git", "add", "new.zig" }, committed);
    var tracked_added = try repositoryChangeMapForTest(committed, "new.zig", "one\ntwo\n", "/tmp");
    defer tracked_added.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(repository_change_map.Kind, &.{ .added, .added }, tracked_added.rows);

    try committed.writeFile(io, .{ .sub_path = "untracked-empty", .data = "" });
    var untracked_empty = try repositoryChangeMapForTest(committed, "untracked-empty", "", "/tmp");
    defer untracked_empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), untracked_empty.rows.len);
    try committed.writeFile(io, .{ .sub_path = "tracked-added-empty", .data = "" });
    try runTestGit(io, &.{ "git", "add", "tracked-added-empty" }, committed);
    var tracked_added_empty = try repositoryChangeMapForTest(committed, "tracked-added-empty", "", "/tmp");
    defer tracked_added_empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), tracked_added_empty.rows.len);

    try tmp.dir.createDir(io, "unborn", .default_dir);
    var unborn = try tmp.dir.openDir(io, "unborn", .{});
    defer unborn.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, unborn);
    var unborn_map = try repositoryChangeMapForTest(unborn, "first.zig", "one\ntwo\n", "/tmp");
    defer unborn_map.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(repository_change_map.Kind, &.{ .added, .added }, unborn_map.rows);
    try unborn.writeFile(io, .{ .sub_path = "empty", .data = "" });
    var unborn_empty = try repositoryChangeMapForTest(unborn, "empty", "", "/tmp");
    defer unborn_empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), unborn_empty.rows.len);
}

test "repository change backend treats pathspec magic literally and fails closed for transforming attributes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try work.writeFile(io, .{ .sub_path = "a*b.zig", .data = "literal\n" });
    try work.writeFile(io, .{ .sub_path = "axb.zig", .data = "other\n" });
    try work.writeFile(io, .{ .sub_path = "-leading.zig", .data = "leading\n" });
    try work.writeFile(io, .{ .sub_path = ":(glob)*.zig", .data = "glob magic\n" });
    try work.writeFile(io, .{ .sub_path = "question?.zig", .data = "question\n" });
    try work.writeFile(io, .{ .sub_path = "bracket[.zig", .data = "bracket\n" });
    try runTestGit(io, &.{ "git", "--literal-pathspecs", "add", "--", "a*b.zig", "axb.zig", "-leading.zig", ":(glob)*.zig", "question?.zig", "bracket[.zig" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" }, work);

    var literal = try repositoryChangeMapForTest(work, "a*b.zig", "changed\n", "/tmp");
    defer literal.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(repository_change_map.Kind, &.{.modified}, literal.rows);
    var leading = try repositoryChangeMapForTest(work, "-leading.zig", "changed\n", "/tmp");
    defer leading.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(repository_change_map.Kind, &.{.modified}, leading.rows);
    inline for (.{ ":(glob)*.zig", "question?.zig", "bracket[.zig" }) |magic_path| {
        var magic = try repositoryChangeMapForTest(work, magic_path, "changed\n", "/tmp");
        defer magic.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(repository_change_map.Kind, &.{.modified}, magic.rows);
    }

    try work.writeFile(io, .{ .sub_path = ".gitattributes", .data = "a\\*b.zig filter=unsafe\n" });
    const rejected = try LocalCommandBackend.loadRepositoryFileChange(std.testing.allocator, io, .{
        .cwd = work,
        .path = "a*b.zig",
        .source_bytes = "changed\n",
    });
    defer rejected.deinit(std.testing.allocator);
    try std.testing.expect(rejected == .failed_static);

    try work.writeFile(io, .{ .sub_path = ".gitattributes", .data = "a[*]b.zig working-tree-encoding=UTF-16\n" });
    const encoding_rejected = try LocalCommandBackend.loadRepositoryFileChange(std.testing.allocator, io, .{
        .cwd = work,
        .path = "a*b.zig",
        .source_bytes = "changed\n",
    });
    defer encoding_rejected.deinit(std.testing.allocator);
    try std.testing.expect(encoding_rejected == .failed_static);

    try work.writeFile(io, .{ .sub_path = ".gitattributes", .data = "a\\*b.zig -diff\n" });
    var forced_text = try repositoryChangeMapForTest(work, "a*b.zig", "changed\n", "/tmp");
    defer forced_text.deinit(std.testing.allocator);
    try std.testing.expectEqual(repository_change_map.Kind.modified, forced_text.row(0));

    try work.writeFile(io, .{ .sub_path = ".gitattributes", .data = "a[*]b.zig diff=custom\n" });
    try runTestGit(io, &.{ "git", "config", "diff.custom.textconv", "false" }, work);
    var textconv_disabled = try repositoryChangeMapForTest(work, "a*b.zig", "changed\n", "/tmp");
    defer textconv_disabled.deinit(std.testing.allocator);
    try std.testing.expectEqual(repository_change_map.Kind.modified, textconv_disabled.row(0));
}

test "repository change temporary comparison leaves its private base empty" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "work", .default_dir);
    try tmp.dir.createDir(io, "temp-base", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try work.writeFile(io, .{ .sub_path = "source", .data = "old\n" });
    try runTestGit(io, &.{ "git", "add", "source" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" }, work);
    const temp_base = try tmp.dir.realPathFileAlloc(io, "temp-base", std.testing.allocator);
    defer std.testing.allocator.free(temp_base);

    var direct = try ComparisonTemp.init(std.testing.allocator, io, temp_base, null, false);
    const directory_stat = try direct.base_dir.statFile(io, direct.dir_name, .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), directory_stat.permissions.toMode() & 0o777);
    try writePrivateComparisonFile(io, direct.dir, "source", "private\n");
    const file_stat = try direct.dir.statFile(io, "source", .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), file_stat.permissions.toMode() & 0o777);
    try std.testing.expect(direct.finish(std.testing.allocator, io, false));

    var map = try repositoryChangeMapForTest(work, "source", "new\n", temp_base);
    defer map.deinit(std.testing.allocator);

    var base = try tmp.dir.openDir(io, "temp-base", .{ .iterate = true });
    defer base.close(io);
    var iterator = base.iterate();
    try std.testing.expect(try iterator.next(io) == null);
}

const ResetHeadHookContext = struct {
    oid: []const u8,

    fn run(ctx_ptr: *anyopaque, io: std.Io, cwd: std.Io.Dir) LoadError!void {
        const ctx: *@This() = @ptrCast(@alignCast(ctx_ptr));
        runTestGit(io, &.{ "git", "reset", "--hard", ctx.oid }, cwd) catch return error.SpawnFailed;
    }
};

const RemoveIndexHookContext = struct {
    path: []const u8,

    fn run(ctx_ptr: *anyopaque, io: std.Io, cwd: std.Io.Dir) LoadError!void {
        const ctx: *@This() = @ptrCast(@alignCast(ctx_ptr));
        runTestGit(io, &.{ "git", "rm", "--cached", "--", ctx.path }, cwd) catch return error.SpawnFailed;
    }
};

const RewriteWorktreeHookContext = struct {
    path: []const u8,
    bytes: []const u8,

    fn run(ctx_ptr: *anyopaque, io: std.Io, cwd: std.Io.Dir) LoadError!void {
        const ctx: *@This() = @ptrCast(@alignCast(ctx_ptr));
        cwd.writeFile(io, .{ .sub_path = ctx.path, .data = ctx.bytes }) catch return error.SpawnFailed;
    }
};

test "repository change backend keeps copied object basis across HEAD index and worktree mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "head-move", .default_dir);
    var head_move = try tmp.dir.openDir(io, "head-move", .{});
    defer head_move.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, head_move);
    try head_move.writeFile(io, .{ .sub_path = "source", .data = "old\n" });
    try runTestGit(io, &.{ "git", "add", "source" }, head_move);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "old" }, head_move);
    const old_oid_output = try gitOutputAlloc(io, head_move, &.{ "git", "rev-parse", "HEAD" });
    defer std.testing.allocator.free(old_oid_output);
    try head_move.writeFile(io, .{ .sub_path = "source", .data = "new HEAD\n" });
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-am", "new" }, head_move);
    const new_oid_output = try gitOutputAlloc(io, head_move, &.{ "git", "rev-parse", "HEAD" });
    defer std.testing.allocator.free(new_oid_output);
    try runTestGit(io, &.{ "git", "reset", "--hard", trimLineEnd(old_oid_output) }, head_move);

    var reset_context = ResetHeadHookContext{ .oid = trimLineEnd(new_oid_output) };
    var head_hooks = RepositoryChangeTestHooks{ .after_head_resolved = .{
        .context = &reset_context,
        .run = ResetHeadHookContext.run,
    } };
    const pinned = try loadGitRepositoryFileChangeWithHooks(std.testing.allocator, io, .{
        .cwd = head_move,
        .path = "source",
        .source_bytes = "old\n",
    }, &head_hooks);
    defer pinned.deinit(std.testing.allocator);
    try std.testing.expect(pinned == .unchanged);
    const current_oid_output = try gitOutputAlloc(io, head_move, &.{ "git", "rev-parse", "HEAD" });
    defer std.testing.allocator.free(current_oid_output);
    try std.testing.expectEqualStrings(trimLineEnd(new_oid_output), trimLineEnd(current_oid_output));

    try tmp.dir.createDir(io, "index-move", .default_dir);
    var index_move = try tmp.dir.openDir(io, "index-move", .{});
    defer index_move.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, index_move);
    try index_move.writeFile(io, .{ .sub_path = "source", .data = "same\n" });
    try runTestGit(io, &.{ "git", "add", "source" }, index_move);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" }, index_move);
    var remove_context = RemoveIndexHookContext{ .path = "source" };
    var index_hooks = RepositoryChangeTestHooks{ .after_head_resolved = .{
        .context = &remove_context,
        .run = RemoveIndexHookContext.run,
    } };
    const index_independent = try loadGitRepositoryFileChangeWithHooks(std.testing.allocator, io, .{
        .cwd = index_move,
        .path = "source",
        .source_bytes = "same\n",
    }, &index_hooks);
    defer index_independent.deinit(std.testing.allocator);
    try std.testing.expect(index_independent == .unchanged);

    try runTestGit(io, &.{ "git", "add", "source" }, index_move);
    var rewrite_context = RewriteWorktreeHookContext{ .path = "source", .bytes = "new live bytes\n" };
    var worktree_hooks = RepositoryChangeTestHooks{ .after_blob_loaded = .{
        .context = &rewrite_context,
        .run = RewriteWorktreeHookContext.run,
    } };
    const snapshot_independent = try loadGitRepositoryFileChangeWithHooks(std.testing.allocator, io, .{
        .cwd = index_move,
        .path = "source",
        .source_bytes = "same\n",
    }, &worktree_hooks);
    defer snapshot_independent.deinit(std.testing.allocator);
    try std.testing.expect(snapshot_independent == .unchanged);
}

test "repository change backend normalizes checkout EOL and keeps ident on its logical row" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try runTestGit(io, &.{ "git", "config", "core.autocrlf", "true" }, work);
    try work.writeFile(io, .{ .sub_path = ".gitattributes", .data = "eol.txt text eol=crlf\nident.txt ident\n" });
    try work.writeFile(io, .{ .sub_path = "eol.txt", .data = "one\r\ntwo\r\n" });
    try work.writeFile(io, .{ .sub_path = "ident.txt", .data = "$Id$\nkeep\n" });
    try runTestGit(io, &.{ "git", "add", ".gitattributes", "eol.txt", "ident.txt" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" }, work);

    var eol_unchanged = try repositoryChangeMapForTest(work, "eol.txt", "one\r\ntwo\r\n", "/tmp");
    defer eol_unchanged.deinit(std.testing.allocator);
    try std.testing.expect(eol_unchanged.isEmpty());
    var eol_changed = try repositoryChangeMapForTest(work, "eol.txt", "one\r\nchanged\r\n", "/tmp");
    defer eol_changed.deinit(std.testing.allocator);
    try std.testing.expectEqual(repository_change_map.Kind.modified, eol_changed.row(1));
    try std.testing.expectEqual(repository_change_map.Kind.none, eol_changed.row(0));

    try work.deleteFile(io, "ident.txt");
    try runTestGit(io, &.{ "git", "checkout", "--", "ident.txt" }, work);
    const ident_bytes = try work.readFileAlloc(io, "ident.txt", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(ident_bytes);
    var ident = try repositoryChangeMapForTest(work, "ident.txt", ident_bytes, "/tmp");
    defer ident.deinit(std.testing.allocator);
    try std.testing.expectEqual(repository_change_map.Kind.modified, ident.row(0));
    try std.testing.expectEqual(repository_change_map.Kind.none, ident.row(1));
}

test "repository change success is gated on cleanup and error paths remove private inputs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "work", .default_dir);
    try tmp.dir.createDir(io, "temp-base", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try work.writeFile(io, .{ .sub_path = "source", .data = "old\n" });
    try runTestGit(io, &.{ "git", "add", "source" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" }, work);
    const temp_base = try tmp.dir.realPathFileAlloc(io, "temp-base", std.testing.allocator);
    defer std.testing.allocator.free(temp_base);

    inline for (.{
        .{ .token = "cleanup-patch", .bytes = "changed\n" },
        .{ .token = "cleanup-unchanged", .bytes = "old\n" },
    }) |fixture| {
        var hooks = RepositoryChangeTestHooks{
            .temp_name_token = fixture.token,
            .force_cleanup_failure = true,
        };
        const result = try loadGitRepositoryFileChangeWithHooks(std.testing.allocator, io, .{
            .cwd = work,
            .path = "source",
            .source_bytes = fixture.bytes,
            .temp_base_path = temp_base,
        }, &hooks);
        defer result.deinit(std.testing.allocator);
        switch (result) {
            .failed_static => |message| try std.testing.expectEqualStrings("Repository comparison cleanup failed", message),
            else => return error.ExpectedCleanupFailure,
        }
        const retained_name = try std.fmt.allocPrint(std.testing.allocator, "gitframe-change-{s}-0", .{fixture.token});
        defer std.testing.allocator.free(retained_name);
        const retained_path = try std.fmt.allocPrint(std.testing.allocator, "temp-base/{s}", .{retained_name});
        defer std.testing.allocator.free(retained_path);
        const retained = try tmp.dir.statFile(io, retained_path, .{ .follow_symlinks = false });
        try std.testing.expectEqual(std.Io.File.Kind.directory, retained.kind);
        var base_for_cleanup = try tmp.dir.openDir(io, "temp-base", .{});
        defer base_for_cleanup.close(io);
        try base_for_cleanup.deleteTree(io, retained_name);
    }

    var collision_base = try tmp.dir.openDir(io, "temp-base", .{});
    defer collision_base.close(io);
    try collision_base.createDir(io, "gitframe-change-collision-0", .fromMode(0o700));
    var collision_hooks = RepositoryChangeTestHooks{ .temp_name_token = "collision" };
    const collision_result = try loadGitRepositoryFileChangeWithHooks(std.testing.allocator, io, .{
        .cwd = work,
        .path = "source",
        .source_bytes = "changed\n",
        .temp_base_path = temp_base,
    }, &collision_hooks);
    defer collision_result.deinit(std.testing.allocator);
    try std.testing.expect(collision_result == .patch);
    try collision_base.deleteTree(io, "gitframe-change-collision-0");

    var open_hooks = RepositoryChangeTestHooks{ .fail_temp_open = true, .temp_name_token = "open-failure" };
    try std.testing.expectError(error.SpawnFailed, loadGitRepositoryFileChangeWithHooks(std.testing.allocator, io, .{
        .cwd = work,
        .path = "source",
        .source_bytes = "changed\n",
        .temp_base_path = temp_base,
    }, &open_hooks));

    inline for (.{ RepositoryChangeWriteTarget.head, RepositoryChangeWriteTarget.current }) |write_failure| {
        var write_hooks = RepositoryChangeTestHooks{ .fail_write = write_failure, .temp_name_token = @tagName(write_failure) };
        try std.testing.expectError(error.SpawnFailed, loadGitRepositoryFileChangeWithHooks(std.testing.allocator, io, .{
            .cwd = work,
            .path = "source",
            .source_bytes = "changed\n",
            .temp_base_path = temp_base,
        }, &write_hooks));
    }
    inline for (.{ @as(usize, 5), @as(usize, 6) }) |command_index| {
        var command_hooks = RepositoryChangeTestHooks{ .fail_command_at = command_index, .temp_name_token = if (command_index == 5) "diff-failure" else "post-attr-failure" };
        try std.testing.expectError(error.SpawnFailed, loadGitRepositoryFileChangeWithHooks(std.testing.allocator, io, .{
            .cwd = work,
            .path = "source",
            .source_bytes = "changed\n",
            .temp_base_path = temp_base,
        }, &command_hooks));
    }
    var limit_hooks = RepositoryChangeTestHooks{
        .limit_command_at = 5,
        .forced_stdout_limit = 1,
        .temp_name_token = "output-limit",
    };
    try std.testing.expectError(error.StreamTooLong, loadGitRepositoryFileChangeWithHooks(std.testing.allocator, io, .{
        .cwd = work,
        .path = "source",
        .source_bytes = "changed\n",
        .temp_base_path = temp_base,
    }, &limit_hooks));

    var base = try tmp.dir.openDir(io, "temp-base", .{ .iterate = true });
    defer base.close(io);
    var iterator = base.iterate();
    try std.testing.expect(try iterator.next(io) == null);
}

const RepositoryChangeAllocationFixture = struct {
    io: std.Io,
    cwd: std.Io.Dir,
    temp_base_path: []const u8,

    fn exercise(allocator: std.mem.Allocator, fixture: *@This()) !void {
        var hooks = RepositoryChangeTestHooks{ .temp_name_token = "allocation" };
        const result = try loadGitRepositoryFileChangeWithHooks(allocator, fixture.io, .{
            .cwd = fixture.cwd,
            .path = "source",
            .source_bytes = "changed\n",
            .temp_base_path = fixture.temp_base_path,
        }, &hooks);
        defer result.deinit(allocator);
        if (result != .patch) return error.ExpectedPatch;
    }
};

test "repository change backend releases private inputs at every allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "work", .default_dir);
    try tmp.dir.createDir(io, "temp-base", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try work.writeFile(io, .{ .sub_path = "source", .data = "old\n" });
    try runTestGit(io, &.{ "git", "add", "source" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" }, work);
    const temp_base = try tmp.dir.realPathFileAlloc(io, "temp-base", std.testing.allocator);
    defer std.testing.allocator.free(temp_base);
    var fixture = RepositoryChangeAllocationFixture{ .io = io, .cwd = work, .temp_base_path = temp_base };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, RepositoryChangeAllocationFixture.exercise, .{&fixture});

    var base = try tmp.dir.openDir(io, "temp-base", .{ .iterate = true });
    defer base.close(io);
    var iterator = base.iterate();
    try std.testing.expect(try iterator.next(io) == null);
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

    var result = try LocalCommandBackend.loadRepositoryFileStatus(std.testing.allocator, io, .{ .cwd = work });
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

    const result = try LocalCommandBackend.loadRepositoryFileStatus(std.testing.allocator, io, .{ .cwd = committed });
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

    var result = try LocalCommandBackend.loadRepositoryFileStatus(std.testing.allocator, io, .{ .cwd = work });
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

    var result = try LocalCommandBackend.loadRepositoryFileStatus(allocator, io, .{ .cwd = work });
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

    const result = try LocalCommandBackend.loadRepositoryManifest(std.testing.allocator, io, .{ .cwd = work });
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

    const result = try LocalCommandBackend.loadRepositoryManifest(std.testing.allocator, io, .{ .cwd = work });
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

    const result = try LocalCommandBackend.loadRepositoryManifest(std.testing.allocator, io, .{ .cwd = work });
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

    const result = try LocalCommandBackend.loadRepositoryManifest(std.testing.allocator, io, .{ .cwd = committed });
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

fn loadGitBranchStatus(allocator: std.mem.Allocator, io: std.Io, request: BranchStatusRequest) LoadError!BranchStatusLoadResult {
    var builder = git_branch_status.Builder.init(allocator);
    defer builder.deinit();

    const cwd: std.process.Child.Cwd = switch (request.cwd) {
        .path => |path| .{ .path = path },
        .dir => |dir| .{ .dir = dir },
    };
    var env = try controlledGitEnvironment(allocator, request.parent_env);
    defer env.deinit();

    const head_argv = [_][]const u8{ "git", "symbolic-ref", "--quiet", "--short", "HEAD" };
    const head_result = try runGitBranchStatusCommandInCwd(allocator, io, cwd, &env, &head_argv, .limited(4 * 1024));
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
    const oid_result = try runGitBranchStatusCommandInCwd(allocator, io, cwd, &env, &oid_argv, .limited(4 * 1024));
    defer oid_result.deinit(allocator);
    switch (oid_result.term) {
        .exited => |code| if (code == 0) {
            try builder.setOid(trimLineEnd(oid_result.stdout));
        },
        else => return branchStatusCommandFailure(allocator, "git rev-parse HEAD", oid_result),
    }

    const upstream_argv = [_][]const u8{ "git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}" };
    const upstream_result = try runGitBranchStatusCommandInCwd(allocator, io, cwd, &env, &upstream_argv, .limited(4 * 1024));
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
        const ab_result = try runGitBranchStatusCommandInCwd(allocator, io, cwd, &env, &ab_argv, .limited(4 * 1024));
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

fn loadGitBranchList(allocator: std.mem.Allocator, io: std.Io, request: BranchListRequest) LoadError!BranchListLoadResult {
    return loadGitBranchListWithLimit(allocator, io, request, .limited(max_branch_list_bytes));
}

fn loadGitBranchListWithLimit(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: BranchListRequest,
    list_stdout_limit: std.Io.Limit,
) LoadError!BranchListLoadResult {
    const cwd: std.process.Child.Cwd = switch (request.cwd) {
        .path => |path| .{ .path = path },
        .dir => |dir| .{ .dir = dir },
    };
    var controlled_env: ?std.process.Environ.Map = switch (request.environment) {
        .inherited => null,
        .controlled => |parent| try controlledGitEnvironment(allocator, parent),
    };
    defer if (controlled_env) |*env| env.deinit();
    const env: ?*const std.process.Environ.Map = if (controlled_env) |*value| value else null;

    const current_argv = [_][]const u8{ "git", "symbolic-ref", "--quiet", "--short", "HEAD" };
    const current_result = try runGitBranchStatusCommandInCwd(allocator, io, cwd, env, &current_argv, .limited(4 * 1024));
    defer current_result.deinit(allocator);

    const format = "--format=%(refname)%00%(refname:short)%00%(objectname)%00%(symref)%00";
    const local_argv = [_][]const u8{ "git", "for-each-ref", format, "refs/heads" };
    const all_argv = [_][]const u8{ "git", "for-each-ref", format, "refs/heads", "refs/remotes" };
    const list_result = switch (request.scope) {
        .local => try runGitBranchStatusCommandInCwd(allocator, io, cwd, env, &local_argv, list_stdout_limit),
        .local_and_remote => try runGitBranchStatusCommandInCwd(allocator, io, cwd, env, &all_argv, list_stdout_limit),
    };
    defer list_result.deinit(allocator);

    return branchListResultFromCommandResults(allocator, current_result, list_result);
}

const ComparePhaseHook = struct {
    context: *anyopaque,
    run: *const fn (*anyopaque, std.Io, std.Io.Dir) LoadError!void,

    fn invoke(self: ComparePhaseHook, io: std.Io, cwd: std.Io.Dir) LoadError!void {
        return self.run(self.context, io, cwd);
    }
};

/// Private deterministic seam for proving that ref movement after step 2
/// cannot affect merge-base, ahead count, or diff. Production always passes
/// null, keeping test orchestration out of the public backend contract.
const CompareTestHooks = struct {
    after_endpoints_pinned: ?ComparePhaseHook = null,
};

const CompareTextResult = union(enum) {
    text: []u8,
    absent,
    failed: []u8,
};

const CompareTargetResolution = union(enum) {
    resolved: struct {
        target: CompareTarget,
        oid: []u8,
    },
    missing: CompareTarget,
    failed: []u8,
    failed_static: []const u8,
};

const CompareHeadResolution = union(enum) {
    resolved: struct {
        oid: []u8,
        name: ?[]u8,
    },
    unresolved,
    failed: []u8,
};

const CompareMergeBaseResult = union(enum) {
    oid: []u8,
    no_merge_base,
    failed: []u8,
};

fn loadGitCompareSnapshot(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: CompareSnapshotRequest,
) LoadError!CompareSnapshotResult {
    return loadGitCompareSnapshotWithHooks(allocator, io, request, null);
}

fn loadGitCompareSnapshotWithHooks(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: CompareSnapshotRequest,
    hooks: ?*CompareTestHooks,
) LoadError!CompareSnapshotResult {
    var env = try controlledGitEnvironment(allocator, request.parent_env);
    defer env.deinit();

    const resolution = if (request.target) |target|
        try resolveExplicitCompareTarget(allocator, io, request.cwd, &env, target)
    else
        try resolveDefaultCompareTarget(allocator, io, request.cwd, &env);

    const resolved = switch (resolution) {
        .resolved => |value| value,
        .missing => |attempted| return .{ .basis_failed = .{
            .kind = .missing_base_ref,
            .attempted = attempted,
        } },
        .failed => |message| return .{ .failed = message },
        .failed_static => |message| return .{ .failed_static = message },
    };
    var target = resolved.target;
    var target_owned = true;
    defer if (target_owned) target.deinit(allocator);
    const base_oid = resolved.oid;
    var base_oid_owned = true;
    defer if (base_oid_owned) allocator.free(base_oid);

    const head_resolution = try resolveCompareHead(allocator, io, request.cwd, &env);
    const resolved_head = switch (head_resolution) {
        .resolved => |value| value,
        .unresolved => {
            target_owned = false;
            return .{ .basis_failed = .{
                .kind = .head_unresolved,
                .attempted = target,
            } };
        },
        .failed => |message| return .{ .failed = message },
    };
    const head_oid = resolved_head.oid;
    var head_oid_owned = true;
    defer if (head_oid_owned) allocator.free(head_oid);
    const head_name = resolved_head.name;
    var head_name_owned = head_name != null;
    defer if (head_name_owned) allocator.free(head_name.?);

    if (hooks) |test_hooks| if (test_hooks.after_endpoints_pinned) |hook| {
        try hook.invoke(io, request.cwd);
    };

    const merge_result = try resolveCompareMergeBase(
        allocator,
        io,
        request.cwd,
        &env,
        base_oid,
        head_oid,
    );
    const merge_base_oid = switch (merge_result) {
        .oid => |oid| oid,
        .no_merge_base => {
            target_owned = false;
            return .{ .basis_failed = .{
                .kind = .no_merge_base,
                .attempted = target,
            } };
        },
        .failed => |message| return .{ .failed = message },
    };
    var merge_base_oid_owned = true;
    defer if (merge_base_oid_owned) allocator.free(merge_base_oid);

    const ahead_count = switch (try loadCompareAheadCount(
        allocator,
        io,
        request.cwd,
        &env,
        merge_base_oid,
        head_oid,
    )) {
        .text => |text| text,
        .absent => return .{ .failed_static = "git rev-list returned no count" },
        .failed => |message| return .{ .failed = message },
    };
    var ahead_count_owned = true;
    defer if (ahead_count_owned) allocator.free(ahead_count);

    const diff = switch (try loadCompareDiff(
        allocator,
        io,
        request.cwd,
        &env,
        merge_base_oid,
        head_oid,
    )) {
        .text => |text| text,
        .absent => return .{ .failed_static = "git diff returned no output record" },
        .failed => |message| return .{ .failed = message },
    };

    target_owned = false;
    base_oid_owned = false;
    head_oid_owned = false;
    head_name_owned = false;
    merge_base_oid_owned = false;
    ahead_count_owned = false;
    return .{ .snapshot = .{
        .target = target,
        .base_oid = base_oid,
        .head_oid = head_oid,
        .head_name = head_name,
        .merge_base_oid = merge_base_oid,
        .ahead_count = ahead_count,
        .diff = diff,
    } };
}

fn resolveExplicitCompareTarget(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    env: *const std.process.Environ.Map,
    spec: CompareTargetSpec,
) LoadError!CompareTargetResolution {
    if (branchKind(spec.full_ref) != spec.kind) {
        return .{ .failed_static = "Compare target kind does not match its full ref" };
    }
    const target = try cloneCompareTarget(allocator, spec);
    return resolveOwnedCompareTarget(allocator, io, cwd, env, target);
}

fn resolveDefaultCompareTarget(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    env: *const std.process.Environ.Map,
) LoadError!CompareTargetResolution {
    const origin_head_argv = [_][]const u8{
        "git",
        "symbolic-ref",
        "--quiet",
        "refs/remotes/origin/HEAD",
    };
    switch (try runOptionalCompareText(
        allocator,
        io,
        cwd,
        env,
        &origin_head_argv,
        "git symbolic-ref origin/HEAD",
        .limited(4 * 1024),
    )) {
        .text => |full_ref| {
            defer allocator.free(full_ref);
            const target = compareTargetFromFullRef(allocator, full_ref) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return .{ .failed_static = "origin/HEAD did not resolve to a branch ref" },
            };
            switch (try resolveOwnedCompareTarget(allocator, io, cwd, env, target)) {
                .resolved => |resolved| return .{ .resolved = resolved },
                .missing => |missing_value| {
                    var missing = missing_value;
                    missing.deinit(allocator);
                },
                .failed => |message| return .{ .failed = message },
                .failed_static => |message| return .{ .failed_static = message },
            }
        },
        .absent => {},
        .failed => |message| return .{ .failed = message },
    }

    const main_target = compareTargetFromFullRef(allocator, "refs/heads/main") catch |err| switch (err) {
        error.InvalidCompareRef => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
    };
    switch (try resolveOwnedCompareTarget(allocator, io, cwd, env, main_target)) {
        .resolved => |resolved| return .{ .resolved = resolved },
        .missing => |missing_value| {
            var missing = missing_value;
            missing.deinit(allocator);
        },
        .failed => |message| return .{ .failed = message },
        .failed_static => |message| return .{ .failed_static = message },
    }

    const master_target = compareTargetFromFullRef(allocator, "refs/heads/master") catch |err| switch (err) {
        error.InvalidCompareRef => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return resolveOwnedCompareTarget(allocator, io, cwd, env, master_target);
}

fn resolveOwnedCompareTarget(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    env: *const std.process.Environ.Map,
    target_value: CompareTarget,
) LoadError!CompareTargetResolution {
    var target = target_value;
    var target_owned = true;
    defer if (target_owned) target.deinit(allocator);

    const argv = [_][]const u8{ "git", "rev-parse", "--verify", "--quiet", target.full_ref };
    return switch (try runOptionalCompareText(
        allocator,
        io,
        cwd,
        env,
        &argv,
        "git rev-parse base",
        .limited(4 * 1024),
    )) {
        .text => |oid| result: {
            target_owned = false;
            break :result .{ .resolved = .{ .target = target, .oid = oid } };
        },
        .absent => result: {
            target_owned = false;
            break :result .{ .missing = target };
        },
        .failed => |message| .{ .failed = message },
    };
}

fn resolveCompareHead(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    env: *const std.process.Environ.Map,
) LoadError!CompareHeadResolution {
    const oid_argv = [_][]const u8{ "git", "rev-parse", "--verify", "--quiet", "HEAD" };
    const oid = switch (try runOptionalCompareText(
        allocator,
        io,
        cwd,
        env,
        &oid_argv,
        "git rev-parse HEAD",
        .limited(4 * 1024),
    )) {
        .text => |text| text,
        .absent => return .unresolved,
        .failed => |message| return .{ .failed = message },
    };
    errdefer allocator.free(oid);

    const name_argv = [_][]const u8{ "git", "symbolic-ref", "--quiet", "--short", "HEAD" };
    const name = switch (try runOptionalCompareText(
        allocator,
        io,
        cwd,
        env,
        &name_argv,
        "git symbolic-ref HEAD",
        .limited(4 * 1024),
    )) {
        .text => |text| text,
        .absent => null,
        .failed => |message| {
            allocator.free(oid);
            return .{ .failed = message };
        },
    };
    return .{ .resolved = .{ .oid = oid, .name = name } };
}

fn resolveCompareMergeBase(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    env: *const std.process.Environ.Map,
    base_oid: []const u8,
    head_oid: []const u8,
) LoadError!CompareMergeBaseResult {
    const argv = [_][]const u8{ "git", "merge-base", base_oid, head_oid };
    const result = try runCompareCommand(allocator, io, cwd, env, &argv, .limited(4 * 1024));
    defer result.deinit(allocator);
    switch (result.term) {
        .exited => |code| switch (code) {
            0 => return .{ .oid = try allocator.dupe(u8, trimLineEnd(result.stdout)) },
            1 => return .no_merge_base,
            else => {},
        },
        else => {},
    }
    return .{ .failed = try compareCommandFailure(allocator, "git merge-base", result) };
}

fn loadCompareAheadCount(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    env: *const std.process.Environ.Map,
    merge_base_oid: []const u8,
    head_oid: []const u8,
) LoadError!CompareTextResult {
    const range = try std.fmt.allocPrint(allocator, "{s}..{s}", .{ merge_base_oid, head_oid });
    defer allocator.free(range);
    const argv = [_][]const u8{ "git", "rev-list", "--count", range };
    return runRequiredCompareText(
        allocator,
        io,
        cwd,
        env,
        &argv,
        "git rev-list --count",
        .limited(4 * 1024),
        true,
    );
}

fn loadCompareDiff(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    env: *const std.process.Environ.Map,
    merge_base_oid: []const u8,
    head_oid: []const u8,
) LoadError!CompareTextResult {
    const range = try std.fmt.allocPrint(allocator, "{s}..{s}", .{ merge_base_oid, head_oid });
    defer allocator.free(range);
    const argv = [_][]const u8{
        "git",
        "diff",
        "--no-color",
        "--no-ext-diff",
        "--src-prefix=a/",
        "--dst-prefix=b/",
        range,
    };
    return runRequiredCompareText(
        allocator,
        io,
        cwd,
        env,
        &argv,
        "git diff compare",
        .limited(max_diff_bytes),
        false,
    );
}

fn runOptionalCompareText(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    env: *const std.process.Environ.Map,
    argv: []const []const u8,
    label: []const u8,
    stdout_limit: std.Io.Limit,
) LoadError!CompareTextResult {
    const result = try runCompareCommand(allocator, io, cwd, env, argv, stdout_limit);
    defer result.deinit(allocator);
    switch (result.term) {
        .exited => |code| switch (code) {
            0 => {
                const text = trimLineEnd(result.stdout);
                if (text.len == 0) return .absent;
                return .{ .text = try allocator.dupe(u8, text) };
            },
            // Git uses exit 1 for a quiet symbolic-ref/rev-parse miss. Other
            // exit codes are operational failures, not basis-domain absence.
            1 => return .absent,
            else => return .{ .failed = try compareCommandFailure(allocator, label, result) },
        },
        else => return .{ .failed = try compareCommandFailure(allocator, label, result) },
    }
}

fn runRequiredCompareText(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    env: *const std.process.Environ.Map,
    argv: []const []const u8,
    label: []const u8,
    stdout_limit: std.Io.Limit,
    trim_output: bool,
) LoadError!CompareTextResult {
    const result = try runCompareCommand(allocator, io, cwd, env, argv, stdout_limit);
    defer result.deinit(allocator);
    if (termExited(result.term, 0)) {
        // Diff may be empty. It is still a successful, owned output record.
        const text = if (trim_output) trimLineEnd(result.stdout) else result.stdout;
        return .{ .text = try allocator.dupe(u8, text) };
    }
    return .{ .failed = try compareCommandFailure(allocator, label, result) };
}

fn runCompareCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    env: *const std.process.Environ.Map,
    argv: []const []const u8,
    stdout_limit: std.Io.Limit,
) LoadError!process_runner.Result {
    return process_runner.runCaptured(allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .environ_map = env,
        .stdout_limit = stdout_limit,
        .stderr_limit = .limited(256 * 1024),
    }) catch |err| return runnerErrorToLoadError(err);
}

fn compareCommandFailure(
    allocator: std.mem.Allocator,
    label: []const u8,
    result: process_runner.Result,
) LoadError![]u8 {
    const stderr = trimLineEnd(result.stderr);
    if (stderr.len != 0) return std.fmt.allocPrint(allocator, "{s} failed: {s}", .{ label, stderr });
    return std.fmt.allocPrint(allocator, "{s} failed: {any}", .{ label, result.term });
}

fn cloneCompareTarget(allocator: std.mem.Allocator, spec: CompareTargetSpec) !CompareTarget {
    const full_ref = try allocator.dupe(u8, spec.full_ref);
    errdefer allocator.free(full_ref);
    return .{
        .full_ref = full_ref,
        .display_name = try allocator.dupe(u8, spec.display_name),
        .kind = spec.kind,
    };
}

fn compareTargetFromFullRef(allocator: std.mem.Allocator, full_ref: []const u8) !CompareTarget {
    const kind = branchKind(full_ref) orelse return error.InvalidCompareRef;
    const prefix = switch (kind) {
        .local => "refs/heads/",
        .remote_tracking => "refs/remotes/",
    };
    return cloneCompareTarget(allocator, .{
        .full_ref = full_ref,
        .display_name = full_ref[prefix.len..],
        .kind = kind,
    });
}

/// Interpret borrowed command output and return an independently owned result.
///
/// `current_result` and `list_result` remain owned by the caller. Keeping this
/// seam private lets failure terminals be tested without making process
/// injection part of the backend API.
fn branchListResultFromCommandResults(
    allocator: std.mem.Allocator,
    current_result: process_runner.Result,
    list_result: process_runner.Result,
) LoadError!BranchListLoadResult {
    var current: ?[]u8 = null;
    defer if (current) |owned| allocator.free(owned);
    switch (current_result.term) {
        .exited => |code| if (code == 0) {
            current = allocator.dupe(u8, trimLineEnd(current_result.stdout)) catch return error.OutOfMemory;
        },
        else => {},
    }

    switch (list_result.term) {
        .exited => |code| if (code != 0) return branchListCommandFailure(allocator, list_result),
        else => return branchListCommandFailure(allocator, list_result),
    }

    var items: std.ArrayList(BranchListItem) = .empty;
    errdefer {
        for (items.items) |item| {
            allocator.free(item.full_ref);
            allocator.free(item.name);
            allocator.free(item.oid);
        }
        items.deinit(allocator);
    }

    var index: usize = 0;
    while (index < list_result.stdout.len) {
        skipBranchListRecordSeparators(list_result.stdout, &index);
        if (index >= list_result.stdout.len) break;
        const full_ref_end = std.mem.indexOfScalarPos(u8, list_result.stdout, index, 0) orelse break;
        const full_ref = list_result.stdout[index..full_ref_end];
        index = full_ref_end + 1;
        const name_end = std.mem.indexOfScalarPos(u8, list_result.stdout, index, 0) orelse break;
        const name = list_result.stdout[index..name_end];
        index = name_end + 1;
        const oid_end = std.mem.indexOfScalarPos(u8, list_result.stdout, index, 0) orelse break;
        const oid = list_result.stdout[index..oid_end];
        index = oid_end + 1;
        const symref_end = std.mem.indexOfScalarPos(u8, list_result.stdout, index, 0) orelse break;
        const symref = list_result.stdout[index..symref_end];
        index = symref_end + 1;
        if (full_ref.len == 0 or name.len == 0 or oid.len == 0) continue;

        const kind = branchKind(full_ref) orelse continue;
        if (kind == .remote_tracking and symref.len != 0 and std.mem.endsWith(u8, full_ref, "/HEAD")) continue;

        const owned_full_ref = allocator.dupe(u8, full_ref) catch return error.OutOfMemory;
        const owned_name = allocator.dupe(u8, name) catch {
            allocator.free(owned_full_ref);
            return error.OutOfMemory;
        };
        const owned_oid = allocator.dupe(u8, oid) catch {
            allocator.free(owned_full_ref);
            allocator.free(owned_name);
            return error.OutOfMemory;
        };
        items.append(allocator, .{
            .full_ref = owned_full_ref,
            .name = owned_name,
            .kind = kind,
            .oid = owned_oid,
            .current = kind == .local and current != null and std.mem.eql(u8, current.?, name),
        }) catch {
            allocator.free(owned_full_ref);
            allocator.free(owned_name);
            allocator.free(owned_oid);
            return error.OutOfMemory;
        };
    }

    const branches = items.toOwnedSlice(allocator) catch return error.OutOfMemory;
    const owned_current = current;
    current = null;
    return .{ .ok = .{
        .current = owned_current,
        .branches = branches,
    } };
}

fn branchKind(full_ref: []const u8) ?BranchKind {
    if (std.mem.startsWith(u8, full_ref, "refs/heads/")) return .local;
    if (std.mem.startsWith(u8, full_ref, "refs/remotes/")) return .remote_tracking;
    return null;
}

fn skipBranchListRecordSeparators(output: []const u8, index: *usize) void {
    // `git for-each-ref --format=...%00...%00` still writes its normal record
    // newline after each formatted ref. Branch names are NUL fields, so consume
    // only those record separators before reading the next branch name.
    while (index.* < output.len and (output[index.*] == '\n' or output[index.*] == '\r')) : (index.* += 1) {}
}

test "skipBranchListRecordSeparators preserves branch name after for-each-ref newline" {
    const output = "\nrefs/heads/zig-port\x00zig-port\x00abc\x00\x00";
    var index: usize = 0;
    skipBranchListRecordSeparators(output, &index);
    try std.testing.expectEqual(@as(usize, 1), index);
    try std.testing.expectEqualStrings("refs/heads/zig-port", output[index .. index + "refs/heads/zig-port".len]);
}

test "branch list non-zero result releases current and preserves stderr" {
    var current_stdout = "main\n".*;
    var list_stderr = "fatal: branch list failed\n".*;
    var empty: [0]u8 = .{};
    const result = try branchListResultFromCommandResults(
        std.testing.allocator,
        .{
            .term = .{ .exited = 0 },
            .stdout = &current_stdout,
            .stderr = &empty,
        },
        .{
            .term = .{ .exited = 128 },
            .stdout = &empty,
            .stderr = &list_stderr,
        },
    );
    defer result.deinit(std.testing.allocator);

    switch (result) {
        .failed => |message| try std.testing.expectEqualStrings(&list_stderr, message),
        .ok, .failed_static => return error.ExpectedBranchListFailure,
    }
}

test "branch list abnormal result releases current and preserves termination" {
    var current_stdout = "main\n".*;
    var empty: [0]u8 = .{};
    const result = try branchListResultFromCommandResults(
        std.testing.allocator,
        .{
            .term = .{ .exited = 0 },
            .stdout = &current_stdout,
            .stderr = &empty,
        },
        .{
            .term = .{ .unknown = 9 },
            .stdout = &empty,
            .stderr = &empty,
        },
    );
    defer result.deinit(std.testing.allocator);

    switch (result) {
        .failed => |message| {
            try std.testing.expect(std.mem.indexOf(u8, message, "unknown") != null);
            try std.testing.expect(std.mem.indexOf(u8, message, "9") != null);
        },
        .ok, .failed_static => return error.ExpectedBranchListFailure,
    }
}

test "branch list diagnostic allocation failure releases current" {
    var current_stdout = "main\n".*;
    var list_stderr = "fatal: branch list failed\n".*;
    var empty: [0]u8 = .{};
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });

    try std.testing.expectError(error.OutOfMemory, branchListResultFromCommandResults(
        failing.allocator(),
        .{
            .term = .{ .exited = 0 },
            .stdout = &current_stdout,
            .stderr = &empty,
        },
        .{
            .term = .{ .exited = 128 },
            .stdout = &empty,
            .stderr = &list_stderr,
        },
    ));
}

test "branch list success transfers current ownership exactly once" {
    var current_stdout = "main\n".*;
    var list_stdout = "refs/heads/main\x00main\x00abc\x00\x00\nrefs/heads/feature/topic\x00feature/topic\x00def\x00\x00".*;
    var empty: [0]u8 = .{};
    const result = try branchListResultFromCommandResults(
        std.testing.allocator,
        .{
            .term = .{ .exited = 0 },
            .stdout = &current_stdout,
            .stderr = &empty,
        },
        .{
            .term = .{ .exited = 0 },
            .stdout = &list_stdout,
            .stderr = &empty,
        },
    );
    defer result.deinit(std.testing.allocator);

    const list = switch (result) {
        .ok => |list| list,
        .failed, .failed_static => return error.ExpectedBranchList,
    };
    try std.testing.expectEqualStrings("main", list.current.?);
    try std.testing.expectEqual(@as(usize, 2), list.branches.len);
    try std.testing.expectEqualStrings("refs/heads/main", list.branches[0].full_ref);
    try std.testing.expectEqualStrings("main", list.branches[0].name);
    try std.testing.expectEqual(BranchKind.local, list.branches[0].kind);
    try std.testing.expect(list.branches[0].current);
    try std.testing.expectEqualStrings("feature/topic", list.branches[1].name);
    try std.testing.expect(!list.branches[1].current);
}

fn branchListCommandFailure(allocator: std.mem.Allocator, result: process_runner.Result) LoadError!BranchListLoadResult {
    if (result.stderr.len > 0) return .{ .failed = allocator.dupe(u8, result.stderr) catch return error.OutOfMemory };
    return .{ .failed = std.fmt.allocPrint(allocator, "git branch list failed: {any}", .{result.term}) catch return error.OutOfMemory };
}

fn runGitBranchStatusCommand(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, argv: []const []const u8) LoadError!process_runner.Result {
    return runGitBranchStatusCommandInCwd(allocator, io, .{ .path = repo_root }, null, argv, .limited(4 * 1024));
}

fn runGitBranchStatusCommandInCwd(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.process.Child.Cwd,
    environ_map: ?*const std.process.Environ.Map,
    argv: []const []const u8,
    stdout_limit: std.Io.Limit,
) LoadError!process_runner.Result {
    return process_runner.runCaptured(allocator, io, .{
        .argv = argv,
        .cwd = cwd,
        .environ_map = environ_map,
        .stdout_limit = stdout_limit,
        .stderr_limit = .limited(16 * 1024),
    }) catch |err| return runnerErrorToLoadError(err);
}

/// Build the complete environment for one descriptor-authorized local Git
/// snapshot (branch status or Compare).
///
/// Git gives `GIT_*` variables precedence over cwd and repository config. That
/// family includes repository/worktree selectors (`GIT_DIR`, `GIT_WORK_TREE`,
/// `GIT_COMMON_DIR`, `GIT_INDEX_FILE`), object/ref selectors
/// (`GIT_OBJECT_DIRECTORY`, `GIT_ALTERNATE_OBJECT_DIRECTORIES`,
/// `GIT_NAMESPACE`), and config/discovery injection (`GIT_CONFIG_*`,
/// `GIT_CEILING_DIRECTORIES`). Removing the entire family is intentionally
/// future-proof: a newly inherited Git knob cannot silently become a second
/// repository authority for any command in the snapshot.
fn controlledGitEnvironment(allocator: std.mem.Allocator, parent: ?*const std.process.Environ.Map) LoadError!std.process.Environ.Map {
    var env = if (parent) |map|
        map.clone(allocator) catch return error.OutOfMemory
    else
        std.process.Environ.Map.init(allocator);
    errdefer env.deinit();

    var index: usize = 0;
    while (index < env.keys().len) {
        const key = env.keys()[index];
        if (key.len >= "GIT_".len and std.ascii.eqlIgnoreCase(key[0.."GIT_".len], "GIT_")) {
            _ = env.swapRemove(key);
        } else {
            index += 1;
        }
    }
    return env;
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

fn runGitAddAll(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8) LoadError!OperationResult {
    const argv = [_][]const u8{ "git", "add", "--all", "--", "." };
    const result = try runCapturedCommand(allocator, io, repo_root, &argv, .limited(64 * 1024), .limited(256 * 1024));
    return operationResultFromGitCommand(allocator, result, "git add --all");
}

fn runGitUnstageAll(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8) LoadError!OperationResult {
    const argv = [_][]const u8{ "git", "restore", "--staged", "--", "." };
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
    const detailed = try process_runner.runWithStdinDetailed(allocator, io, .{
        .argv = &argv,
        .cwd = .{ .path = repo_root },
        .stdin = patch,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });

    return operationResultFromGitStdinCommand(allocator, detailed, "git apply --cached");
}

fn runGitApplyCachedReverse(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, patch: []const u8) LoadError!OperationResult {
    const argv = [_][]const u8{ "git", "apply", "--cached", "--reverse", "--whitespace=nowarn", "-" };
    const detailed = try process_runner.runWithStdinDetailed(allocator, io, .{
        .argv = &argv,
        .cwd = .{ .path = repo_root },
        .stdin = patch,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });

    return operationResultFromGitStdinCommand(allocator, detailed, "git apply --cached --reverse");
}

fn runGitCommit(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, request: CommitRequest) LoadError!OperationResult {
    return runGitCommitLike(allocator, io, repo_root, request, false);
}

fn runGitAmend(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, request: CommitRequest) LoadError!OperationResult {
    return runGitCommitLike(allocator, io, repo_root, request, true);
}

const AskpassSetup = struct {
    base_dir: std.Io.Dir,
    base_dir_owned: bool = false,
    dir_name: []u8,
    helper_path: []u8,
    username_path: []u8,
    password_path: []u8,

    fn deinit(self: *AskpassSetup, allocator: std.mem.Allocator, io: std.Io) void {
        self.base_dir.deleteTree(io, self.dir_name) catch {};
        if (self.base_dir_owned) self.base_dir.close(io);
        allocator.free(self.dir_name);
        allocator.free(self.helper_path);
        allocator.free(self.username_path);
        allocator.free(self.password_path);
        self.* = undefined;
    }
};

// Keep the helper fail-closed: unknown prompt strings must not receive the
// password/token. Prefix matching also avoids treating "Password for
// 'https://myusername@host'" as a username prompt.
const askpass_helper_script =
    \\#!/bin/sh
    \\case "$1" in
    \\  Username*|username*) cat "$GITFRAME_ASKPASS_USERNAME_FILE" ;;
    \\  Password*|password*) cat "$GITFRAME_ASKPASS_PASSWORD_FILE" ;;
    \\  *) exit 1 ;;
    \\esac
    \\
;

fn setupAskpass(allocator: std.mem.Allocator, io: std.Io, parent_env: ?*const std.process.Environ.Map, credentials: PushCredentials) LoadError!AskpassSetup {
    // Prefer XDG_RUNTIME_DIR because it is normally user-private and often
    // tmpfs-backed. Fall back to /tmp for non-conforming or unavailable values,
    // but still create a 0700 per-attempt directory before writing secrets.
    const configured_base_path = if (parent_env) |env| env.get("XDG_RUNTIME_DIR") orelse "/tmp" else "/tmp";
    const base_path = if (std.fs.path.isAbsolute(configured_base_path)) configured_base_path else "/tmp";
    var actual_base_path = base_path;
    var base_dir = std.Io.Dir.openDirAbsolute(io, base_path, .{}) catch blk: {
        actual_base_path = "/tmp";
        break :blk std.Io.Dir.openDirAbsolute(io, "/tmp", .{}) catch return error.SpawnFailed;
    };
    var base_dir_owned = true;
    errdefer if (base_dir_owned) base_dir.close(io);

    const now = std.Io.Clock.now(.awake, io).nanoseconds;
    const dir_name = std.fmt.allocPrint(allocator, "gitframe-askpass-{d}", .{now}) catch return error.OutOfMemory;
    errdefer allocator.free(dir_name);

    base_dir.createDir(io, dir_name, .fromMode(0o700)) catch return error.SpawnFailed;
    errdefer base_dir.deleteTree(io, dir_name) catch {};

    var temp_dir = base_dir.openDir(io, dir_name, .{}) catch return error.SpawnFailed;
    defer temp_dir.close(io);

    // Git askpass takes credentials via a program callback. Store the actual
    // secret bytes in 0600 files and pass only paths through the environment so
    // the token does not appear in argv, remote URLs, or environment values.
    try writeAskpassFile(io, temp_dir, "username", credentials.username, .fromMode(0o600));
    try writeAskpassFile(io, temp_dir, "password", credentials.password, .fromMode(0o600));
    try writeAskpassFile(io, temp_dir, "askpass.sh", askpass_helper_script, .fromMode(0o700));

    const helper_path = std.fmt.allocPrint(allocator, "{s}/{s}/askpass.sh", .{ actual_base_path, dir_name }) catch return error.OutOfMemory;
    errdefer allocator.free(helper_path);
    const username_path = std.fmt.allocPrint(allocator, "{s}/{s}/username", .{ actual_base_path, dir_name }) catch return error.OutOfMemory;
    errdefer allocator.free(username_path);
    const password_path = std.fmt.allocPrint(allocator, "{s}/{s}/password", .{ actual_base_path, dir_name }) catch return error.OutOfMemory;
    errdefer allocator.free(password_path);

    base_dir_owned = false;
    return .{
        .base_dir = base_dir,
        .base_dir_owned = true,
        .dir_name = dir_name,
        .helper_path = helper_path,
        .username_path = username_path,
        .password_path = password_path,
    };
}

fn writeAskpassFile(io: std.Io, dir: std.Io.Dir, name: []const u8, contents: []const u8, permissions: std.Io.File.Permissions) LoadError!void {
    var file = dir.createFile(io, name, .{ .exclusive = true, .permissions = permissions }) catch return error.SpawnFailed;
    defer file.close(io);
    file.writeStreamingAll(io, contents) catch return error.SpawnFailed;
}

fn runGitPush(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, parent_env: ?*const std.process.Environ.Map, request: PushRequest) LoadError!OperationResult {
    if (!try verifyRemoteBranchSnapshot(allocator, io, repo_root, request.branch, request.oid)) {
        return .{ .failed_static = "Branch changed before push; reload and try again" };
    }
    if (remoteEnvironmentRejectedInteractiveSsh(parent_env)) {
        return .{ .failed_static = "Push requires non-interactive SSH; remove BatchMode=no from GIT_SSH_COMMAND" };
    }

    var env = remoteOperationEnvironment(allocator, parent_env) catch |err| switch (err) {
        error.InteractiveSshCommand => return .{ .failed_static = "Push requires non-interactive SSH; remove BatchMode=no from GIT_SSH_COMMAND" },
        error.OutOfMemory => return error.OutOfMemory,
        error.SpawnFailed => return error.SpawnFailed,
        error.StreamTooLong => return error.StreamTooLong,
    };
    defer env.deinit();

    var askpass = if (request.credentials) |credentials| try setupAskpass(allocator, io, parent_env, credentials) else null;
    defer if (askpass) |*setup| setup.deinit(allocator, io);
    if (askpass) |setup| {
        env.put("GIT_ASKPASS", setup.helper_path) catch return error.OutOfMemory;
        env.put("GITFRAME_ASKPASS_USERNAME_FILE", setup.username_path) catch return error.OutOfMemory;
        env.put("GITFRAME_ASKPASS_PASSWORD_FILE", setup.password_path) catch return error.OutOfMemory;
    }

    const refspec = std.fmt.allocPrint(allocator, "refs/heads/{s}:refs/heads/{s}", .{ request.branch, request.remote_branch }) catch return error.OutOfMemory;
    defer allocator.free(refspec);

    const argv_upstream = [_][]const u8{ "git", "push", request.remote, refspec };
    const argv_set_upstream = [_][]const u8{ "git", "push", "--set-upstream", request.remote, refspec };
    const argv: []const []const u8 = switch (request.mode) {
        .upstream => &argv_upstream,
        .set_upstream => &argv_set_upstream,
    };
    const result = std.process.run(allocator, io, .{
        .argv = argv,
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

fn runGitPullRefresh(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, parent_env: ?*const std.process.Environ.Map, request: PullRequest) LoadError!OperationResult {
    if (!try verifyRemoteBranchSnapshot(allocator, io, repo_root, request.branch, request.oid)) {
        return .{ .failed_static = "Branch changed before pull; reload and try again" };
    }
    if (!try verifyConfirmedUpstream(allocator, io, repo_root, request.remote, request.remote_branch)) {
        return .{ .failed_static = "Upstream changed before pull; reload and try again" };
    }
    if (!try verifyCleanWorktree(allocator, io, repo_root)) {
        return .{ .failed_static = "Worktree changed before pull; reload and resolve local changes first" };
    }
    if (remoteEnvironmentRejectedInteractiveSsh(parent_env)) {
        return .{ .failed_static = "Pull requires non-interactive SSH; remove BatchMode=no from GIT_SSH_COMMAND" };
    }

    var env = remoteOperationEnvironment(allocator, parent_env) catch |err| switch (err) {
        error.InteractiveSshCommand => return .{ .failed_static = "Pull requires non-interactive SSH; remove BatchMode=no from GIT_SSH_COMMAND" },
        error.OutOfMemory => return error.OutOfMemory,
        error.SpawnFailed => return error.SpawnFailed,
        error.StreamTooLong => return error.StreamTooLong,
    };
    defer env.deinit();

    const fetch_argv = [_][]const u8{ "git", "fetch", request.remote };
    const fetch_result = std.process.run(allocator, io, .{
        .argv = &fetch_argv,
        .cwd = .{ .path = repo_root },
        .environ_map = &env,
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(256 * 1024),
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.StreamTooLong,
        else => error.SpawnFailed,
    };

    allocator.free(fetch_result.stdout);
    switch (fetch_result.term) {
        .exited => |code| if (code == 0) {
            allocator.free(fetch_result.stderr);
        } else {
            if (fetch_result.stderr.len > 0) return .{ .failed = fetch_result.stderr };
            allocator.free(fetch_result.stderr);
            return .{ .failed = std.fmt.allocPrint(allocator, "git fetch failed: {any}", .{fetch_result.term}) catch return error.OutOfMemory };
        },
        else => {
            if (fetch_result.stderr.len > 0) return .{ .failed = fetch_result.stderr };
            allocator.free(fetch_result.stderr);
            return .{ .failed = std.fmt.allocPrint(allocator, "git fetch failed: {any}", .{fetch_result.term}) catch return error.OutOfMemory };
        },
    }

    // Fetch can take long enough for local state or branch config to change.
    // Re-check the confirmed identity before deciding whether to fast-forward.
    if (!try verifyRemoteBranchSnapshot(allocator, io, repo_root, request.branch, request.oid)) {
        return .{ .failed_static = "Branch changed before pull; reload and try again" };
    }
    if (!try verifyConfirmedUpstream(allocator, io, repo_root, request.remote, request.remote_branch)) {
        return .{ .failed_static = "Upstream changed before pull; reload and try again" };
    }
    if (!try verifyCleanWorktree(allocator, io, repo_root)) {
        return .{ .failed_static = "Worktree changed before pull; reload and resolve local changes first" };
    }

    const remote_ref = try confirmedRemoteTrackingRef(allocator, request.remote, request.remote_branch);
    defer allocator.free(remote_ref);
    const ahead_behind = try explicitAheadBehind(allocator, io, repo_root, remote_ref);
    if (ahead_behind.ahead == 0 and ahead_behind.behind == 0) return .{ .ok_static = "nothing to pull" };
    if (ahead_behind.ahead > 0 and ahead_behind.behind == 0) {
        return .{ .failed_static = "local commits are ahead; push or resolve outside GitFrame" };
    }
    if (ahead_behind.ahead > 0 and ahead_behind.behind > 0) {
        return .{ .failed_static = "branch has diverged; merge or rebase outside GitFrame" };
    }

    const merge_argv = [_][]const u8{ "git", "merge", "--ff-only", remote_ref };
    const merge_result = std.process.run(allocator, io, .{
        .argv = &merge_argv,
        .cwd = .{ .path = repo_root },
        .environ_map = &env,
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(256 * 1024),
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.StreamTooLong,
        else => error.SpawnFailed,
    };

    allocator.free(merge_result.stdout);
    switch (merge_result.term) {
        .exited => |code| if (code == 0) {
            allocator.free(merge_result.stderr);
            return .ok;
        },
        else => {},
    }

    if (merge_result.stderr.len > 0) return .{ .failed = merge_result.stderr };
    allocator.free(merge_result.stderr);
    return .{ .failed = std.fmt.allocPrint(allocator, "git merge --ff-only failed: {any}", .{merge_result.term}) catch return error.OutOfMemory };
}

fn runGitFetch(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, parent_env: ?*const std.process.Environ.Map, request: FetchRequest) LoadError!OperationResult {
    // Background fetch must never take over the terminal for credentials. Keep
    // it on the same non-interactive remote path as pull/push, and reject an
    // explicit BatchMode=no override before spawning git.
    if (remoteEnvironmentRejectedInteractiveSsh(parent_env)) {
        return .{ .failed_static = "Fetch requires non-interactive SSH; remove BatchMode=no from GIT_SSH_COMMAND" };
    }

    var env = remoteOperationEnvironment(allocator, parent_env) catch |err| switch (err) {
        error.InteractiveSshCommand => return .{ .failed_static = "Fetch requires non-interactive SSH; remove BatchMode=no from GIT_SSH_COMMAND" },
        error.OutOfMemory => return error.OutOfMemory,
        error.SpawnFailed => return error.SpawnFailed,
        error.StreamTooLong => return error.StreamTooLong,
    };
    defer env.deinit();

    const argv = [_][]const u8{ "git", "fetch", request.remote };
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

    if (result.stderr.len > 0) return .{ .failed = result.stderr };
    allocator.free(result.stderr);
    return .{ .failed = std.fmt.allocPrint(allocator, "git fetch failed: {any}", .{result.term}) catch return error.OutOfMemory };
}

fn runGitSwitchBranch(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, request: SwitchBranchRequest) LoadError!OperationResult {
    if (!try verifyRemoteBranchSnapshot(allocator, io, repo_root, request.expected_branch, request.expected_oid)) {
        return .{ .failed_static = "Branch changed before switch; reload and try again" };
    }
    if (!try verifyBranchOid(allocator, io, repo_root, request.target_branch, request.target_oid)) {
        return .{ .failed_static = "branch list changed; reopen branch switch and try again" };
    }
    if (!try verifyCleanWorktree(allocator, io, repo_root)) {
        return .{ .failed_static = "Worktree changed before branch switch; reload and resolve local changes first" };
    }

    const argv = [_][]const u8{ "git", "switch", "--no-guess", request.target_branch };
    const result = std.process.run(allocator, io, .{
        .argv = &argv,
        .cwd = .{ .path = repo_root },
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

    if (result.stderr.len > 0) return .{ .failed = result.stderr };
    allocator.free(result.stderr);
    return .{ .failed = std.fmt.allocPrint(allocator, "git switch failed: {any}", .{result.term}) catch return error.OutOfMemory };
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
    // `env` is the effective push environment: remoteOperationEnvironment mutates Git
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

fn verifyRemoteBranchSnapshot(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, branch: []const u8, oid: []const u8) LoadError!bool {
    const branch_argv = [_][]const u8{ "git", "symbolic-ref", "--quiet", "--short", "HEAD" };
    const branch_result = try runGitBranchStatusCommand(allocator, io, repo_root, &branch_argv);
    defer branch_result.deinit(allocator);
    switch (branch_result.term) {
        .exited => |code| if (code != 0) return false,
        else => return false,
    }
    if (!std.mem.eql(u8, trimLineEnd(branch_result.stdout), branch)) return false;

    const oid_argv = [_][]const u8{ "git", "rev-parse", "--verify", "HEAD" };
    const oid_result = try runGitBranchStatusCommand(allocator, io, repo_root, &oid_argv);
    defer oid_result.deinit(allocator);
    switch (oid_result.term) {
        .exited => |code| if (code != 0) return false,
        else => return false,
    }
    return std.mem.eql(u8, trimLineEnd(oid_result.stdout), oid);
}

fn verifyBranchOid(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, branch: []const u8, oid: []const u8) LoadError!bool {
    const ref = std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch}) catch return error.OutOfMemory;
    defer allocator.free(ref);
    const argv = [_][]const u8{ "git", "rev-parse", "--verify", ref };
    const result = try runGitBranchStatusCommand(allocator, io, repo_root, &argv);
    defer result.deinit(allocator);
    switch (result.term) {
        .exited => |code| if (code != 0) return false,
        else => return false,
    }
    return std.mem.eql(u8, trimLineEnd(result.stdout), oid);
}

fn verifyConfirmedUpstream(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, remote: []const u8, remote_branch: []const u8) LoadError!bool {
    const upstream_argv = [_][]const u8{ "git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}" };
    const upstream_result = try runGitBranchStatusCommand(allocator, io, repo_root, &upstream_argv);
    defer upstream_result.deinit(allocator);
    switch (upstream_result.term) {
        .exited => |code| if (code != 0) return false,
        else => return false,
    }
    var builder = git_branch_status.Builder.init(allocator);
    defer builder.deinit();
    builder.setUpstream(trimLineEnd(upstream_result.stdout)) catch return error.OutOfMemory;
    var bundle = builder.finish();
    defer bundle.deinit();
    const upstream = bundle.status.upstream orelse return false;
    return std.mem.eql(u8, upstream.remote, remote) and std.mem.eql(u8, upstream.remote_branch, remote_branch);
}

fn confirmedRemoteTrackingRef(allocator: std.mem.Allocator, remote: []const u8, remote_branch: []const u8) LoadError![]u8 {
    return std.fmt.allocPrint(allocator, "refs/remotes/{s}/{s}", .{ remote, remote_branch }) catch return error.OutOfMemory;
}

fn explicitAheadBehind(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, remote_ref: []const u8) LoadError!RevListAheadBehind {
    const spec = std.fmt.allocPrint(allocator, "HEAD...{s}", .{remote_ref}) catch return error.OutOfMemory;
    defer allocator.free(spec);
    const argv = [_][]const u8{ "git", "rev-list", "--left-right", "--count", spec };
    const result = try runGitBranchStatusCommand(allocator, io, repo_root, &argv);
    defer result.deinit(allocator);
    switch (result.term) {
        .exited => |code| if (code == 0) return parseRevListAheadBehind(result.stdout),
        else => {},
    }
    return error.SpawnFailed;
}

fn verifyCleanWorktree(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8) LoadError!bool {
    // Include untracked files to enforce the "clean worktree only" contract.
    // This is stricter than Git's overwrite protection, but avoids a
    // review action starting from a workspace state GitFrame no longer shows.
    const status_argv = [_][]const u8{ "git", "status", "--porcelain=v1", "-z", "-uall" };
    const status_result = try runGitBranchStatusCommand(allocator, io, repo_root, &status_argv);
    defer status_result.deinit(allocator);
    switch (status_result.term) {
        .exited => |code| if (code != 0) return false,
        else => return false,
    }
    return status_result.stdout.len == 0;
}

const PushEnvironmentError = LoadError || error{InteractiveSshCommand};

fn remoteOperationEnvironment(allocator: std.mem.Allocator, parent_env: ?*const std.process.Environ.Map) PushEnvironmentError!std.process.Environ.Map {
    var env = if (parent_env) |map|
        map.clone(allocator) catch return error.OutOfMemory
    else
        std.process.Environ.Map.init(allocator);
    errdefer env.deinit();

    // Background remote operations run inside the TUI event loop. Disable Git
    // prompts and force SSH batch mode so credential/passphrase requests fail
    // instead of hanging the interface; reviewed foreground/credential paths
    // must opt in separately.
    env.put("GIT_TERMINAL_PROMPT", "0") catch return error.OutOfMemory;

    const existing_ssh = env.get("GIT_SSH_COMMAND");
    const ssh_command = if (existing_ssh) |value|
        switch (sshBatchModeState(value)) {
            .batch => allocator.dupe(u8, value) catch return error.OutOfMemory,
            .interactive => return error.InteractiveSshCommand,
            .unspecified => std.fmt.allocPrint(allocator, "{s} -o BatchMode=yes", .{value}) catch return error.OutOfMemory,
        }
    else
        allocator.dupe(u8, "ssh -o BatchMode=yes") catch return error.OutOfMemory;
    defer allocator.free(ssh_command);
    env.put("GIT_SSH_COMMAND", ssh_command) catch return error.OutOfMemory;

    return env;
}

fn remoteEnvironmentRejectedInteractiveSsh(parent_env: ?*const std.process.Environ.Map) bool {
    const env = parent_env orelse return false;
    const ssh_command = env.get("GIT_SSH_COMMAND") orelse return false;
    return sshBatchModeState(ssh_command) == .interactive;
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

test "OperationRequest represents supported operation inputs" {
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

test "concurrent stdin Git operation mapping keeps stderr on writer failure" {
    const stdout = try std.testing.allocator.dupe(u8, "ignored");
    const stderr = std.testing.allocator.dupe(u8, "error: corrupt patch at line 6\n") catch |err| {
        std.testing.allocator.free(stdout);
        return err;
    };

    const result = try operationResultFromGitStdinCommand(std.testing.allocator, .{
        .failed = .{ .stdin = .{
            .err = error.WriteFailed,
            .result = .{
                .term = .{ .exited = 128 },
                .stdout = stdout,
                .stderr = stderr,
            },
        } },
    }, "git apply --cached");
    defer result.deinit(std.testing.allocator);

    switch (result) {
        .failed => |message| try std.testing.expectEqualStrings("error: corrupt patch at line 6\n", message),
        else => return error.ExpectedGitDiagnosticFailure,
    }
}

test "concurrent stdin Git mapping keeps writer failure when child exits zero" {
    const stdout = try std.testing.allocator.dupe(u8, "ignored");
    const stderr = std.testing.allocator.dupe(u8, "") catch |err| {
        std.testing.allocator.free(stdout);
        return err;
    };

    var result = try operationResultFromGitStdinCommand(std.testing.allocator, .{
        .failed = .{ .stdin = .{
            .err = error.WriteFailed,
            .result = .{
                .term = .{ .exited = 0 },
                .stdout = stdout,
                .stderr = stderr,
            },
        } },
    }, "git apply --cached");
    defer result.deinit(std.testing.allocator);

    switch (result) {
        .failed => |message| {
            try std.testing.expect(std.mem.indexOf(u8, message, "failed during stdin") != null);
            try std.testing.expect(std.mem.indexOf(u8, message, "WriteFailed") != null);
            try std.testing.expect(std.mem.indexOf(u8, message, "exited = 0") != null);
        },
        else => return error.ExpectedGitStdinFailure,
    }
}

test "concurrent stdin Git mapping releases evidence when fallback allocation fails" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const allocator = failing_allocator.allocator();
    const stdout = try allocator.dupe(u8, "ignored");

    try std.testing.expectError(error.OutOfMemory, operationResultFromGitStdinCommand(allocator, .{
        .failed = .{ .stdin = .{
            .err = error.WriteFailed,
            .result = .{
                .term = .{ .exited = 0 },
                .stdout = stdout,
                .stderr = &.{},
            },
        } },
    }, "git apply --cached"));
}

test "concurrent stdin Git apply preserves malformed large patch diagnostic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, tmp.dir);
    const repo_root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(repo_root);

    const malformed_prefix =
        "diff --git a/file.txt b/file.txt\n" ++
        "new file mode 100644\n" ++
        "--- /dev/null\n" ++
        "+++ b/file.txt\n" ++
        "@@ -0,0 +1 @@\n" ++
        "missing-prefix\n";
    const patch = try std.testing.allocator.alloc(u8, 512 * 1024);
    defer std.testing.allocator.free(patch);
    @memcpy(patch[0..malformed_prefix.len], malformed_prefix);
    @memset(patch[malformed_prefix.len..], 'x');

    const result = try runGitApplyCached(std.testing.allocator, io, repo_root, patch);
    defer result.deinit(std.testing.allocator);

    switch (result) {
        .failed => |message| try std.testing.expect(std.mem.indexOf(u8, message, "corrupt patch") != null),
        else => return error.ExpectedGitDiagnosticFailure,
    }
}

test "remote operation environment disables interactive credential prompts" {
    var env = try remoteOperationEnvironment(std.testing.allocator, null);
    defer env.deinit();

    try std.testing.expectEqualStrings("0", env.get("GIT_TERMINAL_PROMPT").?);
    try std.testing.expectEqualStrings("ssh -o BatchMode=yes", env.get("GIT_SSH_COMMAND").?);
}

test "askpass helper returns only recognized prompts" {
    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    try parent.put("XDG_RUNTIME_DIR", "/tmp");

    var setup = try setupAskpass(std.testing.allocator, std.testing.io, &parent, .{
        .username = "user",
        .password = "token",
    });
    defer setup.deinit(std.testing.allocator, std.testing.io);

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("GITFRAME_ASKPASS_USERNAME_FILE", setup.username_path);
    try env.put("GITFRAME_ASKPASS_PASSWORD_FILE", setup.password_path);
    try std.testing.expect(!std.mem.eql(u8, env.get("GITFRAME_ASKPASS_PASSWORD_FILE").?, "token"));

    const username_result = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &[_][]const u8{ setup.helper_path, "Username for 'https://host':" },
        .environ_map = &env,
    });
    defer std.testing.allocator.free(username_result.stdout);
    defer std.testing.allocator.free(username_result.stderr);
    try std.testing.expectEqualStrings("user", username_result.stdout);

    const password_result = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &[_][]const u8{ setup.helper_path, "Password for 'https://host':" },
        .environ_map = &env,
    });
    defer std.testing.allocator.free(password_result.stdout);
    defer std.testing.allocator.free(password_result.stderr);
    try std.testing.expectEqualStrings("token", password_result.stdout);

    const password_with_username_result = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &[_][]const u8{ setup.helper_path, "Password for 'https://myusername@host':" },
        .environ_map = &env,
    });
    defer std.testing.allocator.free(password_with_username_result.stdout);
    defer std.testing.allocator.free(password_with_username_result.stderr);
    try std.testing.expectEqualStrings("token", password_with_username_result.stdout);

    const unknown_result = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &[_][]const u8{ setup.helper_path, "Proxy prompt:" },
        .environ_map = &env,
    });
    defer std.testing.allocator.free(unknown_result.stdout);
    defer std.testing.allocator.free(unknown_result.stderr);
    try std.testing.expectEqualStrings("", unknown_result.stdout);
    try std.testing.expect(unknown_result.term != .exited or unknown_result.term.exited != 0);
}

test "askpass setup falls back when XDG_RUNTIME_DIR is relative" {
    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    try parent.put("XDG_RUNTIME_DIR", "relative-runtime");

    var setup = try setupAskpass(std.testing.allocator, std.testing.io, &parent, .{
        .username = "user",
        .password = "token",
    });
    defer setup.deinit(std.testing.allocator, std.testing.io);

    try std.testing.expect(std.mem.startsWith(u8, setup.helper_path, "/tmp/"));
    try std.testing.expect(std.mem.startsWith(u8, setup.username_path, "/tmp/"));
    try std.testing.expect(std.mem.startsWith(u8, setup.password_path, "/tmp/"));
}

test "remote operation environment preserves existing ssh command while adding BatchMode" {
    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    try parent.put("GIT_SSH_COMMAND", "ssh -i /tmp/key");
    try parent.put("HOME", "/home/test");

    var env = try remoteOperationEnvironment(std.testing.allocator, &parent);
    defer env.deinit();

    try std.testing.expectEqualStrings("0", env.get("GIT_TERMINAL_PROMPT").?);
    try std.testing.expectEqualStrings("ssh -i /tmp/key -o BatchMode=yes", env.get("GIT_SSH_COMMAND").?);
    try std.testing.expectEqualStrings("/home/test", env.get("HOME").?);
}

test "remote operation environment preserves existing BatchMode yes and rejects BatchMode no" {
    var parent_yes = std.process.Environ.Map.init(std.testing.allocator);
    defer parent_yes.deinit();
    try parent_yes.put("GIT_SSH_COMMAND", "ssh -o BatchMode=yes -i /tmp/key");

    var env = try remoteOperationEnvironment(std.testing.allocator, &parent_yes);
    defer env.deinit();
    try std.testing.expectEqualStrings("ssh -o BatchMode=yes -i /tmp/key", env.get("GIT_SSH_COMMAND").?);

    var parent_no = std.process.Environ.Map.init(std.testing.allocator);
    defer parent_no.deinit();
    try parent_no.put("GIT_SSH_COMMAND", "ssh -o BatchMode=no -i /tmp/key");
    try std.testing.expectError(error.InteractiveSshCommand, remoteOperationEnvironment(std.testing.allocator, &parent_no));
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

    const result = try LocalCommandBackend.runOperation(std.testing.allocator, io, .{
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

    const result = try LocalCommandBackend.runOperation(std.testing.allocator, io, .{
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

    const result = try LocalCommandBackend.runOperation(std.testing.allocator, io, .{
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

    const config_result = try std.process.run(std.testing.allocator, io, .{
        .argv = &[_][]const u8{ "git", "config", "--get", "branch.main.remote" },
        .cwd = .{ .dir = work },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer freeRunResult(std.testing.allocator, config_result);
    try std.testing.expect(config_result.term == .exited and config_result.term.exited != 0);
}

test "LocalCommandBackend set-upstream push configures local branch upstream" {
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
    try runTestGit(io, &.{ "git", "switch", "-c", "feature/topic" }, work);
    try work.writeFile(io, .{ .sub_path = "FEATURE.md", .data = "feature\n" });
    try runTestGit(io, &.{ "git", "add", "FEATURE.md" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "feature" }, work);

    const oid = try gitOutputAlloc(io, work, &.{ "git", "rev-parse", "--verify", "HEAD" });
    defer std.testing.allocator.free(oid);

    const result = try LocalCommandBackend.runOperation(std.testing.allocator, io, .{
        .repo_root = repo_root,
        .kind = .{ .push = .{
            .mode = .set_upstream,
            .branch = "feature/topic",
            .remote = "origin",
            .remote_branch = "feature/topic",
            .oid = trimLineEnd(oid),
        } },
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(OperationResult.ok, result);

    const remote_oid = try gitOutputAlloc(io, work, &.{ "git", "rev-parse", "--verify", "refs/remotes/origin/feature/topic" });
    defer std.testing.allocator.free(remote_oid);
    try std.testing.expectEqualStrings(trimLineEnd(oid), trimLineEnd(remote_oid));

    const upstream_remote = try gitOutputAlloc(io, work, &.{ "git", "config", "--get", "branch.feature/topic.remote" });
    defer std.testing.allocator.free(upstream_remote);
    try std.testing.expectEqualStrings("origin", trimLineEnd(upstream_remote));

    const upstream_merge = try gitOutputAlloc(io, work, &.{ "git", "config", "--get", "branch.feature/topic.merge" });
    defer std.testing.allocator.free(upstream_merge);
    try std.testing.expectEqualStrings("refs/heads/feature/topic", trimLineEnd(upstream_merge));
}

test "LocalCommandBackend pull refresh fetches and fast-forwards from local bare remote" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const fixture = try setupPullRefreshFixture(io, &tmp);
    defer fixture.deinit();

    var updater = try tmp.dir.openDir(io, "updater", .{});
    defer updater.close(io);
    try updater.writeFile(io, .{ .sub_path = "README.md", .data = "updated\n" });
    try runTestGit(io, &.{ "git", "add", "README.md" }, updater);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "update" }, updater);
    try runTestGit(io, &.{ "git", "push", "origin", "main" }, updater);

    const result = try LocalCommandBackend.runOperation(std.testing.allocator, io, .{
        .repo_root = fixture.repo_root,
        .kind = .{ .pull_refresh_ff_only = .{
            .branch = "main",
            .remote = "origin",
            .remote_branch = "main",
            .oid = fixture.oid,
        } },
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(OperationResult.ok, result);

    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    const head = try gitOutputAlloc(io, work, &.{ "git", "rev-parse", "HEAD" });
    defer std.testing.allocator.free(head);
    const remote = try gitOutputAlloc(io, work, &.{ "git", "rev-parse", "refs/remotes/origin/main" });
    defer std.testing.allocator.free(remote);
    try std.testing.expectEqualStrings(trimLineEnd(remote), trimLineEnd(head));
}

test "LocalCommandBackend pull refresh reports nothing to pull as success" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const fixture = try setupPullRefreshFixture(io, &tmp);
    defer fixture.deinit();

    const result = try LocalCommandBackend.runOperation(std.testing.allocator, io, .{
        .repo_root = fixture.repo_root,
        .kind = .{ .pull_refresh_ff_only = .{
            .branch = "main",
            .remote = "origin",
            .remote_branch = "main",
            .oid = fixture.oid,
        } },
    });
    defer result.deinit(std.testing.allocator);

    switch (result) {
        .ok_static => |message| try std.testing.expectEqualStrings("nothing to pull", message),
        else => return error.ExpectedPullRefreshNoop,
    }
}

test "LocalCommandBackend pull refresh rejects stale oid before fetch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const fixture = try setupPullRefreshFixture(io, &tmp);
    defer fixture.deinit();

    const result = try LocalCommandBackend.runOperation(std.testing.allocator, io, .{
        .repo_root = fixture.repo_root,
        .kind = .{ .pull_refresh_ff_only = .{
            .branch = "main",
            .remote = "origin",
            .remote_branch = "main",
            .oid = "not-the-current-oid",
        } },
    });
    defer result.deinit(std.testing.allocator);

    switch (result) {
        .failed_static => |message| try std.testing.expectEqualStrings("Branch changed before pull; reload and try again", message),
        else => return error.ExpectedPullRefreshStaleOidFailure,
    }
}

test "LocalCommandBackend pull refresh rejects local commits ahead" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    var fixture = try setupPullRefreshFixture(io, &tmp);
    defer fixture.deinit();

    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try work.writeFile(io, .{ .sub_path = "LOCAL.md", .data = "local\n" });
    try runTestGit(io, &.{ "git", "add", "LOCAL.md" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "local" }, work);
    std.testing.allocator.free(fixture.oid);
    const local_oid = try gitOutputAlloc(io, work, &.{ "git", "rev-parse", "--verify", "HEAD" });
    fixture.oid = try std.testing.allocator.dupe(u8, trimLineEnd(local_oid));
    std.testing.allocator.free(local_oid);

    const result = try LocalCommandBackend.runOperation(std.testing.allocator, io, .{
        .repo_root = fixture.repo_root,
        .kind = .{ .pull_refresh_ff_only = .{
            .branch = "main",
            .remote = "origin",
            .remote_branch = "main",
            .oid = fixture.oid,
        } },
    });
    defer result.deinit(std.testing.allocator);

    switch (result) {
        .failed_static => |message| try std.testing.expectEqualStrings("local commits are ahead; push or resolve outside GitFrame", message),
        else => return error.ExpectedPullRefreshAheadFailure,
    }
}

test "LocalCommandBackend pull refresh rejects diverged branch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    var fixture = try setupPullRefreshFixture(io, &tmp);
    defer fixture.deinit();

    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try work.writeFile(io, .{ .sub_path = "LOCAL.md", .data = "local\n" });
    try runTestGit(io, &.{ "git", "add", "LOCAL.md" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "local" }, work);
    std.testing.allocator.free(fixture.oid);
    const local_oid = try gitOutputAlloc(io, work, &.{ "git", "rev-parse", "--verify", "HEAD" });
    fixture.oid = try std.testing.allocator.dupe(u8, trimLineEnd(local_oid));
    std.testing.allocator.free(local_oid);

    var updater = try tmp.dir.openDir(io, "updater", .{});
    defer updater.close(io);
    try updater.writeFile(io, .{ .sub_path = "REMOTE.md", .data = "remote\n" });
    try runTestGit(io, &.{ "git", "add", "REMOTE.md" }, updater);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "remote" }, updater);
    try runTestGit(io, &.{ "git", "push", "origin", "main" }, updater);

    const result = try LocalCommandBackend.runOperation(std.testing.allocator, io, .{
        .repo_root = fixture.repo_root,
        .kind = .{ .pull_refresh_ff_only = .{
            .branch = "main",
            .remote = "origin",
            .remote_branch = "main",
            .oid = fixture.oid,
        } },
    });
    defer result.deinit(std.testing.allocator);

    switch (result) {
        .failed_static => |message| try std.testing.expectEqualStrings("branch has diverged; merge or rebase outside GitFrame", message),
        else => return error.ExpectedPullRefreshDivergedFailure,
    }
}

test "LocalCommandBackend pull refresh rejects changed upstream" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const fixture = try setupPullRefreshFixture(io, &tmp);
    defer fixture.deinit();

    try runTestGit(io, &.{ "git", "init", "--bare", "other.git" }, tmp.dir);
    const other_root = try tmp.dir.realPathFileAlloc(io, "other.git", std.testing.allocator);
    defer std.testing.allocator.free(other_root);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "remote", "add", "other", other_root }, work);
    try runTestGit(io, &.{ "git", "push", "-u", "other", "main" }, work);

    const result = try LocalCommandBackend.runOperation(std.testing.allocator, io, .{
        .repo_root = fixture.repo_root,
        .kind = .{ .pull_refresh_ff_only = .{
            .branch = "main",
            .remote = "origin",
            .remote_branch = "main",
            .oid = fixture.oid,
        } },
    });
    defer result.deinit(std.testing.allocator);

    switch (result) {
        .failed_static => |message| try std.testing.expectEqualStrings("Upstream changed before pull; reload and try again", message),
        else => return error.ExpectedPullRefreshUpstreamChangedFailure,
    }
}

test "LocalCommandBackend pull refresh rejects dirty worktree before fetch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const fixture = try setupPullRefreshFixture(io, &tmp);
    defer fixture.deinit();

    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try work.writeFile(io, .{ .sub_path = "README.md", .data = "local change\n" });

    const result = try LocalCommandBackend.runOperation(std.testing.allocator, io, .{
        .repo_root = fixture.repo_root,
        .kind = .{ .pull_refresh_ff_only = .{
            .branch = "main",
            .remote = "origin",
            .remote_branch = "main",
            .oid = fixture.oid,
        } },
    });
    defer result.deinit(std.testing.allocator);

    switch (result) {
        .failed_static => |message| try std.testing.expectEqualStrings("Worktree changed before pull; reload and resolve local changes first", message),
        else => return error.ExpectedPullRefreshDirtyFailure,
    }
}

test "LocalCommandBackend pull refresh rejects untracked worktree before fetch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const fixture = try setupPullRefreshFixture(io, &tmp);
    defer fixture.deinit();

    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try work.writeFile(io, .{ .sub_path = "new.txt", .data = "untracked\n" });

    const result = try LocalCommandBackend.runOperation(std.testing.allocator, io, .{
        .repo_root = fixture.repo_root,
        .kind = .{ .pull_refresh_ff_only = .{
            .branch = "main",
            .remote = "origin",
            .remote_branch = "main",
            .oid = fixture.oid,
        } },
    });
    defer result.deinit(std.testing.allocator);

    switch (result) {
        .failed_static => |message| try std.testing.expectEqualStrings("Worktree changed before pull; reload and resolve local changes first", message),
        else => return error.ExpectedPullRefreshUntrackedFailure,
    }
}

test "LocalCommandBackend pull refresh rejects interactive ssh command" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const fixture = try setupPullRefreshFixture(io, &tmp);
    defer fixture.deinit();

    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    try parent.put("GIT_SSH_COMMAND", "ssh -o BatchMode=no -i /tmp/key");

    const result = try LocalCommandBackend.runOperation(std.testing.allocator, io, .{
        .repo_root = fixture.repo_root,
        .kind = .{ .pull_refresh_ff_only = .{
            .branch = "main",
            .remote = "origin",
            .remote_branch = "main",
            .oid = fixture.oid,
        } },
        .env_map = &parent,
    });
    defer result.deinit(std.testing.allocator);

    switch (result) {
        .failed_static => |message| try std.testing.expectEqualStrings("Pull requires non-interactive SSH; remove BatchMode=no from GIT_SSH_COMMAND", message),
        else => return error.ExpectedInteractiveSshPullRefreshFailure,
    }
}

test "LocalCommandBackend fetch rejects interactive ssh command" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const repo = try setupPullWorkRepoForTest(io, &tmp);
    defer std.testing.allocator.free(repo.repo_root);
    defer std.testing.allocator.free(repo.oid);

    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    try parent.put("GIT_SSH_COMMAND", "ssh -o BatchMode=no -i /tmp/key");

    const result = try LocalCommandBackend.runOperation(std.testing.allocator, io, .{
        .repo_root = repo.repo_root,
        .kind = .{ .fetch = .{ .remote = "missing" } },
        .env_map = &parent,
    });
    defer result.deinit(std.testing.allocator);

    switch (result) {
        .failed_static => |message| try std.testing.expectEqualStrings("Fetch requires non-interactive SSH; remove BatchMode=no from GIT_SSH_COMMAND", message),
        else => return error.ExpectedInteractiveSshFetchFailure,
    }
}

test "LocalCommandBackend fetch updates remote tracking refs from local bare remote" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try runTestGit(io, &.{ "git", "init", "--bare", "remote.git" }, tmp.dir);
    try tmp.dir.createDir(io, "work", .default_dir);
    try tmp.dir.createDir(io, "updater", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    var updater = try tmp.dir.openDir(io, "updater", .{});
    defer updater.close(io);

    const remote_root = try tmp.dir.realPathFileAlloc(io, "remote.git", std.testing.allocator);
    defer std.testing.allocator.free(remote_root);
    const repo_root = try tmp.dir.realPathFileAlloc(io, "work", std.testing.allocator);
    defer std.testing.allocator.free(repo_root);

    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try runTestGit(io, &.{ "git", "remote", "add", "origin", remote_root }, work);
    try work.writeFile(io, .{ .sub_path = "README.md", .data = "initial\n" });
    try runTestGit(io, &.{ "git", "add", "README.md" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "initial" }, work);
    try runTestGit(io, &.{ "git", "push", "origin", "main" }, work);
    try runTestGit(io, &.{ "git", "fetch", "origin" }, work);
    const before = try gitOutputAlloc(io, work, &.{ "git", "rev-parse", "refs/remotes/origin/main" });
    defer std.testing.allocator.free(before);

    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, updater);
    try runTestGit(io, &.{ "git", "remote", "add", "origin", remote_root }, updater);
    try runTestGit(io, &.{ "git", "pull", "--ff-only", "origin", "main" }, updater);
    try updater.writeFile(io, .{ .sub_path = "README.md", .data = "updated\n" });
    try runTestGit(io, &.{ "git", "add", "README.md" }, updater);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "update" }, updater);
    try runTestGit(io, &.{ "git", "push", "origin", "main" }, updater);

    const result = try LocalCommandBackend.runOperation(std.testing.allocator, io, .{
        .repo_root = repo_root,
        .kind = .{ .fetch = .{ .remote = "origin" } },
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(OperationResult.ok, result);

    const after = try gitOutputAlloc(io, work, &.{ "git", "rev-parse", "refs/remotes/origin/main" });
    defer std.testing.allocator.free(after);
    const remote = try gitOutputAlloc(io, work, &.{ "git", "ls-remote", "origin", "refs/heads/main" });
    defer std.testing.allocator.free(remote);

    try std.testing.expect(!std.mem.eql(u8, trimLineEnd(before), trimLineEnd(after)));
    try std.testing.expect(std.mem.indexOf(u8, remote, trimLineEnd(after)) != null);
}

test "LocalCommandBackend loads local branch list without record separator newlines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const fixture = try setupBranchSwitchFixture(io, &tmp);
    defer fixture.deinit();

    const result = try LocalCommandBackend.loadBranchList(std.testing.allocator, io, .{
        .cwd = .{ .path = fixture.repo_root },
        .environment = .inherited,
        .scope = .local,
    });
    defer result.deinit(std.testing.allocator);

    const list = switch (result) {
        .ok => |list| list,
        .failed, .failed_static => return error.ExpectedBranchList,
    };
    try std.testing.expectEqualStrings("main", list.current.?);
    try expectBranchListed(list.branches, "main");
    try expectBranchListed(list.branches, "feature/topic");
    try expectBranchNotListed(list.branches, "origin/remote-only");
    const main = branchByFullRef(list.branches, "refs/heads/main") orelse return error.ExpectedBranchListed;
    try std.testing.expectEqual(BranchKind.local, main.kind);
    try std.testing.expect(main.current);
    for (list.branches) |branch| {
        try std.testing.expect(std.mem.indexOfScalar(u8, branch.name, '\n') == null);
        try std.testing.expect(std.mem.indexOfScalar(u8, branch.name, '\r') == null);
    }
}

test "LocalCommandBackend loads distinct local and remote refs and excludes every remote HEAD symref" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const fixture = try setupBranchSwitchFixture(io, &tmp);
    defer fixture.deinit();
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);

    try runTestGit(io, &.{ "git", "config", "core.warnAmbiguousRefs", "true" }, work);
    try runTestGit(io, &.{ "git", "branch", "origin/main", "main" }, work);
    try runTestGit(io, &.{ "git", "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main" }, work);
    try runTestGit(io, &.{ "git", "update-ref", "refs/remotes/upstream/main", fixture.main_oid }, work);
    try runTestGit(io, &.{ "git", "symbolic-ref", "refs/remotes/upstream/HEAD", "refs/remotes/upstream/main" }, work);

    const result = try LocalCommandBackend.loadBranchList(std.testing.allocator, io, .{
        .cwd = .{ .path = fixture.repo_root },
        .environment = .inherited,
        .scope = .local_and_remote,
    });
    defer result.deinit(std.testing.allocator);

    const list = switch (result) {
        .ok => |list| list,
        .failed, .failed_static => return error.ExpectedBranchList,
    };
    const local_collision = branchByFullRef(list.branches, "refs/heads/origin/main") orelse
        return error.ExpectedBranchListed;
    const remote_collision = branchByFullRef(list.branches, "refs/remotes/origin/main") orelse
        return error.ExpectedBranchListed;
    const remote_only = branchByFullRef(list.branches, "refs/remotes/origin/remote-only") orelse
        return error.ExpectedBranchListed;
    const current = branchByFullRef(list.branches, "refs/heads/main") orelse
        return error.ExpectedBranchListed;

    try std.testing.expectEqualStrings("heads/origin/main", local_collision.name);
    try std.testing.expectEqualStrings("remotes/origin/main", remote_collision.name);
    try std.testing.expectEqual(BranchKind.local, local_collision.kind);
    try std.testing.expectEqual(BranchKind.remote_tracking, remote_collision.kind);
    try std.testing.expectEqual(BranchKind.remote_tracking, remote_only.kind);
    try std.testing.expectEqualStrings(fixture.main_oid, local_collision.oid);
    try std.testing.expectEqualStrings(fixture.main_oid, remote_collision.oid);
    try std.testing.expect(current.current);
    try std.testing.expect(!remote_collision.current);
    try std.testing.expect(branchByFullRef(list.branches, "refs/remotes/origin/HEAD") == null);
    try std.testing.expect(branchByFullRef(list.branches, "refs/remotes/upstream/HEAD") == null);
}

test "LocalCommandBackend loads a local and remote branch list larger than four KiB" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const fixture = try setupBranchSwitchFixture(io, &tmp);
    defer fixture.deinit();
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);

    const remote_ref_count = 80;
    var ref_buffer: [160]u8 = undefined;
    for (0..remote_ref_count) |index| {
        const full_ref = try std.fmt.bufPrint(
            &ref_buffer,
            "refs/remotes/origin/feature-{d}-with-a-realistic-name-for-compare-picker",
            .{index},
        );
        try runTestGit(io, &.{ "git", "update-ref", full_ref, fixture.main_oid }, work);
    }
    try runTestGit(io, &.{ "git", "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main" }, work);

    const result = try LocalCommandBackend.loadBranchList(std.testing.allocator, io, .{
        .cwd = .{ .path = fixture.repo_root },
        .environment = .inherited,
        .scope = .local_and_remote,
    });
    defer result.deinit(std.testing.allocator);

    const list = switch (result) {
        .ok => |value| value,
        .failed, .failed_static => return error.ExpectedBranchList,
    };
    try std.testing.expect(list.branches.len >= remote_ref_count);
    for (0..remote_ref_count) |index| {
        const full_ref = try std.fmt.bufPrint(
            &ref_buffer,
            "refs/remotes/origin/feature-{d}-with-a-realistic-name-for-compare-picker",
            .{index},
        );
        const branch = branchByFullRef(list.branches, full_ref) orelse return error.ExpectedBranchListed;
        try std.testing.expectEqual(BranchKind.remote_tracking, branch.kind);
        try std.testing.expectEqualStrings(fixture.main_oid, branch.oid);
    }
    try std.testing.expect(branchByFullRef(list.branches, "refs/remotes/origin/HEAD") == null);
}

test "branch list reports StreamTooLong at its explicit bounded capacity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const fixture = try setupBranchSwitchFixture(io, &tmp);
    defer fixture.deinit();

    try std.testing.expectError(error.StreamTooLong, loadGitBranchListWithLimit(
        std.testing.allocator,
        io,
        .{
            .cwd = .{ .path = fixture.repo_root },
            .environment = .inherited,
            .scope = .local_and_remote,
        },
        .limited(1),
    ));
}

const SwapCompareRefsHookContext = struct {
    original_main_oid: []const u8,
    original_feature_oid: []const u8,

    fn run(ctx_ptr: *anyopaque, io: std.Io, cwd: std.Io.Dir) LoadError!void {
        const ctx: *@This() = @ptrCast(@alignCast(ctx_ptr));
        runTestGit(io, &.{ "git", "update-ref", "refs/heads/main", ctx.original_feature_oid }, cwd) catch
            return error.SpawnFailed;
        runTestGit(io, &.{ "git", "update-ref", "refs/heads/feature/topic", ctx.original_main_oid }, cwd) catch
            return error.SpawnFailed;
    }
};

test "Compare snapshot loads one oid-pinned committed branch diff" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const fixture = try setupBranchSwitchFixture(io, &tmp);
    defer fixture.deinit();
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "switch", "feature/topic" }, work);

    var result = try LocalCommandBackend.loadCompareSnapshot(std.testing.allocator, io, .{
        .cwd = work,
        .parent_env = null,
        .target = .{
            .full_ref = "refs/heads/main",
            .display_name = "main",
            .kind = .local,
        },
    });
    defer result.deinit(std.testing.allocator);

    const snapshot = switch (result) {
        .snapshot => |*snapshot| snapshot,
        else => return error.ExpectedCompareSnapshot,
    };
    try std.testing.expectEqualStrings("refs/heads/main", snapshot.target.full_ref);
    try std.testing.expectEqualStrings("main", snapshot.target.display_name);
    try std.testing.expectEqual(BranchKind.local, snapshot.target.kind);
    try std.testing.expectEqualStrings(fixture.main_oid, snapshot.base_oid);
    try std.testing.expectEqualStrings(fixture.feature_oid, snapshot.head_oid);
    try std.testing.expectEqualStrings(fixture.main_oid, snapshot.merge_base_oid);
    try std.testing.expectEqualStrings("feature/topic", snapshot.head_name.?);
    try std.testing.expectEqualStrings("1", snapshot.ahead_count);
    try std.testing.expect(std.mem.indexOf(u8, snapshot.diff, "FEATURE.md") != null);
    try std.testing.expect(std.mem.endsWith(u8, snapshot.diff, "\n"));
}

test "Compare snapshot default prefers origin HEAD and falls back to local main" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const fixture = try setupBranchSwitchFixture(io, &tmp);
    defer fixture.deinit();
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "switch", "feature/topic" }, work);

    var fallback = try LocalCommandBackend.loadCompareSnapshot(std.testing.allocator, io, .{
        .cwd = work,
        .parent_env = null,
        .target = null,
    });
    defer fallback.deinit(std.testing.allocator);
    switch (fallback) {
        .snapshot => |snapshot| {
            try std.testing.expectEqualStrings("refs/heads/main", snapshot.target.full_ref);
            try std.testing.expectEqualStrings("main", snapshot.target.display_name);
            try std.testing.expectEqual(BranchKind.local, snapshot.target.kind);
        },
        else => return error.ExpectedCompareSnapshot,
    }

    try runTestGit(io, &.{ "git", "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main" }, work);
    var preferred = try LocalCommandBackend.loadCompareSnapshot(std.testing.allocator, io, .{
        .cwd = work,
        .parent_env = null,
        .target = null,
    });
    defer preferred.deinit(std.testing.allocator);
    switch (preferred) {
        .snapshot => |snapshot| {
            try std.testing.expectEqualStrings("refs/remotes/origin/main", snapshot.target.full_ref);
            try std.testing.expectEqualStrings("origin/main", snapshot.target.display_name);
            try std.testing.expectEqual(BranchKind.remote_tracking, snapshot.target.kind);
        },
        else => return error.ExpectedCompareSnapshot,
    }
}

test "Compare snapshot default falls through local main to local master" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=master" }, work);
    try work.writeFile(io, .{ .sub_path = "BASE.md", .data = "base\n" });
    try runTestGit(io, &.{ "git", "add", "BASE.md" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" }, work);
    try runTestGit(io, &.{ "git", "switch", "-c", "feature" }, work);
    try work.writeFile(io, .{ .sub_path = "FEATURE.md", .data = "feature\n" });
    try runTestGit(io, &.{ "git", "add", "FEATURE.md" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "feature" }, work);

    var result = try LocalCommandBackend.loadCompareSnapshot(std.testing.allocator, io, .{
        .cwd = work,
        .parent_env = null,
        .target = null,
    });
    defer result.deinit(std.testing.allocator);
    switch (result) {
        .snapshot => |snapshot| {
            try std.testing.expectEqualStrings("refs/heads/master", snapshot.target.full_ref);
            try std.testing.expectEqualStrings("master", snapshot.target.display_name);
            try std.testing.expectEqual(BranchKind.local, snapshot.target.kind);
        },
        else => return error.ExpectedCompareSnapshot,
    }
}

test "Compare snapshot treats equal base and HEAD as a successful empty diff" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const fixture = try setupBranchSwitchFixture(io, &tmp);
    defer fixture.deinit();
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);

    var result = try LocalCommandBackend.loadCompareSnapshot(std.testing.allocator, io, .{
        .cwd = work,
        .parent_env = null,
        .target = .{
            .full_ref = "refs/heads/main",
            .display_name = "main",
            .kind = .local,
        },
    });
    defer result.deinit(std.testing.allocator);
    switch (result) {
        .snapshot => |snapshot| {
            try std.testing.expectEqualStrings(fixture.main_oid, snapshot.base_oid);
            try std.testing.expectEqualStrings(fixture.main_oid, snapshot.head_oid);
            try std.testing.expectEqualStrings("0", snapshot.ahead_count);
            try std.testing.expectEqual(@as(usize, 0), snapshot.diff.len);
        },
        else => return error.ExpectedCompareSnapshot,
    }
}

test "Compare snapshot reports an explicit missing base with attempted intent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const fixture = try setupBranchSwitchFixture(io, &tmp);
    defer fixture.deinit();
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);

    var result = try LocalCommandBackend.loadCompareSnapshot(std.testing.allocator, io, .{
        .cwd = work,
        .parent_env = null,
        .target = .{
            .full_ref = "refs/heads/missing",
            .display_name = "missing",
            .kind = .local,
        },
    });
    defer result.deinit(std.testing.allocator);
    switch (result) {
        .basis_failed => |failure| {
            try std.testing.expectEqual(CompareBasisFailure.missing_base_ref, failure.kind);
            try std.testing.expectEqualStrings("refs/heads/missing", failure.attempted.full_ref);
            try std.testing.expectEqualStrings("missing", failure.attempted.display_name);
        },
        else => return error.ExpectedMissingCompareBase,
    }
}

test "Compare snapshot separates Git process failure from a missing base" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try tmp.dir.createDir(io, "not-a-repository", .default_dir);
    var cwd = try tmp.dir.openDir(io, "not-a-repository", .{});
    defer cwd.close(io);
    // Prevent discovery of the source repository above std.testing.tmpDir.
    try cwd.writeFile(io, .{ .sub_path = ".git", .data = "invalid gitfile\n" });

    var result = try LocalCommandBackend.loadCompareSnapshot(std.testing.allocator, io, .{
        .cwd = cwd,
        .parent_env = null,
        .target = .{
            .full_ref = "refs/heads/main",
            .display_name = "main",
            .kind = .local,
        },
    });
    defer result.deinit(std.testing.allocator);
    switch (result) {
        .failed => |message| try std.testing.expect(std.mem.indexOf(u8, message, "invalid gitfile") != null),
        else => return error.ExpectedCompareProcessFailure,
    }
}

test "Compare snapshot keeps descriptor authority after path replacement and Git env injection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const fixture = try setupBranchSwitchFixture(io, &tmp);
    defer fixture.deinit();
    var pinned = try tmp.dir.openDir(io, "work", .{});
    defer pinned.close(io);
    try runTestGit(io, &.{ "git", "switch", "feature/topic" }, pinned);

    try tmp.dir.rename("work", tmp.dir, "pinned-work", io);
    try tmp.dir.createDir(io, "work", .default_dir);
    var replacement = try tmp.dir.openDir(io, "work", .{});
    defer replacement.close(io);
    try replacement.writeFile(io, .{ .sub_path = ".git", .data = "invalid replacement gitfile\n" });

    var injected_env = std.process.Environ.Map.init(std.testing.allocator);
    defer injected_env.deinit();
    try injected_env.put("GIT_DIR", "/definitely/not/the/pinned/repository");
    try injected_env.put("GIT_WORK_TREE", "/definitely/not/the/pinned/worktree");

    var result = try LocalCommandBackend.loadCompareSnapshot(std.testing.allocator, io, .{
        .cwd = pinned,
        .parent_env = &injected_env,
        .target = .{
            .full_ref = "refs/heads/main",
            .display_name = "main",
            .kind = .local,
        },
    });
    defer result.deinit(std.testing.allocator);
    switch (result) {
        .snapshot => |snapshot| {
            try std.testing.expectEqualStrings(fixture.main_oid, snapshot.base_oid);
            try std.testing.expectEqualStrings(fixture.feature_oid, snapshot.head_oid);
            try std.testing.expect(std.mem.indexOf(u8, snapshot.diff, "FEATURE.md") != null);
        },
        else => return error.ExpectedDescriptorAuthorizedCompareSnapshot,
    }
}

test "Compare snapshot keeps pinned endpoint oids when live refs move between phases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const fixture = try setupBranchSwitchFixture(io, &tmp);
    defer fixture.deinit();
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "switch", "feature/topic" }, work);

    var hook_context = SwapCompareRefsHookContext{
        .original_main_oid = fixture.main_oid,
        .original_feature_oid = fixture.feature_oid,
    };
    var hooks = CompareTestHooks{ .after_endpoints_pinned = .{
        .context = &hook_context,
        .run = SwapCompareRefsHookContext.run,
    } };
    var result = try loadGitCompareSnapshotWithHooks(std.testing.allocator, io, .{
        .cwd = work,
        .parent_env = null,
        .target = .{
            .full_ref = "refs/heads/main",
            .display_name = "main",
            .kind = .local,
        },
    }, &hooks);
    defer result.deinit(std.testing.allocator);

    const snapshot = switch (result) {
        .snapshot => |*snapshot| snapshot,
        else => return error.ExpectedCompareSnapshot,
    };
    try std.testing.expectEqualStrings(fixture.main_oid, snapshot.base_oid);
    try std.testing.expectEqualStrings(fixture.feature_oid, snapshot.head_oid);
    try std.testing.expectEqualStrings(fixture.main_oid, snapshot.merge_base_oid);
    try std.testing.expectEqualStrings("1", snapshot.ahead_count);
    try std.testing.expect(std.mem.indexOf(u8, snapshot.diff, "FEATURE.md") != null);

    const live_main = try gitOutputAlloc(io, work, &.{ "git", "rev-parse", "refs/heads/main" });
    defer std.testing.allocator.free(live_main);
    const live_feature = try gitOutputAlloc(io, work, &.{ "git", "rev-parse", "refs/heads/feature/topic" });
    defer std.testing.allocator.free(live_feature);
    try std.testing.expectEqualStrings(fixture.feature_oid, trimLineEnd(live_main));
    try std.testing.expectEqualStrings(fixture.main_oid, trimLineEnd(live_feature));
}

test "Compare snapshot accepts detached HEAD and omits its symbolic name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const fixture = try setupBranchSwitchFixture(io, &tmp);
    defer fixture.deinit();
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "switch", "--detach", fixture.feature_oid }, work);

    var result = try LocalCommandBackend.loadCompareSnapshot(std.testing.allocator, io, .{
        .cwd = work,
        .parent_env = null,
        .target = .{
            .full_ref = "refs/heads/main",
            .display_name = "main",
            .kind = .local,
        },
    });
    defer result.deinit(std.testing.allocator);
    switch (result) {
        .snapshot => |snapshot| {
            try std.testing.expectEqualStrings(fixture.feature_oid, snapshot.head_oid);
            try std.testing.expect(snapshot.head_name == null);
            try std.testing.expectEqualStrings("1", snapshot.ahead_count);
        },
        else => return error.ExpectedCompareSnapshot,
    }
}

test "Compare snapshot reports an unborn HEAD separately from a missing base" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const fixture = try setupBranchSwitchFixture(io, &tmp);
    defer fixture.deinit();
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "symbolic-ref", "HEAD", "refs/heads/unborn" }, work);

    var result = try LocalCommandBackend.loadCompareSnapshot(std.testing.allocator, io, .{
        .cwd = work,
        .parent_env = null,
        .target = .{
            .full_ref = "refs/heads/main",
            .display_name = "main",
            .kind = .local,
        },
    });
    defer result.deinit(std.testing.allocator);
    switch (result) {
        .basis_failed => |failure| {
            try std.testing.expectEqual(CompareBasisFailure.head_unresolved, failure.kind);
            try std.testing.expectEqualStrings("refs/heads/main", failure.attempted.full_ref);
        },
        else => return error.ExpectedUnbornCompareHead,
    }
}

test "Compare snapshot reports histories without a merge base" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const fixture = try setupBranchSwitchFixture(io, &tmp);
    defer fixture.deinit();
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "switch", "--orphan", "unrelated" }, work);
    try runTestGit(io, &.{ "git", "rm", "-rf", "--ignore-unmatch", "." }, work);
    try work.writeFile(io, .{ .sub_path = "UNRELATED.md", .data = "unrelated\n" });
    try runTestGit(io, &.{ "git", "add", "UNRELATED.md" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "unrelated" }, work);

    var result = try LocalCommandBackend.loadCompareSnapshot(std.testing.allocator, io, .{
        .cwd = work,
        .parent_env = null,
        .target = .{
            .full_ref = "refs/heads/main",
            .display_name = "main",
            .kind = .local,
        },
    });
    defer result.deinit(std.testing.allocator);
    switch (result) {
        .basis_failed => |failure| {
            try std.testing.expectEqual(CompareBasisFailure.no_merge_base, failure.kind);
            try std.testing.expectEqualStrings("refs/heads/main", failure.attempted.full_ref);
        },
        else => return error.ExpectedNoMergeBase,
    }
}

test "LocalCommandBackend switch branch succeeds between local branches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const fixture = try setupBranchSwitchFixture(io, &tmp);
    defer fixture.deinit();

    const result = try LocalCommandBackend.runOperation(std.testing.allocator, io, .{
        .repo_root = fixture.repo_root,
        .kind = .{ .switch_branch = .{
            .expected_branch = "main",
            .expected_oid = fixture.main_oid,
            .target_branch = "feature/topic",
            .target_oid = fixture.feature_oid,
        } },
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(OperationResult.ok, result);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    const current = try gitOutputAlloc(io, work, &.{ "git", "symbolic-ref", "--quiet", "--short", "HEAD" });
    defer std.testing.allocator.free(current);
    try std.testing.expectEqualStrings("feature/topic", trimLineEnd(current));
}

test "LocalCommandBackend switch branch rejects stale current branch or oid" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const fixture = try setupBranchSwitchFixture(io, &tmp);
    defer fixture.deinit();

    const result = try LocalCommandBackend.runOperation(std.testing.allocator, io, .{
        .repo_root = fixture.repo_root,
        .kind = .{ .switch_branch = .{
            .expected_branch = "main",
            .expected_oid = "not-the-current-oid",
            .target_branch = "feature/topic",
            .target_oid = fixture.feature_oid,
        } },
    });
    defer result.deinit(std.testing.allocator);

    switch (result) {
        .failed_static => |message| try std.testing.expectEqualStrings("Branch changed before switch; reload and try again", message),
        else => return error.ExpectedStaleSwitchCurrentFailure,
    }
}

test "LocalCommandBackend switch branch rejects changed target oid" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const fixture = try setupBranchSwitchFixture(io, &tmp);
    defer fixture.deinit();

    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "switch", "feature/topic" }, work);
    try work.writeFile(io, .{ .sub_path = "FEATURE.md", .data = "changed\n" });
    try runTestGit(io, &.{ "git", "add", "FEATURE.md" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "move feature" }, work);
    try runTestGit(io, &.{ "git", "switch", "main" }, work);

    const result = try LocalCommandBackend.runOperation(std.testing.allocator, io, .{
        .repo_root = fixture.repo_root,
        .kind = .{ .switch_branch = .{
            .expected_branch = "main",
            .expected_oid = fixture.main_oid,
            .target_branch = "feature/topic",
            .target_oid = fixture.feature_oid,
        } },
    });
    defer result.deinit(std.testing.allocator);

    switch (result) {
        .failed_static => |message| try std.testing.expectEqualStrings("branch list changed; reopen branch switch and try again", message),
        else => return error.ExpectedSwitchTargetChangedFailure,
    }
}

test "LocalCommandBackend switch branch rejects dirty worktree" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const fixture = try setupBranchSwitchFixture(io, &tmp);
    defer fixture.deinit();

    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try work.writeFile(io, .{ .sub_path = "README.md", .data = "dirty\n" });

    const result = try LocalCommandBackend.runOperation(std.testing.allocator, io, .{
        .repo_root = fixture.repo_root,
        .kind = .{ .switch_branch = .{
            .expected_branch = "main",
            .expected_oid = fixture.main_oid,
            .target_branch = "feature/topic",
            .target_oid = fixture.feature_oid,
        } },
    });
    defer result.deinit(std.testing.allocator);

    switch (result) {
        .failed_static => |message| try std.testing.expectEqualStrings("Worktree changed before branch switch; reload and resolve local changes first", message),
        else => return error.ExpectedSwitchDirtyFailure,
    }
}

test "LocalCommandBackend switch branch does not guess remote-only targets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const fixture = try setupBranchSwitchFixture(io, &tmp);
    defer fixture.deinit();

    const result = try LocalCommandBackend.runOperation(std.testing.allocator, io, .{
        .repo_root = fixture.repo_root,
        .kind = .{ .switch_branch = .{
            .expected_branch = "main",
            .expected_oid = fixture.main_oid,
            .target_branch = "remote-only",
            .target_oid = fixture.remote_only_oid,
        } },
    });
    defer result.deinit(std.testing.allocator);

    switch (result) {
        .failed_static => |message| try std.testing.expectEqualStrings("branch list changed; reopen branch switch and try again", message),
        else => return error.ExpectedSwitchNoGuessFailure,
    }

    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    const branch_check = try std.process.run(std.testing.allocator, io, .{
        .argv = &[_][]const u8{ "git", "rev-parse", "--verify", "refs/heads/remote-only" },
        .cwd = .{ .dir = work },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer freeRunResult(std.testing.allocator, branch_check);
    switch (branch_check.term) {
        .exited => |code| try std.testing.expect(code != 0),
        else => {},
    }
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

    const result = try LocalCommandBackend.loadBranchStatus(std.testing.allocator, io, .{
        .cwd = .{ .path = repo_root },
        .parent_env = null,
    });
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

    const result = try LocalCommandBackend.loadBranchStatus(std.testing.allocator, io, .{
        .cwd = .{ .path = repo_root },
        .parent_env = null,
    });
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

test "controlled Git environment removes inherited repository authority" {
    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    try parent.put("HOME", "/home/test");

    const git_keys = [_][]const u8{
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_COMMON_DIR",
        "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_INDEX_FILE",
        "GIT_NAMESPACE",
        "GIT_BARE",
        "GIT_SHALLOW_FILE",
        "GIT_REPLACE_REF_BASE",
        "GIT_NO_REPLACE_OBJECTS",
        "GIT_CONFIG_COUNT",
        "GIT_CONFIG_GLOBAL",
        "GIT_CONFIG_SYSTEM",
        "GIT_CEILING_DIRECTORIES",
        "GIT_DISCOVERY_ACROSS_FILESYSTEM",
    };
    for (git_keys) |key| try parent.put(key, "redirect");

    var env = try controlledGitEnvironment(std.testing.allocator, &parent);
    defer env.deinit();

    try std.testing.expectEqualStrings("/home/test", env.get("HOME").?);
    for (git_keys) |key| try std.testing.expect(env.get(key) == null);
    try std.testing.expectEqualStrings("redirect", parent.get("GIT_DIR").?);
}

test "branch status descriptor cwd survives path replacement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try runTestGit(io, &.{ "git", "init", "--bare", "remote-pinned.git" }, tmp.dir);
    try runTestGit(io, &.{ "git", "init", "--bare", "remote-replacement.git" }, tmp.dir);
    try tmp.dir.createDir(io, "work", .default_dir);
    try tmp.dir.createDir(io, "replacement", .default_dir);

    var pinned = try tmp.dir.openDir(io, "work", .{});
    defer pinned.close(io);
    var replacement = try tmp.dir.openDir(io, "replacement", .{});
    defer replacement.close(io);

    const pinned_remote = try tmp.dir.realPathFileAlloc(io, "remote-pinned.git", std.testing.allocator);
    defer std.testing.allocator.free(pinned_remote);
    const replacement_remote = try tmp.dir.realPathFileAlloc(io, "remote-replacement.git", std.testing.allocator);
    defer std.testing.allocator.free(replacement_remote);

    try runTestGit(io, &.{
        "git",
        "init",
        "--initial-branch=pinned",
    }, pinned);
    try runTestGit(io, &.{ "git", "remote", "add", "origin", pinned_remote }, pinned);
    try pinned.writeFile(io, .{ .sub_path = "PINNED.md", .data = "base\n" });
    try runTestGit(io, &.{ "git", "add", "PINNED.md" }, pinned);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "pinned base" }, pinned);
    try runTestGit(io, &.{ "git", "push", "-u", "origin", "pinned" }, pinned);
    try pinned.writeFile(io, .{ .sub_path = "PINNED.md", .data = "base\nahead\n" });
    try runTestGit(io, &.{ "git", "add", "PINNED.md" }, pinned);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "pinned ahead" }, pinned);
    const pinned_oid = try gitOutputAlloc(io, pinned, &.{ "git", "rev-parse", "--verify", "HEAD" });
    defer std.testing.allocator.free(pinned_oid);

    try runTestGit(io, &.{ "git", "init", "--initial-branch=replacement" }, replacement);
    try runTestGit(io, &.{ "git", "remote", "add", "origin", replacement_remote }, replacement);
    try replacement.writeFile(io, .{ .sub_path = "REPLACEMENT.md", .data = "replacement\n" });
    try runTestGit(io, &.{ "git", "add", "REPLACEMENT.md" }, replacement);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "replacement base" }, replacement);
    try runTestGit(io, &.{ "git", "push", "-u", "origin", "replacement" }, replacement);
    const replacement_oid = try gitOutputAlloc(io, replacement, &.{ "git", "rev-parse", "--verify", "HEAD" });
    defer std.testing.allocator.free(replacement_oid);
    try std.testing.expect(!std.mem.eql(u8, trimLineEnd(pinned_oid), trimLineEnd(replacement_oid)));

    // Keep the descriptor to repository A open while its former canonical path
    // is replaced by repository B. Reopening "work" would now observe B.
    try tmp.dir.rename("work", tmp.dir, "pinned-work", io);
    try tmp.dir.rename("replacement", tmp.dir, "work", io);
    const replacement_path = try tmp.dir.realPathFileAlloc(io, "work", std.testing.allocator);
    defer std.testing.allocator.free(replacement_path);
    const replacement_git_dir = try std.fs.path.join(std.testing.allocator, &.{ replacement_path, ".git" });
    defer std.testing.allocator.free(replacement_git_dir);

    // The input environment deliberately tries to override descriptor A with
    // repository B. Branch-status sanitization must remove this second Git
    // authority before the shared environment reaches any subprocess.
    var redirect_env = std.process.Environ.Map.init(std.testing.allocator);
    defer redirect_env.deinit();
    try redirect_env.put("GIT_DIR", replacement_git_dir);
    try redirect_env.put("GIT_WORK_TREE", replacement_path);

    const pinned_result = try LocalCommandBackend.loadBranchStatus(std.testing.allocator, io, .{
        .cwd = .{ .dir = pinned },
        .parent_env = &redirect_env,
    });
    defer pinned_result.deinit(std.testing.allocator);
    const replacement_result = try LocalCommandBackend.loadBranchStatus(std.testing.allocator, io, .{
        .cwd = .{ .path = replacement_path },
        .parent_env = &redirect_env,
    });
    defer replacement_result.deinit(std.testing.allocator);

    const pinned_status = switch (pinned_result) {
        .ok => |bundle| bundle.status,
        .failed, .failed_static => return error.UnexpectedBranchStatusFailure,
    };
    const replacement_status = switch (replacement_result) {
        .ok => |bundle| bundle.status,
        .failed, .failed_static => return error.UnexpectedBranchStatusFailure,
    };

    try std.testing.expectEqualStrings("pinned", pinned_status.branchName().?);
    try std.testing.expectEqualStrings(trimLineEnd(pinned_oid), pinned_status.oid.?);
    try std.testing.expectEqualStrings("origin/pinned", pinned_status.upstream.?.name);
    try std.testing.expectEqual(@as(u32, 1), pinned_status.ahead_behind.?.ahead);
    try std.testing.expectEqual(@as(u32, 0), pinned_status.ahead_behind.?.behind);

    try std.testing.expectEqualStrings("replacement", replacement_status.branchName().?);
    try std.testing.expectEqualStrings(trimLineEnd(replacement_oid), replacement_status.oid.?);
    try std.testing.expectEqualStrings("origin/replacement", replacement_status.upstream.?.name);
    try std.testing.expectEqual(@as(u32, 0), replacement_status.ahead_behind.?.ahead);
    try std.testing.expectEqual(@as(u32, 0), replacement_status.ahead_behind.?.behind);
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

fn runTestGitFailure(io: std.Io, argv: []const []const u8, cwd: std.Io.Dir) !void {
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer freeRunResult(std.testing.allocator, result);
    switch (result.term) {
        .exited => |code| if (code != 0) return,
        else => {},
    }
    return error.ExpectedGitCommandFailure;
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

fn setupPullWorkRepoForTest(io: std.Io, tmp: *std.testing.TmpDir) !struct { repo_root: []u8, oid: []u8 } {
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);

    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try work.writeFile(io, .{ .sub_path = "README.md", .data = "hello\n" });
    try runTestGit(io, &.{ "git", "add", "README.md" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "initial" }, work);

    const repo_root_z = try tmp.dir.realPathFileAlloc(io, "work", std.testing.allocator);
    defer std.testing.allocator.free(repo_root_z);
    const repo_root = try std.testing.allocator.dupe(u8, repo_root_z);
    errdefer std.testing.allocator.free(repo_root);
    const oid_output = try gitOutputAlloc(io, work, &.{ "git", "rev-parse", "--verify", "HEAD" });
    errdefer std.testing.allocator.free(oid_output);
    const oid = try std.testing.allocator.dupe(u8, trimLineEnd(oid_output));
    std.testing.allocator.free(oid_output);

    return .{ .repo_root = repo_root, .oid = oid };
}

const BranchSwitchFixture = struct {
    repo_root: []u8,
    main_oid: []u8,
    feature_oid: []u8,
    remote_only_oid: []u8,

    fn deinit(self: BranchSwitchFixture) void {
        std.testing.allocator.free(self.repo_root);
        std.testing.allocator.free(self.main_oid);
        std.testing.allocator.free(self.feature_oid);
        std.testing.allocator.free(self.remote_only_oid);
    }
};

fn setupBranchSwitchFixture(io: std.Io, tmp: *std.testing.TmpDir) !BranchSwitchFixture {
    try runTestGit(io, &.{ "git", "init", "--bare", "remote.git" }, tmp.dir);
    try tmp.dir.createDir(io, "work", .default_dir);
    try tmp.dir.createDir(io, "updater", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    var updater = try tmp.dir.openDir(io, "updater", .{});
    defer updater.close(io);

    const remote_root = try tmp.dir.realPathFileAlloc(io, "remote.git", std.testing.allocator);
    defer std.testing.allocator.free(remote_root);

    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try runTestGit(io, &.{ "git", "remote", "add", "origin", remote_root }, work);
    try work.writeFile(io, .{ .sub_path = "README.md", .data = "main\n" });
    try runTestGit(io, &.{ "git", "add", "README.md" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "initial" }, work);
    try runTestGit(io, &.{ "git", "push", "-u", "origin", "main" }, work);

    const main_output = try gitOutputAlloc(io, work, &.{ "git", "rev-parse", "--verify", "HEAD" });
    defer std.testing.allocator.free(main_output);
    const main_oid = try std.testing.allocator.dupe(u8, trimLineEnd(main_output));
    errdefer std.testing.allocator.free(main_oid);

    try runTestGit(io, &.{ "git", "switch", "-c", "feature/topic" }, work);
    try work.writeFile(io, .{ .sub_path = "FEATURE.md", .data = "feature\n" });
    try runTestGit(io, &.{ "git", "add", "FEATURE.md" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "feature" }, work);
    const feature_output = try gitOutputAlloc(io, work, &.{ "git", "rev-parse", "--verify", "HEAD" });
    defer std.testing.allocator.free(feature_output);
    const feature_oid = try std.testing.allocator.dupe(u8, trimLineEnd(feature_output));
    errdefer std.testing.allocator.free(feature_oid);
    try runTestGit(io, &.{ "git", "switch", "main" }, work);
    try runTestGit(io, &.{ "git", "push", "origin", "feature/topic" }, work);

    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, updater);
    try runTestGit(io, &.{ "git", "remote", "add", "origin", remote_root }, updater);
    try runTestGit(io, &.{ "git", "pull", "--ff-only", "origin", "main" }, updater);
    try runTestGit(io, &.{ "git", "switch", "-c", "remote-only" }, updater);
    try updater.writeFile(io, .{ .sub_path = "REMOTE.md", .data = "remote\n" });
    try runTestGit(io, &.{ "git", "add", "REMOTE.md" }, updater);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "remote only" }, updater);
    try runTestGit(io, &.{ "git", "push", "origin", "remote-only" }, updater);
    try runTestGit(io, &.{ "git", "fetch", "origin" }, work);
    const remote_only_output = try gitOutputAlloc(io, work, &.{ "git", "rev-parse", "--verify", "refs/remotes/origin/remote-only" });
    defer std.testing.allocator.free(remote_only_output);
    const remote_only_oid = try std.testing.allocator.dupe(u8, trimLineEnd(remote_only_output));
    errdefer std.testing.allocator.free(remote_only_oid);

    const repo_root_z = try tmp.dir.realPathFileAlloc(io, "work", std.testing.allocator);
    defer std.testing.allocator.free(repo_root_z);
    const repo_root = try std.testing.allocator.dupe(u8, repo_root_z);
    errdefer std.testing.allocator.free(repo_root);

    return .{
        .repo_root = repo_root,
        .main_oid = main_oid,
        .feature_oid = feature_oid,
        .remote_only_oid = remote_only_oid,
    };
}

fn expectBranchListed(branches: []const BranchListItem, name: []const u8) !void {
    for (branches) |branch| {
        if (std.mem.eql(u8, branch.name, name)) return;
    }
    return error.ExpectedBranchListed;
}

fn expectBranchNotListed(branches: []const BranchListItem, name: []const u8) !void {
    for (branches) |branch| {
        if (std.mem.eql(u8, branch.name, name)) return error.ExpectedBranchNotListed;
    }
}

fn branchByFullRef(branches: []const BranchListItem, full_ref: []const u8) ?*const BranchListItem {
    for (branches) |*branch| {
        if (std.mem.eql(u8, branch.full_ref, full_ref)) return branch;
    }
    return null;
}

const PullRefreshFixture = struct {
    repo_root: []u8,
    oid: []u8,

    fn deinit(self: PullRefreshFixture) void {
        std.testing.allocator.free(self.repo_root);
        std.testing.allocator.free(self.oid);
    }
};

fn setupPullRefreshFixture(io: std.Io, tmp: *std.testing.TmpDir) !PullRefreshFixture {
    try runTestGit(io, &.{ "git", "init", "--bare", "remote.git" }, tmp.dir);
    try tmp.dir.createDir(io, "work", .default_dir);
    try tmp.dir.createDir(io, "updater", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    var updater = try tmp.dir.openDir(io, "updater", .{});
    defer updater.close(io);

    const remote_root = try tmp.dir.realPathFileAlloc(io, "remote.git", std.testing.allocator);
    defer std.testing.allocator.free(remote_root);

    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try runTestGit(io, &.{ "git", "remote", "add", "origin", remote_root }, work);
    try work.writeFile(io, .{ .sub_path = "README.md", .data = "initial\n" });
    try runTestGit(io, &.{ "git", "add", "README.md" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "initial" }, work);
    try runTestGit(io, &.{ "git", "push", "-u", "origin", "main" }, work);

    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, updater);
    try runTestGit(io, &.{ "git", "remote", "add", "origin", remote_root }, updater);
    try runTestGit(io, &.{ "git", "pull", "--ff-only", "origin", "main" }, updater);

    const repo_root_z = try tmp.dir.realPathFileAlloc(io, "work", std.testing.allocator);
    defer std.testing.allocator.free(repo_root_z);
    const repo_root = try std.testing.allocator.dupe(u8, repo_root_z);
    errdefer std.testing.allocator.free(repo_root);
    const oid_output = try gitOutputAlloc(io, work, &.{ "git", "rev-parse", "--verify", "HEAD" });
    errdefer std.testing.allocator.free(oid_output);
    const oid = try std.testing.allocator.dupe(u8, trimLineEnd(oid_output));
    std.testing.allocator.free(oid_output);

    return .{ .repo_root = repo_root, .oid = oid };
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
