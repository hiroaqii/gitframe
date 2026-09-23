//! History preview request authority, single-flight state, and bounded cache.

const std = @import("std");
const app_page = @import("../../page.zig");
const commit_diff = @import("../../../git/commit_diff.zig");
const git_history = @import("../../../git/history.zig");
const git_preview = @import("../../../git/history_preview.zig");
const path_key = @import("../../../path_key.zig");
const root_capability = @import("../../../repo/root_capability.zig");

pub const cache_entry_limit: usize = 16;
pub const cache_payload_limit: usize = 32 * 1024 * 1024;

/// Generation-free identity for data that can move through the inactive LRU.
pub const CacheIdentity = struct {
    page: app_page.RequestIdentity,
    root: root_capability.Identity,
    catalog_instance: u64,
    selection: git_preview.SelectionSummary,

    pub fn eql(left: CacheIdentity, right: CacheIdentity) bool {
        return std.meta.eql(left.page, right.page) and
            left.root.eql(right.root) and
            left.catalog_instance == right.catalog_instance and
            std.meta.eql(left.selection, right.selection);
    }
};

/// Exact current-generation publication authority.
pub const RequestKey = struct {
    identity: CacheIdentity,
    generation: u64,

    pub fn eql(left: RequestKey, right: RequestKey) bool {
        return left.generation == right.generation and left.identity.eql(right.identity);
    }
};

pub const CopyAuthority = struct {
    selection_generation: u64,
    copy_generation: u64,
};

pub const LatestRequest = struct {
    key: RequestKey,
    request: git_history.SelectionRequest,
};

/// A debounce worker carries no selection request or repository descriptor.
pub const DebounceStamp = struct {
    page: app_page.RequestIdentity,
    root: root_capability.Identity,
    catalog_instance: u64,
    generation: u64,

    pub fn eql(left: DebounceStamp, right: DebounceStamp) bool {
        return std.meta.eql(left.page, right.page) and
            left.root.eql(right.root) and
            left.catalog_instance == right.catalog_instance and
            left.generation == right.generation;
    }

    fn matchesIdentity(self: DebounceStamp, identity: CacheIdentity) bool {
        return std.meta.eql(self.page, identity.page) and
            self.root.eql(identity.root) and
            self.catalog_instance == identity.catalog_instance;
    }
};

pub const Accepted = struct {
    key: RequestKey,
    payload: git_preview.PreviewPayload,
};

pub const Phase = union(enum) {
    idle,
    loading,
    resolved,
    terminal: git_preview.SelectionAdmissionTerminal,
};

pub const Active = union(enum) {
    none,
    debounce: DebounceStamp,
    reader: RequestKey,
};

pub const QueueOutcome = enum {
    unchanged,
    cache_hit,
    queued,
    start_debounce,
};

pub const DebounceResult = union(enum) {
    elapsed,
    failed: git_preview.FailureReason,
};

pub const DebounceOutcome = union(enum) {
    discarded,
    settled,
    start_debounce,
    start_reader: LatestRequest,
};

pub const ReaderOutcome = enum {
    discarded,
    settled,
    start_debounce,
};

const CacheEntry = struct {
    identity: CacheIdentity,
    payload: git_preview.PreviewPayload,
    bytes: usize,
};

const Cache = struct {
    /// Entries are contiguous and most-recent-first.
    entries: [cache_entry_limit]?CacheEntry = .{null} ** cache_entry_limit,
    len: usize = 0,
    payload_bytes: usize = 0,

    fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        while (self.len > 0) {
            var entry = self.removeAt(self.len - 1);
            entry.payload.deinit(allocator);
        }
        self.* = .{};
    }

    fn take(self: *Cache, identity: CacheIdentity) ?git_preview.PreviewPayload {
        for (self.entries[0..self.len], 0..) |maybe_entry, index| {
            const entry = maybe_entry.?;
            if (!entry.identity.eql(identity)) continue;
            return self.removeAt(index).payload;
        }
        return null;
    }

    /// Consumes `payload` on every path.
    fn insert(
        self: *Cache,
        allocator: std.mem.Allocator,
        identity: CacheIdentity,
        payload: git_preview.PreviewPayload,
    ) void {
        var owned = payload;
        if (!payloadCacheable(&owned)) {
            owned.deinit(allocator);
            return;
        }
        const bytes = payloadOwnedBytes(&owned);
        if (bytes > cache_payload_limit) {
            owned.deinit(allocator);
            return;
        }

        for (self.entries[0..self.len], 0..) |maybe_entry, index| {
            if (!maybe_entry.?.identity.eql(identity)) continue;
            var old = self.removeAt(index);
            old.payload.deinit(allocator);
            break;
        }
        while (self.len == cache_entry_limit or bytes > cache_payload_limit - self.payload_bytes) {
            var evicted = self.removeAt(self.len - 1);
            evicted.payload.deinit(allocator);
        }
        var index = self.len;
        while (index > 0) : (index -= 1) self.entries[index] = self.entries[index - 1];
        self.entries[0] = .{
            .identity = identity,
            .payload = owned,
            .bytes = bytes,
        };
        self.len += 1;
        self.payload_bytes += bytes;
        self.assertValid();
    }

    fn removeAt(self: *Cache, index: usize) CacheEntry {
        std.debug.assert(index < self.len);
        const removed = self.entries[index].?;
        var cursor = index;
        while (cursor + 1 < self.len) : (cursor += 1) {
            self.entries[cursor] = self.entries[cursor + 1];
        }
        self.len -= 1;
        self.entries[self.len] = null;
        self.payload_bytes -= removed.bytes;
        self.assertValid();
        return removed;
    }

    fn assertValid(self: *const Cache) void {
        std.debug.assert(self.len <= cache_entry_limit);
        std.debug.assert(self.payload_bytes <= cache_payload_limit);
        for (self.entries[0..self.len]) |entry| std.debug.assert(entry != null);
        for (self.entries[self.len..]) |entry| std.debug.assert(entry == null);
    }
};

