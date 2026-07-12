const std = @import("std");
const diff_hunk_projection = @import("../diff/hunk_projection.zig");
const app_load = @import("load.zig");
const page = @import("page.zig");

pub const max_generated_file_bytes = 1024 * 1024;
pub const max_cached_entries = 4;
pub const max_cached_retained_bytes = 32 * 1024 * 1024;

pub const Kind = enum {
    cached_diff,
    generated_added_file,
    combined_hunks,
};

pub const SourceKind = enum {
    unstaged,
    cached,
    other,
};

pub const Request = struct {
    identity: page.RequestIdentity,
    id: u64,
    repo_root: []u8,
    path_key: []u8,
    kind: Kind,
    source_kind: SourceKind,
    source_session_revision: u64,
    status_snapshot_revision: u64,

    pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        allocator.free(self.path_key);
        self.* = undefined;
    }

    pub fn matchesBorrowed(self: Request, repo_root: []const u8, path_key: []const u8, kind: Kind, source_kind: SourceKind, source_session_revision: u64, status_snapshot_revision: u64) bool {
        return self.kind == kind and
            self.source_kind == source_kind and
            self.source_session_revision == source_session_revision and
            self.status_snapshot_revision == status_snapshot_revision and
            std.mem.eql(u8, self.repo_root, repo_root) and
            std.mem.eql(u8, self.path_key, path_key);
    }

    pub fn matchesDisplayIdentity(self: Request, repo_root: []const u8, path_key: []const u8, source_kind: SourceKind, source_session_revision: u64) bool {
        return self.source_kind == source_kind and
            self.source_session_revision == source_session_revision and
            std.mem.eql(u8, self.repo_root, repo_root) and
            std.mem.eql(u8, self.path_key, path_key);
    }

    pub fn sameSemanticKey(self: Request, other: Request) bool {
        return self.matchesBorrowed(
            other.repo_root,
            other.path_key,
            other.kind,
            other.source_kind,
            other.source_session_revision,
            other.status_snapshot_revision,
        );
    }

    pub fn matchesAuthority(self: Request, repo_root: []const u8, source_kind: SourceKind, source_session_revision: u64, status_snapshot_revision: u64) bool {
        return self.source_kind == source_kind and
            self.source_session_revision == source_session_revision and
            self.status_snapshot_revision == status_snapshot_revision and
            std.mem.eql(u8, self.repo_root, repo_root);
    }
};

pub const GeneratedFile = struct {
    path: []const u8,
    lines: []const []const u8,
    truncated: bool = false,
};

pub const GeneratedFileBundle = struct {
    arena: ?std.heap.ArenaAllocator,
    file: GeneratedFile,

    pub fn deinit(self: *GeneratedFileBundle) void {
        if (self.arena) |*arena| arena.deinit();
        self.arena = null;
        self.file = undefined;
    }
};

pub const CombinedHunkBundle = struct {
    arena: ?std.heap.ArenaAllocator,
    projection: diff_hunk_projection.Projection,
    cached_bundle: app_load.LoadedDiffBundle,
    unstaged_bundle: app_load.LoadedDiffBundle,

    pub fn deinit(self: *CombinedHunkBundle) void {
        if (self.arena) |*arena| arena.deinit();
        self.arena = null;
        self.cached_bundle.deinit();
        self.unstaged_bundle.deinit();
        self.projection = undefined;
    }
};

pub const StatusBody = struct {
    path: []u8,
    message: []u8,

    pub fn deinit(self: *StatusBody, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub const Ready = union(enum) {
    cached_diff: app_load.LoadedDiffBundle,
    generated_added_file: GeneratedFileBundle,
    combined_hunks: CombinedHunkBundle,
    status_body: StatusBody,

    pub fn deinit(self: *Ready, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .cached_diff => |*bundle| bundle.deinit(),
            .generated_added_file => |*bundle| bundle.deinit(),
            .combined_hunks => |*bundle| bundle.deinit(),
            .status_body => |*body| body.deinit(allocator),
        }
        self.* = undefined;
    }

    pub fn cacheable(self: Ready) bool {
        return switch (self) {
            .cached_diff, .generated_added_file, .combined_hunks => true,
            .status_body => false,
        };
    }

    fn retainedBytes(self: Ready) usize {
        return switch (self) {
            .cached_diff => |bundle| arenaCapacity(bundle.arena),
            .generated_added_file => |bundle| arenaCapacity(bundle.arena),
            .combined_hunks => |bundle| saturatedSum(&.{
                arenaCapacity(bundle.arena),
                arenaCapacity(bundle.cached_bundle.arena),
                arenaCapacity(bundle.unstaged_bundle.arena),
            }),
            .status_body => 0,
        };
    }
};

pub const TaskResult = union(enum) {
    ready: Ready,
    failed: StatusBody,
    failed_static: []const u8,

    pub fn deinit(self: *TaskResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ready => |*ready| ready.deinit(allocator),
            .failed => |*body| body.deinit(allocator),
            .failed_static => {},
        }
        self.* = undefined;
    }
};

