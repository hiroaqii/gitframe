const std = @import("std");
const loaded_diff = @import("../loaded_diff.zig");

const LoadedDiff = loaded_diff.LoadedDiff;

pub const AuxiliaryLoadAcceptance = enum {
    accepted_pending,
    accepted_without_pending,
    stale_generation,
};

pub const BranchListAcceptance = enum {
    accepted,
    no_pending,
    stale_pending_generation,
    missing_state,
    stale_state_generation,
    repo_mismatch,
};

pub const PendingLoad = union(enum) {
    repo_discovery: u64,
    diff_load: u64,

    pub fn generation(self: PendingLoad) u64 {
        return switch (self) {
            .repo_discovery => |value| value,
            .diff_load => |value| value,
        };
    }
};

/// Accept status-like auxiliary loads by generation, and clear the pending
/// marker only when this result owns it. Some auxiliary snapshots may already
/// have had their pending marker cleared by a newer UI path; keeping generation
/// as the authority preserves the existing stale-result contract.
pub fn acceptAuxiliaryLoadResult(pending: *?u64, current_generation: u64, result_generation: u64) AuxiliaryLoadAcceptance {
    if (result_generation != current_generation) return .stale_generation;
    if (pending.* == result_generation) {
        pending.* = null;
        return .accepted_pending;
    }
    return .accepted_without_pending;
}

/// Branch-list results are stricter than status snapshots: the popup that
/// requested the list must still exist, still have the same generation, and
/// still point at the same repository before App may show the result.
pub fn acceptBranchListResult(
    pending: *?u64,
    state_has_value: bool,
    state_generation: u64,
    state_repo_root: []const u8,
    result_generation: u64,
    result_repo_root: []const u8,
) BranchListAcceptance {
    const pending_generation = pending.* orelse return .no_pending;
    if (pending_generation != result_generation) return .stale_pending_generation;
    pending.* = null;

    if (!state_has_value) return .missing_state;
    if (state_generation != result_generation) return .stale_state_generation;
    if (!std.mem.eql(u8, state_repo_root, result_repo_root)) return .repo_mismatch;
    return .accepted;
}

/// Runtime-owned load state for the active diff source.
///
/// Async tasks produce raw results in app/load.zig. Once App accepts a result,
/// this type owns the active arena-backed payload and is responsible for
/// replacing or clearing it without leaking old sessions.
pub const LoadRuntimeState = struct {
    state: LoadState = .idle,
    pending: ?PendingLoad = null,
    /// Monotonic id used to ignore stale async task results after reload.
    generation: u64 = 0,

    pub fn beginRepoDiscovery(self: *LoadRuntimeState) u64 {
        const next = self.nextGeneration();
        self.pending = .{ .repo_discovery = next };
        return next;
    }

    pub fn beginDiffLoad(self: *LoadRuntimeState) u64 {
        const next = self.nextGeneration();
        self.pending = .{ .diff_load = next };
        return next;
    }

    pub fn finishPending(self: *LoadRuntimeState, expected: PendingLoad) bool {
        if (!self.pendingMatches(expected)) return false;
        self.pending = null;
        return true;
    }

    pub fn clearPendingIfCurrent(self: *LoadRuntimeState, expected: PendingLoad) bool {
        return self.finishPending(expected);
    }

    pub fn isCurrent(self: *const LoadRuntimeState, generation: u64) bool {
        return self.generation == generation;
    }

    pub fn hasPending(self: *const LoadRuntimeState) bool {
        return self.pending != null;
    }

    pub fn replaceLoaded(self: *LoadRuntimeState, allocator: std.mem.Allocator, session: LoadedSession) void {
        self.clearCurrent(allocator);
        self.state = .{ .loaded = session };
    }

    pub fn replaceFailed(self: *LoadRuntimeState, allocator: std.mem.Allocator, message: []const u8) !void {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();

        const copied = try arena.allocator().dupe(u8, message);
        self.clearCurrent(allocator);
        self.state = .{ .failed = .{
            .arena = arena,
            .message = if (copied.len > 0) copied else "Unknown diff load error",
        } };
    }

    pub fn replaceEmpty(self: *LoadRuntimeState, allocator: std.mem.Allocator, reason: EmptyReason) void {
        self.clearCurrent(allocator);
        self.state = .{ .empty = reason };
    }

    pub fn clearCurrent(self: *LoadRuntimeState, allocator: ?std.mem.Allocator) void {
        switch (self.state) {
            .loaded => |*session| session.deinit(allocator),
            .failed => |*failed| failed.deinit(),
            .idle, .loading, .empty => {},
        }
        self.state = .idle;
    }

    fn nextGeneration(self: *LoadRuntimeState) u64 {
        self.generation +%= 1;
        return self.generation;
    }

    fn pendingMatches(self: *const LoadRuntimeState, expected: PendingLoad) bool {
        const pending = self.pending orelse return false;
        return std.meta.eql(pending, expected);
    }
};

