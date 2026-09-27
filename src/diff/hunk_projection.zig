const std = @import("std");
const diff_parser = @import("parser.zig");
const diff_view_model = @import("view_model.zig");

pub const HunkStageState = enum {
    staged,
    unstaged,
};

/// Maps a displayed hunk to syntax spans owned by the presentation generation.
/// This type must never be used to construct the next Git patch.
pub const PresentationSyntaxOrigin = union(enum) {
    cached: usize,
    unstaged: usize,
};

/// Maps a displayed hunk to the fresh component hunk which authorizes the next
/// stage/unstage patch. This type must never index retained syntax owners.
pub const HunkActionOrigin = union(enum) {
    cached: usize,
    unstaged: usize,
};

pub const Presentation = struct {
    file: diff_parser.FileDiff,
    presentation_syntax_origins: []const PresentationSyntaxOrigin,
    unified_line_index: diff_view_model.RenderedLineIndex,
    side_by_side_line_index: diff_view_model.RenderedLineIndex,

    pub fn lineIndex(self: Presentation, mode: diff_view_model.DisplayMode) diff_view_model.RenderedLineIndex {
        return switch (mode) {
            .unified => self.unified_line_index,
            .side_by_side => self.side_by_side_line_index,
        };
    }
};

pub const Authority = struct {
    hunk_stage_states: []const HunkStageState,
    hunk_action_origins: []const HunkActionOrigin,
};

pub const Projection = struct {
    presentation: Presentation,
    authority: Authority,

    pub fn lineIndex(self: Projection, mode: diff_view_model.DisplayMode) diff_view_model.RenderedLineIndex {
        return self.presentation.lineIndex(mode);
    }
};

pub const BuildError = error{
    UnsupportedFile,
    AmbiguousProjection,
    UnmappableCoordinate,
    OutOfMemory,
};

const Source = enum {
    cached,
    unstaged,
};

/// One component hunk candidate ordered by its index-side changed range.
///
/// Cached diff is HEAD->index and unstaged diff is index->worktree. The index
/// range is used only for ordering and ambiguity checks; `build()` later clones
/// and normalizes the hunk value into HEAD->worktree display coordinates.
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
    return buildWithAllocators(allocator, allocator, cached_file, unstaged_file);
}

