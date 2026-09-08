//! Fixed-capacity serial owner for hosted AI review jobs.

const std = @import("std");
const job = @import("job.zig");
const pipeline = @import("runner.zig");

pub const capacity: usize = 8;

pub const Rejection = enum {
    admission_closed,
    capacity,
    id_exhausted,
    generation_exhausted,
    scope_mismatch,
};

pub const Admission = union(enum) {
    accepted: job.Key,
    rejected: Rejection,
};

pub const ReviewStart = struct {
    key: job.Key,
    request: pipeline.Request,
    cancellation: @import("../process/runner.zig").CancellationView,
};

pub const ReadyDisposition = enum {
    accept,
    canceled,
    stale,
};

pub const QuitDisposition = enum {
    ready,
    confirmation_required,
};

const Slot = union(enum) {
    empty,
    occupied: job.Record,
};

pub const Owner = struct {
    slots: [capacity]Slot = [_]Slot{.empty} ** capacity,
    retained_count: usize = 0,
    active_index: ?usize = null,
    next_id: u64 = 1,
    next_generation: u64 = 1,
    next_sequence: u64 = 1,
    next_terminal_sequence: u64 = 1,
    admission_open: bool = true,
    quitting: bool = false,

    pub fn deinit(self: *Owner) void {
        for (&self.slots) |*slot| switch (slot.*) {
            .empty => {},
            .occupied => |*record| record.deinit(),
        };
        self.* = .{};
    }

    /// Always consumes `request`, including rejection and allocation-free
    /// admission failures.
    pub fn enqueue(self: *Owner, scope: job.Scope, request: pipeline.Request) Admission {
        var owned_request = request;
        var request_owned = true;
        defer if (request_owned) owned_request.deinit();

        if (!self.admission_open) return .{ .rejected = .admission_closed };
        if (self.retained_count == capacity) return .{ .rejected = .capacity };
        if (self.next_id == 0 or self.next_id > std.math.maxInt(job.Id)) {
            return .{ .rejected = .id_exhausted };
        }
        if (self.next_generation == 0) return .{ .rejected = .generation_exhausted };
        if (!owned_request.matchesScope(scope.repository, &scope.target)) {
            return .{ .rejected = .scope_mismatch };
        }

        const slot_index = self.emptySlot().?;
        const key: job.Key = .{
            .id = @intCast(self.next_id),
            .generation = self.next_generation,
        };
        self.slots[slot_index] = .{ .occupied = job.Record.init(
            key,
            self.next_sequence,
            scope,
            owned_request,
        ) };
        request_owned = false;
        self.retained_count += 1;
        self.next_id += 1;
        self.next_generation +%= 1;
        self.next_sequence +%= 1;
        return .{ .accepted = key };
    }

    /// Moves the oldest queued request into one review task and pins the
    /// cancellation address in its fixed slot until terminal adoption.
    pub fn takeNextReview(self: *Owner) ?ReviewStart {
        if (self.active_index != null or self.quitting) return null;
        const index = self.oldestQueued() orelse return null;
        const record = self.recordAt(index);
        const request = record.request orelse unreachable;
        record.request = null;
        record.phase = .reviewing;
        self.active_index = index;
        return .{
            .key = record.key,
            .request = request,
            .cancellation = record.cancellation(),
        };
    }

    pub fn reviewTaskStartFailed(self: *Owner, key: job.Key) bool {
        return self.finishStartFailure(key, .reviewing, .review_task_start_failed);
    }

    pub fn readyDisposition(self: *Owner, key: job.Key) ReadyDisposition {
        const record = self.activeRecord(key, .reviewing) orelse return .stale;
        return if (record.cancel_latched or record.cancellation().requested()) .canceled else .accept;
    }

    pub fn cancelReady(self: *Owner, key: job.Key) bool {
        const record = self.activeRecord(key, .reviewing) orelse return false;
        self.finishRecord(record, job.Terminal.canceled());
        return true;
    }

    pub fn beginPublishing(self: *Owner, key: job.Key) bool {
        const record = self.activeRecord(key, .reviewing) orelse return false;
        if (record.cancel_latched or record.cancellation().requested()) return false;
        record.phase = .publishing;
        return true;
    }

    pub fn publicationTaskStartFailed(self: *Owner, key: job.Key) bool {
        return self.finishStartFailure(key, .publishing, .publication_task_start_failed);
    }

    /// Publication context allocation can fail before the phase transition.
    pub fn publicationTaskStartFailedAfterReview(self: *Owner, key: job.Key) bool {
        return self.finishStartFailure(key, .reviewing, .publication_task_start_failed);
    }

    pub fn finishReview(self: *Owner, key: job.Key, terminal: pipeline.Terminal) bool {
        const record = self.activeRecord(key, .reviewing) orelse return false;
        self.finishRecord(record, .{ .pipeline = terminal });
        return true;
    }

    pub fn finishPublication(self: *Owner, key: job.Key, terminal: pipeline.Terminal) bool {
        const record = self.activeRecord(key, .publishing) orelse return false;
        self.finishRecord(record, .{ .pipeline = terminal });
        return true;
    }

    pub fn cancel(self: *Owner, key: job.Key) bool {
        const record = self.findRecord(key) orelse return false;
        switch (record.phase) {
            .queued => {
                record.request.?.deinit();
                record.request = null;
                self.finishRecord(record, job.Terminal.canceled());
            },
            .reviewing, .publishing => record.requestCancel(),
            .terminal => return false,
        }
        return true;
    }

    pub fn requestQuit(self: *const Owner) QuitDisposition {
        return if (self.hasOwnedWork()) .confirmation_required else .ready;
    }

    /// Closes admission, releases queued requests, and latches the active job.
    /// Returns true when no task result must be awaited.
    pub fn confirmQuit(self: *Owner) bool {
        self.admission_open = false;
        self.quitting = true;
        for (&self.slots) |*slot| switch (slot.*) {
            .empty => {},
            .occupied => |*record| switch (record.phase) {
                .queued => {
                    record.request.?.deinit();
                    record.request = null;
                    self.finishRecord(record, job.Terminal.canceled());
                },
                .reviewing, .publishing => record.requestCancel(),
                .terminal => {},
            },
        };
        return self.active_index == null;
    }

    pub fn quitReady(self: *const Owner) bool {
        return self.quitting and self.active_index == null;
    }

    pub fn selected(self: *const Owner) ?*const job.Record {
        if (self.active_index) |index| return self.recordAtConst(index);
        if (self.oldestQueued()) |index| return self.recordAtConst(index);

        var selected_record: ?*const job.Record = null;
        for (&self.slots) |*slot| switch (slot.*) {
            .empty => {},
            .occupied => |*record| {
                if (record.phase != .terminal or !record.unread) continue;
                if (selected_record == null or terminalBefore(record, selected_record.?)) {
                    selected_record = record;
                }
            },
        };
        return selected_record;
    }

    pub fn find(self: *const Owner, key: job.Key) ?*const job.Record {
        return self.findRecordConst(key);
    }

    pub fn acknowledge(self: *Owner, key: job.Key, repository: @import("../repo/root_capability.zig").Identity) bool {
        const record = self.findRecord(key) orelse return false;
        if (record.phase != .terminal or !record.scope.repository.eql(repository)) return false;
        record.unread = false;
        return true;
    }

    pub fn dismiss(self: *Owner, key: job.Key, repository: @import("../repo/root_capability.zig").Identity) bool {
        for (&self.slots, 0..) |*slot, index| switch (slot.*) {
            .empty => {},
            .occupied => |*record| {
                if (!record.key.eql(key) or record.phase != .terminal or
                    !record.scope.repository.eql(repository)) continue;
                std.debug.assert(self.active_index != index);
                record.deinit();
                slot.* = .empty;
                self.retained_count -= 1;
                return true;
            },
        };
        return false;
    }

    pub fn hasOwnedWork(self: *const Owner) bool {
        for (&self.slots) |*slot| switch (slot.*) {
            .empty => {},
            .occupied => |*record| if (record.phase != .terminal) return true,
        };
        return false;
    }

    fn finishStartFailure(self: *Owner, key: job.Key, expected: std.meta.Tag(job.Phase), failure: job.StartFailure) bool {
        const record = self.activeRecord(key, expected) orelse return false;
        self.finishRecord(record, .{ .start_failed = failure });
        return true;
    }

    fn finishRecord(self: *Owner, record: *job.Record, terminal: job.Terminal) void {
        if (record.request) |*request| {
            request.deinit();
            record.request = null;
        }
        record.phase = .{ .terminal = terminal };
        record.terminal_sequence = self.next_terminal_sequence;
        self.next_terminal_sequence +%= 1;
        record.unread = true;
        if (self.active_index) |index| {
            if (&self.slots[index].occupied == record) self.active_index = null;
        }
    }

    fn activeRecord(self: *Owner, key: job.Key, expected: std.meta.Tag(job.Phase)) ?*job.Record {
        const index = self.active_index orelse return null;
        const record = self.recordAt(index);
        if (!record.key.eql(key) or std.meta.activeTag(record.phase) != expected) return null;
        return record;
    }

    fn emptySlot(self: *Owner) ?usize {
        for (&self.slots, 0..) |*slot, index| if (slot.* == .empty) return index;
        return null;
    }

    fn oldestQueued(self: *const Owner) ?usize {
        var selected_index: ?usize = null;
        for (&self.slots, 0..) |*slot, index| switch (slot.*) {
            .empty => {},
            .occupied => |*record| {
                if (record.phase != .queued) continue;
                if (selected_index == null or record.sequence < self.recordAtConst(selected_index.?).sequence) {
                    selected_index = index;
                }
            },
        };
        return selected_index;
    }

    fn findRecord(self: *Owner, key: job.Key) ?*job.Record {
        for (&self.slots) |*slot| switch (slot.*) {
            .empty => {},
            .occupied => |*record| if (record.key.eql(key)) return record,
        };
        return null;
    }

    fn findRecordConst(self: *const Owner, key: job.Key) ?*const job.Record {
        for (&self.slots) |*slot| switch (slot.*) {
            .empty => {},
            .occupied => |*record| if (record.key.eql(key)) return record,
        };
        return null;
    }

    fn recordAt(self: *Owner, index: usize) *job.Record {
        return switch (self.slots[index]) {
            .empty => unreachable,
            .occupied => |*record| record,
        };
    }

    fn recordAtConst(self: *const Owner, index: usize) *const job.Record {
        return switch (self.slots[index]) {
            .empty => unreachable,
            .occupied => |*record| record,
        };
    }
};

