const std = @import("std");
const chasen = @import("chasen");
const content_fingerprint = @import("../content_fingerprint.zig");
const draw = @import("draw");
const diff_file = @import("file.zig");
const diff_hunk_projection = @import("hunk_projection.zig");
const diff_parser = @import("parser.zig");
const diff_selection = @import("selection.zig");
const diff_syntax_view = @import("syntax_view.zig");
const diff_view_model = @import("view_model.zig");
const syntax_provider = @import("../syntax/provider.zig");
const source_syntax = @import("../syntax/source.zig");
const repository_source = @import("../repository/source.zig");
const syntax_style = @import("../syntax/style.zig");
const syntax_token = @import("../syntax/token.zig");
const theme = @import("theme");
const text_projection = @import("../text/projection.zig");

pub const DisplayMode = diff_view_model.DisplayMode;

pub const HunkStageState = enum {
    unstaged,
    staged,
};

/// Explicit index-membership authority for every hunk rendered in a pane.
///
/// The former empty boolean slice conflated an unstaged document with a
/// staged-only document whose session marks had been normalized away. Keeping
/// the uniform cases as tags also avoids allocating a repeated state slice.
pub const HunkStagePresentation = union(enum) {
    all_unstaged,
    all_staged,
    per_hunk: []const HunkStageState,

    pub fn stateForHunk(self: HunkStagePresentation, hunk_index: usize) HunkStageState {
        return switch (self) {
            .all_unstaged => .unstaged,
            .all_staged => .staged,
            .per_hunk => |states| if (hunk_index < states.len) states[hunk_index] else .unstaged,
        };
    }
};

pub const RenderOptions = struct {
    requested_mode: DisplayMode = .unified,
    scroll: usize = 0,
    horizontal_scroll: usize = 0,
    pane_active: bool = true,
    line_numbers: bool = true,
    highlighted_hunk: ?usize = null,
    cursor_offset: ?usize = null,
    hunk_stages: HunkStagePresentation = .all_unstaged,
    line_index: ?diff_view_model.RenderedLineIndex = null,
    folded_hunks: []const bool = &.{},
    palette: theme.Palette = .default(),
    syntax: ?diff_syntax_view.View = null,
    source_syntax_spans: source_syntax.SourceSpans = .empty(),
    source_has_visible_syntax: bool = false,
    selection: ?diff_selection.View = null,
    header_selection: bool = false,
};

test "hunk stage presentation resolves uniform and exact per-hunk states" {
    const all_unstaged: HunkStagePresentation = .all_unstaged;
    const all_staged: HunkStagePresentation = .all_staged;
    try std.testing.expectEqual(HunkStageState.unstaged, all_unstaged.stateForHunk(0));
    try std.testing.expectEqual(HunkStageState.staged, all_staged.stateForHunk(99));

    const states = [_]HunkStageState{ .staged, .unstaged };
    const per_hunk: HunkStagePresentation = .{ .per_hunk = &states };
    try std.testing.expectEqual(HunkStageState.staged, per_hunk.stateForHunk(0));
    try std.testing.expectEqual(HunkStageState.unstaged, per_hunk.stateForHunk(1));
    try std.testing.expectEqual(HunkStageState.unstaged, per_hunk.stateForHunk(2));
}

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

pub fn generatedHeaderLayout(width: u16, path: []const u8, added_lines: usize, requested_mode: DisplayMode, mode_width: u16) HeaderLayout {
    const detail = "generated";
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
    try renderFileHeader(surface, file, options.requested_mode, content_width, options.header_selection, styles);
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
    var current_hunk_highlighted = false;
    while (rows.next()) |body_row| {
        if (cursor.done()) return;
        if (rows.currentHunkIndex()) |hunk_index| {
            current_hunk_highlighted = options.highlighted_hunk != null and options.highlighted_hunk.? == hunk_index;
        } else {
            current_hunk_highlighted = false;
        }
        const body_offset = cursor.bodyOffset();
        const row = cursor.nextRow() orelse continue;
        const presentation = RowPresentation.forBodyOffset(options, body_offset);
        presentation.prefill(surface, row, styles);
        drawCursorMarker(surface, row, body_offset, options.cursor_offset, presentation, styles);
        switch (body_row) {
            .metadata => |line| try draw.copyClippedTextAt(&body_surface, 0, row, line, presentation.compose(styles.metadata, styles)),
            .binary_marker => _ = body_surface.borrowTextAt(0, row, "Binary file", presentation.compose(styles.warning, styles)),
            .hunk_header => |hunk| {
                const current_stage = if (current_hunk_highlighted) options.hunk_stages.stateForHunk(hunk.hunk_index) else null;
                if (current_stage != null and !hunk.folded) drawHunkGuide(surface, row, guideGlyph(guide_index, hunk.hunk_index, body_offset), current_stage.?, presentation, styles);
                try drawHunkHeaderRow(&body_surface, row, hunk, current_stage, mode, presentation, styles);
            },
            .unified_line => |line| {
                if (current_hunk_highlighted) {
                    if (rows.currentHunkIndex()) |hunk_index| drawHunkGuide(surface, row, guideGlyph(guide_index, hunk_index, body_offset), options.hunk_stages.stateForHunk(hunk_index), presentation, styles);
                }
                const syntax_ctx = unifiedSyntaxContext(options, rows, line);
                try drawUnifiedLine(&body_surface, row, line, options.horizontal_scroll, options.line_numbers, presentation, styles, syntax_ctx.line_spans, syntax_ctx.hunk_side_has_visible_syntax, unifiedSelectionForLine(options, rows, line));
            },
            .side_by_side => |side_row| {
                if (current_hunk_highlighted) {
                    if (rows.currentHunkIndex()) |hunk_index| drawHunkGuide(surface, row, guideGlyph(guide_index, hunk_index, body_offset), options.hunk_stages.stateForHunk(hunk_index), presentation, styles);
                }
                const geometry = sideBySideGeometry(body_surface.size().width);
                const indexed_row = rows.currentSideBySideRow();
                switch (side_row) {
                    .single => |line| try drawSideBySideSingle(&body_surface, row, line, geometry, options.horizontal_scroll, options.line_numbers, presentation, styles, sideBySideSingleSyntaxSpans(options, rows, line), sideBySideSelectionForIndexedRow(options, file, rows.currentHunkIndex(), indexed_row)),
                    .paired => |pair| try drawSideBySidePair(&body_surface, row, pair.removed, pair.added, geometry, options.horizontal_scroll, options.line_numbers, presentation, styles, sideBySidePairSyntaxSpans(options, rows), sideBySideSelectionForIndexedRow(options, file, rows.currentHunkIndex(), indexed_row)),
                }
            },
        }
    }
}

pub fn renderGeneratedAddedFile(surface: *chasen.Surface, path: []const u8, source: *const repository_source.Document, options: RenderOptions) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    const styles = stylesForOptions(options);
    const content_width = bodyWidth(size.width);
    const mode = effectiveMode(content_width, options.requested_mode);
    try renderGeneratedFileHeader(surface, path, source.contentLineCount(), options.requested_mode, content_width, options.header_selection, styles);
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

    for (0..source.rowCount()) |index| {
        if (cursor.done()) return;
        const body_offset = cursor.bodyOffset();
        const row = cursor.nextRow() orelse continue;
        const presentation = RowPresentation.forBodyOffset(options, body_offset);
        presentation.prefill(surface, row, styles);
        drawCursorMarker(surface, row, body_offset, options.cursor_offset, presentation, styles);
        const line: diff_parser.DiffLine = .{
            .kind = .added,
            .text = source.lineBody(index).?,
            .new_line = @intCast(index + 1),
        };
        const line_spans = options.source_syntax_spans.lineSpans(index);
        if (mode == .side_by_side) {
            const geometry = sideBySideGeometry(body_surface.size().width);
            try drawSideBySidePair(&body_surface, row, null, line, geometry, options.horizontal_scroll, options.line_numbers, presentation, styles, .{
                .new = line_spans,
                .new_hunk_side_has_visible_syntax = options.source_has_visible_syntax,
            }, generatedSideBySideSelection(options, index, line));
        } else {
            try drawUnifiedLine(&body_surface, row, line, options.horizontal_scroll, options.line_numbers, presentation, styles, line_spans, options.source_has_visible_syntax, generatedUnifiedSelection(options, index, line));
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
    header_selected: bool,
    styles: RenderStyles,
) !void {
    const stats = fileStats(file);
    const detail = try std.fmt.allocPrint(surface.frameAllocator(), "{d} hunks", .{file.hunks.len});
    try drawHeaderLine(surface, displayPath(file), .{
        .added = stats.added,
        .removed = stats.removed,
        .detail = detail,
    }, modeLabel(mode_width, requested_mode), header_selected, styles);
}

fn renderGeneratedFileHeader(
    surface: *chasen.Surface,
    path: []const u8,
    added_lines: usize,
    requested_mode: DisplayMode,
    mode_width: u16,
    header_selected: bool,
    styles: RenderStyles,
) !void {
    try drawHeaderLine(surface, path, .{
        .added = added_lines,
        .removed = 0,
        .detail = "generated",
    }, modeLabel(mode_width, requested_mode), header_selected, styles);
}

const HeaderStatsText = struct {
    added: usize,
    removed: usize,
    detail: []const u8,
};

fn drawHeaderLine(surface: *chasen.Surface, path: []const u8, stats: HeaderStatsText, mode_label: []const u8, header_selected: bool, styles: RenderStyles) !void {
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
        try drawHeaderPath(&path_area, path, fileHeaderStyle(styles));
    }

    if (layout.stats) |region| try drawHeaderStats(surface, region.col, stats, styles);
    if (layout.mode) |region| try draw.copyClippedTextAt(surface, region.col, 0, mode_label, headerMetadataStyle(styles));

    if (header_selected) {
        if (layout.path_target) |region| applyHeaderRegionStyle(surface, region, styles.selection);
    }
}

fn drawHeaderPath(surface: *chasen.Surface, path: []const u8, style: chasen.TextStyle) !void {
    try draw.copyTailClippedTextAt(surface, 0, 0, path, style);
}

