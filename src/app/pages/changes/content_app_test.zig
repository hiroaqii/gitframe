//! Changes selected-content and editor-target integration tests.

const std = @import("std");
const app_mod = @import("../../../app.zig");
const app_shell_layout = @import("../../shell_layout.zig");
const app_test_support = @import("../../test_support.zig");
const changes_content = @import("content.zig");
const changes_navigation = @import("navigation.zig");
const changes_authority = @import("../../diff_surface/authority.zig");
const content_fingerprint = @import("../../../content_fingerprint.zig");
const diff_source = @import("../../../diff/source.zig");
const file_tree = @import("../../../file_tree.zig");
const git_status = @import("../../../git/status.zig");

const App = app_mod.App;

fn changesNavigationView(app: *const App) changes_navigation.View {
    const size = app_shell_layout.compute(app.terminal_size, .{ .page_bar_visible = true }).bodySize();
    const repo = app.repo_session.view();
    return .{
        .page = &app.pages.changes,
        .repo_root = repo.activeRoot(),
        .repo_epoch = repo.epoch(),
        .root_identity = repo.activeIdentity(),
        .source = app.config.source,
        .layout = .{ .width = size.width, .height = size.height },
    };
}

fn changesContent(app: *const App) changes_content.View {
    return .{
        .page = &app.pages.changes,
        .navigation = changesNavigationView(app),
        .source = app.config.source,
        .repo_root = app.repo_session.view().activeRoot(),
    };
}

fn acceptTestSource(app: *App) void {
    app.pages.changes.auto_reload.acceptSource(content_fingerprint.Fingerprint.init("test source"));
    const source: changes_authority.MemberFreshness = if (diff_source.sourceIsOneShotInput(app.config.source))
        .immutable
    else if (app.pages.changes.auto_reload.sourceIsActionable())
        .fresh
    else if (app.pages.changes.load.hasPending())
        .pending
    else
        .unavailable;
    _ = app.pages.changes.activation.activate(
        app.repo_session.repo_epoch,
        source,
        changes_authority.auxiliaryMember(app.pages.changes.status_load),
        changes_authority.auxiliaryMember(app.pages.changes.branch_status_load),
    );
}

test "selectedEditorTarget accepts status-only file rows" {
    const status_nodes = [_]file_tree.Node{
        .{
            .kind = .file,
            .name = "staged.zig",
            .path = "src/staged.zig",
            .path_key = "src/staged.zig",
            .depth = 0,
            .target = .{ .status_entry = 0 },
        },
    };
    var app: App = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(.{
                .text = "",
                .document = .{ .files = &.{} },
                .file_text_eligibility = &.{},
                .tree = .{ .nodes = &status_nodes },
                .collapsed_dirs = .{},
                .bytes = 0,
                .lines = 0,
            }),
            .viewer = .{
                .selected_node = 0,
                .selected_target = .{ .status_only = 0 },
            },
        } },
        .config = .{ .source = .cached },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.pages.changes.git_status.deinit();
    acceptTestSource(&app);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  src/staged.zig\x00");
    try app.pages.changes.git_status.replace("/repo", &status_bundle);

    switch (changesContent(&app).editorTarget()) {
        .ready => |target| {
            try std.testing.expectEqualStrings("/repo", target.repo_root);
            try std.testing.expectEqualStrings("src/staged.zig", target.path);
        },
        else => return error.ExpectedEditorTarget,
    }
}

test "selectedEditorTarget rejects deleted and historical sources" {
    var app: App = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffTwoWithStatuses()),
            .viewer = .{
                .selected_node = 1,
                .selected_target = .{ .diff_file = 1 },
            },
        } },
        .config = .{ .source = .cached },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    acceptTestSource(&app);

    try std.testing.expectEqual(changes_content.EditorTargetResult.deleted_file, changesContent(&app).editorTarget());

    app.config.source = .{ .range = "main...HEAD" };
    try std.testing.expectEqual(changes_content.EditorTargetResult.unavailable_source, changesContent(&app).editorTarget());
}

test "selectedEditorTarget rejects deleted status-only file rows from fresh status" {
    const status_nodes = [_]file_tree.Node{
        .{
            .kind = .file,
            .name = "deleted.zig",
            .path = "src/deleted.zig",
            .path_key = "src/deleted.zig",
            .depth = 0,
            .target = .{ .status_entry = 0 },
        },
    };
    var app: App = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(.{
                .text = "",
                .document = .{ .files = &.{} },
                .file_text_eligibility = &.{},
                .tree = .{ .nodes = &status_nodes },
                .collapsed_dirs = .{},
                .bytes = 0,
                .lines = 0,
            }),
            .viewer = .{
                .selected_node = 0,
                .selected_target = .{ .status_only = 0 },
            },
        } },
        .terminal_size = .{ .width = 100, .height = 40 },
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
    acceptTestSource(&app);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, " D src/deleted.zig\x00");
    try app.pages.changes.git_status.replace("/repo", &status_bundle);

    try std.testing.expectEqual(changes_content.EditorTargetResult.deleted_file, changesContent(&app).editorTarget());
}

test "selectedEditorTarget rejects live sources without active repo" {
    var app: App = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
        } },
        .config = .{ .source = .unstaged },
    };
    acceptTestSource(&app);

    try std.testing.expectEqual(changes_content.EditorTargetResult.no_repo, changesContent(&app).editorTarget());
}

test "selectedEditorTarget rejects directory rows" {
    var app: App = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffNested()),
            .viewer = .{ .selected_node = 0 },
        } },
        .terminal_size = .{ .width = 100, .height = 40 },
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    acceptTestSource(&app);

    try std.testing.expectEqual(changes_content.EditorTargetResult.directory_unsupported, changesContent(&app).editorTarget());
}
