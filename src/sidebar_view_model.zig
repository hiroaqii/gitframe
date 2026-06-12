const std = @import("std");

const file_tree = @import("file_tree.zig");

pub const Row = struct {
    node_index: usize,
    kind: file_tree.Node.Kind,
    selected: bool,
    depth: u16,
    name: []const u8,
    path: []const u8,
    stats: file_tree.Stats,
    status: ?file_tree.Status,
    fold: Fold,

    pub const Fold = enum {
        none,
        expanded,
        collapsed,
    };
};

pub const RowLayout = struct {
    marker_col: u16 = 0,
    badge_col: ?u16,
    fold_col: ?u16,
    name_col: u16,
    name_width: u16,
    stats_col: ?u16,
    stats_width: u16,
};

pub fn rowForNode(
    tree: file_tree.FileTree,
    collapsed: *const file_tree.CollapsedSet,
    node_index: usize,
    selected_node: usize,
) ?Row {
    if (node_index >= tree.nodes.len) return null;

    const node = tree.nodes[node_index];
    const fold: Row.Fold = if (node.kind == .directory)
        if (file_tree.isCollapsed(collapsed, node.path)) .collapsed else .expanded
    else
        .none;

    return .{
        .node_index = node_index,
        .kind = node.kind,
        .selected = node_index == selected_node,
        .depth = node.depth,
        .name = node.name,
        .path = node.path,
        .stats = node.stats,
        .status = node.status,
        .fold = fold,
    };
}

pub fn visibleRowAt(
    tree: file_tree.FileTree,
    collapsed: *const file_tree.CollapsedSet,
    visible_nodes: []const usize,
    visible_index: usize,
    selected_node: usize,
) ?Row {
    if (visible_index >= visible_nodes.len) return null;
    return rowForNode(tree, collapsed, visible_nodes[visible_index], selected_node);
}

pub fn layout(row: Row, width: u16) RowLayout {
    const stats_width: u16 = if (width > 12) 12 else 0;
    const indent: u16 = row.depth *| 2;
    // Sidebar rows reserve fixed positions for marker, optional status badge,
    // optional fold marker, name text, and right-aligned stats. The indent shifts
    // the tree-specific badge/fold/name columns while keeping marker/stats fixed.
    const badge_col: ?u16 = if (row.status != null) 1 +| indent else null;
    const fold_col: ?u16 = if (row.kind == .directory) 2 +| indent else null;
    const name_col: u16 = if (row.status != null) 3 +| indent else 2 +| indent +| 2;
    const name_width: u16 = if (width > name_col + stats_width) width - name_col - stats_width else 0;
    const stats_col: ?u16 = if (width > 12) width - stats_width else null;

    return .{
        .badge_col = badge_col,
        .fold_col = fold_col,
        .name_col = name_col,
        .name_width = name_width,
        .stats_col = stats_col,
        .stats_width = stats_width,
    };
}

test "rowForNode exposes sidebar row semantics" {
    var collapsed: file_tree.CollapsedSet = .empty;
    defer collapsed.deinit(std.testing.allocator);
    try file_tree.collapse(std.testing.allocator, &collapsed, "src");

    const nodes = [_]file_tree.Node{
        .{
            .kind = .directory,
            .name = "src",
            .path = "src",
            .depth = 0,
            .stats = .{ .added = 3, .removed = 1 },
        },
        .{
            .kind = .file,
            .name = "main.zig",
            .path = "src/main.zig",
            .depth = 1,
            .stats = .{ .added = 3, .removed = 1 },
            .status = .modified,
            .file_index = 0,
        },
    };

    const tree: file_tree.FileTree = .{ .nodes = &nodes };
    const row = rowForNode(tree, &collapsed, 0, 0).?;

    try std.testing.expectEqual(@as(usize, 0), row.node_index);
    try std.testing.expect(row.selected);
    try std.testing.expectEqual(Row.Fold.collapsed, row.fold);
    try std.testing.expectEqual(@as(usize, 3), row.stats.added);
}

test "layout keeps sidebar columns in one place" {
    const nodes = [_]file_tree.Node{
        .{
            .kind = .file,
            .name = "main.zig",
            .path = "src/main.zig",
            .depth = 1,
            .stats = .{ .added = 12, .removed = 4 },
            .status = .added,
            .file_index = 0,
        },
    };
    const tree: file_tree.FileTree = .{ .nodes = &nodes };
    const collapsed: file_tree.CollapsedSet = .empty;
    const row = rowForNode(tree, &collapsed, 0, 1).?;
    const row_layout = layout(row, 40);

    try std.testing.expect(!row.selected);
    try std.testing.expectEqual(@as(u16, 3), row_layout.badge_col.?);
    try std.testing.expectEqual(@as(u16, 5), row_layout.name_col);
    try std.testing.expectEqual(@as(u16, 23), row_layout.name_width);
    try std.testing.expectEqual(@as(u16, 28), row_layout.stats_col.?);
}
