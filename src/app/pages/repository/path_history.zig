const std = @import("std");
const app_page = @import("../../page.zig");
const git_read = @import("../../../git/read.zig");
const root_capability = @import("../../../repo/root_capability.zig");

pub const Terminal = enum {
    unavailable,
    pending,
    known,
};

pub const Request = struct {
    identity: app_page.RequestIdentity,
    root_identity: root_capability.Identity,
    manifest_revision: u64,
    generation: u64,
    root_path: []u8,
    path: []u8,
    root: root_capability.RootCapability,

    pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        allocator.free(self.root_path);
        allocator.free(self.path);
        self.root.deinit();
        self.* = undefined;
    }
};

pub const Finished = struct {
    identity: app_page.RequestIdentity,
    root_identity: root_capability.Identity,
    manifest_revision: u64,
    generation: u64,
    path: []u8,
    outcome: git_read.RepositoryPathHistoryOutcome,

    pub fn deinit(self: *Finished, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.outcome.deinit(allocator);
        self.* = undefined;
    }
};

const Pending = struct {
    identity: app_page.RequestIdentity,
    root_identity: root_capability.Identity,
    manifest_revision: u64,
    generation: u64,
    path: []const u8,

    fn matchesFinished(self: Pending, finished: *const Finished) bool {
        return std.meta.eql(self.identity, finished.identity) and
            self.root_identity.eql(finished.root_identity) and
            self.manifest_revision == finished.manifest_revision and
            self.generation == finished.generation and
            std.mem.eql(u8, self.path, finished.path);
    }
};

const Accepted = struct {
    identity: app_page.RequestIdentity,
    root_identity: root_capability.Identity,
    manifest_revision: u64,
    path: []u8,
    known: git_read.RepositoryPathHistoryKnown,

    fn deinit(self: *Accepted, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.known.deinit(allocator);
        self.* = undefined;
    }

    fn matches(
        self: *const Accepted,
        identity: app_page.RequestIdentity,
        root_identity: root_capability.Identity,
        manifest_revision: u64,
        path: []const u8,
    ) bool {
        return std.meta.eql(self.identity, identity) and
            self.root_identity.eql(root_identity) and
            self.manifest_revision == manifest_revision and
            std.mem.eql(u8, self.path, path);
    }
};

pub const ApplyOutcome = enum {
    discarded,
    unavailable,
    known,
};

/// Borrowed corroboration from an exact fresh branch snapshot. Optionality at
/// the call site represents absence of fresh evidence; `.unborn` must remain
/// distinct from that absence so it can reject facts observed at an OID.
pub const FreshHeadBasis = union(enum) {
    oid: []const u8,
    unborn,

    fn matches(self: FreshHeadBasis, observed: git_read.HeadBasis) bool {
        return switch (self) {
            .oid => |oid| switch (observed) {
                .oid => |observed_oid| std.mem.eql(u8, oid, observed_oid),
                .unborn => false,
            },
            .unborn => observed == .unborn,
        };
    }
};

