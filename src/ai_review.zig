//! Provider-neutral deterministic AI review protocol facade.

pub const limits = @import("ai_review/limits.zig");
pub const protocol = @import("ai_review/protocol.zig");
pub const codec = @import("ai_review/codec.zig");

pub const ReviewPlanSummary = protocol.ReviewPlanSummary;
pub const ReviewUnit = protocol.ReviewUnit;
pub const ReviewLocation = protocol.ReviewLocation;
pub const FindingCandidate = protocol.FindingCandidate;
pub const FindingCandidatePayload = protocol.FindingCandidatePayload;
pub const FindingCandidateBatch = protocol.FindingCandidateBatch;
pub const CapabilityResponse = protocol.CapabilityResponse;

test {
    _ = limits;
    _ = protocol;
    _ = codec;
}