/// Build one normalized display while placing retained presentation facts and
/// replaceable index authority in independent allocation domains. Passing the
/// same allocator preserves the convenient single-owner form used by leaf
/// tests and the developer profiler; Changes uses distinct arenas.
pub fn buildWithAllocators(
    presentation_allocator: std.mem.Allocator,
    authority_allocator: std.mem.Allocator,
    cached_file: diff_parser.FileDiff,
    unstaged_file: diff_parser.FileDiff,
) BuildError!Projection {
    try validateFile(cached_file);
    try validateFile(unstaged_file);

    const cached_transform = buildCoordinateTransform(presentation_allocator, cached_file.hunks) catch |err| return coordinateBuildError(err);
    defer cached_transform.deinit(presentation_allocator);
    const unstaged_transform = buildCoordinateTransform(presentation_allocator, unstaged_file.hunks) catch |err| return coordinateBuildError(err);
    defer unstaged_transform.deinit(presentation_allocator);

    var candidates: std.ArrayList(Candidate) = .empty;
    defer candidates.deinit(presentation_allocator);

    try appendCandidates(presentation_allocator, &candidates, cached_file, .cached);
    try appendCandidates(presentation_allocator, &candidates, unstaged_file, .unstaged);
    if (candidates.items.len == 0) return error.AmbiguousProjection;

    std.mem.sort(Candidate, candidates.items, {}, lessThanCandidate);
    for (candidates.items[1..], 1..) |candidate, index| {
        const previous = candidates.items[index - 1];
        if (candidate.range.start == previous.range.start) return error.AmbiguousProjection;
        if (candidate.range.overlaps(previous.range)) return error.AmbiguousProjection;
    }

    const hunks = try presentation_allocator.alloc(diff_parser.Hunk, candidates.items.len);
    errdefer presentation_allocator.free(hunks);
    const syntax_origins = try presentation_allocator.alloc(PresentationSyntaxOrigin, candidates.items.len);
    errdefer presentation_allocator.free(syntax_origins);
    const stage_states = try authority_allocator.alloc(HunkStageState, candidates.items.len);
    errdefer authority_allocator.free(stage_states);
    const action_origins = try authority_allocator.alloc(HunkActionOrigin, candidates.items.len);
    errdefer authority_allocator.free(action_origins);

    var initialized_hunks: usize = 0;
    errdefer for (hunks[0..initialized_hunks]) |hunk| {
        presentation_allocator.free(hunk.header);
        presentation_allocator.free(hunk.lines);
    };

    // Projected hunk headers and line values belong to the presentation allocator
    // because their coordinates are normalized from HEAD directly to the
    // working tree.
    // Text and section slices remain borrowed from the retained component
    // bundles. Syntax and action origins are deliberately separate arrays even
    // in this same-generation eager result, so future presentation retention
    // cannot accidentally use fresh patch authority for syntax lookup.
    for (candidates.items, 0..) |candidate, index| {
        hunks[index] = try normalizeCandidateHunk(
            presentation_allocator,
            candidate,
            cached_transform,
            unstaged_transform,
        );
        initialized_hunks += 1;
        switch (candidate.source) {
            .cached => {
                stage_states[index] = .staged;
                syntax_origins[index] = .{ .cached = candidate.hunk_index };
                action_origins[index] = .{ .cached = candidate.hunk_index };
            },
            .unstaged => {
                stage_states[index] = .unstaged;
                syntax_origins[index] = .{ .unstaged = candidate.hunk_index };
                action_origins[index] = .{ .unstaged = candidate.hunk_index };
            },
        }
    }

    const file: diff_parser.FileDiff = .{
        .header = unstaged_file.header,
        .old_path = unstaged_file.old_path orelse cached_file.old_path,
        .new_path = unstaged_file.new_path orelse cached_file.new_path,
        .metadata = unstaged_file.metadata,
        .hunks = hunks,
        .is_binary = false,
    };

    var unified_line_index = try diff_view_model.RenderedLineIndex.build(presentation_allocator, file, .unified);
    errdefer unified_line_index.deinit(presentation_allocator);
    const side_by_side_line_index = try diff_view_model.RenderedLineIndex.build(presentation_allocator, file, .side_by_side);

    return .{
        .presentation = .{
            .file = file,
            .presentation_syntax_origins = syntax_origins,
            .unified_line_index = unified_line_index,
            .side_by_side_line_index = side_by_side_line_index,
        },
        .authority = .{
            .hunk_stage_states = stage_states,
            .hunk_action_origins = action_origins,
        },
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
        const range = try changedIndexRange(hunk, source);
        try candidates.append(allocator, .{
            .source = source,
            .hunk_index = hunk_index,
            .hunk = hunk,
            .range = range,
        });
    }
}

fn changedIndexRange(hunk: diff_parser.Hunk, source: Source) BuildError!ChangedRange {
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

        const one_past = std.math.add(u32, index_line, 1) catch return error.UnmappableCoordinate;
        if (start == null or index_line < start.?) start = index_line;
        if (one_past > end) end = one_past;
    }

    const first = start orelse return error.AmbiguousProjection;
    if (first >= end) return error.AmbiguousProjection;
    return .{ .start = first, .end = end };
}

fn lessThanCandidate(_: void, lhs: Candidate, rhs: Candidate) bool {
    return lhs.range.start < rhs.range.start;
}

fn sameRepoPath(old_path: ?[]const u8, new_path: ?[]const u8) bool {
    const old = old_path orelse return false;
    const new = new_path orelse return false;
    return std.mem.eql(u8, old, new);
}

const CoordinateTransformError = error{
    InvalidCoordinate,
    UnmappableCoordinate,
    OutOfMemory,
};

fn coordinateBuildError(err: CoordinateTransformError) BuildError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidCoordinate, error.UnmappableCoordinate => error.UnmappableCoordinate,
    };
}

