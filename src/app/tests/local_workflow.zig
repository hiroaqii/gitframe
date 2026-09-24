//! Root integration tests for local workflow outcomes and shell routing.

const std = @import("std");
const chasen = @import("chasen");

const app_mod = @import("../../app.zig");
const app_actions = @import("../actions.zig");
const app_changes_projection = @import("../changes_projection.zig");
const app_commit_panel = @import("../commit_panel.zig");
const app_load = @import("../load.zig");
const app_message = @import("../message.zig");
const app_shell_layout = @import("../shell_layout.zig");
const app_state = @import("../state.zig");
const app_test_support = @import("../test_support.zig");
const changes_page = @import("../pages/changes.zig");
const changes_action_fence = @import("../pages/changes/action_fence.zig");
const changes_navigation = @import("../pages/changes/navigation.zig");
const changes_reload = @import("../pages/changes/reload.zig");
const changes_authority = @import("../diff_surface/authority.zig");
const content_fingerprint = @import("../../content_fingerprint.zig");
const diff_source = @import("../../diff/source.zig");
const file_tree = @import("../../file_tree.zig");
const git_ops = @import("../git_ops.zig");
const git_status = @import("../../git/status.zig");
const loaded_diff = @import("../../loaded_diff.zig");
const repo_discovery = @import("../../repo/discovery.zig");
const repo_root_capability = @import("../../repo/root_capability.zig");
const action_lifecycle = @import("../workflow/action_lifecycle.zig");

const App = app_mod.App;
const DiffLoadTask = app_load.DiffLoadTask(app_message.Msg);
const StatusLoadTask = app_load.StatusLoadTask(app_message.Msg);
const test_action_root_identity: repo_root_capability.Identity = .{ .device = 41, .inode = 73 };

test "body file navigation advances past a pending request and rejects its late completion" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    const nodes = [_]file_tree.Node{
        .{ .kind = .file, .name = "a", .path = "a", .depth = 0, .target = .{ .diff_file = 0 } },
        .{ .kind = .file, .name = "b", .path = "b", .depth = 0, .target = .{ .status_entry = 0 }, .status = .added },
        .{ .kind = .file, .name = "c", .path = "c", .depth = 0, .target = .{ .status_entry = 1 }, .status = .added },
    };
    var loaded = app_test_support.loadedDiffOne();
    loaded.tree.nodes = &nodes;
    var app: App = .{
        .allocator = allocator,
        .config = .{ .source = .unstaged },
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(loaded),
            .viewer = .{ .focus = .diff },
        } },
        .terminal_size = .{ .width = 120, .height = 32 },
    };
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state.discovery = try testSingleRepoDiscovery(allocator, roots.a);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    activateChanges(&app);
    var status = try git_status.StatusBundle.parseOwned(allocator, "?? b\x00?? c\x00");
    try app.pages.changes.git_status.replace(roots.a, &status);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };
    defer ctx.runtimeClearPendingEffectCopies();
    defer clearPendingStatusAndDiffTasks(&ctx, allocator);

    try app.update(app.handleEvent(.{ .key_press = .{ .codepoint = ']' } }).?, &ctx);
    try std.testing.expectEqualStrings("b", app.pages.changes.changes_projection.pending.?.path_key);
    const first = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), first.len);
    var late_b = first[0].failed(first[0].ctx, .runtime_abandoned, allocator);
    errdefer late_b.deinitUndelivered(allocator);
    late_b.load_finished.changes.projection.result = .{ .ready = .{ .generated_added_file = try app_changes_projection.generatedFileFromContent(allocator, "b", "late B\n") } };

    try app.update(app.handleEvent(.{ .key_press = .{ .codepoint = ']' } }).?, &ctx);
    try std.testing.expectEqualStrings("c", app.pages.changes.changes_projection.pending.?.path_key);
    const second = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), second.len);
    var ready_c = second[0].failed(second[0].ctx, .runtime_abandoned, allocator);
    ready_c.load_finished.changes.projection.result = .{ .ready = .{ .generated_added_file = try app_changes_projection.generatedFileFromContent(allocator, "c", "current C\n") } };
    try app.update(ready_c, &ctx);
    try std.testing.expectEqualStrings("c", app.pages.changes.changes_projection.displayed.request().?.path_key);
    try app.update(late_b, &ctx);
    late_b = .quit;
    try std.testing.expectEqualStrings("c", app.pages.changes.changes_projection.displayed.request().?.path_key);
    try std.testing.expectEqual(@as(usize, 1), app.pages.changes.viewer.selected_target.?.status_only);
    try std.testing.expectEqual(changes_page.Focus.diff, app.pages.changes.viewer.focus);
    try std.testing.expect(!app.pages.changes.changes_projection.hasPending());
}

