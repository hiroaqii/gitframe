//! Pure, bounded ownership for one human Review Run lifecycle.
//!
//! This module owns only validated portable Review values and semantic Store
//! requests/completions. It deliberately has no filesystem, Git, task,
//! renderer, page, or mutation-queue authority.

const std = @import("std");
const artifact = @import("../committed_review/artifact.zig");
const identity = @import("../committed_review/identity.zig");
const target = @import("../committed_review/target.zig");
const review_limits = @import("../committed_review/limits.zig");
const review_store = @import("../review_store.zig");

/// The portable committed-review vocabulary used by this owner, assembled
/// directly from its semantic leaf modules so dependency audits do not confuse
/// the public `committed_review.zig` facade with a renderer `view.zig` import.
const committed_review = struct {
    const AnchoredNote = artifact.AnchoredNote;
    const Finding = artifact.Finding;
    const FindingDisposition = artifact.FindingDisposition;
    const FindingDispositionValue = artifact.FindingDispositionValue;
    const FindingId = artifact.FindingId;
    const FindingSet = artifact.FindingSet;
    const ReviewDraftState = artifact.ReviewDraftState;
    const ReviewResultValue = artifact.ReviewResultValue;
    const RevisionReviewResult = artifact.RevisionReviewResult;
    const ReviewId = identity.ReviewId;
    const ReviewRepositoryId = identity.ReviewRepositoryId;
    const Sha256Digest = identity.Sha256Digest;
    const ObjectId = target.ObjectId;
    const limits = review_limits;
};

pub const max_detached_sessions: usize = 64;
pub const max_operations: usize = 3;
pub const OperationId = u64;
pub const OperationKind = enum { draft, result };
pub const QueueRole = enum { active, pending_draft, pending_result };

pub const QueueEntry = struct {
    operation_id: OperationId,
    kind: OperationKind,
    expected_revision: u64,
    role: QueueRole,
};

/// Read-only evidence for the exact mutation queue shape used by prepare.
pub const QueueToken = struct {
    binding: review_store.ReviewRunBinding,
    epoch: u64,
    entries: [max_operations]QueueEntry = undefined,
    entries_len: usize = 0,

    pub fn slice(self: *const QueueToken) []const QueueEntry {
        return self.entries[0..self.entries_len];
    }

    pub fn eql(self: *const QueueToken, other: *const QueueToken) bool {
        if (!self.binding.eql(other.binding) or self.epoch != other.epoch or
            self.entries_len != other.entries_len) return false;
        for (self.slice(), other.slice()) |left, right| {
            if (left.operation_id != right.operation_id or left.kind != right.kind or
                left.expected_revision != right.expected_revision or left.role != right.role)
            {
                return false;
            }
        }
        return true;
    }
};

pub const AdmissionFailure = enum {
    admission_closed,
    capacity,
    incompatible_queue,
    store_unavailable,
    queue_changed,
    preparation_failed,
};

pub const FailureReason = union(enum) {
    admission: AdmissionFailure,
    persistence: review_store.PersistenceFailure,
    internal_mismatch,
};

pub const Reconciliation = enum { confirmed, reload_required };
pub const Lifecycle = enum { editable, saving, finalizing, completed, failed };

pub const FailureRecord = struct {
    reason: FailureReason,
    kind: OperationKind,
    expected_revision: u64,
    submitted_generation: u64,
    decision: ?committed_review.ReviewResultValue = null,
    observed_committed_revision: ?u64 = null,
    observed_completed_at: ?[20]u8 = null,
};

pub const Completion = struct {
    operation_id: OperationId,
    binding: review_store.ReviewRunBinding,
    kind: OperationKind,
    expected_revision: u64,
    committed_revision: ?u64,
    completed_at: ?[20]u8,
    failure: ?review_store.PersistenceFailure,
};

pub const Reduction = enum { ignored, applied, reconciliation_required };
pub const DraftRequirement = enum { dirty_only, ensure_persisted };

pub const InitError = std.mem.Allocator.Error || error{
    InvalidBinding,
    DuplicateFinding,
    InvalidDraft,
    InvalidResult,
    InvalidRevision,
};

pub const EditError = std.mem.Allocator.Error || error{
    UnknownFinding,
    GenerationOverflow,
    EditBlocked,
};

pub const PrepareError = std.mem.Allocator.Error || error{
    QueueMismatch,
    OperationCapacity,
    Finalizing,
    Completed,
    ReloadRequired,
    DraftRequired,
};

pub const TransitionError = error{
    DirtyRequiresDecision,
    RecoveryRequiresDecision,
    RecoveryCapacity,
};

