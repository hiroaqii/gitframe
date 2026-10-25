//! Shared leaf primitives for shell and page text-input rendering.

const std = @import("std");
const chasen = @import("chasen");

pub fn scrollCells(scroll: usize) u16 {
    return @intCast(@min(scroll, std.math.maxInt(u16)));
}

pub fn inputVisibleStart(text: []const u8, cursor: usize, width: u16) usize {
    const clamped_cursor = @min(cursor, text.len);
    if (width == 0 or text.len == 0) return clamped_cursor;
    const prefix = text[0..clamped_cursor];
    const max_width_before_cursor = width - 1;
    // Count each grapheme once, then drop the prefix in a second forward pass.
    // Keep the total wider than surface coordinates; displayWidth saturates u16.
    var remaining_width: usize = 0;
    var iter = chasen.text.graphemeIterator(prefix);
    while (iter.next()) |grapheme| remaining_width += chasen.text.displayWidth(grapheme.bytes(prefix));
    if (remaining_width <= max_width_before_cursor) return 0;
    iter = chasen.text.graphemeIterator(prefix);
    while (iter.next()) |grapheme| {
        remaining_width -= chasen.text.displayWidth(grapheme.bytes(prefix));
        if (remaining_width <= max_width_before_cursor) return grapheme.start + grapheme.len;
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
    try std.testing.expectEqual(@as(usize, 3), inputVisibleStart("あいう", 9, 5));
    try std.testing.expectEqual(@as(usize, 3), inputVisibleStart("e\u{301}xy", 5, 3));
    try std.testing.expectEqual(@as(usize, 11), inputVisibleStart("👩‍💻x", 12, 2));
    try std.testing.expectEqual(@as(usize, 3), inputVisibleStart("abc", 3, 0));
    try std.testing.expectEqual(@as(usize, 3), inputVisibleStart("abc", 99, 1));
    // Retain chasen's TAB/combining width policy at every codepoint cursor.
    const mixed = "a\tあe\u{301}z";
    var cursor: usize = 0;
    while (cursor <= mixed.len) : (cursor += 1) {
        if (cursor < mixed.len and (mixed[cursor] & 0xc0) == 0x80) continue;
        for (1..8) |width| {
            const visible = inputVisibleStart(mixed, cursor, @intCast(width));
            try std.testing.expect(chasen.text.displayWidth(mixed[visible..cursor]) < width);
            var boundaries = chasen.text.graphemeIterator(mixed[0..cursor]);
            while (boundaries.next()) |grapheme| {
                if (grapheme.start >= visible) break;
                try std.testing.expect(chasen.text.displayWidth(mixed[grapheme.start..cursor]) >= width);
            }
        }
    }
    const long = [_]u8{'x'} ** (64 * 1024);
    try std.testing.expectEqual(long.len - 79, inputVisibleStart(&long, long.len, 80));
    try std.testing.expectEqual(@as(usize, 2), inputVisibleStart(&long, long.len, std.math.maxInt(u16)));
}

test "scroll conversion saturates to terminal cell width" {
    try std.testing.expectEqual(std.math.maxInt(u16), scrollCells(std.math.maxInt(usize)));
}
