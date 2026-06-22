const std = @import("std");
const chasen = @import("chasen");
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

pub const max_body_bytes = 8192;
pub const max_subject_chars = 72;
pub const max_body_chars = 2000;
pub const max_body_lines = 32;

/// Minimal app-local multiline buffer for the commit body.
///
/// This keeps storage self-owned and fixed-capacity while supporting the
/// cursor movement needed by the commit popup.
pub const BodyText = struct {
    pub const InsertError = error{BufferFull};

    buffer: [max_body_bytes]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,

    pub fn slice(self: *const BodyText) []const u8 {
        return self.buffer[0..self.len];
    }

    pub fn insert(self: *BodyText, codepoint: u21) InsertError!void {
        var bytes: [4]u8 = undefined;
        const written = std.unicode.utf8Encode(codepoint, &bytes) catch unreachable;
        if (self.len + written > self.buffer.len) return error.BufferFull;
        std.mem.copyBackwards(u8, self.buffer[self.cursor + written .. self.len + written], self.buffer[self.cursor..self.len]);
        @memcpy(self.buffer[self.cursor .. self.cursor + written], bytes[0..written]);
        self.len += written;
        self.cursor += written;
    }

    pub fn newline(self: *BodyText) InsertError!void {
        if (self.lineCount() >= max_body_lines) return error.BufferFull;
        try self.insert('\n');
    }

    pub fn backspace(self: *BodyText) void {
        if (self.cursor == 0) return;
        const previous = previousBoundary(self.slice(), self.cursor);
        std.mem.copyForwards(u8, self.buffer[previous .. self.len - (self.cursor - previous)], self.buffer[self.cursor..self.len]);
        self.len -= self.cursor - previous;
        self.cursor = previous;
    }

    pub fn moveLeft(self: *BodyText) void {
        self.cursor = previousBoundary(self.slice(), self.cursor);
    }

    pub fn moveRight(self: *BodyText) void {
        self.cursor = nextBoundary(self.slice(), self.cursor);
    }

    pub fn moveUp(self: *BodyText) void {
        const current_line = self.cursorLineIndex();
        if (current_line == 0) return;

        self.cursor = self.cursorForLineColumn(current_line - 1, self.cursorDisplayColumn());
    }

    pub fn moveDown(self: *BodyText) void {
        const current_line = self.cursorLineIndex();
        if (current_line + 1 >= self.lineCount()) return;

        self.cursor = self.cursorForLineColumn(current_line + 1, self.cursorDisplayColumn());
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

    pub fn cursorLineIndex(self: *const BodyText) usize {
        var index: usize = 0;
        for (self.slice()[0..self.cursor]) |byte| {
            if (byte == '\n') index += 1;
        }
        return index;
    }

    pub fn cursorLinePrefix(self: *const BodyText) []const u8 {
        const text = self.slice();
        var start: usize = 0;
        var offset: usize = 0;
        while (offset < self.cursor) : (offset += 1) {
            if (text[offset] == '\n') start = offset + 1;
        }
        return text[start..self.cursor];
    }

    pub fn cursorDisplayColumn(self: *const BodyText) u16 {
        return displayWidthClamped(self.cursorLinePrefix());
    }

    fn cursorForLineColumn(self: *const BodyText, line_index: usize, target_column: u16) usize {
        const bounds = self.lineBounds(line_index) orelse return self.cursor;
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

    pub fn clear(self: *BodyText) void {
        self.* = .{};
    }
};

pub fn graphemeCount(text: []const u8) usize {
    var count: usize = 0;
    var iter = chasen.text.graphemeIterator(text);
    while (iter.next()) |_| count += 1;
    return count;
}

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

test "State accepts multibyte subject up to character limit" {
    var state: State = .{};

    var index: usize = 0;
    while (index < max_subject_chars) : (index += 1) state.insert('あ');

    try std.testing.expect(state.commit_error == null);
    try std.testing.expectEqual(max_subject_chars, graphemeCount(state.subject.slice()));
    try std.testing.expect(state.validateSubmit(.{ .ready = .{ .count = 1 } }) == null);
}

test "State validates trimmed character counts" {
    var state: State = .{};

    state.insert(' ');
    var index: usize = 0;
    while (index < max_subject_chars) : (index += 1) state.insert('あ');
    state.insert(' ');

    try std.testing.expectEqual(max_subject_chars, state.subjectCharCount());
    try std.testing.expect(state.validateSubmit(.{ .ready = .{ .count = 1 } }) == null);

    state.active_field = .body;
    index = 0;
    while (index < max_body_chars) : (index += 1) state.insert('a');
    state.enter();
    state.insert(' ');

    try std.testing.expectEqual(max_body_chars, state.bodyCharCount());
    try std.testing.expect(state.validateSubmit(.{ .ready = .{ .count = 1 } }) == null);
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
                .subject_too_long, .body_too_long => return err,
                else => {},
            }
        }
        if (trimmedSubject(self).len == 0) return .subject_empty;
        if (self.subjectCharCount() > max_subject_chars) return .subject_too_long;
        if (self.bodyCharCount() > max_body_chars) return .body_too_long;
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

    pub fn subjectCharCount(self: *const State) usize {
        return graphemeCount(trimmedSubject(self));
    }

    pub fn bodyCharCount(self: *const State) usize {
        return graphemeCount(trimmedBody(self));
    }

    fn trimmedSubject(self: *const State) []const u8 {
        return std.mem.trim(u8, self.subject.slice(), " \t\r\n");
    }

    fn trimmedBody(self: *const State) []const u8 {
        return std.mem.trim(u8, self.body.slice(), " \t\r\n");
    }
};

test "BodyText edits at the cursor" {
    var body: BodyText = .{};

    try body.insert('a');
    try body.insert('c');
    body.moveLeft();
    try body.insert('b');

    try std.testing.expectEqualStrings("abc", body.slice());
    try std.testing.expectEqual(@as(usize, 2), body.cursor);

    body.backspace();
    try std.testing.expectEqualStrings("ac", body.slice());
    try std.testing.expectEqual(@as(usize, 1), body.cursor);
}

test "BodyText reports cursor line context" {
    var body: BodyText = .{};
    try body.insert('a');
    try body.newline();
    try body.insert('b');

    try std.testing.expectEqual(@as(usize, 1), body.cursorLineIndex());
    try std.testing.expectEqualStrings("b", body.cursorLinePrefix());
}

test "BodyText moves vertically by display column" {
    var body: BodyText = .{};
    try body.insert('a');
    try body.insert('b');
    try body.newline();
    try body.insert('c');
    try body.insert('d');
    try body.insert('e');

    body.moveLeft();
    try std.testing.expectEqualStrings("e", body.slice()[body.cursor .. body.cursor + 1]);

    body.moveUp();
    try std.testing.expectEqual(@as(usize, 0), body.cursorLineIndex());
    try std.testing.expectEqualStrings("ab", body.cursorLinePrefix());

    body.moveDown();
    try std.testing.expectEqual(@as(usize, 1), body.cursorLineIndex());
    try std.testing.expectEqualStrings("cd", body.cursorLinePrefix());
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

fn displayWidthClamped(bytes: []const u8) u16 {
    return chasen.text.displayWidth(bytes);
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
