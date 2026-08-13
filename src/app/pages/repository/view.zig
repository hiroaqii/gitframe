//! Complete Repository page rendering over immutable page-owned state.

const std = @import("std");
const chasen = @import("chasen");
const text_projection = @import("chasen_ui").text_projection;
const draw = @import("draw");
const keymap = @import("keymap");
const theme = @import("theme");
const branch_chrome = @import("../../branch_chrome.zig");
const git_branch_status = @import("../../../git/branch_status.zig");
const page_link = @import("../../page_link.zig");
const root_capability = @import("../../../repo/root_capability.zig");
const repository_page = @import("../repository.zig");
const repository_branch = @import("branch.zig");
const repository_input = @import("input.zig");
const repository_layout = @import("layout.zig");
const repository_tasks = @import("tasks.zig");
const model = @import("model.zig");
const selection = @import("selection.zig");
const source_header = @import("source_header.zig");
const source_geometry = @import("source_geometry.zig");
const source = @import("../../../repository/source.zig");
const repository_change_map = @import("../../../repository/change_map.zig");
const repository_change_index = @import("../../../repository/change_index.zig");
const source_syntax = @import("../../../syntax/source.zig");
const syntax_style = @import("../../../syntax/style.zig");
const syntax_token = @import("../../../syntax/token.zig");
const manifest = @import("../../../repository/manifest.zig");
const repository_tree = @import("../../../repository/tree.zig");
const selected_document = @import("../../../repository/document.zig");

const RepositoryPageState = repository_page.RepositoryPageState;
const repository_tab_width: usize = 4;
const oversized_display_message = std.fmt.comptimePrint(
    "File exceeds the {d} MiB display limit",
    .{selected_document.max_text_mib},
);

pub const ViewContext = struct {
    page_state: *const RepositoryPageState,
    palette: theme.Palette,
    keymap: keymap.Effective = .{},
    /// Borrowed active canonical root. The page owns object identity but does
    /// not duplicate path metadata merely to render its safe basename.
    repo_root: ?[]const u8 = null,
};

pub fn view(context: ViewContext, surface: *chasen.Surface) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;
    const state = context.page_state;
    if (state.incomingUnavailable()) |unavailable| {
        try drawIncomingUnavailable(unavailable, surface, context.palette);
        return;
    }
    if (state.file_search.mode and state.bundle == null) {
        try drawFileSearch(surface, null, &state.file_search, context.palette);
        return;
    }
    switch (state.load_state) {
        .idle, .no_repository, .failed => {
            const label: []const u8 = switch (state.load_state) {
                .idle => "Repository not loaded",
                .no_repository => "Repository required",
                .failed => if (state.status.text().len > 0) state.status.text() else "Repository manifest failed",
                else => unreachable,
            };
            draw.copyClippedTextAt(surface, 1, size.height / 2, label, context.palette.style(if (state.load_state == .failed) .danger else .muted)) catch {};
            return;
        },
        .loading => if (state.bundle == null or
            (state.file_visibility == .all and !state.file_search.mode))
        {
            draw.copyClippedTextAt(surface, 1, size.height / 2, "Loading repository files...", context.palette.style(.muted)) catch {};
            return;
        },
        .empty => {},
        .loaded => {},
    }

    const layout = repository_layout.bodyLayout(size, state.viewer.tree_width, state.viewer.tree_hidden);
    const tree = &state.bundle.?.tree;
    if (layout.tree_visible) {
        var left = surface.child(.{ .col = 0, .row = 0, .width = layout.tree_width, .height = size.height });
        try drawRepositoryBranchRow(state, &left, context.palette);
        const mode_header: []const u8 = if (state.file_visibility == .changed) "Files [changed]" else "Files [all]";
        var key_buffer: [16]u8 = undefined;
        var header_buffer: [64]u8 = undefined;
        const tree_header = if (context.keymap.display(.changed_file_filter, key_buffer[0..])) |binding|
            std.fmt.bufPrint(header_buffer[0..], "{s}  ({s}: toggle)", .{ mode_header, binding }) catch mode_header
        else
            mode_header;
        // Keep the current mode as the leading fact, while rendering the
        // shortcut hint as subdued chrome instead of another accent target.
        if (size.height > 2) {
            _ = left.copyTextAt(1, 2, mode_header, context.palette.boldStyle(.accent)) catch {};
            if (tree_header.len > mode_header.len) {
                var shortcut_style = context.palette.style(.muted);
                shortcut_style.dim = true;
                const shortcut_col: u16 = @intCast(1 + chasen.text.displayWidth(mode_header));
                _ = left.copyTextAt(shortcut_col, 2, tree_header[mode_header.len..], shortcut_style) catch {};
            }
        }
        if (layout.tree_width < size.width) {
            const separator_style: chasen.TextStyle = .{ .dim = true };
            var separator_row: u16 = 0;
            while (separator_row < size.height) : (separator_row += 1) _ = surface.borrowTextAt(layout.tree_width, separator_row, "│", separator_style);
        }

        const rows = layout.treeRows(size.height);
        const tree_message: ?[]const u8 = if (state.load_state == .empty and state.file_visibility == .all)
            "Repository has no tracked or non-ignored files"
        else if (state.load_state == .loading)
            "Loading changed files..."
        else if (state.file_visibility == .all)
            null
        else if (!treeStatusAvailable(state))
            if (state.freshness == .validating) "Loading changed files..." else "Changed-file status unavailable; press r to retry"
        else if (tree.visible_len == 0)
            "No changed files"
        else
            null;
        if (tree_message) |message| {
            if (rows > 0) try drawTreeProjectionRow(context, &left, tree, 0, layout.header_rows);
            if (rows > 1) draw.copyClippedTextAt(&left, 0, layout.header_rows + 1, message, context.palette.style(.muted)) catch {};
        } else {
            var body_row: usize = 0;
            while (body_row < rows and
                state.viewer.tree_vertical_scroll + body_row < state.tree_projection.visibleLen(tree)) : (body_row += 1)
            {
                const visible_index = state.viewer.tree_vertical_scroll + body_row;
                try drawTreeProjectionRow(
                    context,
                    &left,
                    tree,
                    visible_index,
                    @intCast(body_row + layout.header_rows),
                );
            }
        }
    }

    if (layout.source_width == 0) return;
    var right = surface.child(.{ .col = layout.source_col, .row = 0, .width = layout.source_width, .height = size.height });
    if (state.file_search.mode) {
        try drawFileSearch(&right, tree, &state.file_search, context.palette);
        return;
    }
    if (state.selected_path) |path| {
        try drawSourceHeader(
            &right,
            state.sourceHeaderPresentation().?,
            state.source_search,
            state.viewer.focus == .source,
            state.sourceHeaderSelected(),
            context.palette,
        );
        if (size.height > source_geometry.source_body_first_row) {
            try drawDocumentCheckpoint(state, path, &right, context.palette);
        }
    } else {
        draw.copyClippedTextAt(
            &right,
            1,
            0,
            "No file selected",
            context.palette.style(.muted),
        ) catch {};
    }
}

fn drawIncomingUnavailable(
    unavailable: *const page_link.RepositoryUnavailable,
    surface: *chasen.Surface,
    palette: theme.Palette,
) !void {
    const size = surface.size();
    draw.copyClippedTextAt(surface, 1, 0, "Repository target unavailable", palette.boldStyle(.danger)) catch {};
    if (size.height > 1) {
        const path = try manifest.displayWindowAlloc(surface.frameAllocator(), unavailable.path, 0, size.width -| 2);
        draw.copyClippedTextAt(surface, 1, 1, path.text(), palette.boldStyle(.accent)) catch {};
    }
    if (size.height > 2) {
        draw.copyClippedTextAt(surface, 1, 2, unavailable.reason.message(), palette.style(.muted)) catch {};
    }
}

fn treeStatusAvailable(state: *const RepositoryPageState) bool {
    return if (state.bundle) |bundle| bundle.status_available else false;
}

const RepositoryBranchRowTone = enum {
    fact,
    terminal,
};

const RepositoryBranchRowPresentation = struct {
    text: []const u8,
    tone: RepositoryBranchRowTone,
    stale_col: ?u16 = null,
};

/// Project Repository's independent branch owner into its read-only row-0
/// chrome. A snapshot must name the exact current physical root; otherwise a
/// retained label from another repository can never cross into presentation.
fn repositoryBranchRowPresentation(
    state: *const RepositoryPageState,
    allocator: std.mem.Allocator,
    available_width: u16,
) ?RepositoryBranchRowPresentation {
    const root_identity = state.root_identity orelse return null;
    const snapshot_identity = repository_branch.SnapshotIdentity{
        .repo_epoch = state.repo_epoch,
        .root_identity = root_identity,
    };
    if (state.branch.snapshot.matches(snapshot_identity)) {
        const formatted = branch_chrome.formatBaseLabel(
            allocator,
            state.branch.snapshot.status,
            available_width,
        ) catch return .{ .text = "branch", .tone = .fact };
        const failed = switch (state.branch.freshness) {
            .failed => true,
            else => false,
        };
        const stale_text = "  stale";
        const stale_width = chasen.text.displayWidth(stale_text);
        return .{
            // The frame/testing allocator owns the formatted text for the
            // same lifetime as this presentation value.
            .text = formatted.text,
            .tone = .fact,
            // Auxiliary failure never makes the label itself less legible.
            // Admit the subdued suffix only beside an unclipped complete base;
            // otherwise the base receives the whole row width.
            .stale_col = if (failed and
                !formatted.was_clipped and
                formatted.full_display_width +| stale_width <= available_width)
                formatted.full_display_width
            else
                null,
        };
    }

    return switch (state.branch.freshness) {
        .validating => .{ .text = "loading branch", .tone = .terminal },
        .failed => .{ .text = "branch unavailable", .tone = .terminal },
        .unavailable, .fresh => null,
    };
}

fn drawRepositoryBranchRow(
    state: *const RepositoryPageState,
    surface: *chasen.Surface,
    palette: theme.Palette,
) !void {
    const size = surface.size();
    if (size.width <= 1 or size.height == 0) return;
    const presentation = repositoryBranchRowPresentation(
        state,
        surface.frameAllocator(),
        size.width - 1,
    ) orelse return;
    const style = switch (presentation.tone) {
        .fact => palette.style(.info),
        .terminal => palette.style(.muted),
    };
    try draw.copyClippedTextAt(surface, 1, 0, presentation.text, style);
    if (presentation.stale_col) |base_width| {
        var stale_style = palette.style(.muted);
        stale_style.dim = true;
        try draw.copyClippedTextAt(surface, 1 +| base_width, 0, "  stale", stale_style);
    }
}

fn drawTreeProjectionRow(
    context: ViewContext,
    surface: *chasen.Surface,
    tree: *const repository_tree.Tree,
    visible_index: usize,
    screen_row: u16,
) !void {
    const state = context.page_state;
    const target = state.tree_projection.targetAt(tree, visible_index) orelse return;
    const width = surface.size().width;
    const content_col: u16 = switch (target) {
        .repo_root => 1,
        .manifest_node => 0,
    };
    const content_width = width -| content_col;
    const visible_text: []const u8 = switch (target) {
        .repo_root => try rootRowTextAlloc(
            surface.frameAllocator(),
            repositoryRootName(context.repo_root),
            state.viewer.tree_horizontal_scroll,
            content_width,
        ),
        .manifest_node => |node_index| try treeRowTextAlloc(
            surface.frameAllocator(),
            tree.nodes[node_index],
            state.viewer.tree_horizontal_scroll,
            width,
        ),
    };
    var style = switch (target) {
        .repo_root => context.palette.boldStyle(.accent),
        .manifest_node => |node_index| blk: {
            const node = tree.nodes[node_index];
            if (node.kind == .directory) break :blk context.palette.boldStyle(.accent);
            if (node.file_change) |change| break :blk context.palette.style(switch (change) {
                .added => .diff_added,
                .modified => .diff_modified,
            });
            break :blk context.palette.style(.foreground);
        },
    };
    const selected = visible_index == state.viewer.tree_cursor;
    const cursor_background_active = selected and
        state.viewer.focus == .tree and
        !state.file_search.mode;
    // Selection contributes neutral cursor chrome only. The target keeps
    // ownership of its semantic foreground so directories and changed files
    // remain distinguishable in both active and retained-inactive tree states.
    // File search temporarily owns navigation while retaining the tree cursor,
    // so its candidate emphasis—not that stored destination—owns focus chrome.
    // The same low-intensity background as the source cursor avoids the much
    // stronger terminal-dependent foreground/background swap from reverse.
    if (selected) {
        style.bold = true;
    }
    if (cursor_background_active) {
        style.bg = context.palette.color(.pane_cursor_bg);
        fillTreeSelectionRow(surface, screen_row, style);
    }
    draw.copyClippedTextAt(surface, content_col, screen_row, visible_text, style) catch {};
}

/// Extend the selected row's composed semantic foreground and neutral cursor
/// background through the physical tree viewport. The separator is outside
/// this child surface, so it remains fixed chrome rather than becoming part of
/// the selection signal.
fn fillTreeSelectionRow(surface: *chasen.Surface, row: u16, style: chasen.TextStyle) void {
    for (0..surface.size().width) |col| {
        _ = surface.borrowTextAt(@intCast(col), row, " ", style);
    }
}

fn repositoryRootName(root: ?[]const u8) []const u8 {
    const path = root orelse return "Repository";
    const base = std.fs.path.basename(path);
    return if (base.len == 0) path else base;
}

fn drawDocumentCheckpoint(
    state: *const RepositoryPageState,
    selected_path: []const u8,
    surface: *chasen.Surface,
    palette: theme.Palette,
) !void {
    const displayed = state.displayed_document orelse {
        draw.copyClippedTextAt(surface, 1, source_geometry.source_body_first_row, "Loading selected file...", palette.style(.muted)) catch {};
        return;
    };
    if (displayed.manifest_revision != state.manifest_revision or !std.mem.eql(u8, displayed.path, selected_path)) {
        draw.copyClippedTextAt(surface, 1, source_geometry.source_body_first_row, "Loading selected file...", palette.style(.muted)) catch {};
        return;
    }
    switch (displayed.value) {
        .source => |*document| {
            const live_selection = state.liveSourceSelection();
            try drawSource(
                surface,
                document,
                &displayed.syntax_spans,
                displayed.change_decoration.map(),
                state.viewer,
                state.source_search,
                live_selection,
                palette,
            );
            return;
        },
        .inert => |inert| drawInertCheckpoint(inert, surface, palette),
    }
}

fn drawInertCheckpoint(value: selected_document.Value, surface: *chasen.Surface, palette: theme.Palette) void {
    const label: []const u8 = switch (value) {
        .text => unreachable,
        .symlink => |link| blk: {
            const width = surface.size().width -| "Symbolic link -> ".len -| 1;
            const target = manifest.displayWindowAlloc(surface.frameAllocator(), link.target, 0, width) catch break :blk "Symbolic link";
            break :blk std.fmt.allocPrint(surface.frameAllocator(), "Symbolic link -> {s}", .{target.text()}) catch "Symbolic link";
        },
        .binary => "Binary file is not shown",
        .invalid_utf8 => "Non-UTF-8 file is not shown",
        .unsafe_control_text => "File contains unsupported control characters",
        .oversized => oversized_display_message,
        .directory_or_gitlink => "Submodule or directory is not shown",
        .named_pipe, .unix_socket, .block_device, .character_device, .unknown_special => "Special file is not shown",
        .missing_or_changed => "File changed or disappeared; press r to retry",
        .unreadable, .unsupported_platform => "Selected file could not be read",
    };
    draw.copyClippedTextAt(surface, 1, source_geometry.source_body_first_row, label, palette.style(.muted)) catch {};
}

