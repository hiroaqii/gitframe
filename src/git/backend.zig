const std = @import("std");
const builtin = @import("builtin");
const git_ref = @import("ref.zig");
const git_branch_status = @import("branch_status.zig");
const git_push = @import("push.zig");
const git_command = @import("command.zig");
const process_runner = @import("../process/runner.zig");
const root_capability = @import("../repo/root_capability.zig");
const repository_change_map = @import("../repository/change_map.zig");

pub const RemoteEnvironmentMode = enum {
    background,
    inspection,
    foreground,
    local_finalizer,
};

pub const RemoteWarningSet = packed struct {
    git_plaintext_store: bool = false,
    gcm_plaintext_store: bool = false,
    potential_plaintext_store: bool = false,
    helper_policy_unknown: bool = false,
    proxy_credentials_omitted: bool = false,

    pub fn merge(self: *RemoteWarningSet, other: RemoteWarningSet) void {
        self.git_plaintext_store = self.git_plaintext_store or other.git_plaintext_store;
        self.gcm_plaintext_store = self.gcm_plaintext_store or other.gcm_plaintext_store;
        self.potential_plaintext_store = self.potential_plaintext_store or other.potential_plaintext_store;
        self.helper_policy_unknown = self.helper_policy_unknown or other.helper_policy_unknown;
        self.proxy_credentials_omitted = self.proxy_credentials_omitted or other.proxy_credentials_omitted;
    }
};

pub const OwnedRemoteEnvironment = struct {
    map: std.process.Environ.Map,
    warnings: RemoteWarningSet = .{},

    pub fn deinit(self: *OwnedRemoteEnvironment) void {
        self.map.deinit();
        self.* = undefined;
    }
};

pub const max_branch_list_bytes = 4 * 1024 * 1024;

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

/// App-safe terminal vocabulary for a background remote operation. Raw child
/// output is deliberately absent: the backend classifies it while it is held
/// by SensitiveBytes and destroys it before returning across this boundary.
pub const RemoteFailure = enum {
    authentication_required,
    ssh_public_key,
    http_userinfo_rejected,
    canceled_outcome_unknown,
    timed_out_outcome_unknown,
    spawn_failed,
    failed,
};

pub const RemoteSuccess = enum {
    completed,
    already_up_to_date,
};

pub const RemoteOperationOutcome = union(enum) {
    ok: RemoteSuccess,
    failed: RemoteFailure,
};

pub const RemoteOperationResult = struct {
    outcome: RemoteOperationOutcome,
    warnings: RemoteWarningSet = .{},
};

pub const RemoteOperationKind = union(enum) {
    push: PushRequest,
    pull_refresh_ff_only: PullRequest,
    fetch: FetchRequest,
};

/// Descriptor-bound authority for one background remote operation.
///
/// `root` and `environment` are borrowed for the synchronous call. The App
/// task owns both values for its entire run. `control.deadline` is one absolute
/// timestamp shared by URL/config preflight, snapshot verification, and every
/// network or merge child.
pub const RemoteOperationRequest = struct {
    root: *const root_capability.RootCapability,
    environment: *const OwnedRemoteEnvironment,
    control: process_runner.ProcessControl,
    kind: RemoteOperationKind,
};

pub const ForegroundPushInspectionOutcome = union(enum) {
    ready,
    branch_changed,
    oid_changed,
    failed: RemoteFailure,
};

pub const ForegroundPushInspectionResult = struct {
    outcome: ForegroundPushInspectionOutcome,
    warnings: RemoteWarningSet = .{},
};

/// Descriptor-bound, raw-free admission result for a native foreground push.
/// The audit and snapshot verification run in one task immediately before the
/// App queues the terminal child; no URL or config bytes cross this boundary.
pub const ForegroundPushInspectionRequest = struct {
    root: *const root_capability.RootCapability,
    environment: *const OwnedRemoteEnvironment,
    control: process_runner.ProcessControl,
    push: PushRequest,
};

pub const PushUpstreamFinalizeOutcome = enum {
    configured,
    already_configured,
    context_changed,
    branch_changed,
    oid_changed,
    upstream_conflict,
    config_write_failed,
    config_verification_failed,
    tracking_unknown,
};

/// One local-only finalization attempt after a fixed-OID native push has
/// already succeeded. Every child uses the retained descriptor and strict
/// replacement environment supplied by the owning task.
pub const PushUpstreamFinalizeRequest = struct {
    root: *const root_capability.RootCapability,
    environment: *const OwnedRemoteEnvironment,
    control: process_runner.ProcessControl,
    branch: []const u8,
    remote: []const u8,
    remote_branch: []const u8,
    oid: []const u8,
};

pub const RepositoryFileChangeRequest = struct {
    /// Borrowed descriptor cwd kept alive by the synchronous task call.
    cwd: std.Io.Dir,
    /// Borrowed controlled environment shared by repository and temp commands.
    environment: *const git_command.LocalGitEnvironment,
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
    /// Commit snapshot used by the pre-push safety check. Foreground callers
    /// also use it as the immutable source of their native refspec.
    oid: []const u8,
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

/// Request for a write operation executed in a concrete repository.
///
/// The app snapshots `repo_root` and paths before spawning the task so a later
/// repo switch cannot change where the operation runs.
pub const OperationRequest = struct {
    repo_root: []const u8,
    kind: OperationKind,
};

pub const LocalCommandBackend = struct {
    pub fn loadRepositoryFileChange(allocator: std.mem.Allocator, io: std.Io, request: RepositoryFileChangeRequest) git_command.Error!RepositoryFileChangeLoadResult {
        return loadGitRepositoryFileChange(allocator, io, request);
    }

    pub fn loadBranchStatus(allocator: std.mem.Allocator, io: std.Io, request: BranchStatusRequest) git_command.Error!BranchStatusLoadResult {
        return loadGitBranchStatus(allocator, io, request);
    }

    pub fn loadBranchList(allocator: std.mem.Allocator, io: std.Io, request: BranchListRequest) git_command.Error!BranchListLoadResult {
        return loadGitBranchList(allocator, io, request);
    }

    pub fn loadCompareSnapshot(allocator: std.mem.Allocator, io: std.Io, request: CompareSnapshotRequest) git_command.Error!CompareSnapshotResult {
        return loadGitCompareSnapshot(allocator, io, request);
    }

    pub fn runOperation(allocator: std.mem.Allocator, io: std.Io, request: OperationRequest) git_command.Error!OperationResult {
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
            .switch_branch => |switch_branch| runGitSwitchBranch(allocator, io, request.repo_root, switch_branch),
        };
    }

    /// Runs the credentialless background remote path. This is the sole backend
    /// entry point that executes background push, pull, or fetch: it accepts a
    /// retained root descriptor and returns no child-owned diagnostic bytes.
    pub fn runRemoteOperation(
        allocator: std.mem.Allocator,
        io: std.Io,
        request: RemoteOperationRequest,
    ) RemoteOperationResult {
        return runSecureRemoteOperation(allocator, io, request);
    }

    pub fn inspectForegroundPush(
        allocator: std.mem.Allocator,
        io: std.Io,
        request: ForegroundPushInspectionRequest,
    ) ForegroundPushInspectionResult {
        return runForegroundPushInspection(allocator, io, request);
    }

    pub fn finalizePushUpstream(
        allocator: std.mem.Allocator,
        io: std.Io,
        request: PushUpstreamFinalizeRequest,
    ) PushUpstreamFinalizeOutcome {
        return runPushUpstreamFinalizer(allocator, io, request);
    }
};

fn runCapturedCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: ?[]const u8,
    argv: []const []const u8,
    stdout_limit: std.Io.Limit,
    stderr_limit: std.Io.Limit,
) git_command.Error!process_runner.Result {
    return process_runner.runCaptured(allocator, io, .{
        .argv = argv,
        .cwd = if (repo_root) |root| .{ .path = root } else .inherit,
        .stdout_limit = stdout_limit,
        .stderr_limit = stderr_limit,
    }) catch |err| return git_command.fromRunnerError(err);
}

