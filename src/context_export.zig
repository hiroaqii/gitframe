const std = @import("std");
const context = @import("context.zig");

pub fn writeSelectionContext(writer: *std.Io.Writer, selection: context.SelectionContext) !void {
    try writer.writeAll("{");
    try writer.writeAll("\"schema_version\":1");
    try writer.writeAll(",\"source_kind\":");
    try writeString(writer, sourceKindName(selection.source.kind));
    try writer.writeAll(",\"source_label\":");
    try writeString(writer, selection.source.label);
    try writer.writeAll(",\"source_detail\":");
    try writeSourceDetail(writer, selection.source);
    try writer.writeAll(",\"repo_root\":");
    try writeOptionalString(writer, selection.repo_root);
    try writer.writeAll(",\"selection\":");
    try writeSelection(writer, selection.selected);
    try writer.writeAll("}\n");
}

fn writeSourceDetail(writer: *std.Io.Writer, source: context.SourceContext) !void {
    // The exported schema keeps simple source details as a string, but no-index
    // needs a structured pair so consumers do not have to parse a display label.
    if (source.kind == .no_index) {
        try writer.writeAll("{\"left_path\":");
        try writeOptionalString(writer, source.left_path);
        try writer.writeAll(",\"right_path\":");
        try writeOptionalString(writer, source.right_path);
        try writer.writeAll("}");
        return;
    }

    try writeOptionalString(writer, source.detail);
}

fn writeSelection(writer: *std.Io.Writer, selection: ?context.Selection) !void {
    const value = selection orelse {
        try writer.writeAll("null");
        return;
    };

    try writer.writeAll("{");
    switch (value) {
        .diff_file => |file| {
            try writer.writeAll("\"kind\":\"diff_file\"");
            try writer.print(",\"file_index\":{d}", .{file.file_index});
            try writer.writeAll(",\"display_path\":");
            try writeString(writer, file.display_path);
            try writer.writeAll(",\"path_key\":");
            try writeOptionalString(writer, file.path_key);
            try writer.writeAll(",\"hunk_index\":");
            try writeOptionalNumber(writer, file.hunk_index);
        },
        .status_only => |status| {
            try writer.writeAll("\"kind\":\"status_only\"");
            try writer.print(",\"status_index\":{d}", .{status.status_index});
            try writer.writeAll(",\"path_key\":");
            try writeOptionalString(writer, status.path_key);
        },
    }
    try writer.writeAll("}");
}

fn writeOptionalNumber(writer: *std.Io.Writer, value: ?usize) !void {
    if (value) |number| {
        try writer.print("{d}", .{number});
    } else {
        try writer.writeAll("null");
    }
}

fn writeOptionalString(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |text| {
        try writeString(writer, text);
    } else {
        try writer.writeAll("null");
    }
}

fn writeString(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0...0x08, 0x0b...0x0c, 0x0e...0x1f => try writer.print("\\u{x:0>4}", .{byte}),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

fn sourceKindName(kind: context.SourceKind) []const u8 {
    return switch (kind) {
        .unstaged => "unstaged",
        .cached => "cached",
        .stdin => "stdin",
        .pager => "pager",
        .patch_file => "patch_file",
        .range => "range",
        .no_index => "no_index",
    };
}

test "writeSelectionContext emits diff file selection json" {
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeSelectionContext(&writer, .{
        .repo_root = "/repo",
        .source = .{ .kind = .range, .label = "range", .detail = "main...HEAD" },
        .selected = .{ .diff_file = .{
            .file_index = 1,
            .display_path = "src/main.zig",
            .path_key = "src/main.zig",
            .hunk_index = 2,
        } },
    });

    try std.testing.expectEqualStrings(
        "{\"schema_version\":1,\"source_kind\":\"range\",\"source_label\":\"range\",\"source_detail\":\"main...HEAD\",\"repo_root\":\"/repo\",\"selection\":{\"kind\":\"diff_file\",\"file_index\":1,\"display_path\":\"src/main.zig\",\"path_key\":\"src/main.zig\",\"hunk_index\":2}}\n",
        writer.buffered(),
    );
}

test "writeSelectionContext keeps no-index source detail structured" {
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeSelectionContext(&writer, .{
        .repo_root = null,
        .source = .{
            .kind = .no_index,
            .label = "difftool",
            .left_path = "before.zig",
            .right_path = "after.zig",
        },
        .selected = null,
    });

    try std.testing.expectEqualStrings(
        "{\"schema_version\":1,\"source_kind\":\"no_index\",\"source_label\":\"difftool\",\"source_detail\":{\"left_path\":\"before.zig\",\"right_path\":\"after.zig\"},\"repo_root\":null,\"selection\":null}\n",
        writer.buffered(),
    );
}

test "writeSelectionContext emits status-only selection json" {
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeSelectionContext(&writer, .{
        .repo_root = "/repo",
        .source = .{ .kind = .unstaged, .label = "unstaged changes" },
        .selected = .{ .status_only = .{
            .status_index = 3,
            .path_key = "src/new.zig",
        } },
    });

    try std.testing.expectEqualStrings(
        "{\"schema_version\":1,\"source_kind\":\"unstaged\",\"source_label\":\"unstaged changes\",\"source_detail\":null,\"repo_root\":\"/repo\",\"selection\":{\"kind\":\"status_only\",\"status_index\":3,\"path_key\":\"src/new.zig\"}}\n",
        writer.buffered(),
    );
}

test "writeSelectionContext escapes strings" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeSelectionContext(&writer, .{
        .repo_root = null,
        .source = .{ .kind = .patch_file, .label = "patch file", .detail = "a\"b\\c\n" },
        .selected = null,
    });

    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "a\\\"b\\\\c\\n") != null);
}