test "text limit contract repository oversized diagnostic" {
    try std.testing.expectEqualStrings("File exceeds the 2 MiB display limit", oversized_display_message);
}

fn treeRowTextAlloc(
    allocator: std.mem.Allocator,
    node: repository_tree.Node,
    horizontal_scroll: usize,
    width: u16,
) ![]const u8 {
    const marker: []const u8 = switch (node.kind) {
        .file => "  ",
        .directory => if (node.expanded) "▾ " else "▸ ",
    };
    return treeItemTextAlloc(
        allocator,
        (node.depth + 1) * 2,
        marker,
        node.name,
        horizontal_scroll,
        width,
    );
}

fn rootRowTextAlloc(
    allocator: std.mem.Allocator,
    name: []const u8,
    horizontal_scroll: usize,
    width: u16,
) ![]const u8 {
    return treeItemTextAlloc(allocator, 0, "", name, horizontal_scroll, width);
}

fn treeItemTextAlloc(
    allocator: std.mem.Allocator,
    logical_indent: usize,
    marker: []const u8,
    name: []const u8,
    horizontal_scroll: usize,
    width: u16,
) ![]const u8 {
    if (width == 0) return "";
    const available: usize = width;
    const marker_width = chasen.text.displayWidth(marker);
    var skip = horizontal_scroll;
    var indent_columns: usize = 0;
    var visible_marker: []const u8 = marker;
    if (skip < logical_indent) {
        indent_columns = @min(logical_indent - skip, available);
        skip = 0;
    } else {
        skip -= logical_indent;
        if (skip >= marker_width) {
            skip -= marker_width;
            visible_marker = "";
        } else if (skip > 0) {
            // Do not expose a partial disclosure glyph.
            skip = 0;
            visible_marker = "";
        }
    }
    if (chasen.text.displayWidth(visible_marker) > available - indent_columns) visible_marker = "";
    const prefix_columns = @min(indent_columns + chasen.text.displayWidth(visible_marker), available);
    const name_width = available - prefix_columns;
    const name_window = try manifest.displayWindowAlloc(allocator, name, skip, name_width);
    const indent = try allocator.alloc(u8, indent_columns);
    @memset(indent, ' ');
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ indent, visible_marker, name_window.text() });
}

pub fn sourceTextWidth(width: u16, document: *const source.Document, line_numbers: bool) u16 {
    return source_geometry.SourceGeometry.init(.{ .width = width, .height = 0 }, document, line_numbers).text_width;
}

/// Draws the fixed two-row Repository source header. Search presentation owns
/// row 1 whenever a query is active or retained; otherwise the row is a
/// non-interactive separator. Keeping the choice here prevents the normal rule
/// from being painted underneath search text by separate callers.
pub fn drawSourceHeader(
    surface: *chasen.Surface,
    presentation: source_header.Presentation,
    search: model.SourceSearchState,
    source_active: bool,
    path_selected: bool,
    palette: theme.Palette,
) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;
    const header_layout = source_header.layout(size.width, presentation);
    if (header_layout.path_area.width > 0) {
        // Frame allocation failure may omit the path for this redraw, but it
        // must not reject accepted page state or suppress allocation-free
        // metadata and the independent row-1 focus/search signal.
        if (manifest.displayWindowAlloc(
            surface.frameAllocator(),
            presentation.raw_path,
            0,
            header_layout.path_area.width,
        )) |path_window| {
            var path_style = palette.boldStyle(.accent);
            if (path_selected) path_style.bg = palette.color(.diff_cursor);
            draw.copyClippedTextAt(
                surface,
                header_layout.path_area.col,
                source_geometry.source_path_row,
                path_window.text(),
                path_style,
            ) catch {};
        } else |_| {}
    }
    if (header_layout.line) |*field| {
        draw.copyClippedTextAt(
            surface,
            field.region.col,
            source_geometry.source_path_row,
            field.label.text(),
            palette.style(.muted),
        ) catch {};
    }
    if (header_layout.git) |field| {
        draw.copyClippedTextAt(
            surface,
            field.region.col,
            source_geometry.source_path_row,
            field.state.label(),
            sourceHeaderGitStyle(field.state, palette),
        ) catch {};
    }
    if (header_layout.commit) |*field| {
        draw.copyClippedTextAt(
            surface,
            field.region.col,
            source_geometry.source_path_row,
            field.value.text(),
            palette.style(.muted),
        ) catch {};
    }
    if (size.height <= source_geometry.source_search_or_rule_row) return;
    if (drawSearchRow(surface, search, palette)) return;
    const style = sourceHeaderRuleStyle(source_active, palette);
    for (0..size.width) |col| {
        _ = surface.borrowTextAt(@intCast(col), source_geometry.source_search_or_rule_row, "─", style);
    }
}

fn sourceHeaderGitStyle(state: source_header.GitState, palette: theme.Palette) chasen.TextStyle {
    return palette.style(switch (state) {
        .clean => .muted,
        .added => .diff_added,
        .modified => .diff_modified,
        .unavailable => .warning,
    });
}

/// Draws source content only. Header rendering stays separate so file-search
/// takeover can replace the entire right pane without partially drawing the
/// accepted path or separator first.
pub fn drawSource(
    surface: *chasen.Surface,
    document: *const source.Document,
    syntax: ?*const source_syntax.SourceSpans,
    changes: ?*const repository_change_map.Map,
    viewer: model.ViewerState,
    search: model.SourceSearchState,
    live_selection: ?selection.DragSelection,
    palette: theme.Palette,
) !void {
    const size = surface.size();
    if (size.height == 0 or size.width == 0) return;
    const geometry = source_geometry.SourceGeometry.init(size, document, viewer.line_numbers);
    if (size.height <= geometry.body_first_row) return;
    const source_active = viewer.focus == .source;

    const rows = geometry.navigationRows();
    var body_row: usize = 0;
    while (body_row < rows and viewer.source_vertical_scroll + body_row < document.rowCount()) : (body_row += 1) {
        const line_index = viewer.source_vertical_scroll + body_row;
        const line = document.lineBody(line_index).?;
        const projection = try text_projection.Projection.init(line, .{ .tab_width = repository_tab_width });
        const row = geometry.body_first_row + @as(u16, @intCast(body_row));
        const current = line_index == viewer.source_cursor;
        if (source_active and current) fillSourceCursorRow(surface, row, palette.color(.pane_cursor_bg));
        const base_style = sourceRowStyle(palette.style(.foreground), source_active, current, palette);

        const change = if (changes) |map| map.row(line_index) else .none;
        const gutter: []const u8 = if (change == .none) " " else "▌";
        const gutter_role: theme.Role = switch (change) {
            .none => .foreground,
            .added => .diff_added,
            .modified => .diff_modified,
        };
        _ = surface.borrowTextAt(0, row, gutter, sourceRowStyle(palette.style(gutter_role), source_active, current, palette));
        if (viewer.line_numbers) {
            const number = try std.fmt.allocPrint(surface.frameAllocator(), "{d}", .{line_index + 1});
            const number_col: u16 = @intCast(@as(usize, geometry.line_number_col) + geometry.line_number_width - chasen.text.displayWidth(number));
            // Repository has no separate Review-style cursor gutter marker.
            // Promote only the active current line-number digits so retained
            // source position never looks focused while the tree is active.
            // The dedicated role keeps this focus cue distinct from syntax.
            const number_role: theme.Role = if (source_active and current) .pane_active_line_number else .diff_line_number;
            draw.copyClippedTextAt(surface, number_col, row, number, sourceRowStyle(palette.style(number_role), source_active, current, palette)) catch {};
        }
        if (geometry.text_width == 0) {
            applySelectionLineStyles(surface, geometry, row, document, line_index, projection, viewer.source_horizontal_scroll, live_selection, palette.color(.diff_cursor));
            continue;
        }
        drawProjectedLine(surface, geometry.text_col, row, projection, viewer.source_horizontal_scroll, geometry.text_width, base_style);
        if (syntax) |spans| applySyntaxLineStyles(
            surface,
            geometry.text_col,
            row,
            projection,
            viewer.source_horizontal_scroll,
            geometry.text_width,
            spans.lineSpans(line_index),
            base_style,
            palette,
            null,
        );
        if (search.match) |match| if (match.line == line_index) {
            applyByteRangeStyle(
                surface,
                geometry.text_col,
                row,
                projection,
                viewer.source_horizontal_scroll,
                geometry.text_width,
                .{ .start = match.start, .end = match.end },
                sourceRowStyle(palette.boldStyle(.warning), source_active, current, palette),
            );
        };
        applySelectionLineStyles(surface, geometry, row, document, line_index, projection, viewer.source_horizontal_scroll, live_selection, palette.color(.diff_cursor));
    }
}

fn drawProjectedLine(
    surface: *chasen.Surface,
    text_col: u16,
    row: u16,
    projection: text_projection.Projection,
    horizontal_scroll: usize,
    width: usize,
    style: chasen.TextStyle,
) void {
    var visible = projection.visibleSegments(horizontal_scroll, width);
    while (visible.next()) |segment| drawVisibleSegment(surface, text_col, row, segment, style);
}

fn drawVisibleSegment(
    surface: *chasen.Surface,
    text_col: u16,
    row: u16,
    segment: text_projection.VisibleSegment,
    style: chasen.TextStyle,
) void {
    const segment_col: u16 = @intCast(@as(usize, text_col) + segment.viewport_cells.start);
    switch (segment.materialization) {
        .source => |bytes| _ = surface.borrowTextAt(segment_col, row, bytes, style),
        .spaces => |count| for (0..count) |offset| {
            _ = surface.borrowTextAt(@intCast(@as(usize, segment_col) + offset), row, " ", style);
        },
    }
}

fn applyByteRangeStyle(
    surface: *chasen.Surface,
    text_col: u16,
    row: u16,
    projection: text_projection.Projection,
    horizontal_scroll: usize,
    width: usize,
    range: text_projection.ByteRange,
    style: chasen.TextStyle,
) void {
    if (range.start >= range.end) return;
    var visible = projection.visibleSegments(horizontal_scroll, width);
    while (visible.next()) |segment| {
        if (segment.token.byte_start >= range.end) break;
        if (segment.token.byte_end <= range.start) continue;
        restyleVisibleSegment(surface, text_col, row, segment, style, null);
    }
}

fn applySelectionLineStyles(
    surface: *chasen.Surface,
    geometry: source_geometry.SourceGeometry,
    row: u16,
    document: *const source.Document,
    line_index: usize,
    projection: text_projection.Projection,
    horizontal_scroll: usize,
    live_selection: ?selection.DragSelection,
    background: chasen.Color,
) void {
    const selected = live_selection orelse return;
    if (!selected.token.source_fingerprint.eql(document.fingerprint)) return;
    const range = selected.range();
    if (line_index < range.start.line_index or line_index > range.end.line_index) return;
    if (selected.mode == .line) {
        var col: u16 = 0;
        while (col < geometry.width) : (col += 1) setCellBackground(surface, col, row, background);
        return;
    }

    const byte_start = if (line_index == range.start.line_index) range.start.leading_byte else 0;
    const byte_end = if (line_index == range.end.line_index) range.end.trailing_byte else projection.line.len;
    if (byte_start >= byte_end or geometry.text_width == 0) return;
    var visible = projection.visibleSegments(horizontal_scroll, geometry.text_width);
    while (visible.next()) |segment| {
        if (segment.token.byte_start >= byte_end) break;
        if (segment.token.byte_end <= byte_start) continue;
        setVisibleSegmentBackground(surface, geometry.text_col, row, segment, background);
    }
}

fn setVisibleSegmentBackground(
    surface: *chasen.Surface,
    text_col: u16,
    row: u16,
    segment: text_projection.VisibleSegment,
    background: chasen.Color,
) void {
    const segment_col: u16 = @intCast(@as(usize, text_col) + segment.viewport_cells.start);
    switch (segment.materialization) {
        .source => setCellBackground(surface, segment_col, row, background),
        .spaces => |count| for (0..count) |offset| {
            setCellBackground(surface, @intCast(@as(usize, segment_col) + offset), row, background);
        },
    }
}

fn setCellBackground(surface: *chasen.Surface, col: u16, row: u16, background: chasen.Color) void {
    var cell = surface.readCell(col, row) orelse return;
    cell.style.bg = background;
    surface.writeCell(col, row, cell);
}

const SyntaxProjectionStats = struct {
    segments_visited: usize = 0,
    spans_advanced: usize = 0,
    cells_restyled: usize = 0,
};

/// Restyles the already rendered visible source cells with one monotonic pass
/// over canonical visible segments and ordered spans. Reusing the admitted projection keeps
/// TAB/wide clipping in one implementation and avoids allocating/redrawing a
/// text slice per span, which became quadratic for capture-dense lines.
fn applySyntaxLineStyles(
    surface: *chasen.Surface,
    text_col: u16,
    row: u16,
    projection: text_projection.Projection,
    horizontal_scroll: usize,
    width: usize,
    line_spans: syntax_token.LineSpans,
    base_style: chasen.TextStyle,
    palette: theme.Palette,
    stats: ?*SyntaxProjectionStats,
) void {
    if (width == 0 or line_spans.spans.len == 0) return;
    var span_index: usize = 0;
    var visible = projection.visibleSegments(horizontal_scroll, width);
    while (visible.next()) |segment| {
        if (stats) |value| value.segments_visited += 1;
        while (span_index < line_spans.spans.len and line_spans.spans[span_index].end <= segment.token.byte_start) {
            span_index += 1;
            if (stats) |value| value.spans_advanced += 1;
        }
        if (span_index >= line_spans.spans.len) continue;
        const span = line_spans.spans[span_index];
        if (span.start > segment.token.byte_start or segment.token.byte_end > span.end) continue;
        if (!syntax_style.changesForeground(span.role)) continue;
        const style = syntax_style.apply(base_style, span.role, palette);
        restyleVisibleSegment(surface, text_col, row, segment, style, stats);
    }
}

