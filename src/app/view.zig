const std = @import("std");
const chasen = @import("chasen");
const ui = @import("chasen_ui");
const app_commit_panel = @import("commit_panel.zig");
const app_repo_picker = @import("repo_picker.zig");
const draw = @import("draw");
const diff_render = @import("../diff/render.zig");
const git_branch_status = @import("../git/branch_status.zig");
const git_status = @import("../git/status.zig");
const keymap = @import("keymap");
const loaded_diff = @import("../loaded_diff.zig");
const file_tree = @import("../file_tree.zig");
const sidebar_view_model = @import("../sidebar/view_model.zig");

/// Rendering-only helpers for App.
///
/// This module intentionally does not own state transitions. It borrows the
/// App state, projects it to terminal surfaces, and keeps layout constants
/// shared with tests through small public helpers.
pub const footer_rows: u16 = 1;
pub const sidebar_header_rows: u16 = 3;
pub const diff_body_start_row: u16 = diff_render.body_start_row;

const search_marker_gutter_width: u16 = 1;
const shell_frame_min_width: u16 = 30;
const shell_frame_min_height: u16 = 6;
const shell_frame_border = ui.Panel.Border.rounded;
const shell_frame_padding: ui.layout.Insets = .{};
const help_dialog_max_width: u16 = 108;
const help_dialog_max_height: u16 = 34;
const help_two_column_min_width: u16 = 96;
const help_column_gap: u16 = 2;
const help_header_rows: u16 = 2;
const help_scroll_indicator_rows: u16 = 1;
const commit_dialog_width: u16 = 80;
const repo_picker_dialog_width: u16 = 80;
const push_error_dialog_max_width: u16 = 90;
const push_error_dialog_min_height: u16 = 16;
const repo_picker_filter_input_col: u16 = 8;
const repo_picker_path_input_col: u16 = 11;
const repo_picker_list_label_col: u16 = 4;
const commit_dialog_height: u16 = 22;
const confirmation_dialog_width: u16 = 72;
const confirmation_dialog_height: u16 = 9;

const color_accent = chasen.Color{ .index = 14 };
const color_prompt = chasen.Color{ .index = 11 };
const color_staged = chasen.Color{ .index = 10 };
const color_success = chasen.Color{ .index = 2 };
const color_warning = chasen.Color{ .index = 11 };
const color_danger = chasen.Color{ .index = 9 };
const color_info = chasen.Color{ .index = 12 };
const color_binary = chasen.Color{ .index = 13 };
// Amend rewrites history, so it uses a distinct accent from normal commit UI.
const amend_accent = chasen.Color{ .rgb = .{ 203, 166, 247 } };

const StateTone = enum {
    muted,
    loading,
    warning,
    failure,
};

const StateMessage = struct {
    title: []const u8,
    body: []const u8 = "",
    hint: []const u8 = "",
    tone: StateTone = .muted,
};

pub fn view(app: anytype, surface: *chasen.Surface) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    surface.hideCursor();

    if (shellFrameEnabled(size)) {
        const frame = ui.Panel.frame(surface, shellFrameOptions());
        frame.view();
        var content = frame.contentSurface();
        try viewContent(app, &content);
        return;
    }

    try viewContent(app, surface);
}

fn viewContent(app: anytype, surface: *chasen.Surface) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    const footer_row = size.height - footer_rows;
    var body = surface.child(.{
        .col = 0,
        .row = 0,
        .width = size.width,
        .height = footer_row,
    });
    try viewBody(app, &body);

    var footer = surface.child(.{
        .col = 0,
        .row = footer_row,
        .width = size.width,
        .height = footer_rows,
    });
    viewFooter(app, &footer);

    if (app.repo_picker.mode) {
        try viewRepoPicker(app, surface);
    }
    if (app.overlay.isHelp()) {
        try viewHelpPopup(app, surface);
    }
    if (app.commit_panel.is_open and !app.overlay.isAmendCommit()) {
        try viewCommitPanel(app, surface);
    }
    if (app.overlay.isDiscardFile()) {
        try viewDiscardConfirmation(app, surface);
    }
    if (app.overlay.isAmendCommit()) {
        try viewAmendConfirmation(app, surface);
    }
    if (app.overlay.isPushBranch()) {
        try viewPushConfirmation(app, surface);
    }
    if (app.overlay.isPushError()) {
        try viewPushError(app, surface);
    }
}

fn shellFrameOptions() ui.Panel.ViewOptions {
    return .{
        .title = "GitFrame",
        .padding = shell_frame_padding,
        .border = shell_frame_border,
        .border_style = .{ .dim = true },
        .title_style = .{ .bold = true, .fg = .gray },
    };
}

pub fn shellFrameEnabled(size: chasen.Size) bool {
    return size.width >= shell_frame_min_width and size.height >= shell_frame_min_height;
}

pub fn shellContentSize(terminal_size: chasen.Size) chasen.Size {
    const rect = shellContentRect(terminal_size);
    return .{ .width = rect.width, .height = rect.height };
}

pub fn shellContentRect(terminal_size: chasen.Size) chasen.Rect {
    const root_rect: chasen.Rect = .{
        .col = 0,
        .row = 0,
        .width = terminal_size.width,
        .height = terminal_size.height,
    };
    if (!shellFrameEnabled(terminal_size)) return root_rect;
    return ui.Panel.contentRectFor(root_rect, shell_frame_padding);
}

fn viewBody(app: anytype, surface: *chasen.Surface) !void {
    switch (app.load.state) {
        .loaded => |session| return viewLoadedDiff(app, surface, session.loaded),
        else => {},
    }

    const size = surface.size();
    const title = "GitFrame";
    const subtitle = "Read-only diff viewer shell";

    var panel = surface.child(.{
        .col = if (size.width > 60) (size.width - 60) / 2 else 0,
        .row = if (size.height > 10) (size.height - 10) / 2 else 0,
        .width = @min(size.width, 60),
        .height = if (size.height > 10) 10 else size.height,
    });
    var col = panel.column(.{ .gap = 1 });
    col.borrowText(title, .{ .bold = true, .fg = color_accent });
    col.borrowText(subtitle, .{ .fg = .gray });
    try col.print("Source: {s}", .{app.config.sourceLabel()});
    viewLoadState(app, &col);
}

fn viewLoadedDiff(app: anytype, surface: *chasen.Surface, loaded: loaded_diff.LoadedDiff) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    if (app.viewer.sidebar_hidden) {
        if (loaded.visibleNodeCount() == 0) {
            drawStateMessage(surface, filterEmptyMessage(app));
            return;
        }
        try viewDiffPane(app, surface, loaded);
        return;
    }

    const sidebar_width = sidebarWidth(size.width, app.viewer.sidebar_width);
    var sidebar = surface.child(.{
        .col = 0,
        .row = 0,
        .width = sidebar_width,
        .height = size.height,
    });
    try viewSidebar(app, &sidebar, loaded);

    if (size.width > sidebar_width) {
        var row: u16 = 0;
        while (row < size.height) : (row += 1) {
            _ = surface.borrowTextAt(sidebar_width, row, "│", shellSeparatorStyle());
        }
    }

    if (size.width <= sidebar_width + 1) return;
    var diff_pane = surface.child(.{
        .col = sidebar_width + 1,
        .row = 0,
        .width = size.width - sidebar_width - 1,
        .height = size.height,
    });
    if (loaded.visibleNodeCount() == 0) {
        drawStateMessage(&diff_pane, filterEmptyMessage(app));
        return;
    }
    try viewDiffPane(app, &diff_pane, loaded);
}

/// Draw the file tree side pane from the materialized sidebar view-model.
pub fn viewSidebar(app: anytype, surface: *chasen.Surface, loaded: loaded_diff.LoadedDiff) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    const active = app.viewer.focus == .sidebar;
    try drawSidebarDetailRow(app, surface, 0, active);

    if (size.height <= 2) return;
    _ = surface.borrowTextAt(0, 2, paneTitleText("Files", active), paneTitleStyle(active));
    const title_width = chasen.text.displayWidth(paneTitleText("Files", active));
    const stats_col = title_width + 1;
    if (stats_col < size.width) {
        _ = try surface.printAt(stats_col, 2, .{ .fg = .gray }, "{d} files / {d} hunks", .{
            loaded.document.files.len,
            loaded.document.totalHunks(),
        });
    }

    if (size.height <= sidebar_header_rows) return;

    const visible_rows: usize = size.height - sidebar_header_rows;
    // Sidebar has no independent scroll state; derive the visible window
    // from the selected row each frame.
    const range = loaded.sidebarVisibleRange(app.viewer.selected_node, visible_rows);
    var row: u16 = sidebar_header_rows;
    var visible_index: usize = range.start;
    while (visible_index < range.end) : ({
        visible_index += 1;
        row += 1;
    }) {
        const row_model = sidebar_view_model.rowAt(.{
            .tree = loaded.tree,
            .collapsed = &loaded.collapsed_dirs,
            .reviewed_files = loaded.reviewed_files,
            .visible_nodes = loaded.materializedVisibleNodes(),
        }, visible_index, app.viewer.selected_node) orelse continue;
        try drawSidebarRow(surface, row, row_model, app.viewer.focus == .sidebar, app.viewer.sidebar_horizontal_scroll);
    }
}

fn drawSidebarDetailRow(app: anytype, surface: *chasen.Surface, row: u16, active: bool) !void {
    const size = surface.size();
    if (size.width <= 2 or row >= size.height) return;

    if (app.review_display.hide_reviewed_files and app.review_display.changed_file_filter != .all) {
        const text = try std.fmt.allocPrint(surface.frameAllocator(), "hiding reviewed / {s}", .{app.review_display.changed_file_filter.label()});
        try draw.copyClippedTextAt(surface, 1, row, text, .{ .fg = color_prompt });
        return;
    }
    if (app.review_display.hide_reviewed_files) {
        try draw.copyClippedTextAt(surface, 1, row, "hiding reviewed", .{ .fg = color_prompt });
        return;
    }
    if (app.review_display.changed_file_filter != .all) {
        try draw.copyClippedTextAt(surface, 1, row, app.review_display.changed_file_filter.label(), .{ .fg = color_prompt });
        return;
    }

    if (branchStatusSidebarText(app, surface.frameAllocator(), size.width - 1)) |text| {
        try draw.copyClippedTextAt(surface, 1, row, text, paneBranchStyle(active));
    }
}

