//! Import-path shim: the module body moved to `src/app/diff_surface/file_search.zig`
//! so the shared diff surface can reference file-search state without importing
//! Review page namespaces (issue #34 S1).

const shared = @import("../../diff_surface/file_search.zig");

pub const max_candidates = shared.max_candidates;
pub const Basis = shared.Basis;
pub const TargetKind = shared.TargetKind;
pub const Candidate = shared.Candidate;
pub const Projection = shared.Projection;
pub const BuildOptions = shared.BuildOptions;
pub const buildProjection = shared.buildProjection;
pub const State = shared.State;
pub const nextAcceptedSidebarRevision = shared.nextAcceptedSidebarRevision;

test {
    _ = shared;
}
