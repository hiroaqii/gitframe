//! History catalog rendering. Rows are projected only for the current
//! viewport and clipped through Chasen UI's terminal-cell presentation.

const std = @import("std");
const chasen = @import("chasen");
const ui = @import("chasen_ui");
const text_presentation = ui.text_presentation;
const draw = @import("draw");
const keymap = @import("keymap");
const local_time = @import("../../../local_time.zig");
const diff_surface = @import("../../diff_surface.zig");
const page_header = @import("../../page_header.zig");
const committed_diff_navigation = @import("../committed_diff/navigation.zig");
const diff_render = @import("../../../diff/render.zig");
const file_tree = @import("../../../file_tree.zig");
const git_history = @import("../../../git/history.zig");
const git_preview = @import("../../../git/history_preview.zig");
const history_page = @import("../history.zig");
const loaded_diff = @import("../../../loaded_diff.zig");
const root_capability = @import("../../../repo/root_capability.zig");
const theme = @import("theme");

const row_prefix_width: u16 = 2;
const commit_width: u16 = 7;
const date_width: u16 = 10;
const author_width: u16 = 13;
const column_gap: u16 = 2;
const topology_width: u16 = 1;
const topology_gap: u16 = 1;
const right_pane_leading_padding: u16 = 1;

const FieldLayout = struct {
    col: u16,
    width: u16,
};

const CommitRowLayout = struct {
    commit: FieldLayout,
    date: FieldLayout,
    author: FieldLayout,
    topology: FieldLayout,
    summary: FieldLayout,

    fn init(viewport_width: u16) CommitRowLayout {
        const commit_col = row_prefix_width;
        const date_col = commit_col + commit_width + column_gap;
        const author_col = date_col + date_width + column_gap;
        const topology_col = author_col + author_width + topology_gap;
        const summary_col = topology_col + topology_width + topology_gap;
        return .{
            .commit = .{ .col = commit_col, .width = commit_width },
            .date = .{ .col = date_col, .width = date_width },
            .author = .{ .col = author_col, .width = author_width },
            .topology = .{ .col = topology_col, .width = topology_width },
            .summary = .{ .col = summary_col, .width = viewport_width -| summary_col },
        };
    }
};

pub const PickerMarker = struct {
    pub const range_selected = "┃";
    pub const merge = "M";
    pub const root = "R";
    pub const unavailable_parent = "?";
};

pub const range_footer_text = "Range: " ++ PickerMarker.range_selected ++ " selected";

pub const ViewContext = struct {
    page_state: *const history_page.HistoryPageState,
    palette: theme.Palette,
    repo_root: ?[]const u8 = null,
    repo_epoch: u64 = 0,
    root_identity: ?root_capability.Identity = null,
    layout: diff_surface.Layout = .{ .width = 0, .height = 0 },
    keymap: keymap.Effective = .{},

    pub fn footer(self: ViewContext) diff_surface.view.FooterView {
        const navigation = navigationView(self);
        var resolver = navigation.resolver();
        var result = diff_surface.view.footer(.{
            .surface = navigation.view().surface,
            .auto_reload_enabled = false,
            .selection_action_visible = navigation.bodyView(&resolver).retainedSelectionActionAvailable(),
        });
        result.source_label = "commit history";
        return result;
    }
};

pub fn pageHeaderPresentation(context: ViewContext, allocator: std.mem.Allocator) ?page_header.Presentation {
    const page = context.page_state;
    if (page.current_view != .diff) return null;
    const accepted = if (page.accepted) |*value| value else return terminal(sourcePending(page), sourceFailed(page));
    const repository = page.diff.accepted_repository_identity orelse return terminal(sourcePending(page), sourceFailed(page));
    if (!repository.matches(context.repo_epoch, context.root_identity) or !page.diff.hasAcceptedDiff())
        return terminal(sourcePending(page), sourceFailed(page));

    const before = switch (accepted.request.basis.before) {
        .commit => |oid| oid.short(),
        .empty_tree => "empty tree",
    };
    const count = accepted.request.intent.commitCount();
    const base_label = std.fmt.allocPrint(
        allocator,
        "{d} {s} {s}",
        .{ count, if (count == 1) "commit" else "commits", before },
    ) catch return null;
    const selected_label = accepted.request.basis.after.short();
    const head_label = if (page.acceptedContextChanged()) blk: {
        const current = page.currentHeadContext() orelse break :blk selected_label;
        const current_label = headContextLabel(allocator, current) catch break :blk selected_label;
        break :blk std.fmt.allocPrint(
            allocator,
            "{s} · Current HEAD: {s}",
            .{ selected_label, current_label },
        ) catch selected_label;
    } else selected_label;
    return .{ .comparison = .{
        .base_display_name = base_label,
        .head_display_name = head_label,
        .freshness = if (sourcePending(page)) .refreshing else if (sourceFailed(page)) .stale else .fresh,
    } };
}

pub fn pageHeaderLineStats(context: ViewContext) ?file_tree.Stats {
    if (context.page_state.current_view != .diff) return null;
    return diff_surface.view.pageHeaderLineStats(navigationView(context).view().surface);
}

pub fn view(context: ViewContext, surface: *chasen.Surface) !void {
    if (context.page_state.current_view == .diff and context.page_state.accepted != null) {
        return viewDiff(context, surface);
    }
    return viewThreePane(context, surface);
}

pub const PickerLayout = struct {
    history: chasen.Rect,
    outer_divider: chasen.Rect,
    detail: chasen.Rect,
    inner_divider: chasen.Rect,
    files: chasen.Rect,

    pub fn focusAt(self: PickerLayout, point: diff_surface.MousePoint) ?history_page.interaction.Focus {
        if (rectContains(self.history, point)) return .history;

        const right_start = self.outer_divider.col +| self.outer_divider.width;
        const right_end = self.detail.col +| self.detail.width;
        if (point.col < right_start or point.col >= right_end) return null;
        if (rowInRect(self.detail, point.row)) return .commit_detail;
        if (rowInRect(self.files, point.row)) return .changed_files;
        return null;
    }
};

fn rectContains(rect: chasen.Rect, point: diff_surface.MousePoint) bool {
    return point.col >= rect.col and point.col < rect.col +| rect.width and rowInRect(rect, point.row);
}

fn rowInRect(rect: chasen.Rect, row: u16) bool {
    return row >= rect.row and row < rect.row +| rect.height;
}

pub fn pickerLayout(size: chasen.Size, state: history_page.interaction.State) PickerLayout {
    const outer = state.outerWidths(size.width);
    const history: chasen.Rect = .{
        .col = 0,
        .row = 0,
        .width = outer.left,
        .height = size.height,
    };
    const outer_divider: chasen.Rect = .{
        .col = outer.left,
        .row = 0,
        .width = outer.divider,
        .height = size.height,
    };
    const right_padding = @min(outer.right, right_pane_leading_padding);
    const right: chasen.Rect = .{
        .col = outer.left +| outer.divider +| right_padding,
        .row = 0,
        .width = outer.right - right_padding,
        .height = size.height,
    };
    var right_parts: [3]chasen.Rect = undefined;
    _ = ui.layout.splitVertical(&right_parts, right, &.{
        .{ .fill = 2 },
        .{ .length = 1 },
        .{ .fill = 3 },
    });
    return .{
        .history = history,
        .outer_divider = outer_divider,
        .detail = right_parts[0],
        .inner_divider = right_parts[1],
        .files = right_parts[2],
    };
}

pub fn moveDetail(
    page: *history_page.HistoryPageState,
    allocator: std.mem.Allocator,
    size: chasen.Size,
    action: history_page.interaction.VerticalAction,
) !void {
    const detail = readyDetail(page) orelse return;
    var projection = try DetailProjection.init(allocator, detail);
    defer projection.deinit(allocator);
    const body = paneBodyRect(pickerLayout(size, page.interaction_state).detail);
    page.interaction_state.moveDetail(projection.slice(), body.width, body.height, action);
}

pub fn moveFiles(
    page: *history_page.HistoryPageState,
    size: chasen.Size,
    action: history_page.interaction.VerticalAction,
) void {
    const files = readyFiles(page) orelse return;
    const body = paneBodyRect(pickerLayout(size, page.interaction_state).files);
    page.interaction_state.moveFilesVertical(files.len, body.height, action);
}

pub fn scrollFiles(
    page: *history_page.HistoryPageState,
    allocator: std.mem.Allocator,
    size: chasen.Size,
    action: history_page.interaction.HorizontalAction,
) !void {
    const files = readyFiles(page) orelse return;
    const body = paneBodyRect(pickerLayout(size, page.interaction_state).files);
    const columns = fileColumns(body.width, maxStatsWidth(files));
    page.interaction_state.moveFilesHorizontal(
        try maxPathCells(allocator, files),
        columns.path_width,
        action,
    );
}

