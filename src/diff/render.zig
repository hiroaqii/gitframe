const std = @import("std");
const chasen = @import("chasen");
const draw = @import("draw");
const diff_file = @import("file.zig");
const diff_parser = @import("parser.zig");
const diff_view_model = @import("view_model.zig");

pub const DisplayMode = diff_view_model.DisplayMode;

pub const RenderOptions = struct {
    requested_mode: DisplayMode = .unified,
    scroll: usize = 0,
    horizontal_scroll: usize = 0,
    pane_active: bool = true,
    line_numbers: bool = true,
    highlighted_hunk: ?usize = null,
    cursor_offset: ?usize = null,
    staged_hunks: []const bool = &.{},
    line_index: ?diff_view_model.RenderedLineIndex = null,
    folded_hunks: []const bool = &.{},
};

pub const FileStats = diff_file.Stats;

pub fn effectiveMode(width: u16, requested_mode: DisplayMode) DisplayMode {
    if (requested_mode == .side_by_side and width < side_by_side_min_width) return .unified;
    return requested_mode;
}

pub fn modeLabel(width: u16, requested_mode: DisplayMode) []const u8 {
    const mode = effectiveMode(width, requested_mode);
    if (mode != requested_mode) return "unified (auto)";
    return mode.label();
}

pub fn fileStats(file: diff_parser.FileDiff) FileStats {
    return diff_file.stats(file);
}

pub fn displayPath(file: diff_parser.FileDiff) []const u8 {
    return diff_file.displayPath(file);
}

pub fn renderedBodyLineCount(file: diff_parser.FileDiff, mode: DisplayMode) usize {
    return diff_view_model.renderedBodyLineCount(file, mode);
}

pub fn hunkBodyLineOffset(file: diff_parser.FileDiff, mode: DisplayMode, hunk_index: usize) usize {
    return diff_view_model.hunkBodyLineOffset(file, mode, hunk_index);
}

pub fn visibleBodyRows(surface_height: u16) usize {
    return if (surface_height > body_start_row) surface_height - body_start_row else 0;
}

pub fn renderFile(surface: *chasen.Surface, file: diff_parser.FileDiff, options: RenderOptions) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    const mode = effectiveMode(size.width, options.requested_mode);
    try renderFileHeader(surface, file, options.requested_mode, options.pane_active);
    var body_surface = surface.child(.{
        .col = cursor_gutter_width,
        .row = 0,
        .width = size.width -| cursor_gutter_width,
        .height = size.height,
    });

    const line_index = if (options.line_index) |index|
        if (lineIndexMatchesFile(file, index, mode)) index else null
    else
        null;
    var cursor: BodyCursor = .{
        // initAt has already consumed the virtual rows before options.scroll.
        .scroll = if (line_index != null) 0 else options.scroll,
        .base_offset = if (line_index != null) options.scroll else 0,
        .height = size.height,
    };
    var rows = if (line_index) |index|
        diff_view_model.BodyRowIterator.initAtWithFolded(file, mode, index, options.scroll, options.folded_hunks)
    else
        diff_view_model.BodyRowIterator.initWithFolded(file, mode, options.folded_hunks);
    var current_hunk_staged = false;
    while (rows.next()) |body_row| {
        if (cursor.done()) return;
        const body_offset = cursor.bodyOffset();
        const row = cursor.nextRow() orelse continue;
        drawCursorMarker(surface, row, body_offset, options.cursor_offset);
        switch (body_row) {
            .metadata => |line| try draw.copyClippedTextAt(&body_surface, 0, row, line, style_metadata),
            .binary_marker => _ = body_surface.borrowTextAt(0, row, "Binary file", style_warning),
            .hunk_header => |hunk| {
                current_hunk_staged = hunk.hunk_index < options.staged_hunks.len and options.staged_hunks[hunk.hunk_index];
                try drawHunkHeaderRow(&body_surface, row, hunk, options.highlighted_hunk, mode, current_hunk_staged);
            },
            .unified_line => |line| try drawUnifiedLine(&body_surface, row, line, options.horizontal_scroll, options.line_numbers, current_hunk_staged),
            .side_by_side => |side_row| {
                const gutter_col = body_surface.size().width / 2;
                switch (side_row) {
                    .single => |line| try drawSideBySideSingle(&body_surface, row, line, gutter_col, options.horizontal_scroll, options.line_numbers, current_hunk_staged),
                    .paired => |pair| try drawSideBySidePair(&body_surface, row, pair.removed, pair.added, gutter_col, options.horizontal_scroll, options.line_numbers, current_hunk_staged),
                }
            },
        }
    }
}

