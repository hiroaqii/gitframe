const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const content_fingerprint = @import("../content_fingerprint.zig");
const chasen = @import("chasen");
const auto_reload = @import("auto_reload.zig");
const actions = @import("actions.zig");
const page = @import("page.zig");
const diff_parser = @import("../diff/parser.zig");
const diff_hunk_projection = @import("../diff/hunk_projection.zig");
const diff_presentation_identity = @import("../diff/presentation_identity.zig");
const diff_render = @import("../diff/render.zig");
const diff_source = @import("../diff/source.zig");
const diff_syntax_view = @import("../diff/syntax_view.zig");
const diff_view_model = @import("../diff/view_model.zig");
const file_tree = @import("../file_tree.zig");
const git_backend = @import("../git/backend.zig");
const git_branch_status = @import("../git/branch_status.zig");
const git_status = @import("../git/status.zig");
const loaded_diff = @import("../loaded_diff.zig");
const path_key_mod = @import("../path_key.zig");
const process_runner = @import("../process/runner.zig");
const projection_component = @import("projection_component.zig");
const review_projection = @import("review_projection.zig");
const review_read_epoch = @import("review_read_epoch.zig");
const repo_discovery = @import("../repo/discovery.zig");
const root_capability = @import("../repo/root_capability.zig");
const selected_document = @import("../repository/document.zig");
const repository_source = @import("../repository/source.zig");
const source_syntax = @import("../syntax/source.zig");
const source_syntax_runtime = @import("../syntax/source_runtime.zig");
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
    identity: page.RequestIdentity,
    read_epoch: review_read_epoch.ReviewRepositoryReadEpoch = .{},
    generation: u64,
    background_cycle_id: ?u64 = null,
    result: DiffLoadTaskResult,

    pub fn deinit(self: *DiffLoadFinished, allocator: std.mem.Allocator) void {
        self.result.deinit(allocator);
        self.* = undefined;
    }
};

/// Result payload sent from the asynchronous repository discovery task.
pub const RepoDiscoveryFinished = struct {
    identity: page.RequestIdentity,
    generation: u64,
    background_cycle_id: ?u64 = null,
    result: RepoDiscoveryTaskResult,

    pub fn deinit(self: *RepoDiscoveryFinished, allocator: std.mem.Allocator) void {
        self.result.deinit(allocator);
        self.* = undefined;
    }
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
    identity: page.RequestIdentity,
    read_epoch: review_read_epoch.ReviewRepositoryReadEpoch = .{},
    generation: u64,
    background_cycle_id: ?u64 = null,
    repo_root: []u8,
    result: StatusLoadTaskResult,

    pub fn deinit(self: *StatusLoadFinished, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        self.result.deinit(allocator);
    }
};

/// Result payload sent from the asynchronous branch status load task.
pub const BranchStatusLoadFinished = struct {
    identity: page.RequestIdentity,
    read_epoch: review_read_epoch.ReviewRepositoryReadEpoch = .{},
    generation: u64,
    background_cycle_id: ?u64 = null,
    repo_root: []u8,
    result: BranchStatusLoadTaskResult,

    pub fn deinit(self: *BranchStatusLoadFinished, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        self.result.deinit(allocator);
    }
};

pub const BranchListLoadFinished = struct {
    origin: page.Id,
    repo_epoch: u64,
    activation_id: u64,
    generation: u64,
    repo_root: []u8,
    result: BranchListLoadTaskResult,

    pub fn deinit(self: *BranchListLoadFinished, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        self.result.deinit(allocator);
    }
};

pub const ReviewProjectionFinished = review_projection.Finished;

/// Read results whose acceptance and retained state belong to the Review page.
/// The shell still transports these messages and starts any follow-up effects,
/// but it must not flatten their vocabulary back into root App messages.
pub const ReviewReadFinished = union(enum) {
    source: DiffLoadFinished,
    status: StatusLoadFinished,
    branch_status: BranchStatusLoadFinished,
    projection: ReviewProjectionFinished,
    projection_syntax: review_projection.GeneratedSyntaxFinished,

    pub fn deinit(self: *ReviewReadFinished, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*finished| finished.deinit(allocator),
        }
        self.* = undefined;
    }
};

/// Read results accepted by a live shell-owned operation surface.
pub const ShellReadFinished = union(enum) {
    repo_path_discovery: RepoPathDiscoveryFinished,
    branch_list: BranchListLoadFinished,

    pub fn deinit(self: *ShellReadFinished, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*finished| finished.deinit(allocator),
        }
        self.* = undefined;
    }
};

/// Results whose acceptance starts in one owner and commits state in another.
/// Repository discovery is validated by Review, then transferred to the App
/// repository-identity coordinator as one owned command.
pub const CoordinatorReadFinished = union(enum) {
    repo_discovery: RepoDiscoveryFinished,

    pub fn deinit(self: *CoordinatorReadFinished, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*finished| finished.deinit(allocator),
        }
        self.* = undefined;
    }
};

/// Exhaustive owner routing for every asynchronous read completion.
/// Adding a Repository page extends this union with a page-owned branch rather
/// than adding Repository-shaped tags beside Review tags in App.Msg.
pub const ReadFinished = union(enum) {
    review: ReviewReadFinished,
    shell: ShellReadFinished,
    coordinator: CoordinatorReadFinished,

    pub fn deinit(self: *ReadFinished, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*finished| finished.deinit(allocator),
        }
        self.* = undefined;
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
    unchanged: content_fingerprint.Fingerprint,
    loaded: LoadedDiffBundle,
    failed: []u8,
    failed_static: []const u8,

    pub fn deinit(self: *DiffLoadTaskResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .empty, .unchanged, .failed_static => {},
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
    fingerprint: content_fingerprint.Fingerprint = .{
        .byte_len = 0,
        .digest = [_]u8{0} ** 32,
    },

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
        identity: page.RequestIdentity,
        generation: u64,
        background_cycle_id: ?u64 = null,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, runDiscovery(allocator, io));
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, .{ .failed_static = actions.taskFailureMessage(failure) });
        }

        /// Spawn-failure counterpart of the terminal epilogue: releases the
        /// task-owned payload without producing a Msg.
        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            allocator.destroy(task);
        }

        /// Terminal epilogue shared by run and failed; owned-field release,
        /// moves, and destroy live only here.
        fn finish(task: *@This(), allocator: std.mem.Allocator, result: RepoDiscoveryTaskResult) Msg {
            defer allocator.destroy(task);
            return Msg.loadFinished(.{ .coordinator = .{ .repo_discovery = RepoDiscoveryFinished{
                .identity = task.identity,
                .generation = task.generation,
                .background_cycle_id = task.background_cycle_id,
                .result = result,
            } } });
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
            return task.finish(allocator, runPathDiscovery(task.path, allocator, io));
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, .{ .failed_static = actions.taskFailureMessage(failure) });
        }

        /// Terminal epilogue shared by run and failed; owned-field release,
        /// moves, and destroy live only here.
        fn finish(task: *@This(), allocator: std.mem.Allocator, result: RepoPathDiscoveryTaskResult) Msg {
            defer allocator.destroy(task);
            const submitted_path = task.path;
            task.path = &.{};
            return Msg.loadFinished(.{ .shell = .{ .repo_path_discovery = RepoPathDiscoveryFinished{
                .generation = task.generation,
                .submitted_path = submitted_path,
                .result = result,
            } } });
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
        identity: page.RequestIdentity,
        read_epoch: review_read_epoch.ReviewRepositoryReadEpoch,
        request: LoadRequest,
        generation: u64,
        expected_fingerprint: ?content_fingerprint.Fingerprint = null,
        background_cycle_id: ?u64 = null,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, runLoadExpected(task.request, task.expected_fingerprint, allocator, io));
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, .{ .failed_static = actions.taskFailureMessage(failure) });
        }

        /// Spawn-failure counterpart of the terminal epilogue: releases the
        /// task-owned payload without producing a Msg.
        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            task.request.deinit(allocator);
            allocator.destroy(task);
        }

        /// Terminal epilogue shared by run and failed; owned-field release,
        /// moves, and destroy live only here.
        fn finish(task: *@This(), allocator: std.mem.Allocator, result: DiffLoadTaskResult) Msg {
            defer {
                diff_source.freeLoadRequest(allocator, task.request);
                allocator.destroy(task);
            }
            return Msg.loadFinished(.{ .review = .{ .source = DiffLoadFinished{
                .identity = task.identity,
                .read_epoch = task.read_epoch,
                .generation = task.generation,
                .background_cycle_id = task.background_cycle_id,
                .result = result,
            } } });
        }
    };
}

pub fn StatusLoadTask(comptime Msg: type) type {
    return struct {
        identity: page.RequestIdentity,
        read_epoch: review_read_epoch.ReviewRepositoryReadEpoch,
        repo_root: []u8,
        generation: u64,
        origin: git_backend.ReadOrigin = .foreground,
        background_cycle_id: ?u64 = null,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, runStatusLoadWithOrigin(task.repo_root, task.origin, allocator, io));
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, .{ .failed_static = actions.taskFailureMessage(failure) });
        }

        /// Spawn-failure counterpart of the terminal epilogue: releases the
        /// task-owned payload without producing a Msg.
        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(task.repo_root);
            allocator.destroy(task);
        }

        /// Terminal epilogue shared by run and failed; owned-field release,
        /// moves, and destroy live only here.
        fn finish(task: *@This(), allocator: std.mem.Allocator, result: StatusLoadTaskResult) Msg {
            defer allocator.destroy(task);
            const finished = StatusLoadFinished{
                .identity = task.identity,
                .read_epoch = task.read_epoch,
                .generation = task.generation,
                .background_cycle_id = task.background_cycle_id,
                .repo_root = task.repo_root,
                .result = result,
            };
            task.repo_root = &.{};
            return Msg.loadFinished(.{ .review = .{ .status = finished } });
        }
    };
}

