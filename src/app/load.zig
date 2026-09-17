const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const committed_review = @import("../committed_review.zig");
const content_fingerprint = @import("../content_fingerprint.zig");
const chasen = @import("chasen");
const auto_reload = @import("auto_reload.zig");
const actions = @import("actions.zig");
const branch_commit_time = @import("branch_commit_time.zig");
const diff_basis = @import("diff_basis.zig");
const page = @import("page.zig");
const diff_file = @import("../diff/file.zig");
const diff_parser = @import("../diff/parser.zig");
const diff_hunk_projection = @import("../diff/hunk_projection.zig");
const diff_presentation_identity = @import("../diff/presentation_identity.zig");
const diff_render = @import("../diff/render.zig");
const diff_source = @import("../diff/source.zig");
const diff_syntax_view = @import("../diff/syntax_view.zig");
const diff_view_model = @import("../diff/view_model.zig");
const file_tree = @import("../file_tree.zig");
const git_command = @import("../git/command.zig");
const git_committed_review = @import("../git/committed_review.zig");
const git_compare = @import("../git/compare.zig");
const git_history = @import("../git/history.zig");
const git_read = @import("../git/read.zig");
const git_refs = @import("../git/refs.zig");
const git_branch_status = @import("../git/branch_status.zig");
const git_status = @import("../git/status.zig");
const loaded_diff = @import("../loaded_diff.zig");
const path_key_mod = @import("../path_key.zig");
const projection_component = @import("projection_component.zig");
const changes_projection = @import("changes_projection.zig");
const changes_read_epoch = @import("changes_read_epoch.zig");
const repo_discovery = @import("../repo/discovery.zig");
const root_capability = @import("../repo/root_capability.zig");
const review_store = @import("../review_store.zig");
const selected_document = @import("../repository/document.zig");
const repository_source = @import("../repository/source.zig");
const source_syntax = @import("../syntax/source.zig");
const source_syntax_runtime = @import("../syntax/source_runtime.zig");
const syntax_provider = @import("../syntax/provider_runtime.zig");

const LoadRequest = diff_source.LoadRequest;
const LoadedDiff = loaded_diff.LoadedDiff;

const untracked_line_stats_per_file_bytes = 1024 * 1024;
const untracked_stats_max_files = 256;
const untracked_stats_total_bytes = 4 * 1024 * 1024;
const generated_oversized_message = std.fmt.comptimePrint(
    "File exceeds the {d} MiB preview limit.",
    .{selected_document.max_text_mib},
);

/// Task-owned authority for the three source families. Display `repo_root`
/// bytes remain in `LoadRequest` for result/context data only.
pub const LoadAuthority = union(enum) {
    repository: struct {
        root: root_capability.RootCapability,
        environment: git_command.LocalGitEnvironment,
    },
    non_repository: git_command.LocalGitEnvironment,
    none,

    pub fn initRepository(
        allocator: std.mem.Allocator,
        root: root_capability.RootCapability,
        parent_environment: ?*const std.process.Environ.Map,
    ) !LoadAuthority {
        var owned_root = try root.duplicate();
        errdefer owned_root.deinit();
        return .{ .repository = .{
            .root = owned_root,
            .environment = try git_command.LocalGitEnvironment.initFromParent(allocator, parent_environment),
        } };
    }

    pub fn initNonRepository(
        allocator: std.mem.Allocator,
        parent_environment: ?*const std.process.Environ.Map,
    ) !LoadAuthority {
        return .{ .non_repository = try git_command.LocalGitEnvironment.initFromParent(allocator, parent_environment) };
    }

    pub fn deinit(self: *LoadAuthority) void {
        switch (self.*) {
            .repository => |*repository| {
                repository.environment.deinit();
                repository.root.deinit();
            },
            .non_repository => |*environment| environment.deinit(),
            .none => {},
        }
        self.* = .none;
    }

    fn borrowed(self: *const LoadAuthority) diff_source.LoadContext {
        return switch (self.*) {
            .repository => |*repository| .{ .repository = .{
                .cwd = repository.root.dir(),
                .environment = &repository.environment,
            } },
            .non_repository => |*environment| .{ .non_repository = environment },
            .none => .none,
        };
    }
};

/// Result payload sent from the asynchronous diff load task back to App.
pub const DiffLoadFinished = struct {
    identity: page.RequestIdentity,
    read_epoch: changes_read_epoch.ChangesRepositoryReadEpoch = .{},
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
    read_epoch: changes_read_epoch.ChangesRepositoryReadEpoch = .{},
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
    read_epoch: changes_read_epoch.ChangesRepositoryReadEpoch = .{},
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

/// One atomically resolved Review read. Identity and generation remain beside
/// the owned result until the Compare page accepts or rejects the completion.
pub const CompareLoadFinished = struct {
    identity: page.RequestIdentity,
    generation: u64,
    result: CompareLoadTaskResult,

    pub fn deinit(self: *CompareLoadFinished, allocator: std.mem.Allocator) void {
        self.result.deinit(allocator);
        self.* = undefined;
    }
};

pub const CompareBranchListFinished = struct {
    identity: page.RequestIdentity,
    generation: u64,
    result: BranchListLoadTaskResult,

    pub fn deinit(self: *CompareBranchListFinished, allocator: std.mem.Allocator) void {
        self.result.deinit(allocator);
        self.* = undefined;
    }
};

pub const HistoryProbeReason = enum {
    activation,
    open_picker,
    reload,
};

pub const HistoryInitialPolicy = enum {
    reset,
    preserve_draft,
    restore_accepted,
};

pub const HistoryCatalogRequest = union(enum) {
    probe: HistoryProbeReason,
    initial: HistoryInitialPolicy,
    continuation: struct {
        format: git_history.ObjectFormat,
        cursor: git_history.ObjectId,
    },
};

pub const HistoryCatalogFinished = struct {
    identity: page.RequestIdentity,
    root_identity: root_capability.Identity,
    generation: u64,
    request: HistoryCatalogRequest,
    render_now_unix: ?i64 = null,
    result: git_history.LoadResult,

    pub fn deinit(self: *HistoryCatalogFinished, allocator: std.mem.Allocator) void {
        self.result.deinit(allocator);
        self.* = undefined;
    }
};

pub const HistoryDiffTaskResult = union(enum) {
    empty,
    loaded: CommittedDiffBundle,
    unavailable: git_committed_review.ProjectionFailure,
    failed_static: []const u8,

    pub fn deinit(self: *HistoryDiffTaskResult) void {
        switch (self.*) {
            .loaded => |*bundle| bundle.deinit(),
            .empty, .unavailable, .failed_static => {},
        }
        self.* = .empty;
    }
};

pub const HistoryDiffFinished = struct {
    identity: page.RequestIdentity,
    root_identity: root_capability.Identity,
    generation: u64,
    request: git_history.SelectionRequest,
    result: HistoryDiffTaskResult,

    pub fn deinit(self: *HistoryDiffFinished, _: std.mem.Allocator) void {
        self.result.deinit();
        self.* = undefined;
    }
};

pub const HistoryReadFinished = union(enum) {
    catalog: HistoryCatalogFinished,
    diff: HistoryDiffFinished,

    pub fn deinit(self: *HistoryReadFinished, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*finished| finished.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const AiReviewScanTaskResult = union(enum) {
    empty,
    scanned: review_store.ScanResult,
    failed_static: []const u8,

    pub fn deinit(self: *AiReviewScanTaskResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .scanned => |*result| result.deinit(allocator),
            .empty, .failed_static => {},
        }
        self.* = .empty;
    }
};

pub const AiReviewScanFinished = struct {
    identity: page.RequestIdentity,
    generation: u64,
    store_identity: review_store.ConfigurationIdentity,
    result: AiReviewScanTaskResult,

    pub fn deinit(self: *AiReviewScanFinished, allocator: std.mem.Allocator) void {
        self.result.deinit(allocator);
        self.* = undefined;
    }
};

pub const AiReviewLoadedBundle = struct {
    selection: review_store.SelectedRunRead,
    diff: CommittedDiffBundle,

    pub fn deinit(self: *AiReviewLoadedBundle, allocator: std.mem.Allocator) void {
        self.diff.deinit();
        self.selection.deinit(allocator);
        self.* = undefined;
    }
};

pub const AiReviewSelectionTaskResult = union(enum) {
    empty,
    loaded: AiReviewLoadedBundle,
    selection_failed: review_store.SelectionFailure,
    failed_static: []const u8,

    pub fn deinit(self: *AiReviewSelectionTaskResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .loaded => |*bundle| bundle.deinit(allocator),
            .empty, .selection_failed, .failed_static => {},
        }
        self.* = .empty;
    }
};

pub const AiReviewSelectionFinished = struct {
    identity: page.RequestIdentity,
    generation: u64,
    store_identity: review_store.ConfigurationIdentity,
    review_id: committed_review.ReviewId,
    result: AiReviewSelectionTaskResult,

    pub fn deinit(self: *AiReviewSelectionFinished, allocator: std.mem.Allocator) void {
        self.result.deinit(allocator);
        self.* = undefined;
    }
};

pub const ChangesProjectionFinished = changes_projection.Finished;

/// Read results whose acceptance and retained state belong to the Changes page.
/// The shell still transports these messages and starts any follow-up effects,
/// but it must not flatten their vocabulary back into root App messages.
pub const ChangesReadFinished = union(enum) {
    source: DiffLoadFinished,
    status: StatusLoadFinished,
    branch_status: BranchStatusLoadFinished,
    projection: ChangesProjectionFinished,
    projection_syntax: changes_projection.GeneratedSyntaxFinished,

    pub fn deinit(self: *ChangesReadFinished, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*finished| finished.deinit(allocator),
        }
        self.* = undefined;
    }
};

/// Read results whose acceptance and retained state belong to Compare.
pub const CompareReadFinished = union(enum) {
    source: CompareLoadFinished,
    branch_list: CompareBranchListFinished,

    pub fn deinit(self: *CompareReadFinished, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*finished| finished.deinit(allocator),
        }
        self.* = undefined;
    }
};

