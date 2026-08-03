const std = @import("std");
const builtin = @import("builtin");
const chasen = @import("chasen");
const ui = @import("chasen_ui");
const draw = @import("draw");
const branch_chrome = @import("../../branch_chrome.zig");
const app_load_state = @import("../../load_state.zig");
const app_page = @import("../../page.zig");
const review_projection = @import("../../review_projection.zig");
const view_primitives = @import("../../view_primitives.zig");
const review_page = @import("../review.zig");
const review_file_search = @import("file_search.zig");
const review_body_render = @import("body_render.zig");
const review_layout = @import("layout.zig");
const review_navigation = @import("navigation.zig");
const diff_render = @import("../../../diff/render.zig");
const diff_source = @import("../../../diff/source.zig");
const git_branch_status = @import("../../../git/branch_status.zig");
const git_status = @import("../../../git/status.zig");
const keymap = @import("keymap");
const loaded_diff = @import("../../../loaded_diff.zig");
const file_tree = @import("../../../file_tree.zig");
const sidebar_view_model = @import("../../../sidebar/view_model.zig");
const theme = @import("theme");
const test_support = if (builtin.is_test) @import("../../test_support.zig") else struct {};

pub const EmptyRemoteActionHints = struct {
    show_repo_picker: bool = false,
    show_pull: bool = false,
    show_fetch: bool = false,
};

pub const FooterView = struct {
    /// Page-local text input consumes printable keys before shell actions.
    /// Suppress ordinary shell hints while those actions are unreachable.
    normal_action_hints_enabled: bool,
    sidebar_hidden: bool,
    auto_reload_enabled: bool,
    source_label: ?[]const u8,
    activation: ?ActivationPresentation,
};

pub const ActivationPresentation = enum {
    validating,
    stale,
};

pub const Context = struct {
    page: *const review_page.ReviewPageState,
    navigation: review_navigation.View,
    theme: theme.Palette,
    keymap: keymap.Effective,
    source_label: []const u8,
    source: diff_source.SourceMode,
    repo_root: ?[]const u8,
    empty_remote_hints: EmptyRemoteActionHints,

    pub fn init(
        review: *const review_page.ReviewPageState,
        navigation: review_navigation.View,
        palette: theme.Palette,
        effective_keymap: keymap.Effective,
        source_label: []const u8,
        source: diff_source.SourceMode,
        repo_root: ?[]const u8,
        empty_remote_hints: EmptyRemoteActionHints,
    ) Context {
        return .{
            .page = review,
            .navigation = navigation,
            .theme = palette,
            .keymap = effective_keymap,
            .source_label = source_label,
            .source = source,
            .repo_root = repo_root,
            .empty_remote_hints = empty_remote_hints,
        };
    }

    pub fn footer(self: Context) FooterView {
        return .{
            .normal_action_hints_enabled = !self.page.file_search.mode,
            .sidebar_hidden = self.page.viewer.sidebar_hidden,
            .auto_reload_enabled = self.page.auto_reload.enabled(),
            .source_label = sourceFooterLabel(self.source),
            .activation = activationPresentation(self.page, self.source),
        };
    }

    pub fn selectedStatusEntry(self: Context) ?git_status.StatusEntry {
        return self.navigation.selectedStatusEntry();
    }

    pub fn selectedStatusLineStats(self: Context) ?file_tree.Stats {
        return self.navigation.selectedStatusLineStats();
    }

    pub fn activeDiffDisplay(self: Context, allocator: std.mem.Allocator, mode: diff_render.DisplayMode) !?review_navigation.ActiveDiffDisplay {
        return self.navigation.activeDiffDisplay(allocator, mode);
    }

    pub fn displayedReviewBody(self: Context) review_navigation.DisplayedReviewBody {
        return self.navigation.displayedReviewBody();
    }

    pub fn activeGeneratedFileProjection(self: Context) ?*const @import("../../review_projection.zig").GeneratedFileBundle {
        return self.navigation.activeGeneratedFileProjection();
    }

    pub fn activeCachedDiffProjection(self: Context) ?*const @import("../../load.zig").LoadedDiffBundle {
        return self.navigation.activeCachedDiffProjection();
    }

    pub fn selectedHunkIndex(self: Context) ?usize {
        return self.navigation.selectedHunkIndex();
    }

    pub fn visibleDiffCursorOffset(self: Context) ?usize {
        return self.navigation.visibleDiffCursorOffset();
    }

    pub fn diffSelectionView(self: Context) ?@import("../../../diff/selection.zig").View {
        return self.navigation.diffSelectionView();
    }

    pub fn diffHeaderSelectionActive(self: Context) bool {
        return self.navigation.diffHeaderSelectionActive();
    }
};

fn activationPresentation(review: *const review_page.ReviewPageState, source: diff_source.SourceMode) ?ActivationPresentation {
    // Accepted one-shot input is immutable on re-entry and must never pretend
    // that stdin/pager is being read a second time.
    if (diff_source.sourceIsOneShotInput(source)) return null;
    return switch (review.activation.state) {
        .inactive => null,
        .active => |active| blk: {
            const members = active.members;
            if (members.source == .pending or members.status == .pending or members.branch == .pending) {
                break :blk .validating;
            }
            if (members.source == .failed or members.status == .failed or members.branch == .failed) {
                break :blk .stale;
            }
            break :blk null;
        },
    };
}

fn sourceFooterLabel(source: diff_source.SourceMode) ?[]const u8 {
    return switch (source) {
        .unstaged => null,
        .cached => "staged",
        .stdin => "stdin",
        .pager => "pager",
        .patch_file => "patch",
        .range => "range",
        .no_index => "difftool",
    };
}

test "reloadable activation reports validating and stale while one-shot input stays immutable" {
    var review: review_page.ReviewPageState = .{};
    _ = review.activation.activate(1, .pending, .pending, .pending);
    try std.testing.expectEqual(ActivationPresentation.validating, activationPresentation(&review, .unstaged).?);

    review.activation.state.active.members = .{ .source = .fresh, .status = .failed, .branch = .fresh };
    try std.testing.expectEqual(ActivationPresentation.stale, activationPresentation(&review, .unstaged).?);

    try std.testing.expect(activationPresentation(&review, .stdin) == null);
    try std.testing.expect(activationPresentation(&review, .{ .pager = "" }) == null);
}

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

pub fn view(app: Context, surface: *chasen.Surface) !void {
    switch (app.page.load.state) {
        .loaded => |session| return viewLoadedDiff(app, surface, session.loaded),
        else => {},
    }

    // Without an accepted load there is no sidebar owner from which search
    // candidates may borrow paths. Keep the prompt usable, but render the
    // explicit unavailable terminal instead of leaving the old page body
    // visible behind a footer-only input.
    if (app.page.file_search.mode) {
        try drawFileSearch(surface, &app.page.file_search, app.theme);
        return;
    }

    switch (app.page.load.state) {
        .empty => |reason| if (reason == .no_changes) return viewNoChanges(app, surface),
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
    col.borrowText(title, app.theme.boldStyle(.accent));
    col.borrowText(subtitle, app.theme.style(.muted));
    try col.print("Source: {s}", .{app.source_label});
    viewLoadState(app, &col);
}

fn viewNoChanges(app: Context, surface: *chasen.Surface) !void {
    const message = noChangesMessage(app, surface.frameAllocator());
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    if (app.page.viewer.sidebar_hidden) {
        drawStateMessage(surface, message, app.theme);
        return;
    }

    const sidebar_width = review_layout.sidebarWidth(size.width, app.page.viewer.sidebar_width);
    var sidebar = surface.child(.{
        .col = 0,
        .row = 0,
        .width = sidebar_width,
        .height = size.height,
    });
    try viewEmptySidebarChrome(app, &sidebar);

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
    drawStateMessage(&diff_pane, message, app.theme);
}

fn viewEmptySidebarChrome(app: Context, surface: *chasen.Surface) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    try drawSidebarDetailRow(app, surface, 0);

    if (size.height <= 2) return;
    const title = " Files";
    _ = surface.borrowTextAt(0, 2, title, sidebarTitleStyle(app.theme));
    const title_width = chasen.text.displayWidth(title);
    const stats_col = title_width + 1;
    if (stats_col < size.width) {
        _ = try surface.printAt(stats_col, 2, app.theme.style(.muted), "0 files / 0 hunks", .{});
    }
}

fn viewLoadedDiff(app: Context, surface: *chasen.Surface, loaded: loaded_diff.LoadedDiff) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    if (app.page.viewer.sidebar_hidden) {
        if (app.page.file_search.mode) {
            try drawFileSearch(surface, &app.page.file_search, app.theme);
            return;
        }
        if (loaded.visibleNodeCount() == 0) {
            drawStateMessage(surface, filterEmptyMessage(app), app.theme);
            return;
        }
        try viewDiffPane(app, surface, loaded);
        return;
    }

    const sidebar_width = review_layout.sidebarWidth(size.width, app.page.viewer.sidebar_width);
    const search_pane_width = size.width -| (sidebar_width +| 1);
    if (app.page.file_search.mode and search_pane_width < file_search_min_pane_width) {
        try drawFileSearch(surface, &app.page.file_search, app.theme);
        return;
    }
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
    if (app.page.file_search.mode) {
        try drawFileSearch(&diff_pane, &app.page.file_search, app.theme);
        return;
    }
    if (loaded.visibleNodeCount() == 0) {
        drawStateMessage(&diff_pane, filterEmptyMessage(app), app.theme);
        return;
    }
    try viewDiffPane(app, &diff_pane, loaded);
}

/// Draw Review's bounded file-search projection in the diff-pane position.
///
/// Search intentionally replaces the diff body while the sidebar remains as
/// stable context. Each visible label is validated through the typed candidate
/// mapping before it is drawn, so rendering cannot expose a stale path borrow
/// which a later submit would reject.
fn drawFileSearch(surface: *chasen.Surface, state: *const review_file_search.State, palette: theme.Palette) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    const label_col: u16 = 1;
    const prompt_style = palette.boldStyle(.prompt);
    draw.copyClippedTextAt(surface, label_col, 0, file_search_label, prompt_style) catch {};
    const label_width = chasen.text.displayWidth(file_search_label);
    if (size.width > label_col + label_width) {
        const input_col = label_col + label_width;
        try drawInputLine(surface, input_col, 0, state.input.slice(), state.input.cursor, prompt_style);
        view_primitives.showInputCursor(surface, input_col, 0, state.input.slice(), state.input.cursor);
    }

    if (size.height > 1) {
        const status = if (state.truncated)
            "512+ matches; refine search"
        else if (!state.projection_available)
            "File list unavailable; wait or press Esc"
        else if (state.no_match)
            "No matching files"
        else
            "Enter: open  Esc: cancel";
        const role: theme.Role = if (state.no_match or !state.projection_available) .warning else .muted;
        draw.copyClippedTextAt(surface, 1, 1, status, palette.style(role)) catch {};
    }

    if (!state.projection_available) return;
    const visible_rows: usize = size.height -| 2;
    const focused = state.filter.list.focusedIndex();
    const range = ui.ListViewport.visibleRange(state.filter.labels.len, focused, visible_rows);
    var result_index = range.start;
    while (result_index < range.end) : (result_index += 1) {
        const candidate = state.candidateAt(result_index) orelse continue;

        const row: u16 = @intCast(2 + result_index - range.start);
        const style = if (result_index == focused) palette.boldStyle(.prompt) else palette.style(.muted);
        try draw.copyTailClippedTextAt(surface, 1, row, candidate.path_key, style);
    }
}

