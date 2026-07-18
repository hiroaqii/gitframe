const std = @import("std");
const path_key = @import("../path_key.zig");
const diff_parser = @import("parser.zig");
const diff_view_model = @import("view_model.zig");

pub const HunkStageState = enum {
    staged,
    unstaged,
};

pub const HunkOrigin = union(enum) {
    cached: usize,
    unstaged: usize,
};

pub const ProjectedHunkState = struct {
    state: HunkStageState,
    origin: HunkOrigin,
};

pub const Projection = struct {
    file: diff_parser.FileDiff,
    hunk_states: []const ProjectedHunkState,
    unified_line_index: diff_view_model.RenderedLineIndex,
    side_by_side_line_index: diff_view_model.RenderedLineIndex,

    pub fn lineIndex(self: Projection, mode: diff_view_model.DisplayMode) diff_view_model.RenderedLineIndex {
        return switch (mode) {
            .unified => self.unified_line_index,
            .side_by_side => self.side_by_side_line_index,
        };
    }
};

pub const BuildError = error{
    UnsupportedFile,
    AmbiguousProjection,
    OutOfMemory,
};

const Source = enum {
    cached,
    unstaged,
};

/// One hunk candidate projected into index-side coordinates.
///
/// Cached diff is HEAD->index, unstaged diff is index->worktree, so this
/// module never compares HEAD-side and worktree-side line numbers directly.
const Candidate = struct {
    source: Source,
    hunk_index: usize,
    hunk: diff_parser.Hunk,
    range: ChangedRange,
};

const ChangedRange = struct {
    start: u32,
    end: u32,

    fn overlaps(self: ChangedRange, other: ChangedRange) bool {
        return self.start < other.end and other.start < self.end;
    }
};

pub fn build(
    allocator: std.mem.Allocator,
    cached_file: diff_parser.FileDiff,
    unstaged_file: diff_parser.FileDiff,
) BuildError!Projection {
    try validateFile(cached_file);
    try validateFile(unstaged_file);

    var candidates: std.ArrayList(Candidate) = .empty;
    defer candidates.deinit(allocator);

    try appendCandidates(allocator, &candidates, cached_file, .cached);
    try appendCandidates(allocator, &candidates, unstaged_file, .unstaged);
    if (candidates.items.len == 0) return error.AmbiguousProjection;

    std.mem.sort(Candidate, candidates.items, {}, lessThanCandidate);
    for (candidates.items[1..], 1..) |candidate, index| {
        const previous = candidates.items[index - 1];
        if (candidate.range.start == previous.range.start) return error.AmbiguousProjection;
        if (candidate.range.overlaps(previous.range)) return error.AmbiguousProjection;
    }

    const hunks = try allocator.alloc(diff_parser.Hunk, candidates.items.len);
    errdefer allocator.free(hunks);
    const states = try allocator.alloc(ProjectedHunkState, candidates.items.len);
    errdefer allocator.free(states);

    // Hunk structs are copied into the projection, but their line slices still
    // borrow from the original cached/unstaged loaded bundles. The caller must
    // keep those bundles alive as long as this Projection is displayed.
    for (candidates.items, 0..) |candidate, index| {
        hunks[index] = candidate.hunk;
        states[index] = switch (candidate.source) {
            .cached => .{ .state = .staged, .origin = .{ .cached = candidate.hunk_index } },
            .unstaged => .{ .state = .unstaged, .origin = .{ .unstaged = candidate.hunk_index } },
        };
    }

    const file: diff_parser.FileDiff = .{
        .header = unstaged_file.header,
        .old_path = unstaged_file.old_path orelse cached_file.old_path,
        .new_path = unstaged_file.new_path orelse cached_file.new_path,
        .metadata = unstaged_file.metadata,
        .hunks = hunks,
        .is_binary = false,
    };

    return .{
        .file = file,
        .hunk_states = states,
        .unified_line_index = try diff_view_model.RenderedLineIndex.build(allocator, file, .unified),
        .side_by_side_line_index = try diff_view_model.RenderedLineIndex.build(allocator, file, .side_by_side),
    };
}

fn validateFile(file: diff_parser.FileDiff) BuildError!void {
    if (file.is_binary) return error.UnsupportedFile;
    if (file.hunks.len == 0) return error.UnsupportedFile;
    if (!sameRepoPath(file.old_path, file.new_path)) return error.UnsupportedFile;
}

fn appendCandidates(
    allocator: std.mem.Allocator,
    candidates: *std.ArrayList(Candidate),
    file: diff_parser.FileDiff,
    source: Source,
) BuildError!void {
    for (file.hunks, 0..) |hunk, hunk_index| {
        const range = changedIndexRange(hunk, source) orelse return error.AmbiguousProjection;
        try candidates.append(allocator, .{
            .source = source,
            .hunk_index = hunk_index,
            .hunk = hunk,
            .range = range,
        });
    }
}

