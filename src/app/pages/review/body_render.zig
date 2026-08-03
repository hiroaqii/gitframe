//! Review-owned rendering for non-primary diff bodies.
//!
//! Both the current Review view and the page-independent `BodyResolver`
//! adapter delegate here. Keeping the presentation in one module prevents the
//! resolver seam from becoming a second rendering authority.

const std = @import("std");
const chasen = @import("chasen");
const draw = @import("draw");
const diff_parser = @import("../../../diff/parser.zig");
const diff_render = @import("../../../diff/render.zig");
const diff_syntax_view = @import("../../../diff/syntax_view.zig");
const diff_view_model = @import("../../../diff/view_model.zig");
const file_tree = @import("../../../file_tree.zig");
const git_status = @import("../../../git/status.zig");
const review_projection = @import("../../review_projection.zig");
const diff_surface = @import("../../diff_surface.zig");
const theme = @import("theme");

pub const ParsedBody = struct {
    file: diff_parser.FileDiff,
    line_index: ?diff_view_model.RenderedLineIndex,
    folded_hunks: []const bool,
    hunk_stages: diff_render.HunkStagePresentation,
    syntax: diff_syntax_view.View,
};

pub fn renderParsed(body: ParsedBody, args: diff_surface.RenderProjectedBodyArgs) !void {
    try diff_render.renderFile(args.surface, body.file, .{
        .requested_mode = args.requested_mode,
        .scroll = args.scroll,
        .horizontal_scroll = args.horizontal_scroll,
        .pane_active = args.pane_active,
        .line_numbers = args.line_numbers,
        .highlighted_hunk = args.highlighted_hunk,
        .cursor_offset = args.cursor_offset,
        .hunk_stages = body.hunk_stages,
        .line_index = body.line_index,
        .folded_hunks = body.folded_hunks,
        .palette = args.palette,
        .syntax = body.syntax,
        .selection = args.selection,
        .header_selection = args.header_selection,
    });
}

pub fn renderGenerated(bundle: *const review_projection.GeneratedFileBundle, args: diff_surface.RenderProjectedBodyArgs) !void {
    try diff_render.renderGeneratedAddedFile(args.surface, bundle.path, &bundle.source, .{
        .requested_mode = args.requested_mode,
        .scroll = args.scroll,
        .horizontal_scroll = args.horizontal_scroll,
        .pane_active = args.pane_active,
        .line_numbers = args.line_numbers,
        .cursor_offset = args.cursor_offset,
        .hunk_stages = .all_unstaged,
        .palette = args.palette,
        .header_selection = args.header_selection,
        .source_syntax_spans = switch (bundle.decoration) {
            .decorated => |decorated| decorated.spans,
            .eligible, .terminal_plain => .empty(),
        },
        .source_has_visible_syntax = bundle.decoration.hasVisibleSyntax(),
        .selection = args.selection,
    });
}

pub fn renderStatus(path: []const u8, message: []const u8, stats: ?file_tree.Stats, args: diff_surface.RenderProjectedBodyArgs) !void {
    try drawTitlePath(args.surface, path, stats, args.palette);
    try draw.copyClippedTextAt(args.surface, 0, 2, message, .{
        .fg = args.palette.color(.muted),
        .dim = !args.pane_active,
    });
}

/// Review-local status-only fallback. This is intentionally not part of the
/// non-primary resolver callback contract.
pub fn renderStatusOnlyFallback(
    surface: *chasen.Surface,
    entry: git_status.StatusEntry,
    stats: ?file_tree.Stats,
    active: bool,
    palette: theme.Palette,
) !void {
    const path = entry.canonicalPathKey() orelse entry.path;
    try drawTitlePath(surface, path, stats, palette);
    const status_text = try std.fmt.allocPrint(
        surface.frameAllocator(),
        "status: {s}{s}",
        .{ statusName(entry.index), statusSuffix(entry) },
    );
    try draw.copyClippedTextAt(surface, 0, 2, status_text, .{
        .fg = palette.color(.muted),
        .dim = !active,
    });
    switch (file_tree.stagePresenceFromEntry(entry)) {
        .staged_only => {
            try draw.copyClippedTextAt(surface, 0, 4, "This file is staged.", .{ .fg = palette.color(.muted), .dim = !active });
            try draw.copyClippedTextAt(surface, 0, 5, "Loading staged diff preview.", .{ .fg = palette.color(.muted), .dim = !active });
        },
        else => {
            try draw.copyClippedTextAt(surface, 0, 4, "No diff is available for this file yet.", .{ .fg = palette.color(.muted), .dim = !active });
            try draw.copyClippedTextAt(surface, 0, 5, "Loading generated review preview if available.", .{ .fg = palette.color(.muted), .dim = !active });
        },
    }
}

pub fn drawTitlePath(surface: *chasen.Surface, path: []const u8, stats: ?file_tree.Stats, palette: theme.Palette) !void {
    if (stats) |line_stats| {
        if (line_stats.added != 0 or line_stats.removed != 0) {
            const suffix = try std.fmt.allocPrint(surface.frameAllocator(), " +{d} -{d}", .{ line_stats.added, line_stats.removed });
            const suffix_width = chasen.text.displayWidth(suffix);
            const path_width = surface.size().width -| @as(u16, @intCast(@min(suffix_width, std.math.maxInt(u16))));
            if (path_width > 8) {
                var path_surface = surface.child(.{ .col = 0, .row = 0, .width = path_width, .height = 1 });
                try draw.copyTailClippedTextAt(&path_surface, 0, 0, path, paneTitleStyle(palette));
                try drawStatusLineStats(surface, @intCast(path_width), line_stats, palette);
                return;
            }
        }
    }
    try draw.copyTailClippedTextAt(surface, 0, 0, path, paneTitleStyle(palette));
}

pub fn paneTitleStyle(palette: theme.Palette) chasen.TextStyle {
    return palette.boldStyle(.accent);
}

fn drawStatusLineStats(surface: *chasen.Surface, col: u16, stats: file_tree.Stats, palette: theme.Palette) !void {
    var cursor = col;
    const metadata_style = palette.style(.muted);
    try draw.copyClippedTextAt(surface, cursor, 0, " ", metadata_style);
    cursor +|= 1;
    const added = try std.fmt.allocPrint(surface.frameAllocator(), "+{d}", .{stats.added});
    try draw.copyClippedTextAt(surface, cursor, 0, added, .{ .fg = palette.color(.success), .bold = true });
    cursor +|= @intCast(chasen.text.displayWidth(added));
    if (cursor < surface.size().width) {
        try draw.copyClippedTextAt(surface, cursor, 0, " ", metadata_style);
        cursor +|= 1;
    }
    const removed = try std.fmt.allocPrint(surface.frameAllocator(), "-{d}", .{stats.removed});
    try draw.copyClippedTextAt(surface, cursor, 0, removed, .{ .fg = palette.color(.danger), .bold = true });
}

fn statusName(status: git_status.StatusCode) []const u8 {
    return switch (status) {
        .unmodified => "unmodified",
        .modified => "modified",
        .added => "added",
        .deleted => "deleted",
        .renamed => "renamed",
        .copied => "copied",
        .untracked => "untracked",
        .ignored => "ignored",
        .unmerged => "unmerged",
        .unknown => "unknown",
    };
}

fn statusSuffix(entry: git_status.StatusEntry) []const u8 {
    if (entry.isConflict()) return " (conflict)";
    return "";
}
