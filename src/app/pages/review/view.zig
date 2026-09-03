//! Review presentation built exclusively from shared diff-surface renderers.

const std = @import("std");
const chasen = @import("chasen");
const ui = @import("chasen_ui");
const draw = @import("draw");
const theme = @import("theme");
const review_page = @import("../review.zig");
const commit_time = @import("../../branch_commit_time.zig");
const review_navigation = @import("navigation.zig");
const diff_surface = @import("../../diff_surface.zig");
const diff_render = @import("../../../diff/render.zig");
const file_tree = @import("../../../file_tree.zig");
const keymap = @import("keymap");
const page_header = @import("../../page_header.zig");
const root_capability = @import("../../../repo/root_capability.zig");
const committed_review = @import("../../../committed_review.zig");
const review_store = @import("../../../review_store.zig");
const human_review_session = @import("../../human_review_session.zig");
const human_review_decision = @import("human_review_decision.zig");
const finding_card_view = @import("finding_card_view.zig");
const finding_projection = @import("../../../ai_review/finding_projection.zig");

pub const Context = struct {
    page: *const review_page.ReviewPageState,
    human_review: ?human_review_session.Presentation = null,
    palette: theme.Palette,
    repo_root: ?[]const u8,
    repo_epoch: u64,
    root_identity: ?root_capability.Identity,
    layout: diff_surface.Layout,
    keymap: keymap.Effective = .{},

    pub fn footer(self: Context) diff_surface.view.FooterView {
        const navigation = navigationView(self);
        var resolver = navigation.resolver();
        var result = diff_surface.view.footer(.{
            .surface = self.page.readSurface(.{ .range = "review" }, self.layout),
            .auto_reload_enabled = false,
            .selection_action_visible = navigation.bodyView(&resolver).retainedSelectionActionAvailable(),
        });
        // Review's BASE … HEAD header already identifies the comparison.
        // Do not expose its internal `.range = "review"` surface as footer UI.
        result.source_label = null;
        result.finding_summary = activeFindingSummary(self.page);
        return result;
    }
};

fn activeFindingProjection(page: *const review_page.ReviewPageState) ?*const finding_projection.FindingProjectionIndex {
    const pinned = page.pinnedAiConst() orelse return null;
    return &pinned.selection.finding_projection;
}

fn activeFindingSummary(page: *const review_page.ReviewPageState) ?diff_surface.view.FindingSummaryPresentation {
    const index = activeFindingProjection(page) orelse return null;
    return .{
        .mapped = index.summary.mapped,
        .unmapped = index.summary.unmapped,
        .stale = index.summary.stale,
        .failed = index.summary.failed,
    };
}

const FindingAnnotationAdapter = struct {
    projection: *const finding_projection.FindingProjectionIndex,

    fn interface(self: *FindingAnnotationAdapter) diff_surface.view.FindingAnnotationResolver {
        return .{ .ctx = self, .resolve_fn = resolve };
    }

    fn resolve(ctx: *anyopaque, file_index: usize) ?diff_surface.view.FindingAnnotation {
        const self: *FindingAnnotationAdapter = @ptrCast(@alignCast(ctx));
        return findingAnnotationForFile(self.projection, file_index);
    }
};

fn findingAnnotationForFile(
    projection: *const finding_projection.FindingProjectionIndex,
    file_index: usize,
) ?diff_surface.view.FindingAnnotation {
    if (file_index >= projection.files.len) return null;
    const summary = projection.files[file_index].summary;
    if (summary.total == 0) return null;
    return .{
        .total = summary.total,
        .mapped = summary.mapped,
        .highest_severity = if (summary.@"error" > 0)
            .@"error"
        else if (summary.warning > 0)
            .warning
        else
            .info,
    };
}

pub fn humanReviewActionLabel(app: Context) ?[]const u8 {
    if (app.page.human_review_decision.isOpen() or
        app.page.base_picker.open or app.page.ai_reviews.isOpen()) return null;
    const presentation = matchingHumanReviewPresentation(app) orelse return null;
    return switch (presentation.lifecycle) {
        .saving, .finalizing, .completed => "result",
        .failed => if (presentation.reconciliation == .reload_required) "result" else "finalize",
        .editable => "finalize",
    };
}

fn matchingHumanReviewPresentation(app: Context) ?human_review_session.Presentation {
    const pinned = app.page.pinnedAiConst() orelse return null;
    const presentation = app.human_review orelse return null;
    if (!pinned.binding().eql(presentation.binding)) return null;
    return presentation;
}

/// Project one accepted BASE-HEAD pair. Identity and current target must both
/// still match; otherwise a retained old BASE is never exposed in the header.
pub fn pageHeaderPresentation(app: Context) ?page_header.Presentation {
    if (app.repo_root == null) return null;
    const pending = sourcePending(app.page);
    const failed = app.page.basis_failure != null or
        app.page.load_failure != null or
        sourceFailed(app.page);
    const identity = app.page.accepted_repository_identity orelse
        return reviewTerminal(pending, failed);
    if (!identity.matches(app.repo_epoch, app.root_identity))
        return reviewTerminal(pending, failed);

    if (!app.page.hasAcceptedDisplay()) return reviewTerminal(pending, failed);
    const presentation = app.page.presentation orelse return reviewTerminal(pending, failed);
    const freshness: page_header.Freshness = if (pending)
        .refreshing
    else if (failed)
        .stale
    else
        .fresh;
    return switch (presentation) {
        .normal => |normal| result: {
            const target = app.page.base_target orelse break :result reviewTerminal(pending, failed);
            if (!std.mem.eql(u8, target.full_ref, normal.basis.base.full_ref))
                break :result reviewTerminal(pending, failed);
            break :result .{ .review = .{
                .base_display_name = normal.basis.base.display_name,
                .head_display_name = normal.basis.head_display,
                .freshness = freshness,
            } };
        },
        .pinned_ai => |pinned| .{ .review = .{
            .base_display_name = pinned.base_display,
            .head_display_name = pinned.head_display,
            .freshness = freshness,
        } },
    };
}

pub fn pageHeaderLineStats(app: Context) ?file_tree.Stats {
    return diff_surface.view.pageHeaderLineStats(
        app.page.readSurface(.{ .range = "review" }, app.layout),
    );
}

fn sourcePending(page: *const review_page.ReviewPageState) bool {
    return switch (page.activation.state) {
        .active => |active| active.members.source == .pending,
        .inactive => false,
    };
}

fn sourceFailed(page: *const review_page.ReviewPageState) bool {
    return switch (page.activation.state) {
        .active => |active| active.members.source == .failed,
        .inactive => false,
    };
}

fn reviewTerminal(pending: bool, failed: bool) ?page_header.Presentation {
    if (pending) return .{ .terminal = .{ .kind = .review, .state = .loading } };
    if (failed) return .{ .terminal = .{ .kind = .review, .state = .unavailable } };
    return null;
}

pub fn view(app: Context, surface: *chasen.Surface) !void {
    const navigation_context = navigationView(app);
    var mode_key_buffer: [16]u8 = undefined;
    var filter_key_buffer: [16]u8 = undefined;
    var pane_adapter = DiffPaneAdapter{
        .context = navigation_context,
        .palette = app.palette,
        .mode_toggle_key = displayModeToggleKey(app, mode_key_buffer[0..]),
        .human_review = matchingHumanReviewPresentation(app),
    };
    var finding_annotation_adapter: FindingAnnotationAdapter = undefined;
    const finding_annotation_resolver: ?diff_surface.view.FindingAnnotationResolver = if (activeFindingProjection(app.page)) |projection| blk: {
        finding_annotation_adapter = .{ .projection = projection };
        break :blk finding_annotation_adapter.interface();
    } else null;
    const empty_message: ?diff_surface.view.StateMessage = if (app.page.presentation) |presentation|
        switch (presentation) {
            .normal => |normal| try emptyStateMessage(surface.frameAllocator(), normal.basis.base.display_name, normal.basis.ahead_count),
            .pinned_ai => pinnedEmptyStateMessage(),
        }
    else
        null;

    if (!app.page.hasAcceptedDisplay() and (app.page.basis_failure != null or app.page.load_failure != null)) {
        return viewInitialFailure(app, surface);
    }

    try diff_surface.view.view(surface, .{
        .state = app.page.readSurface(.{ .range = "review" }, app.layout),
        .palette = app.palette,
        .source_label = "branch comparison",
        .repo_root = app.repo_root,
        .file_filter_binding = app.keymap.display(.changed_file_filter, filter_key_buffer[0..]),
        .no_changes_actions = .{},
        .empty_message = empty_message,
        .finding_annotation_resolver = finding_annotation_resolver,
        .diff_pane = pane_adapter.interface(),
    });
}

