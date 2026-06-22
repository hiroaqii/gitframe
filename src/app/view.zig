const std = @import("std");
const chasen = @import("chasen");
const ui = @import("chasen_ui");
const app_commit_panel = @import("commit_panel.zig");
const draw = @import("draw");
const diff_render = @import("../diff/render.zig");
const git_status = @import("../git/status.zig");
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
pub const diff_body_start_row: u16 = 3;

const search_marker_gutter_width: u16 = 1;
const shell_frame_min_width: u16 = 30;
const shell_frame_min_height: u16 = 6;
const shell_frame_border = ui.Panel.Border.rounded;
const shell_frame_padding: ui.layout.Insets = .{};
const help_dialog_max_width: u16 = 108;
const help_dialog_max_height: u16 = 28;
const help_two_column_min_width: u16 = 96;
const help_column_gap: u16 = 2;
const help_header_rows: u16 = 2;
const help_scroll_indicator_rows: u16 = 1;
const commit_dialog_width: u16 = 72;
const commit_dialog_height: u16 = 22;

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
    if (app.commit_panel.mode) {
        try viewCommitPanel(app, surface);
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
    col.borrowText(title, .{ .bold = true, .fg = .{ .index = 14 } });
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
    _ = surface.borrowTextAt(0, 0, paneTitleText("Files", active), paneTitleStyle(active));
    _ = try surface.printAt(0, 1, .{ .fg = .gray }, "{d} files / {d} hunks", .{
        loaded.document.files.len,
        loaded.document.totalHunks(),
    });
    if (size.width > 2) {
        if (app.review_display.hide_reviewed_files and app.review_display.changed_file_filter != .all) {
            const text = try std.fmt.allocPrint(surface.frameAllocator(), "hiding reviewed / {s}", .{app.review_display.changed_file_filter.label()});
            try draw.copyClippedTextAt(surface, 0, 2, text, .{ .fg = .{ .index = 11 } });
        } else if (app.review_display.hide_reviewed_files) {
            try draw.copyClippedTextAt(surface, 0, 2, "hiding reviewed", .{ .fg = .{ .index = 11 } });
        } else if (app.review_display.changed_file_filter != .all) {
            try draw.copyClippedTextAt(surface, 0, 2, app.review_display.changed_file_filter.label(), .{ .fg = .{ .index = 11 } });
        }
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
        const row_model = loaded.sidebarRowAt(visible_index, app.viewer.selected_node) orelse continue;
        try drawSidebarRow(surface, row, row_model, app.viewer.focus == .sidebar);
    }
}

fn drawSidebarRow(surface: *chasen.Surface, row: u16, row_model: sidebar_view_model.Row, pane_active: bool) !void {
    const width = surface.size().width;
    const row_layout = sidebar_view_model.layout(row_model, width);
    const style = sidebarRowStyle(row_model, pane_active);
    const marker = if (row_model.selected) ">" else " ";

    if (width > row_layout.marker_col) {
        _ = surface.borrowTextAt(0, row, marker, style);
    }

    if (row_layout.fold_col) |fold_col| {
        if (width > fold_col) {
            const fold_marker = switch (row_model.fold) {
                .none => "",
                .expanded => "▾",
                .collapsed => "▸",
            };
            _ = surface.borrowTextAt(fold_col, row, fold_marker, style);
        }
    }

    if (row_model.status) |status| {
        if (row_layout.badge_col) |badge_col| {
            if (width > badge_col) {
                _ = surface.borrowTextAt(badge_col, row, status.badge(), statusStyle(row_model, status));
            }
        }
    }

    if (row_layout.mode_col) |mode_col| {
        if (width > mode_col) {
            _ = surface.borrowTextAt(mode_col, row, "m", modeBadgeStyle(row_model.selected));
        }
    }

    if (row_layout.reviewed_col) |reviewed_col| {
        if (width > reviewed_col) {
            _ = surface.borrowTextAt(reviewed_col, row, "✓", reviewedStyle(row_model.selected));
        }
    }

    if (row_layout.name_width > 0) {
        var path_area = surface.child(.{
            .col = row_layout.name_col,
            .row = row,
            .width = row_layout.name_width,
            .height = 1,
        });
        try draw.copyClippedTextAt(&path_area, 0, 0, row_model.name, style);
    }

    if (row_layout.stats_col) |stats_col| {
        _ = try surface.printAt(stats_col, row, style, "+{d} -{d}", .{
            row_model.stats.added,
            row_model.stats.removed,
        });
    }
}

