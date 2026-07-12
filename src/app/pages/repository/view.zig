//! Repository source-pane rendering over page-owned source coordinates.

const std = @import("std");
const chasen = @import("chasen");
const draw = @import("draw");
const theme = @import("theme");
const model = @import("model.zig");
const navigation = @import("navigation.zig");
const source = @import("../../../repository/source.zig");
const source_syntax = @import("../../../syntax/source.zig");
const syntax_style = @import("../../../syntax/style.zig");
const syntax_token = @import("../../../syntax/token.zig");
const manifest = @import("../../../repository/manifest.zig");
const repository_tree = @import("../../../repository/tree.zig");

pub fn sourceTextWidth(width: u16, document: *const source.Document, line_numbers: bool) u16 {
    const number_columns: usize = if (line_numbers) decimalDigits(document.rowCount()) + 1 else 0;
    return width -| @as(u16, @intCast(1 + number_columns));
}

pub fn drawSource(
    surface: *chasen.Surface,
    document: *const source.Document,
    syntax: ?*const source_syntax.SourceSpans,
    viewer: model.ViewerState,
    search: model.SourceSearchState,
    palette: theme.Palette,
) !void {
    const size = surface.size();
    if (size.height == 0 or size.width == 0) return;
    drawSearchRow(surface, search, palette);
    if (size.height <= 2) return;

    const rows = navigation.sourceBodyRows(size.height);
    const number_width = if (viewer.line_numbers) decimalDigits(document.rowCount()) else 0;
    const text_col: u16 = @intCast(1 + if (viewer.line_numbers) number_width + 1 else 0);
    const text_width = size.width -| text_col;
    var body_row: usize = 0;
    while (body_row < rows and viewer.source_vertical_scroll + body_row < document.rowCount()) : (body_row += 1) {
        const line_index = viewer.source_vertical_scroll + body_row;
        const row: u16 = @intCast(body_row + 2);
        const current = line_index == viewer.source_cursor;
        const base_style = if (current)
            palette.boldStyle(.prompt)
        else
            palette.style(.foreground);

        _ = surface.borrowTextAt(0, row, " ", palette.style(.diff_added));
        if (viewer.line_numbers) {
            const number = try std.fmt.allocPrint(surface.frameAllocator(), "{d}", .{line_index + 1});
            const number_col: u16 = @intCast(1 + number_width - chasen.text.displayWidth(number));
            draw.copyClippedTextAt(surface, number_col, row, number, if (current) palette.boldStyle(.diff_cursor) else palette.style(.diff_line_number)) catch {};
        }
        if (text_width == 0) continue;
        const line = document.lineBody(line_index).?;
        const visible = try source.renderWindowAlloc(surface.frameAllocator(), line, viewer.source_horizontal_scroll, text_width);
        draw.copyClippedTextAt(surface, text_col, row, visible, base_style) catch {};
        if (syntax) |spans| applySyntaxLineStyles(
            surface,
            text_col,
            row,
            line,
            viewer.source_horizontal_scroll,
            text_width,
            spans.lineSpans(line_index),
            base_style,
            palette,
            null,
        );
        if (search.match) |match| if (match.line == line_index) {
            if (try source.renderRangeWindowAlloc(
                surface.frameAllocator(),
                line,
                match.start,
                match.end,
                viewer.source_horizontal_scroll,
                text_width,
            )) |range| {
                const match_col: u16 = @intCast(@as(usize, text_col) + range.column);
                draw.copyClippedTextAt(surface, match_col, row, range.text, palette.boldStyle(.warning)) catch {};
            }
        };
    }
}

const SyntaxProjectionStats = struct {
    graphemes_visited: usize = 0,
    spans_advanced: usize = 0,
    cells_restyled: usize = 0,
};