fn activateChanges(app: *App) void {
    _ = app.pages.changes.activation.activate(
        app.repo_session.view().epoch(),
        .pending,
        .pending,
        .pending,
    );
}

fn changesNavigation(app: *App) changes_navigation.Controller {
    const body = app_shell_layout.compute(
        app.terminal_size,
        .{ .page_bar_visible = true },
    ).bodySize();
    return .{
        .page = &app.pages.changes,
        .repo_root = app.repo_session.view().activeRoot(),
        .repo_epoch = app.repo_session.view().epoch(),
        .root_identity = app.repo_session.view().activeIdentity(),
        .source = app.config.source,
        .layout = .{ .width = body.width, .height = body.height },
        .diagnostics = .{ .target = &app.pages.changes.status },
    };
}

fn changesReload(app: *App) changes_reload.Controller {
    return .{
        .page = &app.pages.changes,
        .navigation = changesNavigation(app),
        .source = app.config.source,
        .repo_root = app.repo_session.view().activeRoot(),
        .repo_epoch = app.repo_session.view().epoch(),
        .root_identity = app.repo_session.view().activeIdentity(),
    };
}

fn beginAcceptedTestAction(app: *App, kind: app_actions.ActionKind) app_actions.PendingAction {
    if (app.allocator == null) app.allocator = std.testing.allocator;
    const prepared = actionLifecycle(app).prepare(kind);
    return actionLifecycle(app).acceptSpawn(app.allocator.?, prepared).pending;
}

fn actionLifecycle(app: *App) action_lifecycle.Controller {
    return .{ .runtime = &app.action_runtime, .fence = changesActionFence(app) };
}

fn changesActionFence(app: *App) changes_action_fence.Controller {
    return .{
        .read_authority = &app.pages.changes.repository_read_authority,
        .activation = &app.pages.changes.activation,
        .action_cursor = &app.pages.changes.action_cursor,
        .auto_reload = &app.pages.changes.auto_reload,
        .changes_projection = &app.pages.changes.changes_projection,
        .deferred_projection_apply = &app.pages.changes.deferred_projection_apply,
    };
}

fn installTestActionCursor(
    app: *App,
    allocator: std.mem.Allocator,
    kind: changes_page.action_cursor.TargetKind,
    path_key: []const u8,
    action_generation: u64,
) !void {
    const identity = app.repo_session.view().activeIdentity() orelse test_action_root_identity;
    var prepared = try changesNavigation(app).prepareActionCursor(
        allocator,
        app.repo_session.view().epoch(),
        identity,
        kind,
        path_key,
    );
    changesNavigation(app).installActionCursor(allocator, &prepared, action_generation);
}

fn finishStageFileForTest(
    app: *App,
    ctx: *chasen.Ctx(App.Msg),
    finished: app_actions.StageFileFinished,
) !void {
    try app.update(.{ .action_finished = .{ .stage_file = finished } }, ctx);
}

fn finishStageHunkForTest(
    app: *App,
    ctx: *chasen.Ctx(App.Msg),
    finished: app_actions.StageHunkFinished,
) !void {
    try app.update(.{ .action_finished = .{ .stage_hunk = finished } }, ctx);
}