fn restyleVisibleSegment(
    surface: *chasen.Surface,
    text_col: u16,
    row: u16,
    segment: text_projection.VisibleSegment,
    style: chasen.TextStyle,
    stats: ?*SyntaxProjectionStats,
) void {
    const segment_col: u16 = @intCast(@as(usize, text_col) + segment.viewport_cells.start);
    switch (segment.materialization) {
        .source => restyleCell(surface, segment_col, row, style, stats),
        .spaces => |count| for (0..count) |offset| {
            restyleCell(surface, @intCast(@as(usize, segment_col) + offset), row, style, stats);
        },
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
    tree: ?*const repository_tree.Tree,
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
        else if (!state.projection_available)
            "File list unavailable; wait or press Esc"
        else if (state.no_match)
            "No matching files"
        else
            "Enter: open  Esc: cancel";
        draw.copyClippedTextAt(surface, 1, 1, status, palette.style(if (state.no_match or !state.projection_available) .warning else .muted)) catch {};
    }
    const available_tree = tree orelse return;
    if (!state.projection_available) return;
    const visible_rows = @as(usize, size.height -| 2);
    const start = fileSearchWindowStart(state.focused, state.len, visible_rows);
    var row: usize = 0;
    while (row < visible_rows and start + row < state.len) : (row += 1) {
        const result_index = start + row;
        const node = available_tree.nodes[state.matches[result_index]];
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

fn drawSearchRow(surface: *chasen.Surface, search: model.SourceSearchState, palette: theme.Palette) bool {
    if (!search.mode and search.query.len == 0) return false;
    if (surface.size().height <= source_geometry.source_search_or_rule_row) return true;
    if (search.mode) {
        const text = std.fmt.allocPrint(surface.frameAllocator(), "/{s}", .{search.input.slice()}) catch return true;
        draw.copyClippedTextAt(surface, 1, source_geometry.source_search_or_rule_row, text, palette.boldStyle(.prompt)) catch {};
    } else if (search.query.len > 0) {
        const prefix = if (search.match != null) "match: " else "no match: ";
        const text = std.fmt.allocPrint(surface.frameAllocator(), "{s}{s}", .{ prefix, search.query.slice() }) catch return true;
        draw.copyClippedTextAt(surface, 1, source_geometry.source_search_or_rule_row, text, palette.style(if (search.match != null) .muted else .warning)) catch {};
    }
    return true;
}

fn sourceHeaderRuleStyle(_: bool, _: theme.Palette) chasen.TextStyle {
    return .{ .dim = true };
}

/// Current-row presentation is active-source chrome. It contributes only a
/// background, leaving semantic foreground ownership to gutter, syntax, and
/// search. Pane focus never rewrites intrinsic style flags, and inactive
/// source content therefore has no false active-row signal.
fn sourceRowStyle(style: chasen.TextStyle, active: bool, current: bool, palette: theme.Palette) chasen.TextStyle {
    var composed = style;
    if (active and current) composed.bg = palette.color(.pane_cursor_bg);
    return composed;
}

/// Prefill the whole physical row before semantic content is drawn so the
/// cursor background also covers gutter lead-in and trailing blank cells.
fn fillSourceCursorRow(surface: *chasen.Surface, row: u16, background: chasen.Color) void {
    const style = chasen.TextStyle{ .bg = background };
    for (0..surface.size().width) |col| {
        _ = surface.borrowTextAt(@intCast(col), row, " ", style);
    }
}

test "repository source view reserves gutter and renders plain text" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, "const value = 1;\nsecond\n");
    var document = try source.Document.initOwned(allocator, bytes, .init(bytes));
    defer document.deinit(allocator);
    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(40, 6);
    defer test_surface.deinit();

    try drawSource(&test_surface.surface, &document, null, null, .{ .focus = .source }, .{}, null, .default());
    const snapshot = try test_surface.snapshot(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "1 const value = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "2 second") != null);
}

test "repository source gutter renders added and modified rows without moving text" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, "added\nmodified\nplain\n");
    var document = try source.Document.initOwned(allocator, bytes, .init(bytes));
    defer document.deinit(allocator);
    var map = repository_change_map.Map{ .rows = try allocator.dupe(repository_change_map.Kind, &.{ .added, .modified, .none }) };
    defer map.deinit(allocator);
    const palette: theme.Palette = .default();
    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(40, 6);
    defer test_surface.deinit();

    try drawSource(&test_surface.surface, &document, null, &map, .{ .focus = .source, .source_cursor = 1 }, .{}, null, palette);
    try test_surface.expectCellText(0, 2, "▌");
    try test_surface.expectCellText(0, 3, "▌");
    try test_surface.expectCellText(0, 4, " ");
    try test_surface.expectCellText(3, 2, "a");
    try test_surface.expectCellText(3, 3, "m");
    try std.testing.expectEqual(palette.color(.diff_added), test_surface.surface.readCell(0, 2).?.style.fg);
    try std.testing.expectEqual(palette.color(.diff_modified), test_surface.surface.readCell(0, 3).?.style.fg);
    try std.testing.expect(!test_surface.surface.readCell(0, 2).?.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(test_surface.surface.readCell(0, 3).?.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(test_surface.surface.readCell(3, 3).?.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(test_surface.surface.readCell(39, 3).?.style.bg.eql(palette.color(.pane_cursor_bg)));
}

test "repository empty source keeps one synthetic viewer row" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, "");
    var document = try source.Document.initOwned(allocator, bytes, .init(bytes));
    defer document.deinit(allocator);
    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(12, 4);
    defer test_surface.deinit();
    try drawSource(&test_surface.surface, &document, null, null, .{ .focus = .source }, .{}, null, .default());
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

fn sourceHeaderPresentationForTest(path: []const u8) source_header.Presentation {
    return .init(path, null, .unavailable, .unavailable);
}

test "repository source header renders path above a full fixed separator" {
    const palette: theme.Palette = .default();
    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(24, source_geometry.source_body_first_row);
    defer test_surface.deinit();

    try drawSourceHeader(&test_surface.surface, sourceHeaderPresentationForTest("src/main.zig"), .{}, false, false, palette);
    const snapshot = try test_surface.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "src/main.zig") != null);
    for (0..test_surface.surface.size().width) |col| {
        const cell = test_surface.surface.readCell(@intCast(col), source_geometry.source_search_or_rule_row) orelse
            return error.ExpectedSourceHeaderRuleCell;
        try std.testing.expectEqualStrings("─", cell.char.grapheme);
        try std.testing.expect(cell.style.fg.eql(.default));
        try std.testing.expect(cell.style.dim);
    }
}

test "repository source header renders typed metadata focus-stably" {
    const HeaderPalette = struct {
        pub fn get(_: @This(), role: theme.Role) ?theme.ColorValue {
            return switch (role) {
                .accent => .{ .rgb = .{ .r = 10, .g = 11, .b = 12 } },
                .muted => .{ .rgb = .{ .r = 20, .g = 21, .b = 22 } },
                .info => .{ .rgb = .{ .r = 30, .g = 31, .b = 32 } },
                .warning => .{ .rgb = .{ .r = 40, .g = 41, .b = 42 } },
                else => null,
            };
        }
    };
    const palette = theme.Palette.fromConfig(HeaderPalette{});
    const presentation = source_header.Presentation.init(
        "src/app/pages/repository.zig",
        .{ .current = 42, .total = 8713 },
        .modified,
        .{ .committed = 951_827_640 },
    );
    const expected_layout = source_header.layout(96, presentation);
    try std.testing.expect(expected_layout.line != null);
    try std.testing.expect(expected_layout.git != null);
    try std.testing.expect(expected_layout.commit != null);

    var active: chasen.testing.TestSurface = undefined;
    try active.init(96, source_geometry.source_body_first_row);
    defer active.deinit();
    try drawSourceHeader(&active.surface, presentation, .{}, true, false, palette);

    var inactive: chasen.testing.TestSurface = undefined;
    try inactive.init(96, source_geometry.source_body_first_row);
    defer inactive.deinit();
    try drawSourceHeader(&inactive.surface, presentation, .{}, false, false, palette);

    const snapshot = try active.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "src/app/pages/repository.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Ln 42/8713") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "modified") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "commit 2000-02-29 12:34Z") != null);

    const points = [_]struct { col: u16, role: theme.Role, bold: bool }{
        .{ .col = expected_layout.path_target.?.col, .role = .accent, .bold = true },
        .{ .col = expected_layout.line.?.region.col, .role = .muted, .bold = false },
        .{ .col = expected_layout.git.?.region.col, .role = .diff_modified, .bold = false },
        .{ .col = expected_layout.commit.?.region.col, .role = .muted, .bold = false },
    };
    for (points) |point| {
        const active_cell = active.surface.readCell(point.col, source_geometry.source_path_row) orelse
            return error.ExpectedActiveHeaderCell;
        const inactive_cell = inactive.surface.readCell(point.col, source_geometry.source_path_row) orelse
            return error.ExpectedInactiveHeaderCell;
        try std.testing.expect(active_cell.style.fg.eql(palette.color(point.role)));
        try std.testing.expect(inactive_cell.style.fg.eql(palette.color(point.role)));
        try std.testing.expectEqual(point.bold, active_cell.style.bold);
        try std.testing.expectEqual(point.bold, inactive_cell.style.bold);
        try std.testing.expect(!active_cell.style.dim);
        try std.testing.expect(!inactive_cell.style.dim);
    }
}

test "repository source header highlights only the exact path target" {
    const palette: theme.Palette = .default();
    const presentation = source_header.Presentation.init(
        "src/main.zig",
        .{ .current = 2, .total = 20 },
        .modified,
        .{ .committed = 951_827_640 },
    );
    const expected = source_header.layout(72, presentation);
    const target = expected.path_target orelse return error.ExpectedPathTarget;
    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(72, source_geometry.source_body_first_row);
    defer test_surface.deinit();

    try drawSourceHeader(&test_surface.surface, presentation, .{}, true, true, palette);

    var offset: u16 = 0;
    while (offset < target.width) : (offset += 1) {
        const cell = test_surface.surface.readCell(target.col + offset, source_geometry.source_path_row) orelse
            return error.ExpectedSelectedPathCell;
        try std.testing.expect(cell.style.bg.eql(palette.color(.diff_cursor)));
        try std.testing.expect(cell.style.fg.eql(palette.color(.accent)));
        try std.testing.expect(cell.style.bold);
    }
    const line = expected.line orelse return error.ExpectedLineMetadata;
    const metadata = test_surface.surface.readCell(line.region.col, source_geometry.source_path_row) orelse
        return error.ExpectedLineMetadataCell;
    try std.testing.expect(!metadata.style.bg.eql(palette.color(.diff_cursor)));
}

test "repository source header preserves semantic Git styles" {
    const palette: theme.Palette = .default();
    const cases = [_]struct { state: source_header.GitState, role: theme.Role }{
        .{ .state = .clean, .role = .muted },
        .{ .state = .added, .role = .diff_added },
        .{ .state = .modified, .role = .diff_modified },
        .{ .state = .unavailable, .role = .warning },
    };
    for (cases) |case| {
        const presentation = source_header.Presentation.init("main.zig", null, case.state, .unavailable);
        const expected_layout = source_header.layout(40, presentation);
        var test_surface: chasen.testing.TestSurface = undefined;
        try test_surface.init(40, 1);
        defer test_surface.deinit();
        try drawSourceHeader(&test_surface.surface, presentation, .{}, false, false, palette);
        const git_cell = test_surface.surface.readCell(expected_layout.git.?.region.col, 0) orelse
            return error.ExpectedGitHeaderCell;
        try std.testing.expect(git_cell.style.fg.eql(palette.color(case.role)));
        try std.testing.expect(!git_cell.style.dim);
    }
}

test "repository source header renderer follows adaptive omission regions" {
    const presentation = source_header.Presentation.init(
        "src/main.zig",
        .{ .current = 42, .total = 8713 },
        .modified,
        .{ .committed = 951_827_640 },
    );

    var medium: chasen.testing.TestSurface = undefined;
    try medium.init(50, 1);
    defer medium.deinit();
    try drawSourceHeader(&medium.surface, presentation, .{}, false, false, .default());
    const medium_snapshot = try medium.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(medium_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, medium_snapshot, "Ln 42/8713") == null);
    try std.testing.expect(std.mem.indexOf(u8, medium_snapshot, "modified") != null);
    try std.testing.expect(std.mem.indexOf(u8, medium_snapshot, "commit 2000-") != null);

    var narrow: chasen.testing.TestSurface = undefined;
    try narrow.init(29, 1);
    defer narrow.deinit();
    try drawSourceHeader(&narrow.surface, presentation, .{}, false, false, .default());
    const narrow_snapshot = try narrow.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(narrow_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, narrow_snapshot, "Ln 42/8713") == null);
    try std.testing.expect(std.mem.indexOf(u8, narrow_snapshot, "modified") != null);
    try std.testing.expect(std.mem.indexOf(u8, narrow_snapshot, "2000-") == null);
}

test "repository source normal header rule stays white across source focus" {
    const RulePalette = struct {
        pub fn get(_: @This(), role: theme.Role) ?theme.ColorValue {
            return switch (role) {
                .accent => .{ .rgb = .{ .r = 10, .g = 11, .b = 12 } },
                .muted => .{ .rgb = .{ .r = 20, .g = 21, .b = 22 } },
                else => null,
            };
        }
    };
    const palette = theme.Palette.fromConfig(RulePalette{});

    var active: chasen.testing.TestSurface = undefined;
    try active.init(12, source_geometry.source_body_first_row);
    defer active.deinit();
    try drawSourceHeader(&active.surface, sourceHeaderPresentationForTest("src/main.zig"), .{}, true, false, palette);

    var inactive: chasen.testing.TestSurface = undefined;
    try inactive.init(12, source_geometry.source_body_first_row);
    defer inactive.deinit();
    try drawSourceHeader(&inactive.surface, sourceHeaderPresentationForTest("src/main.zig"), .{}, false, false, palette);

    for (0..active.surface.size().width) |col| {
        const active_rule = active.surface.readCell(@intCast(col), source_geometry.source_search_or_rule_row) orelse
            return error.ExpectedActiveSourceHeaderRule;
        const inactive_rule = inactive.surface.readCell(@intCast(col), source_geometry.source_search_or_rule_row) orelse
            return error.ExpectedInactiveSourceHeaderRule;
        try std.testing.expectEqualStrings("─", active_rule.char.grapheme);
        try std.testing.expect(active_rule.style.fg.eql(.default));
        try std.testing.expect(!active_rule.style.fg.eql(palette.color(.accent)));
        try std.testing.expect(active_rule.style.dim);
        try std.testing.expectEqualStrings("─", inactive_rule.char.grapheme);
        try std.testing.expect(inactive_rule.style.fg.eql(.default));
        try std.testing.expect(inactive_rule.style.dim);
    }
}

test "repository source header truncates safely to the path row" {
    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(2, 1);
    defer test_surface.deinit();

    try drawSourceHeader(&test_surface.surface, sourceHeaderPresentationForTest("a"), .{}, false, false, .default());
    try test_surface.expectCellText(1, source_geometry.source_path_row, "a");
    try std.testing.expect(test_surface.surface.readCell(0, source_geometry.source_search_or_rule_row) == null);
}

test "repository source search checkpoint appears without moving source rows" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, "first\nsecond\n");
    var document = try source.Document.initOwned(allocator, bytes, .init(bytes));
    defer document.deinit(allocator);
    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(32, 6);
    defer test_surface.deinit();

    try drawSourceHeader(&test_surface.surface, sourceHeaderPresentationForTest("src/main.zig"), .{}, true, false, .default());
    try drawSource(&test_surface.surface, &document, null, null, .{ .focus = .source }, .{}, null, .default());
    var snapshot = try test_surface.snapshot(allocator);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "/needle") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "src/main.zig") != null);
    try test_surface.expectCellText(0, source_geometry.source_search_or_rule_row, "─");
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "1 first") != null);
    allocator.free(snapshot);

    test_surface.deinit();
    try test_surface.init(32, 6);
    var search: model.SourceSearchState = .{ .mode = true };
    try search.input.insertSlice("needle");
    try drawSourceHeader(&test_surface.surface, sourceHeaderPresentationForTest("src/main.zig"), search, true, false, .default());
    try drawSource(&test_surface.surface, &document, null, null, .{ .focus = .source }, search, null, .default());
    snapshot = try test_surface.snapshot(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "/needle") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "─") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "1 first") != null);
}

