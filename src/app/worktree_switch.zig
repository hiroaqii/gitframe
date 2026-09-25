//! Read-only preparation for branch-picker navigation. Repository replacement
//! remains owned by repo_session; these paths are metadata, not authority.
const std = @import("std");
const chasen = @import("chasen");
const actions = @import("actions.zig");
const app_state = @import("state.zig");
const git_command = @import("../git/command.zig");
const refs = @import("../git/refs.zig");
const discovery = @import("../repo/discovery.zig");
const root_capability = @import("../repo/root_capability.zig");

pub const Validated = struct {
    discovery: discovery.DiscoveryResult,
    root_identity: root_capability.Identity,

    pub fn deinit(self: *Validated, allocator: std.mem.Allocator) void {
        self.discovery.deinit(allocator);
        self.* = undefined;
    }
};

pub const Finished = struct {
    owner: app_state.BranchSwitchOwner,
    generation: u64,
    result: union(enum) {
        ready: Validated,
        failed: []const u8,
    },

    pub fn deinit(self: *Finished, allocator: std.mem.Allocator) void {
        if (self.result == .ready) self.result.ready.deinit(allocator);
        self.* = undefined;
    }
};

pub fn Task(comptime Msg: type) type {
    return struct {
        owner: app_state.BranchSwitchOwner,
        generation: u64,
        source_root: root_capability.RootCapability,
        environment: git_command.LocalGitEnvironment,
        branch: []u8,
        path: []u8,

        pub fn create(
            allocator: std.mem.Allocator,
            owner: app_state.BranchSwitchOwner,
            generation: u64,
            source_root: root_capability.RootCapability,
            parent: ?*const std.process.Environ.Map,
            branch: []const u8,
            path: []const u8,
        ) !*@This() {
            var root = try source_root.duplicate();
            errdefer root.deinit();
            var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, parent);
            errdefer environment.deinit();
            const owned_branch = try allocator.dupe(u8, branch);
            errdefer allocator.free(owned_branch);
            const owned_path = try allocator.dupe(u8, path);
            errdefer allocator.free(owned_path);
            const task = try allocator.create(@This());
            task.* = .{
                .owner = owner,
                .generation = generation,
                .source_root = root,
                .environment = environment,
                .branch = owned_branch,
                .path = owned_path,
            };
            return task;
        }

        pub fn destroy(self: *@This(), allocator: std.mem.Allocator) void {
            self.source_root.deinit();
            self.environment.deinit();
            allocator.free(self.branch);
            allocator.free(self.path);
            allocator.destroy(self);
        }

        pub fn run(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const ready = prepare(allocator, io, .{
                .cwd = self.source_root.dir(),
                .environment = &self.environment,
            }, self.branch, self.path) catch |err| return self.finish(allocator, .{ .failed = failureMessage(err) });
            return self.finish(allocator, .{ .ready = ready });
        }

        pub fn failed(ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.finish(allocator, .{ .failed = actions.taskFailureMessage(failure) });
        }

        fn finish(self: *@This(), allocator: std.mem.Allocator, result: @FieldType(Finished, "result")) Msg {
            defer self.destroy(allocator);
            return Msg.loadFinished(.{ .shell = .{ .worktree_switch = .{
                .owner = self.owner,
                .generation = self.generation,
                .result = result,
            } } });
        }
    };
}