fn operationResultFromGitCommand(allocator: std.mem.Allocator, result: process_runner.Result, fallback_label: []const u8) git_command.Error!OperationResult {
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
) git_command.Error!OperationResult {
    return switch (detailed) {
        .ok => |result| operationResultFromGitCommand(allocator, result, fallback_label),
        .failed => |failure_value| {
            var failure = failure_value;
            defer failure.deinit(allocator);

            const error_name = failure.errorName();
            return switch (failure) {
                .stdin => |*stdin_failure| {
                    const child_exited_zero = switch (stdin_failure.result.term) {
                        .exited => |code| code == 0,
                        else => false,
                    };
                    if (stdin_failure.result.stderr.len > 0 and !child_exited_zero) {
                        const result = stdin_failure.takeResult();
                        allocator.free(result.stdout);
                        return .{ .failed = result.stderr };
                    }

                    const message = if (stdin_failure.result.stderr.len > 0)
                        std.fmt.allocPrint(
                            allocator,
                            "{s} failed during stdin ({s}): {any}\n{s}",
                            .{ fallback_label, error_name, stdin_failure.result.term, stdin_failure.result.stderr },
                        ) catch return error.OutOfMemory
                    else
                        std.fmt.allocPrint(
                            allocator,
                            "{s} failed during stdin ({s}): {any}",
                            .{ fallback_label, error_name, stdin_failure.result.term },
                        ) catch return error.OutOfMemory;
                    const result = stdin_failure.takeResult();
                    result.deinit(allocator);
                    return .{ .failed = message };
                },
                else => git_command.fromRunnerError(failure.toError()),
            };
        },
    };
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
    run: *const fn (*anyopaque, std.Io, std.Io.Dir) git_command.Error!void,

    fn invoke(self: RepositoryChangePhaseHook, io: std.Io, cwd: std.Io.Dir) git_command.Error!void {
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
) git_command.Error!RepositoryFileChangeLoadResult {
    return loadGitRepositoryFileChangeWithHooks(allocator, io, request, null);
}

fn loadGitRepositoryFileChangeWithHooks(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: RepositoryFileChangeRequest,
    hooks: ?*RepositoryChangeTestHooks,
) git_command.Error!RepositoryFileChangeLoadResult {
    const repository_context = git_command.DirectoryContext{ .cwd = request.cwd, .environment = request.environment };

    const head_result = try runRepositoryChangeCommand(allocator, io, repository_context, &.{
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
    const tree_result = try runRepositoryChangeCommand(allocator, io, repository_context, &.{
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

    const entry_result = try runRepositoryChangeCommand(allocator, io, repository_context, &.{
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

    const attributes_before = try loadSafeRepositoryChangeAttributes(allocator, io, repository_context, request.path, hooks) orelse
        return .{ .failed_static = "Repository change attributes unavailable" };

    const blob_result = try runRepositoryChangeCommand(allocator, io, repository_context, &.{
        "git",
        "--no-optional-locks",
        "cat-file",
        "blob",
        blob.?.oid,
    }, &.{}, 16 * 1024 * 1024, hooks);
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

    const diff_result = try runRepositoryChangeCommand(allocator, io, .{ .cwd = temp.dir, .environment = request.environment }, &.{
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
    }, &.{}, 16 * 1024 * 1024, hooks);
    errdefer diff_result.deinit(allocator);

    const attributes_after = try loadSafeRepositoryChangeAttributes(allocator, io, repository_context, request.path, hooks) orelse {
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
    context: git_command.DirectoryContext,
    argv: []const []const u8,
    stdin: []const u8,
    stdout_limit: usize,
    hooks: ?*RepositoryChangeTestHooks,
) git_command.Error!process_runner.Result {
    var effective_stdout_limit = stdout_limit;
    if (hooks) |test_hooks| {
        const command_index = test_hooks.command_index;
        test_hooks.command_index += 1;
        if (test_hooks.fail_command_at == command_index) return error.SpawnFailed;
        if (test_hooks.limit_command_at == command_index) effective_stdout_limit = @min(effective_stdout_limit, test_hooks.forced_stdout_limit);
    }
    return git_command.runWithStdin(allocator, io, context, .{
        .argv = argv,
        .stdin = stdin,
        .stdout_limit = .limited(effective_stdout_limit),
        .stderr_limit = .limited(repository_change_small_output_limit),
    });
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
    context: git_command.DirectoryContext,
    path: []const u8,
    hooks: ?*RepositoryChangeTestHooks,
) git_command.Error!?AttributeState {
    const stdin = allocator.alloc(u8, path.len + 1) catch return error.OutOfMemory;
    defer allocator.free(stdin);
    @memcpy(stdin[0..path.len], path);
    stdin[path.len] = 0;
    const result = try runRepositoryChangeCommand(allocator, io, context, &.{
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
    ) git_command.Error!ComparisonTemp {
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

fn writePrivateComparisonFile(io: std.Io, dir: std.Io.Dir, name: []const u8, contents: []const u8) git_command.Error!void {
    var file = dir.createFile(io, name, .{ .exclusive = true, .permissions = .fromMode(0o600) }) catch return error.SpawnFailed;
    defer file.close(io);
    file.writeStreamingAll(io, contents) catch return error.SpawnFailed;
}

fn repositoryChangeMapForTest(cwd: std.Io.Dir, path: []const u8, source_bytes: []const u8, temp_base_path: []const u8) !repository_change_map.Map {
    var environment = try testingLocalGitEnvironment(std.testing.allocator);
    defer environment.deinit();
    const result = try LocalCommandBackend.loadRepositoryFileChange(std.testing.allocator, std.testing.io, .{
        .cwd = cwd,
        .environment = &environment,
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

fn testingLocalGitEnvironment(allocator: std.mem.Allocator) !git_command.LocalGitEnvironment {
    var parent = try std.testing.environ.createMap(allocator);
    defer parent.deinit();
    return git_command.LocalGitEnvironment.initFromParent(allocator, &parent);
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
    var environment = try testingLocalGitEnvironment(std.testing.allocator);
    defer environment.deinit();
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
        .environment = &environment,
        .path = "a*b.zig",
        .source_bytes = "changed\n",
    });
    defer rejected.deinit(std.testing.allocator);
    try std.testing.expect(rejected == .failed_static);

    try work.writeFile(io, .{ .sub_path = ".gitattributes", .data = "a[*]b.zig working-tree-encoding=UTF-16\n" });
    const encoding_rejected = try LocalCommandBackend.loadRepositoryFileChange(std.testing.allocator, io, .{
        .cwd = work,
        .environment = &environment,
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

    fn run(ctx_ptr: *anyopaque, io: std.Io, cwd: std.Io.Dir) git_command.Error!void {
        const ctx: *@This() = @ptrCast(@alignCast(ctx_ptr));
        runTestGit(io, &.{ "git", "reset", "--hard", ctx.oid }, cwd) catch return error.SpawnFailed;
    }
};

const RemoveIndexHookContext = struct {
    path: []const u8,

    fn run(ctx_ptr: *anyopaque, io: std.Io, cwd: std.Io.Dir) git_command.Error!void {
        const ctx: *@This() = @ptrCast(@alignCast(ctx_ptr));
        runTestGit(io, &.{ "git", "rm", "--cached", "--", ctx.path }, cwd) catch return error.SpawnFailed;
    }
};

const RewriteWorktreeHookContext = struct {
    path: []const u8,
    bytes: []const u8,

    fn run(ctx_ptr: *anyopaque, io: std.Io, cwd: std.Io.Dir) git_command.Error!void {
        const ctx: *@This() = @ptrCast(@alignCast(ctx_ptr));
        cwd.writeFile(io, .{ .sub_path = ctx.path, .data = ctx.bytes }) catch return error.SpawnFailed;
    }
};

test "repository change backend keeps copied object basis across HEAD index and worktree mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var environment = try testingLocalGitEnvironment(std.testing.allocator);
    defer environment.deinit();
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
        .environment = &environment,
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
        .environment = &environment,
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
        .environment = &environment,
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
    var environment = try testingLocalGitEnvironment(std.testing.allocator);
    defer environment.deinit();
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
            .environment = &environment,
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
        .environment = &environment,
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
        .environment = &environment,
        .path = "source",
        .source_bytes = "changed\n",
        .temp_base_path = temp_base,
    }, &open_hooks));

    inline for (.{ RepositoryChangeWriteTarget.head, RepositoryChangeWriteTarget.current }) |write_failure| {
        var write_hooks = RepositoryChangeTestHooks{ .fail_write = write_failure, .temp_name_token = @tagName(write_failure) };
        try std.testing.expectError(error.SpawnFailed, loadGitRepositoryFileChangeWithHooks(std.testing.allocator, io, .{
            .cwd = work,
            .environment = &environment,
            .path = "source",
            .source_bytes = "changed\n",
            .temp_base_path = temp_base,
        }, &write_hooks));
    }
    inline for (.{ @as(usize, 5), @as(usize, 6) }) |command_index| {
        var command_hooks = RepositoryChangeTestHooks{ .fail_command_at = command_index, .temp_name_token = if (command_index == 5) "diff-failure" else "post-attr-failure" };
        try std.testing.expectError(error.SpawnFailed, loadGitRepositoryFileChangeWithHooks(std.testing.allocator, io, .{
            .cwd = work,
            .environment = &environment,
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
        .environment = &environment,
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
    environment: *const git_command.LocalGitEnvironment,
    temp_base_path: []const u8,

    fn exercise(allocator: std.mem.Allocator, fixture: *@This()) !void {
        var hooks = RepositoryChangeTestHooks{ .temp_name_token = "allocation" };
        const result = try loadGitRepositoryFileChangeWithHooks(allocator, fixture.io, .{
            .cwd = fixture.cwd,
            .environment = fixture.environment,
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
    var environment = try testingLocalGitEnvironment(std.testing.allocator);
    defer environment.deinit();
    var fixture = RepositoryChangeAllocationFixture{
        .io = io,
        .cwd = work,
        .environment = &environment,
        .temp_base_path = temp_base,
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, RepositoryChangeAllocationFixture.exercise, .{&fixture});

    var base = try tmp.dir.openDir(io, "temp-base", .{ .iterate = true });
    defer base.close(io);
    var iterator = base.iterate();
    try std.testing.expect(try iterator.next(io) == null);
}

fn loadGitBranchStatus(allocator: std.mem.Allocator, io: std.Io, request: BranchStatusRequest) git_command.Error!BranchStatusLoadResult {
    var builder = git_branch_status.Builder.init(allocator);
    defer builder.deinit();

    var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, request.parent_env);
    defer environment.deinit();

    const head_argv = [_][]const u8{ "git", "symbolic-ref", "--quiet", "--short", "HEAD" };
    const head_result = try runControlledBranchCommand(allocator, io, request.cwd, &environment, &head_argv, .limited(4 * 1024));
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
    const oid_result = try runControlledBranchCommand(allocator, io, request.cwd, &environment, &oid_argv, .limited(4 * 1024));
    defer oid_result.deinit(allocator);
    switch (oid_result.term) {
        .exited => |code| if (code == 0) {
            try builder.setOid(trimLineEnd(oid_result.stdout));
        },
        else => return branchStatusCommandFailure(allocator, "git rev-parse HEAD", oid_result),
    }

    const upstream_argv = [_][]const u8{ "git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}" };
    const upstream_result = try runControlledBranchCommand(allocator, io, request.cwd, &environment, &upstream_argv, .limited(4 * 1024));
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
        const ab_result = try runControlledBranchCommand(allocator, io, request.cwd, &environment, &ab_argv, .limited(4 * 1024));
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

fn loadGitBranchList(allocator: std.mem.Allocator, io: std.Io, request: BranchListRequest) git_command.Error!BranchListLoadResult {
    return loadGitBranchListWithLimit(allocator, io, request, .limited(max_branch_list_bytes));
}

fn loadGitBranchListWithLimit(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: BranchListRequest,
    list_stdout_limit: std.Io.Limit,
) git_command.Error!BranchListLoadResult {
    const cwd: std.process.Child.Cwd = switch (request.cwd) {
        .path => |path| .{ .path = path },
        .dir => |dir| .{ .dir = dir },
    };
    var controlled_environment: ?git_command.LocalGitEnvironment = switch (request.environment) {
        .inherited => null,
        .controlled => |parent| try git_command.LocalGitEnvironment.initFromParent(allocator, parent),
    };
    defer if (controlled_environment) |*environment| environment.deinit();

    const current_argv = [_][]const u8{ "git", "symbolic-ref", "--quiet", "--short", "HEAD" };
    const current_result = if (controlled_environment) |*environment|
        try runControlledBranchCommand(allocator, io, request.cwd, environment, &current_argv, .limited(4 * 1024))
    else
        try runGitBranchStatusCommandInCwd(allocator, io, cwd, null, &current_argv, .limited(4 * 1024));
    defer current_result.deinit(allocator);

    const format = "--format=%(refname)%00%(refname:short)%00%(objectname)%00%(symref)%00";
    const local_argv = [_][]const u8{ "git", "for-each-ref", format, "refs/heads" };
    const all_argv = [_][]const u8{ "git", "for-each-ref", format, "refs/heads", "refs/remotes" };
    const list_argv = switch (request.scope) {
        .local => &local_argv,
        .local_and_remote => &all_argv,
    };
    const list_result = if (controlled_environment) |*environment|
        try runControlledBranchCommand(allocator, io, request.cwd, environment, list_argv, list_stdout_limit)
    else
        try runGitBranchStatusCommandInCwd(allocator, io, cwd, null, list_argv, list_stdout_limit);
    defer list_result.deinit(allocator);

    return branchListResultFromCommandResults(allocator, current_result, list_result);
}

const ComparePhaseHook = struct {
    context: *anyopaque,
    run: *const fn (*anyopaque, std.Io, std.Io.Dir) git_command.Error!void,

    fn invoke(self: ComparePhaseHook, io: std.Io, cwd: std.Io.Dir) git_command.Error!void {
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
) git_command.Error!CompareSnapshotResult {
    return loadGitCompareSnapshotWithHooks(allocator, io, request, null);
}

fn loadGitCompareSnapshotWithHooks(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: CompareSnapshotRequest,
    hooks: ?*CompareTestHooks,
) git_command.Error!CompareSnapshotResult {
    var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, request.parent_env);
    defer environment.deinit();

    const resolution = if (request.target) |target|
        try resolveExplicitCompareTarget(allocator, io, request.cwd, &environment, target)
    else
        try resolveDefaultCompareTarget(allocator, io, request.cwd, &environment);

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

    const head_resolution = try resolveCompareHead(allocator, io, request.cwd, &environment);
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
        &environment,
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
        &environment,
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
        &environment,
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
    env: *const git_command.LocalGitEnvironment,
    spec: CompareTargetSpec,
) git_command.Error!CompareTargetResolution {
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
    env: *const git_command.LocalGitEnvironment,
) git_command.Error!CompareTargetResolution {
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
    env: *const git_command.LocalGitEnvironment,
    target_value: CompareTarget,
) git_command.Error!CompareTargetResolution {
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
    env: *const git_command.LocalGitEnvironment,
) git_command.Error!CompareHeadResolution {
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
    env: *const git_command.LocalGitEnvironment,
    base_oid: []const u8,
    head_oid: []const u8,
) git_command.Error!CompareMergeBaseResult {
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
    env: *const git_command.LocalGitEnvironment,
    merge_base_oid: []const u8,
    head_oid: []const u8,
) git_command.Error!CompareTextResult {
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
    env: *const git_command.LocalGitEnvironment,
    merge_base_oid: []const u8,
    head_oid: []const u8,
) git_command.Error!CompareTextResult {
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
        .limited(16 * 1024 * 1024),
        false,
    );
}

fn runOptionalCompareText(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    env: *const git_command.LocalGitEnvironment,
    argv: []const []const u8,
    label: []const u8,
    stdout_limit: std.Io.Limit,
) git_command.Error!CompareTextResult {
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
    env: *const git_command.LocalGitEnvironment,
    argv: []const []const u8,
    label: []const u8,
    stdout_limit: std.Io.Limit,
    trim_output: bool,
) git_command.Error!CompareTextResult {
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
    env: *const git_command.LocalGitEnvironment,
    argv: []const []const u8,
    stdout_limit: std.Io.Limit,
) git_command.Error!process_runner.Result {
    return git_command.runCaptured(allocator, io, .{ .cwd = cwd, .environment = env }, .{
        .argv = argv,
        .stdout_limit = stdout_limit,
        .stderr_limit = .limited(256 * 1024),
    });
}

fn compareCommandFailure(
    allocator: std.mem.Allocator,
    label: []const u8,
    result: process_runner.Result,
) git_command.Error![]u8 {
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
) git_command.Error!BranchListLoadResult {
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

fn branchListCommandFailure(allocator: std.mem.Allocator, result: process_runner.Result) git_command.Error!BranchListLoadResult {
    if (result.stderr.len > 0) return .{ .failed = allocator.dupe(u8, result.stderr) catch return error.OutOfMemory };
    return .{ .failed = std.fmt.allocPrint(allocator, "git branch list failed: {any}", .{result.term}) catch return error.OutOfMemory };
}

fn runGitBranchStatusCommand(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, argv: []const []const u8) git_command.Error!process_runner.Result {
    return runGitBranchStatusCommandInCwd(allocator, io, .{ .path = repo_root }, null, argv, .limited(4 * 1024));
}

fn runControlledBranchCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: BranchStatusCwd,
    environment: *const git_command.LocalGitEnvironment,
    argv: []const []const u8,
    stdout_limit: std.Io.Limit,
) git_command.Error!process_runner.Result {
    return switch (cwd) {
        .path => |path| runGitBranchStatusCommandInCwd(
            allocator,
            io,
            .{ .path = path },
            environment.borrow(),
            argv,
            stdout_limit,
        ),
        .dir => |dir| git_command.runCaptured(allocator, io, .{ .cwd = dir, .environment = environment }, .{
            .argv = argv,
            .stdout_limit = stdout_limit,
            .stderr_limit = .limited(16 * 1024),
        }),
    };
}

fn runGitBranchStatusCommandInCwd(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.process.Child.Cwd,
    environ_map: ?*const std.process.Environ.Map,
    argv: []const []const u8,
    stdout_limit: std.Io.Limit,
) git_command.Error!process_runner.Result {
    return process_runner.runCaptured(allocator, io, .{
        .argv = argv,
        .cwd = cwd,
        .environ_map = environ_map,
        .stdout_limit = stdout_limit,
        .stderr_limit = .limited(16 * 1024),
    }) catch |err| return git_command.fromRunnerError(err);
}

fn freeRunResult(allocator: std.mem.Allocator, result: std.process.RunResult) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn branchStatusCommandFailure(allocator: std.mem.Allocator, label: []const u8, result: process_runner.Result) git_command.Error!BranchStatusLoadResult {
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

fn parseRevListAheadBehind(text: []const u8) git_command.Error!RevListAheadBehind {
    var iter = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const ahead_text = iter.next() orelse return error.SpawnFailed;
    const behind_text = iter.next() orelse return error.SpawnFailed;
    return .{
        .ahead = std.fmt.parseInt(u32, ahead_text, 10) catch return error.SpawnFailed,
        .behind = std.fmt.parseInt(u32, behind_text, 10) catch return error.SpawnFailed,
    };
}

fn runGitAdd(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, path: []const u8) git_command.Error!OperationResult {
    const argv = [_][]const u8{ "git", "add", "--", path };
    const result = try runCapturedCommand(allocator, io, repo_root, &argv, .limited(64 * 1024), .limited(256 * 1024));
    return operationResultFromGitCommand(allocator, result, "git add");
}

fn runGitUnstage(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, path: []const u8) git_command.Error!OperationResult {
    const argv = [_][]const u8{ "git", "restore", "--staged", "--", path };
    const result = try runCapturedCommand(allocator, io, repo_root, &argv, .limited(64 * 1024), .limited(256 * 1024));
    return operationResultFromGitCommand(allocator, result, "git restore --staged");
}

fn runGitAddAll(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8) git_command.Error!OperationResult {
    const argv = [_][]const u8{ "git", "add", "--all", "--", "." };
    const result = try runCapturedCommand(allocator, io, repo_root, &argv, .limited(64 * 1024), .limited(256 * 1024));
    return operationResultFromGitCommand(allocator, result, "git add --all");
}

fn runGitUnstageAll(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8) git_command.Error!OperationResult {
    const argv = [_][]const u8{ "git", "restore", "--staged", "--", "." };
    const result = try runCapturedCommand(allocator, io, repo_root, &argv, .limited(64 * 1024), .limited(256 * 1024));
    return operationResultFromGitCommand(allocator, result, "git restore --staged");
}

fn runGitDiscard(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, path: []const u8) git_command.Error!OperationResult {
    const argv = [_][]const u8{ "git", "restore", "--", path };
    const result = try runCapturedCommand(allocator, io, repo_root, &argv, .limited(64 * 1024), .limited(256 * 1024));
    return operationResultFromGitCommand(allocator, result, "git restore");
}

fn runGitApplyCached(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, patch: []const u8) git_command.Error!OperationResult {
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

fn runGitApplyCachedReverse(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, patch: []const u8) git_command.Error!OperationResult {
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

fn runGitCommit(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, request: CommitRequest) git_command.Error!OperationResult {
    return runGitCommitLike(allocator, io, repo_root, request, false);
}

fn runGitAmend(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, request: CommitRequest) git_command.Error!OperationResult {
    return runGitCommitLike(allocator, io, repo_root, request, true);
}

const max_remote_diagnostic_bytes = 256 * 1024;

const SensitiveRemoteCommand = union(enum) {
    completed: process_runner.SensitiveResult,
    canceled,
    timed_out,
    failed: RemoteFailure,

    fn deinit(self: *SensitiveRemoteCommand) void {
        switch (self.*) {
            .completed => |*result| result.deinit(),
            .canceled, .timed_out, .failed => {},
        }
        self.* = .{ .failed = .failed };
    }
};

const RemoteUrlUse = enum { fetch, push };
const UrlAudit = enum { accepted, userinfo, invalid };
const RemoteCheck = union(enum) {
    matches,
    mismatch,
    failed: RemoteFailure,
};

fn runSecureRemoteOperation(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: RemoteOperationRequest,
) RemoteOperationResult {
    var warnings = request.environment.warnings;
    const remote_and_use: struct { remote: []const u8, use: RemoteUrlUse } = switch (request.kind) {
        .push => |push| .{ .remote = push.remote, .use = .push },
        .pull_refresh_ff_only => |pull| .{ .remote = pull.remote, .use = .fetch },
        .fetch => |fetch| .{ .remote = fetch.remote, .use = .fetch },
    };

    if (auditRemoteUrls(
        allocator,
        io,
        request.root.dir(),
        &request.environment.map,
        request.control,
        remote_and_use.remote,
        remote_and_use.use,
    )) |failure| return remoteFailureResult(failure, warnings);

    if (classifyCredentialPolicy(
        allocator,
        io,
        request.root.dir(),
        &request.environment.map,
        request.control,
        &warnings,
    )) |failure| return remoteFailureResult(failure, warnings);

    return switch (request.kind) {
        .push => |push| runSecureGitPush(allocator, io, request, push, warnings),
        .pull_refresh_ff_only => |pull| runSecureGitPull(allocator, io, request, pull, warnings),
        .fetch => |fetch| runSecureGitFetch(allocator, io, request, fetch, warnings),
    };
}

fn remoteFailureResult(failure: RemoteFailure, warnings: RemoteWarningSet) RemoteOperationResult {
    return .{ .outcome = .{ .failed = failure }, .warnings = warnings };
}

fn remoteSuccessResult(success: RemoteSuccess, warnings: RemoteWarningSet) RemoteOperationResult {
    return .{ .outcome = .{ .ok = success }, .warnings = warnings };
}

fn runSensitiveRemoteCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    environment: *const std.process.Environ.Map,
    control: process_runner.ProcessControl,
    argv: []const []const u8,
) SensitiveRemoteCommand {
    const controlled = process_runner.runCapturedControlled(allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .environ_map = environment,
        .stdout_limit = .limited(max_remote_diagnostic_bytes),
        .stderr_limit = .limited(max_remote_diagnostic_bytes),
    }, .sensitive, control);
    return switch (controlled) {
        .completed => |captured| switch (captured) {
            .sensitive => |result| .{ .completed = result },
            .ordinary => unreachable,
        },
        .canceled => .canceled,
        .timed_out => .timed_out,
        .failed => |failure| .{ .failed = switch (failure) {
            .spawn => .spawn_failed,
            else => .failed,
        } },
    };
}

fn commandExited(command: *const SensitiveRemoteCommand, expected_code: u8) bool {
    return switch (command.*) {
        .completed => |result| switch (result.term) {
            .exited => |code| code == expected_code,
            else => false,
        },
        .canceled, .timed_out, .failed => false,
    };
}

fn commandFailure(command: *const SensitiveRemoteCommand, diagnose: bool) ?RemoteFailure {
    return switch (command.*) {
        .canceled => .canceled_outcome_unknown,
        .timed_out => .timed_out_outcome_unknown,
        .failed => |failure| failure,
        .completed => |result| switch (result.term) {
            .exited => |code| if (code == 0)
                null
            else if (diagnose)
                diagnoseRemoteFailure(result.stdout.bytes(), result.stderr.bytes())
            else
                .failed,
            else => if (diagnose)
                diagnoseRemoteFailure(result.stdout.bytes(), result.stderr.bytes())
            else
                .failed,
        },
    };
}

fn diagnoseRemoteFailure(stdout: []const u8, stderr: []const u8) RemoteFailure {
    const public_key_patterns = [_][]const u8{
        "permission denied (publickey",
        "no supported authentication methods available",
    };
    for (public_key_patterns) |pattern| {
        if (indexOfIgnoreCase(stdout, pattern) != null or indexOfIgnoreCase(stderr, pattern) != null)
            return .ssh_public_key;
    }

    const authentication_patterns = [_][]const u8{
        "authentication failed",
        "authentication required",
        "could not read username",
        "terminal prompts disabled",
        "http 401",
        "returned error: 401",
        "access denied",
    };
    for (authentication_patterns) |pattern| {
        if (indexOfIgnoreCase(stdout, pattern) != null or indexOfIgnoreCase(stderr, pattern) != null)
            return .authentication_required;
    }
    return .failed;
}

fn auditRemoteUrls(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    environment: *const std.process.Environ.Map,
    control: process_runner.ProcessControl,
    remote: []const u8,
    use: RemoteUrlUse,
) ?RemoteFailure {
    const effective_argv = switch (use) {
        .fetch => &[_][]const u8{ "git", "remote", "get-url", "--all", "--", remote },
        .push => &[_][]const u8{ "git", "remote", "get-url", "--push", "--all", "--", remote },
    };
    var effective = runSensitiveRemoteCommand(allocator, io, cwd, environment, control, effective_argv);
    defer effective.deinit();
    if (commandFailure(&effective, false)) |failure| return failure;
    const effective_bytes = switch (effective) {
        .completed => |*result| result.stdout.bytes(),
        else => unreachable,
    };
    switch (auditLineFramedUrls(effective_bytes)) {
        .accepted => {},
        .userinfo => return .http_userinfo_rejected,
        .invalid => return .failed,
    }

    const url_key = std.fmt.allocPrint(allocator, "remote.{s}.url", .{remote}) catch return .failed;
    defer allocator.free(url_key);
    if (auditConfigUrlValues(allocator, io, cwd, environment, control, url_key, false)) |failure| return failure;

    const pushurl_key = std.fmt.allocPrint(allocator, "remote.{s}.pushurl", .{remote}) catch return .failed;
    defer allocator.free(pushurl_key);
    if (auditConfigUrlValues(allocator, io, cwd, environment, control, pushurl_key, true)) |failure| return failure;
    return null;
}

fn auditConfigUrlValues(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    environment: *const std.process.Environ.Map,
    control: process_runner.ProcessControl,
    key: []const u8,
    optional: bool,
) ?RemoteFailure {
    const argv = [_][]const u8{ "git", "config", "--null", "--get-all", key };
    var command = runSensitiveRemoteCommand(allocator, io, cwd, environment, control, &argv);
    defer command.deinit();
    if (optional and commandExited(&command, 1)) return null;
    if (commandFailure(&command, false)) |failure| return failure;
    const bytes = switch (command) {
        .completed => |*result| result.stdout.bytes(),
        else => unreachable,
    };
    switch (auditNulFramedUrls(bytes)) {
        .accepted => return null,
        .userinfo => return .http_userinfo_rejected,
        .invalid => return .failed,
    }
}

fn auditLineFramedUrls(bytes: []const u8) UrlAudit {
    if (bytes.len == 0 or std.mem.indexOfScalar(u8, bytes, 0) != null) return .invalid;
    var count: usize = 0;
    var start: usize = 0;
    while (start < bytes.len) {
        const relative_end = std.mem.indexOfScalar(u8, bytes[start..], '\n');
        const end = if (relative_end) |offset| start + offset else bytes.len;
        const line = bytes[start..end];
        if (line.len == 0 or std.mem.indexOfScalar(u8, line, '\r') != null) return .invalid;
        count += 1;
        switch (auditRemoteUrlValue(line)) {
            .accepted => {},
            .userinfo => return .userinfo,
            .invalid => return .invalid,
        }
        start = if (relative_end == null) bytes.len else end + 1;
    }
    return if (count > 0) .accepted else .invalid;
}

fn auditNulFramedUrls(bytes: []const u8) UrlAudit {
    if (bytes.len == 0 or bytes[bytes.len - 1] != 0) return .invalid;
    var count: usize = 0;
    var start: usize = 0;
    while (start < bytes.len) {
        const relative_end = std.mem.indexOfScalar(u8, bytes[start..], 0) orelse return .invalid;
        const end = start + relative_end;
        const value = bytes[start..end];
        if (value.len == 0 or std.mem.indexOfAny(u8, value, "\r\n") != null) return .invalid;
        count += 1;
        switch (auditRemoteUrlValue(value)) {
            .accepted => {},
            .userinfo => return .userinfo,
            .invalid => return .invalid,
        }
        start = end + 1;
    }
    return if (count > 0) .accepted else .invalid;
}

fn auditRemoteUrlValue(url: []const u8) UrlAudit {
    for (url) |byte| if (byte < 0x20 or byte == 0x7f) return .invalid;
    const scheme_len: usize = if (std.ascii.startsWithIgnoreCase(url, "http://"))
        "http://".len
    else if (std.ascii.startsWithIgnoreCase(url, "https://"))
        "https://".len
    else
        return .accepted;
    const uri = std.Uri.parse(url) catch return .invalid;
    if ((!std.ascii.eqlIgnoreCase(uri.scheme, "http") and
        !std.ascii.eqlIgnoreCase(uri.scheme, "https")) or uri.host == null)
        return .invalid;
    const authority = url[scheme_len .. std.mem.indexOfAnyPos(u8, url, scheme_len, "/?#") orelse url.len];
    if (uri.user != null or uri.password != null or std.mem.indexOfScalar(u8, authority, '@') != null)
        return .userinfo;
    return .accepted;
}

fn classifyCredentialPolicy(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    environment: *const std.process.Environ.Map,
    control: process_runner.ProcessControl,
    warnings: *RemoteWarningSet,
) ?RemoteFailure {
    const helper_argv = [_][]const u8{ "git", "config", "--null", "--get-all", "credential.helper" };
    var helpers = runSensitiveRemoteCommand(allocator, io, cwd, environment, control, &helper_argv);
    defer helpers.deinit();
    if (!commandExited(&helpers, 1)) {
        if (commandFailure(&helpers, false)) |failure| return failure;
        const bytes = switch (helpers) {
            .completed => |*result| result.stdout.bytes(),
            else => unreachable,
        };
        if (!classifyHelperRecords(bytes, warnings)) return .failed;
    }

    const origin_argv = [_][]const u8{ "git", "config", "--show-origin", "--null", "--get-all", "credential.helper" };
    var origins = runSensitiveRemoteCommand(allocator, io, cwd, environment, control, &origin_argv);
    defer origins.deinit();
    if (!commandExited(&origins, 1)) {
        if (commandFailure(&origins, false)) |failure| return failure;
        const bytes = switch (origins) {
            .completed => |*result| result.stdout.bytes(),
            else => unreachable,
        };
        if (!classifyHelperOrigins(bytes, warnings)) return .failed;
    }

    const scoped_argv = [_][]const u8{ "git", "config", "--null", "--get-regexp", "^credential\\..*\\.helper$" };
    var scoped = runSensitiveRemoteCommand(allocator, io, cwd, environment, control, &scoped_argv);
    defer scoped.deinit();
    if (!commandExited(&scoped, 1)) {
        if (commandFailure(&scoped, false)) |failure| return failure;
        const bytes = switch (scoped) {
            .completed => |*result| result.stdout.bytes(),
            else => unreachable,
        };
        if (!classifyScopedHelperRecords(bytes, warnings)) return .failed;
    }

    const store_argv = [_][]const u8{ "git", "config", "--null", "--get", "credential.credentialStore" };
    var store = runSensitiveRemoteCommand(allocator, io, cwd, environment, control, &store_argv);
    defer store.deinit();
    if (!commandExited(&store, 1)) {
        if (commandFailure(&store, false)) |failure| return failure;
        const bytes = switch (store) {
            .completed => |*result| result.stdout.bytes(),
            else => unreachable,
        };
        if (nulSingleValueEquals(bytes, "plaintext")) warnings.gcm_plaintext_store = true;
    }
    if (environment.get("GCM_CREDENTIAL_STORE")) |value| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t"), "plaintext"))
            warnings.gcm_plaintext_store = true;
    }
    return null;
}

fn classifyHelperRecords(bytes: []const u8, warnings: *RemoteWarningSet) bool {
    if (bytes.len == 0) return true;
    if (bytes[bytes.len - 1] != 0) return false;
    var plaintext_active = false;
    var unknown_active = false;
    var start: usize = 0;
    while (start < bytes.len) {
        const relative_end = std.mem.indexOfScalar(u8, bytes[start..], 0) orelse return false;
        const end = start + relative_end;
        const value = std.mem.trim(u8, bytes[start..end], " \t");
        if (value.len == 0) {
            plaintext_active = false;
            unknown_active = false;
        } else if (helperIsPlaintextStore(value)) {
            plaintext_active = true;
        } else if (!helperIsKnownNonPlaintext(value)) {
            unknown_active = true;
        }
        start = end + 1;
    }
    if (plaintext_active) warnings.git_plaintext_store = true;
    if (unknown_active) warnings.helper_policy_unknown = true;
    return true;
}

fn classifyHelperOrigins(bytes: []const u8, warnings: *RemoteWarningSet) bool {
    if (bytes.len == 0) return true;
    if (bytes[bytes.len - 1] != 0) return false;
    var start: usize = 0;
    while (start < bytes.len) {
        const origin_end_offset = std.mem.indexOfScalar(u8, bytes[start..], 0) orelse return false;
        const origin_end = start + origin_end_offset;
        const origin = bytes[start..origin_end];
        start = origin_end + 1;
        if (start >= bytes.len) return false;
        const value_end_offset = std.mem.indexOfScalar(u8, bytes[start..], 0) orelse return false;
        const value = std.mem.trim(u8, bytes[start .. start + value_end_offset], " \t");
        start += value_end_offset + 1;
        if (!std.mem.startsWith(u8, origin, "file:.git/config")) {
            if (helperIsPlaintextStore(value)) {
                warnings.potential_plaintext_store = true;
            } else if (value.len > 0 and !helperIsKnownNonPlaintext(value)) {
                warnings.helper_policy_unknown = true;
            }
        }
    }
    return true;
}

fn classifyScopedHelperRecords(bytes: []const u8, warnings: *RemoteWarningSet) bool {
    if (bytes.len == 0) return true;
    if (bytes[bytes.len - 1] != 0) return false;
    var start: usize = 0;
    while (start < bytes.len) {
        const end_offset = std.mem.indexOfScalar(u8, bytes[start..], 0) orelse return false;
        const end = start + end_offset;
        const record = bytes[start..end];
        const separator = std.mem.indexOfScalar(u8, record, '\n') orelse return false;
        if (separator == 0) return false;
        const value = std.mem.trim(u8, record[separator + 1 ..], " \t");
        if (helperIsPlaintextStore(value)) {
            warnings.potential_plaintext_store = true;
        } else if (value.len > 0 and !helperIsKnownNonPlaintext(value)) {
            warnings.helper_policy_unknown = true;
        }
        start = end + 1;
    }
    return true;
}

fn helperIsPlaintextStore(value: []const u8) bool {
    const token = helperCommandToken(value) orelse return false;
    if (std.ascii.eqlIgnoreCase(token, "store")) return true;
    const base = std.fs.path.basename(token);
    return std.ascii.eqlIgnoreCase(base, "git-credential-store");
}

fn helperIsKnownNonPlaintext(value: []const u8) bool {
    const token = helperCommandToken(value) orelse return false;
    const base = std.fs.path.basename(token);
    const known = [_][]const u8{ "cache", "manager", "manager-core", "libsecret", "osxkeychain", "wincred", "oauth" };
    for (known) |candidate| {
        if (std.ascii.eqlIgnoreCase(token, candidate) or
            std.ascii.eqlIgnoreCase(base, candidate) or
            (std.mem.startsWith(u8, base, "git-credential-") and
                std.ascii.eqlIgnoreCase(base["git-credential-".len..], candidate))) return true;
    }
    return false;
}

fn helperCommandToken(value: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len == 0 or trimmed[0] == '!' or trimmed[0] == '\'' or trimmed[0] == '"') return null;
    for (trimmed) |byte| if (byte < 0x20 and byte != '\t') return null;
    const end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
    return trimmed[0..end];
}

fn nulSingleValueEquals(bytes: []const u8, expected: []const u8) bool {
    if (bytes.len == 0) return false;
    const value = if (bytes[bytes.len - 1] == 0) bytes[0 .. bytes.len - 1] else bytes;
    if (std.mem.indexOfScalar(u8, value, 0) != null) return false;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t"), expected);
}

fn runForegroundPushInspection(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: ForegroundPushInspectionRequest,
) ForegroundPushInspectionResult {
    var warnings = request.environment.warnings;
    if (auditRemoteUrls(
        allocator,
        io,
        request.root.dir(),
        &request.environment.map,
        request.control,
        request.push.remote,
        .push,
    )) |failure| return .{ .outcome = .{ .failed = failure }, .warnings = warnings };
    if (classifyCredentialPolicy(
        allocator,
        io,
        request.root.dir(),
        &request.environment.map,
        request.control,
        &warnings,
    )) |failure| return .{ .outcome = .{ .failed = failure }, .warnings = warnings };

    const refs = validatePushRefNames(
        allocator,
        io,
        request.root.dir(),
        &request.environment.map,
        request.control,
        request.push.branch,
        request.push.remote_branch,
    );
    switch (refs) {
        .valid => {},
        .invalid => return .{ .outcome = .branch_changed, .warnings = warnings },
        .failed => |failure| return .{ .outcome = .{ .failed = failure }, .warnings = warnings },
    }

    return .{
        .outcome = switch (inspectCurrentBranchAndOid(
            allocator,
            io,
            request.root.dir(),
            &request.environment.map,
            request.control,
            request.push.branch,
            request.push.oid,
        )) {
            .matches => .ready,
            .context_changed, .branch_changed => .branch_changed,
            .oid_changed => .oid_changed,
            .failed => |failure| .{ .failed = failure },
        },
        .warnings = warnings,
    };
}

const RefValidation = union(enum) {
    valid,
    invalid,
    failed: RemoteFailure,
};

fn validatePushRefNames(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    environment: *const std.process.Environ.Map,
    control: process_runner.ProcessControl,
    branch: []const u8,
    remote_branch: []const u8,
) RefValidation {
    const branch_argv = [_][]const u8{ "git", "check-ref-format", "--branch", branch };
    var branch_command = runSensitiveRemoteCommand(allocator, io, cwd, environment, control, &branch_argv);
    defer branch_command.deinit();
    switch (sensitiveExitCode(&branch_command)) {
        .code => |code| if (code != 0) return .invalid,
        .failure => |failure| return .{ .failed = failure },
    }

    const remote_ref = std.fmt.allocPrint(allocator, "refs/heads/{s}", .{remote_branch}) catch
        return .{ .failed = .failed };
    defer allocator.free(remote_ref);
    const remote_argv = [_][]const u8{ "git", "check-ref-format", remote_ref };
    var remote_command = runSensitiveRemoteCommand(allocator, io, cwd, environment, control, &remote_argv);
    defer remote_command.deinit();
    return switch (sensitiveExitCode(&remote_command)) {
        .code => |code| if (code == 0) .valid else .invalid,
        .failure => |failure| .{ .failed = failure },
    };
}

const SensitiveExitCode = union(enum) {
    code: u8,
    failure: RemoteFailure,
};

fn sensitiveExitCode(command: *const SensitiveRemoteCommand) SensitiveExitCode {
    return switch (command.*) {
        .completed => |result| switch (result.term) {
            .exited => |code| .{ .code = code },
            else => .{ .failure = .failed },
        },
        .canceled => .{ .failure = .canceled_outcome_unknown },
        .timed_out => .{ .failure = .timed_out_outcome_unknown },
        .failed => |failure| .{ .failure = failure },
    };
}

const BranchOidInspection = union(enum) {
    matches,
    context_changed,
    branch_changed,
    oid_changed,
    failed: RemoteFailure,
};

fn inspectCurrentBranchAndOid(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    environment: *const std.process.Environ.Map,
    control: process_runner.ProcessControl,
    branch: []const u8,
    oid: []const u8,
) BranchOidInspection {
    const branch_argv = [_][]const u8{ "git", "symbolic-ref", "--quiet", "HEAD" };
    var branch_command = runSensitiveRemoteCommand(allocator, io, cwd, environment, control, &branch_argv);
    defer branch_command.deinit();
    switch (sensitiveExitCode(&branch_command)) {
        .failure => |failure| return switch (failure) {
            .failed => .context_changed,
            else => .{ .failed = failure },
        },
        .code => |code| if (code != 0) return .context_changed,
    }
    const expected_branch = std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch}) catch
        return .{ .failed = .failed };
    defer allocator.free(expected_branch);
    const actual_branch = switch (branch_command) {
        .completed => |*result| trimLineEnd(result.stdout.bytes()),
        else => unreachable,
    };
    if (!std.mem.eql(u8, actual_branch, expected_branch)) return .branch_changed;

    const oid_argv = [_][]const u8{ "git", "rev-parse", "--verify", "HEAD" };
    var oid_command = runSensitiveRemoteCommand(allocator, io, cwd, environment, control, &oid_argv);
    defer oid_command.deinit();
    switch (sensitiveExitCode(&oid_command)) {
        .failure => |failure| return switch (failure) {
            .failed => .oid_changed,
            else => .{ .failed = failure },
        },
        .code => |code| if (code != 0) return .oid_changed,
    }
    const actual_oid = switch (oid_command) {
        .completed => |*result| trimLineEnd(result.stdout.bytes()),
        else => unreachable,
    };
    return if (std.mem.eql(u8, actual_oid, oid)) .matches else .oid_changed;
}

const ConfigRelation = enum {
    missing,
    expected,
    other,
    multiple,
    invalid,
};

const BooleanRelation = enum {
    missing,
    true_value,
    false_value,
    multiple,
    invalid,
};

const FinalizerReadError = error{
    VerificationFailed,
    TrackingUnknown,
};

const TrackingSnapshot = struct {
    local_remote: ConfigRelation,
    effective_remote: ConfigRelation,
    local_merge: ConfigRelation,
    effective_merge: ConfigRelation,
    local_rebase: BooleanRelation,
    effective_rebase: BooleanRelation,

    fn pairMissing(self: TrackingSnapshot) bool {
        return self.local_remote == .missing and self.effective_remote == .missing and
            self.local_merge == .missing and self.effective_merge == .missing;
    }

    fn pairExpected(self: TrackingSnapshot) bool {
        return (self.local_remote == .missing or self.local_remote == .expected) and
            self.effective_remote == .expected and
            (self.local_merge == .missing or self.local_merge == .expected) and
            self.effective_merge == .expected;
    }

    fn localAndEffectivePairExpected(self: TrackingSnapshot) bool {
        return self.local_remote == .expected and self.effective_remote == .expected and
            self.local_merge == .expected and self.effective_merge == .expected;
    }

    fn valuesAreUnambiguous(self: TrackingSnapshot) bool {
        return self.local_remote != .multiple and self.local_remote != .invalid and
            self.effective_remote != .multiple and self.effective_remote != .invalid and
            self.local_merge != .multiple and self.local_merge != .invalid and
            self.effective_merge != .multiple and self.effective_merge != .invalid and
            self.local_rebase != .multiple and self.local_rebase != .invalid and
            self.effective_rebase != .multiple and self.effective_rebase != .invalid;
    }
};

const FinalizerKeys = struct {
    expected_head: []u8,
    expected_merge: []u8,
    remote: []u8,
    merge: []u8,
    rebase: []u8,

    fn init(allocator: std.mem.Allocator, request: PushUpstreamFinalizeRequest) !FinalizerKeys {
        const expected_head = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{request.branch});
        errdefer allocator.free(expected_head);
        const expected_merge = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{request.remote_branch});
        errdefer allocator.free(expected_merge);
        const remote = try std.fmt.allocPrint(allocator, "branch.{s}.remote", .{request.branch});
        errdefer allocator.free(remote);
        const merge = try std.fmt.allocPrint(allocator, "branch.{s}.merge", .{request.branch});
        errdefer allocator.free(merge);
        const rebase = try std.fmt.allocPrint(allocator, "branch.{s}.rebase", .{request.branch});
        return .{
            .expected_head = expected_head,
            .expected_merge = expected_merge,
            .remote = remote,
            .merge = merge,
            .rebase = rebase,
        };
    }

    fn deinit(self: *FinalizerKeys, allocator: std.mem.Allocator) void {
        allocator.free(self.expected_head);
        allocator.free(self.expected_merge);
        allocator.free(self.remote);
        allocator.free(self.merge);
        allocator.free(self.rebase);
        self.* = undefined;
    }
};

fn runPushUpstreamFinalizer(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: PushUpstreamFinalizeRequest,
) PushUpstreamFinalizeOutcome {
    var keys = FinalizerKeys.init(allocator, request) catch return .config_verification_failed;
    defer keys.deinit(allocator);

    switch (validatePushRefNames(
        allocator,
        io,
        request.root.dir(),
        &request.environment.map,
        request.control,
        request.branch,
        request.remote_branch,
    )) {
        .valid => {},
        .invalid => return .context_changed,
        .failed => |failure| return finalizerFailureBeforeWrite(failure),
    }

    if (finalizerContextOutcome(allocator, io, request, false)) |outcome| return outcome;
    const desired_rebase = readAutoSetupRebase(allocator, io, request, false) catch |err|
        return finalizerReadOutcome(err);
    var snapshot = readTrackingSnapshot(allocator, io, request, &keys, false) catch |err|
        return finalizerReadOutcome(err);
    if (!snapshot.valuesAreUnambiguous()) return .config_verification_failed;

    if (snapshot.pairExpected()) {
        if (desired_rebase and snapshot.effective_rebase != .true_value)
            return .upstream_conflict;
        return .already_configured;
    }
    if (!snapshot.pairMissing()) return .upstream_conflict;

    if (finalizerContextOutcome(allocator, io, request, false)) |outcome| return outcome;
    snapshot = readTrackingSnapshot(allocator, io, request, &keys, false) catch |err|
        return finalizerReadOutcome(err);
    if (!snapshot.valuesAreUnambiguous()) return .config_verification_failed;
    if (snapshot.pairExpected()) return .upstream_conflict;
    if (!snapshot.pairMissing()) return .upstream_conflict;

    switch (writeLocalConfig(allocator, io, request, keys.remote, request.remote)) {
        .written => {},
        .failed => return .config_write_failed,
        .unknown => return .tracking_unknown,
    }

    if (finalizerContextOutcome(allocator, io, request, true)) |outcome| return outcome;
    snapshot = readTrackingSnapshot(allocator, io, request, &keys, true) catch |err|
        return finalizerReadOutcome(err);
    if (!snapshot.valuesAreUnambiguous()) return .tracking_unknown;
    if (snapshot.local_remote != .expected or snapshot.effective_remote != .expected or
        snapshot.local_merge != .missing or snapshot.effective_merge != .missing)
        return .upstream_conflict;

    switch (writeLocalConfig(allocator, io, request, keys.merge, keys.expected_merge)) {
        .written => {},
        .failed => return .config_write_failed,
        .unknown => return .tracking_unknown,
    }

    if (finalizerContextOutcome(allocator, io, request, true)) |outcome| return outcome;
    snapshot = readTrackingSnapshot(allocator, io, request, &keys, true) catch |err|
        return finalizerReadOutcome(err);
    if (!snapshot.valuesAreUnambiguous() or !snapshot.localAndEffectivePairExpected())
        return .upstream_conflict;

    if (desired_rebase and snapshot.effective_rebase != .true_value) {
        if (snapshot.effective_rebase != .missing and snapshot.effective_rebase != .false_value)
            return .upstream_conflict;
        switch (writeLocalConfig(allocator, io, request, keys.rebase, "true")) {
            .written => {},
            .failed => return .config_write_failed,
            .unknown => return .tracking_unknown,
        }
    }

    if (finalizerContextOutcome(allocator, io, request, true)) |outcome| return outcome;
    snapshot = readTrackingSnapshot(allocator, io, request, &keys, true) catch |err|
        return finalizerReadOutcome(err);
    if (!snapshot.valuesAreUnambiguous() or !snapshot.localAndEffectivePairExpected())
        return .config_verification_failed;
    if (desired_rebase and
        (snapshot.local_rebase != .true_value or snapshot.effective_rebase != .true_value))
        return .config_verification_failed;
    return .configured;
}

fn finalizerFailureBeforeWrite(failure: RemoteFailure) PushUpstreamFinalizeOutcome {
    return switch (failure) {
        .canceled_outcome_unknown, .timed_out_outcome_unknown => .tracking_unknown,
        else => .config_verification_failed,
    };
}

fn finalizerReadOutcome(err: FinalizerReadError) PushUpstreamFinalizeOutcome {
    return switch (err) {
        error.VerificationFailed => .config_verification_failed,
        error.TrackingUnknown => .tracking_unknown,
    };
}

fn finalizerContextOutcome(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: PushUpstreamFinalizeRequest,
    mutation_started: bool,
) ?PushUpstreamFinalizeOutcome {
    return switch (inspectCurrentBranchAndOid(
        allocator,
        io,
        request.root.dir(),
        &request.environment.map,
        request.control,
        request.branch,
        request.oid,
    )) {
        .matches => null,
        .context_changed => .context_changed,
        .branch_changed => .branch_changed,
        .oid_changed => .oid_changed,
        .failed => |failure| if (mutation_started)
            .tracking_unknown
        else
            finalizerFailureBeforeWrite(failure),
    };
}

fn readAutoSetupRebase(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: PushUpstreamFinalizeRequest,
    mutation_started: bool,
) FinalizerReadError!bool {
    const argv = [_][]const u8{ "git", "config", "--null", "--get-all", "branch.autoSetupRebase" };
    var command = runSensitiveRemoteCommand(allocator, io, request.root.dir(), &request.environment.map, request.control, &argv);
    defer command.deinit();
    switch (sensitiveExitCode(&command)) {
        .failure => |failure| return finalizerReadFailure(failure, mutation_started),
        .code => |code| {
            if (code == 1) return false;
            if (code != 0) return error.VerificationFailed;
        },
    }
    const bytes = switch (command) {
        .completed => |*result| result.stdout.bytes(),
        else => unreachable,
    };
    const value = singleNulValue(bytes) orelse return error.VerificationFailed;
    if (std.ascii.eqlIgnoreCase(value, "remote") or std.ascii.eqlIgnoreCase(value, "always")) return true;
    if (std.ascii.eqlIgnoreCase(value, "never") or std.ascii.eqlIgnoreCase(value, "local")) return false;
    return error.VerificationFailed;
}

fn readTrackingSnapshot(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: PushUpstreamFinalizeRequest,
    keys: *const FinalizerKeys,
    mutation_started: bool,
) FinalizerReadError!TrackingSnapshot {
    return .{
        .local_remote = try readConfigRelation(allocator, io, request, true, keys.remote, request.remote, mutation_started),
        .effective_remote = try readConfigRelation(allocator, io, request, false, keys.remote, request.remote, mutation_started),
        .local_merge = try readConfigRelation(allocator, io, request, true, keys.merge, keys.expected_merge, mutation_started),
        .effective_merge = try readConfigRelation(allocator, io, request, false, keys.merge, keys.expected_merge, mutation_started),
        .local_rebase = try readBooleanRelation(allocator, io, request, true, keys.rebase, mutation_started),
        .effective_rebase = try readBooleanRelation(allocator, io, request, false, keys.rebase, mutation_started),
    };
}

fn readConfigRelation(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: PushUpstreamFinalizeRequest,
    local: bool,
    key: []const u8,
    expected: []const u8,
    mutation_started: bool,
) FinalizerReadError!ConfigRelation {
    const local_argv = [_][]const u8{ "git", "config", "--local", "--null", "--get-all", key };
    const effective_argv = [_][]const u8{ "git", "config", "--null", "--get-all", key };
    const argv: []const []const u8 = if (local) &local_argv else &effective_argv;
    var command = runSensitiveRemoteCommand(allocator, io, request.root.dir(), &request.environment.map, request.control, argv);
    defer command.deinit();
    switch (sensitiveExitCode(&command)) {
        .failure => |failure| return finalizerReadFailure(failure, mutation_started),
        .code => |code| {
            if (code == 1) return .missing;
            if (code != 0) return error.VerificationFailed;
        },
    }
    const bytes = switch (command) {
        .completed => |*result| result.stdout.bytes(),
        else => unreachable,
    };
    return configRelationFromBytes(bytes, expected);
}

fn readBooleanRelation(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: PushUpstreamFinalizeRequest,
    local: bool,
    key: []const u8,
    mutation_started: bool,
) FinalizerReadError!BooleanRelation {
    const local_argv = [_][]const u8{ "git", "config", "--local", "--bool", "--null", "--get-all", key };
    const effective_argv = [_][]const u8{ "git", "config", "--bool", "--null", "--get-all", key };
    const argv: []const []const u8 = if (local) &local_argv else &effective_argv;
    var command = runSensitiveRemoteCommand(allocator, io, request.root.dir(), &request.environment.map, request.control, argv);
    defer command.deinit();
    switch (sensitiveExitCode(&command)) {
        .failure => |failure| return finalizerReadFailure(failure, mutation_started),
        .code => |code| {
            if (code == 1) return .missing;
            if (code != 0) return error.VerificationFailed;
        },
    }
    const bytes = switch (command) {
        .completed => |*result| result.stdout.bytes(),
        else => unreachable,
    };
    const value = singleNulValue(bytes) orelse return if (countNulValues(bytes) > 1) .multiple else .invalid;
    if (std.ascii.eqlIgnoreCase(value, "true")) return .true_value;
    if (std.ascii.eqlIgnoreCase(value, "false")) return .false_value;
    return .invalid;
}

fn finalizerReadFailure(failure: RemoteFailure, mutation_started: bool) FinalizerReadError {
    if (mutation_started or failure == .canceled_outcome_unknown or failure == .timed_out_outcome_unknown)
        return error.TrackingUnknown;
    return error.VerificationFailed;
}

fn configRelationFromBytes(bytes: []const u8, expected: []const u8) ConfigRelation {
    const value = singleNulValue(bytes) orelse return if (countNulValues(bytes) > 1) .multiple else .invalid;
    return if (std.mem.eql(u8, value, expected)) .expected else .other;
}

fn singleNulValue(bytes: []const u8) ?[]const u8 {
    if (bytes.len == 0 or bytes[bytes.len - 1] != 0) return null;
    if (std.mem.indexOfScalar(u8, bytes[0 .. bytes.len - 1], 0) != null) return null;
    return bytes[0 .. bytes.len - 1];
}

fn countNulValues(bytes: []const u8) usize {
    if (bytes.len == 0 or bytes[bytes.len - 1] != 0) return 0;
    return std.mem.count(u8, bytes, &.{0});
}

const ConfigWriteResult = enum { written, failed, unknown };

fn writeLocalConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: PushUpstreamFinalizeRequest,
    key: []const u8,
    value: []const u8,
) ConfigWriteResult {
    const argv = [_][]const u8{ "git", "config", "--local", "--replace-all", key, value };
    var command = runSensitiveRemoteCommand(allocator, io, request.root.dir(), &request.environment.map, request.control, &argv);
    defer command.deinit();
    return switch (sensitiveExitCode(&command)) {
        .code => |code| if (code == 0) .written else .failed,
        .failure => |failure| if (failure == .spawn_failed) .failed else .unknown,
    };
}

fn runSecureGitPush(
    allocator: std.mem.Allocator,
    io: std.Io,
    operation: RemoteOperationRequest,
    request: PushRequest,
    warnings: RemoteWarningSet,
) RemoteOperationResult {
    switch (secureRemoteBranchSnapshotMatches(allocator, io, operation, request.branch, request.oid)) {
        .matches => {},
        .mismatch => return remoteFailureResult(.failed, warnings),
        .failed => |failure| return remoteFailureResult(failure, warnings),
    }

    const refspec = std.fmt.allocPrint(allocator, "refs/heads/{s}:refs/heads/{s}", .{ request.branch, request.remote_branch }) catch
        return remoteFailureResult(.failed, warnings);
    defer allocator.free(refspec);
    const upstream_argv = [_][]const u8{
        "git",   "-c",                           "credential.interactive=false", "-c",                     "credential.trace=false", "-c", "credential.traceSecrets=false",
        "-c",    "credential.traceMsAuth=false", "-c",                           "credential.debug=false", "push",                   "--", request.remote,
        refspec,
    };
    const set_upstream_argv = [_][]const u8{
        "git",          "-c",                           "credential.interactive=false", "-c",                     "credential.trace=false", "-c",             "credential.traceSecrets=false",
        "-c",           "credential.traceMsAuth=false", "-c",                           "credential.debug=false", "push",                   "--set-upstream", "--",
        request.remote, refspec,
    };
    const argv: []const []const u8 = if (request.mode == .set_upstream) &set_upstream_argv else &upstream_argv;
    var command = runSensitiveRemoteCommand(allocator, io, operation.root.dir(), &operation.environment.map, operation.control, argv);
    defer command.deinit();
    if (commandFailure(&command, true)) |failure| return remoteFailureResult(failure, warnings);
    return remoteSuccessResult(.completed, warnings);
}

fn runSecureGitFetch(
    allocator: std.mem.Allocator,
    io: std.Io,
    operation: RemoteOperationRequest,
    request: FetchRequest,
    warnings: RemoteWarningSet,
) RemoteOperationResult {
    const argv = [_][]const u8{
        "git", "-c",                           "credential.interactive=false", "-c",                     "credential.trace=false", "-c", "credential.traceSecrets=false",
        "-c",  "credential.traceMsAuth=false", "-c",                           "credential.debug=false", "fetch",                  "--", request.remote,
    };
    var command = runSensitiveRemoteCommand(allocator, io, operation.root.dir(), &operation.environment.map, operation.control, &argv);
    defer command.deinit();
    if (commandFailure(&command, true)) |failure| return remoteFailureResult(failure, warnings);
    return remoteSuccessResult(.completed, warnings);
}

fn runSecureGitPull(
    allocator: std.mem.Allocator,
    io: std.Io,
    operation: RemoteOperationRequest,
    request: PullRequest,
    warnings: RemoteWarningSet,
) RemoteOperationResult {
    switch (securePullPreconditionsMatch(allocator, io, operation, request)) {
        .matches => {},
        .mismatch => return remoteFailureResult(.failed, warnings),
        .failed => |failure| return remoteFailureResult(failure, warnings),
    }

    const fetch_argv = [_][]const u8{
        "git", "-c",                           "credential.interactive=false", "-c",                     "credential.trace=false", "-c", "credential.traceSecrets=false",
        "-c",  "credential.traceMsAuth=false", "-c",                           "credential.debug=false", "fetch",                  "--", request.remote,
    };
    var fetch = runSensitiveRemoteCommand(allocator, io, operation.root.dir(), &operation.environment.map, operation.control, &fetch_argv);
    defer fetch.deinit();
    if (commandFailure(&fetch, true)) |failure| return remoteFailureResult(failure, warnings);

    switch (securePullPreconditionsMatch(allocator, io, operation, request)) {
        .matches => {},
        .mismatch => return remoteFailureResult(.failed, warnings),
        .failed => |failure| return remoteFailureResult(failure, warnings),
    }

    const remote_ref = std.fmt.allocPrint(allocator, "refs/remotes/{s}/{s}", .{ request.remote, request.remote_branch }) catch
        return remoteFailureResult(.failed, warnings);
    defer allocator.free(remote_ref);
    const spec = std.fmt.allocPrint(allocator, "HEAD...{s}", .{remote_ref}) catch
        return remoteFailureResult(.failed, warnings);
    defer allocator.free(spec);
    const ahead_behind_argv = [_][]const u8{ "git", "rev-list", "--left-right", "--count", spec };
    var ahead_behind_command = runSensitiveRemoteCommand(allocator, io, operation.root.dir(), &operation.environment.map, operation.control, &ahead_behind_argv);
    defer ahead_behind_command.deinit();
    if (commandFailure(&ahead_behind_command, false)) |failure| return remoteFailureResult(failure, warnings);
    const ahead_behind_bytes = switch (ahead_behind_command) {
        .completed => |*result| result.stdout.bytes(),
        else => unreachable,
    };
    const ahead_behind = parseRevListAheadBehind(ahead_behind_bytes) catch
        return remoteFailureResult(.failed, warnings);
    if (ahead_behind.ahead == 0 and ahead_behind.behind == 0)
        return remoteSuccessResult(.already_up_to_date, warnings);
    if (ahead_behind.ahead != 0) return remoteFailureResult(.failed, warnings);

    const merge_argv = [_][]const u8{ "git", "merge", "--ff-only", remote_ref };
    var merge = runSensitiveRemoteCommand(allocator, io, operation.root.dir(), &operation.environment.map, operation.control, &merge_argv);
    defer merge.deinit();
    if (commandFailure(&merge, false)) |failure| return remoteFailureResult(failure, warnings);
    return remoteSuccessResult(.completed, warnings);
}

fn securePullPreconditionsMatch(
    allocator: std.mem.Allocator,
    io: std.Io,
    operation: RemoteOperationRequest,
    request: PullRequest,
) RemoteCheck {
    switch (secureRemoteBranchSnapshotMatches(allocator, io, operation, request.branch, request.oid)) {
        .matches => {},
        .mismatch => return .mismatch,
        .failed => |failure| return .{ .failed = failure },
    }

    const upstream_argv = [_][]const u8{ "git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}" };
    var upstream = runSensitiveRemoteCommand(allocator, io, operation.root.dir(), &operation.environment.map, operation.control, &upstream_argv);
    defer upstream.deinit();
    if (commandFailure(&upstream, false)) |failure| return .{ .failed = failure };
    const actual = switch (upstream) {
        .completed => |*result| trimLineEnd(result.stdout.bytes()),
        else => unreachable,
    };
    const expected = std.fmt.allocPrint(allocator, "{s}/{s}", .{ request.remote, request.remote_branch }) catch return .{ .failed = .failed };
    defer allocator.free(expected);
    if (!std.mem.eql(u8, actual, expected)) return .mismatch;

    const status_argv = [_][]const u8{ "git", "status", "--porcelain=v1", "-z", "-uall" };
    var status = runSensitiveRemoteCommand(allocator, io, operation.root.dir(), &operation.environment.map, operation.control, &status_argv);
    defer status.deinit();
    if (commandFailure(&status, false)) |failure| return .{ .failed = failure };
    return switch (status) {
        .completed => |*result| if (result.stdout.bytes().len == 0) .matches else .mismatch,
        else => unreachable,
    };
}

fn secureRemoteBranchSnapshotMatches(
    allocator: std.mem.Allocator,
    io: std.Io,
    operation: RemoteOperationRequest,
    branch: []const u8,
    oid: []const u8,
) RemoteCheck {
    const branch_argv = [_][]const u8{ "git", "symbolic-ref", "--quiet", "--short", "HEAD" };
    var branch_command = runSensitiveRemoteCommand(allocator, io, operation.root.dir(), &operation.environment.map, operation.control, &branch_argv);
    defer branch_command.deinit();
    if (commandFailure(&branch_command, false)) |failure| return .{ .failed = failure };
    const actual_branch = switch (branch_command) {
        .completed => |*result| trimLineEnd(result.stdout.bytes()),
        else => unreachable,
    };
    if (!std.mem.eql(u8, actual_branch, branch)) return .mismatch;

    const oid_argv = [_][]const u8{ "git", "rev-parse", "--verify", "HEAD" };
    var oid_command = runSensitiveRemoteCommand(allocator, io, operation.root.dir(), &operation.environment.map, operation.control, &oid_argv);
    defer oid_command.deinit();
    if (commandFailure(&oid_command, false)) |failure| return .{ .failed = failure };
    const actual_oid = switch (oid_command) {
        .completed => |*result| trimLineEnd(result.stdout.bytes()),
        else => unreachable,
    };
    return if (std.mem.eql(u8, actual_oid, oid)) .matches else .mismatch;
}

fn runGitSwitchBranch(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, request: SwitchBranchRequest) git_command.Error!OperationResult {
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

fn verifyRemoteBranchSnapshot(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, branch: []const u8, oid: []const u8) git_command.Error!bool {
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

fn verifyBranchOid(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, branch: []const u8, oid: []const u8) git_command.Error!bool {
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

fn verifyCleanWorktree(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8) git_command.Error!bool {
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

/// Build a remote-child environment from the reviewed non-secret allowlist.
///
/// This is intentionally not an ambient clone. The returned map owns every
/// key/value and can be released immediately after a synchronous child call or
/// after Chasen has deep-copied a foreground request.
pub fn buildRemoteEnvironment(
    allocator: std.mem.Allocator,
    parent: ?*const std.process.Environ.Map,
    mode: RemoteEnvironmentMode,
) std.mem.Allocator.Error!OwnedRemoteEnvironment {
    var owned: OwnedRemoteEnvironment = .{
        .map = std.process.Environ.Map.init(allocator),
    };
    errdefer owned.deinit();

    if (parent) |source| {
        const local_exact = [_][]const u8{
            "PATH",
            "HOME",
            "LANG",
            "LANGUAGE",
            "TZ",
            "XDG_CONFIG_HOME",
            "XDG_DATA_HOME",
            "XDG_CACHE_HOME",
            "XDG_RUNTIME_DIR",
        };
        for (local_exact) |key| try copyRemoteEnvironmentKey(&owned.map, source, key);
        for (source.keys(), source.values()) |key, value|
            if (isLocaleEnvironmentKey(key)) try owned.map.put(key, value);

        const remote_exact = [_][]const u8{
            "USER",
            "LOGNAME",
            "SHELL",
            "TMPDIR",
            "SSH_AUTH_SOCK",
            "SSH_AGENT_PID",
            "GNUPGHOME",
            "DBUS_SESSION_BUS_ADDRESS",
            "SSL_CERT_FILE",
            "SSL_CERT_DIR",
            "GCM_CREDENTIAL_STORE",
            "GCM_CREDENTIAL_CACHE_OPTIONS",
            "GCM_PLAINTEXT_STORE_PATH",
            "GCM_DPAPI_STORE_PATH",
            "GCM_GPG_PATH",
            "GCM_PROVIDER",
            "GCM_AUTODETECT_TIMEOUT",
            "GCM_MSAUTH_FLOW",
        };
        if (mode != .local_finalizer) {
            for (remote_exact) |key| try copyRemoteEnvironmentKey(&owned.map, source, key);

            const proxy_keys = [_][]const u8{
                "HTTP_PROXY",
                "HTTPS_PROXY",
                "ALL_PROXY",
                "NO_PROXY",
                "http_proxy",
                "https_proxy",
                "all_proxy",
                "no_proxy",
            };
            for (proxy_keys) |key| {
                const value = source.get(key) orelse continue;
                if (proxyContainsUserInfo(value)) {
                    owned.warnings.proxy_credentials_omitted = true;
                } else {
                    try owned.map.put(key, value);
                }
            }
        }
        if (mode == .foreground) {
            const foreground_exact = [_][]const u8{
                "XDG_CURRENT_DESKTOP",
                "XDG_SESSION_TYPE",
                "DISPLAY",
                "WAYLAND_DISPLAY",
                "BROWSER",
                "TERM",
                "COLORTERM",
                "SSH_TTY",
                "GPG_TTY",
                "GCM_GUI_PROMPT",
            };
            for (foreground_exact) |key| try copyRemoteEnvironmentKey(&owned.map, source, key);
        }
    }

    switch (mode) {
        .background, .inspection => {
            try owned.map.put("GIT_TERMINAL_PROMPT", "0");
            try owned.map.put("GCM_INTERACTIVE", "0");
            try owned.map.put("GCM_GUI_PROMPT", "0");
            try owned.map.put("GIT_SSH_COMMAND", "ssh -o BatchMode=yes");
        },
        .foreground => try owned.map.put("GCM_INTERACTIVE", "1"),
        .local_finalizer => {
            try owned.map.put("GIT_TERMINAL_PROMPT", "0");
            try owned.map.put("GCM_INTERACTIVE", "0");
            try owned.map.put("GCM_GUI_PROMPT", "0");
        },
    }
    return owned;
}

fn copyRemoteEnvironmentKey(
    destination: *std.process.Environ.Map,
    source: *const std.process.Environ.Map,
    key: []const u8,
) std.mem.Allocator.Error!void {
    if (source.get(key)) |value| try destination.put(key, value);
}

fn isLocaleEnvironmentKey(key: []const u8) bool {
    return switch (builtin.os.tag) {
        .windows => std.ascii.startsWithIgnoreCase(key, "LC_"),
        else => std.mem.startsWith(u8, key, "LC_"),
    };
}

fn proxyContainsUserInfo(value: []const u8) bool {
    if (std.Uri.parse(value)) |uri| {
        if (uri.user != null or uri.password != null) return true;
        if (uri.host != null) return false;
    } else |_| {}

    var authority = value;
    if (std.mem.indexOf(u8, authority, "://")) |scheme_end| authority = authority[scheme_end + 3 ..];
    const authority_end = std.mem.indexOfAny(u8, authority, "/?#") orelse authority.len;
    return std.mem.indexOfScalar(u8, authority[0..authority_end], '@') != null;
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

fn runGitCommitLike(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, request: CommitRequest, amend: bool) git_command.Error!OperationResult {
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

test "stdin admission Git mapping fails closed on concurrency start failure" {
    try std.testing.expectError(error.SpawnFailed, operationResultFromGitStdinCommand(std.testing.allocator, .{
        .failed = .{ .stdin_start = error.ConcurrencyUnavailable },
    }, "git apply --cached"));
}

test "stdin admission Git mapping reaches writer failure with real early-discard child" {
    const stdin = try std.testing.allocator.alloc(u8, 256 * 1024);
    defer std.testing.allocator.free(stdin);
    @memset(stdin, 'i');

    const argv = [_][]const u8{
        "/bin/sh",
        "-c",
        "exec 0<&-; printf stdin-prong-diagnostic >&2; exit 7",
    };
    var detailed = try process_runner.runWithStdinDetailed(std.testing.allocator, std.testing.io, .{
        .argv = &argv,
        .stdin = stdin,
        .stdout_limit = .limited(64),
        .stderr_limit = .limited(1024),
    });
    var detailed_owned = true;
    defer if (detailed_owned) detailed.deinit(std.testing.allocator);

    switch (detailed) {
        .failed => |failure| switch (failure) {
            .stdin => |stdin_failure| {
                try std.testing.expectEqualStrings("stdin-prong-diagnostic", stdin_failure.result.stderr);
                try std.testing.expectEqual(std.process.Child.Term{ .exited = 7 }, stdin_failure.result.term);
            },
            else => return error.ExpectedStdinFailure,
        },
        .ok => return error.ExpectedStdinFailure,
    }

    detailed_owned = false;
    const result = try operationResultFromGitStdinCommand(std.testing.allocator, detailed, "git apply --cached");
    defer result.deinit(std.testing.allocator);
    switch (result) {
        .failed => |message| try std.testing.expectEqualStrings("stdin-prong-diagnostic", message),
        else => return error.ExpectedGitDiagnosticFailure,
    }
}

test "stdin admission Git mapping keeps writer error with zero-exit warning" {
    const stdout = try std.testing.allocator.dupe(u8, "ignored");
    const stderr = std.testing.allocator.dupe(u8, "warning: partial input") catch |err| {
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
            try std.testing.expect(std.mem.indexOf(u8, message, "WriteFailed") != null);
            try std.testing.expect(std.mem.indexOf(u8, message, "exited = 0") != null);
            try std.testing.expect(std.mem.indexOf(u8, message, "warning: partial input") != null);
        },
        else => return error.ExpectedGitStdinFailure,
    }
}

fn writeExecutableRemoteTestScript(
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    contents: []const u8,
) !void {
    try dir.writeFile(io, .{
        .sub_path = sub_path,
        .data = contents,
        .flags = .{ .permissions = .executable_file },
    });
}

fn runBackgroundCredentialFill(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    environment: *const std.process.Environ.Map,
    control: process_runner.ProcessControl,
) SensitiveRemoteCommand {
    const argv = [_][]const u8{
        "sh",
        "-c",
        "printf 'protocol=https\\nhost=example.invalid\\n\\n' | git -c credential.interactive=false credential fill",
    };
    return runSensitiveRemoteCommand(allocator, io, cwd, environment, control, &argv);
}

fn configureRemoteTestHelper(
    allocator: std.mem.Allocator,
    io: std.Io,
    work: std.Io.Dir,
    helper_path: []const u8,
) !void {
    const helper = try std.fmt.allocPrint(allocator, "!{s}", .{helper_path});
    defer allocator.free(helper);
    try runTestGit(io, &.{ "git", "config", "--local", "--replace-all", "credential.helper", "" }, work);
    try runTestGit(io, &.{ "git", "config", "--local", "--add", "credential.helper", helper }, work);
}

test "foreground and background remote operation environment own the exact allowlist" {
    const allocator = std.testing.allocator;
    var parent = std.process.Environ.Map.init(allocator);
    defer parent.deinit();

    try parent.put("PATH", "/usr/bin:/bin");
    try parent.put("HOME", "/home/test");
    try parent.put("LC_TIME", "C");
    try parent.put("XDG_RUNTIME_DIR", "/run/user/test");
    try parent.put("SSH_AUTH_SOCK", "/run/agent.sock");
    try parent.put("DBUS_SESSION_BUS_ADDRESS", "unix:path=/run/dbus");
    try parent.put("SSL_CERT_FILE", "/etc/certs.pem");
    try parent.put("TERM", "xterm-256color");
    try parent.put("DISPLAY", ":0");
    try parent.put("GCM_GUI_PROMPT", "true");
    try parent.put("GCM_CREDENTIAL_STORE", "secretservice");

    try parent.put("XDG_STATE_HOME", "/forbidden/state");
    try parent.put("GIT_DIR", "/forbidden/repo");
    try parent.put("GIT_WORK_TREE", "/forbidden/worktree");
    try parent.put("GIT_CONFIG_COUNT", "1");
    try parent.put("GIT_CONFIG_KEY_0", "http.extraHeader");
    try parent.put("GIT_CONFIG_VALUE_0", "Authorization: CONFIG-SECRET-CANARY");
    try parent.put("GCM_TRACE", "1");
    try parent.put("GCM_DEBUG", "1");
    try parent.put("GCM_AZREPOS_SP_SECRET", "GCM-SECRET-CANARY");
    try parent.put("GITHUB_TOKEN", "PROVIDER-SECRET-CANARY");
    try parent.put("GCM_INTERACTIVE", "0");

    var background = try buildRemoteEnvironment(allocator, &parent, .background);
    defer background.deinit();
    try std.testing.expectEqualStrings("/home/test", background.map.get("HOME").?);
    try std.testing.expectEqualStrings("C", background.map.get("LC_TIME").?);
    try std.testing.expectEqualStrings("/run/agent.sock", background.map.get("SSH_AUTH_SOCK").?);
    try std.testing.expectEqualStrings("unix:path=/run/dbus", background.map.get("DBUS_SESSION_BUS_ADDRESS").?);
    try std.testing.expectEqualStrings("/etc/certs.pem", background.map.get("SSL_CERT_FILE").?);
    try std.testing.expectEqualStrings("secretservice", background.map.get("GCM_CREDENTIAL_STORE").?);
    try std.testing.expect(background.map.get("TERM") == null);
    try std.testing.expect(background.map.get("DISPLAY") == null);
    try std.testing.expectEqualStrings("0", background.map.get("GCM_GUI_PROMPT").?);
    try std.testing.expectEqualStrings("0", background.map.get("GCM_INTERACTIVE").?);
    try std.testing.expectEqualStrings("0", background.map.get("GIT_TERMINAL_PROMPT").?);
    try std.testing.expectEqualStrings("ssh -o BatchMode=yes", background.map.get("GIT_SSH_COMMAND").?);

    var foreground = try buildRemoteEnvironment(allocator, &parent, .foreground);
    defer foreground.deinit();
    try std.testing.expectEqualStrings("xterm-256color", foreground.map.get("TERM").?);
    try std.testing.expectEqualStrings(":0", foreground.map.get("DISPLAY").?);
    try std.testing.expectEqualStrings("true", foreground.map.get("GCM_GUI_PROMPT").?);
    try std.testing.expectEqualStrings("1", foreground.map.get("GCM_INTERACTIVE").?);

    var local_finalizer = try buildRemoteEnvironment(allocator, &parent, .local_finalizer);
    defer local_finalizer.deinit();
    try std.testing.expectEqualStrings("/usr/bin:/bin", local_finalizer.map.get("PATH").?);
    try std.testing.expectEqualStrings("/home/test", local_finalizer.map.get("HOME").?);
    try std.testing.expectEqualStrings("C", local_finalizer.map.get("LC_TIME").?);
    try std.testing.expectEqualStrings("/run/user/test", local_finalizer.map.get("XDG_RUNTIME_DIR").?);
    try std.testing.expectEqualStrings("0", local_finalizer.map.get("GIT_TERMINAL_PROMPT").?);
    try std.testing.expectEqualStrings("0", local_finalizer.map.get("GCM_INTERACTIVE").?);
    try std.testing.expectEqualStrings("0", local_finalizer.map.get("GCM_GUI_PROMPT").?);
    const local_forbidden = [_][]const u8{
        "SSH_AUTH_SOCK",
        "SSH_AGENT_PID",
        "DBUS_SESSION_BUS_ADDRESS",
        "SSL_CERT_FILE",
        "GCM_CREDENTIAL_STORE",
        "GCM_PROVIDER",
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "TERM",
        "DISPLAY",
        "GIT_DIR",
        "GIT_CONFIG_COUNT",
    };
    for (local_forbidden) |key| try std.testing.expect(local_finalizer.map.get(key) == null);

    const forbidden = [_][]const u8{
        "XDG_STATE_HOME",
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_CONFIG_COUNT",
        "GIT_CONFIG_KEY_0",
        "GIT_CONFIG_VALUE_0",
        "GCM_TRACE",
        "GCM_DEBUG",
        "GCM_AZREPOS_SP_SECRET",
        "GITHUB_TOKEN",
    };
    for (forbidden) |key| {
        try std.testing.expect(background.map.get(key) == null);
        try std.testing.expect(foreground.map.get(key) == null);
    }

    try parent.put("HOME", "/changed");
    try std.testing.expectEqualStrings("/home/test", foreground.map.get("HOME").?);
}

test "remote authentication blocks GUI interaction and bounds a noncooperating credential helper" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "home", .default_dir);
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);

    try writeExecutableRemoteTestScript(io, tmp.dir, "cooperating-helper", "#!/bin/sh\n" ++
        ": > \"$HOME/helper-invoked\"\n" ++
        "if [ -n \"${DISPLAY:-}${WAYLAND_DISPLAY:-}${BROWSER:-}${COLORTERM:-}${SSH_TTY:-}${GPG_TTY:-}\" ]; then\n" ++
        "  : > \"$HOME/gui-attempted\"\n" ++
        "fi\n" ++
        "if [ \"${GIT_TERMINAL_PROMPT:-}\" != 0 ] || [ \"${GCM_INTERACTIVE:-}\" != 0 ] || [ \"${GCM_GUI_PROMPT:-}\" != 0 ]; then\n" ++
        "  : > \"$HOME/interaction-enabled\"\n" ++
        "fi\n" ++
        "exit 1\n");
    const helper_path = try tmp.dir.realPathFileAlloc(io, "cooperating-helper", allocator);
    defer allocator.free(helper_path);
    try configureRemoteTestHelper(allocator, io, work, helper_path);

    const home_root = try tmp.dir.realPathFileAlloc(io, "home", allocator);
    defer allocator.free(home_root);
    var parent = std.process.Environ.Map.init(allocator);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin:/bin");
    try parent.put("HOME", home_root);
    try parent.put("DISPLAY", ":99");
    try parent.put("WAYLAND_DISPLAY", "wayland-canary");
    try parent.put("BROWSER", "browser-canary");
    try parent.put("TERM", "xterm-canary");
    try parent.put("COLORTERM", "truecolor-canary");
    try parent.put("SSH_TTY", "/dev/pts/canary");
    try parent.put("GPG_TTY", "/dev/pts/gpg-canary");
    var environment = try buildRemoteEnvironment(allocator, &parent, .background);
    defer environment.deinit();

    var denied = runBackgroundCredentialFill(allocator, io, work, &environment.map, .{});
    defer denied.deinit();
    try std.testing.expectEqual(RemoteFailure.failed, commandFailure(&denied, true).?);
    try tmp.dir.access(io, "home/helper-invoked", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "home/gui-attempted", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "home/interaction-enabled", .{}));

    try writeExecutableRemoteTestScript(io, tmp.dir, "hanging-helper", "#!/bin/sh\n" ++
        ": > \"$HOME/hanging-helper-invoked\"\n" ++
        "trap '' TERM\n" ++
        "while :; do sleep 1; done\n");
    const hanging_path = try tmp.dir.realPathFileAlloc(io, "hanging-helper", allocator);
    defer allocator.free(hanging_path);
    try configureRemoteTestHelper(allocator, io, work, hanging_path);
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = .fromMilliseconds(250),
        .clock = .awake,
    });
    var timed_out = runBackgroundCredentialFill(allocator, io, work, &environment.map, .{ .deadline = deadline });
    defer timed_out.deinit();
    try std.testing.expect(timed_out == .timed_out);
    try tmp.dir.access(io, "home/hanging-helper-invoked", .{});
}

test "remote authentication uses a DBus cached libsecret-equivalent helper without GUI discovery" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "home", .default_dir);
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);

    try writeExecutableRemoteTestScript(io, tmp.dir, "libsecret-fixture", "#!/bin/sh\n" ++
        "if [ -n \"${DISPLAY:-}${WAYLAND_DISPLAY:-}${BROWSER:-}${GPG_TTY:-}\" ]; then\n" ++
        "  : > \"$HOME/libsecret-gui-attempted\"\n" ++
        "  exit 1\n" ++
        "fi\n" ++
        "[ \"${DBUS_SESSION_BUS_ADDRESS:-}\" = \"unix:path=$HOME/session-bus\" ] || exit 1\n" ++
        "printf 'username=dbus-user\\npassword=DBUS-CACHED-CREDENTIAL-CANARY\\n'\n");
    const helper_path = try tmp.dir.realPathFileAlloc(io, "libsecret-fixture", allocator);
    defer allocator.free(helper_path);
    try configureRemoteTestHelper(allocator, io, work, helper_path);

    const home_root = try tmp.dir.realPathFileAlloc(io, "home", allocator);
    defer allocator.free(home_root);
    const dbus_address = try std.fmt.allocPrint(allocator, "unix:path={s}/session-bus", .{home_root});
    defer allocator.free(dbus_address);
    var parent = std.process.Environ.Map.init(allocator);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin:/bin");
    try parent.put("HOME", home_root);
    try parent.put("DBUS_SESSION_BUS_ADDRESS", dbus_address);
    try parent.put("DISPLAY", ":99");
    try parent.put("BROWSER", "browser-canary");
    try parent.put("TERM", "terminal-canary");
    var environment = try buildRemoteEnvironment(allocator, &parent, .background);
    defer environment.deinit();

    try std.testing.expectEqualStrings(dbus_address, environment.map.get("DBUS_SESSION_BUS_ADDRESS").?);
    var command = runBackgroundCredentialFill(allocator, io, work, &environment.map, .{});
    defer command.deinit();
    try std.testing.expect(commandFailure(&command, true) == null);
    const output = switch (command) {
        .completed => |*result| result.stdout.bytes(),
        else => return error.ExpectedDbusCredential,
    };
    try std.testing.expect(std.mem.indexOf(u8, output, "username=dbus-user") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "password=DBUS-CACHED-CREDENTIAL-CANARY") != null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "home/libsecret-gui-attempted", .{}));
}

test "credential helper requiring an omitted key returns only a fixed sensitive diagnostic" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "home", .default_dir);
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);

    try writeExecutableRemoteTestScript(io, tmp.dir, "custom-key-helper", "#!/bin/sh\n" ++
        "if [ -n \"${CUSTOM_HELPER_TOKEN:-}\" ]; then\n" ++
        "  printf 'username=ambient-user\\npassword=%s\\n' \"$CUSTOM_HELPER_TOKEN\"\n" ++
        "  exit 0\n" ++
        "fi\n" ++
        "printf '%s\\n' 'Authorization: Bearer OMITTED-AUTH-CANARY' 'password=OMITTED-PASSWORD-CANARY' 'OMITTED-ARBITRARY-CANARY' >&2\n" ++
        "exit 1\n");
    const helper_path = try tmp.dir.realPathFileAlloc(io, "custom-key-helper", allocator);
    defer allocator.free(helper_path);
    try configureRemoteTestHelper(allocator, io, work, helper_path);

    const home_root = try tmp.dir.realPathFileAlloc(io, "home", allocator);
    defer allocator.free(home_root);
    var parent = std.process.Environ.Map.init(allocator);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin:/bin");
    try parent.put("HOME", home_root);
    try parent.put("CUSTOM_HELPER_TOKEN", "AMBIENT-CREDENTIAL-CANARY");
    var environment = try buildRemoteEnvironment(allocator, &parent, .background);
    defer environment.deinit();
    try std.testing.expect(environment.map.get("CUSTOM_HELPER_TOKEN") == null);

    var command = runBackgroundCredentialFill(allocator, io, work, &environment.map, .{});
    defer command.deinit();
    const failure = commandFailure(&command, true) orelse return error.ExpectedCredentialFailure;
    try std.testing.expectEqual(RemoteFailure.failed, failure);
    const raw = switch (command) {
        .completed => |*result| result.stderr.bytes(),
        else => return error.ExpectedSensitiveDiagnostic,
    };
    try std.testing.expect(std.mem.indexOf(u8, raw, "OMITTED-AUTH-CANARY") != null);
    const safe_result = remoteFailureResult(failure, environment.warnings);
    const formatted = try std.fmt.allocPrint(allocator, "{any}", .{safe_result});
    defer allocator.free(formatted);
    const canaries = [_][]const u8{
        "AMBIENT-CREDENTIAL-CANARY",
        "OMITTED-AUTH-CANARY",
        "OMITTED-PASSWORD-CANARY",
        "OMITTED-ARBITRARY-CANARY",
    };
    for (canaries) |canary| try std.testing.expect(std.mem.indexOf(u8, formatted, canary) == null);
}

test "remote URL audit rejects every fetch URL pushurl and effective push URL before network" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "bin", .default_dir);
    try tmp.dir.createDir(io, "home", .default_dir);
    try writeExecutableRemoteTestScript(io, tmp.dir, "bin/git-remote-networkmarker", "#!/bin/sh\n" ++
        ": > \"$HOME/network-started\"\n" ++
        "exit 1\n");
    const bin_root = try tmp.dir.realPathFileAlloc(io, "bin", allocator);
    defer allocator.free(bin_root);
    const home_root = try tmp.dir.realPathFileAlloc(io, "home", allocator);
    defer allocator.free(home_root);
    const path = try std.fmt.allocPrint(allocator, "{s}:/usr/bin:/bin", .{bin_root});
    defer allocator.free(path);
    var parent = std.process.Environ.Map.init(allocator);
    defer parent.deinit();
    try parent.put("PATH", path);
    try parent.put("HOME", home_root);
    var environment = try buildRemoteEnvironment(allocator, &parent, .background);
    defer environment.deinit();

    try tmp.dir.createDir(io, "fetch-work", .default_dir);
    var fetch_work = try tmp.dir.openDir(io, "fetch-work", .{});
    defer fetch_work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, fetch_work);
    try runTestGit(io, &.{ "git", "remote", "add", "origin", "networkmarker::first-fetch-url" }, fetch_work);
    try runTestGit(io, &.{ "git", "config", "--local", "--add", "remote.origin.url", "https://alice:FETCH-URL-CANARY@127.0.0.1:1/repo.git" }, fetch_work);
    const fetch_root_path = try tmp.dir.realPathFileAlloc(io, "fetch-work", allocator);
    defer allocator.free(fetch_root_path);
    var fetch_root = try root_capability.RootCapability.openCanonical(fetch_root_path);
    defer fetch_root.deinit();
    const fetch_result = LocalCommandBackend.runRemoteOperation(allocator, io, .{
        .root = &fetch_root,
        .environment = &environment,
        .control = .{},
        .kind = .{ .fetch = .{ .remote = "origin" } },
    });
    try std.testing.expectEqual(RemoteOperationOutcome{ .failed = .http_userinfo_rejected }, fetch_result.outcome);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "home/network-started", .{}));

    try tmp.dir.createDir(io, "pushurl-work", .default_dir);
    var pushurl_work = try tmp.dir.openDir(io, "pushurl-work", .{});
    defer pushurl_work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, pushurl_work);
    try runTestGit(io, &.{ "git", "remote", "add", "origin", "networkmarker::default-push-url" }, pushurl_work);
    try runTestGit(io, &.{ "git", "config", "--local", "--add", "remote.origin.pushurl", "networkmarker::first-pushurl" }, pushurl_work);
    try runTestGit(io, &.{ "git", "config", "--local", "--add", "remote.origin.pushurl", "https://bob:PUSHURL-CANARY@127.0.0.1:1/repo.git" }, pushurl_work);
    const pushurl_root_path = try tmp.dir.realPathFileAlloc(io, "pushurl-work", allocator);
    defer allocator.free(pushurl_root_path);
    var pushurl_root = try root_capability.RootCapability.openCanonical(pushurl_root_path);
    defer pushurl_root.deinit();
    const pushurl_result = LocalCommandBackend.runRemoteOperation(allocator, io, .{
        .root = &pushurl_root,
        .environment = &environment,
        .control = .{},
        .kind = .{ .push = .{
            .mode = .upstream,
            .branch = "main",
            .remote = "origin",
            .remote_branch = "main",
            .oid = "deadbeef",
        } },
    });
    try std.testing.expectEqual(RemoteOperationOutcome{ .failed = .http_userinfo_rejected }, pushurl_result.outcome);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "home/network-started", .{}));

    try tmp.dir.createDir(io, "effective-push-work", .default_dir);
    var effective_work = try tmp.dir.openDir(io, "effective-push-work", .{});
    defer effective_work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, effective_work);
    try runTestGit(io, &.{ "git", "remote", "add", "origin", "fixture-alias:repo" }, effective_work);
    try runTestGit(io, &.{ "git", "config", "--local", "url.https://carol:EFFECTIVE-PUSH-CANARY@127.0.0.1:1/.pushInsteadOf", "fixture-alias:" }, effective_work);
    const effective_root_path = try tmp.dir.realPathFileAlloc(io, "effective-push-work", allocator);
    defer allocator.free(effective_root_path);
    var effective_root = try root_capability.RootCapability.openCanonical(effective_root_path);
    defer effective_root.deinit();
    const effective_result = LocalCommandBackend.runRemoteOperation(allocator, io, .{
        .root = &effective_root,
        .environment = &environment,
        .control = .{},
        .kind = .{ .push = .{
            .mode = .upstream,
            .branch = "main",
            .remote = "origin",
            .remote_branch = "main",
            .oid = "deadbeef",
        } },
    });
    try std.testing.expectEqual(RemoteOperationOutcome{ .failed = .http_userinfo_rejected }, effective_result.outcome);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "home/network-started", .{}));
}

