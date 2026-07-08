const std = @import("std");
const chasen = @import("chasen");
const draw = @import("draw");
const diff_file = @import("file.zig");
const diff_parser = @import("parser.zig");
const diff_selection = @import("selection.zig");
const diff_view_model = @import("view_model.zig");
const syntax_provider = @import("../syntax/provider.zig");
const theme = @import("theme");

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
    palette: theme.Palette = .default(),
    file_index: usize = 0,
    syntax_spans: syntax_provider.DocumentSpans = .empty(),
    selection: ?diff_selection.View = null,
    header_selection: bool = false,
};

pub const SideBySideRegion = struct {
    col: u16,
    width: u16,

    pub fn contains(self: SideBySideRegion, col: u16) bool {
        return col >= self.col and col < self.col + self.width;
    }
};

pub const SideBySideGeometry = struct {
    old: SideBySideRegion,
    separator_col: u16,
    new: SideBySideRegion,

    pub fn sideAt(self: SideBySideGeometry, col: u16) ?diff_selection.Side {
        if (self.old.contains(col)) return .old;
        if (self.new.contains(col)) return .new;
        return null;
    }
};

pub const FileStats = diff_file.Stats;

pub const HeaderRegion = struct {
    col: u16,
    width: u16,

    pub fn contains(self: HeaderRegion, col: u16) bool {
        return col >= self.col and col < self.col + self.width;
    }
};

pub const HeaderLayout = struct {
    path_target: ?HeaderRegion = null,
    stats: ?HeaderRegion = null,
    mode: ?HeaderRegion = null,
};

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

pub const HeaderStats = struct {
    added: usize,
    removed: usize,
    detail_width: usize,
};

pub fn fileHeaderLayout(width: u16, path: []const u8, file: diff_parser.FileDiff, requested_mode: DisplayMode, mode_width: u16) HeaderLayout {
    const stats = fileStats(file);
    return headerLayout(width, path, .{
        .added = stats.added,
        .removed = stats.removed,
        .detail_width = std.fmt.count("{d} hunks", .{file.hunks.len}),
    }, modeLabel(mode_width, requested_mode));
}

pub fn generatedHeaderLayout(width: u16, path: []const u8, added_lines: usize, truncated: bool, requested_mode: DisplayMode, mode_width: u16) HeaderLayout {
    const detail = if (truncated) "generated truncated" else "generated";
    return headerLayout(width, path, .{
        .added = added_lines,
        .removed = 0,
        .detail_width = chasen.text.displayWidth(detail),
    }, modeLabel(mode_width, requested_mode));
}

fn headerStatsWidth(stats: HeaderStats) u16 {
    const len = std.fmt.count("+{d} -{d} ", .{
        stats.added,
        stats.removed,
    }) + stats.detail_width;
    return @intCast(@min(len, std.math.maxInt(u16)));
}

fn modeLabelWidth(label: []const u8) u16 {
    const len = chasen.text.displayWidth(label);
    return @intCast(@min(len, std.math.maxInt(u16)));
}

pub fn headerLayout(width: u16, path: []const u8, stats: ?HeaderStats, mode_label: []const u8) HeaderLayout {
    if (width == 0) return .{};

    const right_padding: u16 = 1;
    const mode_width = modeLabelWidth(mode_label);
    var layout: HeaderLayout = .{};

    const stats_width = if (stats) |value| headerStatsWidth(value) else 0;
    const min_path_width: u16 = 8;
    if (stats_width > 0 and width > stats_width + 1 + min_path_width) {
        const path_area_width: u16 = @intCast(width - stats_width - 1);
        const path_region = visibleTailClippedPathRegion(0, path_area_width, path);
        if (path_region) |region| {
            layout.path_target = region;
        }

        const visible_path_width = if (path_region) |region| region.width else path_area_width;
        const stats_col: u16 = @intCast(visible_path_width + 1);
        layout.stats = .{ .col = stats_col, .width = stats_width };
        if (mode_width > 0 and width > mode_width + right_padding) {
            const mode_col: u16 = @intCast(width - mode_width - right_padding);
            const stats_end: u16 = @intCast(stats_col + stats_width);
            if (mode_col > stats_end + 1) {
                layout.mode = .{ .col = mode_col, .width = mode_width };
            }
        }
        return layout;
    }

    if (stats_width == 0 and mode_width > 0 and width > mode_width + 2 + right_padding) {
        const mode_col: u16 = @intCast(width - mode_width - right_padding);
        layout.mode = .{ .col = mode_col, .width = mode_width };
        layout.path_target = visibleTailClippedPathRegion(0, mode_col - 2, path);
        return layout;
    }

    layout.path_target = visibleTailClippedPathRegion(0, width, path);
    return layout;
}

fn visibleTailClippedPathRegion(col: u16, available_width: u16, path: []const u8) ?HeaderRegion {
    if (available_width == 0 or path.len == 0) return null;
    const path_width = chasen.text.displayWidth(path);
    if (path_width == 0) return null;
    if (path_width <= available_width) {
        return .{ .col = col, .width = @intCast(path_width) };
    }

    const marker_width: u16 = 2;
    if (available_width <= marker_width) {
        return .{ .col = col, .width = available_width };
    }
    return .{ .col = col, .width = available_width };
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

pub fn bodyWidth(render_surface_width: u16) u16 {
    return render_surface_width -| cursor_gutter_width;
}

pub fn sideBySideGeometry(width: u16) SideBySideGeometry {
    const gutter_col = width / 2;
    const new_col = gutter_col + 1;
    return .{
        .old = .{ .col = 0, .width = gutter_col },
        .separator_col = gutter_col,
        .new = .{ .col = new_col, .width = if (width > new_col) width - new_col else 0 },
    };
}

pub fn renderFile(surface: *chasen.Surface, file: diff_parser.FileDiff, options: RenderOptions) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    const styles = stylesForOptions(options);
    const content_width = bodyWidth(size.width);
    const mode = effectiveMode(content_width, options.requested_mode);
    try renderFileHeader(surface, file, options.requested_mode, content_width, options.pane_active, options.header_selection, styles);
    var body_surface = surface.child(.{
        .col = cursor_gutter_width,
        .row = 0,
        .width = content_width,
        .height = size.height,
    });

    const line_index = if (options.line_index) |index|
        if (lineIndexMatchesFile(file, index, mode)) index else null
    else
        null;
    const guide_index = line_index orelse diff_view_model.RenderedLineIndex.buildFolded(surface.frameAllocator(), file, mode, options.folded_hunks) catch null;
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
    var current_hunk_highlighted = false;
    while (rows.next()) |body_row| {
        if (cursor.done()) return;
        if (rows.currentHunkIndex()) |hunk_index| {
            current_hunk_staged = hunk_index < options.staged_hunks.len and options.staged_hunks[hunk_index];
            current_hunk_highlighted = options.highlighted_hunk != null and options.highlighted_hunk.? == hunk_index;
        } else {
            current_hunk_staged = false;
            current_hunk_highlighted = false;
        }
        const body_offset = cursor.bodyOffset();
        const row = cursor.nextRow() orelse continue;
        drawCursorMarker(surface, row, body_offset, options.cursor_offset, styles);
        switch (body_row) {
            .metadata => |line| try draw.copyClippedTextAt(&body_surface, 0, row, line, styles.metadata),
            .binary_marker => _ = body_surface.borrowTextAt(0, row, "Binary file", styles.warning),
            .hunk_header => |hunk| {
                if (current_hunk_highlighted and !hunk.folded) drawHunkGuide(surface, row, guideGlyph(guide_index, hunk.hunk_index, body_offset), styles);
                try drawHunkHeaderRow(&body_surface, row, hunk, options.highlighted_hunk, mode, current_hunk_staged, styles);
            },
            .unified_line => |line| {
                if (current_hunk_highlighted) {
                    if (rows.currentHunkIndex()) |hunk_index| drawHunkGuide(surface, row, guideGlyph(guide_index, hunk_index, body_offset), styles);
                }
                const syntax_ctx = unifiedSyntaxContext(options, rows, line);
                try drawUnifiedLine(&body_surface, row, line, options.horizontal_scroll, options.line_numbers, current_hunk_staged, styles, syntax_ctx.line_spans, syntax_ctx.hunk_side_has_visible_syntax);
            },
            .side_by_side => |side_row| {
                if (current_hunk_highlighted) {
                    if (rows.currentHunkIndex()) |hunk_index| drawHunkGuide(surface, row, guideGlyph(guide_index, hunk_index, body_offset), styles);
                }
                const geometry = sideBySideGeometry(body_surface.size().width);
                const indexed_row = rows.currentSideBySideRow();
                switch (side_row) {
                    .single => |line| try drawSideBySideSingle(&body_surface, row, line, geometry, options.horizontal_scroll, options.line_numbers, current_hunk_staged, styles, sideBySideSingleSyntaxSpans(options, rows, line), sideBySideSelectionForIndexedRow(options, file, rows.currentHunkIndex(), indexed_row)),
                    .paired => |pair| try drawSideBySidePair(&body_surface, row, pair.removed, pair.added, geometry, options.horizontal_scroll, options.line_numbers, current_hunk_staged, styles, sideBySidePairSyntaxSpans(options, rows), sideBySideSelectionForIndexedRow(options, file, rows.currentHunkIndex(), indexed_row)),
                }
            },
        }
    }
}