fn drawHeaderStats(surface: *chasen.Surface, col: u16, stats: HeaderStatsText, styles: RenderStyles) !void {
    var cursor = col;
    const added_text = try std.fmt.allocPrint(surface.frameAllocator(), "+{d}", .{stats.added});
    try draw.copyClippedTextAt(surface, cursor, 0, added_text, headerAddedStyle(styles));
    cursor +|= @intCast(chasen.text.displayWidth(added_text));
    if (cursor < surface.size().width) {
        try draw.copyClippedTextAt(surface, cursor, 0, " ", headerMetadataStyle(styles));
        cursor +|= 1;
    }

    const removed_text = try std.fmt.allocPrint(surface.frameAllocator(), "-{d}", .{stats.removed});
    try draw.copyClippedTextAt(surface, cursor, 0, removed_text, headerRemovedStyle(styles));
    cursor +|= @intCast(chasen.text.displayWidth(removed_text));
    if (cursor < surface.size().width) {
        try draw.copyClippedTextAt(surface, cursor, 0, " ", headerMetadataStyle(styles));
        cursor +|= 1;
    }

    try draw.copyClippedTextAt(surface, cursor, 0, stats.detail, headerMetadataStyle(styles));
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

fn drawHunkHeader(surface: *chasen.Surface, row: u16, header: []const u8, style: chasen.TextStyle, mode: DisplayMode, presentation: RowPresentation, styles: RenderStyles) !void {
    const row_style = presentation.compose(style, styles);
    if (mode == .side_by_side and surface.size().width >= side_by_side_min_width) {
        const geometry = sideBySideGeometry(surface.size().width);
        var old_column = surface.child(.{
            .col = 0,
            .row = row,
            .width = geometry.old.width,
            .height = 1,
        });
        try draw.copyClippedTextAt(&old_column, 0, 0, header, row_style);
        _ = surface.borrowTextAt(geometry.separator_col, row, "│", presentation.compose(styles.metadata, styles));
        return;
    }

    try draw.copyClippedTextAt(surface, 0, row, header, row_style);
}

fn drawHunkHeaderRow(
    surface: *chasen.Surface,
    row: u16,
    hunk: diff_view_model.HunkHeader,
    current_stage: ?HunkStageState,
    mode: DisplayMode,
    presentation: RowPresentation,
    styles: RenderStyles,
) !void {
    const style = hunkHeaderStyle(current_stage, styles);
    const marker = if (hunk.folded) "▸" else "▾";
    const header = try std.fmt.allocPrint(surface.frameAllocator(), "{s} @@ -{d},{d} +{d},{d} @@ {s}", .{
        marker,
        hunk.old_start,
        hunk.old_count,
        hunk.new_start,
        hunk.new_count,
        hunk.section,
    });
    try drawHunkHeader(surface, row, header, style, mode, presentation, styles);
}

fn hunkHeaderStyle(current_stage: ?HunkStageState, styles: RenderStyles) chasen.TextStyle {
    const stage = current_stage orelse return styles.hunk;
    return switch (stage) {
        .unstaged => styles.selected_hunk,
        .staged => styles.staged_hunk_header,
    };
}

pub const body_start_row: u16 = 3;
pub const cursor_gutter_width: u16 = 2;

const RowPresentation = struct {
    active_cursor: bool,

    fn forBodyOffset(options: RenderOptions, body_offset: usize) RowPresentation {
        return .{ .active_cursor = options.pane_active and options.cursor_offset != null and options.cursor_offset.? == body_offset };
    }

    fn prefill(self: RowPresentation, surface: *chasen.Surface, row: u16, styles: RenderStyles) void {
        if (!self.active_cursor) return;
        fillRowRegion(surface, row, .{ .col = 0, .width = surface.size().width }, .{ .bg = styles.palette.color(.pane_cursor_bg) });
    }

    fn compose(self: RowPresentation, base: chasen.TextStyle, styles: RenderStyles) chasen.TextStyle {
        if (!self.active_cursor) return base;
        var result = base;
        result.bg = styles.palette.color(.pane_cursor_bg);
        return result;
    }

    fn lineNumber(self: RowPresentation, base: chasen.TextStyle, present: bool, styles: RenderStyles) chasen.TextStyle {
        var result = self.compose(base, styles);
        if (self.active_cursor and present) result.fg = styles.palette.color(.pane_active_line_number);
        return result;
    }

    fn prefix(self: RowPresentation, kind: diff_parser.DiffLine.Kind, hunk_side_has_visible_syntax: bool) []const u8 {
        if (self.active_cursor and hunk_side_has_visible_syntax) return switch (kind) {
            .added => "+",
            .removed => "-",
            .context => " ",
            .metadata => "\\",
        };
        return prefixForLine(kind, hunk_side_has_visible_syntax);
    }
};

fn drawCursorMarker(surface: *chasen.Surface, row: u16, body_offset: usize, cursor_offset: ?usize, presentation: RowPresentation, styles: RenderStyles) void {
    if (cursor_offset == null or cursor_offset.? != body_offset) return;
    _ = surface.borrowTextAt(0, row, "▌", presentation.compose(styles.cursor, styles));
}

fn guideGlyph(index_opt: ?diff_view_model.RenderedLineIndex, hunk_index: usize, body_offset: usize) []const u8 {
    const index = index_opt orelse return "│";
    const hunk_offset = index.hunkOffset(hunk_index);
    const line_count = index.hunkLineCount(hunk_index);
    if (body_offset == hunk_offset) return "╭";
    if (line_count > 1 and body_offset + 1 == hunk_offset + line_count) return "╰";
    return "│";
}

fn drawHunkGuide(surface: *chasen.Surface, row: u16, glyph: []const u8, stage: HunkStageState, presentation: RowPresentation, styles: RenderStyles) void {
    if (surface.size().width < 2) return;
    const style = switch (stage) {
        .unstaged => styles.hunk_guide,
        .staged => styles.staged_hunk_guide,
    };
    _ = surface.borrowTextAt(1, row, glyph, presentation.compose(style, styles));
}

const UnifiedSyntaxContext = struct {
    line_spans: syntax_token.LineSpans = .empty(),
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
        .line_spans = syntaxLineSpans(options.syntax, hunk_index, line_index, side),
        .hunk_side_has_visible_syntax = hunkSideHasVisibleSyntaxSignal(options.syntax, hunk_index, side),
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
            .old = syntaxLineSpans(options.syntax, hunk_index, line_index, .old),
            .old_hunk_side_has_visible_syntax = hunkSideHasVisibleSyntaxSignal(options.syntax, hunk_index, .old),
        },
        .added => .{
            .new = syntaxLineSpans(options.syntax, hunk_index, line_index, .new),
            .new_hunk_side_has_visible_syntax = hunkSideHasVisibleSyntaxSignal(options.syntax, hunk_index, .new),
        },
        .context => .{
            .old = syntaxLineSpans(options.syntax, hunk_index, line_index, .old),
            .new = syntaxLineSpans(options.syntax, hunk_index, line_index, .new),
            .old_hunk_side_has_visible_syntax = hunkSideHasVisibleSyntaxSignal(options.syntax, hunk_index, .old),
            .new_hunk_side_has_visible_syntax = hunkSideHasVisibleSyntaxSignal(options.syntax, hunk_index, .new),
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
            .old = if (pair.removed) |line| syntaxLineSpans(options.syntax, hunk_index, line.line_index, .old) else .empty(),
            .new = if (pair.added) |line| syntaxLineSpans(options.syntax, hunk_index, line.line_index, .new) else .empty(),
            .old_hunk_side_has_visible_syntax = hunkSideHasVisibleSyntaxSignal(options.syntax, hunk_index, .old),
            .new_hunk_side_has_visible_syntax = hunkSideHasVisibleSyntaxSignal(options.syntax, hunk_index, .new),
        },
    };
}

fn syntaxLineSpans(view: ?diff_syntax_view.View, hunk_index: usize, line_index: usize, side: syntax_provider.Side) syntax_token.LineSpans {
    return (view orelse return .empty()).lineSpans(.{
        .hunk_index = hunk_index,
        .line_index = line_index,
        .side = side,
    });
}