pub const LoadedSession = struct {
    arena: std.heap.ArenaAllocator,
    loaded: LoadedDiff,
    reviewed_files_owned: bool = false,

    pub fn deinit(self: *LoadedSession, allocator: ?std.mem.Allocator) void {
        if (self.reviewed_files_owned) {
            const owner = allocator orelse @panic("LoadedSession reviewed file slice requires an allocator");
            owner.free(self.loaded.reviewed_files);
        }
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const FailedLoad = struct {
    arena: std.heap.ArenaAllocator,
    message: []const u8,

    pub fn deinit(self: *FailedLoad) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const LoadState = union(enum) {
    idle,
    loading,
    empty: EmptyReason,
    loaded: LoadedSession,
    failed: FailedLoad,
};

pub const EmptyReason = enum {
    no_changes,
    no_repository,
};

test "acceptAuxiliaryLoadResult rejects stale generation and clears matching pending" {
    var pending: ?u64 = 3;

    try std.testing.expectEqual(AuxiliaryLoadAcceptance.stale_generation, acceptAuxiliaryLoadResult(&pending, 4, 3));
    try std.testing.expectEqual(@as(?u64, 3), pending);

    try std.testing.expectEqual(AuxiliaryLoadAcceptance.accepted_pending, acceptAuxiliaryLoadResult(&pending, 3, 3));
    try std.testing.expectEqual(@as(?u64, null), pending);

    try std.testing.expectEqual(AuxiliaryLoadAcceptance.accepted_without_pending, acceptAuxiliaryLoadResult(&pending, 3, 3));
}

test "acceptBranchListResult requires pending state generation and repo match" {
    var pending: ?u64 = null;
    try std.testing.expectEqual(
        BranchListAcceptance.no_pending,
        acceptBranchListResult(&pending, true, 1, "/repo", 1, "/repo"),
    );

    pending = 1;
    try std.testing.expectEqual(
        BranchListAcceptance.stale_pending_generation,
        acceptBranchListResult(&pending, true, 1, "/repo", 2, "/repo"),
    );
    try std.testing.expectEqual(@as(?u64, 1), pending);

    pending = 2;
    try std.testing.expectEqual(
        BranchListAcceptance.missing_state,
        acceptBranchListResult(&pending, false, 2, "/repo", 2, "/repo"),
    );
    try std.testing.expectEqual(@as(?u64, null), pending);

    pending = 3;
    try std.testing.expectEqual(
        BranchListAcceptance.stale_state_generation,
        acceptBranchListResult(&pending, true, 4, "/repo", 3, "/repo"),
    );
    try std.testing.expectEqual(@as(?u64, null), pending);

    pending = 5;
    try std.testing.expectEqual(
        BranchListAcceptance.repo_mismatch,
        acceptBranchListResult(&pending, true, 5, "/repo", 5, "/other"),
    );
    try std.testing.expectEqual(@as(?u64, null), pending);

    pending = 8;
    try std.testing.expectEqual(
        BranchListAcceptance.accepted,
        acceptBranchListResult(&pending, true, 8, "/repo", 8, "/repo"),
    );
    try std.testing.expectEqual(@as(?u64, null), pending);
}