pub fn reflowPreview(
    page: *history_page.HistoryPageState,
    allocator: std.mem.Allocator,
    size: chasen.Size,
) !void {
    const layout = pickerLayout(size, page.interaction_state);
    const detail_body = paneBodyRect(layout.detail);
    if (readyDetail(page)) |detail| {
        var projection = try DetailProjection.init(allocator, detail);
        defer projection.deinit(allocator);
        page.interaction_state.reflowDetail(projection.slice(), detail_body.width, detail_body.height);
    } else {
        page.interaction_state.detail_anchor = .{};
    }

    const files_body = paneBodyRect(layout.files);
    if (readyFiles(page)) |files| {
        const columns = fileColumns(files_body.width, maxStatsWidth(files));
        page.interaction_state.clampFiles(
            files.len,
            files_body.height,
            try maxPathCells(allocator, files),
            columns.path_width,
        );
    } else {
        page.interaction_state.files_vertical_offset = 0;
        page.interaction_state.files_horizontal_offset = 0;
    }
}

fn viewThreePane(context: ViewContext, surface: *chasen.Surface) !void {
    const layout = pickerLayout(surface.size(), context.page_state.interaction_state);
    var history_surface = surface.child(layout.history);
    try viewPicker(context, &history_surface, context.page_state.interaction_state.focus == .history);

    const divider = ui.Divider.init(.{});
    var outer_divider = surface.child(layout.outer_divider);
    divider.view(&outer_divider, .{
        .direction = .vertical,
        .glyph = "│",
        .style = context.palette.style(.muted),
    });

    var detail_surface = surface.child(layout.detail);
    try viewDetailPane(context, &detail_surface);
    var inner_divider = surface.child(layout.inner_divider);
    divider.view(&inner_divider, .{
        .direction = .horizontal,
        .glyph = "─",
        .style = context.palette.style(.muted),
    });
    var files_surface = surface.child(layout.files);
    try viewFilesPane(context, &files_surface);
}

fn paneBodyRect(rect: chasen.Rect) chasen.Rect {
    return .{
        .col = rect.col,
        .row = rect.row +| @min(rect.height, 1),
        .width = rect.width,
        .height = rect.height -| 1,
    };
}

fn drawPaneTitle(
    surface: *chasen.Surface,
    col: u16,
    title: []const u8,
    active: bool,
    palette: theme.Palette,
) !void {
    if (surface.size().height == 0) return;
    try drawClipped(
        surface,
        col,
        0,
        title,
        if (active) palette.boldStyle(.accent) else palette.style(.muted),
    );
}

fn viewDetailPane(context: ViewContext, surface: *chasen.Surface) !void {
    const active = context.page_state.interaction_state.focus == .commit_detail;
    try drawPaneTitle(surface, 0, detailTitle(context.page_state), active, context.palette);
    if (surface.size().height <= 1) return;
    var body = surface.child(.{
        .col = 0,
        .row = 1,
        .width = surface.size().width,
        .height = surface.size().height - 1,
    });
    const detail = readyDetail(context.page_state) orelse {
        try drawPaneMessage(&body, detailStateText(context.page_state), context.palette);
        return;
    };
    const projection = try DetailProjection.init(surface.frameAllocator(), detail);
    try drawDetailBlocks(
        &body,
        projection.slice(),
        context.page_state.interaction_state.detail_anchor,
        active,
        context.palette,
    );
}

fn viewFilesPane(context: ViewContext, surface: *chasen.Surface) !void {
    const active = context.page_state.interaction_state.focus == .changed_files;
    try drawPaneTitle(surface, 0, "Changed files", active, context.palette);
    if (surface.size().height <= 1) return;
    var body = surface.child(.{
        .col = 0,
        .row = 1,
        .width = surface.size().width,
        .height = surface.size().height - 1,
    });
    const files = readyFiles(context.page_state) orelse {
        try drawPaneMessage(&body, filesStateText(context.page_state), context.palette);
        return;
    };
    if (files.len == 0) {
        try drawPaneMessage(&body, "No changed files", context.palette);
        return;
    }

    const columns = fileColumns(body.size().width, maxStatsWidth(files));
    const start = @min(context.page_state.interaction_state.files_vertical_offset, files.len);
    const end = @min(files.len, start +| @as(usize, body.size().height));
    for (files[start..end], 0..) |file, visible_index| {
        const row: u16 = @intCast(visible_index);
        if (columns.status_width > 0) {
            try drawClipped(&body, 0, row, file.statusBadge(), fileStatusStyle(file.status(), context.palette));
        }
        if (columns.path_width > 0) {
            const path = try history_page.preview.pathFieldAlloc(body.frameAllocator(), file.kind);
            try drawProjectedWindow(
                &body,
                columns.path_col,
                row,
                path,
                context.page_state.interaction_state.files_horizontal_offset,
                columns.path_width,
                chasen.TextStyle{},
            );
        }
        if (columns.stats_width > 0) {
            switch (file.stats) {
                .text => |stats| {
                    var stats_area = body.child(.{
                        .col = columns.stats_col,
                        .row = row,
                        .width = columns.stats_width,
                        .height = 1,
                    });
                    const added = try std.fmt.allocPrint(body.frameAllocator(), "+{d}", .{stats.added});
                    const removed = try std.fmt.allocPrint(body.frameAllocator(), "-{d}", .{stats.removed});
                    try drawClipped(&stats_area, 0, 0, added, .{ .fg = context.palette.color(.success), .bold = true });
                    const removed_col: u16 = @intCast(@min(
                        chasen.text.displayWidth(added) +| 1,
                        std.math.maxInt(u16),
                    ));
                    if (removed_col > 0) try drawClipped(&stats_area, removed_col - 1, 0, " ", context.palette.style(.muted));
                    try drawClipped(&stats_area, removed_col, 0, removed, .{ .fg = context.palette.color(.danger), .bold = true });
                },
                else => try drawClipped(
                    &body,
                    columns.stats_col,
                    row,
                    try statsText(body.frameAllocator(), file.stats),
                    context.palette.style(.muted),
                ),
            }
        }
    }
}

fn fileStatusStyle(status: git_preview.FileStatus, palette: theme.Palette) chasen.TextStyle {
    return .{
        .fg = palette.color(switch (status) {
            .modified, .type_changed => .prompt,
            .added => .success,
            .deleted => .danger,
            .renamed => .accent,
        }),
        .bold = true,
    };
}

fn drawPaneMessage(surface: *chasen.Surface, message: []const u8, palette: theme.Palette) !void {
    if (surface.size().width == 0 or surface.size().height == 0) return;
    try drawClipped(surface, 0, 0, message, palette.style(.muted));
}

fn detailTitle(page: *const history_page.HistoryPageState) []const u8 {
    if (page.preview_state.accepted) |accepted| return switch (accepted.payload.detail) {
        .ready => |detail| switch (detail) {
            .single => "Commit detail",
            .range => "Range summary",
        },
        else => selectionTitle(accepted.key.identity.selection),
    };
    if (page.preview_state.current_key) |key| return selectionTitle(key.identity.selection);
    return "Commit detail";
}

fn selectionTitle(summary: git_preview.SelectionSummary) []const u8 {
    return switch (summary) {
        .single => "Commit detail",
        .range => "Range summary",
    };
}

fn detailStateText(page: *const history_page.HistoryPageState) []const u8 {
    if (page.preview_state.accepted) |accepted| return switch (accepted.payload.detail) {
        .ready => unreachable,
        .too_large => "Detail too large",
        .unavailable => "Detail unavailable",
        .failed => "Detail failed",
    };
    return phaseText(page.preview_state.phase);
}

fn filesStateText(page: *const history_page.HistoryPageState) []const u8 {
    if (page.preview_state.accepted) |accepted| return switch (accepted.payload.files) {
        .ready => unreachable,
        .too_large => "File list too large",
        .unavailable => "File list unavailable",
        .failed => "File list failed",
    };
    return phaseText(page.preview_state.phase);
}

fn phaseText(phase: history_page.preview.Phase) []const u8 {
    return switch (phase) {
        .idle => "Preview idle",
        .loading => "Loading preview…",
        .resolved => "Preview unavailable",
        .terminal => |admission| switch (admission) {
            .malformed => "Preview malformed",
            .unavailable => "Preview unavailable",
            .too_large => "Preview too large",
            .failed => "Preview failed",
        },
    };
}

fn readyDetail(page: *const history_page.HistoryPageState) ?git_preview.Detail {
    const current = page.preview_state.current_key orelse return null;
    if (page.preview_state.accepted) |accepted| {
        if (accepted.key.eql(current)) return switch (accepted.payload.detail) {
            .ready => |detail| detail,
            else => null,
        };
    }
    return switch (current.identity.selection) {
        .single => null,
        .range => |range| .{ .range = range },
    };
}

fn readyFiles(page: *const history_page.HistoryPageState) ?[]const git_preview.FileChange {
    const accepted = page.preview_state.accepted orelse return null;
    return switch (accepted.payload.files) {
        .ready => |files| files,
        else => null,
    };
}

