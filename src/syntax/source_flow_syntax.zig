//! flow-syntax adapter for one complete Repository source file.
//!
//! Unlike the Changes page's hunk-side adapter, Repository already owns a complete file.
//! One query cache, syntax instance, refresh, and render preserve cross-hunk
//! language context and avoid multiplying parser setup by the number of hunks.

const std = @import("std");
const flow_syntax = @import("flow_syntax");
const source_document = @import("../repository/source.zig");
const source_spans = @import("source.zig");
const token = @import("token.zig");

pub const RoleHistogram = [@typeInfo(token.TokenRole).@"enum".fields.len]usize;

pub const CapacityReport = struct {
    source_bytes: usize,
    content_lines: usize,
    diagnostic_limits: source_spans.Limits,
    raw_candidates: usize,
    retained_entries: usize,
    retained_spans: usize,
    retained_bytes: usize,
    raw_roles: RoleHistogram,
    retained_roles: RoleHistogram,
    production_decision: source_spans.ProductionDecision,
};

pub fn buildSourceSpans(
    allocator: std.mem.Allocator,
    io: std.Io,
    document: *const source_document.Document,
    path: []const u8,
) !source_spans.SourceSpans {
    if (document.bytes.len == 0) return .empty();
    var candidates = try collectCandidates(allocator, io, document, path);
    defer candidates.deinit(allocator);
    return source_spans.build(allocator, document, candidates.items);
}

/// Runs the production capture and sanitizer pipeline under a relaxed but
/// source-derived final-metadata ceiling. Raw provider candidates and
/// sanitizer temporaries intentionally retain production behavior; only the
/// resulting `SourceSpans` receives the diagnostic ceiling.
pub fn inspectSourceCapacity(
    allocator: std.mem.Allocator,
    io: std.Io,
    document: *const source_document.Document,
    path: []const u8,
) !CapacityReport {
    const diagnostic_limits = try source_spans.sourceDerivedDiagnosticLimits(document);
    if (document.bytes.len == 0) return .{
        .source_bytes = 0,
        .content_lines = 0,
        .diagnostic_limits = diagnostic_limits,
        .raw_candidates = 0,
        .retained_entries = 0,
        .retained_spans = 0,
        .retained_bytes = 0,
        .raw_roles = @splat(0),
        .retained_roles = @splat(0),
        .production_decision = .accept,
    };

    var candidates = try collectCandidates(allocator, io, document, path);
    defer candidates.deinit(allocator);
    var raw_roles: RoleHistogram = @splat(0);
    for (candidates.items) |candidate| raw_roles[@intFromEnum(candidate.span.role)] += 1;

    var limit_hit: ?source_spans.LimitKind = null;
    var spans = source_spans.buildWithLimitsReporting(
        allocator,
        document,
        candidates.items,
        diagnostic_limits,
        &limit_hit,
    ) catch |err| switch (err) {
        error.SyntaxMetadataLimit => return switch (limit_hit orelse return error.MissingDiagnosticLimit) {
            .entries => error.SyntaxDiagnosticEntryLimit,
            .spans => error.SyntaxDiagnosticSpanLimit,
            .bytes => error.SyntaxDiagnosticByteLimit,
        },
        else => return err,
    };
    defer spans.deinit(allocator);

    var retained_roles: RoleHistogram = @splat(0);
    for (spans.spans) |span| retained_roles[@intFromEnum(span.role)] += 1;
    return .{
        .source_bytes = document.bytes.len,
        .content_lines = document.contentLineCount(),
        .diagnostic_limits = diagnostic_limits,
        .raw_candidates = candidates.items.len,
        .retained_entries = spans.line_entries.len,
        .retained_spans = spans.spans.len,
        .retained_bytes = spans.retainedBytes(),
        .raw_roles = raw_roles,
        .retained_roles = retained_roles,
        .production_decision = try source_spans.productionDecision(spans.line_entries.len, spans.spans.len),
    };
}

