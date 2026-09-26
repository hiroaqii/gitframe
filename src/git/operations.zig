//! Local Git writes and their admission checks.
//!
//! Every request borrows one descriptor-bound context. Repository paths are
//! deliberately absent so admission reads and the eventual mutation cannot
//! be redirected after the caller accepts and queues the operation.

const std = @import("std");
const git_command = @import("command.zig");
const process_runner = @import("../process/runner.zig");

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

pub const SwitchBranchRequest = struct {
    expected_branch: []const u8,
    expected_oid: []const u8,
    target_branch: []const u8,
    target_oid: []const u8,
};

/// One synchronous local operation bound to a borrowed repository authority.
pub const OperationRequest = struct {
    context: git_command.DirectoryContext,
    kind: OperationKind,
};

pub fn runOperation(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: OperationRequest,
) git_command.Error!OperationResult {
    return switch (request.kind) {
        .stage_file => |path| runGitAdd(allocator, io, request.context, path),
        .unstage_file => |path| runGitUnstage(allocator, io, request.context, path),
        .stage_all => runGitAddAll(allocator, io, request.context),
        .unstage_all => runGitUnstageAll(allocator, io, request.context),
        .discard_file => |path| runGitDiscard(allocator, io, request.context, path),
        .stage_patch => |patch| runGitApplyCached(allocator, io, request.context, patch.patch),
        .unstage_patch => |patch| runGitApplyCachedReverse(allocator, io, request.context, patch.patch),
        .commit => |commit| runGitCommit(allocator, io, request.context, commit),
        .amend => |commit| runGitAmend(allocator, io, request.context, commit),
        .switch_branch => |switch_branch| runGitSwitchBranch(allocator, io, request.context, switch_branch),
    };
}

fn operationResultFromGitCommand(
    allocator: std.mem.Allocator,
    result: process_runner.Result,
    fallback_label: []const u8,
) git_command.Error!OperationResult {
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

fn runCaptured(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    argv: []const []const u8,
    stdout_limit: std.Io.Limit,
    stderr_limit: std.Io.Limit,
) git_command.Error!process_runner.Result {
    return git_command.runCaptured(allocator, io, context, .{
        .argv = argv,
        .stdout_limit = stdout_limit,
        .stderr_limit = stderr_limit,
    });
}

fn runWithStdinDetailed(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    argv: []const []const u8,
    stdin: []const u8,
) std.mem.Allocator.Error!process_runner.DetailedResult {
    return process_runner.runWithStdinDetailed(allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = context.cwd },
        .environ_map = context.environment.borrow(),
        .stdin = stdin,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });
}

fn runGitAdd(allocator: std.mem.Allocator, io: std.Io, context: git_command.DirectoryContext, path: []const u8) git_command.Error!OperationResult {
    const argv = git_command.literal_pathspec_prefix ++ [_][]const u8{ "add", "--", path };
    const result = try runCaptured(allocator, io, context, &argv, .limited(64 * 1024), .limited(256 * 1024));
    return operationResultFromGitCommand(allocator, result, "git add");
}

fn runGitUnstage(allocator: std.mem.Allocator, io: std.Io, context: git_command.DirectoryContext, path: []const u8) git_command.Error!OperationResult {
    const argv = git_command.literal_pathspec_prefix ++ [_][]const u8{ "restore", "--staged", "--", path };
    const result = try runCaptured(allocator, io, context, &argv, .limited(64 * 1024), .limited(256 * 1024));
    return operationResultFromGitCommand(allocator, result, "git restore --staged");
}

fn runGitAddAll(allocator: std.mem.Allocator, io: std.Io, context: git_command.DirectoryContext) git_command.Error!OperationResult {
    const argv = git_command.literal_pathspec_prefix ++ [_][]const u8{ "add", "--all", "--", "." };
    const result = try runCaptured(allocator, io, context, &argv, .limited(64 * 1024), .limited(256 * 1024));
    return operationResultFromGitCommand(allocator, result, "git add --all");
}

