const std = @import("std");
const builtin = @import("builtin");
const chasen = @import("chasen");
const draw = @import("draw");
const app_load_state = @import("../../load_state.zig");
const view_primitives = @import("../../view_primitives.zig");
const review_page = @import("../review.zig");
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
    file_search_mode: bool,
    file_search_text: []const u8,
    file_search_no_match: bool,
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
            .file_search_mode = self.page.file_search.mode,
            .file_search_text = self.page.file_search.input.slice(),
            .file_search_no_match = self.page.file_search.no_match,
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

    const active = app.page.viewer.focus == .sidebar;
    try drawSidebarDetailRow(app, surface, 0, active);

    if (size.height <= 2) return;
    _ = surface.borrowTextAt(0, 2, paneTitleText("Files", active), paneTitleStyle(active, app.theme));
    const title_width = chasen.text.displayWidth(paneTitleText("Files", active));
    const stats_col = title_width + 1;
    if (stats_col < size.width) {
        _ = try surface.printAt(stats_col, 2, app.theme.style(.muted), "0 files / 0 hunks", .{});
    }
}

fn viewLoadedDiff(app: Context, surface: *chasen.Surface, loaded: loaded_diff.LoadedDiff) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    if (app.page.viewer.sidebar_hidden) {
        if (loaded.visibleNodeCount() == 0) {
            drawStateMessage(surface, filterEmptyMessage(app), app.theme);
            return;
        }
        try viewDiffPane(app, surface, loaded);
        return;
    }

    const sidebar_width = review_layout.sidebarWidth(size.width, app.page.viewer.sidebar_width);
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
        drawStateMessage(&diff_pane, filterEmptyMessage(app), app.theme);
        return;
    }
    try viewDiffPane(app, &diff_pane, loaded);
}

/// Draw the file tree side pane from the materialized sidebar view-model.
pub fn viewSidebar(app: Context, surface: *chasen.Surface, loaded: loaded_diff.LoadedDiff) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    const active = app.page.viewer.focus == .sidebar;
    try drawSidebarDetailRow(app, surface, 0, active);

    if (size.height <= 2) return;
    _ = surface.borrowTextAt(0, 2, paneTitleText("Files", active), paneTitleStyle(active, app.theme));
    const title_width = chasen.text.displayWidth(paneTitleText("Files", active));
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
        try drawSidebarRow(surface, row, row_model, app.page.viewer.focus == .sidebar, app.page.viewer.sidebar_horizontal_scroll, app.theme);
    }
}

fn drawSidebarDetailRow(app: Context, surface: *chasen.Surface, row: u16, active: bool) !void {
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

    if (branchStatusSidebarText(app.page, app.repo_root, surface.frameAllocator(), size.width - 1)) |text| {
        try draw.copyClippedTextAt(surface, 1, row, text, paneBranchStyle(active, app.theme));
    }
}