pub fn renderGeneratedAddedFile(surface: *chasen.Surface, path: []const u8, lines: []const []const u8, truncated: bool, options: RenderOptions) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    const styles = stylesForOptions(options);
    const content_width = bodyWidth(size.width);
    const mode = effectiveMode(content_width, options.requested_mode);
    try renderGeneratedFileHeader(surface, path, lines.len, truncated, options.requested_mode, content_width, options.pane_active, options.header_selection, styles);
    var body_surface = surface.child(.{
        .col = cursor_gutter_width,
        .row = 0,
        .width = content_width,
        .height = size.height,
    });

    var cursor: BodyCursor = .{
        .scroll = options.scroll,
        .height = size.height,
    };

    if (truncated) {
        const body_offset = cursor.bodyOffset();
        const row = cursor.nextRow();
        if (row) |visible_row| {
            drawCursorMarker(surface, visible_row, body_offset, options.cursor_offset, styles);
            try draw.copyClippedTextAt(&body_surface, 0, visible_row, "File preview truncated", styles.warning);
        }
    }

    for (lines, 0..) |line_text, index| {
        if (cursor.done()) return;
        const body_offset = cursor.bodyOffset();
        const row = cursor.nextRow() orelse continue;
        drawCursorMarker(surface, row, body_offset, options.cursor_offset, styles);
        const line: diff_parser.DiffLine = .{
            .kind = .added,
            .text = line_text,
            .new_line = @intCast(index + 1),
        };
        if (mode == .side_by_side) {
            const geometry = sideBySideGeometry(body_surface.size().width);
            try drawSideBySidePair(&body_surface, row, null, line, geometry, options.horizontal_scroll, options.line_numbers, false, styles, .{}, null);
        } else {
            try drawUnifiedLine(&body_surface, row, line, options.horizontal_scroll, options.line_numbers, false, styles, .empty(), false);
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
    mode_width: u16,
    pane_active: bool,
    header_selected: bool,
    styles: RenderStyles,
) !void {
    const stats = fileStats(file);
    const detail = try std.fmt.allocPrint(surface.frameAllocator(), "{d} hunks", .{file.hunks.len});
    try drawHeaderLine(surface, displayPath(file), .{
        .added = stats.added,
        .removed = stats.removed,
        .detail = detail,
    }, modeLabel(mode_width, requested_mode), pane_active, header_selected, styles);
}

fn renderGeneratedFileHeader(
    surface: *chasen.Surface,
    path: []const u8,
    added_lines: usize,
    truncated: bool,
    requested_mode: DisplayMode,
    mode_width: u16,
    pane_active: bool,
    header_selected: bool,
    styles: RenderStyles,
) !void {
    const detail = if (truncated) "generated truncated" else "generated";
    try drawHeaderLine(surface, path, .{
        .added = added_lines,
        .removed = 0,
        .detail = detail,
    }, modeLabel(mode_width, requested_mode), pane_active, header_selected, styles);
}

const HeaderStatsText = struct {
    added: usize,
    removed: usize,
    detail: []const u8,
};

fn drawHeaderLine(surface: *chasen.Surface, path: []const u8, stats: HeaderStatsText, mode_label: []const u8, pane_active: bool, header_selected: bool, styles: RenderStyles) !void {
    const size = surface.size();
    if (size.width == 0) return;

    const layout = headerLayout(size.width, path, .{
        .added = stats.added,
        .removed = stats.removed,
        .detail_width = chasen.text.displayWidth(stats.detail),
    }, mode_label);

    const path_width = if (layout.stats) |region| region.col -| 1 else if (layout.mode) |region| region.col -| 2 else size.width;
    if (path_width > 0) {
        var path_area = surface.child(.{ .col = 0, .row = 0, .width = path_width, .height = 1 });
        try drawHeaderPath(&path_area, path, fileHeaderStyle(pane_active, styles));
    }

    if (layout.stats) |region| try drawHeaderStats(surface, region.col, stats, pane_active, styles);
    if (layout.mode) |region| try draw.copyClippedTextAt(surface, region.col, 0, mode_label, headerMetadataStyle(pane_active, styles));

    if (header_selected) {
        if (layout.path_target) |region| applyHeaderRegionStyle(surface, region, styles.selection);
    }
}

fn drawHeaderPath(surface: *chasen.Surface, path: []const u8, style: chasen.TextStyle) !void {
    try draw.copyTailClippedTextAt(surface, 0, 0, path, style);
}

fn drawHeaderStats(surface: *chasen.Surface, col: u16, stats: HeaderStatsText, pane_active: bool, styles: RenderStyles) !void {
    var cursor = col;
    const added_text = try std.fmt.allocPrint(surface.frameAllocator(), "+{d}", .{stats.added});
    try draw.copyClippedTextAt(surface, cursor, 0, added_text, headerAddedStyle(pane_active, styles));
    cursor +|= @intCast(chasen.text.displayWidth(added_text));
    if (cursor < surface.size().width) {
        try draw.copyClippedTextAt(surface, cursor, 0, " ", headerMetadataStyle(pane_active, styles));
        cursor +|= 1;
    }

    const removed_text = try std.fmt.allocPrint(surface.frameAllocator(), "-{d}", .{stats.removed});
    try draw.copyClippedTextAt(surface, cursor, 0, removed_text, headerRemovedStyle(pane_active, styles));
    cursor +|= @intCast(chasen.text.displayWidth(removed_text));
    if (cursor < surface.size().width) {
        try draw.copyClippedTextAt(surface, cursor, 0, " ", headerMetadataStyle(pane_active, styles));
        cursor +|= 1;
    }

    try draw.copyClippedTextAt(surface, cursor, 0, stats.detail, headerMetadataStyle(pane_active, styles));
}

fn applyHeaderRegionStyle(surface: *chasen.Surface, region: HeaderRegion, style: chasen.TextStyle) void {
    var col = region.col;
    const end = @min(surface.size().width, region.col + region.width);
    while (col < end) : (col += 1) {
        var cell = surface.readCell(col, 0) orelse continue;
        cell.style.bg = style.bg;
        surface.writeCell(col, 0, cell);
    }
}

fn drawHunkHeader(surface: *chasen.Surface, row: u16, header: []const u8, style: chasen.TextStyle, mode: DisplayMode, styles: RenderStyles) !void {
    if (mode == .side_by_side and surface.size().width >= side_by_side_min_width) {
        const geometry = sideBySideGeometry(surface.size().width);
        var old_column = surface.child(.{
            .col = 0,
            .row = row,
            .width = geometry.old.width,
            .height = 1,
        });
        try draw.copyClippedTextAt(&old_column, 0, 0, header, style);
        _ = surface.borrowTextAt(geometry.separator_col, row, "│", styles.metadata);
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
    styles: RenderStyles,
) !void {
    const style = hunkHeaderStyle(highlighted_hunk != null and highlighted_hunk.? == hunk.hunk_index, staged, styles);
    const marker = if (hunk.folded) "▸" else "▾";
    const header = try std.fmt.allocPrint(surface.frameAllocator(), "{s} @@ -{d},{d} +{d},{d} @@ {s}", .{
        marker,
        hunk.old_start,
        hunk.old_count,
        hunk.new_start,
        hunk.new_count,
        hunk.section,
    });
    try drawHunkHeader(surface, row, header, style, mode, styles);
}

fn hunkHeaderStyle(highlighted: bool, staged: bool, styles: RenderStyles) chasen.TextStyle {
    var style = if (highlighted) styles.selected_hunk else styles.hunk;
    if (staged) {
        style.dim = true;
        style.bg = .{ .index = 8 };
    }
    return style;
}

pub const body_start_row: u16 = 3;
pub const cursor_gutter_width: u16 = 2;

fn drawCursorMarker(surface: *chasen.Surface, row: u16, body_offset: usize, cursor_offset: ?usize, styles: RenderStyles) void {
    if (cursor_offset == null or cursor_offset.? != body_offset) return;
    _ = surface.borrowTextAt(0, row, "▌", styles.cursor);
}

fn guideGlyph(index_opt: ?diff_view_model.RenderedLineIndex, hunk_index: usize, body_offset: usize) []const u8 {
    const index = index_opt orelse return "│";
    const hunk_offset = index.hunkOffset(hunk_index);
    const line_count = index.hunkLineCount(hunk_index);
    if (body_offset == hunk_offset) return "╭";
    if (line_count > 1 and body_offset + 1 == hunk_offset + line_count) return "╰";
    return "│";
}

fn drawHunkGuide(surface: *chasen.Surface, row: u16, glyph: []const u8, styles: RenderStyles) void {
    if (surface.size().width < 2) return;
    _ = surface.borrowTextAt(1, row, glyph, styles.hunk_guide);
}

const UnifiedSyntaxContext = struct {
    line_spans: syntax_provider.LineSpans = .empty(),
    hunk_side_has_visible_syntax: bool = false,
};

fn unifiedSyntaxContext(options: RenderOptions, rows: diff_view_model.BodyRowIterator, line: diff_parser.DiffLine) UnifiedSyntaxContext {
    const hunk_index = rows.currentHunkIndex() orelse return .{};
    const line_index = rows.currentUnifiedLineIndex() orelse return .{};
    const side: syntax_provider.Side = switch (line.kind) {
        .removed => .old,
        .added, .context => .new,
        .metadata => return .{},
    };
    return .{
        .line_spans = options.syntax_spans.lineSpans(lineKey(options.file_index, hunk_index, line_index, side)),
        .hunk_side_has_visible_syntax = hunkSideHasVisibleSyntaxSignal(options.syntax_spans, options.file_index, hunk_index, side),
    };
}

fn sideBySideSingleSyntaxSpans(options: RenderOptions, rows: diff_view_model.BodyRowIterator, line: diff_parser.DiffLine) SideBySideSyntaxSpans {
    const hunk_index = rows.currentHunkIndex() orelse return .{};
    const indexed = rows.currentSideBySideRow() orelse return .{};
    const line_index = switch (indexed) {
        .single => |single| single.line_index,
        .paired => return .{},
    };
    return switch (line.kind) {
        .removed => .{
            .old = options.syntax_spans.lineSpans(lineKey(options.file_index, hunk_index, line_index, .old)),
            .old_hunk_side_has_visible_syntax = hunkSideHasVisibleSyntaxSignal(options.syntax_spans, options.file_index, hunk_index, .old),
        },
        .added => .{
            .new = options.syntax_spans.lineSpans(lineKey(options.file_index, hunk_index, line_index, .new)),
            .new_hunk_side_has_visible_syntax = hunkSideHasVisibleSyntaxSignal(options.syntax_spans, options.file_index, hunk_index, .new),
        },
        .context => .{
            .old = options.syntax_spans.lineSpans(lineKey(options.file_index, hunk_index, line_index, .old)),
            .new = options.syntax_spans.lineSpans(lineKey(options.file_index, hunk_index, line_index, .new)),
            .old_hunk_side_has_visible_syntax = hunkSideHasVisibleSyntaxSignal(options.syntax_spans, options.file_index, hunk_index, .old),
            .new_hunk_side_has_visible_syntax = hunkSideHasVisibleSyntaxSignal(options.syntax_spans, options.file_index, hunk_index, .new),
        },
        .metadata => .{},
    };
}

fn sideBySidePairSyntaxSpans(options: RenderOptions, rows: diff_view_model.BodyRowIterator) SideBySideSyntaxSpans {
    const hunk_index = rows.currentHunkIndex() orelse return .{};
    const indexed = rows.currentSideBySideRow() orelse return .{};
    return switch (indexed) {
        .single => .{},
        .paired => |pair| .{
            .old = if (pair.removed) |line| options.syntax_spans.lineSpans(lineKey(options.file_index, hunk_index, line.line_index, .old)) else .empty(),
            .new = if (pair.added) |line| options.syntax_spans.lineSpans(lineKey(options.file_index, hunk_index, line.line_index, .new)) else .empty(),
            .old_hunk_side_has_visible_syntax = hunkSideHasVisibleSyntaxSignal(options.syntax_spans, options.file_index, hunk_index, .old),
            .new_hunk_side_has_visible_syntax = hunkSideHasVisibleSyntaxSignal(options.syntax_spans, options.file_index, hunk_index, .new),
        },
    };
}

fn hunkSideHasVisibleSyntaxSignal(document_spans: syntax_provider.DocumentSpans, file_index: usize, hunk_index: usize, side: syntax_provider.Side) bool {
    if (file_index >= document_spans.files.len) return false;
    const file = document_spans.files[file_index];
    if (hunk_index >= file.hunks.len) return false;
    const hunk = file.hunks[hunk_index];
    for (hunk.lines) |line| {
        const spans = line.forSide(side);
        for (spans.spans) |span| {
            if (roleChangesForeground(span.role)) return true;
        }
    }
    return false;
}

fn lineKey(file_index: usize, hunk_index: usize, line_index: usize, side: syntax_provider.Side) syntax_provider.LineKey {
    return .{
        .file_index = file_index,
        .hunk_index = hunk_index,
        .line_index = line_index,
        .side = side,
    };
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

fn drawUnifiedLine(surface: *chasen.Surface, row: u16, line: diff_parser.DiffLine, horizontal_scroll: usize, line_numbers: bool, staged: bool, styles: RenderStyles, syntax_spans: syntax_provider.LineSpans, hunk_side_has_visible_syntax: bool) !void {
    const text_style = bodyTextStyleForLine(line.kind, staged, styles, hunk_side_has_visible_syntax);
    const marker_style = markerStyleForLine(line.kind, staged, styles);
    const prefix = prefixForLine(line.kind, hunk_side_has_visible_syntax);
    const layout = lineLayout(line_numbers, .unified);
    drawGutterLeadInBackground(surface, row, layout, gutterLeadInStyle(line.kind, staged, styles));

    if (line_numbers) {
        _ = try surface.copyTextAt(0, row, try lineNumberText(surface, line.old_line), lineNumberStyle(line.kind, staged, styles));
        _ = try surface.copyTextAt(5, row, try lineNumberText(surface, line.new_line), lineNumberStyle(line.kind, staged, styles));
    }
    _ = surface.borrowTextAt(layout.prefix_col, row, prefix, marker_style);
    try copyStyledScrolledTextAt(surface, layout.text_col, row, line.text, horizontal_scroll, text_style, syntax_spans, styles);
}

const SideBySideSyntaxSpans = struct {
    old: syntax_provider.LineSpans = .empty(),
    new: syntax_provider.LineSpans = .empty(),
    old_hunk_side_has_visible_syntax: bool = false,
    new_hunk_side_has_visible_syntax: bool = false,
};

const SideBySideSelection = struct {
    old: bool = false,
    new: bool = false,
};

fn drawSideBySidePair(surface: *chasen.Surface, row: u16, removed: ?diff_parser.DiffLine, added: ?diff_parser.DiffLine, geometry: SideBySideGeometry, horizontal_scroll: usize, line_numbers: bool, staged: bool, styles: RenderStyles, syntax_spans: SideBySideSyntaxSpans, selection: ?SideBySideSelection) !void {
    drawSideBySideSelection(surface, row, geometry, selection, styles);
    var columns = sideBySideRowColumns(surface, row, geometry);
    const selected = selection orelse SideBySideSelection{};
    if (removed) |line| try drawSideBySideOld(&columns.old, 0, line, horizontal_scroll, line_numbers, staged, styles, syntax_spans.old, syntax_spans.old_hunk_side_has_visible_syntax, selected.old);
    if (added) |line| try drawSideBySideNew(&columns.new, 0, line, horizontal_scroll, line_numbers, staged, styles, syntax_spans.new, syntax_spans.new_hunk_side_has_visible_syntax, selected.new);
    drawSideBySideGutter(surface, row, geometry, styles);
}

fn drawSideBySideSingle(surface: *chasen.Surface, row: u16, line: diff_parser.DiffLine, geometry: SideBySideGeometry, horizontal_scroll: usize, line_numbers: bool, staged: bool, styles: RenderStyles, syntax_spans: SideBySideSyntaxSpans, selection: ?SideBySideSelection) !void {
    drawSideBySideSelection(surface, row, geometry, selection, styles);
    var columns = sideBySideRowColumns(surface, row, geometry);
    const selected = selection orelse SideBySideSelection{};
    switch (line.kind) {
        .removed => {
            try drawSideBySideOld(&columns.old, 0, line, horizontal_scroll, line_numbers, staged, styles, syntax_spans.old, syntax_spans.old_hunk_side_has_visible_syntax, selected.old);
            drawSideBySideGutter(surface, row, geometry, styles);
        },
        .added => {
            try drawSideBySideNew(&columns.new, 0, line, horizontal_scroll, line_numbers, staged, styles, syntax_spans.new, syntax_spans.new_hunk_side_has_visible_syntax, selected.new);
            drawSideBySideGutter(surface, row, geometry, styles);
        },
        .context => {
            try drawSideBySideOld(&columns.old, 0, line, horizontal_scroll, line_numbers, staged, styles, syntax_spans.old, syntax_spans.old_hunk_side_has_visible_syntax, selected.old);
            try drawSideBySideNew(&columns.new, 0, line, horizontal_scroll, line_numbers, staged, styles, syntax_spans.new, syntax_spans.new_hunk_side_has_visible_syntax, selected.new);
            drawSideBySideGutter(surface, row, geometry, styles);
        },
        .metadata => {
            try draw.copyClippedTextAt(surface, 0, row, line.text, styles.metadata);
        },
    }
}

fn drawSideBySideSelection(surface: *chasen.Surface, row: u16, geometry: SideBySideGeometry, selection: ?SideBySideSelection, styles: RenderStyles) void {
    const selected = selection orelse return;
    if (selected.old) fillRowRegion(surface, row, geometry.old, styles.selection);
    if (selected.new) fillRowRegion(surface, row, geometry.new, styles.selection);
}

fn fillRowRegion(surface: *chasen.Surface, row: u16, region: SideBySideRegion, style: chasen.TextStyle) void {
    var col = region.col;
    const end = @min(surface.size().width, region.col + region.width);
    while (col < end) : (col += 1) {
        _ = surface.borrowTextAt(col, row, " ", style);
    }
}

fn drawSideBySideGutter(surface: *chasen.Surface, row: u16, geometry: SideBySideGeometry, styles: RenderStyles) void {
    _ = surface.borrowTextAt(geometry.separator_col, row, "│", styles.metadata);
}

const SideBySideColumns = struct {
    old: chasen.Surface,
    new: chasen.Surface,
};

fn sideBySideRowColumns(surface: *chasen.Surface, row: u16, geometry: SideBySideGeometry) SideBySideColumns {
    return .{
        .old = surface.child(.{
            .col = geometry.old.col,
            .row = row,
            .width = geometry.old.width,
            .height = 1,
        }),
        .new = surface.child(.{
            .col = geometry.new.col,
            .row = row,
            .width = geometry.new.width,
            .height = 1,
        }),
    };
}

fn sideBySideSelectionForIndexedRow(options: RenderOptions, file: diff_parser.FileDiff, hunk_index_opt: ?usize, row_opt: ?diff_view_model.SideBySideIndexedRow) ?SideBySideSelection {
    const row = row_opt orelse return null;
    return switch (row) {
        .single => |line| sideBySideSelectionForLine(options, file, hunk_index_opt, line),
        .paired => |pair| sideBySideSelectionForPair(options, file, hunk_index_opt, pair),
    };
}

fn sideBySideSelectionForLine(options: RenderOptions, file: diff_parser.FileDiff, hunk_index_opt: ?usize, line: diff_view_model.IndexedDiffLine) ?SideBySideSelection {
    const selection = options.selection orelse return null;
    if (!selection.identity.matchesLoadedFile(options.file_index, file)) return null;
    const hunk_index = hunk_index_opt orelse return null;
    const point = diff_selection.pointFromLine(hunk_index, line.line_index);
    if (!selection.range().contains(point)) return null;
    return switch (selection.side) {
        .old => .{ .old = diff_selection.lineVisibleOnSide(line.line, .old) },
        .new => .{ .new = diff_selection.lineVisibleOnSide(line.line, .new) },
    };
}

fn sideBySideSelectionForPair(options: RenderOptions, file: diff_parser.FileDiff, hunk_index_opt: ?usize, pair: diff_view_model.SideBySideIndexedPair) ?SideBySideSelection {
    const selection = options.selection orelse return null;
    if (!selection.identity.matchesLoadedFile(options.file_index, file)) return null;
    const hunk_index = hunk_index_opt orelse return null;
    var selected: SideBySideSelection = .{};
    const selected_range = selection.range();
    if (pair.removed) |removed| {
        const point = diff_selection.pointFromLine(hunk_index, removed.line_index);
        selected.old = selection.side == .old and selected_range.contains(point) and diff_selection.lineVisibleOnSide(removed.line, .old);
    }
    if (pair.added) |added| {
        const point = diff_selection.pointFromLine(hunk_index, added.line_index);
        selected.new = selection.side == .new and selected_range.contains(point) and diff_selection.lineVisibleOnSide(added.line, .new);
    }
    if (!selected.old and !selected.new) return null;
    return selected;
}

fn drawSideBySideOld(surface: *chasen.Surface, row: u16, line: diff_parser.DiffLine, horizontal_scroll: usize, line_numbers: bool, staged: bool, styles: RenderStyles, syntax_spans: syntax_provider.LineSpans, hunk_side_has_visible_syntax: bool, selected: bool) !void {
    const layout = lineLayout(line_numbers, .side_by_side);
    drawGutterLeadInBackground(surface, row, layout, selectedStyle(gutterLeadInStyle(line.kind, staged, styles), selected, styles));
    if (line_numbers) {
        _ = try surface.copyTextAt(0, row, try lineNumberText(surface, line.old_line), selectedStyle(lineNumberStyle(line.kind, staged, styles), selected, styles));
    }
    const prefix = if (line.kind == .removed and !hunk_side_has_visible_syntax) "-" else " ";
    _ = surface.borrowTextAt(layout.prefix_col, row, prefix, selectedStyle(markerStyleForLine(line.kind, staged, styles), selected, styles));
    try copyStyledScrolledTextAt(surface, layout.text_col, row, line.text, horizontal_scroll, selectedStyle(bodyTextStyleForLine(line.kind, staged, styles, hunk_side_has_visible_syntax), selected, styles), syntax_spans, styles);
}

fn drawSideBySideNew(surface: *chasen.Surface, row: u16, line: diff_parser.DiffLine, horizontal_scroll: usize, line_numbers: bool, staged: bool, styles: RenderStyles, syntax_spans: syntax_provider.LineSpans, hunk_side_has_visible_syntax: bool, selected: bool) !void {
    const layout = lineLayout(line_numbers, .side_by_side);
    drawGutterLeadInBackground(surface, row, layout, selectedStyle(gutterLeadInStyle(line.kind, staged, styles), selected, styles));
    if (line_numbers) {
        _ = try surface.copyTextAt(0, row, try lineNumberText(surface, line.new_line), selectedStyle(lineNumberStyle(line.kind, staged, styles), selected, styles));
    }
    const prefix = if (line.kind == .added and !hunk_side_has_visible_syntax) "+" else " ";
    _ = surface.borrowTextAt(layout.prefix_col, row, prefix, selectedStyle(markerStyleForLine(line.kind, staged, styles), selected, styles));
    try copyStyledScrolledTextAt(surface, layout.text_col, row, line.text, horizontal_scroll, selectedStyle(bodyTextStyleForLine(line.kind, staged, styles, hunk_side_has_visible_syntax), selected, styles), syntax_spans, styles);
}

fn selectedStyle(style: chasen.TextStyle, selected: bool, styles: RenderStyles) chasen.TextStyle {
    if (!selected) return style;
    var selected_style = style;
    selected_style.bg = styles.selection.bg;
    return selected_style;
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

fn drawGutterLeadInBackground(surface: *chasen.Surface, row: u16, layout: LineLayout, style: chasen.TextStyle) void {
    const end_col = @min(layout.text_col, surface.size().width);
    var col: u16 = 0;
    while (col < end_col) : (col += 1) {
        _ = surface.borrowTextAt(col, row, " ", style);
    }
}

fn scrollCells(horizontal_scroll: usize) u16 {
    return @intCast(@min(horizontal_scroll, std.math.maxInt(u16)));
}

fn copyScrolledTextAt(surface: *chasen.Surface, col: u16, row: u16, text: []const u8, horizontal_scroll: usize, style: chasen.TextStyle) !void {
    const scrolled = chasen.text.dropToWidth(text, scrollCells(horizontal_scroll));
    try copyPlainClippedTextAt(surface, col, row, scrolled, style);
}

fn copyStyledScrolledTextAt(surface: *chasen.Surface, col: u16, row: u16, text: []const u8, horizontal_scroll: usize, base_style: chasen.TextStyle, spans: syntax_provider.LineSpans, styles: RenderStyles) !void {
    try copyScrolledTextAt(surface, col, row, text, horizontal_scroll, base_style);
    if (spans.spans.len == 0) return;
    if (col >= surface.size().width) return;

    const scrolled = chasen.text.dropToWidth(text, scrollCells(horizontal_scroll));
    const visible_start = @intFromPtr(scrolled.ptr) - @intFromPtr(text.ptr);
    const visible_end = visible_start + chasen.text.clipToWidth(scrolled, surface.size().width - col).len;
    for (spans.spans) |span| {
        if (span.end <= visible_start or span.start >= visible_end) continue;
        const start = @max(span.start, visible_start);
        const end = @min(span.end, visible_end);
        if (end <= start) continue;
        const prefix_width = chasen.text.displayWidth(text[visible_start..start]);
        const span_col: u16 = col + prefix_width;
        if (span_col >= surface.size().width) continue;
        const token = chasen.text.clipToWidth(text[start..end], surface.size().width - span_col);
        if (token.len == 0) continue;
        _ = try surface.copyTextAt(span_col, row, token, syntaxStyle(base_style, span.role, styles));
    }
}

fn syntaxStyle(base: chasen.TextStyle, role: syntax_provider.TokenRole, styles: RenderStyles) chasen.TextStyle {
    var style = base;
    if (syntaxForegroundForRole(role, styles)) |fg| style.fg = fg;
    return style;
}

fn roleChangesForeground(role: syntax_provider.TokenRole) bool {
    return syntaxForegroundRole(role) != null;
}

fn syntaxForegroundForRole(role: syntax_provider.TokenRole, styles: RenderStyles) ?chasen.Color {
    return switch (syntaxForegroundRole(role) orelse return null) {
        .accent => styles.palette.color(.accent),
        .info => styles.palette.color(.info),
        .prompt => styles.palette.color(.prompt),
        .success => styles.palette.color(.success),
        .warning => styles.palette.color(.warning),
        .muted => styles.palette.color(.muted),
    };
}

const SyntaxForegroundRole = enum {
    accent,
    info,
    prompt,
    success,
    warning,
    muted,
};

fn syntaxForegroundRole(role: syntax_provider.TokenRole) ?SyntaxForegroundRole {
    return switch (role) {
        .keyword, .operator => .accent,
        .function, .property => .info,
        .type, .constant => .prompt,
        .string => .success,
        .number => .warning,
        .comment => .muted,
        .variable, .punctuation, .plain => null,
    };
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

fn textStyleForLine(kind: diff_parser.DiffLine.Kind, staged: bool, styles: RenderStyles) chasen.TextStyle {
    var style = switch (kind) {
        .added => styles.added_text,
        .removed => styles.removed_text,
        .context => styles.context,
        .metadata => styles.metadata,
    };
    if (staged) style.dim = true;
    return style;
}

fn bodyTextStyleForLine(kind: diff_parser.DiffLine.Kind, staged: bool, styles: RenderStyles, hunk_side_has_visible_syntax: bool) chasen.TextStyle {
    var style = textStyleForLine(kind, staged, styles);
    if (hunk_side_has_visible_syntax) switch (kind) {
        .added, .removed => style.fg = styles.context.fg,
        .context, .metadata => {},
    };
    return style;
}

fn markerStyleForLine(kind: diff_parser.DiffLine.Kind, staged: bool, styles: RenderStyles) chasen.TextStyle {
    var style = switch (kind) {
        .added => styles.added_marker,
        .removed => styles.removed_marker,
        .context => styles.context_marker,
        .metadata => styles.metadata,
    };
    if (staged) style.dim = true;
    return style;
}

fn gutterLeadInStyle(kind: diff_parser.DiffLine.Kind, staged: bool, styles: RenderStyles) chasen.TextStyle {
    var style: chasen.TextStyle = switch (kind) {
        .added => .{ .bg = styles.added_text.bg },
        .removed => .{ .bg = styles.removed_text.bg },
        .context => .{ .bg = styles.context.bg },
        .metadata => .{},
    };
    if (staged) style.dim = true;
    return style;
}

fn lineNumberStyle(kind: diff_parser.DiffLine.Kind, staged: bool, styles: RenderStyles) chasen.TextStyle {
    var style = switch (kind) {
        .added => styles.added_line_number,
        .removed => styles.removed_line_number,
        .context => styles.line_number,
        .metadata => styles.metadata,
    };
    if (kind == .context) style.bg = styles.context.bg;
    if (staged) style.dim = true;
    return style;
}

fn fileHeaderStyle(pane_active: bool, styles: RenderStyles) chasen.TextStyle {
    var style = styles.file_header;
    style.dim = !pane_active;
    return style;
}

fn headerAddedStyle(pane_active: bool, styles: RenderStyles) chasen.TextStyle {
    _ = pane_active;
    return .{ .fg = styles.palette.color(.success), .bold = true };
}

fn headerRemovedStyle(pane_active: bool, styles: RenderStyles) chasen.TextStyle {
    _ = pane_active;
    return .{ .fg = styles.palette.color(.danger), .bold = true };
}

fn headerMetadataStyle(pane_active: bool, styles: RenderStyles) chasen.TextStyle {
    _ = pane_active;
    return styles.metadata;
}

fn prefixForLine(kind: diff_parser.DiffLine.Kind, hunk_side_has_visible_syntax: bool) []const u8 {
    return switch (kind) {
        .added => if (hunk_side_has_visible_syntax) " " else "+",
        .removed => if (hunk_side_has_visible_syntax) " " else "-",
        .context => " ",
        .metadata => "\\",
    };
}

const side_by_side_min_width: u16 = 72;

const RenderStyles = struct {
    palette: theme.Palette,
    file_header: chasen.TextStyle,
    hunk: chasen.TextStyle,
    selected_hunk: chasen.TextStyle,
    hunk_guide: chasen.TextStyle,
    cursor: chasen.TextStyle,
    added_text: chasen.TextStyle,
    removed_text: chasen.TextStyle,
    added_marker: chasen.TextStyle,
    removed_marker: chasen.TextStyle,
    context_marker: chasen.TextStyle,
    added_line_number: chasen.TextStyle,
    removed_line_number: chasen.TextStyle,
    context: chasen.TextStyle,
    metadata: chasen.TextStyle,
    line_number: chasen.TextStyle,
    warning: chasen.TextStyle,
    selection: chasen.TextStyle,

    fn fromPalette(palette: theme.Palette) RenderStyles {
        return .{
            .palette = palette,
            .file_header = .{ .bold = true, .fg = palette.color(.accent) },
            .hunk = .{ .dim = true, .fg = palette.color(.diff_metadata) },
            .selected_hunk = .{ .bold = true, .fg = palette.color(.diff_hunk) },
            .hunk_guide = .{ .bold = true, .fg = palette.color(.diff_hunk) },
            .cursor = .{ .bold = true, .fg = palette.color(.diff_cursor) },
            // Keep diff state on backgrounds so body foreground is available
            // for syntax token colors once a provider is enabled.
            .added_text = .{ .fg = palette.color(.diff_added), .bg = palette.color(.diff_added_bg) },
            .removed_text = .{ .fg = palette.color(.diff_removed), .bg = palette.color(.diff_removed_bg) },
            .added_marker = .{ .bold = true, .fg = palette.color(.diff_added), .bg = palette.color(.diff_added_bg) },
            .removed_marker = .{ .bold = true, .fg = palette.color(.diff_removed), .bg = palette.color(.diff_removed_bg) },
            .context_marker = .{ .bg = palette.color(.diff_context_bg) },
            .added_line_number = .{ .fg = palette.color(.diff_line_number), .bg = palette.color(.diff_added_bg) },
            .removed_line_number = .{ .fg = palette.color(.diff_line_number), .bg = palette.color(.diff_removed_bg) },
            .context = .{ .bg = palette.color(.diff_context_bg) },
            .metadata = palette.style(.diff_metadata),
            .line_number = palette.style(.diff_line_number),
            .warning = palette.style(.warning),
            .selection = .{ .bg = palette.color(.diff_cursor) },
        };
    }
};

fn stylesForOptions(options: RenderOptions) RenderStyles {
    var styles = RenderStyles.fromPalette(options.palette);
    if (!options.pane_active) {
        styles.hunk_guide.dim = true;
        styles.cursor.dim = true;
    }
    return styles;
}

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

fn expectBgRange(surface: *chasen.Surface, row: u16, start_col: u16, end_col: u16, bg: chasen.Color) !void {
    var col = start_col;
    while (col < end_col) : (col += 1) {
        const cell = surface.readCell(col, row) orelse return error.MissingCell;
        try std.testing.expect(cell.style.bg.eql(bg));
    }
}

fn expectBodyGutterLeadInBg(surface: *chasen.Surface, row: u16, text_col: u16, bg: chasen.Color) !void {
    try expectBgRange(surface, row, cursor_gutter_width, cursor_gutter_width + text_col, bg);
}

test "renderFile composes diff state as body background and marker foreground" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 6);
    defer ts.deinit();

    const palette = theme.Palette.default();
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

    try renderFile(&ts.surface, file, .{ .requested_mode = .unified, .palette = palette });

    try expectBodyGutterLeadInBg(&ts.surface, 4, lineTextStart(true, .unified), palette.color(.diff_removed_bg));
    try expectBodyGutterLeadInBg(&ts.surface, 5, lineTextStart(true, .unified), palette.color(.diff_added_bg));

    const removed_old_line_number = ts.surface.readCell(3, 4).?;
    try std.testing.expect(removed_old_line_number.style.fg.eql(palette.color(.diff_line_number)));
    try std.testing.expect(removed_old_line_number.style.bg.eql(palette.color(.diff_removed_bg)));

    const removed_prefix = ts.surface.readCell(12, 4).?;
    try std.testing.expect(removed_prefix.style.fg.eql(palette.color(.diff_removed)));
    try std.testing.expect(removed_prefix.style.bg.eql(palette.color(.diff_removed_bg)));

    const removed_body = ts.surface.readCell(14, 4).?;
    try std.testing.expect(removed_body.style.fg.eql(palette.color(.diff_removed)));
    try std.testing.expect(removed_body.style.bg.eql(palette.color(.diff_removed_bg)));

    const added_line_number = ts.surface.readCell(7, 5).?;
    try std.testing.expect(added_line_number.style.bg.eql(palette.color(.diff_added_bg)));

    const added_prefix = ts.surface.readCell(12, 5).?;
    try std.testing.expect(added_prefix.style.fg.eql(palette.color(.diff_added)));
    try std.testing.expect(added_prefix.style.bg.eql(palette.color(.diff_added_bg)));

    const added_body = ts.surface.readCell(14, 5).?;
    try std.testing.expect(added_body.style.fg.eql(palette.color(.diff_added)));
    try std.testing.expect(added_body.style.bg.eql(palette.color(.diff_added_bg)));
}

test "renderFile fills unified gutter lead-in when line numbers are hidden" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(40, 5);
    defer ts.deinit();

    const palette = theme.Palette.default();
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/src/main.zig b/src/main.zig",
        .old_path = "a/src/main.zig",
        .new_path = "b/src/main.zig",
        .metadata = &.{},
        .hunks = &.{.{
            .old_start = 1,
            .old_count = 0,
            .new_start = 1,
            .new_count = 1,
            .section = "",
            .lines = &.{.{ .kind = .added, .text = "new", .new_line = 1 }},
        }},
    };

    try renderFile(&ts.surface, file, .{
        .requested_mode = .unified,
        .line_numbers = false,
        .palette = palette,
    });

    try expectBodyGutterLeadInBg(&ts.surface, 4, lineTextStart(false, .unified), palette.color(.diff_added_bg));
    try ts.expectCellText(2, 4, "+");
    try ts.expectCellText(4, 4, "n");
}

test "renderFile fills context gutter lead-in and line numbers with context background" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 5);
    defer ts.deinit();

    var palette = theme.Palette.default();
    palette.colors[@intFromEnum(theme.Role.diff_context_bg)] = .{ .index = 8 };
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/src/main.zig b/src/main.zig",
        .old_path = "a/src/main.zig",
        .new_path = "b/src/main.zig",
        .metadata = &.{},
        .hunks = &.{.{
            .old_start = 1,
            .old_count = 1,
            .new_start = 1,
            .new_count = 1,
            .section = "",
            .lines = &.{.{ .kind = .context, .text = "same", .old_line = 1, .new_line = 1 }},
        }},
    };

    try renderFile(&ts.surface, file, .{ .requested_mode = .unified, .palette = palette });

    try expectBodyGutterLeadInBg(&ts.surface, 4, lineTextStart(true, .unified), palette.color(.diff_context_bg));

    const old_line_number = ts.surface.readCell(5, 4).?;
    try std.testing.expect(old_line_number.style.fg.eql(palette.color(.diff_line_number)));
    try std.testing.expect(old_line_number.style.bg.eql(palette.color(.diff_context_bg)));

    const new_line_number = ts.surface.readCell(10, 4).?;
    try std.testing.expect(new_line_number.style.fg.eql(palette.color(.diff_line_number)));
    try std.testing.expect(new_line_number.style.bg.eql(palette.color(.diff_context_bg)));
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

    const header_cell = ts.surface.readCell(2, 3).?;
    try std.testing.expect(header_cell.style.bg.eql(.{ .index = 8 }));
    const gutter_cell = ts.surface.readCell(3, 4).?;
    try std.testing.expect(gutter_cell.style.bg.eql(theme.Palette.default().color(.diff_removed_bg)));
    try std.testing.expect(gutter_cell.style.dim);
    try ts.expectCellText(14, 4, "o");
    const old_cell = ts.surface.readCell(14, 4).?;
    try std.testing.expect(old_cell.style.dim);
    try ts.expectCellText(14, 5, "n");
    const new_cell = ts.surface.readCell(14, 5).?;
    try std.testing.expect(new_cell.style.dim);
}