pub fn viewBasePicker(app: Context, surface: *chasen.Surface) !void {
    const picker = app.page.base_picker;
    if (!picker.open) return;

    const opts: ui.Modal.ViewOptions = .{
        .dialog_width = @min(surface.size().width, 96),
        .dialog_height = @min(surface.size().height, 22),
        .title = "Review base",
        .backdrop = false,
        .border = .rounded,
        .title_style = app.palette.boldStyle(.accent),
        .border_style = app.palette.style(.accent),
    };
    const frame = ui.Modal.frame(surface, opts) orelse return;
    var dialog = frame.dialogSurface();
    dialog.fillAll(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = .{} });
    frame.view();
    var content = frame.contentSurface();
    const size = content.size();
    if (size.height == 0) return;

    const list = picker.accepted;
    const visible_count = picker.visibleCount();
    const has_candidates = list != null and list.?.branches.len > 0 and visible_count > 0;
    const show_detail = has_candidates and size.height >= 4;
    const show_current = size.height >= if (show_detail) @as(u16, 5) else @as(u16, 4);
    const footer_row = size.height - 1;
    var next_row: u16 = 0;

    // Filter, one body row, and footer are the compact core. As height shrinks,
    // current-base is omitted before selected detail, and selected detail is
    // omitted before the final candidate/status row.
    if (show_current) {
        const current = if (app.page.normalBasisConst()) |basis|
            try std.fmt.allocPrint(content.frameAllocator(), "Current base: {s}", .{basis.base.display_name})
        else
            "Current base: resolving default";
        try draw.copyClippedTextAt(&content, 0, next_row, current, app.palette.style(.muted));
        next_row += 1;
    }

    if (next_row < footer_row) {
        const filter_prefix = if (picker.input_mode == .query) "Filter: /" else "Filter: ";
        try draw.copyClippedTextAt(&content, 0, next_row, filter_prefix, app.palette.style(.prompt));
        const prefix_width = content.displayWidth(filter_prefix);
        if (prefix_width < size.width) {
            var query_surface = content.child(.{
                .col = prefix_width,
                .row = next_row,
                .width = size.width - prefix_width,
                .height = 1,
            });
            try draw.copyClippedTextAt(&query_surface, 0, 0, picker.query.slice(), chasen.TextStyle{});
        }
        if (picker.input_mode == .query and size.width > 0) {
            const cursor = @min(size.width - 1, prefix_width + content.displayWidth(picker.query.slice()));
            content.showCursor(cursor, next_row);
        }
        next_row += 1;
    }

    if (show_detail and next_row < footer_row) {
        if (picker.selectedItem()) |item| {
            const exact = commit_time.formatExactUtc(item.tip_committer_unix);
            const detail = if (exact) |value|
                try std.fmt.allocPrint(content.frameAllocator(), "last commit: {s}  {s}", .{ value.text(), item.full_ref })
            else
                try std.fmt.allocPrint(content.frameAllocator(), "last commit: unknown  {s}", .{item.full_ref});
            try draw.copyClippedTextAt(&content, 0, next_row, detail, app.palette.style(.muted));
        }
        next_row += 1;
    }

    const list_start = next_row;
    const rows = footer_row -| list_start;
    if (rows > 0) {
        if (picker.loading) {
            try draw.copyClippedTextAt(&content, 0, list_start, "Loading local and remote branches...", app.palette.style(.prompt));
        } else if (picker.failureText()) |message| {
            try draw.copyClippedTextAt(&content, 0, list_start, firstLine(message), app.palette.style(.danger));
        } else if (list == null) {
            try draw.copyClippedTextAt(&content, 0, list_start, "No branches", app.palette.style(.muted));
        } else if (list.?.branches.len == 0) {
            try draw.copyClippedTextAt(&content, 0, list_start, "No local or remote branches", app.palette.style(.muted));
        } else if (visible_count == 0) {
            const message = try std.fmt.allocPrint(content.frameAllocator(), "No branches match \"{s}\"", .{picker.query.slice()});
            try draw.copyClippedTextAt(&content, 0, list_start, message, app.palette.style(.muted));
        }
    }
    const selected = if (visible_count == 0) 0 else picker.filter.list.focusedIndex();
    const start = listWindowStart(selected, visible_count, rows);
    var row: u16 = 0;
    while (has_candidates and row < rows and start + row < visible_count) : (row += 1) {
        const visible_index = start + row;
        const source_index = picker.filter.sourceIndex(visible_index) orelse continue;
        if (source_index >= list.?.branches.len) continue;
        const item = list.?.branches[source_index];
        const focused = visible_index == selected;
        const style = if (focused) app.palette.boldStyle(.accent) else chasen.TextStyle{};
        const marker: []const u8 = if (focused) ">" else " ";
        try draw.copyClippedTextAt(&content, 0, list_start + row, marker, app.palette.style(.accent));

        const relative = commit_time.formatRelative(item.tip_committer_unix, picker.render_now_unix);
        const relative_width = content.displayWidth(relative.text());
        const time_field_width: u16 = @min(size.width, 14);
        const time_col = size.width - time_field_width;
        const rendered_relative_width = @min(relative_width, time_field_width);
        try draw.copyClippedTextAt(
            &content,
            time_col + time_field_width - rendered_relative_width,
            list_start + row,
            relative.text(),
            if (focused) app.palette.boldStyle(.accent) else app.palette.style(.muted),
        );

        const show_kind = size.width >= 84;
        const branch_col: u16 = if (show_kind) 11 else 2;
        if (show_kind) {
            const kind: []const u8 = if (item.kind == .local) "[local]" else "[remote]";
            try draw.copyClippedTextAt(&content, 2, list_start + row, kind, app.palette.style(.muted));
        }
        const branch_end = time_col -| 1;
        if (branch_end > branch_col) {
            var branch_surface = content.child(.{
                .col = branch_col,
                .row = list_start + row,
                .width = branch_end - branch_col,
                .height = 1,
            });
            try draw.copyClippedTextAt(&branch_surface, 0, 0, item.name, style);
        }
    }
    const footer = if (picker.input_mode == .query)
        "Type: filter  Up/Down: move  Tab: command  Esc: clear"
    else
        "/: filter  j/k: move  Enter: review  Esc: close";
    try draw.copyClippedTextAt(&content, 0, footer_row, footer, app.palette.style(.accent));
}