fn drawSidebarRow(surface: *chasen.Surface, row: u16, row_model: sidebar_view_model.Row, pane_active: bool, horizontal_scroll: usize) !void {
    const width = surface.size().width;
    const row_layout = sidebar_view_model.layout(row_model, width);
    const style = sidebarRowStyle(row_model, pane_active);
    const marker = if (row_model.selected) "▌" else " ";

    if (width > row_layout.marker_col) {
        _ = surface.borrowTextAt(0, row, marker, style);
    }

    if (row_model.status) |status| {
        if (row_layout.badge_col) |badge_col| {
            if (width > badge_col) {
                _ = surface.borrowTextAt(badge_col, row, status.badge(), statusStyle(row_model, status, pane_active));
            }
        }
    }

    if (row_layout.mode_col) |mode_col| {
        if (width > mode_col) {
            _ = surface.borrowTextAt(mode_col, row, "m", modeBadgeStyle(row_model.selected, pane_active));
        }
    }

    if (row_layout.reviewed_col) |reviewed_col| {
        if (width > reviewed_col) {
            _ = surface.borrowTextAt(reviewed_col, row, "✓", reviewedStyle(row_model.selected, pane_active));
        }
    }

    if (row_layout.tree_content_width > 0) {
        var path_area = surface.child(.{
            .col = row_layout.tree_content_col,
            .row = row,
            .width = row_layout.tree_content_width,
            .height = 1,
        });
        const content = try sidebarTreeContent(surface.frameAllocator(), row_model);
        const effective_scroll = @min(horizontal_scroll, sidebar_view_model.maxHorizontalScroll(row_model, width));
        const visible = chasen.text.dropToWidth(content, effective_scroll);
        try draw.copyClippedTextAt(&path_area, 0, 0, visible, style);
    }

    if (row_layout.stats_col) |stats_col| {
        var stats_area = surface.child(.{
            .col = stats_col,
            .row = row,
            .width = row_layout.stats_width,
            .height = 1,
        });
        try drawSidebarStats(&stats_area, row_model, pane_active);
    }
}

fn drawSidebarStats(surface: *chasen.Surface, row: sidebar_view_model.Row, pane_active: bool) !void {
    const added_text = try std.fmt.allocPrint(surface.frameAllocator(), "+{d}", .{row.stats.added});
    const removed_text = try std.fmt.allocPrint(surface.frameAllocator(), "-{d}", .{row.stats.removed});
    const added_style = sidebarStatStyle(row, pane_active, color_success);
    const removed_style = sidebarStatStyle(row, pane_active, color_danger);

    try draw.copyClippedTextAt(surface, 0, 0, added_text, added_style);
    const removed_col = chasen.text.displayWidth(added_text) + 1;
    if (removed_col < surface.size().width) {
        try draw.copyClippedTextAt(surface, removed_col, 0, removed_text, removed_style);
    }
}

fn sidebarStatStyle(row: sidebar_view_model.Row, pane_active: bool, fg: chasen.Color) chasen.TextStyle {
    return .{
        .fg = fg,
        .bold = true,
        .dim = !pane_active,
        .reverse = pane_active and row.selected,
    };
}

fn sidebarTreeContent(allocator: std.mem.Allocator, row: sidebar_view_model.Row) ![]const u8 {
    const indent = @as(usize, row.depth) * 2;
    const fold_marker = switch (row.fold) {
        .none => "",
        .expanded => "▾ ",
        .collapsed => "▸ ",
    };
    const len = indent + fold_marker.len + row.name.len;
    const buf = try allocator.alloc(u8, len);
    @memset(buf[0..indent], ' ');
    @memcpy(buf[indent..][0..fold_marker.len], fold_marker);
    @memcpy(buf[indent + fold_marker.len ..][0..row.name.len], row.name);
    return buf;
}

fn sidebarRowStyle(row: sidebar_view_model.Row, pane_active: bool) chasen.TextStyle {
    if (row.selected) return .{ .reverse = pane_active, .bold = true, .dim = !pane_active };
    if (row.kind == .directory) return .{ .bold = true, .dim = !pane_active };
    return switch (row.stage_presence) {
        .staged_only => .{ .fg = color_staged, .dim = !pane_active },
        .mixed => .{ .fg = color_prompt, .dim = !pane_active },
        .conflict => .{ .fg = color_danger, .bold = true, .dim = !pane_active },
        else => .{ .dim = !pane_active },
    };
}

/// Draw the selected file's diff pane.
///
/// Diff rows are already backed by rendered-line indexes in LoadedDiff; this
/// layer only chooses the visible file, mode, and current scroll offset.
pub fn viewDiffPane(app: anytype, surface: *chasen.Surface, loaded: loaded_diff.LoadedDiff) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    if (app.selectedStatusEntry()) |entry| {
        try viewStatusOnlyPane(app, surface, entry);
        return;
    }

    if (loaded.document.files.len == 0) {
        _ = surface.borrowTextAt(0, 0, "No parsed files.", .{ .fg = .gray });
        return;
    }

    var diff_content = diffContentSurface(surface);
    const mode = diff_render.effectiveMode(diff_render.bodyWidth(diff_content.size().width), app.viewer.display_mode);
    const active = app.viewer.sidebar_hidden or app.viewer.focus == .diff;
    const display = (try app.activeDiffDisplay(surface.frameAllocator(), mode)) orelse return;
    const display_file = display.file();
    const title_prefix = repoHeaderLabel(app);
    try diff_render.renderFile(&diff_content, display_file, .{
        .requested_mode = app.viewer.display_mode,
        .scroll = app.viewer.diff_scroll,
        .horizontal_scroll = app.viewer.diff_horizontal_scroll,
        .pane_active = active,
        .title_prefix = title_prefix,
        .line_numbers = app.viewer.view_options.line_numbers,
        .highlighted_hunk = app.selectedHunkIndex(),
        .cursor_offset = app.visibleDiffCursorOffset(),
        .staged_hunks = display.stagedFlags(),
        .line_index = display.lineIndex(),
        .folded_hunks = display.foldedHunks(),
        .palette = app.theme,
    });
    drawDiffHeaderDetailRow(app, surface, active);
    drawSearchMatchMarker(app, surface);
}

fn drawDiffHeaderDetailRow(app: anytype, surface: *chasen.Surface, active: bool) void {
    const size = surface.size();
    if (size.width == 0 or size.height <= 1) return;

    surface.clear(.{ .col = 0, .row = 1, .width = size.width, .height = 1 });
    if (!app.search.mode and app.search.query.len > 0) {
        const label_col: u16 = 1;
        const match_text = if (app.search.match_offset) |offset|
            std.fmt.allocPrint(surface.frameAllocator(), "search: {s} @ {d}", .{ app.search.query.slice(), offset + 1 }) catch "search"
        else
            std.fmt.allocPrint(surface.frameAllocator(), "search: {s} (no match)", .{app.search.query.slice()}) catch "search";
        draw.copyClippedTextAt(surface, label_col, 1, match_text, paneSearchStyle(active)) catch {};
        return;
    }

    if (app.search.mode) {
        const label = "search: ";
        const label_col: u16 = 1;
        const style = paneSearchStyle(active);
        draw.copyClippedTextAt(surface, label_col, 1, label, style) catch {};
        if (size.width > label_col + label.len) {
            const input_col: u16 = label_col + @as(u16, @intCast(label.len));
            drawCommitInputLine(surface, input_col, 1, app.search.input.slice(), app.search.input.cursor, style) catch {};
            showInputCursor(surface, input_col, 1, app.search.input.slice(), app.search.input.cursor);
        }
        return;
    }

    drawPaneHeaderRule(surface, active);
}

fn viewStatusOnlyPane(app: anytype, surface: *chasen.Surface, entry: git_status.StatusEntry) !void {
    const active = app.viewer.sidebar_hidden or app.viewer.focus == .diff;

    var content = diffContentSurface(surface);
    const path = entry.canonicalPathKey() orelse entry.path;

    if (app.activeCachedDiffProjection()) |bundle| {
        if (bundle.loaded.document.files.len > 0) {
            try diff_render.renderFile(&content, bundle.loaded.document.files[0], .{
                .requested_mode = app.viewer.display_mode,
                .scroll = app.viewer.diff_scroll,
                .horizontal_scroll = app.viewer.diff_horizontal_scroll,
                .pane_active = active,
                .title_prefix = repoHeaderLabel(app),
                .line_numbers = app.viewer.view_options.line_numbers,
                .highlighted_hunk = app.selectedHunkIndex(),
                .cursor_offset = app.visibleDiffCursorOffset(),
                .line_index = bundle.loaded.cachedRenderedLineIndex(0, diff_render.effectiveMode(diff_render.bodyWidth(content.size().width), app.viewer.display_mode)),
                .palette = app.theme,
            });
            drawPaneHeaderRule(surface, active);
            return;
        }
    }

    if (app.activeGeneratedFileProjection()) |bundle| {
        try diff_render.renderGeneratedAddedFile(&content, bundle.file.path, bundle.file.lines, bundle.file.truncated, .{
            .requested_mode = app.viewer.display_mode,
            .scroll = app.viewer.diff_scroll,
            .horizontal_scroll = app.viewer.diff_horizontal_scroll,
            .pane_active = active,
            .title_prefix = repoHeaderLabel(app),
            .line_numbers = app.viewer.view_options.line_numbers,
            .cursor_offset = app.visibleDiffCursorOffset(),
            .palette = app.theme,
        });
        drawPaneHeaderRule(surface, active);
        return;
    }

    switch (app.review_projection) {
        .ready => |ready| {
            switch (ready.value) {
                .cached_diff, .generated_added_file => {},
                .combined_hunks => {},
                .status_body => |body| {
                    try drawStatusBody(&content, repoHeaderLabel(app), body.path, body.message, active);
                    drawPaneHeaderRule(surface, active);
                    return;
                },
            }
        },
        .failed => |failed| {
            try drawStatusBody(&content, repoHeaderLabel(app), failed.body.path, failed.body.message, active);
            drawPaneHeaderRule(surface, active);
            return;
        },
        .pending => {
            try drawStatusBody(&content, repoHeaderLabel(app), path, "Loading review projection...", active);
            drawPaneHeaderRule(surface, active);
            return;
        },
        .idle => {},
    }

    try drawTitlePath(&content, repoHeaderLabel(app), path, paneTitleStyle(active));
    const status_text = try std.fmt.allocPrint(surface.frameAllocator(), "status: {s}{s}", .{ statusName(entry.index), statusSuffix(entry) });
    try draw.copyClippedTextAt(&content, 0, 2, status_text, .{ .fg = .gray, .dim = !active });
    switch (file_tree.stagePresenceFromEntry(entry)) {
        .staged_only => {
            try draw.copyClippedTextAt(&content, 0, 4, "This file is staged.", .{ .fg = .gray, .dim = !active });
            try draw.copyClippedTextAt(&content, 0, 5, "Loading staged diff preview.", .{ .fg = .gray, .dim = !active });
        },
        else => {
            try draw.copyClippedTextAt(&content, 0, 4, "No diff is available for this file yet.", .{ .fg = .gray, .dim = !active });
            try draw.copyClippedTextAt(&content, 0, 5, "Loading generated review preview if available.", .{ .fg = .gray, .dim = !active });
        },
    }
}

fn drawPaneHeaderRule(surface: *chasen.Surface, active: bool) void {
    const size = surface.size();
    if (size.width == 0 or size.height <= 1) return;

    for (0..size.width) |col| {
        _ = surface.borrowTextAt(@intCast(col), 1, "─", paneHeaderRuleStyle(active));
    }
}