fn hunkSideHasVisibleSyntaxSignal(view: ?diff_syntax_view.View, hunk_index: usize, side: syntax_provider.Side) bool {
    return (view orelse return false).hunkSideHasVisibleSyntax(hunk_index, side);
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

fn drawUnifiedLine(surface: *chasen.Surface, row: u16, line: diff_parser.DiffLine, horizontal_scroll: usize, line_numbers: bool, presentation: RowPresentation, styles: RenderStyles, syntax_spans: syntax_token.LineSpans, hunk_side_has_visible_syntax: bool, selection: ?diff_selection.LineVisualRange) !void {
    const whole_line = selection != null and selection.?.mode == .line;
    if (whole_line) fillRowRegion(surface, row, .{ .col = 0, .width = surface.size().width }, styles.selection);
    const text_style = selectedStyle(presentation.compose(bodyTextStyleForLine(line.kind, styles, hunk_side_has_visible_syntax), styles), whole_line, styles);
    const marker_style = selectedStyle(presentation.compose(markerStyleForLine(line.kind, styles), styles), whole_line, styles);
    const prefix = presentation.prefix(line.kind, hunk_side_has_visible_syntax);
    const layout = lineLayout(line_numbers, .unified);
    drawGutterLeadInBackground(surface, row, layout, selectedStyle(presentation.compose(gutterLeadInStyle(line.kind, styles), styles), whole_line, styles));

    if (line_numbers) {
        _ = try surface.copyTextAt(0, row, try lineNumberText(surface, line.old_line), selectedStyle(presentation.lineNumber(lineNumberStyle(line.kind, styles), line.old_line != null, styles), whole_line, styles));
        _ = try surface.copyTextAt(5, row, try lineNumberText(surface, line.new_line), selectedStyle(presentation.lineNumber(lineNumberStyle(line.kind, styles), line.new_line != null, styles), whole_line, styles));
    }
    _ = surface.borrowTextAt(layout.prefix_col, row, prefix, marker_style);
    try copyStyledScrolledTextAt(surface, layout.text_col, row, line.text, horizontal_scroll, text_style, syntax_spans, styles);
    if (selection) |selected| if (selected.mode == .character) applyCharacterSelection(surface, layout.text_col, row, line.text, horizontal_scroll, selected, styles.selection.bg);
}

const SideBySideSyntaxSpans = struct {
    old: syntax_token.LineSpans = .empty(),
    new: syntax_token.LineSpans = .empty(),
    old_hunk_side_has_visible_syntax: bool = false,
    new_hunk_side_has_visible_syntax: bool = false,
};

const SideBySideSelection = struct {
    old: ?diff_selection.LineVisualRange = null,
    new: ?diff_selection.LineVisualRange = null,
};

fn unifiedSelectionForLine(options: RenderOptions, rows: diff_view_model.BodyRowIterator, line: diff_parser.DiffLine) ?diff_selection.LineVisualRange {
    const selection = options.selection orelse return null;
    const hunk_index = rows.currentHunkIndex() orelse return null;
    const line_index = rows.currentUnifiedLineIndex() orelse return null;
    return diff_selection.visualRangeForLine(selection, hunk_index, line_index, line, selection.side);
}

fn generatedUnifiedSelection(options: RenderOptions, line_index: usize, line: diff_parser.DiffLine) ?diff_selection.LineVisualRange {
    const selection = options.selection orelse return null;
    if (selection.identity != .generated_file) return null;
    return diff_selection.visualRangeForLine(selection, 0, line_index, line, .new);
}

fn generatedSideBySideSelection(options: RenderOptions, line_index: usize, line: diff_parser.DiffLine) ?SideBySideSelection {
    const range = generatedUnifiedSelection(options, line_index, line) orelse return null;
    return .{ .new = range };
}

fn drawSideBySidePair(surface: *chasen.Surface, row: u16, removed: ?diff_parser.DiffLine, added: ?diff_parser.DiffLine, geometry: SideBySideGeometry, horizontal_scroll: usize, line_numbers: bool, presentation: RowPresentation, styles: RenderStyles, syntax_spans: SideBySideSyntaxSpans, selection: ?SideBySideSelection) !void {
    drawSideBySideSelection(surface, row, geometry, selection, styles);
    var columns = sideBySideRowColumns(surface, row, geometry);
    const selected = selection orelse SideBySideSelection{};
    if (removed) |line| try drawSideBySideOld(&columns.old, 0, line, horizontal_scroll, line_numbers, presentation, styles, syntax_spans.old, syntax_spans.old_hunk_side_has_visible_syntax, selected.old);
    if (added) |line| try drawSideBySideNew(&columns.new, 0, line, horizontal_scroll, line_numbers, presentation, styles, syntax_spans.new, syntax_spans.new_hunk_side_has_visible_syntax, selected.new);
    drawSideBySideGutter(surface, row, geometry, presentation, styles);
}

fn drawSideBySideSingle(surface: *chasen.Surface, row: u16, line: diff_parser.DiffLine, geometry: SideBySideGeometry, horizontal_scroll: usize, line_numbers: bool, presentation: RowPresentation, styles: RenderStyles, syntax_spans: SideBySideSyntaxSpans, selection: ?SideBySideSelection) !void {
    drawSideBySideSelection(surface, row, geometry, selection, styles);
    var columns = sideBySideRowColumns(surface, row, geometry);
    const selected = selection orelse SideBySideSelection{};
    switch (line.kind) {
        .removed => {
            try drawSideBySideOld(&columns.old, 0, line, horizontal_scroll, line_numbers, presentation, styles, syntax_spans.old, syntax_spans.old_hunk_side_has_visible_syntax, selected.old);
            drawSideBySideGutter(surface, row, geometry, presentation, styles);
        },
        .added => {
            try drawSideBySideNew(&columns.new, 0, line, horizontal_scroll, line_numbers, presentation, styles, syntax_spans.new, syntax_spans.new_hunk_side_has_visible_syntax, selected.new);
            drawSideBySideGutter(surface, row, geometry, presentation, styles);
        },
        .context => {
            try drawSideBySideOld(&columns.old, 0, line, horizontal_scroll, line_numbers, presentation, styles, syntax_spans.old, syntax_spans.old_hunk_side_has_visible_syntax, selected.old);
            try drawSideBySideNew(&columns.new, 0, line, horizontal_scroll, line_numbers, presentation, styles, syntax_spans.new, syntax_spans.new_hunk_side_has_visible_syntax, selected.new);
            drawSideBySideGutter(surface, row, geometry, presentation, styles);
        },
        .metadata => {
            try draw.copyClippedTextAt(surface, 0, row, line.text, presentation.compose(styles.metadata, styles));
        },
    }
}

fn drawSideBySideSelection(surface: *chasen.Surface, row: u16, geometry: SideBySideGeometry, selection: ?SideBySideSelection, styles: RenderStyles) void {
    const selected = selection orelse return;
    if (selected.old) |old| if (old.mode == .line) fillRowRegion(surface, row, geometry.old, styles.selection);
    if (selected.new) |new| if (new.mode == .line) fillRowRegion(surface, row, geometry.new, styles.selection);
}

fn fillRowRegion(surface: *chasen.Surface, row: u16, region: SideBySideRegion, style: chasen.TextStyle) void {
    var col = region.col;
    const end = @min(surface.size().width, region.col + region.width);
    while (col < end) : (col += 1) {
        _ = surface.borrowTextAt(col, row, " ", style);
    }
}

fn drawSideBySideGutter(surface: *chasen.Surface, row: u16, geometry: SideBySideGeometry, presentation: RowPresentation, styles: RenderStyles) void {
    _ = surface.borrowTextAt(geometry.separator_col, row, "│", presentation.compose(styles.metadata, styles));
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
    _ = file;
    const hunk_index = hunk_index_opt orelse return null;
    return switch (selection.side) {
        .old => if (diff_selection.visualRangeForLine(selection, hunk_index, line.line_index, line.line, .old)) |range| .{ .old = range } else null,
        .new => if (diff_selection.visualRangeForLine(selection, hunk_index, line.line_index, line.line, .new)) |range| .{ .new = range } else null,
    };
}

fn sideBySideSelectionForPair(options: RenderOptions, file: diff_parser.FileDiff, hunk_index_opt: ?usize, pair: diff_view_model.SideBySideIndexedPair) ?SideBySideSelection {
    const selection = options.selection orelse return null;
    _ = file;
    const hunk_index = hunk_index_opt orelse return null;
    var selected: SideBySideSelection = .{};
    if (pair.removed) |removed| {
        selected.old = diff_selection.visualRangeForLine(selection, hunk_index, removed.line_index, removed.line, .old);
    }
    if (pair.added) |added| {
        selected.new = diff_selection.visualRangeForLine(selection, hunk_index, added.line_index, added.line, .new);
    }
    if (selected.old == null and selected.new == null) return null;
    return selected;
}

fn drawSideBySideOld(surface: *chasen.Surface, row: u16, line: diff_parser.DiffLine, horizontal_scroll: usize, line_numbers: bool, presentation: RowPresentation, styles: RenderStyles, syntax_spans: syntax_token.LineSpans, hunk_side_has_visible_syntax: bool, selection: ?diff_selection.LineVisualRange) !void {
    const selected = selection != null and selection.?.mode == .line;
    const layout = lineLayout(line_numbers, .side_by_side);
    drawGutterLeadInBackground(surface, row, layout, selectedStyle(presentation.compose(gutterLeadInStyle(line.kind, styles), styles), selected, styles));
    if (line_numbers) {
        _ = try surface.copyTextAt(0, row, try lineNumberText(surface, line.old_line), selectedStyle(presentation.lineNumber(lineNumberStyle(line.kind, styles), line.old_line != null, styles), selected, styles));
    }
    const prefix = presentation.prefix(line.kind, hunk_side_has_visible_syntax);
    _ = surface.borrowTextAt(layout.prefix_col, row, prefix, selectedStyle(presentation.compose(markerStyleForLine(line.kind, styles), styles), selected, styles));
    try copyStyledScrolledTextAt(surface, layout.text_col, row, line.text, horizontal_scroll, selectedStyle(presentation.compose(bodyTextStyleForLine(line.kind, styles, hunk_side_has_visible_syntax), styles), selected, styles), syntax_spans, styles);
    if (selection) |range| if (range.mode == .character) applyCharacterSelection(surface, layout.text_col, row, line.text, horizontal_scroll, range, styles.selection.bg);
}

fn drawSideBySideNew(surface: *chasen.Surface, row: u16, line: diff_parser.DiffLine, horizontal_scroll: usize, line_numbers: bool, presentation: RowPresentation, styles: RenderStyles, syntax_spans: syntax_token.LineSpans, hunk_side_has_visible_syntax: bool, selection: ?diff_selection.LineVisualRange) !void {
    const selected = selection != null and selection.?.mode == .line;
    const layout = lineLayout(line_numbers, .side_by_side);
    drawGutterLeadInBackground(surface, row, layout, selectedStyle(presentation.compose(gutterLeadInStyle(line.kind, styles), styles), selected, styles));
    if (line_numbers) {
        _ = try surface.copyTextAt(0, row, try lineNumberText(surface, line.new_line), selectedStyle(presentation.lineNumber(lineNumberStyle(line.kind, styles), line.new_line != null, styles), selected, styles));
    }
    const prefix = presentation.prefix(line.kind, hunk_side_has_visible_syntax);
    _ = surface.borrowTextAt(layout.prefix_col, row, prefix, selectedStyle(presentation.compose(markerStyleForLine(line.kind, styles), styles), selected, styles));
    try copyStyledScrolledTextAt(surface, layout.text_col, row, line.text, horizontal_scroll, selectedStyle(presentation.compose(bodyTextStyleForLine(line.kind, styles, hunk_side_has_visible_syntax), styles), selected, styles), syntax_spans, styles);
    if (selection) |range| if (range.mode == .character) applyCharacterSelection(surface, layout.text_col, row, line.text, horizontal_scroll, range, styles.selection.bg);
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

fn copyStyledScrolledTextAt(surface: *chasen.Surface, col: u16, row: u16, text: []const u8, horizontal_scroll: usize, base_style: chasen.TextStyle, spans: syntax_token.LineSpans, styles: RenderStyles) !void {
    if (col >= surface.size().width) return;
    const width = surface.size().width - col;
    const visible = try text_projection.renderWindowAlloc(surface.frameAllocator(), text, horizontal_scroll, width);
    try copyPlainClippedTextAt(surface, col, row, visible, base_style);
    if (spans.spans.len == 0) return;

    const viewport_end = std.math.add(usize, horizontal_scroll, width) catch std.math.maxInt(usize);
    var logical_col: usize = 0;
    var span_index: usize = 0;
    var graphemes = chasen.text.graphemeIterator(text);
    while (graphemes.next()) |grapheme| {
        if (logical_col >= viewport_end) break;
        const grapheme_end = grapheme.start + grapheme.len;
        while (span_index < spans.spans.len and spans.spans[span_index].end <= grapheme.start) span_index += 1;
        const bytes = grapheme.bytes(text);
        const cells = if (bytes.len == 1 and bytes[0] == '\t')
            text_projection.tab_width - (logical_col % text_projection.tab_width)
        else
            chasen.text.displayWidth(bytes);
        const segment_end = logical_col + cells;
        defer logical_col = segment_end;
        if (span_index >= spans.spans.len) continue;
        const span = spans.spans[span_index];
        if (span.start > grapheme.start or grapheme_end > span.end) continue;
        if (segment_end <= horizontal_scroll) continue;
        const visible_start = @max(logical_col, horizontal_scroll);
        const visible_end = @min(segment_end, viewport_end);
        if (visible_start >= visible_end) continue;
        const style = syntaxStyle(base_style, span.role, styles);
        const relative_start = visible_start - horizontal_scroll;
        const visible_cells = visible_end - visible_start;
        if (bytes.len == 1 and bytes[0] == '\t' or logical_col < horizontal_scroll) {
            for (0..visible_cells) |offset| restyleCell(surface, @intCast(@as(usize, col) + relative_start + offset), row, style);
        } else if (segment_end <= viewport_end) {
            restyleCell(surface, @intCast(@as(usize, col) + relative_start), row, style);
        }
    }
}

fn restyleCell(surface: *chasen.Surface, col: u16, row: u16, style: chasen.TextStyle) void {
    var cell = surface.readCell(col, row) orelse return;
    cell.style = style;
    surface.writeCell(col, row, cell);
}

fn applyCharacterSelection(
    surface: *chasen.Surface,
    text_col: u16,
    row: u16,
    text: []const u8,
    horizontal_scroll: usize,
    range: diff_selection.LineVisualRange,
    background: chasen.Color,
) void {
    if (text_col >= surface.size().width or range.byte_start >= range.byte_end) return;
    const width = surface.size().width - text_col;
    const viewport_end = std.math.add(usize, horizontal_scroll, width) catch std.math.maxInt(usize);
    var logical_col: usize = 0;
    var graphemes = chasen.text.graphemeIterator(text);
    while (graphemes.next()) |grapheme| {
        if (logical_col >= viewport_end or grapheme.start >= range.byte_end) break;
        const bytes = grapheme.bytes(text);
        const cells = if (bytes.len == 1 and bytes[0] == '\t')
            text_projection.tab_width - (logical_col % text_projection.tab_width)
        else
            chasen.text.displayWidth(bytes);
        const segment_end = logical_col + cells;
        defer logical_col = segment_end;
        const grapheme_end = grapheme.start + grapheme.len;
        if (grapheme_end <= range.byte_start or segment_end <= horizontal_scroll) continue;
        const visible_start = @max(logical_col, horizontal_scroll);
        const visible_end = @min(segment_end, viewport_end);
        if (visible_start >= visible_end) continue;
        const relative_start = visible_start - horizontal_scroll;
        const visible_cells = visible_end - visible_start;
        if (bytes.len == 1 and bytes[0] == '\t' or logical_col < horizontal_scroll) {
            for (0..visible_cells) |offset| setCellBackground(surface, @intCast(@as(usize, text_col) + relative_start + offset), row, background);
        } else if (segment_end <= viewport_end) {
            setCellBackground(surface, @intCast(@as(usize, text_col) + relative_start), row, background);
        }
    }
}

fn setCellBackground(surface: *chasen.Surface, col: u16, row: u16, background: chasen.Color) void {
    var cell = surface.readCell(col, row) orelse return;
    cell.style.bg = background;
    surface.writeCell(col, row, cell);
}

fn syntaxStyle(base: chasen.TextStyle, role: syntax_token.TokenRole, styles: RenderStyles) chasen.TextStyle {
    return syntax_style.apply(base, role, styles.palette);
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

fn textStyleForLine(kind: diff_parser.DiffLine.Kind, styles: RenderStyles) chasen.TextStyle {
    return switch (kind) {
        .added => styles.added_text,
        .removed => styles.removed_text,
        .context => styles.context,
        .metadata => styles.metadata,
    };
}

fn bodyTextStyleForLine(kind: diff_parser.DiffLine.Kind, styles: RenderStyles, hunk_side_has_visible_syntax: bool) chasen.TextStyle {
    var style = textStyleForLine(kind, styles);
    if (hunk_side_has_visible_syntax) switch (kind) {
        .added, .removed => style.fg = styles.context.fg,
        .context, .metadata => {},
    };
    return style;
}

fn markerStyleForLine(kind: diff_parser.DiffLine.Kind, styles: RenderStyles) chasen.TextStyle {
    return switch (kind) {
        .added => styles.added_marker,
        .removed => styles.removed_marker,
        .context => styles.context_marker,
        .metadata => styles.metadata,
    };
}

fn gutterLeadInStyle(kind: diff_parser.DiffLine.Kind, styles: RenderStyles) chasen.TextStyle {
    return switch (kind) {
        .added => .{ .bg = styles.added_text.bg },
        .removed => .{ .bg = styles.removed_text.bg },
        .context => .{ .bg = styles.context.bg },
        .metadata => .{},
    };
}

fn lineNumberStyle(kind: diff_parser.DiffLine.Kind, styles: RenderStyles) chasen.TextStyle {
    var style = switch (kind) {
        .added => styles.added_line_number,
        .removed => styles.removed_line_number,
        .context => styles.line_number,
        .metadata => styles.metadata,
    };
    if (kind == .context) style.bg = styles.context.bg;
    return style;
}

/// Row-0 file identity and statistics remain readable across pane focus.
/// The row-1 rule and body cursor own the active-pane signal instead.
fn fileHeaderStyle(styles: RenderStyles) chasen.TextStyle {
    return styles.file_header;
}

fn headerAddedStyle(styles: RenderStyles) chasen.TextStyle {
    return .{ .fg = styles.palette.color(.success), .bold = true };
}

fn headerRemovedStyle(styles: RenderStyles) chasen.TextStyle {
    return .{ .fg = styles.palette.color(.danger), .bold = true };
}

fn headerMetadataStyle(styles: RenderStyles) chasen.TextStyle {
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
    staged_hunk_header: chasen.TextStyle,
    hunk_guide: chasen.TextStyle,
    staged_hunk_guide: chasen.TextStyle,
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
            .staged_hunk_header = .{ .bold = true, .fg = palette.color(.staged) },
            .hunk_guide = .{ .bold = true, .fg = palette.color(.diff_hunk) },
            // Index membership colors current-hunk chrome only. Keeping it
            // out of body styles preserves syntax and diff-kind readability.
            .staged_hunk_guide = .{ .bold = true, .fg = palette.color(.staged) },
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
        styles.staged_hunk_guide.dim = true;
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

fn headerFocusTestPalette() theme.Palette {
    var palette: theme.Palette = .default();
    palette.colors[@intFromEnum(theme.Role.accent)] = .{ .rgb = .{ 1, 2, 3 } };
    palette.colors[@intFromEnum(theme.Role.success)] = .{ .rgb = .{ 4, 5, 6 } };
    palette.colors[@intFromEnum(theme.Role.danger)] = .{ .rgb = .{ 7, 8, 9 } };
    palette.colors[@intFromEnum(theme.Role.diff_metadata)] = .{ .rgb = .{ 10, 11, 12 } };
    return palette;
}

fn expectFocusStableHeaderStyleMatrix(
    active: *chasen.Surface,
    inactive: *chasen.Surface,
    layout: HeaderLayout,
    added_text: []const u8,
    removed_text: []const u8,
    palette: theme.Palette,
) !void {
    const stats_col = layout.stats.?.col;
    const removed_col = stats_col + @as(u16, @intCast(chasen.text.displayWidth(added_text))) + 1;
    const detail_col = removed_col + @as(u16, @intCast(chasen.text.displayWidth(removed_text))) + 1;
    const points = [_]struct {
        col: u16,
        role: theme.Role,
        bold: bool,
    }{
        .{ .col = 0, .role = .accent, .bold = true },
        .{ .col = stats_col, .role = .success, .bold = true },
        .{ .col = removed_col, .role = .danger, .bold = true },
        .{ .col = detail_col, .role = .diff_metadata, .bold = false },
        .{ .col = layout.mode.?.col, .role = .diff_metadata, .bold = false },
    };
    for (points) |point| {
        const active_cell = active.readCell(point.col, 0) orelse return error.ExpectedActiveHeaderCell;
        const inactive_cell = inactive.readCell(point.col, 0) orelse return error.ExpectedInactiveHeaderCell;
        try std.testing.expect(active_cell.style.fg.eql(palette.color(point.role)));
        try std.testing.expect(inactive_cell.style.fg.eql(palette.color(point.role)));
        try std.testing.expectEqual(point.bold, active_cell.style.bold);
        try std.testing.expectEqual(point.bold, inactive_cell.style.bold);
        try std.testing.expect(!active_cell.style.dim);
        try std.testing.expect(!inactive_cell.style.dim);
    }
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

test "renderFile colors staged current hunk header without dimming body" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 6);
    defer ts.deinit();
    var palette = theme.Palette.default();
    palette.colors[@intFromEnum(theme.Role.staged)] = .{ .rgb = .{ 61, 62, 63 } };
    palette.colors[@intFromEnum(theme.Role.diff_hunk)] = .{ .rgb = .{ 71, 72, 73 } };

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
        .highlighted_hunk = 0,
        .hunk_stages = .all_staged,
        .palette = palette,
    });

    const header_cell = ts.surface.readCell(2, 3).?;
    try std.testing.expect(header_cell.style.fg.eql(palette.color(.staged)));
    try std.testing.expect(!header_cell.style.dim);
    try std.testing.expect(header_cell.style.bg.eql(.default));
    const gutter_cell = ts.surface.readCell(3, 4).?;
    try std.testing.expect(gutter_cell.style.bg.eql(theme.Palette.default().color(.diff_removed_bg)));
    try std.testing.expect(!gutter_cell.style.dim);
    try std.testing.expect(!ts.surface.readCell(5, 4).?.style.dim);
    try std.testing.expect(!ts.surface.readCell(12, 4).?.style.dim);
    try ts.expectCellText(14, 4, "o");
    const old_cell = ts.surface.readCell(14, 4).?;
    try std.testing.expect(!old_cell.style.dim);
    try ts.expectCellText(14, 5, "n");
    const new_cell = ts.surface.readCell(14, 5).?;
    try std.testing.expect(!new_cell.style.dim);
}

test "renderFile colors current header and guide from exact per-hunk stage state" {
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/src/main.zig b/src/main.zig",
        .old_path = "a/src/main.zig",
        .new_path = "b/src/main.zig",
        .metadata = &.{},
        .hunks = &.{
            .{
                .old_start = 0,
                .old_count = 0,
                .new_start = 1,
                .new_count = 1,
                .section = "staged",
                .lines = &.{.{ .kind = .added, .text = "first", .new_line = 1 }},
            },
            .{
                .old_start = 1,
                .old_count = 0,
                .new_start = 3,
                .new_count = 1,
                .section = "unstaged",
                .lines = &.{.{ .kind = .added, .text = "second", .new_line = 3 }},
            },
        },
    };
    const states = [_]HunkStageState{ .staged, .unstaged };
    var palette = theme.Palette.default();
    palette.colors[@intFromEnum(theme.Role.staged)] = .{ .rgb = .{ 1, 2, 3 } };
    palette.colors[@intFromEnum(theme.Role.diff_hunk)] = .{ .rgb = .{ 4, 5, 6 } };

    var staged: chasen.testing.TestSurface = undefined;
    try staged.init(80, 7);
    defer staged.deinit();
    try renderFile(&staged.surface, file, .{
        .requested_mode = .unified,
        .highlighted_hunk = 0,
        .hunk_stages = .{ .per_hunk = &states },
        .palette = palette,
    });
    try staged.expectCellText(1, body_start_row, "╭");
    try staged.expectCellText(1, body_start_row + 1, "╰");
    try staged.expectCellText(1, body_start_row + 2, " ");
    try std.testing.expect(staged.surface.readCell(1, body_start_row).?.style.fg.eql(palette.color(.staged)));
    try std.testing.expect(staged.surface.readCell(2, body_start_row).?.style.fg.eql(palette.color(.staged)));
    try std.testing.expect(!staged.surface.readCell(cursor_gutter_width + lineTextStart(true, .unified), body_start_row + 1).?.style.dim);

    var unstaged: chasen.testing.TestSurface = undefined;
    try unstaged.init(80, 7);
    defer unstaged.deinit();
    try renderFile(&unstaged.surface, file, .{
        .requested_mode = .unified,
        .highlighted_hunk = 1,
        .hunk_stages = .{ .per_hunk = &states },
        .palette = palette,
    });
    try unstaged.expectCellText(1, body_start_row, " ");
    try unstaged.expectCellText(1, body_start_row + 2, "╭");
    try unstaged.expectCellText(1, body_start_row + 3, "╰");
    try std.testing.expect(unstaged.surface.readCell(1, body_start_row + 2).?.style.fg.eql(palette.color(.diff_hunk)));
    try std.testing.expect(unstaged.surface.readCell(2, body_start_row + 2).?.style.fg.eql(palette.color(.diff_hunk)));
    try std.testing.expect(!unstaged.surface.readCell(cursor_gutter_width + lineTextStart(true, .unified), body_start_row + 3).?.style.dim);
}

