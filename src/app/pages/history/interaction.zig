//! History three-pane interaction state and pure layout/navigation transitions.

const std = @import("std");
const ui = @import("chasen_ui");

pub const Focus = enum {
    history,
    commit_detail,
    changed_files,

    pub fn next(self: Focus) Focus {
        return switch (self) {
            .history => .commit_detail,
            .commit_detail => .changed_files,
            .changed_files => .history,
        };
    }

    pub fn previous(self: Focus) Focus {
        return switch (self) {
            .history => .changed_files,
            .commit_detail => .history,
            .changed_files => .commit_detail,
        };
    }
};

pub const VerticalAction = enum {
    row_previous,
    row_next,
    page_previous,
    page_next,
    first,
    last,
};

pub const HorizontalAction = enum { left, right };
pub const WidthAction = enum { decrease, increase };

pub const ContentAnchor = struct {
    block_index: usize = 0,
    source_byte_offset: usize = 0,
};

/// One labeled detail value. Continuation rows use the label's display width
/// as their hanging indent; anchors always refer to bytes in `value`.
pub const DetailBlock = struct {
    label: []const u8,
    value: []const u8,
};

pub const DetailLayout = struct {
    blocks: []const DetailBlock,
    width: u16,

    pub fn lineStarts(self: DetailLayout) LineIterator {
        return .{ .blocks = self.blocks, .width = self.width };
    }

    pub fn lineCount(self: DetailLayout) usize {
        var count: usize = 0;
        var lines = self.lineStarts();
        while (lines.next() != null) count +|= 1;
        return count;
    }

    fn ordinalAtOrBefore(self: DetailLayout, target: ContentAnchor) usize {
        var ordinal: usize = 0;
        var last: usize = 0;
        var lines = self.lineStarts();
        while (lines.next()) |candidate| : (ordinal +|= 1) {
            if (candidate.block_index > target.block_index or
                (candidate.block_index == target.block_index and
                    candidate.source_byte_offset > target.source_byte_offset)) return last;
            last = ordinal;
        }
        return last;
    }

    fn anchorAt(self: DetailLayout, target: usize) ContentAnchor {
        var ordinal: usize = 0;
        var last: ContentAnchor = .{};
        var lines = self.lineStarts();
        while (lines.next()) |candidate| : (ordinal +|= 1) {
            last = candidate;
            if (ordinal == target) return candidate;
        }
        return last;
    }
};

pub const LineIterator = struct {
    blocks: []const DetailBlock,
    width: u16,
    block_index: usize = 0,
    source_byte_offset: usize = 0,
    started_block: bool = false,

    pub fn next(self: *LineIterator) ?ContentAnchor {
        while (self.block_index < self.blocks.len) {
            if (!self.started_block) {
                self.started_block = true;
                self.source_byte_offset = 0;
                return .{ .block_index = self.block_index, .source_byte_offset = 0 };
            }
            if (nextLineStart(self.blocks[self.block_index], self.source_byte_offset, self.width)) |offset| {
                self.source_byte_offset = offset;
                return .{ .block_index = self.block_index, .source_byte_offset = offset };
            }
            self.block_index += 1;
            self.started_block = false;
        }
        return null;
    }
};

pub const OuterWidths = struct {
    left: u16,
    divider: u16,
    right: u16,
};

