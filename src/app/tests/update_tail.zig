//! Root integration tests for cross-owner update-tail ordering.

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
const compare_page = @import("../pages/compare.zig");
const repository_page = @import("../pages/repository.zig");
const repository_selection = @import("../pages/repository/selection.zig");
const review_page = @import("../pages/review.zig");
const review_navigation = @import("../pages/review/navigation.zig");
const review_authority = @import("../diff_surface/authority.zig");
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
const git_backend = @import("../../git/backend.zig");
const git_branch_status = @import("../../git/branch_status.zig");
const repo_discovery = @import("../../repo/discovery.zig");
const repo_root_capability = @import("../../repo/root_capability.zig");
const review_session = @import("../../review/session.zig");
const source_syntax_runtime = @import("../../syntax/source_runtime.zig");

const App = app_mod.App;
const app_testing = app_mod.testing;
const LoadedDiff = @import("../../loaded_diff.zig").LoadedDiff;
const loaded_diff = @import("../../loaded_diff.zig");
const DiffLoadTask = app_load.DiffLoadTask(app_message.Msg);
const StatusLoadTask = app_load.StatusLoadTask(app_message.Msg);
const BranchStatusLoadTask = app_load.BranchStatusLoadTask(app_message.Msg);
const CompareLoadFinished = app_load.CompareLoadFinished;
const CompareLoadTask = app_load.CompareLoadTask(app_message.Msg);
const CompareBranchListFinished = app_load.CompareBranchListFinished;
const CompareBranchListLoadTask = app_load.CompareBranchListLoadTask(app_message.Msg);
const RepositoryManifestTask = repository_page.ManifestTask(app_message.Msg);
const RepositoryBranchTask = repository_page.BranchTask(app_message.Msg);
const RepositoryDocumentTask = repository_page.DocumentTask(app_message.Msg);
const RepositorySyntaxTask = repository_page.SyntaxTask(app_message.Msg);
const RepositoryChangeMapTask = repository_page.ChangeMapTask(app_message.Msg);

fn activateReview(app: *App) u64 {
    const source_member: review_authority.MemberFreshness = if (diff_source.sourceIsOneShotInput(app.config.source))
        switch (app.pages.review.load.state) {
            .loaded, .empty => .immutable,
            .loading => .pending,
            .failed => .failed,
            .idle => .pending,
        }
    else
        .pending;
    const auxiliary: review_authority.MemberFreshness = if (diff_source.sourceRequiresRepo(app.config.source) and app.repo_session.view().activeRoot() != null) .pending else .unavailable;
    return app.pages.review.activation.activate(
        app.repo_session.view().epoch(),
        source_member,
        auxiliary,
        auxiliary,
    );
}

fn reviewNavigationView(app: *const App) review_navigation.View {
    const body = app_shell_layout.compute(
        app.terminal_size,
        .{ .page_bar_visible = true },
    ).bodySize();
    return .{
        .page = &app.pages.review,
        .repo_root = app.repo_session.view().activeRoot(),
        .repo_epoch = app.repo_session.view().epoch(),
        .root_identity = app.repo_session.view().activeIdentity(),
        .source = app.config.source,
        .layout = .{ .width = body.width, .height = body.height },
    };
}

test "Compare completion defers as one bundle during drag and applies afterward" {
    const allocator = std.testing.allocator;
    var app: App = .{ .allocator = allocator, .active_page = .compare };
    defer app.pages.compare.deinit(allocator);
    _ = app.pages.compare.activate(app.repo_session.repo_epoch);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    const initial = app.pages.compare.beginRefresh().?;
    try app.update(.{ .load_finished = .{ .compare = .{ .source = try compareAppLoadedFinished(
        allocator,
        initial.identity,
        initial.generation,
        'a',
        'b',
    ) } } }, &ctx);
    app.pages.compare.selection_owner = .{ .diff = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "b/src/compare.zig" } },
        .side = .new,
        .mode = .line,
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 0, .line_index = 1 },
        .moved = true,
    } };
    const replacement = app.pages.compare.beginRefresh().?;
    try app.update(.{ .load_finished = .{ .compare = .{ .source = try compareAppLoadedFinished(
        allocator,
        replacement.identity,
        replacement.generation,
        'd',
        'e',
    ) } } }, &ctx);

    try std.testing.expect(app.pages.compare.deferred_load_apply != null);
    try std.testing.expectEqualStrings(compareAppTestOid('b').slice(), app.pages.compare.basis.?.head_oid.slice());
    app.pages.compare.selection_owner = .none;
    try app.update(.focus_lost, &ctx);
    try std.testing.expect(app.pages.compare.deferred_load_apply == null);
    try std.testing.expectEqualStrings(compareAppTestOid('e').slice(), app.pages.compare.basis.?.head_oid.slice());
}