pub fn BranchStatusLoadTask(comptime Msg: type) type {
    return struct {
        identity: page.RequestIdentity,
        read_epoch: review_read_epoch.ReviewRepositoryReadEpoch,
        repo_root: []u8,
        /// Borrowed from process initialization; App and the runtime keep it
        /// alive until every spawned task has completed.
        env_map: ?*const std.process.Environ.Map,
        generation: u64,
        background_cycle_id: ?u64 = null,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, runBranchStatusLoad(task.repo_root, task.env_map, allocator, io));
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, .{ .failed_static = actions.taskFailureMessage(failure) });
        }

        /// Spawn-failure counterpart of the terminal epilogue: releases the
        /// task-owned payload without producing a Msg.
        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(task.repo_root);
            allocator.destroy(task);
        }

        /// Terminal epilogue shared by run and failed; owned-field release,
        /// moves, and destroy live only here.
        fn finish(task: *@This(), allocator: std.mem.Allocator, result: BranchStatusLoadTaskResult) Msg {
            defer allocator.destroy(task);
            const finished = BranchStatusLoadFinished{
                .identity = task.identity,
                .read_epoch = task.read_epoch,
                .generation = task.generation,
                .background_cycle_id = task.background_cycle_id,
                .repo_root = task.repo_root,
                .result = result,
            };
            task.repo_root = &.{};
            return Msg.loadFinished(.{ .review = .{ .branch_status = finished } });
        }
    };
}

pub fn BranchListLoadTask(comptime Msg: type) type {
    return struct {
        origin: page.Id,
        repo_epoch: u64,
        activation_id: u64,
        repo_root: []u8,
        generation: u64,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, runBranchListLoad(task.repo_root, allocator, io));
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, .{ .failed_static = actions.taskFailureMessage(failure) });
        }

        /// Spawn-failure counterpart of the terminal epilogue: releases the
        /// task-owned payload without producing a Msg.
        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(task.repo_root);
            allocator.destroy(task);
        }

        /// Terminal epilogue shared by run and failed; owned-field release,
        /// moves, and destroy live only here.
        fn finish(task: *@This(), allocator: std.mem.Allocator, result: BranchListLoadTaskResult) Msg {
            defer allocator.destroy(task);
            const finished = BranchListLoadFinished{
                .origin = task.origin,
                .repo_epoch = task.repo_epoch,
                .activation_id = task.activation_id,
                .generation = task.generation,
                .repo_root = task.repo_root,
                .result = result,
            };
            task.repo_root = &.{};
            return Msg.loadFinished(.{ .shell = .{ .branch_list = finished } });
        }
    };
}

pub fn ReviewProjectionTask(comptime Msg: type) type {
    return struct {
        request: review_projection.Request,
        root: ?root_capability.RootCapability = null,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, runReviewProjectionLoad(task.request, task.root, allocator, io));
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, .{ .failed_static = actions.taskFailureMessage(failure) });
        }

        /// Spawn-failure counterpart of the terminal epilogue: releases the
        /// task-owned payload without producing a Msg.
        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            task.request.deinit(allocator);
            if (task.root) |*root| root.deinit();
            allocator.destroy(task);
        }

        /// Terminal epilogue shared by run and failed; owned-field release,
        /// moves, and destroy live only here.
        fn finish(task: *@This(), allocator: std.mem.Allocator, result: review_projection.TaskResult) Msg {
            defer allocator.destroy(task);
            defer if (task.root) |*root| root.deinit();
            const request = task.request;
            task.request = undefined;
            return Msg.loadFinished(.{ .review = .{ .projection = ReviewProjectionFinished{
                .request = request,
                .result = result,
            } } });
        }
    };
}

/// run/failed intentionally stay separate terminals (no shared `finish`):
/// the failure path discards the failure and returns `.terminal_plain`
/// (plain display) instead of a failure-string variant of the success result.
pub fn GeneratedSyntaxTask(comptime Msg: type) type {
    return struct {
        request: review_projection.GeneratedSyntaxRequest,
        root: root_capability.RootCapability,

        /// Spawn-failure counterpart of the terminal epilogue: releases the
        /// task-owned payload without producing a Msg.
        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            task.request.deinit(allocator);
            task.root.deinit();
            allocator.destroy(task);
        }

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer allocator.destroy(task);
            defer task.root.deinit();

            const request = task.request;
            task.request = undefined;
            var snapshot_fingerprint: ?content_fingerprint.Fingerprint = null;
            var result: review_projection.GeneratedSyntaxResult = .{ .terminal_plain = .provider_unavailable };

            if (!task.root.identity.eql(request.root_identity)) {
                result = .stale;
            } else {
                var snapshot = selected_document.load(task.root, request.path_key, allocator, io);
                defer snapshot.deinit(allocator);
                switch (snapshot.value) {
                    .text => |text| {
                        snapshot_fingerprint = text.fingerprint;
                        if (!text.fingerprint.eql(request.expected_fingerprint)) {
                            result = .stale;
                        } else {
                            var source = repository_source.Document.initOwned(allocator, text.bytes, text.fingerprint) catch null;
                            if (source) |*document| {
                                snapshot.value = .unreadable;
                                defer document.deinit(allocator);
                                const spans: ?source_syntax.SourceSpans = source_syntax_runtime.buildSourceSpans(allocator, io, document, request.path_key) catch null;
                                if (spans) |owned| result = .{ .loaded = owned };
                            }
                        }
                    },
                    else => {},
                }
            }

            return Msg.loadFinished(.{ .review = .{ .projection_syntax = .{
                .request = request,
                .snapshot_fingerprint = snapshot_fingerprint,
                .result = result,
            } } });
        }

        pub fn failed(ctx_ptr: *anyopaque, _: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer allocator.destroy(task);
            defer task.root.deinit();

            const request = task.request;
            task.request = undefined;
            return Msg.loadFinished(.{ .review = .{ .projection_syntax = .{
                .request = request,
                .snapshot_fingerprint = null,
                .result = .{ .terminal_plain = .provider_unavailable },
            } } });
        }
    };
}

pub fn runStatusLoad(repo_root: []const u8, allocator: std.mem.Allocator, io: std.Io) StatusLoadTaskResult {
    return runStatusLoadWithOrigin(repo_root, .foreground, allocator, io);
}

