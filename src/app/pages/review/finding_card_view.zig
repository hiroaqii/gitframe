//! Terminal-only painter for Review Finding card rows.

const std = @import("std");
const chasen = @import("chasen");
const draw = @import("draw");
const theme = @import("theme");
const finding_card = @import("../../../ai_review/finding_card.zig");
const diff_render = @import("../../../diff/render.zig");
const review_page = @import("../review.zig");

pub const Painter = struct {
    page: *const review_page.ReviewPageState,
    row_plan: *const finding_card.RowPlan,
    palette: theme.Palette,

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
            const header = if (content.model) |producer_model|
                try std.fmt.allocPrint(content_line.frameAllocator(), "{s} [{s}] {s}/{s}  {s}", .{ marker, severity, content.producer, producer_model, firstLine(content.title) })
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
                "s: next  Enter: close  j/k: scroll  y: copy  Esc/q: back",
                .{ .fg = self.palette.color(.accent), .bg = background, .dim = !focused },
            );
        }
    }
};

fn severityLabel(severity: @import("../../../committed_review.zig").Severity) []const u8 {
    return switch (severity) {
        .info => "info",
        .warning => "warning",
        .@"error" => "error",
    };
}

fn severityColor(palette: theme.Palette, severity: @import("../../../committed_review.zig").Severity) chasen.Color {
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
