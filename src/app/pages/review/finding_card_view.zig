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
        .start = 1 + local_start,
        .end = 1 + local_start + target_width,
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
        const content_width = review_page.findingCardContentWidth(line.size().width);
        if (content_width == 0) return;
        var content_line = line.child(.{ .col = 1, .row = 0, .width = content_width, .height = 1 });

        if (local_row == 0) {
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
        if (local_row >= 1 and local_row <= 5) {
            const text = try review_page.findingCardDisplayText(content_line.frameAllocator(), content);
            const max_scroll = wrappedLineCount(text, content_line.size().width) -| 5;
            const scroll = @min(self.page.finding_card.bodyScroll(model), max_scroll);
            drawWrappedLogicalRow(
                &content_line,
                text,
                scroll + local_row - 1,
                .{ .fg = self.palette.color(.foreground), .bg = background },
            );
            return;
        }
        if (local_row == 6) {
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

fn wrappedLineCount(text: []const u8, width: u16) usize {
    if (width == 0) return 0;
    var rows: usize = 1;
    var line_width: u32 = 0;
    var iter = chasen.text.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        if (bytes.len == 1 and bytes[0] == '\n') {
            rows += 1;
            line_width = 0;
            continue;
        }
        const grapheme_width = chasen.text.displayWidth(bytes);
        if (line_width > 0 and line_width + grapheme_width > width) {
            rows += 1;
            line_width = 0;
        }
        line_width += grapheme_width;
    }
    return rows;
}

fn drawWrappedLogicalRow(surface: *chasen.Surface, text: []const u8, target_row: usize, style: chasen.TextStyle) void {
    if (surface.size().width == 0) return;
    var logical_row: usize = 0;
    var line_start: usize = 0;
    var line_end: usize = 0;
    var line_width: u32 = 0;
    var iter = chasen.text.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        if (bytes.len == 1 and bytes[0] == '\n') {
            if (logical_row == target_row) {
                _ = surface.borrowTextAt(0, 0, text[line_start..line_end], style);
                return;
            }
            logical_row += 1;
            line_start = grapheme.start + grapheme.len;
            line_end = line_start;
            line_width = 0;
            continue;
        }
        const grapheme_width = chasen.text.displayWidth(bytes);
        if (line_width > 0 and line_width + grapheme_width > surface.size().width) {
            if (logical_row == target_row) {
                _ = surface.borrowTextAt(0, 0, text[line_start..line_end], style);
                return;
            }
            logical_row += 1;
            line_start = grapheme.start;
            line_end = grapheme.start;
            line_width = 0;
        }
        line_end = grapheme.start + grapheme.len;
        line_width += grapheme_width;
    }
    if (logical_row == target_row) _ = surface.borrowTextAt(0, 0, text[line_start..line_end], style);
}

test "Review inline Finding wrapped rows are unicode and newline aware" {
    try std.testing.expectEqual(@as(usize, 3), wrappedLineCount("ab\n猫猫", 2));
    try std.testing.expectEqual(@as(usize, 2), wrappedLineCount("abcd", 2));
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
    const content_start: usize = wide.start - 1;
    const content_end: usize = wide.end - 1;
    try std.testing.expectEqualStrings(footer_copy_text, footer_text[content_start..content_end]);
    try std.testing.expect(wide.contains(wide.start));
    try std.testing.expect(wide.contains(wide.end - 1));
    try std.testing.expect(!wide.contains(wide.end));
    try std.testing.expect(footerCopyTarget(wide.end - 1) == null);
    try std.testing.expectEqualDeep(wide, footerCopyTarget(wide.end).?);
}