const file_search_label = "Find file: ";
// Keep enough room for the fixed label and a short visible input tail. Below
// this width the sidebar is less useful than the active prompt, so search uses
// the full body until normal pane geometry becomes usable again.
const file_search_min_pane_width: u16 = 1 + file_search_label.len + 4;

/// Draw the file tree side pane from the materialized sidebar view-model.
pub fn viewSidebar(app: Context, surface: *chasen.Surface, loaded: loaded_diff.LoadedDiff) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    try drawSidebarDetailRow(app, surface, 0);

    if (size.height <= 2) return;
    const title = " Files";
    _ = surface.borrowTextAt(0, 2, title, sidebarTitleStyle(app.theme));
    const title_width = chasen.text.displayWidth(title);
    const stats_col = title_width + 1;
    if (stats_col < size.width) {
        _ = try surface.printAt(stats_col, 2, app.theme.style(.muted), "{d} files / {d} hunks", .{
            loaded.document.files.len,
            loaded.document.totalHunks(),
        });
    }

    if (size.height <= review_layout.sidebar_header_rows) return;

    const visible_rows: usize = size.height - review_layout.sidebar_header_rows;
    // Sidebar has no independent scroll state; derive the visible window
    // from the selected row each frame.
    const range = loaded.sidebarVisibleRange(app.page.viewer.selected_node, visible_rows);
    var row: u16 = review_layout.sidebar_header_rows;
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
        }, visible_index, app.page.viewer.selected_node) orelse continue;
        const cursor_active = app.page.viewer.focus == .sidebar and !app.page.file_search.mode;
        try drawSidebarRow(surface, row, row_model, cursor_active, app.page.viewer.sidebar_horizontal_scroll, app.theme);
    }
}

fn drawSidebarDetailRow(app: Context, surface: *chasen.Surface, row: u16) !void {
    const size = surface.size();
    if (size.width <= 2 or row >= size.height) return;

    if (app.page.review_display.hide_reviewed_files and app.page.review_display.changed_file_filter != .all) {
        const text = try std.fmt.allocPrint(surface.frameAllocator(), "hiding reviewed / {s}", .{app.page.review_display.changed_file_filter.label()});
        try draw.copyClippedTextAt(surface, 1, row, text, app.theme.style(.prompt));
        return;
    }
    if (app.page.review_display.hide_reviewed_files) {
        try draw.copyClippedTextAt(surface, 1, row, "hiding reviewed", app.theme.style(.prompt));
        return;
    }
    if (app.page.review_display.changed_file_filter != .all) {
        try draw.copyClippedTextAt(surface, 1, row, app.page.review_display.changed_file_filter.label(), app.theme.style(.prompt));
        return;
    }

    const available_width = size.width - 1;
    if (branchStatusSidebarPresentation(app.page, app.repo_root, surface.frameAllocator(), available_width)) |presentation| {
        try draw.copyClippedTextAt(surface, 1, row, presentation.text, sidebarBranchStyle(app.theme));

        if (reviewBranchActionHintInputReachable(app.page)) {
            var push_key_buffer: [16]u8 = undefined;
            const push_key = app.keymap.display(.push, push_key_buffer[0..]);
            var pull_key_buffer: [16]u8 = undefined;
            const pull_key = app.keymap.display(.pull, pull_key_buffer[0..]);
            var hint_buffer: [64]u8 = undefined;
            if (reviewBranchActionHintForKeys(presentation, available_width, push_key, pull_key, hint_buffer[0..])) |hint| {
                const hint_col = 1 + hint.base_display_width;
                try draw.copyClippedTextAt(surface, hint_col, row, hint.text, sidebarBranchHintStyle(app.theme));
            }
        }
    }
}

