//! Bounded current-file source coordinates for the Repository page.
//!
//! `Document` owns the safe UTF-8 bytes accepted by `repository/document.zig`.
//! Lines borrow those bytes through 32-bit offsets; no per-line text is copied.
//! Byte offsets, source rows, and terminal display cells are intentionally
//! separate coordinate systems.

const std = @import("std");
const chasen = @import("chasen");
const content_fingerprint = @import("../content_fingerprint.zig");
const selected_document = @import("document.zig");

pub const tab_width: usize = 4;

pub const Match = struct {
    line: usize,
    start: usize,
    end: usize,
};

pub const Document = struct {
    bytes: []u8,
    fingerprint: content_fingerprint.Fingerprint,
    line_starts: []u32,
    max_display_width: usize,

    pub fn initOwned(
        allocator: std.mem.Allocator,
        bytes: []u8,
        fingerprint: content_fingerprint.Fingerprint,
    ) !Document {
        if (bytes.len > selected_document.max_text_bytes) return error.SourceTooLarge;
        var starts: std.ArrayList(u32) = .empty;
        errdefer starts.deinit(allocator);
        try starts.append(allocator, 0);
        for (bytes, 0..) |byte, index| {
            if (byte != '\n' or index + 1 >= bytes.len) continue;
            try starts.append(allocator, @intCast(index + 1));
        }
        const line_starts = try starts.toOwnedSlice(allocator);
        errdefer allocator.free(line_starts);
        var document = Document{
            .bytes = bytes,
            .fingerprint = fingerprint,
            .line_starts = line_starts,
            .max_display_width = 0,
        };
        for (0..document.rowCount()) |line_index| {
            document.max_display_width = @max(document.max_display_width, try displayWidth(document.lineBody(line_index).?));
        }
        return document;
    }

    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        allocator.free(self.line_starts);
        allocator.free(self.bytes);
        self.* = undefined;
    }

    /// Rows available to the viewer. Empty source has one synthetic row.
    pub fn rowCount(self: *const Document) usize {
        return self.line_starts.len;
    }

    /// Real content lines used by line-oriented Git decorations.
    pub fn contentLineCount(self: *const Document) usize {
        return if (self.bytes.len == 0) 0 else self.line_starts.len;
    }

    pub fn lineBody(self: *const Document, line_index: usize) ?[]const u8 {
        if (line_index >= self.line_starts.len) return null;
        const start: usize = self.line_starts[line_index];
        var end: usize = if (line_index + 1 < self.line_starts.len)
            self.line_starts[line_index + 1]
        else
            self.bytes.len;
        if (end > start and self.bytes[end - 1] == '\n') end -= 1;
        if (end > start and self.bytes[end - 1] == '\r') end -= 1;
        return self.bytes[start..end];
    }

    pub fn findNext(self: *const Document, query: []const u8, after: ?Match) ?Match {
        if (query.len == 0 or self.contentLineCount() == 0) return null;
        const start_line = if (after) |match| @min(match.line, self.contentLineCount() - 1) else 0;
        var pass: usize = 0;
        while (pass < 2) : (pass += 1) {
            var line_index: usize = if (pass == 0) start_line else 0;
            const end_line = if (pass == 0) self.contentLineCount() else start_line + 1;
            while (line_index < end_line) : (line_index += 1) {
                const line = self.lineBody(line_index).?;
                const start = if (pass == 0 and line_index == start_line and after != null)
                    @min(after.?.end, line.len)
                else
                    0;
                if (std.mem.indexOfPos(u8, line, start, query)) |index| return .{
                    .line = line_index,
                    .start = index,
                    .end = index + query.len,
                };
            }
        }
        return null;
    }

    pub fn findPrevious(self: *const Document, query: []const u8, before: ?Match) ?Match {
        if (query.len == 0 or self.contentLineCount() == 0) return null;
        if (before == null) {
            var remaining = self.contentLineCount();
            while (remaining > 0) {
                remaining -= 1;
                const line = self.lineBody(remaining).?;
                if (lastIndexInRange(line, query, 0, line.len)) |index| return .{
                    .line = remaining,
                    .start = index,
                    .end = index + query.len,
                };
            }
            return null;
        }

        const current = before.?;
        const start_line = @min(current.line, self.contentLineCount() - 1);
        const start_body = self.lineBody(start_line).?;
        if (lastIndexInRange(start_body, query, 0, @min(current.start, start_body.len))) |index| return .{
            .line = start_line,
            .start = index,
            .end = index + query.len,
        };

        var line_index = if (start_line == 0) self.contentLineCount() - 1 else start_line - 1;
        while (line_index != start_line) {
            const line = self.lineBody(line_index).?;
            if (lastIndexInRange(line, query, 0, line.len)) |index| return .{
                .line = line_index,
                .start = index,
                .end = index + query.len,
            };
            line_index = if (line_index == 0) self.contentLineCount() - 1 else line_index - 1;
        }

        if (lastIndexInRange(start_body, query, @min(current.end, start_body.len), start_body.len)) |index| return .{
            .line = start_line,
            .start = index,
            .end = index + query.len,
        };
        return current;
    }

    pub fn displayColumnForByte(self: *const Document, line_index: usize, byte_offset: usize) ?usize {
        const line = self.lineBody(line_index) orelse return null;
        const target = @min(byte_offset, line.len);
        var display_col: usize = 0;
        var iter = chasen.text.graphemeIterator(line);
        while (iter.next()) |grapheme| {
            if (grapheme.start >= target) break;
            if (target < grapheme.start + grapheme.len) break;
            const bytes = grapheme.bytes(line);
            if (bytes.len == 1 and bytes[0] == '\t') {
                display_col += tab_width - (display_col % tab_width);
            } else {
                display_col += chasen.text.displayWidth(bytes);
            }
        }
        return display_col;
    }

    pub fn lineDisplayWidth(self: *const Document, line_index: usize) ?usize {
        const line = self.lineBody(line_index) orelse return null;
        return displayWidth(line) catch null;
    }

    pub fn maxDisplayWidth(self: *const Document) usize {
        return self.max_display_width;
    }
};