const DetailProjection = struct {
    payload: []u8,
    blocks: [10]history_page.interaction.DetailBlock = undefined,
    len: usize = 0,

    fn init(allocator: std.mem.Allocator, detail: git_preview.Detail) !DetailProjection {
        var result: DetailProjection = .{
            .payload = try history_page.preview.canonicalDetailAlloc(allocator, detail),
        };
        errdefer allocator.free(result.payload);
        var remaining: []const u8 = result.payload;
        const expected: usize = switch (detail) {
            .single => 10,
            .range => 5,
        };
        while (result.len < expected) : (result.len += 1) {
            if (expected == 10 and result.len == 9) {
                const prefix = "Message:\n";
                if (!std.mem.startsWith(u8, remaining, prefix)) return error.MalformedDetailPresentation;
                result.blocks[result.len] = .{ .label = "Message: ", .value = remaining[prefix.len..] };
                remaining = "";
                continue;
            }
            const line_end = std.mem.indexOfScalar(u8, remaining, '\n') orelse remaining.len;
            const line = remaining[0..line_end];
            const separator = std.mem.indexOf(u8, line, ": ") orelse return error.MalformedDetailPresentation;
            result.blocks[result.len] = .{
                .label = line[0 .. separator + 2],
                .value = line[separator + 2 ..],
            };
            remaining = if (line_end < remaining.len) remaining[line_end + 1 ..] else "";
        }
        if (remaining.len != 0) return error.MalformedDetailPresentation;
        return result;
    }

    fn deinit(self: *DetailProjection, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        self.* = undefined;
    }

    fn slice(self: *const DetailProjection) []const history_page.interaction.DetailBlock {
        return self.blocks[0..self.len];
    }
};

fn drawDetailBlocks(
    surface: *chasen.Surface,
    blocks: []const history_page.interaction.DetailBlock,
    anchor: history_page.interaction.ContentAnchor,
    active: bool,
    palette: theme.Palette,
) !void {
    var lines = (history_page.interaction.DetailLayout{
        .blocks = blocks,
        .width = surface.size().width,
    }).lineStarts();
    var current = lines.next();
    var row: u16 = 0;
    var started = false;
    while (current) |line| {
        const next = lines.next();
        if (!started and (line.block_index > anchor.block_index or
            (line.block_index == anchor.block_index and line.source_byte_offset >= anchor.source_byte_offset)))
        {
            started = true;
        }
        if (started and row < surface.size().height) {
            const block = blocks[line.block_index];
            var end = if (next) |next_line|
                if (next_line.block_index == line.block_index) next_line.source_byte_offset else block.value.len
            else
                block.value.len;
            if (end > line.source_byte_offset and block.value[end - 1] == '\n') end -= 1;
            const label_width: u16 = @intCast(@min(chasen.text.displayWidth(block.label), std.math.maxInt(u16)));
            if (line.source_byte_offset == 0) {
                try drawClipped(
                    surface,
                    0,
                    row,
                    block.label,
                    if (active) palette.boldStyle(.accent) else palette.style(.prompt),
                );
            }
            try drawClipped(
                surface,
                @min(label_width, surface.size().width -| 1),
                row,
                block.value[line.source_byte_offset..end],
                chasen.TextStyle{},
            );
            row += 1;
        }
        if (row >= surface.size().height) break;
        current = next;
    }
}

const FileColumns = struct {
    status_width: u16,
    path_col: u16,
    path_width: u16,
    stats_col: u16,
    stats_width: u16,
};

fn fileColumns(width: u16, requested_stats_width: u16) FileColumns {
    const status_width: u16 = @min(width, 1);
    const first_gap: u16 = @min(width -| status_width, 1);
    const remaining = width -| status_width -| first_gap;
    const stats_width = if (remaining >= 2) @min(requested_stats_width, remaining - 2) else 0;
    const stats_gap = if (stats_width > 0 and remaining > stats_width) @as(u16, 1) else 0;
    const path_width = remaining -| stats_gap -| stats_width;
    const path_col = status_width +| first_gap;
    return .{
        .status_width = status_width,
        .path_col = path_col,
        .path_width = path_width,
        .stats_col = path_col +| path_width +| stats_gap,
        .stats_width = stats_width,
    };
}

fn maxStatsWidth(files: []const git_preview.FileChange) u16 {
    var result: usize = 0;
    for (files) |file| result = @max(result, statsTextWidth(file.stats));
    return @intCast(@min(result, 43));
}

fn statsTextWidth(stats: git_preview.StatsKind) usize {
    return switch (stats) {
        .text => |text| std.fmt.count("+{d} -{d}", .{ text.added, text.removed }),
        .binary => "binary".len,
        .mode_only => "mode".len,
        .submodule => "submodule".len,
    };
}

fn statsText(allocator: std.mem.Allocator, stats: git_preview.StatsKind) ![]const u8 {
    return switch (stats) {
        .text => |text| try std.fmt.allocPrint(allocator, "+{d} -{d}", .{ text.added, text.removed }),
        .binary => "binary",
        .mode_only => "mode",
        .submodule => "submodule",
    };
}

fn maxPathCells(allocator: std.mem.Allocator, files: []const git_preview.FileChange) !usize {
    var result: usize = 0;
    for (files) |file| {
        const path = try history_page.preview.pathFieldAlloc(allocator, file.kind);
        defer allocator.free(path);
        const projection = try ui.text_projection.Projection.init(path, .{ .tab_width = 4 });
        result = @max(result, projection.displayWidth());
    }
    return result;
}

fn drawProjectedWindow(
    surface: *chasen.Surface,
    start_col: u16,
    row: u16,
    text: []const u8,
    offset: usize,
    width: u16,
    style: chasen.TextStyle,
) !void {
    if (width == 0 or start_col >= surface.size().width or row >= surface.size().height) return;
    const projection = try ui.text_projection.Projection.init(text, .{ .tab_width = 4 });
    var visible = projection.visibleSegments(offset, width);
    var col = start_col;
    while (visible.next()) |segment| switch (segment.materialization) {
        .source => |bytes| {
            _ = surface.borrowTextAt(col, row, bytes, style);
            col +|= @intCast(@min(chasen.text.displayWidth(bytes), std.math.maxInt(u16)));
        },
        .spaces => |count| {
            var index: usize = 0;
            while (index < count and col < start_col +| width) : (index += 1) {
                _ = surface.borrowTextAt(col, row, " ", style);
                col +|= 1;
            }
        },
    };
}

fn viewPicker(context: ViewContext, surface: *chasen.Surface, pane_active: bool) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;
    const page = context.page_state;
    try drawPaneTitle(surface, row_prefix_width, "History", pane_active, context.palette);

    if (page.load_state == .no_repository) {
        drawState(surface, context.palette, "History", "History requires a repository", "R: switch repository");
        return;
    }
    if (page.catalog_hidden) {
        const title = if (page.currentHeadContext()) |snapshot|
            try std.fmt.allocPrint(surface.frameAllocator(), "History  {s}", .{try headContextLabel(surface.frameAllocator(), snapshot)})
        else
            "History";
        const message = if (page.load_state == .failed)
            page.status.text()
        else
            "Loading current commit history…";
        const previous = if (page.accepted) |accepted|
            try previousDiffLabel(surface.frameAllocator(), accepted)
        else
            null;
        const hint = if (page.load_state == .failed)
            if (previous) |label|
                try std.fmt.allocPrint(surface.frameAllocator(), "{s}  ·  r: retry  ·  Esc: previous diff", .{label})
            else
                "r: retry"
        else if (previous) |label|
            try std.fmt.allocPrint(surface.frameAllocator(), "{s}  ·  Esc: previous diff", .{label})
        else
            "Esc: cancel";
        drawState(surface, context.palette, title, message, hint);
        return;
    }
    if (page.catalog.snapshot == null) {
        if (page.load_state == .failed) {
            const hint = if (page.accepted) |accepted|
                try std.fmt.allocPrint(
                    surface.frameAllocator(),
                    "{s}  ·  r: retry  ·  Esc: previous diff",
                    .{try previousDiffLabel(surface.frameAllocator(), accepted)},
                )
            else
                "r: retry";
            drawState(surface, context.palette, "History unavailable", page.status.text(), hint);
        } else if (page.load_state == .idle) {
            drawState(surface, context.palette, "History", page.status.text(), "r: retry");
        } else {
            drawState(surface, context.palette, "History", "Loading commit history…", "Esc: cancel");
        }
        return;
    }

    const snapshot = &page.catalog.snapshot.?;
    const previous = if (page.acceptedContextChanged())
        try previousDiffLabel(surface.frameAllocator(), page.accepted.?)
    else
        null;
    try drawCatalogContext(surface, context.palette, page, snapshot, previous, pane_active);

    if (page.catalog.records.items.len == 0) {
        if (size.height > 1) try drawClipped(
            surface,
            row_prefix_width,
            1,
            if (previous != null) "No commits yet  ·  r: reload  ·  Esc: previous diff" else "No commits yet  ·  r: reload",
            context.palette.style(.muted),
        );
        return;
    }

    const range = page.catalog.visibleRange(size.height);
    for (range.start..range.end) |index| {
        const row: u16 = @intCast(1 + index - range.start);
        if (row >= size.height) break;
        const selected = index == page.catalog.cursor;
        const focused = selected and pane_active;
        if (focused) fillSelectedRow(surface, row, context.palette.color(.pane_cursor_bg));
        if (index == page.catalog.records.items.len) {
            try drawClipped(surface, 0, row, if (selected) "›" else " ", catalogStyle(context.palette, .prompt, focused));
            if (page.load_state == .loading) {
                try drawClipped(
                    surface,
                    row_prefix_width,
                    row,
                    "Loading older commits…",
                    catalogStyle(context.palette, .prompt, focused),
                );
            } else {
                var enter_style = catalogStyle(context.palette, .accent, focused);
                enter_style.bold = true;
                try drawClipped(surface, row_prefix_width, row, "[Enter]", enter_style);
                try drawClipped(
                    surface,
                    row_prefix_width + 7,
                    row,
                    " Load 200 older commits…",
                    catalogStyle(context.palette, .prompt, focused),
                );
            }
            continue;
        }
        const record = &page.catalog.records.items[index];
        const range_marker: ?[]const u8 = if (page.draft.anchor()) |anchor|
            if (index == anchor or page.draft.contains(page.catalog.cursor, index))
                PickerMarker.range_selected
            else
                null
        else
            null;
        try drawClipped(
            surface,
            0,
            row,
            if (selected) "›" else " ",
            catalogStyle(context.palette, if (focused) .accent else .info, focused),
        );
        if (range_marker) |marker| try drawClipped(surface, 1, row, marker, rangeMarkerStyle(context.palette, focused));
        try drawCommitRow(surface, row, record, context.palette, focused);
    }
}