test "repository commitment resets Compare and refreshes the new physical root" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{
        .allocator = allocator,
        .active_page = .compare,
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
    };
    defer app.pages.compare.deinit(allocator);
    defer app.repo_session.deinit(allocator);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    _ = app.pages.compare.activate(app.repo_session.repo_epoch);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, allocator);

    const initial = app.pages.compare.beginRefresh().?;
    try app.update(.{ .load_finished = .{ .compare = .{ .source = try compareAppLoadedFinished(
        allocator,
        initial.identity,
        initial.generation,
        'a',
        'b',
    ) } } }, &ctx);
    try std.testing.expect(app.pages.compare.basis != null);

    const outcome = try app_testing.commitDiscovery(
        &app,
        allocator,
        try testSingleRepoDiscovery(allocator, roots.b),
        0,
        .external_selection,
    );
    try std.testing.expectEqual(repo_session.CommitOutcome.changed, outcome);
    try std.testing.expect(app.pages.compare.basis == null);
    try std.testing.expect(app.pages.compare.base_target == null);
    try std.testing.expect(app.pages.compare.activation.state == .inactive);
    try app_testing.applyRepoSessionCommit(&app, &ctx, outcome);

    try std.testing.expectEqualStrings(roots.b, app.repo_session.view().activeRoot().?);
    try std.testing.expect(app.pages.compare.basis == null);
    try std.testing.expect(app.pages.compare.base_target == null);
    try std.testing.expect(app.pages.compare.activation.state == .active);
    try std.testing.expectEqual(@as(u8, 1), ctx._pending_tasks_with_len);
    const task: *CompareLoadTask = @ptrCast(@alignCast(ctx._pending_tasks_with[0].ctx));
    try std.testing.expect(task.root.identity.eql(app.repo_session.view().activeIdentity().?));

    var async_app: App = .{
        .allocator = allocator,
        .active_page = .compare,
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
    };
    defer async_app.pages.compare.deinit(allocator);
    defer async_app.repo_session.deinit(allocator);
    async_app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    _ = async_app.pages.compare.activate(0);
    const review_activation = async_app.pages.review.activation.activate(0, .pending, .unavailable, .unavailable);
    const discovery_generation = async_app.pages.review.load.beginRepoDiscovery();
    async_app.pages.review.load.state = .loading;
    var async_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusAndDiffTasks(&async_ctx, allocator);

    try async_app.update(.{ .load_finished = .{ .coordinator = .{ .repo_discovery = .{
        .identity = page.RequestIdentity.review(0, review_activation),
        .generation = discovery_generation,
        .result = .{ .discovered = try testSingleRepoDiscovery(allocator, roots.b) },
    } } } }, &async_ctx);

    try std.testing.expectEqual(@as(u64, 1), async_app.repo_session.view().epoch());
    try std.testing.expect(async_app.pages.compare.activation.state == .active);
    try std.testing.expectEqual(@as(u64, 1), async_app.pages.compare.activation.state.active.repo_epoch);
    try std.testing.expectEqual(@as(u8, 1), async_ctx._pending_tasks_with_len);
}

