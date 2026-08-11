//! Fixed-OID Compare snapshot reads.
//!
//! The caller supplies one borrowed repository descriptor and one borrowed,
//! already-sanitized local Git environment. This domain pins both endpoint
//! object IDs and uses only those IDs for later phases.

const std = @import("std");
const git_command = @import("command.zig");
const git_ref = @import("ref.zig");

pub const BranchKind = git_ref.BranchKind;

/// Borrowed user intent for one committed branch comparison.
///
/// `full_ref` is the only Git authority. The other fields cross the domain
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
    /// Borrowed controlled environment retained by the synchronous caller.
    environment: *const git_command.LocalGitEnvironment,
    /// Null asks the domain to run the reviewed origin/HEAD -> main -> master
    /// fallback. A non-null value is resolved exactly once by full ref.
    target: ?CompareTargetSpec,
};

pub fn loadCompareSnapshot(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: CompareSnapshotRequest,
) git_command.Error!CompareSnapshotResult {
    return loadGitCompareSnapshot(allocator, io, request);
}

fn termExited(term: std.process.Child.Term, expected: u8) bool {
    return switch (term) {
        .exited => |code| code == expected,
        else => false,
    };
}

fn trimLineEnd(text: []const u8) []const u8 {
    return std.mem.trimEnd(u8, text, "\r\n");
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
/// null, keeping test orchestration out of the public domain contract.
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
    const resolution = if (request.target) |target|
        try resolveExplicitCompareTarget(allocator, io, request.cwd, request.environment, target)
    else
        try resolveDefaultCompareTarget(allocator, io, request.cwd, request.environment);

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

    const head_resolution = try resolveCompareHead(allocator, io, request.cwd, request.environment);
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
        request.environment,
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
        request.environment,
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
        request.environment,
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
    const result = try git_command.runCaptured(allocator, io, .{ .cwd = cwd, .environment = env }, .{
        .argv = &argv,
        .stdout_limit = .limited(4 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });
    defer result.deinit(allocator);
    switch (result.term) {
        .exited => |code| switch (code) {
            0 => return .{ .oid = try allocator.dupe(u8, trimLineEnd(result.stdout)) },
            1 => return .no_merge_base,
            else => {},
        },
        else => {},
    }
    return .{ .failed = try compareCommandFailure(allocator, "git merge-base", result.term, result.stderr) };
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
    const result = try git_command.runCaptured(allocator, io, .{ .cwd = cwd, .environment = env }, .{
        .argv = argv,
        .stdout_limit = stdout_limit,
        .stderr_limit = .limited(256 * 1024),
    });
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
            else => return .{ .failed = try compareCommandFailure(allocator, label, result.term, result.stderr) },
        },
        else => return .{ .failed = try compareCommandFailure(allocator, label, result.term, result.stderr) },
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
    const result = try git_command.runCaptured(allocator, io, .{ .cwd = cwd, .environment = env }, .{
        .argv = argv,
        .stdout_limit = stdout_limit,
        .stderr_limit = .limited(256 * 1024),
    });
    defer result.deinit(allocator);
    if (termExited(result.term, 0)) {
        // Diff may be empty. It is still a successful, owned output record.
        const text = if (trim_output) trimLineEnd(result.stdout) else result.stdout;
        return .{ .text = try allocator.dupe(u8, text) };
    }
    return .{ .failed = try compareCommandFailure(allocator, label, result.term, result.stderr) };
}

fn compareCommandFailure(
    allocator: std.mem.Allocator,
    label: []const u8,
    term: std.process.Child.Term,
    stderr_bytes: []const u8,
) git_command.Error![]u8 {
    const stderr = trimLineEnd(stderr_bytes);
    if (stderr.len != 0) return std.fmt.allocPrint(allocator, "{s} failed: {s}", .{ label, stderr });
    return std.fmt.allocPrint(allocator, "{s} failed: {any}", .{ label, term });
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

fn branchKind(full_ref: []const u8) ?BranchKind {
    if (std.mem.startsWith(u8, full_ref, "refs/heads/")) return .local;
    if (std.mem.startsWith(u8, full_ref, "refs/remotes/")) return .remote_tracking;
    return null;
}

fn freeRunResult(allocator: std.mem.Allocator, result: std.process.RunResult) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
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
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const fixture = try setupBranchSwitchFixture(io, &tmp);
    defer fixture.deinit();
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "switch", "feature/topic" }, work);

    var result = try loadCompareSnapshot(std.testing.allocator, io, .{
        .cwd = work,
        .environment = &environment,
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
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const fixture = try setupBranchSwitchFixture(io, &tmp);
    defer fixture.deinit();
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "switch", "feature/topic" }, work);

    var fallback = try loadCompareSnapshot(std.testing.allocator, io, .{
        .cwd = work,
        .environment = &environment,
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
    var preferred = try loadCompareSnapshot(std.testing.allocator, io, .{
        .cwd = work,
        .environment = &environment,
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
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
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

    var result = try loadCompareSnapshot(std.testing.allocator, io, .{
        .cwd = work,
        .environment = &environment,
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
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const fixture = try setupBranchSwitchFixture(io, &tmp);
    defer fixture.deinit();
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);

    var result = try loadCompareSnapshot(std.testing.allocator, io, .{
        .cwd = work,
        .environment = &environment,
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
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const fixture = try setupBranchSwitchFixture(io, &tmp);
    defer fixture.deinit();
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);

    var result = try loadCompareSnapshot(std.testing.allocator, io, .{
        .cwd = work,
        .environment = &environment,
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
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    try tmp.dir.createDir(io, "not-a-repository", .default_dir);
    var cwd = try tmp.dir.openDir(io, "not-a-repository", .{});
    defer cwd.close(io);
    // Prevent discovery of the source repository above std.testing.tmpDir.
    try cwd.writeFile(io, .{ .sub_path = ".git", .data = "invalid gitfile\n" });

    var result = try loadCompareSnapshot(std.testing.allocator, io, .{
        .cwd = cwd,
        .environment = &environment,
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
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, &injected_env);
    defer environment.deinit();

    var result = try loadCompareSnapshot(std.testing.allocator, io, .{
        .cwd = pinned,
        .environment = &environment,
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
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
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
        .environment = &environment,
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
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const fixture = try setupBranchSwitchFixture(io, &tmp);
    defer fixture.deinit();
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "switch", "--detach", fixture.feature_oid }, work);

    var result = try loadCompareSnapshot(std.testing.allocator, io, .{
        .cwd = work,
        .environment = &environment,
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
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const fixture = try setupBranchSwitchFixture(io, &tmp);
    defer fixture.deinit();
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "symbolic-ref", "HEAD", "refs/heads/unborn" }, work);

    var result = try loadCompareSnapshot(std.testing.allocator, io, .{
        .cwd = work,
        .environment = &environment,
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
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const fixture = try setupBranchSwitchFixture(io, &tmp);
    defer fixture.deinit();
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "switch", "--orphan", "unrelated" }, work);
    try runTestGit(io, &.{ "git", "rm", "-rf", "--ignore-unmatch", "." }, work);
    try work.writeFile(io, .{ .sub_path = "UNRELATED.md", .data = "unrelated\n" });
    try runTestGit(io, &.{ "git", "add", "UNRELATED.md" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "unrelated" }, work);

    var result = try loadCompareSnapshot(std.testing.allocator, io, .{
        .cwd = work,
        .environment = &environment,
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
