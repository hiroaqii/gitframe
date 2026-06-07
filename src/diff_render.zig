const std = @import("std");
const chasen = @import("chasen");
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

pub const RenderOptions = struct {
    requested_mode: DisplayMode = .unified,
    scroll: usize = 0,
    highlighted_hunk: ?usize = null,
};

pub const FileStats = struct {
    added: usize = 0,
    removed: usize = 0,
};

pub fn effectiveMode(width: u16, requested_mode: DisplayMode) DisplayMode {
    if (requested_mode == .side_by_side and width < side_by_side_min_width) return .unified;
    return requested_mode;
}

pub fn fileStats(file: diff_parser.FileDiff) FileStats {
    var stats: FileStats = .{};
    for (file.hunks) |hunk| {
        for (hunk.lines) |line| {
            switch (line.kind) {
                .added => stats.added += 1,
                .removed => stats.removed += 1,
                else => {},
            }
        }
    }
    return stats;
}

pub fn displayPath(file: diff_parser.FileDiff) []const u8 {
    if (file.new_path) |path| return stripGitPathPrefix(path);
    if (file.old_path) |path| return stripGitPathPrefix(path);
    return file.header;
}

pub fn renderedBodyLineCount(file: diff_parser.FileDiff, mode: DisplayMode) usize {
    if (file.is_binary) return file.metadata.len + 1;

    var count = file.metadata.len;
    for (file.hunks) |hunk| {
        count += 1;
        count += renderedHunkLineCount(hunk.lines, mode);
    }
    return count;
}

pub fn hunkBodyLineOffset(file: diff_parser.FileDiff, mode: DisplayMode, hunk_index: usize) usize {
    var offset = file.metadata.len;
    for (file.hunks, 0..) |hunk, index| {
        if (index == hunk_index) return offset;
        offset += 1 + renderedHunkLineCount(hunk.lines, mode);
    }
    return offset;
}

pub fn visibleBodyRows(surface_height: u16) usize {
    return if (surface_height > body_start_row) surface_height - body_start_row else 0;
}

pub fn renderFile(surface: *chasen.Surface, file: diff_parser.FileDiff, options: RenderOptions) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    const mode = effectiveMode(size.width, options.requested_mode);
    try renderFileHeader(surface, file, mode);

    var cursor: BodyCursor = .{
        .scroll = options.scroll,
        .height = size.height,
    };
    for (file.metadata) |line| {
        const row = cursor.nextRow() orelse continue;
        try copyClippedTextAt(surface, 0, row, line, style_metadata);
    }

    if (file.is_binary) {
        if (cursor.nextRow()) |row| _ = surface.borrowTextAt(0, row, "Binary file", style_warning);
        return;
    }

    for (file.hunks, 0..) |hunk, hunk_index| {
        if (cursor.nextRow()) |row| {
            const style = if (options.highlighted_hunk != null and options.highlighted_hunk.? == hunk_index)
                style_selected_hunk
            else
                style_hunk;
            const header = try std.fmt.allocPrint(surface.frameAllocator(), "@@ -{d},{d} +{d},{d} @@ {s}", .{
                hunk.old_start,
                hunk.old_count,
                hunk.new_start,
                hunk.new_count,
                hunk.section,
            });
            try drawHunkHeader(surface, row, header, style, mode);
        }

        switch (mode) {
            .unified => try renderUnifiedHunkLines(surface, hunk.lines, &cursor),
            .side_by_side => try renderSideBySideHunkLines(surface, hunk.lines, &cursor),
        }
    }
}

fn renderFileHeader(surface: *chasen.Surface, file: diff_parser.FileDiff, mode: DisplayMode) !void {
    const stats = fileStats(file);
    try copyClippedTextAt(surface, 0, 0, displayPath(file), style_file_header);
    const summary = try std.fmt.allocPrint(surface.frameAllocator(), "{s}  +{d} -{d}", .{
        mode.label(),
        stats.added,
        stats.removed,
    });
    try copyClippedTextAt(surface, 0, 1, summary, style_metadata);
}

