//! Changes-owned rendering for non-primary diff bodies.
//!
//! Both the current Changes view and the page-independent `BodyResolver`
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
const changes_projection = @import("../../changes_projection.zig");
const diff_surface = @import("../../diff_surface.zig");
const diff_surface_view = @import("../../diff_surface/view.zig");
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
        .display_mode_toggle_key = args.display_mode_toggle_key,
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

pub fn renderGenerated(bundle: *const changes_projection.GeneratedFileBundle, args: diff_surface.RenderProjectedBodyArgs) !void {
    try diff_render.renderGeneratedAddedFile(args.surface, bundle.path, &bundle.source, .{
        .requested_mode = args.requested_mode,
        .display_mode_toggle_key = args.display_mode_toggle_key,
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
    return diff_surface_view.renderStatusBody(path, message, stats, args);
}

/// Changes-local status-only fallback. This is intentionally not part of the
/// non-primary resolver callback contract.
pub fn renderStatusOnlyFallback(
    surface: *chasen.Surface,
    entry: git_status.StatusEntry,
    stats: ?file_tree.Stats,
    active: bool,
    palette: theme.Palette,
) !void {
    const path = entry.canonicalPathKey() orelse entry.path;
    try diff_surface_view.drawStatusTitlePath(surface, path, stats, palette);
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
            try draw.copyClippedTextAt(surface, 0, 5, "Loading generated changes preview if available.", .{ .fg = palette.color(.muted), .dim = !active });
        },
    }
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