fn drawSidebarRow(surface: *chasen.Surface, row: u16, row_model: sidebar_view_model.Row, cursor_active: bool, horizontal_scroll: usize, palette: theme.Palette) !void {
    const width = surface.size().width;
    const row_layout = sidebar_view_model.layout(row_model, width);
    const cursor_bg: ?chasen.Color = if (cursor_active and row_model.selected) palette.color(.pane_cursor_bg) else null;
    const style = withCursorBackground(sidebarRowStyle(row_model, palette), cursor_bg);

    // Cursor chrome is a row-level concern, separate from path/badge Git
    // semantics. Fill first so trailing cells share the same signal, then
    // compose the same background into every semantic cell written below.
    if (cursor_bg != null) fillSidebarCursorRow(surface, row, style);

    if (row_model.status) |status| {
        if (row_layout.badge_col) |badge_col| {
            if (width > badge_col) {
                _ = surface.borrowTextAt(badge_col, row, status.badge(), statusStyle(row_model, status, palette, cursor_bg));
            }
        }
    }

    if (row_layout.mode_col) |mode_col| {
        if (width > mode_col) {
            _ = surface.borrowTextAt(mode_col, row, "m", modeBadgeStyle(palette, cursor_bg));
        }
    }

    if (row_layout.reviewed_col) |reviewed_col| {
        if (width > reviewed_col) {
            _ = surface.borrowTextAt(reviewed_col, row, "✓", reviewedStyle(palette, cursor_bg));
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
        const visible = chasen.text.dropToWidth(content, view_primitives.scrollCells(effective_scroll));
        try draw.copyClippedTextAt(&path_area, 0, 0, visible, style);
    }

    if (row_layout.stats_col) |stats_col| {
        var stats_area = surface.child(.{
            .col = stats_col,
            .row = row,
            .width = row_layout.stats_width,
            .height = 1,
        });
        try drawSidebarStats(&stats_area, row_model, palette, cursor_bg);
    }
}

fn fillSidebarCursorRow(surface: *chasen.Surface, row: u16, style: chasen.TextStyle) void {
    for (0..surface.size().width) |col| {
        _ = surface.borrowTextAt(@intCast(col), row, " ", style);
    }
}

fn drawSidebarStats(surface: *chasen.Surface, row: sidebar_view_model.Row, palette: theme.Palette, cursor_bg: ?chasen.Color) !void {
    const added_text = try std.fmt.allocPrint(surface.frameAllocator(), "+{d}", .{row.stats.added});
    const removed_text = try std.fmt.allocPrint(surface.frameAllocator(), "-{d}", .{row.stats.removed});
    const added_style = sidebarStatStyle(palette.color(.success), cursor_bg);
    const removed_style = sidebarStatStyle(palette.color(.danger), cursor_bg);

    try draw.copyClippedTextAt(surface, 0, 0, added_text, added_style);
    const removed_col = chasen.text.displayWidth(added_text) + 1;
    if (removed_col < surface.size().width) {
        try draw.copyClippedTextAt(surface, removed_col, 0, removed_text, removed_style);
    }
}

fn sidebarStatStyle(fg: chasen.Color, cursor_bg: ?chasen.Color) chasen.TextStyle {
    return withCursorBackground(.{
        .fg = fg,
        .bold = true,
    }, cursor_bg);
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

fn sidebarRowStyle(row: sidebar_view_model.Row, palette: theme.Palette) chasen.TextStyle {
    var style: chasen.TextStyle = if (row.kind == .directory or row.kind == .repo_root)
        .{ .bold = true }
    else switch (row.stage_presence) {
        .staged_only => .{ .fg = palette.color(.staged) },
        .mixed => .{ .fg = palette.color(.prompt) },
        .conflict => .{ .fg = palette.color(.danger), .bold = true },
        else => .{},
    };
    if (row.selected) style.bold = true;
    return style;
}

/// Draw the selected file's diff pane.
///
/// Diff rows are already backed by rendered-line indexes in LoadedDiff; this
/// layer only chooses the visible file, mode, and current scroll offset.
pub fn viewDiffPane(app: Context, surface: *chasen.Surface, loaded: loaded_diff.LoadedDiff) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    if (app.selectedStatusEntry()) |entry| {
        try viewStatusOnlyPane(app, surface, entry);
        return;
    }

    if (loaded.document.files.len == 0) {
        _ = surface.borrowTextAt(0, 0, "No parsed files.", app.theme.style(.muted));
        return;
    }

    var diff_content = diffContentSurface(surface);
    const mode = diff_render.effectiveMode(diff_render.bodyWidth(diff_content.size().width), app.page.viewer.display_mode);
    const active = app.page.viewer.sidebar_hidden or app.page.viewer.focus == .diff;
    if (app.displayedReviewBody() == .inert_invalid_utf8) {
        const inert = app.displayedReviewBody().inert_invalid_utf8;
        try review_body_render.renderStatus(
            inert.display_path,
            review_navigation.invalid_utf8_body_message,
            null,
            projectedBodyRenderArgs(app, &diff_content, active),
        );
        drawPaneHeaderRule(surface, active, app.theme);
        return;
    }
    const display = (try app.activeDiffDisplay(surface.frameAllocator(), mode)) orelse return;
    const display_file = display.file();
    try diff_render.renderFile(&diff_content, display_file, .{
        .requested_mode = app.page.viewer.display_mode,
        .scroll = app.page.viewer.diff_scroll,
        .horizontal_scroll = app.page.viewer.diff_horizontal_scroll,
        .pane_active = active,
        .line_numbers = app.page.viewer.view_options.line_numbers,
        .highlighted_hunk = app.selectedHunkIndex(),
        .cursor_offset = app.visibleDiffCursorOffset(),
        .hunk_stages = display.hunkStagePresentation(),
        .line_index = display.lineIndex(),
        .folded_hunks = display.foldedHunks(),
        .palette = app.theme,
        .syntax = display.syntaxView(),
        .selection = app.diffSelectionView(),
        .header_selection = app.diffHeaderSelectionActive(),
    });
    drawDiffHeaderDetailRow(app, surface, active);
    drawSearchMatchMarker(app, surface);
}

fn drawDiffHeaderDetailRow(app: Context, surface: *chasen.Surface, active: bool) void {
    const size = surface.size();
    if (size.width == 0 or size.height <= 1) return;

    surface.clear(.{ .col = 0, .row = 1, .width = size.width, .height = 1 });
    if (!app.page.search.mode and app.page.search.query.len > 0) {
        const label_col: u16 = 1;
        const match_text = if (app.page.search.match_offset) |offset|
            std.fmt.allocPrint(surface.frameAllocator(), "search: {s} @ {d}", .{ app.page.search.query.slice(), offset + 1 }) catch "search"
        else
            std.fmt.allocPrint(surface.frameAllocator(), "search: {s} (no match)", .{app.page.search.query.slice()}) catch "search";
        draw.copyClippedTextAt(surface, label_col, 1, match_text, paneSearchStyle(active, app.theme)) catch {};
        return;
    }

    if (app.page.search.mode) {
        const label = "search: ";
        const label_col: u16 = 1;
        const style = paneSearchStyle(active, app.theme);
        draw.copyClippedTextAt(surface, label_col, 1, label, style) catch {};
        if (size.width > label_col + label.len) {
            const input_col: u16 = label_col + @as(u16, @intCast(label.len));
            drawInputLine(surface, input_col, 1, app.page.search.input.slice(), app.page.search.input.cursor, style) catch {};
            view_primitives.showInputCursor(surface, input_col, 1, app.page.search.input.slice(), app.page.search.input.cursor);
        }
        return;
    }

    drawPaneHeaderRule(surface, active, app.theme);
}

fn drawInputLine(surface: *chasen.Surface, col: u16, row: u16, text: []const u8, cursor: usize, style: chasen.TextStyle) !void {
    const size = surface.size();
    if (col >= size.width or row >= size.height) return;
    const width = size.width - col;
    try draw.copyClippedTextAt(surface, col, row, text[view_primitives.inputVisibleStart(text, cursor, width)..], style);
}

fn viewStatusOnlyPane(app: Context, surface: *chasen.Surface, entry: git_status.StatusEntry) !void {
    const active = app.page.viewer.sidebar_hidden or app.page.viewer.focus == .diff;

    var content = diffContentSurface(surface);
    const path = entry.canonicalPathKey() orelse entry.path;

    switch (app.displayedReviewBody()) {
        .cached => |bundle| {
            try review_body_render.renderParsed(.{
                .file = bundle.loaded.document.files[0],
                .line_index = bundle.loaded.cachedRenderedLineIndex(0, diff_render.effectiveMode(diff_render.bodyWidth(content.size().width), app.page.viewer.display_mode)),
                .folded_hunks = &.{},
                .hunk_stages = .all_staged,
                .syntax = .initDirect(&bundle.loaded.syntax_spans, 0),
            }, projectedBodyRenderArgs(app, &content, active));
            drawPaneHeaderRule(surface, active, app.theme);
            return;
        },
        .combined => |bundle| {
            try review_body_render.renderParsed(.{
                .file = bundle.displayFile(),
                .line_index = bundle.displayLineIndex(diff_render.effectiveMode(diff_render.bodyWidth(content.size().width), app.page.viewer.display_mode)),
                .folded_hunks = &.{},
                .hunk_stages = try review_navigation.projectedHunkStagePresentation(surface.frameAllocator(), bundle.hunkStageStates()),
                .syntax = bundle.syntaxView(),
            }, projectedBodyRenderArgs(app, &content, active));
            drawPaneHeaderRule(surface, active, app.theme);
            return;
        },
        .retained_staged_only => |bundle| {
            try review_body_render.renderParsed(.{
                .file = bundle.displayFile(),
                .line_index = bundle.displayLineIndex(diff_render.effectiveMode(diff_render.bodyWidth(content.size().width), app.page.viewer.display_mode)),
                .folded_hunks = &.{},
                .hunk_stages = .all_staged,
                .syntax = bundle.syntaxView(),
            }, projectedBodyRenderArgs(app, &content, active));
            drawPaneHeaderRule(surface, active, app.theme);
            return;
        },
        .generated => |bundle| {
            try review_body_render.renderGenerated(bundle, projectedBodyRenderArgs(app, &content, active));
            drawPaneHeaderRule(surface, active, app.theme);
            return;
        },
        .inert_invalid_utf8 => |inert| {
            try review_body_render.renderStatus(inert.display_path, review_navigation.invalid_utf8_body_message, app.selectedStatusLineStats(), projectedBodyRenderArgs(app, &content, active));
            drawPaneHeaderRule(surface, active, app.theme);
            return;
        },
        .status => |status| {
            try review_body_render.renderStatus(status.path, status.message, app.selectedStatusLineStats(), projectedBodyRenderArgs(app, &content, active));
            drawPaneHeaderRule(surface, active, app.theme);
            return;
        },
        .pending => {
            try review_body_render.renderStatus(path, "Loading review projection...", app.selectedStatusLineStats(), projectedBodyRenderArgs(app, &content, active));
            drawPaneHeaderRule(surface, active, app.theme);
            return;
        },
        .none, .primary => {},
    }

    try review_body_render.renderStatusOnlyFallback(&content, entry, app.selectedStatusLineStats(), active, app.theme);
}

fn projectedBodyRenderArgs(app: Context, surface: *chasen.Surface, active: bool) @import("../../diff_surface.zig").RenderProjectedBodyArgs {
    return .{
        .surface = surface,
        .requested_mode = app.page.viewer.display_mode,
        .scroll = app.page.viewer.diff_scroll,
        .horizontal_scroll = app.page.viewer.diff_horizontal_scroll,
        .pane_active = active,
        .line_numbers = app.page.viewer.view_options.line_numbers,
        .highlighted_hunk = app.selectedHunkIndex(),
        .cursor_offset = app.visibleDiffCursorOffset(),
        .palette = app.theme,
        .selection = app.diffSelectionView(),
        .header_selection = app.diffHeaderSelectionActive(),
    };
}

fn drawPaneHeaderRule(surface: *chasen.Surface, active: bool, palette: theme.Palette) void {
    const size = surface.size();
    if (size.width == 0 or size.height <= 1) return;

    for (0..size.width) |col| {
        _ = surface.borrowTextAt(@intCast(col), 1, "─", paneHeaderRuleStyle(active, palette));
    }
}

fn drawStatusBody(surface: *chasen.Surface, path: []const u8, message: []const u8, stats: ?file_tree.Stats, active: bool, palette: theme.Palette) !void {
    try review_body_render.renderStatus(path, message, stats, .{
        .surface = surface,
        .requested_mode = .unified,
        .scroll = 0,
        .horizontal_scroll = 0,
        .pane_active = active,
        .line_numbers = true,
        .highlighted_hunk = null,
        .cursor_offset = null,
        .palette = palette,
        .selection = null,
        .header_selection = false,
    });
}

fn viewLoadState(app: Context, col: *chasen.Column) void {
    switch (app.page.load.state) {
        .idle => drawStateMessageColumn(col, .{
            .title = "Waiting to load diff",
            .body = "GitFrame is waiting for a load request.",
            .hint = "Press q to quit.",
        }, app.theme),
        .loading => drawStateMessageColumn(col, .{
            .title = "Loading diff",
            .body = "Reading and parsing the current source.",
            .hint = "Press q to quit.",
            .tone = .loading,
        }, app.theme),
        .empty => |reason| drawStateMessageColumn(col, emptyLoadMessage(reason), app.theme),
        .failed => |failed| drawStateMessageColumn(col, .{
            .title = "Could not load diff",
            .body = firstLine(failed.message),
            .hint = "Press r to retry or q to quit.",
            .tone = .failure,
        }, app.theme),
        .loaded => {},
    }
}

fn emptyLoadMessage(reason: app_load_state.EmptyReason) StateMessage {
    return switch (reason) {
        .no_changes => .{
            // Normal no-changes rendering is intercepted by `viewNoChanges` so
            // clean repos can keep branch chrome. Keep this fallback for any
            // future generic empty-state path.
            .title = "No changes",
            .body = "Working tree has no diff for the current source.",
            .hint = "Press r to reload or q to quit.",
        },
        .no_repository => .{
            .title = "No Git repository",
            .body = "Run GitFrame inside a repository or a workspace containing direct child repositories.",
            .hint = "Press q to quit.",
            .tone = .warning,
        },
    };
}

fn noChangesMessage(app: Context, allocator: std.mem.Allocator) StateMessage {
    return .{
        .title = "No changes",
        .body = "Working tree has no diff for the current source.",
        .hint = noChangesHint(app, allocator),
    };
}

fn noChangesHint(app: Context, allocator: std.mem.Allocator) []const u8 {
    var fetch_key_buffer: [16]u8 = undefined;
    const hints = app.empty_remote_hints;
    const fetch_key = if (hints.show_fetch) app.keymap.display(.fetch, fetch_key_buffer[0..]) else null;

    // The hint is capability-oriented: `U` refreshes first and may legitimately
    // finish as "nothing to pull", so the text advertises the workflow rather
    // than predicting remote state from a possibly stale ahead/behind count.
    if (hints.show_repo_picker and hints.show_pull and fetch_key != null) {
        return std.fmt.allocPrint(allocator, "Press R to switch repository, U to fetch + fast-forward, {s} to fetch, r to reload, or q to quit.", .{fetch_key.?}) catch "Press R to switch repository, U to fetch + fast-forward, r to reload, or q to quit.";
    }
    if (hints.show_repo_picker and hints.show_pull) {
        return "Press R to switch repository, U to fetch + fast-forward, r to reload, or q to quit.";
    }
    if (hints.show_repo_picker and fetch_key != null) {
        return std.fmt.allocPrint(allocator, "Press R to switch repository, {s} to fetch, r to reload, or q to quit.", .{fetch_key.?}) catch "Press R to switch repository, r to reload, or q to quit.";
    }
    if (hints.show_repo_picker) {
        return "Press R to switch repository, r to reload, or q to quit.";
    }
    if (hints.show_pull and fetch_key != null) {
        return std.fmt.allocPrint(allocator, "Press U to fetch + fast-forward, {s} to fetch, r to reload, or q to quit.", .{fetch_key.?}) catch "Press U to fetch + fast-forward, r to reload, or q to quit.";
    }
    if (hints.show_pull) {
        return "Press U to fetch + fast-forward, r to reload, or q to quit.";
    }
    if (fetch_key != null) {
        return std.fmt.allocPrint(allocator, "Press {s} to fetch, r to reload, or q to quit.", .{fetch_key.?}) catch "Press r to reload or q to quit.";
    }
    return "Press r to reload or q to quit.";
}

fn filterEmptyMessage(app: Context) StateMessage {
    const hint = if (app.page.review_display.hide_reviewed_files and app.page.review_display.changed_file_filter != .all)
        "Press F to change filter, H to show reviewed files, or r to reload."
    else if (app.page.review_display.hide_reviewed_files)
        "Press H to show reviewed files or r to reload."
    else if (app.page.review_display.changed_file_filter != .all)
        "Press F to change filter or r to reload."
    else
        "Press r to reload.";

    return .{
        .title = "No files match current filters",
        .body = "The diff is loaded, but the current sidebar filters hide every file.",
        .hint = hint,
    };
}

fn drawStateMessage(surface: *chasen.Surface, message: StateMessage, palette: theme.Palette) void {
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
    drawStateMessageColumn(&col, message, palette);
}

fn drawStateMessageColumn(col: *chasen.Column, message: StateMessage, palette: theme.Palette) void {
    col.borrowText(message.title, stateTitleStyle(message.tone, palette));
    if (message.body.len > 0) col.borrowText(message.body, stateBodyStyle(message.tone, palette));
    if (message.hint.len > 0) col.borrowText(message.hint, stateHintStyle(palette));
}

fn stateTitleStyle(tone: StateTone, palette: theme.Palette) chasen.TextStyle {
    return switch (tone) {
        .muted => palette.boldStyle(.muted),
        .loading => palette.boldStyle(.prompt),
        .warning => palette.boldStyle(.warning),
        .failure => palette.boldStyle(.danger),
    };
}

fn stateBodyStyle(tone: StateTone, palette: theme.Palette) chasen.TextStyle {
    return switch (tone) {
        .failure => palette.style(.danger),
        else => palette.style(.muted),
    };
}

fn stateHintStyle(palette: theme.Palette) chasen.TextStyle {
    return .{ .fg = palette.color(.muted), .dim = true };
}

fn firstLine(text: []const u8) []const u8 {
    if (std.mem.indexOfAny(u8, text, "\r\n")) |end| return text[0..end];
    return text;
}

const SidebarBranchPresentation = struct {
    text: []const u8,
    full_display_width: ?u16 = null,
    was_clipped: bool = false,
    action_hints: ActionHints = .{},

    const ActionHints = struct {
        push: bool = false,
        pull: bool = false,
    };
};

const ReviewBranchActionHint = struct {
    text: []const u8,
    base_display_width: u16,
};

fn branchStatusSidebarPresentation(page: *const review_page.ReviewPageState, repo_root: ?[]const u8, allocator: std.mem.Allocator, available_width: u16) ?SidebarBranchPresentation {
    const root = repo_root orelse return null;
    if (page.branch_status_load.pending) |pending| {
        const has_retained_snapshot = if (page.branch_status.repo_root) |snapshot_root|
            std.mem.eql(u8, root, snapshot_root)
        else
            false;
        if (pending.origin == .foreground or !has_retained_snapshot) return .{ .text = "loading branch" };
    }

    const snapshot_root = page.branch_status.repo_root orelse return null;
    if (!std.mem.eql(u8, root, snapshot_root)) return null;

    const formatted = branch_chrome.formatBaseLabel(allocator, page.branch_status.status, available_width) catch return .{ .text = "branch" };
    return .{
        // The caller-provided frame/testing allocator owns this transferred
        // text for the same lifetime as the returned presentation.
        .text = formatted.text,
        .full_display_width = formatted.full_display_width,
        .was_clipped = formatted.was_clipped,
        .action_hints = branchStatusActionHints(page.branch_status.status),
    };
}

fn branchStatusActionHints(status: git_branch_status.BranchStatus) SidebarBranchPresentation.ActionHints {
    return switch (status.head) {
        .branch => .{
            .push = true,
            .pull = if (status.upstream) |upstream| upstream.remote_branch.len > 0 else false,
        },
        .detached, .unknown => .{},
    };
}

/// Text-input modes consume keys before Review's normal action route. Keep the
/// branch fact visible, but do not advertise a shortcut that cannot currently
/// reach the existing push or pull command.
fn reviewBranchActionHintInputReachable(page: *const review_page.ReviewPageState) bool {
    return !page.search.mode and !page.file_search.mode;
}

/// Compose discoverability chrome only when it fits after an unclipped base.
/// The existing key/input and Review operation paths remain the sole action
/// authority; this helper uses only stable branch topology and bound keys.
fn reviewBranchActionHintForKeys(
    presentation: SidebarBranchPresentation,
    available_width: u16,
    push_key: ?[]const u8,
    pull_key: ?[]const u8,
    buffer: []u8,
) ?ReviewBranchActionHint {
    if (presentation.was_clipped) return null;
    const base_width = presentation.full_display_width orelse return null;
    if (base_width > available_width) return null;

    const push = eligibleActionKey(presentation.action_hints.push, push_key);
    const pull = eligibleActionKey(presentation.action_hints.pull, pull_key);

    if (push) |push_label| {
        if (pull) |pull_label| {
            if (reviewBranchActionHintCandidate(
                base_width,
                available_width,
                buffer,
                "  ({s}: push / {s}: pull)",
                .{ push_label, pull_label },
            )) |hint| return hint;
        }
        return reviewBranchActionHintCandidate(
            base_width,
            available_width,
            buffer,
            "  ({s}: push)",
            .{push_label},
        );
    }
    if (pull) |pull_label| {
        return reviewBranchActionHintCandidate(
            base_width,
            available_width,
            buffer,
            "  ({s}: pull)",
            .{pull_label},
        );
    }
    return null;
}

fn eligibleActionKey(eligible: bool, key: ?[]const u8) ?[]const u8 {
    if (!eligible) return null;
    const bound_key = key orelse return null;
    if (bound_key.len == 0) return null;
    return bound_key;
}

fn reviewBranchActionHintCandidate(
    base_width: u16,
    available_width: u16,
    buffer: []u8,
    comptime format: []const u8,
    args: anytype,
) ?ReviewBranchActionHint {
    const hint = std.fmt.bufPrint(buffer, format, args) catch return null;
    if (chasen.text.displayWidth(hint) > available_width - base_width) return null;
    return .{ .text = hint, .base_display_width = base_width };
}

test "branch sidebar retains background snapshot but shows foreground loading" {
    var builder = git_branch_status.Builder.init(std.testing.allocator);
    errdefer builder.deinit();
    try builder.setBranchHead("main");
    var bundle = builder.finish();
    var branch_status: git_branch_status.State = .{};
    try branch_status.replace("/repo", &bundle);

    var page_state: review_page.ReviewPageState = .{
        .branch_status = branch_status,
        .branch_status_load = .{
            .generation = 1,
            .pending = .{ .generation = 1, .origin = .background, .background_cycle_id = 1 },
            .freshness = .stale_refresh,
        },
    };
    defer page_state.branch_status.deinit();

    const retained = branchStatusSidebarPresentation(&page_state, "/repo", std.testing.allocator, 80).?;
    defer std.testing.allocator.free(retained.text);
    try std.testing.expectEqualStrings("main no upstream", retained.text);
    try std.testing.expect(retained.action_hints.push);
    try std.testing.expect(!retained.action_hints.pull);

    page_state.branch_status_load.pending.?.origin = .foreground;
    const loading = branchStatusSidebarPresentation(&page_state, "/repo", std.testing.allocator, 80).?;
    try std.testing.expectEqualStrings("loading branch", loading.text);
    try std.testing.expect(!loading.action_hints.push);
    try std.testing.expect(!loading.action_hints.pull);
}

test "review branch action hint renders effective keys with Files stats style" {
    var builder = git_branch_status.Builder.init(std.testing.allocator);
    errdefer builder.deinit();
    try builder.setBranchHead("main");
    try builder.setUpstream("origin/main");
    builder.setAheadBehind(0, 0);
    var bundle = builder.finish();
    var branch_status: git_branch_status.State = .{};
    try branch_status.replace("/repo", &bundle);

    var page_state: review_page.ReviewPageState = .{ .branch_status = branch_status };
    defer page_state.branch_status.deinit();
    var palette: theme.Palette = .default();
    palette.colors[@intFromEnum(theme.Role.info)] = .{ .rgb = .{ 1, 2, 3 } };
    palette.colors[@intFromEnum(theme.Role.muted)] = .{ .rgb = .{ 4, 5, 6 } };

    var context = testContext(&page_state, palette, 48, 4);
    context.repo_root = "/repo";
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(48, 1);
    defer ts.deinit();

    try drawSidebarDetailRow(context, &ts.surface, 0);
    const default_snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(default_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, default_snapshot, "main ↑0  (P: push / U: pull)") != null);

    const base_cell = ts.surface.readCell(1, 0) orelse return error.ExpectedBranchBaseCell;
    const hint_cell = ts.surface.readCell(10, 0) orelse return error.ExpectedBranchHintCell;
    try std.testing.expect(base_cell.style.fg.eql(palette.color(.info)));
    try std.testing.expect(!base_cell.style.dim);
    try std.testing.expect(hint_cell.style.eql(palette.style(.muted)));
    try std.testing.expect(!hint_cell.style.dim);

    var config: keymap.Config = .{};
    config.set(.push, .{ .ctrl = .s });
    config.set(.pull, .{ .ctrl = .q });
    context.keymap = keymap.Effective.fromConfig(config);
    ts.surface.clearAll();
    try drawSidebarDetailRow(context, &ts.surface, 0);
    const configured_snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(configured_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, configured_snapshot, "main ↑0  (Ctrl+s: push / Ctrl+q: pull)") != null);

    var pull_unbound: keymap.Effective = .{};
    pull_unbound.bindings[@intFromEnum(keymap.PublicAction.pull)] = null;
    context.keymap = pull_unbound;
    ts.surface.clearAll();
    try drawSidebarDetailRow(context, &ts.surface, 0);
    const pull_unbound_snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(pull_unbound_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, pull_unbound_snapshot, "main ↑0  (P: push)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pull_unbound_snapshot, ": pull)") == null);

    var push_unbound: keymap.Effective = .{};
    push_unbound.bindings[@intFromEnum(keymap.PublicAction.push)] = null;
    context.keymap = push_unbound;
    ts.surface.clearAll();
    try drawSidebarDetailRow(context, &ts.surface, 0);
    const push_unbound_snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(push_unbound_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, push_unbound_snapshot, "main ↑0  (U: pull)") != null);
    try std.testing.expect(std.mem.indexOf(u8, push_unbound_snapshot, ": push") == null);

    push_unbound.bindings[@intFromEnum(keymap.PublicAction.pull)] = null;
    context.keymap = push_unbound;
    ts.surface.clearAll();
    try drawSidebarDetailRow(context, &ts.surface, 0);
    const both_unbound_snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(both_unbound_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, both_unbound_snapshot, "main ↑0") != null);
    try std.testing.expect(std.mem.indexOf(u8, both_unbound_snapshot, ": push") == null);
    try std.testing.expect(std.mem.indexOf(u8, both_unbound_snapshot, ": pull") == null);
}