/// Read results whose acceptance and retained state belong to AI Reviews.
pub const AiReviewsReadFinished = union(enum) {
    history_scan: AiReviewScanFinished,
    history_selection: AiReviewSelectionFinished,

    pub fn deinit(self: *AiReviewsReadFinished, allocator: std.mem.Allocator) void {
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
/// Repository discovery is validated by Changes, then transferred to the App
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
/// than adding Repository-shaped tags beside Changes tags in App.Msg.
pub const ReadFinished = union(enum) {
    changes: ChangesReadFinished,
    history: HistoryReadFinished,
    compare: CompareReadFinished,
    ai_reviews: AiReviewsReadFinished,
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
    loaded: git_refs.BranchList,
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

/// The diff half of one committed comparison completion. An empty Git diff is a successful
/// snapshot and therefore stays paired with its resolved basis.
pub const CommittedDiffBundle = union(enum) {
    empty,
    loaded: LoadedDiffBundle,

    pub fn deinit(self: *CommittedDiffBundle) void {
        switch (self.*) {
            .empty => {},
            .loaded => |*bundle| bundle.deinit(),
        }
        self.* = .empty;
    }
};

pub const CompareLoadedBundle = struct {
    basis: diff_basis.BranchDiffBasis,
    diff: CommittedDiffBundle,

    pub fn deinit(self: *CompareLoadedBundle, allocator: std.mem.Allocator) void {
        self.basis.deinit(allocator);
        self.diff.deinit();
        self.* = undefined;
    }
};

pub const CompareBasisFailureResult = struct {
    kind: diff_basis.BasisFailure,
    attempted: diff_basis.BaseTarget,

    pub fn deinit(self: *CompareBasisFailureResult, allocator: std.mem.Allocator) void {
        self.attempted.deinit(allocator);
        self.* = undefined;
    }
};

pub const CompareLoadTaskResult = union(enum) {
    /// Neutral state used only after an owned member has been moved out.
    empty,
    loaded: CompareLoadedBundle,
    basis_failed: CompareBasisFailureResult,
    failed: []u8,
    failed_static: []const u8,

    pub fn deinit(self: *CompareLoadTaskResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .empty, .failed_static => {},
            .loaded => |*bundle| bundle.deinit(allocator),
            .basis_failed => |*failure| failure.deinit(allocator),
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
        environment: git_command.LocalGitEnvironment,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, runDiscovery(&task.environment, allocator, io));
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, .{ .failed_static = actions.taskFailureMessage(failure) });
        }

        /// Spawn-failure counterpart of the terminal epilogue: releases the
        /// task-owned payload without producing a Msg.
        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            task.environment.deinit();
            allocator.destroy(task);
        }

        /// Terminal epilogue shared by run and failed; owned-field release,
        /// moves, and destroy live only here.
        fn finish(task: *@This(), allocator: std.mem.Allocator, result: RepoDiscoveryTaskResult) Msg {
            defer allocator.destroy(task);
            defer task.environment.deinit();
            return Msg.loadFinished(.{ .coordinator = .{ .repo_discovery = RepoDiscoveryFinished{
                .identity = task.identity,
                .generation = task.generation,
                .background_cycle_id = task.background_cycle_id,
                .result = result,
            } } });
        }
    };
}

pub fn runDiscovery(
    environment: *const git_command.LocalGitEnvironment,
    allocator: std.mem.Allocator,
    io: std.Io,
) RepoDiscoveryTaskResult {
    const result = repo_discovery.discover(allocator, io, environment) catch |err| {
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
        environment: git_command.LocalGitEnvironment,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, runPathDiscovery(task.path, &task.environment, allocator, io));
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, .{ .failed_static = actions.taskFailureMessage(failure) });
        }

        /// Spawn-failure counterpart of the terminal epilogue: releases every
        /// field accepted by the queued task without producing a Msg.
        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(task.path);
            task.environment.deinit();
            allocator.destroy(task);
        }

        /// Terminal epilogue shared by run and failed; owned-field release,
        /// moves, and destroy live only here.
        fn finish(task: *@This(), allocator: std.mem.Allocator, result: RepoPathDiscoveryTaskResult) Msg {
            defer allocator.destroy(task);
            defer task.environment.deinit();
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

pub fn runPathDiscovery(
    path: []const u8,
    environment: *const git_command.LocalGitEnvironment,
    allocator: std.mem.Allocator,
    io: std.Io,
) RepoPathDiscoveryTaskResult {
    const result = repo_discovery.discoverInputPath(allocator, io, path, environment) catch |err| {
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
        read_epoch: changes_read_epoch.ChangesRepositoryReadEpoch,
        request: LoadRequest,
        authority: LoadAuthority,
        generation: u64,
        expected_fingerprint: ?content_fingerprint.Fingerprint = null,
        background_cycle_id: ?u64 = null,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, runLoadExpectedWithContext(
                task.request,
                task.authority.borrowed(),
                task.expected_fingerprint,
                allocator,
                io,
            ));
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, .{ .failed_static = actions.taskFailureMessage(failure) });
        }

        /// Spawn-failure counterpart of the terminal epilogue: releases the
        /// task-owned payload without producing a Msg.
        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            task.request.deinit(allocator);
            task.authority.deinit();
            allocator.destroy(task);
        }

        /// Terminal epilogue shared by run and failed; owned-field release,
        /// moves, and destroy live only here.
        fn finish(task: *@This(), allocator: std.mem.Allocator, result: DiffLoadTaskResult) Msg {
            defer {
                diff_source.freeLoadRequest(allocator, task.request);
                task.authority.deinit();
                allocator.destroy(task);
            }
            return Msg.loadFinished(.{ .changes = .{ .source = DiffLoadFinished{
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
        read_epoch: changes_read_epoch.ChangesRepositoryReadEpoch,
        repo_root: []u8,
        root: root_capability.RootCapability,
        environment: git_command.LocalGitEnvironment,
        generation: u64,
        origin: git_read.ReadOrigin = .foreground,
        background_cycle_id: ?u64 = null,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, runStatusLoadWithOrigin(
                task.repo_root,
                .{ .cwd = task.root.dir(), .environment = &task.environment },
                task.origin,
                allocator,
                io,
            ));
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, .{ .failed_static = actions.taskFailureMessage(failure) });
        }

        /// Spawn-failure counterpart of the terminal epilogue: releases the
        /// task-owned payload without producing a Msg.
        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(task.repo_root);
            task.environment.deinit();
            task.root.deinit();
            allocator.destroy(task);
        }

        /// Terminal epilogue shared by run and failed; owned-field release,
        /// moves, and destroy live only here.
        fn finish(task: *@This(), allocator: std.mem.Allocator, result: StatusLoadTaskResult) Msg {
            defer {
                task.environment.deinit();
                task.root.deinit();
                allocator.destroy(task);
            }
            const finished = StatusLoadFinished{
                .identity = task.identity,
                .read_epoch = task.read_epoch,
                .generation = task.generation,
                .background_cycle_id = task.background_cycle_id,
                .repo_root = task.repo_root,
                .result = result,
            };
            task.repo_root = &.{};
            return Msg.loadFinished(.{ .changes = .{ .status = finished } });
        }
    };
}

pub fn BranchStatusLoadTask(comptime Msg: type) type {
    return struct {
        identity: page.RequestIdentity,
        read_epoch: changes_read_epoch.ChangesRepositoryReadEpoch,
        repo_root: []u8,
        root: root_capability.RootCapability,
        environment: git_command.LocalGitEnvironment,
        generation: u64,
        background_cycle_id: ?u64 = null,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, runBranchStatusLoad(
                .{ .cwd = task.root.dir(), .environment = &task.environment },
                allocator,
                io,
            ));
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, .{ .failed_static = actions.taskFailureMessage(failure) });
        }

        /// Spawn-failure counterpart of the terminal epilogue: releases the
        /// task-owned payload without producing a Msg.
        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(task.repo_root);
            task.environment.deinit();
            task.root.deinit();
            allocator.destroy(task);
        }

        /// Terminal epilogue shared by run and failed; owned-field release,
        /// moves, and destroy live only here.
        fn finish(task: *@This(), allocator: std.mem.Allocator, result: BranchStatusLoadTaskResult) Msg {
            defer {
                task.environment.deinit();
                task.root.deinit();
                allocator.destroy(task);
            }
            const finished = BranchStatusLoadFinished{
                .identity = task.identity,
                .read_epoch = task.read_epoch,
                .generation = task.generation,
                .background_cycle_id = task.background_cycle_id,
                .repo_root = task.repo_root,
                .result = result,
            };
            task.repo_root = &.{};
            return Msg.loadFinished(.{ .changes = .{ .branch_status = finished } });
        }
    };
}

pub fn BranchListLoadTask(comptime Msg: type) type {
    return struct {
        origin: page.Id,
        repo_epoch: u64,
        activation_id: u64,
        repo_root: []u8,
        root: root_capability.RootCapability,
        environment: git_command.LocalGitEnvironment,
        generation: u64,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, runBranchListLoad(
                .{ .cwd = task.root.dir(), .environment = &task.environment },
                allocator,
                io,
            ));
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, .{ .failed_static = actions.taskFailureMessage(failure) });
        }

        /// Spawn-failure counterpart of the terminal epilogue: releases the
        /// task-owned payload without producing a Msg.
        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(task.repo_root);
            task.environment.deinit();
            task.root.deinit();
            allocator.destroy(task);
        }

        /// Terminal epilogue shared by run and failed; owned-field release,
        /// moves, and destroy live only here.
        fn finish(task: *@This(), allocator: std.mem.Allocator, result: BranchListLoadTaskResult) Msg {
            defer {
                task.environment.deinit();
                task.root.deinit();
                allocator.destroy(task);
            }
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

/// Async owner for one Compare snapshot request.
///
/// `init` is the only constructor: it duplicates descriptor authority and
/// snapshots the controlled Git environment plus the optional user target
/// before the task can be spawned.
pub fn CompareLoadTask(comptime Msg: type) type {
    return struct {
        identity: page.RequestIdentity,
        generation: u64,
        root: root_capability.RootCapability,
        target: ?diff_basis.BaseTarget,
        environment: git_command.LocalGitEnvironment,

        pub fn init(
            identity: page.RequestIdentity,
            generation: u64,
            root: root_capability.RootCapability,
            target: ?diff_basis.BaseTarget,
            env_map: ?*const std.process.Environ.Map,
            allocator: std.mem.Allocator,
        ) !@This() {
            var owned_root = try root.duplicate();
            errdefer owned_root.deinit();
            var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, env_map);
            errdefer environment.deinit();
            return .{
                .identity = identity,
                .generation = generation,
                .root = owned_root,
                .target = if (target) |value| try value.clone(allocator) else null,
                .environment = environment,
            };
        }

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, runCompareLoad(
                task.root.dir(),
                task.target,
                &task.environment,
                allocator,
                io,
            ));
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, .{ .failed_static = actions.taskFailureMessage(failure) });
        }

        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            task.deinitOwned(allocator);
            allocator.destroy(task);
        }

        fn finish(task: *@This(), allocator: std.mem.Allocator, result: CompareLoadTaskResult) Msg {
            defer {
                task.deinitOwned(allocator);
                allocator.destroy(task);
            }
            return Msg.loadFinished(.{ .compare = .{ .source = CompareLoadFinished{
                .identity = task.identity,
                .generation = task.generation,
                .result = result,
            } } });
        }

        fn deinitOwned(task: *@This(), allocator: std.mem.Allocator) void {
            if (task.target) |*target| target.deinit(allocator);
            task.environment.deinit();
            task.root.deinit();
        }
    };
}

