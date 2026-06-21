const std = @import("std");
const prompt = @import("prompt.zig");

pub const CommitError = enum {
    message_empty,
    message_too_long,
    no_staged_changes,
    status_loading,
    status_unavailable,
    action_pending,

    pub fn message(self: CommitError) []const u8 {
        return switch (self) {
            .message_empty => "Commit message is empty",
            .message_too_long => "Commit message is too long",
            .no_staged_changes => "No staged changes",
            .status_loading => "Status is still loading",
            .status_unavailable => "Status is unavailable",
            .action_pending => "Another git action is running",
        };
    }
};

test "State validates commit message and staged summary" {
    var state: State = .{};

    try std.testing.expectEqual(CommitError.message_empty, state.validateSubmit(.{ .ready = .{ .count = 1 } }).?);

    state.insert('x');
    try std.testing.expectEqual(CommitError.no_staged_changes, state.validateSubmit(.{ .ready = .{ .count = 0 } }).?);
    try std.testing.expectEqual(CommitError.status_loading, state.validateSubmit(.loading_or_stale).?);
    try std.testing.expectEqual(CommitError.status_unavailable, state.validateSubmit(.unavailable).?);
    try std.testing.expect(state.validateSubmit(.{ .ready = .{ .count = 1 } }) == null);
}

test "State reports input overflow as panel error" {
    var state: State = .{};

    var index: usize = 0;
    while (index < state.message.buffer.len) : (index += 1) state.insert('x');
    state.insert('y');

    try std.testing.expectEqual(CommitError.message_too_long, state.commit_error.?);
    state.backspace();
    try std.testing.expect(state.commit_error == null);
}

pub const StagedSummary = union(enum) {
    ready: struct {
        count: usize,
    },
    loading_or_stale,
    unavailable,
};

/// Self-owned state for the review-screen commit popup.
///
/// The foundation slice only validates local input and staged status. Running
/// `git commit` is intentionally left to a later action slice.
pub const State = struct {
    mode: bool = false,
    message: prompt.TextInput = .{},
    commit_error: ?CommitError = null,

    pub fn open(self: *State) void {
        self.mode = true;
        self.commit_error = null;
    }

    pub fn close(self: *State) void {
        self.* = .{};
    }

    pub fn insert(self: *State, codepoint: u21) void {
        self.message.insert(codepoint) catch {
            self.commit_error = .message_too_long;
            return;
        };
        self.commit_error = null;
    }

    pub fn backspace(self: *State) void {
        self.message.backspace();
        if (self.message.len < self.message.buffer.len) self.commit_error = null;
    }

    pub fn validateSubmit(self: *const State, summary: StagedSummary) ?CommitError {
        if (self.message.len == 0) return .message_empty;
        return switch (summary) {
            .ready => |ready| if (ready.count == 0) .no_staged_changes else null,
            .loading_or_stale => .status_loading,
            .unavailable => .status_unavailable,
        };
    }
};