fn normalizeCandidateHunk(
    allocator: std.mem.Allocator,
    candidate: Candidate,
    cached_transform: CoordinateTransform,
    unstaged_transform: CoordinateTransform,
) BuildError!diff_parser.Hunk {
    const lines = try allocator.alloc(diff_parser.DiffLine, candidate.hunk.lines.len);
    errdefer allocator.free(lines);
    @memcpy(lines, candidate.hunk.lines);

    var normalized = candidate.hunk;
    normalized.lines = lines;
    switch (candidate.source) {
        .cached => {
            // Git's zero-count header convention makes a new-side anchor
            // after-biased. Preserve that convention while mapping B -> C.
            normalized.new_start = try normalizeProjectedStart(
                unstaged_transform,
                candidate.hunk.new_start,
                candidate.hunk.new_count,
                .forward,
                .after,
            );
            for (lines) |*line| {
                if (line.new_line) |coordinate| {
                    line.new_line = try normalizeProjectedLine(unstaged_transform, coordinate, .forward);
                }
            }
        },
        .unstaged => {
            // Git's zero-count header convention makes an old-side anchor
            // before-biased. Preserve that convention while mapping B -> A.
            normalized.old_start = try normalizeProjectedStart(
                cached_transform,
                candidate.hunk.old_start,
                candidate.hunk.old_count,
                .inverse,
                .before,
            );
            for (lines) |*line| {
                if (line.old_line) |coordinate| {
                    line.old_line = try normalizeProjectedLine(cached_transform, coordinate, .inverse);
                }
            }
        },
    }

    try validateProjectedHunk(normalized);
    // Copy and selection consumers read the header bytes; rendering reads the
    // numeric ranges. Keep both in display coordinates, leaving the component
    // hunk used by action authority untouched.
    normalized.header = if (normalized.old_start == candidate.hunk.old_start and normalized.new_start == candidate.hunk.new_start)
        try allocator.dupe(u8, candidate.hunk.header)
    else
        try std.fmt.allocPrint(allocator, "@@ -{d},{d} +{d},{d} @@{s}{s}", .{
            normalized.old_start,
            normalized.old_count,
            normalized.new_start,
            normalized.new_count,
            if (normalized.section.len == 0) "" else " ",
            normalized.section,
        });
    return normalized;
}

fn normalizeProjectedStart(
    transform: CoordinateTransform,
    start: u32,
    count: u32,
    direction: TransformDirection,
    gap_bias: GapBias,
) BuildError!u32 {
    if (count != 0) return normalizeProjectedLine(transform, start, direction);
    const mapped = switch (direction) {
        .forward => transform.mapGapForward(.{ .position = start, .bias = gap_bias }),
        .inverse => transform.mapGapInverse(.{ .position = start, .bias = gap_bias }),
    } catch |err| return coordinateBuildError(err);
    return mapped;
}

fn normalizeProjectedLine(
    transform: CoordinateTransform,
    coordinate: u32,
    direction: TransformDirection,
) BuildError!u32 {
    const mapped = switch (direction) {
        .forward => transform.mapLineForward(coordinate),
        .inverse => transform.mapLineInverse(coordinate),
    } catch |err| return coordinateBuildError(err);
    return mapped;
}

fn validateProjectedHunk(hunk: diff_parser.Hunk) BuildError!void {
    try validateProjectedSide(hunk, .old);
    try validateProjectedSide(hunk, .new);
}

const ProjectedSide = enum {
    old,
    new,
};

fn validateProjectedSide(hunk: diff_parser.Hunk, side: ProjectedSide) BuildError!void {
    const start = switch (side) {
        .old => hunk.old_start,
        .new => hunk.new_start,
    };
    const count = switch (side) {
        .old => hunk.old_count,
        .new => hunk.new_count,
    };

    var consumed: u32 = 0;
    var previous: ?u32 = null;
    for (hunk.lines) |line| {
        const coordinate = switch (side) {
            .old => line.old_line,
            .new => line.new_line,
        } orelse continue;

        if (count == 0) return error.UnmappableCoordinate;
        if (previous) |last| {
            const expected = std.math.add(u32, last, 1) catch return error.UnmappableCoordinate;
            if (coordinate != expected) return error.UnmappableCoordinate;
        } else if (coordinate != start) {
            return error.UnmappableCoordinate;
        }
        previous = coordinate;
        consumed = std.math.add(u32, consumed, 1) catch return error.UnmappableCoordinate;
    }
    if (consumed != count) return error.UnmappableCoordinate;
}

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

