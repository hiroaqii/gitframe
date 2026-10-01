const std = @import("std");
const builtin = @import("builtin");
const chasen = @import("chasen");
const ui = @import("chasen_ui");
const command_line = @import("command_line.zig");
const app_commit_panel = @import("commit_panel.zig");
const app_repo_picker = @import("repo_picker.zig");
const app_actions = @import("actions.zig");
const branch_commit_time = @import("branch_commit_time.zig");
const branch_picker = @import("branch_picker.zig");
const local_time = @import("../local_time.zig");
const action_lifecycle = @import("workflow/action_lifecycle.zig");
const app_state = @import("state.zig");
const shell_layout = @import("shell_layout.zig");
const view_primitives = @import("view_primitives.zig");
const changes_view = @import("pages/changes/view.zig");
const compare_view = @import("pages/compare/view.zig");
const repository_view = @import("pages/repository/view.zig");
const history_view = @import("pages/history/view.zig");
const app_prompt = @import("prompt.zig");
const page = @import("page.zig");
const page_header = @import("page_header.zig");
const file_tree = @import("../file_tree.zig");
const diff_render = @import("../diff/render.zig");
const diff_surface = @import("diff_surface.zig");
const draw = @import("draw");
const keymap = @import("keymap");
const repo_state = @import("../repo/state.zig");
const theme = @import("theme");
const changes_page = if (builtin.is_test) @import("pages/changes.zig") else struct {};
const compare_page = if (builtin.is_test) @import("pages/compare.zig") else struct {};
const repository_page = if (builtin.is_test) @import("pages/repository.zig") else struct {};
const history_page = if (builtin.is_test) @import("pages/history.zig") else struct {};
const git_history = if (builtin.is_test) @import("../git/history.zig") else struct {};
const repository_source = if (builtin.is_test) @import("../repository/source.zig") else struct {};
const content_fingerprint = if (builtin.is_test) @import("../content_fingerprint.zig") else struct {};

/// Rendering-only helpers for App.
///
/// This module intentionally does not own state transitions. It borrows the
/// App state, projects it to terminal surfaces, and keeps layout constants
/// shared with tests through small public helpers.
const shell_frame_border = ui.Panel.Border.rounded;
const help_dialog_max_width: u16 = 120;
const help_dialog_max_height: u16 = 38;
const help_two_column_min_width: u16 = 96;
const help_column_gap: u16 = 2;
const help_footer_rows: u16 = 1;
const commit_dialog_width: u16 = 80;
const repo_picker_dialog_width: u16 = 80;
const remote_error_dialog_max_width: u16 = 90;
const remote_error_dialog_min_height: u16 = 16;
const repo_picker_filter_input_col: u16 = 8;
const repo_picker_path_input_col: u16 = 11;
const repo_picker_list_label_col: u16 = 4;
const commit_dialog_height: u16 = 22;
const confirmation_dialog_width: u16 = 72;
const confirmation_dialog_height: u16 = 9;

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

const PageBarRemoteActions = struct {
    keymap: keymap.Effective,
    push: bool,
    pull: bool,
};

const PageBarMetadata = struct {
    presentation: ?page_header.Presentation = null,
    line_stats: ?file_tree.Stats = null,
    remote_actions: ?PageBarRemoteActions = null,
};

pub const Context = struct {
    changes: changes_view.Context,
    compare: compare_view.Context,
    repository: repository_view.ViewContext,
    history: ?history_view.ViewContext = null,
    active_page: page.Id,
    page_bar_visible: bool,
    theme: theme.Palette,
    keymap: keymap.Effective,
    action: action_lifecycle.View,
    remote_cancelable: bool = false,
    remote_canceling: bool = false,
    /// Shell notifications temporarily win over the active page diagnostic.
    status: *const app_state.StatusMessage,
    page_status: ?*const app_state.StatusMessage = null,
    commit_panel: *const app_commit_panel.State,
    repo_picker: *const app_prompt.RepoPickerState,
    repo_picker_pending_workspace_root: ?[]const u8,
    repo_picker_items: []const app_repo_picker.Item,
    repo_picker_has_recent: bool,
    overlay: *const app_state.OverlayState,
    committed_repo_discovery_kind: app_repo_picker.DiscoveryKind,
    active_repo_index: usize,
    has_active_repo: bool,
    discard_confirmation: ?app_state.DiscardFileConfirmation,
    amend_confirmation: ?app_state.AmendConfirmation,
    push_confirmation: ?app_state.PushConfirmation,
    pull_confirmation: ?app_state.PullConfirmation,
    remote_error_operation: ?app_state.GitErrorOperation,
    remote_error_message: ?[]const u8,
    push_retry_target: ?*const app_state.PushRetryTarget,
    push_retry_inspecting: bool,
    branch_switch: *const app_state.BranchSwitchState,
    staged_summary: app_commit_panel.StagedSummary,
    create_stash: ?*const @import("stash.zig").Create = null,
    stash_catalog: ?*const @import("stash.zig").Catalog = null,
    stash_target: ?@import("pages/changes/operations.zig").StashTarget = null,
};

pub fn view(app: Context, surface: *chasen.Surface) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    surface.hideCursor();

    if (shell_layout.frameEnabled(size)) {
        const frame = ui.Panel.frame(surface, shellFrameOptions(app.theme));
        frame.view();
        var content = frame.contentSurface();
        try viewContent(app, &content);
        return;
    }

    try viewContent(app, surface);
}

fn viewContent(app: Context, surface: *chasen.Surface) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    const sections = shell_layout.partitionContent(.{ .col = 0, .row = 0, .width = size.width, .height = size.height }, .{
        .page_bar_visible = app.page_bar_visible,
    });
    if (sections.page_bar) |rect| {
        var page_bar = surface.child(rect);
        viewPageBar(
            app.active_page,
            sections.body.height == 0 or sections.footer.height == 0,
            .{
                .presentation = activePageHeaderPresentation(app, surface.frameAllocator()),
                .line_stats = activePageHeaderLineStats(app),
                .remote_actions = activePageHeaderRemoteActions(app),
            },
            app.theme,
            &page_bar,
        );
    }
    var body = surface.child(sections.body);
    try viewBody(app, &body);

    var footer = surface.child(sections.footer);
    viewFooter(app, &footer);

    if (app.repo_picker.mode) {
        try viewRepoPicker(app, surface);
    }
    if (app.overlay.isHelp() and app.overlay.visibleOn(app.active_page)) {
        try viewHelpPopup(app, surface);
    }
    if (app.commit_panel.is_open and !app.overlay.isAmendCommit()) {
        try viewCommitPanel(app, surface);
    }
    if (app.overlay.isDiscardFile() and app.overlay.visibleOn(app.active_page)) {
        try viewDiscardConfirmation(app, surface);
    }
    if (app.overlay.isAmendCommit() and app.overlay.visibleOn(app.active_page)) {
        try viewAmendConfirmation(app, surface);
    }
    if (app.overlay.isPushBranch() and app.overlay.visibleOn(app.active_page)) {
        try viewPushConfirmation(app, surface);
    }
    if (app.overlay.isPullBranch() and app.overlay.visibleOn(app.active_page)) {
        try viewPullConfirmation(app, surface);
    }
    if (app.overlay.isSwitchBranch() and app.overlay.visibleOn(app.active_page)) {
        try viewBranchSwitchPopup(app, surface);
    }
    if (app.overlay.isRemoteError() and app.overlay.visibleOn(app.active_page)) {
        try viewRemoteError(app, surface);
    }
    if (app.overlay.isStashes() and app.overlay.visibleOn(app.active_page)) try viewStashes(app, surface);
    if (app.overlay.isCreateStash() and app.overlay.visibleOn(app.active_page)) {
        try viewCreateStash(app, surface);
    }
    if (app.active_page == .compare and app.compare.page.base_picker.open) {
        try compare_view.viewBasePicker(app.compare, surface);
    }
}

fn shellFrameOptions(palette: theme.Palette) ui.Panel.ViewOptions {
    return .{
        .title = "GitFrame",
        .padding = shell_layout.frame_padding,
        .border = shell_frame_border,
        .border_style = .{ .dim = true },
        .title_style = palette.boldStyle(.muted),
    };
}

fn viewBody(app: Context, surface: *chasen.Surface) !void {
    return switch (app.active_page) {
        .changes => changes_view.view(app.changes, surface),
        .repository => repository_view.view(app.repository, surface),
        .history => if (app.history) |history| history_view.view(history, surface) else viewPlaceholderPage(app.active_page, app.has_active_repo, app.theme, surface),
        .compare => compare_view.view(app.compare, surface),
    };
}

fn activePageHeaderPresentation(app: Context, allocator: std.mem.Allocator) ?page_header.Presentation {
    return switch (app.active_page) {
        .changes => changes_view.pageHeaderPresentation(app.changes),
        .repository => repository_view.pageHeaderPresentation(app.repository),
        .history => if (app.history) |history| history_view.pageHeaderPresentation(history, allocator) else null,
        .compare => compare_view.pageHeaderPresentation(app.compare),
    };
}

fn activePageHeaderLineStats(app: Context) ?file_tree.Stats {
    return switch (app.active_page) {
        .changes => changes_view.pageHeaderLineStats(app.changes),
        .compare => compare_view.pageHeaderLineStats(app.compare),
        .history => if (app.history) |history| history_view.pageHeaderLineStats(history) else null,
        .repository => null,
    };
}

fn activePageHeaderRemoteActions(app: Context) ?PageBarRemoteActions {
    const presentation = switch (app.active_page) {
        .changes => blk: {
            if (app.changes.page.search.mode or app.changes.page.file_search.mode) return null;
            switch (app.changes.page.load.state) {
                .loaded => {},
                .empty => |reason| if (reason != .no_changes) return null,
                else => return null,
            }
            break :blk changes_view.pageHeaderPresentation(app.changes) orelse return null;
        },
        .repository => blk: {
            const state = app.repository.page_state;
            if (state.source_search.mode or state.file_search.mode or state.selection_owner != .none) return null;
            const context = state.remoteActionContext(app.repository.repo_root, state.repo_epoch, state.root_identity);
            if (!context.branch_status.fresh) return null;
            break :blk repository_view.pageHeaderPresentation(app.repository) orelse return null;
        },
        else => return null,
    };
    return switch (presentation) {
        .head => |head| switch (head) {
            .branch => |branch| .{
                .keymap = app.keymap,
                .push = true,
                .pull = switch (branch.upstream) {
                    .ahead => true,
                    .no_upstream => false,
                },
            },
            .detached, .unknown => null,
        },
        .comparison, .terminal => null,
    };
}

fn viewPageBar(
    active: page.Id,
    compact: bool,
    metadata: PageBarMetadata,
    palette: theme.Palette,
    surface: *chasen.Surface,
) void {
    if (surface.size().width == 0 or surface.size().height == 0) return;
    if (compact) {
        const label = std.fmt.allocPrint(surface.frameAllocator(), " {s} ", .{active.label()}) catch active.label();
        draw.copyClippedTextAt(surface, 1, shell_layout.page_bar_label_row, label, palette.boldStyle(.accent)) catch {};
    } else {
        for (page.all) |id| {
            const tab = page.tab(id);
            if (tab.col >= surface.size().width) break;
            const label = std.fmt.allocPrint(surface.frameAllocator(), " {s} ", .{id.label()}) catch id.label();
            draw.copyClippedTextAt(surface, tab.col, shell_layout.page_bar_label_row, label, if (id == active) palette.boldStyle(.accent) else palette.style(.muted)) catch {};
        }
        drawPageBarMetadata(metadata, palette, surface);
    }

    if (surface.size().height <= shell_layout.page_bar_rule_row) return;
    const rule_style = pageBarRuleStyle(palette);
    for (0..surface.size().width) |col| {
        _ = surface.borrowTextAt(
            @intCast(col),
            shell_layout.page_bar_rule_row,
            "─",
            rule_style,
        );
    }
}

const PageBarStatsText = struct {
    added: []const u8,
    removed: []const u8,
    added_width: u16,
    total_width: u16,
};

fn pageBarStatsText(surface: *chasen.Surface, stats: file_tree.Stats) ?PageBarStatsText {
    if (stats.complete and stats.added == 0 and stats.removed == 0) return null;
    const added = if (stats.complete) std.fmt.allocPrint(surface.frameAllocator(), "+{d}", .{stats.added}) catch return null else "+?";
    const removed = if (stats.complete) std.fmt.allocPrint(surface.frameAllocator(), "-{d}", .{stats.removed}) catch return null else "-?";
    const added_width = chasen.text.displayWidth(added);
    return .{
        .added = added,
        .removed = removed,
        .added_width = added_width,
        .total_width = added_width +| 1 +| chasen.text.displayWidth(removed),
    };
}

const PageBarRemoteActionText = struct {
    text: []const u8,
    width: u16,
};

fn pageBarRemoteActionText(
    surface: *chasen.Surface,
    actions: PageBarRemoteActions,
    available_width: u16,
) ?PageBarRemoteActionText {
    var push_buffer: [16]u8 = undefined;
    var pull_buffer: [16]u8 = undefined;
    const push_key = if (actions.push) actions.keymap.display(.push, push_buffer[0..]) else null;
    const pull_key = if (actions.pull) actions.keymap.display(.pull, pull_buffer[0..]) else null;

    if (push_key) |push| {
        if (pull_key) |pull| {
            if (pageBarRemoteActionCandidate(
                surface,
                available_width,
                "({s}: push / {s}: pull)",
                .{ push, pull },
            )) |candidate| return candidate;
        }
        return pageBarRemoteActionCandidate(
            surface,
            available_width,
            "({s}: push)",
            .{push},
        );
    }
    if (pull_key) |pull| {
        return pageBarRemoteActionCandidate(
            surface,
            available_width,
            "({s}: pull)",
            .{pull},
        );
    }
    return null;
}

fn pageBarRemoteActionCandidate(
    surface: *chasen.Surface,
    available_width: u16,
    comptime format: []const u8,
    args: anytype,
) ?PageBarRemoteActionText {
    const text = std.fmt.allocPrint(surface.frameAllocator(), format, args) catch return null;
    const width = chasen.text.displayWidth(text);
    if (width > available_width) return null;
    return .{ .text = text, .width = width };
}

fn drawPageBarMetadata(metadata: PageBarMetadata, palette: theme.Palette, surface: *chasen.Surface) void {
    const size = surface.size();
    const context_start = page.tabExtent() +| 1;
    if (context_start >= size.width) return;

    // All page metadata keeps one terminal cell clear at the right edge.
    var context_right = size.width - 1;
    const stats_text = if (metadata.line_stats) |stats| pageBarStatsText(surface, stats) else null;
    const metadata_width = context_right -| context_start;
    const stats_drawable = if (stats_text) |text| text.total_width <= metadata_width else false;

    if (stats_drawable) {
        const text = stats_text.?;
        const stats_right = context_right;
        const stats_col = stats_right - text.total_width;
        draw.copyClippedTextAt(
            surface,
            stats_col,
            shell_layout.page_bar_label_row,
            text.added,
            .{ .fg = palette.color(.success), .bold = true },
        ) catch {};
        draw.copyClippedTextAt(
            surface,
            stats_col +| text.added_width +| 1,
            shell_layout.page_bar_label_row,
            text.removed,
            .{ .fg = palette.color(.danger), .bold = true },
        ) catch {};
        context_right = stats_col -| 2;
    }

    // Keep diff totals at the right edge; remote hints use the remaining width.
    if (metadata.remote_actions) |actions| if (pageBarRemoteActionText(surface, actions, context_right -| context_start)) |text| {
        const action_col = context_right - text.width;
        draw.copyClippedTextAt(
            surface,
            action_col,
            shell_layout.page_bar_label_row,
            text.text,
            palette.style(.muted),
        ) catch {};
        context_right = action_col -| 2;
    };

    const value = metadata.presentation orelse return;
    if (context_start >= context_right) return;
    const text = page_header.formatAlloc(
        surface.frameAllocator(),
        value,
        context_right - context_start,
    ) catch null;
    const repository_context = text orelse return;
    const text_width = chasen.text.displayWidth(repository_context);
    const col = context_right -| text_width;
    if (col < context_start) return;
    draw.copyClippedTextAt(
        surface,
        col,
        shell_layout.page_bar_label_row,
        repository_context,
        switch (value.tone()) {
            .fact => palette.style(.info),
            .terminal => palette.style(.muted),
        },
    ) catch {};
}

fn pageBarRuleStyle(palette: theme.Palette) chasen.TextStyle {
    return .{ .fg = palette.color(.muted), .dim = true };
}

fn viewPlaceholderPage(id: page.Id, has_repository: bool, palette: theme.Palette, surface: *chasen.Surface) void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;
    const row = size.height / 2;
    draw.copyClippedTextAt(surface, 1, row, id.label(), palette.boldStyle(.accent)) catch {};
    const description = if (!has_repository and (id == .repository or id == .history or id == .compare))
        "Repository required"
    else
        id.placeholderDescription();
    if (row + 1 < size.height) draw.copyClippedTextAt(surface, 1, row + 1, description, palette.style(.muted)) catch {};
}

pub const FooterStatusTarget = struct {
    start_col: u16,
    end_col: u16,
    text: []const u8,

    pub fn contains(self: FooterStatusTarget, col: u16) bool {
        return col >= self.start_col and col < self.end_col;
    }
};

const footer_hint_capacity: usize = 9;

const FooterHintPriority = enum {
    repository_switch,
    primary,
    compare_base,
    help,
    secondary,
};

const FooterHints = struct {
    items: [footer_hint_capacity]ui.key_hint.Item = undefined,
    priorities: [footer_hint_capacity]FooterHintPriority = undefined,
    len: usize = 0,

    fn slice(self: *const FooterHints) []const ui.key_hint.Item {
        return self.items[0..self.len];
    }

    fn append(self: *FooterHints, item: ui.key_hint.Item, priority: FooterHintPriority) void {
        if (self.len >= self.items.len) return;
        self.items[self.len] = item;
        self.priorities[self.len] = priority;
        self.len += 1;
    }

    fn widthForPriority(
        self: *const FooterHints,
        priority: FooterHintPriority,
        opts: ui.key_hint.DrawOptions,
    ) u16 {
        var storage: [footer_hint_capacity]ui.key_hint.Item = undefined;
        var len: usize = 0;
        for (self.items[0..self.len], self.priorities[0..self.len]) |item, item_priority| {
            if (item_priority != priority) continue;
            storage[len] = item;
            len += 1;
        }
        return ui.key_hint.width(storage[0..len], opts);
    }
};

const FooterHintProjection = struct {
    items: [footer_hint_capacity]ui.key_hint.Item = undefined,
    len: usize = 0,

    fn slice(self: *const FooterHintProjection) []const ui.key_hint.Item {
        return self.items[0..self.len];
    }
};

const FooterProjection = struct {
    segments: FooterSegments,
    hints: FooterHintProjection,
    hint_col: u16,
    left_limit: u16,
    status_segment: ?usize,
};

/// Projects the exact status cells rendered by the common footer. Input uses
/// this projection too, so responsive segment dropping and clipped text cannot
/// drift away from the mouse hit target.
pub fn footerStatusTarget(app: Context, width: u16) ?FooterStatusTarget {
    if (app.repository.command_line != null) return null;
    if (width == 0) return null;
    if (app.action.spinnerPresentation() != null) return null;
    const visible = app_state.resolveVisibleStatus(app.status, app.page_status) orelse return null;

    var key_buffers: [footer_hint_capacity][16]u8 = undefined;
    const hints = footerHints(app, &key_buffers);
    const projection = projectFooter(app, width, &hints, null);
    const status_segment = projection.status_segment orelse return null;
    const range = projection.segments.renderedRange(status_segment, projection.left_limit) orelse return null;
    return .{
        .start_col = range.start_col,
        .end_col = range.end_col,
        .text = visible.text,
    };
}

fn viewFooter(app: Context, surface: *chasen.Surface) void {
    const width = surface.size().width;
    if (width == 0) return;

    var footer_key_buffers: [footer_hint_capacity][16]u8 = undefined;
    const hints = footerHints(app, &footer_key_buffers);
    const spinner_text = gitActionSpinnerText(app, surface.frameAllocator());
    const projection = projectFooter(app, width, &hints, spinner_text);

    var left_area = surface.child(.{
        .col = 0,
        .row = 0,
        .width = projection.left_limit,
        .height = 1,
    });
    projection.segments.render(&left_area, projection.left_limit);

    const hint_items = projection.hints.slice();
    if (hint_items.len > 0 and width > projection.hint_col) {
        var hint_area = surface.child(.{
            .col = projection.hint_col,
            .row = 0,
            .width = width - projection.hint_col,
            .height = 1,
        });
        _ = ui.key_hint.draw(&hint_area, 0, 0, hint_items, footerKeyHintOptions(app.theme)) catch {};
    }
}

