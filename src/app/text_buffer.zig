const std = @import("std");

/// App-local UTF-8 text storage for editable fields.
///
/// Cursor positions are byte offsets into `bytes.items`. Movement helpers keep
/// those offsets on UTF-8 codepoint boundaries; grapheme-level movement is
/// intentionally left for a later input-polish slice.
pub const TextBuffer = struct {
    pub const InsertError = error{OutOfMemory};

    bytes: std.ArrayListUnmanaged(u8) = .empty,
    cursor: usize = 0,

    pub fn slice(self: *const TextBuffer) []const u8 {
        return self.bytes.items;
    }

    pub fn insert(self: *TextBuffer, allocator: std.mem.Allocator, codepoint: u21) InsertError!void {
        var encoded: [4]u8 = undefined;
        const written = std.unicode.utf8Encode(codepoint, &encoded) catch unreachable;

        try self.bytes.ensureUnusedCapacity(allocator, written);
        const old_len = self.bytes.items.len;
        self.bytes.items.len += written;
        std.mem.copyBackwards(u8, self.bytes.items[self.cursor + written .. old_len + written], self.bytes.items[self.cursor..old_len]);
        @memcpy(self.bytes.items[self.cursor .. self.cursor + written], encoded[0..written]);
        self.cursor += written;
    }

    pub fn backspace(self: *TextBuffer) void {
        if (self.cursor == 0) return;

        const previous = previousBoundary(self.slice(), self.cursor);
        std.mem.copyForwards(u8, self.bytes.items[previous .. self.bytes.items.len - (self.cursor - previous)], self.bytes.items[self.cursor..]);
        self.bytes.items.len -= self.cursor - previous;
        self.cursor = previous;
    }

    pub fn moveLeft(self: *TextBuffer) void {
        self.cursor = previousBoundary(self.slice(), self.cursor);
    }

    pub fn moveRight(self: *TextBuffer) void {
        self.cursor = nextBoundary(self.slice(), self.cursor);
    }

    pub fn clearRetainingCapacity(self: *TextBuffer) void {
        self.bytes.clearRetainingCapacity();
        self.cursor = 0;
    }

    pub fn deinit(self: *TextBuffer, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
        self.* = .{};
    }
};

pub fn previousBoundary(bytes: []const u8, cursor: usize) usize {
    if (cursor == 0) return 0;

    var previous: usize = 0;
    var iter = std.unicode.Utf8View.initUnchecked(bytes).iterator();
    while (iter.nextCodepointSlice()) |codepoint| {
        const end = @intFromPtr(codepoint.ptr) - @intFromPtr(bytes.ptr) + codepoint.len;
        if (end >= cursor) return previous;
        previous = end;
    }
    return previous;
}

pub fn nextBoundary(bytes: []const u8, cursor: usize) usize {
    if (cursor >= bytes.len) return bytes.len;

    var iter = std.unicode.Utf8View.initUnchecked(bytes).iterator();
    while (iter.nextCodepointSlice()) |codepoint| {
        const start = @intFromPtr(codepoint.ptr) - @intFromPtr(bytes.ptr);
        const end = start + codepoint.len;
        if (start >= cursor or cursor < end) return end;
    }
    return bytes.len;
}

test "TextBuffer edits at the cursor and preserves UTF-8 boundaries" {
    var buffer: TextBuffer = .{};
    defer buffer.deinit(std.testing.allocator);

    try buffer.insert(std.testing.allocator, 'a');
    try buffer.insert(std.testing.allocator, 0x1F408);
    try buffer.insert(std.testing.allocator, 'c');
    buffer.moveLeft();
    try buffer.insert(std.testing.allocator, 'b');

    try std.testing.expectEqualStrings("a🐈bc", buffer.slice());

    buffer.backspace();
    try std.testing.expectEqualStrings("a🐈c", buffer.slice());
}

test "TextBuffer clear retains reusable allocation" {
    var buffer: TextBuffer = .{};
    defer buffer.deinit(std.testing.allocator);

    try buffer.insert(std.testing.allocator, 'x');
    const capacity = buffer.bytes.capacity;
    buffer.clearRetainingCapacity();

    try std.testing.expectEqual(@as(usize, 0), buffer.slice().len);
    try std.testing.expectEqual(@as(usize, 0), buffer.cursor);
    try std.testing.expect(buffer.bytes.capacity >= capacity);

    try buffer.insert(std.testing.allocator, 'y');
    try std.testing.expectEqualStrings("y", buffer.slice());
}
