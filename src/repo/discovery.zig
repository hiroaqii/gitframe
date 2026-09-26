const std = @import("std");
const git_command = @import("../git/command.zig");
const root_capability = @import("root_capability.zig");

pub const RepoEntry = struct {
    /// Owned short label used in the picker. Usually the repository directory name.
    label: []const u8,
    /// Owned path shown to the user. Initial discovery uses a path relative to
    /// the scanned root for child repos and "." for the current repo.
    display_path: []const u8,
    /// Owned canonical repository root returned by Git.
    canonical_root: []const u8,
};

/// Owned repository discovery result.
///
/// Callers must release the returned value with `deinit()` using the same
/// allocator that was passed to `discover()` / `discoverRoot()`.
pub const DiscoveryResult = union(enum) {
    single_repo: RepoEntry,
    workspace: struct {
        current_root: []const u8,
        repos: []RepoEntry,
    },
    none: struct {
        current_root: []const u8,
    },

    pub fn deinit(self: *DiscoveryResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .single_repo => |entry| freeRepoEntry(allocator, entry),
            .workspace => |workspace| {
                allocator.free(workspace.current_root);
                for (workspace.repos) |entry| freeRepoEntry(allocator, entry);
                allocator.free(workspace.repos);
            },
            .none => |none| allocator.free(none.current_root),
        }
        self.* = .{ .none = .{ .current_root = "" } };
    }
};

pub const PathDiscoveryError = error{
    PathDoesNotExist,
    PathIsNotDirectory,
    CannotAccessPath,
    NoGitRepositoriesFound,
    OutOfMemory,
    SpawnFailed,
    StreamTooLong,
};

/// Discover the current process directory.
///
/// The returned `DiscoveryResult` is owned by the caller. The temporary cwd
/// allocation used by this convenience wrapper is not transferred into the
/// result and is always released before returning.
pub fn discover(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const git_command.LocalGitEnvironment,
) !DiscoveryResult {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    return discoverRoot(allocator, io, cwd, environment);
}

/// Discover repositories from a borrowed root path.
///
/// `root_path` is only borrowed for the duration of the call. Any path stored
/// in the returned `DiscoveryResult` is separately owned by the result.
pub fn discoverRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    environment: *const git_command.LocalGitEnvironment,
) !DiscoveryResult {
    const current_root = try realPathAbsoluteAlloc(allocator, io, root_path);
    errdefer allocator.free(current_root);

    if (resolveRepoRoot(allocator, io, current_root, environment)) |repo_root| {
        const entry = try repoEntryFromRoot(allocator, ".", repo_root);
        allocator.free(current_root);
        return .{ .single_repo = entry };
    } else |err| switch (err) {
        error.NotARepository => {},
        else => return err,
    }

    const repos = try discoverChildRepos(allocator, io, current_root, environment);
    errdefer {
        for (repos) |entry| freeRepoEntry(allocator, entry);
        allocator.free(repos);
    }

    if (repos.len == 0) {
        return .{ .none = .{ .current_root = current_root } };
    }

    return .{ .workspace = .{
        .current_root = current_root,
        .repos = repos,
    } };
}

/// Discover a user-submitted path from the repository picker.
///
/// Unlike `discoverRoot`, a directory with no repository is a user-facing
/// error here: path submit should keep the current repo open and show an
/// inline message instead of replacing discovery with `.none`.
pub fn discoverInputPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    environment: *const git_command.LocalGitEnvironment,
) PathDiscoveryError!DiscoveryResult {
    const current_root = realPathAbsoluteAlloc(allocator, io, path) catch |err| return mapRealPathError(err);
    defer allocator.free(current_root);

    var dir = std.Io.Dir.openDirAbsolute(io, current_root, .{ .iterate = true }) catch |err| return mapOpenDirError(err);
    dir.close(io);

    var result = discoverRoot(allocator, io, current_root, environment) catch |err| return mapDiscoveryError(err);
    errdefer result.deinit(allocator);

    if (result == .none) return error.NoGitRepositoriesFound;
    return result;
}

