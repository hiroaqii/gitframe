//! Repository source navigation and bounded file-search projection.

const std = @import("std");
const cursor_viewport = @import("../../cursor_viewport.zig");
const model = @import("model.zig");
const source_layout = @import("source_layout.zig");
const source_geometry = @import("source_geometry.zig");
const source = @import("../../../repository/source.zig");
const selected_document = @import("../../../repository/document.zig");
const repository_tree = @import("../../../repository/tree.zig");

fn sourceBounds(
    document: *const source.Document,
    geometry: source_geometry.SourceGeometry,
) cursor_viewport.Bounds {
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
    if (viewer.line_wrap) {
        viewer.source_cursor = @min(viewer.source_cursor, document.rowCount() - 1);
        const layout = source_layout.Layout.init(document, viewer.*, geometry);
        viewer.source_vertical_scroll = layout.reveal(viewer.source_vertical_scroll, .{ .line = viewer.source_cursor }, geometry.visible_source_rows, false);
        return;
    }
    clampSource(viewer, document, geometry);
    viewer.source_vertical_scroll.line = cursor_viewport.placeCursorInComfortBand(
        sourceBounds(document, geometry),
        viewer.source_vertical_scroll.line,
        viewer.source_cursor,
    );
}

pub fn pageSource(viewer: *model.ViewerState, document: *const source.Document, direction: isize, geometry: source_geometry.SourceGeometry) void {
    pageSourceByRows(viewer, document, direction, geometry.navigationRows(), geometry);
}

pub fn halfPageSource(viewer: *model.ViewerState, document: *const source.Document, direction: isize, geometry: source_geometry.SourceGeometry) void {
    const step = @max(@as(usize, geometry.visible_source_rows) / 2, 1);
    pageSourceByRows(viewer, document, direction, step, geometry);
}

fn pageSourceByRows(
    viewer: *model.ViewerState,
    document: *const source.Document,
    direction: isize,
    step: usize,
    geometry: source_geometry.SourceGeometry,
) void {
    if (viewer.line_wrap) {
        const layout = source_layout.Layout.init(document, viewer.*, geometry);
        viewer.source_vertical_scroll = layout.scroll(viewer.source_vertical_scroll, direction, step, geometry.visible_source_rows);
        retainVisibleCursor(viewer, layout, geometry.visible_source_rows);
        return;
    }
    const target = if (direction < 0) viewer.source_cursor -| step else viewer.source_cursor +| step;
    viewer.source_cursor = @min(target, document.rowCount() - 1);
    clampSource(viewer, document, geometry);
    viewer.source_vertical_scroll.line = cursor_viewport.centerCursor(
        sourceBounds(document, geometry),
        viewer.source_vertical_scroll.line,
        viewer.source_cursor,
    );
}

/// Source-pane wheel is viewport-primary until it reaches a content edge,
/// where further wheel input steps the cursor one source row at a time.
pub fn wheelSource(viewer: *model.ViewerState, document: *const source.Document, direction: isize, geometry: source_geometry.SourceGeometry) void {
    scrollSource(viewer, document, direction, geometry, .pointer);
}

/// A timer reaching a content edge must not move the cursor before the caller
/// terminates the drag step without re-hit-testing its endpoint.
pub fn autoScrollSource(viewer: *model.ViewerState, document: *const source.Document, direction: isize, geometry: source_geometry.SourceGeometry) void {
    scrollSource(viewer, document, direction, geometry, .drag);
}

