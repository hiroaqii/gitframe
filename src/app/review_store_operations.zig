//! Bounded App owner for page-independent Review Store mutations.
//!
//! Accepted requests are cloned before background work. One task runs per
//! repository/run key, later compatible drafts coalesce only while unstarted,
//! and result creation waits behind prior draft persistence.

const std = @import("std");
const chasen = @import("chasen");
const committed_review = @import("../committed_review.zig");
const review_store = @import("../review_store.zig");
const app_message = @import("message.zig");

pub const max_active_runs: usize = 64;

pub const Rejection = enum {
    admission_closed,
    capacity,
    incompatible_queue,
    store_unavailable,
};

pub const Admission = union(enum) {
    accepted: struct {
        operation_id: app_message.ReviewStoreOperationId,
        superseded_operation_id: ?app_message.ReviewStoreOperationId = null,
    },
    rejected: Rejection,
};

pub const QuitAdmission = union(enum) {
    ready,
    draining,
    failed: review_store.PersistenceFailure,
};

pub const CompletionRecord = struct {
    operation_id: app_message.ReviewStoreOperationId,
    binding: review_store.ReviewRunBinding,
    kind: app_message.ReviewStoreOperationKind,
    failure: ?review_store.PersistenceFailure,
    notified_review: bool,
};

pub const max_dependent_terminals: usize = 2;

pub const FinishOutcome = struct {
    accepted: bool = false,
    failure: ?review_store.PersistenceFailure = null,
    start_pending: bool = false,
    quit_ready: bool = false,
    quit_canceled: bool = false,
    dependent_terminal_count: usize = 0,
    dependent_terminals: [max_dependent_terminals]CompletionRecord = undefined,

    pub fn dependentTerminals(self: *const FinishOutcome) []const CompletionRecord {
        return self.dependent_terminals[0..self.dependent_terminal_count];
    }
};

const DraftPayload = struct {
    expected_revision: u64,
    canonical_request: []u8,
};

const ResultPayload = struct {
    expected_revision: u64,
    decision: committed_review.ReviewResultValue,
};

const Payload = union(enum) {
    draft: DraftPayload,
    result: ResultPayload,
};

const OwnedOperation = struct {
    operation_id: app_message.ReviewStoreOperationId,
    store: review_store.ConfiguredStore,
    binding: review_store.ReviewRunBinding,
    payload: Payload,

    fn initDraft(
        allocator: std.mem.Allocator,
        operation_id: app_message.ReviewStoreOperationId,
        store: *const review_store.ConfiguredStore,
        request: review_store.DraftSaveRequest,
    ) !OwnedOperation {
        var owned_store = try store.clone(allocator);
        errdefer owned_store.deinit(allocator);
        const snapshot: committed_review.ReviewDraftState = .{
            .schema_version = committed_review.limits.schema_version,
            .review_id = request.binding.review_id,
            .target = request.binding.target,
            .findings_digest = request.binding.findings_digest,
            // Only request ownership is serialized here. The Store ignores
            // this placeholder and assigns its locked next revision.
            .revision = 1,
            .summary = request.summary,
            .finding_dispositions = request.finding_dispositions,
            .anchored_notes = request.anchored_notes,
        };
        return .{
            .operation_id = operation_id,
            .store = owned_store,
            .binding = request.binding,
            .payload = .{ .draft = .{
                .expected_revision = request.expected_revision,
                .canonical_request = try snapshot.writeCanonical(allocator),
            } },
        };
    }

    fn initResult(
        allocator: std.mem.Allocator,
        operation_id: app_message.ReviewStoreOperationId,
        store: *const review_store.ConfiguredStore,
        request: review_store.ReviewResultCreateRequest,
    ) !OwnedOperation {
        return .{
            .operation_id = operation_id,
            .store = try store.clone(allocator),
            .binding = request.binding,
            .payload = .{ .result = .{
                .expected_revision = request.expected_revision,
                .decision = request.decision,
            } },
        };
    }

    fn deinit(self: *OwnedOperation, allocator: std.mem.Allocator) void {
        self.store.deinit(allocator);
        switch (self.payload) {
            .draft => |payload| allocator.free(payload.canonical_request),
            .result => {},
        }
        self.* = undefined;
    }

    fn kind(self: *const OwnedOperation) app_message.ReviewStoreOperationKind {
        return switch (self.payload) {
            .draft => .draft,
            .result => .result,
        };
    }

    fn expectedRevision(self: *const OwnedOperation) u64 {
        return switch (self.payload) {
            .draft => |payload| payload.expected_revision,
            .result => |payload| payload.expected_revision,
        };
    }
};

