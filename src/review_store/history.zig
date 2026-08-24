//! Compatibility facade for the AI Review Store application service.
//!
//! New production callers use semantic exports from review_store.zig. This
//! module retains the #105 path-shaped entrypoints while delegating all Store
//! plus repository/Git composition to ai_review/store_service.zig.

const std = @import("std");
const committed_review = @import("../committed_review.zig");
const git_command = @import("../git/command.zig");
const root_capability = @import("../repo/root_capability.zig");
const service = @import("../ai_review/store_service.zig");

pub const max_namespace_entries = service.max_namespace_entries;
pub const max_run_candidates = service.max_run_candidates;
pub const max_enumerated_name_bytes = service.max_enumerated_name_bytes;
pub const max_diagnostics = service.max_diagnostics;
pub const max_diagnostic_bytes = service.max_diagnostic_bytes;

pub const RepositoryContext = struct {
    capability: *const root_capability.RootCapability,
    environment: *const git_command.LocalGitEnvironment,

    fn git(self: RepositoryContext) git_command.DirectoryContext {
        return .{ .cwd = self.capability.dir(), .environment = self.environment };
    }

    fn semantic(self: RepositoryContext) service.RepositoryContext {
        return .{ .capability = self.capability, .environment = self.environment };
    }
};
// Compile-time witness retained for the slice-1 capability ownership proof.
// The compatibility module never constructs or opens this private type.
const StoreRootCapability = @import("capability.zig").StoreRootCapability;
pub const StoreSnapshot = service.StoreSnapshot;
pub const ArtifactSnapshot = service.ArtifactSnapshot;
pub const RunSummaryStatus = service.RunSummaryStatus;
pub const RunSummary = service.RunSummary;
pub const DiagnosticKind = service.DiagnosticKind;
pub const Diagnostic = service.Diagnostic;
pub const History = service.History;
pub const BoundEmpty = service.BoundEmpty;
pub const ScanFailure = service.ScanFailure;
pub const ScanResult = service.ScanResult;
pub const SelectionFailure = service.SelectionFailure;
pub const SelectedRunRead = service.SelectedRunRead;
pub const SelectionResult = service.SelectionResult;

pub fn scan(
    allocator: std.mem.Allocator,
    io: std.Io,
    store_root: []const u8,
    repository: RepositoryContext,
) std.mem.Allocator.Error!ScanResult {
    var configured = service.ConfiguredStore.initConfigured(allocator, store_root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidStoreRoot => return .{ .failure = .store_invalid },
    };
    defer configured.deinit(allocator);
    return service.scan(allocator, io, &configured, repository.semantic());
}

pub fn loadSelection(
    allocator: std.mem.Allocator,
    io: std.Io,
    store_root: []const u8,
    repository: RepositoryContext,
    expected: StoreSnapshot,
    review_id: committed_review.ReviewId,
    expected_artifacts: ArtifactSnapshot,
) std.mem.Allocator.Error!SelectionResult {
    var configured = service.ConfiguredStore.initConfigured(allocator, store_root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidStoreRoot => return .{ .failure = .root_drift },
    };
    defer configured.deinit(allocator);
    return service.selectExact(
        allocator,
        io,
        &configured,
        repository.semantic(),
        expected,
        review_id,
        expected_artifacts,
    );
}
