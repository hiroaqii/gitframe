//! Sparse, bounded syntax metadata for one accepted Repository source file.
//!
//! Repository files may be newline-dense or capture-dense, so retaining one
//! entry per source line or every raw provider capture would amplify a bounded
//! 1 MiB source into unbounded page state. Only sanitized styled lines/spans
//! survive here; task-local provider/query data is deliberately excluded.

const std = @import("std");
const source_document = @import("../repository/source.zig");
const token = @import("token.zig");

pub const max_spans: usize = 131_072;
pub const max_retained_bytes: usize = 8 * 1024 * 1024;

pub const LineEntry = struct {
    line_index: u32,
    span_start: u32,
    span_count: u32,
};

pub const Candidate = struct {
    line_index: usize,
    span: token.TokenSpan,
};

pub const LimitKind = enum {
    entries,
    spans,
    bytes,
};

pub const Limits = struct {
    entries: ?usize = null,
    spans: usize = max_spans,
    bytes: usize = max_retained_bytes,
};

pub const ProductionDecision = enum {
    accept,
    reject_span,
    reject_bytes,
};

pub const SourceSpans = struct {
    line_entries: []LineEntry = &.{},
    spans: []token.TokenSpan = &.{},

    pub fn empty() SourceSpans {
        return .{};
    }

    pub fn deinit(self: *SourceSpans, allocator: std.mem.Allocator) void {
        allocator.free(self.line_entries);
        allocator.free(self.spans);
        self.* = .empty();
    }

    pub fn lineSpans(self: SourceSpans, line_index: usize) token.LineSpans {
        var low: usize = 0;
        var high = self.line_entries.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const entry = self.line_entries[middle];
            if (entry.line_index < line_index) {
                low = middle + 1;
            } else if (entry.line_index > line_index) {
                high = middle;
            } else {
                const start: usize = entry.span_start;
                return .{ .spans = self.spans[start .. start + entry.span_count] };
            }
        }
        return .empty();
    }

    /// Direct allocations that survive provider completion. Parser trees,
    /// queries, and raw candidates are task-local and are not counted here.
    pub fn retainedBytes(self: SourceSpans) usize {
        return self.line_entries.len *| @sizeOf(LineEntry) +|
            self.spans.len *| @sizeOf(token.TokenSpan);
    }
};

pub fn build(
    allocator: std.mem.Allocator,
    document: *const source_document.Document,
    candidates: []Candidate,
) !SourceSpans {
    return buildWithLimits(allocator, document, candidates, .{});
}

pub fn buildWithLimits(
    allocator: std.mem.Allocator,
    document: *const source_document.Document,
    candidates: []Candidate,
    limits: Limits,
) !SourceSpans {
    return buildWithLimitsInternal(allocator, document, candidates, limits, null);
}

/// Diagnostic entry point for callers that must distinguish which named
/// metadata ceiling rejected an otherwise sanitized result. Production keeps
/// using `build`/`buildWithLimits` and therefore pays for no retained stats.
pub fn buildWithLimitsReporting(
    allocator: std.mem.Allocator,
    document: *const source_document.Document,
    candidates: []Candidate,
    limits: Limits,
    limit_hit: *?LimitKind,
) !SourceSpans {
    limit_hit.* = null;
    return buildWithLimitsInternal(allocator, document, candidates, limits, limit_hit);
}

