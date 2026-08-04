//! Developer profiler for Repository full-file syntax decoration.
//!
//! The tool runs the production flow-syntax source adapter in the same no-cache
//! A -> B -> A sequence used when a user selects two files and revisits the first.
//! It records evidence for cache decisions; it is not a correctness test or a
//! wall-clock acceptance gate, and normal build/test paths do not execute it.
//!
//! Usage:
//!   zig build source-syntax-perf -- <file-a> <file-b> [iterations]
//!   zig build source-syntax-perf -Doptimize=ReleaseFast -- <file-a> <file-b> [iterations]

const std = @import("std");
const selected_document = @import("../repository/document.zig");
const source_document = @import("../repository/source.zig");
const source_adapter = @import("../syntax/source_flow_syntax.zig");

const default_iterations = 7;
const max_iterations = 31;

const Sample = struct {
    first_a_ns: u64,
    file_b_ns: u64,
    revisit_a_ns: u64,
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3 or args.len > 4) {
        std.debug.print("usage: zig build source-syntax-perf -- <file-a> <file-b> [iterations]\n", .{});
        return error.InvalidArguments;
    }
    const iterations = if (args.len == 4)
        try std.fmt.parseUnsigned(usize, args[3], 10)
    else
        default_iterations;
    if (iterations == 0 or iterations > max_iterations) return error.InvalidIterationCount;

    const bytes_a = try readSource(init.gpa, init.io, args[1]);
    defer init.gpa.free(bytes_a);
    const bytes_b = try readSource(init.gpa, init.io, args[2]);
    defer init.gpa.free(bytes_b);

    var samples: [max_iterations]Sample = undefined;
    var checksum: usize = 0;
    for (samples[0..iterations]) |*sample| {
        sample.first_a_ns = try profileSource(init.gpa, init.io, args[1], bytes_a, &checksum);
        sample.file_b_ns = try profileSource(init.gpa, init.io, args[2], bytes_b, &checksum);
        sample.revisit_a_ns = try profileSource(init.gpa, init.io, args[1], bytes_a, &checksum);
    }

    std.debug.print(
        \\GitFrame Repository source syntax profile
        \\  file A: {s} ({d} bytes)
        \\  file B: {s} ({d} bytes)
        \\  iterations: {d}
        \\  checksum: {d}
        \\
    , .{ args[1], bytes_a.len, args[2], bytes_b.len, iterations, checksum });
    printSummary("A first parse", samples[0..iterations], .first_a_ns);
    printSummary("B parse", samples[0..iterations], .file_b_ns);
    printSummary("A revisit (no cache)", samples[0..iterations], .revisit_a_ns);
}

fn readSource(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(selected_document.max_text_bytes));
}

fn profileSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    bytes: []const u8,
    checksum: *usize,
) !u64 {
    const started = nowNs(io);
    const owned = try allocator.dupe(u8, bytes);
    var document = try source_document.Document.initOwnedOrFree(allocator, owned, .init(owned));
    defer document.deinit(allocator);
    var spans = try source_adapter.buildSourceSpans(allocator, io, &document, path);
    defer spans.deinit(allocator);
    checksum.* +%= spans.line_entries.len + spans.spans.len;
    const finished = nowNs(io);
    return if (finished > started) finished - started else 0;
}

const Field = enum { first_a_ns, file_b_ns, revisit_a_ns };

fn printSummary(label: []const u8, samples: []const Sample, comptime field: Field) void {
    var values: [max_iterations]u64 = undefined;
    for (samples, 0..) |sample, index| values[index] = @field(sample, @tagName(field));
    const sorted = values[0..samples.len];
    std.mem.sort(u64, sorted, {}, std.sort.asc(u64));
    const median = sorted[sorted.len / 2];
    std.debug.print("  {s}: median {d} us, range {d}..{d} us\n", .{
        label,
        median / std.time.ns_per_us,
        sorted[0] / std.time.ns_per_us,
        sorted[sorted.len - 1] / std.time.ns_per_us,
    });
}

fn nowNs(io: std.Io) u64 {
    const nanoseconds = std.Io.Clock.now(.awake, io).nanoseconds;
    return @intCast(@max(nanoseconds, 0));
}
