const std = @import("std");
const chasen = @import("chasen");
const diff_parser = @import("../diff/parser.zig");
const diff_hunk_projection = @import("../diff/hunk_projection.zig");
const diff_source = @import("../diff/source.zig");
const diff_view_model = @import("../diff/view_model.zig");
const file_tree = @import("../file_tree.zig");
const git_backend = @import("../git/backend.zig");
const git_branch_status = @import("../git/branch_status.zig");
const git_status = @import("../git/status.zig");
const loaded_diff = @import("../loaded_diff.zig");
const path_key_mod = @import("../path_key.zig");
const process_runner = @import("../process/runner.zig");
const review_projection = @import("review_projection.zig");
const repo_discovery = @import("../repo/discovery.zig");
const syntax_provider = @import("../syntax/provider_runtime.zig");

const LoadRequest = diff_source.LoadRequest;
const LoadedDiff = loaded_diff.LoadedDiff;

const status_line_stats_stdout_limit = 2 * 1024 * 1024;
const status_line_stats_stderr_limit = 256 * 1024;
const untracked_stats_per_file_bytes = review_projection.max_generated_file_bytes;
const untracked_stats_max_files = 256;
const untracked_stats_total_bytes = 4 * 1024 * 1024;

/// Result payload sent from the asynchronous diff load task back to App.
pub const DiffLoadFinished = struct {
    generation: u64,
    result: DiffLoadTaskResult,
};

/// Result payload sent from the asynchronous repository discovery task.
pub const RepoDiscoveryFinished = struct {
    generation: u64,
    result: RepoDiscoveryTaskResult,
};

/// Result payload sent from repository picker path discovery.
pub const RepoPathDiscoveryFinished = struct {
    generation: u64,
    submitted_path: []u8,
    result: RepoPathDiscoveryTaskResult,

    pub fn deinit(self: *RepoPathDiscoveryFinished, allocator: std.mem.Allocator) void {
        allocator.free(self.submitted_path);
        self.result.deinit(allocator);
        self.* = undefined;
    }
};

/// Result payload sent from the asynchronous status load task.
pub const StatusLoadFinished = struct {
    generation: u64,
    repo_root: []u8,
    result: StatusLoadTaskResult,

    pub fn deinit(self: *StatusLoadFinished, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        self.result.deinit(allocator);
    }
};

/// Result payload sent from the asynchronous branch status load task.
pub const BranchStatusLoadFinished = struct {
    generation: u64,
    repo_root: []u8,
    result: BranchStatusLoadTaskResult,

    pub fn deinit(self: *BranchStatusLoadFinished, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        self.result.deinit(allocator);
    }
};

pub const BranchListLoadFinished = struct {
    generation: u64,
    repo_root: []u8,
    result: BranchListLoadTaskResult,

    pub fn deinit(self: *BranchListLoadFinished, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        self.result.deinit(allocator);
    }
};

pub const ReviewProjectionFinished = review_projection.Finished;

pub const RepoDiscoveryTaskResult = union(enum) {
    empty,
    discovered: repo_discovery.DiscoveryResult,
    failed: []u8,
    failed_static: []const u8,

    pub fn deinit(self: *RepoDiscoveryTaskResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .empty, .failed_static => {},
            .discovered => |*discovery| discovery.deinit(allocator),
            .failed => |message| allocator.free(message),
        }
        self.* = .empty;
    }
};

pub const RepoPathDiscoveryTaskResult = union(enum) {
    empty,
    discovered: repo_discovery.DiscoveryResult,
    input_error: repo_discovery.PathDiscoveryError,
    failed: []u8,
    failed_static: []const u8,

    pub fn deinit(self: *RepoPathDiscoveryTaskResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .empty, .input_error, .failed_static => {},
            .discovered => |*discovery| discovery.deinit(allocator),
            .failed => |message| allocator.free(message),
        }
        self.* = .empty;
    }
};

pub const DiffLoadTaskResult = union(enum) {
    empty,
    loaded: LoadedDiffBundle,
    failed: []u8,
    failed_static: []const u8,

    pub fn deinit(self: *DiffLoadTaskResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .empty, .failed_static => {},
            .loaded => |*bundle| bundle.deinit(),
            .failed => |message| allocator.free(message),
        }
        self.* = .empty;
    }
};

pub const StatusLoadTaskResult = union(enum) {
    empty,
    loaded: git_status.StatusBundle,
    failed: []u8,
    failed_static: []const u8,

    pub fn deinit(self: *StatusLoadTaskResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .empty, .failed_static => {},
            .loaded => |*bundle| bundle.deinit(),
            .failed => |message| allocator.free(message),
        }
        self.* = .empty;
    }
};

pub const BranchStatusLoadTaskResult = union(enum) {
    empty,
    loaded: git_branch_status.BranchStatusBundle,
    failed: []u8,
    failed_static: []const u8,

    pub fn deinit(self: *BranchStatusLoadTaskResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .empty, .failed_static => {},
            .loaded => |*bundle| bundle.deinit(),
            .failed => |message| allocator.free(message),
        }
        self.* = .empty;
    }
};

pub const BranchListLoadTaskResult = union(enum) {
    empty,
    loaded: git_backend.BranchList,
    failed: []u8,
    failed_static: []const u8,

    pub fn deinit(self: *BranchListLoadTaskResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .empty, .failed_static => {},
            .loaded => |*list| list.deinit(allocator),
            .failed => |message| allocator.free(message),
        }
        self.* = .empty;
    }
};

