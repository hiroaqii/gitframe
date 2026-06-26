const std = @import("std");
const chasen = @import("chasen");
const text_buffer = @import("text_buffer.zig");

pub const CommitError = enum {
    subject_empty,
    subject_too_long,
    message_too_large,
    input_allocation_failed,
    no_staged_changes,
    status_loading,
    status_unavailable,
    action_pending,
    commit_failed,
    amend_failed,

    pub fn message(self: CommitError) []const u8 {
        return switch (self) {
            .subject_empty => "Commit subject is empty",
            .subject_too_long => "Commit subject is too long",
            .message_too_large => "Commit message is too large",
            .input_allocation_failed => "Could not grow commit message buffer",
            .no_staged_changes => "No staged changes",
            .status_loading => "Status is still loading",
            .status_unavailable => "Status is unavailable",
            .action_pending => "Another git action is running",
            .commit_failed => "Commit failed",
            .amend_failed => "Amend failed",
        };
    }
};

pub const Mode = enum {
    commit,
    amend,
};

pub const Field = enum {
    subject,
    body,
};

pub const max_subject_chars = 72;
pub const max_message_bytes = 64 * 1024;

pub const MessageParts = struct {
    subject: []u8,
    body: ?[]u8 = null,

    pub fn deinit(self: *MessageParts, allocator: std.mem.Allocator) void {
        allocator.free(self.subject);
        if (self.body) |body| allocator.free(body);
        self.* = .{ .subject = &.{} };
    }
};