/// Async owner for one exact History catalog page. The duplicated descriptor
/// and sanitized environment are the only repository authority retained by
/// the task; the cursor is a full inline OID, never a ref or offset.
pub fn HistoryCatalogTask(comptime Msg: type) type {
    return struct {
        identity: page.RequestIdentity,
        generation: u64,
        root: root_capability.RootCapability,
        request: HistoryCatalogRequest,
        environment: git_command.LocalGitEnvironment,

        pub fn init(
            identity: page.RequestIdentity,
            generation: u64,
            root: *const root_capability.RootCapability,
            request: HistoryCatalogRequest,
            env_map: ?*const std.process.Environ.Map,
            allocator: std.mem.Allocator,
        ) !@This() {
            std.debug.assert(identity.origin == .history);
            var owned_root = try root.duplicate();
            errdefer owned_root.deinit();
            var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, env_map);
            errdefer environment.deinit();
            return .{
                .identity = identity,
                .generation = generation,
                .root = owned_root,
                .request = request,
                .environment = environment,
            };
        }

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            const context: git_command.DirectoryContext = .{
                .cwd = task.root.dir(),
                .environment = &task.environment,
            };
            const result: git_history.LoadResult = switch (task.request) {
                .probe => git_history.probeHead(allocator, io, context),
                .initial => git_history.loadInitial(allocator, io, context),
                .continuation => |continuation| git_history.loadContinuation(
                    allocator,
                    io,
                    context,
                    continuation.format,
                    continuation.cursor,
                ),
            } catch git_history.LoadResult{ .failure = .git_command_failed };
            const render_now_unix = if (std.meta.activeTag(task.request) == .initial)
                branch_commit_time.sampleUnixSeconds(io)
            else
                null;
            return task.finish(allocator, result, render_now_unix);
        }

        pub fn failed(ctx_ptr: *anyopaque, _: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, .{ .failure = .git_command_failed }, null);
        }

        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            task.environment.deinit();
            task.root.deinit();
            allocator.destroy(task);
        }

        fn finish(
            task: *@This(),
            allocator: std.mem.Allocator,
            result: git_history.LoadResult,
            render_now_unix: ?i64,
        ) Msg {
            defer task.destroy(allocator);
            return Msg.loadFinished(.{ .history = .{ .catalog = .{
                .identity = task.identity,
                .root_identity = task.root.identity,
                .generation = task.generation,
                .request = task.request,
                .render_now_unix = render_now_unix,
                .result = result,
            } } });
        }
    };
}

/// Async owner for one immutable History selection. The selection request is
/// already resolved from one admitted first-parent catalog; the worker owns a
/// duplicated repository descriptor and materializes only its exact basis.
pub fn HistoryDiffTask(comptime Msg: type) type {
    return struct {
        identity: page.RequestIdentity,
        generation: u64,
        root: root_capability.RootCapability,
        request: git_history.SelectionRequest,
        environment: git_command.LocalGitEnvironment,

        pub fn init(
            identity: page.RequestIdentity,
            generation: u64,
            root: *const root_capability.RootCapability,
            request: git_history.SelectionRequest,
            env_map: ?*const std.process.Environ.Map,
            allocator: std.mem.Allocator,
        ) !@This() {
            std.debug.assert(identity.origin == .history);
            var owned_root = try root.duplicate();
            errdefer owned_root.deinit();
            var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, env_map);
            errdefer environment.deinit();
            return .{
                .identity = identity,
                .generation = generation,
                .root = owned_root,
                .request = request,
                .environment = environment,
            };
        }

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            const context: git_command.DirectoryContext = .{
                .cwd = task.root.dir(),
                .environment = &task.environment,
            };
            return task.finish(allocator, runHistoryDiffLoad(
                allocator,
                io,
                context,
                task.request,
            ));
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, .{ .failed_static = actions.taskFailureMessage(failure) });
        }

        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            task.environment.deinit();
            task.root.deinit();
            allocator.destroy(task);
        }

        fn finish(task: *@This(), allocator: std.mem.Allocator, result: HistoryDiffTaskResult) Msg {
            defer task.destroy(allocator);
            return Msg.loadFinished(.{ .history = .{ .diff = .{
                .identity = task.identity,
                .root_identity = task.root.identity,
                .generation = task.generation,
                .request = task.request,
                .result = result,
            } } });
        }
    };
}

/// Compare-owned asynchronous branch-list read. The task snapshots the
/// physical repository descriptor before spawn and never reopens cwd text.
pub fn CompareBranchListLoadTask(comptime Msg: type) type {
    return struct {
        identity: page.RequestIdentity,
        generation: u64,
        root: root_capability.RootCapability,
        env_map: ?*const std.process.Environ.Map,

        pub fn init(
            identity: page.RequestIdentity,
            generation: u64,
            root: root_capability.RootCapability,
            env_map: ?*const std.process.Environ.Map,
        ) !@This() {
            return .{
                .identity = identity,
                .generation = generation,
                .root = try root.duplicate(),
                .env_map = env_map,
            };
        }

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, runCompareBranchListLoad(
                task.root.dir(),
                task.env_map,
                allocator,
                io,
            ));
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, .{ .failed_static = actions.taskFailureMessage(failure) });
        }

        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            task.root.deinit();
            allocator.destroy(task);
        }

        fn finish(task: *@This(), allocator: std.mem.Allocator, result: BranchListLoadTaskResult) Msg {
            defer allocator.destroy(task);
            task.root.deinit();
            return Msg.loadFinished(.{ .compare = .{ .branch_list = .{
                .identity = task.identity,
                .generation = task.generation,
                .result = result,
            } } });
        }
    };
}

/// Explicit-open Review history scan. Every input needed by the worker is
/// duplicated before spawn; the completion carries the exact Store path
/// snapshot used by the read for event-loop admission.
pub fn AiReviewScanTask(comptime Msg: type) type {
    return struct {
        identity: page.RequestIdentity,
        generation: u64,
        store: review_store.ConfiguredStore,
        root: root_capability.RootCapability,
        environment: git_command.LocalGitEnvironment,

        pub fn init(
            identity: page.RequestIdentity,
            generation: u64,
            store: *const review_store.ConfiguredStore,
            root: root_capability.RootCapability,
            env_map: ?*const std.process.Environ.Map,
            allocator: std.mem.Allocator,
        ) !@This() {
            var owned_store = try store.clone(allocator);
            errdefer owned_store.deinit(allocator);
            var owned_root = try root.duplicate();
            errdefer owned_root.deinit();
            return .{
                .identity = identity,
                .generation = generation,
                .store = owned_store,
                .root = owned_root,
                .environment = try git_command.LocalGitEnvironment.initFromParent(allocator, env_map),
            };
        }

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            const scanned = review_store.scan(allocator, io, &task.store, .{
                .capability = &task.root,
                .environment = &task.environment,
            }) catch return task.finish(allocator, .{ .failed_static = "Could not load AI reviews: out of memory" });
            return task.finish(allocator, .{ .scanned = scanned });
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, .{ .failed_static = actions.taskFailureMessage(failure) });
        }

        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            task.deinitOwned(allocator);
            allocator.destroy(task);
        }

        fn finish(task: *@This(), allocator: std.mem.Allocator, result: AiReviewScanTaskResult) Msg {
            defer {
                task.environment.deinit();
                task.root.deinit();
                task.store.deinit(allocator);
                allocator.destroy(task);
            }
            const store_identity = task.store.identity();
            return Msg.loadFinished(.{ .ai_reviews = .{ .history_scan = .{
                .identity = task.identity,
                .generation = task.generation,
                .store_identity = store_identity,
                .result = result,
            } } });
        }

        fn deinitOwned(task: *@This(), allocator: std.mem.Allocator) void {
            task.environment.deinit();
            task.root.deinit();
            task.store.deinit(allocator);
        }
    };
}

/// Selection-time revalidation and exact projection parse for one scanned Run.
pub fn AiReviewSelectionTask(comptime Msg: type) type {
    return struct {
        identity: page.RequestIdentity,
        generation: u64,
        store: review_store.ConfiguredStore,
        root: root_capability.RootCapability,
        environment: git_command.LocalGitEnvironment,
        expected_store: review_store.StoreSnapshot,
        review_id: committed_review.ReviewId,
        expected_artifacts: review_store.ArtifactSnapshot,
        direct: bool,

        pub fn init(
            identity: page.RequestIdentity,
            generation: u64,
            store: *const review_store.ConfiguredStore,
            root: root_capability.RootCapability,
            env_map: ?*const std.process.Environ.Map,
            expected_store: review_store.StoreSnapshot,
            review_id: committed_review.ReviewId,
            expected_artifacts: review_store.ArtifactSnapshot,
            direct: bool,
            allocator: std.mem.Allocator,
        ) !@This() {
            var owned_store = try store.clone(allocator);
            errdefer owned_store.deinit(allocator);
            var owned_root = try root.duplicate();
            errdefer owned_root.deinit();
            return .{
                .identity = identity,
                .generation = generation,
                .store = owned_store,
                .root = owned_root,
                .environment = try git_command.LocalGitEnvironment.initFromParent(allocator, env_map),
                .expected_store = expected_store,
                .review_id = review_id,
                .expected_artifacts = expected_artifacts,
                .direct = direct,
            };
        }

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, runAiReviewSelection(
                allocator,
                io,
                &task.store,
                .{ .capability = &task.root, .environment = &task.environment },
                task.expected_store,
                task.review_id,
                task.expected_artifacts,
                task.direct,
            ));
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, .{ .failed_static = actions.taskFailureMessage(failure) });
        }

        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            task.deinitOwned(allocator);
            allocator.destroy(task);
        }

        fn finish(task: *@This(), allocator: std.mem.Allocator, result: AiReviewSelectionTaskResult) Msg {
            defer {
                task.environment.deinit();
                task.root.deinit();
                task.store.deinit(allocator);
                allocator.destroy(task);
            }
            const store_identity = task.store.identity();
            return Msg.loadFinished(.{ .ai_reviews = .{ .history_selection = .{
                .identity = task.identity,
                .generation = task.generation,
                .store_identity = store_identity,
                .review_id = task.review_id,
                .result = result,
            } } });
        }

        fn deinitOwned(task: *@This(), allocator: std.mem.Allocator) void {
            task.environment.deinit();
            task.root.deinit();
            task.store.deinit(allocator);
        }
    };
}

pub fn runAiReviewSelection(
    allocator: std.mem.Allocator,
    io: std.Io,
    configured_store: *const review_store.ConfiguredStore,
    repository: review_store.RepositoryContext,
    expected_store: review_store.StoreSnapshot,
    review_id: committed_review.ReviewId,
    expected_artifacts: review_store.ArtifactSnapshot,
    direct: bool,
) AiReviewSelectionTaskResult {
    var selected = (if (direct) review_store.selectExactReload(
        allocator,
        io,
        configured_store,
        repository,
        expected_store,
        review_id,
        expected_artifacts,
    ) else review_store.selectExact(
        allocator,
        io,
        configured_store,
        repository,
        expected_store,
        review_id,
        expected_artifacts,
    )) catch return .{ .failed_static = "Could not load AI review: out of memory" };
    defer selected.deinit(allocator);
    switch (selected) {
        .failure => |failure| return .{ .selection_failed = failure },
        .selected => |*read| {
            var diff: CommittedDiffBundle = if (read.projection.patch_bytes.len == 0)
                .empty
            else
                .{ .loaded = buildLoadedBundleWithIo(allocator, io, read.projection.patch_bytes) catch
                    return .{ .failed_static = "Could not parse AI review diff" } };
            errdefer diff.deinit();
            const owned_read = read.*;
            selected = .{ .failure = .run_invalid };
            return .{ .loaded = .{ .selection = owned_read, .diff = diff } };
        },
    }
}