fn terminalBefore(left: *const job.Record, right: *const job.Record) bool {
    const left_sequence = left.terminal_sequence orelse unreachable;
    const right_sequence = right.terminal_sequence orelse unreachable;
    return left_sequence < right_sequence or
        (left_sequence == right_sequence and left.key.id < right.key.id);
}

const TestFixture = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    tmp: std.testing.TmpDir,
    repo_path: [:0]u8,
    store_path: [:0]u8,
    root: @import("../repo/root_capability.zig").RootCapability,
    store: @import("store_service.zig").ConfiguredStore,
    target: @import("../committed_review.zig").CommittedReviewTarget,

    fn init(allocator: std.mem.Allocator, io: std.Io) !TestFixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDir(io, "repo", .fromMode(0o700));
        try tmp.dir.createDir(io, "store", .fromMode(0o700));
        const repo_path = try tmp.dir.realPathFileAlloc(io, "repo", allocator);
        errdefer allocator.free(repo_path);
        const store_path = try tmp.dir.realPathFileAlloc(io, "store", allocator);
        errdefer allocator.free(store_path);
        var root = try @import("../repo/root_capability.zig").RootCapability.openCanonical(repo_path);
        errdefer root.deinit();
        return .{
            .allocator = allocator,
            .io = io,
            .tmp = tmp,
            .repo_path = repo_path,
            .store_path = store_path,
            .root = root,
            .store = try @import("store_service.zig").ConfiguredStore.initConfigured(allocator, store_path),
            .target = try testTarget(),
        };
    }

    fn deinit(self: *TestFixture) void {
        self.store.deinit(self.allocator);
        self.root.deinit();
        self.allocator.free(self.store_path);
        self.allocator.free(self.repo_path);
        self.tmp.cleanup();
        self.* = undefined;
    }

    fn request(self: *TestFixture) !pipeline.Request {
        const codex = @import("adapters/codex/adapter.zig");
        return pipeline.Request.init(
            self.allocator,
            self.root,
            null,
            &self.store,
            self.repo_path,
            self.target,
            null,
            .{ .codex = try codex.Request.init(self.allocator, "/bin/false", null) },
            "",
        );
    }

    fn scope(self: *const TestFixture) job.Scope {
        return .{ .repository = self.root.identity, .target = self.target };
    }
};

