//! Compatibility path for shared diff-surface geometry.

const shared = @import("../../diff_surface/layout.zig");

pub const sidebar_header_rows = shared.sidebar_header_rows;
pub const diff_body_start_row = shared.diff_body_start_row;
pub const search_marker_gutter_width = shared.search_marker_gutter_width;
pub const diffContentWidth = shared.diffContentWidth;
pub const sidebarWidth = shared.sidebarWidth;
pub const defaultSidebarWidth = shared.defaultSidebarWidth;
pub const clampSidebarWidth = shared.clampSidebarWidth;