test "repository activation and manual reload route to page-owned manifest tasks" {
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{
        .allocator = std.testing.allocator,
        .config = .{ .source = .stdin },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = roots.a,
                .canonical_root = roots.a,
            } } },
        },
    };
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer if (app.repo_session.repo_state.root) |*root| root.deinit();
    defer app.pages.repository.deinit(std.testing.allocator);
    _ = activateReview(&app);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer clearPendingRepositoryTasks(&ctx, std.testing.allocator);

    try app.update(.{ .switch_page = .repository }, &ctx);
    try std.testing.expectEqual(@as(u8, 2), ctx._pending_tasks_with_len);
    const first: *RepositoryManifestTask = @ptrCast(@alignCast(ctx._pending_tasks_with[0].ctx));
    try std.testing.expectEqual(page.Id.repository, first.request.identity.origin);
    try std.testing.expectEqual(app.repo_session.repo_epoch, first.request.identity.repo_epoch);
    const first_generation = first.request.generation;
    const first_branch: *RepositoryBranchTask = @ptrCast(@alignCast(ctx._pending_tasks_with[1].ctx));
    const first_branch_generation = first_branch.request.generation;
    try std.testing.expectEqual(first.request.identity, first_branch.request.identity);

    try app.update(.reload, &ctx);
    try std.testing.expectEqual(@as(u8, 4), ctx._pending_tasks_with_len);
    const second: *RepositoryManifestTask = @ptrCast(@alignCast(ctx._pending_tasks_with[2].ctx));
    try std.testing.expect(second.request.generation > first_generation);
    try std.testing.expectEqual(second.request.generation, app.pages.repository.pending_generation.?);
    const second_branch: *RepositoryBranchTask = @ptrCast(@alignCast(ctx._pending_tasks_with[3].ctx));
    try std.testing.expect(second_branch.request.generation > first_branch_generation);
    try std.testing.expectEqual(second_branch.request.generation, app.pages.repository.branch.pending.?.generation);
}

test "review repository transition active repository replacement rejects old owner and result" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{
        .allocator = allocator,
        .active_page = .repository,
    };
    defer app.pages.repository.deinit(allocator);
    defer app.repo_session.deinit(allocator);
    try std.testing.expectEqual(repo_session.CommitOutcome.changed, try app_testing.commitDiscovery(
        &app,
        allocator,
        try testSingleRepoDiscovery(allocator, roots.a),
        0,
        .external_selection,
    ));
    app.pages.repository.activate(app.repo_session.repo_epoch, app.repo_session.view().activeIdentity());
    const root_a_identity = app.repo_session.view().activeIdentity().?;
    try std.testing.expect(app.pages.repository.root_identity.?.eql(root_a_identity));
    app.pages.repository.selected_path = "retained.zig";
    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        app.repo_session.repo_epoch,
        app.repo_session.view().activeIdentity().?,
        .{ .location = .{ .path = "pending.zig" } },
    );
    app.pages.repository.acceptIncoming(allocator, &incoming);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingRepositoryTasks(&ctx, allocator);

    try app.update(.reload, &ctx);
    try std.testing.expectEqual(@as(u8, 2), ctx._pending_tasks_with_len);
    const old_task: *RepositoryManifestTask = @ptrCast(@alignCast(ctx._pending_tasks_with[0].ctx));
    const old_identity = old_task.request.identity;
    const old_root_identity = old_task.request.root.identity;
    const old_generation = old_task.request.generation;
    try std.testing.expectEqual(page.Id.repository, old_identity.origin);
    try std.testing.expectEqual(app.pages.repository.repo_epoch, old_identity.repo_epoch);
    try std.testing.expectEqual(app.pages.repository.activation_id, old_identity.activation_id);
    try std.testing.expectEqual(app.pages.repository.generation, old_generation);
    try std.testing.expectEqual(old_generation, app.pages.repository.pending_generation.?);
    try std.testing.expect(old_root_identity.eql(root_a_identity));
    try std.testing.expectEqualStrings(roots.a, old_task.request.root_path);

    try std.testing.expectEqual(repo_session.CommitOutcome.changed, try app_testing.commitDiscovery(
        &app,
        allocator,
        try testSingleRepoDiscovery(allocator, roots.b),
        0,
        .external_selection,
    ));
    const root_b_identity = app.repo_session.view().activeIdentity().?;
    try std.testing.expect(!root_a_identity.eql(root_b_identity));
    try std.testing.expectEqualStrings(roots.b, app.repo_session.view().activeRoot().?);
    try std.testing.expectEqual(@as(u64, 2), app.repo_session.repo_epoch);
    try std.testing.expect(app.pages.repository.active);
    try std.testing.expect(app.pages.repository.root_identity.?.eql(root_b_identity));
    try std.testing.expect(app.pages.repository.selected_path == null);
    try std.testing.expect(app.pages.repository.incoming == .none);
    try std.testing.expect(app.pages.repository.pending_generation == null);
    try std.testing.expect(app.pages.repository.needs_revalidation);
    try std.testing.expect(app.pages.repository.wantsManifestRequest());

    try app.update(.{ .repository = .{ .manifest_finished = .{
        .identity = old_identity,
        .root_identity = old_root_identity,
        .generation = old_generation,
        .result = .{ .failed_static = "stale old manifest" },
    } } }, &ctx);

    try std.testing.expectEqualStrings(roots.b, app.repo_session.view().activeRoot().?);
    try std.testing.expectEqual(@as(u64, 2), app.pages.repository.repo_epoch);
    try std.testing.expect(app.pages.repository.root_identity.?.eql(root_b_identity));
    try std.testing.expect(app.pages.repository.bundle == null);
    try std.testing.expect(app.pages.repository.selected_path == null);
    try std.testing.expect(app.pages.repository.incoming == .none);
    const replacement_generation = app.pages.repository.pending_generation orelse
        return error.ExpectedReplacementManifest;
    try std.testing.expect(!app.pages.repository.needs_revalidation);
    try std.testing.expect(!app.pages.repository.wantsManifestRequest());
    try std.testing.expectEqual(@as(u8, 4), ctx._pending_tasks_with_len);
    const replacement_task: *RepositoryManifestTask = @ptrCast(@alignCast(ctx._pending_tasks_with[2].ctx));
    try std.testing.expectEqual(replacement_generation, replacement_task.request.generation);
    try std.testing.expectEqualStrings(roots.b, replacement_task.request.root_path);
    try std.testing.expect(replacement_task.request.root.identity.eql(root_b_identity));
    try std.testing.expectEqual(@as(usize, 0), app.pages.repository.status.text().len);
    try std.testing.expect(app.redraw_plan.resolvesToSkip());
}