pub fn renderGeneratedAddedFile(surface: *chasen.Surface, path: []const u8, lines: []const []const u8, truncated: bool, options: RenderOptions) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    const mode = effectiveMode(size.width, options.requested_mode);
    try renderGeneratedFileHeader(surface, path, lines.len, truncated, options.requested_mode, options.pane_active);

    var cursor: BodyCursor = .{
        .scroll = options.scroll,
        .height = size.height,
    };

    if (truncated) {
        const row = cursor.nextRow();
        if (row) |visible_row| try draw.copyClippedTextAt(surface, 0, visible_row, "File preview truncated", style_warning);
    }

    for (lines, 0..) |line_text, index| {
        if (cursor.done()) return;
        const row = cursor.nextRow() orelse continue;
        const line: diff_parser.DiffLine = .{
            .kind = .added,
            .text = line_text,
            .new_line = @intCast(index + 1),
        };
        if (mode == .side_by_side and size.width >= side_by_side_min_width) {
            const gutter_col = size.width / 2;
            try drawSideBySidePair(surface, row, null, line, gutter_col, options.horizontal_scroll, options.line_numbers, false);
        } else {
            try drawUnifiedLine(surface, row, line, options.horizontal_scroll, options.line_numbers, false);
        }
    }
}

fn lineIndexMatchesFile(file: diff_parser.FileDiff, index: diff_view_model.RenderedLineIndex, mode: DisplayMode) bool {
    return index.mode == mode and index.hunk_offsets.len == file.hunks.len;
}

fn renderFileHeader(
    surface: *chasen.Surface,
    file: diff_parser.FileDiff,
    requested_mode: DisplayMode,
    pane_active: bool,
) !void {
    const stats = fileStats(file);
    const summary = try std.fmt.allocPrint(surface.frameAllocator(), "{s}  +{d} -{d}  {d} hunks", .{
        modeLabel(surface.size().width, requested_mode),
        stats.added,
        stats.removed,
        file.hunks.len,
    });
    try drawHeaderLine(surface, displayPath(file), summary, pane_active);
}

fn renderGeneratedFileHeader(
    surface: *chasen.Surface,
    path: []const u8,
    added_lines: usize,
    truncated: bool,
    requested_mode: DisplayMode,
    pane_active: bool,
) !void {
    const suffix = if (truncated) "  truncated" else "";
    const summary = try std.fmt.allocPrint(surface.frameAllocator(), "{s}  +{d} -0  generated{s}", .{
        modeLabel(surface.size().width, requested_mode),
        added_lines,
        suffix,
    });
    try drawHeaderLine(surface, path, summary, pane_active);
}

fn drawHeaderLine(surface: *chasen.Surface, path: []const u8, summary: []const u8, pane_active: bool) !void {
    const size = surface.size();
    if (size.width == 0) return;

    const summary_width = chasen.text.displayWidth(summary);
    if (size.width > summary_width + 2) {
        const path_width: u16 = @intCast(size.width - summary_width - 2);
        var path_area = surface.child(.{ .col = 0, .row = 0, .width = path_width, .height = 1 });
        try draw.copyClippedTextAt(&path_area, 0, 0, path, fileHeaderStyle(pane_active));

        const summary_col: u16 = @intCast(size.width - summary_width);
        try draw.copyClippedTextAt(surface, summary_col, 0, summary, style_metadata);
        return;
    }

    try draw.copyClippedTextAt(surface, 0, 0, path, fileHeaderStyle(pane_active));
}

fn drawHunkHeader(surface: *chasen.Surface, row: u16, header: []const u8, style: chasen.TextStyle, mode: DisplayMode) !void {
    if (mode == .side_by_side and surface.size().width >= side_by_side_min_width) {
        const gutter_col = surface.size().width / 2;
        var old_column = surface.child(.{
            .col = 0,
            .row = row,
            .width = gutter_col,
            .height = 1,
        });
        try draw.copyClippedTextAt(&old_column, 0, 0, header, style);
        _ = surface.borrowTextAt(gutter_col, row, "│", style_metadata);
        return;
    }

    try draw.copyClippedTextAt(surface, 0, row, header, style);
}

