const std = @import("std");

const app_module = @import("app.zig");
const page = @import("app/page.zig");
const context = @import("context.zig");
const git_status = @import("git/status.zig");
const test_support = @import("app/test_support.zig");

const App = app_module.App;

test "App starts with Review as the only reachable page" {
    const app: App = .{};

    try std.testing.expectEqual(page.Id.review, app.active_page);
    try std.testing.expectEqual(@as(u64, 0), app.repo_session.repo_epoch);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, app.pages.review.viewer.selected_target.?);
}

test "selectionContext exposes selected diff file model coordinate" {
    const app: App = .{
        .pages = .{ .review = .{
            .load = test_support.loadState(test_support.loadedDiffTwo()),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .diff_cursor = .{ .hunk_header = 1 },
            },
        } },
        .config = .{ .source = .{ .range = "main...HEAD" } },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "gitframe",
                .display_path = ".",
                .canonical_root = "/repo/gitframe",
            } } },
        },
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

test "selectionContext returns null for unresolved status-only target" {
    const app: App = .{
        .pages = .{ .review = .{
            .load = test_support.loadState(test_support.loadedDiffOne()),
            .viewer = .{ .selected_target = .{ .status_only = 2 } },
        } },
        .config = .{ .source = .stdin },
    };

    const selection = app.selectionContext();
    try std.testing.expect(selection.repo_root == null);
    try std.testing.expectEqual(context.SourceKind.stdin, selection.source.kind);
    try std.testing.expect(selection.selected == null);
}

test "selectionContext resolves status-only target without loaded diff" {
    var app: App = .{
        .pages = .{ .review = .{
            .viewer = .{ .selected_target = .{ .status_only = 0 } },
        } },
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.pages.review.git_status.deinit();

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? src/new.zig\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);

    const selection = app.selectionContext();
    try std.testing.expectEqualStrings("/repo", selection.repo_root.?);
    try std.testing.expectEqual(context.SourceKind.unstaged, selection.source.kind);

    const status_selection = selection.selected.?.status_only;
    try std.testing.expectEqual(@as(usize, 0), status_selection.status_index);
    try std.testing.expectEqualStrings("src/new.zig", status_selection.path_key.?);
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
        .pages = .{ .review = .{
            .viewer = .{ .selected_target = null },
        } },
        .config = .{ .source = .unstaged },
    };

    const selection = app.selectionContext();
    try std.testing.expect(selection.repo_root == null);
    try std.testing.expectEqual(context.SourceKind.unstaged, selection.source.kind);
    try std.testing.expectEqualStrings("unstaged changes", selection.source.label);
    try std.testing.expect(selection.selected == null);
}