pub fn runStatusLoadWithOrigin(
    repo_root: []const u8,
    origin: git_backend.ReadOrigin,
    allocator: std.mem.Allocator,
    io: std.Io,
) StatusLoadTaskResult {
    const raw_result = git_backend.LocalCommandBackend.loadStatus(allocator, io, .{ .repo_root = repo_root, .origin = origin }) catch |err| {
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

pub fn runBranchStatusLoad(
    repo_root: []const u8,
    env_map: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    io: std.Io,
) BranchStatusLoadTaskResult {
    const raw_result = git_backend.LocalCommandBackend.loadBranchStatus(allocator, io, .{
        .cwd = .{ .path = repo_root },
        .parent_env = env_map,
    }) catch |err| {
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
    const raw_result = git_backend.LocalCommandBackend.loadBranchList(allocator, io, .{ .repo_root = repo_root }) catch |err| {
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
    return runLoadExpected(request, null, allocator, io);
}

pub fn runLoadExpected(
    request: LoadRequest,
    expected_fingerprint: ?content_fingerprint.Fingerprint,
    allocator: std.mem.Allocator,
    io: std.Io,
) DiffLoadTaskResult {
    const raw_result = diff_source.load(allocator, io, request) catch |err| {
        return .{
            .failed = std.fmt.allocPrint(allocator, "Diff load failed: {s}", .{@errorName(err)}) catch
                return .{ .failed_static = "Diff load failed: OutOfMemory" },
        };
    };

    switch (raw_result) {
        .ok => |bytes| {
            defer allocator.free(bytes);
            const fingerprint = content_fingerprint.Fingerprint.init(bytes);
            if (expected_fingerprint) |expected| {
                if (expected.eql(fingerprint)) return .{ .unchanged = fingerprint };
            }
            if (bytes.len == 0) return .empty;
            const bundle = buildLoadedBundleForRequest(allocator, io, bytes, request, fingerprint) catch |err| {
                return .{ .failed = std.fmt.allocPrint(allocator, "Diff parse failed: {s}", .{@errorName(err)}) catch
                    return .{ .failed_static = "Diff parse failed: OutOfMemory" } };
            };
            return .{ .loaded = bundle };
        },
        .failed => |message| return .{ .failed = message },
        .failed_static => |message| return .{ .failed_static = message },
    }
}

pub fn runReviewProjectionLoad(
    request: review_projection.Request,
    root: ?root_capability.RootCapability,
    allocator: std.mem.Allocator,
    io: std.Io,
) review_projection.TaskResult {
    return switch (request.kind) {
        .cached_diff => loadCachedFileDiff(request, allocator, io),
        .generated_added_file => loadGeneratedAddedFile(request, root, allocator, io),
        .combined_hunks => loadCombinedHunks(request, allocator, io),
    };
}

fn loadCachedFileDiff(request: review_projection.Request, allocator: std.mem.Allocator, io: std.Io) review_projection.TaskResult {
    var component = loadFileProjectionComponent(request, allocator, io, .cached) catch |err| {
        return .{ .failed = review_projection.statusBodyAlloc(allocator, request.path_key, "Cached diff load failed: {s}", .{@errorName(err)}) catch
            return .{ .failed_static = "Cached diff load failed: OutOfMemory" } };
    } orelse {
        return .{ .ready = .{ .status_body = review_projection.statusBodyAlloc(allocator, request.path_key, "No staged diff for this file.", .{}) catch
            return .{ .failed_static = "Projection allocation failed" } } };
    };
    defer component.deinit();
    return buildCachedFileTaskResult(request, allocator, io, &component);
}

/// Select a parse-only staged-only candidate only when the request names the
/// same canonical presentation. A miss promotes the already parsed component
/// into the established eager cached projection in this same completion.
fn buildCachedFileTaskResult(
    request: review_projection.Request,
    allocator: std.mem.Allocator,
    io: std.Io,
    component: *projection_component.ParsedComponent,
) review_projection.TaskResult {
    if (request.expected_presentation) |expected| {
        if (component.document.files.len == 1 and component.fileTextSelectable(0)) {
            const fingerprint = diff_presentation_identity.fingerprint(component.document.files[0]);
            if (fingerprint.eql(expected.fingerprint)) {
                const authority_allocator = component.arena.?.allocator();
                const hunk_count = component.document.files[0].hunks.len;
                const stage_states = authority_allocator.alloc(diff_hunk_projection.HunkStageState, hunk_count) catch
                    return buildCachedFileEagerResult(request.path_key, allocator, io, component);
                @memset(stage_states, .staged);
                const action_origins = authority_allocator.alloc(diff_hunk_projection.HunkActionOrigin, hunk_count) catch
                    return buildCachedFileEagerResult(request.path_key, allocator, io, component);
                for (action_origins, 0..) |*origin, hunk_index| origin.* = .{ .cached = hunk_index };

                const candidate: review_projection.StagedOnlyReuseCandidate = .{
                    .fingerprint = fingerprint,
                    .fresh_authority = .{
                        .projection = .{
                            .hunk_stage_states = stage_states,
                            .hunk_action_origins = action_origins,
                        },
                        .cached_component = component.*,
                        .status_snapshot_revision = request.status_snapshot_revision,
                    },
                };
                component.arena = null;
                return .{ .staged_only_reuse_candidate = candidate };
            }
        }
    }
    return buildCachedFileEagerResult(request.path_key, allocator, io, component);
}

fn buildCachedFileEagerResult(
    path_key: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,
    component: *projection_component.ParsedComponent,
) review_projection.TaskResult {
    const bundle = decorateProjectionComponent(component, io) catch |err| {
        return .{ .failed = review_projection.statusBodyAlloc(
            allocator,
            path_key,
            "Cached diff load failed: {s}",
            .{@errorName(err)},
        ) catch return .{ .failed_static = "Cached diff load failed: OutOfMemory" } };
    };
    return .{ .ready = .{ .cached_diff = bundle } };
}

fn loadFileProjectionComponent(
    request: review_projection.Request,
    allocator: std.mem.Allocator,
    io: std.Io,
    base: git_backend.FileDiffBase,
) !?projection_component.ParsedComponent {
    const bytes = try loadFileDiffBytes(request, allocator, io, base) orelse return null;
    defer allocator.free(bytes);
    return try projection_component.ParsedComponent.parse(allocator, bytes);
}

fn loadFileDiffBytes(
    request: review_projection.Request,
    allocator: std.mem.Allocator,
    io: std.Io,
    base: git_backend.FileDiffBase,
) !?[]u8 {
    const raw_result = try git_backend.LocalCommandBackend.loadDiff(allocator, io, .{
        .repo_root = request.repo_root,
        .kind = .{ .file = .{ .base = base, .path = request.path_key } },
    });

    switch (raw_result) {
        .ok => |bytes| {
            if (bytes.len == 0) {
                allocator.free(bytes);
                return null;
            }
            return bytes;
        },
        .failed => |message| {
            defer allocator.free(message);
            return error.GitCommandFailed;
        },
        .failed_static => return error.GitCommandFailed,
    }
}

fn loadCombinedHunks(request: review_projection.Request, allocator: std.mem.Allocator, io: std.Io) review_projection.TaskResult {
    var cached_component = loadFileProjectionComponent(request, allocator, io, .cached) catch |err| {
        return .{ .failed = review_projection.statusBodyAlloc(allocator, request.path_key, "Staged hunk projection load failed: {s}", .{@errorName(err)}) catch
            return .{ .failed_static = "Projection load failed: OutOfMemory" } };
    } orelse return .{ .ready = .{ .status_body = review_projection.statusBodyAlloc(allocator, request.path_key, "No staged hunks for this file.", .{}) catch
        return .{ .failed_static = "Projection allocation failed" } } };
    defer cached_component.deinit();

    var unstaged_component = loadFileProjectionComponent(request, allocator, io, .unstaged) catch |err| {
        return .{ .failed = review_projection.statusBodyAlloc(allocator, request.path_key, "Unstaged hunk projection load failed: {s}", .{@errorName(err)}) catch
            return .{ .failed_static = "Projection load failed: OutOfMemory" } };
    } orelse return .{ .ready = .{ .status_body = review_projection.statusBodyAlloc(allocator, request.path_key, "No unstaged hunks for this file.", .{}) catch
        return .{ .failed_static = "Projection allocation failed" } } };
    defer unstaged_component.deinit();

    return buildCombinedHunkTaskResult(request, allocator, io, &cached_component, &unstaged_component);
}

/// Select the cheap cross-generation candidate only when the request carries
/// a matching presentation fingerprint. A missing hint (including the single
/// retry after an App-side exact mismatch) and an ordinary fingerprint miss
/// both finish in this same worker completion with the established eager
/// decoration path.
fn buildCombinedHunkTaskResult(
    request: review_projection.Request,
    allocator: std.mem.Allocator,
    io: std.Io,
    cached_component: *projection_component.ParsedComponent,
    unstaged_component: *projection_component.ParsedComponent,
) review_projection.TaskResult {
    if (request.expected_presentation) |expected| {
        var prepared = prepareCombinedReuse(
            allocator,
            cached_component,
            unstaged_component,
        ) catch return buildCombinedHunkResult(
            request.path_key,
            request.status_snapshot_revision,
            .init(request.id),
            allocator,
            io,
            cached_component,
            unstaged_component,
        );

        if (prepared.fingerprint.eql(expected.fingerprint)) {
            return .{ .reuse_candidate = prepared.takeCandidate(
                request.status_snapshot_revision,
                cached_component,
                unstaged_component,
            ) };
        }

        prepared.deinit();
    }

    return buildCombinedHunkResult(
        request.path_key,
        request.status_snapshot_revision,
        .init(request.id),
        allocator,
        io,
        cached_component,
        unstaged_component,
    );
}

/// Normalize two parse-only components, eagerly decorate an independent
/// presentation generation, and transfer both owner domains only for a ready
/// combined terminal. This remains the authoritative path for an initial
/// display, a fingerprint miss, and the one hint-free exact-mismatch retry.
fn buildCombinedHunkResult(
    path_key: []const u8,
    status_snapshot_revision: u64,
    content_token: diff_presentation_identity.ContentToken,
    allocator: std.mem.Allocator,
    io: std.Io,
    cached_component: *projection_component.ParsedComponent,
    unstaged_component: *projection_component.ParsedComponent,
) review_projection.TaskResult {
    if (cached_component.document.files.len != 1 or unstaged_component.document.files.len != 1) {
        return .{ .ready = .{ .status_body = review_projection.statusBodyAlloc(allocator, path_key, "Cannot combine staged and unstaged hunks for this file.", .{}) catch
            return .{ .failed_static = "Projection allocation failed" } } };
    }

    const text_selectable = cached_component.fileTextSelectable(0) and unstaged_component.fileTextSelectable(0);
    if (!text_selectable) {
        var decorated = decorateProjectionComponents(cached_component, unstaged_component, io) catch |err| {
            return projectionDecorationFailureResult(allocator, path_key, err);
        };
        defer decorated.deinit();
        const bundle = review_projection.InertCombinedBundle{
            .cached_bundle = decorated.cached,
            .unstaged_bundle = decorated.unstaged,
        };
        decorated.cached.arena = null;
        decorated.unstaged.arena = null;
        return .{ .ready = .{ .inert_combined = bundle } };
    }

    // The parsed inputs become fresh patch authority. Reparse their already
    // owned bytes for the eager presentation so its decorated component
    // storage can outlive replacement of that authority in P4. Parsing is
    // This eager branch deliberately keeps presentation and authority in one
    // same-generation result even though their owners remain replaceable.
    var cached_presentation_component = projection_component.ParsedComponent.parse(allocator, cached_component.text) catch |err| {
        return projectionDecorationFailureResult(allocator, path_key, err);
    };
    defer cached_presentation_component.deinit();
    var unstaged_presentation_component = projection_component.ParsedComponent.parse(allocator, unstaged_component.text) catch |err| {
        return projectionDecorationFailureResult(allocator, path_key, err);
    };
    defer unstaged_presentation_component.deinit();

    var presentation_arena: std.heap.ArenaAllocator = .init(allocator);
    var authority_arena: std.heap.ArenaAllocator = .init(allocator);
    const projection = diff_hunk_projection.buildWithAllocators(
        presentation_arena.allocator(),
        authority_arena.allocator(),
        cached_presentation_component.document.files[0],
        unstaged_presentation_component.document.files[0],
    ) catch |err| {
        presentation_arena.deinit();
        authority_arena.deinit();
        // Unlike invalid text, unsafe coordinates cannot retain an inert
        // projection because that would expose fabricated action targets.
        const body = switch (err) {
            error.UnmappableCoordinate => review_projection.statusBodyAlloc(
                allocator,
                path_key,
                "Cannot combine staged and unstaged hunks: line coordinates cannot be normalized safely.",
                .{},
            ),
            else => review_projection.statusBodyAlloc(
                allocator,
                path_key,
                "Cannot combine staged and unstaged hunks: {s}",
                .{@errorName(err)},
            ),
        } catch return .{ .failed_static = "Projection allocation failed" };
        return .{ .ready = .{ .status_body = body } };
    };

    const bundle = decorateCombinedProjection(
        presentation_arena,
        authority_arena,
        projection,
        status_snapshot_revision,
        content_token,
        &cached_presentation_component,
        &unstaged_presentation_component,
        cached_component,
        unstaged_component,
        io,
    ) catch |err| {
        return projectionDecorationFailureResult(allocator, path_key, err);
    };
    return .{ .ready = .{ .combined_hunks = bundle } };
}

/// Build the provider-independent half of a possible combined-presentation
/// reuse. This function deliberately has no task I/O and cannot decorate
/// syntax. The returned candidate owns normalized comparison storage
/// separately from fresh patch authority so acceptance can discard the former
/// and transfer the latter without retaining a redundant projection arena.
const PreparedCombinedReuse = struct {
    candidate_arena: ?std.heap.ArenaAllocator,
    authority_arena: ?std.heap.ArenaAllocator,
    projection: diff_hunk_projection.Projection,
    fingerprint: diff_presentation_identity.Fingerprint,

    fn deinit(self: *PreparedCombinedReuse) void {
        if (self.candidate_arena) |*arena| arena.deinit();
        self.candidate_arena = null;
        if (self.authority_arena) |*arena| arena.deinit();
        self.authority_arena = null;
        self.projection = undefined;
    }

    /// Transfer both parsed inputs only after the worker has selected the
    /// candidate terminal. A fingerprint miss leaves them untouched for the
    /// ordinary eager builder.
    fn takeCandidate(
        self: *PreparedCombinedReuse,
        status_snapshot_revision: u64,
        cached_component: *projection_component.ParsedComponent,
        unstaged_component: *projection_component.ParsedComponent,
    ) review_projection.CombinedReuseCandidate {
        const candidate: review_projection.CombinedReuseCandidate = .{
            .candidate_arena = self.candidate_arena,
            .projection = self.projection.presentation,
            .fingerprint = self.fingerprint,
            .fresh_authority = .{
                .arena = self.authority_arena,
                .projection = self.projection.authority,
                .cached_component = cached_component.*,
                .unstaged_component = unstaged_component.*,
                .status_snapshot_revision = status_snapshot_revision,
            },
        };
        self.candidate_arena = null;
        self.authority_arena = null;
        self.projection = undefined;
        cached_component.arena = null;
        unstaged_component.arena = null;
        return candidate;
    }
};

fn prepareCombinedReuse(
    allocator: std.mem.Allocator,
    cached_component: *const projection_component.ParsedComponent,
    unstaged_component: *const projection_component.ParsedComponent,
) diff_hunk_projection.BuildError!PreparedCombinedReuse {
    if (cached_component.document.files.len != 1 or unstaged_component.document.files.len != 1) {
        return error.UnsupportedFile;
    }
    if (!cached_component.fileTextSelectable(0) or !unstaged_component.fileTextSelectable(0)) {
        return error.UnsupportedFile;
    }

    var candidate_arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer candidate_arena.deinit();
    var authority_arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer authority_arena.deinit();

    const projection = try diff_hunk_projection.buildWithAllocators(
        candidate_arena.allocator(),
        authority_arena.allocator(),
        cached_component.document.files[0],
        unstaged_component.document.files[0],
    );

    return .{
        .candidate_arena = candidate_arena,
        .authority_arena = authority_arena,
        .projection = projection,
        .fingerprint = diff_presentation_identity.fingerprint(projection.presentation.file),
    };
}

fn buildCombinedReuseCandidate(
    status_snapshot_revision: u64,
    allocator: std.mem.Allocator,
    cached_component: *projection_component.ParsedComponent,
    unstaged_component: *projection_component.ParsedComponent,
) diff_hunk_projection.BuildError!review_projection.CombinedReuseCandidate {
    var prepared = try prepareCombinedReuse(allocator, cached_component, unstaged_component);
    errdefer prepared.deinit();
    return prepared.takeCandidate(status_snapshot_revision, cached_component, unstaged_component);
}

fn projectionDecorationFailureResult(
    allocator: std.mem.Allocator,
    path_key: []const u8,
    err: anyerror,
) review_projection.TaskResult {
    const body = review_projection.statusBodyAlloc(
        allocator,
        path_key,
        "Projection decoration failed: {s}",
        .{@errorName(err)},
    ) catch return .{ .failed_static = "Projection decoration failed: OutOfMemory" };
    return .{ .failed = body };
}

const DecoratedProjectionComponents = struct {
    cached: LoadedDiffBundle,
    unstaged: LoadedDiffBundle,

    fn deinit(self: *DecoratedProjectionComponents) void {
        self.cached.deinit();
        self.unstaged.deinit();
    }
};

fn decorateProjectionComponents(
    cached_component: *projection_component.ParsedComponent,
    unstaged_component: *projection_component.ParsedComponent,
    io: std.Io,
) !DecoratedProjectionComponents {
    var cached = try decorateProjectionComponent(cached_component, io);
    errdefer cached.deinit();
    return .{
        .cached = cached,
        .unstaged = try decorateProjectionComponent(unstaged_component, io),
    };
}

/// Consume normalized presentation/authority arenas, promote only the
/// presentation components, and retain the original parse-only components as
/// patch authority. Every owner is released here on failure and transferred
/// exactly once on success.
fn decorateCombinedProjection(
    presentation_arena_owner: std.heap.ArenaAllocator,
    authority_arena_owner: std.heap.ArenaAllocator,
    projection: diff_hunk_projection.Projection,
    status_snapshot_revision: u64,
    content_token: diff_presentation_identity.ContentToken,
    cached_presentation_component: *projection_component.ParsedComponent,
    unstaged_presentation_component: *projection_component.ParsedComponent,
    cached_authority_component: *projection_component.ParsedComponent,
    unstaged_authority_component: *projection_component.ParsedComponent,
    io: std.Io,
) !review_projection.CombinedHunkBundle {
    var presentation_arena = presentation_arena_owner;
    errdefer presentation_arena.deinit();
    var authority_arena = authority_arena_owner;
    errdefer authority_arena.deinit();
    var decorated = try decorateProjectionComponents(cached_presentation_component, unstaged_presentation_component, io);
    errdefer decorated.deinit();

    const bundle = review_projection.CombinedHunkBundle{
        .presentation = .{
            .arena = presentation_arena,
            .projection = projection.presentation,
            .cached_bundle = decorated.cached,
            .unstaged_bundle = decorated.unstaged,
            .fingerprint = diff_presentation_identity.fingerprint(projection.presentation.file),
            .content_token = content_token,
        },
        .authority = .{
            .arena = authority_arena,
            .projection = projection.authority,
            .cached_component = cached_authority_component.*,
            .unstaged_component = unstaged_authority_component.*,
            .status_snapshot_revision = status_snapshot_revision,
        },
    };
    decorated.cached.arena = null;
    decorated.unstaged.arena = null;
    cached_authority_component.arena = null;
    unstaged_authority_component.arena = null;
    return bundle;
}

fn loadGeneratedAddedFile(
    request: review_projection.Request,
    root: ?root_capability.RootCapability,
    allocator: std.mem.Allocator,
    io: std.Io,
) review_projection.TaskResult {
    const capability = root orelse return .{ .failed_static = "Repository root is unavailable" };
    if (!request.matchesRootIdentity(capability.identity)) return .{ .failed_static = "Repository root changed" };

    var snapshot = selected_document.load(capability, request.path_key, allocator, io);
    defer snapshot.deinit(allocator);
    switch (snapshot.value) {
        .text => |text| {
            const bytes = text.bytes;
            const fingerprint = text.fingerprint;
            snapshot.value = .unreadable;
            const bundle = review_projection.generatedFileFromOwnedContent(
                allocator,
                request.path_key,
                bytes,
                fingerprint,
            ) catch return .{ .failed_static = "Generated preview allocation failed" };
            return .{ .ready = .{ .generated_added_file = bundle } };
        },
        .binary => return generatedStatusBody(allocator, request.path_key, "Binary file content is not shown."),
        .invalid_utf8 => return generatedStatusBody(allocator, request.path_key, "Invalid UTF-8 file content is not shown."),
        .unsafe_control_text => return generatedStatusBody(allocator, request.path_key, "Unsafe control characters are not shown."),
        .oversized => return generatedStatusBody(allocator, request.path_key, "File exceeds the 1 MiB preview limit."),
        .symlink => return generatedStatusBody(allocator, request.path_key, "Symbolic link content is not shown."),
        .directory_or_gitlink => return generatedStatusBody(allocator, request.path_key, "Directory content is not shown."),
        .named_pipe, .unix_socket, .block_device, .character_device, .unknown_special => return generatedStatusBody(allocator, request.path_key, "Special file content is not shown."),
        .missing_or_changed => return generatedStatusBody(allocator, request.path_key, "File changed while loading."),
        .unreadable => return generatedStatusBody(allocator, request.path_key, "File content could not be read."),
        .unsupported_platform => return generatedStatusBody(allocator, request.path_key, "Safe file preview is unavailable on this platform."),
    }
}

fn generatedStatusBody(allocator: std.mem.Allocator, path: []const u8, message: []const u8) review_projection.TaskResult {
    return .{ .ready = .{ .status_body = review_projection.statusBodyAlloc(allocator, path, "{s}", .{message}) catch
        return .{ .failed_static = "Projection allocation failed" } } };
}

/// Residual stats-only helper for best-effort untracked line counts. Review
/// preview bytes must use `repository/document.zig` instead: this legacy walk
/// validates components but cannot make its stat/open pairs race-free.
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
    return buildLoadedBundleWithOptions(allocator, io, bytes, .{}, content_fingerprint.Fingerprint.init(bytes));
}

fn buildLoadedBundleForRequest(
    allocator: std.mem.Allocator,
    io: std.Io,
    bytes: []const u8,
    request: LoadRequest,
    fingerprint: content_fingerprint.Fingerprint,
) !LoadedDiffBundle {
    const root = request.repo_root orelse return buildLoadedBundleWithOptions(allocator, io, bytes, .{}, fingerprint);
    const name = repoRootName(root);
    return buildLoadedBundleWithOptions(allocator, io, bytes, .{ .root = .{ .name = name } }, fingerprint);
}

fn buildLoadedBundleWithOptions(
    allocator: std.mem.Allocator,
    io: std.Io,
    bytes: []const u8,
    tree_options: file_tree.BuildOptions,
    fingerprint: content_fingerprint.Fingerprint,
) !LoadedDiffBundle {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    // DiffDocument string fields borrow from the input bytes, so keep the raw
    // diff text and parser-allocated arrays in the same arena.
    const copied = try arena_allocator.dupe(u8, bytes);
    const document = try diff_parser.parse(arena_allocator, copied);
    const file_text_eligibility = try @import("../diff/text_eligibility.zig").classifyDocument(arena_allocator, document);
    const loaded = try decorateLoadedDiff(
        arena_allocator,
        io,
        copied,
        document,
        file_text_eligibility,
        tree_options,
    );

    // Do not store `arena_allocator` in the result: its interface points at
    // this local arena value, while the arena itself is moved by value across
    // the task-result boundary.
    return .{
        .arena = arena,
        .loaded = loaded,
        .fingerprint = fingerprint,
    };
}

/// Promote one parse-only projection component into the ordinary, fully
/// decorated bundle used by the current Review renderer. Failure leaves the
/// component owner intact; success transfers its arena exactly once.
fn decorateProjectionComponent(
    component: *projection_component.ParsedComponent,
    io: std.Io,
) !LoadedDiffBundle {
    const arena_allocator = component.arena.?.allocator();
    const loaded = try decorateLoadedDiff(
        arena_allocator,
        io,
        component.text,
        component.document,
        component.file_text_eligibility,
        .{},
    );
    const fingerprint = component.fingerprint;
    const arena = component.takeArena();
    return .{
        .arena = arena,
        .loaded = loaded,
        .fingerprint = fingerprint,
    };
}

/// Build every presentation derivative from an already-owned parsed model.
/// Both the ordinary load path and projection promotion use this one work
/// order so P2 cannot silently diverge in syntax, tree, or rendered-row state.
fn decorateLoadedDiff(
    arena_allocator: std.mem.Allocator,
    io: std.Io,
    copied: []const u8,
    document: diff_parser.DiffDocument,
    file_text_eligibility: []const loaded_diff.FileTextEligibility,
    tree_options: file_tree.BuildOptions,
) !LoadedDiff {
    const syntax_spans = try syntax_provider.buildDocumentSpans(arena_allocator, io, document, file_text_eligibility);
    const tree = try file_tree.buildWithOptions(arena_allocator, document, null, tree_options);
    const rendered_line_cache = try diff_view_model.RenderedLineCache.build(arena_allocator, document);
    const collapsed_hunks = try arena_allocator.alloc(bool, document.totalHunks());
    @memset(collapsed_hunks, false);
    var loaded: LoadedDiff = .{
        .bytes = copied.len,
        .lines = countLines(copied),
        .text = copied,
        .document = document,
        .file_text_eligibility = file_text_eligibility,
        .syntax_spans = syntax_spans,
        .tree = tree,
        .rendered_line_cache = rendered_line_cache,
        .collapsed_hunks = collapsed_hunks,
        .collapsed_dirs = .empty,
    };
    try loaded.rebuildVisibleNodes(arena_allocator, false, .all);
    return loaded;
}

fn repoRootName(root: []const u8) []const u8 {
    const base = std.fs.path.basename(root);
    if (base.len == 0) return root;
    return base;
}

pub fn countLines(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;

    var count: usize = 1;
    for (bytes) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
}

const p2_cached_patch =
    "diff --git a/a.zig b/a.zig\n" ++
    "--- a/a.zig\n" ++
    "+++ b/a.zig\n" ++
    "@@ -1 +1 @@\n" ++
    "-const old = 1;\n" ++
    "+const staged = 2;\n";
const p2_unstaged_patch =
    "diff --git a/a.zig b/a.zig\n" ++
    "--- a/a.zig\n" ++
    "+++ b/a.zig\n" ++
    "@@ -3 +3 @@\n" ++
    "-const before = 3;\n" ++
    "+const current = 4;\n";

fn testCombinedProjectionRequest(
    allocator: std.mem.Allocator,
    id: u64,
    status_snapshot_revision: u64,
    expected_presentation: ?review_projection.ExpectedPresentation,
) !review_projection.Request {
    return review_projection.cloneRequestWithOptions(
        allocator,
        page.RequestIdentity.review(0, 1),
        id,
        "/repo",
        "a.zig",
        .combined_hunks,
        .unstaged,
        0,
        status_snapshot_revision,
        .{
            .read_epoch = .{},
            .expected_presentation = expected_presentation,
        },
    );
}

fn testCachedProjectionRequest(
    allocator: std.mem.Allocator,
    id: u64,
    status_snapshot_revision: u64,
    expected_presentation: ?review_projection.ExpectedPresentation,
) !review_projection.Request {
    return review_projection.cloneRequestWithOptions(
        allocator,
        page.RequestIdentity.review(0, 1),
        id,
        "/repo",
        "a.zig",
        .cached_diff,
        .unstaged,
        0,
        status_snapshot_revision,
        .{
            .read_epoch = .{},
            .expected_presentation = expected_presentation,
        },
    );
}

test "cached worker publishes staged-only candidate only for matching presentation hint" {
    const allocator = std.testing.allocator;
    var component = try projection_component.ParsedComponent.parse(allocator, p2_cached_patch);
    defer component.deinit();
    const expected_fingerprint = diff_presentation_identity.fingerprint(component.document.files[0]);
    var request = try testCachedProjectionRequest(allocator, 20, 7, .{
        .fingerprint = expected_fingerprint,
        .content_token = .init(19),
    });
    defer request.deinit(allocator);

    var result = buildCachedFileTaskResult(request, allocator, std.testing.io, &component);
    defer result.deinit(allocator);
    try std.testing.expect(result == .staged_only_reuse_candidate);
    try std.testing.expect(component.arena == null);
    const candidate = &result.staged_only_reuse_candidate;
    try std.testing.expect(candidate.fingerprint.eql(expected_fingerprint));
    try std.testing.expectEqual(@as(u64, 7), candidate.fresh_authority.?.status_snapshot_revision);
    try std.testing.expectEqual(candidate.displayFile().hunks.len, candidate.fresh_authority.?.projection.hunk_stage_states.len);
    for (candidate.fresh_authority.?.projection.hunk_stage_states, candidate.fresh_authority.?.projection.hunk_action_origins, 0..) |state, origin, hunk_index| {
        try std.testing.expectEqual(diff_hunk_projection.HunkStageState.staged, state);
        try std.testing.expectEqual(hunk_index, origin.cached);
    }

    var eager_component = try projection_component.ParsedComponent.parse(allocator, p2_cached_patch);
    defer eager_component.deinit();
    var mismatch = expected_fingerprint;
    mismatch.digest[0] ^= 0xff;
    var eager_request = try testCachedProjectionRequest(allocator, 21, 8, .{
        .fingerprint = mismatch,
        .content_token = .init(20),
    });
    defer eager_request.deinit(allocator);
    var eager = buildCachedFileTaskResult(eager_request, allocator, std.testing.io, &eager_component);
    defer eager.deinit(allocator);
    try std.testing.expect(eager == .ready);
    try std.testing.expect(eager.ready == .cached_diff);
    try std.testing.expect(eager_component.arena == null);
}

test "combined worker publishes provider-independent candidate only for matching hint" {
    const allocator = std.testing.allocator;
    var cached = try projection_component.ParsedComponent.parse(allocator, p2_cached_patch);
    defer cached.deinit();
    var unstaged = try projection_component.ParsedComponent.parse(allocator, p2_unstaged_patch);
    defer unstaged.deinit();

    var probe = try prepareCombinedReuse(allocator, &cached, &unstaged);
    const expected_fingerprint = probe.fingerprint;
    probe.deinit();
    var request = try testCombinedProjectionRequest(allocator, 21, 8, .{
        .fingerprint = expected_fingerprint,
        .content_token = .init(20),
    });
    defer request.deinit(allocator);

    // `prepareCombinedReuse` has no I/O/provider dependency. Reaching this
    // terminal proves the provider-capable eager branch below was not entered;
    // App still performs allocation-free exact equality before acceptance.
    var result = buildCombinedHunkTaskResult(request, allocator, std.testing.io, &cached, &unstaged);
    defer result.deinit(allocator);
    try std.testing.expect(result == .reuse_candidate);
    try std.testing.expect(cached.arena == null);
    try std.testing.expect(unstaged.arena == null);
    try std.testing.expect(result.reuse_candidate.fingerprint.eql(expected_fingerprint));
    try std.testing.expectEqual(@as(u64, 8), result.reuse_candidate.fresh_authority.?.status_snapshot_revision);
    try std.testing.expect(!@hasField(review_projection.CombinedReuseCandidate, "syntax_spans"));
    try std.testing.expect(!@hasField(review_projection.CombinedReuseCandidate, "cached_bundle"));
}

test "combined worker publishes provider-independent candidate for exact primary hint" {
    const allocator = std.testing.allocator;
    var cached = try projection_component.ParsedComponent.parse(allocator, p2_cached_patch);
    defer cached.deinit();
    var unstaged = try projection_component.ParsedComponent.parse(allocator, p2_unstaged_patch);
    defer unstaged.deinit();

    var probe = try prepareCombinedReuse(allocator, &cached, &unstaged);
    const expected_fingerprint = probe.fingerprint;
    probe.deinit();
    var request = try testCombinedProjectionRequest(allocator, 25, 12, .{
        .owner = .primary_loaded,
        .fingerprint = expected_fingerprint,
        .content_token = .init(4),
    });
    defer request.deinit(allocator);

    var result = buildCombinedHunkTaskResult(request, allocator, std.testing.io, &cached, &unstaged);
    defer result.deinit(allocator);
    try std.testing.expect(result == .reuse_candidate);
    try std.testing.expect(result.reuse_candidate.fingerprint.eql(expected_fingerprint));
    try std.testing.expectEqual(@as(u64, 12), result.reuse_candidate.fresh_authority.?.status_snapshot_revision);
}

test "combined worker uses one eager completion for fingerprint miss and hint-free retry" {
    const allocator = std.testing.allocator;

    var mismatch_cached = try projection_component.ParsedComponent.parse(allocator, p2_cached_patch);
    defer mismatch_cached.deinit();
    var mismatch_unstaged = try projection_component.ParsedComponent.parse(allocator, p2_unstaged_patch);
    defer mismatch_unstaged.deinit();
    var mismatch_request = try testCombinedProjectionRequest(allocator, 22, 9, .{
        .fingerprint = .{ .digest = [_]u8{0xa5} ** 32 },
        .content_token = .init(20),
    });
    defer mismatch_request.deinit(allocator);
    var mismatch = buildCombinedHunkTaskResult(
        mismatch_request,
        allocator,
        std.testing.io,
        &mismatch_cached,
        &mismatch_unstaged,
    );
    defer mismatch.deinit(allocator);
    try std.testing.expect(mismatch == .ready);
    try std.testing.expect(mismatch.ready == .combined_hunks);
    try std.testing.expect(mismatch.ready.combined_hunks.presentation.content_token.eql(.init(22)));

    var retry_cached = try projection_component.ParsedComponent.parse(allocator, p2_cached_patch);
    defer retry_cached.deinit();
    var retry_unstaged = try projection_component.ParsedComponent.parse(allocator, p2_unstaged_patch);
    defer retry_unstaged.deinit();
    var retry_request = try testCombinedProjectionRequest(allocator, 23, 10, null);
    defer retry_request.deinit(allocator);
    var retry = buildCombinedHunkTaskResult(
        retry_request,
        allocator,
        std.testing.io,
        &retry_cached,
        &retry_unstaged,
    );
    defer retry.deinit(allocator);
    try std.testing.expect(retry == .ready);
    try std.testing.expect(retry.ready == .combined_hunks);
    try std.testing.expect(retry.ready.combined_hunks.presentation.content_token.eql(.init(23)));
}

test "combined worker candidate selection releases allocation and eager fallback terminals" {
    if (build_options.syntax_provider_flow_syntax) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var cached = try projection_component.ParsedComponent.parse(allocator, p2_cached_patch);
    defer cached.deinit();
    var unstaged = try projection_component.ParsedComponent.parse(allocator, p2_unstaged_patch);
    defer unstaged.deinit();
    var probe = try prepareCombinedReuse(allocator, &cached, &unstaged);
    const expected_fingerprint = probe.fingerprint;
    probe.deinit();

    const Harness = struct {
        fn run(failing_allocator: std.mem.Allocator, expected: diff_presentation_identity.Fingerprint) !void {
            var candidate_cached = try projection_component.ParsedComponent.parse(failing_allocator, p2_cached_patch);
            defer candidate_cached.deinit();
            var candidate_unstaged = try projection_component.ParsedComponent.parse(failing_allocator, p2_unstaged_patch);
            defer candidate_unstaged.deinit();
            var request = try testCombinedProjectionRequest(failing_allocator, 24, 11, .{
                .fingerprint = expected,
                .content_token = .init(20),
            });
            defer request.deinit(failing_allocator);
            var result = buildCombinedHunkTaskResult(
                request,
                failing_allocator,
                std.testing.io,
                &candidate_cached,
                &candidate_unstaged,
            );
            defer result.deinit(failing_allocator);
        }
    };
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        try std.testing.expect(fail_index < 4096);
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        Harness.run(failing.allocator(), expected_fingerprint) catch |err| switch (err) {
            error.OutOfMemory => {},
            else => return err,
        };
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (!failing.has_induced_failure) break;
    }
}

test "combined projection eagerly decorates parse-only components" {
    const allocator = std.testing.allocator;
    var cached = try projection_component.ParsedComponent.parse(allocator, p2_cached_patch);
    defer cached.deinit();
    var unstaged = try projection_component.ParsedComponent.parse(allocator, p2_unstaged_patch);
    defer unstaged.deinit();

    var result = buildCombinedHunkResult("a.zig", 7, .init(11), allocator, std.testing.io, &cached, &unstaged);
    defer result.deinit(allocator);
    try std.testing.expect(result == .ready);
    try std.testing.expect(result.ready == .combined_hunks);
    try std.testing.expect(cached.arena == null);
    try std.testing.expect(unstaged.arena == null);
    const bundle = &result.ready.combined_hunks;
    try std.testing.expectEqual(@as(usize, 2), bundle.displayFile().hunks.len);
    try std.testing.expectEqualStrings(p2_cached_patch, bundle.presentation.cached_bundle.loaded.text);
    try std.testing.expectEqualStrings(p2_unstaged_patch, bundle.presentation.unstaged_bundle.loaded.text);
    try std.testing.expectEqualStrings(p2_cached_patch, bundle.authority.cached_component.text);
    try std.testing.expectEqualStrings(p2_unstaged_patch, bundle.authority.unstaged_component.text);
    try std.testing.expect(bundle.presentation.cached_bundle.loaded.text.ptr != bundle.authority.cached_component.text.ptr);
    try std.testing.expect(bundle.presentation.unstaged_bundle.loaded.text.ptr != bundle.authority.unstaged_component.text.ptr);
    try std.testing.expectEqual(@as(usize, 1), bundle.presentation.cached_bundle.loaded.tree.nodes.len);
    try std.testing.expectEqual(@as(usize, 1), bundle.presentation.unstaged_bundle.loaded.tree.nodes.len);
    try std.testing.expect(bundle.presentation.cached_bundle.fingerprint.eql(bundle.authority.cached_component.fingerprint));
    try std.testing.expect(bundle.presentation.unstaged_bundle.fingerprint.eql(bundle.authority.unstaged_component.fingerprint));
    try std.testing.expect(bundle.presentation.fingerprint.eql(diff_presentation_identity.fingerprint(bundle.displayFile())));
    try std.testing.expect(bundle.presentation.content_token.eql(.init(11)));
    const cached_action_file = bundle.actionSourceFile(.{ .cached = 0 }) orelse return error.ExpectedCachedAuthorityFile;
    const unstaged_action_file = bundle.actionSourceFile(.{ .unstaged = 0 }) orelse return error.ExpectedUnstagedAuthorityFile;
    try std.testing.expect(cached_action_file.hunks[0].lines[0].text.ptr == bundle.authority.cached_component.document.files[0].hunks[0].lines[0].text.ptr);
    try std.testing.expect(unstaged_action_file.hunks[0].lines[0].text.ptr == bundle.authority.unstaged_component.document.files[0].hunks[0].lines[0].text.ptr);
    try std.testing.expect(cached_action_file.hunks[0].lines[0].text.ptr != bundle.presentation.cached_bundle.loaded.document.files[0].hunks[0].lines[0].text.ptr);
    try std.testing.expect(unstaged_action_file.hunks[0].lines[0].text.ptr != bundle.presentation.unstaged_bundle.loaded.document.files[0].hunks[0].lines[0].text.ptr);
    try std.testing.expectEqual(@as(u64, 7), bundle.authority.status_snapshot_revision);
}

test "combined reuse candidate separates comparison storage from fresh authority" {
    const allocator = std.testing.allocator;
    var cached = try projection_component.ParsedComponent.parse(allocator, p2_cached_patch);
    defer cached.deinit();
    var unstaged = try projection_component.ParsedComponent.parse(allocator, p2_unstaged_patch);
    defer unstaged.deinit();

    var candidate = try buildCombinedReuseCandidate(8, allocator, &cached, &unstaged);
    defer candidate.deinit();

    try std.testing.expect(cached.arena == null);
    try std.testing.expect(unstaged.arena == null);
    try std.testing.expect(candidate.candidate_arena != null);
    try std.testing.expect(candidate.fresh_authority != null);
    try std.testing.expectEqual(@as(usize, 2), candidate.displayFile().hunks.len);
    try std.testing.expect(candidate.fingerprint.eql(diff_presentation_identity.fingerprint(candidate.displayFile())));
    try std.testing.expect(candidate.retainedBytes() > 0);
    try std.testing.expect(!@hasField(review_projection.CombinedReuseCandidate, "cached_bundle"));
    try std.testing.expect(!@hasField(review_projection.CombinedReuseCandidate, "unstaged_bundle"));
    try std.testing.expect(!@hasField(review_projection.CombinedReuseCandidate, "syntax_spans"));

    const authority = &candidate.fresh_authority.?;
    try std.testing.expectEqual(@as(u64, 8), authority.status_snapshot_revision);
    try std.testing.expectEqualStrings(p2_cached_patch, authority.cached_component.text);
    try std.testing.expectEqualStrings(p2_unstaged_patch, authority.unstaged_component.text);
    try std.testing.expect(candidate.displayFile().hunks[0].lines[0].text.ptr == authority.cached_component.document.files[0].hunks[0].lines[0].text.ptr);
    try std.testing.expect(candidate.displayFile().hunks[1].lines[0].text.ptr == authority.unstaged_component.document.files[0].hunks[0].lines[0].text.ptr);
    try std.testing.expectEqual(diff_hunk_projection.HunkStageState.staged, authority.projection.hunk_stage_states[0]);
    try std.testing.expectEqual(diff_hunk_projection.HunkStageState.unstaged, authority.projection.hunk_stage_states[1]);
    try std.testing.expect(authority.projection.hunk_action_origins[0] == .cached);
    try std.testing.expect(authority.projection.hunk_action_origins[1] == .unstaged);
}

test "combined reuse candidate discards comparison owner before authority transfer" {
    const allocator = std.testing.allocator;
    var cached = try projection_component.ParsedComponent.parse(allocator, p2_cached_patch);
    defer cached.deinit();
    var unstaged = try projection_component.ParsedComponent.parse(allocator, p2_unstaged_patch);
    defer unstaged.deinit();

    var candidate = try buildCombinedReuseCandidate(9, allocator, &cached, &unstaged);
    defer candidate.deinit();
    var authority = candidate.discardCandidateAndTakeAuthority();
    defer authority.deinit();

    try std.testing.expect(candidate.candidate_arena == null);
    try std.testing.expect(candidate.fresh_authority == null);
    try std.testing.expectEqual(@as(u64, 9), authority.status_snapshot_revision);
    try std.testing.expectEqualStrings(p2_cached_patch, authority.cached_component.text);
    try std.testing.expectEqualStrings(p2_unstaged_patch, authority.unstaged_component.text);
}

test "combined reuse candidate releases every allocation failure" {
    const Harness = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var cached = try projection_component.ParsedComponent.parse(allocator, p2_cached_patch);
            defer cached.deinit();
            var unstaged = try projection_component.ParsedComponent.parse(allocator, p2_unstaged_patch);
            defer unstaged.deinit();
            var candidate = try buildCombinedReuseCandidate(10, allocator, &cached, &unstaged);
            defer candidate.deinit();
        }
    };

    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}