pub fn viewAiReviews(app: Context, surface: *chasen.Surface) !void {
    const picker = &app.page.ai_reviews;
    if (!picker.isOpen()) return;

    const opts: ui.Modal.ViewOptions = .{
        .dialog_width = @min(surface.size().width, 112),
        .dialog_height = @min(surface.size().height, 24),
        .title = "Reviews",
        .backdrop = false,
        .border = .rounded,
        .title_style = app.palette.boldStyle(.accent),
        .border_style = app.palette.style(.accent),
    };
    const frame = ui.Modal.frame(surface, opts) orelse return;
    var dialog = frame.dialogSurface();
    dialog.fillAll(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = .{} });
    frame.view();
    var content = frame.contentSurface();
    const size = content.size();
    if (size.height == 0) return;
    const footer_row = size.height - 1;
    var next_row: u16 = 0;

    if (next_row < footer_row) {
        const filter_prefix = if (picker.queryMode()) "Filter: /" else "Filter: ";
        try draw.copyClippedTextAt(&content, 0, next_row, filter_prefix, app.palette.style(.prompt));
        const prefix_width = content.displayWidth(filter_prefix);
        if (prefix_width < size.width) {
            var query_surface = content.child(.{
                .col = prefix_width,
                .row = next_row,
                .width = size.width - prefix_width,
                .height = 1,
            });
            try draw.copyClippedTextAt(&query_surface, 0, 0, picker.query.slice(), chasen.TextStyle{});
        }
        if (picker.queryMode() and size.width > 0) {
            const cursor = @min(size.width - 1, prefix_width + content.displayWidth(picker.query.slice()));
            content.showCursor(cursor, next_row);
        }
        next_row += 1;
    }

    const capabilities = picker.interactionCapabilities();
    const retained_list = capabilities.list;
    const mixed_invalid = retained_list and picker.rows().len > 0 and picker.skippedCount() > 0;
    const available_rows = footer_row -| next_row;
    const detail_rows: u16 = if (!retained_list)
        0
    else if (mixed_invalid)
        if (available_rows >= 7) 3 else if (available_rows >= 4) 1 else 0
    else if (available_rows >= 6)
        2
    else
        0;
    const list_end = footer_row -| detail_rows;

    if (retained_list and next_row < list_end) {
        try drawAiNormalRow(app, &content, next_row, picker.focus == 0);
        next_row += 1;
        if (next_row < list_end) {
            try draw.copyClippedTextAt(&content, 0, next_row, "────────────────────────────────────────", app.palette.style(.muted));
            next_row += 1;
        }

        const visible_runs = picker.filter.source_indexes.len;
        const run_rows = list_end -| next_row;
        if (visible_runs == 0 and run_rows > 0) {
            if (try aiReviewsStateMessage(app, content.frameAllocator())) |message| {
                try draw.copyClippedTextAt(&content, 0, next_row, message.text, messageStyle(app, message.failure));
            } else if (picker.query.len > 0) {
                const message = try std.fmt.allocPrint(content.frameAllocator(), "No AI reviews match \"{s}\"", .{picker.query.slice()});
                try draw.copyClippedTextAt(&content, 0, next_row, message, app.palette.style(.muted));
            }
        } else if (run_rows > 0) {
            const selected_run = picker.focus -| 1;
            const start = listWindowStart(selected_run, visible_runs, run_rows);
            var row_offset: u16 = 0;
            while (row_offset < run_rows and start + row_offset < visible_runs) : (row_offset += 1) {
                const visible_index = start + row_offset;
                const source_index = picker.filter.sourceIndex(visible_index) orelse continue;
                const rows = picker.rows();
                if (source_index >= rows.len) continue;
                try drawAiReviewRow(
                    app,
                    &content,
                    next_row + row_offset,
                    rows[source_index],
                    picker.focus == visible_index + 1,
                );
            }
        }

        if (detail_rows > 0) {
            const detail_start = footer_row - detail_rows;
            var detail_row = detail_start;
            if (mixed_invalid) {
                const message = try aiReviewsSkippedMessage(picker, content.frameAllocator());
                try draw.copyClippedTextAt(&content, 0, detail_row, message, app.palette.style(.muted));
                detail_row += 1;
            }
            if (detail_row < footer_row) {
                if (try aiReviewsStateMessage(app, content.frameAllocator())) |message| {
                    try draw.copyClippedTextAt(&content, 0, detail_row, message.text, messageStyle(app, message.failure));
                } else if (picker.selectedRow()) |selected| {
                    try drawAiReviewDetail(app, &content, detail_row, selected);
                } else {
                    const detail = if (app.page.isPinnedAi())
                        "Return to the current branch comparison"
                    else
                        "Current branch comparison";
                    try draw.copyClippedTextAt(&content, 0, detail_row, detail, app.palette.style(.muted));
                }
            }
        }
    } else if (next_row < footer_row) {
        if (try aiReviewsStateMessage(app, content.frameAllocator())) |message| {
            try draw.copyClippedTextAt(&content, 0, next_row, message.text, messageStyle(app, message.failure));
        }
        if (next_row + 1 < footer_row) {
            if (picker.selectedRow()) |selected| try drawAiReviewDetail(app, &content, next_row + 1, selected);
        }
    }

    const footer = aiReviewsFooterText(picker);
    try draw.copyClippedTextAt(&content, 0, footer_row, footer, app.palette.style(.accent));
}

pub fn viewHumanReviewDecision(app: Context, surface: *chasen.Surface) !void {
    if (!app.page.human_review_decision.isOpen()) return;
    const presentation = matchingHumanReviewPresentation(app);
    const lifecycle = if (presentation) |value| value.lifecycle else null;
    const completed = lifecycle != null and lifecycle.? == .completed;
    const opts: ui.Modal.ViewOptions = .{
        .dialog_width = @min(surface.size().width, 88),
        .dialog_height = @min(surface.size().height, 24),
        .title = if (completed) "Human review result" else "Finalize human review",
        .backdrop = false,
        .border = .rounded,
        .title_style = app.palette.boldStyle(if (completed) .staged else .accent),
        .border_style = app.palette.style(if (lifecycle != null and lifecycle.? == .failed) .danger else .accent),
    };
    const frame = ui.Modal.frame(surface, opts) orelse return;
    var dialog = frame.dialogSurface();
    dialog.fillAll(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = .{} });
    frame.view();
    var content = frame.contentSurface();
    const size = content.size();
    if (size.height == 0) return;
    const footer_row = size.height - 1;
    var row: u16 = 0;

    if (presentation == null) {
        if (row < footer_row) {
            try draw.copyClippedTextAt(&content, 0, row, "Pinned review session is no longer available", app.palette.style(.danger));
            row += 1;
        }
        if (row < footer_row) {
            try draw.copyClippedTextAt(&content, 0, row, "Close this overlay and reopen the pinned Review.", app.palette.style(.muted));
        }
        try draw.copyClippedTextAt(&content, 0, footer_row, "Esc/q: close", app.palette.style(.accent));
        return;
    }
    const current = presentation.?;
    const snapshot = current.snapshot;
    const read_only = current.lifecycle == .saving or
        current.lifecycle == .finalizing or
        current.lifecycle == .completed or
        current.reconciliation == .reload_required;

    if (row < footer_row) {
        const status = try humanReviewLifecycleText(current, content.frameAllocator());
        const tone: theme.Role = switch (current.lifecycle) {
            .completed => .staged,
            .failed => .danger,
            .saving, .finalizing => .prompt,
            .editable => .accent,
        };
        try draw.copyClippedTextAt(&content, 0, row, status, app.palette.boldStyle(tone));
        row += 1;
    }
    if (row < footer_row) {
        const review_id = current.binding.review_id.canonical();
        const identity = try std.fmt.allocPrint(content.frameAllocator(), "Run {s}", .{&review_id});
        try draw.copyClippedTextAt(&content, 0, row, identity, app.palette.style(.muted));
        row += 1;
    }

    const displayed_decision = if (current.lifecycle == .completed)
        current.decision
    else
        app.page.human_review_decision.selectedDecision();
    const focus = app.page.human_review_decision.focus();
    inline for ([_]struct {
        value: committed_review.ReviewResultValue,
        focus: human_review_decision.Focus,
        label: []const u8,
    }{
        .{ .value = .approved, .focus = .approved, .label = "Approved" },
        .{ .value = .needs_changes, .focus = .needs_changes, .label = "Needs changes" },
        .{ .value = .canceled, .focus = .canceled, .label = "Canceled" },
    }) |choice| {
        if (row >= footer_row) break;
        const selected = displayed_decision != null and displayed_decision.? == choice.value;
        const focused = !read_only and focus != null and focus.? == choice.focus;
        const line = try std.fmt.allocPrint(content.frameAllocator(), "{s} [{s}] {s}", .{
            if (focused) ">" else " ",
            if (selected) "x" else " ",
            choice.label,
        });
        try draw.copyClippedTextAt(
            &content,
            0,
            row,
            line,
            if (focused) app.palette.boldStyle(.accent) else if (selected) app.palette.style(.staged) else chasen.TextStyle{},
        );
        row += 1;
    }

    if (snapshot) |value| {
        if (row < footer_row and size.height >= 11) {
            const evidence = try std.fmt.allocPrint(content.frameAllocator(), "Evidence  {d} accepted finding{s}  {d} anchored note{s}", .{
                acceptedDispositionCount(value.finding_dispositions),
                if (acceptedDispositionCount(value.finding_dispositions) == 1) "" else "s",
                value.anchored_notes.len,
                if (value.anchored_notes.len == 1) "" else "s",
            });
            try draw.copyClippedTextAt(&content, 0, row, evidence, app.palette.style(.muted));
            row += 1;
        }
    }

    if (row < footer_row) {
        const summary_focused = !read_only and focus != null and focus.? == .summary;
        const summary_label = if (read_only)
            "Summary (read-only)"
        else if (summary_focused)
            "> Summary"
        else
            "  Summary";
        try draw.copyClippedTextAt(
            &content,
            0,
            row,
            summary_label,
            if (summary_focused) app.palette.boldStyle(.accent) else app.palette.style(.prompt),
        );
        row += 1;
    }

    const diagnostic = humanReviewDiagnostic(app, current);
    const submit_rows: u16 = if (read_only) 0 else 1;
    const diagnostic_rows: u16 = @intFromBool(diagnostic.len != 0);
    const summary_end = footer_row -| (submit_rows + diagnostic_rows);
    if (row < summary_end) {
        var summary_surface = content.child(.{
            .col = 2,
            .row = row,
            .width = size.width -| 2,
            .height = summary_end - row,
        });
        if (read_only) {
            drawReadonlySummary(
                &summary_surface,
                if (snapshot) |value| value.summary orelse "(none)" else "(none)",
                app.palette.style(.muted),
            );
        } else if (app.page.human_review_decision.summaryArea()) |area| {
            area.view(&summary_surface, .{
                .scroll_line = app.page.human_review_decision.summaryScrollLine(summary_surface.size().height),
                .style = chasen.TextStyle{},
                .placeholder_style = app.palette.style(.muted),
                .show_cursor = app.page.human_review_decision.summaryEditing(),
            });
        }
        row = summary_end;
    }

    if (submit_rows != 0 and row < footer_row) {
        const submit_focused = focus != null and focus.? == .submit;
        try draw.copyClippedTextAt(
            &content,
            0,
            row,
            if (submit_focused) "> [ Submit ]" else "  [ Submit ]",
            if (submit_focused) app.palette.boldStyle(.accent) else app.palette.style(.muted),
        );
        row += 1;
    }
    if (diagnostic.len != 0 and row < footer_row) {
        try draw.copyClippedTextAt(
            &content,
            0,
            row,
            diagnostic,
            app.palette.style(if (current.lifecycle == .failed or
                app.page.human_review_decision.feedback() != .submitting) .danger else .prompt),
        );
    }

    const footer = switch (current.lifecycle) {
        .completed => "Esc/q: close  E: reopen after close",
        .saving, .finalizing => "Completing continues after Esc/q: close",
        .failed => if (current.reconciliation == .reload_required)
            "Esc/q: close  Reload the pinned Review before retry"
        else if (focus != null and focus.? == .summary and app.page.human_review_decision.summaryEditing())
            "Type: summary  Tab: Submit  Esc: leave summary"
        else if (focus != null and focus.? == .summary)
            "Enter: edit summary  Tab/j/k: move  Esc/q: close"
        else
            "Tab/j/k: move  Enter/Space: select  Esc/q: close",
        .editable => if (focus != null and focus.? == .summary and app.page.human_review_decision.summaryEditing())
            "Type: summary  Tab: Submit  Esc: leave summary"
        else if (focus != null and focus.? == .summary)
            "Enter: edit summary  Tab/j/k: move  Esc/q: close"
        else
            "Tab/j/k: move  Enter/Space: select  Esc/q: close",
    };
    try draw.copyClippedTextAt(&content, 0, footer_row, footer, app.palette.style(.accent));
}