fn drawHunkHeader(surface: *chasen.Surface, row: u16, header: []const u8, style: chasen.TextStyle, mode: DisplayMode) !void {
    if (mode == .side_by_side and surface.size().width >= side_by_side_min_width) {
        const gutter_col = surface.size().width / 2;
        var old_column = surface.child(.{
            .col = 0,
            .row = row,
            .width = gutter_col,
            .height = 1,
        });
        try copyClippedTextAt(&old_column, 0, 0, header, style);
        _ = surface.borrowTextAt(gutter_col, row, "│", style_metadata);
        return;
    }

    try copyClippedTextAt(surface, 0, row, header, style);
}

const body_start_row: u16 = 3;

const BodyCursor = struct {
    scroll: usize,
    virtual_row: usize = 0,
    row: u16 = body_start_row,
    height: u16,

    fn nextRow(self: *BodyCursor) ?u16 {
        defer self.virtual_row += 1;
        if (self.virtual_row < self.scroll) return null;
        if (self.row >= self.height) return null;
        const row = self.row;
        self.row += 1;
        return row;
    }
};

fn renderUnifiedHunkLines(surface: *chasen.Surface, lines: []const diff_parser.DiffLine, cursor: *BodyCursor) !void {
    for (lines) |line| {
        const row = cursor.nextRow() orelse continue;
        try drawUnifiedLine(surface, row, line);
    }
}

fn renderSideBySideHunkLines(surface: *chasen.Surface, lines: []const diff_parser.DiffLine, cursor: *BodyCursor) !void {
    const size = surface.size();
    if (size.width < side_by_side_min_width) return renderUnifiedHunkLines(surface, lines, cursor);

    const gutter_col = size.width / 2;
    var index: usize = 0;
    while (index < lines.len) {
        const row = cursor.nextRow();
        const old_line = lines[index];
        if (old_line.kind == .removed and index + 1 < lines.len and lines[index + 1].kind == .added) {
            if (row) |visible_row| try drawSideBySidePair(surface, visible_row, old_line, lines[index + 1], gutter_col);
            index += 2;
        } else {
            if (row) |visible_row| try drawSideBySideSingle(surface, visible_row, old_line, gutter_col);
            index += 1;
        }
    }
}

fn renderedHunkLineCount(lines: []const diff_parser.DiffLine, mode: DisplayMode) usize {
    if (mode == .unified) return lines.len;

    var count: usize = 0;
    var index: usize = 0;
    while (index < lines.len) {
        const old_line = lines[index];
        if (old_line.kind == .removed and index + 1 < lines.len and lines[index + 1].kind == .added) {
            index += 2;
        } else {
            index += 1;
        }
        count += 1;
    }
    return count;
}

fn drawUnifiedLine(surface: *chasen.Surface, row: u16, line: diff_parser.DiffLine) !void {
    const style = styleForLine(line.kind);
    const prefix = prefixForLine(line.kind);

    _ = try surface.copyTextAt(0, row, try lineNumberText(surface, line.old_line), style_line_number);
    _ = try surface.copyTextAt(5, row, try lineNumberText(surface, line.new_line), style_line_number);
    _ = surface.borrowTextAt(10, row, prefix, style);
    try copyClippedTextAt(surface, 12, row, line.text, style);
}

fn drawSideBySidePair(surface: *chasen.Surface, row: u16, removed: diff_parser.DiffLine, added: diff_parser.DiffLine, gutter_col: u16) !void {
    var columns = sideBySideRowColumns(surface, row, gutter_col);
    try drawSideBySideOld(&columns.old, 0, removed);
    try drawSideBySideNew(&columns.new, 0, added);
    drawSideBySideGutter(surface, row, gutter_col);
}