/// Multiline commit body editor.
///
/// Raw bytes and the byte-offset cursor are owned by TextBuffer. This wrapper
/// keeps only the line-oriented helpers needed by body viewport rendering and
/// vertical cursor movement.
pub const BodyText = struct {
    text: text_buffer.TextBuffer = .{},

    pub fn slice(self: *const BodyText) []const u8 {
        return self.text.slice();
    }

    pub fn cursor(self: *const BodyText) usize {
        return self.text.cursor;
    }

    pub fn insert(self: *BodyText, allocator: std.mem.Allocator, codepoint: u21) text_buffer.TextBuffer.InsertError!void {
        try self.text.insert(allocator, codepoint);
    }

    pub fn newline(self: *BodyText, allocator: std.mem.Allocator) text_buffer.TextBuffer.InsertError!void {
        try self.insert(allocator, '\n');
    }

    pub fn backspace(self: *BodyText) void {
        self.text.backspace();
    }

    pub fn moveLeft(self: *BodyText) void {
        self.text.moveLeft();
    }

    pub fn moveRight(self: *BodyText) void {
        self.text.moveRight();
    }

    pub fn moveUp(self: *BodyText) void {
        const current_line = self.cursorLineIndex();
        if (current_line == 0) return;

        self.text.cursor = self.cursorForLineColumn(current_line - 1, self.cursorDisplayColumn());
    }

    pub fn moveDown(self: *BodyText) void {
        const current_line = self.cursorLineIndex();
        if (current_line + 1 >= self.lineCount()) return;

        self.text.cursor = self.cursorForLineColumn(current_line + 1, self.cursorDisplayColumn());
    }

    pub fn lineCount(self: *const BodyText) usize {
        if (self.slice().len == 0) return 1;
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

    pub fn cursorLineIndex(self: *const BodyText) usize {
        var index: usize = 0;
        for (self.slice()[0..self.text.cursor]) |byte| {
            if (byte == '\n') index += 1;
        }
        return index;
    }

    pub fn cursorLinePrefix(self: *const BodyText) []const u8 {
        const text = self.slice();
        var start: usize = 0;
        var offset: usize = 0;
        while (offset < self.text.cursor) : (offset += 1) {
            if (text[offset] == '\n') start = offset + 1;
        }
        return text[start..self.text.cursor];
    }

    pub fn cursorDisplayColumn(self: *const BodyText) u16 {
        return chasen.text.displayWidth(self.cursorLinePrefix());
    }

    pub fn clearRetainingCapacity(self: *BodyText) void {
        self.text.clearRetainingCapacity();
    }

    pub fn deinit(self: *BodyText, allocator: std.mem.Allocator) void {
        self.text.deinit(allocator);
    }

    fn cursorForLineColumn(self: *const BodyText, line_index: usize, target_column: u16) usize {
        const bounds = self.lineBounds(line_index) orelse return self.text.cursor;
        return bounds.start + offsetForDisplayColumn(self.slice()[bounds.start..bounds.end], target_column);
    }

    fn lineBounds(self: *const BodyText, target_index: usize) ?struct { start: usize, end: usize } {
        var start: usize = 0;
        var index: usize = 0;
        const text = self.slice();
        for (text, 0..) |byte, offset| {
            if (byte != '\n') continue;
            if (index == target_index) return .{ .start = start, .end = offset };
            start = offset + 1;
            index += 1;
        }
        if (index == target_index) return .{ .start = start, .end = text.len };
        return null;
    }
};

pub fn graphemeCount(text: []const u8) usize {
    var count: usize = 0;
    var iter = chasen.text.graphemeIterator(text);
    while (iter.next()) |_| count += 1;
    return count;
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
/// Text storage is allocator-backed because commit messages are variable-size
/// user input. Closing the popup clears content while retaining capacity;
/// deinit is the only operation that releases the buffers.
pub const State = struct {
    allocator: ?std.mem.Allocator = null,
    is_open: bool = false,
    mode: Mode = .commit,
    active_field: Field = .subject,
    subject: text_buffer.TextBuffer = .{},
    body: BodyText = .{},
    commit_error: ?CommitError = null,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *State) void {
        const allocator = self.allocator orelse {
            self.* = .{};
            return;
        };
        self.subject.deinit(allocator);
        self.body.deinit(allocator);
        self.* = .{};
    }

    pub fn open(self: *State, mode: Mode) void {
        self.is_open = true;
        self.mode = mode;
        self.commit_error = null;
    }

    pub fn close(self: *State) void {
        self.is_open = false;
        self.mode = .commit;
        self.active_field = .subject;
        self.subject.clearRetainingCapacity();
        self.body.clearRetainingCapacity();
        self.commit_error = null;
    }

    pub fn title(self: *const State) []const u8 {
        return switch (self.mode) {
            .commit => "Commit",
            .amend => "Amend commit",
        };
    }

    pub fn submitLabel(self: *const State) []const u8 {
        return switch (self.mode) {
            .commit => "commit",
            .amend => "amend",
        };
    }

    pub fn pendingStatusText(self: *const State) []const u8 {
        return switch (self.mode) {
            .commit => "committing...",
            .amend => "amending...",
        };
    }

    pub fn failedError(self: *const State) CommitError {
        return switch (self.mode) {
            .commit => .commit_failed,
            .amend => .amend_failed,
        };
    }

    pub fn insert(self: *State, codepoint: u21) void {
        const allocator = self.allocator orelse {
            self.commit_error = .input_allocation_failed;
            return;
        };
        if (self.totalRawBytes() + utf8Len(codepoint) > max_message_bytes) {
            self.commit_error = .message_too_large;
            return;
        }

        switch (self.active_field) {
            .subject => self.subject.insert(allocator, codepoint) catch {
                self.commit_error = .input_allocation_failed;
                return;
            },
            .body => self.body.insert(allocator, codepoint) catch {
                self.commit_error = .input_allocation_failed;
                return;
            },
        }
        self.refreshInputError();
    }

    pub fn enter(self: *State) void {
        switch (self.active_field) {
            .subject => {
                self.active_field = .body;
                self.refreshInputError();
            },
            .body => {
                const allocator = self.allocator orelse {
                    self.commit_error = .input_allocation_failed;
                    return;
                };
                if (self.totalRawBytes() + 1 > max_message_bytes) {
                    self.commit_error = .message_too_large;
                    return;
                }
                self.body.newline(allocator) catch {
                    self.commit_error = .input_allocation_failed;
                    return;
                };
                self.refreshInputError();
            },
        }
    }

    pub fn toggleField(self: *State) void {
        self.active_field = switch (self.active_field) {
            .subject => .body,
            .body => .subject,
        };
        self.refreshInputError();
    }

    pub fn backspace(self: *State) void {
        switch (self.active_field) {
            .subject => self.subject.backspace(),
            .body => self.body.backspace(),
        }
        self.refreshInputError();
    }

    pub fn moveLeft(self: *State) void {
        switch (self.active_field) {
            .subject => self.subject.moveLeft(),
            .body => self.body.moveLeft(),
        }
    }

    pub fn moveRight(self: *State) void {
        switch (self.active_field) {
            .subject => self.subject.moveRight(),
            .body => self.body.moveRight(),
        }
    }

    pub fn moveUp(self: *State) void {
        if (self.active_field == .body) self.body.moveUp();
    }

    pub fn moveDown(self: *State) void {
        if (self.active_field == .body) self.body.moveDown();
    }

    pub fn validateSubmit(self: *const State, summary: StagedSummary) ?CommitError {
        if (self.commit_error) |err| {
            switch (err) {
                .subject_too_long, .message_too_large, .input_allocation_failed => return err,
                else => {},
            }
        }
        if (trimmedSubject(self).len == 0) return .subject_empty;
        if (self.subjectCharCount() > max_subject_chars) return .subject_too_long;
        if (self.totalRawBytes() > max_message_bytes) return .message_too_large;
        if (self.mode == .amend) return null;
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
        const body = trimmedBody(self);
        if (body.len == 0) return allocator.dupe(u8, subject);
        return std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ subject, body });
    }

    /// Return the split message shape used by `git commit -m subject [-m body]`.
    ///
    /// The commit action should not re-parse `formatMessage()` because trimming
    /// and ownership rules belong to this editor state.
    pub fn formatMessageParts(self: *const State, allocator: std.mem.Allocator) !MessageParts {
        const subject = try allocator.dupe(u8, trimmedSubject(self));
        errdefer allocator.free(subject);

        const body = trimmedBody(self);
        return .{
            .subject = subject,
            .body = if (body.len == 0) null else try allocator.dupe(u8, body),
        };
    }

    pub fn subjectCharCount(self: *const State) usize {
        return graphemeCount(trimmedSubject(self));
    }

    pub fn bodyCharCount(self: *const State) usize {
        return graphemeCount(trimmedBody(self));
    }

    fn totalRawBytes(self: *const State) usize {
        return self.subject.slice().len + self.body.slice().len;
    }

    fn refreshInputError(self: *State) void {
        if (self.totalRawBytes() > max_message_bytes) {
            self.commit_error = .message_too_large;
            return;
        }
        if (self.subjectCharCount() > max_subject_chars) {
            self.commit_error = .subject_too_long;
            return;
        }
        if (self.commit_error) |err| {
            switch (err) {
                .subject_too_long, .message_too_large, .input_allocation_failed, .commit_failed, .amend_failed => self.commit_error = null,
                else => {},
            }
        }
    }

    fn trimmedSubject(self: *const State) []const u8 {
        return std.mem.trim(u8, self.subject.slice(), " \t\r\n");
    }

    fn trimmedBody(self: *const State) []const u8 {
        return std.mem.trim(u8, self.body.slice(), " \t\r\n");
    }
};

