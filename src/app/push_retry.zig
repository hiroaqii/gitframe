//! Descriptor-owned native push retry and local-upstream finalization.
//!
//! A failed push snapshot has exactly one owner. Foreground admission moves it
//! through a URL/config/branch/OID inspection task, then retains it until the
//! Chasen foreground callback. A successful no-upstream push moves the same
//! owner into one bounded local finalizer; no credential or raw URL state is
//! present in this lifecycle.

const std = @import("std");
const chasen = @import("chasen");

const actions = @import("actions.zig");
const effect_origin = @import("effect_origin.zig");
const app_state = @import("state.zig");
const remote_request = @import("remote_request.zig");
const git_remote = @import("../git/remote.zig");
const root_capability = @import("../repo/root_capability.zig");

const inspection_timeout = std.Io.Duration.fromSeconds(10);
const finalization_timeout = std.Io.Duration.fromSeconds(10);

pub const TargetIdentity = struct {
    digest: u64,

    pub fn eql(left: TargetIdentity, right: TargetIdentity) bool {
        return left.digest == right.digest;
    }
};

pub fn targetIdentity(target: app_state.PushRetryTarget) TargetIdentity {
    var digest = std.hash.Wyhash.hash(0, @tagName(target.mode));
    digest = std.hash.Wyhash.hash(digest, std.mem.asBytes(&target.repo_epoch));
    digest = std.hash.Wyhash.hash(digest, std.mem.asBytes(&target.root_identity.device));
    digest = std.hash.Wyhash.hash(digest, std.mem.asBytes(&target.root_identity.inode));
    digest = std.hash.Wyhash.hash(digest, target.repo_root);
    digest = std.hash.Wyhash.hash(digest, target.branch);
    digest = std.hash.Wyhash.hash(digest, target.remote);
    digest = std.hash.Wyhash.hash(digest, target.remote_branch);
    digest = std.hash.Wyhash.hash(digest, target.oid);
    return .{ .digest = digest };
}

pub const Available = struct {
    target: app_state.PushRetryTarget,
};

pub const Inspecting = struct {
    identity: remote_request.RemoteRequestIdentity,
    origin: effect_origin.PageOrigin,
    target_identity: TargetIdentity,

    pub fn accepts(self: Inspecting, finished: Finished) bool {
        return self.identity.eql(finished.identity) and
            self.target_identity.eql(finished.target_identity) and
            self.origin.eql(finished.origin);
    }
};

pub const Foreground = struct {
    request_id: chasen.ForegroundCommandRequestId,
    pending: actions.PendingAction,
    identity: remote_request.RemoteRequestIdentity,
    origin: effect_origin.PageOrigin,
    root: root_capability.RootCapability,
    target: app_state.PushRetryTarget,
    warnings: git_remote.RemoteWarningSet,

    pub fn deinit(self: *Foreground, allocator: std.mem.Allocator) void {
        self.root.deinit();
        self.target.deinit(allocator);
        self.* = undefined;
    }
};

/// The task owns root/environment/target while this correlation-only state is
/// live. Chasen either delivers `FinalizeFinished` or deinitializes it during
/// shutdown; App state therefore owns no duplicate finalizer payload.
pub const Finalizing = struct {
    pending: actions.PendingAction,
    identity: remote_request.RemoteRequestIdentity,
    origin: effect_origin.PageOrigin,

    pub fn accepts(self: Finalizing, finished: FinalizeFinished) bool {
        return self.identity.eql(finished.identity);
    }
};

pub const State = union(enum) {
    idle,
    available: Available,
    inspecting: Inspecting,
    foreground: Foreground,
    finalizing: Finalizing,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .available => |*available| available.target.deinit(allocator),
            .foreground => |*foreground| foreground.deinit(allocator),
            .idle, .inspecting, .finalizing => {},
        }
        self.* = .idle;
    }

    pub fn availableTarget(self: *const State) ?*const app_state.PushRetryTarget {
        return switch (self.*) {
            .available => |*available| &available.target,
            else => null,
        };
    }

    pub fn hasForeground(self: State) bool {
        return self == .foreground;
    }

    pub fn isFinalizing(self: State) bool {
        return self == .finalizing;
    }
};