fn scrollSource(viewer: *model.ViewerState, document: *const source.Document, direction: isize, geometry: source_geometry.SourceGeometry, origin: enum { pointer, drag }) void {
    if (viewer.line_wrap) {
        const layout = source_layout.Layout.init(document, viewer.*, geometry);
        const old = layout.clamp(viewer.source_vertical_scroll, geometry.visible_source_rows);
        viewer.source_vertical_scroll = layout.scroll(old, direction, 1, geometry.visible_source_rows);
        if (std.meta.eql(old, viewer.source_vertical_scroll)) {
            if (origin == .pointer and direction != 0 and geometry.visible_source_rows != 0 and
                document.contentLineCount() != 0 and viewer.source_cursor < document.rowCount())
                moveSourceCursor(viewer, document, if (direction < 0) -1 else 1);
        } else retainVisibleCursor(viewer, layout, geometry.visible_source_rows);
        return;
    }
    const bounds = sourceBounds(document, geometry);
    const old_scroll = bounds.clampScroll(viewer.source_vertical_scroll.line);
    const requested_scroll = if (direction < 0)
        old_scroll -| 1
    else if (direction > 0)
        old_scroll +| 1
    else
        old_scroll;
    const new_scroll = bounds.clampScroll(requested_scroll);
    viewer.source_vertical_scroll.line = new_scroll;
    if (old_scroll == new_scroll) {
        if (origin == .drag or bounds.visible_rows == 0 or direction == 0 or document.contentLineCount() == 0) return;
        if (viewer.source_cursor >= document.rowCount()) return;
        moveSourceCursor(viewer, document, if (direction < 0) -1 else 1);
        return;
    }
    if (cursor_viewport.retargetCursorAfterViewportScroll(
        bounds,
        old_scroll,
        new_scroll,
        viewer.source_cursor,
    )) |cursor| {
        viewer.source_cursor = @min(cursor, document.rowCount() - 1);
    }
}

/// Scroll only the viewport. A keyboard line selection owns the
/// semantic cursor/endpoint, so a pointer wheel must not retarget either one.
pub fn scrollSourceViewport(
    viewer: *model.ViewerState,
    document: *const source.Document,
    direction: isize,
    geometry: source_geometry.SourceGeometry,
) void {
    if (viewer.line_wrap) {
        const layout = source_layout.Layout.init(document, viewer.*, geometry);
        viewer.source_vertical_scroll = layout.scroll(viewer.source_vertical_scroll, direction, 1, geometry.visible_source_rows);
        return;
    }
    const bounds = sourceBounds(document, geometry);
    const current = bounds.clampScroll(viewer.source_vertical_scroll.line);
    const requested = if (direction < 0)
        current -| 1
    else if (direction > 0)
        current +| 1
    else
        current;
    viewer.source_vertical_scroll.line = bounds.clampScroll(requested);
}

pub fn firstSource(viewer: *model.ViewerState, document: *const source.Document, geometry: source_geometry.SourceGeometry) void {
    viewer.source_cursor = 0;
    if (viewer.line_wrap) {
        viewer.source_vertical_scroll = .{};
        return;
    }
    clampSource(viewer, document, geometry);
}

pub fn lastSource(viewer: *model.ViewerState, document: *const source.Document, geometry: source_geometry.SourceGeometry) void {
    viewer.source_cursor = document.rowCount() - 1;
    if (viewer.line_wrap) {
        const layout = source_layout.Layout.init(document, viewer.*, geometry);
        viewer.source_vertical_scroll = layout.reveal(viewer.source_vertical_scroll, .{ .line = viewer.source_cursor }, geometry.visible_source_rows, false);
        return;
    }
    clampSource(viewer, document, geometry);
}

/// Move to one already-range-checked real source row and center it when the
/// viewport permits. Horizontal position is preserved except for the same
/// document/geometry clamp used by every other source navigation path.
pub fn gotoSourceLine(
    viewer: *model.ViewerState,
    document: *const source.Document,
    line_index: usize,
    geometry: source_geometry.SourceGeometry,
) void {
    std.debug.assert(line_index < document.contentLineCount());
    viewer.focus = .source;
    viewer.source_cursor = line_index;
    if (viewer.line_wrap) {
        const layout = source_layout.Layout.init(document, viewer.*, geometry);
        viewer.source_vertical_scroll = layout.reveal(viewer.source_vertical_scroll, .{ .line = line_index }, geometry.visible_source_rows, true);
        return;
    }
    clampSource(viewer, document, geometry);
    viewer.source_vertical_scroll.line = cursor_viewport.centerCursor(
        sourceBounds(document, geometry),
        viewer.source_vertical_scroll.line,
        viewer.source_cursor,
    );
}