fn expectRenderedHunkHeader(
    projection: Projection,
    mode: diff_view_model.DisplayMode,
    hunk_index: usize,
    old_start: u32,
    new_start: u32,
) !void {
    const line_index = projection.lineIndex(mode);
    var rows = diff_view_model.BodyRowIterator.initAt(
        projection.presentation.file,
        mode,
        line_index,
        line_index.hunkOffset(hunk_index),
    );
    const row = rows.next() orelse return error.ExpectedProjectedHunkHeader;
    switch (row) {
        .hunk_header => |header| {
            try std.testing.expectEqual(hunk_index, header.hunk_index);
            try std.testing.expectEqual(old_start, header.old_start);
            try std.testing.expectEqual(new_start, header.new_start);
        },
        else => return error.ExpectedProjectedHunkHeader,
    }
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
        \\@@ -30,1 +30,1 @@
        \\-old staged
        \\+new staged
        \\
    );
    const unstaged = try parseOneFile(&unstaged_arena,
        \\diff --git a/src/app.zig b/src/app.zig
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -40,1 +40,1 @@
        \\-old unstaged
        \\+new unstaged
        \\
    );

    const projection = try build(projection_arena.allocator(), cached, unstaged);
    try std.testing.expectEqual(@as(usize, 2), projection.presentation.file.hunks.len);
    try std.testing.expectEqual(HunkStageState.staged, projection.authority.hunk_stage_states[0]);
    try std.testing.expectEqual(HunkStageState.unstaged, projection.authority.hunk_stage_states[1]);
    try std.testing.expectEqualDeep(PresentationSyntaxOrigin{ .cached = 0 }, projection.presentation.presentation_syntax_origins[0]);
    try std.testing.expectEqualDeep(PresentationSyntaxOrigin{ .unstaged = 0 }, projection.presentation.presentation_syntax_origins[1]);
    try std.testing.expectEqualDeep(HunkActionOrigin{ .cached = 0 }, projection.authority.hunk_action_origins[0]);
    try std.testing.expectEqualDeep(HunkActionOrigin{ .unstaged = 0 }, projection.authority.hunk_action_origins[1]);
}

test "hunk projection keeps presentation and authority in separate allocation domains" {
    var cached_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer cached_arena.deinit();
    var unstaged_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer unstaged_arena.deinit();

    const cached = try parseOneFile(&cached_arena,
        \\diff --git a/a.zig b/a.zig
        \\--- a/a.zig
        \\+++ b/a.zig
        \\@@ -1 +1 @@
        \\-const old = 1;
        \\+const staged = 2;
        \\
    );
    const unstaged = try parseOneFile(&unstaged_arena,
        \\diff --git a/a.zig b/a.zig
        \\--- a/a.zig
        \\+++ b/a.zig
        \\@@ -3 +3 @@
        \\-const before = 3;
        \\+const current = 4;
        \\
    );

    var presentation_storage: [64 * 1024]u8 = undefined;
    var authority_storage: [64 * 1024]u8 = undefined;
    var presentation_fba = std.heap.FixedBufferAllocator.init(&presentation_storage);
    var authority_fba = std.heap.FixedBufferAllocator.init(&authority_storage);
    const projection = try buildWithAllocators(
        presentation_fba.allocator(),
        authority_fba.allocator(),
        cached,
        unstaged,
    );

    try std.testing.expect(pointerInBuffer(projection.presentation.file.hunks.ptr, &presentation_storage));
    for (projection.presentation.file.hunks) |hunk| {
        try std.testing.expect(pointerInBuffer(hunk.header.ptr, &presentation_storage));
    }
    try std.testing.expect(pointerInBuffer(projection.presentation.presentation_syntax_origins.ptr, &presentation_storage));
    try std.testing.expect(!pointerInBuffer(projection.presentation.file.hunks.ptr, &authority_storage));
    try std.testing.expect(pointerInBuffer(projection.authority.hunk_stage_states.ptr, &authority_storage));
    try std.testing.expect(pointerInBuffer(projection.authority.hunk_action_origins.ptr, &authority_storage));
    try std.testing.expect(!pointerInBuffer(projection.authority.hunk_stage_states.ptr, &presentation_storage));
}