pub const State = struct {
    catalog_instance: u64 = 0,
    request_generation: u64 = 0,
    debounce_generation: u64 = 0,
    copy_generation: u64 = 0,
    current_key: ?RequestKey = null,
    latest: ?LatestRequest = null,
    active: Active = .none,
    accepted: ?Accepted = null,
    phase: Phase = .idle,
    cache: Cache = .{},
    /// Needed only because page deactivation intentionally has no allocator
    /// parameter. It is set while accepted/cache owns reader allocations.
    payload_allocator: ?std.mem.Allocator = null,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.clearPayloads(allocator);
        self.* = .{};
    }

    /// Revoke visible/current authority while allowing one finite in-flight
    /// worker to complete and be rejected by its old key.
    pub fn invalidate(self: *State, allocator: std.mem.Allocator) void {
        self.clearPayloads(allocator);
        self.current_key = null;
        self.latest = null;
        self.phase = .idle;
    }

    pub fn deactivate(self: *State) void {
        if (self.payload_allocator) |allocator| {
            self.clearPayloads(allocator);
        } else {
            std.debug.assert(self.accepted == null and self.cache.len == 0);
        }
        self.current_key = null;
        self.latest = null;
        self.phase = .idle;
    }

    pub fn catalogPublished(self: *State, allocator: std.mem.Allocator) void {
        self.invalidate(allocator);
        self.catalog_instance +%= 1;
        if (self.catalog_instance == 0) self.catalog_instance = 1;
    }

    pub fn clearSelection(self: *State, allocator: std.mem.Allocator) void {
        self.retireAccepted(allocator);
        self.current_key = null;
        self.latest = null;
        self.phase = .idle;
    }

    /// Queue one resolver-produced request. The caller supplies the descriptive
    /// summary used only for identity; the reader later derives it independently.
    pub fn queue(
        self: *State,
        allocator: std.mem.Allocator,
        identity: CacheIdentity,
        request: git_history.SelectionRequest,
    ) QueueOutcome {
        if (self.current_key) |current| {
            if (current.identity.eql(identity)) return .unchanged;
        }

        self.retireAccepted(allocator);
        self.request_generation +%= 1;
        if (self.request_generation == 0) self.request_generation = 1;
        const key: RequestKey = .{
            .identity = identity,
            .generation = self.request_generation,
        };
        self.current_key = key;
        self.phase = .loading;

        if (self.cache.take(identity)) |payload| {
            self.latest = null;
            self.bindPayloadAllocator(allocator);
            self.accepted = .{ .key = key, .payload = payload };
            self.phase = .resolved;
            return .cache_hit;
        }

        self.latest = .{ .key = key, .request = request };
        return if (self.active == .none) .start_debounce else .queued;
    }

    pub fn reserveDebounce(self: *State) ?DebounceStamp {
        if (self.active != .none) return null;
        const latest = self.latest orelse return null;
        self.debounce_generation +%= 1;
        if (self.debounce_generation == 0) self.debounce_generation = 1;
        return .{
            .page = latest.key.identity.page,
            .root = latest.key.identity.root,
            .catalog_instance = latest.key.identity.catalog_instance,
            .generation = self.debounce_generation,
        };
    }

    pub fn armDebounce(self: *State, stamp: DebounceStamp) void {
        std.debug.assert(self.active == .none);
        std.debug.assert(self.latest != null);
        self.active = .{ .debounce = stamp };
    }

    pub fn rejectDebounceStart(self: *State, stamp: DebounceStamp, reason: git_preview.FailureReason) void {
        const active = switch (self.active) {
            .debounce => |value| value,
            .none, .reader => return,
        };
        if (!active.eql(stamp)) return;
        self.active = .none;
        self.failLatestForStamp(stamp, reason);
    }

    pub fn rejectDebouncePreparation(self: *State, stamp: DebounceStamp, reason: git_preview.FailureReason) void {
        if (self.active != .none) return;
        self.failLatestForStamp(stamp, reason);
    }

    pub fn finishDebounce(
        self: *State,
        stamp: DebounceStamp,
        result: DebounceResult,
    ) DebounceOutcome {
        const active = switch (self.active) {
            .debounce => |value| value,
            .none, .reader => return .discarded,
        };
        if (!active.eql(stamp)) return .discarded;
        self.active = .none;

        switch (result) {
            .failed => |reason| {
                self.failLatestForStamp(stamp, reason);
                return if (self.latest != null) .start_debounce else .settled;
            },
            .elapsed => {},
        }
        const latest = self.latest orelse return .discarded;
        if (!stamp.matchesIdentity(latest.key.identity)) return .start_debounce;
        self.latest = null;
        return .{ .start_reader = latest };
    }

    pub fn armReader(self: *State, key: RequestKey) void {
        std.debug.assert(self.active == .none);
        self.active = .{ .reader = key };
    }

    pub fn rejectReaderStart(self: *State, key: RequestKey, reason: git_preview.FailureReason) void {
        const active = switch (self.active) {
            .reader => |value| value,
            .none, .debounce => return,
        };
        if (!active.eql(key)) return;
        self.active = .none;
        if (self.current_key) |current| {
            if (current.eql(key)) self.phase = .{ .terminal = .{ .failed = reason } };
        }
    }

    /// Consumes a verified payload only when task key, Git-derived summary,
    /// and current exact key all agree. Otherwise the caller retains it for
    /// normal message deinitialization.
    pub fn finishReader(
        self: *State,
        allocator: std.mem.Allocator,
        key: RequestKey,
        result: *git_preview.PreviewReadResult,
    ) ReaderOutcome {
        const active = switch (self.active) {
            .reader => |value| value,
            .none, .debounce => return .discarded,
        };
        if (!active.eql(key)) return .discarded;
        self.active = .none;

        const is_current = if (self.current_key) |current| current.eql(key) else false;
        switch (result.*) {
            .rejected => |terminal| if (is_current) {
                self.phase = .{ .terminal = terminal };
            },
            .verified => |*verified| {
                if (is_current and std.meta.eql(key.identity.selection, verified.summary)) {
                    std.debug.assert(self.accepted == null);
                    const payload = verified.payload;
                    result.* = .{ .rejected = .malformed };
                    self.bindPayloadAllocator(allocator);
                    self.accepted = .{ .key = key, .payload = payload };
                    self.phase = .resolved;
                } else if (is_current) {
                    self.phase = .{ .terminal = .malformed };
                }
            },
        }
        return if (self.latest != null) .start_debounce else if (is_current) .settled else .discarded;
    }

    pub fn activeCount(self: *const State) usize {
        return @intFromBool(self.active != .none);
    }

    pub fn latestCount(self: *const State) usize {
        return @intFromBool(self.latest != null);
    }

    pub fn cacheEntryCount(self: *const State) usize {
        return self.cache.len;
    }

    pub fn cachePayloadBytes(self: *const State) usize {
        return self.cache.payload_bytes;
    }

    pub fn reserveCopyAuthority(self: *State) ?CopyAuthority {
        const current = self.current_key orelse return null;
        self.copy_generation +%= 1;
        if (self.copy_generation == 0) self.copy_generation = 1;
        return .{
            .selection_generation = current.generation,
            .copy_generation = self.copy_generation,
        };
    }

    pub fn currentCopyAuthority(self: *const State) ?CopyAuthority {
        const current = self.current_key orelse return null;
        return .{
            .selection_generation = current.generation,
            .copy_generation = self.copy_generation,
        };
    }

    fn failLatestForStamp(
        self: *State,
        stamp: DebounceStamp,
        reason: git_preview.FailureReason,
    ) void {
        const latest = self.latest orelse return;
        if (!stamp.matchesIdentity(latest.key.identity)) return;
        self.latest = null;
        if (self.current_key) |current| {
            if (current.eql(latest.key)) self.phase = .{ .terminal = .{ .failed = reason } };
        }
    }

    fn retireAccepted(self: *State, allocator: std.mem.Allocator) void {
        const accepted = self.accepted orelse return;
        std.debug.assert(self.payload_allocator != null);
        std.debug.assert(sameAllocator(self.payload_allocator.?, allocator));
        self.accepted = null;
        self.cache.insert(allocator, accepted.key.identity, accepted.payload);
        self.releasePayloadAllocatorIfEmpty();
    }

    fn bindPayloadAllocator(self: *State, allocator: std.mem.Allocator) void {
        if (self.payload_allocator) |bound| {
            std.debug.assert(sameAllocator(bound, allocator));
        } else {
            self.payload_allocator = allocator;
        }
    }

    fn clearPayloads(self: *State, allocator: std.mem.Allocator) void {
        if (self.payload_allocator) |bound| std.debug.assert(sameAllocator(bound, allocator));
        if (self.accepted) |*accepted| accepted.payload.deinit(allocator);
        self.accepted = null;
        self.cache.deinit(allocator);
        self.payload_allocator = null;
    }

    fn releasePayloadAllocatorIfEmpty(self: *State) void {
        if (self.accepted == null and self.cache.len == 0) self.payload_allocator = null;
    }
};

