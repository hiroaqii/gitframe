//! Shared leaf primitives for shell and page text-input rendering.

const std = @import("std");
const chasen = @import("chasen");

pub fn scrollCells(scroll: usize) u16 {
    return @intCast(@min(scroll, std.math.maxInt(u16)));
}

pub fn inputVisibleStart(text: []const u8, cursor: usize, width: u16) usize {
    const clamped_cursor = @min(cursor, text.len);
    if (width == 0 or text.len == 0) return clamped_cursor;
    const max_width_before_cursor = width - 1;
    var iter = chasen.text.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        if (grapheme.start > clamped_cursor) break;
        if (chasen.text.displayWidth(text[grapheme.start..clamped_cursor]) <= max_width_before_cursor) return grapheme.start;
    }
    return clamped_cursor;
}

pub fn showInputCursor(surface: *chasen.Surface, col: u16, row: u16, text: []const u8, cursor: usize) void {
    const size = surface.size();
    if (col >= size.width or row >= size.height) return;
    const width = size.width - col;
    const clamped_cursor = @min(cursor, text.len);
    const visible_start = inputVisibleStart(text, clamped_cursor, width);
    const text_width = chasen.text.displayWidth(text[visible_start..clamped_cursor]);
    surface.showCursor(@min(size.width - 1, col +| text_width), row);
}

test "input visibility keeps the cursor inside the viewport" {
    try std.testing.expectEqual(@as(usize, 2), inputVisibleStart("abcdef", 6, 5));
    try std.testing.expectEqual(@as(usize, 0), inputVisibleStart("abc", 2, 5));
}

test "scroll conversion saturates to terminal cell width" {
    try std.testing.expectEqual(std.math.maxInt(u16), scrollCells(std.math.maxInt(usize)));
}
