const std = @import("std");

pub const RepoEntry = struct {
    /// Short label used in the picker. Usually the repository directory name.
    label: []const u8,
    /// Path shown to the user. Initial discovery uses a path relative to the
    /// scanned root for child repos and "." for the current repo.
    display_path: []const u8,
    /// Canonical repository root returned by Git.
    canonical_root: []const u8,
};

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

pub fn discover(allocator: std.mem.Allocator, io: std.Io) !DiscoveryResult {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    errdefer allocator.free(cwd);
    return discoverRoot(allocator, io, cwd);
}

pub fn discoverRoot(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8) !DiscoveryResult {
    const current_root = try std.Io.Dir.realPathFileAbsoluteAlloc(io, root_path, allocator);
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
