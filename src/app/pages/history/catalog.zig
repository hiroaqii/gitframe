//! History catalog ownership and viewport navigation.

const std = @import("std");
const ui = @import("chasen_ui");
const git_history = @import("../../../git/history.zig");

pub const State = struct {
    snapshot: ?git_history.Snapshot = null,
    total_count: ?usize = null,
    records: std.ArrayListUnmanaged(git_history.Record) = .empty,
    continuation: ?git_history.ObjectId = null,
    capped: bool = false,
    cursor: usize = 0,
    scroll: usize = 0,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.snapshot) |*snapshot| snapshot.deinit(allocator);
        for (self.records.items) |*record| record.deinit(allocator);
        self.records.deinit(allocator);
        self.* = .{};
    }

    pub fn clear(self: *State, allocator: std.mem.Allocator) void {
        self.deinit(allocator);
    }

    pub fn rowCount(self: *const State) usize {
        return self.records.items.len + @intFromBool(self.hasMoreRow());
    }

    pub fn hasMoreRow(self: *const State) bool {
        return self.continuation != null and !self.capped;
    }

    pub fn moreRowSelected(self: *const State) bool {
        return self.hasMoreRow() and self.cursor == self.records.items.len;
    }

    pub fn canMovePrevious(self: *const State) bool {
        return self.rowCount() > 0 and self.cursor > 0;
    }

    pub fn canMoveNext(self: *const State) bool {
        const count = self.rowCount();
        return count > 0 and self.cursor < count - 1;
    }

    pub fn replace(self: *State, allocator: std.mem.Allocator, page: *git_history.Page) !void {
        const snapshot = page.takeSnapshot() orelse return error.MissingInitialSnapshot;
        const records = page.takeRecords();
        var replacement: State = .{
            .snapshot = snapshot,
            .total_count = page.total_count,
            .records = .{ .items = records, .capacity = records.len },
            .continuation = page.continuation,
            .capped = records.len >= git_history.catalog_limit,
        };
        if (replacement.capped) replacement.continuation = null;
        self.deinit(allocator);
        self.* = replacement;
    }

    pub fn append(self: *State, allocator: std.mem.Allocator, page: *git_history.Page) !void {
        if (self.snapshot == null or page.snapshot != null or !self.hasMoreRow()) return error.InvalidContinuation;
        if (page.records.len == 0 or self.records.items.len + page.records.len > git_history.catalog_limit)
            return error.InvalidContinuation;
        try self.records.ensureUnusedCapacity(allocator, page.records.len);
        const incoming = page.takeRecords();
        defer allocator.free(incoming);
        self.records.appendSliceAssumeCapacity(incoming);
        self.continuation = page.continuation;
        self.capped = self.records.items.len >= git_history.catalog_limit;
        if (self.capped) self.continuation = null;
    }

    pub fn movePrevious(self: *State, body_height: u16) void {
        if (self.canMovePrevious()) self.cursor -= 1;
        self.keepCursorVisible(visibleRows(body_height));
    }

    pub fn moveNext(self: *State, body_height: u16) void {
        if (self.canMoveNext()) self.cursor += 1;
        self.keepCursorVisible(visibleRows(body_height));
    }

    pub fn pageUp(self: *State, body_height: u16) void {
        self.cursor -|= @max(visibleRows(body_height), 1);
        self.keepCursorVisible(visibleRows(body_height));
    }

    pub fn pageDown(self: *State, body_height: u16) void {
        const count = self.rowCount();
        if (count > 0) self.cursor = @min(self.cursor +| @max(visibleRows(body_height), 1), count - 1);
        self.keepCursorVisible(visibleRows(body_height));
    }

    pub fn first(self: *State, body_height: u16) void {
        self.cursor = 0;
        self.keepCursorVisible(visibleRows(body_height));
    }

    pub fn last(self: *State, body_height: u16) void {
        self.cursor = self.rowCount() -| 1;
        self.keepCursorVisible(visibleRows(body_height));
    }

    pub fn clamp(self: *State, rows: usize) void {
        const count = self.rowCount();
        self.cursor = if (count == 0) 0 else @min(self.cursor, count - 1);
        self.scroll = ui.Viewport.init(.{
            .total = count,
            .height = rows,
            .offset = self.scroll,
        }).clampedOffset();
        self.keepCursorVisible(rows);
    }

    pub fn visibleRange(self: *const State, body_height: u16) ui.Viewport.Range {
        return ui.Viewport.init(.{
            .total = self.rowCount(),
            .height = visibleRows(body_height),
            .offset = self.scroll,
        }).visibleRange();
    }

    fn keepCursorVisible(self: *State, rows: usize) void {
        self.scroll = ui.Viewport.offsetKeepingIndexVisible(
            self.rowCount(),
            rows,
            self.scroll,
            self.cursor,
        );
    }
};

/// The catalog context occupies row zero; every remaining row belongs to the
/// scrolling list.
pub fn visibleRows(body_height: u16) usize {
    return body_height -| 1;
}

test "History catalog viewport includes only the load-more operation row" {
    var state: State = .{};
    state.records.items = &.{};
    state.continuation = try git_history.ObjectId.parse(.sha1, "0123456789abcdef0123456789abcdef01234567");
    try std.testing.expectEqual(@as(usize, 1), state.rowCount());
    try std.testing.expect(state.moreRowSelected());
    state.capped = true;
    try std.testing.expectEqual(@as(usize, 0), state.rowCount());
}

test "History catalog navigation reuses Viewport keep-visible semantics" {
    var records: [10]git_history.Record = undefined;
    var state: State = .{ .records = .{ .items = &records, .capacity = records.len } };
    try std.testing.expect(!state.canMovePrevious());
    try std.testing.expect(state.canMoveNext());
    state.pageDown(5);
    try std.testing.expectEqual(@as(usize, 4), state.cursor);
    try std.testing.expectEqual(@as(usize, 1), state.scroll);
    state.last(5);
    try std.testing.expectEqual(@as(usize, 9), state.cursor);
    try std.testing.expectEqual(@as(usize, 6), state.scroll);
    try std.testing.expect(state.canMovePrevious());
    try std.testing.expect(!state.canMoveNext());
    state.continuation = try git_history.ObjectId.parse(.sha1, "0123456789abcdef0123456789abcdef01234567");
    try std.testing.expect(state.canMoveNext());
    state.moveNext(5);
    try std.testing.expect(state.moreRowSelected());
    try std.testing.expect(!state.canMoveNext());
    state.first(5);
    try std.testing.expectEqual(@as(usize, 0), state.cursor);
    try std.testing.expectEqual(@as(usize, 0), state.scroll);
    state.records = .empty;
    state.continuation = null;
}

test "History catalog gives the removed column-label row back to the viewport" {
    try std.testing.expectEqual(@as(usize, 0), visibleRows(0));
    try std.testing.expectEqual(@as(usize, 0), visibleRows(1));
    try std.testing.expectEqual(@as(usize, 23), visibleRows(24));
}