fn drawStatusBody(surface: *chasen.Surface, repo_label: ?[]const u8, path: []const u8, message: []const u8, active: bool) !void {
    try drawTitlePath(surface, repo_label, path, paneTitleStyle(active));
    try draw.copyClippedTextAt(surface, 0, 2, message, .{ .fg = .gray, .dim = !active });
}

fn drawTitlePath(surface: *chasen.Surface, repo_label: ?[]const u8, path: []const u8, style: chasen.TextStyle) !void {
    try draw.copyPrefixedTailClippedPathAt(surface, 0, 0, repo_label, path, style);
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

fn viewLoadState(app: anytype, col: *chasen.Column) void {
    switch (app.load.state) {
        .idle => drawStateMessageColumn(col, .{
            .title = "Waiting to load diff",
            .body = "GitFrame is waiting for a load request.",
            .hint = "Press q to quit.",
        }),
        .loading => drawStateMessageColumn(col, .{
            .title = "Loading diff",
            .body = "Reading and parsing the current source.",
            .hint = "Press q to quit.",
            .tone = .loading,
        }),
        .empty => |reason| drawStateMessageColumn(col, emptyLoadMessage(app, reason)),
        .failed => |failed| drawStateMessageColumn(col, .{
            .title = "Could not load diff",
            .body = firstLine(failed.message),
            .hint = "Press r to retry or q to quit.",
            .tone = .failure,
        }),
        .loaded => {},
    }
}

fn emptyLoadMessage(app: anytype, reason: anytype) StateMessage {
    return switch (reason) {
        .no_changes => .{
            .title = "No changes",
            .body = "Working tree has no diff for the current source.",
            .hint = noChangesHint(app),
        },
        .no_repository => .{
            .title = "No Git repository",
            .body = "Run GitFrame inside a repository or a workspace containing direct child repositories.",
            .hint = "Press q to quit.",
            .tone = .warning,
        },
    };
}

fn noChangesHint(app: anytype) []const u8 {
    if (app.repo_state.workspaceRepos() != null) {
        return "Press R to switch repository, r to reload, or q to quit.";
    }
    return "Press r to reload or q to quit.";
}

fn filterEmptyMessage(app: anytype) StateMessage {
    const hint = if (app.review_display.hide_reviewed_files and app.review_display.changed_file_filter != .all)
        "Press F to change filter, H to show reviewed files, or r to reload."
    else if (app.review_display.hide_reviewed_files)
        "Press H to show reviewed files or r to reload."
    else if (app.review_display.changed_file_filter != .all)
        "Press F to change filter or r to reload."
    else
        "Press r to reload.";

    return .{
        .title = "No files match current filters",
        .body = "The diff is loaded, but the current sidebar filters hide every file.",
        .hint = hint,
    };
}

fn drawStateMessage(surface: *chasen.Surface, message: StateMessage) void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    const width = @min(size.width, 64);
    const height: u16 = @min(size.height, 6);
    var panel = surface.child(.{
        .col = if (size.width > width) (size.width - width) / 2 else 0,
        .row = if (size.height > height) (size.height - height) / 2 else 0,
        .width = width,
        .height = height,
    });
    var col = panel.column(.{ .gap = 1 });
    drawStateMessageColumn(&col, message);
}

fn drawStateMessageColumn(col: *chasen.Column, message: StateMessage) void {
    col.borrowText(message.title, stateTitleStyle(message.tone));
    if (message.body.len > 0) col.borrowText(message.body, stateBodyStyle(message.tone));
    if (message.hint.len > 0) col.borrowText(message.hint, stateHintStyle());
}

fn stateTitleStyle(tone: StateTone) chasen.TextStyle {
    return switch (tone) {
        .muted => .{ .bold = true, .fg = .gray },
        .loading => .{ .bold = true, .fg = color_prompt },
        .warning => .{ .bold = true, .fg = color_warning },
        .failure => .{ .bold = true, .fg = color_danger },
    };
}

fn stateBodyStyle(tone: StateTone) chasen.TextStyle {
    return switch (tone) {
        .failure => .{ .fg = color_danger },
        else => .{ .fg = .gray },
    };
}

fn stateHintStyle() chasen.TextStyle {
    return .{ .fg = .gray, .dim = true };
}

fn firstLine(text: []const u8) []const u8 {
    if (std.mem.indexOfAny(u8, text, "\r\n")) |end| return text[0..end];
    return text;
}

fn viewFooter(app: anytype, surface: *chasen.Surface) void {
    const width = surface.size().width;
    if (width == 0) return;

    if (app.file_search.mode) {
        const label = "file: ";
        const label_col: u16 = 1;
        _ = surface.borrowTextAt(label_col, 0, label, .{ .fg = color_prompt, .bold = true });
        const input_col: u16 = label_col + @as(u16, @intCast(label.len));
        _ = surface.copyTextAt(input_col, 0, app.file_search.input.slice(), .{ .fg = color_prompt }) catch {};
        if (app.file_search.no_match) {
            const col: u16 = @intCast(@min(input_col + chasen.text.displayWidth(app.file_search.input.slice()) + 1, std.math.maxInt(u16)));
            if (surface.size().width > col) _ = surface.borrowTextAt(col, 0, "(no match)", .{ .fg = color_danger });
        }
        return;
    }

    var footer_item_storage: [4]ui.key_hint.Item = undefined;
    var footer_key_buffers: [4][16]u8 = undefined;
    const hint_items = footerItems(app, &footer_item_storage, &footer_key_buffers);
    const hint_width = ui.key_hint.width(hint_items, footerKeyHintOptions());
    const hint_col = if (width > hint_width + 1) width - hint_width - 1 else 0;
    const left_limit = if (hint_col > 0) hint_col else width;

    var footer_segments = FooterSegments{};
    footer_segments.append(.{
        .text = std.fmt.allocPrint(surface.frameAllocator(), "{d}x{d}", .{
            app.terminal_size.width,
            app.terminal_size.height,
        }) catch return,
        .style = .{ .fg = .gray },
    });
    if (sourceFooterLabel(app.config)) |label| footer_segments.append(.{
        .text = label,
        .style = .{ .fg = color_prompt },
        .drop_priority = .source,
    });
    if (app.config.watch) footer_segments.append(.{
        .text = "watch",
        .style = .{ .fg = color_staged },
        .drop_priority = .watch,
    });
    if (app.status.text().len > 0) footer_segments.append(.{
        .text = app.status.text(),
        .style = .{ .fg = color_prompt },
    });

    footer_segments.fit(left_limit);
    var left_area = surface.child(.{
        .col = 0,
        .row = 0,
        .width = left_limit,
        .height = 1,
    });
    footer_segments.render(&left_area, left_limit);

    const draw_col = if (hint_col > 0) hint_col else footer_segments.endCol();
    if (width > draw_col) {
        var hint_area = surface.child(.{
            .col = draw_col,
            .row = 0,
            .width = width - draw_col,
            .height = 1,
        });
        _ = ui.key_hint.draw(&hint_area, 0, 0, hint_items, footerKeyHintOptions());
    }
}

const FooterDropPriority = enum {
    source,
    watch,
};

const FooterSegment = struct {
    text: []const u8,
    style: chasen.TextStyle,
    drop_priority: ?FooterDropPriority = null,
    visible: bool = true,
};

const FooterSegments = struct {
    items: [5]FooterSegment = undefined,
    len: usize = 0,

    fn append(self: *FooterSegments, segment: FooterSegment) void {
        if (self.len >= self.items.len) return;
        self.items[self.len] = segment;
        self.len += 1;
    }

    fn fit(self: *FooterSegments, width: u16) void {
        const order = [_]FooterDropPriority{ .source, .watch };
        for (order) |priority| {
            if (self.requiredWidth() <= width) return;
            self.drop(priority);
        }
    }

    fn drop(self: *FooterSegments, priority: FooterDropPriority) void {
        for (self.items[0..self.len]) |*item| {
            if (item.drop_priority != null and item.drop_priority.? == priority) {
                item.visible = false;
                return;
            }
        }
    }

    fn contentWidth(self: *const FooterSegments) u16 {
        var result: usize = 0;
        for (self.items[0..self.len]) |item| {
            if (!item.visible) continue;
            if (result > 0) result += 2;
            result += chasen.text.displayWidth(item.text);
        }
        return @intCast(@min(result, std.math.maxInt(u16)));
    }

    fn requiredWidth(self: *const FooterSegments) u16 {
        const content_width = self.contentWidth();
        if (content_width == 0) return 0;
        return content_width + 1;
    }

    fn render(self: *const FooterSegments, surface: *chasen.Surface, width: u16) void {
        var col: u16 = 1;
        for (self.items[0..self.len]) |item| {
            if (!item.visible or item.text.len == 0) continue;
            if (col >= width) return;
            draw.copyClippedTextAt(surface, col, 0, item.text, item.style) catch {};
            const segment_width = chasen.text.displayWidth(item.text);
            col +|= @intCast(@min(segment_width + 2, std.math.maxInt(u16)));
        }
    }

    fn endCol(self: *const FooterSegments) u16 {
        return self.requiredWidth();
    }
};

fn repoHeaderLabel(app: anytype) ?[]const u8 {
    const root = app.repo_state.activeRoot() orelse return null;
    const base = std.fs.path.basename(root);
    if (base.len == 0) return root;
    return base;
}

fn branchStatusSidebarText(app: anytype, allocator: std.mem.Allocator, available_width: u16) ?[]const u8 {
    const root = app.repo_state.activeRoot() orelse return null;
    if (app.branch_status_load_pending != null) return "loading branch";

    const snapshot_root = app.branch_status.repo_root orelse return null;
    if (!std.mem.eql(u8, root, snapshot_root)) return null;

    return formatSidebarBranchStatus(allocator, app.branch_status.status, available_width) catch "branch";
}

fn formatSidebarBranchStatus(allocator: std.mem.Allocator, status: git_branch_status.BranchStatus, available_width: u16) ![]const u8 {
    const branch = switch (status.head) {
        .branch => |name| name,
        .detached => return "detached",
        .unknown => return "unknown branch",
    };
    var allocated_suffix: ?[]const u8 = null;
    defer if (allocated_suffix) |suffix| allocator.free(suffix);
    const suffix = if (status.upstream == null)
        " no upstream"
    else blk: {
        const ahead = if (status.ahead_behind) |ab| ab.ahead else 0;
        const behind = if (status.ahead_behind) |ab| ab.behind else 0;
        allocated_suffix = try std.fmt.allocPrint(allocator, " ↑{d} ↓{d}", .{ ahead, behind });
        break :blk allocated_suffix.?;
    };
    const reserved = chasen.text.displayWidth(suffix);
    const branch_width = if (available_width > reserved) available_width - reserved else 0;
    const display_branch = try branchPrefixTail(allocator, branch, branch_width);
    defer allocator.free(display_branch);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ display_branch, suffix });
}