test "sensitive diagnostic from a production remote helper cannot cross the typed result boundary" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "bin", .default_dir);
    try tmp.dir.createDir(io, "home", .default_dir);
    try tmp.dir.createDir(io, "work", .default_dir);
    try writeExecutableRemoteTestScript(io, tmp.dir, "bin/git-remote-redactfixture", "#!/bin/sh\n" ++
        ": > \"$HOME/raw-helper-invoked\"\n" ++
        "printf '%s\\n' 'https://alice:RAW-URL-CANARY@example.invalid/repo.git' 'Authorization: Bearer RAW-AUTH-CANARY' 'password=RAW-PASSWORD-CANARY' 'RAW-ARBITRARY-CANARY' >&2\n" ++
        "exit 1\n");
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try runTestGit(io, &.{ "git", "remote", "add", "origin", "redactfixture::opaque" }, work);

    const bin_root = try tmp.dir.realPathFileAlloc(io, "bin", allocator);
    defer allocator.free(bin_root);
    const home_root = try tmp.dir.realPathFileAlloc(io, "home", allocator);
    defer allocator.free(home_root);
    const path = try std.fmt.allocPrint(allocator, "{s}:/usr/bin:/bin", .{bin_root});
    defer allocator.free(path);
    var parent = std.process.Environ.Map.init(allocator);
    defer parent.deinit();
    try parent.put("PATH", path);
    try parent.put("HOME", home_root);
    var environment = try buildRemoteEnvironment(allocator, &parent, .background);
    defer environment.deinit();
    const work_root_path = try tmp.dir.realPathFileAlloc(io, "work", allocator);
    defer allocator.free(work_root_path);
    var root = try root_capability.RootCapability.openCanonical(work_root_path);
    defer root.deinit();

    const result = LocalCommandBackend.runRemoteOperation(allocator, io, .{
        .root = &root,
        .environment = &environment,
        .control = .{},
        .kind = .{ .fetch = .{ .remote = "origin" } },
    });
    try std.testing.expectEqual(RemoteOperationOutcome{ .failed = .failed }, result.outcome);
    try tmp.dir.access(io, "home/raw-helper-invoked", .{});
    const formatted = try std.fmt.allocPrint(allocator, "{any}", .{result});
    defer allocator.free(formatted);
    const canaries = [_][]const u8{
        "RAW-URL-CANARY",
        "RAW-AUTH-CANARY",
        "RAW-PASSWORD-CANARY",
        "RAW-ARBITRARY-CANARY",
    };
    for (canaries) |canary| try std.testing.expect(std.mem.indexOf(u8, formatted, canary) == null);
}

