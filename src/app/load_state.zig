const std = @import("std");
const loaded_diff = @import("../loaded_diff.zig");

const LoadedDiff = loaded_diff.LoadedDiff;

pub const BranchListAcceptance = enum {
    accepted,
    no_pending,
    stale_pending_generation,
    missing_state,
    stale_state_generation,
    repo_mismatch,
};

pub const StatusSnapshotReplaceDecision = enum {
    replace_action_cursor,
    replace_pending_initial_selection,
    replace_no_snapshot,
    replace_root_mismatch,
    replace_changed,
    skip_identical,
};

pub const PendingReloadConsumptionDecision = enum {
    no_pending_reload,
    preserve_generation_mismatch,
    consume_generation_match,
};

pub const WatchReloadRebuildDecision = enum {
    rebuild_not_watch,
    rebuild_no_current_loaded,
    rebuild_text_changed,
    skip_rebuild_identical_text,
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
    if (!state_has_value) return .missing_state;
    if (state_generation != result_generation) return .stale_state_generation;
    if (!std.mem.eql(u8, state_repo_root, result_repo_root)) return .repo_mismatch;
    pending.* = null;
    return .accepted;
}

/// Decide whether a freshly loaded status snapshot may skip replacement.
///
/// App still owns when this check runs and the mutation that follows. This
/// helper only names the reasons so status refresh behavior is auditable without
/// importing the Git status model into load_state.zig.
pub fn statusSnapshotReplaceDecision(
    has_action_cursor: bool,
    pending_initial_first_visible_selection: bool,
    current_repo_root: ?[]const u8,
    result_repo_root: []const u8,
    documents_equal: bool,
) StatusSnapshotReplaceDecision {
    if (has_action_cursor) return .replace_action_cursor;
    if (pending_initial_first_visible_selection) return .replace_pending_initial_selection;
    const root = current_repo_root orelse return .replace_no_snapshot;
    if (!std.mem.eql(u8, root, result_repo_root)) return .replace_root_mismatch;
    if (!documents_equal) return .replace_changed;
    return .skip_identical;
}

/// Decide whether App may transfer ownership of pending reload metadata.
///
/// The decision lives here so generation-match policy has one implementation.
/// The actual `PendingReload` value stays in App because it owns allocator-backed
/// anchor state and visible restoration context.
pub fn pendingReloadConsumption(
    pending_generation: ?u64,
    result_generation: u64,
) PendingReloadConsumptionDecision {
    const generation = pending_generation orelse return .no_pending_reload;
    if (generation != result_generation) return .preserve_generation_mismatch;
    return .consume_generation_match;
}