test "repository source retained search result replaces the normal separator" {
    const palette: theme.Palette = .default();
    var search: model.SourceSearchState = .{
        .match = .{ .line = 0, .start = 0, .end = 6 },
    };
    try search.query.insertSlice("needle");

    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(28, source_geometry.source_body_first_row);
    defer test_surface.deinit();
    try drawSourceHeader(&test_surface.surface, sourceHeaderPresentationForTest("src/main.zig"), search, false, false, palette);

    const snapshot = try test_surface.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "match: needle") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "─") == null);
    const status_cell = test_surface.surface.readCell(1, source_geometry.source_search_or_rule_row) orelse
        return error.ExpectedSourceSearchStatusCell;
    try std.testing.expect(status_cell.style.fg.eql(palette.color(.muted)));
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
    try drawSource(&test_surface.surface, &document, null, null, .{ .focus = .source, .source_cursor = 0 }, search, null, palette);
    const match_cell = test_surface.surface.readCell(7, 2) orelse return error.ExpectedMatchCell;
    const plain_cell = test_surface.surface.readCell(3, 2) orelse return error.ExpectedPlainCell;
    try std.testing.expect(match_cell.style.fg.eql(palette.color(.warning)));
    try std.testing.expect(match_cell.style.bold);
    try std.testing.expect(match_cell.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(plain_cell.style.fg.eql(palette.color(.foreground)));
    try std.testing.expect(!plain_cell.style.bold);
    try std.testing.expect(plain_cell.style.bg.eql(palette.color(.pane_cursor_bg)));
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
    try drawSource(&syntax_surface.surface, &document, &spans, null, .{ .focus = .source }, .{}, null, palette);
    const keyword_cell = syntax_surface.surface.readCell(3, 2) orelse return error.ExpectedKeywordCell;
    const plain_cell = syntax_surface.surface.readCell(9, 2) orelse return error.ExpectedPlainCell;
    const comment_cell = syntax_surface.surface.readCell(3, 3) orelse return error.ExpectedCommentCell;
    const foreground_cell = syntax_surface.surface.readCell(3, 4) orelse return error.ExpectedForegroundCell;
    try std.testing.expectEqual(palette.color(.accent), keyword_cell.style.fg);
    try std.testing.expectEqual(palette.color(.foreground), plain_cell.style.fg);
    try std.testing.expectEqual(palette.color(.muted), comment_cell.style.fg);
    try std.testing.expectEqual(palette.color(.foreground), foreground_cell.style.fg);
    try std.testing.expect(keyword_cell.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(plain_cell.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(!comment_cell.style.bg.eql(palette.color(.pane_cursor_bg)));

    var search_surface: chasen.testing.TestSurface = undefined;
    try search_surface.init(24, 4);
    defer search_surface.deinit();
    try drawSource(&search_surface.surface, &document, &spans, null, .{ .focus = .source }, .{
        .match = .{ .line = 0, .start = 0, .end = 5 },
    }, null, palette);
    const match_cell = search_surface.surface.readCell(3, 2) orelse return error.ExpectedMatchCell;
    try std.testing.expectEqual(palette.color(.warning), match_cell.style.fg);
}

test "repository source focus does not dim semantic foregrounds" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, "const value plain\n");
    var document = try source.Document.initOwned(allocator, bytes, .init(bytes));
    defer document.deinit(allocator);
    var candidates = [_]source_syntax.Candidate{.{
        .line_index = 0,
        .span = .{ .start = 0, .end = 5, .role = .keyword },
    }};
    var spans = try source_syntax.build(allocator, &document, &candidates);
    defer spans.deinit(allocator);
    var changes = repository_change_map.Map{
        .rows = try allocator.dupe(repository_change_map.Kind, &.{.added}),
    };
    defer changes.deinit(allocator);
    var search: model.SourceSearchState = .{
        .match = .{ .line = 0, .start = 6, .end = 11 },
    };
    try search.query.insertSlice("value");
    const palette: theme.Palette = .default();

    var active: chasen.testing.TestSurface = undefined;
    try active.init(32, 4);
    defer active.deinit();
    try drawSourceHeader(&active.surface, sourceHeaderPresentationForTest("src/main.zig"), search, true, false, palette);
    try drawSource(
        &active.surface,
        &document,
        &spans,
        &changes,
        .{ .focus = .source, .source_cursor = 99 },
        search,
        null,
        palette,
    );

    var inactive: chasen.testing.TestSurface = undefined;
    try inactive.init(32, 4);
    defer inactive.deinit();
    try drawSourceHeader(&inactive.surface, sourceHeaderPresentationForTest("src/main.zig"), search, false, false, palette);
    try drawSource(
        &inactive.surface,
        &document,
        &spans,
        &changes,
        .{ .focus = .tree, .source_cursor = 99 },
        search,
        null,
        palette,
    );

    const geometry = source_geometry.SourceGeometry.init(active.surface.size(), &document, true);
    const body_row = geometry.body_first_row;
    const points = [_]struct {
        col: u16,
        row: u16,
        role: theme.Role,
    }{
        .{ .col = 1, .row = source_geometry.source_path_row, .role = .accent },
        .{ .col = 1, .row = source_geometry.source_search_or_rule_row, .role = .muted },
        .{ .col = 0, .row = body_row, .role = .diff_added },
        .{ .col = geometry.line_number_col, .row = body_row, .role = .diff_line_number },
        .{ .col = geometry.text_col, .row = body_row, .role = .accent },
        .{ .col = geometry.text_col + 6, .row = body_row, .role = .warning },
        .{ .col = geometry.text_col + 12, .row = body_row, .role = .foreground },
    };
    for (points) |point| {
        const active_cell = active.surface.readCell(point.col, point.row) orelse return error.ExpectedActiveSourceCell;
        const inactive_cell = inactive.surface.readCell(point.col, point.row) orelse return error.ExpectedInactiveSourceCell;
        try std.testing.expect(active_cell.style.fg.eql(palette.color(point.role)));
        try std.testing.expect(inactive_cell.style.fg.eql(palette.color(point.role)));
        try std.testing.expect(!active_cell.style.dim);
        try std.testing.expect(!inactive_cell.style.dim);
    }
    try std.testing.expect(active.surface.readCell(geometry.text_col + 6, body_row).?.style.bold);
    try std.testing.expect(inactive.surface.readCell(geometry.text_col + 6, body_row).?.style.bold);
}

test "repository source cursor row composes semantic overlays and active-only background" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, "const value plain\nsecond\n");
    var document = try source.Document.initOwned(allocator, bytes, .init(bytes));
    defer document.deinit(allocator);
    var candidates = [_]source_syntax.Candidate{.{
        .line_index = 0,
        .span = .{ .start = 0, .end = 5, .role = .keyword },
    }};
    var spans = try source_syntax.build(allocator, &document, &candidates);
    defer spans.deinit(allocator);
    var changes = repository_change_map.Map{
        .rows = try allocator.dupe(repository_change_map.Kind, &.{ .modified, .none }),
    };
    defer changes.deinit(allocator);
    const search: model.SourceSearchState = .{
        .match = .{ .line = 0, .start = 6, .end = 11 },
    };
    const token: selection.RepositoryContentToken = .{
        .repo_epoch = 1,
        .root_identity = .{ .device = 2, .inode = 3 },
        .path = "main.zig",
        .source_fingerprint = document.fingerprint,
    };
    var live = selection.DragSelection.init(token, .character, selection.pointFromBoundary(0, 12));
    live.update(selection.pointFromBoundary(0, 17));
    var palette: theme.Palette = .default();
    palette.colors[@intFromEnum(theme.Role.foreground)] = .{ .rgb = .{ 21, 22, 23 } };
    palette.colors[@intFromEnum(theme.Role.diff_line_number)] = .{ .rgb = .{ 31, 32, 33 } };
    palette.colors[@intFromEnum(theme.Role.accent)] = .{ .rgb = .{ 41, 42, 43 } };
    palette.colors[@intFromEnum(theme.Role.pane_active_line_number)] = .{ .rgb = .{ 51, 52, 53 } };
    palette.colors[@intFromEnum(theme.Role.pane_cursor_bg)] = .{ .rgb = .{ 1, 2, 3 } };
    palette.colors[@intFromEnum(theme.Role.diff_cursor)] = .{ .rgb = .{ 9, 8, 7 } };

    var active: chasen.testing.TestSurface = undefined;
    try active.init(30, 5);
    defer active.deinit();
    try drawSource(
        &active.surface,
        &document,
        &spans,
        &changes,
        .{ .focus = .source, .source_cursor = 0 },
        search,
        live,
        palette,
    );

    const geometry = source_geometry.SourceGeometry.init(active.surface.size(), &document, true);
    const cursor_row = geometry.body_first_row;
    const gutter = active.surface.readCell(0, cursor_row) orelse return error.ExpectedCursorGutter;
    const line_number = active.surface.readCell(geometry.line_number_col, cursor_row) orelse return error.ExpectedCursorLineNumber;
    const keyword = active.surface.readCell(geometry.text_col, cursor_row) orelse return error.ExpectedCursorKeyword;
    const searched = active.surface.readCell(geometry.text_col + 6, cursor_row) orelse return error.ExpectedCursorSearch;
    const selected = active.surface.readCell(geometry.text_col + 12, cursor_row) orelse return error.ExpectedCursorSelection;
    const trailing = active.surface.readCell(29, cursor_row) orelse return error.ExpectedCursorTrailingCell;
    const non_current_line_number = active.surface.readCell(geometry.line_number_col, cursor_row + 1) orelse
        return error.ExpectedNonCurrentLineNumber;
    try std.testing.expect(gutter.style.fg.eql(palette.color(.diff_modified)));
    try std.testing.expect(line_number.style.fg.eql(palette.color(.pane_active_line_number)));
    try std.testing.expect(!line_number.style.bold);
    try std.testing.expect(non_current_line_number.style.fg.eql(palette.color(.diff_line_number)));
    try std.testing.expect(!non_current_line_number.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(keyword.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(searched.style.fg.eql(palette.color(.warning)));
    try std.testing.expect(searched.style.bold);
    for ([_]chasen.TextStyle{ gutter.style, line_number.style, keyword.style, searched.style, trailing.style }) |style| {
        try std.testing.expect(style.bg.eql(palette.color(.pane_cursor_bg)));
    }
    try std.testing.expect(selected.style.fg.eql(palette.color(.foreground)));
    try std.testing.expect(selected.style.bg.eql(palette.color(.diff_cursor)));
    try std.testing.expect(!active.surface.readCell(0, cursor_row + 1).?.style.bg.eql(palette.color(.pane_cursor_bg)));

    var inactive: chasen.testing.TestSurface = undefined;
    try inactive.init(30, 5);
    defer inactive.deinit();
    try drawSource(
        &inactive.surface,
        &document,
        &spans,
        &changes,
        .{ .focus = .tree, .source_cursor = 0 },
        search,
        null,
        palette,
    );
    for ([_]struct { col: u16, role: theme.Role }{
        .{ .col = 0, .role = .diff_modified },
        .{ .col = geometry.line_number_col, .role = .diff_line_number },
        .{ .col = geometry.text_col, .role = .accent },
        .{ .col = geometry.text_col + 6, .role = .warning },
    }) |point| {
        const cell = inactive.surface.readCell(point.col, cursor_row) orelse return error.ExpectedInactiveCursorCell;
        try std.testing.expect(cell.style.fg.eql(palette.color(point.role)));
        try std.testing.expect(!cell.style.dim);
        try std.testing.expect(!cell.style.bg.eql(palette.color(.pane_cursor_bg)));
    }
    try std.testing.expect(!inactive.surface.readCell(29, cursor_row).?.style.bg.eql(palette.color(.pane_cursor_bg)));
}

test "repository source row style preserves intrinsic flags while gating cursor background" {
    var palette: theme.Palette = .default();
    palette.colors[@intFromEnum(theme.Role.pane_cursor_bg)] = .{ .rgb = .{ 1, 2, 3 } };
    const intrinsic: chasen.TextStyle = .{
        .bold = true,
        .italic = true,
        .dim = true,
        .reverse = true,
        .strikethrough = true,
        .fg = palette.color(.warning),
        .bg = palette.color(.muted),
        .underline = .single,
        .underline_color = palette.color(.accent),
    };

    var expected_active = intrinsic;
    expected_active.bg = palette.color(.pane_cursor_bg);
    try std.testing.expect(sourceRowStyle(intrinsic, true, true, palette).eql(expected_active));
    try std.testing.expect(sourceRowStyle(intrinsic, false, true, palette).eql(intrinsic));
    try std.testing.expect(sourceRowStyle(intrinsic, true, false, palette).eql(intrinsic));
}

test "repository selection background composes after cursor syntax and search styles" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, "const value plain\n");
    var document = try source.Document.initOwned(allocator, bytes, .init(bytes));
    defer document.deinit(allocator);
    var candidates = [_]source_syntax.Candidate{
        .{ .line_index = 0, .span = .{ .start = 0, .end = 5, .role = .keyword } },
        .{ .line_index = 0, .span = .{ .start = 6, .end = 11, .role = .type } },
    };
    var spans = try source_syntax.build(allocator, &document, &candidates);
    defer spans.deinit(allocator);
    const palette: theme.Palette = .default();
    const token: selection.RepositoryContentToken = .{
        .repo_epoch = 1,
        .root_identity = .{ .device = 2, .inode = 3 },
        .path = "main.zig",
        .source_fingerprint = document.fingerprint,
    };
    var live = selection.DragSelection.init(token, .character, selection.pointFromBoundary(0, 0));
    live.update(selection.pointFromBoundary(0, "const value plain".len));
    const search: model.SourceSearchState = .{ .match = .{ .line = 0, .start = 6, .end = 11 } };

    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(30, 4);
    defer test_surface.deinit();
    try drawSource(
        &test_surface.surface,
        &document,
        &spans,
        null,
        .{ .focus = .source, .source_cursor = 0 },
        search,
        live,
        palette,
    );

    const geometry = source_geometry.SourceGeometry.init(test_surface.surface.size(), &document, true);
    const keyword = test_surface.surface.readCell(geometry.text_col, geometry.body_first_row) orelse return error.ExpectedKeywordCell;
    const searched = test_surface.surface.readCell(geometry.text_col + 6, geometry.body_first_row) orelse return error.ExpectedSearchCell;
    const plain = test_surface.surface.readCell(geometry.text_col + 12, geometry.body_first_row) orelse return error.ExpectedPlainCell;
    try std.testing.expectEqual(palette.color(.accent), keyword.style.fg);
    try std.testing.expectEqual(palette.color(.warning), searched.style.fg);
    try std.testing.expect(searched.style.bold);
    try std.testing.expectEqual(palette.color(.foreground), plain.style.fg);
    try std.testing.expect(keyword.style.bg.eql(palette.color(.diff_cursor)));
    try std.testing.expect(searched.style.bg.eql(palette.color(.diff_cursor)));
    try std.testing.expect(plain.style.bg.eql(palette.color(.diff_cursor)));
    const trailing = test_surface.surface.readCell(29, geometry.body_first_row) orelse return error.ExpectedCursorTrailingCell;
    try std.testing.expect(trailing.style.bg.eql(palette.color(.pane_cursor_bg)));
}

test "repository selection whole-line style covers gutter numbers body and trailing cells" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, "one\ntwo\n");
    var document = try source.Document.initOwned(allocator, bytes, .init(bytes));
    defer document.deinit(allocator);
    const palette: theme.Palette = .default();
    const token: selection.RepositoryContentToken = .{
        .repo_epoch = 1,
        .root_identity = .{ .device = 2, .inode = 3 },
        .path = "main.zig",
        .source_fingerprint = document.fingerprint,
    };
    var live = selection.DragSelection.init(token, .line, selection.pointFromLine(0));
    live.update(selection.pointFromLine(1));

    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(20, 5);
    defer test_surface.deinit();
    try drawSource(&test_surface.surface, &document, null, null, .{ .focus = .source }, .{}, live, palette);
    const geometry = source_geometry.SourceGeometry.init(test_surface.surface.size(), &document, true);
    for ([_]struct { col: u16, row: u16 }{
        .{ .col = 0, .row = geometry.body_first_row },
        .{ .col = 1, .row = geometry.body_first_row },
        .{ .col = 3, .row = geometry.body_first_row },
        .{ .col = 19, .row = geometry.body_first_row },
        .{ .col = 0, .row = geometry.body_first_row + 1 },
        .{ .col = 19, .row = geometry.body_first_row + 1 },
    }) |point| {
        const cell = test_surface.surface.readCell(point.col, point.row) orelse return error.ExpectedSelectedCell;
        try std.testing.expect(cell.style.bg.eql(palette.color(.diff_cursor)));
    }
}

