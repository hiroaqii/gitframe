const std = @import("std");

const chasen = @import("chasen");
const file_tree = @import("../file_tree.zig");

pub const Row = struct {
    node_index: usize,
    kind: file_tree.Node.Kind,
    selected: bool,
    depth: u16,
    name: []const u8,
    path: []const u8,
    stats: file_tree.Stats,
    status: ?file_tree.Status,
    stage_presence: file_tree.StagePresence,
    mode_changed: bool,
    reviewed: bool,
    fold: Fold,

    pub const Fold = enum {
        none,
        expanded,
        collapsed,
    };
};

pub const RowLayout = struct {
    reviewed_col: ?u16,
    badge_col: ?u16,
    mode_col: ?u16,
    name_col: u16,
    name_width: u16,
    tree_content_col: u16,
    tree_content_width: u16,
    stats_col: ?u16,
    stats_width: u16,
};

pub const Source = struct {
    tree: file_tree.FileTree,
    collapsed: *const file_tree.CollapsedSet,
    reviewed_files: []const bool,
    /// Null means the caller has no materialized visible-node cache; use the
    /// tree's collapsed-directory traversal instead. An empty slice means the
    /// materialized result is intentionally empty.
    visible_nodes: ?[]const usize,
};

pub fn rowForNode(
    tree: file_tree.FileTree,
    collapsed: *const file_tree.CollapsedSet,
    reviewed_files: []const bool,
    node_index: usize,
    selected_node: usize,
) ?Row {
    if (node_index >= tree.nodes.len) return null;

    const node = tree.nodes[node_index];
    const fold: Row.Fold = switch (node.kind) {
        .repo_root => .expanded,
        .directory => if (file_tree.isCollapsed(collapsed, node.path)) .collapsed else .expanded,
        .file => .none,
    };

    return .{
        .node_index = node_index,
        .kind = node.kind,
        .selected = node_index == selected_node,
        .depth = node.depth,
        .name = node.name,
        .path = node.path,
        .stats = node.stats,
        .status = node.status,
        .stage_presence = node.stage_presence,
        .mode_changed = node.mode_changed,
        .reviewed = if (node.diffFileIndex()) |file_index|
            file_index < reviewed_files.len and reviewed_files[file_index]
        else
            false,
        .fold = fold,
    };
}

pub fn rowAt(source: Source, visible_index: usize, selected_node: usize) ?Row {
    if (source.visible_nodes) |nodes| {
        return visibleRowAt(source.tree, source.collapsed, source.reviewed_files, nodes, visible_index, selected_node);
    }

    const node_index = source.tree.visibleNodeAt(source.collapsed, visible_index) orelse return null;
    return rowForNode(source.tree, source.collapsed, source.reviewed_files, node_index, selected_node);
}

fn visibleRowAt(
    tree: file_tree.FileTree,
    collapsed: *const file_tree.CollapsedSet,
    reviewed_files: []const bool,
    visible_nodes: []const usize,
    visible_index: usize,
    selected_node: usize,
) ?Row {
    if (visible_index >= visible_nodes.len) return null;
    return rowForNode(tree, collapsed, reviewed_files, visible_nodes[visible_index], selected_node);
}

pub fn layout(row: Row, width: u16) RowLayout {
    const indent: u16 = row.depth *| 2;
    // Root and directory content starts at the tree's left edge. File-only
    // reviewed/status/mode columns stay fixed so removing the old selection
    // marker does not make semantic badges jump between rows.
    const reviewed_col: ?u16 = if (row.kind == .file and row.reviewed) 1 else null;
    const badge_col: ?u16 = if (row.status != null) 2 else null;
    const mode_col: ?u16 = if (row.kind == .file and row.mode_changed)
        if (row.status != null) 4 else 2
    else
        null;
    const tree_content_col: u16 = if (row.kind == .repo_root or row.kind == .directory)
        0
    else if (row.mode_changed and row.status != null)
        6
    else if (row.mode_changed or row.status != null)
        4
    else
        2;
    const name_col: u16 = if (row.kind == .repo_root)
        2 +| indent
    else if (row.kind == .directory)
        2 +| indent
    else if (row.mode_changed and row.status != null)
        6 +| indent
    else if (row.mode_changed or row.status != null)
        4 +| indent
    else
        2 +| indent;
    const stats_width: u16 = if (shouldShowStats(row, width, name_col)) 12 else 0;
    const name_width: u16 = if (width > name_col + stats_width) width - name_col - stats_width else 0;
    const stats_col: ?u16 = if (stats_width > 0) width - stats_width else null;
    const tree_content_width: u16 = if (width > tree_content_col + stats_width) width - tree_content_col - stats_width else 0;

    return .{
        .badge_col = badge_col,
        .mode_col = mode_col,
        .reviewed_col = reviewed_col,
        .name_col = name_col,
        .name_width = name_width,
        .tree_content_col = tree_content_col,
        .tree_content_width = tree_content_width,
        .stats_col = stats_col,
        .stats_width = stats_width,
    };
}