pub fn scrollSourceHorizontal(viewer: *model.ViewerState, document: *const source.Document, delta: isize, geometry: source_geometry.SourceGeometry) void {
    if (viewer.line_wrap) return;
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
    if (viewer.line_wrap) {
        const layout = source_layout.Layout.init(document, viewer.*, geometry);
        viewer.source_cursor = @min(viewer.source_cursor, document.rowCount() - 1);
        viewer.source_vertical_scroll = layout.clamp(viewer.source_vertical_scroll, geometry.visible_source_rows);
        if (geometry.visible_source_rows > 0) {
            const visible = layout.visibleLines(viewer.source_vertical_scroll, geometry.visible_source_rows);
            if (viewer.source_cursor < visible.first or viewer.source_cursor > visible.last)
                viewer.source_vertical_scroll = layout.reveal(viewer.source_vertical_scroll, .{ .line = viewer.source_cursor }, geometry.visible_source_rows, false);
        }
        return;
    }
    viewer.source_vertical_scroll.intra = null;
    const bounds = sourceBounds(document, geometry);
    viewer.source_cursor = @min(viewer.source_cursor, document.rowCount() - 1);
    viewer.source_vertical_scroll.line = cursor_viewport.keepCursorVisible(
        bounds,
        viewer.source_vertical_scroll.line,
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
    if (viewer.line_wrap) {
        const layout = source_layout.Layout.init(document, viewer.*, geometry);
        viewer.source_vertical_scroll = layout.reveal(viewer.source_vertical_scroll, .{ .line = match.line, .intra = .{
            .byte = match.start,
            .fingerprint = document.fingerprint,
        } }, geometry.visible_source_rows, false);
        return;
    }
    const match_col = document.displayColumnForByte(match.line, match.start) orelse 0;
    if (match_col < viewer.source_horizontal_scroll) viewer.source_horizontal_scroll = match_col;
    if (geometry.text_width > 0 and match_col >= viewer.source_horizontal_scroll + geometry.text_width) {
        viewer.source_horizontal_scroll = match_col - geometry.text_width + 1;
    }
    clampSource(viewer, document, geometry);
    viewer.source_vertical_scroll.line = cursor_viewport.placeCursorInComfortBand(
        sourceBounds(document, geometry),
        viewer.source_vertical_scroll.line,
        viewer.source_cursor,
    );
}

fn retainVisibleCursor(viewer: *model.ViewerState, layout: source_layout.Layout, visible_rows: usize) void {
    if (visible_rows == 0) return;
    const visible = layout.visibleLines(viewer.source_vertical_scroll, visible_rows);
    viewer.source_cursor = std.math.clamp(viewer.source_cursor, visible.first, visible.last);
}

fn sourceDocumentWithRowsForTest(allocator: std.mem.Allocator, rows: usize) !source.Document {
    const bytes = try allocator.alloc(u8, rows);
    errdefer allocator.free(bytes);
    @memset(bytes, '\n');
    return source.Document.initOwned(allocator, bytes, .init(bytes));
}

test "repository wrap navigation reaches tall line tail and reveals same-line occurrences" {
    const allocator = std.testing.allocator;
    const line = "x" ** 40 ++ "needle" ++ "y" ** 40 ++ "needleEND";
    const bytes = try allocator.dupe(u8, line ++ "\nnext\n");
    var document = try source.Document.initOwnedOrFree(allocator, bytes, .init(bytes));
    defer document.deinit(allocator);
    const geometry = source_geometry.SourceGeometry.init(.{ .width = 12, .height = 6 }, &document, false);
    var viewer: model.ViewerState = .{ .line_wrap = true, .focus = .source };
    pageSource(&viewer, &document, 1, geometry);
    try std.testing.expectEqual(@as(usize, 30), viewer.source_vertical_scroll.intra.?.byte);
    try std.testing.expectEqual(@as(usize, 0), viewer.source_cursor);
    wheelSource(&viewer, &document, 1, geometry);
    try std.testing.expectEqual(@as(usize, 40), viewer.source_vertical_scroll.intra.?.byte);
    const first_match = document.findNext("needle", null).?;
    const second_match = document.findNext("needle", first_match).?;
    try std.testing.expectEqual(@as(usize, 86), second_match.start);
    revealMatch(&viewer, &document, second_match, geometry);
    const layout = source_layout.Layout.init(&document, viewer, geometry);
    const match_row = layout.contentRowAt(geometry, viewer.source_vertical_scroll, geometry.body_first_row + 1).?;
    try std.testing.expect(match_row.fragment.?.bytes.start <= second_match.start);
    try std.testing.expect(match_row.fragment.?.bytes.end > second_match.start);
    revealMatch(&viewer, &document, document.findPrevious("needle", second_match).?, geometry);
    try std.testing.expectEqual(@as(usize, 30), viewer.source_vertical_scroll.intra.?.byte);
    for (0..20) |_| wheelSource(&viewer, &document, 1, geometry);
    try std.testing.expectEqual(@as(usize, 80), viewer.source_vertical_scroll.intra.?.byte);
    const bottom = viewer.source_vertical_scroll;
    autoScrollSource(&viewer, &document, 1, geometry);
    try std.testing.expectEqualDeep(bottom, viewer.source_vertical_scroll);
    // Wheel reaches the next source line at the edge; explicit k returns to
    // the first fragment of the preceding logical line.
    try std.testing.expectEqual(@as(usize, 1), viewer.source_cursor);
    moveSource(&viewer, &document, -1, geometry);
    try std.testing.expectEqual(@as(usize, 0), viewer.source_cursor);
    try std.testing.expect(viewer.source_vertical_scroll.intra == null);
    moveSource(&viewer, &document, 1, geometry);
    try std.testing.expectEqual(@as(usize, 1), viewer.source_cursor);
    try std.testing.expectEqualDeep(bottom, viewer.source_vertical_scroll);
    scrollSourceHorizontal(&viewer, &document, 8, geometry);
    try std.testing.expectEqual(@as(usize, 0), viewer.source_horizontal_scroll);
}

test "repository source comfort keeps single row navigation in band and permits content edges" {
    const allocator = std.testing.allocator;
    var document = try sourceDocumentWithRowsForTest(allocator, 100);
    defer document.deinit(allocator);
    const geometry = source_geometry.SourceGeometry.init(.{ .width = 80, .height = 11 }, &document, true);
    try std.testing.expectEqual(@as(u16, 8), geometry.visible_source_rows);

    var viewer: model.ViewerState = .{
        .focus = .source,
        .source_cursor = 23,
        .source_vertical_scroll = .{ .line = 20 },
    };
    moveSource(&viewer, &document, 1, geometry);
    try std.testing.expectEqual(@as(usize, 24), viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 20), viewer.source_vertical_scroll.line);
    moveSource(&viewer, &document, 1, geometry);
    try std.testing.expectEqual(@as(usize, 25), viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 20), viewer.source_vertical_scroll.line);
    moveSource(&viewer, &document, 1, geometry);
    try std.testing.expectEqual(@as(usize, 26), viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 21), viewer.source_vertical_scroll.line);

    viewer.source_cursor = 23;
    viewer.source_vertical_scroll.line = 20;
    moveSource(&viewer, &document, -1, geometry);
    try std.testing.expectEqual(@as(usize, 22), viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 20), viewer.source_vertical_scroll.line);

    viewer.source_cursor = 20;
    viewer.source_vertical_scroll.line = 20;
    halfPageSource(&viewer, &document, 1, geometry);
    try std.testing.expectEqual(@as(usize, 24), viewer.source_cursor);

    firstSource(&viewer, &document, geometry);
    try std.testing.expectEqual(@as(usize, 0), viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 0), viewer.source_vertical_scroll.line);
    lastSource(&viewer, &document, geometry);
    try std.testing.expectEqual(@as(usize, 99), viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 92), viewer.source_vertical_scroll.line);
}