fn sidebarRowStyle(row: sidebar_view_model.Row, pane_active: bool) chasen.TextStyle {
    if (row.selected) return .{ .reverse = true, .bold = true };
    if (row.kind == .directory) return .{ .bold = true, .fg = .gray, .dim = !pane_active };
    return switch (row.stage_presence) {
        .staged_only => .{ .fg = .{ .index = 10 }, .dim = !pane_active },
        .mixed => .{ .fg = .{ .index = 11 }, .dim = !pane_active },
        .conflict => .{ .fg = .{ .index = 9 }, .bold = true, .dim = !pane_active },
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

    const selected = app.selectedFileIndex(&loaded) orelse 0;
    const file = loaded.document.files[selected];
    var diff_content = diffContentSurface(surface);
    const mode = diff_render.effectiveMode(diff_content.size().width, app.viewer.display_mode);
    const mode_label = diff_render.modeLabel(diff_content.size().width, app.viewer.display_mode);
    const active = app.viewer.sidebar_hidden or app.viewer.focus == .diff;
    const status_style = paneStatusStyle(active);
    const status_text = try std.fmt.allocPrint(surface.frameAllocator(), "{s} {d}/{d}  {d} hunks  {s}  scroll:{d}{s}", .{
        paneTitleText("Diff", active),
        selected + 1,
        loaded.document.files.len,
        file.hunks.len,
        mode_label,
        app.viewer.diff_scroll,
        horizontalScrollStatus(surface, app.viewer.diff_horizontal_scroll),
    });
    try draw.copyClippedTextAt(surface, 0, 2, status_text, status_style);
    if (app.search.query.len > 0 or app.search.mode) {
        surface.clear(.{ .col = 0, .row = 2, .width = size.width, .height = 1 });
    }
    if (!app.search.mode and app.search.query.len > 0 and size.width > 0) {
        const match_text = if (app.search.match_offset) |offset|
            std.fmt.allocPrint(surface.frameAllocator(), "search: {s} @ {d}", .{ app.search.query.slice(), offset + 1 }) catch "search"
        else
            std.fmt.allocPrint(surface.frameAllocator(), "search: {s} (no match)", .{app.search.query.slice()}) catch "search";
        draw.copyClippedTextAt(surface, 0, 2, match_text, paneSearchStyle(app.viewer.focus == .diff)) catch {};
    } else if (app.search.mode and size.width > 0) {
        const prompt_text = std.fmt.allocPrint(surface.frameAllocator(), "search: {s}", .{app.search.input.slice()}) catch "search";
        draw.copyClippedTextAt(surface, 0, 2, prompt_text, paneSearchStyle(app.viewer.focus == .diff)) catch {};
    }
    try diff_render.renderFile(&diff_content, file, .{
        .requested_mode = app.viewer.display_mode,
        .scroll = app.viewer.diff_scroll,
        .horizontal_scroll = app.viewer.diff_horizontal_scroll,
        .pane_active = active,
        .line_numbers = app.viewer.view_options.line_numbers,
        .highlighted_hunk = if (file.hunks.len > 0) app.viewer.selected_hunk else null,
        .line_index = loaded.cachedRenderedLineIndex(selected, mode),
        .folded_hunks = loaded.foldedHunksForFile(selected),
    });
    drawSearchMatchMarker(app, surface);
}

fn viewStatusOnlyPane(app: anytype, surface: *chasen.Surface, entry: git_status.StatusEntry) !void {
    const active = app.viewer.sidebar_hidden or app.viewer.focus == .diff;
    const style = paneStatusStyle(active);
    const title = try std.fmt.allocPrint(surface.frameAllocator(), "{s} {s}", .{ paneTitleText("Status", active), stagePresenceLabel(entry) });
    try draw.copyClippedTextAt(surface, 0, 2, title, style);

    var content = diffContentSurface(surface);
    const path = entry.canonicalPathKey() orelse entry.path;

    switch (app.review_projection) {
        .ready => |ready| {
            switch (ready.value) {
                .cached_diff => |bundle| {
                    if (bundle.loaded.document.files.len > 0) {
                        try diff_render.renderFile(&content, bundle.loaded.document.files[0], .{
                            .requested_mode = app.viewer.display_mode,
                            .scroll = app.viewer.diff_scroll,
                            .horizontal_scroll = app.viewer.diff_horizontal_scroll,
                            .pane_active = active,
                            .line_numbers = app.viewer.view_options.line_numbers,
                            .line_index = bundle.loaded.cachedRenderedLineIndex(0, diff_render.effectiveMode(content.size().width, app.viewer.display_mode)),
                        });
                        return;
                    }
                },
                .generated_added_file => |bundle| {
                    try diff_render.renderGeneratedAddedFile(&content, bundle.file.path, bundle.file.lines, bundle.file.truncated, .{
                        .requested_mode = app.viewer.display_mode,
                        .scroll = app.viewer.diff_scroll,
                        .horizontal_scroll = app.viewer.diff_horizontal_scroll,
                        .pane_active = active,
                        .line_numbers = app.viewer.view_options.line_numbers,
                    });
                    return;
                },
                .status_body => |body| {
                    try drawStatusBody(&content, body.path, body.message, active);
                    return;
                },
            }
        },
        .failed => |failed| {
            try drawStatusBody(&content, failed.body.path, failed.body.message, active);
            return;
        },
        .pending => {
            try drawStatusBody(&content, path, "Loading review projection...", active);
            return;
        },
        .idle => {},
    }

    try draw.copyClippedTextAt(&content, 0, 0, path, .{ .bold = true, .fg = .{ .index = 11 }, .dim = !active });
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

fn drawStatusBody(surface: *chasen.Surface, path: []const u8, message: []const u8, active: bool) !void {
    try draw.copyClippedTextAt(surface, 0, 0, path, .{ .bold = true, .fg = .{ .index = 11 }, .dim = !active });
    try draw.copyClippedTextAt(surface, 0, 2, message, .{ .fg = .gray, .dim = !active });
}

fn stagePresenceLabel(entry: git_status.StatusEntry) []const u8 {
    return switch (file_tree.stagePresenceFromEntry(entry)) {
        .staged_only => "staged",
        .mixed => "mixed",
        .untracked => "untracked",
        .conflict => "conflict",
        .unstaged_only => "unstaged",
        .clean_or_unknown => "status-only file",
    };
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

fn horizontalScrollStatus(surface: *chasen.Surface, offset: usize) []const u8 {
    if (offset == 0) return "";
    return std.fmt.allocPrint(surface.frameAllocator(), "  x:{d}", .{offset}) catch "";
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
        .loading => .{ .bold = true, .fg = .{ .index = 11 } },
        .warning => .{ .bold = true, .fg = .{ .index = 11 } },
        .failure => .{ .bold = true, .fg = .{ .index = 9 } },
    };
}

fn stateBodyStyle(tone: StateTone) chasen.TextStyle {
    return switch (tone) {
        .failure => .{ .fg = .{ .index = 9 } },
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

    if (app.search.mode) {
        _ = surface.borrowTextAt(0, 0, "/", .{ .fg = .{ .index = 11 }, .bold = true });
        _ = surface.copyTextAt(1, 0, app.search.input.slice(), .{ .fg = .{ .index = 11 } }) catch {};
        return;
    }

    if (app.file_search.mode) {
        _ = surface.borrowTextAt(0, 0, "file: ", .{ .fg = .{ .index = 11 }, .bold = true });
        _ = surface.copyTextAt(6, 0, app.file_search.input.slice(), .{ .fg = .{ .index = 11 } }) catch {};
        if (app.file_search.no_match) {
            const col: u16 = @intCast(@min(6 + chasen.text.displayWidth(app.file_search.input.slice()) + 1, std.math.maxInt(u16)));
            if (surface.size().width > col) _ = surface.borrowTextAt(col, 0, "(no match)", .{ .fg = .{ .index = 9 } });
        }
        return;
    }

    var col: u16 = 0;
    if (app.config.watch and width > col + 8) {
        _ = surface.borrowTextAt(col, 0, "watch", .{ .fg = .{ .index = 10 } });
        col +|= 7;
    }
    if (app.status.text().len > 0 and width > col + 2) {
        draw.copyClippedTextAt(surface, col, 0, app.status.text(), .{ .fg = .{ .index = 11 } }) catch {};
        const message_width = chasen.text.displayWidth(app.status.text());
        col +|= @intCast(@min(message_width + 2, std.math.maxInt(u16)));
    }

    const size_text = std.fmt.allocPrint(surface.frameAllocator(), "{d}x{d}", .{
        app.terminal_size.width,
        app.terminal_size.height,
    }) catch return;
    const size_width: u16 = @intCast(@min(chasen.text.displayWidth(size_text), std.math.maxInt(u16)));
    const reserved_size_width: u16 = if (width > size_width + 1) size_width + 1 else 0;
    if (width > col + reserved_size_width) {
        var hint_area = surface.child(.{
            .col = col,
            .row = 0,
            .width = width - col - reserved_size_width,
            .height = 1,
        });
        _ = ui.key_hint.draw(&hint_area, 0, 0, footerItems(app), .{
            .style = .{ .fg = .gray },
            .key_style = .{ .bold = true, .fg = .gray },
        });
    }

    if (width > size_width + 1) {
        _ = surface.copyTextAt(width - size_width, 0, size_text, .{ .fg = .gray }) catch {};
    }
}

fn viewRepoPicker(app: anytype, surface: *chasen.Surface) !void {
    const modal = ui.Modal.init(.{});
    const opts: ui.Modal.ViewOptions = .{
        .dialog_width = 64,
        .dialog_height = 14,
        .title = "Repositories",
        .border = .rounded,
        .title_style = .{ .bold = true, .fg = .{ .index = 14 } },
    };
    modal.view(surface, opts);

    const content_rect = ui.Modal.contentRect(surface, opts);
    if (content_rect.width == 0 or content_rect.height == 0) return;
    var content = surface.child(content_rect);
    const size = content.size();

    if (app.repo_picker.prompt_mode == .path_input) {
        _ = content.borrowTextAt(0, 0, "path: ", .{ .fg = .{ .index = 11 }, .bold = true });
        _ = content.copyTextAt(6, 0, app.repo_picker.path_input.slice(), .{ .fg = .{ .index = 11 } }) catch {};
        if (app.repo_picker.path_pending and size.width > 16) {
            _ = content.borrowTextAt(0, 2, "checking path...", .{ .fg = .gray });
        } else if (app.repo_picker.path_error) |err| {
            _ = content.borrowTextAt(0, 2, err.message(), .{ .fg = .{ .index = 9 } });
        } else if (size.height > 2) {
            _ = content.borrowTextAt(0, 2, "Enter: open path  Esc: back", .{ .fg = .gray });
        }
        return;
    }

    _ = content.borrowTextAt(0, 0, "filter: ", .{ .fg = .{ .index = 11 }, .bold = true });
    _ = content.copyTextAt(8, 0, app.repo_picker.list.input.slice(), .{ .fg = .{ .index = 11 } }) catch {};
    if (app.repo_picker.list.no_match and size.width > 20) {
        _ = content.borrowTextAt(20, 0, "(no match)", .{ .fg = .{ .index = 9 } });
    } else if (app.repo_picker.path_pending and size.width > 24) {
        _ = content.borrowTextAt(20, 0, "(checking path...)", .{ .fg = .gray });
    } else if (app.repo_picker.path_error) |err| {
        _ = content.borrowTextAt(20, 0, err.message(), .{ .fg = .{ .index = 9 } });
    }
    if (size.height > 1) {
        try draw.copyClippedTextAt(&content, 0, 1, "Enter: switch  /: filter  : enter path  Esc: close", .{ .fg = .gray });
    }

    if (size.height <= 2) return;
    const rows = size.height - 2;
    const focused = app.repo_picker.list.filter.list.focusedIndex();
    const range = ui.ListViewport.visibleRange(app.repo_picker.list.filter.labels.len, focused, rows);
    var row: u16 = 2;
    var visible_index: usize = range.start;
    while (visible_index < range.end) : ({
        visible_index += 1;
        row += 1;
    }) {
        const source_index = app.repo_picker.list.filter.sourceIndex(visible_index) orelse continue;
        const label = app.repo_picker.list.filter.labels[visible_index];
        const focused_row = visible_index == focused;
        const active = if (source_index < app.repo_picker_items.items.len)
            switch (app.repo_picker_items.items[source_index].source) {
                .active_repo => true,
                .workspace_repo => |repo_index| repo_index == app.repo_state.active_index,
                .pending_workspace_repo, .recent_repo, .recent_workspace => false,
            }
        else
            false;
        const style: chasen.TextStyle = if (focused_row)
            .{ .reverse = true, .bold = true }
        else if (active)
            .{ .fg = .{ .index = 10 }, .bold = true }
        else
            .{};
        const marker = if (focused_row) ">" else " ";
        const active_marker = if (active) "*" else " ";
        _ = content.borrowTextAt(0, row, marker, style);
        _ = content.borrowTextAt(2, row, active_marker, style);
        var label_area = content.child(.{
            .col = 4,
            .row = row,
            .width = if (size.width > 4) size.width - 4 else 0,
            .height = 1,
        });
        try draw.copyClippedTextAt(&label_area, 0, 0, label, style);
    }
}

fn viewCommitPanel(app: anytype, surface: *chasen.Surface) !void {
    const modal = ui.Modal.init(.{});
    const opts: ui.Modal.ViewOptions = .{
        .dialog_width = @min(surface.size().width, commit_dialog_width),
        .dialog_height = @min(surface.size().height, commit_dialog_height),
        .title = "Commit",
        .border = .rounded,
        .title_style = .{ .bold = true, .fg = .{ .index = 14 } },
        .border_style = .{ .fg = .gray },
        .backdrop_style = .{ .dim = true },
    };
    modal.view(surface, opts);

    const content_rect = ui.Modal.contentRect(surface, opts);
    if (content_rect.width == 0 or content_rect.height == 0) return;
    var content = surface.child(content_rect);
    const size = content.size();

    const staged_text = try stagedSummaryText(content.frameAllocator(), app.stagedSummaryForActiveRepo());
    try draw.copyClippedTextAt(&content, 0, 0, staged_text, .{ .fg = .gray });

    const help_row = if (size.height > 0) size.height - 1 else 0;
    const error_row = if (help_row > 0) help_row - 1 else help_row;
    const field_limit_row = if (size.height > 2) error_row else help_row;

    if (size.height > 2 and 2 < field_limit_row) {
        const active = app.commit_panel.active_field == .subject;
        const label_style: chasen.TextStyle = if (active) .{ .bold = true, .fg = .{ .index = 14 } } else .{ .bold = true };
        _ = content.borrowTextAt(0, 2, if (active) ">" else " ", label_style);
        _ = content.borrowTextAt(2, 2, "Subject:", label_style);
        const input_col: u16 = @min(2, size.width);
        if (size.height > 3 and 3 < field_limit_row and size.width > input_col) {
            const cursor = if (active) app.commit_panel.subject.cursor else null;
            try drawCommitInputLine(&content, input_col, 3, app.commit_panel.subject.slice(), cursor, .{ .fg = .{ .index = 11 } });
            if (active) showInputCursor(&content, input_col, 3, app.commit_panel.subject.slice(), app.commit_panel.subject.cursor);
        }
    }

    if (size.height > 5 and 5 < field_limit_row) {
        const active = app.commit_panel.active_field == .body;
        const label_style: chasen.TextStyle = if (active) .{ .bold = true, .fg = .{ .index = 14 } } else .{ .bold = true };
        _ = content.borrowTextAt(0, 5, if (active) ">" else " ", label_style);
        _ = content.borrowTextAt(2, 5, "Body:", label_style);
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
            try draw.copyClippedTextAt(&content, 0, error_row, err.message(), .{ .fg = .{ .index = 9 } });
        } else {
            try draw.copyClippedTextAt(&content, 0, error_row, "Commit execution is added later.", .{ .fg = .gray });
        }
    }

    if (size.height > 0) {
        try draw.copyClippedTextAt(&content, 0, help_row, "Tab: field  Enter: body/newline  Ctrl+Enter/Ctrl+s: validate  Esc: close", .{ .fg = .gray });
    }
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
        const indicator = try std.fmt.allocPrint(surface.frameAllocator(), "... {d}/{d}", .{ start_line + text_rows, total_lines });
        try draw.copyClippedTextAt(surface, 0, size.height - 1, indicator, .{ .fg = .gray });
    }
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

    // BodyText is append-only for now, so the active insertion point is at the
    // end of the last visible input line.
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

fn footerItems(app: anytype) []const ui.key_hint.Item {
    if (app.viewer.sidebar_hidden) return &footer_hidden_sidebar_items;
    return &footer_items;
}

fn viewHelpPopup(app: anytype, surface: *chasen.Surface) !void {
    const modal = ui.Modal.init(.{});
    const opts = helpModalOptions(surface.size());
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
        try drawHelpSections(&list, helpAllSections(), scroll);
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

    try drawHelpSections(&left, &help_left_sections, scroll);
    try drawHelpSections(&right, &help_right_sections, scroll);
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
        .border = .rounded,
        .title_style = .{ .bold = true, .fg = .{ .index = 14 } },
        .border_style = .{ .fg = .gray },
        .backdrop_style = .{ .dim = true },
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

fn drawHelpSections(surface: *chasen.Surface, sections: []const HelpSection, scroll: usize) !void {
    const height: usize = surface.size().height;
    var source_row: usize = 0;
    var drawn_rows: usize = 0;

    for (sections, 0..) |section, section_index| {
        if (drawn_rows >= height) return;
        try drawHelpLine(surface, scroll, source_row, &drawn_rows, .section_title, section.title, "");
        source_row += 1;

        for (section.items) |item| {
            if (drawn_rows >= height) return;
            try drawHelpLine(surface, scroll, source_row, &drawn_rows, .item, item.key, item.description);
            source_row += 1;
        }

        if (section_index + 1 < sections.len) {
            if (drawn_rows >= height) return;
            try drawHelpLine(surface, scroll, source_row, &drawn_rows, .blank, "", "");
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
    surface: *chasen.Surface,
    scroll: usize,
    source_row: usize,
    drawn_rows: *usize,
    kind: HelpLineKind,
    first: []const u8,
    second: []const u8,
) !void {
    if (source_row < scroll) return;
    const row_offset = source_row - scroll;
    if (row_offset >= surface.size().height) return;

    const row: u16 = @intCast(row_offset);
    switch (kind) {
        .section_title => try draw.copyClippedTextAt(surface, 0, row, first, .{ .bold = true, .fg = .{ .index = 11 } }),
        .item => try drawHelpItem(surface, row, .{ .key = first, .description = second }),
        .blank => {},
    }
    drawn_rows.* = row_offset + 1;
}

fn drawHelpItem(surface: *chasen.Surface, row: u16, item: HelpItem) !void {
    if (surface.size().width == 0) return;
    const key_width: u16 = @min(10, surface.size().width);
    try draw.copyClippedTextAt(surface, 0, row, item.key, .{ .bold = true });
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
    _ = surface.borrowTextAt(0, row, ">", .{ .bold = true, .reverse = true, .fg = .{ .index = 11 } });
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

fn statusStyle(row: sidebar_view_model.Row, status: file_tree.Status) chasen.TextStyle {
    const fg: chasen.Color = switch (row.stage_presence) {
        .staged_only => .{ .index = 10 },
        .mixed => .{ .index = 11 },
        .conflict => .{ .index = 9 },
        else => switch (status) {
            .modified => .{ .index = 11 },
            .added => .{ .index = 2 },
            .deleted => .{ .index = 9 },
            .renamed => .{ .index = 14 },
            .binary => .{ .index = 13 },
        },
    };
    return .{ .fg = fg, .bold = true, .reverse = row.selected };
}

fn reviewedStyle(selected: bool) chasen.TextStyle {
    return .{ .fg = .{ .index = 2 }, .bold = true, .reverse = selected };
}

fn modeBadgeStyle(selected: bool) chasen.TextStyle {
    return .{ .fg = .{ .index = 12 }, .bold = true, .reverse = selected };
}

fn paneTitleStyle(active: bool) chasen.TextStyle {
    return if (active)
        .{ .bold = true, .reverse = true, .fg = .{ .index = 14 } }
    else
        .{ .bold = true, .fg = .gray };
}

fn paneStatusStyle(active: bool) chasen.TextStyle {
    return if (active)
        .{ .reverse = true, .fg = .{ .index = 14 } }
    else
        .{ .fg = .gray };
}

fn paneSearchStyle(active: bool) chasen.TextStyle {
    return if (active)
        .{ .reverse = true, .fg = .{ .index = 11 } }
    else
        .{ .fg = .{ .index = 11 } };
}

fn shellSeparatorStyle() chasen.TextStyle {
    return .{ .dim = true };
}

fn paneTitleText(label: []const u8, active: bool) []const u8 {
    if (!active) return label;
    if (std.mem.eql(u8, label, "Files")) return "▸ Files";
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

const footer_items = [_]ui.key_hint.Item{
    ui.key_hint.item("Tab", "focus"),
    ui.key_hint.item("c", "commit"),
    ui.key_hint.item("?", "help"),
    ui.key_hint.item("q", "quit"),
};

const footer_hidden_sidebar_items = [_]ui.key_hint.Item{
    ui.key_hint.item("B", "sidebar"),
    ui.key_hint.item("c", "commit"),
    ui.key_hint.item("?", "help"),
    ui.key_hint.item("q", "quit"),
};

const HelpItem = struct {
    key: []const u8,
    description: []const u8,
};

const HelpSection = struct {
    title: []const u8,
    items: []const HelpItem,
};

const help_global_items = [_]HelpItem{
    .{ .key = "Tab", .description = "focus sidebar / diff" },
    .{ .key = "?", .description = "open / close help" },
    .{ .key = "q", .description = "quit" },
    .{ .key = "B", .description = "show / hide sidebar" },
    .{ .key = "r", .description = "reload active repository" },
    .{ .key = "R", .description = "switch repository" },
    .{ .key = "c", .description = "open commit panel" },
    .{ .key = "s", .description = "stage selected file / directory" },
    .{ .key = "S", .description = "unstage selected file / directory" },
    .{ .key = "Home/End", .description = "first / last file" },
};

const help_sidebar_items = [_]HelpItem{
    .{ .key = "↑/↓ j/k", .description = "move selection" },
    .{ .key = "Enter", .description = "toggle directory" },
    .{ .key = "←/→", .description = "collapse / expand directory" },
    .{ .key = "f", .description = "search files" },
    .{ .key = "F", .description = "cycle file filter" },
    .{ .key = "v", .description = "mark reviewed" },
    .{ .key = "H", .description = "hide reviewed" },
    .{ .key = "[ / ]", .description = "resize sidebar" },
};

const help_diff_items = [_]HelpItem{
    .{ .key = "↑/↓ j/k", .description = "scroll" },
    .{ .key = "←/→", .description = "horizontal scroll" },
    .{ .key = "Enter", .description = "fold / unfold hunk" },
    .{ .key = "/", .description = "search diff" },
    .{ .key = "u", .description = "unified / side-by-side" },
    .{ .key = "L", .description = "toggle line numbers" },
    .{ .key = "J / K", .description = "next / previous hunk" },
    .{ .key = "n / p", .description = "next / previous match or hunk" },
    .{ .key = "N", .description = "previous search match" },
    .{ .key = "e", .description = "open selected file in editor" },
};

const help_mouse_items = [_]HelpItem{
    .{ .key = "wheel", .description = "scroll pane under pointer" },
    .{ .key = "click", .description = "focus pane" },
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