fn drawHunkHeaderRow(
    surface: *chasen.Surface,
    row: u16,
    hunk: diff_view_model.HunkHeader,
    highlighted_hunk: ?usize,
    mode: DisplayMode,
    staged: bool,
) !void {
    const style = hunkHeaderStyle(highlighted_hunk != null and highlighted_hunk.? == hunk.hunk_index, staged);
    const marker = if (hunk.folded) "▸" else "▾";
    const header = try std.fmt.allocPrint(surface.frameAllocator(), "{s} @@ -{d},{d} +{d},{d} @@ {s}", .{
        marker,
        hunk.old_start,
        hunk.old_count,
        hunk.new_start,
        hunk.new_count,
        hunk.section,
    });
    try drawHunkHeader(surface, row, header, style, mode);
}

fn hunkHeaderStyle(highlighted: bool, staged: bool) chasen.TextStyle {
    if (highlighted) return style_selected_hunk;

    var style = style_hunk;
    if (staged) {
        style.dim = true;
        style.bg = .{ .index = 8 };
    }
    return style;
}

const body_start_row: u16 = 2;
const cursor_gutter_width: u16 = 1;

fn drawCursorMarker(surface: *chasen.Surface, row: u16, body_offset: usize, cursor_offset: ?usize) void {
    if (cursor_offset == null or cursor_offset.? != body_offset) return;
    _ = surface.borrowTextAt(0, row, "▌", style_cursor);
}

const BodyCursor = struct {
    scroll: usize,
    base_offset: usize = 0,
    virtual_row: usize = 0,
    row: u16 = body_start_row,
    height: u16,

    fn nextRow(self: *BodyCursor) ?u16 {
        defer self.virtual_row += 1;
        if (self.virtual_row < self.scroll) return null;
        if (self.row >= self.height) return null;
        const row = self.row;
        self.row += 1;
        return row;
    }

    fn done(self: BodyCursor) bool {
        return self.virtual_row >= self.scroll and self.row >= self.height;
    }

    fn bodyOffset(self: BodyCursor) usize {
        return self.base_offset + self.virtual_row;
    }
};

fn drawUnifiedLine(surface: *chasen.Surface, row: u16, line: diff_parser.DiffLine, horizontal_scroll: usize, line_numbers: bool, staged: bool) !void {
    const style = styleForLine(line.kind, staged);
    const prefix = prefixForLine(line.kind);
    const layout = lineLayout(line_numbers, .unified);

    if (line_numbers) {
        _ = try surface.copyTextAt(0, row, try lineNumberText(surface, line.old_line), lineNumberStyle(staged));
        _ = try surface.copyTextAt(5, row, try lineNumberText(surface, line.new_line), lineNumberStyle(staged));
    }
    _ = surface.borrowTextAt(layout.prefix_col, row, prefix, style);
    try copyScrolledTextAt(surface, layout.text_col, row, line.text, horizontal_scroll, style);
}

fn drawSideBySidePair(surface: *chasen.Surface, row: u16, removed: ?diff_parser.DiffLine, added: ?diff_parser.DiffLine, gutter_col: u16, horizontal_scroll: usize, line_numbers: bool, staged: bool) !void {
    var columns = sideBySideRowColumns(surface, row, gutter_col);
    if (removed) |line| try drawSideBySideOld(&columns.old, 0, line, horizontal_scroll, line_numbers, staged);
    if (added) |line| try drawSideBySideNew(&columns.new, 0, line, horizontal_scroll, line_numbers, staged);
    drawSideBySideGutter(surface, row, gutter_col);
}

fn drawSideBySideSingle(surface: *chasen.Surface, row: u16, line: diff_parser.DiffLine, gutter_col: u16, horizontal_scroll: usize, line_numbers: bool, staged: bool) !void {
    var columns = sideBySideRowColumns(surface, row, gutter_col);
    switch (line.kind) {
        .removed => {
            try drawSideBySideOld(&columns.old, 0, line, horizontal_scroll, line_numbers, staged);
            drawSideBySideGutter(surface, row, gutter_col);
        },
        .added => {
            try drawSideBySideNew(&columns.new, 0, line, horizontal_scroll, line_numbers, staged);
            drawSideBySideGutter(surface, row, gutter_col);
        },
        .context => {
            try drawSideBySideOld(&columns.old, 0, line, horizontal_scroll, line_numbers, staged);
            try drawSideBySideNew(&columns.new, 0, line, horizontal_scroll, line_numbers, staged);
            drawSideBySideGutter(surface, row, gutter_col);
        },
        .metadata => {
            try draw.copyClippedTextAt(surface, 0, row, line.text, style_metadata);
        },
    }
}

