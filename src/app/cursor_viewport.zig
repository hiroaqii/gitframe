//! Allocation-free cursor and viewport placement for semantic row cursors.
//!
//! Callers retain ownership of domain coordinates. This module only maps
//! bounded rendered-row ordinals to scroll offsets and post-scroll ordinals.

const std = @import("std");

pub const max_comfort_margin: usize = 8;

pub const Band = struct {
    first: usize,
    last: usize,

    pub fn contains(self: Band, row: usize) bool {
        return row >= self.first and row <= self.last;
    }
};

pub const Bounds = struct {
    content_rows: usize,
    visible_rows: usize,

    /// A zero-height viewport retains the current content anchor by using one
    /// effective row for bounds only. Interactive placement remains disabled.
    pub fn maxScroll(self: Bounds) usize {
        return self.content_rows -| @max(self.visible_rows, 1);
    }

    pub fn clampScroll(self: Bounds, scroll: usize) usize {
        return @min(scroll, self.maxScroll());
    }

    pub fn comfortBand(self: Bounds) ?Band {
        if (self.content_rows == 0 or self.visible_rows == 0) return null;
        const margin = @min(max_comfort_margin, self.visible_rows / 3);
        return .{
            .first = margin,
            .last = (self.visible_rows - 1) -| margin,
        };
    }

    fn clampCursor(self: Bounds, cursor: usize) ?usize {
        if (self.content_rows == 0) return null;
        return @min(cursor, self.content_rows - 1);
    }
};

/// Minimum-visibility reconciliation. It never centers a visible cursor.
pub fn keepCursorVisible(bounds: Bounds, scroll: usize, cursor: usize) usize {
    var next = bounds.clampScroll(scroll);
    const target = bounds.clampCursor(cursor) orelse return next;
    if (bounds.visible_rows == 0) return next;

    if (target < next) {
        next = target;
    } else if (target - next >= bounds.visible_rows) {
        next = target - (bounds.visible_rows - 1);
    }
    return bounds.clampScroll(next);
}

/// Cursor-primary placement used by single-row movement and explicit jumps.
pub fn placeCursorInComfortBand(bounds: Bounds, scroll: usize, cursor: usize) usize {
    const clamped_scroll = bounds.clampScroll(scroll);
    const band = bounds.comfortBand() orelse return clamped_scroll;
    const target = bounds.clampCursor(cursor) orelse return clamped_scroll;

    if (target < clamped_scroll) {
        return bounds.clampScroll(target -| band.first);
    }
    const screen_row = target - clamped_scroll;
    if (screen_row < band.first) {
        return bounds.clampScroll(target -| band.first);
    }
    if (screen_row > band.last) {
        return bounds.clampScroll(target - band.last);
    }
    return clamped_scroll;
}

/// Coarse cursor-primary placement. Bounds may leave the cursor at a content
/// edge because virtual padding is intentionally unsupported.
pub fn centerCursor(bounds: Bounds, scroll: usize, cursor: usize) usize {
    const clamped_scroll = bounds.clampScroll(scroll);
    if (bounds.visible_rows == 0) return clamped_scroll;
    const target = bounds.clampCursor(cursor) orelse return clamped_scroll;
    return bounds.clampScroll(target -| (bounds.visible_rows / 2));
}

/// Viewport-primary wheel synchronization. The caller owns the scroll move and
/// must preserve its domain cursor identity when this returns the old ordinal.
pub fn retargetCursorAfterViewportScroll(
    bounds: Bounds,
    old_scroll: usize,
    new_scroll: usize,
    old_cursor: ?usize,
) ?usize {
    const old = bounds.clampScroll(old_scroll);
    const new = bounds.clampScroll(new_scroll);
    if (old == new or bounds.visible_rows == 0) return old_cursor;
    if (bounds.content_rows == 0) return null;

    if (old_cursor) |cursor| {
        if (cursor >= old) {
            const screen_row = cursor - old;
            if (screen_row < bounds.visible_rows) {
                if (bounds.comfortBand()) |band| {
                    const candidate = new +| screen_row;
                    if (band.contains(screen_row) and candidate < bounds.content_rows) {
                        return candidate;
                    }
                }
            }
        }
    }

    return @min(new +| (bounds.visible_rows / 2), bounds.content_rows - 1);
}

test "cursor viewport comfort band saturates for small heights and caps its margin" {
    try std.testing.expect((Bounds{ .content_rows = 10, .visible_rows = 0 }).comfortBand() == null);
    try std.testing.expectEqual(Band{ .first = 0, .last = 0 }, (Bounds{ .content_rows = 10, .visible_rows = 1 }).comfortBand().?);
    try std.testing.expectEqual(Band{ .first = 0, .last = 1 }, (Bounds{ .content_rows = 10, .visible_rows = 2 }).comfortBand().?);
    try std.testing.expectEqual(Band{ .first = 1, .last = 1 }, (Bounds{ .content_rows = 10, .visible_rows = 3 }).comfortBand().?);
    try std.testing.expectEqual(Band{ .first = 8, .last = 31 }, (Bounds{ .content_rows = 100, .visible_rows = 40 }).comfortBand().?);
}