fn projectFooter(
    app: Context,
    width: u16,
    hints: *const FooterHints,
    spinner_text: ?[]const u8,
) FooterProjection {
    const hint_options = footerKeyHintOptions(app.theme);
    const essential_hint_width = hints.widthForPriority(.repository_switch, hint_options);
    const essential_reserve = if (essential_hint_width == 0)
        0
    else
        essential_hint_width +| 1;
    var footer_segments = FooterSegments{};
    if (app.active_page == .changes) {
        const changes_footer = app.changes.footer();
        if (changes_footer.source_label) |label| footer_segments.append(.{
            .text = label,
            .style = app.theme.style(.prompt),
            .drop_priority = .source,
        });
        if (changes_footer.activation) |activation| footer_segments.append(.{
            .text = switch (activation) {
                .stale => "stale",
            },
            .style = switch (activation) {
                .stale => app.theme.style(.danger),
            },
            .drop_priority = .source,
        });
    }
    if (app.active_page == .history) {
        if (app.history) |history| {
            if (history.page_state.current_view == .picker and history.page_state.draft.isRange()) {
                footer_segments.append(.{
                    .text = history_view.range_footer_text,
                    .style = app.theme.style(.accent),
                    .drop_priority = .source,
                });
            }
        }
    }
    const committed_footer = switch (app.active_page) {
        .history => if (app.history) |history|
            if (history.page_state.current_view == .diff) history.footer() else null
        else
            null,
        .compare => app.compare.footer(),
        else => null,
    };
    if (committed_footer) |footer| {
        if (footer.source_label) |label| footer_segments.append(.{
            .text = label,
            .style = app.theme.style(.prompt),
            .drop_priority = .source,
        });
        if (footer.activation) |activation| footer_segments.append(.{
            .text = switch (activation) {
                .stale => "stale",
            },
            .style = switch (activation) {
                .stale => app.theme.style(.danger),
            },
            .drop_priority = .source,
        });
    }
    var status_segment: ?usize = null;
    if (spinner_text) |text| {
        footer_segments.append(.{
            .text = text,
            .style = app.theme.style(.prompt),
        });
    } else if (app.status.text().len > 0) {
        if (footer_segments.len < footer_segments.items.len) {
            status_segment = footer_segments.len;
            footer_segments.append(.{
                .text = app.status.text(),
                .style = app.theme.style(.prompt),
            });
        }
    } else if (app.page_status) |page_status| {
        if (page_status.text().len > 0 and footer_segments.len < footer_segments.items.len) {
            status_segment = footer_segments.len;
            footer_segments.append(.{
                .text = page_status.text(),
                .style = app.theme.style(.prompt),
            });
        }
    }

    footer_segments.fit(width -| essential_reserve);

    const segment_width = footer_segments.requiredWidth();
    const hint_budget = if (segment_width == 0)
        width
    else if (width > segment_width)
        width - segment_width - 1
    else
        0;
    const projected_hints = projectFooterHints(hints, hint_budget, hint_options);
    const hint_width = ui.key_hint.width(projected_hints.slice(), hint_options);
    var hint_col = if (hint_width == 0) width else width -| hint_width;
    if (hint_col > segment_width +| 1) hint_col -= 1;
    const left_limit = if (projected_hints.len == 0) width else hint_col;

    return .{
        .segments = footer_segments,
        .hints = projected_hints,
        .hint_col = hint_col,
        .left_limit = left_limit,
        .status_segment = status_segment,
    };
}

fn projectFooterHints(
    hints: *const FooterHints,
    width: u16,
    opts: ui.key_hint.DrawOptions,
) FooterHintProjection {
    var result: FooterHintProjection = .{};
    if (width == 0 or hints.len == 0) return result;

    const priority_order = [_]FooterHintPriority{
        .repository_switch,
        .primary,
        .compare_base,
        .help,
        .secondary,
    };
    var selected = [_]bool{false} ** footer_hint_capacity;
    var selected_count: usize = 0;
    var used_width: usize = 0;
    const separator_width = chasen.text.displayWidth(opts.separator);

    for (priority_order) |priority| {
        for (hints.items[0..hints.len], hints.priorities[0..hints.len], 0..) |_, item_priority, index| {
            if (item_priority != priority) continue;
            const item_width: usize = ui.key_hint.width(hints.items[index .. index + 1], opts);
            const needed = item_width + if (selected_count == 0) @as(usize, 0) else separator_width;
            if (used_width + needed > width) continue;
            selected[index] = true;
            selected_count += 1;
            used_width += needed;
        }
    }

    for (hints.items[0..hints.len], selected[0..hints.len]) |item, keep| {
        if (!keep) continue;
        result.items[result.len] = item;
        result.len += 1;
    }
    return result;
}

const FooterDropPriority = enum {
    source,
};

const FooterSegment = struct {
    text: []const u8,
    style: chasen.TextStyle,
    drop_priority: ?FooterDropPriority = null,
    visible: bool = true,
};

const FooterCellRange = struct {
    start_col: u16,
    end_col: u16,
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
        const order = [_]FooterDropPriority{.source};
        for (order) |priority| {
            if (self.requiredWidth() <= width) return;
            self.drop(priority);
        }
    }

    fn drop(self: *FooterSegments, priority: FooterDropPriority) void {
        for (self.items[0..self.len]) |*item| {
            if (item.drop_priority != null and item.drop_priority.? == priority) {
                item.visible = false;
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

    fn renderedRange(self: *const FooterSegments, target_index: usize, width: u16) ?FooterCellRange {
        var col: u16 = 1;
        for (self.items[0..self.len], 0..) |item, index| {
            if (!item.visible or item.text.len == 0) continue;
            if (col >= width) return null;
            const available = width - col;
            const clipped = chasen.text.clipToWidthWithMarker(item.text, available, "…");
            const drawn_width: u16 = @intCast(
                chasen.text.displayWidth(clipped.prefix) + chasen.text.displayWidth(clipped.marker),
            );
            if (index == target_index) {
                if (drawn_width == 0) return null;
                return .{
                    .start_col = col,
                    .end_col = col + drawn_width,
                };
            }
            const segment_width = chasen.text.displayWidth(item.text);
            col +|= @intCast(@min(segment_width + 2, std.math.maxInt(u16)));
        }
        return null;
    }

    fn endCol(self: *const FooterSegments) u16 {
        return self.requiredWidth();
    }
};

fn gitActionSpinnerText(app: Context, allocator: std.mem.Allocator) ?[]const u8 {
    const presentation = app.action.spinnerPresentation() orelse return null;
    const spinner = ui.Spinner.init(.{});
    if (isRemoteActionKind(presentation.kind) and app.remote_cancelable) {
        if (app.remote_canceling) {
            return std.fmt.allocPrint(allocator, "{s} canceling...", .{spinner.frameAt(presentation.tick)}) catch "canceling...";
        }
        const remote_label = if (visibleStatus(app).len > 0)
            visibleStatus(app)
        else
            pendingActionFallbackLabel(presentation.kind);
        return std.fmt.allocPrint(allocator, "{s} {s}  Esc: cancel", .{ spinner.frameAt(presentation.tick), remote_label }) catch remote_label;
    }
    const label = if (visibleStatus(app).len > 0)
        visibleStatus(app)
    else
        pendingActionFallbackLabel(presentation.kind);
    return std.fmt.allocPrint(allocator, "{s} {s}", .{ spinner.frameAt(presentation.tick), label }) catch label;
}

fn isRemoteActionKind(kind: app_actions.ActionKind) bool {
    return switch (kind) {
        .push, .pull, .fetch => true,
        else => false,
    };
}

fn visibleStatus(app: Context) []const u8 {
    const visible = app_state.resolveVisibleStatus(app.status, app.page_status) orelse return "";
    return visible.text;
}

fn pendingActionFallbackLabel(kind: app_actions.ActionKind) []const u8 {
    return switch (kind) {
        .stage_file => "stage",
        .unstage_file => "unstage",
        .stage_hunk => "hunk stage",
        .unstage_hunk => "hunk unstage",
        .discard_file => "discard",
        .commit => "commit",
        .amend => "amend",
        .push => "push",
        .pull => "pull",
        .fetch => "fetch",
        .switch_branch => "switch",
        .create_stash => "stash",
        .apply_stash => "apply stash",
        .drop_stash => "drop stash",
    };
}

fn footerKeyHintOptions(palette: theme.Palette) ui.key_hint.DrawOptions {
    return .{
        .style = palette.style(.muted),
        .key_style = palette.boldStyle(.muted),
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

fn viewRepoPicker(app: Context, surface: *chasen.Surface) !void {
    const opts: ui.Modal.ViewOptions = .{
        .dialog_width = @min(surface.size().width, repo_picker_dialog_width),
        .dialog_height = @min(surface.size().height, 18),
        .title = "Switch repository",
        .backdrop = false,
        .border = .rounded,
        .title_style = app.theme.boldStyle(.accent),
    };
    const frame = ui.Modal.frame(surface, opts) orelse return;
    fillModalDialog(frame);
    frame.view();
    var content = frame.contentSurface();
    const size = content.size();

    switch (app.repo_picker.input_mode) {
        .list => _ = content.borrowTextAt(0, 0, "Repository list", app.theme.boldStyle(.prompt)),
        .filter => {
            _ = content.borrowTextAt(0, 0, "Filter: ", app.theme.boldStyle(.prompt));
            try drawCommitInputLine(&content, repo_picker_filter_input_col, 0, app.repo_picker.list.input.slice(), app.repo_picker.list.input.cursor, app.theme.style(.prompt));
            view_primitives.showInputCursor(&content, repo_picker_filter_input_col, 0, app.repo_picker.list.input.slice(), app.repo_picker.list.input.cursor);
        },
        .path_input => {
            _ = content.borrowTextAt(0, 0, "Repo path: ", app.theme.boldStyle(.prompt));
            try drawCommitInputLine(&content, repo_picker_path_input_col, 0, app.repo_picker.path_input.slice(), app.repo_picker.path_input.cursor, app.theme.style(.prompt));
            view_primitives.showInputCursor(&content, repo_picker_path_input_col, 0, app.repo_picker.path_input.slice(), app.repo_picker.path_input.cursor);
        },
    }

    const has_path_status = app.repo_picker.path_pending or app.repo_picker.path_error != null;
    if (size.height > 1 and has_path_status) {
        if (app.repo_picker.path_pending) {
            _ = content.borrowTextAt(0, 1, "checking path...", app.theme.style(.muted));
        } else if (app.repo_picker.path_error) |err| {
            try draw.copyClippedTextAt(&content, 0, 1, err.message(), app.theme.style(.danger));
        }
    }

    if (size.height <= 3) return;
    const layout = repoPickerLayout(size.height, has_path_status);
    const list_title = try app_repo_picker.listTitle(
        content.frameAllocator(),
        app.repo_picker_pending_workspace_root,
        app.committed_repo_discovery_kind,
        app.repo_picker_has_recent,
    );
    const list_title_style: chasen.TextStyle = if (app.repo_picker.input_mode == .path_input)
        app.theme.style(.muted)
    else
        app.theme.boldStyle(.accent);
    try draw.copyClippedTextAt(&content, 0, layout.list_title_row, list_title, list_title_style);

    defer {
        if (layout.footer_rows > 0) {
            const has_row = app.repo_picker.list.filter.labels.len > 0;
            drawRepoPickerFooter(&content, layout.footer_row, app.repo_picker.input_mode, has_row, app.theme);
        }
    }

    if (app.repo_picker.list.filter.labels.len == 0) {
        if (size.height > layout.list_start_row) {
            const empty_text = if (app.repo_picker.input_mode == .filter and app.repo_picker.list.input.len > 0)
                "No matching repositories."
            else
                "No recent repositories yet.";
            _ = content.borrowTextAt(2, layout.list_start_row, empty_text, app.theme.style(.muted));
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
        const item = if (source_index < app.repo_picker_items.len) app.repo_picker_items[source_index] else null;
        const list_active = app.repo_picker.input_mode == .list or app.repo_picker.input_mode == .filter;
        const focused_row = list_active and visible_index == focused;
        const active = if (item) |repo_item|
            switch (repo_item.source) {
                .active_repo => true,
                .workspace_repo => |repo_index| repo_index == app.active_repo_index,
                .pending_workspace_repo, .recent_repo, .recent_workspace => false,
            }
        else
            false;
        const style: chasen.TextStyle = if (focused_row)
            .{ .reverse = true, .bold = true }
        else if (active)
            .{ .fg = app.theme.color(.staged), .bold = true, .dim = !list_active }
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
            if (source_index < app.repo_picker_items.len) {
                const detail = app.repo_picker_items[source_index].detail;
                var detail_area = content.child(.{
                    .col = detail_col,
                    .row = detail_row,
                    .width = detail_text_width,
                    .height = 1,
                });
                try draw.copyClippedTextAt(&detail_area, 0, 0, detail, app.theme.style(.muted));
            }
        }
        if (position_width > 0 and size.width > position_width) {
            try draw.copyClippedTextAt(&content, size.width - position_width, detail_row, position_text, app.theme.style(.muted));
        }
    }
}

fn drawRepoPickerFooter(surface: *chasen.Surface, row: u16, input_mode: app_prompt.RepoPickerInputMode, has_row: bool, palette: theme.Palette) void {
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

    const opts = footerKeyHintOptions(palette);
    _ = ui.key_hint.draw(surface, 0, row, items, opts) catch {};
}

fn viewCommitPanel(app: Context, surface: *chasen.Surface) !void {
    const title_style: chasen.TextStyle = if (app.commit_panel.mode == .amend)
        app.theme.boldStyle(.amend)
    else
        app.theme.boldStyle(.accent);
    const opts: ui.Modal.ViewOptions = .{
        .dialog_width = @min(surface.size().width, commit_dialog_width),
        .dialog_height = @min(surface.size().height, commit_dialog_height),
        .title = app.commit_panel.title(),
        .backdrop = false,
        .border = .rounded,
        .title_style = title_style,
    };
    const frame = ui.Modal.frame(surface, opts) orelse return;
    fillModalDialog(frame);
    frame.view();
    var content = frame.contentSurface();
    const size = content.size();

    const staged_text = try stagedSummaryText(content.frameAllocator(), app.staged_summary);
    try draw.copyClippedTextAt(&content, 0, 0, staged_text, app.theme.style(.muted));

    const help_rows = commitHelpRows(size.width);
    const help_start_row = if (size.height > help_rows) size.height - help_rows else 0;
    const error_row = if (help_start_row > 0) help_start_row - 1 else help_start_row;
    const field_limit_row = if (size.height > 2) error_row else help_start_row;

    if (size.height > 2 and 2 < field_limit_row) {
        const active = app.commit_panel.active_field == .subject;
        const label_style: chasen.TextStyle = commitFieldLabelStyle(app, active);
        _ = content.borrowTextAt(0, 2, if (active) ">" else " ", label_style);
        _ = content.borrowTextAt(2, 2, "Subject:", label_style);
        try drawCommitCounter(&content, 2, app.commit_panel.subjectCharCount(), app_commit_panel.max_subject_chars, app.theme);
        const input_col: u16 = @min(2, size.width);
        if (size.height > 3 and 3 < field_limit_row and size.width > input_col) {
            const cursor = if (active) app.commit_panel.subject.cursor else null;
            const input_style: chasen.TextStyle = if (app.commit_panel.mode == .amend) .{} else app.theme.style(.prompt);
            try drawCommitInputLine(&content, input_col, 3, app.commit_panel.subject.slice(), cursor, input_style);
            if (active) view_primitives.showInputCursor(&content, input_col, 3, app.commit_panel.subject.slice(), app.commit_panel.subject.cursor);
        }
    }

    if (size.height > 5 and 5 < field_limit_row) {
        const active = app.commit_panel.active_field == .body;
        const label_style: chasen.TextStyle = commitFieldLabelStyle(app, active);
        _ = content.borrowTextAt(0, 5, if (active) ">" else " ", label_style);
        _ = content.borrowTextAt(2, 5, "Body:", label_style);
        try drawCommitCounter(&content, 5, app.commit_panel.bodyCharCount(), null, app.theme);
    }

    if (size.height > 6 and error_row > 6) {
        var body_area = content.child(.{
            .col = 2,
            .row = 6,
            .width = if (size.width > 2) size.width - 2 else 0,
            .height = error_row - 6,
        });
        try viewCommitBody(&app.commit_panel.body, &body_area, app.commit_panel.active_field == .body, app.theme);
        if (app.commit_panel.active_field == .body) showBodyInputCursor(&body_area, &app.commit_panel.body);
    }

    if (size.height > 2) {
        if (app.commit_panel.commit_error) |err| {
            try draw.copyClippedTextAt(&content, 0, error_row, err.message(), app.theme.style(.danger));
        }
    }

    try viewCommitHelp(app, &content, help_start_row, help_rows);
}

fn drawCommitCounter(surface: *chasen.Surface, row: u16, len: usize, max: ?usize, palette: theme.Palette) !void {
    const size = surface.size();
    if (row >= size.height or size.width == 0) return;

    const counter = if (max) |limit|
        try std.fmt.allocPrint(surface.frameAllocator(), "{d}/{d}", .{ len, limit })
    else
        try std.fmt.allocPrint(surface.frameAllocator(), "{d}", .{len});
    const counter_width = chasen.text.displayWidth(counter);
    if (counter_width >= size.width) return;

    const col = size.width - counter_width;
    try draw.copyClippedTextAt(surface, col, row, counter, palette.style(.muted));
}

fn commitHelpRows(width: u16) u16 {
    const single_line = "Tab: field  Enter: newline  Ctrl+y: copy  Ctrl+s/Ctrl+Enter: validate  Esc: close";
    return if (chasen.text.displayWidth(single_line) <= width) 1 else 2;
}

fn viewCommitHelp(app: Context, surface: *chasen.Surface, start_row: u16, rows: u16) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0 or start_row >= size.height) return;

    const style: chasen.TextStyle = app.theme.style(.muted);
    const submit_label = app.commit_panel.submitLabel();
    if (rows <= 1) {
        const text = try std.fmt.allocPrint(surface.frameAllocator(), "Tab: field  Enter: newline  Ctrl+y: copy  Ctrl+s/Ctrl+Enter: {s}  Esc: close", .{submit_label});
        try draw.copyClippedTextAt(surface, 0, start_row, text, style);
        return;
    }

    try draw.copyClippedTextAt(surface, 0, start_row, "Tab: field  Enter: newline  Ctrl+y: copy", style);
    if (start_row + 1 < size.height) {
        const line2 = try std.fmt.allocPrint(surface.frameAllocator(), "Ctrl+s/Ctrl+Enter: {s}  Esc: close", .{submit_label});
        try draw.copyClippedTextAt(surface, 0, start_row + 1, line2, style);
    }
}

fn commitFieldLabelStyle(app: Context, active: bool) chasen.TextStyle {
    if (active and app.commit_panel.mode == .amend) return app.theme.boldStyle(.amend);
    if (active) return app.theme.boldStyle(.accent);
    return .{ .bold = true };
}

fn viewCommitBody(body: *const app_commit_panel.BodyText, surface: *chasen.Surface, active: bool, palette: theme.Palette) !void {
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
        try draw.copyClippedTextAt(surface, 0, size.height - 1, indicator, palette.style(.muted));
    }
}

fn viewDiscardConfirmation(app: Context, surface: *chasen.Surface) !void {
    const confirmation = app.discard_confirmation orelse return;
    const opts: ui.Modal.ViewOptions = .{
        .dialog_width = @min(surface.size().width, confirmation_dialog_width),
        .dialog_height = @min(surface.size().height, confirmation_dialog_height),
        .title = "Discard file changes?",
        .backdrop = false,
        .border = .rounded,
        .title_style = app.theme.boldStyle(.danger),
        .border_style = app.theme.style(.danger),
    };
    const frame = ui.Modal.frame(surface, opts) orelse return;
    fillModalDialog(frame);
    frame.view();
    var content = frame.contentSurface();
    const size = content.size();

    try drawCenteredText(&content, 0, "This will discard unstaged tracked changes.", app.theme.style(.danger));
    if (size.height > 2) {
        try drawCenteredLabelValue(&content, 2, "File:", confirmation.path, .{ .bold = true }, .{});
    }
    if (size.height > 4) {
        try drawCenteredText(&content, 4, "Enter: discard    Esc/q: cancel", app.theme.style(.danger));
    }
}

fn viewAmendConfirmation(app: Context, surface: *chasen.Surface) !void {
    _ = app.amend_confirmation orelse return;
    const opts: ui.Modal.ViewOptions = .{
        .dialog_width = @min(surface.size().width, confirmation_dialog_width),
        .dialog_height = @min(surface.size().height, confirmation_dialog_height),
        .title = "Amend last commit?",
        .backdrop = false,
        .border = .rounded,
        .title_style = app.theme.boldStyle(.amend),
        .border_style = app.theme.style(.amend),
    };
    const frame = ui.Modal.frame(surface, opts) orelse return;
    fillModalDialog(frame);
    frame.view();
    var content = frame.contentSurface();
    const size = content.size();

    const line_count: u16 = 3;
    const start_row: u16 = if (size.height > line_count) (size.height - line_count) / 2 else 0;
    try drawCenteredText(&content, start_row, "This rewrites the current branch history.", app.theme.style(.amend));
    if (start_row + 2 < size.height) {
        try drawCenteredText(&content, start_row + 2, "Enter: amend    Esc/q: cancel", app.theme.style(.amend));
    }
}

fn stashDisplay(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const path_key = @import("../path_key.zig");
    return if (path_key.isPlainDisplaySafe(raw)) raw else try path_key.quotedDisplayAlloc(allocator, raw);
}

fn viewStashes(app: Context, surface: *chasen.Surface) !void {
    const catalog = app.stash_catalog orelse return;
    const dropping = if (catalog.confirmation) |confirmation| confirmation.action == .drop else false;
    const frame = ui.Modal.frame(surface, .{
        .dialog_width = 108,
        .dialog_height = 22,
        .padding = .{ .left = 2, .right = 2, .top = 1, .bottom = 1 },
        .title = if (catalog.confirmation != null) (if (dropping) "Drop stash" else "Apply stash") else "Stashes",
        .backdrop = false,
        .border = .rounded,
        .title_style = app.theme.boldStyle(.accent),
        .border_style = app.theme.style(.accent),
    }) orelse return;
    fillModalDialog(frame);
    frame.view();
    var content = frame.contentSurface();
    const allocator = content.frameAllocator();
    const size = content.size();
    var branch_buffer: [96]u8 = undefined;
    if (catalog.confirmation) |confirmation| {
        const identity = try std.fmt.allocPrint(allocator, "{s} {s} ({s})", .{ if (dropping) "Drop" else "Apply", confirmation.selector, confirmation.oid[0..@min(12, confirmation.oid.len)] });
        try draw.copyClippedTextAt(&content, 0, 0, identity, app.theme.boldStyle(.accent));
        try draw.copyClippedTextAt(&content, 0, 2, try stashDisplay(allocator, confirmation.message), app.theme.style(.accent));
        const branch = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ if (dropping) "Current branch" else "To branch", try stashDisplay(allocator, confirmation.snapshot.branchLabel(&branch_buffer)) });
        try draw.copyClippedTextAt(&content, 0, 4, branch, app.theme.boldStyle(.prompt));
        const worktree = try std.fmt.allocPrint(allocator, "Worktree: {s}", .{try stashDisplay(allocator, confirmation.snapshot.repo_root)});
        var worktree_body = content.child(.{ .col = 0, .row = 6, .width = size.width, .height = @min(3, size.height -| 6) });
        _ = drawWrappedTextScrolled(&worktree_body, worktree, 0, app.theme.style(.muted));
        if (dropping) {
            _ = content.borrowTextAt(0, 9, "Delete the saved changes in this stash?", app.theme.boldStyle(.danger));
            _ = content.borrowTextAt(0, 10, "This removes the saved entry from the repository's stash list.", app.theme.style(.muted));
            _ = content.borrowTextAt(0, 12, "Current worktree changes will not be applied or discarded.", app.theme.style(.muted));
        } else {
            _ = content.borrowTextAt(0, 9, "The stash will be retained.", app.theme.style(.accent));
            _ = content.borrowTextAt(0, 10, "Staged / unstaged classification will not be restored.", app.theme.style(.muted));
            _ = content.borrowTextAt(0, 12, "Conflicts may leave changes to resolve in this worktree.", app.theme.style(.muted));
        }
        _ = content.borrowTextAt(0, size.height -| 1, if (dropping) "Enter: drop   Esc/q: back" else "Enter: apply   Esc/q: back", app.theme.style(.accent));
        return;
    }
    const destination = if (app.stash_target) |target| target.branch orelse (std.fmt.bufPrint(&branch_buffer, "detached@{s}", .{target.oid[0..@min(12, target.oid.len)]}) catch "detached") else "unavailable; reload before applying";
    const header = try std.fmt.allocPrint(allocator, "Apply to current branch: {s}", .{try stashDisplay(allocator, destination)});
    try draw.copyClippedTextAt(&content, 0, 0, header, app.theme.boldStyle(.accent));
    if (catalog.notice) |notice| try draw.copyClippedTextAt(&content, 0, 1, notice, app.theme.style(.danger));
    if (catalog.pending != null) {
        _ = content.borrowTextAt(0, 3, "Loading stashes...", app.theme.style(.muted));
    } else switch (catalog.result) {
        .empty => {},
        .failed, .failed_static => |detail| {
            try draw.copyClippedTextAt(&content, 0, 3, try stashDisplay(allocator, detail), app.theme.style(.danger));
            _ = content.borrowTextAt(0, 5, "Close and reopen Stashes to retry.", app.theme.style(.muted));
        },
        .loaded => |loaded| if (loaded.entries.len == 0) {
            _ = content.borrowTextAt(0, 3, "No stashes", app.theme.style(.muted));
        } else {
            const columns = [_]ui.ColumnList.Column{
                .{ .header = "Stash", .width = .{ .fixed = 12 } },
                .{ .header = "Created (local)", .width = .{ .fixed = 23 } },
                .{ .header = "Message", .width = .flex },
            };
            const rows = try allocator.alloc(ui.ColumnList.Row, loaded.entries.len);
            const cells = try allocator.alloc([3]ui.ColumnList.Cell, loaded.entries.len);
            for (loaded.entries, rows, cells) |entry, *row, *values| {
                const minute = local_time.formatMinute(entry.created);
                values.* = .{
                    .{ .text = entry.selector },
                    .{ .text = if (minute) |value| try allocator.dupe(u8, value.text()) else "unknown" },
                    .{ .text = try stashDisplay(allocator, entry.message) },
                };
                row.* = values;
            }
            var list = ui.ColumnList.init(.{ .columns = &columns, .rows = rows });
            list.focus = catalog.focus;
            var body = content.child(.{ .col = 0, .row = 2, .width = size.width, .height = size.height -| 4 });
            list.view(&body, .{ .show_header = true, .row_style = app.theme.style(.muted), .focused_style = app.theme.boldStyle(.accent), .marker_style = app.theme.style(.accent), .header_style = app.theme.boldStyle(.prompt), .show_cursor = false });
        },
    }
    _ = content.borrowTextAt(0, size.height -| 1, "Space: apply   d: drop   j/k/↑/↓: select   g: first   Esc/q: close", app.theme.style(.accent));
}