test "review branch action hint follows text input authority" {
    var builder = git_branch_status.Builder.init(std.testing.allocator);
    errdefer builder.deinit();
    try builder.setBranchHead("main");
    try builder.setUpstream("origin/main");
    builder.setAheadBehind(0, 0);
    var bundle = builder.finish();
    var branch_status: git_branch_status.State = .{};
    try branch_status.replace("/repo", &bundle);

    var page_state: review_page.ReviewPageState = .{ .branch_status = branch_status };
    defer page_state.branch_status.deinit();
    var context = testContext(&page_state, .default(), 48, 4);
    context.repo_root = "/repo";
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(48, 1);
    defer ts.deinit();

    try drawSidebarDetailRow(context, &ts.surface, 0);
    const normal_before = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(normal_before);
    try std.testing.expect(std.mem.indexOf(u8, normal_before, "main ↑0  (P: push / U: pull)") != null);

    page_state.file_search.mode = true;
    ts.surface.clearAll();
    try drawSidebarDetailRow(context, &ts.surface, 0);
    const file_search = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(file_search);
    try std.testing.expect(std.mem.indexOf(u8, file_search, "main ↑0") != null);
    try std.testing.expect(std.mem.indexOf(u8, file_search, ": push") == null);
    try std.testing.expect(std.mem.indexOf(u8, file_search, ": pull") == null);

    page_state.file_search.mode = false;
    page_state.search.mode = true;
    ts.surface.clearAll();
    try drawSidebarDetailRow(context, &ts.surface, 0);
    const diff_search = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(diff_search);
    try std.testing.expect(std.mem.indexOf(u8, diff_search, "main ↑0") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff_search, ": push") == null);
    try std.testing.expect(std.mem.indexOf(u8, diff_search, ": pull") == null);

    page_state.search.mode = false;
    ts.surface.clearAll();
    try drawSidebarDetailRow(context, &ts.surface, 0);
    const normal_after = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(normal_after);
    try std.testing.expect(std.mem.indexOf(u8, normal_after, "main ↑0  (P: push / U: pull)") != null);
}

