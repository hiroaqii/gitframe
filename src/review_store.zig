//! Public composition boundary for local Review Store authority.
//! Portable artifact vocabulary remains in `committed_review.zig`.

pub const path = @import("review_store/path.zig");
pub const capability = @import("review_store/capability.zig");
pub const registry = @import("review_store/registry.zig");
pub const run = @import("review_store/run.zig");
pub const history = @import("review_store/history.zig");
pub const publication = @import("review_store/publication.zig");
pub const mutation = @import("review_store/mutation.zig");
const store_service = @import("ai_review/store_service.zig");

pub const ResolvedPath = path.Resolved;
pub const NamespaceTempKind = path.NamespaceTempKind;
pub const NamespaceTempName = path.NamespaceTempName;
pub const StoreRootCapability = capability.StoreRootCapability;
pub const DirectoryCapability = capability.DirectoryCapability;
pub const ParsedRegistry = registry.ParsedRegistry;
pub const LoadedRunArtifacts = run.LoadedRunArtifacts;
pub const ArtifactSnapshot = run.ArtifactSnapshot;
pub const ConfiguredStore = store_service.ConfiguredStore;
pub const RepositoryContext = store_service.RepositoryContext;
pub const StoreSnapshot = store_service.StoreSnapshot;
pub const RunSummaryStatus = store_service.RunSummaryStatus;
pub const RunSummary = store_service.RunSummary;
pub const DiagnosticKind = store_service.DiagnosticKind;
pub const Diagnostic = store_service.Diagnostic;
pub const History = store_service.History;
pub const ScanFailure = store_service.ScanFailure;
pub const ScanResult = store_service.ScanResult;
pub const SelectionFailure = store_service.SelectionFailure;
pub const SelectedRunRead = store_service.SelectedRunRead;
pub const scan = store_service.scan;
pub const selectExact = store_service.selectExact;
pub const ExpectedPublicationIdentity = store_service.ExpectedPublicationIdentity;
pub const ExactIdentity = store_service.ExactIdentity;
pub const ReadFailure = store_service.ReadFailure;
pub const ReadResult = store_service.ReadResult;
pub const readExactIdentity = store_service.readExactIdentity;
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
    _ = @import("review_store/core.zig");
    _ = @import("review_store/catalog.zig");
    _ = @import("review_store/history.zig");
    _ = @import("review_store/publication.zig");
    _ = @import("review_store/mutation.zig");
}
