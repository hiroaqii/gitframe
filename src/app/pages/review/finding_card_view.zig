//! Terminal-only painter for Review Finding card rows.

const std = @import("std");
const chasen = @import("chasen");
const draw = @import("draw");
const theme = @import("theme");
const finding_card = @import("../../../ai_review/finding_card.zig");
const committed_review = @import("../../../committed_review.zig");
const diff_render = @import("../../../diff/render.zig");
const human_review_session = @import("../../human_review_session.zig");
const review_page = @import("../review.zig");

pub const footer_text = "s: next  a/d/u: set  r: retry  y: copy  Enter: close  j/k: scroll  Esc/q: back";
const footer_copy_text = "y: copy";

pub const CellRange = struct {
    start: u16,
    end: u16,

    pub fn contains(self: CellRange, col: u16) bool {
        return col >= self.start and col < self.end;
    }
};

/// Exact fully-painted copy label in whole-card coordinates. Returning null
/// when the right edge is clipped keeps paint and pointer admission identical.
pub fn footerCopyTarget(row_width: u16) ?CellRange {
    const content_width = review_page.findingCardContentWidth(row_width);
    const byte_start = std.mem.indexOf(u8, footer_text, footer_copy_text) orelse unreachable;
    const local_start = chasen.text.displayWidth(footer_text[0..byte_start]);
    const target_width = chasen.text.displayWidth(footer_copy_text);
    if (local_start + target_width > content_width) return null;
    return .{
        .start = review_page.FindingCardLayout.content_col + local_start,
        .end = review_page.FindingCardLayout.content_col + local_start + target_width,
    };
}

pub const Painter = struct {
    page: *const review_page.ReviewPageState,
    row_plan: *const finding_card.RowPlan,
    palette: theme.Palette,
    human_review: ?human_review_session.Presentation,

    pub fn interface(self: *Painter) diff_render.InlineRowPainter {
        return .{ .ctx = self, .paint_fn = paint };
    }

    fn paint(ctx: *anyopaque, surface: *chasen.Surface, row: u16, token: usize, local_row: usize) !void {
        const self: *Painter = @ptrCast(@alignCast(ctx));
        if (token >= self.row_plan.cards.len) return;
        const model = self.row_plan.cards[token];
        const content = self.page.contentForFindingCard(model) orelse return;
        const focused = self.page.finding_card.matches(model);
        const expanded = self.page.finding_card.expanded(model);
        const background: chasen.Color = if (focused) self.palette.color(.pane_cursor_bg) else .default;
        var line = surface.child(.{ .col = 0, .row = row, .width = surface.size().width, .height = 1 });
        line.fillAll(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = .{ .bg = background } });
        if (expanded) paintExpandedBorder(&line, local_row, background, self.palette.color(.accent));
        const content_width = if (expanded)
            review_page.findingCardContentWidth(line.size().width)
        else
            review_page.FindingCardLayout.collapsedContentWidth(line.size().width);
        if (content_width == 0) return;
        const content_col = review_page.FindingCardLayout.content_col;
        var content_line = line.child(.{ .col = content_col, .row = 0, .width = content_width, .height = 1 });

        if (local_row == finding_card.header_row) {
            const marker = if (expanded) "▼" else "▶";
            const severity = severityLabel(model.severity);
            const disposition = dispositionToken(self.human_review, model);
            const header = if (content.model) |producer_model|
                if (disposition) |disposition_label|
                    try std.fmt.allocPrint(content_line.frameAllocator(), "{s} [{s}] [{s}] {s}/{s}  {s}", .{ marker, severity, disposition_label, content.producer, producer_model, firstLine(content.title) })
                else
                    try std.fmt.allocPrint(content_line.frameAllocator(), "{s} [{s}] {s}/{s}  {s}", .{ marker, severity, content.producer, producer_model, firstLine(content.title) })
            else if (disposition) |disposition_label|
                try std.fmt.allocPrint(content_line.frameAllocator(), "{s} [{s}] [{s}] {s}  {s}", .{ marker, severity, disposition_label, content.producer, firstLine(content.title) })
            else
                try std.fmt.allocPrint(content_line.frameAllocator(), "{s} [{s}] {s}  {s}", .{ marker, severity, content.producer, firstLine(content.title) });
            try draw.copyClippedTextAt(&content_line, 0, 0, header, .{
                .fg = severityColor(self.palette, model.severity),
                .bg = background,
                .bold = focused,
            });
            return;
        }
        if (!expanded) return;
        if (local_row >= finding_card.body_start_row and local_row < finding_card.footer_row) {
            const body = self.page.cachedFindingBody(model, content_line.size().width) orelse return;
            const max_scroll = body.rowCount() -| finding_card.body_rows;
            const scroll = @min(self.page.finding_card.bodyScroll(model), max_scroll);
            const text = preparedWrappedRow(body.text, body.row_starts, scroll + local_row - finding_card.body_start_row) orelse return;
            _ = content_line.borrowTextAt(
                0,
                0,
                text,
                .{ .fg = self.palette.color(.foreground), .bg = background },
            );
            return;
        }
        if (local_row == finding_card.footer_row) {
            try draw.copyClippedTextAt(
                &content_line,
                0,
                0,
                footer_text,
                .{ .fg = self.palette.color(.accent), .bg = background, .dim = !focused },
            );
        }
    }
};