test "review branch action hint follows topology and width fallback" {
    const upstream_status: git_branch_status.BranchStatus = .{
        .head = .{ .branch = "main" },
        .upstream = .{ .name = "origin/main", .remote = "origin", .remote_branch = "main" },
        .ahead_behind = .{},
    };
    var formatted = try branch_chrome.formatBaseLabel(std.testing.allocator, upstream_status, 80);
    defer formatted.deinit(std.testing.allocator);
    const presentation: SidebarBranchPresentation = .{
        .text = formatted.text,
        .full_display_width = formatted.full_display_width,
        .was_clipped = formatted.was_clipped,
        .action_hints = branchStatusActionHints(upstream_status),
    };
    try std.testing.expect(presentation.action_hints.push);
    try std.testing.expect(presentation.action_hints.pull);

    const full_hint_width = chasen.text.displayWidth("  (P: push / U: pull)");
    const push_hint_width = chasen.text.displayWidth("  (P: push)");
    const pull_hint_width = chasen.text.displayWidth("  (U: pull)");
    const full_exact_width = presentation.full_display_width.? + full_hint_width;
    const push_exact_width = presentation.full_display_width.? + push_hint_width;
    const pull_exact_width = presentation.full_display_width.? + pull_hint_width;
    var hint_buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "  (P: push / U: pull)",
        reviewBranchActionHintForKeys(presentation, full_exact_width, "P", "U", hint_buffer[0..]).?.text,
    );
    try std.testing.expectEqualStrings(
        "  (P: push)",
        reviewBranchActionHintForKeys(presentation, full_exact_width - 1, "P", "U", hint_buffer[0..]).?.text,
    );
    try std.testing.expectEqualStrings(
        "  (P: push)",
        reviewBranchActionHintForKeys(presentation, push_exact_width, "P", "U", hint_buffer[0..]).?.text,
    );
    try std.testing.expect(reviewBranchActionHintForKeys(presentation, push_exact_width - 1, "P", "U", hint_buffer[0..]) == null);
    try std.testing.expectEqualStrings(
        "  (U: pull)",
        reviewBranchActionHintForKeys(presentation, pull_exact_width, null, "U", hint_buffer[0..]).?.text,
    );
    try std.testing.expectEqualStrings(
        "  (P: push)",
        reviewBranchActionHintForKeys(presentation, push_exact_width, "P", null, hint_buffer[0..]).?.text,
    );
    try std.testing.expect(reviewBranchActionHintForKeys(presentation, full_exact_width, null, null, hint_buffer[0..]) == null);

    const no_upstream_status: git_branch_status.BranchStatus = .{ .head = .{ .branch = "main" } };
    const no_upstream_hints = branchStatusActionHints(no_upstream_status);
    try std.testing.expect(no_upstream_hints.push);
    try std.testing.expect(!no_upstream_hints.pull);

    var no_upstream_formatted = try branch_chrome.formatBaseLabel(std.testing.allocator, no_upstream_status, 80);
    defer no_upstream_formatted.deinit(std.testing.allocator);
    const no_upstream_presentation: SidebarBranchPresentation = .{
        .text = no_upstream_formatted.text,
        .full_display_width = no_upstream_formatted.full_display_width,
        .was_clipped = no_upstream_formatted.was_clipped,
        .action_hints = no_upstream_hints,
    };
    try std.testing.expectEqualStrings(
        "  (P: push)",
        reviewBranchActionHintForKeys(no_upstream_presentation, 80, "P", "U", hint_buffer[0..]).?.text,
    );

    const malformed_upstream_status: git_branch_status.BranchStatus = .{
        .head = .{ .branch = "main" },
        .upstream = .{ .name = "origin", .remote = "origin", .remote_branch = "" },
    };
    const malformed_upstream_hints = branchStatusActionHints(malformed_upstream_status);
    try std.testing.expect(malformed_upstream_hints.push);
    try std.testing.expect(!malformed_upstream_hints.pull);

    var malformed_upstream_formatted = try branch_chrome.formatBaseLabel(std.testing.allocator, malformed_upstream_status, 80);
    defer malformed_upstream_formatted.deinit(std.testing.allocator);
    const malformed_upstream_presentation: SidebarBranchPresentation = .{
        .text = malformed_upstream_formatted.text,
        .full_display_width = malformed_upstream_formatted.full_display_width,
        .was_clipped = malformed_upstream_formatted.was_clipped,
        .action_hints = malformed_upstream_hints,
    };
    try std.testing.expectEqualStrings(
        "  (P: push)",
        reviewBranchActionHintForKeys(malformed_upstream_presentation, 80, "P", "U", hint_buffer[0..]).?.text,
    );
}

test "review branch action hint drops before base clipping and omits non-branch terminals" {
    const upstream_status: git_branch_status.BranchStatus = .{
        .head = .{ .branch = "main" },
        .upstream = .{ .name = "origin/main", .remote = "origin", .remote_branch = "main" },
        .ahead_behind = .{},
    };
    var formatted = try branch_chrome.formatBaseLabel(std.testing.allocator, upstream_status, 80);
    defer formatted.deinit(std.testing.allocator);
    var clipped = try branch_chrome.formatBaseLabel(std.testing.allocator, upstream_status, formatted.full_display_width - 1);
    defer clipped.deinit(std.testing.allocator);
    const clipped_presentation: SidebarBranchPresentation = .{
        .text = clipped.text,
        .full_display_width = clipped.full_display_width,
        .was_clipped = clipped.was_clipped,
        .action_hints = branchStatusActionHints(upstream_status),
    };
    try std.testing.expect(clipped_presentation.was_clipped);
    var hint_buffer: [64]u8 = undefined;
    try std.testing.expect(reviewBranchActionHintForKeys(
        clipped_presentation,
        formatted.full_display_width - 1,
        "P",
        "U",
        hint_buffer[0..],
    ) == null);

    const loading: SidebarBranchPresentation = .{ .text = "loading branch" };
    const detached: SidebarBranchPresentation = .{
        .text = "detached",
        .full_display_width = 8,
        .action_hints = branchStatusActionHints(.{ .head = .detached }),
    };
    const unknown: SidebarBranchPresentation = .{
        .text = "unknown branch",
        .full_display_width = 14,
        .action_hints = branchStatusActionHints(.{ .head = .unknown }),
    };
    try std.testing.expect(!detached.action_hints.push);
    try std.testing.expect(!detached.action_hints.pull);
    try std.testing.expect(!unknown.action_hints.push);
    try std.testing.expect(!unknown.action_hints.pull);
    try std.testing.expect(reviewBranchActionHintForKeys(loading, 80, "P", "U", hint_buffer[0..]) == null);
    try std.testing.expect(reviewBranchActionHintForKeys(detached, 80, "P", "U", hint_buffer[0..]) == null);
    try std.testing.expect(reviewBranchActionHintForKeys(unknown, 80, "P", "U", hint_buffer[0..]) == null);
}

test "review filter summary owns sidebar detail row over branch action hint" {
    var builder = git_branch_status.Builder.init(std.testing.allocator);
    errdefer builder.deinit();
    try builder.setBranchHead("main");
    try builder.setUpstream("origin/main");
    builder.setAheadBehind(0, 0);
    var bundle = builder.finish();
    var branch_status: git_branch_status.State = .{};
    try branch_status.replace("/repo", &bundle);

    var page_state: review_page.ReviewPageState = .{
        .branch_status = branch_status,
        .review_display = .{ .changed_file_filter = .modified },
    };
    defer page_state.branch_status.deinit();
    var context = testContext(&page_state, .default(), 48, 4);
    context.repo_root = "/repo";
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(48, 1);
    defer ts.deinit();

    try drawSidebarDetailRow(context, &ts.surface, 0);
    const snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "modified only") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "main ↑0") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, ": push") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, ": pull") == null);
}

pub fn drawSearchMatchMarker(app: Context, surface: *chasen.Surface) void {
    const match_offset = app.page.search.match_offset orelse return;
    if (match_offset < app.page.viewer.diff_scroll) return;

    const visible_offset = match_offset - app.page.viewer.diff_scroll;
    const body_rows = diff_render.visibleBodyRows(surface.size().height);
    if (visible_offset >= body_rows) return;

    const row: u16 = @intCast(review_layout.diff_body_start_row + visible_offset);
    _ = surface.borrowTextAt(0, row, "»", .{ .bold = true, .reverse = true, .fg = app.theme.color(.prompt) });
}

fn diffContentSurface(surface: *chasen.Surface) chasen.Surface {
    const size = surface.size();
    if (size.width <= review_layout.search_marker_gutter_width) {
        return surface.child(.{ .col = 0, .row = 0, .width = size.width, .height = size.height });
    }
    return surface.child(.{
        .col = review_layout.search_marker_gutter_width,
        .row = 0,
        .width = size.width - review_layout.search_marker_gutter_width,
        .height = size.height,
    });
}

fn withCursorBackground(style: chasen.TextStyle, cursor_bg: ?chasen.Color) chasen.TextStyle {
    var composed = style;
    if (cursor_bg) |background| composed.bg = background;
    return composed;
}

fn statusStyle(row: sidebar_view_model.Row, status: file_tree.Status, palette: theme.Palette, cursor_bg: ?chasen.Color) chasen.TextStyle {
    const fg: chasen.Color = switch (row.stage_presence) {
        .staged_only => palette.color(.staged),
        .mixed => palette.color(.prompt),
        .conflict => palette.color(.danger),
        else => switch (status) {
            .modified => palette.color(.prompt),
            .added => palette.color(.success),
            .deleted => palette.color(.danger),
            .renamed => palette.color(.accent),
            .binary => palette.color(.binary),
        },
    };
    return withCursorBackground(.{ .fg = fg, .bold = true }, cursor_bg);
}

fn reviewedStyle(palette: theme.Palette, cursor_bg: ?chasen.Color) chasen.TextStyle {
    return withCursorBackground(.{ .fg = palette.color(.success), .bold = true }, cursor_bg);
}

fn modeBadgeStyle(palette: theme.Palette, cursor_bg: ?chasen.Color) chasen.TextStyle {
    return withCursorBackground(.{ .fg = palette.color(.info), .bold = true }, cursor_bg);
}

fn sidebarTitleStyle(palette: theme.Palette) chasen.TextStyle {
    return palette.boldStyle(.accent);
}

fn sidebarBranchStyle(palette: theme.Palette) chasen.TextStyle {
    return palette.style(.info);
}

fn sidebarBranchHintStyle(palette: theme.Palette) chasen.TextStyle {
    return palette.style(.muted);
}

/// Selected-file identity is stable chrome rather than a pane-focus signal.
/// Focus remains visible through the row-1 rule and diff body cursor.
fn paneTitleStyle(palette: theme.Palette) chasen.TextStyle {
    return review_body_render.paneTitleStyle(palette);
}

