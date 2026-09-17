//! History catalog rendering. Rows are projected only for the current
//! viewport and clipped through Chasen UI's terminal-cell presentation.

const std = @import("std");
const chasen = @import("chasen");
const ui = @import("chasen_ui");
const text_presentation = ui.text_presentation;
const draw = @import("draw");
const keymap = @import("keymap");
const branch_commit_time = @import("../../branch_commit_time.zig");
const app_state = @import("../../state.zig");
const diff_surface = @import("../../diff_surface.zig");
const page_header = @import("../../page_header.zig");
const committed_diff_navigation = @import("../committed_diff/navigation.zig");
const diff_render = @import("../../../diff/render.zig");
const file_tree = @import("../../../file_tree.zig");
const git_history = @import("../../../git/history.zig");
const history_page = @import("../history.zig");
const loaded_diff = @import("../../../loaded_diff.zig");
const root_capability = @import("../../../repo/root_capability.zig");
const theme = @import("theme");

const row_prefix_width: u16 = 4;
const commit_width: u16 = 7;
const date_width: u16 = 10;
const author_width: u16 = 14;
const column_gap: u16 = 2;

const FieldLayout = struct {
    col: u16,
    width: u16,
};

const CommitRowLayout = struct {
    commit: FieldLayout,
    date: FieldLayout,
    author: FieldLayout,
    summary: FieldLayout,

    fn init(viewport_width: u16) CommitRowLayout {
        const commit_col = row_prefix_width;
        const date_col = commit_col + commit_width + column_gap;
        const author_col = date_col + date_width + column_gap;
        const summary_col = author_col + author_width + column_gap;
        return .{
            .commit = .{ .col = commit_col, .width = commit_width },
            .date = .{ .col = date_col, .width = date_width },
            .author = .{ .col = author_col, .width = author_width },
            .summary = .{ .col = summary_col, .width = viewport_width -| summary_col },
        };
    }
};

pub const PickerMarker = struct {
    pub const range_anchor = "A";
    pub const range_selected = "┃";
    pub const merge = "M";
    pub const root = "R";
    pub const unavailable_parent = "?";
};

pub const range_footer_text = "Range: " ++ PickerMarker.range_anchor ++
    " anchor · " ++ PickerMarker.range_selected ++ " selected";

pub const ViewContext = struct {
    page_state: *const history_page.HistoryPageState,
    palette: theme.Palette,
    repo_root: ?[]const u8 = null,
    repo_epoch: u64 = 0,
    root_identity: ?root_capability.Identity = null,
    layout: diff_surface.Layout = .{ .width = 0, .height = 0 },
    keymap: keymap.Effective = .{},
    shell_status: ?*const app_state.StatusMessage = null,

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
    return viewPicker(context, surface);
}

