const std = @import("std");
const app_page = @import("../../page.zig");
const git_branch_status = @import("../../../git/branch_status.zig");
const root_capability = @import("../../../repo/root_capability.zig");

/// Repository-local terminal for the optional branch-status member.
///
/// These cases deliberately carry no raw subprocess text. The row-0 chrome
/// needs only a bounded availability/staleness decision, while detailed Git
/// stderr remains outside the page's primary status-message authority.
pub const Failure = enum {
    root_changed,
    load_failed,
    preparation_failed,
    start_failed,
    runtime_abandoned,
};

pub const Freshness = union(enum) {
    unavailable,
    validating,
    fresh,
    failed: Failure,
};

pub const SnapshotIdentity = struct {
    repo_epoch: u64,
    root_identity: root_capability.Identity,

    pub fn eql(left: SnapshotIdentity, right: SnapshotIdentity) bool {
        return left.repo_epoch == right.repo_epoch and left.root_identity.eql(right.root_identity);
    }
};

/// Retained last-good branch data for one exact Repository root.
///
/// The backend bundle already owns every status slice in one arena. Taking
/// that arena here avoids a second copy while keeping the snapshot wholly
/// page-local and independently releasable from Changes's branch owner.
pub const Snapshot = struct {
    arena: ?std.heap.ArenaAllocator = null,
    identity: ?SnapshotIdentity = null,
    status: git_branch_status.BranchStatus = .{},

    pub fn deinit(self: *Snapshot) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = .{};
    }

    pub fn matches(self: *const Snapshot, identity: SnapshotIdentity) bool {
        const current = self.identity orelse return false;
        return current.eql(identity);
    }

    fn replace(
        self: *Snapshot,
        identity: SnapshotIdentity,
        bundle: *git_branch_status.BranchStatusBundle,
    ) void {
        const arena = bundle.takeArena();
        const status = bundle.status;
        self.deinit();
        self.arena = arena;
        self.identity = identity;
        self.status = status;
    }
};

pub const Result = union(enum) {
    loaded: git_branch_status.BranchStatusBundle,
    failed: Failure,

    pub fn deinit(self: *Result) void {
        switch (self.*) {
            .loaded => |*bundle| bundle.deinit(),
            .failed => {},
        }
        self.* = .{ .failed = .load_failed };
    }
};

/// Owned completion payload carried by Repository's branch message route.
/// Defining cleanup beside the result keeps normal and undelivered ownership
/// on the same terminal operation.
pub const Finished = struct {
    identity: app_page.RequestIdentity,
    root_identity: root_capability.Identity,
    generation: u64,
    result: Result,

    pub fn deinit(self: *Finished) void {
        self.result.deinit();
        self.* = undefined;
    }
};

/// Prepared branch read. The canonical path is membership evidence for the
/// task's pre/post checks; the duplicated descriptor is the actual Git read
/// authority and must never be replaced by reopening `root_path`.
pub const Request = struct {
    identity: app_page.RequestIdentity,
    generation: u64,
    root_path: []u8,
    root: root_capability.RootCapability,

    pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        allocator.free(self.root_path);
        self.root.deinit();
        self.* = undefined;
    }
};

pub const Pending = struct {
    identity: app_page.RequestIdentity,
    root_identity: root_capability.Identity,
    generation: u64,

    fn matchesFinished(self: Pending, finished: *const Finished) bool {
        return std.meta.eql(self.identity, finished.identity) and
            self.root_identity.eql(finished.root_identity) and
            self.generation == finished.generation;
    }
};

pub const ApplyOutcome = enum {
    discarded,
    unchanged,
    changed,
    failed,
};

