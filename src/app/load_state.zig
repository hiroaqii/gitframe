const std = @import("std");
const loaded_diff = @import("../loaded_diff.zig");

const LoadedDiff = loaded_diff.LoadedDiff;

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