fn finishUnstageHunkForTest(
    app: *App,
    ctx: *chasen.Ctx(App.Msg),
    finished: app_actions.UnstageHunkFinished,
) !void {
    try app.update(.{ .action_finished = .{ .unstage_hunk = finished } }, ctx);
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
        app.repo_session.view().epoch(),
        source,
        changes_authority.auxiliaryMember(app.pages.changes.status_load),
        changes_authority.auxiliaryMember(app.pages.changes.branch_status_load),
    );
}

fn acceptTestSource(app: *App) void {
    app.pages.changes.auto_reload.acceptSource(content_fingerprint.Fingerprint.init("test source"));
    syncTestActivation(app);
}

fn testSingleRepoDiscovery(
    allocator: std.mem.Allocator,
    root: []const u8,
) !repo_discovery.DiscoveryResult {
    return .{ .single_repo = .{
        .label = try allocator.dupe(u8, std.fs.path.basename(root)),
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

fn initStageHunkLaunchApp(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
) !App {
    var root = try repo_root_capability.RootCapability.openCanonical(repo_root);
    var root_owned = true;
    errdefer if (root_owned) root.deinit();
    var discovery = try testSingleRepoDiscovery(allocator, repo_root);
    var discovery_owned = true;
    errdefer if (discovery_owned) discovery.deinit(allocator);
    var arena: std.heap.ArenaAllocator = .init(allocator);
    var arena_owned = true;
    errdefer if (arena_owned) arena.deinit();
    var loaded = app_test_support.loadedDiffTwo();
    try loaded.rebuildVisibleNodes(arena.allocator(), false, .all);
    var app: App = .{
        .allocator = allocator,
        .config = .{ .source = .unstaged },
        .repo_session = .{ .repo_state = .{
            .discovery = discovery,
            .root = root,
        } },
        .pages = .{ .changes = .{
            .load = app_test_support.loadStateWithArena(arena, loaded),
            .viewer = .{
                .focus = .diff,
                .selected_target = .{ .diff_file = 0 },
                .selected_node = 0,
                .diff_cursor = .{ .hunk_header = 0 },
            },
        } },
        .terminal_size = .{ .width = 100, .height = 20 },
    };
    root_owned = false;
    discovery_owned = false;
    arena_owned = false;
    errdefer {
        app.pages.changes.deinit(allocator);
        app.repo_session.repo_state.deinit(allocator);
    }
    var status = try git_status.StatusBundle.parseOwned(allocator, " M a\x00 M b\x00");
    defer status.deinit();
    try app.pages.changes.git_status.replace(repo_root, &status);
    acceptTestSource(&app);
    return app;
}

fn clearPendingStatusTasks(ctx: *chasen.Ctx(App.Msg), allocator: std.mem.Allocator) void {
    for (ctx.takePendingTasksWith()) |entry| {
        var message = entry.failed(entry.ctx, .runtime_abandoned, allocator);
        message.deinitUndelivered(allocator);
    }
}

fn clearPendingStatusAndDiffTasks(
    ctx: *chasen.Ctx(App.Msg),
    allocator: std.mem.Allocator,
) void {
    for (ctx.takePendingTasksWith()) |entry| {
        var message = entry.failed(entry.ctx, .runtime_abandoned, allocator);
        message.deinitUndelivered(allocator);
    }
}

test "successful file action binds the exact source and status generations started by its refresh" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{
        .allocator = allocator,
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
    };
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer app.repo_session.repo_state.deinit(allocator);
    defer changesReload(&app).clearPendingReload(allocator);
    defer changesReload(&app).clearLoadedDiff(app.allocator);
    defer app.pages.changes.git_status.deinit();
    defer changesNavigation(&app).clearActionCursor(allocator);
    _ = activateChanges(&app);

    const pending = beginAcceptedTestAction(&app, .stage_file);
    try installTestActionCursor(&app, allocator, .directory, "src", pending.generation);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, allocator);
    try finishStageFileForTest(&app, &ctx, .{
        .pending = pending,
        .repo_root = try allocator.dupe(u8, roots.a),
        .path = try allocator.dupe(u8, "src"),
        .result = .ok,
    });

    const entries = ctx._pending_tasks_with[0..ctx._pending_tasks_with_len];
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    const status_task: *StatusLoadTask = @ptrCast(@alignCast(entries[0].ctx));
    const source_task: *DiffLoadTask = @ptrCast(@alignCast(entries[2].ctx));
    const basis = app.pages.changes.action_cursor.owner.?.phase.awaiting_action_refresh;
    try std.testing.expectEqual(pending.generation, app.pages.changes.action_cursor.actionGeneration().?);
    try std.testing.expectEqual(status_task.generation, basis.memberState(.status).?.generation.?);
    try std.testing.expectEqual(source_task.generation, basis.memberState(.source).?.generation.?);
    try std.testing.expectEqual(changes_page.action_cursor.Terminal.pending, basis.memberState(.status).?.terminal);
    try std.testing.expectEqual(changes_page.action_cursor.Terminal.pending, basis.memberState(.source).?.terminal);
}

test "successful hunk action binds an exact status-only refresh" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{
        .allocator = allocator,
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
    };
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.pages.changes.git_status.deinit();
    defer changesNavigation(&app).clearActionCursor(allocator);
    _ = activateChanges(&app);

    const pending = beginAcceptedTestAction(&app, .stage_hunk);
    try installTestActionCursor(&app, allocator, .file, "a", pending.generation);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusTasks(&ctx, allocator);
    try finishStageHunkForTest(&app, &ctx, .{
        .pending = pending,
        .repo_root = try allocator.dupe(u8, roots.a),
        .path = try allocator.dupe(u8, "a"),
        .hunk_index = 1,
        .session_mark_mutation = .none,
        .result = .ok,
    });

    const entries = ctx._pending_tasks_with[0..ctx._pending_tasks_with_len];
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    const status_task: *StatusLoadTask = @ptrCast(@alignCast(entries[0].ctx));
    const basis = app.pages.changes.action_cursor.owner.?.phase.awaiting_action_refresh;
    try std.testing.expectEqual(changes_page.action_cursor.RefreshRequirement.status_only, std.meta.activeTag(basis));
    try std.testing.expect(basis.memberState(.source) == null);
    try std.testing.expectEqual(status_task.generation, basis.memberState(.status).?.generation.?);
    try std.testing.expectEqual(changes_page.action_cursor.Terminal.pending, basis.memberState(.status).?.terminal);
}