test "whole-file and per-hunk staged authority converge on current hunk presentation" {
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/a b/a",
        .old_path = "a/a",
        .new_path = "b/a",
        .metadata = &.{},
        .hunks = &.{.{
            .old_start = 0,
            .old_count = 0,
            .new_start = 1,
            .new_count = 1,
            .section = "",
            .lines = &.{.{ .kind = .added, .text = "new", .new_line = 1 }},
        }},
    };
    const staged_state = [_]HunkStageState{.staged};
    var palette = theme.Palette.default();
    palette.colors[@intFromEnum(theme.Role.staged)] = .{ .rgb = .{ 21, 22, 23 } };
    palette.colors[@intFromEnum(theme.Role.diff_hunk)] = .{ .rgb = .{ 31, 32, 33 } };

    var whole_file: chasen.testing.TestSurface = undefined;
    try whole_file.init(80, 5);
    defer whole_file.deinit();
    try renderFile(&whole_file.surface, file, .{
        .highlighted_hunk = 0,
        .hunk_stages = .all_staged,
        .palette = palette,
    });

    var individual_hunk: chasen.testing.TestSurface = undefined;
    try individual_hunk.init(80, 5);
    defer individual_hunk.deinit();
    try renderFile(&individual_hunk.surface, file, .{
        .highlighted_hunk = 0,
        .hunk_stages = .{ .per_hunk = &staged_state },
        .palette = palette,
    });

    const whole_file_guide = whole_file.surface.readCell(1, body_start_row).?;
    const individual_hunk_guide = individual_hunk.surface.readCell(1, body_start_row).?;
    const whole_file_header = whole_file.surface.readCell(2, body_start_row).?;
    const individual_hunk_header = individual_hunk.surface.readCell(2, body_start_row).?;
    try std.testing.expect(whole_file_guide.style.fg.eql(palette.color(.staged)));
    try std.testing.expect(individual_hunk_guide.style.fg.eql(whole_file_guide.style.fg));
    try std.testing.expect(whole_file_header.style.fg.eql(palette.color(.staged)));
    try std.testing.expect(individual_hunk_header.style.fg.eql(whole_file_header.style.fg));
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
    const old_spans = try std.testing.allocator.dupe(syntax_token.TokenSpan, &[_]syntax_token.TokenSpan{.{ .start = 0, .end = 3, .role = .keyword }});
    const new_spans = try std.testing.allocator.dupe(syntax_token.TokenSpan, &[_]syntax_token.TokenSpan{.{ .start = 0, .end = 3, .role = .string }});
    syntax_provider.putLineSpans(&spans, .{ .file_index = 0, .hunk_index = 0, .line_index = 0, .side = .old }, .{ .spans = old_spans });
    syntax_provider.putLineSpans(&spans, .{ .file_index = 0, .hunk_index = 0, .line_index = 1, .side = .new }, .{ .spans = new_spans });

    try renderFile(&ts.surface, file, .{
        .requested_mode = .unified,
        .palette = palette,
        .syntax = .initDirect(&spans, 0),
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
    const new_spans = try std.testing.allocator.dupe(syntax_token.TokenSpan, &[_]syntax_token.TokenSpan{.{ .start = 0, .end = 3, .role = .string }});
    syntax_provider.putLineSpans(&spans, .{ .file_index = 0, .hunk_index = 0, .line_index = 2, .side = .new }, .{ .spans = new_spans });

    try renderFile(&ts.surface, file, .{ .requested_mode = .unified, .syntax = .initDirect(&spans, 0) });

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
    const old_spans = try std.testing.allocator.dupe(syntax_token.TokenSpan, &[_]syntax_token.TokenSpan{.{ .start = 0, .end = 3, .role = .keyword }});
    const new_spans = try std.testing.allocator.dupe(syntax_token.TokenSpan, &[_]syntax_token.TokenSpan{.{ .start = 0, .end = 3, .role = .keyword }});
    syntax_provider.putLineSpans(&spans, .{ .file_index = 0, .hunk_index = 0, .line_index = 1, .side = .old }, .{ .spans = old_spans });
    syntax_provider.putLineSpans(&spans, .{ .file_index = 0, .hunk_index = 0, .line_index = 2, .side = .new }, .{ .spans = new_spans });

    try renderFile(&ts.surface, file, .{
        .requested_mode = .unified,
        .palette = palette,
        .syntax = .initDirect(&spans, 0),
        .hunk_stages = .all_staged,
    });

    const context_cell = ts.surface.readCell(14, 4).?;
    try std.testing.expect(context_cell.style.fg.eql(.default));
    try std.testing.expect(context_cell.style.bg.eql(palette.color(.diff_context_bg)));
    try std.testing.expect(!context_cell.style.dim);

    const removed_keyword = ts.surface.readCell(14, 5).?;
    try std.testing.expect(removed_keyword.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(removed_keyword.style.bg.eql(palette.color(.diff_removed_bg)));
    try std.testing.expect(!removed_keyword.style.dim);

    const removed_identifier = ts.surface.readCell(18, 5).?;
    try std.testing.expect(removed_identifier.style.fg.eql(.default));
    try std.testing.expect(removed_identifier.style.bg.eql(palette.color(.diff_removed_bg)));
    try std.testing.expect(!removed_identifier.style.dim);

    const added_identifier = ts.surface.readCell(18, 6).?;
    try std.testing.expect(added_identifier.style.fg.eql(.default));
    try std.testing.expect(added_identifier.style.bg.eql(palette.color(.diff_added_bg)));
    try std.testing.expect(!added_identifier.style.dim);

    const unspanned_added = ts.surface.readCell(14, 7).?;
    try std.testing.expect(unspanned_added.style.fg.eql(.default));
    try std.testing.expect(unspanned_added.style.bg.eql(palette.color(.diff_added_bg)));
    try std.testing.expect(!unspanned_added.style.dim);
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
    const plain_spans = try std.testing.allocator.dupe(syntax_token.TokenSpan, &[_]syntax_token.TokenSpan{.{ .start = 0, .end = 5, .role = .plain }});
    const fallback_spans = try std.testing.allocator.dupe(syntax_token.TokenSpan, &[_]syntax_token.TokenSpan{
        .{ .start = 0, .end = 5, .role = .variable },
        .{ .start = 5, .end = 7, .role = .punctuation },
    });
    syntax_provider.putLineSpans(&spans, .{ .file_index = 0, .hunk_index = 0, .line_index = 0, .side = .new }, .{ .spans = plain_spans });
    syntax_provider.putLineSpans(&spans, .{ .file_index = 0, .hunk_index = 0, .line_index = 1, .side = .new }, .{ .spans = fallback_spans });

    try renderFile(&ts.surface, file, .{ .requested_mode = .unified, .syntax = .initDirect(&spans, 0) });

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
    const old_spans = try std.testing.allocator.dupe(syntax_token.TokenSpan, &[_]syntax_token.TokenSpan{.{ .start = 0, .end = 4, .role = .keyword }});
    const new_spans = try std.testing.allocator.dupe(syntax_token.TokenSpan, &[_]syntax_token.TokenSpan{.{ .start = 0, .end = 4, .role = .string }});
    syntax_provider.putLineSpans(&spans, .{ .file_index = 0, .hunk_index = 0, .line_index = 0, .side = .old }, .{ .spans = old_spans });
    syntax_provider.putLineSpans(&spans, .{ .file_index = 0, .hunk_index = 0, .line_index = 0, .side = .new }, .{ .spans = new_spans });

    try renderFile(&ts.surface, file, .{
        .requested_mode = .side_by_side,
        .palette = palette,
        .syntax = .initDirect(&spans, 0),
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
    const old_spans = try std.testing.allocator.dupe(syntax_token.TokenSpan, &[_]syntax_token.TokenSpan{.{ .start = 0, .end = 3, .role = .keyword }});
    const new_spans = try std.testing.allocator.dupe(syntax_token.TokenSpan, &[_]syntax_token.TokenSpan{.{ .start = 0, .end = 3, .role = .string }});
    syntax_provider.putLineSpans(&spans, .{ .file_index = 0, .hunk_index = 0, .line_index = 0, .side = .old }, .{ .spans = old_spans });
    syntax_provider.putLineSpans(&spans, .{ .file_index = 0, .hunk_index = 0, .line_index = 1, .side = .new }, .{ .spans = new_spans });

    try renderFile(&ts.surface, file, .{
        .requested_mode = .side_by_side,
        .syntax = .initDirect(&spans, 0),
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

test "renderFile resolves reordered combined syntax in unified and side-by-side modes" {
    const allocator = std.testing.allocator;
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/src/main.zig b/src/main.zig",
        .old_path = "a/src/main.zig",
        .new_path = "b/src/main.zig",
        .metadata = &.{},
        .hunks = &.{
            .{
                .old_start = 10,
                .old_count = 1,
                .new_start = 10,
                .new_count = 1,
                .section = "unstaged origin",
                .lines = &.{
                    .{ .kind = .removed, .text = "old unstaged", .old_line = 10 },
                    .{ .kind = .added, .text = "new unstaged", .new_line = 10 },
                },
            },
            .{
                .old_start = 20,
                .old_count = 1,
                .new_start = 20,
                .new_count = 1,
                .section = "cached origin",
                .lines = &.{
                    .{ .kind = .removed, .text = "old cached", .old_line = 20 },
                    .{ .kind = .added, .text = "new cached", .new_line = 20 },
                },
            },
        },
    };
    const component_hunk_lines = [_]usize{ 2, 2 };
    const component_files = [_]syntax_provider.FileShape{.{ .hunk_line_counts = &component_hunk_lines }};
    var cached = try syntax_provider.allocateEmpty(allocator, .{ .files = &component_files });
    defer cached.deinit(allocator);
    var unstaged = try syntax_provider.allocateEmpty(allocator, .{ .files = &component_files });
    defer unstaged.deinit(allocator);

    // Correct origins use cached(0) and unstaged(1). The other component
    // ordinals deliberately contain non-visible roles so projected-ordinal or
    // opposite-component fallback changes both token color and prefix output.
    try putOwnedTestSpan(allocator, &cached, .{ .file_index = 0, .hunk_index = 0, .line_index = 0, .side = .old }, .keyword);
    try putOwnedTestSpan(allocator, &cached, .{ .file_index = 0, .hunk_index = 0, .line_index = 1, .side = .new }, .string);
    try putOwnedTestSpan(allocator, &cached, .{ .file_index = 0, .hunk_index = 1, .line_index = 0, .side = .old }, .variable);
    try putOwnedTestSpan(allocator, &cached, .{ .file_index = 0, .hunk_index = 1, .line_index = 1, .side = .new }, .plain);
    try putOwnedTestSpan(allocator, &unstaged, .{ .file_index = 0, .hunk_index = 0, .line_index = 0, .side = .old }, .variable);
    try putOwnedTestSpan(allocator, &unstaged, .{ .file_index = 0, .hunk_index = 0, .line_index = 1, .side = .new }, .plain);
    try putOwnedTestSpan(allocator, &unstaged, .{ .file_index = 0, .hunk_index = 1, .line_index = 0, .side = .old }, .type);
    try putOwnedTestSpan(allocator, &unstaged, .{ .file_index = 0, .hunk_index = 1, .line_index = 1, .side = .new }, .number);

    const hunk_states = [_]diff_hunk_projection.ProjectedHunkState{
        .{ .state = .unstaged, .origin = .{ .unstaged = 1 } },
        .{ .state = .staged, .origin = .{ .cached = 0 } },
    };
    const syntax = diff_syntax_view.View.initCombined(&hunk_states, &cached, &unstaged);
    var palette: theme.Palette = .default();
    palette.colors[@intFromEnum(theme.Role.accent)] = .{ .rgb = .{ 1, 2, 3 } };
    palette.colors[@intFromEnum(theme.Role.success)] = .{ .rgb = .{ 4, 5, 6 } };
    palette.colors[@intFromEnum(theme.Role.prompt)] = .{ .rgb = .{ 7, 8, 9 } };
    palette.colors[@intFromEnum(theme.Role.warning)] = .{ .rgb = .{ 10, 11, 12 } };

    var unified: chasen.testing.TestSurface = undefined;
    try unified.init(80, 9);
    defer unified.deinit();
    try renderFile(&unified.surface, file, .{
        .requested_mode = .unified,
        .palette = palette,
        .syntax = syntax,
    });
    const unified_text_col = cursor_gutter_width + lineTextStart(true, .unified);
    const unified_prefix_col = cursor_gutter_width + lineLayout(true, .unified).prefix_col;
    try std.testing.expect(unified.surface.readCell(unified_text_col, body_start_row + 1).?.style.fg.eql(palette.color(.prompt)));
    try std.testing.expect(unified.surface.readCell(unified_text_col, body_start_row + 2).?.style.fg.eql(palette.color(.warning)));
    try std.testing.expect(unified.surface.readCell(unified_text_col, body_start_row + 4).?.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(unified.surface.readCell(unified_text_col, body_start_row + 5).?.style.fg.eql(palette.color(.success)));
    try unified.expectCellText(unified_prefix_col, body_start_row + 1, " ");
    try unified.expectCellText(unified_prefix_col, body_start_row + 5, " ");

    var side_by_side: chasen.testing.TestSurface = undefined;
    try side_by_side.init(100, 7);
    defer side_by_side.deinit();
    try renderFile(&side_by_side.surface, file, .{
        .requested_mode = .side_by_side,
        .palette = palette,
        .syntax = syntax,
    });
    const geometry = sideBySideGeometry(bodyWidth(100));
    const old_text_col = cursor_gutter_width + geometry.old.col + lineTextStart(true, .side_by_side);
    const new_text_col = cursor_gutter_width + geometry.new.col + lineTextStart(true, .side_by_side);
    const old_prefix_col = cursor_gutter_width + geometry.old.col + lineLayout(true, .side_by_side).prefix_col;
    const new_prefix_col = cursor_gutter_width + geometry.new.col + lineLayout(true, .side_by_side).prefix_col;
    try std.testing.expect(side_by_side.surface.readCell(old_text_col, body_start_row + 1).?.style.fg.eql(palette.color(.prompt)));
    try std.testing.expect(side_by_side.surface.readCell(new_text_col, body_start_row + 1).?.style.fg.eql(palette.color(.warning)));
    try std.testing.expect(side_by_side.surface.readCell(old_text_col, body_start_row + 3).?.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(side_by_side.surface.readCell(new_text_col, body_start_row + 3).?.style.fg.eql(palette.color(.success)));
    try side_by_side.expectCellText(old_prefix_col, body_start_row + 1, " ");
    try side_by_side.expectCellText(new_prefix_col, body_start_row + 3, " ");
}

fn putOwnedTestSpan(
    allocator: std.mem.Allocator,
    document: *syntax_provider.DocumentSpans,
    key: syntax_provider.LineKey,
    role: syntax_token.TokenRole,
) !void {
    const spans = try allocator.dupe(syntax_token.TokenSpan, &.{.{ .start = 0, .end = 3, .role = role }});
    syntax_provider.putLineSpans(document, key, .{ .spans = spans });
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

test "review diff cursor character selection preserves syntax without stage dim" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 6);
    defer ts.deinit();

    const palette = reviewCursorTestPalette();
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/a b/a",
        .old_path = "a/a",
        .new_path = "b/a",
        .metadata = &.{},
        .hunks = &.{.{
            .old_start = 0,
            .old_count = 0,
            .new_start = 1,
            .new_count = 1,
            .section = "",
            .lines = &.{.{ .kind = .added, .text = "abcd", .new_line = 1 }},
        }},
    };
    const hunk_line_counts = [_]usize{1};
    const files = [_]syntax_provider.FileShape{.{ .hunk_line_counts = &hunk_line_counts }};
    var spans = try syntax_provider.allocateEmpty(std.testing.allocator, .{ .files = &files });
    defer spans.deinit(std.testing.allocator);
    const keyword = try std.testing.allocator.dupe(syntax_token.TokenSpan, &.{.{ .start = 0, .end = 4, .role = .keyword }});
    syntax_provider.putLineSpans(&spans, .{ .file_index = 0, .hunk_index = 0, .line_index = 0, .side = .new }, .{ .spans = keyword });

    try renderFile(&ts.surface, file, .{
        .requested_mode = .unified,
        .cursor_offset = 1,
        .palette = palette,
        .syntax = .initDirect(&spans, 0),
        .hunk_stages = .all_staged,
        .selection = .{
            .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
            .side = .new,
            .mode = .character,
            .start = .{ .hunk_index = 0, .line_index = 0, .leading = 1, .trailing = 2 },
            .end = .{ .hunk_index = 0, .line_index = 0, .leading = 2, .trailing = 3 },
        },
    });

    const text_col = cursor_gutter_width + lineTextStart(true, .unified);
    const first = ts.surface.readCell(text_col, 4).?;
    const selected_b = ts.surface.readCell(text_col + 1, 4).?;
    const selected_c = ts.surface.readCell(text_col + 2, 4).?;
    const last = ts.surface.readCell(text_col + 3, 4).?;
    const pane_bg = palette.color(.pane_cursor_bg);
    try std.testing.expect(ts.surface.readCell(0, 4).?.style.bg.eql(pane_bg));
    try std.testing.expect(ts.surface.readCell(1, 4).?.style.bg.eql(pane_bg));
    try std.testing.expect(ts.surface.readCell(5, 4).?.style.bg.eql(pane_bg));
    try std.testing.expect(ts.surface.readCell(10, 4).?.style.bg.eql(pane_bg));
    try std.testing.expect(ts.surface.readCell(12, 4).?.style.bg.eql(pane_bg));
    try std.testing.expect(first.style.bg.eql(pane_bg));
    try std.testing.expect(selected_b.style.bg.eql(palette.color(.diff_cursor)));
    try std.testing.expect(selected_c.style.bg.eql(palette.color(.diff_cursor)));
    try std.testing.expect(last.style.bg.eql(pane_bg));
    try std.testing.expect(ts.surface.readCell(79, 4).?.style.bg.eql(pane_bg));
    try std.testing.expect(selected_b.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(selected_c.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(!selected_b.style.dim);
    try std.testing.expect(!selected_c.style.dim);
}

test "review diff cursor side-by-side character selection stays inside the locked pane text" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(100, 6);
    defer ts.deinit();

    const palette = reviewCursorTestPalette();
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/a b/a",
        .old_path = "a/a",
        .new_path = "b/a",
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
    try renderFile(&ts.surface, file, .{
        .requested_mode = .side_by_side,
        .cursor_offset = 1,
        .palette = palette,
        .selection = .{
            .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
            .side = .old,
            .mode = .character,
            .start = .{ .hunk_index = 0, .line_index = 0, .leading = 1, .trailing = 2 },
            .end = .{ .hunk_index = 0, .line_index = 0, .leading = 1, .trailing = 2 },
        },
    });

    const geometry = sideBySideGeometry(bodyWidth(100));
    const old_text = cursor_gutter_width + geometry.old.col + lineTextStart(true, .side_by_side);
    const new_text = cursor_gutter_width + geometry.new.col + lineTextStart(true, .side_by_side);
    const separator = cursor_gutter_width + geometry.separator_col;
    const pane_bg = palette.color(.pane_cursor_bg);
    try std.testing.expect(ts.surface.readCell(0, 4).?.style.bg.eql(pane_bg));
    try std.testing.expect(ts.surface.readCell(1, 4).?.style.bg.eql(pane_bg));
    try std.testing.expect(ts.surface.readCell(cursor_gutter_width + geometry.old.col, 4).?.style.bg.eql(pane_bg));
    try std.testing.expect(ts.surface.readCell(old_text, 4).?.style.bg.eql(pane_bg));
    try std.testing.expect(ts.surface.readCell(old_text + 1, 4).?.style.bg.eql(palette.color(.diff_cursor)));
    try std.testing.expect(ts.surface.readCell(old_text + 2, 4).?.style.bg.eql(pane_bg));
    try std.testing.expect(ts.surface.readCell(separator, 4).?.style.bg.eql(pane_bg));
    try std.testing.expect(ts.surface.readCell(new_text + 1, 4).?.style.bg.eql(pane_bg));
    try std.testing.expect(ts.surface.readCell(99, 4).?.style.bg.eql(pane_bg));
}

test "review diff cursor TAB selection and syntax use the same multi-cell projection" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 6);
    defer ts.deinit();

    const palette = reviewCursorTestPalette();
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/a b/a",
        .old_path = "a/a",
        .new_path = "b/a",
        .metadata = &.{},
        .hunks = &.{.{
            .old_start = 0,
            .old_count = 0,
            .new_start = 1,
            .new_count = 1,
            .section = "",
            .lines = &.{.{ .kind = .added, .text = "a\tb", .new_line = 1 }},
        }},
    };
    const hunk_line_counts = [_]usize{1};
    const files = [_]syntax_provider.FileShape{.{ .hunk_line_counts = &hunk_line_counts }};
    var spans = try syntax_provider.allocateEmpty(std.testing.allocator, .{ .files = &files });
    defer spans.deinit(std.testing.allocator);
    const keyword = try std.testing.allocator.dupe(syntax_token.TokenSpan, &.{.{ .start = 2, .end = 3, .role = .keyword }});
    syntax_provider.putLineSpans(&spans, .{ .file_index = 0, .hunk_index = 0, .line_index = 0, .side = .new }, .{ .spans = keyword });

    try renderFile(&ts.surface, file, .{
        .requested_mode = .unified,
        .cursor_offset = 1,
        .palette = palette,
        .syntax = .initDirect(&spans, 0),
        .selection = .{
            .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
            .side = .new,
            .mode = .character,
            .start = .{ .hunk_index = 0, .line_index = 0, .leading = 1, .trailing = 2 },
            .end = .{ .hunk_index = 0, .line_index = 0, .leading = 1, .trailing = 2 },
        },
    });

    const text_col = cursor_gutter_width + lineTextStart(true, .unified);
    const pane_bg = palette.color(.pane_cursor_bg);
    try std.testing.expect(ts.surface.readCell(text_col, 4).?.style.bg.eql(pane_bg));
    try expectBgRange(&ts.surface, 4, text_col + 1, text_col + 4, palette.color(.diff_cursor));
    const b = ts.surface.readCell(text_col + 4, 4).?;
    try std.testing.expect(b.style.bg.eql(pane_bg));
    try std.testing.expect(b.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(ts.surface.readCell(79, 4).?.style.bg.eql(pane_bg));
}

test "review diff cursor keeps wide combining and emoji graphemes atomic under character selection" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 6);
    defer ts.deinit();

    const palette = reviewCursorTestPalette();
    const text = "a界e\u{301}👩‍💻z";
    const wide_start = 1;
    const wide_end = wide_start + "界".len;
    const emoji_start = wide_end + "e\u{301}".len;
    const selected_end = text.len - 1;
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/a b/a",
        .old_path = "a/a",
        .new_path = "b/a",
        .metadata = &.{},
        .hunks = &.{.{
            .old_start = 0,
            .old_count = 0,
            .new_start = 1,
            .new_count = 1,
            .section = "",
            .lines = &.{.{ .kind = .added, .text = text, .new_line = 1 }},
        }},
    };

    try renderFile(&ts.surface, file, .{
        .requested_mode = .unified,
        .cursor_offset = 1,
        .palette = palette,
        .selection = .{
            .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
            .side = .new,
            .mode = .character,
            .start = .{ .hunk_index = 0, .line_index = 0, .leading = wide_start, .trailing = wide_end },
            .end = .{ .hunk_index = 0, .line_index = 0, .leading = emoji_start, .trailing = selected_end },
        },
    });

    const text_col = cursor_gutter_width + lineTextStart(true, .unified);
    const pane_bg = palette.color(.pane_cursor_bg);
    const selection_bg = palette.color(.diff_cursor);
    try std.testing.expect(ts.surface.readCell(text_col, 4).?.style.bg.eql(pane_bg));
    // Vaxis stores a wide grapheme as one styled Cell with width 2, rather
    // than exposing its second occupied terminal column as another token.
    // Assert grapheme bytes and width together so a byte-interior or
    // partial-cell selection cannot satisfy this regression.
    const wide = ts.surface.readCell(text_col + 1, 4).?;
    const combining = ts.surface.readCell(text_col + 3, 4).?;
    const emoji = ts.surface.readCell(text_col + 4, 4).?;
    try std.testing.expectEqualStrings("界", wide.char.grapheme);
    try std.testing.expectEqual(@as(u8, 2), wide.char.width);
    try std.testing.expect(wide.style.bg.eql(selection_bg));
    try std.testing.expectEqualStrings("e\u{301}", combining.char.grapheme);
    try std.testing.expect(combining.style.bg.eql(selection_bg));
    try std.testing.expectEqualStrings("👩‍💻", emoji.char.grapheme);
    try std.testing.expectEqual(@as(u8, 2), emoji.char.width);
    try std.testing.expect(emoji.style.bg.eql(selection_bg));
    try std.testing.expect(ts.surface.readCell(text_col + 6, 4).?.style.bg.eql(pane_bg));
    try std.testing.expect(ts.surface.readCell(79, 4).?.style.bg.eql(pane_bg));
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
    const old_spans = try std.testing.allocator.dupe(syntax_token.TokenSpan, &[_]syntax_token.TokenSpan{.{ .start = 0, .end = 3, .role = .keyword }});
    const new_spans = try std.testing.allocator.dupe(syntax_token.TokenSpan, &[_]syntax_token.TokenSpan{.{ .start = 0, .end = 3, .role = .keyword }});
    syntax_provider.putLineSpans(&spans, .{ .file_index = 0, .hunk_index = 0, .line_index = 0, .side = .old }, .{ .spans = old_spans });
    syntax_provider.putLineSpans(&spans, .{ .file_index = 0, .hunk_index = 0, .line_index = 1, .side = .new }, .{ .spans = new_spans });

    try renderFile(&ts.surface, file, .{
        .requested_mode = .side_by_side,
        .palette = palette,
        .syntax = .initDirect(&spans, 0),
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
    const new_spans = try std.testing.allocator.dupe(syntax_token.TokenSpan, &[_]syntax_token.TokenSpan{.{ .start = 1, .end = 4, .role = .string }});
    syntax_provider.putLineSpans(&spans, .{ .file_index = 0, .hunk_index = 0, .line_index = 0, .side = .new }, .{ .spans = new_spans });

    try renderFile(&ts.surface, file, .{
        .requested_mode = .unified,
        .horizontal_scroll = 1,
        .palette = palette,
        .syntax = .initDirect(&spans, 0),
    });

    try ts.expectCellText(14, 4, "あ");
    const cell = ts.surface.readCell(14, 4).?;
    try std.testing.expect(cell.style.fg.eql(palette.color(.success)));
    try std.testing.expect(cell.style.bg.eql(palette.color(.diff_added_bg)));
}

test "hunkHeaderStyle colors current hunk from exact stage state" {
    const styles = RenderStyles.fromPalette(.default());
    const unstaged = hunkHeaderStyle(.unstaged, styles);
    const staged = hunkHeaderStyle(.staged, styles);

    try std.testing.expect(unstaged.fg.eql(styles.selected_hunk.fg));
    try std.testing.expect(staged.fg.eql(styles.staged_hunk_header.fg));
    try std.testing.expect(!unstaged.reverse);
    try std.testing.expect(!staged.reverse);
    try std.testing.expect(!unstaged.dim);
    try std.testing.expect(!staged.dim);
    try std.testing.expect(unstaged.bg.eql(.default));
    try std.testing.expect(staged.bg.eql(.default));
}

test "hunkHeaderStyle dims unselected hunk header" {
    const styles = RenderStyles.fromPalette(.default());
    const style = hunkHeaderStyle(null, styles);

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

test "side-by-side staged hunk colors current chrome without dimming body" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(100, 5);
    defer ts.deinit();

    var palette = theme.Palette.default();
    palette.colors[@intFromEnum(theme.Role.staged)] = .{ .rgb = .{ 41, 42, 43 } };
    palette.colors[@intFromEnum(theme.Role.diff_hunk)] = .{ .rgb = .{ 51, 52, 53 } };
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/a b/a",
        .old_path = "a/a",
        .new_path = "b/a",
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

    try renderFile(&ts.surface, file, .{
        .requested_mode = .side_by_side,
        .highlighted_hunk = 0,
        .hunk_stages = .all_staged,
        .palette = palette,
    });

    try ts.expectCellText(1, body_start_row, "╭");
    try ts.expectCellText(1, body_start_row + 1, "╰");
    try std.testing.expect(ts.surface.readCell(1, body_start_row).?.style.fg.eql(palette.color(.staged)));
    try std.testing.expect(ts.surface.readCell(2, body_start_row).?.style.fg.eql(palette.color(.staged)));
    const geometry = sideBySideGeometry(bodyWidth(100));
    const old_text_col = cursor_gutter_width + geometry.old.col + lineTextStart(true, .side_by_side);
    const new_text_col = cursor_gutter_width + geometry.new.col + lineTextStart(true, .side_by_side);
    try std.testing.expect(!ts.surface.readCell(old_text_col, body_start_row + 1).?.style.dim);
    try std.testing.expect(!ts.surface.readCell(new_text_col, body_start_row + 1).?.style.dim);
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
        .hunk_stages = .all_staged,
    });

    const guide_cell = ts.surface.readCell(1, 5).?;
    const header_cell = ts.surface.readCell(2, 5).?;
    try ts.expectCellText(1, 5, "╭");
    try std.testing.expect(guide_cell.style.dim);
    try std.testing.expect(guide_cell.style.fg.eql(RenderStyles.fromPalette(.default()).staged_hunk_guide.fg));
    try std.testing.expect(header_cell.style.fg.eql(RenderStyles.fromPalette(.default()).staged_hunk_header.fg));
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
        .hunk_stages = .all_staged,
        .folded_hunks = &.{true},
    });

    try ts.expectCellText(1, 3, " ");
    try ts.expectCellText(2, 3, "▸");
    try std.testing.expect(ts.surface.readCell(2, 3).?.style.fg.eql(theme.Palette.default().color(.staged)));
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

    const bytes = try std.testing.allocator.dupe(u8, "const value = 1;\npub fn main() void {}");
    var source = try repository_source.Document.initOwned(std.testing.allocator, bytes, .init(bytes));
    defer source.deinit(std.testing.allocator);
    try renderGeneratedAddedFile(&ts.surface, "src/new.zig", &source, .{ .requested_mode = .side_by_side });

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

    const bytes = try std.testing.allocator.dupe(u8, "one\ntwo");
    var source = try repository_source.Document.initOwned(std.testing.allocator, bytes, content_fingerprint.Fingerprint.init(bytes));
    defer source.deinit(std.testing.allocator);
    try renderGeneratedAddedFile(&ts.surface, "src/new.zig", &source, .{
        .requested_mode = .unified,
        .cursor_offset = 1,
    });

    try ts.expectCellText(0, 3, " ");
    try ts.expectCellText(0, 4, "▌");
    try ts.expectCellText(14, 4, "t");
}

