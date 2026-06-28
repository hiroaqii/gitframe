const std = @import("std");

const app_module = @import("app.zig");
const context = @import("context.zig");
const test_support = @import("app/test_support.zig");

const App = app_module.App;

test "selectionContext exposes selected diff file model coordinate" {
    const app: App = .{
        .config = .{ .source = .{ .range = "main...HEAD" } },
        .load = test_support.loadState(test_support.loadedDiffTwo()),
        .viewer = .{
            .selected_target = .{ .diff_file = 0 },
            .selected_file = 0,
            .diff_cursor = .{ .hunk_header = 1 },
        },
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "gitframe",
            .display_path = ".",
            .canonical_root = "/repo/gitframe",
        } } },
    };

    const selection = app.selectionContext();
    try std.testing.expectEqualStrings("/repo/gitframe", selection.repo_root.?);
    try std.testing.expectEqual(context.SourceKind.range, selection.source.kind);
    try std.testing.expectEqualStrings("main...HEAD", selection.source.detail.?);

    const diff_selection = selection.selected.?.diff_file;
    try std.testing.expectEqual(@as(usize, 0), diff_selection.file_index);
    try std.testing.expectEqualStrings("a", diff_selection.display_path);
    try std.testing.expectEqualStrings("a", diff_selection.path_key.?);
    try std.testing.expectEqual(@as(?usize, 1), diff_selection.hunk_index);
}

test "selectionContext accepts status-only target shape" {
    const app: App = .{
        .config = .{ .source = .stdin },
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .status_only = 2 } },
    };

    const selection = app.selectionContext();
    try std.testing.expect(selection.repo_root == null);
    try std.testing.expectEqual(context.SourceKind.stdin, selection.source.kind);

    const status_selection = selection.selected.?.status_only;
    try std.testing.expectEqual(@as(usize, 2), status_selection.status_index);
    try std.testing.expect(status_selection.path_key == null);
}

test "selectionContext keeps no-index source paths" {
    const app: App = .{
        .config = .{ .source = .{ .no_index = .{ .left = "before.zig", .right = "after.zig" } } },
    };

    const selection = app.selectionContext();
    try std.testing.expectEqual(context.SourceKind.no_index, selection.source.kind);
    try std.testing.expectEqualStrings("difftool", selection.source.label);
    try std.testing.expect(selection.source.detail == null);
    try std.testing.expectEqualStrings("before.zig", selection.source.left_path.?);
    try std.testing.expectEqualStrings("after.zig", selection.source.right_path.?);
    try std.testing.expect(selection.selected == null);
}

test "selectionContext returns null selected without a target" {
    const app: App = .{
        .config = .{ .source = .unstaged },
        .viewer = .{ .selected_target = null },
    };

    const selection = app.selectionContext();
    try std.testing.expect(selection.repo_root == null);
    try std.testing.expectEqual(context.SourceKind.unstaged, selection.source.kind);
    try std.testing.expectEqualStrings("unstaged changes", selection.source.label);
    try std.testing.expect(selection.selected == null);
}