test "renderFile applies unified syntax spans without removing diff background" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 6);
    defer ts.deinit();

    const palette = theme.Palette.default();
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/src/main.zig b/src/main.zig",
        .old_path = "a/src/main.zig",
        .new_path = "b/src/main.zig",
        .metadata = &.{},
        .hunks = &.{.{
            .old_start = 1,
            .old_count = 1,
            .new_start = 1,
            .new_count = 1,
            .section = "",
            .lines = &.{
                .{ .kind = .removed, .text = "old", .old_line = 1 },
                .{ .kind = .added, .text = "new", .new_line = 1 },
            },
        }},
    };
    const hunk_line_counts = [_]usize{2};
    const files = [_]syntax_provider.FileShape{.{ .hunk_line_counts = &hunk_line_counts }};
    var spans = try syntax_provider.allocateEmpty(std.testing.allocator, .{ .files = &files });
    defer spans.deinit(std.testing.allocator);
    const old_spans = try std.testing.allocator.dupe(syntax_provider.TokenSpan, &[_]syntax_provider.TokenSpan{.{ .start = 0, .end = 3, .role = .keyword }});
    const new_spans = try std.testing.allocator.dupe(syntax_provider.TokenSpan, &[_]syntax_provider.TokenSpan{.{ .start = 0, .end = 3, .role = .string }});
    syntax_provider.putLineSpans(&spans, .{ .file_index = 0, .hunk_index = 0, .line_index = 0, .side = .old }, .{ .spans = old_spans });
    syntax_provider.putLineSpans(&spans, .{ .file_index = 0, .hunk_index = 0, .line_index = 1, .side = .new }, .{ .spans = new_spans });

    try renderFile(&ts.surface, file, .{
        .requested_mode = .unified,
        .palette = palette,
        .syntax_spans = spans,
    });

    const removed_cell = ts.surface.readCell(14, 4).?;
    try std.testing.expect(removed_cell.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(removed_cell.style.bg.eql(palette.color(.diff_removed_bg)));

    const added_cell = ts.surface.readCell(14, 5).?;
    try std.testing.expect(added_cell.style.fg.eql(palette.color(.success)));
    try std.testing.expect(added_cell.style.bg.eql(palette.color(.diff_added_bg)));
}