test "renderGeneratedAddedFile applies source syntax and hides plain added prefix" {
    const allocator = std.testing.allocator;
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 6);
    defer ts.deinit();
    const bytes = try allocator.dupe(u8, "const value = 1;\n// note");
    var source = try repository_source.Document.initOwned(allocator, bytes, .init(bytes));
    defer source.deinit(allocator);
    var spans = source_syntax.SourceSpans{
        .line_entries = try allocator.dupe(source_syntax.LineEntry, &.{
            .{ .line_index = 0, .span_start = 0, .span_count = 1 },
            .{ .line_index = 1, .span_start = 1, .span_count = 1 },
        }),
        .spans = try allocator.dupe(syntax_token.TokenSpan, &.{
            .{ .start = 0, .end = 5, .role = .keyword },
            .{ .start = 0, .end = 7, .role = .comment },
        }),
    };
    defer spans.deinit(allocator);

    try renderGeneratedAddedFile(&ts.surface, "src/new.zig", &source, .{
        .requested_mode = .unified,
        .source_syntax_spans = spans,
        .source_has_visible_syntax = true,
    });

    try ts.expectCellText(12, 3, " ");
    try ts.expectCellText(12, 4, " ");
    const keyword = ts.surface.readCell(14, 3).?;
    try std.testing.expect(keyword.style.fg.eql(theme.Palette.default().color(.accent)));
    try std.testing.expect(keyword.style.bg.eql(theme.Palette.default().color(.diff_added_bg)));
    const identifier = ts.surface.readCell(20, 3).?;
    try std.testing.expect(identifier.style.fg.eql(.default));
    const comment = ts.surface.readCell(14, 4).?;
    try std.testing.expect(comment.style.fg.eql(theme.Palette.default().color(.muted)));
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

