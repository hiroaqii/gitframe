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

pub fn renderFile(surface: *chasen.Surface, file: diff_parser.FileDiff, options: RenderOptions) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    const mode = effectiveMode(size.width, options.requested_mode);
    try renderFileHeader(surface, file, mode);

    var row: u16 = 3;
    for (file.metadata) |line| {
        if (row >= size.height) return;
        _ = try surface.copyTextAt(0, row, line, style_metadata);
        row += 1;
    }

    if (file.is_binary) {
        if (row < size.height) _ = surface.borrowTextAt(0, row, "Binary file", style_warning);
        return;
    }

    for (file.hunks) |hunk| {
        if (row >= size.height) return;
        _ = try surface.printAt(0, row, style_hunk, "@@ -{d},{d} +{d},{d} @@ {s}", .{
            hunk.old_start,
            hunk.old_count,
            hunk.new_start,
            hunk.new_count,
            hunk.section,
        });
        row += 1;

        switch (mode) {
            .unified => try renderUnifiedHunkLines(surface, hunk.lines, &row),
            .side_by_side => try renderSideBySideHunkLines(surface, hunk.lines, &row),
        }
    }
}

fn renderFileHeader(surface: *chasen.Surface, file: diff_parser.FileDiff, mode: DisplayMode) !void {
    const stats = fileStats(file);
    _ = try surface.copyTextAt(0, 0, displayPath(file), style_file_header);
    _ = try surface.printAt(0, 1, style_metadata, "{s}  +{d} -{d}", .{
        mode.label(),
        stats.added,
        stats.removed,
    });
}

fn renderUnifiedHunkLines(surface: *chasen.Surface, lines: []const diff_parser.DiffLine, row: *u16) !void {
    const height = surface.size().height;
    for (lines) |line| {
        if (row.* >= height) return;
        try drawUnifiedLine(surface, row.*, line);
        row.* += 1;
    }
}

fn renderSideBySideHunkLines(surface: *chasen.Surface, lines: []const diff_parser.DiffLine, row: *u16) !void {
    const size = surface.size();
    if (size.width < side_by_side_min_width) return renderUnifiedHunkLines(surface, lines, row);

    const gutter_col = size.width / 2;
    var index: usize = 0;
    while (index < lines.len) {
        if (row.* >= size.height) return;

        const old_line = lines[index];
        if (old_line.kind == .removed and index + 1 < lines.len and lines[index + 1].kind == .added) {
            try drawSideBySidePair(surface, row.*, old_line, lines[index + 1], gutter_col);
            index += 2;
        } else {
            try drawSideBySideSingle(surface, row.*, old_line, gutter_col);
            index += 1;
        }
        row.* += 1;
    }
}

fn drawUnifiedLine(surface: *chasen.Surface, row: u16, line: diff_parser.DiffLine) !void {
    const style = styleForLine(line.kind);
    const prefix = prefixForLine(line.kind);

    _ = try surface.copyTextAt(0, row, try lineNumberText(surface, line.old_line), style_line_number);
    _ = try surface.copyTextAt(5, row, try lineNumberText(surface, line.new_line), style_line_number);
    _ = surface.borrowTextAt(10, row, prefix, style);
    _ = try surface.copyTextAt(12, row, line.text, style);
}

fn drawSideBySidePair(surface: *chasen.Surface, row: u16, removed: diff_parser.DiffLine, added: diff_parser.DiffLine, gutter_col: u16) !void {
    var columns = sideBySideRowColumns(surface, row, gutter_col);
    try drawSideBySideOld(&columns.old, 0, removed);
    try drawSideBySideNew(&columns.new, 0, added);
    _ = surface.borrowTextAt(gutter_col, row, "│", style_metadata);
}

fn drawSideBySideSingle(surface: *chasen.Surface, row: u16, line: diff_parser.DiffLine, gutter_col: u16) !void {
    var columns = sideBySideRowColumns(surface, row, gutter_col);
    switch (line.kind) {
        .removed => {
            try drawSideBySideOld(&columns.old, 0, line);
            _ = surface.borrowTextAt(gutter_col, row, "│", style_metadata);
        },
        .added => {
            try drawSideBySideNew(&columns.new, 0, line);
            _ = surface.borrowTextAt(gutter_col, row, "│", style_metadata);
        },
        .context => {
            try drawSideBySideOld(&columns.old, 0, line);
            try drawSideBySideNew(&columns.new, 0, line);
            _ = surface.borrowTextAt(gutter_col, row, "│", style_metadata);
        },
        .metadata => {
            _ = try surface.copyTextAt(0, row, line.text, style_metadata);
        },
    }
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
    _ = try surface.copyTextAt(7, row, line.text, styleForLine(line.kind));
}

fn drawSideBySideNew(surface: *chasen.Surface, row: u16, line: diff_parser.DiffLine) !void {
    _ = try surface.copyTextAt(0, row, try lineNumberText(surface, line.new_line), style_line_number);
    const prefix = if (line.kind == .added) "+" else " ";
    _ = surface.borrowTextAt(5, row, prefix, styleForLine(line.kind));
    _ = try surface.copyTextAt(7, row, line.text, styleForLine(line.kind));
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