pub const Finished = struct {
    request: Request,
    result: TaskResult,

    pub fn deinit(self: *Finished, allocator: std.mem.Allocator) void {
        self.request.deinit(allocator);
        self.result.deinit(allocator);
    }
};

pub const ReadyDisplay = struct {
    request: Request,
    value: Ready,

    pub fn deinit(self: *ReadyDisplay, allocator: std.mem.Allocator) void {
        self.request.deinit(allocator);
        self.value.deinit(allocator);
        self.* = undefined;
    }

    fn retainedBytes(self: ReadyDisplay) usize {
        std.debug.assert(self.value.cacheable());
        return saturatedSum(&.{
            @sizeOf(CacheEntry),
            self.request.repo_root.len,
            self.request.path_key.len,
            self.value.retainedBytes(),
        });
    }
};

pub const Displayed = union(enum) {
    idle,
    ready: ReadyDisplay,
    failed: struct {
        request: Request,
        body: StatusBody,
    },

    pub fn deinit(self: *Displayed, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .idle => {},
            .ready => |*ready| ready.deinit(allocator),
            .failed => |*failed| {
                failed.request.deinit(allocator);
                failed.body.deinit(allocator);
            },
        }
        self.* = .idle;
    }

    pub fn request(self: *const Displayed) ?*const Request {
        return switch (self.*) {
            .idle => null,
            .ready => |*ready| &ready.request,
            .failed => |*failed| &failed.request,
        };
    }
};

const CacheEntry = struct {
    projection: ReadyDisplay,
    /// Measured once at admission. Cached projections are immutable, so this
    /// remains stable until promotion, invalidation, eviction, or deinit.
    retained_bytes: usize,

    fn deinit(self: *CacheEntry, allocator: std.mem.Allocator) void {
        self.projection.deinit(allocator);
        self.* = undefined;
    }
};

const Cache = struct {
    /// Oldest entry is at index zero; successful admission appends the MRU.
    entries: std.ArrayList(CacheEntry) = .empty,
    retained_bytes: usize = 0,

    fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(allocator);
        self.entries.deinit(allocator);
        self.* = .{};
    }

    fn hasMatching(
        self: *const Cache,
        repo_root: []const u8,
        path_key: []const u8,
        kind: Kind,
        source_kind: SourceKind,
        source_session_revision: u64,
        status_snapshot_revision: u64,
    ) bool {
        return self.matchingIndex(repo_root, path_key, kind, source_kind, source_session_revision, status_snapshot_revision) != null;
    }

    fn takeMatching(
        self: *Cache,
        repo_root: []const u8,
        path_key: []const u8,
        kind: Kind,
        source_kind: SourceKind,
        source_session_revision: u64,
        status_snapshot_revision: u64,
    ) ?ReadyDisplay {
        const index = self.matchingIndex(repo_root, path_key, kind, source_kind, source_session_revision, status_snapshot_revision) orelse return null;
        var entry = self.entries.orderedRemove(index);
        self.retained_bytes -|= entry.retained_bytes;
        const projection = entry.projection;
        entry = undefined;
        return projection;
    }

    fn matchingIndex(
        self: *const Cache,
        repo_root: []const u8,
        path_key: []const u8,
        kind: Kind,
        source_kind: SourceKind,
        source_session_revision: u64,
        status_snapshot_revision: u64,
    ) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (entry.projection.request.matchesBorrowed(
                repo_root,
                path_key,
                kind,
                source_kind,
                source_session_revision,
                status_snapshot_revision,
            )) return index;
        }
        return null;
    }

    fn admit(self: *Cache, allocator: std.mem.Allocator, projection: ReadyDisplay) void {
        self.admitWithLimits(allocator, projection, max_cached_entries, max_cached_retained_bytes);
    }

    fn admitWithLimits(
        self: *Cache,
        allocator: std.mem.Allocator,
        projection: ReadyDisplay,
        entry_limit: usize,
        byte_limit: usize,
    ) void {
        var candidate = projection;
        var candidate_owned = true;
        defer if (candidate_owned) candidate.deinit(allocator);

        if (!candidate.value.cacheable() or entry_limit == 0) return;
        const retained_bytes = candidate.retainedBytes();
        if (retained_bytes > byte_limit) return;

        if (self.equalKeyIndex(candidate.request)) |index| self.evictAt(allocator, index);
        while (self.entries.items.len >= entry_limit or self.retained_bytes +| retained_bytes > byte_limit) {
            std.debug.assert(self.entries.items.len > 0);
            self.evictAt(allocator, 0);
        }

        self.entries.append(allocator, .{
            .projection = candidate,
            .retained_bytes = retained_bytes,
        }) catch return;
        self.retained_bytes += retained_bytes;
        candidate_owned = false;
    }

    fn equalKeyIndex(self: *const Cache, request: Request) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (entry.projection.request.sameSemanticKey(request)) return index;
        }
        return null;
    }

    fn evictAt(self: *Cache, allocator: std.mem.Allocator, index: usize) void {
        var entry = self.entries.orderedRemove(index);
        self.retained_bytes -|= entry.retained_bytes;
        entry.deinit(allocator);
    }
};

