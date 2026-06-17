const std = @import("std");
const chasen = @import("chasen");
const ui = @import("chasen_ui");
const diff_render = @import("diff_render.zig");
const loaded_diff = @import("loaded_diff.zig");
const file_tree = @import("file_tree.zig");
const sidebar_view_model = @import("sidebar_view_model.zig");

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
    if (!shellFrameEnabled(terminal_size)) return terminal_size;
    const rect = ui.Panel.contentRectFor(.{
        .col = 0,
        .row = 0,
        .width = terminal_size.width,
        .height = terminal_size.height,
    }, shell_frame_padding);
    return .{ .width = rect.width, .height = rect.height };
}

fn viewBody(app: anytype, surface: *chasen.Surface) !void {
    switch (app.load.state) {
        .loaded => |loaded| return viewLoadedDiff(app, surface, loaded),
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
    try viewLoadState(app, &col);
    col.borrowText("Keys: r reload, q quit", .{ .fg = .gray });
}

fn viewLoadedDiff(app: anytype, surface: *chasen.Surface, loaded: loaded_diff.LoadedDiff) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    if (app.viewer.sidebar_hidden) {
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
        if (app.hide_reviewed_files and app.changed_file_filter != .all) {
            _ = try surface.printAt(0, 2, .{ .fg = .{ .index = 11 } }, "hiding reviewed / {s}", .{app.changed_file_filter.label()});
        } else if (app.hide_reviewed_files) {
            _ = surface.borrowTextAt(0, 2, "hiding reviewed", .{ .fg = .{ .index = 11 } });
        } else if (app.changed_file_filter != .all) {
            _ = surface.borrowTextAt(0, 2, app.changed_file_filter.label(), .{ .fg = .{ .index = 11 } });
        }
    }

    if (size.height <= sidebar_header_rows) return;

    const visible_rows: usize = size.height - sidebar_header_rows;
    const visible_count = loaded.visibleNodeCount();
    const selected_row = loaded.visibleRowOfNode(app.viewer.selected_node) orelse 0;
    // Sidebar has no independent scroll state; derive the visible window
    // from the selected row each frame.
    const range = ui.ListViewport.visibleRange(visible_count, selected_row, visible_rows);
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
                _ = surface.borrowTextAt(badge_col, row, status.badge(), statusStyle(status, row_model.selected));
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
        _ = try path_area.copyTextAt(0, 0, row_model.name, style);
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
    return .{ .dim = !pane_active };
}

/// Draw the selected file's diff pane.
///
/// Diff rows are already backed by rendered-line indexes in LoadedDiff; this
/// layer only chooses the visible file, mode, and current scroll offset.
pub fn viewDiffPane(app: anytype, surface: *chasen.Surface, loaded: loaded_diff.LoadedDiff) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    if (loaded.document.files.len == 0) {
        _ = surface.borrowTextAt(0, 0, "No parsed files.", .{ .fg = .gray });
        return;
    }

    const selected = @min(app.viewer.selected_file, loaded.document.files.len - 1);
    const file = loaded.document.files[selected];
    var diff_content = diffContentSurface(surface);
    const mode = diff_render.effectiveMode(diff_content.size().width, app.viewer.display_mode);
    const active = app.viewer.sidebar_hidden or app.viewer.focus == .diff;
    const focus_label = if (app.viewer.sidebar_hidden)
        "diff/sidebar hidden"
    else if (active)
        "diff"
    else
        "sidebar";
    if (app.viewer.sidebar_hidden) {
        _ = try surface.printAt(0, 2, paneStatusStyle(true), "{s} {d}/{d}  {d} hunks  {s}  {s}  scroll:{d}{s}", .{
            paneTitleText("Diff", true),
            selected + 1,
            loaded.document.files.len,
            file.hunks.len,
            mode.label(),
            focus_label,
            app.viewer.diff_scroll,
            horizontalScrollStatus(surface, app.viewer.diff_horizontal_scroll),
        });
    } else {
        _ = try surface.printAt(0, 2, paneStatusStyle(active), "{s} {d}/{d}  {d} hunks  {s}  focus:{s}  scroll:{d}{s}", .{
            paneTitleText("Diff", active),
            selected + 1,
            loaded.document.files.len,
            file.hunks.len,
            mode.label(),
            focus_label,
            app.viewer.diff_scroll,
            horizontalScrollStatus(surface, app.viewer.diff_horizontal_scroll),
        });
    }
    if (app.search.query.len > 0 or app.search.mode) {
        surface.clear(.{ .col = 0, .row = 2, .width = size.width, .height = 1 });
    }
    if (!app.search.mode and app.search.query.len > 0 and size.width > 0) {
        const match_text = if (app.search.match_offset) |offset|
            std.fmt.allocPrint(surface.frameAllocator(), "search: {s} @ {d}", .{ app.search.query.slice(), offset + 1 }) catch "search"
        else
            std.fmt.allocPrint(surface.frameAllocator(), "search: {s} (no match)", .{app.search.query.slice()}) catch "search";
        _ = surface.copyTextAt(0, 2, match_text, paneSearchStyle(app.viewer.focus == .diff)) catch {};
    } else if (app.search.mode and size.width > 0) {
        const prompt_text = std.fmt.allocPrint(surface.frameAllocator(), "search: {s}", .{app.search.input.slice()}) catch "search";
        _ = surface.copyTextAt(0, 2, prompt_text, paneSearchStyle(app.viewer.focus == .diff)) catch {};
    }
    try diff_render.renderFile(&diff_content, file, .{
        .requested_mode = app.viewer.display_mode,
        .scroll = app.viewer.diff_scroll,
        .horizontal_scroll = app.viewer.diff_horizontal_scroll,
        .pane_active = active,
        .highlighted_hunk = if (file.hunks.len > 0) app.viewer.selected_hunk else null,
        .line_index = loaded.cachedRenderedLineIndex(selected, mode),
        .folded_hunks = loaded.foldedHunksForFile(selected),
    });
    drawSearchMatchMarker(app, surface);
}