fn runGitUnstageAll(allocator: std.mem.Allocator, io: std.Io, context: git_command.DirectoryContext) git_command.Error!OperationResult {
    const argv = git_command.literal_pathspec_prefix ++ [_][]const u8{ "restore", "--staged", "--", "." };
    const result = try runCaptured(allocator, io, context, &argv, .limited(64 * 1024), .limited(256 * 1024));
    return operationResultFromGitCommand(allocator, result, "git restore --staged");
}

fn runGitDiscard(allocator: std.mem.Allocator, io: std.Io, context: git_command.DirectoryContext, path: []const u8) git_command.Error!OperationResult {
    const argv = git_command.literal_pathspec_prefix ++ [_][]const u8{ "restore", "--", path };
    const result = try runCaptured(allocator, io, context, &argv, .limited(64 * 1024), .limited(256 * 1024));
    return operationResultFromGitCommand(allocator, result, "git restore");
}

fn runGitApplyCached(allocator: std.mem.Allocator, io: std.Io, context: git_command.DirectoryContext, patch: []const u8) git_command.Error!OperationResult {
    const argv = [_][]const u8{ "git", "apply", "--cached", "--whitespace=nowarn", "-" };
    const detailed = try runWithStdinDetailed(allocator, io, context, &argv, patch);
    return operationResultFromGitStdinCommand(allocator, detailed, "git apply --cached");
}

fn runGitApplyCachedReverse(allocator: std.mem.Allocator, io: std.Io, context: git_command.DirectoryContext, patch: []const u8) git_command.Error!OperationResult {
    const argv = [_][]const u8{ "git", "apply", "--cached", "--reverse", "--whitespace=nowarn", "-" };
    const detailed = try runWithStdinDetailed(allocator, io, context, &argv, patch);
    return operationResultFromGitStdinCommand(allocator, detailed, "git apply --cached --reverse");
}

fn runGitCommit(allocator: std.mem.Allocator, io: std.Io, context: git_command.DirectoryContext, request: CommitRequest) git_command.Error!OperationResult {
    return runGitCommitLike(allocator, io, context, request, false);
}

fn runGitAmend(allocator: std.mem.Allocator, io: std.Io, context: git_command.DirectoryContext, request: CommitRequest) git_command.Error!OperationResult {
    return runGitCommitLike(allocator, io, context, request, true);
}

fn runGitCommitLike(allocator: std.mem.Allocator, io: std.Io, context: git_command.DirectoryContext, request: CommitRequest, amend: bool) git_command.Error!OperationResult {
    const argv_subject = [_][]const u8{ "git", "commit", "-m", request.subject };
    const argv_with_body = [_][]const u8{ "git", "commit", "-m", request.subject, "-m", request.body orelse "" };
    const amend_argv_subject = [_][]const u8{ "git", "commit", "--amend", "-m", request.subject };
    const amend_argv_with_body = [_][]const u8{ "git", "commit", "--amend", "-m", request.subject, "-m", request.body orelse "" };
    const argv = if (amend)
        if (request.body == null) amend_argv_subject[0..] else amend_argv_with_body[0..]
    else if (request.body == null) argv_subject[0..] else argv_with_body[0..];

    const result = try runCaptured(allocator, io, context, argv, .limited(256 * 1024), .limited(256 * 1024));
    return operationResultFromGitCommand(allocator, result, "git commit");
}

fn runGitSwitchBranch(allocator: std.mem.Allocator, io: std.Io, context: git_command.DirectoryContext, request: SwitchBranchRequest) git_command.Error!OperationResult {
    if (!try verifyCurrentBranchSnapshot(allocator, io, context, request.expected_branch, request.expected_oid)) {
        return .{ .failed_static = "Branch changed before switch; reload and try again" };
    }
    if (!try verifyBranchOid(allocator, io, context, request.target_branch, request.target_oid)) {
        return .{ .failed_static = "branch list changed; reopen branch switch and try again" };
    }
    const argv = [_][]const u8{ "git", "switch", "--no-guess", request.target_branch };
    const result = try runCaptured(allocator, io, context, &argv, .limited(128 * 1024), .limited(256 * 1024));
    return operationResultFromGitCommand(allocator, result, "git switch");
}

