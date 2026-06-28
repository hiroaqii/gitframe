const std = @import("std");
const diff_parser = @import("../diff/parser.zig");
const diff_hunk_projection = @import("../diff/hunk_projection.zig");
const diff_source = @import("../diff/source.zig");
const diff_view_model = @import("../diff/view_model.zig");
const file_tree = @import("../file_tree.zig");
const git_backend = @import("../git/backend.zig");
const git_status = @import("../git/status.zig");
const loaded_diff = @import("../loaded_diff.zig");
const review_projection = @import("review_projection.zig");
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
            return try buildLoadedBundle(allocator, bytes);
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
            return try current_dir.readFileAlloc(io, component, allocator, .limited(review_projection.max_generated_file_bytes));
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

pub fn buildLoadedBundle(allocator: std.mem.Allocator, bytes: []const u8) !LoadedDiffBundle {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    // DiffDocument string fields borrow from the input bytes, so keep the raw
    // diff text and parser-allocated arrays in the same arena.
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