pub const RangeWindow = struct {
    column: usize,
    text: []u8,
};

/// Builds only the visible display-cell window and expands TAB without
/// changing the retained source or logical copy text.
pub fn renderWindowAlloc(
    allocator: std.mem.Allocator,
    line: []const u8,
    horizontal_scroll: usize,
    width: usize,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (width == 0) return out.toOwnedSlice(allocator);

    var logical_col: usize = 0;
    var output_width: usize = 0;
    var iter = chasen.text.graphemeIterator(line);
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(line);
        if (bytes.len == 1 and bytes[0] == '\t') {
            const cells = tab_width - (logical_col % tab_width);
            const segment_end = logical_col + cells;
            if (segment_end > horizontal_scroll) {
                const visible_start = @max(logical_col, horizontal_scroll);
                const visible_cells = @min(segment_end - visible_start, width - output_width);
                try out.appendNTimes(allocator, ' ', visible_cells);
                output_width += visible_cells;
            }
            logical_col = segment_end;
        } else {
            const cells = chasen.text.displayWidth(bytes);
            const segment_end = logical_col + cells;
            if (segment_end > horizontal_scroll and logical_col < horizontal_scroll) {
                const visible_cells = @min(segment_end - horizontal_scroll, width - output_width);
                try out.appendNTimes(allocator, ' ', visible_cells);
                output_width += visible_cells;
            } else if (logical_col >= horizontal_scroll) {
                if (output_width + cells > width) break;
                try out.appendSlice(allocator, bytes);
                output_width += cells;
            }
            logical_col = segment_end;
        }
        if (output_width >= width) break;
    }
    return out.toOwnedSlice(allocator);
}