fn buildWithLimitsInternal(
    allocator: std.mem.Allocator,
    document: *const source_document.Document,
    candidates: []Candidate,
    limits: Limits,
    limit_hit: ?*?LimitKind,
) !SourceSpans {
    std.mem.sort(Candidate, candidates, {}, candidateLessThan);

    var entries: std.ArrayList(LineEntry) = .empty;
    errdefer entries.deinit(allocator);
    var spans: std.ArrayList(token.TokenSpan) = .empty;
    errdefer spans.deinit(allocator);
    var raw: std.ArrayList(token.TokenSpan) = .empty;
    defer raw.deinit(allocator);

    var cursor: usize = 0;
    while (cursor < candidates.len) {
        const line_index = candidates[cursor].line_index;
        var end = cursor;
        raw.clearRetainingCapacity();
        while (end < candidates.len and candidates[end].line_index == line_index) : (end += 1) {
            try raw.append(allocator, candidates[end].span);
        }
        if (document.lineBody(line_index)) |line| {
            // Apply the persistent cap after sanitization. Tree-sitter can emit
            // many nested/overlapping raw captures that collapse to a small
            // valid set; capping raw candidates made large valid files lose all
            // decoration even though retained metadata was within budget.
            const sanitized = try token.sanitizeLineSpans(allocator, line, raw.items);
            defer allocator.free(sanitized.spans);
            if (sanitized.spans.len > 0) {
                const next_entry_count = try std.math.add(usize, entries.items.len, 1);
                const next_span_count = try std.math.add(usize, spans.items.len, sanitized.spans.len);
                if (try firstExceededLimit(limits, next_entry_count, next_span_count)) |kind| {
                    if (limit_hit) |hit| hit.* = kind;
                    return error.SyntaxMetadataLimit;
                }
                try entries.append(allocator, .{
                    .line_index = @intCast(line_index),
                    .span_start = @intCast(spans.items.len),
                    .span_count = @intCast(sanitized.spans.len),
                });
                try spans.appendSlice(allocator, sanitized.spans);
            }
        }
        cursor = end;
    }

    const owned_entries = try entries.toOwnedSlice(allocator);
    errdefer allocator.free(owned_entries);
    const owned_spans = try spans.toOwnedSlice(allocator);
    return .{ .line_entries = owned_entries, .spans = owned_spans };
}

/// The relaxed diagnostic result is still finite: after sanitization every
/// retained span consumes at least one source byte and every entry represents
/// one content line. This does not bound provider-emitted raw candidates or
/// sanitizer temporaries; those retain the production adapter's behavior.
pub fn sourceDerivedDiagnosticLimits(document: *const source_document.Document) !Limits {
    const entries = document.contentLineCount();
    const spans = document.bytes.len;
    return .{
        .entries = entries,
        .spans = spans,
        .bytes = try retainedSize(entries, spans),
    };
}

pub fn productionDecision(entry_count: usize, span_count: usize) !ProductionDecision {
    if (try firstExceededLimit(.{}, entry_count, span_count)) |kind| return switch (kind) {
        .entries => unreachable,
        .spans => .reject_span,
        .bytes => .reject_bytes,
    };
    return .accept;
}

fn firstExceededLimit(limits: Limits, entry_count: usize, span_count: usize) !?LimitKind {
    if (limits.entries) |maximum| if (entry_count > maximum) return .entries;
    if (span_count > limits.spans) return .spans;
    if (try retainedSize(entry_count, span_count) > limits.bytes) return .bytes;
    return null;
}

fn retainedSize(entry_count: usize, span_count: usize) !usize {
    const entry_bytes = try std.math.mul(usize, entry_count, @sizeOf(LineEntry));
    const span_bytes = try std.math.mul(usize, span_count, @sizeOf(token.TokenSpan));
    return std.math.add(usize, entry_bytes, span_bytes);
}

fn candidateLessThan(_: void, left: Candidate, right: Candidate) bool {
    if (left.line_index != right.line_index) return left.line_index < right.line_index;
    if (left.span.start != right.span.start) return left.span.start < right.span.start;
    return left.span.end < right.span.end;
}

test "source syntax is sparse and rejects non-grapheme token endpoints" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, "const x = 1;\ne\u{301}x\nplain\n");
    var document = try source_document.Document.initOwned(allocator, bytes, .init(bytes));
    defer document.deinit(allocator);
    var candidates = [_]Candidate{
        .{ .line_index = 0, .span = .{ .start = 0, .end = 5, .role = .keyword } },
        .{ .line_index = 1, .span = .{ .start = 1, .end = 3, .role = .string } },
    };
    var spans = try build(allocator, &document, &candidates);
    defer spans.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), spans.line_entries.len);
    try std.testing.expectEqual(token.TokenRole.keyword, spans.lineSpans(0).spans[0].role);
    try std.testing.expectEqual(@as(usize, 0), spans.lineSpans(1).spans.len);
    try std.testing.expectEqual(@as(usize, 0), spans.lineSpans(500_000).spans.len);
}