test "remote URL audit rejects HTTP userinfo without exposing the sensitive diagnostic" {
    try std.testing.expectEqual(UrlAudit.accepted, auditLineFramedUrls(
        "https://example.invalid/owner/repo.git\nssh://git@example.invalid/repo.git\n",
    ));
    try std.testing.expectEqual(UrlAudit.userinfo, auditLineFramedUrls(
        "https://alice:REMOTE-URL-CANARY@example.invalid/owner/repo.git\n",
    ));
    try std.testing.expectEqual(UrlAudit.userinfo, auditNulFramedUrls(
        "http://alice@example.invalid/repo.git\x00",
    ));
    try std.testing.expectEqual(UrlAudit.invalid, auditLineFramedUrls(
        "https://example.invalid/repo.git\r\n",
    ));
    try std.testing.expectEqual(UrlAudit.invalid, auditNulFramedUrls(
        "https://example.invalid/repo.git",
    ));
    try std.testing.expectEqual(UrlAudit.invalid, auditLineFramedUrls(
        "https://[invalid/repo.git\n",
    ));
    try std.testing.expectEqual(UrlAudit.invalid, auditLineFramedUrls(
        "https://exam\x01ple.invalid/repo.git\n",
    ));
}

test "credential helper classification honors reset and plaintext store" {
    var warnings: RemoteWarningSet = .{};
    try std.testing.expect(classifyHelperRecords("store\x00\x00cache\x00", &warnings));
    try std.testing.expect(!warnings.git_plaintext_store);
    try std.testing.expect(!warnings.helper_policy_unknown);

    warnings = .{};
    try std.testing.expect(classifyHelperRecords("cache\x00store\x00", &warnings));
    try std.testing.expect(warnings.git_plaintext_store);

    warnings = .{};
    try std.testing.expect(classifyHelperRecords("store --file /tmp/credentials\x00", &warnings));
    try std.testing.expect(warnings.git_plaintext_store);

    warnings = .{};
    try std.testing.expect(classifyHelperRecords("!custom wrapper\x00", &warnings));
    try std.testing.expect(warnings.helper_policy_unknown);

    warnings = .{};
    try std.testing.expect(classifyHelperRecords("!custom wrapper\x00\x00cache\x00", &warnings));
    try std.testing.expect(!warnings.helper_policy_unknown);

    warnings = .{};
    try std.testing.expect(classifyHelperOrigins("file:.git/config\x00cache\x00file:/tmp/included.conf\x00store\x00", &warnings));
    try std.testing.expect(warnings.potential_plaintext_store);
    try std.testing.expect(nulSingleValueEquals("plaintext\x00", "plaintext"));

    warnings = .{};
    try std.testing.expect(classifyScopedHelperRecords(
        "credential.https://example.invalid.helper\ncache --timeout 60\x00" ++
            "credential.https://other.invalid.helper\nstore --file /tmp/credentials\x00" ++
            "credential.https://third.invalid.helper\n!custom wrapper\x00",
        &warnings,
    ));
    try std.testing.expect(warnings.potential_plaintext_store);
    try std.testing.expect(warnings.helper_policy_unknown);
}