test "combined presentation and authority owners release every allocation failure" {
    if (build_options.syntax_provider_flow_syntax) return error.SkipZigTest;

    const Harness = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var cached = try projection_component.ParsedComponent.parse(allocator, p2_cached_patch);
            defer cached.deinit();
            var unstaged = try projection_component.ParsedComponent.parse(allocator, p2_unstaged_patch);
            defer unstaged.deinit();
            var result = buildCombinedHunkResult("a.zig", 7, .init(11), allocator, std.testing.io, &cached, &unstaged);
            defer result.deinit(allocator);
        }
    };

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        try std.testing.expect(fail_index < 4096);
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        Harness.run(failing.allocator()) catch |err| switch (err) {
            error.OutOfMemory => {},
            else => return err,
        };
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (!failing.has_induced_failure) break;
    }
}

test "combined projection transfers both bundles when either component is inert" {
    const allocator = std.testing.allocator;
    const valid_patch =
        "diff --git a/a b/a\n" ++
        "index 1111111..2222222 100644\n" ++
        "--- a/a\n" ++
        "+++ b/a\n" ++
        "@@ -1 +1 @@\n" ++
        "-old\n" ++
        "+valid\n";
    const invalid_patch =
        "diff --git a/a b/a\n" ++
        "index 1111111..2222222 100644\n" ++
        "--- a/a\n" ++
        "+++ b/a\n" ++
        "@@ -1 +1 @@\n" ++
        "-old\n" ++
        "+bad\xff\n";

    for ([_]bool{ true, false }) |cached_is_invalid| {
        var cached = try projection_component.ParsedComponent.parse(allocator, if (cached_is_invalid) invalid_patch else valid_patch);
        defer cached.deinit();
        var unstaged = try projection_component.ParsedComponent.parse(allocator, if (cached_is_invalid) valid_patch else invalid_patch);
        defer unstaged.deinit();

        var result = buildCombinedHunkResult("a", 7, .init(11), allocator, std.testing.io, &cached, &unstaged);
        defer result.deinit(allocator);
        try std.testing.expect(result == .ready);
        try std.testing.expect(result.ready == .inert_combined);
        try std.testing.expect(cached.arena == null);
        try std.testing.expect(unstaged.arena == null);
        try std.testing.expectEqual(cached_is_invalid, !result.ready.inert_combined.cached_bundle.loaded.fileTextSelectable(0));
        try std.testing.expectEqual(!cached_is_invalid, !result.ready.inert_combined.unstaged_bundle.loaded.fileTextSelectable(0));
    }
}