test "renderFile hides unified diff prefix for highlighted hunk side and keeps fallback side" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 7);
    defer ts.deinit();

    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/src/main.zig b/src/main.zig",
        .old_path = "a/src/main.zig",
        .new_path = "b/src/main.zig",
        .metadata = &.{},
        .hunks = &.{.{
            .old_start = 1,
            .old_count = 1,
            .new_start = 1,
            .new_count = 2,
            .section = "",
            .lines = &.{
                .{ .kind = .removed, .text = "old", .old_line = 1 },
                .{ .kind = .added, .text = "", .new_line = 1 },
                .{ .kind = .added, .text = "new", .new_line = 2 },
            },
        }},
    };
    const hunk_line_counts = [_]usize{3};
    const files = [_]syntax_provider.FileShape{.{ .hunk_line_counts = &hunk_line_counts }};
    var spans = try syntax_provider.allocateEmpty(std.testing.allocator, .{ .files = &files });
    defer spans.deinit(std.testing.allocator);
    const new_spans = try std.testing.allocator.dupe(syntax_provider.TokenSpan, &[_]syntax_provider.TokenSpan{.{ .start = 0, .end = 3, .role = .string }});
    syntax_provider.putLineSpans(&spans, .{ .file_index = 0, .hunk_index = 0, .line_index = 2, .side = .new }, .{ .spans = new_spans });

    try renderFile(&ts.surface, file, .{ .requested_mode = .unified, .syntax_spans = spans });

    try ts.expectCellText(12, 4, "-");
    try ts.expectCellText(12, 5, " ");
    try ts.expectCellText(12, 6, " ");
    try ts.expectCellText(14, 6, "n");
}

