//! Provider-neutral deterministic AI review protocol facade.

pub const limits = @import("ai_review/limits.zig");
pub const protocol = @import("ai_review/protocol.zig");
pub const codec = @import("ai_review/codec.zig");
pub const producer = @import("ai_review/producer.zig");
pub const finding_projection = @import("ai_review/finding_projection.zig");
pub const finding_card = @import("ai_review/finding_card.zig");
pub const store_service = @import("ai_review/store_service.zig");
pub const store_read_command = @import("ai_review/store_read_command.zig");
pub const maintenance_command = @import("ai_review/maintenance_command.zig");
pub const result_read_command = @import("ai_review/result_read_command.zig");

pub const ReviewPlanSummary = protocol.ReviewPlanSummary;
pub const ReviewUnit = protocol.ReviewUnit;
pub const ReviewLocation = protocol.ReviewLocation;
pub const FindingCandidate = protocol.FindingCandidate;
pub const FindingCandidatePayload = protocol.FindingCandidatePayload;
pub const FindingCandidateBatch = protocol.FindingCandidateBatch;
pub const CapabilityResponse = protocol.CapabilityResponse;
pub const ArtifactInput = producer.Input;
pub const ArtifactBundle = producer.ArtifactBundle;
pub const AnchorVerifier = producer.AnchorVerifier;

test {
    _ = limits;
    _ = protocol;
    _ = codec;
    _ = producer;
    _ = finding_projection;
    _ = finding_card;
    _ = store_service;
    _ = store_read_command;
    _ = result_read_command;
    _ = maintenance_command;
}
