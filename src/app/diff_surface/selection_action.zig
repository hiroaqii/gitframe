//! Diff-specific retained-selection action adapter.
//!
//! The neutral action vocabulary, layout, and viewport arithmetic
//! live in `app/selection_action.zig`. This adapter keeps only parsed/generated
//! diff semantic identity and the selected side/view authority.

const common = @import("../selection_action.zig");
const diff_selection = @import("../../diff/selection.zig");
const diff_view_model = @import("../../diff/view_model.zig");

pub const Action = common.Action;
pub const ViewportBasis = common.ViewportBasis;
pub const StatusPresentation = common.StatusPresentation;
pub const statusLayout = common.statusLayout;

pub const Presentation = struct {
    view: diff_selection.View,
    line_count: usize,

    pub fn status(self: Presentation) StatusPresentation {
        return .{
            .line_count = self.line_count,
            .side = switch (self.view.side) {
                .old => .before,
                .new => .after,
            },
        };
    }
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
    incoming_basis: ViewportBasis,
    resolved_semantic_source: ?usize,
    visible_rows: usize,
) usize {
    return common.restoreViewportAnchor(
        anchor,
        incoming_basis,
        resolved_semantic_source,
        visible_rows,
    );
}