test "renderFile normalizes highlighted unified body base foreground" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 8);
    defer ts.deinit();

    const palette = theme.Palette.default();
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/src/main.zig b/src/main.zig",
        .old_path = "a/src/main.zig",
        .new_path = "b/src/main.zig",
        .metadata = &.{},
        .hunks = &.{.{
            .old_start = 1,
            .old_count = 2,
            .new_start = 1,
            .new_count = 3,
            .section = "",
            .lines = &.{
                .{ .kind = .context, .text = "same item", .old_line = 1, .new_line = 1 },
                .{ .kind = .removed, .text = "var old_item", .old_line = 2 },
                .{ .kind = .added, .text = "var new_item", .new_line = 2 },
                .{ .kind = .added, .text = "plain fallback", .new_line = 3 },
            },
        }},
    };
    const hunk_line_counts = [_]usize{4};
    const files = [_]syntax_provider.FileShape{.{ .hunk_line_counts = &hunk_line_counts }};
    var spans = try syntax_provider.allocateEmpty(std.testing.allocator, .{ .files = &files });
    defer spans.deinit(std.testing.allocator);
    const old_spans = try std.testing.allocator.dupe(syntax_provider.TokenSpan, &[_]syntax_provider.TokenSpan{.{ .start = 0, .end = 3, .role = .keyword }});
    const new_spans = try std.testing.allocator.dupe(syntax_provider.TokenSpan, &[_]syntax_provider.TokenSpan{.{ .start = 0, .end = 3, .role = .keyword }});
    syntax_provider.putLineSpans(&spans, .{ .file_index = 0, .hunk_index = 0, .line_index = 1, .side = .old }, .{ .spans = old_spans });
    syntax_provider.putLineSpans(&spans, .{ .file_index = 0, .hunk_index = 0, .line_index = 2, .side = .new }, .{ .spans = new_spans });

    try renderFile(&ts.surface, file, .{
        .requested_mode = .unified,
        .palette = palette,
        .syntax_spans = spans,
        .staged_hunks = &.{true},
    });

    const context_cell = ts.surface.readCell(14, 4).?;
    try std.testing.expect(context_cell.style.fg.eql(.default));
    try std.testing.expect(context_cell.style.bg.eql(palette.color(.diff_context_bg)));
    try std.testing.expect(context_cell.style.dim);

    const removed_keyword = ts.surface.readCell(14, 5).?;
    try std.testing.expect(removed_keyword.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(removed_keyword.style.bg.eql(palette.color(.diff_removed_bg)));
    try std.testing.expect(removed_keyword.style.dim);

    const removed_identifier = ts.surface.readCell(18, 5).?;
    try std.testing.expect(removed_identifier.style.fg.eql(.default));
    try std.testing.expect(removed_identifier.style.bg.eql(palette.color(.diff_removed_bg)));
    try std.testing.expect(removed_identifier.style.dim);

    const added_identifier = ts.surface.readCell(18, 6).?;
    try std.testing.expect(added_identifier.style.fg.eql(.default));
    try std.testing.expect(added_identifier.style.bg.eql(palette.color(.diff_added_bg)));
    try std.testing.expect(added_identifier.style.dim);

    const unspanned_added = ts.surface.readCell(14, 7).?;
    try std.testing.expect(unspanned_added.style.fg.eql(.default));
    try std.testing.expect(unspanned_added.style.bg.eql(palette.color(.diff_added_bg)));
    try std.testing.expect(unspanned_added.style.dim);
}