test "review repository transition post-commit manifest start failures stay on Repository" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    const cases = [_]struct {
        fail_index: usize,
        generation: u64,
        status: []const u8,
    }{
        .{
            .fail_index = 0,
            .generation = 0,
            .status = "Could not prepare repository manifest: OutOfMemory",
        },
        .{
            .fail_index = 1,
            .generation = 1,
            .status = "Could not start repository manifest task",
        },
    };

    for (cases) |case| {
        var app: App = .{
            // The handoff succeeds through the application allocator. Only
            // destination task preparation uses the failing Ctx allocator,
            // making this a post-commit failure rather than a prepare error.
            .allocator = allocator,
            .repo_session = .{
                .repo_epoch = 7,
                .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
            },
            .config = .{ .source = .unstaged },
            .pages = .{ .review = .{
                .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
                .viewer = .{ .diff_cursor = .{ .hunk_header = 0 } },
            } },
        };
        defer app.pages.review.deinit(allocator);
        defer app.pages.repository.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
        acceptTestSource(&app);
        const review_activation = app.pages.review.activation.state.active.activation_id;
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = case.fail_index });
        var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = failing.allocator() };

        try std.testing.expectError(error.OutOfMemory, app.update(.{ .switch_page = .repository }, &ctx));

        try std.testing.expectEqual(page.Id.repository, app.active_page);
        try std.testing.expect(app.pages.review.activation.state == .inactive);
        try std.testing.expectEqual(review_activation, app.pages.review.activation.next_activation_id);
        try std.testing.expect(app.pages.repository.active);
        try std.testing.expectEqual(@as(u64, 1), app.pages.repository.activation_id);
        const unavailable = app.pages.repository.incomingUnavailable().?;
        try std.testing.expectEqual(page_link.RepositoryUnavailableReason.request_failed, unavailable.reason);
        try std.testing.expectEqualStrings("a", unavailable.path);
        try std.testing.expectEqual(case.generation, app.pages.repository.generation);
        try std.testing.expect(app.pages.repository.pending_generation == null);
        try std.testing.expectEqualStrings(case.status, app.pages.repository.status.text());
        try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
        try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_len);
    }
}