fn pointerInBuffer(pointer: anytype, buffer: []const u8) bool {
    const address = @intFromPtr(pointer);
    const start = @intFromPtr(buffer.ptr);
    return address >= start and address < start + buffer.len;
}

test "hunk projection keeps later HEAD and worktree coordinates stable across staged partition" {
    var first_cached_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer first_cached_arena.deinit();
    var first_unstaged_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer first_unstaged_arena.deinit();
    var first_projection_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer first_projection_arena.deinit();

    const first_cached = try parseOneFile(&first_cached_arena,
        \\diff --git a/src/app.zig b/src/app.zig
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -10,0 +11,1 @@
        \\+inserted before later change
        \\
    );
    const first_unstaged = try parseOneFile(&first_unstaged_arena,
        \\diff --git a/src/app.zig b/src/app.zig
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -21,1 +21,1 @@
        \\-old later
        \\+new later
        \\
    );
    const first = try build(first_projection_arena.allocator(), first_cached, first_unstaged);

    var second_cached_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer second_cached_arena.deinit();
    var second_unstaged_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer second_unstaged_arena.deinit();
    var second_projection_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer second_projection_arena.deinit();

    const second_cached = try parseOneFile(&second_cached_arena,
        \\diff --git a/src/app.zig b/src/app.zig
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -20,1 +20,1 @@
        \\-old later
        \\+new later
        \\
    );
    const second_unstaged = try parseOneFile(&second_unstaged_arena,
        \\diff --git a/src/app.zig b/src/app.zig
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -10,0 +11,1 @@
        \\+inserted before later change
        \\
    );
    const second = try build(second_projection_arena.allocator(), second_cached, second_unstaged);

    for ([_]Projection{ first, second }) |projection| {
        const later = projection.presentation.file.hunks[1];
        try std.testing.expectEqual(@as(u32, 20), later.old_start);
        try std.testing.expectEqual(@as(u32, 21), later.new_start);
        try std.testing.expectEqualStrings("@@ -20,1 +21,1 @@", later.header);
        try std.testing.expectEqual(@as(?u32, 20), later.lines[0].old_line);
        try std.testing.expectEqual(@as(?u32, 21), later.lines[1].new_line);
        try expectRenderedHunkHeader(projection, .unified, 1, 20, 21);
        try expectRenderedHunkHeader(projection, .side_by_side, 1, 20, 21);
    }

    try std.testing.expectEqualDeep(HunkActionOrigin{ .unstaged = 0 }, first.authority.hunk_action_origins[1]);
    try std.testing.expectEqualDeep(HunkActionOrigin{ .cached = 0 }, second.authority.hunk_action_origins[1]);
    try std.testing.expectEqualDeep(PresentationSyntaxOrigin{ .unstaged = 0 }, first.presentation.presentation_syntax_origins[1]);
    try std.testing.expectEqualDeep(PresentationSyntaxOrigin{ .cached = 0 }, second.presentation.presentation_syntax_origins[1]);
    try std.testing.expect(first.presentation.file.hunks[1].lines.ptr != first_unstaged.hunks[0].lines.ptr);
    try std.testing.expect(first.presentation.file.hunks[1].lines[0].text.ptr == first_unstaged.hunks[0].lines[0].text.ptr);
}