fn testTarget() !@import("../committed_review.zig").CommittedReviewTarget {
    const committed = @import("../committed_review.zig");
    const base = try committed.ObjectId.parse(.sha1, "1111111111111111111111111111111111111111");
    const head = try committed.ObjectId.parse(.sha1, "2222222222222222222222222222222222222222");
    return .{
        .object_format = .sha1,
        .source_kind = .branch_range,
        .base_oid = base,
        .head_oid = head,
        .diff_base_oid = base,
    };
}

test "AI review job owner admits eight records and preserves FIFO independently of slot reuse" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try TestFixture.init(allocator, io);
    defer fixture.deinit();
    var owner: Owner = .{};
    defer owner.deinit();

    var keys: [capacity]job.Key = undefined;
    for (&keys, 0..) |*key, index| {
        const admission = owner.enqueue(fixture.scope(), try fixture.request());
        key.* = admission.accepted;
        try std.testing.expectEqual(@as(job.Id, @intCast(index + 1)), key.id);
    }
    try std.testing.expectEqual(capacity, owner.retained_count);
    try std.testing.expect(owner.enqueue(fixture.scope(), try fixture.request()) == .rejected);
    try std.testing.expectEqual(Rejection.capacity, owner.enqueue(fixture.scope(), try fixture.request()).rejected);

    const first = owner.takeNextReview().?;
    try std.testing.expect(first.key.eql(keys[0]));
    var first_request = first.request;
    first_request.deinit();
    try std.testing.expect(owner.reviewTaskStartFailed(first.key));
    const second = owner.takeNextReview().?;
    try std.testing.expect(second.key.eql(keys[1]));
    var second_request = second.request;
    second_request.deinit();
    try std.testing.expect(owner.finishReview(second.key, .{ .outcome = .no_changes }));
}

