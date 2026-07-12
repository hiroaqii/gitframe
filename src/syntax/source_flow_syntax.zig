//! flow-syntax adapter for one complete Repository source file.
//!
//! Unlike Review's hunk-side adapter, Repository already owns a complete file.
//! One query cache, syntax instance, refresh, and render preserve cross-hunk
//! language context and avoid multiplying parser setup by the number of hunks.

const std = @import("std");
const flow_syntax = @import("flow_syntax");
const source_document = @import("../repository/source.zig");
const source_spans = @import("source.zig");
const token = @import("token.zig");

pub fn buildSourceSpans(
    allocator: std.mem.Allocator,
    io: std.Io,
    document: *const source_document.Document,
    path: []const u8,
) !source_spans.SourceSpans {
    if (document.bytes.len == 0) return .empty();
    const query_cache = try flow_syntax.QueryCache.create(io, allocator, .{});
    defer query_cache.deinit();
    var syntax = try flow_syntax.create_guess_file_type_static(allocator, document.bytes, path, query_cache);
    defer syntax.destroy();
    try syntax.refresh_full(document.bytes);

    var candidates: std.ArrayList(source_spans.Candidate) = .empty;
    defer candidates.deinit(allocator);
    var context: RenderContext = .{
        .allocator = allocator,
        .document = document,
        .candidates = &candidates,
    };
    syntax.render(&context, RenderContext.capture, flow_syntax.SimpleNonRegex(*RenderContext), null) catch |err| switch (err) {
        error.Stop => if (context.failure) |failure| return failure,
        else => return err,
    };
    return source_spans.build(allocator, document, candidates.items);
}

const RenderContext = struct {
    allocator: std.mem.Allocator,
    document: *const source_document.Document,
    candidates: *std.ArrayList(source_spans.Candidate),
    failure: ?anyerror = null,

    fn capture(
        self: *RenderContext,
        range: flow_syntax.Range,
        scope: []const u8,
        _: u32,
        capture_index: usize,
        _: *const flow_syntax.Node,
    ) error{Stop}!void {
        if (capture_index != 0) return;
        const start: usize = @intCast(range.start_byte);
        const end: usize = @intCast(range.end_byte);
        if (start >= end or start >= self.document.bytes.len) return;
        const role = token.roleFromScope(scope);
        if (role == .plain) return;
        self.appendRange(start, @min(end, self.document.bytes.len), role) catch |err| {
            self.failure = err;
            return error.Stop;
        };
    }

    fn appendRange(self: *RenderContext, start: usize, end: usize, role: token.TokenRole) !void {
        var line_index = lineIndexForByte(self.document.line_starts, start);
        while (line_index < self.document.contentLineCount()) : (line_index += 1) {
            const line_start: usize = self.document.line_starts[line_index];
            if (line_start >= end) break;
            const line = self.document.lineBody(line_index).?;
            const line_end = line_start + line.len;
            const clipped_start = @max(start, line_start);
            const clipped_end = @min(end, line_end);
            if (clipped_start >= clipped_end) continue;
            try self.candidates.append(self.allocator, .{
                .line_index = line_index,
                .span = .{
                    .start = clipped_start - line_start,
                    .end = clipped_end - line_start,
                    .role = role,
                },
            });
        }
    }
};

fn lineIndexForByte(starts: []const u32, byte_offset: usize) usize {
    var low: usize = 0;
    var high = starts.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (starts[middle] <= byte_offset) low = middle + 1 else high = middle;
    }
    return if (low == 0) 0 else low - 1;
}

test "source syntax byte lookup selects the containing logical line" {
    const starts = [_]u32{ 0, 4, 10 };
    try std.testing.expectEqual(@as(usize, 0), lineIndexForByte(&starts, 0));
    try std.testing.expectEqual(@as(usize, 0), lineIndexForByte(&starts, 3));
    try std.testing.expectEqual(@as(usize, 1), lineIndexForByte(&starts, 4));
    try std.testing.expectEqual(@as(usize, 2), lineIndexForByte(&starts, 100));
}

test "flow syntax builds source-shaped spans from one full file instance" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, "const value: usize = 42;\n// comment\n");
    var document = try source_document.Document.initOwned(allocator, bytes, .init(bytes));
    defer document.deinit(allocator);
    var spans = try buildSourceSpans(allocator, std.testing.io, &document, "main.zig");
    defer spans.deinit(allocator);
    try std.testing.expect(spans.spans.len > 0);
    try std.testing.expect(spans.lineSpans(0).spans.len > 0);
}

test "flow syntax splits multiline captures into CRLF-safe line spans" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, "/* first\r\n * second */\r\nint value = 1;\r\n");
    var document = try source_document.Document.initOwned(allocator, bytes, .init(bytes));
    defer document.deinit(allocator);
    var spans = try buildSourceSpans(allocator, std.testing.io, &document, "main.c");
    defer spans.deinit(allocator);
    try std.testing.expect(spans.lineSpans(0).spans.len > 0);
    try std.testing.expect(spans.lineSpans(1).spans.len > 0);
    var found_comment = false;
    for (spans.line_entries) |entry| {
        const line = document.lineBody(entry.line_index).?;
        for (spans.lineSpans(entry.line_index).spans) |span| {
            if (span.role == .comment) found_comment = true;
            try std.testing.expect(span.start < span.end);
            try std.testing.expect(span.end <= line.len);
            try std.testing.expect(std.mem.indexOfScalar(u8, line[span.start..span.end], '\r') == null);
            try std.testing.expect(std.mem.indexOfScalar(u8, line[span.start..span.end], '\n') == null);
        }
    }
    try std.testing.expect(found_comment);
}
