//! Repository source navigation and bounded file-search projection.

const std = @import("std");
const cursor_viewport = @import("../../cursor_viewport.zig");
const model = @import("model.zig");
const source_geometry = @import("source_geometry.zig");
const source = @import("../../../repository/source.zig");
const selected_document = @import("../../../repository/document.zig");
const repository_tree = @import("../../../repository/tree.zig");

fn sourceBounds(document: *const source.Document, geometry: source_geometry.SourceGeometry) cursor_viewport.Bounds {
    return .{
        .content_rows = document.rowCount(),
        .visible_rows = geometry.visible_source_rows,
    };
}

fn moveSourceCursor(viewer: *model.ViewerState, document: *const source.Document, delta: isize) void {
    if (delta < 0)
        viewer.source_cursor -|= @intCast(-delta)
    else
        viewer.source_cursor = @min(viewer.source_cursor +| @as(usize, @intCast(delta)), document.rowCount() - 1);
}

pub fn moveSource(viewer: *model.ViewerState, document: *const source.Document, delta: isize, geometry: source_geometry.SourceGeometry) void {
    moveSourceCursor(viewer, document, delta);
    clampSource(viewer, document, geometry);
    viewer.source_vertical_scroll = cursor_viewport.placeCursorInComfortBand(
        sourceBounds(document, geometry),
        viewer.source_vertical_scroll,
        viewer.source_cursor,
    );
}

pub fn pageSource(viewer: *model.ViewerState, document: *const source.Document, direction: isize, geometry: source_geometry.SourceGeometry) void {
    const step: isize = @intCast(geometry.navigationRows());
    moveSourceCursor(viewer, document, if (direction < 0) -step else step);
    clampSource(viewer, document, geometry);
    viewer.source_vertical_scroll = cursor_viewport.centerCursor(
        sourceBounds(document, geometry),
        viewer.source_vertical_scroll,
        viewer.source_cursor,
    );
}

/// Source-pane wheel is viewport-primary. Its one-row viewport move is never
/// reverted to preserve the old cursor, and a clamped no-move preserves that
/// cursor exactly.
pub fn wheelSource(viewer: *model.ViewerState, document: *const source.Document, direction: isize, geometry: source_geometry.SourceGeometry) void {
    const bounds = sourceBounds(document, geometry);
    const old_scroll = bounds.clampScroll(viewer.source_vertical_scroll);
    const requested_scroll = if (direction < 0)
        old_scroll -| 1
    else if (direction > 0)
        old_scroll +| 1
    else
        old_scroll;
    const new_scroll = bounds.clampScroll(requested_scroll);
    viewer.source_vertical_scroll = new_scroll;
    if (cursor_viewport.retargetCursorAfterViewportScroll(
        bounds,
        old_scroll,
        new_scroll,
        viewer.source_cursor,
    )) |cursor| viewer.source_cursor = cursor;
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
    const bounds = sourceBounds(document, geometry);
    viewer.source_cursor = @min(viewer.source_cursor, document.rowCount() - 1);
    viewer.source_vertical_scroll = cursor_viewport.keepCursorVisible(
        bounds,
        viewer.source_vertical_scroll,
        viewer.source_cursor,
    );
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
    viewer.source_vertical_scroll = cursor_viewport.placeCursorInComfortBand(
        sourceBounds(document, geometry),
        viewer.source_vertical_scroll,
        viewer.source_cursor,
    );
}

fn sourceDocumentWithRowsForTest(allocator: std.mem.Allocator, rows: usize) !source.Document {
    const bytes = try allocator.alloc(u8, rows);
    errdefer allocator.free(bytes);
    @memset(bytes, '\n');
    return source.Document.initOwned(allocator, bytes, .init(bytes));
}

test "repository source comfort keeps single row navigation in band and permits content edges" {
    const allocator = std.testing.allocator;
    var document = try sourceDocumentWithRowsForTest(allocator, 100);
    defer document.deinit(allocator);
    const geometry = source_geometry.SourceGeometry.init(.{ .width = 80, .height = 11 }, &document, true);
    try std.testing.expectEqual(@as(u16, 9), geometry.visible_source_rows);

    var viewer: model.ViewerState = .{
        .focus = .source,
        .source_cursor = 23,
        .source_vertical_scroll = 20,
    };
    moveSource(&viewer, &document, 1, geometry);
    try std.testing.expectEqual(@as(usize, 24), viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 20), viewer.source_vertical_scroll);
    moveSource(&viewer, &document, 1, geometry);
    try std.testing.expectEqual(@as(usize, 25), viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 20), viewer.source_vertical_scroll);
    moveSource(&viewer, &document, 1, geometry);
    try std.testing.expectEqual(@as(usize, 26), viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 21), viewer.source_vertical_scroll);

    viewer.source_cursor = 23;
    viewer.source_vertical_scroll = 20;
    moveSource(&viewer, &document, -1, geometry);
    try std.testing.expectEqual(@as(usize, 22), viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 19), viewer.source_vertical_scroll);

    firstSource(&viewer, &document, geometry);
    try std.testing.expectEqual(@as(usize, 0), viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 0), viewer.source_vertical_scroll);
    lastSource(&viewer, &document, geometry);
    try std.testing.expectEqual(@as(usize, 99), viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 91), viewer.source_vertical_scroll);
}

