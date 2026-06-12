const std = @import("std");
const diff_parser = @import("diff_parser.zig");

pub const DisplayMode = enum {
    unified,
    side_by_side,

    pub fn label(self: DisplayMode) []const u8 {
        return switch (self) {
            .unified => "unified",
            .side_by_side => "side-by-side",
        };
    }

    pub fn toggled(self: DisplayMode) DisplayMode {
        return switch (self) {
            .unified => .side_by_side,
            .side_by_side => .unified,
        };
    }
};

pub const BodyRow = union(enum) {
    metadata: []const u8,
    binary_marker,
    hunk_header: HunkHeader,
    unified_line: diff_parser.DiffLine,
    side_by_side: SideBySideRow,
};

pub const HunkHeader = struct {
    hunk_index: usize,
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    section: []const u8,
};

pub const BodyRowIterator = struct {
    file: diff_parser.FileDiff,
    mode: DisplayMode,
    phase: Phase = .metadata,
    metadata_index: usize = 0,
    hunk_index: usize = 0,
    line_index: usize = 0,
    side_by_side_rows: SideBySideIterator = .init(&.{}),

    const Phase = enum {
        metadata,
        binary,
        hunk_header,
        hunk_lines,
        done,
    };

    /// Single source of truth for rendered body row order.
    /// Render, count, offset, and search should consume this iterator rather
    /// than each reimplementing metadata / hunk / side-by-side traversal.
    pub fn init(file: diff_parser.FileDiff, mode: DisplayMode) BodyRowIterator {
        return .{
            .file = file,
            .mode = mode,
        };
    }

    /// `index` must be built from the same file and display mode as this
    /// iterator; callers validate that boundary before taking this fast path.
    pub fn initAt(file: diff_parser.FileDiff, mode: DisplayMode, index: RenderedLineIndex, body_offset: usize) BodyRowIterator {
        if (body_offset == 0) return init(file, mode);
        if (body_offset >= index.total_rows) {
            return .{
                .file = file,
                .mode = mode,
                .phase = .done,
            };
        }

        if (body_offset < index.metadata_rows) {
            return .{
                .file = file,
                .mode = mode,
                .metadata_index = body_offset,
            };
        }

        if (body_offset < index.metadata_rows + index.binary_rows) {
            return .{
                .file = file,
                .mode = mode,
                .phase = .binary,
            };
        }

        const hunk_index = index.hunkIndexAtOffset(body_offset) orelse {
            return .{
                .file = file,
                .mode = mode,
                .phase = .done,
            };
        };
        const hunk_local_offset = body_offset - index.hunkOffset(hunk_index);
        if (hunk_local_offset == 0) {
            return .{
                .file = file,
                .mode = mode,
                .phase = .hunk_header,
                .hunk_index = hunk_index,
            };
        }

        var iterator: BodyRowIterator = .{
            .file = file,
            .mode = mode,
            .phase = .hunk_lines,
            .hunk_index = hunk_index,
        };
        const hunk = file.hunks[hunk_index];
        switch (mode) {
            .unified => iterator.line_index = @min(hunk_local_offset - 1, hunk.lines.len),
            .side_by_side => {
                iterator.side_by_side_rows = .init(hunk.lines);
                iterator.side_by_side_rows.skipRows(hunk_local_offset - 1);
            },
        }
        return iterator;
    }

    pub fn next(self: *BodyRowIterator) ?BodyRow {
        while (true) {
            switch (self.phase) {
                .metadata => {
                    if (self.metadata_index < self.file.metadata.len) {
                        const line = self.file.metadata[self.metadata_index];
                        self.metadata_index += 1;
                        return .{ .metadata = line };
                    }
                    self.phase = if (self.file.is_binary) .binary else .hunk_header;
                },
                .binary => {
                    self.phase = .done;
                    return .binary_marker;
                },
                .hunk_header => {
                    if (self.hunk_index >= self.file.hunks.len) {
                        self.phase = .done;
                        return null;
                    }
                    const hunk = self.file.hunks[self.hunk_index];
                    self.phase = .hunk_lines;
                    self.line_index = 0;
                    if (self.mode == .side_by_side) self.side_by_side_rows = .init(hunk.lines);
                    return .{ .hunk_header = .{
                        .hunk_index = self.hunk_index,
                        .old_start = hunk.old_start,
                        .old_count = hunk.old_count,
                        .new_start = hunk.new_start,
                        .new_count = hunk.new_count,
                        .section = hunk.section,
                    } };
                },
                .hunk_lines => {
                    const hunk = self.file.hunks[self.hunk_index];
                    switch (self.mode) {
                        .unified => {
                            if (self.line_index < hunk.lines.len) {
                                const line = hunk.lines[self.line_index];
                                self.line_index += 1;
                                return .{ .unified_line = line };
                            }
                        },
                        .side_by_side => {
                            if (self.side_by_side_rows.next()) |row| return .{ .side_by_side = row };
                        },
                    }
                    self.hunk_index += 1;
                    self.phase = .hunk_header;
                },
                .done => return null,
            }
        }
    }
};