test "hunk projection keeps later coordinates stable across cached and unstaged deletion" {
    var first_cached_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer first_cached_arena.deinit();
    var first_unstaged_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer first_unstaged_arena.deinit();
    var first_projection_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer first_projection_arena.deinit();

    const first_cached = try parseOneFile(&first_cached_arena,
        \\diff --git a/src/app.zig b/src/app.zig
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -10,1 +9,0 @@
        \\-deleted before later change
        \\
    );
    const first_unstaged = try parseOneFile(&first_unstaged_arena,
        \\diff --git a/src/app.zig b/src/app.zig
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -19,1 +19,1 @@
        \\-old later
        \\+new later
        \\
    );
    const first = try build(first_projection_arena.allocator(), first_cached, first_unstaged);

    var second_cached_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer second_cached_arena.deinit();
    var second_unstaged_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer second_unstaged_arena.deinit();
    var second_projection_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer second_projection_arena.deinit();

    const second_cached = try parseOneFile(&second_cached_arena,
        \\diff --git a/src/app.zig b/src/app.zig
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -20,1 +20,1 @@
        \\-old later
        \\+new later
        \\
    );
    const second_unstaged = try parseOneFile(&second_unstaged_arena,
        \\diff --git a/src/app.zig b/src/app.zig
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -10,1 +9,0 @@
        \\-deleted before later change
        \\
    );
    const second = try build(second_projection_arena.allocator(), second_cached, second_unstaged);

    for ([_]Projection{ first, second }) |projection| {
        const later = projection.presentation.file.hunks[1];
        try std.testing.expectEqual(@as(u32, 20), later.old_start);
        try std.testing.expectEqual(@as(u32, 19), later.new_start);
        try std.testing.expectEqual(@as(?u32, 20), later.lines[0].old_line);
        try std.testing.expectEqual(@as(?u32, 19), later.lines[1].new_line);
        try expectRenderedHunkHeader(projection, .unified, 1, 20, 19);
        try expectRenderedHunkHeader(projection, .side_by_side, 1, 20, 19);
    }

    try std.testing.expectEqualDeep(HunkActionOrigin{ .unstaged = 0 }, first.authority.hunk_action_origins[1]);
    try std.testing.expectEqualDeep(HunkActionOrigin{ .cached = 0 }, second.authority.hunk_action_origins[1]);
}

test "hunk projection normalizes zero-count headers after non-zero prior deltas" {
    var first_cached_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer first_cached_arena.deinit();
    var first_unstaged_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer first_unstaged_arena.deinit();
    var first_projection_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer first_projection_arena.deinit();

    const first_cached = try parseOneFile(&first_cached_arena,
        \\diff --git a/src/app.zig b/src/app.zig
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -20,1 +19,0 @@
        \\-cached deletion
        \\
    );
    const first_unstaged = try parseOneFile(&first_unstaged_arena,
        \\diff --git a/src/app.zig b/src/app.zig
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -10,0 +11,1 @@
        \\+unstaged insertion
        \\
    );
    const first = try build(first_projection_arena.allocator(), first_cached, first_unstaged);
    const cached_deletion = first.presentation.file.hunks[1];
    try std.testing.expectEqual(@as(u32, 0), cached_deletion.new_count);
    try std.testing.expectEqual(@as(u32, 20), cached_deletion.new_start);
    try std.testing.expectEqualStrings("@@ -20,1 +20,0 @@", cached_deletion.header);

    var second_cached_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer second_cached_arena.deinit();
    var second_unstaged_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer second_unstaged_arena.deinit();
    var second_projection_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer second_projection_arena.deinit();

    const second_cached = try parseOneFile(&second_cached_arena,
        \\diff --git a/src/app.zig b/src/app.zig
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -10,0 +11,1 @@
        \\+cached insertion
        \\
    );
    const second_unstaged = try parseOneFile(&second_unstaged_arena,
        \\diff --git a/src/app.zig b/src/app.zig
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -20,0 +21,1 @@
        \\+unstaged insertion
        \\
    );
    const second = try build(second_projection_arena.allocator(), second_cached, second_unstaged);
    const unstaged_insertion = second.presentation.file.hunks[1];
    try std.testing.expectEqual(@as(u32, 0), unstaged_insertion.old_count);
    try std.testing.expectEqual(@as(u32, 19), unstaged_insertion.old_start);
    try std.testing.expectEqualStrings("@@ -19,0 +21,1 @@", unstaged_insertion.header);
}