pub fn viewCommitDetail(context: ViewContext, surface: *chasen.Surface) !void {
    const detail = context.page_state.openDetailConst() orelse return;
    const opts: ui.Modal.ViewOptions = .{
        .dialog_width = @min(surface.size().width, 100),
        .dialog_height = @min(surface.size().height, 24),
        .title = "Commit detail",
        .backdrop = true,
        .border = .rounded,
        .title_style = context.palette.boldStyle(.accent),
        .border_style = context.palette.style(.accent),
    };
    const frame = ui.Modal.frame(surface, opts) orelse return;
    var dialog = frame.dialogSurface();
    dialog.fillAll(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = .{} });
    frame.view();
    var content = frame.contentSurface();
    const size = content.size();
    if (size.width == 0 or size.height == 0) return;
    const body_height = size.height -| 2;
    if (body_height > 0) {
        var body = content.child(.{ .col = 0, .row = 0, .width = size.width, .height = body_height });
        _ = drawWrappedTextScrolled(
            &body,
            detail.snapshot.canonical_payload,
            detail.top_visual_row,
            chasen.TextStyle{},
        );
    }

    if (body_height < size.height) {
        const total = history_page.detailVisualRowCount(detail.snapshot.canonical_payload, size.width);
        const end = @min(total, detail.top_visual_row + @as(usize, body_height));
        const visible_status = if (context.page_state.status.text().len > 0)
            context.page_state.status.text()
        else if (context.shell_status) |status|
            status.text()
        else
            "";
        const indicator = if (visible_status.len > 0)
            visible_status
        else if (total > @as(usize, body_height))
            try std.fmt.allocPrint(content.frameAllocator(), "Rows {d}-{d} of {d}", .{
                @min(detail.top_visual_row + 1, total),
                end,
                total,
            })
        else
            "";
        const indicator_style = if (std.mem.startsWith(u8, indicator, "clipboard copy sent:"))
            context.palette.style(.accent)
        else if (visible_status.len > 0)
            context.palette.style(.danger)
        else
            context.palette.style(.muted);
        try draw.copyClippedTextAt(&content, 0, body_height, indicator, indicator_style);
    }
    if (body_height +| 1 < size.height) {
        const items = [_]ui.key_hint.Item{
            ui.key_hint.item("y", "copy"),
            ui.key_hint.item("j/k PgUp/PgDn Home/End", "scroll"),
            ui.key_hint.item("i/Esc/q", "close"),
        };
        _ = try ui.key_hint.draw(&content, 0, body_height + 1, &items, .{
            .key_style = context.palette.boldStyle(.accent),
            .action_style = context.palette.style(.muted),
        });
    }
}

pub fn detailContentSize(size: chasen.Size) history_page.DetailSize {
    const overlay: chasen.Rect = .{ .col = 0, .row = 0, .width = size.width, .height = size.height };
    const dialog = ui.Modal.dialogRectFor(overlay, .{
        .dialog_width = @min(size.width, 100),
        .dialog_height = @min(size.height, 24),
    });
    const content = ui.Modal.contentRectFor(dialog, .{ .top = 1, .right = 1, .bottom = 1, .left = 1 });
    return .{ .width = content.width, .height = content.height -| 2 };
}

fn drawWrappedTextScrolled(surface: *chasen.Surface, text: []const u8, scroll: usize, style: chasen.TextStyle) usize {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return 0;
    const clamped_scroll = @min(scroll, history_page.detailMaxOffset(text, .{
        .width = size.width,
        .height = size.height,
    }));
    var logical_row: usize = 0;
    var drawn_rows: usize = 0;
    var line_start: usize = 0;
    var line_end: usize = 0;
    var line_width: u32 = 0;
    var iter = chasen.text.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        if (bytes.len == 1 and bytes[0] == '\n') {
            if (drawWrappedLine(surface, text[line_start..line_end], logical_row, clamped_scroll, &drawn_rows, style)) return drawn_rows;
            logical_row += 1;
            line_start = grapheme.start + grapheme.len;
            line_end = line_start;
            line_width = 0;
            continue;
        }
        const grapheme_width = chasen.text.displayWidth(bytes);
        if (line_width > 0 and line_width + grapheme_width > size.width) {
            if (drawWrappedLine(surface, text[line_start..line_end], logical_row, clamped_scroll, &drawn_rows, style)) return drawn_rows;
            logical_row += 1;
            line_start = grapheme.start;
            line_end = grapheme.start;
            line_width = 0;
        }
        line_end = grapheme.start + grapheme.len;
        line_width += grapheme_width;
    }
    _ = drawWrappedLine(surface, text[line_start..line_end], logical_row, clamped_scroll, &drawn_rows, style);
    return drawn_rows;
}

fn drawWrappedLine(
    surface: *chasen.Surface,
    line: []const u8,
    logical_row: usize,
    scroll: usize,
    drawn_rows: *usize,
    style: chasen.TextStyle,
) bool {
    if (logical_row < scroll) return false;
    if (drawn_rows.* >= @as(usize, surface.size().height)) return true;
    _ = surface.borrowTextAt(0, @intCast(drawn_rows.*), line, style);
    drawn_rows.* += 1;
    return drawn_rows.* >= @as(usize, surface.size().height);
}