const InFlight = struct {
    operation_id: app_message.ReviewStoreOperationId,
    kind: app_message.ReviewStoreOperationKind,
    expected_revision: u64,
};

const Slot = struct {
    binding: review_store.ReviewRunBinding,
    in_flight: ?InFlight = null,
    pending_draft: ?OwnedOperation = null,
    pending_result: ?OwnedOperation = null,

    fn deinit(self: *Slot, allocator: std.mem.Allocator) void {
        if (self.pending_draft) |*value| value.deinit(allocator);
        if (self.pending_result) |*value| value.deinit(allocator);
        self.* = undefined;
    }

    fn hasPending(self: *const Slot) bool {
        return self.pending_draft != null or self.pending_result != null;
    }
};

pub const Owner = struct {
    slots: [max_active_runs]Slot = undefined,
    slots_len: usize = 0,
    next_operation_id: app_message.ReviewStoreOperationId = 1,
    admission_open: bool = true,
    draining: bool = false,
    last_completion: ?CompletionRecord = null,

    pub fn deinit(self: *Owner, allocator: std.mem.Allocator) void {
        for (self.slots[0..self.slots_len]) |*slot| slot.deinit(allocator);
        self.* = .{};
    }

    pub fn enqueueDraft(
        self: *Owner,
        allocator: std.mem.Allocator,
        store: *const review_store.ConfiguredStore,
        request: review_store.DraftSaveRequest,
    ) !Admission {
        if (!self.admission_open) return .{ .rejected = .admission_closed };
        const operation_id = self.issueOperationId();
        var operation = try OwnedOperation.initDraft(allocator, operation_id, store, request);
        var operation_owned = true;
        defer if (operation_owned) operation.deinit(allocator);

        const slot_index = self.findSlot(request.binding) orelse blk: {
            if (self.slots_len == max_active_runs) return .{ .rejected = .capacity };
            const index = self.slots_len;
            self.slots[index] = .{ .binding = request.binding };
            self.slots_len += 1;
            break :blk index;
        };
        const slot = &self.slots[slot_index];
        if (!slot.binding.eql(request.binding)) return .{ .rejected = .incompatible_queue };
        if (slot.pending_result != null or
            (slot.in_flight != null and slot.in_flight.?.kind == .result))
        {
            return .{ .rejected = .incompatible_queue };
        }
        if (slot.pending_draft) |*pending| {
            if (pending.expectedRevision() != request.expected_revision) {
                return .{ .rejected = .incompatible_queue };
            }
            const superseded = pending.operation_id;
            pending.deinit(allocator);
            pending.* = operation;
            operation_owned = false;
            return .{ .accepted = .{
                .operation_id = operation_id,
                .superseded_operation_id = superseded,
            } };
        }
        if (slot.in_flight) |active| {
            const compatible_revision = std.math.add(u64, active.expected_revision, 1) catch
                return .{ .rejected = .incompatible_queue };
            if (active.kind != .draft or request.expected_revision != compatible_revision) {
                return .{ .rejected = .incompatible_queue };
            }
        }
        slot.pending_draft = operation;
        operation_owned = false;
        return .{ .accepted = .{ .operation_id = operation_id } };
    }

    pub fn enqueueResult(
        self: *Owner,
        allocator: std.mem.Allocator,
        store: *const review_store.ConfiguredStore,
        request: review_store.ReviewResultCreateRequest,
    ) !Admission {
        if (!self.admission_open) return .{ .rejected = .admission_closed };
        const operation_id = self.issueOperationId();
        var operation = try OwnedOperation.initResult(allocator, operation_id, store, request);
        var operation_owned = true;
        defer if (operation_owned) operation.deinit(allocator);

        const slot_index = self.findSlot(request.binding) orelse blk: {
            if (self.slots_len == max_active_runs) return .{ .rejected = .capacity };
            const index = self.slots_len;
            self.slots[index] = .{ .binding = request.binding };
            self.slots_len += 1;
            break :blk index;
        };
        const slot = &self.slots[slot_index];
        if (!slot.binding.eql(request.binding)) return .{ .rejected = .incompatible_queue };
        if (slot.pending_result != null or
            (slot.in_flight != null and slot.in_flight.?.kind == .result))
        {
            return .{ .rejected = .incompatible_queue };
        }
        const prior_draft_revision = if (slot.pending_draft) |*pending|
            std.math.add(u64, pending.expectedRevision(), 1) catch
                return .{ .rejected = .incompatible_queue }
        else if (slot.in_flight) |active|
            if (active.kind == .draft)
                std.math.add(u64, active.expected_revision, 1) catch
                    return .{ .rejected = .incompatible_queue }
            else
                null
        else
            null;
        if (prior_draft_revision) |revision| {
            if (request.expected_revision != revision) return .{ .rejected = .incompatible_queue };
        }
        slot.pending_result = operation;
        operation_owned = false;
        return .{ .accepted = .{ .operation_id = operation_id } };
    }

    /// Starts at most one task for each currently idle Run. A failed spawn
    /// restores the exact unstarted request to its slot.
    pub fn pump(self: *Owner, ctx: *chasen.Ctx(app_message.Msg)) !usize {
        var started: usize = 0;
        for (self.slots[0..self.slots_len]) |*slot| {
            if (slot.in_flight != null) continue;
            var operation = if (slot.pending_draft) |value| blk: {
                slot.pending_draft = null;
                break :blk value;
            } else if (slot.pending_result) |value| blk: {
                slot.pending_result = null;
                break :blk value;
            } else continue;
            var operation_owned = true;
            defer if (operation_owned) operation.deinit(ctx.allocator());

            const task = ctx.allocator().create(Task) catch |err| {
                switch (operation.kind()) {
                    .draft => slot.pending_draft = operation,
                    .result => slot.pending_result = operation,
                }
                operation_owned = false;
                return err;
            };
            task.* = .{ .operation = operation };
            operation_owned = false;
            ctx.task().spawnWith(.{ .ctx = task, .run = Task.run, .failed = Task.failed }) catch |err| {
                operation = task.operation;
                ctx.allocator().destroy(task);
                operation_owned = true;
                switch (operation.kind()) {
                    .draft => slot.pending_draft = operation,
                    .result => slot.pending_result = operation,
                }
                operation_owned = false;
                return err;
            };
            slot.in_flight = .{
                .operation_id = operation.operation_id,
                .kind = operation.kind(),
                .expected_revision = operation.expectedRevision(),
            };
            started += 1;
        }
        return started;
    }

    pub fn finish(
        self: *Owner,
        allocator: std.mem.Allocator,
        finished: *app_message.ReviewStoreOperationFinished,
        presentation_matches: bool,
    ) FinishOutcome {
        defer finished.deinit(allocator);
        const slot_index = self.findSlot(finished.binding) orelse return .{};
        const slot = &self.slots[slot_index];
        const active = slot.in_flight orelse return .{};
        if (active.operation_id != finished.operation_id or
            active.kind != finished.kind or
            !slot.binding.eql(finished.binding)) return .{};

        var failure = finished.result.failure();
        const revision = finished.result.committedRevision();
        slot.in_flight = null;
        self.last_completion = .{
            .operation_id = finished.operation_id,
            .binding = finished.binding,
            .kind = finished.kind,
            .failure = failure,
            .notified_review = presentation_matches,
        };

        var outcome: FinishOutcome = .{
            .accepted = true,
            .failure = failure,
            .start_pending = slot.hasPending(),
        };
        if (failure == null and finished.kind == .draft) {
            if (revision) |committed_revision| {
                if (!pendingCompatible(slot, committed_revision)) failure = .conflict;
            } else {
                failure = .run_invalid;
            }
        }

        if (failure) |terminal| {
            outcome.failure = terminal;
            outcome.start_pending = false;
            self.last_completion.?.failure = terminal;
            retirePending(
                allocator,
                slot,
                terminal,
                presentation_matches,
                &outcome,
            );
            if (self.draining) {
                self.draining = false;
                self.admission_open = true;
                outcome.quit_canceled = true;
            }
        }

        if (slot.in_flight == null and !slot.hasPending()) self.removeSlot(allocator, slot_index);
        if (self.draining and !self.hasWork()) {
            self.draining = false;
            outcome.quit_ready = true;
        }
        return outcome;
    }

    pub fn requestQuit(self: *Owner) QuitAdmission {
        self.admission_open = false;
        if (!self.hasWork()) return .ready;
        self.draining = true;
        return .draining;
    }

    pub fn cancelDrain(self: *Owner, failure: review_store.PersistenceFailure) void {
        if (!self.draining) return;
        self.draining = false;
        self.admission_open = true;
        _ = failure;
    }

    pub fn isDraining(self: *const Owner) bool {
        return self.draining;
    }

    pub fn admissionsOpen(self: *const Owner) bool {
        return self.admission_open;
    }

    pub fn hasWork(self: *const Owner) bool {
        for (self.slots[0..self.slots_len]) |*slot| {
            if (slot.in_flight != null or slot.hasPending()) return true;
        }
        return false;
    }

    fn findSlot(self: *const Owner, binding: review_store.ReviewRunBinding) ?usize {
        for (self.slots[0..self.slots_len], 0..) |*slot, index| {
            if (slot.binding.review_repository_id.eql(binding.review_repository_id) and
                slot.binding.review_id.eql(binding.review_id)) return index;
        }
        return null;
    }

    fn issueOperationId(self: *Owner) app_message.ReviewStoreOperationId {
        const result = self.next_operation_id;
        self.next_operation_id +%= 1;
        if (self.next_operation_id == 0) self.next_operation_id = 1;
        return result;
    }

    fn removeSlot(self: *Owner, allocator: std.mem.Allocator, index: usize) void {
        self.slots[index].deinit(allocator);
        self.slots_len -= 1;
        if (index != self.slots_len) self.slots[index] = self.slots[self.slots_len];
    }
};