test "remote authentication failure becomes a typed sensitive diagnostic" {
    const canary = "Authorization: Basic SENSITIVE-DIAGNOSTIC-CANARY";
    try std.testing.expectEqual(
        RemoteFailure.authentication_required,
        diagnoseRemoteFailure(canary, "fatal: could not read Username: terminal prompts disabled"),
    );
    try std.testing.expectEqual(
        RemoteFailure.ssh_public_key,
        diagnoseRemoteFailure(canary, "git@example.invalid: Permission denied (publickey)."),
    );
    try std.testing.expectEqual(
        RemoteFailure.failed,
        diagnoseRemoteFailure(canary, "arbitrary remote failure"),
    );
}

test "remote cancel is observed before a sensitive child spawn" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    var canceled_generation: std.atomic.Value(u64) = .init(9);
    const argv = [_][]const u8{ "sh", "-c", "exit 0" };
    var result = runSensitiveRemoteCommand(
        std.testing.allocator,
        std.testing.io,
        std.Io.Dir.cwd(),
        &environment,
        .{ .cancellation = .{
            .canceled_generation = &canceled_generation,
            .generation = 9,
        } },
        &argv,
    );
    defer result.deinit();
    try std.testing.expect(result == .canceled);
}

fn requestRemoteCancellation(
    io: std.Io,
    canceled_generation: *std.atomic.Value(u64),
    generation: u64,
) std.Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(40), .awake);
    canceled_generation.store(generation, .release);
}

