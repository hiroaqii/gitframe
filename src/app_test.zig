const std = @import("std");
const chasen = @import("chasen");

const app_module = @import("app.zig");
const page = @import("app/page.zig");
const context = @import("context.zig");
const git_status = @import("git/status.zig");
const test_support = @import("app/test_support.zig");
const action_lifecycle = @import("app/workflow/action_lifecycle.zig");
const review_session = @import("review_session/session.zig");

const App = app_module.App;

test "App starts with Changes as the only reachable working-tree page" {
    const app: App = .{};

    try std.testing.expectEqual(page.Id.changes, app.active_page);
    try std.testing.expectEqual(@as(u64, 0), app.repo_session.repo_epoch);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, app.pages.changes.viewer.selected_target.?);
}

test "selectionContext exposes selected diff file model coordinate" {
    const app: App = .{
        .pages = .{ .changes = .{
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
        .pages = .{ .changes = .{
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
        .pages = .{ .changes = .{
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
    defer app.pages.changes.git_status.deinit();

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? src/new.zig\x00");
    try app.pages.changes.git_status.replace("/repo", &status_bundle);

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
        .pages = .{ .changes = .{
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
test "quit waits for pending git action" {
    var app: App = .{ .allocator = std.testing.allocator };
    action_lifecycle.testing.installAccepted(&app.action_runtime, .{ .generation = 7, .kind = .stage_file });
    defer action_lifecycle.testing.clear(&app.action_runtime);
    var tc: chasen.testing.TestCtx(App.Msg) = .{};
    defer tc.resetTransient();

    try app.update(.quit, &tc.ctx);

    try std.testing.expect(!tc.ctx.shouldQuit());
    try std.testing.expect(app.action_runtime.view().hasPending());
    try std.testing.expectEqualStrings("finish current git action before quitting", app.status.text());
}

test "quit exits when no git action is pending" {
    var app: App = .{ .allocator = std.testing.allocator };
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer ctx.runtimeClearPendingEffectCopies();
    app.drag_auto_scroll.active = .{
        .generation = 5,
        .target = .changes,
        .intent = .{ .direction = .down, .endpoint = .{ .col = 4, .row = 8 } },
    };
    app.drag_auto_scroll.scheduled_generation = 5;

    try app.update(.quit, &ctx);

    try std.testing.expect(ctx.shouldQuit());
    try std.testing.expect(app.drag_auto_scroll.active == null);
    try std.testing.expect(app.drag_auto_scroll.scheduled_generation == null);
    try std.testing.expectEqual(@as(u8, 1), ctx._pending_cancels_len);
}

test "changes cancel remains available when source validation failed" {
    var output: review_session.Output = .{};
    defer output.deinit(std.testing.allocator);
    var app: App = .{
        .allocator = std.testing.allocator,
        .review_output = &output,
    };
    _ = app.pages.changes.activation.activate(0, .failed, .unavailable, .unavailable);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.update(.{ .changes = .finish_review_approved }, &ctx);
    try std.testing.expect(!ctx.shouldQuit());
    try std.testing.expect(!output.ready);
    try std.testing.expectEqualStrings("review source is still being validated", app.pages.changes.status.text());

    try app.update(.{ .changes = .finish_review_canceled }, &ctx);
    try std.testing.expect(ctx.shouldQuit());
    try std.testing.expect(output.ready);
    try std.testing.expectEqual(@as(u8, 130), output.exit_code);
}

test "finishReview waits for pending git action before writing output" {
    var output: review_session.Output = .{};
    defer output.deinit(std.testing.allocator);
    var app: App = .{
        .allocator = std.testing.allocator,
        .review_output = &output,
    };
    action_lifecycle.testing.installAccepted(&app.action_runtime, .{ .generation = 7, .kind = .stage_file });
    defer action_lifecycle.testing.clear(&app.action_runtime);
    var tc: chasen.testing.TestCtx(App.Msg) = .{};
    defer tc.resetTransient();

    try app.update(.{ .changes = .finish_review_canceled }, &tc.ctx);

    try std.testing.expect(!tc.ctx.shouldQuit());
    try std.testing.expect(!output.ready);
    try std.testing.expect(app.action_runtime.view().hasPending());
    try std.testing.expectEqualStrings("finish current git action before finishing review", app.pages.changes.status.text());
}

test "finishReview writes output and quits when no git action is pending" {
    var output: review_session.Output = .{};
    defer output.deinit(std.testing.allocator);
    var app: App = .{
        .allocator = std.testing.allocator,
        .review_output = &output,
    };
    _ = app.pages.changes.activation.activate(0, .fresh, .unavailable, .unavailable);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.update(.{ .changes = .finish_review_approved }, &ctx);

    try std.testing.expect(ctx.shouldQuit());
    try std.testing.expect(output.ready);
    try std.testing.expectEqual(@as(u8, 0), output.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, output.json.items, "\"decision\":\"approved\"") != null);
}

test "selectionContext keeps status-only selection while status load is pending" {
    var app: App = .{
        .pages = .{ .changes = .{
            .viewer = .{ .selected_target = .{ .status_only = 0 } },
            .status_load = .{ .generation = 9, .pending = .{ .generation = 9 } },
        } },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.pages.changes.git_status.deinit();

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? src/new.zig\x00");
    try app.pages.changes.git_status.replace("/repo", &status_bundle);

    const selection = app.selectionContext();
    const status = selection.selected.?.status_only;
    try std.testing.expectEqual(@as(usize, 0), status.status_index);
    try std.testing.expectEqualStrings("src/new.zig", status.path_key.?);
}

test "selectionContext rejects stale status-only identities" {
    var app: App = .{
        .pages = .{ .changes = .{
            .viewer = .{ .selected_target = .{ .status_only = 0 } },
        } },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.pages.changes.git_status.deinit();

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? src/new.zig\x00");
    try app.pages.changes.git_status.replace("/other", &status_bundle);
    try std.testing.expect(app.selectionContext().selected == null);

    app.pages.changes.git_status.deinit();
    var matching = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? src/new.zig\x00");
    try app.pages.changes.git_status.replace("/repo", &matching);
    app.pages.changes.viewer.selected_target = .{ .status_only = 1 };
    try std.testing.expect(app.selectionContext().selected == null);
}
