//! Allocation-free geometry shared by Repository source drawing and input.
//!
//! Keeping one value for gutter, line-number, separator, text, and body rows
//! prevents mouse hit-testing from drifting from rendering when line-number
//! width, pane width, or terminal height changes.

const std = @import("std");
const chasen = @import("chasen");
const source = @import("../../../repository/source.zig");

/// Fixed Repository source chrome. The accepted path owns row 0, while source
/// search presentation or the normal separator exclusively owns row 1.
/// Drawing and input both consume `source_body_first_row`, so neither chrome
/// row can accidentally become selectable source content.
pub const source_path_row: u16 = 0;
pub const source_search_or_rule_row: u16 = 1;
pub const source_body_first_row: u16 = 2;

pub const Region = enum {
    gutter,
    line_number,
    separator,
    text,
};

pub const SourceGeometry = struct {
    width: u16,
    height: u16,
    gutter_col: u16 = 0,
    line_number_col: u16 = 1,
    line_number_width: u16,
    separator_col: ?u16,
    text_col: u16,
    text_width: u16,
    body_first_row: u16,
    visible_source_rows: u16,

    pub fn init(size: chasen.Size, document: *const source.Document, line_numbers: bool) SourceGeometry {
        const number_width: u16 = if (line_numbers) @intCast(decimalDigits(document.rowCount())) else 0;
        const text_col = 1 +| number_width +| @as(u16, if (line_numbers) 1 else 0);
        return .{
            .width = size.width,
            .height = size.height,
            .line_number_width = number_width,
            .separator_col = if (line_numbers) 1 +| number_width else null,
            .text_col = text_col,
            .text_width = size.width -| text_col,
            .body_first_row = source_body_first_row,
            .visible_source_rows = size.height -| source_body_first_row,
        };
    }

    pub fn navigationRows(self: SourceGeometry) usize {
        return @max(@as(usize, self.visible_source_rows), 1);
    }

    pub fn regionAt(self: SourceGeometry, col: u16) ?Region {
        if (col >= self.width) return null;
        if (col == self.gutter_col) return .gutter;
        if (self.line_number_width > 0 and
            col >= self.line_number_col and col < self.line_number_col + self.line_number_width)
        {
            return .line_number;
        }
        if (self.separator_col) |separator| if (col == separator) return .separator;
        if (col >= self.text_col) return .text;
        return null;
    }

    /// Returns only real content rows. `Document.rowCount()` deliberately has
    /// one synthetic row for an empty viewer, which is not selectable text.
    pub fn contentLineAt(
        self: SourceGeometry,
        row: u16,
        vertical_scroll: usize,
        document: *const source.Document,
    ) ?usize {
        if (row < self.body_first_row or row >= self.height) return null;
        const line_index = vertical_scroll + @as(usize, row - self.body_first_row);
        if (line_index >= document.contentLineCount()) return null;
        return line_index;
    }
};

fn decimalDigits(value: usize) usize {
    var number = @max(value, 1);
    var digits: usize = 1;
    while (number >= 10) : (number /= 10) digits += 1;
    return digits;
}

test "repository selection slice B geometry shares narrow line number and body boundaries" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, "\n\n\n\n\n\n\n\n\n\nx");
    var document = try source.Document.initOwned(allocator, bytes, .init(bytes));
    defer document.deinit(allocator);

    const numbered = SourceGeometry.init(.{ .width = 10, .height = 4 }, &document, true);
    try std.testing.expectEqual(@as(u16, 2), numbered.line_number_width);
    try std.testing.expectEqual(@as(?u16, 3), numbered.separator_col);
    try std.testing.expectEqual(@as(u16, 4), numbered.text_col);
    try std.testing.expectEqual(@as(u16, 6), numbered.text_width);
    try std.testing.expectEqual(numbered.height -| numbered.body_first_row, numbered.visible_source_rows);
    try std.testing.expectEqual(Region.gutter, numbered.regionAt(0).?);
    try std.testing.expectEqual(Region.line_number, numbered.regionAt(2).?);
    try std.testing.expectEqual(Region.separator, numbered.regionAt(3).?);
    try std.testing.expectEqual(Region.text, numbered.regionAt(4).?);
    try std.testing.expectEqual(@as(?usize, null), numbered.contentLineAt(source_path_row, 0, &document));
    try std.testing.expectEqual(@as(?usize, null), numbered.contentLineAt(source_search_or_rule_row, 0, &document));
    try std.testing.expectEqual(@as(?usize, 0), numbered.contentLineAt(numbered.body_first_row, 0, &document));
    try std.testing.expectEqual(@as(?usize, 1), numbered.contentLineAt(numbered.body_first_row + 1, 0, &document));
    try std.testing.expectEqual(@as(?usize, null), numbered.contentLineAt(numbered.height, 0, &document));

    const narrow = SourceGeometry.init(.{ .width = 1, .height = 1 }, &document, true);
    try std.testing.expectEqual(@as(u16, 0), narrow.text_width);
    try std.testing.expectEqual(@as(u16, 0), narrow.visible_source_rows);
    try std.testing.expectEqual(@as(usize, 1), narrow.navigationRows());
}

test "repository selection slice B geometry rejects the empty document synthetic row" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, "");
    var document = try source.Document.initOwned(allocator, bytes, .init(bytes));
    defer document.deinit(allocator);
    const geometry = SourceGeometry.init(.{ .width = 20, .height = 4 }, &document, true);
    try std.testing.expectEqual(@as(usize, 1), document.rowCount());
    try std.testing.expectEqual(@as(usize, 0), document.contentLineCount());
    try std.testing.expectEqual(@as(?usize, null), geometry.contentLineAt(geometry.body_first_row, 0, &document));
}