test "renderFile keeps unified diff prefix when spans do not change foreground" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 6);
    defer ts.deinit();

    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/src/main.zig b/src/main.zig",
        .old_path = "a/src/main.zig",
        .new_path = "b/src/main.zig",
        .metadata = &.{},
        .hunks = &.{.{
            .old_start = 1,
            .old_count = 0,
            .new_start = 1,
            .new_count = 2,
            .section = "",
            .lines = &.{
                .{ .kind = .added, .text = "plain", .new_line = 1 },
                .{ .kind = .added, .text = "value()", .new_line = 2 },
            },
        }},
    };
    const hunk_line_counts = [_]usize{2};
    const files = [_]syntax_provider.FileShape{.{ .hunk_line_counts = &hunk_line_counts }};
    var spans = try syntax_provider.allocateEmpty(std.testing.allocator, .{ .files = &files });
    defer spans.deinit(std.testing.allocator);
    const plain_spans = try std.testing.allocator.dupe(syntax_provider.TokenSpan, &[_]syntax_provider.TokenSpan{.{ .start = 0, .end = 5, .role = .plain }});
    const fallback_spans = try std.testing.allocator.dupe(syntax_provider.TokenSpan, &[_]syntax_provider.TokenSpan{
        .{ .start = 0, .end = 5, .role = .variable },
        .{ .start = 5, .end = 7, .role = .punctuation },
    });
    syntax_provider.putLineSpans(&spans, .{ .file_index = 0, .hunk_index = 0, .line_index = 0, .side = .new }, .{ .spans = plain_spans });
    syntax_provider.putLineSpans(&spans, .{ .file_index = 0, .hunk_index = 0, .line_index = 1, .side = .new }, .{ .spans = fallback_spans });

    try renderFile(&ts.surface, file, .{ .requested_mode = .unified, .syntax_spans = spans });

    try ts.expectCellText(12, 4, "+");
    try ts.expectCellText(12, 5, "+");

    const plain_cell = ts.surface.readCell(14, 4).?;
    try std.testing.expect(plain_cell.style.fg.eql(theme.Palette.default().color(.diff_added)));
    try std.testing.expect(plain_cell.style.bg.eql(theme.Palette.default().color(.diff_added_bg)));
    const fallback_cell = ts.surface.readCell(14, 5).?;
    try std.testing.expect(fallback_cell.style.fg.eql(theme.Palette.default().color(.diff_added)));
    try std.testing.expect(fallback_cell.style.bg.eql(theme.Palette.default().color(.diff_added_bg)));
}

