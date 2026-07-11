//! Shared shell geometry and terminal-to-page coordinate conversion.
//!
//! Rendering and input both consume this value so frame, page-bar, body, and
//! footer boundaries cannot drift. Slice B keeps the page bar disabled until
//! the Slice C transition/authority policy makes page switching user-visible.

const std = @import("std");
const chasen = @import("chasen");
const ui = @import("chasen_ui");

pub const footer_rows: u16 = 1;
pub const page_bar_rows: u16 = 1;

const frame_min_width: u16 = 30;
const frame_min_height: u16 = 6;
pub const frame_padding: ui.layout.Insets = .{};

pub const Options = struct {
    page_bar_visible: bool = false,
};

pub const Point = struct {
    col: u16,
    row: u16,
};

pub const Layout = struct {
    terminal: chasen.Rect,
    content: chasen.Rect,
    page_bar: ?chasen.Rect,
    body: chasen.Rect,
    footer: chasen.Rect,

    pub fn contentSize(self: Layout) chasen.Size {
        return rectSize(self.content);
    }

    pub fn bodySize(self: Layout) chasen.Size {
        return rectSize(self.body);
    }

    pub fn terminalToContent(self: Layout, col: i16, row: i16) ?Point {
        return terminalToLocal(self.content, col, row);
    }

    pub fn terminalToBody(self: Layout, col: i16, row: i16) ?Point {
        return terminalToLocal(self.body, col, row);
    }
};

pub const ContentSections = struct {
    page_bar: ?chasen.Rect,
    body: chasen.Rect,
    footer: chasen.Rect,
};

pub fn compute(terminal_size: chasen.Size, options: Options) Layout {
    const terminal: chasen.Rect = .{
        .col = 0,
        .row = 0,
        .width = terminal_size.width,
        .height = terminal_size.height,
    };
    const content = if (frameEnabled(terminal_size))
        ui.Panel.contentRectFor(terminal, frame_padding)
    else
        terminal;

    const sections = partitionContent(content, options);
    return .{
        .terminal = terminal,
        .content = content,
        .page_bar = sections.page_bar,
        .body = sections.body,
        .footer = sections.footer,
    };
}

pub fn partitionContent(content: chasen.Rect, options: Options) ContentSections {
    const requested_page_bar_rows: u16 = if (options.page_bar_visible) page_bar_rows else 0;
    const actual_page_bar_rows = @min(requested_page_bar_rows, content.height);
    const remaining_after_bar = content.height - actual_page_bar_rows;
    const actual_footer_rows = @min(footer_rows, remaining_after_bar);
    const body_height = remaining_after_bar - actual_footer_rows;

    const page_bar = if (actual_page_bar_rows == 0) null else chasen.Rect{
        .col = content.col,
        .row = content.row,
        .width = content.width,
        .height = actual_page_bar_rows,
    };
    const body: chasen.Rect = .{
        .col = content.col,
        .row = content.row + actual_page_bar_rows,
        .width = content.width,
        .height = body_height,
    };
    const footer: chasen.Rect = .{
        .col = content.col,
        .row = content.row + actual_page_bar_rows + body_height,
        .width = content.width,
        .height = actual_footer_rows,
    };
    return .{
        .page_bar = page_bar,
        .body = body,
        .footer = footer,
    };
}

pub fn frameEnabled(size: chasen.Size) bool {
    return size.width >= frame_min_width and size.height >= frame_min_height;
}

pub fn contentRect(terminal_size: chasen.Size) chasen.Rect {
    return compute(terminal_size, .{}).content;
}

pub fn contentSize(terminal_size: chasen.Size) chasen.Size {
    return compute(terminal_size, .{}).contentSize();
}

pub fn bodyHeight(content_height: u16) u16 {
    return content_height -| footer_rows;
}

fn rectSize(rect: chasen.Rect) chasen.Size {
    return .{ .width = rect.width, .height = rect.height };
}

fn terminalToLocal(rect: chasen.Rect, col: i16, row: i16) ?Point {
    if (col < 0 or row < 0) return null;
    const raw_col: usize = @intCast(col);
    const raw_row: usize = @intCast(row);
    const rect_col: usize = rect.col;
    const rect_row: usize = rect.row;
    const rect_width: usize = rect.width;
    const rect_height: usize = rect.height;
    if (raw_col < rect_col or raw_row < rect_row) return null;
    if (raw_col >= rect_col + rect_width or raw_row >= rect_row + rect_height) return null;
    return .{
        .col = @intCast(raw_col - rect_col),
        .row = @intCast(raw_row - rect_row),
    };
}

test "layout partitions framed content into body and footer" {
    const layout = compute(.{ .width = 80, .height = 24 }, .{});
    try std.testing.expect(frameEnabled(.{ .width = 80, .height = 24 }));
    try std.testing.expectEqual(@as(u16, 1), layout.content.col);
    try std.testing.expectEqual(@as(u16, 1), layout.content.row);
    try std.testing.expectEqual(layout.content.width, layout.body.width);
    try std.testing.expectEqual(layout.content.height, layout.body.height + layout.footer.height);
    try std.testing.expectEqual(@as(u16, 1), layout.footer.height);
    try std.testing.expect(layout.page_bar == null);
}

test "layout reserves page bar without exposing it by default" {
    const hidden = compute(.{ .width = 80, .height = 24 }, .{});
    const visible = compute(.{ .width = 80, .height = 24 }, .{ .page_bar_visible = true });
    try std.testing.expect(hidden.page_bar == null);
    try std.testing.expect(visible.page_bar != null);
    try std.testing.expectEqual(hidden.body.height - 1, visible.body.height);
    try std.testing.expectEqual(visible.content.row + 1, visible.body.row);
}

test "terminal conversion rejects frame page bar and footer points" {
    const layout = compute(.{ .width = 80, .height = 24 }, .{ .page_bar_visible = true });
    try std.testing.expect(layout.terminalToBody(0, 0) == null);
    try std.testing.expect(layout.terminalToBody(1, 1) == null);
    try std.testing.expectEqual(Point{ .col = 0, .row = 0 }, layout.terminalToBody(1, 2).?);
    try std.testing.expect(layout.terminalToBody(1, @intCast(layout.footer.row)) == null);
    try std.testing.expectEqual(Point{ .col = 0, .row = 0 }, layout.terminalToContent(1, 1).?);
}

test "tiny layout keeps rectangles bounded" {
    const layout = compute(.{ .width = 1, .height = 1 }, .{ .page_bar_visible = true });
    try std.testing.expectEqual(@as(u16, 1), layout.content.height);
    try std.testing.expectEqual(@as(u16, 1), layout.page_bar.?.height);
    try std.testing.expectEqual(@as(u16, 0), layout.body.height);
    try std.testing.expectEqual(@as(u16, 0), layout.footer.height);
}