fn retirePending(
    allocator: std.mem.Allocator,
    slot: *Slot,
    failure: review_store.PersistenceFailure,
    presentation_matches: bool,
    outcome: *FinishOutcome,
) void {
    if (slot.pending_draft) |value| {
        var operation = value;
        slot.pending_draft = null;
        recordDependentTerminal(&operation, failure, presentation_matches, outcome);
        operation.deinit(allocator);
    }
    if (slot.pending_result) |value| {
        var operation = value;
        slot.pending_result = null;
        recordDependentTerminal(&operation, failure, presentation_matches, outcome);
        operation.deinit(allocator);
    }
}

fn recordDependentTerminal(
    operation: *const OwnedOperation,
    failure: review_store.PersistenceFailure,
    presentation_matches: bool,
    outcome: *FinishOutcome,
) void {
    std.debug.assert(outcome.dependent_terminal_count < max_dependent_terminals);
    outcome.dependent_terminals[outcome.dependent_terminal_count] = .{
        .operation_id = operation.operation_id,
        .binding = operation.binding,
        .kind = operation.kind(),
        .failure = failure,
        .notified_review = presentation_matches,
    };
    outcome.dependent_terminal_count += 1;
}

fn pendingCompatible(slot: *const Slot, committed_revision: u64) bool {
    if (slot.pending_draft) |*pending| {
        if (pending.expectedRevision() != committed_revision) return false;
        if (slot.pending_result) |*result| {
            const next = std.math.add(u64, committed_revision, 1) catch return false;
            if (result.expectedRevision() != next) return false;
        }
        return true;
    }
    if (slot.pending_result) |*result| return result.expectedRevision() == committed_revision;
    return true;
}