pub fn ChangesProjectionTask(comptime Msg: type) type {
    return struct {
        request: changes_projection.Request,
        root: root_capability.RootCapability,
        environment: git_command.LocalGitEnvironment,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, runChangesProjectionLoad(task.request, task.root, &task.environment, allocator, io));
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, .{ .failed_static = actions.taskFailureMessage(failure) });
        }

        /// Spawn-failure counterpart of the terminal epilogue: releases the
        /// task-owned payload without producing a Msg.
        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            task.request.deinit(allocator);
            task.environment.deinit();
            task.root.deinit();
            allocator.destroy(task);
        }

        /// Terminal epilogue shared by run and failed; owned-field release,
        /// moves, and destroy live only here.
        fn finish(task: *@This(), allocator: std.mem.Allocator, result: changes_projection.TaskResult) Msg {
            defer allocator.destroy(task);
            defer task.environment.deinit();
            defer task.root.deinit();
            const request = task.request;
            task.request = undefined;
            return Msg.loadFinished(.{ .changes = .{ .projection = ChangesProjectionFinished{
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
        request: changes_projection.GeneratedSyntaxRequest,
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
            var result: changes_projection.GeneratedSyntaxResult = .{ .terminal_plain = .provider_unavailable };

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

            return Msg.loadFinished(.{ .changes = .{ .projection_syntax = .{
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
            return Msg.loadFinished(.{ .changes = .{ .projection_syntax = .{
                .request = request,
                .snapshot_fingerprint = null,
                .result = .{ .terminal_plain = .provider_unavailable },
            } } });
        }
    };
}

pub fn runStatusLoad(
    repo_root: []const u8,
    parent_environment: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    io: std.Io,
) StatusLoadTaskResult {
    var root = root_capability.RootCapability.openCanonical(repo_root) catch |err| return .{
        .failed = std.fmt.allocPrint(allocator, "Status load failed: {s}", .{@errorName(err)}) catch
            return .{ .failed_static = "Status load failed: OutOfMemory" },
    };
    defer root.deinit();
    var environment = git_command.LocalGitEnvironment.initFromParent(allocator, parent_environment) catch |err| return .{
        .failed = std.fmt.allocPrint(allocator, "Status load failed: {s}", .{@errorName(err)}) catch
            return .{ .failed_static = "Status load failed: OutOfMemory" },
    };
    defer environment.deinit();
    return runStatusLoadWithOrigin(repo_root, .{ .cwd = root.dir(), .environment = &environment }, .foreground, allocator, io);
}

pub fn runStatusLoadWithOrigin(
    _: []const u8,
    context: git_command.DirectoryContext,
    origin: git_read.ReadOrigin,
    allocator: std.mem.Allocator,
    io: std.Io,
) StatusLoadTaskResult {
    const raw_result = git_read.loadStatus(allocator, io, .{ .context = context, .origin = origin }) catch |err| {
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
            populateStatusLineStats(allocator, io, context, &bundle) catch {};
            return .{ .loaded = bundle };
        },
        .failed => |message| return .{ .failed = message },
        .failed_static => |message| return .{ .failed_static = message },
    }
}

pub fn runBranchStatusLoad(
    context: git_command.DirectoryContext,
    allocator: std.mem.Allocator,
    io: std.Io,
) BranchStatusLoadTaskResult {
    const raw_result = git_refs.loadBranchStatus(allocator, io, .{ .context = context }) catch |err| {
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

fn populateStatusLineStats(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    bundle: *git_status.StatusBundle,
) !void {
    var stats_map: StatusStatsMap = .empty;
    defer deinitStatusStatsMap(allocator, &stats_map);

    try collectTrackedStatusLineStats(allocator, io, context, bundle.document, &stats_map, .staged);
    try collectTrackedStatusLineStats(allocator, io, context, bundle.document, &stats_map, .unstaged);
    try collectUntrackedStatusLineStats(allocator, io, context.cwd, bundle.document, &stats_map);

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
    context: git_command.DirectoryContext,
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

    const result = git_read.loadTrackedNumstat(allocator, io, .{
        .context = context,
        .paths = paths.items,
        .staged = side == .staged,
    }) catch return;
    defer result.deinit(allocator);
    switch (result) {
        .ok => |bytes| try parseNumstatZIntoMap(allocator, bytes, stats_map),
        .unavailable => {},
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
    root: std.Io.Dir,
    document: git_status.StatusDocument,
    stats_map: *StatusStatsMap,
) !void {
    return collectUntrackedStatusLineStatsWithBudget(allocator, io, root, document, stats_map, .{
        .per_file_bytes = untracked_line_stats_per_file_bytes,
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
    root: std.Io.Dir,
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

        const content = readRepoFileLimited(allocator, io, root, key, budget.per_file_bytes) catch continue;
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

pub fn runBranchListLoad(
    context: git_command.DirectoryContext,
    allocator: std.mem.Allocator,
    io: std.Io,
) BranchListLoadTaskResult {
    const raw_result = git_refs.loadBranchList(allocator, io, .{
        .context = context,
        .scope = .local,
        .include_tip_committer_unix = true,
    }) catch |err| {
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

pub fn runCompareBranchListLoad(
    cwd: std.Io.Dir,
    env_map: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    io: std.Io,
) BranchListLoadTaskResult {
    var environment = git_command.LocalGitEnvironment.initFromParent(allocator, env_map) catch |err| {
        return .{
            .failed = std.fmt.allocPrint(allocator, "Review base list failed: {s}", .{@errorName(err)}) catch
                return .{ .failed_static = "Review base list failed: OutOfMemory" },
        };
    };
    defer environment.deinit();
    const raw_result = git_refs.loadBranchList(allocator, io, .{
        .context = .{ .cwd = cwd, .environment = &environment },
        .scope = .local_and_remote,
        .include_tip_committer_unix = true,
    }) catch |err| {
        return .{
            .failed = std.fmt.allocPrint(allocator, "Review base list failed: {s}", .{@errorName(err)}) catch
                return .{ .failed_static = "Review base list failed: OutOfMemory" },
        };
    };

    return switch (raw_result) {
        .ok => |list| .{ .loaded = list },
        .failed => |message| .{ .failed = message },
        .failed_static => |message| .{ .failed_static = message },
    };
}

/// Materialize the exact basis from one admitted History selection and parse
/// it through the shared committed-diff bundle boundary.
pub fn runHistoryDiffLoad(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    request: git_history.SelectionRequest,
) HistoryDiffTaskResult {
    if (!historySelectionRequestConsistent(request)) {
        return .{ .unavailable = .projection_git_command_failed };
    }

    var materialized = git_committed_review.materializeCommittedDiff(
        allocator,
        io,
        context,
        request.basis,
    ) catch return .{ .failed_static = "History diff could not be materialized: out of memory" };
    defer materialized.deinit(allocator);

    return switch (materialized) {
        .failure => |failure| .{ .unavailable = failure },
        .materialization => |*value| if (value.patch_bytes.len == 0)
            .{ .loaded = .empty }
        else
            .{ .loaded = .{ .loaded = buildLoadedBundleWithIo(
                allocator,
                io,
                value.patch_bytes,
            ) catch return .{ .failed_static = "History diff could not be parsed" } } },
    };
}

fn historySelectionRequestConsistent(request: git_history.SelectionRequest) bool {
    const format = request.basis.object_format;
    if (!request.snapshot_head.validFor(format) or !request.basis.after.validFor(format)) return false;
    const after = switch (request.intent) {
        .single => |single| blk: {
            if (!single.oid.validFor(format) or
                (single.index == 0 and !single.oid.eql(&request.snapshot_head))) return false;
            break :blk single.oid;
        },
        .range => |range| blk: {
            if (range.newest_index >= range.oldest_index or
                range.anchor_index < range.newest_index or range.anchor_index > range.oldest_index or
                range.cursor_index < range.newest_index or range.cursor_index > range.oldest_index or
                @min(range.anchor_index, range.cursor_index) != range.newest_index or
                @max(range.anchor_index, range.cursor_index) != range.oldest_index or
                !range.newest_oid.validFor(format) or !range.oldest_oid.validFor(format) or
                (range.newest_index == 0 and !range.newest_oid.eql(&request.snapshot_head)))
            {
                return false;
            }
            break :blk range.newest_oid;
        },
    };
    return after.eql(&request.basis.after);
}

test "History exact diff load covers normal root merge range and allow-empty from one catalog" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, null);
    defer environment.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, tmp.dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "root.txt", .data = "root\n" });
    try runTestGit(io, &.{ "git", "add", "." }, tmp.dir);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "root" }, tmp.dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "root.txt", .data = "root\nnormal\n" });
    try runTestGit(io, &.{ "git", "add", "." }, tmp.dir);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "normal" }, tmp.dir);
    try runTestGit(io, &.{ "git", "switch", "-c", "side" }, tmp.dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "side.txt", .data = "side\n" });
    try runTestGit(io, &.{ "git", "add", "." }, tmp.dir);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "side" }, tmp.dir);
    try runTestGit(io, &.{ "git", "switch", "main" }, tmp.dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "main.txt", .data = "main\n" });
    try runTestGit(io, &.{ "git", "add", "." }, tmp.dir);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "main" }, tmp.dir);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "merge", "--no-ff", "-m", "merge", "side" }, tmp.dir);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "empty" }, tmp.dir);

    const context: git_command.DirectoryContext = .{ .cwd = tmp.dir, .environment = &environment };
    var catalog_result = try git_history.loadInitial(allocator, io, context);
    defer catalog_result.deinit(allocator);
    const catalog = switch (catalog_result) {
        .loaded => |*loaded| loaded,
        .failure => return error.ExpectedHistoryCatalog,
    };
    try std.testing.expectEqual(@as(usize, 5), catalog.records.len);
    try std.testing.expectEqual(@as(u16, 2), catalog.records[1].parent_count);

    const cases = [_]struct {
        anchor: ?usize,
        cursor: usize,
        empty: bool,
    }{
        .{ .anchor = null, .cursor = 3, .empty = false }, // normal
        .{ .anchor = null, .cursor = 4, .empty = false }, // root
        .{ .anchor = null, .cursor = 1, .empty = false }, // merge parent 1
        .{ .anchor = 1, .cursor = 3, .empty = false }, // inclusive range
        .{ .anchor = null, .cursor = 0, .empty = true }, // allow-empty
    };
    for (cases) |case| {
        const request = git_history.resolveSelection(
            &catalog.snapshot.?,
            catalog.records,
            case.anchor,
            case.cursor,
        ).request;
        var result = runHistoryDiffLoad(allocator, io, context, request);
        defer result.deinit();
        switch (result) {
            .loaded => |bundle| switch (bundle) {
                .empty => try std.testing.expect(case.empty),
                .loaded => |loaded| {
                    try std.testing.expect(!case.empty);
                    try std.testing.expect(loaded.loaded.document.files.len > 0);
                },
            },
            else => return error.ExpectedHistoryDiff,
        }
    }
}

