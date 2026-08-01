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
const page = @import("page.zig");
const app_state = @import("state.zig");

pub const Origin = struct {
    page_id: page.Id,
    repo_epoch: u64,
    activation_id: u64,

    pub fn eql(left: Origin, right: Origin) bool {
        return left.page_id == right.page_id and
            left.repo_epoch == right.repo_epoch and
            left.activation_id == right.activation_id;
    }
};

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
    generation: u64,
    kind: InspectionKind,
    origin: Origin,
    repo_epoch: u64,
    target_identity: TargetIdentity,

    pub fn accepts(self: Inspecting, finished: Finished) bool {
        return self.generation == finished.generation and
            self.kind == finished.kind and
            self.repo_epoch == finished.repo_epoch and
            self.target_identity.eql(finished.target_identity) and
            self.origin.eql(finished.origin);
    }
};

pub const Foreground = struct {
    request_id: chasen.ForegroundCommandRequestId,
    pending: actions.PendingAction,
    origin: Origin,
    target: app_state.PushRetryTarget,

    pub fn deinit(self: *Foreground, allocator: std.mem.Allocator) void {
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
        origin: Origin,
    ) ?struct { target: app_state.PushRetryTarget, credentials_available: bool, metadata: Inspecting } {
        const available = switch (self.state) {
            .available => |available| available,
            else => return null,
        };
        self.next_generation +%= 1;
        if (self.next_generation == 0) self.next_generation = 1;
        const metadata: Inspecting = .{
            .generation = self.next_generation,
            .kind = kind,
            .origin = origin,
            .repo_epoch = origin.repo_epoch,
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
    generation: u64,
    kind: InspectionKind,
    origin: Origin,
    repo_epoch: u64,
    target_identity: TargetIdentity,
    credentials_available: bool,
    target: app_state.PushRetryTarget,
    outcome: Outcome,

    pub fn deinit(self: *Finished, allocator: std.mem.Allocator) void {
        self.target.deinit(allocator);
        self.* = undefined;
    }
};

pub fn startInspection(
    comptime Msg: type,
    ctx: *chasen.Ctx(Msg),
    metadata: Inspecting,
    target: *app_state.PushRetryTarget,
    credentials_available: bool,
) !void {
    const TaskType = Task(Msg);
    const task = try ctx.allocator().create(TaskType);
    task.* = .{
        .metadata = metadata,
        .credentials_available = credentials_available,
        .target = target.take(),
    };
    errdefer {
        target.* = task.target.take();
        ctx.allocator().destroy(task);
    }
    try ctx.task().spawnWith(.{ .ctx = task, .run = TaskType.run, .failed = TaskType.failed });
}

pub fn Task(comptime Msg: type) type {
    return struct {
        metadata: Inspecting,
        credentials_available: bool,
        target: app_state.PushRetryTarget,

        const Self = @This();

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg {
            const task: *Self = @ptrCast(@alignCast(ctx_ptr));
            const outcome = switch (task.metadata.kind) {
                .verify_snapshot => if (verifySnapshot(allocator, io, task.target)) |matches|
                    if (matches) Outcome{ .snapshot_valid = {} } else Outcome{ .snapshot_changed = {} }
                else |_|
                    Outcome{ .inspection_failed = "could not verify push retry target" },
                .lookup_remote => lookupRemote(allocator, io, &task.target) catch
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
            defer allocator.destroy(task);
            return .{
                .generation = task.metadata.generation,
                .kind = task.metadata.kind,
                .origin = task.metadata.origin,
                .repo_epoch = task.metadata.repo_epoch,
                .target_identity = task.metadata.target_identity,
                .credentials_available = task.credentials_available,
                .target = task.target.take(),
                .outcome = outcome,
            };
        }
    };
}

fn lookupRemote(allocator: std.mem.Allocator, io: std.Io, target: *app_state.PushRetryTarget) !Outcome {
    const argv = [_][]const u8{ "git", "remote", "get-url", target.remote };
    const result = try std.process.run(allocator, io, .{
        .argv = &argv,
        .cwd = .{ .path = target.repo_root },
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

fn verifySnapshot(allocator: std.mem.Allocator, io: std.Io, target: app_state.PushRetryTarget) !bool {
    const branch_argv = [_][]const u8{ "git", "symbolic-ref", "--quiet", "--short", "HEAD" };
    const branch_result = try std.process.run(allocator, io, .{
        .argv = &branch_argv,
        .cwd = .{ .path = target.repo_root },
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
        .cwd = .{ .path = target.repo_root },
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
    try std.testing.expectEqual(@as(u64, 4), started.metadata.repo_epoch);
    try std.testing.expect(started.credentials_available);
}

test "inspection acceptance requires every correlation member" {
    const origin: Origin = .{ .page_id = .review, .repo_epoch = 4, .activation_id = 7 };
    const inspecting: Inspecting = .{
        .generation = 2,
        .kind = .verify_snapshot,
        .origin = origin,
        .repo_epoch = 4,
        .target_identity = .{ .digest = 99 },
    };
    const target = app_state.PushRetryTarget.empty();
    const base: Finished = .{
        .generation = 2,
        .kind = .verify_snapshot,
        .origin = origin,
        .repo_epoch = 4,
        .target_identity = .{ .digest = 99 },
        .credentials_available = false,
        .target = target,
        .outcome = .snapshot_valid,
    };
    try std.testing.expect(inspecting.accepts(base));

    var changed = base;
    changed.generation = 3;
    try std.testing.expect(!inspecting.accepts(changed));
    changed = base;
    changed.kind = .lookup_remote;
    try std.testing.expect(!inspecting.accepts(changed));
    changed = base;
    changed.origin.activation_id = 8;
    try std.testing.expect(!inspecting.accepts(changed));
    changed = base;
    changed.repo_epoch = 5;
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
