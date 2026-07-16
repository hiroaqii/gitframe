//! Repository-local tree/source split geometry.
//!
//! The user-visible width contract intentionally matches Review, but this
//! module does not import Review state or layout. Keeping the calculation pure
//! lets rendering, hit testing, source selection, and resize reconciliation use
//! one Repository-owned authority without coupling the two page domains.

const std = @import("std");

pub const tree_width_step: u16 = 4;
pub const max_tree_width: u16 = 48;
pub const min_source_width: u16 = 24;
const min_tree_width: u16 = 18;

pub const WidthDirection = enum { shrink, grow };

pub fn treeWidth(total_width: u16, preferred_width: ?u16) u16 {
    return clampTreeWidth(total_width, preferred_width orelse defaultTreeWidth(total_width));
}

pub fn defaultTreeWidth(total_width: u16) u16 {
    if (total_width < 50) return @min(total_width, 24);
    if (total_width < 90) return 28;
    return 34;
}

pub fn clampTreeWidth(total_width: u16, width: u16) u16 {
    const max_available = if (total_width > min_source_width + 1)
        total_width - min_source_width - 1
    else
        total_width;
    const effective_max = @min(max_tree_width, max_available);
    const effective_min = @min(min_tree_width, effective_max);
    return @min(@max(width, effective_min), effective_max);
}

pub fn adjustedTreeWidth(total_width: u16, preferred_width: ?u16, direction: WidthDirection) u16 {
    const current = treeWidth(total_width, preferred_width);
    const requested = switch (direction) {
        .shrink => current -| tree_width_step,
        .grow => current +| tree_width_step,
    };
    return clampTreeWidth(total_width, requested);
}

test "Repository tree width matches the approved responsive contract" {
    try std.testing.expectEqual(@as(u16, 15), treeWidth(40, null));
    try std.testing.expectEqual(@as(u16, 28), treeWidth(70, null));
    try std.testing.expectEqual(@as(u16, 34), treeWidth(120, null));
    try std.testing.expectEqual(@as(u16, 18), treeWidth(80, 1));
    try std.testing.expectEqual(@as(u16, 48), treeWidth(120, 90));
    try std.testing.expectEqual(@as(u16, 15), treeWidth(40, 42));
    try std.testing.expectEqual(@as(u16, 42), treeWidth(120, 42));
}

test "Repository tree width adjusts in four-column clamped steps" {
    try std.testing.expectEqual(@as(u16, 30), adjustedTreeWidth(104, null, .shrink));
    try std.testing.expectEqual(@as(u16, 38), adjustedTreeWidth(104, null, .grow));
    try std.testing.expectEqual(@as(u16, 15), adjustedTreeWidth(40, null, .grow));
    try std.testing.expectEqual(@as(u16, 48), adjustedTreeWidth(120, 48, .grow));
}