/// Resolve the Branch Review caller policy, then run the target, ahead, and
/// projection operations separately. Only a fully parsed candidate is
/// published as one accepted Review bundle.
pub fn runCompareLoad(
    cwd: std.Io.Dir,
    target: ?diff_basis.BaseTarget,
    environment: *const git_command.LocalGitEnvironment,
    allocator: std.mem.Allocator,
    io: std.Io,
) CompareLoadTaskResult {
    const context: git_command.DirectoryContext = .{ .cwd = cwd, .environment = environment };
    var selected = if (target) |value|
        git_compare.cloneTarget(allocator, .{
            .full_ref = value.full_ref,
            .display_name = value.display_name,
            .kind = value.kind,
        }) catch |err| return reviewLoadError(allocator, "Review base policy failed", err)
    else selected: {
        var policy = git_compare.selectDefaultTarget(allocator, io, context) catch |err|
            return reviewLoadError(allocator, "Review base policy failed", err);
        defer policy.deinit(allocator);
        break :selected switch (policy) {
            .target => |selected_target| value: {
                policy = .failed;
                break :value selected_target;
            },
            .missing => |attempted| {
                return translateReviewBasisFailure(allocator, .missing_base_ref, .{
                    .full_ref = attempted.full_ref,
                    .display_name = attempted.display_name,
                    .kind = attempted.kind,
                });
            },
            .failed => return .{ .failed_static = "Review base policy failed" },
        };
    };
    defer selected.deinit(allocator);

    var head_name = git_compare.readHeadName(allocator, io, context) catch |err|
        return reviewLoadError(allocator, "Review head display failed", err);
    defer head_name.deinit(allocator);
    if (head_name == .failed) return .{ .failed_static = "Review head display failed" };

    const target_result = git_committed_review.resolveTarget(allocator, io, context, .{
        .source_kind = .branch_range,
        .base = selected.full_ref,
        .head = "HEAD",
    }) catch |err| return reviewLoadError(allocator, "Review target resolution failed", err);
    const committed_target = switch (target_result) {
        .target => |resolved| resolved,
        .failure => |failure| return translateTargetResolutionFailure(allocator, failure, selected),
    };

    const ahead_result = git_committed_review.computeAheadDisplay(allocator, io, context, committed_target) catch |err|
        return reviewLoadError(allocator, "Review ahead display failed", err);
    const ahead_count_u64 = switch (ahead_result) {
        .count => |count| count,
        .failure => |failure| return reviewOperationFailure(allocator, "Review ahead display failed", @tagName(failure)),
    };
    const ahead_count = std.math.cast(usize, ahead_count_u64) orelse
        return .{ .failed_static = "Review ahead display returned an invalid count" };

    var projection_result = git_committed_review.materializeCommittedProjection(allocator, io, context, committed_target) catch |err|
        return reviewLoadError(allocator, "Review projection failed", err);
    defer projection_result.deinit(allocator);
    const patch = switch (projection_result) {
        .projection => |*projection| projection.patch_bytes,
        .failure => |failure| return reviewOperationFailure(allocator, "Review projection failed", @tagName(failure)),
    };

    var diff: CommittedDiffBundle = if (patch.len == 0)
        .empty
    else
        .{ .loaded = buildLoadedBundleWithIo(allocator, io, patch) catch |err| {
            return reviewLoadError(allocator, "Review diff parse failed", err);
        } };
    var diff_owned = true;
    defer if (diff_owned) diff.deinit();

    const full_ref = allocator.dupe(u8, selected.full_ref) catch
        return .{ .failed_static = "Review load failed: OutOfMemory" };
    var full_ref_owned = true;
    defer if (full_ref_owned) allocator.free(full_ref);
    const display_name = allocator.dupe(u8, selected.display_name) catch
        return .{ .failed_static = "Review load failed: OutOfMemory" };
    var display_name_owned = true;
    defer if (display_name_owned) allocator.free(display_name);
    const head_display = if (head_name.name) |name|
        allocator.dupe(u8, name) catch return .{ .failed_static = "Review load failed: OutOfMemory" }
    else
        std.fmt.allocPrint(allocator, "HEAD@{s}", .{committed_target.head_oid.short()}) catch
            return .{ .failed_static = "Review load failed: OutOfMemory" };
    var head_display_owned = true;
    defer if (head_display_owned) allocator.free(head_display);

    diff_owned = false;
    full_ref_owned = false;
    display_name_owned = false;
    head_display_owned = false;
    return .{ .loaded = .{
        .basis = .{
            .base = .{
                .full_ref = full_ref,
                .display_name = display_name,
                .kind = selected.kind,
            },
            .head_display = head_display,
            .target = committed_target,
            .ahead_count = ahead_count,
        },
        .diff = diff,
    } };
}

fn translateTargetResolutionFailure(
    allocator: std.mem.Allocator,
    failure: git_committed_review.TargetResolutionFailure,
    attempted: git_compare.CompareTarget,
) CompareLoadTaskResult {
    return switch (failure) {
        .base_unresolved => translateReviewBasisFailure(allocator, .missing_base_ref, attempted),
        .head_unresolved => translateReviewBasisFailure(allocator, .head_unresolved, attempted),
        .no_merge_base => translateReviewBasisFailure(allocator, .no_merge_base, attempted),
        else => reviewOperationFailure(allocator, "Review target resolution failed", @tagName(failure)),
    };
}

fn translateReviewBasisFailure(
    allocator: std.mem.Allocator,
    kind: diff_basis.BasisFailure,
    attempted: git_compare.CompareTarget,
) CompareLoadTaskResult {
    const full_ref = allocator.dupe(u8, attempted.full_ref) catch
        return .{ .failed_static = "Review load failed: OutOfMemory" };
    var full_ref_owned = true;
    defer if (full_ref_owned) allocator.free(full_ref);
    const display_name = allocator.dupe(u8, attempted.display_name) catch
        return .{ .failed_static = "Review load failed: OutOfMemory" };
    full_ref_owned = false;
    return .{ .basis_failed = .{
        .kind = kind,
        .attempted = .{
            .full_ref = full_ref,
            .display_name = display_name,
            .kind = attempted.kind,
        },
    } };
}

fn reviewOperationFailure(allocator: std.mem.Allocator, prefix: []const u8, code: []const u8) CompareLoadTaskResult {
    return .{
        .failed = std.fmt.allocPrint(allocator, "{s}: {s}", .{ prefix, code }) catch
            return .{ .failed_static = "Review load failed: OutOfMemory" },
    };
}

fn reviewLoadError(allocator: std.mem.Allocator, prefix: []const u8, err: anyerror) CompareLoadTaskResult {
    return .{
        .failed = std.fmt.allocPrint(allocator, "{s}: {s}", .{ prefix, @errorName(err) }) catch
            return .{ .failed_static = "Review load failed: OutOfMemory" },
    };
}

pub fn runLoad(
    request: LoadRequest,
    parent_environment: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    io: std.Io,
) DiffLoadTaskResult {
    return runLoadExpected(request, null, parent_environment, allocator, io);
}

pub fn runLoadExpected(
    request: LoadRequest,
    expected_fingerprint: ?content_fingerprint.Fingerprint,
    parent_environment: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    io: std.Io,
) DiffLoadTaskResult {
    var authority = initSynchronousLoadAuthority(request, parent_environment, allocator) catch |err| return .{
        .failed = std.fmt.allocPrint(allocator, "Diff load failed: {s}", .{@errorName(err)}) catch
            return .{ .failed_static = "Diff load failed: OutOfMemory" },
    };
    defer authority.deinit();
    return runLoadExpectedWithContext(request, authority.borrowed(), expected_fingerprint, allocator, io);
}

fn initSynchronousLoadAuthority(
    request: LoadRequest,
    parent_environment: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
) !LoadAuthority {
    return switch (request.source) {
        .unstaged, .cached, .range => blk: {
            const repo_root = request.repo_root orelse return error.MissingRepoRoot;
            var root = try root_capability.RootCapability.openCanonical(repo_root);
            errdefer root.deinit();
            break :blk .{ .repository = .{
                .root = root,
                .environment = try git_command.LocalGitEnvironment.initFromParent(allocator, parent_environment),
            } };
        },
        .no_index => LoadAuthority.initNonRepository(allocator, parent_environment),
        .stdin, .pager, .patch_file => .none,
    };
}