/// Decide whether an accepted loaded diff result should rebuild the session.
///
/// App computes text equality and performs any visible mutation. A non-consumed
/// pending reload is represented as `consumed_pending_is_watch = false`, keeping
/// this helper independent of Changes-owned `ReloadKind` and `PendingReload`.
pub fn watchReloadRebuildDecision(
    consumed_pending_is_watch: bool,
    has_current_loaded: bool,
    texts_equal: bool,
) WatchReloadRebuildDecision {
    if (!consumed_pending_is_watch) return .rebuild_not_watch;
    if (!has_current_loaded) return .rebuild_no_current_loaded;
    if (!texts_equal) return .rebuild_text_changed;
    return .skip_rebuild_identical_text;
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

    /// Invalidates an outstanding source read after a repository commitment.
    /// The task still owns and eventually frees its result, but its generation
    /// can no longer mutate the newly committed repository session.
    pub fn supersedePending(self: *LoadRuntimeState) void {
        if (self.pending == null) return;
        _ = self.nextGeneration();
        self.pending = null;
    }

    pub fn replaceLoaded(self: *LoadRuntimeState, allocator: std.mem.Allocator, session: LoadedSession) void {
        self.clearCurrent(allocator);
        self.state = .{ .loaded = session };
    }

    pub fn replaceFailed(self: *LoadRuntimeState, allocator: std.mem.Allocator, message: []const u8) !void {
        var failed = try FailedLoad.init(allocator, message);
        self.clearCurrent(allocator);
        self.installPreparedFailed(&failed);
    }

    /// Commit an already allocated failure after a higher-level owner has
    /// completed every clear-before-free transition for the previous state.
    pub fn installPreparedFailed(self: *LoadRuntimeState, failed: *FailedLoad) void {
        std.debug.assert(self.state == .idle);
        self.state = .{ .failed = failed.* };
        failed.* = undefined;
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

    pub fn init(allocator: std.mem.Allocator, message: []const u8) !FailedLoad {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();
        const copied = try arena.allocator().dupe(u8, message);
        return .{
            .arena = arena,
            .message = if (copied.len > 0) copied else "Unknown diff load error",
        };
    }

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
    try std.testing.expectEqual(@as(?u64, 2), pending);

    pending = 3;
    try std.testing.expectEqual(
        BranchListAcceptance.stale_state_generation,
        acceptBranchListResult(&pending, true, 4, "/repo", 3, "/repo"),
    );
    try std.testing.expectEqual(@as(?u64, 3), pending);

    pending = 5;
    try std.testing.expectEqual(
        BranchListAcceptance.repo_mismatch,
        acceptBranchListResult(&pending, true, 5, "/repo", 5, "/other"),
    );
    try std.testing.expectEqual(@as(?u64, 5), pending);

    pending = 8;
    try std.testing.expectEqual(
        BranchListAcceptance.accepted,
        acceptBranchListResult(&pending, true, 8, "/repo", 8, "/repo"),
    );
    try std.testing.expectEqual(@as(?u64, null), pending);
}

test "statusSnapshotReplaceDecision names every replace and skip reason" {
    try std.testing.expectEqual(
        StatusSnapshotReplaceDecision.replace_action_cursor,
        statusSnapshotReplaceDecision(true, false, "/repo", "/repo", true),
    );
    try std.testing.expectEqual(
        StatusSnapshotReplaceDecision.replace_pending_initial_selection,
        statusSnapshotReplaceDecision(false, true, "/repo", "/repo", true),
    );
    try std.testing.expectEqual(
        StatusSnapshotReplaceDecision.replace_no_snapshot,
        statusSnapshotReplaceDecision(false, false, null, "/repo", true),
    );
    try std.testing.expectEqual(
        StatusSnapshotReplaceDecision.replace_root_mismatch,
        statusSnapshotReplaceDecision(false, false, "/other", "/repo", true),
    );
    try std.testing.expectEqual(
        StatusSnapshotReplaceDecision.replace_changed,
        statusSnapshotReplaceDecision(false, false, "/repo", "/repo", false),
    );
    try std.testing.expectEqual(
        StatusSnapshotReplaceDecision.skip_identical,
        statusSnapshotReplaceDecision(false, false, "/repo", "/repo", true),
    );
}

test "pendingReloadConsumption preserves ownership unless generations match" {
    try std.testing.expectEqual(
        PendingReloadConsumptionDecision.no_pending_reload,
        pendingReloadConsumption(null, 3),
    );
    try std.testing.expectEqual(
        PendingReloadConsumptionDecision.preserve_generation_mismatch,
        pendingReloadConsumption(2, 3),
    );
    try std.testing.expectEqual(
        PendingReloadConsumptionDecision.consume_generation_match,
        pendingReloadConsumption(3, 3),
    );
}

test "watchReloadRebuildDecision skips only consumed watch reload with identical text" {
    try std.testing.expectEqual(
        WatchReloadRebuildDecision.rebuild_not_watch,
        watchReloadRebuildDecision(false, true, true),
    );
    try std.testing.expectEqual(
        WatchReloadRebuildDecision.rebuild_no_current_loaded,
        watchReloadRebuildDecision(true, false, true),
    );
    try std.testing.expectEqual(
        WatchReloadRebuildDecision.rebuild_text_changed,
        watchReloadRebuildDecision(true, true, false),
    );
    try std.testing.expectEqual(
        WatchReloadRebuildDecision.skip_rebuild_identical_text,
        watchReloadRebuildDecision(true, true, true),
    );
}