test "repository source syntax projection visits dense line and spans only once" {
    const allocator = std.testing.allocator;
    // Keep this renderer-complexity fixture independent of the production
    // metadata budget; it only needs a line much denser than the viewport.
    const count = 4096;
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
    const projection = try text_projection.Projection.init(line, .{ .tab_width = repository_tab_width });
    drawProjectedLine(&test_surface.surface, 0, 0, projection, horizontal_scroll, 80, .{});
    var stats: SyntaxProjectionStats = .{};
    applySyntaxLineStyles(
        &test_surface.surface,
        0,
        0,
        projection,
        horizontal_scroll,
        80,
        .{ .spans = spans },
        .{},
        .default(),
        &stats,
    );

    try std.testing.expectEqual(@as(usize, 80), stats.segments_visited);
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
    const projection = try text_projection.Projection.init(line, .{ .tab_width = repository_tab_width });
    drawProjectedLine(&tab_surface.surface, 0, 0, projection, 1, 3, .{});
    applySyntaxLineStyles(&tab_surface.surface, 0, 0, projection, 1, 3, .{ .spans = &spans }, .{}, palette, null);
    try std.testing.expectEqual(palette.color(.accent), tab_surface.surface.readCell(0, 0).?.style.fg);
    try std.testing.expectEqual(palette.color(.accent), tab_surface.surface.readCell(2, 0).?.style.fg);

    var wide_surface: chasen.testing.TestSurface = undefined;
    try wide_surface.init(2, 1);
    defer wide_surface.deinit();
    drawProjectedLine(&wide_surface.surface, 0, 0, projection, 5, 2, .{});
    applySyntaxLineStyles(&wide_surface.surface, 0, 0, projection, 5, 2, .{ .spans = &spans }, .{}, palette, null);
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
    var search: model.FileSearchState = .{ .mode = true, .projection_available = true, .truncated = true, .len = 1 };
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
    var search: model.FileSearchState = .{ .mode = true, .projection_available = true, .len = 6, .focused = 5 };
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

test "repository file search renders unavailable projection without stale results" {
    const allocator = std.testing.allocator;
    var search: model.FileSearchState = .{ .mode = true };
    search.matches[0] = 99;
    search.len = 1;
    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(48, 4);
    defer test_surface.deinit();

    try drawFileSearch(&test_surface.surface, null, &search, .default());
    const snapshot = try test_surface.snapshot(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "File list unavailable; wait or press Esc") != null);
}

fn bundleForTest(bytes: []const u8) !repository_tasks.Bundle {
    var document = try manifest.parseOwned(std.testing.allocator, try std.testing.allocator.dupe(u8, bytes));
    errdefer document.deinit(std.testing.allocator);
    return .{ .tree = try repository_tree.Tree.build(std.testing.allocator, &document), .document = document };
}

fn selectionStateForTest(paths: []const u8, content: []const u8) !RepositoryPageState {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 2,
        .repo_epoch = 3,
        .root_identity = .{ .device = 4, .inode = 5 },
        .bundle = try bundleForTest(paths),
        .load_state = .loaded,
        .manifest_revision = 6,
    };
    errdefer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    state.viewer.tree_cursor = 1;
    const bytes = try allocator.dupe(u8, content);
    var document = try source.Document.initOwned(allocator, bytes, .init(bytes));
    errdefer document.deinit(allocator);
    state.displayed_document = .{
        .path = try allocator.dupe(u8, state.selected_path.?),
        .manifest_revision = state.manifest_revision,
        .source_revision = 7,
        .authority = .accepted,
        .value = .{ .source = document },
    };
    return state;
}

fn applyBundleStatusForTest(bundle: *repository_tasks.Bundle, bytes: []const u8) !void {
    var index = try repository_change_index.parseOwned(
        std.testing.allocator,
        try std.testing.allocator.dupe(u8, bytes),
    );
    defer index.deinit(std.testing.allocator);
    _ = bundle.tree.applyChangeIndex(&index);
    bundle.status_fingerprint = index.fingerprint;
    bundle.status_available = true;
}

