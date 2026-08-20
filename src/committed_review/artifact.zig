//! Provider-neutral values stored in the four committed-review v1 artifacts.
//!
//! Parsed string and slice fields borrow one codec-owned arena. Producers own
//! immutable finding/manifest bytes; GitFrame owns mutable draft state until a
//! terminal immutable result exists.

const std = @import("std");
const anchor_mod = @import("anchor.zig");
const identity = @import("identity.zig");
const target_mod = @import("target.zig");

/// Bounded identifier whose namespace is one `ReviewId`, not a repository.
pub const FindingId = struct {
    bytes: []const u8,

    /// Compare the complete identifier bytes.
    pub fn eql(self: FindingId, other: FindingId) bool {
        return std.mem.eql(u8, self.bytes, other.bytes);
    }
};

/// Human-readable provenance supplied by the finding producer.
pub const Producer = struct {
    name: []const u8,
    model: ?[]const u8 = null,
    version: ?[]const u8 = null,
    skill_version: ?[]const u8 = null,

    /// Compare all present provenance fields without defaulting absent values.
    pub fn eql(self: Producer, other: Producer) bool {
        return std.mem.eql(u8, self.name, other.name) and
            optionalTextEql(self.model, other.model) and
            optionalTextEql(self.version, other.version) and
            optionalTextEql(self.skill_version, other.skill_version);
    }
};

/// Producer assessment only; it never derives the human review result.
pub const Severity = enum {
    info,
    warning,
    @"error",
};

/// One immutable producer finding, durably bound to a `CodeAnchor`.
pub const Finding = struct {
    finding_id: FindingId,
    anchor: anchor_mod.CodeAnchor,
    severity: Severity,
    title: []const u8,
    body: []const u8,
    suggestion: ?[]const u8 = null,
};

/// Optional producer-observed timing provenance for one immutable FindingSet.
pub const FindingTiming = struct {
    duration_ms: u64,
};

/// Producer-owned immutable findings payload for one run and exact target.
pub const FindingSet = struct {
    schema_version: u64,
    review_id: identity.ReviewId,
    /// UTC second at which the producer finalized this immutable payload.
    created_at: []const u8,
    timing: ?FindingTiming = null,
    target: target_mod.CommittedReviewTarget,
    producer: Producer,
    findings: []const Finding,

    /// Locate an ID within this run-local payload without cross-run fallback.
    pub fn findingIndex(self: FindingSet, id: FindingId) ?usize {
        for (self.findings, 0..) |finding, index| {
            if (finding.finding_id.eql(id)) return index;
        }
        return null;
    }

    /// Parse a bounded strict artifact whose borrowed fields live until the
    /// returned `Parsed` owner is deinitialized.
    pub fn parseStrict(
        allocator: std.mem.Allocator,
        bytes: []const u8,
    ) @import("codec.zig").ParseError!@import("codec.zig").Parsed(FindingSet) {
        return @import("codec.zig").parseFindingSet(allocator, bytes);
    }

    /// Allocate canonical compact JSON, including its required final LF.
    pub fn writeCanonical(self: *const FindingSet, allocator: std.mem.Allocator) @import("codec.zig").ParseError![]u8 {
        return @import("codec.zig").writeFindingSetAlloc(allocator, self);
    }
};

/// Optional labels for display only; labels do not participate in target equality.
pub const DisplayMetadata = struct {
    base_label: ?[]const u8 = null,
    head_label: ?[]const u8 = null,
};

