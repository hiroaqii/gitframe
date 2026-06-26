const std = @import("std");
const diff_parser = @import("parser.zig");

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

pub const BodyCoordinate = union(enum) {
    metadata: usize,
    binary_marker,
    hunk_header: usize,
    hunk_line: struct {
        hunk_index: usize,
        line_index: usize,
    },
};

pub const HunkHeader = struct {
    hunk_index: usize,
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    section: []const u8,
    folded: bool = false,
};

pub const BodyRowIterator = struct {
    file: diff_parser.FileDiff,
    mode: DisplayMode,
    phase: Phase = .metadata,
    metadata_index: usize = 0,
    hunk_index: usize = 0,
    line_index: usize = 0,
    side_by_side_rows: SideBySideIterator = .init(&.{}),
    folded_hunks: []const bool = &.{},

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
        return initWithFolded(file, mode, &.{});
    }

    pub fn initWithFolded(file: diff_parser.FileDiff, mode: DisplayMode, folded_hunks: []const bool) BodyRowIterator {
        return .{
            .file = file,
            .mode = mode,
            .folded_hunks = folded_hunks,
        };
    }

    /// `index` must be built from the same file and display mode as this
    /// iterator; callers validate that boundary before taking this fast path.
    pub fn initAt(file: diff_parser.FileDiff, mode: DisplayMode, index: RenderedLineIndex, body_offset: usize) BodyRowIterator {
        return initAtWithFolded(file, mode, index, body_offset, &.{});
    }

    pub fn initAtWithFolded(
        file: diff_parser.FileDiff,
        mode: DisplayMode,
        index: RenderedLineIndex,
        body_offset: usize,
        folded_hunks: []const bool,
    ) BodyRowIterator {
        if (body_offset == 0) return initWithFolded(file, mode, folded_hunks);
        if (body_offset >= index.total_rows) {
            return .{
                .file = file,
                .mode = mode,
                .folded_hunks = folded_hunks,
                .phase = .done,
            };
        }

        if (body_offset < index.metadata_rows) {
            return .{
                .file = file,
                .mode = mode,
                .folded_hunks = folded_hunks,
                .metadata_index = metadataIndexAtVisibleRow(file, body_offset) orelse file.metadata.len,
            };
        }

        if (body_offset < index.metadata_rows + index.binary_rows) {
            return .{
                .file = file,
                .mode = mode,
                .folded_hunks = folded_hunks,
                .phase = .binary,
            };
        }

        const hunk_index = index.hunkIndexAtOffset(body_offset) orelse {
            return .{
                .file = file,
                .mode = mode,
                .folded_hunks = folded_hunks,
                .phase = .done,
            };
        };
        const hunk_local_offset = body_offset - index.hunkOffset(hunk_index);
        if (hunk_local_offset == 0) {
            return .{
                .file = file,
                .mode = mode,
                .folded_hunks = folded_hunks,
                .phase = .hunk_header,
                .hunk_index = hunk_index,
            };
        }

        var iterator: BodyRowIterator = .{
            .file = file,
            .mode = mode,
            .folded_hunks = folded_hunks,
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
                        if (!isVisibleMetadataLine(line)) continue;
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
                        .folded = self.isFolded(self.hunk_index),
                    } };
                },
                .hunk_lines => {
                    if (self.isFolded(self.hunk_index)) {
                        self.hunk_index += 1;
                        self.phase = .hunk_header;
                        continue;
                    }
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

    fn isFolded(self: BodyRowIterator, hunk_index: usize) bool {
        return hunk_index < self.folded_hunks.len and self.folded_hunks[hunk_index];
    }
};

pub fn renderedBodyLineCount(file: diff_parser.FileDiff, mode: DisplayMode) usize {
    return renderedBodyLineCountFolded(file, mode, &.{});
}

pub fn renderedBodyLineCountFolded(file: diff_parser.FileDiff, mode: DisplayMode, folded_hunks: []const bool) usize {
    var count: usize = 0;
    var rows = BodyRowIterator.initWithFolded(file, mode, folded_hunks);
    while (rows.next() != null) count += 1;
    return count;
}

pub fn hunkBodyLineOffset(file: diff_parser.FileDiff, mode: DisplayMode, hunk_index: usize) usize {
    return hunkBodyLineOffsetFolded(file, mode, hunk_index, &.{});
}