fn viewCreateStash(app: Context, surface: *chasen.Surface) !void {
    const dialog = app.create_stash orelse return;
    const frame = ui.Modal.frame(surface, .{
        .dialog_width = 84,
        .dialog_height = 17,
        .padding = .{ .left = 2, .right = 2, .top = 1, .bottom = 1 },
        .title = "Create stash",
        .backdrop = false,
        .border = .rounded,
        .title_style = app.theme.boldStyle(.accent),
        .border_style = app.theme.style(.accent),
    }) orelse return;
    fillModalDialog(frame);
    frame.view();
    var content = frame.contentSurface();
    const size = content.size();
    var branch_buffer: [96]u8 = undefined;
    const branch = try std.fmt.allocPrint(content.frameAllocator(), "Branch: {s}", .{dialog.snapshot.branchLabel(&branch_buffer)});
    try draw.copyClippedTextAt(&content, 0, 0, branch, app.theme.boldStyle(.accent));
    const target = app.stash_target;
    const target_matches = if (target) |value| dialog.snapshot.matchesTarget(value.branch, value.oid) else false;
    const has_staged = target_matches and target.?.has_staged;
    _ = content.borrowTextAt(0, 2, if (dialog.focus == .scope) "> Scope" else "  Scope", app.theme.boldStyle(.prompt));
    const all_radio = ui.Radio.init(.{ .selected = dialog.scope == .all, .label = "All changes" });
    var all_surface = content.child(.{ .col = 2, .row = 3, .width = size.width -| 2, .height = 1 });
    all_radio.view(&all_surface, .{
        .style = app.theme.style(.accent),
        .selected_style = app.theme.style(.accent),
        .label_style = app.theme.style(.accent),
        .show_cursor = false,
    });
    _ = content.borrowTextAt(4, 4, "Tracked + untracked; ignored files stay", app.theme.style(.muted));
    const staged_radio = ui.Radio.init(.{
        .selected = has_staged and dialog.scope == .staged,
        .label = if (has_staged) "Staged changes only" else "Staged changes only (unavailable)",
    });
    var staged_surface = content.child(.{ .col = 2, .row = 5, .width = size.width -| 2, .height = 1 });
    const staged_style = app.theme.style(if (has_staged) .accent else .muted);
    staged_radio.view(&staged_surface, .{
        .style = staged_style,
        .selected_style = staged_style,
        .label_style = staged_style,
        .show_cursor = false,
    });
    _ = content.borrowTextAt(4, 6, "Only staged changes; unstaged + untracked stay", app.theme.style(.muted));
    if (size.height > 8) {
        var field_surface = content.child(.{ .col = 0, .row = 8, .width = size.width, .height = @min(2, size.height - 8) });
        const field = ui.FormField.init(.{ .label = if (dialog.focus == .message) "> Message (optional)" else "  Message (optional)" });
        const opts: ui.FormField.ViewOptions = .{ .label_style = app.theme.boldStyle(.prompt) };
        field.view(&field_surface, opts);
        var input_surface = field_surface.child(field.contentRect(&field_surface, opts));
        dialog.message.view(&input_surface, .{ .style = app.theme.style(.accent), .placeholder_style = app.theme.style(.muted), .show_cursor = dialog.focus == .message });
    }
    const available = target_matches and (if (dialog.scope == .all) target.?.has_all else has_staged);
    _ = content.borrowTextAt(0, 11, if (!target_matches) "Target changed or unavailable; cancel and reload" else if (!available) "No changes in selected scope" else "Saved changes are not restored automatically", app.theme.style(if (available) .muted else .danger));
    _ = content.borrowTextAt(0, 12, if (available) "Enter: create   Tab: field   \xe2\x86\x91/\xe2\x86\x93: scope   Esc: cancel" else "Tab: field   \xe2\x86\x91/\xe2\x86\x93: scope   Esc: cancel", app.theme.style(.accent));
}

fn viewPushConfirmation(app: Context, surface: *chasen.Surface) !void {
    const confirmation = app.push_confirmation orelse return;
    const opts: ui.Modal.ViewOptions = .{
        .dialog_width = @min(surface.size().width, confirmation_dialog_width),
        .dialog_height = @min(surface.size().height, confirmation_dialog_height),
        .title = "Push current branch?",
        .backdrop = false,
        .border = .rounded,
        .title_style = app.theme.boldStyle(.accent),
        .border_style = app.theme.style(.accent),
    };
    const frame = ui.Modal.frame(surface, opts) orelse return;
    fillModalDialog(frame);
    frame.view();
    var content = frame.contentSurface();
    const size = content.size();

    const target = try std.fmt.allocPrint(content.frameAllocator(), "{s} -> {s}/{s}", .{ confirmation.branch, confirmation.remote, confirmation.remote_branch });
    const detail = switch (confirmation.mode) {
        .upstream => if (confirmation.ahead_behind) |ahead_behind|
            try std.fmt.allocPrint(content.frameAllocator(), "ahead {d} / behind {d}", .{ ahead_behind.ahead, ahead_behind.behind })
        else
            "ahead/behind unavailable",
        .set_upstream => "will set upstream",
    };
    const line_count: u16 = 5;
    const start_row: u16 = if (size.height > line_count) (size.height - line_count) / 2 else 0;
    try drawCenteredText(&content, start_row, target, app.theme.boldStyle(.accent));
    if (start_row + 2 < size.height) {
        try drawCenteredText(&content, start_row + 2, detail, app.theme.style(.muted));
    }
    if (start_row + 4 < size.height) {
        try drawCenteredText(&content, start_row + 4, "Enter: push    Esc/q: cancel", app.theme.style(.accent));
    }
}

fn viewPullConfirmation(app: Context, surface: *chasen.Surface) !void {
    const confirmation = app.pull_confirmation orelse return;
    const opts: ui.Modal.ViewOptions = .{
        .dialog_width = @min(surface.size().width, confirmation_dialog_width),
        .dialog_height = @min(surface.size().height, confirmation_dialog_height),
        .title = "Fetch, then fast-forward?",
        .backdrop = false,
        .border = .rounded,
        .title_style = app.theme.boldStyle(.accent),
        .border_style = app.theme.style(.accent),
    };
    const frame = ui.Modal.frame(surface, opts) orelse return;
    fillModalDialog(frame);
    frame.view();
    var content = frame.contentSurface();
    const size = content.size();

    const target = try std.fmt.allocPrint(content.frameAllocator(), "Fetch {s}, then fast-forward {s} if behind?", .{ confirmation.remote, confirmation.branch });
    const counts = try std.fmt.allocPrint(content.frameAllocator(), "ahead {d} / behind {d}", .{ confirmation.ahead, confirmation.behind });
    const line_count: u16 = 5;
    const start_row: u16 = if (size.height > line_count) (size.height - line_count) / 2 else 0;
    try drawCenteredText(&content, start_row, target, app.theme.boldStyle(.accent));
    if (start_row + 2 < size.height) {
        try drawCenteredText(&content, start_row + 2, counts, app.theme.style(.muted));
    }
    if (start_row + 4 < size.height) {
        try drawCenteredText(&content, start_row + 4, "Enter: fetch + ff-only    Esc/q: cancel", app.theme.style(.accent));
    }
}

fn viewBranchSwitchPopup(app: Context, surface: *chasen.Surface) !void {
    const state = app.branch_switch;
    if (!state.hasState()) return;

    const frame = branch_picker.viewFrame(surface, app.theme, "Switch branch") orelse return;
    var content = frame.contentSurface();
    const size = content.size();
    if (size.height == 0) return;
    const body_end = size.height -| branch_picker.footer_rows;

    const subtitle = try std.fmt.allocPrint(content.frameAllocator(), "Current branch: {s}", .{if (state.loading) "loading..." else state.current_branch});
    if (body_end > 0) try draw.copyClippedTextAt(&content, 0, 0, subtitle, app.theme.style(.muted));
    if (state.loading) {
        if (body_end > 3) try draw.copyClippedTextAt(&content, 0, 3, "Loading local branches...", app.theme.style(.prompt));
        return;
    }
    if (state.branches.len == 0) {
        if (body_end > 3) try draw.copyClippedTextAt(&content, 0, 3, "No local branches", app.theme.style(.muted));
        return;
    }

    if (body_end > 2) {
        try branch_picker.viewFilter(&content, 2, app.theme, .{
            .query = state.query.slice(),
            .query_mode = state.query_mode,
            .show_cursor = !state.worktree_pending,
        });
    }

    const selected_branch = state.selectedItem();
    if (selected_branch) |branch| {
        const action = branch.action(state.current_branch);
        if (body_end > 3) {
            const note = switch (action) {
                .close => "Current branch; no changes.",
                .checkout => "Carry uncommitted changes to target; abort if unsafe.",
                .open_worktree => "Leave uncommitted changes here; open target worktree.",
            };
            try draw.copyClippedTextAt(&content, 0, 3, note, app.theme.style(.muted));
        }
        if (body_end > 4) {
            if (action == .open_worktree) {
                try draw.copyClippedTextAt(&content, 0, 4, "Worktree: ", app.theme.style(.muted));
                try draw.copyTailClippedTextAt(&content, 10, 4, branch.worktree_path.?, app.theme.style(.muted));
            } else {
                try draw.copyClippedTextAt(&content, 0, 4, "@: open worktree (changes stay here)", app.theme.style(.muted));
            }
        }
        if (body_end > 5) {
            const exact = local_time.formatExact(branch.tip_committer_unix);
            const detail = if (exact) |value|
                try std.fmt.allocPrint(content.frameAllocator(), "last commit: {s}", .{value.text()})
            else
                "last commit: unknown";
            try draw.copyClippedTextAt(&content, 0, 5, detail, app.theme.style(.muted));
        }
    }
    const list_start: u16 = 7;
    const list_rows: u16 = body_end -| list_start;
    const visible_count = state.visibleCount();
    const selected = state.selected_index;
    const start = branch_picker.listWindowStart(selected, visible_count, list_rows);
    if (visible_count == 0 and list_rows > 0) {
        const message = try std.fmt.allocPrint(content.frameAllocator(), "No branches match \"{s}\"", .{state.query.slice()});
        try draw.copyClippedTextAt(&content, 0, list_start, message, app.theme.style(.muted));
    }
    var row: u16 = 0;
    while (row < list_rows and start + row < visible_count) : (row += 1) {
        const visible_index = start + row;
        const branch = state.branches[state.sourceIndex(visible_index) orelse continue];
        const focused = visible_index == selected;
        const marker: []const u8 = if (focused) ">" else " ";
        const current: []const u8 = if (branch.current) "*" else if (branch.worktree_path != null) "@" else " ";
        if (size.width > 0) {
            try draw.copyClippedTextAt(&content, 0, list_start + row, marker, app.theme.style(.accent));
        }
        if (size.width > 2) {
            try draw.copyClippedTextAt(
                &content,
                2,
                list_start + row,
                current,
                if (branch.current) app.theme.boldStyle(.prompt) else if (focused) app.theme.boldStyle(.accent) else app.theme.style(.muted),
            );
        }

        const relative = branch_commit_time.formatRelative(branch.tip_committer_unix, state.render_now_unix);
        const time_field_width: u16 = if (size.width >= 24) 14 else 0;
        const time_col = size.width - time_field_width;
        if (time_field_width > 0) {
            const relative_width = content.displayWidth(relative.text());
            const rendered_relative_width = @min(relative_width, time_field_width);
            try draw.copyClippedTextAt(
                &content,
                time_col + time_field_width - rendered_relative_width,
                list_start + row,
                relative.text(),
                if (focused) app.theme.boldStyle(.accent) else app.theme.style(.muted),
            );
        }

        const branch_col: u16 = @min(size.width, 4);
        const branch_end = if (time_field_width > 0) time_col -| 1 else size.width;
        if (branch_end > branch_col) {
            var branch_surface = content.child(.{
                .col = branch_col,
                .row = list_start + row,
                .width = branch_end - branch_col,
                .height = 1,
            });
            try draw.copyClippedTextAt(
                &branch_surface,
                0,
                0,
                branch.name,
                if (focused) app.theme.boldStyle(.accent) else chasen.TextStyle{},
            );
        }
    }

    if (size.height >= 2) {
        const hint_row = size.height - 1;
        const selection_hint = if (selected_branch) |branch| switch (branch.action(state.current_branch)) {
            .close => "Enter: close  ",
            .checkout => "Enter: checkout  ",
            .open_worktree => "Enter: open worktree  ",
        } else "";
        const hint = if (state.worktree_pending)
            "Checking worktree...    Esc/q: cancel"
        else if (state.query_mode)
            try std.fmt.allocPrint(content.frameAllocator(), "Type: filter  Up/Down: move  {s}Tab: command  Esc: clear", .{selection_hint})
        else
            try std.fmt.allocPrint(content.frameAllocator(), "/: filter  j/k: move  {s}{s}", .{
                selection_hint,
                if (state.query.len > 0) "Esc: clear  q: cancel" else "Esc/q: cancel",
            });
        try draw.copyClippedTextAt(&content, 0, hint_row, hint, app.theme.style(.accent));
    }
}

fn viewRemoteError(app: Context, surface: *chasen.Surface) !void {
    const operation = app.remote_error_operation orelse return;
    const message = std.mem.trimEnd(u8, app.remote_error_message orelse return, "\r\n");
    const opts = remoteErrorModalOptions(surface.size(), message, operation);

    const opts_with_title: ui.Modal.ViewOptions = .{
        .dialog_width = opts.dialog_width,
        .dialog_height = opts.dialog_height,
        .title = switch (operation) {
            .push => "Push failed",
            .pull => "Pull failed",
            .switch_branch => "Branch switch failed",
            .create_stash => "Stash creation failed",
            .apply_stash => "Stash apply failed",
            .drop_stash => "Stash drop failed",
        },
        .backdrop = false,
        .border = .rounded,
        .title_style = app.theme.boldStyle(.danger),
        .border_style = app.theme.style(.danger),
    };
    const frame = ui.Modal.frame(surface, opts_with_title) orelse return;
    fillModalDialog(frame);
    frame.view();
    var content = frame.contentSurface();
    const size = content.size();

    if (size.height > 0) {
        const heading = switch (operation) {
            .push => "Git push failed. Details:",
            .pull => "Git pull failed. Details:",
            .switch_branch => "Git branch switch failed. Details:",
            .create_stash => "Git stash failed. Details:",
            .apply_stash => "Git stash apply failed. Details:",
            .drop_stash => "Git stash drop failed. Details:",
        };
        try draw.copyClippedTextAt(&content, 0, 0, heading, app.theme.boldStyle(.danger));
    }

    const reserved_rows: u16 = if (operation == .switch_branch) 6 else 4;
    var drawn_rows: u16 = 0;
    if (size.height > reserved_rows) {
        var body = content.child(.{
            .col = 0,
            .row = 2,
            .width = size.width,
            .height = size.height - reserved_rows,
        });
        drawn_rows = @intCast(drawWrappedTextScrolled(&body, message, app.overlay.remote_error_scroll, .{}));
    }

    var footer_row = size.height -| 1;
    if (operation == .switch_branch and size.height > reserved_rows) {
        var key_buffer: [64]u8 = undefined;
        if (app.keymap.display(.create_stash, &key_buffer)) |key| {
            const hint = try std.fmt.allocPrint(content.frameAllocator(), "If local changes block switching: close, then use {s}: stash on Changes.", .{key});
            const hint_row = 2 + drawn_rows + 1;
            try draw.copyClippedTextAt(&content, 0, hint_row, hint, app.theme.style(.accent));
            footer_row = hint_row + 2;
        }
    }

    if (size.height > 0) {
        const footer = remoteErrorFooter(operation, app.push_retry_inspecting, app.push_retry_target != null);
        try draw.copyClippedTextAt(&content, 0, footer_row, footer, app.theme.style(.danger));
    }
}