test "repository file search takeover suppresses and restores tree cursor background" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("alpha.zig\x00beta.zig\x00"),
        .load_state = .loaded,
    };
    defer state.deinit(allocator);
    const tree = &state.bundle.?.tree;
    state.selected_path = tree.filePath("alpha.zig", .all);
    const alpha_node = tree.nodeIndexForPath("alpha.zig", .all) orelse return error.ExpectedAlphaFile;
    const alpha_visible = state.tree_projection.visibleIndexForTarget(tree, .{ .manifest_node = alpha_node }) orelse
        return error.ExpectedAlphaFile;
    state.viewer.tree_cursor = alpha_visible;
    state.viewer.focus = .tree;

    const palette = repositorySearchCursorPaletteForTest();
    const size: chasen.Size = .{ .width = 60, .height = 10 };
    const layout = repository_layout.bodyLayout(size, state.viewer.tree_width, state.viewer.tree_hidden);
    const alpha_row = layout.header_rows + @as(u16, @intCast(alpha_visible));

    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(size.width, size.height);
    defer test_surface.deinit();
    try view(.{ .page_state = &state, .palette = palette }, &test_surface.surface);
    const initial_alpha = test_surface.surface.readCell(2, alpha_row) orelse return error.ExpectedAlphaFile;
    const initial_alpha_trailing = test_surface.surface.readCell(layout.tree_width - 1, alpha_row) orelse
        return error.ExpectedAlphaTrailingCell;
    try std.testing.expect(initial_alpha.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(initial_alpha_trailing.style.bg.eql(palette.color(.pane_cursor_bg)));

    _ = state.applyNavigation(allocator, .enter_file_search, size);
    for ("zig") |byte| _ = state.applyNavigation(allocator, .{ .file_search_insert = byte }, size);
    try std.testing.expectEqual(@as(usize, 2), state.file_search.len);
    const retained_tree_cursor = state.viewer.tree_cursor;
    test_surface.surface.clearAll();
    try view(.{ .page_state = &state, .palette = palette }, &test_surface.surface);
    const search_alpha = test_surface.surface.readCell(2, alpha_row) orelse return error.ExpectedAlphaFile;
    const search_alpha_trailing = test_surface.surface.readCell(layout.tree_width - 1, alpha_row) orelse
        return error.ExpectedAlphaTrailingCell;
    const first_candidate = test_surface.surface.readCell(layout.source_col + 1, 2) orelse
        return error.ExpectedSearchCandidate;
    try std.testing.expect(!search_alpha.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(!search_alpha_trailing.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(first_candidate.style.fg.eql(palette.color(.prompt)));
    try std.testing.expect(first_candidate.style.bold);

    _ = state.applyNavigation(allocator, .file_search_next, size);
    try std.testing.expectEqual(retained_tree_cursor, state.viewer.tree_cursor);
    try std.testing.expectEqual(@as(usize, 1), state.file_search.focused);
    test_surface.surface.clearAll();
    try view(.{ .page_state = &state, .palette = palette }, &test_surface.surface);
    const moved_candidate = test_surface.surface.readCell(layout.source_col + 1, 3) orelse
        return error.ExpectedSearchCandidate;
    try std.testing.expect(moved_candidate.style.fg.eql(palette.color(.prompt)));
    try std.testing.expect(moved_candidate.style.bold);

    _ = state.applyNavigation(allocator, .cancel_file_search, size);
    test_surface.surface.clearAll();
    try view(.{ .page_state = &state, .palette = palette }, &test_surface.surface);
    const restored_alpha_trailing = test_surface.surface.readCell(layout.tree_width - 1, alpha_row) orelse
        return error.ExpectedAlphaTrailingCell;
    try std.testing.expect(restored_alpha_trailing.style.bg.eql(palette.color(.pane_cursor_bg)));

    _ = state.applyNavigation(allocator, .enter_file_search, size);
    _ = state.applyNavigation(allocator, .submit_file_search, size);
    try std.testing.expect(!state.file_search.mode);
    test_surface.surface.clearAll();
    try view(.{ .page_state = &state, .palette = palette }, &test_surface.surface);
    const empty_accept_alpha_trailing = test_surface.surface.readCell(layout.tree_width - 1, alpha_row) orelse
        return error.ExpectedAlphaTrailingCell;
    try std.testing.expect(empty_accept_alpha_trailing.style.bg.eql(palette.color(.pane_cursor_bg)));

    _ = state.applyNavigation(allocator, .enter_file_search, size);
    for ("beta") |byte| _ = state.applyNavigation(allocator, .{ .file_search_insert = byte }, size);
    _ = state.applyNavigation(allocator, .submit_file_search, size);
    try std.testing.expect(!state.file_search.mode);
    try std.testing.expectEqualStrings("beta.zig", state.selected_path.?);
    const beta_node = tree.nodeIndexForPath("beta.zig", .all) orelse return error.ExpectedBetaFile;
    const beta_visible = state.tree_projection.visibleIndexForTarget(tree, .{ .manifest_node = beta_node }) orelse
        return error.ExpectedBetaFile;
    const beta_row = layout.header_rows + @as(u16, @intCast(beta_visible));
    test_surface.surface.clearAll();
    try view(.{ .page_state = &state, .palette = palette }, &test_surface.surface);
    const accepted_beta_trailing = test_surface.surface.readCell(layout.tree_width - 1, beta_row) orelse
        return error.ExpectedBetaTrailingCell;
    try std.testing.expect(accepted_beta_trailing.style.bg.eql(palette.color(.pane_cursor_bg)));

    _ = state.applyNavigation(allocator, .enter_file_search, size);
    for ("missing") |byte| _ = state.applyNavigation(allocator, .{ .file_search_insert = byte }, size);
    _ = state.applyNavigation(allocator, .submit_file_search, size);
    try std.testing.expect(state.file_search.mode);
    try std.testing.expect(state.file_search.no_match);
    test_surface.surface.clearAll();
    try view(.{ .page_state = &state, .palette = palette }, &test_surface.surface);
    const no_match_beta_trailing = test_surface.surface.readCell(layout.tree_width - 1, beta_row) orelse
        return error.ExpectedBetaTrailingCell;
    const no_match_prompt = test_surface.surface.readCell(layout.source_col + 1, 0) orelse
        return error.ExpectedSearchPrompt;
    try std.testing.expect(!no_match_beta_trailing.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(no_match_prompt.style.fg.eql(palette.color(.prompt)));
    try std.testing.expect(no_match_prompt.style.bold);
}

test "repository hidden-tree file search keeps unavailable prompt cancellable" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .load_state = .loading,
        .viewer = .{ .focus = .source, .tree_width = 42, .tree_hidden = true },
    };
    defer state.deinit(allocator);
    const size: chasen.Size = .{ .width = 80, .height = 8 };

    _ = state.applyNavigation(allocator, .enter_file_search, size);
    _ = state.applyNavigation(allocator, .submit_file_search, size);
    try std.testing.expect(state.file_search.mode);
    try std.testing.expectEqualStrings("", state.file_search.input.slice());
    try std.testing.expect(!state.file_search.projection_available);
    try std.testing.expect(!state.file_search.no_match);
    try std.testing.expect(!state.viewer.tree_hidden);

    _ = state.applyNavigation(allocator, .{ .file_search_insert = 'x' }, size);
    _ = state.applyNavigation(allocator, .submit_file_search, size);
    try std.testing.expect(state.file_search.mode);
    try std.testing.expect(!state.file_search.projection_available);
    try std.testing.expect(!state.file_search.no_match);
    try std.testing.expect(!state.viewer.tree_hidden);

    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(size.width, size.height);
    defer test_surface.deinit();
    try view(.{ .page_state = &state, .palette = .default() }, &test_surface.surface);
    const snapshot = try test_surface.snapshot(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Find file: x") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "File list unavailable") != null);

    _ = state.applyNavigation(allocator, .cancel_file_search, size);
    try std.testing.expect(!state.file_search.mode);
    try std.testing.expect(state.viewer.tree_hidden);
    try std.testing.expectEqual(model.Focus.source, state.viewer.focus);
}

fn repositorySearchCursorPaletteForTest() theme.Palette {
    const Config = struct {
        pub fn get(_: @This(), role: theme.Role) ?theme.ColorValue {
            return switch (role) {
                .prompt => .{ .rgb = .{ .r = 31, .g = 32, .b = 33 } },
                .pane_cursor_bg => .{ .rgb = .{ .r = 41, .g = 42, .b = 43 } },
                else => null,
            };
        }
    };
    return theme.Palette.fromConfig(Config{});
}

fn repositoryBranchViewStateForTest() !RepositoryPageState {
    return .{
        .active = true,
        .repo_epoch = 3,
        .root_identity = .{ .device = 5, .inode = 8 },
        .bundle = try bundleForTest("README.md\x00src/main.zig\x00"),
        .load_state = .loaded,
    };
}

fn installRepositoryBranchSnapshotForTest(
    state: *RepositoryPageState,
    status: git_branch_status.BranchStatus,
    freshness: repository_branch.Freshness,
) void {
    const root_identity = state.root_identity orelse unreachable;
    state.branch.snapshot.deinit();
    state.branch.snapshot.identity = .{
        .repo_epoch = state.repo_epoch,
        .root_identity = root_identity,
    };
    // Test status slices are static. The production path transfers the
    // backend bundle arena into this same page-owned snapshot.
    state.branch.snapshot.status = status;
    state.branch.freshness = freshness;
}

test "repository tree cursor background follows active focus and preserves semantic palette roles" {
    const allocator = std.testing.allocator;
    var bundle = try bundleForTest("added.zig\x00dir/nested.zig\x00modified.zig\x00selected.zig\x00");
    var index = try repository_change_index.parseOwned(allocator, try allocator.dupe(u8, "?? added.zig\x00" ++
        " M modified.zig\x00" ++
        " M selected.zig\x00"));
    defer index.deinit(allocator);
    _ = bundle.tree.applyChangeIndex(&index);
    var state: RepositoryPageState = .{
        .bundle = bundle,
        .load_state = .loaded,
    };
    defer state.deinit(allocator);
    const tree = &state.bundle.?.tree;
    state.selected_path = tree.filePath("selected.zig", .all);
    const nested_node = tree.nodeIndexForPath("dir/nested.zig", .all) orelse return error.ExpectedNestedFile;
    const nested_visible = state.tree_projection.revealManifestNode(tree, .all, nested_node) orelse
        return error.ExpectedNestedFile;
    const selected_node = tree.nodeIndexForPath("selected.zig", .all) orelse return error.ExpectedSelectedFile;
    const selected_visible = state.tree_projection.visibleIndexForTarget(tree, .{ .manifest_node = selected_node }) orelse
        return error.ExpectedSelectedFile;
    state.viewer.tree_cursor = selected_visible;

    const FocusPalette = struct {
        pub fn get(_: @This(), role: theme.Role) ?theme.ColorValue {
            return switch (role) {
                .foreground => .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } },
                .accent => .{ .rgb = .{ .r = 4, .g = 5, .b = 6 } },
                .muted => .{ .rgb = .{ .r = 7, .g = 8, .b = 9 } },
                .success => .{ .rgb = .{ .r = 10, .g = 11, .b = 12 } },
                .info => .{ .rgb = .{ .r = 13, .g = 14, .b = 15 } },
                .prompt => .{ .rgb = .{ .r = 16, .g = 17, .b = 18 } },
                .pane_cursor_bg => .{ .rgb = .{ .r = 19, .g = 20, .b = 21 } },
                else => null,
            };
        }
    };
    const palette = theme.Palette.fromConfig(FocusPalette{});
    const size: chasen.Size = .{ .width = 60, .height = 10 };
    const layout = repository_layout.bodyLayout(size, state.viewer.tree_width, state.viewer.tree_hidden);
    const directory_node = tree.nodeIndexForPath("dir", .all) orelse return error.ExpectedDirectory;
    const directory_visible = state.tree_projection.visibleIndexForTarget(tree, .{ .manifest_node = directory_node }) orelse
        return error.ExpectedDirectory;
    const added_node = tree.nodeIndexForPath("added.zig", .all) orelse return error.ExpectedAddedFile;
    const added_visible = state.tree_projection.visibleIndexForTarget(tree, .{ .manifest_node = added_node }) orelse
        return error.ExpectedAddedFile;
    const root_row = layout.header_rows;
    const directory_row = layout.header_rows + @as(u16, @intCast(directory_visible));
    const added_row = layout.header_rows + @as(u16, @intCast(added_visible));
    const nested_row = layout.header_rows + @as(u16, @intCast(nested_visible));
    const selected_row = layout.header_rows + @as(u16, @intCast(selected_visible));

    var active_surface: chasen.testing.TestSurface = undefined;
    try active_surface.init(size.width, size.height);
    defer active_surface.deinit();
    try view(.{ .page_state = &state, .palette = palette }, &active_surface.surface);
    try active_surface.expectCellText(0, 2, " ");
    try active_surface.expectCellText(1, 2, "F");
    try active_surface.expectCellText(2, 2, "i");
    const active_header = active_surface.surface.readCell(1, 2) orelse return error.ExpectedTreeHeader;
    const active_root = active_surface.surface.readCell(1, root_row) orelse return error.ExpectedRoot;
    const active_directory = active_surface.surface.readCell(4, directory_row) orelse return error.ExpectedDirectory;
    const active_added = active_surface.surface.readCell(4, added_row) orelse return error.ExpectedAddedFile;
    const active_nested = active_surface.surface.readCell(6, nested_row) orelse return error.ExpectedNestedFile;
    const active_selected = active_surface.surface.readCell(4, selected_row) orelse return error.ExpectedSelectedFile;
    const active_separator = active_surface.surface.readCell(layout.tree_width, 2) orelse return error.ExpectedTreeSeparator;
    try std.testing.expect(active_header.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(active_header.style.bold);
    try std.testing.expect(!active_header.style.dim);
    try std.testing.expect(active_root.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(active_root.style.bold);
    try std.testing.expect(!active_root.style.dim);
    try std.testing.expect(!active_root.style.reverse);
    try std.testing.expect(active_directory.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(active_directory.style.bold);
    try std.testing.expect(!active_directory.style.dim);
    try std.testing.expect(active_added.style.fg.eql(palette.color(.diff_added)));
    try std.testing.expect(!active_added.style.dim);
    try std.testing.expect(active_nested.style.fg.eql(palette.color(.foreground)));
    try std.testing.expect(!active_nested.style.dim);
    try std.testing.expect(active_selected.style.fg.eql(palette.color(.diff_modified)));
    try std.testing.expect(active_selected.style.bold);
    try std.testing.expect(!active_selected.style.reverse);
    try std.testing.expect(active_selected.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(!active_selected.style.dim);
    const active_selected_trailing = active_surface.surface.readCell(layout.tree_width - 1, selected_row) orelse
        return error.ExpectedSelectedTrailingCell;
    try std.testing.expect(active_selected_trailing.style.fg.eql(palette.color(.diff_modified)));
    try std.testing.expect(active_selected_trailing.style.bold);
    try std.testing.expect(!active_selected_trailing.style.reverse);
    try std.testing.expect(active_selected_trailing.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(!active_selected_trailing.style.dim);
    try std.testing.expect(active_separator.style.fg.eql(.default));
    try std.testing.expect(active_separator.style.dim);
    try std.testing.expect(!active_separator.style.reverse);
    try std.testing.expect(!active_separator.style.bg.eql(palette.color(.pane_cursor_bg)));

    state.viewer.tree_cursor = 0;
    active_surface.surface.clearAll();
    try view(.{ .page_state = &state, .palette = palette }, &active_surface.surface);
    const selected_root_gutter = active_surface.surface.readCell(0, root_row) orelse return error.ExpectedRootGutter;
    const selected_root = active_surface.surface.readCell(1, root_row) orelse return error.ExpectedRoot;
    const selected_root_trailing = active_surface.surface.readCell(layout.tree_width - 1, root_row) orelse return error.ExpectedRootTrailingCell;
    try std.testing.expect(selected_root.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(selected_root.style.bold);
    try std.testing.expect(!selected_root.style.reverse);
    try std.testing.expect(selected_root.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(selected_root_gutter.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(selected_root_trailing.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(selected_root_trailing.style.bold);
    try std.testing.expect(!selected_root_trailing.style.reverse);
    try std.testing.expect(selected_root_trailing.style.bg.eql(palette.color(.pane_cursor_bg)));

    state.viewer.tree_cursor = directory_visible;
    active_surface.surface.clearAll();
    try view(.{ .page_state = &state, .palette = palette }, &active_surface.surface);
    const selected_directory = active_surface.surface.readCell(4, directory_row) orelse return error.ExpectedDirectory;
    const selected_directory_trailing = active_surface.surface.readCell(layout.tree_width - 1, directory_row) orelse
        return error.ExpectedDirectoryTrailingCell;
    try std.testing.expect(selected_directory.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(selected_directory.style.bold);
    try std.testing.expect(!selected_directory.style.reverse);
    try std.testing.expect(selected_directory.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(selected_directory_trailing.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(selected_directory_trailing.style.bold);
    try std.testing.expect(!selected_directory_trailing.style.reverse);
    try std.testing.expect(selected_directory_trailing.style.bg.eql(palette.color(.pane_cursor_bg)));

    state.viewer.tree_cursor = selected_visible;
    state.viewer.focus = .source;
    var inactive_surface: chasen.testing.TestSurface = undefined;
    try inactive_surface.init(size.width, size.height);
    defer inactive_surface.deinit();
    try view(.{ .page_state = &state, .palette = palette }, &inactive_surface.surface);
    try inactive_surface.expectCellText(0, 2, " ");
    try inactive_surface.expectCellText(1, 2, "F");
    try inactive_surface.expectCellText(2, 2, "i");
    const inactive_header = inactive_surface.surface.readCell(1, 2) orelse return error.ExpectedTreeHeader;
    const inactive_root = inactive_surface.surface.readCell(1, root_row) orelse return error.ExpectedRoot;
    const inactive_directory = inactive_surface.surface.readCell(4, directory_row) orelse return error.ExpectedDirectory;
    const inactive_added = inactive_surface.surface.readCell(4, added_row) orelse return error.ExpectedAddedFile;
    const inactive_nested = inactive_surface.surface.readCell(6, nested_row) orelse return error.ExpectedNestedFile;
    const inactive_selected = inactive_surface.surface.readCell(4, selected_row) orelse return error.ExpectedSelectedFile;
    const inactive_separator = inactive_surface.surface.readCell(layout.tree_width, 2) orelse return error.ExpectedTreeSeparator;
    try std.testing.expect(inactive_header.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(inactive_header.style.bold);
    try std.testing.expect(!inactive_header.style.dim);
    try std.testing.expect(inactive_root.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(inactive_root.style.bold);
    try std.testing.expect(!inactive_root.style.dim);
    try std.testing.expect(!inactive_root.style.reverse);
    try std.testing.expect(inactive_directory.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(inactive_directory.style.bold);
    try std.testing.expect(!inactive_directory.style.dim);
    try std.testing.expect(inactive_added.style.fg.eql(palette.color(.diff_added)));
    try std.testing.expect(!inactive_added.style.dim);
    try std.testing.expect(inactive_nested.style.fg.eql(palette.color(.foreground)));
    try std.testing.expect(!inactive_nested.style.dim);
    try std.testing.expect(inactive_selected.style.fg.eql(palette.color(.diff_modified)));
    try std.testing.expect(inactive_selected.style.bold);
    try std.testing.expect(!inactive_selected.style.dim);
    try std.testing.expect(!inactive_selected.style.reverse);
    try std.testing.expect(!inactive_selected.style.bg.eql(palette.color(.pane_cursor_bg)));
    const inactive_selected_trailing = inactive_surface.surface.readCell(layout.tree_width - 1, selected_row) orelse
        return error.ExpectedInactiveSelectedTrailingCell;
    try std.testing.expect(!inactive_selected_trailing.style.dim);
    try std.testing.expect(!inactive_selected_trailing.style.reverse);
    try std.testing.expect(!inactive_selected_trailing.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(inactive_separator.style.fg.eql(.default));
    try std.testing.expect(inactive_separator.style.dim);
    try std.testing.expect(!inactive_separator.style.reverse);
    try std.testing.expect(!inactive_separator.style.bg.eql(palette.color(.pane_cursor_bg)));
}

test "repository page accepts selected document and renders plain source" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("src/main.zig\x00", "const value = 1;\n");
    defer state.deinit(allocator);
    state.viewer.focus = .source;

    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(60, 10);
    defer test_surface.deinit();
    try view(.{ .page_state = &state, .palette = .default() }, &test_surface.surface);
    const snapshot = try test_surface.snapshot(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "const value = 1;") != null);
}

test "repository empty root renders without disclosure and mouse activation is inert" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest(""),
        .load_state = .empty,
    };
    defer state.deinit(allocator);

    const full_size = chasen.Size{ .width = 60, .height = 8 };
    var expanded_surface: chasen.testing.TestSurface = undefined;
    try expanded_surface.init(full_size.width, full_size.height);
    defer expanded_surface.deinit();
    try view(.{ .page_state = &state, .palette = .default(), .repo_root = "/work/empty-repo" }, &expanded_surface.surface);
    try expanded_surface.expectCellText(0, 2, " ");
    try expanded_surface.expectCellText(1, 2, "F");
    try expanded_surface.expectCellText(2, 2, "i");
    try expanded_surface.expectCellText(0, 3, " ");
    try expanded_surface.expectCellText(1, 3, "e");
    try expanded_surface.expectCellText(0, 4, "R");
    const expanded_snapshot = try expanded_surface.snapshot(allocator);
    defer allocator.free(expanded_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, expanded_snapshot, "Files") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded_snapshot, "empty-repo") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded_snapshot, "▾ empty-repo") == null);
    try std.testing.expect(std.mem.indexOf(u8, expanded_snapshot, "Repository has no") != null);
    const expanded_layout = repository_layout.bodyLayout(full_size, state.viewer.tree_width, state.viewer.tree_hidden);
    const no_file_cell = expanded_surface.surface.readCell(expanded_layout.source_col + 1, source_geometry.source_path_row) orelse
        return error.ExpectedNoFileSelectedCell;
    try std.testing.expect(no_file_cell.style.fg.eql(theme.Palette.default().color(.muted)));
    try std.testing.expect(!no_file_cell.style.dim);

    const root_click = state.mouseToMsg(.{ .col = 0, .row = 3 }, .left, full_size) orelse
        return error.ExpectedRootMouseTarget;
    try std.testing.expectEqual(repository_page.Msg{ .mouse_toggle_row = 0 }, root_click);
    _ = state.applyNavigation(allocator, root_click, full_size);
    try std.testing.expectEqual(@as(usize, 1), state.tree_projection.visibleLen(&state.bundle.?.tree));

    var after_click_surface: chasen.testing.TestSurface = undefined;
    try after_click_surface.init(full_size.width, full_size.height);
    defer after_click_surface.deinit();
    try view(.{ .page_state = &state, .palette = .default(), .repo_root = "/work/empty-repo" }, &after_click_surface.surface);
    try after_click_surface.expectCellText(0, 3, " ");
    try after_click_surface.expectCellText(1, 3, "e");
    try after_click_surface.expectCellText(0, 4, "R");

    const compact_size = chasen.Size{ .width = 60, .height = 3 };
    var compact_surface: chasen.testing.TestSurface = undefined;
    try compact_surface.init(compact_size.width, compact_size.height);
    defer compact_surface.deinit();
    try view(.{ .page_state = &state, .palette = .default(), .repo_root = "/work/empty-repo" }, &compact_surface.surface);
    try compact_surface.expectCellText(0, 2, " ");
    try compact_surface.expectCellText(1, 2, "F");
    try compact_surface.expectCellText(2, 2, "i");
    const compact_snapshot = try compact_surface.snapshot(allocator);
    defer allocator.free(compact_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, compact_snapshot, "empty-repo") == null);
    try std.testing.expectEqual(repository_page.Msg.focus_tree, state.mouseToMsg(.{ .col = 0, .row = 2 }, .left, compact_size).?);

    var width_one: chasen.testing.TestSurface = undefined;
    try width_one.init(1, compact_size.height);
    defer width_one.deinit();
    try view(.{ .page_state = &state, .palette = .default(), .repo_root = "/work/empty-repo" }, &width_one.surface);
    try width_one.expectCellText(0, 2, " ");

    var width_two: chasen.testing.TestSurface = undefined;
    try width_two.init(2, compact_size.height);
    defer width_two.deinit();
    try view(.{ .page_state = &state, .palette = .default(), .repo_root = "/work/empty-repo" }, &width_two.surface);
    try width_two.expectCellText(0, 2, " ");
    try width_two.expectCellText(1, 2, "F");
}

test "Repository branch renders read-only facts without moving tree geometry" {
    const allocator = std.testing.allocator;
    var state = try repositoryBranchViewStateForTest();
    defer state.deinit(allocator);
    installRepositoryBranchSnapshotForTest(&state, .{
        .head = .{ .branch = "main" },
        .upstream = .{ .name = "origin/main", .remote = "origin", .remote_branch = "main" },
        .ahead_behind = .{ .ahead = 0, .behind = 2 },
    }, .fresh);

    const size: chasen.Size = .{ .width = 72, .height = 8 };
    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(size.width, size.height);
    defer test_surface.deinit();
    const palette: theme.Palette = .default();
    try view(.{ .page_state = &state, .palette = palette, .repo_root = "/work/gitframe" }, &test_surface.surface);

    const snapshot = try test_surface.snapshot(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "main ↑0") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "push") == null);
    try test_surface.expectCellText(1, 0, "m");
    try test_surface.expectCellText(0, 1, " ");
    try test_surface.expectCellText(0, 2, " ");
    try test_surface.expectCellText(1, 2, "F");
    try test_surface.expectCellText(2, 2, "i");
    try test_surface.expectCellText(0, 3, " ");
    try test_surface.expectCellText(1, 3, "g");
    const branch_cell = test_surface.surface.readCell(1, 0) orelse return error.ExpectedRepositoryBranchCell;
    try std.testing.expect(branch_cell.style.fg.eql(palette.color(.info)));
    try std.testing.expect(!branch_cell.style.dim);

    const layout = repository_layout.bodyLayout(size, state.viewer.tree_width, state.viewer.tree_hidden);
    try std.testing.expectEqual(@as(u16, 3), layout.header_rows);
    try std.testing.expectEqual(@as(u16, 5), layout.treeRows(size.height));
    try std.testing.expectEqual(repository_page.Msg{ .mouse_toggle_row = 0 }, state.mouseToMsg(.{ .col = 1, .row = 3 }, .left, size).?);
    try std.testing.expect(repository_input.keyToMsg(repository_page.Msg, .{}, .{ .codepoint = 'P' }) == null);

    installRepositoryBranchSnapshotForTest(&state, .{ .head = .detached }, .fresh);
    test_surface.surface.clearAll();
    try view(.{ .page_state = &state, .palette = palette, .repo_root = "/work/gitframe" }, &test_surface.surface);
    const detached = try test_surface.snapshot(allocator);
    defer allocator.free(detached);
    try std.testing.expect(std.mem.indexOf(u8, detached, "detached") != null);

    installRepositoryBranchSnapshotForTest(&state, .{ .head = .{ .branch = "topic" } }, .fresh);
    test_surface.surface.clearAll();
    try view(.{ .page_state = &state, .palette = palette, .repo_root = "/work/gitframe" }, &test_surface.surface);
    const no_upstream = try test_surface.snapshot(allocator);
    defer allocator.free(no_upstream);
    try std.testing.expect(std.mem.indexOf(u8, no_upstream, "topic no upstream") != null);
}

test "Repository branch retains last good facts and bounds stale chrome" {
    const allocator = std.testing.allocator;
    var state = try repositoryBranchViewStateForTest();
    defer state.deinit(allocator);
    state.branch.freshness = .validating;

    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(72, 8);
    defer test_surface.deinit();
    const palette: theme.Palette = .default();
    try view(.{ .page_state = &state, .palette = palette }, &test_surface.surface);
    const loading = try test_surface.snapshot(allocator);
    defer allocator.free(loading);
    try std.testing.expect(std.mem.indexOf(u8, loading, "loading branch") != null);
    const loading_cell = test_surface.surface.readCell(1, 0) orelse return error.ExpectedLoadingBranchCell;
    try std.testing.expect(loading_cell.style.fg.eql(palette.color(.muted)));

    installRepositoryBranchSnapshotForTest(&state, .{
        .head = .{ .branch = "main" },
        .upstream = .{ .name = "origin/main", .remote = "origin", .remote_branch = "main" },
        .ahead_behind = .{ .ahead = 0, .behind = 0 },
    }, .validating);
    test_surface.surface.clearAll();
    try view(.{ .page_state = &state, .palette = palette }, &test_surface.surface);
    const retained = try test_surface.snapshot(allocator);
    defer allocator.free(retained);
    try std.testing.expect(std.mem.indexOf(u8, retained, "main ↑0") != null);
    try std.testing.expect(std.mem.indexOf(u8, retained, "loading branch") == null);

    state.branch.freshness = .{ .failed = .load_failed };
    test_surface.surface.clearAll();
    try view(.{ .page_state = &state, .palette = palette }, &test_surface.surface);
    const stale = try test_surface.snapshot(allocator);
    defer allocator.free(stale);
    try std.testing.expect(std.mem.indexOf(u8, stale, "main ↑0  stale") != null);
    const base_cell = test_surface.surface.readCell(1, 0) orelse return error.ExpectedRetainedBranchCell;
    const stale_cell = test_surface.surface.readCell(10, 0) orelse return error.ExpectedStaleBranchCell;
    try std.testing.expect(base_cell.style.fg.eql(palette.color(.info)));
    try std.testing.expect(!base_cell.style.dim);
    try std.testing.expect(stale_cell.style.fg.eql(palette.color(.muted)));
    try std.testing.expect(stale_cell.style.dim);

    installRepositoryBranchSnapshotForTest(&state, .{
        .head = .{ .branch = "feature/very-long-ticket-name" },
        .upstream = .{ .name = "origin/main", .remote = "origin", .remote_branch = "main" },
        .ahead_behind = .{ .ahead = 0, .behind = 0 },
    }, .{ .failed = .load_failed });
    const narrow = repositoryBranchRowPresentation(&state, allocator, 10) orelse return error.ExpectedNarrowBranchPresentation;
    defer allocator.free(narrow.text);
    try std.testing.expect(narrow.stale_col == null);
    try std.testing.expect(chasen.text.displayWidth(narrow.text) <= 10);

    state.branch.snapshot.deinit();
    state.branch.freshness = .{ .failed = .load_failed };
    test_surface.surface.clearAll();
    try view(.{ .page_state = &state, .palette = palette }, &test_surface.surface);
    const unavailable = try test_surface.snapshot(allocator);
    defer allocator.free(unavailable);
    try std.testing.expect(std.mem.indexOf(u8, unavailable, "branch unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, unavailable, "main ↑0") == null);
}

test "Repository branch yields row zero to full page owners" {
    const allocator = std.testing.allocator;
    const identity: root_capability.Identity = .{ .device = 5, .inode = 8 };
    var state: RepositoryPageState = .{
        .active = true,
        .repo_epoch = 3,
        .root_identity = identity,
        .load_state = .loading,
    };
    defer state.deinit(allocator);
    installRepositoryBranchSnapshotForTest(&state, .{ .head = .{ .branch = "branch-first" } }, .fresh);

    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(72, 8);
    defer test_surface.deinit();
    try view(.{ .page_state = &state, .palette = .default() }, &test_surface.surface);
    const initial_loading = try test_surface.snapshot(allocator);
    defer allocator.free(initial_loading);
    try std.testing.expect(std.mem.indexOf(u8, initial_loading, "Loading repository files") != null);
    try std.testing.expect(std.mem.indexOf(u8, initial_loading, "branch-first") == null);

    state.load_state = .failed;
    test_surface.surface.clearAll();
    try view(.{ .page_state = &state, .palette = .default() }, &test_surface.surface);
    const manifest_failure = try test_surface.snapshot(allocator);
    defer allocator.free(manifest_failure);
    try std.testing.expect(std.mem.indexOf(u8, manifest_failure, "Repository manifest failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest_failure, "branch-first") == null);

    state.load_state = .loading;
    state.file_search.mode = true;
    test_surface.surface.clearAll();
    try view(.{ .page_state = &state, .palette = .default() }, &test_surface.surface);
    const search_without_bundle = try test_surface.snapshot(allocator);
    defer allocator.free(search_without_bundle);
    try std.testing.expect(std.mem.indexOf(u8, search_without_bundle, "Find file:") != null);
    try std.testing.expect(std.mem.indexOf(u8, search_without_bundle, "branch-first") == null);

    state.file_search.mode = false;
    state.bundle = try bundleForTest("main.zig\x00");
    state.load_state = .loaded;
    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        state.repo_epoch,
        identity,
        .{ .unavailable = .{ .path = "removed.zig", .reason = .no_current_path } },
    );
    state.acceptIncoming(allocator, &incoming);
    test_surface.surface.clearAll();
    try view(.{ .page_state = &state, .palette = .default() }, &test_surface.surface);
    const incoming_unavailable = try test_surface.snapshot(allocator);
    defer allocator.free(incoming_unavailable);
    try std.testing.expect(std.mem.indexOf(u8, incoming_unavailable, "Repository target unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, incoming_unavailable, "branch-first") == null);
}

test "Repository branch keeps bundle search chrome and hides with the tree" {
    const allocator = std.testing.allocator;
    var state = try repositoryBranchViewStateForTest();
    defer state.deinit(allocator);
    installRepositoryBranchSnapshotForTest(&state, .{
        .head = .{ .branch = "main" },
        .upstream = .{ .name = "origin/main", .remote = "origin", .remote_branch = "main" },
        .ahead_behind = .{},
    }, .fresh);

    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(72, 8);
    defer test_surface.deinit();
    state.file_search.mode = true;
    try view(.{ .page_state = &state, .palette = .default() }, &test_surface.surface);
    const search_with_bundle = try test_surface.snapshot(allocator);
    defer allocator.free(search_with_bundle);
    try std.testing.expect(std.mem.indexOf(u8, search_with_bundle, "main ↑0") != null);
    try std.testing.expect(std.mem.indexOf(u8, search_with_bundle, "Find file:") != null);

    state.file_search.mode = false;
    state.viewer.tree_hidden = true;
    state.viewer.focus = .source;
    test_surface.surface.clearAll();
    try view(.{ .page_state = &state, .palette = .default() }, &test_surface.surface);
    const hidden = try test_surface.snapshot(allocator);
    defer allocator.free(hidden);
    try std.testing.expect(std.mem.indexOf(u8, hidden, "main ↑0") == null);
    try std.testing.expect(std.mem.indexOf(u8, hidden, "Files") == null);

    state.viewer.tree_hidden = false;
    state.branch.snapshot.identity.?.repo_epoch = 99;
    state.branch.freshness = .{ .failed = .root_changed };
    test_surface.surface.clearAll();
    try view(.{ .page_state = &state, .palette = .default() }, &test_surface.surface);
    const mismatched = try test_surface.snapshot(allocator);
    defer allocator.free(mismatched);
    try std.testing.expect(std.mem.indexOf(u8, mismatched, "main ↑0") == null);
    try std.testing.expect(std.mem.indexOf(u8, mismatched, "branch unavailable") != null);
}

test "Repository branch clips width one and two without moving Files" {
    const allocator = std.testing.allocator;
    var state = try repositoryBranchViewStateForTest();
    defer state.deinit(allocator);
    installRepositoryBranchSnapshotForTest(&state, .{
        .head = .{ .branch = "main" },
        .upstream = .{ .name = "origin/main", .remote = "origin", .remote_branch = "main" },
        .ahead_behind = .{},
    }, .fresh);

    var width_one: chasen.testing.TestSurface = undefined;
    try width_one.init(1, 3);
    defer width_one.deinit();
    try view(.{ .page_state = &state, .palette = .default() }, &width_one.surface);
    try width_one.expectCellText(0, 0, " ");
    try width_one.expectCellText(0, 1, " ");
    try width_one.expectCellText(0, 2, " ");

    var width_two: chasen.testing.TestSurface = undefined;
    try width_two.init(2, 3);
    defer width_two.deinit();
    try view(.{ .page_state = &state, .palette = .default() }, &width_two.surface);
    try width_two.expectCellText(0, 0, " ");
    try width_two.expectCellText(1, 0, "…");
    try width_two.expectCellText(0, 1, " ");
    try width_two.expectCellText(0, 2, " ");
    try width_two.expectCellText(1, 2, "F");
}

test "repository root renders without disclosure and activation preserves opened descendants" {
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("README.md\x00src/main.zig\x00"),
        .load_state = .loaded,
    };
    defer state.deinit(std.testing.allocator);
    state.selected_path = state.bundle.?.tree.filePath("README.md", .all);

    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(60, 10);
    defer test_surface.deinit();
    try view(.{ .page_state = &state, .palette = .default(), .repo_root = "/work/gitframe" }, &test_surface.surface);
    const snapshot = try test_surface.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Files") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "gitframe") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "▾ gitframe") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "README.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "src") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "main.zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Loading selected file") != null);
    try test_surface.expectCellText(0, 2, " ");
    try test_surface.expectCellText(1, 2, "F");
    try test_surface.expectCellText(0, 3, " ");
    try test_surface.expectCellText(1, 3, "g");

    state.viewer.tree_width = 30;
    var wide_surface: chasen.testing.TestSurface = undefined;
    try wide_surface.init(104, 10);
    defer wide_surface.deinit();
    try view(.{ .page_state = &state, .palette = .default(), .repo_root = "/work/gitframe" }, &wide_surface.surface);
    try wide_surface.expectCellText(30, 0, "│");
    state.viewer.tree_width = null;

    state.viewer.tree_horizontal_scroll = 1;
    test_surface.surface.clearAll();
    try view(.{ .page_state = &state, .palette = .default(), .repo_root = "/work/gitframe" }, &test_surface.surface);
    try test_surface.expectCellText(0, 3, " ");
    try test_surface.expectCellText(1, 3, "i");
    state.viewer.tree_horizontal_scroll = 0;
    const layout = repository_layout.bodyLayout(test_surface.surface.size(), state.viewer.tree_width, state.viewer.tree_hidden);
    try test_surface.expectCellText(
        layout.tree_width + 2,
        source_geometry.source_body_first_row,
        "L",
    );
    const loading_cell = test_surface.surface.readCell(layout.source_col + 1, source_geometry.source_body_first_row) orelse
        return error.ExpectedLoadingCheckpointCell;
    try std.testing.expect(loading_cell.style.fg.eql(theme.Palette.default().color(.muted)));
    try std.testing.expect(!loading_cell.style.dim);
    const inactive_path_cell = test_surface.surface.readCell(layout.source_col + 1, source_geometry.source_path_row) orelse
        return error.ExpectedInactiveSourcePathCell;
    try std.testing.expect(inactive_path_cell.style.fg.eql(theme.Palette.default().color(.accent)));
    try std.testing.expect(!inactive_path_cell.style.dim);
    const source_rule = test_surface.surface.readCell(layout.tree_width + 1, source_geometry.source_search_or_rule_row) orelse
        return error.ExpectedSourceHeaderRuleCell;
    try std.testing.expectEqualStrings("─", source_rule.char.grapheme);
    try std.testing.expect(source_rule.style.fg.eql(.default));
    try std.testing.expect(source_rule.style.dim);

    const directory = state.bundle.?.tree.nodeIndexForPath("src", .all) orelse return error.ExpectedDirectory;
    state.viewer.tree_cursor = state.tree_projection.visibleIndexForTarget(
        &state.bundle.?.tree,
        .{ .manifest_node = directory },
    ) orelse return error.ExpectedVisibleDirectory;
    _ = state.applyNavigation(std.testing.allocator, .toggle_directory, .{ .width = 60, .height = 10 });
    try std.testing.expect(state.bundle.?.tree.nodes[directory].expanded);
    state.viewer.tree_cursor = 0;
    _ = state.applyNavigation(std.testing.allocator, .toggle_directory, .{ .width = 60, .height = 10 });
    var after_root_surface: chasen.testing.TestSurface = undefined;
    try after_root_surface.init(60, 10);
    defer after_root_surface.deinit();
    try view(.{ .page_state = &state, .palette = .default(), .repo_root = "/work/gitframe" }, &after_root_surface.surface);
    const after_root_snapshot = try after_root_surface.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(after_root_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, after_root_snapshot, "gitframe") != null);
    try std.testing.expect(std.mem.indexOf(u8, after_root_snapshot, "▾ gitframe") == null);
    try std.testing.expect(std.mem.indexOf(u8, after_root_snapshot, "README.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, after_root_snapshot, "src") != null);
    try std.testing.expect(std.mem.indexOf(u8, after_root_snapshot, "main.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, after_root_snapshot, "Loading selected file") != null);
}

test "repository source header page view keeps filesystem metadata outside commit history" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("main.zig\x00", "first\nsecond\n");
    defer state.deinit(allocator);
    state.freshness = .fresh;
    state.viewer.focus = .source;
    state.viewer.source_cursor = 1;
    state.displayed_document.?.metadata = .{
        .modified_at = .{ .nanoseconds = 951_827_640 * std.time.ns_per_s },
    };
    try applyBundleStatusForTest(&state.bundle.?, " M main.zig\x00");

    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(120, 8);
    defer test_surface.deinit();
    try view(.{ .page_state = &state, .palette = .default() }, &test_surface.surface);
    {
        const snapshot = try test_surface.snapshot(allocator);
        defer allocator.free(snapshot);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "main.zig") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "Ln 2/2") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "modified") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "2000-02-29 12:34Z") == null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "commit —") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "second") != null);
    }

    const size = test_surface.surface.size();
    const layout = repository_layout.bodyLayout(size, state.viewer.tree_width, state.viewer.tree_hidden);
    const document = &state.displayed_document.?.value.source;
    const geometry = source_geometry.SourceGeometry.init(
        .{ .width = layout.source_width, .height = size.height },
        document,
        state.viewer.line_numbers,
    );
    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{
        .col = geometry.text_col,
        .row = geometry.body_first_row,
    } }, size);
    _ = state.applyNavigation(allocator, .{ .mouse_owner_drag = .{
        .col = geometry.text_col + 2,
        .row = geometry.body_first_row,
    } }, size);
    try std.testing.expect(state.liveSourceSelection() != null);
    test_surface.surface.clearAll();
    try view(.{ .page_state = &state, .palette = .default() }, &test_surface.surface);
    const selected_cell = test_surface.surface.readCell(
        layout.source_col + geometry.text_col,
        geometry.body_first_row,
    ) orelse return error.ExpectedLiveSelectionCell;
    try std.testing.expect(selected_cell.style.bg.eql(theme.Palette.default().color(.diff_cursor)));
    _ = state.applyNavigation(allocator, .cancel_mouse_owner, size);

    state.displayed_document.?.authority = .revalidation_required;
    test_surface.surface.clearAll();
    try view(.{ .page_state = &state, .palette = .default() }, &test_surface.surface);
    {
        const snapshot = try test_surface.snapshot(allocator);
        defer allocator.free(snapshot);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "Ln 2/2") == null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "2000-02-29") == null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "commit —") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "modified") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "second") != null);
    }

    state.displayed_document.?.authority = .accepted;
    _ = state.applyNavigation(allocator, .toggle_tree_visibility, size);
    test_surface.surface.clearAll();
    try view(.{ .page_state = &state, .palette = .default() }, &test_surface.surface);
    {
        const snapshot = try test_surface.snapshot(allocator);
        defer allocator.free(snapshot);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "Files") == null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "main.zig") != null);
        try test_surface.expectCellText(1, source_geometry.source_path_row, "m");
    }
    _ = state.applyNavigation(allocator, .toggle_tree_visibility, size);
    _ = state.applyNavigation(allocator, .enter_file_search, test_surface.surface.size());
    test_surface.surface.clearAll();
    try view(.{ .page_state = &state, .palette = .default() }, &test_surface.surface);
    {
        const snapshot = try test_surface.snapshot(allocator);
        defer allocator.free(snapshot);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "Find file:") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "Ln 2/2") == null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "2000-02-29") == null);
    }
}