const Task = struct {
    operation: OwnedOperation,

    fn run(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io) app_message.Msg {
        const self: *Task = @ptrCast(@alignCast(context));
        defer {
            self.operation.deinit(allocator);
            allocator.destroy(self);
        }
        const finished: app_message.ReviewStoreOperationFinished = .{
            .operation_id = self.operation.operation_id,
            .binding = self.operation.binding,
            .kind = self.operation.kind(),
            .result = switch (self.operation.payload) {
                .draft => |payload| blk: {
                    var parsed = committed_review.ReviewDraftState.parseStrict(
                        allocator,
                        payload.canonical_request,
                    ) catch break :blk .{ .draft = .{ .failure = .run_invalid } };
                    defer parsed.deinit();
                    const result: review_store.DraftSaveResult = review_store.saveDraft(allocator, io, &self.operation.store, .{
                        .binding = self.operation.binding,
                        .expected_revision = payload.expected_revision,
                        .summary = parsed.value.summary,
                        .finding_dispositions = parsed.value.finding_dispositions,
                        .anchored_notes = parsed.value.anchored_notes,
                    }) catch .{ .failure = .io_failed };
                    break :blk .{ .draft = result };
                },
                .result => |payload| blk: {
                    const result: review_store.ReviewResultCreateResult = review_store.createResult(allocator, io, &self.operation.store, .{
                        .binding = self.operation.binding,
                        .expected_revision = payload.expected_revision,
                        .decision = payload.decision,
                    }) catch .{ .failure = .io_failed };
                    break :blk .{ .result = result };
                },
            },
        };
        return .{ .review_store_operation_finished = finished };
    }

    fn failed(
        context: *anyopaque,
        _: chasen.TaskFailure,
        allocator: std.mem.Allocator,
    ) app_message.Msg {
        const self: *Task = @ptrCast(@alignCast(context));
        const kind = self.operation.kind();
        const finished: app_message.ReviewStoreOperationFinished = .{
            .operation_id = self.operation.operation_id,
            .binding = self.operation.binding,
            .kind = kind,
            .result = failureResult(kind, .io_failed),
        };
        self.operation.deinit(allocator);
        allocator.destroy(self);
        return .{ .review_store_operation_finished = finished };
    }
};

