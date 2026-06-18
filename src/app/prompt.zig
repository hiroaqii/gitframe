const std = @import("std");
const ui = @import("chasen_ui");

/// Fixed-capacity UTF-8 text input used by prompt-like modes.
///
/// The app owns mode-specific behavior such as submit/cancel. This type only
/// owns the byte buffer and keeps insertion/backspace UTF-8 aware.
pub const TextInput = struct {
    pub const InsertError = error{BufferFull};

    buffer: [128]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const TextInput) []const u8 {
        return self.buffer[0..self.len];
    }

    pub fn insert(self: *TextInput, codepoint: u21) InsertError!void {
        var bytes: [4]u8 = undefined;
        const written = std.unicode.utf8Encode(codepoint, &bytes) catch unreachable;
        if (self.len + written > self.buffer.len) return error.BufferFull;
        @memcpy(self.buffer[self.len .. self.len + written], bytes[0..written]);
        self.len += written;
    }

    pub fn backspace(self: *TextInput) void {
        if (self.len == 0) return;
        var view = std.unicode.Utf8View.initUnchecked(self.slice());
        var iterator = view.iterator();
        var previous_end: usize = 0;
        while (iterator.nextCodepointSlice()) |bytes| {
            const end = @intFromPtr(bytes.ptr) - @intFromPtr(self.buffer[0..].ptr) + bytes.len;
            if (end >= self.len) break;
            previous_end = end;
        }
        self.len = previous_end;
    }

    pub fn clear(self: *TextInput) void {
        self.len = 0;
    }
};

/// List-filter prompt state shared by file search and repository picker.
///
/// This intentionally does not model diff search: diff search has committed
/// query and match-coordinate state, while list prompts own a ListFilter.
pub const FilterPromptState = struct {
    mode: bool = false,
    input: TextInput = .{},
    /// Owns filtered indexes while labels are borrowed from the active source.
    filter: ui.ListFilter = .{},
    no_match: bool = false,

    pub fn resetNoMatch(self: *FilterPromptState) void {
        self.no_match = false;
    }

    /// Release transient filter results while keeping the prompt text and mode.
    pub fn clearFilter(self: *FilterPromptState, allocator: std.mem.Allocator) void {
        self.filter.deinit(allocator);
        self.filter = .{};
    }

    pub fn deinit(self: *FilterPromptState, allocator: std.mem.Allocator) void {
        self.clearFilter(allocator);
        self.* = .{};
    }
};

test "TextInput inserts UTF-8 codepoints and backspaces by codepoint" {
    var input: TextInput = .{};

    try input.insert('a');
    try input.insert(0x1F408);
    try std.testing.expectEqualStrings("a🐈", input.slice());

    input.backspace();
    try std.testing.expectEqualStrings("a", input.slice());

    input.backspace();
    try std.testing.expectEqualStrings("", input.slice());
}

test "TextInput reports BufferFull without changing existing bytes" {
    var input: TextInput = .{};
    @memset(input.buffer[0..], 'x');
    input.len = input.buffer.len;

    try std.testing.expectError(error.BufferFull, input.insert('y'));
    try std.testing.expectEqual(@as(usize, input.buffer.len), input.len);
    try std.testing.expectEqual(@as(u8, 'x'), input.buffer[0]);
}

test "FilterPromptState deinit resets reusable prompt state" {
    var state: FilterPromptState = .{
        .mode = true,
        .no_match = true,
    };
    try state.input.insert('x');

    state.deinit(std.testing.allocator);

    try std.testing.expect(!state.mode);
    try std.testing.expect(!state.no_match);
    try std.testing.expectEqual(@as(usize, 0), state.input.len);
}
