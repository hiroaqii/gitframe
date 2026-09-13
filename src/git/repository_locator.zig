//! Descriptor-authorized discovery of a Git common-directory physical identity.
//!
//! Git supplies a bounded canonical absolute path; this module opens it with
//! no-follow component traversal and returns only copied device/inode values.

const std = @import("std");
const builtin = @import("builtin");
const binding = @import("../committed_review/repository_binding.zig");
const git_command = @import("command.zig");
const root_capability = @import("../repo/root_capability.zig");

/// Machine-local value returned after descriptor-authorized discovery.
pub const GitCommonDirectoryLocator = binding.GitCommonDirectoryLocator;

const stdout_capture_bytes: usize = std.Io.Dir.max_path_bytes + 1;
const stderr_capture_bytes: usize = 8 * 1024;
const worktree_stdout_capture_bytes: usize = 1024 * 1024;

/// Operation-specific locator terminals; no failure contains a partial locator.
pub const RepositoryLocatorFailure = enum {
    invalid_repository,
    invalid_common_directory,
    common_directory_unavailable,
    git_command_failed,
    unsupported_platform,
};

/// Complete physical locator or one locator-specific terminal.
pub const RepositoryLocatorResult = union(enum) {
    locator: GitCommonDirectoryLocator,
    failure: RepositoryLocatorFailure,
};

pub const MainWorktreeResult = union(enum) {
    basename: []u8,
    unavailable,

    pub fn deinit(self: *MainWorktreeResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .basename => |value| allocator.free(value),
            .unavailable => {},
        }
        self.* = .unavailable;
    }
};

/// Resolve and open the common directory for the borrowed repository context.
/// Child captures and descriptors are released before the value result escapes.
pub fn locate(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
) std.mem.Allocator.Error!RepositoryLocatorResult {
    const argv = [_][]const u8{
        "git",
        "--no-optional-locks",
        "rev-parse",
        "--path-format=absolute",
        "--git-common-dir",
    };
    var command_result = try git_command.runCapturedBounded(allocator, io, context, .{
        .argv = &argv,
        .stdout_limit = .limited(stdout_capture_bytes),
        .stderr_limit = .limited(stderr_capture_bytes),
    });
    defer command_result.deinit(allocator);
    const completed = switch (command_result) {
        .completed => |value| value,
        .stdout_limit_exceeded, .stderr_limit_exceeded, .failed => return .{ .failure = .git_command_failed },
    };
    switch (completed.term) {
        .exited => |code| if (code != 0) return .{ .failure = .invalid_repository },
        else => return .{ .failure = .git_command_failed },
    }
    return locateGitOutput(completed.stdout);
}

/// Read Git's first porcelain worktree record. Git defines that record as the
/// main worktree; linked-worktree cwd therefore resolves to the same basename.
pub fn mainWorktreeBasename(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
) std.mem.Allocator.Error!MainWorktreeResult {
    return mainWorktreeBasenameUsing(allocator, io, context, "git");
}

fn mainWorktreeBasenameUsing(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    executable: []const u8,
) std.mem.Allocator.Error!MainWorktreeResult {
    const argv = [_][]const u8{
        executable,
        "--no-optional-locks",
        "worktree",
        "list",
        "--porcelain",
        "-z",
    };
    var command_result = try git_command.runCapturedBounded(allocator, io, context, .{
        .argv = &argv,
        .stdout_limit = .limited(worktree_stdout_capture_bytes),
        .stderr_limit = .limited(stderr_capture_bytes),
    });
    defer command_result.deinit(allocator);
    const completed = switch (command_result) {
        .completed => |value| value,
        .stdout_limit_exceeded, .stderr_limit_exceeded, .failed => return .unavailable,
    };
    switch (completed.term) {
        .exited => |code| if (code != 0) return .unavailable,
        else => return .unavailable,
    }
    const path = firstMainWorktreePath(completed.stdout) orelse return .unavailable;
    var capability = root_capability.RootCapability.openCanonical(path) catch return .unavailable;
    defer capability.deinit();
    const separator = std.mem.lastIndexOfScalar(u8, path, '/') orelse return .unavailable;
    const basename = path[separator + 1 ..];
    return .{ .basename = try allocator.dupe(u8, basename) };
}