/// One current-selection observation. Pending identity borrows only the
/// task-owned path while that task is live; every invalidation clears pending
/// before the page can release or replace the selected manifest path.
pub const State = struct {
    generation: u64 = 0,
    pending: ?Pending = null,
    accepted: ?Accepted = null,
    needs_revalidation: bool = false,
    terminal: Terminal = .unavailable,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.clearAccepted(allocator);
        self.* = .{};
    }

    pub fn invalidate(self: *State, allocator: std.mem.Allocator, schedule: bool) void {
        self.pending = null;
        self.clearAccepted(allocator);
        self.needs_revalidation = schedule;
        self.terminal = .unavailable;
    }

    /// Withdraw presentation immediately when the caller has no allocator
    /// (activation/reload edges). Any retained accepted allocation is hidden
    /// and released by the next prepared request, hard replacement, or deinit.
    pub fn retire(self: *State, schedule: bool) void {
        self.pending = null;
        self.needs_revalidation = schedule;
        self.terminal = .unavailable;
    }

    pub fn wantsRequest(
        self: *const State,
        active: bool,
        root_identity: ?root_capability.Identity,
        path: ?[]const u8,
    ) bool {
        return active and root_identity != null and path != null and
            self.needs_revalidation and self.pending == null;
    }

    pub fn prepareRequest(
        self: *State,
        allocator: std.mem.Allocator,
        identity: app_page.RequestIdentity,
        manifest_revision: u64,
        repo_root: []const u8,
        path: []const u8,
        capability: *const root_capability.RootCapability,
    ) !Request {
        self.clearAccepted(allocator);
        const owned_root = try allocator.dupe(u8, repo_root);
        errdefer allocator.free(owned_root);
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        var root = try capability.duplicate();
        errdefer root.deinit();

        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        self.pending = .{
            .identity = identity,
            .root_identity = root.identity,
            .manifest_revision = manifest_revision,
            .generation = self.generation,
            .path = owned_path,
        };
        self.needs_revalidation = false;
        self.terminal = .pending;
        return .{
            .identity = identity,
            .root_identity = root.identity,
            .manifest_revision = manifest_revision,
            .generation = self.generation,
            .root_path = owned_root,
            .path = owned_path,
            .root = root,
        };
    }

    pub fn markPreparationFailed(self: *State) void {
        self.needs_revalidation = false;
        self.terminal = .unavailable;
    }

    pub fn rejectSpawn(self: *State, generation: u64) void {
        const pending = self.pending orelse return;
        if (pending.generation != generation) return;
        self.pending = null;
        self.needs_revalidation = false;
        self.terminal = .unavailable;
    }

    pub fn applyFinished(
        self: *State,
        allocator: std.mem.Allocator,
        identity: app_page.RequestIdentity,
        root_identity: ?root_capability.Identity,
        manifest_revision: u64,
        selected_path: ?[]const u8,
        active: bool,
        fresh_branch_basis: ?FreshHeadBasis,
        finished: *Finished,
    ) ApplyOutcome {
        const pending = self.pending orelse return .discarded;
        if (!pending.matchesFinished(finished)) return .discarded;
        self.pending = null;

        const root = root_identity orelse return self.setUnavailable();
        const path = selected_path orelse return self.setUnavailable();
        if (!active or !std.meta.eql(identity, pending.identity) or
            !root.eql(pending.root_identity) or manifest_revision != pending.manifest_revision or
            !std.mem.eql(u8, path, pending.path))
        {
            self.needs_revalidation = active;
            self.terminal = .unavailable;
            return .discarded;
        }

        switch (finished.outcome) {
            .unavailable => return self.setUnavailable(),
            .known => |*known| {
                if (fresh_branch_basis) |branch_basis| {
                    if (!branch_basis.matches(known.head)) return self.setUnavailable();
                }
                self.clearAccepted(allocator);
                self.accepted = .{
                    .identity = finished.identity,
                    .root_identity = finished.root_identity,
                    .manifest_revision = finished.manifest_revision,
                    .path = finished.path,
                    .known = known.*,
                };
                finished.path = &.{};
                finished.outcome = .unavailable;
                self.needs_revalidation = false;
                self.terminal = .known;
                return .known;
            },
        }
    }

    pub fn fact(
        self: *const State,
        identity: app_page.RequestIdentity,
        root_identity: ?root_capability.Identity,
        manifest_revision: u64,
        path: []const u8,
    ) ?git_read.RepositoryPathHistoryFact {
        if (self.terminal != .known) return null;
        const root = root_identity orelse return null;
        const accepted = if (self.accepted) |*value| value else return null;
        if (!accepted.matches(identity, root, manifest_revision, path)) return null;
        return accepted.known.fact;
    }

    /// A later fresh branch observation is a successor authority. If it proves
    /// a different HEAD, withdraw the old value and schedule exactly one read.
    pub fn reconcileFreshBranchBasis(
        self: *State,
        allocator: std.mem.Allocator,
        basis: FreshHeadBasis,
        can_schedule: bool,
    ) bool {
        if (self.terminal != .known) return false;
        const accepted = if (self.accepted) |*value| value else return false;
        if (basis.matches(accepted.known.head)) return false;
        self.invalidate(allocator, can_schedule);
        return true;
    }

    fn setUnavailable(self: *State) ApplyOutcome {
        self.needs_revalidation = false;
        self.terminal = .unavailable;
        return .unavailable;
    }

    fn clearAccepted(self: *State, allocator: std.mem.Allocator) void {
        if (self.accepted) |*accepted| accepted.deinit(allocator);
        self.accepted = null;
    }
};