test "repository source wheel preserves visible screen rows and clamps offscreen cursors" {
    const allocator = std.testing.allocator;
    var document = try sourceDocumentWithRowsForTest(allocator, 100);
    defer document.deinit(allocator);
    const geometry = source_geometry.SourceGeometry.init(.{ .width = 80, .height = 11 }, &document, true);
    var viewer: model.ViewerState = .{
        .focus = .source,
        .source_cursor = 20,
        .source_vertical_scroll = .{ .line = 20 },
        .source_horizontal_scroll = 7,
    };

    for (0..geometry.visible_source_rows) |screen_row| {
        viewer.source_cursor = 20 + screen_row;
        viewer.source_vertical_scroll.line = 20;
        wheelSource(&viewer, &document, 1, geometry);
        try std.testing.expectEqual(@as(usize, 21), viewer.source_vertical_scroll.line);
        try std.testing.expectEqual(21 + screen_row, viewer.source_cursor);

        wheelSource(&viewer, &document, -1, geometry);
        try std.testing.expectEqual(@as(usize, 20), viewer.source_vertical_scroll.line);
        try std.testing.expectEqual(20 + screen_row, viewer.source_cursor);
        try std.testing.expectEqual(@as(usize, 7), viewer.source_horizontal_scroll);
    }

    viewer.source_cursor = 0;
    wheelSource(&viewer, &document, 1, geometry);
    try std.testing.expectEqual(@as(usize, 21), viewer.source_vertical_scroll.line);
    try std.testing.expectEqual(@as(usize, 21), viewer.source_cursor);

    viewer.source_cursor = 29;
    wheelSource(&viewer, &document, -1, geometry);
    try std.testing.expectEqual(@as(usize, 20), viewer.source_vertical_scroll.line);
    try std.testing.expectEqual(@as(usize, 27), viewer.source_cursor);

    viewer.source_cursor = 4;
    viewer.source_vertical_scroll.line = 0;
    wheelSource(&viewer, &document, -1, geometry);
    try std.testing.expectEqual(@as(usize, 0), viewer.source_vertical_scroll.line);
    try std.testing.expectEqual(@as(usize, 3), viewer.source_cursor);

    viewer.source_cursor = 95;
    viewer.source_vertical_scroll.line = 92;
    wheelSource(&viewer, &document, 1, geometry);
    try std.testing.expectEqual(@as(usize, 92), viewer.source_vertical_scroll.line);
    try std.testing.expectEqual(@as(usize, 96), viewer.source_cursor);
}

