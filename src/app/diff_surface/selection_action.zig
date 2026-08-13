//! Pure row projection for Review's retained-selection action surface.
//!
//! Source/model rows remain the only cursor, search, fold, and selection
//! coordinates. This value inserts two presentation-only rows after one
//! resolved source row and is shared by render, hit testing, scrolling, and
//! viewport transitions.

const std = @import("std");
const diff_render = @import("../../diff/render.zig");
const diff_selection = @import("../../diff/selection.zig");
const diff_view_model = @import("../../diff/view_model.zig");

pub const virtual_row_count: usize = 2;

pub const ActionRow = enum(u1) {
    summary = 0,
    controls = 1,
};

pub const Location = union(enum) {
    source: usize,
    action: ActionRow,
};

pub const Bias = enum {
    before,
    after,
};

pub const Projection = struct {
    source_rows: usize,
    after_source_row: usize,

    pub fn init(source_rows: usize, after_source_row: usize) ?Projection {
        if (source_rows == 0 or after_source_row >= source_rows) return null;
        return .{ .source_rows = source_rows, .after_source_row = after_source_row };
    }

    pub fn insertionOffset(self: Projection) usize {
        return self.after_source_row + 1;
    }

    pub fn presentationRows(self: Projection) usize {
        return self.source_rows +| virtual_row_count;
    }

    pub fn renderProjection(self: Projection) diff_render.VirtualRowProjection {
        return .{
            .source_rows = self.source_rows,
            .after_source_row = self.after_source_row,
            .virtual_rows = virtual_row_count,
        };
    }

    pub fn sourceToPresentation(self: Projection, source_row: usize) ?usize {
        if (source_row >= self.source_rows) return null;
        return source_row +| if (source_row > self.after_source_row) virtual_row_count else 0;
    }

    pub fn locate(self: Projection, presentation_row: usize) ?Location {
        if (presentation_row >= self.presentationRows()) return null;
        const insertion = self.insertionOffset();
        if (presentation_row < insertion) return .{ .source = presentation_row };
        if (presentation_row < insertion +| virtual_row_count) {
            return .{ .action = @enumFromInt(presentation_row - insertion) };
        }
        return .{ .source = presentation_row - virtual_row_count };
    }

    /// Resolves an action ordinal to the adjacent real source row on the
    /// requested side. This is the only mapping cursor/page/wheel code uses;
    /// action rows can therefore never become model coordinates.
    pub fn nearestSource(self: Projection, presentation_row: usize, bias: Bias) ?usize {
        const location = self.locate(@min(presentation_row, self.presentationRows() - 1)) orelse return null;
        return switch (location) {
            .source => |source| source,
            .action => switch (bias) {
                .before => self.after_source_row,
                .after => if (self.after_source_row + 1 < self.source_rows)
                    self.after_source_row + 1
                else
                    self.after_source_row,
            },
        };
    }

    pub fn maxScroll(self: Projection, visible_rows: usize) usize {
        return self.presentationRows() -| visible_rows;
    }

    pub fn clampScroll(self: Projection, scroll: usize, visible_rows: usize) usize {
        return @min(scroll, self.maxScroll(visible_rows));
    }

    /// Scroll just enough to reveal the source tail and both action rows.
    pub fn reveal(self: Projection, current_scroll: usize, visible_rows: usize) usize {
        if (visible_rows == 0) return self.clampScroll(current_scroll, visible_rows);
        const last = (self.insertionOffset() +| virtual_row_count) -| 1;
        var scroll = self.clampScroll(current_scroll, visible_rows);
        if (self.after_source_row < scroll) scroll = self.after_source_row;
        if (last >= scroll + visible_rows) scroll = last + 1 - visible_rows;
        return self.clampScroll(scroll, visible_rows);
    }

    pub fn actionScreenRow(self: Projection, action: ActionRow, scroll: usize, visible_rows: usize) ?usize {
        const presentation = self.insertionOffset() +| @intFromEnum(action);
        if (presentation < scroll or presentation >= scroll +| visible_rows) return null;
        return presentation - scroll;
    }
};

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