fn horizontalScrollStatus(surface: *chasen.Surface, offset: usize) []const u8 {
    if (offset == 0) return "";
    return std.fmt.allocPrint(surface.frameAllocator(), "  x:{d}", .{offset}) catch "";
}

fn viewLoadState(app: anytype, col: *chasen.Column) !void {
    switch (app.load.state) {
        .idle => col.borrowText("Waiting to load diff.", .{ .fg = .gray }),
        .loading => col.borrowText("Loading diff...", .{ .fg = .{ .index = 11 } }),
        .empty => |reason| switch (reason) {
            .no_changes => col.borrowText("No changes found.", .{ .fg = .gray }),
            .no_repository => {
                col.borrowText("No Git repositories found.", .{ .fg = .gray });
                col.borrowText("Run inside a repository or a workspace containing direct child repositories.", .{ .fg = .gray });
            },
        },
        .loaded => |loaded| {
            try col.print("Loaded {d} files / {d} hunks.", .{ loaded.document.files.len, loaded.document.totalHunks() });
            try col.print("{d} bytes across {d} lines.", .{ loaded.bytes, loaded.lines });
        },
        .failed => |message| {
            col.borrowText("Could not load diff:", .{ .fg = .{ .index = 9 }, .bold = true });
            col.borrowText(message, .{ .fg = .{ .index = 9 } });
        },
    }
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
    _ = surface.borrowTextAt(col, 0, "gitframe", .{ .bold = true });
    col +|= 9;
    _ = surface.borrowTextAt(col, 0, "viewer shell", .{ .fg = .gray });
    col +|= 13;
    if (app.config.watch and width > col + 8) {
        _ = surface.borrowTextAt(col, 0, "watch", .{ .fg = .{ .index = 10 } });
        col +|= 7;
    }
    if (app.status_message.len > 0 and width > col + 2) {
        _ = surface.borrowTextAt(col, 0, app.status_message, .{ .fg = .{ .index = 11 } });
        const message_width = chasen.text.displayWidth(app.status_message);
        col +|= @intCast(@min(message_width + 2, std.math.maxInt(u16)));
    }
    const focus_text = focusStatusText(app);
    if (width > col + chasen.text.displayWidth(focus_text) + 2) {
        _ = surface.borrowTextAt(col, 0, focus_text, .{ .fg = .gray, .dim = true });
        col +|= @intCast(@min(chasen.text.displayWidth(focus_text) + 2, std.math.maxInt(u16)));
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

    _ = content.borrowTextAt(0, 0, "filter: ", .{ .fg = .{ .index = 11 }, .bold = true });
    _ = content.copyTextAt(8, 0, app.repo_picker.input.slice(), .{ .fg = .{ .index = 11 } }) catch {};
    if (app.repo_picker.no_match and size.width > 20) {
        _ = content.borrowTextAt(20, 0, "(no match)", .{ .fg = .{ .index = 9 } });
    }

    if (size.height <= 2) return;
    const rows = size.height - 2;
    const focused = app.repo_picker.filter.list.focusedIndex();
    const range = ui.ListViewport.visibleRange(app.repo_picker.filter.labels.len, focused, rows);
    var row: u16 = 2;
    var visible_index: usize = range.start;
    while (visible_index < range.end) : ({
        visible_index += 1;
        row += 1;
    }) {
        const source_index = app.repo_picker.filter.sourceIndex(visible_index) orelse continue;
        const label = app.repo_picker.filter.labels[visible_index];
        const focused_row = visible_index == focused;
        const active = source_index == app.repo_state.active_index;
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
        _ = try label_area.copyTextAt(0, 0, label, style);
    }
}

fn footerItems(app: anytype) []const ui.key_hint.Item {
    if (app.viewer.sidebar_hidden) return &footer_hidden_sidebar_items;
    return switch (app.viewer.focus) {
        .sidebar => &footer_sidebar_items,
        .diff => &footer_diff_items,
    };
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

fn statusStyle(status: file_tree.Status, selected: bool) chasen.TextStyle {
    const fg: chasen.Color = switch (status) {
        .modified => .{ .index = 11 },
        .added => .{ .index = 2 },
        .deleted => .{ .index = 9 },
        .renamed => .{ .index = 14 },
        .binary => .{ .index = 13 },
    };
    return .{ .fg = fg, .bold = true, .reverse = selected };
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

fn focusStatusText(app: anytype) []const u8 {
    if (app.viewer.sidebar_hidden) return "focus: diff";
    return switch (app.viewer.focus) {
        .sidebar => "focus: files",
        .diff => "focus: diff",
    };
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

const footer_sidebar_items = [_]ui.key_hint.Item{
    ui.key_hint.item("Tab", "focus"),
    ui.key_hint.item("↑/↓/j/k", "move"),
    ui.key_hint.item("Enter/←/→", "fold"),
    ui.key_hint.item("/", "search"),
    ui.key_hint.item("f", "file"),
    ui.key_hint.item("R", "repo"),
    ui.key_hint.item("F", "filter"),
    ui.key_hint.item("v", "viewed"),
    ui.key_hint.item("H", "hide viewed"),
    ui.key_hint.item("B", "hide sidebar"),
    ui.key_hint.item("[/]", "width"),
    ui.key_hint.item("e", "edit"),
    ui.key_hint.item("n/p", "hunk/search"),
    ui.key_hint.item("u", "mode"),
    ui.key_hint.item("r", "reload"),
    ui.key_hint.item("q", "quit"),
};

const footer_diff_items = [_]ui.key_hint.Item{
    ui.key_hint.item("Tab", "focus"),
    ui.key_hint.item("↑/↓/j/k", "scroll"),
    ui.key_hint.item("Enter", "fold"),
    ui.key_hint.item("/", "search"),
    ui.key_hint.item("f", "file"),
    ui.key_hint.item("R", "repo"),
    ui.key_hint.item("v", "viewed"),
    ui.key_hint.item("H", "hide viewed"),
    ui.key_hint.item("B", "hide sidebar"),
    ui.key_hint.item("[/]", "width"),
    ui.key_hint.item("e", "edit"),
    ui.key_hint.item("n/p", "hunk/search"),
    ui.key_hint.item("u", "mode"),
    ui.key_hint.item("r", "reload"),
    ui.key_hint.item("q", "quit"),
};

const footer_hidden_sidebar_items = [_]ui.key_hint.Item{
    ui.key_hint.item("↑/↓/j/k", "scroll"),
    ui.key_hint.item("Enter", "fold"),
    ui.key_hint.item("/", "search"),
    ui.key_hint.item("f", "file"),
    ui.key_hint.item("B", "show sidebar"),
    ui.key_hint.item("[/]", "width"),
    ui.key_hint.item("e", "edit"),
    ui.key_hint.item("n/p", "hunk/search"),
    ui.key_hint.item("u", "mode"),
    ui.key_hint.item("r", "reload"),
    ui.key_hint.item("q", "quit"),
};
