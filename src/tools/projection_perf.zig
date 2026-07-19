//! Stage-level performance profiler for GitFrame's staged Review projection.
//!
//! This developer-only tool measures parse, flow-syntax, tree/cache construction,
//! and first-redraw costs from a recorded unified-diff patch. Its component-pair
//! mode compares the same normalized HEAD-to-working-tree presentation before and
//! after an index-only hunk move, including parse/projection/equality versus eager
//! decoration. Use it to compare Debug and ReleaseFast builds and to evaluate future
//! projection/provider changes. It is not a correctness test or a wall-clock
//! acceptance gate, and normal `zig build` and `zig build test` paths do not execute
//! it.
//!
//! Usage:
//!   zig build projection-perf -- <patch-file> [iterations]
//!   zig build projection-perf -Doptimize=ReleaseFast -- <patch-file> [iterations]
//!   zig build projection-perf -- --component-pair <before-cached> <before-unstaged> <after-cached> <after-unstaged> [iterations]
//!
//! Results report median and observed range for each stage. A checksum consumes the
//! generated model so optimized builds cannot discard the measured work. The
//! hunk-side syntax pipeline mirrors `syntax/provider_flow_syntax.zig` and must stay
//! synchronized when that production pipeline changes.

const std = @import("std");

const chasen = @import("chasen");
const diff_hunk_projection = @import("../diff/hunk_projection.zig");
const diff_parser = @import("../diff/parser.zig");
const presentation_identity = @import("../diff/presentation_identity.zig");
const diff_render = @import("../diff/render.zig");
const diff_view_model = @import("../diff/view_model.zig");
const file_tree = @import("../file_tree.zig");
const flow_syntax = @import("flow_syntax");
const provider = @import("../syntax/provider.zig");
const token = @import("../syntax/token.zig");

// This developer-only profiler mirrors `syntax/provider_flow_syntax.zig`'s
// hunk-side pipeline. It intentionally propagates non-OOM side errors and counts
// binary hunks in the reported shape even though both paths skip highlighting them.
const max_patch_bytes = 64 * 1024 * 1024;
const default_iterations = 7;
const max_iterations = 31;

const Phase = enum {
    parse_document,
    span_storage,
    query_cache,
    fragment,
    syntax_create,
    syntax_refresh,
    render_sanitize,
    tree_render_cache,
    first_redraw,
    total,
};

const phase_count = @typeInfo(Phase).@"enum".fields.len;
const Sample = [phase_count]u64;

const Stopwatch = struct {
    io: std.Io,
    start_ns: u64,

    fn start(io: std.Io) Stopwatch {
        return .{ .io = io, .start_ns = nowNs(io) };
    }

    fn read(self: Stopwatch) u64 {
        const end_ns = nowNs(self.io);
        return if (end_ns > self.start_ns) end_ns - self.start_ns else 0;
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len >= 2 and std.mem.eql(u8, args[1], "--component-pair")) {
        return profileComponentPairCommand(init, args);
    }
    if (args.len < 2 or args.len > 3) {
        printUsage();
        return error.InvalidArguments;
    }

    const iterations = if (args.len == 3)
        try std.fmt.parseUnsigned(usize, args[2], 10)
    else
        default_iterations;
    if (iterations == 0 or iterations > max_iterations) return error.InvalidIterationCount;

    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        args[1],
        init.gpa,
        .limited(max_patch_bytes),
    );
    defer init.gpa.free(bytes);

    var samples: [max_iterations]Sample = undefined;
    var shape: Shape = .{};
    var checksum: usize = 0;
    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.initWithAllocator(120, 40, std.heap.page_allocator);
    defer test_surface.deinit();
    for (samples[0..iterations]) |*sample| {
        sample.* = try profileOnce(init.gpa, init.io, bytes, &test_surface, &shape, &checksum);
    }

    std.debug.print(
        \\GitFrame staged projection profile
        \\  input: {s}
        \\  bytes: {d}
        \\  patch lines: {d}
        \\  files: {d}
        \\  hunks: {d}
        \\  highlighted sides: {d}
        \\  iterations: {d}
        \\  checksum: {d}
        \\
    , .{
        args[1],
        bytes.len,
        countLines(bytes),
        shape.files,
        shape.hunks,
        shape.highlighted_sides,
        iterations,
        checksum,
    });

    inline for (@typeInfo(Phase).@"enum".fields, 0..) |field, phase_index| {
        printSummary(field.name, samples[0..iterations], phase_index);
    }
}