fn branchPrefixTail(allocator: std.mem.Allocator, branch: []const u8, width: u16) ![]const u8 {
    if (width == 0) return allocator.dupe(u8, "");
    if (chasen.text.displayWidth(branch) <= width) return allocator.dupe(u8, branch);
    const slash = std.mem.indexOfScalar(u8, branch, '/') orelse return markedClipToOwned(allocator, branch, width);
    const prefix = branch[0 .. slash + 1];
    const marker = "…";
    const prefix_width = chasen.text.displayWidth(prefix);
    const marker_width = chasen.text.displayWidth(marker);
    if (width <= prefix_width + marker_width) return markedClipToOwned(allocator, branch, width);
    // Keep branch class prefixes such as "feature/" while preserving the
    // ticket/topic tail that usually disambiguates long branch names.
    const tail_width = width - prefix_width - marker_width;
    const tail_source = branch[slash + 1 ..];
    const tail_source_width = chasen.text.displayWidth(tail_source);
    const tail = chasen.text.dropToWidth(tail_source, tail_source_width - tail_width);
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, marker, tail });
}

fn markedClipToOwned(allocator: std.mem.Allocator, text: []const u8, width: u16) ![]const u8 {
    const clipped = chasen.text.clipToWidthWithMarker(text, width, "…");
    if (clipped.marker.len == 0) return allocator.dupe(u8, clipped.prefix);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ clipped.prefix, clipped.marker });
}

test "formatSidebarBranchStatus distinguishes upstream state" {
    const with_upstream = try formatSidebarBranchStatus(std.testing.allocator, .{
        .head = .{ .branch = "feature/topic" },
        .upstream = .{ .name = "origin/main", .remote = "origin", .remote_branch = "main" },
        .ahead_behind = .{ .ahead = 2, .behind = 1 },
    }, 80);
    defer std.testing.allocator.free(with_upstream);
    try std.testing.expectEqualStrings("feature/topic ↑2 ↓1", with_upstream);

    const without_upstream = try formatSidebarBranchStatus(std.testing.allocator, .{
        .head = .{ .branch = "feature/topic" },
    }, 80);
    defer std.testing.allocator.free(without_upstream);
    try std.testing.expectEqualStrings("feature/topic no upstream", without_upstream);
}

test "formatSidebarBranchStatus keeps branch prefix and tail when clipped" {
    const text = try formatSidebarBranchStatus(std.testing.allocator, .{
        .head = .{ .branch = "feature/very-long-ticket-name" },
        .upstream = .{ .name = "origin/main", .remote = "origin", .remote_branch = "main" },
        .ahead_behind = .{ .ahead = 0, .behind = 0 },
    }, 22);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.startsWith(u8, text, "feature/…"));
    try std.testing.expect(std.mem.endsWith(u8, text, " ↑0 ↓0"));
}

fn sourceFooterLabel(config: anytype) ?[]const u8 {
    return switch (config.source) {
        .unstaged => null,
        .cached => "staged",
        .stdin => "stdin",
        .pager => "pager",
        .patch_file => "patch",
        .range => "range",
        .no_index => "difftool",
    };
}

fn footerKeyHintOptions() ui.key_hint.DrawOptions {
    return .{
        .style = .{ .fg = .gray },
        .key_style = .{ .bold = true, .fg = .gray },
    };
}

const RepoPickerLayout = struct {
    list_title_row: u16,
    list_start_row: u16,
    footer_rows: u16,
    footer_row: u16,
    detail_row: ?u16,
};

fn repoPickerLayout(height: u16, has_path_status: bool) RepoPickerLayout {
    const list_title_row: u16 = if (has_path_status) 3 else 2;
    // Reserve bottom rows from the outside in: footer, optional spacer, and
    // optional selected-path detail. The list viewport then uses the remainder.
    const reserved_footer_rows: u16 = if (height > 9) 4 else if (height > 8) 3 else if (height > 7) 2 else if (height > 6) 1 else 0;
    const detail_row: ?u16 = if (reserved_footer_rows > 1)
        if (reserved_footer_rows > 2) height - 3 else height - 2
    else
        null;

    return .{
        .list_title_row = list_title_row,
        .list_start_row = list_title_row + 1,
        .footer_rows = reserved_footer_rows,
        .footer_row = if (reserved_footer_rows > 0) height - 1 else 0,
        .detail_row = detail_row,
    };
}

fn viewRepoPicker(app: anytype, surface: *chasen.Surface) !void {
    const modal = ui.Modal.init(.{});
    const opts: ui.Modal.ViewOptions = .{
        .dialog_width = @min(surface.size().width, repo_picker_dialog_width),
        .dialog_height = @min(surface.size().height, 18),
        .title = "Switch repository",
        .backdrop = false,
        .border = .rounded,
        .title_style = .{ .bold = true, .fg = color_accent },
    };
    fillModalDialog(surface, opts);
    modal.view(surface, opts);

    const content_rect = ui.Modal.contentRect(surface, opts);
    if (content_rect.width == 0 or content_rect.height == 0) return;
    var content = surface.child(content_rect);
    const size = content.size();

    switch (app.repo_picker.input_mode) {
        .list => _ = content.borrowTextAt(0, 0, "Repository list", .{ .fg = color_prompt, .bold = true }),
        .filter => {
            _ = content.borrowTextAt(0, 0, "Filter: ", .{ .fg = color_prompt, .bold = true });
            try drawCommitInputLine(&content, repo_picker_filter_input_col, 0, app.repo_picker.list.input.slice(), app.repo_picker.list.input.cursor, .{ .fg = color_prompt });
            showInputCursor(&content, repo_picker_filter_input_col, 0, app.repo_picker.list.input.slice(), app.repo_picker.list.input.cursor);
        },
        .path_input => {
            _ = content.borrowTextAt(0, 0, "Repo path: ", .{ .fg = color_prompt, .bold = true });
            try drawCommitInputLine(&content, repo_picker_path_input_col, 0, app.repo_picker.path_input.slice(), app.repo_picker.path_input.cursor, .{ .fg = color_prompt });
            showInputCursor(&content, repo_picker_path_input_col, 0, app.repo_picker.path_input.slice(), app.repo_picker.path_input.cursor);
        },
    }

    const has_path_status = app.repo_picker.path_pending or app.repo_picker.path_error != null;
    if (size.height > 1 and has_path_status) {
        if (app.repo_picker.path_pending) {
            _ = content.borrowTextAt(0, 1, "checking path...", .{ .fg = .gray });
        } else if (app.repo_picker.path_error) |err| {
            try draw.copyClippedTextAt(&content, 0, 1, err.message(), .{ .fg = color_danger });
        }
    }

    if (size.height <= 3) return;
    const layout = repoPickerLayout(size.height, has_path_status);
    const list_title = try app_repo_picker.listTitle(content.frameAllocator(), app.repo_picker_discovery, app.repo_state.discovery, &app.recent_repos);
    const list_title_style: chasen.TextStyle = if (app.repo_picker.input_mode == .path_input)
        .{ .fg = .gray, .dim = true }
    else
        .{ .fg = color_accent, .bold = true };
    try draw.copyClippedTextAt(&content, 0, layout.list_title_row, list_title, list_title_style);

    defer {
        if (layout.footer_rows > 0) {
            const has_row = app.repo_picker.list.filter.labels.len > 0;
            drawRepoPickerFooter(&content, layout.footer_row, app.repo_picker.input_mode, has_row);
        }
    }

    if (app.repo_picker.list.filter.labels.len == 0) {
        if (size.height > layout.list_start_row) {
            const empty_text = if (app.repo_picker.input_mode == .filter and app.repo_picker.list.input.len > 0)
                "No matching repositories."
            else
                "No recent repositories yet.";
            _ = content.borrowTextAt(2, layout.list_start_row, empty_text, .{ .fg = .gray });
        }
        return;
    }

    const rows = size.height -| layout.list_start_row -| layout.footer_rows;
    const focused = app.repo_picker.list.filter.list.focusedIndex();
    const range = ui.ListViewport.visibleRange(app.repo_picker.list.filter.labels.len, focused, rows);
    var row: u16 = layout.list_start_row;
    var visible_index: usize = range.start;
    while (visible_index < range.end) : ({
        visible_index += 1;
        row += 1;
    }) {
        const source_index = app.repo_picker.list.filter.sourceIndex(visible_index) orelse continue;
        const label = app.repo_picker.list.filter.labels[visible_index];
        const item = if (source_index < app.repo_picker_items.items.len) app.repo_picker_items.items[source_index] else null;
        const list_active = app.repo_picker.input_mode == .list or app.repo_picker.input_mode == .filter;
        const focused_row = list_active and visible_index == focused;
        const active = if (item) |repo_item|
            switch (repo_item.source) {
                .active_repo => true,
                .workspace_repo => |repo_index| repo_index == app.repo_state.active_index,
                .pending_workspace_repo, .recent_repo, .recent_workspace => false,
            }
        else
            false;
        const style: chasen.TextStyle = if (focused_row)
            .{ .reverse = true, .bold = true }
        else if (active)
            .{ .fg = color_staged, .bold = true, .dim = !list_active }
        else
            .{ .dim = !list_active };
        const marker = if (focused_row) ">" else " ";
        const active_marker = if (active) "*" else " ";
        _ = content.borrowTextAt(0, row, marker, style);
        _ = content.borrowTextAt(2, row, active_marker, style);
        var label_area = content.child(.{
            .col = repo_picker_list_label_col,
            .row = row,
            .width = size.width -| repo_picker_list_label_col,
            .height = 1,
        });
        try draw.copyClippedTextAt(&label_area, 0, 0, label, style);
    }

    if (layout.detail_row) |detail_row| {
        const total = app.repo_picker.list.filter.labels.len;
        const position_text = if (total > 1)
            try std.fmt.allocPrint(content.frameAllocator(), "{d}/{d}", .{ @min(focused + 1, total), total })
        else
            "";
        const position_width = chasen.text.displayWidth(position_text);
        const detail_width = if (position_width > 0 and size.width > position_width + 1)
            size.width - position_width - 1
        else
            size.width;
        const detail_col: u16 = if (size.width > repo_picker_list_label_col) repo_picker_list_label_col else 0;
        const detail_text_width = detail_width -| detail_col;
        const focused_source_index = app.repo_picker.list.filter.sourceIndex(focused);
        if (focused_source_index) |source_index| {
            if (source_index < app.repo_picker_items.items.len) {
                const detail = app.repo_picker_items.items[source_index].detail;
                var detail_area = content.child(.{
                    .col = detail_col,
                    .row = detail_row,
                    .width = detail_text_width,
                    .height = 1,
                });
                try draw.copyClippedTextAt(&detail_area, 0, 0, detail, .{ .fg = .gray });
            }
        }
        if (position_width > 0 and size.width > position_width) {
            try draw.copyClippedTextAt(&content, size.width - position_width, detail_row, position_text, .{ .fg = .gray });
        }
    }
}