test "repository page anchors inert checkpoint below source header rule" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("binary.dat\x00"),
        .load_state = .loaded,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    state.displayed_document = .{
        .path = try allocator.dupe(u8, state.selected_path.?),
        .manifest_revision = state.manifest_revision,
        .authority = .accepted,
        .value = .{ .inert = .binary },
    };

    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(60, 8);
    defer test_surface.deinit();
    try view(.{ .page_state = &state, .palette = .default() }, &test_surface.surface);

    const layout = repository_layout.bodyLayout(test_surface.surface.size(), state.viewer.tree_width, state.viewer.tree_hidden);
    try test_surface.expectCellText(
        layout.tree_width + 2,
        source_geometry.source_body_first_row,
        "B",
    );
    const inert_cell = test_surface.surface.readCell(layout.source_col + 1, source_geometry.source_body_first_row) orelse
        return error.ExpectedInertCheckpointCell;
    try std.testing.expect(inert_cell.style.fg.eql(theme.Palette.default().color(.muted)));
    try std.testing.expect(!inert_cell.style.dim);
    const source_rule = test_surface.surface.readCell(layout.tree_width + 1, source_geometry.source_search_or_rule_row) orelse
        return error.ExpectedSourceHeaderRuleCell;
    try std.testing.expectEqualStrings("─", source_rule.char.grapheme);
    try std.testing.expect(source_rule.style.fg.eql(.default));
    try std.testing.expect(source_rule.style.dim);

    state.viewer.tree_hidden = true;
    state.viewer.focus = .source;
    test_surface.surface.clearAll();
    try view(.{ .page_state = &state, .palette = .default() }, &test_surface.surface);
    const hidden_snapshot = try test_surface.snapshot(allocator);
    defer allocator.free(hidden_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, hidden_snapshot, "Files") == null);
    try std.testing.expect(std.mem.indexOf(u8, hidden_snapshot, "Binary file is not shown") != null);
}

