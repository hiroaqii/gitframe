const std = @import("std");
const chasen = @import("chasen");

const app_load_state = @import("load_state.zig");
const diff_parser = @import("../diff/parser.zig");
const file_tree = @import("../file_tree.zig");
const loaded_diff = @import("../loaded_diff.zig");

const LoadedDiff = loaded_diff.LoadedDiff;
const LoadedSession = app_load_state.LoadedSession;
const LoadRuntimeState = app_load_state.LoadRuntimeState;

const selectable_one = [_]loaded_diff.FileTextEligibility{.selectable_utf8};
const selectable_two = [_]loaded_diff.FileTextEligibility{ .selectable_utf8, .selectable_utf8 };

pub fn expectSnapshotContains(ts: *const chasen.testing.TestSurface, needle: []const u8) !void {
    const actual = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(actual);
    try std.testing.expect(std.mem.indexOf(u8, actual, needle) != null);
}

pub fn expectSnapshotNotContains(ts: *const chasen.testing.TestSurface, needle: []const u8) !void {
    const actual = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(actual);
    try std.testing.expect(std.mem.indexOf(u8, actual, needle) == null);
}

pub fn mouseEvent(col: anytype, row: anytype, button: anytype) chasen.Event {
    return mouseEventTyped(col, row, button, .press);
}

pub fn mouseEventTyped(col: anytype, row: anytype, button: anytype, mouse_type: anytype) chasen.Event {
    return .{ .mouse = .{
        .col = @intCast(col),
        .row = @intCast(row),
        .button = button,
        .mods = .{},
        .type = mouse_type,
    } };
}

pub fn loadedSession(loaded: LoadedDiff) LoadedSession {
    return .{
        .arena = .init(std.testing.allocator),
        .loaded = loaded,
        .reviewed_files_owned = false,
    };
}

pub fn loadState(loaded: LoadedDiff) LoadRuntimeState {
    return .{ .state = .{ .loaded = loadedSession(loaded) } };
}

pub fn loadStateWithArena(arena: std.heap.ArenaAllocator, loaded: LoadedDiff) LoadRuntimeState {
    return .{ .state = .{ .loaded = .{
        .arena = arena,
        .loaded = loaded,
        .reviewed_files_owned = false,
    } } };
}

pub fn loadedDiffOne() LoadedDiff {
    return .{
        .text = "",
        .document = .{ .files = &files_one },
        .file_text_eligibility = &selectable_one,
        .tree = .{ .nodes = &tree_one_nodes },
        .collapsed_dirs = .{},
        .bytes = 0,
        .lines = 0,
    };
}

pub fn loadedDiffTwo() LoadedDiff {
    return .{
        .text = "",
        .document = .{ .files = &files_two },
        .file_text_eligibility = &selectable_two,
        .tree = .{ .nodes = &tree_two_nodes },
        .collapsed_dirs = .{},
        .bytes = 0,
        .lines = 0,
    };
}

pub fn loadedDiffNested() LoadedDiff {
    return .{
        .text = "",
        .document = .{ .files = &files_two },
        .file_text_eligibility = &selectable_two,
        .tree = .{ .nodes = &tree_nested_nodes },
        .collapsed_dirs = .{},
        .bytes = 0,
        .lines = 0,
    };
}

pub fn loadedDiffTwoWithStatuses() LoadedDiff {
    return .{
        .text = "",
        .document = .{ .files = &files_two_statuses },
        .file_text_eligibility = &selectable_two,
        .tree = .{ .nodes = &tree_two_status_nodes },
        .collapsed_dirs = .{},
        .bytes = 0,
        .lines = 0,
    };
}

pub fn loadedDiffFileOneFirst() LoadedDiff {
    return .{
        .text = "",
        .document = .{ .files = &files_two },
        .file_text_eligibility = &selectable_two,
        .tree = .{ .nodes = &tree_file_one_first_nodes },
        .collapsed_dirs = .{},
        .bytes = 0,
        .lines = 0,
    };
}