fn runLoadExpectedWithContext(
    request: LoadRequest,
    context: diff_source.LoadContext,
    expected_fingerprint: ?content_fingerprint.Fingerprint,
    allocator: std.mem.Allocator,
    io: std.Io,
) DiffLoadTaskResult {
    const raw_result = diff_source.load(allocator, io, request, context) catch |err| {
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

pub fn runChangesProjectionLoad(
    request: changes_projection.Request,
    root: root_capability.RootCapability,
    environment: ?*const git_command.LocalGitEnvironment,
    allocator: std.mem.Allocator,
    io: std.Io,
) changes_projection.TaskResult {
    return switch (request.kind) {
        .cached_diff => loadCachedFileDiff(request, root, environment orelse return .{ .failed_static = "Repository authority unavailable" }, allocator, io),
        .generated_added_file => loadGeneratedAddedFile(request, root, allocator, io),
        .combined_hunks => loadCombinedHunks(request, root, environment orelse return .{ .failed_static = "Repository authority unavailable" }, allocator, io),
    };
}

fn loadCachedFileDiff(
    request: changes_projection.Request,
    root: root_capability.RootCapability,
    environment: *const git_command.LocalGitEnvironment,
    allocator: std.mem.Allocator,
    io: std.Io,
) changes_projection.TaskResult {
    var component = loadFileProjectionComponent(request, root, environment, allocator, io, .cached) catch |err| {
        return .{ .failed = changes_projection.statusBodyAlloc(allocator, request.path_key, "Cached diff load failed: {s}", .{@errorName(err)}) catch
            return .{ .failed_static = "Cached diff load failed: OutOfMemory" } };
    } orelse {
        return .{ .ready = .{ .status_body = changes_projection.statusBodyAlloc(allocator, request.path_key, "No staged diff for this file.", .{}) catch
            return .{ .failed_static = "Projection allocation failed" } } };
    };
    defer component.deinit();
    return buildCachedFileTaskResult(request, allocator, io, &component);
}

/// Select a parse-only staged-only candidate only when the request names the
/// same canonical presentation. A miss promotes the already parsed component
/// into the established eager cached projection in this same completion.
fn buildCachedFileTaskResult(
    request: changes_projection.Request,
    allocator: std.mem.Allocator,
    io: std.Io,
    component: *projection_component.ParsedComponent,
) changes_projection.TaskResult {
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

                const candidate: changes_projection.StagedOnlyReuseCandidate = .{
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
) changes_projection.TaskResult {
    const bundle = decorateProjectionComponent(component, io) catch |err| {
        return .{ .failed = changes_projection.statusBodyAlloc(
            allocator,
            path_key,
            "Cached diff load failed: {s}",
            .{@errorName(err)},
        ) catch return .{ .failed_static = "Cached diff load failed: OutOfMemory" } };
    };
    return .{ .ready = .{ .cached_diff = bundle } };
}

fn loadFileProjectionComponent(
    request: changes_projection.Request,
    root: root_capability.RootCapability,
    environment: *const git_command.LocalGitEnvironment,
    allocator: std.mem.Allocator,
    io: std.Io,
    base: git_read.FileDiffBase,
) !?projection_component.ParsedComponent {
    const bytes = try loadFileDiffBytes(request, root, environment, allocator, io, base) orelse return null;
    defer allocator.free(bytes);
    return try projection_component.ParsedComponent.parse(allocator, bytes);
}

fn loadFileDiffBytes(
    request: changes_projection.Request,
    root: root_capability.RootCapability,
    environment: *const git_command.LocalGitEnvironment,
    allocator: std.mem.Allocator,
    io: std.Io,
    base: git_read.FileDiffBase,
) !?[]u8 {
    const raw_result = try git_read.loadDiff(allocator, io, .{
        .context = .{ .cwd = root.dir(), .environment = environment },
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

fn loadCombinedHunks(
    request: changes_projection.Request,
    root: root_capability.RootCapability,
    environment: *const git_command.LocalGitEnvironment,
    allocator: std.mem.Allocator,
    io: std.Io,
) changes_projection.TaskResult {
    var cached_component = loadFileProjectionComponent(request, root, environment, allocator, io, .cached) catch |err| {
        return .{ .failed = changes_projection.statusBodyAlloc(allocator, request.path_key, "Staged hunk projection load failed: {s}", .{@errorName(err)}) catch
            return .{ .failed_static = "Projection load failed: OutOfMemory" } };
    } orelse return .{ .ready = .{ .status_body = changes_projection.statusBodyAlloc(allocator, request.path_key, "No staged hunks for this file.", .{}) catch
        return .{ .failed_static = "Projection allocation failed" } } };
    defer cached_component.deinit();

    var unstaged_component = loadFileProjectionComponent(request, root, environment, allocator, io, .unstaged) catch |err| {
        return .{ .failed = changes_projection.statusBodyAlloc(allocator, request.path_key, "Unstaged hunk projection load failed: {s}", .{@errorName(err)}) catch
            return .{ .failed_static = "Projection load failed: OutOfMemory" } };
    } orelse return .{ .ready = .{ .status_body = changes_projection.statusBodyAlloc(allocator, request.path_key, "No unstaged hunks for this file.", .{}) catch
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
    request: changes_projection.Request,
    allocator: std.mem.Allocator,
    io: std.Io,
    cached_component: *projection_component.ParsedComponent,
    unstaged_component: *projection_component.ParsedComponent,
) changes_projection.TaskResult {
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
) changes_projection.TaskResult {
    if (cached_component.document.files.len != 1 or unstaged_component.document.files.len != 1) {
        return .{ .ready = .{ .status_body = changes_projection.statusBodyAlloc(allocator, path_key, "Cannot combine staged and unstaged hunks for this file.", .{}) catch
            return .{ .failed_static = "Projection allocation failed" } } };
    }

    const text_selectable = cached_component.fileTextSelectable(0) and unstaged_component.fileTextSelectable(0);
    if (!text_selectable) {
        var decorated = decorateProjectionComponents(cached_component, unstaged_component, io) catch |err| {
            return projectionDecorationFailureResult(allocator, path_key, err);
        };
        defer decorated.deinit();
        const bundle = changes_projection.InertCombinedBundle{
            .cached_bundle = decorated.cached,
            .unstaged_bundle = decorated.unstaged,
        };
        decorated.cached.arena = null;
        decorated.unstaged.arena = null;
        return .{ .ready = .{ .inert_combined = bundle } };
    }

    // The parsed inputs become fresh patch authority. Reparse their already
    // owned bytes for the eager presentation so its decorated component
    // storage can outlive replacement of that authority. This eager branch
    // deliberately keeps presentation and authority in one
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
            error.UnmappableCoordinate => changes_projection.statusBodyAlloc(
                allocator,
                path_key,
                "Cannot combine staged and unstaged hunks: line coordinates cannot be normalized safely.",
                .{},
            ),
            else => changes_projection.statusBodyAlloc(
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
    ) changes_projection.CombinedReuseCandidate {
        const candidate: changes_projection.CombinedReuseCandidate = .{
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
) diff_hunk_projection.BuildError!changes_projection.CombinedReuseCandidate {
    var prepared = try prepareCombinedReuse(allocator, cached_component, unstaged_component);
    errdefer prepared.deinit();
    return prepared.takeCandidate(status_snapshot_revision, cached_component, unstaged_component);
}

fn projectionDecorationFailureResult(
    allocator: std.mem.Allocator,
    path_key: []const u8,
    err: anyerror,
) changes_projection.TaskResult {
    const body = changes_projection.statusBodyAlloc(
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
) !changes_projection.CombinedHunkBundle {
    var presentation_arena = presentation_arena_owner;
    errdefer presentation_arena.deinit();
    var authority_arena = authority_arena_owner;
    errdefer authority_arena.deinit();
    var decorated = try decorateProjectionComponents(cached_presentation_component, unstaged_presentation_component, io);
    errdefer decorated.deinit();

    const bundle = changes_projection.CombinedHunkBundle{
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
    request: changes_projection.Request,
    root: ?root_capability.RootCapability,
    allocator: std.mem.Allocator,
    io: std.Io,
) changes_projection.TaskResult {
    const capability = root orelse return .{ .failed_static = "Repository root is unavailable" };
    if (!request.matchesRootIdentity(capability.identity)) return .{ .failed_static = "Repository root changed" };

    var snapshot = selected_document.load(capability, request.path_key, allocator, io);
    defer snapshot.deinit(allocator);
    switch (snapshot.value) {
        .text => |text| {
            const bytes = text.bytes;
            const fingerprint = text.fingerprint;
            snapshot.value = .unreadable;
            const bundle = changes_projection.generatedFileFromOwnedContent(
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
        .oversized => return generatedStatusBody(allocator, request.path_key, generated_oversized_message),
        .symlink => return generatedStatusBody(allocator, request.path_key, "Symbolic link content is not shown."),
        .directory_or_gitlink => return generatedStatusBody(allocator, request.path_key, "Directory content is not shown."),
        .named_pipe, .unix_socket, .block_device, .character_device, .unknown_special => return generatedStatusBody(allocator, request.path_key, "Special file content is not shown."),
        .missing_or_changed => return generatedStatusBody(allocator, request.path_key, "File changed while loading."),
        .unreadable => return generatedStatusBody(allocator, request.path_key, "File content could not be read."),
        .unsupported_platform => return generatedStatusBody(allocator, request.path_key, "Safe file preview is unavailable on this platform."),
    }
}

fn generatedStatusBody(allocator: std.mem.Allocator, path: []const u8, message: []const u8) changes_projection.TaskResult {
    return .{ .ready = .{ .status_body = changes_projection.statusBodyAlloc(allocator, path, "{s}", .{message}) catch
        return .{ .failed_static = "Projection allocation failed" } } };
}

/// Best-effort untracked line-count read rooted at the task-owned repository
/// descriptor. Changes preview bytes use `repository/document.zig` instead.
fn readRepoFileLimited(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir, path_key: []const u8, limit: usize) ![]u8 {
    try validateRepoRelativePath(path_key);

    var current_dir = root;
    var current_dir_owned = false;
    defer if (current_dir_owned) current_dir.close(io);

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
        if (current_dir_owned) current_dir.close(io);
        current_dir = child_dir;
        current_dir_owned = true;
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
/// decorated bundle used by the current Changes renderer. Failure leaves the
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
/// order so load paths cannot silently diverge in syntax, tree, or rendered-row state.
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
    expected_presentation: ?changes_projection.ExpectedPresentation,
) !changes_projection.Request {
    return changes_projection.cloneRequestWithOptions(
        allocator,
        page.RequestIdentity.changes(0, 1),
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
    expected_presentation: ?changes_projection.ExpectedPresentation,
) !changes_projection.Request {
    return changes_projection.cloneRequestWithOptions(
        allocator,
        page.RequestIdentity.changes(0, 1),
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
    try std.testing.expect(!@hasField(changes_projection.CombinedReuseCandidate, "syntax_spans"));
    try std.testing.expect(!@hasField(changes_projection.CombinedReuseCandidate, "cached_bundle"));
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
    try std.testing.expect(!@hasField(changes_projection.CombinedReuseCandidate, "cached_bundle"));
    try std.testing.expect(!@hasField(changes_projection.CombinedReuseCandidate, "unstaged_bundle"));
    try std.testing.expect(!@hasField(changes_projection.CombinedReuseCandidate, "syntax_spans"));

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
        null,
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

    const content = try readRepoFileLimited(std.testing.allocator, io, tmp.dir, "inside.txt", untracked_line_stats_per_file_bytes);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("inside", content);

    try std.testing.expectError(error.InvalidPath, readRepoFileLimited(std.testing.allocator, io, tmp.dir, "linked.txt", untracked_line_stats_per_file_bytes));
    try std.testing.expectError(error.InvalidPath, readRepoFileLimited(std.testing.allocator, io, tmp.dir, "linked-dir/inside.txt", untracked_line_stats_per_file_bytes));
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
    var request = try changes_projection.testing.cloneRequestWithRootIdentity(
        allocator,
        page.RequestIdentity.changes(1, 2),
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

    var result = runChangesProjectionLoad(request, root, null, allocator, io);
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

test "text limit contract generated projection shared loader" {
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
    var request = try changes_projection.testing.cloneRequestWithRootIdentity(
        allocator,
        page.RequestIdentity.changes(1, 2),
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

    var unsafe = runChangesProjectionLoad(request, first_root, null, allocator, io);
    defer unsafe.deinit(allocator);
    try std.testing.expect(switch (unsafe) {
        .ready => |ready| ready == .status_body,
        else => false,
    });

    var wrong_root = runChangesProjectionLoad(request, second_root, null, allocator, io);
    defer wrong_root.deinit(allocator);
    try std.testing.expect(switch (wrong_root) {
        .failed_static => |message| std.mem.eql(u8, message, "Repository root changed"),
        else => false,
    });

    const boundary_bytes = try allocator.alloc(u8, selected_document.max_text_bytes);
    defer allocator.free(boundary_bytes);
    @memset(boundary_bytes, 'x');
    try first.dir.writeFile(io, .{ .sub_path = "boundary.zig", .data = boundary_bytes });
    var boundary_request = try changes_projection.testing.cloneRequestWithRootIdentity(
        allocator,
        page.RequestIdentity.changes(1, 2),
        4,
        first_path,
        "boundary.zig",
        .generated_added_file,
        .unstaged,
        4,
        5,
        first_root.identity,
    );
    defer boundary_request.deinit(allocator);
    var boundary = runChangesProjectionLoad(boundary_request, first_root, null, allocator, io);
    defer boundary.deinit(allocator);
    switch (boundary) {
        .ready => |ready| switch (ready) {
            .generated_added_file => |bundle| {
                try std.testing.expectEqual(selected_document.max_text_bytes, bundle.source.bytes.len);
                try std.testing.expectEqualSlices(u8, boundary_bytes, bundle.source.bytes);
            },
            else => return error.ExpectedGeneratedPreview,
        },
        else => return error.ExpectedGeneratedPreview,
    }

    const oversized_bytes = try allocator.alloc(u8, selected_document.max_text_bytes + 1);
    defer allocator.free(oversized_bytes);
    @memset(oversized_bytes, 'x');
    try first.dir.writeFile(io, .{ .sub_path = "oversized.zig", .data = oversized_bytes });
    var oversized_request = try changes_projection.testing.cloneRequestWithRootIdentity(
        allocator,
        page.RequestIdentity.changes(1, 2),
        5,
        first_path,
        "oversized.zig",
        .generated_added_file,
        .unstaged,
        4,
        5,
        first_root.identity,
    );
    defer oversized_request.deinit(allocator);
    var oversized = runChangesProjectionLoad(oversized_request, first_root, null, allocator, io);
    defer oversized.deinit(allocator);
    switch (oversized) {
        .ready => |ready| switch (ready) {
            .status_body => |body| try std.testing.expectEqualStrings(generated_oversized_message, body.message),
            else => return error.ExpectedOversizedPreview,
        },
        else => return error.ExpectedOversizedPreview,
    }
}

test "text limit contract changes generated oversized diagnostic" {
    try std.testing.expectEqualStrings("File exceeds the 2 MiB preview limit.", generated_oversized_message);
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
    const oversized = try std.testing.allocator.alloc(u8, untracked_line_stats_per_file_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    try tmp.dir.writeFile(io, .{ .sub_path = "oversized.txt", .data = oversized });
    const entries = [_]git_status.StatusEntry{
        .{ .path = "one.txt", .raw = .{ '?', '?' }, .index = .unmodified, .worktree = .untracked },
        .{ .path = "two.txt", .raw = .{ '?', '?' }, .index = .unmodified, .worktree = .untracked },
        .{ .path = "binary.dat", .raw = .{ '?', '?' }, .index = .unmodified, .worktree = .untracked },
        .{ .path = "oversized.txt", .raw = .{ '?', '?' }, .index = .unmodified, .worktree = .untracked },
    };
    const document: git_status.StatusDocument = .{ .entries = &entries };
    var stats_map: StatusStatsMap = .empty;
    defer deinitStatusStatsMap(std.testing.allocator, &stats_map);

    try collectUntrackedStatusLineStats(std.testing.allocator, io, tmp.dir, document, &stats_map);

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

    try collectUntrackedStatusLineStatsWithBudget(std.testing.allocator, io, tmp.dir, document, &stats_map, .{
        .per_file_bytes = untracked_line_stats_per_file_bytes,
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

    var result = runStatusLoad(repo_root, null, std.testing.allocator, io);
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

    var result = runStatusLoad(repo_root, null, std.testing.allocator, io);
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

    var result = runStatusLoad(repo_root, null, std.testing.allocator, io);
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

test "runCompareLoad returns an atomic validated basis and diff bundle" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, null);
    defer environment.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, tmp.dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "base.txt", .data = "base\n" });
    try runTestGit(io, &.{ "git", "add", "base.txt" }, tmp.dir);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" }, tmp.dir);
    try runTestGit(io, &.{ "git", "switch", "-c", "feature/compare" }, tmp.dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "feature.txt", .data = "feature\n" });
    try runTestGit(io, &.{ "git", "add", "feature.txt" }, tmp.dir);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "feature" }, tmp.dir);

    var result = runCompareLoad(tmp.dir, .{
        .full_ref = @constCast("refs/heads/main"),
        .display_name = @constCast("main"),
        .kind = .local,
    }, &environment, allocator, io);
    defer result.deinit(allocator);
    switch (result) {
        .loaded => |bundle| {
            try std.testing.expectEqualStrings("refs/heads/main", bundle.basis.base.full_ref);
            try std.testing.expectEqualStrings("feature/compare", bundle.basis.head_display);
            try std.testing.expectEqual(@as(usize, 1), bundle.basis.ahead_count);
            try std.testing.expect(bundle.diff == .loaded);
        },
        else => return error.ExpectedCompareLoad,
    }
}

test "runCompareLoad clean committed projection preserves text binary add delete and rename model" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, null);
    defer environment.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, tmp.dir);
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitattributes", .data = "*.bin -diff\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "text.txt", .data = "old text\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "binary.bin", .data = "old\x00binary" });
    try tmp.dir.writeFile(io, .{ .sub_path = "delete.txt", .data = "delete me\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "rename-old.txt", .data = "rename unchanged\n" });
    try runTestGit(io, &.{ "git", "add", "." }, tmp.dir);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" }, tmp.dir);
    try runTestGit(io, &.{ "git", "switch", "-c", "feature/model" }, tmp.dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "text.txt", .data = "new text\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "binary.bin", .data = "new\x00binary" });
    try tmp.dir.writeFile(io, .{ .sub_path = "add.txt", .data = "added\n" });
    try runTestGit(io, &.{ "git", "rm", "delete.txt" }, tmp.dir);
    try runTestGit(io, &.{ "git", "mv", "rename-old.txt", "rename-new.txt" }, tmp.dir);
    try runTestGit(io, &.{ "git", "add", "." }, tmp.dir);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "head" }, tmp.dir);

    var result = runCompareLoad(tmp.dir, .{
        .full_ref = @constCast("refs/heads/main"),
        .display_name = @constCast("main"),
        .kind = .local,
    }, &environment, allocator, io);
    defer result.deinit(allocator);
    const loaded = switch (result) {
        .loaded => |*bundle| switch (bundle.diff) {
            .loaded => |*diff| diff,
            .empty => return error.ExpectedCompareDiff,
        },
        else => return error.ExpectedCompareLoad,
    };

    var statuses = [_]bool{false} ** 5;
    for (loaded.loaded.document.files) |file| switch (diff_file.status(file)) {
        .modified => statuses[0] = true,
        .binary => statuses[1] = true,
        .added => statuses[2] = true,
        .deleted => statuses[3] = true,
        .renamed => statuses[4] = true,
    };
    for (statuses) |present| try std.testing.expect(present);

    const target = result.loaded.basis.target;
    const legacy_range = try std.fmt.allocPrint(allocator, "{s}..{s}", .{
        target.diff_base_oid.slice(),
        target.head_oid.slice(),
    });
    defer allocator.free(legacy_range);
    const legacy_argv = [_][]const u8{
        "git", "diff", "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/", legacy_range,
    };
    const legacy_result = try git_command.runCaptured(allocator, io, .{ .cwd = tmp.dir, .environment = &environment }, .{
        .argv = &legacy_argv,
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });
    defer legacy_result.deinit(allocator);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, legacy_result.term);
    var legacy = try buildLoadedBundle(allocator, legacy_result.stdout);
    defer legacy.deinit();
    try std.testing.expectEqual(legacy.loaded.document.files.len, loaded.loaded.document.files.len);
    for (legacy.loaded.document.files, loaded.loaded.document.files) |old_file, new_file| {
        try std.testing.expect(diff_presentation_identity.exactEqual(old_file, new_file));
    }

    try runTestGit(io, &.{ "git", "config", "diff.algorithm", "definitely-invalid" }, tmp.dir);
    var failed = runCompareLoad(tmp.dir, .{
        .full_ref = @constCast("refs/heads/main"),
        .display_name = @constCast("main"),
        .kind = .local,
    }, &environment, allocator, io);
    defer failed.deinit(allocator);
    switch (failed) {
        .failed => |message| try std.testing.expect(std.mem.startsWith(u8, message, "Review projection failed: projection_git_command_failed")),
        else => return error.ExpectedProjectionFailure,
    }
}

test "runCompareLoad treats empty diff as success and labels detached head" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, null);
    defer environment.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, tmp.dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "base.txt", .data = "base\n" });
    try runTestGit(io, &.{ "git", "add", "base.txt" }, tmp.dir);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" }, tmp.dir);
    try runTestGit(io, &.{ "git", "switch", "--detach", "HEAD" }, tmp.dir);

    var result = runCompareLoad(tmp.dir, null, &environment, allocator, io);
    defer result.deinit(allocator);
    switch (result) {
        .loaded => |bundle| {
            try std.testing.expect(std.mem.startsWith(u8, bundle.basis.head_display, "HEAD@"));
            try std.testing.expectEqual(@as(usize, 0), bundle.basis.ahead_count);
            try std.testing.expect(bundle.diff == .empty);
        },
        else => return error.ExpectedEmptyReviewLoad,
    }
}

test "CompareLoadTask owns cloned target and routes failed terminal to Compare" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const TestMsg = union(enum) {
        load: ReadFinished,

        pub fn loadFinished(msg: ReadFinished) @This() {
            return .{ .load = msg };
        }
    };
    const Task = CompareLoadTask(TestMsg);
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root_path);
    var root = try root_capability.RootCapability.openCanonical(root_path);
    defer root.deinit();
    var target: diff_basis.BaseTarget = .{
        .full_ref = try allocator.dupe(u8, "refs/heads/main"),
        .display_name = try allocator.dupe(u8, "main"),
        .kind = .local,
    };
    defer target.deinit(allocator);

    const task = try allocator.create(Task);
    task.* = try Task.init(page.RequestIdentity.compare(9, 4), 17, root, target, null, allocator);
    try std.testing.expect(task.target.?.full_ref.ptr != target.full_ref.ptr);
    const message = Task.failed(task, .{ .start_failed = "SystemResources" }, allocator);
    var finished = switch (message.load) {
        .compare => |compare| switch (compare) {
            .source => |payload| payload,
            else => return error.UnexpectedReadRoute,
        },
        else => return error.UnexpectedReadRoute,
    };
    defer finished.deinit(allocator);
    try std.testing.expectEqual(page.RequestIdentity.compare(9, 4), finished.identity);
    try std.testing.expectEqual(@as(u64, 17), finished.generation);
    try std.testing.expectEqualStrings("SystemResources", switch (finished.result) {
        .failed_static => |value| value,
        else => return error.UnexpectedResult,
    });
}

test "CompareLoadTask destroy releases cloned spawn payload" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const TestMsg = union(enum) {
        load: ReadFinished,

        pub fn loadFinished(msg: ReadFinished) @This() {
            return .{ .load = msg };
        }
    };
    const Task = CompareLoadTask(TestMsg);
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root_path);
    var root = try root_capability.RootCapability.openCanonical(root_path);
    defer root.deinit();
    var target: diff_basis.BaseTarget = .{
        .full_ref = try allocator.dupe(u8, "refs/heads/main"),
        .display_name = try allocator.dupe(u8, "main"),
        .kind = .local,
    };
    defer target.deinit(allocator);

    const task = try allocator.create(Task);
    task.* = try Task.init(page.RequestIdentity.compare(1, 1), 1, root, target, null, allocator);
    Task.destroy(task, allocator);
}

test "CompareBranchListLoadTask routes its terminal and destroy closes descriptor ownership" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const TestMsg = union(enum) {
        load: ReadFinished,

        pub fn loadFinished(msg: ReadFinished) @This() {
            return .{ .load = msg };
        }
    };
    const Task = CompareBranchListLoadTask(TestMsg);
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root_path);
    var root = try root_capability.RootCapability.openCanonical(root_path);
    defer root.deinit();

    const terminal_task = try allocator.create(Task);
    terminal_task.* = try Task.init(page.RequestIdentity.compare(7, 8), 9, root, null);
    const message = Task.failed(terminal_task, .{ .start_failed = "SystemResources" }, allocator);
    var finished = switch (message.load) {
        .compare => |compare| switch (compare) {
            .branch_list => |payload| payload,
            else => return error.UnexpectedReadRoute,
        },
        else => return error.UnexpectedReadRoute,
    };
    defer finished.deinit(allocator);
    try std.testing.expectEqual(page.RequestIdentity.compare(7, 8), finished.identity);
    try std.testing.expectEqual(@as(u64, 9), finished.generation);
    try std.testing.expectEqualStrings("SystemResources", switch (finished.result) {
        .failed_static => |value| value,
        else => return error.UnexpectedResult,
    });

    const destroyed_task = try allocator.create(Task);
    destroyed_task.* = try Task.init(page.RequestIdentity.compare(1, 2), 3, root, null);
    Task.destroy(destroyed_task, allocator);
}

test "CompareBranchListLoadTask keeps physical root and controlled environment after path replacement" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const TestMsg = union(enum) {
        load: ReadFinished,

        pub fn loadFinished(msg: ReadFinished) @This() {
            return .{ .load = msg };
        }
    };
    const Task = CompareBranchListLoadTask(TestMsg);
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "repo", .default_dir);
    var repo = try tmp.dir.openDir(io, "repo", .{});
    defer repo.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=pinned" }, repo);
    try repo.writeFile(io, .{ .sub_path = "base.txt", .data = "base\n" });
    try runTestGit(io, &.{ "git", "add", "base.txt" }, repo);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" }, repo);
    const root_path = try repo.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root_path);
    var root = try root_capability.RootCapability.openCanonical(root_path);
    defer root.deinit();
    var injected_env = std.process.Environ.Map.init(allocator);
    defer injected_env.deinit();
    try injected_env.put("GIT_DIR", "/definitely/not/the/pinned/repository");

    const task = try allocator.create(Task);
    task.* = try Task.init(page.RequestIdentity.compare(2, 3), 4, root, &injected_env);
    try tmp.dir.rename("repo", tmp.dir, "pinned-repo", io);
    try tmp.dir.createDir(io, "repo", .default_dir);
    var replacement = try tmp.dir.openDir(io, "repo", .{});
    defer replacement.close(io);
    try replacement.writeFile(io, .{ .sub_path = ".git", .data = "invalid replacement gitfile\n" });

    const message = Task.run(task, allocator, io);
    var finished = switch (message.load) {
        .compare => |compare| switch (compare) {
            .branch_list => |payload| payload,
            else => return error.UnexpectedReadRoute,
        },
        else => return error.UnexpectedReadRoute,
    };
    defer finished.deinit(allocator);
    const list = switch (finished.result) {
        .loaded => |value| value,
        else => return error.ExpectedBranchList,
    };
    var found_pinned = false;
    for (list.branches) |branch| {
        if (std.mem.eql(u8, branch.full_ref, "refs/heads/pinned")) {
            found_pinned = true;
            try std.testing.expect(branch.tip_committer_unix != null);
        }
    }
    try std.testing.expect(found_pinned);
}

