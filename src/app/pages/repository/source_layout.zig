//! Borrowed Repository rows shared by drawing, navigation and pointer mapping.
const std = @import("std");
const projection = @import("chasen_ui").text_projection;
const wrap = @import("../../../line_wrap.zig");
const source = @import("../../../repository/source.zig");
const model = @import("model.zig");
const geometry = @import("source_geometry.zig");

pub const Row = struct {
    line: usize,
    ordinal: usize,
    text: projection.Projection,
    fragment: ?wrap.Fragment,

    pub fn position(self: Row, document: *const source.Document) model.SourcePosition {
        const fragment = self.fragment orelse return .{ .line = self.line };
        if (!fragment.continuation) return .{ .line = self.line };
        var tokens = fragment.tokens;
        const token = tokens.next();
        return .{ .line = self.line, .intra = .{
            .byte = if (token) |value| value.byte_start else fragment.bytes.start,
            .tab_cells = if (token) |value| fragment.cells.start -| value.cell_start else 0,
            .fingerprint = document.fingerprint,
        } };
    }

    pub fn segments(self: Row, horizontal: usize, width: usize) wrap.Segments {
        return if (self.fragment) |fragment| fragment.segments() else .{ .projected = self.text.visibleSegments(horizontal, width) };
    }

    pub fn hit(self: Row, horizontal: usize, cell: usize) ?projection.CellHit {
        return if (self.fragment) |fragment| fragment.hitCell(cell) else self.text.hitViewportCell(horizontal, cell);
    }

    pub fn leadingByte(self: Row) usize {
        return if (self.fragment) |fragment| fragment.bytes.start else 0;
    }
};

pub const Layout = struct {
    document: *const source.Document,
    width: usize,
    wrapped: bool,

    pub fn init(document: *const source.Document, viewer: model.ViewerState, pane: geometry.SourceGeometry) Layout {
        return .{ .document = document, .width = pane.text_width, .wrapped = viewer.line_wrap };
    }

    pub fn rows(self: Layout, position: model.SourcePosition) Rows {
        var top = position.admitted(self.document);
        if (!self.wrapped) top.intra = null;
        return .{ .layout = self, .line = top.line, .start = top };
    }

    /// Navigation borrows only fully validated admitted documents.
    fn first(self: Layout, position: model.SourcePosition) Row {
        var iterator = self.rows(position);
        return (iterator.next() catch unreachable).?;
    }

    pub fn contentRowAt(self: Layout, pane: geometry.SourceGeometry, top: model.SourcePosition, screen_row: u16) ?Row {
        if (screen_row < pane.body_first_row or screen_row >= pane.height) return null;
        var iterator = self.rows(top);
        for (0..screen_row - pane.body_first_row) |_| _ = (iterator.next() catch return null) orelse return null;
        const row = (iterator.next() catch return null) orelse return null;
        return if (row.line < self.document.contentLineCount()) row else null;
    }

    fn rowAtOrdinal(self: Layout, line: usize, ordinal: usize) Row {
        var iterator = self.rows(.{ .line = line });
        var row = (iterator.next() catch unreachable).?;
        for (0..ordinal) |_| row = (iterator.next() catch unreachable).?;
        return row;
    }

    fn lastInLine(self: Layout, line: usize) Row {
        var iterator = self.rows(.{ .line = line });
        var last = (iterator.next() catch unreachable).?;
        if (!self.wrapped) return last;
        while (!iterator.fragments.?.done) {
            last = (iterator.next() catch unreachable).?;
        }
        return last;
    }

    /// Walk only the affected lines/fragments; no document-wide row table.
    pub fn shift(self: Layout, position: model.SourcePosition, direction: isize, count: usize) model.SourcePosition {
        if (direction >= 0) {
            var iterator = self.rows(position);
            var row = (iterator.next() catch unreachable).?;
            for (0..count) |_| row = (iterator.next() catch unreachable) orelse break;
            return row.position(self.document);
        }
        var row = self.first(position);
        var remaining = count;
        while (remaining > row.ordinal) {
            remaining -= row.ordinal;
            if (row.line == 0) return .{};
            remaining -= 1;
            row = self.lastInLine(row.line - 1);
        }
        return self.rowAtOrdinal(row.line, row.ordinal - remaining).position(self.document);
    }

    fn sameRow(a: Row, b: Row) bool {
        return a.line == b.line and a.ordinal == b.ordinal;
    }

    pub fn clamp(self: Layout, position: model.SourcePosition, visible_rows: usize) model.SourcePosition {
        var admitted = position.admitted(self.document);
        if (!self.wrapped) {
            admitted.intra = null;
            admitted.line = @min(admitted.line, self.document.rowCount() -| @max(visible_rows, 1));
            return admitted;
        }
        // A full visible window already proves the top is within bounds.
        // Inspect the tail only when this window actually reaches it.
        var iterator = self.rows(admitted);
        const first_row = (iterator.next() catch unreachable).?;
        var available: usize = 1;
        const rows_needed = @max(visible_rows, 1);
        while (available < rows_needed) : (available += 1) {
            if ((iterator.next() catch unreachable) == null) {
                const earlier = self.shift(admitted, -1, rows_needed - available);
                return if (sameRow(first_row, self.first(earlier))) admitted else earlier;
            }
        }
        // Reflow must not replace the saved token by its new fragment start.
        return admitted;
    }

    pub fn scroll(self: Layout, position: model.SourcePosition, direction: isize, count: usize, visible_rows: usize) model.SourcePosition {
        const top = self.clamp(position, visible_rows);
        if (direction == 0) return top;
        const next = self.clamp(self.shift(top, direction, count), visible_rows);
        return if (sameRow(self.first(top), self.first(next))) top else next;
    }

    pub fn visibleLines(self: Layout, top: model.SourcePosition, visible_rows: usize) struct { first: usize, last: usize } {
        var iterator = self.rows(top);
        const first_row = (iterator.next() catch unreachable).?;
        var last = first_row.line;
        for (1..@max(visible_rows, 1)) |_| {
            const row = (iterator.next() catch unreachable) orelse break;
            last = row.line;
        }
        return .{ .first = first_row.line, .last = last };
    }

    /// Explicit navigation reveals a fragment, with the existing comfort band.
    pub fn reveal(self: Layout, top: model.SourcePosition, target: model.SourcePosition, visible_rows: usize, centered: bool) model.SourcePosition {
        if (visible_rows == 0) return self.clamp(top, visible_rows);
        const target_row = self.first(target);
        const margin = @min(@as(usize, 8), visible_rows / 3);
        const first_band = if (centered) visible_rows / 2 else margin;
        const last_band = if (centered) first_band else visible_rows - 1 - margin;
        var iterator = self.rows(top);
        for (0..visible_rows) |index| {
            const row = (iterator.next() catch unreachable) orelse break;
            if (sameRow(row, target_row)) {
                if (index >= first_band and index <= last_band) return self.clamp(top, visible_rows);
                return self.clamp(self.shift(target, -1, if (index < first_band) first_band else last_band), visible_rows);
            }
        }
        const current = self.first(top);
        const before = target_row.line < current.line or
            (target_row.line == current.line and target_row.ordinal < current.ordinal);
        return self.clamp(self.shift(target, -1, if (before) first_band else last_band), visible_rows);
    }
};