fn humanReviewLifecycleText(
    presentation: human_review_session.Presentation,
    allocator: std.mem.Allocator,
) ![]const u8 {
    return switch (presentation.lifecycle) {
        .editable => "Ready for human decision",
        .saving => "Saving review draft...",
        .finalizing => "Completing review result...",
        .failed => if (presentation.reconciliation == .reload_required)
            "Review state requires reload"
        else
            "Completion failed — review and retry",
        .completed => if (presentation.completed_at) |completed_at|
            try std.fmt.allocPrint(allocator, "Completed at {s}", .{completed_at.*[0..]})
        else
            "Completed",
    };
}

fn humanReviewDiagnostic(
    app: Context,
    presentation: human_review_session.Presentation,
) []const u8 {
    switch (presentation.lifecycle) {
        .saving, .finalizing, .completed => return "",
        .editable, .failed => {},
    }
    if (presentation.lifecycle == .failed) {
        if (presentation.reconciliation == .reload_required) return "Binding/revision drift detected; reload before retry";
        if (presentation.failure) |reason| return switch (reason) {
            .persistence => "Persistence failed; Submit retries the preserved snapshot",
            .admission => "Store admission failed; Submit retries without losing the form",
            .internal_mismatch => "Operation state changed unexpectedly; reload before retry",
        };
        return "Completion failed; the preserved form remains available for retry";
    }
    return app.page.human_review_decision.feedback().text();
}

fn acceptedDispositionCount(values: []const committed_review.FindingDisposition) usize {
    var count: usize = 0;
    for (values) |value| if (value.disposition == .accepted) {
        count += 1;
    };
    return count;
}

fn drawReadonlySummary(surface: *chasen.Surface, text: []const u8, style: chasen.TextStyle) void {
    const height = surface.size().height;
    if (height == 0) return;
    var row: u16 = 0;
    var start: usize = 0;
    var index: usize = 0;
    while (index <= text.len and row < height) : (index += 1) {
        if (index == text.len or text[index] == '\n') {
            draw.copyClippedTextAt(surface, 0, row, text[start..index], style) catch {};
            row += 1;
            start = index + 1;
        }
    }
}

const AiReviewsStateMessage = struct {
    text: []const u8,
    failure: bool = false,
};

fn aiReviewsStateMessage(
    app: Context,
    allocator: std.mem.Allocator,
) !?AiReviewsStateMessage {
    const picker = &app.page.ai_reviews;
    return switch (picker.phase) {
        .closed, .ready => null,
        .scan_loading => .{ .text = "Loading AI reviews..." },
        .selection_loading => if (picker.selectedRow()) |selected|
            .{ .text = try std.fmt.allocPrint(allocator, "Loading review... {s}  {s}@{s} -> {s}@{s}", .{
                selected.producer_name,
                selected.base_label orelse "base",
                selected.target.base_oid.short(),
                selected.head_label orelse "head",
                selected.target.head_oid.short(),
            }) }
        else if (app.page.pinnedAiConst()) |pinned|
            .{ .text = try directPinnedLoadingText(
                allocator,
                pinned.selection.artifacts.manifest.value.producer.name,
                pinned.base_display,
                pinned.head_display,
            ) }
        else
            .{ .text = "Loading review..." },
        .return_loading => if (app.page.base_target) |base|
            .{ .text = try std.fmt.allocPrint(allocator, "Loading normal review... {s} -> current branch", .{base.display_name}) }
        else
            .{ .text = "Loading normal review..." },
        .scan_failed => |message| .{ .text = firstLine(message), .failure = true },
        .selection_failed => |failure| .{ .text = firstLine(failure.message), .failure = true },
        .return_failed => |failure| .{ .text = firstLine(failure.message), .failure = true },
        .empty => |kind| switch (kind) {
            .no_reviews => .{ .text = "No AI reviews for this repository" },
            .invalid_only => if (picker.firstDiagnostic()) |reason|
                .{ .text = try std.fmt.allocPrint(allocator, "No valid AI reviews ({d} skipped: {s})", .{ picker.skippedCount(), firstLine(reason) }) }
            else
                .{ .text = try std.fmt.allocPrint(allocator, "No valid AI reviews ({d} skipped)", .{picker.skippedCount()}) },
        },
    };
}

fn aiReviewsSkippedMessage(
    picker: *const review_page.AiReviewsPickerState,
    allocator: std.mem.Allocator,
) ![]const u8 {
    return if (picker.firstDiagnostic()) |reason|
        try std.fmt.allocPrint(allocator, "{d} invalid reviews skipped: {s}", .{ picker.skippedCount(), firstLine(reason) })
    else
        try std.fmt.allocPrint(allocator, "{d} invalid reviews skipped", .{picker.skippedCount()});
}

fn messageStyle(app: Context, failure: bool) chasen.TextStyle {
    return if (failure) app.palette.style(.danger) else app.palette.style(.muted);
}

fn drawAiNormalRow(app: Context, surface: *chasen.Surface, row: u16, focused: bool) !void {
    const focus_marker: []const u8 = if (focused) ">" else " ";
    const current_marker: []const u8 = if (!app.page.isPinnedAi()) "*" else " ";
    const summary = if (app.page.normalBasisConst()) |basis|
        try std.fmt.allocPrint(surface.frameAllocator(), "{s}@{s} -> {s}@{s}", .{
            basis.base.display_name,
            basis.target.base_oid.short(),
            basis.head_display,
            basis.target.head_oid.short(),
        })
    else if (app.page.base_target) |base|
        try std.fmt.allocPrint(surface.frameAllocator(), "{s} -> current branch", .{base.display_name})
    else
        "current branch comparison";
    const text = try std.fmt.allocPrint(surface.frameAllocator(), "{s}{s} Normal Review  {s}", .{ focus_marker, current_marker, summary });
    try draw.copyClippedTextAt(
        surface,
        0,
        row,
        text,
        if (focused) app.palette.boldStyle(.accent) else chasen.TextStyle{},
    );
}

fn drawAiReviewRow(
    app: Context,
    surface: *chasen.Surface,
    row_index: u16,
    item: review_store.RunSummary,
    focused: bool,
) !void {
    const focus_marker: []const u8 = if (focused) ">" else " ";
    const current_marker: []const u8 = if (app.page.isCurrentReviewTarget(&item.target)) "*" else " ";
    const status = if (item.availability == .missing) "target unavailable" else review_page.runSummaryStatusText(item.status);
    const relative = commit_time.formatRelative(item.created_at_unix, app.page.ai_reviews.render_now_unix);
    const finding_label: []const u8 = if (item.finding_count == 1) "finding" else "findings";
    const width = surface.size().width;
    const text = if (width >= 96 and item.producer_model != null)
        try std.fmt.allocPrint(surface.frameAllocator(), "{s}{s} {s}  {s}  {d} {s}  {s}  {s}", .{
            focus_marker, current_marker, item.producer_name, item.producer_model.?, item.finding_count, finding_label, status, relative.text(),
        })
    else if (width >= 68)
        try std.fmt.allocPrint(surface.frameAllocator(), "{s}{s} {s}  {d} {s}  {s}  {s}", .{
            focus_marker, current_marker, item.producer_name, item.finding_count, finding_label, status, relative.text(),
        })
    else if (width >= 42)
        try std.fmt.allocPrint(surface.frameAllocator(), "{s}{s} {s}  {d} {s}  {s}", .{
            focus_marker, current_marker, item.producer_name, item.finding_count, finding_label, status,
        })
    else
        try std.fmt.allocPrint(surface.frameAllocator(), "{s}{s} {s}  {s}", .{ focus_marker, current_marker, item.producer_name, status });
    try draw.copyClippedTextAt(
        surface,
        0,
        row_index,
        text,
        if (focused) app.palette.boldStyle(.accent) else chasen.TextStyle{},
    );
}