fn utf8Len(codepoint: u21) usize {
    var bytes: [4]u8 = undefined;
    return std.unicode.utf8Encode(codepoint, &bytes) catch unreachable;
}

fn offsetForDisplayColumn(bytes: []const u8, target_column: u16) usize {
    var used: u16 = 0;
    var iter = chasen.text.graphemeIterator(bytes);
    while (iter.next()) |grapheme| {
        const grapheme_bytes = grapheme.bytes(bytes);
        const width = chasen.text.displayWidth(grapheme_bytes);
        if (used +| width > target_column) return grapheme.start;
        used +|= width;
        if (used >= target_column) return grapheme.start + grapheme.len;
    }
    return bytes.len;
}

test "State validates commit message and staged summary" {
    var state: State = .init(std.testing.allocator);
    defer state.deinit();

    try std.testing.expectEqual(CommitError.subject_empty, state.validateSubmit(.{ .ready = .{ .count = 1 } }).?);

    state.insert('x');
    try std.testing.expectEqual(CommitError.no_staged_changes, state.validateSubmit(.{ .ready = .{ .count = 0 } }).?);
    try std.testing.expectEqual(CommitError.status_loading, state.validateSubmit(.loading_or_stale).?);
    try std.testing.expectEqual(CommitError.status_unavailable, state.validateSubmit(.unavailable).?);
    try std.testing.expect(state.validateSubmit(.{ .ready = .{ .count = 1 } }) == null);
}