pub const State = struct {
    focus: Focus = .history,
    detail_anchor: ContentAnchor = .{},
    files_vertical_offset: usize = 0,
    files_horizontal_offset: usize = 0,
    preferred_left_width: ?u16 = null,

    pub fn focusNext(self: *State) void {
        self.focus = self.focus.next();
    }

    pub fn focusPrevious(self: *State) void {
        self.focus = self.focus.previous();
    }

    pub fn selectionChanged(self: *State) void {
        self.detail_anchor = .{};
        self.files_vertical_offset = 0;
        self.files_horizontal_offset = 0;
    }

    pub fn moveDetail(
        self: *State,
        blocks: []const DetailBlock,
        width: u16,
        height: u16,
        action: VerticalAction,
    ) void {
        const layout: DetailLayout = .{ .blocks = blocks, .width = width };
        const total = layout.lineCount();
        if (total == 0) {
            self.detail_anchor = .{};
            return;
        }
        const max_offset = viewportMaxOffset(total, height);
        const current = @min(layout.ordinalAtOrBefore(self.detail_anchor), max_offset);
        const target = moveOffset(current, max_offset, height, action);
        self.detail_anchor = layout.anchorAt(target);
    }

    /// Preserve the logical block/source position across wrapping changes,
    /// then clamp it to a valid top-of-viewport line.
    pub fn reflowDetail(self: *State, blocks: []const DetailBlock, width: u16, height: u16) void {
        const layout: DetailLayout = .{ .blocks = blocks, .width = width };
        const total = layout.lineCount();
        if (total == 0) {
            self.detail_anchor = .{};
            return;
        }
        const ordinal = @min(layout.ordinalAtOrBefore(self.detail_anchor), viewportMaxOffset(total, height));
        self.detail_anchor = layout.anchorAt(ordinal);
    }

    pub fn moveFilesVertical(self: *State, total: usize, height: u16, action: VerticalAction) void {
        const max_offset = viewportMaxOffset(total, height);
        self.files_vertical_offset = moveOffset(
            @min(self.files_vertical_offset, max_offset),
            max_offset,
            height,
            action,
        );
    }

    pub fn moveFilesHorizontal(self: *State, total_cells: usize, width: u16, action: HorizontalAction) void {
        const max_offset = viewportMaxOffset(total_cells, width);
        const current = @min(self.files_horizontal_offset, max_offset);
        self.files_horizontal_offset = switch (action) {
            .left => current -| 1,
            .right => @min(current +| 1, max_offset),
        };
    }

    pub fn clampFiles(self: *State, total: usize, height: u16, path_cells: usize, path_width: u16) void {
        self.files_vertical_offset = @min(self.files_vertical_offset, viewportMaxOffset(total, height));
        self.files_horizontal_offset = @min(self.files_horizontal_offset, viewportMaxOffset(path_cells, path_width));
    }

    pub fn outerWidths(self: State, total: u16) OuterWidths {
        if (total == 0) return .{ .left = 0, .divider = 0, .right = 0 };
        const divider: u16 = 1;
        const available = total - divider;
        const preferred = self.preferred_left_width orelse available / 2;
        const left = clampLeftWidth(total, preferred);
        return .{ .left = left, .divider = divider, .right = available - left };
    }

    pub fn adjustWidth(self: *State, total: u16, action: WidthAction) void {
        const current = self.outerWidths(total).left;
        const requested = switch (action) {
            .decrease => current -| 4,
            .increase => current +| 4,
        };
        self.preferred_left_width = clampLeftWidth(total, requested);
    }
};

fn nextLineStart(block: DetailBlock, current: usize, width: u16) ?usize {
    if (current > block.value.len) return null;
    const logical_end = std.mem.indexOfScalarPos(u8, block.value, current, '\n') orelse block.value.len;
    if (current < logical_end) {
        const projection = ui.text_projection.Projection.init(
            block.value[current..logical_end],
            .{ .tab_width = 4 },
        ) catch unreachable;
        const available = valueWidth(block.label, width);
        var consumed_end: usize = 0;
        var consumed_cells: usize = 0;
        var tokens = projection.tokens();
        while (tokens.next()) |token| {
            if (consumed_cells != 0 and token.cell_end > available) break;
            consumed_end = token.byte_end;
            consumed_cells = token.cell_end;
        }
        if (consumed_end < logical_end - current) return current + consumed_end;
    }
    return if (logical_end < block.value.len) logical_end + 1 else null;
}

fn valueWidth(label: []const u8, width: u16) usize {
    const projection = ui.text_projection.Projection.init(label, .{ .tab_width = 4 }) catch unreachable;
    return @max(@as(usize, width) -| projection.displayWidth(), 1);
}

fn viewportMaxOffset(total: usize, height: u16) usize {
    return ui.Viewport.init(.{ .total = total, .height = height }).maxOffset();
}

fn moveOffset(current: usize, max_offset: usize, height: u16, action: VerticalAction) usize {
    return switch (action) {
        .row_previous => current -| 1,
        .row_next => @min(current +| 1, max_offset),
        .page_previous => current -| @as(usize, height),
        .page_next => @min(current +| @as(usize, height), max_offset),
        .first => 0,
        .last => max_offset,
    };
}