fn drawAiReviewDetail(
    app: Context,
    surface: *chasen.Surface,
    start_row: u16,
    item: *const review_store.RunSummary,
) !void {
    const base_label = item.base_label orelse "base";
    const head_label = item.head_label orelse "head";
    const target = try std.fmt.allocPrint(surface.frameAllocator(), "{s}@{s} -> {s}@{s}", .{
        base_label, item.target.base_oid.short(), head_label, item.target.head_oid.short(),
    });
    try draw.copyClippedTextAt(surface, 0, start_row, target, app.palette.style(.muted));
    if (start_row + 1 >= surface.size().height -| 1) return;
    const review_id = item.review_id.canonical();
    const detail = try std.fmt.allocPrint(surface.frameAllocator(), "created {s}  review {s}", .{ &item.created_at, review_id[0..8] });
    try draw.copyClippedTextAt(surface, 0, start_row + 1, detail, app.palette.style(.muted));
}

fn aiReviewsFooterText(picker: *const review_page.AiReviewsPickerState) []const u8 {
    const capabilities = picker.interactionCapabilities();
    if (picker.queryMode()) return "Type: filter  Up/Down: move  Tab: command  Esc: clear/list";
    if (capabilities.cancel) return "r: retry  Esc: cancel";
    if (capabilities.list) return "/: filter  j/k: move  Enter: open  r: refresh/retry  Esc/q: close";
    return "r: retry  Esc/q: close";
}

fn directPinnedLoadingText(
    allocator: std.mem.Allocator,
    producer: []const u8,
    base_display: []const u8,
    head_display: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "Loading review... {s}  {s} -> {s}", .{
        producer,
        base_display,
        head_display,
    });
}

const DiffPaneAdapter = struct {
    context: review_navigation.View,
    palette: theme.Palette,
    mode_toggle_key: ?[]const u8,
    human_review: ?human_review_session.Presentation,

    fn interface(self: *DiffPaneAdapter) diff_surface.view.DiffPaneRenderer {
        return .{ .ctx = self, .render_fn = render };
    }

    fn render(ctx: *anyopaque, surface: *chasen.Surface, loaded: @import("../../../loaded_diff.zig").LoadedDiff) !void {
        const self: *DiffPaneAdapter = @ptrCast(@alignCast(ctx));
        const allocator = surface.frameAllocator();
        var frame = try self.context.buildFindingCardFrame(allocator);
        defer if (frame) |*value| value.deinit(allocator);
        const rows = if (frame) |*value| &value.presentation_rows else null;
        const context = self.context.withPresentationRows(rows);
        var adapter = context.resolver();
        var card_painter: finding_card_view.Painter = undefined;
        const painter: ?diff_render.InlineRowPainter = if (frame) |*value| blk: {
            card_painter = .{
                .page = self.context.page,
                .row_plan = &value.row_plan,
                .palette = self.palette,
                .human_review = self.human_review,
            };
            break :blk card_painter.interface();
        } else null;
        return diff_surface.view.viewDiffPane(
            surface,
            context.bodyView(&adapter),
            loaded,
            self.palette,
            null,
            self.mode_toggle_key,
            painter,
        );
    }
};

fn navigationView(app: Context) review_navigation.View {
    var key_buffer: [16]u8 = undefined;
    return .{
        .page = app.page,
        .repo_root = app.repo_root,
        .repo_epoch = app.repo_epoch,
        .root_identity = app.root_identity,
        .layout = app.layout,
        .mode_toggle_hint_width = diff_render.modeToggleHintWidth(
            displayModeToggleKey(app, key_buffer[0..]),
        ),
    };
}

fn displayModeToggleKey(app: Context, buffer: []u8) ?[]const u8 {
    if (app.page.search.mode or app.page.file_search.mode or app.page.base_picker.open or app.page.ai_reviews.isOpen()) return null;
    return app.keymap.display(.toggle_display_mode, buffer);
}

fn viewInitialFailure(app: Context, surface: *chasen.Surface) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;
    const message = if (app.page.basis_failure) |failure|
        try basisFailureText(surface.frameAllocator(), failure)
    else
        firstLine(app.page.load_failure.?);
    const row = size.height / 2;
    try draw.copyClippedTextAt(surface, 1, row, message, app.palette.boldStyle(.danger));
    if (row + 2 < size.height) {
        try draw.copyClippedTextAt(surface, 1, row + 2, "Press m to choose a base or r to retry.", app.palette.style(.muted));
    }
}

fn basisFailureText(allocator: std.mem.Allocator, failure: review_page.BasisFailureState) ![]const u8 {
    return switch (failure.kind) {
        .missing_base_ref => try std.fmt.allocPrint(allocator, "base {s} not found", .{failure.attempted.display_name}),
        .no_merge_base => try std.fmt.allocPrint(allocator, "no merge base with {s} (shallow clone may have insufficient history)", .{failure.attempted.display_name}),
        .head_unresolved => "HEAD could not be resolved",
    };
}

fn firstLine(text: []const u8) []const u8 {
    if (std.mem.indexOfAny(u8, text, "\r\n")) |end| return text[0..end];
    return text;
}

fn emptyStateMessage(
    allocator: std.mem.Allocator,
    base_display_name: []const u8,
    ahead_count: usize,
) !diff_surface.view.StateMessage {
    if (ahead_count == 0) return .{
        .title = try std.fmt.allocPrint(allocator, "Up to date with {s}", .{base_display_name}),
        .body = try std.fmt.allocPrint(allocator, "No commits are ahead of {s}.", .{base_display_name}),
        .hint = "Press m to choose another base or r to refresh.",
    };

    return .{
        .title = try std.fmt.allocPrint(allocator, "No file changes against {s}", .{base_display_name}),
        .body = if (ahead_count == 1)
            try std.fmt.allocPrint(allocator, "1 commit is ahead of {s}, but its net file diff is empty.", .{base_display_name})
        else
            try std.fmt.allocPrint(allocator, "{d} commits are ahead of {s}, but their net file diff is empty.", .{ ahead_count, base_display_name }),
        .hint = "Press m to choose another base or r to refresh.",
    };
}

fn pinnedEmptyStateMessage() diff_surface.view.StateMessage {
    return .{
        .title = "No file changes in AI review",
        .body = "The selected AI review has an empty net file diff.",
        .hint = "Press a to choose another review or m to return to normal Review.",
    };
}

fn listWindowStart(selected: usize, len: usize, rows: u16) usize {
    if (rows == 0 or len == 0) return 0;
    const visible: usize = @intCast(rows);
    if (len <= visible) return 0;
    return @min(selected -| (visible / 2), len - visible);
}

test "empty Review state distinguishes zero ahead commits from an empty net file diff" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const message = try emptyStateMessage(arena.allocator(), "main", 0);
    try std.testing.expectEqualStrings("Up to date with main", message.title);
    try std.testing.expectEqualStrings("No commits are ahead of main.", message.body);
}