fn failureResult(
    kind: app_message.ReviewStoreOperationKind,
    failure: review_store.PersistenceFailure,
) app_message.ReviewStoreOperationResult {
    return switch (kind) {
        .draft => .{ .draft = .{ .failure = failure } },
        .result => .{ .result = .{ .failure = failure } },
    };
}

test "review state persistence operation owner coalesces drafts serializes result and drains quit" {
    const allocator = std.testing.allocator;
    var store = try review_store.ConfiguredStore.initConfigured(allocator, "/unused");
    defer store.deinit(allocator);
    var owner: Owner = .{};
    defer owner.deinit(allocator);
    const binding = try testBinding(0);
    const first = try owner.enqueueDraft(allocator, &store, testDraft(binding, 0, "first"));
    const first_id = first.accepted.operation_id;
    const newer = try owner.enqueueDraft(allocator, &store, testDraft(binding, 0, "newer"));
    try std.testing.expectEqual(first_id, newer.accepted.superseded_operation_id.?);
    const draft_id = newer.accepted.operation_id;
    const terminal = try owner.enqueueResult(allocator, &store, .{
        .binding = binding,
        .expected_revision = 1,
        .decision = .approved,
    });
    const result_id = terminal.accepted.operation_id;
    const duplicate = try owner.enqueueResult(allocator, &store, .{
        .binding = binding,
        .expected_revision = 1,
        .decision = .canceled,
    });
    try std.testing.expectEqual(Rejection.incompatible_queue, duplicate.rejected);

    var ctx: chasen.Ctx(app_message.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };
    try std.testing.expectEqual(@as(usize, 1), try owner.pump(&ctx));
    try std.testing.expectEqual(QuitAdmission.draining, owner.requestQuit());
    const queued_draft = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), queued_draft.len);
    var discarded = queued_draft[0].failed(queued_draft[0].ctx, .runtime_abandoned, allocator);
    discarded.deinitUndelivered(allocator);

    var draft_finished: app_message.ReviewStoreOperationFinished = .{
        .operation_id = draft_id,
        .binding = binding,
        .kind = .draft,
        .result = .{ .draft = .{ .committed = .{
            .revision = 1,
            .canonical_bytes = try allocator.dupe(u8, "draft\n"),
        } } },
    };
    const draft_outcome = owner.finish(allocator, &draft_finished, true);
    try std.testing.expect(draft_outcome.accepted);
    try std.testing.expect(draft_outcome.start_pending);
    try std.testing.expect(!draft_outcome.quit_ready);
    try std.testing.expect(owner.last_completion.?.notified_review);

    try std.testing.expectEqual(@as(usize, 1), try owner.pump(&ctx));
    const queued_result = ctx.takePendingTasksWith();
    var discarded_result = queued_result[0].failed(queued_result[0].ctx, .runtime_abandoned, allocator);
    discarded_result.deinitUndelivered(allocator);
    var result_finished: app_message.ReviewStoreOperationFinished = .{
        .operation_id = result_id,
        .binding = binding,
        .kind = .result,
        .result = .{ .result = .{ .committed = .{
            .revision = 1,
            .completed_at = "2026-08-21T00:00:00Z".*,
            .canonical_bytes = try allocator.dupe(u8, "result\n"),
        } } },
    };
    const result_outcome = owner.finish(allocator, &result_finished, false);
    try std.testing.expect(result_outcome.quit_ready);
    try std.testing.expect(!owner.last_completion.?.notified_review);
    try std.testing.expect(!owner.hasWork());
}