/// Restyles the already rendered visible source cells with one monotonic pass
/// over both graphemes and ordered spans. Reusing the plain projection keeps
/// TAB/wide clipping in one implementation and avoids allocating/redrawing a
/// text slice per span, which became quadratic for capture-dense lines.
fn applySyntaxLineStyles(
    surface: *chasen.Surface,
    text_col: u16,
    row: u16,
    line: []const u8,
    horizontal_scroll: usize,
    width: usize,
    line_spans: syntax_token.LineSpans,
    base_style: chasen.TextStyle,
    palette: theme.Palette,
    stats: ?*SyntaxProjectionStats,
) void {
    if (width == 0 or line_spans.spans.len == 0) return;
    const viewport_end = std.math.add(usize, horizontal_scroll, width) catch std.math.maxInt(usize);
    var logical_col: usize = 0;
    var span_index: usize = 0;
    var graphemes = chasen.text.graphemeIterator(line);
    while (graphemes.next()) |grapheme| {
        if (stats) |value| value.graphemes_visited += 1;
        if (logical_col >= viewport_end) break;
        const grapheme_end = grapheme.start + grapheme.len;
        while (span_index < line_spans.spans.len and line_spans.spans[span_index].end <= grapheme.start) {
            span_index += 1;
            if (stats) |value| value.spans_advanced += 1;
        }

        const bytes = grapheme.bytes(line);
        const cells = if (bytes.len == 1 and bytes[0] == '\t')
            source.tab_width - (logical_col % source.tab_width)
        else
            chasen.text.displayWidth(bytes);
        const segment_end = logical_col + cells;
        defer logical_col = segment_end;
        if (span_index >= line_spans.spans.len) continue;
        const span = line_spans.spans[span_index];
        if (span.start > grapheme.start or grapheme_end > span.end) continue;
        if (!syntax_style.changesForeground(span.role)) continue;
        if (segment_end <= horizontal_scroll) continue;

        const visible_start = @max(logical_col, horizontal_scroll);
        const visible_end = @min(segment_end, viewport_end);
        if (visible_start >= visible_end) continue;
        const style = syntax_style.apply(base_style, span.role, palette);
        const relative_start = visible_start - horizontal_scroll;
        const visible_cells = visible_end - visible_start;
        const materialized_as_spaces = bytes.len == 1 and bytes[0] == '\t' or logical_col < horizontal_scroll;
        if (materialized_as_spaces) {
            for (0..visible_cells) |offset| restyleCell(surface, @intCast(@as(usize, text_col) + relative_start + offset), row, style, stats);
        } else if (segment_end <= viewport_end) {
            // A fully visible grapheme is stored in its leading cell; rewriting
            // a backend continuation cell could corrupt wide-character layout.
            restyleCell(surface, @intCast(@as(usize, text_col) + relative_start), row, style, stats);
        }
    }
}

fn restyleCell(surface: *chasen.Surface, col: u16, row: u16, style: chasen.TextStyle, stats: ?*SyntaxProjectionStats) void {
    var cell = surface.readCell(col, row) orelse return;
    cell.style = style;
    surface.writeCell(col, row, cell);
    if (stats) |value| value.cells_restyled += 1;
}

pub fn drawFileSearch(
    surface: *chasen.Surface,
    tree: *const repository_tree.Tree,
    state: *const model.FileSearchState,
    palette: theme.Palette,
) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;
    const prompt_text = try std.fmt.allocPrint(surface.frameAllocator(), "Find file: {s}", .{state.input.slice()});
    draw.copyClippedTextAt(surface, 1, 0, prompt_text, palette.boldStyle(.prompt)) catch {};
    if (size.height > 1) {
        const status = if (state.truncated)
            "512+ matches; refine search"
        else if (state.no_match)
            "No matching files"
        else
            "Enter: open  Esc: cancel";
        draw.copyClippedTextAt(surface, 1, 1, status, palette.style(if (state.no_match) .warning else .muted)) catch {};
    }
    const visible_rows = @as(usize, size.height -| 2);
    const start = fileSearchWindowStart(state.focused, state.len, visible_rows);
    var row: usize = 0;
    while (row < visible_rows and start + row < state.len) : (row += 1) {
        const result_index = start + row;
        const node = tree.nodes[state.matches[result_index]];
        const window = try manifest.displayWindowAlloc(surface.frameAllocator(), node.path, 0, size.width -| 2);
        const style = if (result_index == state.focused) palette.boldStyle(.prompt) else palette.style(.muted);
        draw.copyClippedTextAt(surface, 1, @intCast(row + 2), window.text(), style) catch {};
    }
}

