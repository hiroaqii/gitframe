const std = @import("std");
const prompt = @import("prompt.zig");

pub const CommitError = enum {
    subject_empty,
    subject_too_long,
    body_too_long,
    no_staged_changes,
    status_loading,
    status_unavailable,
    action_pending,

    pub fn message(self: CommitError) []const u8 {
        return switch (self) {
            .subject_empty => "Commit subject is empty",
            .subject_too_long => "Commit subject is too long",
            .body_too_long => "Commit body is too long",
            .no_staged_changes => "No staged changes",
            .status_loading => "Status is still loading",
            .status_unavailable => "Status is unavailable",
            .action_pending => "Another git action is running",
        };
    }
};

pub const Field = enum {
    subject,
    body,
};

pub const max_body_bytes = 4096;
pub const max_body_lines = 32;

/// Minimal app-local multiline buffer for the commit body.
///
/// This intentionally keeps only append/backspace behavior for the first
/// commit-panel slice; cursor movement and scrolling can be added when the
/// commit workflow needs them.
pub const BodyText = struct {
    pub const InsertError = error{BufferFull};

    buffer: [max_body_bytes]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const BodyText) []const u8 {
        return self.buffer[0..self.len];
    }

    pub fn insert(self: *BodyText, codepoint: u21) InsertError!void {
        var bytes: [4]u8 = undefined;
        const written = std.unicode.utf8Encode(codepoint, &bytes) catch unreachable;
        if (self.len + written > self.buffer.len) return error.BufferFull;
        @memcpy(self.buffer[self.len .. self.len + written], bytes[0..written]);
        self.len += written;
    }

    pub fn newline(self: *BodyText) InsertError!void {
        if (self.lineCount() >= max_body_lines) return error.BufferFull;
        try self.insert('\n');
    }

    pub fn backspace(self: *BodyText) void {
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

    pub fn lineCount(self: *const BodyText) usize {
        if (self.len == 0) return 1;
        var count: usize = 1;
        for (self.slice()) |byte| {
            if (byte == '\n') count += 1;
        }
        return count;
    }

    pub fn lineAt(self: *const BodyText, target_index: usize) ?[]const u8 {
        var start: usize = 0;
        var index: usize = 0;
        const text = self.slice();
        for (text, 0..) |byte, offset| {
            if (byte != '\n') continue;
            if (index == target_index) return text[start..offset];
            start = offset + 1;
            index += 1;
        }
        if (index == target_index) return text[start..];
        return null;
    }

    pub fn clear(self: *BodyText) void {
        self.len = 0;
    }
};

test "State validates commit message and staged summary" {
    var state: State = .{};

    try std.testing.expectEqual(CommitError.subject_empty, state.validateSubmit(.{ .ready = .{ .count = 1 } }).?);

    state.insert('x');
    try std.testing.expectEqual(CommitError.no_staged_changes, state.validateSubmit(.{ .ready = .{ .count = 0 } }).?);
    try std.testing.expectEqual(CommitError.status_loading, state.validateSubmit(.loading_or_stale).?);
    try std.testing.expectEqual(CommitError.status_unavailable, state.validateSubmit(.unavailable).?);
    try std.testing.expect(state.validateSubmit(.{ .ready = .{ .count = 1 } }) == null);
}

test "State reports input overflow as panel error" {
    var state: State = .{};

    var index: usize = 0;
    while (index < state.subject.buffer.len) : (index += 1) state.insert('x');
    state.insert('y');

    try std.testing.expectEqual(CommitError.subject_too_long, state.commit_error.?);
    try std.testing.expectEqual(CommitError.subject_too_long, state.validateSubmit(.{ .ready = .{ .count = 1 } }).?);
    state.backspace();
    try std.testing.expect(state.commit_error == null);

    state.active_field = .body;
    index = 0;
    while (index < state.body.buffer.len) : (index += 1) state.insert('x');
    state.insert('y');

    try std.testing.expectEqual(CommitError.body_too_long, state.commit_error.?);
    try std.testing.expectEqual(CommitError.body_too_long, state.validateSubmit(.{ .ready = .{ .count = 1 } }).?);
}