fn remoteErrorFooter(operation: app_state.GitErrorOperation, inspecting: bool, retry_available: bool) []const u8 {
    if (operation != .push) return "y: copy  Enter/Esc/q: close";
    if (inspecting) return "checking push target...  y: copy  Enter/Esc/q: cancel";
    if (retry_available) return "i: interactive  y: copy  Enter/Esc/q: close";
    return "y: copy  Enter/Esc/q: close";
}

fn remoteErrorModalOptions(size: chasen.Size, message: []const u8, operation: ?app_state.GitErrorOperation) struct { dialog_width: u16, dialog_height: u16 } {
    const dialog_width = @min(size.width, remote_error_dialog_max_width);
    const content_width = if (dialog_width > 4) dialog_width - 4 else 0;
    const paragraph = ui.Paragraph.init(.{ .text = std.mem.trimEnd(u8, message, "\r\n") });
    const body_rows = paragraph.lineCount(content_width);
    // Heading + gap, body, gap, optional stash hint + gap, footer.
    const desired_content_height = body_rows + @as(usize, if (operation == .switch_branch) 6 else 4);
    const desired_height = modalHeightForContent(size, dialog_width, desired_content_height, if (operation == .switch_branch) 0 else remote_error_dialog_min_height);
    return .{
        .dialog_width = dialog_width,
        .dialog_height = @min(size.height, desired_height),
    };
}

pub fn remoteErrorVisibleRows(size: chasen.Size, message: ?[]const u8, operation: ?app_state.GitErrorOperation) u16 {
    const content_size = remoteErrorContentSize(size, message orelse "", operation);
    const reserved_rows: u16 = if (operation == .switch_branch) 6 else 4;
    return content_size.height -| reserved_rows;
}

pub fn remoteErrorMaxScroll(size: chasen.Size, message: ?[]const u8, operation: ?app_state.GitErrorOperation) usize {
    const text = std.mem.trimEnd(u8, message orelse "", "\r\n");
    const content_size = remoteErrorContentSize(size, text, operation);
    if (content_size.width == 0) return 0;
    return paragraphMaxScroll(text, content_size.width, remoteErrorVisibleRows(size, message, operation));
}

fn remoteErrorContentSize(size: chasen.Size, message: []const u8, operation: ?app_state.GitErrorOperation) chasen.Size {
    const opts = remoteErrorModalOptions(size, message, operation);
    return modalContentSizeForRect(.{ .col = 0, .row = 0, .width = size.width, .height = size.height }, .{
        .dialog_width = opts.dialog_width,
        .dialog_height = opts.dialog_height,
    });
}

fn modalHeightForContent(size: chasen.Size, dialog_width: u16, desired_content_height: usize, min_height: u16) u16 {
    var candidate: u16 = @min(size.height, min_height);
    const overlay: chasen.Rect = .{ .col = 0, .row = 0, .width = size.width, .height = size.height };
    while (candidate < size.height) : (candidate += 1) {
        const content_size = modalContentSizeForRect(overlay, .{
            .dialog_width = dialog_width,
            .dialog_height = candidate,
        });
        if (content_size.height >= desired_content_height) return candidate;
    }
    return size.height;
}

const ParagraphViewport = struct {
    visible_rows: usize,
    wrapped_rows: usize,
    scroll: usize,
};

fn paragraphViewport(text: []const u8, width: u16, visible_rows: u16, scroll: usize) ParagraphViewport {
    const paragraph = ui.Paragraph.init(.{ .text = text });
    const wrapped_rows = paragraph.lineCount(width);
    const height: usize = visible_rows;
    const viewport = ui.Viewport.init(.{
        .total = wrapped_rows,
        .height = height,
        .offset = scroll,
    }).withClampedOffset();
    return .{
        .visible_rows = height,
        .wrapped_rows = wrapped_rows,
        .scroll = viewport.offset,
    };
}

fn paragraphMaxScroll(text: []const u8, width: u16, visible_rows: u16) usize {
    const viewport = paragraphViewport(text, width, visible_rows, 0);
    if (viewport.visible_rows == 0) return viewport.wrapped_rows;
    return ui.Viewport.init(.{
        .total = viewport.wrapped_rows,
        .height = viewport.visible_rows,
        .offset = viewport.scroll,
    }).maxOffset();
}

fn drawWrappedTextScrolled(surface: *chasen.Surface, text: []const u8, scroll: usize, style: chasen.TextStyle) usize {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return 0;

    const viewport = paragraphViewport(text, size.width, size.height, scroll);

    var logical_row: usize = 0;
    var drawn_rows: usize = 0;
    var line_start: usize = 0;
    var line_end: usize = 0;
    var line_width: u32 = 0;

    var iter = chasen.text.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        if (bytes.len == 1 and bytes[0] == '\n') {
            if (drawWrappedLine(surface, text[line_start..line_end], logical_row, viewport.scroll, &drawn_rows, style)) return drawn_rows;
            logical_row += 1;
            line_start = grapheme.start + grapheme.len;
            line_end = line_start;
            line_width = 0;
            continue;
        }

        const grapheme_width = chasen.text.displayWidth(bytes);
        if (line_width > 0 and line_width + grapheme_width > size.width) {
            if (drawWrappedLine(surface, text[line_start..line_end], logical_row, viewport.scroll, &drawn_rows, style)) return drawn_rows;
            logical_row += 1;
            line_start = grapheme.start;
            line_end = grapheme.start;
            line_width = 0;
        }

        line_end = grapheme.start + grapheme.len;
        line_width += grapheme_width;
    }

    _ = drawWrappedLine(surface, text[line_start..line_end], logical_row, viewport.scroll, &drawn_rows, style);
    return drawn_rows;
}

fn drawWrappedLine(surface: *chasen.Surface, line: []const u8, logical_row: usize, scroll: usize, drawn_rows: *usize, style: chasen.TextStyle) bool {
    const size = surface.size();
    if (logical_row < scroll) return false;
    if (drawn_rows.* >= @as(usize, size.height)) return true;
    _ = surface.borrowTextAt(0, @intCast(drawn_rows.*), line, style);
    drawn_rows.* += 1;
    return drawn_rows.* >= @as(usize, size.height);
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
    return text[view_primitives.inputVisibleStart(text, cursor, width)..];
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
    view_primitives.showInputCursor(surface, 0, @intCast(visible_line_index), line, body.cursorLinePrefix().len);
}

fn bodyVisibleStartLine(body: *const app_commit_panel.BodyText, text_rows: u16) usize {
    const total_lines = body.lineCount();
    if (text_rows == 0 or total_lines <= text_rows) return 0;
    const cursor_line = body.cursorLineIndex();
    if (cursor_line < text_rows) return 0;
    return cursor_line - text_rows + 1;
}

fn bodyActiveLineIndex(body: *const app_commit_panel.BodyText, start_line: usize, text_rows: u16) ?u16 {
    if (text_rows == 0) return null;

    const cursor_line = body.cursorLineIndex();
    if (cursor_line < start_line or cursor_line - start_line >= text_rows) return null;
    return @intCast(cursor_line - start_line);
}

fn stagedSummaryText(allocator: std.mem.Allocator, summary: app_commit_panel.StagedSummary) ![]const u8 {
    return switch (summary) {
        .ready => |ready| try std.fmt.allocPrint(allocator, "{d} staged file{s}", .{ ready.count, if (ready.count == 1) "" else "s" }),
        .loading_or_stale => "status loading...",
        .unavailable => "status unavailable",
    };
}

fn footerHints(app: Context, key_buffers: *[footer_hint_capacity][16]u8) FooterHints {
    var result: FooterHints = .{};
    if (!shellNormalActionHintsEnabled(app)) return result;

    switch (app.active_page) {
        .changes => {
            const footer = app.changes.footer();
            if (!footer.normal_action_hints_enabled) return result;

            appendFooterAction(app, &result, key_buffers, .branch_switch, "switch branch", .primary);
            appendFooterAction(app, &result, key_buffers, .repo_picker, "switch repo", .repository_switch);
            appendFooterAction(app, &result, key_buffers, .help, "help", .help);
        },
        .repository => {
            const input = app.repository.page_state.inputContext(app.keymap);
            if (app.repository.command_line != null or
                input.source_search_mode or
                input.file_search_mode or
                input.selection_owner != .none or
                app.repository.page_state.retainedSourceSelection() != null)
            {
                return result;
            }

            appendFooterAction(app, &result, key_buffers, .branch_switch, "switch branch", .primary);
            appendFooterAction(app, &result, key_buffers, .repo_picker, "switch repo", .repository_switch);
            appendFooterAction(app, &result, key_buffers, .help, "help", .help);
        },
        .history => {
            if (app.history) |history| {
                const history_input = history.page_state.inputContext(app.keymap);
                if (history.page_state.current_view == .picker and history_input.loading) {
                    result.append(
                        ui.key_hint.item("Esc", if (history_input.return_to_accepted) "back to diff" else "cancel"),
                        .primary,
                    );
                    return result;
                } else if (history.page_state.current_view == .diff) {
                    const footer = history.footer();
                    if (!footer.normal_action_hints_enabled) return result;
                    appendUnclaimedFooterItem(app, &result, .{ .codepoint = 'm' }, "m", "select commits", .compare_base);
                } else {
                    const range_active = history.page_state.draft.isRange();
                    if (history_input.more_row_selected) {
                        result.append(ui.key_hint.item("Enter", "load older"), .primary);
                    } else if (history_input.picker_ready) {
                        result.append(
                            ui.key_hint.item(
                                "Enter",
                                if (range_active) "open range diff" else "open diff",
                            ),
                            .primary,
                        );
                    }
                    if (history_input.picker_ready and history_input.focus == .commit_detail) {
                        appendFooterAction(app, &result, key_buffers, .copy_history_detail, "copy detail", .primary);
                    }
                    if (range_active and !history_input.return_to_accepted) {
                        result.append(ui.key_hint.item("Esc", "cancel range"), .secondary);
                    }
                }
                if (history.page_state.current_view == .picker and
                    history_input.return_to_accepted and !history_input.loading)
                {
                    result.append(ui.key_hint.item("Esc", "back to diff"), .primary);
                }
                appendFooterAction(app, &result, key_buffers, .branch_switch, "switch branch", .primary);
            }
            appendFooterAction(app, &result, key_buffers, .repo_picker, "switch repo", .repository_switch);
            appendFooterAction(app, &result, key_buffers, .help, "help", .help);
        },
        .compare => {
            const footer = app.compare.footer();
            if (!footer.normal_action_hints_enabled or app.compare.page.base_picker.open) return result;
            appendUnclaimedFooterItem(app, &result, .{ .codepoint = 'm' }, "m", "change base", .compare_base);
            appendFooterAction(app, &result, key_buffers, .branch_switch, "switch branch", .primary);
            appendFooterAction(app, &result, key_buffers, .repo_picker, "switch repo", .repository_switch);
            appendFooterAction(app, &result, key_buffers, .help, "help", .help);
        },
    }
    return result;
}

fn shellNormalActionHintsEnabled(app: Context) bool {
    return !app.action.hasPending() and
        !app.repo_picker.mode and
        !app.commit_panel.is_open and
        app.overlay.kind == .none;
}

fn appendFooterAction(
    app: Context,
    hints: *FooterHints,
    key_buffers: *[footer_hint_capacity][16]u8,
    action: keymap.PublicAction,
    description: []const u8,
    priority: FooterHintPriority,
) void {
    if (hints.len >= footer_hint_capacity) return;
    const key = app.keymap.display(action, key_buffers[hints.len][0..]) orelse return;
    hints.append(ui.key_hint.item(key, description), priority);
}

fn appendUnclaimedFooterItem(
    app: Context,
    hints: *FooterHints,
    key: chasen.Key,
    display_key: []const u8,
    description: []const u8,
    priority: FooterHintPriority,
) void {
    if (app.keymap.actionForKey(key) != null) return;
    hints.append(ui.key_hint.item(display_key, description), priority);
}

fn viewHelpPopup(app: Context, surface: *chasen.Surface) !void {
    const opts = helpModalOptions(surface.size(), app.theme);
    const frame = ui.Modal.frame(surface, opts) orelse return;
    fillModalDialog(frame);
    frame.view();
    var content = frame.contentSurface();
    const size = content.size();

    const help = helpContext(app);
    const body = helpBodyLayout(size, help);
    const total_rows = helpRenderedRows(size, help);
    const max_scroll = helpMaxScrollForContentSize(size, help);
    const scroll = @min(app.overlay.help_scroll, max_scroll);

    try drawHelpFooter(&content, scroll, body.visible_rows, total_rows, body.overflow, app.theme);

    if (body.visible_rows == 0) return;

    if (!helpUsesTwoColumns(size, app.active_page)) {
        var list = content.child(.{
            .col = 0,
            .row = 0,
            .width = size.width,
            .height = body.visible_rows,
        });
        try drawHelpSections(app, &list, helpSectionsForPage(app.active_page), scroll);
        return;
    }

    const left_width: u16 = if (size.width > help_column_gap) (size.width - help_column_gap) / 2 else size.width;
    const right_col: u16 = if (size.width > left_width + help_column_gap) left_width + help_column_gap else size.width;
    const right_width: u16 = if (size.width > right_col) size.width - right_col else 0;

    var left = content.child(.{
        .col = 0,
        .row = 0,
        .width = left_width,
        .height = body.visible_rows,
    });
    var right = content.child(.{
        .col = right_col,
        .row = 0,
        .width = right_width,
        .height = body.visible_rows,
    });

    const columns = helpColumnsForPage(app.active_page);
    try drawHelpSections(app, &left, columns.left, scroll);
    try drawHelpSections(app, &right, columns.right, scroll);
}

fn fillModalDialog(frame: ui.Modal.Frame) void {
    // Keep the normal screen visible outside the dialog while still making the
    // dialog itself an opaque surface, so diff text never bleeds into modal UI.
    var dialog = frame.dialogSurface();
    dialog.fillAll(.{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = .{},
    });
}

const HelpBodyLayout = struct {
    visible_rows: u16,
    overflow: bool,
};

fn helpModalOptions(size: chasen.Size, palette: theme.Palette) ui.Modal.ViewOptions {
    return .{
        .dialog_width = @min(size.width, help_dialog_max_width),
        .dialog_height = @min(size.height -| 2, help_dialog_max_height),
        .title = "Shortcuts",
        .backdrop = false,
        .border = .rounded,
        .title_style = palette.boldStyle(.accent),
    };
}

pub fn helpContentSize(size: chasen.Size) chasen.Size {
    const opts = helpModalOptions(size, .default());
    return modalContentSizeForRect(.{ .col = 0, .row = 0, .width = size.width, .height = size.height }, opts);
}

fn modalContentSizeForRect(overlay_rect: chasen.Rect, opts: ui.Modal.ViewOptions) chasen.Size {
    const dialog_rect = ui.Modal.dialogRectFor(overlay_rect, opts);
    const content_rect = ui.Modal.contentRectFor(dialog_rect, opts.padding);
    return .{ .width = content_rect.width, .height = content_rect.height };
}

pub const HelpContext = struct {
    page: page.Id,
    keymap: keymap.Effective = .{},
    diff_mode: diff_render.DisplayMode = .unified,
};

pub fn helpContext(app: Context) HelpContext {
    return .{ .page = app.active_page, .keymap = app.keymap, .diff_mode = effectiveHelpDiffMode(app) };
}

fn helpBodyLayout(size: chasen.Size, help: HelpContext) HelpBodyLayout {
    const visible_rows = size.height -| help_footer_rows;
    return .{
        .visible_rows = visible_rows,
        .overflow = helpRenderedRows(size, help) > visible_rows,
    };
}

pub fn helpVisibleRows(size: chasen.Size, help: HelpContext) u16 {
    return helpBodyLayout(helpContentSize(size), help).visible_rows;
}

pub fn helpMaxScroll(size: chasen.Size, help: HelpContext) usize {
    return helpMaxScrollForContentSize(helpContentSize(size), help);
}

fn helpMaxScrollForContentSize(content_size: chasen.Size, help: HelpContext) usize {
    const body = helpBodyLayout(content_size, help);
    return helpRenderedRows(content_size, help) -| body.visible_rows;
}

pub fn helpRenderedRows(size: chasen.Size, help: HelpContext) usize {
    if (!helpUsesTwoColumns(size, help.page)) return rowsForSections(help, size.width, helpSectionsForPage(help.page));
    const columns = helpColumnsForPage(help.page);
    const left_width = (size.width - help_column_gap) / 2;
    const right_width = size.width - help_column_gap - left_width;
    return @max(rowsForSections(help, left_width, columns.left), rowsForSections(help, right_width, columns.right));
}

fn helpUsesTwoColumns(size: chasen.Size, help_page: page.Id) bool {
    return size.width >= help_two_column_min_width and helpColumnsForPage(help_page).right.len > 0;
}

fn helpColumnsForPage(help_page: page.Id) struct { left: []const HelpSection, right: []const HelpSection } {
    return switch (help_page) {
        .changes => .{ .left = &help_left_sections, .right = &help_right_sections },
        .repository => .{
            .left = &.{ help_repository_sections[0], help_repository_sections[2] },
            .right = help_repository_sections[1..2],
        },
        .history => .{
            .left = &.{ help_history_sections[0], help_history_sections[2] },
            .right = &.{ help_history_sections[1], help_history_sections[3] },
        },
        .compare => .{ .left = help_compare_sections[0..2], .right = help_compare_sections[2..] },
    };
}

fn helpSectionsForPage(help_page: page.Id) []const HelpSection {
    return switch (help_page) {
        .changes => &help_all_sections,
        .repository => &help_repository_sections,
        .history => &help_history_sections,
        .compare => &help_compare_sections,
    };
}

fn rowsForSections(help: HelpContext, width: u16, sections: []const HelpSection) usize {
    var rows: usize = 0;
    var key_buffer: [40]u8 = undefined;
    for (sections, 0..) |section, index| {
        rows += 1;
        for (section.items) |item| {
            const layout = helpItemLayout(help, width, item, &key_buffer) orelse continue;
            rows += layout.rows;
        }
        if (index + 1 < sections.len) rows += 1;
    }
    return rows;
}

fn drawHelpSections(app: Context, surface: *chasen.Surface, sections: []const HelpSection, scroll: usize) !void {
    const end = scroll + surface.size().height;
    const help = helpContext(app);
    var source_row: usize = 0;
    for (sections, 0..) |section, section_index| {
        if (source_row >= end) return;
        if (source_row >= scroll) {
            try draw.copyClippedTextAt(surface, 0, @intCast(source_row - scroll), section.title, app.theme.boldStyle(.prompt));
        }
        source_row += 1;
        for (section.items) |item| {
            if (source_row >= end) return;
            source_row += try drawHelpItem(help, app.theme, surface, source_row, scroll, item);
        }
        if (section_index + 1 < sections.len) source_row += 1;
    }
}

const HelpItemLayout = struct {
    key: []const u8,
    description: []const u8,
    description_col: u16,
    description_row: usize,
    rows: usize,
};