fn drawSidebarRow(surface: *chasen.Surface, row: u16, row_model: sidebar_view_model.Row, pane_active: bool, horizontal_scroll: usize, palette: theme.Palette) !void {
    const width = surface.size().width;
    const row_layout = sidebar_view_model.layout(row_model, width);
    const style = sidebarRowStyle(row_model, pane_active, palette);
    const marker = if (row_model.selected) "▌" else " ";

    if (width > row_layout.marker_col) {
        _ = surface.borrowTextAt(0, row, marker, style);
    }

    if (row_model.status) |status| {
        if (row_layout.badge_col) |badge_col| {
            if (width > badge_col) {
                _ = surface.borrowTextAt(badge_col, row, status.badge(), statusStyle(row_model, status, pane_active, palette));
            }
        }
    }

    if (row_layout.mode_col) |mode_col| {
        if (width > mode_col) {
            _ = surface.borrowTextAt(mode_col, row, "m", modeBadgeStyle(row_model.selected, pane_active, palette));
        }
    }

    if (row_layout.reviewed_col) |reviewed_col| {
        if (width > reviewed_col) {
            _ = surface.borrowTextAt(reviewed_col, row, "✓", reviewedStyle(row_model.selected, pane_active, palette));
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
        try drawSidebarStats(&stats_area, row_model, pane_active, palette);
    }
}

fn drawSidebarStats(surface: *chasen.Surface, row: sidebar_view_model.Row, pane_active: bool, palette: theme.Palette) !void {
    const added_text = try std.fmt.allocPrint(surface.frameAllocator(), "+{d}", .{row.stats.added});
    const removed_text = try std.fmt.allocPrint(surface.frameAllocator(), "-{d}", .{row.stats.removed});
    const added_style = sidebarStatStyle(row, pane_active, palette.color(.success));
    const removed_style = sidebarStatStyle(row, pane_active, palette.color(.danger));

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

fn sidebarRowStyle(row: sidebar_view_model.Row, pane_active: bool, palette: theme.Palette) chasen.TextStyle {
    if (row.selected) return .{ .reverse = pane_active, .bold = true, .dim = !pane_active };
    if (row.kind == .directory or row.kind == .repo_root) return .{ .bold = true, .dim = !pane_active };
    return switch (row.stage_presence) {
        .staged_only => .{ .fg = palette.color(.staged), .dim = !pane_active },
        .mixed => .{ .fg = palette.color(.prompt), .dim = !pane_active },
        .conflict => .{ .fg = palette.color(.danger), .bold = true, .dim = !pane_active },
        else => .{ .dim = !pane_active },
    };
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
        try drawStatusBody(&diff_content, inert.display_path, review_navigation.invalid_utf8_body_message, null, active, app.theme);
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
        .staged_hunks = display.stagedFlags(),
        .line_index = display.lineIndex(),
        .folded_hunks = display.foldedHunks(),
        .palette = app.theme,
        .file_index = display.loadedFileIndex() orelse 0,
        .syntax_spans = if (display.loadedFileIndex() != null) loaded.syntax_spans else .empty(),
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
            try diff_render.renderFile(&content, bundle.loaded.document.files[0], .{
                .requested_mode = app.page.viewer.display_mode,
                .scroll = app.page.viewer.diff_scroll,
                .horizontal_scroll = app.page.viewer.diff_horizontal_scroll,
                .pane_active = active,
                .line_numbers = app.page.viewer.view_options.line_numbers,
                .highlighted_hunk = app.selectedHunkIndex(),
                .cursor_offset = app.visibleDiffCursorOffset(),
                .line_index = bundle.loaded.cachedRenderedLineIndex(0, diff_render.effectiveMode(diff_render.bodyWidth(content.size().width), app.page.viewer.display_mode)),
                .palette = app.theme,
                .file_index = 0,
                .syntax_spans = bundle.loaded.syntax_spans,
                .selection = app.diffSelectionView(),
                .header_selection = app.diffHeaderSelectionActive(),
            });
            drawPaneHeaderRule(surface, active, app.theme);
            return;
        },
        .combined => |bundle| {
            const flags = try surface.frameAllocator().alloc(bool, bundle.projection.hunk_states.len);
            for (bundle.projection.hunk_states, flags) |state, *flag| flag.* = state.state == .staged;
            try diff_render.renderFile(&content, bundle.projection.file, .{
                .requested_mode = app.page.viewer.display_mode,
                .scroll = app.page.viewer.diff_scroll,
                .horizontal_scroll = app.page.viewer.diff_horizontal_scroll,
                .pane_active = active,
                .line_numbers = app.page.viewer.view_options.line_numbers,
                .highlighted_hunk = app.selectedHunkIndex(),
                .cursor_offset = app.visibleDiffCursorOffset(),
                .line_index = bundle.projection.lineIndex(diff_render.effectiveMode(diff_render.bodyWidth(content.size().width), app.page.viewer.display_mode)),
                .staged_hunks = flags,
                .palette = app.theme,
                .selection = app.diffSelectionView(),
                .header_selection = app.diffHeaderSelectionActive(),
            });
            drawPaneHeaderRule(surface, active, app.theme);
            return;
        },
        .generated => |bundle| {
            try diff_render.renderGeneratedAddedFile(&content, bundle.path, &bundle.source, .{
                .requested_mode = app.page.viewer.display_mode,
                .scroll = app.page.viewer.diff_scroll,
                .horizontal_scroll = app.page.viewer.diff_horizontal_scroll,
                .pane_active = active,
                .line_numbers = app.page.viewer.view_options.line_numbers,
                .cursor_offset = app.visibleDiffCursorOffset(),
                .palette = app.theme,
                .header_selection = app.diffHeaderSelectionActive(),
                .source_syntax_spans = switch (bundle.decoration) {
                    .decorated => |decorated| decorated.spans,
                    .eligible, .terminal_plain => .empty(),
                },
                .source_has_visible_syntax = bundle.decoration.hasVisibleSyntax(),
                .selection = app.diffSelectionView(),
            });
            drawPaneHeaderRule(surface, active, app.theme);
            return;
        },
        .inert_invalid_utf8 => |inert| {
            try drawStatusBody(&content, inert.display_path, review_navigation.invalid_utf8_body_message, app.selectedStatusLineStats(), active, app.theme);
            drawPaneHeaderRule(surface, active, app.theme);
            return;
        },
        .status => |status| {
            try drawStatusBody(&content, status.path, status.message, app.selectedStatusLineStats(), active, app.theme);
            drawPaneHeaderRule(surface, active, app.theme);
            return;
        },
        .pending => {
            try drawStatusBody(&content, path, "Loading review projection...", app.selectedStatusLineStats(), active, app.theme);
            drawPaneHeaderRule(surface, active, app.theme);
            return;
        },
        .none, .primary => {},
    }

    try drawTitlePath(&content, path, app.selectedStatusLineStats(), paneTitleStyle(active, app.theme), active, app.theme);
    const status_text = try std.fmt.allocPrint(surface.frameAllocator(), "status: {s}{s}", .{ statusName(entry.index), statusSuffix(entry) });
    try draw.copyClippedTextAt(&content, 0, 2, status_text, .{ .fg = app.theme.color(.muted), .dim = !active });
    switch (file_tree.stagePresenceFromEntry(entry)) {
        .staged_only => {
            try draw.copyClippedTextAt(&content, 0, 4, "This file is staged.", .{ .fg = app.theme.color(.muted), .dim = !active });
            try draw.copyClippedTextAt(&content, 0, 5, "Loading staged diff preview.", .{ .fg = app.theme.color(.muted), .dim = !active });
        },
        else => {
            try draw.copyClippedTextAt(&content, 0, 4, "No diff is available for this file yet.", .{ .fg = app.theme.color(.muted), .dim = !active });
            try draw.copyClippedTextAt(&content, 0, 5, "Loading generated review preview if available.", .{ .fg = app.theme.color(.muted), .dim = !active });
        },
    }
}