fn collectCandidates(
    allocator: std.mem.Allocator,
    io: std.Io,
    document: *const source_document.Document,
    path: []const u8,
) !std.ArrayList(source_spans.Candidate) {
    const query_cache = try flow_syntax.QueryCache.create(io, allocator, .{});
    defer query_cache.deinit();
    var syntax = try flow_syntax.create_guess_file_type_static(allocator, document.bytes, path, query_cache);
    defer syntax.destroy();
    try syntax.refresh_full(document.bytes);

    var candidates: std.ArrayList(source_spans.Candidate) = .empty;
    errdefer candidates.deinit(allocator);
    var context: RenderContext = .{
        .allocator = allocator,
        .document = document,
        .candidates = &candidates,
    };
    syntax.render(&context, RenderContext.capture, flow_syntax.SimpleNonRegex(*RenderContext), null) catch |err| switch (err) {
        error.Stop => if (context.failure) |failure| return failure,
        else => return err,
    };
    return candidates;
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
        const role = token.roleFromScope(scope);
        if (capture_index != 0 and !token.isSemanticRefinement(role)) return;
        const start: usize = @intCast(range.start_byte);
        const end: usize = @intCast(range.end_byte);
        if (start >= end or start >= self.document.bytes.len) return;
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
    {
        const bytes = try allocator.dupe(u8,
            \\const Item = struct { name: []const u8 };
            \\fn read(item: Item) void {
            \\    _ = item.name;
            \\}
            \\
        );
        var document = try source_document.Document.initOwned(allocator, bytes, .init(bytes));
        defer document.deinit(allocator);
        var spans = try buildSourceSpans(allocator, std.testing.io, &document, "main.zig");
        defer spans.deinit(allocator);
        try std.testing.expect(spans.spans.len > 0);
        try std.testing.expect(spans.lineSpans(0).spans.len > 0);
        try std.testing.expect(roleTextCount(&document, spans, .parameter, "item") > 0);
        try std.testing.expect(roleTextCount(&document, spans, .member, "name") > 0);
    }

    {
        const bytes = try allocator.dupe(u8,
            \\fn read(value: crate::Point) {
            \\    let crate::Point { x } = value;
            \\    println!("{}", x);
            \\}
            \\
        );
        var document = try source_document.Document.initOwned(allocator, bytes, .init(bytes));
        defer document.deinit(allocator);
        var spans = try buildSourceSpans(allocator, std.testing.io, &document, "main.rs");
        defer spans.deinit(allocator);
        try std.testing.expect(roleTextCount(&document, spans, .constructor, "Point") > 0);
        try std.testing.expect(roleTextCount(&document, spans, .macro, "println") > 0);
        try std.testing.expect(roleTextCount(&document, spans, .macro, "!") > 0);
    }

    {
        const bytes = try allocator.dupe(u8, "const message = `Hello ${name}`;\n");
        var document = try source_document.Document.initOwned(allocator, bytes, .init(bytes));
        defer document.deinit(allocator);
        var spans = try buildSourceSpans(allocator, std.testing.io, &document, "main.js");
        defer spans.deinit(allocator);
        try std.testing.expect(roleTextCount(&document, spans, .special_punctuation, "${") > 0);
        try std.testing.expect(roleTextCount(&document, spans, .special_punctuation, "}") > 0);
    }

    {
        const bytes = try allocator.dupe(u8, "message = f\"Hello {name}\"\n");
        var document = try source_document.Document.initOwned(allocator, bytes, .init(bytes));
        defer document.deinit(allocator);
        var spans = try buildSourceSpans(allocator, std.testing.io, &document, "main.py");
        defer spans.deinit(allocator);
        try std.testing.expect(roleTextCount(&document, spans, .special_punctuation, "{") > 0);
        try std.testing.expect(roleTextCount(&document, spans, .special_punctuation, "}") > 0);
    }
}

fn roleTextCount(
    document: *const source_document.Document,
    spans: source_spans.SourceSpans,
    role: token.TokenRole,
    expected: []const u8,
) usize {
    var count: usize = 0;
    for (spans.line_entries) |entry| {
        const line = document.lineBody(entry.line_index) orelse continue;
        for (spans.lineSpans(entry.line_index).spans) |span| {
            if (span.role == role and std.mem.eql(u8, line[span.start..span.end], expected)) count += 1;
        }
    }
    return count;
}

test "flow syntax capacity inspection reports raw and retained roles" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, "const value: usize = 42;\n// comment\n");
    var document = try source_document.Document.initOwned(allocator, bytes, .init(bytes));
    defer document.deinit(allocator);
    const report = try inspectSourceCapacity(allocator, std.testing.io, &document, "main.zig");
    try std.testing.expectEqual(bytes.len, report.source_bytes);
    try std.testing.expectEqual(document.contentLineCount(), report.content_lines);
    try std.testing.expect(report.raw_candidates >= report.retained_spans);
    try std.testing.expect(report.retained_entries > 0);
    try std.testing.expect(report.retained_spans > 0);
    try std.testing.expectEqual(source_spans.ProductionDecision.accept, report.production_decision);
    try std.testing.expectEqual(@as(?usize, document.contentLineCount()), report.diagnostic_limits.entries);
    try std.testing.expectEqual(document.bytes.len, report.diagnostic_limits.spans);
    try std.testing.expectEqual(report.raw_candidates, histogramTotal(report.raw_roles));
    try std.testing.expectEqual(report.retained_spans, histogramTotal(report.retained_roles));
    try std.testing.expect(report.retained_roles[@intFromEnum(token.TokenRole.keyword)] > 0);
    try std.testing.expect(report.retained_roles[@intFromEnum(token.TokenRole.comment)] > 0);
}

test "flow syntax capacity inspection treats empty source as accepted zero metadata" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, "");
    var document = try source_document.Document.initOwned(allocator, bytes, .init(bytes));
    defer document.deinit(allocator);
    const report = try inspectSourceCapacity(allocator, std.testing.io, &document, "empty.zig");
    try std.testing.expectEqual(@as(usize, 0), report.raw_candidates);
    try std.testing.expectEqual(@as(usize, 0), report.retained_entries);
    try std.testing.expectEqual(@as(usize, 0), report.retained_spans);
    try std.testing.expectEqual(@as(usize, 0), report.retained_bytes);
    try std.testing.expectEqual(source_spans.ProductionDecision.accept, report.production_decision);
}

fn histogramTotal(histogram: RoleHistogram) usize {
    var total: usize = 0;
    for (histogram) |count| total += count;
    return total;
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