fn verifyCurrentBranchSnapshot(allocator: std.mem.Allocator, io: std.Io, context: git_command.DirectoryContext, branch: ?[]const u8, oid: []const u8) git_command.Error!bool {
    const current = try readCurrentBranchOid(allocator, io, context, branch) orelse return false;
    defer allocator.free(current);
    return std.mem.eql(u8, current, oid);
}

/// Returns an owned live HEAD only while the requested branch is current.
pub fn readCurrentBranchOid(allocator: std.mem.Allocator, io: std.Io, context: git_command.DirectoryContext, branch: ?[]const u8) git_command.Error!?[]u8 {
    const branch_argv = [_][]const u8{ "git", "symbolic-ref", "--quiet", "--short", "HEAD" };
    const branch_result = try runCaptured(allocator, io, context, &branch_argv, .limited(4 * 1024), .limited(16 * 1024));
    defer branch_result.deinit(allocator);
    switch (branch_result.term) {
        .exited => |code| if (code != (if (branch != null) @as(u8, 0) else @as(u8, 1))) return null,
        else => return null,
    }
    if (branch) |name| if (!std.mem.eql(u8, trimLineEnd(branch_result.stdout), name)) return null;

    const oid_argv = [_][]const u8{ "git", "rev-parse", "--verify", "HEAD" };
    const oid_result = try runCaptured(allocator, io, context, &oid_argv, .limited(4 * 1024), .limited(16 * 1024));
    defer oid_result.deinit(allocator);
    switch (oid_result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    return try allocator.dupe(u8, trimLineEnd(oid_result.stdout));
}

fn verifyBranchOid(allocator: std.mem.Allocator, io: std.Io, context: git_command.DirectoryContext, branch: []const u8, oid: []const u8) git_command.Error!bool {
    const ref = std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch}) catch return error.OutOfMemory;
    defer allocator.free(ref);
    const argv = [_][]const u8{ "git", "rev-parse", "--verify", ref };
    const result = try runCaptured(allocator, io, context, &argv, .limited(4 * 1024), .limited(16 * 1024));
    defer result.deinit(allocator);
    switch (result.term) {
        .exited => |code| if (code != 0) return false,
        else => return false,
    }
    return std.mem.eql(u8, trimLineEnd(result.stdout), oid);
}

fn trimLineEnd(text: []const u8) []const u8 {
    return std.mem.trimEnd(u8, text, "\r\n");
}

test "OperationRequest represents supported operation inputs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const context: git_command.DirectoryContext = .{ .cwd = tmp.dir, .environment = &environment };

    const request: OperationRequest = .{ .context = context, .kind = .{ .unstage_file = "src/app.zig" } };
    try std.testing.expectEqual(tmp.dir.handle, request.context.cwd.handle);
    try std.testing.expectEqualStrings("src/app.zig", request.kind.unstage_file);
    const commit_request: OperationRequest = .{ .context = context, .kind = .{ .commit = .{ .subject = "subject", .body = "body" } } };
    try std.testing.expectEqualStrings("subject", commit_request.kind.commit.subject);
    try std.testing.expectEqualStrings("body", commit_request.kind.commit.body.?);
    const patch_request: OperationRequest = .{ .context = context, .kind = .{ .stage_patch = .{ .patch = "diff --git a/a b/a\n" } } };
    try std.testing.expectEqualStrings("diff --git a/a b/a\n", patch_request.kind.stage_patch.patch);
    const amend_request: OperationRequest = .{ .context = context, .kind = .{ .amend = .{ .subject = "subject", .body = null } } };
    try std.testing.expectEqualStrings("subject", amend_request.kind.amend.subject);
}

