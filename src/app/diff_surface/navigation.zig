//! Page-independent diff navigation model helpers.
//!
//! Pages retain their public `View` / `Controller` shapes and delegate these
//! pure operations through compatibility adapters. This module must not import
//! a page namespace.

const std = @import("std");
const layout = @import("layout.zig");
const context = @import("../../context.zig");
const diff_hunk_projection = @import("../../diff/hunk_projection.zig");
const diff_parser = @import("../../diff/parser.zig");
const diff_render = @import("../../diff/render.zig");
const diff_selection = @import("../../diff/selection.zig");
const diff_view_model = @import("../../diff/view_model.zig");
const file_tree = @import("../../file_tree.zig");
const loaded_diff = @import("../../loaded_diff.zig");
const text_projection = @import("../../text/projection.zig");

const LoadedDiff = loaded_diff.LoadedDiff;

pub const ParsedSelectionTarget = struct {
    file: diff_parser.FileDiff,
    line_index: diff_view_model.RenderedLineIndex,
    folded_hunks: []const bool,
    identity: diff_selection.Identity,
};

pub const SelectionRegion = struct {
    side: diff_selection.Side,
    mode: diff_selection.Mode,
    text_cell: usize,
    leading_boundary: bool = false,
};

pub const ParsedMouseLine = struct {
    hunk_index: usize,
    line_index: usize,
    line: diff_parser.DiffLine,
    region: SelectionRegion,
};

/// Converts projection-owned index membership into the renderer's explicit
/// per-hunk contract.
pub fn projectedHunkStagePresentation(
    allocator: std.mem.Allocator,
    states: []const diff_hunk_projection.HunkStageState,
) !diff_render.HunkStagePresentation {
    if (states.len == 0) return .{ .per_hunk = &.{} };
    const presentation = try allocator.alloc(diff_render.HunkStageState, states.len);
    for (states, presentation) |state, *item| {
        item.* = if (state == .staged) .staged else .unstaged;
    }
    return .{ .per_hunk = presentation };
}

pub fn findNodeBySidebarIdentity(
    loaded: *const LoadedDiff,
    identity: context.SidebarIdentity,
) ?usize {
    for (loaded.tree.nodes, 0..) |node, index| {
        switch (identity) {
            .repo_root => if (node.kind == .repo_root) return index,
            .directory => |path| {
                if (node.kind == .directory and std.mem.eql(u8, node.path, path)) return index;
            },
            .file => |path_key| {
                if (node.kind != .file) continue;
                const node_key = if (node.path_key.len > 0) node.path_key else node.path;
                if (std.mem.eql(u8, node_key, path_key)) return index;
            },
        }
    }
    return null;
}

pub fn findFileNodeByPathKey(loaded: *const LoadedDiff, path_key: []const u8) ?usize {
    for (loaded.tree.nodes, 0..) |node, index| {
        if (node.kind != .file) continue;
        const node_key = if (node.path_key.len > 0) node.path_key else node.path;
        if (std.mem.eql(u8, node_key, path_key)) return index;
    }
    return null;
}

pub fn nearestVisibleFileNode(loaded: *const LoadedDiff, visible_row: usize) ?usize {
    var row = visible_row;
    while (row < loaded.visibleNodeCount()) : (row += 1) {
        const node_index = loaded.visibleNodeAt(row) orelse continue;
        if (loaded.tree.nodes[node_index].kind == .file) return node_index;
    }

    row = @min(visible_row, loaded.visibleNodeCount() - 1);
    while (true) {
        const node_index = loaded.visibleNodeAt(row) orelse return null;
        if (loaded.tree.nodes[node_index].kind == .file) return node_index;
        if (row == 0) break;
        row -= 1;
    }
    return null;
}