test "source syntax metadata limit fails atomically" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, "a b c\n");
    var document = try source_document.Document.initOwned(allocator, bytes, .init(bytes));
    defer document.deinit(allocator);
    var candidates = [_]Candidate{
        .{ .line_index = 0, .span = .{ .start = 0, .end = 1, .role = .variable } },
        .{ .line_index = 0, .span = .{ .start = 2, .end = 3, .role = .variable } },
    };
    try std.testing.expectError(
        error.SyntaxMetadataLimit,
        buildWithLimits(allocator, &document, &candidates, .{ .spans = 1 }),
    );
    try std.testing.expectError(
        error.SyntaxMetadataLimit,
        buildWithLimits(allocator, &document, &candidates, .{ .bytes = 1 }),
    );
}

test "source syntax reports named custom metadata limits" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, "a b\n");
    var document = try source_document.Document.initOwned(allocator, bytes, .init(bytes));
    defer document.deinit(allocator);
    const original = [_]Candidate{
        .{ .line_index = 0, .span = .{ .start = 0, .end = 1, .role = .variable } },
        .{ .line_index = 0, .span = .{ .start = 2, .end = 3, .role = .variable } },
    };

    var entry_limited = original;
    var limit_hit: ?LimitKind = null;
    try std.testing.expectError(
        error.SyntaxMetadataLimit,
        buildWithLimitsReporting(allocator, &document, &entry_limited, .{ .entries = 0 }, &limit_hit),
    );
    try std.testing.expectEqual(LimitKind.entries, limit_hit.?);

    var span_limited = original;
    try std.testing.expectError(
        error.SyntaxMetadataLimit,
        buildWithLimitsReporting(allocator, &document, &span_limited, .{ .spans = 1 }, &limit_hit),
    );
    try std.testing.expectEqual(LimitKind.spans, limit_hit.?);

    var byte_limited = original;
    try std.testing.expectError(
        error.SyntaxMetadataLimit,
        buildWithLimitsReporting(allocator, &document, &byte_limited, .{ .bytes = 1 }, &limit_hit),
    );
    try std.testing.expectEqual(LimitKind.bytes, limit_hit.?);
}

test "source syntax diagnostic limits derive from accepted source shape" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, "a\nb");
    var document = try source_document.Document.initOwned(allocator, bytes, .init(bytes));
    defer document.deinit(allocator);
    const limits = try sourceDerivedDiagnosticLimits(&document);
    try std.testing.expectEqual(@as(?usize, 2), limits.entries);
    try std.testing.expectEqual(bytes.len, limits.spans);
    try std.testing.expectEqual(try retainedSize(2, bytes.len), limits.bytes);
}

test "source syntax allocation failure frees partial metadata" {
    const backing = std.testing.allocator;
    const bytes = try backing.dupe(u8, "const value = 1;\n");
    var document = try source_document.Document.initOwned(backing, bytes, .init(bytes));
    defer document.deinit(backing);
    const original = [_]Candidate{
        .{ .line_index = 0, .span = .{ .start = 0, .end = 5, .role = .keyword } },
        .{ .line_index = 0, .span = .{ .start = 6, .end = 11, .role = .variable } },
        .{ .line_index = 0, .span = .{ .start = 14, .end = 15, .role = .number } },
    };
    var observed_success = false;
    var fail_index: usize = 0;
    while (fail_index < 32) : (fail_index += 1) {
        var candidates = original;
        var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = fail_index });
        var result = build(failing.allocator(), &document, &candidates) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        result.deinit(failing.allocator());
        observed_success = true;
        break;
    }
    try std.testing.expect(observed_success);
}

test "declared source syntax maximum fits retained byte budget" {
    const worst = try retainedSize(max_spans, max_spans);
    try std.testing.expect(worst <= max_retained_bytes);
}

test "source syntax rejects candidate count beyond the declared maximum" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.alloc(u8, max_spans + 1);
    @memset(bytes, 'x');
    var document = try source_document.Document.initOwned(allocator, bytes, .init(bytes));
    defer document.deinit(allocator);
    const candidates = try allocator.alloc(Candidate, max_spans + 1);
    defer allocator.free(candidates);
    for (candidates, 0..) |*candidate, index| candidate.* = .{
        .line_index = 0,
        .span = .{ .start = index, .end = index + 1, .role = .variable },
    };
    try std.testing.expectError(
        error.SyntaxMetadataLimit,
        build(allocator, &document, candidates),
    );
}