pub const Model = struct {
    state: State = .idle,
    next_generation: u64 = 0,

    pub fn deinit(self: *Model, allocator: std.mem.Allocator) void {
        self.state.deinit(allocator);
    }

    pub fn beginInspection(
        self: *Model,
        origin: effect_origin.PageOrigin,
    ) ?struct { target: app_state.PushRetryTarget, metadata: Inspecting } {
        const available = switch (self.state) {
            .available => |available| available,
            else => return null,
        };
        self.next_generation +%= 1;
        if (self.next_generation == 0) self.next_generation = 1;
        const metadata: Inspecting = .{
            .identity = .{
                .repo_epoch = available.target.repo_epoch,
                .root_identity = available.target.root_identity,
                .operation_generation = self.next_generation,
            },
            .origin = origin,
            .target_identity = targetIdentity(available.target),
        };
        self.state = .{ .inspecting = metadata };
        return .{ .target = available.target, .metadata = metadata };
    }

    pub fn restoreAvailable(self: *Model, allocator: std.mem.Allocator, target: app_state.PushRetryTarget) void {
        self.state.deinit(allocator);
        self.state = .{ .available = .{ .target = target } };
    }
};

pub const Outcome = union(enum) {
    ready,
    branch_changed,
    oid_changed,
    failed: git_remote.RemoteFailure,
};

pub const Finished = struct {
    identity: remote_request.RemoteRequestIdentity,
    origin: effect_origin.PageOrigin,
    target_identity: TargetIdentity,
    root: ?root_capability.RootCapability,
    target: app_state.PushRetryTarget,
    warnings: git_remote.RemoteWarningSet,
    outcome: Outcome,

    pub fn takeRoot(self: *Finished) root_capability.RootCapability {
        const root = self.root orelse @panic("push inspection root already moved");
        self.root = null;
        return root;
    }

    pub fn deinit(self: *Finished, allocator: std.mem.Allocator) void {
        if (self.root) |*root| root.deinit();
        self.target.deinit(allocator);
        self.* = undefined;
    }
};

pub fn startInspection(
    comptime Msg: type,
    ctx: *chasen.Ctx(Msg),
    metadata: Inspecting,
    root: *?root_capability.RootCapability,
    environment: *?git_remote.OwnedRemoteEnvironment,
    target: *app_state.PushRetryTarget,
) !void {
    const TaskType = InspectionTask(Msg);
    const task = try ctx.allocator().create(TaskType);
    task.* = .{
        .metadata = metadata,
        .root = root.* orelse @panic("push inspection requires an owned root"),
        .environment = environment.* orelse @panic("push inspection requires an owned environment"),
        .target = target.take(),
    };
    root.* = null;
    environment.* = null;
    errdefer {
        root.* = task.root;
        environment.* = task.environment;
        target.* = task.target.take();
        ctx.allocator().destroy(task);
    }
    try ctx.task().spawnWith(.{ .ctx = task, .run = TaskType.run, .failed = TaskType.failed });
}

pub fn InspectionTask(comptime Msg: type) type {
    return struct {
        metadata: Inspecting,
        root: root_capability.RootCapability,
        environment: git_remote.OwnedRemoteEnvironment,
        target: app_state.PushRetryTarget,

        const Self = @This();

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *Self = @ptrCast(@alignCast(ctx_ptr));
            const result = git_remote.inspectForegroundPush(allocator, io, .{
                .root = &task.root,
                .environment = &task.environment,
                .control = .{ .deadline = std.Io.Clock.Timestamp.fromNow(io, .{
                    .raw = inspection_timeout,
                    .clock = .awake,
                }) },
                .push = .{
                    .mode = task.target.mode,
                    .branch = task.target.branch,
                    .remote = task.target.remote,
                    .remote_branch = task.target.remote_branch,
                    .oid = task.target.oid,
                },
            });
            return Msg.pushInspectionFinished(task.finish(allocator, .{
                .outcome = switch (result.outcome) {
                    .ready => .ready,
                    .branch_changed => .branch_changed,
                    .oid_changed => .oid_changed,
                    .failed => |failure| .{ .failed = failure },
                },
                .warnings = result.warnings,
            }));
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            _ = failure;
            const task: *Self = @ptrCast(@alignCast(ctx_ptr));
            return Msg.pushInspectionFinished(task.finish(allocator, .{
                .outcome = .{ .failed = .spawn_failed },
                .warnings = task.environment.warnings,
            }));
        }

        const TaskResult = struct {
            outcome: Outcome,
            warnings: git_remote.RemoteWarningSet,
        };

        fn finish(task: *Self, allocator: std.mem.Allocator, result: TaskResult) Finished {
            defer {
                task.environment.deinit();
                allocator.destroy(task);
            }
            return .{
                .identity = task.metadata.identity,
                .origin = task.metadata.origin,
                .target_identity = task.metadata.target_identity,
                .root = task.root,
                .target = task.target.take(),
                .warnings = result.warnings,
                .outcome = result.outcome,
            };
        }
    };
}