test "State amend mode skips staged summary gate" {
    var state: State = .init(std.testing.allocator);
    defer state.deinit();

    state.open(.amend);
    state.insert('x');

    try std.testing.expect(state.validateSubmit(.{ .ready = .{ .count = 0 } }) == null);
    try std.testing.expect(state.validateSubmit(.loading_or_stale) == null);
    try std.testing.expect(state.validateSubmit(.unavailable) == null);
}

test "State exposes mode-specific title and submit label" {
    var state: State = .init(std.testing.allocator);
    defer state.deinit();

    state.open(.commit);
    try std.testing.expectEqualStrings("Commit", state.title());
    try std.testing.expectEqualStrings("commit", state.submitLabel());

    state.open(.amend);
    try std.testing.expectEqualStrings("Amend commit", state.title());
    try std.testing.expectEqualStrings("amend", state.submitLabel());
}

test "State reports subject overflow as panel error" {
    var state: State = .init(std.testing.allocator);
    defer state.deinit();

    var index: usize = 0;
    while (index < max_subject_chars + 1) : (index += 1) state.insert('x');

    try std.testing.expectEqual(CommitError.subject_too_long, state.commit_error.?);
    try std.testing.expectEqual(CommitError.subject_too_long, state.validateSubmit(.{ .ready = .{ .count = 1 } }).?);
    state.backspace();
    try std.testing.expect(state.commit_error == null);
}

test "State accepts multibyte subject up to character limit" {
    var state: State = .init(std.testing.allocator);
    defer state.deinit();

    var index: usize = 0;
    while (index < max_subject_chars) : (index += 1) state.insert('あ');

    try std.testing.expect(state.commit_error == null);
    try std.testing.expectEqual(max_subject_chars, graphemeCount(state.subject.slice()));
    try std.testing.expect(state.validateSubmit(.{ .ready = .{ .count = 1 } }) == null);
}

test "State validates trimmed character counts" {
    var state: State = .init(std.testing.allocator);
    defer state.deinit();

    state.insert(' ');
    var index: usize = 0;
    while (index < max_subject_chars) : (index += 1) state.insert('あ');
    state.insert(' ');

    try std.testing.expectEqual(max_subject_chars, state.subjectCharCount());
    try std.testing.expect(state.validateSubmit(.{ .ready = .{ .count = 1 } }) == null);
}

