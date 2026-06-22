const std = @import("std");
const ui = @import("chasen_ui");

/// Fixed-capacity UTF-8 text input used by prompt-like modes.
///
/// The app owns mode-specific behavior such as submit/cancel. This type only
/// owns the byte buffer and keeps insertion/backspace UTF-8 aware.
pub const TextInput = struct {
    pub const InsertError = error{BufferFull};

    buffer: [512]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,

    pub fn slice(self: *const TextInput) []const u8 {
        return self.buffer[0..self.len];
    }

    pub fn insert(self: *TextInput, codepoint: u21) InsertError!void {
        var bytes: [4]u8 = undefined;
        const written = std.unicode.utf8Encode(codepoint, &bytes) catch unreachable;
        if (self.len + written > self.buffer.len) return error.BufferFull;
        std.mem.copyBackwards(u8, self.buffer[self.cursor + written .. self.len + written], self.buffer[self.cursor..self.len]);
        @memcpy(self.buffer[self.cursor .. self.cursor + written], bytes[0..written]);
        self.len += written;
        self.cursor += written;
    }

    pub fn backspace(self: *TextInput) void {
        if (self.cursor == 0) return;
        const previous = previousBoundary(self.slice(), self.cursor);
        std.mem.copyForwards(u8, self.buffer[previous .. self.len - (self.cursor - previous)], self.buffer[self.cursor..self.len]);
        self.len -= self.cursor - previous;
        self.cursor = previous;
    }

    pub fn moveLeft(self: *TextInput) void {
        self.cursor = previousBoundary(self.slice(), self.cursor);
    }

    pub fn moveRight(self: *TextInput) void {
        self.cursor = nextBoundary(self.slice(), self.cursor);
    }

    pub fn clear(self: *TextInput) void {
        self.* = .{};
    }
};

/// Larger fixed-capacity input for filesystem paths.
///
/// Repository paths can easily exceed the short prompt buffer used for search
/// queries. Keep this fixed-capacity for now so prompt state stays self-owned
/// and simple to reset, while still reporting overflow explicitly.
pub const PathInput = struct {
    pub const InsertError = error{BufferFull};

    buffer: [1024]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const PathInput) []const u8 {
        return self.buffer[0..self.len];
    }

    pub fn insert(self: *PathInput, codepoint: u21) InsertError!void {
        var bytes: [4]u8 = undefined;
        const written = std.unicode.utf8Encode(codepoint, &bytes) catch unreachable;
        if (self.len + written > self.buffer.len) return error.BufferFull;
        @memcpy(self.buffer[self.len .. self.len + written], bytes[0..written]);
        self.len += written;
    }

    pub fn backspace(self: *PathInput) void {
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

    pub fn clear(self: *PathInput) void {
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

pub const RepoPickerMode = enum {
    list,
    path_input,
};

pub const RepoPickerPathError = enum {
    path_does_not_exist,
    path_is_not_directory,
    cannot_access_path,
    no_git_repositories_found,
    path_too_long,

    pub fn message(self: RepoPickerPathError) []const u8 {
        return switch (self) {
            .path_does_not_exist => "Path does not exist",
            .path_is_not_directory => "Path is not a directory",
            .cannot_access_path => "Cannot access path",
            .no_git_repositories_found => "No Git repositories found",
            .path_too_long => "Path is too long",
        };
    }
};

pub const RepoPickerState = struct {
    mode: bool = false,
    prompt_mode: RepoPickerMode = .list,
    list: FilterPromptState = .{},
    path_input: PathInput = .{},
    path_error: ?RepoPickerPathError = null,
    path_pending: bool = false,
    path_generation: u64 = 0,

    pub fn deinit(self: *RepoPickerState, allocator: std.mem.Allocator) void {
        const next_generation = self.path_generation +% 1;
        self.list.deinit(allocator);
        self.* = .{ .path_generation = next_generation };
    }

    pub fn clearPathStatus(self: *RepoPickerState) void {
        self.path_error = null;
    }

    pub fn invalidatePathDiscovery(self: *RepoPickerState) void {
        self.path_generation +%= 1;
        self.path_pending = false;
        self.path_error = null;
    }

    pub fn beginPathDiscovery(self: *RepoPickerState) u64 {
        self.path_generation +%= 1;
        self.path_pending = true;
        self.path_error = null;
        return self.path_generation;
    }

    pub fn finishPathDiscovery(self: *RepoPickerState, generation: u64) bool {
        if (!self.path_pending or self.path_generation != generation) return false;
        self.path_pending = false;
        return true;
    }

    pub fn isCurrentPathDiscovery(self: *const RepoPickerState, generation: u64) bool {
        return self.path_generation == generation;
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

test "TextInput edits at the cursor" {
    var input: TextInput = .{};

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

test "TextInput reports BufferFull without changing existing bytes" {
    var input: TextInput = .{};
    @memset(input.buffer[0..], 'x');
    input.len = input.buffer.len;
    input.cursor = input.len;

    try std.testing.expectError(error.BufferFull, input.insert('y'));
    try std.testing.expectEqual(@as(usize, input.buffer.len), input.len);
    try std.testing.expectEqual(@as(u8, 'x'), input.buffer[0]);
}

test "PathInput accepts longer paths than TextInput" {
    var input: PathInput = .{};

    var index: usize = 0;
    while (index < 256) : (index += 1) try input.insert('a');

    try std.testing.expectEqual(@as(usize, 256), input.slice().len);
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

test "RepoPickerState tracks path discovery generation" {
    var state: RepoPickerState = .{};

    const generation = state.beginPathDiscovery();
    try std.testing.expect(state.path_pending);
    try std.testing.expect(state.isCurrentPathDiscovery(generation));
    try std.testing.expect(state.finishPathDiscovery(generation));
    try std.testing.expect(!state.path_pending);
}

fn previousBoundary(bytes: []const u8, cursor: usize) usize {
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

fn nextBoundary(bytes: []const u8, cursor: usize) usize {
    if (cursor >= bytes.len) return bytes.len;

    var iter = std.unicode.Utf8View.initUnchecked(bytes).iterator();
    while (iter.nextCodepointSlice()) |codepoint| {
        const start = @intFromPtr(codepoint.ptr) - @intFromPtr(bytes.ptr);
        const end = start + codepoint.len;
        if (start >= cursor or cursor < end) return end;
    }
    return bytes.len;
}