fn changedIndexRange(hunk: diff_parser.Hunk, source: Source) ?ChangedRange {
    var start: ?u32 = null;
    var end: u32 = 0;

    for (hunk.lines) |line| {
        const index_line = switch (source) {
            .cached => switch (line.kind) {
                .added => line.new_line,
                // A removal in HEAD->index has no surviving index-side line.
                // Keep it anchored to the hunk's index-side start so overlap
                // checks stay conservative instead of pretending the HEAD
                // coordinate is comparable to unstaged old-side coordinates.
                .removed => hunk.new_start,
                else => null,
            },
            .unstaged => switch (line.kind) {
                // An addition in index->worktree has no index-side line.
                // Treat it as a point at the index-side hunk start.
                .added => hunk.old_start,
                .removed => line.old_line,
                else => null,
            },
        } orelse continue;

        const one_past = index_line + 1;
        if (start == null or index_line < start.?) start = index_line;
        if (one_past > end) end = one_past;
    }

    const first = start orelse return null;
    if (first >= end) return null;
    return .{ .start = first, .end = end };
}

fn lessThanCandidate(_: void, lhs: Candidate, rhs: Candidate) bool {
    return lhs.range.start < rhs.range.start;
}

fn sameRepoPath(old_path: ?[]const u8, new_path: ?[]const u8) bool {
    const old = old_path orelse return false;
    const new = new_path orelse return false;
    return std.mem.eql(u8, path_key.stripGitSidePrefix(old), path_key.stripGitSidePrefix(new));
}

const CoordinateTransformError = error{
    InvalidCoordinate,
    UnmappableCoordinate,
    OutOfMemory,
};

/// A maximal non-context edit expressed as boundaries between existing lines.
///
/// Hunk header ranges include context and can contain several independent edit
/// runs. Keeping the exact old/new boundaries of each run lets the combined
/// projection distinguish unchanged counterpart lines from changed lines that
/// must not be paired by position or text.
const EditSegment = struct {
    old_before_gap: u32,
    old_after_gap: u32,
    new_before_gap: u32,
    new_after_gap: u32,
};

const GapBias = enum {
    before,
    after,
};

const GapAnchor = struct {
    position: u32,
    bias: GapBias,
};

const TransformDirection = enum {
    forward,
    inverse,
};

/// A checked, provider-independent line-coordinate transform for one component
/// diff (HEAD<->index or index<->working tree).
///
/// The transform deliberately has no full-file line count. Production callers
/// may pass only coordinates obtained from Git hunk headers and parser-validated
/// DiffLine values; this type validates their local segment relationships and
/// never performs file I/O to discover an otherwise unknown EOF.
const CoordinateTransform = struct {
    segments: []const EditSegment,

    fn deinit(self: CoordinateTransform, allocator: std.mem.Allocator) void {
        allocator.free(self.segments);
    }

    fn mapLineForward(self: CoordinateTransform, line: u32) CoordinateTransformError!u32 {
        return self.mapLine(line, .forward);
    }

    fn mapLineInverse(self: CoordinateTransform, line: u32) CoordinateTransformError!u32 {
        return self.mapLine(line, .inverse);
    }

    fn mapGapForward(self: CoordinateTransform, anchor: GapAnchor) CoordinateTransformError!u32 {
        return self.mapGap(anchor, .forward);
    }

    fn mapGapInverse(self: CoordinateTransform, anchor: GapAnchor) CoordinateTransformError!u32 {
        return self.mapGap(anchor, .inverse);
    }

    fn mapLine(self: CoordinateTransform, line: u32, direction: TransformDirection) CoordinateTransformError!u32 {
        if (line == 0) return error.InvalidCoordinate;

        var accumulated_delta: i64 = 0;
        for (self.segments) |segment| {
            const source_before = segmentBoundary(segment, direction, .source_before);
            const source_after = segmentBoundary(segment, direction, .source_after);
            if (line <= source_before) break;
            if (line <= source_after) return error.UnmappableCoordinate;
            accumulated_delta = try deltaAfterSegment(accumulated_delta, segment, direction);
        }
        return translateCoordinate(line, accumulated_delta);
    }

    fn mapGap(self: CoordinateTransform, anchor: GapAnchor, direction: TransformDirection) CoordinateTransformError!u32 {
        var accumulated_delta: i64 = 0;
        var boundary_before: ?u32 = null;
        var boundary_after: ?u32 = null;

        for (self.segments) |segment| {
            const source_before = segmentBoundary(segment, direction, .source_before);
            const source_after = segmentBoundary(segment, direction, .source_after);
            const target_before = segmentBoundary(segment, direction, .target_before);
            const target_after = segmentBoundary(segment, direction, .target_after);

            if (anchor.position < source_before) break;
            if (anchor.position > source_after) {
                accumulated_delta = try deltaAfterSegment(accumulated_delta, segment, direction);
                continue;
            }
            if (anchor.position > source_before and anchor.position < source_after) {
                return error.UnmappableCoordinate;
            }

            if (source_before == source_after) {
                // Consecutive zero-width edits at one source gap form one
                // before/after choice. Segment-entry validation guarantees
                // that their target boundaries join without a hidden gap.
                if (boundary_after) |previous| {
                    if (previous != target_before) return error.InvalidCoordinate;
                } else {
                    boundary_before = target_before;
                }
                boundary_after = target_after;
                accumulated_delta = try deltaAfterSegment(accumulated_delta, segment, direction);
                continue;
            }

            const mapped_boundary = if (anchor.position == source_before) target_before else target_after;
            if (boundary_after) |previous| {
                if (previous != mapped_boundary) return error.InvalidCoordinate;
            } else {
                boundary_before = mapped_boundary;
            }
            boundary_after = mapped_boundary;

            if (anchor.position == source_after) {
                accumulated_delta = try deltaAfterSegment(accumulated_delta, segment, direction);
                continue;
            }
            break;
        }

        if (boundary_before) |before| {
            const after = boundary_after orelse before;
            return switch (anchor.bias) {
                .before => before,
                .after => after,
            };
        }
        return translateCoordinate(anchor.position, accumulated_delta);
    }
};