fn viewPicker(context: ViewContext, surface: *chasen.Surface) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;
    const page = context.page_state;

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
    try drawCatalogContext(surface, context.palette, page, snapshot, previous);

    if (page.catalog.records.items.len == 0) {
        if (size.height > 1) try drawClipped(
            surface,
            2,
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
        const focused = index == page.catalog.cursor;
        if (focused) fillSelectedRow(surface, row, context.palette.color(.pane_cursor_bg));
        if (index == page.catalog.records.items.len) {
            const markers = try std.fmt.allocPrint(surface.frameAllocator(), "{s} … ", .{if (focused) "›" else " "});
            try drawClipped(surface, 0, row, markers, catalogStyle(context.palette, .prompt, focused));
            const label = if (page.load_state == .loading) "Loading older commits…" else "Load 200 older commits…";
            try drawClipped(surface, row_prefix_width, row, label, catalogStyle(context.palette, .prompt, focused));
            continue;
        }
        const record = &page.catalog.records.items[index];
        const range_marker: ?[]const u8 = if (page.draft.anchor()) |anchor|
            if (index == anchor)
                PickerMarker.range_anchor
            else if (page.draft.contains(page.catalog.cursor, index))
                PickerMarker.range_selected
            else
                null
        else
            null;
        const markers = try std.fmt.allocPrint(surface.frameAllocator(), "{s}{s}{s} ", .{
            if (focused) "›" else " ",
            range_marker orelse " ",
            topologyMarker(record),
        });
        try drawClipped(surface, 0, row, markers, catalogStyle(context.palette, if (focused) .accent else .info, focused));
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
) !void {
    const size = surface.size();
    if (size.width <= 2 or size.height == 0) return;
    const allocator = surface.frameAllocator();
    const base = try catalogHeadContextLabel(allocator, snapshot);
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
    const content_width: u16 = size.width -| 2;
    const base_width = chasen.text.displayWidth(base);
    const full_width = chasen.text.displayWidth(position.full);
    const compact_width = chasen.text.displayWidth(position.compact);
    const right = if (base_width +| column_gap +| full_width <= content_width)
        position.full
    else if (base_width +| column_gap +| compact_width <= content_width)
        position.compact
    else
        null;

    if (right) |right_text| {
        const right_width = chasen.text.displayWidth(right_text);
        const right_col: u16 = size.width - @as(u16, @intCast(right_width));
        const left_width = right_col -| column_gap -| 2;
        try drawClippedField(surface, 2, 0, left_width, left, palette.boldStyle(.accent));
        try drawClipped(surface, right_col, 0, right_text, palette.style(.muted));
        return;
    }

    try drawClipped(surface, 2, 0, left, palette.boldStyle(.accent));
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
    const formatted_date = branch_commit_time.formatDateUtc(record.committer_unix);
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
    drawClipped(surface, 2, row, title, palette.boldStyle(.accent)) catch {};
    if (row + 1 < size.height) drawClipped(surface, 2, row + 1, body, palette.style(.muted)) catch {};
    if (row + 2 < size.height) drawClipped(surface, 2, row + 2, hint, palette.style(.prompt)) catch {};
}

fn drawClipped(surface: *chasen.Surface, col: u16, row: u16, text: []const u8, style: chasen.TextStyle) !void {
    try text_presentation.drawClippedAt(surface, col, row, text, style, .{
        .tab_width = 4,
        .marker = "…",
        .direction = .head,
    });
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
        try view(.{ .page_state = &page_state, .palette = palette }, &rendered.surface);
        const snapshot = try rendered.snapshot(allocator);
        defer allocator.free(snapshot);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "Branch main · HEAD 1111111") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "Commit 3 of 3 loaded") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "catalog head") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "commit   subject") == null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, " AM 1111111") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "›┃R 3333333") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "root subject") != null);
        try rendered.expectCellText(2, 0, "B");
        const layout = CommitRowLayout.init(size.width);
        try rendered.expectCellText(layout.commit.col, 1, "1");
        try rendered.expectCellText(layout.date.col, 1, "2");
        try rendered.expectCellText(layout.author.col, 1, "A");
        try rendered.expectCellText(layout.summary.col, 1, "[");

        const refs_width = chasen.text.displayWidth("[HEAD -> main]");
        for ([_]struct { col: u16, role: theme.Role }{
            .{ .col = layout.commit.col, .role = .accent },
            .{ .col = layout.date.col, .role = .muted },
            .{ .col = layout.author.col, .role = .info },
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
            .{ .col = layout.summary.col, .role = .prompt },
            .{ .col = layout.summary.col + selected_refs_width + 1, .role = .foreground },
        }) |expected| {
            const cell = rendered.surface.readCell(expected.col, 3) orelse return error.ExpectedSelectedHistoryField;
            try std.testing.expect(cell.style.fg.eql(palette.color(expected.role)));
            try std.testing.expect(cell.style.bg.eql(palette.color(.pane_cursor_bg)));
            try std.testing.expect(cell.style.bold);
        }
        try std.testing.expect(rendered.surface.readCell(size.width - 1, 3).?.style.bg.eql(palette.color(.pane_cursor_bg)));

        const merge_marker = rendered.surface.readCell(2, 1) orelse return error.ExpectedTopologyMarker;
        try std.testing.expectEqualStrings(PickerMarker.merge, merge_marker.char.grapheme);
        try std.testing.expect(merge_marker.style.fg.eql(palette.color(.info)));
        try std.testing.expect(!merge_marker.style.dim);
        try std.testing.expect(!merge_marker.style.bg.eql(palette.color(.pane_cursor_bg)));
        const selected_root_marker = rendered.surface.readCell(2, 3) orelse return error.ExpectedTopologyMarker;
        try std.testing.expectEqualStrings(PickerMarker.root, selected_root_marker.char.grapheme);
        try std.testing.expect(selected_root_marker.style.fg.eql(palette.color(.accent)));
        try std.testing.expect(!selected_root_marker.style.dim);
        try std.testing.expect(selected_root_marker.style.bg.eql(palette.color(.pane_cursor_bg)));

        for ([_]struct { row: u16, marker: []const u8 }{
            .{ .row = 1, .marker = PickerMarker.range_anchor },
            .{ .row = 2, .marker = PickerMarker.range_selected },
            .{ .row = 3, .marker = PickerMarker.range_selected },
        }) |expected| {
            const cell = rendered.surface.readCell(1, expected.row) orelse return error.ExpectedRangeMarker;
            try std.testing.expectEqualStrings(expected.marker, cell.char.grapheme);
            try std.testing.expect(cell.style.fg.eql(palette.color(.accent)));
            try std.testing.expect(cell.style.bold);
            try std.testing.expectEqual(expected.row == 3, cell.style.bg.eql(palette.color(.pane_cursor_bg)));
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
    try view(.{ .page_state = &page_state, .palette = .default() }, &detached_more.surface);
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
    try view(.{ .page_state = &page_state, .palette = .default() }, &appended.surface);
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
    try view(.{ .page_state = &page_state, .palette = .default() }, &changed.surface);
    const changed_snapshot = try changed.snapshot(allocator);
    defer allocator.free(changed_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, changed_snapshot, "Branch feature · HEAD 2222222") != null);
    try std.testing.expect(std.mem.indexOf(u8, changed_snapshot, "Previous diff: main @ 1111111") != null);

    page_state.catalog.capped = true;
    var capped: chasen.testing.TestSurface = undefined;
    try capped.init(120, 32);
    defer capped.deinit();
    try view(.{ .page_state = &page_state, .palette = .default() }, &capped.surface);
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
    try view(.{ .page_state = &page_state, .palette = .default() }, &unborn.surface);
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
    try view(.{ .page_state = &page_state, .palette = .default() }, &failed.surface);
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
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "1970-01-01") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "author suffix") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "subject without refs") != null);
}