test "renderFile applies side-by-side context syntax spans per side" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(100, 6);
    defer ts.deinit();

    const palette = theme.Palette.default();
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/src/main.zig b/src/main.zig",
        .old_path = "a/src/main.zig",
        .new_path = "b/src/main.zig",
        .metadata = &.{},
        .hunks = &.{.{ .old_start = 1, .old_count = 1, .new_start = 1, .new_count = 1, .section = "", .lines = &.{
            .{ .kind = .context, .text = "same", .old_line = 1, .new_line = 1 },
        } }},
    };
    const hunk_line_counts = [_]usize{1};
    const files = [_]syntax_provider.FileShape{.{ .hunk_line_counts = &hunk_line_counts }};
    var spans = try syntax_provider.allocateEmpty(std.testing.allocator, .{ .files = &files });
    defer spans.deinit(std.testing.allocator);
    const old_spans = try std.testing.allocator.dupe(syntax_provider.TokenSpan, &[_]syntax_provider.TokenSpan{.{ .start = 0, .end = 4, .role = .keyword }});
    const new_spans = try std.testing.allocator.dupe(syntax_provider.TokenSpan, &[_]syntax_provider.TokenSpan{.{ .start = 0, .end = 4, .role = .string }});
    syntax_provider.putLineSpans(&spans, .{ .file_index = 0, .hunk_index = 0, .line_index = 0, .side = .old }, .{ .spans = old_spans });
    syntax_provider.putLineSpans(&spans, .{ .file_index = 0, .hunk_index = 0, .line_index = 0, .side = .new }, .{ .spans = new_spans });

    try renderFile(&ts.surface, file, .{
        .requested_mode = .side_by_side,
        .palette = palette,
        .syntax_spans = spans,
    });

    const old_cell = ts.surface.readCell(9, 4).?;
    try std.testing.expect(old_cell.style.fg.eql(palette.color(.accent)));
    const new_cell = ts.surface.readCell(59, 4).?;
    try std.testing.expect(new_cell.style.fg.eql(palette.color(.success)));
}

test "renderFile hides side-by-side diff prefixes by highlighted hunk side" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(100, 6);
    defer ts.deinit();

    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/src/main.zig b/src/main.zig",
        .old_path = "a/src/main.zig",
        .new_path = "b/src/main.zig",
        .metadata = &.{},
        .hunks = &.{.{ .old_start = 1, .old_count = 1, .new_start = 1, .new_count = 1, .section = "", .lines = &.{
            .{ .kind = .removed, .text = "old", .old_line = 1 },
            .{ .kind = .added, .text = "new", .new_line = 1 },
        } }},
    };
    const hunk_line_counts = [_]usize{2};
    const files = [_]syntax_provider.FileShape{.{ .hunk_line_counts = &hunk_line_counts }};
    var spans = try syntax_provider.allocateEmpty(std.testing.allocator, .{ .files = &files });
    defer spans.deinit(std.testing.allocator);
    const old_spans = try std.testing.allocator.dupe(syntax_provider.TokenSpan, &[_]syntax_provider.TokenSpan{.{ .start = 0, .end = 3, .role = .keyword }});
    const new_spans = try std.testing.allocator.dupe(syntax_provider.TokenSpan, &[_]syntax_provider.TokenSpan{.{ .start = 0, .end = 3, .role = .string }});
    syntax_provider.putLineSpans(&spans, .{ .file_index = 0, .hunk_index = 0, .line_index = 0, .side = .old }, .{ .spans = old_spans });
    syntax_provider.putLineSpans(&spans, .{ .file_index = 0, .hunk_index = 0, .line_index = 1, .side = .new }, .{ .spans = new_spans });

    try renderFile(&ts.surface, file, .{
        .requested_mode = .side_by_side,
        .syntax_spans = spans,
    });

    const geometry = sideBySideGeometry(bodyWidth(100));
    const old_start = cursor_gutter_width + geometry.old.col;
    const new_start = cursor_gutter_width + geometry.new.col;
    try expectBgRange(&ts.surface, 4, old_start, old_start + lineTextStart(true, .side_by_side), theme.Palette.default().color(.diff_removed_bg));
    try expectBgRange(&ts.surface, 4, new_start, new_start + lineTextStart(true, .side_by_side), theme.Palette.default().color(.diff_added_bg));
    try ts.expectCellText(7, 4, " ");
    try ts.expectCellText(57, 4, " ");
    try ts.expectCellText(9, 4, "o");
    try ts.expectCellText(59, 4, "n");
}

test "renderFile highlights only the selected side-by-side pane side" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(100, 6);
    defer ts.deinit();

    const palette = theme.Palette.default();
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/a b/a",
        .old_path = "a/a",
        .new_path = "b/a",
        .metadata = &.{},
        .hunks = &.{.{ .old_start = 1, .old_count = 1, .new_start = 1, .new_count = 1, .section = "", .lines = &.{
            .{ .kind = .removed, .text = "old", .old_line = 1 },
            .{ .kind = .added, .text = "new", .new_line = 1 },
        } }},
    };
    const geometry = sideBySideGeometry(bodyWidth(100));
    try renderFile(&ts.surface, file, .{
        .requested_mode = .side_by_side,
        .selection = .{
            .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
            .side = .old,
            .start = .{ .hunk_index = 0, .line_index = 0 },
            .end = .{ .hunk_index = 0, .line_index = 0 },
        },
    });

    const old_line_number = ts.surface.readCell(cursor_gutter_width + geometry.old.col, 4).?;
    const old_body = ts.surface.readCell(cursor_gutter_width + geometry.old.col + lineTextStart(true, .side_by_side), 4).?;
    const new_line_number = ts.surface.readCell(cursor_gutter_width + geometry.new.col, 4).?;
    const new_body = ts.surface.readCell(cursor_gutter_width + geometry.new.col + lineTextStart(true, .side_by_side), 4).?;

    try std.testing.expect(old_line_number.style.bg.eql(palette.color(.diff_cursor)));
    try std.testing.expect(old_body.style.bg.eql(palette.color(.diff_cursor)));
    try std.testing.expect(!new_line_number.style.bg.eql(palette.color(.diff_cursor)));
    try std.testing.expect(!new_body.style.bg.eql(palette.color(.diff_cursor)));
    try std.testing.expect(new_line_number.style.bg.eql(palette.color(.diff_added_bg)));
    try std.testing.expect(new_body.style.bg.eql(palette.color(.diff_added_bg)));
}

test "renderFile normalizes highlighted side-by-side body base foreground" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(100, 6);
    defer ts.deinit();

    const palette = theme.Palette.default();
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/src/main.zig b/src/main.zig",
        .old_path = "a/src/main.zig",
        .new_path = "b/src/main.zig",
        .metadata = &.{},
        .hunks = &.{.{ .old_start = 1, .old_count = 1, .new_start = 1, .new_count = 1, .section = "", .lines = &.{
            .{ .kind = .removed, .text = "var old_item", .old_line = 1 },
            .{ .kind = .added, .text = "var new_item", .new_line = 1 },
        } }},
    };
    const hunk_line_counts = [_]usize{2};
    const files = [_]syntax_provider.FileShape{.{ .hunk_line_counts = &hunk_line_counts }};
    var spans = try syntax_provider.allocateEmpty(std.testing.allocator, .{ .files = &files });
    defer spans.deinit(std.testing.allocator);
    const old_spans = try std.testing.allocator.dupe(syntax_provider.TokenSpan, &[_]syntax_provider.TokenSpan{.{ .start = 0, .end = 3, .role = .keyword }});
    const new_spans = try std.testing.allocator.dupe(syntax_provider.TokenSpan, &[_]syntax_provider.TokenSpan{.{ .start = 0, .end = 3, .role = .keyword }});
    syntax_provider.putLineSpans(&spans, .{ .file_index = 0, .hunk_index = 0, .line_index = 0, .side = .old }, .{ .spans = old_spans });
    syntax_provider.putLineSpans(&spans, .{ .file_index = 0, .hunk_index = 0, .line_index = 1, .side = .new }, .{ .spans = new_spans });

    try renderFile(&ts.surface, file, .{
        .requested_mode = .side_by_side,
        .palette = palette,
        .syntax_spans = spans,
    });

    const old_identifier = ts.surface.readCell(13, 4).?;
    try std.testing.expect(old_identifier.style.fg.eql(.default));
    try std.testing.expect(old_identifier.style.bg.eql(palette.color(.diff_removed_bg)));
    const new_identifier = ts.surface.readCell(63, 4).?;
    try std.testing.expect(new_identifier.style.fg.eql(.default));
    try std.testing.expect(new_identifier.style.bg.eql(palette.color(.diff_added_bg)));
}

test "renderFile clips syntax spans through horizontal scroll without splitting UTF-8" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 5);
    defer ts.deinit();

    const palette = theme.Palette.default();
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/src/main.zig b/src/main.zig",
        .old_path = "a/src/main.zig",
        .new_path = "b/src/main.zig",
        .metadata = &.{},
        .hunks = &.{.{ .old_start = 1, .old_count = 0, .new_start = 1, .new_count = 1, .section = "", .lines = &.{
            .{ .kind = .added, .text = "aあbc", .new_line = 1 },
        } }},
    };
    const hunk_line_counts = [_]usize{1};
    const files = [_]syntax_provider.FileShape{.{ .hunk_line_counts = &hunk_line_counts }};
    var spans = try syntax_provider.allocateEmpty(std.testing.allocator, .{ .files = &files });
    defer spans.deinit(std.testing.allocator);
    const new_spans = try std.testing.allocator.dupe(syntax_provider.TokenSpan, &[_]syntax_provider.TokenSpan{.{ .start = 1, .end = 4, .role = .string }});
    syntax_provider.putLineSpans(&spans, .{ .file_index = 0, .hunk_index = 0, .line_index = 0, .side = .new }, .{ .spans = new_spans });

    try renderFile(&ts.surface, file, .{
        .requested_mode = .unified,
        .horizontal_scroll = 1,
        .palette = palette,
        .syntax_spans = spans,
    });

    try ts.expectCellText(14, 4, "あ");
    const cell = ts.surface.readCell(14, 4).?;
    try std.testing.expect(cell.style.fg.eql(palette.color(.success)));
    try std.testing.expect(cell.style.bg.eql(palette.color(.diff_added_bg)));
}

test "hunkHeaderStyle composes highlighted and staged state" {
    const styles = RenderStyles.fromPalette(.default());
    const style = hunkHeaderStyle(true, true, styles);

    try std.testing.expect(style.fg.eql(styles.selected_hunk.fg));
    try std.testing.expect(!style.reverse);
    try std.testing.expect(style.dim);
    try std.testing.expect(style.bg.eql(.{ .index = 8 }));
}