fn helpItemLayout(help: HelpContext, width: u16, item: HelpItem, key_buffer: *[40]u8) ?HelpItemLayout {
    if (width == 0) return null;
    var left_buffer: [16]u8 = undefined;
    var right_buffer: [16]u8 = undefined;
    const key = switch (item.key) {
        .text => |text| text,
        .action => |action| help.keymap.display(action, key_buffer) orelse return null,
        .pair => |pair| blk: {
            const left = help.keymap.display(pair.left, &left_buffer) orelse return null;
            const right = help.keymap.display(pair.right, &right_buffer) orelse return null;
            break :blk std.fmt.bufPrint(key_buffer, "{s} / {s}", .{ left, right }) catch return null;
        },
    };
    const description = switch (item.dynamic) {
        .none => item.description,
        .copy_line => if (help.diff_mode == .unified) "Copy diff" else "Copy line",
        .copy_hunk => if (help.diff_mode == .unified)
            "Copy hunk diff"
        else if (help.page == .compare or help.page == .history)
            "Copy context (selection) / hunk"
        else
            "Copy hunk",
    };
    if (key.len == 0 and description.len == 0) return .{
        .key = key,
        .description = description,
        .description_col = 0,
        .description_row = 0,
        .rows = 1,
    };
    const preferred_col = @max(@as(u16, 18), chasen.text.displayWidth(key) +| 1);
    // On very narrow surfaces, keep the full key above its description.
    const description_col: u16 = if (preferred_col < width) preferred_col else 0;
    const description_row = if (description_col == 0) ui.Paragraph.init(.{ .text = key }).lineCount(width) else 0;
    return .{
        .key = key,
        .description = description,
        .description_col = description_col,
        .description_row = description_row,
        .rows = description_row + ui.Paragraph.init(.{ .text = description }).lineCount(width - description_col),
    };
}

fn drawHelpItem(help: HelpContext, palette: theme.Palette, surface: *chasen.Surface, source_row: usize, scroll: usize, item: HelpItem) !usize {
    var key_buffer: [40]u8 = undefined;
    const layout = helpItemLayout(help, surface.size().width, item, &key_buffer) orelse return 0;
    if (source_row + layout.rows <= scroll or source_row >= scroll + surface.size().height) return layout.rows;
    const key = try surface.frameAllocator().dupe(u8, layout.key);
    drawHelpParagraph(surface, 0, source_row, scroll, key, helpKeyStyle(palette, item.kind));
    drawHelpParagraph(surface, layout.description_col, source_row + layout.description_row, scroll, layout.description, .{});
    return layout.rows;
}

fn drawHelpParagraph(surface: *chasen.Surface, col: u16, source_row: usize, scroll: usize, text: []const u8, style: chasen.TextStyle) void {
    const size = surface.size();
    if (col >= size.width or source_row >= scroll + size.height) return;
    const rows = ui.Paragraph.init(.{ .text = text }).lineCount(size.width - col);
    const skipped = scroll -| source_row;
    if (skipped >= rows) return;
    const row: u16 = @intCast(source_row -| scroll);
    var body = surface.child(.{
        .col = col,
        .row = row,
        .width = size.width - col,
        .height = @intCast(@min(rows - skipped, size.height - row)),
    });
    _ = drawWrappedTextScrolled(&body, text, skipped, style);
}

fn effectiveHelpDiffMode(app: Context) diff_render.DisplayMode {
    return switch (app.active_page) {
        .changes => app.changes.navigation.effectiveDisplayMode(),
        .compare => diff_surface.navigation.effectiveDisplayModeForLayout(
            &app.compare.page.diff.viewer,
            app.compare.layout,
        ),
        .history => if (app.history) |history|
            diff_surface.navigation.effectiveDisplayModeForLayout(
                &history.page_state.diff.viewer,
                history.layout,
            )
        else
            .unified,
        .repository => .unified,
    };
}

fn helpKeyStyle(palette: theme.Palette, kind: HelpItemKind) chasen.TextStyle {
    return switch (kind) {
        .action => palette.boldStyle(.accent),
        .navigation => palette.boldStyle(.pane_command_fg),
        .information => .{},
    };
}

fn drawHelpFooter(surface: *chasen.Surface, scroll: usize, visible_rows: u16, total_rows: usize, overflow: bool, palette: theme.Palette) !void {
    const size = surface.size();
    if (size.height == 0 or size.width == 0) return;
    const legend_width = chasen.text.displayWidth("Actions / Navigation");
    var indicator_col: u16 = 0;
    if (size.width >= legend_width) {
        const row = size.height - 1;
        try draw.copyClippedTextAt(surface, 0, row, "Actions", helpKeyStyle(palette, .action));
        try draw.copyClippedTextAt(surface, 7, row, " / ", palette.style(.muted));
        try draw.copyClippedTextAt(surface, 10, row, "Navigation", helpKeyStyle(palette, .navigation));
        indicator_col = legend_width + 2;
    }
    if (overflow and indicator_col < size.width) {
        var indicator = surface.child(.{
            .col = indicator_col,
            .row = size.height - 1,
            .width = size.width - indicator_col,
            .height = 1,
        });
        try drawHelpScrollIndicator(&indicator, scroll, visible_rows, total_rows, palette);
    }
}

fn drawHelpScrollIndicator(surface: *chasen.Surface, scroll: usize, visible_rows: u16, total_rows: usize, palette: theme.Palette) !void {
    if (surface.size().width == 0 or surface.size().height == 0 or visible_rows == 0 or total_rows == 0) return;

    const start = @min(scroll + 1, total_rows);
    const end = @min(total_rows, scroll + @as(usize, visible_rows));
    const text = try std.fmt.allocPrint(surface.frameAllocator(), "{d}-{d}/{d}", .{ start, end, total_rows });
    const clipped = chasen.text.clipToWidth(text, surface.size().width);
    const text_width = chasen.text.displayWidth(clipped);
    const col: u16 = if (surface.size().width > text_width) surface.size().width - text_width else 0;
    _ = try surface.copyTextAt(col, surface.size().height - 1, clipped, palette.style(.muted));
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

test "footer status target matches clipped rendered cells and retains full text" {
    const status_text = "warning: repository status has a deliberately long diagnostic";
    var app: ShellViewTestHarness = .{
        .terminal_size = .{ .width = 40, .height = 8 },
    };
    app.status.set("{s}", .{status_text});
    const context = app.context();
    const target = footerStatusTarget(context, 40) orelse return error.ExpectedFooterStatusTarget;

    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(40, 1);
    defer ts.deinit();
    viewFooter(context, &ts.surface);
    const snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);

    try std.testing.expectEqualStrings(status_text, target.text);
    try std.testing.expect(target.contains(target.start_col));
    try std.testing.expect(target.contains(target.end_col - 1));
    try std.testing.expect(!target.contains(target.end_col));
    const visible_len: usize = target.end_col - target.start_col;
    try std.testing.expectEqual(
        @as(?usize, target.start_col),
        std.mem.indexOf(u8, snapshot, status_text[0 .. visible_len - 1]),
    );
}

test "footer status target is absent while spinner owns footer" {
    var app: ShellViewTestHarness = .{};
    app.status.set("pushing", .{});
    action_lifecycle.testing.installAccepted(&app.action_runtime, .{ .generation = 1, .kind = .push });
    action_lifecycle.testing.setSpinner(&app.action_runtime, 1, false);

    try std.testing.expect(footerStatusTarget(app.context(), 80) == null);

    action_lifecycle.testing.clear(&app.action_runtime);
    app.status.clear();
    try std.testing.expect(footerStatusTarget(app.context(), 80) == null);
}

test "footer keeps status without normal action hints during Repository command input" {
    var app: ShellViewTestHarness = .{};
    app.status.set("retained status", .{});
    try app.command_input.input.insertSlice("12🐈3456789");
    app.command_line_active = true;
    var context = app.context();
    context.active_page = .repository;
    try std.testing.expect(footerStatusTarget(context, 80) == null);
    var key_buffers: [footer_hint_capacity][16]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), footerHints(context, &key_buffers).len);

    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 1);
    defer ts.deinit();
    viewFooter(context, &ts.surface);
    const snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);

    try std.testing.expect(std.mem.indexOf(u8, snapshot, "retained status") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "6789") == null);
    try std.testing.expect(!ts.screen.cursor_vis);
}

test "footer shows pending spinner with current status label" {
    var app: ShellViewTestHarness = .{};
    app.remote_cancelable = true;
    app.status.set("pushing: main -> origin/main", .{});
    action_lifecycle.testing.installAccepted(&app.action_runtime, .{ .generation = 1, .kind = .push });
    action_lifecycle.testing.setSpinner(&app.action_runtime, 1, false);

    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(96, 1);
    defer ts.deinit();

    viewFooter(app.context(), &ts.surface);
    const snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);

    try std.testing.expect(std.mem.indexOf(u8, snapshot, "/ pushing: main -> origin/main") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Esc: cancel") != null);
}

test "remote cancel spinner replaces the action label with canceling guidance" {
    var app: ShellViewTestHarness = .{};
    app.remote_cancelable = true;
    app.status.set("pushing: raw-child-output-canary", .{});
    action_lifecycle.testing.installAccepted(&app.action_runtime, .{ .generation = 1, .kind = .push });
    action_lifecycle.testing.setSpinner(&app.action_runtime, 2, false);
    var context = app.context();
    context.remote_canceling = true;

    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(96, 1);
    defer ts.deinit();
    viewFooter(context, &ts.surface);
    const snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);

    try std.testing.expect(std.mem.indexOf(u8, snapshot, "canceling...") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "raw-child-output-canary") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Esc: cancel") == null);

    action_lifecycle.testing.clear(&app.action_runtime);
    app.terminal_size = .{ .width = 120, .height = 36 };
    app.status.clear();
    app.changes.status.set(
        "pull failed: remote operation canceled; outcome is unknown; repository reload required; warning: credential.helper may store credentials in plaintext",
        .{},
    );

    var terminal: chasen.testing.TestSurface = undefined;
    try terminal.init(120, 1);
    defer terminal.deinit();
    viewFooter(app.context(), &terminal.surface);
    const terminal_snapshot = try terminal.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(terminal_snapshot);

    try std.testing.expect(std.mem.indexOf(u8, terminal_snapshot, "outcome is unknown; repository reload required") != null);
    try std.testing.expect(std.mem.indexOf(u8, terminal_snapshot, "warning: credential") != null);
    try std.testing.expect(std.mem.indexOf(u8, terminal_snapshot, "q: quit") == null);
}

test "footer falls back to pending kind when status is empty" {
    var app: ShellViewTestHarness = .{};
    action_lifecycle.testing.installAccepted(&app.action_runtime, .{ .generation = 1, .kind = .push });

    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 1);
    defer ts.deinit();

    viewFooter(app.context(), &ts.surface);
    const snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);

    try std.testing.expect(std.mem.indexOf(u8, snapshot, "| push") != null);
}

test "footer keeps action hints without terminal size or automatic reload labels" {
    var app: ShellViewTestHarness = .{ .terminal_size = .{ .width = 120, .height = 32 } };
    app.changes.auto_reload = .{ .activation = .automatic, .interval_ns = 3 * std.time.ns_per_s };

    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(120, 1);
    defer ts.deinit();

    viewFooter(app.context(), &ts.surface);
    const snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);

    try std.testing.expect(std.mem.indexOf(u8, snapshot, "auto-refresh") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "120x32") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "b: switch branch") != null);
}

test "changes file search keeps footer status but suppresses unreachable action hints" {
    var app: ShellViewTestHarness = .{};
    app.changes.file_search.mode = true;
    try app.changes.file_search.input.insertSlice("src/main.zig");
    app.status.set("search active", .{});

    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 1);
    defer ts.deinit();

    viewFooter(app.context(), &ts.surface);
    const snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);

    try std.testing.expect(std.mem.indexOf(u8, snapshot, "file: src/main.zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "search active") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "quit") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "focus") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "commit") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "help") == null);

    var key_buffers: [footer_hint_capacity][16]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), footerHints(app.context(), &key_buffers).len);
}

const ShellViewTestHarness = struct {
    changes: changes_page.ChangesPageState = .{},
    compare: compare_page.ComparePageState = .{},
    repository: repository_page.RepositoryPageState = .{},
    keymap: keymap.Effective = .{},
    theme: theme.Palette = .default(),
    terminal_size: chasen.Size = .{ .width = 80, .height = 24 },
    status: app_state.StatusMessage = .{},
    action_runtime: action_lifecycle.ActionRuntime = .{},
    commit_panel: app_commit_panel.State = .{},
    repo_picker: app_prompt.RepoPickerState = .{},
    repo_picker_items: app_repo_picker.ItemList = .empty,
    recent_repos: repo_state.RecentStore = .{},
    overlay: app_state.OverlayState = .{},
    repo_state: repo_state.State = .{},
    branch_switch: app_state.BranchSwitchState = .{},
    push_confirmation: ?app_state.PushConfirmation = null,
    remote_cancelable: bool = false,
    command_input: command_line.Active = .{},
    command_line_active: bool = false,

    fn context(self: *const ShellViewTestHarness) Context {
        const navigation: @import("pages/changes/navigation.zig").View = .{
            .page = &self.changes,
            .repo_root = null,
            .source = .unstaged,
            .layout = .{ .width = self.terminal_size.width, .height = self.terminal_size.height },
        };
        const changes = changes_view.Context.init(&self.changes, navigation, self.theme, self.keymap, "working tree", .unstaged, null, .{});
        return .{
            .changes = changes,
            .compare = .{
                .page = &self.compare,
                .palette = self.theme,
                .repo_root = self.repo_state.activeRoot(),
                .repo_epoch = 0,
                .root_identity = self.repo_state.activeIdentity(),
                .layout = .{ .width = self.terminal_size.width, .height = self.terminal_size.height },
                .keymap = self.keymap,
            },
            .repository = .{
                .page_state = &self.repository,
                .palette = self.theme,
                .keymap = self.keymap,
                .command_line = if (self.command_line_active) &self.command_input else null,
                .repo_root = self.repo_state.activeRoot(),
            },
            .active_page = .changes,
            .page_bar_visible = false,
            .theme = self.theme,
            .keymap = self.keymap,
            .action = self.action_runtime.view(),
            .remote_cancelable = self.remote_cancelable,
            .status = &self.status,
            .page_status = &self.changes.status,
            .commit_panel = &self.commit_panel,
            .repo_picker = &self.repo_picker,
            .repo_picker_pending_workspace_root = null,
            .repo_picker_items = self.repo_picker_items.items,
            .repo_picker_has_recent = self.recent_repos.entries.items.len > 0,
            .overlay = &self.overlay,
            .committed_repo_discovery_kind = app_repo_picker.discoveryKind(self.repo_state.discovery),
            .active_repo_index = self.repo_state.active_index,
            .has_active_repo = self.repo_state.activeRoot() != null,
            .discard_confirmation = null,
            .amend_confirmation = null,
            .push_confirmation = self.push_confirmation,
            .pull_confirmation = null,
            .remote_error_operation = null,
            .remote_error_message = null,
            .push_retry_target = null,
            .push_retry_inspecting = false,
            .branch_switch = &self.branch_switch,
            .staged_summary = .unavailable,
        };
    }
};

fn expectFooterHintItems(actual: *const FooterHints, expected: []const ui.key_hint.Item) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (actual.slice(), expected) |actual_item, expected_item| {
        try std.testing.expectEqualStrings(expected_item.keys, actual_item.keys);
        try std.testing.expectEqualStrings(expected_item.action, actual_item.action);
    }
}

fn expectProjectedFooterHintItems(actual: *const FooterHintProjection, expected: []const ui.key_hint.Item) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (actual.slice(), expected) |actual_item, expected_item| {
        try std.testing.expectEqualStrings(expected_item.keys, actual_item.keys);
        try std.testing.expectEqualStrings(expected_item.action, actual_item.action);
    }
}

fn installRepositorySourceForFooterTest(harness: *ShellViewTestHarness) !void {
    const allocator = std.testing.allocator;
    const path = try allocator.dupe(u8, "src/main.zig");
    errdefer allocator.free(path);
    const bytes = try allocator.dupe(u8, "const main = 1;\n");
    errdefer allocator.free(bytes);
    var document = try repository_source.Document.initOwned(
        allocator,
        bytes,
        content_fingerprint.Fingerprint.init(bytes),
    );
    errdefer document.deinit(allocator);

    harness.repository.selected_path = path;
    harness.repository.displayed_document = .{
        .path = path,
        .manifest_revision = harness.repository.manifest_revision,
        .authority = .accepted,
        .value = .{ .source = document },
    };
}

test "footer normal-mode hints match the decided page lists" {
    const allocator = std.testing.allocator;
    var harness: ShellViewTestHarness = .{};
    try installRepositorySourceForFooterTest(&harness);
    defer if (harness.repository.displayed_document) |*displayed| displayed.deinit(std.testing.allocator);

    var key_buffers: [footer_hint_capacity][16]u8 = undefined;
    var context = harness.context();
    var hints = footerHints(context, &key_buffers);
    try expectFooterHintItems(&hints, &.{
        ui.key_hint.item("b", "switch branch"),
        ui.key_hint.item("R", "switch repo"),
        ui.key_hint.item("?", "help"),
    });

    context = harness.context();
    context.active_page = .repository;
    hints = footerHints(context, &key_buffers);
    try expectFooterHintItems(&hints, &.{
        ui.key_hint.item("b", "switch branch"),
        ui.key_hint.item("R", "switch repo"),
        ui.key_hint.item("?", "help"),
    });

    context = harness.context();
    context.active_page = .compare;
    hints = footerHints(context, &key_buffers);
    try expectFooterHintItems(&hints, &.{
        ui.key_hint.item("m", "change base"),
        ui.key_hint.item("b", "switch branch"),
        ui.key_hint.item("R", "switch repo"),
        ui.key_hint.item("?", "help"),
    });

    const accepted_oid = try git_history.ObjectId.parse(.sha1, "1111111111111111111111111111111111111111");
    var history_state: history_page.HistoryPageState = .{
        .load_state = .failed,
        .catalog_hidden = true,
        .accepted = .{
            .request = .{
                .snapshot_head = accepted_oid,
                .intent = .{ .single = .{ .index = 0, .oid = accepted_oid } },
                .basis = .{
                    .object_format = .sha1,
                    .before = .empty_tree,
                    .after = accepted_oid,
                },
            },
            .origin = .{ .branch = try allocator.dupe(u8, "main") },
            .selected_parent_count = 0,
        },
    };
    history_state.catalog.continuation = accepted_oid;
    defer history_state.deinit(allocator);
    context = harness.context();
    context.active_page = .history;
    context.history = .{
        .page_state = &history_state,
        .palette = .default(),
    };
    hints = footerHints(context, &key_buffers);
    try expectFooterHintItems(&hints, &.{
        ui.key_hint.item("Esc", "back to diff"),
        ui.key_hint.item("b", "switch branch"),
        ui.key_hint.item("R", "switch repo"),
        ui.key_hint.item("?", "help"),
    });

    history_state.load_state = .loading;
    hints = footerHints(context, &key_buffers);
    try expectFooterHintItems(&hints, &.{
        ui.key_hint.item("Esc", "back to diff"),
    });

    history_state.catalog_hidden = false;
    hints = footerHints(context, &key_buffers);
    try expectFooterHintItems(&hints, &.{
        ui.key_hint.item("Esc", "cancel"),
    });

    history_state.current_view = .diff;
    history_state.load_state = .loaded;
    hints = footerHints(context, &key_buffers);
    try expectFooterHintItems(&hints, &.{
        ui.key_hint.item("m", "select commits"),
        ui.key_hint.item("b", "switch branch"),
        ui.key_hint.item("R", "switch repo"),
        ui.key_hint.item("?", "help"),
    });
    var footer: chasen.testing.TestSurface = undefined;
    try footer.init(120, 1);
    defer footer.deinit();
    viewFooter(context, &footer.surface);
    const snapshot = try footer.snapshot(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "m: select commits") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "commit history") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "120x32") == null);
}

test "History picker footer keeps diff actions and range state without the local Space hint" {
    const allocator = std.testing.allocator;
    var harness: ShellViewTestHarness = .{};
    var history_state: history_page.HistoryPageState = .{ .load_state = .loaded };
    defer history_state.deinit(allocator);
    var history_records: [1]git_history.Record = undefined;
    history_state.catalog.records = .{ .items = &history_records, .capacity = history_records.len };
    defer history_state.catalog.records = .empty;

    var context = harness.context();
    context.active_page = .history;
    context.history = .{
        .page_state = &history_state,
        .palette = .default(),
    };
    var key_buffers: [footer_hint_capacity][16]u8 = undefined;

    var hints = footerHints(context, &key_buffers);
    try expectFooterHintItems(&hints, &.{
        ui.key_hint.item("Enter", "open diff"),
        ui.key_hint.item("b", "switch branch"),
        ui.key_hint.item("R", "switch repo"),
        ui.key_hint.item("?", "help"),
    });

    history_state.draft = .single;
    history_state.interaction_state.focus = .commit_detail;
    hints = footerHints(context, &key_buffers);
    try expectFooterHintItems(&hints, &.{
        ui.key_hint.item("Enter", "open diff"),
        ui.key_hint.item("y", "copy detail"),
        ui.key_hint.item("b", "switch branch"),
        ui.key_hint.item("R", "switch repo"),
        ui.key_hint.item("?", "help"),
    });

    history_state.interaction_state.focus = .history;
    history_state.draft = .{ .range = 0 };
    hints = footerHints(context, &key_buffers);
    try expectFooterHintItems(&hints, &.{
        ui.key_hint.item("Enter", "open range diff"),
        ui.key_hint.item("Esc", "cancel range"),
        ui.key_hint.item("b", "switch branch"),
        ui.key_hint.item("R", "switch repo"),
        ui.key_hint.item("?", "help"),
    });

    var footer: chasen.testing.TestSurface = undefined;
    try footer.init(120, 1);
    defer footer.deinit();
    viewFooter(context, &footer.surface);
    const snapshot = try footer.snapshot(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, history_view.range_footer_text) != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Space:") == null);
}