pub const State = struct {
    displayed: Displayed = .idle,
    pending: ?Request = null,
    cache: Cache = .{},

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.clearPending(allocator);
        self.displayed.deinit(allocator);
        self.cache.deinit(allocator);
    }

    pub fn clearPending(self: *State, allocator: std.mem.Allocator) void {
        if (self.pending) |*request| request.deinit(allocator);
        self.pending = null;
    }

    pub fn clearDisplayed(self: *State, allocator: std.mem.Allocator) void {
        self.displayed.deinit(allocator);
    }

    pub fn clearCache(self: *State, allocator: std.mem.Allocator) void {
        self.cache.deinit(allocator);
    }

    pub fn isEmpty(self: *const State) bool {
        return self.pending == null and self.displayed.request() == null and self.cache.entries.items.len == 0;
    }

    pub fn cacheLen(self: *const State) usize {
        return self.cache.entries.items.len;
    }

    pub fn cacheRetainedBytes(self: *const State) usize {
        return self.cache.retained_bytes;
    }

    pub fn cacheHas(
        self: *const State,
        repo_root: []const u8,
        path_key: []const u8,
        kind: Kind,
        source_kind: SourceKind,
        source_session_revision: u64,
        status_snapshot_revision: u64,
    ) bool {
        return self.cache.hasMatching(repo_root, path_key, kind, source_kind, source_session_revision, status_snapshot_revision);
    }

    pub fn takeCached(
        self: *State,
        repo_root: []const u8,
        path_key: []const u8,
        kind: Kind,
        source_kind: SourceKind,
        source_session_revision: u64,
        status_snapshot_revision: u64,
    ) ?ReadyDisplay {
        return self.cache.takeMatching(repo_root, path_key, kind, source_kind, source_session_revision, status_snapshot_revision);
    }

    /// Moves the current display to the bounded cache only when it remains
    /// reusable under the current Review authority. Failed/status displays and
    /// old-revision values are deinitialized instead.
    pub fn cacheOrClearDisplayed(
        self: *State,
        allocator: std.mem.Allocator,
        repo_root: []const u8,
        source_kind: SourceKind,
        source_session_revision: u64,
        status_snapshot_revision: u64,
    ) void {
        var previous = self.displayed;
        self.displayed = .idle;
        switch (previous) {
            .idle => {},
            .ready => |ready| {
                if (ready.request.matchesAuthority(repo_root, source_kind, source_session_revision, status_snapshot_revision)) {
                    self.cache.admit(allocator, ready);
                } else {
                    var owned = ready;
                    owned.deinit(allocator);
                }
            },
            .failed => |*failed| {
                failed.request.deinit(allocator);
                failed.body.deinit(allocator);
            },
        }
        previous = undefined;
    }

    pub fn installReady(self: *State, ready: ReadyDisplay) void {
        std.debug.assert(switch (self.displayed) {
            .idle => true,
            else => false,
        });
        self.displayed = .{ .ready = ready };
    }

    pub fn hasPending(self: State) bool {
        return self.pending != null;
    }

    pub fn hasDisplayed(self: *const State) bool {
        return self.displayed.request() != null;
    }

    pub fn pendingMatches(self: State, repo_root: []const u8, path_key: []const u8, kind: Kind, source_kind: SourceKind, source_session_revision: u64, status_snapshot_revision: u64) bool {
        const request = self.pending orelse return false;
        return request.matchesBorrowed(repo_root, path_key, kind, source_kind, source_session_revision, status_snapshot_revision);
    }

    pub fn displayedMatches(self: *const State, repo_root: []const u8, path_key: []const u8, kind: Kind, source_kind: SourceKind, source_session_revision: u64, status_snapshot_revision: u64) bool {
        const request = self.displayed.request() orelse return false;
        return request.matchesBorrowed(repo_root, path_key, kind, source_kind, source_session_revision, status_snapshot_revision);
    }
};

