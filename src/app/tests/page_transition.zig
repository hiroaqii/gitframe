//! Root integration tests for page coordination and page-local read routing.

const std = @import("std");
const chasen = @import("chasen");
const app_mod = @import("../../app.zig");
const app_test_support = @import("../test_support.zig");
const app_load = @import("../load.zig");
const app_input = @import("../input.zig");
const app_message = @import("../message.zig");
const app_shell_layout = @import("../shell_layout.zig");
const page = @import("../page.zig");
const page_link = @import("../page_link.zig");
const repo_session = @import("../repo_session.zig");
const repository_page = @import("../pages/repository.zig");
const repository_coordinator = @import("../pages/repository/coordinator.zig");
const repository_layout = @import("../pages/repository/layout.zig");
const repository_tasks = @import("../pages/repository/tasks.zig");
const repository_selection = @import("../pages/repository/selection.zig");
const changes_page = @import("../pages/changes.zig");
const changes_authority = @import("../diff_surface/authority.zig");
const context = @import("../../context.zig");
const content_fingerprint = @import("../../content_fingerprint.zig");
const diff_basis = @import("../diff_basis.zig");
const diff_surface = @import("../diff_surface.zig");
const diff_file = @import("../../diff/file.zig");
const diff_parser = @import("../../diff/parser.zig");
const diff_selection = @import("../../diff/selection.zig");
const diff_source = @import("../../diff/source.zig");
const diff_view_model = @import("../../diff/view_model.zig");
const file_tree = @import("../../file_tree.zig");
const git_refs = @import("../../git/refs.zig");
const git_branch_status = @import("../../git/branch_status.zig");
const repo_discovery = @import("../../repo/discovery.zig");
const repo_root_capability = @import("../../repo/root_capability.zig");
const source_syntax_runtime = @import("../../syntax/source_runtime.zig");

const App = app_mod.App;
const LoadedDiff = @import("../../loaded_diff.zig").LoadedDiff;
const loaded_diff = @import("../../loaded_diff.zig");
const DiffLoadTask = app_load.DiffLoadTask(app_message.Msg);
const StatusLoadTask = app_load.StatusLoadTask(app_message.Msg);
const BranchStatusLoadTask = app_load.BranchStatusLoadTask(app_message.Msg);
const CompareLoadFinished = app_load.CompareLoadFinished;
const CompareLoadTask = app_load.CompareLoadTask(app_message.Msg);
const CompareBranchListFinished = app_load.CompareBranchListFinished;
const CompareBranchListLoadTask = app_load.CompareBranchListLoadTask(app_message.Msg);
const RepositoryManifestTask = repository_tasks.ManifestTask(app_message.Msg);
const RepositoryBranchTask = repository_tasks.BranchTask(app_message.Msg);
const RepositoryDocumentTask = repository_tasks.DocumentTask(app_message.Msg);
const RepositorySyntaxTask = repository_tasks.SyntaxTask(app_message.Msg);
const RepositoryChangeMapTask = repository_tasks.ChangeMapTask(app_message.Msg);

fn activateChanges(app: *App) u64 {
    const source_member: changes_authority.MemberFreshness = if (diff_source.sourceIsOneShotInput(app.config.source))
        switch (app.pages.changes.load.state) {
            .loaded, .empty => .immutable,
            .loading => .pending,
            .failed => .failed,
            .idle => .pending,
        }
    else
        .pending;
    const auxiliary: changes_authority.MemberFreshness = if (diff_source.sourceRequiresRepo(app.config.source) and app.repo_session.view().activeRoot() != null) .pending else .unavailable;
    return app.pages.changes.activation.activate(
        app.repo_session.view().epoch(),
        source_member,
        auxiliary,
        auxiliary,
    );
}

test "Compare entry resolves default and picker selection queues its full ref" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{
        .allocator = allocator,
        .config = .{ .source = .stdin },
        .pages = .{ .changes = .{ .viewer = .{ .diff_scroll = 17 } } },
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
    };
    defer app.pages.compare.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    _ = activateChanges(&app);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };
    defer clearPendingStatusAndDiffTasks(&ctx, allocator);

    try app.update(.{ .switch_page = .compare }, &ctx);
    try std.testing.expectEqual(@as(u8, 1), ctx._pending_tasks_with_len);
    const entry_task: *CompareLoadTask = @ptrCast(@alignCast(ctx._pending_tasks_with[0].ctx));
    try std.testing.expect(entry_task.target == null);
    const entry_identity = entry_task.identity;
    const entry_generation = entry_task.generation;
    try abandonSingleQueuedTask(&ctx, allocator);

    try app.update(.{ .load_finished = .{ .compare = .{ .source = try reviewAppLoadedFinished(
        allocator,
        entry_identity,
        entry_generation,
        'a',
        'b',
    ) } } }, &ctx);
    try std.testing.expectEqualStrings("main", app.pages.compare.basis.?.base.display_name);
    try std.testing.expect(app.pages.compare.diff.load.state == .loaded);
    try std.testing.expectEqual(@as(usize, 17), app.pages.changes.viewer.diff_scroll);

    // The production shared-input route must consume the same-owner bound
    // UpdateAdapter rather than reintroducing a raw controller/resolver pair.
    try std.testing.expectEqual(diff_surface.Focus.sidebar, app.pages.compare.diff.viewer.focus);
    try app.update(.{ .compare = .{ .common = .{ .shared = .toggle_focus } } }, &ctx);
    try std.testing.expectEqual(diff_surface.Focus.diff, app.pages.compare.diff.viewer.focus);

    const picker_message = app.handleEvent(.{ .key_press = .{ .codepoint = 'm' } }) orelse
        return error.ExpectedCompareBasePicker;
    try std.testing.expectEqual(App.Msg{ .compare = .open_base_picker }, picker_message);
    try app.update(picker_message, &ctx);
    try std.testing.expectEqual(@as(u8, 1), ctx._pending_tasks_with_len);
    const picker_task: *CompareBranchListLoadTask = @ptrCast(@alignCast(ctx._pending_tasks_with[0].ctx));
    const picker_identity = picker_task.identity;
    const picker_generation = picker_task.generation;
    try abandonSingleQueuedTask(&ctx, allocator);

    try app.update(.{ .load_finished = .{ .compare = .{ .branch_list = .{
        .identity = picker_identity,
        .generation = picker_generation,
        .result = try branchListForTest(allocator, &.{.{
            .name = "topic",
            .oid = "1111111111111111111111111111111111111111",
        }}),
    } } } }, &ctx);
    const enter_query = app.handleEvent(.{ .key_press = .{ .codepoint = '/' } }) orelse
        return error.ExpectedCompareBaseQuery;
    try std.testing.expectEqual(App.Msg{ .compare = .base_picker_enter_query }, enter_query);
    try app.update(enter_query, &ctx);
    for ("topic") |byte| {
        const insert = app.handleEvent(.{ .key_press = .{ .codepoint = byte } }) orelse
            return error.ExpectedCompareBaseQueryInsert;
        try app.update(insert, &ctx);
    }
    try std.testing.expectEqualStrings("topic", app.pages.compare.base_picker.query.slice());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
    try app.update(.{ .compare = .choose_base }, &ctx);
    try std.testing.expect(!app.pages.compare.base_picker.open);
    try std.testing.expectEqual(@as(u8, 1), ctx._pending_tasks_with_len);
    const selected_task: *CompareLoadTask = @ptrCast(@alignCast(ctx._pending_tasks_with[0].ctx));
    try std.testing.expectEqualStrings("refs/heads/topic", selected_task.target.?.full_ref);
    try std.testing.expectEqualStrings("topic", app.pages.compare.base_target.?.display_name);
}