fn paintExpandedBorder(
    line: *chasen.Surface,
    local_row: usize,
    background: chasen.Color,
    foreground: chasen.Color,
) void {
    const width = line.size().width;
    const left_col = review_page.FindingCardLayout.border_left_col;
    const right_col = review_page.FindingCardLayout.borderRightCol(width) orelse return;
    const style: chasen.TextStyle = .{ .fg = foreground, .bg = background };
    const left = if (local_row == finding_card.header_row) "╭" else if (local_row == finding_card.footer_row) "╰" else "│";
    const right = if (local_row == finding_card.header_row) "╮" else if (local_row == finding_card.footer_row) "╯" else "│";
    _ = line.borrowTextAt(left_col, 0, left, style);
    _ = line.borrowTextAt(right_col, 0, right, style);
    if ((local_row == finding_card.header_row or local_row == finding_card.footer_row) and right_col > left_col + 1) {
        line.fill(
            .{ .col = left_col + 1, .row = 0, .width = right_col - left_col - 1, .height = 1 },
            .{ .char = .{ .grapheme = "─", .width = 1 }, .style = style },
        );
    }
}

test "expanded Finding border paints inset rounded rails around all ten rows" {
    var rendered: chasen.testing.TestSurface = undefined;
    try rendered.init(20, 3);
    defer rendered.deinit();

    const rows = [_]usize{ finding_card.header_row, finding_card.body_start_row, finding_card.footer_row };
    for (rows, 0..) |local_row, surface_row| {
        var line = rendered.surface.child(.{
            .col = 0,
            .row = @intCast(surface_row),
            .width = rendered.surface.size().width,
            .height = 1,
        });
        paintExpandedBorder(&line, local_row, .default, .default);
    }

    const left = review_page.FindingCardLayout.border_left_col;
    const right = review_page.FindingCardLayout.borderRightCol(20).?;
    try rendered.expectCellText(left, 0, "╭");
    try rendered.expectCellText(left + 1, 0, "─");
    try rendered.expectCellText(right, 0, "╮");
    try rendered.expectCellText(left, 1, "│");
    try rendered.expectCellText(right, 1, "│");
    try rendered.expectCellText(left, 2, "╰");
    try rendered.expectCellText(left + 1, 2, "─");
    try rendered.expectCellText(right, 2, "╯");
    try rendered.expectCellText(right + 1, 2, " ");
}

fn dispositionToken(
    presentation: ?human_review_session.Presentation,
    model: finding_card.FindingCardModel,
) ?[]const u8 {
    const current = presentation orelse return null;
    if (!current.binding.review_repository_id.eql(model.identity.review_repository_id) or
        !current.binding.review_id.eql(model.identity.review_id) or
        !current.binding.target.eql(&model.identity.target) or
        !current.binding.findings_digest.eql(model.identity.findings_digest)) return null;
    const snapshot = current.snapshot orelse return null;
    for (snapshot.finding_dispositions) |value| {
        if (!std.mem.eql(u8, value.finding_id.bytes, model.finding_id)) continue;
        return switch (value.disposition) {
            .unreviewed => "U",
            .accepted => "A",
            .dismissed => "D",
        };
    }
    return null;
}

fn severityLabel(severity: committed_review.Severity) []const u8 {
    return switch (severity) {
        .info => "info",
        .warning => "warning",
        .@"error" => "error",
    };
}

fn severityColor(palette: theme.Palette, severity: committed_review.Severity) chasen.Color {
    return switch (severity) {
        .info => palette.color(.accent),
        .warning => palette.color(.warning),
        .@"error" => palette.color(.danger),
    };
}

fn firstLine(text: []const u8) []const u8 {
    return text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
}

