const std = @import("std");
const diff_parser = @import("../diff/parser.zig");
const flow_syntax = @import("flow_syntax");
const provider = @import("provider.zig");
const token = @import("token.zig");
const text_eligibility = @import("../diff/text_eligibility.zig");

// `tools/projection_perf.zig` measures this hunk-side pipeline by calling the
// stage helpers below directly; no instrumentation lives in this module.
pub fn buildDocumentSpans(allocator: std.mem.Allocator, io: std.Io, document: diff_parser.DiffDocument, eligibility: []const text_eligibility.FileTextEligibility) !provider.DocumentSpans {
    std.debug.assert(eligibility.len == document.files.len);
    var spans = try provider.allocateEmptyForDocument(allocator, document);
    errdefer spans.deinit(allocator);

    // Keep flow-syntax state task-local for the first integration. QueryCache
    // construction is not free, but sharing it across chasen tasks would add
    // a lifetime and locking contract before this provider has settled.
    const query_cache = try flow_syntax.QueryCache.create(io, allocator, .{});
    defer query_cache.deinit();

    for (document.files, 0..) |file, file_index| {
        if (file.is_binary or !eligibility[file_index].selectable()) continue;
        for (file.hunks, 0..) |hunk, hunk_index| {
            highlightHunkSide(allocator, &spans, query_cache, file, hunk, .{
                .file_index = file_index,
                .hunk_index = hunk_index,
                .side = .old,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            };
            highlightHunkSide(allocator, &spans, query_cache, file, hunk, .{
                .file_index = file_index,
                .hunk_index = hunk_index,
                .side = .new,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            };
        }
    }

    return spans;
}

pub const HunkSideKey = struct {
    file_index: usize,
    hunk_index: usize,
    side: provider.Side,
};

fn highlightHunkSide(
    allocator: std.mem.Allocator,
    document_spans: *provider.DocumentSpans,
    query_cache: *flow_syntax.QueryCache,
    file: diff_parser.FileDiff,
    hunk: diff_parser.Hunk,
    key: HunkSideKey,
) !void {
    const fragment = try provider.buildFragment(allocator, hunk, key.side);
    defer fragment.deinit(allocator);
    if (fragment.text.len == 0 or fragment.lines.len == 0) return;

    var syntax = try createHunkSideSyntax(allocator, fragment.text, file, key.side, query_cache);
    defer syntax.destroy();
    try syntax.refresh_full(fragment.text);

    try renderAndStoreHunkSideSpans(allocator, document_spans, syntax, fragment, key);
}

/// Stage helper shared with the projection profiler: guesses the file type
/// for one hunk side and creates its flow-syntax instance.
pub fn createHunkSideSyntax(
    allocator: std.mem.Allocator,
    fragment_text: []const u8,
    file: diff_parser.FileDiff,
    side: provider.Side,
    query_cache: *flow_syntax.QueryCache,
) !*flow_syntax {
    return flow_syntax.create_guess_file_type_static(allocator, fragment_text, filePathForSide(file, side), query_cache);
}

/// Stage helper shared with the projection profiler: renders the fragment's
/// spans, sanitizes them per line, and stores them under `key`.
pub fn renderAndStoreHunkSideSpans(
    allocator: std.mem.Allocator,
    document_spans: *provider.DocumentSpans,
    syntax: *flow_syntax,
    fragment: provider.Fragment,
    key: HunkSideKey,
) !void {
    const line_lists = try allocator.alloc(std.ArrayList(token.TokenSpan), fragment.lines.len);
    defer allocator.free(line_lists);
    for (line_lists) |*list| list.* = .empty;
    defer for (line_lists) |*list| list.deinit(allocator);

    var ctx: RenderContext = .{
        .allocator = allocator,
        .line_maps = fragment.lines,
        .line_lists = line_lists,
    };
    syntax.render(&ctx, RenderContext.capture, flow_syntax.SimpleNonRegex(*RenderContext), null) catch |err| switch (err) {
        error.Stop => if (ctx.allocation_failed) return error.OutOfMemory,
        else => return err,
    };

    for (fragment.lines, 0..) |line_map, index| {
        const line_spans = try token.sanitizeLineSpans(allocator, line_map.text, line_lists[index].items);
        provider.putLineSpans(document_spans, .{
            .file_index = key.file_index,
            .hunk_index = key.hunk_index,
            .line_index = line_map.line_index,
            .side = key.side,
        }, line_spans);
    }
}

fn filePathForSide(file: diff_parser.FileDiff, side: provider.Side) ?[]const u8 {
    return switch (side) {
        .old => file.old_path orelse file.new_path,
        .new => file.new_path orelse file.old_path,
    };
}

const RenderContext = struct {
    allocator: std.mem.Allocator,
    line_maps: []const provider.FragmentLine,
    line_lists: []std.ArrayList(token.TokenSpan),
    allocation_failed: bool = false,

    fn capture(
        self: *RenderContext,
        range: flow_syntax.Range,
        scope: []const u8,
        _: u32,
        capture_index: usize,
        _: *const flow_syntax.Node,
    ) error{Stop}!void {
        const role = token.roleFromScope(scope);
        // Preserve the established first-capture behavior for generic scopes,
        // but retain later detailed captures such as the closing delimiter of
        // an interpolation or the punctuation in a macro invocation.
        if (capture_index != 0 and !token.isSemanticRefinement(role)) return;
        provider.appendRangeSpans(self.allocator, self.line_maps, self.line_lists, .{
            .start = @intCast(range.start_byte),
            .end = @intCast(range.end_byte),
        }, role) catch {
            self.allocation_failed = true;
            return error.Stop;
        };
    }
};

test "mixed eligibility skips invalid files without shifting valid span indices" {
    const invalid_lines = [_]diff_parser.DiffLine{.{
        .kind = .added,
        .text = "bad\xff",
        .new_line = 1,
    }};
    const valid_lines = [_]diff_parser.DiffLine{
        .{ .kind = .added, .text = "const Item = struct { name: []const u8 };", .new_line = 1 },
        .{ .kind = .added, .text = "fn read(item: Item) void {", .new_line = 2 },
        .{ .kind = .added, .text = "    _ = item.name;", .new_line = 3 },
        .{ .kind = .added, .text = "}", .new_line = 4 },
    };
    const files = [_]diff_parser.FileDiff{
        .{
            .header = "diff --git a/invalid.zig b/invalid.zig",
            .old_path = "a/invalid.zig",
            .new_path = "b/invalid.zig",
            .metadata = &.{},
            .hunks = &.{.{
                .old_start = 1,
                .old_count = 0,
                .new_start = 1,
                .new_count = 1,
                .section = "",
                .lines = &invalid_lines,
            }},
        },
        .{
            .header = "diff --git a/valid.zig b/valid.zig",
            .old_path = "a/valid.zig",
            .new_path = "b/valid.zig",
            .metadata = &.{},
            .hunks = &.{.{
                .old_start = 1,
                .old_count = 0,
                .new_start = 1,
                .new_count = valid_lines.len,
                .section = "",
                .lines = &valid_lines,
            }},
        },
    };
    const eligibility = [_]text_eligibility.FileTextEligibility{ .inert_invalid_utf8, .selectable_utf8 };
    var spans = try buildDocumentSpans(std.testing.allocator, std.testing.io, .{ .files = &files }, &eligibility);
    defer spans.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), spans.files.len);
    try std.testing.expectEqual(@as(usize, 0), spans.lineSpans(.{
        .file_index = 0,
        .hunk_index = 0,
        .line_index = 0,
        .side = .new,
    }).spans.len);
    const valid = spans.lineSpans(.{
        .file_index = 1,
        .hunk_index = 0,
        .line_index = 0,
        .side = .new,
    });
    try std.testing.expect(valid.spans.len > 0);
    try std.testing.expectEqual(token.TokenRole.keyword, valid.spans[0].role);
    try std.testing.expect(lineHasRoleText(valid_lines[1].text, spans.lineSpans(.{
        .file_index = 1,
        .hunk_index = 0,
        .line_index = 1,
        .side = .new,
    }), .parameter, "item"));
    try std.testing.expect(lineHasRoleText(valid_lines[2].text, spans.lineSpans(.{
        .file_index = 1,
        .hunk_index = 0,
        .line_index = 2,
        .side = .new,
    }), .member, "name"));
}

fn lineHasRoleText(line: []const u8, spans: token.LineSpans, role: token.TokenRole, expected: []const u8) bool {
    for (spans.spans) |span| {
        if (span.role == role and std.mem.eql(u8, line[span.start..span.end], expected)) return true;
    }
    return false;
}