fn drawSideBySideSingle(surface: *chasen.Surface, row: u16, line: diff_parser.DiffLine, gutter_col: u16) !void {
    var columns = sideBySideRowColumns(surface, row, gutter_col);
    switch (line.kind) {
        .removed => {
            try drawSideBySideOld(&columns.old, 0, line);
            drawSideBySideGutter(surface, row, gutter_col);
        },
        .added => {
            try drawSideBySideNew(&columns.new, 0, line);
            drawSideBySideGutter(surface, row, gutter_col);
        },
        .context => {
            try drawSideBySideOld(&columns.old, 0, line);
            try drawSideBySideNew(&columns.new, 0, line);
            drawSideBySideGutter(surface, row, gutter_col);
        },
        .metadata => {
            try copyClippedTextAt(surface, 0, row, line.text, style_metadata);
        },
    }
}

fn drawSideBySideGutter(surface: *chasen.Surface, row: u16, gutter_col: u16) void {
    _ = surface.borrowTextAt(gutter_col, row, "│", style_metadata);
}

const SideBySideColumns = struct {
    old: chasen.Surface,
    new: chasen.Surface,
};

fn sideBySideRowColumns(surface: *chasen.Surface, row: u16, gutter_col: u16) SideBySideColumns {
    const size = surface.size();
    const new_col = gutter_col + 1;
    return .{
        .old = surface.child(.{
            .col = 0,
            .row = row,
            .width = gutter_col,
            .height = 1,
        }),
        .new = surface.child(.{
            .col = new_col,
            .row = row,
            .width = if (size.width > new_col) size.width - new_col else 0,
            .height = 1,
        }),
    };
}

fn drawSideBySideOld(surface: *chasen.Surface, row: u16, line: diff_parser.DiffLine) !void {
    _ = try surface.copyTextAt(0, row, try lineNumberText(surface, line.old_line), style_line_number);
    const prefix = if (line.kind == .removed) "-" else " ";
    _ = surface.borrowTextAt(5, row, prefix, styleForLine(line.kind));
    try copyClippedTextAt(surface, 7, row, line.text, styleForLine(line.kind));
}

fn drawSideBySideNew(surface: *chasen.Surface, row: u16, line: diff_parser.DiffLine) !void {
    _ = try surface.copyTextAt(0, row, try lineNumberText(surface, line.new_line), style_line_number);
    const prefix = if (line.kind == .added) "+" else " ";
    _ = surface.borrowTextAt(5, row, prefix, styleForLine(line.kind));
    try copyClippedTextAt(surface, 7, row, line.text, styleForLine(line.kind));
}

fn copyClippedTextAt(surface: *chasen.Surface, col: u16, row: u16, text: []const u8, style: chasen.TextStyle) !void {
    const size = surface.size();
    if (col >= size.width) return;
    const max_width = size.width - col;
    const clipped = chasen.text.clipToWidth(text, max_width);
    if (clipped.len == 0) return;
    _ = try surface.copyTextAt(col, row, clipped, style);
}

fn lineNumberText(surface: *chasen.Surface, line: ?u32) ![]const u8 {
    return if (line) |n|
        std.fmt.allocPrint(surface.frameAllocator(), "{d: >4}", .{n})
    else
        surface.copyText("    ");
}

fn styleForLine(kind: diff_parser.DiffLine.Kind) chasen.TextStyle {
    return switch (kind) {
        .added => style_added,
        .removed => style_removed,
        .context => style_context,
        .metadata => style_metadata,
    };
}

fn prefixForLine(kind: diff_parser.DiffLine.Kind) []const u8 {
    return switch (kind) {
        .added => "+",
        .removed => "-",
        .context => " ",
        .metadata => "\\",
    };
}

fn stripGitPathPrefix(path: []const u8) []const u8 {
    if (std.mem.eql(u8, path, "/dev/null")) return path;
    if (std.mem.startsWith(u8, path, "a/") or std.mem.startsWith(u8, path, "b/")) return path[2..];
    return path;
}

const side_by_side_min_width: u16 = 72;

