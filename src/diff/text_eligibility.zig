//! Per-file safety classification for parsed diff text.
//!
//! Paths deliberately remain raw Git bytes. Only hunk sections and logical
//! line bodies enter Unicode-aware rendering, syntax, search, and selection,
//! so those fields are the ones classified here.

const std = @import("std");
const diff_parser = @import("parser.zig");

pub const FileTextEligibility = enum {
    selectable_utf8,
    inert_invalid_utf8,

    pub fn selectable(self: FileTextEligibility) bool {
        return self == .selectable_utf8;
    }
};

pub fn classify(file: diff_parser.FileDiff) FileTextEligibility {
    for (file.hunks) |hunk| {
        if (!std.unicode.utf8ValidateSlice(hunk.section)) return .inert_invalid_utf8;
        for (hunk.lines) |line| {
            if (!std.unicode.utf8ValidateSlice(line.text)) return .inert_invalid_utf8;
        }
    }
    return .selectable_utf8;
}

pub fn classifyDocument(
    allocator: std.mem.Allocator,
    document: diff_parser.DiffDocument,
) ![]FileTextEligibility {
    const result = try allocator.alloc(FileTextEligibility, document.files.len);
    for (document.files, result) |file, *eligibility| eligibility.* = classify(file);
    return result;
}

test "classification is per file and excludes raw path bytes" {
    const valid_lines = [_]diff_parser.DiffLine{
        .{ .kind = .context, .text = "valid 界" },
    };
    const invalid_lines = [_]diff_parser.DiffLine{
        .{ .kind = .added, .text = "bad\xff" },
    };
    const files = [_]diff_parser.FileDiff{
        .{
            .header = "valid",
            .old_path = "raw-\xff",
            .hunks = &.{.{ .old_start = 1, .old_count = 1, .new_start = 1, .new_count = 1, .section = "", .lines = &valid_lines }},
            .metadata = &.{},
        },
        .{
            .header = "invalid",
            .hunks = &.{.{ .old_start = 1, .old_count = 0, .new_start = 1, .new_count = 1, .section = "", .lines = &invalid_lines }},
            .metadata = &.{},
        },
    };
    const eligibility = try classifyDocument(std.testing.allocator, .{ .files = &files });
    defer std.testing.allocator.free(eligibility);
    try std.testing.expectEqualSlices(FileTextEligibility, &.{ .selectable_utf8, .inert_invalid_utf8 }, eligibility);
}

test "invalid hunk section is inert" {
    const file: diff_parser.FileDiff = .{
        .header = "invalid section",
        .metadata = &.{},
        .hunks = &.{.{
            .old_start = 1,
            .old_count = 1,
            .new_start = 1,
            .new_count = 1,
            .section = "truncated\xf0\x9f",
            .lines = &.{.{ .kind = .context, .text = "valid" }},
        }},
    };
    try std.testing.expectEqual(FileTextEligibility.inert_invalid_utf8, classify(file));
}

test "invalid leading continuation and truncated line sequences are inert" {
    const invalid_lines = [_][]const u8{
        "leading\xff",
        "continuation\x80",
        "truncated\xf0\x9f",
    };
    for (invalid_lines) |text| {
        const file: diff_parser.FileDiff = .{
            .header = "invalid line",
            .metadata = &.{},
            .hunks = &.{.{
                .old_start = 1,
                .old_count = 0,
                .new_start = 1,
                .new_count = 1,
                .section = "",
                .lines = &.{.{ .kind = .added, .text = text }},
            }},
        };
        try std.testing.expectEqual(FileTextEligibility.inert_invalid_utf8, classify(file));
    }
}