pub fn hunkBodyLineOffsetFolded(file: diff_parser.FileDiff, mode: DisplayMode, hunk_index: usize, folded_hunks: []const bool) usize {
    var offset: usize = 0;
    var rows = BodyRowIterator.initWithFolded(file, mode, folded_hunks);
    while (rows.next()) |row| {
        if (row == .hunk_header and row.hunk_header.hunk_index == hunk_index) return offset;
        offset += 1;
    }
    return offset;
}

pub fn renderedOffsetForCoordinate(
    file: diff_parser.FileDiff,
    mode: DisplayMode,
    coordinate: BodyCoordinate,
    index_opt: ?RenderedLineIndex,
) ?usize {
    const index = if (index_opt) |index|
        if (index.mode == mode and index.hunk_offsets.len == file.hunks.len) index else null
    else
        null;

    return switch (coordinate) {
        .metadata => |metadata_index| visibleMetadataOffset(file, metadata_index),
        .binary_marker => if (file.is_binary) visibleMetadataRowCount(file) else null,
        .hunk_header => |hunk_index| hunkOffsetForCoordinate(file, mode, index, hunk_index),
        .hunk_line => |line| blk: {
            if (line.hunk_index >= file.hunks.len) break :blk null;
            const hunk = file.hunks[line.hunk_index];
            if (line.line_index >= hunk.lines.len) break :blk null;

            const hunk_offset = hunkOffsetForCoordinate(file, mode, index, line.hunk_index) orelse break :blk null;
            if (index) |line_index| {
                if (line_index.hunkLineCount(line.hunk_index) <= 1) break :blk null;
            }
            const local_line_offset = switch (mode) {
                .unified => line.line_index,
                .side_by_side => sideBySideRenderedOffsetForLine(hunk.lines, line.line_index) orelse break :blk null,
            };
            break :blk hunk_offset + 1 + local_line_offset;
        },
    };
}

pub fn coordinateAtOffset(
    file: diff_parser.FileDiff,
    mode: DisplayMode,
    offset: usize,
    folded_hunks: []const bool,
    index_opt: ?RenderedLineIndex,
) ?BodyCoordinate {
    const index = if (index_opt) |index|
        if (index.mode == mode and index.hunk_offsets.len == file.hunks.len) index else null
    else
        null;

    if (index) |line_index| {
        if (offset >= line_index.lineCount()) return null;
    }

    const metadata_rows = visibleMetadataRowCount(file);
    if (offset < metadata_rows) {
        return .{ .metadata = metadataIndexAtVisibleRow(file, offset) orelse return null };
    }

    if (file.is_binary and offset == metadata_rows) return .binary_marker;

    const hunk_index = if (index) |line_index|
        line_index.hunkIndexAtOffset(offset)
    else
        hunkIndexAtOffsetByWalk(file, mode, offset, folded_hunks);
    const hunk_idx = hunk_index orelse return null;
    const hunk_offset = hunkOffsetForCoordinate(file, mode, index, hunk_idx) orelse return null;
    const local_offset = offset - hunk_offset;
    if (local_offset == 0) return .{ .hunk_header = hunk_idx };

    if (isFolded(folded_hunks, hunk_idx)) return null;
    const hunk = file.hunks[hunk_idx];
    const local_line_offset = local_offset - 1;
    const line_index = switch (mode) {
        .unified => if (local_line_offset < hunk.lines.len) local_line_offset else return null,
        .side_by_side => sideBySideLineIndexAtRenderedOffset(hunk.lines, local_line_offset) orelse return null,
    };

    return .{ .hunk_line = .{
        .hunk_index = hunk_idx,
        .line_index = line_index,
    } };
}

fn hunkOffsetForCoordinate(file: diff_parser.FileDiff, mode: DisplayMode, index: ?RenderedLineIndex, hunk_index: usize) ?usize {
    if (hunk_index >= file.hunks.len) return null;
    if (index) |line_index| return line_index.hunkOffset(hunk_index);
    return hunkBodyLineOffset(file, mode, hunk_index);
}