pub const FinalizeFinished = struct {
    identity: remote_request.RemoteRequestIdentity,
    outcome: git_remote.PushUpstreamFinalizeOutcome,
    warnings: git_remote.RemoteWarningSet,
};

pub fn startFinalization(
    comptime Msg: type,
    ctx: *chasen.Ctx(Msg),
    metadata: Finalizing,
    root: *?root_capability.RootCapability,
    environment: *?git_remote.OwnedRemoteEnvironment,
    target: *app_state.PushRetryTarget,
    warnings: git_remote.RemoteWarningSet,
) !void {
    const TaskType = FinalizeTask(Msg);
    const task = try ctx.allocator().create(TaskType);
    task.* = .{
        .metadata = metadata,
        .root = root.* orelse @panic("upstream finalizer requires an owned root"),
        .environment = environment.* orelse @panic("upstream finalizer requires an owned environment"),
        .target = target.take(),
        .warnings = warnings,
    };
    root.* = null;
    environment.* = null;
    errdefer {
        root.* = task.root;
        environment.* = task.environment;
        target.* = task.target.take();
        ctx.allocator().destroy(task);
    }
    try ctx.task().spawnWith(.{ .ctx = task, .run = TaskType.run, .failed = TaskType.failed });
}

pub fn FinalizeTask(comptime Msg: type) type {
    return struct {
        metadata: Finalizing,
        root: root_capability.RootCapability,
        environment: git_remote.OwnedRemoteEnvironment,
        target: app_state.PushRetryTarget,
        warnings: git_remote.RemoteWarningSet,

        const Self = @This();

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *Self = @ptrCast(@alignCast(ctx_ptr));
            const outcome = git_remote.finalizePushUpstream(allocator, io, .{
                .root = &task.root,
                .environment = &task.environment,
                .control = .{ .deadline = std.Io.Clock.Timestamp.fromNow(io, .{
                    .raw = finalization_timeout,
                    .clock = .awake,
                }) },
                .branch = task.target.branch,
                .remote = task.target.remote,
                .remote_branch = task.target.remote_branch,
                .oid = task.target.oid,
            });
            return Msg.pushUpstreamFinalizeFinished(task.finish(allocator, outcome));
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            _ = failure;
            const task: *Self = @ptrCast(@alignCast(ctx_ptr));
            return Msg.pushUpstreamFinalizeFinished(task.finish(allocator, .config_write_failed));
        }

        fn finish(task: *Self, allocator: std.mem.Allocator, outcome: git_remote.PushUpstreamFinalizeOutcome) FinalizeFinished {
            defer {
                task.root.deinit();
                task.environment.deinit();
                task.target.deinit(allocator);
                allocator.destroy(task);
            }
            return .{
                .identity = task.metadata.identity,
                .outcome = outcome,
                .warnings = task.warnings,
            };
        }
    };
}

test "push retry target identity covers the complete semantic snapshot" {
    const base: app_state.PushRetryTarget = .{
        .repo_epoch = 4,
        .root_identity = .{ .device = 7, .inode = 9 },
        .mode = .upstream,
        .repo_root = @constCast("/repo"),
        .branch = @constCast("main"),
        .remote = @constCast("origin"),
        .remote_branch = @constCast("main"),
        .oid = @constCast("abc"),
    };
    var changed = base;
    changed.oid = @constCast("def");
    try std.testing.expect(!targetIdentity(base).eql(targetIdentity(changed)));
}

test "push retry model moves one target owner through inspection" {
    const allocator = std.testing.allocator;
    var model: Model = .{};
    defer model.deinit(allocator);
    model.state = .{ .available = .{ .target = .{
        .repo_epoch = 4,
        .root_identity = .{ .device = 7, .inode = 9 },
        .mode = .upstream,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .branch = try allocator.dupe(u8, "main"),
        .remote = try allocator.dupe(u8, "origin"),
        .remote_branch = try allocator.dupe(u8, "main"),
        .oid = try allocator.dupe(u8, "abc"),
    } } };

    var started = model.beginInspection(.{ .page_id = .changes, .repo_epoch = 4, .activation_id = 7 }).?;
    defer started.target.deinit(allocator);
    try std.testing.expect(model.state == .inspecting);
    try std.testing.expectEqual(@as(u64, 1), started.metadata.identity.operation_generation);
    model.restoreAvailable(allocator, started.target.take());
    try std.testing.expect(model.state == .available);
}
