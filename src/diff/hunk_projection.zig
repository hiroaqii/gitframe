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

fn parseOneFile(arena: *std.heap.ArenaAllocator, text: []const u8) !diff_parser.FileDiff {
    const copied = try arena.allocator().dupe(u8, text);
    const document = try diff_parser.parse(arena.allocator(), copied);
    try std.testing.expectEqual(@as(usize, 1), document.files.len);
    return document.files[0];
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