test "parsed file header keeps semantic statistics and metadata when inactive" {
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
    const palette = headerFocusTestPalette();

    var active: chasen.testing.TestSurface = undefined;
    try active.init(80, 6);
    defer active.deinit();
    try renderFile(&active.surface, file, .{ .pane_active = true, .palette = palette });

    var inactive: chasen.testing.TestSurface = undefined;
    try inactive.init(80, 6);
    defer inactive.deinit();
    try renderFile(&inactive.surface, file, .{ .pane_active = false, .palette = palette });

    try expectFocusStableHeaderStyleMatrix(
        &active.surface,
        &inactive.surface,
        fileHeaderLayout(80, displayPath(file), file, .unified, bodyWidth(80)),
        "+1",
        "-1",
        palette,
    );
}

test "generated file header keeps semantic statistics and metadata when inactive" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, "one\ntwo");
    var source = try repository_source.Document.initOwned(allocator, bytes, .init(bytes));
    defer source.deinit(allocator);
    const palette = headerFocusTestPalette();

    var active: chasen.testing.TestSurface = undefined;
    try active.init(80, 6);
    defer active.deinit();
    try renderGeneratedAddedFile(&active.surface, "src/new.zig", &source, .{ .pane_active = true, .palette = palette });

    var inactive: chasen.testing.TestSurface = undefined;
    try inactive.init(80, 6);
    defer inactive.deinit();
    try renderGeneratedAddedFile(&inactive.surface, "src/new.zig", &source, .{ .pane_active = false, .palette = palette });

    try expectFocusStableHeaderStyleMatrix(
        &active.surface,
        &inactive.surface,
        generatedHeaderLayout(80, "src/new.zig", source.contentLineCount(), .unified, bodyWidth(80)),
        "+2",
        "-0",
        palette,
    );
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
    try std.testing.expect(!ts.surface.readCell(79, 4).?.style.bg.eql(theme.Palette.default().color(.pane_cursor_bg)));
}