test "footer normal-mode hints follow state and local key ownership" {
    var harness: ShellViewTestHarness = .{};
    var key_buffers: [footer_hint_capacity][16]u8 = undefined;

    harness.changes.viewer.sidebar_hidden = true;
    var hints = footerHints(harness.context(), &key_buffers);
    try expectFooterHintItems(&hints, &.{
        ui.key_hint.item("b", "switch branch"),
        ui.key_hint.item("R", "switch repo"),
        ui.key_hint.item("?", "help"),
    });

    harness.changes.viewer.sidebar_hidden = false;
    var context = harness.context();
    context.active_page = .repository;
    hints = footerHints(context, &key_buffers);
    try expectFooterHintItems(&hints, &.{
        ui.key_hint.item("b", "switch branch"),
        ui.key_hint.item("R", "switch repo"),
        ui.key_hint.item("?", "help"),
    });

    harness.repository.viewer.tree_hidden = true;
    context = harness.context();
    context.active_page = .repository;
    hints = footerHints(context, &key_buffers);
    try expectFooterHintItems(&hints, &.{
        ui.key_hint.item("b", "switch branch"),
        ui.key_hint.item("R", "switch repo"),
        ui.key_hint.item("?", "help"),
    });

    harness.repository.selection_owner = .{ .source_header = .{ .identity = .{
        .repo_epoch = 1,
        .activation_id = 1,
        .root_identity = .{ .device = 1, .inode = 1 },
        .manifest_revision = 1,
        .path = "src/main.zig",
    } } };
    context = harness.context();
    context.active_page = .repository;
    try std.testing.expectEqual(@as(usize, 0), footerHints(context, &key_buffers).len);
    harness.repository.selection_owner = .none;

    harness.repository.viewer.tree_hidden = false;
    harness.changes.search.mode = true;
    try std.testing.expectEqual(@as(usize, 0), footerHints(harness.context(), &key_buffers).len);
    harness.changes.search.mode = false;
    harness.repo_picker.mode = true;
    try std.testing.expectEqual(@as(usize, 0), footerHints(harness.context(), &key_buffers).len);
}

test "footer hint projection keeps priority items and original display order" {
    var hints: FooterHints = .{};
    hints.append(ui.key_hint.item("Space", "stage"), .primary);
    hints.append(ui.key_hint.item("c", "commit"), .secondary);
    hints.append(ui.key_hint.item("b", "switch branch"), .secondary);
    hints.append(ui.key_hint.item("R", "switch repo"), .repository_switch);
    hints.append(ui.key_hint.item("?", "help"), .help);

    var projected = projectFooterHints(&hints, 37, .{});
    try expectProjectedFooterHintItems(&projected, &.{
        ui.key_hint.item("Space", "stage"),
        ui.key_hint.item("R", "switch repo"),
        ui.key_hint.item("?", "help"),
    });

    projected = projectFooterHints(&hints, 14, .{});
    try expectProjectedFooterHintItems(&projected, &.{
        ui.key_hint.item("R", "switch repo"),
    });

    projected = projectFooterHints(&hints, 200, .{});
    try expectProjectedFooterHintItems(&projected, hints.slice());
}

test "committed-page footer retention is R then m while display order stays m R help" {
    var hints: FooterHints = .{};
    hints.append(ui.key_hint.item("m", "change base"), .compare_base);
    hints.append(ui.key_hint.item("R", "switch repo"), .repository_switch);
    hints.append(ui.key_hint.item("?", "help"), .help);
    const opts: ui.key_hint.DrawOptions = .{};
    const separator_width = chasen.text.displayWidth(opts.separator);
    const r_width = ui.key_hint.width(hints.items[1..2], opts);
    const m_width = ui.key_hint.width(hints.items[0..1], opts);

    var projected = projectFooterHints(&hints, r_width, opts);
    try expectProjectedFooterHintItems(&projected, &.{ui.key_hint.item("R", "switch repo")});

    projected = projectFooterHints(&hints, r_width + m_width + separator_width, opts);
    try expectProjectedFooterHintItems(&projected, &.{
        ui.key_hint.item("m", "change base"),
        ui.key_hint.item("R", "switch repo"),
    });

    projected = projectFooterHints(&hints, 200, opts);
    try expectProjectedFooterHintItems(&projected, hints.slice());
}

test "shell notification temporarily wins over Changes diagnostic" {
    var harness: ShellViewTestHarness = .{};
    harness.changes.status.set("changes diagnostic", .{});
    var context = harness.context();
    try std.testing.expectEqualStrings("changes diagnostic", visibleStatus(context));

    harness.status.set("shell notification", .{});
    context = harness.context();
    try std.testing.expectEqualStrings("shell notification", visibleStatus(context));

    harness.status.clear();
    context = harness.context();
    try std.testing.expectEqualStrings("changes diagnostic", visibleStatus(context));
}

test "page bar dispatch shows repository requirement for unavailable placeholders" {
    var harness: ShellViewTestHarness = .{};
    harness.repository.load_state = .no_repository;
    var context = harness.context();
    context.active_page = .repository;
    context.page_bar_visible = true;

    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(120, 12);
    defer ts.deinit();

    try viewContent(context, &ts.surface);
    const snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, " Changes ") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Repository required") != null);
}

test "page bar renders labels above a full muted rule" {
    const palette = theme.Palette.default();
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(120, shell_layout.page_bar_rows);
    defer ts.deinit();

    viewPageBar(.repository, false, .{}, palette, &ts.surface);

    const snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, " Changes ") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, " Repository ") != null);
    try expectFullPageBarRule(&ts.surface, palette);
}

test "compact page bar keeps only the active label and draws a rule when available" {
    var two_rows: chasen.testing.TestSurface = undefined;
    try two_rows.init(120, shell_layout.page_bar_rows);
    defer two_rows.deinit();

    viewPageBar(.compare, true, .{}, .default(), &two_rows.surface);
    const snapshot = try two_rows.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, " Compare ") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, " Changes ") == null);
    try two_rows.expectCellText(0, shell_layout.page_bar_rule_row, "─");

    var one_row: chasen.testing.TestSurface = undefined;
    try one_row.init(120, 1);
    defer one_row.deinit();
    viewPageBar(.compare, true, .{}, .default(), &one_row.surface);
    try one_row.expectCellText(2, shell_layout.page_bar_label_row, "C");
    try std.testing.expect(one_row.surface.readCell(0, shell_layout.page_bar_rule_row) == null);
}

test "page bar renders repository context after tabs and omits it in compact mode" {
    const presentation: page_header.Presentation = .{ .head = .{ .branch = .{
        .display_name = "feature/page-header",
        .upstream = .{ .ahead = 2 },
        .freshness = .fresh,
    } } };
    var wide: chasen.testing.TestSurface = undefined;
    try wide.init(120, shell_layout.page_bar_rows);
    defer wide.deinit();
    viewPageBar(.repository, false, .{ .presentation = presentation }, .default(), &wide.surface);

    const snapshot = try wide.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, " Config ") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "HEAD feature/page-header ↑2") != null);
    try wide.expectCellText(119, shell_layout.page_bar_label_row, " ");
    try std.testing.expect(page.tabAtColumn(wide.surface.size().width, page.tabExtent() + 1) == null);

    var compact: chasen.testing.TestSurface = undefined;
    try compact.init(120, shell_layout.page_bar_rows);
    defer compact.deinit();
    viewPageBar(.repository, true, .{ .presentation = presentation }, .default(), &compact.surface);
    const compact_snapshot = try compact.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(compact_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, compact_snapshot, "HEAD ") == null);
}

test "page bar shows remote actions alongside loaded Changes diff totals" {
    const test_support = @import("test_support.zig");
    var harness: ShellViewTestHarness = .{ .changes = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .branch_status = .{
            .repo_root = "/repo",
            .status = .{
                .head = .{ .branch = "main" },
                .upstream = .{ .name = "origin/main", .full_ref = "refs/remotes/origin/main", .remote = "origin", .remote_branch = "main" },
                .ahead_behind = .{ .ahead = 2, .behind = 0 },
            },
        },
        .branch_status_load = .{ .freshness = .fresh },
    } };
    defer harness.changes.load.clearCurrent(null);
    var context = harness.context();
    context.changes.repo_root = "/repo";
    const actions = activePageHeaderRemoteActions(context) orelse return error.ExpectedRemoteActions;
    const palette: theme.Palette = .default();
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(120, shell_layout.page_bar_rows);
    defer ts.deinit();

    viewPageBar(.changes, false, .{
        .presentation = activePageHeaderPresentation(context, ts.surface.frameAllocator()),
        .line_stats = .{ .added = 39, .removed = 710 },
        .remote_actions = actions,
    }, palette, &ts.surface);

    const stats_col = ts.surface.size().width - 1 - chasen.text.displayWidth("+39 -710");
    try ts.expectCellText(stats_col, shell_layout.page_bar_label_row, "+");
    try ts.expectCellText(stats_col + 4, shell_layout.page_bar_label_row, "-");
    try ts.expectCellText(119, shell_layout.page_bar_label_row, " ");
    const added = ts.surface.readCell(stats_col, shell_layout.page_bar_label_row) orelse return error.ExpectedAddedStats;
    const removed = ts.surface.readCell(stats_col + 4, shell_layout.page_bar_label_row) orelse return error.ExpectedRemovedStats;
    try std.testing.expect(added.style.fg.eql(palette.color(.success)));
    try std.testing.expect(added.style.bold);
    try std.testing.expect(removed.style.fg.eql(palette.color(.danger)));
    try std.testing.expect(removed.style.bold);

    const snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "HEAD main ↑2") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "(P: push / U: pull)  +39 -710") != null);
}

test "History page bar keeps compact comparison complete with diff totals at 120 columns" {
    const palette: theme.Palette = .default();
    var ts: chasen.testing.TestSurface = undefined;
    // The outer shell frame consumes two columns from a 120-column terminal.
    try ts.init(118, shell_layout.page_bar_rows);
    defer ts.deinit();

    viewPageBar(.history, false, .{
        .presentation = .{ .comparison = .{
            .base_display_name = "1 commit 1111111",
            .head_display_name = "2222222",
            .freshness = .fresh,
        } },
        .line_stats = .{ .added = 39, .removed = 710 },
    }, palette, &ts.surface);

    const snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "BASE 1 commit 1111111  …  HEAD 2222222",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "+39 -710") != null);
}

test "page bar shows remote actions without diff totals" {
    const presentation: page_header.Presentation = .{ .head = .{ .branch = .{
        .display_name = "main",
        .upstream = .{ .ahead = 0 },
        .freshness = .fresh,
    } } };
    const palette: theme.Palette = .default();
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(120, shell_layout.page_bar_rows);
    defer ts.deinit();

    viewPageBar(.changes, false, .{
        .presentation = presentation,
        .remote_actions = .{ .keymap = .{}, .push = true, .pull = true },
    }, palette, &ts.surface);

    const action_text = "(P: push / U: pull)";
    const action_col = ts.surface.size().width - 1 - chasen.text.displayWidth(action_text);
    try ts.expectCellText(action_col, shell_layout.page_bar_label_row, "(");
    try ts.expectCellText(119, shell_layout.page_bar_label_row, " ");
    const action = ts.surface.readCell(action_col, shell_layout.page_bar_label_row) orelse return error.ExpectedRemoteActionHint;
    try std.testing.expect(action.style.eql(palette.style(.muted)));

    const snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "HEAD main ↑0") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, action_text) != null);
}

test "page bar remote actions follow configured keys and width fallback" {
    var config: keymap.Config = .{};
    config.set(.push, .{ .ctrl = .s });
    config.set(.pull, .{ .ctrl = .q });
    const actions: PageBarRemoteActions = .{
        .keymap = keymap.Effective.fromConfig(config),
        .push = true,
        .pull = true,
    };

    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 1);
    defer ts.deinit();

    const full = pageBarRemoteActionText(&ts.surface, actions, 80).?;
    try std.testing.expectEqualStrings("(Ctrl+s: push / Ctrl+q: pull)", full.text);

    const push_only_width = chasen.text.displayWidth("(Ctrl+s: push)");
    const fallback = pageBarRemoteActionText(&ts.surface, actions, push_only_width).?;
    try std.testing.expectEqualStrings("(Ctrl+s: push)", fallback.text);
}

fn expectFullPageBarRule(surface: *const chasen.Surface, palette: theme.Palette) !void {
    for (0..surface.size().width) |col| {
        const cell = surface.readCell(@intCast(col), shell_layout.page_bar_rule_row) orelse
            return error.ExpectedPageBarRuleCell;
        try std.testing.expectEqualStrings("─", cell.char.grapheme);
        try std.testing.expect(cell.style.fg.eql(palette.color(.muted)));
        try std.testing.expect(cell.style.dim);
    }
}

test "shell content size matches panel content surface" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(120, 32);
    defer ts.deinit();

    const frame = ui.Panel.frame(&ts.surface, shellFrameOptions(.default()));
    const expected = shell_layout.contentSize(ts.surface.size());
    const content = frame.contentSurface();

    try std.testing.expectEqual(expected, content.size());
    try std.testing.expectEqual(chasen.Size{ .width = 118, .height = 30 }, expected);
}

test "shell content size falls back to terminal size on small surfaces" {
    const small = chasen.Size{ .width = 29, .height = 20 };

    try std.testing.expect(!shell_layout.frameEnabled(small));
    try std.testing.expectEqual(small, shell_layout.contentSize(small));
}

test "help content size uses Modal overlay sizing" {
    const size = chasen.Size{ .width = 140, .height = 20 };
    const opts = helpModalOptions(size, .default());
    const expected = modalContentSizeForRect(.{ .col = 0, .row = 0, .width = size.width, .height = size.height }, opts);

    try std.testing.expectEqual(@as(u16, 18), opts.dialog_height);
    try std.testing.expectEqual(expected, helpContentSize(size));
}

test "help popup uses two columns at 120 columns and one at 80 columns" {
    const size = chasen.Size{ .width = 120, .height = 32 };
    const content = helpContentSize(size);
    var harness: ShellViewTestHarness = .{ .terminal_size = size };

    try std.testing.expect(content.width >= help_two_column_min_width);
    for ([_]page.Id{ .changes, .repository, .history, .compare }) |help_page| {
        try std.testing.expect(helpUsesTwoColumns(content, help_page));
        try std.testing.expect(!helpUsesTwoColumns(helpContentSize(.{ .width = 80, .height = 32 }), help_page));
        const columns = helpColumnsForPage(help_page);
        try std.testing.expectEqual(@max(rowsForSections(.{ .page = help_page }, (content.width - help_column_gap) / 2, columns.left), rowsForSections(.{ .page = help_page }, (content.width - help_column_gap) / 2, columns.right)), helpRenderedRows(content, .{ .page = help_page }));

        var context = harness.context();
        context.active_page = help_page;
        var popup: chasen.testing.TestSurface = undefined;
        try popup.init(size.width, size.height);
        defer popup.deinit();
        try viewHelpPopup(context, &popup.surface);
        const snapshot = try popup.snapshot(std.testing.allocator);
        defer std.testing.allocator.free(snapshot);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "Actions / Navigation") != null);
        const popup_content = ui.Modal.frame(&popup.surface, helpModalOptions(size, harness.theme)).?.contentSurface();
        const legend_row = popup_content.size().height - 1;
        try std.testing.expectEqual(harness.theme.boldStyle(.accent), popup_content.readCell(0, legend_row).?.style);
        try std.testing.expectEqual(harness.theme.boldStyle(.pane_command_fg), popup_content.readCell(10, legend_row).?.style);
        var lines = std.mem.splitScalar(u8, snapshot, '\n');
        var found_columns = false;
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, columns.left[0].title) == null) continue;
            try std.testing.expect(std.mem.indexOf(u8, line, columns.right[0].title) != null);
            found_columns = true;
            break;
        }
        try std.testing.expect(found_columns);
    }
}

test "help popup reserves a footer row for its legend and scroll status" {
    const roomy = chasen.Size{ .width = 140, .height = 48 };
    const cramped = chasen.Size{ .width = 140, .height = 10 };

    try std.testing.expectEqual(@as(usize, 0), helpMaxScroll(roomy, .{ .page = .changes }));
    try std.testing.expectEqual(helpContentSize(roomy).height - 1, helpVisibleRows(roomy, .{ .page = .changes }));
    try std.testing.expect(helpMaxScroll(cramped, .{ .page = .changes }) > 0);
    try std.testing.expect(helpVisibleRows(cramped, .{ .page = .changes }) < helpContentSize(cramped).height);
}

test "help popup max scroll helper separates outer and content sizes" {
    const outer = chasen.Size{ .width = 140, .height = 10 };
    const content = helpContentSize(outer);

    try std.testing.expectEqual(helpMaxScrollForContentSize(content, .{ .page = .changes }), helpMaxScroll(outer, .{ .page = .changes }));
}

test "help preserves configured keys and aligned wrapped descriptions while scrolling" {
    var harness: ShellViewTestHarness = .{};
    var config: keymap.Config = .{};
    config.set(.search, .{ .ctrl = .s });
    harness.keymap = .fromConfig(config);
    const context = harness.context();
    const sections = [_]HelpSection{.{ .title = "Help", .items = &.{
        .{ .key = .{ .action = .search }, .description = "previous search match when query is active" },
        help_group_separator,
        .{ .kind = .navigation, .key = .{ .text = "j" }, .description = "scroll" },
    } }};
    for ([_]struct { width: u16, rows: u16, continuation: []const u8 }{
        .{ .width = 51, .rows = 5, .continuation = "is active" },
        .{ .width = 28, .rows = 8, .continuation = "earch matc" },
    }) |case| {
        try std.testing.expectEqual(case.rows, rowsForSections(helpContext(context), case.width, &sections));
        var full: chasen.testing.TestSurface = undefined;
        try full.init(case.width, case.rows);
        defer full.deinit();
        try drawHelpSections(context, &full.surface, &sections, 0);
        const snapshot = try full.snapshot(std.testing.allocator);
        defer std.testing.allocator.free(snapshot);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "Ctrl+s            previous") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "...") == null);
        try full.expectCellText(0, 2, " ");
        try full.expectCellText(18, case.rows - 2, " ");
        try full.expectCellText(0, case.rows - 1, "j");
        try full.expectCellText(18, case.rows - 1, "s");
        try std.testing.expectEqual(context.theme.boldStyle(.accent), full.surface.readCell(0, 1).?.style);
        try std.testing.expectEqual(chasen.TextStyle{}, full.surface.readCell(18, 1).?.style);
        try std.testing.expectEqual(context.theme.boldStyle(.pane_command_fg), full.surface.readCell(0, case.rows - 1).?.style);

        var scrolled: chasen.testing.TestSurface = undefined;
        try scrolled.init(case.width, 2);
        defer scrolled.deinit();
        try drawHelpSections(context, &scrolled.surface, &sections, 2);
        const scrolled_snapshot = try scrolled.snapshot(std.testing.allocator);
        defer std.testing.allocator.free(scrolled_snapshot);
        try std.testing.expect(std.mem.indexOf(u8, scrolled_snapshot, case.continuation) != null);
        try std.testing.expect(std.mem.indexOf(u8, scrolled_snapshot, "Ctrl+s") == null);
        try scrolled.expectCellText(0, 0, " ");
        try scrolled.expectCellText(18, 0, case.continuation[0..1]);
    }
}