fn fileSearchWindowStart(focused: usize, len: usize, visible_rows: usize) usize {
    if (len == 0 or visible_rows == 0) return 0;
    const clamped_focus = @min(focused, len - 1);
    return if (clamped_focus < visible_rows) 0 else clamped_focus - visible_rows + 1;
}

fn drawSearchRow(surface: *chasen.Surface, search: model.SourceSearchState, palette: theme.Palette) void {
    if (surface.size().height <= 1) return;
    if (search.mode) {
        const text = std.fmt.allocPrint(surface.frameAllocator(), "/{s}", .{search.input.slice()}) catch return;
        draw.copyClippedTextAt(surface, 1, 1, text, palette.boldStyle(.prompt)) catch {};
    } else if (search.query.len > 0) {
        const prefix = if (search.match != null) "match: " else "no match: ";
        const text = std.fmt.allocPrint(surface.frameAllocator(), "{s}{s}", .{ prefix, search.query.slice() }) catch return;
        draw.copyClippedTextAt(surface, 1, 1, text, palette.style(if (search.match != null) .muted else .warning)) catch {};
    }
}

fn decimalDigits(value: usize) usize {
    var number = @max(value, 1);
    var digits: usize = 1;
    while (number >= 10) : (number /= 10) digits += 1;
    return digits;
}

test "repository source view reserves gutter and renders plain text" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, "const value = 1;\nsecond\n");
    var document = try source.Document.initOwned(allocator, bytes, .init(bytes));
    defer document.deinit(allocator);
    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(40, 6);
    defer test_surface.deinit();

    try drawSource(&test_surface.surface, &document, null, .{ .focus = .source }, .{}, .default());
    const snapshot = try test_surface.snapshot(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "1 const value = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "2 second") != null);
}

test "repository empty source keeps one synthetic viewer row" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, "");
    var document = try source.Document.initOwned(allocator, bytes, .init(bytes));
    defer document.deinit(allocator);
    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(12, 4);
    defer test_surface.deinit();
    try drawSource(&test_surface.surface, &document, null, .{ .focus = .source }, .{}, .default());
    try test_surface.expectCellText(0, 2, " ");
    try test_surface.expectCellText(1, 2, "1");
}

test "repository source geometry handles narrow line-number transitions" {
    const allocator = std.testing.allocator;
    const nine_bytes = try allocator.dupe(u8, "\n\n\n\n\n\n\n\n\n");
    var nine = try source.Document.initOwned(allocator, nine_bytes, .init(nine_bytes));
    defer nine.deinit(allocator);
    const ten_bytes = try allocator.dupe(u8, "\n\n\n\n\n\n\n\n\n\nx");
    var ten = try source.Document.initOwned(allocator, ten_bytes, .init(ten_bytes));
    defer ten.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 7), sourceTextWidth(10, &nine, true));
    try std.testing.expectEqual(@as(u16, 6), sourceTextWidth(10, &ten, true));
    try std.testing.expectEqual(@as(u16, 9), sourceTextWidth(10, &ten, false));
    try std.testing.expectEqual(@as(u16, 0), sourceTextWidth(1, &ten, true));
}

test "repository source search checkpoint appears without moving source rows" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, "first\nsecond\n");
    var document = try source.Document.initOwned(allocator, bytes, .init(bytes));
    defer document.deinit(allocator);
    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(32, 6);
    defer test_surface.deinit();

    try drawSource(&test_surface.surface, &document, null, .{ .focus = .source }, .{}, .default());
    var snapshot = try test_surface.snapshot(allocator);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "/needle") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "1 first") != null);
    allocator.free(snapshot);

    test_surface.deinit();
    try test_surface.init(32, 6);
    var search: model.SourceSearchState = .{ .mode = true };
    try search.input.insertSlice("needle");
    try drawSource(&test_surface.surface, &document, null, .{ .focus = .source }, search, .default());
    snapshot = try test_surface.snapshot(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "/needle") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "1 first") != null);
}

