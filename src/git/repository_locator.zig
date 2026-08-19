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
    if (path.len >= std.Io.Dir.max_path_bytes or path[0] != '/') return null;
    if (std.mem.indexOfAny(u8, path, "\r\n\x00") != null) return null;
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