fn drawRepoPickerFooter(surface: *chasen.Surface, row: u16, input_mode: anytype, has_row: bool) void {
    const Item = ui.key_hint.Item;
    const items: []const Item = switch (input_mode) {
        .path_input => &.{
            ui.key_hint.item("Enter", "open path"),
            ui.key_hint.item("Esc", "list"),
        },
        .filter => &.{
            ui.key_hint.item("Enter", "open selected"),
            ui.key_hint.item("Up/Down", "select row"),
            ui.key_hint.item("Esc", "list"),
        },
        .list => if (has_row) &.{
            ui.key_hint.item("p", "repo path"),
            ui.key_hint.item("/", "filter"),
            ui.key_hint.item("d", "remove recent"),
            ui.key_hint.item("b/Esc", "back"),
            ui.key_hint.item("q", "close"),
        } else &.{
            ui.key_hint.item("p", "repo path"),
            ui.key_hint.item("Esc/q", "close"),
        },
    };

    const opts = footerKeyHintOptions();
    _ = ui.key_hint.draw(surface, 0, row, items, opts);
}

fn viewCommitPanel(app: anytype, surface: *chasen.Surface) !void {
    const modal = ui.Modal.init(.{});
    const title_style: chasen.TextStyle = if (app.commit_panel.mode == .amend)
        .{ .bold = true, .fg = amend_accent }
    else
        .{ .bold = true, .fg = color_accent };
    const opts: ui.Modal.ViewOptions = .{
        .dialog_width = @min(surface.size().width, commit_dialog_width),
        .dialog_height = @min(surface.size().height, commit_dialog_height),
        .title = app.commit_panel.title(),
        .backdrop = false,
        .border = .rounded,
        .title_style = title_style,
    };
    fillModalDialog(surface, opts);
    modal.view(surface, opts);

    const content_rect = ui.Modal.contentRect(surface, opts);
    if (content_rect.width == 0 or content_rect.height == 0) return;
    var content = surface.child(content_rect);
    const size = content.size();

    const staged_text = try stagedSummaryText(content.frameAllocator(), app.stagedSummaryForActiveRepo());
    try draw.copyClippedTextAt(&content, 0, 0, staged_text, .{ .fg = .gray });

    const help_rows = commitHelpRows(size.width);
    const help_start_row = if (size.height > help_rows) size.height - help_rows else 0;
    const error_row = if (help_start_row > 0) help_start_row - 1 else help_start_row;
    const field_limit_row = if (size.height > 2) error_row else help_start_row;

    if (size.height > 2 and 2 < field_limit_row) {
        const active = app.commit_panel.active_field == .subject;
        const label_style: chasen.TextStyle = commitFieldLabelStyle(app, active);
        _ = content.borrowTextAt(0, 2, if (active) ">" else " ", label_style);
        _ = content.borrowTextAt(2, 2, "Subject:", label_style);
        try drawCommitCounter(&content, 2, app.commit_panel.subjectCharCount(), app_commit_panel.max_subject_chars);
        const input_col: u16 = @min(2, size.width);
        if (size.height > 3 and 3 < field_limit_row and size.width > input_col) {
            const cursor = if (active) app.commit_panel.subject.cursor else null;
            const input_style: chasen.TextStyle = if (app.commit_panel.mode == .amend) .{} else .{ .fg = color_prompt };
            try drawCommitInputLine(&content, input_col, 3, app.commit_panel.subject.slice(), cursor, input_style);
            if (active) showInputCursor(&content, input_col, 3, app.commit_panel.subject.slice(), app.commit_panel.subject.cursor);
        }
    }

    if (size.height > 5 and 5 < field_limit_row) {
        const active = app.commit_panel.active_field == .body;
        const label_style: chasen.TextStyle = commitFieldLabelStyle(app, active);
        _ = content.borrowTextAt(0, 5, if (active) ">" else " ", label_style);
        _ = content.borrowTextAt(2, 5, "Body:", label_style);
        try drawCommitCounter(&content, 5, app.commit_panel.bodyCharCount(), null);
    }

    if (size.height > 6 and error_row > 6) {
        var body_area = content.child(.{
            .col = 2,
            .row = 6,
            .width = if (size.width > 2) size.width - 2 else 0,
            .height = error_row - 6,
        });
        try viewCommitBody(&app.commit_panel.body, &body_area, app.commit_panel.active_field == .body);
        if (app.commit_panel.active_field == .body) showBodyInputCursor(&body_area, &app.commit_panel.body);
    }

    if (size.height > 2) {
        if (app.commit_panel.commit_error) |err| {
            try draw.copyClippedTextAt(&content, 0, error_row, err.message(), .{ .fg = color_danger });
        }
    }

    try viewCommitHelp(app, &content, help_start_row, help_rows);
}

fn drawCommitCounter(surface: *chasen.Surface, row: u16, len: usize, max: ?usize) !void {
    const size = surface.size();
    if (row >= size.height or size.width == 0) return;

    const counter = if (max) |limit|
        try std.fmt.allocPrint(surface.frameAllocator(), "{d}/{d}", .{ len, limit })
    else
        try std.fmt.allocPrint(surface.frameAllocator(), "{d}", .{len});
    const counter_width = chasen.text.displayWidth(counter);
    if (counter_width >= size.width) return;

    const col = size.width - counter_width;
    try draw.copyClippedTextAt(surface, col, row, counter, .{ .fg = .gray });
}

fn commitHelpRows(width: u16) u16 {
    const single_line = "Tab: field  Enter: newline  Ctrl+s/Ctrl+Enter: validate  Esc: close";
    return if (chasen.text.displayWidth(single_line) <= width) 1 else 2;
}

fn viewCommitHelp(app: anytype, surface: *chasen.Surface, start_row: u16, rows: u16) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0 or start_row >= size.height) return;

    const style: chasen.TextStyle = .{ .fg = .gray };
    const submit_label = app.commit_panel.submitLabel();
    if (rows <= 1) {
        const text = try std.fmt.allocPrint(surface.frameAllocator(), "Tab: field  Enter: newline  Ctrl+s/Ctrl+Enter: {s}  Esc: close", .{submit_label});
        try draw.copyClippedTextAt(surface, 0, start_row, text, style);
        return;
    }

    const line1 = try std.fmt.allocPrint(surface.frameAllocator(), "Tab: field  Enter: newline  Ctrl+s: {s}", .{submit_label});
    try draw.copyClippedTextAt(surface, 0, start_row, line1, style);
    if (start_row + 1 < size.height) {
        const line2 = try std.fmt.allocPrint(surface.frameAllocator(), "Ctrl+Enter: {s}  Esc: close", .{submit_label});
        try draw.copyClippedTextAt(surface, 0, start_row + 1, line2, style);
    }
}

fn commitFieldLabelStyle(app: anytype, active: bool) chasen.TextStyle {
    if (active and app.commit_panel.mode == .amend) return .{ .bold = true, .fg = amend_accent };
    if (active) return .{ .bold = true, .fg = color_accent };
    return .{ .bold = true };
}

fn viewCommitBody(body: *const app_commit_panel.BodyText, surface: *chasen.Surface, active: bool) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    const total_lines = body.lineCount();
    const overflow = total_lines > size.height;
    const text_rows = if (overflow and size.height > 0) size.height - 1 else size.height;
    const start_line = bodyVisibleStartLine(body, text_rows);
    const active_line = if (active) bodyActiveLineIndex(body, start_line, text_rows) else null;

    var row: u16 = 0;
    while (row < text_rows) : (row += 1) {
        const body_line = start_line + row;
        const line = body.lineAt(body_line) orelse "";
        const cursor = if (active_line != null and row == active_line.?) body.cursorLinePrefix().len else null;
        try drawCommitInputLine(surface, 0, row, line, cursor, .{});
    }
    if (overflow) {
        const indicator = try std.fmt.allocPrint(surface.frameAllocator(), "... {d}/{d}", .{ body.cursorLineIndex() + 1, total_lines });
        try draw.copyClippedTextAt(surface, 0, size.height - 1, indicator, .{ .fg = .gray });
    }
}

fn viewDiscardConfirmation(app: anytype, surface: *chasen.Surface) !void {
    const confirmation = app.discard_confirmation orelse return;
    const modal = ui.Modal.init(.{});
    const opts: ui.Modal.ViewOptions = .{
        .dialog_width = @min(surface.size().width, confirmation_dialog_width),
        .dialog_height = @min(surface.size().height, confirmation_dialog_height),
        .title = "Discard file changes?",
        .backdrop = false,
        .border = .rounded,
        .title_style = .{ .bold = true, .fg = color_danger },
        .border_style = .{ .fg = color_danger },
    };
    fillModalDialog(surface, opts);
    modal.view(surface, opts);

    const content_rect = ui.Modal.contentRect(surface, opts);
    if (content_rect.width == 0 or content_rect.height == 0) return;
    var content = surface.child(content_rect);
    const size = content.size();

    try drawCenteredText(&content, 0, "This will discard unstaged tracked changes.", .{ .fg = color_danger });
    if (size.height > 2) {
        try drawCenteredLabelValue(&content, 2, "File:", confirmation.path, .{ .bold = true }, .{});
    }
    if (size.height > 4) {
        try drawCenteredText(&content, 4, "Enter: discard    Esc/q: cancel", .{ .fg = color_danger });
    }
}

fn viewAmendConfirmation(app: anytype, surface: *chasen.Surface) !void {
    _ = app.amend_confirmation orelse return;
    const modal = ui.Modal.init(.{});
    const opts: ui.Modal.ViewOptions = .{
        .dialog_width = @min(surface.size().width, confirmation_dialog_width),
        .dialog_height = @min(surface.size().height, confirmation_dialog_height),
        .title = "Amend last commit?",
        .backdrop = false,
        .border = .rounded,
        .title_style = .{ .bold = true, .fg = amend_accent },
        .border_style = .{ .fg = amend_accent },
    };
    fillModalDialog(surface, opts);
    modal.view(surface, opts);

    const content_rect = ui.Modal.contentRect(surface, opts);
    if (content_rect.width == 0 or content_rect.height == 0) return;
    var content = surface.child(content_rect);
    const size = content.size();

    const line_count: u16 = 3;
    const start_row: u16 = if (size.height > line_count) (size.height - line_count) / 2 else 0;
    try drawCenteredText(&content, start_row, "This rewrites the current branch history.", .{ .fg = amend_accent });
    if (start_row + 2 < size.height) {
        try drawCenteredText(&content, start_row + 2, "Enter: amend    Esc/q: cancel", .{ .fg = amend_accent });
    }
}