pub fn renderedBodyLineCount(file: diff_parser.FileDiff, mode: DisplayMode) usize {
    var count: usize = 0;
    var rows = BodyRowIterator.init(file, mode);
    while (rows.next() != null) count += 1;
    return count;
}

pub fn hunkBodyLineOffset(file: diff_parser.FileDiff, mode: DisplayMode, hunk_index: usize) usize {
    var offset: usize = 0;
    var rows = BodyRowIterator.init(file, mode);
    while (rows.next()) |row| {
        if (row == .hunk_header and row.hunk_header.hunk_index == hunk_index) return offset;
        offset += 1;
    }
    return offset;
}

pub const RenderedLineIndex = struct {
    mode: DisplayMode,
    metadata_rows: usize = 0,
    binary_rows: usize = 0,
    total_rows: usize = 0,
    // Offsets are body-row coordinates. Each hunk offset points at its hunk
    // header row; each line count includes that header plus rendered hunk rows.
    hunk_offsets: []usize = &.{},
    hunk_line_counts: []usize = &.{},

    pub fn build(allocator: std.mem.Allocator, file: diff_parser.FileDiff, mode: DisplayMode) !RenderedLineIndex {
        const hunk_offsets = try allocator.alloc(usize, file.hunks.len);
        const hunk_line_counts = allocator.alloc(usize, file.hunks.len) catch |err| {
            allocator.free(hunk_offsets);
            return err;
        };

        var index: RenderedLineIndex = .{
            .mode = mode,
            .hunk_offsets = hunk_offsets,
            .hunk_line_counts = hunk_line_counts,
        };

        // Build from the same iterator used by render/search wrappers so the
        // cached index cannot drift from the rendered body row order.
        var rows = BodyRowIterator.init(file, mode);
        var offset: usize = 0;
        while (rows.next()) |row| : (offset += 1) {
            switch (row) {
                .metadata => index.metadata_rows += 1,
                .binary_marker => index.binary_rows += 1,
                .hunk_header => |hunk| {
                    if (hunk.hunk_index < index.hunk_offsets.len) {
                        index.hunk_offsets[hunk.hunk_index] = offset;
                    }
                },
                .unified_line, .side_by_side => {},
            }
        }
        index.total_rows = offset;

        for (index.hunk_offsets, 0..) |hunk_offset, hunk_index| {
            const next_offset = if (hunk_index + 1 < index.hunk_offsets.len)
                index.hunk_offsets[hunk_index + 1]
            else
                index.total_rows;
            index.hunk_line_counts[hunk_index] = next_offset - hunk_offset;
        }

        return index;
    }

    pub fn deinit(self: *RenderedLineIndex, allocator: std.mem.Allocator) void {
        const mode = self.mode;
        allocator.free(self.hunk_offsets);
        allocator.free(self.hunk_line_counts);
        self.* = .{ .mode = mode };
    }

    pub fn lineCount(self: RenderedLineIndex) usize {
        return self.total_rows;
    }

    pub fn hunkOffset(self: RenderedLineIndex, hunk_index: usize) usize {
        if (hunk_index >= self.hunk_offsets.len) return self.total_rows;
        return self.hunk_offsets[hunk_index];
    }

    pub fn hunkLineCount(self: RenderedLineIndex, hunk_index: usize) usize {
        if (hunk_index >= self.hunk_line_counts.len) return 0;
        return self.hunk_line_counts[hunk_index];
    }

    pub fn hunkIndexAtOffset(self: RenderedLineIndex, offset: usize) ?usize {
        if (self.hunk_offsets.len == 0) return null;
        if (offset < self.hunk_offsets[0]) return null;

        var lo: usize = 0;
        var hi: usize = self.hunk_offsets.len;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.hunk_offsets[mid] <= offset) {
                lo = mid;
            } else {
                hi = mid;
            }
        }

        if (offset >= self.hunk_offsets[lo] + self.hunkLineCount(lo)) return null;
        return lo;
    }
};