/// Exact scalar identity of one source-to-presentation mapping. Owned model
/// paths, text, and folded-hunk slices deliberately never cross reload owners.
pub const ProjectionBasis = struct {
    layout_revision: u64,
    effective_mode: diff_render.DisplayMode,
    source_rows: usize,
    action_insertion_offset: ?usize,

    pub fn eql(self: ProjectionBasis, other: ProjectionBasis) bool {
        return std.meta.eql(self, other);
    }

    pub fn presentationRows(self: ProjectionBasis) usize {
        return self.source_rows +| if (self.action_insertion_offset != null) virtual_row_count else 0;
    }

    pub fn maxScroll(self: ProjectionBasis, visible_rows: usize) usize {
        return self.presentationRows() -| visible_rows;
    }

    pub fn clampScroll(self: ProjectionBasis, scroll: usize, visible_rows: usize) usize {
        return @min(scroll, self.maxScroll(visible_rows));
    }
};

pub const AnchorPosition = struct {
    source_offset_fallback: usize,
    signed_screen_delta: isize,
};

/// Allocation-free value captured before an action projection, model owner,
/// or source-row mapping is retired.
pub const SelectionViewportAnchor = struct {
    semantic_source: SemanticSource,
    source_offset_fallback: usize,
    signed_screen_delta: isize,
    raw_presentation_scroll: usize,
    basis: ProjectionBasis,
};

pub fn captureAnchorPosition(
    source_rows: usize,
    projection: ?Projection,
    presentation_scroll: usize,
) AnchorPosition {
    if (source_rows == 0) return .{ .source_offset_fallback = 0, .signed_screen_delta = 0 };
    const active = projection orelse return .{
        .source_offset_fallback = @min(presentation_scroll, source_rows - 1),
        .signed_screen_delta = 0,
    };
    const clamped = @min(presentation_scroll, active.presentationRows() - 1);
    return switch (active.locate(clamped).?) {
        .source => |source| .{ .source_offset_fallback = source, .signed_screen_delta = 0 },
        .action => {
            const next_source = active.after_source_row + 1;
            if (next_source < active.source_rows) {
                const presentation = active.sourceToPresentation(next_source).?;
                return .{
                    .source_offset_fallback = next_source,
                    .signed_screen_delta = @intCast(presentation - clamped),
                };
            }
            const tail_presentation = active.sourceToPresentation(active.after_source_row).?;
            return .{
                .source_offset_fallback = active.after_source_row,
                .signed_screen_delta = -@as(isize, @intCast(clamped - tail_presentation)),
            };
        },
    };
}

pub fn restoreViewportAnchor(
    anchor: SelectionViewportAnchor,
    incoming_basis: ProjectionBasis,
    incoming_projection: ?Projection,
    resolved_semantic_source: ?usize,
    visible_rows: usize,
) usize {
    if (incoming_basis.source_rows == 0) return 0;
    if (anchor.basis.eql(incoming_basis)) {
        return incoming_basis.clampScroll(anchor.raw_presentation_scroll, visible_rows);
    }

    const source = @min(
        resolved_semantic_source orelse anchor.source_offset_fallback,
        incoming_basis.source_rows - 1,
    );
    const presentation = if (incoming_projection) |projection|
        projection.sourceToPresentation(source) orelse source
    else
        source;
    const raw: usize = if (anchor.signed_screen_delta >= 0)
        presentation -| @as(usize, @intCast(anchor.signed_screen_delta))
    else
        presentation +| @as(usize, @intCast(-anchor.signed_screen_delta));
    return incoming_basis.clampScroll(raw, visible_rows);
}

test "selection action projection maps source and virtual rows bidirectionally" {
    const projection = Projection.init(7, 2).?;
    try std.testing.expectEqual(@as(usize, 9), projection.presentationRows());
    try std.testing.expectEqual(@as(?usize, 0), projection.sourceToPresentation(0));
    try std.testing.expectEqual(@as(?usize, 2), projection.sourceToPresentation(2));
    try std.testing.expectEqual(@as(?usize, 5), projection.sourceToPresentation(3));
    try std.testing.expectEqual(Location{ .source = 2 }, projection.locate(2).?);
    try std.testing.expectEqual(Location{ .action = .summary }, projection.locate(3).?);
    try std.testing.expectEqual(Location{ .action = .controls }, projection.locate(4).?);
    try std.testing.expectEqual(Location{ .source = 3 }, projection.locate(5).?);
}