test "cursor viewport bounds handle empty short zero-height and maximal values" {
    try std.testing.expectEqual(@as(usize, 0), (Bounds{ .content_rows = 0, .visible_rows = 0 }).maxScroll());
    try std.testing.expectEqual(@as(usize, 0), (Bounds{ .content_rows = 4, .visible_rows = 8 }).maxScroll());
    try std.testing.expectEqual(@as(usize, 3), (Bounds{ .content_rows = 4, .visible_rows = 0 }).maxScroll());

    const maximum = std.math.maxInt(usize);
    const bounds = Bounds{ .content_rows = maximum, .visible_rows = maximum };
    try std.testing.expectEqual(@as(usize, 0), bounds.maxScroll());
    try std.testing.expectEqual(@as(usize, 0), bounds.clampScroll(maximum));
    try std.testing.expectEqual(@as(?usize, maximum - 2), retargetCursorAfterViewportScroll(
        .{ .content_rows = maximum, .visible_rows = 3 },
        maximum - 4,
        maximum - 3,
        maximum - 1,
    ));
}

test "cursor viewport minimum visibility does not recenter visible rows" {
    const bounds = Bounds{ .content_rows = 100, .visible_rows = 9 };
    try std.testing.expectEqual(@as(usize, 20), keepCursorVisible(bounds, 20, 24));
    try std.testing.expectEqual(@as(usize, 10), keepCursorVisible(bounds, 20, 10));
    try std.testing.expectEqual(@as(usize, 22), keepCursorVisible(bounds, 20, 30));
    try std.testing.expectEqual(@as(usize, 20), keepCursorVisible(.{ .content_rows = 100, .visible_rows = 0 }, 20, 99));
}

test "cursor viewport comfort placement follows only outside the band" {
    const bounds = Bounds{ .content_rows = 100, .visible_rows = 9 };
    try std.testing.expectEqual(Band{ .first = 3, .last = 5 }, bounds.comfortBand().?);
    try std.testing.expectEqual(@as(usize, 20), placeCursorInComfortBand(bounds, 20, 23));
    try std.testing.expectEqual(@as(usize, 20), placeCursorInComfortBand(bounds, 20, 25));
    try std.testing.expectEqual(@as(usize, 19), placeCursorInComfortBand(bounds, 20, 22));
    try std.testing.expectEqual(@as(usize, 21), placeCursorInComfortBand(bounds, 20, 26));
    try std.testing.expectEqual(@as(usize, 0), placeCursorInComfortBand(bounds, 20, 0));
    try std.testing.expectEqual(@as(usize, 91), placeCursorInComfortBand(bounds, 20, 99));
}

test "cursor viewport coarse placement centers when bounds permit" {
    const bounds = Bounds{ .content_rows = 100, .visible_rows = 10 };
    try std.testing.expectEqual(@as(usize, 45), centerCursor(bounds, 0, 50));
    try std.testing.expectEqual(@as(usize, 0), centerCursor(bounds, 40, 0));
    try std.testing.expectEqual(@as(usize, 90), centerCursor(bounds, 0, 99));
    try std.testing.expectEqual(@as(usize, 12), centerCursor(.{ .content_rows = 100, .visible_rows = 0 }, 12, 99));
}

test "cursor viewport wheel preserves band rows and recenters edge rows" {
    const bounds = Bounds{ .content_rows = 100, .visible_rows = 9 };
    try std.testing.expectEqual(@as(?usize, 25), retargetCursorAfterViewportScroll(bounds, 20, 21, 24));
    try std.testing.expectEqual(@as(?usize, 25), retargetCursorAfterViewportScroll(bounds, 20, 21, 20));
    try std.testing.expectEqual(@as(?usize, 24), retargetCursorAfterViewportScroll(bounds, 21, 20, 29));
    try std.testing.expectEqual(@as(?usize, 24), retargetCursorAfterViewportScroll(bounds, 20, 20, 24));
    try std.testing.expectEqual(@as(?usize, 25), retargetCursorAfterViewportScroll(bounds, 20, 21, null));
    try std.testing.expectEqual(@as(?usize, 95), retargetCursorAfterViewportScroll(bounds, 90, 91, 98));
    try std.testing.expectEqual(@as(?usize, 7), retargetCursorAfterViewportScroll(
        .{ .content_rows = 100, .visible_rows = 0 },
        5,
        6,
        7,
    ));
    try std.testing.expect(retargetCursorAfterViewportScroll(.{ .content_rows = 0, .visible_rows = 9 }, 0, 1, null) == null);
}