fn firstMainWorktreePath(bytes: []const u8) ?[]const u8 {
    if (bytes.len == 0 or bytes[bytes.len - 1] != 0) return null;
    const record_end = std.mem.indexOf(u8, bytes, "\x00\x00") orelse return null;
    var fields = std.mem.splitScalar(u8, bytes[0..record_end], 0);
    const worktree_field = fields.next() orelse return null;
    const prefix = "worktree ";
    if (!std.mem.startsWith(u8, worktree_field, prefix)) return null;
    const path = canonicalAbsolutePath(worktree_field[prefix.len..]) orelse return null;
    if (path.len == 1) return null;

    while (fields.next()) |field| {
        if (field.len == 0) return null;
        if (std.mem.eql(u8, field, "bare")) return null;
    }
    return path;
}

fn locateGitOutput(stdout: []const u8) RepositoryLocatorResult {
    const common_directory = singleAbsolutePath(stdout) orelse
        return .{ .failure = .invalid_common_directory };
    return locateCommonDirectory(common_directory);
}

fn locateCommonDirectory(common_directory: []const u8) RepositoryLocatorResult {
    var capability = root_capability.RootCapability.openCanonical(common_directory) catch |err| {
        return .{ .failure = if (err == error.UnsupportedPlatform)
            .unsupported_platform
        else
            .common_directory_unavailable };
    };
    defer capability.deinit();
    return .{ .locator = .{
        .device = capability.identity.device,
        .inode = capability.identity.inode,
    } };
}

fn singleAbsolutePath(bytes: []const u8) ?[]const u8 {
    if (bytes.len < 2 or bytes[bytes.len - 1] != '\n') return null;
    const path = bytes[0 .. bytes.len - 1];
    if (std.mem.indexOfAny(u8, path, "\r\n\x00") != null) return null;
    return canonicalAbsolutePath(path);
}

fn canonicalAbsolutePath(path: []const u8) ?[]const u8 {
    if (path.len == 0 or path.len >= std.Io.Dir.max_path_bytes or path[0] != '/') return null;
    if (path.len > 1) {
        var components = std.mem.splitScalar(u8, path[1..], '/');
        while (components.next()) |component| {
            if (component.len == 0 or
                std.mem.eql(u8, component, ".") or
                std.mem.eql(u8, component, "..")) return null;
        }
    }
    return path;
}

fn runTestGit(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) !void {
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

fn testGitOutput(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) ![]u8 {
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

fn openCapabilityAt(io: std.Io, parent: std.Io.Dir, sub_path: []const u8) !root_capability.RootCapability {
    const path = try parent.realPathFileAlloc(io, sub_path, std.testing.allocator);
    defer std.testing.allocator.free(path);
    return root_capability.RootCapability.openCanonical(path);
}

fn locateAt(
    io: std.Io,
    parent: std.Io.Dir,
    sub_path: []const u8,
    environment: *const git_command.LocalGitEnvironment,
) !RepositoryLocatorResult {
    var root = try openCapabilityAt(io, parent, sub_path);
    defer root.deinit();
    return locate(std.testing.allocator, io, .{ .cwd = root.dir(), .environment = environment });
}

fn expectLocator(result: RepositoryLocatorResult) !GitCommonDirectoryLocator {
    return switch (result) {
        .locator => |locator| locator,
        .failure => error.ExpectedRepositoryLocator,
    };
}

test "linked worktrees share one Git common-directory locator" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "main", .default_dir);
    var main = try tmp.dir.openDir(io, "main", .{});
    defer main.close(io);
    try runTestGit(io, main, &.{ "git", "init", "--initial-branch=main" });
    try main.writeFile(io, .{ .sub_path = "file", .data = "base\n" });
    try runTestGit(io, main, &.{ "git", "add", "file" });
    try runTestGit(io, main, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
    try runTestGit(io, main, &.{ "git", "worktree", "add", "../linked", "-b", "linked" });

    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const main_locator = try expectLocator(try locateAt(io, tmp.dir, "main", &environment));
    const linked_locator = try expectLocator(try locateAt(io, tmp.dir, "linked", &environment));
    try std.testing.expect(main_locator.eql(linked_locator));
}

test "distinct clones of one remote keep distinct physical locators" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try runTestGit(io, tmp.dir, &.{ "git", "init", "--bare", "remote.git" });
    try runTestGit(io, tmp.dir, &.{ "git", "clone", "remote.git", "clone-a" });
    try runTestGit(io, tmp.dir, &.{ "git", "clone", "remote.git", "clone-b" });

    var clone_a = try tmp.dir.openDir(io, "clone-a", .{});
    defer clone_a.close(io);
    var clone_b = try tmp.dir.openDir(io, "clone-b", .{});
    defer clone_b.close(io);
    const first_remote = try testGitOutput(io, clone_a, &.{ "git", "config", "--get", "remote.origin.url" });
    defer std.testing.allocator.free(first_remote);
    const second_remote = try testGitOutput(io, clone_b, &.{ "git", "config", "--get", "remote.origin.url" });
    defer std.testing.allocator.free(second_remote);
    try std.testing.expectEqualStrings(first_remote, second_remote);

    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    var clone_a_root = try openCapabilityAt(io, tmp.dir, "clone-a");
    defer clone_a_root.deinit();
    var clone_b_root = try openCapabilityAt(io, tmp.dir, "clone-b");
    defer clone_b_root.deinit();
    var clone_a_name = try mainWorktreeBasename(std.testing.allocator, io, .{ .cwd = clone_a_root.dir(), .environment = &environment });
    defer clone_a_name.deinit(std.testing.allocator);
    var clone_b_name = try mainWorktreeBasename(std.testing.allocator, io, .{ .cwd = clone_b_root.dir(), .environment = &environment });
    defer clone_b_name.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("clone-a", clone_a_name.basename);
    try std.testing.expectEqualStrings("clone-b", clone_b_name.basename);
    const first = try expectLocator(try locateAt(io, tmp.dir, "clone-a", &environment));
    const second = try expectLocator(try locateAt(io, tmp.dir, "clone-b", &environment));
    try std.testing.expect(!first.eql(second));
}