fn viewDiff(context: ViewContext, surface: *chasen.Surface) !void {
    const navigation = navigationView(context);
    var mode_key_buffer: [16]u8 = undefined;
    var filter_key_buffer: [16]u8 = undefined;
    var pane = DiffPaneAdapter{
        .context = navigation,
        .palette = context.palette,
        .mode_toggle_key = displayModeToggleKey(context, mode_key_buffer[0..]),
    };
    try diff_surface.view.view(surface, .{
        .state = navigation.view().surface,
        .palette = context.palette,
        .source_label = "commit history",
        .repo_root = context.repo_root,
        .file_filter_binding = context.keymap.display(.changed_file_filter, filter_key_buffer[0..]),
        .no_changes_actions = .{},
        .empty_message = try emptyStateMessage(surface.frameAllocator(), context.page_state.accepted.?),
        .diff_pane = pane.interface(),
    });
}

fn navigationView(context: ViewContext) committed_diff_navigation.View {
    var key_buffer: [16]u8 = undefined;
    return .{
        .diff = &context.page_state.diff,
        .activation = &context.page_state.activation,
        .status = &context.page_state.status,
        .current_target = null,
        .presentation_identity = context.page_state.currentPresentationIdentity(),
        .repo_root = context.repo_root,
        .repo_epoch = context.repo_epoch,
        .root_identity = context.root_identity,
        .source = history_page.selection_source,
        .layout = context.layout,
        .mode_toggle_hint_width = diff_render.modeToggleHintWidth(displayModeToggleKey(context, key_buffer[0..])),
        .live_drag_deferred_source = false,
    };
}

fn displayModeToggleKey(context: ViewContext, buffer: []u8) ?[]const u8 {
    if (context.page_state.diff.search.mode or context.page_state.diff.file_search.mode) return null;
    return context.keymap.display(.toggle_display_mode, buffer);
}

const DiffPaneAdapter = struct {
    context: committed_diff_navigation.View,
    palette: theme.Palette,
    mode_toggle_key: ?[]const u8,

    fn interface(self: *DiffPaneAdapter) diff_surface.view.DiffPaneRenderer {
        return .{ .ctx = self, .render_fn = render };
    }

    fn render(ctx: *anyopaque, surface: *chasen.Surface, loaded: loaded_diff.LoadedDiff) !void {
        const self: *DiffPaneAdapter = @ptrCast(@alignCast(ctx));
        var resolver = self.context.resolver();
        return diff_surface.view.viewDiffPane(
            surface,
            self.context.bodyView(&resolver),
            loaded,
            self.palette,
            null,
            self.mode_toggle_key,
            .{},
        );
    }
};

fn emptyStateMessage(allocator: std.mem.Allocator, accepted: history_page.AcceptedSelection) !diff_surface.view.StateMessage {
    const count = accepted.request.intent.commitCount();
    const body = switch (accepted.request.intent) {
        .single => if (accepted.request.basis.before == .empty_tree)
            try std.fmt.allocPrint(allocator, "Root commit {s} has no changed files.", .{accepted.request.basis.after.short()})
        else if (accepted.selected_parent_count > 1)
            try std.fmt.allocPrint(allocator, "Merge commit {s} has no changes against parent 1/{d}.", .{ accepted.request.basis.after.short(), accepted.selected_parent_count })
        else
            try std.fmt.allocPrint(allocator, "Commit {s} has no changed files.", .{accepted.request.basis.after.short()}),
        .range => try std.fmt.allocPrint(allocator, "The selected {d}-commit range has no net file changes.", .{count}),
    };
    return .{
        .title = "No changed files",
        .body = body,
        .hint = "Press m to choose another History selection.",
    };
}

fn sourcePending(page: *const history_page.HistoryPageState) bool {
    return switch (page.activation.state) {
        .active => |active| active.members.source == .pending,
        .inactive => false,
    };
}

fn sourceFailed(page: *const history_page.HistoryPageState) bool {
    return switch (page.activation.state) {
        .active => |active| active.members.source == .failed,
        .inactive => false,
    };
}

fn terminal(pending: bool, failed: bool) ?page_header.Presentation {
    if (pending) return .{ .terminal = .{ .kind = .comparison, .state = .loading } };
    if (failed) return .{ .terminal = .{ .kind = .comparison, .state = .unavailable } };
    return null;
}

const CatalogPosition = struct {
    full: []const u8,
    compact: []const u8,
};

fn drawCatalogContext(
    surface: *chasen.Surface,
    palette: theme.Palette,
    page: *const history_page.HistoryPageState,
    snapshot: *const git_history.Snapshot,
    previous: ?[]const u8,
    pane_active: bool,
) !void {
    const size = surface.size();
    if (size.width <= row_prefix_width or size.height == 0) return;
    const allocator = surface.frameAllocator();
    const base = try std.fmt.allocPrint(
        allocator,
        "History · {s}",
        .{try catalogHeadContextLabel(allocator, snapshot)},
    );
    var left = base;
    if (page.catalog.capped) {
        left = try std.fmt.allocPrint(allocator, "{s} · Limit: 2,000 commits loaded", .{left});
    } else if (page.load_state == .loading) {
        left = try std.fmt.allocPrint(allocator, "{s} · Loading…", .{left});
    }
    if (previous) |label| {
        left = try std.fmt.allocPrint(allocator, "{s} · {s}", .{ left, label });
    }

    const position = try catalogPositionLabel(allocator, page);
    const right_padding: u16 = 1;
    const content_width: u16 = size.width - row_prefix_width -| right_padding;
    const left_text_width = chasen.text.displayWidth(left);
    const full_width = chasen.text.displayWidth(position.full);
    const compact_width = chasen.text.displayWidth(position.compact);
    const right = if (left_text_width +| column_gap +| full_width <= content_width)
        position.full
    else if (left_text_width +| column_gap +| compact_width <= content_width)
        position.compact
    else
        null;

    if (right) |right_text| {
        const right_width = chasen.text.displayWidth(right_text);
        const right_col: u16 = size.width - right_padding - @as(u16, @intCast(right_width));
        const left_width = right_col -| column_gap -| row_prefix_width;
        try drawClippedField(
            surface,
            row_prefix_width,
            0,
            left_width,
            left,
            if (pane_active) palette.boldStyle(.accent) else palette.style(.muted),
        );
        try drawClipped(surface, right_col, 0, right_text, palette.style(.muted));
        return;
    }

    try drawClipped(
        surface,
        row_prefix_width,
        0,
        left,
        if (pane_active) palette.boldStyle(.accent) else palette.style(.muted),
    );
}

fn catalogHeadContextLabel(allocator: std.mem.Allocator, snapshot: *const git_history.Snapshot) ![]const u8 {
    return switch (snapshot.display) {
        .branch => |branch| if (snapshot.head) |head|
            try std.fmt.allocPrint(allocator, "Branch {s} · HEAD {s}", .{ branch, head.short() })
        else
            try std.fmt.allocPrint(allocator, "Branch {s} · HEAD unavailable", .{branch}),
        .detached => if (snapshot.head) |head|
            try std.fmt.allocPrint(allocator, "Detached HEAD {s}", .{head.short()})
        else
            "Detached HEAD unavailable",
        .unborn => |branch| try std.fmt.allocPrint(allocator, "Branch {s} · Unborn", .{branch}),
    };
}