/// Owns a parsed diff and the arena backing all borrowed slices in it.
///
/// App takes the arena when accepting a fresh result; stale/error paths call
/// deinit through DiffLoadTaskResult.
pub const LoadedDiffBundle = struct {
    arena: ?std.heap.ArenaAllocator,
    loaded: LoadedDiff,

    pub fn deinit(self: *LoadedDiffBundle) void {
        if (self.arena) |*arena| arena.deinit();
        self.arena = null;
    }

    pub fn takeArena(self: *LoadedDiffBundle) std.heap.ArenaAllocator {
        const arena = self.arena.?;
        self.arena = null;
        return arena;
    }
};

/// Async task type factory.
///
/// The task returns App's concrete Msg union, but this module must not import
/// App. Passing Msg at comptime keeps ownership logic here without creating an
/// app/app_load import cycle. Msg supplies loadFinished() so nested message
/// construction stays centralized in App's Msg definition.
pub fn RepoDiscoveryTask(comptime Msg: type) type {
    return struct {
        generation: u64,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer allocator.destroy(task);

            return Msg.loadFinished(.{ .repos_discovered = RepoDiscoveryFinished{
                .generation = task.generation,
                .result = runDiscovery(allocator, io),
            } });
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer allocator.destroy(task);

            return Msg.loadFinished(.{ .repos_discovered = RepoDiscoveryFinished{
                .generation = task.generation,
                .result = .{ .failed_static = taskFailureMessage(failure) },
            } });
        }
    };
}

pub fn runDiscovery(allocator: std.mem.Allocator, io: std.Io) RepoDiscoveryTaskResult {
    const result = repo_discovery.discover(allocator, io) catch |err| {
        return .{
            .failed = std.fmt.allocPrint(allocator, "Repo discovery failed: {s}", .{@errorName(err)}) catch
                return .{ .failed_static = "Repo discovery failed: OutOfMemory" },
        };
    };
    return .{ .discovered = result };
}

pub fn RepoPathDiscoveryTask(comptime Msg: type) type {
    return struct {
        path: []u8,
        generation: u64,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer allocator.destroy(task);

            const submitted_path = task.path;
            task.path = &.{};

            return Msg.loadFinished(.{ .repo_path_discovered = RepoPathDiscoveryFinished{
                .generation = task.generation,
                .submitted_path = submitted_path,
                .result = runPathDiscovery(submitted_path, allocator, io),
            } });
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer allocator.destroy(task);

            const submitted_path = task.path;
            task.path = &.{};

            return Msg.loadFinished(.{ .repo_path_discovered = RepoPathDiscoveryFinished{
                .generation = task.generation,
                .submitted_path = submitted_path,
                .result = .{ .failed_static = taskFailureMessage(failure) },
            } });
        }
    };
}

pub fn runPathDiscovery(path: []const u8, allocator: std.mem.Allocator, io: std.Io) RepoPathDiscoveryTaskResult {
    const result = repo_discovery.discoverInputPath(allocator, io, path) catch |err| {
        return switch (err) {
            error.PathDoesNotExist,
            error.PathIsNotDirectory,
            error.CannotAccessPath,
            error.NoGitRepositoriesFound,
            => .{ .input_error = err },
            else => .{
                .failed = std.fmt.allocPrint(allocator, "Repo path discovery failed: {s}", .{@errorName(err)}) catch
                    return .{ .failed_static = "Repo path discovery failed: OutOfMemory" },
            },
        };
    };
    return .{ .discovered = result };
}

pub fn DiffLoadTask(comptime Msg: type) type {
    return struct {
        request: LoadRequest,
        generation: u64,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer {
                diff_source.freeLoadRequest(allocator, task.request);
                allocator.destroy(task);
            }

            return Msg.loadFinished(.{ .diff_loaded = DiffLoadFinished{
                .generation = task.generation,
                .result = runLoad(task.request, allocator, io),
            } });
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer {
                diff_source.freeLoadRequest(allocator, task.request);
                allocator.destroy(task);
            }

            return Msg.loadFinished(.{ .diff_loaded = DiffLoadFinished{
                .generation = task.generation,
                .result = .{ .failed_static = taskFailureMessage(failure) },
            } });
        }
    };
}

pub fn StatusLoadTask(comptime Msg: type) type {
    return struct {
        repo_root: []u8,
        generation: u64,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer allocator.destroy(task);

            const result = StatusLoadFinished{
                .generation = task.generation,
                .repo_root = task.repo_root,
                .result = runStatusLoad(task.repo_root, allocator, io),
            };
            task.repo_root = &.{};

            return Msg.loadFinished(.{ .status_loaded = result });
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer allocator.destroy(task);

            const result = StatusLoadFinished{
                .generation = task.generation,
                .repo_root = task.repo_root,
                .result = .{ .failed_static = taskFailureMessage(failure) },
            };
            task.repo_root = &.{};

            return Msg.loadFinished(.{ .status_loaded = result });
        }
    };
}

pub fn BranchStatusLoadTask(comptime Msg: type) type {
    return struct {
        repo_root: []u8,
        generation: u64,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer allocator.destroy(task);

            const result = BranchStatusLoadFinished{
                .generation = task.generation,
                .repo_root = task.repo_root,
                .result = runBranchStatusLoad(task.repo_root, allocator, io),
            };
            task.repo_root = &.{};

            return Msg.loadFinished(.{ .branch_status_loaded = result });
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer allocator.destroy(task);

            const result = BranchStatusLoadFinished{
                .generation = task.generation,
                .repo_root = task.repo_root,
                .result = .{ .failed_static = taskFailureMessage(failure) },
            };
            task.repo_root = &.{};

            return Msg.loadFinished(.{ .branch_status_loaded = result });
        }
    };
}