test "Repository active pointer owner blocks wheel redraw until release" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .active_page = .repository,
        .terminal_size = .{ .width = 100, .height = 20 },
    };
    defer app.pages.repository.deinit(allocator);
    app.pages.repository.viewer.tree_width = 42;
    app.pages.repository.selection_owner = .{ .source = repositoryLiveSelectionForTest() };
    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        1,
        .{ .device = 2, .inode = 3 },
        .{ .location = .{ .path = "incoming.zig" } },
    );
    app.pages.repository.acceptIncoming(allocator, &incoming);
    try std.testing.expect(app.pages.repository.activeMouseOwner());
    try std.testing.expect(app.pages.repository.activeMouseSourceRange());
    const shell = app_shell_layout.compute(app.terminal_size, .{ .page_bar_visible = true });
    const body_size = shell.bodySize();
    const tree_width = repository_layout.bodyLayout(
        body_size,
        app.pages.repository.viewer.tree_width,
        app.pages.repository.viewer.tree_hidden,
    ).tree_width;
    const drag = app.handleEvent(app_test_support.mouseEventTyped(
        shell.body.col + tree_width + 1 + 4,
        shell.body.row + 2,
        .left,
        .drag,
    )) orelse return error.ExpectedRepositoryDrag;
    switch (drag) {
        .mouse_selection_drag => |continuation| switch (continuation.target) {
            .repository => |point| try std.testing.expectEqual(
                repository_layout.BodyPoint{ .col = 4, .row = 2 },
                point.?,
            ),
            else => return error.ExpectedRepositoryDrag,
        },
        else => return error.ExpectedRepositoryDrag,
    }

    // Pointer-stream ownership is broader than source-range policy: a second
    // press or wheel cannot replace the gesture before its release terminal.
    try std.testing.expect(app.handleEvent(app_test_support.mouseEvent(
        shell.body.col + tree_width + 2,
        shell.body.row + 2,
        .left,
    )) == null);
    try std.testing.expect(app.handleEvent(app_test_support.mouseEvent(
        shell.body.col + tree_width + 2,
        shell.body.row + 2,
        .wheel_down,
    )) == null);
    try std.testing.expect(app.pages.repository.activeMouseSourceRange());
    try std.testing.expect(app.pages.repository.incomingIsPending());

    const release = app.handleEvent(app_test_support.mouseEventTyped(0, 0, .left, .release)) orelse
        return error.ExpectedRepositoryRelease;
    switch (release) {
        .mouse_selection_release => |continuation| switch (continuation.target) {
            .repository => |point| {
                try std.testing.expect(point == null);
                try std.testing.expect(continuation.pointer.col < 0);
                try std.testing.expect(continuation.pointer.row < 0);
            },
            else => return error.ExpectedRepositoryRelease,
        },
        else => return error.ExpectedRepositoryRelease,
    }
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    try app.update(release, &ctx);
    try std.testing.expect(!app.pages.repository.activeMouseSourceRange());
    try std.testing.expect(!app.pages.repository.activeMouseOwner());

    app.pages.repository.selection_owner = .{ .source_header = repositoryHeaderSelectionForTest() };
    var header_incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        1,
        .{ .device = 2, .inode = 3 },
        .{ .location = .{ .path = "header-incoming.zig" } },
    );
    app.pages.repository.acceptIncoming(allocator, &header_incoming);
    try std.testing.expect(app.handleEvent(app_test_support.mouseEvent(
        shell.body.col + tree_width + 2,
        shell.body.row + 2,
        .wheel_up,
    )) == null);
    try std.testing.expect(app.pages.repository.activeMouseOwner());
    try std.testing.expect(app.pages.repository.incomingIsPending());

    const header_release = app.handleEvent(app_test_support.mouseEventTyped(0, 0, .left, .release)) orelse
        return error.ExpectedRepositoryRelease;
    try app.update(header_release, &ctx);
    try std.testing.expect(!app.pages.repository.activeMouseOwner());
}