test "repository wheel reaches both content edges for long short and exact-fit documents" {
    const allocator = std.testing.allocator;
    for ([_]usize{ 1, 4, 8, 100 }) |rows| {
        var document = try sourceDocumentWithRowsForTest(allocator, rows);
        defer document.deinit(allocator);
        const geometry = source_geometry.SourceGeometry.init(.{ .width = 80, .height = 11 }, &document, true);
        const max_scroll = sourceBounds(&document, geometry).maxScroll();
        for ([_]isize{ -1, 1 }) |direction| {
            var viewer: model.ViewerState = .{
                .source_cursor = rows / 2,
                .source_vertical_scroll = .{ .line = if (direction < 0) 0 else max_scroll },
                .source_horizontal_scroll = 7,
            };
            const edge_scroll = viewer.source_vertical_scroll.line;
            var expected = viewer.source_cursor;
            for (0..rows + 2) |_| {
                expected = if (direction < 0) expected -| 1 else @min(expected + 1, rows - 1);
                wheelSource(&viewer, &document, direction, geometry);
                try std.testing.expectEqual(expected, viewer.source_cursor);
                try std.testing.expectEqual(edge_scroll, viewer.source_vertical_scroll.line);
                try std.testing.expectEqual(@as(usize, 7), viewer.source_horizontal_scroll);
            }
        }
    }
}