fn hunkIndexAtOffsetByWalk(file: diff_parser.FileDiff, mode: DisplayMode, offset: usize, folded_hunks: []const bool) ?usize {
    var rows = BodyRowIterator.initWithFolded(file, mode, folded_hunks);
    var current_offset: usize = 0;
    var current_hunk: ?usize = null;
    while (rows.next()) |row| : (current_offset += 1) {
        switch (row) {
            .hunk_header => |hunk| current_hunk = hunk.hunk_index,
            .unified_line, .side_by_side => {},
            .metadata, .binary_marker => current_hunk = null,
        }
        if (current_offset == offset) return current_hunk;
    }
    return null;
}

fn isFolded(folded_hunks: []const bool, hunk_index: usize) bool {
    return hunk_index < folded_hunks.len and folded_hunks[hunk_index];
}

pub fn isVisibleMetadataLine(line: []const u8) bool {
    // Path headers are kept in the parsed model for patch generation, but the
    // viewer chrome already shows the active file path.
    return !std.mem.startsWith(u8, line, "--- ") and !std.mem.startsWith(u8, line, "+++ ");
}

fn visibleMetadataRowCount(file: diff_parser.FileDiff) usize {
    var count: usize = 0;
    for (file.metadata) |line| {
        if (isVisibleMetadataLine(line)) count += 1;
    }
    return count;
}

fn metadataIndexAtVisibleRow(file: diff_parser.FileDiff, visible_row: usize) ?usize {
    var row: usize = 0;
    for (file.metadata, 0..) |line, index| {
        if (!isVisibleMetadataLine(line)) continue;
        if (row == visible_row) return index;
        row += 1;
    }
    return null;
}