test "combined projection reports unmappable coordinates without transferring bundles" {
    const allocator = std.testing.allocator;
    const cached_patch =
        "diff --git a/a b/a\n" ++
        "--- a/a\n" ++
        "+++ b/a\n" ++
        "@@ -13,1 +13,1 @@\n" ++
        "-old staged\n" ++
        "+new staged\n";
    const unstaged_patch =
        "diff --git a/a b/a\n" ++
        "--- a/a\n" ++
        "+++ b/a\n" ++
        "@@ -13,5 +13,4 @@\n" ++
        " context 13\n" ++
        " context 14\n" ++
        " context 15\n" ++
        "-old unstaged\n" ++
        " context 17\n";

    var cached = try projection_component.ParsedComponent.parse(allocator, cached_patch);
    defer cached.deinit();
    var unstaged = try projection_component.ParsedComponent.parse(allocator, unstaged_patch);
    defer unstaged.deinit();

    var result = buildCombinedHunkResult("a", 7, .init(11), allocator, std.testing.io, &cached, &unstaged);
    defer result.deinit(allocator);
    try std.testing.expect(result == .ready);
    try std.testing.expect(result.ready == .status_body);
    try std.testing.expectEqualStrings(
        "Cannot combine staged and unstaged hunks: line coordinates cannot be normalized safely.",
        result.ready.status_body.message,
    );
    try std.testing.expect(!result.ready.cacheable());
    try std.testing.expect(cached.arena != null);
    try std.testing.expect(unstaged.arena != null);
}

