//! Shell-owned push retry lifecycle and asynchronous inspection tasks.
//!
//! A failed push snapshot has exactly one owner. While Git verifies that
//! snapshot or resolves its remote URL, ownership moves into the task; the App
//! retains only immutable correlation metadata. Every task completion returns
//! the snapshot so accepted, stale, canceled, and undelivered paths all have a
//! single explicit cleanup terminal.

const std = @import("std");
const chasen = @import("chasen");

const actions = @import("actions.zig");
const effect_origin = @import("effect_origin.zig");
const app_state = @import("state.zig");
const remote_request = @import("remote_request.zig");
const git_backend = @import("../git/backend.zig");
const root_capability = @import("../repo/root_capability.zig");

pub const InspectionKind = enum {
    verify_snapshot,
    lookup_remote,
};

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
    credentials_available: bool,
};

pub const Inspecting = struct {
    identity: remote_request.RemoteRequestIdentity,
    kind: InspectionKind,
    origin: effect_origin.PageOrigin,
    target_identity: TargetIdentity,

    pub fn accepts(self: Inspecting, finished: Finished) bool {
        return self.identity.eql(finished.identity) and
            self.kind == finished.kind and
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
    warnings: git_backend.RemoteWarningSet,

    pub fn deinit(self: *Foreground, allocator: std.mem.Allocator) void {
        self.root.deinit();
        self.target.deinit(allocator);
        self.* = undefined;
    }
};

/// Exactly one retry lifecycle state may be live at a time. The `inspecting`
/// state deliberately owns no target: the spawned task is its sole owner.
pub const State = union(enum) {
    idle,
    available: Available,
    inspecting: Inspecting,
    foreground: Foreground,
    credential_prompt: *app_state.PushCredentialPrompt,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .available => |*available| available.target.deinit(allocator),
            .foreground => |*foreground| foreground.deinit(allocator),
            .credential_prompt => |prompt| {
                prompt.deinit(allocator);
                allocator.destroy(prompt);
            },
            .idle, .inspecting => {},
        }
        self.* = .idle;
    }

    pub fn availableTarget(self: *const State) ?*const app_state.PushRetryTarget {
        return switch (self.*) {
            .available => |*available| &available.target,
            else => null,
        };
    }

    pub fn credentialsAvailable(self: State) bool {
        return switch (self) {
            .available => |available| available.credentials_available,
            else => false,
        };
    }

    pub fn credentialPrompt(self: *const State) ?*const app_state.PushCredentialPrompt {
        return switch (self.*) {
            .credential_prompt => |prompt| prompt,
            else => null,
        };
    }

    pub fn hasForeground(self: State) bool {
        return self == .foreground;
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
        kind: InspectionKind,
        origin: effect_origin.PageOrigin,
    ) ?struct { target: app_state.PushRetryTarget, credentials_available: bool, metadata: Inspecting } {
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
            .kind = kind,
            .origin = origin,
            .target_identity = targetIdentity(available.target),
        };
        self.state = .{ .inspecting = metadata };
        return .{
            .target = available.target,
            .credentials_available = available.credentials_available,
            .metadata = metadata,
        };
    }

    pub fn restoreAvailable(self: *Model, allocator: std.mem.Allocator, target: app_state.PushRetryTarget, credentials_available: bool) void {
        self.state.deinit(allocator);
        self.state = .{ .available = .{
            .target = target,
            .credentials_available = credentials_available,
        } };
    }
};

pub const Outcome = union(enum) {
    snapshot_valid,
    snapshot_changed,
    remote_ready,
    remote_not_https,
    inspection_failed: []const u8,
};

