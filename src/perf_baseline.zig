const std = @import("std");

const diff_parser = @import("diff_parser.zig");
const diff_search = @import("diff_search.zig");
const diff_view_model = @import("diff_view_model.zig");
const file_tree = @import("file_tree.zig");

const huge_file_pairs = 8_000;
const no_match_pairs = 2_000;
const many_file_count = 3_000;
const huge_hunk_count = 100;

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

    var traverse_timer = Stopwatch.start(io);
    const visible_rows = traverseVisibleBodyRows(file, .side_by_side, line_index, rows -| 40, 40);
    const traverse_ns = traverse_timer.read();

    std.debug.print("\n[huge single file: {d} replacement rows]\n", .{huge_file_pairs});
    printTiming("fixture build", raw_ns);
    printTiming("parse", parse_ns);
    printTiming("rendered line cache build", cache_ns);
    printTiming("cached rendered row count", count_ns);
    printTiming("cached hunk offset lookup", offset_ns);
    printTiming("indexed visible row traversal near end", traverse_ns);
    std.debug.print("  rows: {d}, last hunk offset: {d}, visible rows: {d}\n", .{ rows, offset, visible_rows });
}

fn runManyFileScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    var raw_timer = Stopwatch.start(io);
    const raw = try buildManyFileDiff(allocator, many_file_count);
    defer allocator.free(raw);
    const raw_ns = raw_timer.read();

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
}

fn runNoMatchSearchScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const raw = try buildHugeFileDiff(allocator, no_match_pairs);
    defer allocator.free(raw);

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

fn nowNs(io: std.Io) u64 {
    const ns = std.Io.Clock.now(.awake, io).nanoseconds;
    if (ns <= 0) return 0;
    return std.math.lossyCast(u64, ns);
}