fn reviewCursorTestPalette() theme.Palette {
    var palette: theme.Palette = .default();
    palette.colors[@intFromEnum(theme.Role.pane_cursor_bg)] = .{ .rgb = .{ 1, 2, 3 } };
    palette.colors[@intFromEnum(theme.Role.diff_cursor)] = .{ .rgb = .{ 4, 5, 6 } };
    palette.colors[@intFromEnum(theme.Role.pane_active_line_number)] = .{ .rgb = .{ 7, 8, 9 } };
    palette.colors[@intFromEnum(theme.Role.diff_context_bg)] = .{ .rgb = .{ 10, 11, 12 } };
    palette.colors[@intFromEnum(theme.Role.diff_added_bg)] = .{ .rgb = .{ 13, 14, 15 } };
    palette.colors[@intFromEnum(theme.Role.diff_removed_bg)] = .{ .rgb = .{ 16, 17, 18 } };
    return palette;
}

test "review diff cursor composes unified selection inside pane chrome" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 5);
    defer ts.deinit();

    const palette = reviewCursorTestPalette();
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/a b/a",
        .old_path = "a/a",
        .new_path = "b/a",
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

    try renderFile(&ts.surface, file, .{
        .requested_mode = .unified,
        .cursor_offset = 1,
        .hunk_stages = .all_staged,
        .palette = palette,
        .selection = .{
            .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
            .side = .new,
            .start = .{ .hunk_index = 0, .line_index = 0 },
            .end = .{ .hunk_index = 0, .line_index = 0 },
        },
    });

    const row: u16 = body_start_row + 1;
    const pane_bg = palette.color(.pane_cursor_bg);
    const selection_bg = palette.color(.diff_cursor);
    try std.testing.expect(ts.surface.readCell(0, row).?.style.bg.eql(pane_bg));
    try std.testing.expect(ts.surface.readCell(1, row).?.style.bg.eql(pane_bg));
    try std.testing.expect(ts.surface.readCell(2, row).?.style.bg.eql(selection_bg));
    const old_number = ts.surface.readCell(5, row).?;
    const new_number = ts.surface.readCell(10, row).?;
    try std.testing.expect(old_number.style.bg.eql(selection_bg));
    try std.testing.expect(new_number.style.bg.eql(selection_bg));
    try std.testing.expect(old_number.style.fg.eql(palette.color(.pane_active_line_number)));
    try std.testing.expect(new_number.style.fg.eql(palette.color(.pane_active_line_number)));
    const text = ts.surface.readCell(cursor_gutter_width + lineTextStart(true, .unified), row).?;
    try std.testing.expect(text.style.bg.eql(selection_bg));
    try std.testing.expect(!text.style.dim);
    try std.testing.expect(ts.surface.readCell(79, row).?.style.bg.eql(selection_bg));
    try std.testing.expect(!ts.surface.readCell(79, body_start_row).?.style.bg.eql(pane_bg));
}