test "keyboard and page bar mouse share the page switch transition" {
    var app: App = .{
        .config = .{ .source = .stdin },
        .terminal_size = .{ .width = 100, .height = 20 },
        .pages = .{ .changes = .{ .load = .{ .state = .{ .empty = .no_changes } } } },
    };
    _ = activateChanges(&app);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    const keyboard = app.handleEvent(.{ .key_press = .{ .codepoint = '2' } }) orelse return error.ExpectedPageSwitch;
    try std.testing.expectEqual(App.Msg{ .switch_page = .repository }, keyboard);
    try app.update(keyboard, &ctx);
    try std.testing.expectEqual(page.Id.repository, app.active_page);
    try std.testing.expect(app.pages.repository.initialized);
    try std.testing.expect(app.pages.changes.activation.state == .inactive);

    try app.update(.reload, &ctx);
    try std.testing.expectEqualStrings("", app.status.text());
    try std.testing.expectEqualStrings("Repository required", app.pages.repository.status.text());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);

    const layout = app_shell_layout.compute(app.terminal_size, .{ .page_bar_visible = true });
    const changes_tab = page.tab(.changes);
    const bar = layout.page_bar orelse return error.ExpectedPageBar;
    const mouse = app.handleEvent(app_test_support.mouseEvent(
        bar.col + changes_tab.col,
        bar.row,
        .left,
    )) orelse return error.ExpectedPageSwitch;
    try std.testing.expectEqual(App.Msg{ .switch_page = .changes }, mouse);
    try app.update(mouse, &ctx);
    try std.testing.expectEqual(page.Id.changes, app.active_page);
    try std.testing.expect(app.pages.changes.activation.state.satisfiesAction(.read_diff));
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
}

test "page key 4 activates Compare without replacing retained Changes state" {
    var app: App = .{
        .config = .{ .source = .stdin },
        .pages = .{ .changes = .{
            .load = .{ .state = .{ .empty = .no_changes } },
            .viewer = .{ .diff_scroll = 11 },
        } },
    };
    _ = activateChanges(&app);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    const message = app.handleEvent(.{ .key_press = .{ .codepoint = '4' } }) orelse
        return error.ExpectedComparePageSwitch;
    try std.testing.expectEqual(App.Msg{ .switch_page = .compare }, message);
    try app.update(message, &ctx);

    try std.testing.expectEqual(page.Id.compare, app.active_page);
    try std.testing.expect(app.pages.compare.activation.state == .active);
    try std.testing.expectEqual(
        page.Id.compare,
        app.pages.compare.activation.currentIdentity().?.origin,
    );
    try std.testing.expect(app.pages.changes.activation.state == .inactive);
    try std.testing.expectEqual(@as(usize, 11), app.pages.changes.viewer.diff_scroll);
    try std.testing.expect(app.pages.changes.load.state == .empty);
    try std.testing.expect(!app.redraw_plan.resolvesToSkip());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
}

test "repository selection shell blocks transition and cancels on focus or resize" {
    var app: App = .{
        .active_page = .repository,
        .terminal_size = .{ .width = 100, .height = 20 },
    };
    app.pages.repository.selection_owner = .{ .source = repositoryLiveSelectionForTest() };
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer ctx.runtimeClearPendingEffectCopies();
    app.drag_auto_scroll.active = .{
        .generation = 4,
        .target = .repository,
        .intent = .{ .direction = .down, .endpoint = .{ .col = 50, .row = 10 } },
    };
    app.drag_auto_scroll.scheduled_generation = 4;
    try std.testing.expect(!@hasField(app_input.KeyContext, "repository_mouse_selection"));
    try std.testing.expect(app.pages.repository.activeMouseOwner());
    try std.testing.expect(app.pages.repository.activeMouseSourceRange());

    try app.update(.{ .switch_page = .compare }, &ctx);
    try std.testing.expectEqual(page.Id.repository, app.active_page);
    try std.testing.expect(app.pages.repository.activeMouseSourceRange());
    try std.testing.expectEqualStrings("finish Repository mouse selection before switching pages", app.status.text());
    try std.testing.expect(app.drag_auto_scroll.active == null);
    try std.testing.expect(app.drag_auto_scroll.scheduled_generation == null);
    try std.testing.expectEqual(@as(u8, 1), ctx._pending_cancels_len);

    app.status.clear();
    const shell = app_shell_layout.compute(app.terminal_size, .{ .page_bar_visible = true });
    const bar = shell.page_bar orelse return error.ExpectedPageBar;
    const changes_tab = page.tab(.changes);
    const mouse_switch = app.handleEvent(app_test_support.mouseEvent(bar.col + changes_tab.col, bar.row, .left)) orelse
        return error.ExpectedPageSwitch;
    try app.update(mouse_switch, &ctx);
    try std.testing.expectEqual(page.Id.repository, app.active_page);
    try std.testing.expect(app.pages.repository.activeMouseSourceRange());
    try std.testing.expectEqualStrings("finish Repository mouse selection before switching pages", app.status.text());

    try app.update(.focus_lost, &ctx);
    try std.testing.expect(!app.pages.repository.activeMouseSourceRange());
    try std.testing.expect(!app.pages.repository.activeMouseOwner());

    app.pages.repository.selection_owner = .{ .source = repositoryLiveSelectionForTest() };
    try app.update(.{ .terminal_resized = .{ .width = 70, .height = 12 } }, &ctx);
    try std.testing.expect(!app.pages.repository.activeMouseSourceRange());
    try std.testing.expect(!app.pages.repository.activeMouseOwner());
    try std.testing.expectEqual(chasen.Size{ .width = 70, .height = 12 }, app.terminal_size);
}

test "changes repository transition common switch commits exact path before revalidation" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{
        .allocator = allocator,
        .active_page = .repository,
        .repo_session = .{
            .repo_epoch = 7,
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
        .config = .{ .source = .unstaged },
        .pages = .{
            .changes = .{
                .repository_read_authority = .{ .epoch = .{ .value = 31 } },
                .load = app_test_support.loadState(app_test_support.loadedDiffTwo()),
                .viewer = .{
                    .selected_target = .{ .diff_file = 0 },
                    .selected_node = 0,
                },
            },
            .repository = .{
                .active = true,
                .repo_epoch = 7,
                .selected_path = "b",
            },
        },
    };
    defer app.pages.changes.deinit(allocator);
    defer app.pages.repository.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    app.pages.repository.root_identity = app.repo_session.view().activeIdentity();
    app.status.set("old navigation status", .{});
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, allocator);

    try app.update(.{ .switch_page = .changes }, &ctx);

    try std.testing.expectEqual(page.Id.changes, app.active_page);
    try std.testing.expect(!app.pages.repository.active);
    try std.testing.expectEqual(@as(usize, 1), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.changes.viewer.selected_target.?);
    try std.testing.expectEqual(@as(usize, 0), app.status.text().len);
    try std.testing.expectEqual(@as(u8, 3), ctx._pending_tasks_with_len);
    const active = app.pages.changes.activation.state.active;
    const entries = ctx._pending_tasks_with[0..ctx._pending_tasks_with_len];
    const status_task: *StatusLoadTask = @ptrCast(@alignCast(entries[0].ctx));
    const branch_task: *BranchStatusLoadTask = @ptrCast(@alignCast(entries[1].ctx));
    const diff_task: *DiffLoadTask = @ptrCast(@alignCast(entries[2].ctx));
    try std.testing.expectEqual(active.activation_id, status_task.identity.activation_id);
    try std.testing.expectEqual(active.activation_id, branch_task.identity.activation_id);
    try std.testing.expectEqual(active.activation_id, diff_task.identity.activation_id);
    try std.testing.expect(status_task.read_epoch.eql(.{ .value = 31 }));
    try std.testing.expect(branch_task.read_epoch.eql(.{ .value = 31 }));
    try std.testing.expect(diff_task.read_epoch.eql(.{ .value = 31 }));
}

