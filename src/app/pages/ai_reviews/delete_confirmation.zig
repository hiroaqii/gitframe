//! Page-owned confirmation and task fence for deleting one exact Review Run.

const std = @import("std");
const chasen = @import("chasen");
const actions = @import("../../actions.zig");
const page = @import("../../page.zig");
const committed_review = @import("../../../committed_review.zig");
const git_command = @import("../../../git/command.zig");
const root_capability = @import("../../../repo/root_capability.zig");
const review_store = @import("../../../review_store.zig");

pub const Summary = struct {
    request: review_store.DeleteRequest,
    target: committed_review.CommittedReviewTarget,
    status: review_store.RunSummaryStatus,
    created_at_unix: i64,
    producer_name: []u8,
    producer_model: ?[]u8,
    base_label: ?[]u8,
    head_label: ?[]u8,
    finding_count: u32,
    fallback_review_id: ?committed_review.ReviewId,

    pub fn init(
        allocator: std.mem.Allocator,
        store: review_store.StoreSnapshot,
        row: *const review_store.RunSummary,
        fallback_review_id: ?committed_review.ReviewId,
    ) !Summary {
        const producer_name = try allocator.dupe(u8, row.producer_name);
        errdefer allocator.free(producer_name);
        const producer_model = if (row.producer_model) |value| try allocator.dupe(u8, value) else null;
        errdefer if (producer_model) |value| allocator.free(value);
        const base_label = if (row.base_label) |value| try allocator.dupe(u8, value) else null;
        errdefer if (base_label) |value| allocator.free(value);
        const head_label = if (row.head_label) |value| try allocator.dupe(u8, value) else null;
        errdefer if (head_label) |value| allocator.free(value);
        return .{
            .request = .{
                .store = store,
                .review_id = row.review_id,
                .artifacts = row.artifact_snapshot,
                .allow_unfinished = true,
            },
            .target = row.target,
            .status = row.status,
            .created_at_unix = row.created_at_unix,
            .producer_name = producer_name,
            .producer_model = producer_model,
            .base_label = base_label,
            .head_label = head_label,
            .finding_count = row.finding_count,
            .fallback_review_id = fallback_review_id,
        };
    }

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        if (self.head_label) |value| allocator.free(value);
        if (self.base_label) |value| allocator.free(value);
        if (self.producer_model) |value| allocator.free(value);
        allocator.free(self.producer_name);
        self.* = undefined;
    }

    pub fn unfinished(self: *const Summary) bool {
        return self.status == .new or self.status == .draft;
    }
};

const Deleting = struct {
    summary: Summary,
    identity: page.RequestIdentity,
    generation: u64,
    root_identity: root_capability.Identity,
    store_identity: review_store.ConfigurationIdentity,
};

pub const Phase = union(enum) {
    closed,
    confirming: Summary,
    deleting: Deleting,
};

pub const Request = struct {
    identity: page.RequestIdentity,
    generation: u64,
    request: review_store.DeleteRequest,
};

pub const FinishedResult = union(enum) {
    result: review_store.DeleteResult,
    failed_static: []const u8,
};

pub const Finished = struct {
    identity: page.RequestIdentity,
    generation: u64,
    root_identity: root_capability.Identity,
    store_identity: review_store.ConfigurationIdentity,
    review_id: committed_review.ReviewId,
    result: FinishedResult,

    pub fn deinit(self: *Finished, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.* = undefined;
    }
};

pub const Accepted = struct {
    review_id: committed_review.ReviewId,
    fallback_review_id: ?committed_review.ReviewId,
    result: FinishedResult,
};