fn catalogPositionLabel(allocator: std.mem.Allocator, page: *const history_page.HistoryPageState) !CatalogPosition {
    const loaded = page.catalog.records.items.len;
    if (page.catalog.moreRowSelected()) return .{
        .full = try std.fmt.allocPrint(allocator, "{d} commits loaded · more available", .{loaded}),
        .compact = try std.fmt.allocPrint(allocator, "{d} loaded · more", .{loaded}),
    };
    if (loaded == 0) return .{
        .full = "0 commits loaded",
        .compact = "0 loaded",
    };
    const position = @min(page.catalog.cursor, loaded - 1) + 1;
    if (page.catalog.total_count) |total| return .{
        .full = try std.fmt.allocPrint(allocator, "Commit {d} of {d}", .{ position, total }),
        .compact = try std.fmt.allocPrint(allocator, "{d}/{d}", .{ position, total }),
    };
    return .{
        .full = try std.fmt.allocPrint(allocator, "Commit {d} of {d} loaded", .{ position, loaded }),
        .compact = try std.fmt.allocPrint(allocator, "{d}/{d}", .{ position, loaded }),
    };
}

fn headContextLabel(allocator: std.mem.Allocator, snapshot: *const git_history.Snapshot) ![]const u8 {
    return switch (snapshot.display) {
        .branch => |branch| if (snapshot.head) |head|
            try std.fmt.allocPrint(allocator, "{s} @ {s}", .{ branch, head.short() })
        else
            try std.fmt.allocPrint(allocator, "{s} (unborn)", .{branch}),
        .detached => if (snapshot.head) |head|
            try std.fmt.allocPrint(allocator, "detached @ {s}", .{head.short()})
        else
            "detached",
        .unborn => |branch| try std.fmt.allocPrint(allocator, "{s} (unborn)", .{branch}),
    };
}

fn previousDiffLabel(allocator: std.mem.Allocator, accepted: history_page.AcceptedSelection) ![]const u8 {
    const context = switch (accepted.origin) {
        .branch => |branch| try std.fmt.allocPrint(
            allocator,
            "{s} @ {s}",
            .{ branch, accepted.request.snapshot_head.short() },
        ),
        .detached => try std.fmt.allocPrint(
            allocator,
            "detached @ {s}",
            .{accepted.request.snapshot_head.short()},
        ),
        .unborn => |branch| try std.fmt.allocPrint(
            allocator,
            "{s} @ {s}",
            .{ branch, accepted.request.snapshot_head.short() },
        ),
    };
    return std.fmt.allocPrint(allocator, "Previous diff: {s}", .{context});
}

fn topologyMarker(record: *const git_history.Record) []const u8 {
    return switch (record.first_parent) {
        .true_root => PickerMarker.root,
        .missing => PickerMarker.unavailable_parent,
        .available => if (record.parent_count > 1) PickerMarker.merge else " ",
    };
}

fn drawCommitRow(
    surface: *chasen.Surface,
    row: u16,
    record: *const git_history.Record,
    palette: theme.Palette,
    focused: bool,
) !void {
    const layout = CommitRowLayout.init(surface.size().width);
    try drawClippedField(
        surface,
        layout.commit.col,
        row,
        layout.commit.width,
        record.oid.short(),
        catalogStyle(palette, .accent, focused),
    );
    const formatted_date = local_time.formatDate(record.committer_unix);
    try drawClippedField(
        surface,
        layout.date.col,
        row,
        layout.date.width,
        if (formatted_date) |*value| value[0..] else "—",
        catalogStyle(palette, .muted, focused),
    );
    try drawClippedField(
        surface,
        layout.author.col,
        row,
        layout.author.width,
        record.author,
        catalogStyle(palette, .info, focused),
    );
    try drawClippedField(
        surface,
        layout.topology.col,
        row,
        layout.topology.width,
        topologyMarker(record),
        catalogStyle(palette, if (focused) .accent else .info, focused),
    );
    try drawSummaryFields(surface, row, layout.summary, record, palette, focused);
}

fn drawSummaryFields(
    surface: *chasen.Surface,
    row: u16,
    field: FieldLayout,
    record: *const git_history.Record,
    palette: theme.Palette,
    focused: bool,
) !void {
    if (field.width == 0) return;
    if (record.decorations.len == 0) {
        try drawClippedField(
            surface,
            field.col,
            row,
            field.width,
            record.subject,
            catalogStyle(palette, .foreground, focused),
        );
        return;
    }

    const refs = try std.fmt.allocPrint(surface.frameAllocator(), "[{s}]", .{record.decorations});
    const refs_width = chasen.text.displayWidth(refs);
    if (refs_width >= field.width) {
        try drawClippedField(surface, field.col, row, field.width, refs, catalogStyle(palette, .prompt, focused));
        return;
    }

    try drawClippedField(surface, field.col, row, refs_width, refs, catalogStyle(palette, .prompt, focused));
    const subject_col = field.col +| refs_width +| 1;
    const subject_width = field.width -| refs_width -| 1;
    try drawClippedField(
        surface,
        subject_col,
        row,
        subject_width,
        record.subject,
        catalogStyle(palette, .foreground, focused),
    );
}

fn catalogStyle(palette: theme.Palette, role: theme.Role, focused: bool) chasen.TextStyle {
    var style = palette.style(role);
    if (focused) {
        style.bold = true;
        style.bg = palette.color(.pane_cursor_bg);
    }
    return style;
}

fn rangeMarkerStyle(palette: theme.Palette, focused: bool) chasen.TextStyle {
    var style = catalogStyle(palette, .accent, focused);
    style.bold = true;
    return style;
}

fn fillSelectedRow(surface: *chasen.Surface, row: u16, background: chasen.Color) void {
    const style = chasen.TextStyle{ .bg = background };
    for (0..surface.size().width) |col| {
        _ = surface.borrowTextAt(@intCast(col), row, " ", style);
    }
}

fn drawClippedField(
    surface: *chasen.Surface,
    col: u16,
    row: u16,
    width: u16,
    text: []const u8,
    style: chasen.TextStyle,
) !void {
    const size = surface.size();
    if (width == 0 or col >= size.width or row >= size.height) return;
    var field = surface.child(.{
        .col = col,
        .row = row,
        .width = @min(width, size.width - col),
        .height = 1,
    });
    try drawClipped(&field, 0, 0, text, style);
}

fn drawState(surface: *chasen.Surface, palette: theme.Palette, title: []const u8, body: []const u8, hint: []const u8) void {
    const size = surface.size();
    const row = size.height / 2;
    drawClipped(surface, row_prefix_width, row, title, palette.boldStyle(.accent)) catch {};
    if (row + 1 < size.height) drawClipped(surface, row_prefix_width, row + 1, body, palette.style(.muted)) catch {};
    if (row + 2 < size.height) drawClipped(surface, row_prefix_width, row + 2, hint, palette.style(.prompt)) catch {};
}

fn drawClipped(surface: *chasen.Surface, col: u16, row: u16, text: []const u8, style: chasen.TextStyle) !void {
    try text_presentation.drawClippedAt(surface, col, row, text, style, .{
        .tab_width = 4,
        .marker = "…",
        .direction = .head,
    });
}

test "History preview three pane layout is exact and saturates a tiny body" {
    const layout = pickerLayout(.{ .width = 120, .height = 27 }, .{});
    try std.testing.expectEqual(chasen.Rect{ .col = 0, .row = 0, .width = 71, .height = 27 }, layout.history);
    try std.testing.expectEqual(chasen.Rect{ .col = 71, .row = 0, .width = 1, .height = 27 }, layout.outer_divider);
    try std.testing.expectEqual(chasen.Rect{ .col = 73, .row = 0, .width = 47, .height = 11 }, layout.detail);
    try std.testing.expectEqual(chasen.Rect{ .col = 73, .row = 11, .width = 47, .height = 1 }, layout.inner_divider);
    try std.testing.expectEqual(chasen.Rect{ .col = 73, .row = 12, .width = 47, .height = 15 }, layout.files);

    const tiny = pickerLayout(.{ .width = 1, .height = 0 }, .{});
    for ([_]chasen.Rect{ tiny.history, tiny.outer_divider, tiny.detail, tiny.inner_divider, tiny.files }) |rect| {
        try std.testing.expect(rect.col +| rect.width <= 1);
        try std.testing.expectEqual(@as(u16, 0), rect.height);
    }
}