test "hunk projection zero-count header mapping preserves Git side bias" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const insertion = try parseOneFile(&arena,
        \\diff --git a/src/app.zig b/src/app.zig
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -5,0 +6,1 @@
        \\+inserted
        \\
    );
    const insertion_transform = try buildCoordinateTransform(std.testing.allocator, insertion.hunks);
    defer insertion_transform.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 5), try normalizeProjectedStart(insertion_transform, 5, 0, .forward, .before));
    try std.testing.expectEqual(@as(u32, 6), try normalizeProjectedStart(insertion_transform, 5, 0, .forward, .after));

    const deletion = try parseOneFile(&arena,
        \\diff --git a/src/app.zig b/src/app.zig
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -6,1 +5,0 @@
        \\-deleted
        \\
    );
    const deletion_transform = try buildCoordinateTransform(std.testing.allocator, deletion.hunks);
    defer deletion_transform.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 5), try normalizeProjectedStart(deletion_transform, 5, 0, .inverse, .before));
    try std.testing.expectEqual(@as(u32, 6), try normalizeProjectedStart(deletion_transform, 5, 0, .inverse, .after));
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
        \\@@ -10,1 +10,1 @@
        \\-old staged
        \\+new staged
        \\
    );
    const unstaged = try parseOneFile(&unstaged_arena,
        \\diff --git a/src/app.zig b/src/app.zig
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -10,1 +10,1 @@
        \\-old unstaged
        \\+new unstaged
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
        \\@@ -10,2 +10,2 @@
        \\-old staged 1
        \\-old staged 2
        \\+new staged 1
        \\+new staged 2
        \\
    );
    const unstaged = try parseOneFile(&unstaged_arena,
        \\diff --git a/src/app.zig b/src/app.zig
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -11,1 +11,1 @@
        \\-old unstaged
        \\+new unstaged
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
        \\@@ -10,3 +10,3 @@
        \\ context 10
        \\-old staged
        \\+new staged
        \\ context 12
        \\
    );
    const unstaged = try parseOneFile(&unstaged_arena,
        \\diff --git a/src/app.zig b/src/app.zig
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -12,5 +12,5 @@
        \\ context 12
        \\ context 13
        \\ context 14
        \\-old unstaged
        \\+new unstaged
        \\ context 16
        \\
    );

    const projection = try build(projection_arena.allocator(), cached, unstaged);
    try std.testing.expectEqual(@as(usize, 2), projection.presentation.file.hunks.len);
    try std.testing.expectEqual(HunkStageState.staged, projection.authority.hunk_stage_states[0]);
    try std.testing.expectEqual(HunkStageState.unstaged, projection.authority.hunk_stage_states[1]);
}

test "hunk projection rejects copied context that crosses another component edit" {
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
        \\@@ -13,1 +13,1 @@
        \\-old staged
        \\+new staged
        \\
    );
    const unstaged = try parseOneFile(&unstaged_arena,
        \\diff --git a/src/app.zig b/src/app.zig
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -13,5 +13,4 @@
        \\ context 13
        \\ context 14
        \\ context 15
        \\-old unstaged
        \\ context 17
        \\
    );

    try std.testing.expectError(error.UnmappableCoordinate, build(projection_arena.allocator(), cached, unstaged));
}

test "hunk projection validation rejects non-contiguous normalized coordinates" {
    const lines = [_]diff_parser.DiffLine{
        .{ .kind = .context, .text = "first", .old_line = 10, .new_line = 10 },
        .{ .kind = .context, .text = "gap", .old_line = 12, .new_line = 11 },
    };
    const hunk: diff_parser.Hunk = .{
        .old_start = 10,
        .old_count = 2,
        .new_start = 10,
        .new_count = 2,
        .section = "",
        .lines = &lines,
    };

    try std.testing.expectError(error.UnmappableCoordinate, validateProjectedHunk(hunk));
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
        .old_path = "a",
        .new_path = "a",
        .metadata = &.{},
        .hunks = &.{hunk},
    };
    var projection_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer projection_arena.deinit();

    try std.testing.expectError(error.AmbiguousProjection, build(projection_arena.allocator(), file, file));
}