test "cached hunk unstage binds exact source and status refresh members" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try initStageHunkLaunchApp(allocator, roots.a);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.pages.changes.deinit(allocator);

    const pending = beginAcceptedTestAction(&app, .unstage_hunk);
    try installTestActionCursor(&app, allocator, .file, "a", pending.generation);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, allocator);
    try finishUnstageHunkForTest(&app, &ctx, .{
        .pending = pending,
        .repo_root = try allocator.dupe(u8, roots.a),
        .path = try allocator.dupe(u8, "a"),
        .hunk_index = 1,
        .session_mark_mutation = .none,
        .reload_after_success = true,
        .result = .ok,
    });

    const entries = ctx._pending_tasks_with[0..ctx._pending_tasks_with_len];
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    const status_task: *StatusLoadTask = @ptrCast(@alignCast(entries[0].ctx));
    const source_task: *DiffLoadTask = @ptrCast(@alignCast(entries[2].ctx));
    const basis = app.pages.changes.action_cursor.owner.?.phase.awaiting_action_refresh;
    try std.testing.expectEqual(changes_page.action_cursor.RefreshRequirement.source_and_status, std.meta.activeTag(basis));
    try std.testing.expectEqual(status_task.generation, basis.memberState(.status).?.generation.?);
    try std.testing.expectEqual(source_task.generation, basis.memberState(.source).?.generation.?);
}