test "remote cancel contains a running TERM-ignoring helper process group" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("PATH", "/usr/bin:/bin");
    var canceled_generation: std.atomic.Value(u64) = .init(0);
    var cancel_future = try std.testing.io.concurrent(requestRemoteCancellation, .{
        std.testing.io,
        &canceled_generation,
        23,
    });
    defer _ = cancel_future.cancel(std.testing.io) catch {};

    const argv = [_][]const u8{
        "sh",
        "-c",
        "trap '' TERM; sh -c 'trap \"\" TERM; while :; do sleep 1; done' & while :; do sleep 1; done",
    };
    var result = runSensitiveRemoteCommand(
        std.testing.allocator,
        std.testing.io,
        std.Io.Dir.cwd(),
        &environment,
        .{ .cancellation = .{
            .canceled_generation = &canceled_generation,
            .generation = 23,
        } },
        &argv,
    );
    defer result.deinit();
    try cancel_future.await(std.testing.io);
    try std.testing.expect(result == .canceled);
}

test "remote timeout is observed before a sensitive child spawn" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    const argv = [_][]const u8{ "sh", "-c", "exit 0" };
    const expired = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .raw = .fromMilliseconds(-1),
        .clock = .awake,
    });
    var result = runSensitiveRemoteCommand(
        std.testing.allocator,
        std.testing.io,
        std.Io.Dir.cwd(),
        &environment,
        .{ .deadline = expired },
        &argv,
    );
    defer result.deinit();
    try std.testing.expect(result == .timed_out);
}