test "diff Help copy keys and vocabulary follow the keymap and effective mode" {
    var harness: ShellViewTestHarness = .{ .terminal_size = .{ .width = 160, .height = 40 } };
    var config: keymap.Config = .{};
    config.set(.copy_current_line, .{ .ctrl = .s });
    config.set(.copy_current_hunk, .{ .ctrl = .enter });
    try std.testing.expect(keymap.validateConfig(config));
    harness.keymap = .fromConfig(config);
    var history: history_page.HistoryPageState = .{};
    harness.changes.viewer.sidebar_hidden = true;
    harness.compare.diff.viewer.sidebar_hidden = true;
    history.diff.viewer.sidebar_hidden = true;

    const cases = [_]struct {
        requested: diff_render.DisplayMode,
        width: u16,
    }{
        .{ .requested = .unified, .width = 160 },
        .{ .requested = .side_by_side, .width = 160 },
        .{ .requested = .side_by_side, .width = 60 },
    };
    for (cases) |case| {
        harness.terminal_size.width = case.width;
        harness.changes.viewer.display_mode = case.requested;
        harness.compare.diff.viewer.display_mode = case.requested;
        history.diff.viewer.display_mode = case.requested;

        for ([_]page.Id{ .changes, .compare, .history }) |help_page| {
            var context = harness.context();
            context.active_page = help_page;
            context.history = .{
                .page_state = &history,
                .palette = harness.theme,
                .layout = .{ .width = case.width, .height = 40 },
                .keymap = harness.keymap,
            };
            const canonical_mode = switch (help_page) {
                .changes => context.changes.navigation.effectiveDisplayMode(),
                .compare => diff_surface.navigation.effectiveDisplayModeForLayout(
                    &harness.compare.diff.viewer,
                    context.compare.layout,
                ),
                .history => diff_surface.navigation.effectiveDisplayModeForLayout(
                    &history.diff.viewer,
                    context.history.?.layout,
                ),
                .repository => unreachable,
            };
            try std.testing.expectEqual(canonical_mode, effectiveHelpDiffMode(context));

            var popup: chasen.testing.TestSurface = undefined;
            try popup.init(60, 2);
            defer popup.deinit();
            _ = try drawHelpItem(helpContext(context), context.theme, &popup.surface, 0, 0, help_diff_items[1]);
            _ = try drawHelpItem(helpContext(context), context.theme, &popup.surface, 1, 0, help_diff_items[2]);
            const snapshot = try popup.snapshot(std.testing.allocator);
            defer std.testing.allocator.free(snapshot);
            try std.testing.expect(std.mem.indexOf(u8, snapshot, "Ctrl+s") != null);
            try std.testing.expect(std.mem.indexOf(u8, snapshot, "Ctrl+Enter") != null);

            const app_input = @import("input.zig");
            const input_context: app_input.KeyContext = .{
                .active_page = help_page,
                .keymap = harness.keymap,
                .changes = .{ .focus = .diff, .keymap = harness.keymap },
                .compare = .{ .common = .{ .focus = .diff, .keymap = harness.keymap } },
                .history = .{ .diff_view = true, .common = .{ .focus = .diff, .keymap = harness.keymap } },
            };
            const msg = @import("message.zig").Msg;
            for ([_]struct { key: u21, expected: msg }{
                .{ .key = 's', .expected = switch (help_page) {
                    .changes => .{ .changes = .copy_current_line },
                    .compare => .{ .compare = .{ .common = .copy_current_line } },
                    .history => .{ .history = .{ .common = .copy_current_line } },
                    else => unreachable,
                } },
                .{ .key = chasen.Key.enter, .expected = switch (help_page) {
                    .changes => .{ .changes = .copy_current_hunk },
                    .compare => .{ .compare = .{ .common = .copy_current_hunk } },
                    .history => .{ .history = .{ .common = .copy_current_hunk } },
                    else => unreachable,
                } },
            }) |binding| {
                try std.testing.expectEqual(binding.expected, app_input.keyToMsg(input_context, .{
                    .codepoint = binding.key,
                    .mods = .{ .ctrl = true },
                }).?);
            }

            if (canonical_mode == .unified) {
                try std.testing.expect(std.mem.indexOf(u8, snapshot, "Copy diff") != null);
                try std.testing.expect(std.mem.indexOf(u8, snapshot, "Copy hunk diff") != null);
                try std.testing.expect(std.mem.indexOf(u8, snapshot, "Copy context") == null);
            } else {
                try std.testing.expect(std.mem.indexOf(u8, snapshot, "Copy line") != null);
                const hunk_label = if (help_page == .changes) "Copy hunk" else "Copy context (selection) / hunk";
                try std.testing.expect(std.mem.indexOf(u8, snapshot, hunk_label) != null);
                try std.testing.expect(std.mem.indexOf(u8, snapshot, "Copy hunk diff") == null);
            }
        }
    }
}

test "help popup uses effective document navigation labels and reaches its tail at 80x12" {
    const size = chasen.Size{ .width = 80, .height = 12 };
    const content = helpContentSize(size);
    try std.testing.expect(!helpUsesTwoColumns(content, .repository));
    try std.testing.expectEqual(rowsForSections(.{ .page = .repository }, content.width, &help_repository_sections), helpRenderedRows(content, .{ .page = .repository }));
    const max_scroll = helpMaxScroll(size, .{ .page = .repository });
    try std.testing.expect(max_scroll > 0);

    var harness: ShellViewTestHarness = .{ .terminal_size = size };
    var config: keymap.Config = .{};
    config.set(.document_first, .{ .plain_codepoint = 'z' });
    config.set(.half_page_down, .{ .plain_codepoint = 'x' });
    config.set(.next_file, .{ .plain_codepoint = 'm' });
    try std.testing.expect(keymap.validateConfig(config));
    harness.keymap = keymap.Effective.fromConfig(config);
    harness.overlay.openHelpForPage(.repository);
    const source_help: HelpContext = .{ .page = .repository, .keymap = harness.keymap };
    const source_items_scroll = rowsForSections(source_help, content.width, help_repository_sections[0..1]) + 1 +
        rowsForSections(source_help, content.width, &.{.{ .title = "Source", .items = help_repository_source_items[0..6] }});
    harness.overlay.help_scroll = source_items_scroll;
    var context = harness.context();
    context.active_page = .repository;

    var middle: chasen.testing.TestSurface = undefined;
    try middle.init(size.width, size.height);
    defer middle.deinit();
    try viewHelpPopup(context, &middle.surface);
    const middle_snapshot = try middle.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(middle_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, middle_snapshot, "[ / m") != null);
    try std.testing.expect(std.mem.indexOf(u8, middle_snapshot, "z / G") != null);
    try std.testing.expect(std.mem.indexOf(u8, middle_snapshot, "Ctrl+u / x") != null);
    harness.overlay.help_scroll += 1;
    context = harness.context();
    context.active_page = .repository;
    try viewHelpPopup(context, &middle.surface);
    const page_snapshot = try middle.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(page_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, page_snapshot, "Ctrl+b / Ctrl+f") != null);

    harness.overlay.help_scroll = max_scroll;
    context = harness.context();
    context.active_page = .repository;
    var tail: chasen.testing.TestSurface = undefined;
    try tail.init(size.width, size.height);
    defer tail.deinit();
    try viewHelpPopup(context, &tail.surface);
    const tail_snapshot = try tail.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(tail_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, tail_snapshot, "Config page") == null);
    try std.testing.expect(std.mem.indexOf(u8, tail_snapshot, "switch repository") != null);

    for ([_]page.Id{ .changes, .compare, .history }) |help_page| {
        harness.overlay.openHelpForPage(help_page);
        const sections = helpSectionsForPage(help_page);
        const shared_section_index: usize = if (help_page == .compare) 2 else 3;
        const diff_help: HelpContext = .{ .page = help_page, .keymap = harness.keymap };
        harness.overlay.help_scroll = rowsForSections(diff_help, content.width, sections[0..shared_section_index]) + 1 +
            rowsForSections(diff_help, content.width, &.{.{ .title = "Diff", .items = help_diff_items[0..9] }});
        context = harness.context();
        context.active_page = help_page;

        var navigation: chasen.testing.TestSurface = undefined;
        try navigation.init(size.width, size.height);
        defer navigation.deinit();
        try viewHelpPopup(context, &navigation.surface);
        const navigation_snapshot = try navigation.snapshot(std.testing.allocator);
        defer std.testing.allocator.free(navigation_snapshot);
        try std.testing.expect(std.mem.indexOf(u8, navigation_snapshot, "[ / m") != null);
        try std.testing.expect(std.mem.indexOf(u8, navigation_snapshot, "z / G") != null);
        try std.testing.expect(std.mem.indexOf(u8, navigation_snapshot, "Ctrl+u / x") != null);
        harness.overlay.help_scroll += 1;
        context = harness.context();
        context.active_page = help_page;
        try viewHelpPopup(context, &navigation.surface);
        const next_snapshot = try navigation.snapshot(std.testing.allocator);
        defer std.testing.allocator.free(next_snapshot);
        try std.testing.expect(std.mem.indexOf(u8, next_snapshot, "Ctrl+b / Ctrl+f   page backward / forward") != null);

        harness.overlay.help_scroll = helpMaxScroll(size, .{ .page = help_page, .keymap = harness.keymap });
        context = harness.context();
        context.active_page = help_page;
        var page_tail: chasen.testing.TestSurface = undefined;
        try page_tail.init(size.width, size.height);
        defer page_tail.deinit();
        try viewHelpPopup(context, &page_tail.surface);
        const page_tail_snapshot = try page_tail.snapshot(std.testing.allocator);
        defer std.testing.allocator.free(page_tail_snapshot);
        try std.testing.expect(std.mem.indexOf(u8, page_tail_snapshot, "previous search match") != null);
        try std.testing.expect(std.mem.indexOf(u8, page_tail_snapshot, "next / previous hunk") != null);
    }
}

test "page help puts local shortcuts before Global navigation and quit" {
    var harness: ShellViewTestHarness = .{ .terminal_size = .{ .width = 120, .height = 32 } };
    for ([_]page.Id{ .repository, .history, .compare }) |help_page| {
        harness.overlay.openHelpForPage(help_page);
        var context = harness.context();
        context.active_page = help_page;

        var popup: chasen.testing.TestSurface = undefined;
        try popup.init(120, 32);
        defer popup.deinit();
        try viewHelpPopup(context, &popup.surface);
        const snapshot = try popup.snapshot(std.testing.allocator);
        defer std.testing.allocator.free(snapshot);

        if (help_page == .compare) {
            try std.testing.expect(std.mem.indexOf(u8, snapshot, "m                 change comparison base") != null);
        }

        const sections = helpColumnsForPage(help_page).left;
        for (sections, 0..) |section, index| {
            if (!std.mem.eql(u8, section.title, "Global")) continue;
            try std.testing.expect(index > 0);
            harness.overlay.help_scroll = rowsForSections(helpContext(context), (helpContentSize(harness.terminal_size).width - help_column_gap) / 2, sections[0..index]) + 1;
            break;
        }
        try viewHelpPopup(context, &popup.surface);
        const global_snapshot = try popup.snapshot(std.testing.allocator);
        defer std.testing.allocator.free(global_snapshot);
        for ([_][]const u8{ "Global", "Changes page", "Repository page", "History page", "Compare page", "switch repository", "open / close help", "quit" }) |label| {
            try std.testing.expect(std.mem.indexOf(u8, global_snapshot, label) != null);
        }
    }
}

test "History help explains every commit picker marker" {
    var harness: ShellViewTestHarness = .{};
    var config: keymap.Config = .{};
    config.set(.copy_history_detail, .{ .plain_codepoint = 'x' });
    harness.keymap = keymap.Effective.fromConfig(config);
    var context = harness.context();
    context.active_page = .history;

    var popup: chasen.testing.TestSurface = undefined;
    try popup.init(120, 32);
    defer popup.deinit();
    try viewHelpPopup(context, &popup.surface);
    const snapshot = try popup.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);

    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Commit markers") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "OID Date Author Type Refs Subject") == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "x                 copy detail (detail pane)",
    ) != null);
    for ([_][]const u8{
        "commit in selected range",
        "merge commit",
        "root commit",
        "first parent unavailable",
    }) |description| {
        try std.testing.expect(std.mem.indexOf(u8, snapshot, description) != null);
    }
}

test "remote error paragraph viewport max scroll follows wrapped line count" {
    const text = "ab\n\nあいz\nabcdef";
    const width: u16 = 4;
    const visible_rows: u16 = 2;
    const paragraph = ui.Paragraph.init(.{ .text = text });
    const expected_rows = paragraph.lineCount(width);

    try std.testing.expectEqual(expected_rows - visible_rows, paragraphMaxScroll(text, width, visible_rows));
}

test "remote error paragraph renderer stays in parity with Paragraph lineCount" {
    const text = "ab\n\nあいz\nabcdef";
    const width: u16 = 4;
    const paragraph = ui.Paragraph.init(.{ .text = text });
    const expected_rows = paragraph.lineCount(width);

    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(width, @intCast(expected_rows + 1));
    defer ts.deinit();

    try std.testing.expectEqual(expected_rows, drawWrappedTextScrolled(&ts.surface, text, 0, .{}));
}

test "remote error paragraph renderer applies scroll offset" {
    const text = "one\ntwo\nthree\nfour";
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(8, 3);
    defer ts.deinit();

    try std.testing.expectEqual(@as(usize, 3), drawWrappedTextScrolled(&ts.surface, text, 1, .{}));
    try ts.expectCellText(0, 0, "t");
    try ts.expectCellText(0, 1, "t");
    try ts.expectCellText(0, 2, "f");
}

test "remote error footer advertises copy and limits interactive action to push at 120 columns" {
    const Case = struct {
        operation: app_state.GitErrorOperation,
        inspecting: bool,
        retry_available: bool,
        expected: []const u8,
    };
    const content_width = remoteErrorContentSize(.{ .width = 120, .height = 24 }, "failure", null).width;

    for ([_]Case{
        .{ .operation = .push, .inspecting = true, .retry_available = true, .expected = "checking push target...  y: copy  Enter/Esc/q: cancel" },
        .{ .operation = .push, .inspecting = false, .retry_available = true, .expected = "i: interactive  y: copy  Enter/Esc/q: close" },
        .{ .operation = .push, .inspecting = false, .retry_available = false, .expected = "y: copy  Enter/Esc/q: close" },
        .{ .operation = .pull, .inspecting = false, .retry_available = false, .expected = "y: copy  Enter/Esc/q: close" },
        .{ .operation = .switch_branch, .inspecting = false, .retry_available = false, .expected = "y: copy  Enter/Esc/q: close" },
    }) |case| {
        const footer = remoteErrorFooter(case.operation, case.inspecting, case.retry_available);
        try std.testing.expectEqualStrings(case.expected, footer);
        try std.testing.expect(footer.len <= @as(usize, content_width));
    }
}

test "branch switch error renders title footer and scrolled tail at 120x32" {
    const message = "error: local changes would be overwritten:\n" ++
        "    a-long-file-name-for-checking-the-wrapped-branch-switch-error-details.txt\n" ** 40 ++
        "Aborting";
    var app: ShellViewTestHarness = .{};
    var context = app.context();
    context.remote_error_operation = .switch_branch;
    context.remote_error_message = message;
    app.overlay.remote_error_scroll = remoteErrorMaxScroll(.{ .width = 120, .height = 32 }, message, .switch_branch);
    try std.testing.expect(app.overlay.remote_error_scroll > 0);
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(120, 32);
    defer ts.deinit();
    try viewRemoteError(context, &ts.surface);
    const snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Branch switch failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Aborting") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "y: copy  Enter/Esc/q: close") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "interactive") == null);
}

test "remote error modal height grows past 31 rows" {
    try std.testing.expectEqual(
        @as(u16, 44),
        modalHeightForContent(.{ .width = 33, .height = 46 }, 33, 40, remote_error_dialog_min_height),
    );
}

test "push confirmation renders ahead behind for upstream push" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 12);
    defer ts.deinit();

    var app: ShellViewTestHarness = .{};
    app.push_confirmation = .{
        .repository_identity = .{ .repo_epoch = 0, .root_identity = .{ .device = 0, .inode = 0 } },
        .mode = .upstream,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .branch = try std.testing.allocator.dupe(u8, "feature"),
        .remote = try std.testing.allocator.dupe(u8, "origin"),
        .remote_branch = try std.testing.allocator.dupe(u8, "feature"),
        .oid = try std.testing.allocator.dupe(u8, "abc123"),
        .ahead_behind = .{ .ahead = 2, .behind = 0 },
    };
    defer app.push_confirmation.?.deinit(std.testing.allocator);

    try viewPushConfirmation(app.context(), &ts.surface);
    const snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);

    try std.testing.expect(std.mem.indexOf(u8, snapshot, "feature -> origin/feature") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "ahead 2 / behind 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "will set upstream") == null);
}

test "push confirmation renders set-upstream detail without fake ahead behind" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 12);
    defer ts.deinit();

    var app: ShellViewTestHarness = .{};
    app.push_confirmation = .{
        .repository_identity = .{ .repo_epoch = 0, .root_identity = .{ .device = 0, .inode = 0 } },
        .mode = .set_upstream,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .branch = try std.testing.allocator.dupe(u8, "feature/topic"),
        .remote = try std.testing.allocator.dupe(u8, "origin"),
        .remote_branch = try std.testing.allocator.dupe(u8, "feature/topic"),
        .oid = try std.testing.allocator.dupe(u8, "abc123"),
        .ahead_behind = null,
    };
    defer app.push_confirmation.?.deinit(std.testing.allocator);

    try viewPushConfirmation(app.context(), &ts.surface);
    const snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);

    try std.testing.expect(std.mem.indexOf(u8, snapshot, "feature/topic -> origin/feature/topic") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "will set upstream") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "ahead 0 / behind 0") == null);
}

const BranchSwitchViewSpec = struct {
    name: []const u8,
    current: bool = false,
    tip_committer_unix: ?i64 = null,
};

fn branchSwitchStateForViewTest(
    allocator: std.mem.Allocator,
    specs: []const BranchSwitchViewSpec,
) !app_state.BranchSwitchState {
    var state: app_state.BranchSwitchState = .{};
    errdefer if (state.hasState()) state.deinit(allocator);
    state.repo_root = try allocator.dupe(u8, "/repo");
    state.current_branch = try allocator.dupe(u8, "main");
    state.current_oid = try allocator.dupe(u8, "abc123");

    const branches = try allocator.alloc(app_state.BranchSwitchItem, specs.len);
    errdefer allocator.free(branches);
    var initialized: usize = 0;
    errdefer for (branches[0..initialized]) |*branch| branch.deinit(allocator);
    for (specs, branches) |spec, *branch| {
        const full_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{spec.name});
        errdefer allocator.free(full_ref);
        const name = try allocator.dupe(u8, spec.name);
        errdefer allocator.free(name);
        branch.* = .{
            .full_ref = full_ref,
            .name = name,
            .oid = try allocator.dupe(u8, "abc123"),
            .current = spec.current,
            .tip_committer_unix = spec.tip_committer_unix,
        };
        initialized += 1;
    }
    state.branches = branches;
    return state;
}

test "branch switch popup renders relative times and selected exact commit detail" {
    const allocator = std.testing.allocator;
    const now: i64 = 1_700_000_000;
    var app: ShellViewTestHarness = .{};
    app.branch_switch = try branchSwitchStateForViewTest(allocator, &.{
        .{ .name = "feature/recent", .tip_committer_unix = now - 2 * 60 * 60 },
        .{ .name = "main", .current = true, .tip_committer_unix = now - 3 * 24 * 60 * 60 },
        .{ .name = "feature/unknown" },
    });
    defer app.branch_switch.deinit(allocator);
    app.branch_switch.render_now_unix = now;

    var known: chasen.testing.TestSurface = undefined;
    try known.init(120, 32);
    defer known.deinit();
    try viewBranchSwitchPopup(app.context(), &known.surface);
    const known_snapshot = try known.snapshot(allocator);
    defer allocator.free(known_snapshot);

    const exact = local_time.formatExact(now - 2 * 60 * 60).?;
    const expected_detail = try std.fmt.allocPrint(allocator, "last commit: {s}", .{exact.text()});
    defer allocator.free(expected_detail);
    const detail_index = std.mem.indexOf(u8, known_snapshot, expected_detail).?;
    const branch_index = std.mem.indexOf(u8, known_snapshot, "feature/recent").?;
    try std.testing.expect(detail_index < branch_index);
    try std.testing.expect(std.mem.indexOf(u8, known_snapshot, "Current branch: main") != null);
    try known.expectCellText(14, 8, " ");
    try known.expectCellText(14, 9, "F");
    try std.testing.expect(std.mem.indexOf(u8, known_snapshot, "2h ago") != null);
    try std.testing.expect(std.mem.indexOf(u8, known_snapshot, "3d ago") != null);
    try std.testing.expect(std.mem.indexOf(u8, known_snapshot, "* main") != null);
    try std.testing.expect(std.mem.indexOf(u8, known_snapshot, "Carry uncommitted changes to target; abort if unsafe.") != null);
    try std.testing.expect(!known.surface.readCell(14, 10).?.style.dim);
    try std.testing.expectEqual(app.theme.boldStyle(.prompt), known.surface.readCell(16, 15).?.style);

    app.branch_switch.branches[0].worktree_path = try allocator.dupe(u8, "/workspace/linked tree");
    var moving: chasen.testing.TestSurface = undefined;
    try moving.init(120, 32);
    defer moving.deinit();
    try viewBranchSwitchPopup(app.context(), &moving.surface);
    const moving_snapshot = try moving.snapshot(allocator);
    defer allocator.free(moving_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, moving_snapshot, "@ feature/recent") != null);
    try std.testing.expect(std.mem.indexOf(u8, moving_snapshot, "Worktree: /workspace/linked tree") != null);
    try std.testing.expect(std.mem.indexOf(u8, moving_snapshot, "Leave uncommitted changes here; open target worktree.") != null);
    try std.testing.expect(std.mem.indexOf(u8, moving_snapshot, "Enter: open worktree") != null);

    app.branch_switch.selected_index = 2;
    var unknown: chasen.testing.TestSurface = undefined;
    try unknown.init(80, 20);
    defer unknown.deinit();
    try viewBranchSwitchPopup(app.context(), &unknown.surface);
    const unknown_snapshot = try unknown.snapshot(allocator);
    defer allocator.free(unknown_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, unknown_snapshot, "last commit: unknown") != null);

    // Shrinking the dialog must clip details before the footer separator.
    for ([_]u16{ 6, 7, 8, 9, 10, 11, 12 }) |height| {
        var short: chasen.testing.TestSurface = undefined;
        try short.init(80, height);
        defer short.deinit();
        try viewBranchSwitchPopup(app.context(), &short.surface);
        const snapshot = try short.snapshot(allocator);
        defer allocator.free(snapshot);
        const footer_offset = std.mem.indexOf(u8, snapshot, "/: filter").?;
        const footer_row: u16 = @intCast(std.mem.count(u8, snapshot[0..footer_offset], "\n"));
        for (2..78) |col| try short.expectCellText(@intCast(col), footer_row - 1, " ");
    }

    try app.branch_switch.editQuery(allocator, .enter);
    for ("MAIN") |codepoint| try app.branch_switch.editQuery(allocator, .{ .insert = codepoint });
    var filtered: chasen.testing.TestSurface = undefined;
    try filtered.init(120, 32);
    defer filtered.deinit();
    try viewBranchSwitchPopup(app.context(), &filtered.surface);
    const filtered_snapshot = try filtered.snapshot(allocator);
    defer allocator.free(filtered_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, filtered_snapshot, "Filter branches: /MAIN") != null);
    try std.testing.expectEqual(@as(u16, 9), filtered.screen.cursor.row);
    try std.testing.expect(std.mem.indexOf(u8, filtered_snapshot, "> * main") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered_snapshot, "feature/") == null);
    try std.testing.expect(std.mem.indexOf(u8, filtered_snapshot, "Enter: close  Tab: command  Esc: clear") != null);
    try std.testing.expectEqual(app.theme.boldStyle(.prompt), filtered.surface.readCell(16, 14).?.style);

    try app.branch_switch.editQuery(allocator, .{ .insert = 'x' });
    var unmatched: chasen.testing.TestSurface = undefined;
    try unmatched.init(120, 32);
    defer unmatched.deinit();
    try viewBranchSwitchPopup(app.context(), &unmatched.surface);
    const unmatched_snapshot = try unmatched.snapshot(allocator);
    defer allocator.free(unmatched_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, unmatched_snapshot, "No branches match \"MAINx\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, unmatched_snapshot, "Enter:") == null);
}