pub fn parsedMouseLine(
    target: ParsedSelectionTarget,
    body_col: u16,
    body_width: u16,
    display_mode: diff_render.DisplayMode,
    offset: usize,
    line_numbers: bool,
    locked: ?diff_selection.DragSelection,
) ?ParsedMouseLine {
    var rows = if (target.line_index.mode == display_mode and target.line_index.hunk_offsets.len == target.file.hunks.len)
        diff_view_model.BodyRowIterator.initAtWithFolded(target.file, display_mode, target.line_index, offset, target.folded_hunks)
    else
        diff_view_model.BodyRowIterator.initWithFolded(target.file, display_mode, target.folded_hunks);
    var skipped: usize = if (target.line_index.hunk_offsets.len == target.file.hunks.len) offset else 0;
    var row = rows.next() orelse return null;
    while (skipped < offset) : (skipped += 1) row = rows.next() orelse return null;
    const hunk_index = rows.currentHunkIndex() orelse return null;
    return switch (row) {
        .unified_line => |line| blk: {
            const line_index = rows.currentUnifiedLineIndex() orelse return null;
            const region = selectionRegionForUnified(body_col, line_numbers, line, locked) orelse return null;
            break :blk .{ .hunk_index = hunk_index, .line_index = line_index, .line = line, .region = region };
        },
        .side_by_side => blk: {
            const indexed = rows.currentSideBySideRow() orelse return null;
            const geometry = diff_render.sideBySideGeometry(body_width);
            const side = geometry.sideAt(body_col) orelse return null;
            if (locked) |selection| if (selection.side != side) return null;
            const side_region = switch (side) {
                .old => geometry.old,
                .new => geometry.new,
            };
            const local_col = body_col - side_region.col;
            const text_col = diff_render.lineTextStart(line_numbers, .side_by_side);
            const mode: diff_selection.Mode = if (locked) |selection| selection.mode else if (local_col < text_col) .line else .character;
            const text_cell: usize = if (local_col > text_col) local_col - text_col else 0;
            const selected_line = indexedLineForSide(indexed, side) orelse return null;
            break :blk .{
                .hunk_index = hunk_index,
                .line_index = selected_line.line_index,
                .line = selected_line.line,
                .region = .{
                    .side = side,
                    .mode = mode,
                    .text_cell = text_cell,
                    .leading_boundary = locked != null and mode == .character and local_col < text_col,
                },
            };
        },
        .metadata, .binary_marker, .hunk_header => null,
    };
}

pub fn indexedLineForSide(row: diff_view_model.SideBySideIndexedRow, side: diff_selection.Side) ?diff_view_model.IndexedDiffLine {
    return switch (row) {
        .single => |line| if (diff_selection.lineVisibleOnSide(line.line, side)) line else null,
        .paired => |pair| switch (side) {
            .old => pair.removed,
            .new => pair.added,
        },
    };
}

pub fn selectionRegionForUnified(body_col: u16, line_numbers: bool, line: diff_parser.DiffLine, locked: ?diff_selection.DragSelection) ?SelectionRegion {
    const text_col = diff_render.lineTextStart(line_numbers, .unified);
    const side: diff_selection.Side = if (locked) |selection|
        selection.side
    else if (line_numbers and body_col < 5)
        .old
    else if (line_numbers and body_col < 10)
        .new
    else switch (line.kind) {
        .removed => .old,
        .added, .context => .new,
        .metadata => return null,
    };
    if (!diff_selection.lineVisibleOnSide(line, side)) return null;
    const mode: diff_selection.Mode = if (locked) |selection| selection.mode else if (body_col < text_col) .line else .character;
    return .{
        .side = side,
        .mode = mode,
        .text_cell = if (body_col > text_col) body_col - text_col else 0,
        .leading_boundary = locked != null and mode == .character and body_col < text_col,
    };
}