fn paneSearchStyle(active: bool, palette: theme.Palette) chasen.TextStyle {
    return if (active)
        palette.boldStyle(.prompt)
    else
        palette.style(.prompt);
}

fn paneHeaderRuleStyle(active: bool, palette: theme.Palette) chasen.TextStyle {
    return if (active)
        .{ .dim = true }
    else
        .{ .fg = palette.color(.muted), .dim = true };
}

fn shellSeparatorStyle() chasen.TextStyle {
    return .{ .dim = true };
}

fn testContext(page: *const review_page.ReviewPageState, palette: theme.Palette, width: u16, height: u16) Context {
    const navigation: review_navigation.View = .{
        .page = page,
        .repo_root = null,
        .source = .unstaged,
        .layout = .{ .width = width, .height = height },
    };
    return Context.init(page, navigation, palette, .{}, "working tree", .unstaged, null, .{});
}

fn paletteWithOverride(role: theme.Role, color: theme.ColorValue) theme.Palette {
    const FakeConfig = struct {
        role: theme.Role,
        color: theme.ColorValue,

        pub fn get(self: @This(), requested: theme.Role) ?theme.ColorValue {
            if (requested == self.role) return self.color;
            return null;
        }
    };
    return theme.Palette.fromConfig(FakeConfig{ .role = role, .color = color });
}

test "review pane title stays stable while rule and search keep focus treatment" {
    var palette: theme.Palette = .default();
    palette.colors[@intFromEnum(theme.Role.accent)] = .{ .rgb = .{ 1, 2, 3 } };
    palette.colors[@intFromEnum(theme.Role.info)] = .{ .rgb = .{ 4, 5, 6 } };
    palette.colors[@intFromEnum(theme.Role.muted)] = .{ .rgb = .{ 7, 8, 9 } };
    palette.colors[@intFromEnum(theme.Role.prompt)] = .{ .rgb = .{ 10, 11, 12 } };

    const title = sidebarTitleStyle(palette);
    const branch = sidebarBranchStyle(palette);
    const inactive_diff_title = paneTitleStyle(palette);
    const active_rule = paneHeaderRuleStyle(true, palette);
    const inactive_rule = paneHeaderRuleStyle(false, palette);
    const active_search = paneSearchStyle(true, palette);
    const inactive_search = paneSearchStyle(false, palette);
    try std.testing.expect(title.fg.eql(palette.color(.accent)));
    try std.testing.expect(title.bold);
    try std.testing.expect(!title.dim);
    try std.testing.expect(branch.fg.eql(palette.color(.info)));
    try std.testing.expect(!branch.dim);
    try std.testing.expect(inactive_diff_title.fg.eql(palette.color(.accent)));
    try std.testing.expect(inactive_diff_title.bold);
    try std.testing.expect(!inactive_diff_title.dim);
    try std.testing.expect(active_rule.fg.eql(.default));
    try std.testing.expect(active_rule.dim);
    try std.testing.expect(inactive_rule.fg.eql(palette.color(.muted)));
    try std.testing.expect(inactive_rule.dim);
    try std.testing.expect(active_search.fg.eql(palette.color(.prompt)));
    try std.testing.expect(active_search.bold);
    try std.testing.expect(inactive_search.fg.eql(palette.color(.prompt)));
    try std.testing.expect(!inactive_search.bold);
}

test "review file search renders a bounded typed candidate window" {
    const allocator = std.testing.allocator;
    const basis: review_file_search.Basis = .{
        .repo_epoch = 1,
        .source_session_revision = 2,
        .accepted_sidebar_revision = 3,
    };
    const nodes = [_]file_tree.Node{
        .{ .kind = .file, .name = "alpha.zig", .path = "src/alpha.zig", .path_key = "src/alpha.zig", .depth = 1, .target = .{ .diff_file = 0 } },
        .{ .kind = .file, .name = "bravo.zig", .path = "src/bravo.zig", .path_key = "src/bravo.zig", .depth = 1, .target = .{ .diff_file = 1 } },
        .{ .kind = .file, .name = "charlie.zig", .path = "src/charlie.zig", .path_key = "src/charlie.zig", .depth = 1, .target = .{ .status_entry = 2 } },
    };
    const loaded: loaded_diff.LoadedDiff = .{
        .text = "",
        .document = .{ .files = &.{} },
        .file_text_eligibility = &.{},
        .tree = .{ .nodes = &nodes },
        .bytes = 0,
        .lines = 0,
    };

    var state: review_file_search.State = .{ .mode = true };
    defer state.deinit(allocator);
    try state.input.insertSlice("src/");
    var projection = try review_file_search.buildProjection(allocator, &loaded, "src/", .{ .basis = basis });
    var projection_live = true;
    defer if (projection_live) projection.deinit(allocator);
    state.publish(allocator, &projection);
    projection_live = false;
    state.move(1);
    state.move(1);

    var palette: theme.Palette = .default();
    palette.colors[@intFromEnum(theme.Role.prompt)] = .{ .rgb = .{ 1, 2, 3 } };
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(24, 4);
    defer ts.deinit();

    try drawFileSearch(&ts.surface, &state, palette);

    const snapshot = try ts.snapshot(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Find file: src/") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Enter: open") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "src/alpha.zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "src/bravo.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "src/charlie.zig") != null);
    const focused = ts.surface.readCell(1, 3) orelse return error.ExpectedFocusedSearchCandidate;
    try std.testing.expect(focused.style.fg.eql(palette.color(.prompt)));
    try std.testing.expect(focused.style.bold);
}

test "review file search renders unavailable and no-match terminals" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(48, 3);
    defer ts.deinit();

    const unavailable: review_file_search.State = .{ .mode = true };
    try drawFileSearch(&ts.surface, &unavailable, .default());
    var snapshot = try ts.snapshot(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "File list unavailable; wait or press Esc") != null);
    std.testing.allocator.free(snapshot);

    ts.surface.clearAll();
    const no_match: review_file_search.State = .{
        .mode = true,
        .basis = .{ .repo_epoch = 1, .source_session_revision = 1, .accepted_sidebar_revision = 1 },
        .projection_available = true,
        .no_match = true,
    };
    try drawFileSearch(&ts.surface, &no_match, .default());
    snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "No matching files") != null);
}

test "review file search keeps long ASCII and Unicode input cursor visible" {
    var state: review_file_search.State = .{ .mode = true };
    try state.input.insertSlice("abcdefghijklmnopqrstuvwxyz");

    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(18, 3);
    defer ts.deinit();

    try drawFileSearch(&ts.surface, &state, .default());
    var snapshot = try ts.snapshot(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "vwxyz") != null);
    try std.testing.expect(ts.screen.cursor_vis);
    try std.testing.expectEqual(@as(u16, 0), ts.screen.cursor.row);
    try std.testing.expect(ts.screen.cursor.col < ts.surface.size().width);
    std.testing.allocator.free(snapshot);

    state.input = .{};
    try state.input.insertSlice("prefix-長い🐈末尾");
    ts.surface.clearAll();
    try drawFileSearch(&ts.surface, &state, .default());
    snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try ts.expectCellText(12, 0, "末");
    try ts.expectCellText(14, 0, "尾");
    try std.testing.expect(ts.screen.cursor_vis);
    try std.testing.expectEqual(@as(u16, 0), ts.screen.cursor.row);
    try std.testing.expect(ts.screen.cursor.col < ts.surface.size().width);
}

test "review file search unavailable terminal replaces no-changes body" {
    const page: review_page.ReviewPageState = .{
        .load = .{ .state = .{ .empty = .no_changes } },
        .file_search = .{ .mode = true },
    };
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(60, 6);
    defer ts.deinit();

    try view(testContext(&page, .default(), 60, 6), &ts.surface);

    const snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Find file:") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "File list unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "No changes") == null);
}

test "review file search uses full body when compact sidebar leaves no prompt pane" {
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffTwo()),
        .file_search = .{ .mode = true },
    };
    defer page.deinit(std.testing.allocator);

    for ([_]u16{ 24, 25 }) |width| {
        var ts: chasen.testing.TestSurface = undefined;
        try ts.init(width, 6);
        defer ts.deinit();

        try view(testContext(&page, .default(), width, 6), &ts.surface);

        try ts.expectCellText(1, 0, "F");
        const snapshot = try ts.snapshot(std.testing.allocator);
        defer std.testing.allocator.free(snapshot);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "Find file:") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "File list unavailable") != null);
    }
}

