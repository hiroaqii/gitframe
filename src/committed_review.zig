//! Provider-neutral, page-neutral committed-review identity and wire contract.
//! Store publication, provider execution, Git resolution, and UI state are
//! deliberately outside this facade.

pub const limits = @import("committed_review/limits.zig");
pub const strict_json = @import("committed_review/strict_json.zig");
pub const codec = @import("committed_review/codec.zig");

const anchor = @import("committed_review/anchor.zig");
const artifact = @import("committed_review/artifact.zig");
const identity = @import("committed_review/identity.zig");
const repository_binding = @import("committed_review/repository_binding.zig");
const target = @import("committed_review/target.zig");

pub const ReviewId = identity.ReviewId;
pub const ReviewRepositoryId = identity.ReviewRepositoryId;
pub const Sha256Digest = identity.Sha256Digest;

pub const GitCommonDirectoryLocator = repository_binding.GitCommonDirectoryLocator;
pub const RepositoryBindingResult = repository_binding.RepositoryBindingResult;
pub const RepositoryBindingRegistry = repository_binding.RepositoryBindingRegistry;

pub const ObjectFormat = target.ObjectFormat;
pub const SourceKind = target.SourceKind;
pub const ObjectId = target.ObjectId;
pub const CommittedReviewTarget = target.CommittedReviewTarget;

pub const AnchorSide = anchor.AnchorSide;
pub const CodeAnchor = anchor.CodeAnchor;

pub const FindingId = artifact.FindingId;
pub const Producer = artifact.Producer;
pub const Severity = artifact.Severity;
pub const Finding = artifact.Finding;
pub const FindingTiming = artifact.FindingTiming;
pub const FindingSet = artifact.FindingSet;
pub const DisplayMetadata = artifact.DisplayMetadata;
pub const ReviewRunManifest = artifact.ReviewRunManifest;
pub const FindingDispositionValue = artifact.FindingDispositionValue;
pub const FindingDisposition = artifact.FindingDisposition;
pub const ReviewDraftState = artifact.ReviewDraftState;
pub const ReviewResultValue = artifact.ReviewResultValue;
pub const validateHumanSummaryText = artifact.validateHumanSummaryText;
pub const hasNeedsChangesEvidence = artifact.hasNeedsChangesEvidence;
pub const AnchoredNote = artifact.AnchoredNote;
pub const RevisionReviewResult = artifact.RevisionReviewResult;
pub const ReviewRunState = artifact.ReviewRunState;
pub const MutationAdmissionError = artifact.MutationAdmissionError;

test {
    _ = @import("committed_review/identity.zig");
    _ = @import("committed_review/target.zig");
    _ = @import("committed_review/anchor.zig");
    _ = @import("committed_review/artifact.zig");
    _ = @import("committed_review/strict_json.zig");
    _ = @import("committed_review/codec.zig");
    _ = @import("committed_review/repository_binding.zig");
}