pub fn summaryForRequest(request: git_history.SelectionRequest, selected_parent_count: u16) git_preview.SelectionSummary {
    return switch (request.intent) {
        .single => |single| .{ .single = .{
            .selected_oid = single.oid,
            .parent_count = selected_parent_count,
            .basis = request.basis,
        } },
        .range => |range| .{ .range = .{
            .count = range.oldest_index - range.newest_index + 1,
            .oldest_oid = range.oldest_oid,
            .newest_oid = range.newest_oid,
            .basis = request.basis,
        } },
    };
}

/// Allocate the width- and viewport-independent clipboard representation for
/// one ready detail value. This formatter owns no clipboard effect; callers
/// decide whether and how to dispatch the returned payload.
pub fn canonicalDetailAlloc(allocator: std.mem.Allocator, detail: git_preview.Detail) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    switch (detail) {
        .single => |single| {
            try out.writer.print("Commit: {s}\nAuthor: {s} <{s}>\nAuthored: ", .{
                single.summary.selected_oid.slice(),
                single.author.name,
                single.author.email,
            });
            try writeTimestamp(&out.writer, single.authored);
            try out.writer.print("\nCommitter: {s} <{s}>\nCommitted: ", .{
                single.committer.name,
                single.committer.email,
            });
            try writeTimestamp(&out.writer, single.committed);
            try out.writer.writeAll("\nBranches: ");
            try writeRefs(&out.writer, single.refs.local_branches);
            try out.writer.writeAll("\nTags: ");
            try writeRefs(&out.writer, single.refs.tags);
            try out.writer.writeAll("\nRemotes: ");
            try writeRefs(&out.writer, single.refs.remote_branches);
            try out.writer.writeAll("\nDiff base: ");
            try writeSingleBasis(&out.writer, single.summary);
            try out.writer.writeAll("\nMessage:\n");
            try out.writer.writeAll(single.message);
        },
        .range => |range| {
            try out.writer.print("Count: {d}\nOldest: {s}\nNewest: {s}\nBefore: ", .{
                range.count,
                range.oldest_oid.slice(),
                range.newest_oid.slice(),
            });
            try writeBefore(&out.writer, range.basis);
            try out.writer.print("\nAfter: {s}", .{range.basis.after.slice()});
        },
    }
    return out.toOwnedSlice();
}