/// Repository-owned branch lifecycle. It intentionally owns no timer, task,
/// App callback, rendering, push authority, or primary page diagnostic.
pub const State = struct {
    snapshot: Snapshot = .{},
    generation: u64 = 0,
    pending: ?Pending = null,
    needs_revalidation: bool = false,
    freshness: Freshness = .unavailable,

    pub fn deinit(self: *State) void {
        self.snapshot.deinit();
        self.* = .{};
    }

    /// Every activation names a new request identity. Retain same-root data for
    /// immediate presentation later, but require a new read before it is fresh
    /// for the new activation.
    pub fn activate(
        self: *State,
        repo_epoch: u64,
        root_identity: ?root_capability.Identity,
    ) void {
        self.pending = null;
        const root = root_identity orelse {
            self.snapshot.deinit();
            self.needs_revalidation = false;
            self.freshness = .unavailable;
            return;
        };
        const identity = SnapshotIdentity{ .repo_epoch = repo_epoch, .root_identity = root };
        if (!self.snapshot.matches(identity)) self.snapshot.deinit();
        self.needs_revalidation = true;
        self.freshness = .validating;
    }

    /// Repository replacement is a hard ownership boundary: neither retained
    /// data nor an old pending generation may cross it.
    pub fn repositoryChanged(
        self: *State,
        active: bool,
        root_identity: ?root_capability.Identity,
    ) void {
        self.pending = null;
        self.snapshot.deinit();
        self.needs_revalidation = active and root_identity != null;
        self.freshness = if (root_identity == null) .unavailable else .validating;
    }

    /// Manual reload may supersede an in-flight generation. Its last-good
    /// snapshot remains renderable until the successor reaches a terminal.
    pub fn requestReload(
        self: *State,
        active: bool,
        repo_epoch: u64,
        root_identity: ?root_capability.Identity,
    ) void {
        const root = root_identity orelse {
            self.pending = null;
            self.snapshot.deinit();
            self.needs_revalidation = false;
            self.freshness = .unavailable;
            return;
        };
        const identity = SnapshotIdentity{ .repo_epoch = repo_epoch, .root_identity = root };
        if (!self.snapshot.matches(identity)) self.snapshot.deinit();
        self.needs_revalidation = active;
        self.freshness = .validating;
    }

    pub fn wantsRequest(self: *const State, active: bool, root_identity: ?root_capability.Identity) bool {
        return active and root_identity != null and self.needs_revalidation;
    }

    /// Install the exact pending identity only after both owned task inputs
    /// have been prepared. Allocation/duplication failure therefore cannot
    /// leave a half-armed generation behind.
    pub fn prepareRequest(
        self: *State,
        allocator: std.mem.Allocator,
        identity: app_page.RequestIdentity,
        repo_root: []const u8,
        capability: *const root_capability.RootCapability,
    ) !Request {
        std.debug.assert(identity.origin == .repository);
        const owned_root = try allocator.dupe(u8, repo_root);
        errdefer allocator.free(owned_root);
        var root = try capability.duplicate();
        errdefer root.deinit();

        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        self.pending = .{
            .identity = identity,
            .root_identity = root.identity,
            .generation = self.generation,
        };
        self.needs_revalidation = false;
        self.freshness = .validating;
        return .{
            .identity = identity,
            .generation = self.generation,
            .root_path = owned_root,
            .root = root,
        };
    }

    pub fn markPreparationFailed(self: *State) void {
        self.needs_revalidation = false;
        self.freshness = .{ .failed = .preparation_failed };
    }

    pub fn rejectSpawn(self: *State, generation: u64) void {
        const pending = self.pending orelse return;
        if (pending.generation != generation) return;
        self.pending = null;
        self.needs_revalidation = false;
        self.freshness = .{ .failed = .start_failed };
    }

    /// Accept only the exact Repository request still named by both page and
    /// branch owners. The caller retains completion ownership and deinitializes
    /// it after this function; an accepted bundle transfers only its arena.
    pub fn applyFinished(
        self: *State,
        current_identity: app_page.RequestIdentity,
        current_root_identity: ?root_capability.Identity,
        active: bool,
        finished: *Finished,
    ) ApplyOutcome {
        const pending = self.pending orelse return .discarded;
        if (!pending.matchesFinished(finished)) return .discarded;
        self.pending = null;

        const current_root = current_root_identity orelse {
            self.needs_revalidation = false;
            self.freshness = .unavailable;
            return .discarded;
        };
        if (!std.meta.eql(current_identity, pending.identity) or
            !current_root.eql(pending.root_identity))
        {
            self.needs_revalidation = active;
            self.freshness = .validating;
            return .discarded;
        }

        self.needs_revalidation = false;
        switch (finished.result) {
            .failed => |failure| {
                self.freshness = .{ .failed = failure };
                return .failed;
            },
            .loaded => |*bundle| {
                const snapshot_identity = SnapshotIdentity{
                    .repo_epoch = current_identity.repo_epoch,
                    .root_identity = current_root,
                };
                const changed = !self.snapshot.matches(snapshot_identity) or
                    !self.snapshot.status.eql(bundle.status);
                if (changed) self.snapshot.replace(snapshot_identity, bundle);
                // An exact inactive completion may refresh retained data, but
                // only the next activation's revalidation can make it fresh.
                self.freshness = if (active) .fresh else .validating;
                return if (changed) .changed else .unchanged;
            },
        }
    }
};