pub const RenderedLineCache = struct {
    unified: []RenderedLineIndex = &.{},
    side_by_side: []RenderedLineIndex = &.{},

    pub fn build(allocator: std.mem.Allocator, document: diff_parser.DiffDocument) !RenderedLineCache {
        const unified = try allocator.alloc(RenderedLineIndex, document.files.len);
        const side_by_side = allocator.alloc(RenderedLineIndex, document.files.len) catch |err| {
            allocator.free(unified);
            return err;
        };

        var cache: RenderedLineCache = .{
            .unified = unified,
            .side_by_side = side_by_side,
        };
        @memset(cache.unified, .{ .mode = .unified });
        @memset(cache.side_by_side, .{ .mode = .side_by_side });
        errdefer cache.deinitForTests(allocator);

        for (document.files, 0..) |file, index| {
            cache.unified[index] = try RenderedLineIndex.build(allocator, file, .unified);
            cache.side_by_side[index] = try RenderedLineIndex.build(allocator, file, .side_by_side);
        }

        return cache;
    }

    pub fn indexFor(self: RenderedLineCache, file_index: usize, mode: DisplayMode) ?RenderedLineIndex {
        return switch (mode) {
            .unified => if (file_index < self.unified.len) self.unified[file_index] else null,
            .side_by_side => if (file_index < self.side_by_side.len) self.side_by_side[file_index] else null,
        };
    }

    fn deinitForTests(self: *RenderedLineCache, allocator: std.mem.Allocator) void {
        for (self.unified) |*index| index.deinit(allocator);
        for (self.side_by_side) |*index| index.deinit(allocator);
        allocator.free(self.unified);
        allocator.free(self.side_by_side);
        self.* = .{};
    }
};

pub const SideBySidePair = struct {
    removed: ?diff_parser.DiffLine = null,
    added: ?diff_parser.DiffLine = null,
};

pub const SideBySideRow = union(enum) {
    single: diff_parser.DiffLine,
    paired: SideBySidePair,
};

/// Converts a hunk's raw unified lines into the rows used by side-by-side mode.
///
/// Git commonly emits replacement blocks as a removed run followed by an added
/// run (`-a -b +A +B`). Pairing those runs by index keeps the two sides aligned
/// for rendering, counting, and search.
pub const SideBySideIterator = struct {
    lines: []const diff_parser.DiffLine,
    index: usize = 0,
    block_removed_start: usize = 0,
    block_removed_len: usize = 0,
    block_added_start: usize = 0,
    block_added_len: usize = 0,
    block_offset: usize = 0,
    in_block: bool = false,

    pub fn init(lines: []const diff_parser.DiffLine) SideBySideIterator {
        return .{ .lines = lines };
    }

    pub fn next(self: *SideBySideIterator) ?SideBySideRow {
        if (self.in_block) return self.nextBlockRow();
        if (self.index >= self.lines.len) return null;

        const line = self.lines[self.index];
        if (line.kind == .removed) {
            const removed_start = self.index;
            var added_start = removed_start;
            while (added_start < self.lines.len and self.lines[added_start].kind == .removed) : (added_start += 1) {}

            var added_end = added_start;
            while (added_end < self.lines.len and self.lines[added_end].kind == .added) : (added_end += 1) {}

            if (added_end > added_start) {
                self.in_block = true;
                self.block_removed_start = removed_start;
                self.block_removed_len = added_start - removed_start;
                self.block_added_start = added_start;
                self.block_added_len = added_end - added_start;
                self.block_offset = 0;
                return self.nextBlockRow();
            }
        }

        self.index += 1;
        return .{ .single = line };
    }

    pub fn skipRows(self: *SideBySideIterator, count: usize) void {
        var skipped: usize = 0;
        while (skipped < count) : (skipped += 1) {
            if (self.next() == null) return;
        }
    }

    fn nextBlockRow(self: *SideBySideIterator) ?SideBySideRow {
        const max_len = @max(self.block_removed_len, self.block_added_len);
        if (self.block_offset >= max_len) {
            self.index = self.block_added_start + self.block_added_len;
            self.in_block = false;
            return self.next();
        }

        const offset = self.block_offset;
        self.block_offset += 1;
        return .{ .paired = .{
            .removed = if (offset < self.block_removed_len) self.lines[self.block_removed_start + offset] else null,
            .added = if (offset < self.block_added_len) self.lines[self.block_added_start + offset] else null,
        } };
    }
};