fn discoverChildRepos(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    environment: *const git_command.LocalGitEnvironment,
) ![]RepoEntry {
    var root_dir = try std.Io.Dir.openDirAbsolute(io, root_path, .{ .iterate = true });
    defer root_dir.close(io);

    var repos: std.ArrayList(RepoEntry) = .empty;
    errdefer {
        for (repos.items) |entry| freeRepoEntry(allocator, entry);
        repos.deinit(allocator);
    }

    var iter = root_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (isDotEntry(entry.name)) continue;

        const child_path = try std.fs.path.join(allocator, &.{ root_path, entry.name });
        defer allocator.free(child_path);

        const repo_root = resolveRepoRoot(allocator, io, child_path, environment) catch |err| switch (err) {
            error.NotARepository => continue,
            else => return err,
        };
        const repo_entry = try repoEntryFromRoot(allocator, entry.name, repo_root);
        repos.append(allocator, repo_entry) catch |err| {
            freeRepoEntry(allocator, repo_entry);
            return err;
        };
    }

    std.mem.sort(RepoEntry, repos.items, {}, compareRepoEntryByDisplayPath);
    return try repos.toOwnedSlice(allocator);
}

const ResolveRepoRootError = error{
    NotARepository,
    OutOfMemory,
    StreamTooLong,
    SpawnFailed,
};

fn resolveRepoRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    environment: *const git_command.LocalGitEnvironment,
) ResolveRepoRootError![]u8 {
    const canonical_candidate = realPathAbsoluteAlloc(allocator, io, path) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.SpawnFailed,
    };
    defer allocator.free(canonical_candidate);

    var root = root_capability.RootCapability.openCanonical(canonical_candidate) catch return error.SpawnFailed;
    defer root.deinit();
    return resolveRepoRootInDir(allocator, io, root.dir(), environment);
}

fn resolveRepoRootInDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    environment: *const git_command.LocalGitEnvironment,
) ResolveRepoRootError![]u8 {
    const result = try git_command.runCaptured(allocator, io, .{ .cwd = cwd, .environment = environment }, .{
        .argv = &.{ "git", "rev-parse", "--show-toplevel" },
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    });
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code == 0 and result.stdout.len > 0) {
            return rootRecordAndDupe(allocator, result.stdout);
        },
        else => {},
    }

    allocator.free(result.stdout);
    return error.NotARepository;
}

fn repoEntryFromRoot(allocator: std.mem.Allocator, display_path: []const u8, repo_root: []u8) !RepoEntry {
    errdefer allocator.free(repo_root);
    const label = try repoLabel(allocator, repo_root);
    errdefer allocator.free(label);
    const owned_display_path = try allocator.dupe(u8, display_path);

    return .{
        .label = label,
        .display_path = owned_display_path,
        .canonical_root = repo_root,
    };
}

fn compareRepoEntryByDisplayPath(_: void, lhs: RepoEntry, rhs: RepoEntry) bool {
    return std.mem.lessThan(u8, lhs.display_path, rhs.display_path);
}

fn freeRepoEntry(allocator: std.mem.Allocator, entry: RepoEntry) void {
    allocator.free(entry.label);
    allocator.free(entry.display_path);
    allocator.free(entry.canonical_root);
}

fn repoLabel(allocator: std.mem.Allocator, canonical_root: []const u8) ![]u8 {
    const base = std.fs.path.basename(canonical_root);
    if (base.len > 0) return allocator.dupe(u8, base);
    return allocator.dupe(u8, canonical_root);
}

fn realPathAbsoluteAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const path_z = try std.Io.Dir.realPathFileAbsoluteAlloc(io, path, allocator);
    defer allocator.free(path_z);
    return allocator.dupe(u8, path_z);
}