fn printUsage() void {
    std.debug.print(
        \\usage:
        \\  zig build projection-perf -- <patch-file> [iterations]
        \\  zig build projection-perf -- --component-pair <before-cached> <before-unstaged> <after-cached> <after-unstaged> [iterations]
        \\
    , .{});
}

const Shape = struct {
    files: usize = 0,
    hunks: usize = 0,
    highlighted_sides: usize = 0,
};

const PairPhase = enum {
    component_parse,
    normalized_projection,
    presentation_fingerprint,
    presentation_equality,
    exact_reuse_construction,
    eager_decoration,
    eager_refresh_total,
};

const pair_phase_count = @typeInfo(PairPhase).@"enum".fields.len;
const PairSample = [pair_phase_count]u64;

const ComponentPairInput = struct {
    before_cached: []const u8,
    before_unstaged: []const u8,
    after_cached: []const u8,
    after_unstaged: []const u8,
};

const ComponentPairShape = struct {
    before_cached_hunks: usize = 0,
    before_unstaged_hunks: usize = 0,
    after_cached_hunks: usize = 0,
    after_unstaged_hunks: usize = 0,
    projected_hunks: usize = 0,
};

fn profileComponentPairCommand(init: std.process.Init, args: []const []const u8) !void {
    if (args.len < 6 or args.len > 7) {
        printUsage();
        return error.InvalidArguments;
    }

    const iterations = if (args.len == 7)
        try std.fmt.parseUnsigned(usize, args[6], 10)
    else
        default_iterations;
    if (iterations == 0 or iterations > max_iterations) return error.InvalidIterationCount;

    const before_cached = try readPatch(init, args[2]);
    defer init.gpa.free(before_cached);
    const before_unstaged = try readPatch(init, args[3]);
    defer init.gpa.free(before_unstaged);
    const after_cached = try readPatch(init, args[4]);
    defer init.gpa.free(after_cached);
    const after_unstaged = try readPatch(init, args[5]);
    defer init.gpa.free(after_unstaged);
    const input: ComponentPairInput = .{
        .before_cached = before_cached,
        .before_unstaged = before_unstaged,
        .after_cached = after_cached,
        .after_unstaged = after_unstaged,
    };

    var samples: [max_iterations]PairSample = undefined;
    var shape: ComponentPairShape = .{};
    var checksum: usize = 0;
    for (samples[0..iterations]) |*sample| {
        sample.* = try profileComponentPairOnce(init.gpa, init.io, input, &shape, &checksum);
    }

    std.debug.print(
        \\GitFrame index-only component-pair profile
        \\  before cached: {s} ({d} bytes, {d} hunks)
        \\  before unstaged: {s} ({d} bytes, {d} hunks)
        \\  after cached: {s} ({d} bytes, {d} hunks)
        \\  after unstaged: {s} ({d} bytes, {d} hunks)
        \\  normalized presentation hunks: {d}
        \\  raw component metadata differs: yes
        \\  canonical presentation equality: yes
        \\  iterations: {d}
        \\  checksum: {d}
        \\
    , .{
        args[2],
        before_cached.len,
        shape.before_cached_hunks,
        args[3],
        before_unstaged.len,
        shape.before_unstaged_hunks,
        args[4],
        after_cached.len,
        shape.after_cached_hunks,
        args[5],
        after_unstaged.len,
        shape.after_unstaged_hunks,
        shape.projected_hunks,
        iterations,
        checksum,
    });

    inline for (@typeInfo(PairPhase).@"enum".fields, 0..) |field, phase_index| {
        printPairSummary(field.name, samples[0..iterations], phase_index);
    }
}

fn readPatch(init: std.process.Init, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(max_patch_bytes));
}