test "review state persistence operation owner cancels failed drain and enforces finite Run cap" {
    const allocator = std.testing.allocator;
    var store = try review_store.ConfiguredStore.initConfigured(allocator, "/unused");
    defer store.deinit(allocator);
    const binding = try testBinding(0);

    // A normal predecessor failure gives every already-accepted dependent an
    // observable terminal, releases its clone, and leaves the Run retryable.
    var recovery: Owner = .{};
    defer recovery.deinit(allocator);
    const active = try recovery.enqueueDraft(allocator, &store, testDraft(binding, 0, "active"));
    var recovery_ctx: chasen.Ctx(app_message.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };
    try std.testing.expectEqual(@as(usize, 1), try recovery.pump(&recovery_ctx));
    const pending_draft = try recovery.enqueueDraft(allocator, &store, testDraft(binding, 1, "pending"));
    const pending_result = try recovery.enqueueResult(allocator, &store, .{
        .binding = binding,
        .expected_revision = 2,
        .decision = .approved,
    });
    const recovery_tasks = recovery_ctx.takePendingTasksWith();
    var abandoned = recovery_tasks[0].failed(recovery_tasks[0].ctx, .runtime_abandoned, allocator);
    abandoned.deinitUndelivered(allocator);

    var wrong_id = failedFinished(active.accepted.operation_id + 100, binding, .draft, .io_failed);
    try std.testing.expect(!recovery.finish(allocator, &wrong_id, true).accepted);
    var wrong_binding = binding;
    wrong_binding.findings_digest = committed_review.Sha256Digest.hash("wrong findings\n");
    var wrong_run = failedFinished(active.accepted.operation_id, wrong_binding, .draft, .io_failed);
    try std.testing.expect(!recovery.finish(allocator, &wrong_run, true).accepted);
    try std.testing.expect(recovery.hasWork());

    var failed = failedFinished(active.accepted.operation_id, binding, .draft, .io_failed);
    const recovered = recovery.finish(allocator, &failed, true);
    try std.testing.expect(recovered.accepted);
    try std.testing.expectEqual(review_store.PersistenceFailure.io_failed, recovered.failure.?);
    try std.testing.expectEqual(@as(usize, 2), recovered.dependentTerminals().len);
    try std.testing.expectEqual(pending_draft.accepted.operation_id, recovered.dependentTerminals()[0].operation_id);
    try std.testing.expectEqual(app_message.ReviewStoreOperationKind.draft, recovered.dependentTerminals()[0].kind);
    try std.testing.expectEqual(pending_result.accepted.operation_id, recovered.dependentTerminals()[1].operation_id);
    try std.testing.expectEqual(app_message.ReviewStoreOperationKind.result, recovered.dependentTerminals()[1].kind);
    for (recovered.dependentTerminals()) |terminal| {
        try std.testing.expectEqual(review_store.PersistenceFailure.io_failed, terminal.failure.?);
        try std.testing.expect(terminal.notified_review);
    }
    try std.testing.expectEqual(active.accepted.operation_id, recovery.last_completion.?.operation_id);
    try std.testing.expect(!recovery.hasWork());
    try std.testing.expect(recovery.admissionsOpen());

    const retry = try recovery.enqueueDraft(allocator, &store, testDraft(binding, 0, "retry"));
    try std.testing.expectEqual(@as(usize, 1), try recovery.pump(&recovery_ctx));
    const retry_tasks = recovery_ctx.takePendingTasksWith();
    var retry_abandoned = retry_tasks[0].failed(retry_tasks[0].ctx, .runtime_abandoned, allocator);
    retry_abandoned.deinitUndelivered(allocator);
    var retry_finished = try committedDraftFinished(allocator, retry.accepted.operation_id, binding, 1);
    const retry_outcome = recovery.finish(allocator, &retry_finished, false);
    try std.testing.expect(retry_outcome.accepted);
    try std.testing.expect(!recovery.hasWork());
    try std.testing.expectEqual(QuitAdmission.ready, recovery.requestQuit());

    // The same dependent-terminal rule cancels a drain, reopens admission,
    // and permits the user's next quit to complete without a blocked slot.
    var owner: Owner = .{};
    defer owner.deinit(allocator);
    const draining_active = try owner.enqueueDraft(allocator, &store, testDraft(binding, 0, "active"));
    var ctx: chasen.Ctx(app_message.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };
    try std.testing.expectEqual(@as(usize, 1), try owner.pump(&ctx));
    _ = try owner.enqueueDraft(allocator, &store, testDraft(binding, 1, "pending"));
    _ = try owner.enqueueResult(allocator, &store, .{
        .binding = binding,
        .expected_revision = 2,
        .decision = .needs_changes,
    });
    try std.testing.expectEqual(QuitAdmission.draining, owner.requestQuit());
    const queued = ctx.takePendingTasksWith();
    var drain_abandoned = queued[0].failed(queued[0].ctx, .runtime_abandoned, allocator);
    drain_abandoned.deinitUndelivered(allocator);
    var drain_finished = failedFinished(draining_active.accepted.operation_id, binding, .draft, .conflict);
    const drain_failure = owner.finish(allocator, &drain_finished, false);
    try std.testing.expect(drain_failure.quit_canceled);
    try std.testing.expectEqual(review_store.PersistenceFailure.conflict, drain_failure.failure.?);
    try std.testing.expectEqual(@as(usize, 2), drain_failure.dependentTerminals().len);
    try std.testing.expect(owner.admissionsOpen());
    try std.testing.expect(!owner.hasWork());
    try std.testing.expectEqual(QuitAdmission.ready, owner.requestQuit());

    var parallel: Owner = .{};
    defer parallel.deinit(allocator);
    _ = try parallel.enqueueDraft(allocator, &store, testDraft(try testBinding(100), 0, "one"));
    _ = try parallel.enqueueDraft(allocator, &store, testDraft(try testBinding(101), 0, "two"));
    var parallel_ctx: chasen.Ctx(app_message.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };
    try std.testing.expectEqual(@as(usize, 2), try parallel.pump(&parallel_ctx));
    const parallel_tasks = parallel_ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 2), parallel_tasks.len);
    for (parallel_tasks) |task| {
        var terminal = task.failed(task.ctx, .runtime_abandoned, allocator);
        var parallel_finished = terminal.review_store_operation_finished;
        terminal = undefined;
        const applied = parallel.finish(allocator, &parallel_finished, false);
        try std.testing.expect(applied.accepted);
    }
    try std.testing.expect(!parallel.hasWork());

    var capacity_owner: Owner = .{};
    defer capacity_owner.deinit(allocator);
    for (0..max_active_runs) |index| {
        const unique = try testBinding(@intCast(index + 1));
        const admission = try capacity_owner.enqueueDraft(allocator, &store, testDraft(unique, 0, "queued"));
        try std.testing.expect(admission == .accepted);
    }
    const overflow = try capacity_owner.enqueueDraft(
        allocator,
        &store,
        testDraft(try testBinding(250), 0, "overflow"),
    );
    try std.testing.expectEqual(Rejection.capacity, overflow.rejected);
}

