//! AI Reviews presentation built from shared committed-diff primitives.

const std = @import("std");
const chasen = @import("chasen");
const ui = @import("chasen_ui");
const draw = @import("draw");
const theme = @import("theme");
const ai_reviews_page = @import("../ai_reviews.zig");
const commit_time = @import("../../branch_commit_time.zig");
const local_time = @import("../../../local_time.zig");
const ai_reviews_navigation = @import("navigation.zig");
const diff_surface = @import("../../diff_surface.zig");
const diff_file = @import("../../../diff/file.zig");
const diff_render = @import("../../../diff/render.zig");
const diff_selection = @import("../../../diff/selection.zig");
const file_tree = @import("../../../file_tree.zig");
const keymap = @import("keymap");
const page_header = @import("../../page_header.zig");
const root_capability = @import("../../../repo/root_capability.zig");
const committed_review = @import("../../../committed_review.zig");
const git_review = @import("../../../git/committed_review.zig");
const review_store = @import("../../../review_store.zig");
const human_review_session = @import("../../human_review_session.zig");
const human_review_decision = @import("human_review_decision.zig");
const finding_card = @import("../../../ai_review/finding_card.zig");
const finding_card_view = @import("finding_card_view.zig");
const finding_projection = @import("../../../ai_review/finding_projection.zig");
const loaded_diff = @import("../../../loaded_diff.zig");

pub const Context = struct {
    page: *const ai_reviews_page.AiReviewsPageState,
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
            .surface = self.page.readSurface(self.layout),
            .auto_reload_enabled = false,
            .selection_action_visible = navigation.bodyView(&resolver).retainedSelectionActionAvailable(),
        });
        result.source_label = null;
        result.finding_summary = activeFindingSummary(self.page);
        return result;
    }
};

fn activeFindingProjection(page: *const ai_reviews_page.AiReviewsPageState) ?*const finding_projection.FindingProjectionIndex {
    const selected = page.selectedRunConst() orelse return null;
    return &selected.selection.finding_projection;
}

fn activeFindingSummary(page: *const ai_reviews_page.AiReviewsPageState) ?diff_surface.view.FindingSummaryPresentation {
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
    if (app.page.human_review_decision.isOpen() or app.page.picker.isOpen() or
        app.page.delete_confirmation.isOpen()) return null;
    const presentation = matchingHumanReviewPresentation(app) orelse return null;
    return switch (presentation.lifecycle) {
        .saving, .finalizing, .completed => "result",
        .failed => if (presentation.reconciliation == .reload_required) "result" else "finalize",
        .editable => "finalize",
    };
}

fn matchingHumanReviewPresentation(app: Context) ?human_review_session.Presentation {
    const selected = app.page.selectedRunConst() orelse return null;
    const presentation = app.human_review orelse return null;
    if (!selected.binding().eql(presentation.binding)) return null;
    return presentation;
}

/// Project one accepted BASE-HEAD pair. Identity and current target must both
/// still match; otherwise a retained old BASE is never exposed in the header.
pub fn pageHeaderPresentation(app: Context) ?page_header.Presentation {
    if (app.repo_root == null) return null;
    const pending = sourcePending(app.page);
    const failed = sourceFailed(app.page);
    const identity = app.page.diff.accepted_repository_identity orelse
        return reviewTerminal(pending, failed);
    if (!identity.matches(app.repo_epoch, app.root_identity) or !app.page.hasAcceptedDisplay())
        return reviewTerminal(pending, failed);
    const selected = app.page.selectedRunConst() orelse return reviewTerminal(pending, failed);
    return .{ .comparison = .{
        .base_display_name = selected.base_display,
        .head_display_name = selected.head_display,
        .freshness = if (pending) .refreshing else if (failed) .stale else .fresh,
    } };
}

pub fn pageHeaderLineStats(app: Context) ?file_tree.Stats {
    return diff_surface.view.pageHeaderLineStats(app.page.readSurface(app.layout));
}

fn sourcePending(page: *const ai_reviews_page.AiReviewsPageState) bool {
    return switch (page.activation.state) {
        .active => |active| active.members.source == .pending,
        .inactive => false,
    };
}

fn sourceFailed(page: *const ai_reviews_page.AiReviewsPageState) bool {
    return switch (page.activation.state) {
        .active => |active| active.members.source == .failed,
        .inactive => false,
    };
}

fn reviewTerminal(pending: bool, failed: bool) ?page_header.Presentation {
    if (pending) return .{ .terminal = .{ .kind = .comparison, .state = .loading } };
    if (failed) return .{ .terminal = .{ .kind = .comparison, .state = .unavailable } };
    return null;
}