fn drawSideBySideGutter(surface: *chasen.Surface, row: u16, gutter_col: u16) void {
    _ = surface.borrowTextAt(gutter_col, row, "│", style_metadata);
}

const SideBySideColumns = struct {
    old: chasen.Surface,
    new: chasen.Surface,
};

fn sideBySideRowColumns(surface: *chasen.Surface, row: u16, gutter_col: u16) SideBySideColumns {
    const size = surface.size();
    const new_col = gutter_col + 1;
    return .{
        .old = surface.child(.{
            .col = 0,
            .row = row,
            .width = gutter_col,
            .height = 1,
        }),
        .new = surface.child(.{
            .col = new_col,
            .row = row,
            .width = if (size.width > new_col) size.width - new_col else 0,
            .height = 1,
        }),
    };
}

fn drawSideBySideOld(surface: *chasen.Surface, row: u16, line: diff_parser.DiffLine, horizontal_scroll: usize, line_numbers: bool, staged: bool) !void {
    const layout = lineLayout(line_numbers, .side_by_side);
    if (line_numbers) {
        _ = try surface.copyTextAt(0, row, try lineNumberText(surface, line.old_line), lineNumberStyle(staged));
    }
    const prefix = if (line.kind == .removed) "-" else " ";
    const style = styleForLine(line.kind, staged);
    _ = surface.borrowTextAt(layout.prefix_col, row, prefix, style);
    try copyScrolledTextAt(surface, layout.text_col, row, line.text, horizontal_scroll, style);
}

fn drawSideBySideNew(surface: *chasen.Surface, row: u16, line: diff_parser.DiffLine, horizontal_scroll: usize, line_numbers: bool, staged: bool) !void {
    const layout = lineLayout(line_numbers, .side_by_side);
    if (line_numbers) {
        _ = try surface.copyTextAt(0, row, try lineNumberText(surface, line.new_line), lineNumberStyle(staged));
    }
    const prefix = if (line.kind == .added) "+" else " ";
    const style = styleForLine(line.kind, staged);
    _ = surface.borrowTextAt(layout.prefix_col, row, prefix, style);
    try copyScrolledTextAt(surface, layout.text_col, row, line.text, horizontal_scroll, style);
}

pub const LineLayoutMode = enum {
    unified,
    side_by_side,
};

const LineLayout = struct {
    prefix_col: u16,
    text_col: u16,
};

pub fn lineTextStart(line_numbers: bool, mode: LineLayoutMode) u16 {
    return lineLayout(line_numbers, mode).text_col;
}

fn lineLayout(line_numbers: bool, mode: LineLayoutMode) LineLayout {
    if (!line_numbers) return .{ .prefix_col = 0, .text_col = 2 };
    return switch (mode) {
        .unified => .{ .prefix_col = 10, .text_col = 12 },
        .side_by_side => .{ .prefix_col = 5, .text_col = 7 },
    };
}

fn copyScrolledTextAt(surface: *chasen.Surface, col: u16, row: u16, text: []const u8, horizontal_scroll: usize, style: chasen.TextStyle) !void {
    const scrolled = chasen.text.dropToWidth(text, horizontal_scroll);
    try copyPlainClippedTextAt(surface, col, row, scrolled, style);
}

// Scrollable diff body text should not draw an artificial ellipsis; users can
// move horizontally to inspect the clipped suffix.
fn copyPlainClippedTextAt(surface: *chasen.Surface, col: u16, row: u16, text: []const u8, style: chasen.TextStyle) !void {
    const size = surface.size();
    if (col >= size.width) return;
    const max_width = size.width - col;
    const clipped = chasen.text.clipToWidth(text, max_width);
    if (clipped.len == 0) return;
    _ = try surface.copyTextAt(col, row, clipped, style);
}

fn lineNumberText(surface: *chasen.Surface, line: ?u32) ![]const u8 {
    return if (line) |n|
        std.fmt.allocPrint(surface.frameAllocator(), "{d: >4}", .{n})
    else
        surface.copyText("    ");
}