test "same-filesystem repository rename retains the common-directory locator" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "repo", .default_dir);
    var repo = try tmp.dir.openDir(io, "repo", .{});
    defer repo.close(io);
    try runTestGit(io, repo, &.{ "git", "init", "--initial-branch=main" });

    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const before = try expectLocator(try locateAt(io, tmp.dir, "repo", &environment));
    try tmp.dir.rename("repo", tmp.dir, "moved", io);
    const after = try expectLocator(try locateAt(io, tmp.dir, "moved", &environment));
    try std.testing.expect(before.eql(after));
}

test "common-directory symlink redirection and non-repository input fail closed" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "repo", .default_dir);
    var repo = try tmp.dir.openDir(io, "repo", .{});
    defer repo.close(io);
    try runTestGit(io, repo, &.{ "git", "init", "--initial-branch=main" });
    try repo.rename(".git", repo, "actual-git", io);
    try repo.symLink(io, "actual-git", ".git", .{ .is_directory = true });

    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const repo_path = try tmp.dir.realPathFileAlloc(io, "repo", std.testing.allocator);
    defer std.testing.allocator.free(repo_path);
    const linked_common_directory = try std.fs.path.join(std.testing.allocator, &.{ repo_path, ".git" });
    defer std.testing.allocator.free(linked_common_directory);
    const redirected = locateCommonDirectory(linked_common_directory);
    try std.testing.expect(redirected == .failure);
    try std.testing.expectEqual(RepositoryLocatorFailure.common_directory_unavailable, redirected.failure);

    try tmp.dir.createDir(io, "not-a-repository", .default_dir);
    var not_a_repository = try tmp.dir.openDir(io, "not-a-repository", .{});
    defer not_a_repository.close(io);
    try not_a_repository.writeFile(io, .{ .sub_path = ".git", .data = "not a gitdir record\n" });
    const invalid = try locateAt(io, tmp.dir, "not-a-repository", &environment);
    try std.testing.expect(invalid == .failure);
    try std.testing.expectEqual(RepositoryLocatorFailure.invalid_repository, invalid.failure);
}

