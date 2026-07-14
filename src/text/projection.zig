//! Projection between logical UTF-8 byte offsets and terminal display cells.
//!
//! Source bytes are the durable identity used by copy and future agent
//! snapshots; terminal cells are only presentation geometry. TABs, wide
//! glyphs, and extended grapheme clusters make those coordinate spaces
//! non-interchangeable, so callers must choose either strict selection
//! boundaries or tolerant presentation enclosure explicitly.

const std = @import("std");
const chasen = @import("chasen");

pub const tab_width: usize = 4;

pub const Token = struct {
    leading: usize,
    trailing: usize,
    display_start: usize,
    display_end: usize,
};

pub const CellHit = union(enum) {
    token: Token,
    boundary: struct { offset: usize, display_column: usize },
};

pub const DisplayRange = struct {
    start: usize,
    end: usize,
};

pub const RangeWindow = struct {
    column: usize,
    text: []u8,
};

/// Strict retained-coordinate validation. Interior grapheme bytes are not
/// rounded because doing so would change the logical selection identity.
pub fn validateBoundary(line: []const u8, byte_offset: usize) bool {
    if (!std.unicode.utf8ValidateSlice(line) or byte_offset > line.len) return false;
    if (byte_offset == 0 or byte_offset == line.len) return true;
    var iter = chasen.text.graphemeIterator(line);
    while (iter.next()) |grapheme| {
        if (grapheme.start == byte_offset or grapheme.start + grapheme.len == byte_offset) return true;
        if (grapheme.start > byte_offset) return false;
    }
    return false;
}

pub fn displayColumnForBoundary(line: []const u8, byte_offset: usize) ?usize {
    if (!validateBoundary(line, byte_offset)) return null;
    return displayColumnForValidatedOffset(line, byte_offset);
}

/// Maps every occupied cell of an atomic token to the same byte boundaries.
/// Empty lines and cells at/beyond EOL resolve to the trailing boundary.
pub fn hitAtDisplayCell(line: []const u8, cell: usize) ?CellHit {
    if (!std.unicode.utf8ValidateSlice(line)) return null;
    var display_col: usize = 0;
    var iter = chasen.text.graphemeIterator(line);
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(line);
        const cells = tokenDisplayWidth(bytes, display_col);
        const end = display_col +| cells;
        if (cells > 0 and cell < end) return .{ .token = .{
            .leading = grapheme.start,
            .trailing = grapheme.start + grapheme.len,
            .display_start = display_col,
            .display_end = end,
        } };
        display_col = end;
    }
    return .{ .boundary = .{ .offset = line.len, .display_column = display_col } };
}

pub fn tokenAtDisplayCell(line: []const u8, cell: usize) ?Token {
    return switch (hitAtDisplayCell(line, cell) orelse return null) {
        .token => |token| token,
        .boundary => null,
    };
}

/// Tolerant presentation mapping for substring/syntax ranges. An interior
/// byte offset resolves to the containing token's leading display column.
pub fn leadingDisplayColumnForByte(line: []const u8, byte_offset: usize) ?usize {
    if (!std.unicode.utf8ValidateSlice(line)) return null;
    return displayColumnForValidatedOffset(line, @min(byte_offset, line.len));
}

pub fn enclosingDisplayRangeForBytes(line: []const u8, byte_start: usize, byte_end: usize) ?DisplayRange {
    if (!std.unicode.utf8ValidateSlice(line) or byte_start >= byte_end or byte_start >= line.len) return null;
    const clamped_end = @min(byte_end, line.len);
    var first: ?usize = null;
    var last: usize = 0;
    var display_col: usize = 0;
    var iter = chasen.text.graphemeIterator(line);
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(line);
        const cells = tokenDisplayWidth(bytes, display_col);
        const display_end = display_col +| cells;
        const grapheme_end = grapheme.start + grapheme.len;
        if (grapheme_end > byte_start and grapheme.start < clamped_end) {
            if (first == null) first = display_col;
            last = display_end;
        }
        display_col = display_end;
        if (grapheme.start >= clamped_end) break;
    }
    return if (first) |start| .{ .start = start, .end = last } else null;
}

pub fn displayWidth(line: []const u8) !usize {
    if (!std.unicode.utf8ValidateSlice(line)) return error.InvalidUtf8;
    var display_col: usize = 0;
    var iter = chasen.text.graphemeIterator(line);
    while (iter.next()) |grapheme| {
        display_col = try std.math.add(usize, display_col, tokenDisplayWidth(grapheme.bytes(line), display_col));
    }
    return display_col;
}

/// Builds only the visible display-cell window and expands TAB without
/// changing retained source or logical copy bytes.
pub fn renderWindowAlloc(allocator: std.mem.Allocator, line: []const u8, horizontal_scroll: usize, width: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (width == 0) return out.toOwnedSlice(allocator);

    var logical_col: usize = 0;
    var output_width: usize = 0;
    var iter = chasen.text.graphemeIterator(line);
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(line);
        const cells = tokenDisplayWidth(bytes, logical_col);
        const segment_end = logical_col + cells;
        if (bytes.len == 1 and bytes[0] == '\t') {
            if (segment_end > horizontal_scroll) {
                const visible_start = @max(logical_col, horizontal_scroll);
                const visible_cells = @min(segment_end - visible_start, width - output_width);
                try out.appendNTimes(allocator, ' ', visible_cells);
                output_width += visible_cells;
            }
        } else if (segment_end > horizontal_scroll and logical_col < horizontal_scroll) {
            const visible_cells = @min(segment_end - horizontal_scroll, width - output_width);
            try out.appendNTimes(allocator, ' ', visible_cells);
            output_width += visible_cells;
        } else if (logical_col >= horizontal_scroll) {
            if (output_width + cells > width) break;
            try out.appendSlice(allocator, bytes);
            output_width += cells;
        }
        logical_col = segment_end;
        if (output_width >= width) break;
    }
    return out.toOwnedSlice(allocator);
}