pub fn prepare(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: git_command.DirectoryContext,
    branch: []const u8,
    path: []const u8,
) !Validated {
    const loaded = try refs.loadBranchList(allocator, io, .{
        .context = source,
        .scope = .local,
        .include_worktree_path = true,
    });
    defer loaded.deinit(allocator);
    const list = switch (loaded) {
        .ok => |list| list,
        else => return error.WorktreeLookupFailed,
    };
    var matches = false;
    for (list.branches) |item| {
        if (std.mem.eql(u8, item.name, branch)) {
            matches = if (item.worktree_path) |current_path| std.mem.eql(u8, current_path, path) else false;
            break;
        }
    }
    if (!matches) return error.WorktreeMappingChanged;

    var root = root_capability.RootCapability.openCanonical(path) catch return error.WorktreeUnavailable;
    defer root.deinit();
    var found = try discovery.discoverInputPath(allocator, io, path, source.environment);
    errdefer found.deinit(allocator);
    if (found != .single_repo or !std.mem.eql(u8, found.single_repo.canonical_root, path)) return error.WorktreeMappingChanged;

    const target: git_command.DirectoryContext = .{ .cwd = root.dir(), .environment = source.environment };
    const current_branch = try readValue(allocator, io, target, &.{ "git", "symbolic-ref", "--quiet", "--short", "HEAD" });
    defer allocator.free(current_branch);
    if (!std.mem.eql(u8, current_branch, branch)) return error.WorktreeMappingChanged;
    const source_common = try commonIdentity(allocator, io, source);
    const target_common = try commonIdentity(allocator, io, target);
    if (!source_common.eql(target_common)) return error.WorktreeRepositoryChanged;
    if (!root_capability.pathMatches(path, root.identity)) return error.WorktreeUnavailable;
    return .{ .discovery = found, .root_identity = root.identity };
}

fn commonIdentity(allocator: std.mem.Allocator, io: std.Io, context: git_command.DirectoryContext) !root_capability.Identity {
    const path = try readValue(allocator, io, context, &.{ "git", "rev-parse", "--path-format=absolute", "--git-common-dir" });
    defer allocator.free(path);
    var root = root_capability.RootCapability.openCanonical(path) catch return error.WorktreeUnavailable;
    defer root.deinit();
    return root.identity;
}

fn readValue(allocator: std.mem.Allocator, io: std.Io, context: git_command.DirectoryContext, argv: []const []const u8) ![]u8 {
    const result = try git_command.runCaptured(allocator, io, context, .{
        .argv = argv,
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    });
    defer result.deinit(allocator);
    switch (result.term) {
        .exited => |code| if (code == 0) return allocator.dupe(u8, std.mem.trimEnd(u8, result.stdout, "\r\n")),
        else => {},
    }
    return error.WorktreeUnavailable;
}

fn failureMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.WorktreeMappingChanged => "branch no longer belongs to that worktree; reopen the branch list",
        error.WorktreeRepositoryChanged => "target is no longer a worktree of this repository",
        error.WorktreeUnavailable, error.PathDoesNotExist, error.PathIsNotDirectory, error.CannotAccessPath, error.NoGitRepositoriesFound => "target worktree is no longer available",
        error.WorktreeLookupFailed => "could not reload branch/worktree mapping",
        error.OutOfMemory => "out of memory while checking target worktree",
        else => "could not verify target worktree",
    };
}

fn testGit(context: git_command.DirectoryContext, argv: []const []const u8) !void {
    const output = try readValue(std.testing.allocator, std.testing.io, context, argv);
    std.testing.allocator.free(output);
}