test "repository source comfort keeps wheel viewport primary at edges and inside band" {
    const allocator = std.testing.allocator;
    var document = try sourceDocumentWithRowsForTest(allocator, 100);
    defer document.deinit(allocator);
    const geometry = source_geometry.SourceGeometry.init(.{ .width = 80, .height = 11 }, &document, true);
    var viewer: model.ViewerState = .{
        .focus = .source,
        .source_cursor = 20,
        .source_vertical_scroll = 20,
        .source_horizontal_scroll = 7,
    };

    wheelSource(&viewer, &document, 1, geometry);
    try std.testing.expectEqual(@as(usize, 21), viewer.source_vertical_scroll);
    try std.testing.expectEqual(@as(usize, 25), viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 7), viewer.source_horizontal_scroll);

    viewer.source_cursor = 24;
    viewer.source_vertical_scroll = 20;
    wheelSource(&viewer, &document, 1, geometry);
    try std.testing.expectEqual(@as(usize, 21), viewer.source_vertical_scroll);
    try std.testing.expectEqual(@as(usize, 25), viewer.source_cursor);

    viewer.source_cursor = 29;
    viewer.source_vertical_scroll = 21;
    wheelSource(&viewer, &document, -1, geometry);
    try std.testing.expectEqual(@as(usize, 20), viewer.source_vertical_scroll);
    try std.testing.expectEqual(@as(usize, 24), viewer.source_cursor);

    viewer.source_cursor = 4;
    viewer.source_vertical_scroll = 0;
    wheelSource(&viewer, &document, -1, geometry);
    try std.testing.expectEqual(@as(usize, 0), viewer.source_vertical_scroll);
    try std.testing.expectEqual(@as(usize, 4), viewer.source_cursor);

    viewer.source_cursor = 95;
    viewer.source_vertical_scroll = 91;
    wheelSource(&viewer, &document, 1, geometry);
    try std.testing.expectEqual(@as(usize, 91), viewer.source_vertical_scroll);
    try std.testing.expectEqual(@as(usize, 95), viewer.source_cursor);
}

test "repository source comfort centers pages and places explicit search in band" {
    const allocator = std.testing.allocator;
    var document = try sourceDocumentWithRowsForTest(allocator, 100);
    defer document.deinit(allocator);
    const geometry = source_geometry.SourceGeometry.init(.{ .width = 80, .height = 12 }, &document, true);
    var viewer: model.ViewerState = .{
        .focus = .source,
        .source_cursor = 24,
        .source_vertical_scroll = 20,
    };

    pageSource(&viewer, &document, 1, geometry);
    try std.testing.expectEqual(@as(usize, 34), viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 29), viewer.source_vertical_scroll);
    pageSource(&viewer, &document, -1, geometry);
    try std.testing.expectEqual(@as(usize, 24), viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 19), viewer.source_vertical_scroll);

    viewer.source_vertical_scroll = 0;
    revealMatch(&viewer, &document, .{ .line = 50, .start = 0, .end = 0 }, geometry);
    try std.testing.expectEqual(@as(usize, 50), viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 44), viewer.source_vertical_scroll);
}

test "repository source comfort keeps reconciliation minimal and handles tiny viewports" {
    const allocator = std.testing.allocator;
    var document = try sourceDocumentWithRowsForTest(allocator, 100);
    defer document.deinit(allocator);

    const regular = source_geometry.SourceGeometry.init(.{ .width = 80, .height = 11 }, &document, true);
    var viewer: model.ViewerState = .{
        .focus = .source,
        .source_cursor = 24,
        .source_vertical_scroll = 20,
    };
    clampSource(&viewer, &document, regular);
    try std.testing.expectEqual(@as(usize, 20), viewer.source_vertical_scroll);

    const three_rows = source_geometry.SourceGeometry.init(.{ .width = 80, .height = 5 }, &document, true);
    clampSource(&viewer, &document, three_rows);
    try std.testing.expectEqual(@as(usize, 22), viewer.source_vertical_scroll);

    const zero_rows = source_geometry.SourceGeometry.init(.{ .width = 80, .height = 2 }, &document, true);
    viewer.source_cursor = 5;
    viewer.source_vertical_scroll = 20;
    moveSource(&viewer, &document, 1, zero_rows);
    try std.testing.expectEqual(@as(usize, 6), viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 20), viewer.source_vertical_scroll);
    wheelSource(&viewer, &document, 1, zero_rows);
    try std.testing.expectEqual(@as(usize, 6), viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 21), viewer.source_vertical_scroll);

    const one_row = source_geometry.SourceGeometry.init(.{ .width = 80, .height = 3 }, &document, true);
    viewer.source_cursor = 20;
    viewer.source_vertical_scroll = 20;
    moveSource(&viewer, &document, 1, one_row);
    try std.testing.expectEqual(@as(usize, 21), viewer.source_vertical_scroll);

    const two_rows = source_geometry.SourceGeometry.init(.{ .width = 80, .height = 4 }, &document, true);
    viewer.source_cursor = 21;
    viewer.source_vertical_scroll = 20;
    moveSource(&viewer, &document, 1, two_rows);
    try std.testing.expectEqual(@as(usize, 21), viewer.source_vertical_scroll);

    viewer.source_cursor = 21;
    viewer.source_vertical_scroll = 20;
    moveSource(&viewer, &document, 1, three_rows);
    try std.testing.expectEqual(@as(usize, 21), viewer.source_vertical_scroll);

    var empty = try sourceDocumentWithRowsForTest(allocator, 0);
    defer empty.deinit(allocator);
    var empty_viewer: model.ViewerState = .{
        .focus = .source,
        .source_cursor = 99,
        .source_vertical_scroll = 99,
    };
    clampSource(&empty_viewer, &empty, three_rows);
    wheelSource(&empty_viewer, &empty, 1, three_rows);
    try std.testing.expectEqual(@as(usize, 0), empty_viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 0), empty_viewer.source_vertical_scroll);
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

test "repository selection navigation clamps cursor scroll and horizontal cells" {
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
