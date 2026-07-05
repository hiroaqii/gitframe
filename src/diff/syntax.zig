const syntax_provider = @import("../syntax/provider.zig");

pub const TokenRole = syntax_provider.TokenRole;
pub const TokenSpan = syntax_provider.TokenSpan;
pub const LineSpans = syntax_provider.LineSpans;

test "TokenSpan validates rendered-line-local UTF-8 byte ranges" {
    const line = "aあb";

    try @import("std").testing.expect((TokenSpan{ .start = 1, .end = 4, .role = .string }).validForLine(line));
    try @import("std").testing.expect(!(TokenSpan{ .start = 2, .end = 4, .role = .string }).validForLine(line));
    try @import("std").testing.expect(!(TokenSpan{ .start = 0, .end = line.len + 1, .role = .plain }).validForLine(line));
}
