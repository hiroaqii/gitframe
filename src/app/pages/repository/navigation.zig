//! Repository source navigation and bounded file-search projection.

const std = @import("std");
const model = @import("model.zig");
const source_geometry = @import("source_geometry.zig");
const source = @import("../../../repository/source.zig");
const selected_document = @import("../../../repository/document.zig");
const repository_tree = @import("../../../repository/tree.zig");

pub fn moveSource(viewer: *model.ViewerState, document: *const source.Document, delta: isize, geometry: source_geometry.SourceGeometry) void {
    if (delta < 0)
        viewer.source_cursor -|= @intCast(-delta)
    else
        viewer.source_cursor = @min(viewer.source_cursor +| @as(usize, @intCast(delta)), document.rowCount() - 1);
    clampSource(viewer, document, geometry);
}

pub fn pageSource(viewer: *model.ViewerState, document: *const source.Document, direction: isize, geometry: source_geometry.SourceGeometry) void {
    const step: isize = @intCast(geometry.navigationRows());
    moveSource(viewer, document, if (direction < 0) -step else step, geometry);
}

pub fn firstSource(viewer: *model.ViewerState, document: *const source.Document, geometry: source_geometry.SourceGeometry) void {
    viewer.source_cursor = 0;
    clampSource(viewer, document, geometry);
}

pub fn lastSource(viewer: *model.ViewerState, document: *const source.Document, geometry: source_geometry.SourceGeometry) void {
    viewer.source_cursor = document.rowCount() - 1;
    clampSource(viewer, document, geometry);
}

pub fn scrollSourceHorizontal(viewer: *model.ViewerState, document: *const source.Document, delta: isize, geometry: source_geometry.SourceGeometry) void {
    if (delta < 0)
        viewer.source_horizontal_scroll -|= @intCast(-delta)
    else
        viewer.source_horizontal_scroll +|= @intCast(delta);
    const maximum = document.maxDisplayWidth() -| @as(usize, geometry.text_width);
    viewer.source_horizontal_scroll = @min(viewer.source_horizontal_scroll, maximum);
}

pub fn clampSource(
    viewer: *model.ViewerState,
    document: *const source.Document,
    geometry: source_geometry.SourceGeometry,
) void {
    const rows = geometry.navigationRows();
    viewer.source_cursor = @min(viewer.source_cursor, document.rowCount() - 1);
    if (viewer.source_cursor < viewer.source_vertical_scroll) viewer.source_vertical_scroll = viewer.source_cursor;
    if (viewer.source_cursor >= viewer.source_vertical_scroll + rows) viewer.source_vertical_scroll = viewer.source_cursor - rows + 1;
    viewer.source_vertical_scroll = @min(viewer.source_vertical_scroll, document.rowCount() -| rows);
    const maximum = document.maxDisplayWidth() -| @as(usize, geometry.text_width);
    viewer.source_horizontal_scroll = @min(viewer.source_horizontal_scroll, maximum);
}

pub fn revealMatch(
    viewer: *model.ViewerState,
    document: *const source.Document,
    match: source.Match,
    geometry: source_geometry.SourceGeometry,
) void {
    viewer.focus = .source;
    viewer.source_cursor = match.line;
    const match_col = document.displayColumnForByte(match.line, match.start) orelse 0;
    if (match_col < viewer.source_horizontal_scroll) viewer.source_horizontal_scroll = match_col;
    if (geometry.text_width > 0 and match_col >= viewer.source_horizontal_scroll + geometry.text_width) {
        viewer.source_horizontal_scroll = match_col - geometry.text_width + 1;
    }
    clampSource(viewer, document, geometry);
}

/// File search follows the active tree projection even though it scans raw
/// nodes so collapsed descendants remain discoverable. Source search is
/// intentionally different: it is scoped to the already selected document.
pub fn refreshFileSearch(
    state: *model.FileSearchState,
    tree: *const repository_tree.Tree,
    visibility: repository_tree.Visibility,
) void {
    state.resetResults();
    state.projection_available = true;
    const query = state.input.slice();
    for (tree.nodes, 0..) |node, node_index| {
        if (node.kind != .file) continue;
        if (visibility == .changed and node.file_change == null) continue;
        if (query.len > 0 and std.mem.indexOf(u8, node.path, query) == null) continue;
        if (state.len == model.max_file_search_matches) {
            state.truncated = true;
            break;
        }
        state.matches[state.len] = node_index;
        state.len += 1;
    }
    state.no_match = state.len == 0;
}

test "repository selection slice B navigation clamps cursor scroll and horizontal cells" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, "one\ntwo\n0123456789\n");
    var document = try source.Document.initOwned(allocator, bytes, .init(bytes));
    defer document.deinit(allocator);
    const geometry = source_geometry.SourceGeometry.init(.{ .width = 7, .height = 3 }, &document, true);
    var viewer: model.ViewerState = .{ .focus = .source };
    moveSource(&viewer, &document, 20, geometry);
    try std.testing.expectEqual(@as(usize, 2), viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 2), viewer.source_vertical_scroll);
    scrollSourceHorizontal(&viewer, &document, 8, geometry);
    try std.testing.expectEqual(@as(usize, 6), viewer.source_horizontal_scroll);
}