fn drawPaneHeaderRule(surface: *chasen.Surface, active: bool, palette: theme.Palette) void {
    const size = surface.size();
    if (size.width == 0 or size.height <= 1) return;

    for (0..size.width) |col| {
        _ = surface.borrowTextAt(@intCast(col), 1, "─", paneHeaderRuleStyle(active, palette));
    }
}

fn drawStatusBody(surface: *chasen.Surface, path: []const u8, message: []const u8, stats: ?file_tree.Stats, active: bool, palette: theme.Palette) !void {
    try drawTitlePath(surface, path, stats, paneTitleStyle(active, palette), active, palette);
    try draw.copyClippedTextAt(surface, 0, 2, message, .{ .fg = palette.color(.muted), .dim = !active });
}

fn drawTitlePath(surface: *chasen.Surface, path: []const u8, stats: ?file_tree.Stats, style: chasen.TextStyle, active: bool, palette: theme.Palette) !void {
    if (stats) |line_stats| {
        if (line_stats.added != 0 or line_stats.removed != 0) {
            const suffix = try std.fmt.allocPrint(surface.frameAllocator(), " +{d} -{d}", .{ line_stats.added, line_stats.removed });
            const suffix_width = chasen.text.displayWidth(suffix);
            const path_width = surface.size().width -| @as(u16, @intCast(@min(suffix_width, std.math.maxInt(u16))));
            if (path_width > 8) {
                var path_surface = surface.child(.{ .col = 0, .row = 0, .width = path_width, .height = 1 });
                try draw.copyTailClippedTextAt(&path_surface, 0, 0, path, style);
                const suffix_col: u16 = @intCast(path_width);
                try drawStatusLineStats(surface, suffix_col, line_stats, active, palette);
                return;
            }
        }
    }
    try draw.copyTailClippedTextAt(surface, 0, 0, path, style);
}