test "repository incoming viewport scroll App immediate and deferred routes use current body size" {
    const allocator = std.testing.allocator;
    const Route = enum { keyboard, page_bar, deferred_manifest };
    var roots = try TestRepoPair.init();
    defer roots.deinit();

    for ([_]Route{ .keyboard, .page_bar, .deferred_manifest }) |route| {
        var app: App = .{
            .allocator = allocator,
            .repo_session = .{
                .repo_epoch = 4,
            },
            .terminal_size = .{ .width = 120, .height = 12 },
            .config = .{ .source = .unstaged },
            .pages = .{ .review = .{
                .load = app_test_support.loadState(repositoryIncomingViewportReviewDiffForTest()),
                .viewer = .{
                    .selected_target = .{ .diff_file = 1 },
                    .selected_node = 3,
                },
            } },
        };
        defer app.pages.review.deinit(allocator);
        defer app.pages.repository.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        app.repo_session.repo_state.discovery = try testSingleRepoDiscovery(allocator, roots.a);
        app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
        const identity = app.repo_session.view().activeIdentity().?;
        var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
        defer clearPendingRepositoryTasks(&ctx, allocator);
        try std.testing.expectEqual(
            chasen.Size{ .width = 118, .height = 7 },
            app_shell_layout.compute(app.terminal_size, .{ .page_bar_visible = true }).bodySize(),
        );

        switch (route) {
            .keyboard, .page_bar => {
                app.pages.repository.repo_epoch = 4;
                app.pages.repository.root_identity = identity;
                app.pages.repository.bundle = try repositoryIncomingViewportBundleForTest(allocator);
                app.pages.repository.load_state = .loaded;
                app.pages.repository.manifest_revision = 2;
                app.pages.repository.viewer = .{
                    .tree_cursor = 5,
                    .tree_vertical_scroll = 99,
                };
                app.pages.repository.selected_path =
                    app.pages.repository.bundle.?.tree.filePath("src/app.zig", .all).?;
                acceptTestSource(&app);
                const msg = if (route == .keyboard)
                    app.handleEvent(.{ .key_press = .{ .codepoint = '2' } }) orelse
                        return error.ExpectedPageSwitch
                else blk: {
                    const repository_tab = page.tab(.repository);
                    const bar = app_shell_layout.compute(app.terminal_size, .{ .page_bar_visible = true }).page_bar orelse return error.ExpectedPageBar;
                    break :blk app.handleEvent(app_test_support.mouseEvent(
                        bar.col + repository_tab.col,
                        bar.row,
                        .left,
                    )) orelse return error.ExpectedPageSwitch;
                };
                try app.update(msg, &ctx);
            },
            .deferred_manifest => {
                app.active_page = .repository;
                app.pages.repository = .{
                    .initialized = true,
                    .active = true,
                    .activation_id = 2,
                    .repo_epoch = 4,
                    .root_identity = identity,
                    .generation = 7,
                    .pending_generation = 7,
                    .load_state = .loading,
                    .viewer = .{ .tree_vertical_scroll = 99 },
                };
                var incoming = try page_link.RepositoryIncoming.initOwned(
                    allocator,
                    4,
                    identity,
                    .{ .location = .{ .path = "src/app/pages/repository.zig" } },
                );
                app.pages.repository.acceptIncoming(allocator, &incoming);
                try app.update(.{ .repository = .{ .manifest_finished = .{
                    .identity = .{ .origin = .repository, .repo_epoch = 4, .activation_id = 2 },
                    .root_identity = identity,
                    .generation = 7,
                    .result = .{ .loaded = try repositoryIncomingViewportBundleForTest(allocator) },
                } } }, &ctx);
            },
        }

        try std.testing.expectEqual(page.Id.repository, app.active_page);
        try std.testing.expectEqualStrings("src/app/pages/repository.zig", app.pages.repository.selected_path.?);
        try std.testing.expectEqual(@as(usize, 4), app.pages.repository.viewer.tree_cursor);
        try std.testing.expectEqual(@as(usize, 1), app.pages.repository.viewer.tree_vertical_scroll);
        try expectRepositoryProjectedPathForTest(&app.pages.repository, 1, "src");
        try expectRepositoryProjectedPathForTest(&app.pages.repository, 4, "src/app/pages/repository.zig");
    }
}