pub fn view(app: Context, surface: *chasen.Surface) !void {
    if (app.page.selectedRunConst() == null) return viewUnselected(app, surface);

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

    try diff_surface.view.view(surface, .{
        .state = app.page.readSurface(app.layout),
        .palette = app.palette,
        .source_label = "AI review",
        .repo_root = app.repo_root,
        .file_filter_binding = app.keymap.display(.changed_file_filter, filter_key_buffer[0..]),
        .no_changes_actions = .{},
        .empty_message = selectedRunEmptyStateMessage(),
        .finding_annotation_resolver = finding_annotation_resolver,
        .diff_pane = pane_adapter.interface(),
    });
}

pub fn viewPicker(app: Context, surface: *chasen.Surface) !void {
    const picker = &app.page.picker;
    if (!picker.isPickerVisible()) return;

    const opts: ui.Modal.ViewOptions = .{
        .dialog_width = @min(surface.size().width, 112),
        .dialog_height = @min(surface.size().height, 24),
        .title = "AI Reviews",
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
        const prefix = if (picker.queryMode()) "Filter: /" else "Filter: ";
        try draw.copyClippedTextAt(&content, 0, next_row, prefix, app.palette.style(.prompt));
        const prefix_width = content.displayWidth(prefix);
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
            content.showCursor(@min(size.width - 1, prefix_width + content.displayWidth(picker.query.slice())), next_row);
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
        if (available_rows >= 6) 3 else if (available_rows >= 3) 1 else 0
    else if (available_rows >= 5)
        2
    else
        0;
    const list_end = footer_row -| detail_rows;
    const visible_runs = picker.filter.source_indexes.len;
    const run_rows = list_end -| next_row;

    if (retained_list and visible_runs > 0 and run_rows > 0) {
        const start = listWindowStart(picker.focus, visible_runs, run_rows);
        var row_offset: u16 = 0;
        while (row_offset < run_rows and start + row_offset < visible_runs) : (row_offset += 1) {
            const visible_index = start + row_offset;
            const source_index = picker.filter.sourceIndex(visible_index) orelse continue;
            const rows = picker.rows();
            if (source_index >= rows.len) continue;
            try drawAiReviewRow(
                app.palette,
                picker.render_now_unix,
                app.page.isCurrentReview(rows[source_index].review_id),
                &content,
                next_row + row_offset,
                rows[source_index],
                picker.focus == visible_index,
            );
        }
    } else if (next_row < list_end) {
        if (try aiReviewsStateMessage(app, content.frameAllocator(), size.width)) |message| {
            try draw.copyClippedTextAt(&content, 0, next_row, message.text, messageStyle(app, message.failure));
        } else if (picker.query.len > 0) {
            const message = try std.fmt.allocPrint(content.frameAllocator(), "No AI reviews match \"{s}\"", .{picker.query.slice()});
            try draw.copyClippedTextAt(&content, 0, next_row, message, app.palette.style(.muted));
        }
    }

    if (detail_rows > 0) {
        var detail_row = footer_row - detail_rows;
        if (mixed_invalid) {
            const message = try aiReviewsSkippedMessage(picker, content.frameAllocator());
            try draw.copyClippedTextAt(&content, 0, detail_row, message, app.palette.style(.muted));
            detail_row += 1;
        }
        if (detail_row < footer_row) {
            if (app.page.status.text().len > 0) {
                try draw.copyClippedTextAt(
                    &content,
                    0,
                    detail_row,
                    firstLine(app.page.status.text()),
                    app.palette.style(.prompt),
                );
            } else if (try aiReviewsStateMessage(app, content.frameAllocator(), size.width)) |message| {
                try draw.copyClippedTextAt(&content, 0, detail_row, message.text, messageStyle(app, message.failure));
            } else if (picker.selectedRow()) |selected| {
                try drawAiReviewDetail(app, &content, detail_row, selected);
            }
        }
    }

    try draw.copyClippedTextAt(&content, 0, footer_row, aiReviewsFooterText(picker, size.width), app.palette.style(.accent));
    if (app.page.delete_confirmation.isOpen()) try viewDeleteConfirmation(app, surface);
}

pub fn viewDeleteConfirmation(app: Context, surface: *chasen.Surface) !void {
    const summary = app.page.delete_confirmation.summary() orelse return;
    const deleting = app.page.delete_confirmation.isDeleting();
    const opts: ui.Modal.ViewOptions = .{
        .dialog_width = @min(surface.size().width, 88),
        .dialog_height = @min(surface.size().height, 15),
        .title = if (deleting) "Deleting AI review Run" else "Delete AI review Run?",
        .backdrop = false,
        .border = .rounded,
        .title_style = app.palette.boldStyle(if (deleting) .prompt else .danger),
        .border_style = app.palette.style(if (deleting) .prompt else .danger),
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

    if (row < footer_row) {
        const review_id = summary.request.review_id.canonical();
        const identity = try std.fmt.allocPrint(content.frameAllocator(), "Run {s}", .{&review_id});
        try draw.copyClippedTextAt(&content, 0, row, identity, app.palette.boldStyle(.accent));
        row += 1;
    }
    if (row < footer_row) {
        const producer = if (summary.producer_model) |model|
            try std.fmt.allocPrint(content.frameAllocator(), "Producer: {s}  Model: {s}", .{ summary.producer_name, model })
        else
            try std.fmt.allocPrint(content.frameAllocator(), "Producer: {s}", .{summary.producer_name});
        try draw.copyClippedTextAt(&content, 0, row, producer, chasen.TextStyle{});
        row += 1;
    }
    if (row < footer_row) {
        const pair = try targetPairAlloc(
            content.frameAllocator(),
            &summary.target,
            summary.base_label,
            summary.head_label,
            true,
            size.width -| content.displayWidth("Target: "),
        );
        const target = try std.fmt.allocPrint(content.frameAllocator(), "Target: {s}", .{pair});
        try draw.copyClippedTextAt(&content, 0, row, target, app.palette.style(.muted));
        row += 1;
    }
    if (row < footer_row) {
        const created = local_time.formatExact(summary.created_at_unix);
        const facts = try std.fmt.allocPrint(content.frameAllocator(), "Status: {s}  Current: {s}  Findings: {d}  Created: {s}", .{
            ai_reviews_page.runSummaryStatusText(summary.status),
            if (app.page.isCurrentReview(summary.request.review_id)) "yes" else "no",
            summary.finding_count,
            if (created) |*value| value.text() else "—",
        });
        try draw.copyClippedTextAt(&content, 0, row, facts, app.palette.style(.muted));
        row += 1;
    }
    if (row < footer_row) row += 1;
    if (summary.unfinished() and row < footer_row) {
        try draw.copyClippedTextAt(
            &content,
            0,
            row,
            "WARNING: This Run is unfinished. Draft state will be removed.",
            app.palette.boldStyle(.danger),
        );
        row += 1;
    }
    if (row < footer_row) {
        try draw.copyClippedTextAt(
            &content,
            0,
            row,
            if (deleting) "Deleting the exact Run from the Review Store..." else "This permanently removes this exact Run from the Review Store.",
            app.palette.style(if (deleting) .prompt else .danger),
        );
        row += 1;
    }
    if (!deleting and row < footer_row) {
        try draw.copyClippedTextAt(&content, 0, row, "[ Cancel ]    Delete (y)", app.palette.boldStyle(.accent));
    }
    try draw.copyClippedTextAt(
        &content,
        0,
        footer_row,
        if (deleting) "Please wait" else "Enter/Esc/n: cancel  y: delete",
        app.palette.style(.accent),
    );
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
            try draw.copyClippedTextAt(&content, 0, row, "Selected AI review session is no longer available", app.palette.style(.danger));
            row += 1;
        }
        if (row < footer_row) {
            try draw.copyClippedTextAt(&content, 0, row, "Close this overlay and reopen the selected AI review.", app.palette.style(.muted));
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
            "Esc/q: close  Reload the selected AI review before retry"
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
        .completed => if (presentation.completed_at) |completed_at| blk: {
            const exact = formatStoredUtcLocal(completed_at) orelse
                break :blk "Completed at —";
            break :blk try std.fmt.allocPrint(allocator, "Completed at {s}", .{exact.text()});
        } else "Completed",
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
    available_width: u16,
) !?AiReviewsStateMessage {
    const picker = &app.page.picker;
    return switch (picker.phase) {
        .closed, .ready => null,
        .scan_loading => .{ .text = "Loading AI reviews..." },
        .selection_loading => if (picker.selectedRow()) |selected| blk: {
            const prefix = try std.fmt.allocPrint(allocator, "Loading review... {s}  ", .{selected.producer_name});
            const pair = try targetPairAlloc(
                allocator,
                &selected.target,
                selected.base_label,
                selected.head_label,
                true,
                available_width -| chasen.text.displayWidth(prefix),
            );
            break :blk .{ .text = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, pair }) };
        } else .{ .text = "Loading review..." },
        .scan_failed => |message| .{ .text = firstLine(message), .failure = true },
        .selection_failed => |failure| .{ .text = firstLine(failure.message), .failure = true },
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
    picker: *const ai_reviews_page.AiReviewsPickerState,
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

fn drawAiReviewRow(
    palette: theme.Palette,
    render_now_unix: ?i64,
    current: bool,
    surface: *chasen.Surface,
    row_index: u16,
    item: review_store.RunSummary,
    focused: bool,
) !void {
    const focus_marker: []const u8 = if (focused) ">" else " ";
    const current_marker: []const u8 = if (current) "*" else " ";
    const status = if (item.availability == .missing) "target unavailable" else ai_reviews_page.runSummaryStatusText(item.status);
    const relative = commit_time.formatRelative(item.created_at_unix, render_now_unix);
    const width = surface.size().width;
    const allocator = surface.frameAllocator();
    const facts = try aiReviewRowFactsAlloc(allocator, surface, item, status, relative.text(), width);
    const facts_width = @min(width -| 3, surface.displayWidth(facts));
    const facts_col = width - facts_width;
    const pair_end = facts_col -| 2;
    const style = if (focused) palette.boldStyle(.accent) else chasen.TextStyle{};
    const markers = try std.fmt.allocPrint(allocator, "{s}{s} ", .{ focus_marker, current_marker });
    try draw.copyClippedTextAt(surface, 0, row_index, markers, style);
    if (pair_end > 3) {
        var pair_surface = surface.child(.{
            .col = 3,
            .row = row_index,
            .width = pair_end - 3,
            .height = 1,
        });
        const pair = try targetPairAlloc(
            allocator,
            &item.target,
            item.base_label,
            item.head_label,
            false,
            pair_surface.size().width,
        );
        try draw.copyClippedTextAt(&pair_surface, 0, 0, pair, style);
    }
    try draw.copyClippedTextAt(surface, facts_col, row_index, facts, style);
}

fn aiReviewRowFactsAlloc(
    allocator: std.mem.Allocator,
    surface: *const chasen.Surface,
    item: review_store.RunSummary,
    status: []const u8,
    relative: []const u8,
    width: u16,
) ![]const u8 {
    const maximum = width -| 21;
    const finding_label: []const u8 = if (item.finding_count == 1) "finding" else "findings";
    if (width >= 96) if (item.producer_model) |model| {
        const text = try std.fmt.allocPrint(allocator, "{s}  {s}  {d} {s}  {s}  {s}", .{
            item.producer_name, model, item.finding_count, finding_label, status, relative,
        });
        if (surface.displayWidth(text) <= maximum) return text;
    };
    if (width >= 68) {
        const text = try std.fmt.allocPrint(allocator, "{s}  {d} {s}  {s}  {s}", .{
            item.producer_name, item.finding_count, finding_label, status, relative,
        });
        if (surface.displayWidth(text) <= maximum) return text;
    }
    if (width >= 54) {
        const text = try std.fmt.allocPrint(allocator, "{s}  {d}  {s}  {s}", .{
            item.producer_name, item.finding_count, status, relative,
        });
        if (surface.displayWidth(text) <= maximum) return text;
    }
    if (width >= 42) {
        const text = try std.fmt.allocPrint(allocator, "{s}  {d}  {s}", .{
            item.producer_name, item.finding_count, status,
        });
        if (surface.displayWidth(text) <= maximum) return text;
    }
    return status;
}

fn drawAiReviewDetail(
    app: Context,
    surface: *chasen.Surface,
    start_row: u16,
    item: *const review_store.RunSummary,
) !void {
    const target = try targetPairAlloc(
        surface.frameAllocator(),
        &item.target,
        item.base_label,
        item.head_label,
        true,
        surface.size().width,
    );
    try draw.copyClippedTextAt(surface, 0, start_row, target, app.palette.style(.muted));
    if (start_row + 1 >= surface.size().height -| 1) return;
    const review_id = item.review_id.canonical();
    const created = local_time.formatExact(item.created_at_unix);
    const created_text = if (created) |*value| value.text() else "—";
    const full_id_width = surface.displayWidth("created ") + surface.displayWidth(created_text) +
        surface.displayWidth("  review ") + surface.displayWidth(&review_id);
    const displayed_review_id: []const u8 = if (surface.size().width >= full_id_width) &review_id else review_id[0..8];
    const detail = try std.fmt.allocPrint(surface.frameAllocator(), "created {s}  review {s}", .{
        created_text,
        displayed_review_id,
    });
    try draw.copyClippedTextAt(surface, 0, start_row + 1, detail, app.palette.style(.muted));
}

fn formatStoredUtcLocal(timestamp: *const [20]u8) ?local_time.Exact {
    const unix_seconds = committed_review.strict_json.timestampToUnixSeconds(timestamp) catch return null;
    return local_time.formatExact(unix_seconds);
}

fn targetPairAlloc(
    allocator: std.mem.Allocator,
    target: *const committed_review.CommittedReviewTarget,
    base_label: ?[]const u8,
    head_label: ?[]const u8,
    detailed: bool,
    available_width: u16,
) ![]const u8 {
    const separator = " → ";
    const separator_width = chasen.text.displayWidth(separator);
    if (available_width <= separator_width) return clippedTextAlloc(allocator, separator, available_width);

    const endpoint_width = available_width - separator_width;
    const base_full_width = targetEndpointWidth(base_label, target.base_oid.short(), detailed);
    const head_full_width = targetEndpointWidth(head_label, target.head_oid.short(), detailed);
    const base_min_width = targetEndpointMinimumWidth(base_label, target.base_oid.short(), detailed);
    const head_min_width = targetEndpointMinimumWidth(head_label, target.head_oid.short(), detailed);
    const budgets = targetEndpointBudgets(
        endpoint_width,
        base_full_width,
        head_full_width,
        base_min_width,
        head_min_width,
    );
    const base = try targetEndpointAlloc(
        allocator,
        base_label,
        target.base_oid.short(),
        detailed,
        budgets.base,
    );
    const head = try targetEndpointAlloc(
        allocator,
        head_label,
        target.head_oid.short(),
        detailed,
        budgets.head,
    );
    return std.fmt.allocPrint(allocator, "{s} → {s}", .{ base, head });
}

const TargetEndpointBudgets = struct {
    base: u16,
    head: u16,
};

fn targetEndpointBudgets(
    available_width: u16,
    base_full_width: u16,
    head_full_width: u16,
    base_min_width: u16,
    head_min_width: u16,
) TargetEndpointBudgets {
    if (@as(u32, base_full_width) + head_full_width <= available_width) {
        return .{ .base = base_full_width, .head = head_full_width };
    }

    const half = available_width / 2;
    if (base_full_width <= half and head_min_width <= available_width - base_full_width) {
        return .{ .base = base_full_width, .head = available_width - base_full_width };
    }
    if (head_full_width <= available_width - half and base_min_width <= available_width - head_full_width) {
        return .{ .base = available_width - head_full_width, .head = head_full_width };
    }

    var base = half;
    var head = available_width - half;
    if (@as(u32, base_min_width) + head_min_width <= available_width) {
        if (base < base_min_width) {
            base = base_min_width;
            head = available_width - base;
        } else if (head < head_min_width) {
            head = head_min_width;
            base = available_width - head;
        }
    }
    return .{ .base = base, .head = head };
}

fn targetEndpointWidth(label: ?[]const u8, short_oid: []const u8, detailed: bool) u16 {
    return if (label) |value|
        chasen.text.displayWidth(value) + if (detailed) 1 + chasen.text.displayWidth(short_oid) else 0
    else
        chasen.text.displayWidth(short_oid);
}

fn targetEndpointMinimumWidth(label: ?[]const u8, short_oid: []const u8, detailed: bool) u16 {
    const full_width = targetEndpointWidth(label, short_oid, detailed);
    if (label != null and detailed) {
        return @min(full_width, 2 + chasen.text.displayWidth(short_oid));
    }

    const text = label orelse short_oid;
    var graphemes = chasen.text.graphemeIterator(text);
    const first = graphemes.next() orelse return 0;
    const first_width = chasen.text.displayWidth(first.bytes(text));
    return @min(full_width, first_width + 1);
}

fn targetEndpointAlloc(
    allocator: std.mem.Allocator,
    label: ?[]const u8,
    short_oid: []const u8,
    detailed: bool,
    available_width: u16,
) ![]const u8 {
    const value = label orelse return clippedTextAlloc(allocator, short_oid, available_width);
    if (!detailed) return clippedTextAlloc(allocator, value, available_width);

    const suffix_width = 1 + chasen.text.displayWidth(short_oid);
    if (available_width < suffix_width) return clippedTextAlloc(allocator, short_oid, available_width);
    const clipped_label = try clippedTextAlloc(allocator, value, available_width - suffix_width);
    return std.fmt.allocPrint(allocator, "{s}@{s}", .{ clipped_label, short_oid });
}

fn clippedTextAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    available_width: u16,
) ![]const u8 {
    const clipped = chasen.text.clipToWidthWithMarker(text, available_width, "…");
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ clipped.prefix, clipped.marker });
}

