const std = @import("std");
const diff_parser = @import("../diff_parser.zig");
const diff_source = @import("../diff_source.zig");
const diff_view_model = @import("../diff_view_model.zig");
const file_tree = @import("../file_tree.zig");
const loaded_diff = @import("../loaded_diff.zig");
const repo_discovery = @import("../repo_discovery.zig");

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