test "credential helper plaintext warning survives descriptor-bound remote authentication success" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try runTestGit(io, &.{ "git", "init", "--bare", "remote.git" }, tmp.dir);
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    const remote_root = try tmp.dir.realPathFileAlloc(io, "remote.git", std.testing.allocator);
    defer std.testing.allocator.free(remote_root);
    try runTestGit(io, &.{ "git", "remote", "add", "origin", remote_root }, work);
    try runTestGit(io, &.{ "git", "config", "--local", "credential.helper", "store" }, work);

    const work_root = try tmp.dir.realPathFileAlloc(io, "work", std.testing.allocator);
    defer std.testing.allocator.free(work_root);
    var root = try root_capability.RootCapability.openCanonical(work_root);
    defer root.deinit();
    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin:/bin");
    var environment = try buildRemoteEnvironment(std.testing.allocator, &parent, .background);
    defer environment.deinit();

    const result = LocalCommandBackend.runRemoteOperation(std.testing.allocator, io, .{
        .root = &root,
        .environment = &environment,
        .control = .{},
        .kind = .{ .fetch = .{ .remote = "origin" } },
    });
    try std.testing.expectEqual(RemoteOperationOutcome{ .ok = .completed }, result.outcome);
    try std.testing.expect(result.warnings.git_plaintext_store);
}

test "remote authentication uses a cached noninteractive HTTPS credential helper" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "home", .default_dir);
    var home = try tmp.dir.openDir(io, "home", .{});
    defer home.close(io);
    try home.writeFile(io, .{
        .sub_path = ".git-credentials",
        .data = "https://alice:CACHED-HTTPS-CREDENTIAL-CANARY@example.invalid\n",
    });
    const home_root = try tmp.dir.realPathFileAlloc(io, "home", std.testing.allocator);
    defer std.testing.allocator.free(home_root);

    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin:/bin");
    try parent.put("HOME", home_root);
    try parent.put("DISPLAY", ":99");
    try parent.put("BROWSER", "GUI-CANARY");
    var environment = try buildRemoteEnvironment(std.testing.allocator, &parent, .background);
    defer environment.deinit();
    try std.testing.expect(environment.map.get("DISPLAY") == null);
    try std.testing.expect(environment.map.get("BROWSER") == null);

    const argv = [_][]const u8{
        "sh",
        "-c",
        "printf 'protocol=https\\nhost=example.invalid\\n\\n' | git -c credential.interactive=false -c credential.helper=store credential fill",
    };
    var command = runSensitiveRemoteCommand(
        std.testing.allocator,
        io,
        tmp.dir,
        &environment.map,
        .{},
        &argv,
    );
    defer command.deinit();
    try std.testing.expect(commandFailure(&command, false) == null);
    const output = switch (command) {
        .completed => |*result| result.stdout.bytes(),
        else => return error.ExpectedCachedCredential,
    };
    try std.testing.expect(std.mem.indexOf(u8, output, "username=alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "password=CACHED-HTTPS-CREDENTIAL-CANARY") != null);
}

test "remote authentication descriptor cwd survives repository path replacement" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try runTestGit(io, &.{ "git", "init", "--bare", "remote.git" }, tmp.dir);
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    const remote_root = try tmp.dir.realPathFileAlloc(io, "remote.git", std.testing.allocator);
    defer std.testing.allocator.free(remote_root);
    try runTestGit(io, &.{ "git", "remote", "add", "origin", remote_root }, work);

    const work_root = try tmp.dir.realPathFileAlloc(io, "work", std.testing.allocator);
    defer std.testing.allocator.free(work_root);
    var root = try root_capability.RootCapability.openCanonical(work_root);
    defer root.deinit();
    try tmp.dir.rename("work", tmp.dir, "pinned-work", io);
    try tmp.dir.createDir(io, "work", .default_dir);
    var replacement = try tmp.dir.openDir(io, "work", .{});
    defer replacement.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, replacement);
    try runTestGit(io, &.{ "git", "remote", "add", "origin", "https://alice:REPLACEMENT-CANARY@127.0.0.1:1/repo.git" }, replacement);

    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin:/bin");
    var environment = try buildRemoteEnvironment(std.testing.allocator, &parent, .background);
    defer environment.deinit();
    const result = LocalCommandBackend.runRemoteOperation(std.testing.allocator, io, .{
        .root = &root,
        .environment = &environment,
        .control = .{},
        .kind = .{ .fetch = .{ .remote = "origin" } },
    });
    try std.testing.expectEqual(RemoteOperationOutcome{ .ok = .completed }, result.outcome);
}

test "remote URL userinfo is rejected before background authentication network access" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try runTestGit(io, &.{ "git", "remote", "add", "origin", "https://alice:REMOTE-URL-NETWORK-CANARY@127.0.0.1:1/owner/repo.git" }, work);

    const work_root = try tmp.dir.realPathFileAlloc(io, "work", std.testing.allocator);
    defer std.testing.allocator.free(work_root);
    var root = try root_capability.RootCapability.openCanonical(work_root);
    defer root.deinit();
    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin:/bin");
    var environment = try buildRemoteEnvironment(std.testing.allocator, &parent, .background);
    defer environment.deinit();

    const result = LocalCommandBackend.runRemoteOperation(std.testing.allocator, io, .{
        .root = &root,
        .environment = &environment,
        .control = .{},
        .kind = .{ .fetch = .{ .remote = "origin" } },
    });
    try std.testing.expectEqual(
        RemoteOperationOutcome{ .failed = .http_userinfo_rejected },
        result.outcome,
    );
}

test "foreground remote environment omits credential-bearing proxies" {
    const allocator = std.testing.allocator;
    var parent = std.process.Environ.Map.init(allocator);
    defer parent.deinit();

    try parent.put("HTTP_PROXY", "http://alice:PROXY-CANARY@proxy.test:8080");
    try parent.put("https_proxy", "bob:SECOND-CANARY@proxy.test:8081");
    try parent.put("HTTPS_PROXY", "http://proxy.test/path@not-userinfo");
    try parent.put("ALL_PROXY", "socks5://proxy.test:1080");
    try parent.put("NO_PROXY", "localhost,127.0.0.1");
    try parent.put("no_proxy", "alice:NO-PROXY-CANARY@proxy.test");

    var owned = try buildRemoteEnvironment(allocator, &parent, .foreground);
    defer owned.deinit();
    try std.testing.expect(owned.warnings.proxy_credentials_omitted);
    try std.testing.expect(owned.map.get("HTTP_PROXY") == null);
    try std.testing.expect(owned.map.get("https_proxy") == null);
    try std.testing.expectEqualStrings("http://proxy.test/path@not-userinfo", owned.map.get("HTTPS_PROXY").?);
    try std.testing.expectEqualStrings("socks5://proxy.test:1080", owned.map.get("ALL_PROXY").?);
    try std.testing.expectEqualStrings("localhost,127.0.0.1", owned.map.get("NO_PROXY").?);
    try std.testing.expect(owned.map.get("no_proxy") == null);
    for (owned.map.values()) |value| {
        try std.testing.expect(std.mem.indexOf(u8, value, "alice") == null);
        try std.testing.expect(std.mem.indexOf(u8, value, "PROXY-CANARY") == null);
        try std.testing.expect(std.mem.indexOf(u8, value, "SECOND-CANARY") == null);
        try std.testing.expect(std.mem.indexOf(u8, value, "NO-PROXY-CANARY") == null);
    }
}

