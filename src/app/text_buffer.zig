const std = @import("std");
const text_edit = @import("text_edit.zig");

/// App-local UTF-8 text storage for editable fields.
///
/// Cursor positions are byte offsets into `bytes.items`. Movement helpers keep
/// those offsets on UTF-8 codepoint boundaries. Grapheme-level movement is not
/// implemented.
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

    pub fn insertSlice(self: *TextBuffer, allocator: std.mem.Allocator, text: []const u8) InsertError!void {
        if (text.len == 0) return;
        std.debug.assert(std.unicode.utf8ValidateSlice(text));

        try self.bytes.ensureUnusedCapacity(allocator, text.len);
        const old_len = self.bytes.items.len;
        self.bytes.items.len += text.len;
        std.mem.copyBackwards(u8, self.bytes.items[self.cursor + text.len .. old_len + text.len], self.bytes.items[self.cursor..old_len]);
        @memcpy(self.bytes.items[self.cursor .. self.cursor + text.len], text);
        self.cursor += text.len;
    }

    pub fn backspace(self: *TextBuffer) void {
        if (self.cursor == 0) return;

        const previous = text_edit.previousBoundary(self.slice(), self.cursor);
        std.mem.copyForwards(u8, self.bytes.items[previous .. self.bytes.items.len - (self.cursor - previous)], self.bytes.items[self.cursor..]);
        self.bytes.items.len -= self.cursor - previous;
        self.cursor = previous;
    }

    pub fn moveLeft(self: *TextBuffer) void {
        self.cursor = text_edit.previousBoundary(self.slice(), self.cursor);
    }

    pub fn moveRight(self: *TextBuffer) void {
        self.cursor = text_edit.nextBoundary(self.slice(), self.cursor);
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

test "TextBuffer inserts slices at the cursor" {
    var buffer: TextBuffer = .{};
    defer buffer.deinit(std.testing.allocator);

    try buffer.insertSlice(std.testing.allocator, "ac");
    buffer.moveLeft();
    try buffer.insertSlice(std.testing.allocator, "🐈b");

    try std.testing.expectEqualStrings("a🐈bc", buffer.slice());
    try std.testing.expectEqual(@as(usize, "a🐈b".len), buffer.cursor);
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