pub const Rows = struct {
    layout: Layout,
    line: usize,
    start: model.SourcePosition,
    text: ?projection.Projection = null,
    fragments: ?wrap.Iterator = null,
    ordinal: usize = 0,

    pub fn next(self: *Rows) projection.Error!?Row {
        while (self.line < self.layout.document.rowCount()) {
            if (self.text == null) {
                self.text = try projection.Projection.init(self.layout.document.lineBody(self.line).?, .{ .tab_width = 4 });
                self.ordinal = 0;
                if (self.layout.wrapped) self.fragments = wrap.Iterator.init(self.text.?, self.layout.width);
            }
            if (self.fragments) |*fragments| {
                const target_cell = if (self.start.intra) |intra|
                    self.text.?.leadingCellForByte(intra.byte) +| intra.tab_cells
                else
                    0;
                while (fragments.next()) |fragment| {
                    const ordinal = self.ordinal;
                    self.ordinal += 1;
                    if (self.start.intra != null and !fragment.placeholder and
                        fragment.cells.end <= target_cell and !fragments.done) continue;
                    self.start.intra = null;
                    return .{ .line = self.line, .ordinal = ordinal, .text = self.text.?, .fragment = fragment };
                }
            } else {
                const row: Row = .{ .line = self.line, .ordinal = 0, .text = self.text.?, .fragment = null };
                self.line += 1;
                self.text = null;
                return row;
            }
            self.line += 1;
            self.text = null;
            self.fragments = null;
        }
        return null;
    }
};

test "repository wrap reflow preserves token TAB anchors and excludes chrome and empty hits" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, "a\tbcdefghijklmnop\nlast\n");
    var document = try source.Document.initOwnedOrFree(allocator, bytes, .init(bytes));
    defer document.deinit(allocator);
    var viewer: model.ViewerState = .{ .line_wrap = true };
    const narrow = geometry.SourceGeometry.init(.{ .width = 4, .height = 4 }, &document, false);
    const layout = Layout.init(&document, viewer, narrow);
    viewer.source_vertical_scroll = layout.scroll(.{}, 1, 1, 1);
    const anchor = viewer.source_vertical_scroll;
    try std.testing.expectEqual(@as(usize, 1), anchor.intra.?.byte);
    try std.testing.expectEqual(@as(usize, 1), anchor.intra.?.tab_cells);
    const wide = geometry.SourceGeometry.init(.{ .width = 7, .height = 4 }, &document, false);
    try std.testing.expectEqualDeep(anchor, Layout.init(&document, viewer, wide).clamp(anchor, 1));
    const zero = geometry.SourceGeometry.init(.{ .width = 1, .height = 8 }, &document, false);
    try std.testing.expectEqualDeep(anchor, Layout.init(&document, viewer, zero).clamp(anchor, zero.visible_source_rows));
    const hidden = Layout.init(&document, viewer, zero).contentRowAt(zero, anchor, zero.body_first_row).?;
    try std.testing.expect(hidden.hit(0, 0) == null);
    const restored = layout.contentRowAt(narrow, anchor, narrow.body_first_row).?;
    try std.testing.expectEqual(@as(usize, 2), restored.fragment.?.cells.start);
    for (0..narrow.body_first_row) |row| try std.testing.expect(layout.contentRowAt(narrow, anchor, @intCast(row)) == null);
    try std.testing.expect(layout.contentRowAt(narrow, anchor, narrow.height) == null);
    const empty_bytes = try allocator.dupe(u8, "");
    var empty = try source.Document.initOwnedOrFree(allocator, empty_bytes, .init(empty_bytes));
    defer empty.deinit(allocator);
    const empty_layout = Layout.init(&empty, viewer, narrow);
    try std.testing.expect(empty_layout.contentRowAt(narrow, .{}, narrow.body_first_row) == null);
    try std.testing.expectEqualDeep(model.SourcePosition{}, empty_layout.scroll(.{}, 1, 10, 1));
}