fn viewPushConfirmation(app: anytype, surface: *chasen.Surface) !void {
    const confirmation = app.push_confirmation orelse return;
    const modal = ui.Modal.init(.{});
    const opts: ui.Modal.ViewOptions = .{
        .dialog_width = @min(surface.size().width, confirmation_dialog_width),
        .dialog_height = @min(surface.size().height, confirmation_dialog_height),
        .title = "Push current branch?",
        .backdrop = false,
        .border = .rounded,
        .title_style = .{ .bold = true, .fg = color_accent },
        .border_style = .{ .fg = color_accent },
    };
    fillModalDialog(surface, opts);
    modal.view(surface, opts);

    const content_rect = ui.Modal.contentRect(surface, opts);
    if (content_rect.width == 0 or content_rect.height == 0) return;
    var content = surface.child(content_rect);
    const size = content.size();

    const target = try std.fmt.allocPrint(content.frameAllocator(), "{s} -> {s}/{s}", .{ confirmation.branch, confirmation.remote, confirmation.remote_branch });
    const counts = try std.fmt.allocPrint(content.frameAllocator(), "ahead {d} / behind {d}", .{ confirmation.ahead, confirmation.behind });
    const line_count: u16 = 5;
    const start_row: u16 = if (size.height > line_count) (size.height - line_count) / 2 else 0;
    try drawCenteredText(&content, start_row, target, .{ .bold = true, .fg = color_accent });
    if (start_row + 2 < size.height) {
        try drawCenteredText(&content, start_row + 2, counts, .{ .fg = .gray });
    }
    if (start_row + 4 < size.height) {
        try drawCenteredText(&content, start_row + 4, "Enter: push    Esc/q: cancel", .{ .fg = color_accent });
    }
}

fn viewPushError(app: anytype, surface: *chasen.Surface) !void {
    const message = app.push_error_message orelse return;
    const modal = ui.Modal.init(.{});
    const opts = pushErrorModalOptions(surface.size(), message);

    const opts_with_title: ui.Modal.ViewOptions = .{
        .dialog_width = opts.dialog_width,
        .dialog_height = opts.dialog_height,
        .title = "Push failed",
        .backdrop = false,
        .border = .rounded,
        .title_style = .{ .bold = true, .fg = color_danger },
        .border_style = .{ .fg = color_danger },
    };
    fillModalDialog(surface, opts_with_title);
    modal.view(surface, opts_with_title);

    const content_rect = ui.Modal.contentRect(surface, opts_with_title);
    if (content_rect.width == 0 or content_rect.height == 0) return;
    var content = surface.child(content_rect);
    const size = content.size();

    if (size.height > 0) {
        try draw.copyClippedTextAt(&content, 0, 0, "Git push failed. Details:", .{ .bold = true, .fg = color_danger });
    }

    if (size.height > 4) {
        var body = content.child(.{
            .col = 0,
            .row = 2,
            .width = size.width,
            .height = size.height - 4,
        });
        drawWrappedTextScrolled(&body, message, app.overlay.push_error_scroll, .{});
    }

    if (size.height > 0) {
        try draw.copyClippedTextAt(&content, 0, size.height - 1, "Enter/Esc/q: close", .{ .fg = color_danger });
    }
}

fn pushErrorModalOptions(size: chasen.Size, message: []const u8) struct { dialog_width: u16, dialog_height: u16 } {
    const dialog_width = @min(size.width, push_error_dialog_max_width);
    const content_width = if (dialog_width > 4) dialog_width - 4 else 0;
    const paragraph = ui.Paragraph.init(.{ .text = message });
    const body_rows = paragraph.lineCount(content_width);
    // Content rows outside the wrapped body: title, body gap, footer gap, footer.
    const desired_content_height = body_rows + 4;
    const desired_height = modalHeightForContent(size, dialog_width, desired_content_height);
    return .{
        .dialog_width = dialog_width,
        .dialog_height = @min(size.height, desired_height),
    };
}

pub fn pushErrorVisibleRows(size: chasen.Size, message: ?[]const u8) u16 {
    const content_size = pushErrorContentSize(size, message orelse "");
    if (content_size.height <= 4) return 0;
    return content_size.height - 4;
}

pub fn pushErrorMaxScroll(size: chasen.Size, message: ?[]const u8) usize {
    const text = message orelse "";
    const content_size = pushErrorContentSize(size, text);
    if (content_size.width == 0) return 0;
    const paragraph = ui.Paragraph.init(.{ .text = text });
    const rows = paragraph.lineCount(content_size.width);
    const visible_rows: usize = pushErrorVisibleRows(size, message);
    if (rows <= visible_rows) return 0;
    return rows - visible_rows;
}

fn pushErrorContentSize(size: chasen.Size, message: []const u8) chasen.Size {
    const opts = pushErrorModalOptions(size, message);
    return ui.Modal.contentSizeForOverlay(.{ .col = 0, .row = 0, .width = size.width, .height = size.height }, .{
        .dialog_width = opts.dialog_width,
        .dialog_height = opts.dialog_height,
    });
}

fn modalHeightForContent(size: chasen.Size, dialog_width: u16, desired_content_height: usize) u16 {
    var candidate = @min(size.height, push_error_dialog_min_height);
    const overlay: chasen.Rect = .{ .col = 0, .row = 0, .width = size.width, .height = size.height };
    while (candidate < size.height) : (candidate += 1) {
        const content_size = ui.Modal.contentSizeForOverlay(overlay, .{
            .dialog_width = dialog_width,
            .dialog_height = candidate,
        });
        if (content_size.height >= desired_content_height) return candidate;
    }
    return size.height;
}

fn drawWrappedTextScrolled(surface: *chasen.Surface, text: []const u8, scroll: usize, style: chasen.TextStyle) void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    var logical_row: usize = 0;
    var drawn_rows: u16 = 0;
    var line_start: usize = 0;
    var line_end: usize = 0;
    var line_width: u32 = 0;

    var iter = chasen.text.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        if (bytes.len == 1 and bytes[0] == '\n') {
            if (drawWrappedLine(surface, text[line_start..line_end], logical_row, scroll, &drawn_rows, style)) return;
            logical_row += 1;
            line_start = grapheme.start + grapheme.len;
            line_end = line_start;
            line_width = 0;
            continue;
        }

        const grapheme_width = chasen.text.displayWidth(bytes);
        if (line_width > 0 and line_width + grapheme_width > size.width) {
            if (drawWrappedLine(surface, text[line_start..line_end], logical_row, scroll, &drawn_rows, style)) return;
            logical_row += 1;
            line_start = grapheme.start;
            line_end = grapheme.start;
            line_width = 0;
        }

        line_end = grapheme.start + grapheme.len;
        line_width += grapheme_width;
    }

    _ = drawWrappedLine(surface, text[line_start..line_end], logical_row, scroll, &drawn_rows, style);
}

fn drawWrappedLine(surface: *chasen.Surface, line: []const u8, logical_row: usize, scroll: usize, drawn_rows: *u16, style: chasen.TextStyle) bool {
    const size = surface.size();
    if (logical_row < scroll) return false;
    if (drawn_rows.* >= size.height) return true;
    _ = surface.borrowTextAt(0, drawn_rows.*, line, style);
    drawn_rows.* += 1;
    return drawn_rows.* >= size.height;
}

fn drawCenteredText(surface: *chasen.Surface, row: u16, text: []const u8, style: chasen.TextStyle) !void {
    const size = surface.size();
    if (row >= size.height or size.width == 0) return;

    const text_width = chasen.text.displayWidth(text);
    const col: u16 = if (text_width < size.width) (size.width - text_width) / 2 else 0;
    try draw.copyClippedTextAt(surface, col, row, text, style);
}

fn drawCenteredLabelValue(surface: *chasen.Surface, row: u16, label: []const u8, value: []const u8, label_style: chasen.TextStyle, value_style: chasen.TextStyle) !void {
    const size = surface.size();
    if (row >= size.height or size.width == 0) return;

    const gap_width: u16 = 1;
    const label_width = chasen.text.displayWidth(label);
    const value_width = chasen.text.displayWidth(value);
    const line_width = label_width + gap_width + value_width;
    var col: u16 = if (line_width < size.width) (size.width - line_width) / 2 else 0;

    try draw.copyClippedTextAt(surface, col, row, label, label_style);
    col +|= @intCast(label_width + gap_width);
    if (col < size.width) try draw.copyClippedTextAt(surface, col, row, value, value_style);
}

fn drawCommitInputLine(surface: *chasen.Surface, col: u16, row: u16, text: []const u8, cursor: ?usize, style: chasen.TextStyle) !void {
    const size = surface.size();
    if (col >= size.width or row >= size.height) return;

    const width = size.width - col;
    const visible = if (cursor) |cursor_pos| inputVisibleSlice(text, cursor_pos, width) else text;
    try draw.copyClippedTextAt(surface, col, row, visible, style);
}

fn inputVisibleSlice(text: []const u8, cursor: usize, width: u16) []const u8 {
    return text[inputVisibleStart(text, cursor, width)..];
}

fn inputVisibleStart(text: []const u8, cursor: usize, width: u16) usize {
    const clamped_cursor = @min(cursor, text.len);
    if (width == 0 or text.len == 0) return clamped_cursor;

    const max_width_before_cursor = width - 1;
    var iter = chasen.text.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        if (grapheme.start > clamped_cursor) break;
        if (chasen.text.displayWidth(text[grapheme.start..clamped_cursor]) <= max_width_before_cursor) {
            return grapheme.start;
        }
    }
    return clamped_cursor;
}

fn showInputCursor(surface: *chasen.Surface, col: u16, row: u16, text: []const u8, cursor: usize) void {
    const size = surface.size();
    if (col >= size.width or row >= size.height) return;

    const width = size.width - col;
    const clamped_cursor = @min(cursor, text.len);
    const visible_start = inputVisibleStart(text, clamped_cursor, width);
    const text_width = chasen.text.displayWidth(text[visible_start..clamped_cursor]);
    const cursor_col = @min(size.width - 1, col +| text_width);
    surface.showCursor(cursor_col, row);
}

fn showBodyInputCursor(surface: *chasen.Surface, body: *const app_commit_panel.BodyText) void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    const total_lines = body.lineCount();
    const overflow = total_lines > size.height;
    const text_rows = if (overflow and size.height > 0) size.height - 1 else size.height;
    const start_line = bodyVisibleStartLine(body, text_rows);
    const visible_line_index = bodyActiveLineIndex(body, start_line, text_rows) orelse return;

    const line = body.lineAt(start_line + visible_line_index) orelse "";
    showInputCursor(surface, 0, @intCast(visible_line_index), line, body.cursorLinePrefix().len);
}

fn bodyVisibleStartLine(body: *const app_commit_panel.BodyText, text_rows: u16) u16 {
    const total_lines = body.lineCount();
    if (text_rows == 0 or total_lines <= text_rows) return 0;
    const cursor_line = body.cursorLineIndex();
    if (cursor_line < text_rows) return 0;
    return @intCast(cursor_line - text_rows + 1);
}

