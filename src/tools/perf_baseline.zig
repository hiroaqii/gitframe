const std = @import("std");

const chasen = @import("chasen");
const diff_parser = @import("../diff/parser.zig");
const diff_render = @import("../diff/render.zig");
const diff_search = @import("../diff/search.zig");
const diff_view_model = @import("../diff/view_model.zig");
const file_tree = @import("../file_tree.zig");

const huge_file_pairs = 8_000;
const no_match_pairs = 2_000;
const many_file_count = 3_000;
const huge_hunk_count = 100;
const render_width = 120;
const render_height = 40;
const render_iterations = 25;

const Stopwatch = struct {
    io: std.Io,
    start_ns: u64,

    fn start(io: std.Io) Stopwatch {
        return .{
            .io = io,
            .start_ns = nowNs(io),
        };
    }

    fn read(self: Stopwatch) u64 {
        const end_ns = nowNs(self.io);
        return if (end_ns > self.start_ns) end_ns - self.start_ns else 0;
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    std.debug.print("\nGitFrame performance baseline\n", .{});
    try runHugeFileScenario(allocator, io);
    try runManyFileScenario(allocator, io);
    try runNoMatchSearchScenario(allocator, io);
}

fn runHugeFileScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    var raw_timer = Stopwatch.start(io);
    const raw = try buildHugeFileDiff(allocator, huge_file_pairs);
    defer allocator.free(raw);
    const raw_ns = raw_timer.read();
    const loaded_model_capacity = try loadedModelArenaCapacity(allocator, raw);

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var parse_timer = Stopwatch.start(io);
    const document = try diff_parser.parse(arena.allocator(), raw);
    const parse_ns = parse_timer.read();
    const file = document.files[0];

    var cache_timer = Stopwatch.start(io);
    const cache = try diff_view_model.RenderedLineCache.build(arena.allocator(), document);
    const cache_ns = cache_timer.read();
    const line_index = cache.indexFor(0, .side_by_side).?;

    var count_timer = Stopwatch.start(io);
    const rows = line_index.lineCount();
    const count_ns = count_timer.read();

    const last_hunk_index = file.hunks.len - 1;
    var offset_timer = Stopwatch.start(io);
    const offset = line_index.hunkOffset(last_hunk_index);
    const offset_ns = offset_timer.read();

    const body_rows = diff_render.visibleBodyRows(render_height);
    const scroll = rows -| body_rows;

    var traverse_timer = Stopwatch.start(io);
    const visible_rows = traverseVisibleBodyRows(file, .side_by_side, line_index, scroll, body_rows);
    const traverse_ns = traverse_timer.read();

    var ts: chasen.testing.TestSurface = undefined;
    try ts.initWithAllocator(render_width, render_height, std.heap.page_allocator);
    defer ts.deinit();

    _ = try renderVisibleBodyRows(&ts, file, line_index, scroll);

    var render_timer = Stopwatch.start(io);
    var iteration: usize = 0;
    while (iteration < render_iterations) : (iteration += 1) {
        _ = try renderVisibleBodyRows(&ts, file, line_index, scroll);
    }
    const render_ns = render_timer.read();

    std.debug.print("\n[huge single file: {d} replacement rows]\n", .{huge_file_pairs});
    printTiming("fixture build", raw_ns);
    printTiming("parse", parse_ns);
    printTiming("rendered line cache build", cache_ns);
    printTiming("cached rendered row count", count_ns);
    printTiming("cached hunk offset lookup", offset_ns);
    printTiming("indexed visible row traversal near end", traverse_ns);
    printTiming("headless side-by-side render near end", render_ns / render_iterations);
    std.debug.print("  rows: {d}, last hunk offset: {d}, visible rows: {d}\n", .{ rows, offset, visible_rows });
    std.debug.print("  render surface: {d}x{d}, body rows: {d}, iterations: {d}\n", .{
        render_width,
        render_height,
        body_rows,
        render_iterations,
    });
    printMemory("raw diff bytes", raw.len);
    printMemory("loaded model arena capacity", loaded_model_capacity);
}