test "body line offsets account for metadata and side-by-side pairs" {
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/a b/a",
        .metadata = &.{ "index 1..2", "--- a/a", "+++ b/a" },
        .hunks = &.{
            .{
                .old_start = 1,
                .old_count = 2,
                .new_start = 1,
                .new_count = 2,
                .section = "first",
                .lines = &.{
                    .{ .kind = .removed, .text = "old", .old_line = 1 },
                    .{ .kind = .added, .text = "new", .new_line = 1 },
                    .{ .kind = .context, .text = "same", .old_line = 2, .new_line = 2 },
                },
            },
            .{
                .old_start = 8,
                .old_count = 1,
                .new_start = 8,
                .new_count = 1,
                .section = "second",
                .lines = &.{
                    .{ .kind = .added, .text = "later", .new_line = 8 },
                },
            },
        },
    };

    try std.testing.expectEqual(@as(usize, 6), hunkBodyLineOffset(file, .side_by_side, 1));
    try std.testing.expectEqual(@as(usize, 8), renderedBodyLineCount(file, .side_by_side));
    try std.testing.expectEqual(@as(usize, 7), hunkBodyLineOffset(file, .unified, 1));
    try std.testing.expectEqual(@as(usize, 9), renderedBodyLineCount(file, .unified));
}

test "rendered line index matches iterator wrappers" {
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/a b/a",
        .metadata = &.{ "index 1..2", "--- a/a", "+++ b/a" },
        .hunks = &.{
            .{
                .old_start = 1,
                .old_count = 4,
                .new_start = 1,
                .new_count = 2,
                .section = "first",
                .lines = &.{
                    .{ .kind = .removed, .text = "old one", .old_line = 1 },
                    .{ .kind = .removed, .text = "old two", .old_line = 2 },
                    .{ .kind = .removed, .text = "old three", .old_line = 3 },
                    .{ .kind = .added, .text = "new one", .new_line = 1 },
                    .{ .kind = .context, .text = "\\ No newline at end of file" },
                },
            },
            .{
                .old_start = 9,
                .old_count = 1,
                .new_start = 9,
                .new_count = 1,
                .section = "second",
                .lines = &.{
                    .{ .kind = .context, .text = "same", .old_line = 9, .new_line = 9 },
                },
            },
        },
    };

    var unified = try RenderedLineIndex.build(std.testing.allocator, file, .unified);
    defer unified.deinit(std.testing.allocator);
    var side_by_side = try RenderedLineIndex.build(std.testing.allocator, file, .side_by_side);
    defer side_by_side.deinit(std.testing.allocator);

    try std.testing.expectEqual(renderedBodyLineCount(file, .unified), unified.lineCount());
    try std.testing.expectEqual(renderedBodyLineCount(file, .side_by_side), side_by_side.lineCount());
    try std.testing.expectEqual(hunkBodyLineOffset(file, .unified, 1), unified.hunkOffset(1));
    try std.testing.expectEqual(hunkBodyLineOffset(file, .side_by_side, 1), side_by_side.hunkOffset(1));
    try std.testing.expectEqual(@as(usize, 3), unified.metadata_rows);
    try std.testing.expectEqual(@as(usize, 0), unified.binary_rows);
    try std.testing.expectEqual(@as(usize, 6), unified.hunkLineCount(0));
    try std.testing.expectEqual(@as(usize, 5), side_by_side.hunkLineCount(0));
}

