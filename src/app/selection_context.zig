//! Human-readable context around an already-authoritative copy payload.
//! No source reads, Git resolution, or clipboard effects belong here.

const std = @import("std");
const commit_diff = @import("../git/commit_diff.zig");
const diff_selection = @import("../diff/selection.zig");

pub const LineRange = struct { first: u32, last: u32 };

pub const Location = struct {
    repository_root: []const u8,
    path: []const u8,
    first_line: u32,
    last_line: u32,
    surface: union(enum) {
        repository,
        committed: struct {
            name: enum { compare, history },
            basis: commit_diff.Basis,
            side: diff_selection.Side,
            /// The first interval is mandatory above; these retain later gaps.
            following_ranges: []const LineRange = &.{},
        },
    } = .repository,
};

pub fn format(allocator: std.mem.Allocator, location: Location, code: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    writeMarkdown(&out.writer, location, code) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeMarkdown(writer: *std.Io.Writer, location: Location, code: []const u8) std.Io.Writer.Error!void {
    try writer.writeAll("Repository: ");
    try writePath(writer, location.repository_root);
    switch (location.surface) {
        .repository => try writer.writeAll("\nSurface: Repository"),
        .committed => |committed| {
            try writer.print("\nSurface: {s}\nBefore: ", .{switch (committed.name) {
                .compare => "Compare",
                .history => "History",
            }});
            if (committed.basis.before == .empty_tree) try writer.writeAll("empty-tree ");
            const before = committed.basis.beforeOid();
            try writer.print("{s}\nAfter: {s}", .{ before.slice(), committed.basis.after.slice() });
        },
    }
    try writer.writeAll("\nFile: ");
    try writePath(writer, location.path);
    if (location.surface == .committed) try writer.print("\nSide: {s}", .{@tagName(location.surface.committed.side)});
    try writer.print("\nLines: {d}", .{location.first_line});
    if (location.last_line != location.first_line) try writer.print("-{d}", .{location.last_line});
    if (location.surface == .committed) for (location.surface.committed.following_ranges) |range| {
        try writer.print(", {d}", .{range.first});
        if (range.last != range.first) try writer.print("-{d}", .{range.last});
    };
    try writer.writeAll("\n\nSelected code:\n");

    var fence_length: usize = 3;
    var run: usize = 0;
    for (code) |byte| {
        run = if (byte == '`') run + 1 else 0;
        fence_length = @max(fence_length, run + 1);
    }
    for (0..fence_length) |_| try writer.writeByte('`');
    try writer.writeByte('\n');
    try writer.writeAll(code);
    // This one LF is framing even when the payload already ends in LF.
    try writer.writeByte('\n');
    for (0..fence_length) |_| try writer.writeByte('`');
    try writer.writeAll("\n\nQuestion:\n");
}

fn writePath(writer: *std.Io.Writer, path: []const u8) !void {
    for (path) |byte| switch (byte) {
        '\\' => try writer.writeAll("\\\\"),
        '\r' => try writer.writeAll("\\r"),
        '\n' => try writer.writeAll("\\n"),
        '\t' => try writer.writeAll("\\t"),
        else => try writer.writeByte(byte),
    };
}

test "selection context keeps Repository fields and exact payload framing" {
    const allocator = std.testing.allocator;
    const location: Location = .{
        .repository_root = "/work/repo",
        .path = "src/file.zig",
        .first_line = 42,
        .last_line = 43,
    };
    for ([_][]const u8{ "\tfirst  \nsecond", "\tfirst  \nsecond\n", "" }) |code| {
        const actual = try format(allocator, location, code);
        defer allocator.free(actual);
        const expected = try std.fmt.allocPrint(
            allocator,
            "Repository: /work/repo\nSurface: Repository\nFile: src/file.zig\nLines: 42-43\n\nSelected code:\n```\n{s}\n```\n\nQuestion:\n",
            .{code},
        );
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "selection context avoids payload fences and escapes only metadata" {
    const allocator = std.testing.allocator;
    const actual = try format(allocator, .{
        .repository_root = "/work/a\\b",
        .path = "a\n\t\r.zig",
        .first_line = 7,
        .last_line = 7,
    }, "```\n\tkeep `  \n````\n");
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(
        "Repository: /work/a\\\\b\nSurface: Repository\nFile: a\\n\\t\\r.zig\nLines: 7\n\nSelected code:\n`````\n```\n\tkeep `  \n````\n\n`````\n\nQuestion:\n",
        actual,
    );
}

test "selection context releases partial formatter allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn check(allocator: std.mem.Allocator) !void {
            const text = try format(allocator, .{
                .repository_root = "/work/repo",
                .path = "file.zig",
                .first_line = 1,
                .last_line = 1,
            }, "selected");
            defer allocator.free(text);
        }
    }.check, .{});
}