fn bodyActiveLineIndex(body: *const app_commit_panel.BodyText, start_line: u16, text_rows: u16) ?u16 {
    if (text_rows == 0) return null;

    const cursor_line = body.cursorLineIndex();
    if (cursor_line < start_line or cursor_line >= @as(usize, start_line) + text_rows) return null;
    return @intCast(cursor_line - start_line);
}

fn stagedSummaryText(allocator: std.mem.Allocator, summary: app_commit_panel.StagedSummary) ![]const u8 {
    return switch (summary) {
        .ready => |ready| try std.fmt.allocPrint(allocator, "{d} staged file{s}", .{ ready.count, if (ready.count == 1) "" else "s" }),
        .loading_or_stale => "status loading...",
        .unavailable => "status unavailable",
    };
}

fn footerItems(app: anytype, storage: *[4]ui.key_hint.Item, key_buffers: *[4][16]u8) []const ui.key_hint.Item {
    var len: usize = 0;
    if (app.viewer.sidebar_hidden) {
        appendFooterItem(app, storage, key_buffers, &len, .toggle_sidebar, "sidebar");
    } else {
        storage[len] = ui.key_hint.item("Tab", "focus");
        len += 1;
    }
    appendFooterItem(app, storage, key_buffers, &len, .commit, "commit");
    appendFooterItem(app, storage, key_buffers, &len, .help, "help");
    storage[len] = ui.key_hint.item("q", "quit");
    len += 1;
    return storage[0..len];
}

fn appendFooterItem(
    app: anytype,
    storage: *[4]ui.key_hint.Item,
    key_buffers: *[4][16]u8,
    len: *usize,
    action: keymap.PublicAction,
    description: []const u8,
) void {
    const key = app.keymap.display(action, key_buffers[len.*][0..]);
    storage[len.*] = ui.key_hint.item(key, description);
    len.* += 1;
}

fn viewHelpPopup(app: anytype, surface: *chasen.Surface) !void {
    const modal = ui.Modal.init(.{});
    const opts = helpModalOptions(surface.size());
    fillModalDialog(surface, opts);
    modal.view(surface, opts);

    const content_rect = ui.Modal.contentRect(surface, opts);
    if (content_rect.width == 0 or content_rect.height == 0) return;
    var content = surface.child(content_rect);
    const size = content.size();

    _ = content.borrowTextAt(0, 0, "GitFrame shortcuts", .{ .bold = true });
    if (size.height <= 2) return;

    const body = helpBodyLayout(size);
    const total_rows = helpRenderedRows(size);
    const max_scroll = helpMaxScrollForContentSize(size);
    const scroll = @min(app.overlay.help_scroll, max_scroll);

    if (body.overflow) {
        drawHelpScrollIndicator(&content, scroll, body.visible_rows, total_rows) catch {};
    }

    if (body.visible_rows == 0) return;

    if (!helpUsesTwoColumns(size)) {
        var list = content.child(.{
            .col = 0,
            .row = help_header_rows,
            .width = size.width,
            .height = body.visible_rows,
        });
        try drawHelpSections(app, &list, helpAllSections(), scroll);
        return;
    }

    const left_width: u16 = if (size.width > help_column_gap) (size.width - help_column_gap) / 2 else size.width;
    const right_col: u16 = if (size.width > left_width + help_column_gap) left_width + help_column_gap else size.width;
    const right_width: u16 = if (size.width > right_col) size.width - right_col else 0;

    var left = content.child(.{
        .col = 0,
        .row = help_header_rows,
        .width = left_width,
        .height = body.visible_rows,
    });
    var right = content.child(.{
        .col = right_col,
        .row = help_header_rows,
        .width = right_width,
        .height = body.visible_rows,
    });

    try drawHelpSections(app, &left, &help_left_sections, scroll);
    try drawHelpSections(app, &right, &help_right_sections, scroll);
}

fn fillModalDialog(surface: *chasen.Surface, opts: ui.Modal.ViewOptions) void {
    // Keep the normal screen visible outside the dialog while still making the
    // dialog itself an opaque surface, so diff text never bleeds into modal UI.
    const rect = ui.Modal.dialogRect(surface, opts);
    if (rect.width == 0 or rect.height == 0) return;
    var dialog = surface.child(rect);
    dialog.fillAll(.{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = .{},
    });
}

const HelpBodyLayout = struct {
    visible_rows: u16,
    overflow: bool,
};

fn helpModalOptions(size: chasen.Size) ui.Modal.ViewOptions {
    return .{
        .dialog_width = @min(size.width, help_dialog_max_width),
        .dialog_height = @min(size.height, help_dialog_max_height),
        .title = "Shortcuts",
        .backdrop = false,
        .border = .rounded,
        .title_style = .{ .bold = true, .fg = color_accent },
    };
}

pub fn helpContentSize(size: chasen.Size) chasen.Size {
    const opts = helpModalOptions(size);
    return ui.Modal.contentSizeForOverlay(.{ .col = 0, .row = 0, .width = size.width, .height = size.height }, opts);
}

fn helpBodyLayout(size: chasen.Size) HelpBodyLayout {
    if (size.height <= help_header_rows) return .{ .visible_rows = 0, .overflow = helpRenderedRows(size) > 0 };

    const total_rows = helpRenderedRows(size);
    const initial_rows = size.height - help_header_rows;
    if (total_rows <= @as(usize, initial_rows)) return .{ .visible_rows = initial_rows, .overflow = false };

    return .{
        .visible_rows = if (initial_rows > help_scroll_indicator_rows) initial_rows - help_scroll_indicator_rows else 0,
        .overflow = true,
    };
}

pub fn helpVisibleRows(size: chasen.Size) u16 {
    return helpBodyLayout(helpContentSize(size)).visible_rows;
}

pub fn helpMaxScroll(size: chasen.Size) usize {
    return helpMaxScrollForContentSize(helpContentSize(size));
}

fn helpMaxScrollForContentSize(content_size: chasen.Size) usize {
    const body = helpBodyLayout(content_size);
    const total_rows = helpRenderedRows(content_size);
    const visible_rows: usize = body.visible_rows;
    if (total_rows <= visible_rows) return 0;
    return total_rows - visible_rows;
}

pub fn helpRenderedRows(size: chasen.Size) usize {
    if (!helpUsesTwoColumns(size)) return rowsForSections(helpAllSections());
    return @max(rowsForSections(&help_left_sections), rowsForSections(&help_right_sections));
}

fn helpUsesTwoColumns(size: chasen.Size) bool {
    return size.width >= help_two_column_min_width;
}

fn helpAllSections() []const HelpSection {
    return &help_all_sections;
}

fn rowsForSections(sections: []const HelpSection) usize {
    var rows: usize = 0;
    for (sections, 0..) |section, index| {
        rows += 1 + section.items.len;
        if (index + 1 < sections.len) rows += 1;
    }
    return rows;
}

fn drawHelpSections(app: anytype, surface: *chasen.Surface, sections: []const HelpSection, scroll: usize) !void {
    const height: usize = surface.size().height;
    var source_row: usize = 0;
    var drawn_rows: usize = 0;

    for (sections, 0..) |section, section_index| {
        if (drawn_rows >= height) return;
        try drawHelpLine(app, surface, scroll, source_row, &drawn_rows, .section_title, section.title, .{ .key = .{ .text = "" }, .description = "" });
        source_row += 1;

        for (section.items) |item| {
            if (drawn_rows >= height) return;
            try drawHelpLine(app, surface, scroll, source_row, &drawn_rows, .item, "", item);
            source_row += 1;
        }

        if (section_index + 1 < sections.len) {
            if (drawn_rows >= height) return;
            try drawHelpLine(app, surface, scroll, source_row, &drawn_rows, .blank, "", .{ .key = .{ .text = "" }, .description = "" });
            source_row += 1;
        }
    }
}

const HelpLineKind = enum {
    section_title,
    item,
    blank,
};

fn drawHelpLine(
    app: anytype,
    surface: *chasen.Surface,
    scroll: usize,
    source_row: usize,
    drawn_rows: *usize,
    kind: HelpLineKind,
    first: []const u8,
    item: HelpItem,
) !void {
    if (source_row < scroll) return;
    const row_offset = source_row - scroll;
    if (row_offset >= surface.size().height) return;

    const row: u16 = @intCast(row_offset);
    switch (kind) {
        .section_title => try draw.copyClippedTextAt(surface, 0, row, first, .{ .bold = true, .fg = color_prompt }),
        .item => try drawHelpItem(app, surface, row, item),
        .blank => {},
    }
    drawn_rows.* = row_offset + 1;
}

fn drawHelpItem(app: anytype, surface: *chasen.Surface, row: u16, item: HelpItem) !void {
    if (surface.size().width == 0) return;
    const key_width: u16 = @min(12, surface.size().width);
    var key_buffer: [16]u8 = undefined;
    var left_buffer: [16]u8 = undefined;
    var right_buffer: [16]u8 = undefined;
    var pair_buffer: [40]u8 = undefined;
    const key = switch (item.key) {
        .text => |text| text,
        .action => |action| app.keymap.display(action, key_buffer[0..]),
        .pair => |pair| blk: {
            const left = app.keymap.display(pair.left, left_buffer[0..]);
            const right = app.keymap.display(pair.right, right_buffer[0..]);
            break :blk std.fmt.bufPrint(pair_buffer[0..], "{s} / {s}", .{ left, right }) catch left;
        },
    };
    try draw.copyClippedTextAt(surface, 0, row, key, .{ .bold = true });
    if (surface.size().width <= key_width) return;
    try draw.copyClippedTextAt(surface, key_width, row, item.description, .{});
}

fn drawHelpScrollIndicator(surface: *chasen.Surface, scroll: usize, visible_rows: u16, total_rows: usize) !void {
    if (surface.size().width == 0 or surface.size().height == 0 or visible_rows == 0 or total_rows == 0) return;

    const start = @min(scroll + 1, total_rows);
    const end = @min(total_rows, scroll + @as(usize, visible_rows));
    const text = try std.fmt.allocPrint(surface.frameAllocator(), "{d}-{d}/{d}", .{ start, end, total_rows });
    const clipped = chasen.text.clipToWidth(text, surface.size().width);
    const text_width = chasen.text.displayWidth(clipped);
    const col: u16 = if (surface.size().width > text_width) surface.size().width - text_width else 0;
    _ = try surface.copyTextAt(col, surface.size().height - 1, clipped, .{ .fg = .gray });
}

pub fn drawSearchMatchMarker(app: anytype, surface: *chasen.Surface) void {
    const match_offset = app.search.match_offset orelse return;
    if (match_offset < app.viewer.diff_scroll) return;

    const visible_offset = match_offset - app.viewer.diff_scroll;
    const body_rows = diff_render.visibleBodyRows(surface.size().height);
    if (visible_offset >= body_rows) return;

    const row: u16 = @intCast(diff_body_start_row + visible_offset);
    _ = surface.borrowTextAt(0, row, "»", .{ .bold = true, .reverse = true, .fg = color_prompt });
}