test "Compare task translation keeps basis failure kinds and attempted target" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        kind: diff_basis.BasisFailure,
    }{
        .{ .kind = .missing_base_ref },
        .{ .kind = .no_merge_base },
        .{ .kind = .head_unresolved },
    };
    for (cases) |case| {
        var result = translateReviewBasisFailure(allocator, case.kind, .{
            .full_ref = @constCast("refs/heads/base"),
            .display_name = @constCast("base"),
            .kind = .local,
        });
        defer result.deinit(allocator);
        switch (result) {
            .basis_failed => |failure| {
                try std.testing.expectEqual(case.kind, failure.kind);
                try std.testing.expectEqualStrings("refs/heads/base", failure.attempted.full_ref);
            },
            else => return error.ExpectedBasisFailure,
        }
    }
}

test "runCompareLoad separates process failure from basis failure" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, null);
    defer environment.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".git", .data = "invalid gitfile\n" });
    var result = runCompareLoad(tmp.dir, .{
        .full_ref = @constCast("refs/heads/main"),
        .display_name = @constCast("main"),
        .kind = .local,
    }, &environment, allocator, io);
    defer result.deinit(allocator);
    try std.testing.expect(result == .failed or result == .failed_static);
}

test "CompareLoadTask duplicate retains physical root after path replacement" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const TestMsg = union(enum) {
        load: ReadFinished,

        pub fn loadFinished(msg: ReadFinished) @This() {
            return .{ .load = msg };
        }
    };
    const Task = CompareLoadTask(TestMsg);
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "repo", .default_dir);
    var repo = try tmp.dir.openDir(io, "repo", .{});
    defer repo.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, repo);
    try repo.writeFile(io, .{ .sub_path = "base.txt", .data = "base\n" });
    try runTestGit(io, &.{ "git", "add", "base.txt" }, repo);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" }, repo);
    try runTestGit(io, &.{ "git", "switch", "-c", "feature" }, repo);
    try repo.writeFile(io, .{ .sub_path = "feature.txt", .data = "feature\n" });
    try runTestGit(io, &.{ "git", "add", "feature.txt" }, repo);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "feature" }, repo);
    const root_path = try repo.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root_path);
    var root = try root_capability.RootCapability.openCanonical(root_path);
    defer root.deinit();
    var parent_env = std.process.Environ.Map.init(allocator);
    defer parent_env.deinit();
    try parent_env.put("UTSUWA_REVIEW_CANARY", "queue-time");
    try parent_env.put("GIT_DIR", "/definitely/not/the/pinned/repository");

    const task = try allocator.create(Task);
    task.* = try Task.init(page.RequestIdentity.compare(2, 3), 1, root, null, &parent_env, allocator);
    try std.testing.expectEqualStrings("queue-time", task.environment.map.get("UTSUWA_REVIEW_CANARY").?);
    try std.testing.expect(task.environment.map.get("GIT_DIR") == null);
    try std.testing.expect(parent_env.get("GIT_DIR") != null);
    try parent_env.put("UTSUWA_REVIEW_CANARY", "mutated-after-queue");
    try std.testing.expectEqualStrings("queue-time", task.environment.map.get("UTSUWA_REVIEW_CANARY").?);
    try tmp.dir.rename("repo", tmp.dir, "pinned-repo", io);
    try tmp.dir.createDir(io, "repo", .default_dir);
    var replacement = try tmp.dir.openDir(io, "repo", .{});
    defer replacement.close(io);
    try replacement.writeFile(io, .{ .sub_path = ".git", .data = "invalid replacement gitfile\n" });

    const message = Task.run(task, allocator, io);
    var finished = switch (message.load) {
        .compare => |compare| switch (compare) {
            .source => |payload| payload,
            else => return error.UnexpectedReadRoute,
        },
        else => return error.UnexpectedReadRoute,
    };
    defer finished.deinit(allocator);
    try std.testing.expect(finished.result == .loaded);
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

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root_path);

    const task = try allocator.create(Task);
    task.* = .{
        .identity = page.RequestIdentity.changes(7, 11),
        .read_epoch = .{ .value = 19 },
        .repo_root = try allocator.dupe(u8, "/repo"),
        .root = try root_capability.RootCapability.openCanonical(root_path),
        .environment = try git_command.LocalGitEnvironment.initFromParent(allocator, null),
        .generation = 42,
    };

    const msg = Task.failed(task, .{ .start_failed = "SystemResources" }, allocator);
    var finished = switch (msg) {
        .load => |load| switch (load) {
            .changes => |changes| switch (changes) {
                .status => |payload| payload,
                else => return error.UnexpectedReadRoute,
            },
            else => return error.UnexpectedReadRoute,
        },
    };
    defer finished.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 42), finished.generation);
    try std.testing.expectEqual(page.RequestIdentity.changes(7, 11), finished.identity);
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

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root_path);
    var authority: LoadAuthority = blk: {
        var owned_root = try root_capability.RootCapability.openCanonical(root_path);
        errdefer owned_root.deinit();
        break :blk .{ .repository = .{
            .root = owned_root,
            .environment = try git_command.LocalGitEnvironment.initFromParent(allocator, null),
        } };
    };
    errdefer authority.deinit();

    const task = try allocator.create(Task);
    task.* = .{
        .identity = page.RequestIdentity.changes(3, 5),
        .read_epoch = .{ .value = 23 },
        .request = .{
            .source = .{ .range = try allocator.dupe(u8, "HEAD~1..HEAD") },
            .repo_root = try allocator.dupe(u8, "/repo"),
        },
        .authority = authority,
        .generation = 9,
    };
    authority = .none;

    const msg = Task.failed(task, .{ .start_failed = "OutOfMemory" }, allocator);
    var finished = switch (msg) {
        .load => |load| switch (load) {
            .changes => |changes| switch (changes) {
                .source => |payload| payload,
                else => return error.UnexpectedReadRoute,
            },
            else => return error.UnexpectedReadRoute,
        },
    };
    defer finished.result.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 9), finished.generation);
    try std.testing.expectEqual(page.RequestIdentity.changes(3, 5), finished.identity);
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
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root_path);
    var root = try root_capability.RootCapability.openCanonical(root_path);
    var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, null);

    const task = try allocator.create(Task);
    task.* = .{
        .identity = page.RequestIdentity.changes(5, 13),
        .read_epoch = .{ .value = 29 },
        .repo_root = try allocator.dupe(u8, "/repo"),
        .root = root,
        .environment = environment,
        .generation = 47,
    };
    root = undefined;
    environment = undefined;
    const root_observer = task.root;

    const msg = Task.failed(task, .{ .start_failed = "SystemResources" }, allocator);
    var finished = switch (msg) {
        .load => |load| switch (load) {
            .changes => |changes| switch (changes) {
                .branch_status => |payload| payload,
                else => return error.UnexpectedReadRoute,
            },
            else => return error.UnexpectedReadRoute,
        },
    };
    defer finished.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 47), finished.generation);
    try std.testing.expectEqual(page.RequestIdentity.changes(5, 13), finished.identity);
    try std.testing.expect(finished.read_epoch.eql(.{ .value = 29 }));
    try std.testing.expectEqualStrings("/repo", finished.repo_root);
    try std.testing.expectEqualStrings("SystemResources", switch (finished.result) {
        .failed_static => |message| message,
        else => return error.UnexpectedResult,
    });
    if (root_observer.duplicate()) |unexpected_value| {
        var unexpected = unexpected_value;
        unexpected.deinit();
        return error.ExpectedClosedRootCapability;
    } else |err| try std.testing.expectEqual(error.InvalidRootCapability, err);
}

