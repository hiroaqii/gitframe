//! Page-neutral syntax token roles and line-local span sanitization.

const std = @import("std");
const chasen = @import("chasen");

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

pub const TokenSpan = struct {
    start: usize,
    end: usize,
    role: TokenRole,

    pub fn validForLine(self: TokenSpan, line: []const u8) bool {
        return self.start <= self.end and self.end <= line.len and
            std.unicode.utf8ValidateSlice(line[self.start..self.end]);
    }
};

pub const LineSpans = struct {
    spans: []const TokenSpan = &.{},

    pub fn empty() LineSpans {
        return .{};
    }
};

pub fn sanitizeLineSpans(allocator: std.mem.Allocator, line: []const u8, spans: []const TokenSpan) !LineSpans {
    if (!std.unicode.utf8ValidateSlice(line)) return .empty();
    var boundaries: std.DynamicBitSetUnmanaged = try .initEmpty(allocator, line.len + 1);
    defer boundaries.deinit(allocator);
    boundaries.set(0);
    boundaries.set(line.len);
    var graphemes = chasen.text.graphemeIterator(line);
    while (graphemes.next()) |grapheme| {
        boundaries.set(grapheme.start);
        boundaries.set(grapheme.start + grapheme.len);
    }

    var valid: std.ArrayList(TokenSpan) = .empty;
    defer valid.deinit(allocator);
    for (spans) |span| {
        if (!span.validForLine(line) or span.start == span.end) continue;
        if (!boundaries.isSet(span.start) or !boundaries.isSet(span.end)) continue;
        try valid.append(allocator, span);
    }
    std.mem.sort(TokenSpan, valid.items, {}, compareSpan);

    var compact: std.ArrayList(TokenSpan) = .empty;
    errdefer compact.deinit(allocator);
    var last_end: usize = 0;
    for (valid.items) |span| {
        if (span.start < last_end) continue;
        try compact.append(allocator, span);
        last_end = span.end;
    }
    return .{ .spans = try compact.toOwnedSlice(allocator) };
}

pub fn roleFromScope(scope: []const u8) TokenRole {
    if (contains(scope, "comment")) return .comment;
    if (contains(scope, "string")) return .string;
    if (contains(scope, "number") or contains(scope, "float") or contains(scope, "integer")) return .number;
    if (contains(scope, "keyword")) return .keyword;
    if (contains(scope, "function") or contains(scope, "method")) return .function;
    if (contains(scope, "type") or contains(scope, "class") or contains(scope, "struct") or contains(scope, "enum")) return .type;
    if (contains(scope, "constant") or contains(scope, "boolean")) return .constant;
    if (contains(scope, "variable") or contains(scope, "parameter")) return .variable;
    if (contains(scope, "operator")) return .operator;
    if (contains(scope, "punctuation") or contains(scope, "delimiter")) return .punctuation;
    if (contains(scope, "property") or contains(scope, "field")) return .property;
    return .plain;
}

fn compareSpan(_: void, a: TokenSpan, b: TokenSpan) bool {
    if (a.start != b.start) return a.start < b.start;
    return a.end < b.end;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "neutral token sanitizer rejects partial grapheme endpoints and overlaps" {
    const raw = [_]TokenSpan{
        .{ .start = 1, .end = 3, .role = .string },
        .{ .start = 0, .end = 3, .role = .keyword },
        .{ .start = 3, .end = 4, .role = .variable },
    };
    const spans = try sanitizeLineSpans(std.testing.allocator, "e\u{301}x", &raw);
    defer std.testing.allocator.free(spans.spans);
    try std.testing.expectEqual(@as(usize, 2), spans.spans.len);
    try std.testing.expectEqual(TokenSpan{ .start = 0, .end = 3, .role = .keyword }, spans.spans[0]);
    try std.testing.expectEqual(TokenSpan{ .start = 3, .end = 4, .role = .variable }, spans.spans[1]);
}

test "neutral token scope mapping keeps existing roles" {
    try std.testing.expectEqual(TokenRole.keyword, roleFromScope("keyword.control"));
    try std.testing.expectEqual(TokenRole.function, roleFromScope("function.method"));
    try std.testing.expectEqual(TokenRole.comment, roleFromScope("comment.documentation"));
    try std.testing.expectEqual(TokenRole.plain, roleFromScope("unknown.capture"));
}

test "neutral token sanitizer rejects an endpoint inside a ZWJ grapheme" {
    const line = "👩‍💻x";
    const raw = [_]TokenSpan{
        .{ .start = 0, .end = 4, .role = .type },
        .{ .start = 0, .end = 11, .role = .type },
        .{ .start = 11, .end = 12, .role = .variable },
    };
    const spans = try sanitizeLineSpans(std.testing.allocator, line, &raw);
    defer std.testing.allocator.free(spans.spans);
    try std.testing.expectEqual(@as(usize, 2), spans.spans.len);
    try std.testing.expectEqual(@as(usize, 11), spans.spans[0].end);
}

test "neutral token sanitizer treats an invalid UTF-8 line as undecorated" {
    const line = [_]u8{ 0xff, 'x' };
    const raw = [_]TokenSpan{.{ .start = 1, .end = 2, .role = .variable }};
    const spans = try sanitizeLineSpans(std.testing.allocator, &line, &raw);
    defer std.testing.allocator.free(spans.spans);
    try std.testing.expectEqual(@as(usize, 0), spans.spans.len);
}