test "projection component decoration preserves loaded model and rendered cells" {
    const allocator = std.testing.allocator;
    const patch =
        "diff --git a/src/a.zig b/src/a.zig\n" ++
        "index 1111111..2222222 100644\n" ++
        "--- a/src/a.zig\n" ++
        "+++ b/src/a.zig\n" ++
        "@@ -1,2 +1,2 @@ fn main\n" ++
        "-const old: usize = 1;\n" ++
        "+const new: usize = 2;\n" ++
        " return;\n";

    var direct = try buildLoadedBundle(allocator, patch);
    defer direct.deinit();
    var component = try projection_component.ParsedComponent.parse(allocator, patch);
    defer component.deinit();
    var promoted = try decorateProjectionComponent(&component, std.testing.io);
    defer promoted.deinit();

    try std.testing.expectEqualStrings(direct.loaded.text, promoted.loaded.text);
    try std.testing.expect(direct.fingerprint.eql(promoted.fingerprint));
    try std.testing.expectEqualDeep(direct.loaded.document, promoted.loaded.document);
    try std.testing.expectEqualSlices(
        loaded_diff.FileTextEligibility,
        direct.loaded.file_text_eligibility,
        promoted.loaded.file_text_eligibility,
    );
    try std.testing.expectEqualDeep(direct.loaded.syntax_spans, promoted.loaded.syntax_spans);
    try std.testing.expectEqualDeep(direct.loaded.tree.nodes, promoted.loaded.tree.nodes);
    try std.testing.expectEqualDeep(direct.loaded.rendered_line_cache, promoted.loaded.rendered_line_cache);
    try std.testing.expectEqualSlices(bool, direct.loaded.collapsed_hunks, promoted.loaded.collapsed_hunks);
    try std.testing.expectEqualSlices(usize, direct.loaded.visible_nodes, promoted.loaded.visible_nodes);
    try std.testing.expectEqual(direct.loaded.visible_node_count, promoted.loaded.visible_node_count);
    try std.testing.expectEqual(direct.loaded.bytes, promoted.loaded.bytes);
    try std.testing.expectEqual(direct.loaded.lines, promoted.loaded.lines);

    var direct_surface: chasen.testing.TestSurface = undefined;
    try direct_surface.init(80, 8);
    defer direct_surface.deinit();
    var promoted_surface: chasen.testing.TestSurface = undefined;
    try promoted_surface.init(80, 8);
    defer promoted_surface.deinit();

    try renderLoadedFileForParity(&direct_surface.surface, &direct.loaded);
    try renderLoadedFileForParity(&promoted_surface.surface, &promoted.loaded);
    var row: u16 = 0;
    while (row < 8) : (row += 1) {
        var col: u16 = 0;
        while (col < 80) : (col += 1) {
            const expected = direct_surface.surface.readCell(col, row) orelse chasen.Cell.blank;
            const actual = promoted_surface.surface.readCell(col, row) orelse chasen.Cell.blank;
            try std.testing.expect(expected.eql(actual));
        }
    }
}