test "changes repository transition blocker retains page owner and Changes state" {
    const allocator = std.testing.allocator;
    const identity: repo_root_capability.Identity = .{ .device = 5, .inode = 8 };
    var app: App = .{
        .allocator = allocator,
        .active_page = .repository,
        .repo_session = .{
            .repo_epoch = 7,
        },
        .config = .{ .source = .unstaged },
        .pages = .{
            .changes = .{
                .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
                .viewer = .{
                    .selected_target = .{ .diff_file = 0 },
                    .selected_node = 0,
                    .diff_scroll = 6,
                },
            },
            .repository = .{
                .active = true,
                .repo_epoch = 7,
                .root_identity = identity,
                .selected_path = "retained.zig",
                .file_search = .{ .mode = true },
            },
        },
    };
    defer app.pages.changes.deinit(allocator);
    defer app.pages.repository.deinit(allocator);
    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        app.repo_session.repo_epoch,
        identity,
        .{ .location = .{ .path = "pending.zig" } },
    );
    app.pages.repository.acceptIncoming(allocator, &incoming);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    try app.update(.{ .switch_page = .changes }, &ctx);

    try std.testing.expectEqual(page.Id.repository, app.active_page);
    try std.testing.expect(app.pages.repository.active);
    try std.testing.expect(app.pages.repository.incoming == .awaiting_manifest);
    try std.testing.expectEqualStrings("pending.zig", app.pages.repository.incoming.manifestIntent().?.path);
    try std.testing.expect(app.pages.changes.activation.state == .inactive);
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(@as(usize, 6), app.pages.changes.viewer.diff_scroll);
    try std.testing.expectEqualStrings("finish file search before switching pages", app.status.text());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
}

test "changes repository transition keyboard and page bar open the same exact Changes path" {
    const allocator = std.testing.allocator;
    const inputs = [_]enum { keyboard, page_bar }{ .keyboard, .page_bar };

    for (inputs) |input| {
        var roots = try TestRepoPair.init();
        defer roots.deinit();
        var app: App = .{
            .allocator = allocator,
            .active_page = .repository,
            .repo_session = .{
                .repo_epoch = 7,
                .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
            },
            .terminal_size = .{ .width = 100, .height = 20 },
            .config = .{ .source = .unstaged },
            .pages = .{
                .changes = .{
                    .load = app_test_support.loadState(app_test_support.loadedDiffTwo()),
                    .viewer = .{
                        .selected_target = .{ .diff_file = 0 },
                        .selected_node = 0,
                    },
                },
                .repository = .{
                    .active = true,
                    .repo_epoch = 7,
                    .selected_path = "b",
                },
            },
        };
        defer app.pages.changes.deinit(allocator);
        defer app.pages.repository.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
        app.pages.repository.root_identity = app.repo_session.view().activeIdentity();
        var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
        defer clearPendingStatusAndDiffTasks(&ctx, allocator);

        const message = switch (input) {
            .keyboard => app.handleEvent(.{ .key_press = .{ .codepoint = '1' } }),
            .page_bar => blk: {
                const layout = app_shell_layout.compute(app.terminal_size, .{ .page_bar_visible = true });
                const changes_tab = page.tab(.changes);
                const bar = layout.page_bar orelse return error.ExpectedPageBar;
                break :blk app.handleEvent(app_test_support.mouseEvent(
                    bar.col + changes_tab.col,
                    bar.row,
                    .left,
                ));
            },
        } orelse return error.ExpectedPageSwitch;
        try std.testing.expectEqual(App.Msg{ .switch_page = .changes }, message);

        try app.update(message, &ctx);

        try std.testing.expectEqual(page.Id.changes, app.active_page);
        try std.testing.expect(!app.pages.repository.active);
        try std.testing.expectEqual(@as(usize, 1), app.pages.changes.viewer.selected_node);
        try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.changes.viewer.selected_target.?);
        try std.testing.expectEqual(@as(u8, 3), ctx._pending_tasks_with_len);
    }
}