const SegmentBoundary = enum {
    source_before,
    source_after,
    target_before,
    target_after,
};

fn segmentBoundary(segment: EditSegment, direction: TransformDirection, boundary: SegmentBoundary) u32 {
    return switch (direction) {
        .forward => switch (boundary) {
            .source_before => segment.old_before_gap,
            .source_after => segment.old_after_gap,
            .target_before => segment.new_before_gap,
            .target_after => segment.new_after_gap,
        },
        .inverse => switch (boundary) {
            .source_before => segment.new_before_gap,
            .source_after => segment.new_after_gap,
            .target_before => segment.old_before_gap,
            .target_after => segment.old_after_gap,
        },
    };
}

fn deltaAfterSegment(accumulated_delta: i64, segment: EditSegment, direction: TransformDirection) CoordinateTransformError!i64 {
    const source_width = segmentBoundary(segment, direction, .source_after) - segmentBoundary(segment, direction, .source_before);
    const target_width = segmentBoundary(segment, direction, .target_after) - segmentBoundary(segment, direction, .target_before);
    const segment_delta = @as(i64, target_width) - @as(i64, source_width);
    return std.math.add(i64, accumulated_delta, segment_delta) catch error.InvalidCoordinate;
}

fn translateCoordinate(coordinate: u32, delta: i64) CoordinateTransformError!u32 {
    const translated = std.math.add(i64, @as(i64, coordinate), delta) catch return error.InvalidCoordinate;
    if (translated < 0 or translated > std.math.maxInt(u32)) return error.InvalidCoordinate;
    return @intCast(translated);
}

const PendingEdit = struct {
    old_before_gap: u32,
    new_before_gap: u32,
};

fn buildCoordinateTransform(allocator: std.mem.Allocator, hunks: []const diff_parser.Hunk) CoordinateTransformError!CoordinateTransform {
    var segments: std.ArrayList(EditSegment) = .empty;
    errdefer segments.deinit(allocator);

    var accumulated_delta: i64 = 0;
    for (hunks) |hunk| try appendHunkEditSegments(allocator, &segments, &accumulated_delta, hunk);

    const owned_segments = try segments.toOwnedSlice(allocator);
    errdefer allocator.free(owned_segments);
    const transform: CoordinateTransform = .{ .segments = owned_segments };
    try validateContextWitnesses(transform, hunks);
    return transform;
}

fn appendHunkEditSegments(
    allocator: std.mem.Allocator,
    segments: *std.ArrayList(EditSegment),
    accumulated_delta: *i64,
    hunk: diff_parser.Hunk,
) CoordinateTransformError!void {
    const initial_old_gap = try initialGap(hunk.old_start, hunk.old_count);
    const initial_new_gap = try initialGap(hunk.new_start, hunk.new_count);
    var old_gap = initial_old_gap;
    var new_gap = initial_new_gap;
    var pending: ?PendingEdit = null;

    for (hunk.lines) |line| switch (line.kind) {
        .context => {
            try closePendingEdit(allocator, segments, accumulated_delta, &pending, old_gap, new_gap);
            old_gap = try consumeExistingLine(line.old_line, old_gap);
            new_gap = try consumeExistingLine(line.new_line, new_gap);
        },
        .removed => {
            if (line.new_line != null) return error.InvalidCoordinate;
            if (pending == null) pending = .{ .old_before_gap = old_gap, .new_before_gap = new_gap };
            old_gap = try consumeExistingLine(line.old_line, old_gap);
        },
        .added => {
            if (line.old_line != null) return error.InvalidCoordinate;
            if (pending == null) pending = .{ .old_before_gap = old_gap, .new_before_gap = new_gap };
            new_gap = try consumeExistingLine(line.new_line, new_gap);
        },
        .metadata => {
            if (line.old_line != null or line.new_line != null) return error.InvalidCoordinate;
        },
    };

    try closePendingEdit(allocator, segments, accumulated_delta, &pending, old_gap, new_gap);
    if (old_gap != try addCount(initial_old_gap, hunk.old_count)) return error.InvalidCoordinate;
    if (new_gap != try addCount(initial_new_gap, hunk.new_count)) return error.InvalidCoordinate;
}