fn renderLoadedFileForParity(surface: *chasen.Surface, loaded: *const LoadedDiff) !void {
    try diff_render.renderFile(surface, loaded.document.files[0], .{
        .requested_mode = .unified,
        .line_index = loaded.renderedLineIndex(0, .unified),
        .folded_hunks = loaded.foldedHunksForFile(0),
        .syntax = diff_syntax_view.View.initDirect(&loaded.syntax_spans, 0),
    });
}

test "projection pair promotion releases partial ownership on every allocation failure" {
    if (build_options.syntax_provider_flow_syntax) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn promote(allocator: std.mem.Allocator, cached_bytes: []const u8, unstaged_bytes: []const u8) !void {
            var cached = try projection_component.ParsedComponent.parse(allocator, cached_bytes);
            defer cached.deinit();
            var unstaged = try projection_component.ParsedComponent.parse(allocator, unstaged_bytes);
            defer unstaged.deinit();
            var decorated = try decorateProjectionComponents(&cached, &unstaged, std.testing.io);
            defer decorated.deinit();
        }
    }.promote, .{ p2_cached_patch, p2_unstaged_patch });
}

test "projection decoration failure terminal owns path and message transactionally" {
    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var result = projectionDecorationFailureResult(failing.allocator(), "src/a.zig", error.OutOfMemory);
        try std.testing.expect(result == .failed_static);
        result.deinit(failing.allocator());
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }

    var successful = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var result = projectionDecorationFailureResult(successful.allocator(), "src/a.zig", error.OutOfMemory);
    try std.testing.expect(result == .failed);
    try std.testing.expectEqualStrings("src/a.zig", result.failed.path);
    try std.testing.expectEqualStrings("Projection decoration failed: OutOfMemory", result.failed.message);
    result.deinit(successful.allocator());
    try std.testing.expectEqual(successful.allocated_bytes, successful.freed_bytes);
}

test "every invalid file remains admitted as an inert tree entry" {
    const patch =
        "diff --git a/a.zig b/a.zig\n" ++
        "--- a/a.zig\n" ++
        "+++ b/a.zig\n" ++
        "@@ -1 +1 @@\n" ++
        "-old\n" ++
        "+bad\xff\n" ++
        "diff --git a/b.zig b/b.zig\n" ++
        "--- a/b.zig\n" ++
        "+++ b/b.zig\n" ++
        "@@ -1 +1 @@\n" ++
        "-old\n" ++
        "+truncated\xf0\x9f\n";
    var bundle = try buildLoadedBundle(std.testing.allocator, patch);
    defer bundle.deinit();

    try std.testing.expectEqual(@as(usize, 2), bundle.loaded.document.files.len);
    try std.testing.expectEqual(@as(usize, 2), bundle.loaded.file_text_eligibility.len);
    try std.testing.expect(!bundle.loaded.fileTextSelectable(0));
    try std.testing.expect(!bundle.loaded.fileTextSelectable(1));
    try std.testing.expectEqual(@as(usize, 2), bundle.loaded.visibleNodeCount());
}

test "expected raw fingerprint returns unchanged before diff parsing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const bytes = "not a unified diff";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "same.patch", .data = bytes });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "same.patch", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const expected = content_fingerprint.Fingerprint.init(bytes);
    var result = runLoadExpected(
        .{ .source = .{ .patch_file = path } },
        expected,
        std.testing.allocator,
        std.testing.io,
    );
    defer result.deinit(std.testing.allocator);

    switch (result) {
        .unchanged => |actual| try std.testing.expect(expected.eql(actual)),
        else => return error.ExpectedUnchangedBeforeParse,
    }
}

