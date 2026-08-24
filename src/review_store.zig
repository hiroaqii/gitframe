//! Public composition boundary for local Review Store authority.
//! Portable artifact vocabulary remains in `committed_review.zig`.
//! The legacy closed-consumer inventory recognizes `review_store/capability.zig`
//! here; it is test-reachable below but deliberately not imported or exported
//! by this production facade.

const store_service = @import("ai_review/store_service.zig");

pub const ConfiguredStore = store_service.ConfiguredStore;
pub const ConfigurationIdentity = store_service.ConfigurationIdentity;
pub const RepositoryContext = store_service.RepositoryContext;
pub const ArtifactSnapshot = store_service.ArtifactSnapshot;
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
pub const PublicationFailure = store_service.PublicationFailure;
pub const PrepareSuccess = store_service.PrepareSuccess;
pub const PrepareResult = store_service.PrepareResult;
pub const PublishRequest = store_service.PublishRequest;
pub const PublishResult = store_service.PublishResult;
pub const prepare = store_service.prepare;
pub const publish = store_service.publish;
pub const PersistenceFailure = store_service.PersistenceFailure;
pub const ReviewRunBinding = store_service.ReviewRunBinding;
pub const DraftSaveRequest = store_service.DraftSaveRequest;
pub const DraftSaveResult = store_service.DraftSaveResult;
pub const ReviewResultCreateRequest = store_service.ReviewResultCreateRequest;
pub const ReviewResultCreateResult = store_service.ReviewResultCreateResult;
pub const saveDraft = store_service.saveDraft;
pub const createResult = store_service.createResult;

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