pub fn BranchListLoadTask(comptime Msg: type) type {
    return struct {
        repo_root: []u8,
        generation: u64,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer allocator.destroy(task);

            const result = BranchListLoadFinished{
                .generation = task.generation,
                .repo_root = task.repo_root,
                .result = runBranchListLoad(task.repo_root, allocator, io),
            };
            task.repo_root = &.{};

            return Msg.loadFinished(.{ .branch_list_loaded = result });
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer allocator.destroy(task);

            const result = BranchListLoadFinished{
                .generation = task.generation,
                .repo_root = task.repo_root,
                .result = .{ .failed_static = taskFailureMessage(failure) },
            };
            task.repo_root = &.{};

            return Msg.loadFinished(.{ .branch_list_loaded = result });
        }
    };
}

pub fn ReviewProjectionTask(comptime Msg: type) type {
    return struct {
        request: review_projection.Request,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer allocator.destroy(task);

            const request = task.request;
            task.request = undefined;

            return Msg.loadFinished(.{ .review_projection_loaded = ReviewProjectionFinished{
                .request = request,
                .result = runReviewProjectionLoad(request, allocator, io),
            } });
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer allocator.destroy(task);

            const request = task.request;
            task.request = undefined;

            return Msg.loadFinished(.{ .review_projection_loaded = ReviewProjectionFinished{
                .request = request,
                .result = .{ .failed_static = taskFailureMessage(failure) },
            } });
        }
    };
}

fn taskFailureMessage(failure: chasen.TaskFailure) []const u8 {
    return switch (failure) {
        .start_failed => |message| message,
    };
}

pub fn runStatusLoad(repo_root: []const u8, allocator: std.mem.Allocator, io: std.Io) StatusLoadTaskResult {
    var local_backend: git_backend.LocalCommandBackend = .{};
    const raw_result = local_backend.backend().loadStatus(allocator, io, .{ .repo_root = repo_root }) catch |err| {
        return .{
            .failed = std.fmt.allocPrint(allocator, "Status load failed: {s}", .{@errorName(err)}) catch
                return .{ .failed_static = "Status load failed: OutOfMemory" },
        };
    };

    switch (raw_result) {
        .ok => |bytes| {
            defer allocator.free(bytes);
            // Empty porcelain output is a valid clean-worktree snapshot. Keep it
            // as a loaded document so App can remember which repo was proven
            // clean; otherwise pull's clean-worktree gate sees the status as
            // stale forever on clean repositories.
            var bundle = git_status.StatusBundle.parseOwned(allocator, bytes) catch |err| {
                return .{ .failed = std.fmt.allocPrint(allocator, "Status parse failed: {s}", .{@errorName(err)}) catch
                    return .{ .failed_static = "Status parse failed: OutOfMemory" } };
            };
            populateStatusLineStats(allocator, io, repo_root, &bundle) catch {};
            return .{ .loaded = bundle };
        },
        .failed => |message| return .{ .failed = message },
        .failed_static => |message| return .{ .failed_static = message },
    }
}

pub fn runBranchStatusLoad(repo_root: []const u8, allocator: std.mem.Allocator, io: std.Io) BranchStatusLoadTaskResult {
    var local_backend: git_backend.LocalCommandBackend = .{};
    const raw_result = local_backend.backend().loadBranchStatus(allocator, io, .{ .repo_root = repo_root }) catch |err| {
        return .{
            .failed = std.fmt.allocPrint(allocator, "Branch status load failed: {s}", .{@errorName(err)}) catch
                return .{ .failed_static = "Branch status load failed: OutOfMemory" },
        };
    };

    switch (raw_result) {
        .ok => |bundle| return .{ .loaded = bundle },
        .failed => |message| return .{ .failed = message },
        .failed_static => |message| return .{ .failed_static = message },
    }
}

const StatusStatsMap = std.StringHashMapUnmanaged(file_tree.Stats);

fn populateStatusLineStats(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, bundle: *git_status.StatusBundle) !void {
    var stats_map: StatusStatsMap = .empty;
    defer deinitStatusStatsMap(allocator, &stats_map);

    try collectTrackedStatusLineStats(allocator, io, repo_root, bundle.document, &stats_map, .staged);
    try collectTrackedStatusLineStats(allocator, io, repo_root, bundle.document, &stats_map, .unstaged);
    try collectUntrackedStatusLineStats(allocator, io, repo_root, bundle.document, &stats_map);

    const line_stats = try statusStatsMapToList(allocator, stats_map);
    defer {
        for (line_stats) |entry| allocator.free(entry.path_key);
        allocator.free(line_stats);
    }

    try bundle.attachLineStats(line_stats);
}

fn deinitStatusStatsMap(allocator: std.mem.Allocator, stats_map: *StatusStatsMap) void {
    var iterator = stats_map.keyIterator();
    while (iterator.next()) |key| allocator.free(key.*);
    stats_map.deinit(allocator);
}

const TrackedStatsSide = enum {
    staged,
    unstaged,
};

fn collectTrackedStatusLineStats(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    document: git_status.StatusDocument,
    stats_map: *StatusStatsMap,
    side: TrackedStatsSide,
) !void {
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);

    for (document.entries) |entry| {
        if (entry.isIgnored() or entry.isUntracked()) continue;
        const include = switch (side) {
            .staged => entry.isStaged(),
            .unstaged => entry.isUnstaged(),
        };
        if (!include) continue;
        const key = entry.canonicalPathKey() orelse continue;
        try paths.append(allocator, key);
    }
    if (paths.items.len == 0) return;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.append(allocator, "diff");
    if (side == .staged) try argv.append(allocator, "--cached");
    try argv.append(allocator, "--no-renames");
    try argv.append(allocator, "--numstat");
    try argv.append(allocator, "-z");
    try argv.append(allocator, "--");
    for (paths.items) |path| try argv.append(allocator, path);

    const result = process_runner.runCaptured(allocator, io, .{
        .argv = argv.items,
        .cwd = .{ .path = repo_root },
        .stdout_limit = .limited(status_line_stats_stdout_limit),
        .stderr_limit = .limited(status_line_stats_stderr_limit),
    }) catch return;
    defer result.deinit(allocator);

    switch (result.term) {
        .exited => |code| if (code == 0) try parseNumstatZIntoMap(allocator, result.stdout, stats_map),
        else => {},
    }
}