fn rootRecordAndDupe(allocator: std.mem.Allocator, bytes: []u8) ![]u8 {
    defer allocator.free(bytes);
    // Git emits one LF record terminator; every preceding byte belongs to the path.
    const end = bytes.len - @intFromBool(std.mem.endsWith(u8, bytes, "\n"));
    return allocator.dupe(u8, bytes[0..end]);
}

fn isDotEntry(name: []const u8) bool {
    return std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..");
}

fn mapRealPathError(err: anyerror) PathDiscoveryError {
    return switch (err) {
        error.FileNotFound => error.PathDoesNotExist,
        error.NotDir => error.PathIsNotDirectory,
        error.AccessDenied, error.PermissionDenied => error.CannotAccessPath,
        error.OutOfMemory => error.OutOfMemory,
        else => error.CannotAccessPath,
    };
}

fn mapOpenDirError(err: anyerror) PathDiscoveryError {
    return switch (err) {
        error.FileNotFound => error.PathDoesNotExist,
        error.NotDir => error.PathIsNotDirectory,
        error.AccessDenied, error.PermissionDenied => error.CannotAccessPath,
        else => error.CannotAccessPath,
    };
}

fn mapDiscoveryError(err: anyerror) PathDiscoveryError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.StreamTooLong,
        error.SpawnFailed => error.SpawnFailed,
        error.FileNotFound => error.PathDoesNotExist,
        error.NotDir => error.PathIsNotDirectory,
        error.AccessDenied, error.PermissionDenied => error.CannotAccessPath,
        else => error.CannotAccessPath,
    };
}

test "repoLabel uses final path component" {
    const label = try repoLabel(std.testing.allocator, "/tmp/work/gitframe");
    defer std.testing.allocator.free(label);
    try std.testing.expectEqualStrings("gitframe", label);
}

test "rootRecordAndDupe strips only the Git record terminator" {
    for ([_][]const u8{ "/tmp/repo", "/tmp/repo ", "/tmp/repo\t", "/tmp/repo\r", "/tmp/repo\n" }) |path| {
        const raw = try std.fmt.allocPrint(std.testing.allocator, "{s}\n", .{path});
        const parsed = try rootRecordAndDupe(std.testing.allocator, raw);
        defer std.testing.allocator.free(parsed);
        try std.testing.expectEqualStrings(path, parsed);
    }
}

test "DiscoveryResult deinit releases none state" {
    var result: DiscoveryResult = .{ .none = .{ .current_root = try std.testing.allocator.dupe(u8, "/tmp/work") } };
    result.deinit(std.testing.allocator);
    try std.testing.expect(result == .none);
}

test "RepoEntry sort uses display path" {
    const allocator = std.testing.allocator;
    var entries = [_]RepoEntry{
        .{
            .label = try allocator.dupe(u8, "zeta"),
            .display_path = try allocator.dupe(u8, "zeta"),
            .canonical_root = try allocator.dupe(u8, "/tmp/zeta"),
        },
        .{
            .label = try allocator.dupe(u8, "alpha"),
            .display_path = try allocator.dupe(u8, "alpha"),
            .canonical_root = try allocator.dupe(u8, "/tmp/alpha"),
        },
    };
    defer {
        for (entries) |entry| freeRepoEntry(allocator, entry);
    }

    std.mem.sort(RepoEntry, entries[0..], {}, compareRepoEntryByDisplayPath);

    try std.testing.expectEqualStrings("alpha", entries[0].display_path);
    try std.testing.expectEqualStrings("zeta", entries[1].display_path);
}

test "discover owns and releases temporary cwd on success" {
    var environment = try testEnvironment(std.testing.allocator);
    defer environment.deinit();
    var result = discover(std.testing.allocator, std.testing.io, &environment) catch |err| switch (err) {
        error.SpawnFailed => return error.SkipZigTest,
        else => return err,
    };
    result.deinit(std.testing.allocator);
}

test "discoverRoot returns none for a directory without repos" {
    var root = try TestRoot.create(std.testing.allocator);
    defer root.cleanup(std.testing.allocator);

    var result = try discoverRootOrSkip(root.path);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result == .none);
    try std.testing.expect(result.none.current_root.len > 0);
}