pub const State = struct {
    phase: Phase = .closed,
    next_generation: u64 = 0,

    pub fn isOpen(self: *const State) bool {
        return self.phase != .closed;
    }

    pub fn isDeleting(self: *const State) bool {
        return self.phase == .deleting;
    }

    pub fn summary(self: *const State) ?*const Summary {
        return switch (self.phase) {
            .closed => null,
            .confirming => |*value| value,
            .deleting => |*value| &value.summary,
        };
    }

    pub fn holdsRun(
        self: *const State,
        review_repository_id: committed_review.ReviewRepositoryId,
        review_id: committed_review.ReviewId,
    ) bool {
        const value = self.summary() orelse return false;
        return value.request.store.review_repository_id.eql(review_repository_id) and
            value.request.review_id.eql(review_id);
    }

    pub fn begin(
        self: *State,
        allocator: std.mem.Allocator,
        store: review_store.StoreSnapshot,
        row: *const review_store.RunSummary,
        fallback_review_id: ?committed_review.ReviewId,
    ) !void {
        std.debug.assert(self.phase == .closed);
        self.phase = .{ .confirming = try Summary.init(allocator, store, row, fallback_review_id) };
    }

    pub fn cancel(self: *State, allocator: std.mem.Allocator) bool {
        var summary_value = switch (self.phase) {
            .confirming => |value| value,
            .closed, .deleting => return false,
        };
        self.phase = .closed;
        summary_value.deinit(allocator);
        return true;
    }

    pub fn confirm(
        self: *State,
        identity: page.RequestIdentity,
        root_identity: root_capability.Identity,
        store_identity: review_store.ConfigurationIdentity,
    ) ?Request {
        const summary_value = switch (self.phase) {
            .confirming => |value| value,
            .closed, .deleting => return null,
        };
        self.advanceGeneration();
        self.phase = .{ .deleting = .{
            .summary = summary_value,
            .identity = identity,
            .generation = self.next_generation,
            .root_identity = root_identity,
            .store_identity = store_identity,
        } };
        return .{
            .identity = identity,
            .generation = self.next_generation,
            .request = summary_value.request,
        };
    }

    pub fn restoreConfirmation(self: *State) void {
        const deleting = switch (self.phase) {
            .deleting => |value| value,
            .closed, .confirming => return,
        };
        self.phase = .{ .confirming = deleting.summary };
    }

    pub fn accept(
        self: *State,
        allocator: std.mem.Allocator,
        repo_epoch: u64,
        root_identity: ?root_capability.Identity,
        store_identity: review_store.ConfigurationIdentity,
        page_instance_current: bool,
        finished: Finished,
    ) ?Accepted {
        var deleting = switch (self.phase) {
            .deleting => |value| value,
            .closed, .confirming => return null,
        };
        if (!page_instance_current or
            deleting.identity.repo_epoch != repo_epoch or
            !std.meta.eql(deleting.identity, finished.identity) or
            deleting.generation != finished.generation or
            !deleting.root_identity.eql(root_identity orelse return null) or
            !deleting.root_identity.eql(finished.root_identity) or
            !deleting.store_identity.eql(store_identity) or
            !deleting.store_identity.eql(finished.store_identity) or
            !deleting.summary.request.review_id.eql(finished.review_id)) return null;

        const accepted: Accepted = .{
            .review_id = finished.review_id,
            .fallback_review_id = deleting.summary.fallback_review_id,
            .result = finished.result,
        };
        self.phase = .closed;
        deleting.summary.deinit(allocator);
        return accepted;
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        switch (self.phase) {
            .closed => {},
            .confirming => |*value| value.deinit(allocator),
            .deleting => |*value| value.summary.deinit(allocator),
        }
        self.* = .{};
    }

    fn advanceGeneration(self: *State) void {
        self.next_generation +%= 1;
        if (self.next_generation == 0) self.next_generation = 1;
    }
};

pub fn Task(comptime Msg: type) type {
    return struct {
        identity: page.RequestIdentity,
        generation: u64,
        store: review_store.ConfiguredStore,
        root: root_capability.RootCapability,
        root_identity: root_capability.Identity,
        environment: git_command.LocalGitEnvironment,
        request: review_store.DeleteRequest,

        pub fn init(
            request: Request,
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
                .identity = request.identity,
                .generation = request.generation,
                .store = owned_store,
                .root = owned_root,
                .root_identity = root.identity,
                .environment = try git_command.LocalGitEnvironment.initFromParent(allocator, env_map),
                .request = request.request,
            };
        }

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            const result: FinishedResult = .{ .result = review_store.deleteRun(
                allocator,
                io,
                &task.store,
                .{ .capability = &task.root, .environment = &task.environment },
                task.request,
            ) catch return task.finish(allocator, .{ .failed_static = "out of memory" }) };
            return task.finish(allocator, result);
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, .{ .failed_static = actions.taskFailureMessage(failure) });
        }

        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            task.deinitOwned(allocator);
            allocator.destroy(task);
        }

        fn finish(task: *@This(), allocator: std.mem.Allocator, result: FinishedResult) Msg {
            defer {
                task.environment.deinit();
                task.root.deinit();
                task.store.deinit(allocator);
                allocator.destroy(task);
            }
            return .{ .ai_review_delete_finished = .{
                .identity = task.identity,
                .generation = task.generation,
                .root_identity = task.root_identity,
                .store_identity = task.store.identity(),
                .review_id = task.request.review_id,
                .result = result,
            } };
        }

        fn deinitOwned(task: *@This(), allocator: std.mem.Allocator) void {
            task.environment.deinit();
            task.root.deinit();
            task.store.deinit(allocator);
        }
    };
}

test "Run deletion confirmation owns its summary and defaults to cancellation" {
    const allocator = std.testing.allocator;
    var row = try testRow();
    var state: State = .{};
    defer state.deinit(allocator);
    try state.begin(allocator, testStoreSnapshot(), &row, null);
    try std.testing.expect(state.summary().?.producer_name.ptr != row.producer_name.ptr);
    try std.testing.expectEqualStrings("reviewer", state.summary().?.producer_name);
    try std.testing.expect(state.summary().?.unfinished());
    try std.testing.expect(state.holdsRun(
        testStoreSnapshot().review_repository_id,
        row.review_id,
    ));
    try std.testing.expect(state.cancel(allocator));
    try std.testing.expect(!state.isOpen());
}