test "repository wheel edge leaves drag viewport-only zero-height and zero intent cursors unchanged" {
    const allocator = std.testing.allocator;
    var document = try sourceDocumentWithRowsForTest(allocator, 4);
    defer document.deinit(allocator);
    const geometry = source_geometry.SourceGeometry.init(.{ .width = 80, .height = 11 }, &document, true);
    var viewer: model.ViewerState = .{ .source_cursor = 2 };
    for ([_]isize{ -1, 1 }) |direction| {
        autoScrollSource(&viewer, &document, direction, geometry);
        scrollSourceViewport(&viewer, &document, direction, geometry);
        try std.testing.expectEqual(@as(usize, 2), viewer.source_cursor);
        try std.testing.expectEqual(@as(usize, 0), viewer.source_vertical_scroll.line);
    }
    wheelSource(&viewer, &document, 0, geometry);
    try std.testing.expectEqual(@as(usize, 2), viewer.source_cursor);
    const zero = source_geometry.SourceGeometry.init(.{ .width = 80, .height = 2 }, &document, true);
    for ([_]isize{ -1, 1 }) |direction| {
        viewer.source_vertical_scroll.line = if (direction < 0) 0 else sourceBounds(&document, zero).maxScroll();
        wheelSource(&viewer, &document, direction, zero);
        try std.testing.expectEqual(@as(usize, 2), viewer.source_cursor);
    }
}

test "repository source comfort centers pages and places explicit search in band" {
    const allocator = std.testing.allocator;
    var document = try sourceDocumentWithRowsForTest(allocator, 100);
    defer document.deinit(allocator);
    const geometry = source_geometry.SourceGeometry.init(.{ .width = 80, .height = 12 }, &document, true);
    var viewer: model.ViewerState = .{
        .focus = .source,
        .source_cursor = 24,
        .source_vertical_scroll = .{ .line = 20 },
    };

    pageSource(&viewer, &document, 1, geometry);
    try std.testing.expectEqual(@as(usize, 33), viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 29), viewer.source_vertical_scroll.line);
    pageSource(&viewer, &document, -1, geometry);
    try std.testing.expectEqual(@as(usize, 24), viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 20), viewer.source_vertical_scroll.line);

    halfPageSource(&viewer, &document, 1, geometry);
    try std.testing.expectEqual(@as(usize, 28), viewer.source_cursor);
    halfPageSource(&viewer, &document, -1, geometry);
    try std.testing.expectEqual(@as(usize, 24), viewer.source_cursor);

    viewer.source_vertical_scroll.line = 0;
    revealMatch(&viewer, &document, .{ .line = 50, .start = 0, .end = 0 }, geometry);
    try std.testing.expectEqual(@as(usize, 50), viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 45), viewer.source_vertical_scroll.line);
}

test "repository source line jump centers real rows and preserves horizontal scroll" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(
        u8,
        "0123456789abcdef\n" ** 20,
    );
    var document = try source.Document.initOwnedOrFree(allocator, bytes, .init(bytes));
    defer document.deinit(allocator);
    const geometry = source_geometry.SourceGeometry.init(.{ .width = 8, .height = 8 }, &document, false);
    var viewer: model.ViewerState = .{
        .focus = .source,
        .source_cursor = 1,
        .source_vertical_scroll = .{ .line = 0 },
        .source_horizontal_scroll = 5,
    };

    gotoSourceLine(&viewer, &document, 14, geometry);

    try std.testing.expectEqual(@as(usize, 14), viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 5), viewer.source_horizontal_scroll);
    try std.testing.expectEqual(
        cursor_viewport.centerCursor(sourceBounds(&document, geometry), 0, 14),
        viewer.source_vertical_scroll.line,
    );
}