test "review diff cursor keeps side-by-side separator outside selected side" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(100, 5);
    defer ts.deinit();

    const palette = reviewCursorTestPalette();
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/a b/a",
        .old_path = "a/a",
        .new_path = "b/a",
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
    const geometry = sideBySideGeometry(bodyWidth(100));

    try renderFile(&ts.surface, file, .{
        .requested_mode = .side_by_side,
        .cursor_offset = 1,
        .palette = palette,
        .selection = .{
            .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
            .side = .old,
            .start = .{ .hunk_index = 0, .line_index = 0 },
            .end = .{ .hunk_index = 0, .line_index = 0 },
        },
    });

    const row: u16 = body_start_row + 1;
    const pane_bg = palette.color(.pane_cursor_bg);
    const selection_bg = palette.color(.diff_cursor);
    const old_start = cursor_gutter_width + geometry.old.col;
    const separator = cursor_gutter_width + geometry.separator_col;
    const new_start = cursor_gutter_width + geometry.new.col;
    try std.testing.expect(ts.surface.readCell(0, row).?.style.bg.eql(pane_bg));
    try std.testing.expect(ts.surface.readCell(1, row).?.style.bg.eql(pane_bg));
    try std.testing.expect(ts.surface.readCell(old_start, row).?.style.bg.eql(selection_bg));
    try std.testing.expect(ts.surface.readCell(separator - 1, row).?.style.bg.eql(selection_bg));
    try std.testing.expect(ts.surface.readCell(separator, row).?.style.bg.eql(pane_bg));
    try std.testing.expect(ts.surface.readCell(new_start, row).?.style.bg.eql(pane_bg));
    try std.testing.expect(ts.surface.readCell(99, row).?.style.bg.eql(pane_bg));
    try std.testing.expect(ts.surface.readCell(old_start + 3, row).?.style.fg.eql(palette.color(.pane_active_line_number)));
    try std.testing.expect(ts.surface.readCell(new_start + 3, row).?.style.fg.eql(palette.color(.pane_active_line_number)));
}

test "review diff cursor restores parsed signs from cross-row syntax authority" {
    const allocator = std.testing.allocator;
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/a b/a",
        .old_path = "a/a",
        .new_path = "b/a",
        .metadata = &.{},
        .hunks = &.{.{
            .old_start = 1,
            .old_count = 2,
            .new_start = 1,
            .new_count = 2,
            .section = "",
            .lines = &.{
                .{ .kind = .removed, .text = "", .old_line = 1 },
                .{ .kind = .removed, .text = "old", .old_line = 2 },
                .{ .kind = .added, .text = "", .new_line = 1 },
                .{ .kind = .added, .text = "new", .new_line = 2 },
            },
        }},
    };
    const hunk_line_counts = [_]usize{4};
    const files = [_]syntax_provider.FileShape{.{ .hunk_line_counts = &hunk_line_counts }};
    var spans = try syntax_provider.allocateEmpty(allocator, .{ .files = &files });
    defer spans.deinit(allocator);
    const old_spans = try allocator.dupe(syntax_token.TokenSpan, &.{.{ .start = 0, .end = 3, .role = .keyword }});
    const new_spans = try allocator.dupe(syntax_token.TokenSpan, &.{.{ .start = 0, .end = 3, .role = .string }});
    syntax_provider.putLineSpans(&spans, .{ .file_index = 0, .hunk_index = 0, .line_index = 1, .side = .old }, .{ .spans = old_spans });
    syntax_provider.putLineSpans(&spans, .{ .file_index = 0, .hunk_index = 0, .line_index = 3, .side = .new }, .{ .spans = new_spans });

    var removed: chasen.testing.TestSurface = undefined;
    try removed.init(80, 8);
    defer removed.deinit();
    try renderFile(&removed.surface, file, .{ .requested_mode = .unified, .cursor_offset = 1, .syntax = .initDirect(&spans, 0) });
    try removed.expectCellText(12, 4, "-");
    try removed.expectCellText(12, 5, " ");
    try std.testing.expect(removed.surface.readCell(12, 4).?.style.bg.eql(theme.Palette.default().color(.pane_cursor_bg)));

    var added: chasen.testing.TestSurface = undefined;
    try added.init(80, 8);
    defer added.deinit();
    try renderFile(&added.surface, file, .{ .requested_mode = .unified, .cursor_offset = 3, .syntax = .initDirect(&spans, 0) });
    try added.expectCellText(12, 6, "+");
    try added.expectCellText(12, 7, " ");

    var split: chasen.testing.TestSurface = undefined;
    try split.init(100, 6);
    defer split.deinit();
    try renderFile(&split.surface, file, .{ .requested_mode = .side_by_side, .cursor_offset = 1, .syntax = .initDirect(&spans, 0) });
    const geometry = sideBySideGeometry(bodyWidth(100));
    try split.expectCellText(cursor_gutter_width + geometry.old.col + lineLayout(true, .side_by_side).prefix_col, 4, "-");
    try split.expectCellText(cursor_gutter_width + geometry.new.col + lineLayout(true, .side_by_side).prefix_col, 4, "+");
    try split.expectCellText(cursor_gutter_width + geometry.old.col + lineLayout(true, .side_by_side).prefix_col, 5, " ");
    try split.expectCellText(cursor_gutter_width + geometry.new.col + lineLayout(true, .side_by_side).prefix_col, 5, " ");
}

test "review diff cursor restores generated sign from cross-row syntax authority" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, "\nconst value = 1;");
    var source = try repository_source.Document.initOwned(allocator, bytes, .init(bytes));
    defer source.deinit(allocator);
    var spans = source_syntax.SourceSpans{
        .line_entries = try allocator.dupe(source_syntax.LineEntry, &.{.{ .line_index = 1, .span_start = 0, .span_count = 1 }}),
        .spans = try allocator.dupe(syntax_token.TokenSpan, &.{.{ .start = 0, .end = 5, .role = .keyword }}),
    };
    defer spans.deinit(allocator);

    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 5);
    defer ts.deinit();
    try renderGeneratedAddedFile(&ts.surface, "new.zig", &source, .{
        .cursor_offset = 0,
        .source_syntax_spans = spans,
        .source_has_visible_syntax = true,
    });

    try ts.expectCellText(12, 3, "+");
    try ts.expectCellText(12, 4, " ");
    try std.testing.expect(ts.surface.readCell(12, 3).?.style.bg.eql(theme.Palette.default().color(.pane_cursor_bg)));
    try std.testing.expect(ts.surface.readCell(14, 4).?.style.fg.eql(theme.Palette.default().color(.accent)));
}

test "review diff cursor covers metadata binary and hunk rows only while active" {
    const palette = reviewCursorTestPalette();
    const text_file: diff_parser.FileDiff = .{
        .header = "diff --git a/a b/a",
        .old_path = "a/a",
        .new_path = "b/a",
        .metadata = &.{"new file mode 100644"},
        .hunks = &.{.{
            .old_start = 0,
            .old_count = 0,
            .new_start = 1,
            .new_count = 1,
            .section = "",
            .lines = &.{.{ .kind = .added, .text = "new", .new_line = 1 }},
        }},
    };
    const binary_file: diff_parser.FileDiff = .{
        .header = "diff --git a/image.bin b/image.bin",
        .metadata = &.{"new file mode 100644"},
        .hunks = &.{},
        .is_binary = true,
    };

    var metadata: chasen.testing.TestSurface = undefined;
    try metadata.init(80, 6);
    defer metadata.deinit();
    try renderFile(&metadata.surface, text_file, .{ .cursor_offset = 0, .palette = palette });
    try expectBgRange(&metadata.surface, body_start_row, 0, 80, palette.color(.pane_cursor_bg));

    var hunk: chasen.testing.TestSurface = undefined;
    try hunk.init(80, 6);
    defer hunk.deinit();
    try renderFile(&hunk.surface, text_file, .{ .cursor_offset = 1, .palette = palette, .hunk_stages = .all_staged });
    try expectBgRange(&hunk.surface, body_start_row + 1, 0, 80, palette.color(.pane_cursor_bg));
    // A hunk header without highlighted_hunk remains metadata-dim; this is
    // cursor ownership, not stage-owned body dimming.
    try std.testing.expect(hunk.surface.readCell(2, body_start_row + 1).?.style.dim);

    var binary: chasen.testing.TestSurface = undefined;
    try binary.init(80, 5);
    defer binary.deinit();
    try renderFile(&binary.surface, binary_file, .{ .cursor_offset = 1, .palette = palette });
    try expectBgRange(&binary.surface, body_start_row + 1, 0, 80, palette.color(.pane_cursor_bg));

    var inactive: chasen.testing.TestSurface = undefined;
    try inactive.init(80, 6);
    defer inactive.deinit();
    try renderFile(&inactive.surface, text_file, .{ .cursor_offset = 2, .pane_active = false, .palette = palette });
    try std.testing.expect(!inactive.surface.readCell(79, body_start_row + 2).?.style.bg.eql(palette.color(.pane_cursor_bg)));
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