fn initialGap(start: u32, count: u32) CoordinateTransformError!u32 {
    if (count == 0) return start;
    if (start == 0) return error.InvalidCoordinate;
    return start - 1;
}

fn consumeExistingLine(actual: ?u32, current_gap: u32) CoordinateTransformError!u32 {
    const expected = std.math.add(u32, current_gap, 1) catch return error.InvalidCoordinate;
    if (actual == null or actual.? != expected) return error.InvalidCoordinate;
    return expected;
}

fn addCount(initial_gap: u32, count: u32) CoordinateTransformError!u32 {
    return std.math.add(u32, initial_gap, count) catch error.InvalidCoordinate;
}

fn closePendingEdit(
    allocator: std.mem.Allocator,
    segments: *std.ArrayList(EditSegment),
    accumulated_delta: *i64,
    pending: *?PendingEdit,
    old_gap: u32,
    new_gap: u32,
) CoordinateTransformError!void {
    const start = pending.* orelse return;
    const segment: EditSegment = .{
        .old_before_gap = start.old_before_gap,
        .old_after_gap = old_gap,
        .new_before_gap = start.new_before_gap,
        .new_after_gap = new_gap,
    };
    if (segment.old_before_gap == segment.old_after_gap and segment.new_before_gap == segment.new_after_gap) {
        return error.InvalidCoordinate;
    }
    if (segment.old_after_gap < segment.old_before_gap or segment.new_after_gap < segment.new_before_gap) {
        return error.InvalidCoordinate;
    }

    if (segments.items.len > 0) {
        const previous = segments.items[segments.items.len - 1];
        if (segment.old_before_gap < previous.old_after_gap or segment.new_before_gap < previous.new_after_gap) {
            return error.InvalidCoordinate;
        }
    }

    const expected_new_before = try translateCoordinate(segment.old_before_gap, accumulated_delta.*);
    if (segment.new_before_gap != expected_new_before) return error.InvalidCoordinate;
    const next_delta = try deltaAfterSegment(accumulated_delta.*, segment, .forward);
    const expected_new_after = try translateCoordinate(segment.old_after_gap, next_delta);
    if (segment.new_after_gap != expected_new_after) return error.InvalidCoordinate;

    try segments.append(allocator, segment);
    accumulated_delta.* = next_delta;
    pending.* = null;
}

fn validateContextWitnesses(transform: CoordinateTransform, hunks: []const diff_parser.Hunk) CoordinateTransformError!void {
    for (hunks) |hunk| for (hunk.lines) |line| {
        if (line.kind != .context) continue;
        const old_line = line.old_line orelse return error.InvalidCoordinate;
        const new_line = line.new_line orelse return error.InvalidCoordinate;
        const forward = transform.mapLineForward(old_line) catch return error.InvalidCoordinate;
        const inverse = transform.mapLineInverse(new_line) catch return error.InvalidCoordinate;
        if (forward != new_line or inverse != old_line) return error.InvalidCoordinate;
    };
}

fn parseOneFile(arena: *std.heap.ArenaAllocator, text: []const u8) !diff_parser.FileDiff {
    const copied = try arena.allocator().dupe(u8, text);
    const document = try diff_parser.parse(arena.allocator(), copied);
    try std.testing.expectEqual(@as(usize, 1), document.files.len);
    return document.files[0];
}

fn expectInsertedGapMapping(transform: CoordinateTransform, source_gap: u32, target_gap: u32, width: u32) !void {
    try std.testing.expect(width > 0);
    const target_after = target_gap + width;

    try std.testing.expectEqual(target_gap, try transform.mapGapForward(.{ .position = source_gap, .bias = .before }));
    try std.testing.expectEqual(target_after, try transform.mapGapForward(.{ .position = source_gap, .bias = .after }));
    try std.testing.expectEqual(source_gap, try transform.mapGapInverse(.{ .position = target_gap, .bias = .before }));
    try std.testing.expectEqual(source_gap, try transform.mapGapInverse(.{ .position = target_gap, .bias = .after }));
    try std.testing.expectEqual(source_gap, try transform.mapGapInverse(.{ .position = target_after, .bias = .before }));
    try std.testing.expectEqual(source_gap, try transform.mapGapInverse(.{ .position = target_after, .bias = .after }));

    var interior = target_gap + 1;
    while (interior < target_after) : (interior += 1) {
        try std.testing.expectError(error.UnmappableCoordinate, transform.mapGapInverse(.{ .position = interior, .bias = .before }));
        try std.testing.expectError(error.UnmappableCoordinate, transform.mapGapInverse(.{ .position = interior, .bias = .after }));
    }
}