const TestRoot = struct {
    tmp: std.testing.TmpDir,
    path: [:0]u8,
    capability: root_capability.RootCapability,

    fn init() !TestRoot {
        const allocator = std.testing.allocator;
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        errdefer allocator.free(path);
        return .{
            .tmp = tmp,
            .path = path,
            .capability = try root_capability.RootCapability.openCanonical(path),
        };
    }

    fn deinit(self: *TestRoot) void {
        self.capability.deinit();
        std.testing.allocator.free(self.path);
        self.tmp.cleanup();
        self.* = undefined;
    }
};

fn knownOutcome(oid: []const u8, fact: git_read.RepositoryPathHistoryFact) !git_read.RepositoryPathHistoryOutcome {
    return .{ .known = .{
        .head = .{ .oid = try std.testing.allocator.dupe(u8, oid) },
        .fact = fact,
    } };
}

fn finishedFromRequest(
    request: *Request,
    outcome: git_read.RepositoryPathHistoryOutcome,
) Finished {
    const finished = Finished{
        .identity = request.identity,
        .root_identity = request.root_identity,
        .manifest_revision = request.manifest_revision,
        .generation = request.generation,
        .path = request.path,
        .outcome = outcome,
    };
    request.path = &.{};
    return finished;
}

test "Repository path history accepts only an exact positive fact with HEAD basis" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state: State = .{};
    defer state.deinit(allocator);
    const identity = app_page.RequestIdentity{ .origin = .repository, .repo_epoch = 3, .activation_id = 4 };
    state.invalidate(allocator, true);
    var request = try state.prepareRequest(allocator, identity, 7, root.path, "src/main.zig", &root.capability);
    defer request.deinit(allocator);
    var finished = finishedFromRequest(&request, try knownOutcome(
        "0123456789abcdef0123456789abcdef01234567",
        .{ .committed = 951_827_640 },
    ));
    defer finished.deinit(allocator);

    try std.testing.expectEqual(ApplyOutcome.known, state.applyFinished(
        allocator,
        identity,
        root.capability.identity,
        7,
        "src/main.zig",
        true,
        .{ .oid = "0123456789abcdef0123456789abcdef01234567" },
        &finished,
    ));
    const fact = state.fact(identity, root.capability.identity, 7, "src/main.zig").?;
    try std.testing.expectEqual(@as(i64, 951_827_640), fact.committed);
    try std.testing.expect(state.pending == null);
    try std.testing.expect(state.terminal == .known);
    try std.testing.expect(finished.outcome == .unavailable);
    try std.testing.expectEqual(@as(usize, 0), finished.path.len);
}

