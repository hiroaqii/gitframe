//! History commit-picker draft state.
//!
//! The catalog owns cursor and scroll. This type owns only the optional range
//! anchor, so direction and normalized endpoints cannot drift into a second
//! source of truth.

const std = @import("std");

pub const Direction = enum {
    at_anchor,
    toward_newer,
    toward_older,
};

pub const Span = struct {
    newest: usize,
    oldest: usize,
};

pub const Draft = union(enum) {
    single,
    range: usize,

    pub fn toggleAnchor(self: *Draft, cursor: usize) void {
        self.* = switch (self.*) {
            .single => .{ .range = cursor },
            .range => .single,
        };
    }

    pub fn clearAnchor(self: *Draft) bool {
        return switch (self.*) {
            .single => false,
            .range => blk: {
                self.* = .single;
                break :blk true;
            },
        };
    }

    pub fn anchor(self: Draft) ?usize {
        return switch (self) {
            .single => null,
            .range => |index| index,
        };
    }

    pub fn isRange(self: Draft) bool {
        return self == .range;
    }

    pub fn direction(self: Draft, cursor: usize) ?Direction {
        const anchor_index = self.anchor() orelse return null;
        if (cursor < anchor_index) return .toward_newer;
        if (cursor > anchor_index) return .toward_older;
        return .at_anchor;
    }

    pub fn span(self: Draft, cursor: usize) ?Span {
        const anchor_index = self.anchor() orelse return null;
        return .{
            .newest = @min(anchor_index, cursor),
            .oldest = @max(anchor_index, cursor),
        };
    }

    pub fn contains(self: Draft, cursor: usize, index: usize) bool {
        const selected = self.span(cursor) orelse return false;
        return index >= selected.newest and index <= selected.oldest;
    }
};

test "History draft derives normalized range and direction across its anchor" {
    var draft: Draft = .single;
    try std.testing.expect(draft.anchor() == null);
    draft.toggleAnchor(3);
    try std.testing.expectEqual(@as(?usize, 3), draft.anchor());
    try std.testing.expectEqual(Direction.at_anchor, draft.direction(3).?);
    try std.testing.expectEqual(Direction.toward_newer, draft.direction(1).?);
    try std.testing.expectEqual(Direction.toward_older, draft.direction(5).?);
    try std.testing.expectEqualDeep(Span{ .newest = 1, .oldest = 3 }, draft.span(1).?);
    try std.testing.expectEqualDeep(Span{ .newest = 3, .oldest = 5 }, draft.span(5).?);
    try std.testing.expect(draft.contains(5, 4));
    try std.testing.expect(!draft.contains(5, 2));
    draft.toggleAnchor(5);
    try std.testing.expect(!draft.isRange());
    draft.toggleAnchor(3);
    try std.testing.expect(draft.clearAnchor());
    try std.testing.expect(!draft.clearAnchor());
}