fn arenaCapacity(arena: ?std.heap.ArenaAllocator) usize {
    return if (arena) |owned| owned.queryCapacity() else 0;
}

fn saturatedSum(values: []const usize) usize {
    var total: usize = 0;
    for (values) |value| total +|= value;
    return total;
}

pub fn cloneRequest(
    allocator: std.mem.Allocator,
    identity: page.RequestIdentity,
    id: u64,
    repo_root: []const u8,
    path_key: []const u8,
    kind: Kind,
    source_kind: SourceKind,
    source_session_revision: u64,
    status_snapshot_revision: u64,
) !Request {
    const owned_root = try allocator.dupe(u8, repo_root);
    errdefer allocator.free(owned_root);
    const owned_path = try allocator.dupe(u8, path_key);
    return .{
        .identity = identity,
        .id = id,
        .repo_root = owned_root,
        .path_key = owned_path,
        .kind = kind,
        .source_kind = source_kind,
        .source_session_revision = source_session_revision,
        .status_snapshot_revision = status_snapshot_revision,
    };
}

pub fn statusBodyAlloc(allocator: std.mem.Allocator, path: []const u8, comptime fmt: []const u8, args: anytype) !StatusBody {
    return .{
        .path = try allocator.dupe(u8, path),
        .message = try std.fmt.allocPrint(allocator, fmt, args),
    };
}

pub fn generatedFileFromContent(allocator: std.mem.Allocator, path: []const u8, content: []const u8, truncated: bool) !GeneratedFileBundle {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    const copied_path = try arena_allocator.dupe(u8, path);
    const copied_content = try arena_allocator.dupe(u8, content);

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(arena_allocator);

    var start: usize = 0;
    while (start < copied_content.len) {
        const end = std.mem.indexOfScalarPos(u8, copied_content, start, '\n') orelse copied_content.len;
        const raw_line = copied_content[start..end];
        const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r') raw_line[0 .. raw_line.len - 1] else raw_line;
        try lines.append(arena_allocator, line);
        start = if (end < copied_content.len) end + 1 else copied_content.len;
    }
    if (copied_content.len == 0) try lines.append(arena_allocator, "");

    return .{
        .arena = arena,
        .file = .{
            .path = copied_path,
            .lines = try lines.toOwnedSlice(arena_allocator),
            .truncated = truncated,
        },
    };
}

test "generated file splits content lines in an owned arena" {
    var bundle = try generatedFileFromContent(std.testing.allocator, "src/new.zig", "one\ntwo\n", false);
    defer bundle.deinit();

    try std.testing.expectEqualStrings("src/new.zig", bundle.file.path);
    try std.testing.expectEqual(@as(usize, 2), bundle.file.lines.len);
    try std.testing.expectEqualStrings("one", bundle.file.lines[0]);
    try std.testing.expectEqualStrings("two", bundle.file.lines[1]);
}

test "request matches semantic projection identity" {
    var request = try cloneRequest(std.testing.allocator, page.RequestIdentity.review(0, 1), 1, "/repo", "src/main.zig", .cached_diff, .unstaged, 10, 20);
    defer request.deinit(std.testing.allocator);

    try std.testing.expect(request.matchesBorrowed("/repo", "src/main.zig", .cached_diff, .unstaged, 10, 20));
    try std.testing.expect(!request.matchesBorrowed("/repo", "src/main.zig", .generated_added_file, .unstaged, 10, 20));
    try std.testing.expect(!request.matchesBorrowed("/repo", "src/main.zig", .cached_diff, .cached, 10, 20));
    try std.testing.expect(!request.matchesBorrowed("/repo", "src/main.zig", .cached_diff, .unstaged, 11, 20));
    try std.testing.expect(!request.matchesBorrowed("/other", "src/main.zig", .cached_diff, .unstaged, 10, 20));
}