test "History preview three pane renders focus structured detail and flat files" {
    const before = try git_history.ObjectId.parse(.sha1, "1111111111111111111111111111111111111111");
    const after = try git_history.ObjectId.parse(.sha1, "2222222222222222222222222222222222222222");
    const oldest = try git_history.ObjectId.parse(.sha1, "3333333333333333333333333333333333333333");
    const summary: git_preview.RangeSummary = .{
        .count = 3,
        .oldest_oid = oldest,
        .newest_oid = after,
        .basis = .{ .object_format = .sha1, .before = .{ .commit = before }, .after = after },
    };
    const path = "src/history/preview-with-a-very-long-component-name-that-needs-horizontal-scrolling.zig";
    var files = [_]git_preview.FileChange{.{
        .kind = .{ .modified = @constCast(path) },
        .old_mode = 0o100644,
        .new_mode = 0o100644,
        .old_oid = before,
        .new_oid = after,
        .stats = .{ .text = .{ .added = 3, .removed = 1 } },
    }};
    var page_state: history_page.HistoryPageState = .{};
    defer {
        page_state.preview_state.accepted = null;
        page_state.deinit(std.testing.allocator);
    }
    page_state.interaction_state.focus = .changed_files;
    page_state.preview_state.phase = .resolved;
    page_state.preview_state.accepted = .{
        .key = .{
            .identity = .{
                .page = .{ .origin = .history, .repo_epoch = 1, .activation_id = 1 },
                .root = .{ .device = 1, .inode = 2 },
                .catalog_instance = 1,
                .selection = .{ .range = summary },
            },
            .generation = 1,
        },
        .payload = .{
            .detail = .{ .ready = .{ .range = summary } },
            .files = .{ .ready = files[0..] },
        },
    };
    page_state.preview_state.current_key = page_state.preview_state.accepted.?.key;

    var palette = theme.Palette.default();
    palette.colors[@intFromEnum(theme.Role.accent)] = .{ .rgb = .{ 1, 2, 3 } };
    palette.colors[@intFromEnum(theme.Role.prompt)] = .{ .rgb = .{ 4, 5, 6 } };
    palette.colors[@intFromEnum(theme.Role.success)] = .{ .rgb = .{ 7, 8, 9 } };
    palette.colors[@intFromEnum(theme.Role.danger)] = .{ .rgb = .{ 10, 11, 12 } };
    var rendered: chasen.testing.TestSurface = undefined;
    try rendered.init(120, 27);
    defer rendered.deinit();
    try view(.{ .page_state = &page_state, .palette = palette }, &rendered.surface);

    const snapshot = try rendered.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "History") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Range summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Changed files") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Count: 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "src/history/preview-with") != null);
    const layout = pickerLayout(rendered.surface.size(), page_state.interaction_state);
    try rendered.expectCellText(layout.outer_divider.col, 0, "│");
    const divider_cell = rendered.surface.readCell(layout.outer_divider.col, 0) orelse return error.ExpectedOuterDivider;
    try std.testing.expect(divider_cell.style.fg.eql(palette.color(.muted)));
    try rendered.expectCellText(layout.inner_divider.col, layout.inner_divider.row, "─");
    const horizontal_divider_cell = rendered.surface.readCell(layout.inner_divider.col, layout.inner_divider.row) orelse return error.ExpectedInnerDivider;
    try std.testing.expect(horizontal_divider_cell.style.fg.eql(palette.color(.muted)));
    try rendered.expectCellText(layout.files.col, layout.files.row, "C");
    const files_body = paneBodyRect(layout.files);
    try rendered.expectCellText(files_body.col, files_body.row, "M");
    const columns = fileColumns(files_body.width, maxStatsWidth(&files));
    try rendered.expectCellText(files_body.col + columns.path_col, files_body.row, "s");
    try rendered.expectCellText(files_body.col + columns.stats_col, files_body.row, "+");
    const active_title = rendered.surface.readCell(layout.files.col, layout.files.row) orelse return error.ExpectedActivePaneTitle;
    try std.testing.expect(active_title.style.bold);
    try std.testing.expect(active_title.style.fg.eql(palette.color(.accent)));
    const status_cell = rendered.surface.readCell(files_body.col, files_body.row) orelse return error.ExpectedFileStatus;
    try std.testing.expect(status_cell.style.bold);
    try std.testing.expect(status_cell.style.fg.eql(palette.color(.prompt)));
    const added_cell = rendered.surface.readCell(files_body.col + columns.stats_col, files_body.row) orelse return error.ExpectedAddedStats;
    const removed_cell = rendered.surface.readCell(files_body.col + columns.stats_col + 3, files_body.row) orelse return error.ExpectedRemovedStats;
    try std.testing.expect(added_cell.style.bold);
    try std.testing.expect(added_cell.style.fg.eql(palette.color(.success)));
    try std.testing.expect(removed_cell.style.bold);
    try std.testing.expect(removed_cell.style.fg.eql(palette.color(.danger)));
    const status_cases = [_]struct { status: git_preview.FileStatus, role: theme.Role }{
        .{ .status = .modified, .role = .prompt },
        .{ .status = .added, .role = .success },
        .{ .status = .deleted, .role = .danger },
        .{ .status = .renamed, .role = .accent },
        .{ .status = .type_changed, .role = .prompt },
    };
    for (status_cases) |case| {
        const style = fileStatusStyle(case.status, palette);
        try std.testing.expect(style.bold);
        try std.testing.expect(style.fg.eql(palette.color(case.role)));
    }

    try scrollFiles(&page_state, std.testing.allocator, .{ .width = 120, .height = 27 }, .right);
    try std.testing.expectEqual(@as(usize, 1), page_state.interaction_state.files_horizontal_offset);
    var scrolled: chasen.testing.TestSurface = undefined;
    try scrolled.init(120, 27);
    defer scrolled.deinit();
    try view(.{ .page_state = &page_state, .palette = palette }, &scrolled.surface);
    try scrolled.expectCellText(files_body.col, files_body.row, "M");
    try scrolled.expectCellText(files_body.col + columns.path_col, files_body.row, "r");
    try scrolled.expectCellText(files_body.col + columns.stats_col, files_body.row, "+");

    const blocks = [_]history_page.interaction.DetailBlock{.{
        .label = "Message: ",
        .value = "abcdefghijk",
    }};
    var wrapped: chasen.testing.TestSurface = undefined;
    try wrapped.init(14, 3);
    defer wrapped.deinit();
    try drawDetailBlocks(&wrapped.surface, &blocks, .{}, false, palette);
    try wrapped.expectCellText(9, 0, "a");
    try wrapped.expectCellText(9, 1, "f");

    const completed = page_state.preview_state.accepted.?;
    page_state.preview_state.accepted = null;
    page_state.preview_state.phase = .loading;
    var loading: chasen.testing.TestSurface = undefined;
    try loading.init(120, 27);
    defer loading.deinit();
    try view(.{ .page_state = &page_state, .palette = palette }, &loading.surface);
    const loading_snapshot = try loading.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(loading_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, loading_snapshot, "Count: 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, loading_snapshot, "Loading preview…") != null);

    // A resize can land while the reader is active. The later completion uses
    // the current geometry, preserving the visible range-summary position and
    // retaining no unavailable file-list offset.
    page_state.interaction_state.detail_anchor = .{ .block_index = 9, .source_byte_offset = 99 };
    page_state.interaction_state.files_vertical_offset = 99;
    page_state.interaction_state.files_horizontal_offset = 99;
    try reflowPreview(&page_state, std.testing.allocator, .{ .width = 62, .height = 13 });
    const resized_anchor = page_state.interaction_state.detail_anchor;
    try std.testing.expectEqual(@as(usize, 0), page_state.interaction_state.files_vertical_offset);
    try std.testing.expectEqual(@as(usize, 0), page_state.interaction_state.files_horizontal_offset);
    page_state.preview_state.accepted = completed;
    page_state.preview_state.phase = .resolved;
    try reflowPreview(&page_state, std.testing.allocator, .{ .width = 62, .height = 13 });
    try std.testing.expectEqual(resized_anchor, page_state.interaction_state.detail_anchor);
    try std.testing.expectEqual(@as(usize, 0), page_state.interaction_state.files_vertical_offset);
    try std.testing.expectEqual(@as(usize, 0), page_state.interaction_state.files_horizontal_offset);
}