fn diffContentSurface(surface: *chasen.Surface) chasen.Surface {
    const size = surface.size();
    if (size.width <= search_marker_gutter_width) {
        return surface.child(.{ .col = 0, .row = 0, .width = size.width, .height = size.height });
    }
    return surface.child(.{
        .col = search_marker_gutter_width,
        .row = 0,
        .width = size.width - search_marker_gutter_width,
        .height = size.height,
    });
}

pub fn contentWidth(width: u16) u16 {
    return if (width > search_marker_gutter_width) width - search_marker_gutter_width else width;
}

fn statusStyle(row: sidebar_view_model.Row, status: file_tree.Status, pane_active: bool) chasen.TextStyle {
    const fg: chasen.Color = switch (row.stage_presence) {
        .staged_only => color_staged,
        .mixed => color_prompt,
        .conflict => color_danger,
        else => switch (status) {
            .modified => color_prompt,
            .added => color_success,
            .deleted => color_danger,
            .renamed => color_accent,
            .binary => color_binary,
        },
    };
    return .{ .fg = fg, .bold = true, .dim = !pane_active, .reverse = pane_active and row.selected };
}

fn reviewedStyle(selected: bool, pane_active: bool) chasen.TextStyle {
    return .{ .fg = color_success, .bold = true, .dim = !pane_active, .reverse = pane_active and selected };
}

fn modeBadgeStyle(selected: bool, pane_active: bool) chasen.TextStyle {
    return .{ .fg = color_info, .bold = true, .dim = !pane_active, .reverse = pane_active and selected };
}

fn paneTitleStyle(active: bool) chasen.TextStyle {
    return if (active)
        .{ .bold = true, .fg = color_accent }
    else
        .{ .bold = true, .fg = .gray, .dim = true };
}

fn paneSearchStyle(active: bool) chasen.TextStyle {
    return if (active)
        .{ .bold = true, .fg = color_prompt }
    else
        .{ .fg = color_prompt };
}

fn paneBranchStyle(active: bool) chasen.TextStyle {
    return if (active)
        .{ .fg = color_info }
    else
        .{ .fg = color_info, .dim = true };
}

fn paneHeaderRuleStyle(active: bool) chasen.TextStyle {
    return if (active)
        .{ .dim = true }
    else
        .{ .fg = .gray, .dim = true };
}

fn shellSeparatorStyle() chasen.TextStyle {
    return .{ .dim = true };
}

fn paneTitleText(label: []const u8, active: bool) []const u8 {
    if (std.mem.eql(u8, label, "Files")) return " Files";
    if (!active) return label;
    if (std.mem.eql(u8, label, "Diff")) return "▸ Diff";
    return label;
}

pub fn terminalBodyHeight(terminal_height: u16) u16 {
    return if (terminal_height > footer_rows) terminal_height - footer_rows else 0;
}

pub fn sidebarWidth(total_width: u16, preferred_width: ?u16) u16 {
    return clampSidebarWidth(total_width, preferred_width orelse defaultSidebarWidth(total_width));
}

pub fn defaultSidebarWidth(total_width: u16) u16 {
    if (total_width < 50) return @min(total_width, 24);
    if (total_width < 90) return 28;
    return 34;
}

pub fn clampSidebarWidth(total_width: u16, width: u16) u16 {
    const min_diff_pane_width: u16 = 24;
    const hard_max_width: u16 = 48;
    const max_available = if (total_width > min_diff_pane_width + 1) total_width - min_diff_pane_width - 1 else total_width;
    const max_width = @min(hard_max_width, max_available);
    const min_width = @min(@as(u16, 18), max_width);
    return @min(@max(width, min_width), max_width);
}

test "footer segment fit includes left inset" {
    var segments = FooterSegments{};
    segments.append(.{ .text = "aa", .style = .{} });
    segments.append(.{ .text = "bb", .style = .{}, .drop_priority = .source });

    try std.testing.expectEqual(@as(u16, 7), segments.requiredWidth());
    segments.fit(6);

    try std.testing.expectEqual(@as(u16, 3), segments.requiredWidth());
    try std.testing.expect(!segments.items[1].visible);
}

test "shell content size matches panel content surface" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(100, 20);
    defer ts.deinit();

    const frame = ui.Panel.frame(&ts.surface, shellFrameOptions());
    const expected = shellContentSize(ts.surface.size());
    const content = frame.contentSurface();

    try std.testing.expectEqual(expected, content.size());
    try std.testing.expectEqual(chasen.Size{ .width = 98, .height = 18 }, expected);
}

test "shell content size falls back to terminal size on small surfaces" {
    const small = chasen.Size{ .width = 29, .height = 20 };

    try std.testing.expect(!shellFrameEnabled(small));
    try std.testing.expectEqual(small, shellContentSize(small));
}

test "help popup uses one column on narrow content" {
    const size = chasen.Size{ .width = 70, .height = 20 };
    const content = helpContentSize(size);

    try std.testing.expect(content.width < help_two_column_min_width);
    try std.testing.expectEqual(rowsForSections(helpAllSections()), helpRenderedRows(content));
}

test "help content size uses Modal overlay sizing" {
    const size = chasen.Size{ .width = 140, .height = 20 };
    const opts = helpModalOptions(size);
    const expected = ui.Modal.contentSizeForOverlay(.{ .col = 0, .row = 0, .width = size.width, .height = size.height }, opts);

    try std.testing.expectEqual(expected, helpContentSize(size));
}

test "help popup uses two columns on wide content" {
    const size = chasen.Size{ .width = 140, .height = 20 };
    const content = helpContentSize(size);

    try std.testing.expect(content.width >= help_two_column_min_width);
    try std.testing.expectEqual(@max(rowsForSections(&help_left_sections), rowsForSections(&help_right_sections)), helpRenderedRows(content));
}

test "help popup reserves indicator row only when content overflows" {
    const roomy = chasen.Size{ .width = 140, .height = 40 };
    const cramped = chasen.Size{ .width = 140, .height = 10 };

    try std.testing.expectEqual(@as(usize, 0), helpMaxScroll(roomy));
    try std.testing.expect(helpMaxScroll(cramped) > 0);
    try std.testing.expect(helpVisibleRows(cramped) < helpContentSize(cramped).height - help_header_rows);
}

test "help popup max scroll helper separates outer and content sizes" {
    const outer = chasen.Size{ .width = 140, .height = 10 };
    const content = helpContentSize(outer);

    try std.testing.expectEqual(helpMaxScrollForContentSize(content), helpMaxScroll(outer));
}

const HelpItem = struct {
    key: HelpKey,
    description: []const u8,
};

const HelpKey = union(enum) {
    text: []const u8,
    action: keymap.PublicAction,
    pair: struct {
        left: keymap.PublicAction,
        right: keymap.PublicAction,
    },
};

const HelpSection = struct {
    title: []const u8,
    items: []const HelpItem,
};

const help_global_items = [_]HelpItem{
    .{ .key = .{ .text = "Tab" }, .description = "focus sidebar / diff" },
    .{ .key = .{ .action = .help }, .description = "open / close help" },
    .{ .key = .{ .text = "q" }, .description = "quit" },
    .{ .key = .{ .action = .toggle_sidebar }, .description = "show / hide sidebar" },
    .{ .key = .{ .action = .reload }, .description = "reload active repository" },
    .{ .key = .{ .action = .repo_picker }, .description = "switch repository" },
    .{ .key = .{ .action = .commit }, .description = "open commit panel" },
    .{ .key = .{ .action = .amend }, .description = "amend last commit" },
    .{ .key = .{ .action = .push }, .description = "push current branch" },
    .{ .key = .{ .action = .discard }, .description = "discard selected file changes" },
    .{ .key = .{ .action = .open_editor }, .description = "open selected file in editor" },
    .{ .key = .{ .text = "a / N" }, .description = "approve / needs changes in review mode" },
    .{ .key = .{ .text = "Home/End" }, .description = "first / last file" },
    .{ .key = .{ .pair = .{ .left = .first_file, .right = .last_file } }, .description = "first / last file" },
};

const help_sidebar_items = [_]HelpItem{
    .{ .key = .{ .text = "↑/↓ j/k" }, .description = "move selection" },
    .{ .key = .{ .text = "Enter" }, .description = "toggle directory" },
    .{ .key = .{ .text = "←/→" }, .description = "collapse / expand directory" },
    .{ .key = .{ .text = "h / l" }, .description = "scroll file tree horizontally" },
    .{ .key = .{ .action = .file_search }, .description = "search files" },
    .{ .key = .{ .action = .changed_file_filter }, .description = "cycle file filter" },
    .{ .key = .{ .text = "s" }, .description = "stage / unstage file or directory" },
    .{ .key = .{ .action = .mark_reviewed }, .description = "mark reviewed" },
    .{ .key = .{ .pair = .{ .left = .hide_reviewed, .right = .toggle_line_numbers } }, .description = "hide reviewed / line numbers" },
    .{ .key = .{ .pair = .{ .left = .decrease_sidebar_width, .right = .increase_sidebar_width } }, .description = "resize sidebar" },
};

const help_diff_items = [_]HelpItem{
    .{ .key = .{ .text = "↑/↓ j/k" }, .description = "scroll" },
    .{ .key = .{ .pair = .{ .left = .page_up, .right = .page_down } }, .description = "page scroll" },
    .{ .key = .{ .text = "←/→" }, .description = "horizontal scroll" },
    .{ .key = .{ .text = "Enter" }, .description = "fold / unfold hunk" },
    .{ .key = .{ .action = .search }, .description = "search diff" },
    .{ .key = .{ .action = .toggle_display_mode }, .description = "unified / side-by-side" },
    .{ .key = .{ .action = .toggle_line_numbers }, .description = "toggle line numbers" },
    .{ .key = .{ .text = "J / K" }, .description = "next / previous hunk" },
    .{ .key = .{ .text = "n / p" }, .description = "next / previous match or hunk" },
    .{ .key = .{ .text = "N" }, .description = "previous search match" },
    .{ .key = .{ .text = "s" }, .description = "stage / unstage hunk" },
};

const help_mouse_items = [_]HelpItem{
    .{ .key = .{ .text = "wheel" }, .description = "scroll pane under pointer" },
    .{ .key = .{ .text = "click" }, .description = "focus pane / select sidebar row" },
};

const help_left_sections = [_]HelpSection{
    .{ .title = "Global", .items = &help_global_items },
    .{ .title = "Sidebar", .items = &help_sidebar_items },
};

const help_right_sections = [_]HelpSection{
    .{ .title = "Diff", .items = &help_diff_items },
    .{ .title = "Mouse", .items = &help_mouse_items },
};

const help_all_sections = [_]HelpSection{
    .{ .title = "Global", .items = &help_global_items },
    .{ .title = "Sidebar", .items = &help_sidebar_items },
    .{ .title = "Diff", .items = &help_diff_items },
    .{ .title = "Mouse", .items = &help_mouse_items },
};