/// Record each logical wrapped-row start once into pre-admitted storage.
pub fn prepareWrappedRows(text: []const u8, width: u16, starts: []usize) usize {
    if (width == 0 or starts.len == 0) return 0;
    std.debug.assert(starts.len >= text.len + 1);
    starts[0] = 0;
    var rows: usize = 1;
    var line_width: u32 = 0;
    var iter = chasen.text.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        if (bytes.len == 1 and bytes[0] == '\n') {
            starts[rows] = grapheme.start + grapheme.len;
            rows += 1;
            line_width = 0;
            continue;
        }
        const grapheme_width = chasen.text.displayWidth(bytes);
        if (line_width > 0 and line_width + grapheme_width > width) {
            starts[rows] = grapheme.start;
            rows += 1;
            line_width = 0;
        }
        line_width += grapheme_width;
    }
    return rows;
}

pub fn preparedWrappedRow(text: []const u8, starts: []const usize, row: usize) ?[]const u8 {
    if (row >= starts.len) return null;
    const start = starts[row];
    var end = if (row + 1 < starts.len) starts[row + 1] else text.len;
    if (start > end or end > text.len) return null;
    if (end > start and text[end - 1] == '\n') end -= 1;
    return text[start..end];
}

test "Review inline Finding wrapped rows are unicode and newline aware" {
    var starts: [16]usize = undefined;
    const count = prepareWrappedRows("ab\n猫猫", 2, &starts);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualStrings("ab", preparedWrappedRow("ab\n猫猫", starts[0..count], 0).?);
    try std.testing.expectEqualStrings("猫", preparedWrappedRow("ab\n猫猫", starts[0..count], 1).?);
    try std.testing.expectEqualStrings("猫", preparedWrappedRow("ab\n猫猫", starts[0..count], 2).?);
    try std.testing.expectEqual(@as(usize, 2), prepareWrappedRows("abcd", 2, &starts));
}

test "Finding disposition header token requires one exact session value" {
    const repository_id = try committed_review.ReviewRepositoryId.parse("123e4567-e89b-42d3-a456-426614174000");
    const review_id = try committed_review.ReviewId.parse("223e4567-e89b-42d3-a456-426614174000");
    const oid = try committed_review.ObjectId.parse(.sha1, "0123456789abcdef0123456789abcdef01234567");
    const target: committed_review.CommittedReviewTarget = .{
        .object_format = .sha1,
        .source_kind = .branch_range,
        .base_oid = oid,
        .head_oid = oid,
        .diff_base_oid = oid,
    };
    const findings_digest = committed_review.Sha256Digest.hash("findings");
    var snapshot = try human_review_session.DraftSnapshot.init(
        std.testing.allocator,
        null,
        &.{.{ .finding_id = .{ .bytes = "F-1" }, .disposition = .unreviewed }},
        &.{},
    );
    defer snapshot.deinit();
    const presentation: human_review_session.Presentation = .{
        .binding = .{
            .review_repository_id = repository_id,
            .review_id = review_id,
            .target = target,
            .findings_digest = findings_digest,
        },
        .lifecycle = .editable,
        .snapshot = &snapshot,
        .reconciliation = .confirmed,
    };
    const model: finding_card.FindingCardModel = .{
        .identity = .{
            .review_repository_id = repository_id,
            .review_id = review_id,
            .target = target,
            .findings_digest = findings_digest,
        },
        .entry_index = 0,
        .finding_id = "F-1",
        .span = .{ .file_ordinal = 0, .hunk_ordinal = 0, .first_diff_line_ordinal = 0, .last_diff_line_ordinal = 0 },
        .side = .after,
        .severity = .info,
    };
    try std.testing.expectEqualStrings("U", dispositionToken(presentation, model).?);
    snapshot.finding_dispositions[0].disposition = .accepted;
    try std.testing.expectEqualStrings("A", dispositionToken(presentation, model).?);
    snapshot.finding_dispositions[0].disposition = .dismissed;
    try std.testing.expectEqualStrings("D", dispositionToken(presentation, model).?);
    var missing = model;
    missing.finding_id = "F-2";
    try std.testing.expect(dispositionToken(presentation, missing) == null);
    try std.testing.expect(dispositionToken(null, model) == null);
}

test "Finding pointer copy target follows the fully visible card footer" {
    const wide = footerCopyTarget(80).?;
    const content_start: usize = wide.start - review_page.FindingCardLayout.content_col;
    const content_end: usize = wide.end - review_page.FindingCardLayout.content_col;
    try std.testing.expectEqualStrings(footer_copy_text, footer_text[content_start..content_end]);
    try std.testing.expect(wide.contains(wide.start));
    try std.testing.expect(wide.contains(wide.end - 1));
    try std.testing.expect(!wide.contains(wide.end));
    const minimum_row_width = wide.end + 1 + review_page.FindingCardLayout.right_padding;
    try std.testing.expect(footerCopyTarget(minimum_row_width - 1) == null);
    try std.testing.expectEqualDeep(wide, footerCopyTarget(minimum_row_width).?);
}