fn branchBundleForTest(name: []const u8) !git_branch_status.BranchStatusBundle {
    var builder = git_branch_status.Builder.init(std.testing.allocator);
    errdefer builder.deinit();
    try builder.setOid("0123456789abcdef");
    try builder.setBranchHead(name);
    try builder.setUpstream("origin/main");
    builder.setAheadBehind(2, 1);
    return builder.finish();
}

const TestRoot = struct {
    tmp: std.testing.TmpDir,
    path: [:0]u8,
    capability: root_capability.RootCapability,

    fn init() !TestRoot {
        const allocator = std.testing.allocator;
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDir(io, "repo", .default_dir);
        const path = try tmp.dir.realPathFileAlloc(io, "repo", allocator);
        errdefer allocator.free(path);
        const capability = try root_capability.RootCapability.openCanonical(path);
        return .{ .tmp = tmp, .path = path, .capability = capability };
    }

    fn deinit(self: *TestRoot) void {
        self.capability.deinit();
        std.testing.allocator.free(self.path);
        self.tmp.cleanup();
    }
};

test "Repository branch state prepares descriptor-owned request and accepts exact result" {
    var root = try TestRoot.init();
    defer root.deinit();
    var state: State = .{};
    defer state.deinit();
    const identity = app_page.RequestIdentity{ .origin = .repository, .repo_epoch = 3, .activation_id = 4 };
    state.activate(identity.repo_epoch, root.capability.identity);

    var request = try state.prepareRequest(
        std.testing.allocator,
        identity,
        root.path,
        &root.capability,
    );
    defer request.deinit(std.testing.allocator);
    try std.testing.expect(request.root.identity.eql(root.capability.identity));
    try std.testing.expectEqualStrings(root.path, request.root_path);
    try std.testing.expect(request.root_path.ptr != root.path.ptr);

    var finished = Finished{
        .identity = request.identity,
        .root_identity = request.root.identity,
        .generation = request.generation,
        .result = .{ .loaded = try branchBundleForTest("feature") },
    };
    defer finished.deinit();
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(
        identity,
        root.capability.identity,
        true,
        &finished,
    ));
    try std.testing.expectEqualStrings("feature", state.snapshot.status.branchName().?);
    try std.testing.expect(state.pending == null);
    try std.testing.expect(state.freshness == .fresh);
}

test "Repository branch identity mismatches are cleanup-only and preserve exact pending request" {
    var root = try TestRoot.init();
    defer root.deinit();
    var state: State = .{};
    defer state.deinit();
    const identity = app_page.RequestIdentity{ .origin = .repository, .repo_epoch = 5, .activation_id = 2 };
    state.activate(identity.repo_epoch, root.capability.identity);
    var request = try state.prepareRequest(std.testing.allocator, identity, root.path, &root.capability);
    defer request.deinit(std.testing.allocator);

    for (0..5) |mismatch| {
        var stale = Finished{
            .identity = request.identity,
            .root_identity = request.root.identity,
            .generation = request.generation,
            .result = .{ .loaded = try branchBundleForTest("stale") },
        };
        defer stale.deinit();
        switch (mismatch) {
            0 => stale.identity.origin = .changes,
            1 => stale.identity.repo_epoch +%= 1,
            2 => stale.identity.activation_id +%= 1,
            3 => stale.root_identity.inode +%= 1,
            4 => stale.generation +%= 1,
            else => unreachable,
        }
        try std.testing.expectEqual(ApplyOutcome.discarded, state.applyFinished(
            identity,
            root.capability.identity,
            true,
            &stale,
        ));
        try std.testing.expectEqual(request.generation, state.pending.?.generation);
        try std.testing.expect(state.snapshot.identity == null);
    }
}