test "State routes enter and body text" {
    var state: State = .init(std.testing.allocator);
    defer state.deinit();

    try state.subject.insert(std.testing.allocator, 's');
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
    var state: State = .init(std.testing.allocator);
    defer state.deinit();

    try state.subject.insert(std.testing.allocator, ' ');
    try state.subject.insert(std.testing.allocator, 's');
    try state.subject.insert(std.testing.allocator, ' ');

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

test "State formats split message parts" {
    var state: State = .init(std.testing.allocator);
    defer state.deinit();

    try state.subject.insert(std.testing.allocator, ' ');
    try state.subject.insert(std.testing.allocator, 's');
    try state.subject.insert(std.testing.allocator, ' ');

    var subject_only = try state.formatMessageParts(std.testing.allocator);
    defer subject_only.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("s", subject_only.subject);
    try std.testing.expect(subject_only.body == null);

    state.active_field = .body;
    state.insert(' ');
    state.insert('b');
    state.enter();
    state.insert('c');
    state.insert(' ');

    var with_body = try state.formatMessageParts(std.testing.allocator);
    defer with_body.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("s", with_body.subject);
    try std.testing.expectEqualStrings("b\nc", with_body.body.?);
}

test "State close clears content and remains reusable" {
    var state: State = .init(std.testing.allocator);
    defer state.deinit();

    state.open(.amend);
    state.insert('s');
    state.enter();
    state.insert('b');
    state.close();

    try std.testing.expect(!state.is_open);
    try std.testing.expectEqual(Mode.commit, state.mode);
    try std.testing.expectEqualStrings("", state.subject.slice());
    try std.testing.expectEqualStrings("", state.body.slice());

    state.open(.commit);
    state.insert('x');
    try std.testing.expectEqualStrings("x", state.subject.slice());
}

test "State distinguishes message byte cap from subject character limit" {
    var state: State = .init(std.testing.allocator);
    defer state.deinit();

    state.active_field = .body;
    var index: usize = 0;
    while (index < max_message_bytes) : (index += 1) state.insert('a');
    try std.testing.expect(state.commit_error == null);

    state.insert('b');
    try std.testing.expectEqual(CommitError.message_too_large, state.commit_error.?);

    state.backspace();
    try std.testing.expect(state.commit_error == null);
}

test "State clears transient allocation error after valid edit" {
    var state: State = .init(std.testing.allocator);
    defer state.deinit();

    state.insert('s');
    state.commit_error = .input_allocation_failed;
    state.insert('x');

    try std.testing.expect(state.commit_error == null);
    try std.testing.expect(state.validateSubmit(.{ .ready = .{ .count = 1 } }) == null);
}

test "BodyText edits at the cursor" {
    var body: BodyText = .{};
    defer body.deinit(std.testing.allocator);

    try body.insert(std.testing.allocator, 'a');
    try body.insert(std.testing.allocator, 'c');
    body.moveLeft();
    try body.insert(std.testing.allocator, 'b');

    try std.testing.expectEqualStrings("abc", body.slice());
    try std.testing.expectEqual(@as(usize, 2), body.cursor());

    body.backspace();
    try std.testing.expectEqualStrings("ac", body.slice());
    try std.testing.expectEqual(@as(usize, 1), body.cursor());
}

test "BodyText reports cursor line context" {
    var body: BodyText = .{};
    defer body.deinit(std.testing.allocator);

    try body.insert(std.testing.allocator, 'a');
    try body.newline(std.testing.allocator);
    try body.insert(std.testing.allocator, 'b');

    try std.testing.expectEqual(@as(usize, 1), body.cursorLineIndex());
    try std.testing.expectEqualStrings("b", body.cursorLinePrefix());
}

test "BodyText moves vertically by display column" {
    var body: BodyText = .{};
    defer body.deinit(std.testing.allocator);

    try body.insert(std.testing.allocator, 'a');
    try body.insert(std.testing.allocator, 'b');
    try body.newline(std.testing.allocator);
    try body.insert(std.testing.allocator, 'c');
    try body.insert(std.testing.allocator, 'd');
    try body.insert(std.testing.allocator, 'e');

    body.moveLeft();
    try std.testing.expectEqualStrings("e", body.slice()[body.cursor() .. body.cursor() + 1]);

    body.moveUp();
    try std.testing.expectEqual(@as(usize, 0), body.cursorLineIndex());
    try std.testing.expectEqualStrings("ab", body.cursorLinePrefix());

    body.moveDown();
    try std.testing.expectEqual(@as(usize, 1), body.cursorLineIndex());
    try std.testing.expectEqualStrings("cd", body.cursorLinePrefix());
}