test "Review page header binds the accepted pair to repository and target" {
    const allocator = std.testing.allocator;
    var state: review_page.ReviewPageState = .{};
    defer state.deinit(allocator);
    _ = state.activate(7);
    state.activation.state.active.members.source = .fresh;
    state.presentation = .{ .normal = .{ .basis = .{
        .base = .{
            .full_ref = try allocator.dupe(u8, "refs/remotes/origin/main"),
            .display_name = try allocator.dupe(u8, "origin/main"),
            .kind = .remote_tracking,
        },
        .head_display = try allocator.dupe(u8, "HEAD@0123456"),
        .target = .{
            .object_format = .sha1,
            .source_kind = .branch_range,
            .base_oid = .{},
            .head_oid = .{},
            .diff_base_oid = .{},
        },
        .ahead_count = 2,
    } } };
    state.base_target = .{
        .full_ref = try allocator.dupe(u8, "refs/remotes/origin/main"),
        .display_name = try allocator.dupe(u8, "origin/main"),
        .kind = .remote_tracking,
    };
    const root_identity: root_capability.Identity = .{ .device = 5, .inode = 8 };
    state.accepted_repository_identity = .{ .repo_epoch = 7, .root_identity = root_identity };
    state.load.state = .{ .empty = .no_changes };
    var context: Context = .{
        .page = &state,
        .palette = .default(),
        .repo_root = "/repo",
        .repo_epoch = 7,
        .root_identity = root_identity,
        .layout = .{ .width = 80, .height = 12 },
    };

    try std.testing.expect(context.footer().source_label == null);
    const accepted = pageHeaderPresentation(context).?;
    const text = (try page_header.formatAlloc(allocator, accepted, 80)).?;
    defer allocator.free(text);
    try std.testing.expectEqualStrings("BASE origin/main  …  HEAD HEAD@0123456", text);

    context.root_identity = .{ .device = 5, .inode = 9 };
    try std.testing.expect(pageHeaderPresentation(context) == null);
    context.root_identity = null;
    try std.testing.expect(pageHeaderPresentation(context) == null);
    context.root_identity = root_identity;

    context.repo_epoch = 8;
    try std.testing.expect(pageHeaderPresentation(context) == null);
    state.activation.state.active.members.source = .pending;
    try std.testing.expect(pageHeaderPresentation(context).? == .terminal);
    context.repo_epoch = 7;
    try std.testing.expect(pageHeaderPresentation(context).? == .review);

    state.activation.state.active.members.source = .failed;
    const stale = pageHeaderPresentation(context).?;
    const stale_text = (try page_header.formatAlloc(allocator, stale, 80)).?;
    defer allocator.free(stale_text);
    try std.testing.expectEqualStrings("BASE origin/main  …  HEAD HEAD@0123456 stale", stale_text);

    state.base_target.?.full_ref[0] = 'x';
    try std.testing.expect(pageHeaderPresentation(context).? == .terminal);
}

test "AI Reviews picker renders bounded 120 80 56 loading and empty modal states" {
    const sizes = [_]chasen.Size{
        .{ .width = 120, .height = 32 },
        .{ .width = 80, .height = 24 },
        .{ .width = 56, .height = 16 },
    };
    var state: review_page.ReviewPageState = .{};
    defer state.deinit(std.testing.allocator);
    state.ai_reviews.phase = .scan_loading;
    for (sizes) |size| {
        var ts: chasen.testing.TestSurface = undefined;
        try ts.init(size.width, size.height);
        defer ts.deinit();
        try viewAiReviews(.{
            .page = &state,
            .palette = .default(),
            .repo_root = "/repo",
            .repo_epoch = 1,
            .root_identity = null,
            .layout = .{ .width = size.width, .height = size.height },
        }, &ts.surface);
        const snapshot = try ts.snapshot(std.testing.allocator);
        defer std.testing.allocator.free(snapshot);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "Reviews") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "Loading AI reviews...") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "r: retry") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "Esc: cancel") != null);
    }

    state.ai_reviews.phase = .{ .scan_failed = "scan failed" };
    try std.testing.expectEqualStrings("r: retry  Esc/q: close", aiReviewsFooterText(&state.ai_reviews));
    const direct_id = try committed_review.ReviewId.parse("723e4567-e89b-42d3-a456-426614174000");
    state.ai_reviews.phase = .{ .selection_failed = .{ .review_id = direct_id, .direct = true, .message = "selection failed" } };
    try std.testing.expectEqualStrings("r: retry  Esc/q: close", aiReviewsFooterText(&state.ai_reviews));
    state.ai_reviews.phase = .{ .return_failed = .{ .direct = true, .message = "return failed" } };
    try std.testing.expectEqualStrings("r: retry  Esc/q: close", aiReviewsFooterText(&state.ai_reviews));

    const labeled_loading = try directPinnedLoadingText(
        std.testing.allocator,
        "reviewer",
        "AI main@aaaaaaa",
        "topic@bbbbbbb",
    );
    defer std.testing.allocator.free(labeled_loading);
    try std.testing.expectEqualStrings(
        "Loading review... reviewer  AI main@aaaaaaa -> topic@bbbbbbb",
        labeled_loading,
    );
    const oid_loading = try directPinnedLoadingText(
        std.testing.allocator,
        "reviewer",
        "AI aaaaaaa",
        "bbbbbbb",
    );
    defer std.testing.allocator.free(oid_loading);
    try std.testing.expectEqualStrings(
        "Loading review... reviewer  AI aaaaaaa -> bbbbbbb",
        oid_loading,
    );

    state.ai_reviews.phase = .{ .empty = .no_reviews };
    state.ai_reviews.scan_result = .unbound;
    state.base_target = .{
        .full_ref = try std.testing.allocator.dupe(u8, "refs/heads/main"),
        .display_name = try std.testing.allocator.dupe(u8, "main"),
        .kind = .local,
    };
    var empty_surface: chasen.testing.TestSurface = undefined;
    try empty_surface.init(80, 24);
    defer empty_surface.deinit();
    try viewAiReviews(.{
        .page = &state,
        .palette = .default(),
        .repo_root = "/repo",
        .repo_epoch = 1,
        .root_identity = null,
        .layout = .{ .width = 80, .height = 24 },
    }, &empty_surface.surface);
    const empty_snapshot = try empty_surface.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(empty_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, empty_snapshot, "Normal Review") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty_snapshot, "main -> current branch") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty_snapshot, "No AI reviews for this repository") != null);

    const target: committed_review.CommittedReviewTarget = .{
        .object_format = .sha1,
        .source_kind = .branch_range,
        .base_oid = try committed_review.ObjectId.parse(.sha1, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        .head_oid = try committed_review.ObjectId.parse(.sha1, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
        .diff_base_oid = try committed_review.ObjectId.parse(.sha1, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
    };
    const rows = try std.testing.allocator.alloc(review_store.RunSummary, 1);
    rows[0] = .{
        .review_id = try committed_review.ReviewId.parse("923e4567-e89b-42d3-a456-426614174000"),
        .target = target,
        .status = .approved,
        .created_at = "2026-08-20T00:00:00Z".*,
        .created_at_unix = 1,
        .producer_name = try std.testing.allocator.dupe(u8, "reviewer"),
        .producer_model = null,
        .base_label = null,
        .head_label = null,
        .finding_count = 7,
        .availability = .available,
        .artifact_snapshot = .{
            .manifest_digest = committed_review.Sha256Digest.hash("manifest"),
            .findings_digest = committed_review.Sha256Digest.hash("findings"),
            .draft_state = .absent,
            .draft_digest = null,
            .result_digest = null,
        },
    };
    const diagnostics = try std.testing.allocator.alloc(review_store.Diagnostic, 1);
    diagnostics[0] = .{ .kind = .invalid_run, .text = try std.testing.allocator.dupe(u8, "invalid manifest") };
    state.ai_reviews.scan_result = .{ .history = .{
        .snapshot = undefined,
        .rows = rows,
        .diagnostics = diagnostics,
        .skipped_count = 1,
        .orphan_count = 0,
    } };
    const labels = [_][]const u8{"reviewer"};
    try state.ai_reviews.filter.apply(std.testing.allocator, &labels, "");
    state.ai_reviews.focus = 1;
    state.ai_reviews.phase = .{ .selection_loading = .{ .review_id = rows[0].review_id, .direct = false } };
    var loading_surface: chasen.testing.TestSurface = undefined;
    try loading_surface.init(80, 24);
    defer loading_surface.deinit();
    try viewAiReviews(.{
        .page = &state,
        .palette = .default(),
        .repo_root = "/repo",
        .repo_epoch = 1,
        .root_identity = null,
        .layout = .{ .width = 80, .height = 24 },
    }, &loading_surface.surface);
    const selected_loading = try loading_surface.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(selected_loading);
    try std.testing.expect(std.mem.indexOf(u8, selected_loading, "Loading review... reviewer") != null);
    try std.testing.expect(std.mem.indexOf(u8, selected_loading, "base@aaaaaaa -> head@bbbbbbb") != null);

    state.ai_reviews.phase = .ready;
    var mixed_surface: chasen.testing.TestSurface = undefined;
    try mixed_surface.init(80, 24);
    defer mixed_surface.deinit();
    try viewAiReviews(.{
        .page = &state,
        .palette = .default(),
        .repo_root = "/repo",
        .repo_epoch = 1,
        .root_identity = null,
        .layout = .{ .width = 80, .height = 24 },
    }, &mixed_surface.surface);
    const mixed_snapshot = try mixed_surface.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(mixed_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, mixed_snapshot, "1 invalid reviews skipped: invalid manifest") != null);
    try std.testing.expect(std.mem.indexOf(u8, mixed_snapshot, "7 findings") != null);
    state.ai_reviews.phase = .{ .return_failed = .{ .direct = false, .message = "return failed" } };
    try std.testing.expectEqualStrings(
        "/: filter  j/k: move  Enter: open  r: refresh/retry  Esc/q: close",
        aiReviewsFooterText(&state.ai_reviews),
    );
}

test "empty Review state describes one ahead commit accurately" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const message = try emptyStateMessage(arena.allocator(), "main", 1);
    try std.testing.expectEqualStrings("No file changes against main", message.title);
    try std.testing.expectEqualStrings("1 commit is ahead of main, but its net file diff is empty.", message.body);
}