fn styleForLine(kind: diff_parser.DiffLine.Kind, staged: bool) chasen.TextStyle {
    var style = switch (kind) {
        .added => style_added,
        .removed => style_removed,
        .context => style_context,
        .metadata => style_metadata,
    };
    if (staged) style.dim = true;
    return style;
}

fn lineNumberStyle(staged: bool) chasen.TextStyle {
    var style = style_line_number;
    if (staged) style.dim = true;
    return style;
}

fn fileHeaderStyle(pane_active: bool) chasen.TextStyle {
    var style = style_file_header;
    style.dim = !pane_active;
    return style;
}

fn prefixForLine(kind: diff_parser.DiffLine.Kind) []const u8 {
    return switch (kind) {
        .added => "+",
        .removed => "-",
        .context => " ",
        .metadata => "\\",
    };
}

const side_by_side_min_width: u16 = 72;

const style_file_header: chasen.TextStyle = .{ .bold = true, .fg = .{ .index = 11 } };
const style_hunk: chasen.TextStyle = .{ .bold = true, .fg = .{ .index = 14 } };
const style_selected_hunk: chasen.TextStyle = .{ .bold = true, .reverse = true, .fg = .{ .index = 14 } };
const style_cursor: chasen.TextStyle = .{ .bold = true, .fg = .{ .index = 11 } };
const style_added: chasen.TextStyle = .{ .fg = .{ .index = 2 } };
const style_removed: chasen.TextStyle = .{ .fg = .{ .index = 9 } };
const style_context: chasen.TextStyle = .{};
const style_metadata: chasen.TextStyle = .{ .fg = .gray };
const style_line_number: chasen.TextStyle = .{ .fg = .gray };
const style_warning: chasen.TextStyle = .{ .fg = .{ .index = 11 } };

test "display mode falls back to unified on narrow panes" {
    try std.testing.expectEqual(DisplayMode.unified, effectiveMode(40, .side_by_side));
    try std.testing.expectEqual(DisplayMode.side_by_side, effectiveMode(90, .side_by_side));
    try std.testing.expectEqual(DisplayMode.unified, effectiveMode(90, .unified));

    try std.testing.expectEqualStrings("unified (auto)", modeLabel(40, .side_by_side));
    try std.testing.expectEqualStrings("side-by-side", modeLabel(90, .side_by_side));
}

test "fileStats counts added and removed hunk lines" {
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/a b/a",
        .metadata = &.{},
        .hunks = &.{
            .{
                .old_start = 1,
                .old_count = 2,
                .new_start = 1,
                .new_count = 2,
                .section = "",
                .lines = &.{
                    .{ .kind = .removed, .text = "old", .old_line = 1 },
                    .{ .kind = .added, .text = "new", .new_line = 1 },
                    .{ .kind = .context, .text = "same", .old_line = 2, .new_line = 2 },
                },
            },
        },
    };

    try std.testing.expectEqual(FileStats{ .added = 1, .removed = 1 }, fileStats(file));
}

test "renderFile dims staged hunk body without removing it" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 6);
    defer ts.deinit();

    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/src/main.zig b/src/main.zig",
        .old_path = "a/src/main.zig",
        .new_path = "b/src/main.zig",
        .metadata = &.{},
        .hunks = &.{
            .{
                .old_start = 1,
                .old_count = 1,
                .new_start = 1,
                .new_count = 1,
                .section = "",
                .lines = &.{
                    .{ .kind = .removed, .text = "old", .old_line = 1 },
                    .{ .kind = .added, .text = "new", .new_line = 1 },
                },
            },
        },
    };

    try renderFile(&ts.surface, file, .{
        .requested_mode = .unified,
        .staged_hunks = &.{true},
    });

    const header_cell = ts.surface.readCell(1, 2).?;
    try std.testing.expect(header_cell.style.bg.eql(.{ .index = 8 }));
    try ts.expectCellText(13, 3, "o");
    const old_cell = ts.surface.readCell(13, 3).?;
    try std.testing.expect(old_cell.style.dim);
    try ts.expectCellText(13, 4, "n");
    const new_cell = ts.surface.readCell(13, 4).?;
    try std.testing.expect(new_cell.style.dim);
}

test "hunkHeaderStyle lets highlighted state win over staged background" {
    const style = hunkHeaderStyle(true, true);

    try std.testing.expect(style.reverse);
    try std.testing.expect(!style.dim);
    try std.testing.expect(style.bg.eql(.default));
}

