const std = @import("std");

pub const TokenRole = enum {
    keyword,
    function,
    type,
    string,
    number,
    comment,
    constant,
    variable,
    operator,
    punctuation,
    property,
    plain,
};

/// Byte offsets are relative to the rendered diff line body (`DiffLine.text`),
/// not to the full source file, line-number gutter, or diff prefix.
pub const TokenSpan = struct {
    start: usize,
    end: usize,
    role: TokenRole,

    pub fn validForLine(self: TokenSpan, line: []const u8) bool {
        return self.start <= self.end and
            self.end <= line.len and
            std.unicode.utf8ValidateSlice(line[self.start..self.end]);
    }
};

pub const LineSpans = struct {
    spans: []const TokenSpan = &.{},

    pub fn empty() LineSpans {
        return .{};
    }
};

test "TokenSpan validates rendered-line-local UTF-8 byte ranges" {
    const line = "aあb";

    try std.testing.expect((TokenSpan{ .start = 1, .end = 4, .role = .string }).validForLine(line));
    try std.testing.expect(!(TokenSpan{ .start = 2, .end = 4, .role = .string }).validForLine(line));
    try std.testing.expect(!(TokenSpan{ .start = 0, .end = line.len + 1, .role = .plain }).validForLine(line));
}