const style_file_header: chasen.TextStyle = .{ .bold = true, .fg = .{ .index = 11 } };
const style_hunk: chasen.TextStyle = .{ .bold = true, .fg = .{ .index = 14 } };
const style_selected_hunk: chasen.TextStyle = .{ .bold = true, .reverse = true, .fg = .{ .index = 14 } };
const style_added: chasen.TextStyle = .{ .fg = .{ .index = 2 } };
const style_removed: chasen.TextStyle = .{ .fg = .{ .index = 9 } };
const style_context: chasen.TextStyle = .{};
const style_metadata: chasen.TextStyle = .{ .fg = .gray };
const style_line_number: chasen.TextStyle = .{ .fg = .gray };
const style_warning: chasen.TextStyle = .{ .fg = .{ .index = 11 } };

test "display mode falls back to unified on narrow panes" {
    try std.testing.expectEqual(DisplayMode.unified, effectiveMode(40, .side_by_side));
    try std.testing.expectEqual(DisplayMode.side_by_side, effectiveMode(90, .side_by_side));
    try std.testing.expectEqual(DisplayMode.unified, effectiveMode(90, .unified));
}

test "fileStats counts added and removed hunk lines" {
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/a b/a",
        .metadata = &.{},
        .hunks = &.{
            .{
                .old_start = 1,
                .old_count = 2,
                .new_start = 1,
                .new_count = 2,
                .section = "",
                .lines = &.{
                    .{ .kind = .removed, .text = "old", .old_line = 1 },
                    .{ .kind = .added, .text = "new", .new_line = 1 },
                    .{ .kind = .context, .text = "same", .old_line = 2, .new_line = 2 },
                },
            },
        },
    };

    try std.testing.expectEqual(FileStats{ .added = 1, .removed = 1 }, fileStats(file));
}

test "displayPath prefers new path and strips git prefixes" {
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/src/main.zig b/src/main.zig",
        .old_path = "a/src/main.zig",
        .new_path = "b/src/main.zig",
        .metadata = &.{},
        .hunks = &.{},
    };

    try std.testing.expectEqualStrings("src/main.zig", displayPath(file));
}

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

test "side-by-side clips old column before new column" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 5);
    defer ts.deinit();

    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/src/main.zig b/src/main.zig",
        .old_path = "a/src/main.zig",
        .new_path = "b/src/main.zig",
        .metadata = &.{},
        .hunks = &.{
            .{
                .old_start = 1,
                .old_count = 1,
                .new_start = 1,
                .new_count = 1,
                .section = "",
                .lines = &.{
                    .{
                        .kind = .removed,
                        .text = "old text that is intentionally much longer than the left side-by-side column",
                        .old_line = 1,
                    },
                    .{
                        .kind = .added,
                        .text = "new",
                        .new_line = 1,
                    },
                },
            },
        },
    };

    try renderFile(&ts.surface, file, .{ .requested_mode = .side_by_side });

    const gutter_col: u16 = 40;
    try ts.expectCellText(gutter_col, 4, "│");
    try ts.expectCellText(gutter_col + 8, 4, "n");
    try ts.expectCellText(gutter_col + 9, 4, "e");
    try ts.expectCellText(gutter_col + 10, 4, "w");
    try ts.expectCellText(gutter_col + 12, 4, " ");
}

test "side-by-side hunk header is clipped before the new column" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 5);
    defer ts.deinit();

    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/src/main.zig b/src/main.zig",
        .old_path = "a/src/main.zig",
        .new_path = "b/src/main.zig",
        .metadata = &.{},
        .hunks = &.{
            .{
                .old_start = 102,
                .old_count = 36,
                .new_start = 134,
                .new_count = 67,
                .section = "fn renderFileHeader(surface: *chasen.Surface, file: diff_parser.FileDiff, mode: DisplayMode) !void",
                .lines = &.{},
            },
        },
    };

    try renderFile(&ts.surface, file, .{ .requested_mode = .side_by_side });

    const gutter_col: u16 = 40;
    try ts.expectCellText(0, 3, "@");
    try ts.expectCellText(1, 3, "@");
    try ts.expectCellText(gutter_col, 3, "│");
    try ts.expectCellText(gutter_col + 1, 3, " ");
    try ts.expectCellText(gutter_col + 8, 3, " ");
}
