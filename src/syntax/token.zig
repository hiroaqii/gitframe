//! Page-neutral syntax token roles and line-local span sanitization.

const std = @import("std");
const chasen = @import("chasen");

pub const TokenRole = enum {
    keyword,
    function,
    macro,
    constructor,
    type,
    string,
    number,
    comment,
    constant,
    variable,
    parameter,
    member,
    operator,
    punctuation,
    special_punctuation,
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

    var generic: std.ArrayList(TokenSpan) = .empty;
    defer generic.deinit(allocator);
    var refinements: std.ArrayList(TokenSpan) = .empty;
    defer refinements.deinit(allocator);
    for (spans) |span| {
        if (!span.validForLine(line) or span.start == span.end) continue;
        if (!boundaries.isSet(span.start) or !boundaries.isSet(span.end)) continue;
        if (isSemanticRefinement(span.role)) {
            try refinements.append(allocator, span);
        } else {
            try generic.append(allocator, span);
        }
    }
    compactNonOverlapping(&generic);
    compactNonOverlapping(&refinements);

    // Detailed semantic captures may be nested inside a generic one: for
    // example `punctuation.special` delimiters sit inside a template string,
    // while `variable.parameter` commonly covers the exact same identifier as
    // `variable`. Preserve the generic foreground around the refined range and
    // let the refined role own only its exact bytes.
    var resolved: std.ArrayList(TokenSpan) = .empty;
    defer resolved.deinit(allocator);
    var refinement_start: usize = 0;
    for (generic.items) |span| {
        while (refinement_start < refinements.items.len and
            refinements.items[refinement_start].end <= span.start) : (refinement_start += 1)
        {}

        var cursor = span.start;
        var refinement_index = refinement_start;
        while (refinement_index < refinements.items.len and
            refinements.items[refinement_index].start < span.end) : (refinement_index += 1)
        {
            const refinement = refinements.items[refinement_index];
            if (cursor < refinement.start) {
                try resolved.append(allocator, .{
                    .start = cursor,
                    .end = @min(refinement.start, span.end),
                    .role = span.role,
                });
            }
            cursor = @max(cursor, refinement.end);
            if (cursor >= span.end) break;
        }
        if (cursor < span.end) try resolved.append(allocator, .{
            .start = cursor,
            .end = span.end,
            .role = span.role,
        });
    }
    try resolved.appendSlice(allocator, refinements.items);
    std.mem.sort(TokenSpan, resolved.items, {}, compareSpan);
    return .{ .spans = try resolved.toOwnedSlice(allocator) };
}

/// Returns true for a capture which preserves a more specific semantic fact
/// than its generic enclosing scope. Providers retain later captures for these
/// roles and the sanitizer lets them override only the overlapping bytes.
pub fn isSemanticRefinement(role: TokenRole) bool {
    return switch (role) {
        .parameter, .member, .constructor, .macro, .special_punctuation => true,
        else => false,
    };
}

pub fn roleFromScope(scope: []const u8) TokenRole {
    if (contains(scope, "comment")) return .comment;
    // Preserve detailed semantic captures before their generic parent scope.
    // Tree-sitter query sets use both bare (`parameter`) and qualified
    // (`variable.parameter`) spellings, so normalize by dot-delimited segment
    // instead of branching on the source language.
    if (hasScopeSegment(scope, "special") and
        (hasScopeSegment(scope, "punctuation") or hasScopeSegment(scope, "delimiter"))) return .special_punctuation;
    if (hasScopeSegment(scope, "parameter")) return .parameter;
    if (hasScopeSegment(scope, "member")) return .member;
    if (hasScopeSegment(scope, "constructor")) return .constructor;
    if (hasScopeSegment(scope, "macro")) return .macro;
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

fn compactNonOverlapping(spans: *std.ArrayList(TokenSpan)) void {
    std.mem.sort(TokenSpan, spans.items, {}, compareSpan);
    var retained: usize = 0;
    var last_end: usize = 0;
    for (spans.items) |span| {
        if (span.start < last_end) continue;
        spans.items[retained] = span;
        retained += 1;
        last_end = span.end;
    }
    spans.shrinkRetainingCapacity(retained);
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn hasScopeSegment(scope: []const u8, expected: []const u8) bool {
    var segments = std.mem.splitScalar(u8, scope, '.');
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, expected)) return true;
    }
    return false;
}

test "neutral token sanitizer rejects partial grapheme endpoints and overlaps" {
    {
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

    {
        const raw = [_]TokenSpan{
            .{ .start = 0, .end = 4, .role = .variable },
            .{ .start = 0, .end = 4, .role = .parameter },
        };
        const spans = try sanitizeLineSpans(std.testing.allocator, "name", &raw);
        defer std.testing.allocator.free(spans.spans);
        try std.testing.expectEqualSlices(TokenSpan, &.{.{
            .start = 0,
            .end = 4,
            .role = .parameter,
        }}, spans.spans);
    }

    {
        const raw = [_]TokenSpan{
            .{ .start = 0, .end = 15, .role = .string },
            .{ .start = 7, .end = 9, .role = .special_punctuation },
            .{ .start = 13, .end = 14, .role = .special_punctuation },
        };
        const spans = try sanitizeLineSpans(std.testing.allocator, "`Hello ${name}`", &raw);
        defer std.testing.allocator.free(spans.spans);
        try std.testing.expectEqualSlices(TokenSpan, &.{
            .{ .start = 0, .end = 7, .role = .string },
            .{ .start = 7, .end = 9, .role = .special_punctuation },
            .{ .start = 9, .end = 13, .role = .string },
            .{ .start = 13, .end = 14, .role = .special_punctuation },
            .{ .start = 14, .end = 15, .role = .string },
        }, spans.spans);
    }
}

test "neutral token scope mapping keeps existing roles" {
    try std.testing.expectEqual(TokenRole.keyword, roleFromScope("keyword.control"));
    try std.testing.expectEqual(TokenRole.function, roleFromScope("function.method"));
    try std.testing.expectEqual(TokenRole.comment, roleFromScope("comment.documentation"));
    try std.testing.expectEqual(TokenRole.plain, roleFromScope("unknown.capture"));

    try std.testing.expectEqual(TokenRole.parameter, roleFromScope("variable.parameter"));
    try std.testing.expectEqual(TokenRole.parameter, roleFromScope("parameter.definition"));
    try std.testing.expectEqual(TokenRole.member, roleFromScope("variable.member"));
    try std.testing.expectEqual(TokenRole.member, roleFromScope("member.definition"));
    try std.testing.expectEqual(TokenRole.constructor, roleFromScope("constructor"));
    try std.testing.expectEqual(TokenRole.macro, roleFromScope("function.macro"));
    try std.testing.expectEqual(TokenRole.macro, roleFromScope("constant.macro"));
    try std.testing.expectEqual(TokenRole.special_punctuation, roleFromScope("punctuation.special"));
    try std.testing.expectEqual(TokenRole.special_punctuation, roleFromScope("delimiter.special"));

    try std.testing.expectEqual(TokenRole.variable, roleFromScope("variable"));
    try std.testing.expectEqual(TokenRole.function, roleFromScope("function.method"));
    try std.testing.expectEqual(TokenRole.constant, roleFromScope("constant.builtin"));
    try std.testing.expectEqual(TokenRole.punctuation, roleFromScope("punctuation.bracket"));
    // Unrecognized special-string scopes intentionally use the base string role.
    try std.testing.expectEqual(TokenRole.string, roleFromScope("string.special.regex"));
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