test "discoverRoot returns single repo for the root repo" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var root = try TestRoot.create(std.testing.allocator);
    defer root.cleanup(std.testing.allocator);
    try gitInitOrSkip(root.path);

    const redirect_path = try std.fs.path.join(allocator, &.{ root.path, "redirect" });
    defer allocator.free(redirect_path);
    try std.Io.Dir.createDirAbsolute(io, redirect_path, .default_dir);
    try gitInitOrSkip(redirect_path);
    const redirect_git_dir = try std.fs.path.join(allocator, &.{ redirect_path, ".git" });
    defer allocator.free(redirect_git_dir);

    var parent = try std.testing.environ.createMap(allocator);
    defer parent.deinit();
    try parent.put("GIT_DIR", redirect_git_dir);
    try parent.put("GIT_WORK_TREE", redirect_path);
    try parent.put("GIT_CONFIG_COUNT", "1");
    try parent.put("GIT_CONFIG_KEY_0", "core.bare");
    try parent.put("GIT_CONFIG_VALUE_0", "true");

    var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, &parent);
    defer environment.deinit();
    var result = discoverRoot(allocator, io, root.path, &environment) catch |err| switch (err) {
        error.SpawnFailed => return error.SkipZigTest,
        else => return err,
    };
    defer result.deinit(allocator);

    try std.testing.expect(result == .single_repo);
    try std.testing.expectEqualStrings(".", result.single_repo.display_path);
    try std.testing.expect(result.single_repo.label.len > 0);
    const canonical_root = try realPathAbsoluteAlloc(allocator, io, root.path);
    defer allocator.free(canonical_root);
    try std.testing.expectEqualStrings(canonical_root, result.single_repo.canonical_root);

    const candidate_path = try std.fs.path.join(allocator, &.{ root.path, "candidate" });
    defer allocator.free(candidate_path);
    const replacement_path = try std.fs.path.join(allocator, &.{ root.path, "replacement" });
    defer allocator.free(replacement_path);
    const accepted_path = try std.fs.path.join(allocator, &.{ root.path, "accepted" });
    defer allocator.free(accepted_path);
    try std.Io.Dir.createDirAbsolute(io, candidate_path, .default_dir);
    try std.Io.Dir.createDirAbsolute(io, replacement_path, .default_dir);
    try gitInitOrSkip(candidate_path);
    try gitInitOrSkip(replacement_path);

    var accepted = try root_capability.RootCapability.openCanonical(candidate_path);
    defer accepted.deinit();
    var root_dir = try std.Io.Dir.openDirAbsolute(io, root.path, .{});
    defer root_dir.close(io);
    try root_dir.rename("candidate", root_dir, "accepted", io);
    try root_dir.rename("replacement", root_dir, "candidate", io);

    const resolved = try resolveRepoRootInDir(allocator, io, accepted.dir(), &environment);
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings(accepted_path, resolved);
    try std.testing.expect(!std.mem.eql(u8, candidate_path, resolved));
}

test "discoverRoot returns workspace for direct child repos" {
    var root = try TestRoot.create(std.testing.allocator);
    defer root.cleanup(std.testing.allocator);

    const alpha_path = try std.fs.path.join(std.testing.allocator, &.{ root.path, "alpha" });
    defer std.testing.allocator.free(alpha_path);
    const zeta_path = try std.fs.path.join(std.testing.allocator, &.{ root.path, "zeta" });
    defer std.testing.allocator.free(zeta_path);

    try std.Io.Dir.createDirAbsolute(std.testing.io, alpha_path, .default_dir);
    try std.Io.Dir.createDirAbsolute(std.testing.io, zeta_path, .default_dir);

    try gitInitOrSkip(zeta_path);
    try gitInitOrSkip(alpha_path);

    var result = try discoverRootOrSkip(root.path);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result == .workspace);
    try std.testing.expect(result.workspace.current_root.len > 0);
    try std.testing.expectEqual(@as(usize, 2), result.workspace.repos.len);
    try std.testing.expectEqualStrings("alpha", result.workspace.repos[0].display_path);
    try std.testing.expectEqualStrings("zeta", result.workspace.repos[1].display_path);
}