pub const Finished = struct {
    identity: remote_request.RemoteRequestIdentity,
    kind: InspectionKind,
    origin: effect_origin.PageOrigin,
    target_identity: TargetIdentity,
    credentials_available: bool,
    root: ?root_capability.RootCapability,
    target: app_state.PushRetryTarget,
    warnings: git_backend.RemoteWarningSet,
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
    environment: *?git_backend.OwnedRemoteEnvironment,
    target: *app_state.PushRetryTarget,
    credentials_available: bool,
) !void {
    const TaskType = Task(Msg);
    const task = try ctx.allocator().create(TaskType);
    task.* = .{
        .metadata = metadata,
        .credentials_available = credentials_available,
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

pub fn Task(comptime Msg: type) type {
    return struct {
        metadata: Inspecting,
        credentials_available: bool,
        root: root_capability.RootCapability,
        environment: git_backend.OwnedRemoteEnvironment,
        target: app_state.PushRetryTarget,

        const Self = @This();

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *Self = @ptrCast(@alignCast(ctx_ptr));
            const outcome = switch (task.metadata.kind) {
                .verify_snapshot => if (verifySnapshot(allocator, io, task.root.dir(), &task.environment.map, task.target)) |matches|
                    if (matches) Outcome{ .snapshot_valid = {} } else Outcome{ .snapshot_changed = {} }
                else |_|
                    Outcome{ .inspection_failed = "could not verify push retry target" },
                .lookup_remote => lookupRemote(allocator, io, task.root.dir(), &task.environment.map, &task.target) catch
                    Outcome{ .inspection_failed = "could not read push remote URL" },
            };
            return Msg.pushInspectionFinished(task.finish(allocator, outcome));
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) Msg {
            const task: *Self = @ptrCast(@alignCast(ctx_ptr));
            return Msg.pushInspectionFinished(task.finish(
                allocator,
                .{ .inspection_failed = actions.taskFailureMessage(failure) },
            ));
        }

        /// Terminal epilogue shared by run and failed; owned-field release,
        /// moves, and destroy live only here.
        fn finish(task: *Self, allocator: std.mem.Allocator, outcome: Outcome) Finished {
            defer {
                task.environment.deinit();
                allocator.destroy(task);
            }
            return .{
                .identity = task.metadata.identity,
                .kind = task.metadata.kind,
                .origin = task.metadata.origin,
                .target_identity = task.metadata.target_identity,
                .credentials_available = task.credentials_available,
                .root = task.root,
                .target = task.target.take(),
                .warnings = task.environment.warnings,
                .outcome = outcome,
            };
        }
    };
}

fn lookupRemote(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    environment: *const std.process.Environ.Map,
    target: *app_state.PushRetryTarget,
) !Outcome {
    const argv = [_][]const u8{ "git", "remote", "get-url", target.remote };
    const result = try std.process.run(allocator, io, .{
        .argv = &argv,
        .cwd = .{ .dir = cwd },
        .environ_map = environment,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code == 0) {
            const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
            defer allocator.free(result.stdout);
            if (!isHttpsRemoteUrl(trimmed)) return .remote_not_https;
            const remote_url = try allocator.dupe(u8, trimmed);
            if (target.remote_url) |old_remote_url| allocator.free(old_remote_url);
            target.remote_url = remote_url;
            return .remote_ready;
        },
        else => {},
    }
    allocator.free(result.stdout);
    return error.RemoteUrlUnavailable;
}

fn isHttpsRemoteUrl(remote_url: []const u8) bool {
    const uri = std.Uri.parse(remote_url) catch return false;
    return std.ascii.eqlIgnoreCase(uri.scheme, "https") and uri.host != null;
}

fn verifySnapshot(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    environment: *const std.process.Environ.Map,
    target: app_state.PushRetryTarget,
) !bool {
    const branch_argv = [_][]const u8{ "git", "symbolic-ref", "--quiet", "--short", "HEAD" };
    const branch_result = try std.process.run(allocator, io, .{
        .argv = &branch_argv,
        .cwd = .{ .dir = cwd },
        .environ_map = environment,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(branch_result.stdout);
    defer allocator.free(branch_result.stderr);
    switch (branch_result.term) {
        .exited => |code| if (code != 0) return false,
        else => return false,
    }
    if (!std.mem.eql(u8, std.mem.trim(u8, branch_result.stdout, " \t\r\n"), target.branch)) return false;

    const oid_argv = [_][]const u8{ "git", "rev-parse", "--verify", "HEAD" };
    const oid_result = try std.process.run(allocator, io, .{
        .argv = &oid_argv,
        .cwd = .{ .dir = cwd },
        .environ_map = environment,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(oid_result.stdout);
    defer allocator.free(oid_result.stderr);
    switch (oid_result.term) {
        .exited => |code| if (code != 0) return false,
        else => return false,
    }
    return std.mem.eql(u8, std.mem.trim(u8, oid_result.stdout, " \t\r\n"), target.oid);
}

test "target identity covers the semantic failed-push snapshot" {
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

test "model moves the sole target owner into inspection metadata" {
    const allocator = std.testing.allocator;
    var model: Model = .{};
    defer model.deinit(allocator);
    model.state = .{ .available = .{
        .target = .{
            .repo_epoch = 4,
            .root_identity = .{ .device = 7, .inode = 9 },
            .mode = .upstream,
            .repo_root = try allocator.dupe(u8, "/repo"),
            .branch = try allocator.dupe(u8, "main"),
            .remote = try allocator.dupe(u8, "origin"),
            .remote_branch = try allocator.dupe(u8, "main"),
            .oid = try allocator.dupe(u8, "abc"),
        },
        .credentials_available = true,
    } };

    var started = model.beginInspection(.verify_snapshot, .{ .page_id = .review, .repo_epoch = 4, .activation_id = 7 }).?;
    defer started.target.deinit(allocator);
    try std.testing.expect(model.state == .inspecting);
    try std.testing.expectEqual(@as(u64, 4), started.metadata.identity.repo_epoch);
    try std.testing.expectEqual(@as(u64, 1), started.metadata.identity.operation_generation);
    try std.testing.expect(started.credentials_available);

    model.restoreAvailable(allocator, started.target.take(), started.credentials_available);
    var second = model.beginInspection(.lookup_remote, .{ .page_id = .review, .repo_epoch = 4, .activation_id = 7 }).?;
    defer second.target.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), second.metadata.identity.operation_generation);
    try std.testing.expectEqual(InspectionKind.lookup_remote, second.metadata.kind);
}

test "inspection acceptance requires every correlation member" {
    const origin: effect_origin.PageOrigin = .{ .page_id = .review, .repo_epoch = 4, .activation_id = 7 };
    const inspecting: Inspecting = .{
        .identity = .{
            .repo_epoch = 4,
            .root_identity = .{ .device = 7, .inode = 9 },
            .operation_generation = 2,
        },
        .kind = .verify_snapshot,
        .origin = origin,
        .target_identity = .{ .digest = 99 },
    };
    const target = app_state.PushRetryTarget.empty();
    const base: Finished = .{
        .identity = inspecting.identity,
        .kind = .verify_snapshot,
        .origin = origin,
        .target_identity = .{ .digest = 99 },
        .credentials_available = false,
        .root = null,
        .target = target,
        .warnings = .{},
        .outcome = .snapshot_valid,
    };
    try std.testing.expect(inspecting.accepts(base));

    var changed = base;
    changed.identity.operation_generation = 3;
    try std.testing.expect(!inspecting.accepts(changed));
    changed = base;
    changed.kind = .lookup_remote;
    try std.testing.expect(!inspecting.accepts(changed));
    changed = base;
    changed.origin.activation_id = 8;
    try std.testing.expect(!inspecting.accepts(changed));
    changed = base;
    changed.identity.repo_epoch = 5;
    try std.testing.expect(!inspecting.accepts(changed));
    changed = base;
    changed.identity.root_identity.inode = 10;
    try std.testing.expect(!inspecting.accepts(changed));
    changed = base;
    changed.target_identity.digest = 100;
    try std.testing.expect(!inspecting.accepts(changed));
}

test "credential remote validation accepts only absolute HTTPS URLs" {
    try std.testing.expect(isHttpsRemoteUrl("https://example.test/owner/repo.git"));
    try std.testing.expect(isHttpsRemoteUrl("HTTPS://example.test/owner/repo.git"));
    try std.testing.expect(!isHttpsRemoteUrl("http://example.test/owner/repo.git"));
    try std.testing.expect(!isHttpsRemoteUrl("git@example.test:owner/repo.git"));
    try std.testing.expect(!isHttpsRemoteUrl("ssh://git@example.test/owner/repo.git"));
    try std.testing.expect(!isHttpsRemoteUrl("file:///tmp/repo.git"));
    try std.testing.expect(!isHttpsRemoteUrl("https:relative-path"));
    try std.testing.expect(!isHttpsRemoteUrl("not a URI"));
}