test "displayPath prefers new path and strips git prefixes" {
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/src/main.zig b/src/main.zig",
        .old_path = "a/src/main.zig",
        .new_path = "b/src/main.zig",
        .metadata = &.{},
        .hunks = &.{},
    };

    try std.testing.expectEqualStrings("src/main.zig", displayPath(file));
}

test "renderGeneratedAddedFile draws content on new side in side-by-side mode" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(90, 6);
    defer ts.deinit();

    try renderGeneratedAddedFile(&ts.surface, "src/new.zig", &.{ "const value = 1;", "pub fn main() void {}" }, false, .{ .requested_mode = .side_by_side });

    try ts.expectCellText(0, 0, "s");
    try ts.expectCellText(45, 2, "│");
    try ts.expectCellText(51, 2, "+");
    try ts.expectCellText(53, 2, "c");
}

test "narrow side-by-side request labels file header as automatic unified fallback" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(50, 4);
    defer ts.deinit();

    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/src/main.zig b/src/main.zig",
        .old_path = "a/src/main.zig",
        .new_path = "b/src/main.zig",
        .metadata = &.{},
        .hunks = &.{
            .{
                .old_start = 1,
                .old_count = 1,
                .new_start = 1,
                .new_count = 1,
                .section = "",
                .lines = &.{
                    .{ .kind = .removed, .text = "old", .old_line = 1 },
                    .{ .kind = .added, .text = "new", .new_line = 1 },
                },
            },
        },
    };

    try renderFile(&ts.surface, file, .{ .requested_mode = .side_by_side });

    try ts.expectCellText(20, 0, "u");
    try ts.expectCellText(28, 0, "(");
    try ts.expectCellText(29, 0, "a");
}

test "side-by-side clips old column before new column" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 5);
    defer ts.deinit();

    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/src/main.zig b/src/main.zig",
        .old_path = "a/src/main.zig",
        .new_path = "b/src/main.zig",
        .metadata = &.{},
        .hunks = &.{
            .{
                .old_start = 1,
                .old_count = 1,
                .new_start = 1,
                .new_count = 1,
                .section = "",
                .lines = &.{
                    .{
                        .kind = .removed,
                        .text = "old text that is intentionally much longer than the left side-by-side column",
                        .old_line = 1,
                    },
                    .{
                        .kind = .added,
                        .text = "new",
                        .new_line = 1,
                    },
                },
            },
        },
    };

    try renderFile(&ts.surface, file, .{ .requested_mode = .side_by_side });

    const gutter_col: u16 = 40;
    try ts.expectCellText(gutter_col, 3, "│");
    try ts.expectCellText(gutter_col + 8, 3, "n");
    try ts.expectCellText(gutter_col + 9, 3, "e");
    try ts.expectCellText(gutter_col + 10, 3, "w");
    try ts.expectCellText(gutter_col + 12, 3, " ");
}

test "side-by-side hunk header is clipped before the new column" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 5);
    defer ts.deinit();

    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/src/main.zig b/src/main.zig",
        .old_path = "a/src/main.zig",
        .new_path = "b/src/main.zig",
        .metadata = &.{},
        .hunks = &.{
            .{
                .old_start = 102,
                .old_count = 36,
                .new_start = 134,
                .new_count = 67,
                .section = "fn renderFileHeader(surface: *chasen.Surface, file: diff_parser.FileDiff, mode: DisplayMode) !void",
                .lines = &.{},
            },
        },
    };

    try renderFile(&ts.surface, file, .{ .requested_mode = .side_by_side });

    const gutter_col: u16 = 40;
    try ts.expectCellText(3, 2, "@");
    try ts.expectCellText(4, 2, "@");
    try ts.expectCellText(gutter_col, 2, "│");
    try ts.expectCellText(gutter_col + 1, 2, " ");
    try ts.expectCellText(gutter_col + 8, 2, " ");
}

test "marked clipping shows ellipsis in fixed metadata rows" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(16, 5);
    defer ts.deinit();

    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/very-long-file-name.zig b/very-long-file-name.zig",
        .old_path = "a/very-long-file-name.zig",
        .new_path = "b/very-long-file-name.zig",
        .metadata = &.{},
        .hunks = &.{},
    };

    try renderFile(&ts.surface, file, .{});

    try ts.expectCellText(15, 0, "…");
}