/// Immutable local binding metadata for one producer run.
pub const ReviewRunManifest = struct {
    schema_version: u64,
    review_id: identity.ReviewId,
    review_repository_id: identity.ReviewRepositoryId,
    target: target_mod.CommittedReviewTarget,
    created_at: []const u8,
    display: ?DisplayMetadata,
    finding_count: u32,
    producer: Producer,
    /// Digest of every exact byte in the stored `findings.json`, including
    /// JSON whitespace, escapes, field order, and its terminating LF.
    findings_digest: identity.Sha256Digest,

    /// Parse with one owner for all returned borrowed fields.
    pub fn parseStrict(
        allocator: std.mem.Allocator,
        bytes: []const u8,
    ) @import("codec.zig").ParseError!@import("codec.zig").Parsed(ReviewRunManifest) {
        return @import("codec.zig").parseManifest(allocator, bytes);
    }

    /// Allocate the canonical manifest representation and final LF.
    pub fn writeCanonical(self: *const ReviewRunManifest, allocator: std.mem.Allocator) @import("codec.zig").ParseError![]u8 {
        return @import("codec.zig").writeManifestAlloc(allocator, self);
    }

    /// Bind this manifest to both the exact findings bytes and decoded value.
    pub fn validateFindingSet(
        self: *const ReviewRunManifest,
        exact_findings_bytes: []const u8,
        finding_set: *const FindingSet,
    ) @import("codec.zig").ValidationError!void {
        return @import("codec.zig").validateManifestFindingSet(self, exact_findings_bytes, finding_set);
    }
};

/// Explicit human disposition; `accepted` means agreement with the finding,
/// not that a patch was applied or that the complete review was approved.
pub const FindingDispositionValue = enum {
    unreviewed,
    accepted,
    dismissed,
};

/// One run-local finding disposition in draft or terminal state.
pub const FindingDisposition = struct {
    finding_id: FindingId,
    disposition: FindingDispositionValue,
};

/// GitFrame-owned mutable state before a terminal result is created.
pub const ReviewDraftState = struct {
    schema_version: u64,
    review_id: identity.ReviewId,
    target: target_mod.CommittedReviewTarget,
    /// Digest of the exact immutable findings payload this revision edits.
    findings_digest: identity.Sha256Digest,
    /// Monotonic positive draft revision used by the storage owner for CAS.
    revision: u64,
    summary: ?[]const u8,
    finding_dispositions: []const FindingDisposition,
    anchored_notes: []const AnchoredNote,

    /// Parse with one owner for all returned borrowed fields.
    pub fn parseStrict(
        allocator: std.mem.Allocator,
        bytes: []const u8,
    ) @import("codec.zig").ParseError!@import("codec.zig").Parsed(ReviewDraftState) {
        return @import("codec.zig").parseDraft(allocator, bytes);
    }

    /// Allocate the canonical draft representation and final LF.
    pub fn writeCanonical(self: *const ReviewDraftState, allocator: std.mem.Allocator) @import("codec.zig").ParseError![]u8 {
        return @import("codec.zig").writeDraftAlloc(allocator, self);
    }

    /// Require exact run, target, digest, and one disposition per finding.
    pub fn validateAgainst(
        self: *const ReviewDraftState,
        finding_set: *const FindingSet,
        findings_digest: identity.Sha256Digest,
    ) @import("codec.zig").ValidationError!void {
        return @import("codec.zig").validateDraftAgainst(self, finding_set, findings_digest);
    }
};

/// Human terminal decision. `canceled` is a normal valid terminal.
pub const ReviewResultValue = enum {
    approved,
    needs_changes,
    canceled,
};

/// Human-authored note with its own content-authoritative anchor.
pub const AnchoredNote = struct {
    anchor: anchor_mod.CodeAnchor,
    body: []const u8,
    related_finding_ids: []const FindingId,
};