fn profileComponentPairOnce(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: ComponentPairInput,
    shape: *ComponentPairShape,
    checksum: *usize,
) !PairSample {
    var sample: PairSample = @splat(0);
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // The retained presentation is setup rather than part of refresh timing.
    // P0 measures the work performed after an index-only action against it.
    const before_cached = try parseComponent(arena_allocator, input.before_cached);
    const before_unstaged = try parseComponent(arena_allocator, input.before_unstaged);
    const before_projection = try diff_hunk_projection.build(
        arena_allocator,
        try singleFile(before_cached),
        try singleFile(before_unstaged),
    );
    const before_fingerprint = presentation_identity.fingerprint(before_projection.file);

    var reuse_timer = Stopwatch.start(io);
    var timer = Stopwatch.start(io);
    const after_cached = try parseComponent(arena_allocator, input.after_cached);
    const after_unstaged = try parseComponent(arena_allocator, input.after_unstaged);
    sample[@intFromEnum(PairPhase.component_parse)] = timer.read();

    timer = Stopwatch.start(io);
    const after_projection = try diff_hunk_projection.build(
        arena_allocator,
        try singleFile(after_cached),
        try singleFile(after_unstaged),
    );
    sample[@intFromEnum(PairPhase.normalized_projection)] = timer.read();

    if (metadataEqual(before_projection.file.metadata, after_projection.file.metadata)) {
        return error.ComponentPairMetadataDidNotChange;
    }
    if (projectedStatesEqual(before_projection.hunk_states, after_projection.hunk_states)) {
        return error.ComponentPairAuthorityDidNotChange;
    }

    timer = Stopwatch.start(io);
    const after_fingerprint = presentation_identity.fingerprint(after_projection.file);
    sample[@intFromEnum(PairPhase.presentation_fingerprint)] = timer.read();
    if (!before_fingerprint.eql(after_fingerprint)) {
        return error.ComponentPairFingerprintMismatch;
    }

    timer = Stopwatch.start(io);
    const equal = presentation_identity.exactEqual(before_projection.file, after_projection.file);
    sample[@intFromEnum(PairPhase.presentation_equality)] = timer.read();
    if (!equal) return error.ComponentPairPresentationMismatch;
    sample[@intFromEnum(PairPhase.exact_reuse_construction)] = reuse_timer.read();

    timer = Stopwatch.start(io);
    try profileEagerComponentDecoration(arena_allocator, io, after_cached, checksum);
    try profileEagerComponentDecoration(arena_allocator, io, after_unstaged, checksum);
    sample[@intFromEnum(PairPhase.eager_decoration)] = timer.read();
    sample[@intFromEnum(PairPhase.eager_refresh_total)] = reuse_timer.read();

    shape.* = .{
        .before_cached_hunks = before_cached.totalHunks(),
        .before_unstaged_hunks = before_unstaged.totalHunks(),
        .after_cached_hunks = after_cached.totalHunks(),
        .after_unstaged_hunks = after_unstaged.totalHunks(),
        .projected_hunks = after_projection.file.hunks.len,
    };
    for (after_fingerprint.digest) |byte| checksum.* +%= byte;
    checksum.* +%= after_projection.file.hunks.len;
    return sample;
}

fn parseComponent(allocator: std.mem.Allocator, bytes: []const u8) !diff_parser.DiffDocument {
    return diff_parser.parse(allocator, try allocator.dupe(u8, bytes));
}

fn singleFile(document: diff_parser.DiffDocument) !diff_parser.FileDiff {
    if (document.files.len != 1) return error.ExpectedSingleFileComponent;
    return document.files[0];
}

fn profileEagerComponentDecoration(
    allocator: std.mem.Allocator,
    io: std.Io,
    document: diff_parser.DiffDocument,
    checksum: *usize,
) !void {
    var spans = try provider.allocateEmptyForDocument(allocator, document);
    const query_cache = try flow_syntax.QueryCache.create(io, allocator, .{});
    defer query_cache.deinit();

    var ignored_sample: Sample = @splat(0);
    var ignored_shape: Shape = .{ .files = document.files.len };
    for (document.files, 0..) |file, file_index| {
        ignored_shape.hunks += file.hunks.len;
        if (file.is_binary) continue;
        for (file.hunks, 0..) |hunk, hunk_index| {
            try profileHunkSide(allocator, io, &ignored_sample, &spans, query_cache, file, hunk, .{
                .file_index = file_index,
                .hunk_index = hunk_index,
                .side = .old,
            }, &ignored_shape, checksum);
            try profileHunkSide(allocator, io, &ignored_sample, &spans, query_cache, file, hunk, .{
                .file_index = file_index,
                .hunk_index = hunk_index,
                .side = .new,
            }, &ignored_shape, checksum);
        }
    }

    const tree = try file_tree.build(allocator, document);
    const rendered_line_cache = try diff_view_model.RenderedLineCache.build(allocator, document);
    checksum.* +%= tree.nodes.len;
    if (document.files.len != 0) {
        checksum.* +%= rendered_line_cache.indexFor(0, .side_by_side).?.lineCount();
    }
}