test "History commit detail reaches a 16 KiB ASCII wide combining document and copies it whole" {
    const allocator = std.testing.allocator;
    const oid = try git_history.ObjectId.parse(.sha1, "0123456789abcdef0123456789abcdef01234567");
    const tail = "TAIL-猫-e\u{301}";
    const subject = try allocator.alloc(u8, 16 * 1024);
    @memset(subject, 's');
    @memcpy(subject[subject.len - tail.len ..], tail);
    const author = try allocator.dupe(u8, "Long Author");
    const committed = try allocator.dupe(u8, "2024-09-01 12:35:23 +00:00");
    const decorations = try allocator.dupe(u8, "HEAD -> main, tag: wide-猫");
    const payload = try std.fmt.allocPrint(
        allocator,
        "Commit: {s}\nAuthor: {s}\nCommitted: {s}\nRefs: {s}\nSubject: {s}",
        .{ oid.slice(), author, committed, decorations, subject },
    );
    var page_state: history_page.HistoryPageState = .{ .detail = .{ .open = .{
        .snapshot = .{
            .oid = oid,
            .author = author,
            .committed = committed,
            .decorations = decorations,
            .subject = subject,
            .canonical_payload = payload,
        },
        .modal_instance_id = 1,
    } } };
    defer page_state.deinit(allocator);
    var shell_status: app_state.StatusMessage = .{};
    const context: ViewContext = .{
        .page_state = &page_state,
        .palette = .default(),
        .shell_status = &shell_status,
    };

    const size: chasen.Size = .{ .width = 80, .height = 24 };
    var rendered: chasen.testing.TestSurface = undefined;
    try rendered.init(size.width, size.height);
    defer rendered.deinit();
    try viewCommitDetail(context, &rendered.surface);
    const start = try rendered.snapshot(allocator);
    defer allocator.free(start);
    try std.testing.expect(std.mem.indexOf(u8, start, "Commit detail") != null);
    try std.testing.expect(std.mem.indexOf(u8, start, "Commit: 0123456789abcdef") != null);
    try std.testing.expect(std.mem.indexOf(u8, start, "Rows 1-") != null);
    try std.testing.expect(std.mem.indexOf(u8, start, "y: copy") != null);

    shell_status.set("close History commit detail before switching pages", .{});
    try viewCommitDetail(context, &rendered.surface);
    const blocked = try rendered.snapshot(allocator);
    defer allocator.free(blocked);
    try std.testing.expect(std.mem.indexOf(u8, blocked, shell_status.text()) != null);
    shell_status.clear();

    const content_size = detailContentSize(size);
    page_state.scrollDetail(.end, content_size);
    try viewCommitDetail(context, &rendered.surface);
    const end = try rendered.snapshot(allocator);
    defer allocator.free(end);
    try std.testing.expect(std.mem.indexOf(u8, end, "e\u{301}") != null);
    try std.testing.expect(std.mem.indexOf(u8, end, " of ") != null);
    const copy = page_state.beginDetailCopy().?;
    try std.testing.expectEqual(payload.len, copy.payload.len);
    try std.testing.expectEqualStrings(payload, copy.payload);

    page_state.clampDetailViewport(detailContentSize(.{ .width = 120, .height = 32 }));
    try std.testing.expectEqual(
        history_page.detailMaxOffset(payload, detailContentSize(.{ .width = 120, .height = 32 })),
        page_state.openDetailConst().?.top_visual_row,
    );
}