test "History catalog renders selected rows at 80x24 and 120x32" {
    const allocator = std.testing.allocator;
    const head = try git_history.ObjectId.parse(.sha1, "1111111111111111111111111111111111111111");
    const parent = try git_history.ObjectId.parse(.sha1, "2222222222222222222222222222222222222222");
    const root = try git_history.ObjectId.parse(.sha1, "3333333333333333333333333333333333333333");
    const records = try allocator.alloc(git_history.Record, 3);
    records[0] = .{
        .oid = head,
        .parent_count = 2,
        .first_parent = .{ .available = parent },
        .author = try allocator.dupe(u8, "Ada Lovelace"),
        .committer_unix = 1_720_000_000,
        .decorations = try allocator.dupe(u8, "HEAD -> main"),
        .subject = try allocator.dupe(u8, "catalog head"),
    };
    records[1] = .{
        .oid = parent,
        .parent_count = 1,
        .first_parent = .{ .available = root },
        .author = try allocator.dupe(u8, "Grace 界界e\u{301} Hopper"),
        .committer_unix = 1_710_000_000,
        .decorations = try allocator.dupe(u8, ""),
        .subject = try allocator.dupe(u8, "catalog middle"),
    };
    records[2] = .{
        .oid = root,
        .parent_count = 0,
        .first_parent = .true_root,
        .author = try allocator.dupe(u8, "Margaret Hamilton"),
        .committer_unix = 1_700_000_000,
        .decorations = try allocator.dupe(u8, "root-tag"),
        .subject = try allocator.dupe(u8, "日本語 root subject"),
    };
    var page: git_history.Page = .{
        .snapshot = .{
            .object_format = .sha1,
            .head = head,
            .display = .{ .branch = try allocator.dupe(u8, "main") },
        },
        .total_count = 1024,
        .records = records,
    };
    defer page.deinit(allocator);
    var page_state: history_page.HistoryPageState = .{ .load_state = .loaded };
    defer page_state.deinit(allocator);
    try page_state.catalog.replace(allocator, &page);
    page_state.render_now_unix = 1_720_086_400;
    page_state.draft = .{ .range = 0 };
    page_state.catalog.cursor = 2;
    var palette = theme.Palette.default();
    palette.colors[@intFromEnum(theme.Role.accent)] = .{ .rgb = .{ 1, 2, 3 } };
    palette.colors[@intFromEnum(theme.Role.muted)] = .{ .rgb = .{ 4, 5, 6 } };
    palette.colors[@intFromEnum(theme.Role.info)] = .{ .rgb = .{ 7, 8, 9 } };
    palette.colors[@intFromEnum(theme.Role.prompt)] = .{ .rgb = .{ 10, 11, 12 } };
    palette.colors[@intFromEnum(theme.Role.foreground)] = .{ .rgb = .{ 13, 14, 15 } };
    palette.colors[@intFromEnum(theme.Role.pane_cursor_bg)] = .{ .rgb = .{ 16, 17, 18 } };

    for ([_]chasen.Size{
        .{ .width = 80, .height = 24 },
        .{ .width = 120, .height = 32 },
    }) |size| {
        var rendered: chasen.testing.TestSurface = undefined;
        try rendered.init(size.width, size.height);
        defer rendered.deinit();
        try viewPicker(.{ .page_state = &page_state, .palette = palette }, &rendered.surface, true);
        const snapshot = try rendered.snapshot(allocator);
        defer allocator.free(snapshot);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "Branch main · HEAD 1111111") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "Commit 3 of 1024") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "catalog head") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "commit   subject") == null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "HiHistory") == null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "root subject") != null);
        try rendered.expectCellText(row_prefix_width, 0, "H");
        const layout = CommitRowLayout.init(size.width);
        try rendered.expectCellText(layout.commit.col, 1, "1");
        try rendered.expectCellText(layout.date.col, 1, "2");
        try rendered.expectCellText(layout.author.col, 1, "A");
        try rendered.expectCellText(layout.summary.col, 1, "[");
        try std.testing.expectEqualStrings("4", rendered.surface.readCell(size.width - 2, 0).?.char.grapheme);
        try std.testing.expectEqualStrings(" ", rendered.surface.readCell(size.width - 1, 0).?.char.grapheme);

        const refs_width = chasen.text.displayWidth("[HEAD -> main]");
        for ([_]struct { col: u16, role: theme.Role }{
            .{ .col = layout.commit.col, .role = .accent },
            .{ .col = layout.date.col, .role = .muted },
            .{ .col = layout.author.col, .role = .info },
            .{ .col = layout.topology.col, .role = .info },
            .{ .col = layout.summary.col, .role = .prompt },
            .{ .col = layout.summary.col + refs_width + 1, .role = .foreground },
        }) |expected| {
            const cell = rendered.surface.readCell(expected.col, 1) orelse return error.ExpectedHistoryField;
            try std.testing.expect(cell.style.fg.eql(palette.color(expected.role)));
            try std.testing.expect(!cell.style.bg.eql(palette.color(.pane_cursor_bg)));
        }

        const selected_refs_width = chasen.text.displayWidth("[root-tag]");
        for ([_]struct { col: u16, role: theme.Role }{
            .{ .col = layout.commit.col, .role = .accent },
            .{ .col = layout.date.col, .role = .muted },
            .{ .col = layout.author.col, .role = .info },
            .{ .col = layout.topology.col, .role = .accent },
            .{ .col = layout.summary.col, .role = .prompt },
            .{ .col = layout.summary.col + selected_refs_width + 1, .role = .foreground },
        }) |expected| {
            const cell = rendered.surface.readCell(expected.col, 3) orelse return error.ExpectedSelectedHistoryField;
            try std.testing.expect(cell.style.fg.eql(palette.color(expected.role)));
            try std.testing.expect(cell.style.bg.eql(palette.color(.pane_cursor_bg)));
            try std.testing.expect(cell.style.bold);
        }
        try std.testing.expect(rendered.surface.readCell(size.width - 1, 3).?.style.bg.eql(palette.color(.pane_cursor_bg)));

        const merge_marker = rendered.surface.readCell(layout.topology.col, 1) orelse return error.ExpectedTopologyMarker;
        try std.testing.expectEqualStrings(PickerMarker.merge, merge_marker.char.grapheme);
        try std.testing.expect(merge_marker.style.fg.eql(palette.color(.info)));
        try std.testing.expect(!merge_marker.style.dim);
        try std.testing.expect(!merge_marker.style.bg.eql(palette.color(.pane_cursor_bg)));
        const selected_root_marker = rendered.surface.readCell(layout.topology.col, 3) orelse return error.ExpectedTopologyMarker;
        try std.testing.expectEqualStrings(PickerMarker.root, selected_root_marker.char.grapheme);
        try std.testing.expect(selected_root_marker.style.fg.eql(palette.color(.accent)));
        try std.testing.expect(!selected_root_marker.style.dim);
        try std.testing.expect(selected_root_marker.style.bg.eql(palette.color(.pane_cursor_bg)));

        for ([_]u16{ 1, 2, 3 }) |row| {
            const cell = rendered.surface.readCell(1, row) orelse return error.ExpectedRangeMarker;
            try std.testing.expectEqualStrings(PickerMarker.range_selected, cell.char.grapheme);
            try std.testing.expect(cell.style.fg.eql(palette.color(.accent)));
            try std.testing.expect(cell.style.bold);
            try std.testing.expectEqual(row == 3, cell.style.bg.eql(palette.color(.pane_cursor_bg)));
        }
        if (size.width == 120) {
            try std.testing.expect(std.mem.indexOf(u8, snapshot, "Ada Lovelace") != null);
        }
    }

    page_state.catalog.snapshot.?.display.deinit(allocator);
    page_state.catalog.snapshot.?.display = .detached;
    const older_oid = try git_history.ObjectId.parse(.sha1, "4444444444444444444444444444444444444444");
    page_state.catalog.continuation = older_oid;
    page_state.catalog.cursor = page_state.catalog.records.items.len;
    var detached_more: chasen.testing.TestSurface = undefined;
    try detached_more.init(80, 24);
    defer detached_more.deinit();
    try viewPicker(.{ .page_state = &page_state, .palette = .default() }, &detached_more.surface, true);
    const detached_more_snapshot = try detached_more.snapshot(allocator);
    defer allocator.free(detached_more_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, detached_more_snapshot, "Detached HEAD 1111111") != null);
    try std.testing.expect(std.mem.indexOf(u8, detached_more_snapshot, "3 commits loaded · more available") != null);
    try std.testing.expect(std.mem.indexOf(u8, detached_more_snapshot, "Load 200 older commits…") != null);

    var older_page: git_history.Page = .{ .records = try allocator.alloc(git_history.Record, 1) };
    older_page.records[0] = .{
        .oid = older_oid,
        .parent_count = 0,
        .first_parent = .true_root,
        .author = try allocator.dupe(u8, "界界界界界界e\u{301} appended author"),
        .committer_unix = 0,
        .decorations = try allocator.dupe(u8, "older-tag-with-a-long-name"),
        .subject = try allocator.dupe(u8, "appended subject stays in the same column"),
    };
    defer older_page.deinit(allocator);
    try page_state.catalog.append(allocator, &older_page);
    page_state.catalog.cursor = 3;
    var appended: chasen.testing.TestSurface = undefined;
    try appended.init(80, 24);
    defer appended.deinit();
    try viewPicker(.{ .page_state = &page_state, .palette = .default() }, &appended.surface, true);
    const appended_layout = CommitRowLayout.init(80);
    try appended.expectCellText(appended_layout.commit.col, 4, "4");
    try appended.expectCellText(appended_layout.date.col, 4, "1");
    try appended.expectCellText(appended_layout.author.col, 4, "界");
    try appended.expectCellText(appended_layout.summary.col, 4, "[");

    page_state.accepted = .{
        .request = .{
            .snapshot_head = head,
            .intent = .{ .single = .{ .index = 0, .oid = head } },
            .basis = .{
                .object_format = .sha1,
                .before = .{ .commit = parent },
                .after = head,
            },
        },
        .origin = .{ .branch = try allocator.dupe(u8, "main") },
        .selected_parent_count = 2,
    };
    page_state.catalog.snapshot.?.display.deinit(allocator);
    page_state.catalog.snapshot.?.display = .{ .branch = try allocator.dupe(u8, "feature") };
    page_state.catalog.snapshot.?.head = parent;

    var changed: chasen.testing.TestSurface = undefined;
    try changed.init(120, 32);
    defer changed.deinit();
    try viewPicker(.{ .page_state = &page_state, .palette = .default() }, &changed.surface, true);
    const changed_snapshot = try changed.snapshot(allocator);
    defer allocator.free(changed_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, changed_snapshot, "Branch feature · HEAD 2222222") != null);
    try std.testing.expect(std.mem.indexOf(u8, changed_snapshot, "Previous diff: main @ 1111111") != null);

    page_state.catalog.capped = true;
    var capped: chasen.testing.TestSurface = undefined;
    try capped.init(120, 32);
    defer capped.deinit();
    try viewPicker(.{ .page_state = &page_state, .palette = .default() }, &capped.surface, true);
    const capped_snapshot = try capped.snapshot(allocator);
    defer allocator.free(capped_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, capped_snapshot, "Limit: 2,000 commits loaded") != null);
    try std.testing.expect(std.mem.indexOf(u8, capped_snapshot, "Previous diff: main @ 1111111") != null);

    var unborn_page: git_history.Page = .{ .snapshot = .{
        .object_format = .sha1,
        .head = null,
        .display = .{ .unborn = try allocator.dupe(u8, "future") },
    } };
    defer unborn_page.deinit(allocator);
    try page_state.catalog.replace(allocator, &unborn_page);
    page_state.load_state = .empty;

    var unborn: chasen.testing.TestSurface = undefined;
    try unborn.init(80, 24);
    defer unborn.deinit();
    try viewPicker(.{ .page_state = &page_state, .palette = .default() }, &unborn.surface, true);
    const unborn_snapshot = try unborn.snapshot(allocator);
    defer allocator.free(unborn_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, unborn_snapshot, "Branch future · Unborn") != null);
    try std.testing.expect(std.mem.indexOf(u8, unborn_snapshot, "Previous diff: main @ 1111111") != null);
    try std.testing.expect(std.mem.indexOf(u8, unborn_snapshot, "r: reload  ·  Esc: previous diff") != null);

    page_state.observed_context = .{
        .object_format = .sha1,
        .head = parent,
        .display = .{ .branch = try allocator.dupe(u8, "broken") },
    };
    page_state.catalog_hidden = true;
    page_state.load_state = .failed;
    page_state.status.set("History load failed: git_command_failed", .{});

    var failed: chasen.testing.TestSurface = undefined;
    try failed.init(80, 24);
    defer failed.deinit();
    try viewPicker(.{ .page_state = &page_state, .palette = .default() }, &failed.surface, true);
    const failed_snapshot = try failed.snapshot(allocator);
    defer allocator.free(failed_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, failed_snapshot, "History  broken @ 2222222") != null);
    try std.testing.expect(std.mem.indexOf(u8, failed_snapshot, "History load failed: git_command_failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, failed_snapshot, "Previous diff: main @ 1111111") != null);
    try std.testing.expect(std.mem.indexOf(u8, failed_snapshot, "r: retry") != null);
    try std.testing.expect(std.mem.indexOf(u8, failed_snapshot, "Esc: previous diff") != null);
}

test "History accepted header keeps only count endpoints and current HEAD context" {
    const allocator = std.testing.allocator;
    const before = try git_history.ObjectId.parse(.sha1, "1111111111111111111111111111111111111111");
    const after = try git_history.ObjectId.parse(.sha1, "2222222222222222222222222222222222222222");
    const oldest = try git_history.ObjectId.parse(.sha1, "3333333333333333333333333333333333333333");
    const Kind = enum { normal, root, merge, range };
    const cases = [_]struct {
        kind: Kind,
        detached: bool,
        expected_base: []const u8,
        expected_head: []const u8,
    }{
        .{
            .kind = .normal,
            .detached = false,
            .expected_base = "1 commit 1111111",
            .expected_head = "2222222",
        },
        .{
            .kind = .root,
            .detached = false,
            .expected_base = "1 commit empty tree",
            .expected_head = "2222222",
        },
        .{
            .kind = .merge,
            .detached = false,
            .expected_base = "1 commit 1111111",
            .expected_head = "2222222",
        },
        .{
            .kind = .range,
            .detached = true,
            .expected_base = "3 commits 1111111",
            .expected_head = "2222222 · Current HEAD: topic @ 3333333",
        },
    };

    for (cases) |case| {
        const intent: git_history.SelectionIntent = switch (case.kind) {
            .normal, .root, .merge => .{ .single = .{ .index = 0, .oid = after } },
            .range => .{ .range = .{
                .anchor_index = 3,
                .cursor_index = 1,
                .newest_index = 1,
                .oldest_index = 3,
                .newest_oid = after,
                .oldest_oid = oldest,
            } },
        };
        const origin: git_history.HeadDisplay = if (case.detached)
            .detached
        else
            .{ .branch = try allocator.dupe(u8, "selection-origin") };
        var page_state: history_page.HistoryPageState = .{
            .repo_epoch = 7,
            .current_view = .diff,
            .observed_context = if (case.kind == .range) .{
                .object_format = .sha1,
                .head = oldest,
                .display = .{ .branch = try allocator.dupe(u8, "topic") },
            } else null,
            .accepted = .{
                .request = .{
                    .snapshot_head = after,
                    .intent = intent,
                    .basis = .{
                        .object_format = .sha1,
                        .before = if (case.kind == .root) .empty_tree else .{ .commit = before },
                        .after = after,
                    },
                },
                .origin = origin,
                .selected_parent_count = if (case.kind == .merge) 2 else if (case.kind == .root) 0 else 1,
            },
            .diff = .{
                .load = .{ .state = .{ .empty = .no_changes } },
                .accepted_repository_identity = .{ .repo_epoch = 7, .root_identity = null },
            },
        };
        defer page_state.deinit(allocator);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const presentation = pageHeaderPresentation(.{
            .page_state = &page_state,
            .palette = .default(),
            .repo_epoch = 7,
        }, arena.allocator()).?;
        const comparison = presentation.comparison;
        try std.testing.expectEqualStrings(case.expected_base, comparison.base_display_name);
        try std.testing.expectEqualStrings(case.expected_head, comparison.head_display_name);

        const line = (try page_header.formatAlloc(arena.allocator(), presentation, 120)).?;
        const expected_line = try std.fmt.allocPrint(
            arena.allocator(),
            "BASE {s}  …  HEAD {s}",
            .{ case.expected_base, case.expected_head },
        );
        try std.testing.expectEqualStrings(expected_line, line);
    }
}

test "History fixed row fields clip ASCII wide and combining metadata without overlap" {
    const oid = try git_history.ObjectId.parse(.sha1, "1111111111111111111111111111111111111111");
    const parent = try git_history.ObjectId.parse(.sha1, "2222222222222222222222222222222222222222");
    const record: git_history.Record = .{
        .oid = oid,
        .parent_count = 1,
        .first_parent = .{ .available = parent },
        .author = @constCast("界界界界界界e\u{301} author suffix"),
        .committer_unix = 0,
        .decorations = @constCast("refs-wide-界界界"),
        .subject = @constCast("a long subject that must remain inside the surface"),
    };
    const unavailable: git_history.Record = .{
        .oid = parent,
        .parent_count = 0,
        .first_parent = .true_root,
        .author = @constCast("an ASCII author name far beyond fourteen cells"),
        .committer_unix = -1,
        .decorations = @constCast(""),
        .subject = @constCast("subject without refs"),
    };

    var rendered: chasen.testing.TestSurface = undefined;
    try rendered.init(80, 2);
    defer rendered.deinit();
    const palette = theme.Palette.default();
    try drawCommitRow(&rendered.surface, 0, &record, palette, false);
    try drawCommitRow(&rendered.surface, 1, &unavailable, palette, false);

    const layout = CommitRowLayout.init(80);
    try rendered.expectCellText(layout.commit.col, 0, "1");
    try rendered.expectCellText(layout.date.col, 0, "1");
    try rendered.expectCellText(layout.author.col, 0, "界");
    try rendered.expectCellText(layout.summary.col, 0, "[");
    const refs_width = chasen.text.displayWidth("[refs-wide-界界界]");
    try rendered.expectCellText(layout.summary.col + refs_width + 1, 0, "a");
    try rendered.expectCellText(layout.date.col, 1, "—");
    try rendered.expectCellText(layout.author.col, 1, "a");
    try rendered.expectCellText(layout.summary.col, 1, "s");

    const snapshot = try rendered.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    const epoch_date = local_time.formatDate(0).?;
    try std.testing.expect(std.mem.indexOf(u8, snapshot, &epoch_date) != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "author suffix") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "subject without refs") != null);
}