test "Repository path history stale completions preserve the exact current pending owner" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state: State = .{};
    defer state.deinit(allocator);
    const identity = app_page.RequestIdentity{ .origin = .repository, .repo_epoch = 5, .activation_id = 6 };
    state.invalidate(allocator, true);
    var request = try state.prepareRequest(allocator, identity, 9, root.path, "a.zig", &root.capability);
    defer request.deinit(allocator);

    for (0..6) |mismatch| {
        var stale = Finished{
            .identity = request.identity,
            .root_identity = request.root_identity,
            .manifest_revision = request.manifest_revision,
            .generation = request.generation,
            .path = try allocator.dupe(u8, request.path),
            .outcome = try knownOutcome("0123456789abcdef0123456789abcdef01234567", .uncommitted),
        };
        defer stale.deinit(allocator);
        switch (mismatch) {
            0 => stale.identity.origin = .changes,
            1 => stale.identity.repo_epoch +%= 1,
            2 => stale.identity.activation_id +%= 1,
            3 => stale.root_identity.inode +%= 1,
            4 => stale.manifest_revision +%= 1,
            5 => stale.generation +%= 1,
            else => unreachable,
        }
        try std.testing.expectEqual(ApplyOutcome.discarded, state.applyFinished(
            allocator,
            identity,
            root.capability.identity,
            9,
            "a.zig",
            true,
            null,
            &stale,
        ));
        try std.testing.expectEqual(request.generation, state.pending.?.generation);
    }
}

test "Repository path history already-fresh branch mismatch is terminal without tight retry" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state: State = .{};
    defer state.deinit(allocator);
    const identity = app_page.RequestIdentity{ .origin = .repository, .repo_epoch = 2, .activation_id = 8 };
    state.invalidate(allocator, true);
    var request = try state.prepareRequest(allocator, identity, 4, root.path, "main.zig", &root.capability);
    defer request.deinit(allocator);
    var finished = finishedFromRequest(&request, try knownOutcome(
        "0123456789abcdef0123456789abcdef01234567",
        .uncommitted,
    ));
    defer finished.deinit(allocator);

    try std.testing.expectEqual(ApplyOutcome.unavailable, state.applyFinished(
        allocator,
        identity,
        root.capability.identity,
        4,
        "main.zig",
        true,
        .{ .oid = "fedcba9876543210fedcba9876543210fedcba98" },
        &finished,
    ));
    try std.testing.expect(state.terminal == .unavailable);
    try std.testing.expect(!state.needs_revalidation);
    try std.testing.expect(state.accepted == null);
}

test "Repository path history later fresh branch mismatch withdraws and schedules one successor" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state: State = .{};
    defer state.deinit(allocator);
    const identity = app_page.RequestIdentity{ .origin = .repository, .repo_epoch = 2, .activation_id = 3 };
    state.invalidate(allocator, true);
    var request = try state.prepareRequest(allocator, identity, 4, root.path, "main.zig", &root.capability);
    defer request.deinit(allocator);
    var finished = finishedFromRequest(&request, try knownOutcome(
        "0123456789abcdef0123456789abcdef01234567",
        .{ .committed = 42 },
    ));
    defer finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.known, state.applyFinished(
        allocator,
        identity,
        root.capability.identity,
        4,
        "main.zig",
        true,
        null,
        &finished,
    ));

    try std.testing.expect(!state.reconcileFreshBranchBasis(
        allocator,
        .{ .oid = "0123456789abcdef0123456789abcdef01234567" },
        true,
    ));
    try std.testing.expect(state.reconcileFreshBranchBasis(
        allocator,
        .{ .oid = "fedcba9876543210fedcba9876543210fedcba98" },
        true,
    ));
    try std.testing.expect(state.accepted == null);
    try std.testing.expect(state.needs_revalidation);
    try std.testing.expect(state.terminal == .unavailable);
}

test "Repository path history unavailable completion and retire close without primary diagnostics" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state: State = .{};
    defer state.deinit(allocator);
    const identity = app_page.RequestIdentity{ .origin = .repository, .repo_epoch = 1, .activation_id = 1 };
    state.invalidate(allocator, true);
    var request = try state.prepareRequest(allocator, identity, 1, root.path, "a.zig", &root.capability);
    defer request.deinit(allocator);
    var finished = finishedFromRequest(&request, .unavailable);
    defer finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.unavailable, state.applyFinished(
        allocator,
        identity,
        root.capability.identity,
        1,
        "a.zig",
        true,
        null,
        &finished,
    ));
    try std.testing.expect(!state.needs_revalidation);
    state.retire(true);
    try std.testing.expect(state.wantsRequest(true, root.capability.identity, "a.zig"));
}
