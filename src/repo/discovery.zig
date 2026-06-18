const std = @import("std");

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

/// Discover the current process directory.
///
/// The returned `DiscoveryResult` is owned by the caller. The temporary cwd
/// allocation used by this convenience wrapper is not transferred into the
/// result and is always released before returning.
pub fn discover(allocator: std.mem.Allocator, io: std.Io) !DiscoveryResult {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    return discoverRoot(allocator, io, cwd);
}

/// Discover repositories from a borrowed root path.
///
/// `root_path` is only borrowed for the duration of the call. Any path stored
/// in the returned `DiscoveryResult` is separately owned by the result.
pub fn discoverRoot(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8) !DiscoveryResult {
    const current_root = try realPathAbsoluteAlloc(allocator, io, root_path);
    errdefer allocator.free(current_root);

    if (resolveRepoRoot(allocator, io, current_root)) |repo_root| {
        const entry = try repoEntryFromRoot(allocator, ".", repo_root);
        allocator.free(current_root);
        return .{ .single_repo = entry };
    } else |err| switch (err) {
        error.NotARepository => {},
        else => return err,
    }

    const repos = try discoverChildRepos(allocator, io, current_root);
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

fn discoverChildRepos(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8) ![]RepoEntry {
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

        const repo_root = resolveRepoRoot(allocator, io, child_path) catch |err| switch (err) {
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

fn resolveRepoRoot(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ResolveRepoRootError![]u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "rev-parse", "--show-toplevel" },
        .cwd = .{ .path = path },
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.StreamTooLong,
        else => error.SpawnFailed,
    };
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code == 0 and result.stdout.len > 0) {
            return trimAndDupe(allocator, result.stdout);
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

fn trimAndDupe(allocator: std.mem.Allocator, bytes: []u8) ![]u8 {
    defer allocator.free(bytes);
    return allocator.dupe(u8, std.mem.trim(u8, bytes, " \t\r\n"));
}

fn isDotEntry(name: []const u8) bool {
    return std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..");
}

test "repoLabel uses final path component" {
    const label = try repoLabel(std.testing.allocator, "/tmp/work/gitframe");
    defer std.testing.allocator.free(label);
    try std.testing.expectEqualStrings("gitframe", label);
}

test "trimAndDupe trims git output and owns result" {
    const raw = try std.testing.allocator.dupe(u8, "/tmp/repo\n");
    const trimmed = try trimAndDupe(std.testing.allocator, raw);
    defer std.testing.allocator.free(trimmed);
    try std.testing.expectEqualStrings("/tmp/repo", trimmed);
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
    var result = discover(std.testing.allocator, std.testing.io) catch |err| switch (err) {
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
    var root = try TestRoot.create(std.testing.allocator);
    defer root.cleanup(std.testing.allocator);
    try gitInitOrSkip(root.path);

    var result = try discoverRootOrSkip(root.path);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result == .single_repo);
    try std.testing.expectEqualStrings(".", result.single_repo.display_path);
    try std.testing.expect(result.single_repo.label.len > 0);
    try std.testing.expect(result.single_repo.canonical_root.len > 0);
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
        const path = try std.fs.path.join(allocator, &.{ "/tmp", sub_path });
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
    return discoverRoot(std.testing.allocator, std.testing.io, root_path) catch |err| switch (err) {
        error.SpawnFailed => error.SkipZigTest,
        else => err,
    };
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