test "empty Review state describes multiple ahead commits accurately" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const message = try emptyStateMessage(arena.allocator(), "origin/main", 3);
    try std.testing.expectEqualStrings("No file changes against origin/main", message.title);
    try std.testing.expectEqualStrings("3 commits are ahead of origin/main, but their net file diff is empty.", message.body);
}

fn pickerPageForViewTest(allocator: std.mem.Allocator) !review_page.ReviewPageState {
    var page_state: review_page.ReviewPageState = .{};
    errdefer page_state.deinit(allocator);
    const specs = [_]struct {
        full_ref: []const u8,
        name: []const u8,
        kind: @import("../../../git/refs.zig").BranchKind,
        timestamp: ?i64,
    }{
        .{
            .full_ref = "refs/heads/feature/very-long-ascii-branch-name-that-must-never-overlap-time",
            .name = "feature/very-long-ascii-branch-name-that-must-never-overlap-time",
            .kind = .local,
            .timestamp = 1_700_000_000,
        },
        .{
            .full_ref = "refs/remotes/origin/日本語のとても長いブランチ名",
            .name = "origin/日本語のとても長いブランチ名",
            .kind = .remote_tracking,
            .timestamp = 1_699_913_660,
        },
    };
    const branches = try allocator.alloc(@import("../../../git/refs.zig").BranchListItem, specs.len);
    var initialized: usize = 0;
    errdefer {
        for (branches[0..initialized]) |item| {
            allocator.free(item.full_ref);
            allocator.free(item.name);
            allocator.free(item.oid);
        }
        allocator.free(branches);
    }
    for (specs, branches) |spec, *item| {
        const full_ref = try allocator.dupe(u8, spec.full_ref);
        errdefer allocator.free(full_ref);
        const name = try allocator.dupe(u8, spec.name);
        errdefer allocator.free(name);
        const oid = try allocator.dupe(u8, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        item.* = .{
            .full_ref = full_ref,
            .name = name,
            .kind = spec.kind,
            .oid = oid,
            .tip_committer_unix = spec.timestamp,
        };
        initialized += 1;
    }
    page_state.base_picker.open = true;
    page_state.base_picker.accepted = .{ .branches = branches };
    const labels = [_][]const u8{ branches[0].full_ref, branches[1].full_ref };
    try page_state.base_picker.filter.apply(allocator, &labels, "");
    page_state.base_picker.render_now_unix = 1_700_000_060;
    return page_state;
}

fn pickerViewContext(page_state: *const review_page.ReviewPageState, width: u16, height: u16) Context {
    return .{
        .page = page_state,
        .palette = .default(),
        .repo_root = null,
        .repo_epoch = 0,
        .root_identity = null,
        .layout = .{ .width = width, .height = height },
    };
}

test "Review display mode header key follows the effective keymap and modal owner" {
    var page_state: review_page.ReviewPageState = .{};
    var config: keymap.Config = .{};
    config.set(.toggle_display_mode, .{ .plain_codepoint = 'z' });
    var context = pickerViewContext(&page_state, 90, 10);
    context.keymap = keymap.Effective.fromConfig(config);

    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("z", displayModeToggleKey(context, buffer[0..]).?);
    try std.testing.expectEqual(
        diff_render.modeToggleHintWidth("z"),
        navigationView(context).mode_toggle_hint_width,
    );

    page_state.search.mode = true;
    try std.testing.expect(displayModeToggleKey(context, buffer[0..]) == null);
    page_state.search.mode = false;
    page_state.file_search.mode = true;
    try std.testing.expect(displayModeToggleKey(context, buffer[0..]) == null);
    page_state.file_search.mode = false;
    page_state.base_picker.open = true;
    try std.testing.expect(displayModeToggleKey(context, buffer[0..]) == null);
}

test "Review base picker narrow and wide surfaces keep time independent from long branch names" {
    const allocator = std.testing.allocator;
    var page_state = try pickerPageForViewTest(allocator);
    defer page_state.deinit(allocator);

    inline for (.{ .{ @as(u16, 80), @as(u16, 12) }, .{ @as(u16, 120), @as(u16, 32) } }) |dimensions| {
        var surface: chasen.testing.TestSurface = undefined;
        try surface.init(dimensions[0], dimensions[1]);
        defer surface.deinit();
        try viewBasePicker(pickerViewContext(&page_state, dimensions[0], dimensions[1]), &surface.surface);
        const snapshot = try surface.snapshot(allocator);
        defer allocator.free(snapshot);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "1m ago") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "1d ago") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "1970") == null);
        if (dimensions[0] == 80) {
            try std.testing.expect(std.mem.indexOf(u8, snapshot, "[local]") == null);
            try std.testing.expect(std.mem.indexOf(u8, snapshot, "[remote]") == null);
        } else {
            try std.testing.expect(std.mem.indexOf(u8, snapshot, "[local]") != null);
        }
    }
}

test "Review base picker compact surface preserves filter candidate and footer before helper rows" {
    const allocator = std.testing.allocator;
    var page_state = try pickerPageForViewTest(allocator);
    defer page_state.deinit(allocator);

    // A 7-row dialog has three content rows after border and padding.
    var surface: chasen.testing.TestSurface = undefined;
    try surface.init(80, 7);
    defer surface.deinit();
    try viewBasePicker(pickerViewContext(&page_state, 80, 7), &surface.surface);
    const snapshot = try surface.snapshot(allocator);
    defer allocator.free(snapshot);

    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Filter:") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "feature/very-long") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "1m ago") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Esc: close") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Current base:") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "last commit:") == null);
}

test "Review base picker surface renders query no-match loading and failure terminals" {
    const allocator = std.testing.allocator;
    var page_state = try pickerPageForViewTest(allocator);
    defer page_state.deinit(allocator);
    page_state.base_picker.enterQuery();
    for ("missing") |byte| try page_state.base_picker.insertQuery(allocator, byte);

    var no_match: chasen.testing.TestSurface = undefined;
    try no_match.init(80, 12);
    defer no_match.deinit();
    try viewBasePicker(pickerViewContext(&page_state, 80, 12), &no_match.surface);
    const no_match_snapshot = try no_match.snapshot(allocator);
    defer allocator.free(no_match_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, no_match_snapshot, "Filter: /missing") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_match_snapshot, "No branches match \"missing\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_match_snapshot, "Esc: clear") != null);

    page_state.base_picker.close(allocator);
    page_state.base_picker.open = true;
    page_state.base_picker.loading = true;
    var loading: chasen.testing.TestSurface = undefined;
    try loading.init(80, 12);
    defer loading.deinit();
    try viewBasePicker(pickerViewContext(&page_state, 80, 12), &loading.surface);
    const loading_snapshot = try loading.snapshot(allocator);
    defer allocator.free(loading_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, loading_snapshot, "Loading local and remote branches") != null);
    try std.testing.expect(std.mem.indexOf(u8, loading_snapshot, "Filter:") != null);
    try std.testing.expect(std.mem.indexOf(u8, loading_snapshot, "Esc: close") != null);

    page_state.base_picker.loading = false;
    page_state.base_picker.failure = .{ .static = "Review base list failed" };
    var failure: chasen.testing.TestSurface = undefined;
    try failure.init(80, 12);
    defer failure.deinit();
    try viewBasePicker(pickerViewContext(&page_state, 80, 12), &failure.surface);
    const failure_snapshot = try failure.snapshot(allocator);
    defer allocator.free(failure_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, failure_snapshot, "Review base list failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, failure_snapshot, "Filter:") != null);
    try std.testing.expect(std.mem.indexOf(u8, failure_snapshot, "Esc: close") != null);

    page_state.base_picker.failure = null;
    page_state.base_picker.accepted = .{
        .branches = try allocator.alloc(@import("../../../git/refs.zig").BranchListItem, 0),
    };
    var empty: chasen.testing.TestSurface = undefined;
    try empty.init(80, 12);
    defer empty.deinit();
    try viewBasePicker(pickerViewContext(&page_state, 80, 12), &empty.surface);
    const empty_snapshot = try empty.snapshot(allocator);
    defer allocator.free(empty_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, empty_snapshot, "No local or remote branches") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty_snapshot, "Filter:") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty_snapshot, "Esc: close") != null);
}