test "rendered line index counts binary file" {
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/bin b/bin",
        .metadata = &.{"Binary files a/bin and b/bin differ"},
        .hunks = &.{},
        .is_binary = true,
    };

    var index = try RenderedLineIndex.build(std.testing.allocator, file, .unified);
    defer index.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), index.metadata_rows);
    try std.testing.expectEqual(@as(usize, 1), index.binary_rows);
    try std.testing.expectEqual(renderedBodyLineCount(file, .unified), index.lineCount());
    try std.testing.expectEqual(index.lineCount(), index.hunkOffset(0));
    try std.testing.expectEqual(@as(usize, 0), index.hunkLineCount(0));
}

test "body row iterator can start at cached offsets" {
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/a b/a",
        .metadata = &.{ "index 1..2", "--- a/a", "+++ b/a" },
        .hunks = &.{
            .{
                .old_start = 1,
                .old_count = 2,
                .new_start = 1,
                .new_count = 2,
                .section = "first",
                .lines = &.{
                    .{ .kind = .removed, .text = "old one", .old_line = 1 },
                    .{ .kind = .removed, .text = "old two", .old_line = 2 },
                    .{ .kind = .added, .text = "new one", .new_line = 1 },
                    .{ .kind = .added, .text = "new two", .new_line = 2 },
                },
            },
            .{
                .old_start = 8,
                .old_count = 1,
                .new_start = 8,
                .new_count = 1,
                .section = "second",
                .lines = &.{
                    .{ .kind = .context, .text = "same", .old_line = 8, .new_line = 8 },
                },
            },
        },
    };

    var index = try RenderedLineIndex.build(std.testing.allocator, file, .side_by_side);
    defer index.deinit(std.testing.allocator);

    var first_pair = BodyRowIterator.initAt(file, .side_by_side, index, index.hunkOffset(0) + 1);
    const pair = first_pair.next().?.side_by_side.paired;
    try std.testing.expectEqualStrings("old one", pair.removed.?.text);
    try std.testing.expectEqualStrings("new one", pair.added.?.text);

    var second_pair = BodyRowIterator.initAt(file, .side_by_side, index, index.hunkOffset(0) + 2);
    const next_pair = second_pair.next().?.side_by_side.paired;
    try std.testing.expectEqualStrings("old two", next_pair.removed.?.text);
    try std.testing.expectEqualStrings("new two", next_pair.added.?.text);

    var second_hunk = BodyRowIterator.initAt(file, .side_by_side, index, index.hunkOffset(1));
    try std.testing.expectEqual(@as(usize, 1), second_hunk.next().?.hunk_header.hunk_index);
    try std.testing.expectEqualStrings("same", second_hunk.next().?.side_by_side.single.text);
}

test "side-by-side pairs removed and added runs by index" {
    const lines = [_]diff_parser.DiffLine{
        .{ .kind = .removed, .text = "old one", .old_line = 1 },
        .{ .kind = .removed, .text = "old two", .old_line = 2 },
        .{ .kind = .added, .text = "new one", .new_line = 1 },
        .{ .kind = .added, .text = "new two", .new_line = 2 },
    };

    var rows = SideBySideIterator.init(lines[0..]);
    const first = rows.next().?.paired;
    const second = rows.next().?.paired;

    try std.testing.expectEqualStrings("old one", first.removed.?.text);
    try std.testing.expectEqualStrings("new one", first.added.?.text);
    try std.testing.expectEqualStrings("old two", second.removed.?.text);
    try std.testing.expectEqualStrings("new two", second.added.?.text);
    try std.testing.expect(rows.next() == null);
    try std.testing.expectEqual(@as(usize, 3), renderedBodyLineCount(.{
        .header = "diff --git a/a b/a",
        .metadata = &.{},
        .hunks = &.{.{
            .old_start = 1,
            .old_count = 2,
            .new_start = 1,
            .new_count = 2,
            .section = "",
            .lines = lines[0..],
        }},
    }, .side_by_side));
}