/// Show ordinary paths directly and retain the quoted codec wherever raw
/// text would be unsafe or collide with the rename framing.
pub fn pathFieldAlloc(allocator: std.mem.Allocator, kind: git_preview.FileChangeKind) ![]u8 {
    return switch (kind) {
        .modified, .added, .deleted, .type_changed => |path| pathTokenAlloc(allocator, path, false),
        .renamed => |rename| blk: {
            const old = try pathTokenAlloc(allocator, rename.old, true);
            defer allocator.free(old);
            const new = try pathTokenAlloc(allocator, rename.new, true);
            defer allocator.free(new);
            break :blk try std.fmt.allocPrint(allocator, "old {s} -> new {s}", .{ old, new });
        },
    };
}

fn pathTokenAlloc(allocator: std.mem.Allocator, path: []const u8, rename_framing: bool) ![]u8 {
    if (path_key.isPlainDisplaySafe(path) and
        (!rename_framing or std.mem.indexOf(u8, path, " -> ") == null))
    {
        return allocator.dupe(u8, path);
    }
    return path_key.quotedDisplayAlloc(allocator, path);
}

fn writeRefs(writer: *std.Io.Writer, refs: []const []const u8) !void {
    if (refs.len == 0) return writer.writeAll("—");
    for (refs, 0..) |ref, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.writeAll(ref);
    }
}

fn writeSingleBasis(writer: *std.Io.Writer, summary: git_preview.SingleSummary) !void {
    switch (summary.basis.before) {
        .empty_tree => try writer.writeAll("empty tree"),
        .commit => |before| if (summary.parent_count > 1)
            try writer.print("parent 1/{d} {s}", .{
                summary.parent_count,
                before.slice(),
            })
        else
            try writer.print("parent {s}", .{before.slice()}),
    }
}

fn writeBefore(writer: *std.Io.Writer, basis: commit_diff.Basis) !void {
    switch (basis.before) {
        .commit => |before| try writer.writeAll(before.slice()),
        .empty_tree => {
            const empty = basis.beforeOid();
            try writer.print("empty tree ({s})", .{empty.slice()});
        },
    }
}

fn writeTimestamp(writer: *std.Io.Writer, timestamp: git_preview.Timestamp) !void {
    const offset_seconds = @as(i64, timestamp.offset_minutes) * 60;
    const wall = std.math.add(i64, timestamp.unix_seconds, offset_seconds) catch return error.InvalidTimestamp;
    const seconds_of_day: u32 = @intCast(@mod(wall, 86_400));
    const civil = civilFromDays(@divFloor(wall, 86_400)) orelse return error.InvalidTimestamp;
    try writer.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} {s}", .{
        civil.year,
        civil.month,
        civil.day,
        @divTrunc(seconds_of_day, 3_600),
        @divTrunc(@mod(seconds_of_day, 3_600), 60),
        @mod(seconds_of_day, 60),
        &timestamp.original_offset,
    });
}

const CivilDate = struct { year: u16, month: u8, day: u8 };

