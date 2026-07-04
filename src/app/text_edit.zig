const std = @import("std");

pub fn utf8Len(codepoint: u21) usize {
    var bytes: [4]u8 = undefined;
    return std.unicode.utf8Encode(codepoint, &bytes) catch unreachable;
}

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

pub fn BoundedTextInput(comptime capacity: usize) type {
    return struct {
        pub const InsertError = error{BufferFull};

        const Self = @This();

        buffer: [capacity]u8 = undefined,
        len: usize = 0,
        cursor: usize = 0,

        pub fn slice(self: *const Self) []const u8 {
            return self.buffer[0..self.len];
        }

        pub fn insert(self: *Self, codepoint: u21) InsertError!void {
            var bytes: [4]u8 = undefined;
            const written = std.unicode.utf8Encode(codepoint, &bytes) catch unreachable;
            try self.insertSlice(bytes[0..written]);
        }

        pub fn insertSlice(self: *Self, text: []const u8) InsertError!void {
            if (text.len == 0) return;
            std.debug.assert(std.unicode.utf8ValidateSlice(text));
            if (self.len + text.len > self.buffer.len) return error.BufferFull;
            std.mem.copyBackwards(u8, self.buffer[self.cursor + text.len .. self.len + text.len], self.buffer[self.cursor..self.len]);
            @memcpy(self.buffer[self.cursor .. self.cursor + text.len], text);
            self.len += text.len;
            self.cursor += text.len;
        }

        pub fn backspace(self: *Self) void {
            if (self.cursor == 0) return;
            const previous = previousBoundary(self.slice(), self.cursor);
            std.mem.copyForwards(u8, self.buffer[previous .. self.len - (self.cursor - previous)], self.buffer[self.cursor..self.len]);
            self.len -= self.cursor - previous;
            self.cursor = previous;
        }

        pub fn moveLeft(self: *Self) void {
            self.cursor = previousBoundary(self.slice(), self.cursor);
        }

        pub fn moveRight(self: *Self) void {
            self.cursor = nextBoundary(self.slice(), self.cursor);
        }

        pub fn clear(self: *Self) void {
            self.* = .{};
        }
    };
}

test "BoundedTextInput inserts UTF-8 codepoints and backspaces by codepoint" {
    const Input = BoundedTextInput(512);
    var input: Input = .{};

    try input.insert('a');
    try input.insert(0x1F408);
    try std.testing.expectEqualStrings("a🐈", input.slice());

    input.backspace();
    try std.testing.expectEqualStrings("a", input.slice());

    input.backspace();
    try std.testing.expectEqualStrings("", input.slice());
}

test "BoundedTextInput edits at the cursor" {
    const Input = BoundedTextInput(512);
    var input: Input = .{};

    try input.insert('a');
    try input.insert('c');
    input.moveLeft();
    try input.insert('b');

    try std.testing.expectEqualStrings("abc", input.slice());
    try std.testing.expectEqual(@as(usize, 2), input.cursor);

    input.backspace();
    try std.testing.expectEqualStrings("ac", input.slice());
    try std.testing.expectEqual(@as(usize, 1), input.cursor);
}

test "BoundedTextInput inserts slices at the cursor" {
    const Input = BoundedTextInput(512);
    var input: Input = .{};

    try input.insertSlice("ac");
    input.moveLeft();
    try input.insertSlice("🐈b");

    try std.testing.expectEqualStrings("a🐈bc", input.slice());
    try std.testing.expectEqual(@as(usize, "a🐈b".len), input.cursor);
}

test "BoundedTextInput reports BufferFull without changing existing bytes" {
    const Input = BoundedTextInput(4);
    var input: Input = .{};
    @memset(input.buffer[0..], 'x');
    input.len = input.buffer.len;
    input.cursor = input.len;

    try std.testing.expectError(error.BufferFull, input.insert('y'));
    try std.testing.expectEqual(@as(usize, input.buffer.len), input.len);
    try std.testing.expectEqual(@as(u8, 'x'), input.buffer[0]);
}

test "BoundedTextInput reports BufferFull for slices without changing state" {
    const Input = BoundedTextInput(4);
    var input: Input = .{};
    @memset(input.buffer[0..], 'x');
    input.len = input.buffer.len - 1;
    input.cursor = 1;
    const before = input;

    try std.testing.expectError(error.BufferFull, input.insertSlice("yy"));
    try std.testing.expectEqual(before.len, input.len);
    try std.testing.expectEqual(before.cursor, input.cursor);
    try std.testing.expectEqualSlices(u8, before.buffer[0..before.len], input.buffer[0..input.len]);
}