fn aiReviewsFooterText(picker: *const ai_reviews_page.AiReviewsPickerState, width: u16) []const u8 {
    const capabilities = picker.interactionCapabilities();
    if (picker.queryMode()) return "Type: filter  Up/Down: move  Tab: command  Esc: clear/list";
    if (capabilities.cancel) return "r: retry  Esc: cancel";
    if (capabilities.list) return if (width >= 78)
        "/: filter  j/k: move  Enter: open  c: close current  D: delete  r: refresh"
    else if (width >= 58)
        "Enter: open  c: close current  D: delete  r: refresh  Esc: close"
    else
        "Enter open  c close  D delete  Esc close";
    return "r: retry  Esc/q: close";
}

const DiffPaneAdapter = struct {
    context: ai_reviews_navigation.View,
    palette: theme.Palette,
    mode_toggle_key: ?[]const u8,
    human_review: ?human_review_session.Presentation,

    fn interface(self: *DiffPaneAdapter) diff_surface.view.DiffPaneRenderer {
        return .{ .ctx = self, .render_fn = render };
    }

    fn render(ctx: *anyopaque, surface: *chasen.Surface, loaded: loaded_diff.LoadedDiff) !void {
        const self: *DiffPaneAdapter = @ptrCast(@alignCast(ctx));
        var frame = self.context.cachedFindingCardFrame();
        const rows = if (frame) |*value| &value.presentation_rows else null;
        const context = self.context.withPresentationRows(rows);
        const finding_highlight = if (frame) |*value|
            focusedFindingHighlight(
                context.page.finding_card,
                &value.row_plan,
                &loaded,
                context.view().selectedFileIndex(&loaded),
            )
        else
            null;
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
            .{
                .inline_row_painter = painter,
                .passive_selection = finding_highlight,
            },
        );
    }
};