fn metadataEqual(lhs: []const []const u8, rhs: []const []const u8) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
}

fn projectedStatesEqual(
    lhs: []const diff_hunk_projection.ProjectedHunkState,
    rhs: []const diff_hunk_projection.ProjectedHunkState,
) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left, right| {
        if (left.state != right.state or !hunkOriginEqual(left.origin, right.origin)) return false;
    }
    return true;
}

fn hunkOriginEqual(lhs: diff_hunk_projection.HunkOrigin, rhs: diff_hunk_projection.HunkOrigin) bool {
    return switch (lhs) {
        .cached => |index| switch (rhs) {
            .cached => |other| index == other,
            .unstaged => false,
        },
        .unstaged => |index| switch (rhs) {
            .cached => false,
            .unstaged => |other| index == other,
        },
    };
}

fn profileOnce(
    allocator: std.mem.Allocator,
    io: std.Io,
    bytes: []const u8,
    test_surface: *chasen.testing.TestSurface,
    shape: *Shape,
    checksum: *usize,
) !Sample {
    var sample: Sample = @splat(0);
    var total_timer = Stopwatch.start(io);

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var timer = Stopwatch.start(io);
    const copied = try arena_allocator.dupe(u8, bytes);
    const document = try diff_parser.parse(arena_allocator, copied);
    sample[@intFromEnum(Phase.parse_document)] = timer.read();

    timer = Stopwatch.start(io);
    var spans = try provider.allocateEmptyForDocument(arena_allocator, document);
    sample[@intFromEnum(Phase.span_storage)] = timer.read();

    timer = Stopwatch.start(io);
    const query_cache = try flow_syntax.QueryCache.create(io, arena_allocator, .{});
    defer query_cache.deinit();
    sample[@intFromEnum(Phase.query_cache)] = timer.read();

    var run_shape: Shape = .{ .files = document.files.len };
    for (document.files, 0..) |file, file_index| {
        run_shape.hunks += file.hunks.len;
        if (file.is_binary) continue;
        for (file.hunks, 0..) |hunk, hunk_index| {
            try profileHunkSide(arena_allocator, io, &sample, &spans, query_cache, file, hunk, .{
                .file_index = file_index,
                .hunk_index = hunk_index,
                .side = .old,
            }, &run_shape, checksum);
            try profileHunkSide(arena_allocator, io, &sample, &spans, query_cache, file, hunk, .{
                .file_index = file_index,
                .hunk_index = hunk_index,
                .side = .new,
            }, &run_shape, checksum);
        }
    }

    timer = Stopwatch.start(io);
    const tree = try file_tree.build(arena_allocator, document);
    const rendered_line_cache = try diff_view_model.RenderedLineCache.build(arena_allocator, document);
    const collapsed_hunks = try arena_allocator.alloc(bool, document.totalHunks());
    @memset(collapsed_hunks, false);
    const visible_nodes = try materializeVisibleNodes(arena_allocator, tree);
    sample[@intFromEnum(Phase.tree_render_cache)] = timer.read();

    timer = Stopwatch.start(io);
    _ = test_surface.arena.reset(.retain_capacity);
    test_surface.surface.clearAll();
    if (document.files.len != 0) {
        try diff_render.renderFile(&test_surface.surface, document.files[0], .{
            .requested_mode = .side_by_side,
            .line_index = rendered_line_cache.indexFor(0, .side_by_side),
            .syntax = .initDirect(&spans, 0),
        });
    }
    sample[@intFromEnum(Phase.first_redraw)] = timer.read();

    checksum.* +%= tree.nodes.len + collapsed_hunks.len + visible_nodes.len;
    if (document.files.len != 0) {
        checksum.* +%= rendered_line_cache.indexFor(0, .side_by_side).?.lineCount();
    }
    shape.* = run_shape;
    sample[@intFromEnum(Phase.total)] = total_timer.read();
    return sample;
}

