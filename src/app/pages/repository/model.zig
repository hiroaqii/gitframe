//! Repository-local viewer, prompt, and source-coordinate state.

const std = @import("std");
const prompt = @import("../../prompt.zig");
const source = @import("../../../repository/source.zig");

pub const max_file_search_matches: usize = 512;

pub const Focus = enum { tree, source };

pub const ViewerState = struct {
    focus: Focus = .tree,
    /// Optional user preference. Effective width is always clamped against the
    /// current terminal while the preference survives compatible reloads and
    /// physical repository replacement as page UI state.
    tree_width: ?u16 = null,
    tree_cursor: usize = 0,
    tree_vertical_scroll: usize = 0,
    tree_horizontal_scroll: usize = 0,
    source_cursor: usize = 0,
    source_vertical_scroll: usize = 0,
    source_horizontal_scroll: usize = 0,
    line_numbers: bool = true,

    pub fn resetSource(self: *ViewerState) void {
        self.source_cursor = 0;
        self.source_vertical_scroll = 0;
        self.source_horizontal_scroll = 0;
    }
};

pub const SourceSearchState = struct {
    mode: bool = false,
    input: prompt.TextInput = .{},
    query: prompt.TextInput = .{},
    match: ?source.Match = null,

    pub fn clear(self: *SourceSearchState) void {
        self.* = .{};
    }
};

pub const FileSearchState = struct {
    mode: bool = false,
    input: prompt.TextInput = .{},
    matches: [max_file_search_matches]usize = undefined,
    len: usize = 0,
    focused: usize = 0,
    truncated: bool = false,
    no_match: bool = false,

    pub fn resetResults(self: *FileSearchState) void {
        self.len = 0;
        self.focused = 0;
        self.truncated = false;
        self.no_match = false;
    }

    pub fn move(self: *FileSearchState, delta: isize) void {
        if (self.len == 0) return;
        if (delta < 0) self.focused -|= @intCast(-delta) else self.focused = @min(self.focused +| @as(usize, @intCast(delta)), self.len - 1);
    }

    pub fn selectedNode(self: *const FileSearchState) ?usize {
        if (self.len == 0 or self.focused >= self.len) return null;
        return self.matches[self.focused];
    }

    pub fn close(self: *FileSearchState) void {
        self.* = .{};
    }
};

test "repository file search state clamps focus and reports selected node" {
    var state: FileSearchState = .{};
    state.matches[0] = 4;
    state.matches[1] = 9;
    state.len = 2;
    state.move(10);
    try std.testing.expectEqual(@as(usize, 9), state.selectedNode().?);
    state.move(-10);
    try std.testing.expectEqual(@as(usize, 4), state.selectedNode().?);
}