fn focusedFindingHighlight(
    state: finding_card.State,
    row_plan: *const finding_card.RowPlan,
    loaded: *const loaded_diff.LoadedDiff,
    selected_file: ?usize,
) ?diff_selection.View {
    const file_index = selected_file orelse return null;
    if (file_index >= loaded.document.files.len) return null;
    for (row_plan.cards) |model| {
        if (!state.matches(model) or model.span.file_ordinal != file_index) continue;
        const path_key = diff_file.canonicalPathKey(loaded.document.files[file_index]) orelse return null;
        return .{
            .identity = .{ .loaded_file = .{ .file_index = file_index, .path_key = path_key } },
            .side = switch (model.side) {
                .before => .old,
                .after => .new,
            },
            .mode = .line,
            .start = diff_selection.pointFromLine(model.span.hunk_ordinal, model.span.first_diff_line_ordinal),
            .end = diff_selection.pointFromLine(model.span.hunk_ordinal, model.span.last_diff_line_ordinal),
        };
    }
    return null;
}

fn navigationView(app: Context) ai_reviews_navigation.View {
    var key_buffer: [16]u8 = undefined;
    return .{
        .page = app.page,
        .repo_root = app.repo_root,
        .repo_epoch = app.repo_epoch,
        .root_identity = app.root_identity,
        .layout = app.layout,
        .mode_toggle_hint_width = diff_render.modeToggleHintWidth(displayModeToggleKey(app, key_buffer[0..])),
    };
}