fn parseNumstatZIntoMap(allocator: std.mem.Allocator, bytes: []const u8, stats_map: *StatusStatsMap) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const field = nextZField(bytes, &offset) orelse break;
        if (field.len == 0) continue;
        const parsed = parseNumstatField(field) orelse continue;
        const key = path_key_mod.canonicalRepoPath(parsed.path) orelse continue;
        try addStatusStats(allocator, stats_map, key, parsed.stats);
    }
}

const NumstatField = struct {
    path: []const u8,
    stats: file_tree.Stats,
};

fn parseNumstatField(field: []const u8) ?NumstatField {
    const first_tab = std.mem.indexOfScalar(u8, field, '\t') orelse return null;
    const second_tab = std.mem.indexOfScalarPos(u8, field, first_tab + 1, '\t') orelse return null;
    const added_text = field[0..first_tab];
    const removed_text = field[first_tab + 1 .. second_tab];
    if (std.mem.eql(u8, added_text, "-") or std.mem.eql(u8, removed_text, "-")) return null;
    const added = std.fmt.parseInt(usize, added_text, 10) catch return null;
    const removed = std.fmt.parseInt(usize, removed_text, 10) catch return null;
    const path = field[second_tab + 1 ..];
    if (path.len == 0) return null;
    return .{ .path = path, .stats = .{ .added = added, .removed = removed } };
}

fn collectUntrackedStatusLineStats(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    document: git_status.StatusDocument,
    stats_map: *StatusStatsMap,
) !void {
    return collectUntrackedStatusLineStatsWithBudget(allocator, io, repo_root, document, stats_map, .{
        .per_file_bytes = untracked_stats_per_file_bytes,
        .max_files = untracked_stats_max_files,
        .total_bytes = untracked_stats_total_bytes,
    });
}

const UntrackedStatsBudget = struct {
    per_file_bytes: usize,
    max_files: usize,
    total_bytes: usize,
};

fn collectUntrackedStatusLineStatsWithBudget(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    document: git_status.StatusDocument,
    stats_map: *StatusStatsMap,
    budget: UntrackedStatsBudget,
) !void {
    var inspected_files: usize = 0;
    var inspected_bytes: usize = 0;

    for (document.entries) |entry| {
        if (!entry.isUntracked()) continue;
        if (inspected_files >= budget.max_files) return;
        const key = entry.canonicalPathKey() orelse continue;
        inspected_files += 1;

        const content = readRepoFileLimited(allocator, io, repo_root, key, budget.per_file_bytes) catch continue;
        defer allocator.free(content);

        if (inspected_bytes + content.len > budget.total_bytes) return;
        inspected_bytes += content.len;

        if (std.mem.indexOfScalar(u8, content, 0) != null) continue;
        try addStatusStats(allocator, stats_map, key, .{ .added = addedFileLineCount(content) });
    }
}

fn addStatusStats(allocator: std.mem.Allocator, stats_map: *StatusStatsMap, key: []const u8, stats: file_tree.Stats) !void {
    const result = try stats_map.getOrPut(allocator, key);
    if (result.found_existing) {
        result.value_ptr.add(stats);
        return;
    }
    errdefer _ = stats_map.remove(key);
    result.key_ptr.* = try allocator.dupe(u8, key);
    result.value_ptr.* = stats;
}

fn statusStatsMapToList(allocator: std.mem.Allocator, stats_map: StatusStatsMap) ![]git_status.StatusLineStats {
    var line_stats = try allocator.alloc(git_status.StatusLineStats, stats_map.count());
    errdefer {
        for (line_stats) |entry| allocator.free(entry.path_key);
        allocator.free(line_stats);
    }

    var iterator = stats_map.iterator();
    var index: usize = 0;
    while (iterator.next()) |entry| : (index += 1) {
        line_stats[index] = .{
            .path_key = try allocator.dupe(u8, entry.key_ptr.*),
            .stats = entry.value_ptr.*,
        };
    }
    std.mem.sort(git_status.StatusLineStats, line_stats, {}, statusLineStatsLessThan);
    return line_stats;
}

fn statusLineStatsLessThan(_: void, lhs: git_status.StatusLineStats, rhs: git_status.StatusLineStats) bool {
    return std.mem.lessThan(u8, lhs.path_key, rhs.path_key);
}

fn addedFileLineCount(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;

    var count: usize = 1;
    const end = if (bytes[bytes.len - 1] == '\n') bytes.len - 1 else bytes.len;
    for (bytes[0..end]) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
}

fn nextZField(text: []const u8, offset: *usize) ?[]const u8 {
    if (offset.* >= text.len) return null;
    const start = offset.*;
    const end = std.mem.indexOfScalarPos(u8, text, start, 0) orelse text.len;
    offset.* = if (end < text.len) end + 1 else text.len;
    return text[start..end];
}