test "sidebar renderer owns badges titles selection styles and horizontal scroll" {
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffTwoWithStatuses()),
        .viewer = .{ .focus = .sidebar },
    };
    var palette: theme.Palette = .default();
    palette.colors[@intFromEnum(theme.Role.pane_cursor_bg)] = .{ .rgb = .{ 1, 2, 3 } };
    palette.colors[@intFromEnum(theme.Role.success)] = .{ .rgb = .{ 4, 5, 6 } };
    palette.colors[@intFromEnum(theme.Role.accent)] = .{ .rgb = .{ 7, 8, 9 } };
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(34, 8);
    defer ts.deinit();

    const selected_row = review_layout.sidebar_header_rows;
    try viewSidebar(testContext(&page, palette, 80, 9), &ts.surface, page.load.state.loaded.loaded);
    try ts.expectCellText(2, review_layout.sidebar_header_rows, "A");
    try ts.expectCellText(2, review_layout.sidebar_header_rows + 1, "D");
    try ts.expectCellText(1, 2, "F");
    const active_badge = ts.surface.readCell(2, selected_row) orelse return error.ExpectedActiveBadge;
    const active_path = ts.surface.readCell(6, selected_row) orelse return error.ExpectedActivePath;
    const active_trailing = ts.surface.readCell(33, selected_row) orelse return error.ExpectedActiveTrailingCell;
    const active_title = ts.surface.readCell(1, 2) orelse return error.ExpectedActiveTitle;
    try std.testing.expect(active_badge.style.fg.eql(palette.color(.success)));
    for ([_]chasen.Cell{ active_badge, active_path, active_trailing }) |cell| {
        try std.testing.expect(cell.style.bg.eql(palette.color(.pane_cursor_bg)));
        try std.testing.expect(!cell.style.dim);
        try std.testing.expect(!cell.style.reverse);
    }
    try std.testing.expect(active_path.style.bold);
    try std.testing.expect(active_trailing.style.bold);
    try std.testing.expect(active_title.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(active_title.style.bold);
    try std.testing.expect(!active_title.style.dim);

    page.viewer.focus = .diff;
    ts.surface.clearAll();
    try viewSidebar(testContext(&page, palette, 80, 9), &ts.surface, page.load.state.loaded.loaded);
    const inactive_badge = ts.surface.readCell(2, selected_row) orelse return error.ExpectedInactiveBadge;
    const inactive_path = ts.surface.readCell(6, selected_row) orelse return error.ExpectedInactivePath;
    const inactive_trailing = ts.surface.readCell(33, selected_row) orelse return error.ExpectedInactiveTrailingCell;
    const inactive_title = ts.surface.readCell(1, 2) orelse return error.ExpectedInactiveTitle;
    try std.testing.expect(inactive_badge.style.fg.eql(palette.color(.success)));
    for ([_]chasen.Cell{ inactive_badge, inactive_path, inactive_trailing }) |cell| {
        try std.testing.expect(!cell.style.bg.eql(palette.color(.pane_cursor_bg)));
        try std.testing.expect(!cell.style.dim);
        try std.testing.expect(!cell.style.reverse);
    }
    try std.testing.expect(inactive_path.style.bold);
    try std.testing.expect(inactive_title.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(inactive_title.style.bold);
    try std.testing.expect(!inactive_title.style.dim);

    page.viewer.focus = .sidebar;
    page.file_search.mode = true;
    ts.surface.clearAll();
    try viewSidebar(testContext(&page, palette, 80, 9), &ts.surface, page.load.state.loaded.loaded);
    // Search enter, no-match, and unavailable terminals all retain mode and
    // therefore let the search candidate presentation own attention.
    try std.testing.expect(!ts.surface.readCell(6, selected_row).?.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(!ts.surface.readCell(33, selected_row).?.style.bg.eql(palette.color(.pane_cursor_bg)));

    var search_full: chasen.testing.TestSurface = undefined;
    try search_full.init(80, 9);
    defer search_full.deinit();
    try view(testContext(&page, palette, 80, 9), &search_full.surface);
    const search_separator_col = review_layout.sidebarWidth(80, page.viewer.sidebar_width);
    try search_full.expectCellText(search_separator_col + 2, 0, "F");
    const search_snapshot = try search_full.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(search_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, search_snapshot, "File list unavailable") != null);

    // Cancel/empty submit and sidebar-entry success restore sidebar focus,
    // while the inactive rendering above also represents a successful search
    // entered from the diff pane.
    page.file_search.mode = false;
    ts.surface.clearAll();
    try viewSidebar(testContext(&page, palette, 80, 9), &ts.surface, page.load.state.loaded.loaded);
    try std.testing.expect(ts.surface.readCell(33, selected_row).?.style.bg.eql(palette.color(.pane_cursor_bg)));

    var full: chasen.testing.TestSurface = undefined;
    try full.init(80, 9);
    defer full.deinit();
    try view(testContext(&page, palette, 80, 9), &full.surface);
    const separator_col = review_layout.sidebarWidth(80, page.viewer.sidebar_width);
    const separator = full.surface.readCell(separator_col, selected_row) orelse return error.ExpectedSidebarSeparator;
    try std.testing.expect(separator.style.dim);
    try std.testing.expect(!separator.style.reverse);
    try std.testing.expect(!separator.style.bg.eql(palette.color(.pane_cursor_bg)));

    var short: chasen.testing.TestSurface = undefined;
    try short.init(12, review_layout.sidebar_header_rows);
    defer short.deinit();
    try viewSidebar(testContext(&page, palette, 80, 9), &short.surface, page.load.state.loaded.loaded);
    try short.expectCellText(1, 2, "F");

    const nodes = [_]file_tree.Node{.{
        .kind = .file,
        .name = "very_long_tail_file.zig",
        .path = "a/b/c/d/e/f/very_long_tail_file.zig",
        .depth = 6,
        .target = .{ .diff_file = 0 },
        .status = .modified,
        .mode_changed = true,
    }};
    page.load = test_support.loadState(.{
        .text = "",
        .document = .{ .files = &test_support.files_one },
        .file_text_eligibility = &.{.selectable_utf8},
        .tree = .{ .nodes = &nodes },
        .collapsed_dirs = .{},
        .bytes = 0,
        .lines = 0,
    });
    page.viewer.sidebar_horizontal_scroll = 12;
    var narrow: chasen.testing.TestSurface = undefined;
    try narrow.init(24, 8);
    defer narrow.deinit();
    try viewSidebar(testContext(&page, palette, 80, 9), &narrow.surface, page.load.state.loaded.loaded);
    try narrow.expectCellText(2, review_layout.sidebar_header_rows, "M");
    try narrow.expectCellText(4, review_layout.sidebar_header_rows, "m");
    try std.testing.expect(narrow.surface.readCell(4, review_layout.sidebar_header_rows).?.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(narrow.surface.readCell(23, review_layout.sidebar_header_rows).?.style.bg.eql(palette.color(.pane_cursor_bg)));
    const snapshot = try narrow.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "very_long") != null);
}