test "repository source match overlay remains distinct on the cursor line" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, "a\tneedle\n");
    var document = try source.Document.initOwned(allocator, bytes, .init(bytes));
    defer document.deinit(allocator);
    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(24, 4);
    defer test_surface.deinit();
    const palette: theme.Palette = .default();
    const search: model.SourceSearchState = .{
        .match = .{ .line = 0, .start = 2, .end = 8 },
    };
    try drawSource(&test_surface.surface, &document, null, .{ .focus = .source, .source_cursor = 0 }, search, palette);
    const match_cell = test_surface.surface.readCell(7, 2) orelse return error.ExpectedMatchCell;
    const plain_cell = test_surface.surface.readCell(3, 2) orelse return error.ExpectedPlainCell;
    try std.testing.expectEqual(palette.boldStyle(.warning), match_cell.style);
    try std.testing.expectEqual(palette.boldStyle(.prompt), plain_cell.style);
}

test "repository source syntax uses neutral styles below the search overlay" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, "const value = 1;\n// note\nplain\n");
    var document = try source.Document.initOwned(allocator, bytes, .init(bytes));
    defer document.deinit(allocator);
    var candidates = [_]source_syntax.Candidate{
        .{
            .line_index = 0,
            .span = .{ .start = 0, .end = 5, .role = .keyword },
        },
        .{
            .line_index = 1,
            .span = .{ .start = 0, .end = 7, .role = .comment },
        },
    };
    var spans = try source_syntax.build(allocator, &document, &candidates);
    defer spans.deinit(allocator);
    const palette: theme.Palette = .default();

    var syntax_surface: chasen.testing.TestSurface = undefined;
    try syntax_surface.init(24, 6);
    defer syntax_surface.deinit();
    try drawSource(&syntax_surface.surface, &document, &spans, .{ .focus = .source }, .{}, palette);
    const keyword_cell = syntax_surface.surface.readCell(3, 2) orelse return error.ExpectedKeywordCell;
    const plain_cell = syntax_surface.surface.readCell(9, 2) orelse return error.ExpectedPlainCell;
    const comment_cell = syntax_surface.surface.readCell(3, 3) orelse return error.ExpectedCommentCell;
    const foreground_cell = syntax_surface.surface.readCell(3, 4) orelse return error.ExpectedForegroundCell;
    try std.testing.expectEqual(palette.color(.accent), keyword_cell.style.fg);
    try std.testing.expectEqual(palette.color(.prompt), plain_cell.style.fg);
    try std.testing.expectEqual(palette.color(.muted), comment_cell.style.fg);
    try std.testing.expectEqual(palette.color(.foreground), foreground_cell.style.fg);

    var search_surface: chasen.testing.TestSurface = undefined;
    try search_surface.init(24, 4);
    defer search_surface.deinit();
    try drawSource(&search_surface.surface, &document, &spans, .{ .focus = .source }, .{
        .match = .{ .line = 0, .start = 0, .end = 5 },
    }, palette);
    const match_cell = search_surface.surface.readCell(3, 2) orelse return error.ExpectedMatchCell;
    try std.testing.expectEqual(palette.color(.warning), match_cell.style.fg);
}

test "repository source syntax projection visits dense line and spans only once" {
    const allocator = std.testing.allocator;
    const count = source_syntax.max_spans;
    const line = try allocator.alloc(u8, count);
    defer allocator.free(line);
    @memset(line, 'x');
    const spans = try allocator.alloc(syntax_token.TokenSpan, count);
    defer allocator.free(spans);
    for (spans, 0..) |*span, index| span.* = .{
        .start = index,
        .end = index + 1,
        .role = .keyword,
    };

    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(80, 1);
    defer test_surface.deinit();
    const horizontal_scroll = count - 80;
    const visible = try source.renderWindowAlloc(test_surface.surface.frameAllocator(), line, horizontal_scroll, 80);
    draw.copyClippedTextAt(&test_surface.surface, 0, 0, visible, .{}) catch {};
    var stats: SyntaxProjectionStats = .{};
    applySyntaxLineStyles(
        &test_surface.surface,
        0,
        0,
        line,
        horizontal_scroll,
        80,
        .{ .spans = spans },
        .{},
        .default(),
        &stats,
    );

    try std.testing.expect(stats.graphemes_visited <= count);
    try std.testing.expect(stats.spans_advanced <= count);
    try std.testing.expectEqual(@as(usize, 80), stats.cells_restyled);
    try std.testing.expectEqual(theme.Palette.default().color(.accent), test_surface.surface.readCell(79, 0).?.style.fg);
}