/// Renders the visible portion of every complete grapheme intersected by a
/// byte match. The returned column is relative to the source-text viewport.
pub fn renderRangeWindowAlloc(
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
        const bytes = grapheme.bytes(line);
        const cells = if (bytes.len == 1 and bytes[0] == '\t')
            tab_width - (logical_col % tab_width)
        else
            chasen.text.displayWidth(bytes);
        const segment_end = logical_col + cells;
        defer logical_col = segment_end;
        const grapheme_end = grapheme.start + grapheme.len;
        if (grapheme_end <= byte_start or grapheme.start >= clamped_end) continue;
        if (segment_end <= horizontal_scroll or logical_col >= viewport_end) continue;

        const visible_start = @max(logical_col, horizontal_scroll);
        const visible_end = @min(segment_end, viewport_end);
        if (visible_start >= visible_end) continue;
        if (first_column == null) first_column = visible_start - horizontal_scroll;
        const visible_cells = visible_end - visible_start;
        if (bytes.len == 1 and bytes[0] == '\t') {
            try out.appendNTimes(allocator, ' ', visible_cells);
            output_width += visible_cells;
        } else if (logical_col < horizontal_scroll) {
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

fn displayWidth(line: []const u8) !usize {
    var display_col: usize = 0;
    var iter = chasen.text.graphemeIterator(line);
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(line);
        const cells = if (bytes.len == 1 and bytes[0] == '\t')
            tab_width - (display_col % tab_width)
        else
            chasen.text.displayWidth(bytes);
        display_col = try std.math.add(usize, display_col, cells);
    }
    return display_col;
}

fn lastIndexInRange(line: []const u8, query: []const u8, start: usize, end: usize) ?usize {
    const clamped_end = @min(end, line.len);
    if (query.len == 0 or start > clamped_end or clamped_end - start < query.len) return null;
    var cursor = clamped_end - query.len;
    while (true) {
        if (std.mem.eql(u8, line[cursor .. cursor + query.len], query)) return cursor;
        if (cursor == start) return null;
        cursor -= 1;
    }
}

test "repository source line model distinguishes viewer rows and content lines" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { bytes: []const u8, rows: []const []const u8, content_lines: usize }{
        .{ .bytes = "", .rows = &.{""}, .content_lines = 0 },
        .{ .bytes = "a", .rows = &.{"a"}, .content_lines = 1 },
        .{ .bytes = "a\n", .rows = &.{"a"}, .content_lines = 1 },
        .{ .bytes = "a\n\n", .rows = &.{ "a", "" }, .content_lines = 2 },
        .{ .bytes = "a\r\nb", .rows = &.{ "a", "b" }, .content_lines = 2 },
    };
    for (cases) |case| {
        const bytes = try allocator.dupe(u8, case.bytes);
        var document = try Document.initOwned(allocator, bytes, content_fingerprint.Fingerprint.init(bytes));
        defer document.deinit(allocator);
        try std.testing.expectEqual(case.rows.len, document.rowCount());
        try std.testing.expectEqual(case.content_lines, document.contentLineCount());
        for (case.rows, 0..) |expected, index| try std.testing.expectEqualStrings(expected, document.lineBody(index).?);
    }
}

test "repository source search wraps by line and byte coordinate" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, "one needle\ntwo\nneedle three\n");
    var document = try Document.initOwned(allocator, bytes, content_fingerprint.Fingerprint.init(bytes));
    defer document.deinit(allocator);

    const first = document.findNext("needle", null).?;
    try std.testing.expectEqual(@as(usize, 0), first.line);
    const second = document.findNext("needle", first).?;
    try std.testing.expectEqual(@as(usize, 2), second.line);
    try std.testing.expectEqual(first, document.findNext("needle", second).?);
    try std.testing.expectEqual(second, document.findPrevious("needle", first).?);
    try std.testing.expect(document.findNext("absent", null) == null);
}