test "changes repository transition active Repository controls remain same-page no-ops" {
    const allocator = std.testing.allocator;
    const identity: repo_root_capability.Identity = .{ .device = 5, .inode = 8 };
    const inputs = [_]enum { keyboard, page_bar }{ .keyboard, .page_bar };

    for (inputs) |input| {
        var app: App = .{
            .allocator = allocator,
            .active_page = .repository,
            .repo_session = .{
                .repo_epoch = 7,
            },
            .terminal_size = .{ .width = 100, .height = 20 },
            .pages = .{ .repository = .{
                .active = true,
                .repo_epoch = 7,
                .root_identity = identity,
                .selected_path = "retained.zig",
            } },
        };
        defer app.pages.repository.deinit(allocator);
        var incoming = try page_link.RepositoryIncoming.initOwned(
            allocator,
            app.repo_session.repo_epoch,
            identity,
            .{ .location = .{ .path = "pending.zig" } },
        );
        app.pages.repository.acceptIncoming(allocator, &incoming);
        var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

        const message = switch (input) {
            .keyboard => app.handleEvent(.{ .key_press = .{ .codepoint = '2' } }),
            .page_bar => blk: {
                const layout = app_shell_layout.compute(app.terminal_size, .{ .page_bar_visible = true });
                const repository_tab = page.tab(.repository);
                const bar = layout.page_bar orelse return error.ExpectedPageBar;
                break :blk app.handleEvent(app_test_support.mouseEvent(
                    bar.col + repository_tab.col,
                    bar.row,
                    .left,
                ));
            },
        } orelse return error.ExpectedPageSwitch;
        try std.testing.expectEqual(App.Msg{ .switch_page = .repository }, message);

        try app.update(message, &ctx);

        try std.testing.expectEqual(page.Id.repository, app.active_page);
        try std.testing.expect(app.pages.repository.active);
        try std.testing.expect(app.pages.repository.incoming == .awaiting_manifest);
        try std.testing.expectEqualStrings("pending.zig", app.pages.repository.incoming.manifestIntent().?.path);
        try std.testing.expectEqualStrings("retained.zig", app.pages.repository.selected_path.?);
        try std.testing.expect(app.pages.changes.activation.state == .inactive);
        try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
    }
}

test "changes repository transition common switch maps retained-location outcomes" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        path: ?[]const u8,
        retained_index: usize = 1,
        hide_reviewed: bool = false,
        identity_mismatch: bool = false,
        status: []const u8,
    }{
        .{ .path = "b", .status = "Repository file is already selected in Changes" },
        .{ .path = "missing.zig", .status = "Repository file is not part of the current Changes" },
        .{ .path = "b", .retained_index = 0, .hide_reviewed = true, .status = "Repository file is hidden by Changes filters" },
        .{ .path = "b", .retained_index = 0, .identity_mismatch = true, .status = "Repository changed before Changes navigation" },
        .{ .path = null, .status = "Repository has no resolved file to open in Changes" },
    };

    for (cases) |case| {
        var roots = try TestRepoPair.init();
        defer roots.deinit();
        var reviewed = [_]bool{ false, true };
        var loaded = app_test_support.loadedDiffTwo();
        loaded.reviewed_files = &reviewed;
        var app: App = .{
            .allocator = allocator,
            .active_page = .repository,
            .repo_session = .{
                .repo_epoch = 7,
                .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
            },
            .config = .{ .source = .unstaged },
            .pages = .{
                .changes = .{
                    .load = app_test_support.loadState(loaded),
                    .viewer = .{
                        .selected_target = .{ .diff_file = case.retained_index },
                        .selected_node = case.retained_index,
                        .diff_cursor = if (case.retained_index == 0) .{ .metadata = 0 } else .{ .metadata = 1 },
                        .diff_scroll = 9,
                    },
                    .review_display = .{ .hide_reviewed_files = case.hide_reviewed },
                },
                .repository = .{
                    .active = true,
                    .repo_epoch = 7,
                    .selected_path = case.path,
                },
            },
        };
        defer app.pages.changes.deinit(allocator);
        defer app.pages.repository.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
        const identity = app.repo_session.view().activeIdentity().?;
        app.pages.repository.root_identity = if (case.identity_mismatch)
            .{ .device = identity.device, .inode = identity.inode +% 1 }
        else
            identity;
        var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
        defer clearPendingStatusAndDiffTasks(&ctx, allocator);

        try app.update(.{ .switch_page = .changes }, &ctx);

        try std.testing.expectEqual(page.Id.changes, app.active_page);
        try std.testing.expect(!app.pages.repository.active);
        try std.testing.expectEqual(case.retained_index, app.pages.changes.viewer.selected_node);
        try std.testing.expectEqual(context.SelectedTarget{ .diff_file = case.retained_index }, app.pages.changes.viewer.selected_target.?);
        try std.testing.expect(std.meta.eql(
            if (case.retained_index == 0)
                diff_view_model.BodyCoordinate{ .metadata = 0 }
            else
                diff_view_model.BodyCoordinate{ .metadata = 1 },
            app.pages.changes.viewer.diff_cursor,
        ));
        try std.testing.expectEqual(@as(usize, 9), app.pages.changes.viewer.diff_scroll);
        try std.testing.expectEqual(case.hide_reviewed, app.pages.changes.review_display.hide_reviewed_files);
        try std.testing.expectEqualStrings(case.status, app.status.text());
        try std.testing.expectEqual(@as(u8, 3), ctx._pending_tasks_with_len);
    }
}

test "changes repository transition common switch consumes pending and unavailable no context" {
    const allocator = std.testing.allocator;
    const identity: repo_root_capability.Identity = .{ .device = 5, .inode = 8 };
    const cases = [_]enum { pending, unavailable }{ .pending, .unavailable };

    for (cases) |case| {
        var app: App = .{
            .allocator = allocator,
            .active_page = .repository,
            .repo_session = .{
                .repo_epoch = 7,
            },
            .config = .{ .source = .stdin },
            .pages = .{
                .changes = .{
                    .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
                    .viewer = .{
                        .selected_target = .{ .diff_file = 0 },
                        .selected_node = 0,
                        .diff_scroll = 6,
                    },
                },
                .repository = .{
                    .active = true,
                    .repo_epoch = 7,
                    .root_identity = identity,
                    .selected_path = "retained.zig",
                },
            },
        };
        defer app.pages.changes.deinit(allocator);
        defer app.pages.repository.deinit(allocator);
        var incoming = try page_link.RepositoryIncoming.initOwned(
            allocator,
            app.repo_session.repo_epoch,
            identity,
            switch (case) {
                .pending => .{ .location = .{ .path = "pending.zig" } },
                .unavailable => .{ .unavailable = .{
                    .path = "missing.zig",
                    .reason = .path_not_found,
                } },
            },
        );
        app.pages.repository.acceptIncoming(allocator, &incoming);
        var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

        try app.update(.{ .switch_page = .changes }, &ctx);

        try std.testing.expectEqual(page.Id.changes, app.active_page);
        try std.testing.expect(!app.pages.repository.active);
        try std.testing.expect(app.pages.repository.incoming == .none);
        try std.testing.expectEqual(@as(usize, 0), app.pages.changes.viewer.selected_node);
        try std.testing.expectEqual(@as(usize, 6), app.pages.changes.viewer.diff_scroll);
        try std.testing.expectEqualStrings("Repository has no resolved file to open in Changes", app.status.text());
        try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
    }
}