test "common-directory output parser is absolute single-line and bounded" {
    try std.testing.expectEqualStrings("/repo/.git", singleAbsolutePath("/repo/.git\n").?);
    try std.testing.expect(singleAbsolutePath("repo/.git\n") == null);
    try std.testing.expect(singleAbsolutePath("/repo/.git") == null);
    try std.testing.expect(singleAbsolutePath("/repo\n/.git\n") == null);
    try std.testing.expect(singleAbsolutePath("/repo\r\n") == null);

    const noncanonical = [_][]const u8{
        "/repo/./.git\n",
        "/repo/../other\n",
        "/repo//.git\n",
        "/repo/.git/\n",
    };
    for (noncanonical) |output| {
        try std.testing.expect(singleAbsolutePath(output) == null);
        const result = locateGitOutput(output);
        try std.testing.expect(result == .failure);
        try std.testing.expectEqual(RepositoryLocatorFailure.invalid_common_directory, result.failure);
    }

    const boundary = try std.testing.allocator.alloc(u8, std.Io.Dir.max_path_bytes + 1);
    defer std.testing.allocator.free(boundary);
    @memset(boundary, 'a');
    boundary[0] = '/';
    boundary[std.Io.Dir.max_path_bytes - 1] = '\n';
    try std.testing.expectEqual(
        std.Io.Dir.max_path_bytes - 1,
        singleAbsolutePath(boundary[0..std.Io.Dir.max_path_bytes]).?.len,
    );
    boundary[std.Io.Dir.max_path_bytes - 1] = 'a';
    boundary[std.Io.Dir.max_path_bytes] = '\n';
    try std.testing.expect(singleAbsolutePath(boundary) == null);
}

test "review repository name parser returns only a finite canonical first non-bare worktree path" {
    const output = "worktree /work/Main-Repo\x00HEAD 0123456789abcdef\x00branch refs/heads/main\x00\x00" ++
        "worktree /work/linked\x00HEAD fedcba9876543210\x00detached\x00\x00";
    try std.testing.expectEqualStrings("/work/Main-Repo", firstMainWorktreePath(output).?);
    try std.testing.expect(firstMainWorktreePath("worktree /work/bare.git\x00bare\x00\x00") == null);
    try std.testing.expect(firstMainWorktreePath("worktree relative\x00HEAD x\x00\x00") == null);
    try std.testing.expect(firstMainWorktreePath("worktree /work/repo\x00HEAD x\x00") == null);
    try std.testing.expect(firstMainWorktreePath("worktree /work/./repo\x00HEAD x\x00\x00") == null);
    try std.testing.expect(firstMainWorktreePath("worktree /work/../repo\x00HEAD x\x00\x00") == null);
    try std.testing.expect(firstMainWorktreePath("worktree /work//repo\x00HEAD x\x00\x00") == null);
    try std.testing.expect(firstMainWorktreePath("worktree /work/repo/\x00HEAD x\x00\x00") == null);

    const oversized_path = try std.testing.allocator.alloc(u8, std.Io.Dir.max_path_bytes);
    defer std.testing.allocator.free(oversized_path);
    @memset(oversized_path, 'a');
    oversized_path[0] = '/';
    const oversized_output = try std.fmt.allocPrint(
        std.testing.allocator,
        "worktree {s}\x00HEAD x\x00\x00",
        .{oversized_path},
    );
    defer std.testing.allocator.free(oversized_output);
    try std.testing.expect(firstMainWorktreePath(oversized_output) == null);
}

test "review repository name discovery rejects fake Git paths that cannot be admitted" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "main", .default_dir);
    try tmp.dir.symLink(io, "main", "linked-main", .{ .is_directory = true });
    const root_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root_path);
    const nonexistent_path = try std.fs.path.join(allocator, &.{ root_path, "missing-main" });
    defer allocator.free(nonexistent_path);
    const linked_path = try std.fs.path.join(allocator, &.{ root_path, "linked-main" });
    defer allocator.free(linked_path);
    const noncanonical_path = try std.fmt.allocPrint(allocator, "{s}/main/../main", .{root_path});
    defer allocator.free(noncanonical_path);
    const oversized_path = try allocator.alloc(u8, std.Io.Dir.max_path_bytes);
    defer allocator.free(oversized_path);
    @memset(oversized_path, 'a');
    oversized_path[0] = '/';
    const executable = try std.fs.path.join(allocator, &.{ root_path, "fake-git" });
    defer allocator.free(executable);
    var root = try root_capability.RootCapability.openCanonical(root_path);
    defer root.deinit();
    var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, null);
    defer environment.deinit();

    for ([_][]const u8{ nonexistent_path, linked_path, noncanonical_path, oversized_path }) |invalid_path| {
        const script = try std.fmt.allocPrint(
            allocator,
            "#!/bin/sh\nprintf 'worktree %s\\000HEAD 0123456789abcdef0123456789abcdef01234567\\000branch refs/heads/main\\000\\000' \"{s}\"\n",
            .{invalid_path},
        );
        defer allocator.free(script);
        try tmp.dir.writeFile(io, .{
            .sub_path = "fake-git",
            .data = script,
            .flags = .{ .permissions = .fromMode(0o700) },
        });
        var discovered = try mainWorktreeBasenameUsing(allocator, io, .{
            .cwd = root.dir(),
            .environment = &environment,
        }, executable);
        defer discovered.deinit(allocator);
        try std.testing.expect(discovered == .unavailable);
    }
}