pub fn runBranchListLoad(repo_root: []const u8, allocator: std.mem.Allocator, io: std.Io) BranchListLoadTaskResult {
    var local_backend: git_backend.LocalCommandBackend = .{};
    const raw_result = local_backend.backend().loadBranchList(allocator, io, .{ .repo_root = repo_root }) catch |err| {
        return .{
            .failed = std.fmt.allocPrint(allocator, "Branch list load failed: {s}", .{@errorName(err)}) catch
                return .{ .failed_static = "Branch list load failed: OutOfMemory" },
        };
    };

    switch (raw_result) {
        .ok => |list| return .{ .loaded = list },
        .failed => |message| return .{ .failed = message },
        .failed_static => |message| return .{ .failed_static = message },
    }
}

pub fn runLoad(request: LoadRequest, allocator: std.mem.Allocator, io: std.Io) DiffLoadTaskResult {
    const raw_result = diff_source.load(allocator, io, request) catch |err| {
        return .{
            .failed = std.fmt.allocPrint(allocator, "Diff load failed: {s}", .{@errorName(err)}) catch
                return .{ .failed_static = "Diff load failed: OutOfMemory" },
        };
    };

    switch (raw_result) {
        .ok => |bytes| {
            defer allocator.free(bytes);
            if (bytes.len == 0) return .empty;
            const bundle = buildLoadedBundleWithIo(allocator, io, bytes) catch |err| {
                return .{ .failed = std.fmt.allocPrint(allocator, "Diff parse failed: {s}", .{@errorName(err)}) catch
                    return .{ .failed_static = "Diff parse failed: OutOfMemory" } };
            };
            return .{ .loaded = bundle };
        },
        .failed => |message| return .{ .failed = message },
        .failed_static => |message| return .{ .failed_static = message },
    }
}

pub fn runReviewProjectionLoad(request: review_projection.Request, allocator: std.mem.Allocator, io: std.Io) review_projection.TaskResult {
    return switch (request.kind) {
        .cached_diff => loadCachedFileDiff(request, allocator, io),
        .generated_added_file => loadGeneratedAddedFile(request, allocator, io),
        .combined_hunks => loadCombinedHunks(request, allocator, io),
    };
}

fn loadCachedFileDiff(request: review_projection.Request, allocator: std.mem.Allocator, io: std.Io) review_projection.TaskResult {
    const bundle = loadFileDiffBundle(request, allocator, io, .cached) catch |err| {
        return .{ .failed = review_projection.statusBodyAlloc(allocator, request.path_key, "Cached diff load failed: {s}", .{@errorName(err)}) catch
            return .{ .failed_static = "Cached diff load failed: OutOfMemory" } };
    };
    if (bundle == null) {
        return .{ .ready = .{ .status_body = review_projection.statusBodyAlloc(allocator, request.path_key, "No staged diff for this file.", .{}) catch
            return .{ .failed_static = "Projection allocation failed" } } };
    }
    return .{ .ready = .{ .cached_diff = bundle.? } };
}

fn loadFileDiffBundle(
    request: review_projection.Request,
    allocator: std.mem.Allocator,
    io: std.Io,
    base: git_backend.FileDiffBase,
) !?LoadedDiffBundle {
    var local_backend: git_backend.LocalCommandBackend = .{};
    const raw_result = try local_backend.backend().loadDiff(allocator, io, .{
        .repo_root = request.repo_root,
        .kind = .{ .file = .{ .base = base, .path = request.path_key } },
    });

    switch (raw_result) {
        .ok => |bytes| {
            defer allocator.free(bytes);
            if (bytes.len == 0) return null;
            return try buildLoadedBundleWithIo(allocator, io, bytes);
        },
        .failed => |message| {
            defer allocator.free(message);
            return error.GitCommandFailed;
        },
        .failed_static => return error.GitCommandFailed,
    }
}

fn loadCombinedHunks(request: review_projection.Request, allocator: std.mem.Allocator, io: std.Io) review_projection.TaskResult {
    var cached_bundle = loadFileDiffBundle(request, allocator, io, .cached) catch |err| {
        return .{ .failed = review_projection.statusBodyAlloc(allocator, request.path_key, "Staged hunk projection load failed: {s}", .{@errorName(err)}) catch
            return .{ .failed_static = "Projection load failed: OutOfMemory" } };
    } orelse return .{ .ready = .{ .status_body = review_projection.statusBodyAlloc(allocator, request.path_key, "No staged hunks for this file.", .{}) catch
        return .{ .failed_static = "Projection allocation failed" } } };
    defer cached_bundle.deinit();

    var unstaged_bundle = loadFileDiffBundle(request, allocator, io, .unstaged) catch |err| {
        return .{ .failed = review_projection.statusBodyAlloc(allocator, request.path_key, "Unstaged hunk projection load failed: {s}", .{@errorName(err)}) catch
            return .{ .failed_static = "Projection load failed: OutOfMemory" } };
    } orelse return .{ .ready = .{ .status_body = review_projection.statusBodyAlloc(allocator, request.path_key, "No unstaged hunks for this file.", .{}) catch
        return .{ .failed_static = "Projection allocation failed" } } };
    defer unstaged_bundle.deinit();

    if (cached_bundle.loaded.document.files.len != 1 or unstaged_bundle.loaded.document.files.len != 1) {
        return .{ .ready = .{ .status_body = review_projection.statusBodyAlloc(allocator, request.path_key, "Cannot combine staged and unstaged hunks for this file.", .{}) catch
            return .{ .failed_static = "Projection allocation failed" } } };
    }

    // The local cached/unstaged bundles are cleaned up on every early return.
    // On success, CombinedHunkBundle takes their arenas and nulls the locals so
    // the defers below become no-ops instead of double-freeing moved ownership.
    var arena: std.heap.ArenaAllocator = .init(allocator);
    const projection = diff_hunk_projection.build(
        arena.allocator(),
        cached_bundle.loaded.document.files[0],
        unstaged_bundle.loaded.document.files[0],
    ) catch |err| {
        arena.deinit();
        return .{ .ready = .{ .status_body = review_projection.statusBodyAlloc(allocator, request.path_key, "Cannot combine staged and unstaged hunks: {s}", .{@errorName(err)}) catch
            return .{ .failed_static = "Projection allocation failed" } } };
    };

    const bundle = review_projection.CombinedHunkBundle{
        .arena = arena,
        .projection = projection,
        .cached_bundle = cached_bundle,
        .unstaged_bundle = unstaged_bundle,
    };
    cached_bundle.arena = null;
    unstaged_bundle.arena = null;
    return .{ .ready = .{ .combined_hunks = bundle } };
}