test "Run deletion completion requires the exact page generation root and Store" {
    const allocator = std.testing.allocator;
    var row = try testRow();
    var state: State = .{};
    defer state.deinit(allocator);
    try state.begin(allocator, testStoreSnapshot(), &row, null);
    const identity = page.RequestIdentity.aiReviews(7, 3);
    const root_identity: root_capability.Identity = .{ .device = 11, .inode = 12 };
    const store_identity: review_store.ConfigurationIdentity = .{ .digest = [_]u8{4} ** 32 };
    const request = state.confirm(identity, root_identity, store_identity).?;
    try std.testing.expect(request.request.allow_unfinished);

    const stale: Finished = .{
        .identity = identity,
        .generation = request.generation + 1,
        .root_identity = root_identity,
        .store_identity = store_identity,
        .review_id = row.review_id,
        .result = .{ .result = .{ .deleted = .complete } },
    };
    try std.testing.expect(state.accept(allocator, 7, root_identity, store_identity, true, stale) == null);
    try std.testing.expect(state.isDeleting());

    var current = stale;
    current.generation = request.generation;
    try std.testing.expect(state.accept(allocator, 7, root_identity, store_identity, false, current) == null);
    try std.testing.expect(state.accept(allocator, 8, root_identity, store_identity, true, current) == null);
    try std.testing.expect(state.accept(allocator, 7, null, store_identity, true, current) == null);
    try std.testing.expect(state.accept(allocator, 7, .{ .device = 13, .inode = 14 }, store_identity, true, current) == null);
    current.identity.activation_id += 1;
    try std.testing.expect(state.accept(allocator, 7, root_identity, store_identity, true, current) == null);
    current.identity = identity;
    current.root_identity = .{ .device = 13, .inode = 14 };
    try std.testing.expect(state.accept(allocator, 7, root_identity, store_identity, true, current) == null);
    current.root_identity = root_identity;
    const other_store: review_store.ConfigurationIdentity = .{ .digest = [_]u8{5} ** 32 };
    try std.testing.expect(state.accept(allocator, 7, root_identity, other_store, true, current) == null);
    current.store_identity = other_store;
    try std.testing.expect(state.accept(allocator, 7, root_identity, store_identity, true, current) == null);
    current.store_identity = store_identity;
    current.review_id = try committed_review.ReviewId.parse("223e4567-e89b-42d3-a456-426614174001");
    try std.testing.expect(state.accept(allocator, 7, root_identity, store_identity, true, current) == null);
    current.review_id = row.review_id;
    const accepted = state.accept(allocator, 7, root_identity, store_identity, true, current).?;
    try std.testing.expect(accepted.review_id.eql(row.review_id));
    try std.testing.expect(!state.isOpen());
}

fn testRow() !review_store.RunSummary {
    const review_id = try committed_review.ReviewId.parse("123e4567-e89b-42d3-a456-426614174000");
    const target: committed_review.CommittedReviewTarget = .{
        .object_format = .sha1,
        .source_kind = .branch_range,
        .base_oid = try committed_review.ObjectId.parse(.sha1, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        .head_oid = try committed_review.ObjectId.parse(.sha1, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
        .diff_base_oid = try committed_review.ObjectId.parse(.sha1, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
    };
    return .{
        .review_id = review_id,
        .target = target,
        .status = .draft,
        .created_at = "2026-09-10T00:00:00Z".*,
        .created_at_unix = 0,
        .producer_name = @constCast("reviewer"),
        .producer_model = @constCast("gpt-test"),
        .base_label = @constCast("main"),
        .head_label = @constCast("topic"),
        .finding_count = 2,
        .availability = .available,
        .artifact_snapshot = .{
            .manifest_digest = committed_review.Sha256Digest.hash("manifest"),
            .findings_digest = committed_review.Sha256Digest.hash("findings"),
            .draft_state = .valid,
            .draft_digest = committed_review.Sha256Digest.hash("draft"),
            .result_digest = null,
        },
    };
}

fn testStoreSnapshot() review_store.StoreSnapshot {
    const repository_id = committed_review.ReviewRepositoryId.parse("223e4567-e89b-42d3-a456-426614174000") catch unreachable;
    const display = review_store.RepositoryDisplayName.fromStored("repository") catch unreachable;
    return .{
        .root_device = 1,
        .root_inode = 2,
        .namespace_device = 3,
        .namespace_inode = 4,
        .repository_instance_id = committed_review.RepositoryInstanceId.parse("123e4567-e89b-42d3-a456-426614174010") catch unreachable,
        .review_repository_id = repository_id,
        .repository_display_name = display,
        .repository_directory_name = review_store.RepositoryDirectoryName.format(&display, repository_id),
    };
}