pub fn selectionRegionForGenerated(body_col: u16, body_width: u16, display_mode: diff_render.DisplayMode, line_numbers: bool, locked: ?diff_selection.DragSelection) ?SelectionRegion {
    if (locked) |selection| if (selection.side != .new) return null;
    const local_col = switch (display_mode) {
        .unified => body_col,
        .side_by_side => blk: {
            const geometry = diff_render.sideBySideGeometry(body_width);
            if (geometry.sideAt(body_col) != .new) return null;
            break :blk body_col - geometry.new.col;
        },
    };
    const text_col = diff_render.lineTextStart(line_numbers, if (display_mode == .unified) .unified else .side_by_side);
    const mode: diff_selection.Mode = if (locked) |selection| selection.mode else if (local_col < text_col) .line else .character;
    return .{
        .side = .new,
        .mode = mode,
        .text_cell = if (local_col > text_col) local_col - text_col else 0,
        .leading_boundary = locked != null and mode == .character and local_col < text_col,
    };
}

pub fn pointForTextCell(hunk_index: usize, line_index: usize, text: []const u8, mode: diff_selection.Mode, cell: usize) ?diff_selection.Point {
    if (mode == .line) return diff_selection.pointFromLine(hunk_index, line_index);
    return switch (text_projection.hitAtDisplayCell(text, cell) orelse return null) {
        .token => |token| diff_selection.pointFromToken(hunk_index, line_index, token),
        .boundary => |boundary| diff_selection.pointFromBoundary(hunk_index, line_index, boundary.offset),
    };
}

pub fn contentWidth(width: u16) u16 {
    return layout.diffContentWidth(width);
}

pub fn sidebarWidth(total_width: u16, preferred_width: ?u16) u16 {
    return layout.sidebarWidth(total_width, preferred_width);
}

pub fn maxHorizontalScrollForBodyRow(body_row: diff_view_model.BodyRow, pane_width: u16, line_numbers: bool) usize {
    return switch (body_row) {
        .unified_line => |line| maxHorizontalScrollForText(line.text, visibleTextWidth(pane_width, diff_render.lineTextStart(line_numbers, .unified))),
        .side_by_side => |side_row| maxHorizontalScrollForSideBySideRow(side_row, pane_width, line_numbers),
        else => 0,
    };
}

pub fn maxHorizontalScrollForSideBySideRow(side_row: diff_view_model.SideBySideRow, pane_width: u16, line_numbers: bool) usize {
    const gutter_col = pane_width / 2;
    const new_col = gutter_col + 1;
    const text_col = diff_render.lineTextStart(line_numbers, .side_by_side);
    const old_text_width: u16 = visibleTextWidth(gutter_col, text_col);
    const new_width: u16 = if (pane_width > new_col) pane_width - new_col else 0;
    const new_text_width: u16 = visibleTextWidth(new_width, text_col);
    var max_scroll: usize = 0;
    switch (side_row) {
        .single => |line| {
            switch (line.kind) {
                .added => max_scroll = @max(max_scroll, maxHorizontalScrollForText(line.text, new_text_width)),
                .context => {
                    max_scroll = @max(max_scroll, maxHorizontalScrollForText(line.text, old_text_width));
                    max_scroll = @max(max_scroll, maxHorizontalScrollForText(line.text, new_text_width));
                },
                else => max_scroll = @max(max_scroll, maxHorizontalScrollForText(line.text, old_text_width)),
            }
        },
        .paired => |pair| {
            if (pair.removed) |line| max_scroll = @max(max_scroll, maxHorizontalScrollForText(line.text, old_text_width));
            if (pair.added) |line| max_scroll = @max(max_scroll, maxHorizontalScrollForText(line.text, new_text_width));
        },
    }
    return max_scroll;
}

pub fn visibleTextWidth(total_width: u16, text_col: u16) u16 {
    return if (total_width > text_col) total_width - text_col else 0;
}

pub fn maxHorizontalScrollForText(text: []const u8, visible_width: u16) usize {
    const width = text_projection.displayWidth(text) catch return 0;
    if (width <= visible_width) return 0;
    return width - visible_width;
}