fn loadGeneratedAddedFile(request: review_projection.Request, allocator: std.mem.Allocator, io: std.Io) review_projection.TaskResult {
    const content = readRepoFile(allocator, io, request.repo_root, request.path_key) catch |err| {
        return .{ .failed = review_projection.statusBodyAlloc(allocator, request.path_key, "Cannot show file content: {s}", .{@errorName(err)}) catch
            return .{ .failed_static = "Projection allocation failed" } };
    };
    defer allocator.free(content);

    if (std.mem.indexOfScalar(u8, content, 0) != null) {
        return .{ .ready = .{ .status_body = review_projection.statusBodyAlloc(allocator, request.path_key, "Binary file content is not shown.", .{}) catch
            return .{ .failed_static = "Projection allocation failed" } } };
    }

    const bundle = review_projection.generatedFileFromContent(allocator, request.path_key, content, false) catch |err| {
        return .{ .failed = review_projection.statusBodyAlloc(allocator, request.path_key, "Generated diff failed: {s}", .{@errorName(err)}) catch
            return .{ .failed_static = "Generated diff failed: OutOfMemory" } };
    };
    return .{ .ready = .{ .generated_added_file = bundle } };
}

fn readRepoFile(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, path_key: []const u8) ![]u8 {
    return readRepoFileLimited(allocator, io, repo_root, path_key, review_projection.max_generated_file_bytes);
}

fn readRepoFileLimited(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, path_key: []const u8, limit: usize) ![]u8 {
    try validateRepoRelativePath(path_key);

    var current_dir = try std.Io.Dir.openDirAbsolute(io, repo_root, .{});
    defer current_dir.close(io);

    var components = std.mem.splitScalar(u8, path_key, '/');
    var component = components.next() orelse return error.InvalidPath;
    while (true) {
        const next = components.next();
        const stat = try current_dir.statFile(io, component, .{ .follow_symlinks = false });
        if (next == null) {
            if (stat.kind != .file) return error.InvalidPath;
            return try current_dir.readFileAlloc(io, component, allocator, .limited(limit));
        }

        if (stat.kind != .directory) return error.InvalidPath;
        const child_dir = try current_dir.openDir(io, component, .{});
        current_dir.close(io);
        current_dir = child_dir;
        component = next.?;
    }
}

fn validateRepoRelativePath(path: []const u8) !void {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return error.InvalidPath;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return error.InvalidPath;
    }
}

/// Test helper for callers that only have diff bytes. Production load paths
/// must call buildLoadedBundleWithIo so optional providers receive task I/O.
pub fn buildLoadedBundle(allocator: std.mem.Allocator, bytes: []const u8) !LoadedDiffBundle {
    return buildLoadedBundleWithIo(allocator, std.testing.io, bytes);
}

pub fn buildLoadedBundleWithIo(allocator: std.mem.Allocator, io: std.Io, bytes: []const u8) !LoadedDiffBundle {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    // DiffDocument string fields borrow from the input bytes, so keep the raw
    // diff text and parser-allocated arrays in the same arena.
    const copied = try arena_allocator.dupe(u8, bytes);
    const document = try diff_parser.parse(arena_allocator, copied);
    const syntax_spans = try syntax_provider.buildDocumentSpans(arena_allocator, io, document);
    const tree = try file_tree.build(arena_allocator, document);
    const rendered_line_cache = try diff_view_model.RenderedLineCache.build(arena_allocator, document);
    const collapsed_hunks = try arena_allocator.alloc(bool, document.totalHunks());
    @memset(collapsed_hunks, false);
    var loaded: LoadedDiff = .{
        .bytes = copied.len,
        .lines = countLines(copied),
        .text = copied,
        .document = document,
        .syntax_spans = syntax_spans,
        .tree = tree,
        .rendered_line_cache = rendered_line_cache,
        .collapsed_hunks = collapsed_hunks,
        .collapsed_dirs = .empty,
    };
    try loaded.rebuildVisibleNodes(arena_allocator, false, .all);

    // Do not store `arena_allocator` in the result: its interface points at
    // this local arena value, while the arena itself is moved by value across
    // the task-result boundary.
    return .{ .arena = arena, .loaded = loaded };
}

pub fn countLines(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;

    var count: usize = 1;
    for (bytes) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
}

test "readRepoFile rejects symlink components" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "inside.txt", .data = "inside" });
    try tmp.dir.symLink(io, "inside.txt", "linked.txt", .{});
    try tmp.dir.createDir(io, "dir", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "dir/inside.txt", .data = "nested" });
    try tmp.dir.symLink(io, "dir", "linked-dir", .{ .is_directory = true });

    const repo_root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(repo_root);

    const content = try readRepoFile(std.testing.allocator, io, repo_root, "inside.txt");
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("inside", content);

    try std.testing.expectError(error.InvalidPath, readRepoFile(std.testing.allocator, io, repo_root, "linked.txt"));
    try std.testing.expectError(error.InvalidPath, readRepoFile(std.testing.allocator, io, repo_root, "linked-dir/inside.txt"));
}