fn displayModeToggleKey(app: Context, buffer: []u8) ?[]const u8 {
    if (app.page.diff.search.mode or app.page.diff.file_search.mode or app.page.picker.isPickerVisible()) return null;
    return app.keymap.display(.toggle_display_mode, buffer);
}

fn viewUnselected(app: Context, surface: *chasen.Surface) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;
    const row = size.height / 2;
    try draw.copyClippedTextAt(surface, 1, row, "No AI review selected", app.palette.boldStyle(.accent));
    if (row + 2 < size.height) {
        try draw.copyClippedTextAt(surface, 1, row + 2, "a: select AI review", app.palette.style(.muted));
    }
}

fn firstLine(text: []const u8) []const u8 {
    if (std.mem.indexOfAny(u8, text, "\r\n")) |end| return text[0..end];
    return text;
}

fn selectedRunEmptyStateMessage() diff_surface.view.StateMessage {
    return .{
        .title = "No file changes in AI review",
        .body = "The selected AI review has an empty net file diff.",
        .hint = "Press a to choose another AI review or r to refresh.",
    };
}

fn listWindowStart(selected: usize, len: usize, rows: u16) usize {
    if (rows == 0 or len == 0) return 0;
    const visible: usize = @intCast(rows);
    if (len <= visible) return 0;
    return @min(selected -| (visible / 2), len - visible);
}

