//! Import-path shim: the module body moved to `src/app/diff_surface/selection.zig`
//! so the shared diff surface can reference selection types without importing
//! Review page namespaces (issue #34 S1).

const shared = @import("../../diff_surface/selection.zig");

pub const SourceBasis = shared.SourceBasis;
pub const DisplayBasis = shared.DisplayBasis;
pub const ReviewContentToken = shared.ReviewContentToken;
pub const Parsed = shared.Parsed;
pub const GeneratedFragment = shared.GeneratedFragment;
pub const Generated = shared.Generated;
pub const CompletedSelection = shared.CompletedSelection;
pub const buildParsed = shared.buildParsed;
pub const buildGenerated = shared.buildGenerated;

test {
    _ = shared;
}
