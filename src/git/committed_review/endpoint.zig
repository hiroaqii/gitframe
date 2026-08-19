const std = @import("std");

pub const max_input_bytes: usize = 4096;
pub const max_suffixes: usize = 64;

pub const ParseError = error{UnsupportedCommitish};

/// A fully preflighted member of the v1 closed commit-ish language. `base`
/// and `suffix_text` borrow the caller's input; no unvalidated bytes are ever
/// passed to an object command.
pub const Parsed = struct {
    base: []const u8,
    suffix_text: []const u8,
    suffix_count: usize,

    pub fn baseIsHex(self: Parsed) bool {
        if (self.base.len == 0) return false;
        for (self.base) |byte| if (!std.ascii.isHex(byte)) return false;
        return true;
    }
};

pub fn parse(input: []const u8) ParseError!Parsed {
    if (input.len == 0 or input.len > max_input_bytes) return error.UnsupportedCommitish;
    if (input[0] == '-') return error.UnsupportedCommitish;
    for (input) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.UnsupportedCommitish;
    }
    if (std.mem.indexOf(u8, input, "..") != null or
        std.mem.indexOfScalar(u8, input, ':') != null or
        std.mem.indexOf(u8, input, "@{") != null or
        std.mem.eql(u8, input, "@"))
    {
        return error.UnsupportedCommitish;
    }

    const suffix_start = firstSuffix(input);
    const base = input[0..suffix_start];
    if (base.len == 0) return error.UnsupportedCommitish;

    var cursor = suffix_start;
    var suffix_count: usize = 0;
    while (cursor < input.len) {
        if (suffix_count == max_suffixes) return error.UnsupportedCommitish;
        if (input[cursor] != '^' and input[cursor] != '~') return error.UnsupportedCommitish;
        cursor = try parseSuffix(input, cursor);
        suffix_count += 1;
    }
    return .{
        .base = base,
        .suffix_text = input[suffix_start..],
        .suffix_count = suffix_count,
    };
}

fn firstSuffix(input: []const u8) usize {
    for (input, 0..) |byte, index| switch (byte) {
        '^', '~' => return index,
        else => {},
    };
    return input.len;
}

fn parseSuffix(input: []const u8, start: usize) ParseError!usize {
    if (input[start] == '~') {
        const end = decimalEnd(input, start + 1);
        if (end == start + 1) return error.UnsupportedCommitish;
        try validateNumber(input[start + 1 .. end]);
        return end;
    }

    std.debug.assert(input[start] == '^');
    if (start + 1 == input.len) return input.len;
    if (input[start + 1] == '{') {
        if (std.mem.startsWith(u8, input[start..], "^{}")) return start + 3;
        if (std.mem.startsWith(u8, input[start..], "^{commit}")) return start + "^{commit}".len;
        return error.UnsupportedCommitish;
    }
    const next = input[start + 1];
    if (next == '^' or next == '~') return start + 1;
    if (!std.ascii.isDigit(next)) return error.UnsupportedCommitish;
    const end = decimalEnd(input, start + 1);
    try validateNumber(input[start + 1 .. end]);
    return end;
}

fn decimalEnd(input: []const u8, start: usize) usize {
    var end = start;
    while (end < input.len and std.ascii.isDigit(input[end])) : (end += 1) {}
    return end;
}

fn validateNumber(text: []const u8) ParseError!void {
    if (text.len == 0 or text.len > 5 or (text.len > 1 and text[0] == '0')) return error.UnsupportedCommitish;
    var value: u32 = 0;
    for (text) |byte| {
        value = std.math.mul(u32, value, 10) catch return error.UnsupportedCommitish;
        value = std.math.add(u32, value, byte - '0') catch return error.UnsupportedCommitish;
        if (value > 65535) return error.UnsupportedCommitish;
    }
}

test "closed endpoint grammar accepts only enumerated ancestry and peel suffixes" {
    const accepted = [_][]const u8{
        "HEAD",   "refs/heads/main", "deadBEEF",         "tag^",  "tag^0",  "tag^1", "tag~0", "tag~42", "tag~65535",
        "tag^{}", "tag^{commit}",    "tag^2~3^{commit}", "tag^^", "tag^~1",
    };
    for (accepted) |value| _ = try parse(value);

    const rejected = [_][]const u8{
        "",          "-n1",       "A..B",        "A...B",       "^main",           "main^@",     "main^!",      "main^-2",           "main~",
        "main^01",   "main~01",   "main^65536",  "main^{tree}", "main^{/message}", "main@{1}",   "@",           ":path",             ":0:path",
        "main:path", ":/message", "white space", "line\nfeed",  "control\x01byte", "main^1tail", "main^{}tail", "main^{commit}tail", "main~9999999999999999999999999999999999999999",
    };
    for (rejected) |value| try std.testing.expectError(error.UnsupportedCommitish, parse(value));
}

test "closed endpoint grammar caps suffix count" {
    var exact: [1 + max_suffixes]u8 = undefined;
    exact[0] = 'a';
    @memset(exact[1..], '^');
    try std.testing.expectEqual(max_suffixes, (try parse(&exact)).suffix_count);

    var over: [1 + (max_suffixes + 1)]u8 = undefined;
    over[0] = 'a';
    @memset(over[1..], '^');
    try std.testing.expectError(error.UnsupportedCommitish, parse(&over));
}

test "closed endpoint grammar caps the complete input bytes" {
    var exact: [max_input_bytes]u8 = undefined;
    @memset(&exact, 'a');
    try std.testing.expectEqual(max_input_bytes, (try parse(&exact)).base.len);

    var over: [max_input_bytes + 1]u8 = undefined;
    @memset(&over, 'a');
    try std.testing.expectError(error.UnsupportedCommitish, parse(&over));
}