fn civilFromDays(days_since_epoch: i64) ?CivilDate {
    const shifted = days_since_epoch + 719_468;
    const era = @divFloor(shifted, 146_097);
    const day_of_era = shifted - era * 146_097;
    const year_of_era = @divFloor(day_of_era - @divFloor(day_of_era, 1_460) +
        @divFloor(day_of_era, 36_524) - @divFloor(day_of_era, 146_096), 365);
    var year = year_of_era + era * 400;
    const day_of_year = day_of_era - (365 * year_of_era + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
    const month_prime = @divFloor(5 * day_of_year + 2, 153);
    const day = day_of_year - @divFloor(153 * month_prime + 2, 5) + 1;
    const month = month_prime + (if (month_prime < 10) @as(i64, 3) else -9);
    year += if (month <= 2) 1 else 0;
    if (year < 1 or year > 9999) return null;
    return .{
        .year = @intCast(year),
        .month = @intCast(month),
        .day = @intCast(day),
    };
}

fn payloadCacheable(payload: *const git_preview.PreviewPayload) bool {
    return payload.detail == .ready and payload.files == .ready;
}

fn payloadOwnedBytes(payload: *const git_preview.PreviewPayload) usize {
    var total: usize = 0;
    switch (payload.detail) {
        .ready => |detail| switch (detail) {
            .single => |single| {
                total = addSize(total, single.author.name.len);
                total = addSize(total, single.author.email.len);
                total = addSize(total, single.committer.name.len);
                total = addSize(total, single.committer.email.len);
                total = addSize(total, single.message.len);
                total = addStringListSize(total, single.refs.local_branches);
                total = addStringListSize(total, single.refs.tags);
                total = addStringListSize(total, single.refs.remote_branches);
            },
            .range => {},
        },
        .too_large, .unavailable, .failed => {},
    }
    switch (payload.files) {
        .ready => |files| {
            total = addSize(total, std.math.mul(usize, files.len, @sizeOf(git_preview.FileChange)) catch return std.math.maxInt(usize));
            for (files) |file| switch (file.kind) {
                .modified, .added, .deleted, .type_changed => |path| total = addSize(total, path.len),
                .renamed => |rename| {
                    total = addSize(total, rename.old.len);
                    total = addSize(total, rename.new.len);
                },
            };
        },
        .too_large, .unavailable, .failed => {},
    }
    return total;
}

fn addStringListSize(total_start: usize, values: []const []const u8) usize {
    var total = addSize(
        total_start,
        std.math.mul(usize, values.len, @sizeOf([]const u8)) catch return std.math.maxInt(usize),
    );
    for (values) |value| total = addSize(total, value.len);
    return total;
}

fn addSize(left: usize, right: usize) usize {
    return std.math.add(usize, left, right) catch std.math.maxInt(usize);
}

fn sameAllocator(left: std.mem.Allocator, right: std.mem.Allocator) bool {
    return left.ptr == right.ptr and left.vtable == right.vtable;
}

test "History preview single-flight keeps only the latest inline request" {
    const allocator = std.testing.allocator;
    var state: State = .{ .catalog_instance = 3 };
    defer state.deinit(allocator);

    const request_a = try testRangeRequest(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "1111111111111111111111111111111111111111",
        "2222222222222222222222222222222222222222",
        "3333333333333333333333333333333333333333",
    );
    const request_b = try testRangeRequest(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "1111111111111111111111111111111111111111",
        "4444444444444444444444444444444444444444",
        "5555555555555555555555555555555555555555",
    );
    const identity_a = testCacheIdentity(request_a, 3);
    const identity_b = testCacheIdentity(request_b, 3);

    try std.testing.expectEqual(QueueOutcome.start_debounce, state.queue(allocator, identity_a, request_a));
    const copy_a = state.reserveCopyAuthority().?;
    try std.testing.expect(std.meta.eql(copy_a, state.currentCopyAuthority().?));
    const stamp = state.reserveDebounce().?;
    state.armDebounce(stamp);
    var input_step: usize = 1;
    while (input_step < 100) : (input_step += 1) {
        const next_identity = if (input_step % 2 == 0) identity_a else identity_b;
        const next_request = if (input_step % 2 == 0) request_a else request_b;
        try std.testing.expectEqual(QueueOutcome.queued, state.queue(allocator, next_identity, next_request));
        try std.testing.expectEqual(@as(usize, 1), state.activeCount());
        try std.testing.expectEqual(@as(usize, 1), state.latestCount());
        try std.testing.expect(state.latest.?.key.identity.eql(next_identity));
        try std.testing.expectEqual(@as(u64, 3), state.latest.?.key.identity.catalog_instance);
    }
    try std.testing.expect(copy_a.selection_generation != state.currentCopyAuthority().?.selection_generation);
    const copy_b = state.reserveCopyAuthority().?;
    try std.testing.expect(copy_b.copy_generation > copy_a.copy_generation);
    try std.testing.expectEqual(@as(usize, 1), state.activeCount());
    try std.testing.expectEqual(@as(usize, 1), state.latestCount());

    const latest_b = switch (state.finishDebounce(stamp, .elapsed)) {
        .start_reader => |latest| latest,
        else => return error.ExpectedPreviewReader,
    };
    try std.testing.expect(latest_b.key.identity.eql(identity_b));
    try std.testing.expectEqual(@as(usize, 0), state.latestCount());
    state.armReader(latest_b.key);

    try std.testing.expectEqual(QueueOutcome.queued, state.queue(allocator, identity_a, request_a));
    var late_b: git_preview.PreviewReadResult = .{ .verified = .{
        .summary = identity_b.selection,
        .payload = readyRangePayload(identity_b.selection),
    } };
    defer late_b.deinit(allocator);
    try std.testing.expectEqual(
        ReaderOutcome.start_debounce,
        state.finishReader(allocator, latest_b.key, &late_b),
    );
    try std.testing.expect(state.accepted == null);
    try std.testing.expect(state.current_key.?.identity.eql(identity_a));
    try std.testing.expect(state.latest.?.key.identity.eql(identity_a));
    try std.testing.expectEqual(@as(usize, 0), state.activeCount());

    const rejected_stamp = state.reserveDebounce().?;
    state.armDebounce(rejected_stamp);
    state.rejectDebounceStart(rejected_stamp, .task_start);
    try std.testing.expectEqual(@as(usize, 0), state.activeCount());
    try std.testing.expectEqual(@as(usize, 0), state.latestCount());
    try std.testing.expect(state.phase == .terminal);
    try std.testing.expect(state.phase.terminal == .failed);

    try std.testing.expectEqual(QueueOutcome.start_debounce, state.queue(allocator, identity_b, request_b));
    const reader_stamp = state.reserveDebounce().?;
    state.armDebounce(reader_stamp);
    const rejected_reader = switch (state.finishDebounce(reader_stamp, .elapsed)) {
        .start_reader => |latest| latest,
        else => return error.ExpectedPreviewReader,
    };
    state.armReader(rejected_reader.key);
    state.rejectReaderStart(rejected_reader.key, .task_start);
    try std.testing.expectEqual(@as(usize, 0), state.activeCount());
    try std.testing.expect(state.phase == .terminal);
    try std.testing.expect(state.phase.terminal == .failed);

    try std.testing.expectEqual(QueueOutcome.start_debounce, state.queue(allocator, identity_a, request_a));
    const retry_stamp = state.reserveDebounce().?;
    state.armDebounce(retry_stamp);
    try std.testing.expectEqual(QueueOutcome.queued, state.queue(allocator, identity_b, request_b));
    const retry_reader = switch (state.finishDebounce(retry_stamp, .elapsed)) {
        .start_reader => |latest| latest,
        else => return error.ExpectedPreviewReader,
    };
    state.armReader(retry_reader.key);
    var retry_result: git_preview.PreviewReadResult = .{ .verified = .{
        .summary = identity_b.selection,
        .payload = readyRangePayload(identity_b.selection),
    } };
    defer retry_result.deinit(allocator);
    try std.testing.expectEqual(
        ReaderOutcome.settled,
        state.finishReader(allocator, retry_reader.key, &retry_result),
    );
    try std.testing.expect(state.accepted.?.key.identity.eql(identity_b));

    try std.testing.expectEqual(QueueOutcome.start_debounce, state.queue(allocator, identity_a, request_a));
    const stale_stamp = state.reserveDebounce().?;
    state.armDebounce(stale_stamp);
    state.catalogPublished(allocator);
    try std.testing.expect(state.currentCopyAuthority() == null);
    var replacement_identity = identity_a;
    replacement_identity.catalog_instance = state.catalog_instance;
    try std.testing.expectEqual(QueueOutcome.queued, state.queue(allocator, replacement_identity, request_a));
    try std.testing.expectEqual(
        DebounceOutcome.start_debounce,
        state.finishDebounce(stale_stamp, .{ .failed = .runtime_abandoned }),
    );
    try std.testing.expect(state.latest.?.key.identity.eql(replacement_identity));
}

test "History preview cache moves ready ownership to a new generation and stays bounded" {
    const allocator = std.testing.allocator;
    var state: State = .{ .catalog_instance = 7 };
    defer state.deinit(allocator);

    const request_a = try testRangeRequest(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "1111111111111111111111111111111111111111",
        "2222222222222222222222222222222222222222",
        "3333333333333333333333333333333333333333",
    );
    const request_b = try testRangeRequest(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "1111111111111111111111111111111111111111",
        "4444444444444444444444444444444444444444",
        "5555555555555555555555555555555555555555",
    );
    const identity_a = testCacheIdentity(request_a, 7);
    const identity_b = testCacheIdentity(request_b, 7);

    const key_a1 = try settleReadyForTest(&state, allocator, identity_a, request_a);
    try std.testing.expectEqual(QueueOutcome.start_debounce, state.queue(allocator, identity_b, request_b));
    try std.testing.expectEqual(@as(usize, 1), state.cacheEntryCount());
    try std.testing.expectEqual(QueueOutcome.cache_hit, state.queue(allocator, identity_a, request_a));
    try std.testing.expect(state.accepted.?.key.generation > key_a1.generation);
    try std.testing.expectEqual(@as(usize, 0), state.cacheEntryCount());
    try std.testing.expectEqual(@as(usize, 0), state.latestCount());
    state.deactivate();
    try std.testing.expect(state.accepted == null);
    try std.testing.expect(state.phase == .idle);

    var bounded: Cache = .{};
    defer bounded.deinit(allocator);
    var index: usize = 0;
    while (index < cache_entry_limit + 1) : (index += 1) {
        var identity = identity_a;
        identity.catalog_instance = index + 1;
        bounded.insert(allocator, identity, readyRangePayload(identity.selection));
    }
    try std.testing.expectEqual(cache_entry_limit, bounded.len);
    try std.testing.expect(bounded.payload_bytes <= cache_payload_limit);
    try std.testing.expectEqual(@as(u64, cache_entry_limit + 1), bounded.entries[0].?.identity.catalog_instance);
    try std.testing.expectEqual(@as(u64, 2), bounded.entries[bounded.len - 1].?.identity.catalog_instance);
    var failed_identity = identity_a;
    failed_identity.catalog_instance = 99;
    bounded.insert(allocator, failed_identity, .{
        .detail = .{ .failed = .git_command },
        .files = .{ .ready = &.{} },
    });
    try std.testing.expectEqual(cache_entry_limit, bounded.len);
    try std.testing.expectEqual(@as(u64, cache_entry_limit + 1), bounded.entries[0].?.identity.catalog_instance);

    const large_message = try allocator.alloc(u8, cache_payload_limit + 1);
    const single_oid = try git_history.ObjectId.parse(
        .sha1,
        "6666666666666666666666666666666666666666",
    );
    const single_summary: git_preview.SingleSummary = .{
        .selected_oid = single_oid,
        .parent_count = 1,
        .basis = .{
            .object_format = .sha1,
            .before = .{ .commit = try git_history.ObjectId.parse(
                .sha1,
                "1111111111111111111111111111111111111111",
            ) },
            .after = single_oid,
        },
    };
    var oversize_cache: Cache = .{};
    defer oversize_cache.deinit(allocator);
    oversize_cache.insert(allocator, .{
        .page = app_page.RequestIdentity.history(7, 11),
        .root = .{ .device = 5, .inode = 9 },
        .catalog_instance = 1,
        .selection = .{ .single = single_summary },
    }, .{
        .detail = .{ .ready = .{ .single = .{
            .summary = single_summary,
            .author = .{ .name = &.{}, .email = &.{} },
            .authored = .{ .unix_seconds = 0, .original_offset = "+0000".*, .offset_minutes = 0 },
            .committer = .{ .name = &.{}, .email = &.{} },
            .committed = .{ .unix_seconds = 0, .original_offset = "+0000".*, .offset_minutes = 0 },
            .refs = .{ .local_branches = &.{}, .tags = &.{}, .remote_branches = &.{} },
            .message = large_message,
        } } },
        .files = .{ .ready = &.{} },
    });
    try std.testing.expectEqual(@as(usize, 0), oversize_cache.len);
}

test "History preview rejects a verified summary mismatch without disturbing a newer latest" {
    const allocator = std.testing.allocator;
    var state: State = .{ .catalog_instance = 5 };
    defer state.deinit(allocator);

    const request = try testRangeRequest(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "1111111111111111111111111111111111111111",
        "2222222222222222222222222222222222222222",
        "3333333333333333333333333333333333333333",
    );
    const identity = testCacheIdentity(request, 5);
    _ = state.queue(allocator, identity, request);
    const stamp = state.reserveDebounce().?;
    state.armDebounce(stamp);
    const latest = switch (state.finishDebounce(stamp, .elapsed)) {
        .start_reader => |value| value,
        else => return error.ExpectedPreviewReader,
    };
    state.armReader(latest.key);

    var wrong_summary = identity.selection;
    wrong_summary.range.count += 1;
    var result: git_preview.PreviewReadResult = .{ .verified = .{
        .summary = wrong_summary,
        .payload = readyRangePayload(wrong_summary),
    } };
    defer result.deinit(allocator);
    try std.testing.expectEqual(
        ReaderOutcome.settled,
        state.finishReader(allocator, latest.key, &result),
    );
    try std.testing.expect(state.accepted == null);
    try std.testing.expect(state.phase == .terminal);
    try std.testing.expect(state.phase.terminal == .malformed);
}

test "History preview canonical detail is exact for single and range" {
    const before = try git_history.ObjectId.parse(.sha1, "1111111111111111111111111111111111111111");
    const after = try git_history.ObjectId.parse(.sha1, "2222222222222222222222222222222222222222");
    const oldest = try git_history.ObjectId.parse(.sha1, "3333333333333333333333333333333333333333");
    const branches = [_][]const u8{ "main", "release" };
    const tags = [_][]const u8{"v1"};
    const single_summary: git_preview.SingleSummary = .{
        .selected_oid = after,
        .parent_count = 2,
        .basis = .{ .object_format = .sha1, .before = .{ .commit = before }, .after = after },
    };
    const single = try canonicalDetailAlloc(std.testing.allocator, .{ .single = .{
        .summary = single_summary,
        .author = .{ .name = "A U Thor", .email = "author@example.com" },
        .authored = .{ .unix_seconds = 0, .original_offset = "+0900".*, .offset_minutes = 540 },
        .committer = .{ .name = "C O M", .email = "commit@example.com" },
        .committed = .{ .unix_seconds = 0, .original_offset = "-0230".*, .offset_minutes = -150 },
        .refs = .{ .local_branches = &branches, .tags = &tags, .remote_branches = &.{} },
        .message = "subject\n\nbody",
    } });
    defer std.testing.allocator.free(single);
    try std.testing.expectEqualStrings(
        "Commit: 2222222222222222222222222222222222222222\n" ++
            "Author: A U Thor <author@example.com>\n" ++
            "Authored: 1970-01-01 09:00:00 +0900\n" ++
            "Committer: C O M <commit@example.com>\n" ++
            "Committed: 1969-12-31 21:30:00 -0230\n" ++
            "Branches: main, release\nTags: v1\nRemotes: —\n" ++
            "Diff base: parent 1/2 1111111111111111111111111111111111111111\n" ++
            "Message:\nsubject\n\nbody",
        single,
    );

    var ordinary_basis: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer ordinary_basis.deinit();
    var ordinary_summary = single_summary;
    ordinary_summary.parent_count = 1;
    try writeSingleBasis(&ordinary_basis.writer, ordinary_summary);
    try std.testing.expectEqualStrings(
        "parent 1111111111111111111111111111111111111111",
        ordinary_basis.written(),
    );

    var root_basis: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer root_basis.deinit();
    var root_summary = single_summary;
    root_summary.parent_count = 0;
    root_summary.basis.before = .empty_tree;
    try writeSingleBasis(&root_basis.writer, root_summary);
    try std.testing.expectEqualStrings("empty tree", root_basis.written());

    const range = try canonicalDetailAlloc(std.testing.allocator, .{ .range = .{
        .count = 3,
        .oldest_oid = oldest,
        .newest_oid = after,
        .basis = .{ .object_format = .sha1, .before = .empty_tree, .after = after },
    } });
    defer std.testing.allocator.free(range);
    try std.testing.expectEqualStrings(
        "Count: 3\nOldest: 3333333333333333333333333333333333333333\n" ++
            "Newest: 2222222222222222222222222222222222222222\n" ++
            "Before: empty tree (4b825dc642cb6eb9a060e54bf8d69288fbee4904)\n" ++
            "After: 2222222222222222222222222222222222222222",
        range,
    );
    try std.testing.expect(std.mem.indexOf(u8, range, "Message") == null);
    try std.testing.expect(std.mem.indexOf(u8, range, "Branches") == null);
}

test "History preview path field keeps quoted rename boundaries unique" {
    const ordinary = try pathFieldAlloc(std.testing.allocator, .{ .modified = "src/topic.txt" });
    defer std.testing.allocator.free(ordinary);
    try std.testing.expectEqualStrings("src/topic.txt", ordinary);

    const single = try pathFieldAlloc(std.testing.allocator, .{ .modified = "src/a -> b\"\\\t\xff" });
    defer std.testing.allocator.free(single);
    try std.testing.expectEqualStrings("\"src/a -> b\\\"\\\\\\t\\xFF\"", single);

    const left_arrow = try pathFieldAlloc(std.testing.allocator, .{ .renamed = .{
        .similarity = 100,
        .old = "a -> b\"\\\t\xff",
        .new = "c",
    } });
    defer std.testing.allocator.free(left_arrow);
    const right_arrow = try pathFieldAlloc(std.testing.allocator, .{ .renamed = .{
        .similarity = 100,
        .old = "a",
        .new = "b -> c\"\\\t\xff",
    } });
    defer std.testing.allocator.free(right_arrow);
    try std.testing.expectEqualStrings("old \"a -> b\\\"\\\\\\t\\xFF\" -> new c", left_arrow);
    try std.testing.expectEqualStrings("old a -> new \"b -> c\\\"\\\\\\t\\xFF\"", right_arrow);
    try std.testing.expect(!std.mem.eql(u8, left_arrow, right_arrow));
}

fn settleReadyForTest(
    state: *State,
    allocator: std.mem.Allocator,
    identity: CacheIdentity,
    request: git_history.SelectionRequest,
) !RequestKey {
    try std.testing.expectEqual(QueueOutcome.start_debounce, state.queue(allocator, identity, request));
    const stamp = state.reserveDebounce().?;
    state.armDebounce(stamp);
    const latest = switch (state.finishDebounce(stamp, .elapsed)) {
        .start_reader => |value| value,
        else => return error.ExpectedPreviewReader,
    };
    state.armReader(latest.key);
    var result: git_preview.PreviewReadResult = .{ .verified = .{
        .summary = identity.selection,
        .payload = readyRangePayload(identity.selection),
    } };
    defer result.deinit(allocator);
    try std.testing.expectEqual(ReaderOutcome.settled, state.finishReader(allocator, latest.key, &result));
    return latest.key;
}

fn readyRangePayload(summary: git_preview.SelectionSummary) git_preview.PreviewPayload {
    return .{
        .detail = .{ .ready = .{ .range = summary.range } },
        .files = .{ .ready = &.{} },
    };
}

fn testCacheIdentity(request: git_history.SelectionRequest, catalog_instance: u64) CacheIdentity {
    return .{
        .page = app_page.RequestIdentity.history(7, 11),
        .root = .{ .device = 5, .inode = 9 },
        .catalog_instance = catalog_instance,
        .selection = summaryForRequest(request, 1),
    };
}

fn testRangeRequest(
    head_text: []const u8,
    before_text: []const u8,
    newest_text: []const u8,
    oldest_text: []const u8,
) !git_history.SelectionRequest {
    const head = try git_history.ObjectId.parse(.sha1, head_text);
    const before = try git_history.ObjectId.parse(.sha1, before_text);
    const newest = try git_history.ObjectId.parse(.sha1, newest_text);
    const oldest = try git_history.ObjectId.parse(.sha1, oldest_text);
    return .{
        .snapshot_head = head,
        .intent = .{ .range = .{
            .anchor_index = 1,
            .cursor_index = 2,
            .newest_index = 1,
            .oldest_index = 2,
            .newest_oid = newest,
            .oldest_oid = oldest,
        } },
        .basis = .{
            .object_format = .sha1,
            .before = .{ .commit = before },
            .after = newest,
        },
    };
}