fn clampLeftWidth(total: u16, preferred: u16) u16 {
    if (total == 0) return 0;
    const available = total - 1;
    if (available < 2) return @min(preferred, available);
    const minimum: u16 = if (total >= 90) 42 else 1;
    const right_minimum: u16 = if (total >= 90) 47 else 1;
    return @min(@max(preferred, minimum), available - right_minimum);
}

test "History interaction cycles fixed focus and clamps file offsets" {
    var state: State = .{};
    state.focusPrevious();
    try std.testing.expectEqual(Focus.changed_files, state.focus);
    state.focusNext();
    state.focusNext();
    state.focusNext();
    try std.testing.expectEqual(Focus.changed_files, state.focus);

    state.moveFilesVertical(20, 5, .last);
    state.moveFilesHorizontal(30, 8, .right);
    try std.testing.expectEqual(@as(usize, 15), state.files_vertical_offset);
    try std.testing.expectEqual(@as(usize, 1), state.files_horizontal_offset);
    state.moveFilesVertical(20, 5, .row_previous);
    state.moveFilesHorizontal(30, 8, .left);
    try std.testing.expectEqual(@as(usize, 14), state.files_vertical_offset);
    try std.testing.expectEqual(@as(usize, 0), state.files_horizontal_offset);
    state.clampFiles(2, 5, 3, 8);
    try std.testing.expectEqual(@as(usize, 0), state.files_vertical_offset);
    try std.testing.expectEqual(@as(usize, 0), state.files_horizontal_offset);

    state.detail_anchor = .{ .block_index = 2, .source_byte_offset = 9 };
    state.files_vertical_offset = 4;
    state.files_horizontal_offset = 7;
    state.selectionChanged();
    try std.testing.expectEqual(ContentAnchor{}, state.detail_anchor);
    try std.testing.expectEqual(@as(usize, 0), state.files_vertical_offset);
    try std.testing.expectEqual(@as(usize, 0), state.files_horizontal_offset);
    try std.testing.expectEqual(Focus.changed_files, state.focus);
}

test "History interaction preserves a logical detail anchor across reflow" {
    const blocks = [_]DetailBlock{
        .{ .label = "Commit: ", .value = "abcdef" },
        .{ .label = "Message: ", .value = "alpha-beta-gamma\nsecond" },
    };
    var state: State = .{ .detail_anchor = .{ .block_index = 1, .source_byte_offset = 5 } };
    state.reflowDetail(&blocks, 11, 1);
    try std.testing.expectEqual(ContentAnchor{ .block_index = 1, .source_byte_offset = 4 }, state.detail_anchor);
    state.moveDetail(&blocks, 14, 2, .last);
    try std.testing.expect(state.detail_anchor.block_index == 1);
    state.moveDetail(&blocks, 11, 2, .first);
    try std.testing.expectEqual(ContentAnchor{}, state.detail_anchor);
    state.moveDetail(&blocks, 11, 2, .row_next);
    try std.testing.expectEqual(ContentAnchor{ .block_index = 0, .source_byte_offset = 3 }, state.detail_anchor);
    state.moveDetail(&blocks, 11, 2, .row_previous);
    try std.testing.expectEqual(ContentAnchor{}, state.detail_anchor);
    state.moveDetail(&blocks, 11, 2, .page_next);
    try std.testing.expect(state.detail_anchor.source_byte_offset > 0 or state.detail_anchor.block_index > 0);
}

test "History interaction clamps width without overwriting the preference on resize" {
    var state: State = .{};
    try std.testing.expectEqual(OuterWidths{ .left = 59, .divider = 1, .right = 60 }, state.outerWidths(120));
    try std.testing.expectEqual(OuterWidths{ .left = 42, .divider = 1, .right = 47 }, state.outerWidths(90));
    for ([_]u16{ 0, 1, 2, 89 }) |width| {
        const parts = state.outerWidths(width);
        try std.testing.expectEqual(width, parts.left + parts.divider + parts.right);
    }

    state.adjustWidth(120, .increase);
    try std.testing.expectEqual(@as(?u16, 63), state.preferred_left_width);
    state.adjustWidth(120, .decrease);
    try std.testing.expectEqual(@as(?u16, 59), state.preferred_left_width);
    state.adjustWidth(120, .increase);
    _ = state.outerWidths(64);
    try std.testing.expectEqual(@as(?u16, 63), state.preferred_left_width);
    try std.testing.expectEqual(OuterWidths{ .left = 63, .divider = 1, .right = 56 }, state.outerWidths(120));
}