test "repository repeated navigation uses precomputed width for admitted worst shapes" {
    const allocator = std.testing.allocator;
    const dense_bytes = try allocator.alloc(u8, selected_document.max_text_bytes);
    @memset(dense_bytes, '\n');
    var dense = try source.Document.initOwned(allocator, dense_bytes, .init(dense_bytes));
    defer dense.deinit(allocator);
    const dense_geometry = source_geometry.SourceGeometry.init(.{ .width = 80, .height = 10 }, &dense, true);
    var dense_viewer: model.ViewerState = .{ .focus = .source };
    for (0..32) |_| moveSource(&dense_viewer, &dense, 1, dense_geometry);
    try std.testing.expectEqual(@as(usize, 32), dense_viewer.source_cursor);

    const long_bytes = try allocator.alloc(u8, selected_document.max_text_bytes);
    @memset(long_bytes, 'a');
    var long = try source.Document.initOwned(allocator, long_bytes, .init(long_bytes));
    defer long.deinit(allocator);
    try std.testing.expectEqual(selected_document.max_text_bytes, long.max_display_width);
    const long_geometry = source_geometry.SourceGeometry.init(.{ .width = 5, .height = 10 }, &long, false);
    var long_viewer: model.ViewerState = .{ .focus = .source };
    for (0..32) |_| scrollSourceHorizontal(&long_viewer, &long, 8, long_geometry);
    try std.testing.expectEqual(@as(usize, 256), long_viewer.source_horizontal_scroll);
}

test "repository file search retains 512 matches and reports the 513th" {
    const allocator = std.testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    for (0..513) |index| {
        const path = if (index < 512)
            try std.fmt.allocPrint(allocator, "match-{d}.zig", .{index})
        else
            try allocator.dupe(u8, "other-512.zig");
        defer allocator.free(path);
        try bytes.appendSlice(allocator, path);
        try bytes.append(allocator, 0);
    }
    var manifest = try @import("../../../repository/manifest.zig").parseOwned(allocator, try bytes.toOwnedSlice(allocator));
    defer manifest.deinit(allocator);
    var tree = try repository_tree.Tree.build(allocator, &manifest);
    defer tree.deinit(allocator);
    var state: model.FileSearchState = .{ .mode = true };
    try state.input.insertSlice("match-");
    refreshFileSearch(&state, &tree, .all);
    try std.testing.expectEqual(model.max_file_search_matches, state.len);
    try std.testing.expect(!state.truncated);

    state.input = .{};
    refreshFileSearch(&state, &tree, .all);
    try std.testing.expectEqual(model.max_file_search_matches, state.len);
    try std.testing.expect(state.truncated);

    state.input = .{};
    try state.input.insertSlice("other-512.zig");
    refreshFileSearch(&state, &tree, .all);
    try std.testing.expectEqual(@as(usize, 1), state.len);
    try std.testing.expect(!state.truncated);
    try std.testing.expectEqualStrings("other-512.zig", tree.nodes[state.selectedNode().?].path);
}

test "repository file search compares invalid raw path bytes safely" {
    const allocator = std.testing.allocator;
    var manifest = try @import("../../../repository/manifest.zig").parseOwned(
        allocator,
        try allocator.dupe(u8, "bad-\xff.zig\x00target.zig\x00"),
    );
    defer manifest.deinit(allocator);
    var tree = try repository_tree.Tree.build(allocator, &manifest);
    defer tree.deinit(allocator);
    var state: model.FileSearchState = .{ .mode = true };
    try state.input.insertSlice("target");
    refreshFileSearch(&state, &tree, .all);
    try std.testing.expectEqual(@as(usize, 1), state.len);
    try std.testing.expectEqualStrings("target.zig", tree.nodes[state.selectedNode().?].path);
}

test "repository changed file search ignores clean files and collapsed visibility" {
    const allocator = std.testing.allocator;
    var manifest = try @import("../../../repository/manifest.zig").parseOwned(
        allocator,
        try allocator.dupe(u8, "dir/changed.zig\x00dir/clean.zig\x00"),
    );
    defer manifest.deinit(allocator);
    var tree = try repository_tree.Tree.build(allocator, &manifest);
    defer tree.deinit(allocator);
    var changes = try @import("../../../repository/change_index.zig").parseOwned(
        allocator,
        try allocator.dupe(u8, " M dir/changed.zig\x00"),
    );
    defer changes.deinit(allocator);
    _ = tree.applyChangeIndex(&changes);
    tree.rebuildVisibleFor(.changed);
    try std.testing.expect(tree.toggleVisibleFor(0, .changed));

    var state: model.FileSearchState = .{ .mode = true };
    refreshFileSearch(&state, &tree, .changed);
    try std.testing.expectEqual(@as(usize, 1), state.len);
    try std.testing.expectEqualStrings("dir/changed.zig", tree.nodes[state.selectedNode().?].path);
}