test "concurrent stdin Git operation mapping keeps stderr on writer failure" {
    const stdout = try std.testing.allocator.dupe(u8, "ignored");
    const stderr = std.testing.allocator.dupe(u8, "error: corrupt patch at line 6\n") catch |err| {
        std.testing.allocator.free(stdout);
        return err;
    };
    const result = try operationResultFromGitStdinCommand(std.testing.allocator, .{ .failed = .{ .stdin = .{
        .err = error.WriteFailed,
        .result = .{ .term = .{ .exited = 128 }, .stdout = stdout, .stderr = stderr },
    } } }, "git apply --cached");
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
    var result = try operationResultFromGitStdinCommand(std.testing.allocator, .{ .failed = .{ .stdin = .{
        .err = error.WriteFailed,
        .result = .{ .term = .{ .exited = 0 }, .stdout = stdout, .stderr = stderr },
    } } }, "git apply --cached");
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
    try std.testing.expectError(error.OutOfMemory, operationResultFromGitStdinCommand(allocator, .{ .failed = .{ .stdin = .{
        .err = error.WriteFailed,
        .result = .{ .term = .{ .exited = 0 }, .stdout = stdout, .stderr = &.{} },
    } } }, "git apply --cached"));
}

test "concurrent stdin Git apply preserves malformed large patch diagnostic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, tmp.dir);
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
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
    const result = try runGitApplyCached(std.testing.allocator, io, .{ .cwd = tmp.dir, .environment = &environment }, patch);
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
    const argv = [_][]const u8{ "/bin/sh", "-c", "exec 0<&-; printf stdin-prong-diagnostic >&2; exit 7" };
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
    var result = try operationResultFromGitStdinCommand(std.testing.allocator, .{ .failed = .{ .stdin = .{
        .err = error.WriteFailed,
        .result = .{ .term = .{ .exited = 0 }, .stdout = stdout, .stderr = stderr },
    } } }, "git apply --cached");
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