const OwnedFindingIds = struct {
    arena: std.heap.ArenaAllocator,
    values: []committed_review.FindingId,

    fn init(
        allocator: std.mem.Allocator,
        findings: []const committed_review.Finding,
    ) InitError!OwnedFindingIds {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const values = try arena.allocator().alloc(committed_review.FindingId, findings.len);
        for (findings, 0..) |finding, index| {
            for (findings[0..index]) |prior| {
                if (prior.finding_id.eql(finding.finding_id)) return error.DuplicateFinding;
            }
            values[index] = .{ .bytes = try arena.allocator().dupe(u8, finding.finding_id.bytes) };
        }
        return .{ .arena = arena, .values = values };
    }

    fn deinit(self: *OwnedFindingIds) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// One allocator-owned complete mutable Review snapshot.
pub const DraftSnapshot = struct {
    arena: std.heap.ArenaAllocator,
    summary: ?[]u8,
    finding_dispositions: []committed_review.FindingDisposition,
    anchored_notes: []committed_review.AnchoredNote,

    pub fn init(
        allocator: std.mem.Allocator,
        summary: ?[]const u8,
        dispositions: []const committed_review.FindingDisposition,
        notes: []const committed_review.AnchoredNote,
    ) std.mem.Allocator.Error!DraftSnapshot {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned_summary = if (summary) |value|
            try arena.allocator().dupe(u8, value)
        else
            null;
        const owned_dispositions = try cloneDispositions(arena.allocator(), dispositions);
        const owned_notes = try cloneNotes(arena.allocator(), notes);
        return .{
            .arena = arena,
            .summary = owned_summary,
            .finding_dispositions = owned_dispositions,
            .anchored_notes = owned_notes,
        };
    }

    fn initDefault(
        allocator: std.mem.Allocator,
        finding_ids: []const committed_review.FindingId,
    ) std.mem.Allocator.Error!DraftSnapshot {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const dispositions = try arena.allocator().alloc(
            committed_review.FindingDisposition,
            finding_ids.len,
        );
        for (finding_ids, 0..) |id, index| {
            dispositions[index] = .{
                .finding_id = .{ .bytes = try arena.allocator().dupe(u8, id.bytes) },
                .disposition = .unreviewed,
            };
        }
        return .{
            .arena = arena,
            .summary = null,
            .finding_dispositions = dispositions,
            .anchored_notes = try arena.allocator().alloc(committed_review.AnchoredNote, 0),
        };
    }

    pub fn clone(self: *const DraftSnapshot, allocator: std.mem.Allocator) !DraftSnapshot {
        return init(allocator, self.summary, self.finding_dispositions, self.anchored_notes);
    }

    pub fn deinit(self: *DraftSnapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn eql(self: *const DraftSnapshot, other: *const DraftSnapshot) bool {
        if (!optionalTextEql(self.summary, other.summary) or
            self.finding_dispositions.len != other.finding_dispositions.len or
            self.anchored_notes.len != other.anchored_notes.len) return false;
        for (self.finding_dispositions, other.finding_dispositions) |left, right| {
            if (!left.finding_id.eql(right.finding_id) or left.disposition != right.disposition) return false;
        }
        for (self.anchored_notes, other.anchored_notes) |left, right| {
            if (!left.anchor.eql(right.anchor) or !std.mem.eql(u8, left.body, right.body) or
                left.related_finding_ids.len != right.related_finding_ids.len) return false;
            for (left.related_finding_ids, right.related_finding_ids) |left_id, right_id| {
                if (!left_id.eql(right_id)) return false;
            }
        }
        return true;
    }

    pub fn request(
        self: *const DraftSnapshot,
        binding: review_store.ReviewRunBinding,
        expected_revision: u64,
    ) review_store.DraftSaveRequest {
        return .{
            .binding = binding,
            .expected_revision = expected_revision,
            .summary = self.summary,
            .finding_dispositions = self.finding_dispositions,
            .anchored_notes = self.anchored_notes,
        };
    }
};

const PersistedDraft = struct {
    revision: u64,
    snapshot: DraftSnapshot,

    fn deinit(self: *PersistedDraft) void {
        self.snapshot.deinit();
        self.* = undefined;
    }
};

const CompletedReview = struct {
    decision: committed_review.ReviewResultValue,
    completed_at: [20]u8,
    snapshot: DraftSnapshot,

    fn deinit(self: *CompletedReview) void {
        self.snapshot.deinit();
        self.* = undefined;
    }
};

const Persisted = union(enum) {
    absent,
    draft: PersistedDraft,
    completed: CompletedReview,

    fn deinit(self: *Persisted) void {
        switch (self.*) {
            .absent => {},
            .draft => |*value| value.deinit(),
            .completed => |*value| value.deinit(),
        }
        self.* = undefined;
    }
};

const DraftOperation = struct { snapshot: DraftSnapshot };
const ResultOperation = struct {
    decision: committed_review.ReviewResultValue,
    snapshot: DraftSnapshot,
};

const OperationPayload = union(OperationKind) {
    draft: DraftOperation,
    result: ResultOperation,

    fn deinit(self: *OperationPayload) void {
        switch (self.*) {
            .draft => |*value| value.snapshot.deinit(),
            .result => |*value| value.snapshot.deinit(),
        }
        self.* = undefined;
    }
};

const OperationEntry = struct {
    operation_id: OperationId,
    expected_revision: u64,
    submitted_generation: u64,
    payload: OperationPayload,

    fn kind(self: *const OperationEntry) OperationKind {
        return std.meta.activeTag(self.payload);
    }

    fn deinit(self: *OperationEntry) void {
        self.payload.deinit();
        self.* = undefined;
    }

    fn decision(self: *const OperationEntry) ?committed_review.ReviewResultValue {
        return switch (self.payload) {
            .draft => null,
            .result => |value| value.decision,
        };
    }
};

pub const PreparedDraft = struct {
    token: QueueToken,
    entry: OperationEntry,
    replace_index: ?usize,
    superseded_operation_id: ?OperationId,
    owned: bool = true,

    pub fn request(self: *const PreparedDraft) review_store.DraftSaveRequest {
        return self.entry.payload.draft.snapshot.request(
            self.token.binding,
            self.entry.expected_revision,
        );
    }

    pub fn deinit(self: *PreparedDraft) void {
        if (self.owned) self.entry.deinit();
        self.* = undefined;
    }
};

pub const PreparedResult = struct {
    token: QueueToken,
    entry: OperationEntry,
    owned: bool = true,

    pub fn request(self: *const PreparedResult) review_store.ReviewResultCreateRequest {
        return .{
            .binding = self.token.binding,
            .expected_revision = self.entry.expected_revision,
            .decision = self.entry.payload.result.decision,
        };
    }

    pub fn deinit(self: *PreparedResult) void {
        if (self.owned) self.entry.deinit();
        self.* = undefined;
    }
};

pub const DraftPreparation = union(enum) { no_change, ready: PreparedDraft };

pub const Session = struct {
    binding: review_store.ReviewRunBinding,
    finding_ids: OwnedFindingIds,
    persisted: Persisted,
    working: ?DraftSnapshot,
    generation: u64 = 1,
    dirty_generation: ?u64 = null,
    operations: [max_operations]OperationEntry = undefined,
    operations_len: usize = 0,
    recovery_intents: [max_operations]OperationEntry = undefined,
    recovery_len: usize = 0,
    last_failure: ?FailureRecord = null,
    reconciliation: Reconciliation = .confirmed,

    pub fn init(
        allocator: std.mem.Allocator,
        binding: review_store.ReviewRunBinding,
        findings: *const committed_review.FindingSet,
        loaded_draft: ?*const committed_review.ReviewDraftState,
        loaded_result: ?*const committed_review.RevisionReviewResult,
    ) InitError!Session {
        if (!findings.review_id.eql(binding.review_id) or
            !findings.target.eql(&binding.target)) return error.InvalidBinding;
        if (loaded_draft) |draft| {
            if (draft.revision == 0) return error.InvalidRevision;
            draft.validateAgainst(findings, binding.findings_digest) catch return error.InvalidDraft;
        }
        if (loaded_result) |result| {
            result.validateAgainst(findings, binding.findings_digest) catch return error.InvalidResult;
            if (result.completed_at.len != 20) return error.InvalidResult;
            if (loaded_draft) |draft| {
                result.validateSubmitSnapshot(draft, findings, binding.findings_digest) catch
                    return error.InvalidResult;
            }
        }

        var finding_ids = try OwnedFindingIds.init(allocator, findings.findings);
        errdefer finding_ids.deinit();
        var session: Session = .{
            .binding = binding,
            .finding_ids = finding_ids,
            .persisted = .absent,
            .working = null,
        };
        finding_ids = undefined;
        errdefer session.deinit();

        if (loaded_result) |result| {
            var completed_at: [20]u8 = undefined;
            @memcpy(&completed_at, result.completed_at);
            session.persisted = .{ .completed = .{
                .decision = result.result,
                .completed_at = completed_at,
                .snapshot = try DraftSnapshot.init(
                    allocator,
                    result.summary,
                    result.finding_dispositions,
                    result.anchored_notes,
                ),
            } };
        } else if (loaded_draft) |draft| {
            var persisted_snapshot = try DraftSnapshot.init(
                allocator,
                draft.summary,
                draft.finding_dispositions,
                draft.anchored_notes,
            );
            errdefer persisted_snapshot.deinit();
            session.working = try persisted_snapshot.clone(allocator);
            session.persisted = .{ .draft = .{
                .revision = draft.revision,
                .snapshot = persisted_snapshot,
            } };
            persisted_snapshot = undefined;
        } else {
            session.working = try DraftSnapshot.initDefault(allocator, session.finding_ids.values);
        }
        return session;
    }

    pub fn deinit(self: *Session) void {
        for (self.operations[0..self.operations_len]) |*entry| entry.deinit();
        for (self.recovery_intents[0..self.recovery_len]) |*entry| entry.deinit();
        if (self.working) |*value| value.deinit();
        self.persisted.deinit();
        self.finding_ids.deinit();
        self.* = undefined;
    }

    pub fn lifecycle(self: *const Session) Lifecycle {
        if (self.persisted == .completed) return .completed;
        for (self.operations[0..self.operations_len]) |*entry| {
            if (entry.kind() == .result) return .finalizing;
        }
        for (self.operations[0..self.operations_len]) |*entry| {
            if (entry.kind() == .draft) return .saving;
        }
        if (self.last_failure != null or self.reconciliation == .reload_required or
            self.recovery_len != 0) return .failed;
        return .editable;
    }

    pub fn workingSnapshot(self: *const Session) ?*const DraftSnapshot {
        return if (self.working) |*value| value else null;
    }

    pub fn completedSnapshot(self: *const Session) ?*const DraftSnapshot {
        return switch (self.persisted) {
            .completed => |*value| &value.snapshot,
            .absent, .draft => null,
        };
    }

    pub fn confirmedRevision(self: *const Session) ?u64 {
        return switch (self.persisted) {
            .absent => 0,
            .draft => |value| value.revision,
            .completed => null,
        };
    }

    pub fn operationCount(self: *const Session) usize {
        return self.operations_len;
    }

    pub fn recoveryCount(self: *const Session) usize {
        return self.recovery_len;
    }

    pub fn editSummary(
        self: *Session,
        allocator: std.mem.Allocator,
        summary: ?[]const u8,
    ) EditError!void {
        try self.ensureEditable();
        const working = if (self.working) |*value| value else return error.EditBlocked;
        if (optionalTextEql(working.summary, summary)) return;
        const next_generation = std.math.add(u64, self.generation, 1) catch
            return error.GenerationOverflow;
        var replacement = try DraftSnapshot.init(
            allocator,
            summary,
            working.finding_dispositions,
            working.anchored_notes,
        );
        working.deinit();
        working.* = replacement;
        replacement = undefined;
        self.generation = next_generation;
        self.refreshDirtyGeneration();
    }

    pub fn editDisposition(
        self: *Session,
        allocator: std.mem.Allocator,
        id: committed_review.FindingId,
        disposition: committed_review.FindingDispositionValue,
    ) EditError!void {
        try self.ensureEditable();
        const working = if (self.working) |*value| value else return error.EditBlocked;
        var selected_index: ?usize = null;
        for (working.finding_dispositions, 0..) |candidate, index| {
            if (candidate.finding_id.eql(id)) {
                selected_index = index;
                break;
            }
        }
        const index = selected_index orelse return error.UnknownFinding;
        if (working.finding_dispositions[index].disposition == disposition) return;
        const next_generation = std.math.add(u64, self.generation, 1) catch
            return error.GenerationOverflow;
        var replacement = try working.clone(allocator);
        replacement.finding_dispositions[index].disposition = disposition;
        working.deinit();
        working.* = replacement;
        replacement = undefined;
        self.generation = next_generation;
        self.refreshDirtyGeneration();
    }

    pub fn prepareSave(
        self: *const Session,
        allocator: std.mem.Allocator,
        token: QueueToken,
        requirement: DraftRequirement,
    ) PrepareError!DraftPreparation {
        try self.ensurePreparationAllowed();
        try self.validateQueueToken(&token);
        const working = if (self.working) |*value| value else return error.Completed;

        if (self.newestDraftRepresentsWorking(working)) return .no_change;
        if (self.dirty_generation == null) {
            if (requirement == .dirty_only or self.persisted != .absent) return .no_change;
        }

        var replace_index: ?usize = null;
        var superseded: ?OperationId = null;
        var expected_revision: u64 = undefined;
        for (token.slice(), 0..) |queue_entry, index| {
            if (queue_entry.role == .pending_result or
                (queue_entry.role == .active and queue_entry.kind == .result)) return error.Finalizing;
            if (queue_entry.role == .pending_draft) {
                replace_index = index;
                superseded = queue_entry.operation_id;
                expected_revision = queue_entry.expected_revision;
            }
        }
        if (replace_index == null) {
            if (self.operations_len == max_operations) return error.OperationCapacity;
            expected_revision = if (lastDraft(self)) |entry|
                std.math.add(u64, entry.expected_revision, 1) catch return error.OperationCapacity
            else
                self.confirmedRevision() orelse return error.Completed;
        }

        return .{ .ready = .{
            .token = token,
            .entry = .{
                .operation_id = 0,
                .expected_revision = expected_revision,
                .submitted_generation = self.generation,
                .payload = .{ .draft = .{ .snapshot = try working.clone(allocator) } },
            },
            .replace_index = replace_index,
            .superseded_operation_id = superseded,
        } };
    }

    pub fn prepareResult(
        self: *const Session,
        allocator: std.mem.Allocator,
        token: QueueToken,
        decision: committed_review.ReviewResultValue,
    ) PrepareError!PreparedResult {
        try self.ensurePreparationAllowed();
        try self.validateQueueToken(&token);
        const working = if (self.working) |*value| value else return error.Completed;
        for (self.operations[0..self.operations_len]) |*entry| {
            if (entry.kind() == .result) return error.Finalizing;
        }
        if (self.dirty_generation != null or
            (lastDraft(self) == null and self.persisted == .absent)) return error.DraftRequired;
        if (self.operations_len == max_operations) return error.OperationCapacity;
        const expected_revision = if (lastDraft(self)) |entry|
            std.math.add(u64, entry.expected_revision, 1) catch return error.OperationCapacity
        else switch (self.persisted) {
            .draft => |value| value.revision,
            .absent => return error.DraftRequired,
            .completed => return error.Completed,
        };
        return .{
            .token = token,
            .entry = .{
                .operation_id = 0,
                .expected_revision = expected_revision,
                .submitted_generation = self.generation,
                .payload = .{ .result = .{
                    .decision = decision,
                    .snapshot = try working.clone(allocator),
                } },
            },
        };
    }

    /// Infallible post-admission commit. All allocation and validation has
    /// already happened in `prepareSave` and checked queue admission.
    pub fn commitDraft(
        self: *Session,
        prepared: *PreparedDraft,
        operation_id: OperationId,
        superseded_operation_id: ?OperationId,
    ) void {
        std.debug.assert(operation_id != 0);
        std.debug.assert(prepared.owned);
        std.debug.assert(prepared.superseded_operation_id == superseded_operation_id);
        self.clearRecovery();
        prepared.entry.operation_id = operation_id;
        if (prepared.replace_index) |index| {
            std.debug.assert(self.operations[index].operation_id == superseded_operation_id.?);
            self.operations[index].deinit();
            self.operations[index] = prepared.entry;
        } else {
            std.debug.assert(self.operations_len < max_operations);
            self.operations[self.operations_len] = prepared.entry;
            self.operations_len += 1;
        }
        prepared.owned = false;
        self.last_failure = null;
        self.refreshDirtyGeneration();
    }

    /// Infallible post-admission result tracking commit.
    pub fn commitResult(
        self: *Session,
        prepared: *PreparedResult,
        operation_id: OperationId,
    ) void {
        std.debug.assert(operation_id != 0);
        std.debug.assert(prepared.owned);
        std.debug.assert(self.operations_len < max_operations);
        self.clearRecovery();
        prepared.entry.operation_id = operation_id;
        self.operations[self.operations_len] = prepared.entry;
        self.operations_len += 1;
        prepared.owned = false;
        self.last_failure = null;
    }

    pub fn rejectDraft(
        self: *Session,
        prepared: *const PreparedDraft,
        reason: AdmissionFailure,
    ) void {
        self.last_failure = failureForEntry(&prepared.entry, .{ .admission = reason }, null, null);
    }

    pub fn rejectResult(
        self: *Session,
        prepared: *const PreparedResult,
        reason: AdmissionFailure,
    ) void {
        self.last_failure = failureForEntry(&prepared.entry, .{ .admission = reason }, null, null);
    }

    pub fn reduce(self: *Session, completion: Completion) Reduction {
        if (!self.binding.eql(completion.binding)) return .ignored;
        const index = self.findOperation(completion.operation_id) orelse return .ignored;
        const entry = &self.operations[index];
        if (index != 0 or entry.kind() != completion.kind or
            entry.expected_revision != completion.expected_revision)
        {
            self.requireReload(completion, index);
            return .reconciliation_required;
        }
        if (completion.failure) |failure| {
            if (completion.committed_revision != null or completion.completed_at != null) {
                self.requireReload(completion, index);
                return .reconciliation_required;
            }
            var terminal = self.takeOperation(index);
            self.last_failure = failureForEntry(
                &terminal,
                .{ .persistence = failure },
                completion.committed_revision,
                completion.completed_at,
            );
            self.appendRecovery(terminal);
            self.refreshDirtyGeneration();
            return .applied;
        }

        const committed_revision = completion.committed_revision orelse {
            self.requireReload(completion, index);
            return .reconciliation_required;
        };
        switch (entry.payload) {
            .draft => {
                const expected_commit = std.math.add(u64, entry.expected_revision, 1) catch {
                    self.requireReload(completion, index);
                    return .reconciliation_required;
                };
                if (committed_revision != expected_commit or completion.completed_at != null) {
                    self.requireReload(completion, index);
                    return .reconciliation_required;
                }
                if (!self.remainingChainCompatible(expected_commit)) {
                    self.requireReload(completion, index);
                    return .reconciliation_required;
                }
                var terminal = self.takeOperation(index);
                var snapshot = terminal.payload.draft.snapshot;
                terminal.payload = undefined;
                self.persisted.deinit();
                self.persisted = .{ .draft = .{
                    .revision = committed_revision,
                    .snapshot = snapshot,
                } };
                snapshot = undefined;
                self.refreshDirtyGeneration();
                self.last_failure = null;
                return .applied;
            },
            .result => |result_entry| {
                if (self.operations_len != 1 or committed_revision != entry.expected_revision or
                    completion.completed_at == null)
                {
                    self.requireReload(completion, index);
                    return .reconciliation_required;
                }
                const confirmed = switch (self.persisted) {
                    .draft => |*value| value,
                    .absent, .completed => {
                        self.requireReload(completion, index);
                        return .reconciliation_required;
                    },
                };
                if (confirmed.revision != entry.expected_revision or
                    !confirmed.snapshot.eql(&result_entry.snapshot))
                {
                    self.requireReload(completion, index);
                    return .reconciliation_required;
                }
                const decision = result_entry.decision;
                var terminal = self.takeOperation(index);
                var snapshot = terminal.payload.result.snapshot;
                terminal.payload = undefined;
                for (self.operations[0..self.operations_len]) |*dependent| dependent.deinit();
                self.operations_len = 0;
                self.clearRecovery();
                if (self.working) |*working| working.deinit();
                self.working = null;
                self.persisted.deinit();
                self.persisted = .{ .completed = .{
                    .decision = decision,
                    .completed_at = completion.completed_at.?,
                    .snapshot = snapshot,
                } };
                snapshot = undefined;
                self.dirty_generation = null;
                self.last_failure = null;
                return .applied;
            },
        }
    }

    pub fn markPreparationFailure(
        self: *Session,
        token: *const QueueToken,
        kind: OperationKind,
        decision: ?committed_review.ReviewResultValue,
    ) void {
        self.last_failure = .{
            .reason = .{ .admission = .preparation_failed },
            .kind = kind,
            .expected_revision = self.intendedExpectedRevision(token, kind),
            .submitted_generation = self.generation,
            .decision = decision,
        };
    }

    pub fn markAdmissionFailure(
        self: *Session,
        kind: OperationKind,
        decision: ?committed_review.ReviewResultValue,
        reason: AdmissionFailure,
    ) void {
        self.last_failure = .{
            .reason = .{ .admission = reason },
            .kind = kind,
            .expected_revision = self.confirmedRevision() orelse 0,
            .submitted_generation = self.generation,
            .decision = decision,
        };
    }

    pub fn markQueueMismatch(
        self: *Session,
        kind: OperationKind,
        decision: ?committed_review.ReviewResultValue,
    ) void {
        if (self.operations_len == 0) {
            self.last_failure = .{
                .reason = .internal_mismatch,
                .kind = kind,
                .expected_revision = self.confirmedRevision() orelse 0,
                .submitted_generation = self.generation,
                .decision = decision,
            };
        } else {
            const known = self.operations[0];
            self.last_failure = failureForEntry(&known, .internal_mismatch, null, null);
            std.debug.assert(self.recovery_len == 0);
            while (self.operations_len != 0) self.appendRecovery(self.takeOperation(0));
        }
        self.refreshDirtyGeneration();
        self.reconciliation = .reload_required;
    }

    fn ensureEditable(self: *const Session) EditError!void {
        if (self.reconciliation == .reload_required or self.persisted == .completed) return error.EditBlocked;
        for (self.operations[0..self.operations_len]) |*entry| {
            if (entry.kind() == .result) return error.EditBlocked;
        }
    }

    fn ensurePreparationAllowed(self: *const Session) PrepareError!void {
        if (self.reconciliation == .reload_required) return error.ReloadRequired;
        if (self.persisted == .completed) return error.Completed;
    }

    fn validateQueueToken(self: *const Session, token: *const QueueToken) PrepareError!void {
        if (!self.binding.eql(token.binding) or token.entries_len != self.operations_len) return error.QueueMismatch;
        for (token.slice(), self.operations[0..self.operations_len]) |queue_entry, operation| {
            if (queue_entry.operation_id != operation.operation_id or
                queue_entry.kind != operation.kind() or
                queue_entry.expected_revision != operation.expected_revision) return error.QueueMismatch;
        }
    }

    fn newestDraftRepresentsWorking(self: *const Session, working: *const DraftSnapshot) bool {
        const entry = lastDraft(self) orelse return false;
        return switch (entry.payload) {
            .draft => |value| value.snapshot.eql(working),
            .result => false,
        };
    }

    fn intendedExpectedRevision(
        self: *const Session,
        token: *const QueueToken,
        kind: OperationKind,
    ) u64 {
        if (kind == .draft) {
            for (token.slice()) |entry| {
                if (entry.role == .pending_draft) return entry.expected_revision;
            }
        }
        if (lastDraft(self)) |entry| {
            return std.math.add(u64, entry.expected_revision, 1) catch entry.expected_revision;
        }
        return self.confirmedRevision() orelse 0;
    }

    fn remainingChainCompatible(self: *const Session, committed_revision: u64) bool {
        if (self.operations_len <= 1) return true;
        const next = &self.operations[1];
        if (next.expected_revision != committed_revision) return false;
        if (self.operations_len == 2) return true;
        if (next.kind() != .draft or self.operations[2].kind() != .result) return false;
        const result_revision = std.math.add(u64, next.expected_revision, 1) catch return false;
        return self.operations[2].expected_revision == result_revision;
    }

    fn refreshDirtyGeneration(self: *Session) void {
        const working = if (self.working) |*value| value else {
            self.dirty_generation = null;
            return;
        };
        const matches = if (lastDraft(self)) |entry|
            switch (entry.payload) {
                .draft => |value| working.eql(&value.snapshot),
                .result => false,
            }
        else switch (self.persisted) {
            .absent => defaultSnapshotClean(working),
            .draft => |*value| working.eql(&value.snapshot),
            .completed => false,
        };
        self.dirty_generation = if (matches) null else self.generation;
    }

    fn findOperation(self: *const Session, operation_id: OperationId) ?usize {
        for (self.operations[0..self.operations_len], 0..) |entry, index| {
            if (entry.operation_id == operation_id) return index;
        }
        return null;
    }

    fn takeOperation(self: *Session, index: usize) OperationEntry {
        const result = self.operations[index];
        var cursor = index;
        while (cursor + 1 < self.operations_len) : (cursor += 1) {
            self.operations[cursor] = self.operations[cursor + 1];
        }
        self.operations_len -= 1;
        return result;
    }

    fn appendRecovery(self: *Session, entry: OperationEntry) void {
        std.debug.assert(self.recovery_len < max_operations);
        self.recovery_intents[self.recovery_len] = entry;
        self.recovery_len += 1;
    }

    fn clearRecovery(self: *Session) void {
        for (self.recovery_intents[0..self.recovery_len]) |*entry| entry.deinit();
        self.recovery_len = 0;
    }

    fn requireReload(self: *Session, completion: Completion, known_index: usize) void {
        const known = self.operations[known_index];
        self.last_failure = failureForEntry(
            &known,
            .internal_mismatch,
            completion.committed_revision,
            completion.completed_at,
        );
        std.debug.assert(self.recovery_len == 0);
        while (self.operations_len != 0) self.appendRecovery(self.takeOperation(0));
        self.refreshDirtyGeneration();
        self.reconciliation = .reload_required;
    }

    fn hasUnsubmittedDirty(self: *const Session) bool {
        return self.dirty_generation != null;
    }

    fn retireableClean(self: *const Session) bool {
        if (self.operations_len != 0 or self.recovery_len != 0 or self.last_failure != null or
            self.reconciliation != .confirmed or self.dirty_generation != null) return false;
        return switch (self.persisted) {
            .completed => true,
            .absent => self.working != null,
            .draft => |*persisted| if (self.working) |*working| working.eql(&persisted.snapshot) else false,
        };
    }

    fn canDetach(self: *const Session) bool {
        return !self.hasUnsubmittedDirty() and !self.retireableClean();
    }
};

const InstallCurrentAction = enum { none, retire, detach };

pub const PreparedInstall = struct {
    candidate: Session,
    reattach_index: ?usize,
    current_action: InstallCurrentAction,
    owned: bool = true,

    pub fn deinit(self: *PreparedInstall) void {
        if (self.owned) self.candidate.deinit();
        self.* = undefined;
    }
};

pub const ClearPlan = enum { none, retire, detach };

pub const RoutedReduction = struct {
    reduction: Reduction = .ignored,
    current_match: bool = false,
    detached_retired: bool = false,
};

pub const Owner = struct {
    current: ?Session = null,
    detached: [max_detached_sessions]Session = undefined,
    detached_len: usize = 0,

    pub fn deinit(self: *Owner) void {
        if (self.current) |*value| value.deinit();
        for (self.detached[0..self.detached_len]) |*value| value.deinit();
        self.* = .{};
    }

    pub fn currentSession(self: *Owner) ?*Session {
        return if (self.current) |*value| value else null;
    }

    pub fn currentSessionConst(self: *const Owner) ?*const Session {
        return if (self.current) |*value| value else null;
    }

    pub fn prepareInstall(
        self: *const Owner,
        candidate: *Session,
    ) TransitionError!PreparedInstall {
        const reattach_index = self.findDetached(candidate.binding);
        var action: InstallCurrentAction = .none;
        if (self.current) |*current| {
            if (current.binding.eql(candidate.binding)) {
                if (!current.retireableClean()) return if (current.hasUnsubmittedDirty())
                    error.DirtyRequiresDecision
                else
                    error.RecoveryRequiresDecision;
                action = .retire;
            } else if (current.retireableClean()) {
                action = .retire;
            } else if (current.canDetach()) {
                action = .detach;
            } else {
                return error.DirtyRequiresDecision;
            }
        }
        const retained = self.detached_len - @intFromBool(reattach_index != null) +
            @intFromBool(action == .detach);
        if (retained > max_detached_sessions) return error.RecoveryCapacity;
        const result: PreparedInstall = .{
            .candidate = candidate.*,
            .reattach_index = reattach_index,
            .current_action = action,
        };
        candidate.* = undefined;
        return result;
    }

    /// Publish a fully prepared transition without allocation or validation.
    pub fn commitInstall(self: *Owner, prepared: *PreparedInstall) void {
        std.debug.assert(prepared.owned);
        var next = if (prepared.reattach_index) |index| blk: {
            const value = self.takeDetached(index);
            prepared.candidate.deinit();
            break :blk value;
        } else blk: {
            const value = prepared.candidate;
            break :blk value;
        };
        if (self.current) |value| {
            var old = value;
            self.current = null;
            switch (prepared.current_action) {
                .none => unreachable,
                .retire => old.deinit(),
                .detach => {
                    std.debug.assert(self.detached_len < max_detached_sessions);
                    self.detached[self.detached_len] = old;
                    self.detached_len += 1;
                },
            }
        }
        self.current = next;
        next = undefined;
        prepared.owned = false;
    }

    pub fn prepareClear(self: *const Owner) TransitionError!ClearPlan {
        const current = if (self.current) |*value| value else return .none;
        if (current.retireableClean()) return .retire;
        if (!current.canDetach()) return error.DirtyRequiresDecision;
        if (self.detached_len == max_detached_sessions) return error.RecoveryCapacity;
        return .detach;
    }

    pub fn commitClear(self: *Owner, plan: ClearPlan) void {
        switch (plan) {
            .none => {},
            .retire => {
                var current = self.current.?;
                self.current = null;
                current.deinit();
            },
            .detach => {
                std.debug.assert(self.detached_len < max_detached_sessions);
                self.detached[self.detached_len] = self.current.?;
                self.detached_len += 1;
                self.current = null;
            },
        }
    }

    pub fn reduce(self: *Owner, completion: Completion) RoutedReduction {
        if (self.current) |*current| {
            if (current.binding.eql(completion.binding)) return .{
                .reduction = current.reduce(completion),
                .current_match = true,
            };
        }
        const index = self.findDetached(completion.binding) orelse return .{};
        const reduction = self.detached[index].reduce(completion);
        var retired = false;
        if (reduction == .applied and self.detached[index].retireableClean()) {
            var value = self.takeDetached(index);
            value.deinit();
            retired = true;
        }
        return .{ .reduction = reduction, .detached_retired = retired };
    }

    pub fn discardDetached(self: *Owner, binding: review_store.ReviewRunBinding) bool {
        const index = self.findDetached(binding) orelse return false;
        if (self.detached[index].operations_len != 0) return false;
        var value = self.takeDetached(index);
        value.deinit();
        return true;
    }

    /// Explicit user-authorized discard/reload seam. Accepted operations are
    /// never discarded; once their ledger is terminal, the exact current or
    /// detached recovery owner can be released before installing a fresh read.
    pub fn discardExact(self: *Owner, binding: review_store.ReviewRunBinding) bool {
        if (self.current) |*current| {
            if (current.binding.eql(binding)) {
                if (current.operations_len != 0) return false;
                var value = self.current.?;
                self.current = null;
                value.deinit();
                return true;
            }
        }
        const index = self.findDetached(binding) orelse return false;
        if (self.detached[index].operations_len != 0) return false;
        var value = self.takeDetached(index);
        value.deinit();
        return true;
    }

    fn findDetached(self: *const Owner, binding: review_store.ReviewRunBinding) ?usize {
        for (self.detached[0..self.detached_len], 0..) |*value, index| {
            if (value.binding.eql(binding)) return index;
        }
        return null;
    }

    fn takeDetached(self: *Owner, index: usize) Session {
        const result = self.detached[index];
        self.detached_len -= 1;
        if (index != self.detached_len) self.detached[index] = self.detached[self.detached_len];
        return result;
    }
};

fn lastDraft(session: *const Session) ?*const OperationEntry {
    var index = session.operations_len;
    while (index != 0) {
        index -= 1;
        const entry = &session.operations[index];
        if (entry.kind() == .draft) return entry;
    }
    return null;
}

fn failureForEntry(
    entry: *const OperationEntry,
    reason: FailureReason,
    observed_revision: ?u64,
    observed_time: ?[20]u8,
) FailureRecord {
    return .{
        .reason = reason,
        .kind = entry.kind(),
        .expected_revision = entry.expected_revision,
        .submitted_generation = entry.submitted_generation,
        .decision = entry.decision(),
        .observed_committed_revision = observed_revision,
        .observed_completed_at = observed_time,
    };
}

fn cloneDispositions(
    allocator: std.mem.Allocator,
    source: []const committed_review.FindingDisposition,
) ![]committed_review.FindingDisposition {
    const values = try allocator.alloc(committed_review.FindingDisposition, source.len);
    for (source, 0..) |value, index| {
        values[index] = .{
            .finding_id = .{ .bytes = try allocator.dupe(u8, value.finding_id.bytes) },
            .disposition = value.disposition,
        };
    }
    return values;
}

fn cloneNotes(
    allocator: std.mem.Allocator,
    source: []const committed_review.AnchoredNote,
) ![]committed_review.AnchoredNote {
    const values = try allocator.alloc(committed_review.AnchoredNote, source.len);
    for (source, 0..) |note, index| {
        var anchor = note.anchor;
        anchor.path_bytes = try allocator.dupe(u8, note.anchor.path_bytes);
        anchor.display_path = if (note.anchor.display_path) |value| try allocator.dupe(u8, value) else null;
        anchor.quoted_text = if (note.anchor.quoted_text) |value| try allocator.dupe(u8, value) else null;
        const related = try allocator.alloc(committed_review.FindingId, note.related_finding_ids.len);
        for (note.related_finding_ids, 0..) |id, related_index| {
            related[related_index] = .{ .bytes = try allocator.dupe(u8, id.bytes) };
        }
        values[index] = .{
            .anchor = anchor,
            .body = try allocator.dupe(u8, note.body),
            .related_finding_ids = related,
        };
    }
    return values;
}

fn optionalTextEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

fn defaultSnapshotClean(snapshot: *const DraftSnapshot) bool {
    if (snapshot.summary != null or snapshot.anchored_notes.len != 0) return false;
    for (snapshot.finding_dispositions) |value| {
        if (value.disposition != .unreviewed) return false;
    }
    return true;
}

test "human review session owns defaults edits and a coalesced save chain" {
    const allocator = std.testing.allocator;
    const binding = try testBinding(1);
    const findings = [_]committed_review.Finding{
        testFinding("F-1", "one"),
        testFinding("F-2", "two"),
    };
    const finding_set = testFindingSet(binding, &findings);
    var session = try Session.init(allocator, binding, &finding_set, null, null);
    defer session.deinit();

    try std.testing.expectEqual(Lifecycle.editable, session.lifecycle());
    try std.testing.expectEqual(@as(?u64, 0), session.confirmedRevision());
    try std.testing.expectEqual(@as(usize, 2), session.workingSnapshot().?.finding_dispositions.len);
    for (session.workingSnapshot().?.finding_dispositions) |value| {
        try std.testing.expectEqual(committed_review.FindingDispositionValue.unreviewed, value.disposition);
    }

    try session.editSummary(allocator, "first");
    try session.editDisposition(allocator, .{ .bytes = "F-1" }, .accepted);
    const first_generation = session.generation;
    const first_preparation = try session.prepareSave(allocator, emptyToken(binding, 1), .dirty_only);
    var first = first_preparation.ready;
    defer first.deinit();
    try std.testing.expectEqual(@as(u64, 0), first.request().expected_revision);
    session.commitDraft(&first, 11, null);
    try std.testing.expectEqual(Lifecycle.saving, session.lifecycle());

    try session.editSummary(allocator, "second");
    const pending_preparation = try session.prepareSave(
        allocator,
        oneToken(binding, 2, 11, .draft, 0, .active),
        .dirty_only,
    );
    var pending = pending_preparation.ready;
    defer pending.deinit();
    try std.testing.expectEqual(@as(u64, 1), pending.request().expected_revision);
    session.commitDraft(&pending, 12, null);

    try session.editSummary(allocator, "latest");
    const replacement_preparation = try session.prepareSave(
        allocator,
        twoToken(
            binding,
            3,
            .{ .operation_id = 11, .kind = .draft, .expected_revision = 0, .role = .active },
            .{ .operation_id = 12, .kind = .draft, .expected_revision = 1, .role = .pending_draft },
        ),
        .dirty_only,
    );
    var replacement = replacement_preparation.ready;
    defer replacement.deinit();
    try std.testing.expectEqual(@as(?OperationId, 12), replacement.superseded_operation_id);
    session.commitDraft(&replacement, 13, 12);

    try std.testing.expectEqual(
        Reduction.ignored,
        session.reduce(testCompletion(binding, 12, .draft, 1, 2, null, null)),
    );
    try std.testing.expectEqual(
        Reduction.applied,
        session.reduce(testCompletion(binding, 11, .draft, 0, 1, null, null)),
    );
    try std.testing.expectEqual(@as(?u64, 1), session.confirmedRevision());
    try std.testing.expectEqualStrings("latest", session.workingSnapshot().?.summary.?);
    try std.testing.expect(session.generation > first_generation);
    try std.testing.expectEqual(@as(?u64, null), session.dirty_generation);

    try std.testing.expectEqual(
        Reduction.applied,
        session.reduce(testCompletion(binding, 13, .draft, 1, 2, null, null)),
    );
    try std.testing.expectEqual(@as(?u64, 2), session.confirmedRevision());
    try std.testing.expectEqual(@as(?u64, null), session.dirty_generation);
    try std.testing.expectEqual(Lifecycle.editable, session.lifecycle());
    try session.editSummary(allocator, "temporary");
    try std.testing.expect(session.dirty_generation != null);
    try session.editSummary(allocator, "latest");
    try std.testing.expectEqual(@as(?u64, null), session.dirty_generation);
}

test "human review session revert during an accepted draft queues a corrective draft before result" {
    const allocator = std.testing.allocator;
    const binding = try testBinding(14);
    const finding_set = testFindingSet(binding, &.{});
    const loaded: committed_review.ReviewDraftState = .{
        .schema_version = committed_review.limits.schema_version,
        .review_id = binding.review_id,
        .target = binding.target,
        .findings_digest = binding.findings_digest,
        .revision = 1,
        .summary = "A",
        .finding_dispositions = &.{},
        .anchored_notes = &.{},
    };
    var session = try Session.init(allocator, binding, &finding_set, &loaded, null);
    defer session.deinit();

    try session.editSummary(allocator, "B");
    const b_preparation = try session.prepareSave(allocator, emptyToken(binding, 1), .dirty_only);
    var b = b_preparation.ready;
    defer b.deinit();
    try std.testing.expectEqual(@as(u64, 1), b.request().expected_revision);
    session.commitDraft(&b, 61, null);
    try std.testing.expectEqual(@as(?u64, null), session.dirty_generation);

    try session.editSummary(allocator, "A");
    try std.testing.expect(session.dirty_generation != null);
    const corrective_preparation = try session.prepareSave(
        allocator,
        oneToken(binding, 2, 61, .draft, 1, .active),
        .ensure_persisted,
    );
    var corrective = corrective_preparation.ready;
    defer corrective.deinit();
    try std.testing.expectEqual(@as(u64, 2), corrective.request().expected_revision);
    try std.testing.expectEqualStrings("A", corrective.request().summary.?);
    session.commitDraft(&corrective, 62, null);
    try std.testing.expectEqual(@as(?u64, null), session.dirty_generation);

    var result = try session.prepareResult(
        allocator,
        twoToken(
            binding,
            3,
            .{ .operation_id = 61, .kind = .draft, .expected_revision = 1, .role = .active },
            .{ .operation_id = 62, .kind = .draft, .expected_revision = 2, .role = .pending_draft },
        ),
        .approved,
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(u64, 3), result.request().expected_revision);
    session.commitResult(&result, 63);

    try std.testing.expectEqual(
        Reduction.applied,
        session.reduce(testCompletion(binding, 61, .draft, 1, 2, null, null)),
    );
    try std.testing.expectEqualStrings("A", session.workingSnapshot().?.summary.?);
    try std.testing.expectEqual(@as(?u64, null), session.dirty_generation);
    try std.testing.expectEqual(
        Reduction.applied,
        session.reduce(testCompletion(binding, 62, .draft, 2, 3, null, null)),
    );
    try std.testing.expectEqual(
        Reduction.applied,
        session.reduce(testCompletion(
            binding,
            63,
            .result,
            3,
            3,
            "2026-08-28T00:00:00Z".*,
            null,
        )),
    );
    try std.testing.expectEqual(Lifecycle.completed, session.lifecycle());
    try std.testing.expectEqualStrings("A", session.completedSnapshot().?.summary.?);
}

test "human review session finalization persists a complete initial draft then trusted result" {
    const allocator = std.testing.allocator;
    const binding = try testBinding(2);
    const findings = [_]committed_review.Finding{testFinding("F-1", "one")};
    const finding_set = testFindingSet(binding, &findings);
    var session = try Session.init(allocator, binding, &finding_set, null, null);
    defer session.deinit();

    const draft_preparation = try session.prepareSave(allocator, emptyToken(binding, 1), .ensure_persisted);
    var draft = draft_preparation.ready;
    defer draft.deinit();
    session.commitDraft(&draft, 21, null);

    var result = try session.prepareResult(
        allocator,
        oneToken(binding, 2, 21, .draft, 0, .pending_draft),
        .approved,
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(u64, 1), result.request().expected_revision);
    session.commitResult(&result, 22);
    try std.testing.expectEqual(Lifecycle.finalizing, session.lifecycle());
    try std.testing.expectError(error.EditBlocked, session.editSummary(allocator, "too late"));

    try std.testing.expectEqual(
        Reduction.applied,
        session.reduce(testCompletion(binding, 21, .draft, 0, 1, null, null)),
    );
    try std.testing.expectEqual(Lifecycle.finalizing, session.lifecycle());
    try std.testing.expectEqual(
        Reduction.applied,
        session.reduce(testCompletion(
            binding,
            22,
            .result,
            1,
            1,
            "2026-08-27T12:00:00Z".*,
            null,
        )),
    );
    try std.testing.expectEqual(Lifecycle.completed, session.lifecycle());
    try std.testing.expectEqual(@as(?u64, null), session.confirmedRevision());
    try std.testing.expect(session.workingSnapshot() == null);
}

test "human review session failures retain exact intents and known mismatches require reload" {
    const allocator = std.testing.allocator;
    const binding = try testBinding(3);
    const finding_set = testFindingSet(binding, &.{});

    var failed = try Session.init(allocator, binding, &finding_set, null, null);
    defer failed.deinit();
    try failed.editSummary(allocator, "recover me");
    const first_preparation = try failed.prepareSave(allocator, emptyToken(binding, 1), .dirty_only);
    var first = first_preparation.ready;
    defer first.deinit();
    failed.commitDraft(&first, 31, null);
    try failed.editSummary(allocator, "newer recovery");
    const second_preparation = try failed.prepareSave(
        allocator,
        oneToken(binding, 2, 31, .draft, 0, .active),
        .dirty_only,
    );
    var second = second_preparation.ready;
    defer second.deinit();
    failed.commitDraft(&second, 32, null);

    try std.testing.expectEqual(
        Reduction.applied,
        failed.reduce(testCompletion(binding, 31, .draft, 0, null, null, .io_failed)),
    );
    try std.testing.expectEqual(
        Reduction.applied,
        failed.reduce(testCompletion(binding, 32, .draft, 1, null, null, .io_failed)),
    );
    try std.testing.expectEqual(@as(usize, 2), failed.recoveryCount());
    try std.testing.expectEqualStrings("newer recovery", failed.workingSnapshot().?.summary.?);
    try std.testing.expectEqual(Lifecycle.failed, failed.lifecycle());

    const retry_preparation = try failed.prepareSave(allocator, emptyToken(binding, 3), .dirty_only);
    var retry = retry_preparation.ready;
    defer retry.deinit();
    failed.commitDraft(&retry, 33, null);
    try std.testing.expectEqual(@as(usize, 0), failed.recoveryCount());
    try std.testing.expectEqual(
        Reduction.applied,
        failed.reduce(testCompletion(binding, 33, .draft, 0, 1, null, null)),
    );
    try std.testing.expectEqualStrings("newer recovery", failed.persisted.draft.snapshot.summary.?);

    var mismatched = try Session.init(allocator, binding, &finding_set, null, null);
    defer mismatched.deinit();
    try mismatched.editSummary(allocator, "exact bytes");
    const mismatch_draft_preparation = try mismatched.prepareSave(allocator, emptyToken(binding, 1), .dirty_only);
    var mismatch_draft = mismatch_draft_preparation.ready;
    defer mismatch_draft.deinit();
    mismatched.commitDraft(&mismatch_draft, 41, null);
    var mismatch_result = try mismatched.prepareResult(
        allocator,
        oneToken(binding, 2, 41, .draft, 0, .active),
        .needs_changes,
    );
    defer mismatch_result.deinit();
    mismatched.commitResult(&mismatch_result, 42);

    try std.testing.expectEqual(
        Reduction.reconciliation_required,
        mismatched.reduce(testCompletion(binding, 41, .draft, 0, 9, null, null)),
    );
    try std.testing.expectEqual(Reconciliation.reload_required, mismatched.reconciliation);
    try std.testing.expectEqual(@as(usize, 0), mismatched.operationCount());
    try std.testing.expectEqual(@as(usize, 2), mismatched.recoveryCount());
    try std.testing.expectEqual(@as(?u64, 0), mismatched.confirmedRevision());
    try std.testing.expectError(error.EditBlocked, mismatched.editSummary(allocator, "blocked"));
    try std.testing.expectEqual(
        Reduction.ignored,
        mismatched.reduce(testCompletion(binding, 42, .result, 1, null, null, .run_invalid)),
    );
}

test "human review session owner routes detached terminals without retargeting current Run" {
    const allocator = std.testing.allocator;
    const binding_a = try testBinding(4);
    const binding_b = try testBinding(5);
    const findings_a = testFindingSet(binding_a, &.{});
    const findings_b = testFindingSet(binding_b, &.{});
    var owner: Owner = .{};
    defer owner.deinit();

    var session_a = try Session.init(allocator, binding_a, &findings_a, null, null);
    try session_a.editSummary(allocator, "A submitted");
    const prepared_a_value = try session_a.prepareSave(allocator, emptyToken(binding_a, 1), .dirty_only);
    var prepared_a = prepared_a_value.ready;
    defer prepared_a.deinit();
    session_a.commitDraft(&prepared_a, 51, null);
    var install_a = try owner.prepareInstall(&session_a);
    defer install_a.deinit();
    owner.commitInstall(&install_a);

    var session_b = try Session.init(allocator, binding_b, &findings_b, null, null);
    var install_b = try owner.prepareInstall(&session_b);
    defer install_b.deinit();
    owner.commitInstall(&install_b);
    try std.testing.expectEqual(@as(usize, 1), owner.detached_len);
    try std.testing.expect(owner.currentSessionConst().?.binding.eql(binding_b));

    const routed = owner.reduce(testCompletion(binding_a, 51, .draft, 0, 1, null, null));
    try std.testing.expectEqual(Reduction.applied, routed.reduction);
    try std.testing.expect(!routed.current_match);
    try std.testing.expect(routed.detached_retired);
    try std.testing.expectEqual(@as(usize, 0), owner.detached_len);
    try std.testing.expect(owner.currentSessionConst().?.binding.eql(binding_b));

    const foreign = try testBinding(6);
    try std.testing.expectEqual(
        Reduction.ignored,
        owner.reduce(testCompletion(foreign, 51, .draft, 0, 1, null, null)).reduction,
    );
}

test "human review session initialization and transition failures are atomic" {
    const allocator = std.testing.allocator;
    const binding = try testBinding(7);
    const duplicate_findings = [_]committed_review.Finding{
        testFinding("F-1", "one"),
        testFinding("F-1", "duplicate"),
    };
    const duplicate_set = testFindingSet(binding, &duplicate_findings);
    try std.testing.expectError(
        error.DuplicateFinding,
        Session.init(allocator, binding, &duplicate_set, null, null),
    );

    const finding_set = testFindingSet(binding, &.{});
    var session = try Session.init(allocator, binding, &finding_set, null, null);
    defer session.deinit();
    session.generation = std.math.maxInt(u64);
    try std.testing.expectError(error.GenerationOverflow, session.editSummary(allocator, "overflow"));
    try std.testing.expect(session.workingSnapshot().?.summary == null);
    try std.testing.expectError(
        error.UnknownFinding,
        session.editDisposition(allocator, .{ .bytes = "missing" }, .dismissed),
    );

    var owner: Owner = .{};
    defer owner.deinit();
    var current = try Session.init(allocator, binding, &finding_set, null, null);
    try current.editSummary(allocator, "dirty and unsubmitted");
    var install = try owner.prepareInstall(&current);
    defer install.deinit();
    owner.commitInstall(&install);
    const other_binding = try testBinding(8);
    const other_findings = testFindingSet(other_binding, &.{});
    var other = try Session.init(allocator, other_binding, &other_findings, null, null);
    defer other.deinit();
    try std.testing.expectError(error.DirtyRequiresDecision, owner.prepareInstall(&other));
    try std.testing.expect(owner.currentSessionConst().?.binding.eql(binding));
    try std.testing.expectEqualStrings(
        "dirty and unsubmitted",
        owner.currentSessionConst().?.workingSnapshot().?.summary.?,
    );
}

test "human review session losslessly owns loaded draft notes and completed result precedence" {
    const allocator = std.testing.allocator;
    const binding = try testBinding(10);
    const findings = [_]committed_review.Finding{testFinding("F-1", "one")};
    const finding_set = testFindingSet(binding, &findings);
    var summary = "saved".*;
    var note_body = "note".*;
    var path = "src/a.zig".*;
    const dispositions = [_]committed_review.FindingDisposition{.{
        .finding_id = .{ .bytes = "F-1" },
        .disposition = .dismissed,
    }};
    const related = [_]committed_review.FindingId{.{ .bytes = "F-1" }};
    const notes = [_]committed_review.AnchoredNote{.{
        .anchor = .{
            .path_bytes = &path,
            .display_path = "a.zig",
            .side = .after,
            .start_line = 1,
            .end_line = 1,
            .content_digest = committed_review.Sha256Digest.hash("line\n"),
            .quoted_text = "line",
        },
        .body = &note_body,
        .related_finding_ids = &related,
    }};
    const draft: committed_review.ReviewDraftState = .{
        .schema_version = committed_review.limits.schema_version,
        .review_id = binding.review_id,
        .target = binding.target,
        .findings_digest = binding.findings_digest,
        .revision = 3,
        .summary = &summary,
        .finding_dispositions = &dispositions,
        .anchored_notes = &notes,
    };
    var session = try Session.init(allocator, binding, &finding_set, &draft, null);
    defer session.deinit();
    summary[0] = 'X';
    note_body[0] = 'X';
    path[0] = 'X';
    try std.testing.expectEqual(@as(?u64, 3), session.confirmedRevision());
    try std.testing.expect(session.dirty_generation == null);
    try std.testing.expectEqualStrings("saved", session.workingSnapshot().?.summary.?);
    try std.testing.expectEqualStrings("note", session.workingSnapshot().?.anchored_notes[0].body);
    try std.testing.expectEqualStrings("src/a.zig", session.workingSnapshot().?.anchored_notes[0].anchor.path_bytes);

    const result: committed_review.RevisionReviewResult = .{
        .schema_version = committed_review.limits.schema_version,
        .review_id = binding.review_id,
        .target = binding.target,
        .findings_digest = binding.findings_digest,
        .result = .approved,
        .completed_at = "2026-08-27T12:00:00Z",
        .summary = draft.summary,
        .finding_dispositions = &dispositions,
        .anchored_notes = &notes,
    };
    var completed = try Session.init(allocator, binding, &finding_set, &draft, &result);
    defer completed.deinit();
    try std.testing.expectEqual(Lifecycle.completed, completed.lifecycle());
    try std.testing.expect(completed.workingSnapshot() == null);
    try std.testing.expectEqual(@as(?u64, null), completed.confirmedRevision());

    var zero_revision = draft;
    zero_revision.revision = 0;
    try std.testing.expectError(
        error.InvalidRevision,
        Session.init(allocator, binding, &finding_set, &zero_revision, null),
    );
    var missing_dispositions = draft;
    missing_dispositions.finding_dispositions = &.{};
    try std.testing.expectError(
        error.InvalidDraft,
        Session.init(allocator, binding, &finding_set, &missing_dispositions, null),
    );
}

test "human review session owner refuses a sixty-fifth detached recovery atomically" {
    const allocator = std.testing.allocator;
    var owner: Owner = .{};
    defer owner.deinit();
    for (0..max_detached_sessions) |index| {
        const binding = try testBinding(@intCast(index + 20));
        const findings = testFindingSet(binding, &.{});
        var session = try Session.init(allocator, binding, &findings, null, null);
        session.markAdmissionFailure(.draft, null, .store_unavailable);
        owner.detached[index] = session;
        owner.detached_len += 1;
    }
    const current_binding = try testBinding(100);
    const current_findings = testFindingSet(current_binding, &.{});
    var current = try Session.init(allocator, current_binding, &current_findings, null, null);
    current.markAdmissionFailure(.draft, null, .store_unavailable);
    owner.current = current;

    const candidate_binding = try testBinding(101);
    const candidate_findings = testFindingSet(candidate_binding, &.{});
    var candidate = try Session.init(allocator, candidate_binding, &candidate_findings, null, null);
    defer candidate.deinit();
    try std.testing.expectError(error.RecoveryCapacity, owner.prepareInstall(&candidate));
    try std.testing.expectEqual(max_detached_sessions, owner.detached_len);
    try std.testing.expect(owner.currentSessionConst().?.binding.eql(current_binding));
    try std.testing.expect(candidate.binding.eql(candidate_binding));
}

fn emptyToken(binding: review_store.ReviewRunBinding, epoch: u64) QueueToken {
    return .{ .binding = binding, .epoch = epoch };
}

fn oneToken(
    binding: review_store.ReviewRunBinding,
    epoch: u64,
    operation_id: OperationId,
    kind: OperationKind,
    expected_revision: u64,
    role: QueueRole,
) QueueToken {
    var token = emptyToken(binding, epoch);
    token.entries[0] = .{
        .operation_id = operation_id,
        .kind = kind,
        .expected_revision = expected_revision,
        .role = role,
    };
    token.entries_len = 1;
    return token;
}

fn twoToken(
    binding: review_store.ReviewRunBinding,
    epoch: u64,
    first: QueueEntry,
    second: QueueEntry,
) QueueToken {
    var token = emptyToken(binding, epoch);
    token.entries[0] = first;
    token.entries[1] = second;
    token.entries_len = 2;
    return token;
}

fn testCompletion(
    binding: review_store.ReviewRunBinding,
    operation_id: OperationId,
    kind: OperationKind,
    expected_revision: u64,
    committed_revision: ?u64,
    completed_at: ?[20]u8,
    failure: ?review_store.PersistenceFailure,
) Completion {
    return .{
        .operation_id = operation_id,
        .binding = binding,
        .kind = kind,
        .expected_revision = expected_revision,
        .committed_revision = committed_revision,
        .completed_at = completed_at,
        .failure = failure,
    };
}

fn testBinding(suffix: u8) !review_store.ReviewRunBinding {
    var repository_id = try committed_review.ReviewRepositoryId.parse("123e4567-e89b-42d3-a456-426614174000");
    repository_id.bytes[15] = suffix;
    var review_id = try committed_review.ReviewId.parse("223e4567-e89b-42d3-a456-426614174000");
    review_id.bytes[15] = suffix;
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
        .findings_digest = committed_review.Sha256Digest.hash(&.{suffix}),
    };
}

fn testFinding(id: []const u8, title: []const u8) committed_review.Finding {
    return .{
        .finding_id = .{ .bytes = id },
        .anchor = .{
            .path_bytes = "src/main.zig",
            .side = .after,
            .start_line = 1,
            .end_line = 1,
            .content_digest = committed_review.Sha256Digest.hash("line\n"),
        },
        .severity = .warning,
        .title = title,
        .body = "body",
    };
}

fn testFindingSet(
    binding: review_store.ReviewRunBinding,
    findings: []const committed_review.Finding,
) committed_review.FindingSet {
    return .{
        .schema_version = committed_review.limits.schema_version,
        .review_id = binding.review_id,
        .created_at = "2026-08-27T00:00:00Z",
        .timing = .{ .duration_ms = 1 },
        .target = binding.target,
        .producer = .{ .name = "test" },
        .findings = findings,
    };
}