pub fn treeContentDisplayWidth(row: Row) usize {
    const indent: usize = @as(usize, row.depth) * 2;
    const fold_width: usize = switch (row.fold) {
        .none => 0,
        .expanded, .collapsed => chasen.text.displayWidth("▾ "),
    };
    return indent + fold_width + chasen.text.displayWidth(row.name);
}

pub fn maxHorizontalScroll(row: Row, width: u16) usize {
    const row_layout = layout(row, width);
    const content_width = treeContentDisplayWidth(row);
    if (content_width <= row_layout.tree_content_width) return 0;
    return content_width - row_layout.tree_content_width;
}

fn hasLineStats(stats: file_tree.Stats) bool {
    return stats.added != 0 or stats.removed != 0;
}

fn shouldShowStats(row: Row, width: u16, name_col: u16) bool {
    const stats_width: u16 = 12;
    const min_name_width_with_stats: u16 = 8;

    // Keep navigation rows quiet; repository totals remain visible at the root.
    if (row.kind != .repo_root) return false;
    return hasLineStats(row.stats) and
        width > name_col + stats_width + min_name_width_with_stats;
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
            .mode_changed = true,
            .target = .{ .diff_file = 0 },
        },
    };

    const tree: file_tree.FileTree = .{ .nodes = &nodes };
    const row = rowForNode(tree, &collapsed, &.{}, 0, 0).?;

    try std.testing.expectEqual(@as(usize, 0), row.node_index);
    try std.testing.expect(row.selected);
    try std.testing.expectEqual(Row.Fold.collapsed, row.fold);
    try std.testing.expectEqual(@as(usize, 3), row.stats.added);
    const file_row = rowForNode(tree, &collapsed, &.{}, 1, 0).?;
    try std.testing.expect(file_row.mode_changed);
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
            .target = .{ .diff_file = 0 },
        },
    };
    const tree: file_tree.FileTree = .{ .nodes = &nodes };
    const collapsed: file_tree.CollapsedSet = .empty;
    const reviewed = [_]bool{true};
    const row = rowForNode(tree, &collapsed, &reviewed, 0, 1).?;
    const row_layout = layout(row, 40);

    try std.testing.expect(!row.selected);
    try std.testing.expect(row.reviewed);
    try std.testing.expectEqual(@as(u16, 1), row_layout.reviewed_col.?);
    try std.testing.expectEqual(@as(u16, 2), row_layout.badge_col.?);
    try std.testing.expectEqual(@as(?u16, null), row_layout.mode_col);
    try std.testing.expectEqual(@as(u16, 6), row_layout.name_col);
    try std.testing.expectEqual(@as(u16, 34), row_layout.name_width);
    try std.testing.expectEqual(@as(u16, 4), row_layout.tree_content_col);
    try std.testing.expectEqual(@as(u16, 36), row_layout.tree_content_width);
    try std.testing.expectEqual(@as(?u16, null), row_layout.stats_col);
}

test "layout reserves a mode badge column for mode-changed file rows" {
    const nodes = [_]file_tree.Node{
        .{
            .kind = .file,
            .name = "script.sh",
            .path = "script.sh",
            .depth = 0,
            .stats = .{},
            .status = .modified,
            .mode_changed = true,
            .target = .{ .diff_file = 0 },
        },
    };
    const tree: file_tree.FileTree = .{ .nodes = &nodes };
    const collapsed: file_tree.CollapsedSet = .empty;
    const row = rowForNode(tree, &collapsed, &.{false}, 0, 0).?;
    const row_layout = layout(row, 40);

    try std.testing.expectEqual(@as(u16, 2), row_layout.badge_col.?);
    try std.testing.expectEqual(@as(u16, 4), row_layout.mode_col.?);
    try std.testing.expectEqual(@as(u16, 6), row_layout.name_col);
}