/// GitFrame-owned immutable terminal result for one exact review run.
pub const RevisionReviewResult = struct {
    schema_version: u64,
    review_id: identity.ReviewId,
    target: target_mod.CommittedReviewTarget,
    /// Digest of the exact immutable findings payload admitted by this result.
    findings_digest: identity.Sha256Digest,
    result: ReviewResultValue,
    /// UTC second at which the human terminal decision was admitted.
    completed_at: []const u8,
    summary: ?[]const u8,
    finding_dispositions: []const FindingDisposition,
    anchored_notes: []const AnchoredNote,

    /// Parse with one owner for all returned borrowed fields.
    pub fn parseStrict(
        allocator: std.mem.Allocator,
        bytes: []const u8,
    ) @import("codec.zig").ParseError!@import("codec.zig").Parsed(RevisionReviewResult) {
        return @import("codec.zig").parseResult(allocator, bytes);
    }

    /// Allocate the canonical terminal result and final LF.
    pub fn writeCanonical(self: *const RevisionReviewResult, allocator: std.mem.Allocator) @import("codec.zig").ParseError![]u8 {
        return @import("codec.zig").writeResultAlloc(allocator, self);
    }

    /// Require exact run, target, digest, dispositions, and related IDs.
    pub fn validateAgainst(
        self: *const RevisionReviewResult,
        finding_set: *const FindingSet,
        findings_digest: identity.Sha256Digest,
    ) @import("codec.zig").ValidationError!void {
        return @import("codec.zig").validateResultAgainst(self, finding_set, findings_digest);
    }

    /// Require this terminal value to be a lossless snapshot of `draft`.
    pub fn validateSubmitSnapshot(
        self: *const RevisionReviewResult,
        draft: *const ReviewDraftState,
        finding_set: *const FindingSet,
        findings_digest: identity.Sha256Digest,
    ) @import("codec.zig").ValidationError!void {
        return @import("codec.zig").validateSubmitSnapshot(self, draft, finding_set, findings_digest);
    }
};

/// Store-neutral state derived only from already validated artifact presence.
pub const ReviewRunState = enum {
    new,
    draft,
    completed,

    /// A valid result has precedence over a retained valid draft.
    pub fn derive(valid_draft_present: bool, valid_result_present: bool) ReviewRunState {
        if (valid_result_present) return .completed;
        if (valid_draft_present) return .draft;
        return .new;
    }

    /// Admit creation or replacement of mutable draft state.
    pub fn admitDraftMutation(self: ReviewRunState) MutationAdmissionError!void {
        if (self == .completed) return error.AlreadyCompleted;
    }

    /// Admit create-once terminal result publication only after a valid draft.
    pub fn admitResultCreation(self: ReviewRunState) MutationAdmissionError!void {
        return switch (self) {
            .new => error.DraftRequired,
            .draft => {},
            .completed => error.AlreadyCompleted,
        };
    }
};

pub const MutationAdmissionError = error{
    DraftRequired,
    AlreadyCompleted,
};

fn optionalTextEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

test "finding IDs remain scoped values instead of review identities" {
    const a: FindingId = .{ .bytes = "finding-1" };
    const b: FindingId = .{ .bytes = "finding-2" };
    try std.testing.expect(a.eql(a));
    try std.testing.expect(!a.eql(b));
    try testReviewRunStateAdmission();
}

fn testReviewRunStateAdmission() !void {
    try std.testing.expectEqual(ReviewRunState.new, ReviewRunState.derive(false, false));
    try std.testing.expectEqual(ReviewRunState.draft, ReviewRunState.derive(true, false));
    try std.testing.expectEqual(ReviewRunState.completed, ReviewRunState.derive(false, true));
    try std.testing.expectEqual(ReviewRunState.completed, ReviewRunState.derive(true, true));

    try ReviewRunState.new.admitDraftMutation();
    try ReviewRunState.draft.admitDraftMutation();
    try std.testing.expectError(error.AlreadyCompleted, ReviewRunState.completed.admitDraftMutation());
    try std.testing.expectError(error.DraftRequired, ReviewRunState.new.admitResultCreation());
    try ReviewRunState.draft.admitResultCreation();
    try std.testing.expectError(error.AlreadyCompleted, ReviewRunState.completed.admitResultCreation());

    // A failed future result publication leaves valid-result evidence absent.
    try std.testing.expectEqual(ReviewRunState.draft, ReviewRunState.derive(true, false));
}