test "unified horizontal scroll keeps line numbers and prefix fixed" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(32, 5);
    defer ts.deinit();

    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/src/main.zig b/src/main.zig",
        .old_path = "a/src/main.zig",
        .new_path = "b/src/main.zig",
        .metadata = &.{},
        .hunks = &.{
            .{
                .old_start = 1,
                .old_count = 1,
                .new_start = 1,
                .new_count = 1,
                .section = "",
                .lines = &.{
                    .{ .kind = .context, .text = "0123456789abcdefghijklmnopqrstuvwxyz", .old_line = 1, .new_line = 1 },
                },
            },
        },
    };

    try renderFile(&ts.surface, file, .{ .requested_mode = .unified, .horizontal_scroll = 4 });

    try ts.expectCellText(0, 3, " ");
    try ts.expectCellText(4, 3, "1");
    try ts.expectCellText(9, 3, "1");
    try ts.expectCellText(11, 3, " ");
    try ts.expectCellText(13, 3, "4");
    try ts.expectCellText(14, 3, "5");
    try ts.expectCellText(31, 3, "m");
}

test "unified line numbers can be hidden while keeping prefix" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(32, 5);
    defer ts.deinit();

    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/src/main.zig b/src/main.zig",
        .old_path = "a/src/main.zig",
        .new_path = "b/src/main.zig",
        .metadata = &.{},
        .hunks = &.{
            .{
                .old_start = 1,
                .old_count = 1,
                .new_start = 1,
                .new_count = 1,
                .section = "",
                .lines = &.{
                    .{ .kind = .added, .text = "new line", .new_line = 1 },
                },
            },
        },
    };

    try renderFile(&ts.surface, file, .{ .requested_mode = .unified, .line_numbers = false });

    try ts.expectCellText(1, 3, "+");
    try ts.expectCellText(3, 3, "n");
    try ts.expectCellText(4, 3, "e");
    try ts.expectCellText(5, 3, "w");
}

test "inactive pane dims file header only" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(40, 5);
    defer ts.deinit();

    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/src/main.zig b/src/main.zig",
        .old_path = "a/src/main.zig",
        .new_path = "b/src/main.zig",
        .metadata = &.{},
        .hunks = &.{},
    };

    try renderFile(&ts.surface, file, .{ .pane_active = false });

    try ts.expectCellText(0, 0, "s");
    try std.testing.expect(ts.surface.readCell(0, 0).?.style.dim);
    try ts.expectCellText(17, 0, "u");
    try std.testing.expect(!ts.surface.readCell(17, 0).?.style.dim);
}

test "side-by-side horizontal scroll keeps gutter fixed" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 5);
    defer ts.deinit();

    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/src/main.zig b/src/main.zig",
        .old_path = "a/src/main.zig",
        .new_path = "b/src/main.zig",
        .metadata = &.{},
        .hunks = &.{
            .{
                .old_start = 1,
                .old_count = 1,
                .new_start = 1,
                .new_count = 1,
                .section = "",
                .lines = &.{
                    .{ .kind = .removed, .text = "old-012345", .old_line = 1 },
                    .{ .kind = .added, .text = "new-abcdef", .new_line = 1 },
                },
            },
        },
    };

    try renderFile(&ts.surface, file, .{ .requested_mode = .side_by_side, .horizontal_scroll = 4 });

    try ts.expectCellText(8, 3, "0");
    try ts.expectCellText(40, 3, "│");
    try ts.expectCellText(48, 3, "a");
}

test "side-by-side line numbers can be hidden while keeping prefixes" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 5);
    defer ts.deinit();

    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/src/main.zig b/src/main.zig",
        .old_path = "a/src/main.zig",
        .new_path = "b/src/main.zig",
        .metadata = &.{},
        .hunks = &.{
            .{
                .old_start = 1,
                .old_count = 1,
                .new_start = 1,
                .new_count = 1,
                .section = "",
                .lines = &.{
                    .{ .kind = .removed, .text = "old", .old_line = 1 },
                    .{ .kind = .added, .text = "new", .new_line = 1 },
                },
            },
        },
    };

    try renderFile(&ts.surface, file, .{ .requested_mode = .side_by_side, .line_numbers = false });

    try ts.expectCellText(1, 3, "-");
    try ts.expectCellText(3, 3, "o");
    try ts.expectCellText(40, 3, "│");
    try ts.expectCellText(41, 3, "+");
    try ts.expectCellText(43, 3, "n");
}