test "AI review job owner closes ID and generation exhaustion without eviction" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try TestFixture.init(allocator, io);
    defer fixture.deinit();
    var owner: Owner = .{};
    defer owner.deinit();

    owner.next_id = @as(u64, std.math.maxInt(job.Id)) + 1;
    try std.testing.expectEqual(Rejection.id_exhausted, owner.enqueue(fixture.scope(), try fixture.request()).rejected);
    try std.testing.expectEqual(@as(usize, 0), owner.retained_count);
    owner.next_id = 1;
    owner.next_generation = 0;
    try std.testing.expectEqual(Rejection.generation_exhausted, owner.enqueue(fixture.scope(), try fixture.request()).rejected);
    try std.testing.expectEqual(@as(usize, 0), owner.retained_count);
}

test "AI review job owner binds retained scope to exact request authority" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try TestFixture.init(allocator, io);
    defer fixture.deinit();
    var owner: Owner = .{};
    defer owner.deinit();

    var wrong_repository = fixture.scope();
    wrong_repository.repository.inode +%= 1;
    try std.testing.expectEqual(
        Rejection.scope_mismatch,
        owner.enqueue(wrong_repository, try fixture.request()).rejected,
    );
    try std.testing.expectEqual(@as(usize, 0), owner.retained_count);

    var wrong_target = fixture.scope();
    wrong_target.target.head_oid = try @import("../committed_review.zig").ObjectId.parse(
        .sha1,
        "3333333333333333333333333333333333333333",
    );
    try std.testing.expectEqual(
        Rejection.scope_mismatch,
        owner.enqueue(wrong_target, try fixture.request()).rejected,
    );
    try std.testing.expectEqual(@as(usize, 0), owner.retained_count);

    const matching = fixture.scope();
    const key = owner.enqueue(matching, try fixture.request()).accepted;
    try std.testing.expect(owner.find(key).?.scope.eql(&matching));
}