test "changes repository transition inactive Repository retains contextual selection" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{
        .allocator = allocator,
        .active_page = .repository,
        .repo_session = .{
            .repo_epoch = 7,
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
        .config = .{ .source = .unstaged },
        .pages = .{
            .changes = .{
                .load = app_test_support.loadState(app_test_support.loadedDiffTwo()),
                .viewer = .{
                    .selected_target = .{ .diff_file = 0 },
                    .selected_node = 0,
                },
            },
            .repository = .{
                .active = true,
                .repo_epoch = 7,
                .selected_path = "b",
            },
        },
    };
    defer app.pages.changes.deinit(allocator);
    defer app.pages.repository.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    app.pages.repository.root_identity = app.repo_session.view().activeIdentity().?;
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, allocator);

    try app.update(.{ .switch_page = .compare }, &ctx);
    try std.testing.expect(!app.pages.repository.active);
    try std.testing.expectEqualStrings("b", app.pages.repository.selected_path.?);

    try app.update(.{ .switch_page = .repository }, &ctx);
    try std.testing.expect(app.pages.repository.active);
    try std.testing.expectEqualStrings("b", app.pages.repository.selected_path.?);

    try app.update(.{ .switch_page = .changes }, &ctx);
    try std.testing.expectEqual(page.Id.changes, app.active_page);
    try std.testing.expect(!app.pages.repository.active);
    try std.testing.expectEqualStrings("b", app.pages.repository.selected_path.?);
    try std.testing.expectEqual(@as(usize, 1), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.changes.viewer.selected_target.?);
    // Public App updates also run the common tail: the two Repository members
    // join Changes's three reads and Review's retained snapshot task.
    try std.testing.expectEqual(@as(u8, 6), ctx._pending_tasks_with_len);
}

test "changes repository transition keyboard opens exact retained path with line owner" {
    const allocator = std.testing.allocator;
    const repository_manifest = @import("../../repository/manifest.zig");
    const repository_tree = @import("../../repository/tree.zig");
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var document = try repository_manifest.parseOwned(
        allocator,
        try allocator.dupe(u8, "a\x00other.zig\x00"),
    );
    var document_owned = true;
    errdefer if (document_owned) document.deinit(allocator);
    const tree = try repository_tree.Tree.build(allocator, &document);

    var app: App = .{
        .allocator = allocator,
        .repo_session = .{
            .repo_epoch = 7,
        },
        .config = .{ .source = .unstaged },
        .pages = .{
            .changes = .{
                .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
                .viewer = .{ .diff_cursor = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 3 } } },
            },
            .repository = .{
                .repo_epoch = 7,
                .bundle = .{ .document = document, .tree = tree },
                .load_state = .loaded,
                .manifest_revision = 2,
                .viewer = .{ .tree_cursor = 1 },
            },
        },
    };
    document_owned = false;
    defer app.pages.changes.deinit(allocator);
    defer app.pages.repository.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state.discovery = try testSingleRepoDiscovery(allocator, roots.a);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    app.pages.repository.root_identity = app.repo_session.view().activeIdentity();
    app.pages.repository.selected_path = app.pages.repository.bundle.?.tree.filePath("other.zig", .all).?;
    acceptTestSource(&app);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingRepositoryTasks(&ctx, allocator);

    const keyboard = app.handleEvent(.{ .key_press = .{ .codepoint = '2' } }) orelse
        return error.ExpectedPageSwitch;
    try app.update(keyboard, &ctx);

    try std.testing.expectEqual(page.Id.repository, app.active_page);
    try std.testing.expect(app.pages.changes.activation.state == .inactive);
    try std.testing.expectEqualStrings("a", app.pages.repository.selected_path.?);
    try std.testing.expect(app.pages.repository.incoming == .awaiting_document);
    const pending = app.pages.repository.incoming.documentIntent().?;
    try std.testing.expectEqualStrings("a", pending.location.path);
    try std.testing.expectEqual(@as(?u32, 3), pending.location.line);
    try std.testing.expectEqual(@as(u64, 2), pending.manifest_revision);
    try std.testing.expect(std.meta.eql(
        diff_view_model.BodyCoordinate{ .hunk_line = .{ .hunk_index = 0, .line_index = 3 } },
        app.pages.changes.viewer.diff_cursor,
    ));
    try std.testing.expectEqual(@as(u8, 2), ctx._pending_tasks_with_len);
}

test "changes repository transition page bar exposes deleted target as unavailable" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{
        .allocator = allocator,
        .repo_session = .{
            .repo_epoch = 3,
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
        .terminal_size = .{ .width = 100, .height = 20 },
        .config = .{ .source = .unstaged },
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffTwoWithStatuses()),
            .viewer = .{
                .selected_node = 1,
                .selected_target = .{ .diff_file = 1 },
            },
        } },
    };
    defer app.pages.changes.deinit(allocator);
    defer app.pages.repository.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    acceptTestSource(&app);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingRepositoryTasks(&ctx, allocator);

    const layout = app_shell_layout.compute(app.terminal_size, .{ .page_bar_visible = true });
    const repository_tab = page.tab(.repository);
    const bar = layout.page_bar orelse return error.ExpectedPageBar;
    const mouse = app.handleEvent(app_test_support.mouseEvent(
        bar.col + repository_tab.col,
        bar.row,
        .left,
    )) orelse return error.ExpectedPageSwitch;
    try app.update(mouse, &ctx);

    try std.testing.expectEqual(page.Id.repository, app.active_page);
    try std.testing.expect(app.pages.changes.activation.state == .inactive);
    const unavailable = app.pages.repository.incomingUnavailable().?;
    try std.testing.expectEqual(page_link.RepositoryUnavailableReason.no_current_path, unavailable.reason);
    try std.testing.expectEqualStrings("src/deleted.zig", unavailable.path);
    try std.testing.expect(app.pages.repository.selected_path == null);
    try std.testing.expectEqual(@as(u8, 2), ctx._pending_tasks_with_len);
}