fn expectDeletedGapMapping(transform: CoordinateTransform, source_gap: u32, target_gap: u32, width: u32) !void {
    try std.testing.expect(width > 0);
    const source_after = source_gap + width;

    try std.testing.expectEqual(target_gap, try transform.mapGapForward(.{ .position = source_gap, .bias = .before }));
    try std.testing.expectEqual(target_gap, try transform.mapGapForward(.{ .position = source_gap, .bias = .after }));
    try std.testing.expectEqual(target_gap, try transform.mapGapForward(.{ .position = source_after, .bias = .before }));
    try std.testing.expectEqual(target_gap, try transform.mapGapForward(.{ .position = source_after, .bias = .after }));
    try std.testing.expectEqual(source_gap, try transform.mapGapInverse(.{ .position = target_gap, .bias = .before }));
    try std.testing.expectEqual(source_after, try transform.mapGapInverse(.{ .position = target_gap, .bias = .after }));

    var interior = source_gap + 1;
    while (interior < source_after) : (interior += 1) {
        try std.testing.expectError(error.UnmappableCoordinate, transform.mapGapForward(.{ .position = interior, .bias = .before }));
        try std.testing.expectError(error.UnmappableCoordinate, transform.mapGapForward(.{ .position = interior, .bias = .after }));
    }
}

test "coordinate transform extracts maximal edit segments and preserves context witnesses" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const file = try parseOneFile(&arena,
        \\diff --git a/src/app.zig b/src/app.zig
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -10,6 +10,6 @@
        \\ context 10
        \\-old 11
        \\\ No newline at end of file
        \\+new 11
        \\ context 12
        \\+inserted 13
        \\ context 13
        \\-removed 14
        \\ context 15
        \\
    );

    const transform = try buildCoordinateTransform(std.testing.allocator, file.hunks);
    defer transform.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), transform.segments.len);
    try std.testing.expectEqualDeep(EditSegment{
        .old_before_gap = 10,
        .old_after_gap = 11,
        .new_before_gap = 10,
        .new_after_gap = 11,
    }, transform.segments[0]);
    try std.testing.expectEqualDeep(EditSegment{
        .old_before_gap = 12,
        .old_after_gap = 12,
        .new_before_gap = 12,
        .new_after_gap = 13,
    }, transform.segments[1]);
    try std.testing.expectEqualDeep(EditSegment{
        .old_before_gap = 13,
        .old_after_gap = 14,
        .new_before_gap = 14,
        .new_after_gap = 14,
    }, transform.segments[2]);

    try std.testing.expectEqual(@as(u32, 10), try transform.mapLineForward(10));
    try std.testing.expectEqual(@as(u32, 12), try transform.mapLineForward(12));
    try std.testing.expectEqual(@as(u32, 14), try transform.mapLineForward(13));
    try std.testing.expectEqual(@as(u32, 15), try transform.mapLineForward(15));
    try std.testing.expectEqual(@as(u32, 13), try transform.mapLineInverse(14));
    try std.testing.expectError(error.UnmappableCoordinate, transform.mapLineForward(11));
    try std.testing.expectError(error.UnmappableCoordinate, transform.mapLineInverse(11));
    try std.testing.expectError(error.UnmappableCoordinate, transform.mapLineInverse(13));
    try std.testing.expectError(error.UnmappableCoordinate, transform.mapLineForward(14));

    try std.testing.expectEqual(@as(u32, 12), try transform.mapGapForward(.{ .position = 12, .bias = .before }));
    try std.testing.expectEqual(@as(u32, 13), try transform.mapGapForward(.{ .position = 12, .bias = .after }));
    try std.testing.expectEqual(@as(u32, 14), try transform.mapGapForward(.{ .position = 13, .bias = .before }));
    try std.testing.expectEqual(@as(u32, 14), try transform.mapGapForward(.{ .position = 14, .bias = .after }));
    try std.testing.expectEqual(@as(u32, 13), try transform.mapGapInverse(.{ .position = 14, .bias = .before }));
    try std.testing.expectEqual(@as(u32, 14), try transform.mapGapInverse(.{ .position = 14, .bias = .after }));
}