fn materializeVisibleNodes(allocator: std.mem.Allocator, tree: file_tree.FileTree) ![]usize {
    const visible_nodes = try allocator.alloc(usize, tree.nodes.len);
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

const HunkSideKey = struct {
    file_index: usize,
    hunk_index: usize,
    side: provider.Side,
};

fn profileHunkSide(
    allocator: std.mem.Allocator,
    io: std.Io,
    sample: *Sample,
    document_spans: *provider.DocumentSpans,
    query_cache: *flow_syntax.QueryCache,
    file: diff_parser.FileDiff,
    hunk: diff_parser.Hunk,
    key: HunkSideKey,
    shape: *Shape,
    checksum: *usize,
) !void {
    var timer = Stopwatch.start(io);
    const fragment = try provider.buildFragment(allocator, hunk, key.side);
    sample[@intFromEnum(Phase.fragment)] +%= timer.read();
    defer fragment.deinit(allocator);
    if (fragment.text.len == 0 or fragment.lines.len == 0) return;
    shape.highlighted_sides += 1;

    timer = Stopwatch.start(io);
    var syntax = try flow_syntax.create_guess_file_type_static(
        allocator,
        fragment.text,
        filePathForSide(file, key.side),
        query_cache,
    );
    sample[@intFromEnum(Phase.syntax_create)] +%= timer.read();
    defer syntax.destroy();

    timer = Stopwatch.start(io);
    try syntax.refresh_full(fragment.text);
    sample[@intFromEnum(Phase.syntax_refresh)] +%= timer.read();

    timer = Stopwatch.start(io);
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
        checksum.* +%= line_spans.spans.len;
        provider.putLineSpans(document_spans, .{
            .file_index = key.file_index,
            .hunk_index = key.hunk_index,
            .line_index = line_map.line_index,
            .side = key.side,
        }, line_spans);
    }
    sample[@intFromEnum(Phase.render_sanitize)] +%= timer.read();
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
        if (capture_index != 0) return;
        const role = token.roleFromScope(scope);
        provider.appendRangeSpans(self.allocator, self.line_maps, self.line_lists, .{
            .start = @intCast(range.start_byte),
            .end = @intCast(range.end_byte),
        }, role) catch {
            self.allocation_failed = true;
            return error.Stop;
        };
    }
};

fn printSummary(label: []const u8, samples: []const Sample, phase_index: usize) void {
    var values: [max_iterations]u64 = undefined;
    for (samples, 0..) |sample, index| values[index] = sample[phase_index];
    const sorted = values[0..samples.len];
    insertionSort(sorted);
    const median = sorted[sorted.len / 2];
    if (median < std.time.ns_per_us) {
        std.debug.print("  {s}: median {d} ns, range {d}..{d} ns\n", .{
            label,
            median,
            sorted[0],
            sorted[sorted.len - 1],
        });
        return;
    }
    std.debug.print("  {s}: median {d} us, range {d}..{d} us\n", .{
        label,
        median / std.time.ns_per_us,
        sorted[0] / std.time.ns_per_us,
        sorted[sorted.len - 1] / std.time.ns_per_us,
    });
}

fn printPairSummary(label: []const u8, samples: []const PairSample, phase_index: usize) void {
    var values: [max_iterations]u64 = undefined;
    for (samples, 0..) |sample, index| values[index] = sample[phase_index];
    const sorted = values[0..samples.len];
    insertionSort(sorted);
    const median = sorted[sorted.len / 2];
    if (median < std.time.ns_per_us) {
        std.debug.print("  {s}: median {d} ns, range {d}..{d} ns\n", .{
            label,
            median,
            sorted[0],
            sorted[sorted.len - 1],
        });
        return;
    }
    std.debug.print("  {s}: median {d} us, range {d}..{d} us\n", .{
        label,
        median / std.time.ns_per_us,
        sorted[0] / std.time.ns_per_us,
        sorted[sorted.len - 1] / std.time.ns_per_us,
    });
}

fn insertionSort(values: []u64) void {
    var index: usize = 1;
    while (index < values.len) : (index += 1) {
        const value = values[index];
        var cursor = index;
        while (cursor > 0 and values[cursor - 1] > value) : (cursor -= 1) {
            values[cursor] = values[cursor - 1];
        }
        values[cursor] = value;
    }
}

fn countLines(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    var count: usize = 0;
    for (bytes) |byte| if (byte == '\n') {
        count += 1;
    };
    return count + @intFromBool(bytes[bytes.len - 1] != '\n');
}

fn nowNs(io: std.Io) u64 {
    const ns = std.Io.Clock.now(.awake, io).nanoseconds;
    return @intCast(@max(ns, 0));
}
