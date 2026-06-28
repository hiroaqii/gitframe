const std = @import("std");
const diff_file = @import("file.zig");
const diff_parser = @import("parser.zig");

pub const HunkPatchError = error{
    NoPath,
    BinaryFile,
    InvalidHunk,
    UnsupportedFileState,
    OutOfMemory,
};

pub fn formatSingleHunkPatch(
    allocator: std.mem.Allocator,
    file: diff_parser.FileDiff,
    hunk_index: usize,
) HunkPatchError![]u8 {
    try validateSupportedFile(file);
    if (hunk_index >= file.hunks.len) return error.InvalidHunk;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    if (file.header.len > 0) try appendLine(&out, allocator, file.header);
    for (file.metadata) |line| try appendLine(&out, allocator, line);
    try appendHunkHeader(&out, allocator, file.hunks[hunk_index]);
    for (file.hunks[hunk_index].lines) |line| try appendHunkLine(&out, allocator, line);

    return out.toOwnedSlice(allocator);
}

fn validateSupportedFile(file: diff_parser.FileDiff) HunkPatchError!void {
    if (diff_file.canonicalPathKey(file) == null) return error.NoPath;
    if (file.is_binary) return error.BinaryFile;
    if (diff_file.status(file) != .modified) return error.UnsupportedFileState;
    if (diff_file.hasModeChange(file)) return error.UnsupportedFileState;
    if (hasCopyMetadata(file)) return error.UnsupportedFileState;
}

fn hasCopyMetadata(file: diff_parser.FileDiff) bool {
    for (file.metadata) |line| {
        if (std.mem.startsWith(u8, line, "copy from ") or
            std.mem.startsWith(u8, line, "copy to "))
        {
            return true;
        }
    }
    return false;
}

fn appendHunkHeader(out: *std.ArrayList(u8), allocator: std.mem.Allocator, hunk: diff_parser.Hunk) HunkPatchError!void {
    const line = if (hunk.section.len > 0)
        try std.fmt.allocPrint(
            allocator,
            "@@ -{d},{d} +{d},{d} @@ {s}\n",
            .{ hunk.old_start, hunk.old_count, hunk.new_start, hunk.new_count, hunk.section },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "@@ -{d},{d} +{d},{d} @@\n",
            .{ hunk.old_start, hunk.old_count, hunk.new_start, hunk.new_count },
        );
    defer allocator.free(line);

    try out.appendSlice(allocator, line);
}

fn appendHunkLine(out: *std.ArrayList(u8), allocator: std.mem.Allocator, line: diff_parser.DiffLine) HunkPatchError!void {
    const prefix: ?u8 = switch (line.kind) {
        .context => ' ',
        .added => '+',
        .removed => '-',
        .metadata => null,
    };
    if (prefix) |byte| try out.append(allocator, byte);
    try appendLine(out, allocator, line.text);
}

fn appendLine(out: *std.ArrayList(u8), allocator: std.mem.Allocator, line: []const u8) HunkPatchError!void {
    try out.appendSlice(allocator, line);
    try out.append(allocator, '\n');
}

test "formatSingleHunkPatch reconstructs a modified hunk with newline terminators" {
    const text =
        \\diff --git a/src/app.zig b/src/app.zig
        \\index 1111111..2222222 100644
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -1,3 +1,3 @@ fn main
        \\ context
        \\-old
        \\+new
        \\@@ -10,1 +10,1 @@ second
        \\-later old
        \\+later new
        \\
    ;

    const document = try diff_parser.parse(std.testing.allocator, text);
    defer document.deinit(std.testing.allocator);

    const patch = try formatSingleHunkPatch(std.testing.allocator, document.files[0], 1);
    defer std.testing.allocator.free(patch);

    try std.testing.expectEqualStrings(
        "diff --git a/src/app.zig b/src/app.zig\n" ++
            "index 1111111..2222222 100644\n" ++
            "--- a/src/app.zig\n" ++
            "+++ b/src/app.zig\n" ++
            "@@ -10,1 +10,1 @@ second\n" ++
            "-later old\n" ++
            "+later new\n",
        patch,
    );
}

test "formatSingleHunkPatch preserves hunk metadata lines" {
    const text =
        \\diff --git a/src/app.zig b/src/app.zig
        \\index 1111111..2222222 100644
        \\--- a/src/app.zig
        \\+++ b/src/app.zig
        \\@@ -1,1 +1,1 @@
        \\-old
        \\\ No newline at end of file
        \\+new
        \\\ No newline at end of file
        \\
    ;

    const document = try diff_parser.parse(std.testing.allocator, text);
    defer document.deinit(std.testing.allocator);

    const patch = try formatSingleHunkPatch(std.testing.allocator, document.files[0], 0);
    defer std.testing.allocator.free(patch);

    try std.testing.expect(std.mem.endsWith(u8, patch, "\\ No newline at end of file\n"));
    try std.testing.expect(std.mem.indexOf(u8, patch, "-old\n\\ No newline at end of file\n+new\n") != null);
}

test "formatSingleHunkPatch rejects unsupported files" {
    const modified = diff_parser.FileDiff{
        .header = "diff --git a/src/app.zig b/src/app.zig",
        .old_path = "a/src/app.zig",
        .new_path = "b/src/app.zig",
        .metadata = &.{ "old mode 100644", "new mode 100755" },
        .hunks = &.{},
    };
    try std.testing.expectError(error.UnsupportedFileState, formatSingleHunkPatch(std.testing.allocator, modified, 0));

    const added = diff_parser.FileDiff{
        .header = "diff --git a/new.zig b/new.zig",
        .old_path = null,
        .new_path = "b/new.zig",
        .metadata = &.{ "new file mode 100644", "--- /dev/null", "+++ b/new.zig" },
        .hunks = &.{},
    };
    try std.testing.expectError(error.UnsupportedFileState, formatSingleHunkPatch(std.testing.allocator, added, 0));

    const binary = diff_parser.FileDiff{
        .header = "diff --git a/img.png b/img.png",
        .old_path = "a/img.png",
        .new_path = "b/img.png",
        .metadata = &.{},
        .hunks = &.{},
        .is_binary = true,
    };
    try std.testing.expectError(error.BinaryFile, formatSingleHunkPatch(std.testing.allocator, binary, 0));

    const copied = diff_parser.FileDiff{
        .header = "diff --git a/src/old.zig b/src/new.zig",
        .old_path = "a/src/old.zig",
        .new_path = "b/src/new.zig",
        .metadata = &.{ "similarity index 95%", "copy from src/old.zig", "copy to src/new.zig" },
        .hunks = &.{},
    };
    try std.testing.expectError(error.UnsupportedFileState, formatSingleHunkPatch(std.testing.allocator, copied, 0));
}