fn drawStatusLineStats(surface: *chasen.Surface, col: u16, stats: file_tree.Stats, active: bool, palette: theme.Palette) !void {
    var cursor = col;
    try draw.copyClippedTextAt(surface, cursor, 0, " ", palette.style(.muted));
    cursor +|= 1;
    const added = try std.fmt.allocPrint(surface.frameAllocator(), "+{d}", .{stats.added});
    try draw.copyClippedTextAt(surface, cursor, 0, added, .{ .fg = palette.color(.success), .bold = true, .dim = !active });
    cursor +|= @intCast(chasen.text.displayWidth(added));
    if (cursor < surface.size().width) {
        try draw.copyClippedTextAt(surface, cursor, 0, " ", palette.style(.muted));
        cursor +|= 1;
    }
    const removed = try std.fmt.allocPrint(surface.frameAllocator(), "-{d}", .{stats.removed});
    try draw.copyClippedTextAt(surface, cursor, 0, removed, .{ .fg = palette.color(.danger), .bold = true, .dim = !active });
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

fn branchStatusSidebarText(page: *const review_page.ReviewPageState, repo_root: ?[]const u8, allocator: std.mem.Allocator, available_width: u16) ?[]const u8 {
    const root = repo_root orelse return null;
    if (page.branch_status_load.pending) |pending| {
        const has_retained_snapshot = if (page.branch_status.repo_root) |snapshot_root|
            std.mem.eql(u8, root, snapshot_root)
        else
            false;
        if (pending.origin == .foreground or !has_retained_snapshot) return "loading branch";
    }

    const snapshot_root = page.branch_status.repo_root orelse return null;
    if (!std.mem.eql(u8, root, snapshot_root)) return null;

    return formatSidebarBranchStatus(allocator, page.branch_status.status, available_width) catch "branch";
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
        allocated_suffix = try std.fmt.allocPrint(allocator, " ↑{d}", .{ahead});
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
    try std.testing.expectEqualStrings("feature/topic ↑2", with_upstream);

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
    try std.testing.expect(std.mem.endsWith(u8, text, " ↑0"));
}

test "formatSidebarBranchStatus omits behind count" {
    const text = try formatSidebarBranchStatus(std.testing.allocator, .{
        .head = .{ .branch = "main" },
        .upstream = .{ .name = "origin/main", .remote = "origin", .remote_branch = "main" },
        .ahead_behind = .{ .ahead = 0, .behind = 7 },
    }, 80);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("main ↑0", text);
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

    const retained = branchStatusSidebarText(&page_state, "/repo", std.testing.allocator, 80).?;
    defer std.testing.allocator.free(retained);
    try std.testing.expectEqualStrings("main no upstream", retained);

    page_state.branch_status_load.pending.?.origin = .foreground;
    try std.testing.expectEqualStrings("loading branch", branchStatusSidebarText(&page_state, "/repo", std.testing.allocator, 80).?);
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

fn statusStyle(row: sidebar_view_model.Row, status: file_tree.Status, pane_active: bool, palette: theme.Palette) chasen.TextStyle {
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
    return .{ .fg = fg, .bold = true, .dim = !pane_active, .reverse = pane_active and row.selected };
}

fn reviewedStyle(selected: bool, pane_active: bool, palette: theme.Palette) chasen.TextStyle {
    return .{ .fg = palette.color(.success), .bold = true, .dim = !pane_active, .reverse = pane_active and selected };
}

fn modeBadgeStyle(selected: bool, pane_active: bool, palette: theme.Palette) chasen.TextStyle {
    return .{ .fg = palette.color(.info), .bold = true, .dim = !pane_active, .reverse = pane_active and selected };
}

fn paneTitleStyle(active: bool, palette: theme.Palette) chasen.TextStyle {
    return if (active)
        palette.boldStyle(.accent)
    else
        .{ .bold = true, .fg = palette.color(.muted), .dim = true };
}

fn paneSearchStyle(active: bool, palette: theme.Palette) chasen.TextStyle {
    return if (active)
        palette.boldStyle(.prompt)
    else
        palette.style(.prompt);
}

fn paneBranchStyle(active: bool, palette: theme.Palette) chasen.TextStyle {
    return if (active)
        palette.style(.info)
    else
        .{ .fg = palette.color(.info), .dim = true };
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

fn paneTitleText(label: []const u8, active: bool) []const u8 {
    if (std.mem.eql(u8, label, "Files")) return " Files";
    if (!active) return label;
    if (std.mem.eql(u8, label, "Diff")) return "▸ Diff";
    return label;
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

test "sidebar renderer owns badges titles selection styles and horizontal scroll" {
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffTwoWithStatuses()),
        .viewer = .{ .focus = .sidebar },
    };
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(34, 8);
    defer ts.deinit();

    try viewSidebar(testContext(&page, .default(), 80, 9), &ts.surface, page.load.state.loaded.loaded);
    try ts.expectCellText(2, review_layout.sidebar_header_rows, "A");
    try ts.expectCellText(2, review_layout.sidebar_header_rows + 1, "D");
    try ts.expectCellText(1, 2, "F");
    try std.testing.expect(ts.surface.readCell(0, review_layout.sidebar_header_rows).?.style.reverse);

    page.viewer.focus = .diff;
    try viewSidebar(testContext(&page, .default(), 80, 9), &ts.surface, page.load.state.loaded.loaded);
    try std.testing.expect(ts.surface.readCell(0, review_layout.sidebar_header_rows).?.style.dim);
    try std.testing.expect(!ts.surface.readCell(0, review_layout.sidebar_header_rows).?.style.reverse);

    const overridden = paletteWithOverride(.success, .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } });
    try viewSidebar(testContext(&page, overridden, 80, 9), &ts.surface, page.load.state.loaded.loaded);
    try std.testing.expect(ts.surface.readCell(2, review_layout.sidebar_header_rows).?.style.fg.eql(.{ .rgb = .{ 1, 2, 3 } }));
    page.viewer.focus = .sidebar;
    const accent = paletteWithOverride(.accent, .{ .rgb = .{ .r = 4, .g = 5, .b = 6 } });
    try viewSidebar(testContext(&page, accent, 80, 9), &ts.surface, page.load.state.loaded.loaded);
    try std.testing.expect(ts.surface.readCell(1, 2).?.style.fg.eql(.{ .rgb = .{ 4, 5, 6 } }));

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
    try viewSidebar(testContext(&page, .default(), 80, 9), &narrow.surface, page.load.state.loaded.loaded);
    try narrow.expectCellText(2, review_layout.sidebar_header_rows, "M");
    try narrow.expectCellText(4, review_layout.sidebar_header_rows, "m");
    const snapshot = try narrow.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "very_long") != null);
}