test "review root expansion renderer keeps expanded root glyph and alignment" {
    const nodes = [_]file_tree.Node{
        .{
            .kind = .repo_root,
            .name = "gitframe",
            .path = "",
            .depth = 0,
            .stats = .{ .added = 51, .removed = 25 },
            .target = .repo_root,
        },
        .{
            .kind = .directory,
            .name = "src",
            .path = "src",
            .depth = 1,
        },
    };
    const tree: file_tree.FileTree = .{ .nodes = &nodes };
    const collapsed: file_tree.CollapsedSet = .empty;
    const root = sidebar_view_model.rowForNode(tree, &collapsed, &.{}, 0, 0).?;
    const directory = sidebar_view_model.rowForNode(tree, &collapsed, &.{}, 1, 1).?;

    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(40, 2);
    defer ts.deinit();
    const palette = paletteWithOverride(.pane_cursor_bg, .{ .rgb = .{ .r = 10, .g = 11, .b = 12 } });

    try drawSidebarRow(&ts.surface, 0, root, true, 0, palette);
    try drawSidebarRow(&ts.surface, 1, directory, true, 0, palette);

    try ts.expectCellText(0, 0, "▾");
    try std.testing.expect(!ts.surface.readCell(0, 0).?.style.reverse);
    try std.testing.expect(ts.surface.readCell(0, 0).?.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(ts.surface.readCell(39, 0).?.style.bg.eql(palette.color(.pane_cursor_bg)));
    try ts.expectCellText(2, 0, "g");
    try ts.expectCellText(28, 0, "+");
    try ts.expectCellText(32, 0, "-");
    try std.testing.expect(ts.surface.readCell(28, 0).?.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(ts.surface.readCell(32, 0).?.style.bg.eql(palette.color(.pane_cursor_bg)));
    try ts.expectCellText(2, 1, "▾");
    try ts.expectCellText(4, 1, "s");
    try std.testing.expect(ts.surface.readCell(39, 1).?.style.bg.eql(palette.color(.pane_cursor_bg)));

    ts.surface.clearAll();
    try drawSidebarRow(&ts.surface, 0, root, false, 0, palette);
    const retained_root = ts.surface.readCell(0, 0) orelse return error.ExpectedRetainedRoot;
    const retained_trailing = ts.surface.readCell(39, 0) orelse return error.ExpectedRetainedRootTrailingCell;
    try std.testing.expect(retained_root.style.bold);
    try std.testing.expect(!retained_root.style.dim);
    try std.testing.expect(!retained_root.style.reverse);
    try std.testing.expect(!retained_root.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(!retained_trailing.style.bg.eql(palette.color(.pane_cursor_bg)));
}

test "sidebar cursor background composes reviewed status mode and path semantics" {
    const row: sidebar_view_model.Row = .{
        .node_index = 0,
        .kind = .file,
        .selected = true,
        .depth = 0,
        .name = "script.sh",
        .path = "script.sh",
        .stats = .{},
        .status = .modified,
        .stage_presence = .mixed,
        .mode_changed = true,
        .reviewed = true,
        .fold = .none,
    };
    var palette: theme.Palette = .default();
    palette.colors[@intFromEnum(theme.Role.pane_cursor_bg)] = .{ .rgb = .{ 1, 2, 3 } };
    palette.colors[@intFromEnum(theme.Role.success)] = .{ .rgb = .{ 4, 5, 6 } };
    palette.colors[@intFromEnum(theme.Role.prompt)] = .{ .rgb = .{ 7, 8, 9 } };
    palette.colors[@intFromEnum(theme.Role.info)] = .{ .rgb = .{ 10, 11, 12 } };

    var active: chasen.testing.TestSurface = undefined;
    try active.init(40, 1);
    defer active.deinit();
    try drawSidebarRow(&active.surface, 0, row, true, 0, palette);

    const points = [_]struct {
        col: u16,
        role: theme.Role,
    }{
        .{ .col = 1, .role = .success },
        .{ .col = 2, .role = .prompt },
        .{ .col = 4, .role = .info },
        .{ .col = 6, .role = .prompt },
    };
    for (points) |point| {
        const cell = active.surface.readCell(point.col, 0) orelse return error.ExpectedActiveSemanticCell;
        try std.testing.expect(cell.style.fg.eql(palette.color(point.role)));
        try std.testing.expect(cell.style.bg.eql(palette.color(.pane_cursor_bg)));
        try std.testing.expect(!cell.style.dim);
        try std.testing.expect(!cell.style.reverse);
    }
    const active_trailing = active.surface.readCell(39, 0) orelse return error.ExpectedActiveTrailingCell;
    try std.testing.expect(active_trailing.style.fg.eql(palette.color(.prompt)));
    try std.testing.expect(active_trailing.style.bg.eql(palette.color(.pane_cursor_bg)));

    var inactive: chasen.testing.TestSurface = undefined;
    try inactive.init(40, 1);
    defer inactive.deinit();
    try drawSidebarRow(&inactive.surface, 0, row, false, 0, palette);
    for (points) |point| {
        const cell = inactive.surface.readCell(point.col, 0) orelse return error.ExpectedInactiveSemanticCell;
        try std.testing.expect(cell.style.fg.eql(palette.color(point.role)));
        try std.testing.expect(!cell.style.bg.eql(palette.color(.pane_cursor_bg)));
        try std.testing.expect(!cell.style.dim);
        try std.testing.expect(!cell.style.reverse);
    }
    const inactive_trailing = inactive.surface.readCell(39, 0) orelse return error.ExpectedInactiveTrailingCell;
    try std.testing.expect(!inactive_trailing.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(!inactive_trailing.style.dim);
    try std.testing.expect(!inactive_trailing.style.reverse);
}

test "sidebar row stage matrix keeps semantic foreground independent of cursor chrome" {
    var palette: theme.Palette = .default();
    palette.colors[@intFromEnum(theme.Role.pane_cursor_bg)] = .{ .rgb = .{ 1, 2, 3 } };
    palette.colors[@intFromEnum(theme.Role.staged)] = .{ .rgb = .{ 4, 5, 6 } };
    palette.colors[@intFromEnum(theme.Role.prompt)] = .{ .rgb = .{ 7, 8, 9 } };
    palette.colors[@intFromEnum(theme.Role.danger)] = .{ .rgb = .{ 10, 11, 12 } };

    const cases = [_]struct {
        stage_presence: file_tree.StagePresence,
        path_color: chasen.Color,
        status_color: chasen.Color,
    }{
        .{ .stage_presence = .clean_or_unknown, .path_color = .default, .status_color = palette.color(.prompt) },
        .{ .stage_presence = .staged_only, .path_color = palette.color(.staged), .status_color = palette.color(.staged) },
        .{ .stage_presence = .mixed, .path_color = palette.color(.prompt), .status_color = palette.color(.prompt) },
        .{ .stage_presence = .conflict, .path_color = palette.color(.danger), .status_color = palette.color(.danger) },
    };
    for (cases) |case| {
        const row: sidebar_view_model.Row = .{
            .node_index = 0,
            .kind = .file,
            .selected = true,
            .depth = 0,
            .name = "file.zig",
            .path = "file.zig",
            .stats = .{},
            .status = .modified,
            .stage_presence = case.stage_presence,
            .mode_changed = false,
            .reviewed = false,
            .fold = .none,
        };
        const inactive_path = sidebarRowStyle(row, palette);
        const active_path = withCursorBackground(inactive_path, palette.color(.pane_cursor_bg));
        const active_status = statusStyle(row, .modified, palette, palette.color(.pane_cursor_bg));

        try std.testing.expect(inactive_path.fg.eql(case.path_color));
        try std.testing.expect(inactive_path.bold);
        try std.testing.expect(!inactive_path.dim);
        try std.testing.expect(!inactive_path.reverse);
        try std.testing.expect(!inactive_path.bg.eql(palette.color(.pane_cursor_bg)));
        try std.testing.expect(active_path.fg.eql(case.path_color));
        try std.testing.expect(active_path.bg.eql(palette.color(.pane_cursor_bg)));
        try std.testing.expect(!active_path.dim);
        try std.testing.expect(!active_path.reverse);
        try std.testing.expect(active_status.fg.eql(case.status_color));
        try std.testing.expect(active_status.bg.eql(palette.color(.pane_cursor_bg)));
        try std.testing.expect(!active_status.dim);
        try std.testing.expect(!active_status.reverse);
    }
}

test "diff renderer owns header search marker gutter and input presentation" {
    var palette: theme.Palette = .default();
    palette.colors[@intFromEnum(theme.Role.pane_cursor_bg)] = .{ .rgb = .{ 1, 2, 3 } };
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .focus = .diff, .diff_cursor = .{ .hunk_header = 0 } },
    };
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(90, 10);
    defer ts.deinit();

    try viewDiffPane(testContext(&page, palette, 90, 11), &ts.surface, page.load.state.loaded.loaded);
    try ts.expectCellText(0, 1, "─");
    try std.testing.expect(ts.surface.readCell(0, 1).?.style.fg.eql(.default));
    try std.testing.expect(ts.surface.readCell(0, 1).?.style.dim);

    page.viewer.focus = .sidebar;
    ts.surface.clear(.{ .col = 0, .row = 0, .width = 90, .height = 10 });
    try viewDiffPane(testContext(&page, palette, 90, 11), &ts.surface, page.load.state.loaded.loaded);
    try std.testing.expect(ts.surface.readCell(0, 1).?.style.fg.eql(.gray));
    try std.testing.expect(!ts.surface.readCell(1, review_layout.diff_body_start_row).?.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(!ts.surface.readCell(89, review_layout.diff_body_start_row).?.style.bg.eql(palette.color(.pane_cursor_bg)));

    page.viewer.focus = .diff;
    page.search.match_offset = 0;
    ts.surface.clear(.{ .col = 0, .row = 0, .width = 90, .height = 10 });
    try viewDiffPane(testContext(&page, palette, 90, 11), &ts.surface, page.load.state.loaded.loaded);
    try ts.expectCellText(0, review_layout.diff_body_start_row, "»");
    try ts.expectCellText(1, review_layout.diff_body_start_row, "▌");
    try ts.expectCellText(2, review_layout.diff_body_start_row, "╭");
    try std.testing.expect(!ts.surface.readCell(0, review_layout.diff_body_start_row).?.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(ts.surface.readCell(1, review_layout.diff_body_start_row).?.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(ts.surface.readCell(2, review_layout.diff_body_start_row).?.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(ts.surface.readCell(89, review_layout.diff_body_start_row).?.style.bg.eql(palette.color(.pane_cursor_bg)));

    page.search.match_offset = null;
    page.viewer.display_mode = .side_by_side;
    var narrow: chasen.testing.TestSurface = undefined;
    try narrow.init(72, 8);
    defer narrow.deinit();
    try viewDiffPane(testContext(&page, palette, 72, 9), &narrow.surface, page.load.state.loaded.loaded);
    try narrow.expectCellText(57, 0, "u");
    try narrow.expectCellText(65, 0, "(");

    page.search.mode = true;
    try page.search.input.insertSlice("missing");
    try viewDiffPane(testContext(&page, palette, 90, 11), &ts.surface, page.load.state.loaded.loaded);
    try ts.expectCellText(1, 1, "s");
    try ts.expectCellText(9, 1, "m");
    try ts.expectCellText(16, 1, " ");
}

test "status-only header keeps semantic statistics and metadata when inactive" {
    var palette: theme.Palette = .default();
    palette.colors[@intFromEnum(theme.Role.success)] = .{ .rgb = .{ 1, 2, 3 } };
    palette.colors[@intFromEnum(theme.Role.danger)] = .{ .rgb = .{ 4, 5, 6 } };
    palette.colors[@intFromEnum(theme.Role.muted)] = .{ .rgb = .{ 7, 8, 9 } };

    var active: chasen.testing.TestSurface = undefined;
    try active.init(40, 4);
    defer active.deinit();
    try drawStatusBody(&active.surface, "src/new.zig", "status only", .{ .added = 12, .removed = 4 }, true, palette);

    var inactive: chasen.testing.TestSurface = undefined;
    try inactive.init(40, 4);
    defer inactive.deinit();
    try drawStatusBody(&inactive.surface, "src/new.zig", "status only", .{ .added = 12, .removed = 4 }, false, palette);

    const suffix_width = chasen.text.displayWidth(" +12 -4");
    const metadata_col: u16 = 40 - @as(u16, @intCast(suffix_width));
    const added_col = metadata_col + 1;
    const separator_col = added_col + 3;
    const removed_col = separator_col + 1;
    const points = [_]struct {
        col: u16,
        role: theme.Role,
        bold: bool,
    }{
        .{ .col = metadata_col, .role = .muted, .bold = false },
        .{ .col = added_col, .role = .success, .bold = true },
        .{ .col = separator_col, .role = .muted, .bold = false },
        .{ .col = removed_col, .role = .danger, .bold = true },
    };
    for (points) |point| {
        const active_cell = active.surface.readCell(point.col, 0) orelse return error.ExpectedActiveStatusHeaderCell;
        const inactive_cell = inactive.surface.readCell(point.col, 0) orelse return error.ExpectedInactiveStatusHeaderCell;
        try std.testing.expect(active_cell.style.fg.eql(palette.color(point.role)));
        try std.testing.expect(inactive_cell.style.fg.eql(palette.color(point.role)));
        try std.testing.expectEqual(point.bold, active_cell.style.bold);
        try std.testing.expectEqual(point.bold, inactive_cell.style.bold);
        try std.testing.expect(!active_cell.style.dim);
        try std.testing.expect(!inactive_cell.style.dim);
    }

    const active_body = active.surface.readCell(0, 2) orelse return error.ExpectedActiveStatusBodyCell;
    const inactive_body = inactive.surface.readCell(0, 2) orelse return error.ExpectedInactiveStatusBodyCell;
    try std.testing.expect(!active_body.style.dim);
    try std.testing.expect(inactive_body.style.dim);
}

test "status-only fallback preserves conflict suffix outside resolver rendering" {
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .status_only = 0 } },
    };
    defer page.deinit(std.testing.allocator);
    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "UU a\x00");
    try page.git_status.replace("/repo", &status_bundle);

    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 8);
    defer ts.deinit();
    try viewDiffPane(testContext(&page, .default(), 80, 9), &ts.surface, page.load.state.loaded.loaded);
    try test_support.expectSnapshotContains(&ts, "status: unmerged (conflict)");
}

test "inactive status-only pending and inert diff path headers keep semantic intensity" {
    const palette = theme.Palette.default();
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{
            .selected_target = .{ .status_only = 0 },
            .focus = .sidebar,
        },
    };
    defer page.git_status.deinit();
    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? new.zig\x00");
    try page.git_status.replace("/repo", &status_bundle);

    var status_only: chasen.testing.TestSurface = undefined;
    try status_only.init(40, 6);
    defer status_only.deinit();
    var status_context = testContext(&page, palette, 40, 7);
    status_context.repo_root = "/repo";
    status_context.navigation.repo_root = "/repo";
    try viewDiffPane(status_context, &status_only.surface, page.load.state.loaded.loaded);
    const status_path = status_only.surface.readCell(1, 0) orelse return error.ExpectedStatusOnlyPath;
    try std.testing.expect(status_path.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(status_path.style.bold);
    try std.testing.expect(!status_path.style.dim);

    page.review_projection.pending = try review_projection.testing.cloneRequest(
        std.testing.allocator,
        app_page.RequestIdentity.review(0, 1),
        1,
        "/repo",
        "new.zig",
        .generated_added_file,
        .unstaged,
        0,
        0,
    );
    defer page.review_projection.clearPending(std.testing.allocator);
    var pending: chasen.testing.TestSurface = undefined;
    try pending.init(40, 6);
    defer pending.deinit();
    try viewDiffPane(status_context, &pending.surface, page.load.state.loaded.loaded);
    const pending_path = pending.surface.readCell(1, 0) orelse return error.ExpectedPendingPath;
    try std.testing.expect(pending_path.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(pending_path.style.bold);
    try std.testing.expect(!pending_path.style.dim);
    page.review_projection.clearPending(std.testing.allocator);

    const inert_eligibility = [_]loaded_diff.FileTextEligibility{.inert_invalid_utf8};
    var inert_loaded = test_support.loadedDiffOne();
    inert_loaded.file_text_eligibility = &inert_eligibility;
    page.load = test_support.loadState(inert_loaded);
    page.viewer.selected_target = .{ .diff_file = 0 };
    var inert: chasen.testing.TestSurface = undefined;
    try inert.init(40, 6);
    defer inert.deinit();
    const inert_context = testContext(&page, palette, 40, 7);
    try viewDiffPane(inert_context, &inert.surface, page.load.state.loaded.loaded);
    const inert_path = inert.surface.readCell(1, 0) orelse return error.ExpectedInertPath;
    try std.testing.expect(inert_path.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(inert_path.style.bold);
    try std.testing.expect(!inert_path.style.dim);
}

test "reviewed sidebar marker and visible search marker are Review view concerns" {
    var reviewed = [_]bool{ true, false };
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(.{
            .text = "",
            .document = .{ .files = &test_support.files_two_statuses },
            .file_text_eligibility = &.{ .selectable_utf8, .selectable_utf8 },
            .tree = .{ .nodes = &test_support.tree_two_status_nodes },
            .reviewed_files = &reviewed,
            .collapsed_dirs = .{},
            .bytes = 0,
            .lines = 0,
        }),
        .search = .{ .match_offset = 4 },
        .viewer = .{ .diff_scroll = 3 },
    };
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(34, 8);
    defer ts.deinit();
    const ctx = testContext(&page, .default(), 80, 9);
    try viewSidebar(ctx, &ts.surface, page.load.state.loaded.loaded);
    try ts.expectCellText(1, review_layout.sidebar_header_rows, "✓");
    drawSearchMatchMarker(ctx, &ts.surface);
    try ts.expectCellText(0, review_layout.diff_body_start_row + 1, "»");
}
