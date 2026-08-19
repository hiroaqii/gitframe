const std = @import("std");
const anchor_mod = @import("anchor.zig");
const identity = @import("identity.zig");
const target_mod = @import("target.zig");

pub const FindingId = struct {
    bytes: []const u8,

    pub fn eql(self: FindingId, other: FindingId) bool {
        return std.mem.eql(u8, self.bytes, other.bytes);
    }
};

pub const Producer = struct {
    name: []const u8,
    model: ?[]const u8 = null,
    version: ?[]const u8 = null,
    skill_version: ?[]const u8 = null,

    pub fn eql(self: Producer, other: Producer) bool {
        return std.mem.eql(u8, self.name, other.name) and
            optionalTextEql(self.model, other.model) and
            optionalTextEql(self.version, other.version) and
            optionalTextEql(self.skill_version, other.skill_version);
    }
};

pub const Severity = enum {
    info,
    warning,
    @"error",
};

pub const Finding = struct {
    finding_id: FindingId,
    anchor: anchor_mod.CodeAnchor,
    severity: Severity,
    title: []const u8,
    body: []const u8,
    suggestion: ?[]const u8 = null,
};

pub const FindingSet = struct {
    schema_version: u64,
    review_id: identity.ReviewId,
    target: target_mod.CommittedReviewTarget,
    producer: Producer,
    findings: []const Finding,

    pub fn findingIndex(self: FindingSet, id: FindingId) ?usize {
        for (self.findings, 0..) |finding, index| {
            if (finding.finding_id.eql(id)) return index;
        }
        return null;
    }

    pub fn parseStrict(
        allocator: std.mem.Allocator,
        bytes: []const u8,
    ) @import("codec.zig").ParseError!@import("codec.zig").Parsed(FindingSet) {
        return @import("codec.zig").parseFindingSet(allocator, bytes);
    }

    pub fn writeCanonical(self: *const FindingSet, allocator: std.mem.Allocator) @import("codec.zig").ParseError![]u8 {
        return @import("codec.zig").writeFindingSetAlloc(allocator, self);
    }
};

pub const DisplayMetadata = struct {
    base_label: ?[]const u8 = null,
    head_label: ?[]const u8 = null,
};

pub const ReviewRunManifest = struct {
    schema_version: u64,
    review_id: identity.ReviewId,
    review_repository_id: identity.ReviewRepositoryId,
    target: target_mod.CommittedReviewTarget,
    created_at: []const u8,
    display: ?DisplayMetadata,
    finding_count: u32,
    producer: Producer,
    findings_digest: identity.Sha256Digest,

    pub fn parseStrict(
        allocator: std.mem.Allocator,
        bytes: []const u8,
    ) @import("codec.zig").ParseError!@import("codec.zig").Parsed(ReviewRunManifest) {
        return @import("codec.zig").parseManifest(allocator, bytes);
    }

    pub fn writeCanonical(self: *const ReviewRunManifest, allocator: std.mem.Allocator) @import("codec.zig").ParseError![]u8 {
        return @import("codec.zig").writeManifestAlloc(allocator, self);
    }

    pub fn validateFindingSet(
        self: *const ReviewRunManifest,
        exact_findings_bytes: []const u8,
        finding_set: *const FindingSet,
    ) @import("codec.zig").ValidationError!void {
        return @import("codec.zig").validateManifestFindingSet(self, exact_findings_bytes, finding_set);
    }
};

pub const FindingDispositionValue = enum {
    unreviewed,
    accepted,
    dismissed,
};

pub const FindingDisposition = struct {
    finding_id: FindingId,
    disposition: FindingDispositionValue,
};

pub const ReviewDraftState = struct {
    schema_version: u64,
    review_id: identity.ReviewId,
    target: target_mod.CommittedReviewTarget,
    findings_digest: identity.Sha256Digest,
    revision: u64,
    summary: ?[]const u8,
    finding_dispositions: []const FindingDisposition,

    pub fn parseStrict(
        allocator: std.mem.Allocator,
        bytes: []const u8,
    ) @import("codec.zig").ParseError!@import("codec.zig").Parsed(ReviewDraftState) {
        return @import("codec.zig").parseDraft(allocator, bytes);
    }

    pub fn writeCanonical(self: *const ReviewDraftState, allocator: std.mem.Allocator) @import("codec.zig").ParseError![]u8 {
        return @import("codec.zig").writeDraftAlloc(allocator, self);
    }

    pub fn validateAgainst(
        self: *const ReviewDraftState,
        finding_set: *const FindingSet,
        findings_digest: identity.Sha256Digest,
    ) @import("codec.zig").ValidationError!void {
        return @import("codec.zig").validateDraftAgainst(self, finding_set, findings_digest);
    }
};

pub const ReviewResultValue = enum {
    approved,
    needs_changes,
    canceled,
};

pub const AnchoredNote = struct {
    anchor: anchor_mod.CodeAnchor,
    body: []const u8,
    related_finding_ids: []const FindingId,
};

pub const RevisionReviewResult = struct {
    schema_version: u64,
    review_id: identity.ReviewId,
    target: target_mod.CommittedReviewTarget,
    findings_digest: identity.Sha256Digest,
    result: ReviewResultValue,
    summary: ?[]const u8,
    finding_dispositions: []const FindingDisposition,
    anchored_notes: []const AnchoredNote,

    pub fn parseStrict(
        allocator: std.mem.Allocator,
        bytes: []const u8,
    ) @import("codec.zig").ParseError!@import("codec.zig").Parsed(RevisionReviewResult) {
        return @import("codec.zig").parseResult(allocator, bytes);
    }

    pub fn writeCanonical(self: *const RevisionReviewResult, allocator: std.mem.Allocator) @import("codec.zig").ParseError![]u8 {
        return @import("codec.zig").writeResultAlloc(allocator, self);
    }

    pub fn validateAgainst(
        self: *const RevisionReviewResult,
        finding_set: *const FindingSet,
        findings_digest: identity.Sha256Digest,
    ) @import("codec.zig").ValidationError!void {
        return @import("codec.zig").validateResultAgainst(self, finding_set, findings_digest);
    }
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
}