test "Finding discovery Review adapter follows the active Run without retaining projection state" {
    var empty_bytes: [0]u8 = .{};
    var empty_entries: [0]finding_projection.Entry = .{};
    var empty_mapped_indices: [0]usize = .{};
    var files = [_]finding_projection.FileRecord{
        .{
            .ordinal = 0,
            .status_bytes = empty_bytes[0..],
            .before = null,
            .after = null,
            .summary = .{ .total = 5, .mapped = 2, .info = 1, .warning = 2, .@"error" = 2 },
        },
        .{
            .ordinal = 1,
            .status_bytes = empty_bytes[0..],
            .before = null,
            .after = null,
            .summary = .{ .total = 2, .mapped = 2, .info = 1, .warning = 1 },
        },
        .{
            .ordinal = 2,
            .status_bytes = empty_bytes[0..],
            .before = null,
            .after = null,
            .summary = .{ .total = 1, .mapped = 1, .info = 1 },
        },
        .{
            .ordinal = 3,
            .status_bytes = empty_bytes[0..],
            .before = null,
            .after = null,
            .summary = .{},
        },
    };
    const index: finding_projection.FindingProjectionIndex = .{
        .identity = undefined,
        .files = files[0..],
        .entries = empty_entries[0..],
        .summary = .{ .total = 5, .mapped = 2, .unmapped = 1, .stale = 1, .failed = 1 },
        .mapped_entry_indices = empty_mapped_indices[0..],
    };
    var page: review_page.ReviewPageState = .{};
    try std.testing.expect(activeFindingProjection(&page) == null);
    try std.testing.expect(activeFindingSummary(&page) == null);

    page.presentation = .{ .normal = undefined };
    try std.testing.expect(activeFindingProjection(&page) == null);
    try std.testing.expect(activeFindingSummary(&page) == null);

    page.presentation = .{ .pinned_ai = .{
        .selection = .{
            .snapshot = undefined,
            .artifacts = undefined,
            .projection = undefined,
            .finding_projection = index,
        },
        .base_display = empty_bytes[0..],
        .head_display = empty_bytes[0..],
    } };
    const active = activeFindingProjection(&page).?;
    const summary = activeFindingSummary(&page).?;
    try std.testing.expectEqual(@as(usize, 2), summary.mapped);
    try std.testing.expectEqual(@as(usize, 1), summary.unmapped);
    try std.testing.expectEqual(@as(usize, 1), summary.stale);
    try std.testing.expectEqual(@as(usize, 1), summary.failed);
    try std.testing.expectEqual(diff_surface.view.FindingAnnotation.Severity.@"error", findingAnnotationForFile(active, 0).?.highest_severity);
    try std.testing.expectEqual(diff_surface.view.FindingAnnotation.Severity.warning, findingAnnotationForFile(active, 1).?.highest_severity);
    try std.testing.expectEqual(diff_surface.view.FindingAnnotation.Severity.info, findingAnnotationForFile(active, 2).?.highest_severity);
    try std.testing.expect(findingAnnotationForFile(active, 3) == null);
    try std.testing.expect(findingAnnotationForFile(active, files.len) == null);

    var replacement_files = [_]finding_projection.FileRecord{.{
        .ordinal = 0,
        .status_bytes = empty_bytes[0..],
        .before = null,
        .after = null,
        .summary = .{ .total = 1, .mapped = 1, .info = 1 },
    }};
    const replacement_index: finding_projection.FindingProjectionIndex = .{
        .identity = undefined,
        .files = replacement_files[0..],
        .entries = empty_entries[0..],
        .summary = .{ .total = 1, .mapped = 1, .info = 1 },
        .mapped_entry_indices = empty_mapped_indices[0..],
    };
    page.presentation = .{ .pinned_ai = .{
        .selection = .{
            .snapshot = undefined,
            .artifacts = undefined,
            .projection = undefined,
            .finding_projection = replacement_index,
        },
        .base_display = empty_bytes[0..],
        .head_display = empty_bytes[0..],
    } };
    const replacement_summary = activeFindingSummary(&page).?;
    try std.testing.expectEqual(@as(usize, 1), replacement_summary.mapped);
    try std.testing.expectEqual(@as(usize, 0), replacement_summary.unmapped);
    try std.testing.expectEqual(@as(usize, 1), findingAnnotationForFile(activeFindingProjection(&page).?, 0).?.total);

    page.presentation = .{ .normal = undefined };
    try std.testing.expect(activeFindingProjection(&page) == null);
    try std.testing.expect(activeFindingSummary(&page) == null);

    page.presentation = null;
    try std.testing.expect(activeFindingProjection(&page) == null);
    try std.testing.expect(activeFindingSummary(&page) == null);
}

test "Finding discovery renders the tail reached by the actual Review controller" {
    const allocator = std.testing.allocator;
    const test_support = @import("../../test_support.zig");
    var nodes = [_]file_tree.Node{.{
        .kind = .file,
        .name = "long-file-name.zig",
        .path = "long-file-name.zig",
        .depth = 0,
        .status = .modified,
        .mode_changed = true,
        .target = .{ .diff_file = 0 },
    }};
    var loaded = test_support.loadedDiffOne();
    loaded.tree = .{ .nodes = &nodes };
    var empty_bytes: [0]u8 = .{};
    var empty_entries: [0]finding_projection.Entry = .{};
    var empty_mapped_indices: [0]usize = .{};
    var files = [_]finding_projection.FileRecord{.{
        .ordinal = 0,
        .status_bytes = empty_bytes[0..],
        .before = null,
        .after = null,
        .summary = .{ .total = 3, .mapped = 2, .@"error" = 3 },
    }};
    const index: finding_projection.FindingProjectionIndex = .{
        .identity = undefined,
        .files = files[0..],
        .entries = empty_entries[0..],
        .summary = .{ .total = 3, .mapped = 2, .@"error" = 3 },
        .mapped_entry_indices = empty_mapped_indices[0..],
    };
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(loaded),
        .presentation = .{ .pinned_ai = .{
            .selection = .{
                .snapshot = undefined,
                .artifacts = undefined,
                .projection = undefined,
                .finding_projection = index,
            },
            .base_display = empty_bytes[0..],
            .head_display = empty_bytes[0..],
        } },
    };
    defer {
        page.presentation = null;
        page.deinit(allocator);
    }
    page.viewer.sidebar_width = 24;
    const layout: diff_surface.Layout = .{ .width = 80, .height = 20 };
    const controller: review_navigation.Controller = .{
        .page = &page,
        .repo_root = null,
        .repo_epoch = 0,
        .root_identity = null,
        .layout = layout,
    };
    var adapter = controller.updateAdapter();
    var first_scroll = try adapter.shared().apply(null, .scroll_sidebar_right);
    defer first_scroll.deinit(null);
    var second_scroll = try adapter.shared().apply(null, .scroll_sidebar_right);
    defer second_scroll.deinit(null);
    try std.testing.expectEqual(@as(usize, 6), page.viewer.sidebar_horizontal_scroll);

    const context: Context = .{
        .page = &page,
        .palette = .default(),
        .repo_root = null,
        .repo_epoch = 0,
        .root_identity = null,
        .layout = layout,
    };
    var reached: chasen.testing.TestSurface = undefined;
    try reached.init(layout.width, layout.height);
    defer reached.deinit();
    try view(context, &reached.surface);

    const row = diff_surface.layout.sidebar_header_rows;
    const expected_tail = "ile-name.zig";
    for (expected_tail, 0..) |_, index_value| {
        try std.testing.expectEqualStrings(
            expected_tail[index_value .. index_value + 1],
            reached.surface.readCell(@intCast(6 + index_value), row).?.char.grapheme,
        );
    }
    try std.testing.expectEqualStrings(" ", reached.surface.readCell(18, row).?.char.grapheme);
    try std.testing.expectEqualStrings("E", reached.surface.readCell(19, row).?.char.grapheme);
    try std.testing.expectEqualStrings("3", reached.surface.readCell(20, row).?.char.grapheme);
    try std.testing.expectEqualStrings(" ", reached.surface.readCell(21, row).?.char.grapheme);
    try std.testing.expectEqualStrings("N", reached.surface.readCell(22, row).?.char.grapheme);
    try std.testing.expectEqualStrings("1", reached.surface.readCell(23, row).?.char.grapheme);
    const reached_snapshot = try reached.snapshot(allocator);
    defer allocator.free(reached_snapshot);

    var capped_scroll = try adapter.shared().apply(null, .scroll_sidebar_right);
    defer capped_scroll.deinit(null);
    try std.testing.expectEqual(@as(usize, 6), page.viewer.sidebar_horizontal_scroll);
    var capped: chasen.testing.TestSurface = undefined;
    try capped.init(layout.width, layout.height);
    defer capped.deinit();
    try view(context, &capped.surface);
    const capped_snapshot = try capped.snapshot(allocator);
    defer allocator.free(capped_snapshot);
    try std.testing.expectEqualStrings(reached_snapshot, capped_snapshot);
}
