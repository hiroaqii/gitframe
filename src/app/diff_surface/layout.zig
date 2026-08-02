//! Page-independent diff pane geometry shared by rendering, navigation, and
//! hit testing.

const std = @import("std");
const diff_render = @import("../../diff/render.zig");

pub const sidebar_header_rows: u16 = 3;
pub const diff_body_start_row: u16 = diff_render.body_start_row;
pub const search_marker_gutter_width: u16 = 1;

pub fn diffContentWidth(width: u16) u16 {
    return if (width > search_marker_gutter_width) width - search_marker_gutter_width else width;
}

pub fn sidebarWidth(total_width: u16, preferred_width: ?u16) u16 {
    return clampSidebarWidth(total_width, preferred_width orelse defaultSidebarWidth(total_width));
}

pub fn defaultSidebarWidth(total_width: u16) u16 {
    if (total_width < 50) return @min(total_width, 24);
    if (total_width < 90) return 28;
    return 34;
}

pub fn clampSidebarWidth(total_width: u16, width: u16) u16 {
    const min_diff_pane_width: u16 = 24;
    const hard_max_width: u16 = 48;
    const max_available = if (total_width > min_diff_pane_width + 1) total_width - min_diff_pane_width - 1 else total_width;
    const max_width = @min(hard_max_width, max_available);
    const min_width = @min(@as(u16, 18), max_width);
    return @min(@max(width, min_width), max_width);
}

test "sidebar width keeps a usable diff pane" {
    try std.testing.expectEqual(@as(u16, 15), sidebarWidth(40, null));
    try std.testing.expectEqual(@as(u16, 28), sidebarWidth(70, null));
    try std.testing.expectEqual(@as(u16, 34), sidebarWidth(120, null));
    try std.testing.expectEqual(@as(u16, 18), sidebarWidth(80, 1));
    try std.testing.expectEqual(@as(u16, 48), sidebarWidth(120, 90));
}

test "diff content width reserves the search marker gutter" {
    try std.testing.expectEqual(@as(u16, 0), diffContentWidth(0));
    try std.testing.expectEqual(@as(u16, 1), diffContentWidth(1));
    try std.testing.expectEqual(@as(u16, 79), diffContentWidth(80));
}