test "status-only hunk refresh spawn rejection closes its exact owner" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try initStageHunkLaunchApp(allocator, roots.a);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.pages.changes.deinit(allocator);

    const pending = beginAcceptedTestAction(&app, .stage_hunk);
    try installTestActionCursor(&app, allocator, .file, "a", pending.generation);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._pending_tasks_with_len = 16 };
    try finishStageHunkForTest(&app, &ctx, .{
        .pending = pending,
        .repo_root = try allocator.dupe(u8, roots.a),
        .path = try allocator.dupe(u8, "a"),
        .hunk_index = 1,
        .session_mark_mutation = .none,
        .result = .ok,
    });
    ctx._pending_tasks_with_len = 0;

    try std.testing.expect(!app.action_runtime.view().hasPending());
    try std.testing.expect(app.pages.changes.status_load.pending == null);
    try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
}

test "inert diff hunk command reports bounded encoding diagnostic" {
    const eligibility = [_]loaded_diff.FileTextEligibility{.inert_invalid_utf8};
    var loaded = app_test_support.loadedDiffOne();
    loaded.file_text_eligibility = &eligibility;
    var app: App = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(loaded),
            .viewer = .{ .selected_target = .{ .diff_file = 0 } },
        } },
        .allocator = std.testing.allocator,
    };
    defer changesReload(&app).clearLoadedDiff(std.testing.allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.update(.{ .changes = .toggle_selected_hunk }, &ctx);

    try std.testing.expectEqualStrings(git_ops.inert_hunk_action_message, app.pages.changes.status.text());
    try std.testing.expect(std.mem.indexOfScalar(u8, app.pages.changes.status.text(), 0xff) == null);
}

test "opening amend confirmation cancels active discard confirmation" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .local_workflow = .{ .commit_panel = app_commit_panel.State.init(allocator) },
        .repo_session = .{ .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } } },
    };
    defer app.local_workflow.commit_panel.deinit();
    defer {
        if (app.local_workflow.amend_confirmation) |*confirmation| confirmation.deinit(allocator);
        if (app.local_workflow.discard_confirmation) |*confirmation| confirmation.deinit(allocator);
    }
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    app.local_workflow.discard_confirmation = .{
        .repo_root = try allocator.dupe(u8, "/repo"),
        .path = try allocator.dupe(u8, "src/app.zig"),
    };
    app.overlay.openDiscardFile();
    app.local_workflow.commit_panel.open(.amend);
    app.local_workflow.commit_panel.insert('x');

    try app.update(.submit_commit_panel, &ctx);

    try std.testing.expect(app.local_workflow.discard_confirmation == null);
    try std.testing.expect(app.local_workflow.amend_confirmation != null);
    try std.testing.expectEqual(app_state.OverlayKind.amend_commit, app.overlay.kind);
}

test "canceling amend confirmation keeps commit panel draft" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .local_workflow = .{ .commit_panel = app_commit_panel.State.init(allocator) },
        .repo_session = .{ .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } } },
    };
    defer app.local_workflow.commit_panel.deinit();
    defer if (app.local_workflow.amend_confirmation) |*confirmation| confirmation.deinit(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    app.local_workflow.commit_panel.open(.amend);
    app.local_workflow.commit_panel.insert('x');
    try app.update(.submit_commit_panel, &ctx);

    try app.update(.cancel_amend, &ctx);

    try std.testing.expect(app.local_workflow.amend_confirmation == null);
    try std.testing.expectEqual(app_state.OverlayKind.none, app.overlay.kind);
    try std.testing.expect(app.local_workflow.commit_panel.is_open);
    try std.testing.expectEqual(app_commit_panel.Mode.amend, app.local_workflow.commit_panel.mode);
    try std.testing.expectEqualStrings("x", app.local_workflow.commit_panel.subject.slice());
}
