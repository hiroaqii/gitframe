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
    cached,
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

pub const NoIndexDiffRequest = struct {
    environment: *const git_command.LocalGitEnvironment,
    left: []const u8,
    right: []const u8,
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

const git_diff_unstaged = [_][]const u8{ "git", "diff", "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/" };
const git_diff_cached = [_][]const u8{ "git", "diff", "--cached", "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/" };
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
        .cached => loadGitDiff(allocator, io, request.context, &git_diff_cached),
        .file => |file| loadGitFileDiff(allocator, io, request.context, file),
        .range => |range| loadGitDiffRange(allocator, io, request.context, range),
    };
}

pub fn loadNoIndexDiff(allocator: std.mem.Allocator, io: std.Io, request: NoIndexDiffRequest) git_command.Error!LoadResult {
    const argv = [_][]const u8{
        "git",
        "diff",
        "--no-index",
        "--no-color",
        "--no-ext-diff",
        "--src-prefix=a/",
        "--dst-prefix=b/",
        "--",
        request.left,
        request.right,
    };
    const result = try git_command.runNonRepositoryCaptured(allocator, io, .inherit, request.environment, .{
        .argv = &argv,
        .stdout_limit = .limited(max_diff_bytes),
        .stderr_limit = .limited(256 * 1024),
    });

    if (isNoIndexSuccess(result.term, result.stdout.len)) {
        allocator.free(result.stderr);
        return .{ .ok = result.stdout };
    }
    allocator.free(result.stdout);
    if (result.stderr.len > 0) return .{ .failed = result.stderr };
    allocator.free(result.stderr);
    return .{ .failed = std.fmt.allocPrint(allocator, "git diff --no-index failed: {any}", .{result.term}) catch return error.OutOfMemory };
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
    try argv.append(allocator, "git");
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
            const argv = [_][]const u8{ "git", "diff", "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/", "--", request.path };
            return loadGitDiff(allocator, io, context, &argv);
        },
        .cached => {
            const argv = [_][]const u8{ "git", "diff", "--cached", "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/", "--", request.path };
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

fn isNoIndexSuccess(term: std.process.Child.Term, stdout_len: usize) bool {
    return switch (term) {
        .exited => |code| code == 0 or (code == 1 and stdout_len > 0),
        else => false,
    };
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

test "no-index diff treats exit one as success only with diff output" {
    try std.testing.expect(isNoIndexSuccess(.{ .exited = 0 }, 0));
    try std.testing.expect(isNoIndexSuccess(.{ .exited = 1 }, 1));
    try std.testing.expect(!isNoIndexSuccess(.{ .exited = 1 }, 0));
    try std.testing.expect(!isNoIndexSuccess(.{ .exited = 2 }, 1));
    try std.testing.expect(!isNoIndexSuccess(.{ .unknown = 9 }, 1));
}