test "renderFile can start from cached viewport offset" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 5);
    defer ts.deinit();

    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/src/main.zig b/src/main.zig",
        .old_path = "a/src/main.zig",
        .new_path = "b/src/main.zig",
        .metadata = &.{ "--- a/src/main.zig", "+++ b/src/main.zig" },
        .hunks = &.{
            .{
                .old_start = 1,
                .old_count = 1,
                .new_start = 1,
                .new_count = 1,
                .section = "first",
                .lines = &.{
                    .{ .kind = .removed, .text = "old", .old_line = 1 },
                    .{ .kind = .added, .text = "new", .new_line = 1 },
                },
            },
            .{
                .old_start = 9,
                .old_count = 1,
                .new_start = 9,
                .new_count = 1,
                .section = "second",
                .lines = &.{
                    .{ .kind = .context, .text = "same", .old_line = 9, .new_line = 9 },
                },
            },
        },
    };

    var index = try diff_view_model.RenderedLineIndex.build(std.testing.allocator, file, .unified);
    defer index.deinit(std.testing.allocator);

    try renderFile(&ts.surface, file, .{
        .requested_mode = .unified,
        .scroll = index.hunkOffset(1),
        .line_index = index,
    });

    try ts.expectCellText(3, 2, "@");
    try ts.expectCellText(4, 2, "@");
    try ts.expectCellText(13, 3, "s");
    try ts.expectCellText(14, 3, "a");
    try ts.expectCellText(15, 3, "m");
    try ts.expectCellText(16, 3, "e");
}

test "renderFile cursor marker uses absolute body offset with cached viewport" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 5);
    defer ts.deinit();

    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/src/main.zig b/src/main.zig",
        .old_path = "a/src/main.zig",
        .new_path = "b/src/main.zig",
        .metadata = &.{ "--- a/src/main.zig", "+++ b/src/main.zig" },
        .hunks = &.{
            .{
                .old_start = 1,
                .old_count = 1,
                .new_start = 1,
                .new_count = 1,
                .section = "first",
                .lines = &.{.{ .kind = .context, .text = "same", .old_line = 1, .new_line = 1 }},
            },
            .{
                .old_start = 9,
                .old_count = 1,
                .new_start = 9,
                .new_count = 1,
                .section = "second",
                .lines = &.{.{ .kind = .context, .text = "later", .old_line = 9, .new_line = 9 }},
            },
        },
    };

    var index = try diff_view_model.RenderedLineIndex.build(std.testing.allocator, file, .unified);
    defer index.deinit(std.testing.allocator);

    try renderFile(&ts.surface, file, .{
        .requested_mode = .unified,
        .scroll = index.hunkOffset(1),
        .cursor_offset = index.hunkOffset(1) + 1,
        .line_index = index,
    });

    try ts.expectCellText(0, 2, " ");
    try ts.expectCellText(0, 3, "▌");
}

test "renderFile can start from cached side-by-side viewport offset" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 5);
    defer ts.deinit();

    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/src/main.zig b/src/main.zig",
        .old_path = "a/src/main.zig",
        .new_path = "b/src/main.zig",
        .metadata = &.{},
        .hunks = &.{
            .{
                .old_start = 1,
                .old_count = 2,
                .new_start = 1,
                .new_count = 2,
                .section = "",
                .lines = &.{
                    .{ .kind = .removed, .text = "old one", .old_line = 1 },
                    .{ .kind = .removed, .text = "old two", .old_line = 2 },
                    .{ .kind = .added, .text = "new one", .new_line = 1 },
                    .{ .kind = .added, .text = "new two", .new_line = 2 },
                },
            },
        },
    };

    var index = try diff_view_model.RenderedLineIndex.build(std.testing.allocator, file, .side_by_side);
    defer index.deinit(std.testing.allocator);

    try renderFile(&ts.surface, file, .{
        .requested_mode = .side_by_side,
        .scroll = index.hunkOffset(0) + 2,
        .line_index = index,
    });

    try ts.expectCellText(8, 2, "o");
    try ts.expectCellText(9, 2, "l");
    try ts.expectCellText(10, 2, "d");
    try ts.expectCellText(40, 2, "│");
    try ts.expectCellText(48, 2, "n");
    try ts.expectCellText(49, 2, "e");
    try ts.expectCellText(50, 2, "w");
}