test "literal path operations and reads preserve unselected index and worktree bytes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const read = @import("read.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, tmp.dir);
    const names = [_][]const u8{ "choice*.txt", ":(glob)*.txt", "space name.txt", "-leading.txt", "question?.txt", "bracket[ab].txt" };
    for (names ++ .{"choice-other.txt"}) |name| try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "base\n" });
    try runTestGit(io, &.{ "git", "add", "--all" }, tmp.dir);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" }, tmp.dir);
    var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, null);
    defer environment.deinit();
    const context: git_command.DirectoryContext = .{ .cwd = tmp.dir, .environment = &environment };

    for (names) |name| {
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "selected\n" });
        try tmp.dir.writeFile(io, .{ .sub_path = "choice-other.txt", .data = "CANARY staged\n" });
        for ([_]read.FileDiffBase{ .unstaged, .cached }) |base| {
            if (base == .cached) {
                const stage = try runOperation(allocator, io, .{ .context = context, .kind = .{ .stage_file = name } });
                defer stage.deinit(allocator);
                try std.testing.expect(stage == .ok);
                const index_names = try gitOutputAlloc(io, tmp.dir, &.{ "git", "diff", "--cached", "--name-only", "-z" });
                defer allocator.free(index_names);
                const expected_names = try std.fmt.allocPrint(allocator, "{s}\x00", .{name});
                defer allocator.free(expected_names);
                try std.testing.expectEqualStrings(expected_names, index_names);
                try runTestGit(io, &.{ "git", "add", "--", "choice-other.txt" }, tmp.dir);
            }
            const diff = try read.loadDiff(allocator, io, .{ .context = context, .kind = .{ .file = .{ .base = base, .path = name } } });
            defer diff.deinit(allocator);
            try std.testing.expect(diff == .ok);
            try std.testing.expect(std.mem.indexOf(u8, diff.ok, "+selected\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, diff.ok, "CANARY") == null);
            const stats = try read.loadTrackedNumstat(allocator, io, .{ .context = context, .paths = &.{name}, .staged = base == .cached });
            defer stats.deinit(allocator);
            try std.testing.expect(stats == .ok);
            const expected_stats = try std.fmt.allocPrint(allocator, "1\t1\t{s}\x00", .{name});
            defer allocator.free(expected_stats);
            try std.testing.expectEqualStrings(expected_stats, stats.ok);
        }

        const unstage = try runOperation(allocator, io, .{ .context = context, .kind = .{ .unstage_file = name } });
        defer unstage.deinit(allocator);
        try std.testing.expect(unstage == .ok);
        const staged_names = try gitOutputAlloc(io, tmp.dir, &.{ "git", "diff", "--cached", "--name-only", "-z" });
        defer allocator.free(staged_names);
        try std.testing.expectEqualStrings("choice-other.txt\x00", staged_names);
        try tmp.dir.writeFile(io, .{ .sub_path = "choice-other.txt", .data = "CANARY unstaged\n" });

        const status = try read.loadStatus(allocator, io, .{ .context = context });
        defer status.deinit(allocator);
        try std.testing.expect(status == .ok);
        var bundle = try @import("status.zig").StatusBundle.parseOwned(allocator, status.ok);
        defer bundle.deinit();
        const target = @import("../app/git_ops.zig").discardTarget(.{
            .source = .unstaged,
            .repo_root = "/fixture",
            .action_target = .{ .path = name, .kind = .file },
            .status = .{ .repo_root = "/fixture", .loading = false, .entries = bundle.document.entries },
        });
        try std.testing.expect(target == .ready);
        const discard = try runOperation(allocator, io, .{ .context = context, .kind = .{ .discard_file = target.ready.path } });
        defer discard.deinit(allocator);
        try std.testing.expect(discard == .ok);
        const selected_bytes = try tmp.dir.readFileAlloc(io, name, allocator, .limited(1024));
        defer allocator.free(selected_bytes);
        try std.testing.expectEqualStrings("base\n", selected_bytes);
        const canary_bytes = try tmp.dir.readFileAlloc(io, "choice-other.txt", allocator, .limited(1024));
        defer allocator.free(canary_bytes);
        try std.testing.expectEqualStrings("CANARY unstaged\n", canary_bytes);
        const canary_index = try gitOutputAlloc(io, tmp.dir, &.{ "git", "show", ":choice-other.txt" });
        defer allocator.free(canary_index);
        try std.testing.expectEqualStrings("CANARY staged\n", canary_index);

        try runTestGit(io, &.{ "git", "restore", "--staged", "--worktree", "--", "choice-other.txt" }, tmp.dir);
    }
}