test "worktree preparation verifies live mapping in both directions without carrying dirty state" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "main", .default_dir);
    var main_dir = try tmp.dir.openDir(io, "main", .{});
    defer main_dir.close(io);
    const main_path = try tmp.dir.realPathFileAlloc(io, "main", allocator);
    defer allocator.free(main_path);
    const linked_path = try std.fs.path.join(allocator, &.{ main_path, "..", "linked tree" });
    defer allocator.free(linked_path);
    var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, null);
    defer environment.deinit();
    const main: git_command.DirectoryContext = .{ .cwd = main_dir, .environment = &environment };
    try testGit(main, &.{ "git", "init", "--initial-branch=main" });
    try main_dir.writeFile(io, .{ .sub_path = "file", .data = "base\n" });
    try testGit(main, &.{ "git", "add", "file" });
    try testGit(main, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
    try testGit(main, &.{ "git", "branch", "free" });
    try testGit(main, &.{ "git", "worktree", "add", "-b", "linked", linked_path });
    const canonical = try tmp.dir.realPathFileAlloc(io, "linked tree", allocator);
    defer allocator.free(canonical);
    var linked_dir = try tmp.dir.openDir(io, "linked tree", .{});
    defer linked_dir.close(io);
    const linked: git_command.DirectoryContext = .{ .cwd = linked_dir, .environment = &environment };
    // The worktree branch may advance after the picker snapshot. Only its
    // branch/worktree relationship matters; this is not a checkout request.
    try testGit(linked, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "advanced" });
    try main_dir.writeFile(io, .{ .sub_path = "file", .data = "staged\n" });
    try testGit(main, &.{ "git", "add", "file" });
    try main_dir.writeFile(io, .{ .sub_path = "file", .data = "staged and unstaged\n" });
    try linked_dir.writeFile(io, .{ .sub_path = "untracked", .data = "stays linked\n" });

    const before = try readValue(allocator, io, main, &.{ "git", "diff", "--binary", "HEAD" });
    defer allocator.free(before);
    const index = try readValue(allocator, io, main, &.{ "git", "ls-files", "--stage" });
    defer allocator.free(index);
    const head = try readValue(allocator, io, main, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(head);
    const target_status = try readValue(allocator, io, linked, &.{ "git", "status", "--porcelain" });
    defer allocator.free(target_status);
    const mappings = try refs.loadBranchList(allocator, io, .{ .context = main, .scope = .local, .include_worktree_path = true });
    defer mappings.deinit(allocator);
    for (mappings.ok.branches) |item| {
        if (std.mem.eql(u8, item.name, "free")) try std.testing.expect(item.worktree_path == null);
        if (std.mem.eql(u8, item.name, "linked")) try std.testing.expectEqualStrings(canonical, item.worktree_path.?);
    }
    var there = try prepare(allocator, io, main, "linked", canonical);
    defer there.deinit(allocator);
    var back = try prepare(allocator, io, linked, "main", main_path);
    defer back.deinit(allocator);
    try std.testing.expectEqualStrings(canonical, there.discovery.single_repo.canonical_root);
    try std.testing.expectEqualStrings(main_path, back.discovery.single_repo.canonical_root);
    const after = try readValue(allocator, io, main, &.{ "git", "diff", "--binary", "HEAD" });
    defer allocator.free(after);
    const after_index = try readValue(allocator, io, main, &.{ "git", "ls-files", "--stage" });
    defer allocator.free(after_index);
    const after_head = try readValue(allocator, io, main, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(after_head);
    const after_target = try readValue(allocator, io, linked, &.{ "git", "status", "--porcelain" });
    defer allocator.free(after_target);
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expectEqualStrings(index, after_index);
    try std.testing.expectEqualStrings(head, after_head);
    try std.testing.expectEqualStrings(target_status, after_target);

    try testGit(linked, &.{ "git", "switch", "-c", "changed" });
    try std.testing.expectError(error.WorktreeMappingChanged, prepare(allocator, io, main, "linked", canonical));
    try tmp.dir.rename("linked tree", tmp.dir, "missing", io);
    try std.testing.expectError(error.WorktreeUnavailable, prepare(allocator, io, main, "changed", canonical));
    try tmp.dir.createDir(io, "linked tree", .default_dir);
    var replaced_dir = try tmp.dir.openDir(io, "linked tree", .{});
    defer replaced_dir.close(io);
    const replaced: git_command.DirectoryContext = .{ .cwd = replaced_dir, .environment = &environment };
    try testGit(replaced, &.{ "git", "init", "--initial-branch=changed" });
    try std.testing.expectError(error.WorktreeRepositoryChanged, prepare(allocator, io, main, "changed", canonical));
}