test "AI review job owner validates exact handoff cancellation and serial terminal selection" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try TestFixture.init(allocator, io);
    defer fixture.deinit();
    var owner: Owner = .{};
    defer owner.deinit();

    const first = owner.enqueue(fixture.scope(), try fixture.request()).accepted;
    const second = owner.enqueue(fixture.scope(), try fixture.request()).accepted;
    const third = owner.enqueue(fixture.scope(), try fixture.request()).accepted;
    var started = owner.takeNextReview().?;
    started.request.deinit();
    try std.testing.expectEqual(ReadyDisposition.stale, owner.readyDisposition(.{ .id = first.id, .generation = first.generation + 1 }));
    try std.testing.expect(owner.cancel(second));
    try std.testing.expect(owner.cancel(first));
    try std.testing.expect(started.cancellation.requested());
    try std.testing.expectEqual(ReadyDisposition.canceled, owner.readyDisposition(first));
    try std.testing.expect(owner.cancelReady(first));

    started = owner.takeNextReview().?;
    try std.testing.expect(started.key.eql(third));
    started.request.deinit();
    try std.testing.expectEqual(ReadyDisposition.accept, owner.readyDisposition(third));
    try std.testing.expect(owner.beginPublishing(third));
    try std.testing.expect(owner.cancel(third));
    try std.testing.expect(owner.find(third).?.phase == .publishing);
    try std.testing.expect(owner.finishPublication(third, .{ .outcome = .no_changes }));
    try std.testing.expect(owner.selected().?.key.eql(second));
    try std.testing.expect(owner.acknowledge(second, fixture.root.identity));
    try std.testing.expect(owner.selected().?.key.eql(first));
    try std.testing.expect(owner.dismiss(first, fixture.root.identity));
    try std.testing.expect(owner.find(first) == null);
}

test "AI review job owner quit releases queued and waits only for active publication" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try TestFixture.init(allocator, io);
    defer fixture.deinit();
    var owner: Owner = .{};
    defer owner.deinit();

    const active = owner.enqueue(fixture.scope(), try fixture.request()).accepted;
    const queued = owner.enqueue(fixture.scope(), try fixture.request()).accepted;
    var started = owner.takeNextReview().?;
    started.request.deinit();
    try std.testing.expect(owner.beginPublishing(active));
    try std.testing.expectEqual(QuitDisposition.confirmation_required, owner.requestQuit());
    try std.testing.expect(!owner.confirmQuit());
    try std.testing.expect(owner.find(queued).?.phase == .terminal);
    try std.testing.expect(owner.find(active).?.phase == .publishing);
    try std.testing.expect(!owner.quitReady());
    try std.testing.expect(owner.finishPublication(active, .{ .outcome = .no_changes }));
    try std.testing.expect(owner.quitReady());
    try std.testing.expectEqual(Rejection.admission_closed, owner.enqueue(fixture.scope(), try fixture.request()).rejected);
}