pub fn loadedDiffWide() LoadedDiff {
    return .{
        .text = "",
        .document = .{ .files = &files_wide },
        .file_text_eligibility = &selectable_one,
        .tree = .{ .nodes = &tree_one_nodes },
        .collapsed_dirs = .{},
        .bytes = 0,
        .lines = 0,
    };
}

pub fn loadedDiffMetadataOnly() LoadedDiff {
    return .{
        .text = "",
        .document = .{ .files = &files_metadata_only },
        .file_text_eligibility = &selectable_one,
        .tree = .{ .nodes = &tree_one_nodes },
        .collapsed_dirs = .{},
        .bytes = 0,
        .lines = 0,
    };
}

pub fn loadedDiffBinaryOnly() LoadedDiff {
    return .{
        .text = "",
        .document = .{ .files = &files_binary_only },
        .file_text_eligibility = &selectable_one,
        .tree = .{ .nodes = &tree_one_nodes },
        .collapsed_dirs = .{},
        .bytes = 0,
        .lines = 0,
    };
}

pub const tree_one_nodes = [_]file_tree.Node{
    .{ .kind = .file, .name = "a", .path = "a", .depth = 0, .target = .{ .diff_file = 0 } },
};

pub const tree_two_nodes = [_]file_tree.Node{
    .{ .kind = .file, .name = "a", .path = "a", .depth = 0, .target = .{ .diff_file = 0 } },
    .{ .kind = .file, .name = "b", .path = "b", .depth = 0, .target = .{ .diff_file = 1 } },
};

pub const tree_file_one_first_nodes = [_]file_tree.Node{
    .{ .kind = .file, .name = "b", .path = "b", .depth = 0, .target = .{ .diff_file = 1 } },
    .{ .kind = .file, .name = "a", .path = "a", .depth = 0, .target = .{ .diff_file = 0 } },
};

pub const tree_nested_nodes = [_]file_tree.Node{
    .{ .kind = .directory, .name = "src", .path = "src", .depth = 0 },
    .{ .kind = .file, .name = "a", .path = "src/a", .depth = 1, .target = .{ .diff_file = 0 } },
    .{ .kind = .file, .name = "b", .path = "src/b", .depth = 1, .target = .{ .diff_file = 1 } },
};

pub const tree_non_contiguous_nodes = [_]file_tree.Node{
    .{ .kind = .directory, .name = "src", .path = "src", .depth = 0 },
    .{ .kind = .file, .name = "a", .path = "src/a", .depth = 1, .target = .{ .diff_file = 0 } },
    .{ .kind = .directory, .name = "lib", .path = "lib", .depth = 0 },
    .{ .kind = .file, .name = "c", .path = "lib/c", .depth = 1, .target = .{ .diff_file = 0 } },
    .{ .kind = .file, .name = "b", .path = "src/b", .depth = 1, .target = .{ .diff_file = 1 } },
};

pub const tree_two_status_nodes = [_]file_tree.Node{
    .{ .kind = .file, .name = "added.zig", .path = "src/added.zig", .depth = 1, .target = .{ .diff_file = 0 }, .status = .added },
    .{ .kind = .file, .name = "deleted.zig", .path = "src/deleted.zig", .depth = 1, .target = .{ .diff_file = 1 }, .status = .deleted },
};

pub const files_one = [_]diff_parser.FileDiff{
    file_with_hunks,
};

pub const files_two = [_]diff_parser.FileDiff{
    file_with_hunks,
    file_with_target_metadata,
};

pub const files_two_statuses = [_]diff_parser.FileDiff{
    .{
        .header = "diff --git a/src/added.zig b/src/added.zig",
        .old_path = null,
        .new_path = "b/src/added.zig",
        .metadata = &.{"new file mode 100644"},
        .hunks = &.{},
    },
    .{
        .header = "diff --git a/src/deleted.zig b/src/deleted.zig",
        .old_path = "a/src/deleted.zig",
        .new_path = null,
        .metadata = &.{"deleted file mode 100644"},
        .hunks = &.{},
    },
};

pub const files_wide = [_]diff_parser.FileDiff{
    file_wide,
};

pub const files_metadata_only = [_]diff_parser.FileDiff{
    .{
        .header = "diff --git a/a b/a",
        .old_path = "a/a",
        .new_path = "b/a",
        .metadata = &.{ "index 1..2", "old mode 100644" },
        .hunks = &.{},
    },
};

