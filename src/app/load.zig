const std = @import("std");
const diff_parser = @import("../diff/parser.zig");
const diff_source = @import("../diff/source.zig");
const diff_view_model = @import("../diff/view_model.zig");
const file_tree = @import("../file_tree.zig");
const git_backend = @import("../git/backend.zig");
const git_status = @import("../git/status.zig");
const loaded_diff = @import("../loaded_diff.zig");
const repo_discovery = @import("../repo/discovery.zig");

const LoadRequest = diff_source.LoadRequest;
const LoadedDiff = loaded_diff.LoadedDiff;

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
/// app/app_load import cycle.
pub fn RepoDiscoveryTask(comptime Msg: type) type {
    return struct {
        generation: u64,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer allocator.destroy(task);

            return @unionInit(Msg, "repos_discovered", RepoDiscoveryFinished{
                .generation = task.generation,
                .result = runDiscovery(allocator, io),
            });
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

            return @unionInit(Msg, "repo_path_discovered", RepoPathDiscoveryFinished{
                .generation = task.generation,
                .submitted_path = submitted_path,
                .result = runPathDiscovery(submitted_path, allocator, io),
            });
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

            return @unionInit(Msg, "diff_loaded", DiffLoadFinished{
                .generation = task.generation,
                .result = runLoad(task.request, allocator, io),
            });
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

            return @unionInit(Msg, "status_loaded", result);
        }
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
            if (bytes.len == 0) return .empty;
            const bundle = git_status.StatusBundle.parseOwned(allocator, bytes) catch |err| {
                return .{ .failed = std.fmt.allocPrint(allocator, "Status parse failed: {s}", .{@errorName(err)}) catch
                    return .{ .failed_static = "Status parse failed: OutOfMemory" } };
            };
            return .{ .loaded = bundle };
        },
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
            const bundle = buildLoadedBundle(allocator, bytes) catch |err| {
                return .{ .failed = std.fmt.allocPrint(allocator, "Diff parse failed: {s}", .{@errorName(err)}) catch
                    return .{ .failed_static = "Diff parse failed: OutOfMemory" } };
            };
            return .{ .loaded = bundle };
        },
        .failed => |message| return .{ .failed = message },
        .failed_static => |message| return .{ .failed_static = message },
    }
}

pub fn buildLoadedBundle(allocator: std.mem.Allocator, bytes: []const u8) !LoadedDiffBundle {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    const copied = try arena_allocator.dupe(u8, bytes);
    const document = try diff_parser.parse(arena_allocator, copied);
    const tree = try file_tree.build(arena_allocator, document);
    const rendered_line_cache = try diff_view_model.RenderedLineCache.build(arena_allocator, document);
    const collapsed_hunks = try arena_allocator.alloc(bool, document.totalHunks());
    @memset(collapsed_hunks, false);
    var loaded: LoadedDiff = .{
        .bytes = copied.len,
        .lines = countLines(copied),
        .text = copied,
        .document = document,
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