test "repository source search wraps both directions within one line" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, "needle x needle x needle");
    var document = try Document.initOwned(allocator, bytes, content_fingerprint.Fingerprint.init(bytes));
    defer document.deinit(allocator);

    const first = document.findNext("needle", null).?;
    const middle = document.findNext("needle", first).?;
    const last = document.findNext("needle", middle).?;
    try std.testing.expectEqual(first, document.findNext("needle", last).?);
    try std.testing.expectEqual(last, document.findPrevious("needle", first).?);
    try std.testing.expectEqual(middle, document.findPrevious("needle", last).?);
    try std.testing.expectEqual(first, document.findPrevious("needle", middle).?);
}

test "repository source render window expands tabs and preserves graphemes" {
    const allocator = std.testing.allocator;
    const rendered = try renderWindowAlloc(allocator, "a\tb界e\u{301}", 0, 12);
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings("a   b界e\u{301}", rendered);

    const clipped = try renderWindowAlloc(allocator, "界x", 1, 2);
    defer allocator.free(clipped);
    try std.testing.expectEqualStrings(" x", clipped);

    const preceded = try renderWindowAlloc(allocator, "a界x", 2, 2);
    defer allocator.free(preceded);
    try std.testing.expectEqualStrings(" x", preceded);

    const combining_bytes = try allocator.dupe(u8, "e\u{301}x");
    var combining = try Document.initOwned(allocator, combining_bytes, content_fingerprint.Fingerprint.init(combining_bytes));
    defer combining.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), combining.displayColumnForByte(0, 1).?);
}

test "repository source match window expands graphemes and preserves display columns" {
    const allocator = std.testing.allocator;
    const after_tab = (try renderRangeWindowAlloc(allocator, "a\tneedle", 2, 8, 0, 20)).?;
    defer allocator.free(after_tab.text);
    try std.testing.expectEqual(@as(usize, 4), after_tab.column);
    try std.testing.expectEqualStrings("needle", after_tab.text);

    const combining = (try renderRangeWindowAlloc(allocator, "e\u{301}x", 1, 3, 0, 10)).?;
    defer allocator.free(combining.text);
    try std.testing.expectEqual(@as(usize, 0), combining.column);
    try std.testing.expectEqualStrings("e\u{301}", combining.text);

    const clipped_wide = (try renderRangeWindowAlloc(allocator, "a界x", 1, 4, 2, 2)).?;
    defer allocator.free(clipped_wide.text);
    try std.testing.expectEqual(@as(usize, 0), clipped_wide.column);
    try std.testing.expectEqualStrings(" ", clipped_wide.text);

    const after_wide = (try renderRangeWindowAlloc(allocator, "a界x", 4, 5, 2, 2)).?;
    defer allocator.free(after_wide.text);
    try std.testing.expectEqual(@as(usize, 1), after_wide.column);
    try std.testing.expectEqualStrings("x", after_wide.text);
}

test "repository source model enforces one MiB and newline dense bounds" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.alloc(u8, selected_document.max_text_bytes);
    @memset(bytes, '\n');
    var document = try Document.initOwned(allocator, bytes, content_fingerprint.Fingerprint.init(bytes));
    defer document.deinit(allocator);
    try std.testing.expectEqual(selected_document.max_text_bytes, document.rowCount());
    try std.testing.expectEqual(selected_document.max_text_bytes, document.contentLineCount());
    try std.testing.expectEqual(@as(usize, 0), document.max_display_width);
    for (0..64) |_| try std.testing.expectEqual(@as(usize, 0), document.maxDisplayWidth());

    const oversized = try allocator.alloc(u8, selected_document.max_text_bytes + 1);
    defer allocator.free(oversized);
    try std.testing.expectError(
        error.SourceTooLarge,
        Document.initOwned(allocator, oversized, content_fingerprint.Fingerprint.init(oversized)),
    );
}
