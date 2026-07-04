const std = @import("std");
const ui = @import("chasen_ui");
const repo_discovery = @import("../repo/discovery.zig");
const text_edit = @import("text_edit.zig");

/// Fixed-capacity UTF-8 text input used by prompt-like modes.
///
/// The app owns mode-specific behavior such as submit/cancel. This type only
/// owns the byte buffer and keeps insertion/backspace UTF-8 aware.
pub const TextInput = text_edit.BoundedTextInput(512);

/// Larger fixed-capacity input for filesystem paths.
///
/// Repository paths can easily exceed the short prompt buffer used for search
/// queries. Keep this fixed-capacity for now so prompt state stays self-owned
/// and simple to reset, while still reporting overflow explicitly.
pub const PathInput = text_edit.BoundedTextInput(1024);

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

pub fn repoPickerPathErrorFromDiscovery(err: repo_discovery.PathDiscoveryError) RepoPickerPathError {
    return switch (err) {
        error.PathDoesNotExist => .path_does_not_exist,
        error.PathIsNotDirectory => .path_is_not_directory,
        error.CannotAccessPath => .cannot_access_path,
        error.NoGitRepositoriesFound => .no_git_repositories_found,
        else => .cannot_access_path,
    };
}

pub const RepoPickerState = struct {
    mode: bool = false,
    input_mode: RepoPickerInputMode = .list,
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

pub const RepoPickerInputMode = enum {
    list,
    filter,
    path_input,
};

test "PathInput accepts longer paths than TextInput" {
    var input: PathInput = .{};

    var index: usize = 0;
    while (index < 256) : (index += 1) try input.insert('a');

    try std.testing.expectEqual(@as(usize, 256), input.slice().len);
}

test "PathInput edits at the cursor" {
    var input: PathInput = .{};

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

test "PathInput inserts slices and preserves state on overflow" {
    var input: PathInput = .{};

    try input.insertSlice("/tmp/giframe");
    input.moveLeft();
    input.moveLeft();
    input.moveLeft();
    input.moveLeft();
    input.moveLeft();
    try input.insertSlice("t");
    try std.testing.expectEqualStrings("/tmp/gitframe", input.slice());

    @memset(input.buffer[0..], 'x');
    input.len = input.buffer.len - 1;
    input.cursor = 2;
    const before = input;
    try std.testing.expectError(error.BufferFull, input.insertSlice("yy"));
    try std.testing.expectEqual(before.len, input.len);
    try std.testing.expectEqual(before.cursor, input.cursor);
    try std.testing.expectEqualSlices(u8, before.buffer[0..before.len], input.buffer[0..input.len]);
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