test "State routes enter and body text" {
    var state: State = .{};

    try state.subject.insert('s');
    state.enter();
    try std.testing.expectEqual(Field.body, state.active_field);

    state.insert('b');
    state.enter();
    state.insert('c');
    try std.testing.expectEqualStrings("b\nc", state.body.slice());

    state.backspace();
    try std.testing.expectEqualStrings("b\n", state.body.slice());
}

test "State formats commit message payload" {
    var state: State = .{};
    try state.subject.insert(' ');
    try state.subject.insert('s');
    try state.subject.insert(' ');

    const subject_only = try state.formatMessage(std.testing.allocator);
    defer std.testing.allocator.free(subject_only);
    try std.testing.expectEqualStrings("s", subject_only);

    state.active_field = .body;
    state.insert('b');
    state.enter();
    state.insert('c');

    const with_body = try state.formatMessage(std.testing.allocator);
    defer std.testing.allocator.free(with_body);
    try std.testing.expectEqualStrings("s\n\nb\nc", with_body);
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
    active_field: Field = .subject,
    subject: prompt.TextInput = .{},
    body: BodyText = .{},
    commit_error: ?CommitError = null,

    pub fn open(self: *State) void {
        self.mode = true;
        self.commit_error = null;
    }

    pub fn close(self: *State) void {
        self.* = .{};
    }

    pub fn insert(self: *State, codepoint: u21) void {
        switch (self.active_field) {
            .subject => self.subject.insert(codepoint) catch {
                self.commit_error = .subject_too_long;
                return;
            },
            .body => self.body.insert(codepoint) catch {
                self.commit_error = .body_too_long;
                return;
            },
        }
        self.commit_error = null;
    }

    pub fn enter(self: *State) void {
        switch (self.active_field) {
            .subject => {
                self.active_field = .body;
                self.commit_error = null;
            },
            .body => {
                self.body.newline() catch {
                    self.commit_error = .body_too_long;
                    return;
                };
                self.commit_error = null;
            },
        }
    }

    pub fn toggleField(self: *State) void {
        self.active_field = switch (self.active_field) {
            .subject => .body,
            .body => .subject,
        };
        self.commit_error = null;
    }

    pub fn backspace(self: *State) void {
        switch (self.active_field) {
            .subject => {
                self.subject.backspace();
                if (self.subject.len < self.subject.buffer.len) self.commit_error = null;
            },
            .body => {
                self.body.backspace();
                if (self.body.len < self.body.buffer.len) self.commit_error = null;
            },
        }
    }

    pub fn validateSubmit(self: *const State, summary: StagedSummary) ?CommitError {
        if (self.commit_error) |err| {
            switch (err) {
                .subject_too_long, .body_too_long => return err,
                else => {},
            }
        }
        if (trimmedSubject(self).len == 0) return .subject_empty;
        return switch (summary) {
            .ready => |ready| if (ready.count == 0) .no_staged_changes else null,
            .loading_or_stale => .status_loading,
            .unavailable => .status_unavailable,
        };
    }

    /// Build the payload expected by `git commit`: subject only, or
    /// `subject\n\nbody` when the body has meaningful content.
    pub fn formatMessage(self: *const State, allocator: std.mem.Allocator) ![]u8 {
        const subject = trimmedSubject(self);
        const body = std.mem.trim(u8, self.body.slice(), " \t\r\n");
        if (body.len == 0) return allocator.dupe(u8, subject);
        return std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ subject, body });
    }

    fn trimmedSubject(self: *const State) []const u8 {
        return std.mem.trim(u8, self.subject.slice(), " \t\r\n");
    }
};
