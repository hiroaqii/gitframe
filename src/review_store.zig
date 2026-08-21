//! Public composition boundary for local Review Store authority.
//! Portable artifact vocabulary remains in `committed_review.zig`.

pub const path = @import("review_store/path.zig");
pub const capability = @import("review_store/capability.zig");
pub const registry = @import("review_store/registry.zig");
pub const run = @import("review_store/run.zig");
pub const history = @import("review_store/history.zig");
pub const publication = @import("review_store/publication.zig");
pub const mutation = @import("review_store/mutation.zig");

pub const ResolvedPath = path.Resolved;
pub const NamespaceTempKind = path.NamespaceTempKind;
pub const NamespaceTempName = path.NamespaceTempName;
pub const StoreRootCapability = capability.StoreRootCapability;
pub const DirectoryCapability = capability.DirectoryCapability;
pub const ParsedRegistry = registry.ParsedRegistry;
pub const LoadedRunArtifacts = run.LoadedRunArtifacts;
pub const ArtifactSnapshot = run.ArtifactSnapshot;
pub const History = history.History;
pub const ScanResult = history.ScanResult;
pub const SelectedRunRead = history.SelectedRunRead;
pub const PreparePublicationResult = publication.PrepareResult;
pub const PublishRequest = publication.PublishRequest;
pub const PublishResult = publication.PublishResult;
pub const DraftMutationRequest = mutation.DraftRequest;
pub const DraftMutationResult = mutation.DraftResult;
pub const ReviewResultRequest = mutation.ResultRequest;
pub const ReviewResultMutationResult = mutation.ResultResult;

test {
    _ = @import("review_store/path.zig");
    _ = @import("review_store/capability.zig");
    _ = @import("review_store/registry.zig");
    _ = @import("review_store/run.zig");
    _ = @import("review_store/history.zig");
    _ = @import("review_store/publication.zig");
    _ = @import("review_store/mutation.zig");
}