test "operations switch branch succeeds between local branches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const fixture = try setupBranchSwitchFixture(io, &tmp);
    defer fixture.deinit();
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);

    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    const remote_root = try tmp.dir.realPathFileAlloc(io, "remote.git", std.testing.allocator);
    defer std.testing.allocator.free(remote_root);
    const updater_root = try tmp.dir.realPathFileAlloc(io, "updater", std.testing.allocator);
    defer std.testing.allocator.free(updater_root);
    try parent.put("GIT_DIR", remote_root);
    try parent.put("gIt_WoRk_TrEe", updater_root);
    try parent.put("GITFRAME_CANARY", "kept");
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, &parent);
    defer environment.deinit();
    try std.testing.expect(environment.borrow().get("GIT_DIR") == null);
    try std.testing.expect(environment.borrow().get("gIt_WoRk_TrEe") == null);
    try std.testing.expectEqualStrings("kept", environment.borrow().get("GITFRAME_CANARY").?);

    const result = try runOperation(std.testing.allocator, io, .{
        .context = .{ .cwd = work, .environment = &environment },
        .kind = .{ .switch_branch = .{
            .expected_branch = "main",
            .expected_oid = fixture.main_oid,
            .target_branch = "feature/topic",
            .target_oid = fixture.feature_oid,
        } },
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(OperationResult.ok, result);
    const current = try gitOutputAlloc(io, work, &.{ "git", "symbolic-ref", "--quiet", "--short", "HEAD" });
    defer std.testing.allocator.free(current);
    try std.testing.expectEqualStrings("feature/topic", trimLineEnd(current));
    const updater_current = try gitOutputAlloc(io, tmp.dir, &.{ "git", "-C", "updater", "symbolic-ref", "--quiet", "--short", "HEAD" });
    defer std.testing.allocator.free(updater_current);
    try std.testing.expectEqualStrings("remote-only", trimLineEnd(updater_current));
}

test "operations switch branch rejects stale current branch or oid" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const fixture = try setupBranchSwitchFixture(io, &tmp);
    defer fixture.deinit();
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const result = try runOperation(std.testing.allocator, io, .{
        .context = .{ .cwd = work, .environment = &environment },
        .kind = .{ .switch_branch = .{ .expected_branch = "main", .expected_oid = "not-the-current-oid", .target_branch = "feature/topic", .target_oid = fixture.feature_oid } },
    });
    defer result.deinit(std.testing.allocator);
    switch (result) {
        .failed_static => |message| try std.testing.expectEqualStrings("Branch changed before switch; reload and try again", message),
        else => return error.ExpectedStaleSwitchCurrentFailure,
    }
}

test "operations switch branch rejects changed target oid" {
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
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const result = try runOperation(std.testing.allocator, io, .{
        .context = .{ .cwd = work, .environment = &environment },
        .kind = .{ .switch_branch = .{ .expected_branch = "main", .expected_oid = fixture.main_oid, .target_branch = "feature/topic", .target_oid = fixture.feature_oid } },
    });
    defer result.deinit(std.testing.allocator);
    switch (result) {
        .failed_static => |message| try std.testing.expectEqualStrings("branch list changed; reopen branch switch and try again", message),
        else => return error.ExpectedSwitchTargetChangedFailure,
    }
}

