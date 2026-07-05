const std = @import("std");
const diff_parser = @import("../diff/parser.zig");
const flow_syntax = @import("flow_syntax");
const provider = @import("provider.zig");

pub fn buildDocumentSpans(allocator: std.mem.Allocator, io: std.Io, document: diff_parser.DiffDocument) !provider.DocumentSpans {
    var spans = try provider.allocateEmptyForDocument(allocator, document);
    errdefer spans.deinit(allocator);

    // Keep flow-syntax state task-local for the first integration. QueryCache
    // construction is not free, but sharing it across chasen tasks would add
    // a lifetime and locking contract before this provider has settled.
    const query_cache = try flow_syntax.QueryCache.create(io, allocator, .{});
    defer query_cache.deinit();

    for (document.files, 0..) |file, file_index| {
        if (file.is_binary) continue;
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

const HunkSideKey = struct {
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

    var syntax = try flow_syntax.create_guess_file_type_static(allocator, fragment.text, filePathForSide(file, key.side), query_cache);
    defer syntax.destroy();
    try syntax.refresh_full(fragment.text);

    const line_lists = try allocator.alloc(std.ArrayList(provider.TokenSpan), fragment.lines.len);
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
        const line_spans = try provider.sanitizeLineSpans(allocator, line_map.text, line_lists[index].items);
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
    line_lists: []std.ArrayList(provider.TokenSpan),
    allocation_failed: bool = false,

    fn capture(
        self: *RenderContext,
        range: flow_syntax.Range,
        scope: []const u8,
        _: u32,
        capture_index: usize,
        _: *const flow_syntax.Node,
    ) error{Stop}!void {
        // Capture groups often include nested scopes. Keep the outermost range
        // for now so overlapping captures do not churn colors within one token.
        if (capture_index != 0) return;
        const role = provider.roleFromScope(scope);
        provider.appendRangeSpans(self.allocator, self.line_maps, self.line_lists, .{
            .start = @intCast(range.start_byte),
            .end = @intCast(range.end_byte),
        }, role) catch {
            self.allocation_failed = true;
            return error.Stop;
        };
    }
};