test "repository filter discoverability header follows effective keymap and clips mode first" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("changed.zig\x00clean.zig\x00"),
        .load_state = .loaded,
        .freshness = .fresh,
    };
    defer state.deinit(allocator);
    try applyBundleStatusForTest(&state.bundle.?, " M changed.zig\x00");
    _ = state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 70, .height = 8 });

    {
        var test_surface: chasen.testing.TestSurface = undefined;
        try test_surface.init(70, 8);
        defer test_surface.deinit();
        try view(.{ .page_state = &state, .palette = .default() }, &test_surface.surface);
        const snapshot = try test_surface.snapshot(allocator);
        defer allocator.free(snapshot);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "Files [changed]  (F: toggle") != null);
        try test_surface.expectCellText(27, 2, "e");
        const mode_cell = test_surface.surface.readCell(1, 2) orelse return error.ExpectedFilterModeCell;
        const shortcut_cell = test_surface.surface.readCell(19, 2) orelse return error.ExpectedFilterShortcutCell;
        const palette: theme.Palette = .default();
        try std.testing.expect(mode_cell.style.fg.eql(palette.color(.accent)));
        try std.testing.expect(mode_cell.style.bold);
        try std.testing.expect(!mode_cell.style.dim);
        try std.testing.expect(shortcut_cell.style.fg.eql(palette.color(.muted)));
        try std.testing.expect(!shortcut_cell.style.bold);
        try std.testing.expect(shortcut_cell.style.dim);
    }

    var config: keymap.Config = .{};
    config.set(.changed_file_filter, .{ .plain_codepoint = 'z' });
    const effective = keymap.Effective.fromConfig(config);
    const toggle = repository_input.keyToMsg(repository_page.Msg, state.inputContext(effective), .{ .codepoint = 'z' }) orelse
        return error.ExpectedConfiguredFilterToggle;
    try std.testing.expectEqual(repository_page.Msg.toggle_changed_filter, toggle);
    _ = state.applyNavigation(allocator, toggle, .{ .width = 70, .height = 8 });
    try std.testing.expectEqual(repository_tree.Visibility.all, state.file_visibility);

    {
        var test_surface: chasen.testing.TestSurface = undefined;
        try test_surface.init(70, 8);
        defer test_surface.deinit();
        try view(.{
            .page_state = &state,
            .palette = .default(),
            .keymap = effective,
        }, &test_surface.surface);
        const snapshot = try test_surface.snapshot(allocator);
        defer allocator.free(snapshot);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "Files [all]  (z: toggle)") != null);
    }

    var unbound = effective;
    unbound.bindings[@intFromEnum(keymap.PublicAction.changed_file_filter)] = null;
    try std.testing.expect(repository_input.keyToMsg(repository_page.Msg, state.inputContext(unbound), .{ .codepoint = 'z' }) == null);
    {
        var test_surface: chasen.testing.TestSurface = undefined;
        try test_surface.init(70, 8);
        defer test_surface.deinit();
        try view(.{
            .page_state = &state,
            .palette = .default(),
            .keymap = unbound,
        }, &test_surface.surface);
        const snapshot = try test_surface.snapshot(allocator);
        defer allocator.free(snapshot);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "Files [all]") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "toggle") == null);
    }

    _ = state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 12, .height = 8 });
    {
        var test_surface: chasen.testing.TestSurface = undefined;
        try test_surface.init(12, 8);
        defer test_surface.deinit();
        try view(.{ .page_state = &state, .palette = .default() }, &test_surface.surface);
        const snapshot = try test_surface.snapshot(allocator);
        defer allocator.free(snapshot);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "Files [chan") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "…") == null);
        try std.testing.expectEqual(@as(u16, 12), repository_layout.bodyLayout(
            test_surface.surface.size(),
            state.viewer.tree_width,
            state.viewer.tree_hidden,
        ).tree_width);
    }
}

test "repository filter discoverability bundle-less Changed loading is safe" {
    const allocator = std.testing.allocator;
    const state: RepositoryPageState = .{
        .load_state = .loading,
        .file_visibility = .changed,
    };
    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(60, 8);
    defer test_surface.deinit();
    try view(.{ .page_state = &state, .palette = .default() }, &test_surface.surface);
    const snapshot = try test_surface.snapshot(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Loading repository files...") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Files [changed]") == null);
}

test "repository filter discoverability distinguishes loading unavailable and no-match states" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("main.zig\x00"),
        .load_state = .loaded,
        .freshness = .validating,
    };
    defer state.deinit(allocator);
    state.viewer.focus = .source;
    _ = state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 120, .height = 8 });

    {
        var test_surface: chasen.testing.TestSurface = undefined;
        try test_surface.init(120, 8);
        defer test_surface.deinit();
        const palette: theme.Palette = .default();
        try view(.{ .page_state = &state, .palette = palette }, &test_surface.surface);
        try test_surface.expectCellText(0, 2, " ");
        try test_surface.expectCellText(1, 2, "F");
        try test_surface.expectCellText(28, 2, ")");
        const layout = repository_layout.bodyLayout(.{ .width = 120, .height = 8 }, state.viewer.tree_width, state.viewer.tree_hidden);
        const message_cell = test_surface.surface.readCell(0, layout.header_rows + 1) orelse
            return error.ExpectedChangedFilesMessage;
        try std.testing.expect(message_cell.style.fg.eql(palette.color(.muted)));
        try std.testing.expect(!message_cell.style.dim);
        const snapshot = try test_surface.snapshot(allocator);
        defer allocator.free(snapshot);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "Files [changed]  (F: toggle)") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "Loading changed files...") != null);
    }

    state.freshness = .fresh;
    {
        var test_surface: chasen.testing.TestSurface = undefined;
        try test_surface.init(180, 8);
        defer test_surface.deinit();
        try view(.{ .page_state = &state, .palette = .default() }, &test_surface.surface);
        const snapshot = try test_surface.snapshot(allocator);
        defer allocator.free(snapshot);
        // The Review-compatible default keeps the source pane usable instead
        // of widening for prose, so assert the distinct state label that is
        // guaranteed to fit and let the existing narrow matrix cover clipping.
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "Changed-file status unavailable") != null);
    }

    const toggle = repository_input.keyToMsg(repository_page.Msg, state.inputContext(.{}), .{ .codepoint = 'F' }) orelse
        return error.ExpectedDefaultFilterToggle;
    _ = state.applyNavigation(allocator, toggle, .{ .width = 120, .height = 8 });
    try std.testing.expectEqual(repository_tree.Visibility.all, state.file_visibility);
    _ = state.applyNavigation(allocator, toggle, .{ .width = 120, .height = 8 });
    try std.testing.expectEqual(repository_tree.Visibility.changed, state.file_visibility);

    try applyBundleStatusForTest(&state.bundle.?, "");
    _ = state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 120, .height = 8 });
    _ = state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 120, .height = 8 });
    {
        var test_surface: chasen.testing.TestSurface = undefined;
        try test_surface.init(120, 8);
        defer test_surface.deinit();
        try view(.{
            .page_state = &state,
            .palette = .default(),
            .repo_root = "/work/clean-repo",
        }, &test_surface.surface);
        const snapshot = try test_surface.snapshot(allocator);
        defer allocator.free(snapshot);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "clean-repo") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "No changed files") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "No file selected") != null);
    }

    _ = state.applyNavigation(allocator, toggle, .{ .width = 120, .height = 8 });
    try std.testing.expectEqual(repository_tree.Visibility.all, state.file_visibility);
    {
        var test_surface: chasen.testing.TestSurface = undefined;
        try test_surface.init(120, 8);
        defer test_surface.deinit();
        try view(.{ .page_state = &state, .palette = .default() }, &test_surface.surface);
        const snapshot = try test_surface.snapshot(allocator);
        defer allocator.free(snapshot);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "Files [all]  (F: toggle)") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "main.zig") != null);
    }
    _ = state.applyNavigation(allocator, toggle, .{ .width = 120, .height = 8 });
    try std.testing.expectEqual(repository_tree.Visibility.changed, state.file_visibility);

    // At the minimum split width and five rows the full prose is clipped, but
    // each state still exposes a distinct leading label instead of falling
    // through to an empty All projection.
    const narrow_states = [_]struct { available: bool, freshness: @TypeOf(state.freshness), label: []const u8 }{
        .{ .available = false, .freshness = .validating, .label = "Loading" },
        .{ .available = false, .freshness = .fresh, .label = "Changed-" },
        .{ .available = true, .freshness = .fresh, .label = "No changed" },
    };
    for (narrow_states) |expected| {
        state.bundle.?.status_available = expected.available;
        state.freshness = expected.freshness;
        var test_surface: chasen.testing.TestSurface = undefined;
        try test_surface.init(24, 5);
        defer test_surface.deinit();
        try view(.{ .page_state = &state, .palette = .default() }, &test_surface.surface);
        const snapshot = try test_surface.snapshot(allocator);
        defer allocator.free(snapshot);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, expected.label) != null);
    }
}

test "repository transition direct unavailable renders byte-safe terminal" {
    const allocator = std.testing.allocator;
    const identity: root_capability.Identity = .{ .device = 3, .inode = 5 };
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("retained.zig\x00"),
        .load_state = .loaded,
        .repo_epoch = 4,
        .root_identity = identity,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();

    const raw_path = [_]u8{ 'o', 'l', 'd', '/', 0xff };
    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        4,
        identity,
        .{ .unavailable = .{ .path = &raw_path, .reason = .no_current_path } },
    );
    state.acceptIncoming(allocator, &incoming);
    try std.testing.expectEqualSlices(u8, &raw_path, state.incomingUnavailable().?.path);
    try std.testing.expectEqualStrings("retained.zig", state.selected_path.?);

    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(80, 6);
    defer test_surface.deinit();
    try view(.{ .page_state = &state, .palette = .default() }, &test_surface.surface);
    const snapshot = try test_surface.snapshot(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Repository target unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, page_link.RepositoryUnavailableReason.no_current_path.message()) != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "retained.zig") == null);

    _ = state.applyNavigation(allocator, .toggle_line_numbers, .{ .width = 80, .height = 6 });
    try std.testing.expect(state.incomingUnavailable() != null);
    _ = state.applyNavigation(allocator, .tree_first, .{ .width = 80, .height = 6 });
    try std.testing.expect(state.incomingUnavailable() == null);
}

test "repository page row rendering is bounded for multiple maximum names" {
    const raw = try std.testing.allocator.alloc(u8, manifest.max_path_bytes);
    defer std.testing.allocator.free(raw);
    @memset(raw, 0x01);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (0..4) |_| {
        const text = try treeRowTextAlloc(arena.allocator(), .{
            .kind = .file,
            .parent = null,
            .path = raw,
            .name = raw,
            .depth = 100,
        }, 100, 20);
        try std.testing.expect(text.len <= 20 * 4 + 8);
        try std.testing.expect(chasen.text.displayWidth(text) <= 20);
    }
}

test "repository root row renders markerless byte-safe basename" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const visible = try rootRowTextAlloc(arena.allocator(), "repo\xff\n", 0, 40);
    try std.testing.expectEqualStrings("repo\\xFF\\x0A", visible);
    const scrolled = try rootRowTextAlloc(arena.allocator(), "repo", 1, 40);
    try std.testing.expectEqualStrings("epo", scrolled);
}