test "review repository transition unavailable path is not replayed after reload" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();

    var initial_loaded = app_test_support.loadedDiffOne();
    initial_loaded.text = "old";
    var app: App = .{
        .allocator = allocator,
        .active_page = .repository,
        .repo_session = .{
            .repo_epoch = 7,
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
        .config = .{ .source = .unstaged },
        .pages = .{
            .review = .{
                .load = app_test_support.loadState(initial_loaded),
                .viewer = .{
                    .selected_target = .{ .diff_file = 0 },
                    .selected_node = 0,
                    .diff_cursor = .{ .metadata = 0 },
                    .diff_scroll = 5,
                },
            },
            .repository = .{
                .active = true,
                .repo_epoch = 7,
                .selected_path = "b",
            },
        },
    };
    defer app.pages.review.deinit(allocator);
    defer app.pages.repository.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    app.pages.repository.root_identity = app.repo_session.view().activeIdentity().?;
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, allocator);

    try app.update(.{ .switch_page = .review }, &ctx);

    try std.testing.expectEqualStrings("Repository file is not part of the current Review", app.status.text());
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(@as(u8, 3), ctx._pending_tasks_with_len);
    const diff_task: *DiffLoadTask = @ptrCast(@alignCast(ctx._pending_tasks_with[2].ctx));
    const status_task: *StatusLoadTask = @ptrCast(@alignCast(ctx._pending_tasks_with[0].ctx));
    var replacement = app_test_support.loadedDiffTwo();
    replacement.text = "new";
    try app.update(.{ .load_finished = .{ .review = .{ .source = .{
        .identity = diff_task.identity,
        .generation = diff_task.generation,
        .background_cycle_id = diff_task.background_cycle_id,
        .result = .{ .loaded = .{
            .arena = .init(allocator),
            .loaded = replacement,
        } },
    } } } }, &ctx);
    try app.update(.{ .load_finished = .{ .review = .{ .status = .{
        .identity = status_task.identity,
        .read_epoch = status_task.read_epoch,
        .generation = status_task.generation,
        .background_cycle_id = status_task.background_cycle_id,
        .repo_root = try allocator.dupe(u8, roots.a),
        .result = .empty,
    } } } }, &ctx);

    const reloaded = reviewNavigationView(&app).activeLoadedDiffConst().?;
    try std.testing.expectEqual(@as(usize, 2), reloaded.document.files.len);
    try std.testing.expect(app.pages.review.viewer.selected_node < reloaded.tree.nodes.len);
    try std.testing.expectEqualStrings(
        "a",
        reloaded.tree.nodes[app.pages.review.viewer.selected_node].path,
    );
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, app.pages.review.viewer.selected_target.?);
}

const compare_app_test_diff =
    "diff --git a/src/compare.zig b/src/compare.zig\n" ++
    "--- a/src/compare.zig\n" ++
    "+++ b/src/compare.zig\n" ++
    "@@ -1 +1 @@\n" ++
    "-old\n" ++
    "+new\n";

fn compareAppTestOid(byte: u8) diff_basis.Oid {
    var oid: diff_basis.Oid = .{ .len = 40 };
    @memset(oid.bytes[0..40], byte);
    return oid;
}

fn compareAppLoadedFinished(
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
                    .oid = compareAppTestOid(base_byte),
                },
                .head_display = head_display,
                .merge_base_oid = compareAppTestOid(base_byte),
                .head_oid = compareAppTestOid(head_byte),
                .ahead_count = 1,
            },
            .diff = .{ .loaded = try app_load.buildLoadedBundle(allocator, compare_app_test_diff) },
        } },
    };
}

fn compareAppBasisFailureFinished(
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

fn repositoryIncomingViewportReviewDiffForTest() LoadedDiff {
    return .{
        .text = "",
        .document = .{ .files = &repository_incoming_viewport_review_files },
        .file_text_eligibility = &repository_incoming_viewport_review_eligibility,
        .tree = .{ .nodes = &repository_incoming_viewport_review_tree_nodes },
        .collapsed_dirs = .{},
        .bytes = 0,
        .lines = 0,
    };
}

fn repositoryIncomingViewportBundleForTest(allocator: std.mem.Allocator) !repository_page.Bundle {
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
    app.pages.review.auto_reload.acceptSource(content_fingerprint.Fingerprint.init("test source"));
    syncTestActivation(app);
}

fn syncTestActivation(app: *App) void {
    const source: review_authority.MemberFreshness = if (diff_source.sourceIsOneShotInput(app.config.source))
        .immutable
    else if (app.pages.review.auto_reload.sourceIsActionable())
        .fresh
    else if (app.pages.review.load.hasPending())
        .pending
    else
        .unavailable;
    _ = app.pages.review.activation.activate(
        app.repo_session.repo_epoch,
        source,
        review_authority.auxiliaryMember(app.pages.review.status_load),
        review_authority.auxiliaryMember(app.pages.review.branch_status_load),
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

const repository_incoming_viewport_review_files = [_]diff_parser.FileDiff{
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

const repository_incoming_viewport_review_eligibility =
    [_]loaded_diff.FileTextEligibility{ .selectable_utf8, .selectable_utf8 };

const repository_incoming_viewport_review_tree_nodes = [_]file_tree.Node{
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
    const items = try allocator.alloc(git_backend.BranchListItem, specs.len);
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