fn runManyFileScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    var raw_timer = Stopwatch.start(io);
    const raw = try buildManyFileDiff(allocator, many_file_count);
    defer allocator.free(raw);
    const raw_ns = raw_timer.read();
    const loaded_model_capacity = try loadedModelArenaCapacity(allocator, raw);

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var parse_timer = Stopwatch.start(io);
    const document = try diff_parser.parse(arena.allocator(), raw);
    const parse_ns = parse_timer.read();

    var tree_timer = Stopwatch.start(io);
    const tree = try file_tree.build(arena.allocator(), document);
    const tree_ns = tree_timer.read();

    var cache_timer = Stopwatch.start(io);
    const cache = try diff_view_model.RenderedLineCache.build(arena.allocator(), document);
    const cache_ns = cache_timer.read();

    var collapsed: file_tree.CollapsedSet = .empty;
    defer collapsed.deinit(allocator);

    var visible_timer = Stopwatch.start(io);
    const visible_count = tree.visibleNodeCount(&collapsed);
    const visible_ns = visible_timer.read();

    std.debug.print("\n[many files: {d} files]\n", .{many_file_count});
    printTiming("fixture build", raw_ns);
    printTiming("parse", parse_ns);
    printTiming("file tree build", tree_ns);
    printTiming("rendered line cache build", cache_ns);
    printTiming("visible node count", visible_ns);
    std.debug.print("  files: {d}, tree nodes: {d}, visible nodes: {d}\n", .{
        document.files.len,
        tree.nodes.len,
        visible_count,
    });
    std.debug.print("  first file cached rows: {d}\n", .{cache.indexFor(0, .side_by_side).?.lineCount()});
    printMemory("raw diff bytes", raw.len);
    printMemory("loaded model arena capacity", loaded_model_capacity);
}

fn runNoMatchSearchScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const raw = try buildHugeFileDiff(allocator, no_match_pairs);
    defer allocator.free(raw);
    const loaded_model_capacity = try loadedModelArenaCapacity(allocator, raw);

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    const document = try diff_parser.parse(arena.allocator(), raw);
    const file = document.files[0];

    var search_timer = Stopwatch.start(io);
    const match = diff_search.findMatch(file, .side_by_side, "zz-no-match", null, .forward);
    const search_ns = search_timer.read();

    std.debug.print("\n[no-match search: {d} replacement rows]\n", .{no_match_pairs});
    printTiming("side-by-side no-match search", search_ns);
    std.debug.print("  match: {s}\n", .{if (match == null) "none" else "found"});
    printMemory("raw diff bytes", raw.len);
    printMemory("loaded model arena capacity", loaded_model_capacity);
}

fn loadedModelArenaCapacity(allocator: std.mem.Allocator, raw: []const u8) !usize {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const copied = try arena_allocator.dupe(u8, raw);
    const document = try diff_parser.parse(arena_allocator, copied);
    const tree = try file_tree.build(arena_allocator, document);
    const rendered_line_cache = try diff_view_model.RenderedLineCache.build(arena_allocator, document);
    const collapsed_hunks = try arena_allocator.alloc(bool, document.totalHunks());
    @memset(collapsed_hunks, false);
    const visible_nodes = try materializeVisibleNodes(arena_allocator, tree);

    // Keep the construction intentionally close to DiffLoadTask.buildLoadedBundle:
    // the values are arena-owned and only their retained capacity is measured.
    _ = rendered_line_cache;
    _ = visible_nodes;

    return arena.queryCapacity();
}

fn materializeVisibleNodes(allocator: std.mem.Allocator, tree: file_tree.FileTree) ![]usize {
    var visible_nodes = try allocator.alloc(usize, tree.nodes.len);
    var collapsed: file_tree.CollapsedSet = .empty;
    defer collapsed.deinit(allocator);

    var count: usize = 0;
    for (tree.nodes, 0..) |_, index| {
        if (!tree.isVisible(index, &collapsed)) continue;
        visible_nodes[count] = index;
        count += 1;
    }

    return visible_nodes[0..count];
}