test "Repository branch failure retains last-good snapshot in its local terminal" {
    var root = try TestRoot.init();
    defer root.deinit();
    var state: State = .{};
    defer state.deinit();
    const identity = app_page.RequestIdentity{ .origin = .repository, .repo_epoch = 1, .activation_id = 1 };
    state.activate(identity.repo_epoch, root.capability.identity);
    var first_request = try state.prepareRequest(std.testing.allocator, identity, root.path, &root.capability);
    defer first_request.deinit(std.testing.allocator);
    var first = Finished{
        .identity = identity,
        .root_identity = first_request.root.identity,
        .generation = first_request.generation,
        .result = .{ .loaded = try branchBundleForTest("main") },
    };
    defer first.deinit();
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(identity, root.capability.identity, true, &first));

    state.requestReload(true, identity.repo_epoch, root.capability.identity);
    var retry = try state.prepareRequest(std.testing.allocator, identity, root.path, &root.capability);
    defer retry.deinit(std.testing.allocator);
    var failed = Finished{
        .identity = identity,
        .root_identity = retry.root.identity,
        .generation = retry.generation,
        .result = .{ .failed = .load_failed },
    };
    defer failed.deinit();
    try std.testing.expectEqual(ApplyOutcome.failed, state.applyFinished(identity, root.capability.identity, true, &failed));
    try std.testing.expectEqualStrings("main", state.snapshot.status.branchName().?);
    try std.testing.expectEqual(Failure.load_failed, state.freshness.failed);
}

test "Repository branch exact inactive completion stays retained but requires activation revalidation" {
    var root = try TestRoot.init();
    defer root.deinit();
    var state: State = .{};
    defer state.deinit();
    const identity = app_page.RequestIdentity{ .origin = .repository, .repo_epoch = 7, .activation_id = 8 };
    state.activate(identity.repo_epoch, root.capability.identity);
    var request = try state.prepareRequest(std.testing.allocator, identity, root.path, &root.capability);
    defer request.deinit(std.testing.allocator);
    var finished = Finished{
        .identity = identity,
        .root_identity = request.root.identity,
        .generation = request.generation,
        .result = .{ .loaded = try branchBundleForTest("inactive") },
    };
    defer finished.deinit();
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(identity, root.capability.identity, false, &finished));
    try std.testing.expect(state.freshness == .validating);
    try std.testing.expect(!state.needs_revalidation);

    state.activate(identity.repo_epoch, root.capability.identity);
    try std.testing.expectEqualStrings("inactive", state.snapshot.status.branchName().?);
    try std.testing.expect(state.needs_revalidation);
    try std.testing.expect(state.freshness == .validating);
}

test "Repository branch repository replacement clears retained and pending owners" {
    var root = try TestRoot.init();
    defer root.deinit();
    var state: State = .{};
    defer state.deinit();
    const identity = app_page.RequestIdentity{ .origin = .repository, .repo_epoch = 2, .activation_id = 3 };
    state.activate(identity.repo_epoch, root.capability.identity);
    var request = try state.prepareRequest(std.testing.allocator, identity, root.path, &root.capability);
    defer request.deinit(std.testing.allocator);
    var finished = Finished{
        .identity = identity,
        .root_identity = request.root.identity,
        .generation = request.generation,
        .result = .{ .loaded = try branchBundleForTest("old") },
    };
    defer finished.deinit();
    _ = state.applyFinished(identity, root.capability.identity, true, &finished);

    state.requestReload(true, identity.repo_epoch, root.capability.identity);
    var pending = try state.prepareRequest(std.testing.allocator, identity, root.path, &root.capability);
    defer pending.deinit(std.testing.allocator);
    const replacement = root_capability.Identity{
        .device = root.capability.identity.device,
        .inode = root.capability.identity.inode +% 1,
    };
    state.repositoryChanged(true, replacement);
    try std.testing.expect(state.snapshot.identity == null);
    try std.testing.expect(state.pending == null);
    try std.testing.expect(state.needs_revalidation);
    try std.testing.expect(state.freshness == .validating);
}

test "Repository branch spawn rejection closes only its exact generation" {
    var state: State = .{
        .generation = 9,
        .pending = .{
            .identity = .{ .origin = .repository, .repo_epoch = 2, .activation_id = 3 },
            .root_identity = .{ .device = 4, .inode = 5 },
            .generation = 9,
        },
        .freshness = .validating,
    };
    defer state.deinit();

    state.rejectSpawn(8);
    try std.testing.expectEqual(@as(?u64, 9), if (state.pending) |pending| pending.generation else null);
    try std.testing.expect(state.freshness == .validating);

    state.rejectSpawn(9);
    try std.testing.expect(state.pending == null);
    try std.testing.expectEqual(Failure.start_failed, state.freshness.failed);
}