test "coordinate transform maps zero-width segments after accumulated positive deltas" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const file = try parseOneFile(&arena,
        \\diff --git a/src/app.zig b/src/app.zig
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -0,0 +1,2 @@
        \\+first
        \\+second
        \\@@ -5,0 +8,1 @@
        \\+third
        \\@@ -10,0 +14,3 @@
        \\+fourth
        \\+fifth
        \\+sixth
        \\
    );

    const transform = try buildCoordinateTransform(std.testing.allocator, file.hunks);
    defer transform.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), transform.segments.len);
    try expectInsertedGapMapping(transform, 0, 0, 2);
    try expectInsertedGapMapping(transform, 5, 7, 1);
    try expectInsertedGapMapping(transform, 10, 13, 3);

    try std.testing.expectEqual(@as(u32, 3), try transform.mapLineForward(1));
    try std.testing.expectEqual(@as(u32, 7), try transform.mapLineForward(5));
    try std.testing.expectEqual(@as(u32, 9), try transform.mapLineForward(6));
    try std.testing.expectEqual(@as(u32, 13), try transform.mapLineForward(10));
    try std.testing.expectEqual(@as(u32, 17), try transform.mapLineForward(11));
    try std.testing.expectError(error.UnmappableCoordinate, transform.mapLineInverse(1));
    try std.testing.expectError(error.UnmappableCoordinate, transform.mapLineInverse(8));
    try std.testing.expectError(error.UnmappableCoordinate, transform.mapLineInverse(15));
}

test "coordinate transform maps collapsed gaps after accumulated negative deltas" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const file = try parseOneFile(&arena,
        \\diff --git a/src/app.zig b/src/app.zig
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -1,2 +0,0 @@
        \\-first
        \\-second
        \\@@ -6,1 +3,0 @@
        \\-sixth
        \\@@ -10,2 +6,0 @@
        \\-tenth
        \\-eleventh
        \\
    );

    const transform = try buildCoordinateTransform(std.testing.allocator, file.hunks);
    defer transform.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), transform.segments.len);
    try expectDeletedGapMapping(transform, 0, 0, 2);
    try expectDeletedGapMapping(transform, 5, 3, 1);
    try expectDeletedGapMapping(transform, 9, 6, 2);

    try std.testing.expectEqual(@as(u32, 1), try transform.mapLineForward(3));
    try std.testing.expectEqual(@as(u32, 4), try transform.mapLineForward(7));
    try std.testing.expectEqual(@as(u32, 7), try transform.mapLineForward(12));
    try std.testing.expectEqual(@as(u32, 3), try transform.mapLineInverse(1));
    try std.testing.expectError(error.UnmappableCoordinate, transform.mapLineForward(1));
    try std.testing.expectError(error.UnmappableCoordinate, transform.mapLineForward(6));
    try std.testing.expectError(error.UnmappableCoordinate, transform.mapLineForward(10));
}

test "coordinate transform maps insertions after one and multiple negative deltas" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const file = try parseOneFile(&arena,
        \\diff --git a/src/app.zig b/src/app.zig
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -1,1 +0,0 @@
        \\-first deletion
        \\@@ -3,0 +3,1 @@
        \\+insertion after one negative delta
        \\@@ -6,1 +5,0 @@
        \\-second deletion
        \\@@ -8,2 +6,0 @@
        \\-third deletion
        \\-fourth deletion
        \\@@ -12,0 +10,2 @@
        \\+insertion after multiple negative deltas one
        \\+insertion after multiple negative deltas two
        \\
    );

    const transform = try buildCoordinateTransform(std.testing.allocator, file.hunks);
    defer transform.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 5), transform.segments.len);
    try expectInsertedGapMapping(transform, 3, 2, 1);
    try expectInsertedGapMapping(transform, 12, 9, 2);
    // The first deletion and following insertion return the accumulated delta
    // to zero; the next segment must still use its stored 5 -> 5 boundary.
    try expectDeletedGapMapping(transform, 5, 5, 1);
}

test "coordinate transform maps deletions after one and multiple positive deltas" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const file = try parseOneFile(&arena,
        \\diff --git a/src/app.zig b/src/app.zig
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -0,0 +1,1 @@
        \\+first insertion
        \\@@ -4,1 +4,0 @@
        \\-deletion after one positive delta
        \\@@ -6,0 +7,2 @@
        \\+second insertion
        \\+third insertion
        \\@@ -8,0 +11,1 @@
        \\+fourth insertion
        \\@@ -13,2 +15,0 @@
        \\-deletion after multiple positive deltas one
        \\-deletion after multiple positive deltas two
        \\
    );

    const transform = try buildCoordinateTransform(std.testing.allocator, file.hunks);
    defer transform.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 5), transform.segments.len);
    try expectDeletedGapMapping(transform, 3, 4, 1);
    try expectDeletedGapMapping(transform, 12, 15, 2);
    // The first insertion and following deletion return the accumulated delta
    // to zero; the next segment must still use its stored 6 -> 6 boundary.
    try expectInsertedGapMapping(transform, 6, 6, 2);
}