const TestRoot = struct {
    parent_dir: std.Io.Dir,
    sub_path: []u8,
    path: []u8,

    fn create(allocator: std.mem.Allocator) !TestRoot {
        var parent_dir = try std.Io.Dir.openDirAbsolute(std.testing.io, "/tmp", .{});
        errdefer parent_dir.close(std.testing.io);

        var random_bytes: [12]u8 = undefined;
        std.testing.io.random(&random_bytes);
        var encoded: [std.base64.url_safe.Encoder.calcSize(random_bytes.len)]u8 = undefined;
        const random_name = std.base64.url_safe.Encoder.encode(&encoded, &random_bytes);
        const sub_path = try std.fmt.allocPrint(allocator, "gitframe-repo-discovery-{s}", .{random_name});
        errdefer allocator.free(sub_path);

        try parent_dir.createDirPath(std.testing.io, sub_path);
        const alias_path = try std.fs.path.join(allocator, &.{ "/tmp", sub_path });
        defer allocator.free(alias_path);
        const path = try realPathAbsoluteAlloc(allocator, std.testing.io, alias_path);
        errdefer allocator.free(path);

        return .{
            .parent_dir = parent_dir,
            .sub_path = sub_path,
            .path = path,
        };
    }

    fn cleanup(self: *TestRoot, allocator: std.mem.Allocator) void {
        self.parent_dir.deleteTree(std.testing.io, self.sub_path) catch {};
        self.parent_dir.close(std.testing.io);
        allocator.free(self.sub_path);
        allocator.free(self.path);
        self.* = undefined;
    }
};

fn discoverRootOrSkip(root_path: []const u8) !DiscoveryResult {
    var environment = try testEnvironment(std.testing.allocator);
    defer environment.deinit();
    return discoverRoot(std.testing.allocator, std.testing.io, root_path, &environment) catch |err| switch (err) {
        error.SpawnFailed => error.SkipZigTest,
        else => err,
    };
}

fn testEnvironment(allocator: std.mem.Allocator) !git_command.LocalGitEnvironment {
    var parent = try std.testing.environ.createMap(allocator);
    defer parent.deinit();
    return git_command.LocalGitEnvironment.initFromParent(allocator, &parent);
}

fn gitInitOrSkip(path: []const u8) !void {
    const result = std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "git", "init", "--quiet" },
        .cwd = .{ .path = path },
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SkipZigTest,
    };
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.SkipZigTest;
}

test "discoverRoot preserves whitespace and pins the matching sibling" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var environment = try testEnvironment(allocator);
    defer environment.deinit();
    for ([_][]const u8{ "repo", "repo ", "repo\t", "repo\r", "repo\n" }) |name| {
        try tmp.dir.createDir(io, name, .default_dir);
        const expected_path = try tmp.dir.realPathFileAlloc(io, name, allocator);
        defer allocator.free(expected_path);
        try gitInitOrSkip(expected_path);
        var dir = try tmp.dir.openDir(io, name, .{});
        defer dir.close(io);
        try dir.writeFile(io, .{ .sub_path = "marker", .data = name });
        var result = try discoverRoot(allocator, io, expected_path, &environment);
        defer result.deinit(allocator);
        try std.testing.expect(result == .single_repo);
        try std.testing.expectEqualStrings(expected_path, result.single_repo.canonical_root);
        var pinned = try root_capability.RootCapability.openCanonical(result.single_repo.canonical_root);
        defer pinned.deinit();
        const marker = try pinned.dir().readFileAlloc(io, "marker", allocator, .limited(1024));
        defer allocator.free(marker);
        try std.testing.expectEqualStrings(name, marker);
    }
}