test "repository source comfort keeps reconciliation minimal and handles tiny viewports" {
    const allocator = std.testing.allocator;
    var document = try sourceDocumentWithRowsForTest(allocator, 100);
    defer document.deinit(allocator);

    const regular = source_geometry.SourceGeometry.init(.{ .width = 80, .height = 11 }, &document, true);
    var viewer: model.ViewerState = .{
        .focus = .source,
        .source_cursor = 24,
        .source_vertical_scroll = .{ .line = 20 },
    };
    clampSource(&viewer, &document, regular);
    try std.testing.expectEqual(@as(usize, 20), viewer.source_vertical_scroll.line);

    const two_rows = source_geometry.SourceGeometry.init(.{ .width = 80, .height = 5 }, &document, true);
    clampSource(&viewer, &document, two_rows);
    try std.testing.expectEqual(@as(usize, 23), viewer.source_vertical_scroll.line);

    const zero_rows = source_geometry.SourceGeometry.init(.{ .width = 80, .height = 2 }, &document, true);
    viewer.source_cursor = 5;
    viewer.source_vertical_scroll.line = 20;
    moveSource(&viewer, &document, 1, zero_rows);
    try std.testing.expectEqual(@as(usize, 6), viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 20), viewer.source_vertical_scroll.line);
    wheelSource(&viewer, &document, 1, zero_rows);
    try std.testing.expectEqual(@as(usize, 6), viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 21), viewer.source_vertical_scroll.line);
    halfPageSource(&viewer, &document, 1, zero_rows);
    try std.testing.expectEqual(@as(usize, 7), viewer.source_cursor);

    const spacer_only = source_geometry.SourceGeometry.init(.{ .width = 80, .height = 3 }, &document, true);
    viewer.source_cursor = 20;
    viewer.source_vertical_scroll.line = 20;
    moveSource(&viewer, &document, 1, spacer_only);
    try std.testing.expectEqual(@as(usize, 20), viewer.source_vertical_scroll.line);

    const one_row = source_geometry.SourceGeometry.init(.{ .width = 80, .height = 4 }, &document, true);
    viewer.source_cursor = 21;
    viewer.source_vertical_scroll.line = 20;
    moveSource(&viewer, &document, 1, one_row);
    try std.testing.expectEqual(@as(usize, 22), viewer.source_vertical_scroll.line);

    viewer.source_cursor = 21;
    viewer.source_vertical_scroll.line = 20;
    moveSource(&viewer, &document, 1, two_rows);
    try std.testing.expectEqual(@as(usize, 21), viewer.source_vertical_scroll.line);

    var empty = try sourceDocumentWithRowsForTest(allocator, 0);
    defer empty.deinit(allocator);
    var empty_viewer: model.ViewerState = .{
        .focus = .source,
        .source_cursor = 99,
        .source_vertical_scroll = .{ .line = 99 },
    };
    clampSource(&empty_viewer, &empty, two_rows);
    wheelSource(&empty_viewer, &empty, 1, two_rows);
    halfPageSource(&empty_viewer, &empty, 1, two_rows);
    pageSource(&empty_viewer, &empty, -1, two_rows);
    firstSource(&empty_viewer, &empty, two_rows);
    lastSource(&empty_viewer, &empty, two_rows);
    try std.testing.expectEqual(@as(usize, 0), empty_viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 0), empty_viewer.source_vertical_scroll.line);
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
    // One source row remains visible after the three-row Repository chrome.
    const geometry = source_geometry.SourceGeometry.init(.{ .width = 7, .height = 4 }, &document, true);
    var viewer: model.ViewerState = .{ .focus = .source };
    moveSource(&viewer, &document, 20, geometry);
    try std.testing.expectEqual(@as(usize, 2), viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 2), viewer.source_vertical_scroll.line);
    scrollSourceHorizontal(&viewer, &document, 8, geometry);
    // Two gutter columns, a line number, and a separator leave three text cells.
    try std.testing.expectEqual(@as(usize, 7), viewer.source_horizontal_scroll);
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