test "coordinate transform combines touching zero-width edits by gap bias" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const file = try parseOneFile(&arena,
        \\diff --git a/src/app.zig b/src/app.zig
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -5,0 +6,1 @@
        \\+first
        \\@@ -5,0 +7,1 @@
        \\+second
        \\
    );

    const transform = try buildCoordinateTransform(std.testing.allocator, file.hunks);
    defer transform.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 5), try transform.mapGapForward(.{ .position = 5, .bias = .before }));
    try std.testing.expectEqual(@as(u32, 7), try transform.mapGapForward(.{ .position = 5, .bias = .after }));
    try std.testing.expectEqual(@as(u32, 5), try transform.mapGapInverse(.{ .position = 6, .bias = .before }));
    try std.testing.expectEqual(@as(u32, 5), try transform.mapGapInverse(.{ .position = 6, .bias = .after }));
}

test "coordinate transform rejects malformed coordinates and discontinuous segment deltas" {
    const bad_context_lines = [_]diff_parser.DiffLine{.{
        .kind = .context,
        .text = "bad",
        .old_line = 2,
        .new_line = 1,
    }};
    const bad_context_hunk: diff_parser.Hunk = .{
        .old_start = 1,
        .old_count = 1,
        .new_start = 1,
        .new_count = 1,
        .section = "",
        .lines = &bad_context_lines,
    };
    try std.testing.expectError(error.InvalidCoordinate, buildCoordinateTransform(std.testing.allocator, &.{bad_context_hunk}));

    const bad_metadata_lines = [_]diff_parser.DiffLine{.{
        .kind = .metadata,
        .text = "metadata",
        .old_line = 1,
        .new_line = null,
    }};
    const bad_metadata_hunk: diff_parser.Hunk = .{
        .old_start = 0,
        .old_count = 0,
        .new_start = 0,
        .new_count = 0,
        .section = "",
        .lines = &bad_metadata_lines,
    };
    try std.testing.expectError(error.InvalidCoordinate, buildCoordinateTransform(std.testing.allocator, &.{bad_metadata_hunk}));

    const bad_count_lines = [_]diff_parser.DiffLine{.{
        .kind = .context,
        .text = "short",
        .old_line = 1,
        .new_line = 1,
    }};
    const bad_count_hunk: diff_parser.Hunk = .{
        .old_start = 1,
        .old_count = 2,
        .new_start = 1,
        .new_count = 1,
        .section = "",
        .lines = &bad_count_lines,
    };
    try std.testing.expectError(error.InvalidCoordinate, buildCoordinateTransform(std.testing.allocator, &.{bad_count_hunk}));

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const discontinuous = try parseOneFile(&arena,
        \\diff --git a/src/app.zig b/src/app.zig
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -0,0 +1,1 @@
        \\+first
        \\@@ -5,1 +5,1 @@
        \\-old
        \\+new
        \\
    );
    try std.testing.expectError(error.InvalidCoordinate, buildCoordinateTransform(std.testing.allocator, discontinuous.hunks));
}

test "coordinate transform checks numeric bounds without claiming an EOF bound" {
    const identity: CoordinateTransform = .{ .segments = &.{} };
    try std.testing.expectError(error.InvalidCoordinate, identity.mapLineForward(0));
    try std.testing.expectEqual(@as(u32, 0), try identity.mapGapForward(.{ .position = 0, .bias = .before }));
    try std.testing.expectEqual(std.math.maxInt(u32), try identity.mapLineForward(std.math.maxInt(u32)));
    try std.testing.expectError(error.InvalidCoordinate, translateCoordinate(0, -1));
    try std.testing.expectError(error.InvalidCoordinate, translateCoordinate(std.math.maxInt(u32), 1));
}

test "hunk projection orders cached new-side and unstaged old-side coordinates" {
    var cached_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer cached_arena.deinit();
    var unstaged_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer unstaged_arena.deinit();
    var projection_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer projection_arena.deinit();

    const cached = try parseOneFile(&cached_arena,
        \\diff --git a/src/app.zig b/src/app.zig
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -30,3 +10,3 @@
        \\ context
        \\-old staged
        \\+new staged
        \\ context
        \\
    );
    const unstaged = try parseOneFile(&unstaged_arena,
        \\diff --git a/src/app.zig b/src/app.zig
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -40,3 +80,3 @@
        \\ context
        \\-old unstaged
        \\+new unstaged
        \\ context
        \\
    );

    const projection = try build(projection_arena.allocator(), cached, unstaged);
    try std.testing.expectEqual(@as(usize, 2), projection.file.hunks.len);
    try std.testing.expectEqual(HunkStageState.staged, projection.hunk_states[0].state);
    try std.testing.expectEqual(HunkStageState.unstaged, projection.hunk_states[1].state);
}