fn failedFinished(
    operation_id: app_message.ReviewStoreOperationId,
    binding: review_store.ReviewRunBinding,
    kind: app_message.ReviewStoreOperationKind,
    failure: review_store.PersistenceFailure,
) app_message.ReviewStoreOperationFinished {
    return .{
        .operation_id = operation_id,
        .binding = binding,
        .kind = kind,
        .result = failureResult(kind, failure),
    };
}

fn committedDraftFinished(
    allocator: std.mem.Allocator,
    operation_id: app_message.ReviewStoreOperationId,
    binding: review_store.ReviewRunBinding,
    revision: u64,
) !app_message.ReviewStoreOperationFinished {
    return .{
        .operation_id = operation_id,
        .binding = binding,
        .kind = .draft,
        .result = .{ .draft = .{ .committed = .{
            .revision = revision,
            .canonical_bytes = try allocator.dupe(u8, "draft\n"),
        } } },
    };
}

fn testDraft(
    binding: review_store.ReviewRunBinding,
    expected_revision: u64,
    summary: []const u8,
) review_store.DraftSaveRequest {
    return .{
        .binding = binding,
        .expected_revision = expected_revision,
        .summary = summary,
        .finding_dispositions = &.{},
        .anchored_notes = &.{},
    };
}

fn testBinding(suffix: u8) !review_store.ReviewRunBinding {
    var repository_id = try committed_review.ReviewRepositoryId.parse("123e4567-e89b-42d3-a456-426614174000");
    repository_id.bytes[15] = suffix;
    const review_id = try committed_review.ReviewId.parse("223e4567-e89b-42d3-a456-426614174000");
    const oid = try committed_review.ObjectId.parse(.sha1, "0123456789abcdef0123456789abcdef01234567");
    return .{
        .review_repository_id = repository_id,
        .review_id = review_id,
        .target = .{
            .object_format = .sha1,
            .source_kind = .branch_range,
            .base_oid = oid,
            .head_oid = oid,
            .diff_base_oid = oid,
        },
        .findings_digest = committed_review.Sha256Digest.hash("findings\n"),
    };
}