test "stats-only repository read rejects stable symlink components" {
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

    const content = try readRepoFileLimited(std.testing.allocator, io, repo_root, "inside.txt", review_projection.max_generated_file_bytes);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("inside", content);

    try std.testing.expectError(error.InvalidPath, readRepoFileLimited(std.testing.allocator, io, repo_root, "linked.txt", review_projection.max_generated_file_bytes));
    try std.testing.expectError(error.InvalidPath, readRepoFileLimited(std.testing.allocator, io, repo_root, "linked-dir/inside.txt", review_projection.max_generated_file_bytes));
}

test "generated projection uses pinned safe source snapshot" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "new.zig", .data = "const value = 1;\r\n" });
    const root_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root_path);
    var root = try root_capability.RootCapability.openCanonical(root_path);
    defer root.deinit();
    var request = try review_projection.testing.cloneRequestWithRootIdentity(
        allocator,
        page.RequestIdentity.review(1, 2),
        3,
        root_path,
        "new.zig",
        .generated_added_file,
        .unstaged,
        4,
        5,
        root.identity,
    );
    defer request.deinit(allocator);

    var result = runReviewProjectionLoad(request, root, allocator, io);
    defer result.deinit(allocator);
    switch (result) {
        .ready => |ready| switch (ready) {
            .generated_added_file => |bundle| {
                try std.testing.expectEqualStrings("const value = 1;", bundle.source.lineBody(0).?);
                try std.testing.expect(bundle.fingerprint().eql(content_fingerprint.Fingerprint.init("const value = 1;\r\n")));
            },
            else => return error.ExpectedGeneratedPreview,
        },
        else => return error.ExpectedGeneratedPreview,
    }
}

test "generated projection keeps unsafe text inert and rejects another root identity" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var first = std.testing.tmpDir(.{});
    defer first.cleanup();
    var second = std.testing.tmpDir(.{});
    defer second.cleanup();
    try first.dir.writeFile(io, .{ .sub_path = "unsafe.zig", .data = "before\rafter" });
    const first_path = try first.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(first_path);
    const second_path = try second.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(second_path);
    var first_root = try root_capability.RootCapability.openCanonical(first_path);
    defer first_root.deinit();
    var second_root = try root_capability.RootCapability.openCanonical(second_path);
    defer second_root.deinit();
    var request = try review_projection.testing.cloneRequestWithRootIdentity(
        allocator,
        page.RequestIdentity.review(1, 2),
        3,
        first_path,
        "unsafe.zig",
        .generated_added_file,
        .unstaged,
        4,
        5,
        first_root.identity,
    );
    defer request.deinit(allocator);

    var unsafe = runReviewProjectionLoad(request, first_root, allocator, io);
    defer unsafe.deinit(allocator);
    try std.testing.expect(switch (unsafe) {
        .ready => |ready| ready == .status_body,
        else => false,
    });

    var wrong_root = runReviewProjectionLoad(request, second_root, allocator, io);
    defer wrong_root.deinit(allocator);
    try std.testing.expect(switch (wrong_root) {
        .failed_static => |message| std.mem.eql(u8, message, "Repository root changed"),
        else => false,
    });
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

test "StatusLoadTask failed preserves read epoch generation and moves repo root" {
    const TestLoadMsg = ReadFinished;
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
        .identity = page.RequestIdentity.review(7, 11),
        .read_epoch = .{ .value = 19 },
        .repo_root = try allocator.dupe(u8, "/repo"),
        .generation = 42,
    };

    const msg = Task.failed(task, .{ .start_failed = "SystemResources" }, allocator);
    var finished = switch (msg) {
        .load => |load| switch (load) {
            .review => |review| switch (review) {
                .status => |payload| payload,
                else => return error.UnexpectedReadRoute,
            },
            else => return error.UnexpectedReadRoute,
        },
    };
    defer finished.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 42), finished.generation);
    try std.testing.expectEqual(page.RequestIdentity.review(7, 11), finished.identity);
    try std.testing.expect(finished.read_epoch.eql(.{ .value = 19 }));
    try std.testing.expectEqualStrings("/repo", finished.repo_root);
    try std.testing.expectEqualStrings("SystemResources", switch (finished.result) {
        .failed_static => |message| message,
        else => return error.UnexpectedResult,
    });
}

test "DiffLoadTask failed frees request and preserves read epoch generation" {
    const TestLoadMsg = ReadFinished;
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
        .identity = page.RequestIdentity.review(3, 5),
        .read_epoch = .{ .value = 23 },
        .request = .{
            .source = .{ .range = try allocator.dupe(u8, "HEAD~1..HEAD") },
            .repo_root = try allocator.dupe(u8, "/repo"),
        },
        .generation = 9,
    };

    const msg = Task.failed(task, .{ .start_failed = "OutOfMemory" }, allocator);
    var finished = switch (msg) {
        .load => |load| switch (load) {
            .review => |review| switch (review) {
                .source => |payload| payload,
                else => return error.UnexpectedReadRoute,
            },
            else => return error.UnexpectedReadRoute,
        },
    };
    defer finished.result.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 9), finished.generation);
    try std.testing.expectEqual(page.RequestIdentity.review(3, 5), finished.identity);
    try std.testing.expect(finished.read_epoch.eql(.{ .value = 23 }));
    try std.testing.expectEqualStrings("OutOfMemory", switch (finished.result) {
        .failed_static => |message| message,
        else => return error.UnexpectedResult,
    });
}

test "BranchStatusLoadTask failed preserves read epoch generation and moves repo root" {
    const TestLoadMsg = ReadFinished;
    const TestMsg = union(enum) {
        load: TestLoadMsg,

        pub fn loadFinished(msg: TestLoadMsg) @This() {
            return .{ .load = msg };
        }
    };
    const Task = BranchStatusLoadTask(TestMsg);
    const allocator = std.testing.allocator;

    const task = try allocator.create(Task);
    task.* = .{
        .identity = page.RequestIdentity.review(5, 13),
        .read_epoch = .{ .value = 29 },
        .repo_root = try allocator.dupe(u8, "/repo"),
        .env_map = null,
        .generation = 47,
    };

    const msg = Task.failed(task, .{ .start_failed = "SystemResources" }, allocator);
    var finished = switch (msg) {
        .load => |load| switch (load) {
            .review => |review| switch (review) {
                .branch_status => |payload| payload,
                else => return error.UnexpectedReadRoute,
            },
            else => return error.UnexpectedReadRoute,
        },
    };
    defer finished.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 47), finished.generation);
    try std.testing.expectEqual(page.RequestIdentity.review(5, 13), finished.identity);
    try std.testing.expect(finished.read_epoch.eql(.{ .value = 29 }));
    try std.testing.expectEqualStrings("/repo", finished.repo_root);
    try std.testing.expectEqualStrings("SystemResources", switch (finished.result) {
        .failed_static => |message| message,
        else => return error.UnexpectedResult,
    });
}

test "ReviewProjectionTask failed preserves request identity and read epoch" {
    const TestLoadMsg = ReadFinished;
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
        .identity = page.RequestIdentity.review(0, 1),
        .id = 11,
        .read_epoch = .{ .value = 53 },
        .repo_root = try allocator.dupe(u8, "/repo"),
        .path_key = try allocator.dupe(u8, "src/main.zig"),
        .kind = .cached_diff,
        .source_kind = .unstaged,
        .source_session_revision = 2,
        .status_snapshot_revision = 3,
    } };

    const msg = Task.failed(task, .{ .start_failed = "OutOfMemory" }, allocator);
    var finished = switch (msg) {
        .load => |load| switch (load) {
            .review => |review| switch (review) {
                .projection => |payload| payload,
                else => return error.UnexpectedReadRoute,
            },
            else => return error.UnexpectedReadRoute,
        },
    };
    defer finished.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 11), finished.request.id);
    try std.testing.expect(finished.request.read_epoch.eql(.{ .value = 53 }));
    try std.testing.expectEqual(@as(u64, 2), finished.request.source_session_revision);
    try std.testing.expectEqual(@as(u64, 3), finished.request.status_snapshot_revision);
    try std.testing.expectEqualStrings("/repo", finished.request.repo_root);
    try std.testing.expectEqualStrings("src/main.zig", finished.request.path_key);
    try std.testing.expectEqualStrings("OutOfMemory", switch (finished.result) {
        .failed_static => |message| message,
        else => return error.UnexpectedResult,
    });
}

test "GeneratedSyntaxTask rereads pinned matching source and retains read epoch" {
    if (!source_syntax_runtime.enabled) return error.SkipZigTest;
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const TestLoadMsg = ReadFinished;
    const TestMsg = union(enum) {
        load: TestLoadMsg,

        pub fn loadFinished(msg: TestLoadMsg) @This() {
            return .{ .load = msg };
        }
    };
    const Task = GeneratedSyntaxTask(TestMsg);
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const content = "const value = 1;\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "new.zig", .data = content });
    const root_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root_path);
    var root = try root_capability.RootCapability.openCanonical(root_path);
    defer root.deinit();

    const task = try allocator.create(Task);
    task.* = .{
        .request = .{
            .identity = page.RequestIdentity.review(2, 3),
            .id = 4,
            .projection_id = 5,
            .read_epoch = .{ .value = 59 },
            .root_identity = root.identity,
            .repo_root = try allocator.dupe(u8, root_path),
            .path_key = try allocator.dupe(u8, "new.zig"),
            .source_kind = .unstaged,
            .source_session_revision = 6,
            .status_snapshot_revision = 7,
            .expected_fingerprint = .init(content),
        },
        .root = try root.duplicate(),
    };
    const msg = Task.run(task, allocator, io);
    var finished = switch (msg) {
        .load => |load| switch (load) {
            .review => |review| switch (review) {
                .projection_syntax => |payload| payload,
                else => return error.UnexpectedReadRoute,
            },
            else => return error.UnexpectedReadRoute,
        },
    };
    defer finished.deinit(allocator);
    try std.testing.expect(finished.request.read_epoch.eql(.{ .value = 59 }));
    try std.testing.expect(finished.snapshot_fingerprint.?.eql(.init(content)));
    try std.testing.expect(finished.result == .loaded);
}