test "selection action projection skips action rows with directional bias" {
    const projection = Projection.init(5, 2).?;
    try std.testing.expectEqual(@as(?usize, 2), projection.nearestSource(3, .before));
    try std.testing.expectEqual(@as(?usize, 3), projection.nearestSource(3, .after));
    try std.testing.expectEqual(@as(?usize, 2), projection.nearestSource(4, .before));
    try std.testing.expectEqual(@as(?usize, 3), projection.nearestSource(4, .after));

    const eof = Projection.init(3, 2).?;
    try std.testing.expectEqual(@as(?usize, 2), eof.nearestSource(3, .after));
    try std.testing.expectEqual(@as(?usize, 2), eof.nearestSource(4, .before));
}

test "selection action reveal saturates for normal tiny and zero viewports" {
    const projection = Projection.init(10, 7).?;
    try std.testing.expectEqual(@as(usize, 5), projection.reveal(0, 5));
    try std.testing.expectEqual(@as(usize, 7), projection.reveal(99, 4));
    try std.testing.expectEqual(@as(usize, 12), projection.reveal(99, 0));
    try std.testing.expectEqual(@as(?usize, 2), projection.actionScreenRow(.summary, 6, 5));
    try std.testing.expectEqual(@as(?usize, 3), projection.actionScreenRow(.controls, 6, 5));
}

test "selection action viewport anchor removes projection without raw scroll reuse" {
    const middle = Projection.init(8, 2).?;
    const middle_basis: ProjectionBasis = .{
        .layout_revision = 1,
        .effective_mode = .unified,
        .source_rows = 8,
        .action_insertion_offset = middle.insertionOffset(),
    };
    const middle_position = captureAnchorPosition(8, middle, 3);
    const on_summary: SelectionViewportAnchor = .{
        .semantic_source = .{ .generated_row = middle_position.source_offset_fallback },
        .source_offset_fallback = middle_position.source_offset_fallback,
        .signed_screen_delta = middle_position.signed_screen_delta,
        .raw_presentation_scroll = 3,
        .basis = middle_basis,
    };
    try std.testing.expectEqual(@as(usize, 3), on_summary.source_offset_fallback);
    try std.testing.expectEqual(@as(isize, 2), on_summary.signed_screen_delta);
    try std.testing.expectEqual(@as(usize, 1), restoreViewportAnchor(on_summary, .{
        .layout_revision = 2,
        .effective_mode = .unified,
        .source_rows = 8,
        .action_insertion_offset = null,
    }, null, 3, 4));

    const eof = Projection.init(4, 3).?;
    const eof_position = captureAnchorPosition(4, eof, 5);
    const on_clear: SelectionViewportAnchor = .{
        .semantic_source = .{ .generated_row = eof_position.source_offset_fallback },
        .source_offset_fallback = eof_position.source_offset_fallback,
        .signed_screen_delta = eof_position.signed_screen_delta,
        .raw_presentation_scroll = 5,
        .basis = .{
            .layout_revision = 1,
            .effective_mode = .unified,
            .source_rows = 4,
            .action_insertion_offset = eof.insertionOffset(),
        },
    };
    try std.testing.expectEqual(@as(usize, 3), on_clear.source_offset_fallback);
    try std.testing.expectEqual(@as(isize, -2), on_clear.signed_screen_delta);
    try std.testing.expectEqual(@as(usize, 5), restoreViewportAnchor(on_clear, .{
        .layout_revision = 2,
        .effective_mode = .unified,
        .source_rows = 8,
        .action_insertion_offset = null,
    }, null, null, 2));
}

test "selection viewport same basis reuses raw ordinal and changed basis resolves semantics" {
    const projection = Projection.init(12, 4).?;
    const basis: ProjectionBasis = .{
        .layout_revision = 9,
        .effective_mode = .side_by_side,
        .source_rows = 12,
        .action_insertion_offset = projection.insertionOffset(),
    };
    const anchor: SelectionViewportAnchor = .{
        .semantic_source = .{ .parsed = .{ .hunk_line = .{ .hunk_index = 1, .line_index = 2 } } },
        .source_offset_fallback = 5,
        .signed_screen_delta = 0,
        .raw_presentation_scroll = 7,
        .basis = basis,
    };
    try std.testing.expectEqual(@as(usize, 7), restoreViewportAnchor(anchor, basis, projection, 1, 3));

    const changed = Projection.init(9, 1).?;
    try std.testing.expectEqual(@as(usize, 6), restoreViewportAnchor(anchor, .{
        .layout_revision = 10,
        .effective_mode = .unified,
        .source_rows = 9,
        .action_insertion_offset = changed.insertionOffset(),
    }, changed, 4, 3));
}