/// Renders the visible portion of every complete token intersected by an
/// arbitrary byte range. This is intentionally tolerant for search/syntax.
pub fn renderEnclosingRangeWindowAlloc(
    allocator: std.mem.Allocator,
    line: []const u8,
    byte_start: usize,
    byte_end: usize,
    horizontal_scroll: usize,
    width: usize,
) !?RangeWindow {
    if (byte_start >= byte_end or byte_start >= line.len or width == 0) return null;
    const clamped_end = @min(byte_end, line.len);
    const viewport_end = std.math.add(usize, horizontal_scroll, width) catch std.math.maxInt(usize);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var first_column: ?usize = null;
    var logical_col: usize = 0;
    var output_width: usize = 0;
    var iter = chasen.text.graphemeIterator(line);
    while (iter.next()) |grapheme| {
        if (grapheme.start >= clamped_end or logical_col >= viewport_end) break;
        const bytes = grapheme.bytes(line);
        const cells = tokenDisplayWidth(bytes, logical_col);
        const segment_end = logical_col + cells;
        defer logical_col = segment_end;
        const grapheme_end = grapheme.start + grapheme.len;
        if (grapheme_end <= byte_start or segment_end <= horizontal_scroll) continue;

        const visible_start = @max(logical_col, horizontal_scroll);
        const visible_end = @min(segment_end, viewport_end);
        if (visible_start >= visible_end) continue;
        if (first_column == null) first_column = visible_start - horizontal_scroll;
        const visible_cells = visible_end - visible_start;
        if (bytes.len == 1 and bytes[0] == '\t' or logical_col < horizontal_scroll) {
            try out.appendNTimes(allocator, ' ', visible_cells);
            output_width += visible_cells;
        } else if (segment_end > viewport_end) {
            break;
        } else {
            try out.appendSlice(allocator, bytes);
            output_width += cells;
        }
    }
    if (first_column == null or output_width == 0) {
        out.deinit(allocator);
        return null;
    }
    return .{ .column = first_column.?, .text = try out.toOwnedSlice(allocator) };
}

fn displayColumnForValidatedOffset(line: []const u8, target: usize) usize {
    var display_col: usize = 0;
    var iter = chasen.text.graphemeIterator(line);
    while (iter.next()) |grapheme| {
        if (grapheme.start >= target or target < grapheme.start + grapheme.len) break;
        display_col += tokenDisplayWidth(grapheme.bytes(line), display_col);
    }
    return display_col;
}

fn tokenDisplayWidth(bytes: []const u8, display_col: usize) usize {
    if (bytes.len == 1 and bytes[0] == '\t') return tab_width - (display_col % tab_width);
    return chasen.text.displayWidth(bytes);
}

test "strict boundaries reject grapheme interiors while presentation encloses them" {
    const line = "e\u{301}界x";
    try std.testing.expect(validateBoundary(line, 0));
    try std.testing.expect(!validateBoundary(line, 1));
    try std.testing.expectEqual(@as(?usize, null), displayColumnForBoundary(line, 1));
    try std.testing.expectEqual(@as(?usize, 0), leadingDisplayColumnForByte(line, 1));
    try std.testing.expectEqual(DisplayRange{ .start = 0, .end = 1 }, enclosingDisplayRangeForBytes(line, 1, 2).?);
}

test "every occupied TAB and wide cell maps to one source token" {
    const line = "a\t界";
    const tab = tokenAtDisplayCell(line, 1).?;
    try std.testing.expectEqual(tab, tokenAtDisplayCell(line, 2).?);
    try std.testing.expectEqual(tab, tokenAtDisplayCell(line, 3).?);
    const wide = tokenAtDisplayCell(line, 4).?;
    try std.testing.expectEqual(wide, tokenAtDisplayCell(line, 5).?);
    try std.testing.expectEqual(@as(usize, 1), tab.leading);
    try std.testing.expectEqual(@as(usize, 2), tab.trailing);
}

test "empty and beyond EOL cells return trailing boundary" {
    try std.testing.expectEqual(@as(usize, 0), hitAtDisplayCell("", 0).?.boundary.offset);
    try std.testing.expectEqual(@as(usize, 1), hitAtDisplayCell("x", 20).?.boundary.offset);
}

test "render windows preserve previous TAB wide and enclosing behavior" {
    const allocator = std.testing.allocator;
    const rendered = try renderWindowAlloc(allocator, "a\tb界e\u{301}", 0, 12);
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings("a   b界e\u{301}", rendered);

    const combining = (try renderEnclosingRangeWindowAlloc(allocator, "e\u{301}x", 1, 3, 0, 10)).?;
    defer allocator.free(combining.text);
    try std.testing.expectEqual(@as(usize, 0), combining.column);
    try std.testing.expectEqualStrings("e\u{301}", combining.text);
}