test "review repository name discovery is stable from linked worktrees" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "Main-Repo", .default_dir);
    var main = try tmp.dir.openDir(io, "Main-Repo", .{});
    defer main.close(io);
    try runTestGit(io, main, &.{ "git", "init", "--initial-branch=main" });
    try main.writeFile(io, .{ .sub_path = "file", .data = "base\n" });
    try runTestGit(io, main, &.{ "git", "add", "file" });
    try runTestGit(io, main, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
    try runTestGit(io, main, &.{ "git", "worktree", "add", "../linked-name", "-b", "linked-name" });

    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    var main_root = try openCapabilityAt(io, tmp.dir, "Main-Repo");
    defer main_root.deinit();
    var linked_root = try openCapabilityAt(io, tmp.dir, "linked-name");
    defer linked_root.deinit();
    var from_main = try mainWorktreeBasename(std.testing.allocator, io, .{ .cwd = main_root.dir(), .environment = &environment });
    defer from_main.deinit(std.testing.allocator);
    var from_linked = try mainWorktreeBasename(std.testing.allocator, io, .{ .cwd = linked_root.dir(), .environment = &environment });
    defer from_linked.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Main-Repo", from_main.basename);
    try std.testing.expectEqualStrings("Main-Repo", from_linked.basename);
}

test "review repository name discovery handles bare separate-git-dir and submodule repositories" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try runTestGit(io, tmp.dir, &.{ "git", "init", "--bare", "Bare.git" });
    try runTestGit(io, tmp.dir, &.{ "git", "init", "--initial-branch=main", "--separate-git-dir", "Separate-Metadata", "Separate-Worktree" });

    try tmp.dir.createDir(io, "Submodule-Source", .default_dir);
    var source = try tmp.dir.openDir(io, "Submodule-Source", .{});
    defer source.close(io);
    try runTestGit(io, source, &.{ "git", "init", "--initial-branch=main" });
    try source.writeFile(io, .{ .sub_path = "file", .data = "submodule\n" });
    try runTestGit(io, source, &.{ "git", "add", "file" });
    try runTestGit(io, source, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
    try tmp.dir.createDir(io, "Super", .default_dir);
    var super = try tmp.dir.openDir(io, "Super", .{});
    defer super.close(io);
    try runTestGit(io, super, &.{ "git", "init", "--initial-branch=main" });
    try runTestGit(io, super, &.{ "git", "-c", "protocol.file.allow=always", "submodule", "add", "../Submodule-Source", "deps/Child" });

    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    var bare_root = try openCapabilityAt(io, tmp.dir, "Bare.git");
    defer bare_root.deinit();
    var bare_name = try mainWorktreeBasename(std.testing.allocator, io, .{ .cwd = bare_root.dir(), .environment = &environment });
    defer bare_name.deinit(std.testing.allocator);
    try std.testing.expect(bare_name == .unavailable);

    var separate_root = try openCapabilityAt(io, tmp.dir, "Separate-Worktree");
    defer separate_root.deinit();
    var separate_name = try mainWorktreeBasename(std.testing.allocator, io, .{ .cwd = separate_root.dir(), .environment = &environment });
    defer separate_name.deinit(std.testing.allocator);
    // The agreed porcelain first-record authority reports the separate Git
    // directory as this repository's main entry; do not infer another path.
    try std.testing.expectEqualStrings("Separate-Metadata", separate_name.basename);

    var submodule_root = try openCapabilityAt(io, tmp.dir, "Super/deps/Child");
    defer submodule_root.deinit();
    var submodule_name = try mainWorktreeBasename(std.testing.allocator, io, .{ .cwd = submodule_root.dir(), .environment = &environment });
    defer submodule_name.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Child", submodule_name.basename);
}