test "repository source syntax projection preserves tab and clipped-wide cells" {
    const line = "\t界x";
    const spans = [_]syntax_token.TokenSpan{
        .{ .start = 0, .end = 1, .role = .keyword },
        .{ .start = 1, .end = 4, .role = .string },
        .{ .start = 4, .end = 5, .role = .number },
    };
    const palette: theme.Palette = .default();

    var tab_surface: chasen.testing.TestSurface = undefined;
    try tab_surface.init(3, 1);
    defer tab_surface.deinit();
    const tab_visible = try source.renderWindowAlloc(tab_surface.surface.frameAllocator(), line, 1, 3);
    draw.copyClippedTextAt(&tab_surface.surface, 0, 0, tab_visible, .{}) catch {};
    applySyntaxLineStyles(&tab_surface.surface, 0, 0, line, 1, 3, .{ .spans = &spans }, .{}, palette, null);
    try std.testing.expectEqual(palette.color(.accent), tab_surface.surface.readCell(0, 0).?.style.fg);
    try std.testing.expectEqual(palette.color(.accent), tab_surface.surface.readCell(2, 0).?.style.fg);

    var wide_surface: chasen.testing.TestSurface = undefined;
    try wide_surface.init(2, 1);
    defer wide_surface.deinit();
    const wide_visible = try source.renderWindowAlloc(wide_surface.surface.frameAllocator(), line, 5, 2);
    draw.copyClippedTextAt(&wide_surface.surface, 0, 0, wide_visible, .{}) catch {};
    applySyntaxLineStyles(&wide_surface.surface, 0, 0, line, 5, 2, .{ .spans = &spans }, .{}, palette, null);
    try std.testing.expectEqualStrings(" ", wide_surface.surface.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqual(palette.color(.success), wide_surface.surface.readCell(0, 0).?.style.fg);
    try std.testing.expectEqualStrings("x", wide_surface.surface.readCell(1, 0).?.char.grapheme);
    try std.testing.expectEqual(palette.color(.warning), wide_surface.surface.readCell(1, 0).?.style.fg);
}

test "repository file search renders its bounded truncation message" {
    const allocator = std.testing.allocator;
    var manifest_document = try manifest.parseOwned(allocator, try allocator.dupe(u8, "one.zig\x00"));
    defer manifest_document.deinit(allocator);
    var tree = try repository_tree.Tree.build(allocator, &manifest_document);
    defer tree.deinit(allocator);
    var search: model.FileSearchState = .{ .mode = true, .truncated = true, .len = 1 };
    search.matches[0] = 0;
    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(40, 5);
    defer test_surface.deinit();
    try drawFileSearch(&test_surface.surface, &tree, &search, .default());
    const snapshot = try test_surface.snapshot(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "512+ matches; refine search") != null);
}

test "repository file search keeps a focused result visible in a short pane" {
    const allocator = std.testing.allocator;
    var manifest_document = try manifest.parseOwned(
        allocator,
        try allocator.dupe(u8, "file-0.zig\x00file-1.zig\x00file-2.zig\x00file-3.zig\x00file-4.zig\x00file-5.zig\x00"),
    );
    defer manifest_document.deinit(allocator);
    var tree = try repository_tree.Tree.build(allocator, &manifest_document);
    defer tree.deinit(allocator);
    var search: model.FileSearchState = .{ .mode = true, .len = 6, .focused = 5 };
    for (0..6) |index| search.matches[index] = index;
    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(24, 4);
    defer test_surface.deinit();
    try drawFileSearch(&test_surface.surface, &tree, &search, .default());
    const snapshot = try test_surface.snapshot(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "file-5.zig") != null);
    try std.testing.expectEqual(search.matches[5], search.selectedNode().?);
    const focused_cell = test_surface.surface.readCell(1, 3) orelse return error.ExpectedFocusedFile;
    try std.testing.expectEqual(theme.Palette.default().boldStyle(.prompt), focused_cell.style);
}