test "addedFileLineCount uses diff stats semantics" {
    try std.testing.expectEqual(@as(usize, 0), addedFileLineCount(""));
    try std.testing.expectEqual(@as(usize, 1), addedFileLineCount("one"));
    try std.testing.expectEqual(@as(usize, 1), addedFileLineCount("one\n"));
    try std.testing.expectEqual(@as(usize, 2), addedFileLineCount("one\ntwo"));
    try std.testing.expectEqual(@as(usize, 2), addedFileLineCount("one\ntwo\n"));
    try std.testing.expectEqual(@as(usize, 1), addedFileLineCount("\n"));
}

test "parseNumstatZIntoMap parses single-path records and ignores binary records" {
    var stats_map: StatusStatsMap = .empty;
    defer deinitStatusStatsMap(std.testing.allocator, &stats_map);

    try parseNumstatZIntoMap(std.testing.allocator, "3\t1\tsrc/a.zig\x00-\t-\tbin.dat\x00", &stats_map);

    try std.testing.expectEqual(@as(usize, 1), stats_map.count());
    const stats = stats_map.get("src/a.zig") orelse return error.ExpectedStats;
    try std.testing.expectEqual(@as(usize, 3), stats.added);
    try std.testing.expectEqual(@as(usize, 1), stats.removed);
}

test "parseNumstatZIntoMap accumulates duplicate paths" {
    var stats_map: StatusStatsMap = .empty;
    defer deinitStatusStatsMap(std.testing.allocator, &stats_map);

    try parseNumstatZIntoMap(std.testing.allocator, "3\t1\tsrc/a.zig\x002\t4\tsrc/a.zig\x00", &stats_map);

    const stats = stats_map.get("src/a.zig") orelse return error.ExpectedStats;
    try std.testing.expectEqual(@as(usize, 5), stats.added);
    try std.testing.expectEqual(@as(usize, 5), stats.removed);
}

test "collectUntrackedStatusLineStats skips binary and oversized files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "one.txt", .data = "one\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "two.txt", .data = "two\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "binary.dat", .data = "a\x00b" });
    const oversized = try std.testing.allocator.alloc(u8, untracked_stats_per_file_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    try tmp.dir.writeFile(io, .{ .sub_path = "oversized.txt", .data = oversized });
    const repo_root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(repo_root);

    const entries = [_]git_status.StatusEntry{
        .{ .path = "one.txt", .raw = .{ '?', '?' }, .index = .unmodified, .worktree = .untracked },
        .{ .path = "two.txt", .raw = .{ '?', '?' }, .index = .unmodified, .worktree = .untracked },
        .{ .path = "binary.dat", .raw = .{ '?', '?' }, .index = .unmodified, .worktree = .untracked },
        .{ .path = "oversized.txt", .raw = .{ '?', '?' }, .index = .unmodified, .worktree = .untracked },
    };
    const document: git_status.StatusDocument = .{ .entries = &entries };
    var stats_map: StatusStatsMap = .empty;
    defer deinitStatusStatsMap(std.testing.allocator, &stats_map);

    try collectUntrackedStatusLineStats(std.testing.allocator, io, repo_root, document, &stats_map);

    try std.testing.expectEqual(@as(usize, 2), stats_map.count());
    try std.testing.expectEqual(@as(usize, 1), stats_map.get("one.txt").?.added);
    try std.testing.expectEqual(@as(usize, 1), stats_map.get("two.txt").?.added);
    try std.testing.expect(stats_map.get("binary.dat") == null);
    try std.testing.expect(stats_map.get("oversized.txt") == null);
}

test "collectUntrackedStatusLineStats consumes max-files budget for failed reads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "valid.txt", .data = "valid\n" });
    const repo_root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(repo_root);

    const entries = [_]git_status.StatusEntry{
        .{ .path = "missing-1.txt", .raw = .{ '?', '?' }, .index = .unmodified, .worktree = .untracked },
        .{ .path = "missing-2.txt", .raw = .{ '?', '?' }, .index = .unmodified, .worktree = .untracked },
        .{ .path = "valid.txt", .raw = .{ '?', '?' }, .index = .unmodified, .worktree = .untracked },
    };
    const document: git_status.StatusDocument = .{ .entries = &entries };
    var stats_map: StatusStatsMap = .empty;
    defer deinitStatusStatsMap(std.testing.allocator, &stats_map);

    try collectUntrackedStatusLineStatsWithBudget(std.testing.allocator, io, repo_root, document, &stats_map, .{
        .per_file_bytes = untracked_stats_per_file_bytes,
        .max_files = 2,
        .total_bytes = untracked_stats_total_bytes,
    });

    try std.testing.expectEqual(@as(usize, 0), stats_map.count());
    try std.testing.expect(stats_map.get("valid.txt") == null);
}

test "runStatusLoad preserves clean repository snapshot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, tmp.dir);
    const repo_root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(repo_root);

    var result = runStatusLoad(repo_root, std.testing.allocator, io);
    defer result.deinit(std.testing.allocator);

    switch (result) {
        .loaded => |bundle| try std.testing.expectEqual(@as(usize, 0), bundle.document.entries.len),
        else => return error.ExpectedCleanStatusSnapshot,
    }
}