fn visibleMetadataOffset(file: diff_parser.FileDiff, metadata_index: usize) ?usize {
    if (metadata_index >= file.metadata.len) return null;
    if (!isVisibleMetadataLine(file.metadata[metadata_index])) return null;

    var row: usize = 0;
    for (file.metadata, 0..) |line, index| {
        if (!isVisibleMetadataLine(line)) continue;
        if (index == metadata_index) return row;
        row += 1;
    }
    return null;
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
        return buildFolded(allocator, file, mode, &.{});
    }

    pub fn buildFolded(
        allocator: std.mem.Allocator,
        file: diff_parser.FileDiff,
        mode: DisplayMode,
        folded_hunks: []const bool,
    ) !RenderedLineIndex {
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
        index.recompute(file, folded_hunks);
        return index;
    }

    pub fn recompute(self: *RenderedLineIndex, file: diff_parser.FileDiff, folded_hunks: []const bool) void {
        self.metadata_rows = 0;
        self.binary_rows = 0;
        self.total_rows = 0;

        // Build from the same iterator used by render/search wrappers so the
        // cached index cannot drift from the rendered body row order.
        var rows = BodyRowIterator.initWithFolded(file, self.mode, folded_hunks);
        var offset: usize = 0;
        while (rows.next()) |row| : (offset += 1) {
            switch (row) {
                .metadata => self.metadata_rows += 1,
                .binary_marker => self.binary_rows += 1,
                .hunk_header => |hunk| {
                    if (hunk.hunk_index < self.hunk_offsets.len) {
                        self.hunk_offsets[hunk.hunk_index] = offset;
                    }
                },
                .unified_line, .side_by_side => {},
            }
        }
        self.total_rows = offset;

        for (self.hunk_offsets, 0..) |hunk_offset, hunk_index| {
            const next_offset = if (hunk_index + 1 < self.hunk_offsets.len)
                self.hunk_offsets[hunk_index + 1]
            else
                self.total_rows;
            self.hunk_line_counts[hunk_index] = next_offset - hunk_offset;
        }
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

    pub fn recomputeFile(
        self: *RenderedLineCache,
        document: diff_parser.DiffDocument,
        file_index: usize,
        folded_hunks: []const bool,
    ) void {
        if (file_index >= document.files.len) return;
        const file = document.files[file_index];
        if (file_index < self.unified.len) self.unified[file_index].recompute(file, folded_hunks);
        if (file_index < self.side_by_side.len) self.side_by_side[file_index].recompute(file, folded_hunks);
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

pub const IndexedDiffLine = struct {
    line: diff_parser.DiffLine,
    line_index: usize,
};

pub const SideBySideIndexedPair = struct {
    removed: ?IndexedDiffLine = null,
    added: ?IndexedDiffLine = null,
};

pub const SideBySideIndexedRow = union(enum) {
    single: IndexedDiffLine,
    paired: SideBySideIndexedPair,
};

pub fn sideBySideRenderedOffsetForLine(lines: []const diff_parser.DiffLine, target_line_index: usize) ?usize {
    var rows = SideBySideIndexedIterator.init(lines);
    var offset: usize = 0;
    while (rows.next()) |row| : (offset += 1) {
        switch (row) {
            .single => |line| {
                if (line.line_index == target_line_index) return offset;
            },
            .paired => |pair| {
                if (pair.removed) |line| {
                    if (line.line_index == target_line_index) return offset;
                }
                if (pair.added) |line| {
                    if (line.line_index == target_line_index) return offset;
                }
            },
        }
    }
    return null;
}

pub fn sideBySideLineIndexAtRenderedOffset(lines: []const diff_parser.DiffLine, target_offset: usize) ?usize {
    var rows = SideBySideIndexedIterator.init(lines);
    var offset: usize = 0;
    while (rows.next()) |row| : (offset += 1) {
        if (offset != target_offset) continue;
        return switch (row) {
            .single => |line| line.line_index,
            .paired => |pair| if (pair.removed) |line|
                line.line_index
            else if (pair.added) |line|
                line.line_index
            else
                null,
        };
    }
    return null;
}

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

pub const SideBySideIndexedIterator = struct {
    lines: []const diff_parser.DiffLine,
    index: usize = 0,
    block_removed_start: usize = 0,
    block_removed_len: usize = 0,
    block_added_start: usize = 0,
    block_added_len: usize = 0,
    block_offset: usize = 0,
    in_block: bool = false,

    pub fn init(lines: []const diff_parser.DiffLine) SideBySideIndexedIterator {
        return .{ .lines = lines };
    }

    pub fn next(self: *SideBySideIndexedIterator) ?SideBySideIndexedRow {
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

        const line_index = self.index;
        self.index += 1;
        return .{ .single = .{ .line = line, .line_index = line_index } };
    }

    fn nextBlockRow(self: *SideBySideIndexedIterator) ?SideBySideIndexedRow {
        const max_len = @max(self.block_removed_len, self.block_added_len);
        if (self.block_offset >= max_len) {
            self.index = self.block_added_start + self.block_added_len;
            self.in_block = false;
            return self.next();
        }

        const offset = self.block_offset;
        self.block_offset += 1;
        return .{ .paired = .{
            .removed = if (offset < self.block_removed_len) .{
                .line = self.lines[self.block_removed_start + offset],
                .line_index = self.block_removed_start + offset,
            } else null,
            .added = if (offset < self.block_added_len) .{
                .line = self.lines[self.block_added_start + offset],
                .line_index = self.block_added_start + offset,
            } else null,
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

    try std.testing.expectEqual(@as(usize, 4), hunkBodyLineOffset(file, .side_by_side, 1));
    try std.testing.expectEqual(@as(usize, 6), renderedBodyLineCount(file, .side_by_side));
    try std.testing.expectEqual(@as(usize, 5), hunkBodyLineOffset(file, .unified, 1));
    try std.testing.expectEqual(@as(usize, 7), renderedBodyLineCount(file, .unified));
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
    try std.testing.expectEqual(@as(usize, 1), unified.metadata_rows);
    try std.testing.expectEqual(@as(usize, 0), unified.binary_rows);
    try std.testing.expectEqual(@as(usize, 6), unified.hunkLineCount(0));
    try std.testing.expectEqual(@as(usize, 5), side_by_side.hunkLineCount(0));
}

test "rendered line index can fold hunk bodies in place" {
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/a b/a",
        .metadata = &.{"index 1..2"},
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
    const folded = [_]bool{ true, false };

    var index = try RenderedLineIndex.buildFolded(std.testing.allocator, file, .unified, &folded);
    defer index.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), index.hunkLineCount(0));
    try std.testing.expectEqual(@as(usize, 2), index.hunkOffset(1));
    try std.testing.expectEqual(@as(?usize, null), renderedOffsetForCoordinate(file, .unified, .{
        .hunk_line = .{ .hunk_index = 0, .line_index = 0 },
    }, index));

    var rows = BodyRowIterator.initAtWithFolded(file, .unified, index, index.hunkOffset(0), &folded);
    const header = rows.next().?.hunk_header;
    try std.testing.expect(header.folded);
    try std.testing.expectEqual(@as(usize, 1), rows.next().?.hunk_header.hunk_index);

    var unfolded = folded;
    unfolded[0] = false;
    index.recompute(file, &unfolded);
    try std.testing.expectEqual(@as(usize, 3), index.hunkLineCount(0));
    try std.testing.expectEqual(@as(?usize, index.hunkOffset(0) + 1), renderedOffsetForCoordinate(file, .unified, .{
        .hunk_line = .{ .hunk_index = 0, .line_index = 0 },
    }, index));
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

test "rendered offset maps added side of paired rows to the paired row" {
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
        },
    };

    var index = try RenderedLineIndex.build(std.testing.allocator, file, .side_by_side);
    defer index.deinit(std.testing.allocator);

    const removed_offset = renderedOffsetForCoordinate(file, .side_by_side, .{
        .hunk_line = .{ .hunk_index = 0, .line_index = 1 },
    }, index);
    const added_offset = renderedOffsetForCoordinate(file, .side_by_side, .{
        .hunk_line = .{ .hunk_index = 0, .line_index = 3 },
    }, index);

    try std.testing.expectEqual(removed_offset, added_offset);
    try std.testing.expectEqual(@as(?usize, index.hunkOffset(0) + 2), added_offset);
}

test "coordinateAtOffset maps rendered rows back to body coordinates" {
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
                    .{ .kind = .context, .text = "same", .old_line = 3, .new_line = 3 },
                },
            },
        },
    };

    var unified = try RenderedLineIndex.build(std.testing.allocator, file, .unified);
    defer unified.deinit(std.testing.allocator);
    var side_by_side = try RenderedLineIndex.build(std.testing.allocator, file, .side_by_side);
    defer side_by_side.deinit(std.testing.allocator);

    try std.testing.expectEqual(BodyCoordinate{ .metadata = 0 }, coordinateAtOffset(file, .unified, 0, &.{}, unified).?);
    try std.testing.expectEqual(BodyCoordinate{ .hunk_header = 0 }, coordinateAtOffset(file, .unified, unified.hunkOffset(0), &.{}, unified).?);
    try std.testing.expectEqual(BodyCoordinate{ .hunk_line = .{ .hunk_index = 0, .line_index = 1 } }, coordinateAtOffset(file, .unified, unified.hunkOffset(0) + 2, &.{}, unified).?);

    // Paired side-by-side rows use the first raw hunk line represented by the row.
    try std.testing.expectEqual(BodyCoordinate{ .hunk_line = .{ .hunk_index = 0, .line_index = 0 } }, coordinateAtOffset(file, .side_by_side, side_by_side.hunkOffset(0) + 1, &.{}, side_by_side).?);
    try std.testing.expectEqual(BodyCoordinate{ .hunk_line = .{ .hunk_index = 0, .line_index = 1 } }, coordinateAtOffset(file, .side_by_side, side_by_side.hunkOffset(0) + 2, &.{}, side_by_side).?);
}

test "coordinateAtOffset maps binary marker" {
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/bin b/bin",
        .metadata = &.{"Binary files a/bin and b/bin differ"},
        .hunks = &.{},
        .is_binary = true,
    };

    try std.testing.expectEqual(BodyCoordinate.binary_marker, coordinateAtOffset(file, .unified, 1, &.{}, null).?);
}

test "rendered offset rejects stale coordinates" {
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/a b/a",
        .metadata = &.{"index 1..2"},
        .hunks = &.{.{
            .old_start = 1,
            .old_count = 1,
            .new_start = 1,
            .new_count = 1,
            .section = "first",
            .lines = &.{.{ .kind = .context, .text = "same", .old_line = 1, .new_line = 1 }},
        }},
    };

    try std.testing.expect(renderedOffsetForCoordinate(file, .unified, .{ .metadata = 9 }, null) == null);
    try std.testing.expect(renderedOffsetForCoordinate(file, .unified, .{ .hunk_header = 2 }, null) == null);
    try std.testing.expect(renderedOffsetForCoordinate(file, .unified, .{
        .hunk_line = .{ .hunk_index = 0, .line_index = 3 },
    }, null) == null);
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
