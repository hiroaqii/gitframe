//! Page-neutral colon command input and closed parser vocabulary.
//!
//! Repository authority and execution stay outside this leaf. `Submission`
//! owns the fixed-capacity bytes from which parse results may borrow.

const std = @import("std");
const prompt = @import("prompt.zig");

pub const Msg = union(enum) {
    open,
    cancel,
    submit,
    insert: u21,
    /// Borrowed from `chasen.Event.paste`; valid only during synchronous dispatch.
    paste: []const u8,
    backspace,
    move_left,
    move_right,
    owned_noop,
};

pub const Command = union(enum) {
    goto_line: usize,
};

pub const ParseResult = union(enum) {
    empty,
    command: Command,
    invalid_line_number,
    unknown_command: []const u8,
};

pub const Active = struct {
    input: prompt.TextInput = .{},

    pub fn submission(self: Active) Submission {
        return .{ .input = self.input };
    }
};

/// Value snapshot which keeps borrowed parser diagnostics alive after the
/// visible session has already returned to its inactive zero state.
pub const Submission = struct {
    input: prompt.TextInput,

    pub fn raw(self: *const Submission) []const u8 {
        return self.input.slice();
    }

    pub fn parse(self: *const Submission) ParseResult {
        const text = self.raw();
        if (text.len == 0) return .empty;
        if (!std.ascii.isDigit(text[0])) return .{ .unknown_command = text };
        if (text[0] == '0') return .invalid_line_number;

        var value: usize = 0;
        for (text) |byte| {
            if (!std.ascii.isDigit(byte)) return .invalid_line_number;
            value = std.math.mul(usize, value, 10) catch return .invalid_line_number;
            value = std.math.add(usize, value, byte - '0') catch return .invalid_line_number;
        }
        return .{ .command = .{ .goto_line = value } };
    }
};

fn submissionForTest(text: []const u8) !Submission {
    var active: Active = .{};
    try active.input.insertSlice(text);
    return active.submission();
}

test "command line parser accepts only positive decimal source lines" {
    var empty = try submissionForTest("");
    try std.testing.expect(empty.parse() == .empty);

    var one = try submissionForTest("1");
    try std.testing.expectEqual(@as(usize, 1), one.parse().command.goto_line);

    var line = try submissionForTest("200");
    try std.testing.expectEqual(@as(usize, 200), line.parse().command.goto_line);

    for ([_][]const u8{ "0", "00", "01", "1x", "12 3" }) |text| {
        var invalid = try submissionForTest(text);
        try std.testing.expect(invalid.parse() == .invalid_line_number);
    }
}

test "command line parser keeps unknown text in the submission snapshot" {
    var submission = try submissionForTest("hoge");
    const result = submission.parse();
    try std.testing.expectEqualStrings("hoge", result.unknown_command);

    // A different active value cannot change the already-submitted bytes.
    var next: Active = .{};
    try next.input.insertSlice("other");
    try std.testing.expectEqualStrings("hoge", result.unknown_command);
}

test "command line parser rejects usize overflow" {
    var buffer: [std.fmt.count("{d}0", .{std.math.maxInt(usize)})]u8 = undefined;
    const overflow = try std.fmt.bufPrint(&buffer, "{d}0", .{std.math.maxInt(usize)});
    var submission = try submissionForTest(overflow);
    try std.testing.expect(submission.parse() == .invalid_line_number);
}

test "command line active input snapshots UTF-8 cursor edits by value" {
    var active: Active = .{};
    try active.input.insertSlice("a🐈c");
    active.input.moveLeft();
    active.input.backspace();
    const submission = active.submission();

    try std.testing.expectEqualStrings("ac", submission.raw());
    try active.input.insert('b');
    try std.testing.expectEqualStrings("abc", active.input.slice());
    try std.testing.expectEqualStrings("ac", submission.raw());
}