const review_app_test_diff =
    "diff --git a/src/compare.zig b/src/compare.zig\n" ++
    "--- a/src/compare.zig\n" ++
    "+++ b/src/compare.zig\n" ++
    "@@ -1 +1 @@\n" ++
    "-old\n" ++
    "+new\n";

fn reviewAppTestOid(byte: u8) diff_basis.Oid {
    var oid: diff_basis.Oid = .{ .len = 40 };
    @memset(oid.bytes[0..40], byte);
    return oid;
}

fn reviewAppLoadedFinished(
    allocator: std.mem.Allocator,
    identity: page.RequestIdentity,
    generation: u64,
    base_byte: u8,
    head_byte: u8,
) !CompareLoadFinished {
    const full_ref = try allocator.dupe(u8, "refs/heads/main");
    errdefer allocator.free(full_ref);
    const display_name = try allocator.dupe(u8, "main");
    errdefer allocator.free(display_name);
    const head_display = try allocator.dupe(u8, "feature");
    errdefer allocator.free(head_display);
    return .{
        .identity = identity,
        .generation = generation,
        .result = .{ .loaded = .{
            .basis = .{
                .base = .{
                    .full_ref = full_ref,
                    .display_name = display_name,
                    .kind = .local,
                },
                .head_display = head_display,
                .target = .{
                    .object_format = .sha1,
                    .source_kind = .branch_range,
                    .base_oid = reviewAppTestOid(base_byte),
                    .head_oid = reviewAppTestOid(head_byte),
                    .diff_base_oid = reviewAppTestOid(base_byte),
                },
                .ahead_count = 1,
            },
            .diff = .{ .loaded = try app_load.buildLoadedBundle(allocator, review_app_test_diff) },
        } },
    };
}

fn reviewAppBasisFailureFinished(
    allocator: std.mem.Allocator,
    identity: page.RequestIdentity,
    generation: u64,
    name: []const u8,
) !CompareLoadFinished {
    const full_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{name});
    errdefer allocator.free(full_ref);
    return .{
        .identity = identity,
        .generation = generation,
        .result = .{ .basis_failed = .{
            .kind = .missing_base_ref,
            .attempted = .{
                .full_ref = full_ref,
                .display_name = try allocator.dupe(u8, name),
                .kind = .local,
            },
        } },
    };
}

const BranchStatusBundleSpec = struct {
    oid: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    upstream: ?[]const u8 = null,
    ahead: ?u32 = null,
    behind: ?u32 = null,
};

fn branchStatusBundleForTest(allocator: std.mem.Allocator, spec: BranchStatusBundleSpec) !git_branch_status.BranchStatusBundle {
    var builder = git_branch_status.Builder.init(allocator);
    errdefer builder.deinit();

    if (spec.oid) |oid| try builder.setOid(oid);
    if (spec.branch) |branch| {
        try builder.setBranchHead(branch);
    } else {
        builder.setDetached();
    }
    if (spec.upstream) |upstream| try builder.setUpstream(upstream);
    if (spec.ahead) |ahead| builder.setAheadBehind(ahead, spec.behind orelse 0);

    return builder.finish();
}

fn configureRepositoryBranchAppForTest(
    app: *App,
    allocator: std.mem.Allocator,
    root_path: []const u8,
) !void {
    app.repo_session.repo_state.discovery = try testSingleRepoDiscovery(allocator, root_path);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(root_path);
    app.pages.repository.activate(app.repo_session.repo_epoch, app.repo_session.view().activeIdentity());
    // These integration tests isolate the auxiliary member. The manifest
    // coordinator has its own start/apply suite and must not add an unrelated
    // task to the branch assertions below.
    app.pages.repository.needs_revalidation = false;
}

fn initializeRepositoryBranchAppRepoForTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
) !void {
    try runAppTestGit(allocator, io, &.{ "git", "init", "--initial-branch=main" }, dir);
    try dir.writeFile(io, .{ .sub_path = "tracked.txt", .data = "base\n" });
    try runAppTestGit(allocator, io, &.{ "git", "add", "tracked.txt" }, dir);
    try runAppTestGit(allocator, io, &.{
        "git",
        "-c",
        "user.name=Test",
        "-c",
        "user.email=test@example.invalid",
        "commit",
        "-m",
        "base",
    }, dir);
}

fn runAppTestGit(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: std.Io.Dir) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.GitCommandFailed;
}

fn repositoryLiveSelectionForTest() repository_selection.DragSelection {
    return .init(
        .{
            .repo_epoch = 1,
            .root_identity = .{ .device = 2, .inode = 3 },
            .path = "main.zig",
            .source_fingerprint = content_fingerprint.Fingerprint.init("source"),
        },
        .character,
        .{ .line_index = 0, .leading_byte = 0, .trailing_byte = 1 },
    );
}

fn repositoryHeaderSelectionForTest() repository_selection.SourceHeaderPathSelection {
    return .{ .identity = .{
        .repo_epoch = 1,
        .activation_id = 4,
        .root_identity = .{ .device = 2, .inode = 3 },
        .manifest_revision = 5,
        .path = "main.zig",
    } };
}

fn testSingleRepoDiscovery(allocator: std.mem.Allocator, root: []const u8) !repo_discovery.DiscoveryResult {
    return testNamedSingleRepoDiscovery(allocator, std.fs.path.basename(root), root);
}

fn testNamedSingleRepoDiscovery(allocator: std.mem.Allocator, label: []const u8, root: []const u8) !repo_discovery.DiscoveryResult {
    return .{ .single_repo = .{
        .label = try allocator.dupe(u8, label),
        .display_path = try allocator.dupe(u8, root),
        .canonical_root = try allocator.dupe(u8, root),
    } };
}

const TestRepoPair = struct {
    tmp: std.testing.TmpDir,
    a: [:0]u8,
    b: [:0]u8,

    fn init() !TestRepoPair {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDir(std.testing.io, "a", .default_dir);
        try tmp.dir.createDir(std.testing.io, "b", .default_dir);
        const a = try tmp.dir.realPathFileAlloc(std.testing.io, "a", std.testing.allocator);
        errdefer std.testing.allocator.free(a);
        const b = try tmp.dir.realPathFileAlloc(std.testing.io, "b", std.testing.allocator);
        return .{ .tmp = tmp, .a = a, .b = b };
    }

    fn deinit(self: *TestRepoPair) void {
        std.testing.allocator.free(self.a);
        std.testing.allocator.free(self.b);
        self.tmp.cleanup();
        self.* = undefined;
    }
};