test "hunk projection rejects equal index-side starts" {
    var cached_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer cached_arena.deinit();
    var unstaged_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer unstaged_arena.deinit();
    var projection_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer projection_arena.deinit();

    const cached = try parseOneFile(&cached_arena,
        \\diff --git a/src/app.zig b/src/app.zig
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -1,3 +10,3 @@
        \\ context
        \\-old staged
        \\+new staged
        \\ context
        \\
    );
    const unstaged = try parseOneFile(&unstaged_arena,
        \\diff --git a/src/app.zig b/src/app.zig
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -10,3 +20,3 @@
        \\ context
        \\-old unstaged
        \\+new unstaged
        \\ context
        \\
    );

    try std.testing.expectError(error.AmbiguousProjection, build(projection_arena.allocator(), cached, unstaged));
}

test "hunk projection rejects mismatched old and new paths" {
    var cached_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer cached_arena.deinit();
    var unstaged_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer unstaged_arena.deinit();
    var projection_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer projection_arena.deinit();

    const cached = try parseOneFile(&cached_arena,
        \\diff --git a/src/old.zig b/src/new.zig
        \\--- a/src/old.zig
        \\+++ b/src/new.zig
        \\@@ -10,3 +10,3 @@
        \\ context
        \\-old staged
        \\+new staged
        \\ context
        \\
    );
    const unstaged = try parseOneFile(&unstaged_arena,
        \\diff --git a/src/new.zig b/src/new.zig
        \\--- a/src/new.zig
        \\+++ b/src/new.zig
        \\@@ -20,3 +20,3 @@
        \\ context
        \\-old unstaged
        \\+new unstaged
        \\ context
        \\
    );

    try std.testing.expectError(error.UnsupportedFile, build(projection_arena.allocator(), cached, unstaged));
}

test "hunk projection rejects overlapping changed ranges with different starts" {
    var cached_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer cached_arena.deinit();
    var unstaged_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer unstaged_arena.deinit();
    var projection_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer projection_arena.deinit();

    const cached = try parseOneFile(&cached_arena,
        \\diff --git a/src/app.zig b/src/app.zig
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -10,5 +10,5 @@
        \\ context
        \\-old staged 1
        \\-old staged 2
        \\+new staged 1
        \\+new staged 2
        \\ context
        \\
    );
    const unstaged = try parseOneFile(&unstaged_arena,
        \\diff --git a/src/app.zig b/src/app.zig
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -11,5 +20,5 @@
        \\ context
        \\-old unstaged
        \\+new unstaged
        \\ context
        \\ context
        \\
    );

    try std.testing.expectError(error.AmbiguousProjection, build(projection_arena.allocator(), cached, unstaged));
}

test "hunk projection combines context-overlapping changed-range-disjoint hunks" {
    var cached_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer cached_arena.deinit();
    var unstaged_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer unstaged_arena.deinit();
    var projection_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer projection_arena.deinit();

    const cached = try parseOneFile(&cached_arena,
        \\diff --git a/src/app.zig b/src/app.zig
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -10,7 +10,7 @@
        \\ context
        \\-old staged
        \\+new staged
        \\ context
        \\ context
        \\ context
        \\ context
        \\
    );
    const unstaged = try parseOneFile(&unstaged_arena,
        \\diff --git a/src/app.zig b/src/app.zig
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -12,7 +20,7 @@
        \\ context
        \\ context
        \\ context
        \\-old unstaged
        \\+new unstaged
        \\ context
        \\ context
        \\
    );

    const projection = try build(projection_arena.allocator(), cached, unstaged);
    try std.testing.expectEqual(@as(usize, 2), projection.file.hunks.len);
    try std.testing.expectEqual(HunkStageState.staged, projection.hunk_states[0].state);
    try std.testing.expectEqual(HunkStageState.unstaged, projection.hunk_states[1].state);
}

test "hunk projection rejects pure context hunks defensively" {
    const line = diff_parser.DiffLine{
        .kind = .context,
        .text = "same",
        .old_line = 1,
        .new_line = 1,
    };
    const hunk = diff_parser.Hunk{
        .old_start = 1,
        .old_count = 1,
        .new_start = 1,
        .new_count = 1,
        .section = "",
        .lines = &.{line},
    };
    const file = diff_parser.FileDiff{
        .header = "diff --git a/a b/a",
        .old_path = "a/a",
        .new_path = "b/a",
        .metadata = &.{},
        .hunks = &.{hunk},
    };
    var projection_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer projection_arena.deinit();

    try std.testing.expectError(error.AmbiguousProjection, build(projection_arena.allocator(), file, file));
}
