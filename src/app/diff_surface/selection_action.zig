//! Diff-specific retained-selection action adapter.
//!
//! The neutral action vocabulary, layout, projection, and viewport arithmetic
//! live in `app/selection_action.zig`. This adapter keeps only parsed/generated
//! diff semantic identity and the selected side/view authority.

const common = @import("../selection_action.zig");
const diff_selection = @import("../../diff/selection.zig");
const diff_view_model = @import("../../diff/view_model.zig");

pub const Action = common.Action;
pub const ActionRow = common.ActionRow;
pub const Bias = common.Bias;
pub const Location = common.Location;
pub const Projection = common.Projection;
pub const ProjectionBasis = common.ProjectionBasis;
pub const virtual_row_count = common.virtual_row_count;

pub const Presentation = struct {
    view: diff_selection.View,
    line_count: usize,
    projection: Projection,
};

pub const SemanticSource = union(enum) {
    none,
    parsed: diff_view_model.BodyCoordinate,
    generated_row: usize,
};

pub const SelectionViewportAnchor = common.ViewportAnchor(SemanticSource);

pub const captureAnchorPosition = common.captureAnchorPosition;

pub fn restoreViewportAnchor(
    anchor: SelectionViewportAnchor,
    incoming_basis: ProjectionBasis,
    incoming_projection: ?Projection,
    resolved_semantic_source: ?usize,
    visible_rows: usize,
) usize {
    return common.restoreViewportAnchor(
        anchor,
        incoming_basis,
        incoming_projection,
        resolved_semantic_source,
        visible_rows,
    );
}