test "layout reserves reviewed gutter for status-less file rows" {
    const nodes = [_]file_tree.Node{
        .{
            .kind = .file,
            .name = "main.zig",
            .path = "main.zig",
            .depth = 0,
            .stats = .{ .added = 1, .removed = 0 },
            .target = .{ .diff_file = 0 },
        },
    };
    const tree: file_tree.FileTree = .{ .nodes = &nodes };
    const collapsed: file_tree.CollapsedSet = .empty;
    const unreviewed = [_]bool{false};
    const reviewed = [_]bool{true};

    const unreviewed_layout = layout(rowForNode(tree, &collapsed, &unreviewed, 0, 0).?, 40);
    const reviewed_layout = layout(rowForNode(tree, &collapsed, &reviewed, 0, 0).?, 40);

    try std.testing.expectEqual(@as(?u16, null), unreviewed_layout.reviewed_col);
    try std.testing.expectEqual(@as(u16, 1), reviewed_layout.reviewed_col.?);
    try std.testing.expectEqual(@as(u16, 2), reviewed_layout.name_col);
    try std.testing.expectEqual(unreviewed_layout.name_col, reviewed_layout.name_col);
    try std.testing.expectEqual(unreviewed_layout.name_width, reviewed_layout.name_width);
}

test "layout omits zero line stats" {
    const nodes = [_]file_tree.Node{
        .{
            .kind = .file,
            .name = "binary.dat",
            .path = "binary.dat",
            .depth = 0,
            .stats = .{},
            .status = .binary,
            .target = .{ .diff_file = 0 },
        },
    };
    const tree: file_tree.FileTree = .{ .nodes = &nodes };
    const collapsed: file_tree.CollapsedSet = .empty;
    const row_layout = layout(rowForNode(tree, &collapsed, &.{false}, 0, 0).?, 40);

    try std.testing.expectEqual(@as(?u16, null), row_layout.stats_col);
    try std.testing.expectEqual(@as(u16, 0), row_layout.stats_width);
    try std.testing.expectEqual(@as(u16, 36), row_layout.name_width);
}

test "layout prioritizes file name over stats in narrow sidebars" {
    const nodes = [_]file_tree.Node{
        .{
            .kind = .file,
            .name = "app.zig",
            .path = "app.zig",
            .depth = 0,
            .stats = .{ .added = 68, .removed = 3 },
            .status = .modified,
            .target = .{ .diff_file = 0 },
        },
    };
    const tree: file_tree.FileTree = .{ .nodes = &nodes };
    const collapsed: file_tree.CollapsedSet = .empty;
    const row_layout = layout(rowForNode(tree, &collapsed, &.{false}, 0, 0).?, 14);

    try std.testing.expectEqual(@as(?u16, null), row_layout.stats_col);
    try std.testing.expectEqual(@as(u16, 0), row_layout.stats_width);
    try std.testing.expect(row_layout.name_width > 0);
}

test "layout shows stats only for repository root rows" {
    const nodes = [_]file_tree.Node{
        .{
            .kind = .repo_root,
            .name = "repo",
            .path = "",
            .depth = 0,
            .stats = .{ .added = 68, .removed = 3 },
            .target = .repo_root,
        },
        .{
            .kind = .directory,
            .name = "src",
            .path = "src",
            .depth = 1,
            .stats = .{ .added = 12, .removed = 4 },
        },
    };
    const tree: file_tree.FileTree = .{ .nodes = &nodes };
    const collapsed: file_tree.CollapsedSet = .empty;

    const root_layout = layout(rowForNode(tree, &collapsed, &.{}, 0, 0).?, 40);
    const directory_layout = layout(rowForNode(tree, &collapsed, &.{}, 1, 0).?, 40);

    try std.testing.expectEqual(@as(u16, 0), root_layout.tree_content_col);
    try std.testing.expectEqual(@as(u16, 2), root_layout.name_col);
    try std.testing.expectEqual(@as(?u16, 28), root_layout.stats_col);
    try std.testing.expectEqual(@as(u16, 0), directory_layout.tree_content_col);
    try std.testing.expectEqual(@as(u16, 4), directory_layout.name_col);
    try std.testing.expectEqual(@as(?u16, null), directory_layout.stats_col);
}

test "review root expansion always renders repository root as expanded" {
    const nodes = [_]file_tree.Node{.{
        .kind = .repo_root,
        .name = "repo",
        .path = "",
        .depth = 0,
        .target = .repo_root,
    }};
    const tree: file_tree.FileTree = .{ .nodes = &nodes };
    const collapsed: file_tree.CollapsedSet = .empty;

    const root = rowForNode(tree, &collapsed, &.{}, 0, 0).?;

    try std.testing.expectEqual(Row.Fold.expanded, root.fold);
    try std.testing.expect(!file_tree.isCollapsed(&collapsed, ""));
}