fn testRunSummaryAlloc(
    allocator: std.mem.Allocator,
    review_id_text: []const u8,
    base_label: ?[]const u8,
    head_label: ?[]const u8,
    finding_count: u32,
    availability: git_review.TargetAvailability,
) !review_store.RunSummary {
    const producer_name = try allocator.dupe(u8, "codex");
    errdefer allocator.free(producer_name);
    const producer_model = try allocator.dupe(u8, "gpt-6-test");
    errdefer allocator.free(producer_model);
    const owned_base = if (base_label) |label| try allocator.dupe(u8, label) else null;
    errdefer if (owned_base) |label| allocator.free(label);
    const owned_head = if (head_label) |label| try allocator.dupe(u8, label) else null;
    errdefer if (owned_head) |label| allocator.free(label);
    return .{
        .review_id = try committed_review.ReviewId.parse(review_id_text),
        .target = .{
            .object_format = .sha1,
            .source_kind = .branch_range,
            .base_oid = try committed_review.ObjectId.parse(.sha1, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
            .head_oid = try committed_review.ObjectId.parse(.sha1, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
            .diff_base_oid = try committed_review.ObjectId.parse(.sha1, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        },
        .status = .approved,
        .created_at = "2026-09-12T09:00:00Z".*,
        .created_at_unix = 1_000,
        .producer_name = producer_name,
        .producer_model = producer_model,
        .base_label = owned_base,
        .head_label = owned_head,
        .finding_count = finding_count,
        .availability = availability,
        .artifact_snapshot = .{
            .manifest_digest = committed_review.Sha256Digest.hash("manifest"),
            .findings_digest = committed_review.Sha256Digest.hash("findings"),
            .draft_state = .absent,
            .draft_digest = null,
            .result_digest = null,
        },
    };
}

test "AI Reviews initial page is stable and Run selection is explicit" {
    const long_base = "base/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const long_head = "機能改善/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    var rendered: chasen.testing.TestSurface = undefined;
    try rendered.init(60, 12);
    defer rendered.deinit();
    var state: ai_reviews_page.AiReviewsPageState = .{};
    defer state.deinit(std.testing.allocator);
    try view(.{
        .page = &state,
        .palette = theme.Palette.default(),
        .repo_root = "/repo",
        .repo_epoch = 1,
        .root_identity = null,
        .layout = .{ .width = 60, .height = 12 },
    }, &rendered.surface);
    try rendered.expectCellText(1, 6, "N");
    try rendered.expectCellText(1, 8, "a");

    const rows = try std.testing.allocator.alloc(review_store.RunSummary, 2);
    rows[0] = try testRunSummaryAlloc(
        std.testing.allocator,
        "123e4567-e89b-42d3-a456-426614174000",
        long_base,
        long_head,
        2,
        .available,
    );
    rows[1] = try testRunSummaryAlloc(
        std.testing.allocator,
        "223e4567-e89b-42d3-a456-426614174000",
        null,
        null,
        1,
        .missing,
    );
    state.picker.scan_result = .{ .history = .{
        .snapshot = testStoreSnapshot(
            try committed_review.ReviewRepositoryId.parse("323e4567-e89b-42d3-a456-426614174000"),
        ),
        .rows = rows,
        .diagnostics = try std.testing.allocator.alloc(review_store.Diagnostic, 0),
        .skipped_count = 0,
        .orphan_count = 0,
    } };
    const filter_labels = [_][]const u8{ "first", "second" };
    try state.picker.filter.apply(std.testing.allocator, &filter_labels, "");
    state.picker.phase = .ready;
    state.picker.render_now_unix = 1_120;

    for ([_]chasen.Size{
        .{ .width = 120, .height = 32 },
        .{ .width = 80, .height = 24 },
        .{ .width = 56, .height = 16 },
    }) |size| {
        var picker_surface: chasen.testing.TestSurface = undefined;
        try picker_surface.init(size.width, size.height);
        defer picker_surface.deinit();
        try viewPicker(.{
            .page = &state,
            .palette = theme.Palette.default(),
            .repo_root = "/repo",
            .repo_epoch = 1,
            .root_identity = null,
            .layout = .{ .width = size.width, .height = size.height },
        }, &picker_surface.surface);
        const snapshot = try picker_surface.snapshot(std.testing.allocator);
        defer std.testing.allocator.free(snapshot);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "base/") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "機") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, " → ") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "…") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "aaaaaaa → bbbbbbb") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "approved") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "aaaaaaa") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "bbbbbbb") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "@aaaaaaa") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "@bbbbbbb") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "base@") == null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "head@") == null);
        const created_exact = local_time.formatExact(rows[0].created_at_unix).?;
        try std.testing.expect(std.mem.indexOf(u8, snapshot, created_exact.text()) != null);

        const pair_width = size.width - 20;
        for ([_]struct {
            base_label: ?[]const u8,
            head_label: ?[]const u8,
            base_fragment: []const u8,
            head_fragment: []const u8,
            clipped: bool,
        }{
            .{ .base_label = long_base, .head_label = "head", .base_fragment = "base/", .head_fragment = "head", .clipped = true },
            .{ .base_label = "base", .head_label = long_head, .base_fragment = "base", .head_fragment = "機能改善/", .clipped = true },
            .{ .base_label = long_base, .head_label = long_head, .base_fragment = "base/", .head_fragment = "機能改善/", .clipped = true },
            .{ .base_label = null, .head_label = null, .base_fragment = "aaaaaaa", .head_fragment = "bbbbbbb", .clipped = false },
        }) |case| {
            const pair = try targetPairAlloc(
                picker_surface.surface.frameAllocator(),
                &rows[0].target,
                case.base_label,
                case.head_label,
                false,
                pair_width,
            );
            try std.testing.expect(chasen.text.displayWidth(pair) <= pair_width);
            try std.testing.expect(std.mem.indexOf(u8, pair, case.base_fragment) != null);
            try std.testing.expect(std.mem.indexOf(u8, pair, " → ") != null);
            try std.testing.expect(std.mem.indexOf(u8, pair, case.head_fragment) != null);
            try std.testing.expectEqual(case.clipped, std.mem.indexOf(u8, pair, "…") != null);
        }

        const detailed_pair = try targetPairAlloc(
            picker_surface.surface.frameAllocator(),
            &rows[0].target,
            long_base,
            long_head,
            true,
            pair_width,
        );
        try std.testing.expect(chasen.text.displayWidth(detailed_pair) <= pair_width);
        try std.testing.expect(std.mem.indexOf(u8, detailed_pair, "…") != null);
        try std.testing.expect(std.mem.indexOf(u8, detailed_pair, "aaaaaaa") != null);
        try std.testing.expect(std.mem.indexOf(u8, detailed_pair, " → ") != null);
        try std.testing.expect(std.mem.indexOf(u8, detailed_pair, "bbbbbbb") != null);
        if (size.width >= 120) {
            try std.testing.expect(std.mem.indexOf(u8, snapshot, "gpt-6-test") != null);
            try std.testing.expect(std.mem.indexOf(u8, snapshot, "2 findings") != null);
            try std.testing.expect(std.mem.indexOf(u8, snapshot, "123e4567-e89b-42d3-a456-426614174000") != null);
        } else if (size.width >= 80) {
            try std.testing.expect(std.mem.indexOf(u8, snapshot, "gpt-6-test") == null);
            try std.testing.expect(std.mem.indexOf(u8, snapshot, "2 findings") != null);
            try std.testing.expect(std.mem.indexOf(u8, snapshot, "review 123e4567") != null);
            try std.testing.expect(std.mem.indexOf(u8, snapshot, "123e4567-e89b-42d3-a456-426614174000") == null);
        } else {
            try std.testing.expect(std.mem.indexOf(u8, snapshot, "gpt-6-test") == null);
            try std.testing.expect(std.mem.indexOf(u8, snapshot, "findings") == null);
            try std.testing.expect(std.mem.indexOf(u8, snapshot, "review 123e4567") != null);
            try std.testing.expect(std.mem.indexOf(u8, snapshot, "123e4567-e89b-42d3-a456-426614174000") == null);
        }
    }

    var marker_surface: chasen.testing.TestSurface = undefined;
    try marker_surface.init(56, 1);
    defer marker_surface.deinit();
    try drawAiReviewRow(
        theme.Palette.default(),
        1_120,
        true,
        &marker_surface.surface,
        0,
        rows[0],
        true,
    );
    try marker_surface.expectCellText(0, 0, ">");
    try marker_surface.expectCellText(1, 0, "*");

    state.picker.phase = .{ .selection_loading = .{
        .review_id = rows[0].review_id,
        .direct = false,
    } };
    const loading = (try aiReviewsStateMessage(.{
        .page = &state,
        .palette = theme.Palette.default(),
        .repo_root = "/repo",
        .repo_epoch = 1,
        .root_identity = null,
        .layout = .{ .width = 80, .height = 24 },
    }, marker_surface.surface.frameAllocator(), 80)).?;
    try std.testing.expect(std.mem.indexOf(u8, loading.text, "aaaaaaa") != null);
    try std.testing.expect(std.mem.indexOf(u8, loading.text, " → ") != null);
    try std.testing.expect(std.mem.indexOf(u8, loading.text, "bbbbbbb") != null);
}

fn testStoreSnapshot(repository_id: committed_review.ReviewRepositoryId) review_store.StoreSnapshot {
    const display = review_store.RepositoryDisplayName.fromStored("repository") catch unreachable;
    return .{
        .root_device = 1,
        .root_inode = 2,
        .namespace_device = 3,
        .namespace_inode = 4,
        .repository_instance_id = committed_review.RepositoryInstanceId.parse("123e4567-e89b-42d3-a456-426614174010") catch unreachable,
        .review_repository_id = repository_id,
        .repository_display_name = display,
        .repository_directory_name = review_store.RepositoryDirectoryName.format(&display, repository_id),
    };
}