test "operations switch branch carries staged unstaged and untracked changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const fixture = try setupBranchSwitchFixture(io, &tmp);
    defer fixture.deinit();
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try work.writeFile(io, .{ .sub_path = "README.md", .data = "staged\n" });
    try runTestGit(io, &.{ "git", "add", "README.md" }, work);
    try work.writeFile(io, .{ .sub_path = "README.md", .data = "unstaged\n" });
    try work.writeFile(io, .{ .sub_path = "local.txt", .data = "untracked\n" });
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const result = try runOperation(std.testing.allocator, io, .{
        .context = .{ .cwd = work, .environment = &environment },
        .kind = .{ .switch_branch = .{ .expected_branch = "main", .expected_oid = fixture.main_oid, .target_branch = "feature/topic", .target_oid = fixture.feature_oid } },
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .ok);
    const current = try gitOutputAlloc(io, work, &.{ "git", "branch", "--show-current" });
    defer std.testing.allocator.free(current);
    try std.testing.expectEqualStrings("feature/topic", trimLineEnd(current));
    const staged = try gitOutputAlloc(io, work, &.{ "git", "show", ":README.md" });
    defer std.testing.allocator.free(staged);
    try std.testing.expectEqualStrings("staged\n", staged);
    const unstaged = try work.readFileAlloc(io, "README.md", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(unstaged);
    try std.testing.expectEqualStrings("unstaged\n", unstaged);
    const untracked = try work.readFileAlloc(io, "local.txt", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(untracked);
    try std.testing.expectEqualStrings("untracked\n", untracked);
    const status = try gitOutputAlloc(io, work, &.{ "git", "status", "--porcelain=v1" });
    defer std.testing.allocator.free(status);
    try std.testing.expectEqualStrings("MM README.md\n?? local.txt\n", status);
}

test "operations switch branch preserves local state when Git refuses an overwrite" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    for ([_]bool{ true, false }) |tracked| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const fixture = try setupBranchSwitchFixture(io, &tmp);
        defer fixture.deinit();
        var work = try tmp.dir.openDir(io, "work", .{});
        defer work.close(io);
        if (tracked) {
            try runTestGit(io, &.{ "git", "switch", "feature/topic" }, work);
            try work.writeFile(io, .{ .sub_path = "README.md", .data = "target\n" });
            try runTestGit(io, &.{ "git", "add", "README.md" }, work);
            try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "target overlap" }, work);
            try runTestGit(io, &.{ "git", "switch", "main" }, work);
        }
        const target_oid = try gitOutputAlloc(io, work, &.{ "git", "rev-parse", "refs/heads/feature/topic" });
        defer allocator.free(target_oid);
        const path = if (tracked) "README.md" else "FEATURE.md";
        try work.writeFile(io, .{ .sub_path = path, .data = "local content\n" });
        if (tracked) try runTestGit(io, &.{ "git", "add", "README.md" }, work);
        const before_index = try gitOutputAlloc(io, work, &.{ "git", "write-tree" });
        defer allocator.free(before_index);
        const before_status = try gitOutputAlloc(io, work, &.{ "git", "status", "--porcelain=v1" });
        defer allocator.free(before_status);
        var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, null);
        defer environment.deinit();
        const result = try runOperation(allocator, io, .{
            .context = .{ .cwd = work, .environment = &environment },
            .kind = .{ .switch_branch = .{ .expected_branch = "main", .expected_oid = fixture.main_oid, .target_branch = "feature/topic", .target_oid = trimLineEnd(target_oid) } },
        });
        defer result.deinit(allocator);
        switch (result) {
            .failed => |message| {
                try std.testing.expect(std.mem.indexOf(u8, message, "would be overwritten") != null);
                try std.testing.expect(std.mem.indexOf(u8, message, path) != null);
            },
            else => return error.ExpectedGitOverwriteRefusal,
        }
        const current = try gitOutputAlloc(io, work, &.{ "git", "branch", "--show-current" });
        defer allocator.free(current);
        try std.testing.expectEqualStrings("main", trimLineEnd(current));
        const after_index = try gitOutputAlloc(io, work, &.{ "git", "write-tree" });
        defer allocator.free(after_index);
        try std.testing.expectEqualStrings(before_index, after_index);
        const after_status = try gitOutputAlloc(io, work, &.{ "git", "status", "--porcelain=v1" });
        defer allocator.free(after_status);
        try std.testing.expectEqualStrings(before_status, after_status);
        const content = try work.readFileAlloc(io, path, allocator, .limited(1024));
        defer allocator.free(content);
        try std.testing.expectEqualStrings("local content\n", content);
    }
}

test "operations switch branch does not guess remote-only targets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const fixture = try setupBranchSwitchFixture(io, &tmp);
    defer fixture.deinit();
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const result = try runOperation(std.testing.allocator, io, .{
        .context = .{ .cwd = work, .environment = &environment },
        .kind = .{ .switch_branch = .{ .expected_branch = "main", .expected_oid = fixture.main_oid, .target_branch = "remote-only", .target_oid = fixture.remote_only_oid } },
    });
    defer result.deinit(std.testing.allocator);
    switch (result) {
        .failed_static => |message| try std.testing.expectEqualStrings("branch list changed; reopen branch switch and try again", message),
        else => return error.ExpectedSwitchNoGuessFailure,
    }
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

const BranchSwitchFixture = struct {
    main_oid: []u8,
    feature_oid: []u8,
    remote_only_oid: []u8,

    fn deinit(self: BranchSwitchFixture) void {
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
    return .{ .main_oid = main_oid, .feature_oid = feature_oid, .remote_only_oid = remote_only_oid };
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

fn freeRunResult(allocator: std.mem.Allocator, result: std.process.RunResult) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}