test "ChangesProjectionTask failed preserves request identity and read epoch" {
    const TestLoadMsg = ReadFinished;
    const TestMsg = union(enum) {
        load: TestLoadMsg,

        pub fn loadFinished(msg: TestLoadMsg) @This() {
            return .{ .load = msg };
        }
    };
    const Task = ChangesProjectionTask(TestMsg);
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root_path);

    const task = try allocator.create(Task);
    task.* = .{
        .request = .{
            .identity = page.RequestIdentity.changes(0, 1),
            .id = 11,
            .read_epoch = .{ .value = 53 },
            .repo_root = try allocator.dupe(u8, "/repo"),
            .path_key = try allocator.dupe(u8, "src/main.zig"),
            .kind = .cached_diff,
            .source_kind = .unstaged,
            .source_session_revision = 2,
            .status_snapshot_revision = 3,
        },
        .root = try root_capability.RootCapability.openCanonical(root_path),
        .environment = try git_command.LocalGitEnvironment.initFromParent(allocator, null),
    };

    const msg = Task.failed(task, .{ .start_failed = "OutOfMemory" }, allocator);
    var finished = switch (msg) {
        .load => |load| switch (load) {
            .changes => |changes| switch (changes) {
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
            .identity = page.RequestIdentity.changes(2, 3),
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
            .changes => |changes| switch (changes) {
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