const HelpItemKind = enum { action, navigation, information };

const HelpItem = struct {
    kind: HelpItemKind = .action,
    key: HelpKey,
    description: []const u8,
    dynamic: enum { none, copy_line, copy_hunk } = .none,
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

const help_group_separator: HelpItem = .{ .kind = .information, .key = .{ .text = "" }, .description = "" };

const help_remote_items = [_]HelpItem{
    .{ .key = .{ .action = .push }, .description = "push current branch" },
    .{ .key = .{ .action = .pull }, .description = "pull from upstream (fast-forward only)" },
};

const help_reviewed_items = [_]HelpItem{
    .{ .key = .{ .action = .mark_reviewed }, .description = "toggle reviewed mark for current file" },
    .{ .key = .{ .action = .hide_reviewed }, .description = "show / hide reviewed files" },
};

const help_git_command_items = [_]HelpItem{
    .{ .key = .{ .text = "Space (file tree)" }, .description = "stage / unstage file or dir" },
    .{ .key = .{ .text = "Space (diff)" }, .description = "stage / unstage hunk" },
    .{ .key = .{ .action = .commit }, .description = "open commit panel" },
    .{ .key = .{ .action = .amend }, .description = "amend last commit" },
    .{ .key = .{ .action = .create_stash }, .description = "create stash (all / staged changes)" },
    .{ .key = .{ .action = .stash_list }, .description = "list stashes / apply or drop" },
} ++ help_remote_items ++ [_]HelpItem{
    .{ .key = .{ .action = .fetch }, .description = "fetch upstream remote (no branch update)" },
    .{ .key = .{ .action = .branch_switch }, .description = "checkout branch / open worktree" },
    .{ .key = .{ .action = .discard }, .description = "discard unstaged changes in selected tracked file" },
};

const help_global_items = [_]HelpItem{
    .{ .key = .{ .action = .help }, .description = "open / close help" },
    .{ .key = .{ .text = "q" }, .description = "quit" },
    .{ .key = .{ .action = .toggle_sidebar }, .description = "show / hide file tree" },
    .{ .key = .{ .action = .reload }, .description = "force reload (auto by default; --no-watch disables)" },
    .{ .key = .{ .action = .open_editor }, .description = "open selected file in editor" },
    help_group_separator,
    .{ .kind = .navigation, .key = .{ .action = .page_changes }, .description = "Changes page" },
    .{ .kind = .navigation, .key = .{ .action = .page_repository }, .description = "Repository page" },
    .{ .kind = .navigation, .key = .{ .action = .page_history }, .description = "History page" },
    .{ .kind = .navigation, .key = .{ .action = .page_compare }, .description = "Compare page" },
    .{ .kind = .navigation, .key = .{ .action = .repo_picker }, .description = "switch repository" },
    .{ .kind = .navigation, .key = .{ .text = "Tab" }, .description = "focus file tree / diff" },
    .{ .kind = .navigation, .key = .{ .text = "Home / End" }, .description = "first / last file" },
};

const help_common_global_actions = [_]HelpItem{
    .{ .key = .{ .action = .help }, .description = "open / close help" },
    .{ .key = .{ .text = "q" }, .description = "quit" },
};

const help_common_global_navigation = [_]HelpItem{
    .{ .kind = .navigation, .key = .{ .action = .page_changes }, .description = "Changes page" },
    .{ .kind = .navigation, .key = .{ .action = .page_repository }, .description = "Repository page" },
    .{ .kind = .navigation, .key = .{ .action = .page_history }, .description = "History page" },
    .{ .kind = .navigation, .key = .{ .action = .page_compare }, .description = "Compare page" },
    .{ .kind = .navigation, .key = .{ .action = .repo_picker }, .description = "switch repository" },
};

const help_compare_items = [_]HelpItem{
    .{ .key = .{ .text = "m" }, .description = "change comparison base" },
    .{ .key = .{ .action = .file_search }, .description = "search files" },
    .{ .key = .{ .action = .changed_file_filter }, .description = "filter files by change type" },
} ++ help_reviewed_items ++ [_]HelpItem{
    help_group_separator,
    .{ .kind = .navigation, .key = .{ .text = "Tab / j / k" }, .description = "focus and navigate files or diff" },
};

const help_compare_global_items = help_common_global_actions ++ [_]HelpItem{
    .{ .key = .{ .action = .reload }, .description = "refresh comparison" },
    .{ .key = .{ .action = .branch_switch }, .description = "checkout branch / open worktree" },
    help_group_separator,
} ++ help_common_global_navigation;

const help_history_items = [_]HelpItem{
    .{ .key = .{ .text = "Space" }, .description = "start / clear range (History)" },
    .{ .key = .{ .text = "Enter" }, .description = "open diff / load older commits" },
    .{ .key = .{ .action = .copy_history_detail }, .description = "copy detail (detail pane)" },
    .{ .key = .{ .pair = .{ .left = .decrease_sidebar_width, .right = .increase_sidebar_width } }, .description = "resize History pane" },
    .{ .key = .{ .text = "m" }, .description = "select commits again (from diff)" },
    .{ .key = .{ .action = .search }, .description = "search diff (not commits)" },
    .{ .key = .{ .text = "Esc" }, .description = "cancel / back to accepted diff" },
    help_group_separator,
    .{ .kind = .navigation, .key = .{ .text = "Tab / Shift+Tab" }, .description = "focus History / detail / files" },
    .{ .kind = .navigation, .key = .{ .text = "↑/↓ j/k" }, .description = "navigate the focused pane" },
    .{ .kind = .navigation, .key = .{ .pair = .{ .left = .page_up, .right = .page_down } }, .description = "move one visible page" },
    .{ .kind = .navigation, .key = .{ .pair = .{ .left = .document_first, .right = .document_last } }, .description = "first / last focused row" },
};

const help_history_global_items = help_common_global_actions ++ [_]HelpItem{
    .{ .key = .{ .action = .reload }, .description = "recheck and reload current HEAD" },
    .{ .key = .{ .action = .branch_switch }, .description = "checkout branch / open worktree" },
    help_group_separator,
} ++ help_common_global_navigation;

const help_history_marker_items = [_]HelpItem{
    .{ .kind = .information, .key = .{ .text = history_view.PickerMarker.range_selected }, .description = "commit in selected range" },
    .{ .kind = .information, .key = .{ .text = history_view.PickerMarker.merge }, .description = "merge commit" },
    .{ .kind = .information, .key = .{ .text = history_view.PickerMarker.root }, .description = "root commit" },
    .{ .kind = .information, .key = .{ .text = history_view.PickerMarker.unavailable_parent }, .description = "first parent unavailable" },
};

const help_history_sections = [_]HelpSection{
    .{ .title = "History", .items = &help_history_items },
    .{ .title = "Commit markers", .items = &help_history_marker_items },
    .{ .title = "Global", .items = &help_history_global_items },
    .{ .title = "Diff", .items = &help_diff_items },
};

const help_compare_sections = [_]HelpSection{
    .{ .title = "Compare", .items = &help_compare_items },
    .{ .title = "Global", .items = &help_compare_global_items },
    .{ .title = "Diff", .items = &help_diff_items },
};

const help_repository_global_items = help_common_global_actions ++ help_remote_items ++ [_]HelpItem{
    .{ .key = .{ .action = .reload }, .description = "force reload" },
    .{ .key = .{ .action = .open_editor }, .description = "open selected file in editor" },
    .{ .key = .{ .action = .branch_switch }, .description = "checkout branch / open worktree" },
    help_group_separator,
} ++ help_common_global_navigation;

const help_repository_tree_items = [_]HelpItem{
    .{ .key = .{ .text = "Enter / Space" }, .description = "toggle directory" },
    .{ .key = .{ .action = .file_search }, .description = "search files" },
    .{ .key = .{ .action = .changed_file_filter }, .description = "show all / changed files" },
    .{ .key = .{ .action = .toggle_sidebar }, .description = "show / hide file tree" },
    .{ .key = .{ .pair = .{ .left = .decrease_sidebar_width, .right = .increase_sidebar_width } }, .description = "resize file tree" },
    help_group_separator,
    .{ .kind = .navigation, .key = .{ .text = "Tab" }, .description = "focus file tree / source" },
    .{ .kind = .navigation, .key = .{ .text = "↑/↓ j/k" }, .description = "move selection" },
    .{ .kind = .navigation, .key = .{ .text = "Home / End" }, .description = "first / last file tree row" },
    .{ .kind = .navigation, .key = .{ .text = "←/→ h/l" }, .description = "scroll file tree horizontally" },
};

const help_repository_source_items = [_]HelpItem{
    .{ .key = .{ .text = "V" }, .description = "begin line selection" },
    .{ .key = .{ .text = "y / Esc" }, .description = "copy / clear selection" },
    .{ .key = .{ .text = "Y" }, .description = "copy selected code with context" },
    .{ .key = .{ .action = .search }, .description = "search source" },
    .{ .key = .{ .action = .toggle_line_numbers }, .description = "toggle line numbers" },
    help_group_separator,
    .{ .kind = .navigation, .key = .{ .pair = .{ .left = .previous_file, .right = .next_file } }, .description = "previous / next file (source)" },
    .{ .kind = .navigation, .key = .{ .text = "↑/↓ j/k" }, .description = "move one source row" },
    .{ .kind = .navigation, .key = .{ .pair = .{ .left = .document_first, .right = .document_last } }, .description = "first / last source row" },
    .{ .kind = .navigation, .key = .{ .pair = .{ .left = .half_page_up, .right = .half_page_down } }, .description = "half page up / down" },
    .{ .kind = .navigation, .key = .{ .pair = .{ .left = .page_backward, .right = .page_forward } }, .description = "page backward / forward" },
    .{ .kind = .navigation, .key = .{ .pair = .{ .left = .page_up, .right = .page_down } }, .description = "page up / down" },
    .{ .kind = .navigation, .key = .{ .text = "Home / End" }, .description = "first / last source row" },
    .{ .kind = .navigation, .key = .{ .text = ":number Enter" }, .description = "go to source line" },
    .{ .kind = .navigation, .key = .{ .text = "←/→ h/l" }, .description = "scroll source horizontally" },
    .{ .kind = .navigation, .key = .{ .text = "n / N / p" }, .description = "next / previous source match" },
};

const help_repository_sections = [_]HelpSection{
    .{ .title = "File tree", .items = &help_repository_tree_items },
    .{ .title = "Source", .items = &help_repository_source_items },
    .{ .title = "Global", .items = &help_repository_global_items },
};

const help_sidebar_items = [_]HelpItem{
    .{ .key = .{ .text = "Enter" }, .description = "toggle directory" },
    .{ .key = .{ .action = .file_search }, .description = "search files" },
    .{ .key = .{ .action = .changed_file_filter }, .description = "filter files by change type" },
} ++ help_reviewed_items ++ [_]HelpItem{
    .{ .key = .{ .pair = .{ .left = .decrease_sidebar_width, .right = .increase_sidebar_width } }, .description = "resize file tree" },
    help_group_separator,
    .{ .kind = .navigation, .key = .{ .text = "↑/↓ j/k" }, .description = "move selection" },
    .{ .kind = .navigation, .key = .{ .text = "←/→" }, .description = "collapse / expand directory" },
    .{ .kind = .navigation, .key = .{ .text = "h / l" }, .description = "scroll file tree horizontally" },
};

const help_diff_items = [_]HelpItem{
    .{ .key = .{ .text = "V" }, .description = "begin line selection" },
    .{ .key = .{ .action = .copy_current_line }, .description = "", .dynamic = .copy_line },
    .{ .key = .{ .action = .copy_current_hunk }, .description = "", .dynamic = .copy_hunk },
    .{ .key = .{ .action = .search }, .description = "search diff" },
    .{ .key = .{ .action = .toggle_display_mode }, .description = "unified / side-by-side" },
    .{ .key = .{ .action = .toggle_line_numbers }, .description = "toggle line numbers" },
    .{ .key = .{ .text = "Enter" }, .description = "fold / unfold hunk" },
    .{ .key = .{ .text = "y / Esc" }, .description = "copy / clear selection" },
    help_group_separator,
    .{ .kind = .navigation, .key = .{ .pair = .{ .left = .previous_file, .right = .next_file } }, .description = "previous / next file (diff focus)" },
    .{ .kind = .navigation, .key = .{ .text = "↑/↓ j/k" }, .description = "move one diff row" },
    .{ .kind = .navigation, .key = .{ .pair = .{ .left = .document_first, .right = .document_last } }, .description = "first / last diff row" },
    .{ .kind = .navigation, .key = .{ .pair = .{ .left = .half_page_up, .right = .half_page_down } }, .description = "half page up / down" },
    .{ .kind = .navigation, .key = .{ .pair = .{ .left = .page_backward, .right = .page_forward } }, .description = "page backward / forward" },
    .{ .kind = .navigation, .key = .{ .pair = .{ .left = .page_up, .right = .page_down } }, .description = "page up / down" },
    .{ .kind = .navigation, .key = .{ .text = "←/→" }, .description = "horizontal scroll" },
    .{ .kind = .navigation, .key = .{ .text = "J / K" }, .description = "next / previous hunk" },
    .{ .kind = .navigation, .key = .{ .text = "n / p" }, .description = "next / previous match or hunk" },
    .{ .kind = .navigation, .key = .{ .text = "N" }, .description = "previous search match when query is active" },
};

const help_left_sections = [_]HelpSection{
    .{ .title = "Git commands", .items = &help_git_command_items },
    .{ .title = "Global", .items = &help_global_items },
};

const help_right_sections = [_]HelpSection{
    .{ .title = "File tree", .items = &help_sidebar_items },
    .{ .title = "Diff", .items = &help_diff_items },
};

const help_all_sections = [_]HelpSection{
    .{ .title = "Git commands", .items = &help_git_command_items },
    .{ .title = "Global", .items = &help_global_items },
    .{ .title = "File tree", .items = &help_sidebar_items },
    .{ .title = "Diff", .items = &help_diff_items },
};

test "commit input renders maximum drafts and logical lines beyond u16" {
    const allocator = std.testing.allocator;
    const Case = struct { pattern: []const u8, bytes: usize };
    for ([_]Case{
        .{ .pattern = "\n", .bytes = 65534 },
        .{ .pattern = "\n", .bytes = 65535 },
        .{ .pattern = "\n", .bytes = 65536 },
        .{ .pattern = "x", .bytes = app_commit_panel.max_message_bytes },
        .{ .pattern = "界e\u{301}\t", .bytes = app_commit_panel.max_message_bytes },
    }) |case| {
        const bytes = try allocator.alloc(u8, case.bytes / case.pattern.len * case.pattern.len);
        defer allocator.free(bytes);
        var offset: usize = 0;
        while (offset < bytes.len) : (offset += case.pattern.len) @memcpy(bytes[offset..][0..case.pattern.len], case.pattern);
        var harness: ShellViewTestHarness = .{};
        harness.commit_panel = .init(allocator);
        defer harness.commit_panel.deinit();
        harness.commit_panel.open(.commit);
        harness.commit_panel.enter();
        harness.commit_panel.paste(bytes);
        try std.testing.expectEqualStrings(bytes, harness.commit_panel.body.slice());
        try std.testing.expect(harness.commit_panel.commit_error == null);

        var panel: chasen.testing.TestSurface = undefined;
        try panel.init(80, 24);
        defer panel.deinit();
        try viewCommitPanel(harness.context(), &panel.surface);
        try std.testing.expect(panel.screen.cursor_vis);
        try std.testing.expect(panel.screen.cursor.col < 80 and panel.screen.cursor.row < 24);
        if (case.pattern[0] == '\n') {
            try std.testing.expectEqual(case.bytes + 1, harness.commit_panel.body.lineCount());
            const indicator = try std.fmt.allocPrint(allocator, "{d}/{d}", .{ case.bytes + 1, case.bytes + 1 });
            defer allocator.free(indicator);
            const snapshot = try panel.snapshot(allocator);
            defer allocator.free(snapshot);
            try std.testing.expect(std.mem.indexOf(u8, snapshot, indicator) != null);
        }
        for ([_]u16{ 1, 2, 80 }) |width| {
            var body_surface: chasen.testing.TestSurface = undefined;
            try body_surface.init(width, 24);
            defer body_surface.deinit();
            try viewCommitBody(&harness.commit_panel.body, &body_surface.surface, true, .default());
            showBodyInputCursor(&body_surface.surface, &harness.commit_panel.body);
            try std.testing.expect(body_surface.screen.cursor_vis);
            try std.testing.expect(body_surface.screen.cursor.col < width and body_surface.screen.cursor.row < 24);
        }
    }
}

test "line stats presentation distinguishes unknown totals from known zero" {
    const allocator = std.testing.allocator;
    const Case = struct { stats: ?file_tree.Stats, text: []const u8 };
    for ([_]Case{
        .{ .stats = null, .text = "+? -?" },
        .{ .stats = .{}, .text = "+0 -0" },
        .{ .stats = .{ .added = 3, .removed = 1 }, .text = "+3 -1" },
        .{ .stats = .{ .added = 3, .complete = false }, .text = "+? -?" },
    }) |case| {
        var surface: chasen.testing.TestSurface = undefined;
        try surface.init(40, 1);
        defer surface.deinit();
        try @import("diff_surface/view.zig").drawStatusTitlePath(&surface.surface, "file.txt", case.stats, .default());
        const snapshot = try surface.snapshot(allocator);
        defer allocator.free(snapshot);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, case.text) != null);
        const stats = case.stats orelse file_tree.Stats{ .complete = false };
        if (!stats.complete) {
            const header = pageBarStatsText(&surface.surface, stats).?;
            try std.testing.expectEqualStrings("+?", header.added);
            try std.testing.expectEqualStrings("-?", header.removed);
        }
    }
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var status = try @import("../git/status.zig").StatusBundle.parseOwned(allocator, "?? known\x00?? unknown\x00");
    defer status.deinit();
    try status.attachLineStats(&.{.{ .path_key = "known", .stats = .{ .added = 2 } }});
    const tree = try file_tree.buildWithOptions(arena.allocator(), .{ .files = &.{} }, status.document, .{ .root = .{ .name = "repo" } });
    try std.testing.expectEqual(@as(usize, 2), tree.nodes[0].stats.added);
    try std.testing.expect(!tree.nodes[0].stats.complete);
}