test "runStatusLoad attaches line stats for staged and untracked added files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, tmp.dir);
    try tmp.dir.createDir(io, "src", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/staged.zig", .data = "one\ntwo\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/untracked.zig", .data = "alpha\nbeta\n" });
    try runTestGit(io, &.{ "git", "add", "src/staged.zig" }, tmp.dir);

    const repo_root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(repo_root);

    var result = runStatusLoad(repo_root, std.testing.allocator, io);
    defer result.deinit(std.testing.allocator);

    switch (result) {
        .loaded => |bundle| {
            const staged = statusLineStatsForTest(bundle.document, "src/staged.zig") orelse return error.ExpectedStagedStats;
            try std.testing.expectEqual(@as(usize, 2), staged.added);
            try std.testing.expectEqual(@as(usize, 0), staged.removed);

            const untracked = statusLineStatsForTest(bundle.document, "src/untracked.zig") orelse return error.ExpectedUntrackedStats;
            try std.testing.expectEqual(@as(usize, 2), untracked.added);
            try std.testing.expectEqual(@as(usize, 0), untracked.removed);
        },
        else => return error.ExpectedStatusSnapshot,
    }
}

test "runStatusLoad keys staged rename stats by current path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, tmp.dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "old.txt", .data = "one\ntwo\n" });
    try runTestGit(io, &.{ "git", "add", "old.txt" }, tmp.dir);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "initial" }, tmp.dir);
    try runTestGit(io, &.{ "git", "mv", "old.txt", "new.txt" }, tmp.dir);

    const repo_root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(repo_root);

    var result = runStatusLoad(repo_root, std.testing.allocator, io);
    defer result.deinit(std.testing.allocator);

    switch (result) {
        .loaded => |bundle| {
            const renamed = statusLineStatsForTest(bundle.document, "new.txt") orelse return error.ExpectedRenameStats;
            try std.testing.expectEqual(@as(usize, 2), renamed.added);
            try std.testing.expectEqual(@as(usize, 0), renamed.removed);
            try std.testing.expect(statusLineStatsForTest(bundle.document, "old.txt") == null);
        },
        else => return error.ExpectedStatusSnapshot,
    }
}

fn statusLineStatsForTest(document: git_status.StatusDocument, key: []const u8) ?file_tree.Stats {
    for (document.line_stats) |entry| {
        if (std.mem.eql(u8, entry.path_key, key)) return entry.stats;
    }
    return null;
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

test "StatusLoadTask failed preserves generation and moves repo root" {
    const TestLoadMsg = union(enum) {
        status_loaded: StatusLoadFinished,
    };
    const TestMsg = union(enum) {
        load: TestLoadMsg,

        pub fn loadFinished(msg: TestLoadMsg) @This() {
            return .{ .load = msg };
        }
    };
    const Task = StatusLoadTask(TestMsg);
    const allocator = std.testing.allocator;

    const task = try allocator.create(Task);
    task.* = .{
        .repo_root = try allocator.dupe(u8, "/repo"),
        .generation = 42,
    };

    const msg = Task.failed(task, .{ .start_failed = "SystemResources" }, allocator);
    var finished = switch (msg) {
        .load => |load| switch (load) {
            .status_loaded => |payload| payload,
        },
    };
    defer finished.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 42), finished.generation);
    try std.testing.expectEqualStrings("/repo", finished.repo_root);
    try std.testing.expectEqualStrings("SystemResources", switch (finished.result) {
        .failed_static => |message| message,
        else => return error.UnexpectedResult,
    });
}

test "DiffLoadTask failed frees request and preserves generation" {
    const TestLoadMsg = union(enum) {
        diff_loaded: DiffLoadFinished,
    };
    const TestMsg = union(enum) {
        load: TestLoadMsg,

        pub fn loadFinished(msg: TestLoadMsg) @This() {
            return .{ .load = msg };
        }
    };
    const Task = DiffLoadTask(TestMsg);
    const allocator = std.testing.allocator;

    const task = try allocator.create(Task);
    task.* = .{
        .request = .{
            .source = .{ .range = try allocator.dupe(u8, "HEAD~1..HEAD") },
            .repo_root = try allocator.dupe(u8, "/repo"),
        },
        .generation = 9,
    };

    const msg = Task.failed(task, .{ .start_failed = "OutOfMemory" }, allocator);
    var finished = switch (msg) {
        .load => |load| switch (load) {
            .diff_loaded => |payload| payload,
        },
    };
    defer finished.result.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 9), finished.generation);
    try std.testing.expectEqualStrings("OutOfMemory", switch (finished.result) {
        .failed_static => |message| message,
        else => return error.UnexpectedResult,
    });
}

test "ReviewProjectionTask failed preserves request identity" {
    const TestLoadMsg = union(enum) {
        review_projection_loaded: ReviewProjectionFinished,
    };
    const TestMsg = union(enum) {
        load: TestLoadMsg,

        pub fn loadFinished(msg: TestLoadMsg) @This() {
            return .{ .load = msg };
        }
    };
    const Task = ReviewProjectionTask(TestMsg);
    const allocator = std.testing.allocator;

    const task = try allocator.create(Task);
    task.* = .{ .request = .{
        .id = 11,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .path_key = try allocator.dupe(u8, "src/main.zig"),
        .kind = .cached_diff,
        .source_kind = .unstaged,
        .load_generation = 2,
        .status_generation = 3,
    } };

    const msg = Task.failed(task, .{ .start_failed = "OutOfMemory" }, allocator);
    var finished = switch (msg) {
        .load => |load| switch (load) {
            .review_projection_loaded => |payload| payload,
        },
    };
    defer finished.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 11), finished.request.id);
    try std.testing.expectEqual(@as(u64, 2), finished.request.load_generation);
    try std.testing.expectEqual(@as(u64, 3), finished.request.status_generation);
    try std.testing.expectEqualStrings("/repo", finished.request.repo_root);
    try std.testing.expectEqualStrings("src/main.zig", finished.request.path_key);
    try std.testing.expectEqualStrings("OutOfMemory", switch (finished.result) {
        .failed_static => |message| message,
        else => return error.UnexpectedResult,
    });
}