fn exerciseForegroundRemoteEnvironmentAllocationFailure(
    allocator: std.mem.Allocator,
    parent: *const std.process.Environ.Map,
) !void {
    var owned = try buildRemoteEnvironment(allocator, parent, .foreground);
    defer owned.deinit();
    try std.testing.expectEqualStrings("1", owned.map.get("GCM_INTERACTIVE").?);
    try std.testing.expect(owned.warnings.proxy_credentials_omitted);
    try std.testing.expect(owned.map.get("HTTPS_PROXY") == null);
}

test "foreground remote environment releases partial construction on allocation failure" {
    const allocator = std.testing.allocator;
    var parent = std.process.Environ.Map.init(allocator);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin:/bin");
    try parent.put("HOME", "/home/test");
    try parent.put("LC_ALL", "C.UTF-8");
    try parent.put("TERM", "xterm-256color");
    try parent.put("SSH_AUTH_SOCK", "/run/agent.sock");
    try parent.put("HTTPS_PROXY", "http://alice:PROXY-CANARY@proxy.test:8080");
    try std.testing.checkAllAllocationFailures(
        allocator,
        exerciseForegroundRemoteEnvironmentAllocationFailure,
        .{&parent},
    );
}

test "LocalCommandBackend foreground push inspection rejects stale oid before admission" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);

    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try runTestGit(io, &.{ "git", "remote", "add", "origin", "." }, work);
    try work.writeFile(io, .{ .sub_path = "README.md", .data = "hello\n" });
    try runTestGit(io, &.{ "git", "add", "README.md" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "initial" }, work);

    const repo_root = try tmp.dir.realPathFileAlloc(io, "work", std.testing.allocator);
    defer std.testing.allocator.free(repo_root);

    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin:/bin");
    try parent.put("HOME", repo_root);
    var environment = try buildRemoteEnvironment(std.testing.allocator, &parent, .inspection);
    defer environment.deinit();
    var root = try root_capability.RootCapability.openCanonical(repo_root);
    defer root.deinit();
    const result = LocalCommandBackend.inspectForegroundPush(std.testing.allocator, io, .{
        .root = &root,
        .environment = &environment,
        .control = .{},
        .push = .{
            .branch = "main",
            .remote = "origin",
            .remote_branch = "main",
            .oid = "not-the-current-oid",
        },
    });
    try std.testing.expectEqual(ForegroundPushInspectionOutcome.oid_changed, result.outcome);
}

test "LocalCommandBackend foreground push inspection rejects a missing remote" {
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

    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin:/bin");
    try parent.put("HOME", repo_root);
    var environment = try buildRemoteEnvironment(std.testing.allocator, &parent, .inspection);
    defer environment.deinit();
    var root = try root_capability.RootCapability.openCanonical(repo_root);
    defer root.deinit();
    const result = LocalCommandBackend.inspectForegroundPush(std.testing.allocator, io, .{
        .root = &root,
        .environment = &environment,
        .control = .{},
        .push = .{
            .branch = "main",
            .remote = "missing",
            .remote_branch = "main",
            .oid = trimLineEnd(oid),
        },
    });
    try std.testing.expectEqual(ForegroundPushInspectionOutcome{ .failed = .failed }, result.outcome);
}

test "LocalCommandBackend foreground push inspection accepts a local bare remote" {
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

    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin:/bin");
    try parent.put("HOME", repo_root);
    var environment = try buildRemoteEnvironment(std.testing.allocator, &parent, .inspection);
    defer environment.deinit();
    var root = try root_capability.RootCapability.openCanonical(repo_root);
    defer root.deinit();
    const result = LocalCommandBackend.inspectForegroundPush(std.testing.allocator, io, .{
        .root = &root,
        .environment = &environment,
        .control = .{},
        .push = .{
            .branch = "main",
            .remote = "origin",
            .remote_branch = "main",
            .oid = trimLineEnd(oid),
        },
    });
    try std.testing.expectEqual(ForegroundPushInspectionOutcome.ready, result.outcome);

    const config_result = try std.process.run(std.testing.allocator, io, .{
        .argv = &[_][]const u8{ "git", "config", "--get", "branch.main.remote" },
        .cwd = .{ .dir = work },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer freeRunResult(std.testing.allocator, config_result);
    try std.testing.expect(config_result.term == .exited and config_result.term.exited != 0);
}

test "LocalCommandBackend upstream finalization configures local tracking after fixed oid push" {
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

    try runTestGit(io, &.{ "git", "push", "--", "origin", "refs/heads/feature/topic:refs/heads/feature/topic" }, work);
    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin:/bin");
    try parent.put("HOME", repo_root);
    var environment = try buildRemoteEnvironment(std.testing.allocator, &parent, .local_finalizer);
    defer environment.deinit();
    var root = try root_capability.RootCapability.openCanonical(repo_root);
    defer root.deinit();
    const request: PushUpstreamFinalizeRequest = .{
        .root = &root,
        .environment = &environment,
        .control = .{},
        .branch = "feature/topic",
        .remote = "origin",
        .remote_branch = "feature/topic",
        .oid = trimLineEnd(oid),
    };
    const result = LocalCommandBackend.finalizePushUpstream(std.testing.allocator, io, request);
    try std.testing.expectEqual(PushUpstreamFinalizeOutcome.configured, result);
    try std.testing.expectEqual(
        PushUpstreamFinalizeOutcome.already_configured,
        LocalCommandBackend.finalizePushUpstream(std.testing.allocator, io, request),
    );

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

test "LocalCommandBackend upstream finalization has conflict-safe typed terminals" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try work.writeFile(io, .{ .sub_path = "README.md", .data = "hello\n" });
    try runTestGit(io, &.{ "git", "add", "README.md" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "initial" }, work);

    const repo_root = try tmp.dir.realPathFileAlloc(io, "work", allocator);
    defer allocator.free(repo_root);
    const oid_bytes = try gitOutputAlloc(io, work, &.{ "git", "rev-parse", "--verify", "HEAD" });
    defer allocator.free(oid_bytes);
    const oid = trimLineEnd(oid_bytes);

    var parent = std.process.Environ.Map.init(allocator);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin:/bin");
    try parent.put("HOME", repo_root);
    var environment = try buildRemoteEnvironment(allocator, &parent, .local_finalizer);
    defer environment.deinit();
    var root = try root_capability.RootCapability.openCanonical(repo_root);
    defer root.deinit();
    var request: PushUpstreamFinalizeRequest = .{
        .root = &root,
        .environment = &environment,
        .control = .{},
        .branch = "main",
        .remote = "origin",
        .remote_branch = "main",
        .oid = oid,
    };

    try runTestGit(io, &.{ "git", "switch", "-c", "other" }, work);
    try std.testing.expectEqual(
        PushUpstreamFinalizeOutcome.branch_changed,
        LocalCommandBackend.finalizePushUpstream(allocator, io, request),
    );
    try runTestGit(io, &.{ "git", "switch", "main" }, work);

    request.oid = "0000000000000000000000000000000000000000";
    try std.testing.expectEqual(
        PushUpstreamFinalizeOutcome.oid_changed,
        LocalCommandBackend.finalizePushUpstream(allocator, io, request),
    );
    request.oid = oid;

    try runTestGit(io, &.{ "git", "switch", "--detach" }, work);
    try std.testing.expectEqual(
        PushUpstreamFinalizeOutcome.context_changed,
        LocalCommandBackend.finalizePushUpstream(allocator, io, request),
    );
    try runTestGit(io, &.{ "git", "switch", "main" }, work);

    try runTestGit(io, &.{ "git", "config", "--local", "--add", "branch.main.remote", "origin" }, work);
    try runTestGit(io, &.{ "git", "config", "--local", "--add", "branch.main.remote", "origin" }, work);
    try std.testing.expectEqual(
        PushUpstreamFinalizeOutcome.config_verification_failed,
        LocalCommandBackend.finalizePushUpstream(allocator, io, request),
    );
    try runTestGit(io, &.{ "git", "config", "--local", "--unset-all", "branch.main.remote" }, work);

    try runTestGit(io, &.{ "git", "config", "--local", "branch.main.remote", "other" }, work);
    try std.testing.expectEqual(
        PushUpstreamFinalizeOutcome.upstream_conflict,
        LocalCommandBackend.finalizePushUpstream(allocator, io, request),
    );
    try runTestGit(io, &.{ "git", "config", "--local", "--unset-all", "branch.main.remote" }, work);

    var lock = try work.createFile(io, ".git/config.lock", .{ .exclusive = true });
    lock.close(io);
    try std.testing.expectEqual(
        PushUpstreamFinalizeOutcome.config_write_failed,
        LocalCommandBackend.finalizePushUpstream(allocator, io, request),
    );
    try work.deleteFile(io, ".git/config.lock");

    var canceled_generation: std.atomic.Value(u64) = .init(7);
    request.control = .{ .cancellation = .{
        .canceled_generation = &canceled_generation,
        .generation = 7,
    } };
    try std.testing.expectEqual(
        PushUpstreamFinalizeOutcome.tracking_unknown,
        LocalCommandBackend.finalizePushUpstream(allocator, io, request),
    );
    request.control = .{};

    try runTestGit(io, &.{ "git", "config", "--local", "branch.autoSetupRebase", "remote" }, work);
    try runTestGit(io, &.{ "git", "config", "--local", "branch.main.rebase", "false" }, work);
    request.remote = ".";
    try std.testing.expectEqual(
        PushUpstreamFinalizeOutcome.configured,
        LocalCommandBackend.finalizePushUpstream(allocator, io, request),
    );
    const configured_remote = try gitOutputAlloc(io, work, &.{ "git", "config", "--get", "branch.main.remote" });
    defer allocator.free(configured_remote);
    try std.testing.expectEqualStrings(".", trimLineEnd(configured_remote));
    const configured_rebase = try gitOutputAlloc(io, work, &.{ "git", "config", "--bool", "--get", "branch.main.rebase" });
    defer allocator.free(configured_rebase);
    try std.testing.expectEqualStrings("true", trimLineEnd(configured_rebase));
    try std.testing.expectEqual(
        PushUpstreamFinalizeOutcome.already_configured,
        LocalCommandBackend.finalizePushUpstream(allocator, io, request),
    );
    try runTestGit(io, &.{ "git", "config", "--local", "branch.main.rebase", "false" }, work);
    try std.testing.expectEqual(
        PushUpstreamFinalizeOutcome.upstream_conflict,
        LocalCommandBackend.finalizePushUpstream(allocator, io, request),
    );
    const conflicting_rebase = try gitOutputAlloc(io, work, &.{ "git", "config", "--bool", "--get", "branch.main.rebase" });
    defer allocator.free(conflicting_rebase);
    try std.testing.expectEqualStrings("false", trimLineEnd(conflicting_rebase));
}

const UpstreamFinalizerFault = enum {
    second_write,
    rebase_write,
    postcondition_mismatch,
};

fn injectUpstreamFinalizerFault(
    io: std.Io,
    work: std.Io.Dir,
    fault: UpstreamFinalizerFault,
) !void {
    for (0..5_000) |_| {
        const config = work.readFileAlloc(io, ".git/config", std.testing.allocator, .limited(64 * 1024)) catch {
            try io.sleep(.fromMilliseconds(1), .awake);
            continue;
        };
        const has_remote = std.mem.indexOf(u8, config, "remote = origin") != null;
        const has_merge = std.mem.indexOf(u8, config, "merge = refs/heads/main") != null;
        const has_rebase_true = std.mem.indexOf(u8, config, "rebase = true") != null;
        std.testing.allocator.free(config);

        const ready = switch (fault) {
            .second_write => has_remote and !has_merge,
            .rebase_write => has_remote and has_merge,
            .postcondition_mismatch => has_remote and has_merge and has_rebase_true,
        };
        if (!ready) {
            try io.sleep(.fromMilliseconds(1), .awake);
            continue;
        }

        switch (fault) {
            .second_write, .rebase_write => {
                var lock = work.createFile(io, ".git/config.lock", .{ .exclusive = true }) catch {
                    try io.sleep(.fromMilliseconds(1), .awake);
                    continue;
                };
                lock.close(io);
                return;
            },
            .postcondition_mismatch => {
                runTestGit(io, &.{ "git", "config", "--local", "branch.main.rebase", "false" }, work) catch {
                    try io.sleep(.fromMilliseconds(1), .awake);
                    continue;
                };
                return;
            },
        }
    }
    return error.FinalizerFaultInjectionMissed;
}

fn exerciseUpstreamFinalizerFault(
    io: std.Io,
    tmp: std.Io.Dir,
    fault: UpstreamFinalizerFault,
) !void {
    const allocator = std.testing.allocator;
    const case_name = @tagName(fault);
    try tmp.createDir(io, case_name, .default_dir);
    var fixture = try tmp.openDir(io, case_name, .{});
    defer fixture.close(io);
    try fixture.createDir(io, "work", .default_dir);
    var work = try fixture.openDir(io, "work", .{});
    defer work.close(io);

    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try work.writeFile(io, .{ .sub_path = "README.md", .data = "hello\n" });
    try runTestGit(io, &.{ "git", "add", "README.md" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "initial" }, work);

    switch (fault) {
        .second_write => {},
        .rebase_write, .postcondition_mismatch => {
            try runTestGit(io, &.{ "git", "config", "--local", "branch.autoSetupRebase", "remote" }, work);
            try runTestGit(io, &.{ "git", "config", "--local", "branch.main.rebase", "false" }, work);
        },
    }

    const repo_root = try fixture.realPathFileAlloc(io, "work", allocator);
    defer allocator.free(repo_root);
    const oid_bytes = try gitOutputAlloc(io, work, &.{ "git", "rev-parse", "--verify", "HEAD" });
    defer allocator.free(oid_bytes);

    var parent = std.process.Environ.Map.init(allocator);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin:/bin");
    try parent.put("HOME", repo_root);
    var environment = try buildRemoteEnvironment(allocator, &parent, .local_finalizer);
    defer environment.deinit();
    var root = try root_capability.RootCapability.openCanonical(repo_root);
    defer root.deinit();
    const request: PushUpstreamFinalizeRequest = .{
        .root = &root,
        .environment = &environment,
        .control = .{},
        .branch = "main",
        .remote = "origin",
        .remote_branch = "main",
        .oid = trimLineEnd(oid_bytes),
    };

    const expected: PushUpstreamFinalizeOutcome = switch (fault) {
        .second_write, .rebase_write => .config_write_failed,
        .postcondition_mismatch => .config_verification_failed,
    };
    var fault_future = try io.concurrent(injectUpstreamFinalizerFault, .{ io, work, fault });
    defer _ = fault_future.cancel(io) catch {};
    const outcome = LocalCommandBackend.finalizePushUpstream(allocator, io, request);
    try fault_future.await(io);
    try std.testing.expectEqual(expected, outcome);

    const configured_remote = try gitOutputAlloc(io, work, &.{ "git", "config", "--get", "branch.main.remote" });
    defer allocator.free(configured_remote);
    try std.testing.expectEqualStrings("origin", trimLineEnd(configured_remote));
    switch (fault) {
        .second_write => try runTestGitFailure(io, &.{ "git", "config", "--get", "branch.main.merge" }, work),
        .rebase_write => {
            const configured_merge = try gitOutputAlloc(io, work, &.{ "git", "config", "--get", "branch.main.merge" });
            defer allocator.free(configured_merge);
            try std.testing.expectEqualStrings("refs/heads/main", trimLineEnd(configured_merge));
            const configured_rebase = try gitOutputAlloc(io, work, &.{ "git", "config", "--bool", "--get", "branch.main.rebase" });
            defer allocator.free(configured_rebase);
            try std.testing.expectEqualStrings("false", trimLineEnd(configured_rebase));
        },
        .postcondition_mismatch => {
            const configured_merge = try gitOutputAlloc(io, work, &.{ "git", "config", "--get", "branch.main.merge" });
            defer allocator.free(configured_merge);
            try std.testing.expectEqualStrings("refs/heads/main", trimLineEnd(configured_merge));
            const configured_rebase = try gitOutputAlloc(io, work, &.{ "git", "config", "--bool", "--get", "branch.main.rebase" });
            defer allocator.free(configured_rebase);
            try std.testing.expectEqualStrings("false", trimLineEnd(configured_rebase));
        },
    }
}

test "LocalCommandBackend upstream finalization reports later write and postcondition faults" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    inline for (std.meta.tags(UpstreamFinalizerFault)) |fault| {
        try exerciseUpstreamFinalizerFault(std.testing.io, tmp.dir, fault);
    }
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

    fn run(ctx_ptr: *anyopaque, io: std.Io, cwd: std.Io.Dir) git_command.Error!void {
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
