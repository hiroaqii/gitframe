//! Repository source-pane rendering over page-owned source coordinates.

const std = @import("std");
const chasen = @import("chasen");
const draw = @import("draw");
const theme = @import("theme");
const model = @import("model.zig");
const navigation = @import("navigation.zig");
const source = @import("../../../repository/source.zig");
const manifest = @import("../../../repository/manifest.zig");
const repository_tree = @import("../../../repository/tree.zig");

pub fn sourceTextWidth(width: u16, document: *const source.Document, line_numbers: bool) u16 {
    const number_columns: usize = if (line_numbers) decimalDigits(document.rowCount()) + 1 else 0;
    return width -| @as(u16, @intCast(1 + number_columns));
}

pub fn drawSource(
    surface: *chasen.Surface,
    document: *const source.Document,
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
            palette.style(.muted);

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

    try drawSource(&test_surface.surface, &document, .{ .focus = .source }, .{}, .default());
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
    try drawSource(&test_surface.surface, &document, .{ .focus = .source }, .{}, .default());
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

    try drawSource(&test_surface.surface, &document, .{ .focus = .source }, .{}, .default());
    var snapshot = try test_surface.snapshot(allocator);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "/needle") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "1 first") != null);
    allocator.free(snapshot);

    test_surface.deinit();
    try test_surface.init(32, 6);
    var search: model.SourceSearchState = .{ .mode = true };
    try search.input.insertSlice("needle");
    try drawSource(&test_surface.surface, &document, .{ .focus = .source }, search, .default());
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
    try drawSource(&test_surface.surface, &document, .{ .focus = .source, .source_cursor = 0 }, search, palette);
    const match_cell = test_surface.surface.readCell(7, 2) orelse return error.ExpectedMatchCell;
    const plain_cell = test_surface.surface.readCell(3, 2) orelse return error.ExpectedPlainCell;
    try std.testing.expectEqual(palette.boldStyle(.warning), match_cell.style);
    try std.testing.expectEqual(palette.boldStyle(.prompt), plain_cell.style);
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