test "diff renderer owns header search marker gutter and input presentation" {
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .focus = .diff, .diff_cursor = .{ .hunk_header = 0 } },
    };
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(90, 10);
    defer ts.deinit();

    try viewDiffPane(testContext(&page, .default(), 90, 11), &ts.surface, page.load.state.loaded.loaded);
    try ts.expectCellText(0, 1, "─");
    try std.testing.expect(ts.surface.readCell(0, 1).?.style.fg.eql(.default));
    try std.testing.expect(ts.surface.readCell(0, 1).?.style.dim);

    page.viewer.focus = .sidebar;
    try viewDiffPane(testContext(&page, .default(), 90, 11), &ts.surface, page.load.state.loaded.loaded);
    try std.testing.expect(ts.surface.readCell(0, 1).?.style.fg.eql(.gray));

    page.viewer.focus = .diff;
    page.search.match_offset = 0;
    try viewDiffPane(testContext(&page, .default(), 90, 11), &ts.surface, page.load.state.loaded.loaded);
    try ts.expectCellText(0, review_layout.diff_body_start_row, "»");
    try ts.expectCellText(1, review_layout.diff_body_start_row, "▌");
    try ts.expectCellText(2, review_layout.diff_body_start_row, "╭");

    page.search.match_offset = null;
    page.viewer.display_mode = .side_by_side;
    var narrow: chasen.testing.TestSurface = undefined;
    try narrow.init(72, 8);
    defer narrow.deinit();
    try viewDiffPane(testContext(&page, .default(), 72, 9), &narrow.surface, page.load.state.loaded.loaded);
    try narrow.expectCellText(57, 0, "u");
    try narrow.expectCellText(65, 0, "(");

    page.search.mode = true;
    try page.search.input.insertSlice("missing");
    try viewDiffPane(testContext(&page, .default(), 90, 11), &ts.surface, page.load.state.loaded.loaded);
    try ts.expectCellText(1, 1, "s");
    try ts.expectCellText(9, 1, "m");
    try ts.expectCellText(16, 1, " ");
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