test "projection cache promotion re-admission and equal key replacement preserve LRU ownership" {
    const allocator = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(allocator);

    var a = try testGeneratedProjection(allocator, 1, "a", 10, 20);
    const a_lines = a.value.generated_added_file.file.lines.ptr;
    cache.admitWithLimits(allocator, a, 2, max_cached_retained_bytes);
    a = undefined;
    var b = try testGeneratedProjection(allocator, 2, "b", 10, 20);
    cache.admitWithLimits(allocator, b, 2, max_cached_retained_bytes);
    b = undefined;

    var promoted_a = cache.takeMatching("/repo", "a", .generated_added_file, .unstaged, 10, 20) orelse
        return error.ExpectedCacheHit;
    try std.testing.expectEqual(a_lines, promoted_a.value.generated_added_file.file.lines.ptr);
    cache.admitWithLimits(allocator, promoted_a, 2, max_cached_retained_bytes);
    promoted_a = undefined;

    var c = try testGeneratedProjection(allocator, 3, "c", 10, 20);
    cache.admitWithLimits(allocator, c, 2, max_cached_retained_bytes);
    c = undefined;
    try std.testing.expect(!cache.hasMatching("/repo", "b", .generated_added_file, .unstaged, 10, 20));
    try std.testing.expect(cache.hasMatching("/repo", "a", .generated_added_file, .unstaged, 10, 20));
    try std.testing.expect(cache.hasMatching("/repo", "c", .generated_added_file, .unstaged, 10, 20));

    var replacement_a = try testGeneratedProjection(allocator, 4, "a", 10, 20);
    const replacement_lines = replacement_a.value.generated_added_file.file.lines.ptr;
    cache.admitWithLimits(allocator, replacement_a, 2, max_cached_retained_bytes);
    replacement_a = undefined;
    try std.testing.expectEqual(@as(usize, 2), cache.entries.items.len);
    var final_a = cache.takeMatching("/repo", "a", .generated_added_file, .unstaged, 10, 20) orelse
        return error.ExpectedReplacement;
    defer final_a.deinit(allocator);
    try std.testing.expectEqual(replacement_lines, final_a.value.generated_added_file.file.lines.ptr);
}

test "projection cache enforces four entry and retained byte bounds" {
    const allocator = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(allocator);

    for (0..max_cached_entries + 1) |index| {
        var path_buffer: [16]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "file-{d}", .{index});
        var projection = try testGeneratedProjection(allocator, index + 1, path, 10, 20);
        cache.admit(allocator, projection);
        projection = undefined;
    }
    try std.testing.expectEqual(max_cached_entries, cache.entries.items.len);
    try std.testing.expect(!cache.hasMatching("/repo", "file-0", .generated_added_file, .unstaged, 10, 20));
    try std.testing.expect(cache.retained_bytes <= max_cached_retained_bytes);

    var oversized = try testGeneratedProjection(allocator, 20, "oversized", 10, 20);
    const retained_bytes = oversized.retainedBytes();
    cache.admitWithLimits(allocator, oversized, max_cached_entries, retained_bytes - 1);
    oversized = undefined;
    try std.testing.expect(!cache.hasMatching("/repo", "oversized", .generated_added_file, .unstaged, 10, 20));
}

test "projection cache byte pressure evicts LRU below the entry limit" {
    const allocator = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(allocator);

    var a = try testGeneratedProjection(allocator, 1, "a", 10, 20);
    const a_bytes = a.retainedBytes();
    var b = try testGeneratedProjection(allocator, 2, "b", 10, 20);
    const b_bytes = b.retainedBytes();
    var c = try testGeneratedProjection(allocator, 3, "c", 10, 20);
    const byte_limit = a_bytes +| b_bytes;

    cache.admitWithLimits(allocator, a, max_cached_entries, byte_limit);
    a = undefined;
    cache.admitWithLimits(allocator, b, max_cached_entries, byte_limit);
    b = undefined;
    try std.testing.expectEqual(@as(usize, 2), cache.entries.items.len);

    cache.admitWithLimits(allocator, c, max_cached_entries, byte_limit);
    c = undefined;
    try std.testing.expectEqual(@as(usize, 2), cache.entries.items.len);
    try std.testing.expect(!cache.hasMatching("/repo", "a", .generated_added_file, .unstaged, 10, 20));
    try std.testing.expect(cache.hasMatching("/repo", "b", .generated_added_file, .unstaged, 10, 20));
    try std.testing.expect(cache.hasMatching("/repo", "c", .generated_added_file, .unstaged, 10, 20));
    try std.testing.expect(cache.retained_bytes <= byte_limit);
}