pub const files_binary_only = [_]diff_parser.FileDiff{
    .{
        .header = "diff --git a/bin b/bin",
        .old_path = "a/bin",
        .new_path = "b/bin",
        .metadata = &.{"index 1..2"},
        .hunks = &.{},
        .is_binary = true,
    },
};

pub const file_wide = diff_parser.FileDiff{
    .header = "diff --git a/a b/a",
    .old_path = "a/a",
    .new_path = "b/a",
    .metadata = &.{ "index 1..2", "--- a/a", "+++ b/a" },
    .hunks = &.{.{
        .old_start = 1,
        .old_count = 1,
        .new_start = 1,
        .new_count = 1,
        .section = "wide",
        .lines = &.{.{
            .kind = .context,
            .text = "wide-0123456789-abcdefghijklmnopqrstuvwxyz-ABCDEFGHIJKLMNOPQRSTUVWXYZ",
            .old_line = 1,
            .new_line = 1,
        }},
    }},
};

pub const diff_one =
    \\diff --git a/a b/a
    \\index 1..2 100644
    \\--- a/a
    \\+++ b/a
    \\@@ -1,3 +1,3 @@
    \\ one
    \\-old
    \\+new
    \\ two
    \\
;

pub const diff_added_deleted =
    \\diff --git a/src/added.zig b/src/added.zig
    \\new file mode 100644
    \\--- /dev/null
    \\+++ b/src/added.zig
    \\@@ -0,0 +1 @@
    \\+added
    \\diff --git a/src/deleted.zig b/src/deleted.zig
    \\deleted file mode 100644
    \\--- a/src/deleted.zig
    \\+++ /dev/null
    \\@@ -1 +0,0 @@
    \\-deleted
    \\
;

pub const diff_cached_projection =
    \\diff --git a/a b/a
    \\index 1..2 100644
    \\--- a/a
    \\+++ b/a
    \\@@ -10,3 +10,3 @@
    \\ context
    \\-old staged
    \\+new staged
    \\ context
    \\
;

pub const diff_unstaged_projection =
    \\diff --git a/a b/a
    \\index 2..3 100644
    \\--- a/a
    \\+++ b/a
    \\@@ -20,3 +20,3 @@
    \\ context
    \\-old unstaged
    \\+new unstaged
    \\ context
    \\
;

pub const file_with_hunks = diff_parser.FileDiff{
    .header = "diff --git a/a b/a",
    .old_path = "a/a",
    .new_path = "b/a",
    .metadata = &.{ "index 1..2", "--- a/a", "+++ b/a" },
    .hunks = &hunks,
};

pub const hunks = [_]diff_parser.Hunk{
    .{
        .old_start = 1,
        .old_count = 4,
        .new_start = 1,
        .new_count = 4,
        .section = "first",
        .lines = &hunk_first_lines,
    },
    .{
        .old_start = 20,
        .old_count = 2,
        .new_start = 20,
        .new_count = 2,
        .section = "second",
        .lines = &hunk_second_lines,
    },
};

pub const hunk_first_lines = [_]diff_parser.DiffLine{
    .{ .kind = .context, .text = "one", .old_line = 1, .new_line = 1 },
    .{ .kind = .context, .text = "two", .old_line = 2, .new_line = 2 },
    .{ .kind = .removed, .text = "old", .old_line = 3 },
    .{ .kind = .added, .text = "new", .new_line = 3 },
    .{ .kind = .context, .text = "four", .old_line = 4, .new_line = 4 },
};

pub const hunk_second_lines = [_]diff_parser.DiffLine{
    .{ .kind = .context, .text = "late one", .old_line = 20, .new_line = 20 },
    .{ .kind = .removed, .text = "late old", .old_line = 21 },
    .{ .kind = .added, .text = "late new", .new_line = 21 },
};

pub const file_with_target_metadata = diff_parser.FileDiff{
    .header = "diff --git a/b b/b",
    .old_path = "a/b",
    .new_path = "b/b",
    .metadata = &.{"target metadata"},
    .hunks = &.{},
};