fn buildHugeFileDiff(allocator: std.mem.Allocator, pairs: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const hunk_count = @min(huge_hunk_count, pairs);
    const base_pairs_per_hunk = pairs / hunk_count;
    const extra_pairs = pairs % hunk_count;

    try append(&out, allocator, "diff --git a/src/huge.zig b/src/huge.zig\n");
    try append(&out, allocator, "index 1111111..2222222 100644\n");
    try append(&out, allocator, "--- a/src/huge.zig\n");
    try append(&out, allocator, "+++ b/src/huge.zig\n");

    var line_number: usize = 1;
    var hunk_index: usize = 0;
    while (hunk_index < hunk_count) : (hunk_index += 1) {
        const pairs_in_hunk = base_pairs_per_hunk + @intFromBool(hunk_index < extra_pairs);
        try appendFmt(&out, allocator, "@@ -{d},{d} +{d},{d} @@ fn huge_{d}()\n", .{
            line_number,
            pairs_in_hunk,
            line_number,
            pairs_in_hunk,
            hunk_index,
        });

        var pair_index: usize = 0;
        while (pair_index < pairs_in_hunk) : (pair_index += 1) {
            const global_index = line_number + pair_index - 1;
            try appendFmt(&out, allocator, "-old generated line {d}\n", .{global_index});
            try appendFmt(&out, allocator, "+new generated line {d}\n", .{global_index});
        }

        line_number += pairs_in_hunk;
    }

    return out.toOwnedSlice(allocator);
}

fn buildManyFileDiff(allocator: std.mem.Allocator, file_count: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (index < file_count) : (index += 1) {
        try appendFmt(&out, allocator, "diff --git a/src/dir{d}/file{d}.zig b/src/dir{d}/file{d}.zig\n", .{
            index % 100,
            index,
            index % 100,
            index,
        });
        try appendFmt(&out, allocator, "--- a/src/dir{d}/file{d}.zig\n", .{ index % 100, index });
        try appendFmt(&out, allocator, "+++ b/src/dir{d}/file{d}.zig\n", .{ index % 100, index });
        try append(&out, allocator, "@@ -1 +1 @@\n");
        try append(&out, allocator, "-old\n");
        try append(&out, allocator, "+new\n");
    }

    return out.toOwnedSlice(allocator);
}

fn traverseVisibleBodyRows(
    file: diff_parser.FileDiff,
    mode: diff_view_model.DisplayMode,
    line_index: diff_view_model.RenderedLineIndex,
    scroll: usize,
    height: usize,
) usize {
    var iter = diff_view_model.BodyRowIterator.initAt(file, mode, line_index, scroll);
    var visible_rows: usize = 0;

    while (iter.next()) |_| {
        if (visible_rows >= height) break;
        visible_rows += 1;
    }

    return visible_rows;
}

fn renderVisibleBodyRows(
    ts: *chasen.testing.TestSurface,
    file: diff_parser.FileDiff,
    line_index: diff_view_model.RenderedLineIndex,
    scroll: usize,
) !usize {
    _ = ts.arena.reset(.retain_capacity);
    ts.surface.clearAll();
    try diff_render.renderFile(&ts.surface, file, .{
        .requested_mode = .side_by_side,
        .scroll = scroll,
        .line_index = line_index,
    });

    return diff_render.visibleBodyRows(render_height);
}

fn append(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    try out.appendSlice(allocator, text);
}

fn appendFmt(out: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    var buf: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, fmt, args);
    try out.appendSlice(allocator, text);
}

fn printTiming(label: []const u8, ns: u64) void {
    std.debug.print("  {s}: {d} us\n", .{ label, ns / std.time.ns_per_us });
}

fn printMemory(label: []const u8, bytes: usize) void {
    std.debug.print("  {s}: {d} KiB\n", .{ label, bytes / 1024 });
}

fn nowNs(io: std.Io) u64 {
    const ns = std.Io.Clock.now(.awake, io).nanoseconds;
    if (ns <= 0) return 0;
    return std.math.lossyCast(u64, ns);
}