test "projection cache rejects status body and cleans metadata allocation failure" {
    const allocator = std.testing.allocator;

    var cache: Cache = .{};
    defer cache.deinit(allocator);
    var status_projection = ReadyDisplay{
        .request = try cloneRequest(allocator, page.RequestIdentity.review(0, 1), 1, "/repo", "status", .cached_diff, .unstaged, 10, 20),
        .value = .{ .status_body = try statusBodyAlloc(allocator, "status", "No staged diff.", .{}) },
    };
    cache.admit(allocator, status_projection);
    status_projection = undefined;
    try std.testing.expectEqual(@as(usize, 0), cache.entries.items.len);

    var projection = try testGeneratedProjection(allocator, 2, "oom", 10, 20);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    cache.admit(failing.allocator(), projection);
    projection = undefined;
    try std.testing.expectEqual(@as(usize, 0), cache.entries.items.len);

    var state: State = .{};
    defer state.deinit(allocator);
    state.displayed = .{ .failed = .{
        .request = try cloneRequest(allocator, page.RequestIdentity.review(0, 1), 3, "/repo", "failed", .cached_diff, .unstaged, 10, 20),
        .body = try statusBodyAlloc(allocator, "failed", "load failed", .{}),
    } };
    state.cacheOrClearDisplayed(allocator, "/repo", .unstaged, 10, 20);
    try std.testing.expect(!state.hasDisplayed());
    try std.testing.expectEqual(@as(usize, 0), state.cacheLen());
}

test "projection cache retained bytes include every cacheable arena" {
    const allocator = std.testing.allocator;

    var cached_arena: std.heap.ArenaAllocator = .init(allocator);
    _ = try cached_arena.allocator().alloc(u8, 1024);
    const cached_capacity = cached_arena.queryCapacity();
    var cached = ReadyDisplay{
        .request = try cloneRequest(allocator, page.RequestIdentity.review(0, 1), 1, "/repo", "cached", .cached_diff, .unstaged, 1, 2),
        .value = .{ .cached_diff = .{ .arena = cached_arena, .loaded = undefined } },
    };
    cached_arena = undefined;
    try std.testing.expect(cached.retainedBytes() >= cached_capacity);
    cached.deinit(allocator);

    var projection_arena: std.heap.ArenaAllocator = .init(allocator);
    var staged_arena: std.heap.ArenaAllocator = .init(allocator);
    var unstaged_arena: std.heap.ArenaAllocator = .init(allocator);
    _ = try projection_arena.allocator().alloc(u8, 512);
    _ = try staged_arena.allocator().alloc(u8, 1024);
    _ = try unstaged_arena.allocator().alloc(u8, 2048);
    const combined_capacity = saturatedSum(&.{
        projection_arena.queryCapacity(),
        staged_arena.queryCapacity(),
        unstaged_arena.queryCapacity(),
    });
    var combined = ReadyDisplay{
        .request = try cloneRequest(allocator, page.RequestIdentity.review(0, 1), 2, "/repo", "combined", .combined_hunks, .unstaged, 1, 2),
        .value = .{ .combined_hunks = .{
            .arena = projection_arena,
            .projection = undefined,
            .cached_bundle = .{ .arena = staged_arena, .loaded = undefined },
            .unstaged_bundle = .{ .arena = unstaged_arena, .loaded = undefined },
        } },
    };
    projection_arena = undefined;
    staged_arena = undefined;
    unstaged_arena = undefined;
    try std.testing.expect(combined.retainedBytes() >= combined_capacity);
    combined.deinit(allocator);
}

fn testGeneratedProjection(
    allocator: std.mem.Allocator,
    id: usize,
    path: []const u8,
    source_session_revision: u64,
    status_snapshot_revision: u64,
) !ReadyDisplay {
    var request = try cloneRequest(
        allocator,
        page.RequestIdentity.review(0, 1),
        id,
        "/repo",
        path,
        .generated_added_file,
        .unstaged,
        source_session_revision,
        status_snapshot_revision,
    );
    errdefer request.deinit(allocator);
    return .{
        .request = request,
        .value = .{ .generated_added_file = try generatedFileFromContent(allocator, path, "one\ntwo\n", false) },
    };
}