fn repositoryIncomingViewportChangesDiffForTest() LoadedDiff {
    return .{
        .text = "",
        .document = .{ .files = &repository_incoming_viewport_changes_files },
        .file_text_eligibility = &repository_incoming_viewport_changes_eligibility,
        .tree = .{ .nodes = &repository_incoming_viewport_changes_tree_nodes },
        .collapsed_dirs = .{},
        .bytes = 0,
        .lines = 0,
    };
}

fn repositoryIncomingViewportBundleForTest(allocator: std.mem.Allocator) !repository_tasks.Bundle {
    const repository_manifest = @import("../../repository/manifest.zig");
    const repository_tree = @import("../../repository/tree.zig");
    var document = try repository_manifest.parseOwned(
        allocator,
        try allocator.dupe(u8, "src/app.zig\x00src/app/pages/repository.zig\x00"),
    );
    errdefer document.deinit(allocator);
    return .{
        .document = document,
        .tree = try repository_tree.Tree.build(allocator, &document),
    };
}

fn expectRepositoryProjectedPathForTest(
    state: *const repository_page.RepositoryPageState,
    visible_index: usize,
    expected_path: []const u8,
) !void {
    const tree = &state.bundle.?.tree;
    const target = state.tree_projection.targetAt(tree, visible_index) orelse
        return error.ExpectedProjectedPath;
    switch (target) {
        .repo_root => return error.ExpectedManifestPath,
        .manifest_node => |node_index| try std.testing.expectEqualStrings(
            expected_path,
            tree.nodes[node_index].path,
        ),
    }
}

fn acceptTestSource(app: *App) void {
    app.pages.changes.auto_reload.acceptSource(content_fingerprint.Fingerprint.init("test source"));
    syncTestActivation(app);
}

fn syncTestActivation(app: *App) void {
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

fn clearPendingRepositoryTasks(ctx: *chasen.Ctx(App.Msg), allocator: std.mem.Allocator) void {
    for (ctx.takePendingTasksWith()) |entry| {
        var message = entry.failed(entry.ctx, .runtime_abandoned, allocator);
        message.deinitUndelivered(allocator);
    }
}

fn clearPendingStatusAndDiffTasks(ctx: *chasen.Ctx(App.Msg), allocator: std.mem.Allocator) void {
    for (ctx.takePendingTasksWith()) |entry| {
        var message = entry.failed(entry.ctx, .runtime_abandoned, allocator);
        message.deinitUndelivered(allocator);
    }
}

const repository_incoming_viewport_changes_files = [_]diff_parser.FileDiff{
    .{
        .header = "diff --git a/src/app.zig b/src/app.zig",
        .old_path = "a/src/app.zig",
        .new_path = "b/src/app.zig",
        .metadata = &.{"index 1..2 100644"},
        .hunks = &.{},
    },
    .{
        .header = "diff --git a/src/app/pages/repository.zig b/src/app/pages/repository.zig",
        .old_path = "a/src/app/pages/repository.zig",
        .new_path = "b/src/app/pages/repository.zig",
        .metadata = &.{"index 1..2 100644"},
        .hunks = &.{},
    },
};

const repository_incoming_viewport_changes_eligibility =
    [_]loaded_diff.FileTextEligibility{ .selectable_utf8, .selectable_utf8 };

const repository_incoming_viewport_changes_tree_nodes = [_]file_tree.Node{
    .{ .kind = .directory, .name = "src", .path = "src", .depth = 0 },
    .{ .kind = .directory, .name = "app", .path = "src/app", .depth = 1 },
    .{ .kind = .directory, .name = "pages", .path = "src/app/pages", .depth = 2 },
    .{
        .kind = .file,
        .name = "repository.zig",
        .path = "src/app/pages/repository.zig",
        .depth = 3,
        .target = .{ .diff_file = 1 },
    },
    .{
        .kind = .file,
        .name = "app.zig",
        .path = "src/app.zig",
        .depth = 1,
        .target = .{ .diff_file = 0 },
    },
};

const BranchListItemSpec = struct {
    name: []const u8,
    oid: []const u8,
    current: bool = false,
};

fn branchListForTest(allocator: std.mem.Allocator, specs: []const BranchListItemSpec) !app_load.BranchListLoadTaskResult {
    const items = try allocator.alloc(git_refs.BranchListItem, specs.len);
    errdefer allocator.free(items);
    var initialized: usize = 0;
    errdefer {
        for (items[0..initialized]) |item| {
            allocator.free(item.full_ref);
            allocator.free(item.name);
            allocator.free(item.oid);
        }
    }
    for (specs, 0..) |spec, index| {
        const full_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{spec.name});
        errdefer allocator.free(full_ref);
        const name = try allocator.dupe(u8, spec.name);
        errdefer allocator.free(name);
        const oid = try allocator.dupe(u8, spec.oid);
        errdefer allocator.free(oid);
        items[index] = .{
            .full_ref = full_ref,
            .name = name,
            .kind = .local,
            .oid = oid,
            .current = spec.current,
        };
        initialized += 1;
    }
    return .{ .loaded = .{ .branches = items } };
}

fn abandonSingleQueuedTask(ctx: *chasen.Ctx(App.Msg), allocator: std.mem.Allocator) !void {
    const queued = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), queued.len);
    var abandoned = queued[0].failed(queued[0].ctx, .runtime_abandoned, allocator);
    abandoned.deinitUndelivered(allocator);
}

fn abandonQueuedTasks(ctx: *chasen.Ctx(App.Msg), allocator: std.mem.Allocator) usize {
    const queued = ctx.takePendingTasksWith();
    for (queued) |task| {
        var abandoned = task.failed(task.ctx, .runtime_abandoned, allocator);
        abandoned.deinitUndelivered(allocator);
    }
    return queued.len;
}