test "hunkHeaderStyle dims unselected hunk header" {
    const styles = RenderStyles.fromPalette(.default());
    const style = hunkHeaderStyle(false, false, styles);

    try std.testing.expect(style.dim);
    try std.testing.expect(style.fg.eql(styles.hunk.fg));
}

test "selected hunk guide is drawn only for highlighted hunk" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 7);
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

    try renderFile(&ts.surface, file, .{
        .requested_mode = .unified,
        .highlighted_hunk = 1,
    });

    try ts.expectCellText(1, 3, " ");
    try ts.expectCellText(1, 4, " ");
    try ts.expectCellText(1, 5, "╭");
    try ts.expectCellText(1, 6, "╰");

    const guide_cell = ts.surface.readCell(1, 5).?;
    try std.testing.expect(guide_cell.style.fg.eql(RenderStyles.fromPalette(.default()).hunk_guide.fg));
}

test "selected hunk guide is dim when pane is inactive" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 7);
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

    try renderFile(&ts.surface, file, .{
        .requested_mode = .unified,
        .highlighted_hunk = 1,
        .pane_active = false,
    });

    const guide_cell = ts.surface.readCell(1, 5).?;
    try ts.expectCellText(1, 5, "╭");
    try std.testing.expect(guide_cell.style.dim);
    try std.testing.expect(guide_cell.style.fg.eql(RenderStyles.fromPalette(.default()).hunk_guide.fg));
}

test "selected hunk guide continues when hunk header is scrolled above viewport" {
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
                .old_count = 3,
                .new_start = 1,
                .new_count = 3,
                .section = "large",
                .lines = &.{
                    .{ .kind = .context, .text = "one", .old_line = 1, .new_line = 1 },
                    .{ .kind = .context, .text = "two", .old_line = 2, .new_line = 2 },
                    .{ .kind = .context, .text = "three", .old_line = 3, .new_line = 3 },
                },
            },
        },
    };

    var index = try diff_view_model.RenderedLineIndex.build(std.testing.allocator, file, .unified);
    defer index.deinit(std.testing.allocator);

    try renderFile(&ts.surface, file, .{
        .requested_mode = .unified,
        .scroll = index.hunkOffset(0) + 1,
        .line_index = index,
        .highlighted_hunk = 0,
    });

    try ts.expectCellText(1, 3, "│");
    try ts.expectCellText(1, 4, "│");
    try ts.expectCellText(14, 3, "o");
    try ts.expectCellText(14, 4, "t");
}

test "selected hunk guide is suppressed for folded highlighted hunk" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 5);
    defer ts.deinit();

    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/src/main.zig b/src/main.zig",
        .old_path = "a/src/main.zig",
        .new_path = "b/src/main.zig",
        .metadata = &.{},
        .hunks = &.{.{
            .old_start = 1,
            .old_count = 2,
            .new_start = 1,
            .new_count = 2,
            .section = "folded",
            .lines = &.{
                .{ .kind = .context, .text = "one", .old_line = 1, .new_line = 1 },
                .{ .kind = .context, .text = "two", .old_line = 2, .new_line = 2 },
            },
        }},
    };

    try renderFile(&ts.surface, file, .{
        .requested_mode = .unified,
        .highlighted_hunk = 0,
        .folded_hunks = &.{true},
    });

    try ts.expectCellText(1, 3, " ");
    try ts.expectCellText(2, 3, "▸");
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

    const geometry = sideBySideGeometry(bodyWidth(90));
    const new_start = cursor_gutter_width + geometry.new.col;
    try expectBgRange(&ts.surface, 3, new_start, new_start + lineTextStart(true, .side_by_side), theme.Palette.default().color(.diff_added_bg));
    try ts.expectCellText(0, 0, "s");
    try ts.expectCellText(cursor_gutter_width + geometry.separator_col, 3, "│");
    try ts.expectCellText(52, 3, "+");
    try ts.expectCellText(54, 3, "c");
}

test "renderGeneratedAddedFile draws cursor marker" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 6);
    defer ts.deinit();

    try renderGeneratedAddedFile(&ts.surface, "src/new.zig", &.{ "one", "two" }, false, .{
        .requested_mode = .unified,
        .cursor_offset = 1,
    });

    try ts.expectCellText(0, 3, " ");
    try ts.expectCellText(0, 4, "▌");
    try ts.expectCellText(14, 4, "t");
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

    try ts.expectCellText(35, 0, "u");
    try ts.expectCellText(43, 0, "(");
    try ts.expectCellText(44, 0, "a");
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

    const gutter_col: u16 = 41;
    try ts.expectCellText(gutter_col, 4, "│");
    try ts.expectCellText(gutter_col + 8, 4, "n");
    try ts.expectCellText(gutter_col + 9, 4, "e");
    try ts.expectCellText(gutter_col + 10, 4, "w");
    try ts.expectCellText(gutter_col + 12, 4, " ");
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

    const gutter_col: u16 = 41;
    try ts.expectCellText(4, 3, "@");
    try ts.expectCellText(5, 3, "@");
    try ts.expectCellText(gutter_col, 3, "│");
    try ts.expectCellText(gutter_col + 1, 3, " ");
    try ts.expectCellText(gutter_col + 8, 3, " ");
}

test "header clipping keeps filename tail visible" {
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

    try ts.expectCellText(0, 0, "…");
    try ts.expectCellText(15, 0, "g");
}

test "header clipping keeps path tail without repo prefix" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(24, 5);
    defer ts.deinit();

    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/very/deep/path/example.zig b/very/deep/path/example.zig",
        .old_path = "a/very/deep/path/example.zig",
        .new_path = "b/very/deep/path/example.zig",
        .metadata = &.{},
        .hunks = &.{},
    };

    try renderFile(&ts.surface, file, .{});

    try ts.expectCellText(0, 0, "…");
    try ts.expectCellText(9, 0, "g");
    try ts.expectCellText(11, 0, "+");
    try ts.expectCellText(12, 0, "0");
}

test "headerLayout separates path target from stats and mode" {
    const layout = headerLayout(60, "src/main.zig", .{ .added = 12, .removed = 4, .detail_width = "2 hunks".len }, "side-by-side");
    try std.testing.expect(layout.path_target != null);
    try std.testing.expect(layout.stats != null);
    try std.testing.expect(layout.mode != null);
    try std.testing.expect(layout.path_target.?.contains(0));
    try std.testing.expect(!layout.path_target.?.contains(layout.stats.?.col));
    try std.testing.expect(!layout.path_target.?.contains(layout.mode.?.col));
}

test "headerLayout omits stats before path in narrow width" {
    const layout = headerLayout(16, "src/main.zig", .{ .added = 12, .removed = 4, .detail_width = "2 hunks".len }, "unified");
    try std.testing.expect(layout.path_target != null);
    try std.testing.expect(layout.stats == null);
    try std.testing.expect(layout.mode == null);
}

test "headerLayout keeps stats before mode label" {
    const layout = headerLayout(24, "src/main.zig", .{ .added = 12, .removed = 4, .detail_width = "2 hunks".len }, "side-by-side");
    try std.testing.expect(layout.path_target != null);
    try std.testing.expect(layout.stats != null);
    try std.testing.expect(layout.mode == null);
}

test "header selection highlights path without highlighting stats" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 5);
    defer ts.deinit();

    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/src/main.zig b/src/main.zig",
        .old_path = "a/src/main.zig",
        .new_path = "b/src/main.zig",
        .metadata = &.{},
        .hunks = &.{},
    };

    try renderFile(&ts.surface, file, .{
        .header_selection = true,
    });

    const path_cell = ts.surface.readCell(0, 0).?;
    const stats_cell = ts.surface.readCell(14, 0).?;
    const selection_bg = theme.Palette.default().color(.diff_cursor);
    try std.testing.expect(path_cell.style.bg.eql(selection_bg));
    try std.testing.expect(!stats_cell.style.bg.eql(selection_bg));
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

    try ts.expectCellText(0, 4, " ");
    try ts.expectCellText(5, 4, "1");
    try ts.expectCellText(10, 4, "1");
    try ts.expectCellText(12, 4, " ");
    try ts.expectCellText(14, 4, "4");
    try ts.expectCellText(15, 4, "5");
    try ts.expectCellText(31, 4, "l");
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

    try ts.expectCellText(2, 4, "+");
    try ts.expectCellText(4, 4, "n");
    try ts.expectCellText(5, 4, "e");
    try ts.expectCellText(6, 4, "w");
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
    try ts.expectCellText(32, 0, "u");
    try std.testing.expect(!ts.surface.readCell(32, 0).?.style.dim);
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

    try ts.expectCellText(9, 4, "0");
    try ts.expectCellText(41, 4, "│");
    try ts.expectCellText(49, 4, "a");
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

    try ts.expectCellText(2, 4, "-");
    try ts.expectCellText(4, 4, "o");
    try ts.expectCellText(41, 4, "│");
    try ts.expectCellText(42, 4, "+");
    try ts.expectCellText(44, 4, "n");
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

    try ts.expectCellText(4, 3, "@");
    try ts.expectCellText(5, 3, "@");
    try ts.expectCellText(14, 4, "s");
    try ts.expectCellText(15, 4, "a");
    try ts.expectCellText(16, 4, "m");
    try ts.expectCellText(17, 4, "e");
}

test "renderFile cursor marker uses absolute body offset and dims when pane is inactive" {
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
        .pane_active = false,
        .line_index = index,
    });

    try ts.expectCellText(0, 3, " ");
    try ts.expectCellText(0, 4, "▌");
    try std.testing.expect(ts.surface.readCell(0, 4).?.style.dim);
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

    try ts.expectCellText(9, 3, "o");
    try ts.expectCellText(10, 3, "l");
    try ts.expectCellText(11, 3, "d");
    try ts.expectCellText(41, 3, "│");
    try ts.expectCellText(49, 3, "n");
    try ts.expectCellText(50, 3, "e");
    try ts.expectCellText(51, 3, "w");
}
